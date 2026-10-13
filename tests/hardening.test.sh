#!/usr/bin/env bash
# =============================================================================
# Pruebas de endurecimiento del contenedor workspace en docker-compose.yml.
#
#   bash tests/hardening.test.sh
#
# Estáticas (sin Docker). El conjunto exacto de capacidades se midió quitando
# una a una con cap_drop: ALL (ver odd/tasks/compose-hardening.md).
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else nok "$1: esperado '$2', obtenido '$3'"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# Líneas del servicio (sin la cabecera), hasta el siguiente servicio
service_block() { awk -v s="$1" '$0 ~ "^  "s":" {on=1; next} on && /^  [A-Za-z0-9_-]+:/ {exit} on {print}' "$COMPOSE"; }
# Elementos de una lista de claves bajo el servicio (cap_add, cap_drop...), ordenados y en una línea
list_of() { service_block "$1" | awk -v k="$2" '$0 ~ "^    "k":" {on=1; next} on && /^      - / {sub(/^      - /,""); gsub(/["\047 ]/,""); sub(/#.*/,""); print; next} on {exit}' | sort | paste -sd, -; }

WS=ai-workspace
REQUIRED_CAPS="CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID,SYS_CHROOT"

t_drops_all_capabilities() {
  assert_eq "cap_drop del workspace" "ALL" "$(list_of $WS cap_drop)"
}

t_adds_only_the_measured_capabilities() {
  assert_eq "cap_add del workspace" "$REQUIRED_CAPS" "$(list_of $WS cap_add)"
}

t_workspace_has_no_dangerous_privileges() {
  local b; b="$(service_block $WS)"
  if grep -qE '^    privileged:[[:space:]]*true' <<< "$b"; then nok "el workspace es privileged"; else ok; fi
  if grep -qE 'NET_ADMIN|SYS_ADMIN|SYS_PTRACE|SYS_MODULE|NET_RAW' <<< "$(list_of $WS cap_add)"; then nok "capacidad peligrosa en el workspace"; else ok; fi
  if grep -qE '^    (pid|ipc|userns_mode):[[:space:]]*"?host' <<< "$b"; then nok "namespace del host compartido"; else ok; fi
}

t_keeps_no_new_privileges() {
  if service_block $WS | grep -q 'no-new-privileges:true'; then ok; else nok "falta no-new-privileges"; fi
}

t_tailscale_keeps_only_net_admin() {          # el sidecar necesita NET_ADMIN; el workspace no
  assert_eq "cap_add de tailscale" "NET_ADMIN" "$(list_of tailscale cap_add)"
}

for t in t_drops_all_capabilities t_adds_only_the_measured_capabilities t_workspace_has_no_dangerous_privileges \
         t_keeps_no_new_privileges t_tailscale_keeps_only_net_admin; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
