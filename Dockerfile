# syntax=docker/dockerfile:1.7
# Imagen "todo incluido": nada del sistema se instala a mano después.
# Todo lo de sistema va en /usr/local u /opt (el volumen ai_home oculta /home/ai).
FROM debian:12-slim
# Etiqueta para que "setup.sh clean" borre solo imágenes viejas de este proyecto
LABEL org.ai-workspace.image="true"

ARG DEBIAN_FRONTEND=noninteractive
ARG USERNAME=ai
ARG USER_UID=1000
ARG USER_GID=1000
# Node: deja NODE_VERSION vacío para tomar la última del major, o fíjala (ej. 24.11.1)
ARG NODE_MAJOR=24
ARG NODE_VERSION=""
# --- Componentes (se eligen con "./setup.sh components"; true/false) ---
ARG INSTALL_CLAUDE=true
ARG INSTALL_PI=true
ARG INSTALL_OPENCODE=false
ARG INSTALL_PLAYWRIGHT=true
ARG INSTALL_PLAYWRIGHT_BROWSERS=true
ARG INSTALL_GENTLE_AI=true
ARG INSTALL_AGY=true
# CLIs npm adicionales para todo el equipo (separadas por espacio)
ARG NPM_EXTRA_PACKAGES=""
# PostgreSQL dentro del workspace (servidor + cliente) y extensiones (postgresql-<major>-<ext>)
ARG PG_MAJOR=17
# false = la BD se instala bajo demanda con "devdb install" (sin root)
ARG INSTALL_PG_SERVER=false
ARG PG_EXTENSIONS="pgvector"
ARG INSTALL_MSSQL_TOOLS=false
# Herdr (runtime persistente para agentes, https://herdr.dev)
ARG INSTALL_HERDR=true
# Doppler CLI (gestor de secretos, https://docs.doppler.com)
ARG INSTALL_DOPPLER=true

SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# 1. Paquetes del sistema (lista declarativa en config/packages.apt)
# ---------------------------------------------------------------------------
COPY config/packages.apt /tmp/packages.apt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && grep -vE '^\s*(#|$)' /tmp/packages.apt | xargs apt-get install -y --no-install-recommends \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && rm -f /etc/ssh/ssh_host_* /tmp/packages.apt

# ---------------------------------------------------------------------------
# 1b. Repos oficiales: GitHub CLI, PostgreSQL (PGDG) y, opcional, Microsoft SQL
#     El servidor PostgreSQL se instala SIN cluster: cada usuario crea el suyo con "devdb"
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    arch="$(dpkg --print-architecture)" \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
 && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list \
 && pkgs=(gh "postgresql-client-${PG_MAJOR}" libpq-dev) \
 && if [[ "${INSTALL_DOPPLER}" == "true" ]]; then \
      curl -fsSL --retry 3 'https://packages.doppler.com/public/cli/gpg.DE2A7741A397C129.key' \
        | gpg --dearmor -o /etc/apt/keyrings/doppler.gpg \
   && echo "deb [signed-by=/etc/apt/keyrings/doppler.gpg] https://packages.doppler.com/public/cli/deb/debian any-version main" \
        > /etc/apt/sources.list.d/doppler-cli.list \
   && pkgs+=(doppler); \
    fi \
 && if [[ "${INSTALL_PG_SERVER}" == "true" ]]; then \
      install -d /etc/postgresql-common \
   && echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.conf \
   && pkgs+=("postgresql-${PG_MAJOR}") \
   && for ext in ${PG_EXTENSIONS}; do pkgs+=("postgresql-${PG_MAJOR}-${ext}"); done; \
    fi \
 && if [[ "${INSTALL_MSSQL_TOOLS}" == "true" ]]; then \
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
   && echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/microsoft.list \
   && pkgs+=(mssql-tools18 unixodbc-dev); \
    fi \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "${pkgs[@]}" \
 && if [[ -d /opt/mssql-tools18/bin ]]; then ln -sf /opt/mssql-tools18/bin/* /usr/local/bin/; fi \
 && gh --version | head -n1 && psql --version

# Locale UTF-8 (mosh y CLIs)
RUN sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# 2. Node.js oficial (verificado con SHA256) en /usr/local
# ---------------------------------------------------------------------------
RUN case "$(dpkg --print-architecture)" in \
      amd64) arch=x64 ;; arm64) arch=arm64 ;; *) echo "arquitectura no soportada"; exit 1 ;; \
    esac \
 && if [[ -n "${NODE_VERSION}" ]]; then v="v${NODE_VERSION#v}"; \
    else v="$(curl -fsSL https://nodejs.org/dist/index.json \
          | jq -r --arg m "v${NODE_MAJOR}." 'map(select(.version|startswith($m)))[0].version')"; fi \
 && f="node-${v}-linux-${arch}.tar.xz" \
 && cd /tmp \
 && curl -fsSLO "https://nodejs.org/dist/${v}/${f}" \
 && curl -fsSL "https://nodejs.org/dist/${v}/SHASUMS256.txt" | grep " ${f}\$" | sha256sum -c - \
 && tar -xJf "${f}" -C /usr/local --strip-components=1 --no-same-owner \
 && rm -f "${f}" \
 && (corepack enable || true) \
 && node --version && npm --version

# ---------------------------------------------------------------------------
# 3. Gestores sin root: uv (Python) y mise (otros runtimes por usuario/proyecto)
# ---------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && mise --version && uv --version

# ---------------------------------------------------------------------------
# 4. CLIs globales de npm horneadas en la imagen (/usr/local)
# ---------------------------------------------------------------------------
RUN pkgs=() \
 && if [[ "${INSTALL_CLAUDE}" == "true" ]];     then pkgs+=(@anthropic-ai/claude-code); fi \
 && if [[ "${INSTALL_PI}" == "true" ]];         then pkgs+=(@mariozechner/pi-coding-agent); fi \
 && if [[ "${INSTALL_OPENCODE}" == "true" ]];   then pkgs+=(opencode-ai); fi \
 && if [[ "${INSTALL_PLAYWRIGHT}" == "true" ]]; then pkgs+=(playwright @playwright/cli @playwright/mcp); fi \
 && read -ra extra <<< "${NPM_EXTRA_PACKAGES}" && pkgs+=("${extra[@]}") \
 && if (( ${#pkgs[@]} )); then \
      echo "npm global: ${pkgs[*]}" \
   && npm install -g --omit=dev --no-fund --no-audit "${pkgs[@]}" \
   && npm cache clean --force; \
    fi

# ---------------------------------------------------------------------------
# 5. Chromium de Playwright + sus librerías (reemplaza la lista manual de libs)
# ---------------------------------------------------------------------------
# playwright-cli y playwright-mcp traen su propia versión de Playwright: se descarga
# el Chromium que corresponde a cada una (si la revisión coincide, no se duplica).
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    if [[ "${INSTALL_PLAYWRIGHT}" == "true" && "${INSTALL_PLAYWRIGHT_BROWSERS}" == "true" ]]; then \
      playwright install --with-deps chromium \
   && find /usr/local/lib/node_modules -path '*/playwright-core/cli.js' -print0 \
      | xargs -0 -r -I{} node {} install chromium; \
    fi \
 && mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"

# ---------------------------------------------------------------------------
# 6. Herdr (instalador oficial: verifica SHA-256, no toca archivos rc)
#    Se instala en /usr/local/bin para que sobreviva al volumen ai_home.
# ---------------------------------------------------------------------------
RUN if [[ "${INSTALL_HERDR}" == "true" ]]; then \
      curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh \
   && ls -l /usr/local/bin/herdr*; \
    fi

# ---------------------------------------------------------------------------
# 6a. Gentle AI (instalador oficial, binario de GitHub Releases con checksum)
#     y Antigravity CLI "agy" (instalador oficial; instala en ~/.local/bin, se mueve
#     a /usr/local/bin para que no lo oculte el volumen ai_home)
# ---------------------------------------------------------------------------
RUN if [[ "${INSTALL_GENTLE_AI}" == "true" ]]; then \
      curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh \
        | bash -s -- --method binary --dir /usr/local/bin \
   && /usr/local/bin/gentle-ai --version; \
    fi
RUN if [[ "${INSTALL_AGY}" == "true" ]]; then \
      tmp_home="$(mktemp -d)" \
   && curl -fsSL https://antigravity.google/cli/install.sh | HOME="$tmp_home" bash \
   && install -m 755 "$tmp_home/.local/bin/agy" /usr/local/bin/agy \
   && rm -rf "$tmp_home" \
   && ls -l /usr/local/bin/agy; \
    fi

# ---------------------------------------------------------------------------
# 6b. Herramientas extra (Moshi, binarios propios...) -> config/extra-root.sh
# ---------------------------------------------------------------------------
COPY --chmod=755 config/extra-root.sh /tmp/extra-root.sh
RUN /tmp/extra-root.sh && rm -f /tmp/extra-root.sh

# ---------------------------------------------------------------------------
# 7. Usuario sin privilegios y entorno para sesiones SSH
# ---------------------------------------------------------------------------
RUN groupadd -g "${USER_GID}" "${USERNAME}" \
 && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /usr/bin/zsh "${USERNAME}" \
 && mkdir -p /workspace /run/sshd /etc/ssh/host_keys /etc/ai-workspace \
 && chown "${USERNAME}:${USERNAME}" /workspace \
 && chown -R "${USERNAME}:${USERNAME}" /opt/ms-playwright

COPY config/env.sh   /etc/ai-workspace/env.sh
COPY config/zshrc    /etc/ai-workspace/zshrc
COPY config/AGENTS.md /etc/ai-workspace/AGENTS.md
COPY config/seed-guide.sh /etc/ai-workspace/seed-guide.sh
COPY --chown=${USER_UID}:${USER_GID} config/skel/zshrc /etc/skel-ai/.zshrc
COPY config/sshd-ai-workspace.conf /etc/ssh/sshd_config.d/10-ai-workspace.conf
COPY --chmod=755 config/ws-doctor /usr/local/bin/ws-doctor
COPY --chmod=755 config/devdb /usr/local/bin/devdb
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# ENV de Docker no llega a sesiones SSH: se carga para bash (login) y zsh (siempre)
RUN ln -sf /etc/ai-workspace/env.sh /etc/profile.d/10-ai-workspace.sh \
 && echo '. /etc/ai-workspace/env.sh' >> /etc/zsh/zshenv \
 && echo '. /etc/ai-workspace/env.sh' >> /etc/bash.bashrc \
 && echo '[[ -r /etc/ai-workspace/zshrc ]] && source /etc/ai-workspace/zshrc' >> /etc/zsh/zshrc \
 && sed -i "s/^AllowUsers .*/AllowUsers ${USERNAME}/" /etc/ssh/sshd_config.d/10-ai-workspace.conf

# Guía para agentes: anexa los componentes realmente incluidos en esta imagen
RUN yn() { [[ "$1" == "true" ]] && echo sí || echo no; } \
 && { echo; echo "## Componentes incluidos en esta imagen"; echo; \
      echo "- Claude Code: $(yn "${INSTALL_CLAUDE}")"; \
      echo "- Pi: $(yn "${INSTALL_PI}")"; \
      echo "- opencode: $(yn "${INSTALL_OPENCODE}")"; \
      echo "- Playwright (playwright, playwright-cli, playwright-mcp): $(yn "${INSTALL_PLAYWRIGHT}")"; \
      echo "- Gentle AI: $(yn "${INSTALL_GENTLE_AI}")"; \
      echo "- Antigravity (agy): $(yn "${INSTALL_AGY}")"; \
      echo "- Herdr: $(yn "${INSTALL_HERDR}")"; \
      echo "- Doppler: $(yn "${INSTALL_DOPPLER}")"; \
      echo "- Servidor PostgreSQL en la imagen: $(yn "${INSTALL_PG_SERVER}") (si no, usa devdb install postgres)"; \
      echo "- sqlcmd (SQL Server tools): $(yn "${INSTALL_MSSQL_TOOLS}")"; \
    } >> /etc/ai-workspace/AGENTS.md

ENV WORKSPACE_USER=${USERNAME}
WORKDIR /workspace
EXPOSE 22 60000-60010/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/22' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
