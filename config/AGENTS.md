# Guía del entorno (léela antes de instalar o diagnosticar)

Estás en un contenedor Linux (Debian 12) como el usuario `ai`. No tienes root ni `sudo`, y `apt` no sirve para instalar. Todo se instala en tu home o en `/workspace`.

## Necesito X: comando

| Necesito | Comando |
|---|---|
| Herramienta npm global | `npm i -g paquete` (queda en `~/.npm-global`) |
| Herramienta Python (CLI) | `uv tool install ruff` (queda en `~/.local/bin`) |
| Paquetes Python de un proyecto | `uv venv` y luego `uv pip install paquete` |
| Otra versión de Node, Go, Terraform, Bun... | `mise use -g node@22`, `mise use -g go@latest` (busca con `mise registry`) |
| PostgreSQL o Redis | `devdb install postgres 17 pgvector`, `devdb install redis`, luego `devdb start` |
| Consola SQL local | `psql` (conecta a la base dev) |
| Secretos | `doppler run -- comando` |
| Autenticar GitHub | `gh auth login` |
| Navegador headless | `playwright-cli open https://example.com` |
| Diagnóstico del entorno | `ws-doctor` |

Los instaladores `curl | sh` que escriben en el home funcionan (opencode, bun, rustup). Los que piden `sudo` o escriben en `/usr/local` fallan: usa `mise`, `npm` o `uv`.

## Esto falla, y por qué

- `sudo ...` y `apt install ...`: no hay root. Busca el equivalente en la tabla.
- `pip install ...` fuera de un venv: bloqueado a propósito (`PIP_REQUIRE_VIRTUALENV=true`). Usa `uv venv`.
- Google Chrome real: requiere root. Usa el Chromium incluido; `PLAYWRIGHT_MCP_BROWSER=chromium` ya está definido.
- Un servidor de desarrollo que no se ve desde fuera: escucha en `0.0.0.0` (no solo `localhost`), por ejemplo en `:3000` o `:5173`.

## Persistencia

- Persiste: lo que instales en `~` y en `/workspace`.
- No persiste: `/usr/local`, `/opt` y `/etc` (se reconstruyen con la imagen).

## Servicios y variables ya definidas

- PostgreSQL: `127.0.0.1:5432`, usuario `ai`, base `dev`, `DATABASE_URL` lista (tras `devdb start`).
- Redis: `127.0.0.1:6379`, `REDIS_URL` lista.
- Secretos: `doppler login` una vez, o `DOPPLER_TOKEN` en el entorno.
- GitHub: `gh auth login` (la sesión queda en el volumen).

## Login OAuth con callback en localhost

Si la URL de login trae `redirect_uri=http://localhost:PUERTO/...`, el navegador del usuario (su PC) no llega a este contenedor y falla con ERR_CONNECTION_REFUSED. Anota el PUERTO y pide al usuario uno de estos métodos, en orden:

- A) En su sesión SSH, sin reconectar: pulsar `~C` y escribir `-L PUERTO:127.0.0.1:PUERTO` (Enter).
- B) Puerto fijo (pi usa 53692): `LocalForward 53692 127.0.0.1:53692` bajo `Host ai-workspace` en su `~/.ssh/config`.
- C) Sin túnel (probar primero; no verificado con todas las herramientas): que copie la URL completa de la barra de direcciones y ejecutarla aquí con `curl '<url>'` mientras la herramienta sigue esperando.

`mosh` no reenvía puertos. `gh auth login`, `doppler login` y `agy` no lo necesitan.

## No investigues

Mira primero esta guía. No pruebes `sudo`, `apt` ni instaladores al azar para averiguar qué se puede. Para diagnosticar ejecuta `ws-doctor`; para releer esta guía, `ws-doctor --guide`.

<!-- componentes -->
