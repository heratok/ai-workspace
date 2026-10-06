# ai-workspace

Entorno de desarrollo aislado en Docker para trabajar con agentes de IA, accesible **solo por Tailscale** y por SSH. Puedes tener varias instancias independientes en el mismo servidor y administrarlas con el comando `aiws`.

- Lo del sistema se instala en la imagen. Lo del usuario se instala sin root en el home.
- En el servidor no se instala nada aparte de Docker: Tailscale corre como contenedor.
- El servidor no publica ningún puerto.

```
 Tu PC (tailnet) ──Tailscale──► [ai-workspace-ts]  ◄─ red compartida ─►  [ai-workspace]
                                 sidecar, NET_ADMIN                       sshd :22, mosh, :3000, :5173
                                 volumen ai_ts_state                      usuario ai, sin root
```

## Contenido

1. [Inicio rápido](#inicio-rápido)
2. [Requisitos y Tailscale](#requisitos-y-tailscale)
3. [Varias instancias](#varias-instancias-en-un-servidor) y [`aiws`](#gestionar-instancias-con-aiws)
4. [Configuración](#configuración): [`.env`](#variables-del-env), [recursos](#recursos-por-instancia-memoria-y-cpus), [componentes](#componentes-instala-solo-lo-que-necesitas)
5. [Operación](#operación): [comandos](#comandos-de-setupsh), [actualizar](#actualizar-a-la-última-versión), [respaldos y limpieza](#limpieza-y-migraciones), [volúmenes](#volúmenes)
6. [Qué trae la imagen](#qué-trae-la-imagen), [bases de datos](#bases-de-datos-dentro-del-workspace-sin-root) y [herramientas](#instalar-herramientas)
7. [Solución de problemas](#solución-de-problemas)
8. [CI](#verificación-automática-ci) y [migración desde v1](#migración-desde-v1)

## Inicio rápido

Necesitas un servidor Linux con Docker y una cuenta de Tailscale (detalles en [Requisitos](#requisitos-y-tailscale)).

### Opción A: un solo comando (recomendada)

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
```

Clona el repositorio en `~/ai-workspace` (o lo actualiza si ya existe) y ejecuta `setup.sh install`. Te pide la auth key de Tailscale (o te da un link de inicio de sesión) y tu clave SSH pública, y después sigue solo.

```bash
# Sin preguntas
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | bash -s -- --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 AAAA...'

# En otra carpeta (por defecto: ~/ai-workspace)
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh \
  | AIWS_DIR=/opt/ai-workspace bash
```

Requiere `git` y Docker con `docker compose`. Para revisar el script antes de ejecutarlo: `curl -fsSLO …/install.sh && less install.sh && bash install.sh`.

Variables de `install.sh`: `AIWS_INSTANCE` (alias, equivale a `--alias`), `AIWS_DIR` (carpeta), `AIWS_REPO_URL` (repositorio) y `AIWS_REPO_BRANCH` (rama o tag, por defecto `main`). Los demás argumentos pasan tal cual a `setup.sh install` (`--authkey`, `--pubkey`, `--mem`, `--cpus`, `--foreground`).

> Si ya hay una instancia en el servidor, volver a ejecutar el comando **crea otra** en lugar de reinstalar. Ver [Varias instancias](#varias-instancias-en-un-servidor).

### Opción B: clonar a mano

```bash
git clone https://github.com/heratok/ai-workspace.git
cd ai-workspace
chmod +x setup.sh
./setup.sh                     # menú → 1) Instalar

# o, sin menú:
./setup.sh install             # opcional: --authkey tskey-auth-XXXX --pubkey 'ssh-ed25519 AAAA...'
```

Clonar desde GitHub permite actualizar luego con `./setup.sh upgrade`.

### Qué hace `setup.sh install`

1. Valida los requisitos.
2. Corrige los saltos de línea de Windows (CRLF).
3. Crea `.env` a partir de `env.example`.
4. Pide la auth key, o muestra un link de inicio de sesión si no la pegas.
5. Aplica las migraciones pendientes y crea los volúmenes.
6. Construye la imagen y levanta los contenedores.
7. **Borra la auth key del `.env`** una vez registrado el nodo.
8. Autoriza tu clave SSH.
9. Deja el comando [`aiws`](#gestionar-instancias-con-aiws) en el `PATH`.
10. Ejecuta `ws-doctor`.

Puedes ejecutarlo de nuevo cuando quieras: los datos se conservan.

Las preguntas se hacen al principio y el resto sigue en **segundo plano**: si se cae la conexión SSH, la instalación continúa (ver [Si se cae SSH durante la instalación](#si-se-cae-ssh-durante-la-instalación)).

### Conexión

```bash
ssh ai@ai-workspace                       # con MagicDNS (si no, usa la IP 100.x)
mosh -p 60000:60010 ai@ai-workspace
# Frontends: http://ai-workspace:3000 y :5173 (el servidor de desarrollo debe escuchar en 0.0.0.0, p. ej. vite --host)
```

El host es el `TS_HOSTNAME` de la instancia (`ai-workspace-ALIAS` si tiene alias). SSH usa el puerto **22** de la IP de Tailscale.

## Requisitos y Tailscale

| Dónde | Qué |
|---|---|
| Servidor Linux | Docker con el plugin `docker compose` (v2), `git` (para `install.sh`) y que exista `/dev/net/tun` |
| Cuenta de Tailscale | Nada que preparar: el script te pide la auth key (solo pegar) o te da un link para iniciar sesión |
| Tu PC | Tailscale conectado a la misma tailnet y una clave SSH. En Windows (PowerShell): `ssh-keygen -t ed25519` (si no tienes) y `type $env:USERPROFILE\.ssh\id_ed25519.pub` para copiarla. Se pega cuando `setup.sh` la pide |

### Conexión a Tailscale: dos formas

En la primera instalación, `setup.sh` muestra `Auth key (oculta):`.

| Qué haces | Qué pasa | Recomendado para |
|---|---|---|
| **Pegas la auth key** y presionas Enter | Se conecta solo | Servidores (con tag, el nodo no vence) |
| **Presionas Enter** sin pegar nada | El script muestra un link `https://login.tailscale.com/a/...`; lo abres, apruebas y continúa solo (espera hasta 10 min) | Probar rápido. El nodo vence a los 180 días, salvo que en el panel uses *Disable key expiry* |

### Cómo crear la auth key

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

## Varias instancias en un servidor

Puedes tener varios entornos completamente aislados en el mismo servidor (por ejemplo, uno por cliente o por persona). Cada instancia tiene su carpeta, sus volúmenes, su imagen, su identidad SSH y su propio nodo en Tailscale: no comparten datos ni contenedores, y `uninstall` o `backup` de una nunca tocan a las demás.

**Crear otra instancia:** ejecuta de nuevo el comando de instalación.

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash
# o con el alias elegido, sin preguntas:
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash -s -- --alias cliente-a
```

| Situación | Qué hace `install.sh` |
|---|---|
| No existe la principal | Instala la principal. Si una primera instalación falló a medias (queda el clon, sin recursos en Docker), volver a ejecutar la **retoma** |
| Existe la principal, con terminal y sin alias | Muestra un menú: crear una instancia nueva, actualizar una existente (`setup.sh upgrade`) o actualizar todas |
| Al crear una nueva, con terminal | Lista las instancias y pregunta `Alias de la nueva instancia [2]`. Enter acepta el siguiente número libre (`2`, `3`…); escribir un alias que ya existe **actualiza** esa instancia |
| Existe la principal, sin terminal ni alias | Crea sola la siguiente libre y lo informa |
| `--alias NOMBRE` o `AIWS_INSTANCE=NOMBRE` | Usa ese nombre sin preguntar; si ya existe, la actualiza. `--alias default` apunta de forma explícita a la principal |

**Alias válido:** de 1 a 20 caracteres entre `a-z`, `0-9` y `-`, sin empezar ni terminar en `-`. Están reservados `ts`, `mssql`, `postgres`, `redis` y los terminados en `-ts` o `-mssql`. `default` (o vacío) es la instancia principal.

La instancia principal conserva exactamente sus nombres de siempre: los servidores ya instalados siguen funcionando sin migrar nada.

### Cómo se nombra cada instancia

Con el alias `foo`, todo se nombra a partir de `ai-workspace-foo`:

| Recurso | Principal | Alias `foo` |
|---|---|---|
| Carpeta | `~/ai-workspace` | `~/ai-workspace-foo` |
| Proyecto compose y contenedor | `ai-workspace` | `ai-workspace-foo` |
| Sidecar de Tailscale / SQL Server | `ai-workspace-ts` / `ai-workspace-mssql` | `ai-workspace-foo-ts` / `ai-workspace-foo-mssql` |
| Imagen | `ai-workspace:latest` | `ai-workspace-foo:latest` |
| Volúmenes | `ai_home`, `ai_workspace`, `ai_ssh_host_keys`, `ai_ts_state`, `ai_mssql_data` | `ai-workspace-foo_home`, `_workspace`, `_ssh_host_keys`, `_ts_state`, `_mssql_data` |
| Nombre en la tailnet (`TS_HOSTNAME`) | `ai-workspace` | `ai-workspace-foo` |

### Reglas a tener en cuenta

- **Una carpeta, una instancia.** El alias queda guardado en el `.env` (`AIWS_INSTANCE`, más `AIWS_NAME` y `AIWS_VOL_PREFIX`, derivados de él) y no se cambia después de instalar. `setup.sh` se niega a usar contenedores que gestiona otra carpeta.
- **Tailscale:** cada instancia se registra como un equipo distinto, así que pide su propia auth key o link de login.
- **Puertos:** no hay conflictos, porque cada instancia tiene su propia red de Tailscale y no se publica nada en el servidor.
- **Recursos:** `MEM_LIMIT` y `CPUS` son topes por instancia (no reservas) y se suman; ver [Recursos por instancia](#recursos-por-instancia-memoria-y-cpus).
- **Actualizar una existente:** lo normal es `./setup.sh upgrade` desde su carpeta, o `aiws upgrade ALIAS`. Con el comando de una línea hay que indicarla (`--alias NOMBRE` o `--alias default`); sin alias el comando crea una nueva.
- **Instalar a mano:** `git clone https://github.com/heratok/ai-workspace.git ai-workspace-foo && cd ai-workspace-foo && ./setup.sh install --alias foo`.

Cada instancia se maneja desde su propia carpeta con `setup.sh`, o desde cualquier lugar con `aiws`:

```bash
cd ~/ai-workspace-foo && ./setup.sh status     # una instancia, desde su carpeta
aiws status foo                                # la misma, desde cualquier carpeta
ssh ai@ai-workspace-foo                        # el host SSH es el TS_HOSTNAME de la instancia
```

## Gestionar instancias con aiws

`aiws` es un comando del servidor para administrar **todas** las instancias sin entrar a la carpeta de cada una. `setup.sh install` (y `update`) lo deja en el `PATH`: enlace en `/usr/local/bin` si se puede escribir ahí; si no, en `~/.local/bin`, y avisa si esa carpeta no está en el `PATH`. Descubre las instancias solo (contenedores etiquetados, el registro `~/.local/share/ai-workspace/instances` y clones `~/ai-workspace*`) y delega cada acción en el `setup.sh` de la carpeta correspondiente, así que se comporta igual que ejecutarlo a mano.

```bash
aiws ls                                     # tabla: alias, estado, Tailscale, carpeta, MEM/CPUS y total
aiws upgrade santiago maria                 # actualiza dos instancias, una tras otra
aiws upgrade --all                          # actualiza todas
aiws upgrade                                # con terminal: lista numerada para elegir (1 3, 1-3 o todas)
aiws shell santiago                         # abre una shell en esa instancia
aiws resources                              # límites y uso real de memoria y CPU de todas
aiws resources santiago --mem 4g --cpus 2   # cambia los topes de una, sin reconstruir
aiws help                                   # todos los comandos; aiws help upgrade o aiws upgrade --help para uno solo
```

`aiws` sin argumentos equivale a `aiws ls`. `install` no se hace con `aiws`: usa `install.sh`.

### Referencia de comandos

| Tipo | Comandos | Cómo se indican las instancias |
|---|---|---|
| Lista | `ls` | No necesita: muestra todas |
| Varias instancias | `upgrade`, `update`, `backup` | Uno o varios alias, o `--all`. Sin argumentos, con terminal: lista para elegir |
| Varias, solo lectura | `status`, `doctor`, `ts-status` | Uno o varios alias, o `--all`. Sin argumentos actúan sobre todas |
| Ver o cambiar recursos | `resources` | Para ver: varios alias o `--all` (sin argumentos, todas). Para cambiar (`--mem`, `--cpus`, `--shm`, `--pids`, `--mssql-mem`, `--set`, `--no-apply`): una sola |
| Una sola instancia | `shell`, `logs`, `psql`, `components`, `add-key`, `migrate`, `progress`, `down` | `aiws COMANDO ALIAS [opciones]` |
| Destructivos, una sola | `rollback`, `clean`, `uninstall`, `purge` | No aceptan `--all` ni varios alias; `setup.sh` sigue pidiendo su confirmación |
| Ayuda | `help` | `aiws help [COMANDO]` |

- **Alias:** los de `aiws ls`. `default` (o `principal`) es la instancia principal. Un alias desconocido se rechaza antes de ejecutar nada.
- **Varias a la vez:** se ejecutan en orden, **si una falla las demás continúan**, y al final hay un resumen `ok`/`fallo`; el código de salida es distinto de cero si alguna falló. El resumen de `upgrade` distingue `ok (actualizada)`, `ok (ya al día)` y `fallo`.
- **`upgrade` y `update` piden UNA confirmación al inicio** (`Se actualizarán y reconstruirán: 2, santiago. ¿Continuar? [s/N]`) y luego corren cada instancia sin más preguntas, así que ninguna puede colgar el lote. `--yes` (o `-y`) la omite (`aiws upgrade --all --yes`); sin terminal es obligatorio y, si falta, `aiws` sale con código 2 sin ejecutar nada.
- **Opciones para `setup.sh`:** en los comandos de varias instancias van después de `--` (`aiws upgrade santiago -- --foreground`); en los demás, tras el alias (`aiws uninstall santiago --all`).

## Configuración

### Variables del `.env`

El archivo `.env` lo crea `setup.sh` con permisos 600. La plantilla documentada está en `env.example`. **No subas `.env` a git.** Cada instancia tiene el suyo.

Si cambias una variable de la imagen (`NODE_*`, `NPM_*`, `INSTALL_*`, `PG_*`, `USER_*`), ejecuta `./setup.sh update`.

**Instancia y red**

| Variable | Por defecto | Descripción |
|---|---|---|
| `AIWS_INSTANCE` | *(vacía = principal)* | Alias de la instancia. Lo escribe `setup.sh`; no lo cambies después de instalar. `AIWS_NAME` y `AIWS_VOL_PREFIX` se derivan de él y también los escribe `setup.sh` |
| `TS_AUTHKEY` | *(vacía)* | Auth key de Tailscale (`tskey-auth-...`). Si está vacía, el script la pide o da un link de login. Se borra tras registrar el nodo; solo vuelve a pedirse si borras el volumen `ai_ts_state` |
| `TS_HOSTNAME` | `ai-workspace` (con alias: `ai-workspace-<alias>`) | Nombre del equipo en la tailnet (y en MagicDNS) |
| `TS_EXTRA_ARGS` | *(vacía)* | Argumentos extra de `tailscale up`, por ejemplo `--advertise-tags=tag:ai-workspace` |
| `TS_IMAGE_TAG` | `stable` | Versión de la imagen `tailscale/tailscale`. Fíjala (p. ej. `v1.90.0`) si quieres que nada cambie solo |
| `DNS_SERVER` | `1.1.1.1` | DNS que usan los contenedores para salir a internet |
| `TZ` | `America/Bogota` | Zona horaria de los servicios |

**Usuario y recursos** (ver [Recursos](#recursos-por-instancia-memoria-y-cpus))

| Variable | Por defecto | Descripción |
|---|---|---|
| `USER_UID` / `USER_GID` | `1000` | Deben coincidir con el dueño actual del volumen `ai_home` |
| `FIX_OWNERSHIP` | `false` | Ponla en `true` **una sola vez** si cambiaste el UID o GID; hace un `chown` recursivo del home y del workspace |
| `MEM_LIMIT` / `CPUS` | `8g` / `4` | Topes de memoria y CPUs del workspace. En una instalación nueva se sugieren según el servidor |
| `SHM_SIZE` / `PIDS_LIMIT` | `2gb` / `2048` | Memoria compartida (`/dev/shm`) y máximo de procesos |
| `MSSQL_MEM_LIMIT` | `4g` | Tope de memoria del contenedor de SQL Server |

**Imagen y componentes** (requieren `update`)

| Variable | Por defecto | Descripción |
|---|---|---|
| `NODE_MAJOR` | `24` | Versión mayor de Node.js |
| `NODE_VERSION` | *(vacía = última del major)* | Versión exacta de Node (p. ej. `24.11.1`) para builds reproducibles |
| `INSTALL_CLAUDE` / `INSTALL_PI` / `INSTALL_OPENCODE` / `INSTALL_AGY` / `INSTALL_GENTLE_AI` / `INSTALL_PLAYWRIGHT` | `true` (opencode: `false`) | Componentes de la imagen. Elígelos con `./setup.sh components` |
| `INSTALL_PLAYWRIGHT_BROWSERS` | `true` | Incluye Chromium y sus librerías en la imagen |
| `INSTALL_HERDR` | `true` | Incluye [Herdr](https://herdr.dev) |
| `INSTALL_DOPPLER` | `true` | Incluye la CLI de Doppler |
| `NPM_EXTRA_PACKAGES` | *(vacía)* | CLIs npm adicionales para todo el equipo, separadas por espacio (p. ej. `@openai/codex`) |

**Bases de datos y secretos**

| Variable | Por defecto | Descripción |
|---|---|---|
| `PG_MAJOR` | `17` | Versión de PostgreSQL (cliente, y servidor si se hornea) en la imagen. Si cambias de versión mayor, los datos existentes requieren `pg_upgrade` o un dump y restore |
| `INSTALL_PG_SERVER` | `false` | `false`: la base se instala bajo demanda con `devdb install` (recomendado). `true`: el servidor ya viene en la imagen |
| `PG_EXTENSIONS` | `pgvector` | Solo aplica con `INSTALL_PG_SERVER=true`. Con `devdb` se indican al instalar: `devdb install postgres 17 pgvector postgis-3` |
| `COMPOSE_PROFILES` | *(vacía)* | Contenedores extra opcionales. Hoy solo existe `mssql` |
| `MSSQL_SA_PASSWORD` | *(vacía = se genera)* | Contraseña del usuario `sa` de SQL Server |
| `INSTALL_MSSQL_TOOLS` | `false` | `true` agrega `sqlcmd` y `bcp` a la imagen |
| `DOPPLER_TOKEN` | *(vacía)* | Service token de Doppler para usar `doppler run` sin `doppler login` |

### Recursos por instancia (memoria y CPUs)

Cada instancia tiene sus propios **topes**, guardados en su `.env`: `MEM_LIMIT`, `CPUS`, `SHM_SIZE`, `PIDS_LIMIT` y `MSSQL_MEM_LIMIT`. Son máximos, **no reservas**: una instancia que no usa su memoria no se la quita a las demás. Por eso la suma de los topes puede superar la RAM del servidor; solo habría problema si varias instancias llegaran a usarlos a la vez (`aiws ls` y `aiws resources` muestran la suma frente a la RAM y avisan).

**Al instalar**, con tus valores:

```bash
curl -fsSL https://raw.githubusercontent.com/heratok/ai-workspace/main/install.sh | bash -s -- --mem 4g --cpus 2
```

Si no los indicas, en una instancia **nueva** `setup.sh` sugiere valores según la RAM del servidor, sus CPUs y cuántas instancias hay ya: `(RAM - 2g para el servidor) / (instancias + 1)`, entre 2g y 8g, y como máximo 4 CPUs. Con terminal pregunta `Memoria máxima [3g]` y `CPUs [2]` (Enter acepta la sugerencia); sin terminal aplica la sugerencia y la muestra. Nunca se cambian solos los valores de una instancia que ya existe.

**Cambiar después, sin reconstruir** (solo se recrean los contenedores de esa instancia):

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

### Componentes: instala solo lo que necesitas

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

## Operación

### Comandos de `setup.sh`

Se ejecutan desde la carpeta de la instancia (`./setup.sh COMANDO` o `bash setup.sh COMANDO`). Con varias instancias, `aiws` ejecuta los mismos comandos sin cambiar de carpeta.

| Comando | Para qué |
|---|---|
| `setup.sh` | **Menú**: instalar o actualizar, ver el progreso, estado, agregar clave SSH, respaldar, desinstalar. Si hay una instalación en curso, lo avisa y la opción por defecto es ver el progreso |
| `install` | Instala o reinstala todo. Con `--alias NOMBRE` crea una instancia aislada (lo normal es usar `install.sh`). También acepta `--authkey`, `--pubkey`, `--mem`, `--cpus` y `--foreground` |
| `progress` | Ver en vivo el progreso (o el resultado) de la última instalación o actualización, por ejemplo tras reconectar |
| `upgrade` | **Descarga lo último de GitHub**, migra y reconstruye (ver [Actualizar](#actualizar-a-la-última-versión)) |
| `update` | Reconstruye la imagen sin caché, con versiones nuevas |
| `rollback` | Vuelve a la versión anterior al último `upgrade` y reconstruye |
| `components` | Elige qué agentes y herramientas trae la imagen (y reconstruye) |
| `resources [--mem 4g --cpus 2 ...]` | Ver límites y uso real, o cambiarlos sin reconstruir (`--set` pregunta cada valor, `--no-apply` solo guarda) |
| `backup` | Respalda el home y los proyectos (incluidas las bases de `devdb`) en `./backups/*.tar.gz` |
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

Si el build falla, el contenedor anterior **sigue funcionando**: solo se reemplaza cuando la imagen nueva se construye bien. Antes de actualizar un servidor, comprueba que el CI de `main` esté en verde (ver [CI](#verificación-automática-ci)).

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

- **Migraciones** (`migrations/NNN-*.sh`): cada mejora publicada puede traer un script que **limpia o adapta** lo que dejó la versión anterior (variables obsoletas del `.env`, volúmenes o contenedores renombrados…). Cada uno corre **una sola vez por servidor**, en orden, durante `upgrade`, `update` e `install`, y queda registrado en `logs/.migrations-done`. La `001` limpia restos de versiones anteriores sin borrar datos; la `002` convierte la vieja `NPM_GLOBAL_PACKAGES` del `.env` a los componentes `INSTALL_*` y deja lo que no reconoce en `NPM_EXTRA_PACKAGES`. Cómo escribir una nueva: [`migrations/README.md`](migrations/README.md).
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

```bash
gh auth login        # una vez, dentro del workspace; el token queda en ~/.config/gh (volumen ai_home)
gh repo clone org/repo /workspace/repo
```

## Bases de datos dentro del workspace, sin root

La imagen **no trae servidores de bases de datos**. Cuando necesites uno, lo instalas dentro del workspace, sin root y sin reconstruir la imagen, con `devdb`:

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

**Cómo instala sin root:**

1. `apt-get update` y `apt-get download` con un estado de apt propio en `~/.cache/devdb/apt`, usando los repos oficiales (PGDG y Debian) ya configurados en la imagen.
2. Descarga solo los paquetes pedidos y las librerías `lib*` que **falten** en la imagen.
3. Los extrae con `dpkg-deb -x` en `~/.local/opt/devdb/<servicio>`.
4. `devdb` arma el `LD_LIBRARY_PATH` automáticamente al ejecutar cada binario.

| | PostgreSQL | Redis |
|---|---|---|
| Dirección | `127.0.0.1:5432`, usuario `ai`, base de datos `dev` | `127.0.0.1:6379` |
| Variables ya definidas | `PGHOST`, `PGUSER`, `PGDATABASE`, `DATABASE_URL` | `REDIS_URL` |
| Binarios | `~/.local/opt/devdb/postgresql-<ver>` | `~/.local/opt/devdb/redis` |
| Datos | `~/.local/share/devdb/postgres` | `~/.local/share/devdb/redis` |

- **Persistencia:** binarios y datos quedan en el volumen `ai_home`, así que se conservan al reconstruir la imagen.
- **Seguridad:** solo escuchan en `127.0.0.1` y usan autenticación `trust` local. Es solo para desarrollo.
- **Desde tu PC:** `ssh -N -L 5432:127.0.0.1:5432 ai@ai-workspace` y luego conecta tu cliente a `localhost:5432`.
- **Servidor ya incluido en la imagen:** pon `INSTALL_PG_SERVER=true` en `.env` y ejecuta `./setup.sh update`. `devdb` lo detecta solo.

### SQL Server (la única excepción)

SQL Server no puede correr sin root dentro del workspace. Si lo necesitas, va en un contenedor aparte (opcional):

```bash
# en .env
COMPOSE_PROFILES=mssql
INSTALL_MSSQL_TOOLS=true     # agrega sqlcmd/bcp a la imagen
# luego
./setup.sh install
# dentro del workspace
sqlcmd -C -Q "SELECT @@VERSION"   # ya vienen SQLCMDSERVER, SQLCMDUSER y SQLCMDPASSWORD
```

Solo funciona en servidores x86_64 y necesita unos 2 GB de RAM. La contraseña la genera `setup.sh`.

## Instalar herramientas

Todo lo que instalas **sin root** queda en `ai_home`, así que sobrevive a `update` y a `uninstall` (pero no a `uninstall --all`). Lo que quieras para todo el equipo en cada instalación nueva, agrégalo a la imagen.

| Necesito… | Dónde / cómo | ¿Root? |
|---|---|---|
| Un paquete apt | Agregarlo a `config/packages.apt` y luego `update` | En el build |
| Un binario externo | Agregarlo a `config/extra-root.sh` y luego `update` | En el build |
| Una herramienta npm fija para todos | `NPM_EXTRA_PACKAGES` en `.env` y luego `update` | En el build |
| Una herramienta npm puntual o una actualización | `npm i -g pkg` (queda en `~/.npm-global`) | No |
| Una herramienta Python | `uv tool install ruff` (queda en `~/.local/bin`) | No |
| Otra versión de Node, Python o Go | `mise use -g node@22`, o un `.mise.toml` por repositorio | No |
| Otra versión del navegador de Playwright | `npx playwright install chromium` o `playwright-cli install-browser chromium` | No |
| Un servidor de base de datos (PostgreSQL, Redis) | `devdb install postgres 17` o `devdb install redis` | No |
| CLIs como binario (Go, Rust, Java, Terraform, kubectl, Bun, Deno…) | `mise use -g go@latest`, `mise use -g terraform`, `mise use -g bun` (busca con `mise registry`) | No |

### Instaladores `curl | sh` (opencode, bun, deno, rust…)

Funcionan **sin root**: escriben en tu home, y esas carpetas ya están en el `PATH` y se conservan en `ai_home`.

```bash
curl -fsSL https://opencode.ai/install | bash      # -> ~/.opencode/bin/opencode
curl -fsSL https://bun.sh/install | bash           # -> ~/.bun/bin
curl -fsSL https://sh.rustup.rs | sh -s -- -y      # -> ~/.cargo/bin
```

Si un instalador pide `sudo` o escribe en `/usr/local`, no va a funcionar como `ai`. En ese caso usa `mise`, `npm i -g` o `uv tool`, o agrégalo a la imagen en `config/extra-root.sh`. Para tener opencode en la imagen para todo el equipo, actívalo en `./setup.sh components`.

### Herdr (incluido)

[Herdr](https://herdr.dev) mantiene las terminales de los agentes vivas aunque cierres SSH, y desde cualquier dispositivo retomas donde ibas:

```bash
herdr          # abre o retoma tus sesiones de agentes (Claude Code, opencode, Pi…)
```

El instalador oficial verifica el SHA-256 y deja el binario en `/usr/local/bin`. Se actualiza con `./setup.sh update`. Para una versión más nueva solo para ti, sin root: `curl -fsSL https://herdr.dev/install.sh | sh` (instala en `~/.local/bin`, que tiene prioridad en el `PATH`).

### Gentle AI y Antigravity CLI (agy)

```bash
gentle-ai          # configurador interactivo: agentes, memoria (Engram), skills y flujos
gentle-ai doctor   # diagnóstico, sin cambios

agy                # Antigravity CLI. La primera vez muestra una URL: ábrela en tu PC,
                   # aprueba con tu cuenta Google y pega el código (tienes ~30 s)
```

- Gentle AI escribe su configuración en tu home (`~/.claude`, configuración de opencode, etc.), dentro del volumen `ai_home`.
- **agy en un servidor sin navegador:** también puedes hacer login en tu PC y copiar `~/.gemini/antigravity-cli/antigravity-oauth-token` a la misma ruta dentro del workspace.

### Doppler (secretos)

La CLI de [Doppler](https://docs.doppler.com) evita dejar API keys y contraseñas en archivos `.env` dentro de los proyectos.

```bash
doppler login                 # una vez, dentro del workspace; muestra un código o link para aprobar en el navegador
cd /workspace/mi-proyecto
doppler setup                 # elige proyecto y config (dev, stg…)
doppler run -- npm run dev    # inyecta los secretos como variables de entorno
```

- La sesión queda en `~/.doppler` (volumen `ai_home`), así que no repites el login al reconstruir.
- **Sin login (agentes o automatizaciones):** pon un *service token* de solo lectura en `DOPPLER_TOKEN` en el `.env` y ejecuta `./setup.sh update`.

### Playwright para agentes

```bash
playwright-cli open https://example.com     # navegador headless con Chromium incluido
playwright-cli snapshot                     # árbol de elementos para el agente
playwright-cli click e12 && playwright-cli close
claude mcp add playwright -- playwright-mcp # registrar el servidor MCP en Claude Code
```

`PLAYWRIGHT_MCP_BROWSER=chromium` ya viene definido, así que no intenta usar Google Chrome, que necesitaría root.

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| Se cayó SSH durante `install` o `update` | La instalación continúa en segundo plano. Reconecta y ejecuta `./setup.sh progress` |
| `aiws: command not found` | `setup.sh install` o `update` crea el enlace, y avisa si `~/.local/bin` no está en tu `PATH`. Agrégalo, o enlázalo a mano: `ln -s ~/ai-workspace/aiws ~/.local/bin/aiws` |
| `aiws` dice "Instancia desconocida" | Revisa los alias con `aiws ls`. `default` (o `principal`) es la principal |
| `aiws upgrade` sale con código 2 | Sin terminal, la confirmación es obligatoria: agrega `--yes` |
| `./setup.sh upgrade` falla sin terminal | Usa `./setup.sh upgrade --yes` |
| `install.sh` creó otra instancia en vez de actualizar | Con la principal ya instalada y sin alias, crea una nueva. Para actualizar usa `./setup.sh upgrade`, `aiws upgrade ALIAS` o `--alias NOMBRE` |
| "El contenedor … lo gestiona otra carpeta" | Una carpeta es una instancia. Usa esa carpeta, o elige otro alias |
| Tras `upgrade`, algo dejó de funcionar | `./setup.sh rollback` vuelve a la versión anterior y reconstruye |
| El `build` falla durante `update` o `upgrade` | El contenedor anterior sigue en pie. Revisa el log con `./setup.sh progress` o `logs/latest.log` |
| Alerta "host key changed" al conectar por SSH | Se borró el volumen `ai_ssh_host_keys`. Quita la entrada vieja de `~/.ssh/known_hosts` |
| El nodo pide auth key otra vez | Se borró el volumen `ai_ts_state`: es un nodo nuevo. Pega una auth key o usa el link de login |
| No entro por SSH | Comprueba `./setup.sh ts-status` y `./setup.sh doctor`. Si no autorizaste tu clave: `./setup.sh add-key` |
| Permisos incorrectos en el home tras cambiar `USER_UID` / `USER_GID` | Pon `FIX_OWNERSHIP=true` una sola vez y ejecuta `./setup.sh update` |
| El frontend no abre en `:3000` / `:5173` | El servidor de desarrollo debe escuchar en `0.0.0.0` (p. ej. `vite --host`) |
| `agy` falla con `Illegal instruction` | El servidor (o su VM) no expone las instrucciones AES de la CPU. Habilítalas en el hipervisor o desmarca el componente |
| La suma de `MEM_LIMIT` supera la RAM | Es un aviso, no un error: son topes. Ajusta con `aiws resources ALIAS --mem 4g` si varias instancias usan memoria a la vez |

## Verificación automática (CI)

Cada push a `main`, cada pull request y la ejecución manual pasan por `.github/workflows/ci.yml`, que corre en `ubuntu-24.04`:

- **lint:** sintaxis de todos los scripts, ShellCheck (solo errores), pruebas de multi-instancia (`tests/instances.test.sh`) y de `aiws` (`tests/aiws.test.sh`), y validación del compose con los nombres de la instancia principal y de una con alias.
- **build:** construye la imagen completa y verifica que estén las herramientas (`claude`, `pi`, `playwright`, `herdr`, `doppler`, `gentle-ai`, `agy`, etc.).

`actions/checkout` está fijado por SHA (v7.0.1) y Dependabot revisa cada semana las acciones de `.github/workflows/` (`.github/dependabot.yml`). Si el CI sale en rojo, no hagas `upgrade` hasta que se corrija.

## Migración desde v1

1. En la carpeta v1, ejecuta `docker compose down`. Los volúmenes `ai_home` y `ai_workspace` no se tocan.
2. Revisa el home: si tienes Node o herramientas instaladas a mano (`~/.nvm`, `~/.local/bin/node`), quítalas para que no tapen las de la imagen.
3. Pasa a `config/extra-root.sh` las herramientas que instalabas a mano, apuntando a `/usr/local/bin`.
4. Ejecuta `./setup.sh install`.
5. Actualiza tus clientes: `ssh ai@ai-workspace` en el puerto 22. El puerto 2222 y la IP fija anterior ya no se usan.
