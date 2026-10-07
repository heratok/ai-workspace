#!/usr/bin/env bash
# Descarga un instalador (script) y lo imprime por la salida estándar.
# Uso en el build: fetch-script.sh URL | bash
#
# Por qué existe: algún CDN responde a ciertos clientes (p. ej. los runners de CI) con el
# cuerpo en gzip sin avisarlo en las cabeceras, y "curl | bash" revienta con un "syntax
# error" ilegible. Aquí se reintenta, se descomprime si llega gzip y se exige un shebang;
# si no es un script, se explica qué llegó.
set -Eeuo pipefail

url="${1:?uso: fetch-script.sh URL}"
delay="${FETCH_RETRY_DELAY:-2}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

hex2() { head -c2 "$1" | od -An -tx1 | tr -d ' \n'; }

for attempt in 1 2 3; do
  if curl -fsSL --retry 2 --compressed -D "$tmp/headers" -o "$tmp/body" "$url"; then
    if [[ "$(hex2 "$tmp/body")" == "1f8b" ]]; then
      if gunzip -c "$tmp/body" > "$tmp/plain" 2>/dev/null; then mv "$tmp/plain" "$tmp/body"; fi
    fi
    if [[ "$(hex2 "$tmp/body")" == "2321" ]]; then
      cat "$tmp/body"
      exit 0
    fi
    echo "[fetch-script] intento $attempt: la respuesta de $url no es un script" >&2
  else
    echo "[fetch-script] intento $attempt: falló la descarga de $url" >&2
  fi
  if (( attempt < 3 )); then sleep $((attempt * delay)); fi
done

{
  echo "[fetch-script] $url no devolvió un script (no es un script tras 3 intentos)."
  if [[ -s "$tmp/body" ]]; then
    echo "  primeros bytes (hex): $(head -c16 "$tmp/body" | od -An -tx1 | tr -d ' \n')"
    echo "  tamaño: $(wc -c < "$tmp/body") bytes"
  fi
  if [[ -s "$tmp/headers" ]]; then
    echo "  cabeceras de la última respuesta:"
    tr -d '\r' < "$tmp/headers" | grep -iE '^(HTTP|content-type|content-encoding|content-length|server|age|via|x-cache|cf-ray)' | sed 's/^/    /' || true
  fi
} >&2
exit 1
