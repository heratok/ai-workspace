#!/usr/bin/env bash
# Corre como root (sshd lo requiere). El usuario "ai" nunca obtiene root.
set -Eeuo pipefail

USERNAME="${WORKSPACE_USER:-ai}"
HOME_DIR="/home/${USERNAME}"
KEY_DIR="/etc/ssh/host_keys"
FIX_OWNERSHIP="${FIX_OWNERSHIP:-false}"

log() { echo "[entrypoint] $*"; }

USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"

# 1. Clave de host SSH persistente
install -d -m 700 "$KEY_DIR"
if [[ ! -f "$KEY_DIR/ssh_host_ed25519_key" ]]; then
  log "Generando clave de host SSH persistente..."
  ssh-keygen -q -t ed25519 -f "$KEY_DIR/ssh_host_ed25519_key" -N "" -C "ai-workspace"
fi
chmod 600 "$KEY_DIR/ssh_host_ed25519_key"
chmod 644 "$KEY_DIR/ssh_host_ed25519_key.pub"

# 2. Home y workspace (volúmenes): dueño correcto en la raíz
install -d -o "$USER_UID" -g "$USER_GID" -m 755 "$HOME_DIR" /workspace
if [[ "$FIX_OWNERSHIP" == "true" ]]; then
  log "FIX_OWNERSHIP=true -> chown recursivo de $HOME_DIR y /workspace"
  chown -R "$USER_UID:$USER_GID" "$HOME_DIR" /workspace
elif [[ "$(stat -c %u "$HOME_DIR")" != "$USER_UID" ]]; then
  log "AVISO: $HOME_DIR no pertenece a UID $USER_UID. Usa FIX_OWNERSHIP=true o ajusta USER_UID."
fi

# 3. Sembrar dotfiles sin sobrescribir los existentes del usuario
cp -an /etc/skel-ai/. "$HOME_DIR"/

# 4. Directorios de instalación sin root
# Cada nivel por separado: "install -d" deja los directorios padre como root.
# chown no recursivo: también repara instalaciones previas con padres de root.
for d in .ssh .local .local/bin .local/share .local/state .npm-global .npm-global/bin .cache .config; do
  install -d "$HOME_DIR/$d"
  chown "$USER_UID:$USER_GID" "$HOME_DIR/$d"
done
chmod 700 "$HOME_DIR/.ssh"
if [[ -f "$HOME_DIR/.ssh/authorized_keys" ]]; then
  chown "$USER_UID:$USER_GID" "$HOME_DIR/.ssh/authorized_keys"
  chmod 600 "$HOME_DIR/.ssh/authorized_keys"
else
  log "AVISO: no existe $HOME_DIR/.ssh/authorized_keys; no podrás entrar por SSH."
fi

# 5. Variables de conexión a servicios -> sesiones SSH (ENV de Docker no llega a SSH)
RUNTIME_ENV=/etc/ai-workspace/runtime.env
{
  echo "# Generado por entrypoint.sh en cada arranque. No editar."
  for var in SQLCMDSERVER SQLCMDUSER SQLCMDPASSWORD DOPPLER_TOKEN AIWS_HOSTNAME; do
    if [[ -n "${!var:-}" ]]; then printf 'export %s=%q\n' "$var" "${!var}"; fi
  done
} > "$RUNTIME_ENV"
chown root:"$USER_GID" "$RUNTIME_ENV"
chmod 640 "$RUNTIME_ENV"

# 6. Bases de datos locales con arranque automático (devdb enable ...), como usuario sin root
if compgen -G "$HOME_DIR/.config/devdb/autostart.*" >/dev/null; then
  log "Iniciando bases de datos locales (devdb autostart)"
  runuser -u "$USERNAME" -- env HOME="$HOME_DIR" USER="$USERNAME" /usr/local/bin/devdb autostart || log "AVISO: devdb autostart falló"
fi

# 7. Validar configuración y arrancar
/usr/sbin/sshd -t
log "sshd listo"
exec /usr/sbin/sshd -D -e
