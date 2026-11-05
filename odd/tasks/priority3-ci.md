# Feature: priority3-ci (CI and tests block of the priority 3 backlog)
Branch: ci/priority3-ci. Delivery: ask-on-risk. Runner: `bash tests/<name>.test.sh` (Git Bash locally,
ubuntu-24.04 in CI). No Docker locally: CI-only behavior (cache, landing job) is proven on the PR run.

## Specs
- S1 ShellCheck lints `lib/*.sh` (backlog: "ShellCheck does not lint `lib/*.sh`"); real warnings fixed.
  Cross-module globals (colors, instance vars) are shared with `setup.sh`, so SC2034/SC2154 are excluded
  only for the `lib/` run. A test fails if a `lib/*.sh` module is not in the ShellCheck list.
- S2 `concurrency` (`group: ci-${{ github.ref }}`, `cancel-in-progress: true`) and `timeout-minutes` on
  every step of every job.
- S3 Build job uses layer cache: `docker/build-push-action` pinned by SHA, `cache-from/cache-to: type=gha`,
  `--no-cache` only on the Monday schedule run; the image stays loadable as `ai-workspace:ci`.
- S4 A `landing` job runs `npm ci`, `npm run build`, `npm audit --audit-level=high`; Dependabot has an
  `npm` entry for `/landing` with groups.
- S5 Tool images in CI (`koalaman/shellcheck`, `hadolint`, `aquasec/trivy`) pinned by digest (tag kept as
  a comment/prefix for readability).
- S6 Asserts (`ok/nok/assert_*/run`) moved to `tests/helpers/asserts.sh`; `tests/run-all.sh` runs every
  `tests/*.test.sh` and fails if any fails. Every test file keeps its own `run: bash tests/<name>` step.
- S7 `tests/fetch-script.test.sh` passes (or skips explicitly) on Windows Git Bash.
- S8 Behavior tests for `add_key` (literal key, `RUTA.pub`, `github:user`, no duplicates),
  `components_cmd`, and the `BORRAR` confirmation of `uninstall --all` without `--yes`.

## Tasks
| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T1 | S1 | inline | done (unit 1) | RED 11 fails (one per lib module); GREEN security 92/0, shellcheck lib rc=0 |
| T2 | S2-S3 | inline | done (unit 1) | RED 11 fails; GREEN; YAML parsed, every step has timeout-minutes; cache proven only on the PR run |
| T3 | S4 | inline | done (unit 1) | RED 6 fails; local `npm audit` found zod <4.6.6 HIGH, fixed in lockfile; npm ci+build+audit rc=0 |
| T4 | S5 | inline | done (unit 1) | RED 3 fails; digests resolved from registry-1.docker.io for the same tags |
| T5 | S6 | inline | done (unit 2) | RED 2 fails (no helper, no run-all); 16 files migrated; run-all tested with a fake suite |
| T6 | S7 | inline | done (unit 1) | RED 4 fails on Git Bash (curl 37); GREEN 9/0 with cygpath -m |
| T7 | S8 | inline | done (unit 2) | characterization (behavior existed, no RED); mutation on server: BORRAR→case-insensitive and dedupe removal both caught |

Route evidence: one parent session, sequential small units; no Writer trigger reason.

## Log
- L1 (2026-11-05, user): "si dale, limpia y arranca con CI" — after listing the priority 3 backlog
  (`odd/tasks/priority3-backlog.md`, section "CI and tests").
- L2 (2026-11-05) Unit 1 = T1-T4+T6. Real finding: the new landing job would fail on day one (zod HIGH);
  fixed with `npm audit fix` (lockfile only). No Docker locally: buildx cache and landing job proven on the PR.
- L3 (2026-11-05, user): "si vas  a probar prueba en el server no en windows" — tests now run on the test
  server (opc@100.112.41.81, bash 4.4, OL8) in a mktemp scratch dir, removed afterwards.
- L4 Unit 2 = T5+T7. Server run-all: 17 test files, 0 failures (entrypoint against a real container).
  New tests/commands.test.sh (add-key 9 cases, components 4). Next: PR; CI-only proofs (gha cache, landing job).
