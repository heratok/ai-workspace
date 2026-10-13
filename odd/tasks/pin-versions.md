# Feature: pin-versions (reproducible image builds)

## Objective
Builds of the image must be reproducible: same repo commit => same tool versions, and a version
bump must be an explicit, reviewable change (not a side effect of "latest").

## Problem
Most tools install "latest" at build time: npm CLIs (claude-code, pi, opencode, playwright*), `uv`
(`ghcr.io/astral-sh/uv:latest`), `mise`, `tailscale:stable`, Herdr/Gentle AI installers. CI can pass
today and fail tomorrow with no code change; two servers built on different days differ.

## Design
- Dockerfile gets one ARG per tool (`CLAUDE_CODE_VERSION`, `PI_VERSION`, `OPENCODE_VERSION`,
  `PLAYWRIGHT_VERSION`, `PLAYWRIGHT_CLI_VERSION`, `PLAYWRIGHT_MCP_VERSION`, `UV_VERSION`,
  `MISE_VERSION`, ...). Committed defaults are concrete versions. `latest` is an explicit opt-in.
- npm spec built as `pkg@version`; empty or `latest` => `pkg@latest`.
- docker-compose.yml forwards the ARGs from `.env` (same defaults); env.example documents them.
- Dependabot: add `docker` (FROM / COPY --from) and `docker-compose` (tailscale tag) ecosystems.
- Installer-script tools without a version flag (Herdr, Gentle AI, agy) are documented as the
  remaining floating items; pin only where the installer supports it (verified, not assumed).
- Out of scope: automated bump workflow for npm ARGs (follow-up).

## TDD
Mode: strict. Runner: `bash tests/pins.test.sh` (new, plain bash, no network) added to CI.

## Tasks
- [x] P1 Tests (RED): every npm/uv/mise ARG exists with a concrete default; Dockerfile uses them;
      compose forwards them; env.example documents them; spec-building helper handles empty/latest
- [x] P2 Dockerfile: ARGs + `pkg@version` specs, uv/mise pinned
- [x] P3 docker-compose.yml + env.example forward/document the ARGs
- [x] P4 dependabot docker + docker-compose; CI step for pins test
- [x] P5 Verify: pins test GREEN, `docker compose config`, docker build of the affected layers

## Verification
`bash tests/pins.test.sh`; `docker compose config -q`; `docker build` (Docker available locally).

## Progress / Next
P1-P5 done. pins test 46/46; uv fixed as its own stage (Docker does not expand vars in COPY --from). REAL BUILD verified on the Linux test VPS (isolated buildx builder, Chromium excluded): claude 2.1.296, pi 0.73.1, playwright 1.64.0, cli 0.1.22, mcp 0.0.83, uv 0.13.0, mise 2026.10.8 all match pins. Still floating (installers): herdr 0.9.3, gentle-ai 4.1.1, agy 1.3.4, doppler 3.77.0. Chromium layer not built (disk). Next: commit.
