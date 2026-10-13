# Feature: pin-installers (Herdr + Gentle AI pinned, update-pins script)

## Objective
Remove the last floating, unverified-script installs of Herdr and Gentle AI from the image build,
and give maintainers one tool to choose or auto-bump the pinned versions.

## Problem (measured 2026-10-13)
- `curl https://herdr.dev/install.sh | sh` and `curl .../gentle-ai/main/scripts/install.sh | bash`
  run live scripts (Gentle AI's comes from the `main` branch) and always install the latest.
  Drift is real: Herdr was 0.9.3 in a build and 0.9.4 hours later.
- Neither installer has a `--version`: Gentle AI only has channels (stable/beta/nightly), Herdr
  reads `herdr.dev/latest.json`.
- agy (Antigravity) stays as is: its asset URL embeds a build id (`1.3.4-5524158944247808`) and the
  archive layout is unknown; revisit separately.

## Facts used (read-only checks)
- Herdr assets: `https://github.com/herdrdev/herdr/releases/download/v<ver>/herdr-linux-{x86_64,aarch64}`
  (raw binary). The GitHub API exposes a sha256 `digest` per asset. Releases also include
  `preview-...` tags that must be filtered out (stable = `v<major>.<minor>.<patch>`).
- Gentle AI assets: `gentle-ai_<ver>_linux_{amd64,arm64}.tar.gz` + `checksums.txt` (+ `.minisig`) per
  release; the binary `gentle-ai` sits at the archive root.

## Design
- Dockerfile ARGs: `HERDR_VERSION`, `HERDR_SHA256_AMD64`, `HERDR_SHA256_ARM64`, `GENTLE_AI_VERSION`
  (concrete defaults). Herdr: download the versioned binary and `sha256sum -c` against the pinned digest.
  Gentle AI: download the versioned archive and verify it against that release's `checksums.txt`.
  No installer script is executed. Forwarded by compose, documented in env.example.
- `scripts/update-pins.sh`: `list [tool] [N]` (last N stable versions, default 5), `choose [tool]`
  (list + pick), `set <tool> <version>`, `latest [tool|all]` (no questions: usable from a scheduled job).
  It rewrites Dockerfile, docker-compose.yml and env.example consistently; refuses unknown versions
  and leaves the files untouched on any failure. JSON parsed with perl JSON::PP (no jq needed).
  Tests inject fixtures via `PINS_FETCH` (no network).
- NOT done: a scheduled GitHub workflow that opens bump PRs (unknown whether this repo lets Actions
  open PRs; auto-merge was already disabled). The `latest` command is what such a job would call.
- Gentle AI checksum is same-origin integrity (the minisign signature is not verified).

## TDD
Mode: strict. Runners: `bash tests/pins.test.sh` (extended) and `bash tests/update-pins.test.sh` (new).

## Tasks
- [x] I1 Tests (RED): pins.test.sh extended (new ARGs, no installer scripts, checksum verification)
- [x] I2 Dockerfile + compose + env.example
- [x] I3 Tests (RED) for scripts/update-pins.sh with fixtures
- [x] I4 scripts/update-pins.sh
- [x] I5 CI (shellcheck list + test step), docs, verify download+checksum logic against the real
      releases (read-only), full build is done by CI

## Verification
Both test files; ShellCheck `-x -S warning`; checksum logic checked against the real upstream
digests; CI build runs the tool presence check (herdr, gentle-ai).

## Progress / Next
I1-I5 done. pins 72/72, update-pins 65/65 (mutation-tested), security 37, docs 62. Verified read-only against the REAL GitHub API: list shows the last 5 stable versions per tool with the pinned one marked; set herdr 0.9.3 computes the real digests (18a8dc65.., 4de7aa3e..) in a temp copy; unknown version rejected. ShellCheck v0.11.0 -x -S warning exit 0 (run on the VPS, image removed afterwards). NOT verified: the real download+sha256sum -c inside the image build (CI builds the image; Herdr digest 0.9.4 amd64/arm64 taken from the API and latest.json; Gentle AI tar layout from the installer source: binary at archive root). Scheduled bump PRs still not done (Actions PR permission unknown).
