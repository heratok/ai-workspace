# Desarrollo y migración

[← Volver al README](../README.md)

## Verificación automática (CI)

Cada push a `main`, cada pull request y la ejecución manual pasan por `.github/workflows/ci.yml`, que corre en `ubuntu-24.04`:

- **lint:** sintaxis de todos los scripts, ShellCheck (solo errores), las pruebas de `tests/` (multi-instancia, `aiws`, guía para agentes, descarga de instaladores, restauración de respaldos, versiones fijadas, endurecimiento del compose, configuración de seguridad y documentación: `bash tests/<nombre>.test.sh`) y la validación del compose con los nombres de la instancia principal y de una con alias.
- **security:** Hadolint sobre el `Dockerfile` (falla solo con errores) y Trivy sobre el repo (secretos, dependencias y configuración; HIGH/CRITICAL con corrección), ambos como contenedores con versión fija (súbela a mano: Dependabot no ve los `run:`). Las excepciones aceptadas están en `.hadolint.yaml` y `.trivyignore`, cada una con su motivo. El workflow corre además **cada lunes** (`schedule`) para detectar CVE nuevas sin cambios de código.
- **build:** construye la imagen completa y verifica que estén las herramientas (`claude`, `pi`, `playwright`, `herdr`, `doppler`, `gentle-ai`, `agy`, etc.). Después escanea la imagen con Trivy: **bloquea** si hay CVE CRITICAL con corrección (baseline medido: 0) e informa los HIGH sin bloquear (~40, en binarios Go de terceros como `gh` y `gentle-ai`).

`actions/checkout` está fijado por SHA (v7.0.1) y Dependabot revisa cada semana las acciones de `.github/workflows/` (`.github/dependabot.yml`). Si el CI sale en rojo, no hagas `upgrade` hasta que se corrija.

## Migración desde v1

1. En la carpeta v1, ejecuta `docker compose down`. Los volúmenes `ai_home` y `ai_workspace` no se tocan.
2. Revisa el home: si tienes Node o herramientas instaladas a mano (`~/.nvm`, `~/.local/bin/node`), quítalas para que no tapen las de la imagen.
3. Pasa a `config/extra-root.sh` las herramientas que instalabas a mano, apuntando a `/usr/local/bin`.
4. Ejecuta `./setup.sh install`.
5. Actualiza tus clientes: `ssh ai@ai-workspace` en el puerto 22. El puerto 2222 y la IP fija anterior ya no se usan.
