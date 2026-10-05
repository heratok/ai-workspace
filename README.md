# ai-workspace

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

### Opción A: un solo comando

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
```

Clona el repositorio en `~/ai-workspace` (o lo actualiza si ya existe) y ejecuta `setup.sh install`. Las preguntas (auth key, clave SSH, componentes) se responden igual que en la opción B.

```bash
# Sin preguntas
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | bash -s -- --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 AAAA...'

# En otra carpeta (por defecto: ~/ai-workspace)
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | AIWS_DIR=/opt/ai-workspace bash
```

Requiere `git` y Docker con `docker compose`. Si prefieres revisar el script antes de ejecutarlo: `curl -fsSLO …/install.sh && less install.sh && bash install.sh`.

Si ya tienes una instancia en el servidor, volver a ejecutar el comando **crea otra** en lugar de reinstalar la existente (ver [Varias instancias en un servidor](#varias-instancias-en-un-servidor)).

### Opción B: clonar a mano

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

## Varias instancias en un servidor

Puedes tener varios entornos completamente aislados en el mismo servidor (por ejemplo, uno por cliente o por persona). Cada instancia tiene su carpeta, sus volúmenes, su imagen, su identidad SSH y su propio nodo en Tailscale: no comparten datos ni contenedores, y `uninstall` o `backup` de una nunca tocan a las demás.

**Crear una segunda instancia:** ejecuta de nuevo el mismo comando de instalación.

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
```

- La principal cuenta como existente solo si ya tiene contenedores o volúmenes en Docker. Si una primera instalación falló a medias (queda el clon, sin recursos), volver a ejecutar el comando la **retoma** en lugar de crear otra.
- Si ya existe la instancia principal, `install.sh` lista las instancias del servidor y pregunta `Alias de la nueva instancia [2]`. Enter acepta el número sugerido (el siguiente libre: `2`, `3`...); escribir un alias que ya existe **actualiza** esa instancia.
- Sin terminal interactiva (automatizaciones), crea sola la siguiente libre y lo informa.
- Para elegir el nombre sin preguntas: `... | bash -s -- --alias cliente-a` o `AIWS_INSTANCE=cliente-a`. Si la instancia ya existe, la actualiza. `--alias default` apunta de forma explícita a la principal.
- **Actualizar una instancia existente:** lo normal es `./setup.sh upgrade` desde su carpeta. Con el comando de una línea hay que indicarla (`--alias NOMBRE` o `--alias default`); sin alias, el comando crea una instancia nueva.
- Alias válido: de 1 a 20 caracteres entre `a-z`, `0-9` y `-`, sin empezar ni terminar en `-`. Están reservados `ts`, `mssql`, `postgres`, `redis` y los terminados en `-ts` o `-mssql`. `default` (o vacío) es la instancia principal.
- La instancia principal conserva exactamente sus nombres de siempre: los servidores ya instalados siguen funcionando sin migrar nada.

Con el alias `foo`, todo se nombra a partir de `ai-workspace-foo`:

| Recurso | Principal | Alias `foo` |
|---|---|---|
| Carpeta | `~/ai-workspace` | `~/ai-workspace-foo` |
| Proyecto compose y contenedor | `ai-workspace` | `ai-workspace-foo` |
| Sidecar de Tailscale / SQL Server | `ai-workspace-ts` / `ai-workspace-mssql` | `ai-workspace-foo-ts` / `ai-workspace-foo-mssql` |
| Imagen | `ai-workspace:latest` | `ai-workspace-foo:latest` |
| Volúmenes | `ai_home`, `ai_workspace`, `ai_ssh_host_keys`, `ai_ts_state`, `ai_mssql_data` | `ai-workspace-foo_home`, `_workspace`, `_ssh_host_keys`, `_ts_state`, `_mssql_data` |
| Nombre en la tailnet (`TS_HOSTNAME`) | `ai-workspace` | `ai-workspace-foo` |

Cada instancia se maneja **desde su propia carpeta**, con los mismos comandos de siempre:

```bash
cd ~/ai-workspace-foo
./setup.sh status | shell | backup | upgrade | uninstall
ssh ai@ai-workspace-foo          # el host SSH es el TS_HOSTNAME de la instancia
```

O, sin entrar a ninguna carpeta, con [`aiws`](#gestionar-instancias-con-aiws): `aiws ls`, `aiws upgrade foo`, `aiws shell foo`.

Detalles a tener en cuenta:

- **Recursos:** `MEM_LIMIT` y `CPUS` son topes por instancia (no reservas) y se suman: el instalador sugiere valores según la RAM y las instancias existentes y avisa cuando la suma supera la RAM. Se cambian sin reconstruir; ver [Recursos por instancia](#recursos-por-instancia-memoria-y-cpus).
- **Puertos:** no hay conflictos, porque cada instancia tiene su propia red de Tailscale y no se publica nada en el servidor.
- **Una carpeta, una instancia:** el alias queda guardado en el `.env` (`AIWS_INSTANCE`) y no se cambia después de instalar. `setup.sh` se niega a usar contenedores que gestiona otra carpeta.
- **Tailscale:** cada instancia se registra como un equipo distinto, así que pide su propia auth key o link de login.
- **Instalar a mano:** `git clone ... ai-workspace-foo && cd ai-workspace-foo && ./setup.sh install --alias foo`.

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

**`setup.sh upgrade` sin preguntas:** `./setup.sh upgrade --yes` guarda aparte los cambios locales (`git stash`), actualiza y reconstruye; si ya está al día lo informa y no reconstruye (salvo `--rebuild`); `--foreground` se pasa al `update`. Sin `--yes` conserva las preguntas de siempre y exige una terminal: sin ella falla con un mensaje en lugar de aparentar éxito.

### Si una actualización sale mal

```bash
./setup.sh rollback       # vuelve a la versión que tenías antes del último upgrade y reconstruye
```

Si el build falla, el contenedor anterior **sigue funcionando**: solo se reemplaza cuando la imagen nueva se construye bien. Además, cada push a GitHub pasa por la verificación automática (`.github/workflows/ci.yml`): revisa los scripts, valida el compose y construye la imagen completa. Si sale en rojo, no hagas `upgrade` hasta que se corrija.

### Limpieza y migraciones (para que escale)

- **Migraciones** (`migrations/NNN-*.sh`): cada mejora publicada en GitHub puede traer un script que **limpia o adapta** lo que dejó la versión anterior (variables obsoletas del `.env`, volúmenes o contenedores renombrados…). Cada uno corre **una sola vez por servidor**, en orden, durante `upgrade`, `update` e `install`, y queda registrado en `logs/.migrations-done`. La `001` ya limpia los restos de las versiones anteriores, **sin borrar datos**. La `002` convierte la vieja `NPM_GLOBAL_PACKAGES` del `.env` a los componentes `INSTALL_*` y deja lo que no reconoce en `NPM_EXTRA_PACKAGES`. Cómo escribir una nueva: [`migrations/README.md`](migrations/README.md).
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

## Gestionar instancias con aiws

`aiws` es un comando del servidor para administrar **todas** las instancias sin entrar a la carpeta de cada una. `setup.sh install` lo deja en el `PATH` (enlace en `/usr/local/bin` si se puede escribir ahí; si no, en `~/.local/bin`, y avisa si esa carpeta no está en el `PATH`). Descubre las instancias solo (contenedores etiquetados y clones `~/ai-workspace*`) y delega cada acción en el `setup.sh` de la carpeta correspondiente, así que se comporta igual que ejecutarlo a mano.

```bash
aiws ls                           # tabla: alias, estado, Tailscale, carpeta, MEM/CPUS y total reservado
aiws upgrade santiago maria       # actualiza dos instancias, una tras otra
aiws upgrade --all                # actualiza todas
aiws upgrade                      # con terminal: lista numerada para elegir (1 3, 1-3 o todas)
aiws shell santiago               # abre una shell en esa instancia
aiws resources                      # límites y uso real de memoria y CPU de todas
aiws resources santiago --mem 4g --cpus 2   # cambia los topes de una, sin reconstruir
aiws help                         # todos los comandos; aiws help upgrade o aiws upgrade --help para uno solo
```

- **Alias:** los de `aiws ls`. `default` (o `principal`) es la instancia principal. Un alias desconocido se rechaza antes de ejecutar nada.
- **Varias instancias a la vez** (`upgrade`, `update`, `backup`, `status`, `doctor`, `ts-status`): se ejecutan en orden, **si una falla las demás continúan**, y al final hay un resumen `ok`/`fallo`; el código de salida es distinto de cero si alguna falló. Sin argumentos, `upgrade`, `update` y `backup` muestran la lista para elegir (sin terminal exigen alias o `--all`); `status`, `doctor` y `ts-status` actúan sobre todas.
- **`upgrade` y `update` piden UNA confirmación al inicio** ("Se actualizarán y reconstruirán: 2, santiago. ¿Continuar? [s/N]") y luego corren cada instancia sin más preguntas ni lectura del teclado, así que ninguna puede colgar el lote. Con `--yes` (o `-y`) se omite la confirmación (`aiws upgrade --all --yes`); sin terminal es obligatorio y, si falta, `aiws` sale con código 2 sin ejecutar nada. El resumen final distingue `ok (actualizada)`, `ok (ya al día)` y `fallo`.
- **Una sola instancia** (`shell`, `logs`, `psql`, `components`, `add-key`, `migrate`, `progress`, `down`): `aiws <comando> <alias> [opciones]`.
- **Destructivos, siempre una sola instancia** (`rollback`, `clean`, `uninstall`, `purge`): no aceptan `--all` ni varios alias, y `setup.sh` sigue pidiendo su confirmación.
- **Opciones para `setup.sh`:** en los comandos de varias instancias van después de `--` (`aiws upgrade santiago -- --foreground`); en los demás, tras el alias (`aiws uninstall santiago --all`).
- Al volver a ejecutar `install.sh` con instancias existentes y una terminal interactiva, un menú ofrece crear una instancia nueva, actualizar una existente (`setup.sh upgrade`, que descarga lo nuevo, migra y ofrece reconstruir) o actualizarlas todas. Sin terminal, sigue creando la siguiente libre.

## Recursos por instancia (memoria y CPUs)

Cada instancia tiene sus propios **topes** de recursos, que se guardan en su `.env`: `MEM_LIMIT`, `CPUS`, `SHM_SIZE` (`/dev/shm`, por defecto `2gb`), `PIDS_LIMIT` (por defecto `2048`) y `MSSQL_MEM_LIMIT` (SQL Server, por defecto `4g`). Son máximos, **no reservas**: una instancia que no usa su memoria no se la quita a las demás. Por eso la suma de los topes puede superar la RAM del servidor; solo habría problema si varias instancias llegaran a usarlos a la vez (`aiws ls` y `aiws resources` muestran la suma frente a la RAM y avisan).

**Al instalar:**

```bash
# Con tus valores
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash -s -- --mem 4g --cpus 2
```

Si no los indicas, en una instancia **nueva** `setup.sh` sugiere valores según la RAM del servidor, sus CPUs y cuántas instancias hay ya: `(RAM - 2g para el servidor) / (instancias + 1)`, entre 2g y 8g, y como máximo 4 CPUs. Con terminal pregunta `Memoria máxima [3g]` y `CPUs [2]` (Enter acepta la sugerencia); sin terminal aplica la sugerencia y la muestra. Si el servidor es muy pequeño usa el mínimo (2g) y avisa. Nunca se cambian solos los valores de una instancia que ya existe (la principal instalada antes conserva `8g` y `4`).

**Cambiar después, sin reconstruir** (en segundos; solo se recrean los contenedores de esa instancia):

```bash
./setup.sh resources                              # límites actuales y uso real (docker stats)
./setup.sh resources --mem 4g --cpus 2            # cambia y aplica
./setup.sh resources --shm 1g --pids 4096         # /dev/shm y máximo de procesos
./setup.sh resources --mem 4g --no-apply          # solo guarda en .env
./setup.sh resources --set                        # pregunta cada valor (Enter conserva el actual)

aiws resources                                    # tabla de todas: límites, uso real y totales del servidor
aiws resources santiago --mem 4g --cpus 2         # cambia una instancia desde cualquier carpeta
```

Validaciones: memoria y `/dev/shm` como `512m`, `4g` o `1.5g` (sin distinguir mayúsculas); memoria mínima `1g` (con menos de `2g` avisa: Chromium/Playwright); CPUs un número positivo que no supere las del servidor; procesos un entero de al menos `256`. Si algún valor es inválido no se cambia nada.

## Componentes: instala solo lo que necesitas

```bash
./setup.sh components      # o menú → 4) Elegir componentes
```

```
  1) [x] Claude Code       agente de Anthropic (claude)
  2) [x] Pi                agente pi-coding-agent
  3) [ ] opencode          agente opencode (opencode-ai)
  4) [x] Antigravity CLI   agente de Google (agy)
  5) [x] Gentle AI         memoria y flujos para tus agentes (gentle-ai)
  6) [x] Herdr             sesiones de agentes persistentes (herdr)
  7) [x] Playwright        navegador para agentes + Chromium (~600 MB)
  8) [x] Doppler CLI       gestor de secretos (doppler)
  9) [ ] SQL Server tools  sqlcmd y bcp
  Escribe números para marcar/desmarcar (ej: 3 7), a=todos, n=ninguno, d=por defecto, Enter=guardar
```

- **Primera instalación:** el script pregunta *"¿Instalación completa o personalizada?"*. Si eliges la personalizada, muestra este menú.
- **Después:** cambia la selección cuando quieras. El script guarda en `.env` (`INSTALL_*=true/false`) y ofrece reconstruir. Lo que desmarcas desaparece de la imagen; tus datos no se tocan.
- **La base siempre viene:** git, gh, Node, Python/uv, mise, clientes de bases de datos, devdb, zsh y las herramientas de terminal.
- **CLIs npm extra para todo el equipo:** `NPM_EXTRA_PACKAGES="@openai/codex otra-cli"` en `.env`.

## Qué trae la imagen

Todo esto queda instalado al construir la imagen; no hay que instalar nada a mano:

| Categoría | Herramientas |
|---|---|
| Git y GitHub | `git`, `git-lfs`, `gh` (GitHub CLI, desde su repo oficial) |
| Lenguajes | Node 24 (`npm`, `corepack` → `pnpm`/`yarn`), Python 3 (`uv`, `venv`), `mise` para Go, Rust, Java, otras versiones de Node/Python, etc. (sin root) |
| Compilación | `build-essential`, `pkg-config`, `make`, `libpq-dev` (para módulos nativos de npm y pip) |
| Bases de datos | Clientes `psql`/`pg_dump` 17, `sqlite3`, `redis-cli`, `mariadb`/`mysql`. **Servidores bajo demanda sin root:** `devdb install postgres` y `devdb install redis`. `sqlcmd`/`bcp` opcionales |
| Secretos | **Doppler CLI** (`doppler login`, `doppler run -- …`) |
| Agentes / IA | Claude Code, Pi, **Antigravity CLI (agy)**, **Gentle AI**, opencode (opcional), **Herdr**, Playwright, **playwright-cli** y **playwright-mcp**, con su Chromium incluido (no hace falta Google Chrome) |
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
| `AIWS_INSTANCE` | No | *(vacía = instancia principal)* | Alias de la instancia (ver [Varias instancias](#varias-instancias-en-un-servidor)). Lo escribe `setup.sh`; no lo cambies después de instalar. Junto con `AIWS_NAME` y `AIWS_VOL_PREFIX`, que se derivan de él, define los nombres de contenedores, imagen y volúmenes. |
| `TS_AUTHKEY` | No (el script la pide) | *(vacía)* | Auth key de Tailscale (`tskey-auth-...`). Si está vacía, el script la pide o da un link de login. Se borra tras registrar el nodo. Solo vuelve a pedirse si borras el volumen `ai_ts_state`. |
| `TS_HOSTNAME` | No | `ai-workspace` (instancia con alias: `ai-workspace-<alias>`) | Nombre del equipo en la tailnet (y en MagicDNS). |
| `TS_EXTRA_ARGS` | No | *(vacía)* | Argumentos extra de `tailscale up`, por ejemplo `--advertise-tags=tag:ai-workspace`. |
| `TS_IMAGE_TAG` | No | `stable` | Versión de la imagen `tailscale/tailscale`. Fíjala (p. ej. `v1.90.0`) si quieres que nada cambie solo. |
| `DNS_SERVER` | No | `1.1.1.1` | DNS que usan los contenedores para salir a internet. |
| `USER_UID` / `USER_GID` | No | `1000` | Deben coincidir con el dueño actual del volumen `ai_home`. |
| `FIX_OWNERSHIP` | No | `false` | Ponla en `true` **una sola vez** si cambiaste el UID o GID; hace un `chown` recursivo del home y del workspace. |
| `MEM_LIMIT` / `CPUS` | No | `8g` / `4` | Topes de memoria y CPUs del workspace (por instancia; ver [Recursos](#recursos-por-instancia-memoria-y-cpus)). En una instalación nueva se sugieren según el servidor. |
| `SHM_SIZE` / `PIDS_LIMIT` | No | `2gb` / `2048` | Memoria compartida (`/dev/shm`) y máximo de procesos del workspace. |
| `MSSQL_MEM_LIMIT` | No | `4g` | Tope de memoria del contenedor de SQL Server. |
| `NODE_MAJOR` | No | `24` | Versión mayor de Node.js. |
| `NODE_VERSION` | No | *(vacía = última del major)* | Versión exacta de Node (p. ej. `24.11.1`), para que cada build dé el mismo resultado. |
| `INSTALL_PLAYWRIGHT_BROWSERS` | No | `true` | Incluye Chromium y sus librerías en la imagen. |
| `INSTALL_CLAUDE` / `INSTALL_PI` / `INSTALL_OPENCODE` / `INSTALL_AGY` / `INSTALL_GENTLE_AI` / `INSTALL_PLAYWRIGHT` | No | `true` (opencode: `false`) | Componentes de la imagen. Elígelos con `./setup.sh components` |
| `NPM_EXTRA_PACKAGES` | No | *(vacía)* | CLIs npm adicionales para todo el equipo, separadas por espacio |
| `INSTALL_HERDR` | No | `true` | Incluye [Herdr](https://herdr.dev) en la imagen. |
| `INSTALL_DOPPLER` | No | `true` | Incluye la CLI de Doppler. |
| `DOPPLER_TOKEN` | No | *(vacía)* | Service token de Doppler para usar `doppler run` sin `doppler login`. |
| `PG_MAJOR` | No | `17` | Versión de PostgreSQL (servidor y cliente) dentro de la imagen. Si cambias de versión mayor, los datos existentes requieren `pg_upgrade` o un dump y restore. |
| `INSTALL_PG_SERVER` | No | `false` | `false`: la base de datos se instala bajo demanda con `devdb install` (recomendado). `true`: el servidor ya viene en la imagen. |
| `PG_EXTENSIONS` | No | `pgvector` | Solo aplica con `INSTALL_PG_SERVER=true`. Con `devdb` se indican en la instalación: `devdb install postgres 17 pgvector postgis-3`. |
| `COMPOSE_PROFILES` | No | *(vacía)* | Contenedores extra opcionales. Hoy solo existe `mssql`. |
| `MSSQL_SA_PASSWORD` | No (se genera sola) | *(vacía = aleatoria)* | Contraseña del usuario `sa` de SQL Server. |
| `INSTALL_MSSQL_TOOLS` | No | `false` | Ponla en `true` para agregar `sqlcmd` y `bcp` a la imagen; después ejecuta `update`. |
| `TZ` | No | `America/Bogota` | Zona horaria de los servicios. |

Si cambias una variable de la imagen (`NODE_*`, `NPM_*`, `INSTALL_*`, `USER_*`), ejecuta `bash setup.sh update`.

## Volúmenes

Los nombres son los de la instancia principal. En una instancia con alias `foo` son `ai-workspace-foo_home`, `ai-workspace-foo_workspace`, etc. (ver la tabla de [Varias instancias](#varias-instancias-en-un-servidor)).

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
| `bash setup.sh install` | Instala o reinstala todo. Con `--alias NOMBRE` crea una instancia aislada (lo normal es usar `install.sh`) |
| `bash setup.sh progress` | Ver en vivo el progreso (o el resultado) de la última instalación o actualización, por ejemplo tras reconectar |
| `bash setup.sh backup` | Respalda el home y los proyectos (incluidas las bases de datos de `devdb`) en `./backups/*.tar.gz` |
| `bash setup.sh uninstall` | Quita contenedores, red e imagen. **Conserva** datos, `.env` e identidades; `install` lo deja como estaba |
| `bash setup.sh uninstall --all` | **Borra todo**: proyectos, home, bases de datos, identidad SSH, el equipo en Tailscale y `.env`. Ofrece respaldo y pide escribir `BORRAR` |
| `bash setup.sh upgrade` | **Descarga lo último de GitHub** y reconstruye (ver "Actualizar a la última versión") |
| `bash setup.sh update` | Reconstruye la imagen sin caché, con versiones nuevas |
| `bash setup.sh components` | Elige qué agentes y herramientas trae la imagen (y reconstruye) |
| `bash setup.sh rollback` | Vuelve a la versión anterior al último `upgrade` y reconstruye |
| `bash setup.sh resources [--mem 4g --cpus 2 ...]` | Ver límites y uso real, o cambiarlos sin reconstruir (`--set` pregunta cada valor, `--no-apply` solo guarda) |
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

Si un instalador pide `sudo` o escribe en `/usr/local`, no va a funcionar como `ai`. En ese caso usa `mise`, `npm i -g` o `uv tool`, o agrégalo a la imagen en `config/extra-root.sh` para todo el equipo. Para tener opencode en la imagen para todo el equipo, actívalo en `./setup.sh components`.

### Herdr (incluido)

[Herdr](https://herdr.dev) viene instalado en la imagen (`INSTALL_HERDR=true`). Mantiene las terminales de los agentes vivas aunque cierres SSH, y desde cualquier dispositivo retomas donde ibas:

```bash
herdr          # abre o retoma tus sesiones de agentes (Claude Code, opencode, Pi…)
```

El instalador oficial verifica el SHA-256 y deja el binario en `/usr/local/bin`. Se actualiza con `bash setup.sh update`. Si quieres una versión más nueva solo para ti, sin root: `curl -fsSL https://herdr.dev/install.sh | sh`, que la instala en `~/.local/bin` y tiene prioridad en el `PATH`.

### Gentle AI y Antigravity CLI (agy)

```bash
gentle-ai          # configurador interactivo: agentes, memoria (Engram), skills y flujos
gentle-ai doctor   # diagnóstico, sin cambios

agy                # Antigravity CLI. La primera vez muestra una URL: ábrela en tu PC,
                   # aprueba con tu cuenta Google y pega el código (tienes ~30 s)
```

- Gentle AI escribe su configuración en tu home (`~/.claude`, configuración de opencode, etc.). Todo queda en el volumen `ai_home`.
- **agy en un servidor sin navegador:** también puedes hacer login en tu PC y copiar `~/.gemini/antigravity-cli/antigravity-oauth-token` a la misma ruta dentro del workspace.
- Si `agy` falla con `Illegal instruction`, el servidor (o su VM) no expone las instrucciones AES de la CPU. Hay que habilitarlas en el hipervisor, o desmarcar el componente.

### Doppler (secretos)

La CLI de [Doppler](https://docs.doppler.com) viene en la imagen (`INSTALL_DOPPLER=true`). Así las API keys y las contraseñas no quedan en archivos `.env` dentro de los proyectos.

```bash
doppler login                 # una vez, dentro del workspace; muestra un código o link para aprobar en el navegador
cd /workspace/mi-proyecto
doppler setup                 # elige proyecto y config (dev, stg…)
doppler run -- npm run dev    # inyecta los secretos como variables de entorno
```

- La sesión queda en `~/.doppler` (volumen `ai_home`), así que no tienes que volver a hacer login al reconstruir.
- **Sin login (agentes o automatizaciones):** pon un *service token* de solo lectura en `DOPPLER_TOKEN` en el `.env` del servidor y ejecuta `./setup.sh update`. `doppler run` lo usará solo.

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
| Una herramienta npm fija para todos | `NPM_EXTRA_PACKAGES` en `.env` y luego `update` | En el build |
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
