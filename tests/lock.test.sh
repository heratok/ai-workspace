#!/usr/bin/env bash
# =============================================================================
# Pruebas del bloqueo por instancia: dos comandos que modifican la misma
# instancia nunca corren a la vez (flock sobre logs/.lock).
#
#   bash tests/lock.test.sh
#
# Usa un "docker" simulado que registra sus llamadas; no toca contenedores reales.
# Sin flock (p. ej. Git Bash en Windows) se omiten las pruebas que lo necesitan.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOLDER=""
trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

SKIPPED=0
HAVE_FLOCK=0; command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1
run_flock() {
  if (( HAVE_FLOCK )); then run "$1"
  else echo "== $1 (OMITIDA: sin flock en este entorno)"; SKIPPED=$((SKIPPED+1)); fi
  return 0
}

# ------------------------------------------------------------------- sandbox
# Repo copiado (SCRIPT_DIR propio), HOME falso y docker simulado que registra
# "compose/exec" en $F/calls.log.
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake" "$SB/repo"
  : > "$SB/fake/calls.log"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
case "${1:-}" in
  compose) [[ "$2" == version ]] && exit 0
           echo "compose $*" >> "$F/calls.log"; exit 0 ;;
  exec)    echo "exec $*" >> "$F/calls.log"; exit 0 ;;
  *)       exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/env.example" "$SB/repo/"
  unset XDG_DATA_HOME AIWS_LOCK_HELD AIWS_FLOCK
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
  LOCK="$SB/repo/logs/.lock"
}

# Toma el bloqueo desde fuera (como otro setup.sh) hasta que se mate a $HOLDER
hold_lock() {
  mkdir -p "$SB/repo/logs"
  ( exec 8>>"$LOCK"; flock -x 8; exec sleep 60 ) &
  HOLDER=$!
  local _; for _ in $(seq 1 50); do
    if ! flock -n "$LOCK" true 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  nok "no pude tomar el bloqueo de prueba"
}
release_lock() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; }

lock_free() { [[ ! -e "$LOCK" ]] || flock -n "$LOCK" true 2>/dev/null; }

# ---------------------------------------------------------------------- tests
t_mutating_command_fails_while_lock_is_held() {
  mk_sandbox; hold_lock
  local out rc
  out="$(bash "$SB/repo/setup.sh" down 2>&1)"; rc=$?
  release_lock
  assert_eq "con el bloqueo tomado falla" "1" "$rc"
  assert_has "nombra la instancia" "$out" "ai-workspace"
  assert_has "explica el motivo" "$out" "operación en curso"
  assert_lacks "no cambió nada" "$(cat "$SB/fake/calls.log")" "compose down"
}

t_message_suggests_progress_when_a_background_process_runs() {
  mk_sandbox; hold_lock
  echo "$HOLDER" > "$SB/repo/logs/.pid"     # proceso vivo: como un install en segundo plano
  local out
  out="$(bash "$SB/repo/setup.sh" backup 2>&1)"
  release_lock
  assert_has "sugiere ver el progreso" "$out" "./setup.sh progress"
}

t_read_only_command_works_while_lock_is_held() {
  mk_sandbox; hold_lock
  local rc
  bash "$SB/repo/setup.sh" status >/dev/null 2>&1; rc=$?
  release_lock
  assert_eq "status funciona con el bloqueo tomado" "0" "$rc"
  assert_has "status consultó compose" "$(cat "$SB/fake/calls.log")" "compose ps"
}

t_lock_is_released_when_the_command_ends() {
  mk_sandbox
  bash "$SB/repo/setup.sh" down >/dev/null 2>&1
  if lock_free; then ok; else nok "el bloqueo sigue tomado tras terminar down"; fi
}

# Simula el segundo plano: el proceso que bloquea lanza un hijo que hereda el bloqueo
# (como run_bg o "exec setup.sh update") y termina; el hijo no se bloquea contra sí mismo.
t_background_child_keeps_the_lock_until_it_ends() {
  mk_sandbox
  local out
  out="$(
    # shellcheck disable=SC1091
    source "$SB/repo/setup.sh"; set +eEu; trap - ERR
    op_lock
    bash "$SB/repo/setup.sh" down >/dev/null 2>&1 && echo "hijo-ok"
    ( exec sleep 2 ) >/dev/null 2>&1 &
    echo "pid=$!"
  )"
  assert_has "el hijo heredero no se bloquea contra sí mismo" "$out" "hijo-ok"
  local pid="${out##*pid=}"
  if lock_free; then nok "el bloqueo se soltó aunque el hijo sigue vivo"; else ok; fi
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  if lock_free; then ok; else nok "el bloqueo no se soltó cuando terminó el hijo"; fi
}

t_without_flock_warns_once_and_proceeds() {
  mk_sandbox
  local out rc
  out="$(AIWS_FLOCK=flock-no-existe bash "$SB/repo/setup.sh" down 2>&1)"; rc=$?
  assert_eq "sin flock no falla" "0" "$rc"
  assert_eq "avisa una sola vez" "1" "$(grep -c 'flock' <<<"$out")"
  assert_has "siguió con el comando" "$(cat "$SB/fake/calls.log")" "compose down"
}

t_down_still_behaves_as_before() {
  mk_sandbox
  local out rc
  out="$(bash "$SB/repo/setup.sh" down 2>&1)"; rc=$?
  assert_eq "down termina bien" "0" "$rc"
  assert_has "down detiene los contenedores" "$(cat "$SB/fake/calls.log")" "compose down"
  assert_has "down conserva su mensaje" "$out" "Contenedores detenidos"
}

run_flock t_mutating_command_fails_while_lock_is_held
run_flock t_message_suggests_progress_when_a_background_process_runs
run_flock t_read_only_command_works_while_lock_is_held
run_flock t_lock_is_released_when_the_command_ends
run_flock t_background_child_keeps_the_lock_until_it_ends
run t_without_flock_warns_once_and_proceeds
run_flock t_down_still_behaves_as_before

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos, $SKIPPED omitidas"
(( f == 0 ))
