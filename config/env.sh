# Entorno común para TODAS las sesiones (SSH, mosh, bash, zsh, interactivas o no).
# Importante: las variables ENV del Dockerfile NO llegan a las sesiones SSH;
# por eso se definen aquí y se cargan desde /etc/profile.d y /etc/zsh/zshenv.

export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8

# Navegadores de Playwright horneados en la imagen
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# playwright-cli / playwright-mcp: usar el Chromium incluido (por defecto buscan Google Chrome)
export PLAYWRIGHT_MCP_BROWSER="${PLAYWRIGHT_MCP_BROWSER:-chromium}"

# Instalaciones de usuario SIN root (persisten en el volumen ai_home)
export NPM_CONFIG_PREFIX="$HOME/.npm-global"     # npm install -g  -> ~/.npm-global
export UV_TOOL_BIN_DIR="$HOME/.local/bin"         # uv tool install -> ~/.local/bin
export PIP_REQUIRE_VIRTUALENV=true                # evita pip install "global"
export MISE_DATA_DIR="$HOME/.local/share/mise"    # mise use node@22 / python@3.12 ...

# Bases de datos locales del workspace (devdb). psql se conecta sin parámetros.
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-${USER:-ai}}"
export PGDATABASE="${PGDATABASE:-dev}"
export DATABASE_URL="${DATABASE_URL:-postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}}"
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379/0}"

# Variables de servicios externos opcionales (SQL Server) generadas por entrypoint.sh
[ -r /etc/ai-workspace/runtime.env ] && . /etc/ai-workspace/runtime.env

# Orden: herramientas del usuario > runtimes de mise > imagen
__ws_prepend() { case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; }
__ws_prepend /usr/local/bin
# Carpetas que usan los instaladores "curl | sh" (opencode, bun, deno, rust...)
for __d in "$HOME/.opencode/bin" "$HOME/.bun/bin" "$HOME/.deno/bin" "$HOME/.cargo/bin" "$HOME/go/bin"; do
  [ -d "$__d" ] && __ws_prepend "$__d"
done
unset __d
__ws_prepend "$MISE_DATA_DIR/shims"
__ws_prepend "$NPM_CONFIG_PREFIX/bin"
__ws_prepend "$HOME/.local/bin"
unset -f __ws_prepend
export PATH

export EDITOR="${EDITOR:-vim}"
