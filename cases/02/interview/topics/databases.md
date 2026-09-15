# Databases and Data Access

> 22 questions on relational versus document storage, transactions, isolation and locking, index design and query plans, pagination, the ORM boundary, and migrations and backfills. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except DB-03, DB-12, DB-13, DB-14, DB-15, DB-19, DB-20 and DB-22, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — DB-01, DB-03, DB-05, DB-08, DB-09, DB-11, DB-12, DB-13, DB-14, DB-15, DB-17, DB-19, DB-20, DB-21
- **retail-software-marketplace** — DB-01, DB-02, DB-03, DB-05, DB-08, DB-09, DB-10, DB-11, DB-12, DB-13, DB-14, DB-15, DB-17, DB-20, DB-21
- **general** — DB-04, DB-06, DB-07, DB-16, DB-18, DB-22

---

## 1. Data modelling and polyglot persistence

---

### DB-01. How do you decide what belongs in a relational schema and what belongs in a document — and what does that split cost you once both stores hold part of the same entity?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Relational is for anything with referential integrity, a fixed shape, or a role in a transaction. A document is for anything whose shape the platform cannot fix in advance without blocking the next use case. The split costs you four things: a projection pipeline, a lag budget, a reconciliation job, and a second place to get authorization wrong. You should only pay that cost when a single store genuinely cannot serve both halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I actually apply** is not "structured versus unstructured". It is three questions. First, does this data take part in a foreign key or in a transaction that must be atomic? Second, do I need to query it by predicates I can list today? Third, would adding a new variant require a migration? If the answers are yes, yes, no, it is relational. If they are no, no, yes, it is a document.

In the marketplace, that test produced a deliberate split down the middle of one entity, which is the interesting case. A listing has a **spine**: identity, vendor ownership, category, status, publication timestamp and price tiers. The spine has referential integrity to vendors, and it takes part in shortlists and connections. It is also what search and the admin workspace query. So the spine is relational, in `postgres-core`. A listing also has a **body**: everything specific to being a Point of Sale ([POS](https://en.wikipedia.org/wiki/Point_of_sale "The system and moment at which a retail transaction is completed")) system, an inventory tool or a loyalty engine. The platform cannot fix a schema for the body without blocking whichever category ships next. So the body is a document in `mongo-catalog`. It is validated at write time against a per-category `facet_schemas` document, not against a table definition. The validation matters, because "no fixed column set" must not turn into "no contract". [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") checks the submitted attributes against the category schema, and that check is what keeps the body governable. Adding a category becomes a document insert plus a facet mapping, not a migration.

The cancer platform drew the same line differently, because the data was different. Education pages vary by cancer type, treatment line and locale, and they are versioned with a review state. So they live in `mongo-content`. The clinical record is relational, because a prescription has referential integrity and an authorization boundary. Symptom scores went to `jsonb` inside [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), not to Mongo. The symptom set differs by cancer type and changes with the protocol. But it is read in the same query as the row it belongs to. So a Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) on the document was the right answer, not a second store.

**What the split costs, stated honestly, because this is the half of the question people skip.**

- **A projection.** Anything a user filters on has to be queryable relationally. So a worker copies the facetable subset of the Mongo document into `product_listing_facets` in Postgres. That table is a denormalised read model. Only `indexer-worker` writes it, and only `catalog-service` reads it.
- **A lag, and therefore a lag budget and an alert.** The projection trails the document by seconds, with p95 under 5 s. When the indexer dies, listings silently stop becoming searchable. That failure has no error to raise, so it needs its own metric.
- **A reconciliation job.** A nightly sweep re-projects any product whose `projected_at` is older than its `updated_at` by more than five minutes. It also deletes revision documents that are older than 24 hours, that no product row points at, and that have no successor revision. Without that job, one lost event is permanent.
- **A write-ordering rule.** Mongo first, Postgres commit second. An orphaned revision document that nothing points at is invisible garbage. A committed pointer to a document that does not exist is a broken listing.
- **A second authorization surface.** Every store that can answer a query can become the path around your access control. That is why the search index in the cancer platform carries mandatory scope fields on every document.

**And the alternative I would not dismiss.** Everything in PostgreSQL, with `jsonb` for the metadata, is genuinely defensible at this size. I would say so, rather than pretend the polyglot choice was obvious. That alternative trades the projection lag for heavier write amplification on the same table that serves search. The reason to take the split here is the vendor-facing authoring surface: per-category schema validation, immutable document revisions and staged imports. That surface is Mongo's native shape. If that surface did not exist, one store would be the better answer.

</details>


---

### DB-02. While building the Retail Software Aggregation Platform, you used MongoDB for product metadata to handle variable schemas for POS and inventory tools; how did you manage the integration and query performance when the system needed to join this unstructured metadata with relational vendor data stored in PostgreSQL?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
There is no join. Designing the system so there never has to be one is the main point. The hot query runs against a single denormalised PostgreSQL table. A worker projects the facetable subset of the Mongo document into that table. The document is fetched afterwards, in one bulk `$in` by primary key, and only for the products already on the page.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism, in the order a request hits it.**

1. **One relation for the search query.** `product_listing_facets` carries `vendor_id`, `category_slug`, `status`, `published_at`, `country_coverage`, `deployment_model`, `price_from_minor`, `integrations`, a `facets jsonb` column and a `search_vector`. `vendor_id`, `status` and `published_at` are copied from `product` *deliberately*. That way the highest-traffic query in the system touches exactly one relation, and it never joins, even within PostgreSQL. Only `indexer-worker` writes the table, and only `catalog-service` reads it. That rule is what keeps a denormalised table from becoming a correctness problem.
2. **Indexes per access pattern, not per column.** `GIN (search_vector)` serves free text. `GIN (facets jsonb_path_ops)` serves containment predicates on category-specific attributes. `GIN` on the `country_coverage` and `integrations` arrays serves containment. Two partial B-trees serve the sort orders: `(category_slug, published_at DESC, product_id) WHERE status = 'published'` for the default browse order, and `(category_slug, price_from_minor)` for the price sort. The partial predicate keeps roughly 15,000 unpublished and archived rows out of the hot index entirely. It also removes the status filter from every plan.
3. **Hydration by primary key, in bulk, after the page is decided.** `product_metadata._id` **is** `product.id`, so the two stores join without a mapping table. The page returns about thirty product ids. [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") serves the ones it has as `cat:listing:{id}:v{rev}`. The misses go to Mongo as a single `find({_id: {$in: [...]}})`. It is never per item. A loop of thirty round trips is how this design would have failed.

**The performance consequence, broken into parts.** The uncached path budgets about 45 ms for the keyset query on the projection, about 25 ms for the bulk Mongo hydration and about 14 ms for serialisation. It lands near 107 ms server-side, against a p95 target of 200 ms. At the modelled 85% hit ratio on the search-page cache, the p95 falls on that uncached path. That leaves roughly 90 ms of headroom for a cold buffer cache or an autoscaling cold start.

**Where it actually gets hard, and what I would say honestly.** The main performance risk is not the cross-store fetch. It is the planner on the projection table. A comparison workflow produces queries with many optional predicates. The failure mode is a bitmap `OR` across several GIN indexes on an unselective combination, which degrades toward a sequential scan as the table grows. Selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor for high-cardinality arrays. So the claim that those indexes combine into a bitmap `AND` is exactly the kind of thing I would confirm before quoting a latency figure. I would confirm it with `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table on the pinned minor version. If the plan is wrong, the fix is a composite covering index per high-traffic category, not a bigger instance.

Two product constraints buy guarantees that the planner cannot give. First, the [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") refuses an uncategorised query that carries more than two facet predicates, and that guarantees a viable leading index. Second, the response returns `total_estimate` capped at 1,000 instead of an exact count. The reason is that an exact count over a filtered GIN scan costs as much as the page itself. In both cases, a small product decision removes a whole class of performance problem. I would rather argue for one of those decisions than tune around the consequence.

**The cost of the design.** The projection trails by seconds, so a vendor who just clicked publish would see stale data. The design routes around that lag instead of shrinking it. The vendor workspace reads `product` from the Postgres primary and the metadata document from Mongo directly. It never reads the projection, and it never reads the cache. So vendors get read-your-writes, and retailers get the fast, slightly stale read model.

</details>


---

### DB-03. When is it right to let two stores disagree, and how do you keep that from being a bug?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
It is right whenever a derived store exists at all, which is most systems. The discipline is that the divergence is bounded, stated as a number, measured in production, and reconciled. A staleness budget is a design decision. Unmeasured staleness is a defect that only looks like a budget.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where disagreement is correct.** A search index, a projection table, a cache, a read replica. Each one exists because deriving the answer at read time is too expensive, and each one is necessarily behind. If you try to make them synchronous, you put the derivation back on the write path. That removes the reason they exist.

**What turns that from acceptable into engineered.**

- **State the budget as a number built from its parts.** On the cancer platform, search freshness is expressed as the sum of the relay interval, the bulk flush and the index refresh. That is under eight seconds at the median and under fifteen at the high percentile. Writing it as a sum, not as a single figure, is what makes it actionable. The sum shows immediately that tightening one component alone cannot bring the total below the sum of the other two.
- **Measure the actual lag, not the configured intervals.** The metric is the time from when the source event happened to the derived write. Configuration tells you what should happen. The metric tells you what does happen.
- **Alert on it, and page.** This is the important one. A consumer that stops is invisible to every other signal. Requests stay fast, errors stay at zero, and the data quietly stops updating. Index freshness and projection lag are the only things that show it.
- **Reconcile.** A periodic sweep re-derives anything whose derived timestamp is older than its source update by more than the budget. That sweep is the backstop for a lost event. It is the price of choosing incremental maintenance over recomputing from the source of truth each time.
- **Keep it rebuildable.** The derived store holds nothing that cannot be derived from the owner. So the worst case is a rebuild, not a data loss. And the rebuild is rehearsed, because a mitigation nobody has executed is an assumption.

**Where disagreement is not acceptable.** Anything the user is told is done. A patient's check-in must be durable before the handset says recorded. A connection request must not create two threads or two charges. That guarantee comes from a unique constraint in the owning store, not from a cache or a queue. The line I draw is this: a derived view that is behind is fine, and it must be visible. A fact that is uncertain is not fine.

**And the consequence for the user has to be designed too.** A vendor who publishes and does not immediately see their listing in search will file a bug. Either the interface shows the write, not the index, in that user's own view, or the delay is communicated. An unexplained inconsistency is a support cost, even when it is technically correct.

</details>

---

## 2. Transactions, locking and concurrency

---

### DB-04. Tell me about transactions: the isolation levels, what each one actually prevents, and where a transaction stops being enough.

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
Read Committed prevents dirty reads. Repeatable Read also prevents non-repeatable reads, and in PostgreSQL it prevents phantoms too. Serializable prevents the remaining write-skew anomalies by aborting one of the conflicting transactions. A transaction stops being enough the moment the operation crosses a boundary that the database does not control. That boundary can be a second store, a broker, an external provider, or a user's think-time.

<details>
<summary><strong>Detailed answer</strong></summary>

**The levels and the anomalies, concretely.**

- **Read Uncommitted.** The standard allows dirty reads at this level. PostgreSQL does not implement it as a separate level. It behaves as Read Committed.
- **Read Committed** (the PostgreSQL default). Each *statement* sees a snapshot taken when that statement began. There are no dirty reads. Two reads in the same transaction can return different values. A `SELECT` followed by an `UPDATE` can act on data that changed in between. The subtle case is this one. Suppose an `UPDATE` under Read Committed finds a row locked. After the lock is released, the `UPDATE` re-evaluates its `WHERE` clause against the new version of the row. That can silently change which rows are affected.
- **Repeatable Read.** There is one snapshot for the whole transaction. There are no dirty reads and no non-repeatable reads. In PostgreSQL's Multi-Version Concurrency Control ([MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row")) implementation, there are no phantoms either, which is stronger than the standard requires. The price is `could not serialize access due to concurrent update`, so the application must be prepared to retry.
- **Serializable.** This is snapshot isolation plus predicate-dependency tracking, and that tracking catches write skew. In write skew, two transactions each read what the other is about to change, and both commit a state that neither would have allowed. The canonical case is two people booking the last slot after both checked availability. The cost is more serialization failures, and therefore a mandatory retry loop.

**The practical position I take.** I use Read Committed for almost everything. Correctness is carried by constraints and explicit locking, not by the isolation level. The reason is that a constraint is declarative and always on, whereas an isolation level is a setting someone can change. I use Serializable where the invariant genuinely spans rows that no single unique constraint can express. And then I use it with a retry loop, because a Serializable transaction that cannot retry is a transaction that fails under load.

**Where a transaction stops being enough: four boundaries.**

1. **A second datastore.** No transaction spans PostgreSQL and [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), or PostgreSQL and a message broker. This is why both my recent systems use a transactional outbox. The event row commits with the state change. Publication happens afterwards, with at-least-once delivery and idempotent consumers. A distributed transaction here would buy a coordinator, a new failure mode and worse latency, to avoid writing an idempotent handler.
2. **Any external side effect.** Sending an email, charging a card, calling a provider. The database can roll back, but the provider cannot. The pattern is a state machine in the database, with an attempt row per try. One reminder has many `reminder_delivery` rows, and each row has a channel, a provider message id and a terminal state. So "was it delivered" is a query, not a search through logs. And a retry is safe, because the attempt is recorded before it is made.
3. **Anything spanning user think-time.** Holding a transaction open across a user's decision is how you get a frozen table. The answer is optimistic concurrency, which means a version or revision column checked on write. It is not a long-lived lock.
4. **Long-running work.** A transaction held open for a large batch holds back the oldest snapshot. That blocks vacuum and lets dead tuples accumulate across the whole database. So batch work gets chunked into many short transactions, which is also what makes it resumable.

**And the thing I would add without being asked:** the strongest correctness tools in a relational database are not isolation levels at all. They are constraints. `UNIQUE (retail_group_id, idempotency_key)` is what finally prevents a duplicate connection thread and a duplicate charge, not the retry logic in front of it. A partial unique index on `(connection_request_id)` `WHERE kind = 'connection'` is what makes "a connection bills at most once" a property of the schema, not something that depends on everyone remembering. Isolation levels manage contention. Constraints decide which states are possible.

</details>


---

### DB-05. Explain optimistic vs pessimistic locking.

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Pessimistic locking takes the lock before doing the work, and it makes conflicting writers wait. Optimistic locking does the work first. Then, at commit, it checks whether anyone else changed the row, and it fails the loser. The choice follows contention and who can retry. Low contention with a client that can redo the work favours optimistic locking. High contention, or a client that cannot resolve a conflict, favours pessimistic locking.

<details>
<summary><strong>Detailed answer</strong></summary>

**Pessimistic.** `SELECT … FOR UPDATE` takes a row lock for the rest of the transaction, and other writers block. It is the right answer when three things are true. A conflict is likely, the work between read and write is short, and the correct resolution of a conflict is "wait your turn". The costs are real. Waiting writers hold connections. Lock waits can grow into a long queue of waiting transactions under load. And any lock held across a network call or a user's think-time is a design defect, not a tuning problem.

**Optimistic.** The row carries a version. That can be an explicit `version` column, an `updated_at`, or PostgreSQL's system `xmin`. The write is `UPDATE … WHERE id = ? AND version = ?`. If the affected-row count is zero, somebody else got there first. No locks are held while the user thinks, so it scales well when conflicts are rare. It degrades badly when conflicts are not rare: under heavy contention, you spend all your work on retries. Over HTTP this is exactly `ETag` plus `If-Match` returning `412`. It is the same mechanism, exposed in the protocol, so that the client can decide what to do.

**Where each one is used in these systems. This is the more interesting half of the question.**

- **Optimistic, expressed as a monotonic guard, not a version check.** `indexer-worker` upserts `product_listing_facets` keyed on `product_id`, and it **ignores an event whose `source_revision_id` is older than the row's current value**. That is optimistic concurrency for a projection. Redelivery is a no-op, and out-of-order delivery cannot roll a listing backwards. A plain version check would reject the stale write with an error. Here the correct action is to drop the stale write silently. It is the same idea, with a resolution that fits the domain.
- **Pessimistic, chosen deliberately over optimistic.** [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") updates from the hospital directory are serialised per directory object on a Redis lock, `lock:scim:{entra_object_id}`. The reason is not contention. The reason is that **the client will not resolve a version conflict for you**. Entra ID sends a `PATCH` and expects it to be applied. Returning a `412` and hoping it re-reads and re-applies is not a contract that provider honours. When the other party cannot take part in the retry, optimistic locking is not available to you. That is the cleanest test I know for choosing between the two.
- **The third option people forget: `FOR UPDATE SKIP LOCKED`.** The reminder sweep claims due rows with `SELECT … FOR UPDATE SKIP LOCKED`. That is pessimistic locking with the waiting removed. A worker takes what is free and leaves contended rows to whoever holds them. That is what lets the worker pool scale horizontally without double-dispatch and without a queue of blocked workers. It is the right primitive for work-claiming specifically.
- **The fourth option: neither.** The best concurrency control is often a constraint. `UNIQUE (patient_id, recorded_for)` with `ON CONFLICT DO UPDATE`, or a partial unique index on `(connection_request_id)` `WHERE kind = 'connection'`, resolves the race in the database, with no lock and no retry loop. If the conflict has a correct deterministic resolution, express it as a constraint, not as a protocol.

**Two details worth adding.** First, deadlocks are a pessimistic-locking phenomenon. The practical defence is a consistent lock ordering plus short transactions. PostgreSQL detects deadlocks and aborts one transaction, the victim, so the application must be able to retry a deadlock failure. Second, isolation level matters. At `SERIALIZABLE`, PostgreSQL gives you optimistic behaviour for free: it aborts transactions whose interleaving was not serialisable. That is elegant, and it means every write path needs a retry loop.

</details>


---

### DB-06. A table is frozen — how do you debug the blocking transaction, and what do you put in place so it does not happen again?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Query the live lock graph to get from the victim to the actual blocker. In PostgreSQL that means `pg_stat_activity` joined to `pg_locks`, or `pg_blocking_pids()` on the waiter. Then look at what that blocker is doing. More importantly, look at whether it is doing anything at all. Prevention is mostly three settings and one discipline. The settings are statement and idle-in-transaction timeouts, and `NOWAIT` or `SKIP LOCKED` on contended claim queries. The discipline is never holding a transaction open across work that the database is not doing.

<details>
<summary><strong>Detailed answer</strong></summary>

**Getting to the blocker.** The waiter is easy to find, and it is useless on its own. What I want is the chain:

- `SELECT pid, state, wait_event_type, wait_event, query, xact_start, state_change, pg_blocking_pids(pid) FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;` gives every waiter and who is holding it up. Follow the chain to the root. The blocker is often not blocked itself, and that is what makes it the culprit.
- Then look at the root's `state`. If it is `idle in transaction`, the database is not the problem. The application opened a transaction and went off to do something else: an Application Programming Interface (API) call, a file read, a user's think-time. The lock is a side effect. That is the most common cause I have seen, and it is an application bug, not a database one.
- `pg_locks` tells you *which* lock is held. A wait on a `transactionid` lock usually means a row-level write conflict. A table-level `ACCESS EXCLUSIVE` on the relation is almost always a migration. So it is worth checking `pg_stat_activity` for an `ALTER TABLE` before assuming it is application traffic.
- `xact_start` versus `query_start` is the sign of a long transaction running many short statements. That is a different problem from one long statement.

**The migration case deserves its own note**, because it is the case that freezes a table completely, not just slows it. An `ALTER TABLE` that needs `ACCESS EXCLUSIVE` queues behind existing readers. Then every later query queues behind *it*. So one slow `SELECT` plus one `ALTER` stalls the whole table. That is why `lock_timeout` on migration sessions matters more than `statement_timeout`. It is better to fail the migration and retry than to build a queue.

**Resolution, in order.** Cancel first (`pg_cancel_backend`). Terminate only if cancelling does not work (`pg_terminate_backend`). And record what the blocker was before you kill it. This is the part people skip. If you skip it, you have lost the evidence, and you will do this again next week.

**What I put in place afterwards.**

- **`idle_in_transaction_session_timeout`** at the database or role level. This single setting turns the most common cause from an outage into an error in one connection. There is no legitimate reason for an application transaction to sit idle for minutes.
- **`statement_timeout`** per role, tuned differently for the web tier and for background jobs. A web request that has run for thirty seconds is not going to produce a useful response.
- **`lock_timeout`** on the migration path specifically, so that schema changes fail fast instead of queueing.
- **`SELECT ... FOR UPDATE SKIP LOCKED`** for any pattern that claims a row of work. In the reminder sweep, this is what lets workers scale without double-dispatch *and* without blocking each other. Two workers never contend for the same row. They simply take different ones.
- **Short transactions as a rule, enforced by the session dependency.** The session opens as late as possible and closes at the end of the request. Nothing that is not a database operation happens inside it. No Hypertext Transfer Protocol ([HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Application protocol used to request and transfer web resources")) calls inside a transaction, ever.
- **Optimistic concurrency instead of pessimistic locks**, wherever the conflict is rare. That means a revision column checked on write. In the marketplace it is `current_revision_id`, and in the projection it is an ignore-if-older comparison on `source_revision_id`.
- **Monitoring on the leading indicator**, not on the outcome: the age of the longest-running transaction, the count of sessions idle in transaction, and the lock-wait count. A dashboard that only shows query latency tells you about this after your users do.

**The honest caveat.** All of the above assumes the blocker is a transaction. If the table is "frozen" and the lock graph is empty, the problem is somewhere else. It can be connection-pool exhaustion that looks like a hang, a saturated replica, or a client-side deadlock in the application's own pool. I would check the pool's checked-out count before spending longer in `pg_locks`. Treating "no output" as "investigate the process table", not as "it is just slow", applies to the database layer as much as anywhere.

</details>


---

### DB-07. Tell me about deadlocks in a database — how they arise, how you diagnose one after the fact, and how you design them out.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
A deadlock is a cycle. Two transactions each hold a lock that the other needs. So neither can proceed, and the database breaks the tie by aborting one of them. Deadlocks come almost entirely from inconsistent lock ordering. The durable fix has two parts. Make every transaction acquire locks in the same deterministic order. And keep transactions short enough that the window barely exists.

<details>
<summary><strong>Detailed answer</strong></summary>

**How they arise.** The textbook case is two transactions that update the same two rows in opposite orders. In practice the ordering is rarely explicit. It is implied by a loop over a set that nobody sorted, by a foreign key taking a lock on a parent row, by an index update, or by an `UPDATE ... WHERE` whose row order the planner chose. These are the three shapes I have actually seen:

1. **Unordered batch updates.** Two workers process overlapping id sets, in whatever order the ids arrived. This is the common one. Sorting the batch by primary key removes it completely.
2. **Foreign-key lock escalation.** In PostgreSQL, inserting a child row takes a key-share lock on the parent. Two transactions that insert children of two parents, and also change those parents' key columns, deadlock without any statement that obviously conflicts.
3. **Upsert races.** Two concurrent `INSERT ... ON CONFLICT` statements on overlapping keys. That is the pattern any idempotent consumer uses. This one matters because it is the shape of a message-driven projection, and duplicate delivery makes it *likely*, not just theoretical.

**Diagnosing after the fact.** A deadlock is never live by the time you look, because the database has already resolved it. So the evidence is in the log. PostgreSQL logs the deadlock error itself. Setting `log_lock_waits = on` also logs the long lock waits around it. For that, `deadlock_timeout` should be set to a value that is a real threshold, not an accident. PostgreSQL's deadlock report gives both processes, the statement each one was running, and the lock each one was waiting for. That is usually enough to reconstruct the cycle.

Beyond the log line, I want the application's `trace_id` in the statement context. Then I can get from the two statements back to the two requests and see what the code paths were. Logging the statement alone tells you where the collision happened, but not what the code was trying to do. And what the code was trying to do is where the fix is. In both my recent systems, every log line carries `trace_id`. In the marketplace, every log line also carries `request_id`. Linking a deadlock report to two traces is exactly the kind of thing that join is for.

I also want the **rate**. One deadlock a week on a retryable path is noise. A rising rate is a design problem. It usually appears right after a concurrency increase: more workers, a bigger batch size, or a new consumer on the same queue.

**Designing them out.**

- **Deterministic lock ordering.** Sort every batch by the primary key before touching rows. This is one line of code, and it removes the largest single cause.
- **Short transactions, narrow scope.** Fewer locks, held for less time. Take a transaction that does a database read, an HTTP call and then a write. Its window is orders of magnitude wider than it needs to be, and the HTTP call should be outside it.
- **`SKIP LOCKED` for work claiming.** Two workers claiming reminders never contend at all, because they take different rows. Designing contention away is better than resolving it.
- **Idempotent upserts on a natural key.** Then the correct response to a serialization failure or a deadlock abort is simply to retry, with no compensating logic.
- **A bounded retry with jitter on the retryable error classes**: deadlock detected, and serialization failure. An immediate retry without jitter recreates the collision. That is the detail people miss.
- **Consider an advisory lock** where the contention is over a logical resource, not over a row. One example is serialising SCIM operations per directory object. That is what the `lock:scim:{entra_object_id}` Redis lock does in the cancer platform. It keeps concurrent directory updates for one clinician from interleaving at all.

**The trade-off worth naming.** Every one of these lowers concurrency or makes the code slightly more constrained. Sorting a batch costs nothing. Holding an advisory lock per aggregate serialises work that could, in principle, run in parallel. I would accept the serialisation for a low-frequency operation like provisioning. I would refuse it for a high-frequency operation. There, the right answer is to redesign so that the two transactions do not touch the same rows.

</details>


---

### DB-08. Give an example where two database operations MUST be atomic. When would you deliberately NOT use one large transaction?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The canonical pair that must be atomic is a state change and the outbox row that announces it. Commit them together, and "it happened but nobody heard" is no longer a state the system can reach. I deliberately refuse one large transaction for anything long, anything that crosses a network boundary, and anything bulk. The reason is that a long transaction in PostgreSQL holds back vacuum and holds locks. So every other query on the system pays its cost.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three examples where atomicity is genuinely required.**

1. **The state change and its outbox event.** `vendor-service` updates `product.current_revision_id` and inserts `outbox_event` in one PostgreSQL transaction. The relay publishes afterwards and stamps `published_at`. The alternative is to commit, then publish. That alternative has a window in which the process dies, and then the fact exists while the event does not, permanently and undetectably. This is the single most common place where people dual-write by accident, and the outbox exists for exactly this pair.
2. **Deprovisioning a clinician.** When SCIM marks a clinician inactive, the `clinician` row flips **and every open `care_relationship` for that clinician closes in the same transaction**. A partial application here is an access-control failure. The account is disabled but the relationship rows that row-level security joins through are still open, or the reverse. Either half alone is wrong. And the wrong state is a security event, not a data inconsistency.
3. **A charge and the thing it charges for.** `connection_request` and the `billing_charge` that comes from it must not diverge. A charge with no connection is a refund conversation. A connection with no charge is revenue lost silently. Here the design adds one more safeguard. The charge is derived from the event in an async step, and the schema carries a partial unique index on `(connection_request_id)` `WHERE kind = 'connection'`. So at-least-once delivery cannot produce two charges.

**Where I would deliberately not open one big transaction.**

- **Bulk work.** A 20,000-row catalog import is not one transaction. It is chunked into 500-row tasks. Rows land in `import_staging`, and they are validated against the category's facet schema. Only then are products promoted. That gives per-row error reporting, resumability, and a bounded lock footprint. A single transaction would hold locks for minutes. It would produce one all-or-nothing verdict with no per-row detail. And it would roll back an hour of work on row 19,998.
- **Anything crossing a network boundary.** Never hold a transaction open across an HTTP call to another service, a blob upload, or a broker publish. The transaction's duration becomes the remote system's latency plus its failure modes, and a hung call becomes a held lock. The cancer platform's composition path calls `clinical-nlp-svc` from a [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") task with a bounded deadline. That call is entirely outside any database transaction, and the task writes the result afterwards.
- **Two stores.** In the marketplace's publish path, the Mongo write and the Postgres commit are explicitly not one transaction, and they cannot be. The ordering rule does the work instead: Mongo first, Postgres second. The reason is that an orphaned revision document is invisible garbage, while a committed pointer to a missing document is a broken listing. A nightly reconciliation cleans up the orphans.
- **Backfills and migrations.** They are batched with a keyset cursor and a commit per batch. The reasons are the same, plus one more. A long `UPDATE` over a large table is an index-maintenance and write-amplification event that competes with live traffic.

**Why long transactions are specifically expensive in PostgreSQL.** This detail turns the rule from a style preference into an operational argument. An open transaction holds back the oldest transaction horizon. So **autovacuum cannot reclaim dead tuples anywhere in the database** for as long as that transaction runs. Bloat accumulates, and table and index scans get slower for every other query. On a replica, a long-running read can cause recovery conflicts or force the lag to increase. A transaction that holds locks also makes every conflicting writer wait behind it. On a 110-million-row partitioned table, that effect is not local. So "keep transactions short" is not about tidiness. It is a property the rest of the system depends on.

**The rule I would state.** A transaction should span exactly the set of writes that must be true together, and nothing else. If you cannot name why a second write belongs inside it, it does not belong there.

</details>

---

## 3. Query performance and data access

---

### DB-09. How do you design the indexes for a table — do you start from the schema or from the queries, and what do you do when the planner declines the index you added?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
From the queries, always. An index with no named access pattern behind it is write amplification, and on a 110-million-row table that amplification is expensive. When the planner declines an index, it is usually telling the truth. It declines the index for one of three reasons. The predicate does not match the index's leading columns. Or the index is not selective enough to beat a sequential scan. Or the statistics are wrong. I read the plan before I argue with it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Queries first, and I mean that literally, as a document.** In both designs, the index list is derived from a table that lists the access patterns one by one: the endpoint, its frequency, and the index that serves it. Examples are: browse a category newest-first; the same, sorted by entry price; free text over name and vendor; filter by country coverage; a group's shortlists; a thread's messages newest-first; unpublished outbox rows. Each row of that table names one index. Any index that does not appear in the table gets deleted. That discipline is what keeps the write path affordable, because every index is a write cost on every insert and a maintenance cost on every update.

**Choosing the type from the predicate, not from habit.**

- **Composite B-tree** for ordered access. Examples are `(patient_id, timeline_at DESC)` on every table that feeds the timeline, and `(category_slug, published_at DESC, product_id)` for browse. Column order follows equality, then range, then sort. That order is what makes keyset pagination cheap.
- **Partial** wherever a status predicate is always present. `WHERE status = 'published'` keeps roughly 15,000 rows out of a 55,000-row index, and it removes the filter from every plan. `WHERE published_at IS NULL` limits the outbox relay's index to the tiny unpublished set, instead of all history. `WHERE state = 'pending'` does the same for due reminders. Partial indexes give the most benefit for their cost here, and they are the most under-used option.
- **GIN** for containment and full text: `jsonb_path_ops` for category-specific attributes, arrays for integrations and country coverage, and `tsvector` for free text.
- **Block Range Index ([BRIN](https://www.postgresql.org/docs/current/brin.html "Compact PostgreSQL index type suited to large, sequentially correlated tables"))** on the time column of an append-only partitioned table. Physical order matches insert order. So on a 1.8-billion-row audit table, it costs a fraction of a B-tree's size for the same range scan.
- **Generalized Search Tree ([GiST](https://www.postgresql.org/docs/current/gist.html "PostgreSQL index type supporting range and exclusion constraints"))** where the predicate is a range overlap. The temporal `care_relationship` exclusion constraint is the index that answers "may this clinician see this patient". So the constraint and the index are the same object.
- **Time-to-live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"))** in Mongo, for staging data that must expire without a job.

**Partitioning before indexing on the big tables.** The check-in and audit tables use monthly range partitioning. So partition pruning removes almost all of the table from every query before any index is consulted. And detaching an old partition is a metadata operation, not a 500 GB `DELETE`. An index cannot rescue a query that scans five years when it needs one month.

**When the planner declines the index.** I go through these steps in order. The first step is always to look, not to force.

1. **Read `EXPLAIN (ANALYZE, BUFFERS)`.** Not `EXPLAIN`, because the estimate alone is what led to the problem.
2. **Check that the predicate actually matches.** Any of these makes an index unusable: a function applied to the column, an implicit cast, a `LIKE '%x'` leading wildcard, or a leading column missing from the `WHERE` clause. This is the cause more often than anything clever.
3. **Compare estimated rows to actual rows.** A large difference means a statistics problem, not an indexing problem. Run `ANALYZE`. Then raise the column's statistics target (`ALTER COLUMN … SET STATISTICS`), or add extended statistics for correlated columns. Adding another index on top of a bad estimate just gives the planner a new way to be wrong.
4. **Accept that the planner may be right.** If the index returns a large fraction of the table, a sequential scan genuinely is cheaper. Then the answer is a more selective query, or a partial index that carries the selective predicate. It is not a hint.
5. **Check whether it is a bitmap combination problem.** Several GIN indexes over an unselective combination can degrade toward a scan. And the selectivity estimates for high-cardinality array containment are poor. If that is the shape, the fix is a composite covering index for the high-traffic case, not a bigger instance.
6. **Only then consider forcing.** `SET enable_seqscan = off` is a diagnostic to confirm the hypothesis. It is never a deployed setting.

**One design note that is really an indexing decision.** The timeline query unions five tables. Every one of them carries a normalised `timeline_at` column, filled from that table's own natural column. That column exists so that all five tables can be served by the same composite index shape, and ordered deterministically by one keyset cursor. Without it, each branch would sort on a different column of a different type, and no index would serve the union. That is the pattern I would generalise: sometimes the right index change is a schema change that makes one index possible.

</details>


---

### DB-10. Walk me through an `EXPLAIN (ANALYZE, BUFFERS)` output. What tells you the plan is wrong rather than merely slow, and what do you do when estimated and actual rows disagree by three orders of magnitude?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Read it from the inside out. At every node, compare `rows=` estimated against `rows=` actual. A plan that is merely slow has accurate estimates and expensive work. A plan that is *wrong* has estimates that are off. That means the planner chose a join strategy and an access method for a row count that does not exist. A divergence of three orders of magnitude is a statistics problem first, and a query-shape problem second. I would run `ANALYZE` before touching anything else.

<details>
<summary><strong>Detailed answer</strong></summary>

**How I read it.** Execution is depth-first, from the innermost node outward, so I start at the leaves. For each node I want four things:

- **`rows=N` (estimated) versus `rows=N` (actual), and `loops=`.** Actual rows are per loop. So a node showing 10 rows with `loops=5000` did 50,000 rows of work. Missing that is the single most common misreading.
- **`actual time=start..end`.** The gap between a node's total and the sum of its children is that node's own cost. If a node's children are fast and the node itself is slow, that node is where the time went.
- **`Buffers: shared hit=` versus `read=`.** `hit` is the buffer cache, and `read` is the storage layer. A high `read` on a query that should be hot means the working set does not fit. That is a capacity answer, not an indexing one. `BUFFERS` is also how you tell two plans apart when cache warmth distorts the wall-clock time. The same query run twice looks faster the second time, for reasons that have nothing to do with the plan.
- **`Rows Removed by Filter`.** A large number here means the index brought back rows that the predicate then discarded. So the index is not carrying the selective condition. That is usually an argument for a partial or composite index.

**What tells me the plan is wrong rather than slow.**

- **Estimates that diverge from actuals**, especially at a leaf. Everything above a bad estimate is a decision made on a false premise.
- **A nested loop with a large actual outer row count.** A nested loop is the right choice for a handful of outer rows. At 100,000 it is a disaster, and it is the classic symptom of an underestimate.
- **A sequential scan on a large table where a selective predicate exists.** Either the index does not match the predicate, or the planner thinks the predicate is not selective.
- **A sort or hash spilling to disk**: `Sort Method: external merge Disk: ...`. That is a `work_mem` answer, and it is often one setting rather than a query rewrite.
- **A bitmap heap scan with `lossy=` blocks.** This means `work_mem` was too small to hold exact tuple ids. So the scan fell back to whole blocks and then rechecked them. This is also a memory answer.
- **A materialised subquery or [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement") where the planner could not push the predicate down.** Older PostgreSQL versions always fenced CTEs off from the rest of the query. Recent versions inline a non-recursive, side-effect-free CTE, unless the CTE is referenced more than once or marked `MATERIALIZED`. It is worth knowing which behaviour your version has.

By contrast, a plan that is merely slow looks *right*. The estimates track the actuals, the access methods are the ones you would have chosen, and it is simply reading a lot of pages. That calls for a conversation about data volume or product requirements, not about tuning.

**Three orders of magnitude, in order.**

1. **`ANALYZE` the table and re-run.** Stale statistics after a bulk load or an import are the cause more often than anything else, and this is thirty seconds of work.
2. **Raise the column's statistics target (`ALTER COLUMN … SET STATISTICS`)** if the distribution is skewed. The default histogram is coarse. A column with a long tail is exactly where it fails, for example a category slug where one category holds most rows.
3. **Add extended statistics** (`CREATE STATISTICS`) when the divergence comes from *correlated* columns. The planner multiplies selectivities, because it assumes the columns are independent. `category_slug` and `deployment_model` are not independent. So multiplying their selectivities produces an estimate that is orders of magnitude too low. This is the fix that people most often do not know exists.
4. **Look for estimation blind spots that the planner genuinely has.** Array containment on `text[]` and `jsonb_path_ops` on high-cardinality documents both estimate poorly, and no amount of `ANALYZE` fixes that. If the query's shape is impossible to estimate by its nature, the answer is to remove the need for the estimate. That means a composite covering index for the high-traffic case, or a product constraint that guarantees a selective leading predicate. In the marketplace, the API refuses an uncategorised query that carries more than two facet predicates, for exactly this reason. That rule guarantees a viable leading index, instead of hoping for one.
5. **Check for a function or cast wrapping the column.** It makes the statistics unusable, however fresh they are.

**The discipline around all of this.** A plan read on a laptop against a seeded table is not evidence about production. The data volume is different, the distribution is different, `work_mem` is different, and the minor version is possibly different. Before I quoted a latency figure, I would run the plan against a dataset of realistic size on the pinned version. And when I change something, I change one thing and confirm the change took. Two simultaneous changes produce a clean result that cannot be interpreted.

</details>


---

### DB-11. A list endpoint is paginated and the deep pages are getting slower. What is actually happening, and what do you tell the stakeholder who wants a jump-to-page control?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
`OFFSET n` does not skip rows cheaply. The database produces all `n` rows in order and throws them away. So page 400 costs roughly 400 times as much as page 1. The fix is keyset pagination. You carry the last row's sort key as a cursor and use it as a `WHERE` predicate, so every page costs the same. The honest answer to the jump-to-page request is that a numbered pager and a cheap deep page are mutually exclusive. After saying that, you offer what the stakeholder actually wants.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** `LIMIT 20 OFFSET 8000` asks the database for 8,020 rows in sort order, and it discards 8,000 of them. The work grows linearly with the offset, and it is done on every request. No index changes that: the index gets you the order, not the skip. It gets worse under concurrent writes. A row inserted between two requests shifts everything. So a user paging forward sees a duplicate, and a user paging back misses a row. Nobody reports that correctness bug, because it looks like a refresh.

**The fix.** Keyset pagination, also called cursor or seek pagination. The cursor is the sort key of the last row on the page. The next query is `WHERE (published_at, product_id) < (:cursor_ts, :cursor_id) ORDER BY published_at DESC, product_id DESC LIMIT 20`, and the same composite index as page 1 serves it. Page 400 costs exactly what page 1 costs. A concurrent insert cannot shift the window, because the position is a value, not a count.

Two details make it actually work:

- **The cursor must be a unique tuple.** A timestamp alone is not unique, so ties either duplicate rows or drop them. That is why the tuple carries the primary key as a tiebreaker, and why the composite index has the same shape. In the cancer platform, the timeline unions five source tables, so the cursor is `(timeline_at, source_table, id)`. The third component exists because ties across sources must break deterministically. And `timeline_at` itself is a normalised column, added to every source table for exactly this reason.
- **The cursor should be opaque.** Encode it. Do not expose raw column values. Clients will start to construct those values by hand, and then they become a contract you cannot change.

Both these designs use keyset pagination everywhere for this reason. The cancer platform bans offset pagination on the timeline query outright. With a 110-million-row check-in table, offset pagination degrades so badly that it was worth writing down as a rule, not as a preference.

**The stakeholder conversation, which is the real question here.** I would not open with "that is not possible". I would ask what the control is for. The answer is usually one of three things, and only one of them actually needs page numbers. And when I do explain the cost, I lead with the correctness half, not the performance half. On a sourcing workflow whose whole purpose is comparing a complete set, silently dropping a row is a defect, not a small imperfection. That is the argument that convinces people.

- *"I want to know how many results there are."* That is a count, not a pager. An exact count over a filtered index scan costs about as much as the page itself. So I would offer an estimate capped at a threshold. The marketplace returns `total_estimate` and stops counting at 1,000, and the interface shows "1,000+". For a sourcing workflow, that is genuinely all the information the number carries.
- *"I want to get to the end, or to a specific region of the list."* That is a sort or filter request that only looks like a pagination request. Reversing the sort gets you the end in one page. Jumping to "products starting with M" or "notes from March" is a `WHERE` clause. It is both faster and more useful than page 40.
- *"I want to resume where I was."* That is exactly what a cursor is. A cursor works better than a page number, because it is stable under concurrent writes.

If they still want numbered pages after all that, I would explain the trade honestly. Numbered pages can be delivered over a bounded range: offset pagination capped at, say, the first 1,000 rows, with keyset pagination beyond that. Past that limit, the cost is real latency on a query that the rest of the system's budget depends on. I would rather present that as a choice with a number attached than either refuse it or quietly ship something that degrades. What I would not do is ship an uncapped offset pager and let it become a production incident six months later. By then it is a contract, and removing it is a breaking change.

**The general habit behind this one.** A request for a mechanism is usually the first mechanism that came to mind, not the requirement. Finding the outcome first costs one question. It regularly replaces a hard feature with an easy one.

</details>


---

### DB-12. A query is fast for most callers and pathological for one. How do you approach that?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
That pattern is almost always about selectivity, not indexing. One caller's parameters produce a very different row estimate. So the planner picks a plan that is right for the common case and disastrous for that caller. That is why I compare plans across parameter sets instead of looking at one plan.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the shape points at selectivity.** If the query were simply missing an index, everyone would be slow. Fast for most callers and terrible for one means the chosen plan fits typical inputs and does not fit this caller's inputs. These are the usual mechanisms:

- **A predicate that is highly selective for most values and unselective for one.** A caller whose organisation has a hundred rows and a caller whose organisation has four million get the same plan. The nested-loop plan that is optimal for the first caller is a catastrophe for the second.
- **Correlated predicates that the planner treats as independent.** So the planner multiplies selectivities, and it greatly underestimates the row count. This is common with a category plus an attribute that only occurs in that category.
- **High-cardinality array or containment predicates.** Here the estimates are genuinely poor. The planner may choose a bitmap combination that degrades toward a scan on an unselective combination.
- **Data skew that the statistics do not capture**, because the sample missed a heavy value.

**How I diagnose it.** Capture the actual parameters from the slow caller. Not a representative example, but the real ones. Get the plan with actual timings for both a typical parameter set and theirs. Then compare estimated rows against actual rows at each node. A node that estimates fifty rows and produces five hundred thousand is the finding. Everything planned above it was planned on that estimate.

**The fixes, in order.**

1. **Improve the statistics.** Use extended statistics for correlated columns, or a higher sampling target on a skewed column. This is the cheapest fix, and it fixes the cause, not the symptom.
2. **Rewrite the query so that the plan cannot go wrong.** Restructure it so a selective predicate leads, or split it into two queries whose shapes are each predictable. Here, predictability is often worth more than peak speed.
3. **A composite or partial index that serves the pathological shape**, if it is a recurring class and not one caller.
4. **Bound the input.** If a caller can construct a query with no viable index, that is a product decision worth taking deliberately. Refusing an unbounded combination guarantees that a leading index always exists. Stating that as a constraint is more honest than hoping.

**And the operational half.** Once the query is fixed, the plan shape gets asserted in a test, if this path's performance is a design property. The parameter set that broke it goes into the seeded test data. Otherwise the next person will optimise against the common case again and bring the problem back.

</details>


---

### DB-13. When do you drop out of the ORM entirely, and what do you give up?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
I drop out of the ORM when the generated plan is the thing being engineered, not an implementation detail. In practice, that is the two or three queries that carry the traffic. What you give up is identity mapping, change tracking and the object graph. So those queries return rows, not entities, and that is deliberate.

<details>
<summary><strong>Detailed answer</strong></summary>

**The split I use.** I use the Object-Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) for domain writes, and for anything whose shape follows the object model. That is where the unit of work, the identity map and cascading behaviour are worth their cost. I use Core for the hot reads. There, the question is not "does this return the right rows". The question is "does the planner choose the index I built for it". Wrapping that in ORM constructs puts a layer between me and the plan, for no benefit.

**The two places it happened on these systems.** The first is the catalog search. It has many optional predicates over a projection table, with a partial index, a keyset cursor, and a deliberate constraint on how many facet predicates a query may carry. The second is the patient timeline. It is a union across five tables, with the limit pushed into each branch and a composite cursor to break ties deterministically. Neither query can be expressed in the ORM without hiding exactly the parts that matter.

**What you give up, honestly.**

- **The identity map and change tracking.** Core returns rows. If you want to modify something, you go back through the ORM, or you write the update explicitly. For a read path, that is not a loss.
- **Relationship traversal.** You get what you selected. In practice, this is a benefit on a hot path, because implicit traversal is where the N+1 comes from.
- **Some portability.** This matters less than people say. The queries where you need Core are usually the ones that use engine-specific features anyway, and pretending otherwise is a fiction.
- **Readability for anyone who only knows the ORM.** This is the real cost. The mitigation has two parts. One is a comment that states the constraint the query is written to satisfy. The other is a test that asserts the plan shape, so that a well-meant simplification fails loudly.

**What I would not do.** I would not push the query behind a generic repository method that returns a nice object and hides the statement. If the implementation is the design, hiding it is a liability, not an abstraction. Abstraction pays off where the implementation is genuinely interchangeable.

**And I would not start here.** Write it in the ORM, measure, and drop down only where the measurement says so. Most queries never need it.

</details>


---

### DB-14. Beyond N+1, what other query patterns quietly get worse as a table grows?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Offset pagination, exact counts, unbounded `IN` lists, sorts that no index can serve, and anything with a leading wildcard. They all behave perfectly in development. Then they degrade in proportion to data the developer never had.

<details>
<summary><strong>Detailed answer</strong></summary>

**The list, with the mechanism for each.**

- **Offset pagination.** The database produces every skipped row and then discards it. Page one is instant. Page four hundred reads four hundred pages of rows, only to throw them away. Worse, under concurrent writes the pages shift, and rows are duplicated or skipped. Keyset pagination carries the last row's sort tuple as a cursor. Its cost per page is constant, and it is stable. This is why both systems use it everywhere, and why the timeline cursor is a composite tuple and not a single column.
- **Exact counts on a filtered set.** `COUNT(*)` with a filter costs roughly what fetching the rows costs. So a paginated list endpoint that does a count plus a page does double work, to show a number nobody acts on. A capped count, one that stops and reports "1,000+", is usually what the workflow actually needs.
- **Unbounded `IN` lists.** Batching is the right fix for an N+1, but an unbounded batch is a new problem. A list of ten thousand identifiers produces a very large statement and unpredictable plans. Batches need a cap and a chunking loop.
- **Sorting on something that is not in an index.** It is fine at ten thousand rows, and it becomes a disk sort at ten million. The sign is a sort node spilling to disk in the plan.
- **A leading wildcard in a text match.** It cannot use a standard index at all. It needs a trigram index or a proper text search.
- **Predicates the index cannot serve because of a function or a cast.** Applying a function to the column, or comparing a column to a value of a different type, silently defeats the index. The plan shows a sequential scan, and the query looks correct.
- **`SELECT *` on wide rows.** This is worst with large text or binary columns, which are pulled out of overflow storage for rows where the caller only wanted two fields.
- **`DISTINCT` used to hide a join fan-out.** It forces a sort or hash over the entire multiplied result.

**How I catch these before production.** Seed a table to a realistic size in the integration environment, instead of testing against a hundred rows. Most of these problems are invisible below about a million rows. Assert the plan shape on the paths whose performance is a design property. And assert query counts in tests. That catches the N+1 family directly. It is the only technique here that keeps working as the code changes.

</details>


---

### DB-15. How do you stop an N+1 regression from coming back six months later?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Assert the query count in a test. Reading code for N+1 works until someone adds a property that touches a relationship. Then it silently stops working. A test that fails when a request issues more queries than it should is the only mechanism that survives staff turnover.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why review does not keep the problem out.** An N+1 is rarely introduced by someone who writes a loop with a query in it. It is introduced when someone adds a computed property to a model, when a serialiser reaches one level deeper, or when a template touches a relationship. All of these changes look harmless in a diff, and they are in a different file from the query. Six months later, nobody remembers that the endpoint was optimised.

**The mechanisms that actually work, in order.**

- **Query-count assertions on the endpoints that matter.** Hit the endpoint in a test with a fixture that holds several rows, count the statements, and assert a bound. The important detail is that the fixture must have more than one row in each collection. With one row, an N+1 and a batched fetch produce the same count, and the test passes on a broken implementation.
- **Make lazy loading raise.** Configure relationships so that accessing an unloaded one raises an error, instead of quietly issuing a query. This turns the entire class of defect into a loud error at development time. It is the single most valuable setting in this area. And under an async session, it is effectively mandatory anyway.
- **Log statements in development, with a count per request.** Then the number is visible while you work, instead of being discovered later. A request that issues forty queries should be obvious to the person writing it.
- **Watch requests per page view in production, not just latency.** The distributed and client-side versions of this problem show perfect server-side percentiles. Every request is fast, but there are far too many of them. A latency dashboard will never show it.

**On the batching side**, the same discipline applies to the versions that do not involve the database. A per-item cache lookup becomes a multi-get. A per-item document fetch becomes a bulk query. A per-row event becomes one batched event. Those need the same kind of assertion, because they are just as invisible in review.

**What I do not rely on.** A comment saying "do not remove this eager load". Someone tidying up will remove it, in good faith, and nothing will fail.

</details>


---

### DB-16. How do you prove a query optimisation actually worked in production rather than on your laptop — and what would make you revert one that looked faster?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
A laptop measurement is a hypothesis, not evidence. The data volume, the distribution, the cache warmth and the configuration are all different. Proof is the production percentile for that route or query, before and after the change. It must cover a window long enough to include the real traffic mix, with the plan captured on both sides. I would revert a change in three cases. It improved a mean while it worsened the tail. Or it improved reads by making the write path slower. Or its gain turns out to be cache warmth, not the change.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the laptop gives the wrong answer, specifically.** There are four reasons, and they make each other worse. First, the dataset is smaller and more uniform, so the planner makes different choices. Second, the buffer cache holds the whole table, so the `BUFFERS` reads that dominate production are invisible. Third, `work_mem` and parallelism settings differ, so a sort that spills to disk in production fits in memory locally. Fourth, there is no concurrency, so lock contention and connection-pool queueing contribute nothing. A query can be three times faster locally and slower in production, because the plan flipped on a different row estimate.

**What I would actually measure.**

1. **The percentile, not the mean.** That means `http_request_duration_seconds` p95 by route, and the database-side statement duration for the specific query. A mean improves when the common case gets faster, and it hides a tail that got worse. The tail is what the error budget is spent on, and it is what users describe.
2. **Over a full traffic cycle.** These workloads are extremely uneven. The cancer platform concentrates 70% of its traffic in an eight-hour clinic window, and the check-in burst lands between 07:00 and 09:00. A measurement taken at 15:00 says nothing about the morning. A week is usually the shortest honest window.
3. **Buffer reads, not just time.** If `shared read` dropped, the query is genuinely touching less data. If only the wall time dropped, I might be measuring a warmer cache.
4. **The plan on both sides.** `auto_explain` with a duration threshold captures the plan for the slow executions in production. Production is the only place where the plan that matters actually runs. If a change did not change the plan, it did not do what I thought.
5. **The write path, on the same graph.** Adding an index to fix a read makes every insert and update on that table slower, and it adds maintenance load. On a table that takes a bulk import, this can be the dominant cost. It will not show up if I only look at the endpoint I was optimising.

**How I would roll it out.** A change with plan risk rolls out the same way as the service with the risky queries: as a canary. In the marketplace, `catalog-service` gets a second deployment, which receives about 10% of traffic through ingress weighting. That deployment is held for fifteen minutes against error rate and p95 before the weight advances. This is done specifically because the service carries the risky query plans. The canary gives a concurrent A/B test under identical real traffic. That is strictly better evidence than a before-and-after comparison across time, because it controls for everything that changes on its own.

For a pure index addition, run `CREATE INDEX CONCURRENTLY` first, confirm that the planner adopts the index, then measure. And I would check that the new index is actually used before declaring success. If `pg_stat_user_indexes` shows zero scans a week later, the planner never chose the index, however good the local test looked.

**What would make me revert something that looked faster.**

- **The p99 got worse while the p50 improved.** This is common with a plan change that is better on typical inputs and catastrophic on an outlier. An example is a nested loop that is great for ten outer rows and terrible for ten thousand. The wider the variance, the worse the incident when it arrives.
- **The write path degraded.** Say a new index costs 15% on an import path, to save 10 ms on a read I execute rarely. That is a bad trade, and it is only visible if I looked.
- **Cache pressure moved.** A bigger index pushes hot data out of the buffer cache, and that makes unrelated queries slower. The sign is a rising `shared read` on queries I did not touch.
- **The improvement cannot be attributed to the change.** If a deploy, a vacuum, an `ANALYZE` and my change all landed in the same window, I have not proven anything. Change one variable, and confirm the change took. Otherwise the result is clean but cannot be interpreted.
- **It only holds on today's data distribution.** A query that is fast because one category currently holds 200 rows is a problem waiting to happen. I would check the plan against a projected volume before treating the gain as durable.
- **It made the code much harder to reason about, for a gain inside the noise.** Take a 5% improvement that turns a readable query into hand-tuned [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database"), with a comment that explains why it must not be touched. That is usually not worth it. And on a project where quality is valued over speed, that argument convinces people.

**And the thing I would set up so the next person does not have to ask.** A dashboard panel per hot query, with the deploy timeline laid over it. Most "did this help" arguments cannot be answered, because nobody recorded the before.

</details>

---

## 4. Migrations and backfills

---

### DB-17. A table has to change shape while it is being read and written in production. How do you sequence that, and what makes a migration dangerous rather than merely slow?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Expand, migrate, contract, across separate releases. Add the new shape as nullable, dual-write, backfill in bounded batches, and switch reads. Only remove the old shape in a later release, once nothing reads it. What makes a migration dangerous rather than slow is a lock. An operation that takes `ACCESS EXCLUSIVE` makes every later query queue behind it. So a schema change that would have taken four seconds freezes the table for as long as the longest transaction in front of it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence, with the release boundaries that make it work.**

1. **Expand.** Add the new column as nullable, with no default that requires a rewrite. Add the new index `CONCURRENTLY`. Add the new table. Nothing reads them yet. This ships and runs against the *old* application image without breaking it, and the whole approach depends on that property.
2. **Dual-write.** The new image writes both shapes. It is deployed as a normal rolling or blue-green release. During that release, both image versions are live against the same schema.
3. **Backfill.** A batched, resumable job: bounded chunks, each one its own short transaction, throttled and observable. Not one `UPDATE` over 110 million rows. That single `UPDATE` would hold locks, generate an enormous volume of write-ahead log, and hold back vacuum with its snapshot for its whole duration.
4. **Switch reads.** This is a separate release. Now the old shape is written but not read.
5. **Contract.** A later merge request, at least one release afterwards, drops the old column or constraint. Because it is a separate change, it can be reverted.

**Why the release boundaries matter more than the SQL.** The rule both designs enforce is that **every migration must be backwards-compatible with the previous image**. That rule is what permits blue-green, because both colours run against the same schema during the cut-over. It is also what makes rollback a redeploy of the previous image digest, not a down-migration. Down-migrations are a trap. They are written once, never tested, and run for the first time during an incident. The cancer platform runs `alembic upgrade head` as a pre-sync hook before the rollout, and it has no down-migration path at all. If a change cannot be written compatibly, it is split across two releases instead.

**What makes it dangerous rather than slow: the types of lock.** The distinction I would draw is between three kinds of operation. Some take a brief `ACCESS EXCLUSIVE` lock. Some hold that lock for the duration of a rewrite. And some avoid it.

- **Effectively instant on modern PostgreSQL:** adding a nullable column; adding a column with a non-volatile default (stored in the catalogue, with no rewrite since version 11); dropping a column; renaming.
- **Dangerous because they rewrite the table while holding the lock:** changing a column type, in most cases; adding a column with a volatile default.
- **Dangerous because they hold a lock while scanning:** adding a `CHECK` constraint, which holds `ACCESS EXCLUSIVE` while it scans. Adding a foreign key holds `SHARE ROW EXCLUSIVE` on both tables, so it blocks writes while it scans. `SET NOT NULL` without a prepared constraint also scans the table while holding `ACCESS EXCLUSIVE`. That is why you add `CHECK` and foreign-key constraints `NOT VALID` first and run `VALIDATE CONSTRAINT` afterwards. Validation takes only a `SHARE UPDATE EXCLUSIVE` lock, and it does not block writes.
- **Safe if you remember the flag:** creating an index. `CREATE INDEX` blocks writes for its whole duration. `CREATE INDEX CONCURRENTLY` does not. Its cost is two passes over the table, and the risk of leaving an invalid index behind if it fails. That invalid index then has to be dropped, and the build retried.

**The lock queue is the part people underestimate.** An `ALTER TABLE` that waits for `ACCESS EXCLUSIVE` sits behind the current readers. And every query that arrives after it queues behind *it*. So one slow analytics `SELECT` plus one otherwise trivial `ALTER` stalls the entire table. The defence is `lock_timeout` on the migration session, with a retry loop. The migration gets the lock quickly, or it fails and tries again a moment later. Failing fast is strictly better than building a queue.

**And the other things I check.** Is the migration idempotent and resumable, in case it dies halfway? Does it run as a role separate from the application role, so that the application never holds schema privileges? Does it run before the new pods roll out, or after? What is the write-ahead log volume, and will it push the replication slot past its limit and break the replica? A backfill that generates more [WAL](https://www.postgresql.org/docs/current/wal-intro.html "Write Ahead Log — Sequential log written before data pages so committed transactions survive a crash") than the replica can consume turns a migration into a replication incident. That kind of incident is invisible until it happens.

**On non-relational stores, the same discipline applies**, with one difference: nothing forces you to migrate. A document carries an explicit `schema_version`, and the read path handles both versions. But "handles both" has to be a decision with an end date, not an accident. A lazy migrate-on-read with no backfill means that version 1 documents exist forever, and every reader carries that branch permanently.

</details>


---

### DB-18. You are reviewing someone else's migration an hour before a release. What do you look for, and what would make you block it outright?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
I look at lock strength and duration first, then reversibility, then whether the previous application image can still run against the new schema. I block outright on four things. Anything that takes a long `ACCESS EXCLUSIVE` lock on a hot table. Any unbounded `UPDATE` or `DELETE`. Any destructive change that lands in the same release as the code that stops using it. And any migration that nobody has run against a production-sized dataset.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checklist, in the order I read the file.**

1. **What lock does each statement take, and for how long?** I read every `ALTER` and ask which lock mode it needs. A column type change, an added `CHECK` or foreign key without `NOT VALID`, a `SET NOT NULL` without a prepared constraint, a non-`CONCURRENTLY` index: each of these blocks the table for a scan or a rewrite. On a small table nobody notices. On the hot one it is an outage.
2. **Is there a `lock_timeout`?** Without one, the migration waits indefinitely for the current readers, and it builds a queue behind itself. With one, it fails fast and retries. This is the single most valuable line in a migration file, and it is almost always missing.
3. **Is the data change bounded?** An `UPDATE` with no `WHERE` on a large table is four problems in one statement: a long transaction, a flood of write-ahead log, a vacuum blocker and a replication risk. I want batching with a bound and a resume point.
4. **Is it backwards-compatible with the image that is currently running?** This question decides whether rollback exists. If the old pods cannot serve traffic against the new schema, the only way out after the migration lands is forward, at the worst possible time. I also ask the same question from the other side. Is the rollback a redeploy, or does it need a down-migration? If it needs one, I want to know who would run it under pressure, and whether it has ever been tested. Usually the answer to both is no. Then the right fix is to restructure the migration, not to write a better down step.
5. **Does the destructive half ship separately?** Say a dropped column is in the same merge request as the code that stopped reading it. Then the rollback of that code is now broken. Contract is a later release, deliberately.
6. **Is it idempotent and resumable?** If it dies at 60%, what happens when it is re-run? A migration that is only correct from a clean start is a migration that will be run twice.
7. **Has it been run against production-sized data?** "It took two seconds on my machine" tells you nothing about a 110-million-row table. If the answer is no, the duration is unknown. And an unknown duration on a lock is the definition of a dangerous change.
8. **What does it do to the replicas?** WAL volume, pressure on the replication slot, and whether replica lag will go over its alert threshold during the run.
9. **Does it run as the right role?** Migrations run under an owning role that never serves a request, and the application role holds no schema privileges. On the cancer platform, this also matters for Row-Level Security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")). There, the application role must be `NOSUPERUSER` without `BYPASSRLS`. A migration that quietly grants a privilege to the application role would disable the strongest control in the system.
10. **Does it touch anything security-relevant?** A policy, a grant, or a constraint that an authorization rule depends on. Those get read twice, however little time is left.

**One reviewing habit worth stating.** I read the generated statements, not the migration framework's shorthand. A one-line instruction to alter a column can emit something very different from what the author intended. And the emitted statement is what the database will execute.

**What blocks it outright.** Any one of these blocks it. An unbounded rewrite or scan under `ACCESS EXCLUSIVE` on a hot table. A `DROP` or a destructive type change in the same release as the code change. An unbatched data migration on a large table. A migration that has never been run against realistic volume. Or a change that makes the previous image unable to run. I would also block a migration that has no plan for what happens if it fails halfway. At that point, "we will work it out" means an improvised `UPDATE` in production.

**What does not block it, but gets written down.** A slow but safe migration is fine, for example a `CONCURRENTLY` index build that will take forty minutes. It just needs to be known, started early, and not be something anyone is waiting on. Slow is a scheduling problem. Dangerous is a correctness problem.

**How I would say it.** Name the specific statement and the specific lock, and attach the alternative. For example: "`ALTER TABLE ... ALTER COLUMN TYPE` rewrites the table under `ACCESS EXCLUSIVE`; add a new nullable column, backfill in batches, switch reads next release". That is a review someone can act on in the hour available. "This looks risky" is not, and an hour before a release the difference matters. If the alternative genuinely cannot be built in the time, the honest recommendation is to pull the migration from the release, not to approve it with a caveat nobody will read.

</details>


---

### DB-19. A backfill on a very large table has to be stopped halfway. What does that demand of how you wrote it?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It demands four things. The backfill must be resumable from its own recorded progress. It must be idempotent per batch. It must be throttled by an observed signal, not by a fixed sleep. And it must be safe to leave permanently half-done, because the release must be correct whether the backfill finished or not.

<details>
<summary><strong>Detailed answer</strong></summary>

**The last point is the one people miss, so I will start there.** Suppose the application depends on the backfilled column being fully populated. Then stopping halfway means the system is in an invalid state, and someone is under pressure to restart the backfill immediately. The design that removes that pressure is expand-and-contract. The column is added as nullable. The code writes the column from now on, and the code does not require the column. Only a later release, after the backfill has verifiably completed, starts reading the column as guaranteed to be present. Then a paused backfill is an inconvenience, not an incident.

**What resumability actually requires.**

- **Progress recorded durably, in the database, not in the job's memory.** A cursor row names the last completed key or partition, and it is committed with each batch. Then restarting means reading the cursor and continuing. It does not matter whether the job stopped cleanly or the pod was killed.
- **Batches bounded by key range, not by offset.** Then a restart does not rescan what is already done, and the cost of each batch is predictable.
- **Idempotent batches.** A batch that was partly applied before the job died must be safe to re-run. Writing the batch as an update that is conditional on the current value achieves that. Re-running it is then a no-op on rows that are already done.
- **A commit per batch**, never one long transaction. A single transaction over a hundred million rows holds locks for its whole life. It accumulates enormous numbers of dead row versions, and it cannot be stopped without losing all of its work.

**Throttling by signal, not by sleep.** A fixed pause between batches is a guess, and it is wrong at both ends. It is too slow on a quiet night and too aggressive during a peak. The job can instead read replication lag, or lock wait counts, and pause when they go over a threshold. Then the job adapts. It also means the job stops on its own during an incident, and a human does not need to remember that it exists.

**Operational properties I would want.** A kill switch that does not require a deploy: a flag that the job checks between batches. Then stopping the job is a configuration change, not a rollout. Progress and estimated remaining time as metrics. Then anyone can answer "how far through is it" without asking me. And a verification query at the end that asserts zero remaining rows, before anything depends on completeness.

**The rehearsal.** Run the backfill against a realistic copy first. Stop it halfway on purpose, and restart it. That turns the duration into a measurement. It also turns resumability from a property I believe I implemented into one I have observed.

</details>


---

### DB-20. A migration failed halfway on production. What now?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First, establish what actually applied, because the framework's version table and the real schema can disagree. Then stop the deploy. Decide between roll-forward and roll-back based on whether the previous image runs against the current schema. Only then touch anything.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: stop making it worse.** Halt the deploy so that no further revisions run, and stop any automated retry. A migration retried blindly against a partially applied state is how a recoverable situation becomes a bad one.

**Step two: find out the real state.** Ask two questions, which have different answers. What does the migration framework's version table say? And what does the schema actually contain? The two diverge in exactly the case that matters. One example is a statement that ran outside a transaction, such as a concurrent index build. Another is a script with several statements, where one committed and a later one failed. Inspect the schema directly. A concurrent index build that failed leaves an invalid index behind, and that index must be dropped before a retry. This is the single most common version of this incident.

**Step three: is the system currently serving?** Usually yes, because expand-only migrations do not break the running image. That turns an emergency into a problem with time to solve it. It is the main reason I hold expand-and-contract as a rule.

**Step four: decide the direction.**

- **Roll forward** if the remaining steps are safe and the failure was environmental: a lock timeout, a transient error, a resource limit. Fix the cause, drop any invalid artifact, and re-run. This is the usual outcome.
- **Roll back the application** to the previous image if the new code needs schema that the migration did not deliver. The migration was expand-only, so the old image runs against the partial schema. This is why the discipline exists. Then fix the migration properly, and try again in a normal release, not under pressure.
- **Reconcile the version table by hand**, carefully and with someone watching, if the table disagrees with reality. Marking a revision as applied when it is not is a decision to make deliberately and to write down, because the next person will trust that table.

**Step five: afterwards.** Why did it fail here and not in the rehearsal? Almost always, the answer is production traffic: a lock wait, a size difference, a timeout. That lesson belongs in three places: in the migration itself as a lock timeout with retries, in a bounded and resumable backfill, and in a rehearsal on a realistic copy next time.

**What I would not do.** I would not run an ad-hoc fix directly against production without putting it through a migration. The schema would then stop matching the code that describes it, and the next deploy would be a surprise. If an emergency statement is genuinely needed, it gets written as a migration immediately afterwards.

</details>


---

### DB-21. A schema change has to be rolled back after the new code is already live. What does that demand of how the migration was written in the first place?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It demands that the migration was additive, and that the old image can still run against the new schema. Then the rollback is a redeploy of the previous image digest, and the schema does not move at all. If the migration was destructive, there is no clean rollback. Down-migrations restore shape but not data. And by the time you need one, it has never been run.

<details>
<summary><strong>Detailed answer</strong></summary>

**Reframing the question, because the framing is the answer.** "Roll back the schema" is almost always the wrong operation. Data written in the new shape since the migration does not survive a reversal of the shape. A down-migration that drops a column drops whatever went into that column. What you actually want is to roll back *the code* and leave the schema where it is. That is only possible if the schema is compatible with both images. So the demand is made when the migration is written, one or more releases earlier: **every migration must run safely against the previous application image.** In both these designs, that is the stated rule. It is what makes rollback a redeploy of the previous image digest. That rollback is safe by construction, because the schema is compatible in both directions during the window.

**What that means concretely for how the migration is written.**

- **Additive only in the release that deploys.** Nullable columns, new tables, and new indexes created `CONCURRENTLY`. The old image ignores them, and the new image uses them.
- **No rename in place.** A rename breaks the old image immediately. Add the new column, dual-write, backfill, switch reads, and drop the old column later.
- **No `NOT NULL` or new constraint that the old image can violate.** The old image does not know that it must populate the column, so the first write from a surviving old pod fails. Constraints go on in the contract phase, after every writer populates the field.
- **No default that changes behaviour under the old image.** Say the old code inserts a row without the column, and the default is wrong for what that row means. Then you have bad rows to clean up, and that cleanup is a data migration nobody planned.
- **Contract lands at least one release later**, as its own merge request. That gap is the rollback window. Its width is a deliberate choice, not an accident.
- **Backfills are separate from schema changes**, and they are resumable. So rolling back the code does not require unwinding a half-finished backfill.

**What rollback looks like when it is done right.** [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") reverts to the previous revision, the previous image digest is deployed, and the schema stays. Nothing runs against the database at all. That is the property worth defending in an interview. It means the rollback path is the same mechanism as the deploy path, which is exercised all the time. It is not a special procedure that only ever runs during an incident.

**What rollback looks like when it is done wrong.** Someone writes a down-migration, and it has three problems. It has never been executed anywhere. It restores structure, but not the data that the forward migration transformed. And it runs under exactly the conditions where mistakes are most expensive. I would rather have no down-migration and a forward-fix discipline than a down-migration that creates false confidence. If a truly destructive change has to be reverted, the honest path is a point-in-time restore to a scratch instance, plus a reconciliation of what was written since. That is slow and manual, and it is exactly why the expand-and-contract discipline exists.

**The organisational half of this.** Expand-and-contract costs three merge requests where one would do. The third one, the contract, is the one that gets forgotten. So the codebase collects columns that nobody reads and that everybody is afraid to drop. I would treat the contract migration as part of the same piece of work, tracked and landed, not as tidying. And I would say plainly that the cost is real: this discipline is slower. What it buys is that a bad release at 17:00 on a Friday is a redeploy, not an incident.

</details>


---

### DB-22. You have to write a migration against a database engine whose locking behaviour you do not know. How do you proceed safely?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Assume that nothing about locking transfers from other engines. Establish the locking behaviour empirically before touching production. First, read the engine's own documentation on the specific operation. Then rehearse against a realistic copy, and watch what actually blocks. The process discipline transfers completely, but the engine specifics do not.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why locking specifically is the thing not to assume.** Almost everything else about a migration is reasoning that carries across engines: batching, resumability, expand-and-contract, and keeping the previous application version runnable. Locking is different for two reasons. It is where engines genuinely diverge. And if you are wrong about it, the consequence is not a slow query but a stalled table. An operation that is online on one engine takes an exclusive lock on another, and you cannot see the difference in the statement's syntax.

**What I would establish before writing anything.**

- **Which operations are online for this engine and version.** Adding a column, adding an index, adding a constraint, changing a type: each has a documented lock level. Version matters. The answer changes between releases, and the documentation is version-specific for a reason.
- **Whether a lock request queues behind existing transactions and blocks everything behind it.** This is the failure that surprises people on any engine. A statement that needs a brief exclusive lock waits for a long-running read. Then every later query queues behind the waiting statement. A migration that should take milliseconds stalls the table. If the engine has this behaviour, every migration needs a short lock timeout with retries. Then the migration gives up instead of making every later query queue behind it.
- **Whether there is concurrency control that lets readers proceed during a write.** That decides whether a backfill is disruptive or merely slow.
- **Whether the schema change is transactional.** If it is not, a failure leaves a partially applied state. So the migration must be written to detect and clean up whatever artifact it leaves behind.

**Then rehearse, on a copy at realistic scale, and watch the right thing.** Do not only watch how long it takes. Watch what it blocked while it ran. Run representative read and write traffic against the copy during the migration, and observe whether that traffic stalls. The duration is a number I can plan around. The blocking is what decides whether the migration can run during traffic at all.

**What I write regardless of engine.** Bounded, resumable, restartable batches. Expand-and-contract, so that the previous image runs against the new schema and rollback is a redeploy. No data backfill inside the schema migration. A verification query before moving on to the step that adds constraints. And a written answer to what happens if the migration must be stopped halfway, agreed in advance and not at two in the morning.

**And I would ask.** Whoever has run migrations on this system before knows the three things that are not in the documentation. Twenty minutes with them is worth more than a day of reading. Not asking is a way of protecting your ego at the client's expense.

</details>

