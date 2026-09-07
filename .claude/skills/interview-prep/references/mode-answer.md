# Mode: answer

Produce the base question-and-answer pack for an interview folder. Each of the two packs is either **sourced** — answering a question set the client actually gave — or **generated**, when no such set exists.

**Persona:** Senior Software Engineer preparing structured, reproducible interview answers. Technical but clear — anyone with a solid engineering background follows the reasoning without re-reading.

**Arguments:** `<interview>` — the interview folder. `<project>` — optional.

---

## Step 1 — Read the inputs

- `<interview>/soft-skills-questions.txt` and `<interview>/tech-questions.txt` — **optional.** The gate reports each one as `SOURCED`, `ABSENT`, or `PRESENT BUT HOLDS NO QUESTIONS`.
- `<interview>/candidate-profile.txt`, when the gate reported it FOUND — the client's brief on what they want in a candidate. Load `candidate-profile.md` and follow it; it owns the weighting.
- `<project>/inputs.txt`, when a project folder was given — high-level context (description, stack, responsibilities) to ground answers in concrete experience. Reference the project where it fits naturally; do not force it into every answer.

The two packs are decided **independently**. It is normal for one to be sourced and the other generated — a client often shares their soft-skills questions and nothing else.

When the gate reports a file as `PRESENT BUT HOLDS NO QUESTIONS`, say so to the user before generating. A placeholder like a lone `1` means someone intended to paste a set and has not yet.

---

## Step 2a — Sourced pack

Parse the question file line by line. Client files are hand-maintained and mix several shapes, so handle all of them:

- **Numbered lines** (`1`, `2`, `3.1`) are question identifiers. Consecutive lines sharing a top-level number (`3`, `3.1`, `3.2`) form one group — the sub-numbered lines are sub-questions within it.
- **Bulleted lines** (`•`, `-`, `*`) are questions too. Number them yourself, continuing the file's sequence.
- **A short unmarked line** that introduces the questions below it (`Django`, `SQLAlchemy`, `General`) is a **topic heading**, not a question. Keep it as the grouping for the questions that follow.
- **`Possible answer:` lines** are draft answers someone already sketched, not questions. Treat each as raw material for the question above it: use what is right, correct what is wrong, and expand it to the depth `output-conventions.md` requires. Never emit one verbatim as the finished answer, and never mistake one for a question.

Preserve the source numbering exactly — do not renumber, merge or reorder. Answer every question; skip nothing.

A client profile adds no questions to a sourced pack — the file fixes the set. It steers **emphasis** only, per Step 3.

---

## Step 2b — Generated pack

No question set exists for this pack, so write one and answer it. The result is deliberately more general than a sourced pack: it covers what an interviewer in this situation would most likely ask, rather than what one demonstrably did ask.

Draw the questions from whatever sources the gate confirmed, in this order of authority:

1. **The candidate profile**, when present. It is the strongest available signal — the client has stated their must-haves, their pain points, and the working culture they expect. Follow `candidate-profile.md`; in a generated pack it drives the question set outright rather than merely reweighting it.
2. **The project brief and any design docs** in `<project>/`, when a project folder was given — the candidate's real stack, responsibilities and architecture, which is what an interviewer would actually probe.
3. **The other pack's question file**, when that one was sourced. A real client set reveals this interviewer's register, depth and phrasing; match it so the two packs read as one interview.

Shape:

- Group by topic area and order easier to harder within each area.
- At least 10 questions per pack. Cover every hard must-have from the profile at least once.
- Number sequentially from 1. Use sub-numbering only where a question genuinely splits.
- Soft-skills pack: turn each named working practice or cultural expectation into a concrete scenario question. Technical pack: cover the named stack and, above all, the named pain points.

Never present a generated question as one the client asked. The header note in Step 3 is what keeps that distinction visible.

---

## Step 3 — Write the two documents

`<interview>/soft-skills-answers.md`:

```
# Soft Skills — Interview Answers
```

`<interview>/tech-answers.md`:

```
# Technical — Interview Answers
```

Directly under the heading, record how the pack was built — this is what tells a later reader, and `extend`, which kind of artifact they are holding:

```
> Questions supplied by the client.
```
```
> Questions generated — no client question set was available.
```

Add the profile weighting note from `candidate-profile.md` on its own line when a profile was used.

Every question uses the block from `output-conventions.md`; sub-questions use the nested form there.

Whichever branch produced the questions, the answers obey the same honesty rule: foreground the experience that overlaps what the client asked for, mirror their stated working practices where the answer touches on them, and answer in the register they described. Where the source material shows no such experience, answer honestly about what is adjacent; never claim experience `inputs.txt` does not support.

---

## Review — in addition to the shared checklist

- **Sourced packs:** every question from the file is covered, no skipped lines, and numbering matches the original exactly including sub-questions.
- **Generated packs:** at least 10 questions, grouped by topic, easier to harder; every hard must-have from the profile is targeted at least once.
- Each file's header states whether its questions were supplied or generated, and the two packs are labelled independently.
- When a profile was used: no answer claims experience the source material does not support, and the header carries the weighting note.
