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
#  - "docker run ... czf -" escribe por stdout un tar.gz de $F/tree (respaldo simulado);
#    con $F/fail_backup escribe bytes a medias y sale con error
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
                args=("$@"); host="" name=""
                for ((i=0; i<${#args[@]}; i++)); do
                  if [[ "${args[i]}" == czf && "${args[i+1]}" == - ]]; then
                    if [[ -e "$F/fail_backup" ]]; then printf 'a medias'; echo "tar: error simulado" >&2; exit 2; fi
                    tar czf - -C "$F/tree" .
                  fi
                  [[ "${args[i]}" == -v && "${args[i+1]}" == *:/b:ro ]] && host="${args[i+1]%:/b:ro}"
                  [[ "${args[i]}" == _ ]] && name="${args[i+1]}"
                done
                if [[ -n "$name" ]]; then          # extracción de restore: como Docker real
                  # -v sin ruta absoluta es un volumen con nombre (vacío): el archivo no está ahí
                  [[ "$host" == /* && -f "$host/$name" ]] || { echo "tar: /b/$name: No such file" >&2; exit 2; }
                  if [[ -s "$F/fail_extract" ]]; then rm -f "$F/fail_extract"; echo "tar: error simulado" >&2; exit 2; fi
                fi
                exit 0 ;;
  compose)      [[ "$2" == version ]] && exit 0
                echo "compose $*" >> "$F/calls.log"; exit 0 ;;
  exec)         echo "exec $*" >> "$F/calls.log"; exit 0 ;;
  *)            exit 0 ;;
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

t_backup_streams_from_the_container_and_the_host_writes_the_file() {   # S6: el contenedor (root) no escribe en backups/
  load_setup
  ( backup ) >/dev/null 2>&1
  local run f; run="$(calls | grep -E '^run .*czf' || true)"; f="$(latest_backup)"
  assert_has "tar por stdout" "$run" "czf - "
  assert_lacks "sin montar backups/ en el contenedor" "$run" ":/b"
  [[ -n "$f" ]] && ok || nok "no quedó respaldo"
  assert_eq "dueño del respaldo" "$(id -un)" "$(stat -c %U "$f" 2>/dev/null)"
  assert_eq "permisos del respaldo" 600 "$(stat -c %a "$f" 2>/dev/null)"
  assert_eq "permisos del checksum" 600 "$(stat -c %a "$f.sha256" 2>/dev/null)"
}

t_backup_is_atomic_on_success() {   # S5: se escribe <archivo>.partial y se renombra al final
  load_setup
  backup >/dev/null 2>&1
  assert_eq "LAST_BACKUP es el respaldo final" "$(latest_backup)" "$LAST_BACKUP"
  assert_eq "no queda .partial" "" "$(cd "$BK" && ls -- *.partial 2>/dev/null)"
  assert_ok "el archivo es un tar.gz válido" validate_backup "$LAST_BACKUP"
}

t_backup_failure_leaves_no_valid_archive_and_restarts_devdb() {   # S5
  load_setup
  : > "$SB/fake/fail_backup"
  ( backup ) >/dev/null 2>&1
  local rc=$?
  (( rc != 0 )) && ok || nok "backup debía fallar"
  assert_eq "ningún archivo con nombre válido" "" "$(latest_backup)"
  assert_eq "sin checksum" "" "$(cd "$BK" && ls -- *.sha256 2>/dev/null)"
  assert_eq "sin .partial" "" "$(cd "$BK" && ls -- *.partial 2>/dev/null)"
  assert_has "reanuda las BD locales" "$(calls | grep '^exec' | tail -n1)" "devdb autostart"
}

t_backup_still_rotates_to_backup_keep() {   # comportamiento previo: "backup" rota a BACKUP_KEEP
  load_setup
  # shellcheck disable=SC2034  # lo lee backup
  BACKUP_KEEP=2
  local d f
  for d in 01 02 03; do f="$BK/ai-workspace-202601$d-100000.tar.gz"; mk_archive "$f"; touch -d "2026-01-$d" "$f"; done
  ( backup ) >/dev/null 2>&1
  assert_eq "quedan 2 respaldos" 2 "$(cd "$BK" && ls -- ai-workspace-*.tar.gz | wc -l)"
  [[ -f "$BK/ai-workspace-20260103-100000.tar.gz" ]] && ok || nok "debía conservar el más nuevo de los viejos"
}

t_backup_rotation_never_touches_another_instance() {   # "ai-workspace-[0-9]*" también coincide con el alias "2"
  load_setup
  # shellcheck disable=SC2034  # lo lee backup
  BACKUP_KEEP=1
  local d f
  for d in 01 02; do f="$BK/ai-workspace-2-202601$d-100000.tar.gz"; mk_archive "$f"; touch -d "2020-01-$d" "$f"; done
  ( backup ) >/dev/null 2>&1
  assert_eq "los respaldos del alias 2 siguen" 2 "$(cd "$BK" && ls -- ai-workspace-2-*.tar.gz | wc -l)"
}

t_backup_rotates_checksums_with_their_archives() {   # S4: sin checksums huérfanos
  load_setup
  # shellcheck disable=SC2034  # lo lee backup
  BACKUP_KEEP=2
  local d f
  for d in 01 02 03; do f="$BK/ai-workspace-202601$d-100000.tar.gz"; mk_archive "$f"; touch -d "2026-01-$d" "$f"; done
  ( cd "$BK" && sha256sum ai-workspace-20260101-100000.tar.gz > ai-workspace-20260101-100000.tar.gz.sha256 )
  ( backup ) >/dev/null 2>&1
  for f in "$BK"/*.sha256; do
    [[ -e "$f" ]] || continue
    [[ -f "${f%.sha256}" ]] && ok || nok "checksum huérfano: $(basename "$f")"
  done
  [[ ! -e "$BK/ai-workspace-20260101-100000.tar.gz.sha256" ]] && ok || nok "el .sha256 del respaldo rotado debía borrarse"
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

t_restore_does_not_rotate_away_the_archive_it_restores() {   # el respaldo de seguridad no debe borrar el elegido
  load_setup
  # shellcheck disable=SC2034  # lo lee backup -> keep_newest
  BACKUP_KEEP=1
  local f="$BK/ai-workspace-20260101-100000.tar.gz"
  mk_archive "$f"; touch -d '2020-01-01' "$f"                  # el más viejo: el primero que rotaría
  ( restore --yes "$f" ) >/dev/null 2>&1
  local rc=$?
  assert_eq "termina bien" 0 "$rc"
  [[ -f "$f" ]] && ok || nok "restore borró el respaldo que estaba restaurando"
  assert_eq "una sola extracción" 1 "$(calls | grep -c 'xzf' || true)"
}

t_restore_accepts_a_relative_path() {   # "-v backups:/b" sería un volumen con nombre, no la carpeta
  load_setup
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( cd "$SB/repo" && restore --yes backups/ai-workspace-20260101-100000.tar.gz ) >/dev/null 2>&1
  local rc=$?
  assert_eq "termina bien" 0 "$rc"
  local run; run="$(calls | grep -E '^run .*xzf' || true)"
  [[ "$run" =~ -v\ /[^\ ]*/backups:/b:ro ]] && ok || nok "debía montar la carpeta con ruta absoluta: $run"
}

t_restore_puts_the_safety_backup_back_when_extraction_fails() {
  load_setup
  echo true > "$SB/fake/running"; echo 1 > "$SB/fake/fail_extract"
  mk_archive "$BK/ai-workspace-20260101-100000.tar.gz"
  ( restore --yes ai-workspace-20260101-100000.tar.gz ) >/dev/null 2>&1
  local rc=$? safety; safety="$(basename "$(latest_backup)")"
  (( rc != 0 )) && ok || nok "debía terminar con error"
  assert_eq "dos extracciones (fallida + vuelta atrás)" 2 "$(calls | grep -c 'xzf' || true)"
  [[ "$safety" != ai-workspace-20260101-100000.tar.gz ]] && ok || nok "no hubo respaldo de seguridad"
  assert_has "la segunda usa el respaldo de seguridad" "$(calls | grep 'xzf' | tail -n1)" "$safety"
  assert_has "vuelve a arrancar el workspace" "$(calls | tail -n1)" "start"
}

# ------------------------------------------------- rotación de logs/respaldos (keep_newest) en modo estricto
# Hallado probando el upgrade real: "ls" sale con error si no hay archivos que coincidan y, con pipefail + trap ERR,
# eso abortaba "clean" (p. ej. "upgrade --foreground" con la carpeta logs/ vacía). Ya fallaba en el monolito viejo.
strict() { ( set -Eeo pipefail; trap 'echo "TRAP-ERR línea $LINENO"; exit 99' ERR; "$@"; echo termino ) 2>&1; }

t_keep_newest_survives_a_directory_without_matching_files() {
  load_setup
  mkdir -p "$SB/vacio"
  local out; out="$(strict keep_newest "$SB/vacio" '*-[0-9]*.log' 5)"
  assert_has "no aborta" "$out" "termino"
  [[ "$out" != *TRAP-ERR* ]] && ok || nok "el trap ERR saltó con una carpeta sin coincidencias: $out"
  out="$(strict keep_newest "$SB/no-existe" '*.log' 5)"
  assert_has "carpeta inexistente tampoco" "$out" "termino"
}

t_keep_newest_still_deletes_the_oldest_files() {
  load_setup
  mkdir -p "$SB/logs"; local i
  for i in 1 2 3 4 5 6 7; do touch -d "2026-01-0$i" "$SB/logs/x-$i.log"; done
  local out; out="$(strict keep_newest "$SB/logs" 'x-*.log' 5)"
  assert_has "termina" "$out" "termino"
  assert_eq "quedan las 5 más nuevas" "x-3.log x-4.log x-5.log x-6.log x-7.log" "$(cd "$SB/logs" && ls | sort | tr '\n' ' ' | sed 's/ $//')"
}

for t in t_latest_backup_picks_newest_by_timestamp t_latest_backup_ignores_other_instances_and_checksums \
         t_resolve_accepts_path_basename_and_default t_resolve_rejects_missing_and_foreign_backups \
         t_validate_accepts_good_archive t_validate_rejects_corrupt_archive t_validate_rejects_unknown_top_level_dirs \
         t_validate_rejects_archive_without_instance_volumes t_validate_accepts_paths_containing_a_colon t_validate_checks_sha256_when_present \
         t_backup_writes_a_verifiable_checksum t_backup_streams_from_the_container_and_the_host_writes_the_file \
         t_backup_is_atomic_on_success t_backup_failure_leaves_no_valid_archive_and_restarts_devdb \
         t_backup_still_rotates_to_backup_keep t_backup_rotation_never_touches_another_instance t_backup_rotates_checksums_with_their_archives \
         t_restore_replaces_volumes_from_the_archive t_restore_takes_a_safety_backup_first \
         t_restore_aborts_when_not_confirmed t_restore_with_yes_does_not_prompt \
         t_restore_stops_and_restarts_a_running_workspace t_restore_leaves_a_stopped_workspace_stopped \
         t_restore_refuses_invalid_archive_before_touching_anything t_restore_rejects_unknown_option \
         t_restore_does_not_rotate_away_the_archive_it_restores t_restore_accepts_a_relative_path \
         t_restore_puts_the_safety_backup_back_when_extraction_fails t_keep_newest_survives_a_directory_without_matching_files t_keep_newest_still_deletes_the_oldest_files; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
