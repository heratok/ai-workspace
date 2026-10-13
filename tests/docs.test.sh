#!/usr/bin/env bash
# =============================================================================
# Pruebas de la documentación: README corto + docs/ con enlaces que no se rompen.
#
#   bash tests/docs.test.sh
#
# Estáticas (sin Docker ni red). Usa perl solo para el "slug" de los títulos
# (minúsculas y signos según las reglas de GitHub, con letras Unicode).
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$ROOT/README.md"
DOCS="$ROOT/docs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

DOC_FILES=(instancias configuracion operacion herramientas solucion-de-problemas desarrollo)
MD_FILES() { echo "$README"; local d; for d in "${DOC_FILES[@]}"; do echo "$DOCS/$d.md"; done; }

# slugs de GitHub de todos los títulos de un archivo (un solo perl por archivo; ignora bloques de código)
# minúsculas, sin signos (salvo - y _), espacios -> guiones; el resultado se guarda en caché
anchors_of() {
  local f="$1" c; c="$TMP/anchors.$(echo "$1" | tr "/:\\" "___")"
  [[ -f "$c" ]] || awk '/^```/ {c = !c; next} !c && /^#{1,6} / {sub(/^#+ +/, ""); print}' "$f" \
    | perl -CSD -Mutf8 -ne 's/`//g; $_ = lc; s/[^\p{L}\p{N} _\n-]//g; s/ /-/g; print' > "$c"
  cat "$c"
}

t_readme_is_short() {
  local n; n="$(wc -l < "$README")"
  (( n <= 170 )) && ok || nok "README.md tiene $n líneas (máximo 170: el resto va en docs/)"
}

t_every_doc_exists_and_is_linked_from_readme() {
  local d
  for d in "${DOC_FILES[@]}"; do
    [[ -s "$DOCS/$d.md" ]] && ok || nok "falta docs/$d.md"
    grep -q "docs/$d.md" "$README" && ok || nok "el README no enlaza docs/$d.md"
  done
}

t_every_doc_links_back_to_the_readme() {
  local d
  for d in "${DOC_FILES[@]}"; do
    [[ -f "$DOCS/$d.md" ]] || { nok "falta docs/$d.md"; continue; }
    grep -q '](../README.md)' "$DOCS/$d.md" && ok || nok "docs/$d.md no enlaza de vuelta al README"
  done
}

t_all_relative_links_and_anchors_resolve() {
  local f dir link path anchor target n=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    dir="$(dirname "$f")"
    while IFS= read -r link; do
      n=$((n + 1))
      path="${link%%#*}"; anchor=""; [[ "$link" == *"#"* ]] && anchor="${link#*#}"
      if [[ -z "$path" ]]; then target="$f"; else target="$dir/$path"; fi
      if [[ ! -e "$target" ]]; then nok "$(basename "$f"): enlace roto a '$link'"; continue; fi
      if [[ -n "$anchor" && -f "$target" && "$target" == *.md ]]; then
        anchors_of "$target" | grep -qxF -- "$anchor" && ok || nok "$(basename "$f"): el ancla '#$anchor' no existe en $(basename "$target")"
      else ok; fi
    done < <(awk '/^```/ {c = !c; next} !c' "$f" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(https?:|mailto:)')
  done < <(MD_FILES)
  (( n > 20 )) && ok || nok "se comprobaron solo $n enlaces: ¿se movió el contenido?"
}

t_key_sections_survive_the_split() {
  local h all; all="$(cat "$README" "$DOCS"/*.md 2>/dev/null)"
  for h in '## Inicio rápido' '## Requisitos y Tailscale' '## Varias instancias en un servidor' '## Gestionar instancias con aiws' \
           '### Variables del `.env`' '### Recursos por instancia' '### Componentes' '### Comandos de `setup.sh`' \
           '### Actualizar a la última versión' '## Qué trae la imagen' '## Bases de datos dentro del workspace' \
           '### Login OAuth con callback en localhost' '## Solución de problemas' '## Verificación automática (CI)' '## Migración desde v1'; do
    grep -qF -- "$h" <<< "$all" && ok || nok "se perdió la sección '$h'"
  done
}

t_code_points_to_the_new_config_doc() {
  grep -q 'docs/configuracion.md' "$ROOT/docker-compose.yml" && ok || nok "docker-compose.yml debe apuntar a docs/configuracion.md"
  grep -q 'docs/configuracion.md' "$ROOT/setup.sh" && ok || nok "setup.sh debe apuntar a docs/configuracion.md"
}

for t in t_readme_is_short t_every_doc_exists_and_is_linked_from_readme t_every_doc_links_back_to_the_readme \
         t_all_relative_links_and_anchors_resolve t_key_sections_survive_the_split t_code_points_to_the_new_config_doc; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
