# Requirement Clarification & Scoping

**Tender Platform for a MENA Police Department**

## Table of Contents

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Explicit Non-Goals](#explicit-non-goals)

## Target Audience

Government-to-business (B2G), with two populations that share no data and must never be able to reach each other's records.

| Actor | Population | What they do |
|---|---|---|
| **Procurement officer** (internal) | ~120 | Drafts a tender, uploads the requirement pack, sets criteria and weights, publishes, runs the clarification period |
| **Evaluator** (internal, often seconded from a technical unit) | ~500 | Scores assigned bids against criteria after the sealed bids are opened |
| **Committee chair / awarding authority** (internal) | ~60 | Convenes the evaluation session, arbitrates consensus, signs the award |
| **Legal, finance, audit** (internal) | ~180 | Reviews compliance, budget encumbrance, and the award trail after the fact |
| **Platform administrator** (internal) | ~40 | Manages users, reference data, vendor qualification categories |
| **Vendor user** (external) | ~14,000 across ~6,000 vendor organizations | Registers the organization, maintains qualification documents, asks clarification questions, submits a bid |

The CRM half of the product serves the internal side only: vendor accounts, contacts, engagement history and qualification status are department-owned records about a vendor, not records the vendor edits.

## Functional Requirements

**Must have**

1. **Tender lifecycle** — draft → internal approval → published → clarification → closed → under evaluation → awarded → contracted, with an immutable version of the requirement pack captured at publication. A published tender's criteria and weights cannot change; a correction is a new version with its own notice.
2. **Sealed bid submission** — a vendor uploads a bid pack and commits it before the deadline. Bid content is cryptographically sealed and unreadable to anyone, including platform staff, until the tender closes and the evaluation session opens.
3. **Evaluation and award** — criteria with weights, independent scoring per evaluator, a consensus step, a computed weighted total whose formula version is recorded, conflict-of-interest recusal, and an award decision bound to human-entered scores.
4. **Document intelligence** — requirement documents are parsed, chunked and semantically analysed so that criteria, deadlines, mandatory qualifications and deliverables are proposed to the drafting officer; vendor proposals are summarized per criterion with a citation back to the source page.
5. **Vendor CRM** — vendor organization records, contacts, qualification documents and expiry tracking, engagement timeline, and the debarment/suspension list that gates eligibility.
6. **Search and analytics** — keyword and semantic retrieval across tenders, bids and vendor documents, plus department-level spend, participation and cycle-time reporting.

**Nice to have**

1. Clarification Q&A board with anonymised questions broadcast to all bidders on a tender.
2. Auto-generated shortlist ranking as an advisory overlay on the human scores.
3. Contract milestone tracking after award, handing off to the department's finance system.
4. Vendor-facing similarity search ("tenders like ones you have won").
5. Offline evaluation export for committee members working in a room with no network access.

## Non-Functional Requirements

| Property | Target | Where it is held |
|---|---|---|
| Availability — vendor submission path while a tender window is open | 99.9% monthly | `04` failure modes; multi-AZ everywhere on this path |
| Availability — internal CRM, analytics, [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") assistance | 99.5% monthly | Degraded modes are acceptable; see the AI kill switch in `04` |
| Read latency — tender browse, CRM lists | p95 < 250 ms, p99 < 600 ms | `04` latency budget |
| Search latency — hybrid keyword + semantic | p95 < 700 ms | `04` latency budget |
| Upload initiation — presigned [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") issue | p95 < 150 ms | `04` deadline surge |
| Bid sealing — the commit that makes a submission legally on time | p95 < 1.2 s | `04` latency budget |
| Requirement extraction (async) | p95 < 6 min per requirement pack | `04` AI pipeline |
| Proposal summarization (async) | p95 < 3 min per bid pack | `04` AI pipeline |
| Durability of a submitted bid | No acknowledged submission may be lost or altered | `03` submission ledger; `06` custody |
| Scalability — ordinary load | Horizontal on stateless services; no sharding at the modelled volumes | `03` partitioning and its evolution triggers |
| Scalability — deadline surge | Absorb a 10× spike on the submission path with no error-rate change | `04` bottleneck 1; the surge path carries no bytes and holds one short lock |
| [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") / [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") | 5 min / 1 hour, single region | `05` backup and restore |

**Consistency positioning.** The system is deliberately split.

- **[CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability") for anything that decides an outcome** — tender state, bid custody, the submission ledger, scores and the award. These live in one [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") primary, are read on the write path with no replica fallback, and refuse writes during a partition rather than accept a divergent one. A tender that cannot record a submission must reject it visibly; a silently accepted bid is worse than a rejected one.
- **[AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") for anything that only informs** — search, analytics dashboards, notification fan-out and every AI artifact. These are projections rebuilt from the event log with a lag budget of 30 seconds. Nothing in this half is ever an input to eligibility, scoring or award.

The rule this positioning exists to enforce: **no eventually consistent store is ever read to answer "may this vendor bid" or "what did the evaluator score".**

## Scale Estimation

Modelled from the department's size and the tender cadence — the brief carries no measured figures, so every number below is an estimate this design is sized against, not a reported result.

**Users and traffic**

- [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day") ~1,400 (≈300 internal, ≈1,100 vendor), concentrated in a 6-hour regional working window.
- Baseline **25 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second")**, ordinary peak **70 QPS**.
- **Deadline surge: ~260 QPS for 10–20 minutes**, when several hundred vendors finish uploading against the same closing time. The surge is dominated by presigned-URL issue, upload-progress polling and the sealing commit — not by reads.

**Volume**

- ~1,400 tenders published per year; ~11 bids each → ~15,400 bids per year.
- Requirement pack ~35 MB per tender; bid pack ~55 MB per bid.
- Object storage: ≈900 GB/year raw, ≈1.1 TB/year with extracted text and previews → **≈5.4 TB over five years**.
- PostgreSQL: ~40 GB of transactional rows plus ~90 GB of partitioned audit and ledger history → **≈130 GB over five years**, comfortably a single node.
- Search corpus: ~4.9 M chunks/year → ~24.5 M over five years. Only a 24-month hot window (~10 M chunks, ~63 GB including graph overhead) stays in the vector index; older chunks keep their extracted text in object storage and are re-indexed on demand.
- Model traffic: bid summarization dominates, at roughly 180 K input tokens per bid pack → **~2.8 B input tokens/year**. This, not compute, is the platform's largest variable cost, and it is the reason the summarization stage is cached by content hash and runs on the cheaper model tier with only the reduce step on the larger one.

> **Verify Before Build:** the model-tier split above assumes current OpenAI per-token pricing and that the chosen tier's context window holds a full map-stage chunk group — check both against the pricing page and the model card at build time, because the split stops paying for itself if either changes.

**What these numbers mean for the infrastructure.** At 70 QPS steady state no component needs sharding, and the design says so explicitly in `03` rather than provisioning for a scale that is not there. What the numbers *do* force is elasticity on a 10× spike confined to one path, and that shapes `02`: bytes never traverse the [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), the surge path is stateless, and the only serialized resource on it is a per-tender lock held for milliseconds.

## Explicit Non-Goals

- **Not an e-procurement suite.** Purchase orders, invoicing, goods receipt and payment stay in the department's finance system; the platform hands over an award and a contract reference.
- **No reverse auction or live bidding.** Sealed single-round submission only — the mechanism the sealed-bid custody design in `06` assumes.
- **No cross-department tender federation.** One department, one tenant.
- **The model never decides.** Extraction, summarization and generated reports are advisory artifacts with citations. No AI output is ever written into a score, an eligibility verdict or an award record; `04` and `06` enforce this structurally rather than by convention.
