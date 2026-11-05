# shellcheck shell=bash
# lib/backup.sh - respaldo y restauración
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ------------------------------------------------------------ respaldo / desinstalación
confirm() {   # confirm "pregunta" -> 0 si responde s/S
  local ans; read -rp "$1 [s/N]: " ans || true
  [[ "$ans" =~ ^[sSyY]$ ]]
}

backup() {   # backup [--no-rotate]: deja la ruta del respaldo en LAST_BACKUP (vacía si no hubo)
  local dest="$SCRIPT_DIR/backups" file v mounts=() rotate=true img sum written=false
  [[ "${1:-}" == --no-rotate ]] && rotate=false
  LAST_BACKUP=""
  for v in "${VOLUMES[@]}"; do
    docker volume inspect "$v" >/dev/null 2>&1 && mounts+=(-v "$v:/v/$v:ro")
  done
  (( ${#mounts[@]} )) || { warn "No hay volúmenes de datos que respaldar."; return 0; }
  mkdir -p "$dest"; chmod 700 "$dest"
  file="$AIWS_NAME-$(date +%Y%m%d-%H%M%S).tar.gz"
  img="$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "$IMAGE" || echo debian:12-slim)"
  # Si PostgreSQL local está corriendo, se detiene para un respaldo consistente
  docker exec -u "$WS_USER" "$CONTAINER" devdb stop all >/dev/null 2>&1 || true
  info "Respaldando home y proyectos -> backups/$file"
  # tar sale por stdout: el archivo lo crea este usuario (umask 077 -> 600), no root dentro del contenedor.
  # Se escribe como .partial y solo se renombra si tar terminó bien (nunca queda un respaldo a medias con nombre válido).
  if ( umask 077; docker run --rm "${mounts[@]}" --entrypoint tar "$img" czf - -C /v . > "$dest/$file.partial" ) \
     && [[ -s "$dest/$file.partial" ]] && mv -f -- "$dest/$file.partial" "$dest/$file"; then
    written=true
  fi
  docker exec -u "$WS_USER" "$CONTAINER" devdb autostart >/dev/null 2>&1 || true   # reanuda BD con autostart (también si falló)
  if [[ "$written" != true ]]; then
    rm -f -- "$dest/$file.partial"
    die "El respaldo falló; no se guardó ningún archivo."
  fi
  # Checksum junto al respaldo: "restore" lo verifica antes de tocar nada
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(sha256sum < "$dest/$file" | cut -d' ' -f1)" \
      && ( umask 077; echo "$sum  $file" > "$dest/$file.sha256" ) || warn "No se pudo escribir $file.sha256"
  fi
  info "Respaldo listo: $dest/$file ($(du -h "$dest/$file" | cut -f1))"
  LAST_BACKUP="$dest/$file"
  [[ "$rotate" == true ]] && rotate_backups
  echo "    Restaurar: ./setup.sh restore $file"
}

rotate_backups() {   # conserva los BACKUP_KEEP respaldos más nuevos; cada .sha256 se borra con su archivo
  local dest="$SCRIPT_DIR/backups" f own=()
  # Solo nombres de ESTA instancia: el glob "ai-workspace-[0-9]*" también coincide con el alias "2"
  while IFS= read -r f; do
    is_own_backup_name "$(basename "$f")" && own+=("$f")
  done < <(ls -1t "$dest/$AIWS_NAME"-*.tar.gz 2>/dev/null || true)
  if (( ${#own[@]} > BACKUP_KEEP )); then
    for f in "${own[@]:$BACKUP_KEEP}"; do rm -f -- "$f" && echo "    borrado: ${f#"$SCRIPT_DIR"/}"; done
  fi
  for f in "$dest/$AIWS_NAME"-*.tar.gz.sha256; do   # sin huérfanos (también los que dejó la rotación anterior)
    [[ -f "$f" && ! -e "${f%.sha256}" ]] && is_own_backup_name "$(basename "${f%.sha256}")" || continue
    rm -f -- "$f" && echo "    borrado: ${f#"$SCRIPT_DIR"/}"
  done
  return 0
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
  elif [[ -f "$arg" ]]; then f="$(readlink -f -- "$arg")"   # absoluta: "-v backups:/b" sería un volumen con nombre
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
  local yes=false file="" a v was_running=false
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
  backup --no-rotate          # rotar aquí podría borrar justo el respaldo que se va a restaurar
  local safety="$LAST_BACKUP"

  info "Restaurando ${#vols[@]} volumen(es)..."
  if ! extract_backup "$file" "${vols[@]}"; then
    if [[ -n "$safety" ]]; then
      warn "La restauración falló; se vuelve al estado anterior desde $(basename "$safety")..."
      local -a svols=(); while IFS= read -r v; do svols+=("$v"); done < <(backup_volumes "$safety")
      extract_backup "$safety" "${svols[@]}" \
        || warn "Tampoco se pudo volver atrás. Respaldo de seguridad: $safety"
    fi
    if [[ "$was_running" == true ]]; then info "Arrancando el workspace..."; compose start "$WS_SERVICE" >/dev/null; fi
    die "No se pudo restaurar desde $(basename "$file")."
  fi

  if [[ "$was_running" == true ]]; then info "Arrancando el workspace..."; compose start "$WS_SERVICE" >/dev/null; fi
  info "Restauración lista desde $(basename "$file")."
}

extract_backup() {   # extract_backup ARCHIVO VOL...: vacía esos volúmenes y extrae ARCHIVO (ruta absoluta) en ellos
  local file="$1" v; shift
  local -a mounts=(); for v in "$@"; do mounts+=(-v "$v:/v/$v"); done
  docker run --rm "${mounts[@]}" -v "$(dirname "$file"):/b:ro" --entrypoint sh \
    "$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "$IMAGE" || echo debian:12-slim)" \
    -c 'f="$1"; shift; for v in "$@"; do find "/v/$v" -mindepth 1 -delete; done; tar xzf "/b/$f" -C /v' \
    _ "$(basename "$file")" "$@"
}
