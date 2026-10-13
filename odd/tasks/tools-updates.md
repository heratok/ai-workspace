# Feature: tools-updates (`./setup.sh tools`: find, choose and apply tool updates; pin Doppler; agy stays latest)

## Objective
After pinning every tool, `./setup.sh update` rebuilds the SAME versions (it used to pull the latest
of everything). Give the server admin that control back: opening the main script tells you which
tools have newer versions, and `./setup.sh tools` lets you pick and apply them.

## Why agy and Doppler were not pinned before (investigated 2026-10-13)
- agy (DECIDED: not pinned, always latest): the installer has no version option; the bucket `antigravity-public` does NOT allow anonymous
  listing (401), and every build URL embeds an unpredictable build id
  (`.../1.3.4-5524158944247808/linux-x64/cli_linux_x64.tar.gz`). Only the latest is discoverable
  (`<base>/manifests/linux_{amd64,arm64}.json` -> version, url, sha512). It CAN be pinned by
  url+sha512, but not listed/chosen among old versions ("latest only"). Archive = one file `antigravity`.
- Doppler: it was installed from its apt repo (unpinned). Doppler publishes GitHub releases
  (`DopplerHQ/cli`, tag `3.77.0`) with `doppler_<ver>_linux_{amd64,arm64}.tar.gz` (binary `doppler`
  at the archive root) and `checksums.txt`: pin like Gentle AI.

## Design (final, after the user's decision that agy always installs the latest)
- Dockerfile: new ARG `DOPPLER_VERSION`; Doppler from the release tarball verified with checksums.txt (apt repo
  block removed). agy is NOT pinned: it keeps the official installer + `config/fetch-script.sh` (always latest).
  New image LABEL `org.ai-workspace.versions="id=ver,..."` so `tools` can show what is REALLY in the image.
- `env.example`: the pins are COMMENTED (`# KEY=value`, documentation only). `.env` is created by copying
  env.example and `upgrade` appends missing keys, so active pins would freeze every server. Only `tools`
  writes a real value, when the user picks one. Migration 003 cleans `.env` files that already copied them.
- `scripts/update-pins.sh` v2: registry of 12 tools (npm: claude-code pi opencode playwright playwright-cli
  playwright-mcp; GitHub releases: uv mise tailscale herdr gentle-ai doppler). `--target repo|env`,
  `set <tool> latest`, `check [--tsv]` (pinned vs latest, parallel fetches), `reset` (env). `env` writes
  overrides to the server's `.env` only (never tracked files) and respects INSTALL_* flags. Uses only bash,
  curl, grep, sed and awk: the server guarantees Docker, git and curl, not perl/jq.
- `lib/tools.sh` + `./setup.sh tools [--yes] [--reset]`: table (tool, in image, pinned, latest, origin, state),
  pick all / numbers / none, writes .env, offers `update`. `--reset` drops the overrides. Menu entry 11.
  Menu notice "N herramientas con versión nueva": cache `logs/.tools-check` 12 h, one attempt per 15 min,
  5 s timeout, never overwrites a good cache with an all-error result, silent on any failure.
  `aiws tools ALIAS` delegates.
- Known trade-offs: a `.env` override outlives repo bumps (table marks origin `.env`; `--reset`);
  "latest" npm may include breaking changes (the user chooses, nothing is automatic); `agy` is not covered.

## TDD
Mode: strict. Runners: pins.test.sh, update-pins.test.sh (extended), new tools.test.sh, modules.test.sh,
aiws.test.sh (EXPECTED_CMDS), docs.test.sh.

## Tasks
- [x] T1 Tests (RED) + Dockerfile/compose/env.example: Doppler pinned (release + checksums.txt, apt repo removed), image LABEL with versions. DECISION (user, mid-task): agy is NOT pinned, it always installs the latest (installer + fetch-script stay); the agy pin work was reverted.
- [x] T2 Tests (RED) + update-pins.sh v2 (registry, npm/gh/agy sources, check, env target, reset)
- [x] T3 Tests (RED) + lib/tools.sh, setup.sh wiring (command, menu entry, notice), aiws, modules test
- [x] T4 Verify against REAL APIs (read-only) and the full flow in a sandbox with a fake docker
- [ ] T5 Docs (operation, configuration, tools), CI wiring, PR; CI builds the real image

## Verification
All suites; ShellCheck `-x -S warning` (pinned image, run on the VPS); real `check` against the live
APIs; CI build verifies doppler/agy download + checksum + `--version`.

## Hallazgos durante la implementación (todos corregidos, cada uno con su test)
1. `.env` = copia de `env.example` y `upgrade` le agrega las claves que falten: con las versiones ACTIVAS en
   `env.example`, cada servidor las habría congelado para siempre (el repo no podría actualizarlas) y la tabla de
   `tools` mostraría origen `.env` para todo. Ahora van COMENTADAS (`# CLAVE=valor`); solo `tools` escribe un valor
   real al elegir uno. Migración `003-versiones-fijadas-fuera-del-env.sh` limpia los `.env` que ya las copiaron
   (quita las iguales al valor del repo, conserva y avisa de las distintas; Herdr como grupo).
2. El `/latest` de npm responde 406 si el `Accept` no es JSON simple (el `fetch` falso de los tests ignoraba cabeceras).
3. `trap ... RETURN` con variable local ya fuera de alcance (`set -u`): error real en `check`.
4. Sin red, `check` devuelve todas las filas en error: ya no pisa una caché buena del aviso del menú.
5. Un `$(...)` con procesos hijos vivos bloquea más que el `timeout`: el aviso escribe a un archivo.
6. **El servidor no tiene perl con JSON::PP** (Oracle Linux 8: perl existe, JSON::PP no; Debian: perl-base tampoco).
   `update-pins.sh`, `lib/tools.sh` y la migración ya no usan perl: JSON con grep+awk, ediciones con awk.
7. La API real de GitHub devuelve JSON con espacios (`"tag_name": "v1"`); los fixtures sintéticos eran compactos.
   Ahora hay fixtures REALES capturados (`tests/fixtures/github-*.json`) y el parser tolera espacios.

## Verificación
- Windows: update-pins, tools, pins, modules, security, docs, hardening, aiws, restore.
- Linux real (Oracle Linux 8, gawk, sin JSON::PP): `check` real de las 12 herramientas en 1,4 s; suites.
- Debian 12 (mawk, sin JSON::PP) en contenedor `debian:12-slim`: update-pins y tools.
- ShellCheck v0.11.0 `-x -S warning` exit 0 (misma imagen del CI, en la VPS; imagen retirada después).
- Mutación: la migración rota hace fallar los tests.

## Progress / Next
Todo implementado salvo lo marcado. Pendiente: PR + CI (construye la imagen real: Doppler por release + etiqueta).
No verificado aún: build real con Doppler instalado desde su release (lo hace el CI) y `./setup.sh tools --yes` con
reconstrucción real. agy: decisión del usuario, no se fija.
