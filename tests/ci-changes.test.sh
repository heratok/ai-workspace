#!/usr/bin/env bash
# =============================================================================
# Pruebas de scripts/ci-changes.sh (qué jobs pesados del CI hacen falta según los archivos cambiados).
#
#   bash tests/ci-changes.test.sh
#
# Sin red: cada prueba arma un repositorio git temporal con un commit base y otro con el cambio.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci-changes.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

ZERO=0000000000000000000000000000000000000000

# mk_repo <archivo>...: repo con un commit base (BASE) y otro (HEAD_SHA) que modifica esos archivos
mk_repo() {
  R="$TMP/repo.$RANDOM"; mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.name ci; git -C "$R" config user.email ci@example.invalid; git -C "$R" config core.autocrlf false
  mkdir -p "$R/config" "$R/landing/src" "$R/docs" "$R/tests/helpers" "$R/.github/workflows"
  for f in Dockerfile .dockerignore entrypoint.sh docker-compose.yml config/zshrc landing/src/index.astro \
           docs/uso.md README.md tests/entrypoint.test.sh tests/helpers/asserts.sh tests/aiws.test.sh \
           .github/workflows/ci.yml scripts/ci-changes.sh; do
    mkdir -p "$(dirname "$R/$f")"; echo base > "$R/$f"
  done
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
  for f in "$@"; do mkdir -p "$(dirname "$R/$f")"; echo cambio >> "$R/$f"; done
  git -C "$R" add -A; git -C "$R" commit -qm cambio --allow-empty
  HEAD_SHA="$(git -C "$R" rev-parse HEAD)"
}

changes() { (cd "$R" && bash "$SCRIPT" "$@"); }

t_docs_only_skips_image_and_landing() {
  mk_repo docs/uso.md README.md
  local out; out="$(changes pull_request "$BASE" "$HEAD_SHA")"
  assert_has "docs" "$out" "image=false"
  assert_has "docs" "$out" "landing=false"
}

t_image_files_trigger_build_only() {
  local f out
  for f in Dockerfile .dockerignore entrypoint.sh docker-compose.yml config/zshrc config/nuevo.conf tests/entrypoint.test.sh tests/helpers/asserts.sh; do
    mk_repo "$f"
    out="$(changes pull_request "$BASE" "$HEAD_SHA")"
    assert_has "$f" "$out" "image=true"
    assert_has "$f" "$out" "landing=false"
  done
}

t_landing_files_trigger_landing_only() {
  mk_repo landing/src/index.astro
  local out; out="$(changes push "$BASE" "$HEAD_SHA")"
  assert_has "landing" "$out" "landing=true"
  assert_has "landing" "$out" "image=false"
}

t_other_tests_do_not_trigger_build() {   # las pruebas de lint corren siempre; no necesitan la imagen
  mk_repo tests/aiws.test.sh
  local out; out="$(changes pull_request "$BASE" "$HEAD_SHA")"
  assert_has "tests/aiws" "$out" "image=false"
}

t_ci_files_trigger_everything() {   # un cambio en el propio CI o en este filtro se valida completo
  local f out
  for f in .github/workflows/ci.yml scripts/ci-changes.sh; do
    mk_repo "$f"
    out="$(changes pull_request "$BASE" "$HEAD_SHA")"
    assert_has "$f" "$out" "image=true"
    assert_has "$f" "$out" "landing=true"
  done
}

t_schedule_and_manual_runs_run_everything() {   # el lunes y workflow_dispatch construyen siempre
  mk_repo docs/uso.md
  local ev out
  for ev in schedule workflow_dispatch; do
    out="$(changes "$ev" "$BASE" "$HEAD_SHA")"
    assert_has "$ev" "$out" "image=true"
    assert_has "$ev" "$out" "landing=true"
  done
}

t_unknown_base_runs_everything() {   # sin base confiable (rama nueva, force push, historia cortada): ante la duda, todo
  mk_repo docs/uso.md
  local b out
  for b in "" "$ZERO" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; do
    out="$(changes push "$b" "$HEAD_SHA")"
    assert_has "base '$b'" "$out" "image=true"
    assert_has "base '$b'" "$out" "landing=true"
  done
}

t_output_is_github_output_format() {   # exactamente dos líneas clave=valor para $GITHUB_OUTPUT
  mk_repo Dockerfile
  local out; out="$(changes pull_request "$BASE" "$HEAD_SHA")"
  assert_match "formato" "$out" $'^image=(true|false)\nlanding=(true|false)$'
}

for t in t_docs_only_skips_image_and_landing t_image_files_trigger_build_only t_landing_files_trigger_landing_only \
         t_other_tests_do_not_trigger_build t_ci_files_trigger_everything t_schedule_and_manual_runs_run_everything \
         t_unknown_base_runs_everything t_output_is_github_output_format; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
