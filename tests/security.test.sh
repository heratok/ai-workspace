#!/usr/bin/env bash
# =============================================================================
# Pruebas de la configuración del escaneo de seguridad (Hadolint + Trivy) en CI.
#
#   bash tests/security.test.sh
#
# Estáticas (sin Docker ni red): comprueban que las herramientas estén fijadas,
# que el escaneo corra también por calendario y que cada excepción tenga motivo.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
HADOLINT_CFG="$ROOT/.hadolint.yaml"
TRIVY_IGNORE="$ROOT/.trivyignore"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

t_ci_runs_on_a_schedule() {
  grep -qE '^  schedule:' "$CI" && ok || nok "ci.yml no tiene 'schedule:'"
  grep -qE "^    - cron: '[0-9*/, -]+ [0-9*/, -]+ [0-9*/, -]+ [0-9*/, -]+ [0-9*/, -]+'" "$CI" && ok || nok "ci.yml no tiene un cron válido"
}

t_has_a_security_job() {
  grep -qE '^  security:' "$CI" && ok || nok "falta el job 'security'"
}

t_scanners_are_pinned_not_latest() {
  grep -qE 'hadolint/hadolint:v[0-9]+\.[0-9]+\.[0-9]+' "$CI" && ok || nok "hadolint no está fijado a una versión"
  grep -qE 'aquasec/trivy:[0-9]+\.[0-9]+\.[0-9]+' "$CI" && ok || nok "trivy no está fijado a una versión"
  if grep -qE '(hadolint|trivy):latest' "$CI"; then nok "no se debe usar :latest"; else ok; fi
}

t_repo_scan_blocks_only_actionable_findings() {
  local body; body="$(<"$CI")"
  assert_has "trivy fs" "$body" "trivy:"
  grep -qE 'fs .*--ignore-unfixed|--ignore-unfixed .*fs ' "$CI" && ok || nok "el escaneo del repo debe usar --ignore-unfixed"
  grep -qE -- '--exit-code 1' "$CI" && ok || nok "el escaneo del repo debe fallar el CI (--exit-code 1)"
  grep -qE -- '--failure-threshold error' "$CI" && ok || nok "hadolint debe fallar solo en errores"
}

t_image_is_scanned_after_build() {
  grep -qE 'image .*ai-workspace:ci' "$CI" && ok || nok "falta el escaneo de la imagen ai-workspace:ci"
}

t_image_scan_blocks_critical_and_reports_high() {
  grep -qE 'image .*--severity CRITICAL .*--ignore-unfixed .*--exit-code 1 .*ai-workspace:ci|image .*--severity CRITICAL .*--exit-code 1 .*--ignore-unfixed .*ai-workspace:ci' "$CI" && ok || nok "el escaneo de imagen debe bloquear CRITICAL con corrección"
  grep -qE 'image .*--severity HIGH .*--exit-code 0 .*ai-workspace:ci' "$CI" && ok || nok "los HIGH de la imagen deben informarse sin bloquear"
}

t_heavy_jobs_follow_changed_files() {   # build y landing se saltan si el cambio no los toca; lint y security corren siempre
  local body; body="$(<"$CI")"
  assert_has "job changes" "$body" "run: bash scripts/ci-changes.sh"
  assert_has "build filtrado" "$body" "if: needs.changes.outputs.image == 'true'"
  assert_has "landing filtrado" "$body" "if: needs.changes.outputs.landing == 'true'"
  grep -qE '^  changes:' "$CI" && ok || nok "falta el job 'changes'"
  awk '/^  (lint|security):/{j=1} /^  [a-z]+:/ && !/^  (lint|security):/{j=0} j && /needs\.changes/' "$CI" | grep -q . && nok "lint y security no deben depender de changes" || ok
}

t_image_scans_share_trivy_cache() {   # sin caché compartida, cada escaneo vuelve a bajar la base de vulnerabilidades (~1 min)
  local n; n="$(grep -cE 'trivy-cache:/root/\.cache/trivy .*image .*ai-workspace:ci' "$CI" || true)"
  (( n == 2 )) && ok || nok "los dos escaneos de la imagen deben montar el volumen trivy-cache (encontrados: $n)"
}

t_ci_step_names_are_valid_yaml() {      # "name: texto: otro" sin comillas rompe el YAML (actionlint: mapping values are not allowed)
  local bad; bad="$(grep -nE '^      - name: [^"'"'"'].*: ' "$CI" || true)"
  [[ -z "$bad" ]] && ok || nok "nombre de paso con ': ' sin comillas: $bad"
}

t_every_test_script_is_shellchecked() {   # un script que ShellCheck no revisa puede esconder errores de shell
  local f n d line; line="$(grep -E 'koalaman/shellcheck' "$CI")"
  for f in "$ROOT"/tests/*.test.sh "$ROOT"/tests/run-all.sh "$ROOT"/tests/helpers/*.sh "$ROOT"/scripts/*.sh "$ROOT"/lib/*.sh; do
    [[ -f "$f" ]] || continue
    d="$(basename "$(dirname "$f")")"; n="$d/$(basename "$f")"
    [[ "$line" == *"$n"* || "$line" == *"$d/*.test.sh"* || "$line" == *"$d/*.sh"* ]] && ok || nok "$n no está en la lista de ShellCheck de ci.yml"
  done
}

t_every_test_script_runs_in_ci() {   # un test que ningún paso del CI ejecuta no protege nada
  local f n
  for f in "$ROOT"/tests/*.test.sh; do
    n="$(basename "$f")"
    grep -qE "run: bash tests/$n" "$CI" && ok || nok "tests/$n no se ejecuta en el CI (falta un paso 'run: bash tests/$n' en ci.yml)"
  done
}

t_hadolint_config_documents_every_ignore() {
  [[ -f "$HADOLINT_CFG" ]] || { nok "falta .hadolint.yaml"; return 0; }
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" == *"#"* ]] && ok || nok "regla ignorada sin motivo: $line"
  done < <(grep -E '^[[:space:]]+- (DL|SC)[0-9]+' "$HADOLINT_CFG")
  (( n > 0 )) && ok || nok ".hadolint.yaml no ignora nada (¿se midió el baseline?)"
}

t_trivyignore_documents_every_ignore() {
  [[ -f "$TRIVY_IGNORE" ]] || { nok "falta .trivyignore"; return 0; }
  local prev="" line n=0
  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != \#* ]]; then
      n=$((n + 1))
      [[ "$prev" == \#* ]] && ok || nok "excepción sin comentario con el motivo justo encima: $line"
    fi
    prev="$line"
  done < "$TRIVY_IGNORE"
  (( n > 0 )) && ok || nok ".trivyignore no acepta nada (DS-0002 está medido y es intencional)"
}

t_ci_cancels_superseded_runs() {   # two pushes to the same ref should not both burn a 60 min build
  grep -qE '^concurrency:' "$CI" && ok || nok "ci.yml no tiene un bloque 'concurrency:' de nivel superior"
  grep -qE '^  group: ci-\$\{\{ github\.ref \}\}' "$CI" && ok || nok "concurrency debe agrupar por 'ci-\${{ github.ref }}'"
  grep -qE '^  cancel-in-progress: true' "$CI" && ok || nok "concurrency debe tener 'cancel-in-progress: true'"
}

t_every_step_has_a_timeout() {   # a hung suite must not burn the whole job
  local steps timeouts
  steps="$(grep -cE '^      - (name|uses):' "$CI")"
  timeouts="$(grep -cE '^        timeout-minutes: [0-9]+' "$CI")"
  [[ "$steps" -gt 0 && "$steps" == "$timeouts" ]] && ok || nok "pasos: $steps, pasos con timeout-minutes: $timeouts (cada paso necesita el suyo)"
}

t_build_uses_layer_cache() {
  grep -qE 'uses: docker/setup-buildx-action@[0-9a-f]{40}' "$CI" && ok || nok "falta docker/setup-buildx-action fijado por SHA"
  grep -qE 'uses: docker/build-push-action@[0-9a-f]{40}' "$CI" && ok || nok "falta docker/build-push-action fijado por SHA"
  grep -qE 'cache-from: type=gha' "$CI" && ok || nok "el build debe leer la caché de GitHub (cache-from: type=gha)"
  grep -qE 'cache-to: type=gha' "$CI" && ok || nok "el build debe guardar la caché de GitHub (cache-to: type=gha)"
  grep -qE "no-cache: \\$\\{\\{ github\\.event_name == 'schedule' \\}\\}" "$CI" && ok || nok "sin caché solo en la corrida del lunes (no-cache: \${{ github.event_name == 'schedule' }})"
  grep -qE 'load: true' "$CI" && ok || nok "la imagen debe quedar cargada en Docker para los pasos siguientes (load: true)"
  grep -qE 'tags: ai-workspace:ci' "$CI" && ok || nok "la imagen debe llamarse ai-workspace:ci"
}

t_tool_images_pinned_by_digest() {   # a tag can be moved; a digest cannot
  local img
  for img in koalaman/shellcheck hadolint/hadolint aquasec/trivy; do
    if grep -E "$img:" "$CI" | grep -vqE "$img:[^ ]+@sha256:[0-9a-f]{64}"; then
      nok "$img debe ir fijado por digest (tag@sha256:...) en todos sus usos"
    else ok; fi
  done
}

t_landing_is_built_and_audited() {
  grep -qE '^  landing:' "$CI" && ok || nok "falta el job 'landing'"
  grep -qE 'working-directory: landing' "$CI" && ok || nok "el job landing debe trabajar en landing/"
  grep -qE 'run: npm ci' "$CI" && ok || nok "landing debe instalar con 'npm ci'"
  grep -qE 'run: npm run build' "$CI" && ok || nok "landing debe compilar con 'npm run build'"
  grep -qE 'run: npm audit --audit-level=high' "$CI" && ok || nok "landing debe pasar 'npm audit --audit-level=high'"
}

t_dependabot_watches_landing_npm() {
  local dep="$ROOT/.github/dependabot.yml" block
  block="$(awk '/package-ecosystem: npm/{f=1} f&&/package-ecosystem:/&&!/npm/{f=0} f' "$dep")"
  [[ -n "$block" ]] && ok || { nok "dependabot.yml no tiene una entrada npm"; return 0; }
  assert_has "directorio npm" "$block" "directory: /landing"
  assert_has "grupos npm" "$block" "groups:"
}

t_tests_share_one_assert_helper() {   # a fix to an assert must not need 16 copies
  local f n
  [[ -f "$ROOT/tests/helpers/asserts.sh" ]] && ok || { nok "falta tests/helpers/asserts.sh"; return 0; }
  for f in "$ROOT"/tests/*.test.sh; do
    n="$(basename "$f")"
    grep -qE '^source "\$ROOT/tests/helpers/asserts\.sh"' "$f" && ok || nok "$n no carga tests/helpers/asserts.sh"
    if grep -qE '^(ok|nok|run|assert_(eq|has|lacks|ok|fail|match|file))\(\)' "$f"; then nok "$n redefine asserts del helper"; else ok; fi
  done
}

t_run_all_fails_when_any_test_fails() {
  local runner="$ROOT/tests/run-all.sh" d="$TMP/suite" out rc
  [[ -f "$runner" ]] || { nok "falta tests/run-all.sh"; return 0; }
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho bien\n' > "$d/a.test.sh"
  printf '#!/usr/bin/env bash\necho mal; exit 1\n' > "$d/b.test.sh"
  out="$(AIWS_TESTS_DIR="$d" bash "$runner" 2>&1)"; rc=$?
  assert_eq "run-all con un test roto: código" "1" "$rc"
  assert_has "run-all nombra el test roto" "$out" "b.test.sh"
  rm "$d/b.test.sh"
  out="$(AIWS_TESTS_DIR="$d" bash "$runner" 2>&1)"; rc=$?
  assert_eq "run-all con todo en verde: código" "0" "$rc"
  assert_has "run-all cuenta los tests" "$out" "1 ok, 0 fallidos"
}

for t in t_ci_runs_on_a_schedule t_has_a_security_job t_scanners_are_pinned_not_latest \
         t_tests_share_one_assert_helper t_run_all_fails_when_any_test_fails \
         t_ci_cancels_superseded_runs t_every_step_has_a_timeout t_build_uses_layer_cache \
         t_tool_images_pinned_by_digest t_landing_is_built_and_audited t_dependabot_watches_landing_npm \
         t_repo_scan_blocks_only_actionable_findings t_image_is_scanned_after_build \
         t_image_scan_blocks_critical_and_reports_high t_image_scans_share_trivy_cache t_heavy_jobs_follow_changed_files t_ci_step_names_are_valid_yaml t_every_test_script_is_shellchecked t_every_test_script_runs_in_ci t_hadolint_config_documents_every_ignore t_trivyignore_documents_every_ignore; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
