# Feature: security-scan (Hadolint + Trivy in CI, weekly schedule)

## Objective
Find Dockerfile smells, leaked secrets, vulnerable dependencies and image CVEs automatically,
including when nobody pushes (new CVEs appear without code changes).

## Problem
CI only checks syntax, ShellCheck(error), tests and that the image builds. No lint of the
Dockerfile, no CVE/secret scan, and it only runs on push/PR, so a CVE published tomorrow is
never noticed.

## Baseline (measured on the Linux test VPS, tools run as containers)
- Hadolint v2.15.1 on Dockerfile: 0 errors, 12 warnings. SC3010/SC3054/SC3014 are false positives
  (hadolint assumes POSIX sh although the Dockerfile sets SHELL to bash); DL3008 (unpinned apt) is
  intentional (declarative config/packages.apt); DL3003 (cd /tmp in one RUN); DL3046 (-l, UID 1000);
  DL3025 (HEALTHCHECK CMD form); DL3064 (ARG names).
- Trivy v0.75.0 `fs` (vuln,secret,misconfig, HIGH+CRITICAL): 0 secrets; 1 HIGH misconfig DS-0002
  (Dockerfile has no non-root USER: intentional, sshd needs root and drops to `ai`; capabilities are
  now limited by cap_drop ALL); 1 HIGH vuln in landing/package-lock.json (http-cache-semantics,
  NO fixed version -> filtered by --ignore-unfixed).
- Full-image scan baseline: measured later (see Progress).

## Design
- New CI job `security` (parallel to `lint`): Hadolint (`--failure-threshold error`, config in
  `.hadolint.yaml` with a reason per ignored rule) and Trivy `fs` (`--ignore-unfixed`, HIGH+CRITICAL,
  `--exit-code 1`, accepted findings in `.trivyignore` each with a reason).
- In the `build` job after the build: Trivy image scan: CRITICAL with a fix BLOCKS (baseline measured: 0); HIGH reported only (exit 0; ~40, all in third-party Go binaries gh/gentle-ai).
  (Baseline measured later on the full 5.12 GB image built on the Linux VPS.)
- Workflow also triggers weekly (`schedule`, Monday 06:00 UTC) so drift and new CVEs surface.
- Tools run as pinned containers (hadolint/hadolint:v2.15.1, aquasec/trivy:0.75.0): no third-party
  action to SHA-pin. Dependabot does not see versions inside `run:` lines (manual bump, noted in README).
- Static test `tests/security.test.sh`: schedule present, tools pinned (no latest), config files
  exist and every ignore has a rationale comment, image scan step present.

## TDD
Mode: strict. Runner: `bash tests/security.test.sh` (new, plain bash, no Docker).

## Tasks
- [x] S1 Tests (RED)
- [x] S2 .hadolint.yaml and .trivyignore with rationale
- [x] S3 ci.yml: schedule, `security` job, image scan step
- [x] S4 README (CI section) + validate: run the exact CI commands on the Linux VPS

## Verification
`bash tests/security.test.sh`; the same hadolint/trivy commands as CI on the VPS (exit codes 0).

## Progress / Next
S1-S4 done. security test 25/25 (incl. a YAML step-name guard: actionlint caught an unquoted ": " that would have broken the whole workflow). Full image built on the VPS (5.12 GB): CI tool checks pass incl. Chromium; trivy image CRITICAL exit 0. INCIDENT: that build+scan took the VPS disk from 73% to 98% before cleanup (guard covered only the build) - see memory reference/test-vps-rules. Exact CI commands run on the Linux VPS: hadolint exit 0, trivy fs exit 0 (landing http-cache-semantics filtered by --ignore-unfixed, DS-0002 accepted), actionlint 1.7.7 exit 0. NOT verified: the cron schedule (only runs on GitHub). Follow-up: promote CRITICAL to blocking after the first runs.
