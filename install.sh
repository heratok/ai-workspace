#!/usr/bin/env bash
# =============================================================================
# ai-workspace - instalación en un solo comando
#
#   curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 ...'
#
# Clona el repositorio (o lo actualiza si ya existe) y ejecuta "setup.sh install"
# con los argumentos recibidos. setup.sh necesita vivir en un clon de git para
# que luego funcionen "upgrade" y "rollback".
#
# Variables opcionales:
#   AIWS_DIR          Carpeta de instalación   (por defecto: ~/ai-workspace)
#   AIWS_REPO_URL     Repositorio              (por defecto: https://github.com/heratok/ai-workspace.git)
#   AIWS_REPO_BRANCH  Rama o tag               (por defecto: main)
# =============================================================================

# Todo va dentro de main(), que se llama en la última línea: si la descarga se
# corta a la mitad, bash no ejecuta un script incompleto.
main() {
  set -Eeuo pipefail

  local dir="${AIWS_DIR:-$HOME/ai-workspace}"
  local repo="${AIWS_REPO_URL:-https://github.com/heratok/ai-workspace.git}"
  local branch="${AIWS_REPO_BRANCH:-main}"

  info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
  warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

  command -v git >/dev/null    || die "Falta git en el servidor (ej.: sudo apt-get install -y git)."
  command -v docker >/dev/null || die "Falta Docker en el servidor: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "Falta el plugin \"docker compose\"."

  if [[ -d "$dir/.git" ]]; then
    info "Ya existe $dir: actualizando ($branch)..."
    if ! git -C "$dir" pull -q --ff-only origin "$branch"; then
      warn "No se pudo actualizar sin conflictos; sigo con la versión local (luego: ./setup.sh upgrade)."
    fi
  elif [[ -e "$dir" ]]; then
    die "$dir existe pero no es un clon de git. Muévelo o usa AIWS_DIR=/otra/ruta."
  else
    info "Clonando $repo ($branch) en $dir..."
    git clone -q --branch "$branch" "$repo" "$dir"
  fi

  chmod +x "$dir/setup.sh"
  cd "$dir"
  info "Ejecutando setup.sh install..."

  # Con "curl | bash" la entrada estándar es el propio script: las preguntas de
  # setup.sh (auth key, clave SSH, componentes) deben leer de la terminal.
  if [[ -t 0 ]]; then
    exec ./setup.sh install "$@"
  elif { : </dev/tty; } 2>/dev/null; then
    exec ./setup.sh install "$@" </dev/tty
  else
    warn "Sin terminal interactiva: pasa --authkey y --pubkey para que no haga preguntas."
    exec ./setup.sh install "$@" </dev/null
  fi
}

main "$@"
