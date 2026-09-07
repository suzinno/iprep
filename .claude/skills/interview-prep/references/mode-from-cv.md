# Mode: from-cv

Generate a full interview guide — questions *and* answers — from a CV brief and the system design docs for that project.

**Persona:** Principal Software Engineer & Technical Architect, 20+ years. Expertise: backend development, monolithic and distributed systems, reliability, scalability and high-availability infrastructure, system design, data processing pipelines / ETL.

**Arguments:** `<project>` — one `<case>/projects/<name>` folder. This mode runs per project. `<interview>` below is that project's case-level interview folder, which the gate resolves and reports.

---

## Step 1 — Read the inputs

1. `<project>/inputs.txt` — the CV text. Title, Description, Environment, Responsibilities.
2. The design docs in `<project>/` — `00-overview.md` through `06-security.md`. These hold the architecture decisions, data models, reliability patterns and security posture that must drive how specific and how deep the generated questions and answers are.
3. `<interview>/candidate-profile.txt`, when the gate reported it FOUND — the client's brief on what they want in a candidate. Load `candidate-profile.md` and follow it; it owns the weighting.

The design docs are not background reading. An answer that could have been written without them has failed this mode.

---

## Step 2 — Identify the expertise

1. The primary industry niche (FinTech, e-commerce, EdTech, …).
2. The 5-8 strongest technical pillars. Derive pillars primarily from **Responsibilities** — each one describes a real activity the person performed, so they must be able to demonstrate deep knowledge of the underlying concepts, the alternatives, and the trade-offs. Group related responsibilities into one pillar (several database responsibilities → a single "Database Engineering" pillar).

---

## Step 3 — Generate the guide

The guide **verifies the person can back up every responsibility listed on their CV**. Questions probe whether the candidate actually did the work — not whether they know the vocabulary.

Three difficulty levels per pillar:

- **Q1 — Basic / filtering.** Baseline professional knowledge. Does the candidate understand the foundational concepts behind their stated responsibilities?
- **Q2 — Deep dive.** Implementation details, failure modes, gotchas. Specific decisions, alternatives considered, problems hit — the detail only someone who did the work has.
- **Q3 — Architectural.** Trade-offs, system-wide impact, scale. How a responsibility connects to the wider system, what changes at 10x, what they'd do differently.

Rules:

- Every pillar has questions at every level — up to 5 per level.
- Q3 questions should target the **intersection** of tools (e.g. how tool A behaves when database B fails), not one tool in isolation.
- **Responsibility coverage:** every responsibility in `inputs.txt` is targeted by at least one question somewhere in the guide.
- **When a client profile is in play,** weight pillars toward its must-haves and named pain points, and push those toward Q2 and Q3. Responsibility coverage still holds in full — the profile changes proportion, never scope.
- **Ground the answers in this project.** Reference the actual architecture, tech choices and data models from the design docs. Answers read as the candidate describing *their* system, not reciting generic knowledge.

---

## Step 4 — Assemble the document

Header:

```
# Interview Questions — <Project Title>
> Auto-generated from CV and system design documents. Questions target stated responsibilities and technical pillars.

## Table of Contents
- [<Pillar Name>](#pillar-name)
- [<Pillar Name>](#pillar-name-1)
...
```

Then one `## <Pillar Name>` section per pillar. Within a pillar, order questions by level — all Q1s, then Q2s, then Q3s. Use the Q1/Q2/Q3 labels to carry difficulty; do not also write "easy/medium/hard".

Question blocks follow `output-conventions.md`.

---

## Step 5 — Save

Write to `<project>/interview-questions.md`.

---

## Review — in addition to the shared checklist

- **Responsibility coverage** — walk `inputs.txt` responsibility by responsibility and name the question that targets each. List any gaps and fill them.
- Every pillar has a `## <Pillar Name>` heading, and its questions run Q1 → Q2 → Q3.
- Every Table of Contents link resolves to a real heading anchor in the file.
- Answers reference this project's specifics, not textbook generalities.
- When a profile was used: every hard must-have in it is targeted by at least one question, the named pain points are targeted at Q2 or Q3, and the header carries the weighting note.
