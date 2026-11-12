# Feature: compose-hardening (cap_drop ALL on the workspace container)

## Objective
The workspace container runs sshd/entrypoint as root. Drop every Linux capability it does not
need so a compromise of the root-run part has the smallest possible blast radius.

## Problem
`docker-compose.yml` only sets `no-new-privileges`. The workspace keeps Docker's default 14
capabilities (NET_RAW, MKNOD, SETFCAP, AUDIT_WRITE, KILL, ...). The unprivileged user `ai`
already has none; only the root parts (entrypoint, sshd) use them.

## Evidence (measured, not guessed) - Linux test VPS, throwaway containers, current entrypoint.sh
`cap_drop: ALL` + leave-one-out, login via sshd with FIX_OWNERSHIP=true:
- REQUIRED (container fails or sshd refuses login without them): AUDIT_WRITE (pty logins), CHOWN, DAC_OVERRIDE, FOWNER,
  SETGID, SETUID, SYS_CHROOT. Plus KILL for sshd's abnormal-exit cleanup of the `ai` child (see L2).
- NOT required: NET_BIND_SERVICE, SETPCAP, and all other Docker defaults. (AUDIT_WRITE and KILL were wrongly
  listed here: the measurement used SSH without a pty. See L1.)
- Also verified with the real topology (network namespace shared with the sidecar, no published
  port): works with exactly the 6 required caps, without NET_BIND_SERVICE.

## Design
- `ai-workspace` service: `cap_drop: [ALL]` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID,
  SETUID, SYS_CHROOT]`, with a comment saying why each is needed and how to add one if a future
  root-run feature needs it.
- Tailscale sidecar and mssql untouched (out of scope; follow-up for the sidecar).
- Static test `tests/hardening.test.sh`: exact cap set, no privileged, no NET_ADMIN/SYS_ADMIN on
  the workspace, `no-new-privileges` kept. Added to CI.

## TDD
Mode: strict. Runner: `bash tests/hardening.test.sh` (new, plain bash, no Docker needed).

## Tasks
- [x] H1 Tests (RED): exact cap set + no privileged/NET_ADMIN/SYS_ADMIN + no-new-privileges kept
- [x] H2 docker-compose.yml: cap_drop ALL + the 6 caps, documented
- [x] H3 CI step; README security note
- [x] H4 Verified on the Linux VPS with equivalent docker flags (old image + CURRENT entrypoint.sh and sshd conf), incl. shared network namespace like production; NOT with the full real compose (sidecar needs a Tailscale authkey). Original text: (throwaway instance alias, no existing
      resources touched)

## Verification
`bash tests/hardening.test.sh`; `docker compose config -q`; measured leave-one-out (done).

## Progress / Next
H1-H4 done. hardening test 7/7, pins 46/46, compose config renders cap_drop/cap_add. Follow-up: tailscale sidecar could also use cap_drop ALL + NET_ADMIN (needs its own measurement). Known unverified: runtime of Chromium/devdb under the new set (they run as user ai, which never had capabilities).

## Log
- L1 (2026-11-12) Bug: interactive SSH sessions close right after authentication. Client: "Connection to ... closed
  by remote host", "Exit status -1". Container log:
  `Accepted publickey for ai ...` / `linux_audit_write_entry failed: Operation not permitted` /
  `syslogin_perform_logout: logout() returned an error` / `cleanup_exit: kill(673): Operation not permitted`.
  Cause: Debian 12 sshd (OpenSSH 9.2p1, built with Linux audit) calls `audit_session_open()` when it records the
  login of a session with a pty and calls `fatal()` on EPERM, so it needs CAP_AUDIT_WRITE. sshd runs as root and
  must signal its session children, which run as `ai`, so it also needs CAP_KILL.
  Why the leave-one-out measurement missed it: logins were checked with non-interactive SSH commands (no pty),
  which never reach `audit_session_open`, so AUDIT_WRITE and KILL looked unneeded.
  Change: `cap_add` gains AUDIT_WRITE and KILL (8 caps); `cap_drop: ALL` and `no-new-privileges` unchanged.
  `tests/hardening.test.sh` asserts both (RED 3 fails, then GREEN); `tests/entrypoint.test.sh` mirrors the set.
  No Docker integration test opens a real SSH session, so the pty path (`ssh -tt ai@... true`) has no automated test.
- L2 (2026-11-12) Verified on the Linux test VPS with the current `ai-workspace:latest` image, throwaway containers,
  `ssh` from inside the container to 127.0.0.1:
  old 6 caps: no pty exit=0; `ssh -tt ... true` exit=255 "closed by remote host" + `linux_audit_write_entry failed`
  (bug reproduced). 6 + AUDIT_WRITE + KILL: no pty exit=0, pty exit=0.
  Nuance: 6 + AUDIT_WRITE alone already fixes the pty login, and a client-killed pty session left no orphaned
  processes. `cleanup_exit: kill(): Operation not permitted` only appears on sshd's abnormal-exit path (after the
  audit `fatal()`), where the root monitor must kill the child running as `ai`. KILL is kept, as requested, for
  that path; it was not needed for the successful login.
