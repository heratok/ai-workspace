#!/usr/bin/env bash
# =============================================================================
# Pruebas de la migración 001 (limpiar versiones previas): no debe borrar datos ni contenedores en uso.
#
#   bash tests/migrations.test.sh
#
# Sin Docker real: un "docker" falso guarda el estado en archivos (volúmenes, contenedores detenidos y en ejecución)
# y registra cada llamada. Hallado al probar el upgrade en una copia con alias propio: la migración eliminaba el
# volumen ai-workspace_ai_ssh_host_keys (que en una VPS real existe) y forzaba la baja de contenedores corriendo.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG="$ROOT/migrations/001-limpiar-versiones-previas.sh"
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
# Estado del docker falso en $SB/fake: volumes, running, stopped (un nombre por línea) y calls.log
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake" "$SB/repo"
  : > "$SB/fake/volumes"; : > "$SB/fake/running"; : > "$SB/fake/stopped"; : > "$SB/fake/calls.log"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
echo "$*" >> "$F/calls.log"
has() { grep -qxF "$2" "$F/$1"; }
case "${1:-}" in
  volume)
    case "${2:-}" in
      ls)      pat=""; for a in "$@"; do [[ "$a" == name=* ]] && pat="${a#name=}"; done          # --filter name=X: coincidencia por subcadena, como el docker real
               if [[ -n "$pat" ]]; then grep -F -- "$pat" "$F/volumes" || true; else cat "$F/volumes"; fi ;;
      inspect) has volumes "$3" ;;
      rm)      has volumes "$3" || exit 1; has running_volumes "$3" 2>/dev/null && exit 1; grep -vxF "$3" "$F/volumes" > "$F/v.tmp"; mv "$F/v.tmp" "$F/volumes" ;;
      *) exit 0 ;;
    esac ;;
  container) [[ "${2:-}" == inspect ]] && { has running "$3" || has stopped "$3"; } ;;
  rm)
    shift; force=false; names=()
    for a in "$@"; do if [[ "$a" == -f ]]; then force=true; else names+=("$a"); fi; done
    rc=0
    for n in "${names[@]}"; do
      if has running "$n"; then
        if [[ "$force" == true ]]; then grep -vxF "$n" "$F/running" > "$F/r.tmp"; mv "$F/r.tmp" "$F/running"; else rc=1; fi
      elif has stopped "$n"; then grep -vxF "$n" "$F/stopped" > "$F/s.tmp"; mv "$F/s.tmp" "$F/stopped"
      else rc=1; fi
    done
    exit $rc ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/env.example" "$SB/repo/"
  cp "$SB/repo/env.example" "$SB/repo/.env"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
}
add_volumes() { local v; for v in "$@"; do echo "$v" >> "$SB/fake/volumes"; done; }
run_001() {   # como run_migrations: subproceso con las funciones de setup.sh cargadas
  ( cd "$SB/repo" && bash -c 'set -Eeuo pipefail; source "$1"; source "$2"' _ "$SB/repo/setup.sh" "$MIG" ) 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'
}
calls() { cat "$SB/fake/calls.log"; }
volumes() { tr '\n' ' ' < "$SB/fake/volumes" | sed 's/ $//'; }

# ------------------------------------------------------------------- volúmenes
t_001_never_removes_the_obsolete_ssh_keys_volume() {
  mk_sandbox; add_volumes ai-workspace_ai_ssh_host_keys ai_ssh_host_keys ai_home
  local out; out="$(run_001)"
  assert_eq "ningún 'volume rm'" "" "$(calls | grep -E '^volume rm' || true)"
  assert_eq "los volúmenes siguen ahí" "ai-workspace_ai_ssh_host_keys ai_ssh_host_keys ai_home" "$(volumes)"
  assert_has "avisa del volumen" "$out" "ai-workspace_ai_ssh_host_keys"
  assert_has "da el comando para borrarlo a mano" "$out" "docker volume rm ai-workspace_ai_ssh_host_keys"
}

t_001_does_not_flag_the_current_ssh_keys_volume_as_obsolete() {
  mk_sandbox; add_volumes ai_ssh_host_keys
  local out; out="$(run_001)"
  assert_lacks "el volumen vigente no es obsoleto" "$out" "volume rm ai_ssh_host_keys"
}

t_001_still_warns_about_old_database_volumes_and_never_removes_them() {
  mk_sandbox; add_volumes ai_pg_data ai_redis_data
  local out; out="$(run_001)"
  assert_has "avisa de postgres" "$out" "ai_pg_data"
  assert_has "avisa de redis" "$out" "ai_redis_data"
  assert_eq "no se borran" "ai_pg_data ai_redis_data" "$(volumes)"
  assert_eq "ningún 'volume rm'" "" "$(calls | grep -E '^volume rm' || true)"
}

# ------------------------------------------------------------------- contenedores viejos de BD
t_001_never_force_removes_a_running_container() {
  mk_sandbox; echo ai-workspace-postgres >> "$SB/fake/running"
  local out; out="$(run_001)"
  assert_eq "sigue corriendo" "ai-workspace-postgres" "$(cat "$SB/fake/running")"
  assert_eq "ningún 'rm -f'" "" "$(calls | grep -E '^rm .*-f' || true)"
  assert_has "avisa que lo deja intacto" "$out" "ai-workspace-postgres"
}

t_001_removes_old_database_containers_only_when_stopped() {
  mk_sandbox; echo ai-workspace-postgres >> "$SB/fake/stopped"; echo ai-workspace-redis >> "$SB/fake/running"
  run_001 >/dev/null
  assert_eq "el detenido se elimina" "" "$(cat "$SB/fake/stopped")"
  assert_eq "el que corre se conserva" "ai-workspace-redis" "$(cat "$SB/fake/running")"
}

t_001_is_quiet_when_there_is_nothing_to_clean() {
  mk_sandbox
  local out; out="$(run_001)"; assert_eq "código de salida" "0" "$?"
  assert_lacks "sin avisos" "$out" "aviso"
  assert_eq "ninguna llamada destructiva" "" "$(calls | grep -E '^(rm|volume rm)' || true)"
}

# ------------------------------------------------------------------- lo que sí debe seguir haciendo
t_001_still_removes_obsolete_env_variables() {
  mk_sandbox
  printf 'BIND_IP=0.0.0.0\nPOSTGRES_USER=x\nTS_HOSTNAME=mi-equipo\n' >> "$SB/repo/.env"
  run_001 >/dev/null
  assert_eq "BIND_IP fuera" "0" "$(grep -c '^BIND_IP=' "$SB/repo/.env")"
  assert_eq "POSTGRES_USER fuera" "0" "$(grep -c '^POSTGRES_USER=' "$SB/repo/.env")"
  assert_eq "las demás variables se conservan" "1" "$(grep -c '^TS_HOSTNAME=mi-equipo' "$SB/repo/.env")"
}

t_001_is_idempotent() {
  mk_sandbox; add_volumes ai-workspace_ai_ssh_host_keys; echo ai-workspace-postgres >> "$SB/fake/stopped"
  run_001 >/dev/null; local once; once="$(volumes)|$(cat "$SB/fake/stopped")"
  run_001 >/dev/null
  assert_eq "segunda ejecución sin cambios" "$once" "$(volumes)|$(cat "$SB/fake/stopped")"
}

for t in t_001_never_removes_the_obsolete_ssh_keys_volume t_001_does_not_flag_the_current_ssh_keys_volume_as_obsolete \
         t_001_still_warns_about_old_database_volumes_and_never_removes_them t_001_never_force_removes_a_running_container \
         t_001_removes_old_database_containers_only_when_stopped t_001_is_quiet_when_there_is_nothing_to_clean \
         t_001_still_removes_obsolete_env_variables t_001_is_idempotent; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
