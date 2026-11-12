#!/usr/bin/env bash
# =============================================================================
# image-tag.sh - etiqueta de la imagen en GHCR: hash del contexto de build en un commit
#
#   scripts/image-tag.sh [commit]   Imprime ctx-<12 hex> (por defecto, de HEAD)
#   scripts/image-tag.sh --paths    Lista las rutas que forman el contexto (una por línea)
#
# La usan el CI (al publicar) y setup.sh (al descargar), así ambos calculan siempre la misma.
# Solo cuenta lo que entra en la imagen (.dockerignore): un commit de docs reutiliza la imagen
# ya publicada y la etiqueta de una versión anterior se calcula sin hacer checkout (rollback).
# Ediciones sin commit no cambian la etiqueta: setup.sh las detecta y construye local.
# =============================================================================
set -Eeuo pipefail

CONTEXT_PATHS=(.dockerignore Dockerfile entrypoint.sh config)

if [[ "${1:-}" == --paths ]]; then printf '%s\n' "${CONTEXT_PATHS[@]}"; exit 0; fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
rev="${1:-HEAD}"
tree="$(git -c safe.directory="$PWD" ls-tree -r "$rev" -- "${CONTEXT_PATHS[@]}")"
[[ -n "$tree" ]] || { echo "image-tag: $rev no tiene contexto de build (${CONTEXT_PATHS[*]})" >&2; exit 1; }
hash="$(git hash-object --stdin <<< "$tree")"
echo "ctx-${hash:0:12}"
