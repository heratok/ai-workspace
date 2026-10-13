# Feature: docs-split (README as quick start + docs/)

## Objective
README.md is a quick start someone reads in two minutes; the reference material lives in `docs/`.

## Problem
README.md has ~630 lines mixing quick start, reference (.env, aiws, commands), tool guides and
troubleshooting. Finding the install steps means scrolling past everything else, and every new
feature lands in the same file.

## Design
- README.md (~130 lines): intro + diagram, quick start (A/B, what install does, connect),
  requirements and Tailscale (needed to start), and an index of the docs.
- docs/instancias.md (multi-instance + aiws), docs/configuracion.md (.env, resources, components),
  docs/operacion.md (commands, upgrade, backup/restore, volumes), docs/herramientas.md (image,
  databases, installing tools, agents), docs/solucion-de-problemas.md, docs/desarrollo.md (CI,
  migration from v1).
- Content moves VERBATIM (no rewriting); headings keep their text so existing anchors map 1:1.
  Links are rewritten by a script from a heading->file map, not by hand.
- Code references to README sections (docker-compose.yml, setup.sh) are updated.
- Static test `tests/docs.test.sh`: README length cap, every doc exists and is linked from the
  README, every relative link and #anchor in README+docs resolves (GitHub slug rules, perl for
  Unicode), key headings preserved, code references updated. Added to CI.

## TDD
Mode: strict. Runner: `bash tests/docs.test.sh` (new; needs perl, present in CI and Git Bash).

## Tasks
- [x] D1 Tests (RED)
- [x] D2 Split with a script (verbatim move + link rewrite); verify no line of content lost
- [x] D3 Update code references + CI step
- [x] D4 Review the rendered structure (headings, back links) and commit

## Verification
`bash tests/docs.test.sh`; line-count reconciliation old README vs README+docs (only added
headers/back links/index lines differ).

## Progress / Next
D1-D4 done. docs test 61/61 (link checker validated with injected broken links). Split by script (scratchpad, not committed): zero lines of content lost (old vs new multiset diff), only headers/back links/index added. The test caught a relative link (migrations/README.md) that needed ../. README 628 -> 124 lines. Pending: landing page text may still reference README sections (checked: no references).
