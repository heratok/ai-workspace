# Agent guide for the isolated workspace

## Objective
Ship a short guide (AGENTS.md) that every coding agent inside the workspace finds automatically, so agents stop probing/guessing how to install things (no root, no sudo, pip blocked, devdb for DB servers...) and save tokens and time.

## Problem / Why
Agents run as non-root user `ai`. `sudo`/`apt install` fail, `pip install` fails (PIP_REQUIRE_VIRTUALENV=true), the ai_home volume hides anything the image puts in /home/ai. Only the 591-line README documents the right way; agents never read it.

## Scope
- config/AGENTS.md (new, source of truth, Spanish, <= ~60 lines, dense tables)
- Dockerfile: copy to /etc/ai-workspace/AGENTS.md; append a build-time "Componentes incluidos" section from the INSTALL_* ARGs
- entrypoint.sh: seed /workspace/AGENTS.md (symlink to /etc/ai-workspace/AGENTS.md) and /workspace/CLAUDE.md (`@/etc/ai-workspace/AGENTS.md`) only if absent; never touch ~/.claude, ~/.config/opencode, etc.
- config/ws-doctor: `--guide` prints the guide; normal run warns if guide/seeds are missing
- tests/guide.test.sh (new) + CI wiring (.github/workflows/ci.yml): guide exists in image, every command cited exists (`command -v`); entrypoint seeding test
- README: short section pointing to the guide

Out of scope: version pinning (uv/mise/gentle-ai), devdb tests, aiws ls purge bug.

## Constraints
- Artifacts in Spanish (project language), neutral professional tone, no persona slang.
- Never overwrite existing user files in /workspace; seeding is idempotent.
- Every command cited in the guide must exist in the image.
- No push/commit without user instruction (commit allowed locally only if asked).

## TDD
Mode: strict (session config). Runner: `bash tests/guide.test.sh`, `bash tests/instances.test.sh`, `bash tests/aiws.test.sh`, `shellcheck -S error`. RED before implementation.

## Tasks
- [x] T1 RED: tests/guide.test.sh (seeding idempotent, no-overwrite, symlink target, guide commands exist in a fake PATH list) fails
- [x] T2 config/AGENTS.md + Dockerfile copy + build-time components section
- [x] T3 entrypoint.sh seeding (GREEN for T1)
- [x] T4 ws-doctor --guide + missing-guide warning
- [x] T5 CI wiring (tests step + image check that guide exists and commands resolve)
- [x] T6 README pointer; run all tests + shellcheck

## Acceptance criteria
- Fresh container: /workspace/AGENTS.md and /workspace/CLAUDE.md exist; second boot changes nothing; a pre-existing file is left untouched.
- `ws-doctor --guide` prints the guide.
- All tests and `shellcheck -S error` pass; CI green.

## Progress / Evidence
- T1 RED observado: `bash tests/guide.test.sh` sin implementación -> "19 aserciones correctas, 16 fallidas", rc=1 (faltaban config/AGENTS.md, config/seed-guide.sh y `--guide` en ws-doctor).
- T2-T4 GREEN: `bash tests/guide.test.sh` en debian:12-slim (Linux, con symlinks) -> "44 aserciones correctas, 0 fallidas, 0 omitidas", rc=0. En Git Bash/Windows los symlinks no están permitidos: 7 pruebas de siembra se omiten (28 correctas, 0 fallidas, rc=0).
- Lógica de siembra extraída a config/seed-guide.sh (copiada a /etc/ai-workspace/seed-guide.sh; entrypoint.sh paso 4b la ejecuta); rutas sobrescribibles con AIWS_GUIDE_SRC, AIWS_WORKSPACE_DIR, AIWS_OWNER.
- Sección de componentes del Dockerfile verificada ejecutando el fragmento RUN con bash -Eeuo pipefail: lista "sí/no" correcta.
- T5: ci.yml con bash -n/shellcheck/tests y paso "Verificar la guía para agentes dentro de la imagen" (corregido: backticks escapados dentro de bash -c; fragmento ejecutado con un shim, resuelve los comandos citados).
- T6: `bash tests/instances.test.sh` (Linux) 321 correctas, 0 fallidas; `bash tests/aiws.test.sh` (Linux) 387 correctas, 0 fallidas. `shellcheck -S error` (koalaman/shellcheck:stable) sobre entrypoint.sh, config/ws-doctor, config/seed-guide.sh, tests/guide.test.sh: sin hallazgos. `bash -n` OK en los 4.
- No ejecutado: `docker build` completo de la imagen (y por tanto el paso de CI dentro de la imagen); README renderizado.

## Next step
Revisar y confirmar con el usuario (sin commit ni push).
