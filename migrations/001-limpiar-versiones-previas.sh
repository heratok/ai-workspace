# shellcheck shell=bash
# Limpia restos de versiones anteriores de ai-workspace (idempotente, no borra datos).

# Variables del .env que ya no se usan
for v in BIND_IP POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD REDIS_IMAGE_TAG; do
  if [[ -n "$(env_get "$v")" ]] || grep -qE "^$v=" "$ENV_FILE" 2>/dev/null; then
    env_del "$v"; info "  .env: eliminada variable obsoleta $v"
  fi
done

# v1: clave de host SSH en un volumen con prefijo de carpeta (hoy: ai_ssh_host_keys)
for vol in $(docker volume ls -q --filter name=_ai_ssh_host_keys 2>/dev/null); do
  [[ "$vol" == ai_ssh_host_keys ]] && continue
  if docker volume rm "$vol" >/dev/null 2>&1; then info "  volumen obsoleto eliminado: $vol"
  else warn "  $vol sigue en uso; se deja intacto"; fi
done

# Versión con Postgres/Redis en contenedores aparte: NO se borran (pueden tener datos)
for vol in ai_pg_data ai_redis_data; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    warn "  Existe el volumen $vol de una versión anterior (BD en contenedor aparte)."
    warn "  Si ya migraste tus datos a devdb, bórralo con: docker volume rm $vol"
  fi
done
docker rm -f ai-workspace-postgres ai-workspace-redis >/dev/null 2>&1 && info "  contenedores viejos de BD eliminados" || true
