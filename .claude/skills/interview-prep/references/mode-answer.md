# Mode: answer

Produce the base question-and-answer pack for a case. Each of the two packs is either **sourced** — answering a question set the client actually gave — or **generated**, when no such set exists.

**Persona:** Senior Software Engineer preparing structured, reproducible interview answers. Technical but clear — anyone with a solid engineering background follows the reasoning without re-reading.

**Arguments:** `<case>` — the case folder. `<interview>` below is `<case>/interview`; `<project>` stands for any one of the `<case>/projects/<name>` folders, and this mode reads **all** of them.

---

## Step 1 — Read the inputs

- `<interview>/soft-skills-questions.txt` and `<interview>/tech-questions.txt` — **optional.** The gate reports each one as `SOURCED`, `ABSENT`, or `PRESENT BUT HOLDS NO QUESTIONS`.
- `<interview>/candidate-profile.txt`, when the gate reported it FOUND — the client's brief on what they want in a candidate. Load `candidate-profile.md` and follow it; it owns the weighting.
- `<project>/inputs.txt` **and** `<project>/00-overview.md` through `06-security.md`, for **every** project the gate reported as `SOURCED`. The brief gives description, stack and responsibilities; the design docs give the architecture, data models, failure modes and trade-offs. Both are required — the gate blocks without the docs. The pack is common to the whole case, so it must span every project in it. Reference a project where it fits naturally; do not force one into every answer.

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
2. **Every sourced project's brief and design docs** — the candidate's real stack, responsibilities and architecture across the whole case, which is what an interviewer would actually probe. Cover each project's stack; a generated pack that draws on only one of several projects has failed this mode.
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

Every question uses the block from `output-conventions.md`; sub-questions use the nested form there. `tech-answers.md` is an **attributed** file — follow the project attribution section in `output-conventions.md`, which owns the `**Project:**` line and the index. `soft-skills-answers.md` is not attributed.

Whichever branch produced the questions, every answer that touches a project is **bound to that project's design docs** — the actual services, data models, queues and failure modes, not the stack list. An answer that could have been written from `inputs.txt` alone has failed this mode.

Whichever branch produced the questions, the answers obey the same honesty rule: foreground the experience that overlaps what the client asked for, mirror their stated working practices where the answer touches on them, and answer in the register they described. Where the source material shows no such experience, answer honestly about what is adjacent; never claim experience `inputs.txt` does not support.

---

## Review — in addition to the shared checklist

- **Sourced packs:** every question from the file is covered, no skipped lines, and numbering matches the original exactly including sub-questions.
- **Generated packs:** at least 10 questions, grouped by topic, easier to harder; every hard must-have from the profile is targeted at least once.
- Each file's header states whether its questions were supplied or generated, and the two packs are labelled independently.
- Every project the gate reported as `SOURCED` is drawn on somewhere in the technical pack, and its questions are attributed to it.
- Answers grounded in a project cite something only its design docs contain — a service, a data model, a failure mode — not merely a technology from its Environment line.
- When a profile was used: no answer claims experience the source material does not support, and the header carries the weighting note.
