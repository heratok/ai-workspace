#!/usr/bin/env bash
# =============================================================================
# Pruebas de la división de setup.sh en módulos (lib/) y del lint a nivel warning.
#
#   bash tests/modules.test.sh
#
# Estáticas (sin Docker). Las suites de comportamiento (instances, aiws, restore...)
# siguen siendo las que garantizan que el movimiento no cambió nada.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$ROOT/setup.sh"
LIB="$ROOT/lib"
CI="$ROOT/.github/workflows/ci.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

MODULES=(common instances config lifecycle background resources components maintenance backup uninstall tools)

# Funciones que existían en el setup.sh monolítico (ninguna puede perderse ni duplicarse al mover)
BASELINE_FUNCTIONS="
  add_key alias_error ask_res ask_value backup backup_volumes bg_entry bg_running bind_alias build_and_up 
  check_files check_instance_owner check_prereqs choose_components clean collect_pubkey comp_value 
  components_cmd compose configure_env confirm container_owner create_volumes default_pubkey die doctor 
  ensure_secrets env_del env_get env_set existing_instance_count follow forget_authkey g gen_secret has_tty 
  host_cpus host_mem_kb info install_aiws_link install_steps instance_names is_own_backup_name is_writable 
  keep_newest latest_backup main mem_to_mb menu normalize_line_endings other_instance_dirs other_instances 
  profile_on registry_add registry_file registry_remove report_status res_check res_prompt resolve_backup 
  resources resources_apply resources_show restore rollback run_bg run_migrations run_update same_dir 
  size_resources suggest_cpus suggest_mem suggest_mem_is_tiny sum_mem_limits_mb summary ts_ip 
  ts_logged_in_before ts_wait_login uninstall update_steps upgrade upgrade_result usage validate_backup 
  wait_healthy wait_services warn warn_mem_over_host warn_root_clone write_instance_env
"

all_sources() { echo "$SETUP"; local m; for m in "${MODULES[@]}"; do echo "$LIB/$m.sh"; done; }

t_every_module_exists_and_parses() {
  local m
  for m in "${MODULES[@]}"; do
    if [[ -s "$LIB/$m.sh" ]]; then ok; else nok "falta lib/$m.sh"; continue; fi
    bash -n "$LIB/$m.sh" 2>/dev/null && ok || nok "lib/$m.sh no pasa bash -n"
    head -n 5 "$LIB/$m.sh" | grep -q '# shellcheck shell=bash' && ok || nok "lib/$m.sh sin '# shellcheck shell=bash' en la cabecera"
  done
}

t_setup_is_a_thin_entry_point() {
  local n; n="$(wc -l < "$SETUP")"
  (( n <= 260 )) && ok || nok "setup.sh tiene $n líneas (máximo 260: la lógica va en lib/)"
}

t_setup_sources_every_module_in_order() {
  local m prev=0 line
  for m in "${MODULES[@]}"; do
    line="$(grep -n "lib/$m.sh\"" "$SETUP" | grep -v 'shellcheck' | head -n1 | cut -d: -f1)"
    if [[ -z "$line" ]]; then nok "setup.sh no carga lib/$m.sh"; continue; fi
    (( line > prev )) && ok || nok "lib/$m.sh se carga fuera de orden (el orden original de las asignaciones globales importa)"
    prev="$line"
  done
}

t_setup_guards_against_a_missing_lib() {
  grep -q 'lib/common.sh' "$SETUP" && grep -qE '\[\[ -d "\$SCRIPT_DIR/lib" \]\]|\[\[ -f "\$SCRIPT_DIR/lib/common.sh" \]\]' "$SETUP" && ok || nok "setup.sh debe comprobar que lib/ existe antes de cargarla"
}

t_setup_exits_right_after_main() {   # "upgrade" reemplaza setup.sh mientras corre: tras main no debe leer más del archivo
  tail -n 3 "$SETUP" | grep -qE 'main "\$@"; exit' && ok || nok "setup.sh debe terminar con 'main \"\$@\"; exit' (si no, tras un upgrade bash leería bytes de otra versión del archivo)"
}

t_every_baseline_function_is_defined_exactly_once() {
  local fn defs srcs; mapfile -t srcs < <(all_sources)
  for fn in $BASELINE_FUNCTIONS; do
    defs="$(cat "${srcs[@]}" 2>/dev/null | grep -cE "^${fn}\(\)")"
    [[ "$defs" == 1 ]] && ok || nok "la función '$fn' está definida $defs veces (debe ser 1)"
  done
}

t_help_prints_the_whole_header() {
  local out; out="$(bash "$SETUP" help 2>&1)"
  [[ "$out" == *"Variables del .env"* ]] && ok || nok "la ayuda no muestra la última línea del encabezado (usage cortaba con un rango fijo)"
  [[ "$out" == *"restore"* ]] && ok || nok "la ayuda no menciona restore"
  [[ "$out" != *"====="* ]] && ok || nok "la ayuda no debe imprimir la línea de cierre del encabezado"
}

t_check_files_requires_the_modules() {
  grep -q 'lib/common.sh' <(sed -n '/^check_files() {/,/^}/p' "$LIB"/*.sh "$SETUP" 2>/dev/null) && ok || nok "check_files debe exigir los archivos de lib/"
}

t_ci_lints_at_warning_level_with_a_pinned_shellcheck() {
  grep -qE 'koalaman/shellcheck:v[0-9]+\.[0-9]+\.[0-9]+' "$CI" && ok || nok "ShellCheck debe correr como contenedor con versión fija"
  grep -qE -- '-x .*-S warning|-S warning .*-x' "$CI" && ok || nok "ShellCheck debe usar -x y -S warning"
  if grep -qE 'shellcheck -S error' "$CI"; then nok "queda el ShellCheck antiguo (-S error)"; else ok; fi
}

for t in t_every_module_exists_and_parses t_setup_is_a_thin_entry_point t_setup_sources_every_module_in_order \
         t_setup_guards_against_a_missing_lib t_setup_exits_right_after_main t_every_baseline_function_is_defined_exactly_once \
         t_help_prints_the_whole_header t_check_files_requires_the_modules t_ci_lints_at_warning_level_with_a_pinned_shellcheck; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
