# shellcheck shell=bash
# Asserts compartidos de todas las pruebas de tests/*.test.sh.
# Se carga con source DESPUÉS de crear $TMP: prepara los contadores $PASSES y $FAILS (un archivo por
# contador, porque cada prueba corre en un subshell y las variables no vuelven al padre).

PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }

# Texto largo (un ci.yml entero, la salida de un comando) recortado en los mensajes de fallo
_assert_clip() { local s="$1"; (( ${#s} > 400 )) && s="${s:0:400}... (recortado)"; printf '%s' "$s"; }

assert_eq()    { if [[ "$2" == "$3" ]]; then ok; else nok "$1: esperado '$2', obtenido '$3'"; fi; return 0; }
assert_has()   { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3' en: $(_assert_clip "$2")"; fi; return 0; }
assert_lacks() { if [[ "$2" != *"$3"* ]]; then ok; else nok "$1: NO debía contener '$3' en: $(_assert_clip "$2")"; fi; return 0; }
assert_match() { if [[ "$2" =~ $3 ]]; then ok; else nok "$1: '$2' no cumple $3"; fi; return 0; }
assert_file()  { if [[ -f "$2" ]]; then ok; else nok "$1: no existe el archivo $2"; fi; return 0; }
assert_ok()    { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then ok; else nok "$n: debía tener éxito: $*"; fi; return 0; }
assert_fail()  { local n="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then nok "$n: debía fallar: $*"; else ok; fi; return 0; }

# run <función>: la ejecuta en un subshell; si termina con error (set -e, exit) cuenta como fallo
run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}
