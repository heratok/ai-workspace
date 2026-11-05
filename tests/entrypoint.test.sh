#!/usr/bin/env bash
# =============================================================================
# Pruebas del entrypoint y de la configuración de sshd en un contenedor REAL.
#
#   AIWS_TEST_IMAGE=ai-workspace:ci bash tests/entrypoint.test.sh
#
# Monta entrypoint.sh y config/sshd-ai-workspace.conf del repo sobre la imagen (así prueba el
# código actual sin reconstruir) y corre con las mismas capacidades que docker-compose.yml.
# Solo crea contenedores y volúmenes "aiws-ept-<pid>-*", y los borra al terminar.
# Sin Docker o sin la imagen se omite; con AIWS_TEST_REQUIRE=1 (CI) eso es un fallo.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${AIWS_TEST_IMAGE:-ai-workspace:latest}"
P="aiws-ept-$$"
TMP="$(mktemp -d)"
cleanup() {
  docker ps -aq --filter "name=^$P-" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume ls -q --filter "name=^$P-" | xargs -r docker volume rm >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else nok "$1: esperado '$2', obtenido '$3'"; fi; return 0; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3' en: $2"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [[ "${AIWS_TEST_REQUIRE:-}" == 1 ]]; then echo "FALTA la imagen $IMAGE (AIWS_TEST_REQUIRE=1)" >&2; exit 1; fi
  echo "Se omite: no hay Docker o no existe la imagen $IMAGE (AIWS_TEST_IMAGE=...)"; exit 0
fi

# Mismas capacidades y opciones que el servicio ai-workspace de docker-compose.yml
CAPS=(--cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --cap-add SYS_CHROOT)

# start_ws <nombre>: contenedor con volúmenes propios y el código del repo montado encima de la imagen
start_ws() {
  docker run -d --name "$P-$1" --init "${CAPS[@]}" --security-opt no-new-privileges:true \
    -v "$P-$1-home:/home/ai" -v "$P-$1-ws:/workspace" -v "$P-$1-keys:/etc/ssh/host_keys" \
    -v "$ROOT/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
    -v "$ROOT/config/sshd-ai-workspace.conf:/etc/ssh/sshd_config.d/10-ai-workspace.conf:ro" \
    "$IMAGE" >/dev/null
}

# wait_ready <nombre>: espera a "sshd listo" del arranque actual (o a que el contenedor muera)
wait_ready() {
  local i n="${2:-1}"
  for ((i = 0; i < 60; i++)); do
    (( $(docker logs "$P-$1" 2>&1 | grep -c 'sshd listo') >= n )) && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' "$P-$1" 2>/dev/null)" == true ]] || break
    sleep 1
  done
  docker logs "$P-$1" >&2 2>&1; return 1
}

as_ai()   { docker exec -u ai "$P-$1" sh -c "$2"; }
owner()   { docker exec "$P-$1" stat -c %U "$2" 2>/dev/null || echo "(no existe)"; }

t_fresh_home_gets_install_dirs_owned_by_ai() {
  start_ws fresh; wait_ready fresh || { nok "el contenedor no arrancó"; return 0; }
  local d
  for d in .ssh .local/bin .npm-global/bin .cache .config; do
    assert_eq "dueño de ~/$d" ai "$(owner fresh "/home/ai/$d")"
  done
  assert_eq "permisos de ~/.ssh" 700 "$(docker exec "$P-fresh" stat -c %a /home/ai/.ssh)"
}

t_planted_symlinks_are_not_followed_by_root() {
  start_ws evil; wait_ready evil || { nok "el contenedor no arrancó"; return 0; }
  # Lo que haría un agente comprometido entre dos arranques
  as_ai evil 'cd ~ && rm -rf .cache .config .npm-global && ln -s /usr/local/bin .cache \
    && ln -s /etc/ssh/sshd_config.d .config && ln -s /usr/local/lib .npm-global \
    && ln -sf /etc/shadow .ssh/authorized_keys'
  docker restart "$P-evil" >/dev/null
  wait_ready evil 2 || { nok "el contenedor no volvió a arrancar"; return 0; }
  assert_eq "/usr/local/bin sigue de root" root "$(owner evil /usr/local/bin)"
  assert_eq "/etc/ssh/sshd_config.d sigue de root" root "$(owner evil /etc/ssh/sshd_config.d)"
  assert_eq "/etc/shadow sigue de root" root "$(owner evil /etc/shadow)"
  assert_eq "no crea /usr/local/lib/bin" "(no existe)" "$(owner evil /usr/local/lib/bin)"
  assert_has "avisa del enlace" "$(docker logs "$P-evil" 2>&1)" "enlace simbólico"
}

t_sshd_forwarding_is_restricted() {
  start_ws sshd; wait_ready sshd || { nok "el contenedor no arrancó"; return 0; }
  local cfg k; cfg="$(docker exec "$P-sshd" /usr/sbin/sshd -T 2>/dev/null)"
  for k in allowagentforwarding allowtcpforwarding allowstreamlocalforwarding permittunnel; do
    printf '%s: %s\n' "$k" "$(grep -m1 "^$k " <<< "$cfg" | cut -d' ' -f2)"
  done > "$TMP/fwd"
  assert_eq "reenvíos de sshd" "allowagentforwarding: no
allowtcpforwarding: local
allowstreamlocalforwarding: no
permittunnel: no" "$(cat "$TMP/fwd")"
}

t_stop_shuts_down_devdb_cleanly() {          # docker stop: PostgreSQL y Redis se apagan antes que sshd, sin SIGKILL
  start_ws db; wait_ready db || { nok "el contenedor no arrancó"; return 0; }
  # La imagen no trae servidores: devdb los descarga (requiere red)
  as_ai db 'devdb install postgres 17 && devdb install redis && devdb start all' >/dev/null 2>&1 \
    || { nok "devdb no pudo instalar o iniciar PostgreSQL y Redis"; return 0; }
  docker stop -t 30 "$P-db" >/dev/null
  local code; code="$(docker inspect -f '{{.State.ExitCode}}' "$P-db")"
  if [[ "$code" == 137 ]]; then nok "el contenedor murió por SIGKILL (137)"; else ok; fi
  # docker cp lee del contenedor detenido
  local d=/home/ai/.local/share/devdb
  assert_has "PostgreSQL se apagó limpio" "$(docker cp "$P-db:$d/postgres.log" - 2>/dev/null | tar -xO)" "database system is shut down"
  assert_has "Redis se apagó limpio" "$(docker cp "$P-db:$d/redis.log" - 2>/dev/null | tar -xO)" "ready to exit"
}

for t in t_fresh_home_gets_install_dirs_owned_by_ai t_planted_symlinks_are_not_followed_by_root t_sshd_forwarding_is_restricted \
         t_stop_shuts_down_devdb_cleanly; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
