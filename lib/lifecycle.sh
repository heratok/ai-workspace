# shellcheck shell=bash
# lib/lifecycle.sh - ciclo de vida: construir, levantar, esperar servicios, claves SSH y resumen
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ---------------------------------------------------------------- ciclo de vida
wait_healthy() {
  local name="$1" i status="missing"
  for i in $(seq 1 45); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
    case "$status" in
      healthy)   info "$name saludable"; return 0 ;;
      unhealthy) break ;;
    esac
    sleep 2
  done
  docker logs --tail 40 "$name" >&2 || true
  die "$name no quedó saludable (estado: $status)."
}

# Espera a que el nodo tenga IP en la tailnet. Si no hay auth key, muestra el link de login.
ts_wait_login() {
  local timeout=600 waited=0 url="" shown=""
  while (( waited < timeout )); do
    [[ -n "$(ts_ip)" ]] && { info "Tailscale conectado (IP $(ts_ip))"; return 0; }
    url="$(docker logs "$TS_CONTAINER" 2>&1 | grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' | tail -n1 || true)"
    if [[ -n "$url" && "$url" != "$shown" ]]; then
      cat <<EOF

${c_warn}>>> Abre este link en tu navegador y aprueba el equipo:${c_off}

      $url

    (esperando hasta $((timeout / 60)) minutos...)
EOF
      shown="$url"
    fi
    sleep 3; waited=$((waited + 3))
  done
  docker logs --tail 30 "$TS_CONTAINER" >&2 || true
  die "Tailscale no se conectó. Revisa la auth key o vuelve a ejecutar install."
}

build_and_up() {
  info "Construyendo imagen (la primera vez tarda varios minutos)..."
  compose build --pull "$@"
  info "Levantando Tailscale..."
  compose up -d tailscale
  ts_wait_login
  info "Levantando workspace..."
  compose up -d --remove-orphans
  wait_healthy "$TS_CONTAINER"
  wait_healthy "$CONTAINER"
  wait_services
}

wait_services() {
  if profile_on mssql; then info "SQL Server tarda ~30 s en aceptar conexiones la primera vez."; fi
  return 0
}

# Una vez registrado el nodo, la auth key ya no hace falta: se elimina del .env
forget_authkey() {
  if [[ -n "$(env_get TS_AUTHKEY)" ]]; then
    env_set TS_AUTHKEY ""
    info "Nodo registrado: TS_AUTHKEY eliminada del .env (la identidad vive en el volumen $TS_VOLUME)"
    # Recrear ambos (el workspace comparte la red del sidecar) para quitar la key del entorno
    compose up -d --force-recreate
    wait_healthy "$TS_CONTAINER"
    wait_healthy "$CONTAINER"
    wait_services
  fi
}

ts_ip() { docker exec "$TS_CONTAINER" tailscale ip -4 2>/dev/null | head -n1 || true; }

# Acepta: ruta a .pub | la clave pegada como texto | github:usuario | "-" o vacío = pegar
add_key() {
  local src="${1:-}" keys tmp
  tmp="$(mktemp)"

  [[ "$src" == *"PRIVATE KEY"* ]] && die "Eso es una clave PRIVADA. Usa solo el contenido del archivo .pub"
  if [[ -z "$src" || "$src" == "-" ]]; then
    cat <<EOF

Pega tu clave PÚBLICA SSH (una línea que empieza con ssh-ed25519, ssh-rsa o ecdsa-...)
  En tu PC Windows (PowerShell):  type \$env:USERPROFILE\.ssh\id_ed25519.pub
  ¿No tienes?  ssh-keygen -t ed25519   y luego el comando de arriba.
EOF
    read -rp "Clave pública: " keys || true
  elif [[ "$src" == github:* ]]; then
    keys="$(curl -fsSL "https://github.com/${src#github:}.keys")" || die "No pude descargar las claves de GitHub de ${src#github:}"
  elif [[ -f "$src" ]]; then
    [[ "$src" == *.pub ]] || warn "$src no termina en .pub; verifica que NO sea tu clave privada."
    keys="$(cat "$src")"
  elif [[ "$src" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    keys="$src"
  else
    die "No existe el archivo '$src'. Usa: add-key (y pegar), add-key 'ssh-ed25519 AAAA...', add-key RUTA.pub o add-key github:usuario"
  fi

  grep -qE 'PRIVATE KEY' <<<"$keys" && die "Eso es una clave PRIVADA. Pega solo el contenido del archivo .pub"
  printf '%s\n' "$keys" | tr -d '\r' | grep -E '^(ssh-|ecdsa-|sk-)' > "$tmp" || true
  [[ -s "$tmp" ]] || die "No se encontró ninguna clave pública válida."
  # Validación con ssh-keygen del contenedor (no depende de herramientas del servidor)
  docker exec -i "$CONTAINER" ssh-keygen -l -f - < "$tmp" >/dev/null 2>&1 \
    || die "La clave no es válida (¿se cortó al pegar?)."

  docker exec -i "$CONTAINER" bash -c '
    set -e
    d=/home/'"$WS_USER"'/.ssh; f="$d/authorized_keys"
    install -d -m 700 "$d"; touch "$f"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      grep -qxF "$k" "$f" || echo "$k" >> "$f"
    done
    chown -R '"$WS_USER"':'"$WS_USER"' "$d"; chmod 600 "$f"
  ' < "$tmp"
  while IFS= read -r line; do info "Clave autorizada: $line"; done \
    < <(docker exec -i "$CONTAINER" ssh-keygen -l -f - < "$tmp")
  rm -f "$tmp"
}

default_pubkey() {
  local k
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$k" ]]; then echo "$k"; return 0; fi
  done
  return 0
}

doctor() { docker exec -u "$WS_USER" "$CONTAINER" zsh -lc ws-doctor; }

summary() {
  local host ip profiles others; host="$(env_get TS_HOSTNAME)"; host="${host:-$AIWS_NAME}"; ip="$(ts_ip)"
  profiles="$(env_get COMPOSE_PROFILES)"
  cat <<EOF

${c_ok}Listo.${c_off} Accesible SOLO desde tu tailnet (nada publicado en el servidor).
  Instancia: ${AIWS_NAME}${INSTANCE:+  (alias: $INSTANCE)}   Carpeta: ${SCRIPT_DIR}
  Equipo: ${host}  (IP Tailscale: ${ip:-?})
  SSH   : ssh ${WS_USER}@${host}
  Mosh  : mosh -p 60000:60010 ${WS_USER}@${host}
  Web   : http://${host}:3000  |  http://${host}:5173   (el dev server debe escuchar en 0.0.0.0)
  BD local : dentro del workspace -> devdb start (PostgreSQL) | devdb start redis | devdb enable (autoarranque)
  Extra    : ${profiles:-ninguno}   (mssql = SQL Server en contenedor aparte)
  GitHub   : dentro del workspace ejecuta  gh auth login  (queda guardado en el volumen)
  Diagnóstico: ./setup.sh doctor   |   Estado Tailscale: ./setup.sh ts-status
  Instancias : aiws ls  (gestiona todas desde el servidor)   |   Ayuda: aiws help
EOF
  others="$(other_instances | tr '\n' ' ')"
  if [[ -n "${others// /}" ]]; then
    warn "Hay otras instancias en este servidor: ${others}"
    warn "MEM_LIMIT ($(env_get MEM_LIMIT || true)) y CPUS de cada instancia se suman: revisa que el total quepa en el servidor."
  fi
}
