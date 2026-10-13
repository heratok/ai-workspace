# shellcheck shell=bash
# lib/background.sh - procesos en segundo plano, instalación/actualización y enlace aiws
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ------------------------------------------------------------ segundo plano
# Lo interactivo (auth key, clave SSH) se pregunta ANTES; lo largo (build) corre
# en una sesión propia (setsid + nohup), inmune al corte de SSH.
bg_running() { [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

run_bg() {   # run_bg <nombre> <paso-interno>
  local name="$1"; shift
  if bg_running; then
    warn "Ya hay un proceso en curso (PID $(cat "$PID_FILE")). Mostrando su progreso."
    follow; return 0
  fi
  install -d -m 700 "$LOG_DIR"
  local log="$LOG_DIR/$name-$(date +%Y%m%d-%H%M%S).log"
  : > "$log"; chmod 600 "$log"
  ln -sfn "$(basename "$log")" "$LOG_DIR/latest.log"
  rm -f "$PID_FILE" "$STATUS_FILE"

  if command -v setsid >/dev/null; then
    setsid nohup bash "$SCRIPT_DIR/setup.sh" __bg "$@" >> "$log" 2>&1 < /dev/null &
  else
    nohup bash "$SCRIPT_DIR/setup.sh" __bg "$@" >> "$log" 2>&1 < /dev/null &
  fi
  disown 2>/dev/null || true
  local _; for _ in $(seq 1 50); do [[ -s "$PID_FILE" ]] && break; sleep 0.1; done

  cat <<EOF

${c_ok}==> Ejecutándose en SEGUNDO PLANO${c_off} (PID $(cat "$PID_FILE" 2>/dev/null || echo '?')).
    Si se cae la conexión SSH o cierras la terminal, el proceso SIGUE.
    Volver a ver el progreso:  ./setup.sh progress
    Log completo:              logs/$(basename "$log")
    Ctrl+C solo deja de mostrar el log; NO detiene la instalación.

EOF
  follow
}

bg_entry() {   # se ejecuta dentro del proceso desacoplado
  echo $$ > "$PID_FILE"
  trap 'echo $? > "$STATUS_FILE"; rm -f "$PID_FILE"' EXIT
  export BUILDKIT_PROGRESS=plain        # salida legible en el log (sin TTY)
  echo "== $(date '+%F %T') inicio: $* (PID $$)"
  case "$1" in
    install_steps|update_steps) "$1" ;;
    *) die "Paso interno desconocido: $1" ;;
  esac
  echo "== $(date '+%F %T') fin OK"
}

follow() {
  local log="$LOG_DIR/latest.log" pid
  [[ -e "$log" ]] || { info "No hay procesos registrados todavía."; return 0; }
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  trap 'echo; info "Dejaste de ver el log; el proceso continúa. Retoma con: ./setup.sh progress"; exit 0' INT
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    tail -n +1 -F --pid="$pid" "$log" 2>/dev/null || true
  else
    tail -n 60 "$log" || true
  fi
  trap - INT
  report_status
}

report_status() {
  if bg_running; then info "Sigue en curso (PID $(cat "$PID_FILE")). ./setup.sh progress"; return 0; fi
  [[ -f "$STATUS_FILE" ]] || return 0
  local rc; rc="$(cat "$STATUS_FILE")"
  if [[ "$rc" == 0 ]]; then info "Último proceso: terminó correctamente."; return 0; fi
  echo "${c_err}[error]${c_off} Último proceso terminó con error (código $rc). Revisa: logs/latest.log" >&2
  exit "$rc"   # el estado real llega al llamador (aiws, scripts); exit evita el aviso genérico del trap ERR
}

# Clave SSH: se recoge en primer plano y se aplica al final del proceso en segundo plano
collect_pubkey() {
  local src="${1:-}" keys=""
  [[ -z "$src" && -f "$KEY_OK" ]] && return 0
  [[ -z "$src" ]] && src="$(default_pubkey)"
  if [[ "$src" == github:* ]]; then
    keys="$(curl -fsSL "https://github.com/${src#github:}.keys")" || die "No pude descargar las claves de ${src#github:}"
  elif [[ -n "$src" && -f "$src" ]]; then
    keys="$(cat "$src")"
  elif [[ -n "$src" ]]; then
    keys="$src"
  elif [[ -t 0 ]]; then
    cat <<EOF

Clave PÚBLICA SSH para entrar al workspace (una línea ssh-ed25519 / ssh-rsa / ecdsa-...)
  En tu PC Windows (PowerShell):  type \$env:USERPROFILE\.ssh\id_ed25519.pub
  ¿No tienes?  ssh-keygen -t ed25519   y luego el comando de arriba.
EOF
    read -rp "Clave pública (Enter para omitir): " keys || true
  fi
  [[ -z "$keys" ]] && { warn "Sin clave SSH: agrégala después con ./setup.sh add-key"; return 0; }
  [[ "$keys" == *"PRIVATE KEY"* ]] && die "Eso es una clave PRIVADA. Usa solo el contenido del archivo .pub"
  grep -qE '^(ssh-|ecdsa-|sk-)' <<<"$(tr -d '\r' <<<"$keys")" || die "No parece una clave pública SSH."
  install -d -m 700 "$LOG_DIR"
  ( umask 077; printf '%s\n' "$keys" | tr -d '\r' > "$PENDING_KEY" )
  info "Clave SSH recibida; se aplicará al terminar la instalación."
}

install_steps() {
  run_migrations
  create_volumes
  build_and_up
  forget_authkey
  if [[ -s "$PENDING_KEY" ]]; then
    add_key "$PENDING_KEY" && rm -f "$PENDING_KEY" && touch "$KEY_OK"
  elif docker exec "$CONTAINER" test -s "/home/$WS_USER/.ssh/authorized_keys"; then
    touch "$KEY_OK"
  else
    warn "Sin clave SSH autorizada. Agrégala con: ./setup.sh add-key"
  fi
  install_aiws_link || true
  doctor || warn "ws-doctor reportó problemas (revisa arriba)."
  summary
}

update_steps() { run_migrations; build_and_up --no-cache; clean; doctor || true; install_aiws_link || true; }

# Deja "aiws" en el PATH: enlace al aiws de este clon, en /usr/local/bin si se puede escribir ahí
# y si no en ~/.local/bin. Cualquier clon sirve (aiws descubre todas las instancias), así que un
# enlace existente a otro clon se respeta salvo que su destino ya no exista.
is_writable() { [[ -w "$1" ]]; }

# Avisa si aiws queda dentro de /root: otros usuarios del servidor no podrán usarlo
warn_root_clone() {
  if [[ "$(id -u)" == 0 && "$SCRIPT_DIR" == /root/* ]]; then
    warn "Este clon está en $SCRIPT_DIR: otros usuarios del servidor no podrán ejecutar aiws. Para compartirlo, clona en una ruta común (ej.: AIWS_DIR=/opt/ai-workspace)."
  fi
  return 0
}

install_aiws_link() {
  local src="$SCRIPT_DIR/aiws" sys="${AIWS_SYSTEM_BIN:-/usr/local/bin}" dir link target=""
  [[ -f "$src" ]] || return 0
  chmod +x "$src" 2>/dev/null || true
  # 1) un enlace vivo (a este u otro clon) se respeta; uno roto se rehace si se puede escribir
  for dir in "$sys" "$HOME/.local/bin"; do
    link="$dir/aiws"
    if [[ -L "$link" ]]; then
      [[ -e "$link" ]] && return 0
      if is_writable "$dir"; then ln -sfn "$src" "$link" && info "Enlace de aiws reparado: $link" && warn_root_clone; return 0; fi
      warn "El enlace $link está roto y no puedo escribir en $dir; pruebo con otra carpeta."
    elif [[ -e "$link" ]]; then
      warn "Ya existe $link y no es un enlace: no lo toco."
    elif [[ -z "$target" ]] && { is_writable "$dir" || [[ "$dir" == "$HOME/.local/bin" ]]; }; then
      target="$dir"                                  # primera carpeta libre y utilizable
    fi
  done
  [[ -n "$target" ]] || { warn "No encontré dónde instalar aiws. Enlázalo a mano: ln -s $src ~/.local/bin/aiws"; return 0; }
  mkdir -p "$target" 2>/dev/null || true
  ln -s "$src" "$target/aiws" || { warn "No pude crear el enlace de aiws en $target."; return 0; }
  info "Comando aiws instalado en $target/aiws (gestiona todas las instancias: aiws help)"
  if [[ ":$PATH:" != *":$target:"* ]]; then
    warn "$target no está en tu PATH. Agrégalo con:  echo 'export PATH=\"$target:\$PATH\"' >> ~/.bashrc  y abre una sesión nueva."
  fi
  warn_root_clone
}
