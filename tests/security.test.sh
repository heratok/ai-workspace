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
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3'"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

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

t_ci_step_names_are_valid_yaml() {      # "name: texto: otro" sin comillas rompe el YAML (actionlint: mapping values are not allowed)
  local bad; bad="$(grep -nE '^      - name: [^"'"'"'].*: ' "$CI" || true)"
  [[ -z "$bad" ]] && ok || nok "nombre de paso con ': ' sin comillas: $bad"
}

t_every_test_script_is_shellchecked() {   # un test que ShellCheck no revisa puede esconder errores de shell
  local f n line; line="$(grep -E 'shellcheck -S error' "$CI")"
  for f in "$ROOT"/tests/*.test.sh; do
    n="tests/$(basename "$f")"
    [[ "$line" == *"$n"* ]] && ok || nok "$n no está en la lista de ShellCheck de ci.yml"
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

for t in t_ci_runs_on_a_schedule t_has_a_security_job t_scanners_are_pinned_not_latest \
         t_repo_scan_blocks_only_actionable_findings t_image_is_scanned_after_build \
         t_image_scan_blocks_critical_and_reports_high t_ci_step_names_are_valid_yaml t_every_test_script_is_shellchecked t_hadolint_config_documents_every_ignore t_trivyignore_documents_every_ignore; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
