#!/usr/bin/env bash
# =============================================================================
# ai-workspace - instalación en un solo comando
#
#   curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 ...'
#   curl -fsSL .../install.sh | bash -s -- --alias cliente-a      # instancia aislada extra
#   curl -fsSL .../install.sh | bash -s -- --mem 4g --cpus 2     # límites de memoria y CPUs (si no, se sugieren)
#
# Clona el repositorio (o lo actualiza si ya existe) y ejecuta "setup.sh install"
# con los argumentos recibidos. setup.sh necesita vivir en un clon de git para
# que luego funcionen "upgrade" y "rollback".
#
# Varias instancias en el mismo servidor: si ya existe la principal y no indicas
# alias, se crea una nueva (ai-workspace-2, ai-workspace-3...) en su propia carpeta,
# con volúmenes, contenedores y nombre de Tailscale propios.
#
# Variables opcionales:
#   AIWS_INSTANCE     Alias de la instancia      (equivale a --alias; vacío o "default" = la principal)
#   AIWS_DIR          Carpeta de instalación     (por defecto: ~/ai-workspace, o ~/ai-workspace-ALIAS)
#   AIWS_REPO_URL     Repositorio                (por defecto: https://github.com/heratok/ai-workspace.git)
#   AIWS_REPO_BRANCH  Rama o tag                 (por defecto: main)
# =============================================================================

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Funciones auxiliares de instancias: sin efectos secundarios, para poder probarlas con
# "source install.sh" (tests/instances.test.sh). Las reglas de alias son las mismas de setup.sh.
ALIAS_RE='^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$'

# aiws_alias_error <alias>: imprime el motivo y devuelve 1 si el alias no es válido
aiws_alias_error() {
  local a="$1"
  if [[ ! "$a" =~ $ALIAS_RE ]]; then
    echo "Alias inválido '$a': usa 1 a 20 caracteres entre a-z, 0-9 y '-' (sin empezar ni terminar en '-')."
    return 1
  fi
  case "$a" in
    ts|mssql|postgres|redis|*-ts|*-mssql)
      echo "Alias reservado '$a': evita ts, mssql, postgres, redis y los terminados en -ts o -mssql."
      return 1 ;;
  esac
  return 0
}

aiws_dir_for() {   # carpeta por defecto de una instancia ("" = principal)
  if [[ -z "${1:-}" ]]; then echo "$HOME/ai-workspace"; else echo "$HOME/ai-workspace-$1"; fi
}
aiws_container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
aiws_volume_exists()    { docker volume inspect "$1" >/dev/null 2>&1; }

# ¿Ya hay una instancia principal? Solo cuenta si existen sus recursos en Docker: un clon sin
# contenedores ni volúmenes es una instalación que no terminó, y volver a ejecutar la retoma.
aiws_default_exists() {
  local x
  for x in ai-workspace ai-workspace-ts; do aiws_container_exists "$x" && return 0; done
  for x in ai_ts_state ai_home; do aiws_volume_exists "$x" && return 0; done
  return 1
}

# ¿Alias ocupado? Carpeta, contenedores o volúmenes con sus nombres
aiws_alias_taken() {
  local n="ai-workspace-$1" x
  [[ -e "$(aiws_dir_for "$1")" ]] && return 0
  for x in "$n" "$n-ts" "$n-mssql"; do aiws_container_exists "$x" && return 0; done
  for x in home workspace ssh_host_keys ts_state mssql_data; do aiws_volume_exists "${n}_$x" && return 0; done
  return 1
}

# Primer número libre desde el 2
aiws_next_free_alias() {
  local n=2
  while aiws_alias_taken "$n"; do n=$((n + 1)); done
  echo "$n"
}

# Instancias existentes (una por línea; "default" primero): clones en ~ y contenedores etiquetados
aiws_list_instances() {
  local d l all
  all="$({
    aiws_default_exists && echo default
    for d in "$HOME"/ai-workspace-*; do
      [[ -d "$d/.git" ]] && echo "${d##*/ai-workspace-}"
    done
    { docker ps -a --filter label=org.ai-workspace.instance --format '{{.Label "org.ai-workspace.instance"}}' 2>/dev/null || true; } \
      | while IFS= read -r l; do
          l="${l#ai-workspace}"; l="${l#-}"; echo "${l:-default}"
        done
  } | sort -u)"
  if grep -qx default <<<"$all"; then echo default; fi
  grep -vx -e default -e '' <<<"$all" || true
}

aiws_have_tty() { { : </dev/tty; } 2>/dev/null; }
aiws_prompt()   { local a=""; read -rp "$1" a </dev/tty || true; echo "$a"; }

# Ya existe la principal y no se indicó alias: lista las instancias y decide cuál usar.
# Imprime el alias elegido en stdout (los mensajes van a stderr).
aiws_choose_alias() {
  local next name answer msg tries=0
  next="$(aiws_next_free_alias)"
  if [[ -z "${AIWS_MENU_SHOWN:-}" ]]; then
  {
    echo "Ya hay instancias de ai-workspace en este servidor:"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$name" == default ]]; then printf '  - %-14s (ai-workspace)\n' "$name"
      else printf '  - %-14s (ai-workspace-%s)\n' "$name" "$name"; fi
    done <<<"$(aiws_list_instances)"
  } >&2
  fi
  if aiws_have_tty; then
    # Un alias inválido se vuelve a preguntar (hasta 3 intentos)
    while :; do
      answer="$(aiws_prompt "Alias de la nueva instancia [$next] (escribe uno existente para actualizarlo): ")"
      answer="${answer//[[:space:]]/}"
      answer="${answer:-$next}"
      [[ "$answer" == default ]] && break
      msg="$(aiws_alias_error "$answer")" && break
      echo "$msg" >&2
      tries=$((tries + 1))
      (( tries < 3 )) || return 1
    done
  else
    answer="$next"
    echo "Sin terminal interactiva: se crea la instancia nueva '$answer' (ai-workspace-$answer)." >&2
  fi
  printf '%s\n' "$answer"
}

# Menú al volver a ejecutar con instancias existentes (solo con terminal). Imprime en stdout
# "new" o "update <alias...>" (default = la principal); el menú va a stderr.
aiws_menu() {
  local -a inst=()
  local name i total tries=0 answer
  while IFS= read -r name; do [[ -n "$name" ]] && inst+=("$name"); done <<<"$(aiws_list_instances)"
  total=${#inst[@]}
  {
    echo "Ya hay instancias de ai-workspace en este servidor. ¿Qué quieres hacer?"
    echo "  1) Crear una instancia nueva"
    for i in "${!inst[@]}"; do
      if [[ "${inst[i]}" == default ]]; then name=ai-workspace; else name="ai-workspace-${inst[i]}"; fi
      printf '  %d) Actualizar %s  (%s)
' "$((i + 2))" "${inst[i]}" "$name"
    done
    printf '  %d) Actualizar todas
' "$((total + 2))"
  } >&2
  while (( tries < 3 )); do
    answer="$(aiws_prompt "Opción [1]: ")"
    answer="${answer//[[:space:]]/}"; answer="${answer:-1}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= total + 2 )); then
      if (( answer == 1 )); then echo new
      elif (( answer == total + 2 )); then echo "update ${inst[*]}"
      else echo "update ${inst[answer - 2]}"; fi
      return 0
    fi
    echo "Opción inválida: '$answer'." >&2
    tries=$((tries + 1))
  done
  return 1
}

# Actualiza instancias existentes (alias; default = la principal), una tras otra, con "setup.sh upgrade"
# dentro de su carpeta (él mismo hace el fetch/merge, las migraciones y deja la versión previa para
# rollback; un git pull antes lo dejaría sin cambios que aplicar). Sigue si alguna falla; devuelve 1 si hubo fallos.
aiws_update_instances() {
  local a key dir fails=0 r
  local -a results=()
  for a in "$@"; do
    key="$a"; [[ "$a" == default ]] && key=""
    dir="$(aiws_dir_for "$key")"
    if [[ ! -f "$dir/setup.sh" ]]; then
      warn "No encuentro la carpeta de '$a' ($dir). Si está en otro lugar usa: aiws upgrade $a"
      results+=("  fallo  $a"); fails=$((fails + 1)); continue
    fi
    info "Actualizando $a ($dir)..."
    if ( cd "$dir" && bash ./setup.sh upgrade --yes ); then results+=("  ok     $a")
    else results+=("  fallo  $a"); fails=$((fails + 1)); fi
  done
  echo; echo "Resumen:"
  for r in "${results[@]}"; do echo "$r"; done
  (( fails == 0 ))
}

# Resuelve la instancia: alias explícito > principal si aún no existe > elegir. Imprime el alias ("" = principal).
aiws_pick_instance() {
  local raw="${1:-}" a msg
  if [[ -n "$raw" ]]; then a="$raw"
  elif aiws_default_exists; then a="$(aiws_choose_alias)" || return 1
  else a=""; fi
  [[ "$a" == default ]] && a=""
  if [[ -n "$a" ]]; then
    msg="$(aiws_alias_error "$a")" || { echo "$msg" >&2; return 1; }
  fi
  printf '%s\n' "$a"
}

# Todo va dentro de main(), que se llama en la última línea: si la descarga se
# corta a la mitad, bash no ejecuta un script incompleto.
main() {
  set -Eeuo pipefail

  local repo="${AIWS_REPO_URL:-https://github.com/heratok/ai-workspace.git}"
  local branch="${AIWS_REPO_BRANCH:-main}"

  # --alias NOMBRE se consume aquí; el resto de argumentos pasa tal cual a setup.sh
  local alias_raw="${AIWS_INSTANCE:-}" alias
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias)   alias_raw="${2:?falta el alias (ej.: --alias cliente-a)}"; shift 2 ;;
      --alias=*) alias_raw="${1#--alias=}"; shift ;;
      *)         args+=("$1"); shift ;;
    esac
  done

  command -v git >/dev/null    || die "Falta git en el servidor (ej.: sudo apt-get install -y git)."
  command -v docker >/dev/null || die "Falta Docker en el servidor: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "Falta el plugin \"docker compose\"."

  # Con terminal y la principal ya instalada: menú para crear una instancia nueva o actualizar las existentes
  if [[ -z "$alias_raw" && -z "${AIWS_DIR:-}" ]] && aiws_have_tty && aiws_default_exists; then
    local choice rc=0
    choice="$(aiws_menu)" || exit 1
    if [[ "$choice" == update* ]]; then
      local -a to_update
      read -ra to_update <<<"${choice#update }"
      aiws_update_instances "${to_update[@]}" || rc=$?
      return "$rc"
    fi
    AIWS_MENU_SHOWN=1
  fi
  # Con AIWS_DIR y sin alias, la carpeta manda: setup.sh toma la instancia de su .env
  if [[ -n "$alias_raw" || -z "${AIWS_DIR:-}" ]]; then
    alias="$(aiws_pick_instance "$alias_raw")" || exit 1
  else
    alias=""
  fi
  local dir="${AIWS_DIR:-$(aiws_dir_for "$alias")}"
  # "--alias default" apunta a la principal de forma explícita (setup.sh lo valida contra el .env de la carpeta)
  local explicit_default=false
  [[ "$alias_raw" == default ]] && explicit_default=true

  if [[ -d "$dir/.git" ]]; then
    info "Ya existe $dir: actualizando ($branch)..."
    if ! git -C "$dir" pull -q --ff-only origin "$branch"; then
      warn "No se pudo actualizar sin conflictos; sigo con la versión local (luego: ./setup.sh upgrade)."
    fi
  elif [[ -e "$dir" ]]; then
    die "$dir existe pero no es un clon de git. Muévelo o usa AIWS_DIR=/otra/ruta."
  else
    if [[ -n "$alias" ]]; then
      info "Nueva instancia: ai-workspace-$alias (carpeta $dir)"
      if aiws_alias_taken "$alias"; then
        warn "Ya existen contenedores o volúmenes de ai-workspace-$alias sin carpeta: se reutilizan sus datos."
      fi
    fi
    info "Clonando $repo ($branch) en $dir..."
    git clone -q --branch "$branch" "$repo" "$dir"
  fi

  chmod +x "$dir/setup.sh"
  cd "$dir"
  info "Ejecutando setup.sh install..."

  local -a pass=()
  if [[ -n "$alias" ]]; then pass=(--alias "$alias"); elif [[ "$explicit_default" == true ]]; then pass=(--alias default); fi
  pass+=(${args[@]+"${args[@]}"})

  # Con "curl | bash" la entrada estándar es el propio script: las preguntas de
  # setup.sh (auth key, clave SSH, componentes) deben leer de la terminal.
  if [[ -t 0 ]]; then
    exec ./setup.sh install ${pass[@]+"${pass[@]}"}
  elif aiws_have_tty; then
    exec ./setup.sh install ${pass[@]+"${pass[@]}"} </dev/tty
  else
    warn "Sin terminal interactiva: pasa --authkey y --pubkey para que no haga preguntas."
    exec ./setup.sh install ${pass[@]+"${pass[@]}"} </dev/null
  fi
}

# Con "curl | bash" BASH_SOURCE está vacío y main debe correr; con "source install.sh" (pruebas) no.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
