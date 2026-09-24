# Difficulty Tiers

Single owner for the difficulty levels in a project guide. `from-design` and `from-resps` both load this file; each mode file owns only how many questions it asks and how it groups them.

---

## The three levels

- **Q1 — Basic / filtering.** Baseline professional knowledge. Does the candidate understand the foundational concepts behind their stated responsibilities?
- **Q2 — Deep dive.** Implementation details, failure modes, gotchas. Specific decisions, alternatives considered, problems hit — the detail only someone who did the work has.
- **Q3 — Architectural.** Trade-offs, system-wide impact, scale. How a responsibility connects to the wider system, what changes at 10x, what they'd do differently.

Q3 questions target the **intersection** of tools (e.g. how tool A behaves when database B fails), not one tool in isolation.

---

## Labels and order

In a project guide, the number in a question heading is its level, not a sequence number: every `### Q2.` in a guide is a deep-dive question, and the label repeats from section to section. Use the Q1/Q2/Q3 labels to carry difficulty; do not also write "easy/medium/hard".

Within a section, order questions by level — all Q1s, then Q2s, then Q3s.
