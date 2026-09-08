# Abbreviation Glossary and Link Enrichment

**Status:** implemented on this branch
**Scope:** a generation convention inherited by every case, plus a one-time back-fill of case 02
**Branch:** `docs/case-02-interview-packs`

---

## Problem

Generated documents under `cases/` are dense with abbreviations — `SCIM`, `APIM`, `RLS`, `PITR`, `DPIA` — that a reader either already knows or must leave the document to look up. Measured across the 16 generated documents of case 02: **110 distinct abbreviations** in prose, the top ten appearing between 16 and 61 times each.

Two rules already touch this and neither solves it:

- `output-conventions.md` Language & style rule 1 requires the full term on first use — but it governs `interview-prep` output only.
- `system-design`, which produces the documents holding the bulk of these abbreviations, has **no abbreviation rule at all**.

There is no owner spanning both skills, so the same abbreviation is expanded, footnoted, or left bare depending on which skill emitted the paragraph.

## Goal

On GitHub's rendered view, the first use of an abbreviation in a document is a link: clicking opens the official source, hovering shows what the term stands for and what it is for. The facts behind that link have exactly one owner and are applied mechanically, not restated per document.

Reading surface is GitHub web. Tooltips are therefore load-bearing and the design may rely on them.

## Non-goals

- Linking every occurrence. First eligible occurrence per document only.
- Forcing links to open in a new tab. GitHub's HTML sanitiser strips `target` on anchors and Markdown has no syntax for it. Readers ctrl/cmd-click. There is no workaround; this is accepted, not deferred.
- Tooltips on touch devices or in non-GitHub renderers. Out of reach of any Markdown-level design.
- Enriching case 01. Explicitly out of scope, which also keeps clear of its pre-skill leftovers.
- Rewriting `output-conventions.md` rule 1. It survives unchanged.

---

## Design

### 1. The owner artifact

`.claude/glossary.md` is the single owner of every abbreviation fact. It holds three sections.

**Section A — a short statement of the convention itself.** This is the part that spans both skills. Neither `output-conventions.md` nor `system-design/SKILL.md` restates it; each cites this file in one line. Without this, the convention would have to be written twice, which is the duplication defect the repository already names.

**Section B — linked terms**, one table:

| Column | Content |
|---|---|
| `Term` | The literal token as it appears in prose, e.g. `SCIM`, `AES-256`, `PostgreSQL` |
| `Expansion` | What it stands for, e.g. `System for Cross-domain Identity Management` |
| `Purpose` | One sentence on what it is used for |
| `Source` | Official URL, e.g. `https://scim.cloud/` |

**Section C — deliberately not linked**, one table of `Term` and `Reason`. Holds the universally-known tokens (`CPU`, `GB`, `ID`, `UI`, `DB`, `IP`) and the pattern false positives (SQL keywords and Mermaid node identifiers such as `PATIENT`, `CAT`, `MG`, `CEL`).

Section C is not decoration. Without it the checker re-raises the same tokens on every run and the decision to skip them stays an unrecorded judgement call. This mirrors the repository's existing principle that an optional input is always reported, never silent.

### 2. Composed tooltips

The tooltip text is derived from context, so that no fact is ever stated twice:

- **Prose already expands the term inline** (the `interview-prep` first-use rule): link the abbreviation inside the parenthetical, and the title carries **purpose only**.

  `Object-Relational Mapping ([ORM](url "Maps relational rows onto objects so queries are written in the host language."))`

- **Prose does not expand it** (all `system-design` documents, and any later use): the title carries **`Expansion — purpose`**.

  `[SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — an open REST standard for provisioning users and groups between an identity provider and an application.")`

The linker decides which form applies mechanically: an occurrence counts as already expanded when the text immediately preceding it is that term's glossary `Expansion` followed by an opening parenthesis. Every other occurrence takes the `Expansion — purpose` form.

This is what lets `system-design` adopt the convention without gaining a prose rule of its own, and what lets `output-conventions.md` rule 1 stay exactly as written.

### 3. The linker

A Python script, `.claude/scripts/link-abbreviations.py`, applies the glossary to a set of Markdown files. Two modes:

- default — rewrite files in place
- `--check` — report only, exit non-zero on any finding, write nothing

**Matching rules.**

- First eligible occurrence per file per term. Case-sensitive, word-boundary.
- **Longest match first.** `SHA256` and `AES-256` must be attempted before `SHA`, or `SHA` links inside `SHA256`. Both `SHA256` and `SHA-256` occur in the corpus; each is its own glossary row rather than a normalisation rule, so the linked text always matches the prose.
- **Slash compounds need no special handling.** `CI/CD`, `OAuth2/OIDC`, `MQTT/TLS` and `REST/HTTPS` all occur. A `/` is a non-word character, so word-boundary matching already treats each side as an independent term; the compound is never a term of its own. The fixture suite asserts this rather than leaving it to be assumed.
- **Plural forms are not matched, and cost nothing.** Seven stems appear pluralised (`APIs`, `SLOs`, `SLIs`, `URLs`, `GPUs`, `MRNs`, `JWTs`) and **no term occurs only in plural form**, so every term still has a singular occurrence to link. Matching plurals would complicate longest-match ordering for no measured coverage gain.
- **Product names are matched literally from the glossary, never discovered by pattern.** `SQLAlchemy`, `Alembic`, `Poetry`, `Celery` and `Pydantic` are ordinary capitalised words that no all-caps pattern finds. Any pattern-based discovery of products would be silently arbitrary, so the glossary enumerates them.

**Skipped regions.**

| Region | Reason |
|---|---|
| Fenced blocks, ` ``` ` and `~~~` | Mermaid, SQL and code. 450 occurrences in case 02 fall here and can never be enriched. |
| Inline code spans | Service identifiers such as `` `scim-provisioning-svc` `` |
| All headings, `#` to `######` | A link changes the GitHub anchor slug and breaks the tables of contents, which every document has |
| Existing Markdown links, both text and target | Prevents nested links; 168 already exist in case 02 |
| `<summary>` lines | Structural, not prose |
| YAML frontmatter | None in the current corpus; handled defensively |
| HTML tags, `<...>` | Attribute values and tag names are not prose |

**Table cells are eligible.** They render links and titles normally, and they hold 438 of case 02's prose occurrences — more than body paragraphs do. Excluding them would leave most of the corpus unenriched.

`<details>` **bodies are not skipped** — GitHub renders Markdown inside them and they hold the bulk of every answer pack's prose.

**Idempotency.** An already-linked occurrence counts as that term's first occurrence, so a second run is a no-op. This is a correctness property, not an optimisation: without it, re-running the linker after an edit would link a second occurrence.

### 4. `--check` is the guard

`--check` exits non-zero listing three classes of finding:

1. A glossary term used in eligible prose and left unlinked
2. A link whose title or URL has diverged from the glossary
3. A link to a term absent from the glossary

This makes the new invariant guarded rather than `[UNGUARDED]`.

**It does not verify that URLs resolve.** A gate cannot depend on the network. The ~110 URLs are fetched once by hand before the glossary is committed, and that stays a manual step, re-run when a source is edited. Recorded here as a known limitation rather than left to be discovered.

### 5. The gate does not change

The linker runs **after** generation, over what a skill just wrote. No mode reads the glossary. Therefore:

- `preflight.sh` is untouched and its exit-code contract is unchanged
- `gate-check.sh` is untouched and its four mutation tests need no re-run
- The forbidden pattern *"no mode reads an input the gate did not report"* never fires

This was the deciding factor in choosing a post-pass over a reference file the modes load.

### 6. Skill integration

Each skill gains one line and restates nothing:

- `system-design/SKILL.md`, Step 5, after the consistency review: run the linker over `<project>/*.md`.
- `interview-prep/SKILL.md`, Step 4, after the review: run the linker over the files the mode wrote.
- `output-conventions.md`: one line under Language & style pointing at `.claude/glossary.md` as the owner of abbreviation linking. Rule 1 is otherwise unchanged.

### 7. Testing

Fixtures built in a temporary directory, never inside `cases/`, following the discipline `gate-check.sh` already sets: a known-pass, a known-fail, and a deliberately-wrong control that must be reported. Three states per check — pass, fail, could-not-run — never two.

Four mutations of the linker that the suite must catch:

1. Fence tracking disabled — a term inside a Mermaid block gets linked
2. Heading skip removed — a term in a `##` heading gets linked
3. Idempotency broken — a second run links a second occurrence
4. A stored title corrupted — `--check` fails to report the divergence

### 8. Case 02 back-fill

Measured across all 16 Markdown files of case 02 on `docs/case-02-interview-packs`:

| | Files | Terms | Link sites |
|---|---|---|---|
| `system-design` documents | 14 | 106 abbreviations + 12 products | 417 |
| Answer packs (`interview-questions.md`) | 2 | 59 abbreviations + 14 products | 101 |
| **Corpus total, terms deduplicated** | **16** | **118 abbreviations + 14 products = 132** | **518** |

A further 15 terms are recorded in Section C as deliberately not linked, so the glossary holds 147 rows.

Correctly skipped and therefore never enriched: 450 occurrences inside fenced blocks, all in the design documents, and 295 occurrences in headings, 283 of them in the answer packs whose question titles are all headings and whose tables of contents depend on the anchors.

The back-fill is a single pass on this branch, since both the design documents and the answer packs are present here. It is reviewed as two diffs — design documents first, then the two answer packs — because the packs are 4,456 lines of generated-then-reviewed content and a mixed diff of that size is not reviewable. Nothing is committed without explicit instruction.

### 9. Vocabulary decisions

Product names are included: the mechanism is identical and a link answering "what is ArgoCD" is genuinely useful. Reversing that is deleting fourteen rows.

Short tokens carry a false-positive risk that no rule eliminates — `AP` and `CP` are CAP-theorem terms, `SAS` is an Azure shared access signature, `GC` is garbage collection, `POS` is point of sale. First-occurrence linking keeps the blast radius to one site per document, and the Phase 1 diff review is where these are confirmed.

---

## Repository changes required

| File | Change |
|---|---|
| `CLAUDE.md` — Language / Stack rules | Amend "shell is the only executable code": Python is permitted for the linker. A Markdown-aware rewriter in awk would hinge on `sub()` backreference and quoting behaviour across ~190KB of prose containing tables and nested Markdown |
| `CLAUDE.md` — Where to find things | Rows for `.claude/glossary.md` and the linker |
| `CLAUDE.md` — Architectural Invariants | One invariant, naming `--check` as its guard |
| `CLAUDE.md` — Testing | The two new commands |
| `.claude/glossary.md` | New — 132 linked terms plus 15 recorded exclusions |
| `.claude/scripts/link-abbreviations.py` | New |
| `.claude/scripts/link-abbreviations-check.sh` | New — fixture suite |
| `.claude/skills/system-design/SKILL.md` | One line in Step 5 |
| `.claude/skills/interview-prep/SKILL.md` | One line in Step 4 |
| `.claude/skills/interview-prep/references/output-conventions.md` | One line under Language & style |
| `cases/02/projects/*/*.md` | Back-fill, 518 link sites across 16 files |

## Effort

Populating and URL-verifying 124 glossary entries dominates. The linker and its fixture suite is the next largest piece. Everything else is a line or two per file.
