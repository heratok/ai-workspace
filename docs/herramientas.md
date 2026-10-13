# Imagen y herramientas

[← Volver al README](../README.md)

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

### Guía para agentes

La imagen trae una guía corta (`/etc/ai-workspace/AGENTS.md`, fuente: `config/AGENTS.md`) que explica a los agentes qué se puede instalar sin root y cómo, qué falla y por qué, y qué componentes incluye esta imagen.

- En cada arranque, `entrypoint.sh` siembra `/workspace/AGENTS.md` (enlace a la guía) y `/workspace/CLAUDE.md` (importa la guía con `@`). Así Claude Code, opencode, Pi y otros la leen solos.
- Si esos archivos ya existen (incluso modificados), no se tocan. Nunca se escribe en `~/.claude`, `~/.config/opencode`, etc.
- Para leerla tú: `ws-doctor --guide`. `ws-doctor` avisa si falta.

### Login OAuth con callback en localhost

Algunas herramientas (pi, MCPs con OAuth, etc.) abren una URL de login cuyo `redirect_uri` es `http://localhost:PUERTO/...`. Ese `localhost` es el de **tu PC**, no el del contenedor donde espera la herramienta, así que el navegador termina en `ERR_CONNECTION_REFUSED`. El `sshd` corre dentro del contenedor (comparte red con el sidecar de Tailscale, sin puertos publicados en el host) y permite `AllowTcpForwarding yes`, así que un túnel `ssh -L` desde tu PC llega al loopback del contenedor. El `PUERTO` aparece en el `redirect_uri` de la URL de login.

Tres métodos, en este orden:

- **A) Agregar el túnel sin reconectar.** Dentro de la sesión SSH pulsa `~C` (al inicio de una línea, tras Enter) y escribe `-L PUERTO:127.0.0.1:PUERTO`. Luego abre la URL de login en tu navegador. Sirve para puertos aleatorios.
- **B) Puerto fijo en `~/.ssh/config` (Windows: `%USERPROFILE%\.ssh\config`).** Para herramientas con puerto fijo, como pi (`53692`):

  ```
  Host ai-workspace
      HostName ai-workspace
      User ai
      LocalForward 53692 127.0.0.1:53692
  ```

  `53692` es el puerto de pi. Para puertos aleatorios usa A o C.
- **C) Sin túnel (probar primero; no verificado con todas las herramientas).** Tras autorizar, copia la URL completa de la barra de direcciones (la del error) y, dentro del contenedor y mientras la herramienta sigue esperando, ejecuta `curl '<url>'`.

Notas:

- `mosh` no reenvía puertos: abre una sesión aparte con `ssh -N -L PUERTO:127.0.0.1:PUERTO ai@ai-workspace`.
- No lo necesitan `gh auth login`, `doppler login` ni `agy` (usan flujos de código o pegado).
- `ws-doctor` comprueba que el reenvío de puertos esté habilitado.

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
