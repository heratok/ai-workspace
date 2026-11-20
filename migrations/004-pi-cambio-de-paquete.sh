# shellcheck shell=bash
# Pi se publica ahora como @earendil-works/pi-coding-agent; @mariozechner/pi-coding-agent quedó deprecado en 0.73.1.
# El paquete nuevo empieza en 0.74.0, así que un PI_VERSION anterior en el .env rompería el build ("No matching
# version"). Aquí se quita ese valor para que la imagen use la versión del repo. Idempotente.
# Las versiones 0.74.0 o superiores existen en el paquete nuevo y se conservan.

if [[ -f "$ENV_FILE" ]]; then
  cur="$(env_get PI_VERSION)"
  if [[ "$cur" =~ ^v?0\.([0-9]+)\.[0-9]+$ ]] && (( BASH_REMATCH[1] < 74 )); then
    env_del PI_VERSION
    info "  .env: quité PI_VERSION=$cur (solo existe en el paquete viejo; Pi ahora es @earendil-works/pi-coding-agent)"
  fi
fi
