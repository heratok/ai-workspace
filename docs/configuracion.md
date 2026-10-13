# Referencia de configuración

[← Volver al README](../README.md)

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

### Versiones fijadas de la imagen

Para que dos builds del mismo commit den la misma imagen, las herramientas llevan su versión fijada (en el `Dockerfile`, reenviada por `docker-compose.yml` y documentada en `env.example`). Puedes sobrescribirlas en tu `.env` y aplicar con `./setup.sh update`; `latest` vuelve a flotar (no reproducible).

| Variable | Qué fija |
|----------|----------|
| `CLAUDE_CODE_VERSION`, `PI_VERSION`, `OPENCODE_VERSION` | CLIs de npm |
| `PLAYWRIGHT_VERSION`, `PLAYWRIGHT_CLI_VERSION`, `PLAYWRIGHT_MCP_VERSION` | Playwright y sus CLIs |
| `UV_VERSION`, `MISE_VERSION`, `TS_IMAGE_TAG` | `uv`, `mise` y la imagen de Tailscale |
| `HERDR_VERSION`, `HERDR_SHA256_AMD64`, `HERDR_SHA256_ARM64` | Binario de Herdr y el SHA-256 con el que se verifica |
| `GENTLE_AI_VERSION` | Gentle AI (se verifica con el `checksums.txt` de su release) |

Herdr y Gentle AI ya no se instalan ejecutando un script descargado en el momento: el build baja el binario de esa versión y comprueba su checksum. **No cambies a mano** las versiones ni los checksums de Herdr y Gentle AI: usa el script, que los mantiene consistentes en los tres archivos y calcula los checksums solo:

```bash
scripts/update-pins.sh list                # últimas 5 versiones estables de cada una (marca la fijada)
scripts/update-pins.sh choose herdr        # muestra las últimas 5 y te deja elegir cuál fijar
scripts/update-pins.sh set herdr 0.9.3     # fija una versión concreta
scripts/update-pins.sh set gentle-ai 4.1.0
scripts/update-pins.sh latest              # fija la última estable de ambas, sin preguntar
```

Después revisa el cambio con `git diff` y reconstruye (`./setup.sh update`); en un PR, el CI construye la imagen y comprueba que las herramientas funcionan. Siguen flotando `agy` (su instalador no permite fijar versión) y Doppler (paquete apt).
