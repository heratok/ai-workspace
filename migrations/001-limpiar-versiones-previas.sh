# shellcheck shell=bash
# Limpia restos de versiones anteriores de ai-workspace (idempotente). NO borra volúmenes ni contenedores en uso:
# de lo que no es seguro tocar solo avisa y da el comando para hacerlo a mano.

# Variables del .env que ya no se usan
for v in BIND_IP POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD REDIS_IMAGE_TAG; do
  if [[ -n "$(env_get "$v")" ]] || grep -qE "^$v=" "$ENV_FILE" 2>/dev/null; then
    env_del "$v"; info "  .env: eliminada variable obsoleta $v"
  fi
done

# v1: clave de host SSH en un volumen con prefijo de carpeta (hoy: ai_ssh_host_keys)
# Ya no se usa, pero NO se borra solo: es un volumen de datos y puede ser de otra instalación.
for vol in $(docker volume ls -q --filter name=_ai_ssh_host_keys 2>/dev/null); do
  [[ "$vol" == ai_ssh_host_keys ]] && continue
  warn "  Existe el volumen $vol de una versión anterior (clave de host SSH); ya no se usa."
  warn "  Si no lo necesitas, bórralo a mano con: docker volume rm $vol"
done

# Versión con Postgres/Redis en contenedores aparte: NO se borran (pueden tener datos)
for vol in ai_pg_data ai_redis_data; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    warn "  Existe el volumen $vol de una versión anterior (BD en contenedor aparte)."
    warn "  Si ya migraste tus datos a devdb, bórralo con: docker volume rm $vol"
  fi
done
# Contenedores viejos de BD: solo se eliminan si están DETENIDOS (sin -f). Uno en ejecución se deja intacto.
for c in ai-workspace-postgres ai-workspace-redis; do
  docker container inspect "$c" >/dev/null 2>&1 || continue
  if docker rm "$c" >/dev/null 2>&1; then info "  contenedor viejo de BD eliminado: $c (estaba detenido)"
  else warn "  $c sigue en ejecución (versión anterior con BD en contenedor aparte): se deja intacto."; fi
done
