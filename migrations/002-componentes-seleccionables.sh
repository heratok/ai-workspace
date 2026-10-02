# shellcheck shell=bash
# NPM_GLOBAL_PACKAGES (lista única) se reemplazó por componentes INSTALL_* + NPM_EXTRA_PACKAGES.
old="$(env_get NPM_GLOBAL_PACKAGES)"
if grep -qE '^NPM_GLOBAL_PACKAGES=' "$ENV_FILE" 2>/dev/null; then
  extra=""
  for p in $old; do
    case "$p" in
      @anthropic-ai/claude-code|@mariozechner/pi-coding-agent|playwright|@playwright/cli|@playwright/mcp) ;;
      opencode-ai) env_set INSTALL_OPENCODE true ;;
      *) extra+="${extra:+ }$p" ;;
    esac
  done
  if [[ -n "$extra" ]]; then
    env_set NPM_EXTRA_PACKAGES "$extra"
    info "  NPM_GLOBAL_PACKAGES -> NPM_EXTRA_PACKAGES=\"$extra\""
  fi
  env_del NPM_GLOBAL_PACKAGES
  info "  .env: NPM_GLOBAL_PACKAGES reemplazada por componentes (./setup.sh components)"
fi
