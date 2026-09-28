# Output Conventions

Single owner for how every `interview-prep` output looks. All four modes load this file; none of them restate what is here.

---

## Question block

Every question — in every mode, in every output file — uses exactly this block:

```
---

### Q<number>. <Question text>

**Brief answer**
<1-2 sentences capturing the core idea. This is what you'd say in the first 15 seconds of your response.>

<details>
<summary><strong>Must cover</strong></summary>

<The checklist for this answer. See "Must cover" below.>

</details>

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
<summary><strong>Must cover</strong></summary>

<...>

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

<...>

</details>

#### Q3.2. <Sub-question text>

...
```

---

## Must cover

A collapsed checklist of what the answer has to contain, so a reader can test their own recall before opening the answer itself. It is **derived from the finished answer, never written before it** — a list written first produces an answer that reads back as a term checklist. The answer is authoritative: where the two disagree, the list is what gets corrected.

Entries are bold or plain, and the two carry different weight:

- **Bold — required.** The answer sounds incomplete without this. Two to eight per question. More than eight is a signal, not a quota to trim to: it usually means the answer covers two questions and wants splitting into sub-questions, or that the test was applied loosely. Re-examine the answer; never drop a required entry to make the count fit.
- **Plain — optional.** Carries a distinct idea the bold entries do not, and adds depth. At most seven, written as comma-separated runs rather than one bullet each.
- **Neither.** A contrast case named only as the thing you avoid, a variant of an entry already listed, and one item of an illustrative run earn no bullet. They are in the answer and stay there. A list that transcribes every term the answer touches is not a checklist.

A bold entry may carry a short clause where the bare term is ambiguous: one clause, about ten words, no "because" and no "so". Plain entries never carry one — an optional term that needs explaining is not optional. Where a term already has a footnote, its entry carries no clause: a footnote defines an unfamiliar concept, a clause says which aspect of a familiar term this answer turns on.

Entries appear in the order the detailed answer raises them.

**What an entry is** depends on the pack. Technical packs, and a project's own guides, list **terms** — the named concepts the answer turns on:

```
<details>
<summary><strong>Must cover</strong></summary>

- **event loop** — one blocking call stalls every request
- **connection pool** — summed across pods, under the database limit
- **expand/contract**
- selectinload, thread pool bound, asyncpg

</details>
```

Soft-skills packs list **beats** — the parts of the story the answer has to reach. A soft-skills answer has no technical vocabulary to check against, so the checklist tracks the narrative instead:

```
<details>
<summary><strong>Must cover</strong></summary>

- **the decision** — I escalated rather than absorbed it
- **the constraint** — two days to the release
- **the outcome** — review latency down to one day

</details>
```

The bounds, the clause rule and the derivation order are the same for both forms.

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

**Which files carry this:** `<interview>/tech-answers.md` and `<interview>/tech-extra.md`. The soft-skills files do not — soft-skills questions are not project-bound. A project's own guides — `interview-questions.md` and `resps-questions.md` — do not either: every question in them belongs to that project by construction.

---

## Language & style

1. **Abbreviations** — On first use, write the full term followed by the abbreviation in parentheses: "Object-Relational Mapping (ORM)", "Single Sign-On (SSO)". Use the abbreviation freely afterwards.

   Linking and hover text for abbreviations are owned by `.claude/glossary.md` and applied by `.claude/scripts/link-abbreviations.py` after the document is written. This rule and that file do not overlap: this rule governs the prose, the glossary governs the link.

   The linker skips the `Must cover` block, so an abbreviation's first use — and the expansion that goes with it — belongs in the prose, not in a checklist entry.

2. **Readability** — English prose follows `.claude/b2-lang-rules.md`, which owns every readability rule; read it in full before writing and do not restate it here. It governs the wording only: simplifying never drops a fact, a condition or a number, and a technical term the interview turns on stays, expanded rather than replaced.

3. **Tone** — Technical and precise, but conversational enough to reproduce in a live interview. Avoid academic phrasing ("it is worth noting that...", "one might argue..."). Prefer direct statements ("Use X when...", "The tradeoff is...").

4. **Depth** — Go beyond definitions. Real-world seniority, not textbook. Every detailed answer covers: *why* it matters, *when* to use or avoid it, *what goes wrong* when misapplied, and *how* it connects to the broader system.

5. **Complex concepts** — When an answer leans on a concept that needs a one-line clarifier, add a footnote block at the end of that question section:

   ```
   > **Footnotes:**
   > - **MRO (Method Resolution Order):** The algorithm Python uses to determine which method to call in a class hierarchy. Python uses C3 linearization.
   > - **CQRS:** Separates read and write models, allowing independent scaling and optimization of each path.
   ```

   Footnotes are optional — add them only when the concept genuinely benefits.

6. **Reproducibility** — Write as if the reader will use this to prepare for their own interview. Prioritize clarity and memorability over exhaustiveness.

7. **No decoration** — Don't add symbols, emoji, or badges that carry no meaning.

8. **Output language** — Prose is written in the language the gate's `language:` note names, `en` or `ru`, one per case. The gate owns how `<interview>/language.txt` is read and when it falls back to `en`. Russian prose has no readability file, because its reader is a native speaker; rules 3 and 4 apply to it unchanged.

   - **Fixed text stays in English.** Everything this file or a mode file gives as a literal template is copied as written: document titles and header notes, the `Brief answer`, `Must cover`, `Detailed answer` and `Footnotes` labels, the `Q<n>.` numbering, the `**Project:**` line and the `Questions by project` heading. The linker and this checklist match these strings, and a translated label stops matching without any error. A name a mode file offers as a choice rather than as text to copy — a topic from `from-resps`'s topic sequence — is not fixed text and is written in the case language, like section labels and pillar names.
   - **Quoted source text is copied as written.** A question from a client's `*-questions.txt` and a responsibility quoted from `inputs.txt` keep their own wording and language, because a translation changes what the source said. Quoted text is exempt from the one-form-per-concept rule below. Generated questions, answers, `Must cover` entries and footnotes are in the case language.
   - **Technical terms in Russian prose.** Product, library and protocol names and all abbreviations stay in Latin script. A concept with a Russian term in common engineering use takes that term (шардирование, идемпотентность, репликация); any other concept keeps its English term in Latin script. A document uses one form per concept throughout.
   - **Abbreviations expand in English**, as in «Object-Relational Mapping (ORM)». The linker recognises an expansion only in the glossary's wording, which is English.

---

## Review checklist (shared)

Every mode re-reads its own output and verifies:

- Detailed answers meet the 600-character minimum — **all** of them, not most
- No duplicate content between brief and detailed (brief = headline, detailed = substance)
- Both `<details>` blocks of every question — `Must cover` and `Detailed answer` — are opened and closed
- Every bold `Must cover` entry appears in that question's detailed answer, in the order the list gives. The same words in another grammatical form count: Russian changes word endings, so «один проход» appears as «одним проходом»
- Every `Must cover` list holds two to eight bold entries and at most seven plain ones, and no entry is an incidental mention — a contrast case, a variant of another entry, or one item of an illustrative run
- Abbreviations expanded on first use
- In English output, every sentence passes `.claude/b2-lang-rules.md` — checked against that file, not from memory
- Prose is in the language the gate reported, and every literal template string is in English exactly as given
- Every same-file link (`](#…)`) resolves to a heading — checked by `python3 .claude/scripts/check-anchors.py <file>`, never by eye
- Numbering is consistent and unbroken — in a project guide the `Q<n>` label is the difficulty level and repeats by design (see `tiers.md`)
- In an attributed file: every question carries a `**Project:**` line, every value names a real project folder or `general`, and the index at the top accounts for every question exactly once

Each mode file adds its own checks on top of these.
