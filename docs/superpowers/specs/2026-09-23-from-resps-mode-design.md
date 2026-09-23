# from-resps: a CV-only question guide per project

**Status:** implemented on this branch
**Scope:** `interview-prep` gains a fourth mode; `from-cv` is renamed `from-design`
**Branch:** `feat/from-resps-mode`
**Implementation plan:** written, executed, then removed. Recover it with `git show 0d88901:docs/superpowers/plans/2026-09-23-from-resps-mode.md`.

---

## Problem

`from-design` writes a project guide whose questions come from the design docs: they name endpoints, services, tables and decisions that exist only in `/system-design` output. That suits an interviewer who has read the design. Most interviewers have not. They hold the CV — description, environment, responsibilities — and ask about the technologies it lists and the work it claims. A guide built from the design does not prepare the candidate for that interviewer.

## Decisions

- **Two project-level modes.** `from-design` (the renamed `from-cv`, unchanged in behaviour) writes `interview-questions.md`. `from-resps` writes `resps-questions.md`. Separate files, so neither overwrites the other and the existing guides stay valid.
- **The knowledge boundary applies to questions only.** A `from-resps` question may use only what `inputs.txt` states plus general knowledge of the listed technologies. Answers still draw on the design docs, so the gate requires them for `from-resps` as it does for `from-design`.
- **One section per responsibility, at most three questions each**, scaled to how much the responsibility holds. Sections are ordered by topic, not by CV position.
- **The cap is kept when a responsibility names more concerns than three questions can cover.** Each question takes one concern; the rest stay unasked and the review reports them. Bundling them into compound questions hides the gap and blurs the question.
- **Difficulty levels have one owner**, `references/tiers.md`, cited by both project modes.
- **`extend` reads `resps-questions.md`** as further covered ground. It is an optional input: reported, never blocking.

## Rejected alternatives

- **Brief-only answers.** Answering "which indexes did you add" from the brief forces invented specifics, which breaks the honesty rule and brings back the Environment-line recital the gate exists to prevent. An optional-docs variant would need an extra gate state and would put made-up detail into a prep pack.
- **One shared output file.** Both modes would overwrite each other, and `extend`'s dependency on `interview-questions.md` would become ambiguous.
- **Keeping `from-cv` as an alias.** Two names for one mode is a second owner for the mode word. The harness asserts that `from-cv` is now an unknown mode.
- **Topic headings above responsibility sections.** Question blocks already use `###`, so a topic level would need a new heading depth. The topic goes into the section heading instead.
