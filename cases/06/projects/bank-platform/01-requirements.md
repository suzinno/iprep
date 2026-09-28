# Requirement Clarification & Scoping

**Project:** Банковская платформа управления ликвидностью и финансовой аналитики (bank liquidity management and financial analytics platform)

## Table of Contents

- [Context and Assumptions](#context-and-assumptions)
- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Out of Scope](#out-of-scope)

## Context and Assumptions

The platform is the treasury and finance analytics slice of a bank's on-premise [DWH](https://en.wikipedia.org/wiki/Data_warehouse "Data Warehouse — Central store that integrates historical data from many sources for reporting and analysis"). It consolidates balances, postings, treasury deals and reference data from banking and internal sources, calculates cash positions, liquidity metrics, cash flow and financial KPIs in 20+ data marts, and serves them to 25+ reports and dashboards in Power [BI](https://en.wikipedia.org/wiki/Business_intelligence "Business Intelligence — Tools and practices that turn stored business data into reports and dashboards for decisions") and Apache Superset.

The brief does not state these facts; the design assumes them and each is named where it constrains a decision:

| Assumption | Why it matters |
|---|---|
| The platform is a tenant of the bank's existing Greenplum DWH, not a dedicated cluster | Greenplum is justified by the shared DWH and the multi-year history, not by this project's volume alone (see [Scale Estimation](#scale-estimation)) |
| Source classes: core banking ledger (nightly extract), payment postings and account balance updates ([Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing"), intraday), treasury deal system (nightly extract), correspondent-account statements (file drop), reference data (currencies, [FX](https://en.wikipedia.org/wiki/Foreign_exchange_market "Foreign Exchange — Conversion between currencies and the rates used to value amounts in another currency") rates, calendar, legal entities) | Drives the ingestion paths in `02-high-level-design.md` |
| Core banking closes the operational day and delivers end-of-day extracts by 04:00 | Sets the batch window: daily marts must be published by 07:30 |
| The metrics are management liquidity metrics (positions, gaps, buffers, cash flow), not the regulatory submission itself | Keeps the regulatory scope in `06-security.md` to data controls rather than filing |
| Legacy marts (`dm_legacy`) exist and feed the current reports | Migration of 25+ reports is a parallel run, not a greenfield build |

## Target Audience

Internal, [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers")-within-the-bank. No external or retail users.

| Group | Size | Uses |
|---|---|---|
| Treasury (liquidity and funding desk) | ~30 | Intraday cash positions, liquidity gaps and buffers, daily liquidity pack |
| Finance departments (controlling, planning, accounting) | ~200 | Cash flow actual vs forecast, financial KPIs, monthly packs |
| Operational control | ~50 | Load and reconciliation status, discrepancy follow-up, intraday monitoring |
| Management | ~100 | Summary dashboards, read-only |
| DWH analysts and engineers | ~20 | Ad-hoc [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database"), reconciliation analysis, adjustments, mart development |

## Functional Requirements

**Must have**

1. **Daily consolidation** of 500K+ financial records from several sources into layered storage (`stg` → `core` → `dm`), idempotent per load batch and per business date.
2. **Calculation marts**: 20+ data marts for end-of-day and intraday cash positions, liquidity gaps and buffers, actual and forecast cash flow, and financial KPIs, calculated by Greenplum stored procedures.
3. **Near-real-time intraday positions** from Kafka into the staging layer, visible on dashboards within 15 minutes of the source event.
4. **Automated multi-level reconciliation** (source ↔ staging ↔ core ↔ marts ↔ reports) that blocks publication of a business date with a failing blocking rule.
5. **Report delivery and migration**: 25+ Power BI and Superset reports reading a stable view contract, migrated from legacy marts with a parallel run so no scheduled delivery is missed.

**Nice to have**

1. **Source change impact analysis**: given a changed source field, list the affected columns, marts, KPIs and reports from a mapping and dependency registry.
2. **Lineage publication**: generated Confluence pages for data lineage, [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") sources and cross-system dependencies.
3. **Discrepancy management**: a break register with root-cause category, status and Jira link.
4. **Controlled manual adjustments** prepared as code, approved by a second person, applied through the normal build.
5. **Platform health dashboard**: run success, freshness and reconciliation status in Superset.

## Non-Functional Requirements

| Attribute | Target | Mechanism (owner file) |
|---|---|---|
| Run success | ≥ 99.9% of scheduled load and report runs per month succeed, automatic retries included | Idempotent steps, retries, dependency gates (`04-deep-dive.md`) |
| Daily freshness | Previous business date published by 07:30 and Power BI refreshed by 08:00 on ≥ 99% of business days | Batch window and critical path (`04-deep-dive.md`) |
| Intraday freshness | p95 ≤ 15 min from Kafka event to Superset dashboard | 60 s micro-batch + 5 min rebuild + 5 min cache (`04-deep-dive.md`) |
| Key report generation time | ~40% below the pre-optimisation baseline | Distribution, partitioning and SQL rewrite (`04-deep-dive.md`) |
| Availability | 99.5% for BI during business hours (Mon–Fri 07:00–20:00); batch is best effort outside them | Mirrored segments, standby coordinator, two Superset instances (`04-deep-dive.md`) |
| Dashboard latency | p95 < 3 s for Power BI import models; p95 < 5 s for uncached Superset charts | Pre-aggregated marts, caching (`05-reliability.md`) |
| Accuracy | Amounts stored as `NUMERIC`, never floating point; every published date passes all blocking reconciliation rules | Reconciliation gate (`04-deep-dive.md`) |
| Retention | 5 years of consolidated history online | Monthly partitions (`03-data-modeling.md`) |

**Consistency ([CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition")):** single-site, on-premise, so partition tolerance is about node failure rather than a split between regions. For published figures the platform is [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability"): a business date becomes visible only after it reconciles, and if reconciliation fails the reports keep showing the previous published date with a stale marker rather than unreconciled numbers. Intraday positions are the one [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") path: they are always shown, labelled as indicative with their `as_of_ts`, and replaced by the reconciled end-of-day figure next morning.

## Scale Estimation

**Users.** ~400 named users, ~200 [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day"). Peak is 08:30–10:00 when the daily packs are opened.

**Write volume.**

- 500K+ records per business day (brief), assumed split ~350K postings, ~100K account balances, ~50K deals, cash flows and reference rows.
- Month-end and quarter-end peak: design for 3× = 1.5M records per day.
- Kafka intraday: ~400K messages over a 12-hour day ≈ 9 msg/s average, ~50 msg/s at 5× intraday bursts, ~150 msg/s at month-end. Trivial for Kafka; the design problem is Greenplum's dislike of small inserts, not throughput.

**Read [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second").**

- Superset: ~120 users × 8 dashboard views × 10 charts ≈ 9.6K chart queries per day; 25% in the peak hour ≈ 0.7 QPS, bursts to ~5 QPS. With a ~50% cache hit rate, Greenplum sees ≤ 3 QPS from Superset.
- Power BI import models answer from memory; Greenplum sees only the refresh queries, ~27 datasets × ~5 queries ≈ 135 queries after each publish.
- Scheduled runs: ~15 source loads + ~24 mart builds + ~40 reconciliation rule groups + ~27 report refreshes + publish ≈ 110 runs per business day ≈ 2,400 per month. At 99.9%, that budget allows about 2 failed runs per month. The 156 intraday cycles per day (every 5 minutes, 07:00–20:00) are measured by the freshness [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") instead, so they do not dilute the run-success figure.

**Storage, 5 years.**

| Component | Estimate |
|---|---|
| `core` facts | ~150M rows/year × 5 ≈ 750M rows × ~250 B ≈ 190 GB raw; ≈ 50 GB in append-optimized columnar tables with zstd (~4×) |
| `dm` marts | ≈ 30 GB (aggregated, heap tables) |
| `stg` | 90-day retention of raw payloads ≈ 45 GB |
| `dm_legacy` during migration | ≈ 30 GB, dropped per report after cutover |
| Subtotal × 2 (segment mirrors) + 50% headroom for spill and vacuum | ≈ 0.5 TB of Greenplum allocation |
| [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") `ctl` | < 20 GB (run log, reconciliation results, registries) |
| Kafka | 400K × 1 KB × 7-day retention × replication factor 3 ≈ 8.4 GB |

**What the numbers say.** 750M rows over five years does not by itself need an [MPP](https://en.wikipedia.org/wiki/Massively_parallel "Massively Parallel Processing — Splits one query across many nodes that each process their own slice of the data at the same time") database; a well-partitioned PostgreSQL could hold it. Greenplum is the right home because the source data and the legacy marts already live in the bank's DWH, and because multi-year window functions over postings and balances parallelise across segments. The platform should be sized as a tenant with a resource group, not as a cluster of its own.

## Out of Scope

- Regulatory submission to the central bank; the marts may feed it, but filing is another system.
- Payment execution or any write back to core banking.
- Forecasting models beyond the contractual cash-flow schedule.
- A custom web application for business users; BI tools are the only user interface.
