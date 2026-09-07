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
inputs.txt ──> /system-design ──> 00-overview.md .. 06-security.md ──┐
                                                                     ├──> from-cv ──> interview-questions.md
inputs.txt ──────────────────────────────────────────────────────────┘

{soft-skills,tech}-questions.txt  (optional) ─┐
candidate-profile.txt             (optional) ─┼──> answer ──> {soft-skills,tech}-answers.md ──> extend ──> {soft-skills,tech}-extra.md
<project>/inputs.txt              (optional) ─┘
                    at least one of the three
```

| Mode | Argument(s) | Requires on disk | Writes |
|---|---|---|---|
| `from-cv` | `<project>` `[<interview>]` | `inputs.txt`, and `00-overview.md`…`06-security.md` from `/system-design` | `<project>/interview-questions.md` |
| `answer` | `<interview>` `[<project>]` | at least one source: a `*-questions.txt`, a profile, or a project brief | `<interview>/soft-skills-answers.md`, `tech-answers.md` |
| `extend` | `<interview>` `[<project>]` | both `*-answers.md`; `<project>/interview-questions.md` if a project is given | `<interview>/soft-skills-extra.md`, `tech-extra.md` |

`extend`'s dependency on `from-cv` is **conditional**: it applies only when a project folder is passed. An interview folder with no associated project is a supported case.

Each mode takes its **primary folder first** — the one it writes into — and an optional companion folder second. For `from-cv` the companion is an interview folder; for `answer` and `extend` it is a project folder.

The two `*-questions.txt` files are **optional**, and independent of each other. A client may supply one pack, both, or neither. Where a set exists, `answer` answers it; where none exists, `answer` generates that pack from the profile and the project brief, and the result is more generic by design. A file counts as a question set only if it actually holds questions — a stub like a lone `1` is non-empty but sources nothing, and the gate reports it as `PRESENT BUT HOLDS NO QUESTIONS`.

`answer` still needs **something** to work from. With no question set, no profile and no project it is BLOCKED, because the alternative is inventing an interview out of nothing.

`<interview>/candidate-profile.txt` is an **optional** client brief describing what the client wants in a candidate. It is rare, it never blocks, and when present it weights what every mode generates. The gate always reports whether it was found.

---

## Step 0 — Parse the invocation

`$ARGUMENTS` is `<mode> <path> [<companion-path>]`.

`<mode>` is one of `from-cv`, `answer`, `extend`.

If no mode word is present, infer the likely mode from the paths given, state the inference, and **ask the user to confirm before doing anything else**. Never silently guess a mode — the three modes write different files to different folders.

---

## Step 1 — Run the precondition gate

**Before reading any input file, before loading a mode file, run:**

```
.claude/skills/interview-prep/scripts/preflight.sh <mode> <path> [<companion-path>]
```

Dispatch on the **exit code**, not on the printed text:

| Exit | Meaning | What you do |
|---|---|---|
| `0` | READY | Continue to Step 2. |
| `1` | BLOCKED | **Stop.** Report the unsatisfied preconditions and the `to unblock:` remedy verbatim. Offer to run the remedy. Do not generate anything. |
| `2` | CANNOT-RUN | **Stop.** The invocation is malformed. Report the problem and ask for the correct arguments. |

Read the gate's `notes:` section either way. It reports the candidate profile as `FOUND`, `ABSENT`, `PRESENT BUT EMPTY` or `PRESENT BUT UNUSABLE`. On the two unusable verdicts, say so to the user before generating — a file was put there deliberately and producing an unweighted pack silently is the failure to avoid.

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
