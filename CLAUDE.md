# CLAUDE.md

## Project Overview

`iprep` generates interview preparation material: a system design reverse-engineered from a CV project brief, a per-project question-and-answer guide, and case-level answer packs for a client's question set. Two skills do the work — `system-design` produces the design docs, `interview-prep` consumes them — and everything they read or write lives under `cases/`. The one concept to hold: a **case** is one engagement holding any number of CV projects plus at most one interview pack shared across all of them, and every dependency between steps is an **artifact on disk**, never "a skill ran earlier".

**Out of scope (do not add):** not a CV writer, not a general document generator, not a job tracker; no link or inference between two cases.

## Where to find things

`README.md` is the operational entry point: how to start a case, the pipeline order, and how to check where a case stands.

| Need | Read |
|---|---|
| Run the pipeline end to end | `README.md` |
| What each mode requires, writes, how they chain | `.claude/skills/interview-prep/SKILL.md` |
| How every generated document is formatted | `.claude/skills/interview-prep/references/output-conventions.md` |
| How a client brief reweights generation | `.claude/skills/interview-prep/references/candidate-profile.md` |
| What one mode actually does | `.claude/skills/interview-prep/references/mode-from-cv.md`, `mode-answer.md`, `mode-extend.md` |
| The exact precondition contract | `.claude/skills/interview-prep/scripts/preflight.sh` |
| What the gate is actually proven to do | `.claude/skills/interview-prep/scripts/gate-check.sh` |
| How design docs are produced | `.claude/skills/system-design/SKILL.md` |

## Don't touch without reading

- `.claude/skills/interview-prep/scripts/preflight.sh` — read the header comment first. It is the only thing between a confident wrong answer and a correct one; its exit codes are a contract every caller dispatches on.
- `.claude/skills/interview-prep/SKILL.md` frontmatter — a bulk text transform once joined `name:` and `description:` onto one line, silently invalidating the YAML so the skill re-registered as `interview-prep: Role`. Re-parse it after any scripted edit.
- `.claude/skills/interview-prep/references/output-conventions.md` — sole owner of the question block, style rules, project attribution and the shared review checklist. Changing a format here changes every generated document; changing a format anywhere else creates a second owner.
- `.claude/skills/interview-prep/scripts/gate-check.sh` — the only real guard in the repo. Weakening a check here silently downgrades seven invariants to conventions; add checks rather than relax them.
- `cases/nn/` — a template, not a case. Never work in it and never write generated output into it.
- `cases/01/interview/ss-answers.md`, `ts-answers.md`, `ss-final-pack.md` — pre-skill leftovers no mode reads and no gate checks. Near-duplicates of the canonical `soft-skills-answers.md` / `tech-answers.md` that differ from them. Leave them alone until someone decides their fate.

## Language / Stack rules

- Shell is the only executable code. `preflight.sh` must pass `shellcheck .claude/skills/interview-prep/scripts/*.sh` — run it as a directory sweep, not on one file, because a solo invocation silences findings the sweep reports.
- Markdown in `.claude/skills/` is **unwrapped**: one long line per paragraph and per list item. Do not reflow it. Code fences, tables and frontmatter are exempt and stay line-broken.
- Prose in the skills names the artifact, never the folder tree it happened to sit in when written. `<project>` means `<case>/projects/<name>`; `<interview>` means `<case>/interview`.
- `system-design` owns the `inputs.txt` schema (`Title:` / `Description:` / `Environment:` / `Responsibilities:`). Reference those heading labels as an interface; never restate what belongs in each section.

## Architectural Invariants

Declared rules. Each names its guard, or is marked `[UNGUARDED]` — meaning nothing fails when it is broken, so it will be violated silently. The guard is `.claude/skills/interview-prep/scripts/gate-check.sh`, which has been mutation-tested: folding CANNOT-RUN into BLOCKED, accepting a stub brief, dropping the profile note, and removing the project/case guard are each detected.

- **Dependencies are artifacts on disk, never session state.** No record of past invocations survives a `/clear` or another machine, so the gate checks files. *(guard: `scripts/gate-check.sh` — every fixture is built fresh in a temp directory, so verdicts can only come from files)*
- **The gate has exactly three states and callers dispatch on exit code, not text.** `0` READY, `1` BLOCKED (a prerequisite artifact is missing), `2` CANNOT-RUN (the invocation itself is malformed). Folding "you gave me a bad path" into "your prerequisites aren't met" is the failure this prevents. *(guard: `scripts/gate-check.sh` — CANNOT-RUN section)*
- **A BLOCKED result names a runnable remedy**, e.g. `run: /system-design cases/02/projects/<name>`. *(guard: `scripts/gate-check.sh` — remedy strings are asserted, not just exit codes)*
- **Stub inputs are rejected on content, not on `-s`.** A 2-byte question file (`1 `) and a 54-byte `inputs.txt` holding only the four headings are both non-empty and both worthless. `has_questions` and `has_brief_content` measure real text; the latter strips the heading labels first, because `Responsibilities:` is 17 characters and clears a naive threshold alone. *(guard: `scripts/gate-check.sh` — stub and unfilled-template checks)*
- **Optional inputs are always reported, never silent.** Every run prints the profile, both question files and every project by name. An optional input that goes unnoticed is how a feature silently fails to happen. *(guard: `scripts/gate-check.sh` — reporting section)*
- **Answers are bound to design docs, never to a brief alone.** Every project with a usable brief must have its `/system-design` docs before `answer` runs. `inputs.txt` names the stack and responsibilities but not the architecture, data models or failure modes that make an answer specific; without them the pack recites the Environment line. A case with no projects has nothing to bind to and still runs. *(guard: `scripts/gate-check.sh` — the brief-only fixtures)*
- **`answer` needs at least one source** — a question file, a profile, or a project brief. Otherwise "everything is optional" means inventing an interview out of nothing. *(guard: `scripts/gate-check.sh`)*
- **`from-cv` is per project; `answer` and `extend` are per case.** A case-level `from-cv` would have to block on the least-ready project or invent a fourth "partly ready" state. *(guard: `scripts/gate-check.sh` — the two cross-kind CANNOT-RUN checks)*
- **One owner per fact.** `output-conventions.md` owns format; `candidate-profile.md` owns client weighting; `SKILL.md` owns the chain; each mode file owns only its own logic. Restating a fact elsewhere is duplication even when the wording differs. `[UNGUARDED]` — a prose convention; nothing fails when it is broken.
- **Cases are independent.** Nothing infers a link between two cases from folder numbering or content resemblance, however similar their projects. `[UNGUARDED]` — an absence, and nothing tests for one.
- **Question order is never rearranged.** A client's bank is pooled from prior candidates and already grouped; its order is what the interviewer reads from. Per-project separation is carried by the `**Project:**` tag and the index — an attribution, not a partition. `[UNGUARDED]` — a content convention, checked only by the review checklist.

### Forbidden patterns

- No mode reads an input the gate did not report. If a mode needs a new file, the gate learns about it first.
- No `-s`-only usability test on a file a human is expected to fill in.
- No second copy of the answer format, the style rules, or the chain outside their owner files.

## Security and honesty rules

- `candidate-profile.txt` is confidential client material and often describes the client's own staff and internal friction. Render scenarios neutrally; never reproduce a brief's characterisation of its people into generated output.
- Never write an answer claiming experience the project briefs and design docs do not support. Where there is no such experience, answer honestly about what is adjacent.
- Never present a generated question as one the client asked. Each pack's header states whether its questions were supplied or generated.

## Testing

**Scope.** `preflight.sh` is the only thing with automated checks, and it gets more scrutiny than the content it guards. Generated documents are verified by the review checklist in `output-conventions.md` plus each mode file's own checks.

**Commands.**

```
shellcheck .claude/skills/interview-prep/scripts/*.sh
.claude/skills/interview-prep/scripts/gate-check.sh
```

`gate-check.sh` builds every fixture in a temp directory and exits non-zero on any failure. It ends with a self-test that plants a wrong expectation and confirms it is reported — a suite that only ever passes confirms whatever you already expected.

**Re-verifying the harness itself.** After changing either script, mutate `preflight.sh` and confirm the harness fails, then restore with `git checkout --`. Four mutations that must be caught: `EXIT_CANNOT_RUN=1`, bypassing `has_brief_content`, altering a `notes:` string, and removing the `projects` parent-directory guard.

**Spot checks against real cases** (these depend on live data and go stale as work is done — the harness deliberately does not):

```
PF=.claude/skills/interview-prep/scripts/preflight.sh
$PF from-cv cases/01/projects/cancer-support-platform   # 0 READY
$PF from-cv cases/02/projects/cancer-support-platform   # 1 BLOCKED, remedy names /system-design
$PF answer  cases/02                                    # 0 READY
$PF extend  cases/02                                    # 1 BLOCKED, remedy names /interview-prep answer
$PF from-cv cases/01                                    # 2 CANNOT-RUN, a case is not a project
$PF answer  cases/01/projects/cancer-support-platform    # 2 CANNOT-RUN, a project is not a case
$PF frobnicate cases/01                                 # 2 CANNOT-RUN
```

**Patterns.** Always pair a known-pass with a known-fail, and include a deliberately-wrong control — a check suite that only ever passes confirms whatever you already expected. Three states per check, never two: pass, fail, and could-not-run. Build fixtures in a scratch directory, never inside `cases/`.

Known traps, each of which has produced a false FAIL here: `from-cv` treats the project brief as *required*, so it appears under `verified:`, not among the optional `notes:`; `notes:` print on BLOCKED as well as READY, so asserting a note says nothing about the exit code; and `ABSENT` wraps its path in parentheses while `SOURCED` and `FOUND` do not.

## AI pair behavior

- Run the gate before anything else, and dispatch on its exit code. A BLOCKED result is not a hurdle to reason around — report the remedy verbatim and offer to run it.
- Report every `PRESENT BUT EMPTY`, `PRESENT BUT UNUSABLE`, `PRESENT BUT HOLDS NO QUESTIONS` or `PRESENT BUT NOT FILLED IN` note to the user before generating. Someone put that file there deliberately.
- Do not create files under `cases/` unasked, and never delete generated output to "regenerate cleanly" without asking — some of it is hours of work and is not reproducible identically.
- Flag duplication proactively: a rule appearing in two files is a defect here, not a convention.
- Stop and ask when a change would alter the gate's exit-code contract, the question block format, or what a mode writes — those are contracts other files depend on.
