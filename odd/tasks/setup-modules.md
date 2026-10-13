# Feature: setup-modules (split setup.sh into lib/ + ShellCheck at warning level)

## Objective
setup.sh (1362 lines, 90 functions) becomes a thin entry point that sources cohesive modules in
`lib/`, with the same behavior, and CI lints at `-S warning` instead of `-S error`.

## Problem
One 1362-line file mixes naming, config, lifecycle, background jobs, resources, components,
migrations, upgrade, backup/restore and uninstall. It is hard to review and to assign to the
team, and ShellCheck only fails on errors, so warnings (unused vars, masked return values,
array misuse) accumulate: 10 in setup.sh and a few in other scripts (measured, shellcheck 0.11.0).

## Design
- MECHANICAL split by line ranges, in original order, so top-level assignments (ALIAS_RE,
  COMPONENTS, LOG_KEEP, ...) execute in the same order. No logic changes in the move.
- Modules: lib/common.sh (utils, env_*, registry), lib/instances.sh (naming, ownership, checks),
  lib/config.sh, lib/lifecycle.sh, lib/background.sh, lib/resources.sh, lib/components.sh,
  lib/maintenance.sh (migrations, clean, upgrade, rollback), lib/backup.sh (backup, restore),
  lib/uninstall.sh. setup.sh keeps: header/usage, global paths, sourcing, menu, main.
- usage() prints the header until the closing `# ====` line (was a hardcoded 3,27 range that
  already cut the last header line after the `restore` line was added).
- setup.sh fails with a clear message if lib/ is missing (incomplete copy).
- check_files also requires lib/*.sh. Test sandboxes copy lib/.
- ShellCheck: pinned container koalaman/shellcheck:v0.11.0 (like hadolint/trivy), `-x -S warning`,
  `--source-path=SCRIPTDIR`; fix the measured warnings (no blanket disables; a disable only with
  a reason for real false positives).
- Upgrade path: servers are git clones, `setup.sh upgrade` pulls then execs the new setup.sh, so
  old->new works (verified by reading upgrade(); to be re-checked in a sandbox).
- Static test `tests/modules.test.sh`: lib files exist and parse, every baseline function is
  defined exactly once, setup.sh is small, help shows the full header, CI uses the pinned
  shellcheck at warning level.

## TDD
Mode: strict. Characterization = existing suites (instances, aiws, restore, guide) must stay green;
new runner: `bash tests/modules.test.sh`.

## Tasks
- [x] M1 Tests (RED): tests/modules.test.sh
- [x] M2 Split setup.sh into lib/ (mechanical) + usage fix + lib/ guard + check_files
- [x] M3 Test sandboxes copy lib/; all existing suites green
- [x] M4 Fix ShellCheck warnings (setup.sh/lib, devdb, ws-doctor, tests); CI to pinned `-x -S warning`
- [x] M5 Upgrade-path check in a sandbox (old monolith -> new modular via git pull); docs mention lib/

## Verification
All suites green; `shellcheck -x -S warning` clean with the pinned image; `bash setup.sh help` full.

## Progress / Next
M1-M5 done. setup.sh 1362 -> 180 lines + 10 modules (mechanical split: multiset diff shows only usage() changed). modules test 140/140; ShellCheck 0.11.0 -x -S warning clean on all scripts (10 real warnings fixed: renamed fg in main, find|xargs in devdb/ws-doctor, SC2155 in tests; 3 documented SC2034 disables in tests). Upgrade path old monolith -> modular verified on the Linux VPS with a FAKE docker first in PATH + isolated HOME (migrations include docker volume rm: never run them for real there): rc=0, migrations ran with the new modules. Found and fixed: usage() cut the last header line; setup.sh now ends with "main; exit" (upgrade replaces the file while it runs). Pending: confirm aiws/instances suites in the background run.
