# Feature: priority2-robustness (operation lock, graceful stop, safe backups, honest uninstall)
Branch: fix/priority2-robustness (from fix/priority1-security). Delivery: ask-on-risk.
Runners: plain bash suites in tests/ (Linux for flock and Docker parts; test VPS opc@100.112.41.81).

## Specs
- S1 Mutating `setup.sh` commands of one instance never run at the same time: they take an
  exclusive per-instance lock (`flock`). If it is held, the command stops with a clear message
  naming the instance, without changing anything. The background process (install/upgrade/update)
  keeps the lock until it ends. Read-only commands (status, progress/logs, doctor, help, ls) do not
  take it. Without `flock` on the host: warn once and continue (no lock), never fail.
- S2 `docker stop` / `compose stop` shuts down local PostgreSQL and Redis (devdb) cleanly before
  sshd exits, instead of SIGKILL after the grace period; the workspace service gets
  `stop_grace_period: 30s`.
- S3 Every compose service limits its Docker logs (json-file, max-size 10m, max-file 3).
- S4 `clean` (explicit, or the one `update`/`upgrade` run) no longer deletes backups; backups rotate
  only when `backup` runs, and archives and their `.sha256` rotate together (no orphan checksums).
- S5 `backup` is atomic: it writes `<file>.partial` and renames at the end; on failure no archive
  with a valid name is left and the local databases are started again.
- S6 Backup archives and checksums belong to the user running `setup.sh`, mode 600 (today a root
  container writes them: root-owned, 644).
- S7 `uninstall --all`: if any volume cannot be removed, it keeps `.env` and the instance registry
  entry, lists the volumes that failed and exits non-zero (never prints "Todo eliminado").
- S8 `rollback` keeps local changes in a `git stash` (same behavior and prompt as `upgrade`) instead
  of discarding them with `reset --hard`.

## Tasks
| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| W1 | S1 | delegated (parallel writer) | done (125cf43) | RED 8 fails; lock.test 17/0 on Linux (6 skipped on Windows, no flock) |
| W2 | S2-S3 | delegated (parallel writer) | done (ddc7c0c) | RED: PG/Redis logs had no shutdown line; GREEN entrypoint.test 15/0 real container; hardening 16/0 |
| W3 | S4-S8 | delegated (parallel writer) | done (1e712f2) | RED 17+15 fails; restore 66/0, maintenance 29/0; real Docker: opc 600, no .partial after forced failure |

Route evidence: three independent units with disjoint edit surfaces, each several files and
real-environment checks, launched together (Writer trigger a).

## Log
- L1 (2026-11-05, user): "sigue con la prioridad 2" — after the review list: lock between
  operations, Postgres/Redis SIGKILL on stop, update deleting backups, partial backups, uninstall
  --all claiming success, rollback reset --hard, unbounded Docker logs; plus root-owned backups
  found while testing priority 1.
- L2 Parent fix during integration: rotation glob `ai-workspace-[0-9]*` also matched alias "2"
  archives (RED: both deleted); `rotate_backups` now filters with `is_own_backup_name`. Also
  `setup.sh rollback "$@"` and CI step for tests/maintenance.test.sh.
- L3 Seam check on Linux (all 15 hermetic suites + shellcheck CI list): all 0 failures;
  entrypoint.test 15/0. Behavior change: install/update while another op runs now exits with the
  lock message (suggesting `./setup.sh progress`) instead of attaching to it.
- L4 Independent verifier (f33493a..125cf43): S1-S8 met, no blockers. Fixed A1: help text of
  `clean` (setup.sh header + menu, aiws) still said it deletes old backups; header now shows
  `rollback [--yes]`. Advisories left: A2 `op_lock` creates `logs/` (fails if a previous `sudo` run
  left it root-owned); A3 pre-existing: signal before the trap or sshd dying alone still kills
  devdb; A4 `docker volume inspect` failing for another reason is treated as "volume absent";
  A5 with `install --alias X` the lock message names the previous AIWS_NAME (folder is correct).
