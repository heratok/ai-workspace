#!/usr/bin/env bash
# =============================================================================
# Pruebas de config/fetch-script.sh (descarga robusta de instaladores "curl | sh").
#
#   bash tests/fetch-script.test.sh
#
# Sin red: las "URL" son file:// y el reintento no espera (FETCH_RETRY_DELAY=0).
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH="$ROOT/config/fetch-script.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"
export FETCH_RETRY_DELAY=0

SCRIPT_BODY=$'#!/bin/bash\necho instalado\n'

# file:// URL for a local path. On Windows (Git Bash) curl.exe does not understand MSYS paths such as
# /tmp/...: cygpath -m turns them into C:/... (cygpath only exists there; Linux keeps the path as is).
file_url() {
  if command -v cygpath >/dev/null 2>&1; then echo "file:///$(cygpath -m "$1")"; else echo "file://$1"; fi
}

t_script_exists() {
  [[ -f "$FETCH" ]] && ok || nok "falta config/fetch-script.sh"
}

t_plain_script_passes_through() {
  printf '%s' "$SCRIPT_BODY" > "$TMP/plain.sh"
  local out; out="$(bash "$FETCH" "$(file_url "$TMP/plain.sh")" 2>/dev/null)"
  assert_eq "script plano" "$SCRIPT_BODY" "$out"$'\n'
}

t_gzip_script_is_decompressed() {
  printf '%s' "$SCRIPT_BODY" | gzip -c > "$TMP/gz.sh"
  local out; out="$(bash "$FETCH" "$(file_url "$TMP/gz.sh")" 2>/dev/null)"
  assert_eq "script gzip" "$SCRIPT_BODY" "$out"$'\n'
}

t_output_is_runnable() {
  printf '%s' "$SCRIPT_BODY" | gzip -c > "$TMP/gz2.sh"
  local out; out="$(bash "$FETCH" "$(file_url "$TMP/gz2.sh")" 2>/dev/null | bash)"
  assert_eq "ejecutable" "instalado" "$out"
}

t_non_script_fails_with_diagnostics() {
  printf '<html>error 200 de un proxy</html>' > "$TMP/html.out"
  local err rc
  err="$(bash "$FETCH" "$(file_url "$TMP/html.out")" 2>&1 >/dev/null)"; rc=$?
  assert_eq "código de salida" "1" "$rc"
  assert_has "mensaje" "$err" "no es un script"
  assert_has "primeros bytes" "$err" "3c68746d6c"
}

t_missing_url_fails() {
  local rc
  bash "$FETCH" "$(file_url "$TMP/no-existe")" >/dev/null 2>&1; rc=$?
  assert_eq "URL inexistente falla" "1" "$rc"
}

t_no_args_fails() {
  local rc
  bash "$FETCH" >/dev/null 2>&1; rc=$?
  [[ "$rc" != "0" ]] && ok || nok "sin argumentos debe fallar"
}

run t_script_exists
run t_plain_script_passes_through
run t_gzip_script_is_decompressed
run t_output_is_runnable
run t_non_script_fails_with_diagnostics
run t_missing_url_fails
run t_no_args_fails

p="$(wc -l < "$PASSES" | tr -d ' ')"; f="$(wc -l < "$FAILS" | tr -d ' ')"
echo
echo "Resultado: $p aserciones correctas, $f fallidas"
(( f == 0 ))
