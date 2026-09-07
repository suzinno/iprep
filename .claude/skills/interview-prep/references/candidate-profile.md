# Candidate profile — optional client brief

Single owner for how a client's candidate brief changes what the modes generate. All three modes load this file **only when the gate reports the profile FOUND**.

---

## What it is

`<interview>/candidate-profile.txt` is a brief written by the client or the vendor describing **what they want in a candidate** for a specific role. It is not a CV and not a project description: `inputs.txt` says what the candidate did, the profile says what the client is looking for.

It is optional and rare. Most interview folders have none, and the gate reports `candidate profile: ABSENT` — generate normally in that case and do not mention it.

If the gate reports it PRESENT BUT EMPTY or PRESENT BUT UNUSABLE, tell the user before generating anything. Someone put a file there on purpose; silently producing an unweighted pack is the failure to avoid.

---

## Step 1 — Read it into four buckets

The brief mixes hard requirements with culture. Sort every statement into one of these before generating, because they drive different question types:

1. **Hard technical must-haves** — named technologies, versions, scale figures, and the specific way the client uses them. Phrases like "is a must", "required", "essential", "expert in".
2. **Named pain points** — incidents, bottlenecks and failures the client volunteers about their own system. These are the single highest-value source in the document; see Step 2.
3. **Working practices** — how work actually arrives and moves: requirement quality, estimation culture, review gates, tooling policy, pipeline realities.
4. **Soft and cultural constraints** — team dynamics, politics, communication norms, the pace the client expects.

Anything flagged "will be an advantage" / "nice to have" is a fifth, lower-weight bucket: worth one or two questions, never a pillar.

---

## Step 2 — Mine the named pain points first

When a client volunteers that something broke, they are telling you what they will ask about. A line like "millions of attribute updates previously caused memory overloads and crashed production" is not background — it is next week's interview question, and it names the exact failure mode the candidate must be able to reason about.

For each pain point, generate questions that make the candidate: diagnose the failure, name the mechanism behind it, propose the mitigation, and say how they would detect it earlier next time. Pair the pain point with the specific tool the client named, not with the generic category.

Watch for **unusual qualifiers** and target them directly, because they are the ones a generic question set always misses — an explicitly *synchronous* framework under heavy load, a non-mainstream database, a coverage number that gates merges, a pipeline slow enough to change how someone works.

---

## Step 3 — Weight the generation

When no client question set exists and a pack is being generated from scratch, the profile stops being a reweighting input and becomes the **primary source** for what to ask. Everything below still applies; it simply drives the whole set rather than a share of it.

The profile shifts **emphasis and proportion**. It never replaces a mode's own coverage obligation: `from-cv` still covers every responsibility, `answer` still answers every source question, `extend` still covers every original topic area.

- Give the hard must-haves and pain points a **clearly larger share** of questions than untargeted topics — roughly half of the technical pack when the brief is as specific as this one.
- Cover **every** hard must-have at least once. List them and check them off; a "must" the pack never asks about is a gap.
- Push the client's must-haves toward the harder levels. If the brief says deep expertise is required, the Q1 question about that tool is not enough on its own.
- Turn working practices and cultural constraints into **scenario questions** for the soft-skills pack, one per named situation — vague requirements, blown estimates, review disagreements, tooling policy, the client's stated pace.
- Leave the rest of the pack intact. A profile-weighted set is still a complete set, not a narrow one.

---

## Step 4 — Two guards

**Do not fabricate fit.** The profile says what the client wants; `inputs.txt` and the design docs say what the candidate actually did. Where they overlap, foreground the overlap. Where they do not, write a question that lets the candidate speak honestly about adjacent experience — never an answer claiming experience the source material does not support. The pack is preparation, not a script for pretending.

**Keep scenarios neutral.** Briefs are candid about client dysfunction and may name internal friction, politics, or individuals. Generate the question as a neutral situation the candidate might face; do not quote the brief's characterisation of the client's own staff into a document the candidate may share or read aloud.

---

## Step 5 — Say that it was applied

When a profile was used, note it under the document header so the reader knows the pack is role-weighted rather than generic:

```
> Weighted toward the client brief in `candidate-profile.txt`.
```
