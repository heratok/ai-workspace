# shellcheck shell=bash
# lib/tools.sh - versiones nuevas de las herramientas de la imagen: "./setup.sh tools" y el aviso del menú.
# Se carga con "source" desde setup.sh; no se ejecuta solo.
#
# La consulta y la escritura viven en scripts/update-pins.sh con --target env: SOLO toca el .env del servidor
# (nunca los archivos del repo, así "upgrade" no ve cambios locales) y omite los componentes desactivados.
# agy no se fija a propósito: siempre instala la última al construir ("./setup.sh update").

TOOLS_SCRIPT="$SCRIPT_DIR/scripts/update-pins.sh"
TOOLS_CACHE="$LOG_DIR/.tools-check"        # 1ª línea: epoch de la consulta; el resto: salida TSV de "check"
TOOLS_TRY="$LOG_DIR/.tools-check-try"      # epoch del último intento (con o sin éxito): sin red no se reintenta en cada menú
TOOLS_OUTDATED=()                          # ids con versión nueva (los deja tools_print_table)
TOOLS_PENDING=0                            # herramientas cuyo valor fijado difiere de lo que hay en la imagen

tools_run() { PINS_ROOT="$SCRIPT_DIR" PINS_ENV="$ENV_FILE" bash "$TOOLS_SCRIPT" --target env "$@"; }

tools_rebuild() { main update; }

tools_cache_save() {   # tools_cache_save <tsv>
  mkdir -p "$LOG_DIR"
  { date +%s; printf '%s\n' "$1"; } > "$TOOLS_CACHE"
}

# "id=versión" por línea, leído de la etiqueta de la imagen (vacío si no hay imagen o etiqueta)
tools_image_versions() {
  docker image inspect --format '{{ index .Config.Labels "org.ai-workspace.versions" }}' "$IMAGE" 2>/dev/null | tr ',' '\n' | grep '=' || true
}

# Tabla de herramientas. Las de versión nueva llevan número para poder elegirlas.
tools_print_table() {   # tools_print_table <tsv>
  local tsv="$1" id label pin latest origin status num n=0 errs=0 img state v
  local -A inimg=()
  while IFS='=' read -r id v; do [[ -n "$id" ]] && inimg[$id]="$v"; done < <(tools_image_versions)
  TOOLS_OUTDATED=(); TOOLS_PENDING=0
  printf '%-4s %-16s %-11s %-11s %-11s %-7s %s\n' "" HERRAMIENTA "EN IMAGEN" FIJADA ÚLTIMA ORIGEN ESTADO
  while IFS=$'\t' read -r id label pin latest origin status; do
    [[ -n "$id" ]] || continue
    img="${inimg[$id]:--}"; num=""; state="al día"
    case "$status" in
      outdated) n=$((n + 1)); TOOLS_OUTDATED+=("$id"); num="$n)"; state="nueva versión" ;;
      error)    errs=$((errs + 1)); state="sin respuesta" ;;
      *)        if [[ "$img" != "-" && "$img" != "$pin" ]]; then TOOLS_PENDING=$((TOOLS_PENDING + 1)); state="reconstruir"; fi ;;
    esac
    printf '%-4s %-16s %-11s %-11s %-11s %-7s %s\n' "$num" "$id" "$img" "$pin" "$latest" "$origin" "$state"
  done <<< "$tsv"
  echo
  echo "${#TOOLS_OUTDATED[@]} con versión nueva, $TOOLS_PENDING pendiente(s) de reconstruir, $errs sin respuesta."
}

tools_cmd() {
  local yes=false reset=false a
  for a in "$@"; do
    case "$a" in
      --yes|-y) yes=true ;;
      --reset)  reset=true ;;
      *) die "Opción desconocida para tools: $a (usa --yes o --reset)" ;;
    esac
  done
  [[ -f "$TOOLS_SCRIPT" ]] || die "Falta scripts/update-pins.sh (copia incompleta de la carpeta)."
  [[ -f "$ENV_FILE" ]] || die "No hay .env todavía: ejecuta ./setup.sh install primero."

  if [[ "$reset" == true ]]; then
    tools_run reset
    rm -f "$TOOLS_CACHE"
    if [[ "$yes" == true ]] || confirm "¿Reconstruir ahora la imagen con las versiones del repo?"; then tools_rebuild; fi
    return 0
  fi

  info "Consultando las últimas versiones (npm y GitHub)..."
  local tsv; tsv="$(tools_run check --tsv)" || die "No pude consultar las versiones (¿sin red?)."
  tools_cache_save "$tsv"
  echo
  tools_print_table "$tsv"
  echo

  if (( ${#TOOLS_OUTDATED[@]} == 0 )); then
    info "Todo al día."
    if (( TOOLS_PENDING > 0 )) && { [[ "$yes" == true ]] || confirm "Hay $TOOLS_PENDING herramienta(s) con otra versión en el .env que la imagen. ¿Reconstruir ahora?"; }; then tools_rebuild; fi
    return 0
  fi

  local -a sel=(); local choice n
  if [[ "$yes" == true ]]; then
    sel=("${TOOLS_OUTDATED[@]}")
  else
    has_tty || die "tools necesita responder preguntas y no hay terminal: usa ./setup.sh tools --yes (actualiza todo y reconstruye sin preguntar)."
    read -rp "¿Cuáles actualizar? [t]odas, números separados por coma, Enter = ninguna: " choice || true
    [[ -n "$choice" ]] || { info "No se cambió nada."; return 0; }
    if [[ "${choice,,}" == t || "${choice,,}" == todas ]]; then
      sel=("${TOOLS_OUTDATED[@]}")
    else
      local -a nums=(); IFS=',' read -ra nums <<< "${choice// /}"
      for n in "${nums[@]}"; do   # se valida TODO antes de cambiar nada
        [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#TOOLS_OUTDATED[@]} )) || die "Selección inválida: '$n' (elige entre 1 y ${#TOOLS_OUTDATED[@]}, o t)."
        sel+=("${TOOLS_OUTDATED[n - 1]}")
      done
    fi
  fi

  for a in "${sel[@]}"; do tools_run set "$a" latest || warn "No pude fijar $a."; done
  rm -f "$TOOLS_CACHE"   # el aviso del menú se recalcula en la próxima apertura
  info "Guardado en .env (no se tocaron los archivos del repo). Para volver a las versiones del repo: ./setup.sh tools --reset"
  if [[ "$yes" == true ]] || confirm "¿Reconstruir ahora la imagen? (./setup.sh update)"; then tools_rebuild
  else info "Cuando quieras aplicarlos: ./setup.sh update"; fi
}

# Aviso al abrir el menú. Caché de 12 h, tope de 5 s, un intento cada 15 min; falla en silencio y nunca bloquea.
tools_notice() {
  [[ -z "${AIWS_NO_TOOLS_CHECK:-}" && -f "$TOOLS_SCRIPT" && -f "$ENV_FILE" ]] || return 0
  local now ts=0 last=0 out n
  now="$(date +%s)"
  if [[ -s "$TOOLS_CACHE" ]]; then ts="$(head -n1 "$TOOLS_CACHE")"; fi
  if [[ -s "$TOOLS_TRY" ]]; then last="$(head -n1 "$TOOLS_TRY")"; fi
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - ts > ${AIWS_TOOLS_CACHE_TTL:-43200} && now - last > 900 )); then
    mkdir -p "$LOG_DIR"; echo "$now" > "$TOOLS_TRY"
    out="$(mktemp)"   # a un archivo (no $(...)): si el timeout mata el script, no se espera a los procesos hijos
    if PINS_ROOT="$SCRIPT_DIR" PINS_ENV="$ENV_FILE" timeout "${AIWS_TOOLS_CHECK_TIMEOUT:-5}" bash "$TOOLS_SCRIPT" --target env check --tsv > "$out" 2>/dev/null \
       && awk -F'\t' '$6 != "error" { found = 1 } END { exit !found }' "$out"; then   # si NADA respondió (sin red), no pisar una caché buena
      tools_cache_save "$(cat "$out")"
    fi
    rm -f "$out"
  fi
  [[ -s "$TOOLS_CACHE" ]] || return 0
  n="$(tail -n +2 "$TOOLS_CACHE" | awk -F'\t' '$6 == "outdated"' | wc -l | tr -d ' ')"
  if (( n > 0 )); then echo "  ${c_warn}>> $n herramienta(s) con versión nueva${c_off} (opción 11 o ./setup.sh tools)"; fi
  return 0
}
