#!/usr/bin/env bash
# Siembra la guía para agentes en /workspace. Idempotente: nunca pisa archivos existentes
# (ni archivos ni symlinks, rotos o no). Lo invoca entrypoint.sh como root en cada arranque.
# Las rutas se pueden sobrescribir (pruebas): AIWS_GUIDE_SRC, AIWS_WORKSPACE_DIR, AIWS_OWNER (uid:gid).
set -Eeuo pipefail

SRC="${AIWS_GUIDE_SRC:-/etc/ai-workspace/AGENTS.md}"
DIR="${AIWS_WORKSPACE_DIR:-/workspace}"
OWNER="${AIWS_OWNER:-$(id -u "${WORKSPACE_USER:-ai}"):$(id -g "${WORKSPACE_USER:-ai}")}"

[[ -f "$SRC" ]] || { echo "[seed-guide] AVISO: no existe $SRC; no se siembra la guía."; exit 0; }

if [[ ! -e "$DIR/AGENTS.md" && ! -L "$DIR/AGENTS.md" ]]; then
  ln -s "$SRC" "$DIR/AGENTS.md"
  chown -h "$OWNER" "$DIR/AGENTS.md"
  echo "[seed-guide] sembrado $DIR/AGENTS.md"
fi

if [[ ! -e "$DIR/CLAUDE.md" && ! -L "$DIR/CLAUDE.md" ]]; then
  printf '@%s\n' "$SRC" > "$DIR/CLAUDE.md"
  chown "$OWNER" "$DIR/CLAUDE.md"
  echo "[seed-guide] sembrado $DIR/CLAUDE.md"
fi
