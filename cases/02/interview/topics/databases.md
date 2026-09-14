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
Relational for anything with referential integrity, a fixed shape, or a role in a transaction; document for anything whose shape the platform cannot fix in advance without blocking the next use case. The split costs you a projection pipeline, a lag budget, a reconciliation job, and a second place to get authorization wrong — and you should only pay that when a single store genuinely cannot serve both halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I actually apply** is not "structured versus unstructured". It is three questions: does this data participate in a foreign key or a transaction that must be atomic; do I need to query it by predicates I can enumerate today; and would adding a new variant require a migration. If the answers are yes, yes, no — it is relational. If they are no, no, yes — it is a document.

In the marketplace that produced a deliberate split down the middle of one entity, which is the interesting case. A listing has a **spine** — identity, vendor ownership, category, status, publication timestamp, price tiers — which has referential integrity to vendors, participates in shortlists and connections, and is what search and the admin workspace query. That is relational, in `postgres-core`. It has a **body** — everything specific to being a Point of Sale ([POS](https://en.wikipedia.org/wiki/Point_of_sale "The system and moment at which a retail transaction is completed")) system, an inventory tool or a loyalty engine — which has no schema the platform can fix without blocking whichever category ships next. That is a document in `mongo-catalog`, validated at write time against a per-category `facet_schemas` document rather than a table definition. The validation matters: "no fixed column set" must not degrade into "no contract", and [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") checking the submitted attributes against the category schema is what keeps it governable. Adding a category becomes a document insert plus a facet mapping, not a migration.

The cancer platform drew the same line differently because the data was different: education pages vary by cancer type, treatment line and locale and are versioned with a review state, so they live in `mongo-content`; the clinical record is relational because a prescription has referential integrity and an authorization boundary. Symptom scores went to `jsonb` inside [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") rather than to Mongo — the symptom set differs by cancer type and evolves with the protocol, but it is read in the same query as the row it belongs to, so a Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) on the document was the right answer rather than a second store.

**What the split costs, stated honestly, because this is the half of the question people skip.**

- **A projection.** Anything a user filters on has to be queryable relationally, so a worker copies the facetable subset of the Mongo document into `product_listing_facets` in Postgres. That table is a denormalised read model written only by `indexer-worker` and read only by `catalog-service`.
- **A lag, and therefore a lag budget and an alert.** The projection trails the document by seconds — p95 under 5 s — and when the indexer dies, listings silently stop becoming searchable. That failure has no error to raise, so it needs its own metric.
- **A reconciliation job.** A nightly sweep re-projects any product whose `projected_at` predates its `updated_at`, and deletes revision documents that no product row points at. Without it, one lost event is permanent.
- **A write-ordering rule.** Mongo first, Postgres commit second. An orphaned revision document that nothing points at is invisible garbage; a committed pointer to a document that does not exist is a broken listing.
- **A second authorization surface.** Every store that can answer a query can become the path around your access control. That is why the search index in the cancer platform carries mandatory scope fields on every document.

**And the alternative I would not dismiss.** Everything in PostgreSQL with `jsonb` for the metadata is genuinely defensible at this size, and I would say so rather than pretend the polyglot choice was obvious. It trades the projection lag for heavier write amplification on the same table that serves search. The reason to take the split here is the vendor-facing authoring surface — per-category schema validation, immutable document revisions, staged imports — which is Mongo's native shape. If that surface did not exist, one store would be the better answer.

</details>


---

### DB-02. While building the Retail Software Aggregation Platform, you used MongoDB for product metadata to handle variable schemas for POS and inventory tools; how did you manage the integration and query performance when the system needed to join this unstructured metadata with relational vendor data stored in PostgreSQL?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
There is no join, and designing so there never has to be one is the whole answer. The hot query runs against a single denormalised PostgreSQL table that a worker projects the facetable subset of the Mongo document into; the document is fetched afterwards, in one bulk `$in` by primary key, only for the products already on the page.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism, in the order a request hits it.**

1. **One relation for the search query.** `product_listing_facets` carries `vendor_id`, `category_slug`, `status`, `published_at`, `country_coverage`, `deployment_model`, `price_from_minor`, `integrations`, a `facets jsonb` column and a `search_vector`. `vendor_id`, `status` and `published_at` are copied from `product` *deliberately*, so the highest-traffic query in the system touches exactly one relation and never joins even within PostgreSQL. It is written only by `indexer-worker` and read only by `catalog-service`, which is what keeps a denormalised table from becoming a correctness problem.
2. **Indexes per access pattern, not per column.** `GIN (search_vector)` for free text; `GIN (facets jsonb_path_ops)` for arbitrary category-specific predicates; `GIN` on the `country_coverage` and `integrations` arrays for containment; and two partial B-trees — `(category_slug, published_at DESC, product_id) WHERE status = 'published'` for the default browse order and `(category_slug, price_from_minor)` for the price sort. The partial predicate keeps roughly 15,000 unpublished and archived rows out of the hot index entirely and removes the status filter from every plan.
3. **Hydration by primary key, in bulk, after the page is decided.** `product_metadata._id` **is** `product.id`, so the two stores join without a mapping table. The page returns about thirty product ids; [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") serves the ones it has as `cat:listing:{id}:v{rev}`, and the misses go to Mongo as a single `find({_id: {$in: [...]}})`. Never per-item — a loop of thirty round trips is how this design would have failed.

**The performance consequence, decomposed.** The uncached path budgets about 45 ms for the keyset query on the projection, about 25 ms for the bulk Mongo hydration and about 14 ms for serialisation, landing near 107 ms server-side against a p95 target of 200 ms. At the modelled 85% hit ratio on the search-page cache, the p95 falls on that uncached path with roughly 90 ms of headroom for a cold buffer cache or an autoscaling cold start.

**Where it actually gets hard, and what I would say honestly.** The defining performance risk is not the cross-store fetch — it is the planner on the projection table. A comparison workflow produces queries with many optional predicates, and the failure mode is a bitmap `OR` across several GIN indexes on an unselective combination degrading toward a sequential scan as the table grows. Selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor for high-cardinality arrays, so the claim that those indexes combine into a bitmap `AND` is exactly the kind of thing I would confirm with `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table on the pinned minor version before quoting a latency figure. If the plan is wrong, the fix is a composite covering index per high-traffic category, not a bigger instance.

Two product constraints buy guarantees the query planner cannot: the [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") refuses an uncategorised query carrying more than two facet predicates, which guarantees a viable leading index; and the response returns `total_estimate` capped at 1,000 rather than an exact count, because an exact count over a filtered GIN scan costs as much as the page itself. Both are cases where a small product decision removes a class of performance problem, and I would rather argue for one of those than tune around the consequence.

**The cost of the design.** The projection trails by seconds, so a vendor who just clicked publish would see stale data. That is routed around rather than shrunk: the vendor workspace reads `product` from the Postgres primary and the metadata document from Mongo directly, never the projection and never the cache, so vendors get read-your-writes and retailers get the fast, slightly-stale read model.

</details>


---

### DB-03. When is it right to let two stores disagree, and how do you keep that from being a bug?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Whenever a derived store exists at all, which is most systems. The discipline is that the divergence is bounded, stated as a number, measured in production, and reconciled — a staleness budget is a design decision, and unmeasured staleness is a defect wearing its clothes.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where disagreement is correct.** A search index, a projection table, a cache, a read replica. Each exists because deriving the answer at read time is too expensive, and each is necessarily behind. Trying to make them synchronous puts the derivation back on the write path and removes the reason they exist.

**What turns that from acceptable into engineered.**

- **State the budget as a composed number.** On the health platform, search freshness is expressed as the sum of the relay interval, the bulk flush and the index refresh — under eight seconds at the median, under fifteen at the high percentile. Writing it as a sum rather than as a single figure is what makes it actionable: it shows immediately that tightening one component alone buys nothing.
- **Measure the actual lag, not the configured intervals.** The metric is the elapsed time from the source event's occurrence to the derived write. Configuration tells you what should happen; the metric tells you what does.
- **Alert on it, and page.** This is the important one. A consumer that stops is invisible to every other signal — requests stay fast, errors stay zero, and the data quietly stops updating. Index freshness and projection lag are the only things that surface it.
- **Reconcile.** A periodic sweep re-deriving anything whose derived timestamp predates its source update by more than the budget. That is the backstop for a lost event, and it is the price of choosing incremental maintenance over recomputing from truth each time.
- **Keep it rebuildable.** The derived store holds nothing not derivable from the owner, so the worst case is a rebuild rather than a data loss — and the rebuild is rehearsed, because a mitigation nobody has executed is an assumption.

**Where disagreement is not acceptable.** Anything the user is told is done. A patient's check-in must be durable before the handset says recorded. A connection request must not create two threads or two charges — and that guarantee comes from a unique constraint in the owning store, not from a cache or a queue. The line I draw is between a derived view being behind, which is fine and must be visible, and a fact being uncertain, which is not.

**And the user-facing consequence has to be designed too.** A vendor who publishes and does not immediately see their listing in search will file a bug. Either the interface reflects the write rather than the index for that user's own view, or the delay is communicated. An unexplained inconsistency is a support cost even when it is technically correct.

</details>

---

## 2. Transactions, locking and concurrency

---

### DB-04. Tell me about transactions: the isolation levels, what each one actually prevents, and where a transaction stops being enough.

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

1. **A second datastore.** No transaction spans PostgreSQL and [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), or PostgreSQL and a message broker. This is why both my recent systems use a transactional outbox: the event row commits with the state change, and publication happens afterwards with at-least-once delivery and idempotent consumers. Reaching for a distributed transaction here would buy a coordinator, a new failure mode and worse latency to avoid writing an idempotent handler.
2. **Any external side effect.** Sending an email, charging a card, calling a provider. The database can roll back; the provider cannot. The pattern is a state machine in the database with an attempt row per try — one reminder, many `reminder_delivery` rows each with a channel, a provider message id and a terminal state — so "was it delivered" is a query rather than a log grep, and a retry is safe because the attempt is recorded before it is made.
3. **Anything spanning user think-time.** Holding a transaction open across a user's decision is how you get a frozen table. The answer is optimistic concurrency — a version or revision column checked on write — not a long-lived lock.
4. **Long-running work.** A transaction held open for a large batch pins the oldest snapshot, which blocks vacuum and lets dead tuples accumulate across the whole database. Batch work gets chunked into many short transactions, which is also what makes it resumable.

**And the thing I would add unprompted:** the strongest correctness tools in a relational database are not isolation levels at all, they are constraints. `UNIQUE (retail_group_id, idempotency_key)` is what finally prevents a duplicate connection thread and a duplicate charge, not the retry logic in front of it. `UNIQUE (connection_request_id) WHERE kind = 'connection'` is what makes "a connection bills at most once" a property of the schema rather than a property of everyone remembering. Isolation levels manage contention; constraints decide what states are possible.

</details>


---

### DB-05. Explain optimistic vs pessimistic locking.

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Pessimistic locking takes the lock before doing the work and makes conflicting writers wait; optimistic locking does the work, then checks at commit whether anyone else changed the row, and fails the loser. The choice follows contention and who can retry: low contention with a client that can redo the work favours optimistic, high contention or a client that cannot resolve a conflict favours pessimistic.

<details>
<summary><strong>Detailed answer</strong></summary>

**Pessimistic.** `SELECT … FOR UPDATE` takes a row lock for the rest of the transaction; other writers block. It is the right answer when a conflict is likely, when the work between read and write is short, and when the correct resolution of a conflict is "wait your turn". The costs are real: waiting writers hold connections, lock waits can escalate into a pileup under load, and any lock held across a network call or a user's think-time is a design defect rather than a tuning problem.

**Optimistic.** The row carries a version — an explicit `version` column, an `updated_at`, or PostgreSQL's system `xmin`. The write is `UPDATE … WHERE id = ? AND version = ?`, and an affected-row count of zero means somebody else got there first. No locks are held while the user thinks, so it scales well when conflicts are rare, and it degrades badly when they are not: under heavy contention you spend all your work on retries. Over HTTP this is exactly `ETag` plus `If-Match` returning `412` — the same mechanism surfaced in the protocol so the client can decide what to do.

**Where each one is used in these systems, which is the more interesting half of the question.**

- **Optimistic, expressed as a monotonic guard rather than a version check.** `indexer-worker` upserts `product_listing_facets` keyed on `product_id` and **ignores an event whose `source_revision_id` is older than the row's current value**. That is optimistic concurrency for a projection: redelivery is a no-op and out-of-order delivery cannot roll a listing backwards. A plain version check would reject the stale write with an error; here the correct action is to drop it silently, which is the same idea with a domain-appropriate resolution.
- **Pessimistic, chosen deliberately over optimistic.** [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") updates from the hospital directory serialise per directory object on a Redis lock, `lock:scim:{entra_object_id}`. The reason is not contention — it is that **the client will not resolve a version conflict for you**. Entra ID sends a `PATCH` and expects it applied; returning a `412` and hoping it re-reads and re-applies is not a contract that provider honours. When the counterparty cannot participate in the retry, optimistic locking is not available to you, and that is the cleanest test I know for choosing between the two.
- **The third option people forget: `FOR UPDATE SKIP LOCKED`.** The reminder sweep claims due rows with `SELECT … FOR UPDATE SKIP LOCKED`, which is pessimistic locking with the waiting removed — a worker takes what is free and leaves contended rows to whoever holds them. That is what lets the worker pool scale horizontally without double-dispatch and without a queue of blocked workers, and it is the right primitive for work-claiming specifically.
- **The fourth option: neither.** The best concurrency control is often a constraint. `UNIQUE (patient_id, recorded_for)` with `ON CONFLICT DO UPDATE`, or `UNIQUE (connection_request_id) WHERE kind = 'connection'`, resolves the race in the database with no lock and no retry loop. If the conflict has a correct deterministic resolution, express it as a constraint rather than as a protocol.

**Two details worth adding.** Deadlocks are a pessimistic-locking phenomenon and the practical defence is a consistent lock ordering plus short transactions; PostgreSQL detects them and kills a victim, so the application must be able to retry a serialization failure. And isolation level matters: at `SERIALIZABLE`, PostgreSQL gives you optimistic behaviour for free, aborting transactions whose interleaving was not serialisable — which is elegant, and means every write path needs a retry loop.

</details>


---

### DB-06. A table is frozen — how do you debug the blocking transaction, and what do you put in place so it does not happen again?

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

### DB-07. Tell me about deadlocks in a database — how they arise, how you diagnose one after the fact, and how you design them out.

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

### DB-08. Give an example where two database operations MUST be atomic. When would you deliberately NOT use one large transaction?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The canonical must-be-atomic pair is a state change and the outbox row that announces it: commit them together and "it happened but nobody heard" stops being a reachable state. The deliberate refusal is anything long, anything crossing a network boundary, and anything bulk — because a long transaction in PostgreSQL holds back vacuum and holds locks, so its cost is paid by every other query on the system.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three examples where atomicity is genuinely required.**

1. **The state change and its outbox event.** `vendor-service` updates `product.current_revision_id` and inserts `outbox_event` in one PostgreSQL transaction; the relay publishes afterwards and stamps `published_at`. The alternative — commit, then publish — has a window in which the process dies and the fact exists while the event does not, permanently and undetectably. This is the single most common place people accidentally dual-write, and the outbox exists for exactly this pair.
2. **Deprovisioning a clinician.** When SCIM marks a clinician inactive, the `clinician` row flips **and every open `care_relationship` for that clinician closes in the same transaction**. A partial application here is an access-control failure: the account is disabled but the relationship rows that row-level security joins through are still open, or vice versa. Either half alone is wrong, and the wrongness is a security event rather than a data inconsistency.
3. **A charge and the thing it charges for.** `connection_request` and the `billing_charge` that accrues from it must not diverge — a charge with no connection is a refund conversation, and a connection with no charge is revenue lost silently. Here the design takes an extra belt: the charge is derived asynchronously from the event, and the schema carries `UNIQUE (connection_request_id) WHERE kind = 'connection'` so at-least-once delivery cannot produce two.

**Where I would deliberately not open one big transaction.**

- **Bulk work.** A 20,000-row catalog import is not one transaction. It is chunked into 500-row tasks, rows land in `import_staging`, they are validated against the category's facet schema, and only then are products promoted. That gives per-row error reporting, resumability, and a bounded lock footprint. A single transaction would hold locks for minutes, produce one all-or-nothing verdict with no per-row detail, and roll back an hour of work on row 19,998.
- **Anything crossing a network boundary.** Never hold a transaction open across an HTTP call to another service, a blob upload, or a broker publish. The transaction's duration becomes the remote system's latency plus its failure modes, and a hung call becomes a held lock. The cancer platform's composition path calls `clinical-nlp-svc` from a [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") task with a bounded deadline, entirely outside any database transaction, and writes the result afterwards.
- **Two stores.** The Mongo write and the Postgres commit in the marketplace's publish path are explicitly not one transaction and cannot be. The ordering rule does the work instead: Mongo first, Postgres second, because an orphaned revision document is invisible garbage while a committed pointer to a missing document is a broken listing. A nightly reconciliation sweeps the orphans.
- **Backfills and migrations.** Batched with a keyset cursor and a commit per batch, for the same reasons plus one more: a long `UPDATE` over a large table is an index-maintenance and write-amplification event that competes with live traffic.

**Why long transactions are specifically expensive in PostgreSQL,** which is the detail that turns this from a style preference into an operational argument: an open transaction pins the oldest transaction horizon, so **autovacuum cannot reclaim dead tuples anywhere in the database** for as long as it runs. Bloat accumulates, table and index scans get slower for every other query, and on a replica a long-running read can cause recovery conflicts or force a lag increase. A transaction that holds locks also parks every conflicting writer behind it, and on a 110-million-row partitioned table that is not a local effect. So "keep transactions short" is not tidiness — it is a property the rest of the system depends on.

**The rule I would state.** A transaction should span exactly the set of writes that must be true together, and nothing else. If you cannot name why a second write belongs inside it, it does not.

</details>

---

## 3. Query performance and data access

---

### DB-09. How do you design the indexes for a table — do you start from the schema or from the queries, and what do you do when the planner declines the index you added?

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
- **Time-to-live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"))** in Mongo for staging data that must expire without a job.

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

### DB-10. Walk me through an `EXPLAIN (ANALYZE, BUFFERS)` output. What tells you the plan is wrong rather than merely slow, and what do you do when estimated and actual rows disagree by three orders of magnitude?

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

### DB-11. A list endpoint is paginated and the deep pages are getting slower. What is actually happening, and what do you tell the stakeholder who wants a jump-to-page control?

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

**The stakeholder conversation, which is the real question here.** I would not open with "that is not possible". I would ask what the control is for, because the answer is usually one of three things, and only one of them actually needs page numbers. And when I do explain the cost, I lead with the correctness half rather than the performance half — on a sourcing workflow whose whole purpose is comparing a complete set, silently dropping a row is a defect rather than a rough edge, and that is the argument that lands.

- *"I want to know how many results there are."* That is a count, not a pager. An exact count over a filtered index scan costs about as much as the page itself, so what I would offer is an estimate capped at a threshold — the marketplace returns `total_estimate` and stops counting at 1,000, and the interface shows "1,000+". For a sourcing workflow that is genuinely all the information the number carries.
- *"I want to get to the end / to a specific region of the list."* That is a sort or filter request wearing a pagination costume. Reversing the sort gets you the end in one page. Jumping to "products starting with M" or "notes from March" is a `WHERE` clause, and it is both faster and more useful than page 40.
- *"I want to resume where I was."* That is exactly what a cursor is, and it works better than a page number because it is stable under concurrent writes.

If after all that they still want numbered pages, I would give the trade honestly: it is deliverable over a bounded range — offset pagination capped at, say, the first 1,000 rows, with keyset beyond it — and past that limit the cost is real latency on a query that the rest of the system's budget depends on. I would rather present that as a choice with a number attached than either refuse it or quietly ship something that degrades. The thing I would not do is ship an uncapped offset pager and let it become a production incident six months later, because at that point it is a contract and removing it is a breaking change.

**The general habit underneath this one.** A request for a mechanism is usually the first mechanism that came to mind rather than the requirement. Finding the outcome first costs one question and regularly replaces a hard feature with an easy one.

</details>


---

### DB-12. A query is fast for most callers and pathological for one. How do you approach that?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
That pattern is almost always about selectivity rather than indexing — one caller's parameters produce a wildly different row estimate, so the planner picks a plan that is right for the common case and disastrous for theirs. So I compare plans across parameter sets rather than looking at one.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the shape points at selectivity.** If the query were simply missing an index, everyone would be slow. Fast for most and terrible for one means the plan chosen is appropriate for typical inputs and inappropriate for these. The usual mechanisms:

- **A predicate that is highly selective for most values and unselective for one.** A caller belonging to an organisation with a hundred rows and a caller belonging to one with four million get the same plan, and the nested-loop plan that is optimal for the first is a catastrophe for the second.
- **Correlated predicates the planner treats as independent**, so it multiplies selectivities and drastically underestimates the row count. Common with a category plus an attribute that only occurs in that category.
- **High-cardinality array or containment predicates**, where estimates are genuinely poor and the planner may choose a bitmap combination that degrades toward a scan on an unselective combination.
- **Data skew the statistics do not capture**, because the sample missed a heavy value.

**How I diagnose it.** Capture the actual parameters from the slow caller — not a representative example, the real ones — and get the plan with actual timings for both a typical set and theirs. Then compare estimated against actual rows at each node. A node estimating fifty and producing five hundred thousand is the finding, and everything planned above it was planned on that estimate.

**The fixes, in order.**

1. **Improve the statistics.** Extended statistics for correlated columns, or a higher sampling target on a skewed column. This is the cheapest fix and it fixes the cause rather than the symptom.
2. **Rewrite so the plan cannot go wrong.** Restructure so a selective predicate leads, or split into two queries whose shapes are each predictable. Predictability is often worth more than peak speed here.
3. **A composite or partial index serving the pathological shape**, if it is a recurring class rather than one caller.
4. **Bound the input.** If a caller can construct a query with no viable index, that is a product decision worth taking deliberately — refusing an unbounded combination guarantees a leading index always exists, and stating it as a constraint is more honest than hoping.

**And the operational half.** Once fixed, the plan shape gets asserted in a test if this path's performance is a design property, and the parameter set that broke it goes into the seeded test data — because the next person will otherwise optimise against the common case again and reintroduce it.

</details>


---

### DB-13. When do you drop out of the ORM entirely, and what do you give up?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
When the generated plan is the thing being engineered rather than an implementation detail — which in practice is the two or three queries carrying the traffic. What you give up is identity mapping, change tracking and the object graph, so those queries return rows rather than entities, deliberately.

<details>
<summary><strong>Detailed answer</strong></summary>

**The split I use.** The Object-Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) for domain writes and for anything whose shape follows the object model — that is where the unit of work, the identity map and cascading behaviour earn their cost. Core for the hot reads, because there the question is not "does this return the right rows" but "does the planner choose the index I built for it", and wrapping that in ORM constructs puts a layer between me and the plan for no benefit.

**The two places it happened on these systems.** The catalog search, which is many optional predicates over a projection table with a partial index, a keyset cursor and a deliberate constraint on how many facet predicates a query may carry. And the patient timeline, which is a union across five tables with the limit pushed into each branch and a composite cursor to break ties deterministically. Neither of those is expressible in the ORM without obscuring exactly the parts that matter.

**What you give up, honestly.**

- **The identity map and change tracking.** Core returns rows. If you want to modify something, you go back through the ORM or write the update explicitly. For a read path that is not a loss.
- **Relationship traversal.** You get what you selected. In practice this is a benefit on a hot path, because implicit traversal is where the N+1 comes from.
- **Some portability**, which matters less than people say — the queries where you need Core are usually the ones using engine-specific features anyway, and pretending otherwise is a fiction.
- **Readability for anyone who only knows the ORM.** This is the real cost, and the mitigation is a comment stating the constraint the query is written to satisfy, and a test asserting the plan shape so a well-meant simplification fails loudly.

**What I would not do.** Push it behind a generic repository method that returns a nice object and hides the statement. If the implementation is the design, hiding it is a liability rather than an abstraction. Abstraction pays where the implementation is genuinely interchangeable.

**And I would not start here.** Write it in the ORM, measure, and drop down only where the measurement says so. Most queries never need it.

</details>


---

### DB-14. Beyond N+1, what other query patterns quietly get worse as a table grows?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Offset pagination, exact counts, unbounded `IN` lists, sorts that cannot be served by an index, and anything with a leading wildcard. They all behave perfectly in development and degrade in proportion to data the developer never had.

<details>
<summary><strong>Detailed answer</strong></summary>

**The list, with the mechanism for each.**

- **Offset pagination.** The database produces and discards every skipped row. Page one is instant, page four hundred reads four hundred pages of rows to throw them away. Worse, under concurrent writes the pages shift and rows are duplicated or skipped. Keyset pagination — carry the last row's sort tuple as a cursor — is constant cost per page and stable. This is why both systems use it everywhere and why the timeline cursor is a composite tuple rather than a single column.
- **Exact counts on a filtered set.** `COUNT(*)` with a filter costs roughly what fetching the rows costs, so a paginated list endpoint doing a count plus a page is doing double work to render a number nobody acts on. Capping it — a count-with-limit that reports "1,000+" — is usually what the workflow actually needs.
- **Unbounded `IN` lists.** Batching is the right fix for an N+1, and an unbounded batch is a new problem: a list of ten thousand identifiers produces a very large statement and unpredictable plans. Batches need a cap and a chunking loop.
- **Sorting on something not in an index.** Fine at ten thousand rows, a disk sort at ten million. The tell is a sort node spilling to disk in the plan.
- **A leading wildcard in a text match.** Cannot use a standard index at all. Needs a trigram index or a proper text search.
- **Predicates the index cannot serve because of a function or a cast.** Applying a function to the column, or comparing a column to a value of a different type, silently defeats the index. The plan shows a sequential scan and the query looks correct.
- **`SELECT *` on wide rows**, particularly with large text or binary columns pulled out of overflow storage for rows the caller only wanted two fields from.
- **`DISTINCT` used to paper over a join fan-out**, which forces a sort or hash over the entire multiplied result.

**How I catch these before production.** Seed a table to a realistic size in the integration environment rather than testing against a hundred rows — most of these are invisible below about a million. Assert plan shape on the paths whose performance is a design property. And assert query counts in tests, which catches the N+1 family directly and is the only technique here that keeps working as the code changes.

</details>


---

### DB-15. How do you stop an N+1 regression from coming back six months later?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Assert the query count in a test. Reading code for N+1 works until someone adds a property that touches a relationship, and then it silently does not. A test that fails when a request issues more queries than it should is the only mechanism that survives staff turnover.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why review does not hold the line.** An N+1 is rarely introduced by someone writing a loop with a query in it. It is introduced by adding a computed property to a model, by a serialiser reaching one level deeper, or by a template touching a relationship — all changes that look harmless in a diff and are in a different file from the query. Six months later nobody remembers that the endpoint was optimised.

**The mechanisms that actually work, in order.**

- **Query-count assertions on the endpoints that matter.** Hit the endpoint in a test with a fixture holding several rows, count the statements, assert a bound. The important detail is that the fixture must have more than one row of each collection — with one row an N+1 and a batched fetch produce the same count and the test passes on a broken implementation.
- **Make lazy loading raise.** Configure relationships so that accessing an unloaded one raises rather than quietly issuing a query. This converts the entire class of defect into a loud error at development time. It is the single highest-value setting in this area, and under an asynchronous session it is effectively mandatory anyway.
- **Log statements in development with a per-request count**, so the number is visible while working rather than discovered later. A request issuing forty queries should be obvious to the person writing it.
- **Watch requests per page view in production, not just latency.** The distributed and client-side versions of this problem show perfect server-side percentiles — every request is fast, there are just far too many. A latency dashboard will never show it.

**On the batching side**, the same discipline applies to the non-database versions: a per-item cache lookup becomes a multi-get, a per-item document fetch becomes a bulk query, and a per-row event becomes one batched event. Those need the same kind of assertion, because they are equally invisible in review.

**What I do not rely on.** A comment saying "do not remove this eager load". It will be removed by someone tidying up, in good faith, and nothing will fail.

</details>


---

### DB-16. How do you prove a query optimisation actually worked in production rather than on your laptop — and what would make you revert one that looked faster?

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
- **It made the code substantially harder to reason about for a gain inside the noise.** A 5% improvement that turns a readable query into hand-tuned [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") with a comment explaining why it must not be touched is usually not worth it — and on a project where quality is valued over speed, that argument lands.

**And the thing I would set up so the next person does not have to ask.** A dashboard panel per hot query, with the deploy timeline overlaid. Most "did this help" arguments are unanswerable because nobody recorded the before.

</details>

---

## 4. Migrations and backfills

---

### DB-17. A table has to change shape while it is being read and written in production. How do you sequence that, and what makes a migration dangerous rather than merely slow?

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

### DB-18. You are reviewing someone else's migration an hour before a release. What do you look for, and what would make you block it outright?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Lock strength and duration first, then reversibility, then whether the previous application image can still run against the new schema. I block outright on anything that takes a long `ACCESS EXCLUSIVE` lock on a hot table, any unbounded `UPDATE` or `DELETE`, any destructive change landing in the same release as the code that stops using it, and any migration nobody has run against a production-sized dataset.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checklist, in the order I read the file.**

1. **What lock does each statement take, and for how long?** I read every `ALTER` and ask which mode it needs. A column type change, an added `CHECK` or foreign key without `NOT VALID`, a `SET NOT NULL` without a prepared constraint, a non-`CONCURRENTLY` index — each of these blocks the table for a scan or a rewrite. On a small table nobody notices; on the hot one it is an outage.
2. **Is there a `lock_timeout`?** Without one, the migration waits indefinitely for the current readers and builds a queue behind itself. With one, it fails fast and retries. This is the single highest-value line in a migration file and it is almost always missing.
3. **Is the data change bounded?** An `UPDATE` with no `WHERE` on a large table is a long transaction, a write-ahead log flood, a vacuum blocker and a replication risk in one statement. I want batching with a bound and a resume point.
4. **Is it backwards-compatible with the currently-running image?** This is the question that decides whether rollback exists. If the old pods cannot serve traffic against the new schema, then the moment the migration lands the only way out is forward, at the worst possible time. I ask the same question from the other side too: is the rollback a redeploy, or does it need a down-migration? If it needs one, I want to know who would run it under pressure and whether it has ever been tested. Usually the answer to both is no, and the right fix is to restructure the migration rather than to write a better down step.
5. **Does the destructive half ship separately?** A dropped column in the same merge request as the code that stopped reading it means the rollback of that code is now broken. Contract is a later release, deliberately.
6. **Is it idempotent and resumable?** If it dies at 60%, what happens when it is re-run? A migration that is only correct from a clean start is a migration that will be run twice.
7. **Has it been run against production-sized data?** "It took two seconds on my machine" is not information about a 110-million-row table. If the answer is no, the duration is unknown, and an unknown duration on a lock is the definition of a dangerous change.
8. **What does it do to the replicas?** WAL volume, replication slot pressure, and whether replica lag will breach its alert threshold during the run.
9. **Does it run as the right role?** Migrations under an owning role that never serves a request; the application role holds no schema privileges. On the cancer platform this also matters for Row-Level Security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")), where the application role must be `NOSUPERUSER` without `BYPASSRLS` — a migration that quietly grants a privilege to the application role would disable the strongest control in the system.
10. **Does it touch anything security-relevant?** A policy, a grant, a constraint that an authorization rule depends on. Those get read twice regardless of the clock.

**One reviewing habit worth stating.** I read the generated statements, not the migration framework's shorthand. A one-line instruction to alter a column can emit something very different from what the author intended, and the emitted statement is the thing the database will execute.

**What blocks it outright.** Any of: an unbounded rewrite or scan under `ACCESS EXCLUSIVE` on a hot table; a `DROP` or a destructive type change in the same release as the code change; an unbatched data migration on a large table; a migration that has never been run against realistic volume; or a change that makes the previous image unable to run. I would also block a migration that has no plan for what happens if it fails halfway, because "we will work it out" at that point means an improvised `UPDATE` in production.

**What does not block it, but gets written down.** A slow but safe migration — say a `CONCURRENTLY` index build that will take forty minutes — is fine; it just needs to be known, started early, and not be something anyone is waiting on. Slow is a scheduling problem. Dangerous is a correctness problem.

**How I would say it.** Naming the specific statement and the specific lock, with the alternative attached — "`ALTER TABLE ... ALTER COLUMN TYPE` rewrites the table under `ACCESS EXCLUSIVE`; add a new nullable column, backfill in batches, switch reads next release" — is a review someone can act on in the hour available. "This looks risky" is not, and an hour before a release the difference matters. If the alternative genuinely cannot be built in the time, then the honest recommendation is to pull it from the release rather than to approve it with a caveat nobody will read.

</details>


---

### DB-19. A backfill on a very large table has to be stopped halfway. What does that demand of how you wrote it?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
That it is resumable from its own recorded progress, idempotent per batch, throttled by an observed signal rather than a fixed sleep, and safe to leave permanently half-done — because the release must be correct whether the backfill finished or not.

<details>
<summary><strong>Detailed answer</strong></summary>

**The last point is the one people miss, so I will start there.** If the application depends on the backfilled column being fully populated, then stopping halfway means the system is in an invalid state and someone is under pressure to restart it immediately. The design that removes that pressure is expand-and-contract: the column is added nullable, the code writes it going forward and does not require it, and only a later release — after the backfill has verifiably completed — starts reading it as guaranteed present. Then a paused backfill is an inconvenience rather than an incident.

**What resumability actually requires.**

- **Progress recorded durably, in the database, not in the job's memory.** A cursor row naming the last completed key or partition, committed with each batch. Then restarting is reading the cursor and continuing, and it does not matter whether the job stopped cleanly or the pod was killed.
- **Batches bounded by key range rather than by offset**, so a restart does not rescan what is already done and so each batch's cost is predictable.
- **Idempotent batches.** A batch that partially applied before dying must be safe to re-run. Writing it as an update conditional on the current value achieves that, so re-running is a no-op on rows already done.
- **Commit per batch**, never one long transaction. A single transaction over a hundred million rows holds locks for its whole life, accumulates enormous undo, and cannot be interrupted at all.

**Throttling by signal, not by sleep.** A fixed pause between batches is a guess that is wrong at both ends — too slow on a quiet night, too aggressive during a peak. Reading replication lag, or lock wait counts, and pausing when they exceed a threshold means the job adapts. It also means the job stops on its own during an incident rather than needing a human to remember it exists.

**Operational properties I would want.** A kill switch that does not require a deploy — a flag the job checks between batches — so stopping it is a configuration change rather than a rollout. Progress and estimated remaining time as metrics, so the question "how far through is it" is answerable without asking me. And a verification query at the end that asserts zero remaining rows, before anything depends on completeness.

**The rehearsal.** Run it against a realistic copy first, and stop it halfway on purpose, and restart it. That turns the duration into a measurement and turns resumability from a property I believe I implemented into one I have observed.

</details>


---

### DB-20. A migration failed halfway on production. What now?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First establish what actually applied, because the framework's version table and the real schema can disagree. Then stop the deploy, decide roll-forward or roll-back on whether the previous image runs against the current schema, and only then touch anything.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: stop making it worse.** Halt the deploy so no further revisions run, and stop any automated retry. A migration retried blindly against a partially applied state is how a recoverable situation becomes a bad one.

**Step two: find out the real state.** Two questions with different answers: what does the migration framework's version table say, and what does the schema actually contain? They diverge in exactly the case that matters — a statement that ran outside a transaction, such as a concurrent index build, or a script with several statements where one committed and a later one failed. Inspect the schema directly. A concurrent index build that failed leaves an invalid index behind that must be dropped before a retry, and this is the single most common version of this incident.

**Step three: is the system currently serving?** Usually yes, because expand-only migrations do not break the running image. That converts an emergency into a problem with time attached, and it is the main reason I hold the expand-and-contract rule as a rule.

**Step four: decide direction.**

- **Roll forward** if the remaining steps are safe and the failure was environmental — a lock timeout, a transient error, a resource limit. Fix the cause, drop any invalid artifact, re-run. This is the usual outcome.
- **Roll back the application** to the previous image if the new code needs schema the migration did not deliver. Because the migration was expand-only, the old image runs against the partial schema, and this is why the discipline exists. Then fix the migration properly and try again in a normal release rather than under pressure.
- **Reconcile the version table by hand**, carefully and with someone watching, if it disagrees with reality. Marking a revision applied when it is not is a decision to make deliberately and to write down, because the next person will trust that table.

**Step five: afterwards.** Why did it fail here and not in the rehearsal? Almost always the answer is production traffic — a lock wait, a size difference, a timeout. That belongs in the migration itself as a lock timeout with retries, in a bounded and resumable backfill, and in a rehearsal on a realistic copy next time.

**What I would not do.** Run an ad-hoc fix directly against production without it going through a migration, because the schema then stops matching the code that describes it and the next deploy is a surprise. If an emergency statement is genuinely needed, it gets written as a migration immediately afterwards.

</details>


---

### DB-21. A schema change has to be rolled back after the new code is already live. What does that demand of how the migration was written in the first place?

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

### DB-22. You have to write a migration against a database engine whose locking behaviour you do not know. How do you proceed safely?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Assume nothing transfers about locking, and establish it empirically before touching production: read the engine's own documentation on the specific operation, then rehearse against a realistic copy while watching what actually blocks. The process discipline transfers completely; the engine specifics do not.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why locking specifically is the thing not to assume.** Almost everything else about a migration is reasoning that carries across engines — batching, resumability, expand-and-contract, keeping the previous application version runnable. Locking is different because it is where engines genuinely diverge, and because the consequence of being wrong is not a slow query but a stalled table. An operation that is online on one engine takes an exclusive lock on another, and the difference is invisible in the statement's syntax.

**What I would establish before writing anything.**

- **Which operations are online for this engine and version.** Adding a column, adding an index, adding a constraint, changing a type — each with a documented lock level. Version matters: the answer changes between releases and the documentation is version-specific for a reason.
- **Whether a lock request queues behind existing transactions and blocks everything behind it.** This is the failure that surprises people on any engine: a statement needing a brief exclusive lock waits for a long-running read, and every subsequent query queues behind the waiter. A migration that should take milliseconds stalls the table. If the engine has this behaviour, every migration needs a short lock timeout with retries so it gives up rather than becoming a traffic jam.
- **Whether there is concurrency control that lets readers proceed during a write**, because that determines whether a backfill is disruptive or merely slow.
- **Whether the schema change is transactional.** If it is not, a failure leaves a partially applied state and the migration must be written to detect and clean up whatever artifact it leaves behind.

**Then rehearse, on a copy at realistic scale, watching the right thing.** Not just how long it takes — what it blocked while it ran. Run representative read and write traffic against the copy during the migration and observe whether that traffic stalls. The duration is a number I can plan around; the blocking is the thing that decides whether it can run at all during traffic.

**What I write regardless of engine.** Bounded, resumable, restartable batches. Expand-and-contract so the previous image runs against the new schema and rollback is a redeploy. No data backfill inside the schema migration. A verification query before proceeding to the constraining step. And a written answer to what happens if it must be stopped halfway, agreed in advance rather than at two in the morning.

**And I would ask.** Whoever has run migrations on this system before knows the three things that are not in the documentation. Twenty minutes with them is worth more than a day of reading, and not asking is a way of protecting your ego at the client's expense.

</details>

