#!/usr/bin/env bash
# =============================================================================
# Pruebas de "setup.sh add-key" y "setup.sh components".
#
#   bash tests/commands.test.sh
#
# Usa un "docker" y un "curl" simulados en un directorio temporal: authorized_keys vive en
# $SB/fake/home/ai/.ssh y nunca se toca un contenedor real ni la red.
# =============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=tests/helpers/asserts.sh
source "$ROOT/tests/helpers/asserts.sh"

KEY_A="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA a@pc"
KEY_B="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB b@pc"
KEY_GH="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCgithub octo@github"

# ------------------------------------------------------------------- sandbox
# docker simulado:
#  - "exec -i C ssh-keygen -l -f -": una huella por clave; falla si alguna línea contiene ROTA
#  - "exec -i C bash -c SCRIPT": corre SCRIPT en local con /home/ -> $F/home/, sin chown/chmod
#  - "image inspect": éxito solo si existe $F/image
#  - el resto tiene éxito sin hacer nada
# curl simulado: https://github.com/octo.keys devuelve KEY_GH; cualquier otro usuario, 404.
mk_sandbox() {
  SB="$(mktemp -d "$TMP/sb.XXXXXX")"
  mkdir -p "$SB/home" "$SB/bin" "$SB/fake/home" "$SB/repo"
  cat > "$SB/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="${FAKE_DOCKER_DIR:?}"
if [[ "${1:-}" == exec ]]; then
  shift; [[ "${1:-}" == -i ]] && shift; shift   # contenedor
  if [[ "${1:-}" == ssh-keygen ]]; then
    in="$(cat)"; grep -q ROTA <<<"$in" && exit 1
    while IFS= read -r k; do [[ -n "$k" ]] && echo "256 SHA256:fake ${k##* } (ED25519)"; done <<<"$in"
    exit 0
  fi
  if [[ "${1:-}" == bash && "${2:-}" == -c ]]; then
    # Ownership and modes belong to the real container (Linux); Git Bash on Windows cannot set them
    script="${3//\/home\//$F/home/}"; script="${script//chown -R/: }"
    script="${script//install -d -m 700/mkdir -p}"; script="${script//chmod 600/: }"
    exec bash -c "$script"
  fi
  exit 0
fi
case "${1:-} ${2:-}" in
  "image inspect") [[ -e "$F/image" ]] ;;
  *) exit 0 ;;
esac
EOF
  cat > "$SB/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    https://github.com/octo.keys) printf '%s\n' "$KEY_GH"; exit 0 ;;
    https://github.com/*) exit 22 ;;
  esac
done
exit 0
EOF
  chmod +x "$SB/bin/docker" "$SB/bin/curl"
  cp -r "$ROOT/setup.sh" "$ROOT/lib" "$ROOT/env.example" "$SB/repo/"
  unset XDG_DATA_HOME
  export HOME="$SB/home" FAKE_DOCKER_DIR="$SB/fake" PATH="$SB/bin:$PATH"
}

load_setup() {
  mk_sandbox
  # shellcheck disable=SC1091
  source "$SB/repo/setup.sh"
  set +eEu; trap - ERR
  AUTH="$SB/fake/home/$WS_USER/.ssh/authorized_keys"
}

# ================================================================ add-key
t_add_key_literal() {
  load_setup
  local out rc; out="$( add_key "$KEY_A" 2>&1 )"; rc=$?
  assert_eq "rc" 0 "$rc"
  assert_eq "authorized_keys" "$KEY_A" "$(cat "$AUTH" 2>/dev/null)"
  assert_has "informa la clave" "$out" "Clave autorizada"
}

t_add_key_from_pub_file_with_crlf() {   # copiada desde Windows: termina en \r\n
  load_setup
  printf '%s\r\n%s\r\n' "$KEY_A" "$KEY_B" > "$SB/id.pub"
  local rc; ( add_key "$SB/id.pub" >/dev/null 2>&1 ); rc=$?
  assert_eq "rc" 0 "$rc"
  assert_eq "dos claves, sin \\r" "$KEY_A"$'\n'"$KEY_B" "$(cat "$AUTH" 2>/dev/null)"
}

t_add_key_from_github() {
  load_setup
  local rc; ( add_key github:octo >/dev/null 2>&1 ); rc=$?
  assert_eq "rc" 0 "$rc"
  assert_eq "clave de GitHub" "$KEY_GH" "$(cat "$AUTH" 2>/dev/null)"
}

t_add_key_github_unknown_user_fails() {
  load_setup
  local out rc; out="$( add_key github:nadie 2>&1 )"; rc=$?
  (( rc != 0 )) && ok || nok "debía fallar"
  assert_has "explica" "$out" "No pude descargar las claves de GitHub de nadie"
  [[ ! -e "$AUTH" ]] && ok || nok "no debía crear authorized_keys"
}

t_add_key_does_not_duplicate() {
  load_setup
  ( add_key "$KEY_A" >/dev/null 2>&1 )
  printf '%s\n%s\n' "$KEY_A" "$KEY_B" > "$SB/two.pub"
  ( add_key "$SB/two.pub" >/dev/null 2>&1 )
  ( add_key "$KEY_B" >/dev/null 2>&1 )
  assert_eq "cada clave una vez" "$KEY_A"$'\n'"$KEY_B" "$(cat "$AUTH" 2>/dev/null)"
}

t_add_key_rejects_private_key() {
  load_setup
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----\n' > "$SB/id_ed25519"
  local out rc; out="$( add_key "$SB/id_ed25519" 2>&1 )"; rc=$?
  (( rc != 0 )) && ok || nok "debía fallar"
  assert_has "explica" "$out" "clave PRIVADA"
  [[ ! -e "$AUTH" ]] && ok || nok "no debía crear authorized_keys"
}

t_add_key_rejects_invalid_key() {   # p. ej. cortada al pegar: ssh-keygen la rechaza
  load_setup
  local out rc; out="$( add_key "ssh-ed25519 ROTA" 2>&1 )"; rc=$?
  (( rc != 0 )) && ok || nok "debía fallar"
  assert_has "explica" "$out" "La clave no es válida"
  [[ ! -e "$AUTH" ]] && ok || nok "no debía crear authorized_keys"
}

t_add_key_missing_file_fails() {
  load_setup
  local out rc; out="$( add_key "$SB/no-existe.pub" 2>&1 )"; rc=$?
  (( rc != 0 )) && ok || nok "debía fallar"
  assert_has "explica" "$out" "No existe el archivo"
}

t_add_key_pasted_from_stdin() {
  load_setup
  local rc; ( add_key >/dev/null 2>&1 <<<"$KEY_B" ); rc=$?
  assert_eq "rc" 0 "$rc"
  assert_eq "clave pegada" "$KEY_B" "$(cat "$AUTH" 2>/dev/null)"
}

# ================================================================ components
t_components_saves_toggles_to_env() {   # 3 = opencode (false -> true), 1 = Claude (true -> false)
  load_setup
  local rc; ( components_cmd >/dev/null 2>&1 <<<$'3 1\n\n' ); rc=$?
  assert_eq "rc" 0 "$rc"
  assert_eq "INSTALL_OPENCODE" "true" "$(env_get INSTALL_OPENCODE)"
  assert_eq "INSTALL_CLAUDE" "false" "$(env_get INSTALL_CLAUDE)"
  assert_eq "INSTALL_PI sin tocar" "true" "$(env_get INSTALL_PI)"
  [[ "$(stat -c %a "$ENV_FILE" 2>/dev/null)" == 600 || "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] && ok || nok ".env debía quedar con permisos 600"
}

t_components_cancel_changes_nothing() {
  load_setup
  printf 'INSTALL_CLAUDE=true\n' > "$ENV_FILE"
  local before; before="$(cat "$ENV_FILE")"
  local out; out="$( components_cmd 2>&1 <<<$'3\nq\n' )"
  assert_has "avisa" "$out" "Sin cambios."
  assert_eq ".env intacto" "$before" "$(cat "$ENV_FILE")"
}

t_components_none_and_invalid_option() {
  load_setup
  local out; out="$( components_cmd 2>&1 <<<$'n\n99 x\n\n' )"
  assert_has "avisa de la opción 99" "$out" "Opción inválida: 99"
  assert_has "avisa de la opción x" "$out" "Opción inválida: x"
  assert_eq "INSTALL_CLAUDE" "false" "$(env_get INSTALL_CLAUDE)"
  assert_eq "INSTALL_PLAYWRIGHT" "false" "$(env_get INSTALL_PLAYWRIGHT)"
}

t_components_offers_rebuild_only_with_an_image() {
  load_setup
  confirm() { echo "$1" >> "$SB/prompts"; return 1; }
  local out; out="$( components_cmd 2>&1 <<<$'3\n\n' )"
  [[ ! -e "$SB/prompts" ]] && ok || nok "sin imagen no debía preguntar por reconstruir"
  : > "$SB/fake/image"
  out="$( components_cmd 2>&1 <<<$'3\n\n' )"
  assert_has "pregunta por reconstruir" "$(cat "$SB/prompts" 2>/dev/null)" "Reconstruir ahora"
  assert_has "explica cómo aplicar" "$out" "./setup.sh update"
}

for t in t_add_key_literal t_add_key_from_pub_file_with_crlf t_add_key_from_github \
         t_add_key_github_unknown_user_fails t_add_key_does_not_duplicate t_add_key_rejects_private_key \
         t_add_key_rejects_invalid_key t_add_key_missing_file_fails t_add_key_pasted_from_stdin \
         t_components_saves_toggles_to_env t_components_cancel_changes_nothing \
         t_components_none_and_invalid_option t_components_offers_rebuild_only_with_an_image; do
  run "$t"
done

p="$(wc -l < "$PASSES")"; f="$(wc -l < "$FAILS")"
echo; echo "Resultado: $p ok, $f fallos"
(( f == 0 ))
