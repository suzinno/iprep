# Interview Questions — Retail Software Aggregation Platform

> Auto-generated from [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") and system design documents. Questions target stated responsibilities and technical pillars.
> Weighted toward the client brief in `candidate-profile.txt`.

## Table of Contents

- [Service Architecture and Module Boundaries](#service-architecture-and-module-boundaries)
- [Polyglot Data Modeling and Cross-Store Consistency](#polyglot-data-modeling-and-cross-store-consistency)
- [SQL Performance, Indexing and Migrations at Scale](#sql-performance-indexing-and-migrations-at-scale)
- [Caching and the Catalog Read Path](#caching-and-the-catalog-read-path)
- [Asynchronous Work, Message Brokers and Bulk Attribute Updates](#asynchronous-work-message-brokers-and-bulk-attribute-updates)
- [FastAPI Service Design and API Contracts](#fastapi-service-design-and-api-contracts)
- [Identity, Authorization and Tenant Isolation](#identity-authorization-and-tenant-isolation)
- [Testing, Delivery and Observability](#testing-delivery-and-observability)

---

## Service Architecture and Module Boundaries

---

### Q1. What does "clean architecture" mean concretely in a Python service, and what in the code actually stops the dependency direction from being violated?

**Brief answer**
It means the domain logic depends on nothing, and everything else — [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") handlers, the Object-Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")), the message broker — depends inward on it. In Python nothing enforces that by construction, so it has to be enforced by import discipline and a linter rule, not by good intentions.

<details>
<summary><strong>Detailed answer</strong></summary>

The layering I used across the six marketplace services is the conventional three rings. The innermost holds domain entities and the rules that are true regardless of technology — a listing cannot be published while its vendor is `pending`, a connection request bills at most once. The middle ring holds use cases that orchestrate those rules and speak only to abstract repository interfaces. The outer ring holds the parts that would change if we swapped a technology: the [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") routers, the [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") repository implementations, the [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") document mapper, the [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") task definitions.

The practical payoff is not philosophical purity, it is that the catalog domain rules are testable without a database and that swapping the metadata store would touch one ring. The practical danger is that Python has no visibility modifiers, so `from app.infrastructure.db import session` inside a domain module compiles and runs perfectly. The rule is therefore mechanical: an import-linter contract in the pipeline declares the layer graph and fails the build on a back-edge. Without that check, "clean architecture" degrades within about two sprints into a folder naming convention, which is the state most codebases claiming it are actually in.

The one place I deliberately broke the abstraction was the catalog search query. That path uses SQLAlchemy Core with hand-written predicates rather than the ORM, because the generated query plan is the thing being engineered. Hiding it behind a generic repository method would have meant nobody could see what the database was being asked to do. The rule I apply is that abstraction is worth it where the implementation is genuinely interchangeable, and it is a liability where the implementation *is* the design.

</details>

---

### Q1. Why are catalog, vendor and retailer separate services here rather than separate modules inside one application?

**Brief answer**
The brief required that listing changes must not reach connection and billing flows. A module boundary documents that requirement; a process boundary enforces it. At this traffic level that is the entire justification — it is an isolation decision, not a throughput one.

<details>
<summary><strong>Detailed answer</strong></summary>

The split follows the shape of the marketplace rather than a technical layer. `catalog-service` is read-only and carries the highest traffic. `vendor-service` owns the write side of listings, including publish and bulk import. `retailer-service` owns the buyer's private working set — stores, shortlists, users — which is data vendors must never read. `connection-service` owns the platform's actual commercial event, and `billing-service` owns charges. `identity-service` is a separate trust boundary because a compromise there is categorically worse than a compromise anywhere else.

What each boundary buys is specific. A runaway catalog import can saturate `vendor-service` and its workers without touching the pods that serve browse. A bad release of `billing-service` cannot corrupt a live conversation thread, because it has no write path into `connection_thread` — it only consumes `connection.requested` from the event bus. And a vendor-side query physically cannot read `shortlist` rows, because that table lives behind a service the vendor token cannot reach at all.

I would not defend this as free. Six services plus three worker deployments is more operational surface than roughly 35 queries per second ([QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second")) at peak requires, and it is only affordable because all nine share one repository, one migration history, one Continuous Integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Automatically builds and tests code on every change")) pipeline and one cluster. If a team split those into nine repositories at this scale, coordination cost would exceed the value of the boundaries within a quarter. The boundary that mattered was the deployment boundary, not the repository boundary.

</details>

---

### Q1. What does it mean that a service "owns its tables", and what happens the first time someone breaks that?

**Brief answer**
One service holds write access to a set of tables, and no peer touches them directly — a peer that needs the data calls an Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")) or consumes an event. The first violation is invisible and cheap; the cost arrives at the next schema change.

<details>
<summary><strong>Detailed answer</strong></summary>

Ownership is what makes the service boundary real. If `billing-service` could `SELECT` from `connection_request` directly, the two services would share a schema, and every column rename in `connection-service` would become a coordinated release across two deployables. That is the shared-database anti-pattern, and its symptom is not an outage — it is that migrations stop being safe, so they stop happening, so the schema calcifies.

In this design the enforcement is partly conventional and partly mechanical. Conventionally, each service has its own SQLAlchemy metadata covering only its tables. Mechanically, each service connects with its own database role, and the grants are [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files")-managed, so `billing-service`'s role simply has no `SELECT` on the connection tables. That is the version I would insist on, because a convention enforced only by code review survives exactly until a Friday afternoon.

There is one deliberate exception worth naming, because it looks like a violation and is not. `product_listing_facets` is written only by `indexer-worker` and read only by `catalog-service` — two different deployables against one table. That is a read model, not shared ownership: the writer owns the schema, the reader treats it as a published contract, and the table exists precisely so that the read side never joins back into `vendor-service`'s tables. The distinction I hold is that shared *ownership* is a defect, whereas a single-writer projection with declared readers is a pattern.

</details>

---

### Q2. The brief's requirement was that listing changes must not spill into connection and billing flows. Where exactly is that enforced, and how would you write a test that fails when it is broken?

**Brief answer**
It is enforced by `vendor-service` having no write path into `connection_*` or `billing_*` tables, and by every cross-boundary effect travelling as an event through the transactional outbox. The test is a negative one: assert the grant matrix and assert that a publish produces exactly one outbox row and no other write.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanism is the outbox. Publishing a listing runs one [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") transaction that updates `product.current_revision_id` and inserts one row into `outbox_event`. Nothing else. A relay process publishes that row to the `sb-catalog-events` topic afterwards and stamps `published_at`. Consumers — `indexer-worker`, `notification-worker` — do their own work in their own transactions. So a listing publish physically cannot fail because the notifier is down, and it cannot write to a conversation thread because it never opens one.

Testing that is the interesting part, because the requirement is an *absence*, and absences are what test suites are worst at. Three checks, at different levels. First, an integration test that publishes a listing inside a transaction wrapped by a SQLAlchemy event listener recording every statement executed, then asserts the set of touched tables equals `{product, outbox_event}` exactly — an equality assertion, not a "does not contain", because a whitelist catches the new table someone adds next year. Second, a database-level test that connects as the `vendor-service` role and asserts `INSERT INTO connection_request` raises a permission error; a test that expects a failure has to assert the specific error, otherwise a missing table would also make it pass. Third, an architecture test asserting no module under `vendor/` imports anything under `connection/` or `billing/`.

The failure I have actually seen in this class of design is subtler than a direct write. Someone adds a "notify the vendor immediately on publish" feature and calls the notification path synchronously inside the publish handler because it is one line. Nothing is corrupted, no boundary is violated on paper — but the publish transaction now holds open while an external call runs, and a notification outage becomes a publish outage. That is why the check is on the *set of writes and calls* in the transaction, not on table ownership alone.

</details>

---

### Q2. `connection-service` calls `retailer-service` synchronously, and that is the only synchronous inter-service hop in the design. It fails open on timeout. Defend that.

**Brief answer**
The call asks whether the retail group already has an open thread for this product, which changes what the caller returns. On timeout it permits the connection rather than blocking it, because refusing a legitimate connection request costs the marketplace more than an occasional duplicate thread — and the duplicate is caught by a unique constraint anyway.

<details>
<summary><strong>Detailed answer</strong></summary>

The rule I applied to every call in the system is one sentence: synchronous when the caller cannot act without the answer, asynchronous when the caller only needs the work to happen. Almost everything falls on the asynchronous side. This one does not, because the response body differs depending on the answer — the category manager either opens a new thread or is routed to the existing one.

The failure mode of any synchronous hop is that it converts the callee's availability into the caller's availability. With a 250 millisecond timeout and no fallback, a slow `retailer-service` would take down connection creation, which is the platform's single most commercially important write. So the timeout has an explicit fallback, and the direction of the fallback is a business decision rather than a technical one. Opening a duplicate thread is a mild annoyance for a vendor. Refusing a sourcing conversation is the platform failing at the one job it exists to do.

What makes failing open acceptable rather than reckless is that the safety net is in the database, not in the retry logic. `connection_request` carries `UNIQUE (retail_group_id, idempotency_key)`, and the endpoint requires an `Idempotency-Key` header. A double-submitted request from the same category manager collides in the schema, so it cannot create two threads and cannot bill the vendor twice. The synchronous call is an optimisation for user experience; the constraint is the correctness guarantee. That ordering is the general principle — if failing open is only safe because a downstream check exists, name that check explicitly, and if you cannot name it, you are not failing open, you are guessing.

The residual risk I would state honestly is a partition where `retailer-service` is slow but healthy for long enough to produce a burst of duplicate threads with *different* idempotency keys, from genuinely separate user actions. The constraint does not catch that. It is bounded by the per-group quota of twenty connection requests per day, which is a marketplace-integrity control that happens to cap this blast radius too.

</details>

---

### Q2. You reviewed pull requests and refactored the catalog and auth modules. Give me a refactor these boundaries made safe, and one that would still be dangerous.

**Brief answer**
Safe: replacing the catalog search query implementation, because it sits behind one service that owns one table and one API contract. Dangerous: changing the shape of an event payload or the projection contract, because the blast radius is asynchronous and shows up as silently wrong data rather than a failed deploy.

<details>
<summary><strong>Detailed answer</strong></summary>

The safe one first. Rewriting the faceted search query — moving from ORM-generated Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Queries and manipulates data in a relational database")) to hand-built SQLAlchemy Core, adding the partial index predicate, switching from offset to keyset pagination — touched exactly one service, one table it exclusively reads, and a response model the frontend generates its client from. Every consequence of getting it wrong is a synchronous failure that functional tests catch: wrong result set, wrong ordering, a slow query the plan test flags. The boundary made it safe because nothing else in the platform could observe the change.

The dangerous one is the projection contract. `indexer-worker` reads a MongoDB revision document and writes `product_listing_facets`. Suppose a refactor renames a facet key or changes how `country_coverage` is derived. The deploy succeeds, the tests pass if they were written against the new shape, and the failure is that listings quietly stop matching a filter they should match. Nobody pages you. A vendor eventually reports that their product does not appear under Germany, weeks later. That is the shape of every asynchronous refactor failure: no error, degraded truth, long detection time.

So the review standard for the two is different. For a synchronous refactor I want tests and a canary. For anything touching an event payload or a projection I want the change to be additive first — write the new key alongside the old, backfill, verify by comparing projected rows against the source documents, then remove the old key in a later merge request. That is the same expand/contract discipline used for [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") migrations, applied to a data contract instead of a schema, and for the same reason: during the rollout window both versions are live simultaneously whether you planned for it or not.

The auth module refactor sat in between and I treated it as the dangerous class, because an authorization refactor's failure mode is also silent — it does not throw, it returns rows it should not.

</details>

---

### Q2. You documented workflows, deployment steps and data models. In your experience, which documentation actually survives contact with a changing system, and which rots?

**Brief answer**
Documentation that is executable or generated survives; prose that restates what the code already says rots within a release. The durable artefacts here were the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document generated from [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models, the Terraform configuration, and the design decisions with their rejected alternatives.

<details>
<summary><strong>Detailed answer</strong></summary>

Three categories behave completely differently over time.

Generated documentation cannot drift, because it is a build artefact. The OpenAPI specification comes out of the Pydantic request and response models, so it is wrong only if the code is wrong. The same holds for the entity relationship model insofar as it is derived from the SQLAlchemy metadata and the Alembic history. I push as much documentation as possible into this category, because it is the only one with a mechanical guarantee.

Executable documentation is the second tier: the Docker Compose file that brings up PostgreSQL, MongoDB and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") at pinned versions is the real answer to "how do I run this locally", and it stays correct because CI runs integration tests against it. A written setup guide covering the same ground is wrong the first week someone bumps a version. So the guide should say "run `docker compose up`" and stop, rather than list the services.

The third tier is the one that genuinely needs prose and cannot be generated: *why*. Why MongoDB and PostgreSQL rather than `JSONB` alone. Why PostgreSQL full-text search rather than a dedicated search cluster, and the explicit trigger that would change the answer. Why Row-Level Security was rejected as the primary tenant control. That material has no other home, it is what a new engineer actually needs, and it rots slowly because decisions change less often than code. The discipline that keeps it honest is recording the rejected alternative and its cost alongside the choice — a decision record with no alternative is indistinguishable from a description, and descriptions are what the code is for.

What I stopped writing was step-by-step deployment runbooks describing what the pipeline does. The pipeline definition is the truth; a parallel prose copy is a second owner of the same fact and the two diverge silently.

</details>

---

### Q3. Six services and three worker pools for a system peaking around 35 QPS. Make the case against yourself: when is the modular monolith the right call, and what would make you collapse these?

**Brief answer**
The monolith is genuinely defensible here and would be correct for a smaller team — the traffic does not need the split. The case for six services rests entirely on enforcing the isolation requirement rather than documenting it. I would collapse them if the operational overhead started costing more engineering time than the boundaries saved.

<details>
<summary><strong>Detailed answer</strong></summary>

The honest position is that at this scale the split is a bet, not an obvious win, and the bet is about people and blast radius rather than load. A modular monolith with the same package boundaries would serve 35 QPS on a fraction of the infrastructure, deploy in one step, debug in one process, and never need distributed tracing to answer "where did the request go". Anyone claiming microservices are obviously right at this volume has not paid the operational bill.

What the process boundary buys that the module boundary does not is enforcement under pressure. In a monolith, the constraint that listing changes must not touch billing is a rule someone can break with a single import at the end of a sprint, and the only thing standing in the way is review discipline. Across a process boundary, breaking it requires deliberately adding an HTTP client and a network policy exception — visible in a diff, and hard to do accidentally. The second thing it buys is independent failure and scaling: a bulk import cannot exhaust web-tier capacity, and `catalog-service` can be canaried on its own because it carries the risky query plans.

The conditions that would make me collapse them are concrete. If the team fell below roughly six engineers, the coordination cost would dominate. If we found ourselves routinely making changes that touched three services at once, the boundaries would be in the wrong place, and merging them would be cheaper than moving them. If the operational cost — nine deployments to observe, distributed traces to follow, cross-service test setup — started showing up as slower delivery on ordinary features, that is the signal.

The thing that makes collapsing feasible is that the split is already limited: one repository, one Alembic history, one pipeline, one cluster namespace. Merging two services is a routing change and a database grant change, not a re-platforming. I would treat that reversibility as part of the design rather than an accident — the expensive version of this decision is nine repositories, and I deliberately did not build that.

</details>

---

### Q3. Vendor analytics arrives as a new requirement — impressions, shortlist adds and connection conversion per listing. Where does it go, and what does your answer reveal about whether the boundaries were right?

**Brief answer**
It is a read model fed by events from three different services, so it belongs in a new consumer with its own store rather than inside any existing service. If it could not be built without reaching into three services' tables, that would be evidence the boundaries were drawn wrong.

<details>
<summary><strong>Detailed answer</strong></summary>

The data it needs is spread deliberately. Impressions are a `catalog-service` concern, shortlist adds live in `retailer-service`, and conversion comes from `connection-service`. No single service owns the question. That is the normal shape of an analytics requirement and the reason it should not be bolted onto whichever service is nearest.

The clean implementation is another consumer of the existing event streams. `connection.requested` and `connection.responded` are already published to `sb-connection-events`; shortlist adds would need a new event from `retailer-service`, emitted through the same outbox; impressions are high-volume and low-value per record, so they should be sampled or batched rather than eventful — a counter in Redis flushed periodically, not one message per page view. The consumer maintains its own aggregate table, and the vendor workspace reads it. Nothing joins across service boundaries at query time.

This is also a good test of the boundaries, and it passes with one qualification. Two of the three signals are already events, which means the design anticipated that other consumers would want them. The shortlist signal is not, which tells me the retailer side was modelled as a private working set rather than as a source of marketplace facts — reasonable, since the tenant isolation requirement is strongest there, but it means adding the event needs a privacy decision, not just a code change. Vendors must see aggregate shortlist counts, never which retail group added them. That constraint belongs in the event payload, not in the query that reads it, because an event carrying group identity will eventually be consumed by something that leaks it.

The failure mode I would watch for is the analytics store quietly becoming a second system of record because it is the only place with a cross-service view. The guard is that it is rebuildable — every number in it must be reconstructable by replaying events, and there must be a job that does exactly that, or it will drift and nobody will know which copy is right.

</details>

---

### Q3. Task descriptions arrive abstract and incomplete, and the business logic has to be reverse-engineered before coding. How do you do that against a nine-deployable architecture without stalling for a week?

**Brief answer**
Reconstruct the behaviour from the artefacts that cannot lie — the schema, the event catalogue, the API contract and the audit trail — then take a concrete, wrong-on-purpose proposal to the application manager rather than a list of open questions. Confirming a specific reading is far faster than eliciting a specification.

<details>
<summary><strong>Detailed answer</strong></summary>

Waiting for a complete ticket is not a strategy, and neither is guessing and building. What works is narrowing the ambiguity cheaply before spending anyone's time.

The first pass is entirely offline and usually takes an hour or two. The database schema tells you what states exist — `connection_request.status` moving between `open`, `responded`, `closed` and `withdrawn` describes the real lifecycle more accurately than any document. The event catalogue tells you what the system considers a fact worth telling others about. The API surface tells you what the client can actually do. The `audit_event` table tells you what has actually happened in production, which is frequently different from what everyone believes happens. In a distributed design this reconstruction is more valuable than in a monolith, precisely because no single file contains the flow.

The second pass is a written proposal, not a question list. Something like: "My reading is that a connection request from a category manager should mark the shortlist item `contacted` for the whole retail group, not just for that user, and that the vendor should see the group name but not the individual's name. If that is right, I will implement it this way; if not, tell me which half is wrong." That gets a decisive answer in one short call, because the person is reacting to something concrete rather than being asked to author a specification. Being explicitly wrong is a feature — people correct much faster than they specify.

The third part is being honest about the cost as it accrues. If the clarification takes three days to arrange, the estimate is now wrong, and the useful behaviour is updating the remaining estimate daily and saying plainly what is blocking, rather than absorbing it quietly and delivering late. I would rather flag a slipped estimate early and be dull about it than protect the original number.

The one thing I would not do is let the reverse-engineering become the deliverable. The point is to get to a defensible reading fast enough to start building, not to produce an archaeology report.

</details>

---

## Polyglot Data Modeling and Cross-Store Consistency

---

### Q1. The brief asked for MongoDB schemas for product metadata "without a fixed column set". What does schemaless actually buy here, and how do you stop it degrading into "no contract"?

**Brief answer**
It buys the ability to add a product category without a migration, because a point-of-sale ([POS](https://en.wikipedia.org/wiki/Point_of_sale "Point of Sale — The system and moment at which a retail transaction is completed")) system, an inventory engine and a loyalty platform have almost no attributes in common. It stays governed because a per-category `facet_schemas` document declares which attribute keys are typed, which are facetable, and their value domains, and Pydantic validates against it at write time.

<details>
<summary><strong>Detailed answer</strong></summary>

The requirement is real rather than fashionable. A POS listing has lane counts, offline mode, peripheral certifications and payment-terminal compatibility. An inventory tool has stock-count methods, replenishment models and warehouse integrations. A loyalty engine has points models and campaign types. Fixing those as columns means either a sparse table with hundreds of mostly-null columns, or a migration every time the marketplace opens a category — and opening categories is the growth path of the business, so making it an engineering event is a structural mistake.

What people get wrong is treating "schemaless" as "unvalidated". The store having no schema does not mean the *system* has no schema; it means the schema moved from the database into the application, and it now has to be a first-class artefact rather than an accident. `facet_schemas` is that artefact: one document per category, declaring the attribute keys, their types, which are facetable, their permitted value domains and their display order. `product_category.facet_schema_ref` points at it, and it is the only cross-store pointer in the relational schema.

The write path then does what a database `CHECK` constraint would have done: `vendor-service` loads the category schema and builds a Pydantic model from it to validate submitted `attributes`. Unknown keys are rejected rather than absorbed, which matters because absorbing them is how a document store silently accumulates six spellings of the same field. Adding a category becomes a document insert plus a facet-projection mapping — a data change with a review, not a schema migration with a deploy.

The cost I would name up front is that the validator now has a lifecycle. Schemas version, existing documents stay on the version they were written against, and something has to handle both. That is a genuine open problem in this design rather than a solved one, and I would prototype the answer before shipping the first category rather than after the tenth.

</details>

---

### Q1. Walk me through what lives in PostgreSQL versus MongoDB, and what decides the seam between them.

**Brief answer**
PostgreSQL holds the spine — identity, ownership, category, status, publication time, structured pricing — because it has referential integrity and participates in shortlists and connections. MongoDB holds the body, the category-specific attributes. The seam is filterability: anything a retailer can filter on must be queryable relationally, so it gets projected back into PostgreSQL.

<details>
<summary><strong>Detailed answer</strong></summary>

The two responsibilities in the brief look contradictory — MongoDB holds product metadata, PostgreSQL holds product listings used by search — and the resolution is that a listing has two halves with different governance.

The spine is relational because it has relationships. A `product` row has a foreign key to its vendor and its category, it is referenced by `shortlist_item` and `connection_request`, and its `status` gates publication. Those are integrity constraints a document store cannot express, and getting them wrong means an orphaned shortlist entry or a connection request against an archived listing. Structured pricing sits here too, in `product_price_tier`, because the comparison view sorts and ranges over price — a query the database has to be able to plan. Free-form pricing prose stays in the document, because nobody filters on prose.

The body is documental because it genuinely has no fixed shape across categories. It lives in `product_metadata`, keyed by the PostgreSQL `product.id`, so the two stores join without a mapping table — that identity choice removes a whole class of drift.

The seam is where the design earns its keep. A facet a retailer filters on cannot live only in Mongo, because the search query is a relational query with keyset pagination and partial indexes. So `indexer-worker` projects the facetable subset of the document into `product_listing_facets` in PostgreSQL, denormalised and flat. That projection is the price of the split, and it is exactly why catalog reads are eventually consistent rather than strongly consistent: the projection trails the document by seconds. The design accepts that lag explicitly, budgets it at a 95th percentile under five seconds, and measures it as `indexer_lag_seconds` — an unmeasured lag is the version of this pattern that fails.

</details>

---

### Q1. What is a transactional outbox, and what exact problem does it solve that a "commit then publish" call does not?

**Brief answer**
It writes the event into the same database transaction as the state change, so the two commit atomically, and a separate relay publishes it afterwards. It solves the dual-write problem: committing to the database and then publishing to a broker are two operations that can fail independently, and a crash between them loses the event with no trace.

<details>
<summary><strong>Detailed answer</strong></summary>

The naive version is: commit the listing publish, then publish `catalog.listing.published` to the topic. If the process dies between those two lines — a pod eviction, an out-of-memory kill, a network blip talking to the broker — the listing is published in the database and nobody downstream ever hears about it. The listing never becomes searchable, no notification goes out, and nothing in the system is in an error state. That is the worst class of bug: consistent-looking, silent, and only discovered by a vendor complaining.

Reversing the order is not better. Publish first, then commit, and a crash gives you an event for a state change that never happened — consumers project a listing that does not exist.

The outbox removes the dual write. `outbox_event` is an ordinary PostgreSQL table, and the row is inserted in the same transaction as the `product` update. Either both land or neither does; there is no window. A relay then queries the unpublished rows — served by a partial index on `(occurred_at) WHERE published_at IS NULL`, which stays tiny because published rows leave it — pushes them to Azure Service Bus, and stamps `published_at`.

The guarantee this yields is at-least-once, never zero-times. The relay can crash after publishing and before stamping, which redelivers the event. That is why every consumer in the catalogue is idempotent on `event_id`, and why the projection additionally ignores an event whose `source_revision_id` is older than the row's current value. Exactly-once across a database and a broker does not exist without a distributed transaction, and paying for one here would be absurd — so the design buys at-least-once and pushes the deduplication into the consumers, where it is cheap.

The operational tell that the relay has stalled is `outbox_unpublished_age_seconds`, alerted above 300 seconds. Without that metric, a stopped relay looks exactly like a quiet afternoon.

</details>

---

### Q1. `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product`. Why deliberately denormalise, and what is the rule for when that is acceptable?

**Brief answer**
So that the hot search query touches exactly one relation and never joins. It is acceptable because the table is a single-writer read model with no independent authority — the copy can only ever be stale, never contradictory, and staleness is already the accepted property of this path.

<details>
<summary><strong>Detailed answer</strong></summary>

Faceted search is the highest-traffic query in the system and the one with the most optional predicates. Every join it has to perform is another relation the planner must estimate selectivity for, and joins are where plans go wrong as data grows. Flattening the three columns the query filters and orders on means the plan is a single index scan on `product_listing_facets` with no nested loop to get wrong.

The `status` copy earns the most, because it enables the partial index. `idx_plf_browse` is defined `WHERE status = 'published'`, which keeps drafts and archived listings out of the index entirely — roughly 40,000 rows in the index out of 55,000 in the table — and removes the status filter from every plan that uses it. You cannot build a partial index on a predicate that lives in another table.

The rule I apply for whether denormalisation is safe has three parts. First, single writer: only `indexer-worker` writes this table, so there is no possibility of two components disagreeing about the value. Second, no independent authority: nothing treats `product_listing_facets.status` as the truth — the authoritative status is `product.status`, and the vendor workspace reads that directly rather than the projection. Third, a reconciliation path: a nightly job re-projects any `product` whose `projected_at` predates its `updated_at` by more than five minutes, so a lost event self-heals rather than leaving a permanently wrong row.

Where denormalisation goes badly is when those conditions are not met — two writers, or a consumer treating the copy as authoritative for a decision that matters. The same pattern appears on `connection_request.vendor_id`, copied from `product` so vendor-side connection queries need no join, and it is safe for the same reason: a listing does not change vendor, so the copy is not merely single-writer, it is immutable.

</details>

---

### Q2. On a listing publish, the MongoDB write happens before the PostgreSQL commit. Why that order specifically, and what cleans up when it goes wrong?

**Brief answer**
Because the two failure modes are not symmetric. An orphaned revision document that no `product` row points at is invisible and reclaimable; a committed pointer to a document that does not exist is a broken listing a user hits. A nightly reconciliation job deletes the orphans.

<details>
<summary><strong>Detailed answer</strong></summary>

There is no transaction spanning PostgreSQL and MongoDB, so one of the two writes lands first and the process can die in between. The design does not pretend otherwise — it picks the order whose garbage is harmless.

Writing Mongo first means the crash window leaves a `product_metadata_revisions` document with no `product.current_revision_id` pointing at it. Nothing reads it, because every read path starts from the relational spine and follows the pointer. It occupies a few tens of kilobytes and is otherwise inert. Reversing the order means the crash window leaves `product.current_revision_id` pointing at a document that was never written, and the detail endpoint returns a 500 for a listing that looks published in every listing view. One is a storage cost, the other is a user-visible defect that also breaks the projection.

Cleanup is a nightly Celery job on the `indexing` queue. It lists revision documents created more than twenty-four hours ago with no matching `current_revision_id` and no successor revision, and deletes them. The twenty-four hour window matters — sweeping aggressively would race a publish that is legitimately in flight. The same job does the other half of the reconciliation: re-projecting any `product` whose `projected_at` trails its `updated_at` by more than five minutes, which is the backstop for an event that was published but never consumed.

The general principle is that when you cannot have atomicity, you choose which inconsistency you are willing to live with, and then you build the thing that converges. A design that picks an order and stops there has not solved the problem, it has only made it rarer — and rarer failures are harder to diagnose, not easier. The reconciliation job is what turns "usually consistent" into "eventually consistent", and the difference between those two is whether anyone can sleep.

</details>

---

### Q2. Walk me through what happens when `indexer-worker` receives the same event twice, and when it receives two events out of order.

**Brief answer**
Duplicate delivery is a no-op because the projection is an upsert keyed on `product_id`. Out-of-order delivery is rejected because the upsert ignores an event whose `source_revision_id` is older than the row's current value, so a stale event cannot roll a listing backwards.

<details>
<summary><strong>Detailed answer</strong></summary>

At-least-once delivery makes both of these normal operating conditions rather than exceptional ones. The relay can publish and crash before stamping `published_at`; Service Bus redelivers anything not settled within the lock duration; a competing-consumer subscription with two worker pods can process two events for the same product concurrently.

Duplicates are handled by making the write idempotent in the database rather than by remembering what has been seen. The projection is `INSERT ... ON CONFLICT (product_id) DO UPDATE`, so reprocessing the same event produces the same row. Nothing consults a "have I seen this event id" set, because such a set is itself state that can be lost, and losing it converts a safe design into an unsafe one at exactly the worst moment. The rule I hold generally is that any handler which must not double-apply needs a natural key or a unique constraint in the system of record — a Redis-based deduplication table is a latency optimisation and must never be load-bearing.

Ordering is the harder half, and it is the one people forget. Two revisions published seconds apart can arrive in either order, and if the older one wins the listing silently reverts to previous content. The guard is the monotonic `source_revision_id`: the `DO UPDATE` clause carries a `WHERE excluded.source_revision_id > product_listing_facets.source_revision_id` predicate, so an older event updates zero rows and completes successfully. It must complete successfully rather than raise — an out-of-order event is not an error, and treating it as one dead-letters perfectly healthy traffic.

Cache invalidation follows the same event, and it is safe for a different reason: keys are suffixed `v{rev}`, so a stale cached value is simply unreachable once the revision pointer moves. Correctness there does not depend on the purge message arriving at all, which is what lets me treat Redis as fully expendable.

The one thing this does not protect against is an event that never arrives. That is why the reconciliation job exists, and why `indexer_lag_seconds` pages at sixty seconds — a dead indexer produces no errors anywhere, only listings that quietly never become searchable.

</details>

---

### Q2. A category's `facet_schemas` document changes shape — an attribute is renamed and a new facet is added. What breaks, and what are your options?

**Brief answer**
Existing `product_metadata` documents stay on the old `schema_version`, so the projection must handle both shapes at once, and any facet filter over the renamed key silently stops matching older listings. The options are lazy migrate-on-read, a backfill job, or a hard per-category version cutover — and the choice sets the cost of every future category change.

<details>
<summary><strong>Detailed answer</strong></summary>

The failure here is not an exception, it is a wrong result set. `indexer-worker` reads a document whose attribute key no longer matches the mapping, projects a null into `product_listing_facets.facets`, and the listing drops out of that filter. The vendor sees their listing still published, the retailer just never finds it. No alert fires, because nothing failed.

The three options trade differently:

**Lazy migrate-on-read** — the projection understands every historical `schema_version` and normalises on the way through. Nothing needs backfilling, and old documents stay valid forever. The cost is a mapping layer that only ever grows, and after four versions nobody can say what a given category's document actually looks like. This is the option that never causes an incident and slowly becomes unmaintainable.

**Backfill** — write a migration job that rewrites every document of that category to the new shape, then drop support for the old one. The projection stays simple. The cost is a real data migration over the affected subset, run with the same care as a schema migration: batched, resumable, verified by comparing projected rows before and after, and reversible. At 40,000 listings across many categories this is very tractable; the affected slice is usually a few hundred documents.

**Hard cutover** — new schema version applies to new revisions only, and old listings must be re-published by their vendor to move. Cheap to build, and it pushes the cost onto vendors, which for a marketplace is the wrong direction.

I would default to backfill for renames and additive-only handling for new facets — a new facetable key is simply absent on old documents, and absent should project as null rather than as an error, so adding a facet needs no migration at all. The rule that keeps this cheap is designing changes to be additive by default and reserving the migration for the genuinely destructive ones.

What I would insist on regardless is a schema-change checklist that includes re-running the projection over the affected category and diffing the facet counts before and after. A rename that silently drops 300 listings out of a filter is invisible unless something counts.

</details>

---

### Q2. The admin workspace can edit vendors, retail chains, stores and products directly. How do you stop admin writes from bypassing the invariants the vendor API enforces?

**Brief answer**
By making the admin console call the same versioned public API rather than a private backend, so there is no second write path whose rules can drift. The bypasses that remain are explicit, gated on the `platform` account type, and every one of them writes an audit record.

<details>
<summary><strong>Detailed answer</strong></summary>

The requirement behind the admin panel was that vendor teams could update listings and category managers could shortlist without raising engineering tickets — which means the panel has to reach every entity a support ticket would otherwise touch. The tempting implementation is an internal admin backend with direct database access, because it is faster to build and nobody outside sees it. That is the mistake. It creates a second write path with its own copy of the invariants, and within a few months the two disagree: the vendor API refuses to publish a listing for a `pending` vendor and the admin path does not, so a support action creates a state the domain believes is impossible.

The design instead serves the admin console as a static single-page application from blob storage through the edge, and it calls `/v1/admin/*` endpoints on the same services, defined by the same Pydantic models, generating the same OpenAPI document, covered by the same functional contract tests. The consequence I would state plainly is that no admin capability exists which the public API contract does not already describe and test. The cost is a chattier interface on screens that join across services, since there is no bespoke aggregate endpoint — I accepted that, because the alternative buys a faster screen with an unverifiable rule set.

Where admin genuinely needs more power, the extra power is named rather than implicit. Tenant scoping is applied by the repository layer from the token's `org_id`; the `platform` account type has no `org_id` and bypasses that filter explicitly, in one code path, and the bypass writes an `audit_event`. Same for state transitions: an operator suspending a vendor goes through a state-transition endpoint that runs the same guard logic, not an `UPDATE` on `status`.

The test that matters most here is the negative one — for every org-owned repository method, assert that a non-platform token from another organisation gets an empty result. That is a control whose failure is silent, so it needs a test that fails loudly.

</details>

---

### Q2. Monetary values are integer minor units with an explicit currency, price tiers are relational, and free-form pricing prose stays in Mongo. Walk me through each of those three decisions.

**Brief answer**
Integer minor units because floating point cannot represent decimal money exactly and errors accumulate across aggregation. Relational tiers because the comparison view sorts and range-filters on price. Prose in the document because nobody queries prose, and putting it in a column buys nothing while constraining it.

<details>
<summary><strong>Detailed answer</strong></summary>

On representation: a `float` cannot hold 0.10 exactly, and in a marketplace comparing subscription pricing across vendors the errors show up as a total that is a cent off, which erodes trust in every number on the page. Storing `price_minor bigint` with an explicit [ISO-4217](https://www.six-group.com/en/products-services/financial-information/data-standards.html "ISO 4217 — Standardizes three-letter currency codes for unambiguous monetary values") `currency char(3)` makes arithmetic exact and makes the currency impossible to forget — a bare number column invites the assumption that everything is euros, and this is a European marketplace with vendors pricing in several currencies. The rule is that the unit travels with the value. Comparison across currencies then becomes an explicit conversion with a stated rate and timestamp, rather than an accidental addition.

On structure: `product_price_tier` is relational because the comparison workflow does real query work over it — sort by entry price, filter to a ceiling, band by store count. `price_from_minor` is additionally projected into `product_listing_facets` with its own partial index, `idx_plf_price`, because "cheapest first within a category" is a high-frequency access pattern and it needs a leading index rather than a sort over a filtered set. Modelling tiers as a nested array inside the Mongo document would have made all of that an application-side scan.

On prose: pricing almost always carries qualifications — volume commitments, implementation fees, what a "lane" means for that vendor. That text is essential to a sourcing decision and useless to a query. Forcing it into a column adds a schema commitment with no query benefit, and the moment one vendor wants two paragraphs and another wants a table you are back to modelling free-form content in SQL.

The general seam is the same one that runs through the whole data design: structured where the database has to reason about it, documental where it only has to store and return it. What makes that seam maintainable rather than arbitrary is that the facetable subset is declared in `facet_schemas`, so the boundary is written down rather than remembered.

</details>

---

### Q3. Argue the other side: everything in PostgreSQL, `JSONB` for the metadata. What does that design get right, and what would make you switch to it?

**Brief answer**
It removes the projection pipeline, the lag, the reconciliation job and an entire operational dependency — one store, one transaction, no eventual consistency on publish. I would switch if metadata write volume stayed low and category churn turned out to be rarer than expected, because then the two-store design is paying a permanent cost for flexibility nobody uses.

<details>
<summary><strong>Detailed answer</strong></summary>

The `JSONB`-only design is genuinely defensible and I want to be honest that this was a close call rather than an obvious win. Its advantages are large. A publish becomes one transaction, so there is no dual write, no ordering rule, no orphan reconciliation and no window where the two stores disagree. `product_listing_facets` might not need to exist at all, since the facets could be a `JSONB` column on `product` with a `jsonb_path_ops` Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) over it — which collapses the projection lag to zero and deletes `indexer_lag_seconds` from the alert list. One database to back up, one to tune, one to be expert in. For a small team that last point alone can decide it.

What tips it the other way here is the vendor-facing authoring surface rather than the read path. Per-category schema validation, immutable document revisions, and staged bulk imports are MongoDB's native shape. In PostgreSQL, revisions become a history table with the document duplicated per revision, and import staging becomes another table with its own cleanup job rather than a collection with a thirty-day time-to-live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires")) index. None of that is hard; it is just all hand-built.

The cost of `JSONB` that gets underestimated is write amplification. PostgreSQL rewrites the whole row on update, and a 60 kilobyte `JSONB` document with a GIN index on it produces substantial write and index maintenance on every revision — on the same table that serves search. The two-store split trades that for projection lag. So the real trade is: heavier writes on the read-serving table, or a lag with a pipeline to maintain.

What would change my mind is evidence rather than taste. If after a year the catalog had six categories instead of thirty, revisions were infrequent, and the projection pipeline was the source of most of the operational noise, then it is paying for flexibility that never materialised and I would consolidate. The migration direction is favourable too — moving documents into `JSONB` is a backfill, whereas splitting a `JSONB` column out into a document store later is the same backfill plus building the pipeline. That asymmetry is a fair argument for starting with `JSONB` and earning MongoDB, and I would take it seriously on a greenfield build with an uncertain category roadmap.

</details>

---

### Q3. Volume goes up tenfold — 400,000 listings, high-churn attributes, imports running most of the day. What breaks first in this data model?

**Brief answer**
The projection pipeline, not the stores. `indexer-worker` throughput and the cache invalidation it triggers are the first constraint, and the symptom is `indexer_lag_seconds` climbing until search results are visibly stale rather than anything failing outright.

<details>
<summary><strong>Detailed answer</strong></summary>

Take the components in order of how close each is to its limit.

The stores themselves are comfortable. 400,000 listings is roughly 150 gigabytes in Mongo and a `product_listing_facets` table still well within what one PostgreSQL node handles; the declared sharding trigger is around 2,000 sustained write transactions per second or a one terabyte working set, and neither is approached. The unbounded tables — `audit_event` and `connection_message` — are partitioned monthly and detached on schedule, so their resident size plateaus rather than growing linearly.

The projection is a different story, because its load scales with *change* rather than with size. High-churn attributes mean many revisions per listing per day, and each one produces an event, a Mongo read, a PostgreSQL upsert with `tsvector` and GIN index maintenance, and cache purges. GIN indexes are the specific pain point: they are expensive to update, and PostgreSQL buffers that work in the pending list, so heavy churn either slows writes or defers the cost into unpredictable cleanup pauses on the same table serving search.

The mitigations I would reach for, in order. First, coalesce: if a listing is revised five times in a minute, project once — the projection is idempotent and only the latest revision matters, so debouncing per `product_id` over a short window is free correctness-wise and cuts work proportionally to churn. Second, widen the batching already used for imports, which projects in batches of 200 rather than per row, and apply it to steady-state churn as well. Third, separate the queue so high-churn bulk projection cannot starve the interactive publish path — a vendor clicking publish should not queue behind a 20,000-row import.

The second thing to break is cache hit ratio. The 95th-percentile latency budget assumes an 85% hit rate on search pages; heavy churn purges facet counts constantly and the hit rate collapses, so uncached path latency becomes the typical latency rather than the tail.

The thing that would *not* break, and this is worth saying, is correctness. Every mechanism here — idempotent upsert, revision ordering, revision-suffixed cache keys, reconciliation — is already designed for redelivery and concurrency. Tenfold volume makes it slow before it makes it wrong, which is the failure direction I want.

</details>

---

### Q3. A large vendor complains that the comparison matrix shows null cells for their product. They want completeness enforced. What does that demand of the model, and would you do it?

**Brief answer**
Enforcing completeness means making every facetable attribute in a category required at publish, which blocks listings rather than improving them. I would refuse the general version and instead make the gap visible and actionable, because an empty cell is itself sourcing signal.

<details>
<summary><strong>Detailed answer</strong></summary>

The comparison matrix is the union of the compared categories' facet schemas, with a cell null wherever a vendor did not supply that attribute. The vendor's complaint is real — a row of blanks reads as a weaker product. But the fix they are asking for has consequences they are not weighing.

Requiring every attribute means a vendor cannot publish until they have answered every question the category schema asks, including ones that do not apply to their product. The predictable outcomes are that listings do not get published, or worse, that vendors fill fields with placeholder values to get past the gate. The second is far more damaging than a null, because a false "yes" on an integration is a retailer discovering the gap after a procurement process. A null is honest ignorance; a coerced value is misinformation, and the data model cannot tell them apart afterwards.

There is also a structural argument. The whole point of the schemaless body is that categories differ and the platform cannot fix in advance what every product must declare. Mandatory completeness reintroduces exactly the rigidity the design removed, one category at a time.

What I would actually build has three parts. First, distinguish "not supplied" from "not applicable" in the schema — those are different facts and rendering them identically is the real defect. Second, give vendors a completeness score in their workspace with the missing attributes listed, so the incentive is visible before publish rather than after a complaint; marketplaces generally get better data from a visible completeness meter than from a hard gate. Third, allow a category schema to mark a small set of attributes as genuinely required — the two or three that no meaningful comparison can proceed without — so "required" stays credible instead of becoming a blanket.

The trade-off I would state to the vendor directly is that the platform optimises for the retailer's ability to compare honestly, and that a matrix which shows gaps is more useful to a buyer than one which hides them. That answer is also the commercially correct one: buyers leaving because the comparison misled them costs more than one vendor's dissatisfaction.

</details>

---

### Q3. Retailers already run enterprise resource planning and inventory systems. `integrations text[]` is a filterable facet. What does taking that seriously demand of the model?

**Brief answer**
Integration compatibility is the attribute that actually decides a sourcing outcome, and modelling it as a free-text array makes it filterable and unreliable at the same time. Taking it seriously means a controlled vocabulary with versions and a stated depth of integration, which is a governance problem more than a schema one.

<details>
<summary><strong>Detailed answer</strong></summary>

In retail sourcing this is often the deciding question. A chain running a particular enterprise resource planning ([ERP](https://en.wikipedia.org/wiki/Enterprise_resource_planning "Enterprise Resource Planning — Integrated software that manages an organization's core business processes")) suite for stock and finance cannot adopt a point-of-sale system that does not talk to it, no matter how good the product is. So `integrations` is not a nice-to-have facet alongside country coverage — it is close to a hard filter, and its data quality determines whether the comparison is useful or misleading.

The current model is a `text[]` on `product_listing_facets` with a GIN index for containment, populated from the vendor's metadata document. Query-wise that is right. The problem is upstream: if vendors type the value, you get several spellings of the same system, product names that changed between versions, and vendors claiming an integration that is a nightly comma-separated file export rather than a live interface. A retailer filters, gets matches, and discovers during procurement that the integration does not mean what they assumed. That is worse than not offering the filter.

What taking it seriously requires:

**A controlled vocabulary**, owned by the platform rather than by vendors. Integration targets become entities with identifiers, not strings — which the facet schema can express as an enumerated value domain, so validation at write time rejects an unknown value instead of absorbing it. Adding a target is a curation action.

**Version and depth as first-class attributes.** "Integrates with X" is not one fact. Which major versions, and what kind of integration — certified interface, published connector, generic file exchange, or a professional-services project. Modelling those as a structured object per integration rather than a flat string is what lets a retailer filter on something meaningful, and it turns the comparison matrix from marketing into information.

**Evidence, eventually.** The strongest version is vendor-supplied claims plus operator verification for the categories where it matters most, similar to the vetting that already gates publication.

The reason this is a data-model conversation and not just a product one is the seam. A structured integration object lives naturally in the Mongo document, but the filter needs a flat, indexable projection — so the projection has to derive a queryable form, most likely a normalised array of identifiers for containment plus the structured detail on the detail page. That is exactly the pattern the design already uses, and this is a good example of why the facetable subset being declared in the schema, rather than inferred, keeps the model honest as attributes get richer.

</details>

---

## SQL Performance, Indexing and Migrations at Scale

---

### Q1. What is a GIN index, how does it differ from a B-tree, and where is each one right in this schema?

**Brief answer**
A B-tree indexes a whole value and supports ordering and ranges; a Generalized Inverted Index (GIN) indexes the *elements inside* a composite value — array members, `jsonb` keys and paths, lexemes in a `tsvector` — and supports containment. Here B-trees serve browse ordering and price ranges, GIN serves free text, array filters and category-specific attributes.

<details>
<summary><strong>Detailed answer</strong></summary>

A B-tree stores keys in sorted order, so it answers equality, ranges and ordered scans, and it can satisfy an `ORDER BY` without a sort step. That is why `idx_plf_browse` is a B-tree on `(category_slug, published_at DESC, product_id)` — the default browse is "this category, newest first, paged", and a B-tree returns exactly that in index order with no sort node in the plan.

GIN inverts the relationship. For each element inside a value it stores a posting list of the rows containing it, which is what you need when the query asks "does this array contain Germany" or "does this document have `offline_mode = true`". Three of the four catalog filters are that shape: `country_coverage text[]` and `integrations text[]` under `idx_plf_arrays`, the arbitrary category attributes under `idx_plf_facets` with `jsonb_path_ops`, and the free-text `search_vector` under `idx_plf_search`.

The `jsonb_path_ops` choice is worth calling out. The default `jsonb_ops` operator class indexes keys and values separately and supports more operators; `jsonb_path_ops` indexes hashes of whole paths, which makes the index substantially smaller and containment queries faster, at the cost of only supporting the containment operator. Since the facet queries are all containment, that is a straight win — but it is a decision you have to make deliberately, because the default is the slower one for this workload.

The properties that bite are GIN's write cost and its ordering blindness. GIN updates are expensive, which is why `search_vector` is maintained by `indexer-worker` rather than by a trigger inside the vendor's publish transaction — a trigger would couple write latency on the authoring path to text-search index maintenance for a value only the read projection needs. And GIN cannot order, so a query filtered by GIN and ordered by `published_at` still needs either a sort or a B-tree to take over. That interaction is the core of the search bottleneck in this system.

</details>

---

### Q1. What is a partial index, and what does `idx_plf_browse` specifically buy by carrying `WHERE status = 'published'`?

**Brief answer**
A partial index covers only the rows matching a predicate. Here it keeps drafts and archived listings out of the index entirely — roughly 40,000 indexed rows out of 55,000 — and, because the predicate is implied by membership, the planner drops the status filter from every plan that uses it.

<details>
<summary><strong>Detailed answer</strong></summary>

Two benefits, and the second is the one people miss.

The obvious benefit is size. Only published listings are ever searchable, so indexing drafts and archived rows is pure overhead: a larger index, more pages to read, more maintenance on every write. Excluding roughly a quarter of the table makes the index measurably more likely to stay resident in the buffer cache, and buffer residency is usually what separates a five-millisecond index scan from a fifty-millisecond one.

The subtler benefit is planning. When the planner recognises that a query's `WHERE status = 'published'` is implied by the index predicate, it does not need to re-check the condition — the filter disappears from the plan node rather than being applied per row. It also improves the row estimates, because the index statistics describe only the relevant population. Bad estimates are the usual root cause of a plan that degrades from an index scan to a sequential scan as a table grows, so anything that improves them is buying stability, not just speed.

`idx_plf_price` uses the same technique with a compound predicate — `WHERE status = 'published' AND price_from_minor IS NOT NULL` — because price-sorted browse is meaningless for listings with no entry price, and excluding the nulls means the index is dense.

The cost is that a partial index is only usable when the planner can prove the query implies the predicate. If someone writes a query with `status = ANY(ARRAY['published'])` or passes the status as a parameter the planner cannot fold, the index is silently unusable and the query falls back to a sequential scan with the same result and twenty times the cost. That is a real trap: partial indexes fail by being ignored, not by erroring. It is why the search query is built with SQLAlchemy Core with the predicate written literally, and why there is a test asserting the plan uses the expected index rather than only asserting the result set.

</details>

---

### Q1. What is keyset pagination, and why does this API use it everywhere instead of `OFFSET`?

**Brief answer**
Keyset pagination carries the last row's sort key as a cursor and asks for rows after it, so every page costs the same. `OFFSET n` makes the database produce and discard `n` rows, so page 40 costs forty times page 1 — and a comparison workflow generates deep pages.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanics: instead of `ORDER BY published_at DESC LIMIT 20 OFFSET 780`, the query is `WHERE (published_at, product_id) < (:cursor_ts, :cursor_id) ORDER BY published_at DESC, product_id DESC LIMIT 20`. The row comparison maps directly onto `idx_plf_browse`, so the database seeks into the index at the cursor position and reads twenty entries. It never touches the 780 rows before it.

Two properties follow. Performance is flat rather than linear in page depth, which matters here because sourcing is a comparison workflow — a category manager evaluating point-of-sale systems genuinely pages deep, unlike a consumer who abandons after page two. And results are stable under concurrent writes: with `OFFSET`, a listing published while someone is on page 3 shifts everything down, so a row on the page boundary is either shown twice or skipped entirely. Keyset anchors on a value rather than a position, so a new insert simply does not appear in pages already passed.

The two implementation details that decide whether it actually works. First, the sort key must be unique, which is why the cursor is the composite `(published_at, product_id)` rather than the timestamp alone — two listings published in the same millisecond would otherwise make the boundary ambiguous and drop a row. Second, the cursor must be opaque to the client: encoded, and ideally signed or at least validated, so it cannot be edited into a probe of somebody else's ordering, and so its internal shape can change without breaking clients.

The cost is the honest one: you cannot jump to page 40 directly, only forward and backward. For a sourcing tool that is fine — nobody deep-links to a page number in a filtered comparison. If a random-access requirement ever appeared, it would need a different design rather than a fallback to `OFFSET`, because mixing the two reintroduces the cost on exactly the deep pages you were protecting.

</details>

---

### Q1. You are handed a slow query. What does `EXPLAIN (ANALYZE, BUFFERS)` tell you, and what do you look at first?

**Brief answer**
It runs the query and reports the actual plan with real timings and row counts alongside the planner's estimates, plus how many blocks came from the buffer cache versus disk. The first thing I look at is the ratio of estimated to actual rows, because a bad estimate is the usual root cause and the slow node is usually a symptom of it.

<details>
<summary><strong>Detailed answer</strong></summary>

`EXPLAIN` alone shows the plan the planner would choose with its estimates. Adding `ANALYZE` executes the query and adds actual row counts and per-node timing, which is the only way to see where the estimate diverged from reality. Adding `BUFFERS` reports shared hits versus reads, which distinguishes "this query is expensive" from "this query is expensive right now because the data is not cached" — a distinction that decides whether you rewrite the query or provision more memory.

My reading order:

Estimated versus actual rows on every node, worst ratio first. A node estimating 50 rows and returning 500,000 explains everything downstream: the planner chose a nested loop because it thought the outer side was tiny, and now it is running half a million lookups. Fixing the estimate — better statistics, a raised statistics target on a skewed column, or a rewrite that gives the planner something it can estimate — usually fixes the plan without touching indexes at all.

Then the node types. A sequential scan on a large table where an index exists means either the index is unusable (the partial-index trap, a type mismatch, a function wrapping the column) or the planner believes the scan is cheaper because it expects to return most of the table. A bitmap heap scan with high "rows removed by filter" means the index narrowed poorly and the real work happened after. A sort with external merge means `work_mem` was insufficient and it spilled to disk.

Then buffers. High `read` against low `hit` on a repeated query points at a working set that does not fit, not at query shape.

For this system specifically, the query I would run this against is the faceted search, because its failure mode is exactly a bad estimate: PostgreSQL's selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor on high-cardinality data, so the planner can choose a bitmap `OR` across several GIN indexes that degrades toward a sequential scan. That is why the 45-millisecond figure in the design is marked as needing verification against a seeded table on the pinned version rather than assumed — and why the remedy if the plan is wrong is a composite covering index per high-traffic category, not a larger instance.

</details>

---

### Q2. The faceted search accepts free text, a category, two or three array containments, a price ceiling and a deployment model, all optional. Walk me through why that degrades, and how you fixed it.

**Brief answer**
Many optional predicates over several GIN indexes lets the planner combine them into a bitmap that is unselective, and as the table grows it tips toward a sequential scan. The fixes were a single denormalised table with no joins, a partial index carrying the status predicate, keyset pagination, and a product rule that a facet-heavy query must name a category.

<details>
<summary><strong>Detailed answer</strong></summary>

The shape of the problem is that every optional filter multiplies the number of distinct query plans the system can produce, and the planner must estimate selectivity for each combination. For array containment and `jsonb` path containment those estimates are weak, so it can decide that a bitmap `OR` across `idx_plf_arrays` and `idx_plf_facets` is cheap, build a bitmap covering most of the table, and then filter the heap. At 5,000 rows that is fine. At 40,000 with a growing index it starts losing to a plain scan, and the planner eventually agrees and stops using the indexes — at which point latency jumps discontinuously rather than degrading gradually, which is why this class of problem surfaces as an incident rather than a trend.

The mitigations, in the order they mattered:

**One relation, no joins.** `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product` so the hot query touches a single table. Every join removed is one fewer selectivity estimate to get wrong.

**A partial index that carries the status predicate.** `idx_plf_browse` is defined `WHERE status = 'published'`, keeping unpublished rows out entirely and removing the filter from the plan.

**Keyset pagination**, so deep comparison pages do not add cost on top of an already marginal plan.

**A category is required for facet-heavy queries.** The API refuses an uncategorised query carrying more than two facet predicates. This is the one that converts a hope into a guarantee: with a category present, `idx_plf_browse` or `idx_plf_price` is always a viable leading index, so there is always a selective entry point rather than a bitmap over the whole table.

**`total_estimate` rather than an exact count**, because an exact count over a filtered GIN scan costs roughly as much as the page itself and doubles the work for a number nobody acts on.

What I would insist on before trusting any of it is verification: `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table at realistic cardinality on the pinned PostgreSQL minor version, and a regression test asserting the plan shape. Index design reasoned about on paper and never checked against a planner is a hypothesis, and this particular hypothesis is one I would expect to be partly wrong.

</details>

---

### Q2. Refusing an uncategorised query with more than two facet predicates is a product constraint bought for a performance guarantee. Defend that, and tell me when that trade is wrong.

**Brief answer**
It is defensible because it matches how sourcing actually works — nobody compares a point-of-sale system against a loyalty engine — so the constraint costs users nothing while removing the worst query shape entirely. It is wrong when the constraint blocks a real workflow, or when it is a substitute for understanding the query rather than a decision about the product.

<details>
<summary><strong>Detailed answer</strong></summary>

The engineering appeal is obvious: an unbounded query surface means an unbounded set of plans, and no amount of indexing makes every combination fast. Constraining the input converts "we hope the planner does something sensible" into "there is always a selective leading index". That is a much stronger position than tuning, because it holds as the table grows.

The reason it is legitimate here rather than a cop-out is that the constraint encodes a truth about the domain. Retail software categories are not comparable across type — the facets themselves differ, so a cross-category facet query is close to meaningless. A category manager sourcing checkout software starts by picking checkout software. The constraint is therefore invisible to correct usage, and the error it returns can be an actionable one: "narrow to a category to filter on these attributes", with the category list attached.

Where this trade goes wrong is when the constraint is chosen for the engineer's convenience and the user notices. If retailers genuinely wanted to search "everything offering German coverage and Software-as-a-Service deployment under a price ceiling" — a plausible cross-category query with three facets — the rule blocks a real workflow, and the honest response is to build for it: a materialised cross-category summary, or a narrower always-available facet set for uncategorised search, rather than telling the user their question is invalid.

The other way it goes wrong is as a substitute for diagnosis. Adding a constraint because a query was slow, without having read the plan, means you may have removed the symptom and left the cause — and the next feature reintroduces it. The order I insist on is: understand the plan, fix what is fixable in the schema and the indexes, and only then consider constraining the input. Here the constraint came last and is documented as a product decision with its rationale, which is what makes it reviewable by someone who is not an engineer.

The general principle is that constraining the problem is a legitimate and underused engineering tool, but it spends product surface, so it needs the product owner's agreement rather than an engineer's unilateral choice.

</details>

---

### Q2. The API returns `total_estimate` capped at 1,000 rather than an exact count. Why, and how would you produce the estimate?

**Brief answer**
An exact count over a filtered GIN scan costs about as much as fetching the page, because the database must visit every matching row to count it. The estimate comes from the planner's row estimate, refined by counting exactly up to a cap and reporting "1,000+" beyond it.

<details>
<summary><strong>Detailed answer</strong></summary>

The cost asymmetry is the whole point. Fetching twenty results with keyset pagination stops after twenty index entries. Counting the matches cannot stop — `COUNT(*)` over the same predicate must traverse the entire matching set, and with a bitmap heap scan it also has to visit heap pages for visibility checks, since PostgreSQL's Multi-Version Concurrency Control means the index alone cannot confirm a row is visible to this transaction. So the count is frequently the most expensive part of a search request, and it is paid on every page.

The estimate has two sources depending on the accuracy needed. The cheap one is the planner's own estimate, obtainable by running `EXPLAIN` on the count query and reading the estimated rows — no execution, essentially free, and accurate to within an order of magnitude, which is fine for "about 400 results". The more accurate one is a bounded exact count: run the count with a `LIMIT` inside a subquery so it stops at 1,001 rows, and report either the exact number or "1,000+". That is bounded work regardless of result-set size, and it gives an exact answer in the common case where the filtered set is small — which is precisely the case where users care about the number.

The product argument matters as much as the technical one. A sourcing workflow does not act on the difference between 1,247 and 1,000+. It acts on "is this filter narrow enough to work through" — and any number above a few hundred means "no, narrow it further". Paying a per-request cost for precision nobody uses is the definition of a bad trade, and the honest way to present it is in the interface: "1,000+ results, add a filter" is more useful than an exact count anyway.

The cost I would state plainly is that the pagination interface cannot show "page 7 of 63", and the design accepts that because keyset pagination already precludes jumping to page 63. Those two decisions are consistent, which matters — an exact count with keyset pagination would be paying for a number the navigation cannot use.

</details>

---

### Q2. You need to add a non-nullable column and an index to a table with well over a hundred million rows, with no downtime. Walk me through it.

**Brief answer**
Never in one migration. Add the column nullable with no default, backfill in bounded batches, add the index concurrently, then add the `NOT NULL` constraint as a validated check — and only after every deployed version of the application writes the column. Each step must be independently safe to abandon.

<details>
<summary><strong>Detailed answer</strong></summary>

The naive `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT ...` is the thing that takes production down. On older PostgreSQL versions it rewrites the table; even where the default is stored as metadata, adding `NOT NULL` requires a full validation scan under an `ACCESS EXCLUSIVE` lock, and on a hundred-million-row table that lock is held for minutes. Worse, the lock request queues behind running queries and every subsequent query queues behind the lock request — so a migration that would have taken two minutes takes the whole application down for as long as one long-running `SELECT` holds its share lock. That cascade is the part people are surprised by.

The sequence I use:

**Expand.** Add the column nullable, no default. This is a catalogue change only and takes milliseconds. Deploy the application version that writes the new column on every insert and update, while still tolerating null on read. Nothing depends on the column yet.

**Backfill.** A batched job updating a bounded number of rows per statement — keyed on the primary key so each batch is an index range, committing between batches, with a sleep to keep replication lag and dead-tuple accumulation under control. It must be resumable, because it will be interrupted. On a hundred million rows this runs for hours or days, and that is fine: nothing is blocked while it runs.

**Index.** `CREATE INDEX CONCURRENTLY`, which does not take a write lock. It is slower, cannot run inside a transaction — which matters for Alembic, since the migration must be marked non-transactional — and it can fail and leave an invalid index behind, so the migration has to check for and drop an invalid index before retrying. Silently leaving one is a classic: it is never used and still costs on every write.

**Constrain.** Add the constraint as `NOT VALID` first, which only checks new rows and takes a brief lock, then `VALIDATE CONSTRAINT`, which scans under a weaker lock that does not block reads and writes. Converting to a true `NOT NULL` column can then follow.

**Contract.** Any drop of an old column is a separate merge request at least one release later.

The rule underneath all of it is that the previous application image must run correctly against the new schema throughout, because that is the only thing that makes rollback possible. If a migration and a deploy must land together, you have no rollback, only roll-forward — and discovering that during an incident is how a bad deploy becomes a long outage.

</details>

---

### Q2. `catalog-service` reads a replica and falls back to the primary above thirty seconds of lag. What does that protect against, what does it not, and how would you catch a read-your-writes violation?

**Brief answer**
It protects browse throughput from competing with writes, and the fallback stops a badly lagging replica from serving visibly wrong data. It does not give read-your-writes to anyone, which is why the vendor workspace reads the primary and the metadata document directly rather than the projection.

<details>
<summary><strong>Detailed answer</strong></summary>

Replica reads exist because the read-to-write ratio is roughly 17:1 by request count and closer to 50:1 by database work, so the catalog read path is where the load is. Moving it off the primary keeps write latency stable and gives a second machine's worth of buffer cache for the search indexes.

What it costs is a second staleness window on top of the projection lag. A listing publish has to travel: commit on the primary, replicate, be projected by `indexer-worker`, and have its cache key purged. `postgres_replica_lag_seconds` is an explicit service level indicator with a five-second objective, and above thirty seconds `catalog-service` health-checks itself back to the primary — accepting elevated primary load in exchange for not serving data that is wrong enough to notice. That threshold is a judgement call and I would want it tuned against real lag distribution rather than left at a guessed number.

What the fallback does not do is provide read-your-writes for anyone, and that is the important part. A vendor who clicks publish and then loads their listing must see their change, and no amount of lag tuning guarantees that. The design routes around it rather than shrinking it: the vendor workspace reads `product` from the primary and the metadata document from MongoDB directly, never `product_listing_facets` and never the cache. Vendors therefore get read-your-writes; retailers get the fast, cached, slightly-stale projection, which is invisible to them because they were not the ones who changed anything. The one place a vendor sees the projection is an explicit "preview as a retailer sees it" view, where the lag is the point.

Catching a violation is the interesting part, because the symptom is intermittent and depends on timing. A functional test that publishes and immediately re-reads through the vendor endpoint will pass against a local single-node database no matter which connection it uses — the bug only appears with a real replica under lag. So the test has to run against the Compose topology with a replica and with lag deliberately induced, and the more reliable guard is structural: assert at the repository layer that vendor-workspace read methods are bound to the primary session, so choosing the wrong session is a test failure rather than a race. Controls whose failure is timing-dependent need a structural test, not a behavioural one.

</details>

---

### Q3. The client's system of record is InterSystems IRIS, with tables over a hundred million rows. Your experience here is PostgreSQL. How do you approach that, and what transfers?

**Brief answer**
Most of it transfers, because the hard part is not dialect — it is access-pattern-driven index design, migration safety at volume, and reading a plan. What does not transfer is [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage")'s specifics: its globals-based storage underneath the relational projection, its own plan syntax and tooling, and the fact that community knowledge is far thinner, so I would lean harder on measurement and on the people who already run it.

<details>
<summary><strong>Detailed answer</strong></summary>

I want to be straightforward: I have not run InterSystems IRIS in production, and I would not claim otherwise. What I would bring is the part of the work that is database-independent, and that is most of it.

The transferable core. Indexes exist to serve named access patterns, and every index in this design maps to one — a browse ordering, a price sort, a containment filter — with the corollary that an index nobody's pattern names is write cost with no return. Selectivity and cardinality reasoning is universal. So is the discipline around large-table migrations: expand/contract, nullable-then-backfill-then-constrain, batched and resumable backfills, index creation that does not hold an exclusive lock, and the rule that the previous application version must run against the new schema so rollback stays possible. On a hundred-million-row table those disciplines are not optional in any engine — the naive migration takes the system down on IRIS exactly as it does on PostgreSQL, and for the same lock-queueing reason.

What is genuinely different and where I would be careful. IRIS is a multi-model database whose relational surface sits over a globals storage engine, so the mapping from a table to physical structure is not the heap-plus-B-tree model my intuition is built on, and bitmap indexes play a much larger role than they do in PostgreSQL. Its query plan output and tuning tooling are its own, so my first task would be learning to read a plan there properly rather than assuming the shapes I know. Its locking and concurrency behaviour under bulk update is something I would characterise empirically before trusting any intuition. And practically, the answer to a strange behaviour is much less likely to be one search away than it is with PostgreSQL, which changes how I would work: more measurement, more small experiments against a realistic data volume, and more early conversation with whoever has been running it.

Concretely, in the first weeks I would want a representative-volume environment to test against, the existing migration history to see what the team already treats as safe, and the slow-query evidence for the tables that hurt. I would not propose changes to a hundred-million-row table on the strength of PostgreSQL analogies — I would reproduce, measure, and then propose.

The honest summary is that the engineering judgement transfers and the engine-specific knowledge does not, and I would rather say that plainly than discover it mid-migration.

</details>

---

### Q3. This design deliberately rejected Elasticsearch for PostgreSQL full-text search. Defend that, and name exactly what would reverse it.

**Brief answer**
40,000 listings with structured facets is well inside what PostgreSQL handles, and a search cluster would add a third data store, a second consistency lag and real relevance-tuning expertise for a requirement nobody had stated. It reverses if the 95th-percentile search exceeds 200 milliseconds after the index work, or if free-text relevance ranking becomes an actual product requirement.

<details>
<summary><strong>Detailed answer</strong></summary>

The case against adding it is about total cost rather than capability. Elasticsearch is better at text — no argument. But adopting it means a cluster to run, shard and replica sizing to get right, a second projection pipeline with its own lag and its own reconciliation, a second place tenant filtering must be enforced correctly, and a skill set the team has to actually have. The failure mode of an under-tended search cluster is not that it is slow; it is that results are subtly wrong and nobody notices, which for a marketplace means listings that exist and cannot be found.

Against that, the workload is small and structured. The dominant query is not "find documents about checkout" — it is "category equals point-of-sale, coverage contains Germany, deployment is Software-as-a-Service, price under X, newest first". That is a faceted filter with an ordering, which is a relational query. Free text is one optional predicate among several, served by a `tsvector` GIN index. PostgreSQL does that comfortably at this cardinality, and it does it inside the same transaction and the same tenant-filtering layer as everything else.

The reversal triggers are written down rather than left to taste, which matters because "should we add Elasticsearch" is otherwise an argument that recurs forever. First, measurement: if the 95th-percentile catalog search exceeds the 200-millisecond target after the indexing work — the partial indexes, the denormalised projection, the category requirement — then PostgreSQL has been given its best shot and lost. Second, requirement: if relevance ranking becomes a product feature, meaning results ordered by how well they match rather than filtered by whether they match, with boosting, synonyms and typo tolerance, that is not something to build on `ts_rank`.

The third trigger is the one I would actually bet on arriving first, and it is in the design as an open question: multilingual text. A single dictionary handles a monolingual catalog well and handles "Kassensystem" versus "POS" not at all. A European marketplace needs per-listing language configuration and probably trigram similarity for vendor-name fuzziness, and that is where PostgreSQL's text search gets uncomfortable rather than merely imperfect. I would prototype against real vendor copy before assuming the GIN index is sufficient, because that is a quality problem that never shows up in a latency graph.

</details>

---

### Q3. `audit_event` and `connection_message` grow without bound. Explain the partitioning strategy, and what changes about it at ten times the volume.

**Brief answer**
Both are declaratively range-partitioned by month, so retention is a metadata operation — detach the old partition and archive it — rather than a long-running `DELETE`. At ten times the volume the strategy holds; what changes is that `audit_event` should move out to cold storage entirely rather than living in the operational database.

<details>
<summary><strong>Detailed answer</strong></summary>

Why partitioning rather than deletion: removing a month of rows with `DELETE` on a large table produces an enormous number of dead tuples, hours of vacuum work, index bloat, and replication lag while it runs — all on the production primary, all to remove data nobody wanted. `DETACH PARTITION` is a catalogue operation that completes in milliseconds and leaves a standalone table you can archive and drop at leisure. Retention becomes cheap enough to actually enforce, which is the real point: retention policies that are expensive to execute quietly stop being executed, and then you are holding data you told a regulator you had deleted.

Monthly is the right granularity here because the retention windows are twenty-four months of audit and thirty-six months of closed-thread messages — so partition counts stay in the low tens, which keeps planning cost negligible. Daily partitioning at these volumes would give hundreds of partitions and a planner paying to prune them for no benefit.

The access patterns cooperate. Both tables are append-only into the current partition, so index maintenance happens in a small, cache-resident B-tree rather than across a huge one — which is a substantial write-throughput benefit independent of retention. And thread message reads are `WHERE thread_id = ? ORDER BY created_at DESC`, which prunes to recent partitions for the common case of an active conversation.

At ten times the volume, the mechanism does not change but the placement should. `audit_event` is already the largest contributor at roughly 25 gigabytes, and it is written by everything and read almost never — compliance queries and incident investigations. Keeping ten times that in the operational database means backup times, restore times and buffer cache all paying for data whose read rate is close to zero. The stated evolution trigger is to move it to blob-backed cold storage, and that is the move I would make well before sharding anything: it removes the largest table and most of the growth, and it is far less invasive than sharding a database that at that point still has a working set inside a terabyte.

The thing I would watch is that partition maintenance must be automated and monitored. A missing future partition means inserts start failing at midnight on the first of the month, which is a genuinely stupid way to have an incident and a very common one.

</details>

---

### Q3. The 45-millisecond search figure in the design is flagged as unverified. How do you actually establish a performance claim before building on it?

**Brief answer**
Reproduce the real conditions — realistic row count and cardinality, the pinned engine version, the actual query the application generates — and read the plan rather than the wall-clock time. A number measured against a seeded toy table is not evidence, and a number without a plan does not tell you whether it will survive growth.

<details>
<summary><strong>Detailed answer</strong></summary>

The specific claim at risk is that PostgreSQL combines `idx_plf_arrays` and `idx_plf_facets` into a bitmap `AND` rather than degrading toward a sequential scan. That depends on selectivity estimates for `text[]` containment and `jsonb_path_ops`, which are known to be poor for high-cardinality data. If the estimate is wrong, the plan is wrong, and the 45-millisecond figure is fiction — and since the whole latency budget is built on it, everything downstream is fiction too.

What a real verification needs:

**Realistic data, not just realistic volume.** Forty thousand rows of identical generated content will produce beautiful plans and tell you nothing, because selectivity depends on distribution. The seed has to reproduce the skew — a few categories holding most listings, country coverage heavily concentrated in a handful of markets, integration arrays with a long tail. Uniform random data is the classic way to prove a query fast that is slow in production.

**The pinned minor version**, because planner behaviour changes between releases, and the version in the local container is frequently not the version in production.

**The query the application actually emits**, captured from SQLAlchemy rather than retyped by hand. A hand-written approximation loses the parameter binding, and whether a value is a literal or a parameter changes what the planner can prove — which is exactly the trap that makes partial indexes silently unusable.

**The plan, not the timing.** `EXPLAIN (ANALYZE, BUFFERS)` with attention to estimated-versus-actual rows on each node. A query that runs in 20 milliseconds via a sequential scan over a warm cache is a query that will run in two seconds next year; the timing looks fine and the plan says it is not.

Then it has to stay verified. A one-off measurement rots the moment someone adds a filter or the data distribution shifts, so the check belongs in the pipeline: an integration test against a seeded database asserting the plan uses the expected index and contains no sequential scan on that table. That test fails on the merge request that breaks it rather than in production three months later.

And if the plan does turn out wrong, the design already names the correct response — a composite covering index per high-traffic category, not a bigger instance. Scaling hardware to hide a bad plan buys a few months and makes the eventual diagnosis harder.

</details>

---

## Caching and the Catalog Read Path

---

### Q1. What is cache-aside, and why is this design cache-aside rather than write-through?

**Brief answer**
Cache-aside means the application reads the cache, and on a miss reads the source and populates the cache itself; the write path never touches the cache. It was chosen so Redis stays fully expendable — write-through would put cache population inside the vendor's publish transaction, coupling a write path to a component the design treats as optional.

<details>
<summary><strong>Detailed answer</strong></summary>

The three common strategies differ in who writes the cache. In write-through, the write path updates the cache and the database together, so reads always hit a warm cache but a cache failure becomes a write failure. In write-behind, the cache is written first and the database asynchronously after, which is fast and can lose data. In cache-aside, the write path only invalidates, and readers populate.

Cache-aside wins here for one reason that outranks the others: it keeps Redis strictly optional. If `redis-cache` disappears entirely, every read falls through to PostgreSQL and MongoDB and the system keeps working — latency rises from roughly 35 milliseconds to roughly 107, and database load multiplies about sixfold, which capacity is deliberately sized to absorb. That is a degradation, not an outage. Write-through would have made the cache a dependency of publishing a listing, which is precisely backwards: the least reliable component in the system would have become load-bearing on one of the most important writes.

The second reason is that write-through does not fit the data. A cached listing detail is a *composed* object — the relational spine, the metadata document, and signed media URLs. The publish transaction does not have all of that assembled, so writing through would mean doing the composition work on the write path for a listing nobody may view. Most listings are viewed far less often than a naive cache design assumes; populating on read means only the hot ones ever cost anything.

The classic cache-aside weakness is the invalidation race: a reader loads from the database, a writer updates and invalidates, and then the reader writes its now-stale value into the cache, where it sits until it expires. This design sidesteps that entirely with revision-suffixed keys rather than by trying to order the operations — which is the part I would emphasise, because the ordering solutions are all subtly wrong under concurrency.

</details>

---

### Q1. The listing detail cache key is `cat:listing:{product_id}:v{rev}`. What does the revision suffix buy?

**Brief answer**
It makes a stale value unreachable rather than merely scheduled for deletion. When the revision pointer moves, the old key is no longer computed by anyone, so correctness stops depending on the purge message arriving at all.

<details>
<summary><strong>Detailed answer</strong></summary>

Normal invalidation is a race and a delivery problem at once. The purge travels as an event through Service Bus to `indexer-worker`, which deletes the key. If that message is delayed, lost, or dead-lettered, the stale value survives for its full fifteen-minute time-to-live, and there is nothing in the system that knows it is wrong.

Including the revision in the key changes the question from "did the delete succeed" to "what key does the reader compute". A reader builds the key from `product.current_revision_id`, which it has just read from the authoritative store. After a publish, that pointer is the new revision, so the reader computes `...:v8` and misses. `...:v7` still exists in Redis, and it is simply unreachable — no code path constructs it. It expires on its own and nobody was served from it.

This is content-addressing applied to a cache key, the same idea as the build-[SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity")-keyed static bundle and the revision-keyed media paths at the Content Delivery Network ([CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Distributes cached content across edge locations to reduce latency")) layer, where the design notes that no invalidation is needed at all because a new revision is a new Uniform Resource Locator. The pattern is worth naming as a general principle: prefer making stale data unaddressable over making it deleted, because the first is a property of your key derivation and the second is a distributed systems problem.

The cost is orphaned keys. Every revision leaves its predecessor's entry occupying memory until its time-to-live expires, so a heavily-revised listing holds several copies. At a fifteen-minute TTL and this revision rate that is negligible, and Redis is configured with an eviction policy so memory pressure evicts the coldest keys — which are exactly the orphans. If revision churn increased tenfold I would revisit it, most likely by shortening the TTL rather than by abandoning the pattern.

The purge is still sent, because it reclaims memory promptly and keeps facet counts fresh. It is just no longer the thing correctness rests on, and that distinction — between an optimisation and a guarantee — is the one I would want any cache design to be able to state explicitly.

</details>

---

### Q1. What is a cache stampede, and why does naive time-to-live caching make it worse at exactly the wrong moment?

**Brief answer**
A stampede is many concurrent requests all missing the same key at the same instant and all recomputing it against the database. Naive TTL caching causes it by construction: the more popular a key, the more requests are in flight when it expires, so the busiest keys produce the largest simultaneous load.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanism is unintuitive because caching is supposed to reduce load. Consider a widely-viewed point-of-sale listing being fetched fifty times a second. Its key has a fifteen-minute TTL. For fifteen minutes the database sees nothing. Then the key expires, and every request arriving in the window between expiry and repopulation misses — because nobody has written the new value yet. All of them query PostgreSQL and MongoDB, all of them do the same composition work, and all of them write the same value back.

The perverse property is that the size of the spike scales with popularity and with recomputation cost. A key that takes 100 milliseconds to rebuild and is requested fifty times a second produces roughly five concurrent duplicate rebuilds. A slower rebuild produces more, which slows the database, which makes the rebuild slower still. That feedback loop is how a cache expiry turns into a self-sustaining incident — the database never catches up because each expiry cycle arrives before the last is drained.

It is also invisible in aggregate metrics. Average database load looks fine; the hit ratio looks fine. What you see is periodic latency spikes correlated with nothing obvious, because the correlation is with key expiry times, which nothing graphs.

This matters here specifically because the brief's requirement was to cache hot catalog reads to cut database load on popular listings — and popularity concentration is exactly the condition that makes naive TTL caching counterproductive. A marketplace has a strong head: a handful of well-known products in each category get a large share of the traffic. Those are the keys the cache is for, and they are the keys that stampede hardest.

The two mitigations in the design — a single-flight lock so only one request rebuilds, and probabilistic early expiry so rebuilds spread over a window instead of landing on one instant — together bound database load on a listing to roughly one recomputation per TTL regardless of concurrency.

</details>

---

### Q2. Walk me through single-flight and probabilistic early expiry. What does each cover that the other does not?

**Brief answer**
Single-flight bounds concurrency at the moment of a miss — one rebuilder, everyone else waits briefly or serves stale. Probabilistic early expiry prevents the simultaneous miss from happening at all, by having readers refresh before expiry with rising probability. The first is a safety net; the second removes most of the events the net would have to catch.

<details>
<summary><strong>Detailed answer</strong></summary>

**Single-flight.** On a miss, the pod attempts `SET cat:lock:{key} NX EX 5`. Exactly one wins and recomputes; the losers poll the key for up to 200 milliseconds and then serve the stale value if one exists. The `NX` makes the acquisition atomic, and the five-second expiry means a pod that dies holding the lock does not wedge the key — which is the failure everyone forgets, and the reason a lock without an expiry is a bug rather than a lock. The cost is up to 200 milliseconds of added latency on losing requests during a rebuild, and a small amount of code that only pays off under the exact traffic pattern the brief describes.

The subtlety is what a loser does after 200 milliseconds. Serving stale is right when a stale value exists; when the key is genuinely cold — first request after a deploy, or after an eviction — there is nothing to serve, so the loser has to fall through to the database. That is correct, and it means single-flight bounds the stampede rather than eliminating it on a cold key.

**Probabilistic early expiry.** Each cached value stores its computation cost and a delta, and on every read the client evaluates whether to recompute early, with probability rising as the remaining TTL shrinks and scaled by how expensive the value was to build. Expensive keys refresh earlier; cheap ones ride to expiry. The effect is that the popular key is almost always refreshed by one lucky reader *before* it expires, so there is never a moment when the key is absent and everyone misses together. Recomputation spreads across a window instead of landing on an instant.

Why both: probabilistic expiry is a statistical guarantee, not an absolute one, and it does nothing for a key that was evicted under memory pressure or lost in a Redis restart — both of which produce a genuine cold miss with full concurrency. Single-flight covers those. Conversely, single-flight alone still concentrates one rebuild plus a burst of 200-millisecond-delayed requests at every expiry; probabilistic refresh removes that pattern in the steady state.

The combination is what bounds database load per listing to roughly one recomputation per TTL regardless of how many concurrent readers there are, which is the property the design actually needs.

</details>

---

### Q2. Three Redis layers, three different invalidation rules — event-driven purge for listing detail, TTL only for search pages, event purge for facet counts. Why does the search layer get a different rule?

**Brief answer**
Because you cannot enumerate the keys a listing change affects. A listing belongs to an unbounded number of filter combinations, so precise invalidation is intractable; a 60-second time-to-live buys freshness for a cost you can reason about.

<details>
<summary><strong>Detailed answer</strong></summary>

The difference is the relationship between the changed entity and the cache key.

`cat:listing:{product_id}:v{rev}` maps one-to-one to a product. When that product changes, exactly one key is affected and you can name it. So event-driven purge works, and the revision suffix makes it safe even if the purge is lost.

`cat:search:{filter_hash}` maps many-to-many. A published listing may enter or leave any result set whose filters it now matches — a category, several country coverage values, a set of integrations, a price band, a deployment model, crossed with sort orders and cursor positions. Enumerating those combinations means either computing every filter set the listing satisfies, which is combinatorial, or keeping a reverse index from products to cached filter hashes, which is more state to maintain and to get wrong than the cache is worth. So the design does not try. A 60-second TTL means a newly published listing appears in search within a minute, which sits comfortably inside the 95th-percentile five-second projection freshness target being the dominant term anyway.

`cat:facets:{category_slug}` sits in between. Facet counts are per-category, so any projection write in a category invalidates exactly one key — nameable, so purged, with a five-minute TTL as the backstop.

The general rule I take from this is that invalidation strategy follows key cardinality relative to the change, not preference. Where the mapping is one-to-one, purge. Where it is many-to-many, use a short TTL and accept bounded staleness, because precise invalidation of a many-to-many relationship is where cache bugs live. And in both cases decide what the *correctness* guarantee is independently of the purge — here it is the revision suffix for detail, and simply "search is allowed to be seconds stale" for the search layer, which is a documented consequence of the availability-over-consistency choice for catalog reads.

The one thing that would change the calculus is a much longer search TTL for cost reasons. At 60 seconds nobody notices; at ten minutes a vendor would, and then the reverse index starts to look worth building.

</details>

---

### Q2. `redis-cache` disappears entirely. Walk me through what happens across the system, and what fails closed rather than degrading.

**Brief answer**
It is not an outage. Cache-aside means every read falls through to PostgreSQL and MongoDB — latency goes from roughly 35 to roughly 107 milliseconds and database load multiplies about sixfold, which capacity is sized for. Rate limiting and idempotency degrade too, and they deliberately fail closed for writes and open for reads.

<details>
<summary><strong>Detailed answer</strong></summary>

Taking the keyspaces in turn.

The catalog caches — listing detail, search pages, facet counts — simply miss. Every request takes the uncached path. The latency budget was built with both columns precisely so this is a known quantity rather than a surprise, and the sixfold database load multiplier is why the PostgreSQL replica is sized with headroom rather than to the average. The thing that would make this dangerous is the stampede: a Redis loss is a total simultaneous cold start, so every hot key is contended at once. Single-flight helps, but only within a pod; across many pods it is a distributed lock that has just lost its lock server. That is the part I would want load-tested rather than reasoned about, because it is the one place where "graceful degradation" could turn into a thundering herd against the database.

`authz:jwks` holds the identity provider's signing keys. On a miss, services refetch from the [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")) endpoint — a network call, so authorization stops costing one millisecond and starts costing tens, on every request until the key is cached again locally. This is why the local in-process fallback matters: a JWKS refetch storm against `identity-service` during a Redis outage would be a genuinely bad compounding failure.

`rl:*` and `idem:*` are the interesting ones because they are correctness-adjacent rather than performance-only. Business rate limits — twenty connection requests per retail group per day, five imports per vendor per day — exist as marketplace-integrity controls, and idempotency keys prevent duplicate threads and duplicate charges. Without Redis, neither can be evaluated. The design fails **closed for writes and open for reads**: a browse request proceeds unlimited, but a connection request or an import submission is rejected with a retryable error rather than allowed unchecked. That is the right direction — the cost of refusing a few connection requests during an outage is far below the cost of a burst of duplicate charges or an unbounded spam window.

I would add one qualification: idempotency is not solely dependent on Redis. `UNIQUE (retail_group_id, idempotency_key)` in PostgreSQL is the actual guarantee, and the Redis key is the fast path. So even failing open on that specific check would not create duplicate threads — but it would turn a clean 200 response into a constraint violation that has to be handled, and failing closed is simpler to reason about under stress.

</details>

---

### Q2. There are two Redis instances — `redis-cache` and `redis-broker`. Justify running two rather than one with separate databases.

**Brief answer**
They have opposite operational requirements. The cache is expendable, memory-bound and safe to evict from; the broker holds in-flight work, needs persistence, and must never evict. One instance forces one configuration on both, and the losing side is whichever one you did not think about.

<details>
<summary><strong>Detailed answer</strong></summary>

The configurations conflict directly.

The cache wants a maxmemory policy that evicts least-recently-used keys under pressure — that is correct behaviour, since everything in it is rebuildable from PostgreSQL and MongoDB. It wants no persistence, because writing an append-only file for data you are happy to lose is pure cost. It is sized to a working set, roughly six gigabytes here, and it is fine for it to be full.

The broker wants exactly the opposite. Evicting a queued Celery task loses work — an import chunk that never runs, a notification never sent, with no error anywhere. So its eviction policy must be `noeviction`, meaning it returns errors rather than dropping data when full, and it wants append-only persistence with `everysec` fsync so a restart does not lose the queue. It is sized to peak queue depth, and it being near full is an incident rather than a normal state.

Numbered databases inside one instance do not separate any of that. `maxmemory`, the eviction policy, persistence and the memory ceiling are all instance-wide. So a co-located deployment means either the cache cannot evict — and a cache that cannot evict returns write errors when full, which is a spectacular way to fail — or the broker can evict, and you lose queued tasks silently under exactly the cache pressure a big import creates. That second scenario is the one that would actually happen, because import load raises both cache churn and queue depth at once.

There is also a blast-radius argument. A cache flush is a routine operation; doing it against an instance also holding the queue would destroy in-flight work. Separating them means `FLUSHDB` on the cache is boring.

The cost is a second instance to provision, monitor and pay for, and the honest note is that Celery on Redis is itself a compromise — Redis has no real acknowledgement semantics, so import durability rests on a visibility timeout rather than on broker guarantees. The design flags that as needing a kill-the-worker test, and names the correct fix if imports must be durable: move the `imports` queue to Azure Service Bus, which is already in the stack, and leave Redis carrying only work that is fully rebuildable from the outbox.

</details>

---

### Q3. Production hit ratio on `cat:search` drops from 0.85 to 0.40 and stays there. Walk me through the diagnosis.

**Brief answer**
The hit ratio is a function of key cardinality versus TTL versus request rate, so something has changed one of those three. I would check for a client change that added a parameter to the filter hash, a traffic-shape change such as crawling, and memory pressure causing eviction — in that order, because the first is the most common and the cheapest to confirm.

<details>
<summary><strong>Detailed answer</strong></summary>

The latency budget assumes 0.85, so this is a real regression: the 95th percentile moves from the cached path to the uncached one and PostgreSQL load roughly triples. Worth treating as an incident even though nothing is erroring.

**Key cardinality first.** `cat:search:{filter_hash}` hashes the filter set plus the cursor. If a client change added a field to that hash — a new sort option, a locale, a tracking parameter accidentally included, a cursor that is now unique per session — the key space explodes and every request is effectively unique. This is by far the most common cause, and it is fast to confirm: sample the keyspace, count distinct keys over a window, and compare against the previous week. A tenfold increase in distinct keys with flat traffic is the answer. The related version is a hash that includes something with high entropy, such as a floating-point price ceiling from a slider rather than a banded value.

**Traffic shape second.** A crawler, a competitor scraping, or a vendor integration paging through everything produces requests that are individually unique and never repeat, so they miss by construction and drag the ratio down without any bug existing. The tell is a low hit ratio concentrated on one subject or subscription key, which the per-`org_id` rate-limit counters make visible. The design's per-vendor cap on catalog detail fetches exists precisely to make systematic scraping slow enough to notice — this is what noticing looks like.

**Memory pressure third.** If the working set has grown past the instance size, Redis evicts least-recently-used keys before their TTL, so keys that should have been hits are gone. Check `evicted_keys` and used memory against maxmemory. The cause is often not the search keyspace at all but another one growing — orphaned revision-suffixed listing keys under heavy publish churn, for instance.

**Then the boring ones:** a deploy that changed the TTL, a change in cursor depth so users page deeper into unique pages, or a Redis restart that has not yet re-warmed — the last being self-resolving, which is why I would check uptime early even though it is rarely the answer.

What makes this diagnosable at all is having the metric per keyspace rather than one global ratio. A single aggregate number tells you something is wrong and nothing about where.

</details>

---

### Q3. At ten times the traffic, is Redis still the right layer? What would you add, and what would you stop caching?

**Brief answer**
Redis stays right for shared state; what changes is that a per-pod in-process layer becomes worth adding in front of it for the small, hot, near-static values, and the CDN takes more of the read path. I would stop caching search pages before I stopped caching listing details, because their key cardinality scales badly.

<details>
<summary><strong>Detailed answer</strong></summary>

At ten times the traffic the network round trip to Redis stops being free relative to everything else. A search request currently makes several Redis calls — the search key, then a multi-get for listing summaries — each a few milliseconds. That is a small share of a 107-millisecond uncached path and a large share of a 35-millisecond cached one, so as the cached path dominates, Redis latency becomes the budget.

**What I would add.** A per-pod in-process cache in front of Redis for values that are tiny, near-static and read on every request — the category tree, the facet schemas, the JWKS. The design already does this with a 60-second TTL, and at higher load that layer earns more. The reason it is safe for these and not for listings is that they are small enough to replicate per pod and stale-tolerant for a minute; a per-pod listing cache would multiply memory by the pod count and make invalidation genuinely unsolvable, since there is no way to purge across pods without another message path.

**What the CDN should take.** More. Media and the static bundle are already there. A logged-out or category-level browse page is a candidate for edge caching if the response can be made non-personalised, which is a product question — currently every request carries an authenticated organisation context, so it cannot be. Making the first page of a category anonymous-cacheable would remove a large share of traffic before it reaches the cluster, and at ten times the load that is worth the product change.

**What I would stop caching.** Search pages, or rather cache them more narrowly. Their key includes the cursor, so deep pages are individually cold and pollute the keyspace with entries used once. Caching only the first page or two of each filter combination captures nearly all the value at a fraction of the cardinality — the distribution of page depth is steep, and the tail is where the memory goes.

The thing I would not do is reach for a bigger Redis first. The failure at that scale is more likely to be key cardinality and round-trip count than raw capacity, and both are fixed by design changes rather than by provisioning.

</details>

---

### Q3. A cache sits in front of tenant-scoped data. How do you guarantee a cached value never crosses an organisation boundary?

**Brief answer**
By only caching data that has no tenant dimension. The catalog caches hold published listings, which every authenticated account may read, so there is nothing to leak — and anything org-scoped is deliberately not cached in a shared keyspace. Where it must be, the `org_id` belongs in the key, and that has to be structurally enforced rather than remembered.

<details>
<summary><strong>Detailed answer</strong></summary>

This is the failure mode I would treat as most serious in the entire caching design, because it is silent, it is a data breach rather than a bug, and the usual way it happens is someone adding a cache to an existing endpoint without thinking about who the response varies by.

The design's defence is mostly structural: the shared cache holds only non-tenant-varying data. `cat:listing:*`, `cat:search:*` and `cat:facets:*` all describe published listings, which are visible to every authenticated account regardless of organisation — that is what a marketplace catalog is. Shortlists, connection threads and vendor drafts are org-scoped, and none of them are in the shared cache at all. So the guarantee comes from the absence of a cache rather than from correct key construction, which is a much stronger position: there is no key to get wrong.

Where a tenant-scoped cache is genuinely needed, the rules I would insist on. The `org_id` goes in the key prefix, not somewhere in the middle, so a keyspace scan makes ownership obvious. It comes from the validated token claim, never from a request parameter — a cache key built from user input is a cache-poisoning primitive. And the derivation lives in one shared helper rather than being assembled at each call site, because the failure is one endpoint out of forty forgetting, and code review does not reliably catch a missing prefix.

The test that actually catches this is a negative integration test in the same family as the tenant-isolation tests: request a resource as organisation A, request the same resource as organisation B, assert B gets B's data or nothing — and run it with the cache warm, because a cold-cache test passes trivially and is worse than no test, since it creates confidence. The design already asserts cross-tenant reads return empty for every org-owned repository method; the cache-warm variant is the version that catches this specific bug.

The related trap is caching an *authorization decision* rather than data. Caching "this subject may read this product" keyed on the product alone is the same bug wearing a different hat. Authorization here is a local claim check costing about a millisecond, so there is no reason to cache it — and I would treat a proposal to cache a permission result as needing a much higher burden of proof than caching content.

</details>

---

## Asynchronous Work, Message Brokers and Bulk Attribute Updates

---

### Q1. This system runs both Celery and Azure Service Bus. Why two messaging systems, and what is the rule that decides which one carries a given piece of work?

**Brief answer**
Celery moves work between Python processes we own; Service Bus moves events across a boundary — to Azure Functions, to another service, to a consumer that does not exist yet. It is a rule rather than a preference, and applying it consistently is what stops the two from becoming redundant.

<details>
<summary><strong>Detailed answer</strong></summary>

The two are not interchangeable, and the confusion comes from both being "queues" in casual conversation. They solve different problems.

Celery is a distributed task queue for Python. The unit is a function call with arguments, the consumer is code from the same repository, and the value is that scheduling, retries, routing and result handling are already built. `imports`, `indexing` and `notifications` are Celery queues because in every case the producer and the consumer are our own Python code and the work is a function.

Service Bus is a broker for events crossing a boundary. `sb-catalog-events` and `sb-connection-events` carry domain facts — a listing was published, a connection was requested — to consumers that include `indexer-worker`, `notification-worker`, `billing-service`, and whatever is added next year. The publisher does not know the consumer set, which is the point. `sb-notification-dispatch` carries work to an Azure Function, which is not a Python process we own at all.

What each is bad at is the argument against collapsing them. Celery reaching an Azure Function means implementing the Function's trigger contract by hand and losing native scaling. Service Bus scheduling in-process Python work means rebuilding Celery's routing, retry and chunking on top of a message broker, and losing the ability to call a task like a function. Either direction puts a system in a role it is bad at.

The notification path shows the rule applied cleanly and is worth stating because it looks like duplication and is not. `notification-worker` decides *whether and what* to notify — a policy decision needing database context about subscriptions, preferences and thread state. `fn-notify-dispatch` performs *delivery* to the email provider. One owner per step, no overlap, and the boundary between them is exactly where the work leaves our Python.

The operational cost is honest and real: two broker technologies to monitor, two sets of failure modes, two dead-letter concepts. I would accept that cost only because the rule is crisp enough that nobody has to think about which to use.

</details>

---

### Q1. `sb-catalog-events` is a topic and `sb-notification-dispatch` is a queue. What is the difference, and why is each right where it is?

**Brief answer**
A queue delivers each message to exactly one consumer; a topic copies each message into every subscription. Catalog events have several independent consumers who each need their own copy, so a topic. Notification dispatch has one job to be done once, so a queue.

<details>
<summary><strong>Detailed answer</strong></summary>

The distinction is about how many parties need to react. `catalog.listing.published` matters to `indexer-worker`, which projects the facets, and to `notification-worker`, which alerts saved-search subscribers. Those are independent reactions — neither consumes the other's copy, and a failure in one must not deprive the other. A topic with a subscription per consumer gives exactly that: each subscription is its own queue with its own delivery state, its own retry count and its own dead-letter queue. `indexer-worker` falling behind does not delay notifications.

Within a subscription, delivery is competing-consumer: several `indexer-worker` pods share one subscription, and each message goes to exactly one of them. That is what lets the projection scale horizontally while every event is still projected once.

`sb-notification-dispatch` is a queue because delivery is a single job with a single owner. Sending the same email twice is a defect, not a fan-out.

The property I care about most in choosing a topic is that the publisher stays ignorant of the consumers. When vendor analytics arrives and needs to count publishes, it declares a new subscription and binds — and `vendor-service`, which owns the most sensitive write path in the catalog, is not redeployed to satisfy a reporting feature. If the publisher had enqueued directly to a named consumer queue, every new consumer would mean editing and shipping the publisher.

The trade-off is that fan-out makes delivery guarantees per-subscription rather than global. A subscription created with a wrong filter receives nothing and reports no error — silence is indistinguishable from health. So subscription topology is configuration that has to be asserted, which is why it is Terraform-managed and why I would want an integration test that publishes an event and asserts every expected subscription received it, rather than eyeballing it in the portal.

</details>

---

### Q1. What is a dead-letter queue, and what should actually happen when a message lands in one?

**Brief answer**
It is where the broker puts a message it could not deliver successfully after the configured attempts, so a poison message does not block the queue forever. What should happen is an alert and a human decision — a dead-letter queue that nobody looks at is a data-loss mechanism with extra steps.

<details>
<summary><strong>Detailed answer</strong></summary>

The problem it solves is head-of-line blocking with unbounded retry. A message whose handler always throws — malformed payload, a referenced row that was deleted, a bug triggered by one specific shape — will be retried forever if you let it, consuming capacity and, on an ordered queue, blocking everything behind it. Dead-lettering moves it aside after a bounded number of attempts so the rest of the queue drains.

The part that gets neglected is what happens next. In this design, Service Bus dead-letters after ten attempts and any dead-letter count above zero on any subscription raises a ticket-level alert. That threshold is deliberate: not a page, because a single dead-lettered notification is not a night-time emergency, but not silence either, because the alternative is discovering a month later that saved-search alerts stopped for one category. The value zero is the right threshold precisely because dead-lettering should be rare — if it is noisy, the retry policy or the handler is wrong, and lowering the alert sensitivity is treating the symptom.

Handling a dead-lettered message properly means answering three questions: is the payload wrong, is the handler wrong, or was the failure transient and already fixed. Transient failures should not be reaching the dead-letter queue at all — that is what retries with backoff are for — so a message that arrives there is usually a real defect. The remedy is to fix the handler, then replay the message, which requires that replaying is a supported operation rather than something improvised during an incident.

Two things that must be true for replay to be safe. Consumers have to be idempotent, which they are here — the projection upserts and ignores older revisions, and consumers deduplicate on `event_id` — so replaying a message that partially succeeded is harmless. And the message has to still be meaningful; replaying a six-week-old `catalog.listing.published` for a listing since archived should be a no-op by virtue of the revision check rather than by luck.

The failure I would guard against hardest is a dead-letter queue with retention shorter than the time it takes anyone to notice. That converts "quarantined for investigation" into "deleted quietly".

</details>

---

### Q1. What is consumer prefetch, and why is it the first thing you look at when a message consumer runs out of memory?

**Brief answer**
Prefetch is how many unacknowledged messages the broker will push to one consumer at a time. It is the first suspect because a high prefetch multiplied by a large message and a slow handler means the consumer is holding thousands of message bodies in memory before it has processed the first one.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanism is a throughput optimisation that becomes a memory hazard. Fetching one message at a time means a network round trip per message, so brokers let a consumer take a batch — a prefetch count in Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")) terms, `worker_prefetch_multiplier` in Celery, the prefetch count on a Service Bus receiver. The consumer holds those messages, unacknowledged, until it processes each one.

The arithmetic is what bites. A prefetch of 500 with 100-kilobyte messages is 50 megabytes resident per consumer thread before any work happens. Multiply by concurrency within the process and by the number of pods and it is easy to reach a figure that exceeds the container limit. And the failure is not gradual: the process is killed by the out-of-memory killer, so every one of those unacknowledged messages is redelivered to another consumer, which now also has a full prefetch buffer and also dies. That is the cascade — a memory problem turning into a redelivery storm turning into a cluster-wide crash loop, with the queue depth rising the whole time because nothing is being acknowledged.

The defaults are the trap. Celery's default prefetch multiplier is four times the concurrency, which is fine for small tasks and catastrophic for large payloads. Long-running tasks make it worse, because prefetched messages sit unacknowledged for the duration and may hit visibility timeouts and be redelivered while still being worked on.

The fixes, in order: lower the prefetch to something matched to handler duration — for long tasks it should approach one; keep message bodies small by passing a reference rather than a payload, which is why import rows land in blob storage and MongoDB staging while the message carries a job identifier and a row range; and set a container memory limit that kills a runaway process fast rather than letting it degrade the node.

This matters here because bulk catalog import is exactly the shape that triggers it — many messages, meaningful per-message work, and a queue that can grow to thousands of chunks during a large vendor upload.

</details>

---

### Q2. A system pushing millions of product attribute updates through a broker has taken production down with memory overloads. Diagnose the likely mechanism, and say what you would put in place.

**Brief answer**
Almost always the queue growing faster than it drains, with memory consumed on both sides — the broker holding an unbounded backlog and the consumers holding large prefetch buffers. The fixes are backpressure at the producer, prefetch matched to handler cost, small message bodies, and coalescing updates so the volume never exists.

<details>
<summary><strong>Detailed answer</strong></summary>

The pattern is consistent enough to describe generically. Something generates attribute updates far faster than downstream can apply them — a bulk import, a supplier feed, a migration. Each update becomes a message. The producer has no idea how deep the queue is, because publishing is asynchronous and fast, so it keeps going. Queue depth grows into the millions. [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") holds message metadata in memory even for persistent messages, so a deep queue is itself memory pressure on the broker; when it crosses its high-watermark it raises a memory alarm and **blocks publishers** — which means the producing application's threads stall on publish, connection pools fill, health checks fail, and the outage surfaces as an unresponsive Application Programming Interface rather than as a broker problem. Meanwhile consumers holding big prefetch buffers get out-of-memory killed, everything they held is redelivered, and the backlog grows further.

Four controls, roughly in order of how much they help:

**Do not generate the messages.** Coalescing is the highest-leverage fix and the one people reach for last. If an entity is updated fifty times in a minute and only the final state matters, project once — debounce per entity over a short window. In this design the projection is idempotent and ignores older revisions, so collapsing is free correctness-wise, and it cuts work proportionally to churn rather than to volume. Similarly, an import emits one `catalog.import.completed` event and the projection re-processes affected products in batches of 200, instead of one event per row — which is the difference between 20,000 messages and about 100.

**Backpressure at the producer.** The producer must observe queue depth and slow down. Here that is a per-vendor concurrency cap of four in-flight import chunks, held as a Redis semaphore, plus rate limits of five import jobs per vendor per day. A producer that cannot be slowed is a producer that will eventually take the broker down.

**Bound consumer memory.** Prefetch matched to handler duration, small message bodies with payloads by reference — rows in staging and blob storage, a job identifier and row range in the message — and container memory limits so a runaway pod dies fast and visibly.

**Isolate.** Separate queues and separate worker deployments, so bulk attribute work cannot starve the interactive publish path or notifications. `imports` scales on its own queue depth without touching the web tier.

And it must be observable before it is critical: queue depth as an alerting signal with a threshold well under the danger point — `imports` under 500 here — plus broker memory, because the alarm that blocks publishers is the one that turns a backlog into an outage.

</details>

---

### Q2. A vendor uploads a 20,000-row catalog import. Walk me through the path and every mechanism that stops it degrading browse for everyone else.

**Brief answer**
The file goes to blob storage, the job is chunked into 500-row Celery tasks on a dedicated `imports` queue consumed by a dedicated worker deployment, capped at four concurrent chunks per vendor, staged and validated before any product row moves, and projected in batches rather than per row.

<details>
<summary><strong>Detailed answer</strong></summary>

The path in order. The vendor posts a multipart file, which `vendor-service` writes to `blob-media` under `imports/{vendor_id}/{job_id}` and records as a `catalog_import_job` row with status `queued`. The request returns immediately with a job identifier — a 20,000-row import is not a request, and holding an HTTP connection for it is the first mistake to avoid. `catalog-import-worker` picks it up, parses, and chunks into 500-row Celery tasks.

The isolation mechanisms:

**A separate queue and a separate worker deployment.** `imports` is not `indexing` or `notifications`, and the pods are separate, so import load cannot starve projection or notification work, and none of it runs in the web tier. The horizontal pod autoscaler scales importers on `imports` queue depth, so a large import adds import capacity without adding browse capacity nobody needs.

**A per-vendor concurrency cap.** At most four chunks in flight per `vendor_id`, held as a Redis semaphore. This is the control that stops one vendor's bulk upload occupying the whole worker pool while everyone else's imports wait — a fairness property, not a capacity one, and it matters because the pool is shared.

**Staging before promotion.** Rows land in the `import_staging` collection with their raw payload, mapped result and per-row errors, and are validated against the category's facet schema before any `product` row changes. A malformed file fails wholly at validation with a per-row error digest the vendor can see, rather than half-applying and leaving the catalog in a state nobody intended. Staging carries a 30-day time-to-live index, so cleanup needs no job.

**Batched projection.** The completed import emits one `catalog.import.completed` event and `indexer-worker` re-projects affected products in batches of 200. Without this a single import produces 20,000 separate projections, 20,000 GIN index updates and 20,000 cache invalidations — which would flush the catalog cache for that vendor's whole portfolio and put the read path on the uncached path for everyone.

**Payload by reference.** Messages carry a job identifier and a row range, not row data, so queue depth does not translate into broker memory.

The vendor-visible outcome is a job they can poll — row totals, successes, failures and an error digest — which is also what stops support tickets, since the failure is legible without engineering involvement.

</details>

---

### Q2. Celery on Redis does not have real acknowledgement semantics. What is the risk to import durability, and how would you actually test it rather than assume?

**Brief answer**
A worker killed mid-task relies on a visibility timeout expiring for the task to be redelivered, and a broker failover can drop unacknowledged tasks entirely — so a chunk can vanish with no error. The test is to kill a worker mid-chunk and a broker mid-queue and assert the rows are eventually applied.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanics matter. With a real AMQP broker, a consumer holds an unacknowledged message and the broker knows it is outstanding; if the connection drops, the broker requeues it immediately and deterministically. Redis has no such concept. Celery emulates it: with `acks_late=True` the task is acknowledged after completion rather than on receipt, and an in-flight task is tracked in a separate structure with a visibility timeout, so if the timeout expires without acknowledgement the task is restored to the queue. That is an emulation built on top of a data store, and its guarantees are weaker in two specific places.

First, timing. Redelivery waits for the visibility timeout, which must be longer than the longest legitimate task or healthy long-running work gets duplicated. So a killed worker's chunk is delayed by that timeout, not requeued instantly.

Second, durability. Redis persistence with append-only file and `everysec` fsync means up to a second of writes can be lost on an unclean shutdown, and a failover to a replica can lose more. Anything in that window — including the in-flight tracking structure — is gone, and nothing reports it. The chunk simply never runs. The import job sits at `running` forever, or reports fewer rows than the file contained.

Testing it properly means three experiments, each with a known expected outcome rather than "see what happens":

**Kill the worker mid-chunk** with `SIGKILL` — not `SIGTERM`, which triggers graceful drain and proves nothing. Assert that after the visibility timeout the chunk is reprocessed and every row lands. This also verifies the chunk handler is idempotent, since partial work may already be applied.

**Kill the broker** with a queue holding known in-flight and queued tasks, restart it, and assert the full row count is eventually applied. This is the one likeliest to fail.

**Fail over the broker** if the deployment is replicated, with the same assertion.

Each needs an explicit "could not run" outcome distinguished from a pass — if the harness never actually killed the process, or the rows were already applied before the kill, the test reports success while proving nothing. That distinction is the whole value of the exercise.

If any of these fails and imports must be durable, the design already names the fix: move the `imports` queue to Azure Service Bus, which is in the stack and does have real delivery semantics, and keep Redis for `notifications` and `indexing`, whose work is fully rebuildable from the outbox and reconciliation job.

</details>

---

### Q2. Notification policy lives in `notification-worker` and delivery lives in `fn-notify-dispatch`. Why split those, and what breaks if the boundary blurs?

**Brief answer**
Deciding whether and what to notify needs database context — subscriptions, thread state, preferences — and is a Python policy decision. Delivering to an email provider is a stateless side effect with different scaling and retry characteristics. Blurring them puts business rules in a Function with no database access, or blocks a worker on an external provider's latency.

<details>
<summary><strong>Detailed answer</strong></summary>

The split follows the rule that each step has exactly one owner. `notification-worker` consumes `catalog.listing.published` or `connection.requested`, and answers the questions that require knowing things: does anyone have a saved search matching this listing, is this connection's vendor contact still active, has this recipient already been notified about this thread in the last hour, what is their preference. Those are joins against `postgres-core`. Then it emits a concrete dispatch instruction — this address, this template, this data — onto `sb-notification-dispatch`. `fn-notify-dispatch` takes that and calls the email provider.

What each side gains. The worker never waits on an external provider, so a slow email vendor cannot back up the queue that also carries policy decisions for other events. The Function scales on queue depth independently and is the only component holding provider credentials, which narrows that secret's blast radius to one workload. And the Function is stateless, so retries against a flaky provider are trivially safe.

What breaks if it blurs. Putting policy into the Function means it needs database connectivity from outside the cluster, credentials, and a copy of domain logic that will drift from the worker's — a second owner of the same rules, which is the defect this architecture spends effort avoiding. Putting delivery into the worker means a synchronous call to an external provider inside a Celery task, so provider latency becomes queue latency and provider downtime becomes a growing backlog on a queue that also carries other work.

The failure mode to watch is duplicate sends. Delivery is at-least-once, so a receipt lost between the queue and the Function can produce a second email. That is accepted rather than solved, because a duplicate notification is a much better failure than a missing one — a vendor seeing a connection request twice will still respond; a vendor never seeing it loses the deal the platform exists to create. Where duplication would be genuinely harmful, the deduplication belongs in the dispatch instruction as an idempotency key the provider honours, not in a "have I sent this" table that can itself be lost.

</details>

---

### Q3. The broker hits its memory alarm and blocks publishers. Trace the cascade through this architecture and say what should have caught it earlier.

**Brief answer**
Publishing stalls, so the outbox relay stops draining and `outbox_unpublished_age_seconds` climbs, while any component publishing synchronously blocks its request threads. The design's protection is that domain writes never publish directly — they insert an outbox row and commit — so listing publishes and connection requests keep succeeding. Queue depth and broker memory alerts should have fired long before the alarm.

<details>
<summary><strong>Detailed answer</strong></summary>

Take the cascade in order.

Publisher-side blocking is the dangerous part, and its severity depends entirely on who publishes. If a request handler published directly to the broker, blocking would stall request threads, fill the connection pool, fail readiness probes, and take the service out of rotation — an API outage caused by a broker memory condition, which is the shape most of these incidents take.

This design largely avoids that, and it is worth being precise about why. `vendor-service` and `connection-service` never publish in the request path. They insert a row into `outbox_event` in the same transaction as the state change and commit. The only component talking to the broker is the outbox relay. So when publishing blocks, listing publishes and connection requests continue to succeed; what stops is the relay draining the outbox. `outbox_event.published_at` stays null, the partial index on unpublished rows grows, and `outbox_unpublished_age_seconds` rises past its 30-second objective and pages at 300 seconds. Nothing is lost — the events are durable in PostgreSQL — and when the broker recovers the relay resumes from where it stopped.

Downstream, projection and notification stop. New listings do not become searchable, so `indexer_lag_seconds` breaches its 60-second alert. Connection notifications stall, which is commercially the most painful part. Consumers are idempotent, so the eventual flush is safe.

What should have caught it earlier. The alarm is a late symptom; the cause is a backlog that grew for a while first. Queue depth is already an alerting signal and an autoscaler input — `imports` under 500, others under 100 — and it would have breached long before broker memory did. Broker memory itself should be a monitored metric with a threshold well under the alarm watermark, because between "getting deep" and "publishers blocked" there is a large window where adding consumers fixes it and no user notices.

The structural lesson I would take is the one the outbox already encodes: keep the broker off the synchronous path entirely. A broker problem should degrade freshness, not availability. If any component in the system publishes directly from a request handler, that is the thing to fix before tuning any threshold — and I would grep for it rather than assume.

</details>

---

### Q3. Suppose this workload were not 200 imports a day but millions of attribute updates an hour, continuously. What changes architecturally?

**Brief answer**
Per-event processing stops being viable, so the design shifts from event-per-change to stream-with-compaction: coalesce updates per entity, process in batches, and reconsider the projection store, because GIN index maintenance on the search table becomes the limiting factor rather than the broker.

<details>
<summary><strong>Detailed answer</strong></summary>

At 200 imports a day the current shape is comfortable and the mechanisms are about isolation. At millions of updates an hour the constraint moves and several decisions invert.

**Coalescing becomes mandatory rather than an optimisation.** If an attribute changes forty times an hour and only the latest state is queryable, projecting forty times is wasted work. A keyed stream where later records supersede earlier ones for the same entity — log compaction, in [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") terms — matches the workload far better than a queue of independent events. That is also the point at which Kafka or Event Hubs becomes the right choice over Service Bus: the current volume is around 0.2 messages per second, where a cluster would be absurd, but sustained high-volume keyed updates with replay is precisely what a log is for. The design's stated reasoning for Service Bus is volume, so the reasoning itself names this trigger.

**The projection becomes the bottleneck, not the broker.** GIN indexes are expensive to maintain, and this volume of upserts into `product_listing_facets` with `tsvector` and multiple GIN indexes will dominate. The responses are micro-batching much larger than 200, tuning the GIN pending-list behaviour so index merges are amortised, and possibly splitting the projection so high-churn attributes live in a table without the text index. At the extreme, this is the point where a purpose-built search store stops being over-engineering — which is the second reversal trigger already written down.

**Backpressure becomes a first-class contract rather than a semaphore.** A per-vendor concurrency cap is right for occasional bulk imports; a continuous stream needs the producer to observe consumer lag and slow down or shed, with a defined policy for what is dropped.

**Read-your-writes gets harder.** The vendor workspace currently sidesteps projection lag by reading authoritative sources directly. Under continuous churn that still works, but the retailer-visible lag widens, and the five-second freshness objective would need renegotiating rather than quietly missing.

What would not change is the outbox, the idempotent projection and the reconciliation job. Those are volume-independent correctness mechanisms, and they are the parts I would keep unchanged while replacing everything around them.

</details>

---

### Q3. The target environment uses MQTT alongside a broker, and nothing in this system does. What is MQTT actually for, and what of your experience transfers?

**Brief answer**
Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")) is a lightweight publish-subscribe protocol built for constrained clients over unreliable networks — devices, not services — with per-connection sessions and three quality-of-service levels. I have not run it in production. What transfers is everything about delivery semantics, idempotency and backpressure; what does not is its connection and authentication model, which is genuinely different.

<details>
<summary><strong>Detailed answer</strong></summary>

Being straightforward first: this platform uses Celery over Redis and Azure Service Bus, and no MQTT anywhere. I would not claim operational experience with it.

What it is for. MQTT targets clients that are constrained and intermittently connected — sensors, terminals, mobile devices. The protocol is deliberately tiny, it holds a long-lived connection with a session that can survive reconnection, and it offers three delivery levels: quality of service 0 is fire-and-forget, 1 is at-least-once with acknowledgement, 2 is exactly-once via a four-step handshake that is expensive and rarely worth it. Topics are hierarchical strings with wildcards, and there is no queue abstraction — a subscriber that is offline without a persistent session simply misses messages. In a retail context the obvious use is store-level equipment: point-of-sale terminals and devices publishing telemetry over connections that drop.

What transfers directly. Quality of service 1 is at-least-once, which is the same guarantee Service Bus gives and the same one the outbox produces, so every consumer discipline I have applied here applies there: idempotent handlers, natural keys and unique constraints in the system of record rather than deduplication state in the application, and treating redelivery as normal rather than exceptional. Backpressure reasoning transfers, as does the prefetch-and-memory analysis — an MQTT broker under a flood of publishing devices fails in a recognisably similar way. So does the discipline of alerting on lag and depth rather than on errors.

What does not transfer and where I would be careful. Authentication is per connection rather than per publish, so a device that authenticated once keeps publishing on that session — which means authorization on topic patterns matters much more than it does in a request-response system, and a compromised device is a longer-lived problem than a leaked token with a fifteen-minute lifetime. Retained messages and last-will messages have no analogue in my experience and change how state is modelled. And the operational shape is different: tens of thousands of long-lived connections is a scaling problem about file descriptors and session state, not about throughput.

So my honest position is that I would come in fluent in the semantics and inexperienced in the operations, and I would want to learn the second by reading the existing topic design and the incident history rather than by assuming it resembles a service broker.

</details>

---

### Q3. Azure Service Bus is unavailable for two hours. Walk me through the impact, what you do during it, and what recovery looks like.

**Brief answer**
Nothing is lost and nothing user-facing fails, because domain writes commit to the outbox rather than publishing. Freshness degrades: new listings do not become searchable and notifications do not go out. During it I would verify the outbox is accumulating rather than erroring, and recovery is the relay draining, which needs watching for a thundering herd.

<details>
<summary><strong>Detailed answer</strong></summary>

**Impact.** Catalog browse is entirely unaffected — it reads the projection and the cache and never touches the broker. Vendors can publish listings and retailers can open connections, because those transactions write `product`/`connection_request` and an `outbox_event` row and commit; the relay's inability to publish does not roll them back. What stops is everything downstream: projection, so new and edited listings do not appear in search; notifications, so vendors are not told about connection requests; billing accrual, since `billing-service` consumes `connection.requested`; and `shortlist_item.status` moving to `contacted`.

The commercially painful one is notifications. A connection request that reaches the vendor two hours late is a real cost in a marketplace whose value proposition is speed to conversation, and I would want that stated in the incident communication rather than buried.

**What I would do during it.** First, confirm the failure is the broker and not the relay, because they look identical from the outbox metric. Second, confirm rows are accumulating with `published_at` null rather than the relay erroring in a way that loses them — the whole safety property rests on that, so I would verify it rather than trust it. Third, check that nothing has an unbounded retry loop hammering the broker and burning capacity. Fourth, watch the partial index on unpublished rows: it is sized for a near-empty set, and two hours of accumulation is fine, but a much longer outage would make the relay's own query degrade, which is the second-order failure worth knowing about in advance.

I would not attempt a manual workaround. Bypassing the relay to project directly would create a second writer to `product_listing_facets` under exactly the conditions where mistakes happen.

**Recovery.** The relay resumes and drains from `occurred_at` order. The risk is the flush: two hours of accumulated events arrive at consumers at once, so `indexer-worker` sees a burst, GIN index maintenance spikes on the search table, and cache invalidations flush a large share of the catalog cache — meaning read latency moves to the uncached path just as database load peaks. Consumers scale on queue depth, which helps, but I would rather rate-limit the relay's drain than let it deliver everything as fast as possible. A controlled ten-minute recovery is better than a two-minute one that browns out browse.

Then the reconciliation job is the backstop: anything whose `projected_at` still trails `updated_at` gets re-projected regardless of whether its event survived.

</details>

---

## FastAPI Service Design and API Contracts

---

### Q1. In FastAPI, what actually differs between declaring an endpoint `async def` and declaring it `def`?

**Brief answer**
An `async def` endpoint runs on the event loop in the main thread; a `def` endpoint is run in a thread from a bounded worker pool so it cannot block the loop. Choosing wrongly is the single most common FastAPI performance bug — a blocking call inside `async def` stalls every concurrent request in that process.

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI is built on the Asynchronous Server Gateway Interface ([ASGI](https://asgi.readthedocs.io/en/latest/ "Standard interface between asynchronous Python web servers and applications")), and Uvicorn runs one event loop per worker process. An `async def` handler is a coroutine scheduled on that loop. While it awaits something — a database round trip, a Redis call — the loop runs other requests. That is where the concurrency comes from: one thread interleaving thousands of waits.

A plain `def` handler cannot be awaited, so FastAPI runs it in an anyio thread pool. That is deliberate and correct for synchronous work, because it keeps blocking code off the loop. The cost is that the pool is bounded — forty threads by default — so concurrency for those endpoints is capped by pool size, and exceeding it queues requests invisibly. Latency rises with nothing in the application looking wrong.

The failure that hurts is the third combination: blocking code inside `async def`. A synchronous database driver, `requests` instead of an async client, a `time.sleep`, a large `json.loads`, a password hash. There is no `await`, so the loop cannot switch, and the entire process stops serving every other in-flight request for the duration. At 100 milliseconds of blocking and moderate concurrency, the 99th percentile detonates while the average looks acceptable. Nothing errors; throughput just collapses.

The rule I apply is that the handler's colour must match its dependencies. If the database driver is synchronous, the endpoint should be `def` and FastAPI's thread pool handles it — that is a perfectly good design, not a fallback. If the drivers are async throughout, the endpoint should be `async def`. What is never acceptable is mixing: an `async def` handler that calls anything blocking. Where a blocking call is unavoidable inside an async handler, it goes through `run_in_threadpool` explicitly, so the cost is visible in the code.

This design's workload is dominated by waiting on PostgreSQL, MongoDB and Redis, which is exactly the case async request handling suits — the process spends nearly all its time on network waits, and interleaving them is close to free.

</details>

---

### Q1. What does Pydantic actually do on each request, and what does it cost?

**Brief answer**
It parses and validates the request body against a declared model, coerces types, rejects unknown fields, and on the way out serialises the response model. The cost is real central-processing-unit work proportional to payload size — around a dozen milliseconds for a page of thirty product summaries in this system's latency budget.

<details>
<summary><strong>Detailed answer</strong></summary>

Three jobs, and it is worth separating them because they have different costs and different value.

**Validation and coercion on input.** The declared model is the contract: types checked, constraints applied, and unknown fields rejected rather than absorbed. That last property is a security control as much as a correctness one — it is why the design can say every request body is a Pydantic model and therefore mass-assignment style attacks have no surface. Vendor `attributes` get a second pass against the category's facet schema, because that is the only genuinely untyped input the system accepts.

**Serialisation on output.** The response model determines what leaves the service, which means a field added to an internal object does not silently start appearing in an API response. In a multi-tenant marketplace that is a meaningful control: the response model is what stops a newly-added internal column from leaking into a vendor-facing payload.

**Schema generation.** The models generate the OpenAPI document, which the admin console and vendor integrations build against. That makes the contract a build artefact rather than documentation, so it cannot drift from the code.

The cost shows up in the latency budget as roughly 12 to 14 milliseconds for a search page — comparable to the Redis round trips and, on a cached page, one of the larger single terms. It scales with the number of objects and fields, so the mitigations are about payload shape: return summaries rather than full details in list responses, keep page sizes bounded at 50, and avoid nesting that forces the whole object graph to be revalidated.

The trap I would flag is re-validating data the system already trusts. Constructing a Pydantic model from a database row that was validated on the way in pays the cost twice for no benefit. Where a hot path does that in a loop it is worth measuring, because it is invisible in code review and obvious in a profile. Pydantic v2's Rust core made this dramatically cheaper than it used to be, which changes the arithmetic but not the principle.

</details>

---

### Q1. What is Uvicorn, and how do processes, threads and the event loop relate in a deployed FastAPI service?

**Brief answer**
Uvicorn is the ASGI server that runs the application: one event loop per worker process, plus a bounded thread pool for synchronous handlers. In [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") the outer scaling unit is the pod rather than a process manager, so the usual deployment is a small number of workers per pod and many pods.

<details>
<summary><strong>Detailed answer</strong></summary>

The layers, from the outside in. A pod runs a container; the container runs Uvicorn; Uvicorn runs one or more worker processes; each worker process has one event loop and one anyio thread pool. Python's global interpreter lock means a single process uses roughly one core for pure Python work, so parallelism across cores comes from processes, not threads.

Concurrency within a worker comes from the event loop interleaving awaits. For an input/output-bound workload — which this is, since nearly all the time is spent waiting on PostgreSQL, MongoDB and Redis — one loop handles a large number of concurrent requests, because each one is mostly idle. Throughput is bounded by the slowest downstream dependency and by the central-processing-unit cost of serialisation, not by thread count.

In Kubernetes I would generally run few workers per pod — often one or two — and scale pods, because the cluster's autoscaler and scheduler are better at placement than a process manager inside a container, and because per-pod resource limits are much easier to reason about with one process. Multiple workers per pod also complicates graceful shutdown and metrics.

The numbers that actually need setting, and each has a failure mode if left at default:

**Thread pool size** bounds concurrency for `def` endpoints, and exceeding it queues requests with no visible error.

**Database pool size per pod**, which must be multiplied by the pod count and kept under the PostgreSQL Flexible Server connection limit. This is the constraint people discover during an autoscaling event: pods scale up, connections multiply, and the database refuses new ones — so an increase in load causes a hard failure rather than degradation.

**Graceful shutdown timing.** Uvicorn must stop accepting and drain in-flight requests before the pod dies, and the readiness probe must fail first so the ingress stops routing. Getting that wrong produces a small burst of connection resets on every deploy, which people learn to ignore, which is worse than fixing it.

</details>

---

### Q1. What is FastAPI's dependency injection actually for, and what does this system use it for?

**Brief answer**
It declares what a handler needs — a database session, the authenticated principal, a scope check — and lets the framework build and tear those down per request. Here it carries the three authorization checks and the request-scoped session, which is what makes those enforceable in one place rather than per endpoint.

<details>
<summary><strong>Detailed answer</strong></summary>

Mechanically, a dependency is a callable declared in the signature. FastAPI resolves it before the handler runs, caches it within the request, and — for generator dependencies — runs teardown afterwards. It also appears in the generated OpenAPI document, so a security dependency shows up in the contract rather than being invisible.

The uses that matter here:

**The database session.** A generator dependency yields a session and closes it after, so no handler manages transaction lifecycle by hand. That is where the repository layer's tenant filter is bound, which is the key point — it means tenant scoping is a property of having a session, not of remembering to filter.

**Authentication and account type.** A dependency validates the JSON Web Token locally against the cached key set and produces a principal object with `sub`, `act`, `org_id`, roles and scopes. The account-type check is then a router-level dependency: everything under `/v1/vendor/*` requires `act = vendor`. Applying it at the router rather than per endpoint is deliberate — the failure mode of per-endpoint checks is the endpoint someone adds next year without one, and a router-level dependency covers routes that do not exist yet.

**Scope checks**, composed on top of that for finer requirements like `connection:write`.

The thing to be careful about is that dependency injection makes it easy to hide expensive work in a signature. A dependency that opens a connection or makes a network call runs on every request to that route, including ones that do not need it, and it is easy to miss in review because it does not appear in the body. Authorization here is deliberately a local claim check costing about a millisecond precisely so that this dependency is cheap — an introspection round trip per request would have added 15 to 30 milliseconds to every endpoint, and the latency budget rests on it not doing that.

The other caution is testability. Dependency overrides make testing easy, and that ease makes it tempting to override the authorization dependency in tests — at which point the tests stop exercising the control that matters most. I would override the token *source* and keep the real validation and scoping in the path under test.

</details>

---

### Q2. Suppose you are on a synchronous FastAPI application under heavy enterprise load and you cannot rewrite it to async. How do you make it fast?

**Brief answer**
Stop trying to get concurrency from the event loop and get it from processes and pods instead, then attack the per-request cost. Size the thread pool and the database pool deliberately, move anything slow off the request path, and make sure nothing blocking is hiding inside an `async def`.

<details>
<summary><strong>Detailed answer</strong></summary>

A synchronous application under FastAPI is not a broken design — a `def` handler runs in the thread pool and the loop stays free. It is a design with a different scaling curve, and the mistake is treating it as if it were async and wondering why concurrency stalls.

**First, find the mixed-colour code.** The worst outcome is a codebase that is mostly synchronous but has some `async def` handlers calling synchronous drivers. Those block the loop and take everything with them. In a genuinely synchronous application, every handler should be `def`, and I would enforce that with a lint rule rather than a convention. This is the highest-value check and it costs an afternoon.

**Second, size the pools against each other.** Concurrency is bounded by the anyio thread pool, and each in-flight request holds a database connection while it works. So thread pool size, database pool size and the PostgreSQL connection limit are one arithmetic problem: threads per pod times pods must not exceed what the database will accept, and a connection pooler in transaction mode is usually necessary to decouple the two. Raising the thread pool without raising the connection budget just moves the queue from the pool to the database.

**Third, get parallelism from replicas.** With the global interpreter lock, one process is roughly one core for Python work, so scale pods rather than threads. That is the honest answer to "heavy enterprise load" on a synchronous stack: horizontal scale, with the database connection budget as the real ceiling — which is exactly why a pooler matters more here than in an async deployment.

**Fourth, reduce per-request work.** Serialisation is often the largest Python-side cost, so trim response payloads, keep page sizes bounded and avoid revalidating trusted data. Cache what is cacheable. Move anything slow off the request entirely — this design pushes imports, projection, notification and media processing to workers and Functions precisely so no request waits on them.

**Fifth, protect the tail.** Timeouts on every downstream call, so one slow dependency cannot occupy threads indefinitely; a bounded queue with a fast rejection rather than unbounded queueing, because a request that will time out anyway should not hold a thread; and circuit breaking on a dependency that is failing.

The measurement that tells you which of these to do is not average latency — it is thread-pool saturation and queue wait. Those are the numbers that distinguish "the application is slow" from "the application is fast but only forty requests at a time".

</details>

---

### Q2. Someone adds a blocking call inside an `async def` endpoint. Describe the symptom and how you would find it.

**Brief answer**
Throughput collapses and the high percentiles explode while the average stays plausible, with low central-processing-unit usage and no errors. I would look for event-loop lag as a metric first, and confirm it with a stack sample of the running process rather than by reading code.

<details>
<summary><strong>Detailed answer</strong></summary>

The symptom pattern is distinctive once you have seen it. Requests to *unrelated* endpoints in the same process get slow, because the loop is stalled for everyone. Latency becomes quantised — clustered around multiples of the blocking duration — since requests queue behind whichever handler is blocking. Central-processing-unit usage is low, because the process is waiting, not computing, which misleads anyone who scales on the usual signal: adding pods helps a little and never fixes it, since each new pod has the same defect.

Nothing errors. That is what makes it linger.

How I would find it. The definitive metric is event-loop lag: schedule a callback at a fixed interval and record how late it actually fires. In a healthy process that is sub-millisecond; when something blocks it spikes to the blocking duration. Exporting that as a metric turns an invisible failure into a graph, and I would want it in place before the incident rather than after — it is a handful of lines.

To localise it, a sampling profiler attached to the running process is the fastest route, since it shows what the main thread is actually doing at the moment of the stall. That answers it in minutes where reading code takes hours.

Distributed tracing helps if the blocking call is a network call — a span for a synchronous provider call inside an async handler is visible in the trace. It does not help if the block is central-processing-unit-bound, such as a large parse or a password hash, since there is no span to see. That is a real gap and the reason loop lag is the primary signal rather than tracing.

Preventing it is more valuable than detecting it. The blocking-call detection mode of the async debug facility catches it in development. A lint rule banning known-synchronous clients inside async handlers catches it at review. And where a blocking call is genuinely necessary — a library with no async version — wrapping it in `run_in_threadpool` makes the cost explicit at the call site, which is the version I would want in the codebase rather than a comment.

</details>

---

### Q2. The frontend team generates its client from your OpenAPI document. What counts as a breaking change, and how do you ship a field that must be required?

**Brief answer**
Anything that makes a previously valid request invalid or a previously valid response unparseable — a new required request field, a removed or narrowed response field, a changed type or enum tightening. A newly required field ships in stages: optional with a default, adoption, then required.

<details>
<summary><strong>Detailed answer</strong></summary>

Code generation changes the stakes. When the client is generated from the specification, a change to the document is a change to the frontend's compiled types, and a mismatch surfaces as a build failure or a runtime parse error rather than as a tolerated extra field. That is mostly an improvement — drift becomes loud — but it means the contract has to be managed deliberately.

**Breaking on the request side:** adding a required field, removing a field the client sends and the server needs, narrowing a type, tightening an enum by removing a value, adding a stricter constraint, or making an optional query parameter mandatory.

**Breaking on the response side:** removing a field, making a non-nullable field nullable, changing a type, or adding a value to an enum the client switches on exhaustively. That last is the one people argue about: adding an enum value is additive on the wire and breaking for a generated client with exhaustive matching, so it has to be treated as breaking unless the client is written to tolerate unknown values — a decision to agree with the frontend team once rather than per change.

**Not breaking:** adding an optional request field, adding a response field, or loosening a constraint.

Shipping a newly required field is expand/contract applied to an API. First deploy accepts it as optional, with the server applying a sensible default when absent, and record how often the default path is taken. Then the client starts sending it, and the metric confirms adoption reached effectively 100%. Only then does it become required, in a separate release. Skipping the middle step is the mistake — declaring it required and coordinating a simultaneous deploy of both sides means a rollback of either one breaks the other, which is exactly the situation you were trying to avoid.

Two things make this workable in practice. The document is generated from Pydantic models, so it cannot drift from behaviour. And the pipeline runs functional contract tests against it, which is where a diff against the previous published specification belongs — an automated breaking-change check on the merge request, so the conversation happens before the frontend's build breaks rather than after.

</details>

---

### Q2. `POST /v1/connections` requires an `Idempotency-Key`. Implement it properly — what are the failure cases?

**Brief answer**
Store the key with the request fingerprint and the eventual response, keyed uniquely in the database rather than only in the cache. The hard cases are a retry arriving while the first is still in flight, and a retry reusing a key with a different body.

<details>
<summary><strong>Detailed answer</strong></summary>

The requirement is concrete: a double-submitted connection request from a category manager must not create two threads and must not bill the vendor twice. Billing makes this a correctness problem rather than a cosmetic one.

The mechanism has two layers, and which is the guarantee matters. `connection_request` carries `UNIQUE (retail_group_id, idempotency_key)`, so the database is what finally prevents the duplicate. The Redis `idem:*` key is the fast path that avoids doing the work twice — it is an optimisation, and it must never be the only thing standing between the system and a duplicate charge, because a cache flush would then create one. The related constraint `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge` enforces the same property one layer down, in the schema rather than in retry logic.

The flow. On arrival, attempt to claim the key by inserting a record in a `processing` state. If the insert succeeds, do the work and store the response. If it conflicts, look at the existing record.

**Case one — completed.** Return the stored response verbatim, with the original status code. Not a fresh computation, because the resource may have changed since; the client asking again with the same key is asking "what happened to my request", and it must get the same answer.

**Case two — still processing.** The first request has not finished. Return 409 with a retry hint rather than blocking, because blocking ties up a thread on a request whose outcome is unknown. This is the case people forget, and under a double-click it is the common one.

**Case three — same key, different body.** This is a client bug, and it must be an error, specifically 422 rather than a silent replay. If you replay the stored response for a different request, the client believes an operation happened that did not. Detecting it requires storing a hash of the request body alongside the key.

Scope and expiry: keys are scoped per organisation, so one tenant cannot collide with or probe another's, and they expire after 24 hours — long enough to cover any realistic retry, short enough that the table does not grow forever.

The last piece is that the response must be stored in the same transaction as the state change. Committing the connection and then failing to record the idempotency result means a retry does the work again.

</details>

---

### Q2. Nine deployments, autoscaling, one PostgreSQL Flexible Server with a connection limit. Walk me through sizing the connection pools.

**Brief answer**
The sum of every pod's maximum pool across all deployments must stay under the server's limit with headroom, and that sum moves when the autoscaler moves. The arithmetic has to be done against maximum replica counts, not current ones, and a pooler is what decouples the two.

<details>
<summary><strong>Detailed answer</strong></summary>

The failure this prevents is nasty and specific: load rises, the horizontal pod autoscaler adds pods, each new pod opens its pool, the server hits `max_connections`, and it starts refusing *all* new connections — including from the pods that were already healthy. So an increase in load produces a hard, total failure rather than gradual degradation, and it happens at the worst moment. Azure Database for PostgreSQL derives its connection limit from the instance tier, and on smaller tiers it is lower than people expect.

The arithmetic is straightforward and has to be done pessimistically: for each deployment, pool maximum plus overflow, times the maximum replica count the autoscaler will reach, summed across all nine, plus a reserved allowance for migrations, the reconciliation job, and human access during an incident — which is exactly when you must be able to connect. That total goes under the limit with real headroom.

Two things make it tractable here. FastAPI's async handlers mean a pod holds a connection only while a query is actually in flight, so a small pool per pod goes a long way — the connection is not held for the whole request. And read traffic goes to the replica, which has its own limit, so the read-heavy service is not competing with writers for the same budget.

Where the numbers do not fit, a connection pooler in transaction mode is the answer: applications connect to the pooler with generous pools and the pooler multiplexes a small number of real backend connections. That decouples pod count from backend connections entirely, which is what makes aggressive autoscaling safe. The caveat is that transaction-mode pooling breaks anything relying on session state — session variables, prepared statements, advisory locks — and this is one of the stated reasons the design does not use PostgreSQL Row-Level Security as its primary tenant control: setting a per-request session variable through a transaction-mode pooler is precisely where that mechanism silently becomes a no-op or leaks across pooled sessions.

The operational corollary is to alert on connection count as a fraction of the limit, well before it saturates. It is a slow-moving number that becomes an outage instantly, which is the profile that most deserves an alert.

</details>

---

### Q3. Size this for its stated 100 QPS peak capacity target on the assumption of a synchronous stack. What breaks first?

**Brief answer**
The database connection budget, not the application. On a synchronous stack each in-flight request holds a connection for its whole duration, so pods times threads is a direct multiplier on connections — and that saturates long before central-processing-unit does at this request rate.

<details>
<summary><strong>Detailed answer</strong></summary>

Work it from the request side. At 100 queries per second with an average server-side latency near 107 milliseconds on the uncached path, Little's law gives roughly 11 concurrent requests in flight in the steady state. That is a small number, and it is why this system is not throughput-constrained. Peaks and tails matter more than the average, so I would size for several times that — say 40 to 50 concurrent — to absorb a slow dependency without queueing.

On a synchronous stack, those 50 concurrent requests are 50 threads across the fleet, each holding a database connection for the request duration rather than only during a query. With, say, ten pods at eight threads each, that is 80 potential connections from one service — and this is one of six services plus three worker pools. The sum against a Flexible Server limit is where it breaks, and it breaks hard: refused connections rather than slow responses.

Central-processing-unit is the second constraint and a distant one. Serialisation is around 12 to 14 milliseconds per search page, so 100 requests per second is roughly 1.4 core-seconds per second of pure Python work — two or three cores across the fleet, before any framework overhead. Comfortable, and it is why the autoscaler targets 65% central-processing-unit rather than something aggressive: there is room.

Memory rarely binds for the web tier. It does for the import workers, where prefetch and payload size dominate, which is why those scale on queue depth rather than central-processing-unit and have their own limits.

So the sizing conclusions: a connection pooler in transaction mode to decouple pods from backend connections, thread pools sized deliberately rather than left at 40, timeouts on every downstream call so one slow dependency cannot occupy every thread, and bounded queueing with fast rejection instead of unbounded queueing. The last one matters most under a genuine spike — a request that will exceed its deadline anyway should be rejected immediately rather than holding a thread and a connection while it dies.

The honest caveat is that all of this assumes the cache is doing its job. At an 85% hit ratio the concurrency figures above hold; if Redis is lost, latency triples and so does concurrency in flight, which triples connection demand. Capacity is sized to survive that, and it is the scenario I would load-test rather than calculate, because it is where the arithmetic and reality most often part company.

</details>

---

### Q3. The admin console is a static single-page application calling the same public API, with no dedicated backend. Defend the chattiness, and say when you would add an aggregate endpoint.

**Brief answer**
It means no admin capability exists that the public contract does not already describe and test, which removes an entire class of unaudited privileged path. The cost is more requests on screens that join across services, and I would add an aggregate endpoint when a specific screen's latency becomes a real complaint — as a versioned public endpoint, not a private one.

<details>
<summary><strong>Detailed answer</strong></summary>

The alternative — a backend-for-frontend serving the admin console — is faster to build and produces better screens. What it costs is a second write path with its own copy of the domain rules, and the failure that follows is predictable: the vendor API refuses to publish a listing for a `pending` vendor, the admin path does not, and a support action creates a state the domain believes impossible. The rules diverge because nothing forces them to agree.

Serving the console as a static bundle from blob storage through the edge, calling `/v1/admin/*` on the same services with the same Pydantic models, means one set of rules, one OpenAPI document, one suite of functional contract tests. Every admin capability is described by a contract that something already tests. In a system whose threat model is dominated by authenticated insiders and whose most privileged actor is the platform operator, that property is worth paying for — an unaudited internal path used by operators is exactly where a tenant-scope bypass would hide.

The cost is real: an entity screen showing a vendor with its listings, its billing account and its recent connections needs several calls across several services, and each carries its own authorization and serialisation. On a well-connected internal user's browser that is fine; it is not free.

When I would add an aggregate endpoint: when a specific screen has a measured latency problem that request parallelism and pagination do not fix. And I would add it as a versioned public endpoint under the same contract — a composite read model, in the API, tested like everything else — rather than as a private backend. That keeps the property that matters (one described and tested surface) while buying back the latency. What I would not do is introduce a service whose whole purpose is to be exempt from the contract.

The trigger I would actually watch for is different from latency: if operators start asking for capabilities that do not fit the public contract — bulk state changes, cross-tenant queries, data corrections — that is a signal the admin domain has genuinely diverged, and the right answer is to model those as first-class audited operations rather than to smuggle them in through a private path.

</details>

---

### Q3. The API is versioned as `/v1` in the path. What happens when you need `v2`, and would you do it differently?

**Brief answer**
Path versioning is coarse: it versions the whole surface for a change affecting one endpoint, and running two versions means maintaining two sets of handlers against one domain. I would keep it, because it is legible to clients and trivial to route — but I would version at the resource level in practice and reserve a global `v2` for a genuine break.

<details>
<summary><strong>Detailed answer</strong></summary>

The alternatives each trade differently. Header-based versioning is finer-grained and invisible in logs, browser address bars and support conversations, which makes debugging worse and makes it easy for a client to end up on a version nobody realised. Media-type negotiation is the most correct and the least used, which itself is a cost — generated clients and tooling handle it poorly. Path versioning is coarse and obvious, and obvious wins for an API consumed by external vendor integrations that will not all upgrade on your schedule.

The real question is not the scheme but how to avoid needing it. Most changes are additive and need no version at all: new optional request fields, new response fields, new endpoints. The expand/contract discipline described for required fields handles most of the rest. In practice a well-run API's `v1` lasts years, and reaching for `v2` early usually means the change management was skipped.

When a genuine break is unavoidable — a resource whose shape is wrong, a semantic change that cannot be expressed additively — the approach I would take is to introduce the new shape as a new resource path under `v1` rather than versioning the entire surface. `/v1/catalog/products` and `/v1/catalog/product-listings` with different shapes is uglier than `/v2/catalog/products` and vastly cheaper: clients migrate one endpoint at a time, the old one gets a deprecation header and a sunset date, and nobody maintains two parallel handler trees for the ninety per cent of endpoints that did not change.

A global `v2` I would reserve for a break that genuinely spans the surface — a change to authentication, error format, or pagination. And I would run it as a translation layer over one domain implementation, never as a forked codebase, because two implementations of the same rules diverge and the divergence is discovered by a customer.

The operational prerequisite for any of this is knowing who uses what. Per-subscription metrics at the gateway, tagged by endpoint and version, so a deprecation is a conversation with three named vendor integrations rather than an announcement into the void. Without that, you cannot retire anything and the versions accumulate — which is the actual long-run cost of getting this wrong.

</details>

---

## Identity, Authorization and Tenant Isolation

---

### Q1. Explain the OAuth 2.0 authorization code flow with Proof Key for Code Exchange, and why the web clients here use it.

**Brief answer**
The client redirects the user to the authorization server, gets a short-lived code back, and exchanges it for tokens on a second channel. Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")) binds that exchange to a secret the client generated, so an intercepted code is useless to anyone else. Both web clients are public clients with no secret to keep, which is exactly what PKCE is for.

<details>
<summary><strong>Detailed answer</strong></summary>

The flow: the client generates a random `code_verifier` and sends its hash as `code_challenge` on the authorization request. The user authenticates at `identity-service`, which redirects back with a one-time authorization code. The client then posts that code together with the original `code_verifier` to the token endpoint, which hashes it, compares, and only then issues tokens.

What PKCE prevents is code interception. The code travels through the browser — in a redirect Uniform Resource Locator, visible in history and referrer headers, and historically interceptable by a malicious application registered for the same redirect scheme. Without PKCE, possessing the code is enough to get tokens. With it, an attacker also needs the verifier, which never left the client. It was designed for mobile applications and is now recommended for all public clients, browser-based ones included.

Why not the alternatives. The implicit flow returned tokens directly in the redirect fragment, putting them in browser history and referrers, and is deprecated. Resource owner password credentials — the client collecting the username and password directly — trains users to type credentials into arbitrary applications, cannot support multi-factor or federated login, and is likewise deprecated.

The client type is what decides. The marketplace web application and the admin console are public clients: their code is delivered to the browser, so any embedded secret is readable. They get authorization code with PKCE and no client secret. Vendor system integrations pushing catalog data are confidential clients running on servers, so they use client credentials with a secret hashed with Argon2id in `oauth_client` — a machine-to-machine grant with no user, which is the right shape for an automated feed.

The refresh token then lives in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie scoped to the API origin, so cross-site scripting cannot read it from JavaScript. That is a meaningful improvement over storing tokens in `localStorage`, which is the default mistake in single-page applications and turns any script injection into a full account takeover.

</details>

---

### Q1. What is in a JSON Web Token here, and what does verifying it locally against a cached key set buy over calling an introspection endpoint?

**Brief answer**
It carries `sub`, the account type `act`, `org_id`, roles, scopes, a token identifier and expiry, signed with [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs"). Local verification costs about a millisecond and no network call; introspection would add 15 to 30 milliseconds to every request and make `identity-service` a synchronous dependency of everything.

<details>
<summary><strong>Detailed answer</strong></summary>

A JSON Web Token ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "Compact, signed token format for carrying claims between parties")) is a signed, base64-encoded set of claims. RS256 means asymmetric signing: `identity-service` holds the private key in Key Vault, and every service verifies with the public key published at the JWKS endpoint. That asymmetry matters — a compromised service can verify tokens but cannot mint them, which would not be true with a shared symmetric secret.

The claims are chosen so that authorization needs nothing else. `act` says vendor, retailer or platform, and drives the coarse router-level check. `org_id` is the tenant, and it is what the repository layer filters every org-owned query on. `roles` and `scopes` carry the finer permissions. So the three-check authorization model — account type, then role-to-scope, then tenant scope — runs entirely on claims already in hand.

That is the whole argument for local verification. The design's latency budget puts authorization at one millisecond and states plainly that it only holds because there is no network call: a signature check against a key already in memory, plus expiry and audience validation. Introspection — asking the authorization server whether this token is currently valid — would add a round trip to every request in a system where the total server-side budget is around 107 milliseconds, and would make `identity-service` a hard dependency on the critical path of every other service. Its outage would become a total outage.

The price is revocation latency. A locally-verified token stays valid until it expires, because nothing consults a central authority. That is bounded by the 15-minute access-token lifetime, which is short enough to be an acceptable window for most cases and is the deliberate trade being made. Where 15 minutes is not good enough — a suspended vendor — the design adds a small Redis denylist of revoked token identifiers that services consult, populated from an `identity.user.deactivated` event. That is a targeted exception for the rare case, rather than making every request pay for it.

Verification also happens twice on purpose: the gateway validates signature, expiry and audience at the edge so a forged token never reaches the cluster, and each service validates again and applies its own rules. The edge is a filter, never the authority.

</details>

---

### Q1. Distinguish authentication, role-based access control and attribute-based access control, and name the three checks this system runs.

**Brief answer**
Authentication establishes who the caller is; role-based access control decides what that kind of user may do; attribute-based access control decides which specific rows they may touch. Here they are account type from the `act` claim, then role-to-scope, then tenant scope on `org_id` — in that order, on every request.

<details>
<summary><strong>Detailed answer</strong></summary>

The distinction that matters is that the first two are about *capabilities* and the third is about *instances*, and conflating them is how multi-tenant systems leak.

**Account type** is the coarsest check and the one the brief explicitly asked for — catalog and connection endpoints staying behind the right account type. It is a router-level FastAPI dependency: `/v1/vendor/*` requires `act = vendor`, `/v1/retailer/*` requires `act = retailer`, `/v1/admin/*` requires `act = platform`. A retailer token cannot reach a vendor route regardless of its scopes. Being at the router rather than the endpoint is deliberate, because it covers routes that do not exist yet.

**Role to scope** is classic role-based access control, resolved at token issue rather than at request time. A vendor `viewer` receives `vendor:read` only. A retailer `category_manager` receives `retailer:read` and `connection:write` but not `retailer:admin`, so it can open a conversation but cannot add stores or change group membership. Resolving at issue keeps the request path free of a role lookup, at the cost that a role change takes effect on the next token — bounded by the same 15-minute window.

**Tenant scope** is attribute-based and is the one that actually protects the data. Every query touching an org-owned table filters on `org_id` from the token. This is where the real threats live: a vendor reading a competitor's drafts, a retail group reading another group's shortlists. Account type does not help — both callers are legitimately vendors.

The critical design decision is that tenant scoping is enforced in *one* place: a session-level filter applied by the repository layer, not a check written into each endpoint. A per-endpoint check is a control that works until the day someone adds an endpoint, and that day always comes. Centralising it means the failure mode changes from "one endpoint forgot" to "the repository layer is wrong", which is a single auditable thing with a single test — assert that cross-tenant reads return empty for every org-owned repository method.

Platform admins bypass the third check explicitly, in one code path, and every bypass writes an audit record.

</details>

---

### Q2. Walk me through refresh token rotation with reuse detection. What happens when a token is stolen?

**Brief answer**
Every refresh mints a new token and revokes the old one, so a token is single-use. If a revoked token is presented, that means two parties hold the chain — so the entire chain is revoked and an alert is raised. The legitimate user is logged out, which is the correct outcome.

<details>
<summary><strong>Detailed answer</strong></summary>

Static long-lived refresh tokens are the weak point of most token-based designs: a 30-day credential that grants fresh access tokens indefinitely, with theft indistinguishable from normal use.

Rotation makes each one single-use. `refresh_token` records `jti`, `issued_at`, `expires_at`, `revoked_at` and `replaced_by`, forming a chain. Presenting a valid token returns a new access token and a new refresh token, and marks the presented one revoked with `replaced_by` pointing at its successor.

Reuse detection is what turns rotation from hygiene into a detector. Consider a stolen token. Either the attacker uses it first — the legitimate client's next refresh presents a now-revoked token — or the legitimate client uses it first and the attacker's attempt presents a revoked one. In both orders, a revoked `jti` is presented, and that is a fact with only one explanation: two parties held the same token. There is no benign cause, which is what makes it a high-quality signal rather than a heuristic.

The response is to revoke the whole chain — every descendant of the compromised token — and raise an alert. Both parties are logged out. The legitimate user re-authenticates, which is mildly annoying and vastly better than an attacker holding a 30-day credential. The alert matters as much as the revocation, because it is one of the few places the system learns that a credential was compromised at all.

Two implementation details decide whether it works. The rotation must be atomic — revoke the old and issue the new in one transaction — or a concurrent refresh from two browser tabs produces a false positive that logs a real user out for no reason. And the network-failure case needs thought: a client that receives a new token but fails to store it will retry with the old one and trigger detection. A short grace window where the immediate predecessor is accepted once mitigates that, at a small cost in strictness, and I would want that decision made explicitly rather than discovered through support tickets.

Revoked rows are kept for 30 days past expiry, because deleting them immediately would mean a reused token looks unknown rather than revoked, and the detector would go quiet.

</details>

---

### Q2. PostgreSQL Row-Level Security is the stronger mechanism for tenant isolation, and this design rejects it as the primary control. Defend that.

**Brief answer**
Row-Level Security depends on a per-request session variable, and the read path uses a pooled connection with a shared role — which is exactly where that variable either fails to apply or leaks between requests. A control that silently becomes a no-op is worse than one you know you have to enforce in the application.

<details>
<summary><strong>Detailed answer</strong></summary>

I want to be clear that Row-Level Security is genuinely stronger in principle. It puts the filter in the database, so a query that forgets it returns nothing rather than everything, and it protects against application bugs, ad-hoc queries and any future consumer of the schema. If it fits, it is the better answer.

The reason it does not fit here is connection pooling. Row-Level Security policies read a session variable — something like `current_setting('app.current_org')` — that the application sets per request. In transaction-mode pooling, a connection is handed to a transaction and returned afterwards, so the session in which you set the variable is not reliably the session your next statement runs in. Two failure modes follow, and both are bad: the variable is unset and the policy either blocks everything or, if written with a permissive fallback, allows everything; or the variable is left over from a previous request and one tenant's query executes under another tenant's scope. The second is a cross-tenant data leak that looks like a working system.

This is not hypothetical for `catalog-service`, which reads a replica through a pooled connection with a shared role. And the design already leans on transaction-mode pooling to keep the connection budget manageable across nine autoscaling deployments — so the two mechanisms are in direct conflict, and one of them has to give.

Getting Row-Level Security wrong is worse than not relying on it, because the team believes a control is enforcing something it is not. That is the actual argument: not that it is hard, but that its failure is silent and its presence produces false confidence.

The compensating control is that tenant filtering lives in exactly one auditable layer — a session-level filter applied by the repository layer, not per endpoint — with a test asserting that cross-tenant reads return empty for every org-owned repository method. One place to review, one place to test, and a test that fails loudly.

What would change my answer: session-mode pooling or per-tenant database roles would make Row-Level Security viable, and if a compliance requirement demanded database-enforced isolation, I would restructure the connection strategy to get it rather than argue. It is a defensible rejection, not a permanent one — and I would want it revisited rather than inherited as folklore.

</details>

---

### Q2. Access tokens live 15 minutes, so revocation is bounded by that. A vendor is suspended for fraud and must lose access now. Walk me through it.

**Brief answer**
Revoke the refresh chain immediately, publish `identity.user.deactivated`, and have services consult a small Redis denylist of revoked token identifiers so outstanding access tokens are rejected before they expire. It is a targeted exception to local verification, not a general introspection call.

<details>
<summary><strong>Detailed answer</strong></summary>

The tension is structural. Local token verification is what makes authorization cost a millisecond and keeps `identity-service` off the critical path — but it means no service asks anyone whether a token is still good, so a valid signature and an unexpired `exp` are sufficient. For nearly everything, a 15-minute window is an acceptable price. For a suspended vendor it is not: fifteen minutes is long enough to export a catalog or send messages that will have to be retracted.

The sequence:

**Revoke the refresh chain** in `identity-service`, so no new access tokens can be minted. That closes the future immediately and is the most important step, because without it the account keeps refreshing indefinitely.

**Publish `identity.user.deactivated`** through the outbox, consumed by `retailer-service` and `vendor-service` to tombstone the actor and by the identity path to populate the denylist.

**Populate a Redis denylist** of revoked token identifiers, which every service checks alongside signature verification. This is the part that closes the existing window. It is affordable precisely because it is small and rare — a set of identifiers for tokens revoked within the last 15 minutes, so entries expire on their own at the token's own expiry. It is not introspection: no round trip to `identity-service`, one local Redis lookup that is already on the path for other reasons.

**Suspend at the vendor level too**, setting `vendor.status` to `suspended`. That is the durable control — publication is gated on vetting state, so even a token that slips through cannot publish. Defence in depth matters here because the denylist is a cache, and caches can be empty.

The failure case worth naming: if `redis-cache` is unavailable, the denylist is unavailable, and the system falls back to accepting unexpired tokens. That is failing open on a security control, which deserves an explicit decision rather than an accident. Given `vendor.status` is checked in the database on every write path, the residual exposure is read access for up to 15 minutes, which I would accept and document — but I would want it written down, because "the security control degrades when the cache is down" is exactly the sentence nobody wants to discover during an incident.

</details>

---

### Q2. The threat model says a vendor enumerating the retailer directory would kill the marketplace. How is that prevented, and how do you test for an absence?

**Brief answer**
No vendor-facing endpoint returns retail group, store or retailer user data at all — a vendor learns a group's identity only through a connection that group initiated. Testing an absence means asserting the shape of the whole API surface, not just the behaviour of endpoints you remembered to check.

<details>
<summary><strong>Detailed answer</strong></summary>

This is the most commercially dangerous threat in the model, and the reason is that it requires no exploit. A vendor with a legitimate account querying a legitimate endpoint that returns slightly too much is enough. If the buyer side believes the platform is a lead-generation list for vendors, they leave, and a marketplace without buyers is nothing.

The control is structural rather than a filter. `retailer-service` owns retail groups, stores, retailer users and shortlists, and no vendor-scoped route reaches it. Vendors do not get a filtered view of retailers — they get no view. Identity flows only in one direction, initiated by the buyer: a `connection_request` opened by a retail group reveals that group to that vendor for that product. Everything else the vendor sees about the buyer side is aggregate and unattributed.

Testing an absence is genuinely harder than testing a behaviour, because the risk is the endpoint nobody thought about. Three layers:

**A surface test over the generated contract.** Enumerate every path in the OpenAPI document reachable with `act = vendor`, and assert none of their response models contain retailer-identifying fields. Since the document is generated from Pydantic models, this catches an endpoint added next quarter whose response happens to embed a retailer object — which no hand-written test would. This is the check that scales.

**Per-endpoint negative tests** for the routes where a leak is plausible: a vendor fetching a connection sees the group name they are in conversation with and not the individual's email; a vendor's analytics shows shortlist counts and not which groups added them.

**Repository-level tenant tests**, asserting cross-tenant reads return empty for every org-owned method — the general control this specific threat is an instance of.

The residual risk I would name is inference rather than direct disclosure. A vendor who sees connection volume by country and by store-count band, over time, can narrow down who is shopping. That is not solved by access control; it is solved by deciding what aggregates to expose and at what granularity, and by not offering a filter combination that resolves to one organisation. That is a product decision that needs to be made deliberately, and it is the kind of leak that gets built by accident while adding a useful-looking analytics feature.

</details>

---

### Q2. The gateway caches the signing key set on its own schedule, and the application caches it separately. What breaks during a key rotation, and how do you fix it?

**Brief answer**
The two caches can disagree, so tokens signed with the new key may be rejected at the edge while the cluster would accept them — a partial, confusing authentication outage. The fix is to make the key overlap window strictly longer than the slowest cache refresh, and to verify the gateway's actual refresh interval rather than assume it.

<details>
<summary><strong>Detailed answer</strong></summary>

The setup: `identity-service` signs with a private key from Key Vault, rotating every 90 days, publishing both old and new public keys at the JWKS endpoint through an overlap. Verification happens twice — the gateway validates signature, expiry and audience at the edge, and each service validates again against the key set cached in `redis-cache` for ten minutes, refreshed on an unknown key identifier.

Two independent caches with independent refresh schedules is the problem. The application cache is well-behaved: ten-minute time-to-live, and an unknown `kid` triggers an immediate refresh, so it converges within one request of a new key appearing. The gateway's cache follows its own policy, which on some tiers is measured in hours and is not obviously configurable. So during rotation there is a window where tokens signed with the new key are rejected at the edge with a signature failure and never reach the services that would have accepted them.

The symptom is nasty to diagnose: authentication failures for some users and not others — those with newly-issued tokens — with no error in the application logs at all, because the requests never arrived. Anyone debugging from the application side sees a quiet, healthy service and a lot of confused users.

The fix has three parts. First, establish the gateway's actual refresh interval for the target tier, empirically rather than from documentation. Second, make the overlap window strictly longer than that interval with real margin — publish the new public key and wait out the longest cache lifetime *before* switching the signing key, so every verifier already knows the new key by the time any token is signed with it. That ordering is the whole trick: publish, wait, then sign. Third, verify it in staging with a deliberate rotation and an assertion that requests keep succeeding throughout, because this is a procedure that runs once a quarter and will be executed by someone who has not done it before.

The general principle is that any credential rotation involving multiple independent caches is a publish-then-wait-then-switch sequence, and the wait must be derived from the slowest cache you do not control. Rotations fail when someone switches first and lets the caches catch up.

</details>

---

### Q3. Platform admins bypass tenant scoping entirely. Design that so it is safe.

**Brief answer**
Make the bypass a single explicit code path rather than an absence of a filter, require it to be requested rather than implied, audit every use with the actor and the object, and alert on volume. The danger is not that admins have the power — it is that the power is indistinguishable from a bug.

<details>
<summary><strong>Detailed answer</strong></summary>

Platform operators genuinely need cross-tenant access: vetting vendors, moderating listings, resolving disputes. The question is how to grant it without creating a path where "no tenant filter" is a normal state some code can drift into.

**Make it explicit and singular.** The repository layer applies the tenant filter by default from the token's `org_id`. A `platform` token has no `org_id`, and the temptation is to let a null `org_id` mean "no filter" — which is exactly wrong, because then any bug producing a null claim silently grants cross-tenant access. Instead the bypass should be an affirmative act: an unscoped session the caller must construct deliberately, named something unmissable in a diff. A missing `org_id` should be an error, not a wildcard.

**Audit unconditionally, at the data layer.** Every bypass writes an `audit_event` with actor, action, object type and object identifier, from the same layer that grants the bypass rather than from the endpoint that used it. Auditing at the call site means the call site that forgets is the one you needed. `audit_event` is append-only — the application role holds insert and select and no update or delete grant — and partitions are archived to immutable storage, so an operator cannot erase their own trail.

**Scope by role rather than by account type alone.** `platform_user` has `operator`, `moderator` and `support` roles, and they need different reach. Support resolving a login problem does not need to read connection message bodies; moderation does not need billing. Treating `act = platform` as a single super-power wastes the role model that already exists, and it is the difference between a compromised support account being a nuisance and being a full data breach.

**Alert on shape, not just record it.** An operator reading three vendors in an afternoon is work. One reading four hundred retail groups in an hour is either an incident or an export. Audit records nobody looks at are archaeology; a volume alert makes them a control.

The last piece is that the bypass should be as narrow as the task allows. Reading a specific vendor by identifier is different from listing all vendors, and admin screens should be built around lookup rather than enumeration wherever the workflow permits — because an enumeration endpoint is the one that turns a compromised operator account into a full copy of the marketplace.

</details>

---

### Q3. Right to erasure: a departing category manager's identity is tombstoned but the messages they wrote are retained. Defend that, and state the cost.

**Brief answer**
A vendor's record of a commercial negotiation is not the individual's to delete, so the messages are retained under the legitimate-interest exemption while identity, credentials and audit attribution are erased. The cost is that erasure is not total, the retained text may still identify its author from context, and the position must be stated in the privacy notice and defended to a regulator.

<details>
<summary><strong>Detailed answer</strong></summary>

The conflict is genuine rather than an implementation shortcut. The General Data Protection Regulation gives a data subject the right to erasure, and the messages a category manager wrote are personal data — authored by them, attributed to them, potentially identifying them from content alone. But those messages are also the counterparty's business record of a negotiation, and the vendor is not a party to the individual's employment ending.

What is erased: `auth_subject`, email and name are tombstoned, refresh chains revoked, access removed immediately, and the audit actor pseudonymised. What is retained: message bodies, re-attributed to a deleted-user tombstone. The basis is the exemption for establishing, exercising or defending legal claims — a commercial negotiation record is exactly that.

The alternative is worse, and that is the strongest part of the argument. Deleting the messages destroys the vendor's record of a conversation they participated in, potentially mid-negotiation, and leaves a thread with gaps that make the remaining messages misleading. One party unilaterally erasing half of a two-party correspondence is not a neutral act.

The costs, stated honestly. Erasure is partial, and the individual may reasonably object. Retained text can identify its author from context — a signature block, a distinctive phrasing, a reference to their own role — so tombstoning the identifier does not fully anonymise the content, and claiming otherwise would be wrong. And the position has to be written into the privacy notice up front and be defensible to a supervisory authority, which means it is a decision for the business and its counsel, not one an architect makes alone. My job is to implement it precisely, make the boundary auditable, and make sure nobody believes the erasure is more complete than it is.

The design decision this connects to is that message bodies are not encrypted at the application level either — the reasoning is the same family: they are commercial correspondence between two consenting organisations, and the operator needs to moderate abuse and investigate disputes. If a customer contract later required confidentiality from the operator, that is an envelope-encryption project with a real key-management design, and it would also change the erasure answer, because destroying a key is a much cleaner erasure than deleting rows.

</details>

---

### Q3. There is no mutual Transport Layer Security between services. Defend that, and name the exact trigger that would change it.

**Brief answer**
Doing it properly means a service mesh, and a mesh's cost — sidecar lifecycle, certificate rotation, a new failure mode in every request path — is disproportionate for nine workloads in one namespace with no untrusted tenant. The trigger is concrete: a second tenant-facing workload in the cluster, a third-party container, or a compliance requirement naming internal encryption in transit.

<details>
<summary><strong>Detailed answer</strong></summary>

What is actually in place: [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") 1.3 from clients to the edge and from the edge to the ingress, TLS with certificate verification to every data store over private endpoints with no public addresses, and TLS to Service Bus, Blob and Key Vault with workload identity rather than connection strings. Plaintext HTTP exists only between pods inside one namespace, constrained by a default-deny NetworkPolicy with explicit allows per pair.

The threat mutual TLS would address is an attacker with a foothold inside the cluster network, able to observe or inject traffic between pods. That is a real threat in a shared cluster. It is much weaker here: one namespace, nine workloads, all our own code, no customer-supplied containers, no multi-tenant compute. An attacker who can read pod-to-pod traffic has already achieved code execution in the cluster, at which point they can read the service account tokens and call the services directly — so mutual TLS would not be the control that saves you.

Against that, the mesh's cost is not theoretical. A sidecar per pod means a second container's lifecycle to coordinate with the application's, including startup ordering races where the application starts before the proxy is ready and its first calls fail. Certificate rotation becomes a thing that can break every request path at once. Debugging gains a hop. And mesh upgrades are cluster-wide events. For nine workloads that is a poor trade.

What matters more than the decision is that the reversal trigger is written down and specific, because "we'll add it when we need it" is how it never gets added. The three named conditions: a second tenant-facing workload in the cluster, so pod-to-pod traffic crosses a trust boundary; a third-party or customer-supplied container, same reasoning; or a compliance requirement explicitly naming encryption in transit between internal services, which is common in regulated sectors and would not be arguable.

The honest weakness of the current position is that the threat model's own conclusion — that every dangerous attack here is an authorization problem rather than a network one — is the justification, and if that conclusion stopped holding, the network posture would need revisiting alongside it. I would rather state that dependency than present the decision as unconditional.

</details>

---

## Testing, Delivery and Observability

---

### Q1. Unit, integration and functional tests all gate this pipeline. What does each catch that the others do not?

**Brief answer**
Unit tests catch logic errors in isolation and run in seconds. Integration tests catch everything that only appears when real infrastructure is involved — query plans, constraints, driver behaviour. Functional tests catch contract violations at the API surface, which is what clients actually consume.

<details>
<summary><strong>Detailed answer</strong></summary>

They fail differently, which is the point of running all three.

**Unit tests** exercise domain logic with no infrastructure: can a listing be published while its vendor is `pending`, does the price band calculation handle a null ceiling, does the facet validator reject an unknown key. They are fast enough to run on every save, so they are where the bulk of the coverage should come from. What they cannot see is anything about the database — a mocked repository returns whatever you told it to, so a query that would fail on a constraint passes happily.

**Integration tests** run against real PostgreSQL, MongoDB and Redis brought up by Docker Compose at pinned versions. This is where the things that actually break in this system live. Does the unique constraint on `(retail_group_id, idempotency_key)` genuinely prevent a duplicate connection. Does the projection upsert ignore an older `source_revision_id`. Does the faceted search use `idx_plf_browse` or fall back to a sequential scan. Does a cross-tenant read return empty. Every one of those is a property of the database, and a mocked test passes while broken — which is worse than no test, because it creates confidence.

**Functional tests** call the API over HTTP as a client would, and validate against the OpenAPI document. They catch the layer above: status codes, error shapes, pagination behaviour, authorization at the router, and contract drift. Since the admin console and vendor integrations generate their clients from that document, a functional contract test is the thing standing between a model change and a broken frontend build.

The proportions matter as much as the presence. Many unit tests, a substantial integration layer targeted at infrastructure-dependent behaviour, and a thinner functional layer covering the contract and the critical paths. Inverting that — mostly end-to-end tests — produces a suite that is slow, flaky, and tells you something is broken without telling you what.

</details>

---

### Q1. What does a test coverage number actually tell you, and what does it not?

**Brief answer**
It tells you which lines executed during the suite. It does not tell you whether anything was asserted, whether the interesting inputs were tried, or whether the behaviour is correct. High coverage is weak evidence of quality and strong evidence of the absence of entirely untested code.

<details>
<summary><strong>Detailed answer</strong></summary>

Line coverage measures execution, not verification. A test that calls a function and asserts nothing gives full coverage of that function. So does a test asserting something trivially true. This is not hypothetical — it is exactly what a suite drifts toward when a number is a merge gate and the deadline is close, because the fastest way to raise coverage is to execute code without checking it.

What it genuinely tells you is the negative: code with zero coverage was never run by any test, so nothing at all is known about it. That is real information, and it is why the metric is worth having. A 40% figure is a legitimate alarm.

What it misses, concretely. Branch coverage is weaker than line coverage suggests — a single test through an `if` covers both the condition line and the taken branch while the other path is unexercised. Input space is invisible: full coverage of a price-band function says nothing about the null case, the negative case, or the boundary. Interaction is invisible: every unit fully covered and the composition still wrong. And the failures that matter most in this system — a projection that silently drops a facet, a tenant filter that stops applying, an alert rule nobody validated — are behaviours whose absence coverage cannot see at all, because absent code has no lines.

What I actually look at alongside it: whether tests assert outcomes rather than calls, whether the tests fail when the code is wrong — which mutation testing measures properly and a spot check by deliberately breaking something measures cheaply — and whether the paths that would hurt most in production are covered at all, regardless of the aggregate.

The pragmatic position is that a coverage target is a floor with a known gaming strategy, and the way to keep it honest is to review test quality in code review rather than to trust the number. A 90% target is achievable honestly; it is just not self-verifying.

</details>

---

### Q1. Ruff, a type checker, SonarQube and Trivy all gate this kind of pipeline. What does each catch that the others do not?

**Brief answer**
Ruff catches style and simple correctness patterns in milliseconds. A type checker catches interface mismatches across module boundaries. SonarQube catches structural issues and tracks them over time. Trivy catches known vulnerabilities in dependencies and images, which is the only one of the four that changes without anyone touching the code.

<details>
<summary><strong>Detailed answer</strong></summary>

**[Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects")** is upstream of all four and worth naming first: it resolves dependencies to a lock file, so every environment — a laptop, a CI job, a production image — installs the identical set. Without that, the other three tools are auditing different code in different places, and a vulnerability report against a version nobody actually runs is noise.

**Ruff** is a linter and formatter covering the space [Flake8](https://flake8.pycqa.org/en/latest/ "Flake8 — Lint tool that checks Python code for style and programming errors"), isort and Black occupied, fast enough to run on save and in a pre-commit hook. Its value is partly the bug classes it catches — unused variables, mutable default arguments, shadowed builtins, a bare `except` — and mostly that it ends every discussion about formatting. Style debates in code review are pure cost, and delegating them to a tool that reformats deterministically removes them entirely.

**A type checker** — Mypy or an equivalent — catches what linters structurally cannot: a function called with the wrong shape from another module, a nullable value used without a check, a refactor that renamed a field in one place and not another. In a Python codebase spanning six services and three workers, this is the tool that makes large refactors safe, because it finds every call site rather than every call site you remembered. The value is proportional to annotation coverage, so it is worth being strict in new code and pragmatic about legacy.

**SonarQube** covers a different axis: cyclomatic complexity, duplication, and its own bug and security-hotspot rules, tracked over time with a quality gate on new code. The over-time property is the distinctive one — it makes gradual decay visible, and gating on the diff rather than the whole codebase means a legacy module does not block every merge while still preventing new debt.

**Trivy** scans dependencies and container images for known vulnerabilities. It is categorically different from the other three because its findings change when nothing in the repository changed — a Common Vulnerabilities and Exposures identifier published today makes yesterday's green build red. That is why the design rebuilds base images weekly and pins by digest: pinning gives reproducibility, and scheduled rebuilds plus scanning stop pinning from meaning "frozen on a vulnerable base forever". Those two disciplines only work together.

They overlap slightly and each has a gap the others fill. What none of them catches is whether the code does the right thing, which is what tests and review are for — and the trap is a pipeline with five green gates and no behavioural verification, where the gates provide confidence out of proportion to what they actually check.

</details>

---

### Q1. Terraform state lives in a locked, versioned blob container and applies run only from CI. What does each of those three properties protect against?

**Brief answer**
Locking prevents two concurrent applies from corrupting state or racing on the same resource. Versioning makes a corrupted or wrongly-applied state recoverable. Applying only from CI means the deployed infrastructure matches a reviewed commit, rather than whatever the last person ran from their laptop.

<details>
<summary><strong>Detailed answer</strong></summary>

Terraform state is a mapping from configuration to real resource identifiers, and it is the single most fragile artefact in an infrastructure-as-code setup, because losing it does not lose the infrastructure — it loses Terraform's knowledge of it, and the next apply then tries to create everything that already exists.

**Locking.** Two applies at once can interleave reads and writes to state and produce a file describing infrastructure that does not exist. Blob lease locking makes the second apply wait. It matters most exactly when it is most likely: an incident, when two people are both trying to fix something.

**Versioning.** Recovery. A bad apply, a state file truncated by a failed upload, a resource removed from configuration and destroyed by accident — all of those are recoverable by restoring a prior version. It also gives an audit trail of what the infrastructure looked like at a point in time, which is invaluable during an incident review.

**Applies only from CI, on the default branch.** This is the one that turns infrastructure-as-code from a convenience into a control. If people can apply from laptops, state drifts from the repository, the configuration stops describing reality, and the next CI apply produces surprising changes. Restricting it means every infrastructure change is a reviewed merge request. That is also what makes the security posture reviewable: role assignments are Terraform resources, so a widened permission appears as a diff someone approves rather than a click nobody saw. The design says explicitly that nothing in the secrets and identity section is enforced by code review alone — this is the mechanism that makes that true.

Two things I would add. Alert rules belong in Terraform for the same reason, and the design says so: an alert silenced by hand during an incident and never restored is the standard way monitoring rots. And CI authenticates to the cloud by workload identity federation rather than a stored service principal secret, so there is no long-lived credential to leak — which matters because the design also names this deploy identity as the largest concentration of privilege in the system, and splitting it into plan-only and apply-only identities is flagged as work to do before the first production apply rather than after an incident.

</details>

---

### Q1. The CV lists administering Linux hosts. What does that actually mean when everything runs as containers on a managed Kubernetes service?

**Brief answer**
It moves from configuring individual machines to building images, setting resource and security constraints, and keeping node pools patched. The traditional per-host work mostly disappears; what remains is base-image hygiene, the container's own userspace, and understanding the kernel behaviour that still shows through.

<details>
<summary><strong>Detailed answer</strong></summary>

Three layers, and it is worth being precise about which is which, because "Linux administration" means very different things across them.

**The node pool.** On a managed service, node images are provisioned and patched through the platform, and the work is choosing the image, scheduling upgrades, draining nodes safely and sizing the pool. The design treats this as an operations practice rather than an architectural element — it shows up as node-pool image maintenance and nothing more. Cordon-and-drain during an upgrade is where it intersects with the application: pods must tolerate being evicted, which is why workers use a `preStop` hook that stops consuming and waits for the in-flight task inside a 120-second grace period rather than being killed mid-chunk.

**The container image.** This is where most of the remaining work lives, and it is genuinely Linux administration: choosing a minimal base, not running as root, dropping capabilities, a read-only root filesystem where possible, and keeping the image small because every package is attack surface that Trivy will eventually flag. Base images rebuilt weekly and pinned by digest is the discipline that keeps this from rotting.

**The parts of the kernel that still show through**, which is where actual experience pays. Container memory limits are enforced by control groups, so a Python process exceeding its limit is killed by the out-of-memory killer with no traceback — which looks like a mysterious restart unless you know to check the exit code and the node's kernel log. File descriptor limits bite services holding many connections. Time-wait socket accumulation shows up under high connection churn. And Java-or-Python heap sizing against a control-group limit rather than the node's total memory is a classic source of pods that die under load for no visible reason.

So the honest summary is that the per-host configuration management work — packages, users, service units, hardening a machine — is largely gone, replaced by image definitions and manifests. What transfers is the diagnostic skill: reading a process's actual state, understanding what killed it, and knowing that a container is a process with constraints rather than a small virtual machine.

</details>

---

### Q2. The client targets 90% coverage and manages test cases in Xray linked to Jira. How do you reach that number honestly, and how do you work with a test-management tool on top of a code suite?

**Brief answer**
Reach it by testing behaviour rather than lines — start from the paths whose failure would hurt, and let coverage follow. For the tool, keep one source of truth: the automated test is the truth, and the management tool holds the traceability link, populated from the run rather than maintained by hand.

<details>
<summary><strong>Detailed answer</strong></summary>

**On the number.** Ninety per cent is reachable honestly and trivially reachable dishonestly, and the difference is entirely in what gets asserted. The way it goes wrong is treating the gap as the work item — finding the uncovered lines and writing tests that execute them. That produces tests coupled to implementation, which then break on every refactor, which teaches everyone that the suite is an obstacle.

The way that works is starting from consequences. In this system: a duplicate connection request creating two threads and two charges, a tenant filter that stops applying, the projection dropping a facet so listings vanish from search, an import half-applying, a migration that is not backward-compatible. Write tests for those first, at the level where the behaviour actually lives — mostly integration tests against real stores, because that is where these failures are. Coverage rises as a side effect, and the tests that result are worth maintaining because they assert outcomes rather than calls.

Then use the coverage report diagnostically rather than as a target: look at *what* is uncovered, not how much. An uncovered error branch in the outbox relay is a real gap. Uncovered lines in a generated module are not, and the honest move is to exclude them explicitly with a reason rather than write a test to pad the number.

I would also spot-check that the suite can fail — break something deliberately and confirm the relevant test goes red. A suite that only ever passes confirms whatever you already expected, and that check costs a minute.

**On Xray.** The risk with any test-management tool over an automated suite is two sources of truth: a manually-maintained test case in the tool and an automated test in the repository, drifting apart until nobody knows which describes the system. My position is that the automated test is the truth, and the tool holds traceability — which requirement or ticket a test covers, and the execution result.

Practically that means the automated run publishes results into the tool rather than someone updating statuses, tests carry the issue key as a marker or annotation so the link is in the code and moves with it, and manual test cases exist only for things genuinely not automatable. Where the client's process expects manual test-case authoring for work that is automated, that is a conversation to have openly rather than a duplicate to maintain quietly — and it is the sort of process question where I would ask before deciding unilaterally, since the tooling convention is theirs to own.

</details>

---

### Q2. Integration tests run against real PostgreSQL, MongoDB and Redis in Docker Compose rather than mocks. What specifically does that catch?

**Brief answer**
Everything that is a property of the database rather than of the code: constraint enforcement, query plans, transaction and isolation behaviour, driver type handling, and the projection pipeline end to end. A mocked test returns what you told it to, so it passes with the exact bugs that reach production.

<details>
<summary><strong>Detailed answer</strong></summary>

The examples from this system are concrete, and each is something a mock cannot see.

**Constraints.** `UNIQUE (retail_group_id, idempotency_key)` on `connection_request` and `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge` are the actual guarantees against duplicate threads and duplicate charges. The design puts them in the schema deliberately rather than in retry logic. A mocked repository asserts that the code *tried* to insert; only a real database asserts that a concurrent double insert fails.

**Query plans.** The whole search design rests on the planner using `idx_plf_browse` and combining the GIN indexes sensibly, and the design flags that as unverified for good reason. A test asserting the plan contains no sequential scan on `product_listing_facets` needs a real PostgreSQL at the pinned version with realistically distributed data. This is the single most valuable integration test in the system, because its failure mode in production is a latency cliff rather than an error.

**Transactions and isolation.** The outbox pattern's whole correctness argument is that the state change and the `outbox_event` row commit atomically. That is a transaction property. Similarly, whether two concurrent projections of the same product interleave safely depends on real locking behaviour.

**Driver and type behaviour.** `text[]` containment, `jsonb_path_ops` semantics, `CITEXT` comparison, timezone handling on `timestamptz`, Mongo's document limits and time-to-live index behaviour — all of these are where a mock's simplified model diverges from reality quietly.

**The pipeline end to end.** Publish, outbox, project, invalidate — the sequence that makes a listing searchable. Testing it with real stores is the only way to catch an ordering bug between the Mongo write and the PostgreSQL commit.

The cost is honest: integration tests are slower, need containers in CI, and demand disciplined isolation between tests so they do not interfere. That cost is a large share of the pipeline's runtime. I would still pay it, because the alternative is a fast suite that is green while the system is broken — and mocks are most misleading precisely where the system is most subtle.

</details>

---

### Q2. How do you test a control whose failure is silent — the tenant filter, the projection, the audit write, an alert rule?

**Brief answer**
Test the negative explicitly and prove the test can fail. For each control, construct the state where the control is the only thing preventing a bad outcome, assert the outcome does not happen, then deliberately break the control and confirm the test goes red.

<details>
<summary><strong>Detailed answer</strong></summary>

Silent controls are the hardest thing in a test suite because their success looks identical to their absence. Nothing errors when the tenant filter stops applying; you just get more rows. Nothing errors when the audit write is dropped; the table is just emptier.

**The tenant filter.** Seed two organisations with data, authenticate as one, and assert that every org-owned repository method returns only its own rows and empty for the other's identifiers. Parameterise it over the methods rather than hand-writing each, so a new repository method added next year is covered by construction — the gap is always the method someone forgot. And run a variant with the cache warm, because a cold-cache-only test misses the cross-tenant cache key bug entirely.

**The projection.** Publish a listing, wait for the projection, and assert the row in `product_listing_facets` matches the source document field by field — not merely that a row exists. Then redeliver the same event and assert the row is unchanged, and deliver an older `source_revision_id` and assert it does not roll back. Those three are the actual contract.

**The audit write.** Perform an audited action and assert the `audit_event` row exists with the right actor, action and object. Then assert the application role cannot update or delete it, which is a grant test — and grant tests must assert the specific permission error, because a test expecting any failure also passes when the table does not exist.

**Alert rules.** These are the most commonly untested and the ones that matter at 3am. An alert rule is code, and it can be wrong in both directions: a threshold that never fires, or a query that fires constantly and gets muted. Since the rules are Terraform-managed, they can be tested by feeding synthetic metric data at known values and asserting the rule evaluates true above the threshold and false below.

The discipline underneath all of these: pair a known-fail with the known-pass. If you have not seen the test go red, you do not know it can. And distinguish three outcomes rather than two — pass, fail, and could-not-run — because a test that errored during setup folds silently into whichever branch was written first, and that branch is always the one confirming what you already believed.

</details>

---

### Q2. The client welcomes AI tooling but the leads do not accept purely AI-generated code and expect you to fully understand your own work. How do you work that way?

**Brief answer**
Use it where it is genuinely good — boilerplate, test scaffolding, unfamiliar syntax, a first draft to react to — and treat everything it produces as a suggestion from someone with no context on the codebase. The submitting engineer owns every line, which means being able to defend each decision in review without qualification.

<details>
<summary><strong>Detailed answer</strong></summary>

The client's position is coherent and I would work the same way regardless of policy. The generated code is frequently plausible and locally wrong: it invents an interface that does not exist, it duplicates a helper already in the repository, it uses a pattern from a different framework version, and — the one that matters most here — it produces a test that executes code without asserting anything, which raises coverage and verifies nothing. That last failure is directly at odds with a 90% coverage gate, because it makes the number look right while the suite gets weaker.

Where it earns its place: scaffolding a set of Pydantic models from a schema, generating the repetitive half of a test suite once the first test establishes the shape, drafting a migration I will then rewrite for the expand/contract sequence, explaining an unfamiliar library, and producing a first draft of documentation I will restructure. In each case the value is in the typing, not the thinking.

Where I do not use it without heavy scrutiny: authorization logic, migrations against large tables, anything touching the projection or the outbox, and query construction where the plan matters. Those are the places where plausible-looking wrong code is most dangerous, because their failures are silent — and the code review will not catch a subtly wrong tenant filter any more reliably than it would catch a hand-written one.

The self-review discipline is the substance of the client's requirement, and it is a habit rather than a policy. Before opening a merge request I read my own diff as a reviewer: does every line have a reason, is there anything I would have to look up to explain, does it duplicate something already in the repository, does the test actually assert the behaviour rather than the implementation. If I cannot explain why a line is there, it does not go in — that rule applies equally to generated code and to code I wrote at the end of a long day.

And I would not hide the use of the tool. A reviewer's time is better spent if they know which parts were drafted quickly and which were reasoned through. The standard I hold is that submitted code is code I wrote, regardless of what typed it.

</details>

---

### Q2. Migrations are expand/contract and run before deploy; `catalog-service` deploys by canary and the rest roll. Walk me through a bad deploy and the rollback.

**Brief answer**
Rollback is redeploying the previous image digest, and it is safe only because the schema is compatible with both versions during the window — that is what expand/contract buys. The canary should catch a bad `catalog-service` release before most traffic sees it; the failure that expand/contract does not cover is a bad data change, which no rollback undoes.

<details>
<summary><strong>Detailed answer</strong></summary>

Take the sequence. The pipeline lints, runs unit, integration and functional tests, builds digest-pinned images, scans them, runs `alembic upgrade head` — expand-only, so nullable columns, new tables and indexes created concurrently — deploys to staging, smoke-tests, then deploys production with canary for `catalog-service` and rolling elsewhere. Any contract migration dropping a column is a separate merge request at least one release later.

**A bad `catalog-service` release.** Roughly 10% of traffic goes to the canary deployment, held 15 minutes against its error rate and 95th-percentile latency before the weight advances. A regression — a broken query plan, a serialisation error, a wrong result set — shows up as elevated errors or latency on the canary while 90% of users are unaffected. The response is to set the weight to zero, which is faster than any redeploy, and then investigate. The reason `catalog-service` gets canary and the others roll is that it takes the traffic and carries the risky query plans, so it is where a gradual exposure buys the most.

**A bad release elsewhere**, caught after rolling out. Rollback is redeploying the previous image digest. That is safe by construction because the schema was expanded, not changed: the old image can still run against it, since nothing it depends on was removed and nothing new is mandatory. This is the entire reason for expand/contract — without it, a rollback means either running the old code against an incompatible schema or reversing a migration under pressure, and reversing migrations against real data during an incident is how a bad deploy becomes a long outage.

**The failure this does not cover** is worth naming, because it is the one people assume is covered. If the bad release *wrote wrong data* — a projection that mangled facets, a job that set the wrong status on a batch of rows — rolling back the code stops the bleeding and repairs nothing. Recovery is a data fix: re-project from the authoritative sources, which the reconciliation job can do here, or restore from point-in-time backup for anything not rebuildable. That is why the projection being rebuildable from Mongo and PostgreSQL is a resilience property and not just an architectural nicety.

Blue-green was rejected for a specific reason worth repeating: it doubles the pod footprint and, since both colours share `postgres-core`, delivers no database-level isolation — which is the only part of the risk that expand/contract does not already handle.

</details>

---

### Q3. The pipeline takes twenty to thirty minutes. How do you work with that, and how would you shorten it without weakening the gates?

**Brief answer**
Work with it by batching verification locally so the pipeline is a confirmation rather than a discovery mechanism, and by planning the day around it instead of watching it. Shorten it by parallelising stages, running the expensive slices selectively, and caching properly — never by removing a gate.

<details>
<summary><strong>Detailed answer</strong></summary>

**Working with it.** A slow pipeline punishes using CI as a debugging loop, so the answer is to make failures happen locally. Pre-commit hooks catch the lint and format gates in seconds. The unit suite runs locally in seconds. The integration suite runs locally against the same Compose topology CI uses, which is the highest-value habit — a pipeline failure at minute eighteen on something reproducible in ninety seconds locally is entirely self-inflicted. Then push once, with the expectation that it passes.

The other half is not sitting and watching. Push and move to the next task, review someone else's merge request, write the description. Twenty minutes is expensive if it is dead time and cheap if it is not. What I would avoid is the anti-pattern of pushing speculative fixes to see what happens, which turns one twenty-minute wait into five.

**Shortening it, without weakening anything.** In rough order of return:

*Parallelise.* Lint, type check and unit tests have no dependency on each other and can run concurrently. Integration tests can shard across several runners by module. The stages here are drawn sequentially, and much of that is ordering-by-convention rather than by dependency.

*Cache properly.* Dependency installation and container image layers are frequently a large share of the time. A warm dependency cache keyed on the lock file and a build cache for image layers often removes several minutes with no behavioural change.

*Right-size the container startup.* Bringing up PostgreSQL, MongoDB and Redis per job is fixed overhead paid repeatedly; sharing them across a job's tests with proper isolation between tests, rather than restarting per test, is a common large win.

*Run expensive slices selectively — carefully.* Full integration on merge requests, plus the slowest end-to-end slice on the default branch. This is the one that shades into weakening the gate, so the rule is that anything skipped on a merge request must run before production, not merely somewhere eventually.

What I would not do is drop the integration tests against real stores or relax the scan. Those catch the failures this system actually has. A fifteen-minute pipeline that misses a bad query plan is worse than a twenty-five-minute one that catches it — and honestly, a slow pipeline is a mild tax compared to a silent projection bug reaching production.

</details>

---

### Q3. The target environment runs GitOps with ArgoCD on OpenShift and Prometheus for metrics. This system uses GitLab CI pushing to AKS with Azure Monitor. What transfers, and what would you have to learn?

**Brief answer**
The Kubernetes model, the deployment strategies, the migration discipline and the observability concepts all transfer directly. What is new is the pull-based reconciliation model — where the cluster converges on Git rather than a pipeline pushing to it — plus OpenShift's stricter defaults and [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/ "Prometheus Query Language — Queries and aggregates time series metrics collected by Prometheus") as a query language.

<details>
<summary><strong>Detailed answer</strong></summary>

Being clear about the boundary: I have run GitLab CI deploying to a managed Kubernetes service with cloud-native monitoring. I have not operated [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") or OpenShift in production, and Prometheus I know as a model more than as a daily tool.

**What transfers.** Everything about Kubernetes itself — deployments, probes, resource limits, autoscaling on custom metrics, `preStop` draining for workers, NetworkPolicy. The deployment strategies transfer: canary for the risky high-traffic service, rolling elsewhere, blue-green rejected for specific reasons. The migration discipline transfers entirely and is arguably more important under GitOps, since expand/contract is what makes a declarative rollback safe. And the observability concepts — service level indicators and objectives, error-budget burn alerting, the distinction between an alert that pages and one that raises a ticket — are tool-independent.

**What is genuinely different.**

*Pull versus push.* In this design, the pipeline holds cluster credentials and pushes a deployment. Under GitOps, a controller inside the cluster watches a repository and reconciles toward it, so no pipeline job holds cluster credentials — a real security improvement — and the repository is the declared state rather than a record of what someone ran. Drift is detected and corrected automatically, which also means a manual `kubectl` change is silently reverted, and that surprises people once.

*Migration ordering becomes the interesting problem.* With a push pipeline, `alembic upgrade head` is a stage before deploy and the ordering is explicit. Under ArgoCD it becomes a sync hook — a PreSync job — and getting that ordering and its failure behaviour right is the part I would want to study carefully, because a migration that runs after the new pods start is a different and much worse system.

*OpenShift's defaults are stricter* than a stock Kubernetes distribution — security context constraints, no running as root, its own build and route abstractions. Most of that is good hygiene the images should satisfy anyway, and it tends to surface as things that worked elsewhere failing until the manifests are corrected.

*Prometheus is a pull model with its own query language.* The concepts map onto what is here — the autoscaler already scales on a custom queue-depth metric, which is precisely a Prometheus-shaped signal — but PromQL, recording rules and Alertmanager routing are craft I would need to build rather than claim.

My honest expectation is that the architecture and the disciplines carry over intact and the first few weeks would be spent on tooling fluency, which is the cheaper half to acquire.

</details>

---

### Q3. Of the alerts in this design, which would you page a human for at three in the morning, and which would you not?

**Brief answer**
Page for things that are both urgent and actionable: catalog error-budget burn, connection-create failures, a stalled outbox, and a dead indexer. Ticket everything whose impact accumulates over hours rather than minutes — dead letters, replica lag, expiring certificates, per-job import failures.

<details>
<summary><strong>Detailed answer</strong></summary>

The test I apply is whether a human woken now can do something that a human at nine in the morning cannot, and whether the damage between now and then justifies the cost. Pages that fail that test train people to ignore pages, which is how the real one gets missed.

**Page.**

*Catalog read error-budget burn at 14.4× over an hour.* Browse is the platform's shop window and this rate consumes a month's budget in about two days. It is a burn-rate alert rather than a threshold, which is right — it fires on trajectory rather than on a single bad minute, so it is both sensitive and resistant to noise.

*Connection create 5xx above 1% over five minutes.* This is the platform's commercial event. A retailer who cannot open a conversation may not come back, and there is no queue absorbing the failure.

*Outbox unpublished age above 300 seconds.* Everything asynchronous has stopped: nothing is projected, nothing is notified, nothing is billed. It is silent from the user's side until it is very visible, and the fix is usually immediate once someone looks.

*Indexer lag 95th percentile above 60 seconds for ten minutes.* The design calls this a silent failure, and it is right: new listings never become searchable and nothing else surfaces it. A vendor who published this morning and cannot be found all day is a support escalation and a trust problem.

**Ticket.**

*Dead-letter count above zero.* Real and needs handling, but one message quarantined is not worth a night. The exception is a rate — hundreds arriving means a systemic handler failure, and that should escalate.

*Replica lag above 30 seconds.* The application already fails back to the primary automatically, so the control has worked. It needs investigating, not intervening.

*Per-job import failures above 5% of rows.* The vendor already sees an error digest, so the failure is legible to the affected party. It is a data-quality problem for the morning.

*Certificate or secret expiring in 30 days.* Thirty days of warning is the opposite of urgent — though if it were still firing at three days I would want that escalated, because an alert nobody acted on for four weeks is a process failure the alert should reflect.

The other thing I would insist on is that every paging alert names a runbook and an owner. An alert that wakes someone with no idea what to do is a worse outcome than no alert, because it costs the sleep and buys nothing.

</details>

---

### Q3. Coverage is at 90%, every gate is green, and a defect reaches production anyway. What does that tell you, and what do you change?

**Brief answer**
That the gates were measuring what is easy to measure rather than what actually fails. The response is to trace the specific defect back to the check that should have caught it and add that one, not to raise thresholds or add gates generally.

<details>
<summary><strong>Detailed answer</strong></summary>

Green gates and a production defect is not a paradox — it is the normal state of any system, because gates verify the failures someone anticipated. The useful question is narrow: what would have caught *this* one.

The categories that routinely pass every gate in a system shaped like this:

**Silent data-correctness failures.** A projection dropping a facet, a tenant filter no longer applying, an event consumer skipping a case. Nothing throws; the data is just wrong. Unit tests pass because the logic is fine in isolation, and coverage counts the executed lines. What catches these is negative assertions against real stores — and a test that has never been seen to fail is not evidence.

**Plan and performance regressions.** A query that returns the right rows the wrong way. Correctness tests are green, latency triples. Only a plan assertion catches it, and only against realistic data.

**Configuration and infrastructure.** A NetworkPolicy, an alert rule, a role assignment, an autoscaler threshold. Frequently outside the test suite entirely, and this is where "green pipeline, broken production" most often originates.

**Integration with reality.** Provider behaviour, message ordering under real concurrency, a broker's actual delivery semantics — the design already flags Celery-on-Redis durability as needing a kill test rather than an assumption.

**Requirements.** The code does exactly what was specified and the specification was wrong. No gate can catch this, and it is worth saying so rather than pretending more testing would have.

What I would change is narrow and specific: write the test that would have caught this defect, at the cheapest level that reliably catches it, and confirm it fails against the unfixed code. Then ask whether the defect belongs to a class — if it is the third silent projection bug, the gap is systemic and deserves a general mechanism such as a reconciliation check comparing projected rows against sources.

What I would not do is raise the coverage target. Ninety per cent did not catch it and ninety-five will not either; the number was never measuring the right thing. Adding gates in response to an incident is how pipelines reach forty minutes while catching no more than they did before.

</details>

---

### Q3. Telemetry here goes to Azure Monitor and Application Insights. The target environment runs the ELK stack with Kibana and Elastic APM. What transfers, and what would you have to build differently?

**Brief answer**
The instrumentation transfers almost entirely, because everything is emitted through OpenTelemetry rather than a vendor software development kit — that was the point of choosing it. What changes is the query language, the retention and index management you now own, and that log volume becomes a cost you have to manage rather than a bill you receive.

<details>
<summary><strong>Detailed answer</strong></summary>

**What transfers.** Metrics, logs and traces here are all emitted in-process through one OpenTelemetry software development kit and exported to Azure Monitor, so the application code is not coupled to the backend — swapping the exporter is configuration. That decision is worth more than it looks: a codebase instrumented with a vendor's proprietary client is genuinely expensive to move, and one instrumented with OpenTelemetry is not.

The structural discipline transfers wholesale, and it is the part that determines whether an observability stack is usable. Structured JSON logs to stdout, every line carrying `request_id`, `trace_id`, `service`, `actor_side`, `org_id`, `route` and `status`. The rule that `org_id` is always present so a support query can be scoped to one tenant without a full-text sweep — that matters more in Elasticsearch than in a managed service, because it is the difference between a term query and a scan. And the standing rule that no log line contains a message body, a token or a client secret, which in a self-hosted stack matters more still, since the index is now data you are storing and retaining yourself.

**What is different.**

*Query language and mental model.* Kusto and Kibana's query languages are different tools for the same job; that is a week of fluency, not a conceptual gap. Elastic Application Performance Monitoring gives service maps and transaction breakdowns comparable to Application Insights, and the trace model is the same one.

*You own the cluster.* Index lifecycle management, shard sizing, retention tiers and hot-warm-cold architecture are now your responsibility. That is real operational work with a real failure mode — an unmanaged log index fills disks and takes the observability stack down at exactly the moment you need it, which is a well-known way for an incident to get much worse.

*Volume becomes a design constraint.* With a managed service, log volume is a bill. Self-hosted, it is capacity. That pushes sampling decisions earlier — here it is 100% of errors and write-path requests and 5% of catalog reads, which is already the right shape and would carry over unchanged.

The one thing I would verify early rather than assume, in either stack, is trace continuity across asynchronous boundaries. The design flags this explicitly: propagation through message properties depends on the instrumentation actually injecting and extracting the trace context, and it has historically been partly manual. That claim needs an integration test asserting one trace identifier spans a publish-to-notify flow — before an incident, not during one.

</details>
