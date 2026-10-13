# shellcheck shell=bash
# Las versiones fijadas de las herramientas ya no se copian al .env (van comentadas en env.example): un .env que las
# trae congela el servidor y nunca recibe los cambios del repo en "upgrade". Aquí se quitan las que valen lo mismo
# que el valor por defecto del repo; las distintas se conservan (pueden ser una elección tuya, o de un repo anterior)
# y se avisa. Idempotente. "./setup.sh tools" las vuelve a escribir solo cuando eliges una.

PIN_KEYS=(CLAUDE_CODE_VERSION PI_VERSION OPENCODE_VERSION PLAYWRIGHT_VERSION PLAYWRIGHT_CLI_VERSION PLAYWRIGHT_MCP_VERSION
          UV_VERSION MISE_VERSION TS_IMAGE_TAG GENTLE_AI_VERSION DOPPLER_VERSION)
HERDR_KEYS=(HERDR_VERSION HERDR_SHA256_AMD64 HERDR_SHA256_ARM64)

former_default() {   # valores por defecto ANTERIORES del repo (no eran una elección del usuario; se quitan igual)
  case "$1" in TS_IMAGE_TAG) echo stable ;; esac
}

pin_repo_default() {   # valor por defecto del repo: ARG del Dockerfile o, si no hay, el valor por defecto en docker-compose.yml
  local k="$1" v
  v="$(sed -n -E "s/^ARG $k=\"?([^\" ]*)\"?.*/\1/p" "$SCRIPT_DIR/Dockerfile" | head -n1)"
  if [[ -z "$v" ]]; then
    v="$(grep -oE "\\\$\{$k:-[^}]*\}" "$SCRIPT_DIR/docker-compose.yml" | head -n1 | sed -E 's/^\$\{[A-Z0-9_]+:-//; s/\}$//')"
  fi
  echo "$v"
}

if [[ -f "$ENV_FILE" ]]; then
  removed=0
  for k in "${PIN_KEYS[@]}"; do
    cur="$(env_get "$k")"; [[ -n "$cur" ]] || continue
    if [[ "$cur" == "$(pin_repo_default "$k")" || "$cur" == "$(former_default "$k")" ]]; then
      env_del "$k"; removed=$((removed + 1))
    else
      warn "  .env conserva $k=$cur (distinta de la del repo: $(pin_repo_default "$k")). Si no la elegiste tú: ./setup.sh tools --reset"
    fi
  done
  # Herdr: la versión y sus dos checksums van siempre juntos (si la versión es la del repo, se quita el grupo entero)
  cur="$(env_get HERDR_VERSION)"
  if [[ -n "$cur" ]]; then
    if [[ "$cur" == "$(pin_repo_default HERDR_VERSION)" ]]; then
      for k in "${HERDR_KEYS[@]}"; do [[ -n "$(env_get "$k")" ]] && removed=$((removed + 1)); env_del "$k"; done
    else
      warn "  .env conserva HERDR_VERSION=$cur con sus checksums (distinta de la del repo). Si no la elegiste tú: ./setup.sh tools --reset"
    fi
  fi
  if (( removed > 0 )); then info "  .env: quité $removed versión(es) fijada(s) que coincidían con el repo (el repo manda; otra versión: ./setup.sh tools)"; fi
fi
