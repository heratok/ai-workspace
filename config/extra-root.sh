#!/usr/bin/env bash
# Hook de BUILD (corre como root dentro de la imagen).
# Aquí van herramientas extra para TODO el equipo (Herdr ya viene: INSTALL_HERDR).
# Regla: instalar SIEMPRE fuera de /home (p. ej. /usr/local/bin u /opt),
# porque el volumen ai_home oculta todo lo que la imagen ponga en /home/ai.
set -Eeuo pipefail

# Ejemplo binario descargado (ajusta URL/versión real):
# HERDR_VERSION="x.y.z"
# curl -fsSL "https://github.com/<org>/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-$(uname -m).tar.gz" \
#   | tar -xz -C /usr/local/bin herdr
# chmod 755 /usr/local/bin/herdr

# Ejemplo instalador tipo "curl | sh" que acepta directorio destino:
# curl -fsSL https://example.com/install.sh | INSTALL_DIR=/usr/local/bin sh

echo "[extra-root] sin herramientas extra configuradas"
