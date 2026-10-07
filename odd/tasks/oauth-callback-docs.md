# OAuth localhost callbacks from the user's PC

## Objective
Document and diagnose how to complete OAuth logins whose callback is `http://localhost:PORT/...` when the agent runs inside the container and the browser runs on the user's PC (Windows).

## Problem / Why
`localhost` in the browser is the user's PC, not the container, so the redirect ends in ERR_CONNECTION_REFUSED (e.g. pi on port 53692, MCPs with OAuth on random ports). SSH terminates inside the container (sshd shares the tailscale netns; no host port published) and AllowTcpForwarding is yes, so `ssh -L` works, but nothing in the guide/README says so and agents waste tokens investigating.

## Scope
1. config/AGENTS.md: short section "Login OAuth con callback en localhost" (keep the whole guide <= ~60 lines)
2. README.md: section with the explanation, the three methods, and a `~/.ssh/config` snippet (Windows) with `LocalForward`; note that mosh does not forward ports; TOC updated
3. config/ws-doctor: check that TCP forwarding is enabled (read /etc/ssh/sshd_config.d/10-ai-workspace.conf; `sshd -T` needs root so do NOT use it); warn, not fail, if the file is unreadable
4. tests/guide.test.sh (and CI if needed): guide contains the OAuth section; ws-doctor check covered

Out of scope: BROWSER helper script, sshd hardening (PermitOpen), any change to sshd config.

## Methods to document (in this order)
- A) Add the tunnel without reconnecting: inside the SSH session press `~C`, then `-L PORT:127.0.0.1:PORT` (PORT appears in the `redirect_uri=http://localhost:PORT/...` of the login URL)
- B) Fixed-port tools (pi 53692): `LocalForward 53692 127.0.0.1:53692` in the PC's ~/.ssh/config under `Host ai-workspace`
- C) Fallback without tunnel: copy the full callback URL from the browser address bar and run `curl '<url>'` inside the container while the tool is still waiting. Mark as "probar primero: no verificado con todas las herramientas".
Also: mosh does not forward ports (open a separate `ssh -N -L ...`); `gh auth login`, `doppler login`, `agy` do not need this (code/paste flows).

## Constraints
- Spanish, neutral professional tone, no voseo. Every command cited in AGENTS.md table rows must keep passing the CI "commands exist" check (only cite binaries that exist; `ssh`, `curl` exist in the image).
- Do not claim the curl method is verified.
- No commit/push.

## TDD
Mode: strict (session config). Runner: `bash tests/guide.test.sh`, `bash tests/instances.test.sh`, `bash tests/aiws.test.sh`, `shellcheck -S error` (docker koalaman/shellcheck if not installed). RED first.

## Tasks
- [x] T1 RED: tests for OAuth section in guide + ws-doctor forwarding check fail
- [x] T2 AGENTS.md section
- [x] T3 ws-doctor forwarding check
- [x] T4 README section + SSH snippet + TOC
- [x] T5 all tests + shellcheck, report

## Acceptance criteria
- Guide has the OAuth section (<= ~60 lines total); `ws-doctor` reports forwarding enabled/disabled; tests and shellcheck green.

## Progress / Evidence
- T1 RED: `bash tests/guide.test.sh` (Git Bash) -> 31 correctas, 10 fallidas (sección OAuth, orden y 3 casos de ws-doctor).
- T2-T4 GREEN: `bash tests/guide.test.sh` (Git Bash) -> 41 correctas, 0 fallidas, 7 omitidas (symlinks).
- Linux (docker debian:12-slim): guide.test.sh 57/0/0 omitidas; instances.test.sh 321/0; aiws.test.sh 387/0.
- `shellcheck -S error` (koalaman/shellcheck:stable) sobre ws-doctor y guide.test.sh: sin hallazgos; `bash -n`: ok.
- Guía: 55 líneas; comandos citados en filas de tabla (devdb doppler gh mise npm playwright-cli psql uv ws-doctor) todos verificados por CI.
- No ejecutado: docker build completo, render del README.

## Next step
Revisión del diff y commit por el usuario.
