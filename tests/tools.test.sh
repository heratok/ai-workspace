#!/usr/bin/env bash
# =============================================================================
# Pruebas de "./setup.sh tools" (lib/tools.sh): buscar versiones nuevas de las herramientas,
# elegir cuáles aplicar (se guardan en el .env) y el aviso al abrir el menú.
#
#   bash tests/tools.test.sh
#
# Sin red ni Docker real: GitHub/npm se simulan (PINS_FETCH) y "docker" es un falso que solo
# responde por la etiqueta de versiones de la imagen. Cada prueba usa una copia temporal del repo.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# shellcheck source=tests/helpers/pins-fixtures.sh
source "$ROOT/tests/helpers/pins-fixtures.sh"

# ------------------------------------------------------------------- sandbox
# Copia del repo (SCRIPT_DIR propio), .env con pines CONOCIDOS, "docker" falso (etiqueta de la imagen) y APIs simuladas.
seed() {   # seed <CLAVE> <valor>: fija el valor en Dockerfile, compose y env.example de la copia
  K="$1" V="$2" perl -pi -e 's/^ARG \Q$ENV{K}\E=.*/ARG $ENV{K}=$ENV{V}/; s/(\$\{\Q$ENV{K}\E:-)[^}]*(\})/$1$ENV{V}$2/g; s/^((?:# )?)\Q$ENV{K}\E=.*/$1$ENV{K}=$ENV{V}/' "$SB/repo/Dockerfile" "$SB/repo/docker-compose.yml" "$SB/repo/env.example"
}
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake" "$SB/repo"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
# docker falso: solo contesta por la etiqueta de versiones de la imagen ($FAKE_DOCKER_DIR/label)
if [[ "${1:-} ${2:-}" == "image inspect" ]]; then
  [[ -f "$FAKE_DOCKER_DIR/label" ]] && cat "$FAKE_DOCKER_DIR/label" || exit 1
  exit 0
fi
exit 0
EOF
  chmod +x "$SB/bin/docker"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/scripts" "$ROOT/Dockerfile" "$ROOT/docker-compose.yml" "$ROOT/env.example" "$SB/repo/"
  seed CLAUDE_CODE_VERSION 2.1.296; seed PI_VERSION 0.73.1; seed OPENCODE_VERSION 1.19.0
  seed PLAYWRIGHT_VERSION 1.64.0; seed PLAYWRIGHT_CLI_VERSION 0.1.22; seed PLAYWRIGHT_MCP_VERSION 0.0.83
  seed UV_VERSION 0.13.0; seed MISE_VERSION v2026.10.8; seed TS_IMAGE_TAG v1.104.1
  seed HERDR_VERSION 0.9.4; seed HERDR_SHA256_AMD64 "$SHA_C"; seed HERDR_SHA256_ARM64 "$SHA_D"
  seed GENTLE_AI_VERSION 4.1.1; seed DOPPLER_VERSION 3.77.0
  cp "$SB/repo/env.example" "$SB/repo/.env"
  pins_fixtures    # crea $FIX y $FIX/fetch.sh (latest: claude-code 2.1.310, playwright 1.65.0, mise v2026.10.9, doppler 3.78.0; el resto al día)
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH" PINS_FETCH="$FIX/fetch.sh" AIWS_TOOLS_CACHE_TTL=43200 AIWS_TOOLS_CHECK_TIMEOUT=60
  unset AIWS_NO_TOOLS_CHECK
}
load_tools() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"
  set +eEu; trap - ERR
  has_tty() { return 0; }                                   # las pruebas alimentan las preguntas por stdin
  tools_rebuild() { echo rebuild >> "$SB/rebuilds.log"; }   # no se reconstruye nada de verdad
  ENVF="$SB/repo/.env"; CACHE="$SB/repo/logs/.tools-check"
}
dotenv() { sed -n -E "s/^$1=(.*)/\1/p" "$ENVF" | tail -n1; }
rebuilds() { cat "$SB/rebuilds.log" 2>/dev/null | wc -l | tr -d ' '; }
repo_sum() { cat "$SB/repo/Dockerfile" "$SB/repo/docker-compose.yml" "$SB/repo/env.example" | cksum; }

# ------------------------------------------------------------------- tabla y selección
t_tools_shows_the_table_with_outdated_tools() {
  load_tools
  local out; out="$(printf '\n' | tools_cmd 2>&1)"
  assert_has "encabezado" "$out" "HERRAMIENTA"
  assert_has "claude-code" "$out" "2.1.310"
  assert_has "mise con v" "$out" "v2026.10.9"
  assert_has "estado" "$out" "nueva versión"
  assert_has "resumen" "$out" "4 con versión nueva"
}

t_tools_enter_means_no_changes() {
  load_tools
  local before; before="$(cat "$ENVF" | cksum)"
  printf '\n' | tools_cmd >/dev/null 2>&1; assert_eq "no es un error" "0" "$?"
  assert_eq ".env intacto" "$before" "$(cat "$ENVF" | cksum)"
  assert_eq "sin reconstruir" "0" "$(rebuilds)"
}

t_tools_applies_the_chosen_numbers_to_dotenv_only() {
  load_tools
  local before; before="$(repo_sum)"
  # outdated en orden: 1 claude-code, 2 playwright, 3 mise, 4 doppler
  printf '1,3\nn\n' | tools_cmd >/dev/null 2>&1; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code en .env" "2.1.310" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "mise en .env (con v)" "v2026.10.9" "$(dotenv MISE_VERSION)"
  assert_eq "playwright no elegido: no se escribe nada en el .env" "" "$(dotenv PLAYWRIGHT_VERSION)"
  assert_eq "archivos del repo intactos" "$before" "$(repo_sum)"
  assert_eq "no reconstruyó (respondí n)" "0" "$(rebuilds)"
}

t_tools_t_selects_everything_outdated() {
  load_tools
  printf 't\nn\n' | tools_cmd >/dev/null 2>&1
  assert_eq "claude-code" "2.1.310" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "playwright" "1.65.0" "$(dotenv PLAYWRIGHT_VERSION)"
  assert_eq "mise" "v2026.10.9" "$(dotenv MISE_VERSION)"
  assert_eq "doppler" "3.78.0" "$(dotenv DOPPLER_VERSION)"
  assert_eq "uv (al día) no se escribe en el .env" "" "$(dotenv UV_VERSION)"
}

t_tools_offers_the_rebuild_after_applying() {
  load_tools
  printf '1\ns\n' | tools_cmd >/dev/null 2>&1
  assert_eq "reconstruyó al confirmar" "1" "$(rebuilds)"
}

t_tools_rejects_an_invalid_selection_without_changing_anything() {
  load_tools
  local before; before="$(cat "$ENVF" | cksum)"
  printf '9\n' | tools_cmd >/dev/null 2>&1; (( $? != 0 )) && ok || nok "un número fuera de la lista debía fallar"
  printf 'abc\n' | tools_cmd >/dev/null 2>&1; (( $? != 0 )) && ok || nok "texto no numérico debía fallar"
  assert_eq ".env intacto" "$before" "$(cat "$ENVF" | cksum)"
}

t_tools_yes_updates_everything_and_rebuilds_without_asking() {
  load_tools
  tools_cmd --yes </dev/null >/dev/null 2>&1; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code" "2.1.310" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "doppler" "3.78.0" "$(dotenv DOPPLER_VERSION)"
  assert_eq "reconstruyó" "1" "$(rebuilds)"
}

t_tools_all_up_to_date() {
  load_tools
  printf 'CLAUDE_CODE_VERSION=2.1.310\nPLAYWRIGHT_VERSION=1.65.0\nMISE_VERSION=v2026.10.9\nDOPPLER_VERSION=3.78.0\n' >> "$ENVF"
  local out; out="$(tools_cmd </dev/null 2>&1)"
  assert_has "todo al día" "$out" "al día"
  assert_lacks "no ofrece elegir" "$out" "Elige"
  assert_eq "sin reconstruir" "0" "$(rebuilds)"
}

t_tools_marks_the_origin_dotenv() {
  load_tools; echo "CLAUDE_CODE_VERSION=2.1.300" >> "$ENVF"
  assert_has "origen .env" "$(printf '\n' | tools_cmd 2>&1)" ".env"
}

t_tools_skips_disabled_components() {
  load_tools
  local out; out="$(printf '\n' | tools_cmd 2>&1)"
  assert_lacks "opencode desactivado por defecto" "$out" "opencode"
  printf 'INSTALL_OPENCODE=true\n' >> "$ENVF"
  assert_has "opencode al activarlo" "$(printf '\n' | tools_cmd 2>&1)" "opencode"
}

t_tools_shows_what_is_really_in_the_image() {
  load_tools
  echo "claude-code=2.1.290,pi=0.73.1,uv=0.13.0,mise=v2026.10.8,herdr=0.9.4,gentle-ai=4.1.1,doppler=3.77.0" > "$SB/fake/label"
  local out; out="$(printf '\n' | tools_cmd 2>&1)"
  assert_has "versión de la imagen" "$out" "2.1.290"
  assert_has "columna" "$out" "EN IMAGEN"
}

t_tools_flags_a_pending_rebuild_when_dotenv_differs_from_the_image() {
  load_tools
  echo "pi=0.73.0" > "$SB/fake/label"       # la imagen tiene pi 0.73.0 pero el .env/repo fijan 0.73.1
  assert_has "reconstruir" "$(printf '\n' | tools_cmd 2>&1)" "reconstruir"
}

t_tools_without_an_image_shows_a_dash_and_still_works() {
  load_tools
  rm -f "$SB/fake/label"
  local out; out="$(printf '\n' | tools_cmd 2>&1)"; assert_eq "código de salida" "0" "$?"
  assert_has "sin imagen" "$out" "-"
}

# ------------------------------------------------------------------- reset y errores
t_tools_reset_removes_the_overrides_and_offers_a_rebuild() {
  load_tools
  printf 'CLAUDE_CODE_VERSION=2.1.300\nHERDR_VERSION=0.9.3\nHERDR_SHA256_AMD64=%s\nHERDR_SHA256_ARM64=%s\n' "$SHA_A" "$SHA_B" >> "$ENVF"
  local before_other; before_other="$(dotenv TS_HOSTNAME)"
  printf 's\n' | tools_cmd --reset >/dev/null 2>&1; assert_eq "código de salida" "0" "$?"
  assert_eq "claude-code sin override" "" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "herdr sin override" "" "$(dotenv HERDR_VERSION)$(dotenv HERDR_SHA256_AMD64)$(dotenv HERDR_SHA256_ARM64)"
  assert_eq "otras variables intactas" "$before_other" "$(dotenv TS_HOSTNAME)"
  assert_eq "ofreció reconstruir" "1" "$(rebuilds)"
}

t_tools_without_dotenv_explains_what_to_do() {
  load_tools; rm -f "$ENVF"
  local out; out="$(tools_cmd </dev/null 2>&1)"; local rc=$?
  (( rc != 0 )) && ok || nok "sin .env debía fallar"
  assert_has "pista" "$out" "install"
}

t_tools_rejects_unknown_options() {
  load_tools
  ( tools_cmd --nope </dev/null >/dev/null 2>&1 ); (( $? != 0 )) && ok || nok "opción desconocida debía fallar"
}

t_tools_without_a_terminal_requires_yes() {
  load_tools
  has_tty() { return 1; }
  local out; out="$(tools_cmd </dev/null 2>&1)"; local rc=$?
  (( rc != 0 )) && ok || nok "sin terminal y sin --yes debía fallar"
  assert_has "explica" "$out" "--yes"
}

t_tools_survives_a_failing_source() {
  load_tools; rm -f "$FIX"/jdx_mise_releases*
  local out; out="$(printf '\n' | tools_cmd 2>&1)"; assert_eq "no es fatal" "0" "$?"
  assert_has "sin respuesta" "$out" "sin respuesta"
}

# ------------------------------------------------------------------- aviso al abrir el menú
now() { date +%s; }
write_cache() {   # write_cache <epoch> <outdated-count>
  mkdir -p "$SB/repo/logs"
  { echo "$1"; local i; for ((i = 0; i < $2; i++)); do printf 'tool%s\tTool\t1.0.0\t2.0.0\trepo\toutdated\n' "$i"; done; printf 'okay\tOk\t1.0.0\t1.0.0\trepo\tok\n'; } > "$CACHE"
}

t_notice_uses_a_fresh_cache_without_touching_the_network() {
  load_tools
  write_cache "$(now)" 2
  export PINS_FETCH="$TMP/no-existe.sh"     # si intentara la red, fallaría
  assert_has "avisa" "$(tools_notice 2>&1)" "2 herramienta"
}

t_notice_refreshes_a_stale_cache() {
  load_tools
  write_cache "$(( $(now) - 100000 ))" 0
  local out; out="$(tools_notice 2>&1)"
  assert_has "avisa con datos nuevos" "$out" "4 herramienta"
  local ts; ts="$(head -n1 "$CACHE")"
  (( ts > $(now) - 60 )) && ok || nok "la caché debía quedar con marca de tiempo nueva"
}

t_notice_is_silent_and_harmless_when_the_check_fails() {
  load_tools
  export PINS_FETCH="$TMP/no-existe.sh"
  local out; out="$(tools_notice 2>&1)"; local rc=$?
  assert_eq "no avisa" "" "$out"
  assert_eq "no falla" "0" "$rc"
}

t_notice_falls_back_to_a_stale_cache_when_offline() {
  load_tools
  write_cache "$(( $(now) - 100000 ))" 3
  export PINS_FETCH="$TMP/no-existe.sh"
  assert_has "usa lo último conocido" "$(tools_notice 2>&1)" "3 herramienta"
}

t_notice_says_nothing_when_everything_is_up_to_date() {
  load_tools
  write_cache "$(now)" 0
  assert_eq "silencio" "" "$(tools_notice 2>&1)"
}

t_notice_can_be_disabled() {
  load_tools
  write_cache "$(now)" 2
  export AIWS_NO_TOOLS_CHECK=1
  assert_eq "silencio" "" "$(tools_notice 2>&1)"
}

t_notice_never_blocks_longer_than_its_timeout() {
  load_tools
  printf '#!/usr/bin/env bash\nsleep 8\n' > "$TMP/lento.sh"; chmod +x "$TMP/lento.sh"
  export PINS_FETCH="$TMP/lento.sh" AIWS_TOOLS_CHECK_TIMEOUT=1
  local t0 t1; t0="$(now)"; tools_notice >/dev/null 2>&1; t1="$(now)"
  (( t1 - t0 <= 5 )) && ok || nok "el aviso tardó $(( t1 - t0 )) s con un tope de 1 s"
}

t_notice_does_not_retry_right_after_a_failed_check() {   # sin red, abrir el menú muchas veces no debe costar 4 s cada vez
  load_tools
  printf '#!/usr/bin/env bash\necho x >> "%s/intentos"\nexit 22\n' "$SB" > "$TMP/cuenta.sh"; chmod +x "$TMP/cuenta.sh"
  export PINS_FETCH="$TMP/cuenta.sh"
  tools_notice >/dev/null 2>&1
  local first; first="$(wc -l < "$SB/intentos" 2>/dev/null | tr -d ' ')"
  tools_notice >/dev/null 2>&1; tools_notice >/dev/null 2>&1
  assert_eq "los reintentos inmediatos no consultan otra vez" "$first" "$(wc -l < "$SB/intentos" | tr -d ' ')"
  (( first > 0 )) && ok || nok "el primer intento sí debía consultar"
}

t_notice_needs_an_installed_instance() {
  load_tools; rm -f "$ENVF"
  assert_eq "sin .env no consulta" "" "$(tools_notice 2>&1)"
}

t_menu_shows_the_notice_and_the_new_option() {
  load_tools
  write_cache "$(now)" 2
  main() { echo "main $*" >> "$SB/main.log"; }      # el menú delega en main
  local out; out="$(echo 11 | menu 2>&1)"
  assert_has "aviso en el menú" "$out" "2 herramienta"
  assert_has "opción 11" "$out" "11) Buscar actualizaciones de herramientas"
  assert_eq "la opción 11 llama a tools" "main tools" "$(cat "$SB/main.log" 2>/dev/null)"
}

t_main_dispatches_the_tools_command() {
  load_tools
  local out; out="$(main tools --nope </dev/null 2>&1)"; local rc=$?
  (( rc != 0 )) && ok || nok "main tools con opción inválida debía fallar"
  assert_has "llegó a tools_cmd" "$out" "--nope"
}

t_help_and_aiws_know_about_tools() {
  load_tools
  assert_has "ayuda de setup.sh" "$(bash "$SB/repo/setup.sh" help 2>&1)" "tools"
  grep -q '^  "tools|' "$ROOT/aiws" && ok || nok "aiws debe delegar el comando tools"
}

# ------------------------------------------------------------------- .env sin versiones congeladas
MIGRATION="$ROOT/migrations/003-versiones-fijadas-fuera-del-env.sh"
run_migration() {   # como run_migrations: subproceso con las funciones de setup.sh cargadas
  ( cd "$SB/repo" && bash -c 'set -Eeuo pipefail; source "$1"; source "$2"' _ "$SB/repo/setup.sh" "$MIGRATION" ) 2>&1
}

t_a_fresh_dotenv_copied_from_env_example_has_no_pins() {
  load_tools   # el .env de la prueba es una copia de env.example: no debe traer versiones activas
  local k
  for k in CLAUDE_CODE_VERSION PI_VERSION MISE_VERSION HERDR_VERSION HERDR_SHA256_AMD64 GENTLE_AI_VERSION DOPPLER_VERSION TS_IMAGE_TAG; do
    assert_eq "$k no se copia al .env" "" "$(dotenv "$k")"
  done
  local out; out="$(printf '\n' | tools_cmd 2>&1)"
  assert_lacks "ningún origen .env" "$out" ".env    "
  assert_has "origen repo" "$out" "repo"
}

t_migration_removes_pins_equal_to_the_repo_defaults_and_keeps_the_rest() {
  load_tools; [[ -f "$MIGRATION" ]] || { nok "falta migrations/003-versiones-fijadas-fuera-del-env.sh"; return 0; }
  local host_before; host_before="$(dotenv TS_HOSTNAME)"
  printf 'CLAUDE_CODE_VERSION=2.1.296\nPI_VERSION=0.70.0\nMISE_VERSION=v2026.10.8\nTS_IMAGE_TAG=v1.104.1\nGENTLE_AI_VERSION=4.0.0\n' >> "$ENVF"
  local out; out="$(run_migration)"; assert_eq "código de salida" "0" "$?"
  assert_eq "igual al repo: se quita (claude-code)" "" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "igual al repo: se quita (mise)" "" "$(dotenv MISE_VERSION)"
  assert_eq "igual al repo: se quita (tailscale)" "" "$(dotenv TS_IMAGE_TAG)"
  assert_eq "distinta del repo: se conserva (pi)" "0.70.0" "$(dotenv PI_VERSION)"
  assert_eq "distinta del repo: se conserva (gentle-ai)" "4.0.0" "$(dotenv GENTLE_AI_VERSION)"
  assert_has "avisa de lo que conserva" "$out" "PI_VERSION"
  assert_eq "otras variables intactas" "$host_before" "$(dotenv TS_HOSTNAME)"
}

t_migration_handles_the_herdr_group_as_a_unit() {
  load_tools; [[ -f "$MIGRATION" ]] || { nok "falta la migración 003"; return 0; }
  printf 'HERDR_VERSION=0.9.4\nHERDR_SHA256_AMD64=%s\nHERDR_SHA256_ARM64=%s\n' "$SHA_C" "$SHA_D" >> "$ENVF"
  run_migration >/dev/null
  assert_eq "grupo igual al repo: se quita completo" "" "$(dotenv HERDR_VERSION)$(dotenv HERDR_SHA256_AMD64)$(dotenv HERDR_SHA256_ARM64)"
  printf 'HERDR_VERSION=0.9.3\nHERDR_SHA256_AMD64=%s\nHERDR_SHA256_ARM64=%s\n' "$SHA_A" "$SHA_B" >> "$ENVF"
  run_migration >/dev/null
  assert_eq "versión distinta: se conservan versión y checksums juntos" "0.9.3|$SHA_A|$SHA_B" "$(dotenv HERDR_VERSION)|$(dotenv HERDR_SHA256_AMD64)|$(dotenv HERDR_SHA256_ARM64)"
}

t_migration_is_idempotent_and_survives_a_missing_dotenv() {
  load_tools; [[ -f "$MIGRATION" ]] || { nok "falta la migración 003"; return 0; }
  printf 'PI_VERSION=0.70.0\n' >> "$ENVF"
  run_migration >/dev/null; local once; once="$(cksum < "$ENVF")"
  run_migration >/dev/null; assert_eq "segunda ejecución sin cambios" "$once" "$(cksum < "$ENVF")"
  rm -f "$ENVF"; run_migration >/dev/null; assert_eq "sin .env no falla" "0" "$?"
}

t_after_the_migration_tools_marks_the_kept_pin_as_an_override() {
  load_tools; [[ -f "$MIGRATION" ]] || { nok "falta la migración 003"; return 0; }
  printf 'PI_VERSION=0.70.0\n' >> "$ENVF"; run_migration >/dev/null
  local out; out="$(printf '\n' | tools_cmd 2>&1)"
  assert_has "pi con origen .env" "$out" "0.70.0"
}

# ------------------------------------------------- sin perl en el servidor (solo Docker, git y curl están garantizados)
t_tools_menu_notice_and_migration_work_without_perl() {
  load_tools
  local d="$TMP/noperl"; mkdir -p "$d"
  printf '#!/bin/sh\necho "perl no disponible (simulación)" >&2\nexit 127\n' > "$d/perl"; chmod +x "$d/perl"
  export PATH="$d:$PATH"
  local out; out="$(printf '1,3\nn\n' | tools_cmd 2>&1)"; assert_eq "tools sin perl" "0" "$?"
  assert_has "tabla" "$out" "HERRAMIENTA"
  assert_eq "claude-code en .env" "2.1.310" "$(dotenv CLAUDE_CODE_VERSION)"
  assert_eq "mise en .env" "v2026.10.9" "$(dotenv MISE_VERSION)"
  printf 's\n' | tools_cmd --reset >/dev/null 2>&1; assert_eq "reset sin perl" "0" "$?"
  assert_eq "reset quitó claude-code" "" "$(dotenv CLAUDE_CODE_VERSION)"
  rm -f "$CACHE"; rm -f "$SB/repo/logs/.tools-check-try"
  assert_has "aviso sin perl" "$(tools_notice 2>&1)" "herramienta"
  printf 'PI_VERSION=0.73.1\nMISE_VERSION=v2026.10.8\n' >> "$ENVF"
  run_migration >/dev/null 2>&1; assert_eq "migración sin perl" "0" "$?"
  assert_eq "la migración quitó lo igual al repo" "" "$(dotenv PI_VERSION)"
}

for t in t_tools_shows_the_table_with_outdated_tools t_tools_enter_means_no_changes \
         t_tools_applies_the_chosen_numbers_to_dotenv_only t_tools_t_selects_everything_outdated \
         t_tools_offers_the_rebuild_after_applying t_tools_rejects_an_invalid_selection_without_changing_anything \
         t_tools_yes_updates_everything_and_rebuilds_without_asking t_tools_all_up_to_date t_tools_marks_the_origin_dotenv \
         t_tools_skips_disabled_components t_tools_shows_what_is_really_in_the_image \
         t_tools_flags_a_pending_rebuild_when_dotenv_differs_from_the_image t_tools_without_an_image_shows_a_dash_and_still_works \
         t_tools_reset_removes_the_overrides_and_offers_a_rebuild t_tools_without_dotenv_explains_what_to_do \
         t_tools_rejects_unknown_options t_tools_without_a_terminal_requires_yes t_tools_survives_a_failing_source \
         t_notice_uses_a_fresh_cache_without_touching_the_network t_notice_refreshes_a_stale_cache \
         t_notice_is_silent_and_harmless_when_the_check_fails t_notice_falls_back_to_a_stale_cache_when_offline \
         t_notice_says_nothing_when_everything_is_up_to_date t_notice_can_be_disabled \
         t_notice_never_blocks_longer_than_its_timeout t_notice_does_not_retry_right_after_a_failed_check t_notice_needs_an_installed_instance \
         t_menu_shows_the_notice_and_the_new_option t_main_dispatches_the_tools_command t_help_and_aiws_know_about_tools \
         t_a_fresh_dotenv_copied_from_env_example_has_no_pins t_migration_removes_pins_equal_to_the_repo_defaults_and_keeps_the_rest \
         t_migration_handles_the_herdr_group_as_a_unit t_migration_is_idempotent_and_survives_a_missing_dotenv \
         t_after_the_migration_tools_marks_the_kept_pin_as_an_override t_tools_menu_notice_and_migration_work_without_perl; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
