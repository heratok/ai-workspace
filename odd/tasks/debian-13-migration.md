# Feature: debian-13-migration (base image debian:12-slim -> debian:13-slim)

## Objective
Move the image to Debian 13 (trixie) deliberately, with a full build and verification, before
Debian 12 reaches late LTS (regular security support ended around June 2026; LTS continues).

## Problem
Dependabot opened PR #3 (`debian:12-slim` -> `debian:13-slim`). Its CI build FAILED in 36 s:
the Dockerfile adds PostgreSQL's repo as `bookworm-pgdg`; on trixie `libpq5 18.6-1.pgdg12+2`
depends on `libldap-2.5-0`, which does not exist there ("held broken packages").
PR #3 was closed and Dependabot now ignores major `debian` bumps (see .github/dependabot.yml).

## Known work (measured: the first item only; the rest are UNVERIFIED risks to check)
- [measured] PGDG repo: `bookworm-pgdg` -> `trixie-pgdg` (Dockerfile ~line 76).
- Microsoft repo `packages.microsoft.com/debian/12/prod` (mssql-tools18): check whether
  `debian/13` is published before touching INSTALL_MSSQL_TOOLS.
- config/packages.apt: names may differ on trixie (t64 transition, renamed packages).
- `playwright install --with-deps chromium`: check Debian 13 support for the pinned Playwright.
- fzf/zshrc comment "(Debian 12)", other tools that assume 12.
- Text that says "Debian 12": config/AGENTS.md, landing (Diagrama.astro, index.astro),
  lib/backup.sh fallback image `debian:12-slim` (2 places), config/zshrc.
- Re-measure: Hadolint, Trivy image baseline (was 0 CRITICAL fixable, ~40 HIGH in Go binaries),
  cap_drop set (sshd on trixie may need other capabilities: re-run the leave-one-out).

## Approach
One branch, one PR. Full image build (CI does it) plus the CI tool checks; do NOT build big images
on the shared test VPS without asking (disk incident 2026-10-13: 73% -> 98%).
Strict TDD: add/adjust static tests first (e.g. no remaining `bookworm`, repos match the base).

## Tasks
- [ ] B1 Tests (RED): no `bookworm`/`debian/12`/`Debian 12` left outside this doc; repos match base
- [ ] B2 Dockerfile + packages.apt on trixie; fix what the build reports
- [ ] B3 Update texts (AGENTS.md, landing, backup.sh fallback, zshrc)
- [ ] B4 Re-measure security baseline and capability set; update .trivyignore/.hadolint.yaml if needed
- [ ] B5 Remove the dependabot `ignore` for debian major (or bump the pin consciously)

## Progress / Next
Not started. Trigger: when planned (suggested within a few months).
