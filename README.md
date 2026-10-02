# ai-workspace v2

Entorno de desarrollo aislado en Docker, accesible **solo por Tailscale**.

- Lo del sistema se instala en la imagen. Lo del usuario se instala sin root en el home.
- En el servidor no se instala nada aparte de Docker: Tailscale corre como contenedor.
- El servidor no publica ningún puerto.

```
 Tu PC (tailnet) ──Tailscale──► [ai-workspace-ts]  ◄─ red compartida ─►  [ai-workspace]
                                 sidecar, NET_ADMIN                       sshd :22, mosh, :3000, :5173
                                 volumen ai_ts_state                      usuario ai, sin root
```

## Requisitos

| Dónde | Qué |
|---|---|
| Servidor Linux | Docker con el plugin `docker compose` (v2), y que exista `/dev/net/tun` |
| Cuenta de Tailscale | Nada que preparar: el script te pide la auth key (solo pegar) o te da un link para iniciar sesión |
| Tu PC | Tailscale conectado a la misma tailnet y una clave SSH. En Windows (PowerShell): `ssh-keygen -t ed25519` (si no tienes) y `type $env:USERPROFILE\.ssh\id_ed25519.pub` para copiarla. Se pega cuando `setup.sh` la pide |

### Conexión a Tailscale: dos formas (el script pregunta)

En la primera instalación, `setup.sh` muestra:

```
Auth key (oculta):
```

| Qué haces | Qué pasa | Recomendado para |
|---|---|---|
| **Pegas la auth key** y presionas Enter | Se conecta solo | Servidores (con tag, el nodo no vence) |
| **Presionas Enter** sin pegar nada | El script muestra un link `https://login.tailscale.com/a/...`; lo abres, apruebas y continúa solo (espera hasta 10 min) | Probar rápido. El nodo vence a los 180 días, salvo que en el panel uses *Disable key expiry* |

### Cómo crear la auth key (opción recomendada)

1. Entra a https://login.tailscale.com/admin/settings/keys y pulsa **Generate auth key**.
2. Configúrala así:
   - **Reusable:** sí, para poder reinstalar.
   - **Ephemeral:** **no**. Si es ephemeral, el nodo desaparece al reiniciarse.
   - **Tags:** `tag:ai-workspace` (recomendado). Antes hay que declarar el tag en las ACL:
     ```json
     "tagOwners": { "tag:ai-workspace": ["autogroup:admin"] }
     ```
     Los nodos con tag **no vencen** (no tienen key expiry), así que no se desconectan cada 180 días.
3. Copia la clave, que empieza con `tskey-auth-`, y pégala cuando el script la pida. Solo se pide una vez.

## Instalación

```bash
# En el servidor (recomendado: desde GitHub, así luego se actualiza solo)
git clone https://github.com/heratok/ai-workspace.git
cd ai-workspace
chmod +x setup.sh
./setup.sh                     # menú → 1) Instalar

# o, sin menú:
bash setup.sh install          # pide la auth key de Tailscale y tu clave SSH pública (pegar)
# te pedirá la auth key (pegar) o te dará un link de login.
# Sin preguntas: --authkey tskey-auth-XXXX
```

`setup.sh install` hace lo siguiente:

1. Valida los requisitos.
2. Corrige los saltos de línea de Windows (CRLF).
3. Crea `.env` a partir de `env.example`.
4. Pide la auth key, o muestra un link de inicio de sesión si no la pegas.
5. Crea los volúmenes.
6. Construye la imagen y levanta los contenedores.
7. **Borra la auth key del `.env`** una vez registrado el nodo.
8. Autoriza tu clave SSH.
9. Ejecuta `ws-doctor`.

Puedes ejecutarlo de nuevo cuando quieras: los datos se conservan.

### Actualizar a la última versión

```bash
./setup.sh upgrade        # o menú → 2) Actualizar a la última versión
```

1. Descarga de GitHub lo nuevo (`git fetch` y `merge --ff-only`) y te muestra qué cambió.
2. Si tienes cambios locales en archivos del repo, los guarda aparte con `git stash` antes de actualizar.
3. Agrega a tu `.env` las variables **nuevas** de `env.example`, sin tocar las que ya tienes.
4. Ofrece reconstruir la imagen (`update`, en segundo plano). Tus datos y volúmenes no se tocan.

**Si instalaste copiando la carpeta a mano** (versión vieja, sin `.git`), `./setup.sh upgrade` la conecta al repo y la deja en la última versión. Conserva `.env`, `logs/` y `backups/`, y reemplaza los archivos del proyecto. Si personalizaste `config/packages.apt` u otro archivo, guarda una copia antes.

Otro repo o rama: `AIWS_REPO_URL=https://github.com/otro/fork.git AIWS_REPO_BRANCH=dev ./setup.sh upgrade`.

### Limpieza y migraciones (para que escale)

- **Migraciones** (`migrations/NNN-*.sh`): cada mejora publicada en GitHub puede traer un script que **limpia o adapta** lo que dejó la versión anterior (variables obsoletas del `.env`, volúmenes o contenedores renombrados…). Cada uno corre **una sola vez por servidor**, en orden, durante `upgrade`, `update` e `install`, y queda registrado en `logs/.migrations-done`. La `001` ya limpia los restos de las versiones anteriores, **sin borrar datos**. Cómo escribir una nueva: [`migrations/README.md`](migrations/README.md).
- **`./setup.sh clean`** (menú → 7, y automático después de cada `update`) hace tres cosas:
  - borra las imágenes viejas de `ai-workspace` que quedan al reconstruir; solo las de este proyecto, gracias a la etiqueta `org.ai-workspace.image`;
  - conserva los últimos 20 logs;
  - conserva los últimos 5 respaldos.
- **`./setup.sh clean --deep`** también borra la caché de build y las imágenes sin uso de **todo** Docker del servidor. Pide confirmación.
- Límites configurables: `AIWS_LOG_KEEP=50 AIWS_BACKUP_KEEP=10 ./setup.sh clean`.

### Si se cae la conexión SSH durante la instalación

`install` y `update` hacen las preguntas al principio (auth key de Tailscale, clave SSH) y después siguen en **segundo plano**, en una sesión propia (`setsid` + `nohup`). Si se cae la conexión SSH o cierras la terminal, **la instalación continúa**.

```bash
./setup.sh progress      # al reconectar: muestra el log desde el inicio y lo sigue en vivo
```

- `Ctrl+C` mientras ves el log solo deja de mostrarlo; **no** detiene la instalación.
- Los logs quedan en `logs/` (`logs/latest.log` es siempre el último). Al terminar se muestra si salió bien o con error.
- Si ejecutas `install` mientras ya hay uno corriendo, no lanza otro: te muestra el progreso del que está en curso.
- Si te logueas por link (sin auth key), el link aparece en el log; también lo ves con `./setup.sh progress`.
- Para ejecutar sin segundo plano: `./setup.sh install --foreground`.

### Conexión

```bash
ssh ai@ai-workspace                       # con MagicDNS (si no, usa la IP 100.x)
mosh -p 60000:60010 ai@ai-workspace
# Frontends: http://ai-workspace:3000 y :5173 (el servidor de desarrollo debe escuchar en 0.0.0.0, p. ej. vite --host)
```

> Cambio respecto a v1: SSH ahora es el puerto **22** en la IP de Tailscale, ya no el 2222.

## Qué trae la imagen

Todo esto queda instalado al construir la imagen; no hay que instalar nada a mano:

| Categoría | Herramientas |
|---|---|
| Git y GitHub | `git`, `git-lfs`, `gh` (GitHub CLI, desde su repo oficial) |
| Lenguajes | Node 24 (`npm`, `corepack` → `pnpm`/`yarn`), Python 3 (`uv`, `venv`), `mise` para Go, Rust, Java, otras versiones de Node/Python, etc. (sin root) |
| Compilación | `build-essential`, `pkg-config`, `make`, `libpq-dev` (para módulos nativos de npm y pip) |
| Bases de datos | Clientes `psql`/`pg_dump` 17, `sqlite3`, `redis-cli`, `mariadb`/`mysql`. **Servidores bajo demanda sin root:** `devdb install postgres` y `devdb install redis`. `sqlcmd`/`bcp` opcionales |
| Agentes / IA | Claude Code, Pi, **Herdr**, Playwright, **playwright-cli** y **playwright-mcp**, con su Chromium incluido (no hace falta Google Chrome) |
| CLI | `zsh`, `fzf`, `rg`, `fd`, `bat`, `jq`, `tree`, `htop`, `tmux`, `vim`, `nano`, `direnv`, `shellcheck`, `mosh` |

### GitHub CLI

```bash
gh auth login        # una vez, dentro del workspace; el token queda en ~/.config/gh (volumen ai_home)
gh repo clone org/repo /workspace/repo
```

## Bases de datos (dentro del workspace, sin root)

La imagen **no trae servidores de bases de datos**. Cuando necesites uno, lo instalas tú mismo dentro del workspace, sin root y sin reconstruir la imagen, con `devdb`:

```bash
devdb install postgres 17 pgvector   # versión y extensiones opcionales (13–18 vía PGDG)
devdb install redis
devdb installed                      # qué hay instalado
devdb start [postgres|redis|all]     # la primera vez crea el cluster y la base de datos "dev"
devdb status | stop | restart | logs
devdb psql                           # o simplemente: psql
devdb enable all                     # arranque automático con el contenedor
devdb uninstall postgres|redis       # borra los binarios; los datos se conservan
devdb tunnel                         # conectar DBeaver o Power BI desde tu PC
```

**Cómo instala sin root.** Es la misma técnica de `local-pg.sh`, ya automatizada:

1. `apt-get update` y `apt-get download` con un estado de apt propio en `~/.cache/devdb/apt`, usando los repos oficiales (PGDG y Debian) que ya vienen configurados en la imagen.
2. Descarga solo los paquetes pedidos y las librerías `lib*` que **falten** en la imagen.
3. Los extrae con `dpkg-deb -x` en `~/.local/opt/devdb/<servicio>`.
4. `devdb` arma el `LD_LIBRARY_PATH` automáticamente al ejecutar cada binario.

| | PostgreSQL | Redis |
|---|---|---|
| Dirección | `127.0.0.1:5432`, usuario `ai`, base de datos `dev` | `127.0.0.1:6379` |
| Variables ya definidas | `PGHOST`, `PGUSER`, `PGDATABASE`, `DATABASE_URL` | `REDIS_URL` |
| Binarios | `~/.local/opt/devdb/postgresql-<ver>` | `~/.local/opt/devdb/redis` |
| Datos | `~/.local/share/devdb/postgres` | `~/.local/share/devdb/redis` |

- **Persistencia:** los binarios y los datos quedan en el volumen `ai_home`, así que se conservan al reconstruir la imagen.
- **Seguridad:** solo escuchan en `127.0.0.1` y usan autenticación `trust` local. Es solo para desarrollo.
- **Desde tu PC:** `ssh -N -L 5432:127.0.0.1:5432 ai@ai-workspace` y luego conecta tu cliente a `localhost:5432`.
- **Servidor ya incluido en la imagen:** si prefieres no instalarlo cada vez, pon `INSTALL_PG_SERVER=true` en `.env` y ejecuta `bash setup.sh update`. `devdb` lo detecta solo.
- **Tu proyecto:** `./database/scripts/local-pg.sh` puede seguir funcionando tal cual. Si quieres simplificarlo, su paso de instalación puede llamar a `devdb install postgres 15`.

### SQL Server (la única excepción)

SQL Server no puede correr sin root dentro del workspace. Si lo necesitas, va en un contenedor aparte (opcional):

```bash
# en .env
COMPOSE_PROFILES=mssql
INSTALL_MSSQL_TOOLS=true     # agrega sqlcmd/bcp a la imagen
# luego
bash setup.sh install
# dentro del workspace
sqlcmd -C -Q "SELECT @@VERSION"   # ya vienen SQLCMDSERVER, SQLCMDUSER y SQLCMDPASSWORD
```

Solo funciona en servidores x86_64 y necesita unos 2 GB de RAM. La contraseña la genera `setup.sh`.

## Variables del `.env`

El archivo `.env` lo crea `setup.sh` con permisos 600. La plantilla documentada está en `env.example`. **No subas `.env` a git.**

| Variable | Obligatoria | Por defecto | Descripción |
|---|---|---|---|
| `TS_AUTHKEY` | No (el script la pide) | *(vacía)* | Auth key de Tailscale (`tskey-auth-...`). Si está vacía, el script la pide o da un link de login. Se borra tras registrar el nodo. Solo vuelve a pedirse si borras el volumen `ai_ts_state`. |
| `TS_HOSTNAME` | No | `ai-workspace` | Nombre del equipo en la tailnet (y en MagicDNS). |
| `TS_EXTRA_ARGS` | No | *(vacía)* | Argumentos extra de `tailscale up`, por ejemplo `--advertise-tags=tag:ai-workspace`. |
| `TS_IMAGE_TAG` | No | `stable` | Versión de la imagen `tailscale/tailscale`. Fíjala (p. ej. `v1.90.0`) si quieres que nada cambie solo. |
| `DNS_SERVER` | No | `1.1.1.1` | DNS que usan los contenedores para salir a internet. |
| `USER_UID` / `USER_GID` | No | `1000` | Deben coincidir con el dueño actual del volumen `ai_home`. |
| `FIX_OWNERSHIP` | No | `false` | Ponla en `true` **una sola vez** si cambiaste el UID o GID; hace un `chown` recursivo del home y del workspace. |
| `MEM_LIMIT` / `CPUS` | No | `8g` / `4` | Límites de recursos del workspace. |
| `NODE_MAJOR` | No | `24` | Versión mayor de Node.js. |
| `NODE_VERSION` | No | *(vacía = última del major)* | Versión exacta de Node (p. ej. `24.11.1`), para que cada build dé el mismo resultado. |
| `NPM_GLOBAL_PACKAGES` | No | `@anthropic-ai/claude-code @mariozechner/pi-coding-agent playwright @playwright/cli @playwright/mcp` | Herramientas npm que se instalan dentro de la imagen. |
| `INSTALL_PLAYWRIGHT_BROWSERS` | No | `true` | Incluye Chromium y sus librerías en la imagen. |
| `INSTALL_HERDR` | No | `true` | Incluye [Herdr](https://herdr.dev) en la imagen. |
| `PG_MAJOR` | No | `17` | Versión de PostgreSQL (servidor y cliente) dentro de la imagen. Si cambias de versión mayor, los datos existentes requieren `pg_upgrade` o un dump y restore. |
| `INSTALL_PG_SERVER` | No | `false` | `false`: la base de datos se instala bajo demanda con `devdb install` (recomendado). `true`: el servidor ya viene en la imagen. |
| `PG_EXTENSIONS` | No | `pgvector` | Solo aplica con `INSTALL_PG_SERVER=true`. Con `devdb` se indican en la instalación: `devdb install postgres 17 pgvector postgis-3`. |
| `COMPOSE_PROFILES` | No | *(vacía)* | Contenedores extra opcionales. Hoy solo existe `mssql`. |
| `MSSQL_SA_PASSWORD` | No (se genera sola) | *(vacía = aleatoria)* | Contraseña del usuario `sa` de SQL Server. |
| `INSTALL_MSSQL_TOOLS` | No | `false` | Ponla en `true` para agregar `sqlcmd` y `bcp` a la imagen; después ejecuta `update`. |
| `TZ` | No | `America/Bogota` | Zona horaria de los servicios. |

Si cambias una variable de la imagen (`NODE_*`, `NPM_*`, `INSTALL_*`, `USER_*`), ejecuta `bash setup.sh update`.

## Volúmenes

| Volumen | Contenido | Si lo borras… |
|---|---|---|
| `ai_home` | Home del usuario: configuraciones, instalaciones sin root y **datos de PostgreSQL y Redis** (`~/.local/share/devdb`) | Pierdes tu configuración personal y tus bases locales |
| `ai_workspace` | Proyectos | **Pierdes tus proyectos** |
| `ai_ssh_host_keys` | Identidad SSH del servidor | Los clientes verán una alerta de "host key changed" |
| `ai_ts_state` | Identidad del nodo en Tailscale | Se crea un nodo nuevo y el script vuelve a pedir la key o el login |
| `ai_mssql_data` | Datos de SQL Server (si lo usas) | **Pierdes esas bases** |

## Comandos

| Comando | Para qué |
|---|---|
| `bash setup.sh` | **Menú**: instalar o actualizar, **ver el progreso**, estado, agregar clave SSH, respaldar, desinstalar. Si hay una instalación en curso, lo avisa y la opción por defecto es ver el progreso |
| `bash setup.sh install` | Instala o reinstala todo |
| `bash setup.sh progress` | Ver en vivo el progreso (o el resultado) de la última instalación o actualización, por ejemplo tras reconectar |
| `bash setup.sh backup` | Respalda el home y los proyectos (incluidas las bases de datos de `devdb`) en `./backups/*.tar.gz` |
| `bash setup.sh uninstall` | Quita contenedores, red e imagen. **Conserva** datos, `.env` e identidades; `install` lo deja como estaba |
| `bash setup.sh uninstall --all` | **Borra todo**: proyectos, home, bases de datos, identidad SSH, el equipo en Tailscale y `.env`. Ofrece respaldo y pide escribir `BORRAR` |
| `bash setup.sh upgrade` | **Descarga lo último de GitHub** y reconstruye (ver "Actualizar a la última versión") |
| `bash setup.sh update` | Reconstruye la imagen sin caché, con versiones nuevas |
| `bash setup.sh clean [--deep]` | Limpia imágenes viejas, logs y respaldos antiguos |
| `bash setup.sh migrate` | Aplica manualmente las migraciones pendientes |
| `bash setup.sh add-key` | Autoriza una clave SSH. Sin argumento la pide para **pegar**; también acepta `'ssh-ed25519 AAAA...'`, `RUTA.pub` o `github:usuario` |
| `bash setup.sh status` / `logs` | Estado y registros de los contenedores |
| `bash setup.sh shell` | Abre una shell como `ai` dentro del workspace |
| `bash setup.sh psql` | Abre `psql` contra el PostgreSQL local (lo inicia si está apagado) |
| `bash setup.sh doctor` | Diagnóstico de herramientas, rutas y permisos |
| `bash setup.sh ts-status` | Estado de Tailscale |
| `bash setup.sh down` | Detiene los contenedores; los volúmenes se conservan |

## Instalar herramientas

Todo lo que instalas **sin root** queda en `ai_home`, así que sobrevive a `update` y a `uninstall` (pero no a `uninstall --all`). Lo que quieras para todo el equipo y en cada instalación nueva, agrégalo a la imagen (filas con "En el build").

### Instaladores `curl | sh` (opencode, bun, deno, rust…)

Funcionan **sin root**: estos instaladores escriben en tu home, y esas carpetas ya están en el `PATH` y se conservan en `ai_home`.

```bash
curl -fsSL https://opencode.ai/install | bash      # -> ~/.opencode/bin/opencode
curl -fsSL https://bun.sh/install | bash           # -> ~/.bun/bin
curl -fsSL https://sh.rustup.rs | sh -s -- -y      # -> ~/.cargo/bin
```

Si un instalador pide `sudo` o escribe en `/usr/local`, no va a funcionar como `ai`. En ese caso usa `mise`, `npm i -g` o `uv tool`, o agrégalo a la imagen en `config/extra-root.sh` para todo el equipo. Para tener opencode en la imagen también puedes agregar `opencode-ai` a `NPM_GLOBAL_PACKAGES`.

### Herdr (incluido)

[Herdr](https://herdr.dev) viene instalado en la imagen (`INSTALL_HERDR=true`). Mantiene las terminales de los agentes vivas aunque cierres SSH, y desde cualquier dispositivo retomas donde ibas:

```bash
herdr          # abre o retoma tus sesiones de agentes (Claude Code, opencode, Pi…)
```

El instalador oficial verifica el SHA-256 y deja el binario en `/usr/local/bin`. Se actualiza con `bash setup.sh update`. Si quieres una versión más nueva solo para ti, sin root: `curl -fsSL https://herdr.dev/install.sh | sh`, que la instala en `~/.local/bin` y tiene prioridad en el `PATH`.

### Playwright para agentes

```bash
playwright-cli open https://example.com     # navegador headless con Chromium incluido
playwright-cli snapshot                     # árbol de elementos para el agente
playwright-cli click e12 && playwright-cli close
claude mcp add playwright -- playwright-mcp # registrar el servidor MCP en Claude Code
```

`PLAYWRIGHT_MCP_BROWSER=chromium` ya viene definido, así que no intenta usar Google Chrome, que necesitaría root.


| Necesito… | Dónde / cómo | ¿Root? |
|---|---|---|
| Un paquete apt | Agregarlo a `config/packages.apt` y luego `update` | En el build |
| Un binario externo (Herdr, etc.) | Agregarlo a `config/extra-root.sh` y luego `update` | En el build |
| Una herramienta npm fija para todos | `NPM_GLOBAL_PACKAGES` en `.env` y luego `update` | En el build |
| Una herramienta npm puntual o una actualización | `npm i -g pkg` (queda en `~/.npm-global`) | No |
| Una herramienta Python | `uv tool install ruff` (queda en `~/.local/bin`) | No |
| Otra versión de Node, Python o Go | `mise use -g node@22`, o un `.mise.toml` por repositorio | No |
| Otra versión del navegador de Playwright | `npx playwright install chromium` o `playwright-cli install-browser chromium` | No |
| Un servidor de base de datos (PostgreSQL, Redis) | `devdb install postgres 17` o `devdb install redis` | No |
| CLIs como binario (Go, Rust, Java, Terraform, kubectl, Bun, Deno…) | `mise use -g go@latest`, `mise use -g terraform`, `mise use -g bun` (busca con `mise registry`) | No |

## Migración desde v1

1. En la carpeta v1, ejecuta `docker compose down`. Los volúmenes `ai_home` y `ai_workspace` no se tocan.
2. Revisa el home: si tienes Node o herramientas instaladas a mano (`~/.nvm`, `~/.local/bin/node`), quítalas para que no tapen las de la imagen.
3. Pasa a `config/extra-root.sh` las herramientas que instalabas a mano, apuntando a `/usr/local/bin`.
4. Ejecuta `bash setup.sh install`.
5. Actualiza tus clientes: `ssh ai@ai-workspace` en el puerto 22. La IP 100.112.41.81 y el puerto 2222 ya no se usan.
