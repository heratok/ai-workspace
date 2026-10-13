#!/usr/bin/env bash
# =============================================================================
# Pruebas de scripts/update-pins.sh (listar, elegir y fijar versiones de Herdr y Gentle AI).
#
#   bash tests/update-pins.test.sh
#
# Sin red: la API de GitHub se simula con archivos (PINS_FETCH). Cada prueba trabaja sobre una
# copia temporal de Dockerfile, docker-compose.yml y env.example (PINS_ROOT).
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/update-pins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else nok "$1: esperado '$2', obtenido '$3'"; fi; return 0; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3' en: $2"; fi; return 0; }
assert_lacks() { if [[ "$2" != *"$3"* ]]; then ok; else nok "$1: NO debía contener '$3' en: $2"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# --------------------------------------------------------------- fixtures
source "$ROOT/tests/helpers/pins-fixtures.sh"
mk_fixtures() { pins_fixtures; }
# Copia de los tres archivos que el script reescribe, con pines de partida CONOCIDOS (no los del repo, que cambian)
seed_pin() {   # seed_pin <CLAVE> <valor>: fija el valor en Dockerfile (ARG), compose (valor por defecto) y env.example
  K="$1" V="$2" perl -pi -e 's/^ARG \Q$ENV{K}\E=.*/ARG $ENV{K}=$ENV{V}/; s/(\$\{\Q$ENV{K}\E:-)[^}]*(\})/$1$ENV{V}$2/g; s/^((?:# )?)\Q$ENV{K}\E=.*/$1$ENV{K}=$ENV{V}/' "$R/Dockerfile" "$R/docker-compose.yml" "$R/env.example"
}
mk_root() {
  mk_fixtures
  R="$TMP/root.$RANDOM"; mkdir -p "$R"
  cp "$ROOT/Dockerfile" "$ROOT/docker-compose.yml" "$ROOT/env.example" "$R/"
  seed_pin CLAUDE_CODE_VERSION 2.1.296; seed_pin PI_VERSION 0.73.1; seed_pin OPENCODE_VERSION 1.19.0
  seed_pin PLAYWRIGHT_VERSION 1.64.0; seed_pin PLAYWRIGHT_CLI_VERSION 0.1.22; seed_pin PLAYWRIGHT_MCP_VERSION 0.0.83
  seed_pin UV_VERSION 0.13.0; seed_pin MISE_VERSION v2026.10.8; seed_pin TS_IMAGE_TAG v1.104.1
  seed_pin HERDR_VERSION 0.9.4; seed_pin HERDR_SHA256_AMD64 "$SHA_C"; seed_pin HERDR_SHA256_ARM64 "$SHA_D"
  seed_pin GENTLE_AI_VERSION 4.1.1; seed_pin DOPPLER_VERSION 3.77.0
  printf 'INSTALL_OPENCODE=false\nTS_HOSTNAME=mi-equipo\n' > "$R/.env"
  export PINS_ROOT="$R" PINS_FETCH="$FIX/fetch.sh"
}
pin() { bash "$SCRIPT" "$@" 2>&1; }

dockerfile_default() { sed -n -E "s/^ARG $1=\"?([^\" ]*)\"?.*/\1/p" "$R/Dockerfile" | head -n1; }
compose_default()    { sed -n -E "s/^[[:space:]]+$1: \\\$\{$1:-([^}]*)\}.*/\1/p" "$R/docker-compose.yml" | head -n1; }
env_value()          { sed -n -E "s/^(# )?$1=(.*)/\2/p" "$R/env.example" | head -n1; }
snapshot()           { cat "$R/Dockerfile" "$R/docker-compose.yml" "$R/env.example" | cksum; }

assert_pin_everywhere() {   # assert_pin_everywhere <CLAVE> <valor>
  assert_eq "$1 en Dockerfile" "$2" "$(dockerfile_default "$1")"
  assert_eq "$1 en compose" "$2" "$(compose_default "$1")"
  assert_eq "$1 en env.example" "$2" "$(env_value "$1")"
}

# ------------------------------------------------------------------- pruebas
t_script_exists_and_has_help() {
  [[ -f "$SCRIPT" ]] && ok || { nok "falta scripts/update-pins.sh"; return 0; }
  local out; out="$(bash "$SCRIPT" --help 2>&1)"
  for w in list choose set latest herdr gentle-ai; do assert_has "ayuda menciona $w" "$out" "$w"; done
}

t_list_herdr_shows_five_stable_versions_newest_first() {
  mk_root
  local out; out="$(pin list herdr)"
  assert_has "0.9.4" "$out" "0.9.4"
  assert_lacks "sin previews" "$out" "preview"
  local order; order="$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 5 | paste -sd' ')"
  assert_eq "orden y cantidad" "0.9.4 0.9.3 0.9.2 0.9.1 0.9.0" "$order"
  assert_lacks "solo 5" "$out" "0.8.9"
}

t_list_accepts_a_custom_count() {
  mk_root
  local out; out="$(pin list herdr 2 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
  assert_eq "2 versiones" "0.9.4 0.9.3" "$out"
}

t_list_gentle_ai_skips_prereleases() {
  mk_root
  local out; out="$(pin list gentle-ai)"
  assert_lacks "sin beta" "$out" "beta"
  assert_eq "orden" "4.1.1 4.1.0 4.0.0 3.7.0 3.6.1" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 5 | paste -sd' ')"
}

t_set_herdr_updates_version_and_both_checksums_everywhere() {
  mk_root
  pin set herdr 0.9.3 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere HERDR_VERSION 0.9.3
  assert_pin_everywhere HERDR_SHA256_AMD64 "$SHA_A"
  assert_pin_everywhere HERDR_SHA256_ARM64 "$SHA_B"
}

t_set_herdr_does_not_touch_other_pins() {
  mk_root
  local before; before="$(dockerfile_default GENTLE_AI_VERSION)|$(dockerfile_default UV_VERSION)|$(dockerfile_default CLAUDE_CODE_VERSION)"
  pin set herdr 0.9.3 >/dev/null
  assert_eq "otros pins intactos" "$before" "$(dockerfile_default GENTLE_AI_VERSION)|$(dockerfile_default UV_VERSION)|$(dockerfile_default CLAUDE_CODE_VERSION)"
}

t_set_herdr_unknown_version_fails_and_changes_nothing() {
  mk_root
  local before; before="$(snapshot)"
  pin set herdr 9.9.9 >/dev/null; local rc=$?
  (( rc != 0 )) && ok || nok "debía fallar con una versión que no existe"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_set_herdr_without_a_linux_binary_fails_and_changes_nothing() {
  mk_root
  local before; before="$(snapshot)"
  local out; out="$(pin set herdr 0.1.0)"; local rc=$?
  (( rc != 0 )) && ok || nok "debía fallar si la release no trae binario linux con checksum"
  assert_has "mensaje claro" "$out" "checksum"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_set_gentle_ai_updates_the_version_everywhere() {
  mk_root
  pin set gentle-ai 4.1.0 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere GENTLE_AI_VERSION 4.1.0
}

t_set_gentle_ai_unknown_version_fails_and_changes_nothing() {
  mk_root
  local before; before="$(snapshot)"
  pin set gentle-ai 0.0.1 >/dev/null; local rc=$?
  (( rc != 0 )) && ok || nok "debía fallar con una versión que no existe"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_set_rejects_a_malformed_version_before_touching_anything() {
  mk_root
  local before; before="$(snapshot)"
  pin set herdr 'v0.9.3; rm -rf /' >/dev/null; local rc=$?
  (( rc != 0 )) && ok || nok "debía rechazar una versión con formato inválido"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_latest_picks_the_newest_stable_without_asking() {
  mk_root
  pin latest herdr </dev/null >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere HERDR_VERSION 0.9.4
  assert_pin_everywhere HERDR_SHA256_AMD64 "$SHA_C"
}

t_latest_all_updates_both_tools() {
  mk_root
  pin set herdr 0.9.3 >/dev/null; pin set gentle-ai 4.1.0 >/dev/null
  pin latest all </dev/null >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere HERDR_VERSION 0.9.4
  assert_pin_everywhere GENTLE_AI_VERSION 4.1.1
}

t_choose_applies_the_selected_version() {
  mk_root
  local out; out="$(printf '2\n' | bash "$SCRIPT" choose herdr 2>&1)"; assert_eq "código de salida" "0" "$?"
  assert_has "muestra la lista" "$out" "0.9.3"
  assert_pin_everywhere HERDR_VERSION 0.9.3
}

t_choose_cancels_on_empty_input() {
  mk_root
  local before; before="$(snapshot)"
  printf '\n' | bash "$SCRIPT" choose herdr >/dev/null 2>&1; assert_eq "cancelar no es error" "0" "$?"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_choose_rejects_an_out_of_range_number() {
  mk_root
  local before; before="$(snapshot)"
  printf '9\n' | bash "$SCRIPT" choose herdr >/dev/null 2>&1; local rc=$?
  (( rc != 0 )) && ok || nok "debía fallar con un número fuera de la lista"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

t_unknown_tool_or_command_fails() {
  mk_root
  pin list nada >/dev/null; (( $? != 0 )) && ok || nok "herramienta desconocida debía fallar"
  pin volar herdr >/dev/null; (( $? != 0 )) && ok || nok "comando desconocido debía fallar"
}

t_a_failed_fetch_changes_nothing() {
  mk_root
  export PINS_FETCH="$TMP/no-existe-fetch.sh"
  local before; before="$(snapshot)"
  pin latest herdr </dev/null >/dev/null; (( $? != 0 )) && ok || nok "sin red debía fallar"
  assert_eq "archivos intactos" "$before" "$(snapshot)"
}

# ------------------------------------------------- v2: todas las herramientas, check, .env y reset
dotenv_value() { sed -n -E "s/^$1=(.*)/\1/p" "$R/.env" | head -n1; }
dotenv_count() { grep -cE "^$1=" "$R/.env" || true; }
tsv_field() {  # tsv_field <id> <columna 1-6> <salida-tsv>
  printf '%s\n' "$3" | awk -F'\t' -v id="$1" -v c="$2" '$1 == id { print $c }'
}
snapshot_files() { cat "$R/Dockerfile" "$R/docker-compose.yml" "$R/env.example" | cksum; }

t_check_tsv_reports_each_tool_with_its_status() {
  mk_root
  local out t; out="$(pin check --tsv)"; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code desactualizado" "2.1.296|2.1.310|outdated" "$(tsv_field claude-code 3 "$out")|$(tsv_field claude-code 4 "$out")|$(tsv_field claude-code 6 "$out")"
  assert_eq "playwright desactualizado" "outdated" "$(tsv_field playwright 6 "$out")"
  assert_eq "mise desactualizado (con v)" "v2026.10.8|v2026.10.9|outdated" "$(tsv_field mise 3 "$out")|$(tsv_field mise 4 "$out")|$(tsv_field mise 6 "$out")"
  assert_eq "doppler desactualizado" "outdated" "$(tsv_field doppler 6 "$out")"
  for t in pi playwright-cli playwright-mcp uv tailscale herdr gentle-ai opencode; do assert_eq "$t al día" "ok" "$(tsv_field "$t" 6 "$out")"; done
  assert_eq "origen del repo" "repo" "$(tsv_field claude-code 5 "$out")"
}

t_check_human_table_has_header_and_summary() {
  mk_root
  local out; out="$(pin check)"
  assert_has "encabezado" "$out" "HERRAMIENTA"
  assert_has "fila" "$out" "claude-code"
  assert_has "resumen" "$out" "4 con versión nueva"
}

t_check_does_not_flag_a_pin_newer_than_latest() {
  mk_root; seed_pin CLAUDE_CODE_VERSION 2.9.9
  assert_eq "más nueva que la última: ok" "ok" "$(tsv_field claude-code 6 "$(pin check --tsv)")"
}

t_check_a_failing_source_is_reported_without_failing_the_rest() {
  mk_root; rm -f "$FIX"/jdx_mise_releases*
  local out; out="$(pin check --tsv)"; assert_eq "no es fatal" "0" "$?"
  assert_eq "mise con error" "error" "$(tsv_field mise 6 "$out")"
  assert_eq "las demás siguen" "outdated" "$(tsv_field claude-code 6 "$out")"
}

t_check_env_target_marks_overrides_and_uses_dotenv_value() {
  mk_root; echo "CLAUDE_CODE_VERSION=2.1.300" >> "$R/.env"
  local out; out="$(pin --target env check --tsv)"
  assert_eq "fijada = valor del .env" "2.1.300" "$(tsv_field claude-code 3 "$out")"
  assert_eq "origen .env" ".env" "$(tsv_field claude-code 5 "$out")"
  assert_eq "los demás vienen del repo" "repo" "$(tsv_field pi 5 "$out")"
}

t_check_env_target_skips_disabled_components() {
  mk_root     # el .env de la prueba trae INSTALL_OPENCODE=false
  local out; out="$(pin --target env check --tsv)"
  assert_eq "opencode omitido" "" "$(tsv_field opencode 1 "$out")"
  printf 'INSTALL_OPENCODE=true\nINSTALL_HERDR=false\nINSTALL_DOPPLER=false\n' >> "$R/.env"
  out="$(pin --target env check --tsv)"
  assert_eq "opencode incluido al activarlo" "opencode" "$(tsv_field opencode 1 "$out")"
  assert_eq "herdr omitido" "" "$(tsv_field herdr 1 "$out")"
  assert_eq "doppler omitido" "" "$(tsv_field doppler 1 "$out")"
  assert_eq "uv siempre" "uv" "$(tsv_field uv 1 "$out")"
}

t_set_env_target_writes_only_to_dotenv() {
  mk_root
  local before; before="$(snapshot_files)"
  pin --target env set claude-code 2.1.300 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_eq "valor en .env" "2.1.300" "$(dotenv_value CLAUDE_CODE_VERSION)"
  assert_eq "archivos del repo intactos" "$before" "$(snapshot_files)"
  assert_eq "otras líneas del .env se conservan" "mi-equipo" "$(dotenv_value TS_HOSTNAME)"
}

t_set_env_target_replaces_instead_of_duplicating() {
  mk_root
  pin --target env set claude-code 2.1.300 >/dev/null; pin --target env set claude-code 2.1.296 >/dev/null
  assert_eq "una sola línea" "1" "$(dotenv_count CLAUDE_CODE_VERSION)"
  assert_eq "último valor" "2.1.296" "$(dotenv_value CLAUDE_CODE_VERSION)"
}

t_set_env_target_requires_an_existing_dotenv() {
  mk_root; rm -f "$R/.env"
  pin --target env set claude-code 2.1.300 >/dev/null; (( $? != 0 )) && ok || nok "sin .env debía fallar"
  [[ ! -e "$R/.env" ]] && ok || nok "no debía crear el .env"
}

t_set_herdr_in_env_target_writes_version_and_both_checksums() {
  mk_root
  pin --target env set herdr 0.9.3 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_eq "versión" "0.9.3" "$(dotenv_value HERDR_VERSION)"
  assert_eq "sha amd64" "$SHA_A" "$(dotenv_value HERDR_SHA256_AMD64)"
  assert_eq "sha arm64" "$SHA_B" "$(dotenv_value HERDR_SHA256_ARM64)"
}

t_set_latest_keyword_resolves_the_newest_version() {
  mk_root
  pin set claude-code latest >/dev/null; assert_pin_everywhere CLAUDE_CODE_VERSION 2.1.310
  pin set herdr latest >/dev/null;       assert_pin_everywhere HERDR_VERSION 0.9.4
}

t_set_npm_unknown_or_prerelease_version_fails_and_changes_nothing() {
  mk_root
  local before; before="$(snapshot_files)"
  pin set claude-code 9.9.9 >/dev/null; (( $? != 0 )) && ok || nok "versión inexistente debía fallar"
  pin set claude-code 2.2.0-beta.1 >/dev/null; (( $? != 0 )) && ok || nok "una prerelease debía rechazarse"
  assert_eq "archivos intactos" "$before" "$(snapshot_files)"
}

t_set_mise_keeps_the_v_prefix_everywhere() {
  mk_root
  pin set mise 2026.10.9 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere MISE_VERSION v2026.10.9
}

t_set_tailscale_updates_compose_and_env_example_but_not_the_dockerfile() {
  mk_root
  local df; df="$(cksum < "$R/Dockerfile")"
  pin set tailscale 1.104.0 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_eq "compose" "1" "$(grep -c 'TS_IMAGE_TAG:-v1.104.0}' "$R/docker-compose.yml")"
  assert_eq "env.example" "v1.104.0" "$(env_value TS_IMAGE_TAG)"
  assert_eq "Dockerfile intacto" "$df" "$(cksum < "$R/Dockerfile")"
}

t_set_uv_doppler_and_the_other_npm_packages() {
  mk_root
  pin set uv 0.12.9 >/dev/null;                assert_pin_everywhere UV_VERSION 0.12.9
  pin set doppler 3.78.0 >/dev/null;           assert_pin_everywhere DOPPLER_VERSION 3.78.0
  pin set playwright 1.65.0 >/dev/null;        assert_pin_everywhere PLAYWRIGHT_VERSION 1.65.0
  pin set playwright-cli 0.1.21 >/dev/null;    assert_pin_everywhere PLAYWRIGHT_CLI_VERSION 0.1.21
  pin set playwright-mcp 0.0.82 >/dev/null;    assert_pin_everywhere PLAYWRIGHT_MCP_VERSION 0.0.82
  pin set pi 0.73.0 >/dev/null;                assert_pin_everywhere PI_VERSION 0.73.0
  pin set opencode 1.18.0 >/dev/null;          assert_pin_everywhere OPENCODE_VERSION 1.18.0
}

t_list_npm_shows_stable_versions_newest_first_without_prereleases() {
  mk_root
  local out; out="$(pin list claude-code 3)"
  assert_lacks "sin beta" "$out" "beta"
  assert_eq "orden" "2.1.310 2.1.300 2.1.296" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
  assert_has "marca la fijada" "$out" "fijada"
}

t_list_mise_shows_values_with_the_v() {
  mk_root
  assert_has "con v" "$(pin list mise 2)" "v2026.10.9"
}

t_reset_removes_only_pin_overrides_from_dotenv() {
  mk_root
  pin --target env set claude-code 2.1.300 >/dev/null; pin --target env set herdr 0.9.3 >/dev/null; pin --target env set mise 2026.10.9 >/dev/null
  local before; before="$(snapshot_files)"
  local out; out="$(pin --target env reset)"; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code sin override" "0" "$(dotenv_count CLAUDE_CODE_VERSION)"
  assert_eq "herdr y sus sha sin override" "0" "$(( $(dotenv_count HERDR_VERSION) + $(dotenv_count HERDR_SHA256_AMD64) + $(dotenv_count HERDR_SHA256_ARM64) ))"
  assert_eq "mise sin override" "0" "$(dotenv_count MISE_VERSION)"
  assert_eq "líneas ajenas intactas" "mi-equipo" "$(dotenv_value TS_HOSTNAME)"
  assert_eq "opencode=false intacto" "false" "$(dotenv_value INSTALL_OPENCODE)"
  assert_eq "archivos del repo intactos" "$before" "$(snapshot_files)"
  assert_has "informa (5 líneas: claude-code, mise y herdr con sus 2 checksums)" "$out" "5 versión"
}

t_reset_needs_the_env_target() {
  mk_root
  pin reset >/dev/null; (( $? != 0 )) && ok || nok "reset sin --target env debía fallar (no debe tocar los archivos del repo)"
}

t_latest_all_in_env_target_updates_enabled_tools_and_skips_disabled_ones() {
  mk_root
  pin --target env latest all </dev/null >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code" "2.1.310" "$(dotenv_value CLAUDE_CODE_VERSION)"
  assert_eq "mise" "v2026.10.9" "$(dotenv_value MISE_VERSION)"
  assert_eq "opencode (desactivado) no se toca" "0" "$(dotenv_count OPENCODE_VERSION)"
}

# ------------------------------------------------- el servidor solo garantiza Docker, git y curl: NADA de perl
# (en Oracle Linux 8 "perl" existe pero JSON::PP no: el script fallaba en silencio con todas las consultas)
noperl_path() {   # PATH con un "perl" falso delante: cualquier uso de perl falla
  local d="$TMP/noperl"; mkdir -p "$d"
  printf '#!/bin/sh\necho "perl no disponible (simulación)" >&2\nexit 127\n' > "$d/perl"; chmod +x "$d/perl"
  echo "$d:$PATH"
}

t_runs_without_perl_check_list_and_set() {
  mk_root
  local P; P="$(noperl_path)"
  local out; out="$(PATH="$P" bash "$SCRIPT" check --tsv 2>&1)"; assert_eq "check sin perl" "0" "$?"
  assert_eq "claude-code desactualizado" "outdated" "$(tsv_field claude-code 6 "$out")"
  assert_eq "herdr al día" "ok" "$(tsv_field herdr 6 "$out")"
  out="$(PATH="$P" bash "$SCRIPT" list claude-code 3 2>&1)"
  assert_eq "list de npm sin perl" "2.1.310 2.1.300 2.1.296" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
  out="$(PATH="$P" bash "$SCRIPT" list herdr 3 2>&1)"
  assert_eq "list de GitHub sin perl" "0.9.4 0.9.3 0.9.2" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
  PATH="$P" bash "$SCRIPT" set herdr 0.9.3 >/dev/null 2>&1; assert_eq "set herdr (repo) sin perl" "0" "$?"
  assert_pin_everywhere HERDR_VERSION 0.9.3
  assert_pin_everywhere HERDR_SHA256_AMD64 "$SHA_A"
  PATH="$P" bash "$SCRIPT" set claude-code latest >/dev/null 2>&1; assert_pin_everywhere CLAUDE_CODE_VERSION 2.1.310
  PATH="$P" bash "$SCRIPT" set mise 2026.10.9 >/dev/null 2>&1; assert_pin_everywhere MISE_VERSION v2026.10.9
  PATH="$P" bash "$SCRIPT" set tailscale 1.104.0 >/dev/null 2>&1; assert_eq "tailscale en compose" "1" "$(grep -c 'TS_IMAGE_TAG:-v1.104.0}' "$R/docker-compose.yml")"
}

t_runs_without_perl_env_target_and_reset() {
  mk_root
  local P; P="$(noperl_path)"
  PATH="$P" bash "$SCRIPT" --target env set claude-code 2.1.300 >/dev/null 2>&1; assert_eq "set --target env sin perl" "0" "$?"
  assert_eq "valor" "2.1.300" "$(dotenv_value CLAUDE_CODE_VERSION)"
  PATH="$P" bash "$SCRIPT" --target env set herdr 0.9.3 >/dev/null 2>&1
  assert_eq "herdr y sus checksums" "0.9.3|$SHA_A|$SHA_B" "$(dotenv_value HERDR_VERSION)|$(dotenv_value HERDR_SHA256_AMD64)|$(dotenv_value HERDR_SHA256_ARM64)"
  PATH="$P" bash "$SCRIPT" --target env latest all </dev/null >/dev/null 2>&1; assert_eq "latest all sin perl" "0" "$?"
  assert_eq "mise" "v2026.10.9" "$(dotenv_value MISE_VERSION)"
  PATH="$P" bash "$SCRIPT" --target env reset >/dev/null 2>&1; assert_eq "reset sin perl" "0" "$?"
  assert_eq "sin overrides" "0" "$(( $(dotenv_count CLAUDE_CODE_VERSION) + $(dotenv_count MISE_VERSION) + $(dotenv_count HERDR_VERSION) ))"
  assert_eq "líneas ajenas intactas" "mi-equipo" "$(dotenv_value TS_HOSTNAME)"
}

t_dotenv_keeps_its_permissions_and_a_missing_final_newline_is_handled() {
  mk_root
  printf 'INSTALL_OPENCODE=false\nTS_HOSTNAME=mi-equipo' > "$R/.env"       # sin salto de línea final
  chmod 600 "$R/.env"
  local P; P="$(noperl_path)"
  PATH="$P" bash "$SCRIPT" --target env set claude-code 2.1.300 >/dev/null 2>&1
  assert_eq "no pega la línea nueva a la anterior" "mi-equipo" "$(dotenv_value TS_HOSTNAME)"
  assert_eq "valor escrito" "2.1.300" "$(dotenv_value CLAUDE_CODE_VERSION)"
  if [[ "$(uname -s)" == Linux ]]; then assert_eq "permisos 600 intactos" "600" "$(stat -c %a "$R/.env")"; else ok; fi
}

# ------------------------------------------------- respuestas REALES capturadas de la API de GitHub
# (JSON con espacios tras los dos puntos, notas de release larguísimas con comillas escapadas, builds "preview-..."):
# los fixtures sintéticos eran compactos y por eso no vieron que el parser fallaba con la API de verdad.
real_fetch() {   # PINS_FETCH que sirve las muestras reales
  local f="$TMP/real-fetch.sh"
  cat > "$f" <<EOS
#!/usr/bin/env bash
d="$ROOT/tests/fixtures"
case "\$1" in
  *herdrdev/herdr/releases/tags/v0.9.3)                 cat "\$d/github-herdr-tag-v0.9.3.json" ;;
  *herdrdev/herdr/releases?per_page*)                   cat "\$d/github-herdr-releases.json" ;;
  *Gentleman-Programming/gentle-ai/releases?per_page*)  cat "\$d/github-gentle-ai-releases.json" ;;
  *) exit 22 ;;
esac
EOS
  chmod +x "$f"; echo "$f"
}

t_parses_real_github_releases_with_spaces_and_previews() {
  mk_root; export PINS_FETCH; PINS_FETCH="$(real_fetch)"
  local out; out="$(pin list herdr 3)"
  assert_eq "herdr: solo estables, la más nueva primero" "0.9.4 0.9.3 0.9.2" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
  assert_lacks "sin builds preview" "$out" "preview"
  out="$(pin list gentle-ai 2)"
  assert_eq "gentle-ai" "4.1.1 4.1.0" "$(printf '%s\n' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | paste -sd' ')"
}

t_real_herdr_digests_are_extracted_from_the_real_release_document() {
  mk_root; export PINS_FETCH; PINS_FETCH="$(real_fetch)"
  pin set herdr 0.9.3 >/dev/null; assert_eq "código de salida" "0" "$?"
  assert_pin_everywhere HERDR_VERSION 0.9.3
  assert_pin_everywhere HERDR_SHA256_AMD64 18a8dc65f1c2fa485884344356dea1cfd911c6f06cf46fa78e193f4087f4dba7
  assert_pin_everywhere HERDR_SHA256_ARM64 4de7aa3e25678812e92960de64f7c2aaa1bca1f0f80a3c5e559837e231e1f5c0
}

t_real_latest_is_the_newest_stable_release() {
  mk_root; export PINS_FETCH; PINS_FETCH="$(real_fetch)"
  rm -f "$R/.env"; printf 'INSTALL_HERDR=true\n' > "$R/.env"
  local out; out="$(pin --target env check --tsv)"
  assert_eq "herdr: la última estable real" "0.9.4" "$(tsv_field herdr 4 "$out")"
  assert_eq "gentle-ai: la última estable real" "4.1.1" "$(tsv_field gentle-ai 4 "$out")"
}

for t in t_script_exists_and_has_help t_list_herdr_shows_five_stable_versions_newest_first t_list_accepts_a_custom_count \
         t_list_gentle_ai_skips_prereleases t_set_herdr_updates_version_and_both_checksums_everywhere \
         t_set_herdr_does_not_touch_other_pins t_set_herdr_unknown_version_fails_and_changes_nothing \
         t_set_herdr_without_a_linux_binary_fails_and_changes_nothing t_set_gentle_ai_updates_the_version_everywhere \
         t_set_gentle_ai_unknown_version_fails_and_changes_nothing t_set_rejects_a_malformed_version_before_touching_anything \
         t_latest_picks_the_newest_stable_without_asking t_latest_all_updates_both_tools t_choose_applies_the_selected_version \
         t_choose_cancels_on_empty_input t_choose_rejects_an_out_of_range_number t_unknown_tool_or_command_fails \
         t_a_failed_fetch_changes_nothing \
         t_check_tsv_reports_each_tool_with_its_status t_check_human_table_has_header_and_summary t_check_does_not_flag_a_pin_newer_than_latest \
         t_check_a_failing_source_is_reported_without_failing_the_rest t_check_env_target_marks_overrides_and_uses_dotenv_value t_check_env_target_skips_disabled_components \
         t_set_env_target_writes_only_to_dotenv t_set_env_target_replaces_instead_of_duplicating t_set_env_target_requires_an_existing_dotenv \
         t_set_herdr_in_env_target_writes_version_and_both_checksums t_set_latest_keyword_resolves_the_newest_version t_set_npm_unknown_or_prerelease_version_fails_and_changes_nothing \
         t_set_mise_keeps_the_v_prefix_everywhere t_set_tailscale_updates_compose_and_env_example_but_not_the_dockerfile t_set_uv_doppler_and_the_other_npm_packages \
         t_list_npm_shows_stable_versions_newest_first_without_prereleases t_list_mise_shows_values_with_the_v t_reset_removes_only_pin_overrides_from_dotenv \
         t_reset_needs_the_env_target t_latest_all_in_env_target_updates_enabled_tools_and_skips_disabled_ones \
         t_runs_without_perl_check_list_and_set t_runs_without_perl_env_target_and_reset t_dotenv_keeps_its_permissions_and_a_missing_final_newline_is_handled \
         t_parses_real_github_releases_with_spaces_and_previews t_real_herdr_digests_are_extracted_from_the_real_release_document t_real_latest_is_the_newest_stable_release; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
