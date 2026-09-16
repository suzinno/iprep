# Key Competencies — STAR Stories

> Examples from the latest project: the personalized cancer support platform.
> Ranked by priority for this role.

**Table of Contents**

- [Key Competencies — STAR Stories](#key-competencies--star-stories)
  - [1. FastAPI Architecture and Module Boundaries](#1-fastapi-architecture-and-module-boundaries)
  - [2. REST APIs with SCIM 2.0 and Entra ID Tokens](#2-rest-apis-with-scim-20-and-entra-id-tokens)
  - [3. SQL on Big Tables and Careful Migrations](#3-sql-on-big-tables-and-careful-migrations)
  - [4. RabbitMQ and Reliable Event-Driven Work](#4-rabbitmq-and-reliable-event-driven-work)
  - [5. Quality over Speed: Gates and Self-Review](#5-quality-over-speed-gates-and-self-review)
  - [6. Clarifying Vague Requirements](#6-clarifying-vague-requirements)
  - [7. Testing That Proves Behaviour](#7-testing-that-proves-behaviour)
  - [8. Raising Technical Concerns Constructively](#8-raising-technical-concerns-constructively)
  - [9. Clear Estimates and Process](#9-clear-estimates-and-process)
  - [10. GitOps Delivery](#10-gitops-delivery)
  - [11. Observability and Elasticsearch](#11-observability-and-elasticsearch)
  - [12. API Contracts with the Frontend](#12-api-contracts-with-the-frontend)

---

## 1. FastAPI Architecture and Module Boundaries

**The role needs:** A core backend on Python, [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"), Uvicorn, [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime"), [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") and [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy"). The team also needs someone who understands how to optimize a synchronous FastAPI architecture for heavy enterprise loads.

**Brief:** I designed the core of the platform as a FastAPI **modular monolith**. Two parts moved out into their own services. One manages clinician and care-team accounts over System for Cross-domain Identity Management ([SCIM](https://scim.cloud/ "Standardizes automated provisioning and deprovisioning of user identities between systems")). The other runs clinical Natural Language Processing ([NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Computational techniques for analyzing and generating human language")).

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** The product is a platform for people diagnosed with cancer and for the clinicians who follow them. Patients log how they feel every day. They read guidance for their diagnosis and treatment. They keep appointments, prescriptions and visit notes in one place. Patients and clinicians work with the same record, but their access rules are opposite. The traffic is modest. The design expects about 200 requests a second at peak, with bursts to about 400. And one team works on the system.

**Task.** I was a backend engineer on this platform. My job here was to design the shape of the backend. That meant deciding what stays in one deployable unit and what moves out into its own service.

**Action.** With one team and about 200 requests a second, a full split into microservices would not add throughput. It would add distributed transactions, for example between the diary and the records. Those cost latency and on-call load. So I kept the core as one deployable unit, called `care-core`.

The core has four modules: patient diary, records, clinical content and identity. Each module is its own Python package, with **its own [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") schema**. So the boundary in the code also exists in the database. Without that, any module could slowly start using any table. A module reads its own schema directly. The rule is that a module reaches another module only through a **published in-process interface**, not a direct import. A call through that interface stays inside one process. And the modules can still share a transaction.

The records module is separate on purpose. A clinical record has a different write model from authored content. It also has different consistency and audit rules. If records sat inside clinical content, a prescription and a leaflet would go through the same code path.

Only two parts had a real reason to run outside the core. The SCIM service follows the release cadence of the hospital directory. The NLP service needs graphics processing unit (GPU) hardware. It also ships when a new model version is ready. So I moved those two out as separate FastAPI services. No user request waits on the NLP service, because its work goes through a queue.

Moving services out left a real coupling in the data. The SCIM service still writes to the same PostgreSQL database. It writes only the `identity` schema. That means clinicians, care-team members, and the care relationships that close when the hospital directory disables an account (deprovisioning). It never touches the records, diary or content schemas. So the separation is at the **deployment level, not the data level**. The SCIM service releases when the hospital directory changes. But it cannot change the `identity` tables without taking the core into account. **Schema ownership** keeps this coupling under control. The design also says when to look at the coupling again: when someone proposes a second service that writes across schemas.

We also accepted a trade-off. The four core modules still release as one unit. So one module's release blocks another module's features.

**Result.** SCIM and NLP releases no longer blocked the rest of the product. The core stayed one deployable unit with four modules, and the modules can still share a transaction. We did not pay for a fleet of microservices that the traffic did not need.

**Honest limits.** First, the module boundary is enforced, but not by the database. Python has no visibility modifier, so the pipeline carries import-linter contracts that fail the build on a cross-module import, and an integration test fails a module that runs SQL against a schema it does not own. What that does not cover is dynamic access, such as reaching into another module's package by name at run time. Per-module database roles would cover more, but they would mean a separate connection pool per module, and that would cost us the single transaction across modules. Second, the result is release independence. I don't have a metric for it, such as release frequency. Third, the design expects a peak of about 200 requests a second. I haven't tuned a synchronous FastAPI setup or Uvicorn workers for heavy enterprise load. At this scale, the design handles load in other ways. For example, heavy work runs off the request path, and stateless services scale horizontally.

</details>

---

## 2. REST APIs with SCIM 2.0 and Entra ID Tokens

**The role needs:** Azure, with Entra ID as the identity provider. This need came from the second interview, not from the posting. The team is building a SCIM 2.0 interface, because a user deleted in the directory goes unnoticed. A deleted user just never logs in again, so the deletion goes undetected. The team also plans to carry endpoint-level permissions in the token.

**Brief:** I implemented the Representational State Transfer ([REST](https://en.wikipedia.org/wiki/REST "Architectural style for stateless, resource-oriented HTTP APIs")) endpoints that bring clinician and care-team accounts in from the hospital directory over SCIM 2.0. They also check Entra ID tokens. A clinician token is never valid on the patient portal. When the hospital disables an account (deprovisioning), our database closes that clinician's open care relationships in the same transaction.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** The platform serves two groups of users whose access rules are opposite. About 250,000 patients register themselves over five years. About 3,500 clinicians and about 400 care-team coordinators come from the hospital directory. Content authors and platform operators come from the directory too. Clinician accounts start in the hospital's Entra ID tenant. The requirement is that a clinician who leaves the hospital loses access through the directory, not through a manual step in our product.

**Task.** I implemented the REST Application Programming Interfaces (APIs) for this, with SCIM 2.0 and Entra ID JSON Web Tokens ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties")). Clinician and care-team accounts had to stay provisioned from the hospital directory. They also had to stay off the patient portal. Section 7 covers how the tests for these flows were chosen.

**Action.** "Stay off the patient portal" is not a rule in the user interface. It is a check on the token audience that rejects the request by default (fails closed), before application code runs. The design has **two identity planes**. Patients register themselves through Entra External ID, in a separate patient tenant, with identity proofing at enrolment. Clinicians and care teams sign in through the hospital's Entra ID tenant. They never register themselves, and SCIM is the only way their accounts are created. For them, the hospital's conditional access enforces multi-factor authentication. The platform does not weaken it. Each plane has its own **token audience**: `api://care-platform/patient` and `api://care-platform/clinician`.

Sign-in uses the OAuth 2.0 authorization code flow with Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")). [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect ([OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users")) handles identity. Access tokens are short-lived, at 15 minutes. Refresh tokens are rotated and bound to the client.

The gateway is Azure [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management ([APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Publishes, secures and rate limits APIs behind a managed gateway")), and it validates the JWT. It checks the signature against the cached signing keys, the JSON Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "Publishes the public keys a party needs to verify a signed token")). It also checks the issuer and the expiry. It also checks the audience against the plane of the route. So a clinician token on `/api/v1/diary/check-ins` gets a `403` at the gateway. A patient token on a clinician path gets the same answer. JWT validation failures are counted by reason, with an alert on any sustained rise.

`care-core` then validates the token again. It does not trust a header that the gateway set. So a request that skips the gateway still has its token checked.

The SCIM service runs on its own, and section 1 covers why. I implemented the SCIM endpoints on that service. The service implements `Users` and `Groups`, plus `ServiceProviderConfig`. Entra ID is the only caller allowed. Entra ID signs in with its own client credential. The network also limits where SCIM calls can come from. The SCIM endpoints are never exposed through the patient plane. Pydantic models define the SCIM schema, so the schema is checked in code rather than only described. A [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") lock, keyed by the Entra object ID, makes sure only one change to a directory account runs at a time. The lock expires after 30 seconds.

The risk the design singles out here is deprovisioning, because a failure there can be silent. Access that should have ended has not ended, and nobody sees it. The design covers deprovisioning in three places.

First, a deprovisioning closes every open care relationship for that clinician in the **same transaction**. Which patients a clinician can see (their reach) is checked in the database on every request. The check needs an active care relationship. Section 7 covers that control. So when that transaction commits, the database stops returning that clinician's patient records on the next request. The database check does not wait for the token to expire.

Second, a SCIM sync failure is a **paged alert**. The design treats a deprovisioning that did not land as a security event.

Third, a **detection rule** in Kibana runs over the audit events. It catches a deprovisioning that did not close its care relationships. That alert goes to the security team.

There was also a design choice for when Entra ID itself is down. The signing keys are cached in Redis for 12 hours. The cache is refreshed when a token carries a key id (`kid`) that the cache does not hold. So existing tokens keep validating during an outage. Separately, SCIM sync queues and replays. New clinician sign-in fails. Active sessions keep working until their 15-minute tokens need a refresh, because a refresh also needs Entra ID. That is why the cache time is long on purpose.

**Result.** There is no number for this work, and I would rather say that than invent one. What I can give you is what the design guarantees. A clinician token is rejected on a patient path before application code runs, and `care-core` checks the token again. A clinician's reach to patient records ends in the same database transaction that applies the deprovisioning. No manual step in our product is needed. A sync failure pages someone. A deprovisioning that did not close the care relationships is caught by a detection rule.

**Honest limits.** First, your team plans to put endpoint permissions into the token through an Entra custom claims provider. I have not built that. In this design the token decides the plane. Roles give capability, and reach is checked per request in the database. The design has no central policy engine either. The trade-off I would raise is timing. A permission in a token stays true until the token expires. A check on every request sees a change on the next request. Second, the design does not record how roles or group memberships get into the token, so I cannot speak to that from this project. Third, I have no measured deprovisioning time. When a deprovisioning arrives depends on the directory's provisioning cycle, and the design does not state that cycle. The design also does not say whether open sessions or refresh tokens are revoked on a deprovisioning. The design also does not say what a still-valid token can reach outside patient records, such as content, before that token expires. The design caches a rendered timeline page for 60 seconds. It does not say whether the reach check runs before a cached page is served. Fourth, the design has the paged alert and the detection rule, but no periodic comparison between the directory and the `clinician` table. That comparison is what I would add first. Fifth, the design does not cover the SCIM protocol details. It does not say what `DELETE` does compared with `active: false`. It also does not say how `PATCH` operations are parsed, or how a group maps to a care team. Your case is a user who is deleted, not disabled. For that case, the design does not say whether care relationships close.

</details>

---

## 3. SQL on Big Tables and Careful Migrations

**The role needs:** Work on tables with over 100 million records in InterSystems [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage"). That work needs well-optimized [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") and extremely careful migrations.

**Brief:** I moved data access to SQLAlchemy 2, and I tightened the SQL for the patient timeline. The timeline combines five tables and loads one page at a time with a **keyset cursor**, not an offset. In the design, the biggest tables are split by month. Every index serves a named query.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** Clinicians open a patient's timeline during a consultation. The timeline shows appointments, prescriptions, visit notes, documents and daily check-ins in one list. The design target for a timeline read is a 95th percentile under 120 ms from the cache. Without the cache, the target is under 250 ms. A two-second load is the behaviour the product exists to remove.

The data is large, but the traffic is not. The check-ins table is sized at about 46 million rows: 25,000 patients checking in on a given day, for five years. The audit table is sized at about 1.8 billion rows over the same five years.

**Task.** I moved data access to SQLAlchemy 2. I also tightened the SQL for clinical record queries, the ones behind the patient timeline and the care-team views.

**Action.** The database runs as one primary server with two read replicas. It is not split across servers (sharding), and at this scale it should not be.

The check-ins and audit tables use **monthly range partitioning**. Both tables are written in time order. The audit table only gets new rows. A check-in row is rewritten only when the same day arrives again. Queries read a recent time window. So when a query bounds the partition key, PostgreSQL skips almost all of the table (partition pruning). Archiving means detaching an old partition, which only changes metadata. It is not a 500 GB `DELETE`. Both tables also have a Block Range Index ([BRIN](https://www.postgresql.org/docs/current/brin.html "Compact PostgreSQL index type suited to large, sequentially correlated tables")) on the time column. The rows sit on disk in insert order. So a BRIN index is a fraction of a B-tree's size for the same range scan.

Every index exists for a named query from an API contract. On a 46-million-row table, an index with no query behind it only makes every write more expensive (write amplification). So the list is short on purpose.

The main challenge in my part was the patient timeline. It is the query clinicians run most often, and it combines five tables with `UNION ALL`. But each table sorts on its own column, and one of those columns, `encounter_date`, is a `date`. A union that mixes a plain date with a date and time (`timestamptz`) cannot be ordered in a fixed, repeatable way. It also cannot be served from one index shape.

So each of the five tables carries a **`timeline_at`** column, filled from that table's sorting column. The timeline query orders only on `timeline_at`. The sorting columns stay, because `encounter_date` is the clinical fact. `timeline_at` only sets the display order. Each table has a B-tree index on the patient and `timeline_at`, newest first.

The timeline uses a cursor instead of an offset (keyset pagination). The cursor holds `timeline_at`, the source table and the row id. So rows from different tables with the same `timeline_at` still come in a fixed order. Each branch of the union has its own `LIMIT`. So PostgreSQL reads at most one page of rows from each table. It does not build and sort the whole union. Offset pagination is not allowed on this query, and the patient and `timeline_at` indexes exist to avoid it.

SQLAlchemy 2 has a typed API, so pyright can check the data access code as a blocking gate. Type checking matters on a medical record, because a wrong join means patient data reaches someone who should not see it.

The access rules had a second risk. Row-Level Security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")) policies on every patient table check for an active care relationship. On the check-ins and audit tables, the way a policy is written changes the query plan. One way to write the policy compares `patient_id` with an array built from a subquery (`= ANY (ARRAY(SELECT …))`). Then the patient check can use an index on `patient_id`. If the policy uses an `IN` subquery, or hides the check in a function, the check runs as a filter. Then a query with no patient filter of its own reads every row in each partition it touches. Partition pruning still works, because it comes from the time bound. So the policies use the array form. The slow form still returns the right rows, so a test that only checks the rows would not catch it. A test on the query plan (an **`EXPLAIN` assertion**) guards that shape.

Migrations run with Alembic in an [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") PreSync hook, before the new version rolls out. Every migration follows **expand/contract**. One release adds columns and backfills them. The next release removes what is no longer read. Each migration also works with the previous version of the service. So both versions can run on the same schema during a blue-green switch. A rollback also does not need a down-migration. If a migration cannot be written this way, it is split across two releases.

**Result.** By design, the timeline reads at most one page of rows from each of the five tables. In the design, time-window queries on the check-ins and audit tables skip almost all old months, and a rollback does not need a down-migration. One primary server has enough headroom for the modelled load.

**Honest limits.** First, I haven't worked with InterSystems IRIS. My SQL work is on PostgreSQL, through SQLAlchemy, which this role also uses. Every database has its quirks, and I'd rather learn where they are than work against them. Second, 46 million rows is a five-year sizing estimate for the check-ins table, not a count I measured. The 1.8 billion audit rows are an estimate too. Third, the design gives the migration rule, but not the mechanics for very large tables. It does not describe batched backfills or lock timeouts. It also does not describe how new monthly partitions are created, or how indexes are built on them without long locks. So I can't point to a migration I ran on a table this size. Fourth, I have no measured before-and-after for the timeline. The 120 ms and 250 ms figures are design targets. The latency number on my [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") is for search, not for this timeline.

</details>

---

## 4. RabbitMQ and Reliable Event-Driven Work

**The role needs:** Deep [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") knowledge, together with Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")). The system carries a very large number of product attribute updates, so broker stability under that volume matters.

**Brief:** I built the event-driven paths on this platform: MQTT for check-ins coming in from patients' phones, a `care.events` topic exchange for domain facts, and [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for the work we own and have to retry. Reminders moved off the request path, and a check-in stopped depending on a good connection.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** Patients log how they feel once a day. They also get reminders for appointments and for the check-in itself. Those two things are what the product cannot lose. Patients are often on a weak mobile connection, on public transport or inside a hospital building. Before this work, reminders were sent inline, during the web request that created them. So a reminder died with the request. Nothing recorded that the reminder had not arrived. That meant nobody could say how often it happened.

The volume is modest. The check-in burst is about 50 messages a second, mostly between 07:00 and 09:00.

**Task.** I owned the event-driven paths. My job was to take wellbeing check-ins and appointment reminders off the request path. A weak connection or a failed request should not be able to lose either one.

**Action.** The first decision was which transport does which job. Each transport has a job written down, and nothing crosses those boundaries case by case. RabbitMQ carries domain facts on a topic exchange called `care.events`, over the Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")). Those are facts like "a check-in was recorded" or "an appointment was scheduled". Celery runs on the same broker, on its own queues, for work the platform owns and must retry. Reminder windows and search indexing are that kind of work.

Celery alone was the other option, and I did not choose it. Celery models work we schedule and retry for ourselves. A topic exchange models facts we publish for others. If both go through Celery, every consumer joins one task registry, and publishing a fact means knowing who reads it.

Check-ins come in over the RabbitMQ MQTT plugin, on the topic `care/checkin/{patient_id}`. The phone publishes at Quality of Service level 1 ([QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") 1) on a persistent session. That combination is the whole point. The phone holds the check-in through a tunnel or a dead spot, and delivers it when the connection comes back. The session has to be persistent, because a clean session throws away a publish that was sent but not yet acknowledged. This is also why the broker is RabbitMQ and not Azure Service Bus. Service Bus has no MQTT ingress. So the check-in path would need a separate bridge, and that bridge is the component RabbitMQ already is.

Durability then rests on two settings. Every queue bound to `care.events`, and every Celery queue, is a **quorum queue** on a three-node cluster. **Publisher confirms** are mandatory. So nothing routed to a quorum queue is confirmed to the publisher before a majority of its replicas holds it. Quorum queues were not really a choice here. RabbitMQ 4 removed classic mirrored queues, so a quorum queue is the supported replicated option for this work.

Delivery is at-least-once, so the same check-in can arrive twice. I did not solve that in the application. A check-in row carries a **unique key** on the patient and the day it is recorded for, and the write is an idempotent `INSERT ... ON CONFLICT DO UPDATE` on that pair. A redelivered message then rewrites one row instead of creating a second one. There are also 24-hour idempotency keys in the cache, but those are only an optimisation. If the cache is flushed, the database key is still what makes the write safe.

The first thing the check-in path has to defend against is a behaviour of the broker, not a bug in our code. RabbitMQ returns a publish acknowledgement ([PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message")) for a QoS 1 publish even when the message routes to no queue at all. On MQTT 3.1.1 that acknowledgement carries no reason code, so the phone cannot tell it apart from success. MQTT 5 does carry `No matching subscribers`, but only a client that checks it will act on it. That is exactly the loss this path exists to prevent. The patient's screen says "recorded" and no check-in was ever stored. The design answer is an **alternate exchange** on `care.events`. An unroutable message is re-published there and lands in a queue, where its depth is visible and can raise an alert. Two smaller settings sit next to it. The plugin setting `mqtt.exchange` has to point at `care.events`, or the plugin publishes to `amq.topic` instead. And MQTT's `/` separator is always translated to AMQP's `.`, so the topic binds as `care.checkin.{patient_id}`.

The second problem was the reminders, and the answer was to keep the state out of the queue. A reminder is a row in PostgreSQL with a state. A scheduler runs every 60 seconds and claims the reminders that are due within the next two minutes, using `SELECT ... FOR UPDATE SKIP LOCKED`. That lets several workers run without dispatching the same reminder twice. The claimed row moves to `dispatching`. Every attempt then gets its own delivery row. That row holds the channel, the provider's message id and a final state. Delivery itself goes to the notification service, keyed by that delivery row's id. If an attempt fails, it retries with backoff, then tries another channel, then raises a flag to the care team. A terminal failure reaches a person instead of ending in a log line.

Keeping the state in the database is what makes the path survive an outage. If the notification service or the queue is down, the reminders simply stay `pending` and the next run picks them up. Nothing is lost in a queue outage, because the queue was never where the state lived. The same is true if the scheduler itself stops: reminders are late, not lost.

**Result.** Missed reminders fell by 22%. I want to be precise about where that number comes from, because it is not the broker. It comes from the state machine in the database and from one row per delivery attempt. Those two things also make "how many reminders were missed" a query rather than a search through logs. On the check-in side the result is a property, not a number. The check-in is durable on the broker before the patient's phone is told it was recorded. Nothing is lost from that moment on.

**Honest limits.** First, the role is sized for a much larger volume of attribute updates than this system carries, and for broker memory pressure at that volume. This system is much smaller. Its peak is about 50 messages a second on MQTT. I have not tuned a broker at that volume, and I have not handled broker memory pressure in production. What I have done here is the durability side: quorum queues, mandatory confirms, late acknowledgement, bounded retries and a dead-letter queue. Second, duplicate reminder delivery is still possible, in the race where a delivery succeeds but its receipt is lost. We accepted that on purpose, because a patient seeing a reminder twice is a much better failure than not seeing it. Third, the MQTT plugin authenticates per connection, not per publish. So a long-lived mobile connection has to be re-validated against token expiry separately. The design caps how long a connection may live. The cap is shorter than the refresh-token window. The design also says this needs a prototype against real token lifetimes. Fourth, Celery's support for quorum queues is recent, and I flagged it as a risk rather than assuming it works. That is the constructive-disagreement story in section 8. Fifth, I can say the 22% is the reduction in missed reminders, but I do not have the measurement window or the baseline rate. Sixth, this story is the broker half of that line in the posting. Search, Kibana and Elastic Application Performance Monitoring (APM) are section 11.

</details>

---

## 5. Quality over Speed: Gates and Self-Review

**The role needs:** Quality and thoroughness valued far more than speed, with careful review of test cases and cross-checking of requirements. Artificial Intelligence ([AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Software that generates or assists with tasks such as writing code")) tools are welcome. But every code quality gate still has to pass, leads review the code, and the result has to be readable.

**Brief:** I configured the Continuous Integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Automatically builds and tests code on every change")) gates for this platform: lint, strict type checking, tests and a quality gate, each one blocking. One of them is really a privacy control. My rule is that a gate has to be able to fail. And I read my own diff before I ask anyone else to.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** This is a medical record system. A regression here does not only break a page. It can take away a patient's access, or put one patient's record in front of a clinician who has no care relationship with them. So being careful is not a personality trait on this project. It is the requirement. Three Python services go through the same GitLab CI gates, and each one has its own dependencies.

**Task.** I configured GitLab CI with lint, type and quality gates, so that lint, type checks and test runs all happen before anything deploys. I also moved the three services to Python 3.14 with dependencies managed by [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects"), so the runtime and the packages stayed the same across modules. And I fixed the pipeline and deploy jobs that were failing.

**Action.** The pipeline runs in a fixed order and every step blocks the next one. `ruff` for lint. `pyright --strict` for types. Unit and contract tests. Then integration tests, which run against real data stores and a real broker rather than mocks. Then the SonarQube quality gate, on coverage and on new-code quality. Then the image is built, scanned, and pushed to the registry by digest. The last thing the pipeline does is commit that digest to the manifest repository, and section 10 covers that part.

The part that matters to me is not the list. It is that **each gate can genuinely fail**. A gate that cannot fail proves nothing, and it is worse than no gate, because people trust it. Section 7 covers how the tests behind those gates are chosen.

One gate is a privacy control rather than a style check. No clinical free text, no symptom values and no document contents are ever written to a log. A redaction filter driven by Pydantic drops fields marked sensitive at the formatter. On top of that, a **CI check fails the build** if a log call passes a model that contains a field marked sensitive. That check exists because the failure it catches is silent: a log line that leaks clinical text looks exactly like a log line that does not. There is a second check of the same kind on database roles, and section 7 covers it.

The main challenge in my part was dependency drift. A dependency could resolve one way in the pipeline and another way on a developer's machine. The problem was not the difference itself. It was when the difference appeared. Drift like this does not show at build time. The design calls it a deploy-time surprise, and that is the worst place to learn about it, because by then the change has already been approved.

The fix was one **Poetry lockfile per service**. One lockfile per service keeps the runtime and the packages consistent across modules. The interpreter version is pinned identically across the three services. Pinning applies to the images too. Images are built from **pinned digests** and scanned at build, a dependency audit runs in CI, and only digest-pinned images are deployed. So a mutable tag cannot be swapped underneath a running cluster.

The gates are only one part of it. Before I ask for review, I read my own diff as if someone else wrote it. I run the fast gates locally. And I check the change against the acceptance criteria line by line, because **cross-checking the requirement is a separate act from believing I have met it**. I have been wrong often enough to make that a step rather than a feeling. A reviewer's time is better spent on the design question than on something I could have caught myself.

I use AI tools every day, and my rules do not change when I do. First, I read and understand every line before it reaches a merge request. If I cannot explain why a branch is there, it does not go in. That applies to generated tests most of all, because a test that passes for the wrong reason is worse than no test. Second, the quality gates apply identically. Generated code does not get a lighter review, and a reviewer should not be able to tell which lines came from where. Third, nothing confidential goes into a tool that would take it outside the tenancy: no patient text, no client material, no secrets. On a health-data system that is a legal constraint, not a preference.

AI tools help me most at the two ends of a task. At the start, for finding my way around unfamiliar code and turning a vague ticket into a list of questions to check against the system. At the end, as a second reader on my own diff before a person spends time on it. In the middle, where the decisions are, I use them barely at all. They are weakest exactly where the decision matters: a permission rule, a migration on a huge table, or an ordering property. The answer depends on things the tool cannot see, and the failure is silent.

**Result.** I have no before-and-after number for this work, and I would rather say that than quote one. What I can state are properties. Every gate is blocking and each one can genuinely fail. The runtime and the packages stay consistent across the three services, which removes the drift that used to appear at deploy time. A log call that carries a sensitive field fails the build instead of reaching production. And a mutable tag cannot be swapped underneath a running cluster.

**Honest limits.** First, the posting names Mypy, Black, isort, Trivy and pre-commit. This project used `pyright --strict` rather than Mypy, and I think the strictness setting matters more than which of the two you run. `ruff` covers what Black and isort do separately, so those two were not separate steps. The pipeline scans images and audits dependencies, but I cannot tell you the scanner was Trivy specifically. I run git hooks locally as a personal habit, and that is not the same as a configured pre-commit stage that everyone shares. Second, the design says the interpreter and package versions are pinned the same way across the three services. But it names no check that fails the build when they stop matching. So that consistency is a convention held by code review, not a gate. It is the first gate I would add. Third, static gates look at the artefact, not at behaviour. Lint, type checking and the quality gate cannot tell you that a clinician read a record they should not have. They cannot tell you an audit row was never written either. Those need tests, and section 7 is where that lives. Fourth, a scan proves what is in the image, not what is running. Comparing the digests actually deployed against the scan results is the step people skip, and I would want that comparison somewhere.

</details>

---

## 6. Clarifying Vague Requirements

**The role needs:** Someone who can work from a short, abstract task description without waiting for a fuller one. The expectation is to book a call with the application manager and work out the business logic before coding starts.

**Brief:** I do the homework first, then ask. I reconstruct as much of the intent as the system and the existing documents support. Then I write down my reading, and the decisions I cannot make alone. The person who owns the business logic then reacts to a proposal instead of facing an open question.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** The requirement I want to use is one line in the project's "nice to have" list: "Trend surfacing — flagging a sustained deterioration in check-in scores to the care team." That is the whole thing. Four words in it carry weight, and the line defines none of them. How long is "sustained"? How far down is a "deterioration"? Who exactly is "the care team"? And what does "flagging" oblige anyone to do?

**Task.** The job would be to turn that line into acceptance criteria someone has agreed to. I would have to do that without waiting for a better ticket, and without quietly building something the product had already said it would not build.

**Action.** The first step is to read the system before asking anything. Three things are already settled, and I do not need a meeting to find them. The symptom scores are stored as a flexible document rather than fixed columns, with an index behind the trend query, so the data shape exists. The read endpoint is already in the API contract, on the clinician side, and it returns a series plus a list of flags. And "the care team" is not a loose phrase here. The design has a care-team table and a care-relationship table, and the RLS policies already join through the care-relationship one.

Then I read the exclusions, which is a separate act from reading the requirements and catches a different kind of mistake. The requirements list rules out diagnostic or triage decision support. That one line from the **exclusion list** removes a whole class of interpretation. A generous reading of the trend-surfacing line is easy to hear as triage support. That is the real risk in an abstract ticket on this system. The risk is not doing too little. It is quietly building something the product said it would not build.

So what is actually missing is narrower than it first looks. The read path is specified. The meaning of a flag is not. The word `flags` appears once in the whole design set, and nothing says what puts an entry into it.

That leaves four decisions I cannot make on my own. Over what window is a deterioration "sustained". What magnitude counts. Does this reach the whole care team or the named clinician. And is the flag advisory, or does it create an obligation to act. Those are business questions with clinical and legal consequences. Guessing at them is how you build the wrong thing carefully.

Two of those four are also the expensive kind. My test is simple. Does the answer change something costly to reverse? A schema, an interface other teams use, or a boundary about who can see what. A threshold or a default value can be a parameter with a comment saying it is a placeholder. But who receives the flag is a question about who sees what, and whether the flag obliges action has a clinical consequence. Those get answered first.

Then I book a short slot with the application manager or the product owner who holds the business logic. Not necessarily with whoever wrote the ticket. A one-line ticket is often relayed rather than owned, so I go to whoever holds the logic. That is going to the source rather than around anyone, and I would tell the lead I did it.

I do not arrive with four questions. I arrive with a **proposal with a default** for each one. I propose that a sustained deterioration means three consecutive days below the baseline, which answers the window and the magnitude together. I propose that it notifies the named clinician rather than the whole care team. I propose that the flag is advisory. Then I ask them which of the three is wrong. Someone can correct a proposal in a minute. An open question makes them do my thinking for me.

While I wait for that call, I am not blocked. I do the work that does not depend on the answer: the data access, the test scaffolding, the shape of the migration. Two days waiting is not two lost days unless I let it be. If two days turns into a week, I raise it with my own lead. A decision sitting with one person for a week is a planning problem somebody else should know about.

The last step is writing the agreed criteria down. They go on **the ticket**, not into a chat thread. Anything that changes a documented boundary goes into the design file that owns it. Section 9 covers what happens to the estimate.

**Result.** The general claim I would make for this approach is that the call takes about twenty minutes and saves a week. For this particular requirement, what the method produces is more modest and more honest. The exclusion list rules out a whole class of interpretation before anyone is asked a question. And the method isolates four business decisions, so they go to the person who can actually make them instead of being guessed at by me.

**Honest limits.** First, this is how I work, applied to that requirement. I cannot point you at the meeting, the date, or what was decided. The design documents do not record any of it, and I will not invent one for an interview. Trend surfacing is still a nice-to-have with a read endpoint and an index behind it. Second, the three proposals are proposals. They are what I would walk in with, not what was settled. Third, on this platform the reverse-engineering is of a design set, which is the easier version. The harder version is working the rules out of a schema and its migration history, with no document to check against. I did that on the retail catalog project, not this one.

</details>

---

## 7. Testing That Proves Behaviour

**The role needs:** Extensive unit and integration tests, expertise in Pytest and Xray, a 90% coverage target, and the patience to wait twenty to thirty minutes for a pipeline to pass.

**Brief:** I do not choose tests by what is cheap to cover. I choose them by what happens when the thing fails, so the tests I wrote cover the paths where a regression takes a patient's access away. The test I find most interesting on this system is not one of mine. It is the one that proves the access control survives a reused database connection.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** A clinician may only see a patient they have an active care relationship with. That check does not live in the application. It lives in the database, as an RLS policy. It is the single most important control in the design, because it changes what a mistake does. A query a developer forgets to scope returns zero rows, instead of returning another patient's record.

**Task.** I wrote the Pytest unit and integration tests for the API contracts, the identity and SCIM flows, and the clinical content services. The point of those suites was that a SCIM change or a portal change should not be able to take away a patient's access.

**Action.** I pick tests by **the consequence of a failure**, not by what is cheap to cover. The design makes the same choice. Coverage targets the API schemas, the identity and SCIM flows, and the clinical content services. Those are the paths where a regression removes a patient's access. A bug there is an access-control bug, not a display bug, and that is a different category of problem.

Integration tests only prove something if the dependencies are real. The integration stage runs against real containers in Docker Compose: PostgreSQL, [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), Elasticsearch, Redis and RabbitMQ. It is the same stack a developer runs locally. A mocked broker cannot fail the way a real one does. And a fake database cannot show you how RLS behaves. So the database-level assertions only work because the database is real.

The hardest part is what happens underneath all of that. In production the database is Azure Flexible Server, and it sits behind a connection pooler that works in transaction mode. A transaction-mode pooler reuses one connection across requests from different people. The application tells the database who the actor is by setting a variable. A plain `SET` is scoped to the session. So on a reused connection, one caller's actor would still be set for the next caller's query. The strongest control in the design would then become its exact opposite. Instead of returning zero rows to a query that forgot to scope itself, it would return another patient's rows.

I want to be accurate about what this is. It is not a bug we shipped and then found. It is a hazard the design names in advance. It is worth naming because a test suite that never reuses a connection cannot see it. Every test still passes.

The answer has three parts. First, the actor is set with **`SET LOCAL`** inside the request transaction, never a plain `SET`. Second, every statement of a request runs inside that transaction, because a `SET LOCAL` issued outside a transaction block has no effect. Third, a **pooled-connection test** asserts it, rather than a reviewer promising it. That test sends two different actors through one reused connection. It checks that the second actor sees nothing belonging to the first.

There is a second test next to it that is easier to forget. The policy reads the actor through a function that turns an empty string into null (`nullif(current_setting('app.actor_id', true), '')`). Without that, a request with no actor behaves differently depending on which connection it lands on. A fresh connection returns null. A connection that has already served a request returns an empty string, and then the cast fails. So a second test runs a query with no actor on a connection that has already served a scoped request, and asserts zero rows. Fresh connection or reused connection, the answer has to be the same.

One more thing has to hold before any of that means anything. The application's database role is `NOSUPERUSER` and does not have `BYPASSRLS`. Migrations run as a separate owning role that never serves a request. A **role-privilege assertion** runs in the pipeline, so a role that quietly grew the right to bypass the policies fails the build. That check is the sort section 5 talks about: it catches something that produces no error at all.

You mention a twenty to thirty minute pipeline. A pipeline that slow changes how I work rather than how much I deliver, and I would rather wait for a gate that can really fail. I batch related changes into one merge request. I do not push a branch just to see whether it compiles. The rest of that habit is in section 5.

**Result.** There is no number here, and I would rather say that than reach for one. What I can state are properties, and each one is a test rather than an intention. An actor set in one request cannot survive into the next request on the same connection. A request with no actor matches no rows, on a reused connection and on a fresh one. The application role cannot bypass RLS, and the pipeline asserts it. Integration runs against the real data stores and the real broker. The rule behind all four is that a claim which might be false gets a test before it gets trusted.

**Honest limits.** First, and this is the one I would raise myself: the pooled-connection test is only meaningful against the transaction-mode pooler that production runs behind. The Compose stack names PostgreSQL, not the pooler. That gap is what makes a control look tested when it is not. It is the part of the suite I would want proven first. Second, the design says a pooled-connection test asserts this behaviour. The design does not say which stage runs that test. Only the role-privilege assertion is written down as running in the pipeline. I would want to know where those tests run before I called them a gate. Third, on coverage: the role asks for 90%, and I would work to whatever number the team sets. But I do not claim a coverage figure for this project. SonarQube gates coverage and new-code quality, and no target percentage is named anywhere in the design. A high number tells you the suite executes the code. It does not tell you the suite asserts anything useful. The statement worth making is which paths are covered and why. Fourth, I have not used Xray. My tracking experience is Jira for estimates and remaining work, and Confluence for release and incident notes. I would not want to imply otherwise. Xray changes traceability and reporting rather than test design, so I would expect to be productive with it in days rather than weeks. Fifth, I do not have a measured pipeline duration for this project, so I cannot compare it with your twenty to thirty minutes.

</details>

---

## 8. Raising Technical Concerns Constructively

**The role needs:** Someone who stays professional about the technology, raises technical issues with the people who own the decision, and does it constructively. Proactivity is welcome, but steady rather than pushy.

**Brief:** When I raise a concern, I name the mechanism first. Then I propose the test that would settle it. Both go into the file that owns the decision. My example on this platform is Celery running on quorum queues, and I will be honest that its status is still open.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** The reminder path is one of the two things this product cannot lose. It runs on Celery, on RabbitMQ **quorum queues**, which section 4 explains were not really a choice.

**Task.** My task was to decide whether the reminder path was allowed to depend on Celery running on quorum queues. It had to be done without assuming Celery works, and without holding up the rest of the design.

**Action.** The first thing a concern needs is a **mechanism**. Not "Celery feels risky". Celery's support for quorum queues is recent, and it interacts with three specific settings this design depends on: `task_acks_late`, global QoS, and priority. That is something another engineer can go and check, agree with, or disagree with. A complaint that names no mechanism cannot be acted on, and it costs the team more than it returns.

The second thing a concern needs is a way to settle it. In this case that is a **version test**. Pin the Celery version and test it against the broker version. Do that before the reminder path depends on it. A concern with no test attached is only an opinion.

The third thing is a **fallback**. Here that is raw AMQP consumers for the `celery.reminders` queue. What makes that fallback cheap is that the design had already made room for it. Celery and the topic exchange were kept separate for a completely different reason, which section 4 covers. So the design already accommodates the fallback, and that is the whole reason it is cheap.

I want to be straight about where this stands. It is still open. Running a real broker in the pipeline does not settle it. The question needs that pinned-version test specifically, and the pipeline as designed does not assert it yet. I would rather the status say "open" than say "fine".

This is not one anecdote, and that is the part I would want a lead to notice. The same design flags the MQTT plugin's per-connection authentication as needing a prototype. It flags the missing trace-context header in MQTT 3.1.1 as a decision to take before instrumenting. It flags the audit volume, which section 3 sizes and which the design puts at roughly five times all the clinical data combined, as something to validate against a clinical pilot before build. It flags the clinical synonym set as needing an owner outside engineering. And it flags the data-protection assessment for model fine-tuning as something to complete before the first tuning run, not after it.

Running two brokers is the same idea applied to a cost rather than a risk. It is a real operational cost, and the file that takes the cost says so. It also writes down **the condition that would reverse it**: two brokers are the first thing to revisit if MQTT ingress is ever dropped. That is the house rule on this project. Where a cost is taken, the file that takes it names the price and the condition that would reverse it. So writing a concern into the document is not my personal style here. It is how the design stays accurate about its own risks.

On raising a disagreement itself, my habits are simple. I take it to the person who owns the decision, in the merge request or the design document where it belongs. I try to state the other position accurately before I state mine, because if I cannot do that, I do not understand it yet. I do not argue technology choices in shared channels, and I do not join in when a stack is being criticised in general terms. If something does go wrong in a part of the system someone else owns, I take it to that owner, with the query and the numbers.

When I am overruled on a trade-off, that is their call to make and I make it work. I say my concern once, clearly, with the reason, and I note what would make us look at it again. Then I write the cost down: what breaks, when it surfaces, and what it would take to undo. The follow-up becomes a ticket rather than a grievance. The one exception is a genuine safety or compliance problem. There I would escalate rather than comply, and I would tell the person I was doing it rather than doing it quietly. That is a last resort, and only for that category.

**Result.** There is no number here and no closed outcome. What I can point at are three properties. The risky dependency has a documented way out that the design had already accommodated, instead of an assumption that it will be fine. The condition that would reverse the two-broker cost is written next to the cost. And the concern survives a handover, because it lives in the design file rather than in a conversation nobody can reconstruct later.

**Honest limits.** First, the status is open. Nothing records the pinned-version test being run, and nothing records a decision either to keep Celery on those queues or to move to raw consumers. Second, this was not an argument with anybody. It is a concern raised in the document that owns the path. I cannot name you a counterpart, a meeting or a reaction, because there is no record of one. I would rather say that than invent it. Third, being overruled and then building it properly anyway is how I intend to work. I would want to be held to that. But I cannot point you at a recorded instance of it on this project. Fourth, the two-broker cost is real but it is not quantified anywhere. No money, no hours, no headcount. Only the trigger to revisit it is concrete.

</details>

---

## 9. Clear Estimates and Process

**The role needs:** A remaining estimate kept up to date in Jira every day. Time tracked in the client's own system, daily stand-ups, and blockers communicated as they appear.

**Brief:** I keep the written trail current while the work happens, rather than reconstructing it later. The **remaining estimate** gets revised daily with a specific reason attached. Blockers go on the ticket the day they appear. Release and incident notes go in one shared place, so the deploy runbook is one document.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** On this platform the written record is not just tidiness. Other parts of the system depend on it. The breach-reporting path has a 72-hour clock, and the path itself is documented in the runbook. Restore is rehearsed against a scratch environment every quarter. And the three services release independently, on different strategies, which section 10 covers.

**Task.** I kept estimates and remaining work current in Jira, and release and incident notes in Confluence, so those releases shared one runbook instead of one person's memory.

**Action.** First, the estimate gets set after the scope lands, not before. Section 6 covers how the scope gets settled. Estimating an abstract ticket means guessing twice.

Then the reason this work is hard to estimate, because that is the part people skip. On this platform a schema change lands across three releases, which section 3 explains. So the implementation is small and the verification is not. When I estimate that kind of task I split it up front and price the verification separately. Expand is a day. The backfill is a day plus a rehearsal of the backfill. Contract is half a day in a later release. The verification is spread across all three. And I say that out loud when I give the number: this is two days of code and three days of verifying the plan and the rollback. Work on an authorization boundary behaves the same way.

There is also a risk you cannot price in advance. Anything that takes a lock on a large table can run long in a way no estimate covers. So the estimate comes with a stated plan for what happens if the backfill has to be stopped halfway. If somebody wants the whole thing faster, the thing that gets cut is the rehearsal. I want that decision made knowingly rather than by accident.

Then the daily part. I revise the remaining estimate, never the original. The original is a historical artefact, and rewriting it hides exactly the information a planner needs. Next to the new number goes a specific cause. Not "taking longer than expected". Something a person can act on. The column has to be added across three releases, because of the expand/contract rule section 3 describes. So the migration is two days more than I planned. A reason lets someone decide something. A vague number just moves the surprise.

Timing matters more than accuracy here. I would rather revise upward on day two and revise back down on day four than deliver a surprise on day five. An estimate is a forecast made with the least information anyone will ever have, so being wrong is normal. Being wrong quietly is not. If yesterday changed my view of how long something takes, the stand-up is where I say so, in one sentence, on the day I formed the view.

A **blocker note** has four parts and goes on the ticket the day the blocker appears. The specific thing I need and who owns it. What I have already tried. What it is costing, which is usually "not blocking yet, it becomes blocking on Friday". And what I am doing in the meantime. The note goes on the ticket rather than in a chat thread, because chat scrolls and the ticket is where somebody looks in a week. If it does not move, I follow up with a date, and after that I go to my own lead rather than to theirs. When it unblocks, I say so on the ticket and thank whoever did it. I do not name another team as blocking in a shared channel.

Stand-ups I keep short and specific: what moved, what is next, what is in my way. A blocker named as a specific thing a specific person can unblock, not as a general difficulty. If two of us need twenty minutes, we take it afterwards.

The runbook is the part that is actually architectural. Release and incident notes go into the shared space as they happen, so there is **one runbook** rather than a different story for each service. Two things in the design depend on that document existing. The 72-hour breach-reporting path is written in it. And the quarterly **restore rehearsal** works against a scratch environment. It covers the two paths that are easiest to get wrong. One is a point-in-time restore of PostgreSQL to a chosen timestamp. The other is a full rebuild of the search index from PostgreSQL and the content store, then a document count to check the two match. A backup that has never been restored is an assumption, not a control. In the same way, a runbook nobody runs is a wish list. The rehearsal is what keeps it correct.

Keeping that written record costs about ten minutes a day, and I would rather spend that than reconstruct a week later. On a health platform the question "when did this go out, what did we know at the time, and why did the estimate move" sometimes comes from outside the team. A status written at the end of a sprint is fiction. A status updated the same day is a record. The one thing I would push back on is the same report going into a ticket and a chat and a spreadsheet. I would raise that once, politely, and drop it if the answer is that both audiences need their own.

**Result.** There is no number here, and no single dramatic story. What I can point at are two properties. One runbook exists as a single document, which is the thing the restore rehearsal and the breach-reporting path both depend on. And a revised number with a cause attached reaches a planner while they can still do something with it, rather than arriving as a surprise on the due date.

**Honest limits.** First, this is a routine rather than one dramatic incident. I cannot give you a specific task on this project whose estimate slipped, by how much, what the reason turned out to be, and what the planner then did. Second, on time tracking: I record time as the work happens rather than reconstructing it on a Friday, and I am comfortable doing that in whatever system you use. But I have tracked it in Jira, not in a separate client-side tool, so I would be learning your system rather than bringing experience of it. Third, my CV says that diary, content and identity deploys shared one runbook. That wording is loose and I would rather correct it myself. Those are three of the four modules inside one deployable unit, `care-core`, where content is the clinical-content module. So they are one deploy, not three. The accurate version is one runbook across the three services that do release independently, not across modules. Fourth, the quarterly restore rehearsal is the cadence the design sets. I can tell you what it covers and why it exists. I cannot vouch that every quarter's rehearsal was carried out, or point you at a correction it produced in the runbook.

</details>

---

## 10. GitOps Delivery

**The role needs:** Docker, Docker Compose, GitLab CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step"), ArgoCD, GitOps, OpenShift and Prometheus.

**Brief:** Releases go out through ArgoCD from a manifest repository, so no pipeline job holds cluster credentials. Each service has a release strategy picked against the failure it can actually have. Rollback is a revert of a commit, not a re-run of a deploy job.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** Three services release independently, plus two Azure Functions, and they sit across two clusters. The data is regulated clinical data. And the pipeline runs code from every merge request.

**Task.** I configured the GitLab CI gates that run before the deploys, and I fixed the pipeline and deploy jobs that were failing. I deployed releases with ArgoCD to OpenShift and [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications"), so the three services that release independently all use the same GitOps path.

**Action.** The first rule is that the pipeline never touches the cluster. GitLab CI builds and gates. ArgoCD deploys. The last thing the pipeline does is commit the image digest to the **manifest repository**, and ArgoCD reconciles that onto both clusters.

That is not a preference about tools. A deploy job would need standing privilege on the cluster, on a system holding special-category health data. Pulling the desired state from a repository removes that credential instead of protecting it. It also changes what rollback means. Because the desired state is a commit, rolling back is reverting the commit. One declared desired state, one rollback mechanism, and no imperative deploys from the cluster side.

The release strategies then differ by service, and each one is chosen against a named failure rather than by preference. The core is **blue-green**: a single instantaneous route switch, which is the cleanest rollback for the service that holds the record. The NLP service is **canary**, at 5%, then 25%, then 100%. Model quality shows up statistically. So the design treats a percentage rollout, with confidence and latency compared between the two versions, as the only way to see a regression before everyone gets it. The SCIM service is a rolling update: an external caller, idempotent operations, and no user-visible surface. The Azure Functions go out by slot swap.

The sync runs two hooks. Migrations run in the PreSync hook, before the rollout, under a separate owning role that never serves a request. Section 3 covers the expand/contract rule. The delivery consequence is that a rollback is an ArgoCD **revision revert**, with no down-migration. After the rollout, a PostSync hook runs a smoke test and a Service Level Objective ([SLO](https://sre.google/sre-book/service-level-objectives/ "Target value for a service level indicator that a service commits to meet")) check.

Then the expensive part, which I would rather raise myself than be asked about. There are two clusters. The OpenShift cluster (`aro-primary`) holds everything stateful and the two FastAPI services. A second cluster (`aks-ml`), with a GPU node pool, holds the NLP service and nothing else. The design itself calls this its most expensive choice. It is justified by exactly two things: managing the GPU node pool, and the independent release cadence the brief asks for on the NLP service. The alternative that was considered and rejected was one OpenShift cluster with a GPU machine set.

The cost is concrete, not theoretical. Network policy only governs traffic inside a cluster, so the call from the core to the NLP service crosses peered networks. It needs network security groups, a private endpoint and mutual Transport Layer Security. That is three mechanisms where one would do. The split also makes a certificate manager an explicit dependency, because OpenShift's built-in service certificates do not span clusters.

The cost is acceptable because the design writes down the condition that would reverse the split. If GPU inference ever moves to a managed endpoint, `aks-ml` should be collapsed into `aro-primary`. The design deliberately keeps no state on `aks-ml`, so that collapse stays cheap. The blast radius is bounded too. A partition between the clusters affects page generation only, because nothing on a user's request path lives on `aks-ml`.

**Result.** There is no delivery number in this project's record. No deploy frequency, no lead time, no rollback duration, no failed-deploy rate. Here is what I can stand behind. The three services release on one GitOps path. No pipeline job holds cluster credentials. A rollback is a revision revert and needs no down-migration. Only digest-pinned images are deployed, which section 5 covers. Nothing is deployed imperatively from the cluster side.

**Honest limits.** First, on OpenShift specifically. I have used it as a delivery target: a managed cluster, a GitOps controller reconciling from a manifest repository, migrations in a PreSync hook and a smoke test in a PostSync hook. I have used the platform's own build tooling much less, and I have not written security context constraints or operators. If I joined, there are four things I would want to establish early: which security context constraint is in force, how the platform networking layer is set up, the upgrade cadence, and whether the platform's build tooling or the external pipeline is authoritative. Second, the PostSync step is thin in the design. It says a smoke test and an SLO check. Nothing says what the smoke test asserts, which threshold fails a sync, or whether a failed check rolls back on its own. I would want that pinned down before relying on it. Third, I have no war story here. Nothing records a deploy that went wrong, a rollback actually executed, or a bad canary caught in the 5% window. I can tell you what the path does, not what it has survived. Fourth, collapsing the second cluster is an intention with a stated trigger, not something that has been done. Fifth, two more items from that line of the posting live elsewhere. Docker image builds and the Docker Compose integration stack are sections 5 and 7. Prometheus is section 11.

</details>

---

## 11. Observability and Elasticsearch

**The role needs:** Elasticsearch and the Elastic stack, including Kibana and Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production"), together with Prometheus.

**Brief:** I designed the Elasticsearch indexes for clinical content search. I also instrumented Elastic APM, Prometheus and Kibana for API and consumer latency and error rates. I would want to talk about two things. First, why the scope filter is a correctness control and not just a speed improvement. Second, why the index is written through an outbox rather than a second write.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** Patients and clinicians need to find a note, a piece of guidance or a past visit without scanning a whole record. The volume makes that a real engineering problem: about 2.4 million visit notes over five years, roughly 150 GB in the search cluster. PostgreSQL full-text search is fine at 100,000 notes. It is not fine at 2.4 million with per-clause filtering, highlighting and relevance tuning. The target is a 95th percentile search under 400 ms.

**Task.** I designed the PostgreSQL schemas and the Elasticsearch indexes for clinical content search. I also instrumented Elastic APM, Prometheus and Kibana, to track API and consumer latency and error rates on the wellbeing and reminder traffic.

**Action.** The search side is three indexes behind one read alias. Clients never query the search cluster directly. The core builds every query and injects the scope filter itself.

That scope filter is a correctness control before it is anything else. Every document in every index carries the patient id and the care-team ids. Every query is then wrapped in a filter on those two fields, derived from the caller's token and the care-relationship table. The reason is simple: a search engine that can return a document the record layer would refuse is a disclosure path. So search uses the same scope as the RLS policies in section 3, and search cannot become the way around them.

The same fields are also what make it fast. Scope and date clauses go in **filter context**, which is cacheable and unscored. Only the user's own text goes in the scoring clause. So the expensive scoring pass runs on an already filtered set. Two indexing settings sit next to that. Bulk indexing flushes at 5 seconds or 1000 documents. And the refresh interval is 5 seconds rather than the 1-second default, which roughly halves segment-merge pressure.

Now the part I think is the actual design decision. The core never writes to the search cluster directly. Every write commits to PostgreSQL with an **outbox** row in the same transaction. A relay publishes that row to `care.events`, and the index consumer bulk-indexes it. The alternative is a dual write. A dual write has one bad failure. The PostgreSQL commit succeeds, the index write fails, and the index is permanently wrong with nothing to detect it. With the outbox, the row stays unpublished until the index succeeds. So the backlog is visible as a metric and it drains on recovery. On top of that, a nightly reconciliation compares document counts per patient between the two and reindexes the patients that diverge.

That correctness costs freshness, and the design states the cost as a sum rather than a single number. The relay takes up to 2 seconds, the bulk flush up to 5, and the refresh interval is another 5. So a newly saved note is searchable at a 50th percentile under 8 seconds, a 95th under 15, and a 99th under 30. Stating it as a sum is deliberate, because tightening any one of the three cannot bring the total below the sum of the other two.

There are two telemetry planes, because the system runs partly on the clusters and partly on Azure's own services. They are joined rather than left separate. A standard **`traceparent`** header travels in message headers. So one trace covers the `POST /diary/check-ins` request, the `care.events` exchange, the index consumer and the write into the search cluster. Azure Monitor diagnostic logs are shipped into the same Elastic deployment, so Kibana is the one place to read both. Without that join, a reminder that fails between `celery.reminders` and the notification service leaves you with two separate traces you cannot join.

Tracing is Elastic APM. The Python agent auto-instruments FastAPI, SQLAlchemy, Celery, RabbitMQ and outbound [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources"). Sampling is 100% of errors and of all reminder and NLP traffic, and 10% of routine reads.

Prometheus collects the metrics and the dashboards live in Kibana. The Service Level Indicators (SLIs) I care about most on the consumer side are three. `consumer_task_duration_seconds`, at the 95th percentile by queue, alerting above 5 seconds on `celery.reminders` or `celery.index`. The ratio of `consumer_task_failed_total` to `consumer_task_total` by queue, alerting above 1% over 15 minutes. And `outbox_unpublished_age_seconds`, which is the index-freshness signal, alerting above 30 seconds for 5 minutes. That last one is the one I would watch, because it is meant to catch a stalled index before a clinician notices a note is missing.

Logging is structured, in JavaScript Object Notation ([JSON](https://www.json.org/json-en.html "Lightweight text format for structured data exchange")), written to standard output and shipped to Elasticsearch. Every line carries the trace id, the span id, the service, the module, the kind of actor, and where it applies the patient id. No clinical content is ever logged, and section 5 covers the gate that enforces that. Audit is a database table, never a log stream. Logs are for operators and audit is for the regulator. Conflating the two means the log retention policy quietly becomes the audit policy.

The open problem is the first hop. The trace is continuous from the HTTP request, through the exchange, through the consumer, to the index write. The leg from the patient's device to the broker is not settled, because MQTT 3.1.1 has no user-property header for carrying context. Either the check-in clients move to MQTT 5, or `traceparent` gets carried inside the payload envelope. That has to be decided before instrumenting, because retrofitting it breaks every client already published. I would not tell you that leg is traced today.

**Result.** The number on my CV is a 35% cut in query latency, and I want to scope it tightly. It is for clinical content search. It is not the patient timeline, not the record queries, not write latency, not index freshness and not relevance. The target that work was aimed at is a 95th percentile search under 400 ms. The objective on top of that is 99.5% monthly. And search degrades to the PostgreSQL chronological fallback rather than erroring. On the observability side the results are properties rather than numbers. One trace that crosses from the request into the background work. One place to read it. And a freshness alert set to fire before a user sees a missing note.

**Honest limits.** First, the 35% has no baseline I can quote you. I do not have the before figure, the measurement method or the environment it was measured in. Second, there is a separate 28% on my CV, for relevance, and I deliberately will not pair the two. That number comes from two fine-tuned models: entity and code extraction from visit notes, and passage reranking when approved passages are retrieved. Both are evaluated against a held-out clinical set. It is not a search-relevance number. A relevance claim about search would depend on a clinical synonym and abbreviation set that has no owner, so I do not make one. Third, on the MQTT trace leg. The telemetry section says the trace context travels on every hop, including MQTT, and a note a few paragraphs down records the MQTT decision as still open. That tension is in the document, and I would want it resolved rather than inherited. Fourth, the design names metrics and thresholds but not the tooling around them. No rule files, no scrape configuration, and no named log shipper. I can give you the indicators and the alert thresholds, not the configuration. Fifth, there is a real lag window on scope changes. After a patient's care team is reassigned, the outgoing team can still match in search until the reindex finishes. What makes that acceptable is that reassignment also closes the care-relationship row, and the record layer honours that immediately. Sixth, nothing records this instrumentation being verified. No proof that an alert fired when it should, and no end-to-end trace assertion in a test. That is the first thing I would add.

</details>

---

## 12. API Contracts with the Frontend

**The role needs:** Close collaboration with a frontend team working in JavaScript and TypeScript, Vue, Nuxt, Pinia, VueUse, PrimeVue, Vite and Playwright. Understanding [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") and Orval for API contracts is essential.

**Brief:** The contract is an artefact, not a document. It is generated from the models that validate the requests, so it cannot drift from the code. A breaking change to a response shape fails my build rather than someone else's screen.

<details>
<summary><strong>STAR story</strong></summary>

**Situation.** One API serves two audiences whose access rules are opposite. Patients and clinicians both sit on `/api/v1`, separated at the gateway by the audience in their token. The web client consumes the same REST surface. And in the design's own words, the paths these contracts cover are the paths where a regression removes a patient's access.

**Task.** I implemented the REST APIs. Section 2 covers the SCIM and Entra ID side. I also wrote the Pytest suites for the API contracts, the identity flows and the clinical content services. I also configured the pipeline those suites run in, and fixed the jobs when they broke.

**Action.** The core idea is that the contract is generated, not maintained. Pydantic models define every request and response body. FastAPI emits the OpenAPI document from those same models, and that document is **the published contract**. The property that matters is that the document cannot drift from the code. The objects that validate an incoming request are the objects that produce the schema. The contract is executable rather than documented.

Then it matters where a break lands. A change to a response shape fails the **contract suite**, which runs in the same blocking stage as the unit tests. That is before the integration tests, before an image is built, and long before anything is synced to a cluster.

I want to be straight about one thing here. The design documents describe the contract, not the consumer. They never name a frontend team or a generated client. But the reason I care where the break lands is the consumer. If a frontend generates a typed client from the document, a breaking change becomes a failing test in my pipeline. Not a broken screen in theirs. I would rather find a contract break in a CI job than in a stand-up.

It helps to be precise about what "breaking" means. Removing or renaming a response field. Narrowing a type. Making a request field non-nullable, or making a response field nullable, because the direction is what makes each one breaking. Adding a required request field, though adding an optional one is safe. Changing the members of an enumeration, because a client that switches exhaustively over it breaks on a new value. Changing which status codes an operation returns, or the shape of the error body. The test I use is simple. A change is safe if every request an old client can send still succeeds. And every response it gets back still parses under its old schema.

Several conventions exist to keep evolution inside a version additive. The path is versioned at `/api/v1`. Pagination is a cursor everywhere, for the reason section 3 gives. An `Idempotency-Key` is required on every `POST` mutation. Error bodies follow [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details. The reason I value that is that a client cannot branch on prose. And `traceparent` is propagated on every hop, which is section 11. The design does not say what happens when a change cannot be made additively. What I would propose is a second version served alongside the first until clients move, but that is my proposal and not something the documents record.

On the synchronous side, anything a user waits for goes over REST through the gateway: the timeline, record reads and writes, search, page delivery. A user-visible read has no business being eventually consistent. Even the daily check-in has a REST endpoint next to the MQTT one that section 4 covers, returning `202` with the same meaning, because the web client needs it. Internally the design chose not to use [gRPC](https://grpc.io/docs/ "gRPC Remote Procedure Calls — Contract-first remote procedure call framework running over HTTP/2 with protocol buffer payloads"). It would be marginally faster, but across three services the shared FastAPI and Pydantic toolchain is worth more than the microseconds.

The mechanism catches a break. It does not have the conversation. The thing I would add is a **schema diff gate**. It generates the OpenAPI document in the pipeline and compares it against a committed baseline. A breaking change then fails the build. That is not in this design, and I want to be clear it is something I would propose rather than something that was there. Its real value is not the gate. It is that the diff becomes the artefact I take to the frontend leads before I implement anything. Here is the change, here is what it breaks in your generated client, here is the window where both versions run. That is a better way to open the conversation than letting them find it in their build.

One last thing I watch for. A response shape that forces the client into a loop is a backend design defect, not a frontend problem. A response shape is far easier to argue about while it is still a Pydantic model, and much harder once a screen has been built on it. The fix is not more caching. It is agreeing what one screen actually needs and returning that.

**Result.** No number and no incident here. The properties I can stand behind are three. The contract cannot drift from the code, because it is generated from the models that validate the requests. A breaking change to a response shape fails a blocking stage in my pipeline, before an image is built. And the conventions are set up so that evolution inside a version stays additive.

**Honest limits.** First, on Orval. The posting says understanding OpenAPI and Orval is essential. I know the OpenAPI half well, and that is where my work actually sat. I have not used Orval. It generates a typed client from the document, which is the consuming side of the thing I produce. So it is the part of the contract I already understand. But I have not used the tool, and I will not claim it. Second, the frontend stack itself. Vue, Nuxt, Pinia, VueUse, PrimeVue, Vite and Playwright. I have not worked in any of them. I can reason about what a generated client does to a consumer, and that is a different thing from having built the consumer. Third, the design documents never mention a frontend team, a generated client or a mock server. The mechanism is documented. The collaboration half is how I work, not something this project's record proves. Fourth, the schema diff gate is a proposal. Fifth, nothing records a specific breaking change that was caught, negotiated or shipped here. So I have no endpoint, no field and no date to give you. And there is no coverage figure either. The pipeline gates coverage on new code, and the honest statement is which paths are covered and why.

</details>

---

<span style="color:gray">*The posting lists experience in enterprise resource planning systems and the retail domain as an advantage. Every example above is from the cancer support platform. My retail-domain experience is on the previous project, a software marketplace, and not on this one. I have no enterprise resource planning experience to claim.*</span>
