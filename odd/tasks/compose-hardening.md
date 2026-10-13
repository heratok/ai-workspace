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
- REQUIRED (container fails or sshd refuses login without them): CHOWN, DAC_OVERRIDE, FOWNER,
  SETGID, SETUID, SYS_CHROOT.
- NOT required: KILL, NET_BIND_SERVICE, AUDIT_WRITE, SETPCAP, and all other Docker defaults.
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
