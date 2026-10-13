# shellcheck shell=bash
# Fixtures compartidos de las pruebas de update-pins y de tools: respuestas falsas de la API de GitHub y del registro de npm.
# Se carga con source desde tests/update-pins.test.sh y tests/tools.test.sh (requieren $TMP).

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # amd64 de 0.9.3
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"   # arm64 de 0.9.3
SHA_C="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"   # amd64 de 0.9.4
SHA_D="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"   # arm64 de 0.9.4

herdr_rel() {   # herdr_rel <tag> <amd64> <arm64> [prerelease]
  printf '{"tag_name":"%s","prerelease":%s,"published_at":"2026-10-0%sT10:00:00Z","assets":[{"name":"herdr-linux-aarch64","digest":"sha256:%s"},{"name":"herdr-linux-x86_64","digest":"sha256:%s"},{"name":"herdr-macos-x86_64","digest":"sha256:%s"}]}' \
    "$1" "${4:-false}" "$((RANDOM % 9 + 1))" "$3" "$2" "$2"
}

npm_fx() {   # npm_fx <paquete> <última> <versiones...>: doc /latest y doc completo (formato abreviado) del registro
  local pkg="$1" latest="$2"; shift 2
  local enc="${pkg//\//%2F}" vs="" v
  for v in "$@" "$latest"; do vs+="\"$v\":{\"name\":\"$pkg\",\"version\":\"$v\",\"dist\":{\"tarball\":\"https://registry.npmjs.org/$pkg/-/x-$v.tgz\"}},"; done
  printf '{"bin":{"x":"cli.js"},"dist":{"shasum":"abc"},"name":"%s","version":"%s"}' "$pkg" "$latest" > "$FIX/npm_${enc}_latest"
  printf '{"name":"%s","dist-tags":{"latest":"%s"},"versions":{%s}}' "$pkg" "$latest" "${vs%,}" > "$FIX/npm_${enc}"
}
gh_fx() {    # gh_fx <owner/repo> <tag>...: lista de releases (la primera es la más nueva; "!tag" = prerelease) y un doc por tag
  local repo="$1"; shift
  local base="${repo//\//_}" items="" t pre
  for t in "$@"; do
    pre=false; if [[ "$t" == !* ]]; then pre=true; t="${t#!}"; fi
    items+="{\"tag_name\":\"$t\",\"prerelease\":$pre,\"published_at\":\"2026-10-01T10:00:00Z\"},"
    printf '{"tag_name":"%s","prerelease":%s}' "$t" "$pre" > "$FIX/${base}_releases_tags_$t"
  done
  printf '[%s]' "${items%,}" > "$FIX/${base}_releases?per_page=30"
}

pins_fixtures() {   # crea $FIX con las respuestas falsas de GitHub y npm, y su "curl" falso ($FIX/fetch.sh); requiere $TMP
  FIX="$TMP/fix.$RANDOM"; mkdir -p "$FIX"
  local p="releases?per_page=30"
  {
    echo "["
    herdr_rel v0.9.4 "$SHA_C" "$SHA_D"; echo ","
    herdr_rel preview-2026-10-12-6d697e1e75ff "$SHA_C" "$SHA_D" true; echo ","
    herdr_rel v0.9.3 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.9.2 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel preview-2026-09-29-9dc3a1df2b56 "$SHA_A" "$SHA_B" true; echo ","
    herdr_rel v0.9.1 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.9.0 "$SHA_A" "$SHA_B"; echo ","
    herdr_rel v0.8.9 "$SHA_A" "$SHA_B"
    echo "]"
  } > "$FIX/herdrdev_herdr_$p"
  herdr_rel v0.9.3 "$SHA_A" "$SHA_B" > "$FIX/herdrdev_herdr_releases_tags_v0.9.3"
  herdr_rel v0.9.4 "$SHA_C" "$SHA_D" > "$FIX/herdrdev_herdr_releases_tags_v0.9.4"
  printf '{"tag_name":"v0.1.0","prerelease":false,"assets":[{"name":"herdr-macos-x86_64","digest":"sha256:%s"}]}' "$SHA_A" > "$FIX/herdrdev_herdr_releases_tags_v0.1.0"   # sin binario linux
  cat > "$FIX/Gentleman-Programming_gentle-ai_$p" <<'EOF'
[{"tag_name":"v4.2.0-beta.1","prerelease":true,"published_at":"2026-10-12T10:00:00Z"},
 {"tag_name":"v4.1.1","prerelease":false,"published_at":"2026-10-10T10:00:00Z"},
 {"tag_name":"v4.1.0","prerelease":false,"published_at":"2026-10-01T10:00:00Z"},
 {"tag_name":"v4.0.0","prerelease":false,"published_at":"2026-09-20T10:00:00Z"},
 {"tag_name":"v3.7.0","prerelease":false,"published_at":"2026-09-10T10:00:00Z"},
 {"tag_name":"v3.6.1","prerelease":false,"published_at":"2026-09-01T10:00:00Z"},
 {"tag_name":"v3.6.0","prerelease":false,"published_at":"2026-08-20T10:00:00Z"}]
EOF
  echo '{"tag_name":"v4.1.0","prerelease":false}' > "$FIX/Gentleman-Programming_gentle-ai_releases_tags_v4.1.0"
  echo '{"tag_name":"v4.1.1","prerelease":false}' > "$FIX/Gentleman-Programming_gentle-ai_releases_tags_v4.1.1"
  # --- fuentes de las demás herramientas (npm y releases de GitHub) ---
  npm_fx @anthropic-ai/claude-code 2.1.310 2.1.296 2.1.300 2.2.0-beta.1
  npm_fx @mariozechner/pi-coding-agent 0.73.1 0.73.0
  npm_fx opencode-ai 1.19.0 1.18.0
  npm_fx playwright 1.65.0 1.64.0
  npm_fx @playwright/cli 0.1.22 0.1.21
  npm_fx @playwright/mcp 0.0.83 0.0.82
  gh_fx astral-sh/uv 0.13.0 0.12.9
  gh_fx jdx/mise v2026.10.9 v2026.10.8
  gh_fx tailscale/tailscale v1.104.1 v1.104.0 '!v1.105.0-rc1'
  gh_fx DopplerHQ/cli 3.78.0 3.77.0
  # "curl" falso: la URL se convierte en el nombre del archivo de fixtures; si no existe, falla como un 404
  cat > "$FIX/fetch.sh" <<EOF
#!/usr/bin/env bash
# npm responde 406 al /latest si el Accept no es JSON simple: el falso lo exige para detectar esa regresión
case "\$1" in */latest) [[ "\${2:-}" == application/json ]] || exit 22 ;; esac
f="$FIX/\$(printf '%s' "\$1" | sed 's#https://api.github.com/repos/##; s#https://registry.npmjs.org/#npm_#; s#[/]#_#g')"
[[ -f "\$f" ]] && cat "\$f" || exit 22
EOF
  chmod +x "$FIX/fetch.sh"
}

