#!/usr/bin/env bash
# =============================================================================
# update-pins.sh - busca, lista, elige y fija las versiones de las herramientas de la imagen
#
#   scripts/update-pins.sh [--target repo|env] check [--tsv]      Compara lo fijado con lo último de cada herramienta
#   scripts/update-pins.sh [--target repo|env] list [herramienta|all] [N]   Últimas N (por defecto 5) versiones estables
#   scripts/update-pins.sh [--target repo|env] choose <herramienta>         Muestra las últimas 5 y te deja elegir
#   scripts/update-pins.sh [--target repo|env] set <herramienta> <versión|latest>   Fija esa versión
#   scripts/update-pins.sh [--target repo|env] latest [herramienta|all]     Fija la última estable, sin preguntar
#   scripts/update-pins.sh --target env reset                     Quita del .env todas las versiones fijadas
#
# Herramientas: claude-code pi opencode playwright playwright-cli playwright-mcp (npm), uv mise tailscale
# herdr gentle-ai doppler (releases de GitHub). agy NO se fija: siempre instala la última al construir.
#
# --target repo (por defecto, para mantenedores): reescribe Dockerfile, docker-compose.yml y env.example.
# --target env  (lo usa "./setup.sh tools" en el servidor): escribe SOLO en el .env, sin tocar archivos del
#   repo (así "upgrade" no ve cambios locales) y omite los componentes desactivados (INSTALL_*=false).
# Para Herdr toma el SHA256 de cada binario de linux (GitHub lo publica como "digest"); Gentle AI y Doppler
# se verifican en el build con el checksums.txt de su release. Si algo falla no se toca ningún archivo.
# Solo usa bash, curl, grep, sed y awk (el servidor únicamente garantiza Docker, git y curl: nada de perl ni jq;
# en Oracle Linux, por ejemplo, perl existe pero no trae JSON::PP).
# Variables: GITHUB_TOKEN (opcional, sube el límite de la API), PINS_ROOT, PINS_ENV y PINS_FETCH (pruebas).
# =============================================================================
set -Eeuo pipefail

ROOT="${PINS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${PINS_ENV:-$ROOT/.env}"
TARGET=repo
DEFAULT_COUNT=5
TOOLS=(claude-code pi opencode playwright playwright-cli playwright-mcp uv mise tailscale herdr gentle-ai doppler)
HERDR_SHA_KEYS=(HERDR_SHA256_AMD64 HERDR_SHA256_ARM64)

die()  { echo "[error] $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { awk 'NR >= 3 { if ($0 ~ /^# =+$/) exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- registro de herramientas
# tipo|nombre|CLAVE|origen|prefijo del tag|prefijo del valor|¿ARG en Dockerfile?|INSTALL_* que la activa
tool_spec() {
  case "$1" in
    claude-code)    echo "npm|Claude Code|CLAUDE_CODE_VERSION|@anthropic-ai/claude-code|||1|INSTALL_CLAUDE" ;;
    pi)             echo "npm|Pi|PI_VERSION|@mariozechner/pi-coding-agent|||1|INSTALL_PI" ;;
    opencode)       echo "npm|opencode|OPENCODE_VERSION|opencode-ai|||1|INSTALL_OPENCODE" ;;
    playwright)     echo "npm|Playwright|PLAYWRIGHT_VERSION|playwright|||1|INSTALL_PLAYWRIGHT" ;;
    playwright-cli) echo "npm|Playwright CLI|PLAYWRIGHT_CLI_VERSION|@playwright/cli|||1|INSTALL_PLAYWRIGHT" ;;
    playwright-mcp) echo "npm|Playwright MCP|PLAYWRIGHT_MCP_VERSION|@playwright/mcp|||1|INSTALL_PLAYWRIGHT" ;;
    uv)             echo "gh|uv|UV_VERSION|astral-sh/uv|||1|" ;;
    mise)           echo "gh|mise|MISE_VERSION|jdx/mise|v|v|1|" ;;
    tailscale)      echo "gh|Tailscale|TS_IMAGE_TAG|tailscale/tailscale|v|v|0|" ;;
    herdr)          echo "gh|Herdr|HERDR_VERSION|herdrdev/herdr|v||1|INSTALL_HERDR" ;;
    gentle-ai)      echo "gh|Gentle AI|GENTLE_AI_VERSION|Gentleman-Programming/gentle-ai|v||1|INSTALL_GENTLE_AI" ;;
    doppler)        echo "gh|Doppler|DOPPLER_VERSION|DopplerHQ/cli|||1|INSTALL_DOPPLER" ;;
    agy)            die "agy no se fija: siempre instala la última al construir (Google no lista versiones ni da URLs predecibles). ./setup.sh update la renueva." ;;
    *) die "Herramienta desconocida: $1 (usa: ${TOOLS[*]})" ;;
  esac
}
# Carga los campos de una herramienta en S_KIND S_LABEL S_KEY S_SRC S_TAGP S_VALP S_INDF S_FLAG
load_spec() { IFS='|' read -r S_KIND S_LABEL S_KEY S_SRC S_TAGP S_VALP S_INDF S_FLAG <<< "$(tool_spec "$1")"; }

# ---------------------------------------------------------------- red
fetch() {   # fetch <url> [accept]
  local url="$1" accept="${2:-application/vnd.github+json}"
  if [[ -n "${PINS_FETCH:-}" ]]; then "$PINS_FETCH" "$url" "$accept"; return; fi
  local -a auth=(); [[ "$url" == https://api.github.com/* && -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 -H "Accept: $accept" "${auth[@]}" "$url"
}
npm_url() { echo "https://registry.npmjs.org/${1//\//%2F}"; }

# ---------------------------------------------------------------- JSON mínimo (grep + awk, sin perl ni jq)
# Las respuestas de GitHub y npm son JSON estándar y sus textos libres escapan las comillas (\"), así que un patrón con
# comillas SIN escapar como "tag_name":"..." solo puede ser una clave real. Se extraen los pares clave:valor que interesan,
# en orden de aparición, y se agrupan con awk.
json_pairs() {   # json_pairs <claves separadas por |>: stdin = JSON, stdout = una línea "clave:valor" por aparición
  grep -oE "\"($1)\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false|null)" || true
}
sort_versions_desc() { sort -t. -k1,1nr -k2,2nr -k3,3nr; }   # versiones x.y.z (puede haber una columna extra tras un TAB)

# "versión<TAB>fecha" de las releases estables (<prefijo>x.y.z, sin prerelease/draft), la más nueva primero
gh_versions() {   # gh_versions <owner/repo> <prefijo-de-tag> <N>
  local body; body="$(fetch "https://api.github.com/repos/$1/releases?per_page=30")" || die "No pude consultar las releases de $1 en GitHub."
  printf '%s' "$body" | json_pairs 'tag_name|draft|prerelease|published_at' | awk -F'"' -v p="$2" '
    function flush() {
      if (tag != "" && !draft && !pre && tag ~ ("^" p "[0-9]+[.][0-9]+[.][0-9]+$")) print substr(tag, length(p) + 1) "\t" substr(date, 1, 10)
    }
    { key = $2; v3 = $3; sub(/^[[:space:]]*:[[:space:]]*/, "", v3); val = (v3 ~ /^(true|false|null)$/) ? v3 : $4 }
    key == "tag_name"     { flush(); tag = val; draft = 0; pre = 0; date = "" }
    key == "draft"        { draft = (val == "true") }
    key == "prerelease"   { pre = (val == "true") }
    key == "published_at" { date = val }
    END { flush() }
  ' | sort_versions_desc | head -n "$3"
}
npm_versions() {   # npm_versions <paquete> <N>
  local body; body="$(fetch "$(npm_url "$1")" "application/vnd.npm.install-v1+json")" || die "No pude consultar $1 en el registro de npm."
  # cada versión del documento abreviado empieza con {"name":"<paquete>","version":"x.y.z" (las prerelease no encajan: x.y.z-beta)
  printf '%s' "$body" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"[[:space:]]*,[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
    | sort -u | sort_versions_desc | awk '{ print $0 "\t" }' | head -n "$2"
}
versions_of() {   # versions_of <id> <N>
  load_spec "$1"
  if [[ "$S_KIND" == npm ]]; then npm_versions "$S_SRC" "$2"; else gh_versions "$S_SRC" "$S_TAGP" "$2"; fi
}
latest_of() {   # versión estable más nueva (sin prefijos), o falla
  load_spec "$1"
  local v
  if [[ "$S_KIND" == npm ]]; then
    v="$(fetch "$(npm_url "$S_SRC")/latest" application/json | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/')" || return 1
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  else
    v="$(gh_versions "$S_SRC" "$S_TAGP" 1 | cut -f1)" || return 1
    [[ -n "$v" ]] || return 1
  fi
  echo "$v"
}

# ---------------------------------------------------------------- lo fijado hoy
dockerfile_arg()   { sed -n -E "s/^ARG $1=\"?([^\" ]*)\"?.*/\1/p" "$ROOT/Dockerfile" | head -n1; }
compose_default()  { grep -oE "\\\$\{$1:-[^}]*\}" "$ROOT/docker-compose.yml" | head -n1 | sed -E 's/^\$\{[A-Z0-9_]+:-//; s/\}$//'; }
env_get()          { [[ -f "$ENV_FILE" ]] && sed -n -E "s/^$1=(.*)/\1/p" "$ENV_FILE" | tail -n1 || true; }
repo_value()       { if [[ "$S_INDF" == 1 ]]; then dockerfile_arg "$1"; else compose_default "$1"; fi; }

pinned_of() {   # "valor<TAB>origen" de la herramienta ya cargada con load_spec
  local v=""
  if [[ "$TARGET" == env ]]; then v="$(env_get "$S_KEY")"; fi
  if [[ -n "$v" ]]; then printf '%s\t.env\n' "$v"; else printf '%s\trepo\n' "$(repo_value "$S_KEY")"; fi
}

enabled() {   # en --target env se omiten los componentes desactivados
  load_spec "$1"
  [[ "$TARGET" == env && -n "$S_FLAG" ]] || return 0
  local f; f="$(env_get "$S_FLAG")"; [[ -n "$f" ]] || f="$(dockerfile_arg "$S_FLAG")"
  [[ "$f" == true ]]
}

# ---------------------------------------------------------------- escritura (awk; conserva permisos y dueño del archivo)
rewrite_file() {   # rewrite_file <archivo> <programa-awk> [var=valor ...]: aplica awk y vuelca el resultado SOBRE el mismo archivo
  local file="$1" prog="$2" tmp; shift 2
  tmp="$(mktemp)"
  local -a vars=(); local kv; for kv in "$@"; do vars+=(-v "$kv"); done
  if awk "${vars[@]}" "$prog" "$file" > "$tmp"; then cat "$tmp" > "$file"; rm -f "$tmp"; else rm -f "$tmp"; die "No pude reescribir $file"; fi
}
set_arg_line() {   # ARG CLAVE=valor del Dockerfile
  rewrite_file "$1" 'index($0, "ARG " k "=") == 1 { print "ARG " k "=" v; next } { print }' "k=$2" "v=$3"
}
set_compose_default() {   # cada ${CLAVE:-valor} de docker-compose.yml
  rewrite_file "$1" '
    { line = $0; out = ""; pat = "${" k ":-"
      while ((i = index(line, pat)) > 0) {
        out = out substr(line, 1, i - 1) pat v "}"
        rest = substr(line, i + length(pat)); j = index(rest, "}"); line = substr(rest, j + 1)
      }
      print out line }' "k=$2" "v=$3"
}
set_env_line() {   # CLAVE=valor, o "# CLAVE=valor" (en env.example las versiones van comentadas: se conserva el "# ")
  rewrite_file "$1" 'index($0, k "=") == 1 { print k "=" v; next } index($0, "# " k "=") == 1 { print "# " k "=" v; next } { print }' "k=$2" "v=$3"
}
drop_env_line() { rewrite_file "$1" 'index($0, k "=") != 1 { print }' "k=$2"; }

write_repo() {   # write_repo <CLAVE> <valor> <¿en Dockerfile?>
  if [[ "$3" == 1 ]]; then set_arg_line "$ROOT/Dockerfile" "$1" "$2"; fi
  set_compose_default "$ROOT/docker-compose.yml" "$1" "$2"
  set_env_line "$ROOT/env.example" "$1" "$2"
}
write_env() {   # write_env <CLAVE> <valor>: reemplaza la línea o la agrega al final
  if grep -qE "^$1=" "$ENV_FILE"; then set_env_line "$ENV_FILE" "$1" "$2"
  else
    if [[ -s "$ENV_FILE" && "$(tail -c1 "$ENV_FILE" | wc -l)" -eq 0 ]]; then echo >> "$ENV_FILE"; fi
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
}
write_pin() { if [[ "$TARGET" == env ]]; then write_env "$1" "$2"; else write_repo "$1" "$2" "${3:-1}"; fi; }

check_targets() {   # cada clave debe poder escribirse: si no, no se toca nada
  local k indf
  if [[ "$TARGET" == env ]]; then [[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE: ejecuta ./setup.sh install primero."; return 0; fi
  while (( $# )); do
    k="$1"; indf="$2"; shift 2
    if [[ "$indf" == 1 ]]; then grep -qE "^ARG $k=" "$ROOT/Dockerfile" || die "Dockerfile no tiene ARG $k"; fi
    grep -qE "\\\$\{$k:-" "$ROOT/docker-compose.yml" || die "docker-compose.yml no usa $k"
    grep -qE "^(# )?$k=" "$ROOT/env.example" || die "env.example no documenta $k"
  done
}

# ---------------------------------------------------------------- fijar una versión
herdr_digests() {   # "amd64 arm64" (sha256 de los binarios linux de esa versión)
  local body out; body="$(fetch "https://api.github.com/repos/herdrdev/herdr/releases/tags/v$1")" || die "La versión $1 de herdr no existe en GitHub."
  out="$(printf '%s' "$body" | grep -oE '"(name|digest)"[[:space:]]*:[[:space:]]*"[^"]*"' | awk -F'"' '
    $2 == "name"   { n = $4 }
    $2 == "digest" { if (n != "") d[n] = $4; n = "" }
    function ok(s) { return length(s) == 71 && s ~ /^sha256:[0-9a-f]+$/ }
    END {
      x = d["herdr-linux-x86_64"]; a = d["herdr-linux-aarch64"]
      if (ok(x) && ok(a)) print substr(x, 8), substr(a, 8); else exit 3
    }')" || die "La release $1 de herdr no trae binarios de linux con checksum publicado; no se puede fijar."
  echo "$out"
}
assert_version_exists() {   # assert_version_exists <id> <versión>
  load_spec "$1"
  local body
  if [[ "$S_KIND" == npm ]]; then
    body="$(fetch "$(npm_url "$S_SRC")" "application/vnd.npm.install-v1+json")" || die "No pude consultar $S_SRC en el registro de npm."
    printf '%s' "$body" | grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"[^\"]+\"[[:space:]]*,[[:space:]]*\"version\"[[:space:]]*:[[:space:]]*\"${2//./\\.}\"" || die "La versión $2 de $1 no existe en npm."
  else
    body="$(fetch "https://api.github.com/repos/$S_SRC/releases/tags/$S_TAGP$2")" || die "La versión $2 de $1 no existe en GitHub."
    if printf '%s' "$body" | grep -qE '"prerelease"[[:space:]]*:[[:space:]]*true'; then
      die "La versión $2 de $1 es una prerelease; elige una estable."
    fi
  fi
}
valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

set_pin() {   # set_pin <herramienta> <versión|latest>
  local id="$1" ver="${2#v}" amd="" arm=""
  load_spec "$id"
  if [[ "$2" == latest ]]; then ver="$(latest_of "$id")" || die "No pude averiguar la última versión de $id."; fi
  valid_version "$ver" || die "Versión inválida: '$2' (formato esperado: 1.2.3)"
  assert_version_exists "$id" "$ver"
  if [[ "$id" == herdr ]]; then
    read -r amd arm < <(herdr_digests "$ver")
    check_targets "$S_KEY" 1 "${HERDR_SHA_KEYS[0]}" 1 "${HERDR_SHA_KEYS[1]}" 1
    write_pin "$S_KEY" "$S_VALP$ver" "$S_INDF"; write_pin "${HERDR_SHA_KEYS[0]}" "$amd" 1; write_pin "${HERDR_SHA_KEYS[1]}" "$arm" 1
    info "herdr fijado en $ver (sha256 amd64 ${amd:0:12}…, arm64 ${arm:0:12}…)"
    return 0
  fi
  check_targets "$S_KEY" "$S_INDF"
  write_pin "$S_KEY" "$S_VALP$ver" "$S_INDF"
  info "$id fijado en $S_VALP$ver$([[ "$TARGET" == env ]] && echo ' (en el .env)')"
}

# ---------------------------------------------------------------- comandos
ver_gt() {   # ver_gt <a> <b>: ¿a > b? (x.y.z)
  awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 } exit 1 }'
}

print_list() {   # print_list <id> <N>
  local id="$1" n="$2" i=0 v d mark pin
  load_spec "$id"
  pin="$(pinned_of | cut -f1)"; pin="${pin#"$S_VALP"}"
  echo "Últimas $n versiones estables de $id:"
  while IFS=$'\t' read -r v d; do
    i=$((i + 1)); mark=""; [[ "$v" == "$pin" ]] && mark="  ← fijada"
    printf '  %d) %s%s  %s%s\n' "$i" "$S_VALP" "$v" "$d" "$mark"
  done < <(versions_of "$id" "$n")
  (( i > 0 )) || die "No encontré releases estables de $id."
}

cmd_list() {
  local tool="${1:-all}" n="${2:-$DEFAULT_COUNT}" t
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "N debe ser un número: $n"
  if [[ "$tool" == all ]]; then for t in "${TOOLS[@]}"; do if enabled "$t"; then print_list "$t" "$n"; fi; done
  else tool_spec "$tool" >/dev/null; print_list "$tool" "$n"; fi
}

cmd_choose() {
  local tool="${1:-}" choice versions
  [[ -n "$tool" ]] || die "Indica la herramienta: choose <herramienta>"
  tool_spec "$tool" >/dev/null
  versions="$(versions_of "$tool" "$DEFAULT_COUNT" | cut -f1)"
  [[ -n "$versions" ]] || die "No encontré releases estables de $tool."
  print_list "$tool" "$DEFAULT_COUNT"
  read -rp "Elige 1-$(wc -l <<< "$versions" | tr -d ' ') (Enter cancela): " choice || true
  [[ -n "$choice" ]] || { info "Cancelado; no se cambió nada."; return 0; }
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] || die "Opción inválida: $choice"
  choice="$(sed -n "${choice}p" <<< "$versions")"
  [[ -n "$choice" ]] || die "Ese número no está en la lista."
  set_pin "$tool" "$choice"
}

cmd_latest() {
  local tool="${1:-all}" t
  if [[ "$tool" != all ]]; then tool_spec "$tool" >/dev/null; set_pin "$tool" latest; return; fi
  for t in "${TOOLS[@]}"; do if enabled "$t"; then set_pin "$t" latest; fi; done
}

# Compara lo fijado con lo último. Una consulta por herramienta, en paralelo; una que falle no afecta al resto.
cmd_check() {
  local tsv=false t id pin origin latest status ok_n=0 out_n=0 err_n=0 tmp
  [[ "${1:-}" == --tsv ]] && tsv=true
  tmp="$(mktemp -d)"
  trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$tmp"; exit 143' TERM INT   # si te cancelan (timeout), no dejes consultas huérfanas
  local -a ids=()
  for t in "${TOOLS[@]}"; do if enabled "$t"; then ids+=("$t"); fi; done
  for id in "${ids[@]}"; do ( latest_of "$id" > "$tmp/$id" 2>/dev/null || echo ERROR > "$tmp/$id" ) & done
  wait
  local -a rows=()
  for id in "${ids[@]}"; do
    load_spec "$id"
    IFS=$'\t' read -r pin origin <<< "$(pinned_of)"
    latest="$(cat "$tmp/$id" 2>/dev/null || echo ERROR)"
    if [[ "$latest" == ERROR || -z "$latest" ]]; then status=error; latest="?"; err_n=$((err_n + 1))
    elif ver_gt "$latest" "${pin#"$S_VALP"}"; then status=outdated; latest="$S_VALP$latest"; out_n=$((out_n + 1))
    else status=ok; latest="$S_VALP$latest"; ok_n=$((ok_n + 1)); fi
    rows+=("$id"$'\t'"$S_LABEL"$'\t'"$pin"$'\t'"$latest"$'\t'"$origin"$'\t'"$status")
  done
  rm -rf "$tmp"
  if [[ "$tsv" == true ]]; then printf '%s\n' "${rows[@]}"; return 0; fi
  printf '%-16s %-12s %-12s %-7s %s\n' HERRAMIENTA FIJADA ÚLTIMA ORIGEN ESTADO
  local r f1 f3 f4 f5 f6
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r f1 _ f3 f4 f5 f6 <<< "$r"
    printf '%-16s %-12s %-12s %-7s %s\n' "$f1" "$f3" "$f4" "$f5" "$f6"
  done
  echo "$out_n con versión nueva, $ok_n al día, $err_n sin respuesta (de ${#ids[@]})."
}

cmd_reset() {
  [[ "$TARGET" == env ]] || die "reset solo funciona con --target env (quita las versiones fijadas del .env; no toca los archivos del repo)."
  [[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE"
  local t k n=0
  for t in "${TOOLS[@]}"; do
    load_spec "$t"
    for k in "$S_KEY" $([[ "$t" == herdr ]] && echo "${HERDR_SHA_KEYS[*]}"); do
      if grep -qE "^$k=" "$ENV_FILE"; then drop_env_line "$ENV_FILE" "$k"; n=$((n + 1)); fi
    done
  done
  info "Quité $n versión(es) fijada(s) del .env; la imagen usará las del repo."
}

main() {
  while [[ $# -gt 0 ]]; do   # opciones globales
    case "$1" in
      --target)   TARGET="${2:?falta repo o env}"; shift 2 ;;
      --target=*) TARGET="${1#*=}"; shift ;;
      *) break ;;
    esac
  done
  [[ "$TARGET" == repo || "$TARGET" == env ]] || die "--target debe ser repo o env"
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    check)   cmd_check "$@" ;;
    list)    cmd_list "$@" ;;
    choose)  cmd_choose "$@" ;;
    set)     [[ $# -eq 2 ]] || die "Uso: set <herramienta> <versión|latest>"; set_pin "$1" "$2" ;;
    latest)  cmd_latest "$@" ;;
    reset)   cmd_reset ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "Comando desconocido: $cmd" ;;
  esac
}

main "$@"
