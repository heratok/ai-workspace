# shellcheck shell=bash
# lib/maintenance.sh - migraciones, limpieza, actualización desde GitHub y rollback
# Se carga con "source" desde setup.sh; no se ejecuta solo.

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
