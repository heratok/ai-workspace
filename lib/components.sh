# shellcheck shell=bash
# lib/components.sh - componentes de la imagen seleccionables
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ------------------------------------------------------------ componentes
# Formato: VARIABLE|Nombre|Por defecto|Descripción
COMPONENTS=(
  "INSTALL_CLAUDE|Claude Code|true|agente de Anthropic (claude)"
  "INSTALL_PI|Pi|true|agente pi-coding-agent"
  "INSTALL_OPENCODE|opencode|false|agente opencode (opencode-ai)"
  "INSTALL_AGY|Antigravity CLI|true|agente de Google (agy)"
  "INSTALL_GENTLE_AI|Gentle AI|true|memoria y flujos para tus agentes (gentle-ai)"
  "INSTALL_HERDR|Herdr|true|sesiones de agentes persistentes (herdr)"
  "INSTALL_PLAYWRIGHT|Playwright|true|navegador para agentes: playwright, -cli, -mcp + Chromium (~600 MB)"
  "INSTALL_DOPPLER|Doppler CLI|true|gestor de secretos (doppler)"
  "INSTALL_MSSQL_TOOLS|SQL Server tools|false|sqlcmd y bcp (mssql-tools18)"
)

comp_value() {   # valor actual (o el defecto) de un componente
  local var="$1" def="$2" v; v="$(env_get "$var")"
  [[ "$v" == true || "$v" == false ]] && echo "$v" || echo "$def"
}

# Menú de selección. Devuelve 0 si se guardaron cambios.
choose_components() {
  local -a vars names defs descs vals
  local i entry n="${#COMPONENTS[@]}"
  for i in "${!COMPONENTS[@]}"; do
    IFS='|' read -r vars[i] names[i] defs[i] descs[i] <<< "${COMPONENTS[i]}"
    vals[i]="$(comp_value "${vars[i]}" "${defs[i]}")"
  done
  local orig=("${vals[@]}") input tok
  while true; do
    echo
    echo "${c_ok}Componentes de la imagen${c_off} (lo base siempre viene: git, gh, Node, Python/uv, mise, psql, devdb, zsh...)"
    for i in "${!vars[@]}"; do
      local mark="[ ]"; [[ "${vals[i]}" == true ]] && mark="[x]"
      printf '  %2d) %s %-17s %s\n' "$((i+1))" "$mark" "${names[i]}" "${descs[i]}"
    done
    echo "  Escribe números para marcar/desmarcar (ej: 3 7), a=todos, n=ninguno, d=por defecto,"
    read -rp "  Enter=guardar, q=cancelar: " input || input=q
    case "$input" in
      "") break ;;
      q|Q) info "Sin cambios."; return 1 ;;
      a|A) for i in "${!vals[@]}"; do vals[i]=true; done ;;
      n|N) for i in "${!vals[@]}"; do vals[i]=false; done ;;
      d|D) for i in "${!vals[@]}"; do vals[i]="${defs[i]}"; done ;;
      *) for tok in $input; do
           if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
             i=$((tok-1)); [[ "${vals[i]}" == true ]] && vals[i]=false || vals[i]=true
           else warn "Opción inválida: $tok"; fi
         done ;;
    esac
  done
  local changed=false
  for i in "${!vars[@]}"; do
    env_set "${vars[i]}" "${vals[i]}"
    [[ "${vals[i]}" != "${orig[i]}" ]] && changed=true
  done
  info "Componentes guardados en .env"
  [[ "$changed" == true ]]
}

components_cmd() {
  [[ -f "$ENV_FILE" ]] || { cp "$ENV_EXAMPLE" "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  if choose_components; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      confirm "¿Reconstruir ahora para aplicar los cambios?" && exec bash "$SCRIPT_DIR/setup.sh" update
      info "Aplícalos cuando quieras con: ./setup.sh update"
    fi
  fi
  return 0
}
