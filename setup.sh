#!/usr/bin/env bash
# =============================================================================
# ai-workspace - instalador / operador en un solo script
#
#   ./setup.sh                       Menú interactivo (instalar, desinstalar, estado...)
#   ./setup.sh install [--pubkey RUTA.pub|'ssh-ed25519 ...'] [--authkey tskey-auth-...] [--alias NOMBRE] [--mem 4g] [--cpus 2] [--foreground]
#                                    Pide lo que falte y luego sigue en SEGUNDO PLANO:
#                                    si se cae SSH, la instalación continúa.
#                                    --alias: instancia aislada ai-workspace-NOMBRE (varias por servidor;
#                                    una carpeta = una instancia). Lo normal es crearla con install.sh.
#   ./setup.sh progress              Ver el progreso / resultado del último proceso
#   ./setup.sh upgrade [--yes]       Descarga lo último de GitHub (git), migra y reconstruye (--yes: sin preguntas)
#   ./setup.sh resources [--mem 4g --cpus 2 ...]  Ver límites y uso real, o cambiarlos SIN reconstruir (--set: elegir uno a uno)
#   ./setup.sh components            Elegir qué agentes/herramientas trae la imagen
#   ./setup.sh rollback              Vuelve a la versión anterior al último upgrade
#   ./setup.sh clean [--deep]        Limpia imágenes viejas, logs y respaldos antiguos
#   ./setup.sh update                Reconstruye con versiones nuevas
#   ./setup.sh add-key [RUTA.pub | 'ssh-ed25519 AAAA...' | github:usuario]
#                                    Autoriza una clave SSH (sin argumento: la pide para pegar)
#   ./setup.sh backup                Respalda home + proyectos en ./backups
#   ./setup.sh uninstall [--yes]     Quita contenedores e imagen; CONSERVA datos
#   ./setup.sh uninstall --all       Borra TODO: datos, volúmenes, .env, nodo Tailscale
#   ./setup.sh status | logs | shell | psql | doctor | ts-status | down
#   (bases de datos locales: dentro del workspace usa "devdb help")
#
# Requisito único en el servidor: Docker + plugin "docker compose".
# Variables del .env: ver env.example y README.md.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WS_USER="ai"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/env.example"
REPO_URL="${AIWS_REPO_URL:-https://github.com/heratok/ai-workspace.git}"
REPO_BRANCH="${AIWS_REPO_BRANCH:-main}"
LOG_DIR="$SCRIPT_DIR/logs"            # logs + estado de procesos en segundo plano
PID_FILE="$LOG_DIR/.pid"
STATUS_FILE="$LOG_DIR/.status"
PENDING_KEY="$LOG_DIR/.pending-key.pub"
KEY_OK="$LOG_DIR/.ssh-key-ok"

# ----------------------------------------------------------------- utilidades
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
info() { echo "${c_ok}==>${c_off} $*"; }
warn() { echo "${c_warn}[aviso]${c_off} $*" >&2; }
die()  { echo "${c_err}[error]${c_off} $*" >&2; exit 1; }
trap 'die "falló en la línea $LINENO: $BASH_COMMAND"' ERR

compose() {
  # AIWS_NAME / AIWS_VOL_PREFIX se pasan siempre desde los nombres derivados de esta
  # instancia, así compose y setup.sh nunca discrepan aunque el .env se edite a mano.
  local -a envf=(); [[ -f "$ENV_FILE" ]] && envf=(--env-file "$ENV_FILE")
  AIWS_NAME="$AIWS_NAME" AIWS_VOL_PREFIX="$AIWS_VOL_PREFIX" docker compose ${envf[@]+"${envf[@]}"} "$@"
}

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}
# Escritura segura (valores con / & | @ espacios) sin sed
env_set() {
  local key="$1" val="$2" tmp
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  tmp="$(mktemp "$ENV_FILE.XXXX")"
  KEY="$key" VAL="$val" awk '
    BEGIN { k=ENVIRON["KEY"]; v=ENVIRON["VAL"]; done=0 }
    index($0, k"=")==1 { if (!done) { print k"="v; done=1 }; next }
    { print }
    END { if (!done) print k"="v }
  ' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}

env_del() {   # elimina una variable obsoleta del .env
  [[ -f "$ENV_FILE" ]] || return 0
  grep -qE "^$1=" "$ENV_FILE" || return 0
  local tmp; tmp="$(mktemp "$ENV_FILE.XXXX")"
  grep -vE "^$1=" "$ENV_FILE" > "$tmp" || true
  chmod 600 "$tmp"; mv "$tmp" "$ENV_FILE"
}

# Registro por usuario de las carpetas de instancias (aiws lo lee: una instancia fuera de ~/ai-workspace*
# deja de tener contenedores tras "down" y, sin esto, desaparecería de la lista).
registry_file() { echo "${XDG_DATA_HOME:-$HOME/.local/share}/ai-workspace/instances"; }
registry_add() {
  local f; f="$(registry_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  touch "$f" 2>/dev/null || return 0
  grep -qxF "$SCRIPT_DIR" "$f" || echo "$SCRIPT_DIR" >> "$f"
  return 0
}
registry_remove() {
  local f tmp; f="$(registry_file)"
  [[ -f "$f" ]] || return 0
  tmp="$(mktemp "$f.XXXX")" || return 0
  grep -vxF "$SCRIPT_DIR" "$f" > "$tmp" || true
  mv "$tmp" "$f"
}

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
           config/extra-root.sh config/ws-doctor config/devdb; do
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

# --------------------------------------------------------------- configuración
gen_secret() { od -An -tx1 -N20 /dev/urandom | tr -d ' \n'; }

profile_on() { [[ ",$(env_get COMPOSE_PROFILES)," == *",$1,"* ]]; }

# Contraseñas de servicios: se generan una sola vez y quedan en .env (600)
ensure_secrets() {
  if [[ -z "$(env_get MSSQL_SA_PASSWORD)" ]]; then
    env_set MSSQL_SA_PASSWORD "Ws1-$(gen_secret)"   # SQL Server exige mayúscula, número y símbolo
  fi
  return 0
}

# ¿El nodo ya tiene identidad guardada? (volumen con estado de Tailscale)
ts_logged_in_before() {
  docker volume inspect "$TS_VOLUME" >/dev/null 2>&1 || return 1
  local tag; tag="$(env_get TS_IMAGE_TAG)"
  docker run --rm --entrypoint sh -v "$TS_VOLUME:/s:ro" "tailscale/tailscale:${tag:-stable}" \
    -c 'test -s /s/tailscaled.state' >/dev/null 2>&1
}

configure_env() {
  local authkey="${1:-}" is_new=false

  if [[ ! -f "$ENV_FILE" ]]; then
    is_new=true
    [[ -f "$ENV_EXAMPLE" ]] || die "Falta env.example"
    cp "$ENV_EXAMPLE" "$ENV_FILE"; chmod 600 "$ENV_FILE"
    info ".env creado desde env.example"
    if has_tty; then
      local mode; read -rp "¿Instalación completa (recomendada) o personalizada? [C/p]: " mode || true
      if [[ "$mode" =~ ^[pP] ]]; then choose_components || true; fi
    fi
  fi

  write_instance_env
  size_resources "$is_new"
  [[ -n "$authkey" ]] && env_set TS_AUTHKEY "$authkey"

  if ! ts_logged_in_before && [[ -z "$(env_get TS_AUTHKEY)" ]]; then
    cat <<EOF

${c_ok}Conexión a Tailscale (solo esta vez):${c_off}
  - Pega tu auth key (tskey-auth-...) y presiona Enter, o
  - Presiona Enter sin pegar nada para iniciar sesión con un link en el navegador.
EOF
    read -rsp "Auth key (oculta): " authkey || true; echo
    authkey="$(echo -n "$authkey" | tr -d '[:space:]')"
    if [[ -n "$authkey" ]]; then env_set TS_AUTHKEY "$authkey"
    else info "Sin auth key: se mostrará un link de inicio de sesión."; fi
  fi

  local key; key="$(env_get TS_AUTHKEY)"
  if [[ -n "$key" && "$key" != tskey-* ]]; then
    env_set TS_AUTHKEY ""
    die "TS_AUTHKEY no parece válida (debe empezar con 'tskey-'). Ejecuta install de nuevo."
  fi
  ensure_secrets
  info "Configuración lista en .env (instancia $AIWS_NAME, TS_HOSTNAME=$(env_get TS_HOSTNAME), servicios: $(env_get COMPOSE_PROFILES))"
}

create_volumes() {
  local v
  for v in "${VOLUMES[@]}"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      info "Volumen $v ya existe (se conserva)"
    else
      docker volume create "$v" >/dev/null && info "Volumen $v creado"
    fi
  done
}

# ---------------------------------------------------------------- ciclo de vida
wait_healthy() {
  local name="$1" i status="missing"
  for i in $(seq 1 45); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
    case "$status" in
      healthy)   info "$name saludable"; return 0 ;;
      unhealthy) break ;;
    esac
    sleep 2
  done
  docker logs --tail 40 "$name" >&2 || true
  die "$name no quedó saludable (estado: $status)."
}

# Espera a que el nodo tenga IP en la tailnet. Si no hay auth key, muestra el link de login.
ts_wait_login() {
  local timeout=600 waited=0 url="" shown=""
  while (( waited < timeout )); do
    [[ -n "$(ts_ip)" ]] && { info "Tailscale conectado (IP $(ts_ip))"; return 0; }
    url="$(docker logs "$TS_CONTAINER" 2>&1 | grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' | tail -n1 || true)"
    if [[ -n "$url" && "$url" != "$shown" ]]; then
      cat <<EOF

${c_warn}>>> Abre este link en tu navegador y aprueba el equipo:${c_off}

      $url

    (esperando hasta $((timeout / 60)) minutos...)
EOF
      shown="$url"
    fi
    sleep 3; waited=$((waited + 3))
  done
  docker logs --tail 30 "$TS_CONTAINER" >&2 || true
  die "Tailscale no se conectó. Revisa la auth key o vuelve a ejecutar install."
}

build_and_up() {
  info "Construyendo imagen (la primera vez tarda varios minutos)..."
  compose build --pull "$@"
  info "Levantando Tailscale..."
  compose up -d tailscale
  ts_wait_login
  info "Levantando workspace..."
  compose up -d --remove-orphans
  wait_healthy "$TS_CONTAINER"
  wait_healthy "$CONTAINER"
  wait_services
}

wait_services() {
  if profile_on mssql; then info "SQL Server tarda ~30 s en aceptar conexiones la primera vez."; fi
  return 0
}

# Una vez registrado el nodo, la auth key ya no hace falta: se elimina del .env
forget_authkey() {
  if [[ -n "$(env_get TS_AUTHKEY)" ]]; then
    env_set TS_AUTHKEY ""
    info "Nodo registrado: TS_AUTHKEY eliminada del .env (la identidad vive en el volumen $TS_VOLUME)"
    # Recrear ambos (el workspace comparte la red del sidecar) para quitar la key del entorno
    compose up -d --force-recreate
    wait_healthy "$TS_CONTAINER"
    wait_healthy "$CONTAINER"
    wait_services
  fi
}

ts_ip() { docker exec "$TS_CONTAINER" tailscale ip -4 2>/dev/null | head -n1 || true; }

# Acepta: ruta a .pub | la clave pegada como texto | github:usuario | "-" o vacío = pegar
add_key() {
  local src="${1:-}" keys tmp
  tmp="$(mktemp)"

  [[ "$src" == *"PRIVATE KEY"* ]] && die "Eso es una clave PRIVADA. Usa solo el contenido del archivo .pub"
  if [[ -z "$src" || "$src" == "-" ]]; then
    cat <<EOF

Pega tu clave PÚBLICA SSH (una línea que empieza con ssh-ed25519, ssh-rsa o ecdsa-...)
  En tu PC Windows (PowerShell):  type \$env:USERPROFILE\.ssh\id_ed25519.pub
  ¿No tienes?  ssh-keygen -t ed25519   y luego el comando de arriba.
EOF
    read -rp "Clave pública: " keys || true
  elif [[ "$src" == github:* ]]; then
    keys="$(curl -fsSL "https://github.com/${src#github:}.keys")" || die "No pude descargar las claves de GitHub de ${src#github:}"
  elif [[ -f "$src" ]]; then
    [[ "$src" == *.pub ]] || warn "$src no termina en .pub; verifica que NO sea tu clave privada."
    keys="$(cat "$src")"
  elif [[ "$src" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    keys="$src"
  else
    die "No existe el archivo '$src'. Usa: add-key (y pegar), add-key 'ssh-ed25519 AAAA...', add-key RUTA.pub o add-key github:usuario"
  fi

  grep -qE 'PRIVATE KEY' <<<"$keys" && die "Eso es una clave PRIVADA. Pega solo el contenido del archivo .pub"
  printf '%s\n' "$keys" | tr -d '\r' | grep -E '^(ssh-|ecdsa-|sk-)' > "$tmp" || true
  [[ -s "$tmp" ]] || die "No se encontró ninguna clave pública válida."
  # Validación con ssh-keygen del contenedor (no depende de herramientas del servidor)
  docker exec -i "$CONTAINER" ssh-keygen -l -f - < "$tmp" >/dev/null 2>&1 \
    || die "La clave no es válida (¿se cortó al pegar?)."

  docker exec -i "$CONTAINER" bash -c '
    set -e
    d=/home/'"$WS_USER"'/.ssh; f="$d/authorized_keys"
    install -d -m 700 "$d"; touch "$f"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      grep -qxF "$k" "$f" || echo "$k" >> "$f"
    done
    chown -R '"$WS_USER"':'"$WS_USER"' "$d"; chmod 600 "$f"
  ' < "$tmp"
  while IFS= read -r line; do info "Clave autorizada: $line"; done \
    < <(docker exec -i "$CONTAINER" ssh-keygen -l -f - < "$tmp")
  rm -f "$tmp"
}

default_pubkey() {
  local k
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$k" ]]; then echo "$k"; return 0; fi
  done
  return 0
}

doctor() { docker exec -u "$WS_USER" "$CONTAINER" zsh -lc ws-doctor; }

summary() {
  local host ip profiles others; host="$(env_get TS_HOSTNAME)"; host="${host:-$AIWS_NAME}"; ip="$(ts_ip)"
  profiles="$(env_get COMPOSE_PROFILES)"
  cat <<EOF

${c_ok}Listo.${c_off} Accesible SOLO desde tu tailnet (nada publicado en el servidor).
  Instancia: ${AIWS_NAME}${INSTANCE:+  (alias: $INSTANCE)}   Carpeta: ${SCRIPT_DIR}
  Equipo: ${host}  (IP Tailscale: ${ip:-?})
  SSH   : ssh ${WS_USER}@${host}
  Mosh  : mosh -p 60000:60010 ${WS_USER}@${host}
  Web   : http://${host}:3000  |  http://${host}:5173   (el dev server debe escuchar en 0.0.0.0)
  BD local : dentro del workspace -> devdb start (PostgreSQL) | devdb start redis | devdb enable (autoarranque)
  Extra    : ${profiles:-ninguno}   (mssql = SQL Server en contenedor aparte)
  GitHub   : dentro del workspace ejecuta  gh auth login  (queda guardado en el volumen)
  Diagnóstico: ./setup.sh doctor   |   Estado Tailscale: ./setup.sh ts-status
  Instancias : aiws ls  (gestiona todas desde el servidor)   |   Ayuda: aiws help
EOF
  others="$(other_instances | tr '\n' ' ')"
  if [[ -n "${others// /}" ]]; then
    warn "Hay otras instancias en este servidor: ${others}"
    warn "MEM_LIMIT ($(env_get MEM_LIMIT || true)) y CPUS de cada instancia se suman: revisa que el total quepa en el servidor."
  fi
}

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------ segundo plano
# Lo interactivo (auth key, clave SSH) se pregunta ANTES; lo largo (build) corre
# en una sesión propia (setsid + nohup), inmune al corte de SSH.
bg_running() { [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

run_bg() {   # run_bg <nombre> <paso-interno>
  local name="$1"; shift
  if bg_running; then
    warn "Ya hay un proceso en curso (PID $(cat "$PID_FILE")). Mostrando su progreso."
    follow; return 0
  fi
  install -d -m 700 "$LOG_DIR"
  local log="$LOG_DIR/$name-$(date +%Y%m%d-%H%M%S).log"
  : > "$log"; chmod 600 "$log"
  ln -sfn "$(basename "$log")" "$LOG_DIR/latest.log"
  rm -f "$PID_FILE" "$STATUS_FILE"

  if command -v setsid >/dev/null; then
    setsid nohup bash "$SCRIPT_DIR/setup.sh" __bg "$@" >> "$log" 2>&1 < /dev/null &
  else
    nohup bash "$SCRIPT_DIR/setup.sh" __bg "$@" >> "$log" 2>&1 < /dev/null &
  fi
  disown 2>/dev/null || true
  local _; for _ in $(seq 1 50); do [[ -s "$PID_FILE" ]] && break; sleep 0.1; done

  cat <<EOF

${c_ok}==> Ejecutándose en SEGUNDO PLANO${c_off} (PID $(cat "$PID_FILE" 2>/dev/null || echo '?')).
    Si se cae la conexión SSH o cierras la terminal, el proceso SIGUE.
    Volver a ver el progreso:  ./setup.sh progress
    Log completo:              logs/$(basename "$log")
    Ctrl+C solo deja de mostrar el log; NO detiene la instalación.

EOF
  follow
}

bg_entry() {   # se ejecuta dentro del proceso desacoplado
  echo $$ > "$PID_FILE"
  trap 'echo $? > "$STATUS_FILE"; rm -f "$PID_FILE"' EXIT
  export BUILDKIT_PROGRESS=plain        # salida legible en el log (sin TTY)
  echo "== $(date '+%F %T') inicio: $* (PID $$)"
  case "$1" in
    install_steps|update_steps) "$1" ;;
    *) die "Paso interno desconocido: $1" ;;
  esac
  echo "== $(date '+%F %T') fin OK"
}

follow() {
  local log="$LOG_DIR/latest.log" pid
  [[ -e "$log" ]] || { info "No hay procesos registrados todavía."; return 0; }
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  trap 'echo; info "Dejaste de ver el log; el proceso continúa. Retoma con: ./setup.sh progress"; exit 0' INT
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    tail -n +1 -F --pid="$pid" "$log" 2>/dev/null || true
  else
    tail -n 60 "$log" || true
  fi
  trap - INT
  report_status
}

report_status() {
  if bg_running; then info "Sigue en curso (PID $(cat "$PID_FILE")). ./setup.sh progress"; return 0; fi
  [[ -f "$STATUS_FILE" ]] || return 0
  local rc; rc="$(cat "$STATUS_FILE")"
  if [[ "$rc" == 0 ]]; then info "Último proceso: terminó correctamente."; return 0; fi
  echo "${c_err}[error]${c_off} Último proceso terminó con error (código $rc). Revisa: logs/latest.log" >&2
  exit "$rc"   # el estado real llega al llamador (aiws, scripts); exit evita el aviso genérico del trap ERR
}

# Clave SSH: se recoge en primer plano y se aplica al final del proceso en segundo plano
collect_pubkey() {
  local src="${1:-}" keys=""
  [[ -z "$src" && -f "$KEY_OK" ]] && return 0
  [[ -z "$src" ]] && src="$(default_pubkey)"
  if [[ "$src" == github:* ]]; then
    keys="$(curl -fsSL "https://github.com/${src#github:}.keys")" || die "No pude descargar las claves de ${src#github:}"
  elif [[ -n "$src" && -f "$src" ]]; then
    keys="$(cat "$src")"
  elif [[ -n "$src" ]]; then
    keys="$src"
  elif [[ -t 0 ]]; then
    cat <<EOF

Clave PÚBLICA SSH para entrar al workspace (una línea ssh-ed25519 / ssh-rsa / ecdsa-...)
  En tu PC Windows (PowerShell):  type \$env:USERPROFILE\.ssh\id_ed25519.pub
  ¿No tienes?  ssh-keygen -t ed25519   y luego el comando de arriba.
EOF
    read -rp "Clave pública (Enter para omitir): " keys || true
  fi
  [[ -z "$keys" ]] && { warn "Sin clave SSH: agrégala después con ./setup.sh add-key"; return 0; }
  [[ "$keys" == *"PRIVATE KEY"* ]] && die "Eso es una clave PRIVADA. Usa solo el contenido del archivo .pub"
  grep -qE '^(ssh-|ecdsa-|sk-)' <<<"$(tr -d '\r' <<<"$keys")" || die "No parece una clave pública SSH."
  install -d -m 700 "$LOG_DIR"
  ( umask 077; printf '%s\n' "$keys" | tr -d '\r' > "$PENDING_KEY" )
  info "Clave SSH recibida; se aplicará al terminar la instalación."
}

install_steps() {
  run_migrations
  create_volumes
  build_and_up
  forget_authkey
  if [[ -s "$PENDING_KEY" ]]; then
    add_key "$PENDING_KEY" && rm -f "$PENDING_KEY" && touch "$KEY_OK"
  elif docker exec "$CONTAINER" test -s "/home/$WS_USER/.ssh/authorized_keys"; then
    touch "$KEY_OK"
  else
    warn "Sin clave SSH autorizada. Agrégala con: ./setup.sh add-key"
  fi
  install_aiws_link || true
  doctor || warn "ws-doctor reportó problemas (revisa arriba)."
  summary
}

update_steps() { run_migrations; build_and_up --no-cache; clean; doctor || true; install_aiws_link || true; }

# Deja "aiws" en el PATH: enlace al aiws de este clon, en /usr/local/bin si se puede escribir ahí
# y si no en ~/.local/bin. Cualquier clon sirve (aiws descubre todas las instancias), así que un
# enlace existente a otro clon se respeta salvo que su destino ya no exista.
is_writable() { [[ -w "$1" ]]; }

# Avisa si aiws queda dentro de /root: otros usuarios del servidor no podrán usarlo
warn_root_clone() {
  if [[ "$(id -u)" == 0 && "$SCRIPT_DIR" == /root/* ]]; then
    warn "Este clon está en $SCRIPT_DIR: otros usuarios del servidor no podrán ejecutar aiws. Para compartirlo, clona en una ruta común (ej.: AIWS_DIR=/opt/ai-workspace)."
  fi
  return 0
}

install_aiws_link() {
  local src="$SCRIPT_DIR/aiws" sys="${AIWS_SYSTEM_BIN:-/usr/local/bin}" dir link target=""
  [[ -f "$src" ]] || return 0
  chmod +x "$src" 2>/dev/null || true
  # 1) un enlace vivo (a este u otro clon) se respeta; uno roto se rehace si se puede escribir
  for dir in "$sys" "$HOME/.local/bin"; do
    link="$dir/aiws"
    if [[ -L "$link" ]]; then
      [[ -e "$link" ]] && return 0
      if is_writable "$dir"; then ln -sfn "$src" "$link" && info "Enlace de aiws reparado: $link" && warn_root_clone; return 0; fi
      warn "El enlace $link está roto y no puedo escribir en $dir; pruebo con otra carpeta."
    elif [[ -e "$link" ]]; then
      warn "Ya existe $link y no es un enlace: no lo toco."
    elif [[ -z "$target" ]] && { is_writable "$dir" || [[ "$dir" == "$HOME/.local/bin" ]]; }; then
      target="$dir"                                  # primera carpeta libre y utilizable
    fi
  done
  [[ -n "$target" ]] || { warn "No encontré dónde instalar aiws. Enlázalo a mano: ln -s $src ~/.local/bin/aiws"; return 0; }
  mkdir -p "$target" 2>/dev/null || true
  ln -s "$src" "$target/aiws" || { warn "No pude crear el enlace de aiws en $target."; return 0; }
  info "Comando aiws instalado en $target/aiws (gestiona todas las instancias: aiws help)"
  if [[ ":$PATH:" != *":$target:"* ]]; then
    warn "$target no está en tu PATH. Agrégalo con:  echo 'export PATH=\"$target:\$PATH\"' >> ~/.bashrc  y abre una sesión nueva."
  fi
  warn_root_clone
}

# ------------------------------------------------------------ recursos por instancia
# MEM_LIMIT, CPUS, SHM_SIZE, PIDS_LIMIT y MSSQL_MEM_LIMIT son topes por instancia (no reservas).
# Se cambian sin reconstruir: "resources" los escribe en .env y recrea solo los contenedores de esta instancia.
SIZE_MEM=""; SIZE_CPUS=""     # --mem / --cpus de "install"

# Datos del servidor (AIWS_HOST_MEM_KB / AIWS_HOST_CPUS permiten fijarlos, p. ej. en pruebas)
host_mem_kb() {
  if [[ -n "${AIWS_HOST_MEM_KB:-}" ]]; then echo "$AIWS_HOST_MEM_KB"; return 0; fi
  awk '/^MemTotal:/ { print $2; f = 1 } END { if (!f) print 0 }' /proc/meminfo 2>/dev/null || echo 0
}
host_cpus() {
  if [[ -n "${AIWS_HOST_CPUS:-}" ]]; then echo "$AIWS_HOST_CPUS"; return 0; fi
  nproc 2>/dev/null || echo 1
}

ask_value() { local a=""; read -rp "$1" a || true; echo "$a"; }

# 512m, 4g, 1.5g, 4gb (sin distinguir mayúsculas) -> megabytes enteros; falla si no es un tamaño
mem_to_mb() {
  local v; v="$(tr 'A-Z' 'a-z' <<<"$1")"; v="${v%b}"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?[mg]$ ]] || return 1
  awk -v n="${v%[mg]}" -v u="${v: -1}" 'BEGIN { printf "%d\n", (u == "g" ? n * 1024 : n) }'
}

# res_check <VARIABLE> <valor>: valida y deja el valor normalizado en RES_VALUE.
# Errores a stderr (devuelve 1); avisos con warn, que no bloquean.
res_check() {
  local key="$1" v="$2" mb cpus
  RES_VALUE=""
  case "$key" in
    MEM_LIMIT|MSSQL_MEM_LIMIT)
      mb="$(mem_to_mb "$v")" || { echo "$key inválido '$v': usa un tamaño como 512m, 4g o 1.5g." >&2; return 1; }
      (( mb >= 1024 )) || { echo "$key demasiado bajo ($v): el mínimo es 1g." >&2; return 1; }
      if (( mb < 2048 )); then
        if [[ "$key" == MEM_LIMIT ]]; then warn "Con menos de 2g Chromium/Playwright y las compilaciones pueden quedarse sin memoria."
        else warn "SQL Server necesita alrededor de 2g para funcionar con comodidad."; fi
      fi
      RES_VALUE="$(tr 'A-Z' 'a-z' <<<"$v")"; RES_VALUE="${RES_VALUE%b}" ;;
    SHM_SIZE)
      mb="$(mem_to_mb "$v")" || { echo "SHM_SIZE inválido '$v': usa un tamaño como 512m o 1g." >&2; return 1; }
      (( mb > 0 )) || { echo "SHM_SIZE debe ser mayor que 0." >&2; return 1; }
      RES_VALUE="$(tr 'A-Z' 'a-z' <<<"$v")"; RES_VALUE="${RES_VALUE%b}" ;;
    CPUS)
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "CPUS inválido '$v': usa un número positivo (ej.: 2 o 1.5)." >&2; return 1; }
      cpus="$(host_cpus)"
      awk -v c="$v" 'BEGIN { exit !(c > 0) }' || { echo "CPUS debe ser mayor que 0." >&2; return 1; }
      awk -v c="$v" -v m="$cpus" 'BEGIN { exit !(c <= m) }' || { echo "CPUS ($v) supera las $cpus CPUs del servidor." >&2; return 1; }
      RES_VALUE="$v" ;;
    PIDS_LIMIT)
      [[ "$v" =~ ^[0-9]+$ ]] || { echo "PIDS_LIMIT inválido '$v': usa un entero." >&2; return 1; }
      (( v >= 256 )) || { echo "PIDS_LIMIT demasiado bajo ($v): el mínimo es 256." >&2; return 1; }
      RES_VALUE="$v" ;;
    *) echo "Variable de recursos desconocida: $key" >&2; return 1 ;;
  esac
}

# Carpetas de las demás instancias de este servidor (registro + clones ~/ai-workspace* con .env), sin la propia
other_instance_dirs() {
  local reg d canon self seen=""
  reg="$(registry_file)"; self="$(readlink -f "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")"
  while IFS= read -r d; do
    [[ -n "$d" && -f "$d/.env" ]] || continue
    canon="$(readlink -f "$d" 2>/dev/null || echo "$d")"
    [[ "$canon" == "$self" || "$seen" == *"|$canon|"* ]] && continue
    seen+="|$canon|"; echo "$d"
  done < <({ [[ -f "$reg" ]] && cat "$reg"; for d in "$HOME"/ai-workspace "$HOME"/ai-workspace-*; do [[ -f "$d/.env" ]] && echo "$d"; done; true; })
}

# Cuántas instancias hay ya además de esta (carpetas conocidas o contenedores)
existing_instance_count() {
  local dirs conts
  dirs="$(other_instance_dirs | wc -l | tr -d ' ')"; conts="$(other_instances | wc -l | tr -d ' ')"
  (( dirs > conts )) && echo "$dirs" || echo "$conts"
}

# Sugerencia de MEM_LIMIT: (RAM - 2g para el servidor) / (existentes + 1), entre 2g y 8g, en g enteros
suggest_mem() {
  local n="${1:-0}" kb per
  kb="$(host_mem_kb)"
  per=$(( (kb - 2 * 1048576) / (n + 1) / 1048576 ))
  (( per > 8 )) && per=8
  (( per < 2 )) && per=2
  echo "${per}g"
}
suggest_mem_is_tiny() {   # ¿ni siquiera caben 2g por instancia?
  local n="${1:-0}" kb; kb="$(host_mem_kb)"
  (( (kb - 2 * 1048576) / (n + 1) / 1048576 < 2 ))
}
suggest_cpus() { local c; c="$(host_cpus)"; (( c > 4 )) && c=4; echo "$c"; }

# Suma de MEM_LIMIT (en MB) de esta instancia (con el valor dado) y de las demás
sum_mem_limits_mb() {
  local own="${1:-$(env_get MEM_LIMIT)}" d v total=0 mb
  mb="$(mem_to_mb "${own:-8g}" || echo 0)"; total=$((total + mb))
  while IFS= read -r d; do
    v="$(grep -E '^MEM_LIMIT=' "$d/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    mb="$(mem_to_mb "${v:-8g}" || echo 0)"; total=$((total + mb))
  done < <(other_instance_dirs)
  echo "$total"
}
warn_mem_over_host() {
  local total host_mb; total="$(sum_mem_limits_mb "${1:-}")"; host_mb=$(( $(host_mem_kb) / 1024 ))
  if (( host_mb > 0 && total > host_mb )); then
    warn "La suma de MEM_LIMIT de las instancias ($((total / 1024))g) supera la RAM del servidor ($((host_mb / 1024))g). Son topes, no reservas: solo hay problema si varias instancias los usan a la vez."
  fi
  return 0
}

# Pregunta un valor con una sugerencia por defecto (3 intentos; si no, usa la sugerencia)
ask_res() {   # ask_res <VARIABLE> <etiqueta> <sugerido>: imprime el valor elegido
  local key="$1" label="$2" sug="$3" ans tries=0
  while (( tries < 3 )); do
    ans="$(ask_value "$label [$sug]: ")"; ans="${ans//[[:space:]]/}"; ans="${ans:-$sug}"
    if res_check "$key" "$ans" >&2; then echo "$RES_VALUE"; return 0; fi
    tries=$((tries + 1))
  done
  warn "Demasiados intentos inválidos: uso el valor sugerido ($sug)." ; echo "$sug"
}

# Dimensiona una instancia al instalar. Lo indicado con --mem/--cpus siempre se aplica; lo demás
# solo en un .env NUEVO (una instancia existente nunca cambia sus valores sola).
size_resources() {
  local is_new="$1" n mem cpus sm sc
  if [[ -n "$SIZE_MEM" ]]; then res_check MEM_LIMIT "$SIZE_MEM" || die "--mem inválido."; env_set MEM_LIMIT "$RES_VALUE"; fi
  if [[ -n "$SIZE_CPUS" ]]; then res_check CPUS "$SIZE_CPUS" || die "--cpus inválido."; env_set CPUS "$RES_VALUE"; fi
  [[ "$is_new" == true ]] || return 0
  n="$(existing_instance_count)"; sm="$(suggest_mem "$n")"; sc="$(suggest_cpus)"
  if suggest_mem_is_tiny "$n"; then
    warn "Este servidor tiene poca memoria para $((n + 1)) instancia(s): sugiero el mínimo (2g). Considera menos instancias o más RAM."
  fi
  if [[ -z "$SIZE_MEM" ]]; then
    if has_tty; then mem="$(ask_res MEM_LIMIT "Memoria máxima" "$sm")"
    else mem="$sm"; info "Memoria máxima sugerida: $sm (cámbiala después con ./setup.sh resources --mem ...)"; fi
    env_set MEM_LIMIT "$mem"
  fi
  if [[ -z "$SIZE_CPUS" ]]; then
    if has_tty; then cpus="$(ask_res CPUS "CPUs" "$sc")"
    else cpus="$sc"; info "CPUs sugeridas: $sc (cámbialas después con ./setup.sh resources --cpus ...)"; fi
    env_set CPUS "$cpus"
  fi
  warn_mem_over_host "$(env_get MEM_LIMIT)"
}

# Límites actuales y uso real de esta instancia
resources_show() {
  local mem cpus shm pids mmem usage mu cu hostgb
  mem="$(env_get MEM_LIMIT)"; cpus="$(env_get CPUS)"; shm="$(env_get SHM_SIZE)"; pids="$(env_get PIDS_LIMIT)"; mmem="$(env_get MSSQL_MEM_LIMIT)"
  mu="detenida"; cu="detenida"
  if usage="$(docker stats --no-stream --format '{{.MemUsage}}|{{.CPUPerc}}' "$CONTAINER" 2>/dev/null)" && [[ -n "$usage" ]]; then
    mu="${usage%%|*}"; cu="${usage##*|}"
  fi
  hostgb="$(awk -v k="$(host_mem_kb)" 'BEGIN { printf "%.0fg", k / 1048576 }')"
  cat <<EOF
Instancia ${AIWS_NAME}
  Memoria  : límite ${mem:-8g}   uso ${mu}
  CPUs     : límite ${cpus:-4}   uso ${cu}
  /dev/shm : ${shm:-2gb}   Procesos máx.: ${pids:-2048}$(profile_on mssql && echo "   SQL Server: ${mmem:-4g}")
  Servidor : ${hostgb} de RAM y $(host_cpus) CPUs (los límites son topes, no reservas)
Cambiar sin reconstruir: ./setup.sh resources --mem 4g --cpus 2   (o --set para elegir uno a uno)
EOF
}

# resources [--mem V] [--cpus V] [--shm V] [--pids V] [--mssql-mem V] [--no-apply] [--set]
resources() {
  local mem="" cpus="" shm="" pids="" mmem="" apply=true setmode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mem)        mem="${2:?falta el valor de --mem}"; shift 2 ;;
      --mem=*)      mem="${1#*=}"; shift ;;
      --cpus)       cpus="${2:?falta el valor de --cpus}"; shift 2 ;;
      --cpus=*)     cpus="${1#*=}"; shift ;;
      --shm)        shm="${2:?falta el valor de --shm}"; shift 2 ;;
      --shm=*)      shm="${1#*=}"; shift ;;
      --pids)       pids="${2:?falta el valor de --pids}"; shift 2 ;;
      --pids=*)     pids="${1#*=}"; shift ;;
      --mssql-mem)  mmem="${2:?falta el valor de --mssql-mem}"; shift 2 ;;
      --mssql-mem=*) mmem="${1#*=}"; shift ;;
      --no-apply)   apply=false; shift ;;
      --set)        setmode=true; shift ;;
      *) die "Opción desconocida: $1 (usa --mem, --cpus, --shm, --pids, --mssql-mem, --no-apply o --set)" ;;
    esac
  done
  [[ -f "$ENV_FILE" ]] || die "Esta instancia aún no está instalada (no hay .env): ejecuta ./setup.sh install"

  if [[ "$setmode" == true ]]; then
    has_tty || die "--set pregunta uno a uno y necesita una terminal; sin ella usa --mem, --cpus, etc."
    resources_show; echo
    local cur sug n; n="$(existing_instance_count)"
    sug="$(suggest_mem "$n")"; cur="$(env_get MEM_LIMIT)"; cur="${cur:-8g}"
    mem="$(res_prompt MEM_LIMIT "Memoria máxima" "$cur" "$sug")"
    sug="$(suggest_cpus)"; cur="$(env_get CPUS)"; cur="${cur:-4}"
    cpus="$(res_prompt CPUS "CPUs" "$cur" "$sug")"
    cur="$(env_get SHM_SIZE)"; shm="$(res_prompt SHM_SIZE "Memoria compartida (/dev/shm)" "${cur:-2gb}" "2gb")"
    cur="$(env_get PIDS_LIMIT)"; pids="$(res_prompt PIDS_LIMIT "Máximo de procesos" "${cur:-2048}" "2048")"
    if profile_on mssql; then cur="$(env_get MSSQL_MEM_LIMIT)"; mmem="$(res_prompt MSSQL_MEM_LIMIT "Memoria de SQL Server" "${cur:-4g}" "4g")"; fi
  fi

  if [[ -z "$mem$cpus$shm$pids$mmem" ]]; then resources_show; return 0; fi

  # Validar todo antes de escribir nada
  local k v
  local -a keys=() vals=()
  for k in MEM_LIMIT:"$mem" CPUS:"$cpus" SHM_SIZE:"$shm" PIDS_LIMIT:"$pids" MSSQL_MEM_LIMIT:"$mmem"; do
    v="${k#*:}"; k="${k%%:*}"
    [[ -n "$v" ]] || continue
    res_check "$k" "$v" || die "No se cambió nada."
    keys+=("$k"); vals+=("$RES_VALUE")
  done
  local i
  for i in "${!keys[@]}"; do env_set "${keys[i]}" "${vals[i]}"; info "${keys[i]}=${vals[i]}"; done
  warn_mem_over_host "$(env_get MEM_LIMIT)"
  [[ "$apply" == true ]] || { info "Guardado en .env (sin aplicar). Aplícalo con: ./setup.sh resources --mem ... o recreando con compose."; return 0; }
  resources_apply
}

# En --set: Enter conserva el valor actual; se muestra también la sugerencia. Imprime el valor o nada si no cambia.
res_prompt() {   # res_prompt <VARIABLE> <etiqueta> <actual> <sugerido>
  local key="$1" label="$2" cur="$3" sug="$4" ans tries=0
  while (( tries < 3 )); do
    ans="$(ask_value "$label (actual $cur, sugerido $sug) [$cur]: ")"; ans="${ans//[[:space:]]/}"
    if [[ -z "$ans" || "$ans" == "$cur" ]]; then return 0; fi
    if res_check "$key" "$ans" >&2; then echo "$RES_VALUE"; return 0; fi
    tries=$((tries + 1))
  done
  warn "Demasiados intentos inválidos: conservo $cur." >&2
}

# Recrea solo los contenedores de esta instancia con los límites nuevos: segundos, sin reconstruir
resources_apply() {
  if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    info "Guardado. Se aplicará cuando la instancia se instale o se levante."; return 0
  fi
  info "Aplicando solo en $AIWS_NAME (se recrean sus contenedores; la imagen no se reconstruye)..."
  compose up -d --no-build
  wait_healthy "$TS_CONTAINER"
  wait_healthy "$CONTAINER"
  info "Listo."
}

# ------------------------------------------------------------ componentes
# Formato: VARIABLE|Nombre|Por defecto|Descripción
COMPONENTS=(
  "INSTALL_CLAUDE|Claude Code|true|agente de Anthropic (claude)"
  "INSTALL_PI|Pi|true|agente pi-coding-agent"
  "INSTALL_OPENCODE|opencode|false|agente opencode (opencode-ai)"
  "INSTALL_AGY|Antigravity CLI|true|agente de Google (agy)"
  "INSTALL_GENTLE_AI|Gentle AI|true|memoria y flujos para tus agentes (gentle-ai)"
  "INSTALL_HERDR|Herdr|true|sesiones de agentes persistentes (herdr)"
  "INSTALL_PLAYWRIGHT|Playwright|true|navegador para agentes: playwright, -cli, -mcp + Chromium (~600 MB)"
  "INSTALL_DOPPLER|Doppler CLI|true|gestor de secretos (doppler)"
  "INSTALL_MSSQL_TOOLS|SQL Server tools|false|sqlcmd y bcp (mssql-tools18)"
)

comp_value() {   # valor actual (o el defecto) de un componente
  local var="$1" def="$2" v; v="$(env_get "$var")"
  [[ "$v" == true || "$v" == false ]] && echo "$v" || echo "$def"
}

# Menú de selección. Devuelve 0 si se guardaron cambios.
choose_components() {
  local -a vars names defs descs vals
  local i entry n="${#COMPONENTS[@]}"
  for i in "${!COMPONENTS[@]}"; do
    IFS='|' read -r vars[i] names[i] defs[i] descs[i] <<< "${COMPONENTS[i]}"
    vals[i]="$(comp_value "${vars[i]}" "${defs[i]}")"
  done
  local orig=("${vals[@]}") input tok
  while true; do
    echo
    echo "${c_ok}Componentes de la imagen${c_off} (lo base siempre viene: git, gh, Node, Python/uv, mise, psql, devdb, zsh...)"
    for i in "${!vars[@]}"; do
      local mark="[ ]"; [[ "${vals[i]}" == true ]] && mark="[x]"
      printf '  %2d) %s %-17s %s\n' "$((i+1))" "$mark" "${names[i]}" "${descs[i]}"
    done
    echo "  Escribe números para marcar/desmarcar (ej: 3 7), a=todos, n=ninguno, d=por defecto,"
    read -rp "  Enter=guardar, q=cancelar: " input || input=q
    case "$input" in
      "") break ;;
      q|Q) info "Sin cambios."; return 1 ;;
      a|A) for i in "${!vals[@]}"; do vals[i]=true; done ;;
      n|N) for i in "${!vals[@]}"; do vals[i]=false; done ;;
      d|D) for i in "${!vals[@]}"; do vals[i]="${defs[i]}"; done ;;
      *) for tok in $input; do
           if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
             i=$((tok-1)); [[ "${vals[i]}" == true ]] && vals[i]=false || vals[i]=true
           else warn "Opción inválida: $tok"; fi
         done ;;
    esac
  done
  local changed=false
  for i in "${!vars[@]}"; do
    env_set "${vars[i]}" "${vals[i]}"
    [[ "${vals[i]}" != "${orig[i]}" ]] && changed=true
  done
  info "Componentes guardados en .env"
  [[ "$changed" == true ]]
}

components_cmd() {
  [[ -f "$ENV_FILE" ]] || { cp "$ENV_EXAMPLE" "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  if choose_components; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      confirm "¿Reconstruir ahora para aplicar los cambios?" && exec bash "$SCRIPT_DIR/setup.sh" update
      info "Aplícalos cuando quieras con: ./setup.sh update"
    fi
  fi
  return 0
}

# ------------------------------------------------------------ migraciones
# migrations/NNN-descripcion.sh: cada una corre UNA vez por servidor, en orden.
# Sirven para quitar lo obsoleto o renombrar cosas entre versiones (escalable:
# cada mejora futura que necesite limpiar algo agrega su propio archivo).
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"
MIGRATIONS_DONE="$LOG_DIR/.migrations-done"

run_migrations() {
  [[ -d "$MIGRATIONS_DIR" ]] || return 0
  install -d -m 700 "$LOG_DIR"; touch "$MIGRATIONS_DONE"
  local f name n=0
  for f in "$MIGRATIONS_DIR"/[0-9][0-9][0-9]-*.sh; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f")"
    grep -qxF "$name" "$MIGRATIONS_DONE" && continue
    info "Migración $name"
    # Subproceso con las funciones de setup.sh disponibles (info, warn, env_get/set/del, compose...)
    if bash -c 'set -Eeuo pipefail; source "$1"; source "$2"' _ "$SCRIPT_DIR/setup.sh" "$f"; then
      echo "$name" >> "$MIGRATIONS_DONE"; n=$((n+1))
    else
      die "La migración $name falló. Corrige y vuelve a ejecutar (las anteriores ya quedaron aplicadas)."
    fi
  done
  (( n > 0 )) && info "$n migración(es) aplicadas." || true
}

# ------------------------------------------------------------ limpieza
LOG_KEEP="${AIWS_LOG_KEEP:-20}"
BACKUP_KEEP="${AIWS_BACKUP_KEEP:-5}"

keep_newest() {   # keep_newest <dir> <patrón> <n>: borra los más viejos
  local dir="$1" pat="$2" keep="$3" f
  [[ -d "$dir" ]] || return 0
  ls -1t "$dir"/$pat 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    rm -f -- "$f" && echo "    borrado: ${f#$SCRIPT_DIR/}"
  done
}

clean() {
  local deep=false; [[ "${1:-}" == --deep ]] && deep=true
  info "Limpiando imágenes viejas de $AIWS_NAME (capas sin etiqueta tras reconstruir)..."
  local -a flt=(--filter "label=org.ai-workspace.image=true")
  [[ -n "$INSTANCE" ]] && flt+=(--filter "label=org.ai-workspace.instance=$AIWS_NAME")   # solo las de esta instancia
  docker image prune -f "${flt[@]}" | tail -n1 || true
  info "Logs: se conservan los últimos $LOG_KEEP"
  keep_newest "$LOG_DIR" '*-[0-9]*.log' "$LOG_KEEP"
  info "Respaldos: se conservan los últimos $BACKUP_KEEP"
  keep_newest "$SCRIPT_DIR/backups" "$AIWS_NAME-[0-9]*.tar.gz" "$BACKUP_KEEP"
  if [[ "$deep" == true ]]; then
    warn "Limpieza profunda: caché de build de Docker e imágenes sin uso (afecta a TODO Docker del servidor)."
    if confirm "¿Continuar?"; then
      docker builder prune -f | tail -n1 || true
      docker image prune -f | tail -n1 || true
    fi
  fi
  docker system df 2>/dev/null | sed 's/^/    /' || true
}

# ------------------------------------------------------------ actualizar desde GitHub
g() { git --no-pager -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" "$@"; }

has_tty() { [[ -t 0 ]]; }
# Reconstruye con el setup.sh recién descargado (proceso nuevo); aparte para poder probar upgrade
run_update() { exec bash "$SCRIPT_DIR/setup.sh" update "$@"; }
# aiws pasa AIWS_UPGRADE_RESULT_FILE para saber si la instancia se actualizó o ya estaba al día
upgrade_result() { if [[ -n "${AIWS_UPGRADE_RESULT_FILE:-}" ]]; then echo "$1" > "$AIWS_UPGRADE_RESULT_FILE" 2>/dev/null || true; fi; return 0; }

# upgrade [--yes|-y] [--rebuild] [--foreground]
#   --yes         sin preguntas: guarda cambios locales (git stash), actualiza y reconstruye
#   --rebuild     con --yes, reconstruye aunque ya esté al día
#   --foreground  se pasa a "update" (sin segundo plano)
# Sin --yes pregunta cada paso (requiere terminal; sin ella falla en vez de aparentar éxito).
upgrade() {
  local yes=false rebuild=false fg=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)     yes=true ;;
      --rebuild)    rebuild=true ;;
      --foreground) fg=(--foreground) ;;
      *) die "Opción desconocida para upgrade: $1 (usa --yes, --rebuild o --foreground)" ;;
    esac
    shift
  done
  command -v git >/dev/null || die "Falta git en el servidor."
  if [[ "$yes" != true ]] && ! has_tty; then
    die "upgrade necesita responder preguntas y no hay terminal: usa ./setup.sh upgrade --yes (actualiza y reconstruye sin preguntar)."
  fi
  registry_add
  if bg_running; then warn "Hay una instalación en curso; espera a que termine."; follow; return 0; fi

  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    cat <<EOF
Esta carpeta no viene de git (la copiaste a mano). Se conectará a:
  $REPO_URL ($REPO_BRANCH)
Se conservan .env, logs/ y backups/. Los archivos del proyecto se reemplazan por los del repo
(si personalizaste config/packages.apt u otros, guarda una copia antes).
EOF
    if [[ "$yes" != true ]]; then confirm "¿Continuar?" || { info "Cancelado."; return 0; }; fi
    g init -q
    g config core.fileMode false          # chmod +x local no cuenta como "cambio"
    g remote add origin "$REPO_URL" 2>/dev/null || g remote set-url origin "$REPO_URL"
    g fetch -q origin "$REPO_BRANCH" || die "No pude descargar $REPO_URL (¿repo privado? usa: gh auth login / gh repo clone)"
    g reset -q --hard "origin/$REPO_BRANCH"
    g branch -q -M "$REPO_BRANCH"
    g branch -q --set-upstream-to="origin/$REPO_BRANCH" "$REPO_BRANCH"
    info "Carpeta conectada a GitHub: $(g log -1 --format='%h %s (%cr)')"
  else
    g config core.fileMode false
    g fetch -q origin "$REPO_BRANCH" || die "No pude contactar $REPO_URL"
    local behind; behind="$(g rev-list --count "HEAD..origin/$REPO_BRANCH")"
    if [[ "$behind" == 0 ]]; then
      info "Ya tienes la última versión (ya al día): $(g log -1 --format='%h %s (%cr)')"
      upgrade_result uptodate
      if [[ "$yes" == true ]]; then
        [[ "$rebuild" == true ]] && run_update ${fg[@]+"${fg[@]}"}
        return 0
      fi
      confirm "¿Reconstruir de todos modos (actualiza paquetes y herramientas)?" && run_update ${fg[@]+"${fg[@]}"}
      return 0
    fi
    echo "${c_ok}Cambios nuevos ($behind):${c_off}"
    g log --format='  %h %s (%cr)' "HEAD..origin/$REPO_BRANCH"
    g diff --stat "HEAD" "origin/$REPO_BRANCH" | tail -n 15
    if [[ -n "$(g status --porcelain --untracked-files=no)" ]]; then
      warn "Tienes cambios locales en archivos del repo:"; g status --short --untracked-files=no
      if [[ "$yes" != true ]]; then confirm "¿Guardarlos aparte (git stash) y actualizar?" || { info "Cancelado."; return 0; }; fi
      g stash push -q -m "setup.sh upgrade $(date +%F_%T)"
      info "Tus cambios quedaron guardados: git stash list  (recupéralos con: git stash pop)"
    fi
    install -d -m 700 "$LOG_DIR"; g rev-parse HEAD > "$LOG_DIR/.prev-version"   # para rollback
    g merge -q --ff-only "origin/$REPO_BRANCH" || die "No se pudo actualizar sin conflictos (git status)."
    info "Archivos actualizados a: $(g log -1 --format='%h %s')"
  fi
  upgrade_result updated

  normalize_line_endings
  run_migrations
  if [[ ! -f "$ENV_FILE" ]]; then
    info "No hay .env todavía: ejecuta ./setup.sh install"
    return 0
  fi
  # Variables nuevas de env.example que falten en tu .env (sin tocar las existentes)
  local line key added=0
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
    key="${BASH_REMATCH[1]}"
    if ! grep -qE "^${key}=" "$ENV_FILE"; then echo "$line" >> "$ENV_FILE"; added=$((added+1)); fi
  done < "$ENV_EXAMPLE"
  (( added > 0 )) && info "$added variable(s) nuevas agregadas a .env desde env.example"
  if [[ "$yes" == true ]] || confirm "¿Reconstruir ahora la imagen con los cambios? (recomendado)"; then
    run_update ${fg[@]+"${fg[@]}"}
    return 0
  fi
  info "Cuando quieras aplicarlos: ./setup.sh update"
}

rollback() {
  [[ -d "$SCRIPT_DIR/.git" && -s "$LOG_DIR/.prev-version" ]] || die "No hay una versión anterior registrada (solo existe tras un upgrade)."
  local prev; prev="$(cat "$LOG_DIR/.prev-version")"
  echo "Volver de $(g log -1 --format='%h %s') a $(g log -1 --format='%h %s' "$prev")"
  confirm "¿Continuar? (luego se reconstruye la imagen)" || { info "Cancelado."; return 0; }
  g reset -q --hard "$prev"
  info "Archivos de vuelta en $(g log -1 --format='%h %s'). Para volver a lo último: ./setup.sh upgrade"
  exec bash "$SCRIPT_DIR/setup.sh" update
}

# ------------------------------------------------------------ respaldo / desinstalación
confirm() {   # confirm "pregunta" -> 0 si responde s/S
  local ans; read -rp "$1 [s/N]: " ans || true
  [[ "$ans" =~ ^[sSyY]$ ]]
}

backup() {
  local dest="$SCRIPT_DIR/backups" file v mounts=()
  for v in "${VOLUMES[@]}"; do
    docker volume inspect "$v" >/dev/null 2>&1 && mounts+=(-v "$v:/v/$v:ro")
  done
  (( ${#mounts[@]} )) || { warn "No hay volúmenes de datos que respaldar."; return 0; }
  mkdir -p "$dest"; chmod 700 "$dest"
  file="$AIWS_NAME-$(date +%Y%m%d-%H%M%S).tar.gz"
  # Si PostgreSQL local está corriendo, se detiene para un respaldo consistente
  docker exec -u "$WS_USER" "$CONTAINER" devdb stop all >/dev/null 2>&1 || true
  info "Respaldando home y proyectos -> backups/$file"
  docker run --rm "${mounts[@]}" -v "$dest:/b" --entrypoint tar \
    "$(docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "$IMAGE" || echo debian:12-slim)" \
    czf "/b/$file" -C /v .
  chmod 600 "$dest/$file" 2>/dev/null || true
  docker exec -u "$WS_USER" "$CONTAINER" devdb autostart >/dev/null 2>&1 || true   # reanuda BD con autostart
  info "Respaldo listo: $dest/$file ($(du -h "$dest/$file" | cut -f1))"
  keep_newest "$dest" "$AIWS_NAME-[0-9]*.tar.gz" "$BACKUP_KEEP"
  local restore_mounts=""
  for v in "${VOLUMES[@]}"; do restore_mounts+="-v $v:/v/$v "; done
  echo "    Restaurar: docker run --rm ${restore_mounts}-v \$PWD/backups:/b debian:12-slim tar xzf /b/$file -C /v"
}

uninstall() {
  local all=false yes=false
  for a in "$@"; do
    case "$a" in
      --all|--purge) all=true ;;
      --yes|-y)      yes=true ;;
      *) die "Opción desconocida: $a" ;;
    esac
  done

  if [[ "$all" == false ]]; then
    echo "Se eliminarán contenedores, red e imagen. Se CONSERVAN: home, proyectos, BD locales, identidad SSH y Tailscale, .env."
    [[ "$yes" == true ]] || confirm "¿Continuar?" || { info "Cancelado."; return 0; }
    compose --profile mssql down --remove-orphans || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    registry_remove
    info "Desinstalado. Para volver: ./setup.sh install (los datos siguen ahí)."
    return 0
  fi

  cat <<EOF
${c_err}DESINSTALAR TODO${c_off} — se borrará de forma PERMANENTE:
  - Proyectos (/workspace) y home del usuario (configuración, herramientas, BD locales de devdb)
  - Identidad SSH del servidor y nodo de Tailscale
  - SQL Server (si existía), imagen, contenedores, red y el archivo .env
  Los respaldos en ./backups NO se borran.
EOF
  if [[ "$yes" != true ]]; then
    if confirm "¿Hacer un respaldo antes de borrar? (recomendado)"; then backup; fi
    local word; read -rp "Escribe BORRAR para confirmar: " word || true
    [[ "$word" == "BORRAR" ]] || { info "Cancelado. No se borró nada."; return 0; }
  fi

  # Quitar el equipo de la tailnet antes de destruir su identidad
  docker exec "$TS_CONTAINER" tailscale logout >/dev/null 2>&1 \
    && info "Sesión de Tailscale cerrada (si el equipo sigue en el panel, bórralo allí)." || true
  compose --profile mssql down --remove-orphans || true
  local v
  for v in "${ALL_VOLUMES[@]}"; do
    docker volume rm "$v" >/dev/null 2>&1 && info "Volumen $v eliminado" || true
  done
  docker image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
  registry_remove
  info "Todo eliminado. Los archivos de esta carpeta quedan para reinstalar con ./setup.sh install"
}

menu() {
  local running=false
  bg_running && running=true
  echo
  echo "${c_ok}${AIWS_NAME}${c_off} — ¿qué quieres hacer?"
  if [[ -d "$SCRIPT_DIR/.git" ]]; then echo "  versión: $(g log -1 --format='%h %s (%cr)' 2>/dev/null)"; fi
  if [[ "$running" == true ]]; then
    echo "  ${c_warn}>> Hay una instalación/actualización EN CURSO (PID $(cat "$PID_FILE")). Usa la opción 3 para verla.${c_off}"
  fi
  cat <<EOF
  1) Instalar / reinstalar
  2) Actualizar a la última versión (GitHub) y reconstruir
  3) Ver progreso de la instalación (o el resultado de la última)
  4) Elegir componentes (qué agentes y herramientas se instalan)
  5) Estado y diagnóstico
  6) Agregar clave SSH
  7) Respaldar datos (home + proyectos)
  8) Limpiar (imágenes viejas, logs y respaldos antiguos)
  9) Desinstalar (conserva datos)
 10) Desinstalar TODO (borra datos)
  0) Salir
EOF
  local opt def=""; [[ "$running" == true ]] && def=3
  read -rp "Opción${def:+ [$def]}: " opt || true
  opt="${opt:-$def}"
  case "$opt" in
    1) main install ;;
    2) main upgrade ;;
    3) main progress ;;
    4) main components ;;
    5) compose ps; doctor || true ;;
    6) main add-key ;;
    7) main backup ;;
    8) main clean ;;
    9) main uninstall ;;
    10) main uninstall --all ;;
    *) info "Nada que hacer." ;;
  esac
}

# ------------------------------------------------------------------------ main
main() {
  local cmd="${1:-}"; shift || true
  if [[ -z "$cmd" ]]; then
    if [[ -t 0 ]]; then menu; return; else cmd=install; fi   # sin terminal: instala
  fi

  case "$cmd" in
    install)
      local pubkey="" authkey="" fg=false alias_set=false alias_arg=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --alias)      alias_arg="${2:?falta el alias}"; alias_set=true; shift 2 ;;
          --mem)        SIZE_MEM="${2:?falta el tamaño (ej.: --mem 4g)}"; shift 2 ;;
          --mem=*)      SIZE_MEM="${1#*=}"; shift ;;
          --cpus)       SIZE_CPUS="${2:?falta el número de CPUs (ej.: --cpus 2)}"; shift 2 ;;
          --cpus=*)     SIZE_CPUS="${1#*=}"; shift ;;
          --pubkey)     pubkey="${2:?falta ruta o clave}"; shift 2 ;;
          --authkey)    authkey="${2:?falta key}"; shift 2 ;;
          --foreground) fg=true; shift ;;
          *) die "Opción desconocida: $1" ;;
        esac
      done
      if bg_running; then warn "Ya hay una instalación en curso."; follow; return 0; fi
      # 1) Preguntas (rápido, en primer plano)
      check_prereqs
      check_files
      normalize_line_endings
      if [[ "$alias_set" == true ]]; then bind_alias "$alias_arg"; fi
      check_instance_owner
      configure_env "$authkey"
      registry_add
      collect_pubkey "$pubkey"
      # 2) Lo largo: en segundo plano, inmune al corte de SSH
      if [[ "$fg" == true ]]; then install_steps; else run_bg install install_steps; fi
      ;;
    update)
      check_prereqs; check_files; normalize_line_endings
      if [[ "${1:-}" == --foreground ]]; then update_steps; else run_bg update update_steps; fi ;;
    progress)  follow ;;
    resources) resources "$@" ;;
    upgrade|self-update) check_prereqs; upgrade "$@" ;;
    rollback)  check_prereqs; rollback ;;
    clean)     check_prereqs; clean "$@" ;;
    components) components_cmd ;;
    migrate)   run_migrations ;;
    __bg)      bg_entry "$@" ;;
    add-key)   add_key "${1:-}" ;;
    status)    compose ps ;;
    logs)      compose logs -f --tail 100 ;;
    shell)     docker exec -it -u "$WS_USER" "$CONTAINER" zsh -l ;;
    psql)      docker exec -it -u "$WS_USER" "$CONTAINER" zsh -lc 'devdb psql' ;;
    doctor)    doctor ;;
    ts-status) docker exec "$TS_CONTAINER" tailscale status ;;
    backup)    check_prereqs; backup ;;
    uninstall) check_prereqs; uninstall "$@" ;;
    purge)     check_prereqs; uninstall --all "$@" ;;
    down)      compose down; info "Contenedores detenidos. Volúmenes (datos e identidad Tailscale) se conservan." ;;
    -h|--help|help) usage ;;
    *) usage; die "Comando desconocido: $cmd" ;;
  esac
}

# Permite "source setup.sh" en pruebas sin ejecutar nada
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
