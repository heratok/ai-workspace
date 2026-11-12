#!/usr/bin/env bash
# =============================================================================
# Pruebas de lib/image.sh: descargar la imagen publicada en GHCR o construirla en el servidor.
#
#   bash tests/image.test.sh
#
# Usa un "docker" simulado (registra cada llamada; las imágenes "publicadas" se listan en un archivo)
# y un repo git desechable con el contexto de build; no toca Docker, red ni el repo real.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

REPO_IMG=ghcr.io/heratok/ai-workspace

# ------------------------------------------------------------------- sandbox
# docker simulado:
#  - todas las llamadas quedan en $F/calls
#  - "manifest inspect" y "pull" solo tienen éxito para las referencias de $F/published
#  - "image ls" lista $F/local; "image rm" la quita de ahí
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake"
  : > "$SB/fake/calls"; : > "$SB/fake/published"; : > "$SB/fake/local"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
echo "$*" >> "$F/calls"
case "${1:-} ${2:-}" in
  "manifest inspect") grep -qxF "$3" "$F/published" ;;
  "pull "*)           grep -qxF "$2" "$F/published" || { echo "manifest unknown" >&2; exit 1; } ;;
  "image ls")         cat "$F/local" ;;
  "image rm")         grep -vxF "$3" "$F/local" > "$F/l.tmp"; mv "$F/l.tmp" "$F/local" ;;
  *)                  exit 0 ;;
esac
EOF
  chmod +x "$SB/bin/docker"
  R="$SB/repo"; mkdir -p "$R"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/scripts" "$ROOT/env.example" "$ROOT/docker-compose.yml" \
        "$ROOT/Dockerfile" "$ROOT/.dockerignore" "$ROOT/entrypoint.sh" "$ROOT/config" "$R/"
  git -C "$R" init -q -b main
  git -C "$R" config user.name t; git -C "$R" config user.email t@t; git -C "$R" config core.autocrlf false
  printf 'logs/\nbackups/\n.env\n' > "$R/.gitignore"
  git -C "$R" add -A; git -C "$R" commit -qm v1
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
}

load_setup() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$R/setup.sh"
  set +eEu; trap - ERR
  confirm() { return 0; }
  host_arch() { echo x86_64; }
  cp "$R/env.example" "$ENV_FILE"
  TAG="$(bash "$R/scripts/image-tag.sh")"
}
publish() { echo "$REPO_IMG:$1" >> "$SB/fake/published"; }
calls() { cat "$SB/fake/calls"; }
commit_v2() {   # v2 con un cambio en el contexto de build (otra etiqueta)
  echo "# v2" >> "$R/config/zshrc"; git -C "$R" commit -qam v2
  V2="$(git -C "$R" rev-parse HEAD)"; TAG2="$(bash "$R/scripts/image-tag.sh")"
}

# ================================================================ image_source
t_defaults_use_ghcr() {   # S2: el .env recién copiado de env.example es la configuración por defecto
  load_setup
  assert_eq "origen" ghcr "$(image_source)"
}

t_explicit_defaults_and_quotes_still_use_ghcr() {   # S2: valores iguales al defecto (con o sin comillas) no cuentan como propios
  load_setup
  env_set INSTALL_CLAUDE true; env_set PG_EXTENSIONS '"pgvector"'; env_set NODE_VERSION ""; env_set CLAUDE_CODE_VERSION "'2.1.296'"
  assert_eq "origen" ghcr "$(image_source)"
}

t_custom_build_args_build_locally() {   # S3
  local kv out
  for kv in INSTALL_OPENCODE=true USER_UID=1001 USER_GID=1001 CLAUDE_CODE_VERSION=9.9.9 NPM_EXTRA_PACKAGES=cowsay INSTALL_MSSQL_TOOLS=true; do
    load_setup
    env_set "${kv%%=*}" "${kv#*=}"
    out="$(image_source)"
    assert_has "$kv" "$out" "build"
    assert_has "$kv nombra la variable" "$out" "${kv%%=*}"
  done
}

t_non_amd64_builds_locally() {   # S3: GHCR solo publica amd64
  load_setup
  host_arch() { echo aarch64; }
  assert_has "arm" "$(image_source)" "build"
}

t_source_build_forces_local_build() {   # S3
  load_setup
  env_set AIWS_IMAGE_SOURCE build
  assert_has "forzado" "$(image_source)" "build"
}

t_invalid_source_fails() {
  load_setup
  env_set AIWS_IMAGE_SOURCE ghcrr
  assert_fail "valor inválido" image_source
}

t_local_edits_in_the_build_context_build_locally() {   # S8
  load_setup
  echo "# mío" >> "$R/config/zshrc"
  assert_has "config editado" "$(image_source)" "build"
}

t_local_edits_outside_the_context_keep_ghcr() {   # S8: solo cuenta lo que entra en la imagen
  load_setup
  echo "notas" >> "$R/docker-compose.yml"
  assert_eq "compose editado" ghcr "$(image_source)"
}

t_folder_without_git_builds_locally() {   # S8
  load_setup
  rm -rf "$R/.git"
  assert_has "sin git" "$(image_source)" "build"
}

# ================================================================ build_and_up
stub_up() { ts_wait_login() { :; }; wait_healthy() { :; }; wait_services() { :; }; }

t_build_and_up_pulls_and_tags_the_published_image() {   # S2
  load_setup; stub_up; publish "$TAG"
  ( build_and_up --no-cache ) >/dev/null 2>&1
  assert_has "descarga" "$(calls)" "pull $REPO_IMG:$TAG"
  assert_has "etiqueta local" "$(calls)" "tag $REPO_IMG:$TAG $IMAGE"
  assert_lacks "no construye" "$(calls)" " build"
  assert_has "levanta" "$(calls)" "up -d --remove-orphans"
}

t_build_and_up_fails_without_touching_the_container_if_not_published() {   # S4
  load_setup; stub_up
  local rc=0 out
  out="$( ( build_and_up ) 2>&1 )" || rc=$?
  [[ $rc -ne 0 ]] && ok || nok "debía fallar"
  assert_lacks "no recrea el contenedor" "$(calls)" "up -d"
  assert_lacks "no construye" "$(calls)" " build"
  assert_has "explica la salida" "$out" "AIWS_IMAGE_SOURCE=build"
}

t_build_and_up_still_builds_with_custom_config() {   # S3, comportamiento previo
  load_setup; stub_up
  env_set INSTALL_OPENCODE true
  ( build_and_up --no-cache ) >/dev/null 2>&1
  assert_has "construye" "$(calls)" "build --pull --no-cache"
  assert_lacks "no descarga" "$(calls)" "pull $REPO_IMG"
}

# ================================================================ upgrade y rollback
mk_origin() {   # origin con v2 publicado o no; el servidor sigue en v1
  git clone -q --bare "$R" "$SB/origin.git"
  git -C "$R" remote add origin "$SB/origin.git"; git -C "$R" fetch -q origin
  git -C "$R" branch -q --set-upstream-to=origin/main main
  V1="$(git -C "$R" rev-parse HEAD)"
  local w="$SB/work"; git clone -q "$SB/origin.git" "$w"
  git -C "$w" config user.name t; git -C "$w" config user.email t@t; git -C "$w" config core.autocrlf false
  echo "# v2" >> "$w/config/zshrc"; git -C "$w" commit -qam v2; git -C "$w" push -q origin main
  TAG2="$(bash "$w/scripts/image-tag.sh")"
  REPO_BRANCH=main
  run_update() { echo "UPDATE $*" >> "$SB/updates"; }
}

t_upgrade_aborts_before_touching_files_if_not_published() {   # S4
  load_setup; mk_origin
  local out; out="$( ( upgrade --yes ) 2>&1 )"
  assert_eq "sigue en v1" "$V1" "$(git -C "$R" rev-parse HEAD)"
  assert_eq "no reconstruye" "" "$(cat "$SB/updates" 2>/dev/null)"
  [[ -s "$LOG_DIR/.prev-version" ]] && nok "no debía registrar versión anterior" || ok
  assert_has "avisa" "$out" "$REPO_IMG:$TAG2"
}

t_upgrade_proceeds_when_published() {   # S2
  load_setup; mk_origin; publish "$TAG2"
  ( upgrade --yes ) >/dev/null 2>&1
  assert_eq "en v2" "v2" "$(git -C "$R" log -1 --format=%s)"
  assert_eq "reconstruye" "UPDATE " "$(cat "$SB/updates" 2>/dev/null)"
}

t_upgrade_with_custom_config_does_not_need_ghcr() {   # S3
  load_setup; mk_origin
  env_set INSTALL_OPENCODE true
  ( upgrade --yes ) >/dev/null 2>&1
  assert_eq "en v2" "v2" "$(git -C "$R" log -1 --format=%s)"
}

t_rollback_aborts_if_previous_image_not_published() {   # S4
  load_setup; V1="$(git -C "$R" rev-parse HEAD)"; commit_v2
  run_update() { echo "UPDATE $*" >> "$SB/updates"; }
  mkdir -p "$LOG_DIR"; echo "$V1" > "$LOG_DIR/.prev-version"
  ( rollback --yes ) >/dev/null 2>&1
  assert_eq "sigue en v2" "$V2" "$(git -C "$R" rev-parse HEAD)"
  assert_eq "no reconstruye" "" "$(cat "$SB/updates" 2>/dev/null)"
  publish "$TAG"
  ( rollback --yes ) >/dev/null 2>&1
  assert_eq "vuelve a v1" "$V1" "$(git -C "$R" rev-parse HEAD)"
}

# ================================================================ clean
t_clean_removes_old_ghcr_tags_only() {   # S5
  load_setup
  printf '%s\n' "$REPO_IMG:ctx-000000000000" "$REPO_IMG:$TAG" "$REPO_IMG:ctx-111111111111" > "$SB/fake/local"
  ( clean ) >/dev/null 2>&1
  assert_eq "queda la actual" "$REPO_IMG:$TAG" "$(cat "$SB/fake/local")"
}

t_env_example_documents_image_source() {   # S6: los servidores existentes la reciben en "upgrade"
  grep -qxF "AIWS_IMAGE_SOURCE=auto" "$ROOT/env.example" && ok || nok "env.example debe traer AIWS_IMAGE_SOURCE=auto"
}

for t in t_defaults_use_ghcr t_env_example_documents_image_source t_explicit_defaults_and_quotes_still_use_ghcr t_custom_build_args_build_locally \
         t_non_amd64_builds_locally t_source_build_forces_local_build t_invalid_source_fails \
         t_local_edits_in_the_build_context_build_locally t_local_edits_outside_the_context_keep_ghcr t_folder_without_git_builds_locally \
         t_build_and_up_pulls_and_tags_the_published_image t_build_and_up_fails_without_touching_the_container_if_not_published \
         t_build_and_up_still_builds_with_custom_config t_upgrade_aborts_before_touching_files_if_not_published \
         t_upgrade_proceeds_when_published t_upgrade_with_custom_config_does_not_need_ghcr \
         t_rollback_aborts_if_previous_image_not_published t_clean_removes_old_ghcr_tags_only; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
