#!/usr/bin/env bash
# =============================================================================
# Corre todas las pruebas de tests/*.test.sh, una tras otra, y falla si alguna falla.
#
#   bash tests/run-all.sh
#
# El CI no lo usa (cada prueba tiene su propio paso, con su nombre y su timeout); es para correr
# todo en local antes de un push. AIWS_TESTS_DIR cambia la carpeta (lo usan las pruebas de este script).
# =============================================================================
set -u

DIR="${AIWS_TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
passed=0; failed=()

for t in "$DIR"/*.test.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  echo "### $name"
  if bash "$t"; then passed=$((passed + 1)); else failed+=("$name"); fi
done

echo
echo "Pruebas: $passed ok, ${#failed[@]} fallidos"
if (( ${#failed[@]} > 0 )); then
  printf '  FALLÓ: %s\n' "${failed[@]}" >&2
  exit 1
fi
