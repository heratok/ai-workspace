# Feature: backup-restore (tested `setup.sh restore`)

## Objective
A backup is only real if restoring it is a supported, tested command.

## Problem
`setup.sh backup` writes `backups/<name>-<ts>.tar.gz` and prints a `docker run ... tar xzf` line as
text. No `restore` command, no integrity check, no test. Restoring by hand over a live instance can
corrupt home/workspace data.

## Design
- `./setup.sh restore [FILE]`: default = newest backup of this instance; FILE = path or basename.
- Validates the archive first (`tar tzf`, must contain a top-level dir per expected volume).
- Refuses to run while the workspace container is up unless it is stopped first by the command
  itself (confirm prompt; `--yes` skips). Restores into the instance's own volumes only.
- Optional `backup` side effects: write `<file>.sha256`; `restore` verifies it when present.
- Tests use the existing stubbed-`docker` style plus a real tar round-trip in a temp dir.
- Also exposed in the interactive menu and `aiws` (if it wraps setup.sh commands).

## Scope
setup.sh, tests/restore.test.sh (new), .github/workflows/ci.yml, README.md.

## TDD
Mode: strict. Runner: `bash tests/restore.test.sh`, added to CI.

## Tasks
- [x] R1 Tests (RED): newest-backup selection, archive validation (good/bad/empty), checksum
      verify, refuses unknown FILE, running-container guard, volumes targeted
- [x] R2 setup.sh: `backup` writes sha256; `restore` implemented; usage/menu updated
- [x] R3 Real round-trip with Docker: backup -> wipe volume -> restore -> contents equal
- [x] R4 CI step + README section

## Verification
`bash tests/restore.test.sh`; manual Docker round-trip on throwaway volumes (never real instance data).

## Progress / Next
R1-R4 done. tests/restore.test.sh 32/32; real Docker round trip (backup -> corrupt -> restore) verified on throwaway volumes; aiws restore wired (aiws.test 395/395); instances 315/315. Bugs found by tests: GNU tar treats "C:/x" as remote host -> tar now reads stdin. Not done: interactive menu entry. Local-only failures: fetch-script.test (4, Windows curl file:// paths, untouched file).
