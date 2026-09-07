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

Then read `references/re-system-design.md` (bundled in this skill's directory) in full. This is your **primary reference** — it defines the framework, all required sub-sections, and output format. The instructions below extend it but do not replace it. Every sub-point in that template **MUST** appear in your output.

## Step 2 — Plan the Architecture Holistically

Before writing any file, reason through the complete architecture end-to-end:
- Use **Description** as the product context and business goal.
- Use **Environment** as the fixed tech stack — justify how each technology maps to a role in the architecture. Do not introduce tools outside this list unless the stack has a clear gap, and flag that explicitly.
- Use **Responsibilities** as the strongest signal for what the system actually does. These define the real engineering work — let them drive service boundaries, API surface, data flows, async patterns, and infrastructure decisions. If a responsibility implies a component or pattern, it must appear in the design.
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
- Start with `# <Section Name>` and a subtitle with the project title, followed by a **Table of Contents** — a reference list with Markdown links to the main sections (`##` headings) in that file
- Use Mermaid.js diagrams where applicable (architecture flows, ER diagrams, sequence diagrams)
- Target **80–150 lines** of meaningful content (excluding diagrams). This is a guideline, not a hard limit — some sections naturally need more, but none should be under 60 or over 200
- Be written in structured, professional Markdown

## Step 4 — Write Overview Index

After all section files are written, create `<project>/00-overview.md`:
- Project title and a one-paragraph executive summary
- Links to each section file with a one-line description
- Full tech stack listing with role assignments (e.g., "Redis — session cache, rate limiting")

## Step 5 — Cross-Document Consistency Review

After all files are written, re-read them and verify:
- Every service, data store, queue, and protocol is named identically across all files
- Technology choices in `02` are respected in `03`–`06` with no silent substitutions
- Data entities in `03` map to API contracts in `02` and access patterns in `05`
- Security boundaries in `06` reflect the topology from `02` and communication patterns from `04`
- Scale estimates in `01` are proportional to infrastructure decisions in `02`–`05`
- If any inconsistency is found, fix it before finishing

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
