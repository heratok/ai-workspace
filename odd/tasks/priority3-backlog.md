# Backlog: priority3 (CI, supply chain, maintainability)
Not started. Source: full repo review of 2026-11-05 (three reviewers + verifiers of priority 1/2).
Each item names its evidence; re-check it before starting, the code may have moved.

## CI and tests
- ShellCheck does not lint `lib/*.sh`: the file list in `.github/workflows/ci.yml` (ShellCheck step)
  omits it, and `-x` only follows sourced files, it does not report on them. Add `lib/*.sh`.
- No layer cache in the `build` job (full rebuild on every push/PR, 60 min limit): use
  `docker/build-push-action` pinned by SHA with `cache-from/cache-to: type=gha`; keep `--no-cache`
  only for the Monday schedule run.
- No `concurrency` block (`group: ci-${{ github.ref }}`, `cancel-in-progress: true`) and no per-step
  `timeout-minutes` (a hung suite burns the whole job).
- Landing is never built in CI and Dependabot has no `npm` entry for `/landing` (the CVE bump of
  2026-11-05 was found by Trivy, not Dependabot): add a `landing` job (`npm ci`, `npm run build`,
  `npm audit --audit-level=high`) and a Dependabot npm entry with groups.
- Tool images in CI (`koalaman/shellcheck`, `hadolint`, `aquasec/trivy`) pinned by tag, not digest.
- Asserts (`ok/nok/assert_*/run`) copied into every `tests/*.test.sh`: move to
  `tests/helpers/asserts.sh`; add `tests/run-all.sh`.
- `tests/fetch-script.test.sh` fails on Windows (curl.exe does not understand MSYS `/tmp` paths):
  skip like `tests/guide.test.sh` does, or `cygpath -m`.
- Behavior tests missing for `add_key` (literal key, `RUTA.pub`, `github:user`, no duplicates),
  `components_cmd`, and the `BORRAR` confirmation of `uninstall --all` without `--yes`.

## Image and supply chain (Dockerfile, compose)
- Every `ARG` is declared before the first `RUN` (Dockerfile ~13-56): changing one version rebuilds
  apt, Node and Chromium. Declare each `ARG` right before the `RUN` that uses it; move the agents
  (Claude, Pi, opencode) after Playwright/Chromium.
- `mise` installed with `curl https://mise.run | sh` without checksum (Dockerfile ~131).
- `NODE_VERSION` empty by default (latest of the major: not reproducible); `SHASUMS256.txt` comes from
  the same origin as the tarball (verify `.sig` or pin the SHA256 via `scripts/update-pins.sh`).
- Base images not pinned by digest; `mcr.microsoft.com/mssql/server:2022-latest` floats.
- apt repo keys (gh, PGDG, Microsoft) downloaded without fingerprint check.
- Gentle AI and Doppler checksums validated against the same release (pin SHA256 like Herdr).
- Tailscale sidecar not hardened (`no-new-privileges`, `mem_limit`, `pids_limit`, `cap_drop: ALL` +
  `NET_ADMIN`/`NET_RAW`); `TS_AUTHKEY` stays visible in `docker inspect` until the container is
  recreated; docs recommend a reusable key (prefer one-off, short-lived, tagged).
- `authorized_keys` lives in `~/.ssh` owned by `ai`: an agent can add its own key. Move to a
  root-owned `AuthorizedKeysFile /etc/ssh/authorized_keys/%u` (needs a migration and `add_key`).
- Workspace receives the `sa` password of SQL Server; `mssql` has no healthcheck. Local PG trusts
  every host connection (network namespace shared with the sidecar).

## Shell maintainability (aiws, lib/)
- Duplication between `aiws` and `lib/`: logging/colors, `inst_env` vs `env_get` (and the copy in
  `scripts/update-pins.sh` that does not strip `\r`), registry path, host mem/cpu, instance names,
  instance discovery and memory sums. Extract a side-effect-free `lib/core.sh` sourced by `aiws`.
- `aiws restore <alias> <archivo>` is impossible although the help offers it (`aiws` destructive
  argument check).
- `confirm` lives in `lib/backup.sh` and `has_tty` in `lib/maintenance.sh` but are used elsewhere:
  move to `lib/common.sh`. Dead code `mems`/`cpuv` in `cmd_ls`.
- `upgrade()` writes new `.env` keys with `echo >>` (breaks a file without trailing newline; reuse
  `env_set`). `ts_logged_in_before` pulls `tailscale/tailscale:stable` instead of the pinned tag.
- Registry (`registry_add/remove`) without its own lock; `uninstall` (without `--all`) removes the
  instance from `aiws ls` although it keeps the data.
- Temp files left on error (`add_key`, `env_set`, `inst_run`); unquoted word splitting of user input
  (`components.sh`, `aiws`, `migrations/002`); `"${auth[@]}"` unguarded in `update-pins.sh`;
  `rewrite_file` in `update-pins.sh` not atomic. Migrations are recorded per folder, not per server.

## Advisories left by the priority 1/2 verifiers
- Failure of the safety backup inside `restore` aborts with the workspace stopped; backup names have
  1 s resolution (same-second backup + restore collide); `~/.ssh` as a regular file makes the
  container restart-loop; a `.partial` survives a Ctrl+C.
- `op_lock` creates `logs/` (fails if a previous `sudo` run left it root-owned); with
  `install --alias X` the lock message names the previous instance name.
- A signal before the entrypoint installs its trap, or sshd dying alone, still kills devdb.

## Docs and landing
- `docs/desarrollo.md` module table omits `lib/tools.sh` (add a docs test against `MODULES`);
  `purge` and `self-update` aliases undocumented; Dependabot coverage described incompletely.
- Landing: no meta description / Open Graph / canonical / favicon (`layouts/Base.astro`); tabs do not
  follow the ARIA tabs pattern (`pages/index.astro`, `components/Diagrama.astro`); Google Fonts
  render-blocking without `preconnect` to `fonts.gstatic.com`.
- Stale tasks: `odd/tasks/multi-instance.md` T6 and `odd/tasks/tools-updates.md` T5 look done;
  `odd/tasks/debian-13-migration.md` B1-B5 pending.

## Operational (test server, not code)
- The real instance `ai-workspace` on the test VPS is down since 2026-10-20: its Tailscale sidecar
  restart-loops waiting for device approval in the Tailscale admin console.
