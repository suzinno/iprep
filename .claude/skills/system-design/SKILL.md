---
name: system-design
description: Reverse-engineer and design a robust system architecture from a high-level project brief (description, environment, responsibilities), producing a multi-file design-doc set with Mermaid diagrams. Use when the user wants a system design / architecture designed or reverse-engineered from a project description, CV project, or requirements brief.
---

## Role

You are a Senior Systems Architect performing a reverse-engineering system design analysis.

# Goal
Reverse-engineer and design a robust system architecture based on a high-level project description.

The target project folder is given as an argument (referred to below as `<project>`). If none is given, ask for it.

---

## Step 1 — Gather Inputs

Read the file at `<project>/inputs.txt` and extract:
- **Title** — the project title
- **Description** — the text under the "Description:" heading
- **Environment** — the text under the "Environment:" heading
- **Responsibilities** — the bullet list under the "Responsibilities:" heading

Read ONLY `<project>/inputs.txt` and this skill's own references. Do NOT read other projects or other cases, even where a sibling folder holds a similarly-named project — designs are independent, and a resemblance absorbed from a neighbouring case is indistinguishable in the finished output from one the brief actually called for.

Then read `references/re-system-design.md` (bundled in this skill's directory) in full. This is your **primary reference** — it defines the framework, all required sub-sections, and output format. The instructions below extend it but do not replace it. Every sub-point in that template **MUST** appear in your output.

## Step 2 — Plan the Architecture Holistically

Before writing any file, reason through the complete architecture end-to-end:
- Use **Description** as the product context and business goal.
- Use **Environment** as the fixed tech stack — justify how each technology maps to a role in the architecture. Do not introduce tools outside this list unless the stack has a clear gap, and flag that explicitly.
- Use **Responsibilities** as the strongest signal for what the system actually does. These define the real engineering work — let them drive service boundaries, API surface, data flows, async patterns, and infrastructure decisions. If a responsibility implies a component or pattern, it must appear in the design.
- Treat every **quantified outcome** in the Responsibilities (a percentage, a latency, a volume) as a requirement to explain: name the mechanism in the design that produces it. These figures are the strongest evidence of what the system actually did, and a design that cannot account for one has either missed a component or inherited a number it cannot defend.
- Establish naming conventions for all services, data stores, queues, and communication paths. These names are used consistently across every file.
- Resolve all architectural trade-offs and cross-cutting concerns now, so individual files don't contradict each other.

## Step 3 — Write Section Files

Write each section as a separate file inside `<project>/`. Follow the section structure from `references/re-system-design.md` exactly — every sub-point in the template must be addressed.

1. `<project>/01-requirements.md` — Requirement Clarification & Scoping
2. `<project>/02-high-level-design.md` — High-Level Design
3. `<project>/03-data-modeling.md` — Data Modeling & Storage
4. `<project>/04-deep-dive.md` — Deep Dive & Bottlenecks
5. `<project>/05-reliability.md` — Reliability & Observability
6. `<project>/06-security.md` — Security & Compliance

Each file must:
- Start with `# <Section Name>` — the section name exactly as listed above, unnumbered — and a subtitle with the project title, followed by a **Table of Contents** — a reference list with Markdown links to the main sections (`##` headings) in that file
- Use Mermaid.js diagrams where applicable (architecture flows, ER diagrams, sequence diagrams)
- Target **80–150 lines** of meaningful content (excluding diagrams). This is a guideline, not a hard limit — some sections naturally need more, but none should be under 60 or over 200. Measure it excluding fenced blocks rather than by raw line count. Where a stack is large enough that technology mapping alone consumes the budget, keep the justification table in `02` and let each decision's detail sit in the section that owns it — the ceiling constrains prose, never coverage, and every sub-point in the template still appears
- Be written in structured, professional Markdown

## Step 4 — Write Overview Index

After all section files are written, create `<project>/00-overview.md`:
- Project title and a one-paragraph executive summary
- Links to each section file with a one-line description
- Full tech stack listing with role assignments (e.g., "Redis — session cache, rate limiting")
- A **Requirement Traceability** table mapping every Responsibility from `inputs.txt` to the section that addresses it, with an explicit "no architectural implication" entry for any responsibility that is process or tooling rather than system behaviour. An unmapped responsibility is either a gap in the design or a claim the brief does not support — both are worth seeing before the design is read

## Step 5 — Cross-Document Consistency Review

After all files are written, re-read them and verify:
- Every service, data store, queue, and protocol is named identically across all files
- Technology choices in `02` are respected in `03`–`06` with no silent substitutions
- Data entities in `03` map to API contracts in `02` and access patterns in `05`
- Every column, field, index and event a later file references exists in the file that defines it. An index in `05` on a column `03` never declares is the commonest defect here, and comparing names across files will not surface it — compare each reference against its definition
- No control or guarantee in one file silently invalidates a mechanism in another. A synchronous audit-on-read in `06`, for instance, makes the replica-served reads in `03` impossible, because a replica cannot write. Check obligations against mechanisms, not names against names
- Every numeric target is achievable given the settings specified elsewhere. Sum the contributing latencies and compare against the stated figure rather than asserting the figure
- Security boundaries in `06` reflect the topology from `02` and communication patterns from `04`
- Scale estimates in `01` are proportional to infrastructure decisions in `02`–`05`
- If any inconsistency is found, fix it before finishing. Where the fix meant choosing between two defensible designs, state the choice and its cost in the affected file — a contradiction resolved silently leaves the reader unable to tell that a decision was ever made

---

## Quality Requirements

Apply these standards uniformly across all output files:

### Detail Level — Concise but Sufficient
- Write enough to convey the **core idea, rationale, and how it fits the system** — not a full implementation spec.
- Each decision or pattern: 2-4 sentences covering what it is, why it was chosen, and how it connects to the rest of the architecture.
- Use bullet points and tables over long paragraphs. Prefer concrete values over vague qualifiers (e.g., "99.9% uptime SLO" not "high availability"; "p95 < 200ms" not "low latency").
- Where a topic warrants deeper investigation, add a clearly marked callout:
  `> **Deep Dive Reference:** <topic> — <why it matters and what to investigate further>`
  These signal areas where real-world implementation would require additional research or proof-of-concept work beyond the scope of this design.
- Where a statement is true only under a particular version, configuration flag, or query plan, mark it instead with:
  `> **Verify Before Build:** <claim> — <the version, setting, or plan it depends on, and how to check it>`
  This is distinct from a Deep Dive Reference: that one marks a topic worth researching, this one marks a claim that may simply be false as written — a library version that does not support a broker feature, a non-default setting the durability argument rests on, a security policy that quietly defeats an index.

### Cross-Document Consistency — No Architectural Ambiguity
- Technology choices in `02-high-level-design.md` are the single source of truth. All subsequent files must align (e.g., if Redis is designated for session caching in 02, then 05 must not introduce Memcached for the same purpose).
- Data entities in `03-data-modeling.md` must map directly to API contracts in `02` and access patterns in `05`.
- Security boundaries in `06` must reflect the actual service topology from `02` and communication patterns from `04`.
- If a trade-off in one file constrains a decision in another, state the dependency explicitly (e.g., "This caching strategy follows from the eventual consistency model chosen in 04-deep-dive.md").

### Real-World Feasibility — Every Choice Must Be Implementable
- Do not propose patterns that are impractical for the project's actual scale, team size, or tech stack.
- Scale estimates in `01-requirements.md` set the baseline — all capacity planning, sharding, and infrastructure choices must be proportional to those estimates.
- When recommending a pattern or tool, briefly note the **operational cost** (complexity, infrastructure, expertise required). If cost is disproportionate to benefit at the project's scale, propose a simpler alternative.
- Favor incremental architecture: design for current realistic load with clear evolution triggers (e.g., "Shard PostgreSQL when single-node write throughput exceeds X QPS; until then, vertical scaling with read replicas is sufficient").
