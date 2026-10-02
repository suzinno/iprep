# Responsibility Questions — Smart Healthcare System (IoT)
> Auto-generated from the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") brief. Questions use only what the CV states; answers draw on the system design documents.
> Some sections go past the three-question cap. The extra questions either come from a supplied technical question bank or were generated on request.

## Table of Contents
- [R1. Architecture — Services and database structure](#r1-architecture--services-and-database-structure)
- [R2. Architecture — Choosing the stack](#r2-architecture--choosing-the-stack)
- [R3. Databases — Queries and stored procedures](#r3-databases--queries-and-stored-procedures)
- [R4. Databases — Indexes and raw query tuning](#r4-databases--indexes-and-raw-query-tuning)
- [R5. Messaging — RabbitMQ between services](#r5-messaging--rabbitmq-between-services)
- [R6. Data and AI pipelines — ChatGPT expert chatbot](#r6-data-and-ai-pipelines--chatgpt-expert-chatbot)
- [R7. Data and AI pipelines — NumPy array work](#r7-data-and-ai-pipelines--numpy-array-work)
- [R8. Data quality — Pandas normalization and inspection](#r8-data-quality--pandas-normalization-and-inspection)
- [R9. Security — OAuth authentication](#r9-security--oauth-authentication)
- [R10. Cloud — Kubernetes disaster recovery](#r10-cloud--kubernetes-disaster-recovery)
- [R11. Cloud — Terraform for Azure](#r11-cloud--terraform-for-azure)
- [R12. Cloud — Blob Storage for files](#r12-cloud--blob-storage-for-files)
- [R13. Cloud — Azure Functions](#r13-cloud--azure-functions)
- [R14. Cloud — AKS cluster setup](#r14-cloud--aks-cluster-setup)
- [R15. Cloud — Cluster health and troubleshooting](#r15-cloud--cluster-health-and-troubleshooting)
- [R16. CI/CD — Faster pipelines](#r16-cicd--faster-pipelines)
- [R17. Testing and observability — Service monitoring](#r17-testing-and-observability--service-monitoring)
- [R18. Testing and observability — Logging in Grafana](#r18-testing-and-observability--logging-in-grafana)

---

## R1. Architecture — Services and database structure

> Designing the overall structure and schema of the databases and microservices, and ensuring that they are scalable, secure, and easy to maintain;

---

### Q1. How did you decide where to draw the boundaries between your microservices?

**Brief answer**
I split services along the platform's responsibilities and along how much failure each path could tolerate. The clinical alert path got its own small services, so a slow part elsewhere could not delay an alert.

<details>
<summary><strong>Must cover</strong></summary>

- **three request paths** — telemetry, alert and staff, kept apart by failure tolerance
- **processor split from the writer** — two consumers of one stream
- **no synchronous calls between services**
- **views and message contracts** — become interfaces, tested in CI
- care-core on Django, robot and assistant off the alert path, split by table

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The platform had three request paths with different failure tolerance. The telemetry path takes vital signs from ward gateways. The alert path turns a bad reading into a push notification to a nurse. The staff path serves dashboards, the transport robot and the assistant. I kept these paths apart wherever their tolerance differed.

That gave these services:

- `care-core` runs on Django and owns patients, admissions, beds, devices and thresholds. It is the richest relational model, and ward managers need an admin UI for it.
- `telemetry-service` accepts gateway uploads and serves vitals reads.
- `vitals-processor` evaluates alert rules. `vitals-writer` stores raw frames. They are two separate consumers of the same stream.
- `alert-service` owns the alert lifecycle and escalation. `notification-service` sends the pushes.
- `robot-service` and `assistant-service` are side features, so they sit off the alert path.
- Two Azure Functions apps run scheduled and event-driven calculations.

The most important choice is the processor split from the writer. Raw storage in Cosmos DB can throttle. If one consumer did both jobs, a slow write would sit in front of rule evaluation. With two queues, the writer can fall minutes behind while alerts stay inside their 5-second budget.

I also kept one rule: no synchronous calls between services inside the cluster. A service that needs another service's data reads a published view or consumes an event. In a request chain, one slow service stalls every caller. The cost is that views and message contracts become interfaces. Their owners test them in Continuous Integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Automatically builds and tests code on every change")).

What I avoided is a split by table. A service per table gives you distributed joins and chatty calls, but none of the isolation.

</details>

---

### Q1. What data integrity mechanisms does PostgreSQL provide?

**Brief answer**
Constraints that reject bad rows whatever code writes them, transactions and row locks that keep related changes together, and the Write Ahead Log underneath for durability. I used all three, and added grants as a fourth layer.

<details>
<summary><strong>Must cover</strong></summary>

- **constraints** — reject bad data whatever code writes it
- **CHECK constraints** — rules on one row
- **partial unique indexes** — rules for a subset of rows
- **one transaction** — the update and its history row
- **WAL** — written before the commit is confirmed
- **insert-only** — audit rows cannot be changed
- **foreign keys stop at the schema boundary**
- UNIQUE on natural identifiers, generated column, row locks, synchronous standby

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I think of PostgreSQL integrity in four layers.

**Constraints.** They reject bad data at write time, whatever code writes it. That matters when several services and migration jobs touch one server.

- Primary keys, and foreign keys inside one schema. For example, `care.admission` references `care.patient` and `care.bed`.
- `UNIQUE` constraints on natural identifiers: the patient's `mrn`, the device `serial` and the staff member's `entra_object_id`.
- CHECK constraints for rules on one row. On `care.alert_threshold`, exactly one of `ward_id` and `admission_id` is set. Another check keeps `sustain_s` between 0 and 60.
- Partial unique indexes for rules that apply to a subset of rows. They allow one active admission per bed, one open binding per device, and one unresolved alert per `dedup_key`.
- A generated column. The database computes `kb.chunk.content_tsv` from the chunk text, so the search vector cannot drift from the text.

**Transactions and locks.** `alerting.acknowledge_alert` updates the alert and inserts its history row in one transaction. Either both rows change or neither does. The conditional `UPDATE` also takes a row lock, so two nurses cannot both acknowledge one alert. The stored procedure questions cover that race.

**Durability.** PostgreSQL writes every change to the Write Ahead Log (WAL) before it confirms the commit. So a crash after the commit loses nothing. The server also has a synchronous standby in another zone, so a zone loss loses no committed data.

**Grants.** The audit table is insert-only for every writer. No service can change or delete a past audit row.

There is one honest limit. Foreign keys stop at the schema boundary. `alerting.alert.patient_id` is a logical reference, because a foreign key across owners would couple their migrations. Between services, integrity comes from events, published views and idempotent writes.

</details>

---

### Q2. How did you stop one microservice from depending on another service's database tables?

**Brief answer**
Every service owned exactly one [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") schema, and no service wrote to another's schema. When a service needed another's data, it read a named view that the owner published as an interface, never the base tables.

<details>
<summary><strong>Must cover</strong></summary>

- **one schema per owning service**
- **published views** — the only way to read another service's data
- **no foreign keys across schemas** — they would couple migrations
- **grants enforce this** — per-component login, NOLOGIN owner role
- **views are contracts** — column stability tested in CI
- Entra ID object ID

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

All services share one PostgreSQL server, but each has its own schema: `care`, `alerting`, `notify`, `robotics`, `kb` and `telemetry`. The rule is one schema per owning service. A service never writes another service's schema.

For reads across services, the owner publishes views. For example, `care.v_device_binding` maps a device to its bed, admission and patient. `vitals-processor` and `telemetry-service` read that view. They never touch `care.device_binding` directly. So `care-core` can change its tables freely, as long as the view keeps its columns.

There are no foreign keys across schemas. `alerting.alert.patient_id` is a logical reference. A foreign key across owners would couple their migrations: one service could not deploy a schema change without the other. Integrity across schemas comes from events and from the views.

The database grants enforce this, so it is more than a convention. Each runtime component has its own PostgreSQL login, mapped to its managed identity. No runtime role owns a schema. Each schema is owned by a `NOLOGIN` owner role, and only that schema's migration job uses it. A service gets Data Manipulation Language ([DML](https://en.wikipedia.org/wiki/Data_manipulation_language "The SQL statements that read and change rows")) rights on its own schema and `SELECT` on named views only. A query against another schema's base table fails with a permission error.

One detail kept identity simple. Outside `care`, every table identifies a staff member by the Entra ID object ID from the access token. So a service can connect a caller to a push token or an audit row without asking `care-core`.

The trade-off is that views are contracts. A migration that changes a view must keep its columns stable, and the owner tests that in CI.

</details>

---

### Q2. How do you preserve "effective ACID" across microservices?

**Brief answer**
I did not stretch one transaction across services. Each invariant lives inside one service's local transaction, and services are joined by at-least-once messages and idempotent writes. That gives full guarantees inside a service and eventual consistency between services.

<details>
<summary><strong>Must cover</strong></summary>

- **local transaction** — every invariant inside one service
- **no two-phase commit and no saga**
- **at-least-once delivery** — every step may run more than once
- **idempotent** — safe to repeat on the receiving side
- **persist before notify**
- **eventual consistency** — readers see a slightly old state
- **no outbox table** — the escalation check covers the gap
- dedup_key, $addToSet, Idempotency-Key, 60-second access cache

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Full Atomicity, Consistency, Isolation, Durability ([ACID](https://en.wikipedia.org/wiki/ACID "Names the four guarantees a database transaction provides")) holds only inside one database transaction. Across services, I aimed for something weaker but predictable. Each service is fully transactional inside. Every step between services is safe to repeat.

**Atomicity: one local transaction per invariant.** I drew service boundaries so that every rule that must hold at once lives in one schema. Acknowledging an alert updates the row and writes its history in one local transaction. In this design, no step needed rows in two schemas to change together. So I used no two-phase commit and no saga.

**Consistency between services: repeatable steps.** Messages between services have at-least-once delivery, so every step may repeat. Every write on the receiving side is idempotent, which means safe to repeat:

- `alert-service` inserts with `ON CONFLICT (dedup_key) DO NOTHING`. A repeated event cannot open a second alert.
- `vitals-writer` uses a deterministic document ID and `$addToSet`. A replayed batch changes nothing.
- Ingest checks `batch_id` in Redis with `SET NX`. `POST` endpoints for missions and admissions accept an `Idempotency-Key`, which Redis holds for 24 hours.

The RabbitMQ questions cover how each message hop is made durable.

**Order of steps.** The rule is persist before notify. `alert-service` sends a push only after the alert row commits. A push for an alert that does not exist could not be acknowledged or escalated.

**Isolation between services.** Readers get eventual consistency and may see a slightly old state. Services read another service's data through published views, or through short caches. The patient access check is cached for 60 seconds.

**The gap I accepted.** There is no outbox table. A crash after the commit and before `notify.send` is sent could lose that first push. The escalation check covers it, because it reads the alert table itself. An unacknowledged alert still escalates on schedule, and the dashboard feed still shows it.

</details>

---

### Q2. How do you ensure backward compatibility in evolving APIs?

**Brief answer**
Every interface was a versioned contract that changed only by adding. That covered the HTTP paths, the Pydantic message contracts and the published database views. Old and new code must run side by side during a canary.

<details>
<summary><strong>Must cover</strong></summary>

- **add, never break** — inside one version
- **/api/v1** — versioning at API Management
- **versioned Pydantic contracts** — the version is in the name
- **schema header** — names the contract of each message
- **optional field** — ward_id in AlertRaisedV1
- **views keep their columns** — tested in CI
- **old and new versions run together** — during a canary
- DRF serializers, send_task by name, expand-then-contract

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The system had three kinds of interfaces. Each followed one rule: add, never break.

**Hypertext Transfer Protocol (HTTP) APIs.** Staff endpoints sit under `/api/v1`, and gateway ingest sits under `/ingest/v1`. API Management handles the versioning at the edge. Pydantic validates bodies in the Flask services, and Django REST Framework (DRF) serializers validate them in `care-core`. Inside one version, I only added new endpoints and optional fields. A change that removes or renames a field needs a new version path.

**Messages between services.** These are versioned Pydantic contracts in a shared `contracts` package, and the version is in the name: `VitalsBatchV1`, `AlertRaisedV1`. Every message also carries a schema header that names its contract. So a consumer knows which model to parse. The additive rule applies here too. For example, `ward_id` is an optional field in `AlertRaisedV1`, because `func-analytics` knows only the admission. `alert-service` fills a missing `ward_id` from a view. Celery commands are called by name with `send_task("notify.send", …)`. No service imports another's code, and the task arguments are a Pydantic contract as well.

**Database views.** Services read each other's data only through published views, such as `care.v_device_binding`. A `care` migration must keep the view's columns stable. So the views keep their columns, and the view's owner tests that in Continuous Integration (CI).

Why this matters: during a canary, old and new versions run together. For queue workers, one new replica joins the old consumers on the same queue. Both versions read the same messages, so neither version may break the other. Schema migrations follow expand-then-contract for the same reason.

CI also protects consumers. A change to `contracts/` selects every service that imports it. Every consumer builds and tests against the new contract before the merge.

</details>

---

### Q2. What strategies do you use for zero-downtime schema migrations?

**Brief answer**
Every migration must work with the old and the new code, because both run during a rollout. So I used expand-then-contract: a release only adds, and removal waits for a later release. Migrations run as a Kubernetes Job before the new pods start.

<details>
<summary><strong>Must cover</strong></summary>

- **work with the old and the new code** — both run during a rollout
- **expand-then-contract** — removal waits for a later release
- **three releases** — for a column rename
- **Kubernetes Job** — before the new pods start
- **owner role** — runtime roles cannot run DDL
- **views keep their columns**
- **CREATE INDEX CONCURRENTLY**
- **lock timeout**
- Django migrations, Alembic, create_next_partitions, backfill in batches

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The core rule is simple. Every migration must work with the old and the new code. During a rollout, old and new pods run at the same time. A rollback must also work without a down-migration.

**Expand-then-contract.** A release only adds: new columns, tables or views. Removal waits for a later release, when no running code uses the old shape. A column rename, for example, takes three releases:

1. Add the new column. The code writes both columns and reads the old one. Old rows are backfilled in batches.
2. Switch reads to the new column.
3. Drop the old column, once no running image reads it.

Each step can be rolled back on its own.

**Where migrations run.** A Kubernetes Job runs them before the new pods start. Each schema has one owner. Django migrations cover `care` and `audit`. Alembic covers every other schema, and each migration history lives with its owning service. The job acts as the schema's owner role. Runtime roles own nothing, so they cannot run Data Definition Language (DDL) by mistake.

**Views as the stable layer.** Other services read `care` data only through published views. A migration can reshape the base tables, as long as the views keep their columns. CI tests that.

**Partitions.** Scheduled routines such as `create_next_partitions` create the next period's partitions ahead of time. So no insert waits for DDL at a month boundary.

**Locks.** Expand-then-contract does not solve locking. Some DDL takes a strong table lock. A plain `CREATE INDEX` blocks writes to the table until it finishes. On a busy table such as `alerting.alert`, CREATE INDEX CONCURRENTLY avoids that. It is slower and cannot run inside a transaction. A lock timeout on the migration session also matters. Without it, an `ALTER TABLE` can queue behind a long query, and every new query then queues behind the `ALTER TABLE`.

</details>

---

### Q2. What are MongoDB sharding pitfalls?

**Brief answer**
Almost every pitfall comes from the shard key. Queries can miss it, a key can send all writes to one place, and a key is hard to change later. Our raw frames ran on Cosmos DB for MongoDB with the shard key `patientId`, chosen to match how the data is read.

<details>
<summary><strong>Must cover</strong></summary>

- **Cosmos DB for MongoDB** — the service manages physical partitions
- **scatter-gather query** — when a query lacks the shard key
- **patientId** — every read is one patient
- **hot partition** — a time key sends all writes to one value
- **20 GB** — the logical partition limit
- **unique index must include the shard key**
- **hard to change later**
- jumbo chunks, HTTP 429, TTL only on _ts, Docker Compose

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

First, what I actually ran. Raw frames lived in Cosmos DB for MongoDB, not in a self-run sharded MongoDB cluster. Cosmos DB hashes the shard key into logical partitions and manages the physical partitions itself. So I had no config servers, routers or balancer to operate. Locally we ran plain MongoDB in Docker Compose. The main pitfalls are the same in both, because they come from the shard key.

**A key that does not match the reads.** A query without the shard key goes to every partition. This is a scatter-gather query. On Cosmos DB it also costs more Request Units (RU). Every read of `vitals_raw` is one patient's timeline, so I chose `patientId`. Every query then targets one logical partition.

**A hot partition.** A key on time, such as `windowStart`, would send all current writes to one value. A key on `gatewayId` would give only about 40 values, each carrying a whole ward. With `patientId`, writes spread across about 1,200 monitored patients. Each patient writes about 0.1 documents per second.

**Partition size.** A Cosmos DB logical partition holds at most 20 GB. One patient writes about 15 MB a day, and Time To Live (TTL) expiry keeps 30 days. So each partition stays far below the limit. In self-run MongoDB, the matching risk is jumbo chunks from a key with too few values.

**Uniqueness.** A unique index must include the shard key, because each shard checks uniqueness only for its own data. Our `_id` is built from `patientId` and `windowStart`. A redelivered message therefore upserts into the same document.

**Throttling.** On Cosmos DB, a burst above the throughput budget returns Hypertext Transfer Protocol (HTTP) 429. The writer's queue absorbs that, so alerts are not affected.

**TTL detail.** The RU-based MongoDB API supports a TTL index only on `_ts`, not on a custom date field. I had to confirm that before relying on expiry.

**A key is hard to change later.** On Cosmos DB, a new key means copying the data into a new collection. So I checked the key against the retention period and growth before the first write.

</details>

---

### Q3. How would your database design change at ten times the current load?

**Brief answer**
Not much at first, because I set evolution triggers instead of scaling early. The first real step would be moving the telemetry schema to its own PostgreSQL server; the raw-frame store and the services already scale out.

<details>
<summary><strong>Must cover</strong></summary>

- **evolution triggers** — the next step is decided by measurement
- **split the telemetry schema** — CPU above 70% for a week, or 2 TB
- **shard key patientId** — every read hits one partition
- **time-range partitioning** — retention is a partition drop
- **single PostgreSQL primary** — keeps alert ownership strictly consistent
- 4,000 RU/s ceiling, Redis clustering, stateless workers

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I sized the design for about 1,200 monitored beds. At that size PostgreSQL stays below about 200 GB, with a few hundred writes per second. One General Purpose server handles that easily, so I did not shard it. Instead I wrote down evolution triggers, so the next step is decided by measurement.

At ten times the load, this is what changes:

- **PostgreSQL.** The trigger is primary CPU above 70% for a week, or storage above 2 TB. The first move is to split the `telemetry` schema onto its own server. Each service owns one schema and reads other schemas only through views, so that is a move, not a rewrite.
- **Raw telemetry in Cosmos DB.** The shard key is `patientId`. Every read is one patient's timeline, so every query hits one logical partition. One patient writes about 15 MB per day, so 30 days stay far below the 20 GB partition limit. More beds means more partitions, not bigger ones. A Request Unit ([RU](https://learn.microsoft.com/en-us/azure/cosmos-db/request-units "Azure Cosmos DB's currency for provisioned throughput, charged per request regardless of operation type")) is Cosmos DB's unit of throughput, and the autoscale ceiling of 4,000 RU/s would need raising.
- **Time-range partitioning** on the rollup and audit tables keeps retention cheap at any size. Retention is a partition drop, not a mass delete.
- **[Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store")** is not clustered, because the working set is under 1 GB. The trigger for clustering is memory above 70% of the tier.
- **Services and workers** are stateless. Queue workers scale on queue depth, so they grow with load.

The weak point at 10x is the single PostgreSQL primary for clinical writes. I chose one primary with a synchronous standby, so two nurses can never both own an alert. Sharding clinical data would break that simple guarantee. So I would split by schema long before I split by patient.

</details>

---

### Q3. How do you design for peak traffic events? When did peaks appear in your project?

**Brief answer**
With headroom in the capacity plan, queues that absorb bursts, and limits per client so one caller cannot take all capacity. The largest peak in this system is the replay after a hospital network outage, not a busy hour.

<details>
<summary><strong>Must cover</strong></summary>

- **design targets** — no measured production peak to quote
- **2× peak headroom** — about 600 requests per second
- **replay after an uplink outage** — about 25 minutes for 24 hours
- **WAF limit** — 2× headroom over the replay peak
- **queues absorb bursts**
- **limits per client** — per user, per gateway
- 3× without redesign, old frames raise no alerts, Redis for dashboards, 4,000 RU/s

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

First, an honest point. The numbers here are design targets. The brief gives no measured traffic, so I have no measured production peak to quote.

**Capacity plan.** Peak traffic at the edge is about 300 requests per second. Dashboards, the alert feed and gateway ingest make up most of it. The plan sizes for 2× peak headroom, about 600 requests per second. The scalability target is 3× the current load without a redesign.

**Where peaks appear.**

1. **Replay after an uplink outage.** This is the largest peak. A gateway buffers up to 24 hours on disk. When the network returns, it replays in order. Each batch packs up to 60 seconds of frames, at one extra request per second. So 24 hours of backlog clears in about 25 minutes, without a burst of requests. The Web Application Firewall (WAF) allows 2,400 requests per minute per hospital IP address. That WAF limit keeps 2× headroom over the replay peak. Frames older than 120 seconds raise no alerts, so a replay cannot flood nurses with alerts about the past.
2. **Dashboards.** About 400 dashboard sessions are open at peak, and each polls the latest vitals every 3 seconds. Those reads come from Redis, so they add no load to PostgreSQL.

**How the design absorbs a peak.**

- **Queues absorb bursts.** RabbitMQ holds the burst, and the alert latency budget leaves about 3 seconds of headroom. Workers scale on queue depth, as the AKS questions explain.
- **Slow consumers stay off the alert path.** Under Cosmos DB throttling, the writer can fall minutes behind while alerts stay on budget.
- **Limits per client.** API Management allows 300 calls per minute per user, and 20 assistant questions per minute. `telemetry-service` limits each gateway to 5 batches per second. One faulty client cannot take capacity from the others.
- **Throughput with room.** Cosmos DB autoscales up to 4,000 Request Units (RU) per second. Normal writer load is about 1,800 RU per second.

</details>

---

### Q3. How do you distinguish a "distributed monolith" from true microservices in practice? What are the first warning signs that a system is drifting back into one?

**Brief answer**
A distributed monolith has service boundaries on paper but stays coupled at runtime or at release time. My test is whether one service can change, deploy and fail without the others. The first warning signs are synchronous call chains, shared tables and releases that must happen in a fixed order.

<details>
<summary><strong>Must cover</strong></summary>

- **deploy alone** — no fixed release order
- **fail without stopping the others**
- **synchronous call chains** — one slow service stalls every caller
- **own its data** — no shared tables
- **warning signs** — one feature touches several services
- **shared packages** — deliberate, but each addition couples more services
- **one PostgreSQL server** — a shared failure domain, not a shared model
- availability multiplies, ward_census exception, change detection in CI

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I use three practical tests.

1. **Can one service deploy alone?** If a change needs several services released together, in a set order, they are one system split across processes. Here each service has its own image. CI builds only what changed. Expand-then-contract migrations mean no release depends on another going first.
2. **Can one service fail without stopping the others?** The main risk is synchronous call chains. One slow service stalls every caller, and availability multiplies down the chain. This system has no synchronous calls between services inside the cluster. If `care-core` is down, the alert path still runs. Thresholds and bindings come from Redis and from published views.
3. **Does each service own its data?** Shared tables are the other main coupling. Each service owns one schema and reads others only through views. The schema question above covers how grants enforce that.

**Warning signs** I watch for:

- One feature touches several services in the same pull request.
- A new synchronous call appears "just for one lookup".
- A view or message change breaks a consumer at deploy time.
- A shared library starts to hold business logic.
- Services can only be tested all together.

**Where drift could start here.** I see two places.

- **Shared packages.** `contracts` and `vitals_rules` are shared, and a change to either selects every importing service in CI. That is deliberate. The National Early Warning Score 2 (NEWS2) must score the same in the processor and in the rollups. But each addition to a shared package couples more services, so I kept them small.
- **One PostgreSQL server.** All schemas sit on one PostgreSQL server. That is a shared failure domain and a shared capacity limit, but not a shared model. The evolution trigger to move the `telemetry` schema to its own server is the way out.

There is also one documented exception. `care.ward_census` reads `alerting.alert` through its owner role, only to count open alerts. I kept such exceptions few and named.

</details>

---

### Q3. What trade-offs do you face between consistency and availability?

**Brief answer**
I chose per data type, not once for the whole system. Alert state is consistency first: a write that cannot reach the primary fails rather than diverges. Raw telemetry and latest values are availability first: the platform keeps accepting data, and readers may see values a few seconds old.

<details>
<summary><strong>Must cover</strong></summary>

- **per data type** — by what a wrong answer costs
- **consistency first** — a write fails rather than diverges
- **failover** — new notifications wait up to about 2 minutes
- **availability first** — gateways keep buffering
- **data-age indicator**
- **PACELC** — latency against consistency without a partition
- **write-through** — a threshold change applies on the next batch
- **fails open** — the audit log can over-count, never under-count
- synchronous standby, 60-second access cache, sustain windows restart, asynchronous cross-region replica

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The Consistency, Availability and Partition tolerance ([CAP](https://en.wikipedia.org/wiki/CAP_theorem "Names the theorem that a distributed system can guarantee only two of the three during a network partition")) theorem says a system must choose during a network partition. I made that choice per data type, based on what a wrong answer would cost.

**Alert state: consistency first.** Clinical records, alerts and acknowledgements live on one PostgreSQL primary with a synchronous standby in another zone. Two nurses must never both believe they own an alert. So a write that cannot reach the primary fails rather than diverges. The price is paid during a failover, which takes 60 to 120 seconds. `alert-service` persists an alert before it notifies anyone, so new notifications wait up to about 2 minutes. I accepted that. Bedside alarms stay primary, and alerts wait in their queue instead of being lost.

**Telemetry: availability first.** Gateways keep buffering, and the platform accepts data during partial failures. Latest values in Redis may be a few seconds old. The dashboard shows a data-age indicator, so a nurse sees the delay instead of trusting old numbers.

**Without a partition.** The Partition, Availability, Consistency, Else Latency, Consistency ([PACELC](https://en.wikipedia.org/wiki/PACELC_design_principle "Extends CAP by naming the latency against consistency trade that applies when there is no partition")) model extends CAP. Even when nothing fails, you trade latency against consistency. The telemetry path takes low latency: latest values come from Redis. The alert state path does not make that trade.

**The same trade in caches.**

- Thresholds use write-through to Redis. A nurse's tighter limit must apply on the next batch, so a stale threshold is a safety risk.
- The patient access check uses a 60-second cache. A roster change can take up to 60 seconds to apply. That delay is accepted for faster reads.
- If Redis fails, thresholds and bindings fall back to PostgreSQL views. Sustain windows restart, which delays sustained-condition alerts by at most their window.

**When a guard is unavailable.** The audit guard fails open. If Redis is down, every access is logged. So the audit log can over-count, but never under-count.

**Across regions.** The cross-region read replica is asynchronous. A region loss can therefore lose up to 5 minutes of clinical writes. A synchronous cross-region write would add the cross-region network delay to every commit.

</details>

---

## R2. Architecture — Choosing the stack

> Identifying the appropriate technology stack and tools to use for the design and implementation of microservices;

---

### Q1. Your stack lists both Django and Flask. How did you decide which framework a service should use?

**Brief answer**
Django with Django [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") Framework went where the data model was rich and staff needed an admin UI. Flask went to small, focused services with a handful of endpoints each.

<details>
<summary><strong>Must cover</strong></summary>

- **Django only for care-core** — rich relational model, CRUD-heavy
- **Django admin** — configuration UI for ward managers
- **DRF permission classes** — hold the patient access check
- **Flask for small services** — about five endpoints each
- **SQLAlchemy and Alembic** — not tied to a Django project
- **one language** — shared contracts package
- care_access decorator, FastAPI

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used Django only for `care-core`. It owns hospitals, wards, beds, patients, admissions, staff, devices and thresholds. That is a Create, Read, Update, Delete ([CRUD](https://en.wikipedia.org/wiki/Create,_read,_update_and_delete "Names the four basic operations of persistent storage")) heavy model with many foreign keys. Django gave three things I would otherwise build myself:

- The Django admin gave ward managers a configuration UI for free.
- Django REST Framework ([DRF](https://www.django-rest-framework.org/ "Toolkit for building REST APIs on Django with serializers and permission classes")) serializers validated input.
- DRF permission classes held the patient-level access check.

I used Flask for small services: telemetry, alerts, notifications, robots and the assistant. Each has about five endpoints, and Django would be too much framework for that. These services used [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") for data access and [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") for migrations. I did not want the Django Object Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Maps application objects to relational database rows and queries")) there, because it ties migrations to a Django project.

Two things kept the mix manageable:

- **One language.** Everything was Python, including workers, Functions and the gateway agent. So shared code lives in one place: a `contracts` package with [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models for messages, and a `vitals_rules` package for alert scoring.
- **One access rule, two adapters.** `care-core` checks patient access with a DRF permission class. The Flask services use a `care_access` decorator from the same package. So the rule has one implementation.

I considered [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"). It fits small typed APIs well, but it has no admin UI, and `care-core` needed one. For the small services, Flask with Pydantic already gave me typed validation.

The cost of two frameworks is two sets of conventions: two migration tools and two test setups. I accepted that, because each framework matched its service's shape.

</details>

---

### Q2. Why did you run more than one database engine, and how did you decide which data went into which?

**Brief answer**
Each store matched one access pattern. PostgreSQL held everything that needed transactions and constraints, Cosmos DB for [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") held the high-volume raw frames, and Redis held the hot values the alert path read on every batch.

<details>
<summary><strong>Must cover</strong></summary>

- **access pattern** — and what a failure would cost
- **PostgreSQL as the system of record** — transactions and constraints
- **Cosmos DB for MongoDB** — otherwise about 100 million rows a day
- **Redis** — read by the alert path on every batch
- **Azure SQL Database got no role**
- **no cross-store transactions**
- pgvector, vacuum and WAL, Docker Compose

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I chose by access pattern and by what a failure would cost.

- **PostgreSQL** is the system of record: patients, admissions, alerts, missions, rollups, audit and the assistant's corpus. These need transactions and constraints. For example, a conditional update makes sure two nurses cannot both acknowledge one alert. PostgreSQL also gave me stored procedures, partitioning and `pgvector` search in the same engine.
- **Cosmos DB for MongoDB** holds raw one-second frames for 30 days. That is about 1,200 frames per second, or about 100 million rows a day if stored in PostgreSQL. That much short-lived data would dominate vacuum, Write Ahead Log ([WAL](https://www.postgresql.org/docs/current/wal-intro.html "Sequential log written before data pages so committed transactions survive a crash")) and backup on the system-of-record server. Cosmos DB gave native Time To Live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Duration after which a cached or stored value expires")) expiry and autoscaling throughput. Locally we ran MongoDB in Docker Compose.
- **Redis** holds latest vitals, rule windows, and caches of thresholds and device bindings. The alert path reads these on every batch, so reads must take under a millisecond.

The CV also lists Azure [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") Database. Honestly, it got no role. PostgreSQL met every relational need, and we already used it for stored procedures and index tuning. A second relational engine would double backup, disaster recovery and tuning work for no gain. If a hospital system had offered data only through Azure SQL Database, I would read it with an integration job, not adopt it as a store.

The cost of several stores is more to operate, and no cross-store transactions. So I kept the ingest path simple: `telemetry-service` never writes to PostgreSQL on ingest. Raw frames go to Cosmos DB and latest values to Redis, each written by its own consumer.

</details>

---

### Q3. How did you choose between a managed Azure service and running a tool yourself on Kubernetes?

**Brief answer**
I defaulted to managed services and ran a tool myself only when the managed option could not do a job the design needed. [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") was the main exception, because it was the [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") broker and gave native topic routing.

<details>
<summary><strong>Must cover</strong></summary>

- **default to managed services** — every self-run component needs patching and paging
- **RabbitMQ on AKS** — Celery broker, native topic routing
- **AKS instead of Azure Container Apps** — control over the broker and the mesh
- **Azure Functions** — replaced Kubernetes CronJobs
- **operator** — with definitions in Terraform
- Loki and Jaeger, tainted node pool, Azure Backup for AKS

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I default to managed services, because every self-run component is something the team must patch, back up and get paged for. So PostgreSQL ran on Azure Database for PostgreSQL Flexible Server, Redis on Azure Cache for Redis, and raw frames on Cosmos DB. Metrics went to Azure Monitor managed service for Prometheus, and dashboards to Azure Managed Grafana. For logs and traces I used Log Analytics and Application Insights instead of running Loki and Jaeger.

I ran something myself only for a concrete reason:

- **RabbitMQ on [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") instead of Azure Service Bus.** Service Bus is managed. But Celery already used RabbitMQ as its broker, and topic routing is native in RabbitMQ. I ran it as a three-node cluster with quorum queues, on its own tainted node pool.
- **AKS instead of Azure Container Apps.** Container Apps is simpler, but it gives less control over RabbitMQ and the service mesh, and I needed both. Azure [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Service (AKS) gave that control.

The same test worked in the other direction. Azure Functions replaced Kubernetes CronJobs for scheduled calculations. Functions gave a native blob trigger for document ingest, and they kept batch CPU off the alert-path nodes.

The trade-off with a self-run RabbitMQ is real. Its upgrades, disk alarms and backups are our job. I reduced that work with the RabbitMQ Cluster Kubernetes Operator, which runs the cluster and its upgrades. The operator is backed by PodDisruptionBudgets, definitions in [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files"), and Azure Backup for AKS on the broker's volumes.

</details>

---

### Q3. How do you balance cost vs performance in data stores?

**Brief answer**
I sized each store from capacity estimates and paid for speed only on the paths that needed it. Batching cut the Cosmos DB bill, downsampling kept history cheap, and PostgreSQL and Redis were scaled only at named thresholds.

<details>
<summary><strong>Must cover</strong></summary>

- **capacity estimates** — before any price
- **Redis Premium** — sub-millisecond reads for the alert path
- **Request Units** — the write pattern sets the bill
- **one upsert per window** — about 1,800 RU/s
- **autoscale ceiling** — 4,000 RU/s
- **downsampled** — rollups and compressed archives
- **no sharding** — one server fits about 200 GB
- **evolution triggers** — scale at a named threshold
- Parquet, cool and archive tiers, list price

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from capacity estimates, not from the price list. The design had an estimate for every store. Then I paid for speed only where a query on a critical path needed it.

**Speed where the alert path reads.** Latest values, rule windows and the threshold caches live in Redis Premium, zone-redundant. The alert path reads them on every batch, so sub-millisecond reads were worth paying for.

**Raw frames in Cosmos DB, sized by batching.** Cosmos DB charges in Request Units (RU) for every operation. So the write pattern sets the bill. `vitals-writer` groups frames by patient and 10-second window, and makes one upsert per window. That is about 180 upserts a second at about 10 RU each, or about 1,800 RU/s. I set an autoscale ceiling of 4,000 RU/s. At list price, that is at most about $0.35k a month, plus about $0.1k a month for 450 GB. One write per frame would cost many times more.

**Short hot data, downsampled history.** Raw frames stay 30 days, with native Time To Live (TTL). One-minute rollups stay 90 days in PostgreSQL, and one-hour rollups stay 5 years. Older raw frames go to Blob Storage as Parquet, about 10:1 compressed, on the cool and then the archive tier. So the expensive stores hold only what dashboards and alerts read, and history is downsampled.

**One PostgreSQL server, no sharding.** PostgreSQL stays under about 200 GB. One General Purpose server with 8 vCores fits that with room to grow. Sharding would add cost and complexity for no gain. Instead, I wrote down evolution triggers. The `telemetry` schema moves to its own server when primary CPU stays above 70% for a week, or when storage passes 2 TB. Redis is not clustered either, because the working set is under 1 GB. Clustering starts when memory passes 70% of the tier.

The biggest storage cost was images, about 11 TB over five years, and Blob lifecycle tiers handled that. One honest limit: these are design estimates at list price, not a measured bill.

</details>

---

## R3. Databases — Queries and stored procedures

> Developing optimized SQL queries and stored procedures for PostgreSQL;

---

### Q1. When did you put logic in a PostgreSQL stored procedure instead of in the application?

**Brief answer**
Only when the database had to decide something atomically, or when one set-based statement could replace many round trips. Business rules such as alert scoring stayed in Python.

<details>
<summary><strong>Must cover</strong></summary>

- **atomic with the data** — or removes many round trips
- **conditional update** — the concurrency control
- **FOR UPDATE SKIP LOCKED**
- **one statement per rollup run** — replaces about 6,000 round trips
- **ward_census** — one query per ward, not per bed
- **NEWS2 in a Python package** — shared by the processor and the rollups
- jsonb_to_recordset, partition maintenance, harder to unit test

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used a short test. Logic goes into the database when it must be atomic with the data, or when it removes a large number of round trips. Otherwise it stays in the service, where it is easier to test, version and read.

These routines passed the test:

- `alerting.acknowledge_alert` runs a conditional update and writes the history row in one round trip. The conditional update is the concurrency control.
- `alerting.claim_due_escalations` and `robotics.assign_next_mission` pick work with `FOR UPDATE SKIP LOCKED`. Both are races between concurrent processes.
- `telemetry.upsert_minute_rollups` takes one JavaScript Object Notation ([JSON](https://www.json.org/json-en.html "Lightweight text format for structured data exchange")) array. It unpacks the array with `jsonb_to_recordset` into a single `INSERT … ON CONFLICT`. One statement per rollup run replaces about 6,000 round trips.
- `care.ward_census` returns beds, admissions, patient summaries and open alert counts in one query per ward, not one per bed.
- Partition maintenance routines create the next period's partitions and drop expired ones.

What stayed out: the National Early Warning Score 2 ([NEWS2](https://www.rcp.ac.uk/improving-care/resources/national-early-warning-score-news-2/ "Scores routine vital signs to detect clinical deterioration in adult patients")) and the threshold rules. NEWS2 lives in a Python package, `vitals_rules`. The live processor and the rollup function both import it, so the score on a trend chart is the score that raised the alert. Clinical rules change and need unit tests. A stored procedure would hide them inside a migration.

Stored procedures have real costs. They are harder to unit test, they are versioned through migrations, and they hide logic from people who read only the service code. So I kept each one small, with one job, and named it after that job.

</details>

---

### Q2. How did you stop two concurrent requests from changing the same row inside a stored procedure?

**Brief answer**
I made the `UPDATE` itself the check, with the allowed states in its `WHERE` clause, so only one caller can win. For work queues I used `FOR UPDATE SKIP LOCKED`, so concurrent workers never pick the same row.

<details>
<summary><strong>Must cover</strong></summary>

- **read-then-write race**
- **conditional statement** — allowed states in the WHERE clause
- **row lock** — the second caller re-checks and updates nothing
- **409 Conflict**
- **SKIP LOCKED** — concurrent workers take different rows
- **partial unique index on dedup_key**
- Celery beat overlap, SERIALIZABLE

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The clearest case was acknowledging an alert. Two nurses can tap "acknowledge" on the same alert at the same moment. A read-then-write in the application has a race. Both read `open`, both write `acknowledged`, and both believe they own the alert.

`alerting.acknowledge_alert` avoids that with one conditional statement: `UPDATE … WHERE alert_id = $1 AND status IN ('open','escalated')`. PostgreSQL takes a row lock for the update. The second caller waits for that lock. Then it re-checks the `WHERE` clause against the new row version, finds `acknowledged`, and updates nothing. The routine returns the row or nothing. The Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")) turns "nothing" into a 409 Conflict. The history row is written in the same transaction.

Work queues have a different problem. Several workers want different rows, not the same one.

- `claim_due_escalations` selects due alerts with `FOR UPDATE SKIP LOCKED`, then raises the level and sets the next deadline. If two Celery beat processes ever overlap, each skips the rows the other holds. So no alert escalates twice.
- `assign_next_mission` locks the oldest highest-priority queued mission and the idle robot with the most battery, both with `SKIP LOCKED`. Robot heartbeats and new requests both start an assignment, so the race is real.

I did not use `SERIALIZABLE` isolation here. It would work, but the application must then retry on serialization failures. These cases have a simpler row-level answer.

One more guard sits outside the procedures. A partial unique index on `dedup_key` for unresolved alerts turns a duplicate raise into a no-op with `ON CONFLICT DO NOTHING`. So even a replayed message cannot create a second open alert.

</details>

---

### Q3. How did you secure stored procedures so that each service could run them without getting wider database rights?

**Brief answer**
The routines are `SECURITY DEFINER`, owned by a no-login owner role, with a fixed `search_path`. A service gets only `EXECUTE` on the routine, so it can do exactly what the routine does and nothing more.

<details>
<summary><strong>Must cover</strong></summary>

- **NOLOGIN owner role** — used only by the migration job
- **SECURITY DEFINER** — runs with the owner's rights
- **EXECUTE only** — for the calling service
- **ward_census** — a count without a read grant on alerts
- **partition DDL** — needs ownership, kept out of runtime roles
- **fixed search_path** — blocks a caller's look-alike objects
- managed identity login, insert-only audit table

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Each schema is owned by a `NOLOGIN` owner role, such as `care_owner`. Only that schema's migration job uses it. Runtime services log in as their own roles and own nothing.

The stored procedures are declared `SECURITY DEFINER`. They run with the rights of their owner, not of the caller. A service receives `EXECUTE` on a routine, and the routine does the privileged work. So the service gets `EXECUTE` only, never the wider grant. Two examples:

- `care.ward_census` counts open alerts from `alerting.alert`. The owner role `care_owner` holds `SELECT` on that table. `care-core`'s runtime role never gets it. So the census can show the count, but `care-core` cannot read alerts freely.
- Changing partitions needs Data Definition Language ([DDL](https://en.wikipedia.org/wiki/Data_definition_language "The SQL statements that create and alter database objects")), the statements that create and change tables. Partition DDL needs table ownership. The routines `telemetry.create_next_partitions` and `audit.create_next_partitions` are owned by their schema owners. `func-analytics` only executes them. So DDL rights never reach a runtime role.

`SECURITY DEFINER` has one classic risk. If the function uses the caller's `search_path`, the caller can create an object with the same name in a schema it controls. The function then runs that object with the owner's rights. So every routine sets a fixed `search_path` in its definition.

This fits the wider design. Every component has its own PostgreSQL login, mapped to its managed identity. A grant table lists exactly what each component can touch. The audit table is insert-only for every writer, which protects its integrity. Stored procedures are the controlled way to allow one wider action without widening the role.

</details>

---

## R4. Databases — Indexes and raw query tuning

> Build indexes on SQL tables and optimization of existing raw queries.

---

### Q1. How did you find which raw queries needed optimizing?

**Brief answer**
By evidence, not by guessing. I reviewed `pg_stat_statements` weekly by total time, logged slow plans with `auto_explain`, and checked every fix with `EXPLAIN (ANALYZE, BUFFERS)` before and after.

<details>
<summary><strong>Must cover</strong></summary>

- **pg_stat_statements** — sorted by total time
- **auto_explain** — plans over 500 ms, from production
- **EXPLAIN (ANALYZE, BUFFERS)** — before and after each fix
- **sargable predicate**
- **change one thing**
- **each index costs on every write** — so it must serve a named query
- row estimates, sort spills, EXISTS

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from `pg_stat_statements`, reviewed weekly and sorted by total time. Total time matters more than the slowest single call. A 5 ms query that runs 200 times a second costs more than a 2-second report that runs once an hour.

For the plans, `auto_explain` logged the plan of any statement over 500 ms. That shows what the planner actually did in production, with real data and real parameters. A plan from a laptop often differs.

Each fix followed the same loop:

1. Take the plan with `EXPLAIN (ANALYZE, BUFFERS)`. `BUFFERS` shows how many pages the query read, so I can see whether the cost is disk reads or CPU.
2. Look for the usual causes. A sequential scan where an index range would do. Row estimates far from the real counts. Sort spills to disk. A predicate that is not sargable, such as `date_trunc()` wrapped around an indexed column. A sargable predicate compares the bare column, so the index can be used.
3. Change one thing: an index, a rewrite, or a statistics fix.
4. Run the same `EXPLAIN (ANALYZE, BUFFERS)` again and compare.

Some fixes were rewrites, not indexes. Access checks became an `EXISTS` query against `v_patient_access`, which stops at the first matching row.

The catch is that each index costs on every write. It also takes space and needs vacuum. So an index had to serve a named query. I did not add one "just in case".

</details>

---

### Q1. How do you choose the right index type in PostgreSQL?

**Brief answer**
From the operator the query uses. B-tree covers equality, ranges and sorting, so it is the default. GIN, BRIN and HNSW each serve one kind of query that a B-tree cannot serve well.

<details>
<summary><strong>Must cover</strong></summary>

- **the query's operator** — decides which index types can serve it
- **B-tree** — equality, ranges and ORDER BY
- **equality columns go first** — then the range or sort column
- **GIN** — many keys inside one value
- **pg_trgm** — a match in the middle of a string
- **BRIN** — only when physical order follows the column
- **HNSW** — approximate vector search
- encrypted-field lookup, partial on active chunks, EXPLAIN

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I choose from the query's operator, not from the column. Each index type supports a set of operators. The planner uses an index only if the query's operator is one of them.

**B-tree is the default.** It serves equality, ranges and `ORDER BY`. Most of my indexes were B-tree. One example is `care.patient (national_id_hmac)`. The national ID is encrypted, so the lookup is an exact match on a hash of it. A B-tree handles that equality well.

**In a composite B-tree, equality columns go first.** The range or sort column comes after them. `care.staff_ward_assignment (ward_id, shift_end)` answers "who is on duty on this ward now". The query uses equality on `ward_id`, then a range on `shift_end > now()`. `care.admission (patient_id, admitted_at DESC)` returns one patient's history already sorted. With the columns reversed, the planner could not jump straight to one patient.

**GIN for values with many keys inside.** A Generalized Inverted Index (GIN) maps each key to the rows that contain it. Full-text search on `kb.chunk.content_tsv` needs it, because one chunk holds many words. Name search also uses GIN, with `pg_trgm` on `care.patient.full_name`. A nurse types part of a name. A B-tree cannot serve a match in the middle of a string.

**BRIN only when the physical order follows the column.** A Block Range Index (BRIN) stores the lowest and highest value for each range of table blocks. It works on `vitals_minute.bucket_start`, because rows arrive in time order. On a column in random order, every block range would cover almost all values, and the index would skip almost nothing.

**HNSW for vector similarity.** The assistant's embeddings use a Hierarchical Navigable Small World (HNSW) index from `pgvector`, partial on active chunks. The search is approximate. That is the price of fast nearest-neighbour search over about 500,000 chunks.

Every new index then went through the same check with `EXPLAIN`. Each index also costs on every write, so it had to serve a named query.

</details>

---

### Q2. How did you decide to use a partial index rather than an index on the whole table?

**Brief answer**
When the queries only ever touch a small, well-defined subset of rows. Most alerts end up resolved, and the hot queries read only unresolved ones, so indexing only those rows keeps the index small and fast.

<details>
<summary><strong>Must cover</strong></summary>

- **only unresolved alerts** — the hot subset
- **keyset pagination**
- **partial unique index** — one open alert per dedup_key
- **NULLs never collide**
- **planner must prove** — the query repeats the index predicate
- one active admission per bed, BRIN, GIN with pg_trgm

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The alert table is the clearest example. Almost every alert ends up resolved, but the ward alert feed shows only live ones. So the feed index holds only unresolved alerts: `(ward_id, raised_at DESC, alert_id DESC) WHERE status <> 'resolved'`. The index stays small, so it is more likely to stay in memory.

The same index serves keyset pagination. `WHERE (raised_at, alert_id) < ($cursor_ts, $cursor_id)` reads one index range. `OFFSET n` would read and throw away n rows on every page.

Partial indexes also enforce rules that a full unique index cannot:

- **Deduplication.** A partial unique index on `dedup_key`, where the status is not resolved, allows only one open alert per key. A resolved alert with the same key does not block a new one. A unique key on (`admission_id`, `rule_code`) would not work. Ward-level alerts have no admission, and NULLs never collide in a unique index.
- **One active admission per bed** and **one open binding per device** work the same way.

Other partial indexes serve work queues. The escalation check reads `next_escalation_at` only for open or escalated alerts. The robot assignment reads only queued missions and idle robots.

The catch: the planner must prove that the query's `WHERE` clause implies the index predicate. Only then does it use a partial index. So the query must repeat the condition, written the same way. A query with `status IN ('open','acknowledged','escalated')` instead of `status <> 'resolved'` may not match. I checked each one with `EXPLAIN`.

Where a partial index did not fit, I used another type. A Block Range Index ([BRIN](https://www.postgresql.org/docs/current/brin.html "Compact PostgreSQL index type suited to large, sequentially correlated tables")) serves range scans on time-ordered columns. A Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) with `pg_trgm` serves search by part of a name.

</details>

---

### Q2. What is table bloat? Why does it happen, and how do you deal with it?

**Brief answer**
Bloat is space held by dead row versions that PostgreSQL keeps after updates and deletes until vacuum cleans them. I dealt with it mostly by design: no mass deletes, high-churn data outside PostgreSQL, and fewer updates per row.

<details>
<summary><strong>Must cover</strong></summary>

- **MVCC** — an update writes a new row version
- **dead row versions** — stay until vacuum removes them
- **index bloat**
- **long-running transactions** — stop vacuum from cleaning
- **partition drop** — leaves no dead rows
- **high-churn data outside PostgreSQL**
- **partial indexes** — sized to open alerts
- one upsert per bucket, VACUUM FULL

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

PostgreSQL uses Multi Version Concurrency Control ([MVCC](https://www.postgresql.org/docs/current/mvcc.html "Lets readers and writers proceed concurrently by keeping multiple versions of a row")). An `UPDATE` does not change a row in place. It writes a new row version and marks the old one dead. A `DELETE` also only marks the row dead. A transaction that started earlier may still need the old version, so the old version stays. Vacuum removes dead row versions later and makes their space reusable.

Table bloat is the space held by dead row versions, and by free space that vacuum cleaned but could not give back. The same thing happens inside indexes. This is index bloat.

Bloat hurts in two ways. Scans read more pages for the same live rows. Indexes grow, so less of them fits in memory.

Bloat grows when rows die faster than vacuum cleans them. The usual causes are mass deletes, very frequent updates to the same rows, and long-running transactions. A long transaction stops vacuum from removing any row version that the transaction might still see.

In this system I dealt with bloat mostly by design:

- **No mass deletes.** Retention on the rollups and the audit log is a partition drop, not a `DELETE`, as I described for large tables. A partition drop leaves no dead rows at all.
- **High-churn data outside PostgreSQL.** Raw frames go to Cosmos DB with native Time To Live (TTL). About 100 million short-lived rows a day would otherwise dominate vacuum on the system-of-record server. Latest values live in Redis, not in a table row that changes every second.
- **Fewer updates per row.** Rollups are written through one upsert per bucket, not updated frame by frame.
- **Small hot indexes.** The hot alert indexes are partial indexes that cover only unresolved alerts. After vacuum, they hold only open alerts, however many resolved alerts the table keeps.

Where bloat still appears, plain `VACUUM` makes the space reusable inside the table. `VACUUM FULL` rewrites the table and returns space to the operating system. But it takes an exclusive lock for the whole rewrite, so I would not run it on a live clinical table during the day.

The design documents do not record autovacuum settings, so I cannot quote tuned values.

</details>

---

### Q3. How did you keep indexes and queries fast as the tables grew very large?

**Brief answer**
I range-partitioned the tables that grow without limit by time, and wrote queries so the planner could prune partitions before it used each partition's small index. Retention then became a partition drop instead of a mass delete.

<details>
<summary><strong>Must cover</strong></summary>

- **range-partitioned by time**
- **indexes live per partition**
- **partition pruning** — only with plain comparisons on the key
- **BRIN** — whole time-range scans, rows in time order
- **DETACH plus DROP** — no dead rows or index bloat
- **unique constraint must include the partition key**
- date_trunc, audit index on patient and time

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Three tables grow without limit: the one-minute rollups, the one-hour rollups and the access audit log. They are range-partitioned by time. `vitals_minute` and `access_event` have monthly partitions. `vitals_hour` has yearly ones.

Indexes live per partition. The primary key `(patient_id, bucket_start)` exists in each monthly partition of `vitals_minute`. A trend chart asks for one patient over a time range. The planner first keeps only the partitions that overlap the range. Then it does an index range scan in each. Every partition index stays small.

This works only if the query is written right. Trend queries compare `bucket_start` to literal bounds. If you wrap the column in `date_trunc()`, you lose both the index and partition pruning, and the query touches every partition.

Different queries need different index types on the same data:

- The trend chart uses the B-tree primary key.
- The dataset export and the minute-to-hour rollup scan whole time ranges. For those I used a BRIN index on `bucket_start`. It is tiny, because rows arrive in time order.
- The audit table has an index on `(patient_id, occurred_at)` for "who viewed this patient's record". It also has BRIN on `occurred_at` for the monthly archive export.

The biggest win was retention. Deleting old rollups with `DELETE … WHERE bucket_start < …` would create dead rows, bloat the indexes and load vacuum. With partitions, retention is `DETACH` plus `DROP`. It is fast and leaves no index bloat. A scheduled routine creates the next period's partitions and drops expired ones.

There are trade-offs. A query without the partition key scans all partitions. Also, a unique constraint on a partitioned table must include the partition key. So I chose the key to match how the data is read: by time range.

</details>

---

### Q3. How do you balance read optimization with write performance?

**Brief answer**
Every index speeds some reads and slows every write, so each index had to serve a named query. Beyond that, I kept the high-rate write path out of PostgreSQL, batched writes, and served repeated reads from Redis.

<details>
<summary><strong>Must cover</strong></summary>

- **named query** — pays for each index
- **write-heavy path stays out of PostgreSQL**
- **batched** — one upsert per window or per run
- **BRIN** — little cost per insert
- **partial indexes** — writes to resolved alerts skip them
- **write-through** — one extra Redis call per change
- **coalesced** — one audit row per user, resource and 15 minutes
- SET NX, reads from the primary

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Every index speeds up some reads and slows every write to its table. So I treated each index as a cost that a named query had to pay for. Beyond that, I balanced reads and writes per path, because the paths had very different shapes.

**The write-heavy path stays out of PostgreSQL.** About 1,200 frames a second arrive. `telemetry-service` never writes to PostgreSQL on ingest. Raw frames go to Cosmos DB, and latest values go to Redis. So the relational tables never carry the per-second write load.

**Writes are batched.** `vitals-writer` groups frames and makes one upsert per 10-second window. `func-analytics` writes a whole rollup run with one call to `upsert_minute_rollups`. Fewer, larger writes also mean fewer index updates.

**Cheap indexes on tables that mostly grow by inserts.** `vitals_minute` has a Block Range Index (BRIN) on `bucket_start` for the scans over whole time ranges. It is tiny, and rows arrive in time order, so it adds little cost to each insert. A B-tree on the same column would be far larger.

**Partial indexes on changing tables.** The hot alert indexes cover only unresolved alerts. A write to a resolved alert does not touch those indexes.

**Repeated reads served from memory.** `vitals-processor` reads thresholds and device bindings on every batch. They sit in Redis. `care-core` updates them with write-through after the PostgreSQL commit. The write costs one extra Redis call, and the alert path avoids a database read for every batch.

**Writes caused by reads are coalesced.** Every read of patient data writes an audit row. Logging every dashboard poll would produce about 11 million rows a day. So only the first access per user, resource and 15-minute window is logged, guarded by `SET NX` in Redis.

That audit write has one more effect. Patient-data reads go to the primary, because the audit insert is part of the request. The cross-region replica is for disaster recovery only, not for spreading reads.

</details>

---

## R5. Messaging — RabbitMQ between services

> RabbitMQ configuration for communication between services;

---

### Q1. Which exchange types did you use in RabbitMQ, and why?

**Brief answer**
Topic exchanges for domain events, so one message could reach several consumers and each consumer chose what it wanted by routing key. Commands for exactly one worker went through Celery on their own queue.

<details>
<summary><strong>Must cover</strong></summary>

- **topic exchange** — consumers choose by routing key
- **two queues bound** — processor and writer each get every batch
- **topic over fanout** — or direct
- **Celery for commands** — exactly one worker, with retries
- **dead-letter exchange** — after 5 deliveries
- vitals.{hospital}.{ward}, alert.raised.{severity}, Terraform RabbitMQ provider

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There were two topic exchanges, `telemetry` and `alerts`. In a topic exchange, consumers choose messages by routing key pattern.

`telemetry-service` published each gateway batch to `telemetry` with the routing key `vitals.{hospital}.{ward}`. Two queues bound with `vitals.#`: `vitals.processor` for rule evaluation and `vitals.writer` for raw storage. So every batch reached both consumers. The topic exchange also left room to bind a queue to one hospital or one ward later, without changing the publisher.

`vitals-processor` published to `alerts` with `alert.raised.{severity}`. The risk-score function published `alert.raised.advisory` to the same exchange. `alert-service` bound with `alert.raised.*`. Because severity is in the key, a future consumer can take only critical alerts.

I chose topic over fanout, because fanout ignores the key. I chose it over direct, because direct needs exact key matches and cannot say "all wards of one hospital".

Commands were different. "Send this push notification" must run on exactly one worker, with retries. Celery for commands gave that: the task `notify.send` ran on its own `notify` queue. Celery beat put scheduled checks on `alerts.scheduled`.

A dead-letter exchange caught poison messages. After 5 deliveries, a message moved to `queue.dlq`. Any depth above zero paged the on-call engineer.

Terraform's RabbitMQ provider declared every exchange, queue, binding and policy. So a rebuilt cluster got an identical topology, and services needed no `configure` permission.

</details>

---

### Q1. How do you decide on sync vs. async inter-service communication?

**Brief answer**
Sync where a person or a device waits for the answer; async between services. Inside the cluster no service calls another synchronously: it reads a published view or consumes an event.

<details>
<summary><strong>Must cover</strong></summary>

- **need the answer to continue**
- **202 Accepted** — only after the broker confirms
- **long-poll** — robots behind NAT
- **at their own speed** — processor and writer
- **no synchronous calls between services inside the cluster**
- **published view**
- **views become contracts** — column changes tested in CI
- Celery retries, idempotent consumers, dead-letter queue

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I asked two questions. Does the caller need the answer to continue? And should the caller fail when the other side is slow or down?

**Sync where a person or a device waits.**

- Staff clients call services over Representational State Transfer (REST) through API Management. A screen needs a response, and reads must show the latest committed state.
- The ward gateway uploads each batch and gets `202 Accepted` only after RabbitMQ confirms it. The gateway must know the batch is durable before it drops the batch from its buffer. So the call is synchronous, but it waits only for durability, not for processing.
- Robots long-poll for their next mission. They sit behind hospital Network Address Translation ([NAT](https://datatracker.ietf.org/doc/html/rfc3022 "Maps multiple private addresses to a shared public address")), so pulling avoids inbound connections to the robots.

**Async between services.**

- `telemetry-service` publishes each batch once. `vitals-processor` and `vitals-writer` consume it at their own speed, and each has its own failure tolerance.
- `vitals-processor` publishes alerts and does not wait for `alert-service` to store them.
- Push notifications are Celery tasks with retries and backoff.

**No synchronous calls between services inside the cluster.** A service that needs another's data reads a published view or consumes an event. A chain of requests would let one slow service stall every caller on the alert path.

The cost is real. Views become contracts. A migration that changes a view must keep its columns stable, and the view's owner tests that in Continuous Integration (CI). Async flows also need idempotent consumers and a dead-letter queue, because the broker delivers at least once.

</details>

---

### Q2. How did you make sure a message was not lost between a producer, RabbitMQ and a consumer?

**Brief answer**
Each hop had its own guarantee: publisher confirms on the way in, replicated quorum queues inside the broker, and manual acks on the way out. That gives at-least-once delivery, so every consumer was idempotent.

<details>
<summary><strong>Must cover</strong></summary>

- **publisher confirms** — 202 only after the confirm
- **quorum queues** — three nodes, one per zone
- **manual acks** — after the work is done
- **at-least-once delivery** — so duplicates happen
- **idempotent consumers** — $addToSet, dedup_key, batch_id
- **dead-letter queue** — after 5 deliveries
- gateway disk buffer, two nodes lost

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I looked at each hop separately.

**Producer to broker.** Every publish used publisher confirms. `telemetry-service` returned `202 Accepted` to the gateway only after RabbitMQ confirmed the batch. The gateway deletes a batch from its disk buffer only after that 202. So after a crash anywhere before the confirm, the gateway sends the batch again.

**Inside the broker.** The four main queues were quorum queues, replicated on three nodes, one per availability zone. A confirmed message survives the loss of one node. The cost is a few seconds of leader election. If two nodes are lost, the queues become unavailable. Then `telemetry-service` returns 503 and the gateways keep buffering. Alerts are late, but no data is lost.

**Broker to consumer.** Consumers used manual acks, sent only after the work was done. `vitals-writer` buffers up to 10 seconds of messages, upserts each window once, then acks the whole buffer.

This gives at-least-once delivery, so duplicates happen. Every consumer was built for that. These are idempotent consumers:

- Raw frames use a deterministic document ID and `$addToSet`, so a redelivered batch changes nothing.
- Alerts insert with `ON CONFLICT (dedup_key) DO NOTHING`.
- Ingest checks `batch_id` in Redis with `SET NX`, so a retried upload is not published twice.

A message that fails every time must not block the queue. After 5 deliveries, the quorum-queue delivery limit sends it to the dead-letter queue. A depth above zero pages someone, so the queue never grows silently.

</details>

---

### Q2. How do you design retry and dead-letter strategies? How do retry policies differ for transient and permanent failures?

**Brief answer**
I first split failures by whether a retry can help. Permanent failures are rejected at the edge or dead-lettered. Transient ones get retries with backoff. A separate safety net covers the case where every retry fails.

<details>
<summary><strong>Must cover</strong></summary>

- **whether a retry can help**
- **rejected at ingest** — contract violations never enter a queue
- **retries with backoff** — three for a push
- **queue absorbs the backlog** — Cosmos DB throttling
- **escalates on schedule** — the safety net
- **delivery limit of 5** — then the dead-letter exchange
- **pages the on-call engineer**
- **requeues immediately** — can dead-letter a valid message
- HTTP 429, notify.delivery, fix the cause first

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

First I split failures by whether a retry can help.

**Permanent failures are stopped as early as possible.** A batch that breaks the `VitalsBatchV1` contract is rejected at ingest with an error. A value in the wrong unit is one example. The rejected batch never enters a queue. `telemetry-service` also rejects frames more than 5 seconds in the future. A retry would only repeat these failures.

**Transient failures get retries with backoff.**

- A push that fails is retried by Celery three times with backoff. `notify.delivery` records the number of attempts and the status.
- When Cosmos DB throttles with Hypertext Transfer Protocol (HTTP) 429, `vitals-writer` falls behind, and its queue absorbs the backlog. Alerts are not affected, because they use a separate queue.
- During a PostgreSQL failover of 60 to 120 seconds, alerts wait in `alert-service.raised` and are inserted afterwards.

**A retry never replaces the safety net.** If all push retries fail, an unacknowledged alert still escalates on schedule. The dashboard feed also still shows it.

**Dead-letter is for what retries cannot fix.** Each quorum queue has a delivery limit of 5, as I described for message loss. After that, the message goes to the dead-letter exchange and into `queue.dlq`. Any depth above zero pages the on-call engineer. The queue exists for inspection. The engineer fixes the cause first and only then sends the message back. A message sent back before the fix only returns to the queue.

There is one trap. The delivery limit counts every redelivery. A consumer that requeues immediately during a two-minute database failover can use up 5 deliveries in seconds. Then a valid alert lands in the dead-letter queue. So a transient error must wait or back off before the message goes back to the queue. The design documents do not record how each consumer backs off in this case, so I would treat it as a point to confirm.

</details>

---

### Q3. How did RabbitMQ and Celery work together, and when did you choose a Celery task over a plain message?

**Brief answer**
Both ran on the same RabbitMQ cluster. Domain events that could have many consumers were plain messages on topic exchanges; commands that one worker had to run, with retries, were Celery tasks.

<details>
<summary><strong>Must cover</strong></summary>

- **domain events** — several consumers, consumed with kombu
- **commands** — exactly one worker
- **send_task by name** — no service imports another's code
- **Pydantic contract**
- **Celery beat** — one replica, SKIP LOCKED protects overlaps
- **quorum queues for Celery** — no global QoS
- retries with backoff, heartbeat metric, remote control off

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Two kinds of traffic shared one broker.

**Domain events** such as `VitalsBatchV1` and `AlertRaisedV1` describe something that happened. They go to topic exchanges and may have several consumers. The consumers use kombu directly, so they control acks, prefetch and batching themselves. `vitals-writer` needs that control, because it buffers 10 seconds of messages before one ack.

**Commands** such as `notify.send` ask for one action by exactly one worker. Celery gives that with little code: retries with backoff, and beat for schedules. The notification worker retries a push three times with backoff.

Services never import each other's code. A producer calls `send_task("notify.send", …)` by name. The arguments are a Pydantic contract in the shared `contracts` package, so both sides agree on the shape.

Celery beat ran the time-driven work inside `alert-service`: the escalation check and the gateway-silence check, every 15 seconds, through the `alerts.scheduled` queue. Beat runs as one replica, and it can crash and restart. So `claim_due_escalations` uses `SKIP LOCKED`, and an overlap cannot escalate an alert twice. A heartbeat metric pages if no check ran for 60 seconds.

The two tools have one trap together. I used quorum queues for Celery too. Quorum queues do not support global Quality of Service ([QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")), and countdown tasks on them need Celery's quorum-queue detection. The Celery and kombu versions in use must support `task_default_queue_type = "quorum"`, and that has to be confirmed before relying on it. I avoided countdown tasks entirely and used only beat.

I also turned off Celery remote control and task events. Then workers need no access to the `celery.pidbox` and `celeryev` exchanges, and their RabbitMQ permissions stay narrow.

</details>

---

### Q3. How do RabbitMQ consumers impact PostgreSQL performance under load, and how do you deal with it?

**Brief answer**
A consumer turns queue depth into database load, and autoscaling multiplies it. I kept the high-rate consumers on Cosmos DB and Redis, so PostgreSQL sees writes only when a rule fires.

<details>
<summary><strong>Must cover</strong></summary>

- **queue depth into database load**
- **high-rate consumers** — Cosmos DB and Redis, not PostgreSQL
- **only on a cache miss**
- **only when a rule fires** — about 5,000 alerts a day
- **KEDA** — more Redis calls, not more database load
- **Redis failover** — a short burst of view queries
- **alerts wait in their queue** — during a PostgreSQL failover
- **connection limit** — all replicas together
- ON CONFLICT, 60 to 120 seconds

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The risk is simple. A consumer turns queue depth into database load. When the backlog grows, autoscaling adds consumers, and every new consumer adds queries and connections. The database then slows down, each message takes longer, and the backlog grows further.

The high-rate consumers rarely touch PostgreSQL. I designed them that way on purpose.

- **`vitals-writer`** handles every batch, about 40 messages a second. It writes to Cosmos DB, not to PostgreSQL.
- **`vitals-processor`** also handles every batch. It reads thresholds and device bindings from Redis, and it writes latest values and rule windows to Redis. It reads PostgreSQL only on a cache miss.
- **`alert-service`** writes to PostgreSQL, but only when a rule fires. That is about 5,000 alerts a day. Each insert uses `ON CONFLICT (dedup_key) DO NOTHING`, so a redelivered message costs one cheap statement.

Autoscaling follows the same idea. Kubernetes Event-driven Autoscaling (KEDA) adds processor replicas at a queue depth of 50. More processors mean more Redis calls, not more database load.

**The weak spot is a Redis failover.** Thresholds and bindings then fall back to the PostgreSQL views. Each processor fills Redis again after its first miss on a key. So the database sees a short burst of view queries, and then the cache takes over again.

**The other direction matters too.** A PostgreSQL failover takes 60 to 120 seconds, and `alert-service` cannot insert during it. The alerts wait in their queue and are inserted after the failover. The producers do not wait for that.

One gap is honest to name. The design documents do not size connection pools per replica. Before I raise a replica ceiling, I would check that all replicas together stay under the server's connection limit.

</details>

---

### Q3. How do you choose between orchestration and choreography when implementing the Saga pattern?

**Brief answer**
Choreography when the steps are independent reactions that never need undoing; orchestration when one component must track the state and decide the next step. This system needed no Saga with compensation, because each business transaction stays inside one service.

<details>
<summary><strong>Must cover</strong></summary>

- **compensating step**
- **choreography** — independent reactions, idempotent consumers
- **orchestration** — one owner tracks state and deadlines
- **no Saga** — each business transaction in one service and one schema
- **alert lifecycle** — owned by alert-service
- **mission lifecycle**
- **only after the alert row commits** — order instead of compensation
- Celery beat, assign_next_mission

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A Saga splits one business transaction into local transactions across services. Each step has a compensating step that undoes it if a later step fails. In choreography, each service reacts to events, and nobody directs the flow. In orchestration, one component tells each step what to do and tracks the state.

Honestly, this system has no Saga with compensating transactions. I kept each business transaction inside one service and one schema. But the choice between the two styles still came up, and I made it per flow.

**Choreography for the telemetry and alert flow.** `telemetry-service` publishes a batch. `vitals-processor` and `vitals-writer` react to it independently. `vitals-processor` then publishes an alert event, and `alert-service` reacts to that. No step needs to undo another, and each consumer is idempotent. So no component has to track the whole flow. A new consumer can also join without any change to the producer.

**Orchestration where one owner must track state and deadlines.**

- `alert-service` owns the alert lifecycle: open, acknowledged, escalated and resolved. It sends `notify.send` commands, and Celery beat checks deadlines every 15 seconds. `alert-service` decides the next escalation level. With choreography, that decision would be spread across services. Nobody could then answer "who is handling this alert now?"
- `robot-service` owns the mission lifecycle, from queued to completed or aborted. A stored procedure, `assign_next_mission`, picks the mission and the robot. The robot then pulls its next mission.

**Order instead of compensation.** `alert-service` sends a notification only after the alert row commits. So a push never points to an alert that does not exist, and nothing needs rolling back. A push that was sent cannot be undone anyway.

My rule is simple. Choreography fits when the steps are independent reactions. Orchestration fits when one component must know the state and decide the next step. If a real cross-service transaction appeared, I would orchestrate it. Compensation logic in one place is easier to test and to reason about.

</details>

---

## R6. Data and AI pipelines — ChatGPT expert chatbot

> Integration with [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") [ChatGPT](https://openai.com/chatgpt/ "ChatGPT — OpenAI's conversational large language model product") for creating a chatbot that answers expert questions and quickly searches for information among a corpus of documents with expert recommendations;

---

### Q1. How did you make the chatbot answer from your document corpus instead of from what the model already knows?

**Brief answer**
Retrieval first, generation second. For each question I searched the corpus, put the best passages into the prompt, told the model to answer only from them, and returned citations to the exact chunks used.

<details>
<summary><strong>Must cover</strong></summary>

- **retrieval-augmented generation**
- **blob trigger** — func-knowledge chunks and embeds each document
- **answer only from these passages**
- **citations** — document, chunk and title
- **fallback to search-only**
- **answer cache** — keyed by the corpus version
- server-sent events, Pydantic for structured output, first token within 2 seconds

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The pattern is Retrieval-Augmented Generation ([RAG](https://en.wikipedia.org/wiki/Retrieval-augmented_generation "Grounds a model's answer in documents retrieved at query time")), and it has two halves.

**Ingest.** Knowledge editors upload documents to Blob Storage. A blob trigger starts an Azure Function, `func-knowledge`. It extracts the text, splits it into chunks, and calls the [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") embeddings API for each chunk. Each chunk goes into PostgreSQL with its text, a full-text search vector and an embedding. A document becomes `active` only when all of that has succeeded. A new version marks the old document superseded and its chunks inactive, so old guidance stops appearing.

**Answering.** `assistant-service` receives the question and runs a hybrid search to get the best passages. It sends them to the chat completions API, with the instruction to answer only from these passages. The answer streams back to the user as server-sent events. The final event carries citations: document ID, chunk ID and title. So a clinician can open the source and check it.

A few choices made this reliable:

- **Citations are required.** In a clinical setting, an answer nobody can check is worse than no answer.
- **Pydantic parses the structured part** of the model output, so a malformed citation list is caught instead of shown.
- **Fallback to search-only.** If the OpenAI API is down or rate-limited, the assistant returns search results from PostgreSQL. Users still get the passages, just no generated answer.
- **Answer cache.** Repeated questions hit a Redis cache keyed by the normalised question and the corpus version. When a document becomes active, the version goes up, so old answers are never served again.

The targets were a first streamed token within 2 seconds, and a full answer within 8 seconds at p95. Generation takes most of that time.

</details>

---

### Q1. Why did you build the chatbot on retrieval instead of fine-tuning the model on your documents?

**Brief answer**
Fine-tuning changes how a model writes, but it is a poor way to teach it facts that change. The guidelines changed often, every answer needed a source a clinician could check, and a retired document had to stop appearing at once. Retrieval gave all three, and fine-tuning gave none of them.

<details>
<summary><strong>Must cover</strong></summary>

- **knowledge that changes** — a new version replaces the old one at once
- **old facts stay in the model's weights**
- **citations** — retrieval knows which passages it sent
- **facts versus behaviour** — fine-tuning teaches format, not facts
- **only an upload** — an editor, not an engineer
- **control at query time** — the code chooses what the model sees
- **fine-tune for style and still retrieve for facts**
- training run per change, filter by hospital

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The corpus is clinical guidelines and expert recommendations. Five needs decided the approach.

**Knowledge that changes.** Guidelines get new versions. With retrieval, a new version replaces the old one in the index. The old chunks are marked inactive, so the next question already uses the new text. With fine-tuning, the old facts stay in the model's weights. Removing them means training a new model, and you still cannot prove the old fact is gone.

**Citations.** In a clinical setting, an answer nobody can check is worse than no answer. Retrieval knows which passages it sent, so each answer cites the document, the chunk and the title. A fine-tuned model cannot say where a fact came from.

**Facts versus behaviour.** Fine-tuning is good at teaching format, tone and vocabulary. It is unreliable at teaching facts. The model may mix two guidelines, or produce a dose that sounds right but is not. That is the risk this design works hardest against.

**Speed of change.** Fine-tuning needs training data in question-and-answer form, a training run per change, and a new evaluation each time. Retrieval needs only an upload. A knowledge editor adds a document, and no engineer is involved.

**Control at query time.** With retrieval, the code chooses what the model sees. It leaves out inactive documents, and it could filter by hospital later. A fine-tuned model carries everything in its weights, for every user.

When would I fine-tune? If answers needed a fixed house format that prompting could not hold, or if the model kept misreading local abbreviations. Then I would fine-tune for style and still retrieve for facts. The two approaches work together.

</details>

---

### Q1. Walk me through how you built the knowledge base. How did a source document become searchable chunks?

**Brief answer**
Knowledge editors uploaded curated guidelines, and an Azure Function turned each one into chunks. It extracted the text with its headings, split it along the document's own sections, and added the title and section path to each chunk. Then it embedded each chunk with OpenAI and stored the text, a full-text vector and the embedding in one PostgreSQL row.

<details>
<summary><strong>Must cover</strong></summary>

- **curated, not crawled** — editors upload, no patient records
- **blob trigger**
- **keeps the structure** — headings, recommendations, tables
- **cleaning** — the same footer in hundreds of chunks
- **split along the document's own structure** — half a dosing rule is dangerous
- **a table stays in one chunk** — with its header row
- **title and section path** — inside the embedded text
- **embeddings API in batches**
- SAS URL, 1,536 dimensions, content_tsv, ordinal

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

**What went in.** The corpus was curated, not crawled. Knowledge editors, a separate role in Entra ID, uploaded clinical guidelines and expert recommendations. The corpus reached about 5,000 documents and about 500,000 chunks. No patient records went in.

**Upload.** The editor uploads through `assistant-service`. The service creates the `kb.document` row with status `processing`. It returns a short-lived Shared Access Signature (SAS) URL, and the file goes straight to the `kb-documents` container in Blob Storage.

**Extraction.** A blob trigger starts `func-knowledge`. Most sources were Portable Document Format ([PDF](https://en.wikipedia.org/wiki/PDF "Fixed-layout document format for reliable printing and viewing")) files with a text layer. The function extracts the text and keeps the structure: headings, numbered recommendations, lists and tables. It also removes running headers, footers and page numbers. Without that cleaning, the same footer text lands in hundreds of chunks and matches many searches.

**Splitting.** I split along the document's own structure first: section, then recommendation, then paragraph. A fixed split by character count can cut a recommendation in half, and half a dosing rule is dangerous. Only a section that is still too long is split again, at paragraph or sentence boundaries, with a small overlap. A table stays in one chunk with its header row, because a table row without its header means nothing. The chunk size question covers the limits.

**Context in each chunk.** Each chunk starts with a short header: the document title and section path, such as "Sepsis guideline › Antibiotics › Adults". A chunk that says "give within one hour" is useless if you do not know what it refers to. The header is part of the embedded text and of the indexed text, so both kinds of search see it.

**Embedding and storage.** The function sends chunks to the OpenAI embeddings API in batches. Each chunk becomes one `kb.chunk` row. The row holds the `ordinal`, the `content`, a 1,536-dimension `embedding`, and `content_tsv`, which the database generates for full-text search. The `ordinal` keeps the reading order, so the UI can show the text around a cited chunk.

The document becomes `active` only when every chunk is stored. The ingestion question covers that step and its failures.

</details>

---

### Q1. Which OpenAI models did the chatbot use, and why did you choose them?

**Brief answer**
`gpt-4o` wrote the answers and `text-embedding-3-small` produced the embeddings. The answer model had to follow "answer only from these passages" reliably and start streaming within 2 seconds. The embedding model had to be cheap enough for 500,000 chunks and good enough to match clinical paraphrases.

<details>
<summary><strong>Must cover</strong></summary>

- **gpt-4o** — follows the grounding instruction
- **structured output** — fewer failed Pydantic parses
- **first streamed token within 2 seconds**
- **dated snapshot** — a model change goes through the evaluation
- **temperature 0**
- **text-embedding-3-small** — 1,536 dimensions
- **2,000 dimensions** — the HNSW limit in pgvector
- **same model for query and chunks** — a change means re-embedding the whole corpus
- text-embedding-3-large, gpt-4o-mini for follow-up rewrites

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There are two calls, and each one has its own model.

**Answers: `gpt-4o`.** The chat model gets about eight passages and the instruction to answer only from them, with citations. I needed three things from it:

- It follows the grounding instruction. Weaker models more often add facts from their own training, and that is the main risk in clinical answers.
- It returns well-formed structured output. Pydantic parses the citation part, and a stronger model fails that parse less often.
- It is fast enough. The targets were a first streamed token within 2 seconds, and a full answer within 8 seconds at p95.

I used a dated snapshot of the model, not the alias that moves to new versions. A silent model update can change answers. So a model change went through the evaluation first, like a code change. I set temperature 0, because two identical clinical questions should not get different answers.

**Embeddings: `text-embedding-3-small`.** It produces 1,536 dimensions, which sets the `vector(1536)` column and the HNSW index. I compared it with `text-embedding-3-large`. The large model produces 3,072 dimensions by default, and `pgvector` builds an HNSW index on at most 2,000 dimensions for the standard vector type. The large model would also double the index memory. On our retrieval question set, the gap between the two was small, so the small model won on cost and memory.

**One rule connects the two.** Use the same model for query and chunks. Vectors from two models cannot be compared, even when they have the same size. So a change of embedding model means re-embedding the whole corpus and starting a new corpus version. The scaling question covers that job.

For helper calls, I would use `gpt-4o-mini`. One example is rewriting a follow-up into a full question before retrieval. That step does not decide clinical content, so a cheaper and faster model fits it.

</details>

---

### Q1. How do you structure a multi-step LLM workflow?

**Brief answer**
One model call per question, and every other step is plain code: limits, cache, retrieval, redaction, generation, validation and logging. The code chooses the next step, never the model.

<details>
<summary><strong>Must cover</strong></summary>

- **one model call per question**
- **deterministic code** — every step except generation
- **daily token budget**
- **answer cache** — a hit skips every later step
- **redaction** — before the prompt leaves the tenant
- **search-only fallback**
- **the code chooses the next step**
- 20 questions per minute, server-sent events, Pydantic, chat_log, rewrite call for follow-ups

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

In this project the chatbot is one pipeline inside `assistant-service`. There is one model call per question. Every other step is deterministic code, so I can test it and time it on its own.

The steps, in order:

1. **Limits.** API Management allows 20 questions per minute per user. The service also checks a daily token budget per user in Redis. The budget caps Large Language Model (LLM) spend.
2. **Answer cache.** The service looks up the answer cache, keyed by the normalised question and the corpus version. A hit skips every later step.
3. **Retrieval.** One hybrid search query in PostgreSQL returns the best passages. R6 Q1 and Q2 explain how it works.
4. **Redaction.** Before the prompt leaves the tenant, the question passes the redaction step.
5. **Generation.** One chat completions call gets the passages and the instruction to answer only from them. The answer streams to the user as server-sent events.
6. **Validation.** Pydantic parses the structured part of the output. A malformed citation list is caught, not shown.
7. **Logging.** The service writes a `chat_log` row with the redacted question, the cited chunk IDs and the latency.

Each step has one job, so each step can fail on its own terms. If the OpenAI API is down or rate-limited, step 5 fails. The service then uses the search-only fallback and returns the passages from step 3. The user still gets the sources, just no generated answer.

The main rule: the code chooses the next step, not the model. A workflow where the model picks its own next action is harder to test, to time and to limit.

This design has no chain of model calls and no agent. One call keeps the answer inside the 8-second budget, and generation already takes most of that time. The first step I would add is a rewrite call for follow-up questions. It turns "and for children?" into a full question before retrieval. It costs a second model call, so I would add it only when follow-ups become common.

</details>

---

### Q2. How did your ingestion process keep the knowledge base consistent when a run failed or a document was replaced?

**Brief answer**
Only chunks of an `active` document could be searched. The function wrote new chunks as inactive, then switched the new version on and the old one off in one transaction. So search saw the old version or the new one, never half of each. A failed run left the old version live, and it could run again safely.

<details>
<summary><strong>Must cover</strong></summary>

- **status** — only active chunks are searched
- **safe to repeat** — leftovers from a failed attempt deleted first
- **chunks are inserted as inactive**
- **one transaction** — old or new version, never a mix
- **corpus version** — no cached answer from the old text
- **exponential backoff** — respects Retry-After
- **poison queue** — after five attempts
- **old version stays active**
- source, 24-hour cache TTL, capped scale-out, blob versioning

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Each `kb.document` row has a status: `processing`, `active`, `superseded` or `failed`. Search reads only chunks with `is_active = true`. So consistency depends on when that flag changes.

**One run, step by step.**

1. The blob trigger fires, and `func-knowledge` loads the document row. It finds the previous version of the same document by its `source`.
2. It deletes any chunks that an earlier failed attempt left for this document. That makes the run safe to repeat.
3. It extracts, splits and embeds the text. The chunks are inserted as inactive, with `is_active = false`.
4. One transaction switches the versions. The new document and its chunks become active. The previous version becomes `superseded`, and its chunks become inactive.
5. After the commit, the function increments the corpus version in Redis, `assistant:corpus_version`. The answer cache key includes that version, so no cached answer from the old text is served again.

**Why one transaction.** Search sees either the old version or the new one. It never sees a mix, and it never sees a moment with neither.

**Failures.** The long step is embedding. The usual failures there are an OpenAI rate limit, HTTP 429, and timeouts. The function retries each batch with exponential backoff and respects the `Retry-After` header. If the whole run still fails, the Functions runtime retries the blob trigger, up to five attempts. After that the message goes to a poison queue, and the document is marked `failed`. The old version stays active the whole time. The editor sees the `failed` status and can upload again.

**The gap after the commit.** If the Redis increment fails after the commit, the cache can serve old answers until they expire. Cached answers live for 24 hours. The function retries the increment, so this gap is short in practice.

**Bulk loads.** The first load of 5,000 documents, or a full re-embedding, is a burst of embedding calls. Batching many chunks into one request reduces the number of calls. Capping the function app's scale-out keeps us under the account's tokens-per-minute limit.

The container also has blob versioning on. An earlier source file can be restored and processed again.

</details>

---

### Q2. What chunk size did you use, and how did you arrive at it?

**Brief answer**
About 400 tokens per chunk, with a hard limit of 512 and about 50 tokens of overlap when a long section had to be cut. I started from the documents' structure and the prompt budget. Then I compared 256, 512 and 1,024 tokens on our retrieval question set, and the middle size found the right passage most often.

<details>
<summary><strong>Must cover</strong></summary>

- **about 400 tokens** — hard limit 512
- **too small** — a chunk loses its context
- **too large** — one embedding averages several topics
- **one whole recommendation**
- **prompt budget** — about eight chunks
- **recall at 8** — same question set, three sizes
- **tiktoken** — tokens, not characters
- **overlap only when a long section is cut** — about 50 tokens
- 8,191-token input limit, near-duplicate chunks, about 100 chunks per document

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used about 400 tokens per chunk, with a hard limit of 512. Chunk size is a trade-off between two failures:

- **Too small**, and a chunk loses its context. "Give within one hour" says nothing without the drug and the condition. The model gets fragments, and fewer questions find a complete answer.
- **Too large**, and one embedding averages several topics. The vector then matches nothing well. Large chunks also fill the prompt, so fewer different sources fit.

**Where I started.** Three facts set the range:

1. **The documents.** One recommendation with its conditions is usually 100 to 400 tokens. A chunk should hold one whole recommendation.
2. **The prompt budget.** About eight chunks go into the prompt. At 400 tokens each, that is about 3,200 tokens of passages, which keeps generation inside the 8-second answer target.
3. **The embedding model.** `text-embedding-3-small` accepts up to 8,191 tokens. So the limit came from retrieval quality, not from the model.

**How I decided.** I built the corpus three times, at 256, 512 and 1,024 tokens. Then I ran the same retrieval question set on each one. The metric was recall at 8: how often a passage that answers the question is among the eight chunks sent to the model. At 256, too many recommendations were split from their conditions. At 1,024, chunks mixed topics, and the right passage ranked lower. A limit of 512, with about 400 on average, scored best. The evaluation question covers the question set.

**Counting.** I counted tokens with `tiktoken`, using the embedding model's tokenizer, not characters. Clinical text is full of drug names and units, and they use more tokens per character than plain English.

**Overlap.** I used overlap only when a long section is cut at paragraph or sentence level. About 50 tokens, roughly 10%, keeps a sentence that crosses the cut readable in both chunks. More overlap stores the same text twice and returns near-duplicate chunks for one question.

**A check against the corpus numbers.** 5,000 documents gave about 500,000 chunks, so about 100 chunks per document. About 400 tokens of text plus a 1,536-dimension vector per row matches the 4 GB the corpus takes in PostgreSQL.

</details>

---

### Q2. How did you make the document search both fast and accurate for expert terms?

**Brief answer**
I ran a hybrid search in one PostgreSQL query: vector similarity for meaning and full-text search for exact terms, fused by reciprocal rank. Each side had its own index, aimed at a 300 ms p95 target.

<details>
<summary><strong>Must cover</strong></summary>

- **vector search blurs exact tokens** — drug names and codes
- **HNSW from pgvector** — cosine distance
- **tsvector indexed with GIN**
- **reciprocal rank fusion** — k = 60, ranks instead of scores
- **partial HNSW index** — filtering after the search returns too few rows
- 1,536 dimensions, 500,000 chunks, delete superseded chunks

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Pure vector search blurs exact tokens. Drug names, dosage codes and guideline IDs look alike to an embedding model, but a clinician needs the exact one. Pure keyword search misses paraphrases: "low oxygen" will not find "hypoxaemia". So I used both.

Everything lived in PostgreSQL, in the `kb` schema:

- An `embedding` column with 1,536 dimensions. It has a Hierarchical Navigable Small World ([HNSW](https://arxiv.org/abs/1603.09320 "Graph index for approximate nearest-neighbour search over vectors")) index from `pgvector`, using cosine distance.
- A generated `tsvector` column, indexed with GIN, for full-text search.

The query has two Common Table Expressions (CTEs). One takes the top 20 chunks by cosine distance. The other takes the top 20 by `ts_rank`. Then reciprocal rank fusion combines them, with k = 60. Each chunk scores the sum of 1 / (60 + its rank) across both lists. Fusing by rank avoids mixing two score scales that mean different things.

Keeping search in PostgreSQL meant one store, one backup and one access model. The corpus is about 500,000 chunks and 4 GB, and PostgreSQL handles that without a separate vector database.

Approximate indexes have one trap: filtering after the search. Superseded chunks are flagged with `is_active = false`. If the HNSW index returns 20 neighbours and a filter then removes some, you get fewer than 20 rows. So the design uses a partial HNSW index, `WHERE is_active`. That must be confirmed with `EXPLAIN` on the `pgvector` version in use. If it does not work, the fallback is to delete superseded chunks instead of flagging them.

The target was a passage search p95 under 300 ms. The expensive part of the assistant is generation, not search, so search had room inside the full answer budget.

</details>

---

### Q2. Why did you keep the embeddings in PostgreSQL instead of a dedicated vector database?

**Brief answer**
At about 500,000 chunks and 4 GB, `pgvector` met the 300 ms search target. PostgreSQL also gave me what a separate store could not: hybrid search in one query, version switches in one transaction, and the same grants, backups and recovery as the rest of the system.

<details>
<summary><strong>Must cover</strong></summary>

- **500,000 chunks and 4 GB** — the index fits in memory
- **hybrid search in one query**
- **one transaction for a version switch** — never a chunk from a superseded guideline
- **one security model** — grants, backups, recovery
- **HNSW index competes for memory**
- **filtering after an approximate search**
- **Azure AI Search** — the version switch would not be atomic
- **kb schema on its own PostgreSQL server** — the first step
- Qdrant, Pinecone, semantic ranker, slow index rebuild

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I compared three options: `pgvector` in our PostgreSQL, Azure [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Search, and a dedicated vector database such as Qdrant or Pinecone.

**Why PostgreSQL won.**

- **Size.** The corpus is about 500,000 chunks and 4 GB. An HNSW index of that size fits in memory on our server. Search met the passage search target of p95 under 300 ms. A dedicated store pays off at tens of millions of vectors, not here.
- **Hybrid search in one query.** Vector search, full-text search and reciprocal rank fusion run in one SQL statement. With a separate vector store, the service runs two searches in two systems and merges them in code.
- **One transaction for a version switch.** A new document version and its chunks become active, and the old ones inactive, in one transaction. With two stores, the vector index and the document table can disagree. Then search can return a chunk from a superseded guideline. In clinical guidance, that is the failure that matters most.
- **One security model.** Only `assistant-service` and `func-knowledge` have grants on the `kb` schema. Backups, point-in-time recovery and disaster recovery already cover PostgreSQL. A new store would need its own access model, backups and failover plan.

**What it costs.**

- The HNSW index competes for memory with clinical queries on the same server.
- A full index build is slow, so re-embedding the corpus means a slow index rebuild.
- Filtering after an approximate search can return fewer rows than asked. The design uses a partial index on active chunks for that reason.

**Azure AI Search** was the strongest alternative. It is managed, and it has hybrid search and a semantic ranker built in. I did not choose it, because the document table and the index would live in two places. Then the version switch would not be atomic. It would also add its own cost and a second copy of the corpus.

**When I would move.** The first step is the `kb` schema on its own PostgreSQL server, if search starts to slow clinical queries. A dedicated vector database comes later, and only if PostgreSQL cannot keep the 300 ms target.

</details>

---

### Q2. How did you decide which retrieved passages went into the prompt?

**Brief answer**
The hybrid search returned up to 40 candidates, reciprocal rank fusion ordered them, and the top eight went into the prompt, with at most two from one section. Eight came from our retrieval question set. I left out a separate reranking model to stay inside the latency budget.

<details>
<summary><strong>Must cover</strong></summary>

- **reciprocal rank fusion** — already a first reranking
- **top eight** — recall flattened after about eight
- **weak passages** — close but wrong
- **at most two chunks from one section**
- **chunk ID, document title and section path** — the model cites by chunk ID
- **cross-encoder reranker** — left out for latency and one more provider
- **no relevance cutoff** — fused scores measure rank, not closeness
- k = 60, about 3,200 tokens, best passage first

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

**Candidates.** One SQL query takes the top 20 chunks by cosine distance and the top 20 by full-text rank. Reciprocal rank fusion merges them, with k = 60. Fusion is already a first reranking, because a chunk that both searches find rises to the top.

**How many.** I sent the top eight. That number came from the retrieval question set. Recall rose quickly up to about eight passages and then flattened. More passages cost tokens on every question and add time to the 8-second target. They also add weak passages, and the model may then quote a passage that is close but wrong. At about 400 tokens per chunk, eight passages take about 3,200 tokens.

**Variety.** Neighbouring chunks of one section often both match, and they say almost the same thing. So I kept at most two chunks from one section. That leaves room for a second guideline, which may say something different.

**Format in the prompt.** Each passage goes in with its chunk ID, document title and section path. The model cites by chunk ID, so every citation points to a passage that was sent. The best passage goes first.

**No separate reranking model.** A cross-encoder reranker reads the question and each candidate together. It usually ranks better than fusion. I left it out for two reasons. It adds a few hundred milliseconds to a budget that generation already uses up. And a hosted reranker sends the question to one more outside provider. I would add one if the question set often showed the right passage in the top 40 but not in the top eight. That is the gap a reranker closes.

**What is missing.** There is no relevance cutoff, so eight passages go in even when none of them is relevant. A cutoff needs the cosine distance of the best passage, because fused scores measure rank, not closeness. The hallucination question covers this gap.

</details>

---

### Q2. How do you handle failures while interacting with third-party APIs?

**Brief answer**
I gave each provider its own degraded mode, so an outage makes the service worse instead of breaking it. OpenAI falls back to search-only answers, push delivery retries while escalation carries on, and Entra ID signing keys are cached.

<details>
<summary><strong>Must cover</strong></summary>

- **what must keep working** — asked for each provider
- **search-only answers** — passages without a generated answer
- **daily token budget** — keeps us below the provider's rate limit
- **3 retries with backoff**
- **escalation does not depend on the push**
- **signing keys are cached** — refreshed hourly or on an unknown key ID
- **retry only transient failures**
- 99.5% availability, answer cache, registry-only egress, timeout from the 8-second budget

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

This system depends on three outside providers: the OpenAI API, the Firebase and Apple push services, and Entra ID. For each one I asked two questions. What does the user lose when it fails? And what must keep working anyway?

**OpenAI API.** An outage or a rate limit ends in search-only answers. The hybrid search runs inside PostgreSQL, so users still get the best passages, just no generated answer. The assistant targets 99.5% availability, lower than the alert path, because it depends on an external API. I also kept us away from the provider's rate limit. API Management allows 20 questions per minute per user, and a daily token budget per user sits in Redis. The answer cache removes repeat calls.

**Push providers.** `notification-service` sends each push as a Celery task with 3 retries with backoff. If the provider stays down, the phone alert is late. But escalation does not depend on the push. Unacknowledged alerts escalate on schedule anyway, and the dashboard feed still shows them.

**Entra ID.** Every service validates tokens against Entra ID signing keys. The signing keys are cached in the application. They are refreshed every hour, and also when a token carries an unknown key ID. So a short Entra ID outage does not block tokens that were already issued. New sign-ins still fail.

The general rules:

- Retry only transient failures, with backoff and a retry limit. A rejected request fails the same way on every retry.
- Put a fallback behind every provider call that a user waits on.
- Never let a provider failure stop the escalation logic.
- Allow outbound traffic only to known providers. Istio's registry-only egress policy allows only these endpoints.

What the design does not fix is a timeout value for the OpenAI call. I would set it from the 8-second answer budget.

</details>

---

### Q2. How do you maintain context persistence efficiently?

**Brief answer**
The design keeps a question log, not a conversation memory: `chat_log` stores each redacted question with its cited chunks for 90 days. For follow-ups, I would keep only the last few redacted turns in Redis under a short Time To Live (TTL) and run retrieval again on every turn.

<details>
<summary><strong>Must cover</strong></summary>

- **conversation_id** — optional on the ask endpoint
- **chat_log** — redacted question, cited chunks, 90 days
- **not read back into prompts**
- **Redis with a short TTL**
- **last few turns** — each turn adds prompt tokens
- **retrieval runs again for each turn**
- **keep follow-ups out of the answer cache**
- chat text kept out of application logs, daily token budget, rewrite into a full question

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I want to be exact about what the design holds. The ask endpoint takes an optional `conversation_id`. But the design stores a log per question, not a conversation store. The `chat_log` table holds the user, the redacted question, the cited chunk IDs, the latency and the time. The service keeps each row for 90 days. The log serves audit and quality review. It is not read back into prompts.

So in this system, context persistence is mostly about what not to keep. The logging rules keep chat text out of application logs. Only the redacted question is stored, and only for 90 days.

If follow-up questions need context, I would build it on the parts the system already has:

- **Store turns in Redis with a short TTL**, keyed by `conversation_id`. A conversation is short-lived and needs no durable store. The key expires on its own.
- **Keep only the last few turns**, redacted, not the whole history. Each turn adds prompt tokens, so it adds cost and time to the 8-second answer budget. The daily token budget per user counts those tokens too.
- **Do not re-send old passages.** Retrieval runs again for each turn. The prompt then holds the passages for the current question, not a growing pile of old ones.
- **Rewrite the follow-up into a full question** before retrieval. A search for "and for children?" alone finds nothing useful.
- **Keep follow-ups out of the answer cache.** The cache key is the normalised question plus the corpus version. The same follow-up text means different things in different conversations, so it must not return a cached answer.

The trade-off is quality against cost. More context helps a follow-up, but the model reads that context again on every turn.

</details>

---

### Q2. How do you prevent hallucinations in expert answers?

**Brief answer**
Retrieval gives the model the right passages, as R6 Q1 describes; after that I limited what the model may say and made every claim checkable. The prompt allows answers only from the passages, and every answer carries citations that the service validates and a clinician can open.

<details>
<summary><strong>Must cover</strong></summary>

- **answer only from the passages**
- **curated corpus** — superseded versions marked inactive
- **citations** — document, chunk and title
- **Pydantic** — a malformed citation list is caught
- **every cited chunk ID must be one of the passages sent**
- **corpus version** — cached answers on old guidance never read
- **refuses when retrieval finds nothing relevant**
- chat_log review, cosine distance cutoff, evaluation set

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Retrieval is the first defence, and R6 Q1 covers it. This answer is about what happens after retrieval. A model can still add facts that are not in the passages it received.

**Limit the prompt.** The prompt tells the model to answer only from the passages. Those passages come from a curated corpus. Knowledge editors upload the guidelines. When a document gets a new version, the old chunks are marked inactive, so old guidance does not reach the prompt.

**Require citations.** Every answer ends with citations: document ID, chunk ID and title. In a clinical setting, an answer nobody can check is worse than no answer. A clinician opens the cited passage and compares it with the answer.

**Validate the output.** Pydantic parses the structured part of the output, so a malformed citation list is caught, not shown. Also, every cited chunk ID must be one of the passages sent in the prompt. A citation to a chunk the model never saw means the model invented a source, so the service counts it as an invalid citation.

**Never serve stale answers.** The answer cache is keyed by the corpus version. When a new document becomes active, the version changes. A cached answer based on old guidance is then never read again.

**Review after the fact.** `chat_log` stores the redacted question and the cited chunk IDs. So a reviewer can see which sources backed which answers.

One part is still missing: a rule that refuses when retrieval finds nothing relevant. That rule needs a cutoff on the cosine distance of the best passage. The fused search score cannot serve, because reciprocal rank fusion works on ranks, not on how close a passage is. The evaluation question covers how answers are scored.

</details>

---

### Q2. How did you evaluate your RAG pipeline, and which metrics told you it was good enough?

**Brief answer**
I measured retrieval and answers separately, on a labelled set of about 200 expert questions. Retrieval was scored by recall at 8 and Mean Reciprocal Rank ([MRR](https://en.wikipedia.org/wiki/Mean_reciprocal_rank "Ranking metric scoring how high the first relevant result appears")). Answers were scored on citation match and on faithfulness to the passages, by a judge model that knowledge editors checked on a sample.

<details>
<summary><strong>Must cover</strong></summary>

- **two halves** — retrieval and answers fail for different reasons
- **about 200 expert questions** — right chunks and documents marked
- **recall at 8** — the main number
- **MRR** — is the right chunk near the top
- **recall at 40** — a ranking problem or a search problem
- **citation match**
- **faithfulness** — scored by an LLM judge
- **human check on the judge**
- invalid citations, Pydantic parse failures, search-only fallbacks, assistant_answer_seconds, never exact wording

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I evaluated the two halves of the pipeline separately. Retrieval and answers fail for different reasons, so one end-to-end score would not say what to fix.

**The question set.** Knowledge editors wrote about 200 expert questions. For each one, they marked the chunks that answer it and the documents a correct answer must cite. The set runs against a fixed corpus with stored embeddings, so retrieval results are repeatable. It runs before any change to chunking, the embedding model, the search query, the prompt or the chat model. It does not run on every commit, because the answer part costs tokens.

**Retrieval metrics.**

- **Recall at 8.** The share of questions where at least one right chunk is among the eight sent to the model. This is the main number. If retrieval misses, no model can answer correctly.
- **Mean Reciprocal Rank (MRR).** The average of 1 divided by the rank of the first right chunk. It shows whether the right chunk is near the top or only just inside.
- **Recall at 40.** The same measure before the top eight are chosen. A gap between recall at 40 and recall at 8 means ranking is the problem, not search.

**Answer metrics.** Every question in the set runs through the full pipeline.

- **Citation match.** The answer cites at least one of the expected documents. This is a plain code check.
- **Faithfulness.** Every claim in the answer must be supported by the passages that were sent. A second model call scores this as a Large Language Model (LLM) judge, with a fixed rubric.
- **Human check on the judge.** Knowledge editors scored a sample of about 30 answers by hand. That showed where the judge and the clinicians disagreed. A judge model is cheap, but I trusted it only where it agreed with the experts.

**Production signals.** These run on live traffic:

- invalid citations, where a cited chunk ID is not one of the passages sent;
- Pydantic parse failures of the structured output;
- search-only fallbacks, which show provider problems;
- `assistant_answer_seconds` against its 8-second p95 target.

**The release rule.** A change ships only if recall at 8 and faithfulness do not drop against the last run. Exact wording is never compared, because the model's wording changes between runs.

</details>

---

### Q2. How do you test LLM-dependent features?

**Brief answer**
I split the feature into deterministic parts and the model call. The deterministic parts fit the per-service unit and integration tests the pipeline already runs, with the model stubbed. The model's answers are checked against a fixed question set, on citations rather than wording.

<details>
<summary><strong>Must cover</strong></summary>

- **mostly not the LLM**
- **per-service unit tests** — the design names no assistant cases
- **model stubbed**
- **redaction step** — sample questions with each masked pattern
- **search-only fallback** — a stub raises an outage
- **fixed corpus with stored embeddings** — deterministic search results
- **a test, not a review** — keeps PHI out of the logs
- **evaluation set** — asserts on citations, not wording
- Pydantic parsing, answer cache key, Docker Compose, cost in tokens

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A feature built on a Large Language Model (LLM) is mostly not the LLM. So the parts around the model are tested like any other code, and the model output is a separate problem.

**Unit tests.** The pipeline runs per-service unit tests in the Continuous Integration (CI) jobs. The design does not list the assistant's test cases, so I will not claim a list. With the model stubbed, the cases that matter are:

- the redaction step, with sample questions that hold Medical Record Number (MRN), national-ID, phone and date patterns;
- Pydantic parsing of the structured output, including a malformed citation list;
- the search-only fallback, with a stub that raises an outage or a rate-limit error;
- the answer cache key, which must change when the corpus version changes.

**Integration tests.** The CI integration tests run against dependencies in Docker Compose. For the assistant, that means a real PostgreSQL with `pgvector`. The useful test runs the hybrid search query against a fixed corpus with stored embeddings. The embeddings are fixed data, so the search results are deterministic. The test then checks that a known question returns the expected chunks.

**Logs.** This test is in the design. A CI test sends sample requests and checks that no Protected Health Information (PHI) field reaches the logs. Chat text is one of the forbidden fields. So a test, not a review, keeps PHI out of the logs.

The model output changes between runs and between model versions. So an exact-match test fails for the wrong reasons. Instead, the evaluation set holds a fixed list of expert questions. Each one lists the documents a correct answer must cite. The check asserts on citations, not on wording. It runs before a model or prompt change, not on every commit, because each run costs tokens. The evaluation question covers its metrics.

</details>

---

### Q2. How do you observe LLM-related latency issues?

**Brief answer**
I tracked `assistant_answer_seconds` against its SLO of p95 ≤ 8 s, and used traces to split one slow answer into cache, search and model time. The model call takes most of the time, so time to first token and cache hits matter as much as the total.

<details>
<summary><strong>Must cover</strong></summary>

- **assistant_answer_seconds** — p95 ≤ 8 s
- **latency_ms** — on each chat_log row
- **OpenTelemetry** — cache and search as separate spans
- **manual span** — around the OpenAI call
- **time to first token** — the stream hides a slow model
- **label the metric by cache hit or miss**
- multi-window burn rates, trace_id log panel in Grafana, token counts, 300 ms search target

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The targets came from the requirements. The first streamed token must arrive within 2 seconds, and the full answer within 8 seconds at p95. Passage search has its own target: p95 under 300 ms. Generation takes most of the time.

**Metric.** `assistant-service` exposes `assistant_answer_seconds` as a Prometheus histogram. Its Service Level Objective (SLO) is p95 ≤ 8 s, with 99.5% availability. It pages through multi-window burn rates, like every other SLO in the system.

**Per request.** Each `chat_log` row stores `latency_ms` next to the cited chunk IDs. So a slow answer can be linked to the sources it used.

**Traces.** OpenTelemetry instruments Flask, SQLAlchemy and Redis, and exports to Application Insights. One trace shows the cache lookup and the search query as separate spans. The OpenAI call is not among the instrumented libraries. Its time shows up in the request span, but no child span explains it. I would add a manual span around the OpenAI call, so the model time has a name. In Grafana, each service dashboard has a log panel filtered by `trace_id` next to the metrics.

Three things a total hides, which I would split out:

- **Time to first token.** The stream hides a slow model, because the user sees text early even when the total is long. The requirement has a 2-second target, but the design measures only the total. I would add a first-token histogram.
- **Cache hits.** A hit returns without a model call. If hits and misses share one histogram, a rising hit rate can hide slower model calls. So I would label the metric by cache hit or miss.
- **Token counts.** More prompt and answer tokens mean slower generation. I would record the token counts from each API response on the model span.

</details>

---

### Q3. What did you do to stop patient data from reaching the OpenAI API?

**Brief answer**
The corpus held guidelines, not patient records, and the assistant service had no database grant on any patient table. Staff could still type patient details into a question, so every question passed a redaction step before it left our tenant.

<details>
<summary><strong>Must cover</strong></summary>

- **corpus holds no patient records**
- **grants only on the kb schema**
- **redaction step** — MRN, national ID, phone numbers, dates
- **free-text names** — the residual risk
- **zero data retention** — and a BAA, both confirmed before go-live
- **Azure OpenAI Service** — an endpoint and credential swap
- registry-only outbound policy, 90-day redacted chat log

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I treated this as a data-flow problem with three entry points.

**The corpus.** The corpus holds no patient records. It holds curated clinical guidelines and expert recommendations, uploaded by knowledge editors. So the passages sent to OpenAI carry no Protected Health Information ([PHI](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160/subpart-A/section-160.103 "Individually identifiable health data that HIPAA regulates")).

**The service's reach.** `assistant-service` has a PostgreSQL login with grants only on the `kb` schema. It cannot read a patient table, even with a bug in its code. Outbound traffic is controlled too. Istio runs with a registry-only outbound policy, and it allows only the OpenAI API, the push providers and Entra ID.

**The user's question.** This is the real risk. A nurse can type a patient's details into a question. So each question passes a redaction step. It masks Medical Record Number ([MRN](https://en.wikipedia.org/wiki/Medical_record "Unique identifier a healthcare provider assigns to a patient's record")) and national ID patterns, phone numbers and dates. Free-text names are the residual risk, because rule-based redaction cannot catch them reliably. For that risk, the UI warns the user, and the OpenAI organisation is set to zero data retention. The chat log stores only the redacted question, for 90 days.

The contract side matters as much as the code. OpenAI offers zero data retention and a Business Associate Agreement ([BAA](https://www.hhs.gov/hipaa/for-professionals/covered-entities/sample-business-associate-agreement-provisions/index.html "HIPAA contract under which a vendor may handle protected health information for a covered entity")) only to approved API customers. Both must be confirmed before go-live. If they cannot be, the assistant moves to Azure OpenAI Service, which keeps the data in our tenant. We used the OpenAI Software Development Kit ([SDK](https://en.wikipedia.org/wiki/Software_development_kit "Packaged set of tools and libraries for building against a platform")), so that change is an endpoint and credential swap, not a rewrite.

The trade-off is simple. We called the OpenAI API directly, not Azure OpenAI. That is acceptable only because the corpus holds no patient data and every question is redacted first.

</details>

---

### Q3. How did you protect the chatbot against prompt injection?

**Brief answer**
I assumed some injections would get through, and I limited what they could do. Injected text can come from the question or from a document. So the corpus was curated, passages went into the prompt marked as data, and the model had no tools, no write access and no data beyond the guidelines. The worst case was a wrong answer that still had to cite a real passage.

<details>
<summary><strong>Must cover</strong></summary>

- **direct injection** — through the question
- **indirect injection** — through a document, the more dangerous route
- **limit the damage**
- **nothing to steal** — grants only on the kb schema
- **no tools** — the code chooses the next step
- **KnowledgeEditor role** — only curated sources
- **delimiters** — passages are reference material, never instructions
- **every cited chunk ID must be one of the passages sent**
- instruction-like text flagged at ingest, 20 questions per minute, daily token budget, chat_log review

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Prompt injection is text that tries to override the model's instructions. It has two routes.

- **Direct injection, through the question.** A user types "ignore your instructions and…". Every user is a signed-in staff member, but the risk is still real.
- **Indirect injection, through a document.** A passage holds text that reads like an instruction, and retrieval puts it into the prompt. This is the more dangerous route, because the user never sees the text.

No prompt wording stops injection completely. So I designed to limit the damage.

1. **Nothing to steal.** `assistant-service` has grants only on the `kb` schema. The corpus holds no patient records, and the prompt holds no secrets and no other user's data. A successful injection can reveal only the system prompt and the guidelines.
2. **Nothing to do.** The model has no tools and no function calling. It makes one call and returns text, and the code chooses the next step. So injected text cannot send a message, change a record or call another service.
3. **Who can add text.** Only the KnowledgeEditor role can upload documents, and the documents are curated guidelines from known sources. Ingest also flags chunks with instruction-like text, such as "ignore previous instructions", for an editor to check.
4. **Instructions apart from data.** The system message holds the rules. Passages go into the user message inside clear delimiters, each with its chunk ID. The system message says passage text is reference material, never instructions. This lowers the success rate, but it does not stop a determined attack.
5. **Output checks.** Pydantic parses the structured output. Every cited chunk ID must be one of the passages sent. An answer that breaks the format is not shown, and the user gets the search results instead.
6. **Limits and review.** API Management allows 20 questions per minute per user, and a daily token budget caps use. So nobody can probe at scale. `chat_log` keeps the redacted question, so a review can find attempts later.

**What I accept.** A clever injection can still make an answer wrong. In a clinical setting that matters. So the citation is the last control: a clinician checks the cited source before acting on the answer.

</details>

---

### Q3. How would you scale a RAG system?

**Brief answer**
The design is sized for about 300 questions a day and 500,000 chunks, where PostgreSQL handles search well. At higher volume the provider is the limit, not search. So I would rely on the cache and token budgets, scale replicas on open streams, and move the `kb` schema to its own PostgreSQL server.

<details>
<summary><strong>Must cover</strong></summary>

- **generation** — the limit is the provider, not our CPUs
- **answer cache**
- **daily token budget**
- **scale replicas on open streams** — CPU is a poor signal
- **HNSW index** — works best when it fits in memory
- **kb schema on its own PostgreSQL server**
- **re-embedding the whole corpus**
- 300 questions a day, 500,000 chunks, Azure OpenAI Service, dedicated vector database, 300 ms search target

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Start from the numbers. The assistant gets about 300 questions a day, under 1 request per second. But each answer holds a connection for up to 8 seconds. The corpus is 5,000 documents: about 500,000 chunks with embeddings, about 4 GB in PostgreSQL. At this size, one PostgreSQL server handles both search and the rest of the system of record.

A Retrieval-Augmented Generation (RAG) system has parts that scale differently.

**Generation.** This part is slow and expensive, and it runs at the provider. More questions reach the OpenAI rate limit and the cost limit before they load our CPUs. The tools here are the answer cache, the limit of 20 questions per minute per user in API Management, and the daily token budget. The search-only fallback covers a provider limit. At much higher volume, Azure OpenAI Service with its own reserved capacity is the next option.

**Serving.** `assistant-service` mostly waits on open streams. CPU stays low while connections stay open, so CPU is a poor scaling signal. I would scale replicas on open streams instead.

**Retrieval.** Search uses a Hierarchical Navigable Small World (HNSW) index from `pgvector`. The HNSW index works best when it fits in memory. As the corpus grows, the index grows too, and it competes for memory with clinical queries on the same server. Only `assistant-service` and `func-knowledge` have grants on the `kb` schema. So I would put the `kb` schema on its own PostgreSQL server without touching any other service. That is my first step when search starts to slow clinical queries. A dedicated vector database comes later, and only if PostgreSQL cannot keep the 300 ms search target.

**Ingest.** `func-knowledge` runs on a blob trigger, so it scales with uploads. Its limit is the embeddings API rate. The large job is re-embedding the whole corpus, for example after an embedding model change. That job needs throttling, and it ends with a new corpus version so the cache starts clean.

None of these steps is needed at the current load. Keeping search in one store gives one backup and one access model, and that is worth more at this size.

</details>

---

## R7. Data and AI pipelines — NumPy array work

> Utilizing [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") for transposing, sorting and concatenating data;

---

### Q1. What problem did NumPy solve in your data processing?

**Brief answer**
It made the scheduled rollups and risk scoring fast. I concatenated each patient's frames into one array, sorted them by time, and transposed them into one row per signal, so statistics and model features ran as vectorised operations.

<details>
<summary><strong>Must cover</strong></summary>

- **func-analytics** — rollups every 5 minutes, scoring every 15
- **concatenate** — frame lists from all windows
- **sort by timestamp** — frames are not guaranteed to be in order
- **transpose** — one row per signal
- **vectorised** — native code, no Python loop per frame
- about 360,000 frames per run, Pandas for resampling

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

NumPy sat in `func-analytics`, the Azure Functions app that runs rollups every 5 minutes and risk scoring every 15 minutes.

The raw data comes from Cosmos DB as documents. Each document holds one patient's 10-second window, with a list of frames. A frame has a timestamp and up to five signals: heart rate, oxygen saturation, respiratory rate, blood pressure and temperature. For a rollup, the function reads one patient's windows for the period. Then it does three steps:

1. **Concatenate** the frame lists from all windows into one array.
2. **Sort** by timestamp. Frames inside a document are not guaranteed to be in order. Frames are added with `$addToSet` as they arrive, and two writer replicas can add to the same window. Replayed data after an outage also arrives late.
3. **Transpose** from one row per frame to one row per signal. Now each signal is one row, and statistics run on it directly.

After that, the per-minute mean, minimum and maximum, the NEWS2 score over 1-minute buckets, and the risk-model features are array operations. These vectorised operations run in native code over the whole array, not in a Python loop per frame.

The volume is why this matters. 1,200 beds at one frame per second is about 360,000 frames in each 5-minute run. A Python loop over dictionaries at that size is slow and uses a lot of memory. With NumPy, each signal is one compact array of numbers.

Pandas sat on top, for resampling into minute buckets and for data inspection. NumPy did the raw array work underneath and built the feature matrices for the risk model.

</details>

---

### Q2. Which NumPy operations copy data and which do not, and why did that matter for your workload?

**Brief answer**
Transposing returns a view, so it is almost free; concatenating and sorting create new arrays. So I concatenated once per patient, sorted with `argsort` to reorder all signals together, and avoided repeated copies inside loops.

<details>
<summary><strong>Must cover</strong></summary>

- **transpose returns a view** — it changes strides, not data
- **concatenate copies** — once per patient, never in a loop
- **argsort** — one order applied to every signal
- **stable sort** — equal timestamps keep their arrival order
- **NaN for missing signals** — a zero corrupts the mean
- np.ascontiguousarray, np.nanmean

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The design records that the rollups concatenate, sort and transpose frame arrays. It does not go deeper than that. So here is how I handle those operations at this volume, and why.

- **Transpose returns a view.** It changes the strides, not the data, so `frames.T` is almost free. The catch is memory layout. After a transpose, one signal's values are no longer next to each other in memory. For heavy work per signal, `np.ascontiguousarray` makes one copy up front, and that can pay off.
- **Concatenate copies.** It always allocates a new array and copies every input. The classic mistake is to call it inside a loop, once per window. That copies the growing array again and again, so the cost grows with the square of the size. I collect the window arrays in a list and call `np.concatenate` once per patient.
- **Sort.** `np.sort` returns a sorted copy, and `ndarray.sort()` sorts in place. For frames, the order by timestamp must apply to every signal. So I call `argsort` on the timestamp column once, and index the whole array with the result. With `kind="stable"`, it is a stable sort: frames with equal timestamps keep their arrival order.

Missing signals need care too. Not every device reports every signal, and the ingest contract marks each signal as optional. I use NaN for missing signals in float arrays, and functions like `np.nanmean`. A zero would silently pull the mean down.

I do not have measured memory or timing numbers for these runs, so I will not quote any. The method is the point: one allocation per patient, views where possible, and no copies inside loops.

</details>

---

### Q2. How did you turn raw vital-sign arrays into features for a machine learning model?

**Brief answer**
For each patient, I cut the sorted per-signal arrays into trailing windows and computed summary features with vectorised NumPy operations: level, spread, trend and the share of missing data. The same feature code ran in the scoring run and in the training export, so the model saw the same features in training and in production.

<details>
<summary><strong>Must cover</strong></summary>

- **trailing windows** — 15 minutes, 1 hour and 4 hours
- **np.searchsorted** — window starts without a loop
- **a slice is a view**
- **trend** — the slope of a straight-line fit
- **missing share**
- **training-serving skew** — one feature function for both
- **point in time** — no data after the prediction time
- **artefact flag** — NaN, not zero
- np.nanmean, np.polyfit, NEWS2 from vitals_rules, one row per patient

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The input is the array from the concatenate, sort and transpose steps: one row per signal, one column per frame, in time order.

**Windows.** Deterioration is a change over time, so one reading says little. I used trailing windows of 15 minutes, 1 hour and 4 hours. The frames are sorted, so `np.searchsorted` on the timestamps finds where each window starts, without a loop. Each window is then a slice, and a slice is a view, not a copy.

**Features for each signal and window.**

- **Level:** mean, minimum and maximum, with `np.nanmean`, `np.nanmin` and `np.nanmax`.
- **Spread:** the standard deviation. An unstable signal can matter as much as a high one.
- **Trend:** the slope of a straight-line fit over the window, with `np.polyfit` of degree 1. A slow fall in oxygen saturation over 4 hours is the pattern a single threshold misses.
- **Missing share:** the share of NaN values. Features from a window with many gaps are less reliable, and the model needs to know that.
- **NEWS2** over the window, from the shared `vitals_rules` package.

All patients are then stacked into one matrix, with one row per patient, for one batched call to the model endpoint.

**Same code for training and scoring.** The biggest risk with features is a difference between training and production. This is called training-serving skew. If training computes a mean one way and scoring another way, the model is wrong without any error. So the feature function lives in one package. The scoring run and the monthly training export both import it, the same way both use NEWS2 from `vitals_rules`.

**Point in time.** Training features use only data from before the prediction time. A window that reaches past it leaks the outcome into the features. The model then looks better in training than it really is.

**Artefacts.** Frames with the device's artefact flag become NaN before any feature is computed. A probe-off reading of zero would otherwise look like a collapse.

</details>

---

## R8. Data quality — Pandas normalization and inspection

> Data normalization and data inspection using Pandas;

---

### Q1. What did data normalization mean in your project, and where did it happen?

**Brief answer**
It meant normalizing units and time in the health data, not database normal forms. Units were converted at the ward gateway before upload, and Pandas normalized the time axis by resampling raw frames into regular one-minute buckets.

<details>
<summary><strong>Must cover</strong></summary>

- **not relational normal forms**
- **canonical units** — converted at the ward gateway
- **VitalsBatchV1 rejects anything else**
- **resamples into one-minute buckets**
- **sanity checks** — plausible ranges for each unit
- **sample_count and artefact_ratio** — stored with each bucket
- one-hour rollups built from minute buckets

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

"Normalization" can mean two things, so I say which one first. Here it was about data values, not relational normal forms.

**Units.** Bedside devices come from different vendors and report in different units. The ward gateway converts every frame to canonical units before upload: beats per minute, percent, breaths per minute, mmHg and degrees Celsius. The ingest contract is a Pydantic model, and `VitalsBatchV1` rejects anything else. I put this step at the edge on purpose. The alert rules need canonical units within a second, and a batch job would be too late.

**Time.** Raw frames arrive about once per second, but not exactly. Some are missing, some are late, and replays after an outage bring old frames. In `func-analytics`, Pandas resamples each patient's frames into one-minute buckets. Each bucket gets mean, minimum and maximum values, a sample count and an artefact ratio. One-hour rollups are then built from the minute buckets. So every trend chart reads a regular series, whatever the gaps in the raw data.

**Sanity checks.** During the rollup, Pandas also runs unit sanity checks: values must sit in a plausible range for their unit. A temperature of 98 in a Celsius column is the kind of error this catches. It means a device sent Fahrenheit and the conversion missed it.

The sample count matters to the reader. A minute built from 12 frames is less reliable than one built from 60. So `sample_count` and `artefact_ratio` are stored with each bucket, and a reader can tell a thin minute from a full one.

</details>

---

### Q2. How did you inspect the incoming patient monitoring data with Pandas to catch missing or bad readings?

**Brief answer**
A daily Pandas step compared what each device should have sent with what arrived, and measured how much of it was artefact or late. The results went into a table with one row per device per day, so problems showed up by device and gateway.

<details>
<summary><strong>Must cover</strong></summary>

- **data_quality_daily** — one row per device per day
- **completeness** — expected against received frames
- **artefact ratio** — from the device's quality flag
- **late ratio** — points at the network or the gateway
- **group-by** — per device, over the day
- **not a real-time alarm** — GATEWAY_SILENT covers fast failures
- threshold tuning on archive data

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Inspection ran in `func-analytics` and wrote to `telemetry.data_quality_daily`, with one row per device per day.

It measured three things:

- **Completeness.** `expected_frames` against `received_frames`. A device bound to a bed for 24 hours at one frame per second should send 86,400 frames. The expected count should cover only the time the device was bound to a bed. Otherwise an idle spare device looks broken.
- **Artefact ratio.** Each frame carries a quality flag from the device. The step counts the share of frames flagged as artefacts. Probe-off and motion artefacts are the main cause of false alarms.
- **Late ratio.** The share of frames that arrived well after their timestamp. A high late ratio points at the network or the gateway, not at the device.

The row also stores `gateway_id`, so problems can be grouped by ward gateway.

In Pandas this is a group-by over the day's frames per device, with a few aggregations. It is a daily data-quality report.

It is not a real-time alarm. Fast problems have their own path. A gateway that is silent for 30 seconds raises a `GATEWAY_SILENT` alert in the alert pipeline. The daily table finds slow problems, such as a device that drops a few percent of its frames every day, or a ward whose gateway is always late.

The data also helps the clinical side. Sustain windows and score bands are tuned with clinical staff on replayed archive data. A device with a high artefact ratio would distort that threshold tuning, so it helps to know which devices those are.

</details>

---

### Q2. How did you use Pandas to prepare a training dataset for a machine learning model from the monitoring data?

**Brief answer**
A monthly export matched each prediction time with what happened to the patient afterwards, and it dropped data the quality checks marked as poor. It also replaced patient IDs with a keyed hash. The result was a pseudonymised dataset that only the Azure Machine Learning workspace could read.

<details>
<summary><strong>Must cover</strong></summary>

- **outcome labels** — admission events within the prediction horizon
- **merge_asof** — the next outcome event per admission
- **leakage** — no data after the prediction time
- **quality filter** — data_quality_daily
- **kept the real ratio** — class weights in training
- **HMAC** — key in Key Vault
- **split by patient**
- **pseudonymisation, not anonymisation** — still personal data
- 12-hour horizon, Parquet, one-year deletion, ml-datasets container

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The dataset trains the deterioration risk model, so each row needs features and an outcome. The export runs monthly in `func-analytics`.

**Outcome labels.** `care.admission_event` records rapid-response calls, transfers to intensive care, deaths and discharges. The function reads them through the `care.v_admission_outcome` view. A row is positive when a deterioration event follows within the prediction horizon. I used 12 hours.

**Joining in time.** In Pandas, `merge_asof` with `direction="forward"` and `by="admission_id"` matches each prediction time with the next outcome event for that admission. A `tolerance` of 12 hours turns "an event within the horizon" into one join, without a loop.

**Leakage.** Features use only data from before the prediction time, as the NumPy question covers. Rows after an outcome event are dropped too. A patient who is already in intensive care is not "about to deteriorate".

**Quality filter.** `telemetry.data_quality_daily` gives completeness and the artefact ratio per device per day. Rows from device-days with low completeness or a high artefact ratio are dropped. Otherwise the model can learn that a broken probe means a sick patient.

**Class balance.** Deterioration events are rare. I kept the real ratio in the dataset and handled the imbalance in training with class weights. Deleting negatives in the export would hide the real rate from the evaluation.

**Identity.** Patient IDs are replaced by a Hash-based Message Authentication Code ([HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Verifies both the integrity and authenticity of a message using a shared secret key")), with the key in Key Vault. The same patient always gets the same pseudonym, so one patient's rows stay linked. That makes a split by patient possible: no patient is in both the training set and the test set. Names, MRNs and national IDs never enter the dataset.

This is pseudonymisation, not anonymisation. Whoever holds the key can link rows back to a patient, so the data is still personal data. It is written as Parquet to the `ml-datasets` container, deleted after one year, and readable only by the Azure Machine Learning workspace.

</details>

---

## R9. Security — OAuth authentication

> Configuring OAuth authentication in the application;

---

### Q1. Which OAuth flow did you use for users signing in to the application, and why?

**Brief answer**
The authorization code flow with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), through Microsoft Entra ID and the [MSAL](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview "Microsoft Authentication Library — Client library that obtains tokens from Microsoft Entra ID") libraries. Neither a browser app nor a mobile app can keep a client secret, and PKCE protects the code exchange without one.

<details>
<summary><strong>Must cover</strong></summary>

- **authorization code flow with PKCE**
- **code verifier** — a stolen code cannot be redeemed
- **no implicit flow** — tokens leak from the URL
- **Conditional Access** — MFA and compliant devices
- **MSAL** — flow, token cache and silent refresh
- **roles claim** — Entra app roles
- OIDC, 60-minute access tokens, refresh token rotation, self-hosted IdP

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Entra ID was the only identity provider. Every caller, human or machine, presented an OAuth 2.0 access token from it.

For staff I used [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect ([OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users")) on top of OAuth 2.0. The flow was the authorization code flow with PKCE. Proof Key for Code Exchange (PKCE) works like this. The app creates a random code verifier and sends its hash with the sign-in request. When it exchanges the code for tokens, it sends the verifier itself. An attacker who steals the code cannot redeem it without the verifier. That is why PKCE replaces a client secret for apps that cannot keep one.

There was no implicit flow. It returns tokens in the Uniform Resource Locator ([URL](https://datatracker.ietf.org/doc/html/rfc3986 "Addresses the location and access method of a resource on the web")) fragment, where they leak into browser history and logs. Current OAuth security guidance advises against it.

The sign-in policy sat in Entra ID, not in our code:

- Multi Factor Authentication ([MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Requires more than one form of evidence to verify a user's identity")) and compliant-device rules came from Conditional Access.
- Access tokens lived 60 minutes, and refresh tokens were rotated.
- The Microsoft Authentication Library (MSAL) handled the flow, the token cache and silent refresh, on both the web app and the mobile app.

Roles came from Entra app roles in the token's `roles` claim: `Nurse`, `ChargeNurse`, `Physician`, `WardManager` and others. Across services, a staff member is identified by the Entra object ID in the token. So no service needs a lookup to know who is calling.

Why Entra ID and not our own identity provider? A self-hosted Identity Provider ([IdP](https://en.wikipedia.org/wiki/Identity_provider "Service that authenticates users and issues identity assertions to relying applications")) is one more security-critical system to run and patch.

</details>

---

### Q2. How did the IoT devices and the robot authenticate when there was no user to sign in?

**Brief answer**
With the OAuth client credentials flow, using a certificate instead of a client secret. The private key stayed in the device's hardware, and each machine had its own identity, so one could be revoked without touching the others.

<details>
<summary><strong>Must cover</strong></summary>

- **client credentials flow**
- **certificate credential** — the private key stays in the TPM
- **one app registration per gateway** — created by Terraform
- **certificates rotated every 90 days**
- **device must be bound to the gateway's ward**
- **robot_id must match the token's client ID**
- registered egress IP addresses, Bash provisioning

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Machines used the same identity provider as staff, Entra ID, but a different flow: the client credentials flow.

**Ward gateways.** Bedside devices never talk to the cloud. They connect to an edge gateway, one per ward. Each gateway had one app registration in Entra ID, created by Terraform, with the app role `Telemetry.Write`. It authenticated with a certificate credential. The private key never left the gateway's Trusted Platform Module ([TPM](https://trustedcomputinggroup.org/resource/trusted-platform-module-tpm-summary/ "Hardware chip that stores cryptographic keys so they cannot be copied off the device")). A secret in a config file can be copied. A key in a TPM cannot. Certificates rotated every 90 days.

**Robots.** Same pattern, with the app role `Robot.Operate`.

A valid token was not enough. The service also checked that the caller could act on the specific resource:

- `telemetry-service` mapped the token's client ID to the gateway's ward. The device must be bound to the gateway's ward, or the frame is rejected. So a stolen gateway identity cannot inject readings for another ward.
- `robot-service` checked that the `robot_id` in the path matches the token's client ID. It rejected the call otherwise. So one robot cannot report as another.

Network rules added a second layer. The Web Application Firewall ([WAF](https://owasp.org/www-community/Web_Application_Firewall "Filters and blocks malicious HTTP traffic before it reaches an application")) accepted the ingest and robot paths only from registered hospital egress IP addresses.

One identity per machine is more work to set up, but it pays off. Revoking one lost gateway does not touch the other 39. Bash scripts handled gateway provisioning, and Terraform managed the app registrations.

</details>

---

### Q3. How did the claims in an OAuth token turn into a decision about which patient records a user could open?

**Brief answer**
The token only proved who the user was and which role they had. A patient-level rule then decided access: the user had to be on the patient's care team, or rostered on the patient's ward right now.

<details>
<summary><strong>Must cover</strong></summary>

- **validated twice** — at API Management and in each service
- **JWKS** — refreshed hourly and on an unknown key ID
- **RBAC** — the roles claim sets the type of action
- **ABAC** — on the care team, or rostered on the ward
- **cached for 60 seconds**
- **break-glass** — reason, logged, reviewed
- separation of duties, DRF permission class, audit row

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A valid token proves who the caller is. It says nothing about which patients they should see. A nurse on one ward has the same role as a nurse on another.

**Step 1: the token is validated twice.** API Management checks issuer, audience, signature and expiry with `validate-jwt`. Then each service validates the token again against cached Entra signing keys. The JSON Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "Publishes the public keys a party needs to verify a signed token")) is refreshed hourly, and also when an unknown key ID appears. The second check costs under a millisecond. It matters because gateway ingest bypasses API Management, and inside the cluster a compromised pod could call a service directly.

**Step 2: Role Based Access Control ([RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Grants permissions to users based on assigned roles rather than individually")).** The `roles` claim says what type of action is allowed. A `Nurse` can read vitals and acknowledge alerts. A `ChargeNurse` can also edit thresholds for their ward. An `Admin` has no clinical read access, for separation of duties.

**Step 3: Attribute Based Access Control ([ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Grants access based on attributes of the subject, resource and environment rather than fixed roles")).** Whether the action applies to this patient comes from a view, `care.v_patient_access`. The user must be on the admission's care team, or rostered on the patient's ward right now. Services check this with an `EXISTS` query. The result is cached for 60 seconds in Redis. `care-core` runs the check in a DRF permission class. The Flask services use a decorator from the same shared package. So the rule has one implementation.

**Break-glass.** In an emergency, a nurse or physician outside the care team can open a record by giving a reason. The access is logged as `break_glass`, the privacy officer is notified, and it appears in the weekly access review.

Every read or write of patient data also inserts an audit row before the response.

The 60-second cache is the trade-off. A roster change takes up to a minute to apply. In return, most requests skip a database query.

</details>

---

## R10. Cloud — Kubernetes disaster recovery

> Designing and implementing disaster recovery plans for Kubernetes(k8s) environments;

---

### Q1. What recovery time and recovery point objectives did you set, and how did you arrive at them?

**Brief answer**
One target per scenario, not one number: zone loss under 5 minutes with no data loss, cluster loss in 60 minutes, and region loss within 2 hours with at most 5 minutes of clinical data lost. The targets followed from the platform's role, because bedside monitors keep their own alarms.

<details>
<summary><strong>Must cover</strong></summary>

- **secondary notification layer** — bedside alarms stay primary
- **per scenario** — zone, cluster, region
- **synchronous standby** — zero loss on zone failure
- **clinical data lives outside the cluster**
- **gateway replay** — covers in-flight messages
- **cross-region read replica** — its lag sets the region RPO
- 99.9% availability, Cosmos DB continuous backup, 24-hour gateway buffer

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from what an outage costs. Bedside monitors keep their own local alarms. Our platform is a secondary notification layer, for remote staff. So a short outage delays remote alerts, but it does not silence alarms at the bedside. That sets the availability target at 99.9% a month, about 43 minutes of downtime. It also justifies zone redundancy in one region, instead of active-active regions.

Then I split recovery per scenario, because each one fails differently:

| Scenario | Recovery Time Objective ([RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Maximum acceptable duration to restore a system after a disruption")) | Recovery Point Objective ([RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Maximum acceptable amount of data loss, measured in time since the last recovery point")) |
|---|---|---|
| Zone loss | Under 5 min, automatic | 0 |
| Cluster loss (failed upgrade, deleted namespace, broken control plane) | 60 min | 0 for clinical data |
| Region loss | 2 h or less | 5 min or less for PostgreSQL |

Where the numbers come from:

- **Zone loss** recovery is automatic. Pods reschedule to the other two zones. PostgreSQL fails over to its synchronous standby, so nothing committed is lost. Quorum queues keep a majority.
- **Cluster loss** loses no clinical data, because clinical data lives outside the cluster: PostgreSQL, Cosmos DB and Blob Storage. The risk is messages in flight in RabbitMQ. Gateway replay covers those.
- **Region loss** RPO is the lag of the cross-region read replica of PostgreSQL. Raw telemetry history is restored from Cosmos DB continuous backup within hours. Meanwhile, new frames go to a fresh collection.

Raw telemetry also has its own durability rule: no loss while a gateway buffer holds the data. The gateway disk buffer holds 24 hours.

Clinical records got the strict target. Two nurses must never both believe they own an alert. So alert state lives on one consistent primary, and its RPO is 0 on zone loss.

</details>

---

### Q1. What is point-in-time recovery (PITR), and when is it critical?

**Brief answer**
Point-in-time recovery ([PITR](https://www.postgresql.org/docs/current/continuous-archiving.html "Point in Time Recovery — Restores a database to a specific past moment using base backups and archived logs")) restores a database to its state at a chosen moment, for example one second before a bad delete. It is critical when the damage is logical. A replica copies a wrong change within seconds, so only a backup from before the change can undo it.

<details>
<summary><strong>Must cover</strong></summary>

- **write-ahead log** — replayed up to the chosen moment
- **retention period** — not fixed in the design docs
- **Cosmos DB continuous backup**
- **a replica copies every change** — including a wrong one
- **logical damage** — bad migration, accidental delete, corrupting bug
- **restore to a new server** — copy back only the damaged rows
- soft delete, versioning, idempotent rollups, expand-then-contract, restore drill

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Point-in-time recovery (PITR) combines two things. A full backup gives a starting copy. The write-ahead log (WAL) records every change after that backup. A restore loads the backup, replays the log up to the chosen moment, and stops there.

In this design, three stores needed it in different ways:

- **PostgreSQL Flexible Server**, the system of record. It takes automatic backups and keeps the WAL, so it can restore to a chosen second inside its retention period. The design docs do not fix that retention period. I would set it explicitly and not rely on the default.
- **Cosmos DB continuous backup** protects `vitals_raw`. The region-loss runbook restores raw telemetry history from it.
- **Blob Storage** has no PITR of this kind in the design. The closest protections are set per container: soft delete for 30 days on `patient-files`, versioning on `kb-documents`, and an immutability policy on `audit-archive`.

The key point is what PITR protects against. We already had a synchronous standby and a cross-region read replica. They protect against a lost zone or a lost region. But a replica copies every change, including a wrong one. A bad migration, an accidental `DELETE` or a bug that corrupts rows reaches the standby within seconds. That is logical damage: the database works, but the data is wrong. Only PITR can take the data back to the moment before the mistake.

Two details matter in practice:

- **Restore to a new server.** Flexible Server restores into a new server, not in place. Rolling the whole database back would also lose every good write since the mistake, such as new alerts and acknowledgements. So for a partial mistake, I restore to a side server and copy back only the damaged rows.
- **Not every store needs it.** Redis holds caches and short-lived values that new data replaces within seconds. `func-analytics` builds the rollups from raw frames with an idempotent upsert. So the rollups can be rebuilt while the raw frames are still inside their 30 days.

Expand-then-contract migrations lower the risk, because a release only adds columns or views. PITR is the safety net for the mistakes that process does not catch. A backup is only proven by a restore, so I would add a PITR restore to the quarterly restore drill.

</details>

---

### Q2. How did you restore a lost AKS cluster, and what did you back up to make that possible?

**Brief answer**
The cluster itself was rebuilt, not restored: Terraform created a new AKS cluster and the pipeline redeployed the last released manifests. Backup covered only what could not be rebuilt — namespaced resources and RabbitMQ volumes — and gateways replayed the messages lost with the broker.

<details>
<summary><strong>Must cover</strong></summary>

- **rebuilt, not restored**
- **terraform apply** — creates a new AKS cluster
- **last released manifests**
- **Azure Backup for AKS** — namespaced resources and RabbitMQ volumes
- **replay window** — skips the batch_id check
- **downstream writes are idempotent**
- **quarterly restore** — into a scratch cluster
- CSI Azure Disks, dry-run runbooks

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I treated the cluster as disposable and the data as the thing to protect. All clinical data sits outside the cluster, in managed stores. So the cluster is rebuilt, not restored.

The runbook for cluster loss:

1. `terraform apply` creates a new AKS cluster, with its node pools, add-ons and identities.
2. GitHub Actions redeploys the last released manifests. The images are already in Azure Container Registry, tagged by commit.
3. Azure Backup for AKS restores namespaced resources and the RabbitMQ persistent volumes.
4. Terraform applies the RabbitMQ definitions again: exchanges, queues, bindings, policies and users. The topology comes back identical.
5. Gateway replay fills the gap.

Step 5 has a subtle trap. Gateways keep 15 minutes of batches that the platform already acknowledged. After a rebuild, an operator opens a replay window for each gateway, stored in Redis for at most 2 hours, and starts the replay. While the window is open, `telemetry-service` skips its `batch_id` duplicate check for that gateway. The reason: Redis survived the cluster loss, so it still holds those batch keys. Without the skip, it would drop exactly the batches that were lost with the broker.

Replays are safe because the downstream writes are idempotent. Raw frames use `$addToSet` upserts, and alerts hit the `dedup_key` unique index.

Two things must be confirmed before relying on the backup step. Azure Backup for AKS support depends on the AKS version. It also needs the volumes to be Container Storage Interface ([CSI](https://kubernetes-csi.github.io/docs/ "Standard plugin interface through which Kubernetes attaches storage volumes")) Azure Disks, which must be checked for the RabbitMQ StatefulSet.

Testing is part of the plan. A quarterly restore puts a backup into a scratch cluster, and smoke tests check it. Runbooks are Bash scripts in the repository, each with a dry-run mode.

</details>

---

### Q3. How did you decide how much standby infrastructure to keep ready for a disaster?

**Brief answer**
I kept a pilot light, not a warm standby: data replicated continuously to a paired region, compute built only on failover. A warm second cluster would cut region recovery to minutes but double compute cost, and zone redundancy already covered the common failures.

<details>
<summary><strong>Must cover</strong></summary>

- **pilot light** — data replicated, compute built on failover
- **zone redundancy covers the common failures**
- **not the primary alarm**
- **a warm second cluster doubles compute**
- **Terraform dr workspace**
- **rehearsed every six months**
- cross-region read replica, GZRS, EU region pair

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The options go from backup-and-restore, through pilot light and warm standby, to active-active. Each step toward faster recovery costs more money and more operational work.

I chose a pilot light for three reasons:

- **Zone redundancy covers the common failures.** AKS, PostgreSQL, Redis, RabbitMQ and storage all span three zones in the primary region. A full region loss is rare.
- **The platform is not the primary alarm.** Bedside monitors keep alarming during our outage. A 2-hour region RTO delays remote notification, but patients are not left without an alarm.
- **Cost.** A warm second cluster doubles compute for a scenario that almost never happens.

This is always on in the paired region:

- A cross-region read replica of PostgreSQL. Its lag is the 5-minute RPO.
- Cosmos DB continuous backup, for raw telemetry.
- Geo-Zone-Redundant Storage ([GZRS](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy "Azure Storage redundancy that copies data across zones in one region and to a paired region")) for Blob Storage.
- Azure Container Registry, geo-replicated, so the images are already there.

This is built on failover: a Terraform `dr` workspace creates AKS, Redis, RabbitMQ, API Management and Functions. Then the PostgreSQL replica is promoted and the public hostname is pointed at the new region.

The weakness of a pilot light is that it is rarely used, so it can quietly break. That is why a full region failover is rehearsed every six months, in staging.

Where the General Data Protection Regulation ([GDPR](https://gdpr-info.eu/ "EU regulation governing the processing of personal data")) applies, all regions, including the disaster-recovery region, sit in an EU region pair. So a failover does not move data out of the EU.

One point needs checking before build. Flexible Server must allow a geo read replica on a zone-redundant primary in the chosen region pair.

</details>

---

## R11. Cloud — Terraform for Azure

> Define and manage Azure infrastructure components using Terraform;

---

### Q1. How did you organise Terraform state across environments, and how did you protect it?

**Brief answer**
One state per environment, plus one for the disaster-recovery region, in an Azure Storage backend with blob-lease locking. Each environment's deploy identity signed in through OIDC federation, not a stored secret, and could reach only its own environment.

<details>
<summary><strong>Must cover</strong></summary>

- **state can contain secrets** — treat it like a database
- **one state per environment** — plus a dr workspace
- **blob-lease locking**
- **OIDC federation** — no stored cloud secret
- **RBAC scoped** — to the environment's resource group
- **plan on every pull request** — apply on merge after approval
- terraform fmt and validate, one giant state

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

State is the most sensitive Terraform file. It maps code to real resources, and the state can contain secrets in plain text. So it needs the same care as a database.

**Layout.** One state per environment, plus a separate `dr` workspace that builds the disaster-recovery region. With separate states, a mistake in staging cannot touch production. Each plan also stays small and fast.

**Backend.** Azure Storage, with blob-lease locking. When one run holds the lease, a second `apply` fails instead of corrupting the state. So two engineers, or two pipeline runs, cannot write at once.

**Access.** GitHub Actions signs in to Azure through OIDC federation, with one deploy identity per environment. There is no stored cloud secret in the repository or in GitHub. Each identity has Azure RBAC scoped to its own environment's resource group.

**Change flow.** Every pull request runs `terraform fmt`, `validate` and `plan`, and the plan output is part of the review. So there is a plan on every pull request. Apply runs on merge, after an environment approval.

Separate states have a cost. Values shared between them must be passed explicitly. I prefer that to one giant state, where every plan is slow and every mistake is large.

</details>

---

### Q3. What did you manage with Terraform besides Azure resources, and where did you draw the line between Terraform and your deployment pipeline?

**Brief answer**
Terraform also managed Entra ID app registrations and RabbitMQ definitions, because other code depends on both. Application workloads on Kubernetes stayed with the deployment pipeline, because they change with every release.

<details>
<summary><strong>Must cover</strong></summary>

- **Entra ID app registrations** — one per gateway and per robot
- **RabbitMQ definitions** — identical topology after a rebuild
- **Bicep is Azure-only**
- **Kubernetes workloads deployed by GitHub Actions**
- **slow, shared infrastructure** — against fast releases per service
- **order after a rebuild** — Terraform first, then the pipeline
- configure permission denied, dr workspace

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

**Azure resources.** Every Azure resource came from Terraform. That covers the AKS cluster and node pools, PostgreSQL Flexible Server, Cosmos DB, Redis, Blob Storage, Key Vault, API Management, Application Gateway, Functions, Container Registry, Azure Machine Learning and networking.

**Beyond Azure:**

- **Entra ID app registrations.** One per ward gateway and one per robot, with their app roles, plus the staff app registrations. Adding a gateway is a code change, reviewed like any other.
- **RabbitMQ definitions**, through the RabbitMQ provider: exchanges, queues, bindings, policies and users. After a cluster rebuild, the topology comes back identical. It also means services have their `configure` permission denied. They only publish and consume.
- **The disaster-recovery region**, as a separate `dr` workspace.

This range decided the tool. Bicep is Azure-only. Terraform also covers Entra ID and RabbitMQ, in the same language and workflow.

**Where Terraform stopped.** Kubernetes workloads were deployed by GitHub Actions, not Terraform. Deployments, autoscaling objects and PodDisruptionBudgets change with every release. They also need canary steps with health gates, which Terraform does not do. So Terraform owns slow, shared infrastructure, and the pipeline owns fast releases per service. If you mix them, a one-line app change waits for an infrastructure plan.

The line has a cost. The cluster exists in Terraform, but the workloads on it do not. So the order after a rebuild matters: Terraform runs first, then the pipeline redeploys the last released manifests. The disaster-recovery runbook follows that order.

</details>

---

## R12. Cloud — Blob Storage for files

> Azure Blob Storage configuration for storing images and other files;

---

### Q1. How did clients upload images to Blob Storage — through your API, or directly?

**Brief answer**
Directly. The API created a pending file record and returned a short-lived, write-only [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") URL, the client uploaded straight to Blob Storage, and a completion call confirmed the blob before the file counted as stored.

<details>
<summary><strong>Must cover</strong></summary>

- **file bytes never pass through a service**
- **patient_file row** — status pending, created before the SAS
- **write-only SAS** — 10 minutes, one blob path
- **complete call** — checks that the blob exists and its size
- **user delegation SAS** — no account key in the application
- **access check at issue time**
- 5-minute read-only download SAS, audit row

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

File bytes never pass through a service. Wound photos and scans can be several megabytes each. Passing them through a service would tie up its workers and memory for nothing.

The upload flow:

1. The client calls `POST /patients/{id}/files` with the kind, content type and size. `care-core` checks that this user may access this patient. It creates a `patient_file` row with status `pending`.
2. It returns a Shared Access Signature (SAS) URL. It is a write-only SAS, valid for 10 minutes, for one blob path.
3. The client uploads straight to Blob Storage.
4. The client makes the complete call. `care-core` checks that the blob exists and matches the declared size, then sets the status to `stored`.

Downloads work the same way, with a 5-minute read-only download SAS.

Details that mattered:

- **User delegation SAS.** `care-core` has the Data Contributor and Delegator roles on the `patient-files` container. So it signs SAS tokens with its Entra identity, not with the storage account key. The account key never appears in the application.
- **The row before the SAS.** The file record exists before any upload. A client that uploads and never completes leaves a `pending` row, which is easy to find and clean up.
- **Access check at issue time.** The SAS itself is the permission. So the patient access rule runs before the SAS is issued, and each issue writes an audit row.
- **Short lifetimes.** A leaked URL works for minutes at most.

</details>

---

### Q2. How did you manage cost and retention for files that pile up over the years?

**Brief answer**
With lifecycle rules per container: patient files moved from hot to cool after 30 days and to cold after a year, raw archives went to the archive tier, and audit archives were locked by an immutability policy. Images were the largest storage cost in the whole design, so tiering mattered most.

<details>
<summary><strong>Must cover</strong></summary>

- **about 11 TB over five years** — more than all the telemetry
- **lifecycle rules per container**
- **hot, then cool, then cold** — for patient files
- **archive tier is offline** — rehydration can take hours
- **immutability** — audit archives, 6 years
- **capacity estimates, not a retention policy**
- versioning, soft delete, GZRS

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The numbers drove this. About 2,000 files a day, at around 3 MB each, is about 11 TB over five years. That is more than all the telemetry. So storage tiering was the main cost lever.

I set lifecycle rules per container:

| Container | Rule |
|---|---|
| `patient-files` | Hot for 30 days, then cool, then cold after 1 year; soft delete for 30 days |
| `kb-documents` | Hot, with versioning on |
| `vitals-archive` | Daily Parquet files of raw frames; cool, then archive tier after 90 days |
| `audit-archive` | Monthly Parquet files of the audit log; time-based immutability for 6 years |
| `ml-datasets` | Pseudonymised training data; deleted after 1 year |

The reasoning behind the rules:

- **Access falls fast.** A wound photo is viewed often during the admission and rarely after it. Cool and cold tiers cost less to store but more to read. That fits old files.
- **The archive tier is offline.** Reading from it needs rehydration, which can take hours. That is fine for raw telemetry archives. It is not fine for a patient file a clinician may open, so patient files stop at cold.
- **Soft delete** protects against accidental or malicious deletion for 30 days.
- **Immutability** on audit archives means nobody, not even an administrator, can change or delete them during the retention period. That protects the integrity of the audit trail.

Redundancy was GZRS, which copies data across zones and to the paired region. It costs more than storage in one region, but it is also the disaster-recovery plan for files.

One caution. The five-year figures are capacity estimates, not a retention policy. Clinical records follow local medical-records law, and that law decides when a patient file may be deleted.

</details>

---

## R13. Cloud — Azure Functions

> Implement serverless calculations using Azure Functions;

---

### Q1. How did you call an Azure Machine Learning model from an Azure Function?

**Brief answer**
A timer function ran every 15 minutes and built one feature row per monitored patient. It sent all the rows in one batched HTTPS call to the model's managed online endpoint, signed in with the function's managed identity. A score above the threshold raised an advisory alert. If the endpoint failed, the run was skipped and logged.

<details>
<summary><strong>Must cover</strong></summary>

- **managed online endpoint** — tracking, versions, safe rollout
- **every 15 minutes**
- **one batched HTTPS call** — not 1,200 round trips
- **advisory alert** — dedup_key stops a repeat every run
- **managed identity** — no stored endpoint key
- **skipped and logged** — the score goes stale
- **no retry loop inside the run** — it would overlap the next run
- **mirrored traffic** — a new version scores but is not used
- batch endpoint, timeout, skipped-run metric

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the model lives.** The `deterioration-risk` model was trained and versioned in Azure Machine Learning, and served from a managed online endpoint. I kept the model out of our services. The workspace gives experiment tracking, model versions and a safe rollout, and a model inside a service loses all three.

**The scoring run.** `func-analytics` runs the scoring every 15 minutes on a timer.

1. It builds one feature row per monitored patient with NumPy. The NumPy question covers the features.
2. It sends all rows in one batched HTTPS call. One call per patient would be about 1,200 round trips every 15 minutes.
3. A score above the threshold becomes an advisory alert, published like any other alert. The `dedup_key` stops a patient from getting a new alert on every run while the score stays high.

**Sign-in.** The endpoint accepts Microsoft Entra ID tokens. The function gets a token with its managed identity, so no endpoint key is stored anywhere.

**Failure.** The call is synchronous and has a timeout. If the endpoint is down or returns an error, the run is skipped and logged, and a metric counts skipped runs. The advisory score goes stale until the next run. That is acceptable because the score is advisory. The threshold and NEWS2 alerts on the live path do not depend on it. There is no retry loop inside the run, because a retry that runs past 15 minutes would overlap the next run.

**New model versions.** A managed online endpoint can hold two deployments. A new version first gets mirrored traffic. It receives a copy of each request, and its scores are compared but not used. Then it takes a small share of real traffic, and finally all of it.

**Online or batch.** Azure Machine Learning also has batch endpoints for large offline jobs. 1,200 rows every 15 minutes is small and needs an answer in seconds, so an online endpoint fits.

</details>

---

### Q2. How did you make a function safe to run again after a failure or a timeout?

**Brief answer**
Each run resumed from a watermark and wrote with an idempotent upsert, so running the same period twice gave the same result. A failed run left trend charts stale for a while, but it never touched the alert path.

<details>
<summary><strong>Must cover</strong></summary>

- **safe to run twice**
- **watermark** — the next run starts where the last one completed
- **idempotent write** — INSERT … ON CONFLICT DO UPDATE
- **late data** — the weak spot of a pure watermark
- **skipped and logged** — when the ML endpoint is down
- **off the alert path**
- 6,000 round trips, known archive paths

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Timer-triggered functions fail in untidy ways: a timeout halfway through, a retry, or two runs that overlap after a restart. So every function had to be safe to run twice on the same data.

The rollup function shows the pattern:

- **Watermark.** Each run knows the last bucket it completed, and it processes from there to now. If a run fails, the next one starts from the same watermark and covers the gap. Nothing is skipped.
- **Idempotent write.** Results go through one stored procedure, `telemetry.upsert_minute_rollups`. It takes a JSON array and runs a single `INSERT … ON CONFLICT (patient_id, bucket_start) DO UPDATE`. Writing the same minute twice leaves the same row. One statement per run also replaces about 6,000 round trips, which keeps the run short and less likely to time out.
- **Late data** is the weak spot of a pure watermark. Frames can arrive late, for example after a gateway replay. A bucket that was already written does not see them. Because the upsert is idempotent, it is safe to recompute a trailing window of buckets. How far back to look is a tuning choice.

The other functions follow the same idea:

- **Risk scoring** runs every 15 minutes and calls the Azure Machine Learning ([ML](https://en.wikipedia.org/wiki/Machine_learning "Algorithms that learn patterns from data rather than following explicit rules")) endpoint in one batch. If the endpoint is down, the run is skipped and logged. The advisory score goes stale, and the next run scores again.
- **Archive and export** jobs write files per day or per month to known archive paths, such as `yyyy/mm/dd/hospital_id/`. So a rerun writes to the same place.

A failure stays harmless because the functions are off the alert path. Alerts come from the live processor on Kubernetes. A failed rollup means stale trend charts for a while, not a missed alert.

</details>

---

### Q3. Why did you run some calculations in Azure Functions instead of on your Kubernetes cluster?

**Brief answer**
Two reasons: a native blob trigger for document ingest, and keeping batch CPU away from the nodes that run the alert path. The cost was a second runtime to operate, and a Premium plan for private network access.

<details>
<summary><strong>Must cover</strong></summary>

- **timers** — rollups, archive, scoring, exports
- **blob trigger** — document ingest
- **Kubernetes CronJobs** — the alternative
- **isolation from the alert path** — batch CPU off its nodes
- **second runtime**
- **Premium plan** — VNet integration for private endpoints
- **egress control is weaker** — func-knowledge has open outbound HTTPS

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There were two function apps:

- **`func-analytics`** runs on timers. Rollups run every 5 minutes, risk scoring every 15 minutes, the raw archive and partition maintenance daily, and the dataset export and audit archive monthly.
- **`func-knowledge`** runs on a blob trigger. When an editor uploads a document to `kb-documents`, it extracts, chunks and embeds the text.

The alternative was Kubernetes CronJobs on the same AKS cluster. I chose Functions for these reasons:

- **Native blob trigger.** Document ingest reacts to uploads without a watcher that I would have to write.
- **Isolation from the alert path.** Rollups over hundreds of thousands of frames are bursts of CPU work. On the cluster, they would compete with `vitals-processor` for node capacity, or need their own node pool. In Functions, that batch CPU runs off the alert-path nodes.
- **Different failure tolerance.** Nothing in Functions is on the alert path. If a run fails, trend charts are stale for a while.

The costs:

- **A second runtime.** Deployment is different (zip packages), and so are the logs and the scaling rules. The same pipeline deploys both, which reduces that cost.
- **Premium plan.** The functions reach PostgreSQL, Cosmos DB and Blob Storage over private endpoints. That needs VNet integration, which here means the Premium plan, with about one always-ready instance per app.
- **Egress control is weaker.** `func-analytics` needs no internet, so its subnet denies outbound internet traffic. `func-knowledge` must reach the OpenAI API. A network security group filters by IP address, not host name. So its outbound [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") Secure ([HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP encrypted with TLS to protect requests and responses in transit")) traffic is open. That is a known residual risk. It is smaller because `func-knowledge` has no grant on any patient data.

</details>

---

## R14. Cloud — AKS cluster setup

> Configure and deploy Kubernetes(k8s) clusters using Azure AKS;

---

### Q1. How did you lay out node pools in your AKS cluster, and why?

**Brief answer**
Three pools across three zones: a system pool for Kubernetes components, an autoscaled apps pool for services and workers, and a tainted stateful pool that ran only RabbitMQ. The separate stateful pool kept a noisy application pod from starving the broker.

<details>
<summary><strong>Must cover</strong></summary>

- **three availability zones** — every pool spans them
- **system pool** — separate from application pods
- **cluster autoscaler** — apps pool, 3 to 9 nodes
- **tainted stateful pool** — RabbitMQ only
- **topology spread** — 3 replicas across zones
- **private API server** — deploys run from inside the network
- D8s_v5 nodes, Istio add-on, workload identity

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The cluster ran in three availability zones, and each pool spanned them:

| Pool | Size | Runs |
|---|---|---|
| `system` | 3 × D4s_v5 | Kubernetes system components and add-ons |
| `apps` | 3–9 × D8s_v5, cluster autoscaler | All services and queue workers |
| `stateful` | 3 × D4s_v5, one per zone, tainted | RabbitMQ only |

The reason for each pool:

- **System pool.** CoreDNS and the other system pods must not be evicted by an application that runs out of memory. So they get their own pool.
- **Apps pool.** Services scale on CPU and workers scale on queue depth. When pods cannot be placed, the cluster autoscaler adds nodes, up to 9.
- **Tainted stateful pool.** RabbitMQ carries the whole alert path. With a taint, only pods that tolerate it land there. With one node per zone, each RabbitMQ replica gets its own zone and its own disk. A memory-hungry pod elsewhere cannot push the broker into a memory alarm.

Spreading mattered too. Alert-path deployments ran 3 replicas with topology spread across zones. So losing one zone costs seconds of reduced capacity, not an outage.

I enabled these add-ons: the Istio-based service mesh for Mutual [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") ([mTLS](https://en.wikipedia.org/wiki/Mutual_authentication "TLS in which client and server both present certificates, so each authenticates the other")) and canary routing, Kubernetes Event-driven Autoscaling ([KEDA](https://keda.sh/ "Scales Kubernetes workloads on external event sources such as queue depth")) for queue-based scaling, workload identity, and the Key Vault provider for the Secrets Store CSI driver.

The cluster had a private API server. So deploy jobs ran on a self-hosted runner inside the virtual network, while build jobs stayed on GitHub-hosted runners.

</details>

---

### Q1. What are the key considerations when deploying APIs to Kubernetes?

**Brief answer**
An API on Kubernetes needs more than a Deployment. It needs replicas across zones, a disruption budget, health probes, resource requests, a secure path in, and platform identity and secrets. Here the choices that mattered most were zone spread, a token check in every service, and secrets that never enter the image.

<details>
<summary><strong>Must cover</strong></summary>

- **3 replicas across zones** — topology spread constraints
- **minAvailable: 2** — a drain removes one replica at most
- **readiness probe** — no traffic until the pod can serve
- **liveness probe** — must allow for a slow startup
- **resource requests** — the base for scheduling and the HPA
- **every service validates the token**
- **workload identity** — one managed identity per service account
- **secrets from Key Vault** — never in the image or manifest
- Istio internal ingress, STRICT mTLS, Pod Security Admission, default-deny network policies, build once, /metrics

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I treat it as a checklist, grouped by concern.

**Availability.** Alert-path APIs run 3 replicas across zones, placed with topology spread constraints. A PodDisruptionBudget with `minAvailable: 2` stops a node drain from removing more than one replica. Scaling uses the Horizontal Pod Autoscaler (HPA) on CPU. The autoscaling question covers the details.

**Health and lifecycle.** A readiness probe keeps a pod out of traffic until it can serve. A liveness probe restarts a stuck pod. But it must allow for a slow startup, or it kills healthy pods again and again. The design docs do not record probe paths or timings, so I describe the rule, not a number.

**Resources.** Every container needs CPU and memory resource requests. The scheduler uses them to place the pod, and the HPA measures CPU against them. A memory limit that is too low shows up as `OOMKilled`.

**The path in.** Traffic passes the Application Gateway web application firewall (WAF), then Azure API Management, then the Istio internal ingress. The ingress routes by path. Istio enforces mutual TLS (mTLS) in STRICT mode between pods. Even so, every service validates the token itself. Ingest does not pass API Management, and a compromised pod could call a service directly.

**Identity and secrets.** Each service account uses AKS workload identity, federated to its own managed identity. The pod gets its secrets from Key Vault through the Secrets Store CSI driver. They are never built into an image or written into a manifest.

**Hardening.** Pod Security Admission runs at the `restricted` level. Containers run as non-root with a read-only root filesystem. Azure Policy admits only images from our registry, and network policies deny all traffic by default.

**Release and visibility.** Images are built once, tagged with the commit hash and promoted between environments. Migrations run first, as a Kubernetes Job. Every API exposes `/metrics` and writes structured JSON logs to stdout.

The common mistake is to treat these as extras for later. Without a disruption budget, a routine upgrade can take down several replicas at once. Without a readiness probe, a rollout sends requests to pods that cannot serve them yet.

</details>

---

### Q2. How did you configure autoscaling differently for API services and for background workers?

**Brief answer**
API services scaled on CPU with the Horizontal Pod Autoscaler; queue workers scaled on queue depth with KEDA, because a worker's real load is its backlog, not its CPU. The cluster autoscaler then added nodes when pods could not be placed.

<details>
<summary><strong>Must cover</strong></summary>

- **HPA on CPU** — for HTTP services
- **KEDA on queue depth** — for workers
- **backlog, not CPU**
- **latency budget** — about 3 seconds of headroom
- **depth of 50** — scale before the budget is used
- **alert at 120**
- cluster autoscaler, Pending pods, maximum replicas

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The key question is: which signal shows that a pod is falling behind?

**Hypertext Transfer Protocol (HTTP) services**, such as `care-core` and `telemetry-service`, use the Horizontal Pod Autoscaler ([HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Automatically adjusts the number of Kubernetes pod replicas to match load")) on CPU. For them, request load and CPU move together, so CPU is a fair signal.

**Queue workers**, such as `vitals-processor`, `vitals-writer` and the notification worker, use KEDA on RabbitMQ queue depth. A worker's real load is its backlog, not its CPU. A worker's CPU can look fine while thousands of messages wait, for example while it waits on Redis or Cosmos DB. Queue depth measures the backlog directly.

The numbers came from the alert latency budget. The alert path has a 5-second p95 target. The summed budget is about 1.9 seconds, which leaves about 3 seconds of headroom for a backlog. At 40 messages per second, 3 seconds is about 120 messages in `vitals.processor`. So:

- KEDA adds processor replicas at a depth of 50, well before the budget is used.
- A monitoring alert at 120 fires when the latency target is at risk.

The rest of the setup:

- **Replicas.** Alert-path deployments run 3 replicas, one per zone.
- **Cluster autoscaler.** When pods are `Pending` for lack of capacity, it adds nodes to the apps pool, up to 9. Pods `Pending` for more than 5 minutes are a paging signal, because the autoscaler has probably hit its limit.
- **Maximum replicas.** HPA or KEDA at maximum replicas is also a cluster health signal. It means the next step is capacity planning.

</details>

---

### Q3. How did you run a stateful service like RabbitMQ on AKS?

**Brief answer**
As a three-node StatefulSet run by the RabbitMQ Cluster Kubernetes Operator, one node per zone on a tainted node pool, with persistent Azure Disks and quorum queues. A PodDisruptionBudget allowed only one broker node down at a time.

<details>
<summary><strong>Must cover</strong></summary>

- **RabbitMQ Cluster Kubernetes Operator**
- **three replicas, one per zone** — on the tainted stateful pool
- **Azure Disks are zonal**
- **quorum queues** — survive one node loss
- **maxUnavailable: 1**
- **memory and disk alarms** — block publishers
- Terraform definitions, Azure Backup for AKS, Azure Service Bus

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A broker on Kubernetes must never be treated like a stateless pod.

**Operator.** The RabbitMQ Cluster Kubernetes Operator runs the StatefulSet, forms the cluster and handles rolling upgrades in a safe order.

**Placement.** Three replicas, one per zone, on the tainted `stateful` pool, which has one node per zone. Each replica has its own persistent volume on an Azure Disk. Azure Disks are zonal, so a pod must come back in the zone where its disk lives. One node per zone makes that placement predictable.

**Data safety.** Quorum queues replicate every queue on all three nodes. A confirmed message survives one node loss. Losing one node costs a few seconds of leader election.

**Disruptions.** A PodDisruptionBudget with `maxUnavailable: 1` means a node drain or upgrade takes down at most one broker at a time. The quorum keeps a majority.

**Monitoring.** The `rabbitmq_prometheus` plugin exposes the metrics. Memory and disk alarms page someone, because an alarmed broker blocks publishers. Queue depth on `vitals.processor` is also a Service Level Objective ([SLO](https://sre.google/sre-book/service-level-objectives/ "Target value for a service level indicator that a service commits to meet")) signal.

**Configuration as code.** Exchanges, queues, bindings, policies and users come from Terraform definitions. A rebuilt cluster gets the same topology.

**Backup.** Azure Backup for AKS covers the RabbitMQ volumes, for cluster rebuilds. That depends on the volumes being CSI-driver Azure Disks, which must be confirmed for the StatefulSet.

The honest trade-off: this is more to operate than Azure Service Bus. I accepted it, because Celery needed RabbitMQ as its broker and I wanted native topic routing.

</details>

---

## R15. Cloud — Cluster health and troubleshooting

> Monitoring and maintaining the health of the Kubernetes(k8s) cluster, and troubleshooting any issues that may arise;

---

### Q1. Which signals did you watch to know that the Kubernetes cluster was healthy?

**Brief answer**
Signals that predict user impact, not every metric: nodes NotReady, pods crash-looping or stuck Pending, volumes filling up, broker alarms, certificates close to expiry, autoscalers at their maximum, and the AKS version nearing end of support.

<details>
<summary><strong>Must cover</strong></summary>

- **NotReady nodes**
- **Pending pods** — the autoscaler has hit its limit
- **CrashLoopBackOff**
- **volume above 80%** — before a RabbitMQ disk alarm
- **certificate expiry** — within 14 days
- **AKS version nearing end of support**
- **patients, not pods** — gateway silence, escalation check, dead letters
- managed Prometheus, Container Insights

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I grouped the signals by what they predict.

**Capacity and placement:**

- NotReady nodes: a node `NotReady` for more than 5 minutes.
- Pending pods: pods `Pending` for more than 5 minutes. That usually means no capacity, and the cluster autoscaler has hit its limit.
- HPA or KEDA at maximum replicas. Scaling has run out of room.

**Workload failure:** pods in `CrashLoopBackOff`.

**Storage:** a persistent volume above 80% full. For RabbitMQ, a volume above 80% comes before a disk alarm, which blocks publishers.

**Broker:** a RabbitMQ memory or disk alarm.

**Slow-burning risks:**

- Certificate expiry within 14 days.
- AKS version nearing end of support. Out of support means no more security patches.

The data came from Azure Monitor managed service for Prometheus. It scraped node, kube-state, Istio and RabbitMQ metrics. Container Insights sent logs to Log Analytics. Grafana showed both.

Cluster signals are not the whole picture. The most important pages are about patients, not pods. These page directly: a gateway silent for more than 30 seconds, an escalation check that has not run for 60 seconds, and any message in a dead-letter queue. A healthy cluster with a silent gateway is still an incident.

Every paging alert linked to its runbook section, so the on-call engineer did not start from nothing.

</details>

---

### Q2. Walk me through how you troubleshot a pod that kept restarting.

**Brief answer**
From the cheapest evidence to the richest: Kubernetes events and `kubectl describe` first, then the crashed container's logs, then the Grafana log panel and the trace. The exit reason usually points at the cause — memory, a failing probe, or a startup dependency.

<details>
<summary><strong>Must cover</strong></summary>

- **kubectl describe** — last state and exit reason
- **OOMKilled**
- **logs --previous** — output of the crashed container
- **Grafana log panel** — trace_id links logs to metrics
- **secrets mount** — workload identity lacks Key Vault access
- **read-only root filesystem**
- **liveness probe** — fails during a slow startup
- dependency during a failover, default-deny network policy

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The runbook order was: events and `kubectl describe` first, then the pod's Grafana log panel, then its trace. Here is that order, with the causes I check at each step.

1. **`kubectl describe pod`** shows the last state and the exit reason. `OOMKilled` means the memory limit is too low, or there is a leak. Exit code 1 means the app crashed by itself. The events show failed probes, image pull errors and volume mount failures.
2. **`kubectl logs --previous`** shows the output of the crashed container, not the new one. Without `--previous`, you often see a clean startup and nothing useful.
3. **Grafana log panel.** Every service logs structured JSON with a `trace_id`. The service dashboard pairs metrics with logs. So I can see whether restarts line up with a traffic spike or a deploy.
4. **Trace**, if the crash follows a specific request.

Causes specific to this platform that I check early:

- **Secrets mount.** Credentials come from Key Vault through the Secrets Store CSI driver. If the pod's workload identity lacks access to Key Vault, the volume mount fails and the pod never starts.
- **Read-only root filesystem.** Pod Security Admission runs at the `restricted` level, and containers have a read-only root filesystem. A library that writes to a temp path crashes at startup, unless it gets a writable `emptyDir` volume.
- **Liveness probe too strict.** A liveness probe that fails during a slow startup kills a healthy pod again and again.
- **Dependency not ready.** For example, RabbitMQ or PostgreSQL during a failover. The service should retry with backoff at startup, not crash.
- **Network policy.** The default is deny. A new dependency without an allow rule looks like a timeout.

After the fix, I ask why monitoring did not catch it sooner. That is why `CrashLoopBackOff` is a paging signal.

</details>

---

### Q3. How did you upgrade the cluster without interrupting notifications to medical staff?

**Brief answer**
Upgrades ran in a weekly maintenance window with surge nodes, and PodDisruptionBudgets kept at least two replicas of every alert-path service and all but one RabbitMQ node running. Nodes drained a batch at a time, so capacity dipped but the alert path never stopped.

<details>
<summary><strong>Must cover</strong></summary>

- **maintenance window** — Sunday, 02:00–06:00
- **NodeImage channel**
- **max surge 33%**
- **minAvailable: 2** — for alert-path deployments
- **maxUnavailable: 1** — for RabbitMQ
- **manual acks** — evicted work goes back to the queue
- **mesh upgrades tied to AKS revisions**
- topology spread, alert_delivery_seconds, quarterly drill

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Upgrades are the most common planned disruption, so I treated them as a design problem.

**When.** A planned maintenance window on Sunday, 02:00–06:00 local time. Node images used the `NodeImage` channel, so node operating system patches arrived automatically in that window.

**How nodes are replaced.** Max surge was 33%. AKS adds new nodes first, then drains and removes old ones in batches. The surge keeps capacity during the roll.

**What protects the workloads.** PodDisruptionBudgets:

- `minAvailable: 2` for alert-path deployments, which run 3 replicas. So a drain can evict only one at a time.
- `maxUnavailable: 1` for RabbitMQ. The quorum queues keep a majority throughout.

Topology spread keeps replicas across zones, so one drained node never holds all the copies.

**Safe shutdown.** Workers use manual acks. When a worker is evicted, its unacknowledged messages go back to the queue, and another replica takes them. Nothing is lost, only delayed a little.

**The mesh.** The Istio add-on ties mesh upgrades to AKS revisions. So I planned mesh and cluster versions together.

**Watching.** During and after an upgrade, the usual signals apply: `alert_delivery_seconds`, queue depth, and pods that are `Pending` or crash-looping. The AKS version nearing end of support is itself a signal, so an upgrade never becomes an emergency.

**If it goes wrong.** An upgrade that breaks the cluster is a disaster-recovery scenario: rebuild with Terraform, redeploy, restore, replay. That runbook is tested in a quarterly drill.

</details>

---

## R16. CI/CD — Faster pipelines

> Optimize CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") pipelines for speed and efficiency, reducing build and deployment times through caching and parallel jobs;

---

### Q1. Which caches did you add to the pipelines, and what did each one save?

**Brief answer**
Three layers: the pip download cache keyed on each service's lock file, the Docker Buildx layer cache stored in GitHub Actions per service, and Dockerfiles ordered so a code-only change reused the dependency layer.

<details>
<summary><strong>Must cover</strong></summary>

- **cache key** — changes exactly when the content changes
- **pip cache** — keyed on the lock file
- **Buildx layer cache** — type=gha, one scope per service
- **dependencies before code** — in the Dockerfile
- **no before-and-after number** — only where the time went
- poisoned cache

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A cache helps only if its cache key changes exactly when the content changes. I used three layers.

**Python dependencies.** `actions/setup-python` with its pip cache, keyed on each service's lock file. Lint, type checks and unit tests restore it, so packages are not downloaded again on each run. When the lock file changes, the key changes and the cache is rebuilt.

**Docker layers.** The Buildx layer cache uses the GitHub Actions cache backend, `type=gha`, with one cache scope per service. Without the scope, services overwrite each other's cache entries, and every build misses.

**Dockerfile order.** Each Dockerfile installs dependencies before code is copied in. Layers are cached in order, and a layer is reused only if everything before it is unchanged. So a code-only change reuses the dependency layer and rebuilds only the last few layers. The wrong order, code first, reinstalls every dependency on every commit.

I cannot give a before-and-after number here, and I will not invent one. What I can say is where the time went: dependency installs and image builds, repeated on every run. Each of these changes removes one of those repeats.

A cache is also a risk. A poisoned or stale cache can hide a broken dependency. The lock-file key limits that, because a changed dependency always means a new key.

</details>

---

### Q1. What is your approach to structuring a CI/CD pipeline?

**Brief answer**
Two halves joined by one artifact. CI runs on the pull request, fans out into parallel jobs and fans in to one required check. CD starts from `main` with an image built once, then promotes that exact image through gates that stop a bad change on their own.

<details>
<summary><strong>Must cover</strong></summary>

- **fan-out and fan-in** — parallel jobs, one required check
- **critical CVEs** — fail the build
- **build once** — the artifact between CI and CD
- **expand-then-contract**
- **environment approval** — the one human gate
- **OIDC federation** — no stored cloud secrets
- **self-hosted runner** — deploys reach a private API server
- change detection, mypy, Terraform plan, staging smoke tests, canary gate

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I build each stage around one question: what must be true before the change moves on?

**Continuous integration (CI), on every pull request.** It has a fan-out and fan-in shape: parallel jobs, then one check.

- First, change detection maps the changed paths to the services they affect.
- Then independent jobs run in parallel for each service: lint and mypy type checks, unit tests, the image build and integration tests. Terraform format, validate and plan run beside them.
- All jobs feed one required check, and branch protection requires only that check.

The pull-request question covers the change detection and the matrix in detail. The image build also carries a security gate for Common Vulnerabilities and Exposures (CVEs). CI fails a build when the image has critical CVEs.

**The artifact between the halves.** The rule is build once. On `main`, each image is built once, tagged with the commit hash and pushed to Azure Container Registry. Every later stage promotes that exact image. If each environment rebuilt the image, production would run something staging never tested.

**Continuous delivery (CD), in order of risk.** Migrations run first, as a Kubernetes Job, in expand-then-contract style. Then staging deploys and runs smoke tests. Then the production canary runs, with a gate that reads Prometheus. The deployment question covers these gates.

**Infrastructure has its own gate.** Terraform plan runs on every pull request. Apply runs on merge, and only after environment approval. That is the one human gate in the pipeline. A wrong apply can remove a whole resource, and a canary cannot catch that.

**Identity and runners.** GitHub Actions signs in to Azure with OpenID Connect (OIDC). It uses OIDC federation, not stored keys. Each environment has its own deploy identity, and GitHub stores no cloud secrets. Build jobs run on GitHub-hosted runners. Deploy jobs run on a self-hosted runner inside the network, because the AKS API server is private.

The trade-off is complexity. A matrix, one required check and two kinds of runner are more to maintain than one linear script. That pays off once a repository holds many services.

</details>

---

### Q2. How did you keep a pull request from running every job for every service in the repository?

**Brief answer**
A first job mapped the changed paths to the services they affect, and every later job ran as a parallel matrix over only those services. A change to shared packages selected every service that imports them.

<details>
<summary><strong>Must cover</strong></summary>

- **change detection** — git diff mapped to services
- **shared code** — selects every service that imports it
- **parallel matrix jobs** — total time is the slowest job
- **integration tests** — dependencies in Docker Compose
- **one required check**
- **concurrency group** — cancels superseded runs
- **under-selecting** — the risk in the path map
- mypy, Terraform plan

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The repository held many services: `services/*` and `functions/*`, shared code in `contracts/` and `vitals_rules/`, and `infra/` for Terraform. Running every job for every service on every pull request wastes most of the time.

**Change detection.** The first job is a Bash step. It runs `git diff` against the base branch and maps the changed paths to services. The output becomes the matrix for the later jobs. The important rule is about shared code. A change to `contracts/` or `vitals_rules/` selects every service that imports it, because a message contract or an alert rule affects all of them. Without that rule, a breaking contract change could pass CI.

**Parallel matrix jobs.** For each selected service, these jobs run in parallel: lint and type checks with mypy, unit tests, the Docker image build, and integration tests. The integration tests run against real PostgreSQL, MongoDB, RabbitMQ and Redis in Docker Compose. Terraform format, validate and plan run in their own job. So the total time is the slowest job, not the sum of all jobs.

**One required check.** All jobs feed one final job, and branch protection requires only that one required check. Otherwise the list of required checks would change with every matrix.

**Concurrency group.** A new push to the same branch cancels the superseded run. Nobody waits for, or pays for, a run that no longer matters.

The trade-off is the risk of under-selecting. If the path map misses a dependency, a broken service can merge untested. That is why shared paths select every service that uses them.

</details>

---

### Q2. How do you reduce Docker image size?

**Brief answer**
Install only what each service imports and start from a slim base image. A multi-stage build keeps compilers out of the final image. The design docs record no base images or sizes, so I describe the method. Here, size mattered for image pulls during scale-out and failover, and for the vulnerability gate.

<details>
<summary><strong>Must cover</strong></summary>

- **image pull** — on scale-out and after a zone loss
- **fewer packages** — fewer known vulnerabilities
- **its own lock file** — only what the service imports
- **slim base image**
- **multi-stage build** — compilers stay in the first stage
- **.dockerignore**
- **clean up in the same layer**
- func-analytics zip package, musl, --no-cache-dir, docker history, ephemeral debug container

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

First, why size mattered here. A pod cannot start until its node pulls the image. That happens when the cluster autoscaler adds a node, or when a pod moves after a zone loss. A smaller image pull finishes sooner. Fewer packages also mean fewer known vulnerabilities. That matters because CI fails a build on any critical Common Vulnerabilities and Exposures ([CVE](https://www.cve.org/ "Public identifier for a known software security flaw")) entry.

The design docs do not state base images or image sizes. So I describe the method, not a before-and-after number.

The steps, roughly in order of effect:

1. **Install only what the service imports.** Each service has its own lock file, so one service does not carry another's libraries. NumPy and Pandas, the heaviest libraries in the stack, are used only in `func-analytics`. It deploys to Azure Functions as a zip package, not as an image. Test tools such as pytest and mypy stay out of the runtime image too.
2. **A slim base image.** A `python:*-slim` base leaves out the compilers and extra packages of the full Debian image. I avoid Alpine for Python services. Alpine uses musl instead of glibc, so pip may find no prebuilt wheel and compile from source. The build gets slower, and the image is not always smaller.
3. **A multi-stage build.** The first stage has the compilers and builds the wheels. The final stage copies in only the installed packages and the code. So build tools never reach production.
4. **No pip cache in the image.** I use `pip install --no-cache-dir`, or a BuildKit cache mount. The pip cache belongs in the CI cache, not in an image layer.
5. **A tight build context.** A `.dockerignore` file keeps `.git`, tests and local data out of the build context. A broad `COPY` then cannot pull them in.
6. **Clean up in the same layer.** A file deleted in a later layer still ships in the earlier one.

To find what is large, I read the layer sizes with `docker history`.

The trade-off is debugging. A minimal image may have no shell or tools. Our containers already run as non-root with a read-only root filesystem. So I debug from outside: logs, traces, and an ephemeral debug container when needed.

</details>

---

### Q3. How did you make deployments faster without making releases riskier?

**Brief answer**
Build once and promote the same image; run migrations first, in an expand-then-contract style, so any image can roll back; then release through automated canaries with a Prometheus gate. Speed came from removing manual steps, and safety from gates that act on their own.

<details>
<summary><strong>Must cover</strong></summary>

- **build once** — promote the exact image
- **expand-then-contract** — rollback without a down-migration
- **synthetic gateway** — a push reaches a test device within 5 seconds
- **Istio traffic weights** — 10%, 50%, 100%
- **Bash gate queries Prometheus** — 5xx ratio and p95
- **canary for queue workers** — one replica takes about 1/N
- **rollback** — the previous commit's manifests
- self-hosted runner, zip packages

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Faster deploys are only worth it if a bad release is caught and reversed quickly. The pipeline did both.

1. **Build once.** On `main`, each image is built once, tagged with the commit hash and pushed to Azure Container Registry. Staging and production promote that exact image. There is no rebuild per environment, so production runs what staging tested.
2. **Migrations first**, as a Kubernetes Job, in expand-then-contract style. A release only adds columns or views, and removal waits for a later release. So the old and the new code both work with the schema. Any image can roll back without a down-migration.
3. **Staging** deploys automatically and runs smoke tests. One test uses a synthetic gateway. It injects a reading that breaks a threshold, and checks that a push reaches a test device within 5 seconds. That tests the whole alert path, not only HTTP health.
4. **Canary for HTTP services.** Istio traffic weights go 10%, then 50%, then 100%. At each step, a Bash gate queries Prometheus for the 5xx ratio and p95 latency. If the gate fails, the weights go back automatically.
5. **Canary for queue workers.** Traffic weights do not apply to consumers. So one new-version replica joins the existing consumers and takes about 1/N of the messages. The gate watches dead-letter queue depth, error rate and `alert_delivery_seconds` for 15 minutes. Then the rest roll out.
6. **Rollback** applies the previous commit's manifests again. Expand-then-contract makes that safe.

Two infrastructure details matter here. The AKS API server is private, so deploy jobs run on a self-hosted runner inside the network, while build jobs stay on GitHub-hosted runners. Functions deploy as zip packages from the same pipeline, so there is one release flow.

The gates are what make speed safe. A canary without an automatic gate is just a slow full rollout.

</details>

---

## R17. Testing and observability — Service monitoring

> Implement monitoring and logging mechanisms to track the health and performance of the microservices;

---

### Q1. Which metrics did you use to decide whether a microservice was healthy?

**Brief answer**
Service level indicators tied to what users notice: end-to-end alert delivery time, the ingest success ratio, the API error ratio and p95 latency, and the queue backlog. Each had an SLO, and all came from Prometheus metrics.

<details>
<summary><strong>Must cover</strong></summary>

- **the user's view** — what a nurse or a gateway notices first
- **/metrics** — scraped by managed Prometheus
- **alert_delivery_seconds** — from ingest receive time to push handoff
- **received_at** — travels in the message headers
- **Istio metrics** — rate, errors and latency without code changes
- **outside the SLO** — provider-to-phone delivery
- ingest availability 99.95%, processor backlog under 120

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from the user's view, not from CPU graphs. For each path I asked one question: what would a nurse or a gateway notice first?

Every service exposed Prometheus metrics at `/metrics`. Azure Monitor managed service for Prometheus scraped them, together with node, kube-state, Istio and RabbitMQ metrics.

The Service Level Indicators (SLIs) and their targets:

| SLO | Indicator | Target |
|---|---|---|
| Alert delivery | `alert_delivery_seconds` histogram, from ingest receive time to push handoff | p95 ≤ 5 s; 99.9% ≤ 30 s |
| Ingest availability | Share of batches without a 5xx error | 99.95% |
| Staff API | Istio ingress metrics: 5xx ratio and p95 | 99.9%, p95 < 300 ms |
| Latest vitals | The same, for one route | p95 < 100 ms |
| Assistant | `assistant_answer_seconds` | p95 ≤ 8 s; 99.5% availability |
| Processor backlog | Ready messages in `vitals.processor` | Under 120 |

The alert delivery metric needed care, because it crosses four services. `telemetry-service` stamps `received_at` when it accepts a batch. That value travels in the message headers, into `AlertRaisedV1`, and into the `notify.send` arguments. The notification worker records the difference at push handoff. So one histogram measures the whole path, end to end.

Istio metrics gave request rate, errors and latency for every HTTP service without code changes. Services added their own domain metrics on top.

Delivery from the push provider to the phone was outside our control, so it was outside the SLO. A good metric states clearly where it stops.

</details>

---

### Q2. How did you follow one request across several services when something was slow?

**Brief answer**
With distributed tracing: OpenTelemetry instrumented every service and library, and the `traceparent` header travelled in HTTP headers and in RabbitMQ message headers. One trace covered upload, processing, alerting and notification, even across the queues.

<details>
<summary><strong>Must cover</strong></summary>

- **the queue** — most of the alert path is asynchronous
- **OpenTelemetry** — exports to Application Insights
- **traceparent header** — the producer injects it, the consumer extracts it
- **alert-path traces kept at 100%** — dashboard reads at 10%
- **trace_id in every log line**
- **gap between the publish span and the consume span** — queue wait
- span links for batched consumers

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Tracing over HTTP is easy. The hard part in this system was the queue, because most of the alert path is asynchronous.

**Instrumentation.** OpenTelemetry instrumentation for Django, Flask, SQLAlchemy, Redis, Celery and kombu, exporting to Application Insights. Each library produces spans without hand-written code.

**Propagation across RabbitMQ.** Every message carries a `traceparent` header in the World Wide Web Consortium ([W3C](https://www.w3.org/ "Develops open web standards such as trace context propagation")) trace context format. The producer injects it and the consumer extracts it. So one trace spans the gateway upload, `telemetry-service`, `vitals-processor`, `alert-service` and the notification worker. Without that header, each consumer would start a new trace, and the path would break into pieces at every queue.

**Sampling.** Alert-path traces are kept at 100%. That is about 5,000 a day, which is cheap, and they are the traces we need most. Dashboard reads are sampled at 10%, because there are many of them and they look alike.

**Linking to logs.** Every log line carries `trace_id` and `span_id`. With a trace_id in every log line, I can jump from a slow span to the log lines of that request.

In practice, a slow alert shows up first in the `alert_delivery_seconds` histogram. The trace then shows which hop took the time. In this design the likely causes are a wait in a queue, a PostgreSQL failover, or the push provider. Queue wait shows as the gap between the publish span and the consume span.

One gotcha: batching breaks the one-message, one-trace picture. `vitals-writer` buffers messages from many batches and writes them together. For a consumer like that, a span can use span links to point at several parent traces, instead of belonging to one.

</details>

---

### Q2. What defines a good service level agreement (SLA) dashboard?

**Brief answer**
It answers two questions at a glance: are we inside our targets for this period, and how fast are we using the margin? This design had SLOs but no contractual [SLA](https://en.wikipedia.org/wiki/Service-level_agreement "Service Level Agreement — Commitment between a provider and its customer on measurable service targets, such as delivery time") with the hospitals. So the dashboard shows each SLO with its error budget and burn rate, plus the safety signals that a ratio hides.

<details>
<summary><strong>Must cover</strong></summary>

- **a promise to someone** — with a consequence when it is broken
- **no contractual SLA** — only SLOs in this design
- **looser than the SLO**
- **error budget left** — in minutes, over a 30-day window
- **burn rate** — the same windows as the alerts
- **safety signals in their own row**
- **where the measurement stops**
- **Istio metrics at the ingress**
- API Management Standard v2 SLA, 43 minutes a month, trace_id drill-down

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

First, a naming point. A service level agreement (SLA) is a promise to someone, with a consequence when it is broken. This design defines service level objectives (SLOs), which are internal targets. It has no contractual SLA with the hospitals. The only SLA in the design is Microsoft's SLA for API Management Standard v2. So what I would build is an SLO dashboard. If a contract came later, its SLA should be looser than the SLO. Then the team is warned before the contract is broken.

A good dashboard, in Azure Managed Grafana over the Prometheus metrics, has these parts.

**One row per SLO, at the top.** Each row shows three things: the service level indicator ([SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health")) for the period, the target, and the error budget left. The window must match the target. The alert path targets 99.9% a month, which is about 43 minutes of downtime. So the panel uses a 30-day rolling window and shows the budget left in minutes. Minutes are easier to act on than a percentage.

**Burn rate beside the budget.** The panels use the same windows as the alerts: 1 hour, 5 minutes and 6 hours. Then the dashboard and the page tell the same story. A budget that still looks large can be burning at 14.4 times the rate the budget allows. That needs attention now.

**Safety signals in their own row.** Silent gateways by ward, the age of the last escalation check, and dead-letter queue depth. They are not ratios, so they never appear in an SLO. One silent gateway out of 40 barely moves availability, but that ward is not monitored remotely.

**Where the measurement stops.** Each panel says what it covers. Alert delivery ends at the handoff to the push provider. Delivery from the provider to the phone is outside the SLO. A reader should not assume the number covers more than it does.

**Measured where users are.** Staff API figures come from Istio metrics at the ingress, not from pod health. A pod can look healthy while users get errors.

**A path down, not everything at once.** The top rows stay few and stable. Each row links to its service dashboard, and from there to the log panel filtered by `trace_id`. Engineers drill down, and managers can stop at the top.

The common mistake is a wall of CPU and memory graphs. Those graphs help explain a problem once you know you have one. They do not show whether you kept your promise.

</details>

---

### Q3. How did you set up monitoring alerts so that engineers were paged for real problems and not for noise?

**Brief answer**
SLO alerts used multi-window burn rates: a page only when the error budget was burning fast, a ticket when it burned slowly. A short list of safety signals paged directly, whatever the budget said, because they meant patients were not being monitored.

<details>
<summary><strong>Must cover</strong></summary>

- **burn rate** — how fast the error budget is used
- **page at 14.4× over 1 hour** — confirmed over 5 minutes
- **ticket at 3× over 6 hours**
- **safety signals page directly**
- **gateway_last_seen_age_seconds > 30**
- **dead-letter queue depth above zero**
- **one silent gateway barely moves a ratio**
- escalation check older than 60 seconds, runbook links

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There were two kinds of alerts, with different rules.

**Burn-rate alerts for SLOs.** A plain threshold, such as "error rate above 1%", fires on every short spike and misses slow leaks. A burn rate measures how fast the error budget is used. I used two windows:

- **Page at 14.4× over 1 hour**, confirmed over 5 minutes. At that rate, a 30-day budget is gone in about 2 days. The short window makes the alert stop soon after the problem stops.
- **Ticket at 3× over 6 hours.** That is a slow leak. It needs a fix during working hours, not at 3 a.m.

**Safety signals page directly.** Some conditions mean that a patient is not monitored, or that an alert is stuck. They page whatever the budget says:

- `gateway_last_seen_age_seconds > 30` for any bound gateway. That ward is not monitored remotely.
- `escalation_check_last_run_timestamp` older than 60 seconds. Escalations may not be happening.
- Any dead-letter queue depth above zero. A message, possibly an alert, has failed five times.

A budget-based alert would hide these. One silent gateway out of 40 barely moves an availability ratio, but it is a clinical incident.

To keep pages useful, every paging alert links to its runbook section.

</details>

---

## R18. Testing and observability — Logging in Grafana

> Setting up logging for the system using Grafana;

---

### Q1. Grafana is usually a metrics tool. How did you set it up to work with logs?

**Brief answer**
Grafana did not store logs; it queried them. Container logs went to Azure Log Analytics, and Azure Managed Grafana read them through the Azure Monitor data source in [KQL](https://learn.microsoft.com/en-us/kusto/query/ "Kusto Query Language — Query language for Azure Monitor Log Analytics and Azure Data Explorer"), on the same dashboards as the Prometheus metrics.

<details>
<summary><strong>Must cover</strong></summary>

- **Grafana is a front end** — it queries logs, it does not store them
- **Container Insights** — ships logs to Log Analytics
- **Azure Monitor data source** — queries in KQL
- **fixed fields** — service, event, trace_id
- **log panel filtered by trace_id**
- 30-day and 1-year retention, Loki, Azure Workbooks, ingestion cost

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Grafana is a front end. So the real questions are where the logs live and how Grafana reaches them.

**Where logs live.** Every service writes one JSON object per line to stdout. Container Insights collects those lines from AKS and ships them to a Log Analytics workspace, `log-care`. Logs stay 30 days for interactive queries and 1 year in archive.

**How Grafana reads them.** Azure Managed Grafana has the Azure Monitor data source. It queries Log Analytics in Kusto Query Language (KQL). The same Grafana instance also reads the Prometheus metrics, so one tool shows both.

**The log line.** Every line has fixed fields: `ts`, `level`, `service`, `trace_id`, `span_id`, `request_id`, `actor_id` and `event`, plus fields for the event. Fixed names make KQL queries reusable across services: filter by `service`, group by `event`, join on `trace_id`.

**Dashboards.** Each service dashboard pairs its metrics with a log panel filtered by `trace_id`. An engineer sees a latency spike, picks a slow request, and reads its log lines without switching tools. That was the point of putting logs in Grafana, instead of sending people to the Azure portal.

**Why not Loki?** A self-hosted Loki stack in the cluster would be one more stateful system to run, scale and back up. Log Analytics is managed, and AKS already ships logs there through Container Insights. Grafana over Log Analytics gave us the Grafana experience without running the storage.

**Why not Azure Workbooks?** The team knew Grafana better, and Grafana already held the metrics dashboards.

The trade-off is cost. Log Analytics bills by the volume ingested, so ingestion cost grows with noisy logs. Keeping log volume down matters for the bill as well as for privacy.

</details>

---

### Q2. What did you keep out of the logs in a healthcare system, and how did you enforce it?

**Brief answer**
No protected health information: patient UUIDs were allowed for debugging, but names, record numbers, vital sign values and chat text were not. A shared logging filter dropped known PHI fields, and a CI test failed the build if sample requests produced any.

<details>
<summary><strong>Must cover</strong></summary>

- **logs are copied widely**
- **patient UUIDs allowed** — needed to debug
- **vital sign values** — health data when linked to a patient
- **shared logging filter** — drops known PHI field names
- **CI test** — fails the build on a PHI field
- **field names, not free text** — the filter's limit
- **audit table, not logs** — who viewed a record
- redacted chat log

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Logs are copied widely. They go to Log Analytics, to Grafana panels, into support tickets and into screenshots. So logs are the easiest way for patient data to leak. The rule was simple: no PHI in logs.

**What was allowed.** Patient UUIDs were allowed, because an engineer needs them to debug a specific case. A Universally Unique Identifier ([UUID](https://datatracker.ietf.org/doc/html/rfc9562 "128-bit identifier that can be generated without a central authority")) alone does not identify a person outside our system. Actor IDs, trace IDs and request IDs were allowed for the same reason.

**What was not allowed.** Names, medical record numbers, vital sign values and chat text. Vital sign values surprise people. But a heart-rate series linked to a patient ID is health data about that patient.

**How it was enforced:**

- **A shared logging filter** in every service drops known PHI field names before a line is written. It is shared code, so every service uses the same list.
- **A CI test** sends sample requests through each service and checks the log output. If any known PHI field appears, the build fails. This catches the common case: a developer logs a whole request body while debugging.
- **Structured logging** makes the filter possible. Every line is JSON with named fields, so the filter works on field names, not free text.

**Related controls:**

- The assistant's chat log keeps only the redacted question, for 90 days, in its own table.
- Who viewed a patient's record goes to the audit table, not logs: `audit.access_event`. That table has proper retention, immutable archives and access control.

The limit is clear. A filter on field names cannot catch PHI that someone typed into a free-text field logged under a harmless name. The CI test and code review are the backstop for that case.

</details>
