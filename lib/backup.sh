# shellcheck shell=bash
# lib/backup.sh - respaldo y restauración
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ------------------------------------------------------------ respaldo / desinstalación
confirm() {   # confirm "pregunta" -> 0 si responde s/S
  local ans; read -rp "$1 [s/N]: " ans || true
  [[ "$ans" =~ ^[sSyY]$ ]]
}

backup() {
  local dest="$SCRIPT_DIR/backups" file v mounts=()
  for v in "${VOLUMES[@]}"; do
    docker volume inspect "$v" >/dev/null 2>&1 && mounts+=(-v "$v:/v/$v:ro")
  done
  (( ${#mounts[@]} )) || { warn "No hay volúmenes de datos que respaldar."; return 0; }
  mkdir -p "$dest"; chmod 700 "$dest"
  file="$AIWS_NAME-$(date +%Y%m%d-%H%M%S).tar.gz"
  # Si PostgreSQL local está corriendo, se detiene para un respaldo consistente
  docker exec -u "$WS_USER" "$CONTAINER" devdb stop all >/dev/null 2>&1 || true
  info "Respaldando home y proyectos -> backups/$file"
  docker run --rm "${mounts[@]}" -v "$dest:/b" --entrypoint tar \
    "$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "$IMAGE" || echo debian:12-slim)" \
    czf "/b/$file" -C /v .
  chmod 600 "$dest/$file" 2>/dev/null || true
  # Checksum junto al respaldo: "restore" lo verifica antes de tocar nada
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$dest" && sha256sum "$file" > "$file.sha256" ) && chmod 600 "$dest/$file.sha256" 2>/dev/null || true
  fi
  docker exec -u "$WS_USER" "$CONTAINER" devdb autostart >/dev/null 2>&1 || true   # reanuda BD con autostart
  info "Respaldo listo: $dest/$file ($(du -h "$dest/$file" | cut -f1))"
  keep_newest "$dest" "$AIWS_NAME-[0-9]*.tar.gz" "$BACKUP_KEEP"
  keep_newest "$dest" "$AIWS_NAME-[0-9]*.tar.gz.sha256" "$BACKUP_KEEP"
  echo "    Restaurar: ./setup.sh restore $file"
}

# ------------------------------------------------------------ restauración
# Respaldos de ESTA instancia: <AIWS_NAME>-AAAAMMDD-HHMMSS.tar.gz (el alias "2" no confunde a la principal)
is_own_backup_name() { [[ "$1" =~ ^${AIWS_NAME}-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]; }

latest_backup() {   # ruta del respaldo más reciente (por el timestamp del nombre), o nada
  local f best="" n
  for f in "$SCRIPT_DIR/backups/$AIWS_NAME"-*.tar.gz; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f")"; is_own_backup_name "$n" || continue
    [[ -z "$best" || "$n" > "$(basename "$best")" ]] && best="$f"
  done
  [[ -n "$best" ]] && echo "$best"
  return 0
}

resolve_backup() {  # resolve_backup [ARCHIVO]: ruta, nombre dentro de backups/ o (vacío) el más reciente
  local arg="${1:-}" f
  if [[ -z "$arg" ]]; then
    f="$(latest_backup)"; [[ -n "$f" ]] || die "No hay respaldos de $AIWS_NAME en $SCRIPT_DIR/backups."
  elif [[ -f "$arg" ]]; then f="$arg"
  elif [[ -f "$SCRIPT_DIR/backups/$arg" ]]; then f="$SCRIPT_DIR/backups/$arg"
  else die "No existe el respaldo: $arg"; fi
  is_own_backup_name "$(basename "$f")" || die "'$(basename "$f")' no es un respaldo de $AIWS_NAME (¿es de otra instancia?)."
  echo "$f"
}

backup_volumes() {  # volúmenes (nivel superior) contenidos en el archivo, uno por línea (tar lee por stdin: "C:/x" no es un host)
  tar tz < "$1" | awk -F/ 'NF > 1 && $2 != "" { print $2 }' | sort -u
}

validate_backup() {  # validate_backup ARCHIVO: integridad, checksum y que SOLO traiga volúmenes de esta instancia
  local f="$1" v ov known found=0
  if [[ -f "$f.sha256" ]]; then
    ( cd "$(dirname "$f")" && sha256sum -c --status "$(basename "$f").sha256" ) \
      || die "El checksum no coincide: $(basename "$f") está dañado o fue modificado."
  fi
  tar tz < "$f" >/dev/null 2>&1 || die "El archivo no es un tar.gz válido: $(basename "$f")"
  while IFS= read -r v; do
    known=false
    for ov in "${VOLUMES[@]}"; do [[ "$v" == "$ov" ]] && known=true; done
    [[ "$known" == true ]] || die "El respaldo trae '$v', que no es un volumen de $AIWS_NAME. No se restaura."
    found=$((found + 1))
  done < <(backup_volumes "$f")
  (( found > 0 )) || die "El respaldo no contiene volúmenes de $AIWS_NAME."
}

restore() {
  local yes=false file="" a v ov was_running=false
  for a in "$@"; do
    case "$a" in
      --yes|-y) yes=true ;;
      -*) die "Opción desconocida: $a" ;;
      *)  [[ -z "$file" ]] || die "Solo se acepta un respaldo."; file="$a" ;;
    esac
  done
  file="$(resolve_backup "$file")"
  validate_backup "$file"
  local -a vols=(); while IFS= read -r v; do vols+=("$v"); done < <(backup_volumes "$file")

  warn "Se REEMPLAZARÁ el contenido de: ${vols[*]}  (instancia $AIWS_NAME)"
  echo "    Respaldo: $(basename "$file")"
  if [[ "$yes" != true ]]; then confirm "¿Continuar? (antes se hace un respaldo de seguridad del estado actual)" || { info "Cancelado."; return 0; }; fi

  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" == true ]]; then
    was_running=true; info "Deteniendo el workspace para restaurar sin escrituras en curso..."
    compose stop "$WS_SERVICE" >/dev/null
  fi
  info "Respaldo de seguridad del estado actual..."
  backup

  local -a mounts=(); for v in "${vols[@]}"; do mounts+=(-v "$v:/v/$v"); done
  info "Restaurando ${#vols[@]} volumen(es)..."
  docker run --rm "${mounts[@]}" -v "$(dirname "$file"):/b:ro" --entrypoint sh \
    "$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "$IMAGE" || echo debian:12-slim)" \
    -c 'f="$1"; shift; for v in "$@"; do find "/v/$v" -mindepth 1 -delete; done; tar xzf "/b/$f" -C /v' \
    _ "$(basename "$file")" "${vols[@]}"

  if [[ "$was_running" == true ]]; then info "Arrancando el workspace..."; compose start "$WS_SERVICE" >/dev/null; fi
  info "Restauración lista desde $(basename "$file")."
}
