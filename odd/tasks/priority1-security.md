# Feature: priority1-security (entrypoint symlink escalation, sshd forwarding, safe restore)
Branch: fix/priority1-security. Delivery: ask-on-risk. Runners: `bash tests/restore.test.sh`,
`bash tests/security.test.sh`, `AIWS_TEST_IMAGE=<img> bash tests/entrypoint.test.sh` (needs Docker).

## Specs
- S1 The entrypoint (root) never follows a symlink planted by `ai` inside `/home/ai`: no chown,
  chmod or directory creation through a symlinked path component (`.cache -> /usr/local/bin`,
  `.ssh/authorized_keys -> /etc/shadow`, `.npm-global -> /usr/local/lib` ...). It logs an AVISO
  and keeps starting sshd. A fresh home still gets every install dir owned by `ai`.
- S2 sshd: `AllowAgentForwarding no`, `AllowTcpForwarding local` (`ssh -L` for OAuth keeps
  working), `AllowStreamLocalForwarding no`, `PermitTunnel no`. Docs that say `yes` updated.
- S3 `restore` never deletes the archive it is restoring: the safety backup it takes first does
  not rotate old backups.
- S4 `restore` with a relative path (`./setup.sh restore backups/x.tar.gz`) works: the path is
  made absolute before it is bind-mounted (a relative `-v backups:/b` is a named volume in Docker).
- S5 If the extraction fails, `restore` puts the safety backup back, restarts the workspace if it
  was running, and exits with an error.

## Tasks
| ID | Specs | Route | Status | Evidence |
|---|---|---|---|---|
| T1 | S1 | inline | done | RED on test VPS (old entrypoint): /usr/local/bin, /etc/ssh/sshd_config.d and /etc/shadow became owned by `ai` after a restart. GREEN: tests/entrypoint.test.sh 12/0 |
| T2 | S2 | inline | done | RED 4/4 in entrypoint.test; GREEN. Real check on VPS: login ok, `ssh -L` HTTP 200, `-R` refused, no SSH_AUTH_SOCK with `-A`, ws-doctor exit 0. hardening.test 11/0 |
| T3 | S3-S5 | inline | done | RED 7 asserts (fake docker now mimics real Docker: relative -v = named volume). GREEN restore.test 47/0. Real Docker on VPS (throwaway `ai-workspace-eptrt_*` volumes): relative path + AIWS_BACKUP_KEEP=1 restores v1 and keeps the archive; same scenario on `main` wiped both volumes and created a stray `backups` volume; failing extraction (hardlink to a missing member) rolled back to the safety backup, rc=1, data intact |

## Log
- L1 (2026-11-05, user): "que le podemos mejorar a esto? revisando todo lo que tenemos?" -> review;
  user then: "ssh -i "$env:USERPROFILE\.ssh\aryuwi-prueba" opc@100.112.41.81 puedes probar todo y
  hacer todo en esta instancia de prueba".
- L2 Out of scope (follow-up): move `authorized_keys` to a root-owned `AuthorizedKeysFile`
  (persisted format change + migration + `add_key`).
- L3 Test server note: it also runs Coolify, dusakawi-api, mipres, Mayan, Ollama. Touch only
  throwaway `aiws-ept-*` resources. The existing `ai-workspace-ts` sidecar is in a restart loop
  (4855 restarts) waiting for device approval in the Tailscale admin console (old install, before
  commit 2061529); left untouched.
- L4 Found while testing (follow-up): backup archives are written by a root container into the
  bind-mounted `backups/`, so they end up owned by root and `chmod 600` silently fails (mode 644).
  The `backups/` dir is 700 so other host users cannot read them, but the owner cannot chmod/touch
  them. Fix idea: `tar ... | cat > file` on the host side, or `--user $(id -u)`.
- L5 Checks: shellcheck v0.11.0 (CI list) clean; restore 47/0, entrypoint 12/0 (real image),
  instances 340/0, aiws 403/0, modules 144/0, hardening 11/0, security 55/0, migrations 21/0,
  docs 62/0. Not run: image rebuild with the new entrypoint baked in (tested by bind-mounting it).
- L6 Independent verifier (diff 2061529..9141af7+6aa03eb): S1-S5 met, no blockers. Strict-mode
  probes (set -Eeuo pipefail + trap ERR) confirm the rollback path and relative path; differential
  vs baseline: normal `backup` identical. Advisories (pre-existing): safety-backup failure aborts with
  the workspace stopped; backup names have 1 s resolution (same-second backup + restore collide);
  `~/.ssh` as a regular file makes the container restart-loop. New, minor: `readlink -f` resolves a
  symlinked archive argument to its target name.
