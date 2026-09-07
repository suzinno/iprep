# Mode: extend

Generate additional questions that read as a natural continuation of an existing interview — as if the same interviewer decided to go deeper or wider on the same topics — and answer them.

**Persona:** Senior Software Engineer and experienced technical interviewer.

**Arguments:** `<case>` — the case folder. `<project>` and `<interview>` below are its two sides, as `SKILL.md` defines them; neither is passed separately.

---

## Step 1 — Read the inputs

- `<interview>/soft-skills-questions.txt`, `<interview>/tech-questions.txt` — the original set, **optional.** The gate reports each as `SOURCED`, `ABSENT` or `PRESENT BUT HOLDS NO QUESTIONS`. When a pack has no originals, the base answers below carry the questions and are the only source for Step 2.
- `<interview>/soft-skills-answers.md`, `<interview>/tech-answers.md` — **what the base pack already covers.** A new question is a duplicate if the existing *answers* already cover its substance, even when no original question asks it in those words. Checking the question list alone is not enough.
- `<interview>/candidate-profile.txt`, when the gate reported it FOUND — the client's brief on what they want in a candidate. Load `candidate-profile.md` and follow it; it owns the weighting.
- `<project>/inputs.txt` and `<project>/interview-questions.md`, when the gate reported the project brief `SOURCED` — the CV guide is a second body of covered ground to avoid re-asking, and the brief tailors new questions toward what the candidate would realistically face.

---

## Step 2 — Analyze the original set

Analyse the original question file when there is one. When there is not, analyse the base answers pack instead — it contains the questions, and its header says whether they were supplied by the client or generated.

If that header says the base questions were **generated**, there is no real interviewer whose style you are continuing. Say nothing about matching an interviewer; aim instead for the coverage a thorough interviewer would add — breadth across untouched topics and depth on the ones that matter most to the client.

For each pack, identify:

1. **Topics covered** — the themes, tools and concepts the interviewer focuses on
2. **Interviewer style** — how questions are phrased: scenario-based, direct, follow-up chains, opinion-seeking
3. **Depth pattern** — broad-then-drill-down? trade-offs? real experience vs theory?
4. **Gaps** — what a thorough interviewer would logically explore next within those same topics, but didn't ask
5. **Client gaps**, when a profile is in play — every must-have and named pain point in the brief that the original set never probed. These are the most valuable gaps in the document: the client said it matters and nobody has asked about it yet.

---

## Step 3 — Generate

- **5-7 new questions per topic area** identified in Step 2. Not fewer.
- They must sound like the **same interviewer** — match the phrasing, depth expectation and scenario framing of the originals.
- **No duplicates or near-duplicates.** Cross-check every generated question against the original questions, the base answers, and the CV guide when present. Different angle, aspect or scenario each time.
- **Complement, don't repeat** — fill gaps, go deeper into what was touched on, or explore adjacent concerns the interviewer would logically care about.
- **When a client profile is in play,** the client gaps from Step 2 come first, and the brief's must-haves and pain points take a clearly larger share than untargeted topics. The per-topic-area minimum still holds.
- Sub-questions are allowed where the original set uses them and they add real value. Don't force them.
- **Numbering continues from where the base pack left off.** If the questions end at 7 — in the original file, or in the answers pack when there is no original — the extra set starts at 8.

Answer every generated question using the block in `output-conventions.md`.

---

## Step 4 — Save

`<interview>/soft-skills-extra.md`:

```
# Soft Skills — Extended Questions & Answers
> Generated as a continuation of the original question set. Same interviewer style, new angles.
```

`<interview>/tech-extra.md`:

```
# Technical — Extended Questions & Answers
> Generated as a continuation of the original question set. Same interviewer style, new angles.
```

---

## Review — in addition to the shared checklist

- No generated question duplicates or closely mirrors an original question, anything the base answers already cover, or anything in the CV guide when one was read.
- Each topic area from the base pack — the originals, or the answers pack when there are no originals — has 5-7 new questions.
- Numbering continues cleanly from the original set.
- The style genuinely matches the original interviewer's approach, or, when the base questions were generated, the set adds real coverage rather than claiming a style it cannot know.
- When a profile was used: every client gap identified in Step 2 is now covered, and the header carries the weighting note.
