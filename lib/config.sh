# shellcheck shell=bash
# lib/config.sh - .env, secretos y volúmenes
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# --------------------------------------------------------------- configuración
gen_secret() { od -An -tx1 -N20 /dev/urandom | tr -d ' \n'; }

profile_on() { [[ ",$(env_get COMPOSE_PROFILES)," == *",$1,"* ]]; }

# Contraseñas de servicios: se generan una sola vez y quedan en .env (600)
ensure_secrets() {
  if [[ -z "$(env_get MSSQL_SA_PASSWORD)" ]]; then
    env_set MSSQL_SA_PASSWORD "Ws1-$(gen_secret)"   # SQL Server exige mayúscula, número y símbolo
  fi
  return 0
}

# ¿El nodo ya tiene identidad guardada? (volumen con estado de Tailscale)
ts_logged_in_before() {
  docker volume inspect "$TS_VOLUME" >/dev/null 2>&1 || return 1
  local tag; tag="$(env_get TS_IMAGE_TAG)"
  docker run --rm --entrypoint sh -v "$TS_VOLUME:/s:ro" "tailscale/tailscale:${tag:-stable}" \
    -c 'test -s /s/tailscaled.state' >/dev/null 2>&1
}

configure_env() {
  local authkey="${1:-}" is_new=false

  if [[ ! -f "$ENV_FILE" ]]; then
    is_new=true
    [[ -f "$ENV_EXAMPLE" ]] || die "Falta env.example"
    cp "$ENV_EXAMPLE" "$ENV_FILE"; chmod 600 "$ENV_FILE"
    info ".env creado desde env.example"
    if has_tty; then
      local mode; read -rp "¿Instalación completa (recomendada) o personalizada? [C/p]: " mode || true
      if [[ "$mode" =~ ^[pP] ]]; then choose_components || true; fi
    fi
  fi

  write_instance_env
  size_resources "$is_new"
  [[ -n "$authkey" ]] && env_set TS_AUTHKEY "$authkey"

  if ! ts_logged_in_before && [[ -z "$(env_get TS_AUTHKEY)" ]]; then
    cat <<EOF

${c_ok}Conexión a Tailscale (solo esta vez):${c_off}
  - Pega tu auth key (tskey-auth-...) y presiona Enter, o
  - Presiona Enter sin pegar nada para iniciar sesión con un link en el navegador.
EOF
    read -rsp "Auth key (oculta): " authkey || true; echo
    authkey="$(echo -n "$authkey" | tr -d '[:space:]')"
    if [[ -n "$authkey" ]]; then env_set TS_AUTHKEY "$authkey"
    else info "Sin auth key: se mostrará un link de inicio de sesión."; fi
  fi

  local key; key="$(env_get TS_AUTHKEY)"
  if [[ -n "$key" && "$key" != tskey-* ]]; then
    env_set TS_AUTHKEY ""
    die "TS_AUTHKEY no parece válida (debe empezar con 'tskey-'). Ejecuta install de nuevo."
  fi
  ensure_secrets
  info "Configuración lista en .env (instancia $AIWS_NAME, TS_HOSTNAME=$(env_get TS_HOSTNAME), servicios: $(env_get COMPOSE_PROFILES))"
}

create_volumes() {
  local v
  for v in "${VOLUMES[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      info "Volumen $v ya existe (se conserva)"
    else
      docker volume create "$v" >/dev/null && info "Volumen $v creado"
    fi
  done
}
