# Docs and landing refresh

## Objective
Bring README.md and the landing page up to date with the current feature set and improve their clarity. Remove every "Dusakawi EPS" mention from the landing page.

## Problem / Why
Recent work (one-command install via install.sh, multiple isolated instances per server, the `aiws` command, CI hardening with pinned actions and Dependabot) may not be reflected consistently in README.md and the landing. The landing footer carries an organization name that is not needed.

## Scope
- README.md
- landing/src/pages/index.astro (and landing components only if needed)

Out of scope: scripts, Dockerfile, compose, CI behavior.

## Constraints
- Keep the existing language of each artifact (Spanish, as the project already uses it); neutral, professional tone.
- Every documented command/flag must exist in the code (install.sh, setup.sh, aiws, env.example, docker-compose.yml).
- No new dependencies in the landing.
- User authorized pushing directly to main.

## TDD
Mode: strict (session config). Runner: none applicable (documentation and static content). Functional checks: `npm run build` in landing/, CI on main.

## Tasks
- [x] T1 Remove all "Dusakawi EPS" mentions from the landing (route: delegated writer, trigger: 2+ non-trivial files)
- [x] T2 Update README.md to match current behavior and improve structure (route: delegated writer)
- [x] T3 Improve landing content so it matches the README and current features (route: delegated writer)
- [ ] T4 Verify landing build, commit, push to main, CI green (route: inline)

## Acceptance criteria
- `rg -i dusakawi landing/` returns nothing.
- README and landing describe install.sh, multi-instance, and aiws accurately.
- `npm run build` in landing/ succeeds; CI on main is green.

## Progress / Evidence
- `rg -i dusakawi landing/src README.md`: no matches.
- `npm run build` (landing/): 1 page built (writer + parent spot check).
- Documented commands checked against aiws/install.sh (ls, resources, upgrade --all, --alias).
- README: rewritten with TOC, quick start (install.sh / manual), instances, aiws reference, config tables, operations, troubleshooting, CI. Removed outdated v1 note, fixed IP, orphan table, external project script reference.
- Unverified (kept from previous README): devdb, ws-doctor, entrypoint, migrations details; resource suggestion ranges.
- Not checked in a browser: nav with one extra link on small screens.

## Next step
T4: review, commit, push to main, CI.
