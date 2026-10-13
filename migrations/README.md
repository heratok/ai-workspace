# Migraciones

Cada archivo `NNN-descripcion.sh` corre **una sola vez por servidor**, en orden numérico, dentro de
`./setup.sh upgrade`, `update` e `install`. Las aplicadas quedan registradas en `logs/.migrations-done`.

Sirven para que cada mejora que se publica en GitHub pueda **limpiar o adaptar** lo que dejó una
versión anterior (variables obsoletas del `.env`, contenedores o volúmenes renombrados, archivos viejos),
sin que nadie tenga que hacerlo a mano.

## Cómo agregar una

1. Crea `migrations/NNN-que-hace.sh` con el siguiente número libre (`002-...`, `003-...`).
2. Debe ser **idempotente** (si se ejecuta dos veces no rompe nada) y **nunca borrar datos** del usuario
   sin respaldo (volúmenes `ai_home`, `ai_workspace`, bases de datos). Regla general: **ningún `docker volume rm`
   ni `docker rm -f` automáticos**. De un volumen obsoleto solo se avisa y se da el comando para borrarlo a mano;
   un contenedor viejo se elimina solo si está detenido (`docker rm` sin `-f`). Un volumen que hoy parece
   obsoleto puede ser de otra instalación de ese mismo servidor. Las pruebas de ejemplo están en
   `tests/migrations.test.sh` (usa un `docker` falso que distingue contenedores detenidos de los que corren).
3. Tiene disponibles las funciones de `setup.sh`: `info`, `warn`, `die`, `env_get`, `env_set`, `env_del`,
   `compose`, `confirm`, y variables como `$SCRIPT_DIR`, `$ENV_FILE`, `$CONTAINER`.
   Con varias instancias en el servidor, cada carpeta corre sus migraciones: usa `$CONTAINER`, `$IMAGE`,
   `$TS_VOLUME` y `${VOLUMES[@]}` en lugar de nombres fijos, para no tocar otras instancias.
4. Si falla (exit ≠ 0) el proceso se detiene y se reintenta en la siguiente ejecución.

Comando manual: `./setup.sh migrate`.
