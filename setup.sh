#!/usr/bin/env bash
# =============================================================================
# ai-workspace - instalador / operador en un solo script
#
#   ./setup.sh                       Menú interactivo (instalar, desinstalar, estado...)
#   ./setup.sh install [--pubkey RUTA.pub|'ssh-ed25519 ...'] [--authkey tskey-auth-...] [--foreground]
#                                    Pide lo que falte y luego sigue en SEGUNDO PLANO:
#                                    si se cae SSH, la instalación continúa.
#   ./setup.sh progress              Ver el progreso / resultado del último proceso
#   ./setup.sh upgrade               Descarga lo último de GitHub (git), migra y reconstruye
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

CONTAINER="ai-workspace"
TS_CONTAINER="ai-workspace-ts"
TS_VOLUME="ai_ts_state"
WS_USER="ai"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/env.example"
VOLUMES=(ai_home ai_workspace)
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
  if [[ -f "$ENV_FILE" ]]; then docker compose --env-file "$ENV_FILE" "$@"; else docker compose "$@"; fi
}

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
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
  local authkey="${1:-}"

  if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$ENV_EXAMPLE" ]] || die "Falta env.example"
    cp "$ENV_EXAMPLE" "$ENV_FILE"; chmod 600 "$ENV_FILE"
    info ".env creado desde env.example"
  fi

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
  info "Configuración lista en .env (TS_HOSTNAME=$(env_get TS_HOSTNAME), servicios: $(env_get COMPOSE_PROFILES))"
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
  local host ip profiles; host="$(env_get TS_HOSTNAME)"; host="${host:-ai-workspace}"; ip="$(ts_ip)"
  profiles="$(env_get COMPOSE_PROFILES)"
  cat <<EOF

${c_ok}Listo.${c_off} Accesible SOLO desde tu tailnet (nada publicado en el servidor).
  Equipo: ${host}  (IP Tailscale: ${ip:-?})
  SSH   : ssh ${WS_USER}@${host}
  Mosh  : mosh -p 60000:60010 ${WS_USER}@${host}
  Web   : http://${host}:3000  |  http://${host}:5173   (el dev server debe escuchar en 0.0.0.0)
  BD local : dentro del workspace -> devdb start (PostgreSQL) | devdb start redis | devdb enable (autoarranque)
  Extra    : ${profiles:-ninguno}   (mssql = SQL Server en contenedor aparte)
  GitHub   : dentro del workspace ejecuta  gh auth login  (queda guardado en el volumen)
  Diagnóstico: ./setup.sh doctor   |   Estado Tailscale: ./setup.sh ts-status
EOF
}

usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; }

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
  if [[ "$rc" == 0 ]]; then info "Último proceso: terminó correctamente."
  else echo "${c_err}[error]${c_off} Último proceso terminó con error (código $rc). Revisa: logs/latest.log" >&2; fi
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
  doctor || warn "ws-doctor reportó problemas (revisa arriba)."
  summary
}

update_steps() { run_migrations; build_and_up --no-cache; clean; doctor || true; }

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
  info "Limpiando imágenes viejas de ai-workspace (capas sin etiqueta tras reconstruir)..."
  docker image prune -f --filter "label=org.ai-workspace.image=true" | tail -n1 || true
  info "Logs: se conservan los últimos $LOG_KEEP"
  keep_newest "$LOG_DIR" '*-[0-9]*.log' "$LOG_KEEP"
  info "Respaldos: se conservan los últimos $BACKUP_KEEP"
  keep_newest "$SCRIPT_DIR/backups" 'ai-workspace-*.tar.gz' "$BACKUP_KEEP"
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
g() { git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" "$@"; }

upgrade() {
  command -v git >/dev/null || die "Falta git en el servidor."
  if bg_running; then warn "Hay una instalación en curso; espera a que termine."; follow; return 0; fi

  if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    cat <<EOF
Esta carpeta no viene de git (la copiaste a mano). Se conectará a:
  $REPO_URL ($REPO_BRANCH)
Se conservan .env, logs/ y backups/. Los archivos del proyecto se reemplazan por los del repo
(si personalizaste config/packages.apt u otros, guarda una copia antes).
EOF
    confirm "¿Continuar?" || { info "Cancelado."; return 0; }
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
      info "Ya tienes la última versión: $(g log -1 --format='%h %s (%cr)')"
      confirm "¿Reconstruir de todos modos (actualiza paquetes y herramientas)?" && exec bash "$SCRIPT_DIR/setup.sh" update
      return 0
    fi
    echo "${c_ok}Cambios nuevos ($behind):${c_off}"
    g log --format='  %h %s (%cr)' "HEAD..origin/$REPO_BRANCH"
    g diff --stat "HEAD" "origin/$REPO_BRANCH" | tail -n 15
    if [[ -n "$(g status --porcelain --untracked-files=no)" ]]; then
      warn "Tienes cambios locales en archivos del repo:"; g status --short --untracked-files=no
      confirm "¿Guardarlos aparte (git stash) y actualizar?" || { info "Cancelado."; return 0; }
      g stash push -q -m "setup.sh upgrade $(date +%F_%T)"
      info "Tus cambios quedaron guardados: git stash list  (recupéralos con: git stash pop)"
    fi
    install -d -m 700 "$LOG_DIR"; g rev-parse HEAD > "$LOG_DIR/.prev-version"   # para rollback
    g merge -q --ff-only "origin/$REPO_BRANCH" || die "No se pudo actualizar sin conflictos (git status)."
    info "Archivos actualizados a: $(g log -1 --format='%h %s')"
  fi

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
  if confirm "¿Reconstruir ahora la imagen con los cambios? (recomendado)"; then
    exec bash "$SCRIPT_DIR/setup.sh" update   # proceso nuevo: usa el setup.sh recién descargado
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
ALL_VOLUMES=(ai_home ai_workspace ai_ssh_host_keys ai_ts_state ai_mssql_data)

confirm() {   # confirm "pregunta" -> 0 si responde s/S
  local ans; read -rp "$1 [s/N]: " ans || true
  [[ "$ans" =~ ^[sSyY]$ ]]
}

backup() {
  local dest="$SCRIPT_DIR/backups" file v mounts=()
  for v in ai_home ai_workspace; do
    docker volume inspect "$v" >/dev/null 2>&1 && mounts+=(-v "$v:/v/$v:ro")
  done
  (( ${#mounts[@]} )) || { warn "No hay volúmenes de datos que respaldar."; return 0; }
  mkdir -p "$dest"; chmod 700 "$dest"
  file="ai-workspace-$(date +%Y%m%d-%H%M%S).tar.gz"
  # Si PostgreSQL local está corriendo, se detiene para un respaldo consistente
  docker exec -u "$WS_USER" "$CONTAINER" devdb stop all >/dev/null 2>&1 || true
  info "Respaldando home y proyectos -> backups/$file"
  docker run --rm "${mounts[@]}" -v "$dest:/b" --entrypoint tar \
    "$(docker image inspect ai-workspace:latest >/dev/null 2>&1 && echo ai-workspace:latest || echo debian:12-slim)" \
    czf "/b/$file" -C /v .
  chmod 600 "$dest/$file" 2>/dev/null || true
  docker exec -u "$WS_USER" "$CONTAINER" devdb autostart >/dev/null 2>&1 || true   # reanuda BD con autostart
  info "Respaldo listo: $dest/$file ($(du -h "$dest/$file" | cut -f1))"
  keep_newest "$dest" 'ai-workspace-*.tar.gz' "$BACKUP_KEEP"
  echo "    Restaurar: docker run --rm -v ai_home:/v/ai_home -v ai_workspace:/v/ai_workspace -v \$PWD/backups:/b debian:12-slim tar xzf /b/$file -C /v"
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
    docker image rm ai-workspace:latest >/dev/null 2>&1 || true
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
  docker image rm ai-workspace:latest >/dev/null 2>&1 || true
  rm -f "$ENV_FILE"
  info "Todo eliminado. Los archivos de esta carpeta quedan para reinstalar con ./setup.sh install"
}

menu() {
  local running=false
  bg_running && running=true
  echo
  echo "${c_ok}ai-workspace${c_off} — ¿qué quieres hacer?"
  if [[ -d "$SCRIPT_DIR/.git" ]]; then echo "  versión: $(g log -1 --format='%h %s (%cr)' 2>/dev/null)"; fi
  if [[ "$running" == true ]]; then
    echo "  ${c_warn}>> Hay una instalación/actualización EN CURSO (PID $(cat "$PID_FILE")). Usa la opción 3 para verla.${c_off}"
  fi
  cat <<EOF
  1) Instalar / reinstalar
  2) Actualizar a la última versión (GitHub) y reconstruir
  3) Ver progreso de la instalación (o el resultado de la última)
  4) Estado y diagnóstico
  5) Agregar clave SSH
  6) Respaldar datos (home + proyectos)
  7) Limpiar (imágenes viejas, logs y respaldos antiguos)
  8) Desinstalar (conserva datos)
  9) Desinstalar TODO (borra datos)
  0) Salir
EOF
  local opt def=""; [[ "$running" == true ]] && def=3
  read -rp "Opción${def:+ [$def]}: " opt || true
  opt="${opt:-$def}"
  case "$opt" in
    1) main install ;;
    2) main upgrade ;;
    3) main progress ;;
    4) compose ps; doctor || true ;;
    5) main add-key ;;
    6) main backup ;;
    7) main clean ;;
    8) main uninstall ;;
    9) main uninstall --all ;;
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
      local pubkey="" authkey="" fg=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
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
      configure_env "$authkey"
      collect_pubkey "$pubkey"
      # 2) Lo largo: en segundo plano, inmune al corte de SSH
      if [[ "$fg" == true ]]; then install_steps; else run_bg install install_steps; fi
      ;;
    update)
      check_prereqs; check_files; normalize_line_endings
      if [[ "${1:-}" == --foreground ]]; then update_steps; else run_bg update update_steps; fi ;;
    progress)  follow ;;
    upgrade|self-update) check_prereqs; upgrade ;;
    rollback)  check_prereqs; rollback ;;
    clean)     check_prereqs; clean "$@" ;;
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
