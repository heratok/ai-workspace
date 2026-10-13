#!/usr/bin/env bash
# =============================================================================
# ai-workspace - instalador / operador en un solo script
#
#   ./setup.sh                       Menú interactivo (instalar, desinstalar, estado...)
#   ./setup.sh install [--pubkey RUTA.pub|'ssh-ed25519 ...'] [--authkey tskey-auth-...] [--alias NOMBRE] [--mem 4g] [--cpus 2] [--foreground]
#                                    Pide lo que falte y luego sigue en SEGUNDO PLANO:
#                                    si se cae SSH, la instalación continúa.
#                                    --alias: instancia aislada ai-workspace-NOMBRE (varias por servidor;
#                                    una carpeta = una instancia). Lo normal es crearla con install.sh.
#   ./setup.sh progress              Ver el progreso / resultado del último proceso
#   ./setup.sh upgrade [--yes]       Descarga lo último de GitHub (git), migra y reconstruye (--yes: sin preguntas)
#   ./setup.sh resources [--mem 4g --cpus 2 ...]  Ver límites y uso real, o cambiarlos SIN reconstruir (--set: elegir uno a uno)
#   ./setup.sh components            Elegir qué agentes/herramientas trae la imagen
#   ./setup.sh rollback              Vuelve a la versión anterior al último upgrade
#   ./setup.sh clean [--deep]        Limpia imágenes viejas, logs y respaldos antiguos
#   ./setup.sh update                Reconstruye con versiones nuevas
#   ./setup.sh add-key [RUTA.pub | 'ssh-ed25519 AAAA...' | github:usuario]
#                                    Autoriza una clave SSH (sin argumento: la pide para pegar)
#   ./setup.sh backup                Respalda home + proyectos en ./backups (con checksum)
#   ./setup.sh restore [ARCHIVO] [--yes]  Restaura un respaldo (por defecto el más reciente; hace antes uno de seguridad)
#   ./setup.sh tools [--yes] [--reset]  Busca versiones nuevas de las herramientas, eliges cuáles aplicar (se guardan en .env) y reconstruye
#   ./setup.sh uninstall [--yes]     Quita contenedores e imagen; CONSERVA datos
#   ./setup.sh uninstall --all       Borra TODO: datos, volúmenes, .env, nodo Tailscale
#   ./setup.sh status | logs | shell | psql | doctor | ts-status | down
#   (bases de datos locales: dentro del workspace usa "devdb help")
#
# Requisito único en el servidor: Docker + plugin "docker compose".
# Variables del .env: ver env.example y docs/configuracion.md.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WS_USER="ai"
WS_SERVICE="ai-workspace"             # nombre del servicio en docker-compose.yml (no cambia con el alias)
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/env.example"
REPO_URL="${AIWS_REPO_URL:-https://github.com/heratok/ai-workspace.git}"
REPO_BRANCH="${AIWS_REPO_BRANCH:-main}"
LOG_DIR="$SCRIPT_DIR/logs"            # logs + estado de procesos en segundo plano
PID_FILE="$LOG_DIR/.pid"
STATUS_FILE="$LOG_DIR/.status"
PENDING_KEY="$LOG_DIR/.pending-key.pub"
KEY_OK="$LOG_DIR/.ssh-key-ok"

# ----------------------------------------------------------------- módulos
# La lógica vive en lib/. El ORDEN importa: las asignaciones globales de cada módulo se ejecutan al cargarlo.
[[ -f "$SCRIPT_DIR/lib/common.sh" ]] || { echo "[error] Falta la carpeta lib/ (copia incompleta): vuelve a copiar o clonar el repositorio completo." >&2; exit 1; }
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/instances.sh
source "$SCRIPT_DIR/lib/instances.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/lifecycle.sh
source "$SCRIPT_DIR/lib/lifecycle.sh"
# shellcheck source=lib/background.sh
source "$SCRIPT_DIR/lib/background.sh"
# shellcheck source=lib/resources.sh
source "$SCRIPT_DIR/lib/resources.sh"
# shellcheck source=lib/components.sh
source "$SCRIPT_DIR/lib/components.sh"
# shellcheck source=lib/maintenance.sh
source "$SCRIPT_DIR/lib/maintenance.sh"
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/lib/backup.sh"
# shellcheck source=lib/uninstall.sh
source "$SCRIPT_DIR/lib/uninstall.sh"
# shellcheck source=lib/tools.sh
source "$SCRIPT_DIR/lib/tools.sh"

# Muestra el encabezado de este archivo (hasta la línea de cierre "# ====")
usage() { awk 'NR >= 3 { if ($0 ~ /^# =+$/) exit; print }' "$0" | sed 's/^# \{0,1\}//'; }

menu() {
  local running=false
  bg_running && running=true
  echo
  echo "${c_ok}${AIWS_NAME}${c_off} — ¿qué quieres hacer?"
  if [[ -d "$SCRIPT_DIR/.git" ]]; then echo "  versión: $(g log -1 --format='%h %s (%cr)' 2>/dev/null)"; fi
  tools_notice || true   # "N herramientas con versión nueva" (caché, tope de 4 s, silencioso si falla)
  if [[ "$running" == true ]]; then
    echo "  ${c_warn}>> Hay una instalación/actualización EN CURSO (PID $(cat "$PID_FILE")). Usa la opción 3 para verla.${c_off}"
  fi
  cat <<EOF
  1) Instalar / reinstalar
  2) Actualizar a la última versión (GitHub) y reconstruir
  3) Ver progreso de la instalación (o el resultado de la última)
  4) Elegir componentes (qué agentes y herramientas se instalan)
  5) Estado y diagnóstico
  6) Agregar clave SSH
  7) Respaldar datos (home + proyectos)
  8) Limpiar (imágenes viejas, logs y respaldos antiguos)
  9) Desinstalar (conserva datos)
 10) Desinstalar TODO (borra datos)
 11) Buscar actualizaciones de herramientas
  0) Salir
EOF
  local opt def=""; [[ "$running" == true ]] && def=3
  read -rp "Opción${def:+ [$def]}: " opt || true
  opt="${opt:-$def}"
  case "$opt" in
    1) main install ;;
    2) main upgrade ;;
    3) main progress ;;
    4) main components ;;
    5) compose ps; doctor || true ;;
    6) main add-key ;;
    7) main backup ;;
    8) main clean ;;
    9) main uninstall ;;
    10) main uninstall --all ;;
    11) main tools ;;
    *) info "Nada que hacer." ;;
  esac
}

# ------------------------------------------------------------------------ main
main() {
  local cmd="${1:-}"; shift || true
  if [[ -z "$cmd" ]]; then
    if [[ -t 0 ]]; then menu; return; else cmd=install; fi   # sin terminal: instala
  fi

  case "$cmd" in
    install)
      local pubkey="" authkey="" foreground=false alias_set=false alias_arg=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --alias)      alias_arg="${2:?falta el alias}"; alias_set=true; shift 2 ;;
          --mem)        SIZE_MEM="${2:?falta el tamaño (ej.: --mem 4g)}"; shift 2 ;;
          --mem=*)      SIZE_MEM="${1#*=}"; shift ;;
          --cpus)       SIZE_CPUS="${2:?falta el número de CPUs (ej.: --cpus 2)}"; shift 2 ;;
          --cpus=*)     SIZE_CPUS="${1#*=}"; shift ;;
          --pubkey)     pubkey="${2:?falta ruta o clave}"; shift 2 ;;
          --authkey)    authkey="${2:?falta key}"; shift 2 ;;
          --foreground) foreground=true; shift ;;
          *) die "Opción desconocida: $1" ;;
        esac
      done
      if bg_running; then warn "Ya hay una instalación en curso."; follow; return 0; fi
      # 1) Preguntas (rápido, en primer plano)
      check_prereqs
      check_files
      normalize_line_endings
      if [[ "$alias_set" == true ]]; then bind_alias "$alias_arg"; fi
      check_instance_owner
      configure_env "$authkey"
      registry_add
      collect_pubkey "$pubkey"
      # 2) Lo largo: en segundo plano, inmune al corte de SSH
      if [[ "$foreground" == true ]]; then install_steps; else run_bg install install_steps; fi
      ;;
    update)
      check_prereqs; check_files; normalize_line_endings
      if [[ "${1:-}" == --foreground ]]; then update_steps; else run_bg update update_steps; fi ;;
    progress)  follow ;;
    resources) resources "$@" ;;
    upgrade|self-update) check_prereqs; upgrade "$@" ;;
    rollback)  check_prereqs; rollback ;;
    clean)     check_prereqs; clean "$@" ;;
    components) components_cmd ;;
    migrate)   run_migrations ;;
    __bg)      bg_entry "$@" ;;
    add-key)   add_key "${1:-}" ;;
    status)    compose ps ;;
    logs)      compose logs -f --tail 100 ;;
    shell)     docker exec -it -u "$WS_USER" "$CONTAINER" zsh -l ;;
    psql)      docker exec -it -u "$WS_USER" "$CONTAINER" zsh -lc 'devdb psql' ;;
    doctor)    doctor ;;
    ts-status) docker exec "$TS_CONTAINER" tailscale status ;;
    backup)    check_prereqs; backup ;;
    restore)   check_prereqs; restore "$@" ;;
    tools)     tools_cmd "$@" ;;
    uninstall) check_prereqs; uninstall "$@" ;;
    purge)     check_prereqs; uninstall --all "$@" ;;
    down)      compose down; info "Contenedores detenidos. Volúmenes (datos e identidad Tailscale) se conservan." ;;
    -h|--help|help) usage ;;
    *) usage; die "Comando desconocido: $cmd" ;;
  esac
}

# Permite "source setup.sh" en pruebas sin ejecutar nada
# "exit" a propósito: "upgrade" reemplaza este archivo mientras corre; tras main no se debe leer ni un byte más.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit; fi
