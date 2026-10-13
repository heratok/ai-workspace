# shellcheck shell=bash
# lib/instances.sh - nombres de instancia, propiedad de la carpeta y verificaciones previas
# Se carga con "source" desde setup.sh; no se ejecuta solo.

# ------------------------------------------------------------------ instancias
# Varias instancias aisladas en un mismo servidor: cada una vive en su carpeta y
# todos sus nombres (proyecto compose, contenedores, volúmenes, imagen) derivan
# del alias guardado en .env (AIWS_INSTANCE). Sin alias = instancia principal,
# con los nombres de siempre (ai-workspace, ai_home...), sin migrar nada.
ALIAS_RE='^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$'

# alias_error <alias>: imprime el motivo y devuelve 1 si el alias no es válido
alias_error() {
  local a="$1"
  if [[ ! "$a" =~ $ALIAS_RE ]]; then
    echo "Alias inválido '$a': usa 1 a 20 caracteres entre a-z, 0-9 y '-' (sin empezar ni terminar en '-')."
    return 1
  fi
  # Estos nombres chocarían con los contenedores auxiliares (-ts, -mssql) o con restos de versiones viejas
  case "$a" in
    ts|mssql|postgres|redis|*-ts|*-mssql)
      echo "Alias reservado '$a': evita ts, mssql, postgres, redis y los terminados en -ts o -mssql."
      return 1 ;;
  esac
  return 0
}

# instance_names <alias>: fija todos los nombres de la instancia ("" o "default" = principal)
instance_names() {
  local a="${1:-}" msg
  [[ "$a" == default ]] && a=""
  if [[ -n "$a" ]]; then msg="$(alias_error "$a")" || die "$msg"; fi
  INSTANCE="$a"
  if [[ -z "$a" ]]; then AIWS_NAME="ai-workspace"; AIWS_VOL_PREFIX="ai"
  else AIWS_NAME="ai-workspace-$a"; AIWS_VOL_PREFIX="ai-workspace-$a"; fi
  CONTAINER="$AIWS_NAME"
  TS_CONTAINER="$AIWS_NAME-ts"
  MSSQL_CONTAINER="$AIWS_NAME-mssql"
  IMAGE="$AIWS_NAME:latest"
  TS_VOLUME="${AIWS_VOL_PREFIX}_ts_state"
  VOLUMES=("${AIWS_VOL_PREFIX}_home" "${AIWS_VOL_PREFIX}_workspace")
  ALL_VOLUMES=("${VOLUMES[@]}" "${AIWS_VOL_PREFIX}_ssh_host_keys" "$TS_VOLUME" "${AIWS_VOL_PREFIX}_mssql_data")
}
instance_names "$(env_get AIWS_INSTANCE)"

# Guarda la identidad de la instancia en .env (idempotente). Para alias, el nombre
# en la tailnet (TS_HOSTNAME) deja de ser el genérico, salvo que el usuario lo haya cambiado.
write_instance_env() {
  env_set AIWS_INSTANCE "$INSTANCE"
  env_set AIWS_NAME "$AIWS_NAME"
  env_set AIWS_VOL_PREFIX "$AIWS_VOL_PREFIX"
  if [[ -n "$INSTANCE" ]]; then
    local h; h="$(env_get TS_HOSTNAME)"
    if [[ -z "$h" || "$h" == ai-workspace ]]; then env_set TS_HOSTNAME "$AIWS_NAME"; fi
  fi
}

# --alias: una carpeta = una instancia. Solo se rechaza si esta carpeta ya tiene la suya:
# su .env guarda otro alias, o ella gestiona los contenedores de la instancia actual.
# (Un clon nuevo con la principal instalada en otra carpeta sí puede crear una instancia.)
bind_alias() {
  local want="${1:-}" msg owner
  [[ "$want" == default ]] && want=""
  if [[ -n "$want" ]]; then msg="$(alias_error "$want")" || die "$msg"; fi
  [[ "$want" == "$INSTANCE" ]] && return 0
  owner="$(container_owner "$CONTAINER")"
  if [[ -n "$INSTANCE" ]] || { [[ -n "$owner" ]] && same_dir "$owner" "$SCRIPT_DIR"; }; then
    die "Esta carpeta ya es la instancia '${INSTANCE:-principal}' ($CONTAINER). Para otra instancia usa otra carpeta: install.sh --alias ${want:-default}"
  fi
  instance_names "$want"
}

# Dueño (carpeta de compose) de un contenedor; vacío si no existe o no es de compose
container_owner() {
  docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null || true
}

same_dir() { [[ "$(readlink -f "$1" 2>/dev/null || echo "$1")" == "$(readlink -f "$2" 2>/dev/null || echo "$2")" ]]; }

# Evita pisar una instancia gestionada desde otra carpeta. Si la carpeta dueña registrada ya
# no existe (la moviste), solo avisa: sigue siendo la misma instancia.
check_instance_owner() {
  local c owner
  for c in "$CONTAINER" "$TS_CONTAINER"; do
    docker container inspect "$c" >/dev/null 2>&1 || continue
    owner="$(container_owner "$c")"
    if [[ -n "$owner" ]]; then
      same_dir "$owner" "$SCRIPT_DIR" && continue
      [[ -d "$owner" ]] && die "El contenedor $c lo gestiona otra carpeta ($owner). Usa esa carpeta, o elige otro alias: install.sh --alias OTRO"
    elif [[ -n "$INSTANCE" ]]; then
      die "El contenedor $c ya existe y no lo gestiona ninguna carpeta conocida. Elige otro alias: install.sh --alias OTRO"
    fi
    warn "El contenedor $c figura en ${owner:-otro origen}, no en esta carpeta. Si moviste la carpeta, sigue siendo la misma instancia."
  done
  return 0
}

# Nombres (AIWS_NAME) de las demás instancias del servidor, una por línea
other_instances() {
  {
    docker ps -a --filter label=org.ai-workspace.instance --format '{{.Label "org.ai-workspace.instance"}}' 2>/dev/null || true
    # La principal instalada antes de las etiquetas no tiene ninguna
    docker container inspect ai-workspace-ts >/dev/null 2>&1 && echo ai-workspace
  } | sort -u | grep -vxF -e "$AIWS_NAME" -e '' || true
}

# ------------------------------------------------------------- verificaciones
check_prereqs() {
  command -v docker >/dev/null || die "Docker no está instalado en el servidor."
  docker info >/dev/null 2>&1 || die "Sin acceso a Docker. ¿Tu usuario está en el grupo 'docker'? (o usa sudo)"
  docker compose version >/dev/null 2>&1 || die "Falta el plugin 'docker compose' (v2)."
  [[ -c /dev/net/tun ]] || die "No existe /dev/net/tun en el servidor (requerido por Tailscale). Pide al admin: 'modprobe tun'."
}

# Detecta copias incompletas o viejas de la carpeta
check_files() {
  local f missing=()
  for f in Dockerfile docker-compose.yml entrypoint.sh env.example config/packages.apt \
           config/env.sh config/zshrc config/skel/zshrc config/sshd-ai-workspace.conf \
           config/extra-root.sh config/ws-doctor config/devdb \
           lib/common.sh lib/instances.sh lib/config.sh lib/lifecycle.sh lib/background.sh \
           lib/resources.sh lib/components.sh lib/maintenance.sh lib/backup.sh lib/uninstall.sh lib/tools.sh; do
    [[ -f "$f" ]] || missing+=("$f")
  done
  (( ${#missing[@]} == 0 )) || die "Faltan archivos (copia la carpeta completa de nuevo): ${missing[*]}"
  grep -q 'config/devdb' Dockerfile || die "Dockerfile desactualizado: copia de nuevo la carpeta completa."
}

# Archivos copiados desde Windows: quitar CRLF que rompen los scripts
normalize_line_endings() {
  local f
  for f in Dockerfile docker-compose.yml entrypoint.sh env.example config/*; do
    if [[ -f "$f" ]] && grep -q $'\r' "$f"; then sed -i 's/\r$//' "$f"; warn "CRLF corregido en $f"; fi
  done
  [[ -f "$ENV_FILE" ]] && grep -q $'\r' "$ENV_FILE" && sed -i 's/\r$//' "$ENV_FILE"
  chmod +x entrypoint.sh config/*.sh config/ws-doctor 2>/dev/null || true
}
