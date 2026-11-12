#!/usr/bin/env bash
# =============================================================================
# ci-changes.sh - decide qué jobs pesados del CI hacen falta según los archivos cambiados
#
#   scripts/ci-changes.sh <evento> <sha-base> <sha-head>   (lo usa el job "changes" de ci.yml)
#
# Imprime dos líneas para $GITHUB_OUTPUT:
#   image=true|false     construir, escanear y probar la imagen (job build)
#   landing=true|false   compilar y auditar la landing (job landing)
#
# Ante la duda, todo en true: schedule y workflow_dispatch, base vacía o en ceros (rama nueva),
# base que no está en la historia (force push) o un git diff que falla.
# Un cambio en ci.yml o en este script también activa todo: el filtro se valida a sí mismo.
# =============================================================================
set -Euo pipefail

event="${1:-}" base="${2:-}" head="${3:-}"

all() { printf 'image=true\nlanding=true\n'; exit 0; }

[[ "$event" == pull_request || "$event" == push ]] || all
[[ -n "$base" && -n "$head" && ! "$base" =~ ^0+$ ]] || all
git cat-file -e "${base}^{commit}" 2>/dev/null || all
files="$(git diff --name-only "$base" "$head" 2>/dev/null)" || all

image=false landing=false
while IFS= read -r f; do
  case "$f" in
    .github/workflows/ci.yml|scripts/ci-changes.sh) all ;;
    # Contexto del build (.dockerignore) más lo que prueba la imagen en un contenedor real
    Dockerfile|.dockerignore|entrypoint.sh|config/*|docker-compose.yml|tests/entrypoint.test.sh|tests/helpers/*) image=true ;;
    landing/*) landing=true ;;
  esac
done <<< "$files"

printf 'image=%s\nlanding=%s\n' "$image" "$landing"
