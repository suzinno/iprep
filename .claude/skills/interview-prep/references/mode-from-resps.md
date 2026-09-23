# Mode: from-resps

Generate an interview guide — questions *and* answers — for an interviewer who has seen only the CV. The questions come from the CV brief alone; the answers draw on the system design docs. A guide whose questions may name what the design docs hold is `from-design`.

**Persona:** two roles, kept apart. The questions are written by a senior technical interviewer who holds only the CV — the description, the environment list and the responsibilities — and knows the listed technologies well. The answers are written as the candidate, a Principal Software Engineer describing the system they built.

**Arguments:** `<project>` — one `<case>/projects/<name>` folder. This mode runs per project. `<interview>` below is that project's case-level interview folder, which the gate resolves and reports.

---

## Step 1 — Read the inputs

1. `<project>/inputs.txt` — the CV text. Title, Description, Environment, Responsibilities. It is the **only** source for questions.
2. The design docs in `<project>/` — `00-overview.md` through `06-security.md`. They are the source for **answers only**. Read them, but never take a question from them.
3. `<interview>/candidate-profile.txt`, when the gate reported it FOUND — the client's brief on what they want in a candidate. Load `candidate-profile.md` and follow it; it owns the weighting.

---

## Step 2 — Map the responsibilities

For each responsibility in `inputs.txt`, settle three things before writing any question:

1. **Its topic** — one from the sequence below. A responsibility that spans two topics goes under its main one. It is never split and never listed twice.
2. **Its technologies** — the ones it names, and the ones it implies. A technology is implied when it is the standard companion of one the responsibility names or the Environment line lists: "indexing in PostgreSQL" implies query plans and index types. A tool the brief never mentions appears only as an alternative the candidate may have weighed, never as one they used.
3. **Its weight** — how much an interviewer could fairly ask about it. It sets the question count in Step 3.

Topic sequence:

1. Architecture and service design
2. APIs and integration
3. Databases and data modelling
4. Messaging and asynchronous processing
5. Search, data and AI pipelines
6. Security, identity and secrets
7. Cloud infrastructure, containers and infrastructure as code
8. Continuous integration and delivery
9. Performance and caching
10. Testing, observability and documentation

Skip topics the CV does not cover. Within a topic, responsibilities keep their order from the CV.

---

## Step 3 — Generate the guide

The guide **verifies the person can back up each responsibility in front of an interviewer who knows only the CV**. Questions probe whether the candidate actually did the work — not whether they know the vocabulary.

**What a question may contain.** Only what `inputs.txt` states, plus general knowledge of the technologies it names or implies. Never a service, endpoint, table, queue, component, figure or decision that appears only in the design docs. The test for every question: could an interviewer holding only the CV have written it? Questions ask the candidate to supply the specifics — "which indexes did you add, and why?" — rather than naming them for the candidate.

**How many questions.** The difficulty levels are defined in `tiers.md`. Each responsibility gets one to three questions, scaled to its weight: one for a thin responsibility, two for a typical one, three for a rich one. Three is a hard cap, and every answer block counts toward it, so a sub-question counts as one. Spread a responsibility's questions across levels rather than stacking them at one; a responsibility with three questions has one at each level.

**When a client profile is in play,** weight as `candidate-profile.md` sets out, inside the cap: a matching responsibility can rise to three questions, never past three and never below one.

**No repeats.** Where two responsibilities share ground, split it between their sections rather than asking the same question twice.

**Ground the answers in this project.** The brief answer, the `Must cover` list and the detailed answer draw on the design docs: the actual architecture, tech choices and data models. They read as the candidate describing *their* system, not reciting generic knowledge. Where the design docs do not cover what a question asks, the answer says honestly what the candidate did that is closest to it — never a specific the brief and the docs do not support.

---

## Step 4 — Assemble the document

Header:

```
# Responsibility Questions — <Project Title>
> Auto-generated from the CV brief. Questions use only what the CV states; answers draw on the system design documents.

## Table of Contents
- [R1. <Topic> — <Short label>](#r1-topic--short-label)
- [R2. <Topic> — <Short label>](#r2-topic--short-label)
...
```

Then one section per responsibility, in topic order and numbered in that order:

```
## R<n>. <Topic> — <Short label>

> <The responsibility's text from inputs.txt, without its bullet marker>
```

The topic in the heading is a short form of its name in the sequence ("Databases", "Messaging"). The short label names the responsibility in a few words.

Label and order each section's questions as `tiers.md` sets out. Question blocks follow `output-conventions.md`.

---

## Step 5 — Save

Write to `<project>/resps-questions.md`.

---

## Review — in addition to the shared checklist

- **Responsibility coverage** — walk `inputs.txt` responsibility by responsibility and name the section that holds each. Every responsibility has exactly one section.
- **Order** — sections follow the topic sequence, responsibilities within a topic keep their CV order, and `R<n>` numbering is unbroken.
- **Count** — every section holds one to three answer blocks, spread across levels, and a section with three has one at each level.
- **Knowledge boundary** — for every question heading, list each specific name it uses (tools, components, figures) and confirm it appears in `inputs.txt` or belongs to a technology the brief names or implies. Rewrite every question that fails. This applies to the question headings only; answers may name what the design docs hold.
- Answers reference this project's design, not textbook generalities, and claim nothing the brief and the design docs do not support.
- Every Table of Contents link resolves to a real heading anchor in the file.
- When a profile was used: the header carries the weighting note, and each hard must-have the brief names or implies is targeted by at least one question. Report any must-have the brief never mentions — this guide cannot ask about it.
