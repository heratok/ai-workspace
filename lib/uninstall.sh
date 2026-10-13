# shellcheck shell=bash
# lib/uninstall.sh - desinstalación
# Se carga con "source" desde setup.sh; no se ejecuta solo.

uninstall() {
  local all=false yes=false
  for a in "$@"; do
    case "$a" in
      --all|--purge) all=true ;;
      --yes|-y)      yes=true ;;
      *) die "Opción desconocida: $a" ;;
    esac
  done

  if [[ "$all" == false ]]; then
    echo "Se eliminarán contenedores, red e imagen. Se CONSERVAN: home, proyectos, BD locales, identidad SSH y Tailscale, .env."
    [[ "$yes" == true ]] || confirm "¿Continuar?" || { info "Cancelado."; return 0; }
    compose --profile mssql down --remove-orphans || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    registry_remove
    info "Desinstalado. Para volver: ./setup.sh install (los datos siguen ahí)."
    return 0
  fi

  cat <<EOF
${c_err}DESINSTALAR TODO${c_off} — se borrará de forma PERMANENTE:
  - Proyectos (/workspace) y home del usuario (configuración, herramientas, BD locales de devdb)
  - Identidad SSH del servidor y nodo de Tailscale
  - SQL Server (si existía), imagen, contenedores, red y el archivo .env
  Los respaldos en ./backups NO se borran.
EOF
  if [[ "$yes" != true ]]; then
    if confirm "¿Hacer un respaldo antes de borrar? (recomendado)"; then backup; fi
    local word; read -rp "Escribe BORRAR para confirmar: " word || true
    [[ "$word" == "BORRAR" ]] || { info "Cancelado. No se borró nada."; return 0; }
  fi

  # Quitar el equipo de la tailnet antes de destruir su identidad
  docker exec "$TS_CONTAINER" tailscale logout >/dev/null 2>&1 \
    && info "Sesión de Tailscale cerrada (si el equipo sigue en el panel, bórralo allí)." || true
  compose --profile mssql down --remove-orphans || true
  local v
  for v in "${ALL_VOLUMES[@]}"; do
    docker volume rm "$v" >/dev/null 2>&1 && info "Volumen $v eliminado" || true
  done
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
  registry_remove
  info "Todo eliminado. Los archivos de esta carpeta quedan para reinstalar con ./setup.sh install"
}
