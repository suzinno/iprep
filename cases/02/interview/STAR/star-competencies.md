# Key Competencies — STAR Stories

> Examples from the latest project: the personalized cancer support platform.
> Ranked by priority for this role.

**Table of Contents**

- [Key Competencies — STAR Stories](#key-competencies--star-stories)
  - [1. FastAPI Architecture and Module Boundaries](#1-fastapi-architecture-and-module-boundaries)
  - [2. SQL on Big Tables and Careful Migrations](#2-sql-on-big-tables-and-careful-migrations)

---

## 1. FastAPI Architecture and Module Boundaries

**The role needs:** A core backend on Python, FastAPI, Uvicorn, Pydantic, SQLAlchemy and Alembic. The team also needs someone who understands how to optimize a synchronous FastAPI architecture for heavy enterprise loads.

**Brief:** I designed the core of the platform as a FastAPI **modular monolith**. Two parts moved out into their own services. One manages clinician and care-team accounts over System for Cross-domain Identity Management (SCIM). The other runs clinical Natural Language Processing (NLP).

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** The product is a platform for people diagnosed with cancer and for the clinicians who follow them. Patients log how they feel every day. They read guidance for their diagnosis and treatment. They keep appointments, prescriptions and visit notes in one place. Patients and clinicians work with the same record, but their access rules are opposite. The traffic is modest. The design expects about 200 requests a second at peak, with bursts to about 400. And one team works on the system.

**Task.** I was a backend engineer on the core platform. My job here was to design the shape of the backend. That meant deciding what stays in one deployable unit and what moves out into its own service.

**Action.** With one team and about 200 requests a second, a full split into microservices would not add throughput. It would add distributed transactions, for example between the diary and the records. Those cost latency and on-call load. So I kept the core as one deployable unit, called `care-core`.

The core has four modules: patient diary, records, clinical content and identity. Each module is its own Python package, with **its own PostgreSQL schema**. So the boundary in the code also exists in the database. Without that, any module could slowly start using any table. A module reads its own schema directly. The rule is that a module reaches another module only through a **published in-process interface**, not a direct import. A call through that interface stays inside one process. And the modules can still share a transaction.

The records module is separate on purpose. A clinical record has a different write model from authored content. It also has different consistency and audit rules. If records sat inside clinical content, a prescription and a leaflet would go through the same code path.

Only two parts had a real reason to run outside the core. The SCIM service follows the release cadence of the hospital directory. The NLP service needs GPU hardware. It also ships when a new model version is ready. So I moved those two out as separate FastAPI services. No user request waits on the NLP service, because its work goes through a queue.

Moving services out left a real coupling in the data. The SCIM service still writes to the same PostgreSQL database. It writes only the `identity` schema. That means clinicians, care-team members, and the care relationships that close when the hospital directory disables an account (deprovisioning). It never touches the records, diary or content schemas. So the separation is at the **deployment level, not the data level**. The SCIM service releases when the hospital directory changes. But it cannot change the `identity` tables without taking the core into account. **Schema ownership** keeps this coupling under control. The design also says when to look at the coupling again: when someone proposes a second service that writes across schemas.

We also accepted a trade-off. The four core modules still release as one unit. So one module's release blocks another module's features.

**Result.** SCIM and NLP releases no longer blocked the rest of the product. The core stayed one deployable unit with four modules, and the modules can still share a transaction. We did not pay for a fleet of microservices that the traffic did not need.

**Honest limits.** First, nothing automatic enforces the module boundary. Python has no visibility modifier, and the pipeline has no import check that fails the build on a cross-module import. Schema ownership and code review hold the boundary. Before I move anything else out of the core, I would add that import check. Second, the result is release independence. I don't have a metric for it, such as release frequency. Third, the design expects a peak of about 200 requests a second. I haven't tuned a synchronous FastAPI setup or Uvicorn workers for heavy enterprise load. At this scale, the design handles load in other ways. For example, heavy work runs off the request path, and stateless services scale horizontally.

</details>

---

## 2. SQL on Big Tables and Careful Migrations

**The role needs:** Work on tables with over 100 million records in InterSystems IRIS. That work needs well-optimized SQL and extremely careful migrations.

**Brief:** I moved data access to SQLAlchemy 2, and I tightened the SQL for the patient timeline. The timeline combines five tables and loads one page at a time with a **keyset cursor**, not an offset. In the design, the biggest tables are split by month. Every index serves a named query.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** Clinicians open a patient's timeline during a consultation. The timeline shows appointments, prescriptions, visit notes, documents and daily check-ins in one list. The design target for a timeline read is a 95th percentile (p95) under 120 ms from the cache. Without the cache, the target is under 250 ms. A two-second load is the behaviour the product exists to remove.

The data is large, but the traffic is not. The check-ins table is sized at about 110 million rows: 60,000 monthly-active patients, one check-in a day, for five years. The audit table is sized at about 1.8 billion rows over the same five years.

**Task.** I moved data access to SQLAlchemy 2. I also tightened the SQL for clinical record queries, the ones behind the patient timeline and the care-team views.

**Action.** The database runs as one primary server with two read replicas. It is not split across servers (sharding), and at this scale it should not be.

The check-ins and audit tables use **monthly range partitioning**. Both tables are written in time order. The audit table only gets new rows. A check-in row is rewritten only when the same day arrives again. Queries read a recent time window. So when a query bounds the partition key, PostgreSQL skips almost all of the table (partition pruning). Archiving means detaching an old partition, which only changes metadata. It is not a 500 GB `DELETE`. Both tables also have a Block Range Index (BRIN) on the time column. The rows sit on disk in insert order. So a BRIN index is a fraction of a B-tree's size for the same range scan.

Every index exists for a named query from an Application Programming Interface (API) contract. On a 110-million-row table, an index with no query behind it only makes every write more expensive (write amplification). So the list is short on purpose.

The main challenge in my part was the patient timeline. It is the query clinicians run most often, and it combines five tables with `UNION ALL`. But each table sorts on its own column, and one of those columns, `encounter_date`, is a `date`. A union that mixes a plain date with a date and time (`timestamptz`) cannot be ordered in a fixed, repeatable way. It also cannot be served from one index shape.

So each of the five tables carries a **`timeline_at`** column, filled from that table's sorting column. The timeline query orders only on `timeline_at`. The sorting columns stay, because `encounter_date` is the clinical fact. `timeline_at` only sets the display order. Each table has a B-tree index on the patient and `timeline_at`, newest first.

The timeline uses a cursor instead of an offset (keyset pagination). The cursor holds `timeline_at`, the source table and the row id. So rows from different tables with the same `timeline_at` still come in a fixed order. Each branch of the union has its own `LIMIT`. So PostgreSQL reads at most one page of rows from each table. It does not build and sort the whole union. Offset pagination is not allowed on this query, and the patient and `timeline_at` indexes exist to avoid it.

SQLAlchemy 2 has a typed API, so pyright can check the data access code as a blocking gate. Type checking matters on a medical record, because a wrong join means patient data reaches someone who should not see it.

The access rules had a second risk. Row-Level Security (RLS) policies on every patient table check for an active care relationship. On the check-ins and audit tables, the way a policy is written changes the query plan. One way to write the policy compares `patient_id` with an array built from a subquery (`= ANY (ARRAY(SELECT …))`). Then the patient check can use an index on `patient_id`. If the policy uses an `IN` subquery, or hides the check in a function, the check runs as a filter. Then a query with no patient filter of its own reads every row in each partition it touches. Partition pruning still works, because it comes from the time bound. So the policies use the array form. The slow form still returns the right rows, so a test that only checks the rows would not catch it. A test on the query plan (an **`EXPLAIN` assertion**) guards that shape.

Migrations run with Alembic in an ArgoCD PreSync hook, before the new version rolls out. Every migration follows **expand/contract**. One release adds columns and backfills them. The next release removes what is no longer read. Each migration also works with the previous version of the service. So both versions can run on the same schema during a blue-green switch. A rollback also does not need a down-migration. If a migration cannot be written this way, it is split across two releases.

**Result.** By design, the timeline reads at most one page of rows from each of the five tables. In the design, time-window queries on the check-ins and audit tables skip almost all old months, and a rollback does not need a down-migration. One primary server has enough headroom for the modelled load.

**Honest limits.** First, I haven't worked with InterSystems IRIS. My SQL work is on PostgreSQL, through SQLAlchemy, which this role also uses. Every database has its quirks, and I'd rather learn where they are than work against them. Second, 110 million rows is a five-year sizing estimate for the check-ins table, not a count I measured. The 1.8 billion audit rows are an estimate too. Third, the design gives the migration rule, but not the mechanics for very large tables. It does not describe batched backfills or lock timeouts. It also does not describe how new monthly partitions are created, or how indexes are built on them without long locks. So I can't point to a migration I ran on a table this size. Fourth, I have no measured before-and-after for the timeline. The 120 ms and 250 ms figures are design targets. The latency number on my CV is for search, not for this timeline.

</details>
