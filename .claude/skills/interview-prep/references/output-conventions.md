# Output Conventions

Single owner for how every `interview-prep` output looks. All three modes load this file; none of them restate what is here.

---

## Question block

Every question — in every mode, in every output file — uses exactly this block:

```
---

### Q<number>. <Question text>

**Brief answer**
<1-2 sentences capturing the core idea. This is what you'd say in the first 15 seconds of your response.>

<details>
<summary><strong>Detailed answer</strong></summary>

<Comprehensive answer: focus on edge cases, trade-offs, failure modes, and "why" decisions. Minimum 600 characters. Use paragraphs, bullet points, or short lists where they improve clarity. Reference real patterns, tools, or practices — not abstract theory.>

</details>
```

## Sub-questions

When a question has sub-questions (`3.1`, `3.2`), nest them under the parent heading. The parent gets a heading only — no answer block of its own:

```
---

### Q3. <Parent question text>

#### Q3.1. <Sub-question text>

**Brief answer**
<...>

<details>
<summary><strong>Detailed answer</strong></summary>

<...>

</details>

#### Q3.2. <Sub-question text>

...
```

---

## Project attribution

A case may hold several CV projects, and a client's question bank mixes questions tied to one of them, questions spanning several, and questions tied to none. Attribution is carried per question, and the document is **never reordered into project groups** — question order and numbering always follow the source question file, which is the order the interviewer has in front of them.

Every question in an attributed file carries a `**Project:**` line between the heading and the brief answer:

```
---

### Q5. <Question text>

**Project:** iot-telemetry

**Brief answer**
<...>
```

The value is one or more project folder names, or `general` when the question is not tied to any project. Name several when a question genuinely spans them — a tag is an attribution, not a partition, so nothing is forced into a single bucket and nothing is dropped for fitting none.

The document then opens with an index, directly under the header notes, giving the per-project view without moving anything:

```
## Questions by project

- **cancer-support-platform** — Q1, Q2, Q3, Q6, Q7
- **iot-telemetry** — Q5, Q8.2, Q9
- **general** — Q4.1–Q4.6, Q11, Q12
```

**Which files carry this:** `<interview>/tech-answers.md` and `<interview>/tech-extra.md`. The soft-skills files do not — soft-skills questions are not project-bound. A project's own `interview-questions.md` does not either: every question in it belongs to that project by construction.

---

## Language & style

1. **Abbreviations** — On first use, write the full term followed by the abbreviation in parentheses: "Object-Relational Mapping (ORM)", "Single Sign-On (SSO)". Use the abbreviation freely afterwards.

2. **Tone** — Technical and precise, but conversational enough to reproduce in a live interview. Avoid academic phrasing ("it is worth noting that...", "one might argue..."). Prefer direct statements ("Use X when...", "The tradeoff is...").

3. **Depth** — Go beyond definitions. Real-world seniority, not textbook. Every detailed answer covers: *why* it matters, *when* to use or avoid it, *what goes wrong* when misapplied, and *how* it connects to the broader system.

4. **Complex concepts** — When an answer leans on a concept that needs a one-line clarifier, add a footnote block at the end of that question section:

   ```
   > **Footnotes:**
   > - **MRO (Method Resolution Order):** The algorithm Python uses to determine which method to call in a class hierarchy. Python uses C3 linearization.
   > - **CQRS:** Separates read and write models, allowing independent scaling and optimization of each path.
   ```

   Footnotes are optional — add them only when the concept genuinely benefits.

5. **Reproducibility** — Write as if the reader will use this to prepare for their own interview. Prioritize clarity and memorability over exhaustiveness.

6. **No decoration** — Don't add symbols, emoji, or badges that carry no meaning.

---

## Review checklist (shared)

Every mode re-reads its own output and verifies:

- Detailed answers meet the 600-character minimum — **all** of them, not most
- No duplicate content between brief and detailed (brief = headline, detailed = substance)
- Every `<details>` block is opened and closed
- Abbreviations expanded on first use
- Numbering is consistent and unbroken
- In an attributed file: every question carries a `**Project:**` line, every value names a real project folder or `general`, and the index at the top accounts for every question exactly once

Each mode file adds its own checks on top of these.
