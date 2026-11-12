# shellcheck shell=bash
# lib/image.sh - de dónde sale la imagen: la publicada en GHCR o un build en el servidor.
# Se carga con "source" desde setup.sh; no se ejecuta solo.
#
# El CI publica en GHCR (paquete público) la imagen que pasó escaneos y pruebas, etiquetada con el hash
# del contexto de build (scripts/image-tag.sh). Un servidor la descarga si usa la configuración por defecto:
# AIWS_IMAGE_SOURCE=auto, arquitectura amd64, carpeta con git, sin ediciones locales en el contexto de build
# y con todas las variables de build del .env iguales a los valores por defecto de docker-compose.yml.
# En cualquier otro caso construye localmente, como siempre. Los volúmenes no dependen de esto.

IMAGE_REPO="${AIWS_IMAGE_REPO:-ghcr.io/heratok/ai-workspace}"
IMAGE_TAG_SCRIPT="$SCRIPT_DIR/scripts/image-tag.sh"

host_arch() { uname -m; }

# image_tag [commit]: etiqueta en GHCR de la imagen de ese commit (por defecto, HEAD)
image_tag() { bash "$IMAGE_TAG_SCRIPT" "$@"; }

# Variables de build del .env distintas del valor por defecto del compose (una por línea).
# Vacía equivale al defecto, igual que ${VAR:-defecto} en compose; las comillas no cuentan.
image_custom_args() {
  local line key def val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]+([A-Z0-9_]+):\ \$\{([A-Z0-9_]+):-([^}]*)\} ]] || continue
    key="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[3]}"
    val="$(env_get "$key")"
    val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
    [[ -z "$val" || "$val" == "$def" ]] || echo "$key"
  done < <(sed -n '/^  ai-workspace:/,/^    image:/p' "$SCRIPT_DIR/docker-compose.yml")
}

# Imprime "ghcr" o "build <motivo>"
image_source() {
  local mode; mode="$(env_get AIWS_IMAGE_SOURCE)"
  case "${mode:-auto}" in
    auto) ;;
    build) echo "build AIWS_IMAGE_SOURCE=build en .env"; return 0 ;;
    *) die "AIWS_IMAGE_SOURCE='$mode' no es válido en .env (usa auto o build)." ;;
  esac
  local arch; arch="$(host_arch)"
  [[ "$arch" == x86_64 ]] || { echo "build arquitectura $arch (GHCR solo publica amd64)"; return 0; }
  [[ -d "$SCRIPT_DIR/.git" ]] && image_tag >/dev/null 2>&1 || { echo "build carpeta sin historial de git"; return 0; }
  local custom; custom="$(image_custom_args | tr '\n' ' ')"
  [[ -z "$custom" ]] || { echo "build configuración propia en .env: ${custom% }"; return 0; }
  local -a paths; mapfile -t paths < <(image_tag --paths)
  [[ -z "$(g status --porcelain -- "${paths[@]}")" ]] || { echo "build cambios locales en ${paths[*]}"; return 0; }
  echo ghcr
}

# Si la imagen sale de GHCR, la de <commit> tiene que estar publicada antes de cambiar nada.
# Sin publicar: el CI de esa versión no terminó o falló.
image_check_published() {
  [[ "$(image_source)" == ghcr ]] || return 0
  local tag; tag="$(image_tag "$1" 2>/dev/null)" || return 0
  docker manifest inspect "$IMAGE_REPO:$tag" >/dev/null 2>&1 && return 0
  warn "La imagen de esa versión ($IMAGE_REPO:$tag) todavía no está publicada: el CI no terminó o falló."
  warn "No se cambió nada. Reintenta cuando el CI esté en verde, o construye en el servidor con AIWS_IMAGE_SOURCE=build en .env."
  return 1
}

# Descarga la imagen de HEAD y la deja con el nombre local de la instancia ($IMAGE)
image_pull() {
  local ref; ref="$IMAGE_REPO:$(image_tag)"
  info "Descargando la imagen publicada por el CI: $ref"
  docker pull "$ref" || die "No se pudo descargar $ref (el CI de esta versión no terminó o falló). El contenedor actual sigue igual. Reintenta con ./setup.sh update cuando el CI esté en verde, o construye en el servidor con AIWS_IMAGE_SOURCE=build en .env."
  docker tag "$ref" "$IMAGE"
}

# Borra las etiquetas de GHCR distintas de la actual (cada una ocupa varios GB).
# Si otra instancia usa esa imagen, solo se quita la etiqueta: su $IMAGE la sigue reteniendo.
image_clean_old() {
  local cur ref; cur="$IMAGE_REPO:$(image_tag 2>/dev/null || true)"
  while IFS= read -r ref; do
    [[ -n "$ref" && "$ref" != "$cur" && "$ref" != *:"<none>" ]] || continue
    docker image rm "$ref" >/dev/null 2>&1 && echo "    borrada: $ref" || true
  done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "$IMAGE_REPO" 2>/dev/null || true)
}
