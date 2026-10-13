#!/usr/bin/env bash
# =============================================================================
# Pruebas de "setup.sh restore" (y del checksum que escribe "setup.sh backup").
#
#   bash tests/restore.test.sh
#
# Usa tar real sobre archivos temporales y un "docker" simulado que registra sus
# llamadas; no toca volúmenes ni contenedores del equipo donde se ejecuta.
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
assert_ok()   { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then ok; else nok "$n: debía tener éxito: $*"; fi; return 0; }
assert_fail() { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then nok "$n: debía fallar: $*"; else ok; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# ------------------------------------------------------------------- sandbox
# Repo copiado (SCRIPT_DIR propio), HOME falso y docker simulado que:
#  - dice que todos los volúmenes/imágenes existen y si el contenedor corre ($F/running)
#  - "docker run ... czf /b/X" crea X en backups/ a partir de $F/tree (respaldo simulado)
#  - registra "docker run/compose/exec" en $F/calls.log
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake/tree/ai_home" "$SB/fake/tree/ai_workspace" "$SB/repo/backups"
  echo "hola" > "$SB/fake/tree/ai_home/a.txt"; echo "proyecto" > "$SB/fake/tree/ai_workspace/b.txt"
  echo false > "$SB/fake/running"; : > "$SB/fake/calls.log"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
case "${1:-}" in
  volume|image) exit 0 ;;
  inspect)      cat "$F/running"; exit 0 ;;
  run)          echo "run $*" >> "$F/calls.log"
                args=("$@")
                for ((i=0; i<${#args[@]}; i++)); do
                  if [[ "${args[i]}" == czf ]]; then
                    tar czf "$FAKE_BACKUP_DIR/$(basename "${args[i+1]}")" -C "$F/tree" .
                  fi
                done
                exit 0 ;;
  compose)      [[ "$2" == version ]] && exit 0
                echo "compose $*" >> "$F/calls.log"; exit 0 ;;
  exec)         echo "exec $*" >> "$F/calls.log"; exit 0 ;;
  *)            exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  cp "$ROOT/setup.sh" "$ROOT/env.example" "$SB/repo/"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" FAKE_BACKUP_DIR="$SB/repo/backups" PATH="$SB/bin:$PATH"
}

load_setup() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"
  set +eEu; trap - ERR
  confirm() { return 0; }          # por defecto "sí" a todo
  BK="$SB/repo/backups"
}

# mk_archive <ruta> [dir-extra-en-la-raíz]: tar.gz con la misma forma que escribe "backup" (-C /v .)
mk_archive() {
  local out="$1" extra="${2:-}" t; t="$(mktemp -d "$TMP/tree.XXXXXX")"
  mkdir -p "$t/ai_home" "$t/ai_workspace"; echo hola > "$t/ai_home/a.txt"; echo proyecto > "$t/ai_workspace/b.txt"
  if [[ -n "$extra" ]]; then mkdir -p "$t/$extra"; echo x > "$t/$extra/x.txt"; fi
  tar czf - -C "$t" . > "$out"      # por stdout: una ruta con ":" no se toma por un host remoto
}
calls() { cat "$SB/fake/calls.log"; }

# ================================================================ selección
t_latest_backup_picks_newest_by_timestamp() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  mk_archive "$BK/ai-workspace-20260301-090000.tar.gz"
  mk_archive "$BK/ai-workspace-20260201-120000.tar.gz"
  touch -d '2020-01-01' "$BK/ai-workspace-20260301-090000.tar.gz"      # el mtime NO manda: el nombre sí
  assert_eq "más reciente" "$BK/ai-workspace-20260301-090000.tar.gz" "$(latest_backup)"
}

t_latest_backup_ignores_other_instances_and_checksums() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  mk_archive "$BK/ai-workspace-2-20260901-100000.tar.gz"               # alias "2": NO es de la instancia principal
  : > "$BK/ai-workspace-20260901-100000.tar.gz.sha256"
  assert_eq "solo la principal" "$BK/ai-workspace-20260101-100000.tar.gz" "$(latest_backup)"
}

t_resolve_accepts_path_basename_and_default() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  assert_eq "ruta" "$BK/ai-workspace-20260101-100000.tar.gz" "$(resolve_backup "$BK/ai-workspace-20260101-100000.tar.gz")"
  assert_eq "nombre" "$BK/ai-workspace-20260101-100000.tar.gz" "$(resolve_backup ai-workspace-20260101-100000.tar.gz)"
  assert_eq "por defecto" "$BK/ai-workspace-20260101-100000.tar.gz" "$(resolve_backup "")"
}

t_resolve_rejects_missing_and_foreign_backups() {
  load_setup
  assert_fail "sin respaldos" resolve_backup ""
  assert_fail "no existe" resolve_backup ai-workspace-20260101-100000.tar.gz
  mk_archive "$BK/ai-workspace-foo-20260101-100000.tar.gz"
  assert_fail "de otra instancia" resolve_backup "$BK/ai-workspace-foo-20260101-100000.tar.gz"
}

# ================================================================ validación
t_validate_accepts_good_archive() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  assert_ok "bueno" validate_backup "$BK/ai-workspace-20260101-100000.tar.gz"
}

t_validate_rejects_corrupt_archive() {
  load_setup
  echo "no soy un tar" > "$BK/ai-workspace-20260101-100000.tar.gz"
  assert_fail "corrupto" validate_backup "$BK/ai-workspace-20260101-100000.tar.gz"
}

t_validate_rejects_unknown_top_level_dirs() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz" evil
  assert_fail "directorio ajeno" validate_backup "$BK/ai-workspace-20260101-100000.tar.gz"
}

t_validate_rejects_archive_without_instance_volumes() {
  load_setup
  local t; t="$(mktemp -d "$TMP/tree.XXXXXX")"; mkdir -p "$t/otra"; echo x > "$t/otra/x"
  tar czf "$BK/ai-workspace-20260101-100000.tar.gz" -C "$t" .
  assert_fail "sin volúmenes" validate_backup "$BK/ai-workspace-20260101-100000.tar.gz"
}

t_validate_accepts_paths_containing_a_colon() {
  load_setup
  mkdir -p "$SB/repo/host:dir"
  mk_archive "$SB/repo/host:dir/ai-workspace-20260101-100000.tar.gz"
  cd "$SB/repo" && assert_ok "ruta con dos puntos" validate_backup "host:dir/ai-workspace-20260101-100000.tar.gz"
  assert_eq "volúmenes" "ai_home
ai_workspace" "$(backup_volumes "host:dir/ai-workspace-20260101-100000.tar.gz")"
}

t_validate_checks_sha256_when_present() {
  load_setup
  local f="$BK/ai-workspace-20260101-100000.tar.gz"
  mk_archive "$f"
  ( cd "$BK" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256" )
  assert_ok "checksum bueno" validate_backup "$f"
  mk_archive "$f" extra_ok                                              # otro contenido, mismo nombre
  assert_fail "checksum no coincide" validate_backup "$f"
}

# ================================================================ backup
t_backup_writes_a_verifiable_checksum() {
  load_setup
  ( backup ) >/dev/null 2>&1
  local f; f="$(latest_backup)"
  [[ -n "$f" && -f "$f.sha256" ]] && ok || nok "backup no escribió el .sha256"
  assert_ok "el checksum verifica" validate_backup "$f"
}

# ================================================================ restore
t_restore_replaces_volumes_from_the_archive() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  local run; run="$(calls | grep -E '^run .*xzf' || true)"
  assert_has "monta home rw" "$run" "-v ai_home:/v/ai_home"
  assert_has "monta workspace rw" "$run" "-v ai_workspace:/v/ai_workspace"
  assert_has "respaldos de solo lectura" "$run" "/b:ro"
  assert_has "extrae el archivo" "$run" "ai-workspace-20260101-100000.tar.gz"
  assert_lacks "no toca volúmenes de Tailscale" "$run" "ts_state"
}

t_restore_takes_a_safety_backup_first() {
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  local first; first="$(calls | grep -E '^run ' | head -n1)"
  assert_has "primero respalda" "$first" "czf"
}

t_restore_aborts_when_not_confirmed() {
  load_setup
  confirm() { return 1; }
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore ) >/dev/null 2>&1
  assert_eq "no ejecuta nada" "" "$(calls | grep -E 'xzf|czf' || true)"
}

t_restore_with_yes_does_not_prompt() {
  load_setup
  confirm() { echo PREGUNTO >> "$SB/prompted"; return 1; }
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  [[ ! -e "$SB/prompted" ]] && ok || nok "--yes no debe preguntar"
}

t_restore_stops_and_restarts_a_running_workspace() {
  load_setup
  echo true > "$SB/fake/running"
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  local c; c="$(calls)"
  assert_has "detiene el workspace" "$c" "compose "
  [[ "$c" == *stop*xzf*start* || "$c" == *stop*start* ]] && ok || nok "debía detener antes y arrancar después: $c"
}

t_restore_leaves_a_stopped_workspace_stopped() {
  load_setup
  echo false > "$SB/fake/running"
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  assert_eq "no arranca ni detiene" "" "$(calls | grep -E 'compose .*(stop|start)' || true)"
}

t_restore_refuses_invalid_archive_before_touching_anything() {
  load_setup
  echo "no soy un tar" > "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ) >/dev/null 2>&1
  local rc=$?
  assert_eq "no ejecuta nada" "" "$(calls | grep -E 'run |compose ' || true)"
  (( rc != 0 )) && ok || nok "debía fallar con código != 0"
}

t_restore_rejects_unknown_option() {
  load_setup
  assert_fail "opción desconocida" restore --nope
}

for t in t_latest_backup_picks_newest_by_timestamp t_latest_backup_ignores_other_instances_and_checksums \
         t_resolve_accepts_path_basename_and_default t_resolve_rejects_missing_and_foreign_backups \
         t_validate_accepts_good_archive t_validate_rejects_corrupt_archive t_validate_rejects_unknown_top_level_dirs \
         t_validate_rejects_archive_without_instance_volumes t_validate_accepts_paths_containing_a_colon t_validate_checks_sha256_when_present \
         t_backup_writes_a_verifiable_checksum \
         t_restore_replaces_volumes_from_the_archive t_restore_takes_a_safety_backup_first \
         t_restore_aborts_when_not_confirmed t_restore_with_yes_does_not_prompt \
         t_restore_stops_and_restarts_a_running_workspace t_restore_leaves_a_stopped_workspace_stopped \
         t_restore_refuses_invalid_archive_before_touching_anything t_restore_rejects_unknown_option; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
