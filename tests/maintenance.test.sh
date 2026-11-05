#!/usr/bin/env bash
# =============================================================================
# Pruebas de "setup.sh clean", "setup.sh rollback" y "setup.sh uninstall --all".
#
#   bash tests/maintenance.test.sh
#
# Usa un "docker" simulado y un repo git desechable en un directorio temporal;
# no toca volúmenes, contenedores ni el repo del equipo donde se ejecuta.
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

# ------------------------------------------------------------------- sandbox
# Repo copiado (SCRIPT_DIR propio), HOME falso y docker simulado:
#  - volúmenes en $F/volumes; "volume rm" falla para los listados en $F/stuck
#  - el resto de llamadas tiene éxito sin hacer nada
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake" "$SB/repo/backups"
  : > "$SB/fake/volumes"; : > "$SB/fake/stuck"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
case "${1:-} ${2:-}" in
  "volume inspect") grep -qxF "$3" "$F/volumes" ;;
  "volume rm")      grep -qxF "$3" "$F/volumes" || { echo "no such volume" >&2; exit 1; }
                    grep -qxF "$3" "$F/stuck" && { echo "volume is in use" >&2; exit 1; }
                    grep -vxF "$3" "$F/volumes" > "$F/v.tmp"; mv "$F/v.tmp" "$F/volumes" ;;
  *)                exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/env.example" "$SB/repo/"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
}

load_setup() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"
  set +eEu; trap - ERR
  confirm() { echo "$1" >> "$SB/prompts"; return 0; }   # por defecto "sí" a todo, registrando la pregunta
  BK="$SB/repo/backups"
}

# ================================================================ clean
t_clean_does_not_delete_backups() {   # S4: los respaldos solo rotan con "backup"
  load_setup
  # shellcheck disable=SC2034  # lo leería clean
  BACKUP_KEEP=2
  local d
  for d in 01 02 03 04; do
    : > "$BK/ai-workspace-202601$d-100000.tar.gz"; : > "$BK/ai-workspace-202601$d-100000.tar.gz.sha256"
    touch -d "2026-01-$d" "$BK/ai-workspace-202601$d-100000.tar.gz"
  done
  ( clean ) >/dev/null 2>&1
  assert_eq "conserva los 4 respaldos" 4 "$(cd "$BK" && ls -- *.tar.gz | wc -l)"
  assert_eq "conserva los 4 checksums" 4 "$(cd "$BK" && ls -- *.sha256 | wc -l)"
}

t_clean_still_rotates_logs() {   # comportamiento previo
  load_setup
  # shellcheck disable=SC2034  # lo lee clean
  LOG_KEEP=2
  mkdir -p "$LOG_DIR"; local i
  for i in 1 2 3 4; do touch -d "2026-01-0$i" "$LOG_DIR/install-2026010$i.log"; done
  ( clean ) >/dev/null 2>&1
  assert_eq "quedan 2 logs" "install-20260103.log install-20260104.log" "$(cd "$LOG_DIR" && ls -- *.log | sort | tr '\n' ' ' | sed 's/ $//')"
}

# ================================================================ rollback
# Repo git real en el sandbox: v1 -> v2 (con .prev-version = v1); run_update se simula
mk_git_repo() {
  local r="$SB/repo"
  git -C "$r" init -q; git -C "$r" config user.email t@t; git -C "$r" config user.name t
  echo v1 > "$r/notes.txt"; git -C "$r" add -A; git -C "$r" commit -qm v1
  V1="$(git -C "$r" rev-parse HEAD)"
  echo v2 > "$r/notes.txt"; git -C "$r" commit -qam v2
  mkdir -p "$LOG_DIR"; echo "$V1" > "$LOG_DIR/.prev-version"
  run_update() { echo "UPDATE $*" >> "$SB/updates"; }
}

t_rollback_stashes_local_changes() {   # S8: no se pierden con reset --hard
  load_setup; mk_git_repo
  echo "mi cambio" > "$SB/repo/notes.txt"
  ( rollback ) >/dev/null 2>&1
  assert_eq "vuelve a v1" "$V1" "$(git -C "$SB/repo" rev-parse HEAD)"
  assert_eq "un stash" 1 "$(git -C "$SB/repo" stash list | wc -l)"
  assert_has "el stash guarda el cambio" "$(git -C "$SB/repo" stash show -p 2>/dev/null)" "+mi cambio"
  assert_has "pregunta como upgrade" "$(cat "$SB/prompts" 2>/dev/null)" "(git stash)"
  assert_eq "reconstruye" "UPDATE " "$(cat "$SB/updates" 2>/dev/null)"
}

t_rollback_keeps_changes_when_stash_is_declined() {   # S8: "no" a guardarlos = no se toca nada
  load_setup; mk_git_repo
  confirm() { [[ "$1" != *stash* ]]; }
  echo "mi cambio" > "$SB/repo/notes.txt"
  ( rollback ) >/dev/null 2>&1
  assert_eq "sigue en v2" "v2" "$(git -C "$SB/repo" log -1 --format=%s)"
  assert_eq "el cambio sigue ahí" "mi cambio" "$(cat "$SB/repo/notes.txt")"
  assert_eq "no reconstruye" "" "$(cat "$SB/updates" 2>/dev/null)"
}

t_rollback_yes_does_not_prompt() {   # S8: --yes salta las preguntas
  load_setup; mk_git_repo
  echo "mi cambio" > "$SB/repo/notes.txt"
  ( rollback --yes ) >/dev/null 2>&1
  assert_eq "sin preguntas" "" "$(cat "$SB/prompts" 2>/dev/null)"
  assert_eq "un stash" 1 "$(git -C "$SB/repo" stash list | wc -l)"
  assert_eq "vuelve a v1" "$V1" "$(git -C "$SB/repo" rev-parse HEAD)"
}

t_rollback_clean_tree_still_resets_and_rebuilds() {   # comportamiento previo
  load_setup; mk_git_repo
  ( rollback ) >/dev/null 2>&1
  assert_eq "vuelve a v1" "$V1" "$(git -C "$SB/repo" rev-parse HEAD)"
  assert_eq "sin stash" 0 "$(git -C "$SB/repo" stash list | wc -l)"
  assert_eq "reconstruye" "UPDATE " "$(cat "$SB/updates" 2>/dev/null)"
}

# ================================================================ uninstall --all
mk_instance() {
  printf 'AIWS_X=1\n' > "$ENV_FILE"; registry_add
  local v; for v in "${ALL_VOLUMES[@]}"; do echo "$v" >> "$SB/fake/volumes"; done
}

t_uninstall_all_keeps_env_and_registry_when_a_volume_fails() {   # S7
  load_setup; mk_instance
  echo "${VOLUMES[0]}" > "$SB/fake/stuck"
  local out; out="$(uninstall --all --yes 2>&1)"; local rc=$?
  (( rc != 0 )) && ok || nok "debía terminar con error"
  assert_has "nombra el volumen" "$out" "${VOLUMES[0]}"
  assert_lacks "no dice que borró todo" "$out" "Todo eliminado"
  [[ -f "$ENV_FILE" ]] && ok || nok "debía conservar .env"
  assert_eq "conserva el registro" "$SCRIPT_DIR" "$(cat "$(registry_file)" 2>/dev/null)"
}

t_uninstall_all_still_removes_everything() {   # comportamiento previo
  load_setup; mk_instance
  local out; out="$(uninstall --all --yes 2>&1)"; local rc=$?
  assert_eq "rc" 0 "$rc"
  assert_has "avisa" "$out" "Todo eliminado"
  assert_eq "sin volúmenes" "" "$(cat "$SB/fake/volumes")"
  [[ ! -e "$ENV_FILE" ]] && ok || nok "debía borrar .env"
  assert_eq "quita el registro" "" "$(cat "$(registry_file)" 2>/dev/null)"
}

t_uninstall_all_ignores_volumes_that_never_existed() {   # p. ej. mssql sin activar
  load_setup; mk_instance
  grep -v mssql "$SB/fake/volumes" > "$SB/fake/v"; mv "$SB/fake/v" "$SB/fake/volumes"
  local out; out="$(uninstall --all --yes 2>&1)"; local rc=$?
  assert_eq "rc" 0 "$rc"
  assert_has "avisa" "$out" "Todo eliminado"
}

for t in t_clean_does_not_delete_backups t_clean_still_rotates_logs \
         t_rollback_stashes_local_changes t_rollback_keeps_changes_when_stash_is_declined \
         t_rollback_yes_does_not_prompt t_rollback_clean_tree_still_resets_and_rebuilds \
         t_uninstall_all_keeps_env_and_registry_when_a_volume_fails t_uninstall_all_still_removes_everything \
         t_uninstall_all_ignores_volumes_that_never_existed; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
