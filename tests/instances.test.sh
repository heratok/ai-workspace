#!/usr/bin/env bash
# =============================================================================
# Pruebas de multi-instancia (sin Docker real): nombres derivados, validación de
# alias, detección de instancias existentes y siguiente alias libre.
#
#   bash tests/instances.test.sh
#
# Cada prueba corre en un subproceso con HOME falso y un "docker" simulado al
# principio del PATH (responde según archivos de fixture), así que no toca nada
# del equipo donde se ejecuta.
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
assert_ok()   { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then ok; else nok "$n: debía tener éxito: $*"; fi; return 0; }
assert_fail() { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then nok "$n: debía fallar: $*"; else ok; fi; return 0; }
join() { local IFS=,; echo "$*"; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# ------------------------------------------------------------------- sandbox
# HOME falso, repo copiado (SCRIPT_DIR propio) y docker simulado.
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake" "$SB/repo"
  : > "$SB/fake/containers"; : > "$SB/fake/volumes"; : > "$SB/fake/labels"; : > "$SB/fake/owners"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
# docker simulado: lee fixtures de $FAKE_DOCKER_DIR
F="${FAKE_DOCKER_DIR:?}"
case "${1:-}" in
  ps)        cat "$F/labels" ;;                                  # docker ps -a --filter label=... --format ...
  container) grep -qxF "$3" "$F/containers" ;;                   # docker container inspect NAME
  volume)    [[ "$2" == create ]] && exit 0                       # docker volume create NAME
             grep -qxF "$3" "$F/volumes" ;;                      # docker volume inspect NAME
  inspect)   n="${*: -1}"                                        # docker inspect -f '{{...working_dir}}' NAME
             grep -qxF "$n" "$F/containers" || exit 1
             awk -F= -v n="$n" '$1==n { print $2 }' "$F/owners" ;;
  info)      exit 0 ;;
  stats)     n="${*: -1}"; grep -qxF "$n" "$F/containers" && cat "$F/stats" 2>/dev/null ;;
  compose)   [[ "$2" == version ]] && exit 0                        # version ok; "build" falla a propósito; el resto (up...) pasa
             echo "docker $*" >> "$F/compose.log"
             [[ " $* " == *" build "* ]] && exit 1
             exit 0 ;;
  *)         exit 1 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  cp "$ROOT/setup.sh" "$ROOT/env.example" "$SB/repo/"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
}
fake_container() { echo "$1" >> "$SB/fake/containers"; }
fake_volume()    { echo "$1" >> "$SB/fake/volumes"; }
fake_label()     { echo "$1" >> "$SB/fake/labels"; }

load_setup() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"
  set +eEu; trap - ERR
}
load_install() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$ROOT/install.sh"
  set +eEu
}

# ================================================================ setup.sh
t_setup_default_names() {
  load_setup
  instance_names ""
  assert_eq "INSTANCE" "" "$INSTANCE"
  assert_eq "AIWS_NAME" "ai-workspace" "$AIWS_NAME"
  assert_eq "AIWS_VOL_PREFIX" "ai" "$AIWS_VOL_PREFIX"
  assert_eq "CONTAINER" "ai-workspace" "$CONTAINER"
  assert_eq "TS_CONTAINER" "ai-workspace-ts" "$TS_CONTAINER"
  assert_eq "MSSQL_CONTAINER" "ai-workspace-mssql" "$MSSQL_CONTAINER"
  assert_eq "IMAGE" "ai-workspace:latest" "$IMAGE"
  assert_eq "TS_VOLUME" "ai_ts_state" "$TS_VOLUME"
  assert_eq "VOLUMES" "ai_home,ai_workspace" "$(join "${VOLUMES[@]}")"
  assert_eq "ALL_VOLUMES" "ai_home,ai_workspace,ai_ssh_host_keys,ai_ts_state,ai_mssql_data" "$(join "${ALL_VOLUMES[@]}")"
}

t_setup_default_alias_word() {
  load_setup
  instance_names "default"
  assert_eq "INSTANCE" "" "$INSTANCE"
  assert_eq "CONTAINER" "ai-workspace" "$CONTAINER"
}

t_setup_alias_names() {
  load_setup
  instance_names "foo"
  assert_eq "INSTANCE" "foo" "$INSTANCE"
  assert_eq "AIWS_NAME" "ai-workspace-foo" "$AIWS_NAME"
  assert_eq "AIWS_VOL_PREFIX" "ai-workspace-foo" "$AIWS_VOL_PREFIX"
  assert_eq "CONTAINER" "ai-workspace-foo" "$CONTAINER"
  assert_eq "TS_CONTAINER" "ai-workspace-foo-ts" "$TS_CONTAINER"
  assert_eq "MSSQL_CONTAINER" "ai-workspace-foo-mssql" "$MSSQL_CONTAINER"
  assert_eq "IMAGE" "ai-workspace-foo:latest" "$IMAGE"
  assert_eq "TS_VOLUME" "ai-workspace-foo_ts_state" "$TS_VOLUME"
  assert_eq "VOLUMES" "ai-workspace-foo_home,ai-workspace-foo_workspace" "$(join "${VOLUMES[@]}")"
  assert_eq "ALL_VOLUMES" \
    "ai-workspace-foo_home,ai-workspace-foo_workspace,ai-workspace-foo_ssh_host_keys,ai-workspace-foo_ts_state,ai-workspace-foo_mssql_data" \
    "$(join "${ALL_VOLUMES[@]}")"
}

t_setup_instance_read_from_env() {
  mk_sandbox
  printf 'AIWS_INSTANCE=bar\n' > "$SB/repo/.env"
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"; set +eEu; trap - ERR
  assert_eq "CONTAINER desde .env" "ai-workspace-bar" "$CONTAINER"
}

t_setup_invalid_instance_dies() {
  load_setup
  assert_fail "alias inválido en instance_names" instance_names "Bad_Alias"
  assert_fail "alias reservado en instance_names" instance_names "ts"
}

t_setup_alias_validation() {
  load_setup
  local a
  for a in a ab foo foo-bar 2 a1 a-b abcdefghijklmnopqrst; do
    assert_ok "válido: $a" alias_error "$a"
  done
  for a in "" -a a- A foo_bar foo.bar "a b" abcdefghijklmnopqrstu ts mssql postgres redis foo-ts foo-mssql; do
    assert_fail "inválido: '$a'" alias_error "$a"
  done
}

t_setup_other_instances() {
  load_setup
  instance_names "foo"
  fake_label "ai-workspace-foo"; fake_label "ai-workspace-bar"; fake_label "ai-workspace-bar"
  fake_container "ai-workspace-ts"          # principal heredada: sin etiqueta
  assert_eq "otras instancias" "ai-workspace
ai-workspace-bar" "$(other_instances)"
  instance_names ""
  assert_eq "otras vistas desde la principal" "ai-workspace-bar
ai-workspace-foo" "$(other_instances)"
}

t_setup_no_other_instances() {
  load_setup
  instance_names "foo"
  fake_label "ai-workspace-foo"
  assert_eq "sin otras" "" "$(other_instances)"
}

t_setup_owner_check() {
  load_setup
  instance_names "foo"
  # sin contenedores: no hay conflicto
  assert_ok "libre" check_instance_owner
  # contenedor propio de esta carpeta
  fake_container "ai-workspace-foo"; echo "ai-workspace-foo=$SCRIPT_DIR" >> "$SB/fake/owners"
  assert_ok "propio" check_instance_owner
  # contenedor de otra carpeta que existe: se rechaza
  mkdir -p "$SB/otra"
  echo "ai-workspace-foo-ts=$SB/otra" >> "$SB/fake/owners"; fake_container "ai-workspace-foo-ts"
  assert_fail "ajeno" check_instance_owner
  # el dueño registrado ya no existe (carpeta movida): solo se avisa
  : > "$SB/fake/owners"; echo "ai-workspace-foo=$SCRIPT_DIR" >> "$SB/fake/owners"
  echo "ai-workspace-foo-ts=/carpeta/que/ya/no/existe" >> "$SB/fake/owners"
  assert_ok "dueño movido: aviso" check_instance_owner
}

t_setup_owner_default() {
  load_setup
  instance_names ""
  fake_container "ai-workspace"; mkdir -p "$SB/otra"
  echo "ai-workspace=$SB/otra" >> "$SB/fake/owners"
  assert_fail "la principal de otra carpeta existente se rechaza" check_instance_owner
  : > "$SB/fake/owners"; echo "ai-workspace=/carpeta/que/ya/no/existe" >> "$SB/fake/owners"
  assert_ok "la principal con dueño movido solo avisa" check_instance_owner
  : > "$SB/fake/owners"; echo "ai-workspace=$SCRIPT_DIR" >> "$SB/fake/owners"
  assert_ok "la principal propia" check_instance_owner
}

t_setup_write_env_alias() {
  load_setup
  instance_names "foo"
  cp "$SB/repo/env.example" "$SB/repo/.env"
  write_instance_env
  assert_eq "AIWS_INSTANCE" "foo" "$(env_get AIWS_INSTANCE)"
  assert_eq "AIWS_NAME" "ai-workspace-foo" "$(env_get AIWS_NAME)"
  assert_eq "AIWS_VOL_PREFIX" "ai-workspace-foo" "$(env_get AIWS_VOL_PREFIX)"
  assert_eq "TS_HOSTNAME por defecto se reemplaza" "ai-workspace-foo" "$(env_get TS_HOSTNAME)"
  env_set TS_HOSTNAME "mi-equipo"; write_instance_env
  assert_eq "TS_HOSTNAME explícito se respeta" "mi-equipo" "$(env_get TS_HOSTNAME)"
}

t_setup_write_env_default() {
  load_setup
  instance_names ""
  cp "$SB/repo/env.example" "$SB/repo/.env"
  write_instance_env
  assert_eq "AIWS_INSTANCE vacío" "" "$(env_get AIWS_INSTANCE)"
  assert_eq "AIWS_NAME" "ai-workspace" "$(env_get AIWS_NAME)"
  assert_eq "AIWS_VOL_PREFIX" "ai" "$(env_get AIWS_VOL_PREFIX)"
  assert_eq "TS_HOSTNAME intacto" "ai-workspace" "$(env_get TS_HOSTNAME)"
}

t_setup_configure_env_alias() {
  load_setup
  bind_alias "foo"
  configure_env "tskey-auth-test" </dev/null >/dev/null 2>&1
  assert_eq "AIWS_INSTANCE" "foo" "$(env_get AIWS_INSTANCE)"
  assert_eq "AIWS_NAME" "ai-workspace-foo" "$(env_get AIWS_NAME)"
  assert_eq "TS_HOSTNAME" "ai-workspace-foo" "$(env_get TS_HOSTNAME)"
}

t_setup_bind_alias_conflict() {
  load_setup
  # esta carpeta ya es la instancia "foo" (con contenedores): no se reasigna
  printf 'AIWS_INSTANCE=foo\n' > "$SB/repo/.env"
  instance_names "foo"; fake_container "ai-workspace-foo"
  assert_fail "reasignar carpeta en uso" bind_alias "bar"
  assert_ok "mismo alias" bind_alias "foo"
}

t_setup_bind_alias_fresh_clone() {
  load_setup
  # La principal existe y la gestiona OTRA carpeta; esta es un clon nuevo sin .env
  mkdir -p "$SB/principal"; fake_container "ai-workspace"; fake_container "ai-workspace-ts"
  echo "ai-workspace=$SB/principal" >> "$SB/fake/owners"
  assert_ok "alias en clon nuevo con la principal existente" bind_alias "2"
  bind_alias "2"
  assert_eq "CONTAINER" "ai-workspace-2" "$CONTAINER"
}

t_setup_bind_alias_owned_container() {
  load_setup
  # esta carpeta ya gestiona la principal: no se reasigna a otro alias
  fake_container "ai-workspace"; echo "ai-workspace=$SCRIPT_DIR" >> "$SB/fake/owners"
  assert_fail "carpeta dueña de la principal" bind_alias "foo"
  assert_ok "mismo (principal)" bind_alias "default"
}

t_setup_bind_alias_env_conflict() {
  load_setup
  printf 'AIWS_INSTANCE=foo\n' > "$SB/repo/.env"
  instance_names "foo"          # sin contenedores: el .env basta para rechazar
  assert_fail ".env con otra instancia" bind_alias "bar"
  assert_ok "mismo alias" bind_alias "foo"
}

t_setup_env_crlf() {
  mk_sandbox
  printf 'AIWS_INSTANCE=bar\r\nTS_HOSTNAME=x\r\n' > "$SB/repo/.env"
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"; set +eEu; trap - ERR
  assert_eq "CONTAINER con .env CRLF" "ai-workspace-bar" "$CONTAINER"
  assert_eq "env_get sin CR" "x" "$(env_get TS_HOSTNAME)"
}

t_setup_summary_shows_instance() {
  load_setup
  instance_names "foo"
  cp "$SB/repo/env.example" "$SB/repo/.env"; write_instance_env
  local out; out="$(summary 2>&1)"
  [[ "$out" == *"ai-workspace-foo"* ]] && ok || nok "summary debe mostrar la instancia"
  [[ "$out" == *"ssh ai@ai-workspace-foo"* ]] && ok || nok "summary debe mostrar el host SSH de la instancia"
}

# install.sh -> setup.sh de punta a punta (git y docker simulados): con la principal ya instalada,
# la segunda ejecución debe terminar como instancia ai-workspace-2 en su propia carpeta.
t_e2e_second_instance_via_install_sh() {
  mk_sandbox
  if { : </dev/tty; } 2>/dev/null; then echo "  (omitida: hay /dev/tty y las preguntas leerían de él)"; return 0; fi
  cat > "$SB/bin/git" <<'EOF'
#!/usr/bin/env bash
# git simulado: "clone" copia este repo y neutraliza el requisito de /dev/net/tun
if [[ "$1" == clone ]]; then
  d="${*: -1}"; mkdir -p "$d"
  (cd "$AIWS_TEST_ROOT" && tar cf - --exclude=.git --exclude=odd --exclude=tests --exclude=landing --exclude=node_modules --exclude=logs --exclude=backups --exclude=.env .) | tar xf - -C "$d"
  mkdir -p "$d/.git"
  sed -i 's#\[\[ -c /dev/net/tun \]\] || die.*#true#' "$d/setup.sh"
fi
exit 0
EOF
  chmod +x "$SB/bin/git"
  # En Git Bash (Windows) "install -m 700" falla al cambiar permisos; este envoltorio solo quita -m
  local real_install; real_install="$(command -v install)"
  cat > "$SB/bin/install" <<EOF
#!/usr/bin/env bash
a=(); while [[ \$# -gt 0 ]]; do if [[ "\$1" == -m ]]; then shift 2; else a+=("\$1"); shift; fi; done
exec "$real_install" "\${a[@]}"
EOF
  chmod +x "$SB/bin/install"
  # La principal ya existe y la gestiona ~/ai-workspace
  mkdir -p "$HOME/ai-workspace/.git"
  fake_container "ai-workspace"; fake_container "ai-workspace-ts"
  printf '%s\n' "ai-workspace=$HOME/ai-workspace" "ai-workspace-ts=$HOME/ai-workspace" > "$SB/fake/owners"
  local out
  out="$(AIWS_TEST_ROOT="$ROOT" AIWS_HOST_CPUS=8 AIWS_HOST_MEM_KB=16777216 bash -s -- --foreground --mem 3g --cpus 2 --authkey tskey-auth-x --pubkey 'ssh-ed25519 AAAA' < "$ROOT/install.sh" 2>&1)"
  [[ "$out" == *"ai-workspace-2"* ]] && ok || nok "debe crear ai-workspace-2: $out"
  [[ "$out" != *"ya es la instancia"* ]] && ok || nok "setup.sh rechazó el alias nuevo: $out"
  assert_eq ".env de la segunda instancia" "2" "$(grep -E '^AIWS_INSTANCE=' "$HOME/ai-workspace-2/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
  assert_eq "TS_HOSTNAME de la segunda" "ai-workspace-2" "$(grep -E '^TS_HOSTNAME=' "$HOME/ai-workspace-2/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
  assert_eq "--mem llegó a setup.sh" "3g" "$(grep -E '^MEM_LIMIT=' "$HOME/ai-workspace-2/.env" 2>/dev/null | cut -d= -f2- | tr -d "[:space:]")"
  assert_eq "--cpus llegó a setup.sh" "2" "$(grep -E '^CPUS=' "$HOME/ai-workspace-2/.env" 2>/dev/null | cut -d= -f2- | tr -d "[:space:]")"
  assert_has "registro de la segunda instancia" "$(cat "$HOME/.local/share/ai-workspace/instances" 2>/dev/null)" "$HOME/ai-workspace-2"
  [[ -f "$HOME/ai-workspace/.env" ]] && nok "la principal no debe tocarse" || ok
  grep -q 'build' "$SB/fake/compose.log" 2>/dev/null && ok || nok "setup.sh debía llegar al build (compose.log vacío): $out"
}


t_devdb_tunnel_hostname() {
  if [[ "$(id -u)" -eq 0 ]]; then echo "  (omitida: devdb se niega a correr como root)"; return 0; fi
  mk_sandbox
  local dd="${DEVDB_UNDER_TEST:-$ROOT/config/devdb}"
  assert_eq "con AIWS_HOSTNAME" "ssh -N -L 5432:127.0.0.1:5432 ai@ai-workspace-foo" \
    "$(AIWS_HOSTNAME=ai-workspace-foo HOME="$SB/home" bash "$dd" tunnel 2>&1 | grep -o 'ssh -N -L [^ ]* ai@[^ ]*')"
  assert_eq "sin AIWS_HOSTNAME" "ssh -N -L 5432:127.0.0.1:5432 ai@ai-workspace" \
    "$(env -u AIWS_HOSTNAME HOME="$SB/home" bash "$dd" tunnel 2>&1 | grep -o 'ssh -N -L [^ ]* ai@[^ ]*')"
}


# =============================================================== install.sh
t_install_alias_validation() {
  load_install
  local a
  for a in a foo foo-bar 2 abcdefghijklmnopqrst; do assert_ok "válido: $a" aiws_alias_error "$a"; done
  for a in "" -a a- A foo_bar abcdefghijklmnopqrstu ts mssql postgres redis foo-ts foo-mssql; do
    assert_fail "inválido: '$a'" aiws_alias_error "$a"
  done
}

t_install_dir_for() {
  load_install
  assert_eq "dir principal" "$HOME/ai-workspace" "$(aiws_dir_for "")"
  assert_eq "dir alias" "$HOME/ai-workspace-foo" "$(aiws_dir_for foo)"
}

t_install_default_exists() {
  load_install
  assert_fail "nada" aiws_default_exists
  mkdir -p "$HOME/ai-workspace/.git"
  assert_fail "solo el clon (instalación fallida): se retoma la principal" aiws_default_exists
  rm -rf "$HOME/ai-workspace"
  fake_container "ai-workspace"
  assert_ok "por contenedor del workspace" aiws_default_exists
  : > "$SB/fake/containers"
  fake_container "ai-workspace-ts"
  assert_ok "por contenedor" aiws_default_exists
  : > "$SB/fake/containers"; fake_volume "ai_ts_state"
$1  : > "$SB/fake/volumes"; fake_volume "ai_home"
  assert_ok "por volumen home" aiws_default_exists
}

t_install_default_dir_without_git_is_not_instance() {
  load_install
  mkdir -p "$HOME/ai-workspace"        # carpeta suelta, no es un clon
  assert_fail "carpeta sin .git" aiws_default_exists
}

t_install_alias_taken() {
  load_install
  assert_fail "libre" aiws_alias_taken 2
  mkdir -p "$HOME/ai-workspace-2"
  assert_ok "por carpeta" aiws_alias_taken 2
  fake_container "ai-workspace-3";       assert_ok "por contenedor" aiws_alias_taken 3
  fake_container "ai-workspace-4-ts";    assert_ok "por sidecar" aiws_alias_taken 4
  fake_container "ai-workspace-5-mssql"; assert_ok "por mssql" aiws_alias_taken 5
  fake_volume "ai-workspace-6_home";     assert_ok "por volumen home" aiws_alias_taken 6
$1  fake_volume "ai-workspace-9_ssh_host_keys"; assert_ok "por volumen ssh" aiws_alias_taken 9
  fake_volume "ai-workspace-10_mssql_data"; assert_ok "por volumen mssql" aiws_alias_taken 10
  assert_fail "otro libre" aiws_alias_taken 8
}

t_install_next_free_alias() {
  load_install
  assert_eq "primero libre" "2" "$(aiws_next_free_alias)"
  mkdir -p "$HOME/ai-workspace-2"
  assert_eq "salta carpeta" "3" "$(aiws_next_free_alias)"
  fake_container "ai-workspace-3-ts"
  assert_eq "salta contenedor" "4" "$(aiws_next_free_alias)"
  fake_volume "ai-workspace-4_workspace"
  assert_eq "salta volumen" "5" "$(aiws_next_free_alias)"
}

t_install_list_instances() {
  load_install
  assert_eq "vacío" "" "$(aiws_list_instances)"
  mkdir -p "$HOME/ai-workspace/.git" "$HOME/ai-workspace-foo/.git" "$HOME/ai-workspace-suelta"
  fake_container "ai-workspace-ts"
  fake_label "ai-workspace-bar"; fake_label "ai-workspace-foo"
  assert_eq "unión de clones y etiquetas" "default
bar
foo" "$(aiws_list_instances)"
}

t_install_choose_non_interactive() {
  load_install
  aiws_have_tty() { return 1; }
  mkdir -p "$HOME/ai-workspace/.git"
  assert_eq "sin terminal: siguiente libre" "2" "$(aiws_choose_alias 2>/dev/null)"
  mkdir -p "$HOME/ai-workspace-2"
  assert_eq "sin terminal: salta ocupados" "3" "$(aiws_choose_alias 2>/dev/null)"
}

t_install_choose_interactive() {
  load_install
  aiws_have_tty() { return 0; }
  mkdir -p "$HOME/ai-workspace/.git"
  aiws_prompt() { echo ""; }
  assert_eq "Enter acepta la sugerencia" "2" "$(aiws_choose_alias 2>/dev/null)"
  aiws_prompt() { echo "cliente-a"; }
  assert_eq "alias escrito" "cliente-a" "$(aiws_choose_alias 2>/dev/null)"
}

t_install_choose_reasks_invalid() {
  load_install
  aiws_have_tty() { return 0; }
  mkdir -p "$HOME/ai-workspace/.git"
  printf '%s\n' "Mal_Alias" "ts" "bueno" > "$SB/answers"; echo 0 > "$SB/n"
  aiws_prompt() { local n; n="$(<"$SB/n")"; n=$((n+1)); echo "$n" > "$SB/n"; sed -n "${n}p" "$SB/answers"; }
  assert_eq "re-pregunta hasta un alias válido" "bueno" "$(aiws_choose_alias 2>/dev/null)"
  printf '%s\n' "Mal_Alias" "ts" "A" "bueno" > "$SB/answers"; echo 0 > "$SB/n"
  assert_fail "3 intentos inválidos: se rinde" aiws_choose_alias
}

t_install_default_untouched_when_no_default() {
  load_install
  aiws_have_tty() { return 1; }
  assert_eq "sin principal: instalar la principal" "" "$(aiws_pick_instance 2>/dev/null)"
}

t_install_pick_instance_explicit() {
  load_install
  mkdir -p "$HOME/ai-workspace/.git"
  fake_container "ai-workspace-ts"
  assert_eq "alias explícito" "foo" "$(aiws_pick_instance foo 2>/dev/null)"
  assert_eq "default explícito" "" "$(aiws_pick_instance default 2>/dev/null)"
}

t_install_pick_instance_rejects_invalid() {
  load_install
  assert_fail "alias inválido" aiws_pick_instance "Foo_Bar"
}

# ================================================================ T10: menú de install.sh y aiws en el PATH
# Dos instancias existentes: la principal (por su sidecar) y "foo" (por etiqueta)
two_instances() {
  fake_container "ai-workspace-ts"; fake_label "ai-workspace-foo"
}
# Clones con setup.sh falso que registra "carpeta|argumentos" y git simulado
fake_clones() {
  local d
  : > "$SB/calls"; : > "$SB/gitcalls"
  for d in ai-workspace ai-workspace-foo; do
    mkdir -p "$HOME/$d/.git"
    cat > "$HOME/$d/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "${PWD##*/}|$*" >> "$AIWS_TEST_CALLS"
[[ -f "$PWD/.fail" ]] && exit 1
exit 0
EOF
  done
  cat > "$SB/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$AIWS_TEST_GITCALLS"
exit 0
EOF
  chmod +x "$SB/bin/git"
  export AIWS_TEST_CALLS="$SB/calls" AIWS_TEST_GITCALLS="$SB/gitcalls"
}

t_install_menu_choices() {
  load_install
  two_instances
  local out
  aiws_prompt() { echo ""; }
  assert_eq "Enter = crear nueva" "new" "$(aiws_menu 2>/dev/null)"
  aiws_prompt() { echo "1"; };  assert_eq "1" "new" "$(aiws_menu 2>/dev/null)"
  aiws_prompt() { echo "2"; };  assert_eq "2 = principal" "update default" "$(aiws_menu 2>/dev/null)"
  aiws_prompt() { echo "3"; };  assert_eq "3 = foo" "update foo" "$(aiws_menu 2>/dev/null)"
  aiws_prompt() { echo "4"; };  assert_eq "4 = todas" "update default foo" "$(aiws_menu 2>/dev/null)"
  out="$(aiws_menu 2>&1 >/dev/null)"
  assert_has "opción crear" "$out" "1) Crear una instancia nueva"
  assert_has "opción actualizar principal" "$out" "2) Actualizar default"
  assert_has "opción actualizar foo" "$out" "3) Actualizar foo"
  assert_has "opción todas" "$out" "4) Actualizar todas"
}

t_install_menu_reasks() {
  load_install
  two_instances
  printf '%s\n' "9" "x" "3" > "$SB/answers"; echo 0 > "$SB/n"
  aiws_prompt() { local n; n="$(<"$SB/n")"; n=$((n+1)); echo "$n" > "$SB/n"; sed -n "${n}p" "$SB/answers"; }
  assert_eq "re-pregunta" "update foo" "$(aiws_menu 2>/dev/null)"
  printf '%s\n' "9" "x" "0" "2" > "$SB/answers"; echo 0 > "$SB/n"
  assert_fail "3 intentos inválidos" aiws_menu
}

t_install_update_instances() {
  load_install
  fake_clones
  aiws_update_instances default foo >/dev/null 2>&1; assert_eq "rc 0" "0" "$?"
  assert_eq "setup.sh upgrade en cada clon" "ai-workspace|upgrade --yes
ai-workspace-foo|upgrade --yes" "$(cat "$SB/calls")"
  assert_eq "sin git pull (lo hace setup.sh upgrade)" "" "$(cat "$SB/gitcalls")"
}

t_install_update_instances_failure_continues() {
  load_install
  fake_clones
  touch "$HOME/ai-workspace/.fail"
  local out; out="$(aiws_update_instances default zzz foo 2>&1)"; local rc=$?
  assert_eq "rc distinto de 0" "1" "$rc"
  assert_eq "siguió con foo pese a los fallos" "ai-workspace|upgrade --yes
ai-workspace-foo|upgrade --yes" "$(cat "$SB/calls")"
  assert_has "resumen fallo" "$out" "fallo"
  assert_has "carpeta inexistente" "$out" "zzz"
}

t_install_main_menu_update() {
  load_install
  fake_clones; two_instances
  aiws_have_tty() { return 0; }
  aiws_prompt() { echo "3"; }
  main --pubkey x >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "actualizó foo y no instaló nada" "ai-workspace-foo|upgrade --yes" "$(cat "$SB/calls")"
}

t_setup_summary_mentions_aiws() {
  load_setup
  instance_names "foo"
  cp "$SB/repo/env.example" "$SB/repo/.env"; write_instance_env
  local out; out="$(summary 2>&1)"
  assert_has "aiws help" "$out" "aiws help"
}

# Enlace de aiws en el PATH (se omite donde no hay enlaces simbólicos, p. ej. Git Bash)
t_setup_aiws_link() {
  load_setup
  ln -s "$ROOT/aiws" "$SB/probe" 2>/dev/null
  if [[ ! -L "$SB/probe" ]]; then echo "  (omitida: este sistema no crea enlaces simbólicos)"; return 0; fi
  cp "$ROOT/aiws" "$SCRIPT_DIR/aiws"
  mkdir -p "$SB/sys"; export AIWS_SYSTEM_BIN="$SB/sys"
  install_aiws_link >/dev/null 2>&1
  assert_eq "en la carpeta del sistema" "$SCRIPT_DIR/aiws" "$(readlink "$SB/sys/aiws")"
  # ya existe un enlace a otro clon vivo: se respeta
  mkdir -p "$SB/otro"; cp "$ROOT/aiws" "$SB/otro/aiws"; ln -sfn "$SB/otro/aiws" "$SB/sys/aiws"
  install_aiws_link >/dev/null 2>&1
  assert_eq "no pisa un enlace vivo" "$SB/otro/aiws" "$(readlink "$SB/sys/aiws")"
  # enlace roto: se rehace
  ln -sfn "$SB/no/existe" "$SB/sys/aiws"
  install_aiws_link >/dev/null 2>&1
  assert_eq "rehace un enlace roto" "$SCRIPT_DIR/aiws" "$(readlink "$SB/sys/aiws")"
  # sin permisos en la carpeta del sistema: ~/.local/bin y aviso de PATH
  rm -f "$SB/sys/aiws"; export AIWS_SYSTEM_BIN="$SB/no-escribible"
  local out; out="$(install_aiws_link 2>&1)"
  assert_eq "en ~/.local/bin" "$SCRIPT_DIR/aiws" "$(readlink "$HOME/.local/bin/aiws")"
  assert_has "avisa del PATH" "$out" "PATH"
}


# ================================================================ ronda 3: códigos de salida, registro y enlace
t_setup_report_status_propagates() {
  load_setup
  mkdir -p "$LOG_DIR"; : > "$LOG_DIR/latest.log"
  echo 3 > "$STATUS_FILE"
  ( report_status ) >/dev/null 2>&1; assert_eq "report_status propaga el código" "3" "$?"
  ( follow ) >/dev/null 2>&1;        assert_eq "follow propaga el código" "3" "$?"
  echo 0 > "$STATUS_FILE"
  ( report_status ) >/dev/null 2>&1; assert_eq "éxito" "0" "$?"
  rm -f "$STATUS_FILE"
  ( report_status ) >/dev/null 2>&1; assert_eq "sin estado" "0" "$?"
}

t_setup_follow_busy_returns_real_status() {
  load_setup
  mkdir -p "$LOG_DIR"; : > "$LOG_DIR/latest.log"
  # un proceso en curso que termina con error y deja su estado
  ( sleep 1; echo 7 > "$STATUS_FILE"; rm -f "$PID_FILE" ) &
  echo $! > "$PID_FILE"
  rm -f "$STATUS_FILE"
  ( run_bg install install_steps_never_used ) >/dev/null 2>&1; assert_eq "ya en curso: devuelve el estado real" "7" "$?"
}

t_setup_registry() {
  load_setup
  unset XDG_DATA_HOME
  local f="$HOME/.local/share/ai-workspace/instances"
  registry_add; registry_add
  assert_eq "una línea, sin duplicados" "$SCRIPT_DIR" "$(cat "$f")"
  echo "/otra/carpeta" >> "$f"
  registry_remove
  assert_eq "quita solo la propia" "/otra/carpeta" "$(cat "$f")"
  export XDG_DATA_HOME="$SB/xdg"; registry_add
  assert_eq "respeta XDG_DATA_HOME" "$SCRIPT_DIR" "$(cat "$SB/xdg/ai-workspace/instances")"
}

t_setup_uninstall_unregisters() {
  load_setup
  unset XDG_DATA_HOME
  registry_add
  uninstall --yes >/dev/null 2>&1
  assert_eq "uninstall quita el registro" "" "$(cat "$HOME/.local/share/ai-workspace/instances" 2>/dev/null)"
  registry_add
  uninstall --all --yes >/dev/null 2>&1
  assert_eq "purge quita el registro" "" "$(cat "$HOME/.local/share/ai-workspace/instances" 2>/dev/null)"
}

t_setup_root_clone_warning() {
  load_setup
  printf '#!/usr/bin/env bash\necho 0\n' > "$SB/bin/id"; chmod +x "$SB/bin/id"
  SCRIPT_DIR=/root/ai-workspace
  assert_has "root con clon en /root" "$(warn_root_clone 2>&1)" "otros usuarios"
  SCRIPT_DIR=/home/x/ai-workspace
  assert_eq "clon fuera de /root" "" "$(warn_root_clone 2>&1)"
  printf '#!/usr/bin/env bash\necho 1000\n' > "$SB/bin/id"
  SCRIPT_DIR=/root/ai-workspace
  assert_eq "usuario normal" "" "$(warn_root_clone 2>&1)"
}

# enlaces: se omite donde no existan los enlaces simbólicos
t_setup_aiws_link_edge_cases() {
  load_setup
  ln -s "$ROOT/aiws" "$SB/probe" 2>/dev/null
  if [[ ! -L "$SB/probe" ]]; then echo "  (omitida: este sistema no crea enlaces simbólicos)"; return 0; fi
  cp "$ROOT/aiws" "$SCRIPT_DIR/aiws"
  mkdir -p "$SB/sys" "$HOME/.local/bin"; export AIWS_SYSTEM_BIN="$SB/sys"
  # enlace roto en una carpeta sin escritura: cae a ~/.local/bin
  ln -sfn "$SB/no/existe" "$SB/sys/aiws"
  is_writable() { [[ "$1" != "$SB/sys" ]]; }
  install_aiws_link >/dev/null 2>&1
  assert_eq "cae a ~/.local/bin" "$SCRIPT_DIR/aiws" "$(readlink "$HOME/.local/bin/aiws")"
  # un archivo normal llamado aiws no se pisa
  rm -f "$SB/sys/aiws" "$HOME/.local/bin/aiws"; echo "mio" > "$SB/sys/aiws"
  is_writable() { return 0; }
  install_aiws_link >/dev/null 2>&1
  assert_eq "archivo normal intacto" "mio" "$(cat "$SB/sys/aiws")"
  assert_eq "usa la otra carpeta" "$SCRIPT_DIR/aiws" "$(readlink "$HOME/.local/bin/aiws")"
}


# ================================================================ ronda 5: setup.sh upgrade sin preguntas
# git simulado: cuántos commits faltan ($SB/behind) y si hay cambios locales ($SB/dirty)
fake_git_for_upgrade() {
  echo 0 > "$SB/behind"; : > "$SB/dirty"; : > "$SB/gitcalls"; : > "$SB/updates"
  cat > "$SB/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SB_GITCALLS"
case " $* " in
  *" rev-list "*)  cat "$SB_BEHIND" ;;
  *" status "*)    cat "$SB_DIRTY" ;;
  *" rev-parse "*) echo abc123 ;;
  *" log "*)       echo "abc123 mensaje" ;;
esac
exit 0
EOF
  chmod +x "$SB/bin/git"
  export SB_GITCALLS="$SB/gitcalls" SB_BEHIND="$SB/behind" SB_DIRTY="$SB/dirty"
  mkdir -p "$SCRIPT_DIR/.git"; cp "$SB/repo/env.example" "$SB/repo/.env"
  run_update() { echo "UPDATE $*" >> "$SB/updates"; }
}

t_setup_g_never_pages() {
  load_setup
  fake_git_for_upgrade
  g log -1 >/dev/null 2>&1
  assert_has "git sin paginador" "$(cat "$SB/gitcalls")" "--no-pager"
}

t_setup_upgrade_no_tty_requires_yes() {
  load_setup
  fake_git_for_upgrade
  has_tty() { return 1; }
  local out; out="$(upgrade 2>&1)"; local rc=$?
  assert_eq "falla" "1" "$rc"
  assert_has "explica" "$out" "--yes"
  assert_eq "no tocó git" "" "$(cat "$SB/gitcalls")"
  assert_eq "no reconstruyó" "" "$(cat "$SB/updates")"
}

t_setup_upgrade_yes_updates_and_rebuilds() {
  load_setup
  fake_git_for_upgrade
  has_tty() { return 1; }
  echo 2 > "$SB/behind"; echo " M Dockerfile" > "$SB/dirty"
  export AIWS_UPGRADE_RESULT_FILE="$SB/result"
  upgrade --yes >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_has "guardó cambios locales" "$(cat "$SB/gitcalls")" "stash push"
  assert_has "fusionó" "$(cat "$SB/gitcalls")" "merge"
  assert_eq "reconstruye sin preguntar" "UPDATE " "$(cat "$SB/updates")"
  assert_eq "resultado para aiws" "updated" "$(cat "$SB/result")"
  [[ -s "$LOG_DIR/.prev-version" ]] && ok || nok "debe guardar .prev-version para rollback"
}

t_setup_upgrade_yes_up_to_date() {
  load_setup
  fake_git_for_upgrade
  has_tty() { return 1; }
  export AIWS_UPGRADE_RESULT_FILE="$SB/result"
  local out; out="$(upgrade -y 2>&1)"; assert_eq "rc 0" "0" "$?"
  assert_has "ya al día" "$out" "ya al día"
  assert_eq "no reconstruye" "" "$(cat "$SB/updates")"
  assert_eq "resultado para aiws" "uptodate" "$(cat "$SB/result")"
  upgrade --yes --rebuild >/dev/null 2>&1
  assert_eq "--rebuild fuerza la reconstrucción" "UPDATE " "$(cat "$SB/updates")"
}

t_setup_upgrade_yes_foreground_passes() {
  load_setup
  fake_git_for_upgrade
  has_tty() { return 1; }
  echo 1 > "$SB/behind"
  upgrade --yes --foreground >/dev/null 2>&1
  assert_eq "--foreground llega al update" "UPDATE --foreground" "$(cat "$SB/updates")"
}

t_setup_upgrade_interactive_unchanged() {
  load_setup
  fake_git_for_upgrade
  has_tty() { return 0; }
  echo 1 > "$SB/behind"
  upgrade >/dev/null 2>&1 <<<"n"
  assert_eq "con tty y sin --yes pregunta (N = no reconstruye)" "" "$(cat "$SB/updates")"
  upgrade >/dev/null 2>&1 <<<"s"
  assert_eq "responde s: reconstruye" "UPDATE " "$(cat "$SB/updates")"
}

t_setup_upgrade_unknown_option() {
  load_setup
  fake_git_for_upgrade
  assert_fail "opción desconocida" upgrade --nada
}


# ================================================================ T12-T14: recursos por instancia
t_setup_suggest_mem() {
  load_setup
  local kb n want
  # RAM en kB | instancias existentes | sugerencia esperada
  while read -r kb n want; do
    AIWS_HOST_MEM_KB="$kb"
    assert_eq "RAM ${kb}kB, $n existentes" "$want" "$(suggest_mem "$n")"
  done <<'EOF'
16777216 0 8g
16777216 1 7g
16777216 2 4g
16777216 3 3g
8388608 0 6g
8388608 1 3g
8388608 2 2g
4194304 0 2g
4194304 1 2g
2097152 0 2g
67108864 0 8g
EOF
  AIWS_HOST_MEM_KB=4194304; suggest_mem_is_tiny 1 && ok || nok "4g con 1 existente es justo"
  AIWS_HOST_MEM_KB=16777216; suggest_mem_is_tiny 0 && nok "16g no es pequeño" || ok
  AIWS_HOST_MEM_KB=2097152;  suggest_mem_is_tiny 0 && ok || nok "2g es pequeño"
}

t_setup_suggest_cpus() {
  load_setup
  local c
  for c in "8 4" "4 4" "2 2" "1 1"; do
    AIWS_HOST_CPUS="${c% *}"; assert_eq "nproc ${c% *}" "${c#* }" "$(suggest_cpus)"
  done
}

t_setup_res_validation() {
  load_setup
  AIWS_HOST_CPUS=4
  local v
  for v in 1g 4g 4G 1.5g 4gb 1024m 16g; do assert_ok "MEM_LIMIT válido: $v" res_check MEM_LIMIT "$v"; done
  for v in "" abc 0 4 512m 0.5g -1g 4x; do assert_fail "MEM_LIMIT inválido: '$v'" res_check MEM_LIMIT "$v"; done
  res_check MEM_LIMIT 4G >/dev/null 2>&1; assert_eq "normaliza" "4g" "$RES_VALUE"
  res_check MEM_LIMIT 4GB >/dev/null 2>&1; assert_eq "normaliza gb" "4g" "$RES_VALUE"
  assert_has "avisa por debajo de 2g" "$(res_check MEM_LIMIT 1g 2>&1)" "2g"
  assert_eq "sin aviso con 2g" "" "$(res_check MEM_LIMIT 2g 2>&1)"
  for v in 1g 512m 64m; do assert_ok "SHM_SIZE válido: $v" res_check SHM_SIZE "$v"; done
  for v in 0 abc "" 2; do assert_fail "SHM_SIZE inválido: '$v'" res_check SHM_SIZE "$v"; done
  for v in 1 2 1.5 0.5 4; do assert_ok "CPUS válido: $v" res_check CPUS "$v"; done
  for v in 0 -1 abc "" 5 4.1 1.; do assert_fail "CPUS inválido: '$v'" res_check CPUS "$v"; done
  for v in 256 2048 4096; do assert_ok "PIDS_LIMIT válido: $v" res_check PIDS_LIMIT "$v"; done
  for v in 255 0 abc "" 1.5; do assert_fail "PIDS_LIMIT inválido: '$v'" res_check PIDS_LIMIT "$v"; done
  assert_ok "MSSQL_MEM_LIMIT" res_check MSSQL_MEM_LIMIT 2g
}

res_env() {   # prepara .env y entorno de prueba para `resources`
  cp "$SB/repo/env.example" "$SB/repo/.env"
  export AIWS_HOST_MEM_KB=16777216 AIWS_HOST_CPUS=8
  : > "$SB/fake/compose.log"
  wait_healthy() { :; }
  has_tty() { return 1; }
}

t_setup_resources_set_writes_env() {
  load_setup; res_env
  resources --mem 4G --cpus 2 --shm 1g --pids 4096 --mssql-mem 2g --no-apply >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "MEM_LIMIT" "4g" "$(env_get MEM_LIMIT)"
  assert_eq "CPUS" "2" "$(env_get CPUS)"
  assert_eq "SHM_SIZE" "1g" "$(env_get SHM_SIZE)"
  assert_eq "PIDS_LIMIT" "4096" "$(env_get PIDS_LIMIT)"
  assert_eq "MSSQL_MEM_LIMIT" "2g" "$(env_get MSSQL_MEM_LIMIT)"
  assert_eq "--no-apply no toca compose" "" "$(cat "$SB/fake/compose.log")"
}

t_setup_resources_invalid_writes_nothing() {
  load_setup; res_env
  assert_fail "valor inválido" resources --mem abc --no-apply
  assert_fail "todo o nada" resources --mem 4g --cpus 99 --no-apply
  assert_eq "MEM_LIMIT intacto" "8g" "$(env_get MEM_LIMIT)"
  assert_eq "CPUS intacto" "4" "$(env_get CPUS)"
  assert_fail "opción desconocida" resources --nada
}

t_setup_resources_apply_without_build() {
  load_setup; res_env
  fake_container "$CONTAINER"
  resources --mem 4g >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_has "recrea solo con up --no-build" "$(cat "$SB/fake/compose.log")" "up -d --no-build"
  assert_lacks "nunca reconstruye" "$(cat "$SB/fake/compose.log")" "build --pull"
  : > "$SB/fake/compose.log"; : > "$SB/fake/containers"
  resources --mem 3g >/dev/null 2>&1
  assert_eq "sin contenedores: solo guarda" "" "$(cat "$SB/fake/compose.log")"
  assert_eq "guardado igualmente" "3g" "$(env_get MEM_LIMIT)"
}

t_setup_resources_show() {
  load_setup; res_env
  fake_container "$CONTAINER"
  echo "1.2GiB / 8GiB|3.4%" > "$SB/fake/stats"
  local out; out="$(resources 2>&1)"; assert_eq "rc" "0" "$?"
  assert_has "límite de memoria" "$out" "8g"
  assert_has "uso de memoria" "$out" "1.2GiB"
  assert_has "uso de CPU" "$out" "3.4%"
  assert_has "shm" "$out" "2gb"
  assert_has "pids" "$out" "2048"
  assert_has "servidor" "$out" "16"
  : > "$SB/fake/containers"
  assert_has "detenida" "$(resources 2>&1)" "detenida"
}

t_setup_resources_warns_over_host() {
  load_setup; res_env
  export AIWS_HOST_MEM_KB=8388608
  unset XDG_DATA_HOME
  mkdir -p "$SB/otra"; echo "MEM_LIMIT=2g" > "$SB/otra/.env"
  mkdir -p "$HOME/.local/share/ai-workspace"; echo "$SB/otra" > "$HOME/.local/share/ai-workspace/instances"
  local out; out="$(resources --mem 8g --no-apply 2>&1)"
  assert_has "avisa que supera la RAM" "$out" "supera"
  assert_has "explica que son topes" "$out" "tope"
  out="$(resources --mem 2g --no-apply 2>&1)"
  assert_lacks "sin aviso si cabe" "$out" "supera"
}

t_setup_resources_set_interactive() {
  load_setup; res_env
  has_tty() { return 0; }
  : > "$SB/prompts"; printf '%s\n' "" "2" "" "" > "$SB/answers"; echo 0 > "$SB/n"
  ask_value() { echo "$1" >> "$SB/prompts"; local n; n="$(<"$SB/n")"; n=$((n+1)); echo "$n" > "$SB/n"; sed -n "${n}p" "$SB/answers"; }
  resources --set --no-apply >/dev/null 2>&1; assert_eq "rc" "0" "$?"
  assert_eq "Enter conserva el actual" "8g" "$(env_get MEM_LIMIT)"
  assert_eq "valor escrito" "2" "$(env_get CPUS)"
  assert_has "muestra el actual" "$(cat "$SB/prompts")" "actual 8g"
  assert_has "muestra la sugerencia" "$(cat "$SB/prompts")" "sugerido"
  has_tty() { return 1; }
  assert_fail "--set sin terminal" resources --set --no-apply
}

t_setup_sizing_noninteractive() {
  load_setup
  has_tty() { return 1; }
  unset XDG_DATA_HOME
  export AIWS_HOST_MEM_KB=16777216 AIWS_HOST_CPUS=8
  bind_alias "foo"; configure_env "tskey-auth-t" >/dev/null 2>&1
  assert_eq "16g y sin otras: 8g" "8g" "$(env_get MEM_LIMIT)"
  assert_eq "cpus tope 4" "4" "$(env_get CPUS)"
  rm -f "$ENV_FILE"
  export AIWS_HOST_MEM_KB=8388608 AIWS_HOST_CPUS=2
  mkdir -p "$SB/otra"; echo "MEM_LIMIT=2g" > "$SB/otra/.env"
  mkdir -p "$HOME/.local/share/ai-workspace"; echo "$SB/otra" > "$HOME/.local/share/ai-workspace/instances"
  local out; out="$(configure_env "tskey-auth-t" 2>&1)"
  assert_eq "8g con una existente: 3g" "3g" "$(env_get MEM_LIMIT)"
  assert_eq "nproc 2" "2" "$(env_get CPUS)"
  assert_has "informa lo aplicado" "$out" "3g"
  rm -f "$ENV_FILE"; rm -rf "$HOME/.local/share/ai-workspace"
  export AIWS_HOST_MEM_KB=2097152
  out="$(configure_env "tskey-auth-t" 2>&1)"
  assert_eq "host diminuto: mínimo 2g" "2g" "$(env_get MEM_LIMIT)"
  assert_has "avisa de poca memoria" "$out" "poca memoria"
}

t_setup_sizing_explicit_flags() {
  load_setup
  has_tty() { return 0; }
  ask_value() { echo PREGUNTO >> "$SB/asked"; echo ""; }
  export AIWS_HOST_MEM_KB=16777216 AIWS_HOST_CPUS=8
  SIZE_MEM=3G SIZE_CPUS=2
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "MEM_LIMIT explícito" "3g" "$(env_get MEM_LIMIT)"
  assert_eq "CPUS explícito" "2" "$(env_get CPUS)"
  assert_eq "no pregunta lo ya indicado" "" "$(cat "$SB/asked" 2>/dev/null)"
  rm -f "$ENV_FILE"; SIZE_MEM=abc SIZE_CPUS=""
  assert_fail "valor inválido de --mem" configure_env "tskey-auth-t"
}

t_setup_sizing_interactive_prompts() {
  load_setup
  has_tty() { return 0; }
  export AIWS_HOST_MEM_KB=16777216 AIWS_HOST_CPUS=8
  : > "$SB/prompts"
  # Enter acepta la sugerencia
  ask_value() { echo "$1" >> "$SB/prompts"; echo ""; }
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "Enter = sugerido (mem)" "8g" "$(env_get MEM_LIMIT)"
  assert_eq "Enter = sugerido (cpus)" "4" "$(env_get CPUS)"
  assert_has "prompt de memoria con sugerencia" "$(cat "$SB/prompts")" "Memoria máxima [8g]"
  assert_has "prompt de CPUs con sugerencia" "$(cat "$SB/prompts")" "CPUs [4]"
  # valor inválido y luego válido
  rm -f "$ENV_FILE"; printf '%s\n' "x" "5g" "" > "$SB/answers"; echo 0 > "$SB/n"
  ask_value() { local n; n="$(<"$SB/n")"; n=$((n+1)); echo "$n" > "$SB/n"; sed -n "${n}p" "$SB/answers"; }
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "re-pregunta tras un valor inválido" "5g" "$(env_get MEM_LIMIT)"
  # tres inválidos: cae a la sugerencia
  rm -f "$ENV_FILE"; printf '%s\n' "x" "y" "z" "" > "$SB/answers"; echo 0 > "$SB/n"
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "3 intentos inválidos: sugerencia" "8g" "$(env_get MEM_LIMIT)"
}

t_setup_sizing_existing_env_untouched() {
  load_setup
  has_tty() { return 1; }
  export AIWS_HOST_MEM_KB=4194304 AIWS_HOST_CPUS=2
  cp "$SB/repo/env.example" "$ENV_FILE"; env_set MEM_LIMIT 8g; env_set CPUS 4
  SIZE_MEM=""; SIZE_CPUS=""
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "no cambia MEM_LIMIT" "8g" "$(env_get MEM_LIMIT)"
  assert_eq "no cambia CPUS" "4" "$(env_get CPUS)"
  SIZE_MEM=3g
  configure_env "tskey-auth-t" </dev/null >/dev/null 2>&1
  assert_eq "un --mem explícito sí se aplica" "3g" "$(env_get MEM_LIMIT)"
}


run t_setup_default_names
run t_setup_default_alias_word
run t_setup_alias_names
run t_setup_instance_read_from_env
run t_setup_invalid_instance_dies
run t_setup_alias_validation
run t_setup_other_instances
run t_setup_no_other_instances
run t_setup_owner_check
run t_setup_owner_default
run t_setup_write_env_alias
run t_setup_write_env_default
run t_setup_configure_env_alias
run t_setup_bind_alias_conflict
run t_setup_bind_alias_fresh_clone
run t_setup_bind_alias_owned_container
run t_setup_bind_alias_env_conflict
run t_setup_env_crlf
run t_setup_summary_shows_instance
run t_install_alias_validation
run t_install_dir_for
run t_install_default_exists
run t_install_default_dir_without_git_is_not_instance
run t_install_alias_taken
run t_install_next_free_alias
run t_install_list_instances
run t_install_choose_non_interactive
run t_install_choose_interactive
run t_install_choose_reasks_invalid
run t_install_default_untouched_when_no_default
run t_install_pick_instance_explicit
run t_install_pick_instance_rejects_invalid
run t_devdb_tunnel_hostname
run t_e2e_second_instance_via_install_sh
run t_install_menu_choices
run t_install_menu_reasks
run t_install_update_instances
run t_install_update_instances_failure_continues
run t_install_main_menu_update
run t_setup_summary_mentions_aiws
run t_setup_aiws_link
run t_setup_report_status_propagates
run t_setup_follow_busy_returns_real_status
run t_setup_registry
run t_setup_uninstall_unregisters
run t_setup_root_clone_warning
run t_setup_aiws_link_edge_cases
run t_setup_g_never_pages
run t_setup_upgrade_no_tty_requires_yes
run t_setup_upgrade_yes_updates_and_rebuilds
run t_setup_upgrade_yes_up_to_date
run t_setup_upgrade_yes_foreground_passes
run t_setup_upgrade_interactive_unchanged
run t_setup_upgrade_unknown_option
run t_setup_suggest_mem
run t_setup_suggest_cpus
run t_setup_res_validation
run t_setup_resources_set_writes_env
run t_setup_resources_invalid_writes_nothing
run t_setup_resources_apply_without_build
run t_setup_resources_show
run t_setup_resources_warns_over_host
run t_setup_resources_set_interactive
run t_setup_sizing_noninteractive
run t_setup_sizing_explicit_flags
run t_setup_sizing_interactive_prompts
run t_setup_sizing_existing_env_untouched

p="$(wc -l < "$PASSES" | tr -d ' ')"; f="$(wc -l < "$FAILS" | tr -d ' ')"
echo
echo "Resultado: $p aserciones correctas, $f fallidas"
(( f == 0 ))
