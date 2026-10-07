#!/usr/bin/env bash
# =============================================================================
# Pruebas de la guía para agentes (config/AGENTS.md) y de su siembra en /workspace.
#
#   bash tests/guide.test.sh
#
# Sin Docker ni root: config/seed-guide.sh se ejecuta contra rutas temporales.
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
assert_file() { if [[ -f "$2" ]]; then ok; else nok "$1: no existe el archivo $2"; fi; return 0; }

SKIPPED=0
# Los symlinks pueden no estar disponibles (p. ej. Git Bash en Windows sin privilegios):
# esas pruebas se omiten y CI (Linux) las ejecuta.
HAVE_SYMLINK=0; if ln -s "$0" "$TMP/.probe" 2>/dev/null && [[ -L "$TMP/.probe" ]]; then HAVE_SYMLINK=1; fi; rm -rf "$TMP/.probe"
run_sym() {
  if (( HAVE_SYMLINK )); then run "$1"
  else echo "== $1 (OMITIDA: sin soporte de symlinks en este entorno)"; SKIPPED=$((SKIPPED+1)); fi
  return 0
}

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# ------------------------------------------------------------------- sandbox
GUIDE_SRC="$ROOT/config/AGENTS.md"
SEED="$ROOT/config/seed-guide.sh"

mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/ws" "$SB/etc"
  cp "$GUIDE_SRC" "$SB/etc/AGENTS.md" 2>/dev/null || echo "# guía de prueba" > "$SB/etc/AGENTS.md"
  export AIWS_GUIDE_SRC="$SB/etc/AGENTS.md" AIWS_WORKSPACE_DIR="$SB/ws" AIWS_OWNER="$(id -u):$(id -g)"
}
seed() { bash "$SEED" >/dev/null 2>&1; }

# ================================================================== siembra
t_seed_creates_both() {
  mk_sandbox
  seed; assert_eq "rc de la siembra" "0" "$?"
  assert_file "AGENTS.md sembrado" "$SB/ws/AGENTS.md"
  assert_file "CLAUDE.md sembrado" "$SB/ws/CLAUDE.md"
}

t_seed_symlink_target() {
  mk_sandbox; seed
  [[ -L "$SB/ws/AGENTS.md" ]] && ok || nok "AGENTS.md debe ser un symlink"
  assert_eq "destino del symlink" "$AIWS_GUIDE_SRC" "$(readlink "$SB/ws/AGENTS.md")"
}

t_seed_claude_import() {
  mk_sandbox; seed
  assert_eq "CLAUDE.md importa la guía" "@$AIWS_GUIDE_SRC" "$(head -n1 "$SB/ws/CLAUDE.md")"
  [[ ! -L "$SB/ws/CLAUDE.md" ]] && ok || nok "CLAUDE.md debe ser un archivo, no un symlink"
}

t_seed_idempotent() {
  mk_sandbox; seed
  local before after
  before="$(ls -lAn --time-style=+%s "$SB/ws"; cat "$SB/ws/CLAUDE.md")"
  sleep 1; seed; assert_eq "rc del segundo arranque" "0" "$?"
  after="$(ls -lAn --time-style=+%s "$SB/ws"; cat "$SB/ws/CLAUDE.md")"
  assert_eq "segundo arranque no cambia nada" "$before" "$after"
}

t_seed_no_overwrite_files() {
  mk_sandbox
  echo "mío agents" > "$SB/ws/AGENTS.md"; echo "mío claude" > "$SB/ws/CLAUDE.md"
  seed
  assert_eq "AGENTS.md preexistente intacto" "mío agents" "$(cat "$SB/ws/AGENTS.md")"
  assert_eq "CLAUDE.md preexistente intacto" "mío claude" "$(cat "$SB/ws/CLAUDE.md")"
  [[ ! -L "$SB/ws/AGENTS.md" ]] && ok || nok "no debía convertir el archivo en symlink"
}

t_seed_no_overwrite_broken_symlink() {
  mk_sandbox
  ln -s "$SB/no-existe" "$SB/ws/AGENTS.md"; ln -s "$SB/no-existe" "$SB/ws/CLAUDE.md"
  seed
  assert_eq "symlink roto AGENTS.md intacto" "$SB/no-existe" "$(readlink "$SB/ws/AGENTS.md")"
  assert_eq "symlink roto CLAUDE.md intacto" "$SB/no-existe" "$(readlink "$SB/ws/CLAUDE.md")"
}

t_seed_partial() {
  mk_sandbox
  echo "mío claude" > "$SB/ws/CLAUDE.md"
  seed
  [[ -L "$SB/ws/AGENTS.md" ]] && ok || nok "debía sembrar AGENTS.md aunque CLAUDE.md exista"
  assert_eq "CLAUDE.md intacto" "mío claude" "$(cat "$SB/ws/CLAUDE.md")"
}

t_seed_missing_guide_is_noop() {
  mk_sandbox
  export AIWS_GUIDE_SRC="$SB/no-hay-guia.md"
  seed; assert_eq "rc 0 sin guía" "0" "$?"
  [[ ! -e "$SB/ws/AGENTS.md" && ! -e "$SB/ws/CLAUDE.md" ]] && ok || nok "sin guía no debía sembrar nada"
}

# ================================================================== contenido de la guía
# Binarios que la guía puede citar en sus tablas de comandos.
GUIDE_ALLOWED=(npm npx uv mise devdb doppler gh ws-doctor playwright playwright-cli psql redis-cli curl git node python3 pip)
# Los que el job "build" de CI verifica con command -v dentro de la imagen.
CI_CHECKED=(npm uv mise devdb ws-doctor gh doppler psql git node playwright playwright-cli)

t_guide_exists_and_short() {
  assert_file "config/AGENTS.md existe" "$GUIDE_SRC"
  local n; n="$(wc -l < "$GUIDE_SRC" 2>/dev/null | tr -d ' ')"
  (( ${n:-0} > 0 && ${n:-0} <= 70 )) && ok || nok "la guía debe tener entre 1 y 70 líneas (tiene ${n:-0})"
  assert_has "marca de componentes" "$(cat "$GUIDE_SRC" 2>/dev/null)" "<!-- componentes -->"
}

t_guide_commands_allowed() {
  [[ -f "$GUIDE_SRC" ]] || { nok "falta $GUIDE_SRC"; return 0; }
  local cmds c found=0
  # primer término de cada fragmento `...` en filas de tabla
  cmds="$(grep -E '^\|' "$GUIDE_SRC" | grep -oE '`[^`]+`' | tr -d '`' | awk '{print $1}' | grep -E '^[a-z][a-z0-9-]*$' | sort -u)"
  for c in $cmds; do
    found=1
    if [[ " ${GUIDE_ALLOWED[*]} " == *" $c "* ]]; then ok; else nok "la guía cita '$c', que no está en la lista permitida"; fi
  done
  (( found )) && ok || nok "la guía no cita ningún comando en sus tablas"
}

t_guide_commands_checked_by_ci() {
  local ci="$ROOT/.github/workflows/ci.yml" c
  [[ -f "$ci" ]] || { nok "falta ci.yml"; return 0; }
  for c in "${CI_CHECKED[@]}"; do
    if grep -qE "(^|[[:space:]])$c([[:space:]]|;|\\\\|$)" "$ci"; then ok; else nok "CI no verifica '$c' dentro de la imagen"; fi
  done
}

t_ws_doctor_has_guide_option() {
  assert_has "ws-doctor --guide" "$(cat "$ROOT/config/ws-doctor")" "--guide"
}

run_sym t_seed_creates_both
run_sym t_seed_symlink_target
run_sym t_seed_claude_import
run_sym t_seed_idempotent
run_sym t_seed_no_overwrite_files
run_sym t_seed_no_overwrite_broken_symlink
run_sym t_seed_partial
run t_seed_missing_guide_is_noop
run t_guide_exists_and_short
run t_guide_commands_allowed
run t_guide_commands_checked_by_ci
run t_ws_doctor_has_guide_option

p="$(wc -l < "$PASSES" | tr -d ' ')"; f="$(wc -l < "$FAILS" | tr -d ' ')"
echo
echo "Resultado: $p aserciones correctas, $f fallidas, $SKIPPED pruebas omitidas"
(( f == 0 ))
