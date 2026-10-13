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

PIN_ARGS=(CLAUDE_CODE_VERSION PI_VERSION OPENCODE_VERSION PLAYWRIGHT_VERSION PLAYWRIGHT_CLI_VERSION PLAYWRIGHT_MCP_VERSION UV_VERSION MISE_VERSION)

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
  for a in "${PIN_ARGS[@]}"; do
    grep -qE "^[[:space:]]+$a: \\\$\{$a:-" "$COMPOSE" && ok || nok "compose no reenvía $a"
  done
}

t_compose_defaults_match_dockerfile() {
  local a d c
  for a in "${PIN_ARGS[@]}"; do
    d="$(default_of "$a")"
    c="$(sed -n -E "s/^[[:space:]]+$a: \\\$\{$a:-([^}]*)\}.*/\1/p" "$COMPOSE" | head -n1)"
    [[ "$c" == "$d" ]] && ok || nok "$a: compose='$c' Dockerfile='$d'"
  done
}

t_env_example_documents_every_pin() {
  local a
  for a in "${PIN_ARGS[@]}"; do
    grep -qE "^#? ?$a=" "$ENVEX" && ok || nok "env.example no documenta $a"
  done
}

t_tailscale_tag_is_not_stable() {
  local tag; tag="$(sed -n -E 's/^TS_IMAGE_TAG=(.*)/\1/p' "$ENVEX" | head -n1)"
  assert_match "TS_IMAGE_TAG en env.example" "$tag" '^v[0-9]+\.[0-9]+\.[0-9]+$'
  grep -qE 'TS_IMAGE_TAG:-v[0-9]+\.[0-9]+\.[0-9]+' "$COMPOSE" && ok || nok "compose no usa un tag fijo de tailscale por defecto"
}

t_dependabot_watches_docker_and_compose() {
  local body; body="$(<"$DEPENDABOT")"
  assert_has "docker"         "$body" 'package-ecosystem: docker'
  assert_has "docker-compose" "$body" 'package-ecosystem: docker-compose'
}

t_dependabot_ignores_debian_major_bumps() {   # debian 12 -> 13 rompe el build (repos bookworm-pgdg/Microsoft): migración planificada aparte
  local blk; blk="$(awk '/package-ecosystem: docker$/ {on=1; next} /package-ecosystem:/ {on=0} on' "$DEPENDABOT")"
  grep -q 'dependency-name: debian' <<< "$blk" && ok || nok "dependabot (docker) debe ignorar debian"
  grep -q 'version-update:semver-major' <<< "$blk" && ok || nok "dependabot (docker) debe ignorar solo los saltos de versión mayor de debian"
  grep -q '^[[:space:]]*#.*debian-13-migration' "$DEPENDABOT" && ok || nok "la regla debe apuntar a odd/tasks/debian-13-migration.md en un comentario"
}

for t in t_every_pin_arg_has_a_concrete_default t_npm_packages_are_installed_with_explicit_versions \
         t_uv_and_mise_are_pinned t_compose_forwards_every_pin t_compose_defaults_match_dockerfile \
         t_env_example_documents_every_pin t_tailscale_tag_is_not_stable t_dependabot_watches_docker_and_compose t_dependabot_ignores_debian_major_bumps; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
