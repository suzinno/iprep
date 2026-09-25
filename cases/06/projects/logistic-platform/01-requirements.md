# Requirement Clarification & Scoping

*Logistics Platform for Transport Management and Analytics*

## Table of Contents

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Assumptions and Open Questions](#assumptions-and-open-questions)

---

## Target Audience

The platform is **internal [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers")**: one enterprise runs it, and external carriers connect to it as partners.

| Audience | Uses | Volume |
|---|---|---|
| Dispatchers and logisticians | Create transport orders, assign trips, follow delivery statuses | ~400 users |
| Logistics and finance managers | [SLA](https://en.wikipedia.org/wiki/Service-level_agreement "Service Level Agreement — Commitment between a provider and its customer on measurable service targets, such as delivery time"), cost and efficiency dashboards | ~200 viewers |
| Operations analysts and the data team | Data marts, reconciliation, data-quality review, report changes | ~20 users |
| External carriers and transport systems | Send status updates, ETAs, proof of delivery and invoices | ~150 integrations |

The brief's responsibilities sit almost entirely on the **analytics side**: consolidation, data marts, reconciliation, data quality and reporting. The operational side (orders, routes, statuses) is designed only as deeply as the analytics side needs as a source.

---

## Functional Requirements

### Core (must have)

1. **Transport order and delivery tracking** — orders, shipments, routes, trips and a status history per shipment, with carrier status updates applied through a validated state machine.
2. **Carrier data intake** — accept status messages and files from external transport systems, keep every raw payload, and map known fields into internal statuses.
3. **Daily consolidation** — a Python-driven batch that extracts internal, carrier and file data, conforms it into one model and rebuilds 15+ data marts every night.
4. **Reconciliation and data quality** — completeness, uniqueness, reference and divergence checks; source-to-core, core-to-mart and mart-to-report reconciliation; blocking checks stop a mart from being published.
5. **Dashboards** — Power [BI](https://en.wikipedia.org/wiki/Business_intelligence "Business Intelligence — Tools and practices that turn stored business data into reports and dashboards for decisions") and Tableau dashboards for deliveries, costs, SLA and operational KPIs, reading only published marts.

### Supplementary (nice to have)

1. **Near-real-time delivery view** — today's shipment statuses, fed from [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") within minutes rather than overnight.
2. **Carrier discrepancy workflow** — review carrier-versus-internal differences and record a correction decision with an audit trail.
3. **Lineage and source-to-target mapping catalogue** — machine-readable mappings and lineage edges, so the impact of a source change on marts and reports can be queried.
4. **Report regression testing** — compare [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") values before and after a source, mapping or calculation change.
5. **Oracle payload profiling** — analyse the variable-shape carrier payloads before new fields are mapped.

---

## Non-Functional Requirements

| Property | Target | Notes |
|---|---|---|
| Availability — `tms-api`, `carrier-gateway` | 99.9% monthly | Carriers retry on failure; messages are never lost once acknowledged |
| Availability — analytics (`analytics_dwh`, dashboards) | 99.5% in business hours | Nightly downtime for maintenance is acceptable |
| Daily publish | Marts published by 07:00 local time on 99% of business days | The daily batch starts at 01:00 |
| Near-real-time freshness | p95 ≤ 2 min from carrier message to `nrt.shipment_status_current` | Derived in `04-deep-dive.md` |
| Latency — `tms-api` | p95 < 300 ms | Single-row reads and writes on `tms_db` |
| Latency — `carrier-gateway` acknowledgement | p95 < 500 ms | Persist the raw payload, publish, acknowledge |
| Latency — dashboards | p95 < 3 s per page | Import-mode datasets over pre-aggregated marts |
| Scalability | 3× current volume without redesign | Vertical scaling plus read replicas; no sharding |

### Consistency (CAP positioning)

- **`tms_db` is [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability").** One primary with a synchronous Multi-[AZ](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/ "Availability Zone — Isolated group of data centres within an AWS Region, used to survive a single-site failure") standby. A status transition is either committed or rejected; it is never accepted twice.
- **`carrier-gateway` leans [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") for intake.** It accepts and stores a carrier message even when `tms-api` is down, and the message is applied later from the queue.
- **Analytics is eventually consistent, in two tiers.** The near-real-time tier is minutes behind and **not reconciled**. The daily tier is reconciled and is the only source for official reports. When the two disagree, the daily tier wins.

---

## Scale Estimation

Base figures are assumptions sized for a mid-to-large enterprise logistics operation; the brief gives no volumes.

| Driver | Estimate |
|---|---|
| Transport orders | ~15,000 / day |
| Shipments | ~20,000 / day (≈1.3 per order) |
| Trips (vehicle runs) | ~6,000 / day |
| Shipment status events | ~160,000 / day (≈8 per shipment) |
| Carrier messages (status, [ETA](https://en.wikipedia.org/wiki/Estimated_time_of_arrival "Estimated Time of Arrival — Predicted time a vehicle or shipment reaches its destination"), proof of delivery, invoice) | ~250,000 / day |
| Cost lines | ~30,000 / day |

### DAU and QPS

- **[DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day"):** ~620 people (400 operational, 200 viewers, 20 analysts) plus ~150 carrier integrations.
- **`tms-api`:** 400 users × ~300 requests/day = 120,000/day → **~1.4 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") average, ~11 QPS peak** (8× during the morning dispatch window).
- **`carrier-gateway`:** 250,000 messages/day → **~2.9/s average, ~30/s peak** (10× when carriers flush batches).
- **RabbitMQ:** ~450,000 messages/day in total (carrier plus domain events) → **~5/s average, ~50/s peak**. This is far below one broker node's capacity; the cluster exists for availability, not throughput.
- **Dashboards:** ~200 viewers × 15 page views × 6 visuals ≈ 18,000 queries/day, mostly answered from the import cache. The near-real-time page adds ~3 queries/s against `nrt` tables at peak (50 viewers, 1-minute refresh, 4 visuals).

### Daily batch volume

One nightly run extracts the day's delta (~0.5–1 million rows across sources) plus a **7-day reprocessing window** of status events (~1.1 million rows) for late carrier data. That is a few million rows per night, all moved with set-based [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") and `COPY`, never row by row.

### 5-year storage

| Store | Growth | 5 years |
|---|---|---|
| `tms_db` ([PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees")) | ~240 MB/day with indexes | ~440 GB |
| `ext_hub` (Oracle) | ~750 MB/day of raw [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") payloads; 2 years kept, older archived to [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") | ~550 GB steady state |
| `analytics_dwh` (PostgreSQL) | core facts, marts, 14 days of staging, indexes | ~0.6 TB |
| S3 `lp-landing` and `lp-archive` | ~1 GB/day of files and extracts; lifecycle to archive storage after 90 days | ~1.8 TB |

Every store fits a single database node for the five-year horizon, which is why `03-data-modeling.md` partitions but does not shard.

---

## Assumptions and Open Questions

- **Oracle is pre-existing.** The brief uses Oracle only to analyse variable-shape data from external transport systems. The design treats `ext_hub` as an existing integration hub where partner feeds already land, not as a store chosen for this platform.
- **"[AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") ([RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover"), CloudWatch, S3 and others)"** leaves the compute and scheduling services open. The design uses [ECS](https://aws.amazon.com/ecs/ "Amazon Elastic Container Service — Managed container orchestration on AWS; with Fargate it runs containers without managing servers") Fargate, EventBridge Scheduler, Amazon MQ for RabbitMQ, [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") and Secrets Manager, and flags each one where it is introduced.
- **Jurisdiction is not stated.** `06-security.md` names the decision it forces for personal data.
- **No volumes are stated.** Every figure above is an assumption to validate against real order counts.
