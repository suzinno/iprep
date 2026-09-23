# from-resps mode — implementation plan

Spec: `docs/superpowers/specs/2026-09-23-from-resps-mode-design.md`. Delete this file on the branch before merge.

1. Rename `from-cv` → `from-design`: `git mv` the mode file; update `preflight.sh`, `gate-check.sh`, `SKILL.md` (re-parse frontmatter), `mode-extend.md`, `candidate-profile.md`, `output-conventions.md`, `README.md`, `CLAUDE.md`. Harness asserts `from-cv` is CANNOT-RUN "unknown mode".
2. Extract `references/tiers.md` from the from-design Step 3; `from-design` cites it. Scope the shared "numbering unbroken" check to case-level packs.
3. Add `from-resps`: shared gate branch with `from-design`; `references/mode-from-resps.md`; SKILL/README/CLAUDE updates; fixtures READY / BLOCKED docs / BLOCKED not filled / CANNOT-RUN case folder.
4. `extend` reports each sourced project's `resps-questions.md` (FOUND / ABSENT / PRESENT BUT EMPTY / PRESENT BUT UNUSABLE), never blocks; `mode-extend.md` reads it when FOUND. One fixture per report, plus READY when absent.
5. Verify: shellcheck sweep, `gate-check.sh`, `link-abbreviations-check.sh`, `link-abbreviations.py --check` on case 02; six mutations (four existing + from-resps doc requirement + extend resps report), each `bash -n` checked, restored from a scratchpad backup; residual `from-cv` count.
