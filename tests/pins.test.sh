#!/usr/bin/env bash
# =============================================================================
# Pruebas de versiones fijadas (builds reproducibles).
#
#   bash tests/pins.test.sh
#
# Sin red ni Docker: son comprobaciones estáticas de Dockerfile, compose,
# env.example y dependabot. Evitan que vuelva a colarse un "latest" implícito.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT/Dockerfile"
COMPOSE="$ROOT/docker-compose.yml"
ENVEX="$ROOT/env.example"
DEPENDABOT="$ROOT/.github/dependabot.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSES="$TMP/passes"; FAILS="$TMP/fails"; : > "$PASSES"; : > "$FAILS"

ok()  { echo x >> "$PASSES"; return 0; }
nok() { echo "    FAIL: $*" >&2; echo x >> "$FAILS"; return 0; }
assert_has() { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1: debía contener '$3'"; fi; return 0; }
assert_match() { if [[ "$2" =~ $3 ]]; then ok; else nok "$1: '$2' no cumple $3"; fi; return 0; }

run() {
  echo "== $1"
  ( "$1" )
  local rc=$?
  if (( rc != 0 )); then nok "$1 terminó con código $rc"; fi
  return 0
}

# ARG de Dockerfile -> valor por defecto
default_of() { sed -n -E "s/^ARG $1=\"?([^\" ]*)\"?.*/\1/p" "$DOCKERFILE" | head -n1; }

PIN_ARGS=(CLAUDE_CODE_VERSION PI_VERSION OPENCODE_VERSION PLAYWRIGHT_VERSION PLAYWRIGHT_CLI_VERSION PLAYWRIGHT_MCP_VERSION UV_VERSION MISE_VERSION HERDR_VERSION GENTLE_AI_VERSION DOPPLER_VERSION)
SHA_ARGS=(HERDR_SHA256_AMD64 HERDR_SHA256_ARM64)
ALL_PINS=("${PIN_ARGS[@]}" "${SHA_ARGS[@]}")

t_every_pin_arg_has_a_concrete_default() {
  local a v
  for a in "${PIN_ARGS[@]}"; do
    v="$(default_of "$a")"
    assert_match "default de $a" "$v" '^v?[0-9]+\.[0-9]+\.[0-9]+$'
  done
}

t_npm_packages_are_installed_with_explicit_versions() {
  local body; body="$(<"$DOCKERFILE")"
  assert_has "claude"   "$body" '@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}'
  assert_has "pi"       "$body" '@mariozechner/pi-coding-agent@${PI_VERSION:-latest}'
  assert_has "opencode" "$body" 'opencode-ai@${OPENCODE_VERSION:-latest}'
  assert_has "playwright" "$body" 'playwright@${PLAYWRIGHT_VERSION:-latest}'
  assert_has "pw cli"   "$body" '@playwright/cli@${PLAYWRIGHT_CLI_VERSION:-latest}'
  assert_has "pw mcp"   "$body" '@playwright/mcp@${PLAYWRIGHT_MCP_VERSION:-latest}'
}

t_uv_and_mise_are_pinned() {
  local body; body="$(<"$DOCKERFILE")"
  # Docker no expande variables en "COPY --from=": uv va como etapa propia (FROM acepta ARG global)
  assert_has "uv"   "$body" 'FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv'
  assert_has "uv copy" "$body" 'COPY --from=uv /uv /uvx /usr/local/bin/'
  assert_has "mise" "$body" 'MISE_VERSION=${MISE_VERSION}'
  if grep -q 'astral-sh/uv:latest' "$DOCKERFILE"; then nok "uv sigue en :latest"; else ok; fi
}

t_compose_forwards_every_pin() {
  local a
  for a in "${ALL_PINS[@]}"; do
    grep -qE "^[[:space:]]+$a: \\\$\{$a:-" "$COMPOSE" && ok || nok "compose no reenvía $a"
  done
}

t_compose_defaults_match_dockerfile() {
  local a d c
  for a in "${ALL_PINS[@]}"; do
    d="$(default_of "$a")"
    c="$(sed -n -E "s/^[[:space:]]+$a: \\\$\{$a:-([^}]*)\}.*/\1/p" "$COMPOSE" | head -n1)"
    [[ "$c" == "$d" ]] && ok || nok "$a: compose='$c' Dockerfile='$d'"
  done
}

t_env_example_documents_every_pin() {
  local a
  for a in "${ALL_PINS[@]}"; do
    grep -qE "^#? ?$a=" "$ENVEX" && ok || nok "env.example no documenta $a"
  done
}

t_tailscale_tag_is_not_stable() {
  local tag; tag="$(sed -n -E 's/^(# )?TS_IMAGE_TAG=(.*)/\2/p' "$ENVEX" | head -n1)"
  assert_match "TS_IMAGE_TAG en env.example" "$tag" '^v[0-9]+\.[0-9]+\.[0-9]+$'
  grep -qE 'TS_IMAGE_TAG:-v[0-9]+\.[0-9]+\.[0-9]+' "$COMPOSE" && ok || nok "compose no usa un tag fijo de tailscale por defecto"
}

t_dependabot_watches_docker_and_compose() {
  local body; body="$(<"$DEPENDABOT")"
  assert_has "docker"         "$body" 'package-ecosystem: docker'
  assert_has "docker-compose" "$body" 'package-ecosystem: docker-compose'
}

t_herdr_and_gentle_ai_checksums_are_pinned() {
  local a v
  for a in "${SHA_ARGS[@]}"; do
    v="$(default_of "$a")"
    assert_match "sha de $a" "$v" '^[0-9a-f]{64}$'
  done
}

t_herdr_and_gentle_ai_are_not_installed_with_live_scripts() {
  local body; body="$(<"$DOCKERFILE")"
  # ni el script de herdr.dev ni el de la rama main de gentle-ai: se ejecutaban en vivo y siempre traían la última
  if grep -qE 'herdr\.dev/install\.sh' <<< "$body"; then nok "Herdr no debe instalarse con herdr.dev/install.sh"; else ok; fi
  if grep -qE 'gentle-ai/main/scripts/install\.sh' <<< "$body"; then nok "Gentle AI no debe instalarse con el script de la rama main"; else ok; fi
  assert_has "binario de herdr" "$body" 'herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-'
  assert_has "checksum de herdr" "$body" 'HERDR_SHA256_AMD64'
  assert_has "archivo de gentle-ai" "$body" 'Gentleman-Programming/gentle-ai/releases/download/v${GENTLE_AI_VERSION}'
  assert_has "checksums.txt de gentle-ai" "$body" 'checksums.txt'
  [[ "$(grep -cE 'sha256sum -c' <<< "$body")" -ge 3 ]] && ok || nok "debe verificarse con sha256sum -c: node, herdr y gentle-ai (mínimo 3 usos)"
}

t_doppler_is_installed_from_its_pinned_release_not_apt() {
  local body; body="$(<"$DOCKERFILE")"
  if grep -qE 'packages.doppler.com' <<< "$body"; then nok "Doppler no debe instalarse desde su repo apt (sin versión)"; else ok; fi
  assert_has "doppler por release" "$body" 'DopplerHQ/cli/releases/download/${DOPPLER_VERSION}'
  assert_has "checksums de doppler" "$body" 'checksums.txt'
}

t_agy_always_installs_the_latest() {   # decisión: agy no se fija (Google no lista versiones ni da URLs predecibles)
  local body; body="$(<"$DOCKERFILE")"
  assert_has "instalador de agy" "$body" 'antigravity.google/cli/install.sh'
  if grep -qE 'ARG AGY_' <<< "$body"; then nok "agy no debe tener ARG de versión: siempre instala la última"; else ok; fi
}

t_image_label_lists_every_pinned_tool() {   # `./setup.sh tools` lee esta etiqueta para mostrar lo que hay REALMENTE en la imagen
  local body id; body="$(<"$DOCKERFILE")"
  assert_has "etiqueta" "$body" 'LABEL org.ai-workspace.versions='
  for id in claude-code pi opencode playwright playwright-cli playwright-mcp uv mise herdr gentle-ai doppler; do
    grep -qE "org\.ai-workspace\.versions=.*[\",]${id}=\\$\{[A-Z_]+_VERSION\}" <<< "$body" && ok || nok "la etiqueta de versiones no incluye $id"
  done
}

t_env_example_pins_are_commented_out() {
  # setup.sh crea el .env COPIANDO env.example y "upgrade" le agrega las claves que falten: si las versiones fijadas
  # estuvieran activas, cada servidor las congelaría para siempre y nunca recibiría los cambios del repo.
  # Van comentadas (solo documentan el valor por defecto); "./setup.sh tools" escribe un valor real cuando eliges uno.
  local a
  for a in "${ALL_PINS[@]}" TS_IMAGE_TAG; do
    if grep -qE "^$a=" "$ENVEX"; then nok "$a está activa en env.example: se copiaría al .env y congelaría el servidor (debe ir comentada: '# $a=...')"; else ok; fi
    grep -qE "^# $a=" "$ENVEX" && ok || nok "$a debe documentarse como '# $a=valor' en env.example"
  done
}

t_ci_checks_that_dotenv_pins_reach_the_build() {
  # ./setup.sh tools escribe las versiones en el .env: esa es TODA su promesa. Si compose dejara de reenviarlas al build
  # (o a la imagen de Tailscale), tools mostraría cambios que nunca se aplican. El CI lo comprueba con "docker compose config".
  local ci="$ROOT/.github/workflows/ci.yml"
  grep -q 'CLAUDE_CODE_VERSION=2.1.290' "$ci" && ok || nok "ci.yml debe escribir un override en el .env (CLAUDE_CODE_VERSION=2.1.290)"
  grep -qE 'CLAUDE_CODE_VERSION: 2[\]?[.]1[\]?[.]290' "$ci" && ok || nok "ci.yml debe comprobar que el override llega al build (CLAUDE_CODE_VERSION: 2.1.290)"
  grep -qE 'HERDR_VERSION: 0[\]?[.]9[\]?[.]3' "$ci" && ok || nok "ci.yml debe comprobar HERDR_VERSION del .env"
  grep -qE 'tailscale/tailscale:v1[\]?[.]100[\]?[.]0' "$ci" && ok || nok "ci.yml debe comprobar que TS_IMAGE_TAG del .env llega a la imagen de Tailscale"
}

t_dependabot_ignores_debian_major_bumps() {   # debian 12 -> 13 rompe el build (repos bookworm-pgdg/Microsoft): migración planificada aparte
  local blk; blk="$(awk '/package-ecosystem: docker$/ {on=1; next} /package-ecosystem:/ {on=0} on' "$DEPENDABOT")"
  grep -q 'dependency-name: debian' <<< "$blk" && ok || nok "dependabot (docker) debe ignorar debian"
  grep -q 'version-update:semver-major' <<< "$blk" && ok || nok "dependabot (docker) debe ignorar solo los saltos de versión mayor de debian"
  grep -q '^[[:space:]]*#.*debian-13-migration' "$DEPENDABOT" && ok || nok "la regla debe apuntar a odd/tasks/debian-13-migration.md en un comentario"
}

for t in t_every_pin_arg_has_a_concrete_default t_npm_packages_are_installed_with_explicit_versions \
         t_uv_and_mise_are_pinned t_compose_forwards_every_pin t_compose_defaults_match_dockerfile \
         t_env_example_documents_every_pin t_tailscale_tag_is_not_stable t_dependabot_watches_docker_and_compose t_dependabot_ignores_debian_major_bumps t_herdr_and_gentle_ai_checksums_are_pinned t_herdr_and_gentle_ai_are_not_installed_with_live_scripts t_doppler_is_installed_from_its_pinned_release_not_apt t_agy_always_installs_the_latest t_image_label_lists_every_pinned_tool t_env_example_pins_are_commented_out t_ci_checks_that_dotenv_pins_reach_the_build; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
