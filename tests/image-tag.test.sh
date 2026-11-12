#!/usr/bin/env bash
# =============================================================================
# Pruebas de scripts/image-tag.sh (etiqueta de la imagen en GHCR = hash del contexto de build).
#
#   bash tests/image-tag.test.sh
#
# Sin red ni Docker: cada prueba arma un repositorio git temporal con una copia del script.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/image-tag.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

# mk_repo: repo con el contexto de build y otros archivos; deja el primer commit en C1
mk_repo() {
  R="$TMP/repo.$RANDOM"; mkdir -p "$R/scripts" "$R/config" "$R/docs" "$R/landing"
  git -C "$R" init -q
  git -C "$R" config user.name ci; git -C "$R" config user.email ci@example.invalid; git -C "$R" config core.autocrlf false
  cp "$SCRIPT" "$R/scripts/image-tag.sh"
  local f; for f in Dockerfile .dockerignore entrypoint.sh config/zshrc docs/uso.md README.md docker-compose.yml landing/x.astro; do echo base > "$R/$f"; done
  git -C "$R" add -A; git -C "$R" commit -qm base
  C1="$(tag)"
}
commit_change() { local f; for f in "$@"; do mkdir -p "$(dirname "$R/$f")"; echo cambio >> "$R/$f"; done; git -C "$R" add -A; git -C "$R" commit -qm cambio; }
tag() { bash "$R/scripts/image-tag.sh" "$@"; }

t_tag_format() {
  mk_repo
  assert_match "formato" "$C1" '^ctx-[0-9a-f]{12}$'
}

t_changes_outside_the_context_keep_the_tag() {   # un commit de docs reutiliza la imagen ya publicada
  mk_repo
  commit_change docs/uso.md README.md docker-compose.yml landing/x.astro scripts/otro.sh
  assert_eq "mismo tag" "$C1" "$(tag)"
}

t_each_context_file_changes_the_tag() {
  local f
  for f in Dockerfile .dockerignore entrypoint.sh config/zshrc config/nuevo.conf; do
    mk_repo
    commit_change "$f"
    [[ "$(tag)" != "$C1" ]] && ok || nok "$f no cambió el tag"
  done
}

t_tag_of_a_previous_commit() {   # rollback: el tag de la versión anterior se calcula sin hacer checkout
  mk_repo
  local first; first="$(git -C "$R" rev-parse HEAD)"
  commit_change Dockerfile
  assert_eq "tag de HEAD~1" "$C1" "$(tag "$first")"
}

t_uncommitted_edits_do_not_change_the_tag() {   # el tag describe el commit; las ediciones locales las detecta setup.sh
  mk_repo
  echo local >> "$R/config/zshrc"
  assert_eq "mismo tag" "$C1" "$(tag)"
}

t_fails_outside_git() {
  local d="$TMP/nogit.$RANDOM"; mkdir -p "$d/scripts"; cp "$SCRIPT" "$d/scripts/"
  if bash "$d/scripts/image-tag.sh" >/dev/null 2>&1; then nok "debía fallar sin git"; else ok; fi
}

t_paths_match_dockerignore() {   # el contexto de build lo define .dockerignore: si cambia, el tag debe seguirlo
  local want got
  # .dockerignore no entra en la imagen, pero decide qué entra: también forma parte del hash
  want="$({ echo .dockerignore; sed -n -E 's#^!([^*]+)$#\1#p' "$ROOT/.dockerignore" | sed 's#/$##'; } | sort -u | tr '\n' ' ')"
  got="$(bash "$SCRIPT" --paths | sort -u | tr '\n' ' ')"
  assert_eq "rutas del contexto" "$want" "$got"
}

for t in t_tag_format t_changes_outside_the_context_keep_the_tag t_each_context_file_changes_the_tag \
         t_tag_of_a_previous_commit t_uncommitted_edits_do_not_change_the_tag t_fails_outside_git t_paths_match_dockerignore; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
