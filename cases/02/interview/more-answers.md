# Supplied Questions — Answers by Topic

> Answers throughout are generated from the project briefs and system design documents in this case.
> Grouped by topic and tiered by difficulty.
> Weighted toward the client brief in `candidate-profile.txt`.

**Difficulty tiers.** `Q1` baseline — the foundational knowledge behind a stated responsibility. `Q2` deep dive — implementation detail, failure modes, the gotchas only someone who did the work has. `Q3` architectural — trade-offs, system-wide impact, what changes at scale. The tier follows the question that was asked, so not every topic carries all three.

## Questions by project

- **cancer-support-platform** — 1, 2, 3, 10, 12, 14, 16, 17, 18, 21, 25, 26, 27, 28, 29, 31, 32, 34, 35, 36, 37, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48
- **retail-software-marketplace** — 1, 3, 4, 9, 10, 11, 12, 14, 16, 17, 18, 19, 21, 24, 29, 30, 32, 34, 35, 36, 37, 38, 39, 40, 42, 46
- **general** — 5, 6, 7, 8, 13, 15, 20, 22, 23, 33

## Table of Contents

- [Service Boundaries and Event-Driven Consistency](#service-boundaries-and-event-driven-consistency)
- [Polyglot Persistence: Relational and Document Models](#polyglot-persistence-relational-and-document-models)
- [Transactions, Locking and Concurrency](#transactions-locking-and-concurrency)
- [Indexing and Query Performance](#indexing-and-query-performance)
- [Schema Evolution and Migrations](#schema-evolution-and-migrations)
- [API Design, Contracts and Retry Semantics](#api-design-contracts-and-retry-semantics)
- [FastAPI Runtime and Service Structure](#fastapi-runtime-and-service-structure)
- [Caching and Search Consistency](#caching-and-search-consistency)
- [RabbitMQ Operations and Topology](#rabbitmq-operations-and-topology)
- [Scaling and Load Management](#scaling-and-load-management)
- [Identity, Authorization and Tenant Isolation](#identity-authorization-and-tenant-isolation)
- [Container Images and Delivery](#container-images-and-delivery)
- [Security and Data Protection](#security-and-data-protection)
- [Distributed Data and Resilience Patterns](#distributed-data-and-resilience-patterns) *(generated)*
- [Entra ID, SCIM and Token Validation](#entra-id-scim-and-token-validation) *(generated)*

---

## Service Boundaries and Event-Driven Consistency

---

### 1. Tell me about best practices for handling missing events — how do you stop them, and how do you find out where one went?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
You stop them by never dual-writing: the event row commits in the same transaction as the state change, and a relay publishes it afterwards, so "the change happened but the event did not" is not a reachable state. You find a missing one by making every stage of the pipeline a counter you can query — unpublished outbox age, queue depth, dead-letter count, projection lag — plus a reconciliation job that compares source and projection and re-emits the difference.

<details>
<summary><strong>Detailed answer</strong></summary>

**The first rule is that the event must not be a second write.** The classic loss is a handler that commits to the database and then publishes to the broker: if the process dies between the two, the fact exists and the event does not, and nothing anywhere knows. Both systems in my recent work use a transactional outbox for exactly this. In the marketplace, `vendor-service` inserts `outbox_event` in the same [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") transaction that flips `product.current_revision_id`; a relay publishes to `sb-catalog-events` and stamps `published_at`. In the cancer platform the same pattern feeds `care.events`, and it is the only mechanism that writes to `es-clinical` or `sb-integration` — which is precisely why index drift cannot occur there.

**The second rule is that publishing successfully is not the same as being routed.** This is the one that bites people. [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") acknowledges a publish that matches no binding; the broker did its job, there was simply nowhere to put the message. A mistyped routing key, a binding lost in a redeploy, or a new tenant publishing on an unbound pattern therefore produces a confirmed publish and a discarded message. The fix is an **alternate exchange** on the topic exchange, which diverts unroutable publishes into a queue whose depth is a metric and an alert. That converts silent loss into visible backlog, which is the whole game.

**The third rule is at-least-once plus idempotency, never exactly-once.** Consumers acknowledge late — after their work commits — so a crash produces a redelivery rather than a gap. That makes duplicates normal, so every handler has to be idempotent, and the cheapest place to enforce that is the database: `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE` for check-ins, an upsert on `product_id` that ignores an event whose `source_revision_id` is older than the row's current value for the catalog projection. The second form also makes out-of-order delivery safe, which redelivery alone does not.

**Finding out where one went.** I want four numbers before I want a log:

1. `outbox_unpublished_age_seconds` — if this is rising, the relay is the problem and nothing downstream has seen anything.
2. Broker queue depth and unacknowledged count per queue — separates "nobody is consuming" from "the consumer is slow".
3. Dead-letter count per subscription, alerting on greater than zero. A message that failed its retries is *somewhere*, and the dead-letter queue is where you read the actual exception.
4. Projection lag measured as `occurred_at` → `projected_at` — in the marketplace that is `indexer_lag_seconds`, alerting at 60 s, because a dead indexer is otherwise completely silent: listings simply stop becoming searchable and no error is raised anywhere.

Those four localise the loss to a stage. After that, distributed tracing is what localises it to a message: `traceparent` propagates in message headers on every hop, so a single trace spans publish → project → invalidate → notify. Without that join a failure between a worker and a Function is two unconnected half-stories.

**And the backstop that assumes all of the above failed.** Both designs carry a reconciliation sweep: a nightly job that re-projects any `product` whose `projected_at` predates its `updated_at` by more than five minutes, and a document-count comparison per patient between `pg-clinical` and `es-clinical` that reindexes divergent patients. Monitoring tells you an event went missing; reconciliation is what makes the system self-heal without someone writing a one-off script at 2 a.m. I would treat a design with no reconciliation path as incomplete regardless of how good its alerting is.

</details>

---

### 2. In your recent work on the Cancer Support Platform, you transitioned from a FastAPI modular monolith to extracted microservices for SCIM and NLP; what specific technical criteria did you use to define the service boundaries, and how did you handle data consistency between these services using RabbitMQ?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Only two things left, and each left for a reason that survives scrutiny: `scim-provisioning-svc` because its release cadence belongs to the hospital directory rather than to us, and `clinical-nlp-svc` because it needs GPU hardware and ships on a model's schedule. Everything else stayed in `care-core` because at roughly 200 queries per second a distributed transaction across `diary` and `records` buys latency and on-call load for no throughput. Consistency is not two-phase commit — it is a transactional outbox publishing domain facts to the `care.events` topic exchange, with idempotent consumers and a natural key in PostgreSQL underneath.

<details>
<summary><strong>Detailed answer</strong></summary>

**The criteria, in the order I applied them.**

1. **Does it have an independent release driver?** Not "is it a different noun" — does something outside our team force it to ship on its own clock? System for Cross-domain Identity Management ([SCIM](https://scim.cloud/ "Standardizes automated provisioning and deprovisioning of user identities between systems")) provisioning does: the hospital's Azure Entra ID tenant changes its attribute mappings and its Groups behaviour on the directory team's schedule, and a directory change should not be blocked behind a patient-portal release, nor the reverse. The Natural Language Processing ([NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Computational techniques for analyzing and generating human language")) service does too: a model version is a release, and it needs a canary rollout with a quality comparison that makes no sense for a Create-Read-Update-Delete service.
2. **Does it need different hardware or a different runtime shape?** `clinical-nlp-svc` needs a GPU node pool. Putting a GPU `MachineSet` into the regulated primary cluster to serve one workload was the alternative, and the split is the most expensive decision in the design — which is why the design also records the condition that reverses it: if inference moves to a managed endpoint, `aks-ml` collapses back, and nothing stateful lives there to make that hard.
3. **Can it own its data, or would it have to share tables?** This is the criterion people skip, and it is the one that decides whether the extraction is real. `scim-provisioning-svc` writes the `identity` schema only — `clinician`, `care_team_member`, and the `care_relationship` rows a deprovisioning closes — and never touches `records`, `diary` or `content`. So the extraction is **deployment-level, not data-level**: it releases independently, but it cannot evolve those tables without regard for `care-core`. I would say that plainly in an interview rather than claim a cleaner boundary than exists, and the honest framing is that schema ownership is the constraint that keeps it from decaying.
4. **What did the split cost, and is the cost proportional?** Two deployables became four, with a cross-cluster hop that needs mutual Transport Layer Security (mTLS) and therefore a certificate authority we would not otherwise run. At 200 queries per second that cost is only justified by the two drivers above, and nothing else cleared the bar.

**The counter-example matters as much as the examples.** `records` is a separate module from `clinical-content` — a prescription and a leaflet do not belong behind the same code path — but it is not a separate service, because its consistency obligations are the same as `diary`'s and they share transactions. A module boundary that is enforced in code and in the database schema gets you most of the isolation without the distributed-systems tax. Extraction is a deployment decision, not a modelling one.

**Consistency across the boundary.** There is no distributed transaction anywhere and there should not be one.

- **Publish through an outbox.** A state change and its `outbox_event` row commit together; the relay publishes to the `care.events` topic exchange afterwards. Delivery is at-least-once, never zero-times.
- **Publish facts, not commands.** `checkin.recorded`, `visitnote.created`, `carerelationship.changed`. A topic exchange means the publisher does not know who reacts, so adding the third consumer does not require redeploying the module that owns the clinical record.
- **Make redelivery arithmetic.** Every consumer is idempotent against a natural key in `pg-clinical`, not against an application-side "have I seen this" set that can itself be lost. [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency keys exist, but they are explicitly the optimisation, not the guarantee.
- **Make the messages durable.** Quorum queues across the three-node `rmq-core` cluster with mandatory publisher confirms. Without confirms, `publish()` returns when the frame hits the socket, which says nothing about replication; with them, a confirmed publish has been accepted by a majority.
- **Keep the state machine in the database, not in the queue.** Reminders stay `pending` in PostgreSQL and are re-swept; a broker or Function outage makes them late, not lost. This is the property that lets me say "eventually consistent" without it meaning "eventually, possibly".

The one place I would push back on the premise: the direction was never "monolith → microservices" as a programme. Two services left, for two named reasons, and the design records what would bring one of them back.

</details>

---

## Polyglot Persistence: Relational and Document Models

---

### 3. How do you decide what belongs in a relational schema and what belongs in a document — and what does that split cost you once both stores hold part of the same entity?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Relational for anything with referential integrity, a fixed shape, or a role in a transaction; document for anything whose shape the platform cannot fix in advance without blocking the next use case. The split costs you a projection pipeline, a lag budget, a reconciliation job, and a second place to get authorization wrong — and you should only pay that when a single store genuinely cannot serve both halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I actually apply** is not "structured versus unstructured". It is three questions: does this data participate in a foreign key or a transaction that must be atomic; do I need to query it by predicates I can enumerate today; and would adding a new variant require a migration. If the answers are yes, yes, no — it is relational. If they are no, no, yes — it is a document.

In the marketplace that produced a deliberate split down the middle of one entity, which is the interesting case. A listing has a **spine** — identity, vendor ownership, category, status, publication timestamp, price tiers — which has referential integrity to vendors, participates in shortlists and connections, and is what search and the admin workspace query. That is relational, in `postgres-core`. It has a **body** — everything specific to being a Point of Sale ([POS](https://en.wikipedia.org/wiki/Point_of_sale "The system and moment at which a retail transaction is completed")) system, an inventory tool or a loyalty engine — which has no schema the platform can fix without blocking whichever category ships next. That is a document in `mongo-catalog`, validated at write time against a per-category `facet_schemas` document rather than a table definition. The validation matters: "no fixed column set" must not degrade into "no contract", and [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") checking the submitted attributes against the category schema is what keeps it governable. Adding a category becomes a document insert plus a facet mapping, not a migration.

The cancer platform drew the same line differently because the data was different: education pages vary by cancer type, treatment line and locale and are versioned with a review state, so they live in `mongo-content`; the clinical record is relational because a prescription has referential integrity and an authorization boundary. Symptom scores went to `jsonb` inside PostgreSQL rather than to Mongo — the symptom set differs by cancer type and evolves with the protocol, but it is read in the same query as the row it belongs to, so a Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) on the document was the right answer rather than a second store.

**What the split costs, stated honestly, because this is the half of the question people skip.**

- **A projection.** Anything a user filters on has to be queryable relationally, so a worker copies the facetable subset of the Mongo document into `product_listing_facets` in Postgres. That table is a denormalised read model written only by `indexer-worker` and read only by `catalog-service`.
- **A lag, and therefore a lag budget and an alert.** The projection trails the document by seconds — p95 under 5 s — and when the indexer dies, listings silently stop becoming searchable. That failure has no error to raise, so it needs its own metric.
- **A reconciliation job.** A nightly sweep re-projects any product whose `projected_at` predates its `updated_at`, and deletes revision documents that no product row points at. Without it, one lost event is permanent.
- **A write-ordering rule.** Mongo first, Postgres commit second. An orphaned revision document that nothing points at is invisible garbage; a committed pointer to a document that does not exist is a broken listing.
- **A second authorization surface.** Every store that can answer a query can become the path around your access control. That is why the search index in the cancer platform carries mandatory scope fields on every document.

**And the alternative I would not dismiss.** Everything in PostgreSQL with `jsonb` for the metadata is genuinely defensible at this size, and I would say so rather than pretend the polyglot choice was obvious. It trades the projection lag for heavier write amplification on the same table that serves search. The reason to take the split here is the vendor-facing authoring surface — per-category schema validation, immutable document revisions, staged imports — which is Mongo's native shape. If that surface did not exist, one store would be the better answer.

</details>

---

### 4. While building the Retail Software Aggregation Platform, you used MongoDB for product metadata to handle variable schemas for POS and inventory tools; how did you manage the integration and query performance when the system needed to join this unstructured metadata with relational vendor data stored in PostgreSQL?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
There is no join, and designing so there never has to be one is the whole answer. The hot query runs against a single denormalised PostgreSQL table that a worker projects the facetable subset of the Mongo document into; the document is fetched afterwards, in one bulk `$in` by primary key, only for the products already on the page.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism, in the order a request hits it.**

1. **One relation for the search query.** `product_listing_facets` carries `vendor_id`, `category_slug`, `status`, `published_at`, `country_coverage`, `deployment_model`, `price_from_minor`, `integrations`, a `facets jsonb` column and a `search_vector`. `vendor_id`, `status` and `published_at` are copied from `product` *deliberately*, so the highest-traffic query in the system touches exactly one relation and never joins even within PostgreSQL. It is written only by `indexer-worker` and read only by `catalog-service`, which is what keeps a denormalised table from becoming a correctness problem.
2. **Indexes per access pattern, not per column.** `GIN (search_vector)` for free text; `GIN (facets jsonb_path_ops)` for arbitrary category-specific predicates; `GIN` on the `country_coverage` and `integrations` arrays for containment; and two partial B-trees — `(category_slug, published_at DESC, product_id) WHERE status = 'published'` for the default browse order and `(category_slug, price_from_minor)` for the price sort. The partial predicate keeps roughly 15,000 unpublished and archived rows out of the hot index entirely and removes the status filter from every plan.
3. **Hydration by primary key, in bulk, after the page is decided.** `product_metadata._id` **is** `product.id`, so the two stores join without a mapping table. The page returns about thirty product ids; Redis serves the ones it has as `cat:listing:{id}:v{rev}`, and the misses go to Mongo as a single `find({_id: {$in: [...]}})`. Never per-item — a loop of thirty round trips is how this design would have failed.

**The performance consequence, decomposed.** The uncached path budgets about 45 ms for the keyset query on the projection, about 25 ms for the bulk Mongo hydration and about 14 ms for serialisation, landing near 107 ms server-side against a p95 target of 200 ms. At the modelled 85% hit ratio on the search-page cache, the p95 falls on that uncached path with roughly 90 ms of headroom for a cold buffer cache or an autoscaling cold start.

**Where it actually gets hard, and what I would say honestly.** The defining performance risk is not the cross-store fetch — it is the planner on the projection table. A comparison workflow produces queries with many optional predicates, and the failure mode is a bitmap `OR` across several GIN indexes on an unselective combination degrading toward a sequential scan as the table grows. Selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor for high-cardinality arrays, so the claim that those indexes combine into a bitmap `AND` is exactly the kind of thing I would confirm with `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table on the pinned minor version before quoting a latency figure. If the plan is wrong, the fix is a composite covering index per high-traffic category, not a bigger instance.

Two product constraints buy guarantees the query planner cannot: the [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") refuses an uncategorised query carrying more than two facet predicates, which guarantees a viable leading index; and the response returns `total_estimate` capped at 1,000 rather than an exact count, because an exact count over a filtered GIN scan costs as much as the page itself. Both are cases where a small product decision removes a class of performance problem, and I would rather argue for one of those than tune around the consequence.

**The cost of the design.** The projection trails by seconds, so a vendor who just clicked publish would see stale data. That is routed around rather than shrunk: the vendor workspace reads `product` from the Postgres primary and the metadata document from Mongo directly, never the projection and never the cache, so vendors get read-your-writes and retailers get the fast, slightly-stale read model.

</details>

---

### 5. This vacancy involves working with InterSystems IRIS, which supports both relational and document data models; given your experience with both PostgreSQL and MongoDB, how would you approach designing a data access layer in Python that effectively bridges these two different storage paradigms?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
I have not worked with InterSystems [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage"), so I would answer this from the two-store version of the same problem, which I have built twice. The design principle transfers directly: the access layer exposes one repository per aggregate returning typed domain objects, and which paradigm serves a given field is an implementation detail behind that boundary — with the important difference that on a single engine, the two halves can share a transaction, which removes the projection pipeline and the reconciliation job that the two-store version has to pay for.

<details>
<summary><strong>Detailed answer</strong></summary>

**Being straight about what I have and have not done.** My experience is PostgreSQL plus [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") as separate engines, and PostgreSQL `jsonb` as a document model inside a relational one. IRIS's model — where the same data is reachable as objects, as relational tables and as globals over one storage engine — is adjacent to the second of those rather than the first, and I would expect the first week to be spent learning where its abstractions leak rather than assuming my Postgres intuitions hold.

**What transfers, and I would argue it transfers strongly.**

*One repository per aggregate, not one per table.* Callers ask `ProductRepository.get(product_id)` and receive a typed Pydantic or dataclass object. Whether the price tiers came from a relational table and the free-form attributes from a document is not the caller's business. This is the boundary that makes the storage decision reversible; without it, the paradigm split leaks into every endpoint and you can never change it.

*A validated schema on the schemaless half.* The mistake with any document model is letting "no fixed columns" mean "no contract". In the marketplace, vendor-supplied attributes are validated at write time against a per-category schema document, so the store is flexible and the data is still governable. On IRIS I would do the same thing: the storage engine's permissiveness is not an excuse to skip the application-level schema, and the per-category schema is a document, so adding a category stays a data change rather than a migration.

*Filterable attributes are the seam.* Anything a user filters or sorts on has to be reachable by an index. In the two-store design that forced a projection table; on a single engine it should instead be a typed, indexed property alongside the flexible ones. I would expect the real design conversation on IRIS to be exactly this — which attributes get promoted to indexed properties and which stay in the flexible body — and the answer comes from the query list, not from the data's shape.

*Migrations stay explicit.* Even where the engine does not force one, I want a versioned migration history for the relational half and an explicit `schema_version` on documents, with the read path able to handle the previous version. Lazy migrate-on-read versus a backfill job is a decision to make per change, and pretending a schemaless store means no migrations just moves the migration into unowned runtime code.

**What I would expect to be genuinely different, and would check rather than assume.**

- **Transactions across both halves.** On one engine this should be a single transaction, which deletes the outbox, the projection lag and the reconciliation sweep. That is a real simplification and the main reason to prefer the single-engine model — but I would verify the isolation semantics across the object and relational access paths before relying on it, because "same engine" does not automatically mean "same isolation guarantees through every access path".
- **Which driver, and what it costs.** Whether the Python layer goes through a Database API (DB-API) driver, an object binding, or both, decides whether [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") is usable and therefore whether the repository layer looks familiar. On a non-mainstream database I would expect the Object-Relational Mapping ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) dialect support to be the constraint that shapes the code, and I would want to know early whether the hot queries must be hand-written Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Queries and manipulates data in a relational database")).
- **Plan behaviour on large tables.** The brief mentions tables above 100 million rows. Every instinct I have about index selection and partition pruning comes from PostgreSQL's planner, and the only honest way to carry that across is to read this engine's execution plans against realistic data rather than assume the shape is the same.

**The one thing I would refuse to do.** Write an abstraction that pretends the two paradigms are one. A repository interface that hides the storage decision is worth having; a generic "store anything" layer that makes a relational query and a document query look identical produces code where nobody can tell which one they wrote, and the performance cliff arrives without warning. The layer should be thin, typed, and honest about which half it is touching.

</details>

---

## Transactions, Locking and Concurrency

---

### 6. Tell me about transactions: the isolation levels, what each one actually prevents, and where a transaction stops being enough.

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
Read Committed prevents dirty reads, Repeatable Read additionally prevents non-repeatable reads and — in PostgreSQL — phantoms, and Serializable prevents the remaining write-skew anomalies by aborting one of the conflicting transactions. A transaction stops being enough the moment the operation crosses a boundary the database does not control: a second store, a broker, an external provider, or a user's think-time.

<details>
<summary><strong>Detailed answer</strong></summary>

**The levels and the anomalies, concretely.**

- **Read Uncommitted** — permits dirty reads in the standard. PostgreSQL does not implement it as distinct; it behaves as Read Committed.
- **Read Committed** (the PostgreSQL default). Each *statement* sees a snapshot taken when that statement began. No dirty reads. Two reads in the same transaction can return different values, and a `SELECT` followed by an `UPDATE` can act on data that changed in between. The subtle one: under Read Committed an `UPDATE` that finds a row locked will re-evaluate its `WHERE` clause against the new version after the lock is released, which can silently change which rows are affected.
- **Repeatable Read.** One snapshot for the whole transaction. No dirty reads, no non-repeatable reads, and in PostgreSQL's Multi-Version Concurrency Control ([MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row")) implementation no phantoms either — which is stronger than the standard requires. The price is `could not serialize access due to concurrent update`, so the application must be prepared to retry.
- **Serializable.** Snapshot isolation plus predicate-dependency tracking, which catches write skew — two transactions each reading what the other is about to change and both committing a state neither would have allowed. The canonical case is two people booking the last slot after both checked availability. The cost is more serialization failures and therefore a mandatory retry loop.

**The practical position I take.** Read Committed for almost everything, with correctness carried by constraints and explicit locking rather than by the isolation level, because a constraint is declarative and always on, whereas an isolation level is a setting someone can change. Serializable where the invariant genuinely spans rows that no single unique constraint can express — and then with a retry loop, because a Serializable transaction that cannot retry is a transaction that fails under load.

**Where a transaction stops being enough — four boundaries.**

1. **A second datastore.** No transaction spans PostgreSQL and MongoDB, or PostgreSQL and a message broker. This is why both my recent systems use a transactional outbox: the event row commits with the state change, and publication happens afterwards with at-least-once delivery and idempotent consumers. Reaching for a distributed transaction here would buy a coordinator, a new failure mode and worse latency to avoid writing an idempotent handler.
2. **Any external side effect.** Sending an email, charging a card, calling a provider. The database can roll back; the provider cannot. The pattern is a state machine in the database with an attempt row per try — one reminder, many `reminder_delivery` rows each with a channel, a provider message id and a terminal state — so "was it delivered" is a query rather than a log grep, and a retry is safe because the attempt is recorded before it is made.
3. **Anything spanning user think-time.** Holding a transaction open across a user's decision is how you get a frozen table. The answer is optimistic concurrency — a version or revision column checked on write — not a long-lived lock.
4. **Long-running work.** A transaction held open for a large batch pins the oldest snapshot, which blocks vacuum and lets dead tuples accumulate across the whole database. Batch work gets chunked into many short transactions, which is also what makes it resumable.

**And the thing I would add unprompted:** the strongest correctness tools in a relational database are not isolation levels at all, they are constraints. `UNIQUE (retail_group_id, idempotency_key)` is what finally prevents a duplicate connection thread and a duplicate charge, not the retry logic in front of it. `UNIQUE (connection_request_id) WHERE kind = 'connection'` is what makes "a connection bills at most once" a property of the schema rather than a property of everyone remembering. Isolation levels manage contention; constraints decide what states are possible.

</details>

---

### 7. A table is frozen — how do you debug the blocking transaction, and what do you put in place so it does not happen again?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Query the live lock graph — in PostgreSQL, `pg_stat_activity` joined to `pg_locks`, or `pg_blocking_pids()` on the waiter — to get from the victim to the actual blocker, then look at what that blocker is doing and, more importantly, whether it is doing anything at all. Prevention is mostly three settings and one discipline: statement and idle-in-transaction timeouts, `NOWAIT` or `SKIP LOCKED` on contended claim queries, and never holding a transaction open across work the database is not doing.

<details>
<summary><strong>Detailed answer</strong></summary>

**Getting to the blocker.** The waiter is easy to find and useless on its own. What I want is the chain:

- `SELECT pid, state, wait_event_type, wait_event, query, xact_start, state_change, pg_blocking_pids(pid) FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;` gives every waiter and who is holding it up. Follow the chain to the root — the blocker is frequently not itself blocked, which is what makes it the culprit.
- Then look at the root's `state`. If it is `idle in transaction`, the database is not the problem: the application opened a transaction and went off to do something else — an Application Programming Interface (API) call, a file read, a user's think-time — and the lock is collateral. That is the most common cause I have seen, and it is an application bug, not a database one.
- `pg_locks` filtered on the relation tells you *which* lock mode is held, which distinguishes a row-level write conflict from a table-level `ACCESS EXCLUSIVE` — the latter is almost always a migration, and it is worth checking `pg_stat_activity` for an `ALTER TABLE` before assuming application traffic.
- `xact_start` versus `query_start` is the tell for a long transaction running many short statements, which is a different problem from one long statement.

**The migration case deserves its own note**, because it is the one that freezes a table completely rather than merely slowing it. An `ALTER TABLE` that needs `ACCESS EXCLUSIVE` queues behind existing readers, and every subsequent query queues behind *it* — so one slow `SELECT` plus one `ALTER` stalls the whole table. That is why `lock_timeout` on migration sessions matters more than `statement_timeout`: better to fail the migration and retry than to build a queue.

**Resolution, in order.** Cancel first (`pg_cancel_backend`), terminate only if cancelling does not work (`pg_terminate_backend`), and — this is the part people skip — record what it was before killing it, because otherwise you have lost the evidence and will do this again next week.

**What I put in place afterwards.**

- **`idle_in_transaction_session_timeout`** at the database or role level. This single setting converts the most common cause from an outage into an error in one connection. There is no legitimate reason for an application transaction to sit idle for minutes.
- **`statement_timeout`** per role, tuned differently for the web tier and for background jobs. A web request that has run for thirty seconds is not going to produce a useful response.
- **`lock_timeout`** on the migration path specifically, so schema changes fail fast rather than queueing.
- **`SELECT ... FOR UPDATE SKIP LOCKED`** for any claim-a-row-of-work pattern. In the reminder sweep this is what lets workers scale without double-dispatch *and* without blocking each other — two workers never contend for the same row, they simply take different ones.
- **Short transactions as a rule, enforced by the session dependency.** The session opens as late as possible and closes at the end of the request, and nothing that is not a database operation happens inside it. No Hypertext Transfer Protocol ([HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Application protocol used to request and transfer web resources")) calls inside a transaction, ever.
- **Optimistic concurrency instead of pessimistic locks** wherever the conflict is rare — a revision column checked on write, which in the marketplace is `current_revision_id` and in the projection is an ignore-if-older comparison on `source_revision_id`.
- **Monitoring on the leading indicator**, not the outcome: longest-running transaction age, count of sessions idle in transaction, and lock-wait count. A dashboard that only shows query latency tells you about this after users do.

**The honest caveat.** All of the above assumes the blocker is a transaction. If the table is "frozen" and the lock graph is empty, the problem is somewhere else — connection-pool exhaustion presenting as a hang, a saturated replica, or a client-side deadlock in the application's own pool — and I would check the pool's checked-out count before spending longer in `pg_locks`. Treating "no output" as "investigate the process table" rather than "it is just slow" applies to the database layer as much as anywhere.

</details>

---

### 8. Tell me about deadlocks in a database — how they arise, how you diagnose one after the fact, and how you design them out.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
A deadlock is a cycle: two transactions each hold a lock the other needs, so neither can proceed and the database breaks the tie by aborting one. They arise almost entirely from inconsistent lock ordering, and the durable fix is to make every transaction acquire locks in the same deterministic order — plus keeping transactions short enough that the window barely exists.

<details>
<summary><strong>Detailed answer</strong></summary>

**How they arise.** The textbook case is two transactions updating the same two rows in opposite orders. In practice the ordering is rarely explicit — it is implied by a loop over a set that nobody sorted, by a foreign key taking a lock on a parent row, by an index update, or by an `UPDATE ... WHERE` whose row order the planner chose. The three shapes I have actually seen:

1. **Unordered batch updates.** Two workers processing overlapping id sets in whatever order they arrived. This is the common one, and sorting the batch by primary key eliminates it outright.
2. **Foreign-key lock escalation.** Inserting a child row takes a share lock on the parent; two transactions inserting children of two parents while also updating those parents deadlock without any obviously conflicting statement.
3. **Upsert races.** Two concurrent `INSERT ... ON CONFLICT` on overlapping keys, which is the pattern any idempotent consumer uses. This one matters because it is the shape of a message-driven projection, and duplicate delivery makes it *likely* rather than theoretical.

**Diagnosing after the fact.** A deadlock is never live by the time you look — the database already resolved it. So the evidence is in the log, and the prerequisite is having turned the log on: `log_lock_waits = on` and `deadlock_timeout` at a value that is a real threshold rather than an accident. PostgreSQL's deadlock report gives both processes, the statements each was running, and which lock each was waiting on. That is usually enough to reconstruct the cycle.

What I want beyond the log line: the application's `trace_id` in the statement context, so I can get from the two statements back to the two requests and see what the code paths were. Logging the statement alone tells you the collision point but not the intent, and the intent is where the fix lives. In both my recent systems every log line carries `trace_id` and `request_id`, and correlating a deadlock report to two traces is exactly the kind of thing that join is for.

I also want the **rate**. One deadlock a week on a retryable path is noise; a rising rate is a design problem, and it usually appears right after a concurrency increase — more workers, a bigger batch size, a new consumer on the same queue.

**Designing them out.**

- **Deterministic lock ordering.** Sort every batch by the primary key before touching rows. This is one line of code and removes the largest single cause.
- **Short transactions, narrow scope.** Fewer locks held for less time. A transaction that does a database read, an HTTP call and then a write has a window orders of magnitude wider than it needs, and the HTTP call should be outside it.
- **`SKIP LOCKED` for work claiming.** Two workers claiming reminders never contend at all — they take different rows. Designing contention away beats resolving it.
- **Idempotent upserts on a natural key**, so the correct response to a serialization failure or a deadlock abort is simply to retry, with no compensating logic.
- **A bounded retry with jitter on the retryable error classes** — deadlock detected, serialization failure. Immediate retry without jitter recreates the collision; that is the detail people miss.
- **Consider row-level advisory locks** where the contention is over a logical resource rather than a row, such as serialising SCIM operations per directory object. That is what the `lock:scim:{entra_object_id}` key does in the cancer platform, keeping concurrent directory updates for one clinician from interleaving at all.

**The trade-off worth naming.** Every one of these makes concurrency lower or code slightly more constrained. Sorting a batch costs nothing; holding an advisory lock per aggregate serialises work that could in principle run in parallel. I would take the serialisation for a low-frequency operation like provisioning and refuse it for a high-frequency one, where the right answer is to redesign so the two transactions do not touch the same rows.

</details>

---

### 9. Nothing changed in the code, there was no deployment and no traffic spike, but lag suddenly appeared. How do you debug this, and where do you look first?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
"Nothing changed" almost always means nothing changed *in the things we deploy* — so I look first at the things that change themselves: data volume crossing a planner threshold, a background maintenance job, a partition boundary, a certificate or credential rotation, a managed-service failover, and an upstream provider. The first number I pull is which lag it is, because replica lag, projection lag, queue lag and cache-miss latency have entirely different causes and only one of them is a database problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one is refusing to accept the word "lag" undefined.** In the marketplace there are at least four distinct numbers that a user would describe the same way, and each has its own alert: `postgres_replica_lag_seconds`, `indexer_lag_seconds` (event `occurred_at` → row `projected_at`), `outbox_unpublished_age_seconds`, and `celery_queue_depth` per queue. Knowing which one moved localises the problem before any hypothesis is formed. If none of them moved and users still see staleness, the problem is in the cache layer or the client, not the pipeline.

**Then the categories of thing that change without a deploy, in the order I check them.**

1. **Data crossing a threshold.** This is the most common cause of an overnight change with no deploy. A table grows past the point where the planner's estimate flips a nested loop into a hash join, or an index stops fitting in the buffer cache, and a query that was 40 ms becomes 4 s. Stale statistics do the same thing: autovacuum falls behind on a write-heavy table, estimates drift from reality, and the plan degrades. The check is `EXPLAIN (ANALYZE, BUFFERS)` on the slow query and a comparison of estimated against actual rows — a three-orders-of-magnitude divergence is a statistics problem, and `ANALYZE` is the immediate test.
2. **Autovacuum itself.** A long-running transaction somewhere is pinning the oldest snapshot, so vacuum cannot reclaim dead tuples across the whole database. Table bloat rises, scans read more pages for the same rows, and everything gets slower with no change anywhere. `pg_stat_activity` ordered by `xact_start` finds it in one query, and this is the case where the cause and the symptom are in different services entirely.
3. **A time-driven job.** A monthly partition boundary, a nightly reconciliation sweep, a retention detach, a backup window, a [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") expiry wave in Mongo. These are in the design and they are still surprising at 03:00 because nobody correlates them by default. Worth putting the schedule on the same dashboard as the lag.
4. **The managed service moved.** A Flexible Server maintenance failover, a replica rebuild, a Redis node swap. Failover is 60–120 s of failed writes by design, but the after-effects are longer: a cold buffer cache on the new primary, a reconnect storm, and a replica that has to catch up. The platform's activity log answers this and it is not somewhere application engineers instinctively look.
5. **A credential or certificate rotation.** Key rotation with an overlap window that turned out to be shorter than a cache's refresh interval produces intermittent failures that look like latency because of the retries in front of them. In the marketplace the specific known trap is the gateway's [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")) cache refreshing on a different schedule from the application's, so during a signing-key rotation the two can disagree.
6. **Upstream.** A third-party provider slowing down turns into queue depth on our side. If the queue that is backing up is the dispatch queue, the problem is probably not ours at all.
7. **A noisy neighbour on shared infrastructure** — one tenant's bulk import occupying the worker pool, which is the specific failure the per-vendor concurrency cap exists to prevent, and worth confirming rather than assuming the cap held.

**What I would not do.** Start by reading recent commits. The premise says there were none, and the single biggest waste of an incident hour is refusing to believe the premise. I would also not restart anything before capturing the lock graph, the running queries and the plan — a restart usually clears the symptom and destroys the evidence, and then it recurs.

**What I would put in place afterwards.** If this was a silent degradation, the gap is not the fix, it is the detection. `indexer_lag_seconds` alerting at 60 s exists precisely because a dead indexer raises no error — new listings simply stop becoming searchable. Every derived or projected view needs a freshness metric with an alert, because the failure mode of a projection is silence. And the deployment timeline, the maintenance-event feed and the scheduled-job calendar belong on the same dashboard as the latency graph, so "did anything change" is a glance rather than an investigation.

</details>

---

## Indexing and Query Performance

---

### 10. How do you design the indexes for a table — do you start from the schema or from the queries, and what do you do when the planner declines the index you added?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
From the queries, always — an index with no named access pattern behind it is write amplification, and on a 110-million-row table that is expensive amplification. When the planner declines an index, it is usually telling the truth: either the predicate does not match the index's leading columns, or the index is not selective enough to beat a sequential scan, or the statistics are wrong. I read the plan before I argue with it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Queries first, and I mean that literally as a document.** In both designs the index list is derived from an enumerated table of access patterns — the endpoint, its frequency, and the index that serves it. Browse a category newest-first; the same sorted by entry price; free text over name and vendor; filter by country coverage; a group's shortlists; a thread's messages newest-first; unpublished outbox rows. Each row of that table names one index, and any index that does not appear in it gets deleted. That discipline is what keeps the write path affordable: every index is a write cost on every insert and a maintenance cost on every update.

**Choosing the type from the predicate, not from habit.**

- **Composite B-tree** for ordered access — `(patient_id, timeline_at DESC)` on every timeline-feeding table, `(category_slug, published_at DESC, product_id)` for browse. Column order follows equality-then-range-then-sort, and it is what makes keyset pagination cheap.
- **Partial** wherever a status predicate is always present. `WHERE status = 'published'` keeps roughly 15,000 rows out of a 55,000-row index and removes the filter from every plan; `WHERE published_at IS NULL` keeps the outbox relay's index to the tiny unpublished set rather than all history; `WHERE state = 'pending'` does the same for due reminders. Partial indexes are the highest-leverage and most under-used option here.
- **GIN** for containment and full text — `jsonb_path_ops` for category-specific attributes, arrays for integrations and country coverage, `tsvector` for free text.
- **Block Range Index ([BRIN](https://www.postgresql.org/docs/current/brin.html "Compact PostgreSQL index type suited to large, sequentially correlated tables"))** on the time column of an append-only partitioned table. Physical order matches insert order, so it costs a fraction of a B-tree's size for the same range scan on a 1.8-billion-row audit table.
- **Generalized Search Tree ([GiST](https://www.postgresql.org/docs/current/gist.html "PostgreSQL index type supporting range and exclusion constraints"))** where the predicate is a range overlap — the temporal `care_relationship` exclusion constraint is the index that answers "may this clinician see this patient", so the constraint and the index are the same object.
- **Time-to-live (TTL)** in Mongo for staging data that must expire without a job.

**Partitioning before indexing on the big tables.** Monthly range partitioning on the check-in and audit tables means partition pruning removes almost all of the table from every query before any index is consulted, and detaching an old partition is a metadata operation rather than a 500 GB `DELETE`. An index cannot rescue a query that scans five years when it needs one month.

**When the planner declines the index.** I go through this in order, and the first step is always to look rather than to force.

1. **Read `EXPLAIN (ANALYZE, BUFFERS)`.** Not `EXPLAIN` — the estimate alone is what led to the problem.
2. **Check the predicate actually matches.** A function applied to the column, an implicit cast, a `LIKE '%x'` leading wildcard, or a leading column missing from the `WHERE` clause all make an index unusable. This is the cause more often than anything clever.
3. **Compare estimated to actual rows.** A large divergence means statistics, not indexing. `ANALYZE`, then raise `default_statistics_target` on the column or add extended statistics for correlated columns. Adding another index on top of a bad estimate just gives the planner a new way to be wrong.
4. **Accept that it may be right.** If the index returns a large fraction of the table, a sequential scan genuinely is cheaper, and the answer is a more selective query or a partial index carrying the selective predicate — not a hint.
5. **Check whether it is a bitmap combination problem.** Several GIN indexes over an unselective combination can degrade toward a scan, and the selectivity estimates for high-cardinality array containment are poor. If that is the shape, the fix is a composite covering index for the high-traffic case, not a bigger instance.
6. **Only then consider forcing.** `SET enable_seqscan = off` is a diagnostic to confirm the hypothesis, never a deployed setting.

**One design note that is really an indexing decision.** The timeline query unions five tables, and every one of them carries a normalised `timeline_at` column populated from its own natural column. That exists so all five can be served by the same composite index shape and ordered deterministically by one keyset cursor. Without it, each branch would sort on a different column of a different type and no index would serve the union. That is the pattern I would generalise: sometimes the right index change is a schema change that makes one index possible.

</details>

---

### 11. Walk me through an `EXPLAIN (ANALYZE, BUFFERS)` output. What tells you the plan is wrong rather than merely slow, and what do you do when estimated and actual rows disagree by three orders of magnitude?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Read it inside out, and compare `rows=` estimated against `rows=` actual at every node — a plan that is merely slow has accurate estimates and expensive work; a plan that is *wrong* has estimates that are off, which means the planner chose a join strategy and an access method for a row count that does not exist. A three-orders-of-magnitude divergence is a statistics problem first and a query-shape problem second, and I would run `ANALYZE` before touching anything else.

<details>
<summary><strong>Detailed answer</strong></summary>

**How I read it.** Execution is depth-first from the innermost node outward, so I start at the leaves. For each node I want four things:

- **`rows=N` (estimated) versus `rows=N` (actual) and `loops=`.** Actual rows are per loop, so a node showing 10 rows with `loops=5000` did 50,000 rows of work. Missing that is the single most common misreading.
- **`actual time=start..end`.** The gap between a node's total and the sum of its children is that node's own cost. A node whose children are fast and which is itself slow is where the time went.
- **`Buffers: shared hit=` versus `read=`.** `hit` is the buffer cache, `read` is the storage layer. High `read` on a query that should be hot means the working set does not fit, which is a capacity answer rather than an indexing one. `BUFFERS` is also how you tell two plans apart when wall-clock time is polluted by cache warmth — the same query run twice looks faster the second time for reasons that have nothing to do with the plan.
- **`Rows Removed by Filter`.** A large number here means the index brought back rows the predicate then discarded — the index is not carrying the selective condition, which is usually an argument for a partial or composite index.

**What tells me the plan is wrong rather than slow.**

- **Estimates diverging from actuals**, especially at a leaf. Everything above a bad estimate is a decision made on a false premise.
- **A nested loop with a large actual outer row count.** A nested loop is the right choice for a handful of outer rows; at 100,000 it is a disaster, and it is the classic symptom of an underestimate.
- **A sequential scan on a large table where a selective predicate exists.** Either the index does not match the predicate or the planner thinks the predicate is not selective.
- **A sort or hash spilling to disk** — `Sort Method: external merge Disk: ...`. That is a `work_mem` answer, and it is often one setting rather than a query rewrite.
- **A bitmap heap scan with `lossy=` blocks**, meaning `work_mem` was too small to hold exact tuple ids so it fell back to whole blocks and then rechecked. Also a memory answer.
- **A materialised subquery or [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement") where the planner could not push the predicate down.** Older PostgreSQL versions fenced CTEs unconditionally; recent ones inline them unless the CTE is referenced more than once or marked `MATERIALIZED`, and it is worth knowing which behaviour you are on.

By contrast, a plan that is merely slow looks *right*: the estimates track, the access methods are the ones you would have chosen, and it is simply reading a lot of pages. That is a data-volume or a product-requirement conversation, not a tuning one.

**Three orders of magnitude, in order.**

1. **`ANALYZE` the table and re-run.** Stale statistics after a bulk load or an import are the cause more often than anything else, and this is thirty seconds of work.
2. **Raise `default_statistics_target` for the column** if the distribution is skewed. The default histogram is coarse, and a column with a long tail — a category slug where one category holds most rows — is exactly where it fails.
3. **Add extended statistics** (`CREATE STATISTICS`) when the divergence comes from *correlated* columns. The planner multiplies selectivities assuming independence; `category_slug` and `deployment_model` are not independent, and multiplying their selectivities produces an estimate orders of magnitude too low. This is the fix that people most often do not know exists.
4. **Look for estimation blind spots the planner genuinely has.** Array containment on `text[]` and `jsonb_path_ops` on high-cardinality documents both estimate poorly, and no amount of `ANALYZE` fixes that. If the query's shape is inherently unestimable, the answer is to remove the need for the estimate — a composite covering index for the high-traffic case, or a product constraint that guarantees a selective leading predicate. In the marketplace the API refuses an uncategorised query carrying more than two facet predicates for exactly this reason: it guarantees a viable leading index rather than hoping for one.
5. **Check for a function or cast wrapping the column**, which makes the statistics inapplicable regardless of how fresh they are.

**The discipline around all of this.** A plan read on a laptop against a seeded table is not evidence about production — different data volume, different distribution, different `work_mem`, possibly a different minor version. Before I would quote a latency figure I would run the plan against a realistically-sized dataset on the pinned version. And when I change something, I change one thing and confirm the change took, because two simultaneous changes produce a clean but uninterpretable result.

</details>

---

### 12. A list endpoint is paginated and the deep pages are getting slower. What is actually happening, and what do you tell the stakeholder who wants a jump-to-page control?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
`OFFSET n` does not skip rows cheaply — the database produces all `n` rows in order and throws them away, so page 400 costs roughly 400 times page 1. The fix is keyset pagination: carry the last row's sort key as a cursor and use it as a `WHERE` predicate, so every page costs the same. The honest answer to the jump-to-page request is that a numbered pager and a cheap deep page are mutually exclusive, and then offering what the stakeholder actually wants.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** `LIMIT 20 OFFSET 8000` asks the database for 8,020 rows in sort order and discards 8,000. The work is linear in the offset, it is done on every request, and there is no index that changes it — the index gets you the order, not the skip. It gets worse under concurrent writes: a row inserted between two requests shifts everything, so a user paging forward sees a duplicate and a user paging back misses a row. That correctness bug is the one nobody reports, because it looks like a refresh.

**The fix.** Keyset, also called cursor or seek pagination. The cursor is the sort key of the last row on the page, and the next query is `WHERE (published_at, product_id) < (:cursor_ts, :cursor_id) ORDER BY published_at DESC, product_id DESC LIMIT 20`, served by the same composite index as page 1. Page 400 costs exactly what page 1 costs, and a concurrent insert cannot shift the window because the position is a value, not a count.

Two details that make it actually work:

- **The cursor must be a unique tuple.** A timestamp alone is not unique, so ties either duplicate or drop rows. That is why the tuple carries the primary key as a tiebreaker, and why the composite index has the same shape. In the cancer platform the timeline unions five source tables, so the cursor is `(timeline_at, source_table, id)` — the third component exists because ties across sources must break deterministically, and `timeline_at` itself is a normalised column added to every source table for exactly this reason.
- **The cursor should be opaque.** Encode it, do not expose raw column values that clients will start constructing by hand and that then become a contract you cannot change.

Both these designs use keyset everywhere for this reason, and the cancer platform prohibits offset pagination on the timeline query outright — a 110-million-row check-in table degrades badly enough that it was worth writing down as a rule rather than a preference.

**The stakeholder conversation, which is the real question here.** I would not open with "that is not possible". I would ask what the control is for, because the answer is usually one of three things, and only one of them actually needs page numbers.

- *"I want to know how many results there are."* That is a count, not a pager. An exact count over a filtered index scan costs about as much as the page itself, so what I would offer is an estimate capped at a threshold — the marketplace returns `total_estimate` and stops counting at 1,000, and the interface shows "1,000+". For a sourcing workflow that is genuinely all the information the number carries.
- *"I want to get to the end / to a specific region of the list."* That is a sort or filter request wearing a pagination costume. Reversing the sort gets you the end in one page. Jumping to "products starting with M" or "notes from March" is a `WHERE` clause, and it is both faster and more useful than page 40.
- *"I want to resume where I was."* That is exactly what a cursor is, and it works better than a page number because it is stable under concurrent writes.

If after all that they still want numbered pages, I would give the trade honestly: it is deliverable over a bounded range — offset pagination capped at, say, the first 1,000 rows, with keyset beyond it — and past that limit the cost is real latency on a query that the rest of the system's budget depends on. I would rather present that as a choice with a number attached than either refuse it or quietly ship something that degrades. The thing I would not do is ship an uncapped offset pager and let it become a production incident six months later, because at that point it is a contract and removing it is a breaking change.

</details>

---

### 13. How do you prove a query optimisation actually worked in production rather than on your laptop — and what would make you revert one that looked faster?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
A laptop measurement is a hypothesis, not evidence: different data volume, different distribution, different cache warmth, different configuration. Proof is the production percentile for that route or query before and after, over a window long enough to cover the real traffic mix, with the plan captured on both sides. I would revert a change that improved a mean while worsening the tail, that improved reads by making the write path slower, or whose gain turns out to be cache warmth rather than the change.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the laptop lies, specifically.** Four reasons, and they compound: the dataset is smaller and more uniform, so the planner makes different choices; the buffer cache holds the whole table, so `BUFFERS` reads that dominate production are invisible; `work_mem` and parallelism settings differ, so a sort that spills in production fits in memory locally; and there is no concurrency, so lock contention and connection-pool queueing contribute nothing. A query can be three times faster locally and slower in production because the plan flipped on a different row estimate.

**What I would actually measure.**

1. **The percentile, not the mean.** `http_request_duration_seconds` p95 by route, and the database-side statement duration for the specific query. A mean improves when the common case gets faster and hides a tail that got worse; the tail is what the error budget is spent on and what users describe.
2. **Over a full traffic cycle.** These workloads are extremely non-uniform — the cancer platform concentrates 70% of its traffic in an eight-hour clinic window, and the check-in burst lands between 07:00 and 09:00. A measurement taken at 15:00 says nothing about the morning. A week is usually the shortest honest window.
3. **Buffer reads, not just time.** If `shared read` dropped, the query is genuinely touching less data. If only the wall time dropped, I might be measuring a warmer cache.
4. **The plan on both sides.** `auto_explain` with a duration threshold captures the plan for the slow executions in production, which is the only place where the plan that matters actually runs. A change whose plan did not change did not do what I thought.
5. **The write path, on the same graph.** Adding an index to fix a read makes every insert and update on that table slower and adds maintenance load. On a table taking a bulk import this can be the dominant cost, and it will not show up if I only look at the endpoint I was optimising.

**How I would roll it out.** For a change with plan risk, the same way the service with the risky queries is deployed — canary. In the marketplace `catalog-service` takes a second deployment receiving about 10% of traffic through ingress weighting, held for fifteen minutes against error rate and p95 before the weight advances, specifically because it carries the risky query plans. That gives a concurrent A/B under identical real traffic, which is strictly better evidence than a before-and-after across time, since it controls for everything that changes on its own.

For a pure index addition, `CREATE INDEX CONCURRENTLY` first, confirm the planner adopts it, then measure. And I would check that the new index is actually used before declaring victory — `pg_stat_user_indexes` showing zero scans a week later means the planner never chose it, however good the local test looked.

**What would make me revert something that looked faster.**

- **The p99 got worse while the p50 improved.** Common with a plan change that is better on typical inputs and catastrophic on an outlier — a nested loop that is great for ten outer rows and dreadful for ten thousand. The wider the variance, the worse the incident when it arrives.
- **The write path degraded.** A new index that costs 15% on an import path to save 10 ms on a read I execute rarely is a bad trade, and it is only visible if I looked.
- **Cache pressure moved.** A bigger index displacing hot data from the buffer cache makes unrelated queries slower. The tell is rising `shared read` on queries I did not touch.
- **The improvement is not attributable.** If a deploy, a vacuum, an `ANALYZE` and my change all landed in the same window, I have not proven anything. Change one variable and confirm the change took — otherwise the result is clean and uninterpretable.
- **It only holds on today's data distribution.** A query fast because one category currently holds 200 rows is a time bomb. I would check the plan against a projected volume before treating it as durable.
- **It made the code substantially harder to reason about for a gain inside the noise.** A 5% improvement that turns a readable query into hand-tuned SQL with a comment explaining why it must not be touched is usually not worth it — and on a project where quality is valued over speed, that argument lands.

**And the thing I would set up so the next person does not have to ask.** A dashboard panel per hot query, with the deploy timeline overlaid. Most "did this help" arguments are unanswerable because nobody recorded the before.

</details>

---

## Schema Evolution and Migrations

---

### 14. A table has to change shape while it is being read and written in production. How do you sequence that, and what makes a migration dangerous rather than merely slow?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Expand, migrate, contract — across separate releases. Add the new shape as nullable, dual-write, backfill in bounded batches, switch reads, and only remove the old shape in a later release once nothing reads it. What makes a migration dangerous rather than slow is a lock: an operation that takes `ACCESS EXCLUSIVE` queues every subsequent query behind it, so a schema change that would have taken four seconds freezes the table for as long as the longest transaction in front of it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence, with the release boundaries that make it work.**

1. **Expand.** Add the new column nullable with no default that requires a rewrite, add the new index `CONCURRENTLY`, add the new table. Nothing reads it yet. This ships and runs against the *old* application image without breaking it — which is the property the whole approach rests on.
2. **Dual-write.** The new image writes both shapes. Deployed as a normal rolling or blue-green release, during which both image versions are live against the same schema.
3. **Backfill.** A batched, resumable job — bounded chunks, each its own short transaction, throttled and observable. Not one `UPDATE` over 110 million rows, which holds locks, generates enormous write-ahead log volume and pins a snapshot against vacuum for its whole duration.
4. **Switch reads.** A separate release. Now the old shape is written but unread.
5. **Contract.** A later merge request, at least one release afterwards, drops the old column or constraint. Being a separate change is what makes it revertible.

**Why the release boundaries matter more than the SQL.** The rule both designs enforce is that **every migration must be backwards-compatible with the previous image**. That is what permits blue-green — both colours run against the same schema during the cut-over — and it is what makes rollback a redeploy of the previous image digest rather than a down-migration. Down-migrations are a trap: they are written once, never tested, and run for the first time during an incident. The cancer platform runs `alembic upgrade head` as a pre-sync hook before the rollout and has no down-migration path at all; a change that cannot be written compatibly is split across two releases instead.

**What makes it dangerous rather than slow — the lock taxonomy.** The distinction I would draw is between operations that take a brief `ACCESS EXCLUSIVE` lock, those that hold it for the duration of a rewrite, and those that avoid it.

- **Effectively instant on modern PostgreSQL:** adding a nullable column; adding a column with a non-volatile default (stored in the catalogue, no rewrite since version 11); dropping a column; renaming.
- **Dangerous because they rewrite the table while holding the lock:** changing a column type in most cases; adding a column with a volatile default; `SET NOT NULL` without a prepared constraint.
- **Dangerous because they hold the lock while scanning:** adding a foreign key or a `CHECK` constraint — which is why you add them `NOT VALID` first and `VALIDATE CONSTRAINT` afterwards, since validation takes only a `SHARE UPDATE EXCLUSIVE` lock and does not block writes.
- **Safe if you remember the flag:** creating an index. `CREATE INDEX` blocks writes for its whole duration; `CREATE INDEX CONCURRENTLY` does not, at the cost of two table passes and the possibility of leaving an invalid index behind if it fails, which then has to be dropped and retried.

**The lock queue is the part people underestimate.** An `ALTER TABLE` waiting for `ACCESS EXCLUSIVE` sits behind the current readers — and every query that arrives after it queues behind *it*. So one slow analytics `SELECT` plus one otherwise-trivial `ALTER` stalls the entire table. The defence is `lock_timeout` on the migration session with a retry loop: acquire quickly or fail and try again in a moment. Failing fast is strictly better than building a queue.

**And the other things I check.** Is the migration idempotent and resumable, in case it dies halfway? Does it run as a role separate from the application role, so the application never holds schema privileges? Does it run before the new pods roll, or after? What is the write-ahead log volume, and will it blow the replication slot and break the replica? A backfill that generates more [WAL](https://www.postgresql.org/docs/current/wal-intro.html "Write Ahead Log — Sequential log written before data pages so committed transactions survive a crash") than the replica can consume turns a migration into a replication incident, and that one is invisible until it happens.

**On non-relational stores the same discipline applies** with one twist: nothing forces you to migrate. A document carries an explicit `schema_version` and the read path handles both versions — but "handles both" has to be a decision with an end date, not an accident, because a lazy migrate-on-read with no backfill means version 1 documents exist forever and every reader carries the branch permanently.

</details>

---

### 15. You are reviewing someone else's migration an hour before a release. What do you look for, and what would make you block it outright?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Lock strength and duration first, then reversibility, then whether the previous application image can still run against the new schema. I block outright on anything that takes a long `ACCESS EXCLUSIVE` lock on a hot table, any unbounded `UPDATE` or `DELETE`, any destructive change landing in the same release as the code that stops using it, and any migration nobody has run against a production-sized dataset.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checklist, in the order I read the file.**

1. **What lock does each statement take, and for how long?** I read every `ALTER` and ask which mode it needs. A column type change, an added `CHECK` or foreign key without `NOT VALID`, a `SET NOT NULL` without a prepared constraint, a non-`CONCURRENTLY` index — each of these blocks the table for a scan or a rewrite. On a small table nobody notices; on the hot one it is an outage.
2. **Is there a `lock_timeout`?** Without one, the migration waits indefinitely for the current readers and builds a queue behind itself. With one, it fails fast and retries. This is the single highest-value line in a migration file and it is almost always missing.
3. **Is the data change bounded?** An `UPDATE` with no `WHERE` on a large table is a long transaction, a write-ahead log flood, a vacuum blocker and a replication risk in one statement. I want batching with a bound and a resume point.
4. **Is it backwards-compatible with the currently-running image?** This is the question that decides whether rollback exists. If the old pods cannot serve traffic against the new schema, then the moment the migration lands the only way out is forward, at the worst possible time.
5. **Does the destructive half ship separately?** A dropped column in the same merge request as the code that stopped reading it means the rollback of that code is now broken. Contract is a later release, deliberately.
6. **Is it idempotent and resumable?** If it dies at 60%, what happens when it is re-run? A migration that is only correct from a clean start is a migration that will be run twice.
7. **Has it been run against production-sized data?** "It took two seconds on my machine" is not information about a 110-million-row table. If the answer is no, the duration is unknown, and an unknown duration on a lock is the definition of a dangerous change.
8. **What does it do to the replicas?** WAL volume, replication slot pressure, and whether replica lag will breach its alert threshold during the run.
9. **Does it run as the right role?** Migrations under an owning role that never serves a request; the application role holds no schema privileges. On the cancer platform this also matters for Row-Level Security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")), where the application role must be `NOSUPERUSER` without `BYPASSRLS` — a migration that quietly grants a privilege to the application role would disable the strongest control in the system.
10. **Does it touch anything security-relevant?** A policy, a grant, a constraint that an authorization rule depends on. Those get read twice regardless of the clock.

**What blocks it outright.** Any of: an unbounded rewrite or scan under `ACCESS EXCLUSIVE` on a hot table; a `DROP` or a destructive type change in the same release as the code change; an unbatched data migration on a large table; a migration that has never been run against realistic volume; or a change that makes the previous image unable to run. I would also block a migration that has no plan for what happens if it fails halfway, because "we will work it out" at that point means an improvised `UPDATE` in production.

**What does not block it, but gets written down.** A slow but safe migration — say a `CONCURRENTLY` index build that will take forty minutes — is fine; it just needs to be known, started early, and not be something anyone is waiting on. Slow is a scheduling problem. Dangerous is a correctness problem.

**How I would say it.** Naming the specific statement and the specific lock, with the alternative attached — "`ALTER TABLE ... ALTER COLUMN TYPE` rewrites the table under `ACCESS EXCLUSIVE`; add a new nullable column, backfill in batches, switch reads next release" — is a review someone can act on in the hour available. "This looks risky" is not, and an hour before a release the difference matters. If the alternative genuinely cannot be built in the time, then the honest recommendation is to pull it from the release rather than to approve it with a caveat nobody will read.

</details>

---

### 16. A schema change has to be rolled back after the new code is already live. What does that demand of how the migration was written in the first place?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It demands that the migration was additive and that the old image can still run against the new schema — because then the rollback is a redeploy of the previous image digest and the schema does not move at all. If the migration was destructive, there is no clean rollback: down-migrations restore shape but not data, and by the time you need one it has never been run.

<details>
<summary><strong>Detailed answer</strong></summary>

**Reframing the question, because the framing is the answer.** "Roll back the schema" is almost always the wrong operation. Data written since the migration under the new shape does not survive a shape reversal, and a down-migration that drops a column drops whatever went into it. What you actually want is to roll back *the code* and leave the schema where it is — and that is only possible if the schema is compatible with both images. So the demand is made at write time, one or more releases earlier: **every migration must run safely against the previous application image.** In both these designs that is the stated rule, and it is what makes rollback a redeploy of the previous image digest, safe by construction because the schema is compatible in both directions during the window.

**What that means concretely for how the migration is written.**

- **Additive only in the release that deploys.** Nullable columns, new tables, new indexes created `CONCURRENTLY`. The old image ignores them; the new image uses them.
- **No rename in place.** A rename breaks the old image immediately. Add the new column, dual-write, backfill, switch reads, drop later.
- **No `NOT NULL` or new constraint the old image can violate.** The old image does not know to populate the column, so the first write from a surviving old pod fails. Constraints go on in the contract phase, after every writer populates the field.
- **No default that changes behaviour under the old image.** If the old code inserts a row without the column and the default is wrong for its semantics, you now have bad rows to clean up, and that cleanup is a data migration nobody planned.
- **Contract lands at least one release later**, as its own merge request. That gap is the rollback window, and its width is a deliberate choice rather than an accident.
- **Backfills are separate from schema changes** and are resumable, so rolling back the code does not require unwinding a half-finished backfill.

**What rollback looks like when it is done right.** [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") reverts to the previous revision, the previous image digest is deployed, the schema stays. Nothing runs against the database at all. That is the property worth defending in an interview, because it means the rollback path is the same mechanism as the deploy path — one that gets exercised constantly — rather than a special procedure that only ever runs during an incident.

**What rollback looks like when it is done wrong.** Someone writes a down-migration, and it has three problems: it has never been executed anywhere; it restores structure but not the data the forward migration transformed; and it runs under exactly the conditions where mistakes are most expensive. I would rather have no down-migration and a forward-fix discipline than a down-migration that creates false confidence. If a truly destructive change has to be reverted, the honest path is point-in-time restore to a scratch instance and a reconciliation of what was written since — which is slow, manual, and exactly why the expand/contract discipline exists.

**The organisational half of this.** Expand/contract costs three merge requests where one would do, and the third one — the contract — is the one that gets forgotten, so the codebase accumulates columns nobody reads and everybody is afraid to drop. I would treat the contract migration as part of the same piece of work, tracked and landed, rather than as tidying. And I would say plainly that the cost is real: this discipline is slower, and the thing it buys is that a bad release at 17:00 on a Friday is a redeploy rather than an incident.

</details>

---

## API Design, Contracts and Retry Semantics

---

### 17. How do you version an API, and how do you tell a breaking change from a safe one when the consumer is another team you cannot deploy with?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
A major version in the path (`/v1`) for changes that cannot be made compatibly, and additive evolution inside it for everything else. The test for breaking is not a judgement call: a change is safe if every request a conforming old client can send still succeeds and every response it receives still parses under its old schema — which is a property a generated contract and a contract test can check, rather than something a reviewer eyeballs.

<details>
<summary><strong>Detailed answer</strong></summary>

**The scheme, and why.** Both these systems version in the path — `/api/v1` and `/v1` — because it is visible in logs, trivially routable at the gateway, and unambiguous in a bug report. Header or media-type versioning is more theoretically pure and worse in practice: it is invisible in an access log, easy to omit, and harder to route on. The important part is not which scheme, it is that **a new major version is a last resort**, because it means running two implementations and migrating every consumer. Most evolution should be additive inside the current version.

**The compatibility rules, stated as rules so they are checkable.**

*Safe, additively:* adding an optional request field with a sensible default; adding a response field; adding a new endpoint; adding a new enum value **only if** the contract already told clients how to handle unknown values; relaxing a validation rule; adding an optional query parameter.

*Breaking:* removing or renaming any field; making an optional request field required; narrowing a type or a validation rule; changing the meaning of an existing field while keeping its name — the worst one, because nothing detects it; changing default sort or pagination behaviour; changing a status code for an existing condition; changing an error code's meaning; removing an enum value a client may send.

*The two that generate arguments:* **adding a response field** breaks a client that rejects unknown fields, and **adding an enum value** breaks a client that switches exhaustively. Both are really contract questions — if the published contract says clients must tolerate unknown fields and unknown enum values, then they are safe and a client that breaks is non-conforming. If it does not say so, they are breaking. So I would put that statement in the contract on day one, because it is the cheapest thing you will ever do for your future self.

**Making the check mechanical rather than social.** Pydantic models define every request and response, [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document, and **that document is the published contract and is contract-tested in continuous integration**. That gives two things: a diff of the schema on every merge request, which makes a breaking change visible during review rather than after release; and a spec that consumers generate a client from. On this vacancy's stack the frontend generates its client from the OpenAPI document, which raises the stakes usefully — a breaking schema change surfaces as a compilation failure on their side rather than a runtime error in someone's browser, and the generated client is a strong argument for keeping the spec honest.

**When you cannot deploy together — which is the actual question.**

- **Expand/contract, exactly as with a database.** Add the new field alongside the old; populate both; announce; give a deprecation window with a date; remove only after telemetry shows nobody uses the old one. Per-field usage telemetry is what turns "I think nobody uses it" into "nobody used it in ninety days", and it is worth the instrumentation.
- **Tolerant reading on our side too.** We are somebody's consumer as well. Ignoring unknown fields on inbound payloads means their additive change does not break us.
- **Consumer-driven contract tests where the consumer is internal.** Their expectations run in our pipeline, so we find out at merge time rather than at their deploy time.
- **`Deprecation` and `Sunset` headers plus telemetry on old-version usage**, so the deprecation is a measured process rather than an email.
- **Run both versions concurrently when a break is unavoidable**, with an explicit end-of-life date, and accept that you now maintain two. That cost is the reason to exhaust additive options first.

**And the one I would push back on.** Versioning is frequently proposed as the solution to a change that should simply not be made. If a field's meaning is changing, the right move is usually a *new field with a new name* and a deprecation of the old, not `/v2` — because `/v2` migrates every consumer for a change that affected one field. Reserve the major version for a genuine change of resource model.

</details>

---

### 18. A client retries a POST it never got a response to. What does your API have to do so the retry is safe, and where does the guarantee actually live?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Accept a client-supplied `Idempotency-Key`, and on a repeat of the same key return the stored result of the first attempt rather than performing the work again. The guarantee does not live in the cache that makes this fast — it lives in a unique constraint in the database, because a cache can be flushed and the retry must still be safe.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the retry happens at all.** The client's timeout expired, or the connection dropped, or a load balancer returned a 502. The client does not know whether the server processed the request — and cannot know, because the ambiguity is in the network. So the server must make the question irrelevant: the second request must produce the same end state and the same visible answer as the first.

**The mechanism.**

1. **The client generates the key**, not the server, and reuses it across retries of the same logical operation. A server-generated key is useless here — the client cannot ask for one, because asking is itself a request that can fail.
2. **`Idempotency-Key` is required on all mutating `POST`s.** Required, not optional: an optional idempotency mechanism is one that is absent exactly when someone forgot.
3. **The first request records the key with its outcome** — status code and response body — so a replay returns the identical response rather than a different one that happens to have the same effect. A client that gets a `201` then a `409` on its retry has to write special handling; a client that gets the same `201` twice does not.
4. **Concurrent duplicates are handled, not just sequential ones.** Two copies of the same request arriving simultaneously is the normal case for a double-clicked button. The first inserts the key row and proceeds; the second either waits or receives `409 Conflict` with a retry hint. Getting this wrong is how a system that "has idempotency" still double-charges.
5. **The key is scoped and expires.** Scoped to the tenant, so one organisation cannot collide with or probe another's keys — in the marketplace the constraint is `UNIQUE (retail_group_id, idempotency_key)`. Expiry of about 24 hours, matching the outer bound of any sane retry.

**Where the guarantee lives — this is the part of the answer I care about.** In the cancer platform, `idem:{idempotency_key}` in Redis holds the stored response, and the design says explicitly that this is the *optimisation* and not the guarantee: flushing the cache permits a duplicate `POST` to be reprocessed, and what makes that safe is a natural key in PostgreSQL underneath — `(patient_id, recorded_for)` unique on check-ins, so a redelivered check-in becomes an `INSERT ... ON CONFLICT DO UPDATE`, which is arithmetic rather than a bug. In the marketplace the same rule is written into the schema: `UNIQUE (retail_group_id, idempotency_key)` on `connection_request` is described as the database, not the cache, being what finally prevents a duplicate thread *and* a duplicate charge, and `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge` makes "a connection bills at most once" a property of the schema rather than of everyone remembering.

That is the general principle I would state: **any mutation that must not double-apply needs a natural key or a unique constraint in the system of record.** A cache-based dedupe is a latency saving that must never be load-bearing. The way to test whether a system really has this is to flush the cache and replay — if a duplicate appears, the guarantee was never there.

**Two more things that belong in the answer.**

*The ambiguity extends past the API.* The same problem exists between the broker and the consumer. At-least-once delivery means duplicates are normal; exactly-once does not exist across a broker and a database without a distributed transaction. So every consumer is idempotent against the same natural keys, and the API and the message path share one mechanism rather than two.

*Sometimes the right answer is to accept the duplicate.* Reminder delivery in the cancer platform can double-send under a receipt-loss race, and that is deliberate: a patient seeing a reminder twice is a far better failure than not seeing it at all. Knowing which side of that trade each operation sits on is the design decision; "make everything exactly-once" is not achievable and pretending otherwise is how people build elaborate machinery that still fails.

</details>

---

### 19. An endpoint takes a list of identifiers and acts on all of them. What failure modes do people miss, and what does the response body look like when half of them fail?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
The missed failure modes are almost all consequences of one decision nobody made explicitly: whether the operation is atomic or per-item. Everything else — partial failure, retry semantics, unbounded input, duplicate ids, mixed authorization outcomes — follows from that. When half fail, the response has to be per-item and machine-readable: a stable identifier per entry, its own status, and an error code the client can branch on, never a prose summary.

<details>
<summary><strong>Detailed answer</strong></summary>

**The decision that has to be made first.** All-or-nothing, or best-effort per item? Both are defensible, and the failure is leaving it implicit, because then the answer varies by which exception fired. A bulk import of vendor catalogue rows is validated wholly and fails wholly — rows land in staging, are checked against the category schema, and nothing moves into the live tables unless the file is acceptable, with a per-row `error_digest` explaining why. A bulk archive of listings is per-item, because one bad id is no reason to refuse the other forty-nine. State it in the contract, and make the status code match: `200` or `207` for partial, never `200` with failures buried in the body and never `500` because one item failed.

**What people miss.**

- **Unbounded input.** No maximum list length, so someone sends 100,000 ids and the request times out halfway with an unknown amount applied. A hard cap in the schema — 50, 200, whatever the operation supports — plus an asynchronous job endpoint for genuinely large work. The marketplace draws this line explicitly: a 20,000-row import is not a request; it is an upload that returns a job id, chunked into 500-row tasks with a status endpoint the workspace polls.
- **Retry after a partial failure.** The client retries the whole list, including the items that succeeded. Without per-item idempotency you double-apply. The key must be per item — or derived from the operation and the item id — not per request.
- **Duplicate ids in one list.** `[a, a, b]`. Does `a` get processed twice? Deduplicate on arrival and say so.
- **Mixed authorization outcomes.** Some ids belong to the caller's organisation and some do not. The unsafe response tells the caller which ids exist but are forbidden — that is an enumeration oracle, and in a marketplace where competitors share the platform it matters. `not_found` for anything outside the caller's tenant scope, uniformly, so the response cannot be used to probe.
- **Ordering and interdependence.** If the items are not independent, a partial application can leave an inconsistent state that neither a retry nor a rollback repairs.
- **One transaction for the whole list.** A 500-item batch in one transaction holds locks for its duration, risks deadlock against a concurrent batch in a different order, and rolls back everything on the last item's failure. Chunk it, sort by primary key, and commit per chunk.
- **The timeout.** Fifty items times 200 ms is ten seconds, which is past most client and gateway timeouts. The client then retries, and now two runs are in flight.
- **No per-item observability.** Only the request is traced, so a failure inside item 37 is unattributable.

**The response shape.** Per item, with a stable identifier, a status, and a structured error:

```json
{
  "summary": { "requested": 4, "succeeded": 2, "failed": 2 },
  "results": [
    { "id": "p_01", "status": "ok" },
    { "id": "p_02", "status": "ok" },
    { "id": "p_03", "status": "error", "code": "not_found", "detail": "No such product for this organisation." },
    { "id": "p_04", "status": "error", "code": "conflict", "detail": "Listing is archived and cannot be republished.", "retryable": false }
  ]
}
```

The properties that matter: the client can retry precisely the failed subset; `code` is a stable enumeration it can branch on while `detail` is human text that may change; `retryable` distinguishes a transient failure from a permanent one so a client does not hammer a validation error; and the order and identifiers let it reconcile against what it sent. `RFC` 9457 problem-detail bodies are the convention in both these systems for single-resource errors, and the per-item objects follow the same field vocabulary so clients learn one error model.

**Response codes.** `207 Multi-Status` if the contract embraces it; otherwise `200` with the per-item statuses, documented. What I would not do is return `400` for a partial success — the request was valid and two items were applied, and a `400` invites a client to retry the whole thing.

</details>

---

## FastAPI Runtime and Service Structure

---

### 20. When do you write a route as `def` rather than `async def` in FastAPI, and what does each choice actually do to the thread pool and the event loop under load?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
`async def` runs the handler directly on the event loop; `def` runs it in a bounded worker thread pool. So `def` is correct for blocking work — a synchronous database driver, a library with no async version, anything central-processing-unit-bound — and `async def` is correct only when every await inside it is genuinely non-blocking. The dangerous combination is `async def` containing a blocking call, which stalls the whole event loop for every concurrent request, not just the one.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each actually does.** FastAPI inspects the signature. An `async def` route is awaited on the event loop in the same thread that is handling every other request. A plain `def` route is dispatched to an `anyio` worker thread pool — by default 40 threads — and the event loop awaits its completion, so the loop stays free while that thread blocks.

**The failure mode that matters.** One blocking call inside an `async def` — a synchronous database driver, `requests`, `time.sleep`, a large JSON parse, a bcrypt or [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive") hash, a Pandas operation — holds the event loop for its whole duration. During that time *no other request progresses at all*, not even ones that are ready. The symptom is characteristic and easy to misread: latency that degrades non-linearly with concurrency while central-processing-unit utilisation stays low and every endpoint slows down together, including the health check. People see low utilisation and conclude the service is not the bottleneck.

The inverse mistake is cheaper but real: writing `def` for a handler that only awaits network input-output means burning a thread for something the loop could have multiplexed, and the thread pool's 40 slots become the concurrency ceiling. Requests beyond that queue silently.

**So the rule I apply.** `async def` if and only if every call inside it is awaitable and non-blocking, all the way down — including the driver, the client library and the serialisation. Otherwise `def`, and let the thread pool do its job. A mixed handler — mostly async with one blocking call — is the worst of both, and the fix is `run_in_threadpool` (or `asyncio.to_thread`) around the blocking part rather than converting the whole route.

**The pool is a resource with a size, and it is shared.** The default 40 threads are shared by every `def` route *and* every `def` dependency. A slow blocking endpoint can exhaust it and stall unrelated `def` endpoints while the event loop sits idle. Raising the limit trades memory and context-switching for concurrency and is worth doing deliberately with a number, not by doubling until it stops hurting. The same applies to the database connection pool underneath: threads waiting on a pool with fewer connections than threads is queueing you cannot see from the outside.

**Where this connects to the stack in front of me.** This vacancy involves optimising a *synchronous* FastAPI architecture under heavy enterprise load, and that is a deliberate architecture rather than an oversight: with a synchronous database driver, `def` routes plus a correctly-sized thread pool are the right answer, and converting handlers to `async def` without converting the driver would be actively harmful. The tuning levers in that world are the thread pool size, the connection pool size, the worker-process count and the relationship between them — not the keyword on the function.

**How I would demonstrate it rather than assert it.** Two endpoints, one `async def` with a `time.sleep(1)` and one `def` with the same, and a load test at concurrency 20. The first serialises to twenty seconds and takes the health check down with it; the second finishes in about one second. It is a thirty-second demonstration and it makes the mechanism impossible to misremember.

</details>

---

### 21. What belongs in a FastAPI dependency, what belongs in middleware, and what belongs in the handler itself — and how do you keep a dependency chain from becoming a hidden call graph nobody can follow?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Middleware for anything that must apply to every request regardless of route and needs the raw request or response — correlation ids, timing, compression, catch-all error shaping. Dependencies for anything route-scoped that produces a typed value or enforces a precondition — authentication, tenant scope, the database session, pagination parameters. The handler for the business decision and nothing else. The chain stays followable by keeping it shallow and typed, and by treating dependencies as *inputs*, not as a place to put side effects.

<details>
<summary><strong>Detailed answer</strong></summary>

**Middleware — the narrow case.** Middleware runs for every request including 404s and validation failures, sees the raw request and response, and cannot be selectively applied per route or return a typed value. So it is right for: assigning and propagating `request_id` and trace context; request timing and metrics; response compression; security headers; and a final exception boundary that turns anything unhandled into a problem-detail body rather than a stack trace. It is wrong for authorization, because middleware has to pattern-match on paths to know what to enforce, and a path-matching rule is a control that silently stops covering a route the day someone adds one under a prefix the pattern missed.

**Dependencies — the default.** Route-scoped, typed, testable, composable, and declared in the signature so they appear in the generated OpenAPI document. What lives here:

- **Authentication** — decode and verify the token, return a typed principal. Both systems validate locally against a cached JWKS with no network call per request, which is the assumption the latency budget rests on.
- **Authorization preconditions** — account type and scope. In the marketplace `/v1/vendor/*` requires `act = vendor`, enforced by a dependency on the router, so a retailer token cannot reach a vendor route regardless of its scopes. Declaring it on the router rather than per endpoint is the point: adding an endpoint under that prefix inherits the check instead of needing someone to remember it.
- **The database session**, with deterministic cleanup.
- **Parameter objects** — pagination cursors, filter models — so validation is declarative and appears in the schema.
- **Tenant scope**, resolved once and attached to the repository layer.

**The handler.** The business decision, expressed against typed inputs. If a handler starts with fifteen lines of extracting things from the request, those lines are dependencies that have not been written yet.

**Keeping the chain followable — the real question.** A deep dependency graph is genuinely hard to read: the signature shows one parameter, and behind it are six layers each with its own side effects. What keeps it manageable:

- **Depth of two or three, not six.** A dependency may depend on another; a five-level chain means the abstraction is wrong.
- **Dependencies return values; they do not mutate global state.** The moment a dependency writes to `request.state` for another dependency to read, the graph has stopped being a graph and become implicit coupling. Ordering now matters and nothing declares it.
- **Type the return.** `current_user: Annotated[Principal, Depends(get_current_user)]` tells a reader what arrives without opening the dependency. An untyped `dict` forces everyone to go read it.
- **One clear name per concern**, and the same dependency reused everywhere rather than three near-identical auth dependencies that drift. Three copies of an authorization decision is the defect, not the convention.
- **Router-level dependencies for invariants**, endpoint-level for specifics — so the invariant is visible in one place rather than repeated thirty times, and cannot be forgotten on the thirty-first.
- **No heavy or side-effecting work in a dependency.** Dependencies run before the handler and on every request including ones that will be rejected later. A dependency that makes a network call has added that latency to every request on the route, and a dependency that writes has made a side effect happen for a request that may never be processed.
- **Read the generated OpenAPI document when in doubt.** Because dependencies surface as parameters and security schemes, the spec is a rendering of the chain — which is a genuinely useful review artefact, and one reason to prefer dependencies to middleware for anything a client needs to know about.

**The one exception I would make explicitly.** Cross-cutting concerns that have to apply to routes nobody has written yet — the exception boundary, correlation ids — are worth putting in middleware precisely because they should not be forgettable. Everything else being a dependency means it is visible in the signature, and visible beats implicit.

</details>

---

### 22. A dependency opens a database session and has to close it whatever happens. How do you write that, what does sub-dependency caching do within one request, and how do you override the whole chain in a test without touching real infrastructure?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
A generator dependency with `try/finally` — or a context manager — so the session closes on the normal path, on an exception and on a client disconnect. Within one request FastAPI caches each dependency's result by its callable and parameters, so every dependency that asks for the session gets the same one and the request has a single transaction. In tests, `app.dependency_overrides` replaces the session provider at the top of the chain, and everything beneath it follows without a single mock at the call sites.

<details>
<summary><strong>Detailed answer</strong></summary>

**Writing it.**

```python
def get_session() -> Iterator[Session]:
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
```

The `finally` is the load-bearing line: it runs on the happy path, on an exception raised in the handler, and when the client disconnects mid-request. Without it a leaked session holds a pooled connection, and under load the pool exhausts and every request blocks waiting for one — which presents as a total hang rather than an error, and is one of the harder failures to diagnose because nothing has raised. Whether to commit in the dependency or in a unit-of-work object inside the handler is a real choice; committing here keeps the request/transaction boundary in one place, at the cost of committing work the handler may not have considered final.

Two details specific to this pattern. First, the code after `yield` runs *after the response has been generated*, so raising there cannot change the status code the client already received — cleanup that must affect the response belongs before the yield or in an exception handler. Second, an `async def` session dependency must use an async driver and an async session; a synchronous session inside an async dependency blocks the event loop for the whole request, which is the single most common way a FastAPI service becomes mysteriously slow under concurrency.

**Sub-dependency caching.** Within one request, FastAPI caches by `(callable, parameters)`. So if `get_session` is required by `get_repository`, by `get_current_user` and by the handler itself, it is called once and all three receive the same object. That is what makes a request one transaction rather than three, and it is also why a dependency with a side effect is dangerous — it fires once per request, not once per declaration, and reasoning about that requires knowing this rule. `Depends(fn, use_cache=False)` opts out where a fresh value is genuinely required, which is rare and worth a comment when it happens.

The caching is per request, not global. A request-scoped cache of care-team membership is fine and correct; the cancer platform caches exactly that for the request's duration and states that the membership never outlives one request, because a stale authorization fact is a disclosure rather than a slow page.

**Overriding in tests.**

```python
app.dependency_overrides[get_session] = lambda: test_session
```

The property that makes this good is that the override happens at the *top* of the chain. Every dependency and every handler that asks for a session now receives the test one, with no patching at the call sites and no mock objects pretending to be a session. The same applies to `get_current_user` — override it with a fixture principal and every authorization dependency downstream works against a real token-shaped object.

**What I would and would not fake, though.** The override mechanism lets you replace the session with an in-memory SQLite one, and I would mostly refuse to. Both these projects run integration tests against real PostgreSQL, MongoDB and Redis in Docker Compose at the pinned versions, because the things a mock passes while broken are exactly the interesting ones: GIN query plans, the projection pipeline, `ON CONFLICT` behaviour, partial index selection, row-level security policies, and how a real broker behaves under flow control. A test suite that only proves the Python is self-consistent confirms whatever you already expected.

Where the override earns its place is at the *edges*: a transaction rolled back per test for isolation, a fixture principal instead of minting real tokens, and a stubbed external provider so the suite does not send email. The rule I would state is that you fake what you do not own and run what you do.

</details>

---

### 23. You inherit a synchronous FastAPI service that is slow under concurrency. What do you measure first, and which optimisations would you do before anyone mentions rewriting it as async?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Measure where the time goes before changing anything: request latency broken into its components by trace, worker and thread-pool saturation, database connection-pool wait time, and the slow-query log. In my experience the cause is almost never "it is synchronous" — it is a pool sized wrong, an N+1 query, a missing index, or a blocking call sitting inside an `async def` route. All of those are cheaper to fix than a rewrite, and a rewrite that lands on top of them fixes nothing.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I measure, in order, and why that order.**

1. **A distributed trace of a slow request, decomposed.** Time in the gateway, time queued before the handler, time in each database call, time in outbound calls, time in serialisation. This single artefact usually ends the debate, because "slow under concurrency" describes three completely different problems — queueing, contention and per-request cost — and the trace distinguishes them immediately.
2. **Queueing versus service time.** If per-request work is unchanged under load but total latency rises linearly with concurrency, the service is queueing and the fix is capacity or pool sizing. If per-request work itself degrades, it is contention — locks, pool waits, or an overloaded database.
3. **Thread-pool saturation.** For `def` routes, the `anyio` pool defaults to 40 threads and is shared across every `def` route and dependency. If it is full, requests wait before they start, and the event loop looks idle the whole time.
4. **Database connection-pool wait time.** Threads waiting for a connection is invisible unless you instrument it. This is where a service with 40 threads and a pool of 5 spends its life.
5. **Worker process count versus cores.** A single Uvicorn worker on an eight-core node caps throughput at one core for anything central-processing-unit-bound. Free throughput, frequently unclaimed.
6. **The slow-query log and `pg_stat_statements`**, ordered by *total* time rather than by mean. The query that takes 20 ms and runs 400 times per request is the problem; the 2-second report that runs hourly is not.
7. **Whether any `async def` route contains a blocking call.** One `requests` call or one synchronous driver call inside an `async def` stalls the event loop for every concurrent request. The signature is low central-processing-unit utilisation with everything slow simultaneously, including the health check.

**The optimisations I would do first, roughly in order of value per unit of risk.**

- **Fix the N+1s.** Almost always present, almost always the biggest single win, and completely independent of async. In the marketplace this is the difference between hydrating thirty listings with one bulk `$in` and doing thirty round trips. Eager-load explicitly; the tracing view makes them obvious because you see thirty identical spans.
- **Size the pools coherently.** Thread pool, database pool and worker count are one system, not three settings. The sum of every pod's pool maximum must stay under the server's connection limit, and a thread pool larger than the connection pool just moves the queue.
- **Add the missing indexes, informed by the plan rather than by intuition**, and check the planner adopts them.
- **Move the blocking call out of the event loop** — `run_in_threadpool` around the offending part, not a rewrite of the route.
- **Take work off the request path entirely.** A request that sends an email, generates a thumbnail or re-indexes a document synchronously is doing work the user is not waiting for. Both these systems push that to a queue and return `202`, and it is often a larger win than any tuning.
- **Cache the expensive read**, with a stated invalidation rule and stampede protection, so the cache does not become its own incident at expiry.
- **Add more workers or pods.** Unfashionable and frequently correct: if the service is input-output-bound and the database has headroom, horizontal scale is cheaper than an engineering quarter.
- **Reduce payload size** — fewer fields, pagination limits, compression. Serialisation of large response bodies is real central-processing-unit time and is easy to overlook.

**What I would say about the rewrite.** Async gains throughput when a process spends most of its time waiting on the network and the concurrency ceiling is thread count. It gains nothing when the bottleneck is the database, and it makes things worse when a single blocking call remains anywhere in the path — which, in a codebase being converted incrementally, it will. A conversion also means an async driver, an async session, async-safe libraries, and re-testing every path, so it is a large change with a wide blast radius on a system that is already under pressure.

So my position would be: measure, take the cheap wins, and re-measure. If after that the profile shows threads waiting on the network with the database idle, then async is the right answer and now there is evidence for it. Given that this stack is explicitly a synchronous architecture under heavy enterprise load, I would expect to be tuning the pool relationships and the query layer rather than proposing a rewrite — and I would want the before-and-after numbers on the same graph either way, because "it feels faster" is not a result.

</details>

---

## Caching and Search Consistency

---

### 24. Your cache hit ratio drops sharply with no change in traffic. Where do you look, and how do you decide whether the cache is now doing more harm than good?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
A hit ratio falls for one of four reasons: the keyspace got wider, the entries are being evicted, they are being invalidated more aggressively, or the cache lost its data. Look at key cardinality, eviction count, memory against `maxmemory`, and whether a deploy or a data change altered how keys are constructed. You decide it is doing harm when the miss path plus the lookup and write cost exceeds the direct path, or when it has started serving answers that are wrong.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where I look, and the specific signal each gives.**

1. **Key cardinality.** A hit ratio is a function of how concentrated the key distribution is. If a new filter parameter, a new sort option or a locale got folded into the key, the same traffic now spreads over ten times as many keys and each one is cold. In the marketplace the search cache is keyed on `cat:search:{filter_hash}`, and a hash over a filter set is exactly the kind of key that widens silently when someone adds a facet to the interface. That is a client-side change with no backend deploy, which is why "nothing changed" can be true and the ratio can still halve.
2. **Evictions and memory.** `evicted_keys` rising with memory at `maxmemory` means entries are being pushed out before their TTL. That is a capacity answer, and the fix is either more memory or a smaller working set — the latter usually meaning caching fewer, larger, more reusable things rather than many small ones.
3. **Invalidation volume.** An event-driven purge that is now firing far more often. The specific shape in the marketplace is a bulk import: 20,000 rows would produce 20,000 cache invalidations and 20,000 upserts if each row emitted its own event, which is precisely why the import emits one completion event and the indexer re-projects in batches of 200. A regression that reverts that batching would show up first as a collapsed hit ratio, not as an import failure.
4. **Did the cache lose its data?** A Redis failover, a restart, a `maxmemory-policy` change, a key-prefix change in a deploy. A prefix change is a total cold start that looks like a catastrophic ratio drop and resolves on its own — but only if you know to wait rather than to intervene.
5. **TTL changes.** Someone shortened a TTL for freshness and paid for it in hit ratio. This is a trade that should be made deliberately, and it often is not.
6. **A shift in the traffic *mix* rather than its volume.** The question says traffic did not change, but "same requests per second" and "same distribution" are different claims. A crawler, an integration partner, or a scripted comparison workflow enumerating listings produces the same request rate over a completely flat key distribution and no cache can help with that. In the marketplace this also has a security reading — systematic enumeration is catalogue scraping, and there are per-vendor detail-fetch caps designed to make it slow enough to notice.

**Deciding whether it is now doing harm.** Three tests:

*The arithmetic one.* The cache helps when `hit_ratio × saved_cost > lookup_cost + write_cost`. A Redis round trip is a few milliseconds; the uncached path on the marketplace search is about 45 ms in Postgres plus 25 ms in Mongo. At an 85% hit ratio that is strongly positive; at 10% you are adding 3–7 ms to nearly every request to save the database occasionally. There is a crossover, and it is worth computing rather than arguing about.

*The capacity one.* Even a poor hit ratio can be worth keeping if the backing store cannot survive the full load. The marketplace design states the number plainly: losing `redis-cache` entirely is not an outage — cache-aside means every read falls through — but latency rises from about 35 ms to about 107 ms and Postgres load multiplies roughly sixfold, and capacity is sized to survive that. Knowing that number is what turns "should we keep the cache" from an opinion into a decision.

*The correctness one, which outranks both.* A cache that serves stale data past what the product can tolerate is doing harm at any hit ratio. The structural protection here is that the listing key carries the revision — `cat:listing:{id}:v{rev}` — so a stale key is simply unreachable even if the purge message is lost; invalidation correctness depends on the revision pointer in Postgres being current, not on a message arriving. That is the pattern I would reach for generally: prefer a key design where staleness is impossible over an invalidation protocol that must not fail.

**What I would do rather than remove it.** Fix the key design first — normalise filter parameters so equivalent queries hash identically, drop parameters that do not affect the result, and cache the expensive shared fragment rather than the per-user whole. Then check the stampede protections still work, because a low hit ratio and a hot key together are how a cache expiry becomes a database incident: single-flight per key plus probabilistic early expiry bound the recomputation to roughly one per TTL regardless of concurrency, and those only help if they are still in the path.

**And one thing I would check before any of it.** Whether the ratio dropped or the *metric* dropped. A relabelled metric, a new keyspace not included in the aggregation, or a scrape failure all look identical to a real regression on a dashboard. Confirming the measurement before acting on it costs a minute and occasionally saves the entire investigation.

</details>

---

### 25. You keep a search index alongside the database. How do you keep the two in step, how do you reindex with no downtime, and how do you know a relevance change is an improvement?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
In step by never dual-writing: the index is fed from a transactional outbox, so a committed change always produces an event and the backlog is a visible metric rather than silent drift. Reindex with no downtime by building into a new index and moving an alias atomically, which is only safe because the index holds no data of its own and is fully rebuildable from source. And a relevance change is an improvement only if it is measured — offline against a labelled set, then online — never because it looks better on the three queries someone tried.

<details>
<summary><strong>Detailed answer</strong></summary>

**Keeping them in step.** The application never writes to `es-clinical` directly. Every write commits to `pg-clinical` with an `outbox_event` row in the same transaction; a relay publishes to the topic exchange; the `celery.index` worker consumes and bulk-indexes. The property this buys is specific: with a dual write, a database commit followed by an index failure leaves the index permanently wrong with nothing to detect it. Here the outbox row stays unpublished until the index write succeeds, so the failure is a growing backlog with an alert on it — `outbox_unpublished_age_seconds` over 30 s for five minutes — rather than silent divergence.

The lag is stated as a **composed** budget rather than a target: the outbox relay at up to 2 s, plus a bulk flush at 1,000 documents or 5 seconds, plus a 5 s `refresh_interval`, giving p50 under 8 s, p95 under 15 s, p99 under 30 s. Stating it as a sum matters because tightening any one of the three alone buys nothing, and people do reach for `refresh_interval: 1s` believing it will help. The 5 s setting is itself a deliberate trade — it roughly halves segment-merge pressure against the 1 s default.

And the backstop that assumes all of that failed: a nightly reconciliation comparing document counts per patient between the two stores, reindexing any patient that diverges.

**One property makes all of this tractable: no data originates in the index.** It is a projection, rebuildable from PostgreSQL and MongoDB at any time, which is why its disaster-recovery target can be "or a rebuild" and why a degraded cluster degrades search to a clearly-labelled chronological fallback served from the database rather than producing an outage.

**Reindexing with no downtime.** Aliases, always. Clients — and in this design clients means the application, never a direct query — read through the `clinical-search` alias. To reindex: create the new index with the new mapping, backfill from source, keep the live feed flowing to both during the catch-up, verify document counts and a sample of queries against the old index, then atomically repoint the alias in a single call, and keep the old index until you are confident. Rollback is repointing the alias back, which is seconds.

The corollary is that a mapping change is never an in-place edit. Many mappings cannot be altered on an existing index at all, and the ones that can produce documents indexed under two different analyzers — which is a relevance bug that is very hard to see. The reindex rehearsal is part of the quarterly restore drill here precisely because a rebuild is also relied on as a mitigation, and an untested mitigation is an assumption.

**Two things about this index that are not about consistency but must not be dropped in a reindex.** Every document carries `patient_id` and `care_team_ids`, and every query is wrapped in a filter on them derived from the caller's token. Search authorization is an index-level property, not an application convention — a search engine that can return a document the record layer would refuse *is* the disclosure path around the row-level security. And queries put scope and date clauses in `filter` context, which is cacheable and unscored, with only the user's text in `must`, so the expensive scoring pass runs over a pre-filtered set. A reindex that loses the scope fields is a security incident, not a performance regression, which is why the count-and-sample verification before the alias swap is not optional.

**Knowing a relevance change is an improvement.** This is where most teams go wrong, because relevance is the one area where a change always looks better to the person who made it.

- **Offline first, against a labelled set.** A fixed set of queries with judged results, scored on normalised discounted cumulative gain, mean reciprocal rank, or precision at 10 depending on what the surface is for. The judgements have to come from someone who knows the domain — for oncology notes that is clinical work, not engineering work, and the design says so explicitly. Without judgements there is no measurement, only preference.
- **Look at the losses, not just the average.** A change that improves the mean while destroying a class of query — exact drug-name lookup, staging notation — is a regression for the people who rely on that class. Per-query diffs against the baseline are more informative than the aggregate.
- **Then online, on a share of traffic**, measured on click-through at rank, time to first click, and the abandonment rate. The interleaving approach — mixing results from both rankers into one list — is much more sensitive than a plain A/B when traffic is modest, which it is at 25,000 daily active users.
- **Hold the analysis chain constant while changing one thing.** A synonym set, an analyzer and a query change together give one number and no attribution.
- **Keep the index rebuildable and the model version stamped on every artefact**, so a relevance regression traced to a model version is a reindex and a rollback rather than an archaeology exercise.

**The honest caveat I would add.** Search quality on clinical text depends heavily on a synonym and abbreviation resource — brand versus generic drug names, staging notation — and building and maintaining that is domain work with a named owner, not something an engineer improves by tuning `boost` values. A relevance claim without that owner is not a claim I would make.

</details>

---

## RabbitMQ Operations and Topology

---

### 26. A RabbitMQ cluster loses a node mid-traffic. What actually happens to queues, consumers and unacknowledged messages, and how does that differ between classic, mirrored and quorum queues?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
A classic queue lives on one node, so losing that node makes the queue and everything in it unavailable until it returns. A quorum queue replicates through Raft across a majority, so a confirmed publish survives the loss and a new leader is elected in seconds. Unacknowledged messages are requeued and redelivered in every case, which is exactly why every consumer has to be idempotent. Classic mirrored queues are gone — removed in RabbitMQ 4 — so quorum is not one option among several, it is the supported one.

<details>
<summary><strong>Detailed answer</strong></summary>

**What happens, by queue type.**

*Classic (non-replicated).* The queue is hosted on exactly one node. That node dying means the queue is unavailable; durable messages survive on disk and come back when the node does, transient ones do not. Consumers get a channel or connection error; publishers targeting it fail or, worse, publish into an exchange whose binding leads nowhere. This is the mode that contradicts any claim that an acknowledgement means the data is safe.

*Classic mirrored.* The historical answer — a leader plus mirrors, promotion on failure. It had real problems, notably the risk of confirming a publish that an unsynchronised mirror did not hold, and the expensive resynchronisation of a mirror rejoining. **It was removed in RabbitMQ 4**, and being able to say that rather than describing it as a live option is part of the answer.

*Quorum.* A Raft consensus group across an odd number of members — three, matching the cluster here. A publish is confirmed only once a majority has it on disk. Losing one of three leaves a majority, so the queue stays available; a new leader is elected in seconds, and consumers reconnect and continue. Losing two of three loses quorum and the queue becomes unavailable for writes rather than losing data — it refuses rather than diverges, which is the correct failure for a clinical check-in.

**Unacknowledged messages, which is the part that surprises people.** A message delivered but not acknowledged is not gone: when the consumer's channel dies with the node, the broker requeues it and delivers it to another consumer. So a node loss produces a burst of redeliveries, and the duplicate is *normal* rather than exceptional. Which is why the design's dedupe lives in the database — a redelivered check-in is `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE`, arithmetic rather than a bug — and not in an in-memory set that would have died with the node.

**What the application must have been written to do.**

- **Publisher confirms, mandatory.** Without them `publish()` returns as soon as the frame is written to the socket, which says nothing about replication. With them, unconfirmed publishes are retried by the publisher.
- **Late acknowledgement.** Acknowledge after the work commits, not on receipt, so a crash produces a redelivery rather than a gap.
- **Connection recovery with jitter.** Every client reconnecting simultaneously to the surviving nodes is a thundering herd on a cluster that just lost a third of its capacity.
- **Idempotent handlers against a natural key.** Non-negotiable, as above.
- **Bounded prefetch.** A large prefetch means more messages in flight to redeliver and more memory pinned on the surviving nodes.

**Where it is felt at the edges here.** Patient check-ins arrive over Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")) with Quality of Service ([QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")) 1, so the phone holds the message and retries until it gets a broker acknowledgement — a node loss becomes a slightly later check-in rather than a lost one. That is the whole reason the ingest path can claim a Recovery Point Objective ([RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Maximum acceptable amount of data loss, measured in time since the last recovery point")) of zero from the moment of acknowledgement, and it only holds because the queue behind it is replicated.

**The costs, which I would state rather than wait to be asked.** Quorum queues use more memory and disk than classic ones, every publish pays a majority round trip, and they do not support some legacy features in the same way — per-message priority in particular. There is also a specific risk worth naming: [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle")'s support for quorum queues is comparatively recent and interacts with `task_acks_late`, global prefetch and priority settings, so the Celery and broker versions have to be pinned and integration-tested together. The documented fallback is raw Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")) consumers for the reminder queue, which the topic-exchange design already accommodates. The point being that the risky dependency has an exit rather than being assumed to work.

</details>

---

### 27. How do you design the exchange and routing-key topology for a multi-tenant fan-out, and what happens to a message that matches no binding?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
A topic exchange with a hierarchical routing key ordered from most stable to most specific, and one queue per consumer with its own binding pattern — so adding a consumer never touches the publisher. A message matching no binding is **silently discarded**, and the broker acknowledges it. The only defence is an alternate exchange, which diverts unroutable publishes somewhere visible and turns silent loss into a queue depth you can alert on.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why a topic exchange rather than a queue per consumer.** A publisher never writes to a queue in AMQP — it writes to an exchange, and bindings decide where copies land. A direct exchange matches the routing key exactly, a fanout ignores it, a topic exchange matches wildcard patterns (`*` for one word, `#` for zero or more). The reason that matters is coupling: when a visit note is created, the search projection worker needs to know, the timeline cache invalidator needs to know, and next quarter something else will. If the publisher enqueued directly to named queues, adding the third consumer would mean editing and redeploying the module that owns the clinical record — the highest-risk deployable in the system — to satisfy a downstream feature. With a topic exchange the new consumer declares its own queue, binds its pattern, and the publisher never changes.

**Designing the routing key.** Order the segments from most stable to most specific, because binding patterns are prefix-friendly and the leading segments are the ones consumers will filter on for years. The shape here is `{domain}.{entity}.{event}` — `checkin.recorded`, `visitnote.created`, `appointment.scheduled`, `carerelationship.changed` — with the device ingress path adding a tenant-like segment, `care.checkin.{patient_id}`.

**On putting the tenant in the routing key.** It is the right call when consumers legitimately need per-tenant subscriptions, and the wrong one when it produces unbounded binding cardinality. A binding per tenant across thousands of tenants is a real operational cost — every publish is matched against every binding, and the topology becomes something nobody can reason about. My default is: tenant in the routing key so a consumer *can* filter on it, but consumers bind broadly (`care.checkin.#`) and filter in the handler, with per-tenant bindings reserved for the small number of cases that genuinely need physical isolation — a tenant with a separate retention obligation, or one whose volume must not share a queue with everyone else's. Isolation by queue is a decision to take deliberately for named tenants, not a default for all of them.

**One more topology rule this design holds to.** Celery queues and the domain-event exchange are kept separate on purpose: Celery models *work we schedule and retry for ourselves*, and a topic exchange models *facts we publish for others*. Collapsing them makes every consumer a Celery task and couples independent services to one task registry. That boundary is stated once and honoured, which is more valuable than any individual naming convention.

**A message matching no binding.** This is the important half of the question. RabbitMQ accepts the publish and discards the message, and — critically — returns a publisher confirm, and over MQTT returns a [PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message") for a QoS 1 publish. From the protocol's point of view the broker did accept it; there was simply nowhere to route it. So a mistyped topic, a new patient cohort publishing on an unbound pattern, or a binding lost in a redeploy produces a device that is told the check-in is safe and a message that never existed. **Nothing errors.** The queue depth downstream simply stays flat while users see "recorded" in the application.

The defences, in order:

1. **An alternate exchange on the topic exchange.** Unroutable publishes are diverted into a dead-letter queue whose count is a metric and an alert. This converts silent loss into visible backlog and is the single most important setting on the exchange.
2. **The `mandatory` flag** with a return listener, if the publisher needs to know synchronously. Alternate exchange is the systemic answer; `mandatory` is the per-publish one.
3. **Assert the topology in integration tests.** Bindings are configuration, and configuration with no test is a convention. A test that publishes and asserts a consumer received it catches the mistyped pattern; eyeballing the management interface does not.
4. **Declare bindings in code or infrastructure-as-code**, never by hand, so a redeploy cannot lose one.

**The specific trap in this system, which I would volunteer.** MQTT topics are slash-separated and AMQP routing keys are dot-separated, and the plugin translates between them: `care/checkin/{patient_id}` arrives as the routing key `care.checkin.{patient_id}`. A consumer binding written in MQTT terms — `care/checkin/#` — matches nothing at all, with no error. Alongside that, the plugin publishes to `amq.topic` by default rather than to the exchange the rest of the platform consumes; leaving that at the default means every check-in is published successfully, acknowledged to the device, and consumed by nobody. Three settings carry the reliability claim on that path and not one of them is a default, which is the general lesson: **an acknowledgement is a statement about the broker's obligations, not about your application's**, and closing the gap between "accepted" and "a consumer will see it" is your job.

</details>

---

### 28. The broker hits its memory high-watermark. What does RabbitMQ do to publishers, what does that look like from the application side, and what should the application have been written to do about it?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
It raises a memory alarm and applies flow control by blocking publishing connections — so a consumer problem surfaces as a producer outage. From the application side that is not an error: the connection simply stops accepting publishes, so request threads pile up behind a socket that never returns and upstream timeouts cascade. The application should have bounded prefetch, batched both sides, set an explicit queue overflow policy so backpressure is felt as a fast failure rather than absorbed, and alerted on queue depth long before memory.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** RabbitMQ holds a queue's messages in memory and pages them to disk under pressure, but several things resist paging: messages currently delivered-but-unacknowledged, per-message index metadata that stays resident even when the body is paged, and connection and channel buffers. A consumer with a large prefetch and slow handlers can hold tens of thousands of messages in flight per channel, none of which the broker may release. When the resident total crosses `vm_memory_high_watermark` the broker raises an alarm and blocks publishing connections. There is a disk-space alarm with the same effect, and it is worth knowing both exist because the symptom is identical.

**What it looks like from the application.** This is the part that makes it hard to diagnose. The publisher does not receive an exception — the connection is *blocked*, and a `basic.publish` simply does not complete. Under a synchronous client, the calling thread waits; under load, every request thread doing a publish waits with it, the thread pool exhausts, and the service stops serving *every* endpoint, including ones that never touch the broker. Health checks fail, the orchestrator restarts pods, the new pods immediately block too, and the incident reads as a total application outage whose actual cause is a slow consumer. The AMQP protocol does signal this — `connection.blocked` — and most clients expose a callback for it, which almost nobody registers.

**The shape that gets a broker here.** Millions of small attribute updates published one per attribute is close to the worst case: per-message overhead dominates the payload, the queue index alone becomes enormous, and any consumer doing a row-at-a-time database write will never keep up with a publisher writing in a tight loop. The producer is fast because it is doing nothing; the consumer is slow because it is doing the work. That asymmetry is what fills a broker.

**What the application should have been written to do, in the order I would apply it.**

1. **Bound prefetch.** An unbounded or very high `prefetch_count` is the most common single cause. Set it to a small multiple of what one worker processes concurrently, so unacknowledged messages cannot become an unpageable backlog.
2. **Batch on both sides.** Publish one message describing many changes rather than one per change, and have the consumer write with a bulk statement. The equivalent decision in this platform is the search indexer flushing at 1,000 documents or 5 seconds rather than indexing per document, and in the marketplace it is an import emitting one completion event and re-projecting in batches of 200 rather than 20,000 individual events. Same shape of fix, twice.
3. **Set queue limits with an explicit overflow policy.** `max-length` or `max-length-bytes` with `overflow: reject-publish` makes the producer feel backpressure directly and fail fast, instead of letting the broker absorb the problem until it takes everyone down. Choosing `reject-publish` over `drop-head` is a domain decision: dropping the oldest attribute update may be acceptable; dropping a clinical check-in is not.
4. **Register the `connection.blocked` callback** and expose it as a metric and a circuit-breaker input, so the application can shed load or fail fast rather than piling up threads against a blocked socket.
5. **Publish off the request path.** A publish inside a request handler couples user-facing availability to broker health. The outbox pattern already does this — the request writes a row and commits, and a relay publishes — which means a blocked broker produces a growing outbox rather than failing requests.
6. **Queues that expect long backlogs cost disk, not RAM** — quorum queues with disk-first behaviour rather than anything memory-resident.
7. **Separate the estate.** A high-churn bulk pipeline should not share a broker, or at minimum not a virtual host and node set, with the latency-sensitive path. Colocating them means a bulk backlog blocks interactive publishing, and that is how one feature's load becomes every feature's outage.

**Alert on the leading indicator, not the outcome.** `rmq_queue_depth` and unacknowledged-message count rising for fifteen minutes is the signal; the memory alarm is the consequence. The dashboard here alerts on depth above 10,000 or a sustained rise precisely so the page arrives before flow control does. Consumer processing latency per queue and consumer error rate are the two that tell you *why* the depth is rising.

**And the detection I would add regardless of everything above.** A load test that publishes at a multiple of peak with consumers deliberately throttled, run against a real broker in Docker Compose rather than a mock, so the flow-control behaviour is observed once in a controlled setting instead of discovered in production. A mocked broker cannot block a connection, which means it cannot fail the way the real one does — and that is exactly the failure worth rehearsing.

</details>

---

## Scaling and Load Management

---

### 29. Traffic goes up tenfold and stays there. Walk me through what breaks first, in what order, and which of those you can fix with configuration rather than code.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Connection limits break first, because they are a hard ceiling rather than a gradient — the database connection limit and the pod thread pool saturate before central-processing-unit does. Then the single-writer database, then any queue whose consumers do not scale with its producers, then anything with a per-instance singleton. Configuration buys you the first round — pool sizes, replica counts, autoscaler bounds, prefetch, cache TTLs — and the things that need code are the ones with an architectural cause: an N+1, a synchronous audit write, a scheduler singleton.

<details>
<summary><strong>Detailed answer</strong></summary>

**In order, with why each is where it is.**

1. **Connection pools — application and database.** This is first because it is a cliff, not a slope. The pods scale out, each opens its pool, and the sum crosses the server's connection limit; new connections are refused and the failure is total rather than gradual. Both designs size the sum of every pod's pool maximum to stay under the server limit, which means horizontal scaling has a ceiling that arrives without warning if nobody recomputed it. The configuration fix is smaller per-pod pools plus a connection proxy such as PgBouncer in transaction mode; the trap is that transaction-mode pooling **breaks anything relying on session state** — and in the cancer platform the row-level security context is set per transaction with `SET LOCAL` specifically because a plain session-scoped `SET` would leak one caller's identity into the next caller's query through a reused backend. So "add a pooler" is a configuration change with a correctness precondition, and I would check that precondition before making it.
2. **The database primary.** Reads can go to replicas; writes cannot. In the marketplace catalogue reads already come off a replica, so the read side scales by adding replicas — configuration. In the cancer platform they cannot: every protected-health-information read writes an audit row in the same transaction, a replica cannot write, so patient-facing reads are served by the primary. Ten times the traffic on that path is ten times the write load, and no amount of replica provisioning helps. That is a code-and-design change — batching audit writes, or accepting an audit trail with a hole in it, which for a health record is the worse outcome. Worth naming as the least obvious consequence of a security control.
3. **The thread pool and worker count.** For synchronous handlers, the `anyio` pool is a fixed ceiling shared across every `def` route and dependency; requests queue before they start while the event loop looks idle. Configuration: pool size, worker processes per pod, replica count, autoscaler maximum. The autoscaler maximum is the one people forget — a Horizontal Pod Autoscaler capped at 8 does not care that you need 30.
4. **Queues and their consumers.** Producers scale with request traffic automatically; consumers only scale if something scales them. The marketplace autoscales worker pools on queue depth via a custom metric, which is the configuration answer, but it is bounded by the cluster autoscaler's node range and ultimately by the database the consumers write to. An unbounded backlog then becomes the broker memory problem, where a consumer shortfall surfaces as a producer outage.
5. **Cache and its stampede behaviour.** A tenfold traffic increase on a cache-aside layer multiplies the concurrency hitting each expiry. Without single-flight and probabilistic early expiry, every TTL boundary becomes a synchronised thundering herd at the database. Both are code, and both are already present in the marketplace design precisely because the traffic pattern makes it inevitable.
6. **Singletons.** The Celery beat scheduler is one replica by design, holding a distributed lock so a restart cannot double-schedule. It does not break under load in the same way, but it does not scale either, and the sweep window has to still fit. That is a design review, not a setting.
7. **The edge.** The gateway and front door are a genuine single point of failure for north-south traffic in both designs, accepted deliberately. At ten times load, tier and quota configuration matter, and they are configuration — but the rate limits themselves need re-deriving, because limits calibrated for the old volume will now reject legitimate traffic.

**Configuration versus code, summarised.** Configuration: pool sizes at every layer, replica and worker counts, autoscaler bounds, prefetch, cache TTLs, gateway tier, rate-limit thresholds, `work_mem` and autovacuum aggressiveness. Code and design: N+1 queries that were tolerable at one times and are fatal at ten; synchronous work on the request path; the audit-write coupling; anything with a hidden singleton; and query plans that flip when the table crosses a planner threshold — which is the failure that arrives without any deploy at all.

**The honest framing for these two systems specifically.** Both are sized against modest numbers — about 200 queries per second peak in the clinical platform, about 35 in the marketplace — and both explicitly refuse to buy sharding or a service mesh against numbers that do not require them. Ten times either figure is still well inside what a single well-tuned primary with replicas handles, so my answer is emphatically *not* "shard it". The documented evolution triggers say the same thing in the right order: above about 3,000 sustained writes per second or 4 TB hot, the first move is extracting the append-only audit and check-in tables to their own instance — they are referenced by no foreign key and read by nothing on the request path — and only after that would sharding the record by patient be considered, which is roughly twenty times the modelled load. Knowing the trigger *and* the order is more useful than knowing the techniques.

</details>

---

### 30. An enterprise client sends a bulk load that is orders of magnitude larger than normal traffic. How do you keep it from starving everyone else, and what do you do when shedding load is the only honest option left?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
Isolate it before it arrives: a separate queue and a separate worker deployment so bulk work cannot consume the capacity that serves interactive requests, plus a per-tenant concurrency cap so one client cannot occupy even that pool. When shedding is genuinely the only option left, shed deliberately and by class — reject the bulk work with a retryable error and a clear signal, protect the interactive path — and make sure the client can tell a "come back later" from a "this will never work".

<details>
<summary><strong>Detailed answer</strong></summary>

**The isolation, which is where nearly all the value is.**

1. **Bulk work is never a request.** A 20,000-row import is an upload to blob storage plus a job record, returning a job id immediately. The workspace polls a status endpoint showing row totals, successes, failures and an error digest. Nothing about that occupies a web worker.
2. **A separate queue and a separate worker deployment.** `catalog-import-worker` runs on its own deployment consuming its own queue and autoscales on *that* queue's depth. It shares the codebase but not the request path, so a large import cannot exhaust web-tier capacity and cannot starve the indexing or notification queues either. A single shared worker pool is the failure this prevents, and it is the most common way this goes wrong.
3. **A per-tenant concurrency cap.** At most four concurrent chunks per vendor, held as a Redis semaphore. Separate queues stop bulk work from starving interactive work; this stops *one* tenant's bulk work from starving every other tenant's. Those are two different problems and they need two different mechanisms — which is worth saying, because people implement the first and believe they have solved the second.
4. **Chunking.** The file becomes 500-row tasks. Each chunk is a short transaction, so it does not hold locks, does not pin a snapshot against vacuum, and is individually resumable and observable. It also bounds what a worker drain has to wait for — chunks are sized to finish inside the termination grace period, so a deploy mid-import does not kill work.
5. **Batched downstream effects.** This is the subtle one. A completed import emits *one* event, and the indexer re-projects the affected products in batches of 200. Without that, one import produces 20,000 events, 20,000 cache invalidations and 20,000 upserts — and the damage lands on the read path everyone else is using, not on the import path. The blast radius of bulk work is usually downstream of the bulk work.
6. **Stage, then promote.** Rows land in staging and are validated against the category schema before any live row moves. A malformed file fails wholly at validation with a per-row digest, never half-applied. That matters for starvation too: validation is cheap, and rejecting a bad file early avoids paying the expensive path at all.
7. **Business rate limits, not just infrastructure ones.** Five import jobs per vendor per day, 200 listing writes per vendor per hour. These are quotas expressed in domain terms, and they express something a per-IP limit cannot. They are also the first thing to reach for when a client's "bulk load" is actually a misconfigured integration retrying.

**When shedding is the only honest option.** It happens — capacity is finite and the alternative to shedding is that everything fails, which is worse and less fair. Principles:

- **Shed by class, and decide the classes in advance.** The interactive read path is protected; bulk ingestion is shed first. That ranking should exist in the design, not be improvised during the incident.
- **Shed at the edge, cheaply.** A request rejected at the gateway costs nothing; one rejected after it has taken a connection and a worker thread has already consumed the capacity you were trying to protect.
- **Reject, do not drop.** `429` with `Retry-After`, or a queue policy of `reject-publish` rather than `drop-head`, so the producer knows and can back off. Silent dropping means the client retries harder and the outcome is data loss nobody can account for.
- **Distinguish retryable from terminal.** A client must be able to tell "the platform is busy, come back in ten minutes" from "this file is invalid and will never import". Conflating them means either a permanent failure retried forever or a transient one abandoned.
- **Preserve fairness while shedding.** If shedding is necessary, shed the heaviest tenant's excess first rather than uniformly. Uniform shedding under one tenant's overload punishes everyone for one client's behaviour.
- **Make it visible.** Shedding that is not on a dashboard is indistinguishable from a bug, and the support conversation that follows is much worse.

**And the commercial half, which is a real part of the answer.** An enterprise client sending orders of magnitude more than normal is frequently a conversation rather than an engineering problem: a scheduled window, a negotiated quota, or a dedicated worker pool for that tenant. In a business where a large client's data volume *is* the product, the right answer is sometimes to provision for them explicitly and bill for it, rather than to defend the platform against a customer who is using it as intended. I would want the quota conversation to happen before the incident, and having the per-tenant caps already in place is what makes that conversation possible — you can raise a named number for a named client rather than rebuilding the mechanism under pressure.

</details>

---

## Identity, Authorization and Tenant Isolation

---

### 31. You implemented SCIM 2.0 and Azure Entra ID for clinician account provisioning; can you explain how you structured the JWT validation logic within FastAPI to ensure secure, isolated access between the clinician care-team views and the patient portal?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Two identity planes with two distinct token audiences, and the separation is an audience check that fails closed at the gateway before application code runs — a clinician token presented on a patient route is rejected with a `403` at Azure API Management, and vice versa. The service then re-validates rather than trusting a header, so bypassing the gateway is not bypassing authentication. Beyond authentication, *reach* is enforced in PostgreSQL by row-level security joining through the temporal care-relationship table, so a query somebody forgets to scope returns zero rows instead of another patient's record.

<details>
<summary><strong>Detailed answer</strong></summary>

**The two planes.** Patients self-register into an external tenant and receive tokens with the audience `api://care-platform/patient`. Clinicians and care-team staff exist only in the hospital's Azure Entra ID tenant, are **never** self-service, and receive `api://care-platform/clinician`. The brief's requirement that clinician accounts "stay off the patient portal" is therefore not a user-interface rule — it is an audience value, checked before anything else.

**Where validation happens, and why twice.** The gateway validates signature against a cached JSON Web Key Set (JWKS), issuer, expiry and **audience against the route's plane**. That means a forged or wrong-plane token never reaches the cluster at all. Then `care-core` validates again locally, and this second check is the one I would defend hardest: a service that trusts an `X-User-Id` header set by the gateway has made the gateway the only thing between an attacker inside the network and every record. The edge is a filter, never the authority. Neither check makes a network call per request — JWKS is cached in Redis with a twelve-hour lifetime — which is both a latency decision and, deliberately, the identity-provider outage mitigation: during an Entra ID outage, existing tokens keep validating and active sessions are unaffected, while new sign-ins fail.

**How it is structured in FastAPI.** A dependency on the router, not a check in each endpoint. The patient router carries a dependency requiring the patient audience; the clinician router requires the clinician audience. Declaring it on the router is the design decision that matters: adding an endpoint under that prefix inherits the check rather than needing someone to remember it, and a per-endpoint check is a control that works until the day someone adds an endpoint. The dependency returns a typed principal — subject, audience, roles, plane — so handlers work against a value rather than reaching into the request, and the requirement shows up in the generated OpenAPI document.

Access tokens are short-lived at fifteen minutes with rotated, client-bound refresh tokens, using authorization code flow with Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")). Multi-factor authentication on the clinician side is the hospital's conditional access policy, which the platform does not weaken.

**The part that actually protects data, which is not the token.** Authentication establishes *who*; the harder question is *which patients*. That check — does an active care relationship exist between this clinician and this patient at this instant — lives in the database as row-level security. Each request sets a session configuration parameter with `SET LOCAL` inside the request transaction, and policies on every patient-scoped table join through the temporal `care_relationship` range. Application-layer checks exist too, but they are the second line. The reason this is the strongest control in the design is that it converts the most common class of application bug — a query missing a scope clause — into an empty result set rather than a disclosure.

Three implementation details decide whether that is real, and each is asserted by a test rather than left to review:

- **`SET LOCAL`, never a plain `SET`.** A transaction-mode pooler reuses a backend across requests, and a session-scoped setting would leak one caller's identity into the next caller's query — turning the strongest control into its exact opposite. There is a pooled-connection leakage test for precisely this.
- **The application role is `NOSUPERUSER` and lacks `BYPASSRLS`**, and migrations run as a separate owning role that never serves a request. A role-privilege assertion runs in the pipeline.
- **Policies are written so the patient predicate still reaches the planner**, keeping partition pruning intact on the monthly-partitioned tables. A policy hiding the key behind an opaque subquery silently turns a pruned index scan into a full sweep, so there is an `EXPLAIN` assertion guarding the plan shape.

**SCIM's role in all of this.** `scim-provisioning-svc` implements Users and Groups, with Entra ID as the sole authorised caller, authenticated by its own client credential and network-restricted. Create, update and `active: false` map to clinician and care-team-member rows — and **a deprovisioning closes every open care relationship for that clinician in the same transaction.** Access ends when employment ends, with no platform-side action. That is why a SCIM sync failure is a *paged* alert rather than a ticket: a deprovisioning that did not land means access that should have ended has not, which is a security event rather than an integration hiccup.

**And the seam nobody expects.** The MQTT check-in listener authenticates the *connection*, not each publish, and authorises publishes only to the topic matching the token's subject. Because authentication is per connection, a long-lived mobile connection has to be re-validated against token expiry out of band — so connections carry a maximum lifetime shorter than the refresh window and are forced to re-authenticate. That gap is flagged explicitly in the design rather than assumed away, and it is the kind of detail I would rather raise myself than be caught by.

</details>

---

### 32. Where should an authorization decision live — the gateway, the application, or the database — and how would you prove to an auditor that one tenant cannot see another's data?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
All three, with different jobs: the gateway rejects what is obviously wrong before it costs anything, the application makes the decision it has the context for, and the database enforces the one invariant that must hold even when the application is wrong. Which layer carries the *final* enforcement depends on whether you can set per-request context safely — and I have built it both ways, for reasons I can defend. You prove it to an auditor with a test that fails, not with a document: a cross-tenant read attempted for every repository method and every table, run in the pipeline, plus the audit trail showing every deliberate bypass.

<details>
<summary><strong>Detailed answer</strong></summary>

**The three layers and what each is actually good at.**

*Gateway.* Coarse, cheap, and early. Token signature, expiry, and **audience against the route's plane** — a clinician token on a patient path is rejected before it reaches application code. What it cannot do is anything requiring domain state, because it does not have any, and a gateway rule that pattern-matches on paths stops covering a route the day someone adds one the pattern misses. So: a filter, never the authority.

*Application.* Where the decision with context lives — roles to scopes, account type to router, tenant scope to query. The critical design property is that it is enforced in **one** place rather than per endpoint. In the marketplace that is a session-level filter applied by the repository layer, because a per-endpoint check is a control that works until someone adds an endpoint. Same reasoning as putting the audience dependency on the router rather than on thirty handlers.

*Database.* The backstop for the invariant that must survive an application bug. Row-level security means a query missing its scope clause returns zero rows rather than someone else's record — it converts the most common class of mistake into an empty result instead of a disclosure.

**And the interesting part: I have made opposite calls on this, deliberately.** In the cancer platform, row-level security is the primary reach control, joining through the temporal care-relationship table, with the session context set by `SET LOCAL` inside the request transaction. In the marketplace, row-level security is **deliberately not used** as the primary control — and it is the stronger mechanism, so that needs a reason. The reason is that the catalogue service reads a replica through a pooled connection with a shared role, and setting a per-request session variable through a connection pool is exactly where row-level security silently becomes a no-op or leaks across pooled sessions. Getting that wrong is worse than not relying on it, because it produces a control everyone believes in and nobody tests. The compensating control is tenant filtering in one auditable layer with a test asserting cross-tenant reads return empty for every org-scoped repository method.

That is the general rule I would offer: **put the enforcement at the lowest layer you can guarantee the context reaches correctly, and if you cannot guarantee it, move up and test harder.** A control you believe in and cannot verify is worse than a weaker one you can.

**Proving it to an auditor.** A design document is not evidence. What I would put in front of them:

1. **A test that fails when the control is removed.** For every org-scoped repository method and every patient-scoped table, a test that authenticates as tenant A and attempts to read tenant B's row, asserting an empty result or a `not_found`. Run in the pipeline as a blocking gate. The important property is that the suite has been shown to *fail* — a check that has never failed has not been demonstrated to test anything, so I would deliberately break the filter and confirm the suite goes red before treating a green run as proof.
2. **The pooled-connection leakage test**, specifically. Two requests with different principals through the same pooled backend, asserting the second cannot see the first's rows. This is the failure mode that turns the strongest control into its opposite, and it is invisible in every other test.
3. **A role-privilege assertion.** The application role is `NOSUPERUSER` and lacks `BYPASSRLS`; migrations run under a different role that never serves a request. Asserted in the pipeline, not checked by hand.
4. **The plan-shape assertion.** An `EXPLAIN` check confirming the policy predicate still reaches the planner, which is a performance control but also evidence that the policy is doing what its author thought.
5. **Coverage of the second query surface.** Search is the classic path around the record layer. Every document in the index carries scope fields and every query is wrapped in a filter on them derived from the caller's token — an index-level property, not an application convention — because a search engine that can return a document the record layer would refuse *is* the disclosure.
6. **The audit trail, including the bypasses.** Platform administrators bypass tenant scope explicitly and every bypass writes an audit row. Break-glass access in the clinical system requires a reason string, grants a time-boxed relationship, notifies the patient's team and raises a high-priority event reviewed within 24 hours. An auditor is usually more interested in whether exceptions are recorded and reviewed than in whether they exist.
7. **Detection rules over the audit stream**, each naming a specific misuse rather than a generic anomaly — access outside a care team, volume far above a user's baseline, bulk downloads, a deprovisioning that did not close its relationships, any direct database query from a non-application principal.

**The honest limitation to state.** None of this defends against a compromised application principal or a platform administrator acting maliciously; those are detection-and-review problems, not prevention ones. Saying so is better than implying the controls are stronger than they are — and an auditor who hears "here is what this does not cover, and here is how we would find out" will trust the rest of the answer more.

</details>

---

## Container Images and Delivery

---

### 33. What is in your Dockerfile that a generated one is not — and what would you refuse to put in an image, however convenient?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
A multi-stage build so no compiler or build dependency reaches the runtime image, a non-root user with an explicit numeric id, a base pinned by digest, dependencies installed from a lockfile before the source is copied so the cache layer survives a code change, and a real health check. What I would refuse: any secret, in any form — build argument, environment variable, or a file in a discarded stage — because layers are not private.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the generated one usually gets wrong.**

- **One stage.** The build toolchain — compiler, headers, the package manager's cache — ends up in the runtime image, which triples the size and, more importantly, triples the vulnerability-scan surface. A multi-stage build installs dependencies in a builder and copies only the resulting environment forward.
- **Layer order that defeats the cache.** `COPY . .` before installing dependencies means every source edit reinstalls everything. Copy the lockfile, install, then copy the source. On a pipeline the client expects to run for twenty to thirty minutes, minutes of build cache are worth having.
- **Root.** The default is root, and a non-root numeric user is a one-line change that turns a container escape from trivial into work. It also matters concretely on OpenShift, which assigns an arbitrary user id at runtime — so the image has to be group-writable where it needs to write and must not assume a fixed uid.
- **An unpinned base.** `python:3.12-slim` is a moving target, so the image built today and the one built next month are different artefacts with the same recipe. Pin by digest.
- **No lockfile discipline.** Installing from a loose requirements file means the resolver picks whatever is current. [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects") with a committed lock — the marketplace and clinical services both do this — is what keeps runtime and packages consistent across services, and the drift it removes was previously a deploy-time surprise.
- **No health check, or one that only checks the process is alive.** A readiness probe that returns `200` while the database pool is exhausted will happily send traffic to a pod that cannot serve it. Liveness and readiness need to mean different things.
- **No `.dockerignore`.** The build context ends up carrying the git history, local environment files, test fixtures and the virtual environment — slow, and a disclosure risk.
- **`CMD` in shell form**, so the process is not process id 1 and does not receive `SIGTERM`. That breaks graceful shutdown, which matters where workers are drained rather than killed: stop consuming, finish the in-flight task, exit inside the grace period.

**What else I put in.** Version and commit metadata as labels, so a running container can be traced to a commit without guessing. `PYTHONDONTWRITEBYTECODE` and `PYTHONUNBUFFERED`, the second because unbuffered output is the difference between having logs from a crash and not. An explicit `WORKDIR` and explicit ownership on anything that needs to be writable. And the smallest base that still has a package manager I can patch with — I would rather take a slim Debian base I can update than a distroless one that is marginally smaller and much harder to fix under time pressure.

**What I refuse to put in, and why.**

- **Any secret.** Not as a build argument, not as an environment variable, not as a file deleted in a later layer — the layer persists and `docker history` shows build arguments. Secrets come from the platform at runtime: Key Vault projected as files, reached by workload identity, never baked into an image and never environment variables set at build time. A secret in an image is a secret in a registry, and a registry is a distribution system.
- **Credentials for the package index**, for the same reason. Build-time secret mounts exist precisely so they do not become layers.
- **Anything that makes the image environment-specific.** One image, promoted from staging to production, configured at runtime. An image built per environment means the artefact that was tested is not the artefact that ships.
- **A debugging shell, a package manager left usable, or diagnostic tools "just in case".** They are attack surface, and the modern answer is an ephemeral debug container attached when needed rather than a permanently larger image.
- **`latest` anywhere**, in the base or in a deployment manifest. The deployment references a digest; a mutable tag cannot then be swapped underneath a running cluster, which is a supply-chain property rather than a tidiness one.
- **Test fixtures, sample data, or the test suite.** They inflate the image and occasionally contain something that should not leave the repository.

</details>

---

### 34. How do you make a container image reproducible, and how do you keep base-image pinning from meaning "frozen on a vulnerable base forever"?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Reproducibility comes from pinning every input — base by digest, dependencies by a committed lockfile with hashes, system packages by version — and from removing the sources of nondeterminism that remain, chiefly timestamps and file ordering. The pinning-versus-staleness tension is resolved by automating the *update*, not by loosening the pin: rebuild on a schedule, let a bot propose the new digest, and make the pipeline's vulnerability gate the thing that forces the merge.

<details>
<summary><strong>Detailed answer</strong></summary>

**What "reproducible" actually requires.** Bit-for-bit reproducibility is achievable and rarely what people need; what is needed is that the same source produces a functionally identical image, and that you can say exactly what is inside one you built six months ago.

- **Base by digest**, not by tag. `python:3.12-slim` moves; `python@sha256:...` does not.
- **Application dependencies from a committed lockfile** — Poetry here — resolved once and installed identically everywhere, ideally with hashes so a compromised or republished package fails the install rather than silently changing.
- **System packages pinned by version** where they matter, and the package index snapshot pinned if the distribution supports it. This is the most-skipped one and the most common source of "it built differently today".
- **The build context controlled by `.dockerignore`**, so stray local files cannot enter and change the result.
- **Deterministic timestamps.** `SOURCE_DATE_EPOCH`, or a build tool that normalises them. File modification times are the single largest source of digest differences between otherwise-identical builds.
- **One image promoted across environments**, never rebuilt per environment. If staging and production images are separate builds, the thing you tested is not the thing you shipped, and no amount of pinning fixes that.
- **A software bill of materials generated at build**, so "what is in this image" is a query rather than an archaeology exercise when a vulnerability is announced.

**And then the artefact has to be referenced by digest downstream.** Both designs deploy digest-pinned images only — the pipeline's final act is committing a digest to the GitOps repository, which ArgoCD reconciles. A mutable tag cannot be swapped underneath a running cluster, which makes "what is running" answerable with certainty. Reproducibility that stops at the build and hands a mutable tag to the deployer has given away the property it just paid for.

**The staleness problem, which is the real question.** A pinned digest is frozen by construction, and freezing is the point — right up until it means running a base with a known critical vulnerability because nobody wanted to touch the pin. The resolution is that **the pin is a record of what you chose, not a commitment to never choose again**, and the update has to be automated or it will not happen.

1. **Rebuild on a schedule regardless of source changes.** The marketplace design rebuilds base images weekly. This alone picks up upstream security patches without anyone deciding to.
2. **Automate the digest bump.** A dependency bot opens a merge request moving the base digest forward; it runs the full pipeline; a human reviews a small diff. The decision stays with a person, the *work* does not.
3. **Scan at build and make it blocking.** Image vulnerability scanning and dependency audit are pipeline gates in both designs. A gate that can only warn is a gate that gets ignored, so it has to be able to fail the build — and it has to have been *shown* to fail, or nobody knows whether it works.
4. **Separate "found" from "must fix now" with a policy.** Block on critical and high with a fix available; ticket the rest with a deadline. Blocking on every finding trains everyone to bypass the gate, which is worse than a looser policy honestly applied.
5. **Have an expedited path.** When a serious vulnerability lands, the fix is a digest bump and a redeploy, and that should be the same pipeline everyone uses daily rather than a special procedure. The path you use every day is the one that works under pressure.
6. **Keep the runtime image small enough that the question is tractable.** Fewer packages means fewer findings; a multi-stage build that leaves the compiler behind removes a large share of them permanently.
7. **Track base age as a metric.** "Oldest base image in production, in days" on a dashboard makes drift visible before a scanner makes it urgent.

**The trade-off stated plainly.** Weekly rebuilds mean the running image changes without a code change, which is a small ongoing risk of an upstream regression — and that is exactly what staging plus a smoke test plus a canary is for. The alternative risk, an unpatched base, is worse and grows monotonically. I would take the frequent small change over the rare large one, and I would say so in those terms rather than treating it as obviously correct.

</details>

---

## Security and Data Protection

---

### 35. Threat-model an endpoint that accepts file uploads from an untrusted client. What are you defending against, and in what order do the controls go in?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Against four categories: the file harming the server that receives it, the file harming whoever downloads it later, the upload path being used to exhaust resources, and the storage location being used to reach things it should not. The controls go in from the outside inward — authenticate and authorise, cap size and rate before reading a byte, validate type by content rather than by what the client claimed, quarantine and scan before the file is addressable, and serve it back from an origin where a malicious file cannot do damage.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I am defending against, named concretely.**

- **Malware distributed through us.** A vendor uploads a datasheet, a retailer downloads it, and the platform was the delivery mechanism. Reputationally this is the worst outcome even though the platform itself was never compromised.
- **Stored cross-site scripting.** An SVG or [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers") file served inline from the application's own origin executes with that origin's privileges — it can read the session and act as the user. This is the most likely real exploit and the least dramatic-sounding.
- **Parser exploits and decompression bombs.** Image and document libraries are large C surfaces; a crafted file can crash or exploit the process that parses it, and a zip bomb or a pixel-flood image exhausts memory during thumbnailing.
- **Server-side request forgery and path traversal.** A filename with traversal sequences, or an ingestion step that fetches a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") the file specifies.
- **Resource exhaustion.** Very large files, many concurrent uploads, or many small ones occupying the processing pool.
- **The upload being a data-exfiltration or storage-abuse channel** — using the platform as free file hosting, or writing to a prefix another tenant reads.
- **[XML](https://www.w3.org/XML/ "Extensible Markup Language — Markup format for structured, machine and human readable documents") External Entity and formula injection** in the structured-import case, where the "file" is a spreadsheet or an XML document that a parser will interpret.

**The controls, in the order they go in.**

1. **Authenticate and authorise first.** Anonymous upload is a different and much harder problem. Both these systems only accept uploads from an authenticated principal scoped to an organisation, and the quota is per organisation.
2. **Bound it before reading it.** A declared size in the upload intent, a hard cap enforced at the gateway and the web application firewall, and a per-tenant rate quota — five import jobs per vendor per day in the marketplace. Reject at the edge; a request rejected after it has consumed a worker has already cost what you were protecting.
3. **Keep the bytes off the application entirely.** This is the highest-leverage structural decision. The clinical platform issues a scoped, short-lived Shared Access Signature ([SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Time-limited token granting scoped access to an Azure Storage resource")) so the client uploads directly to blob storage; multi-megabyte scans never touch the pods serving a clinician's timeline. That removes memory exhaustion, parser exposure and bandwidth contention from the API tier in one move — and the metadata write stays transactional because the intent is recorded before the bytes arrive.
4. **Land it somewhere it cannot be reached.** Uploads go to a quarantine container, not to the served location. In the clinical design a document row is not visible to any client until its scan state is clean, and the file is promoted to the documents container only after `fn-blob-ingest` reports a clean scan. **An unscanned file is never addressable**, which is the property that makes the whole thing defensible rather than a race.
5. **Validate type by content, not by claim.** Content-type headers and file extensions are client-supplied. Sniff the magic bytes, enforce an allowlist — never a denylist — and reject anything that does not match what was declared. An allowlist fails closed on a format nobody thought about.
6. **Scan, then transform.** Malware scanning, then re-encoding rather than passing the original through: the marketplace re-encodes images in `fn-media-process`, which strips metadata and defeats most polyglot and parser-exploit files as a side effect. Do the parsing in an isolated, resource-limited, time-limited worker — never in the request path — because a decompression bomb should kill a bounded job, not a web pod.
7. **Strip metadata.** Images carry location and device data; documents carry author and revision history. For patient-uploaded documents in a clinical system that is a privacy obligation, not a nicety.
8. **Control the download path, which is where the stored-[XSS](https://owasp.org/www-community/attacks/xss/ "Cross Site Scripting — Attack that injects malicious script into content viewed by other users") defence actually lives.** Content-addressed paths with a generated identifier, never the client's filename. `Content-Disposition: attachment` so nothing renders inline. A strict `Content-Type` from your own detection rather than the client's. And — the control people miss — **serve user-supplied files from a separate hostname**, so even a successful stored XSS executes in an origin that holds no session and can reach nothing. The marketplace does exactly this: datasheets go out through a dedicated download hostname, so no vendor-supplied file is ever served from the origin hosting the admin console.
9. **Authorise the download too.** Short-lived, scoped read tokens rather than unguessable URLs. An unguessable URL is a bearer token with no expiry and no revocation.
10. **Audit and observe.** Who uploaded what, when, and what the scan concluded; alert on scan failures and on unusual volume per tenant.

**The ordering principle behind the list.** Cheap and certain checks before expensive and fallible ones — a size cap costs nothing and a malware scan costs seconds, so the cap goes first. And every control assumes the one before it failed, which is why "unscanned files are unreachable" matters more than any individual scanner: it is a structural property rather than a detection.

</details>

---

### 36. Personal data is flowing through logs, traces, error reports and a message payload. How do you keep it out of the places it does not belong, and how would you prove it is out?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Mark the sensitive fields once on the model that defines them, and let every output path — log formatter, trace attributes, error serialiser, message envelope — read that same mark, so there is one owner of "this field is sensitive" rather than four. Then make it impossible to regress: a pipeline check that fails the build when a log call passes a model carrying a sensitive field, and a periodic scan of what actually landed in the log store. Proving it means sampling the destinations, not reading the code.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four leaks, because each needs a different mechanism.**

*Logs.* The obvious one, and the easiest to fix structurally. The rule in the clinical platform is absolute: **no clinical free text, no symptom values, no document contents are ever logged.** Every line is JSON carrying `trace_id`, `span_id`, `service`, `module`, `actor_kind` and where applicable a patient identifier — identifiers, never content. A redaction filter driven by the Pydantic model drops known-sensitive fields at the formatter, which is the right layer because it catches every call site including the ones in libraries. The marketplace has the same rule for message bodies, tokens and client secrets.

*Traces.* Easier to forget and just as exposed. Auto-instrumentation captures database statement text and HTTP request attributes, and a statement with a bound literal or a query string with an email address is now in the tracing backend, which frequently has different retention and different access control from the log store. Disable statement-parameter capture, allowlist span attributes rather than denylisting them, and apply the same redaction to the exporter.

*Error reports.* The worst offender, because the whole point of an error report is to capture state. A framework validation error will happily include the rejected value; an exception handler that logs the request body defeats every other control at once. So: never serialise a request body into an error; report the field name and the rule that failed, never the value. Both these systems use problem-detail bodies, and the discipline is that `detail` is a description, not a dump.

*Message payloads.* The one people forget entirely, because a queue feels internal. It is not — it is a store with its own retention, its own dead-letter queue that someone will read during an incident, and its own access control. The pattern I prefer is a thin event carrying identifiers and letting the consumer read what it needs under its own authorisation, rather than a fat event carrying the data. The clinical design does the strong version of this at the model boundary: the NLP service receives diagnosis code, treatment line, stage and locale for page composition — *not* the patient's identity, name or contact details — and extraction calls that must see note text receive the text and a correlation id, never the patient identifier. Data minimisation applied to an internal hop, which is where it is usually skipped.

**Making it one owner rather than four.** The property that makes this maintainable is that "sensitive" is declared once, on the Pydantic model that defines the field, and the log formatter, the span exporter, the error serialiser and the event envelope all read that same declaration. Four independent redaction lists is four things to drift, and the one that drifts is the one you find out about from a regulator.

**Keeping it out permanently.** A rule enforced by review is a rule that holds until a busy week. The clinical platform makes it a build gate: **a continuous-integration check fails the build if a log call passes a model containing a field marked sensitive.** That turns a convention into a control. Alongside it: a linter banning direct formatting of request bodies into log calls, and default-deny allowlists for span attributes — because a denylist is a list of the leaks you thought of.

**And the distinction that keeps the whole design honest.** Audit is a database table, never a log stream. Logs are for operators; audit is for the regulator. Conflating them means log retention policy silently becomes audit policy — and it also means the thing you most want to redact aggressively and the thing you must retain immutably for seven years are the same pipeline, which is an impossible position. Separating them lets logs be ruthlessly minimal.

**Proving it is out.** Code review proves intent; only the destination proves outcome.

1. **Sample the log store and search it.** Pattern-match for the shapes that should never appear — identifier formats, email addresses, free-text fields, token prefixes — as a scheduled job with an alert, not a one-off audit. This is the check that finds the leak nobody anticipated, which is by definition the one the allowlist missed.
2. **Do the same in the tracing backend and the error reporter.** Different systems, different teams, frequently different retention. A control verified in one and assumed in the others is unverified.
3. **Inspect a dead-letter queue's contents** as part of the exercise, since that is a message store with a long tail and human readers.
4. **Test the redaction with a known-positive and a known-negative.** Log a model with a sensitive field populated and assert it is absent from the output; log one without and assert the surrounding structure is intact. A redaction filter that has never been shown to redact is an assumption — and the failure mode of a broken one is silence, which looks exactly like success.
5. **Verify the build gate can actually fail.** Introduce a violating log call on a branch and confirm the pipeline goes red. A gate that has only ever passed has not been demonstrated to do anything.
6. **Check retention and access on each destination**, because "it is only in logs" is not a defence if the logs are retained for two years and broadly readable. Residency too — for the clinical system, all resources and all backups sit in a single region with no cross-border transfer, and a telemetry backend outside that region would breach it as surely as a database would.
7. **Prove deletion works end to end.** A data subject access request or an erasure request has to reach every destination, and a personal identifier sitting in a log store nobody enumerated is the reason erasure requests are hard. The right answer is usually that logs carry pseudonymous identifiers only, so there is nothing to erase there — but that has to be true, not assumed.

**One honest note on scope.** Erasure and retention genuinely conflict, and in both these systems retention wins for a defined class of data — a medical record is retained under health-records law, and a vendor's record of a commercial negotiation is not the individual's to delete. Those positions are stated to the user at consent and are defensible; what is not defensible is promising deletion and quietly not performing it. Keeping personal data out of the peripheral systems in the first place is what makes the remaining conflict small enough to explain.

</details>

---

## Distributed Data and Resilience Patterns

> **The questions in this section were generated, not supplied.** The supplied set leans on the transactional outbox in nine separate answers without ever asking about it, and never raises sagas, read models, event sourcing or the failure-handling patterns around a degrading dependency. These are the questions an interviewer working through the same material would reach for next.

---

### 37. The outbox pattern appears all over your designs. What does it actually guarantee, what does it not guarantee, and what does it cost to run?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It guarantees that a state change and the intent to publish it commit or fail together, which removes the dual-write failure entirely. It does not guarantee exactly-once delivery, global ordering, or that any consumer succeeded — only that the event will eventually be published at least once. It costs an extra write per business write, a relay to operate and monitor, a table that grows without bound unless you prune it, and seconds of lag.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it guarantees, precisely.** The event row is inserted in the same transaction as the state change, so there is no window in which the fact exists and the intent to publish it does not. That is the whole guarantee, and it is narrow: it is a statement about *durability of intent*, not about delivery. A relay then reads unpublished rows, publishes them, and marks them published. Because publication is a separate step that can be retried, delivery is at-least-once and never zero-times.

**What it does not guarantee, which is the more useful half.**

- **Not exactly-once.** The relay can publish and then crash before marking the row, so the same event goes out twice. Consumers must be idempotent — against a natural key in the system of record, not against an in-memory set. The projection worker in the marketplace upserts keyed on the product and ignores an event whose source revision is older than the row's current value, which makes both redelivery *and* out-of-order delivery no-ops.
- **Not globally ordered, and this is where the subtle bug lives.** A relay that polls `WHERE id > :watermark ORDER BY id` looks correct and is not: identifiers are assigned when a row is inserted, but rows become *visible* when their transaction commits. Two concurrent transactions can commit in the opposite order to their identifiers, so a relay that has advanced its watermark past the higher id will never see the lower one when it commits a moment later. The event is silently lost forever. The defence both these designs use is to avoid a watermark entirely: the relay's only query is a partial index on `WHERE published_at IS NULL`, so a row that becomes visible late is still picked up on the next sweep regardless of its identifier. If you do need a watermark, it has to lag behind the oldest in-flight transaction rather than the highest identifier.
- **Ordering is at best per-aggregate**, and only if you arrange for it: one consumer per aggregate key, or a routing key that keeps an aggregate's events on one queue. With competing consumers on a shared queue, two events for the same entity can be processed concurrently and out of order. Designing handlers to be order-independent is cheaper than enforcing order, which is why the ignore-if-older comparison exists.
- **Not delivery, and not success.** The event being published says nothing about a consumer having applied it. That is a separate concern with its own metric — projection lag measured from event time to projection time.
- **Not freshness.** There is a relay interval plus a broker hop plus consumer processing, and the result is seconds. If a reader cannot tolerate that, the answer is to read the source of truth directly rather than to tune the relay, which is exactly what the vendor workspace does.

**Running the relay.** Poll on the partial index, claim rows with `FOR UPDATE SKIP LOCKED` so several relay instances can run without double-publishing or blocking each other, publish in batches, mark published. Publisher confirms are mandatory — without them the relay marks a row published when the frame hit the socket, which reintroduces the loss the pattern exists to prevent. And the relay needs a liveness signal of its own: a stopped relay is completely silent, so the alert is on `outbox_unpublished_age_seconds`, not on an error rate.

**What it costs, stated plainly.**

- **An extra write on every business transaction**, which is real write amplification on a hot path and shows up in write-ahead log volume as well as in latency.
- **Unbounded table growth.** Published rows have to be pruned or partitioned, and a forgotten outbox table quietly becoming the largest thing in the database is a common outcome. The retention decision is part of the pattern, not an afterthought.
- **A component to operate.** The relay is a thing that can be down, and its failure is invisible without instrumentation.
- **Lag, and therefore a lag budget.** Which then has to be stated and defended — the search freshness budget in the clinical platform is composed as relay plus bulk flush plus refresh interval precisely because tightening one alone buys nothing.
- **Discipline.** Every writer has to remember to write the outbox row. A developer who writes state and publishes directly has bypassed the whole mechanism with no error. That is a code-review and lint concern, and it is the pattern's real weakness.

**The alternative worth naming: Change Data Capture ([CDC](https://en.wikipedia.org/wiki/Change_data_capture "Streams row-level changes out of a database by reading its transaction log")).** Read the write-ahead log directly and derive events from row changes. It removes the extra write, removes the growth problem, and removes the discipline problem entirely — nothing can bypass it, because it observes the log rather than trusting the application. What it costs is a connector to operate, a replication slot that retains write-ahead log if the consumer stalls — which will fill the primary's disk and take the database down, a genuinely dangerous failure mode — and events shaped like table rows rather than like curated domain facts, which couples every consumer to your schema. My default is the outbox, because a hand-written event is a published contract and a row diff is an implementation detail leaking. I would move to CDC when the number of writers makes the discipline unenforceable, and I would put the replication-slot lag on a pager the same day.

</details>

---

### 38. A business operation spans three services and cannot be one transaction. How do you make it eventually correct, and what happens when a compensating step itself fails?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
A saga: a sequence of local transactions, each committing independently, each with a compensating action that semantically undoes it. Compensation is not rollback — you do not delete the charge, you write a credit. When a compensating step fails, it must be retried indefinitely and idempotently, because a compensation cannot itself have a compensation without recursing; and where the effect genuinely cannot be undone automatically, the honest design escalates to a human rather than pretending.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape in front of me.** Opening a connection request in the marketplace is exactly this: the connection is created, a billing charge accrues on the vendor's account, the shortlist item flips to `contacted` in the retailer's private working set, and the vendor is notified. Four effects, three services plus a Function, no shared transaction. Each is driven off `connection.requested`, published through the outbox so the first step's commit and the intent to do the rest are atomic.

**Making it eventually correct.**

- **Each step is a local transaction that commits on its own.** No step waits for a later one.
- **Each step is idempotent**, because delivery is at-least-once. Here that is carried in the schema: `UNIQUE (retail_group_id, idempotency_key)` on the request, and `UNIQUE (connection_request_id) WHERE kind = 'connection'` on the charge, which makes "a connection bills at most once" a property of the database rather than of everyone remembering to check.
- **The saga's state lives in a table, not in memory.** Which step has completed, what it returned, what remains. That is what makes it resumable after a crash and queryable during an incident, and it is the difference between a saga and a sequence of hopeful event handlers.
- **Compensation is semantic, not syntactic.** You cannot roll back a committed transaction in another service. You write an opposing fact: a credit against a charge, a `withdrawn` status against a request, a correction notice against a sent notification. For anything financial that is not a workaround, it is the requirement — an accounting record you can delete is not an accounting record.

**Ordering the steps, which is the design decision that matters most.** Classify every step as compensatable, pivot, or retriable. Compensatable steps can be undone; the pivot is the point of no return; everything after the pivot must be retriable until it succeeds, because there is no way back. Then order the operation so the irreversible step happens as late as possible. Sending the vendor an email is effectively a pivot — you cannot unsend it — so it goes after the charge and the status change, not before. Getting that ordering wrong is what produces the situation where the only remaining option is an apology.

**When a compensating step fails.** This is the question that separates people who have read about sagas from people who have run one.

1. **Compensations must be retriable forever and idempotent.** A compensation cannot have its own compensation without infinite regress, so the only correct response to its failure is to try again. Exponential backoff with jitter, no retry budget cap, no give-up.
2. **After bounded attempts it goes to a dead-letter queue with a page, not a ticket.** A stuck compensation means the system is in an inconsistent state that it knows about and cannot fix. That is exactly the class of thing a human must see.
3. **The saga state row records where it stopped**, so a human or a replay resumes from the failed step rather than re-running the whole thing.
4. **Some effects genuinely cannot be compensated automatically.** A notification already delivered, a file already downloaded by the counterparty. The compensation for those is a task for a person — a correction message, a support contact — and the design should name that explicitly instead of leaving an impossible retry loop in the code. Writing "compensate: send correction email to vendor contact" is a better design than writing a handler that will never succeed.
5. **Guard against the compensation racing the forward step.** A compensation arriving before the step it undoes has been observed must be safe — which again means idempotent, keyed, and state-machine-driven rather than blind.

**Sagas have no isolation, and you have to plan for it.** Other readers see intermediate states: the charge exists while the connection is still being set up. The countermeasures are semantic locks — a `pending` status that readers understand — commutative updates, and re-reading a value before acting on it. The marketplace accepts one of these openly: a category manager may briefly see a shortlist item still marked `candidate` while a connection is already open, because the update is asynchronous and idempotent, and the authoritative signal in the interface is the connection list itself. Naming the anomaly and deciding it is acceptable is the correct treatment; the failure is not noticing it exists.

**And the thing I would say before any of this.** A saga is what you use when you cannot have a transaction — it is strictly worse than one, and the first question is whether the boundary is real. The clinical platform's SCIM deprovisioning closes every open care relationship for a departing clinician **in the same transaction**, because access ending when employment ends is a security property that must not be eventually consistent. That was affordable only because identity writes stayed in one database, and that is a large part of why the extraction there was deployment-level rather than data-level. If an operation has an invariant that cannot tolerate an intermediate state, the right answer is usually to move the boundary, not to write a saga across it.

</details>

---

### 39. Choreography or orchestration — how do you choose, and what does each cost you when you have to debug it at three in the morning?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Choreography — services reacting to published facts with no coordinator — when the reactions are genuinely independent and adding a consumer should not touch the publisher. Orchestration — one component that knows the whole sequence — when the sequence itself is the business logic, when order or compensation must be coordinated, or when someone needs to ask "where did this get to". The debugging cost is the mirror image: choreography has no single place that describes the flow, and orchestration has a coupling point that every change goes through.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction I actually use** is not about technology, it is about where the knowledge of the sequence lives. In choreography, no component knows the flow; each knows only what it reacts to, and the flow is an emergent property of the bindings. In orchestration, one component holds the sequence explicitly and tells the others what to do.

The clinical platform states the boundary as a rule rather than deciding case by case, and I think that is the right way to hold it: **Celery models work we schedule and retry for ourselves; a topic exchange models facts we publish for others.** Collapsing them makes every consumer a Celery task and couples independent services to one task registry. So reminder sweeps, page generation and index projection are orchestrated work with owners, deadlines and retry policies; `checkin.recorded` and `visitnote.created` are facts published to whoever cares. The same seam exists in the marketplace: Celery moves work between Python processes we own, Service Bus moves events across a boundary, and the notification split follows it exactly — the worker decides *whether and what* to notify, which is a policy decision needing database context, and the Function performs *delivery*. One owner per step, no overlap.

**Choose choreography when:** the consumers are independent of each other; adding one should not require touching or redeploying the publisher; the publisher genuinely should not know who reacts; and no consumer's failure changes what another consumer should do. The concrete payoff in the clinical platform is that the publisher of a visit note is the module that owns the clinical record — the highest-risk deployable in the system — and a new downstream feature must never require redeploying it.

**Choose orchestration when:** the order of steps is part of the business rule; a step's outcome decides whether a later step happens; compensation has to be coordinated across steps; you need to query the state of an in-flight operation; or the flow has a timeout as a whole rather than per step. Anything shaped like the saga in the previous question wants an orchestrator, because "which step are we on" has to be a row somebody can select.

**Debugging choreography.** There is no file you can open that describes the flow. Answering "what happens when a listing is published" means reading the bindings, the subscriptions and the consumers, and the topology *is* the program. The specific failure mode is the one nobody sees: a binding that matches nothing. The broker accepts the publish, returns a confirm, and discards the message — so the defences are structural rather than diagnostic. An alternate exchange turning unroutable publishes into visible backlog, an event catalogue that is maintained as a real artefact listing every event with its emitter and consumers, binding topology declared in code and asserted in integration tests rather than eyeballed in a management interface, and trace context propagated through message headers so one trace spans publish through project through invalidate through notify. Without that last one, a failure between a worker and a Function is two unconnected half-stories.

**Debugging orchestration.** Much easier — the sequence is in one place, the state is a row, and "where did this get to" is a query. What you pay is coupling: the orchestrator knows every participant, so every new step is a change to it, and it becomes a deployment bottleneck and a single component whose failure stalls every flow it drives. It also drifts toward becoming the place all the business logic accumulates, at which point the services around it are anaemic and you have a distributed monolith with extra network hops.

**The anti-pattern worth naming.** Choreography where the services are not actually independent — every consumer must be deployed in lockstep because event shapes are coupled and a change to one ripples through all of them. That is a distributed monolith wearing an event-driven costume: you have paid every cost of asynchrony and kept every cost of coupling. The tell is whether you can add a consumer without coordinating a release, and whether you can change an event's shape additively. If the answer to either is no, the choreography is nominal.

**What I would do in practice**, and have: choreograph the fan-out of facts, orchestrate anything transaction-shaped, keep the rule written down once so it is not relitigated per feature, and instrument both the same way — because the observability requirement is identical and it is the only thing that makes either debuggable at three in the morning.

</details>

---

### 40. When is a separate read model worth building, and when is it over-engineering?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Worth it when the shape the reads want is genuinely different from the shape the writes want — a union across five tables, faceted filtering with full text, a capability the write store does not have — or when read and write volumes differ by orders of magnitude. Over-engineering when the read shape is the write shape with a join, when both models still hit the same tables anyway, or when the pattern is adopted for its name rather than against a measured problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**Both systems have one, and neither calls it Command Query Responsibility Segregation (CQRS)**, which I think is the healthy way round. In the marketplace, `product_listing_facets` is a denormalised table written only by the indexer and read only by the catalogue service: it copies vendor, status and publication time from the product table *deliberately* so the hot query touches exactly one relation and never joins. In the clinical platform, `es-clinical` is the same idea in a different store — a search index fed from the outbox, holding no data of its own, fully rebuildable from source.

**What justified them, concretely.**

- **The read shape differs from the write shape.** Faceted search over free text plus array containment plus a category-specific attribute is not a query you can serve well from a normalised authoring model. Neither is a chronological timeline unioned across appointments, prescriptions, visit notes, documents and check-ins.
- **The write store cannot do it at all.** Scoring, highlighting and analyzer-driven relevance are not things a relational full-text index gives you at 2.4 million notes with per-clause filtering. That second store was bought against a measured latency target, not a preference — and the design says so.
- **The volumes are asymmetric.** The catalogue is overwhelmingly read; the authoring surface is a trickle by comparison. Optimising one against the other's constraints costs the wrong side.
- **Write-path isolation.** Maintaining the search vector in the indexer rather than in a database trigger keeps text-search maintenance out of the vendor's publish transaction. The write path should not pay for a value only the read path needs.

**What you pay, every time.**

- Eventual consistency, and therefore a stated lag budget with an alert, because a dead projection is silent — listings simply stop becoming searchable and nothing errors.
- A projection to operate and a reconciliation job to repair it.
- A second place to get authorization wrong. Every document in the clinical index carries scope fields and every query filters on them, because a search engine that can return a document the record layer would refuse *is* the disclosure path.
- The read-your-writes problem for whoever just wrote. Both designs route around it rather than shrinking the lag: the vendor workspace reads the primary and the document store directly, never the projection and never the cache, so vendors get read-your-writes while retailers get the fast, slightly stale read model. That routing decision is the part people forget, and it is usually cheaper than chasing the lag down.

**When it is over-engineering.** When the read query is the write model plus a join and an index — add the index. When the "read model" lives in the same database and is populated synchronously in the same transaction — you have paid the denormalisation cost and bought none of the isolation. When it is really a cache with a projection pipeline bolted on, which is more moving parts than a cache with a sensible key. When the team cannot yet operate the lag monitoring and reconciliation the pattern requires, because an unmonitored projection is a silent corruption generator. And when the argument for it is that the architecture should be CQRS, rather than that a specific query is too slow or too awkward for a specific reason.

The test I would apply: name the query, name why the write model cannot serve it, and name the number it has to hit. If all three exist, build the read model. If the answer is "it seems cleaner", do not.

**One distinction worth being crisp about, because they are routinely bundled:** separating the read and write models has nothing to do with event sourcing. You can have either without the other, and conflating them is how a team ends up adopting two large patterns when it needed part of one.

> **Footnotes:**
> - **CQRS (Command Query Responsibility Segregation):** Separates the model used to change state from the model used to read it, so each can be shaped and scaled for its own job. It says nothing about how the write model stores its data, and in particular does not imply event sourcing.

</details>

---

### 41. Would you event-source either of these systems? Argue it either way.

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
No — and the interesting part is that the clinical platform looks like it wants to be event-sourced and still should not be. It already has an immutable seven-year audit table, temporal validity ranges and immutable versioned content, which delivers most of the auditability people reach for event sourcing to get, at a fraction of the cost. I would use the ingredients without adopting the pattern, and I would reserve event sourcing for a domain where the sequence of changes genuinely *is* the product.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it is, stated so the trade-off is visible.** Current state is not stored; it is derived by folding an append-only log of events. Nothing is updated or deleted, ever. Reads run against projections built from that log, and rebuilding a projection means replaying history.

**The case *for*, in the clinical platform specifically, because it is genuinely strong on the surface.** Every read and write of patient data already writes an immutable audit row retained for seven years. Clinician access is modelled as a temporal range with a start and an end rather than a flag that gets overwritten, so history is not lost. Education pages are immutable versions, and what a patient was shown is pinned to an exact version so a later revision never silently changes the record of what advice they were given. Regulators ask "who saw what, when, and what did it say at the time". That is a domain where history is a first-class obligation, and event sourcing answers all of it natively.

**The case *against*, which is the one I would make.**

- **The obligation is already met by much smaller machinery.** An append-only audit table with update and delete revoked from every application role plus a blocking trigger, partitioned monthly and archived to immutable storage, satisfies the regulator. Event sourcing would deliver the same property and also restructure every read in the system.
- **Every query becomes a projection.** A clinician opening a timeline mid-consultation needs it in under 250 milliseconds, and "fold five years of events" is not that. So you build projections — which means you have taken on the lag, the rebuild and the reconciliation cost of a read model for *every* entity rather than for the two that needed it.
- **Constraints get much weaker.** The strongest correctness tools here are relational: a unique key on patient and date making a redelivered check-in arithmetic rather than a bug, an exclusion constraint on the temporal care relationship, a partial unique index making "a connection bills at most once" a property of the schema. In an event-sourced model those invariants move into application code and aggregate boundaries, where they are enforced by everyone remembering.
- **Schema evolution becomes permanent.** You can never delete an old event shape. Code written in year five must still correctly replay an event written in year one, which means upcasters, version tolerance and a growing body of compatibility code that can never be removed. That is a very different maintenance profile from a migration you land and forget.
- **Erasure conflicts head-on with immutability.** The right to erasure against an append-only log has one real answer — crypto-shredding, encrypting per subject and destroying the key — and that is a key-management project with its own failure modes, not a checkbox. The platform already has a genuine retention-versus-erasure conflict it resolves deliberately; adding an immutable event log makes the resolvable part unresolvable too.
- **Operational and cognitive cost.** It changes how everyone reasons about the system, and this is a client that values thoroughness over speed with leads who review closely. A pattern the whole team must learn before anyone can review a change honestly is a large bet.

**What I would take from it instead — and both designs already do.** Append-only where the record must be immutable. Temporal validity ranges instead of overwriting a flag. Immutable versioned artefacts pinned by identity and version. An outbox so integration events are a durable record rather than a side effect. That is event sourcing's *hygiene* applied where it pays, without making every read a fold.

**Where I would say yes.** A domain where the log is the product rather than an audit of it — a ledger, a trading or settlement system, anywhere you must reconstruct precisely why a decision was made from the state as it was at that instant, or where regulators require replay rather than records. And even then I would want a team that has operated projections before, because the pattern's failure mode is a rebuild you cannot complete inside a maintenance window.

**The meta-point I would make in the room.** Being able to argue *against* a pattern you understand is worth more than being able to list its benefits. Both these systems refuse things deliberately — no sharding at 200 queries per second, no service mesh at nine workloads, row-level security explicitly declined in one of them because pooled connections would make it a no-op — and each refusal is recorded with the condition that would reverse it. Event sourcing belongs on that list, not on the roadmap.

</details>

---

### 42. A downstream dependency starts degrading. Walk me through timeouts, retries, circuit breakers and bulkheads — and how each one can make the situation worse.

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Timeouts first, because without a bound nothing else works — an unbounded call is an unbounded resource hold, and the budget has to shrink as you go down the call chain. Retries turn a struggling dependency into a dead one if they are unjittered, unbudgeted or applied to non-idempotent calls. Circuit breakers fail a healthy dependency when the threshold is wrong or the breaker is shared across tenants. Bulkheads are the one that rarely backfires, and they are the one people implement last.

<details>
<summary><strong>Detailed answer</strong></summary>

**Timeouts, and they genuinely come first.** A call with no timeout holds a thread, a connection and a slot in whatever pool it came from, indefinitely. Under load that is how one slow dependency consumes an entire service. Two details people miss:

- **The budget must decrease down the chain.** If the client waits 5 s, the gateway 5 s and the service 5 s, an inner retry outlives the outer deadline and does work nobody is waiting for. Each hop should get the remaining budget minus a margin, propagated explicitly.
- **Connect and read timeouts are different settings**, and only setting one leaves the other unbounded.

The marketplace has exactly one synchronous call that crosses a service boundary, and it carries a 250 ms timeout. That is not a tuning value; it is a design constraint — keeping to one sync hop with a hard bound is why a degrading peer cannot cascade.

**Retries, and how they make it worse.** A retry is a load multiplier aimed at something already struggling. Three retries at three layers is twenty-seven calls for one request, and the dependency that was at 90% capacity is now at 300%. The failure modes:

- **No jitter.** Everyone backs off by the same amount and retries in sync, so the herd arrives together forever. Exponential backoff *with jitter* is not an optimisation, it is the mechanism.
- **No budget.** A retry budget caps retries at a fraction of total traffic — say 10% — so a broad outage cannot multiply load at all. Without it, retry volume scales with failure rate, which is exactly backwards.
- **Retrying the wrong things.** Only idempotent operations, only on retryable classes. Retrying a `400` or a `422` can never succeed. Retrying a non-idempotent `POST` without an idempotency key is how a double charge happens — which is why the key is mandatory on mutating requests here, and why the guarantee behind it lives in a unique constraint rather than in a cache.
- **Retrying something that already succeeded.** A timeout does not mean the work did not happen. That ambiguity is the whole reason the idempotency machinery exists.

**Circuit breakers.** Track failures against a dependency; above a threshold, stop calling it and fail fast; after a cooldown, let one probe through and close if it succeeds. What it buys is that a dead dependency stops consuming your resources and stops adding load to its own recovery. How it makes things worse:

- **A threshold tuned too tight** trips on a blip and takes out a dependency that was fine, converting a slow request into a total outage for that path.
- **Shared breaker state across tenants or endpoints.** One tenant sending requests that legitimately fail opens the circuit for everyone. Breakers should be scoped to what actually shares a failure mode.
- **Unlimited half-open probes.** Letting a burst through on recovery re-kills the dependency immediately. One probe, then decide.
- **No fallback behind it.** A breaker without a defined fallback just converts a slow error into a fast one, which is better but not much.
- **Invisible state.** A breaker nobody monitors is a silent outage — everything is fast and everything is wrong. Its state belongs on a dashboard as a first-class metric.

**Fallbacks, and the decision that goes with them.** Each one needs an explicit fail-open or fail-closed choice with a reason. The marketplace's single sync hop fails *open*: on timeout it permits the connection rather than blocking it, because refusing a legitimate connection request costs the marketplace more than an occasional duplicate thread — and the duplicate is caught by a unique constraint anyway. The safety net is in the schema, which is what makes failing open defensible rather than reckless. In the same system, business rate limiting fails **closed for writes and open for reads** when the cache is unavailable. Two different answers, each derived from what the control is protecting.

**Bulkheads, which are the underrated one.** Separate resource pools so one dependency's slowness cannot consume everything. Concretely, in these systems: import workers on their own deployment and their own queue so a bulk load cannot starve indexing or notifications; a per-vendor concurrency semaphore so one tenant cannot occupy even that pool; and the recommendation to keep a high-churn bulk pipeline off the broker serving the latency-sensitive path, because a bulk backlog otherwise blocks interactive publishing. Separate connection pools per dependency belong in the same category. Bulkheads rarely backfire — the cost is under-utilisation, since a partitioned pool cannot lend capacity — and that is usually a price worth paying for a blast radius you can predict.

**The failure I have seen most.** All four added at once, none measured, and the aggregate timeout ends up longer than the client's — so the client gives up and retries while the server is still patiently working through its own retry schedule. The order I would actually apply them: bound everything with a timeout, make the operation idempotent, add jittered and budgeted retries, add a breaker with a fallback and a dashboard, and partition the pools. Then load-test with the dependency deliberately degraded — not down, *slow*, which is the harder and more common case — because a mock cannot be slow in the way a real dependency is.

</details>

---

## Entra ID, SCIM and Token Validation

> **The questions in this section were generated, not supplied.** The supplied set asks one question about SCIM and token isolation, and the rest of the case owns the basics — what SCIM 2.0 is, the audience split, the authorization-code flow, refresh rotation, the identity-provider outage. These go at the layer below that: the protocol details that break in production, what Entra ID actually does as a client, and what a token from another organisation's directory does and does not entitle someone to.

---

### 43. Walk me through implementing SCIM 2.0 `PATCH`. Why is that the part that breaks, and how do you keep it correct when two updates for the same user arrive at once?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
`PATCH` breaks because it is the only part of SCIM that is a small expression language rather than a document swap: each operation carries an `op`, an optional `path` that can contain a filter, and a `value` whose shape depends on both. Getting multi-valued attributes right — emails, group members, roles — is most of the work. Concurrency is handled by serialising per directory object rather than by optimistic locking, because the client will not resolve a version conflict for you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why `PATCH` and not `PUT`.** `PUT` replaces the whole resource, so any attribute the client omits is semantically deleted — which means a client that does not send every attribute silently destroys data. `PATCH` sends only what changed, which is both safer and what Entra ID actually prefers to send. So `PATCH` is the path that carries almost all real traffic, and it is the one worth building carefully.

**The three operations, and where each goes wrong.**

- **`replace` with no path** — the value is an object whose keys are merged into the resource. The common mistake is treating it as a full replacement.
- **`replace` with a simple path** — `{"op":"replace","path":"active","value":false}`. This is the disable path and therefore the most security-relevant single message the service receives.
- **`add`** — on a single-valued attribute it behaves as replace; on a multi-valued attribute it *appends*. Implementing `add` as assignment for both is the classic bug: a user's second email address overwrites the first.
- **`remove`** — requires a path, and on a multi-valued attribute the path usually carries a filter: `path: members[value eq "abc"]`. So the implementation needs a small filter parser, not a dictionary lookup. Treating `members` as a scalar and clearing the whole collection is how a single group-membership removal empties a care team.

**The details that are easy to miss.**

- **Attribute names are case-insensitive** per the specification. Matching them case-sensitively produces intermittent failures that look random.
- **`externalId` is the client's identifier and `id` is yours**, and they are not interchangeable. Here the clinician row carries both — `entra_object_id` and `scim_external_id`, each unique — because the directory's object identifier is the stable join key and the SCIM identifier is what appears in request paths.
- **Type coercion.** Values that arrive as a string where the schema says boolean are a known class of client quirk. Coerce deliberately and reject what you cannot interpret rather than treating a truthy string as true.
- **`active: false` is a soft delete**, and it is the deprovisioning signal. Treating it as an ordinary attribute update rather than as a lifecycle event is how access outlives employment. Here it maps to closing every open care relationship for that clinician **in the same transaction** — the whole point of the integration.
- **Return the updated resource**, or `204` consistently, and set `ETag` if you claim to support versioning. Claiming versioning support in `ServiceProviderConfig` and then ignoring `If-Match` is worse than not claiming it.
- **Error bodies matter**, because the client branches on them. A `409` for a duplicate `userName`, a `400` with a `scimType` of `invalidValue` for a malformed patch, a `404` for an unknown identifier. A generic `500` for a bad request causes the client to retry forever.

**Concurrency, which is the second half of the question.** Two updates for the same user can arrive concurrently — a role change and a disable, or a retry overlapping the original. Last-write-wins on the whole row is wrong here: a disable being overwritten by an in-flight role update means an account that should be closed is open, which is a security failure rather than a data-quality one.

Optimistic concurrency via `ETag`/`If-Match` is the specification's answer, and it is the wrong tool in this case because the client is not going to re-read and merge on a `412` — it will escrow the record and retry it later, if at all. So this design serialises instead: a Redis lock keyed on the directory object identifier (`lock:scim:{entra_object_id}`) with a short expiry, held for the duration of the operation. Concurrent updates for *one* user queue; updates for different users run fully parallel, so the throughput cost is nothing at this volume. A short expiry matters — a lock that outlives a crashed pod blocks that user's provisioning until it expires.

Underneath the lock the operation is still idempotent and still transactional: the patch is applied and any lifecycle consequence — closing care relationships — commits with it. So a redelivery after a lock expiry converges rather than double-applying.

**And the constraint that keeps the blast radius small.** This service writes the identity schema only — clinician rows, care-team membership, and the care relationships a deprovisioning closes. It never touches the record, diary or content schemas. That is what makes a bug here an identity problem rather than a clinical-record problem, and it is the reason the extraction was defensible at all.

</details>

---

### 44. Entra ID is the only client of your SCIM service. What does it actually do that the specification does not require, and what breaks if you implement the specification literally?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It matches existing users by issuing a filtered `GET` before deciding whether to create — so if you do not implement filtering on the matching attribute, every cycle creates duplicates instead of updating. It runs a full initial cycle and then incremental cycles on a schedule measured in tens of minutes, escrows and retries individual failures with backoff, and puts the whole job into quarantine after sustained failures. Implementing the specification literally and testing only against your own client is how all of that is discovered in production.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it does that the specification does not require.**

- **It discovers your capabilities and believes you.** It reads `ServiceProviderConfig`, and on some configurations `Schemas` and `ResourceTypes`. Advertising support for something you have not implemented — `PATCH`, filtering, sorting, `ETag` — makes it use a path that then fails. The honest move is to advertise exactly what works.
- **It matches before it writes.** The provisioning cycle asks "does this user already exist" with a filtered query on the matching attribute, typically `GET /scim/v2/Users?filter=userName eq "someone@trust.example"`. If filtering is unimplemented or returns everything, the match fails and the client concludes the user is new. The result is duplicate accounts on every cycle rather than a visible error — silent, cumulative, and exactly the sort of failure this pipeline exists to prevent. Filtering is not optional in practice even though the specification treats much of it as such.
- **It prefers `PATCH` over `PUT`**, so `PATCH` carries the real traffic.
- **It disables rather than deletes.** The normal lifecycle signal for a departing clinician is `active: false`, not `DELETE`. A hard delete arrives only in narrower circumstances. An implementation that only handles `DELETE` as deprovisioning will never deprovision anyone.
- **It runs an initial cycle then incremental ones**, and the incremental interval is measured in tens of minutes rather than seconds. That interval dominates the end-to-end deprovisioning latency, which is a separate question worth its own answer.
- **It escrows failures and retries them.** A record that fails is retried on later cycles with decreasing frequency, and eventually abandoned. So a transient bug does not lose the change immediately — but a persistent one loses it quietly, weeks later, with nobody watching.
- **It quarantines the job.** Sustained failures — most often authentication failures — put the whole provisioning job into quarantine, after which it retries on a much slower schedule. The important operational consequence: **provisioning can stop entirely while every dashboard on our side looks perfectly healthy**, because a service that receives no requests reports no errors.
- **It respects throttling.** A `429` with `Retry-After` is handled properly, which means rate limiting this endpoint is safe — and is worth having, since an endpoint that can disable accounts should not be unbounded.
- **It sends attributes shaped by the tenant's mapping configuration**, not by your schema. Someone in the directory team can change a mapping and change what arrives, with no code change on either side.

**What breaks if you implement the specification literally.** Duplicates from missing filter support; deprovisioning that never fires because only `DELETE` was handled; retry storms from returning `500` on malformed input the client will never fix; an integration that quarantines because a credential expired and nobody noticed; and multi-valued attribute corruption from treating `add` as assignment.

**So how do you test it when the client is a product you do not control?**

1. **A SCIM specification compliance suite** as the baseline — it catches the protocol-level mistakes cheaply.
2. **Contract tests against captured real payloads.** Record what the tenant actually sends for create, update, disable, group add and group remove, and replay those as fixtures. This is the highest-value suite by a distance, because it tests the client you actually have rather than the one the specification describes.
3. **A staging tenant doing a real provisioning cycle** before anything reaches production. Nothing else exercises matching, escrow and quarantine behaviour.
4. **Integration tests against a real database**, since the lifecycle consequence — closing care relationships transactionally — is the part that matters and is exactly what a mocked repository would pass while broken.

**And the monitoring that follows from all of the above.** Because the failure mode is silence, the alerts cannot be error-rate alerts. What is needed is a *liveness* signal on the integration: time since the last successful provisioning request, alerting when it exceeds a couple of cycles. Alongside it, a periodic reconciliation comparing the directory's view with the local clinician table, so an account active here and disabled there is surfaced rather than assumed impossible. A SCIM sync failure is a paged alert in this design, not a ticket, and that is the reason: a deprovisioning that did not land means access that should have ended has not, which is a security event.

</details>

---

### 45. How do a clinician's roles and team memberships get from the directory into an authorization decision, and what happens when a user belongs to more than two hundred groups?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
They mostly do not travel in the token, and that is deliberate. App roles give coarse capability in the `roles` claim; everything about *reach* — which patients, which team — is resolved from the database on every request, because it changes faster than a token lives. The two-hundred-group case is the reason to avoid group claims entirely: past that limit Entra omits the groups claim and substitutes an overage indicator pointing at Microsoft Graph, so any design that reads groups from the token silently stops working for exactly the most senior users.

<details>
<summary><strong>Detailed answer</strong></summary>

**The three mechanisms, and what each is good for.**

- **Group claims.** The token carries directory group identifiers — opaque object identifiers, not names. Useful if the directory's groups genuinely are your authorization model. Two problems: the identifiers are meaningless without a mapping you maintain, and the claim has a hard size limit.
- **App roles.** Roles are declared on the application registration, assigned to users or groups in the directory, and emitted in the `roles` claim. They are your vocabulary rather than the directory's, they are bounded by what you defined, and an administrator assigning them is making a statement about *your* application rather than about a mailing list. This is the better mechanism for capability and it is what the role model here maps onto — clinician, care-team administrator, content author, content approver, platform operator.
- **Nothing in the token at all**, with the decision resolved server-side per request. This is what carries the important half of the model.

**The overage behaviour, precisely.** Past roughly two hundred groups in a JSON Web Token — the limits differ by token type and are lower for some flows — Entra stops emitting the groups claim and instead includes an overage indicator with a pointer to a Microsoft Graph endpoint that returns the full list. Any code doing `if "nurse-group-guid" in token["groups"]` now throws a key error or, far worse, evaluates to false and denies a legitimate user. And it happens to the users with the most memberships, who tend to be the longest-serving and most senior clinicians. The workaround — calling Graph per request to resolve the real list — adds a network round trip to every authorization decision, which is precisely what both these designs refuse to do: the latency budget rests on authorization requiring no network call.

So the overage rule is not a corner case to handle; it is an argument against the mechanism.

**What this system actually does.** Capability comes from the role; **reach comes from the database**. The question "may this clinician see this patient" is answered by a row-level security policy joining through the temporal care-relationship table, evaluated inside the request transaction. That has three consequences worth saying out loud:

1. **Freshness.** A clinician removed from a care team loses reach on their very next query, with no token refresh and no waiting fifteen minutes. Putting reach in a token means access outlives the decision to revoke it by the token's lifetime — unacceptable for a record where team membership is the access-control boundary.
2. **Size.** A clinician may follow hundreds of patients. That list can never be a claim; tokens would be enormous and stale.
3. **Single definition.** There is exactly one place that defines the relationship, and both the record layer and the search layer derive scope from it. A token-carried copy would be a second definition, and two definitions of an authorization fact is how they drift.

The membership *is* cached, but only for the duration of a single request — explicitly never longer, because a stale authorization fact is a disclosure rather than a slow page.

**Where directory groups still earn their place.** Group-to-role assignment in the directory is a good administrative model: the hospital manages a group, the group is assigned an app role, and the role arrives in the token. That keeps the directory team's workflow intact without making group identifiers part of the application's logic. Group *provisioning* over SCIM is also how care-team membership arrives here as data — which is the right place for it, since it then lives in the database where reach is evaluated rather than in a claim.

**The general principle.** Put in the token what is stable for the token's lifetime and small enough to carry: who you are, which tenant, what kind of principal, what capability. Resolve everything volatile or large at request time from the system of record. The test I would apply to any claim someone proposes adding is: if this changes one minute after the token is issued, what happens? If the answer is "they keep the access for fifteen minutes", it does not belong in the token.

</details>

---

### 46. Your API accepts tokens issued by a hospital's Entra tenant. What exactly do you validate, and what is the mistake that lets a token from any other organisation in?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Signature against the tenant's published keys, then issuer, audience, expiry and not-before — and then the one people miss, the tenant identifier against an allowlist. The mistake is configuring the application as multi-tenant and validating the issuer against the shared metadata endpoint, whose issuer value is a template. Accept that and every Entra tenant in the world satisfies your issuer check, which means anyone with a Microsoft work account can obtain a token your API will honour.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checks, in order, and none of them is optional.**

1. **Signature**, against the keys published at the tenant's key-set endpoint, selecting by the `kid` header. Keys rotate, so the set is cached — twelve hours here — and refreshed on an unrecognised `kid` rather than on a timer alone. The long cache is deliberate: it is also the identity-provider outage mitigation, since existing tokens keep validating while new sign-ins fail.
2. **Algorithm**, pinned. Accept the asymmetric algorithm you expect and nothing else — never read the algorithm out of the token header and trust it, which is how signature bypasses happen.
3. **Issuer**, exactly. Entra's version 2 issuer is the login host plus the tenant identifier plus a version suffix; version 1 tokens use a different host entirely. Accepting either loosely is a common mistake, and so is failing to notice that the two token versions carry different claim shapes.
4. **Audience**, against this API's identifier — not the client's. Two distinct planes exist here with two distinct audience values, and the gateway checks the audience against the route's plane so a clinician token on a patient path is rejected before application code runs.
5. **Tenant identifier against an allowlist.** The check that actually establishes *which organisation* this is.
6. **Expiry and not-before**, with a small clock-skew tolerance and no more.
7. **Token type.** An identity token is not an access token; its audience is the client application, not your API. Accepting one because it parses and has a valid signature is a real and recurring vulnerability.
8. **Delegated scope versus application role.** A token from the client-credentials flow has no user behind it, and treating its application permissions as though a person consented to them is how a service integration acquires user-level reach.

**The multi-tenant trap, spelled out.** A single-tenant application resolves metadata from its own tenant, and the published issuer is a concrete value containing that tenant's identifier — so the issuer check does the tenant check for free. A multi-tenant application resolves metadata from the shared endpoint, and the published issuer is *templated* with a placeholder for the tenant. Libraries handle this by substituting the tenant identifier from the token itself, which means the issuer always matches. The check passes for every tenant on the platform, and unless you then compare the tenant identifier against a list you maintain, any Microsoft work or school account can obtain a token your API accepts. What saves you afterwards is that the principal still has no care relationship and therefore reaches no data — but that is defence in depth doing the work of authentication, and it is not a position to be in deliberately.

**Identity claims, which is the other recurring mistake.** The stable identifier for a principal is the object identifier together with the tenant identifier. Email address, user principal name and preferred username are all mutable, are not guaranteed to be verified, and can in some configurations be set by a directory administrator to a value that collides with something meaningful in your system. Anything keyed on an email address as a user identity is a rename away from an account-takeover story. The clinician record here keys on the directory object identifier for exactly this reason.

**Validate twice, and mean it.** The gateway validates signature, issuer, expiry and audience so a forged or wrong-plane token never reaches the cluster. The service then validates again locally against the cached key set and applies its own rules. A service that trusts a header the gateway set has made the gateway the only thing standing between anyone inside the network and every record. The edge is a filter; it is never the authority.

**A rotation hazard worth raising unprompted**, because the marketplace design flags exactly this: a gateway caches the key set on its own schedule, independent of the application's cache. During a signing-key rotation the two can disagree, and tokens signed with the new key are rejected at the edge while the cluster would have accepted them. The fix is to make the key-overlap window strictly longer than the slowest cache's refresh interval — which requires knowing that interval on the specific tier you are running, not assuming it.

**And the limitation to state honestly.** All of this is authentication. None of it decides what the principal may reach. In this design that decision is a database join against a temporal care relationship, evaluated per request — which is the reason a validated token from an unexpected tenant returns empty results rather than someone's record.

</details>

---

### 47. A clinician is deprovisioned in the hospital directory at nine in the morning. When exactly do they lose access, and what dominates that number?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Not immediately, and the dominant term is not the one people expect. The access token's fifteen-minute lifetime is the small part; the directory's provisioning cycle — tens of minutes — is what actually sets the number. But the honest answer is better than that arithmetic suggests, because a still-valid token buys almost nothing here: reach is resolved from the database on every request, and the deprovisioning closes the care relationships in the same transaction, so the moment the SCIM call lands the record goes empty even for a token that has not expired.

<details>
<summary><strong>Detailed answer</strong></summary>

**The chain, with each link's contribution.**

1. **Directory change at 09:00.** Instant, and invisible to us.
2. **Waiting for the next incremental provisioning cycle.** Tens of minutes. **This dominates.** It is a schedule inside a product we do not control, and no amount of engineering on our side shortens it.
3. **The SCIM request arrives and commits.** Milliseconds. `active: false` maps to the clinician row and closes every open care relationship for that clinician in the same transaction.
4. **Their existing access token remains cryptographically valid** for up to its full fifteen minutes, and their session may hold a refresh token too.

Naively that is a cycle plus fifteen minutes. In practice the fourth term mostly does not matter, and understanding why is the interesting part.

**Why the token lifetime is nearly irrelevant here.** The token establishes *who*, not *what they may reach*. Reach is a row-level security policy joining through the temporal care-relationship range, evaluated inside each request's transaction against the current state of the database. Closing those relationships in step three means the very next query from that still-valid token returns zero rows — not an error, an empty record. The same scope is projected into the search index as a mandatory filter derived from the caller's token and the current relationships, so search closes at the same moment rather than becoming the way around it.

So the effective exposure window is step two, and the mitigations belong there rather than in token lifetimes. That is a direct payoff of a design decision made much earlier — putting the authorization boundary in the database instead of in a claim — and it is worth naming as such, because the alternative design would have had a genuinely fifteen-minute hole.

**What is left exposed, and I would not gloss over it.** Anything the token authorises that is *not* patient-scoped: reading their own profile, endpoints gated by role alone. And the long-lived device connection path — the broker authenticates a connection rather than each publish, so a connection established before the revocation persists until its maximum lifetime forces re-authentication. That gap is flagged explicitly in the design rather than assumed away, and connection lifetimes are deliberately set shorter than the refresh window because of it.

**What to do when tens of minutes is not acceptable.** It depends entirely on why someone is being removed. Routine offboarding at the end of a notice period does not need to be fast. A suspension for cause does, and for that the answer is not to speed up the provisioning cycle — it is to have a second, immediate path:

- **Revoke the sign-in session in the directory**, which invalidates refresh tokens so nothing new is issued. It does not retract the access token already in the wild.
- **A denylist consulted at validation time**, checked against a small, fast store. This is what the marketplace does for a suspended vendor — an event publishes the deactivation and services consult a denylist of revoked token identifiers — and it is the general answer to the gap between "token issued" and "token should no longer work". The cost is a lookup on every request, which is why it holds only the exceptions rather than every principal.
- **Continuous Access Evaluation**, which exists for exactly this and lets a resource reject a token near-real-time on a critical directory event. It is worth knowing about, and worth being precise that a custom API has to participate in it — it is not something you inherit by pointing at Entra.
- **An in-platform emergency disable** that does not wait for the directory at all: set the clinician inactive and close their relationships now, and let the SCIM cycle reconcile later. Since every operation here is idempotent, an out-of-band disable followed by the directory's own disable converges rather than conflicting.

**And the detection that makes the whole thing trustworthy.** A SCIM sync failure is a *paged* alert in this design, not a ticket, precisely because the failure mode is silence: a quarantined provisioning job means deprovisionings simply stop arriving while every dashboard on our side looks healthy. There is a detection rule over the audit stream for a deprovisioning that did not close its care relationships, and a periodic reconciliation between the directory's view and the local clinician table catches an account active here and disabled there. Without those, the answer to "when do they lose access" would be "we believe within an hour", and belief is not a control.

</details>

---

### 48. The SCIM endpoint can create and disable clinician accounts and is called by something outside your network. Threat-model it.

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
It is the highest-privilege external surface in the system — it writes the table that authorization is derived from — and the two worst outcomes are opposite: mass deprovisioning, which takes clinicians out of the record mid-consultation and is a patient-safety event, and unauthorised provisioning, which is an attempt to manufacture an insider. The controls are a strong client credential with no shared secret, network restriction, strict separation from the patient plane, a volume circuit-breaker on destructive operations, and audit on everything.

<details>
<summary><strong>Detailed answer</strong></summary>

**The threats, ranked by what they actually cost.**

| Threat | Consequence | Control |
|---|---|---|
| Mass deprovisioning, malicious or from a mapping error | Clinicians lose the record mid-consultation. In a clinical setting this is a safety event, not an outage | Volume threshold on destructive operations with human confirmation above it; audit and alert on disable rate |
| Credential compromise, then unauthorised provisioning | An attacker tries to manufacture a clinician account | Certificate or federated credential, no shared secret; network restriction; and the fact that a row alone grants nothing without a directory-issued token |
| User enumeration through the filter endpoint | The staff directory of a hospital trust is itself sensitive | Authenticated caller only, rate limiting, uniform responses, audit on query volume |
| Injection through attribute values | Stored cross-site scripting or a broken record downstream | Strict schema validation; unknown fields rejected rather than absorbed |
| Replay of a captured request | Duplicate or reverted lifecycle changes | Transport security, short-lived credentials, idempotent operations keyed on the directory identifier |
| Exposure of the endpoint on the patient plane | A patient-audience token reaching provisioning | Separate route and audience; never published through the patient-facing surface |
| Directory compromise upstream | Full legitimate-looking access | Accepted and stated; detection rather than prevention |

**The nuance that makes the provisioning threat less bad than it first looks, and worth saying.** Writing a clinician row does not by itself grant access. Authentication still requires a token issued by the hospital's directory for that object identifier, and reach still requires an active care relationship. So an attacker holding only the SCIM credential can create a row that nobody can authenticate as. To get an actual session they would need to compromise the directory too — at which point they have a legitimate identity and this endpoint is not their problem. That is defence in depth genuinely working, and it is an argument for keeping the authorization boundary in the database rather than in provisioning.

**Which is also why mass *deprovisioning* is the more serious direction.** It needs no second compromise to do damage: it is a single credential away, it is fast, it looks exactly like normal traffic, and its effect is immediate because reach is resolved per request. A bad attribute mapping configured by a well-meaning administrator produces the same outcome as an attacker. So the control I would insist on is a rate threshold on the disable path — beyond some number of deprovisionings in a window, stop and require a human decision. It is mildly annoying during a genuine bulk offboarding and it is the difference between an incident and a catastrophe.

**The controls, concretely.**

- **The directory is the sole authorised caller**, authenticated with its own client credential and network-restricted. I would push for a certificate or a federated credential over a shared secret — a long-lived secret in a directory configuration is a credential nobody rotates, and its expiry is also a favourite cause of a silently quarantined provisioning job.
- **Strict input validation.** Every request body is a typed model, so unknown fields are rejected rather than absorbed. The attribute set arriving here is shaped by a tenant-side mapping that someone can change without touching our code, which makes validation a genuine boundary rather than a formality.
- **Rate limiting**, safe to apply because the client honours throttling responses correctly.
- **Everything is audited** — actor, operation, target, and the trace identifier joining it to the rest of the telemetry. The lifecycle consequence is audited as its own event, not folded into a generic update.
- **Detection rules that name specific misuse** rather than generic anomalies: a deprovisioning that did not close its care relationships, an unusual volume of disables, provisioning activity outside the directory team's normal pattern.
- **Deployment must not drop requests.** This service uses a rolling update precisely because it has an external caller and idempotent operations; the client's escrow-and-retry behaviour is the safety net, and it only works because every operation is idempotent.
- **Blast radius is bounded by schema ownership.** This service writes the identity schema and nothing else. A compromise here cannot rewrite a prescription.

**What I would state as accepted rather than solved.** The hospital directory becomes a trust dependency of the platform: compromise it and platform access follows, and no control on our side prevents that. The answer is detection — out-of-team access rules, volume anomalies, break-glass review within twenty-four hours — plus the fact that every patient-data access writes an immutable audit row in the same transaction as the access, so a legitimate-looking insider leaves a complete trail. Being explicit about where prevention ends and detection begins is more useful than implying the controls are stronger than they are.

</details>
