# shellcheck shell=bash
# lib/resources.sh - recursos por instancia (memoria y CPUs)
# Se carga con "source" desde setup.sh; no se ejecuta solo.

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
