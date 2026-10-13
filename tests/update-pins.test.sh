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
SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # amd64 de 0.9.3
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"   # arm64 de 0.9.3
SHA_C="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"   # amd64 de 0.9.4
SHA_D="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"   # arm64 de 0.9.4

herdr_rel() {   # herdr_rel <tag> <amd64> <arm64> [prerelease]
  printf '{"tag_name":"%s","prerelease":%s,"published_at":"2026-10-0%sT10:00:00Z","assets":[{"name":"herdr-linux-aarch64","digest":"sha256:%s"},{"name":"herdr-linux-x86_64","digest":"sha256:%s"},{"name":"herdr-macos-x86_64","digest":"sha256:%s"}]}' \
    "$1" "${4:-false}" "$((RANDOM % 9 + 1))" "$3" "$2" "$2"
}

mk_fixtures() {
  FIX="$TMP/fix.$RANDOM"; mkdir -p "$FIX"
  local p="releases?per_page=30"
  {
    echo "["
    herdr_rel v0.9.4 "$SHA_C" "$SHA_D"; echo ","
    herdr_rel preview-2026-10-12-6d697e1e75ff "$SHA_C" "$SHA_D" true; echo ","
    herdr_rel v0.9.3 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.9.2 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel preview-2026-09-29-9dc3a1df2b56 "$SHA_A" "$SHA_B" true; echo ","
    herdr_rel v0.9.1 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.9.0 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.8.9 "$SHA_A" "$SHA_B"
    echo "]"
  } > "$FIX/herdrdev_herdr_$p"
  herdr_rel v0.9.3 "$SHA_A" "$SHA_B" > "$FIX/herdrdev_herdr_releases_tags_v0.9.3"
  herdr_rel v0.9.4 "$SHA_C" "$SHA_D" > "$FIX/herdrdev_herdr_releases_tags_v0.9.4"
  printf '{"tag_name":"v0.1.0","prerelease":false,"assets":[{"name":"herdr-macos-x86_64","digest":"sha256:%s"}]}' "$SHA_A" > "$FIX/herdrdev_herdr_releases_tags_v0.1.0"   # sin binario linux
  cat > "$FIX/Gentleman-Programming_gentle-ai_$p" <<'EOF'
[{"tag_name":"v4.2.0-beta.1","prerelease":true,"published_at":"2026-10-12T10:00:00Z"},
 {"tag_name":"v4.1.1","prerelease":false,"published_at":"2026-10-10T10:00:00Z"},
 {"tag_name":"v4.1.0","prerelease":false,"published_at":"2026-10-01T10:00:00Z"},
 {"tag_name":"v4.0.0","prerelease":false,"published_at":"2026-09-20T10:00:00Z"},
 {"tag_name":"v3.7.0","prerelease":false,"published_at":"2026-09-10T10:00:00Z"},
 {"tag_name":"v3.6.1","prerelease":false,"published_at":"2026-09-01T10:00:00Z"},
 {"tag_name":"v3.6.0","prerelease":false,"published_at":"2026-08-20T10:00:00Z"}]
EOF
  echo '{"tag_name":"v4.1.0","prerelease":false}' > "$FIX/Gentleman-Programming_gentle-ai_releases_tags_v4.1.0"
  echo '{"tag_name":"v4.1.1","prerelease":false}' > "$FIX/Gentleman-Programming_gentle-ai_releases_tags_v4.1.1"
  # "curl" falso: la URL se convierte en el nombre del archivo de fixtures; si no existe, falla como un 404
  cat > "$FIX/fetch.sh" <<EOF
#!/usr/bin/env bash
f="$FIX/\$(printf '%s' "\$1" | sed 's#https://api.github.com/repos/##; s#[/]#_#g')"
[[ -f "\$f" ]] && cat "\$f" || exit 22
EOF
  chmod +x "$FIX/fetch.sh"
}

# Copia de los tres archivos que el script reescribe, con los valores actuales del repo
mk_root() {
  mk_fixtures
  R="$TMP/root.$RANDOM"; mkdir -p "$R"
  cp "$ROOT/Dockerfile" "$ROOT/docker-compose.yml" "$ROOT/env.example" "$R/"
  export PINS_ROOT="$R" PINS_FETCH="$FIX/fetch.sh"
}
pin() { bash "$SCRIPT" "$@" 2>&1; }

dockerfile_default() { sed -n -E "s/^ARG $1=\"?([^\" ]*)\"?.*/\1/p" "$R/Dockerfile" | head -n1; }
compose_default()    { sed -n -E "s/^[[:space:]]+$1: \\\$\{$1:-([^}]*)\}.*/\1/p" "$R/docker-compose.yml" | head -n1; }
env_value()          { sed -n -E "s/^$1=(.*)/\1/p" "$R/env.example" | head -n1; }
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

for t in t_script_exists_and_has_help t_list_herdr_shows_five_stable_versions_newest_first t_list_accepts_a_custom_count \
         t_list_gentle_ai_skips_prereleases t_set_herdr_updates_version_and_both_checksums_everywhere \
         t_set_herdr_does_not_touch_other_pins t_set_herdr_unknown_version_fails_and_changes_nothing \
         t_set_herdr_without_a_linux_binary_fails_and_changes_nothing t_set_gentle_ai_updates_the_version_everywhere \
         t_set_gentle_ai_unknown_version_fails_and_changes_nothing t_set_rejects_a_malformed_version_before_touching_anything \
         t_latest_picks_the_newest_stable_without_asking t_latest_all_updates_both_tools t_choose_applies_the_selected_version \
         t_choose_cancels_on_empty_input t_choose_rejects_an_out_of_range_number t_unknown_tool_or_command_fails \
         t_a_failed_fetch_changes_nothing; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
