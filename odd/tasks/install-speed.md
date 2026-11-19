# Feature: install-speed (primera instalación más rápida)
Branch: fix/install-speed · Runner: bash tests/run-all.sh (Linux) · Entrega: un PR.

## Specs
- S1 El `chmod +x config/*.sh` de `normalize_line_endings` no debe hacer que `image_source` elija build (en Linux, `core.fileMode=true`).
- S2 En `install`, la descarga de GHCR corre mientras se hace el login de Tailscale.
- S3 En `install`, si la imagen no está publicada, se construye en el servidor en vez de abortar. `update`/`upgrade`/`rollback` no cambian.
- S4 En `install`, la auth key se borra recreando solo el sidecar antes de crear el workspace; si el workspace ya existe, se recrean ambos (comportamiento previo).
- S5 El HEALTHCHECK del workspace sondea rápido al arrancar (`--start-interval`).

## Tasks
- [x] T1 S1-S5 inline · RED en Linux (8 fallos) -> GREEN (image.test.sh 62/0); suite completa verde salvo docs.test.sh (15 fallos de anclas que ya ocurren en main en ese entorno; en Windows 66/0)

## Log
- L1 "si dale y arregla todo eso" (2026-11-19), sobre el análisis de la instalación.
- L2 Bug S1 reproducido en Linux sobre main: config/env.sh, fetch-script.sh y seed-guide.sh quedaban " M" y forzaban el build. Además se guardan con 100755 en git.
- L3 Pendiente: reducir la imagen (un solo Chromium de Playwright) tras medir el build de Debian 13.
