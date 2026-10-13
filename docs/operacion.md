# Guía de operación

[← Volver al README](../README.md)

## Operación

### Comandos de `setup.sh`

Se ejecutan desde la carpeta de la instancia (`./setup.sh COMANDO` o `bash setup.sh COMANDO`). Con varias instancias, `aiws` ejecuta los mismos comandos sin cambiar de carpeta.

| Comando | Para qué |
|---|---|
| `setup.sh` | **Menú**: instalar o actualizar, ver el progreso, estado, agregar clave SSH, respaldar, desinstalar. Si hay una instalación en curso, lo avisa y la opción por defecto es ver el progreso |
| `install` | Instala o reinstala todo. Con `--alias NOMBRE` crea una instancia aislada (lo normal es usar `install.sh`). También acepta `--authkey`, `--pubkey`, `--mem`, `--cpus` y `--foreground` |
| `progress` | Ver en vivo el progreso (o el resultado) de la última instalación o actualización, por ejemplo tras reconectar |
| `upgrade` | **Descarga lo último de GitHub**, migra y reconstruye (ver [Actualizar](#actualizar-a-la-última-versión)) |
| `update` | Reconstruye la imagen sin caché **con las versiones fijadas** (las de tu `.env` o, si no hay, las del repo). `agy` siempre trae la última. Para versiones nuevas de las herramientas, usa `tools` |
| `tools [--yes] [--reset]` | Busca versiones nuevas de las herramientas (npm y GitHub), muestra una tabla con lo que hay en la imagen, lo fijado y lo último, y te deja elegir cuáles aplicar: se guardan en el `.env` (nunca en los archivos del repo) y ofrece reconstruir. `--yes` aplica todo y reconstruye; `--reset` quita las versiones del `.env` y vuelve a las del repo. Al abrir el menú avisa si hay versiones nuevas (opción 11) |
| `rollback` | Vuelve a la versión anterior al último `upgrade` y reconstruye |
| `components` | Elige qué agentes y herramientas trae la imagen (y reconstruye) |
| `resources [--mem 4g --cpus 2 ...]` | Ver límites y uso real, o cambiarlos sin reconstruir (`--set` pregunta cada valor, `--no-apply` solo guarda) |
| `backup` | Respalda el home y los proyectos (incluidas las bases de `devdb`) en `./backups/*.tar.gz`, con su checksum `.sha256` |
| `restore [ARCHIVO] [--yes]` | Restaura un respaldo (por defecto el más reciente de la instancia). Verifica el checksum, rechaza respaldos de otra instancia, **reemplaza** el contenido de home y proyectos y antes hace un respaldo de seguridad del estado actual. Si el workspace está corriendo lo detiene y lo vuelve a arrancar |
| `clean [--deep]` | Limpia imágenes viejas, logs y respaldos antiguos |
| `migrate` | Aplica manualmente las migraciones pendientes |
| `add-key` | Autoriza una clave SSH. Sin argumento la pide para **pegar**; también acepta `'ssh-ed25519 AAAA...'`, `RUTA.pub` o `github:usuario` |
| `status` / `logs` | Estado y registros de los contenedores |
| `shell` | Abre una shell como `ai` dentro del workspace |
| `psql` | Abre `psql` contra el PostgreSQL local de `devdb` |
| `doctor` | Diagnóstico de herramientas, rutas y permisos |
| `ts-status` | Estado de Tailscale |
| `down` | Detiene los contenedores; los volúmenes se conservan |
| `uninstall` | Quita contenedores, red e imagen. **Conserva** datos, `.env` e identidades; `install` lo deja como estaba |
| `uninstall --all` | **Borra todo**: proyectos, home, bases de datos, identidad SSH, el equipo en Tailscale y `.env`. Ofrece respaldo y pide escribir `BORRAR` |

### Actualizar a la última versión

```bash
./setup.sh upgrade        # o menú → 2) Actualizar a la última versión
aiws upgrade --all        # todas las instancias
```

1. Descarga de GitHub lo nuevo (`git fetch` y `merge --ff-only`) y te muestra qué cambió.
2. Si tienes cambios locales en archivos del repo, los guarda aparte con `git stash` antes de actualizar.
3. Aplica las migraciones pendientes.
4. Agrega a tu `.env` las variables **nuevas** de `env.example`, sin tocar las que ya tienes.
5. Ofrece reconstruir la imagen (`update`, en segundo plano). Tus datos y volúmenes no se tocan.

**Sin preguntas:** `./setup.sh upgrade --yes` guarda aparte los cambios locales, actualiza y reconstruye. Si ya está al día lo informa y no reconstruye (salvo `--rebuild`); `--foreground` se pasa al `update`. Sin `--yes` conserva las preguntas y exige una terminal: sin ella falla con un mensaje en lugar de aparentar éxito.

**Carpeta copiada a mano (sin `.git`):** `./setup.sh upgrade` la conecta al repo y la deja en la última versión. Conserva `.env`, `logs/` y `backups/`, y reemplaza los archivos del proyecto. Si personalizaste `config/packages.apt` u otro archivo, guarda una copia antes.

**Otro repo o rama:** `AIWS_REPO_URL=https://github.com/otro/fork.git AIWS_REPO_BRANCH=dev ./setup.sh upgrade`.

**Si una actualización sale mal:**

```bash
./setup.sh rollback       # vuelve a la versión que tenías antes del último upgrade y reconstruye
```

Si el build falla, el contenedor anterior **sigue funcionando**: solo se reemplaza cuando la imagen nueva se construye bien. Antes de actualizar un servidor, comprueba que el CI de `main` esté en verde (ver [CI](desarrollo.md#verificación-automática-ci)).

### Si se cae SSH durante la instalación

`install` y `update` hacen las preguntas al principio y después siguen en **segundo plano**, en una sesión propia (`setsid` + `nohup`). Si se cae la conexión o cierras la terminal, **la instalación continúa**.

```bash
./setup.sh progress      # al reconectar: muestra el log desde el inicio y lo sigue en vivo
```

- `Ctrl+C` mientras ves el log solo deja de mostrarlo; **no** detiene la instalación.
- Los logs quedan en `logs/` (`logs/latest.log` es siempre el último). Al terminar se muestra si salió bien o con error.
- Si ejecutas `install` mientras ya hay uno corriendo, no lanza otro: te muestra el progreso del que está en curso.
- Si te logueas por link (sin auth key), el link aparece en el log; también lo ves con `./setup.sh progress`.
- Para ejecutar sin segundo plano: `./setup.sh install --foreground`.

### Limpieza y migraciones

- **Migraciones** (`migrations/NNN-*.sh`): cada mejora publicada puede traer un script que **limpia o adapta** lo que dejó la versión anterior (variables obsoletas del `.env`, volúmenes o contenedores renombrados…). Cada uno corre **una sola vez por servidor**, en orden, durante `upgrade`, `update` e `install`, y queda registrado en `logs/.migrations-done`. La `001` limpia restos de versiones anteriores sin borrar datos (de un volumen obsoleto solo avisa y da el comando; un contenedor viejo solo se elimina si está detenido); la `003` quita del `.env` las versiones fijadas que coinciden con las del repo; la `002` convierte la vieja `NPM_GLOBAL_PACKAGES` del `.env` a los componentes `INSTALL_*` y deja lo que no reconoce en `NPM_EXTRA_PACKAGES`. Cómo escribir una nueva: [`migrations/README.md`](../migrations/README.md).
- **`./setup.sh clean`** (menú → 8, y automático después de cada `update`):
  - borra las imágenes viejas que quedan al reconstruir, solo las de esa instancia, gracias a las etiquetas `org.ai-workspace.image` y `org.ai-workspace.instance`;
  - conserva los últimos 20 logs;
  - conserva los últimos 5 respaldos.
- **`./setup.sh clean --deep`** también borra la caché de build y las imágenes sin uso de **todo** Docker del servidor. Pide confirmación.
- Límites configurables: `AIWS_LOG_KEEP=50 AIWS_BACKUP_KEEP=10 ./setup.sh clean`.

### Volúmenes

Los nombres son los de la instancia principal. En una instancia con alias `foo` son `ai-workspace-foo_home`, `ai-workspace-foo_workspace`, etc.

| Volumen | Contenido | Si lo borras… |
|---|---|---|
| `ai_home` | Home del usuario: configuraciones, instalaciones sin root y **datos de PostgreSQL y Redis** (`~/.local/share/devdb`) | Pierdes tu configuración personal y tus bases locales |
| `ai_workspace` | Proyectos | **Pierdes tus proyectos** |
| `ai_ssh_host_keys` | Identidad SSH del servidor | Los clientes verán una alerta de "host key changed" |
| `ai_ts_state` | Identidad del nodo en Tailscale | Se crea un nodo nuevo y el script vuelve a pedir la key o el login |
| `ai_mssql_data` | Datos de SQL Server (si lo usas) | **Pierdes esas bases** |
