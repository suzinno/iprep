# Requirement Clarification & Scoping

*Retail Software Aggregation Platform*

## Table of Contents

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Explicit Non-Goals](#explicit-non-goals)

## Target Audience

**[B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers"), three-sided, with an operator role.** No consumer surface exists.

| Actor | Who they are | What they do |
|---|---|---|
| **Vendor team** | Product/sales staff at a software vendor | Publish and revise listings, respond to inbound conversations, run bulk catalog imports |
| **Category manager** | Sourcing role inside a retail group | Compare features, pricing and coverage; shortlist; open a conversation with a vendor |
| **Retail group admin** | IT/procurement lead for a chain | Manages the group's stores, users and shortlist visibility |
| **Platform operator** | Internal marketplace staff | Vet vendors, moderate listings, resolve disputes, manage plans and billing |

The buying unit is an organisation, not a person. Every read and write is scoped to an org (`vendor` or `retail_group`), and a category manager who leaves the chain must lose access while the chain's shortlists and conversation history survive — this drives the org-scoped authorization model in `06-security.md`, not user-level ownership.

## Functional Requirements

**Must have**

1. **Catalog browse, filter and compare.** Faceted search over listings by category, country coverage, deployment model, price band and integrations; a side-by-side comparison of up to five products. This is the platform's reason to exist and the dominant traffic.
2. **Vendor listing lifecycle.** Draft → publish → revise, with per-category metadata that has no fixed column set, plus bulk import for vendors with large portfolios.
3. **Shortlist with talk-state.** A retail group builds shortlists and sees, per product, whether someone in the group is already in conversation — the brief's "track who is already in talks".
4. **Vendor–retailer connection and threaded conversation.** A connection request from a listing becomes a durable thread; this replaces the separate [RFP](https://en.wikipedia.org/wiki/Request_for_proposal "Request For Proposal — Formal solicitation inviting vendors to bid on a project") round.
5. **Admin workspace over vendors, retail chains, stores and products.** Every entity a support ticket would otherwise touch is editable by the right role without an engineering change.

**Nice to have**

1. **Coverage gap suggestions** — surface listings matching a chain's declared gaps in checkout, stock or loyalty.
2. **Vendor analytics** — impressions, shortlist adds and connection conversion per listing.
3. **Saved searches with change alerts** when a matching listing is published or repriced.
4. **Vendor plan and connection-based billing**, isolated from listing edits (the brief's requirement that listing changes not spill into billing flows).

## Non-Functional Requirements

| Property | Target | Rationale |
|---|---|---|
| **Availability — catalog read** | 99.9% monthly (≈43 min budget) | Browse is the shop window; degrading to cached data is acceptable, being down is not |
| **Availability — write paths** | 99.5% monthly | Single-region, zone-redundant. Multi-region active-active is not proportional at this scale (see `04-deep-dive.md`) |
| **Latency — catalog search** | p95 < 200 ms, p99 < 500 ms server-side | Comparison work is interactive; the budget is decomposed in `05-reliability.md` |
| **Latency — listing detail** | p95 < 150 ms | [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store")-served on the hot path |
| **Latency — connection create** | p95 < 300 ms | Synchronous commit plus outbox insert; delivery is async |
| **Scalability** | 100 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") peak sustained without re-architecture | Roughly 3× the modelled peak; see the evolution triggers below |
| **Consistency ([CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition"))** | **[CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability") for connections, billing and identity; [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") for catalog reads** | A connection request, a charge or a token must never be lost or double-counted. A listing edit that takes seconds to appear in search results costs nothing |
| **Catalog projection freshness** | p95 < 5 s, p99 < 30 s from publish to searchable | The staleness window the AP choice buys; measured as `indexer_lag_seconds` in `05-reliability.md` |
| **Durability** | [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") 15 min, [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") 4 h | Geo-redundant backup, not a warm standby region |

The system is **not throughput-constrained**. The complexity it does carry comes from two places: heterogeneous per-category product metadata that still has to be filterable, and strict multi-tenant isolation between competing vendors and competing retail groups. Every non-trivial decision downstream traces to one of those two, not to load.

## Scale Estimation

Baseline for a mature European deployment. The brief quantifies nothing, so these are stated assumptions that all capacity planning in `02`–`06` is held to.

**Population**

| Entity | Year 1 | Year 5 |
|---|---|---|
| Vendors | 400 | 2,000 |
| Published listings | 2,500 | 40,000 |
| Retail groups | 900 | 5,000 |
| Stores (across groups) | 60,000 | 250,000 |
| Registered users | 5,000 | 25,000 (≈18,000 retailer-side, ≈7,000 vendor-side) |

**Traffic (year 5)**

- **[DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day") 3,000**, [MAU](https://en.wikipedia.org/wiki/Active_users "Monthly Active Users — Count of distinct users who use a product within a calendar month") 12,000 — weekday-concentrated B2B usage, roughly 12% of registered users active daily.
- ~120 [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") requests per active user per day → **≈360,000 requests/day ≈ 4.2 QPS average**.
- Peak factor 8× (European mid-morning) → **≈35 QPS peak**, of which ~33 read and ~2 write. Read:write ≈ 17:1 by request count, and closer to 50:1 by database work once cached reads are excluded.
- Async volume: ~200 catalog import jobs/day (peak 40 concurrent rows-in-flight per vendor), ~15,000 notifications/day → 0.2 msg/s average, ~20 msg/s in a post-import burst.

Capacity is provisioned for **100 QPS peak**, ~3× the model. That headroom is one autoscaling step, not an architectural allowance.

**5-year storage**

| Store | Size | Dominant contributor |
|---|---|---|
| `postgres-core` | ~110 GB | `audit_event` ~25 GB, `connection_message` ~8 GB, indexes ~25 GB, remainder operational tables |

These are **steady-state resident sizes at the retention windows defined in `03-data-modeling.md`** (24 months of audit, 36 months of closed-thread messages), not cumulative five-year totals. The two unbounded tables are partitioned monthly and detached on schedule, so resident size plateaus rather than growing linearly.
| `mongo-catalog` | ~15 GB | 40,000 listings × ~60 KB including ~10 retained revisions |
| `blob-media` | ~1.5 TB | 40,000 listings × ~15 assets × ~1.5 MB, plus import files |
| `redis-cache` | 6 GB working set | Hot listings, search result pages, facet counts, rate-limit counters |

Both databases fit a single well-provisioned node for the whole five-year horizon with room to spare, which is why neither is sharded in `03-data-modeling.md`. The explicit evolution triggers: **shard `postgres-core` only if sustained write throughput exceeds 2,000 [TPS](https://en.wikipedia.org/wiki/Transaction_processing "Transactions Per Second — Throughput measure of how many transactions a system completes each second") or the working set exceeds ~1 TB**; **introduce a dedicated search engine only if p95 catalog search exceeds 200 ms after the index work in `05-reliability.md`, or if free-text relevance ranking becomes a product requirement**. Until then, vertical scaling plus read replicas and a Postgres-native search projection are correct and materially cheaper to operate.

> **Deep Dive Reference:** Marketplace liquidity metrics — the scale numbers above model usage, not marketplace health. Connection-to-response rate and time-to-first-vendor-reply determine whether the platform actually shortens sourcing, and they should be instrumented from day one (see `05-reliability.md`) rather than reverse-engineered later.

## Explicit Non-Goals

- **No payment processing between retailer and vendor.** The platform brokers a conversation; contracts and money settle off-platform. Vendor subscription billing is in scope and is delegated to an external [PSP](https://en.wikipedia.org/wiki/Payment_service_provider "Payment Service Provider — Third party that processes card and payment transactions on a merchant's behalf"), which keeps cardholder data entirely out of the system (`06-security.md`).
- **No RFP/tender workflow engine.** The product replaces a sourcing round; it does not model one.
- **No cross-marketplace vendor federation** or syndication to third-party catalogs.
- **No consumer or single-store self-service tier** in the modelled scope — the buying unit is a chain.
