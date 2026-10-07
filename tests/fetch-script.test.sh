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
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"
export FETCH_RETRY_DELAY=0

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else nok "$1: esperado '$2', obtenido '$3'"; fi; return 0; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3' en: $2"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

SCRIPT_BODY=$'#!/bin/bash\necho instalado\n'

t_script_exists() {
  [[ -f "$FETCH" ]] && ok || nok "falta config/fetch-script.sh"
}

t_plain_script_passes_through() {
  printf '%s' "$SCRIPT_BODY" > "$TMP/plain.sh"
  local out; out="$(bash "$FETCH" "file://$TMP/plain.sh" 2>/dev/null)"
  assert_eq "script plano" "$SCRIPT_BODY" "$out"$'\n'
}

t_gzip_script_is_decompressed() {
  printf '%s' "$SCRIPT_BODY" | gzip -c > "$TMP/gz.sh"
  local out; out="$(bash "$FETCH" "file://$TMP/gz.sh" 2>/dev/null)"
  assert_eq "script gzip" "$SCRIPT_BODY" "$out"$'\n'
}

t_output_is_runnable() {
  printf '%s' "$SCRIPT_BODY" | gzip -c > "$TMP/gz2.sh"
  local out; out="$(bash "$FETCH" "file://$TMP/gz2.sh" 2>/dev/null | bash)"
  assert_eq "ejecutable" "instalado" "$out"
}

t_non_script_fails_with_diagnostics() {
  printf '<html>error 200 de un proxy</html>' > "$TMP/html.out"
  local err rc
  err="$(bash "$FETCH" "file://$TMP/html.out" 2>&1 >/dev/null)"; rc=$?
  assert_eq "código de salida" "1" "$rc"
  assert_has "mensaje" "$err" "no es un script"
  assert_has "primeros bytes" "$err" "3c68746d6c"
}

t_missing_url_fails() {
  local rc
  bash "$FETCH" "file://$TMP/no-existe" >/dev/null 2>&1; rc=$?
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
