# Reliability & Observability

*Logistics Platform for Transport Management and Analytics*

## Table of Contents

- [Read/Write Optimizations](#readwrite-optimizations)
- [Optimizing Legacy Report Queries](#optimizing-legacy-report-queries)
- [Caching Strategy](#caching-strategy)
- [Telemetry](#telemetry)
- [Automation and Release](#automation-and-release)
- [Backup and Recovery](#backup-and-recovery)

---

## Read/Write Optimizations

Indexes follow the query patterns; each one names the query it serves.

| Table | Index | Serves |
|---|---|---|
| `tms_db.shipment_status_event` | B-tree `(shipment_id, event_ts)` | A shipment's history in order; the transition check reads the latest event |
| `tms_db.shipment` | Partial B-tree `(status_code, promised_delivery_by) WHERE status_code NOT IN ('DELIVERED','CANCELLED')` | Dispatcher lists of open shipments, soonest due first; the partial index stays small because most rows are terminal |
| `tms_db.shipment` | B-tree `(updated_at)`, present on `tms_db_replica` through replication | The nightly incremental extract |
| `tms_db.outbox_event` | Partial B-tree `(created_at) WHERE published_at IS NULL` | The outbox relay's poll, which only ever reads unpublished rows |
| `ext_hub.carrier_message` | Unique `(carrier_code, idempotency_key)`; B-tree `(received_at)` | Duplicate rejection at intake; the nightly extract |
| `core.fact_status_event` | [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") `(event_date)` | Date-range scans; rows arrive in date order, so a BRIN index is a few pages instead of gigabytes |
| `core.fact_status_event` | B-tree `(shipment_key, event_ts)` | Window functions per shipment in mart builds |
| `core.fact_shipment` | B-tree `(carrier_key, promised_delivery_by)` | Carrier and date filters in [SLA](https://en.wikipedia.org/wiki/Service-level_agreement "Service Level Agreement — Commitment between a provider and its customer on measurable service targets, such as delivery time") and on-time marts |
| `mart.*` | B-tree on the grain columns, e.g. `(business_date, carrier_key)` | [BI](https://en.wikipedia.org/wiki/Business_intelligence "Business Intelligence — Tools and practices that turn stored business data into reports and dashboards for decisions") filters and DirectQuery pages |
| `nrt.shipment_status_current` | Primary key `(shipment_id)`; B-tree `(region, status_code)` | Upserts; the "deliveries today" page filtered by region |
| `dq.recon_discrepancy` | Partial B-tree `(carrier_id, detected_at) WHERE status = 'open'` | The analysts' open-discrepancy queue |

**No full-text index.** No query searches free text. **No [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") index**: [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") has none, and expiry is done by dropping partitions (`03-data-modeling.md`).

**Write path.** `COPY` into `stg` partitions, then set-based `INSERT … ON CONFLICT DO UPDATE` into `core`. Mart builds in `mart_build` create each table with `CREATE TABLE AS` and add indexes **after** the load, which is several times faster than maintaining them row by row.

> **Verify Before Build:** Since PostgreSQL 12, a [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement") referenced once is inlined into the outer query unless it is declared `MATERIALIZED`. Legacy queries written for older versions sometimes relied on the CTE acting as an optimisation fence. Check the plan of each migrated query on the target version.

---

## Optimizing Legacy Report Queries

Inherited report [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") is the largest source of slow regular reports. The method is the same for each query:

1. **Find the cost.** `pg_stat_statements` ranks statements by total time, not by single-run time. A 2-second query run 5,000 times a day matters more than a 5-minute monthly one.
2. **Read the plan.** `EXPLAIN (ANALYZE, BUFFERS)` on production-sized data shows where rows are misestimated, which scans are sequential, and where sorts spill to disk.
3. **Fix the cause, in this order:**
   - Move the report onto a mart, so it reads pre-aggregated rows instead of recomputing from raw facts on every run.
   - Rewrite correlated subqueries and repeated self-joins into one pass with window functions.
   - Make predicates sargable: `event_date >= $1` instead of `date_trunc('day', event_ts) = $1`, so partition pruning and indexes apply.
   - Add the index the plan asks for, and nothing speculative.
4. **Prove it.** Compare the results row by row with the old query before switching the report. A faster query with different numbers is a regression.

**Mart structure for speed.** Marts are stored at the grain the dashboards filter on, carry the dimension attributes the reports display (a denormalised copy), and are rebuilt with fresh statistics (`ANALYZE`) after every build.

---

## Caching Strategy

The platform has no [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") layer and no [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"). Every consumer is internal, and every expensive read has a pre-computed store behind it. Adding a distributed cache would add a component with nothing to cache.

| Layer | What is cached | Invalidation |
|---|---|---|
| **BI datasets** | Power BI import-mode datasets and Tableau extracts hold a copy of `mart` | Event-driven: `consolidation-runner` triggers a refresh right after the swap. No timer refresh, so a dataset never shows a half-built day |
| **Database** | Each mart is a materialised result of `core` | Rebuilt in full every night in `mart_build`, published by the swap — write-then-publish, the analytic form of write-through |
| **Application** | `tms-api` keeps reference data (locations, carriers, status transitions) in process memory | Cache-aside with a 5-minute TTL; a change to reference data is visible within 5 minutes |
| **Near-real-time pages** | Not cached | DirectQuery against `nrt.shipment_status_current`, because a cache would defeat the purpose |

> **Verify Before Build:** Power BI automatic page refresh for a DirectQuery page is limited by capacity: shared capacity does not allow intervals short enough for a 1-minute view, while Premium or Fabric capacity lets the administrator set the minimum. Confirm the capacity before promising a 1-minute refresh on the dashboard.

---

## Telemetry

### Metrics and SLOs (CloudWatch)

| [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health") | [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") | Alarm |
|---|---|---|
| Daily publish time (`meta.mart_publish_state.published_at`) | By 07:00 on 99% of business days | No publish by 06:00 → on-call data engineer |
| Near-real-time freshness: `nrt-loader` emits `now − received_at` per upsert, where `received_at` is the carrier message's intake time carried in the event | p95 ≤ 2 min | p95 > 5 min for 10 min |
| `tms-api` latency | p95 < 300 ms | p95 > 500 ms for 5 min |
| `carrier-gateway` acknowledgement latency and 5xx rate | p95 < 500 ms; 5xx < 0.1% | 5xx > 1% for 5 min |
| Blocking data-quality failures per run | 0 | Any failure → alert with the rule and the observed value |
| Queue depth: `tms.carrier-status`, `analytics.nrt`; any `.dlq` depth | Near 0 | Depth > 10,000 or any message in a `.dlq` |
| Open carrier discrepancies older than 5 days | Trend down | Weekly report, not a page |
| Near-real-time versus daily difference (see `04-deep-dive.md`) | Tracked, no target yet | — |

Every Python job emits `rows_extracted`, `rows_loaded`, `step_duration_seconds` and `checks_failed` as custom metrics with `run_id` and `step` dimensions. Amazon MQ and [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") publish their own metrics natively.

### Structured logging

All services and jobs log [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") lines to CloudWatch Logs with `timestamp`, `level`, `service`, `run_id` or `request_id`, `carrier_code`, `message_id` and `event_id` where they apply. Logs Insights can then follow one carrier message from intake to the near-real-time table by `message_id` and `event_id`.

### Distributed tracing

A correlation ID travels with every hop: the `message_id` from `carrier-gateway` is copied into the event headers, then into `shipment_status_event.source_ref`, then into the outbox event. For request-level traces through `tms-api` and `carrier-gateway`, OpenTelemetry instrumentation can export to [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") X-Ray. It is not in the brief's stack, so it is optional here; the correlation IDs already answer "where did this message go".

---

## Automation and Release

The brief names no [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") tool, so the pipeline below is tool-neutral.

1. **On every change:** lint Python and SQL; run unit tests for the check logic in `quality-runner`; apply the versioned SQL migrations to a fresh PostgreSQL container, which proves they run from zero.
2. **Integration stage:** run the nightly flow end to end against a masked, production-shaped snapshot. Run the full `meta.dq_rule` set and the [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") regression against `dq.kpi_baseline`.
3. **Release sign-off:** the analytics release lists every KPI that moved beyond its threshold with the reason. Business owners sign off expected changes; an unexplained move blocks the release.
4. **Deploy services** (`tms-api`, `carrier-gateway`, `quality-api`, `nrt-loader`) as [ECS](https://aws.amazon.com/ecs/ "Amazon Elastic Container Service — Managed container orchestration on AWS; with Fargate it runs containers without managing servers") rolling deployments with health checks and automatic rollback.
5. **Deploy marts blue-green.** The new definitions build into `mart_build` in the next nightly run. After the checks pass, one transaction renames `mart` to `mart_prev` and `mart_build` to `mart`. Rollback is the reverse rename. BI connections use the same schema and table names throughout.
6. **After release:** `quality-runner` compares the first published day's KPIs with the baseline, and the analyst checks the headline numbers on the dashboards before closing the release in Jira.

> **Verify Before Build:** `ALTER SCHEMA … RENAME` needs an exclusive lock and waits for running BI queries. Set a short `lock_timeout` with a retry so the swap cannot stall the batch, and set default privileges so `bi_reader` has `SELECT` on objects created in `mart_build`.

---

## Backup and Recovery

| Store | [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") | [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") | Mechanism |
|---|---|---|---|
| `tms_db` | 5 min | 1 h | RDS automated backups with point-in-time recovery; Multi-[AZ](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/ "Availability Zone — Isolated group of data centres within an AWS Region, used to survive a single-site failure") for instance failure |
| `ext_hub` | 5 min | 4 h | RDS automated backups; the owning team's recovery plan applies |
| `analytics_dwh` | 24 h | 4 h | Rebuildable: nightly RDS snapshot, plus `lp-archive` extracts from which `core` can be replayed |
| `lp-landing`, `lp-archive` | 0 | — | [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") versioning; lifecycle to archive storage after 90 days |
| [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") | Messages in flight | Minutes | Quorum queues; `carrier-gateway` stores the raw message in `ext_hub` before it publishes, so the broker is never the only copy |
