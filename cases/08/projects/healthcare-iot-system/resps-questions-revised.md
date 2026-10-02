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

### Q3. How many active users did the system support approximately? When did peak traffic events appear in your project? How did you design for handling them?

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

### Q2. Did you use partial index? How did you decide to use a partial index rather than an index on the whole table?

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

## R5. Messaging — RabbitMQ between services

> RabbitMQ configuration for communication between services;

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

## R6. Data and AI pipelines — ChatGPT expert chatbot

> Integration with [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") [ChatGPT](https://openai.com/chatgpt/ "ChatGPT — OpenAI's conversational large language model product") for creating a chatbot that answers expert questions and quickly searches for information among a corpus of documents with expert recommendations;

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

### Q2. How do you prevent hallucinations in expert answers?

**Brief answer**
Retrieval gives the model the right passages; after that I limited what the model may say and made every claim checkable. The prompt allows answers only from the passages, and every answer carries citations that the service validates and a clinician can open.

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

## R10. Cloud — Kubernetes disaster recovery

> Designing and implementing disaster recovery plans for Kubernetes(k8s) environments;

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

## R14. Cloud — AKS cluster setup

> Configure and deploy Kubernetes(k8s) clusters using Azure AKS;

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

## R16. CI/CD — Faster pipelines

> Optimize CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") pipelines for speed and efficiency, reducing build and deployment times through caching and parallel jobs;

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
