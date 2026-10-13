# shellcheck shell=bash
# lib/common.sh - utilidades (mensajes, compose, .env) y registro de instancias
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ----------------------------------------------------------------- utilidades
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_ok}==>${c_off} $*"; }
warn() { echo "${c_warn}[aviso]${c_off} $*" >&2; }
die()  { echo "${c_err}[error]${c_off} $*" >&2; exit 1; }
trap 'die "falló en la línea $LINENO: $BASH_COMMAND"' ERR

compose() {
  # AIWS_NAME / AIWS_VOL_PREFIX se pasan siempre desde los nombres derivados de esta
  # instancia, así compose y setup.sh nunca discrepan aunque el .env se edite a mano.
  local -a envf=(); [[ -f "$ENV_FILE" ]] && envf=(--env-file "$ENV_FILE")
  AIWS_NAME="$AIWS_NAME" AIWS_VOL_PREFIX="$AIWS_VOL_PREFIX" docker compose ${envf[@]+"${envf[@]}"} "$@"
}

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}
# Escritura segura (valores con / & | @ espacios) sin sed
env_set() {
  local key="$1" val="$2" tmp
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  tmp="$(mktemp "$ENV_FILE.XXXX")"
  KEY="$key" VAL="$val" awk '
    BEGIN { k=ENVIRON["KEY"]; v=ENVIRON["VAL"]; done=0 }
    index($0, k"=")==1 { if (!done) { print k"="v; done=1 }; next }
    { print }
    END { if (!done) print k"="v }
  ' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}

env_del() {   # elimina una variable obsoleta del .env
  [[ -f "$ENV_FILE" ]] || return 0
  grep -qE "^$1=" "$ENV_FILE" || return 0
  local tmp; tmp="$(mktemp "$ENV_FILE.XXXX")"
  grep -vE "^$1=" "$ENV_FILE" > "$tmp" || true
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}

# Registro por usuario de las carpetas de instancias (aiws lo lee: una instancia fuera de ~/ai-workspace*
# deja de tener contenedores tras "down" y, sin esto, desaparecería de la lista).
registry_file() { echo "${XDG_DATA_HOME:-$HOME/.local/share}/ai-workspace/instances"; }
registry_add() {
  local f; f="$(registry_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  touch "$f" 2>/dev/null || return 0
  grep -qxF "$SCRIPT_DIR" "$f" || echo "$SCRIPT_DIR" >> "$f"
  return 0
}
registry_remove() {
  local f tmp; f="$(registry_file)"
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp "$f.XXXX")" || return 0
  grep -vxF "$SCRIPT_DIR" "$f" > "$tmp" || true
  mv "$tmp" "$f"
}
