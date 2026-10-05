#!/usr/bin/env bash
# =============================================================================
# Pruebas del comando "aiws" (gestión de varias instancias desde el servidor).
#
#   bash tests/aiws.test.sh
#
# Sin Docker real: "docker" simulado al principio del PATH (fixtures en archivos), HOME
# falso y un setup.sh falso por instancia que solo registra cómo lo invocan.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

# ------------------------------------------------------------------ aserciones
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

# ------------------------------------------------------------------- sandbox
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake"
  : > "$SB/fake/ps"; : > "$SB/fake/states"; : > "$SB/fake/owners"; : > "$SB/calls"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
# docker simulado: ps -> fixture "ps" (nombre|carpeta); inspect/container -> "states" y "owners"
F="${FAKE_DOCKER_DIR:?}"
case "${1:-}" in
  ps)        cat "$F/ps" ;;
  stats)     n="${*: -1}"; awk -F= -v n="$n" '$1==n { print $2 }' "$F/stats" 2>/dev/null ;;
  inspect)   fmt="$3"; n="$4"
             grep -q "^$n=" "$F/states" || exit 1
             case "$fmt" in
               *State.Status*) awk -F= -v n="$n" '$1==n { print $2 }' "$F/states" ;;
               *working_dir*)  awk -F= -v n="$n" '$1==n { print $2 }' "$F/owners" ;;
             esac ;;
  container) [[ "${2:-}" == inspect ]] && grep -q "^$3=" "$F/states" ;;
  *)         exit 1 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" AIWS_TEST_CALLS="$SB/calls" PATH="$SB/bin:$PATH"
}
fake_ps()    { echo "$1|$2" >> "$SB/fake/ps"; }          # contenedor etiquetado: valor de la etiqueta | carpeta
fake_state() { echo "$1=$2" >> "$SB/fake/states"; }      # contenedor -> running|exited
fake_owner() { echo "$1=$2" >> "$SB/fake/owners"; }

# mk_inst <carpeta> <alias|""> [MEM_LIMIT] [CPUS] [TS_HOSTNAME]: clon con setup.sh falso y .env
mk_inst() {
  mkdir -p "$1"
  cat > "$1/setup.sh" <<'EOF'
#!/usr/bin/env bash
# setup.sh falso: registra "carpeta|argumentos"; falla si existe .fail
echo "${PWD##*/}|$*" >> "${AIWS_TEST_CALLS:?}"
echo "AIWS_INSTANCE=${AIWS_INSTANCE-unset} AIWS_NAME=${AIWS_NAME-unset} AIWS_VOL_PREFIX=${AIWS_VOL_PREFIX-unset} ENV_FILE=${ENV_FILE-unset} TS_HOSTNAME=${TS_HOSTNAME-unset} AIWS_HOSTNAME=${AIWS_HOSTNAME-unset} MEM_LIMIT=${MEM_LIMIT-unset} CPUS=${CPUS-unset} COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME-unset} COMPOSE_PROFILES=${COMPOSE_PROFILES-unset}" > "${AIWS_TEST_CALLS}.env"
# lo que lee de stdin (solo si la prueba lo pide, para no bloquear en una terminal)
if [[ -n "${AIWS_TEST_READ_STDIN:-}" ]]; then IFS= read -r l || l=""; echo "$l" > "${AIWS_TEST_CALLS}.stdin"; fi
# resultado de "upgrade" para aiws: ya al día (.uptodate) o actualizada
if [[ "${1:-}" == upgrade && -n "${AIWS_UPGRADE_RESULT_FILE:-}" ]]; then
  if [[ -f "$PWD/.uptodate" ]]; then echo uptodate > "$AIWS_UPGRADE_RESULT_FILE"; else echo updated > "$AIWS_UPGRADE_RESULT_FILE"; fi
fi
[[ -f "$PWD/.fail" ]] && exit 1
exit 0
EOF
  { echo "AIWS_INSTANCE=$2"
    [[ -n "${3:-}" ]] && echo "MEM_LIMIT=$3"
    [[ -n "${4:-}" ]] && echo "CPUS=$4"
    [[ -n "${5:-}" ]] && echo "TS_HOSTNAME=$5"
    return 0; } > "$1/.env"
}
calls() { cat "$SB/calls"; }

load_aiws() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$ROOT/aiws"
  set +eEu; trap - ERR
  inst_have_tty() { return 1; }
}
# Tres instancias típicas: principal, foo y bar
three() {
  mk_inst "$HOME/ai-workspace" ""
  mk_inst "$HOME/ai-workspace-foo" "foo"
  mk_inst "$HOME/ai-workspace-bar" "bar"
}

# ================================================================== T7 descubrimiento
t_discover_clones() {
  load_aiws
  three
  mkdir -p "$HOME/ai-workspace-sinsetup"            # carpeta suelta, sin setup.sh: se ignora
  inst_discover
  assert_eq "alias en orden (principal primero)" "default bar foo" "${INST_ALIASES[*]}"
  assert_eq "carpetas" "3" "${#INST_DIRS[@]}"
}

t_discover_containers_and_dedupe() {
  load_aiws
  mk_inst "$HOME/ai-workspace-foo" "foo"
  mk_inst "$SB/custom/x" "cliente"                  # instancia en una carpeta fuera de ~
  fake_ps "ai-workspace-foo" "$HOME/ai-workspace-foo"
  fake_ps "ai-workspace-foo" "$HOME/ai-workspace-foo"
  fake_ps "ai-workspace-cliente" "$SB/custom/x"
  inst_discover
  assert_eq "sin duplicados, con la carpeta de los contenedores" "cliente foo" "${INST_ALIASES[*]}"
}

t_discover_missing_folder_warns() {
  load_aiws
  mk_inst "$HOME/ai-workspace" ""
  fake_ps "ai-workspace-viejo" "$SB/no/existe"
  inst_discover
  assert_eq "solo la que existe" "default" "${INST_ALIASES[*]}"
  assert_has "aviso de carpeta inexistente" "${INST_WARN[*]}" "$SB/no/existe"
}

t_discover_legacy_default() {
  load_aiws
  mk_inst "$SB/legado" ""
  fake_state "ai-workspace-ts" "running"; fake_owner "ai-workspace-ts" "$SB/legado"
  inst_discover
  assert_eq "principal heredada (sin etiqueta)" "default" "${INST_ALIASES[*]}"
}

t_discover_alias_from_env_crlf() {
  load_aiws
  mk_inst "$HOME/ai-workspace-zeta" "zeta"
  printf 'AIWS_INSTANCE=zeta\r\n' > "$HOME/ai-workspace-zeta/.env"
  inst_discover
  assert_eq "alias sin CR" "zeta" "${INST_ALIASES[*]}"
}

t_state() {
  load_aiws
  three
  fake_state "ai-workspace" "running"; fake_state "ai-workspace-foo" "exited"
  assert_eq "running" "running" "$(inst_state default)"
  assert_eq "stopped" "stopped" "$(inst_state foo)"
  assert_eq "sin contenedores" "sin contenedores" "$(inst_state bar)"
}

t_sum_mem() {
  load_aiws
  assert_eq "g+g" "16g" "$(inst_sum_mem 8g 8g)"
  assert_eq "g+m" "8.5g" "$(inst_sum_mem 8g 512m)"
}

t_ls() {
  load_aiws
  mk_inst "$HOME/ai-workspace" "" "8g" "4"
  mk_inst "$HOME/ai-workspace-foo" "foo" "4g" "2" "mi-equipo"
  fake_state "ai-workspace" "running"
  local out; out="$(main ls 2>&1)"
  assert_has "encabezado" "$out" "ESTADO"
  assert_has "principal" "$out" "ai-workspace "
  assert_has "alias foo" "$out" "ai-workspace-foo"
  assert_has "estado running" "$out" "running"
  assert_has "sin contenedores" "$out" "sin contenedores"
  assert_has "hostname" "$out" "mi-equipo"
  assert_has "carpeta" "$out" "$HOME/ai-workspace-foo"
  assert_has "total memoria" "$out" "12g"
  assert_has "total cpus" "$out" "6"
  assert_eq "sin argumentos = ls" "$out" "$(main 2>&1)"
}

t_ls_empty() {
  load_aiws
  local out; out="$(main ls 2>&1)"
  assert_has "sin instancias" "$out" "No hay instancias"
}

# ================================================================== resolución y selección
t_resolve() {
  load_aiws
  three
  inst_discover
  assert_eq "default" "0" "$(inst_resolve default)"
  assert_eq "principal" "0" "$(inst_resolve principal)"
  assert_eq "foo" "2" "$(inst_resolve foo)"
  local msg; msg="$(inst_resolve nada 2>&1)"; local rc=$?
  assert_eq "desconocido falla" "1" "$rc"
  assert_has "lista los válidos" "$msg" "default, bar, foo"
}

t_parse_selection() {
  load_aiws
  assert_eq "espacios" "1 3" "$(inst_parse_selection "1 3" 4)"
  assert_eq "comas" "1 3" "$(inst_parse_selection "1,3" 4)"
  assert_eq "rango" "1 2 3" "$(inst_parse_selection "1-3" 4)"
  assert_eq "mezcla y orden" "1 2 4" "$(inst_parse_selection "4, 1-2" 4)"
  assert_eq "sin repetidos" "1 2" "$(inst_parse_selection "1 1 2" 4)"
  assert_eq "todas" "1 2 3" "$(inst_parse_selection "todas" 3)"
  assert_eq "all" "1 2 3" "$(inst_parse_selection "ALL" 3)"
  inst_parse_selection "" 3 >/dev/null; assert_eq "vacío = cancelar" "2" "$?"
  local bad
  for bad in 0 4 x 3-1 1- -2 "1 x" 1-9; do
    inst_parse_selection "$bad" 3 >/dev/null 2>&1; assert_eq "inválido '$bad'" "1" "$?"
  done
}

# ================================================================== T8 upgrade
t_upgrade_single() {
  load_aiws; three
  main upgrade --yes foo >/dev/null 2>&1; local rc=$?
  assert_eq "rc" "0" "$rc"
  assert_eq "llamadas" "ai-workspace-foo|upgrade --yes" "$(calls)"
}

t_upgrade_multiple_in_order() {
  load_aiws; three
  main upgrade --yes foo default >/dev/null 2>&1
  assert_eq "orden pedido" "ai-workspace-foo|upgrade --yes
ai-workspace|upgrade --yes" "$(calls)"
}

t_upgrade_principal_synonym() {
  load_aiws; three
  main upgrade --yes principal >/dev/null 2>&1
  assert_eq "principal = default" "ai-workspace|upgrade --yes" "$(calls)"
}

t_upgrade_all() {
  load_aiws; three
  main upgrade --yes --all >/dev/null 2>&1
  assert_eq "todas, en orden" "ai-workspace|upgrade --yes
ai-workspace-bar|upgrade --yes
ai-workspace-foo|upgrade --yes" "$(calls)"
}

t_upgrade_unknown_runs_nothing() {
  load_aiws; three
  local out; out="$(main upgrade --yes foo nada 2>&1)"; local rc=$?
  assert_eq "rc" "1" "$rc"
  assert_has "lista válidos" "$out" "default, bar, foo"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_upgrade_failure_continues() {
  load_aiws; three
  touch "$HOME/ai-workspace-bar/.fail"
  local out; out="$(main upgrade --yes --all 2>&1)"; local rc=$?
  assert_eq "rc distinto de 0" "1" "$rc"
  assert_eq "siguió con la última" "ai-workspace|upgrade --yes
ai-workspace-bar|upgrade --yes
ai-workspace-foo|upgrade --yes" "$(calls)"
  assert_has "resumen ok" "$out" "ok"
  assert_has "resumen fallo" "$out" "fallo"
  assert_has "resumen nombra la fallida" "$out" "ai-workspace-bar"
}

t_upgrade_all_ok_exit_zero() {
  load_aiws; three
  main upgrade --yes --all >/dev/null 2>&1; assert_eq "rc 0" "0" "$?"
}

t_upgrade_extra_args() {
  load_aiws; three
  main upgrade --yes foo -- --foo --bar >/dev/null 2>&1
  assert_eq "argumentos tras --" "ai-workspace-foo|upgrade --yes --foo --bar" "$(calls)"
  local out; out="$(main upgrade --yes foo --otra 2>&1)"; local rc=$?
  assert_eq "opción suelta sin -- falla" "1" "$rc"
  assert_has "explica --" "$out" "--"
}

t_upgrade_no_tty_no_args() {
  load_aiws; three
  local out; out="$(main upgrade 2>&1)"; local rc=$?
  assert_eq "rc" "1" "$rc"
  assert_has "indica --all" "$out" "--all"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_upgrade_interactive() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo "1 3"; }
  main upgrade --yes >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "seleccionadas 1 y 3" "ai-workspace|upgrade --yes
ai-workspace-foo|upgrade --yes" "$(calls)"
}

t_upgrade_interactive_todas() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo "todas"; }
  main upgrade --yes >/dev/null 2>&1
  assert_eq "las tres" "3" "$(calls | wc -l | tr -d ' ')"
}

t_upgrade_interactive_reask() {
  load_aiws; three
  inst_have_tty() { return 0; }
  printf '%s\n' "zzz" "9" "2" > "$SB/answers"; echo 0 > "$SB/n"
  inst_prompt() { local n; n="$(<"$SB/n")"; n=$((n+1)); echo "$n" > "$SB/n"; sed -n "${n}p" "$SB/answers"; }
  main upgrade --yes >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "tras 2 inválidas, la tercera vale" "ai-workspace-bar|upgrade --yes" "$(calls)"
}

t_upgrade_interactive_gives_up() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo "zzz"; }
  main upgrade --yes >/dev/null 2>&1; assert_eq "rc" "1" "$?"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_upgrade_interactive_cancel() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo ""; }
  local out; out="$(main upgrade --yes 2>&1)"; assert_eq "rc 0" "0" "$?"
  assert_has "cancelado" "$out" "Cancelado"
  assert_eq "no corrió nada" "" "$(calls)"
}

# ================================================================== T9 passthrough
t_passthrough_single() {
  load_aiws; three
  main shell foo >/dev/null 2>&1
  assert_eq "shell" "ai-workspace-foo|shell" "$(calls)"
  : > "$SB/calls"
  main logs principal >/dev/null 2>&1
  assert_eq "logs de la principal" "ai-workspace|logs" "$(calls)"
}

t_passthrough_args() {
  load_aiws; three
  main uninstall foo --all --yes >/dev/null 2>&1
  assert_eq "argumentos de setup.sh" "ai-workspace-foo|uninstall --all --yes" "$(calls)"
  : > "$SB/calls"
  main add-key foo 'ssh-ed25519 AAAA' >/dev/null 2>&1
  assert_eq "add-key con clave" "ai-workspace-foo|add-key ssh-ed25519 AAAA" "$(calls)"
}

t_passthrough_exit_code() {
  load_aiws; three
  touch "$HOME/ai-workspace-foo/.fail"
  main shell foo >/dev/null 2>&1; assert_eq "propaga el fallo" "1" "$?"
}

t_destructive_requires_one_alias() {
  load_aiws; three
  local c out
  for c in uninstall purge rollback clean; do
    : > "$SB/calls"
    out="$(main "$c" 2>&1)"; assert_eq "$c sin alias falla" "1" "$?"
    assert_has "$c pide alias" "$out" "alias"
    out="$(main "$c" foo bar 2>&1)"; assert_eq "$c con dos alias falla" "1" "$?"
    out="$(main "$c" --all 2>&1)"; assert_eq "$c --all falla" "1" "$?"
    out="$(main "$c" nada 2>&1)"; assert_eq "$c alias desconocido falla" "1" "$?"
    assert_eq "$c no corrió nada" "" "$(calls)"
  done
}

t_multi_commands() {
  load_aiws; three
  main status --all >/dev/null 2>&1
  assert_eq "status --all" "3" "$(calls | wc -l | tr -d ' ')"
  : > "$SB/calls"
  main doctor foo bar >/dev/null 2>&1
  assert_eq "doctor varios" "ai-workspace-foo|doctor
ai-workspace-bar|doctor" "$(calls)"
  : > "$SB/calls"
  main status >/dev/null 2>&1
  assert_eq "status sin alias = todas (solo lectura)" "3" "$(calls | wc -l | tr -d ' ')"
  : > "$SB/calls"
  main backup foo bar >/dev/null 2>&1
  assert_eq "backup varios" "ai-workspace-foo|backup
ai-workspace-bar|backup" "$(calls)"
}

t_single_rejects_second_alias() {
  load_aiws; three
  local out; out="$(main shell foo bar 2>&1)"; assert_eq "rc" "1" "$?"
  assert_has "una sola instancia" "$out" "una sola"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_install_not_dispatchable() {
  load_aiws; three
  local out; out="$(main install foo 2>&1)"; assert_eq "rc" "2" "$?"
  assert_has "remite a install.sh" "$out" "install.sh"
}

# ================================================================== ronda 3
t_upgrade_dedupes() {
  load_aiws; three
  main upgrade --yes foo foo principal default >/dev/null 2>&1
  assert_eq "cada instancia una sola vez, en orden" "ai-workspace-foo|upgrade --yes
ai-workspace|upgrade --yes" "$(calls)"
}

t_all_with_aliases_errors() {
  load_aiws; three
  local out; out="$(main upgrade --yes --all foo 2>&1)"; assert_eq "rc" "1" "$?"
  assert_has "explica" "$out" "--all"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_discover_backup_copy_ignored() {
  load_aiws
  mk_inst "$HOME/ai-workspace" ""
  mk_inst "$HOME/ai-workspace-bak" ""               # copia de respaldo: su .env dice "principal"
  inst_discover
  assert_eq "la copia no cuenta" "default" "${INST_ALIASES[*]}"
  assert_has "avisa de la copia" "${INST_WARN[*]}" "$HOME/ai-workspace-bak"
  assert_has "ls la menciona como ignorada" "$(main ls 2>&1)" "se ignora"
}

t_discover_name_mismatch_but_owns_containers() {
  load_aiws
  mk_inst "$HOME/ai-workspace-baz" "qux"            # nombre y .env no coinciden
  inst_discover
  assert_eq "sin contenedores: ignorada" "" "${INST_ALIASES[*]}"
  fake_ps "ai-workspace-qux" "$HOME/ai-workspace-baz"
  inst_discover
  assert_eq "con contenedores: es una instancia" "qux" "${INST_ALIASES[*]}"
}

t_discover_ambiguous_alias() {
  load_aiws
  mk_inst "$HOME/ai-workspace-foo" "foo"
  mk_inst "$SB/custom/y" "foo"
  fake_ps "ai-workspace-foo" "$SB/custom/y"
  inst_discover
  assert_eq "se muestran ambas" "foo foo" "${INST_ALIASES[*]}"
  local msg; msg="$(inst_resolve foo 2>&1)"; local rc=$?
  assert_eq "resolver falla" "1" "$rc"
  assert_has "nombra una carpeta" "$msg" "$HOME/ai-workspace-foo"
  assert_has "nombra la otra" "$msg" "$SB/custom/y"
  main upgrade --yes foo >/dev/null 2>&1; assert_eq "upgrade falla" "1" "$?"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_discover_registry() {
  load_aiws
  mk_inst "$SB/custom/z" "zeta"
  mkdir -p "$HOME/.local/share/ai-workspace"
  printf '%s\n' "$SB/custom/z" "$SB/custom/z" "$SB/no/existe" > "$HOME/.local/share/ai-workspace/instances"
  inst_discover
  assert_eq "instancia registrada (sin contenedores ni ~)" "zeta" "${INST_ALIASES[*]}"
  assert_has "avisa de la carpeta faltante" "${INST_WARN[*]}" "$SB/no/existe"
  mk_inst "$SB/custom/w" "omega"
  mkdir -p "$SB/xdg/ai-workspace"; echo "$SB/custom/w" > "$SB/xdg/ai-workspace/instances"
  export XDG_DATA_HOME="$SB/xdg"
  inst_discover
  assert_eq "respeta XDG_DATA_HOME" "omega" "${INST_ALIASES[*]}"
}

t_selection_leading_zeros() {
  load_aiws
  assert_eq "08" "8" "$(inst_parse_selection "08" 9)"
  assert_eq "09" "9" "$(inst_parse_selection "09" 9)"
  assert_eq "rango con ceros" "1 2 3" "$(inst_parse_selection "01-03" 9)"
}

t_clean_environment() {
  load_aiws; three
  local v
  for v in AIWS_INSTANCE AIWS_NAME AIWS_VOL_PREFIX ENV_FILE TS_HOSTNAME AIWS_HOSTNAME MEM_LIMIT CPUS COMPOSE_PROJECT_NAME COMPOSE_PROFILES; do
    export "$v=sucio"
  done
  main status foo >/dev/null 2>&1
  assert_eq "setup.sh recibe el entorno limpio" "AIWS_INSTANCE=unset AIWS_NAME=unset AIWS_VOL_PREFIX=unset ENV_FILE=unset TS_HOSTNAME=unset AIWS_HOSTNAME=unset MEM_LIMIT=unset CPUS=unset COMPOSE_PROJECT_NAME=unset COMPOSE_PROFILES=unset" "$(cat "$SB/calls.env")"
}


# ================================================================== ronda 5: confirmación única y --yes
t_upgrade_needs_yes_without_tty() {
  load_aiws; three
  local out c
  for c in upgrade update; do
    out="$(main "$c" foo 2>&1)"; assert_eq "$c sin tty ni --yes: rc 2" "2" "$?"
    assert_has "$c pide --yes" "$out" "--yes"
  done
  assert_eq "no corrió nada" "" "$(calls)"
}

t_upgrade_confirmation_prompt() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo "$1" > "$SB/prompt"; echo "s"; }
  main upgrade foo default >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_has "lista las instancias" "$(cat "$SB/prompt")" "Se actualizarán y reconstruirán: foo, default"
  assert_has "pide continuar" "$(cat "$SB/prompt")" "¿Continuar?"
  assert_eq "ejecuta con --yes en cada hija" "ai-workspace-foo|upgrade --yes
ai-workspace|upgrade --yes" "$(calls)"
}

t_upgrade_confirmation_declined() {
  load_aiws; three
  inst_have_tty() { return 0; }
  local a
  for a in n N "" no; do
    inst_prompt() { echo "$a"; }
    main upgrade foo >/dev/null 2>&1; assert_eq "respuesta '$a': rc 0" "0" "$?"
  done
  assert_eq "no corrió nada" "" "$(calls)"
}

t_upgrade_yes_skips_prompt() {
  load_aiws; three
  inst_have_tty() { return 0; }
  inst_prompt() { echo "PREGUNTO" > "$SB/asked"; echo n; }
  main upgrade -y foo >/dev/null 2>&1
  main upgrade bar --yes >/dev/null 2>&1
  assert_eq "sin preguntar" "" "$(cat "$SB/asked" 2>/dev/null)"
  assert_eq "corrió ambas" "2" "$(calls | wc -l | tr -d ' ')"
}

t_update_confirmation_and_args() {
  load_aiws; three
  main update --yes foo >/dev/null 2>&1
  assert_eq "update no recibe --yes (setup.sh update no pregunta)" "ai-workspace-foo|update" "$(calls)"
  : > "$SB/calls"
  main update -y foo -- --foreground >/dev/null 2>&1
  assert_eq "argumentos tras --" "ai-workspace-foo|update --foreground" "$(calls)"
}

t_children_stdin() {
  load_aiws; three
  export AIWS_TEST_READ_STDIN=1
  echo "hola" | main upgrade --yes foo >/dev/null 2>&1
  assert_eq "varias: stdin cerrado" "" "$(cat "$SB/calls.stdin")"
  echo "hola" | main shell foo >/dev/null 2>&1
  assert_eq "una sola (interactiva): hereda stdin" "hola" "$(cat "$SB/calls.stdin")"
  echo "si" | main uninstall foo >/dev/null 2>&1
  assert_eq "destructiva: hereda stdin para su confirmación" "si" "$(cat "$SB/calls.stdin")"
}

t_upgrade_summary_kinds() {
  load_aiws; three
  touch "$HOME/ai-workspace-foo/.uptodate" "$HOME/ai-workspace-bar/.fail"
  local out; out="$(main upgrade --yes --all 2>&1)"; assert_eq "rc" "1" "$?"
  assert_has "actualizada" "$out" "ok (actualizada)"
  assert_has "ya al día" "$out" "ok (ya al día)"
  assert_has "fallo" "$out" "fallo"
}

t_help_documents_yes() {
  load_aiws
  assert_has "help upgrade" "$(main help upgrade 2>&1)" "--yes"
  assert_has "help update" "$(main help update 2>&1)" "--yes"
  assert_has "help general" "$(main help 2>&1)" "--yes"
}


# ================================================================== T12-T14: recursos
res_three() {   # tres instancias con límites distintos y uso real simulado
  mk_inst "$HOME/ai-workspace" "" "8g" "4"
  mk_inst "$HOME/ai-workspace-foo" "foo" "4g" "2"
  mk_inst "$HOME/ai-workspace-bar" "bar" "2g" "1"
  fake_state "ai-workspace" "running"; fake_state "ai-workspace-foo" "running"
  echo "ai-workspace=1.2GiB / 8GiB|3.4%" > "$SB/fake/stats"
  echo "ai-workspace-foo=900MiB / 4GiB|0.5%" >> "$SB/fake/stats"
  export AIWS_HOST_MEM_KB=16777216 AIWS_HOST_CPUS=8
}

t_resources_table() {
  load_aiws; res_three
  local out; out="$(main resources 2>&1)"; assert_eq "rc" "0" "$?"
  assert_has "encabezado" "$out" "ALIAS"
  assert_has "uso de memoria" "$out" "1.2GiB"
  assert_has "uso de CPU" "$out" "3.4%"
  assert_has "otra instancia" "$out" "900MiB"
  assert_has "detenida" "$out" "sin contenedores"
  assert_has "suma de límites" "$out" "Suma de límites: 14g"
  assert_has "son máximos" "$out" "máximos"
  assert_has "RAM del servidor" "$out" "16g"
  assert_eq "--all igual que sin argumentos" "$out" "$(main resources --all 2>&1)"
  assert_eq "no ejecutó setup.sh" "" "$(calls)"
}

t_resources_subset() {
  load_aiws; res_three
  local out; out="$(main resources foo 2>&1)"
  assert_has "foo" "$out" "900MiB"
  assert_lacks "sin la principal" "$out" "1.2GiB"
  out="$(main resources nada 2>&1)"; assert_eq "alias desconocido" "1" "$?"
  assert_has "lista válidos" "$out" "default, bar, foo"
}

t_resources_warns_over_host() {
  load_aiws; res_three
  export AIWS_HOST_MEM_KB=8388608
  assert_has "avisa" "$(main resources 2>&1)" "supera"
  export AIWS_HOST_MEM_KB=33554432
  assert_lacks "sin aviso" "$(main resources 2>&1)" "supera"
}

t_resources_set_delegates() {
  load_aiws; res_three
  main resources foo --mem 4g --cpus 2 >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "delegado a setup.sh de esa instancia" "ai-workspace-foo|resources --mem 4g --cpus 2" "$(calls)"
  : > "$SB/calls"
  main resources principal --shm 1g --pids 4096 --mssql-mem 2g --no-apply >/dev/null 2>&1
  assert_eq "todas las opciones" "ai-workspace|resources --shm 1g --pids 4096 --mssql-mem 2g --no-apply" "$(calls)"
  : > "$SB/calls"
  main resources foo --set >/dev/null 2>&1
  assert_eq "modo interactivo" "ai-workspace-foo|resources --set" "$(calls)"
  : > "$SB/calls"
  main resources foo --mem=3g >/dev/null 2>&1
  assert_eq "forma --mem=VALOR" "ai-workspace-foo|resources --mem=3g" "$(calls)"
}

t_resources_set_needs_one_instance() {
  load_aiws; res_three
  local out
  out="$(main resources foo bar --mem 4g 2>&1)"; assert_eq "dos alias" "1" "$?"
  assert_has "pide una sola" "$out" "una sola"
  out="$(main resources --all --mem 4g 2>&1)"; assert_eq "--all" "1" "$?"
  out="$(main resources --mem 4g 2>&1)"; assert_eq "sin alias" "1" "$?"
  out="$(main resources nada --mem 4g 2>&1)"; assert_eq "alias desconocido" "1" "$?"
  out="$(main resources foo --mem 2>&1)"; assert_eq "falta el valor" "1" "$?"
  assert_eq "no corrió nada" "" "$(calls)"
}

t_ls_sum_of_limits() {
  load_aiws; res_three
  local out; out="$(main ls 2>&1)"
  assert_has "suma de límites" "$out" "Suma de límites"
  assert_has "son máximos, no reservas" "$out" "no son reservas"
  assert_has "RAM del servidor" "$out" "16g"
  assert_has "CPUs del servidor" "$out" "8 CPUs"
  assert_lacks "ya no dice reservado" "$out" "Total reservado"
}

t_help_resources() {
  load_aiws
  local out; out="$(main help resources 2>&1)"
  assert_has "uso" "$out" "aiws resources"
  assert_has "--mem" "$out" "--mem"
  assert_has "--cpus" "$out" "--cpus"
  assert_has "sin reconstruir" "$out" "sin reconstruir"
  assert_has "general lo lista" "$(main help 2>&1)" "resources"
}


# ================================================================== ayuda
# Subcomandos reales de setup.sh que aiws debe poder delegar (si setup.sh suma uno, hay que sumarlo aquí y en aiws)
EXPECTED_CMDS=(ls resources upgrade update status doctor ts-status backup shell logs psql components add-key migrate progress down rollback clean uninstall purge help)

t_help_general() {
  load_aiws; three
  local out c; out="$(main help 2>&1)"; assert_eq "rc" "0" "$?"
  assert_eq "--help igual" "$out" "$(main --help 2>&1)"
  assert_eq "-h igual" "$out" "$(main -h 2>&1)"
  for c in "${EXPECTED_CMDS[@]}"; do assert_has "help menciona $c" "$out" "$c"; done
  assert_has "varias instancias" "$out" "--all"
  assert_has "destructivos" "$out" "destructivo"
  assert_has "ejemplo ls" "$out" "aiws ls"
  assert_has "ejemplo upgrade varios" "$out" "aiws upgrade santiago maria"
  assert_has "ejemplo upgrade --all" "$out" "aiws upgrade --all"
  assert_has "ejemplo shell" "$out" "aiws shell santiago"
}

t_help_table_matches_dispatcher() {
  load_aiws; three
  local c out
  for c in "${AIWS_CMD_NAMES[@]}"; do
    out="$(main "$c" --help 2>&1)"; assert_eq "$c --help rc" "0" "$?"
    assert_has "$c --help muestra Uso" "$out" "Uso:"
    assert_has "$c --help menciona el comando" "$out" "aiws $c"
    assert_has "$c --help trae ejemplo" "$out" "Ejemplo"
    assert_eq "help $c = $c --help" "$out" "$(main help "$c" 2>&1)"
    assert_eq "$c -h" "$out" "$(main "$c" -h 2>&1)"
  done
  # ningún subcomando esperado falta en la tabla
  for c in "${EXPECTED_CMDS[@]}"; do
    [[ " ${AIWS_CMD_NAMES[*]} " == *" $c "* ]] && ok || nok "la tabla de comandos no incluye $c"
  done
  assert_eq "--help no ejecuta setup.sh" "" "$(calls)"
}

t_help_marks_kinds() {
  load_aiws
  assert_has "uninstall destructivo" "$(main help uninstall 2>&1)" "destructivo"
  assert_has "upgrade acepta varias" "$(main help upgrade 2>&1)" "varias"
  assert_has "shell una sola" "$(main help shell 2>&1)" "una sola"
}

t_help_unknown_command() {
  load_aiws; three
  local out; out="$(main fabuloso 2>&1)"; local rc=$?
  assert_eq "rc 2" "2" "$rc"
  assert_has "error corto" "$out" "fabuloso"
  assert_has "y la ayuda general" "$out" "Comandos"
  out="$(main help fabuloso 2>&1)"; assert_eq "help <desconocido> rc 2" "2" "$?"
  assert_eq "no ejecutó nada" "" "$(calls)"
}

run t_discover_clones
run t_discover_containers_and_dedupe
run t_discover_missing_folder_warns
run t_discover_legacy_default
run t_discover_alias_from_env_crlf
run t_state
run t_sum_mem
run t_ls
run t_ls_empty
run t_resolve
run t_parse_selection
run t_upgrade_single
run t_upgrade_multiple_in_order
run t_upgrade_principal_synonym
run t_upgrade_all
run t_upgrade_unknown_runs_nothing
run t_upgrade_failure_continues
run t_upgrade_all_ok_exit_zero
run t_upgrade_extra_args
run t_upgrade_no_tty_no_args
run t_upgrade_interactive
run t_upgrade_interactive_todas
run t_upgrade_interactive_reask
run t_upgrade_interactive_gives_up
run t_upgrade_interactive_cancel
run t_passthrough_single
run t_passthrough_args
run t_passthrough_exit_code
run t_destructive_requires_one_alias
run t_multi_commands
run t_single_rejects_second_alias
run t_install_not_dispatchable
run t_help_general
run t_help_table_matches_dispatcher
run t_help_marks_kinds
run t_help_unknown_command
run t_upgrade_dedupes
run t_all_with_aliases_errors
run t_discover_backup_copy_ignored
run t_discover_name_mismatch_but_owns_containers
run t_discover_ambiguous_alias
run t_discover_registry
run t_selection_leading_zeros
run t_clean_environment
run t_upgrade_needs_yes_without_tty
run t_upgrade_confirmation_prompt
run t_upgrade_confirmation_declined
run t_upgrade_yes_skips_prompt
run t_update_confirmation_and_args
run t_children_stdin
run t_upgrade_summary_kinds
run t_help_documents_yes
run t_resources_table
run t_resources_subset
run t_resources_warns_over_host
run t_resources_set_delegates
run t_resources_set_needs_one_instance
run t_ls_sum_of_limits
run t_help_resources

p="$(wc -l < "$PASSES" | tr -d ' ')"; f="$(wc -l < "$FAILS" | tr -d ' ')"
echo
echo "Resultado: $p aserciones correctas, $f fallidas"
(( f == 0 ))
