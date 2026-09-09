# Technical — Extended Questions & Answers

> Generated as a continuation of the original question set. Same interviewer style, new angles.
> Weighted toward the client brief in `candidate-profile.txt`.

## Questions by project

- **cancer-support-platform** — Q14, Q16, Q18, Q20, Q22–Q30, Q33–Q46, Q48, Q50–Q68, Q70–Q76, Q78–Q88
- **banking-software-marketplace** — Q14, Q16–Q18, Q20, Q23–Q33, Q38, Q39, Q41, Q46–Q54, Q56, Q58–Q68, Q70–Q76, Q78–Q83, Q86, Q88–Q90
- **general** — Q15, Q19, Q21, Q69, Q77

## Contents

- [FastAPI, Pydantic and Optimising a Synchronous Stack](#fastapi-pydantic-and-optimising-a-synchronous-stack)
- [SQLAlchemy, SQL and Migrations on Very Large Tables](#sqlalchemy-sql-and-migrations-on-very-large-tables)
- [Data Access, API Shape and the N+1 Family](#data-access-api-shape-and-the-n1-family)
- [RabbitMQ, Celery and High-Volume Message Work](#rabbitmq-celery-and-high-volume-message-work)
- [Search, Elasticsearch and the ELK Stack](#search-elasticsearch-and-the-elk-stack)
- [Caching, Redis and Read Paths](#caching-redis-and-read-paths)
- [Identity, Authorization and API Contracts](#identity-authorization-and-api-contracts)
- [Cloud Infrastructure, Kubernetes and Delivery](#cloud-infrastructure-kubernetes-and-delivery)
- [Terraform, CI/CD and GitOps](#terraform-cicd-and-gitops)
- [Code Quality Gates and the Toolchain](#code-quality-gates-and-the-toolchain)
- [Testing: Pytest, Test Management and Coverage](#testing-pytest-test-management-and-coverage)
- [Containerization and the Local Stack](#containerization-and-the-local-stack)
- [Observability and Production Diagnosis](#observability-and-production-diagnosis)
- [Enterprise Resource Planning and Retail Domain](#enterprise-resource-planning-and-retail-domain)

---

## FastAPI, Pydantic and Optimising a Synchronous Stack

---

### Q14. How do you size workers, threads and connection pools for a deployed service, and which of those constraints actually binds?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Work backwards from the database's connection limit, because that is the constraint that binds in practice. Workers per pod times connections per worker times replicas has to stay under it, and everything else — thread pool size, autoscaler bounds — is chosen inside that budget.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the database limit is the real ceiling.** Every other number is elastic. The autoscaler will add pods, each pod starts its workers, and each worker opens its pool. Nobody notices until a spike, at which point the autoscaler cheerfully starts pods that cannot connect, and the failure presents as a database problem with every application dashboard green. So the budget is computed first and everything else is fitted to it.

**The arithmetic, and where people get it wrong.** Maximum pool size per worker, times workers per pod, times the maximum replica count — plus the workers, the migration job, and any analytics or administrative client that shares the same instance. That last group is what is usually forgotten, and it is what consumes the headroom during an incident when someone opens a session to look at something.

**What to do when the numbers do not fit.**

- **Shrink the per-pod pool rather than raising the limit.** A pod serving asynchronous handlers genuinely needs a small pool, because connections are held only while a query is in flight. Generous pools per pod are a habit from synchronous deployments.
- **Put a pooler in front in transaction mode**, which multiplexes many client connections onto few server ones. The caveat is important: transaction-mode pooling breaks anything relying on session state, which includes session-scoped settings used for authorization — a control that becomes its exact opposite when one caller's identity survives into the next request's query.
- **Cap the autoscaler's maximum deliberately**, so the scaling ceiling and the connection budget are the same decision rather than two.

**The thread pool.** In a service with any synchronous handlers, the pool size is the concurrency limit for those paths, and it consumes connections too. Too small and requests queue invisibly; too large and you have threads contending for the interpreter and a connection budget blown. It is derived, not defaulted.

**Workers per pod.** I prefer one, with the replica count owned by the orchestrator. Two layers of scaling that do not know about each other is a bad combination, and one process per container makes the memory limit meaningful and the metrics attributable.

**And I instrument pool wait time as its own metric.** Time spent waiting to acquire a connection is invisible in query latency and is exactly what saturation looks like. Without it, the diagnosis is guesswork; with it, it is a five-second answer.

</details>

---

### Q15. You are asked to migrate a synchronous FastAPI service to async. How would you sequence it, and when would you refuse?

**Project:** general

**Brief answer**
All the way down or not at all — async session, async driver, async repositories, async handlers — because a partial migration is strictly worse than the synchronous version. And I would refuse when the bottleneck is not concurrency at all, which it usually is not.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, establish that it is the answer.** Async concurrency helps a request that spends its time waiting. It does nothing for a request doing forty-five seconds of work, and nothing for a request issuing thirty queries. So before proposing the migration I want a trace breakdown per endpoint: time in the database, time in outbound calls, time in Python. If the time is in query count or in the plan, the migration is a large risky project that will not move the number, and saying so is more valuable than doing it.

**When it genuinely is the answer.** Handlers that spend most of their time waiting on input and output, high concurrency, and a connection or thread budget that binds because each synchronous request holds a worker for its whole duration.

**Why partial is worse than none.** Declaring a handler `async def` while it still calls a synchronous driver moves the blocking from a thread pool, where it is contained, onto the event loop, where it stalls every other request that worker is serving — including the health probe. The synchronous version was safe and bounded; the half-migrated one is neither. So the migration propagates: an async session implies an async driver, which implies async repositories, which implies async services, which implies async handlers.

**The sequencing I would use.**

1. **Get the blocking work out first**, onto a queue. This is worth doing regardless, it reduces the surface being migrated, and it frequently removes the need for the migration.
2. **Introduce the async driver and session alongside the existing one**, so both exist during the transition.
3. **Migrate by vertical slice** — one router with its services and repositories, end to end — rather than by layer. A layer-wise migration leaves a boundary where async calls synchronous, which is precisely the unsafe state.
4. **Set relationships to raise on lazy access before migrating**, not after. Under an async session an implicit lazy load raises anyway; discovering that during the migration means debugging it at the worst time, whereas turning it on beforehand surfaces every site while the code still works.
5. **Move the blocking calls that genuinely cannot be removed into a bounded thread pool.** The bound is the point — an unbounded offload just moves the queue somewhere invisible.
6. **Load test each slice**, because the failure mode is a single overlooked blocking call and it will not show up under low concurrency.

**When I would refuse outright.** If the team is not going to maintain the discipline afterwards. One synchronous call added later reintroduces the whole failure mode, silently, and it will be added by someone acting reasonably. Without the linting and the lazy-load setting to catch it, the migration buys a fragile system in exchange for a robust one.

</details>

---

### Q16. The same data arrives over HTTP, from a broker, and from a bulk import. Where does validation belong?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
At every boundary where data enters the process, including the broker — a message is untrusted input regardless of transport. What differs is the cost model: per-request validation is free at request scale and expensive at import scale, so the bulk path validates once at the edge and works with plain structures internally.

<details>
<summary><strong>Detailed answer</strong></summary>

**The rule: the boundary, not the transport.** It is tempting to treat a message from your own broker as trusted because it came from inside the estate. It is not: it may have been published by an older version of a producer, by a device on a lossy connection, or by a producer whose schema changed. On the health platform, check-ins arrive from patient handsets over a publish-subscribe transport and are validated against a typed model on the consumer side for exactly that reason. A device is untrusted input whatever protocol it speaks.

**What differs between the three paths.**

- **The request path.** Validate the whole body into a typed model. The cost is irrelevant at one body per request, and the payoff is a structured error naming the offending field, which is what makes an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") usable.
- **The message path.** Validate the envelope into a typed model too, but the failure handling is completely different. A request can return a 400 to a caller who will fix it; a message has nobody to tell. So an invalid message must dead-letter after bounded attempts rather than being retried forever, and the dead-letter has to be monitored — a poison message looping is capacity consumption that looks like healthy throughput.
- **The bulk path.** A twenty-thousand-row import validated as twenty thousand rich model instances at every stage is real cost for no additional safety. Validate each row once at the edge, collect the failures rather than aborting on the first, and work with plain structures through the batching and writing stages. And the response has to be per-row: a bulk operation that fails wholesale on one bad row is unusable, because the caller cannot make progress.

**What must never be skipped anywhere.** Anything crossing a trust boundary, and anything where the field decides authorization or money. Types on those come from the model, and the model is the same one wherever the data enters, so there is one definition rather than three that drift.

**Where validation must not live.** In a validator that queries the database. That turns parsing into an N+1 and it runs before any authorization has been applied, so it is also a way to probe for existence. Cross-record checks belong in the service layer, after the caller's scope is known.

**And the response side.** A declared response model is not decoration — it is what stops an internal field leaking into an API response. That is a security property, and it is the one reason I would keep response models on an endpoint whose input was already validated.

</details>

---

### Q17. Six services and three worker pools share a lot of code. How do you avoid building a distributed monolith?

**Project:** banking-software-marketplace

**Brief answer**
Share the boring things and duplicate the domain. A shared library for logging, tracing, authentication middleware and typed configuration is fine; a shared domain model or a shared database access layer couples releases and is how independent services stop being independent.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I apply: does sharing this force a coordinated release?** If updating the library means every service must redeploy together, the services are one deployable with extra network hops — all the operational cost of a distributed system and none of the independence.

**What is safe to share.**

- **Cross-cutting infrastructure.** Structured logging setup, trace propagation, the authentication middleware and token validation, health probes, typed configuration loading. These change rarely, they are not domain logic, and a version lag between services is harmless.
- **Client stubs generated from a service's published contract**, versioned with that contract. Generated rather than hand-written, so the contract remains the source of truth.
- **Test utilities and factories.**

**What is not.**

- **Domain models.** A shared entity means two services agree on a shape, and now a change for one is a change for both. Each service should own its own representation of a concept, even where they overlap — the duplication is the price of independence and it is usually a good trade.
- **A shared data access layer over a shared database.** This is the strongest form of coupling there is, and it is the one that always arrives by accident. Each service owns its tables. Another service asking for that data gets an API or an event, not a query.
- **A shared library containing business rules.** The rule then lives nowhere in particular and changing it means a coordinated release of everything.

**What keeps it honest mechanically.** Import rules in the linter declaring the layer graph and failing the build on a back edge, because nothing in Python prevents a domain module importing the database session — without that check, the architecture degrades into a folder naming convention within about two sprints. Separate schemas per owning service with permissions enforcing it, so a cross-service query fails rather than works. And versioning the shared library properly with services able to lag, so an upgrade is per service rather than a fleet operation.

**The signal that it has gone wrong.** A change that requires touching four repositories, or a deploy order that matters. Either of those means the boundaries are in the wrong place, and the honest response is either to fix the boundary or to admit that these should be one deployable — which for a system at this traffic level would be a defensible answer rather than a defeat.

</details>

---

### Q18. How do you decide between a background task in the web process, a task queue, and a scheduled sweep?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By whether losing the work is acceptable. An in-process background task dies with the process and has no retry, so it is only ever right for something genuinely disposable. Anything the system owes gets a queue; anything time-based gets a scheduled sweep over durable state.

<details>
<summary><strong>Detailed answer</strong></summary>

**In-process background work.** [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") can run a coroutine after the response is sent. It shares the process, so it competes for the same event loop, it dies if the pod is rescheduled, and there is no retry, no visibility and no dead-letter. That makes it acceptable for exactly one category: work whose loss is invisible and harmless, such as a best-effort cache warm. Every time I have seen it used for something that matters — sending an email, writing an audit row — it has eventually lost work during a deploy, and the loss was silent.

**A task queue** is the default for anything the platform owns and must complete: imports, indexing, notification decisions, document processing. What it buys is retry with a bounded attempt count, a dead-letter destination, workers that scale independently of the web tier, and visibility of the backlog. The cost is a broker and a second deployment shape, which is worth it the moment the work matters.

**A scheduled sweep over durable state** is the right answer for anything time-based, and it is underrated. Reminders are not queued when they are created; they are rows with a due time, and a periodic task claims the due ones with a row-level lock that skips already-claimed rows, so multiple workers can run without double-dispatching. That is more robust than scheduling a delayed message, because the state of the world is in the database rather than in the broker — if the broker is rebuilt, nothing is lost, and a bug can be fixed and the sweep will pick up what it missed.

**The rule.** Work that has an owner and a deadline lives in the database; the queue moves it. If the only record that something needs doing is a message in flight, then the broker has become a database with no query interface and no backup.

**And the seam between the two brokers**, since both systems have two: the task queue moves work between processes we own, and the service bus moves events across a boundary to something we do not own. Collapsing them either way puts one system in a role it is bad at.

</details>

---

### Q19. Response times get worse under concurrency but the database looks idle. Walk me through the diagnosis.

**Project:** general

**Brief answer**
That combination almost always means requests are queuing on something with a fixed width — an event loop blocked by a synchronous call, a saturated thread pool, or an exhausted connection pool. The database being idle is the clue: nothing is working, everything is waiting.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the shape tells you.** Latency rising with concurrency while the downstream is idle means the bottleneck is in the process, and it is a queue rather than slow work. Three candidates, and they are distinguishable.

**1. A blocking call on the event loop.** The signature is that every endpoint on that worker degrades together, including trivial ones and the health probe, and processor use is moderate rather than pinned. Confirmation: enable the loop's debug mode or an equivalent slow-callback warning, which names the coroutine that held the loop. Common culprits are a synchronous database driver in an async handler, a synchronous [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client, a lazy-loaded relationship firing a query, and a large parse or crypto operation.

**2. A saturated thread pool.** If handlers are synchronous, concurrency is capped at the pool size and request N+1 waits for a slot. The signature is a hard plateau in throughput with latency rising linearly beyond it — a queue, textbook shape. Confirmation is comparing in-flight requests against the configured pool size.

**3. Connection pool exhaustion.** Time is spent waiting to acquire a connection, not executing a query, which is precisely why the database looks idle — it has few active sessions because the application cannot get to it. Confirmation: instrument pool wait time as its own metric, or look at pool checkout counts against the maximum. This one is easy to misdiagnose as a database problem and the fix is often the opposite of the instinct — fewer, better-used connections rather than more.

**What I look at, in order.** A trace with spans for connection acquisition, query execution and outbound calls, because that separates waiting from working immediately. Then in-flight request count against the concurrency limits. Then, if it is still unclear, a stack sample of the workers under load — a profiler that shows where threads actually are will show the whole pool parked in the same place.

**What I would not do first.** Add replicas. If the constraint is per-process concurrency, more replicas help; if it is the connection limit, more replicas make it strictly worse, and you have now changed two things while the graph moves.

</details>

---

### Q20. An endpoint has to write to two stores. How do you handle partial failure?

**Project:** banking-software-marketplace, cancer-support-platform

**Brief answer**
Never with two writes in one request hoping both succeed. One store owns the fact and is written transactionally; everything else is driven from that write through an outbox, so a failure leaves an unpublished row that drains on recovery rather than a fact that half happened.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the obvious approach fails.** Write to the database, then publish an event, then update the cache. If the process dies between the first and second, the fact exists and nothing downstream knows. If the publish succeeds and the commit rolls back, downstream knows about something that never happened. There is no ordering of two independent writes that is safe, and the failure is silent in both directions.

**The transactional outbox.** The fact and a row describing the event it should produce are written in one transaction, so they cannot disagree. A relay reads unpublished rows, publishes them, and only then marks them published. If the broker is unavailable, rows accumulate and drain on recovery. If the relay dies after publishing but before marking, the event is delivered twice — which is why every consumer is idempotent, and why at-least-once is the honest guarantee rather than exactly-once.

**Ordering when two stores are both genuinely written.** On the marketplace a listing publish writes the immutable revision document to the document store first, then in one relational transaction updates the current-revision pointer and inserts the outbox row. The order is deliberate: an orphaned revision that nothing points at is invisible and reclaimable, whereas a committed pointer to a missing document is a broken listing. The general rule is to write the referenced thing before the reference, so the failure leaves garbage rather than a dangling pointer.

**What makes the whole arrangement work.** One owning store per fact, and every derived store — the search index, the projection, every cache — rebuildable from it. That is what makes the recovery procedures honest rather than aspirational, and it is why the index is never written from a request handler: single-writer is what makes drift impossible rather than unlikely.

**The monitoring it requires.** The age of the oldest unpublished row, alerted on. A stalled relay is completely silent otherwise — every request succeeds, latency is flat, and the downstream world just stops updating.

**And what I would not reach for.** A distributed transaction across two heterogeneous stores. The coordination cost and the failure modes are worse than the problem, and the outbox gives you the property that actually matters — no fact without its event — with mechanisms that fail in ways you can reason about.

</details>

---

## SQLAlchemy, SQL and Migrations on Very Large Tables

---

### Q21. You have to write a migration against a database engine whose locking behaviour you do not know. How do you proceed safely?

**Project:** general

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

---

### Q22. A backfill on a very large table has to be stopped halfway. What does that demand of how you wrote it?

**Project:** cancer-support-platform

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

### Q23. What makes a migration dangerous, and how do you review someone else's?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Two things: a lock held long enough to stall traffic, and a change the previously deployed image cannot run against. I review for those before I read anything else, because a migration is the one change in a release that is genuinely hard to undo.

<details>
<summary><strong>Detailed answer</strong></summary>

**The dangerous operations, and what I look for.**

- **Anything that rewrites the table.** Adding a column with a volatile default, changing a column's type, adding a non-null constraint in one step. On a large table these hold an exclusive lock for the duration of a full rewrite.
- **An index built without the concurrent option.** Blocks writes for the whole build.
- **A lock taken behind a queue.** This is the subtle one people miss: a statement needing a brief exclusive lock has to wait for existing transactions, and while it waits, every subsequent query queues behind it. A migration that would have taken milliseconds takes down the table because one long-running read was in flight. The mitigation is a short lock timeout with retries, so the migration gives up rather than becoming a traffic jam.
- **A change the old image cannot tolerate.** Dropping or renaming a column that the currently running version still selects. During any rolling deploy, both versions are live.
- **A data migration inside a schema migration.** Backfilling a hundred million rows in the migration script means the deploy is blocked on it and it cannot be throttled or resumed.
- **A migration that is not idempotent or not resumable**, which matters because it will be interrupted at some point.

**What I check on a review, in order.**

1. Is it expand-only? If it drops or renames anything, it does not go out with the code that stops using it.
2. Does the previous image run against this schema? If I cannot answer yes immediately, that is the whole review.
3. What locks does each statement take, and for how long on the real row count? Not on the developer's copy.
4. Is there a data backfill hiding in it?
5. Is the rollback a redeploy, or does it need a down-migration? If it needs one, I want to know who would run it under pressure and whether it has ever been tested. Usually the answer to both is no, and the right fix is to restructure the migration rather than to write a better down step.
6. Has it been run against a realistic copy, and how long did it take?

**One reviewing habit worth stating.** I read the generated statements, not the migration framework's shorthand. A one-line instruction to alter a column can emit something very different from what the author intended, and the emitted statement is the thing the database will execute.

</details>

---

### Q24. A query is fast for most callers and pathological for one. How do you approach that?

**Project:** cancer-support-platform, banking-software-marketplace

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

### Q25. When do you drop out of the ORM entirely, and what do you give up?

**Project:** cancer-support-platform, banking-software-marketplace

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

### Q26. Explain how you manage a SQLAlchemy session's lifetime in a web application, and what goes wrong when you get it wrong.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
One session per request, opened and closed by a dependency, with the transaction boundary at the unit of work rather than per statement. The failures are a session shared across concurrent requests, a session held open across a slow external call, and objects used after the session has closed.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape.** A session factory at application startup, a dependency that yields a session per request and closes it afterwards including on an exception, and an explicit commit at the end of the successful path. Handlers do not commit individually — the request is the unit of work, so a partial write cannot survive a later failure in the same request.

**What goes wrong.**

- **A session shared between requests or tasks.** A session is not safe for concurrent use. A module-level session, or one captured in a closure and reused, produces symptoms that look like data corruption and are genuinely hard to trace, because two requests interleave on one connection.
- **Holding a transaction open across a slow call.** A handler that opens a transaction, calls an external service, waits three hundred milliseconds and then writes has held a connection and a set of locks for the whole call. Under load that exhausts the pool and creates lock contention that looks like a database problem. The transaction should be as short as the work that has to be atomic.
- **Detached instance access.** Touching an attribute after the session closed raises, or worse, quietly re-queries in a synchronous stack. The fix is to convert to the response model inside the request, which is what a response model does for you anyway.
- **Lazy loading in a loop.** The classic N+1. Setting relationships to raise on lazy access turns it into a loud error at development time instead of a silent extra query per row in production. Under an asynchronous session it raises anyway, because implicit input/output on the event loop is not permitted — one of the rare cases where the runtime enforces the discipline for you.
- **`expire_on_commit` surprises.** Attributes accessed after a commit re-fetch by default, which is a hidden query at exactly the moment you thought you were done.

**Sessions outside the request.** A worker task creates its own session with its own lifetime and does not inherit anything from a request context. Sharing an engine is fine; sharing a session is not. Each task is its own unit of work, which is also what makes retries safe.

**The one setting that is not about sessions but always comes up with them.** The pool size per process, multiplied by processes and replicas, against the database's connection limit. That is the constraint that actually binds in production, and it is discovered during a spike if it is not calculated in advance.

</details>

---

### Q27. A migration failed halfway on production. What now?

**Project:** cancer-support-platform, banking-software-marketplace

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

## Data Access, API Shape and the N+1 Family

---

### Q28. Beyond N+1, what other query patterns quietly get worse as a table grows?

**Project:** cancer-support-platform, banking-software-marketplace

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

### Q29. How do you stop an N+1 regression from coming back six months later?

**Project:** cancer-support-platform, banking-software-marketplace

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

### Q30. When is it right to let two stores disagree, and how do you keep that from being a bug?

**Project:** banking-software-marketplace, cancer-support-platform

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

### Q31. A stakeholder asks for a jump-to-page control on a large filtered list. What do you tell them?

**Project:** banking-software-marketplace

**Brief answer**
That it is buildable and it is usually the wrong thing to want, because arbitrary paging costs more the deeper you go and gives incorrect results under concurrent writes. Then I ask what they are actually trying to do, because the answer is nearly always better filtering.

<details>
<summary><strong>Detailed answer</strong></summary>

**The two costs, stated plainly rather than as a refusal.**

- **Cost grows with depth.** Skipping to page four hundred means the database produces and discards four hundred pages of rows. Page one is instant and page four hundred is not, and the pattern is that the feature is fine in testing and slow in production, because nobody tests page four hundred.
- **It is incorrect under writes.** If a row is inserted while someone pages, everything shifts by one, and they see a row twice or never see it. On a sourcing workflow whose whole purpose is comparing a complete set, silently dropping one is a real defect rather than a rough edge — and it is the argument that usually lands, because it is about correctness rather than about performance.

**Then the question underneath.** People ask for page jumps for a small number of reasons, and each has a better answer: they want to get to the end (sort descending), they want a specific item (search or filter), they want to resume where they were (a saved cursor or a link), or they want a sense of how much there is (a count, which can be an estimate). Only one legitimate use survives, which is a human systematically working through a large set over days — and that needs a saved position and a stable ordering more than it needs page numbers.

**What I offer instead.** Keyset pagination with next and previous, so cost is constant per page and the sequence is stable under writes. A capped total estimate rather than an exact count, because an exact count over a filtered scan costs about as much as the page itself and "1,000+" is what a sourcing workflow actually needs. And better filtering and sorting, which is what genuinely reduces a large result set to a usable one.

**If they still want it after that**, which is legitimate, then it is a decision with a cost attached rather than a misunderstanding. I would implement it bounded — page jumps available within the first N pages, beyond which the interface requires narrowing — and say clearly what the bound is and why. Bounding it is what keeps a rare workflow from becoming an unbounded query anyone can issue.

**The general habit.** A request for a mechanism is usually the first mechanism that came to mind rather than the requirement. Finding the outcome first costs one question and regularly replaces a hard feature with an easy one.

</details>

---

### Q32. A bulk endpoint takes a list of identifiers. What failure modes do people miss?

**Project:** banking-software-marketplace

**Brief answer**
An unbounded list, partial failure with an all-or-nothing response, losing the ordering the caller sent, and silently dropping identifiers the caller may not access — which turns an authorization boundary into an enumeration oracle if it is done inconsistently.

<details>
<summary><strong>Detailed answer</strong></summary>

**The failure modes, in the order they bite.**

- **No cap on the list.** A batch endpoint added to fix an N+1 becomes a way to ask for fifty thousand objects in one request. That is an unbounded query, an unbounded response and a denial-of-service primitive handed to any authenticated caller. The cap is part of the contract and it is validated, not hoped for. The comparison endpoint on the marketplace takes between two and five products for exactly this reason — the bound comes from the product requirement, which is the best kind of bound.
- **Partial failure with no partial result.** Forty-nine of fifty found, one missing, and the whole request returns an error. The caller has no way to make progress. The response should be per-item: what was found, what was not, and why, with an overall status that says the request itself succeeded.
- **Order and duplicates.** Callers frequently assume the response is in the order they sent, and a bulk query returns whatever the database returns. Either key the response by identifier — which I prefer, because it removes the assumption entirely — or state the ordering guarantee explicitly. Duplicates in the input need a defined behaviour too.
- **Authorization applied inconsistently.** This is the one with a security consequence. If a forbidden identifier returns "not found" and a nonexistent one returns "not found", fine. If one returns "forbidden" and the other "not found", the endpoint tells an attacker which identifiers exist — and a bulk endpoint lets them ask five hundred at a time. On a marketplace where a vendor enumerating the retailer directory would be commercially fatal, that is not a theoretical concern. The scope filter is applied in the query, and unauthorised items are indistinguishable from absent ones.
- **The internal N+1.** A batch endpoint that loops internally has moved the problem rather than fixed it. It has to become one query with an `IN`, one multi-get, one bulk document fetch.
- **Rate limits counted per request rather than per item.** One request asking for five hundred items is not the same load as one asking for one, and a limiter counting requests will happily allow the expensive pattern.

**The general principle.** A batch endpoint is a load amplifier with the amplification factor chosen by the caller. Every limit, every check and every cost has to be reasoned about per item, not per request.

</details>

---

## RabbitMQ, Celery and High-Volume Message Work

---

### Q33. How do you decide what goes in a message payload and what does not — and why does that decide whether a broker survives a bulk update?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A message carries the identity of what changed, the revision, and the routing information — not the changed object. Broker memory is the product of message size and backlog depth, so payload size is one of only two factors you control, and it is the one that is free to fix.

<details>
<summary><strong>Detailed answer</strong></summary>

**The rule: reference, not content.** An event says "product 4471 revision 19 was published", and the consumer reads the current revision from the store that owns it. It does not carry the product document. Four reasons, and the memory one is only the first:

- **Size times depth is the memory bill.** A five-kilobyte payload and a two-million-message backlog is ten gigabytes the broker has to hold or page. A two-hundred-byte payload is four hundred megabytes. Same backlog, completely different outcome, and this is the difference between a broker that degrades and one that hits its high watermark and blocks every publisher.
- **A large payload is stale by the time it is consumed.** If the object changed twice while the message queued, a content-carrying message applies an old state. A reference-carrying message reads the current one and is naturally correct.
- **Redelivery and out-of-order delivery become tractable.** Carrying the source revision lets the consumer ignore an event older than what it has already projected, which makes redelivery a no-op and stops out-of-order delivery rolling a record backwards.
- **The broker stops being a data store.** Once payloads carry content, people start reading the queue for data, and now there is a copy of the truth with no query interface and no backup.

**What does go in.** The entity identifier and kind, the revision or a version counter, the event name, an occurrence timestamp, a correlation identifier and the trace context. Small, fixed, and enough for every consumer to decide whether it cares and to fetch what it needs.

**The exception, stated.** Where a consumer genuinely cannot read the source — a message crossing a boundary to a system with no access to our store — content has to travel. Then it is bounded explicitly, and anything large goes to object storage with the message carrying the reference. A message is not the place for a document.

**The second factor, since I said there were two.** Backlog depth, which is controlled by consumer prefetch, by whether the queue pages to disk, by message expiry with a dead-letter destination, and by scaling consumers on queue depth rather than on processor use. But payload size is the one you fix once, in the schema, and never think about again — which makes it the cheapest control in the set.

**And the bulk-update shape specifically.** A twenty-thousand-row import emitting one message per row is twenty thousand messages, twenty thousand cache invalidations and twenty thousand projection writes. One completion event, with the consumer re-projecting affected rows in batches, is one message. The payload rule and the granularity rule are the same decision viewed from two sides.

</details>

---

### Q34. Explain publisher confirms, consumer acknowledgements and prefetch. Which do you tune first when a backlog is growing?

**Project:** cancer-support-platform

**Brief answer**
Confirms protect the publisher's claim that a message is safe; acknowledgements protect the consumer's claim that it was handled; prefetch bounds how much a consumer holds at once. When a backlog grows, prefetch is the first thing I look at, because it is the usual cause of a consumer running out of memory.

<details>
<summary><strong>Detailed answer</strong></summary>

**Publisher confirms.** Without them, publishing is fire-and-forget: the broker may have accepted the message, or it may have died, and the publisher cannot tell. With confirms, the broker acknowledges once the message is durable — on a replicated queue, once it is replicated. That is what makes a zero recovery-point claim meaningful, and it is why the check-in path can tell the patient's device "recorded" the moment the confirm arrives.

The trap alongside it: a publish that routes to no queue is still confirmed. The broker did its job; there was simply nowhere to put it. So an exchange carrying a durability guarantee needs an alternate exchange, or an unbound routing key is acknowledged to the publisher and silently discarded — the exact loss the path exists to prevent, made invisible by the mechanism meant to prevent it.

**Consumer acknowledgements.** Automatic acknowledgement means the message is considered delivered when it leaves the broker, so a worker that crashes mid-task loses it. Manual acknowledgement after the work completes means a crash causes redelivery instead. Redelivery then requires idempotent handlers, and the durable version of that is a natural key in the database — an upsert on a unique constraint makes a redelivered check-in arithmetic rather than a bug. Deduplication in a cache is an optimisation; the constraint is the guarantee.

**Prefetch.** How many unacknowledged messages the broker will push to one consumer. Unlimited prefetch — the default in some clients — means a consumer with a large backlog available will pull as much as it can into memory. That is the classic out-of-memory on the consumer side, and it also destroys load balancing: one worker grabs the backlog while others idle. A small prefetch, in the low tens for ordinary work and often one for long tasks, is almost always right.

**The order I tune.** Prefetch first, because it is the usual cause of both the memory symptom and the uneven distribution, and it is a one-line change. Then acknowledgement mode, to establish whether the backlog is real work or redelivery churn from tasks that crash and come back. Then consumer concurrency and replica count, scaled on queue depth rather than processor use — a worker blocked on input/output shows low processor use while the queue grows, so a processor-based autoscaler sits still through exactly the event it exists for. Adding consumers first, before understanding the shape, frequently makes it worse by multiplying pressure on whatever the consumers are waiting on.

</details>

---

### Q35. Classic queues, quorum queues, lazy behaviour, streams — what would you choose for a continuous high-volume attribute update feed, and why?

**Project:** cancer-support-platform

**Brief answer**
Quorum queues for anything whose loss matters, which is the default now that mirrored classic queues are gone. For a genuinely continuous high-volume feed with several independent consumers, a stream is the better fit, because a stream is a replayable log rather than a destructive queue.

<details>
<summary><strong>Detailed answer</strong></summary>

**Quorum queues.** Replicated with a consensus protocol, durable by design, and the supported answer for high availability in current versions. They are what both these systems use for the domain event exchange and the task queues. The trade-offs are real and worth knowing: higher write amplification because every message is replicated, memory use proportional to the number of unacknowledged messages rather than to the queue, and poison-message handling via a delivery-limit and dead-letter rather than infinite redelivery. That last one is a feature — a message that fails forever should leave the queue.

**Classic queues** remain reasonable for genuinely transient work where loss is acceptable and throughput matters more than durability. Mirroring them is no longer available, so "classic and reliable" is not a combination on offer.

**Lazy behaviour** — paging messages to disk rather than holding them in memory — is what stops a growing backlog becoming a broker memory incident. On quorum queues this is effectively the operating model rather than a separate mode. The general principle is what matters: a backlog is an acceptable state and must be paid for in disk, not in memory, or the broker's failure takes production with it.

**Streams**, and why I would reach for one on the described workload. A stream is an append-only log with offset-based consumption and a retention policy. Several consumers read the same messages independently at their own positions, and reading does not remove anything. For millions of attribute updates flowing continuously that is a better fit than a queue in three ways: throughput is much higher because there is no per-message bookkeeping; a slow consumer falls behind rather than causing the backlog to accumulate against every consumer; and a consumer can be rewound and replayed, which is exactly what you want when a projection needs rebuilding.

**What a stream costs.** Retention is time or size based rather than consumption based, so you size storage deliberately. Consumers must track offsets. Per-message routing flexibility is lower. And the semantics are different enough that it is not a drop-in replacement for a work queue.

**How I would actually decide.** Work with an owner that must complete once — a queue, quorum, with a dead-letter. A continuous fact stream with multiple independent readers and a need to replay — a stream. The mistake I would avoid is using one queue for both, because the requirements pull in opposite directions: a work queue wants to forget, and a fact log wants to remember.

</details>

---

### Q36. Connection and channel churn on a broker: why does it matter, and what does it look like when it goes wrong?

**Project:** cancer-support-platform

**Brief answer**
Connections and channels are expensive to establish and are held server-side, so opening one per message turns the broker into the bottleneck. It shows up as high broker processor use with low message throughput, and often as file-descriptor exhaustion — a resource problem that looks nothing like a messaging problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**The model.** A connection is a long-lived transport connection, authenticated once, with real setup cost including the security handshake. Channels are lightweight multiplexed sessions inside it. The intended shape is a small number of long-lived connections per process with a channel per thread or per consumer.

**The anti-pattern.** Code that opens a connection, publishes one message and closes it. It works perfectly in development and at low volume, and at a thousand messages a second it is a thousand handshakes a second. The broker spends its capacity on connection setup, and every connection consumes a file descriptor and memory until the operating system refuses more.

**What the symptoms look like**, and why they mislead:

- Broker processor use high while message rates are unremarkable. The work is not messaging.
- Connection count climbing steadily and never dropping, which usually means connections are not being closed on error paths.
- File descriptor or socket exhaustion, appearing as connection refusals that look like a network fault.
- Latency spikes correlated with deploys, because a rolling restart reconnects everything at once and the broker handles a thundering herd of handshakes.
- On the client side, timeouts that resolve on retry, which sends people looking at the network.

**What I do about it.**

- **One long-lived connection per process, channels per unit of concurrency**, with a pool rather than per-call creation. Publisher and consumer connections separated, because the broker's flow control blocks publishers and you do not want that to stall consumers on the same connection.
- **Heartbeats configured deliberately**, so a connection dropped by an intermediary is detected rather than sitting half-open. Half-open connections are worse than closed ones: they consume broker resources and the client thinks it is fine.
- **Reconnection with backoff and jitter.** Without jitter, a broker restart brings every client back simultaneously and the reconnect storm is its own outage.
- **Monitor connection and channel counts as first-class metrics**, with an alert on a rising trend. A count that only grows is a leak, and it is invisible until the limit is hit.

**One more that is specific to a long-lived connection.** The broker authenticates a connection, not each publish. So a long-lived mobile client connection has to be bounded by a maximum lifetime shorter than the credential's validity window and forced to reconnect, or an expired credential keeps publishing indefinitely.

</details>

---

### Q37. How would you upgrade a broker cluster that is carrying production traffic?

**Project:** cancer-support-platform

**Brief answer**
Read the release notes for the version pair specifically, rehearse the whole thing on a copy, then roll one node at a time with the cluster staying quorate, having first confirmed that every client version in the estate is compatible with both the old and the new broker.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before touching anything.**

- **Read the upgrade notes for the exact version pair**, not the general guidance. Broker upgrades are where features get removed — mirrored classic queues disappearing is the obvious recent example, and a cluster relying on them does not upgrade, it migrates.
- **Inventory what the estate actually uses.** Queue types, plugins, policies, exchange types, and every client library version. A plugin that is not available on the new version is a blocker discovered at the worst time, and the protocol bridge plugins are the ones most often forgotten.
- **Check client compatibility in both directions**, because during the roll, clients talk to both versions.
- **Rehearse on a copy** with representative topology and message volume, and rehearse the rollback too. An upgrade path that has not been reversed is a one-way door.

**The roll itself.**

- **One node at a time**, waiting for the cluster to be fully healthy and the replicated queues to be back to full membership before touching the next. Rushing this is how you lose quorum, and losing quorum on a replicated queue is a much worse day than a slow upgrade.
- **Drain the node first** where the client library supports it, so consumers move rather than being disconnected.
- **Watch the right signals during**: queue depth, unacknowledged counts, publish confirm latency, consumer counts and the memory watermark. Not just whether the node came back.
- **Expect and tolerate reconnection.** Clients must reconnect with backoff and jitter, and publishers must handle a confirm that does not arrive. If they do not, the upgrade is blocked on fixing the clients first — which is a legitimate outcome and better found in the rehearsal.

**Feature flags and the two-step.** Where the new version changes a default or offers a new queue type, I would separate the upgrade from the adoption. Upgrade first, verify stability, then change queue types or settings in a later, separate change. Bundling them means an incident has two candidate causes.

**And the honest caveat.** Some upgrades are not rolling. A change that alters the cluster's internal format may need a full stop, and there is no clever way around that — it needs a maintenance window, a tested restore, and publishers that queue at the outbox rather than losing anything. The design already has that property, which is the point of publishing through an outbox: a broker being unavailable leaves unpublished rows that drain on recovery rather than facts that never left.

</details>

---

### Q38. What do you configure on Celery before putting it on a critical path?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Late acknowledgement, a small prefetch, bounded retries with a dead-letter destination, idempotent tasks with the guarantee in the database rather than in a cache, per-queue routing with dedicated workers, and hard and soft time limits. Then I test the crash case rather than assuming the settings do what they say.

<details>
<summary><strong>Detailed answer</strong></summary>

**The settings, and what each prevents.**

- **Late acknowledgement.** A task is acknowledged after it completes, not when it is received, so a worker killed mid-task causes redelivery rather than loss. This is off by default and it is the single most important change.
- **Small prefetch.** With the default multiplier a worker reserves a batch of tasks it may hold for a long time. For long-running tasks that is both a memory problem and a distribution problem — one worker holds work while others idle. For anything slow, one.
- **Bounded retries with backoff and jitter**, and then a dead-letter destination. Infinite retry on a poison message is a loop that consumes capacity forever and looks like healthy throughput.
- **Idempotency, guaranteed in the database.** Every task must tolerate running twice, because at-least-once delivery plus redelivery guarantees it will. The guarantee is a unique constraint or a natural key upsert. A deduplication key in a cache is an optimisation that vanishes on a flush.
- **Separate queues with dedicated workers.** Imports must not sit behind reminders. Both these systems route by kind with a worker deployment per queue, which also lets each scale on its own depth.
- **Soft and hard time limits.** A soft limit raises inside the task so it can clean up; the hard limit kills it. Without them one stuck task holds a worker slot indefinitely.
- **Graceful shutdown that works.** A pre-stop hook that stops consuming and waits for the in-flight task, bounded by the termination grace period, with task chunks sized to finish well inside it. Otherwise every deploy kills work mid-flight and relies on redelivery to paper over it.

**What I verify rather than assume.**

- **Kill a worker mid-task and confirm the work completes after redelivery.** This is the test that proves late acknowledgement is actually configured, and it takes minutes.
- **The broker's semantics under the chosen backend.** A cache used as a broker does not have true acknowledgement, so durability claims that rest on it are false — that gets a kill-the-worker test before anything important depends on it.
- **Version compatibility between the task framework and the broker for the queue type in use.** Support for replicated queue types interacts with late acknowledgement, prefetch and priorities in ways that are version-specific, so the versions are pinned and tested together rather than assumed.

**And the boundary I keep.** The task framework moves work between processes we own. Events crossing to something we do not own go on the service bus. Collapsing those puts one system in a role it is bad at.

</details>

---

### Q39. When would you not use a broker at all?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
When the work is time-based rather than event-based, when the volume does not justify a second piece of infrastructure, or when the caller genuinely needs the answer now. A broker between two services that must agree synchronously adds latency and a failure mode without buying anything.

<details>
<summary><strong>Detailed answer</strong></summary>

**Time-based work belongs in the database, not the queue.** Reminders are the example. The instinct is to publish a delayed message when the appointment is created. What that actually does is put the schedule inside the broker, where it cannot be queried, cannot be corrected in bulk, and disappears if the broker is rebuilt. The durable version is a row with a due time and a state, and a periodic sweep that claims due rows with a lock that skips already-claimed ones so several workers run without double-dispatching. Every attempt writes a row, which is what turns "was it delivered" into a query rather than a log search. If a bug means a batch went out wrong, the state is in the database and can be fixed.

**Low volume does not justify the infrastructure.** A broker is a component to run, upgrade, monitor, back up and reason about during an incident. For a handful of background jobs a day, a job table with a poller is less machinery and easier to debug. I would rather add the broker when there is a reason than have it because it is the pattern.

**When the caller needs the answer.** Asynchronous messaging cannot make a synchronous requirement disappear; it relocates it into a correlation-and-wait pattern that is strictly more complicated than a call. Where one service must ask another a question to complete a request, a bounded synchronous call with a short timeout and a defined behaviour on failure is the honest design. The marketplace has exactly one such hop, with a 250 millisecond timeout and a deliberate decision to fail open — and the correctness guarantee still comes from a unique constraint in the database rather than from the call.

**When ordering across many keys must be strict.** A queue with competing consumers does not preserve global order, and getting order back means one consumer or per-key partitioning, at which point a log or the database's own sequencing may be the better primitive.

**And where an outbox is enough.** If the only requirement is that a fact reliably reaches one other component, a table written in the same transaction as the fact, plus a relay, provides the durability. The broker is then a transport choice rather than the source of the guarantee — which is the correct relationship, and it is what makes a broker outage a delay rather than a loss.

</details>

---

## Search, Elasticsearch and the ELK Stack

---

### Q40. Describe your experience with Elasticsearch. What did you index, and how did you keep it in step with the database?

**Project:** cancer-support-platform

**Brief answer**
Clinical content search on the health platform — visit notes, guidance and visit history behind a single alias. It is kept in step by never being written directly: the relational store is the source of truth, a transactional outbox drives an index consumer, and the whole index is rebuildable from the primary stores.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it.** Documents for the searchable clinical content, each carrying the scope fields that decide who may see it — the patient identifier and the care-team identifiers — alongside the searchable text and the filterable metadata. The scope fields are on every document deliberately, so the filter is an index-level property rather than an application convention.

**How it stays in step, which is the part that matters.** The application never writes to the index from a request handler. The sequence is: the fact is written to the relational store, and in the same transaction an outbox row is written. A relay publishes that row and only then marks it published. An index consumer reads the event and bulk-indexes. That single-writer rule is what makes dual-write drift impossible — there is no code path where the database and the index can disagree because one write succeeded and the other did not.

**Freshness is stated as a composed budget rather than asserted.** The relay under a couple of seconds, plus the bulk flush interval, plus the index refresh interval, which together give a newly saved note searchable within about eight seconds at the median. The useful property of writing it as a sum is that it shows tightening any single component alone buys nothing.

**Rebuildability, and why it is the important property.** The index holds nothing that is not derivable from the relational and document stores, so losing the cluster entirely is a rebuild rather than a data loss. That is what makes the disaster recovery plan honest — and because a mitigation nobody has run is an assumption, the rebuild is rehearsed quarterly with a document-count reconciliation between sources and index.

**What I would flag as the operational risk.** A consumer that stops is silent: search keeps working, every request is fast, and the results simply stop including anything new. So the metric that matters is the lag from the source event's timestamp to the index write, alerted on, because nothing else surfaces it.

**And the honest limit of my experience.** I ran this at a scale of a couple of million documents on a self-managed cluster in the platform's own cluster — real operations including shard sizing, replica counts and version upgrades, but not a very large multi-node search estate. What I have not done is run a cluster at tens of terabytes with hot-warm-cold tiering.

</details>

---

### Q41. What is the difference between filtering and ranking, and why does confusing them cause most bad search?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A filter decides whether a document may appear; ranking decides where. They are different questions with different correctness requirements, and treating a filter as a strong ranking signal is how a search returns something it should never have returned at all.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why they must be separate.**

- **A filter is binary and it is a correctness property.** Whether the caller may see this document, whether it is published, whether it is within the requested date range. There is no "slightly" — a scope filter that is expressed as a score boost means a sufficiently strong text match can outrank it, and now the search has disclosed something. On a system where authorization is the whole threat model, that is not a subtle bug.
- **Ranking is continuous and it is a quality property.** Which of the permitted documents is most useful. Getting it wrong is disappointing; getting the filter wrong is an incident.

**The engineering consequences of separating them.** Clauses that only include or exclude go in filter context, where they contribute nothing to the score and are cacheable — which is also a real performance benefit, because a cached filter bitmap is reused across queries. Scoring clauses are only the ones expressing relevance. The scope fields are on every document and the query is always wrapped in a filter on them, as an index-level property rather than an application convention, so a query written by someone who forgets returns nothing rather than someone else's data.

**Where the confusion actually shows up in practice.**

- **Status expressed as a boost.** "Prefer published listings" rather than "only published listings" — and eventually a draft appears because its text matched better. The marketplace instead carries the status predicate in a partial index, which keeps unpublished rows out of the index entirely and removes the filter from every plan.
- **Recency as a filter when it should be a signal.** The inverse mistake: hard-cutting anything older than a year, so a highly relevant older document is unreachable and nobody knows why. Recency belongs in the score.
- **A relevance threshold used as a filter.** Scores are not comparable across queries, so a fixed cutoff means results vanish for some queries and not others, with no pattern anyone can explain.

**How I keep it honest.** The filter set is tested for absence — a query from one scope must return zero documents from another, asserted rather than assumed. Relevance changes are evaluated against a judged set, so a boost adjustment is measured rather than eyeballed. And no relevance work is ever permitted to touch the scope filter, which is stated as a rule rather than left to judgement, because that is the one clause where a well-meant tuning change becomes a disclosure.

</details>

---

### Q42. Explain mappings and analyzers, and why a mapping change is harder than a schema change.

**Project:** cancer-support-platform

**Brief answer**
A mapping declares each field's type and how text is analysed into terms; an analyzer is the pipeline that turns text into those terms at index time and at query time. Most mapping changes cannot be applied in place, because existing documents were already tokenised under the old rules — so the change is a reindex, not an alter.

<details>
<summary><strong>Detailed answer</strong></summary>

**Analyzers, concretely.** A character filter, a tokenizer, then token filters — lowercasing, stop words, stemming, synonyms. Analysis happens twice: at index time, producing the terms stored in the inverted index, and at query time, producing the terms to look up. They must agree, or nothing matches. This is the source of the most common confusing bug in search: a field analysed one way and queried another, giving zero results for a document that is obviously there.

**Where the clinical synonym filter earns its place.** The same condition appears as a clinical term, an abbreviation and a lay phrase, and a clinician searching one must find a note written with another. That mapping is what makes the search useful rather than literal. The operational consequence is worth knowing — synonyms applied at index time require a reindex to change, while synonyms applied at query time can be updated without one but cost more per query. Choosing the second is usually right precisely because the vocabulary will change.

**Why a mapping change is not an alter.** The inverted index holds terms produced by the old analyzer. Changing the analyzer does not retroactively re-tokenise them. Changing a field's type is generally not permitted at all. So the change is: create a new index with the new mapping, reindex into it, and switch.

**Which is why every index sits behind an alias**, and this is the single most important operational decision in a search deployment. The application only ever talks to the alias. A mapping change becomes: build the new index, reindex, verify document counts and spot-check queries, then atomically move the alias. Zero downtime, and the rollback is moving the alias back — which is why the old index is kept until confidence is established rather than deleted at switchover.

**During the reindex**, new writes still arrive. Either dual-write to both indices for the window, or reindex to a point in time and then replay events since. The event-driven design makes the second option straightforward, because the outbox is an ordered log of what changed.

**What I would add for anything non-trivial.** A field that is both analysed for search and kept as an exact keyword for filtering and aggregation — you almost always need both, and adding the second later is another reindex. And dynamic mapping switched off in production: a document with an unexpected field silently creating a mapping is how an index ends up with a type nobody chose and cannot change.

</details>

---

### Q43. How do you tune relevance, and how do you know a relevance change is actually an improvement?

**Project:** cancer-support-platform

**Brief answer**
By evaluating against a judged set rather than by looking at results. Relevance changes are the easiest thing in engineering to fool yourself about — every change looks better on the three queries you tested it with, which are the queries that motivated the change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The levers, briefly.** Field boosting, so a match in a title outweighs a match in the body. Analyzer choices — stemming, synonyms, handling of abbreviations. Phrase matching and proximity for multi-word queries. Filters versus scoring clauses, which matters both for correctness and for cost: a clause that only includes or excludes belongs in filter context, where it is cacheable and does not contribute to the score. And a reranking pass over the top results where the first-stage retrieval is broad.

**The problem with tuning by inspection.** You change a boost, run your query, the result you wanted moves up, you ship it. What you cannot see is the thousand queries it made worse. Relevance is a distribution and inspection samples it in the least representative way possible.

**What I would insist on instead.**

- **A judged set.** A few hundred real queries with relevance labels for the returned documents. On a clinical system those judgements have to come from clinicians — I cannot label whether a note is relevant to a query, and pretending otherwise produces a metric that measures my guesses.
- **A metric that reflects the interface.** Something rank-weighted over the first page, because that is what a user sees. Precision over the whole result set is measuring something nobody experiences.
- **Baseline first, then change one thing.** Two changes at once and you cannot attribute the movement.
- **Look at what regressed, not just the aggregate.** A change lifting the mean while badly breaking one query class is usually a bad change, and the aggregate hides it.
- **Online evidence where it is available.** Click and reformulation rates, with the caveat that they measure engagement rather than correctness, and on a clinical tool that difference is not academic.

**Where the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") claims a relevance improvement**, the honest framing is that the number comes from an offline evaluation on a judged set with clinician labels, comparing a defined baseline against the tuned configuration. What would make it a false claim: measuring on the queries the change was designed for, changing the judged set at the same time as the configuration, or reporting an aggregate that a subgroup regression is hiding. I would rather state the evaluation method with the number than state the number alone.

**And a constraint that outranks relevance here.** Nothing may be returned outside the caller's scope, and the scope filter is not a ranking input — it is a filter, applied at the index level, and no relevance tuning is permitted to touch it.

</details>

---

### Q44. What do you use Kibana for beyond looking at logs?

**Project:** cancer-support-platform

**Brief answer**
As the single pane where the two telemetry planes meet — application traces, cluster metrics and the cloud provider's own diagnostic logs shipped into the same store. Its real value is being the one place you can follow a request across a broker boundary rather than assembling two half-stories during an incident.

<details>
<summary><strong>Detailed answer</strong></summary>

**The joining problem it solves.** The estate spans services in the cluster and managed cloud services, so there are inevitably two sources of telemetry. What makes them one system is the trace context propagating on every hop — including the message headers on the broker, the transport bridge and the service bus — and the cloud provider's diagnostic logs being shipped into the same store as everything else. Without that, a reminder failing between a worker and the delivery function is two disconnected halves, and you discover that during an incident rather than before one.

**What I actually build in it.**

- **A dashboard per objective rather than per service.** The question during an incident is "are we meeting the reminder delivery target", not "how is service seven". A per-service dashboard forces the person under pressure to assemble the answer.
- **Saved searches for the recurring investigations.** "All events for this correlation identifier across every service" is the query you want to run in an incident, not compose in one.
- **The traces view for latency work.** Where the time actually goes in a request, including the spans for connection acquisition and outbound calls, which is what separates waiting from working.
- **Ad hoc analysis over structured logs.** Because logs are structured with trace identifiers, service, module and actor kind, they can be aggregated as data rather than grepped as text — error rates by reason, a distribution of a field, the shape of a spike.

**Two rules I hold about it.**

- **No clinical free text, no symptom values, no message bodies ever reach it.** A redaction filter drops fields marked sensitive at the formatter, and a pipeline check fails the build if a log call passes a model containing one. A log store is not a place where sensitive content is acceptable just because it is internal.
- **Audit is a database table, never a log stream.** Conflating them means the log retention policy silently becomes the audit retention policy, which is a compliance failure nobody notices until someone asks for a record older than the retention window.

**And what I would not use it for.** Alerting that needs to be reliable during a partial outage — the alerting path should not depend on the same store that may be the thing failing. Metric-based alerting on the metrics system is the more robust arrangement, with the log store as the investigation tool.

</details>

---

### Q45. How do you run a reindex with no search downtime?

**Project:** cancer-support-platform

**Brief answer**
Through an alias, always. Build the new index alongside the old, reindex into it, verify counts and sample queries, then move the alias atomically. The application never names a concrete index, so the switch is invisible and the rollback is moving the alias back.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.**

1. **Create the target index** with the new mapping and settings. Replica count set to zero and the refresh interval disabled during the bulk load, because both cost throughput you do not need until the index is live — then restored before the switch.
2. **Reindex.** From the existing index where the source documents are unchanged and only the mapping differs; from the primary stores where the document shape itself is changing, because then the old index is the wrong source. On this system the second path is always available, which is the point of the index holding nothing that is not derivable.
3. **Handle writes arriving during the window.** Either write to both indices for the duration, or reindex to a point in time and replay the events since from the outbox. The second is cleaner when there is an ordered event log, which there is.
4. **Verify before switching.** Document counts reconciled against the source, a set of known queries run against both indices and compared, and a spot check on documents that exercise the changed mapping. Counting is the cheapest assertion that catches a silently truncated reindex.
5. **Move the alias in one atomic action** that removes the old index and adds the new one. No window where the alias points at nothing or at both.
6. **Keep the old index** until confidence is established. It is the rollback, and deleting it at switchover converts a two-second recovery into a rebuild.

**What goes wrong when people skip the alias.** The application holds a concrete index name, so the switch means a configuration change and a deploy, which means a window where some pods query the old index and some the new. That is not a catastrophe for search, but it is avoidable for free — and the alias also makes the emergency case work, where you need to point at a rebuilt index right now.

**On throughput during the reindex.** It competes with production traffic for the same cluster resources. It is throttled deliberately and run when traffic is low, and the cluster's own load is watched during it. A reindex that saturates the cluster degrades live search, which is the outcome the whole exercise was meant to avoid.

**And the same procedure covers disaster recovery**, which is why it is worth rehearsing rather than documenting. Losing the cluster entirely is the same sequence starting from step two, and having run it quarterly means the duration is a number rather than a hope.

</details>

---

## Caching, Redis and Read Paths

---

### Q46. Describe your experience with Redis. What did you use it for beyond caching?

**Project:** banking-software-marketplace, cancer-support-platform

**Brief answer**
Cache-aside for the hot catalog reads, a task broker for one system's workers, idempotency keys, a per-vendor concurrency semaphore, and rate limiting. The important decision was running two separate instances — cache and broker — rather than one with separate logical databases.

<details>
<summary><strong>Detailed answer</strong></summary>

**The uses, and what each demands of the deployment.**

- **Cache-aside on the catalog read path.** Listing details keyed with the revision in the key, search result pages with a short expiry, and facet counts. Loss is acceptable by construction: a cold cache means slower reads, not wrong ones.
- **A task broker for the marketplace workers.** Completely different requirements — this is not disposable, and losing it means losing queued work. That is why it is a separate instance with different persistence and different memory policy.
- **Idempotency keys** on mutating requests, as an optimisation in front of the real guarantee. The durable guarantee is a unique constraint in the database; the cache short-circuits the duplicate before it reaches the database. Losing the keys permits a duplicate to be reprocessed, and the constraint is what makes that safe.
- **A per-vendor concurrency semaphore** so one vendor's large import cannot occupy the whole worker pool. A counter with an expiry, so a crashed worker releases its slot rather than deadlocking the vendor forever.
- **Rate limiting** as a per-subject token bucket in the application, beneath the coarser limits at the gateway.

**Why two instances rather than one with separate databases.** Because the failure modes must not be shared. A cache should evict under memory pressure — that is correct behaviour. A broker must never evict, because eviction there is silent data loss. Those are opposite memory policies and they cannot both be configured on one instance. Beyond that, a cache flush to clear a bad entry must not touch queued work, the persistence requirements differ, and a cache stampede's traffic burst must not slow down task dispatch. Two instances is a small cost for keeping a disposable store and a durable one from sharing a fate.

**What I am careful about.** Every use above is either disposable or backed by a durable guarantee elsewhere. Nothing is the sole record of anything. The moment a cache becomes the only place a fact lives, it has silently become a database without backups, and that transition happens gradually and by accident.

</details>

---

### Q47. How do you decide a cache is doing more harm than good?

**Project:** banking-software-marketplace

**Brief answer**
When the hit ratio is low enough that it is mostly adding a round trip and an invalidation risk to a query that was fine, when the staleness it introduces is producing support tickets, or when it has become the thing that must not fail. Any of those is a reason to remove it rather than tune it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The signals I actually look at.**

- **A low hit ratio.** A cache hitting a small fraction of the time is paying the lookup cost on every request, paying the write cost on every miss, and buying very little. Usually the cause is a key too specific — a key including a parameter that varies per caller — or a working set far larger than the memory allocated. Either way, the honest options are to fix the key, size it properly, or remove it. Leaving a low-hit cache in place is pure overhead with an invalidation liability attached.
- **Staleness producing tickets.** If people are reporting that they published something and cannot see it, the tolerance assumed at design time was wrong. Sometimes the fix is invalidation, and sometimes the honest fix is that this data should not have been cached.
- **It has stopped being optional.** The test is whether the system is correct and survivable with the cache empty. If capacity has quietly been sized on the assumption of a warm cache, then a restart or a flush is an outage, and the cache has become a load-bearing component without anyone deciding that. On the marketplace this is written down as a number instead of a hope: with the cache gone entirely, latency roughly triples and database load multiplies about sixfold, and capacity is sized so that is survivable.
- **The invalidation logic is now the complicated part.** When more code exists to keep the cache correct than to compute the value, the cache has inverted the cost it was meant to reduce.

**What I check before removing it.** Whether the underlying query is actually slow now. Caches are often added for a query that was later fixed with an index, and nobody removed the cache — so it is protecting nothing while carrying all the risk. Measuring the uncached path is a ten-minute experiment that occasionally deletes a whole subsystem.

**How I remove one safely.** Reduce the expiry progressively rather than deleting it outright, watching the database load at each step. That converts a scary change into a measured one, and if load rises unacceptably at some point, that is the evidence that the cache is genuinely needed — which is a much better basis for keeping it than the fact that it is already there.

**And the case for keeping one that looks marginal.** A cache absorbing a burst is not judged by its average hit ratio. A key that is hit fifty times in one second during a spike and never otherwise has a poor overall ratio and is doing exactly the job it exists for. So I look at the distribution rather than the mean before concluding anything.

</details>

---

### Q48. What makes cache invalidation go wrong, and what do you do about it?

**Project:** banking-software-marketplace, cancer-support-platform

**Brief answer**
Almost always a key that nobody deleted — because the delete was in a code path that failed, or because the set of affected keys is not enumerable. The structural fix is to make invalidation unnecessary: put the version in the key, so a new version is a new key and the old one simply ages out.

<details>
<summary><strong>Detailed answer</strong></summary>

**The recurring failure modes.**

- **A delete that did not happen.** The write succeeded, the invalidation was after the commit and the process died, or the call raised and was swallowed. Now a stale value is served indefinitely. This is common precisely because invalidation is usually the least important-looking line in a function.
- **An unenumerable key set.** One change affects an unknown number of cached queries. People respond with a pattern-based delete, which is a scan of the keyspace and a serious operational hazard on a large instance, or with a full flush, which converts a small update into a total cache loss and a stampede.
- **The wrong key.** Keys constructed in two places with slightly different rules — a missing parameter, a different order — so the write path deletes one key and the read path reads another. Nothing errors.
- **A cross-tenant key.** A key that omits the scope, so one organisation's cached response is served to another. That is a disclosure rather than a staleness bug, and it is the reason gateway response caching is disabled on data paths by policy rather than by omission.
- **The race.** Read misses, fetches, and writes the cache after a concurrent update has already invalidated it — so the stale value is written after the delete and lives out its full expiry.

**What I do, in order of preference.**

1. **Version the key.** Include the entity's revision. A change produces a new key, the old one is never read again and expires quietly. No delete has to succeed for correctness. This eliminates the first, third and fifth failure modes at once.
2. **Invalidate from the event, not the request.** The consumer that already handles the change deletes the keys, so invalidation is retried and dead-lettered like any other message handling rather than being a fire-and-forget call at the end of a request.
3. **Where the key set is not enumerable, do not pretend.** Use a short expiry and say so. An honest bounded staleness beats an invalidation strategy that silently misses.
4. **Build the key in exactly one place**, a single function, with the scope always in it.
5. **Never flush globally as an operational habit.** If that is the recovery procedure, the caching design has a defect.

**And the property I would state for any cache:** every cached value is derivable from a source of truth, and the system is correct with the cache empty. If that is not true, it is not a cache.

</details>

---

### Q49. Redis is memory-bound. What happens when it fills, and how do you configure for that?

**Project:** banking-software-marketplace

**Brief answer**
It depends entirely on the eviction policy, which is why a cache and a broker cannot share an instance. A cache should evict least-recently-used keys — that is correct. A broker or anything durable must refuse writes rather than evict, because eviction there is silent data loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the memory limit does.** When usage reaches the configured maximum, behaviour is governed by the eviction policy. With no eviction, writes are refused with an error and reads keep working. With a least-recently-used or least-frequently-used policy, keys are discarded to make room — either across all keys or only those with an expiry set.

**Why that single setting decides the architecture.**

- **The cache instance** is configured to evict least-recently-used keys with expiries. Filling up is a normal operating state, and eviction is the designed behaviour. The consequence is a lower hit ratio and more database load, which is visible in metrics and survivable because capacity is sized for a cold cache.
- **The broker instance** is configured to refuse writes rather than evict. If it evicts, queued tasks vanish with no error anywhere — the producer got an acknowledgement, the consumer never sees the task, and nothing anywhere reports a problem. A publish failing loudly is far better, because the caller can retry or the outbox can hold the row.

They are opposite settings, so one instance cannot serve both roles correctly. That is the concrete reason for two instances rather than a preference for tidiness.

**What I monitor.** Used memory against the maximum, the eviction rate, the hit ratio, and the count of keys without an expiry. That last one is the leak detector: a cache steadily accumulating keys nobody set an expiry on will eventually be entirely composed of them, and the eviction policy that only considers keys with expiries then has nothing to evict.

**Fragmentation** is worth naming because it surprises people — the ratio of memory the allocator holds to memory actually used can drift well above one, so the instance appears full while holding much less. It is a metric to watch rather than a number to assume.

**On persistence.** Snapshotting has a fork cost that can briefly double memory, which is exactly the wrong thing to happen on an instance near its limit. The append-only log is more durable and has its own rewrite behaviour. For the cache, persistence is unnecessary — a cold restart is a designed state. For the broker, it matters, and that is another reason the two are separate.

**And the deployment consequence.** Memory limits are set explicitly rather than left to the container's limit, so the process makes its own eviction decision instead of being killed by the platform. Being terminated for exceeding memory is the worst outcome: total loss with no eviction and no error.

</details>

---

### Q50. Where would you not use Redis?

**Project:** banking-software-marketplace, cancer-support-platform

**Brief answer**
As the source of truth for anything, as the sole holder of a durability guarantee, for a distributed lock protecting something whose double-execution actually matters, and for large objects. Each of those is a case where its speed is being used to paper over a guarantee it does not provide.

<details>
<summary><strong>Detailed answer</strong></summary>

**As a source of truth.** It is memory-first with configurable persistence, and the persistence options all have a window. That is fine for a cache and unacceptable for a fact. The failure is gradual rather than dramatic: something is cached, then something is stored there because it was convenient, and eventually a value exists nowhere else. My rule is that the system must be correct with it empty — if that is not true, something has quietly become a database without backups.

**As the durability guarantee for idempotency.** Idempotency keys held there are an optimisation. If they are flushed, a duplicate request gets reprocessed, and the thing that must prevent a double charge is a unique constraint in the database. Relying on the cache alone means the guarantee disappears with a restart, and it disappears silently.

**For a distributed lock protecting something that actually matters.** Single-instance locks are unsafe under failover; the multi-instance algorithm is contested and depends on timing assumptions that do not hold with process pauses or clock drift. My position is practical rather than doctrinal: I use it for advisory coordination where a rare double execution is tolerable — a semaphore limiting a vendor's import concurrency, where two extra workers occasionally is harmless. Where double execution is not tolerable, the correctness comes from the database: a unique constraint, or a row claimed with a lock that skips already-claimed rows. Then the lock is an optimisation to reduce contention rather than the thing preventing the error.

**For large objects.** Storing files or large documents fills memory fast and it is the most expensive storage in the estate. Those belong in object storage with a reference held elsewhere.

**For anything needing queries.** No secondary indexes worth relying on, no joins, and scanning the keyspace on a large instance is an operational hazard. If the access pattern needs a query, it needs a database.

**And as a queue where durability matters**, which is the specific case worth stating: used as a task broker it lacks true acknowledgement semantics, so a worker that dies mid-task can lose the work. That is acceptable for tasks that are re-derivable and not for tasks that are not — and the honest way to hold that position is to test it by killing a worker mid-task rather than to assume the configuration protects you.

</details>

---

## Identity, Authorization and API Contracts

---

### Q51. A new requirement needs the caller's identity to carry more than it does today. How do you avoid solving that by adding claims?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By asking whether the thing being added changes independently of the token's lifetime. Anything that can change while a token is live does not belong in it — because a claim is a snapshot, and a stale snapshot of a permission is an authorization defect that no expiry short enough will fix.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the pull to add a claim is strong.** It is free at read time: no lookup, no network call, no dependency. On a system whose entire latency budget rests on validating tokens locally against a cached key set rather than calling an introspection endpoint, adding one more field to something already being parsed looks like the obvious answer.

**The test I apply.** Does this fact change on the token's schedule or on its own? Issuer, audience, subject, account type and coarse scopes change when the session does, so they belong in the token. A record-level permission, a team membership, an organisation's subscription state or an entitlement changes whenever the business changes it — which may be thirty seconds after the token was minted. Putting it in the token means the system is enforcing yesterday's answer, and the only remedies are shortening the token life, which costs the latency you were protecting, or reissuing on every change, which is a distributed invalidation problem far worse than the lookup you avoided.

**So where does it go instead.** Into the data layer, evaluated per request against the store that owns it. On the health platform, "may this clinician see this patient" is an active row in a relationship table with a validity period — access has a start and an end, history is not overwritten, and revocation takes effect on the next request rather than on the next token. On the marketplace it is the organisation on the token compared against the organisation owning the row, applied in one place by the repository layer. Both are lookups, both are indexed, and both are correct at the moment of use.

**Three more reasons not to grow the token.**

- **A token is signed, not encrypted.** Anything in it is readable by anyone holding it, including on a device you do not control. An entitlement list is a description of your permission model handed to whoever asks.
- **Size.** Tokens travel on every request and often in a header with a size limit somewhere in the path. Growth is discovered as a mysterious failure at a proxy.
- **It becomes an interface.** Once a consumer reads a claim, removing it is a breaking change, and now the identity provider's schema is coupled to application logic.

**Where I would genuinely add one.** A stable, coarse fact that gates routing rather than records — an account type or a tenant identifier — because those are what the gateway needs to reject a request before any application code runs, and they do not change while a fifteen-minute token is alive.

</details>

---

### Q52. How would you bound the damage from a leaked signing key?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By being able to rotate without an outage, which means the key set is fetched by identifier and cached with a known refresh interval, more than one key is trusted at a time, and the overlap window is longer than every cache in the path. Without that, rotation is itself an outage and so it never happens.

<details>
<summary><strong>Detailed answer</strong></summary>

**What a leaked signing key means.** Anyone holding it can mint a token that every validator accepts, with any subject, any audience and any scopes. Every downstream control that trusts the token is bypassed. It is the closest thing to a total authentication compromise, so the only question that matters is how quickly the key can stop being trusted.

**What makes rotation possible.**

- **Tokens carry a key identifier**, and validators select the key by it rather than assuming a single key. Without that, two keys cannot be trusted at once and rotation is a hard cut.
- **The key set is fetched from the provider and cached**, and the cache refreshes on a known interval. Every validator must be able to pick up a new key without a deploy.
- **More than one key is published during a transition**, so tokens signed with either verify.
- **The overlap window exceeds every cache in the path.** This is the specific trap on these systems: the gateway caches the key set on its own schedule, independently of the application's cache. During a rotation the two can disagree, so tokens signed with the new key are rejected at the edge while services would accept them. The fix is to make the overlap strictly longer than the gateway's refresh interval — and to confirm what that interval actually is on the tier in use, rather than assuming the documented default, before the first rotation rather than after.

**The emergency sequence, if a key is actually leaked.** Publish a new key and get it into every cache. Start signing with it. Then remove the old key from the published set, which is the moment forged tokens stop working — so the exposure window is bounded by the slowest cache refresh, which is exactly why that number needs to be known in advance. Then force re-authentication by invalidating refresh token families, because tokens minted with the leaked key must not be exchangeable for new legitimate ones.

**Reducing the blast radius beforehand.** Keys held in a managed store, never in configuration or an image. Ideally never exported at all — signing performed by the store — so there is nothing to leak. Separate keys per environment, so a non-production leak is not a production incident. And short access token lifetimes, so the residual damage after the key is withdrawn expires quickly.

**The part I would insist on.** Rehearsing a rotation on a schedule, in production, before there is an incident. A rotation procedure that has never been executed is an assumption, and this is one where the failure mode — everyone logged out simultaneously — is severe enough that nobody will attempt it for the first time under pressure.

</details>

---

### Q53. How do you agree an API contract before either side has built anything?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By writing the typed models first and publishing the generated document as a draft, so the discussion is about a concrete artifact rather than about intentions. The frontend can generate a client and work against a stub while the implementation is still being written.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not a document written by hand.** A hand-written specification diverges from the implementation immediately and nobody notices, because nothing checks it. If the document is emitted from the typed models that the code actually uses, it cannot describe something the service does not do — the schema is executable rather than described. So the sequence is: write the models, emit the document, publish it as a draft, and only then write the handlers.

**What the conversation is about, given a draft.** Not field names, mostly — those settle in minutes once there is something to look at. The useful discussion is about shape, and it is worth having deliberately:

- **What one screen needs in one call.** If a view always needs a list plus one field from each related entity, that field belongs in the list response. Designing endpoints around screens rather than around tables is what prevents a chatty interface, and it is far easier to argue about while the response is still a model in a branch than after both sides have built against it.
- **Where a batch verb is needed.** A comparison view needing two to five items should be one request, not five, and that is a contract decision rather than an optimisation.
- **What is optional versus nullable**, since those generate different types and the distinction is invisible until someone's client breaks.
- **What the error shapes are.** If only the success shape is declared, every consumer invents its own failure handling. Declaring the error responses is part of the contract, not an afterthought.
- **Which enumerations are open.** A closed set generates a closed type, and adding a member later breaks strict clients.

**Working in parallel after that.** The frontend generates a client from the draft and works against a mock served from the same document, so both sides progress against one artifact. The contract test in the pipeline diffs the emitted document against the published one, so if the implementation drifts from what was agreed, it is a red build rather than a discovery.

**What I ask for in return.** That they regenerate in their own pipeline against the latest published document, so drift shows up as a red build on their side too. And that changes requested after agreement come as a change to the document rather than as a message — because otherwise the contract quietly becomes whatever was said in a call, which is the state the whole arrangement exists to avoid.

</details>

---

### Q54. How do you handle secrets and credentials in an application and its pipeline?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By having as few as possible. Workload identity federation means a service authenticates to cloud resources as itself with no stored credential, which removes the whole class of problem for most of them. What genuinely must be a secret lives in a managed store, is injected at runtime, and is never in an image or a repository.

<details>
<summary><strong>Detailed answer</strong></summary>

**Eliminate first.** The best secret is one that does not exist. A federated workload identity — a cluster service account trusted by the cloud identity provider, mapped to a managed identity per service — means database, storage and message access happen with no connection string and no stored key anywhere in the cluster. The same applies to the deployment pipeline: it authenticates by federation rather than holding a long-lived service principal secret. That removes rotation, leakage and expiry as concerns for the majority of what used to be secrets.

**What remains** — third-party credentials, signing keys, anything the platform does not federate — lives in a managed secret store, referenced by identity rather than copied, and injected at runtime as environment values or mounted files. Never baked into an image, because an image is distributed and cached and lives longer than anyone expects.

**In the pipeline.** Masked variables scoped to protected branches, so a fork or an unprotected branch cannot read them. No secret ever echoed, including in a debug run — and note that a value in a variable can still leak through a command that prints its own arguments or through a tool's verbose output, which masking does not always catch. Applies run only from the default branch under the federated identity.

**Detection, because prevention fails eventually.** A secret scanner in pre-commit and as a pipeline gate, and a scan of history when adopting it on an existing repository. A committed secret is compromised the moment it is pushed, so the response is always rotate first and then clean the history — removing it without rotating is theatre.

**Rotation.** Anything that cannot be federated has a rotation procedure that has actually been executed, because the failure mode of an untested rotation is discovering a consumer nobody knew about at the moment the old credential stops working. Rotation with an overlap window, and the overlap window longer than any cache that holds the credential — which is the same lesson as the signing key rotation, in a different guise.

**Where I would want a review.** Any change to identity configuration or role assignment. Role assignments are declared in infrastructure code specifically so that a widened permission is a reviewable diff rather than a click nobody sees, and I would flag any such change for someone else to look at rather than treat it as ordinary work.

</details>

---

### Q55. How would you demonstrate to an auditor that an access control actually works?

**Project:** cancer-support-platform

**Brief answer**
With three kinds of evidence rather than an assertion: the control's definition in version control with its review history, an automated check that fails when the control is removed, and production records showing it operating — access logged, exceptions recorded and reviewed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why "we have row-level policies" is not an answer.** It describes an intention. An auditor's question is whether the control is present, effective and continuously operating, and each of those needs different evidence. The useful thing about preparing for that question is that answering it properly also makes the control genuinely better — most of what an auditor wants is what an engineer should want anyway.

**Present.** The policy definitions are in migrations in version control, so what is deployed is reviewable and its history shows who changed it and when. Any change went through review. That is a much stronger statement than a screenshot of a current configuration, because it covers the whole period rather than this moment.

**Effective — and this is where most of the work is.**

- **A test asserting the negative case**, and crucially one that enumerates rather than exemplifies: every scoped repository method called with a principal from another scope, asserting empty. A new method is covered automatically, which is the only version that stays true.
- **Evidence that the test can fail.** A check that has never failed has not been shown to check anything, so the control is removed deliberately, the test is observed going red, and the control is restored. For a control whose failure is silent that is the only feedback available, and demonstrating it is what converts a green pipeline from a claim into evidence.
- **Assertions on the control's preconditions.** That the application's database role has no bypass privilege. That the identity is applied with transaction scope, proved by a test running two requests through the same pooled connection and asserting the second sees nothing of the first — because a pooler reusing a backend across requests is exactly where this control silently becomes its opposite.
- **A plan assertion**, since a policy rewritten for readability can hide the partition key from the planner and convert a pruned scan into a full sweep. That is a performance failure rather than a security one, but it is the same class: a change that looks like a tidy-up and is not.

**Continuously operating.** Every access writes an audit row in the same transaction as the access itself, so the trail cannot be lost in a queue. Exceptional access — break-glass — is a distinct, time-boxed grant with a recorded reason and a review inside a day, and the review is itself evidenced. Alert rules live in infrastructure code, so a silenced alert is a reviewable diff rather than a slow decay nobody sees.

**What I would say honestly if asked what could still go wrong.** A platform administrator path exists and is audited rather than prevented; the audit's completeness depends on the write path being the only path; and none of this addresses someone with legitimate access misusing it, which is a detection problem rather than a prevention one.

</details>

---

### Q56. Where should an authorization decision live — the gateway, the application, or the database? How do you choose?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
As deep as the mechanism can be made trustworthy. The gateway is a filter and never the authority; the application is where most decisions land; the database is the strongest place and only where the deployment topology actually supports it. These two systems chose differently for that reason.

<details>
<summary><strong>Detailed answer</strong></summary>

**The gateway.** Good for coarse, route-level decisions: is this token valid, is it the right audience, does this account type belong on this route family. On the health platform the patient and clinician planes are separate audiences, so a clinician token on a patient route is rejected before any application code runs. But it is a filter, never the authority — each service revalidates locally, so bypassing the gateway is not bypassing authentication. A control that only exists at the edge is a control that assumes nothing ever reaches the service another way.

**The application.** Where most record-level decisions live, because that is where the caller, the resource and the business rule are all in scope. The risk is well known: a check that must be remembered at each call site is a control that works until someone adds a call site. The mitigations are structural — enforce it at the router as a dependency rather than inside handlers, and apply the scope in the repository layer in one place rather than per endpoint.

**The database.** The strongest, because a query someone forgets to scope returns zero rows rather than someone else's record. On the health platform the policies are the single most important control in the design, joining through the relationship table so that access is a data question rather than a code question.

**Why the marketplace deliberately did not use it**, which is the interesting half. The catalog read path uses a pooled connection under a shared role. Database-level filtering depends on a per-request session setting, and with a transaction-mode pooler reusing a backend across requests, a session-scoped setting leaks one caller's identity into the next caller's query — turning the strongest control in the design into its exact opposite. Relying on a mechanism the topology cannot support is worse than not relying on it, because everyone believes it is there.

**So the choice rule.** Push it as deep as the mechanism is trustworthy in this deployment, and pay for a weaker mechanism with a stronger test. The marketplace pays for its application-layer filter with a test asserting a cross-scope read returns empty for every scoped repository method, plus an audit row on every administrative bypass. The health platform pays for its database-level control with a pooled-connection leakage test, a role-privilege assertion and a plan assertion.

**And the anti-pattern worth naming.** The same decision implemented in two places with two definitions. Then they disagree eventually, and the one that is wrong is the one nobody is testing. One owner per rule, enforced in the deepest layer it can be, and referenced elsewhere rather than restated.

</details>

---

## Cloud Infrastructure, Kubernetes and Delivery

---

### Q57. What is different about OpenShift compared with plain Kubernetes, and what would you have to learn?

**Project:** cancer-support-platform

**Brief answer**
It is [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") with opinionated defaults, a stricter security posture and its own resources layered on top. The differences that actually bite are the security context constraints — containers do not run as root and are assigned an arbitrary user identifier — and its own build and route objects.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I have worked with.** Deployments to a managed OpenShift cluster, delivered by a GitOps controller from a manifest repository, with migrations as a pre-sync hook and a smoke test as a post-sync hook. So the delivery path and the workload shape are familiar; the platform's own build tooling I have used less.

**The differences that matter in practice.**

- **Security context constraints.** The default policy refuses root and assigns an arbitrary, high-numbered user identifier at runtime. An image that assumes a fixed user, or writes to a directory owned by a specific one, fails. The fix is to build images with group-writable directories and no assumption about the user identifier — which is good practice generally and is simply enforced here. This is the single most common reason an image that runs elsewhere does not run on OpenShift.
- **Routes rather than ingress**, with their own object and their own approach to certificates and termination. Ingress works too, and mixing both is a way to get confused about which is authoritative.
- **Projects rather than namespaces**, which is a namespace with additional defaults and quota attached.
- **Its own build and image stream objects**, which can watch a registry tag and trigger a rollout. Useful, and a second mechanism to reason about when a GitOps controller is also managing the desired state — two systems that both think they own the deployed image is a genuine source of confusion.
- **An integrated registry and an operator-heavy ecosystem**, so a lot of platform capability arrives as operators rather than as raw manifests.

**What I would want to learn deliberately rather than assume.** The exact constraint policy in use and what it permits, because that determines what images can run at all. How the platform's own networking layer is configured, since network policy behaviour differs. The upgrade cadence, which is more opinionated than on a plain cluster and affects planning. And whether the platform's build tooling or an external pipeline is authoritative, because that decides where the source of truth for a deployed version lives.

**What transfers unchanged.** Everything about workload design — probes, resource requests and limits, graceful shutdown, autoscaling signals, pod disruption budgets — and the entire delivery discipline: expand-and-contract migrations, digest-pinned images, declarative desired state with rollback as a revert. Those are the parts that are hard, and none of them are platform-specific.

</details>

---

### Q58. How do you choose between a managed cloud service and running the component yourself in the cluster?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Managed by default, self-hosted when a specific requirement forces it — a feature the managed version lacks, a data-residency or tenancy constraint, or a cost profile that does not work. And the decision is written down with the condition that would reverse it, because it is expensive to revisit casually.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why managed is the default.** What you are buying is not the software, it is the operations: patching, backups, failover, upgrade paths, and someone else being on call for the storage layer. For a relational database, that is a very good trade — a managed instance with point-in-time restore and zone redundancy is better than most teams will operate themselves, and the restore actually works.

**What pushed components in-cluster on the health platform.** The broker, the document store and the search cluster all run in the cluster rather than as managed services, and the honest reasons are a mix: the managed alternatives did not offer the specific features required — the protocol bridge plugin on the broker, particular analyzer configuration on search — and the platform's tenancy and residency requirements were simpler to satisfy inside the cluster than to negotiate per service.

**And the honest cost of that choice.** You own version upgrades, replica membership, shard and replica counts, persistent volume sizing, and the restore procedure. That is real operational work resembling on-premises operations, and the discipline it forces is treating a rebuild as routine — the search index is rebuildable from the primary stores, rehearsed quarterly with a count reconciliation, because a mitigation nobody has executed is an assumption.

**The questions I actually ask.**

- Does the managed version support what we need, at the version we need? Feature gaps are the usual disqualifier and they are specific rather than general.
- Is this stateful? Stateful components in a cluster are where the operational cost concentrates, so the bar is much higher for a database than for a stateless service.
- Who is on call for it at three in the morning, and do they have a rehearsed restore?
- What does it cost at our actual volume, including the operational time, not just the instance price?
- Is there an exit? A managed service with a proprietary interface is a different commitment from one speaking a standard protocol.

**What I would resist.** Self-hosting because it is cheaper on paper. The instance cost is the visible part and the smaller part; the invisible part is the upgrade nobody scheduled and the restore nobody tested. And equally, adopting a managed service whose behaviour under failure nobody has tested — managed does not mean it fails in the way you assumed.

</details>

---

### Q59. Explain requests and limits, and what goes wrong when they are set badly.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Requests decide scheduling and guarantee; limits cap consumption. The two failure modes are opposite and both common: processor limits set too low cause throttling that looks like slow code, and memory limits set too low cause the process to be killed abruptly with no stack trace.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** The request is what the scheduler reserves and what the pod is guaranteed. The limit is the ceiling. For processor time, exceeding the limit means throttling — the container is descheduled for the rest of its accounting period. For memory there is no throttling; exceeding the limit means the process is terminated.

**Processor limits set too low.** The symptom is latency spikes that correlate with nothing visible: the application is not busy, the database is fine, and periodically requests take much longer. What is happening is that the container burned its quota early in the accounting window and is being descheduled. It is particularly cruel with garbage collection and with startup, where a brief legitimate burst gets throttled and the startup probe then fails, producing a restart loop that looks like a crash. The tell is the throttling metric, which is not on most default dashboards and should be.

**Memory limits set too low.** The container is killed. No stack trace, no application log line, just a restart with a status the orchestrator records and nobody reads. It shows up as intermittent restarts under load and is frequently misdiagnosed as a crash bug. The subtlety with a runtime that manages its own heap is that memory use grows until collection, so a limit set to observed steady-state use will be exceeded routinely.

**Requests set too high** wastes capacity — nodes fill up with reservations nothing uses, the cluster autoscaler adds nodes, and the bill grows for idle guarantees.

**Requests set too low** means the pod is scheduled onto a node with nothing to spare and is a first candidate for eviction under pressure. Its behaviour then depends on what else lands next to it, which makes performance irreproducible.

**How I set them.** From observed usage under realistic load, not from a guess: request near the steady-state median, limit with real headroom above the observed peak. For memory I prefer request and limit equal on anything important, so the pod gets the strongest scheduling guarantee and its behaviour does not depend on its neighbours. For processor I often set a generous limit or none on latency-sensitive services, because throttling a request-serving process to save capacity it was not going to use anyway is a bad trade.

**And I watch the throttling and termination counters as first-class signals**, because both failure modes are invisible in application metrics — one looks like slow code, the other looks like a crash.

</details>

---

### Q60. A pod is being killed and restarted repeatedly. Walk me through the diagnosis.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Read the termination reason first, because it separates the whole problem space in one step: killed for memory, failed a probe, exited non-zero, or evicted. Each has a different cause and a different fix, and guessing between them wastes the most time.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: the last state and its reason.** The pod's status carries the previous container's exit reason and code. Four broad outcomes:

- **Killed for exceeding memory.** No application log will explain it — the process was terminated, not thrown. Look at whether the limit is below the actual peak, whether there is a leak (memory climbing monotonically across restarts rather than sawtoothing), or whether one request shape allocates hugely, which is the usual cause when restarts correlate with a specific endpoint or a large import.
- **A probe failing.** Liveness failing restarts the container; readiness failing only removes it from service. If liveness is failing under load rather than at startup, the probe is measuring load rather than liveness and it is causing the outage it claims to detect. If it fails at startup, the container needs longer than the probe allows, and the fix is a startup probe rather than a more generous liveness threshold.
- **A non-zero exit.** An application crash or a failure to start — a missing configuration value, an unreachable dependency, a failed migration. The logs from the previous container instance are where the answer is, and they need to be fetched explicitly since the current instance's logs will not have it.
- **Evicted.** Node pressure — disk, memory — rather than anything about this pod. Look at the node, not the workload.

**Step two: the pattern.** Immediately on start every time is configuration or a dependency. After some minutes is memory or a leak. Under load is limits or probes. All pods at once is a deploy or a shared dependency; one pod is a node.

**Step three: reproduce with the safety off.** Run the image with generous limits and probes relaxed, and see what it does. If it survives, the problem is the limits or the probes rather than the code, which is a much better place to be.

**Two specifics worth naming.** A worker being restarted mid-task is not just an availability problem — it is a durability question, and the answer must be that redelivery covers it. If a restart loses work, the acknowledgement mode is wrong. And a liveness probe hitting an endpoint that touches the database will fail during a database blip and restart every pod simultaneously, converting a brief dependency problem into a full outage. Liveness should test the process, readiness should test the dependencies.

</details>

---

### Q61. How do you make a worker shut down safely mid-task?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Stop consuming first, finish the in-flight task, then exit — bounded by the termination grace period, with task chunk sizes small enough to finish comfortably inside it. And behind all of that, at-least-once delivery so an ungraceful kill causes redelivery rather than loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence.** On termination the orchestrator runs a pre-stop hook and sends a termination signal, then waits for the grace period before killing the process. So:

1. **Pre-stop: stop accepting new work.** Cancel the broker consumer so no further messages are delivered to this worker. Anything already prefetched is either processed or returned unacknowledged.
2. **Finish the in-flight task.** The signal handler sets a flag; the task loop completes the current item and does not start another.
3. **Acknowledge, release resources, exit cleanly.**

**The numbers have to agree, and this is where it usually goes wrong.** The grace period must exceed the longest realistic task duration, or the process is killed mid-task anyway and the graceful shutdown is decorative. Two ways to make that true: raise the grace period, or make tasks short. I strongly prefer the second — chunking a large import into pieces sized to finish well inside the window means the worker is never far from a clean stopping point, and it makes the whole system more tolerant of every kind of interruption, not just deploys.

**Why redelivery still has to work.** Graceful shutdown is best-effort. A node failure, an out-of-memory kill or an exceeded grace period all skip it. So the durable guarantee is late acknowledgement plus idempotent handling: the message is only acknowledged after the work completes, so an ungraceful death causes redelivery, and the handler tolerates running twice because the guarantee lives in a database constraint. Graceful shutdown reduces how often that path is exercised; it is not what makes the system correct.

**For long-running work specifically.** Checkpoint progress so a resumed task does not redo everything — an import that records which chunk it completed can restart at the boundary rather than at the beginning. This matters more as tasks get longer, and it is the difference between a redelivery costing seconds and costing an hour.

**For the web tier**, the same shape with different mechanics: readiness fails first so traffic stops arriving, a brief pause covers the propagation delay through the load balancer, then in-flight requests complete. Skipping the pause is the classic source of connection errors during an otherwise clean rollout — the pod stops before the routing layer has noticed.

</details>

---

## Terraform, CI/CD and GitOps

---

### Q62. How do you structure Terraform so more than one person can work on it?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By splitting state along blast-radius lines rather than by resource type, using one module set with a variables file per environment, and locking state so two applies cannot collide. The structure question is really a question about what one careless apply can destroy.

<details>
<summary><strong>Detailed answer</strong></summary>

**State splitting is the main decision.** One monolithic state means every apply plans the whole estate, plans take a long time, everyone contends for the lock, and a mistake can affect anything. So state is split, and the seam I use is blast radius and change frequency together: the network and identity layer changes rarely and is catastrophic to get wrong; the data layer changes rarely and holds the data; the application layer changes constantly and is recoverable. Three states, and the application layer's identity does not have permission to touch the other two.

**One module set, variables per environment.** Environments differ in instance sizes and counts, not in topology. That is what makes a staging smoke test meaningful — staging is the same architecture at smaller sizes rather than a different architecture that happens to share a name. Copying the configuration per environment guarantees divergence within a quarter.

**The operational rules.**

- **State in a versioned, locked backend**, so two concurrent applies cannot corrupt it and a damaged state can be recovered from a previous version.
- **Applies run only from continuous integration on the default branch**, authenticated by workload identity federation. Nobody applies from a laptop, so state and reality cannot diverge through a helpful local fix.
- **Plan on every merge request, posted for review.** The plan is the review artifact. Reviewing configuration without the plan means reviewing intent rather than effect, and the two differ most on the changes that matter — a plan showing a resource being destroyed and recreated is the finding, and it is invisible in the source diff.
- **Production has a manual gate between plan and apply**, so a human confirms the plan they read is the plan being applied.

**What is in it that people leave out.** Alert rules, and role assignments. Alert rules in code means a hand-silenced alert is a reviewable diff rather than something discovered six months later when the thing it watched failed quietly. Role assignments in code means a widened permission is a diff rather than a click nobody sees.

**The concentration of privilege, stated honestly.** The deploy identity is the largest single concentration of privilege in either design. The right shape is to split it — a plan-only identity for merge requests, an apply identity gated on protected branches, and the network and data modules under their own identity. That is a decision worth taking before the first production apply rather than after an incident, and it is the kind of change I would flag for review rather than make on my own judgement.

</details>

---

### Q63. What do you do about a resource someone created by hand in the portal?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
It shows up in the plan and it fails the pipeline. Then it gets imported into state and codified, or removed. What I would not do is quietly reconcile it, because the moment the code stops describing reality, infrastructure as code becomes decorative.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why drift has to be a failure rather than a warning.** A configuration that describes most of the infrastructure is worse than one that describes none, because people trust it. The plan is the mechanism that keeps the description honest, and if drift is tolerated then the plan becomes noise nobody reads, which is exactly when the destructive change slips through unnoticed.

**What actually happens.**

1. **Detected.** A scheduled plan on the default branch, not only on merge requests, so drift from something outside the pipeline surfaces within a day rather than at the next deploy.
2. **Understood before touched.** Why does it exist? Usually the answer is an incident — someone scaled something or opened a firewall rule at two in the morning, correctly. That is a legitimate act and the failure is not having codified it afterwards.
3. **Import or remove.** If it should exist, it is imported into state and written into the configuration, so the next plan is clean. If it should not, it is removed through the configuration.
4. **Never resolved by applying blindly.** A plan proposing to destroy a hand-created resource might be right, or it might be about to delete something an incident depends on. That decision needs a person.

**The emergency case, handled explicitly.** Break-glass changes will happen and pretending otherwise produces a policy people work around. The rule is that a manual change is permitted during an incident and must be codified within an agreed window, tracked as a ticket created at the time. That keeps the discipline without making the incident harder.

**Two related habits.** Everything created by the pipeline is tagged with its origin, so an untagged resource is immediately identifiable as unmanaged. And nobody has standing write access to the production subscription — a human needing it goes through a time-bound elevation that writes an audit record. That is the control that actually reduces drift, because it makes the manual path visible rather than convenient.

**The uncomfortable case.** A resource created by another team, in a subscription we share. That is a conversation rather than a technical fix, and the resolution is usually a boundary — separate resource groups or subscriptions with separate ownership — rather than an agreement to be careful.

</details>

---

### Q64. How do you know a pipeline gate can actually fail?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By having seen it go red for a real reason. That is the only acceptable evidence, and the way to get it deliberately is a known-pass and known-fail pair: introduce a change the gate should catch, confirm the build fails, restore. Two inputs, a few minutes.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the question needs asking at all.** A gate that cannot fail is indistinguishable from a gate that works, from the outside — both are green forever. And a green pipeline is the single most trusted signal in most teams. So a broken gate does not merely fail to protect; it actively provides false confidence, and it will keep doing so until an incident.

**The specific ways gates turn out to be decorative.**

- **Configured to report rather than enforce.** A quality or scanning stage that prints findings and exits zero. Very common, because report mode is the sensible way to introduce a tool and nobody comes back to flip it.
- **Exit status lost through a pipe.** A command piped through a log filter reports the filter's status, not the command's. The fix is capturing the status on the command's own line and exiting with it, and this one is easy to introduce accidentally while making output readable.
- **A step in a shell that exits before it runs.** Under strict error handling, a search that correctly finds nothing returns non-zero and kills the step — which is the passing branch of an assert-absent check, dying before it prints anything.
- **Invoked differently from how it runs locally.** Some analysers report different findings for one file alone than for a directory sweep, so verifying a guard through a convenient local invocation leaves it unverified in the pipeline. The invocation has to be copied from the pipeline definition rather than approximated.
- **A test that passes for a reason unrelated to its name**, because the fixture satisfies the assertion before the logic under test is reached.

**What I do about it.**

- **Verify each gate once, deliberately, with a real known-fail input.** Not a syntax error — a mutation that leaves the file parsable, because a syntax error makes everything fail at once, which reads as overwhelming evidence and is worthless. It is a could-not-run, not a catch.
- **Three outcomes, never two: pass, fail, and could-not-run.** A check with no explicit could-not-run branch folds a tool error or a mutation that did not take into whichever branch was written first, and that is always the one confirming what you expected.
- **Commit a known-pass and known-fail pair for anything guarding an invariant**, so weakening the gate later fails that pair. This is the only mechanism I know that makes a gate resistant to being quietly loosened.
- **Report on gate history.** A stage that has never gone red is either perfect or broken. Knowing which is worth a look.

**Where I apply the same scepticism.** Alerts and monitoring, identically. An alert rule with a typo in a label matches nothing and reports nothing, forever, and the only evidence it works is having seen it fire.

</details>

---

### Q65. How do you answer "what exactly was running in production at two o'clock last Tuesday"?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
From version control, if the desired state is a commit and images are referenced by digest. Then the answer is a revision at a timestamp, not an archaeology exercise across deploy logs — and that property is most of why the regulated system uses a pull-based delivery model.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it is a hard question in most systems.** A deploy job ran, and what it produced depends on what its inputs resolved to at the time — a mutable tag, a dependency range, a configuration value read from somewhere else. The job log says it succeeded. Reconstructing the actual artifact months later means correlating a build number, a registry tag that may have been repointed, and a configuration store with no history.

**What makes it answerable.**

- **Images referenced by digest, not by tag.** A tag is a pointer that can be repointed; a digest is the content. This is the single most important part — without it, "we deployed version 2.3.1" names a label rather than an artifact.
- **Desired state as a commit.** The manifest repository holds what should be running, so the state at any timestamp is a revision. A rollback is a revert of that revision rather than a re-run of a job whose inputs may have changed since.
- **A controller reconciling that state continuously**, so drift between what is declared and what is running is detected rather than inferred. Without reconciliation, a hand-edited resource survives silently until the next deploy overwrites it, and nobody can say which state was in effect during an incident.
- **Configuration in the same repository as the manifests**, or at least versioned, so a change to a value is as traceable as a change to code.
- **Infrastructure in version control too**, including alert rules and role assignments, so "was this alert enabled on Tuesday" and "who could reach this resource" are also queries rather than guesses.

**The credential property that comes with the same arrangement.** Because the pipeline's final act is committing an image digest rather than talking to the cluster, no pipeline job holds cluster credentials at all. That removes a broad standing privilege from a system that runs code from every merge request, and it is the reason I would choose this model on a regulated system even setting the auditability aside.

**What it does not answer, honestly.** What data was in flight, what feature flags were set if flags live outside version control, and what a human did by hand during an incident. Those need their own records — flag changes with an audit trail, and manual changes tracked as tickets at the time. And the gap that catches people: a long-lived pod is running the image it started with, so correlating the declared digest against what is actually running is a separate check rather than an assumption.

**On the marketplace**, which deploys directly rather than through a controller, the equivalent evidence is the recorded digest per deploy plus the pipeline history. Weaker, and adequate for that system — and stating which one is weaker is more useful than claiming both are equal.

</details>

---

### Q66. How do you roll back — application code, database schema, and infrastructure?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Application code by redeploying the previous digest or reverting the manifest commit. Schema, deliberately, not at all — expand-and-contract means the old code runs against the new schema, so there is nothing to undo. Infrastructure by reverting the configuration and applying, with the caveat that some resources do not roll back cleanly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Application code.** The previous image by digest, not by tag, because a mutable tag can have been repointed and then "the previous version" is not what you think. On the GitOps side that is a revert of the manifest commit; on the direct-deploy side a redeploy of the recorded digest. Either way it should be one action, take a couple of minutes, and require no decisions.

**The schema is the interesting one, and the answer is that it is not rolled back.** Migrations are expand-only: a release adds nullable columns, new tables and concurrently-built indexes. Removals land at least one release later, once nothing reads the old shape. The consequence is that the previous image runs correctly against the current schema throughout, so rolling back the code needs no schema change at all.

That is a deliberate substitution of one hard problem for a discipline. A down-migration on a table with hundreds of millions of rows is not something anyone will run under pressure — it is slow, it is untested, and if the forward migration destroyed data the down migration cannot recreate it. So the design does not depend on one existing. A migration that cannot be written in expand-and-contract form gets split across two releases; that is a rule rather than a case-by-case judgement.

**Infrastructure.** Revert the configuration and apply. It works for most changes and there are real exceptions worth knowing in advance: a resource whose change forces replacement will be destroyed and recreated on the way back, which for anything stateful is not a rollback; some settings are one-way; and a reverted change may not restore a dependent resource's state. So for infrastructure the more useful discipline is reading the plan properly before the first apply, since the reverse plan is not guaranteed to be symmetric.

**What makes a rollback actually work in practice**, beyond mechanism: it has to be rehearsed. A rollback path nobody has executed is an assumption, and the moment you need it is the worst moment to find out that the previous image no longer starts because a configuration key was removed. So the rollback is exercised as part of a release rather than trusted.

**And knowing when not to.** If the bad release has already written data in a new shape, rolling back the code means the old version meets data it does not understand. That is the case where rolling forward with a fix is correct, and recognising it quickly is the actual skill — which is why the question I ask before any risky release is what the bad version will have written by the time we notice.

</details>

---

### Q67. How do you keep a pipeline honest when everyone is under pressure to merge?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By making the gates hard to weaken quietly — configuration in code and reviewed, no ad-hoc skip mechanism, and a check on the checks — and by making the pipeline fast enough that people are not motivated to route around it. Most gate erosion is a response to friction rather than to disagreement.

<details>
<summary><strong>Detailed answer</strong></summary>

**How gates actually erode.** Rarely by decision. It is a skip flag added for one urgent release and never removed; a threshold lowered to unblock a merge and never raised; a flaky test marked as skipped that stays skipped; a stage made non-blocking during an incident. Each is reasonable at the time and the aggregate is a pipeline that cannot fail.

**The controls I would put in place.**

- **Pipeline configuration is code, reviewed like code.** Weakening a gate is a diff someone approves, not a setting someone changes.
- **No general skip mechanism.** A commit-message flag that bypasses the pipeline will be used, and its use will not be reviewed. If an emergency path is genuinely needed, it should require a named approver and produce a record.
- **A check on the checks.** For anything that guards an invariant, a known-pass and known-fail pair committed alongside it, so if someone loosens the gate, that pair fails. This is the only mechanism I know that makes a gate resistant to being quietly weakened, and it costs very little.
- **Quarantine rather than skip for flaky tests.** A skipped test disappears; a quarantined one still runs, still reports, and has an owner and a deadline. A flaky test is a defect in the test or a race in the code, and treating it as noise means eventually ignoring a real failure.
- **Report on gate health.** How often each stage fails, and whether any has never failed. A stage that has never gone red is either perfect or broken, and it is worth knowing which.

**And attack the friction, because that is the actual driver.** Parallelise stages, cache properly, run the affected subset on merge requests and the full matrix on merge, and make failures diagnosable — half the pressure to bypass a gate comes from a failure message nobody can interpret. A pipeline that is fast and whose failures are clear does not get argued with nearly as much.

**Where I would hold firm.** Not shipping with the authorization boundary incomplete, not skipping expand-and-contract, not disabling a gate to get a release out. Those failures are silent and expensive to undo, and they are exactly what the pipeline exists for. If someone senior wants it anyway, I state the cost in writing and the decision is theirs — but I would not make that decision myself under time pressure, because time pressure is the condition under which it is most likely to be wrong.

</details>

---

## Code Quality Gates and the Toolchain

---

### Q68. If you had to halve pipeline time, which quality tool would you drop first, and which would you never drop?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
I would drop nothing first — I would parallelise, cache and split by relevance, because almost all of the twenty to thirty minutes is one stage and the tools are seconds. If genuinely forced to remove a gate, the formatter and the duplication metrics go before anything that can catch a defect.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the time actually is, which reframes the question.** Linting, formatting and type checking are seconds. Static analysis is a minute or two. Almost the entire pipeline duration is the integration stage bringing up real data stores and running against them, plus image build and scanning. So "drop a quality tool" would buy nothing measurable, and it is worth saying that rather than accepting the premise.

**What I would do instead, in order.**

- **Parallelise independent stages.** Lint, type check and unit tests have no reason to run in sequence.
- **Fix the caching.** Dependency installation and image layers rebuilt from scratch every run is usually a large share of the time and it is a configuration fix, not a trade-off.
- **Split by relevance.** Merge requests run the affected integration subset; the full matrix runs on merge to the default branch. That preserves coverage at the point it matters while shortening the loop where it is felt.
- **Reuse containers across tests** rather than per test, with transactional isolation per test instead of teardown.
- **Move scanning off the critical path** where it can be: scan the built image in parallel with deployment to a non-production environment rather than before it.

**If I genuinely had to remove gates**, the order and the reasoning.

1. **Formatting checks in the pipeline.** Enforced by a pre-commit hook anyway, so the pipeline check is a backstop. Lowest information content of anything there.
2. **Duplication and complexity metrics.** Useful as a trend, rarely the thing that stops a defect.
3. **Import layering rules** — reluctantly, because architecture erodes quietly and this is what stops it, but the erosion takes months while a defect takes a day.

**What I would not drop, and would argue about.**

- **The integration stage against real stores.** It is the slow one and it is the one people propose cutting, and it is precisely what catches the query plans, the projection behaviour and the broker semantics that a mocked test passes while broken. A mocked broker cannot fail the way a real one does.
- **Strict type checking.** Seconds, and it catches a whole class at the boundary.
- **Vulnerability scanning.** It is the only thing looking at what your dependencies did rather than what you did.

**And the honest framing I would offer.** A fast pipeline that cannot catch a broken migration is worse than a slow one that can, because the wait simply moves to production where it costs more and lands on someone else. If the real problem is that a twenty-minute wait is painful, the fix is arranging to have something else legitimately in flight, not weakening the thing that makes merging safe.

</details>

---

### Q69. How do you introduce strict type checking into a codebase that was never typed?

**Project:** general

**Brief answer**
Incrementally, module by module, with the strictness gate applying only to what has been converted. Turning it on globally produces thousands of findings and a team that learns to ignore the tool, which is worse than not having enabled it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The approach.**

1. **Turn it on in a permissive mode across the whole codebase**, so it runs and reports without failing anything. That establishes the baseline and, more usefully, shows where the pain is concentrated — usually a few modules with dynamic behaviour.
2. **Make it blocking for a small set of modules first**, chosen deliberately: the data models and the domain layer, because they are the ones every other module depends on, and typing them propagates useful information outward. Typing the leaves first gets you much less.
3. **Add modules to the strict set as they are converted**, in separate merge requests that do nothing else. A typing change mixed with a behavioural change is unreviewable, because the diff is enormous and the important part is three lines of it.
4. **Ratchet.** The set only grows. A new module is strict from creation. This is what stops the effort decaying — without a ratchet, converted modules drift back.

**What I would be careful about.**

- **Not letting the escape hatches become permanent.** Ignore comments and untyped-any annotations are legitimate during conversion and need a reason attached and a way to count them, so the debt is visible and shrinking rather than invisible and stable.
- **Not contorting the code to satisfy the checker.** If typing something honestly requires a baroque construction, the type is telling you the design is unclear — that is worth acting on, but sometimes the right answer is a narrow, documented escape rather than a rewrite.
- **Third-party stubs.** A large share of the initial findings are missing type information for dependencies rather than defects in your code, and it is worth separating those out early or the signal is drowned.

**What it buys, so the effort is justified rather than assumed.** Refactoring becomes tractable, because the checker enumerates the call sites affected by a shape change. The optional-value class of defect largely disappears at the boundary. And on an asynchronous codebase it catches a coroutine that is never awaited, which is a genuinely nasty runtime bug that produces no error and silently does nothing.

**And the honest caveat.** It is a real investment and its benefit is slow and diffuse, so it needs to be proposed as such rather than as a quick win. On a codebase nobody is changing much, it may simply not be worth it.

</details>

---

### Q70. A static analysis gate fails your merge on something you think is a false positive. What do you do?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Assume it is right first and look properly, because a decent fraction of the time it is seeing something I am not. If it genuinely is wrong, suppress it at the narrowest scope with a written reason, and if the same rule keeps misfiring, change the rule for everyone rather than suppressing repeatedly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I start by assuming it is right.** Findings that feel like false positives are often correct in a way that is not obvious — a broad exception clause that does swallow something, a resource that is not closed on an error path, a comparison that behaves differently than it reads. The instinct that a tool is being pedantic is exactly the instinct that lets a real defect through, and it costs ten minutes to check.

**When it really is wrong.** Suppress at the narrowest possible scope — the line, not the file, and never the rule globally — with a comment saying why. A bare suppression is a defect in itself: the next person cannot tell whether it was considered or whether someone was in a hurry, so they leave it forever.

**When the same rule misfires repeatedly.** That is not a suppression problem, it is a configuration problem. Turn the rule off for the codebase or for a directory, in the shared configuration, with the reason recorded. Scattering identical suppressions across thirty files is worse in every way: it is invisible as a pattern, it cannot be revisited, and it trains people to add suppressions reflexively.

**Where I would push back on the gate itself.** Two cases. A coverage threshold applied to the whole codebase rather than to new code — that is unachievable on a legacy codebase and it produces exactly the fake tests it was meant to prevent. And a security rule producing a high volume of noise in a context where it does not apply; a noisy security rule is worse than none, because it teaches people to skim security findings.

**How I raise that.** With data rather than annoyance: here are the last thirty findings from this rule, this many were real, here is what I propose. A specific proposal with evidence usually gets accepted. "This rule is annoying" does not, and reasonably so.

**And what I would not do.** Suppress it to get the merge through and plan to look later. That is how a suppression becomes permanent, and it is the mechanism by which a whole gate stops meaning anything — one reasonable exception at a time.

</details>

---

### Q71. A vulnerability scanner reports a critical finding in a base image with no fix available. What do you do?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Establish whether it is reachable in our usage before doing anything else, because most base-image findings are in components the application never invokes. Then either remove the component, change the base image, or accept it with an expiry and a written reason — never suppress it silently.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: is it reachable?** A finding in a package present in the image is not the same as a finding in code the application executes. A vulnerability in a shell utility or a library the application never imports is a real finding about the image and often not an exploitable path in this deployment. That does not make it acceptable, but it entirely changes the urgency and the response.

**Step two: can it just go away?** In order of preference:

- **Remove the component.** A slimmer base image, or a multi-stage build where the runtime stage carries only the runtime, removes whole categories of finding permanently. Most base-image findings are in things a Python service does not need, and this is the fix that keeps paying.
- **Change the base image** to a variant where the component is patched or absent.
- **Update the layer above.** Sometimes the finding is in a transitive dependency that a newer version of a direct dependency drops.

**Step three: if none of those work.** An explicit, time-bounded exception with a written justification: why it is not reachable in our deployment, what compensating control exists, who owns it, and an expiry date after which it fails the build again. The expiry is the essential part — an exception without one is a permanent silent suppression, and the whole value of the gate is that it is not silent.

**Who decides.** Not me alone. A critical finding accepted into production is a security decision, and it goes to whoever owns security with the analysis attached. My job is to bring the analysis, not the verdict.

**The habit that prevents most of this.** Rebuild base images on a schedule rather than only when the application changes. A service not deployed for two months is running a two-month-old base image with two months of accumulated advisories, and nothing will tell you because nothing changed. Scheduled rebuilds plus scheduled rescans of what is actually running is what turns this from a build-time formality into an operational control.

**And a related honesty point.** The scan proves what is in the image, not what is running. A long-lived pod is running the image it started with. Correlating deployed digests against scan results is the step that closes that gap, and it is one people skip.

</details>

---

### Q72. How do you keep a service's dependencies current without a monthly surprise?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A committed lockfile so every environment resolves identically, automated update proposals on a regular cadence in small batches, and a test suite good enough that a green build on an update is actually evidence. The surprise comes from batching six months of updates into one change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The lockfile is the foundation.** Direct dependencies with permissive constraints and a committed lock resolving every transitive package to an exact version, so the pipeline, the developer's machine and the production image install identical trees. Without it, "works locally" and "works in production" are two different dependency graphs and the difference surfaces at deploy time. Adopting this removed a class of deploy-time surprise on the health platform that had come from drift between modules.

**Updates on a cadence, in small batches.** Automated proposals weekly, grouped sensibly — patch updates together, each significant version bump on its own. Small and frequent is dramatically cheaper than large and rare: a single patch batch that breaks something is trivially bisected, whereas a quarterly update touching forty packages is a research project, and the fact that it is a research project is why it keeps being deferred, which makes the next one worse.

**Separating the kinds of update.**

- **Security updates** go promptly and out of cadence.
- **Patch and minor updates** are the weekly batch, largely automatic if the suite is trustworthy.
- **Major versions** get their own change, their own reading of the release notes and their own testing. These are the ones that need a person, and treating them as routine is how a breaking change ships quietly.
- **The language runtime** is its own project, planned rather than absorbed.

**What makes automation safe.** The suite has to be good enough that green means something — which means integration tests against real data stores, because most dependency breakage is at the boundary with the database driver, the broker client or the serialisation library, and a mocked test will not see it. Auto-merging updates on a suite that only exercises mocks is how you deploy a broken driver.

**And pin the tools too.** The linter, the type checker and the formatter are pinned, because an unpinned linter updating overnight fails the build for everyone on code nobody touched. Tool versions are part of the environment and deserve the same treatment as libraries.

**The honest trade-off.** This is ongoing maintenance that produces no features, and it is the first thing dropped under pressure. The argument I would make for keeping it is that it is not optional work, it is only deferrable — and deferring it converts small regular effort into an occasional large emergency, usually triggered by a security advisory at the worst moment.

</details>

---

## Testing: Pytest, Test Management and Coverage

---

### Q73. Describe your experience with Pytest. What do your fixtures look like on a project with real data stores?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Session-scoped fixtures bring the containers up once and run migrations; a function-scoped fixture wraps each test in a transaction that is rolled back afterwards. That combination gives real database behaviour with per-test isolation and no teardown cost.

<details>
<summary><strong>Detailed answer</strong></summary>

**The layering.**

- **Session scope**: start the containers — database, document store, cache, broker, search — at pinned versions matching production, and run the migrations once. Expensive, done once.
- **Function scope**: open a connection, begin a transaction, hand the test a session bound to it, and roll back at the end. Every test sees a clean database without truncating tables or re-running migrations, which is what keeps a suite with real stores fast enough to be tolerable.
- **Factories rather than fixture data files.** A helper that creates a valid entity with sensible defaults and accepts overrides for the fields the test cares about. A test then reads as "a published listing from a suspended vendor" rather than as twenty lines of setup, and the intent is visible.

**The stores that do not participate in a transaction.** The document store, the cache, the broker and the search index have to be cleaned explicitly — a per-test namespace or prefix, or a truncation between tests. Getting this wrong produces the worst kind of flakiness: order-dependent failures where a test passes alone and fails in the suite.

**The fixture discipline I care most about**, because I have been bitten by it. One fixture, one behaviour. A fixture carrying several conditions can only honestly exercise the first that fires, and every later assertion on it is decoration. I had a set of checks pass for reasons unrelated to what they named because a fixture carried a condition that short-circuited before the logic under test was ever reached — so both the thing being tested and a second thing looked covered, and neither was. Now the trigger for the behaviour under test appears only in the region under test, and nothing else in the fixture can satisfy the assertion.

**Other things I rely on.** Parametrisation for boundary cases, so one test body covers the empty, single and many cases with the failure naming the case. Marks to separate fast unit runs from the slow integration suite, so the local loop stays quick. Dependency overrides at the application level to substitute a controlled principal or an external client.

**And the check I run on any test I intend to trust.** Break the behaviour it names, confirm it goes red for the expected reason, restore. A test that has never failed has not been shown to test anything, and this takes seconds at the time of writing and is nearly impossible to retrofit honestly later.

</details>

---

### Q74. How do you test asynchronous code and message consumers?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Against a real broker, not a mock, because the behaviours worth testing are redelivery, acknowledgement and ordering — none of which a mock reproduces. And the important tests are the unpleasant ones: kill the consumer mid-task, deliver the same message twice, deliver two messages out of order.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why a mocked broker is close to worthless here.** It confirms the handler function does what the handler function does. Everything that actually goes wrong is in the interaction: a message acknowledged before the work completed, a handler that is not idempotent under redelivery, a binding pattern that matches nothing, a payload that fails validation and is retried forever. A mock passes all of those while broken.

**The tests I would insist on for any consumer.**

- **Redelivery is harmless.** Deliver the same message twice, assert one row and one side effect. This is the test that proves the idempotency guarantee is real — and it should be proving a database constraint rather than an in-memory check, so it still holds after a restart.
- **Out-of-order delivery does not roll state backwards.** Deliver a newer event then an older one, assert the newer state survives. This is what the source revision on the event is for, and without the test it is an intention.
- **A crash mid-task causes redelivery, not loss.** Kill the worker while a task is in flight and assert the work completes afterwards. This is the test that actually verifies acknowledgement mode is configured as believed, and it is the one nobody writes.
- **A poison message dead-letters rather than looping.** Assert the attempt count is bounded and the message ends up somewhere visible.
- **The binding topology is what you think.** Publish with the routing key the producer really uses and assert it arrives. Binding configuration is silent when wrong — a queue bound with a typo receives nothing and reports no error — which is exactly why it belongs in a test rather than in a management interface someone eyeballs.

**On the asynchronous code itself.** An async-aware test runner, and time controlled rather than waited on — no sleeps, because a sleep-based test is either slow or flaky and usually both. Where a test must wait for a consumer, poll for the expected condition with a timeout and fail with a message naming what was expected, rather than sleeping a fixed interval and hoping.

**And the trap specific to async testing.** An unawaited coroutine silently does nothing and the test passes. The type checker catches most of these, and a warnings-as-errors setting catches the rest — worth configuring, because the failure is completely silent otherwise.

</details>

---

### Q75. What is your approach to test data, and why not use production data?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Synthetic, generated by factories, with realistic volume where volume is the thing under test. Production data is not an option on a clinical system for legal reasons, and it is a bad idea generally — it makes tests non-reproducible and it silently spreads sensitive material into every environment.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not production data.** On the health platform it is disqualified outright: patient data outside the production tenancy has no lawful basis and anonymisation of clinical free text is far harder than people assume — a note can identify someone through circumstance without containing a name. Beyond that, and applying to any system: a test whose fixture is a snapshot is not reproducible, it drifts, it fails for reasons unrelated to the change, and copies of it end up on laptops and in backups nobody tracks.

**What I use instead.**

- **Factories producing valid entities with overrides**, so a test declares only what it cares about.
- **Deterministic generation with a fixed seed** where randomness is useful. Random data finds edge cases; unseeded random data produces failures nobody can reproduce, which is the worst of both.
- **Realistic volume where volume is the point.** This one is worth insisting on: a query performance test against a hundred rows tells you nothing, because the planner chooses differently at different scales and a sequential scan on a small table is correct. So the integration environment seeds a table to a size where the plan is the production plan. Without that, every plan assertion is meaningless.
- **Deliberately awkward values**, since real data is not tidy: names with non-Latin characters and apostrophes, timestamps across a daylight-saving boundary, an empty collection, a maximum-length string, a zero, a negative. Most boundary defects are found here rather than by volume.

**Where a production shape is genuinely needed** — investigating a defect that only occurs on real data — the answer is a controlled export with the sensitive fields replaced, produced by a reviewed process into a restricted environment, with an expiry. Not a copy of the database onto someone's machine. And on the clinical system, not at all: the investigation happens in production with the access audited, rather than by moving the data.

**One thing I would add.** The same factories are useful for seeding a local environment, which means the development stack is populated with data that exercises the awkward cases by default. A developer whose local data is all tidy will keep writing code that assumes tidy data.

</details>

---

### Q76. The suite passes on merge requests and fails on the default branch. What is going on?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Usually one of four things: the branch ran a different subset, two independently-green branches merged into a conflict no test saw, the default branch runs against something merge requests do not, or a test is order-dependent and the fuller run changes the order.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four causes, and how to tell them apart quickly.**

- **Different scope.** If merge requests run an affected subset and the default branch runs the full matrix, then a passing merge request never proved anything about the failing test. This is the most common cause and it is a deliberate trade-off rather than a bug — the cost of a shorter feedback loop is exactly this. The check is whether the failing test was in the merge request's selection at all.
- **Semantic merge conflict.** Two branches, each green, each correct against the base. One renames a function, the other adds a call site. Version control merges both cleanly and the result is broken. Nothing tested the combination, because the combination did not exist until the merge. This is what a merge queue or a required rebase-and-rerun against the current default branch exists to prevent, and if it happens more than occasionally that is the fix.
- **Environment difference.** The default branch pipeline has credentials, a real external dependency, or a deploy target that merge request pipelines do not — often for good security reasons, since secrets are scoped to protected branches. So a whole class of test only ever runs there, and the first time it runs is after merge.
- **Order dependence.** A fuller run changes ordering or parallelism, and a test that leaks state into another surfaces. Confirmable in a minute by running with randomised order locally.

**What I do first regardless of cause.** Establish whether the default branch is broken for everyone, because that blocks the whole team and outranks diagnosis. If it is, revert the merge rather than fixing forward — a revert is fast, reversible and does not require understanding the problem yet. Fixing forward under pressure with everyone blocked is how a second defect arrives.

**Then the structural fix rather than the instance fix.** If it was a semantic merge conflict, require branches to be current with the default branch before merging, or use a merge queue that tests the merged result. If it was scope, make sure the selection logic is conservative — better to run too much than to have a class of change routinely untested. If it was environment, get an equivalent running on merge requests even if it is against a stub, so the shape of the failure is at least reachable earlier.

**And I would look at how often it happens.** An occasional default-branch failure is the normal cost of a subset strategy. A regular one means the subset selection is wrong, and the team has quietly stopped trusting merge request pipelines — which is worse than the time they save.

</details>

---

### Q77. The client wants traceability from requirement to test evidence for every release. What would you put in place?

**Project:** general

**Brief answer**
A link that lives in the code and moves with it — tests carrying the identifier of the requirement they cover, reported automatically from the pipeline — so the evidence is generated rather than maintained. A traceability matrix kept by hand is out of date within one sprint.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the requirement really is.** Someone must be able to ask, for a given release, which requirements are covered, by what, and whether it passed. That is a legitimate need on a regulated or heavily audited product, and it is a question a code suite alone answers badly — a test file does not know why it exists.

**How I would build it.**

- **The link lives in the test.** A marker or naming convention carrying the requirement identifier, so it moves with the code, appears in the diff, and disappears when the test is deleted. A mapping maintained in a separate document is a mapping that rots, and it rots invisibly.
- **Evidence is emitted by the pipeline, not entered by a person.** Each run produces a machine-readable report of which tests ran, which requirements they cover and what the outcome was, attached to the release artifact. Nobody transcribes anything, so nobody transcribes it wrongly or late.
- **A gap report as a build output.** Requirements with no linked test listed on every run. That is the actual value — not the matrix, which is a formality, but the list of things nobody has verified, which is a finding.
- **Manual test cases confined to what genuinely cannot be automated** — exploratory work, something needing a real external system, an accessibility judgement. Each is a recurring cost forever, so the list should be short and deliberately chosen rather than accumulated.
- **The release record assembled automatically**: which commit, which image digest, which requirements, which evidence. On a system where "what was running last Tuesday and what proved it" is a real question, that record is the answer.

**The failure mode I would work hardest to avoid.** Two catalogues drifting — a managed set of test cases and a code suite that no longer correspond. A manual case survives for a year after the behaviour it describes was removed, and each regression run someone marks it passed because investigating is harder. That produces a document asserting coverage that does not exist, which is worse than having no document at all.

**What I would ask early.** What happens when an automated test is deleted — because that is where the drift starts, and the answer is usually that nobody has thought about it. And who owns the requirement identifiers, since the whole scheme rests on them being stable.

**My honest position on the tooling.** I have kept traceability through tickets with explicit acceptance criteria, tests identifiably covering them, and release notes recording what was verified. A dedicated test-management tool sitting alongside the issue tracker is a workflow I have not used; the concepts are the same and I would expect the tool itself to take days rather than weeks.

</details>

---

### Q78. How do you decide what not to test?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By asking what the test would catch that something else does not, and what it costs to maintain. I do not test the framework, the language, or code whose failure is loud and immediate — and I am deliberate about it rather than just leaving gaps.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I actively choose not to test.**

- **The framework and the libraries.** A test asserting that the validation library rejects a wrong type is testing someone else's suite. The exception is where I depend on a behaviour that is version-specific or contested — a broker's semantics under a particular acknowledgement configuration, whether an instrumentation version really propagates trace context. Those get a test precisely because they are claims I would otherwise be assuming.
- **Anything a type checker already proves.** A test that a function rejects a string where an integer is expected duplicates the checker and costs maintenance on every refactor.
- **Trivial accessors and pass-throughs.** They contribute coverage and no information, and a suite full of them is what a coverage target produces when it is chased rather than used.
- **Failures that are loud, immediate and unmissable.** A missing configuration value that stops the process at startup does not need a test — it cannot ship unnoticed. Contrast that with a permission check that silently permits, which needs one badly.
- **Exact wording of user-facing strings**, unless the wording is itself a requirement. Otherwise every copy change is a red build and people learn to update assertions without reading them.
- **Third-party integrations at their own boundary.** I test that we call correctly and handle each documented response; I do not test their service. That belongs in a monitored synthetic check, not in a pipeline.

**How I decide the marginal case.** Two questions. If this broke, would anything else notice — a type error, a failing integration test, a loud crash, a metric? And what does the test cost when the code changes for an unrelated reason? A test that catches nothing new and breaks on every refactor has negative value, and removing one is a legitimate act rather than a retreat.

**Where I spend the effort saved.** On the tests that are hard: integration against real stores, the negative authorization cases, redelivery and crash-recovery, the plan shape on a query whose performance is a design property. Those cost more to write and each is worth ten trivial unit tests, and they also happen to move coverage.

**The thing I insist on when I skip something.** Say so. An uncovered path that was considered and deliberately left is a decision; one that was never noticed is a gap. So it goes in the merge request description, or in an explicit coverage exclusion with a reason — visible and reviewable — rather than being papered over with a test that asserts nothing, which is camouflage rather than coverage.

</details>

---

## Containerization and the Local Stack

---

### Q79. What is in your Dockerfile that a default one is not?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A multi-stage build so the runtime carries no build toolchain, a non-root user with no assumption about its identifier, dependencies installed from a lockfile in a separately cached layer, and a base image pinned by digest rather than by tag.

<details>
<summary><strong>Detailed answer</strong></summary>

**Multi-stage.** A build stage with the compiler toolchain and the package manager, and a runtime stage containing the interpreter, the installed dependencies and the application. This roughly halves the image and removes a large share of vulnerability findings, because most of them are in build tooling that has no business being in production.

**Layer ordering for the cache.** Dependency manifests copied and installed before the application source, so a code change does not invalidate the dependency layer. On a service with a substantial dependency tree that is the difference between a fifteen-second rebuild and a three-minute one, and it compounds over a day.

**Installed from a committed lockfile**, with the package manager configured not to create a virtual environment inside the container — the container is the isolation. Same tree everywhere.

**A non-root user, written so the identifier does not matter.** This is the part people get wrong. Setting a specific user is not enough on a platform that assigns an arbitrary high-numbered identifier at runtime, which OpenShift does by default. Directories the application writes to are group-writable and owned by the root group, so an arbitrary user can still write. An image assuming a fixed user works everywhere except the platform with the strictest policy, and that is discovered at the worst time.

**Base image pinned by digest**, not by a tag. A tag is mutable; a digest is the image. Combined with deploying by digest, that means what was tested is what runs.

**Other things that earn their place.** A `.dockerignore` that excludes the version control directory, local environment files and test artifacts — both for size and because a stray environment file in an image is a leaked secret. A signal-forwarding entrypoint so the process receives the termination signal and graceful shutdown actually runs, rather than the shell swallowing it. No secrets as build arguments, since build arguments persist in the image history.

**And a scan as a blocking gate**, with base images rebuilt on a schedule rather than only when the application changes — otherwise a service not deployed for two months is running two months of unpatched advisories and nothing reports it.

</details>

---

### Q80. What does your Compose stack contain, and how close is it to production?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
The real components at the same pinned versions as production — database, document store, search, cache and broker — because the integration stage in the pipeline runs against that same stack. It is not a convenience; it is what makes the tests mean something.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it and why it is the real thing.** On the health platform: the relational database, the document store, the search cluster, the cache and the broker. On the marketplace: the relational database, the document store and the cache, with the cache appearing twice in different roles. Same major versions as production, pinned, and the pipeline's integration stage brings up the same definition.

The reason is specific rather than aesthetic. The two things a mocked test passes while broken are the projection pipeline and the query plans — and a mocked broker cannot fail the way a real one does. Redelivery, acknowledgement semantics, the memory watermark blocking publishers, an unroutable publish still being confirmed: none of those exist in a fake. So the components that carry the guarantees are real everywhere.

**Where it is honestly not like production.** Single nodes rather than clusters, so replication, failover, quorum behaviour and network partitions are not exercised at all. No gateway, no managed identity, no service bus — those are stubbed or bypassed locally. Volumes are small, so nothing about plans at scale is represented. Resource limits are absent, so nothing about throttling or memory pressure appears.

I would rather state those gaps than let the local stack imply coverage it does not have. The consequence is that anything depending on cluster behaviour needs a real environment to verify, and that includes some of the most important properties in the design — which is exactly why a restore and a failover get rehearsed rather than assumed.

**What makes it usable day to day.** Healthchecks with dependency ordering, so the application waits for the database to be ready rather than crash-looping. Seed data from the same factories the tests use, so a developer's local data exercises the awkward cases. Named volumes so a restart does not lose state, and a documented one-line reset that does.

**The property I care most about.** A developer runs the same stack the pipeline runs. When something fails in the pipeline and passes locally, the difference is not the dependencies, which removes the most frustrating category of debugging there is.

</details>

---

### Q81. A container works locally and fails in the cluster. Where do you look?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
In order: configuration and secrets, identity and permissions, the filesystem and user identifier, network policy, and resource limits. Almost every instance is one of those five, and they are distinguishable in a couple of minutes each.

<details>
<summary><strong>Detailed answer</strong></summary>

**Configuration.** A value present in a local environment file and absent from the cluster's configuration. The failure is usually at startup and the log says so, if the application validates its configuration on boot — which it should, loudly, rather than failing later with something unrelated. Failing fast on a missing configuration value is one of the cheapest robustness measures there is.

**Identity and permissions.** Locally the application uses a connection string; in the cluster it authenticates as a federated workload identity. If the service account is not annotated correctly, or the role assignment is missing, it cannot reach the database or the storage account. The symptom is an authorization error from the cloud provider that reads like a network problem. This is the most common cause in my experience once configuration is ruled out.

**Filesystem and user.** Locally the container often runs as root. In the cluster it does not, and on a stricter platform it runs as an arbitrary assigned identifier. Anything writing to a path owned by a specific user, or expecting a writable filesystem where the root filesystem is read-only, fails here. Temporary directories need to be explicit mounts.

**Network.** Network policy denying egress, a private endpoint the pod cannot resolve, a name that resolves differently inside the cluster. Testing from a debug container in the same namespace with the same service account separates "the application is wrong" from "the network is wrong" in about a minute.

**Resources.** Terminated for memory, or throttled so severely that startup exceeds the probe threshold and it restart-loops. Locally there are no limits, so the first time the process meets one is in the cluster.

**How I actually work through it.** Read the previous container's termination reason first, because it partitions the space immediately. Then read the whole startup log rather than the last line — the real error is usually several lines above the symptom. Then run the same image in the cluster with a shell as the entrypoint, so I can inspect the environment as the process sees it. What the pod's environment actually contains is usually where the answer is, and it is different from what the manifest appears to say more often than you would expect.

</details>

---

### Q82. How do you pin things — base images, packages, and the tool versions in CI?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Everything pinned to an immutable identifier: base images by digest, packages by a committed lockfile, tools by exact version, and pipeline images by digest too. The rule is that a build with unchanged inputs produces the same result, and any moving reference breaks that.

<details>
<summary><strong>Detailed answer</strong></summary>

**Base images by digest.** A tag is a pointer that can be repointed; a digest is content. Pinning by tag means the same source can produce a different image tomorrow, which makes a failure impossible to attribute and makes "the tested image" a fiction. The cost is a scheduled job that bumps the digest and opens a merge request, which is a small automation and turns an implicit update into a reviewed one.

**Packages by lockfile**, committed, with the transitive tree resolved exactly. Constraints in the manifest, exact versions in the lock. That is what makes the pipeline, the developer machine and the production image identical.

**Pipeline tooling.** The linter, type checker, formatter and scanners pinned to exact versions, and the container images the pipeline itself runs in pinned by digest. An unpinned linter that updates overnight fails the build for everyone on code nobody touched, which is both disruptive and confusing because nothing in the repository changed. Tool versions are part of the environment.

**Deployment by digest.** The manifest references the image digest, not a tag. A mutable tag cannot then be swapped underneath a running cluster, and a rollback names a specific artifact rather than a label whose meaning may have moved.

**Where pinning has a real cost, stated.** It converts automatic security updates into deliberate ones, so you now own the update cadence. That is the right trade — I would rather choose when to take a change than have it arrive during an incident — but it only works if the cadence is actually maintained. Pinning without an update process is how a service ends up two years behind, and that is a worse outcome than not pinning.

**So the pinning and the update automation are one decision.** Scheduled proposals for base image digests and package updates, small batches, a suite good enough that green is evidence. Pinning is what makes updates safe to automate; automation is what makes pinning sustainable. Doing either alone fails, in opposite directions.

</details>

---

### Q83. How do you debug inside a running container in production, and what would you not do?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By exhausting telemetry first, then attaching a debug container to inspect rather than to change. What I would not do is edit anything inside a running container, install tools into it, or restart it before capturing what I need — a restart destroys the evidence.

<details>
<summary><strong>Detailed answer</strong></summary>

**Almost always, telemetry answers it.** Traces show where the time goes, structured logs filtered by the correlation identifier show the path a specific request took, and metrics show whether it is one pod or all of them. If those cannot answer the question, that is itself a finding — it means the instrumentation has a gap, and the gap is worth fixing more than this instance is worth debugging by hand.

**When I do need to be inside.** An ephemeral debug container attached to the pod's namespaces, carrying the tools, so the application image stays minimal — and so I am not installing anything into a running production container, which changes the thing being investigated and leaves it in a state nobody can reproduce.

**What I look at.** The environment as the process actually sees it, network reachability to its dependencies from inside the pod, whether the filesystem is what the manifest claims, and process-level state — thread stacks if the interpreter supports dumping them, which is the fastest way to find a whole worker pool parked on the same lock.

**Before anything else: capture.** Logs from the current and previous instance, the pod description including the termination reason, a heap or thread dump if relevant, and the current metrics. A restart is often the correct remediation and it destroys everything, so the order is capture, then remediate. The number of times an incident has been resolved by a restart and then recurred a week later with no evidence from the first occurrence is why I hold that order.

**What I would not do.**

- **Edit code or configuration inside a running container.** The change vanishes on restart, it is invisible to everyone, and the running system no longer matches what is declared.
- **Restart before capturing**, unless the outage cost genuinely outweighs the evidence.
- **Exec into a container to read data**, on the clinical system. Access to patient data goes through the audited path, not through a shell, and going around it is a control failure regardless of intent.
- **Leave a debug container attached** or a temporarily relaxed policy in place. Both get forgotten.
- **Attach a debugger that pauses the process** on something serving traffic.

**And afterwards.** Whatever I had to go inside to learn becomes a metric or a log field, so the next occurrence is answerable from telemetry. Debugging by hand in production is a signal about the observability, not a routine to get better at.

</details>

---

## Observability and Production Diagnosis

---

### Q84. Describe your experience with Prometheus. What did you instrument, and what do your queries look like?

**Project:** cancer-support-platform

**Brief answer**
Application metrics exposed on a scrape endpoint and alert rules held in infrastructure code. What I instrumented was chosen so each metric names a specific failure rather than a general notion of health — index freshness, reminder lateness, consumer duration and failures, queue depth.

<details>
<summary><strong>Detailed answer</strong></summary>

**The metrics that earn their place, and what each is for.**

- **The age of the oldest unpublished outbox row.** This is index freshness expressed as a number: a stalled relay means search results silently stop updating while every request stays fast. Alerted above thirty seconds.
- **Reminder dispatch lateness at the high percentile, and delivery outcomes by state.** Reminder delivery is the clinical objective, so its lateness is a first-class metric rather than something inferred from logs.
- **Consumer task duration and failure counts per queue**, plus broker queue depth and unacknowledged counts. Queue depth doubles as the autoscaling signal, so the same number drives both scaling and paging, which keeps the two from disagreeing.
- **Authentication failures by reason, and identity provisioning failures.** A deprovisioning that did not land is a security event, not a background job, so it pages.
- **The standard request rate, error rate and duration histograms**, which are necessary and are not where the interesting failures are.

**What the queries look like in practice.** Rates over counters rather than raw counters — a counter's value is meaningless, its rate is the signal. Ratios computed from two counters for error rates rather than a pre-computed percentage, so the numerator and denominator can be inspected separately. Histogram quantiles for latency, with the caveat that quantiles from histograms are estimates bounded by bucket boundaries, so the buckets have to be chosen around the thresholds that matter rather than left at a default. And alerts written with a duration condition so a single scrape does not page anyone.

**On cardinality**, which is the mistake that hurts. A label carrying a user identifier, a request path with an identifier in it, or an unbounded error string will multiply the series count until the server degrades. Labels are bounded sets — service, queue, outcome, status class — and anything unbounded belongs in a log line, not a label. This is easy to get wrong and expensive to undo.

**Alert rules in infrastructure code.** The detail I would emphasise, because it is the one people skip. An alert silenced by hand during an incident and never restored is the standard way monitoring rots. In code, a silenced alert is a reviewable diff rather than something discovered six months later when the thing it watched failed quietly.

</details>

---

### Q85. What does an application performance monitoring tool give you that metrics and logs do not?

**Project:** cancer-support-platform

**Brief answer**
The causal path of one request across every hop. Metrics tell you something is slow in aggregate and logs tell you what happened at points; a trace tells you where the time went in this specific request, including the hops through a broker that logs and metrics show as two unrelated halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each of the three actually answers.** Metrics answer "is it happening and how much" — cheap, aggregate, no per-request detail. Logs answer "what happened here" — detailed, per-event, and disconnected across services unless correlated. Traces answer "where did the time go for this request, across everything it touched", which neither of the others can reconstruct.

**Where it earns its cost on these systems.** A request touches the gateway, the service, the database, the cache and possibly the broker. A trace with spans for each shows immediately whether the time is in query execution, in waiting for a connection from the pool, in an outbound call, or in the application itself. That distinction — waiting versus working — is the one that decides the whole diagnosis, and it is invisible in a latency metric.

**The asynchronous case is where it becomes essential rather than convenient.** A check-in arrives over the message transport, is bridged into the broker, consumed by a worker, written, and indexed. Without trace context propagating across those hops it is four unrelated log streams. With it, one trace covers the request, the event, the consumer and the index write — so when a reminder fails between the worker and the delivery function, it is one picture rather than two half-stories assembled during an incident.

**The honest caveat, which I would state before relying on it.** Trace continuity across a message broker is the claim most likely to be false as written, because it depends on the instrumentation versions actually injecting and extracting the context header on that transport. And on the older version of the lightweight publish-subscribe protocol there is no user-property header at all, so the context has to travel inside the payload envelope — a decision that must be made before instrumenting, because retrofitting it breaks every published client. So the versions are pinned and an end-to-end trace identifier is asserted in an integration test. That is a claim you do not want to discover is false during an incident.

**On sampling.** Deliberately uneven: everything for errors and for the paths carrying the important guarantees, a small percentage of routine reads. Uniform sampling at a low rate means the interesting request is the one you did not keep.

**And what it does not replace.** Audit. A trace is telemetry with a retention policy and sampling; an audit record is a durable row written in the same transaction as the access. Conflating them means the telemetry retention policy silently becomes the audit policy.

</details>

---

### Q86. You are paged: latency is up and the error rate is flat. Walk me through it.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A flat error rate with rising latency means the system is still working and something is queueing. So the question is what everything is waiting for — a shared dependency, a saturated pool, or a cache that has stopped absorbing load — rather than what is broken.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start by bounding it.** Is it everything or one endpoint? All pods or one? When did it start, and what changed near then — a deploy, a configuration change, a scheduled job, a traffic pattern? The deploy timeline is the first thing I look at because it is the cheapest to rule out and the most common cause.

**Then split waiting from working, using traces.** The spans say whether the added time is in query execution, in acquiring a connection, in an outbound call, or in the application. That one distinction eliminates most of the space.

**The usual causes for this specific signature.**

- **A shared downstream saturated.** The database at its connection limit, or the cache slow. Everything that touches it slows together and nothing fails, because requests are queueing rather than being rejected. The tell is that unrelated endpoints degrade in step.
- **Connection pool exhaustion.** Time spent waiting to acquire, not executing — which is precisely why the database can look idle while the application is slow. Instrumenting pool wait as its own metric is what makes this a five-second diagnosis instead of an hour.
- **A cache hit ratio drop.** More requests falling through to the database, so latency rises and the database load multiplies. Causes: an eviction storm because memory filled, a key format changed by a deploy so every read misses, or an invalidation that removed more than intended.
- **A derived store falling behind**, which shows as latency on the paths that fall back to the primary.
- **Processor throttling from a limit set too low**, which looks exactly like slow code and is invisible unless the throttling metric is on the dashboard.
- **A blocking call introduced into an asynchronous path**, degrading everything on that worker together including the health probe.
- **A query plan change** after a data volume threshold or a statistics refresh. Slow suddenly, on one endpoint, with no deploy.

**What I do while diagnosing.** If it is degrading toward an outage, mitigate first — scale the affected tier, shed non-essential load, or roll back a recent deploy — and diagnose after, with the evidence captured before anything is restarted. If it is stable and merely worse, take the time to find the cause, because mitigating a latency problem without understanding it usually just moves it.

**And I check the obvious thing last but I do check it:** whether the latency is real or the measurement changed. A new endpoint with a different profile entering the same aggregate will move a percentile without anything having got slower.

</details>

---

### Q87. Where is the line between a log, a metric, an audit record and a trace — and what goes wrong when it blurs?

**Project:** cancer-support-platform

**Brief answer**
Different durability, retention and access requirements, which is the whole point. The failure that matters most is treating logs as an audit trail: the log retention policy then silently becomes the audit policy, and nobody notices until someone asks for a record older than the window.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each one is for.**

- **A metric** is an aggregate number for alerting and trend. Cheap, bounded, no per-request detail. Its constraint is cardinality: a label carrying a user identifier or an unbounded error string multiplies the series count until the monitoring system degrades. Anything unbounded belongs in a log line, not a label.
- **A log** is a structured event describing what happened at a point. Sampled or dropped under pressure in some pipelines, retained for weeks, queryable by anyone with access to the log store.
- **A trace** is the causal path of one request across every hop, deliberately sampled — everything for errors and the paths carrying the important guarantees, a small percentage of routine reads.
- **An audit record** is a durable, immutable business fact about who accessed or changed what. It is written in the same transaction as the access it records, so it cannot be lost independently of the thing it describes.

**Why conflating audit and logs is the serious one.** They look similar — both are append-only records of events — so it is a natural economy to say the logs are the audit trail. Then: log retention is weeks and audit retention is years, so the record is gone when it is needed. Logs are sampled or dropped under load, so the trail has holes exactly when the system was under stress. Logs go to a store with broad read access, so an audit trail of sensitive access is readable by everyone who can query logs. And a log line is written after the fact rather than transactionally, so a crash between the action and the log leaves an unrecorded access.

That is why audit is a database table here, with its own retention, its own access control and an archive under a write-once policy with a long legal hold — and why the audit write is in the same transaction as the access, which is a deliberate coupling rather than an oversight.

**The other blurs, more briefly.** Metrics used as logs produces a cardinality explosion that takes the monitoring system down. Logs used as metrics means alerting depends on the log pipeline, which may be the thing that is failing. Traces used as audit fails because they are sampled — the request you need is the one that was not kept.

**And the content rule that cuts across all of them.** No clinical free text, no symptom values, no message bodies in telemetry of any kind. Enforced mechanically rather than culturally: a redaction filter at the formatter dropping fields marked sensitive on the model, and a pipeline check failing the build if a log call passes such a model. Intention does not survive contact with an incident at two in the morning, which is exactly when someone adds a debug line containing the object.

</details>

---

### Q88. Your team is getting too many alerts. How do you fix that without going blind?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
By auditing every alert against one test — did a human need to act, and did they — then deleting or demoting the ones that fail it. Alert fatigue is not solved by tuning thresholds; it is solved by having far fewer things that page, each of which is trusted.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it has to be fixed rather than tolerated.** An on-call rotation receiving twenty pages a night learns to acknowledge without reading. At that point the alerting system has negative value: it costs sleep and it provides no detection, and the one real incident arrives in a stream of noise that has already trained everyone to dismiss it. Muting is what happens next, and a muted alert is worse than an absent one because everyone still believes it is there.

**The audit.** For every alert that fired in the last month: did it require a human to act immediately, and did a human act? Four outcomes.

- **Fired and needed action** — keep, and check the runbook is accurate.
- **Fired and nobody acted, and nothing bad happened** — it should not page. Demote to a dashboard or a ticket.
- **Fired repeatedly for the same underlying cause** — a symptom of over-alerting on causes. Replace several cause-alerts with one symptom-alert on the objective, and let the dashboard explain why.
- **Never fired** — either the condition never occurred, or the rule is broken. A rule with a typo in a label matches nothing forever, so this needs checking rather than assuming.

**The structural changes that usually follow.**

- **Alert on symptoms, not causes.** One alert on the user-facing objective, with the causes as dashboard panels. Alerting on every possible cause guarantees a storm during an incident, which is precisely when clarity matters most.
- **Duration conditions**, so a single scrape does not page.
- **Thresholds derived from the objective** rather than from a round number someone liked.
- **Grouping and inhibition**, so a downstream failure does not page for every dependent service.
- **Every paging alert names an owner and a runbook.** An alert with neither will be muted, deservedly.
- **A message stating what is wrong and what it means**, not a metric expression. The reader is half asleep.

**What I would protect from the cull.** The alerts for silent failures, even though they fire rarely — index freshness, projection lag, dead-letter depth, identity provisioning failures. Those are precisely the ones nothing else surfaces, and their rarity is an argument for keeping them rather than against.

**And the rules go in infrastructure code**, so a threshold change or a silence is a reviewed diff rather than a click. That is what stops the set decaying again six months later, which is otherwise exactly what happens.

</details>

---

## Enterprise Resource Planning and Retail Domain

---

### Q89. How much of your marketplace work would transfer to a retail or enterprise resource planning catalogue, and what would not?

**Project:** banking-software-marketplace

**Brief answer**
The data modelling transfers well — a per-category attribute set, a schemaless metadata store with a validated write path, and a maintained projection for search. What does not transfer is the operational scale of continuous attribute churn, and the entire transactional side of retail, which I have not built.

<details>
<summary><strong>Detailed answer</strong></summary>

**What genuinely transfers.**

- **Modelling a catalogue whose attribute set differs per category.** Attributes are data, not columns, so the contract has to come from a per-category schema document validated on write. That is the same problem an enterprise catalogue has, and the failure mode is identical: without the validated write path, "no fixed column set" becomes "no contract" within a quarter.
- **Separating the descriptive from the filterable.** Anything filtered gets a defined type and an index in a projection; anything purely descriptive stays in the document. That separation is what keeps search on indexes rather than scanning documents.
- **Immutable revisions with a current pointer.** A comparison or a shortlist must show what a vendor said at a version, not a record that changes underneath it. In a retail catalogue the equivalent is price and specification history, which is usually a hard requirement rather than a nicety.
- **The consistency machinery.** One owning store per fact, an outbox so a fact and its event cannot disagree, source revisions on events so redelivery is a no-op and out-of-order delivery cannot roll a listing backwards, and a reconciliation sweep as the backstop for a lost event.
- **Bulk import as a first-class path**, chunked onto its own queue with a per-supplier concurrency cap so one supplier cannot occupy the pool.

**What does not transfer, stated plainly.**

- **Scale of churn.** The marketplace handled hundreds of imports a day. A large retail or resource-planning catalogue has continuous attribute updates at a rate where the update path, not the read path, is the design centre. I have designed for a burst; I have not operated a continuous multi-million-update feed, and I would expect the topology itself to change at that volume.
- **The transactional side of retail entirely.** Stock movements, promotions and pricing engines, order and fulfilment flows, tax and fiscal receipt rules, integration with point-of-sale networks. None of that is work I have done. My platform was where retailers choose software, not the software that runs a store.
- **Resource planning as a domain.** I have not worked inside one of those products, so its module structure, its customisation model and the constraints that come with a decades-old data model are things I would be learning.

**How I would frame that in a conversation.** The shapes I would meet are ones I have built — catalogue modelling, bulk updates, projection maintenance, search over faceted data. The domain vocabulary and the transactional processes are ones I would need to learn, and I would rather say that than discover it in the third week.

</details>

---

### Q90. Retail is seasonal. What does a peak window change about how you plan and operate a release?

**Project:** banking-software-marketplace

**Brief answer**
It turns a peak into a change freeze with a deliberate boundary, moves risky work well before it, and makes capacity a decision taken in advance rather than by an autoscaler during the event. Most of what changes is planning discipline rather than architecture.

<details>
<summary><strong>Detailed answer</strong></summary>

**The freeze, and what it should actually cover.** A blanket ban on all changes is the wrong shape — it prevents fixes as well as features, and it produces a large batch of accumulated change landing immediately afterwards, which is its own risk. What I would freeze is the class of change that is hard to reverse: schema migrations, infrastructure changes, anything altering a hot query plan, and dependency or runtime upgrades. Behaviour behind a flag and genuine fixes stay possible, because the alternative is being unable to respond during the period when responding matters most.

**What moves before the window.**

- **Migrations and backfills**, finished and verified with time to spare, so nothing large is in flight when traffic arrives.
- **Capacity decisions taken in advance.** Autoscaling reacts, which is fine for a spike and inadequate for a sustained peak with a hard downstream limit — the connection budget does not scale with the autoscaler. So the ceilings are raised deliberately and the database sizing is decided ahead, not during.
- **A load test at peak shape rather than at average volume.** The interesting failures are all at the peak, and testing at the mean finds none of them. Shape matters as much as volume: a concentrated two-hour burst behaves nothing like the same daily total spread evenly.
- **A cold-start rehearsal.** If capacity has quietly been sized on a warm cache, then a restart during the peak is an outage. Knowing what happens with an empty cache — and having sized for it — is a different statement from hoping it does not happen.

**What changes operationally during it.** Higher alerting sensitivity on the things that degrade before they fail — queue depth trends, connection pool waits, cache hit ratio, projection lag. A named person who can decide to roll back without assembling a meeting. And a rehearsed rollback, because the window is exactly when nobody wants to attempt one for the first time.

**Afterwards.** The peak is the best data anyone will get all year, so the numbers get recorded and become next year's sizing input rather than being forgotten. And the changes deferred by the freeze land in a planned sequence rather than as one large batch — the post-freeze release is where the accumulated risk actually sits, and treating it as a return to normal is how a freeze causes the incident it was meant to prevent.

**The honest scope of my experience here.** The marketplace had no strong seasonality — its load was steady business-to-business traffic. The discipline above is what I would apply, drawn from the burst work I did do (the morning check-in concentration on the health platform, and bulk imports on the marketplace) rather than from having run a retail peak.

</details>
