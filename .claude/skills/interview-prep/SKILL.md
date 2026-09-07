---
name: interview-prep
description: Build interview preparation packs — generate a question guide from a CV project, produce the base question-and-answer packs for an interview (answering a client's question set when one exists, generating one when it does not), or extend an existing pack with new questions. Three chained modes (from-cv, answer, extend) whose prerequisites are enforced against files on disk, with optional weighting toward a client's candidate brief. Use when the user wants interview questions generated from a CV or system-design project, wants soft-skills/tech question files answered, or wants an existing interview set extended with further questions.
---

## Role

You produce interview preparation material — questions, answers, or both — from a CV project brief and its system design docs, or from an existing question set. Each mode defines its own persona; adopt the one in the mode file you load.

Output format and style are owned by `references/output-conventions.md`, not by this file and not by the mode files.

---

## Modes and how they chain

Each mode consumes what the previous step wrote to disk. The dependency is on **the artifacts**, never on "that skill was run earlier" — that is not knowable in a new session.

```
<project>/inputs.txt ──> /system-design ──> <project>/00-overview.md .. 06-security.md ──┐
                                                                                         ├──> from-cv ──> <project>/interview-questions.md
<project>/inputs.txt ────────────────────────────────────────────────────────────────────┘

<interview>/{soft-skills,tech}-questions.txt  (optional) ─┐
<interview>/candidate-profile.txt             (optional) ─┼──> answer ──> <interview>/{soft-skills,tech}-answers.md ──> extend ──> <interview>/{soft-skills,tech}-extra.md
<project>/inputs.txt                          (optional) ─┘
                              at least one of the three
```

| Mode | Argument | Requires on disk | Writes |
|---|---|---|---|
| `from-cv` | `<case>` | `<project>/inputs.txt`, and `00-overview.md`…`06-security.md` from `/system-design` | `<project>/interview-questions.md` |
| `answer` | `<case>` | at least one source: a `*-questions.txt`, a candidate profile, or the project brief | `<interview>/soft-skills-answers.md`, `<interview>/tech-answers.md` |
| `extend` | `<case>` | both `*-answers.md`; `<project>/interview-questions.md` when the case has a project | `<interview>/soft-skills-extra.md`, `<interview>/tech-extra.md` |

`extend`'s dependency on `from-cv` is **conditional**: it applies only when the case has a project brief to have generated a CV guide from. A case with an interview pack and no project is a supported shape.

---

The two `*-questions.txt` files are **optional**, and independent of each other. A client may supply one pack, both, or neither. Where a set exists, `answer` answers it; where none exists, `answer` generates that pack from the profile and the project brief, and the result is more generic by design. A file counts as a question set only if it actually holds questions — a stub like a lone `1` is non-empty but sources nothing, and the gate reports it as `PRESENT BUT HOLDS NO QUESTIONS`.

`answer` still needs **something** to work from. With no question set, no profile and no project it is BLOCKED, because the alternative is inventing an interview out of nothing.

`<interview>/candidate-profile.txt` is an **optional** client brief describing what the client wants in a candidate. It is rare, it never blocks, and when present it weights what every mode generates. The gate always reports whether it was found.

---

## The case folder

Every mode takes exactly one argument: a **case**. A case holds at most one project, and optionally one interview pack, at fixed relative paths:

| Path | Written by | Holds |
|---|---|---|
| `<case>/project` | `/system-design`, `from-cv` | `inputs.txt`, `00-overview.md`…`06-security.md`, `interview-questions.md` |
| `<case>/interview` | `answer`, `extend` | `candidate-profile.txt`, `*-questions.txt`, `*-answers.md`, `*-extra.md` |

Throughout this file and every mode file, `<project>` and `<interview>` mean those two paths. They are **derived from the case, never passed** — there is no companion argument to any mode.

Only the case folder itself has to exist. A case whose project side or interview pack is missing is an ordinary "not started yet" state, and the gate reports it BLOCKED with a runnable remedy — never as a malformed invocation. Create `<interview>/` if a mode needs to write there and it is absent.

Two cases are never related to each other. A new case is independent of every existing one even when its project covers similar ground, and nothing in this skill infers a link from folder numbering or from content resemblance.

---

## Step 0 — Parse the invocation

`$ARGUMENTS` is `<mode> <case>`.

`<mode>` is one of `from-cv`, `answer`, `extend`.

If no mode word is present, infer the likely mode from what the case already holds, state the inference, and **ask the user to confirm before doing anything else**. Never silently guess a mode — the three modes write different files to different places.

---

## Step 1 — Run the precondition gate

**Before reading any input file, before loading a mode file, run:**

```
.claude/skills/interview-prep/scripts/preflight.sh <mode> <case>
```

Dispatch on the **exit code**, not on the printed text:

| Exit | Meaning | What you do |
|---|---|---|
| `0` | READY | Continue to Step 2. |
| `1` | BLOCKED | **Stop.** Report the unsatisfied preconditions and the `to unblock:` remedy verbatim. Offer to run the remedy. Do not generate anything. |
| `2` | CANNOT-RUN | **Stop.** The invocation is malformed. Report the problem and ask for the correct arguments. |

Read the gate's `notes:` section either way. It reports every optional input: the candidate profile, each `*-questions.txt`, and the project brief. On any `PRESENT BUT EMPTY` or `PRESENT BUT UNUSABLE` verdict, say so to the user before generating — a file was put there deliberately, and producing an unweighted or ungrounded pack silently is the failure to avoid.

A BLOCKED result is not a hurdle to reason around. Generating output from missing prerequisites produces a guide grounded in nothing — the failure is silent and the result looks fine. If the user explicitly instructs you to proceed anyway, say plainly what will be missing from the result, then proceed.

---

## Step 2 — Load the conventions and the mode

Read both, in this order:

1. `references/output-conventions.md` — the question block, style rules, shared review checklist
2. the mode file — `references/mode-from-cv.md`, `references/mode-answer.md`, or `references/mode-extend.md`
3. `references/candidate-profile.md` — **only if** the gate reported the profile FOUND. It owns how the client brief reweights generation.

---

## Step 3 — Execute

Follow the mode file. It owns the inputs to read, the generation logic, the document header, and where to save.

---

## Step 4 — Review

Re-read every file you wrote and verify the shared checklist in `references/output-conventions.md` plus the mode-specific checks in the mode file.

Fix what fails. Report anything you could not fix rather than reporting done.
