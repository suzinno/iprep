# Architecture and Distributed Systems

> 19 questions on service boundaries and distributed data, saga and compensation, choreography versus orchestration, read models and event sourcing, consistency models, resilience patterns, and scaling, load balancing and availability. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except ARCH-01, ARCH-02, ARCH-04, ARCH-06, ARCH-07, ARCH-08 and ARCH-14, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — ARCH-01, ARCH-02, ARCH-03, ARCH-05, ARCH-07, ARCH-08, ARCH-10, ARCH-11, ARCH-13, ARCH-14, ARCH-15, ARCH-18, ARCH-19
- **retail-software-marketplace** — ARCH-01, ARCH-02, ARCH-03, ARCH-04, ARCH-06, ARCH-08, ARCH-10, ARCH-11, ARCH-12, ARCH-13, ARCH-14, ARCH-15, ARCH-16, ARCH-18, ARCH-19
- **general** — ARCH-09, ARCH-17

---

## 1. Service boundaries and distributed data

---

### ARCH-01. Choreography or orchestration — how do you choose, and what does each cost you when you have to debug it at three in the morning?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Choose choreography when the reactions are genuinely independent and adding a consumer should not touch the publisher. In choreography, services react to published facts, and there is no coordinator. Choose orchestration when the sequence itself is the business logic, when order or compensation must be coordinated, or when someone needs to ask "where did this get to". In orchestration, one component knows the whole sequence. The debugging costs are opposite. Choreography has no single place that describes the flow. Orchestration has a coupling point that every change goes through.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction I actually use** is not about technology. It is about where the knowledge of the sequence lives. In choreography, no component knows the flow. Each component knows only what it reacts to, and the flow emerges from the bindings. In orchestration, one component holds the sequence explicitly and tells the others what to do.

The cancer platform states the boundary as a rule, instead of deciding case by case. I think that is the right way to handle it. The rule is: **[Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") models work we schedule and retry for ourselves. A topic exchange models facts we publish for others.** If you merge the two, every consumer becomes a Celery task, and independent services become coupled to one task registry. So reminder sweeps, page generation and index projection are orchestrated work, with owners, deadlines and retry policies. `checkin.recorded` and `visitnote.created` are facts, published to whoever cares. The same boundary exists in the marketplace. Celery moves work between Python processes we own. Service Bus moves events across a boundary. The notification split follows the Celery and Service Bus boundary exactly. The worker decides *whether and what* to notify, because that is a policy decision that needs database context. The Function performs the *delivery*. Each step has one owner, and nothing overlaps.

**Choose choreography when:** the consumers are independent of each other, and adding one should not require touching or redeploying the publisher. Two more conditions must also hold: the publisher genuinely should not know who reacts, and no consumer's failure changes what another consumer should do. In the cancer platform, the concrete benefit concerns the publisher of a visit note. That publisher is the module that owns the clinical record, which is the highest-risk deployable in the system. A new downstream feature must never require redeploying it.

**Choose orchestration when:** the order of steps is part of the business rule, or a step's outcome decides whether a later step happens. Also choose it when compensation has to be coordinated across steps, or when you need to query the state of an in-flight operation. The same applies when the flow has a timeout as a whole rather than per step. Anything shaped like the saga in the previous question should have an orchestrator. The reason is that "which step are we on" has to be a row that somebody can select.

**Debugging choreography.** There is no file you can open that describes the flow. To answer "what happens when a listing is published", you have to read the bindings, the subscriptions and the consumers. The topology *is* the program. The specific failure mode is the one nobody sees: a binding that matches nothing. The broker accepts the publish, returns a confirm, and discards the message. So the defences have to be structural, not diagnostic. These are the defences. An alternate exchange turns unroutable publishes into visible backlog. An event catalogue is maintained as a real artefact, and it lists every event with its emitter and its consumers. The binding topology is declared in code and asserted in integration tests, instead of being checked by eye in a management interface. And trace context is propagated through message headers, so one trace spans publish, then project, then invalidate, then notify. Without that last one, a failure between a worker and a Function becomes two unconnected partial stories.

**Debugging orchestration.** This is much easier. The sequence is in one place, the state is a row, and "where did this get to" is a query. What you pay is coupling. The orchestrator knows every participant, so every new step is a change to the orchestrator. It becomes a deployment bottleneck. It also becomes a single component whose failure stalls every flow it drives. Over time, it also tends to become the place where all the business logic collects. At that point, the services around it are anaemic, and you have a distributed monolith with extra network hops.

**The anti-pattern worth naming** is choreography where the services are not actually independent. Every consumer must be deployed together with the others, because the event shapes are coupled and a change to one spreads through all of them. That is a distributed monolith that only looks event-driven. You have paid every cost of asynchrony and kept every cost of coupling. There are two signs to check. Can you add a consumer without coordinating a release? And can you change an event's shape additively? If the answer to either is no, the choreography exists only in name.

**What I would do in practice**, and what I have done: choreograph the fan-out of facts, and orchestrate anything transaction-shaped. Keep the rule written down once, so nobody argues about it again for each feature. And instrument both the same way. The reason is that the observability requirement is identical, and observability is the only thing that makes either one debuggable at three in the morning.

</details>


---

### ARCH-02. When is a separate read model worth building, and when is it over-engineering?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
A separate read model is worth it when the reads want a genuinely different shape from the writes. Examples are a union across five tables, faceted filtering with full text, or a capability that the write store does not have. It is also worth it when read and write volumes differ by orders of magnitude. It is over-engineering when the read shape is just the write shape with a join. It is also over-engineering when both models still hit the same tables anyway. And it is over-engineering when a team adopts the pattern for its name rather than against a measured problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**Both systems have one, and neither calls it Command Query Responsibility Segregation (CQRS)**. I think that is the healthy way round. In the marketplace, `product_listing_facets` is a denormalised table. Only the indexer writes to it, and only the catalogue service reads it. It copies vendor, status and publication time from the product table *deliberately*, so the hot query touches exactly one relation and never joins. In the cancer platform, `es-clinical` is the same idea in a different store. It is a search index fed from the outbox. It holds no data of its own, and it can be fully rebuilt from source.

**What justified them, in concrete terms.**

- **The read shape differs from the write shape.** Take faceted search over free text, plus array containment, plus a category-specific attribute. You cannot serve that query well from a normalised authoring model. The same is true for a chronological timeline that is a union across appointments, prescriptions, visit notes, documents and check-ins.
- **The write store cannot do it at all.** A relational full-text index does not give you scoring, highlighting and analyzer-driven relevance at 2.4 million notes with per-clause filtering. That second store was bought to meet a measured latency target, not because of a preference. And the design says so.
- **The volumes are asymmetric.** Reads make up almost all of the catalogue's traffic. By comparison, the authoring surface gets very little traffic. If you optimise one side under the other side's constraints, the wrong side pays.
- **Write-path isolation.** The indexer maintains the search vector, not a database trigger. That keeps text-search maintenance out of the vendor's publish transaction. The write path should not pay for a value that only the read path needs.

**What you pay, every time.**

- Eventual consistency. So you need a stated lag budget with an alert, because a dead projection is silent. Listings simply stop becoming searchable, and nothing raises an error.
- A projection to operate, and a reconciliation job to repair it.
- A second place to get authorization wrong. Every document in the clinical index carries scope fields, and every query filters on them. The reason is that a search engine that can return a document the record layer would refuse *is* the disclosure path.
- The read-your-writes problem for whoever just wrote. Both designs route around it, instead of shrinking the lag. The vendor workspace reads the primary and the document store directly, and never the projection and never the cache. So vendors get read-your-writes, while retailers get the fast, slightly stale read model. People forget that routing decision, and it is usually cheaper than chasing the lag down.

**When it is over-engineering.** If the read query is the write model plus a join and an index, add the index. If the "read model" lives in the same database and is filled synchronously in the same transaction, you have paid the denormalisation cost and bought none of the isolation. It is also over-engineering when it is really a cache with a projection pipeline added on top. That has more moving parts than a cache with a sensible key. It is over-engineering when the team cannot yet operate the lag monitoring and reconciliation that the pattern requires, because an unmonitored projection silently produces corrupt data. And it is over-engineering when the argument for it is that the architecture should be CQRS, and not that a specific query is too slow or too awkward for a specific reason.

The test I would apply has three parts. Name the query. Name why the write model cannot serve it. And name the number it has to hit. If all three exist, build the read model. If the answer is "it seems cleaner", do not build it.

**One distinction is worth stating clearly, because people routinely bundle the two:** separating the read and write models has nothing to do with event sourcing. You can have either one without the other. When a team confuses them, it ends up adopting two large patterns when it needed part of one.

> **Footnotes:**
> - **CQRS (Command Query Responsibility Segregation):** It separates the model used to change state from the model used to read it. So each model can be shaped and scaled for its own job. It says nothing about how the write model stores its data. In particular, it does not imply event sourcing.

</details>


---

### ARCH-03. What's the difference between strong consistency and eventual consistency? What business trade-off exists here?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Under strong consistency, a successful write is visible to every later read. Under eventual consistency, reads may see an older value for a bounded period. The business trade-off is not abstract. It is whether you can recover from a stale answer. A listing that takes five seconds to appear in search costs nothing. A lost prescription write or a double-counted charge cannot be undone. So those paths pay for consistency with availability.

<details>
<summary><strong>Detailed answer</strong></summary>

**The definitions, stated more precisely.** Strong consistency means that reads are ordered after the writes that completed before them. That is what a single primary gives you by default. Eventual consistency means that replicas converge if no new writes arrive. There is no promise about when, unless you make one. "Read-your-writes" is a weaker guarantee, and it is often enough: *you* see your own write immediately, but other people may not.

**The decision is per path, not per system, and that is the main point.** Both designs are explicitly mixed:

- The marketplace is **consistent and partition-tolerant for connections, billing and identity**. It is **available and partition-tolerant for catalog reads**. A connection request, a charge or a token must never be lost or double-counted. A listing edit that is invisible for a few seconds costs nothing.
- The cancer platform is consistent for the clinical record. Under a partition, it returns `503` rather than serve a prescription that may be stale. It is available for diary ingest. There, a check-in is durable on the broker and acknowledged before it reaches the record. The reason is that losing a patient's symptom entry to a partition is worse than showing it a few seconds late.

Both designs state the boundary in the requirements document, instead of discovering it endpoint by endpoint. In the cancer platform, the boundary between the two positions is literally a queue.

**What eventual consistency actually costs. This is the part that separates a real answer from a definition.** It is never free, and it is never just "a bit stale":

- **A bounded lag, so you need a budget and an alert.** The marketplace budgets projection freshness at p95 under 5 s and p99 under 30 s. It measures freshness as `indexer_lag_seconds`, with an alert at 60 s. The cancer platform builds its search budget from its parts, instead of just stating it. A 2 s outbox relay, plus a 5 s bulk flush, plus a 5 s refresh interval, gives p95 under 15 s. The cancer platform also notes that tightening any one of the three alone cannot bring the total below the sum of the other two. "Eventually consistent" without a number and a metric means "eventually, possibly".
- **A reconciliation job.** Without one, the loss of a single event is permanent. Both designs have a nightly reconciliation. The marketplace re-projects anything whose projection timestamp is older than its update timestamp by more than five minutes. The cancer platform compares document counts per patient between the database and the search index, and it reindexes the patients that differ.
- **Read-your-writes routing for the author.** The vendor who just clicked publish is the one person for whom the lag is obvious. So the vendor workspace reads the primary and the document store directly, and never the projection or the cache. The design does not shrink the lag. It routes around the lag for the one party who notices it.
- **A second authorization surface.** Every store that can answer a query is a path around your access control. That is why every document in the clinical search index carries mandatory scope fields.

**How I would frame the trade-off for a business stakeholder.** I would not frame it as consistency versus availability. I would frame it as: *what does a wrong answer cost, and can we undo it?* A stale search result costs a refresh. A double charge costs a refund, a support conversation and some trust. A missing clinical record entry during a consultation is a safety incident. Once you ask the question that way, the answer is usually obvious. And it is almost always different for different paths in the same product. That is exactly why one consistency choice for the whole system is the wrong kind of decision.

</details>


---

### ARCH-04. Six services and three worker pools share a lot of code. How do you avoid building a distributed monolith?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Share the boring things, and duplicate the domain. A shared library for logging, tracing, authentication middleware and typed configuration is fine. A shared domain model or a shared database access layer couples releases. That is how independent services stop being independent.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I apply: does sharing this force a coordinated release?** If updating the library means every service must redeploy together, the services are one deployable with extra network hops. You get all the operational cost of a distributed system and none of the independence.

**What is safe to share.**

- **Cross-cutting infrastructure.** This means structured logging setup, trace propagation, the authentication middleware and token validation, health probes, and typed configuration loading. These change rarely, and they are not domain logic. A version lag between services is harmless.
- **Client stubs generated from a service's published contract**, versioned with that contract. They are generated, not written by hand, so the contract stays the source of truth.
- **Test utilities and factories.**

**What is not safe to share.**

- **Domain models.** A shared entity means two services agree on a shape. Then a change for one service is a change for both. Each service should own its own representation of a concept, even where the representations overlap. The duplication is the price of independence, and it is usually a good trade.
- **A shared data access layer over a shared database.** This is the strongest form of coupling there is. And it is the one that always arrives by accident. Each service owns its tables. When another service asks for that data, it gets an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") or an event, not a query.
- **A shared library containing business rules.** The rule then lives nowhere in particular. And changing it means a coordinated release of everything.

**What enforces it mechanically.** Import rules in the linter, which declare the layer graph and fail the build on a back edge. They are needed because nothing in Python prevents a domain module from importing the database session. Without that check, the architecture decays into a folder naming convention within about two sprints. Separate schemas per owning service, with permissions that enforce them, so a cross-service query fails instead of working. And proper versioning of the shared library, with services able to lag behind, so an upgrade happens per service and not as a fleet operation.

**The signal that it has gone wrong** is a change that requires touching four repositories, or a deploy order that matters. Either of those means the boundaries are in the wrong place. The honest response is one of two things: fix the boundary, or admit that these services should be one deployable. For a system at this traffic level, one deployable would be a defensible answer, not a defeat.

</details>


---

### ARCH-05. In your recent work on the Cancer Support Platform, you transitioned from a FastAPI modular monolith to extracted microservices for SCIM and NLP; what specific technical criteria did you use to define the service boundaries, and how did you handle data consistency between these services using RabbitMQ?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Only two things moved out, and each one moved out for a reason that holds up under close examination. `scim-provisioning-svc` moved out because its release cadence belongs to the hospital directory, not to us. `clinical-nlp-svc` moved out because it needs GPU hardware and ships on a model's schedule. Everything else stayed in `care-core`, because at roughly 200 queries per second a distributed transaction across `diary` and `records` adds latency and on-call load for no throughput. Consistency is not two-phase commit. It is a transactional outbox that publishes domain facts to the `care.events` topic exchange, with idempotent consumers and a natural key in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") underneath.

<details>
<summary><strong>Detailed answer</strong></summary>

**The criteria, in the order I applied them.**

1. **Does it have an independent release driver?** The question is not "is it a different noun". The question is whether something outside our team forces it to ship on its own schedule. System for Cross-domain Identity Management ([SCIM](https://scim.cloud/ "Standardizes automated provisioning and deprovisioning of user identities between systems")) provisioning has such a driver. The hospital's Azure Entra ID tenant changes its attribute mappings and its Groups behaviour on the directory team's schedule. A directory change should not be blocked behind a patient-portal release, and a patient-portal release should not be blocked behind a directory change. The Natural Language Processing ([NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Computational techniques for analyzing and generating human language")) service has one too. A model version is a release. It needs a canary rollout with a quality comparison, and that makes no sense for a Create-Read-Update-Delete service.
2. **Does it need different hardware or a different runtime shape?** `clinical-nlp-svc` needs a GPU node pool. The alternative was to put a GPU `MachineSet` into the regulated primary cluster to serve one workload. The split is the most expensive decision in the design. That is why the design also records the condition that reverses it. If inference moves to a managed endpoint, `aks-ml` is merged back, and nothing stateful lives there to make that hard.
3. **Can it own its data, or would it have to share tables?** People skip this criterion, and it is the one that decides whether the extraction is real. `scim-provisioning-svc` writes only the `identity` schema: `clinician`, `care_team_member`, and the `care_relationship` rows that a deprovisioning closes. It never touches `records`, `diary` or `content`. So the extraction is **deployment-level, not data-level**. It releases independently, but it cannot evolve those tables without taking `care-core` into account. I would say that plainly in an interview, rather than claim a cleaner boundary than the one that exists. The honest framing is that schema ownership is the constraint that keeps the extraction from decaying.
4. **What did the split cost, and is the cost proportional?** Two deployables became four. There is also a cross-cluster hop that needs mutual Transport Layer Security (mTLS), and so a certificate authority that we would not otherwise run. At 200 queries per second, only the two drivers above justify that cost, and nothing else cleared the bar.

**The counter-example matters as much as the examples.** `records` is a separate module from `clinical-content`, because a prescription and a leaflet do not belong behind the same code path. But `records` is not a separate service, because its consistency obligations are the same as those of `diary`, and the two modules share transactions. A module boundary that the pipeline enforces — import contracts over the code, and a test that fails a module running [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") against a schema it does not own — gives you most of the isolation. And it does that without the extra cost of a distributed system. Extraction is a deployment decision, not a modelling one.

**Consistency across the boundary.** There is no distributed transaction anywhere, and there should not be one.

- **Publish through an outbox.** A state change and its `outbox_event` row commit together. The relay publishes to the `care.events` topic exchange afterwards. Delivery is at-least-once, never zero times.
- **Publish facts, not commands.** `checkin.recorded`, `visitnote.created`, `carerelationship.changed`. With a topic exchange, the publisher does not know who reacts. So adding the third consumer does not require redeploying the module that owns the clinical record.
- **Make a redelivery just a repeated calculation.** Every consumer is idempotent against a natural key in `pg-clinical`. It is not idempotent against an application-side "have I seen this" set, which can itself be lost. [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency keys exist, but they are explicitly the optimisation, not the guarantee.
- **Make the messages durable.** Use quorum queues across the three-node `rmq-core` cluster, with mandatory publisher confirms. Without confirms, `publish()` returns when the frame reaches the socket, and that says nothing about replication. With confirms, a confirmed publish has been accepted by a majority.
- **Keep the state machine in the database, not in the queue.** Reminders stay `pending` in PostgreSQL and are swept again. So a broker or Function outage makes them late, not lost. This property is what lets me say "eventually consistent" without it meaning "eventually, possibly".

There is one place where I would push back on the premise. The direction was never "monolith → microservices" as a programme. Two services moved out, for two named reasons. And the design records what would bring one of them back.

</details>


---

### ARCH-06. A business operation spans three services and cannot be one transaction. How do you make it eventually correct, and what happens when a compensating step itself fails?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
The answer is a saga. A saga is a sequence of local transactions. Each one commits independently, and each one has a compensating action that semantically undoes it. Compensation is not rollback: you do not delete the charge, you write a credit. When a compensating step fails, it must be retried indefinitely and idempotently. The reason is that a compensation cannot itself have a compensation without starting an endless chain. And where the effect genuinely cannot be undone automatically, the honest design escalates to a human instead of pretending.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape in front of me.** Opening a connection request in the marketplace is exactly this. The connection is created. A billing charge accrues on the vendor's account. The shortlist item changes to `contacted` in the retailer's private working set. And the vendor is notified. That is four effects, across three services plus a Function, with no shared transaction. Each effect is driven by `connection.requested`. That event is published through the outbox, so the first step's commit and the intent to do the rest are atomic.

**Making it eventually correct.**

- **Each step is a local transaction that commits on its own.** No step waits for a later one.
- **Each step is idempotent**, because delivery is at-least-once. Here, the schema carries that. The request has `UNIQUE (retail_group_id, idempotency_key)`. The charge has a partial unique index on `(connection_request_id)` `WHERE kind = 'connection'`. That index makes "a connection bills at most once" a property of the database, not a property of everyone remembering to check.
- **The saga's state lives in a table, not in memory.** The table records which step has completed, what it returned, and what remains. That is what lets you resume the saga after a crash and query it during an incident. It is also the difference between a saga and a sequence of event handlers that only hope everything works.
- **Compensation is semantic, not syntactic.** You cannot roll back a committed transaction in another service. Instead, you write an opposing fact: a credit against a charge, a `withdrawn` status against a request, or a correction notice against a sent notification. For anything financial, that is not a workaround. It is the requirement, because an accounting record you can delete is not an accounting record.

**Ordering the steps is the design decision that matters most.** Classify every step as compensatable, pivot, or retriable. Compensatable steps can be undone. The pivot is the point of no return. Everything after the pivot must be retriable until it succeeds, because there is no way back. Then order the operation so that the irreversible step happens as late as possible. Sending the vendor an email is effectively a pivot, because you cannot unsend it. So it goes after the charge and the status change, not before. If you get that ordering wrong, you end up in the situation where the only option left is an apology.

**When a compensating step fails.** This question separates people who have read about sagas from people who have run one.

1. **Compensations must be retriable forever, and idempotent.** A compensation cannot have its own compensation without an endless chain of compensations (infinite regress). So the only correct response to its failure is to try again. Use exponential backoff with jitter, with no retry budget cap, and no giving up.
2. **After bounded attempts, it goes to a dead-letter queue with a page, not a ticket.** A stuck compensation means that the system is in an inconsistent state. The system knows about that state and cannot fix it. That is exactly the kind of thing a human must see.
3. **The saga state row records where it stopped**, so a human or a replay continues from the failed step, instead of re-running the whole thing.
4. **Some effects genuinely cannot be compensated automatically.** Examples are a notification that was already delivered, or a file that the counterparty already downloaded. The compensation for those is a task for a person, such as a correction message or a support contact. The design should name that task explicitly, instead of leaving an impossible retry loop in the code. Writing "compensate: send correction email to vendor contact" is a better design than writing a handler that will never succeed.
5. **Guard against the compensation racing the forward step.** If a compensation arrives before the step it undoes has been observed, that must be safe. Again, that means the compensation is idempotent, keyed, and driven by the state machine, not blind.

**Sagas have no isolation, and you have to plan for that.** Other readers see intermediate states. For example, the charge exists while the connection is still being set up. The countermeasures are semantic locks (a `pending` status that readers understand), commutative updates, and re-reading a value before acting on it. The marketplace openly accepts one of these intermediate states. A category manager may briefly see a shortlist item still marked `candidate` while a connection is already open. The reason is that the update is async and idempotent, and the authoritative signal in the interface is the connection list itself. The correct treatment is to name the anomaly and decide that it is acceptable. The failure is not noticing that it exists.

**And the thing I would say before any of this.** A saga is what you use when you cannot have a transaction. It is strictly worse than a transaction, and the first question is whether the boundary is real. In the cancer platform, SCIM deprovisioning closes every open care relationship for a departing clinician **in the same transaction**. The reason is that access ending when employment ends is a security property, and it must not be eventually consistent. That was affordable only because identity writes stayed in one database. And that is a large part of why the extraction there was deployment-level rather than data-level. If an operation has an invariant that cannot tolerate an intermediate state, the right answer is usually to move the boundary, not to write a saga across it.

</details>


---

### ARCH-07. Would you event-source either of these systems? Argue it either way.

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
No. The interesting part is that the cancer platform looks like it wants to be event-sourced, and it still should not be. It already has an immutable seven-year audit table, temporal validity ranges and immutable versioned content. Together, these deliver most of the auditability that people turn to event sourcing for, at a fraction of the cost. I would use the ingredients without adopting the pattern. And I would keep event sourcing for a domain where the sequence of changes genuinely *is* the product.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it is, stated so that the trade-off is visible.** Current state is not stored. It is derived by folding an append-only log of events. Nothing is ever updated or deleted. Reads run against projections built from that log, and rebuilding a projection means replaying history.

**The case *for*, in the cancer platform specifically, because on the surface it is genuinely strong.** Every read and write of patient data already writes an immutable audit row, retained for seven years. Clinician access is modelled as a temporal range with a start and an end, not as a flag that gets overwritten. So history is not lost. Education pages are immutable versions. What a patient was shown is pinned to an exact version, so a later revision never silently changes the record of what advice they were given. Regulators ask "who saw what, when, and what did it say at the time". In that kind of domain, history is a first-class obligation, and event sourcing answers all of it natively.

**The case *against*, which is the one I would make.**

- **Much smaller machinery already meets the obligation.** Take an append-only audit table. Update and delete on it are revoked from every application role, and it also has a blocking trigger. It is partitioned monthly and archived to immutable storage. That table satisfies the regulator. Event sourcing would deliver the same property, and it would also restructure every read in the system.
- **Every query becomes a projection.** A clinician who opens a timeline during a consultation needs it in under 250 milliseconds. "Fold five years of events" does not meet that. So you build projections. That means you have taken on the lag, the rebuild and the reconciliation cost of a read model for *every* entity, not just for the two that needed it.
- **Constraints get much weaker.** The strongest correctness tools here are relational. A unique key on patient and date makes a redelivered check-in just a repeated calculation, not a bug. There is an exclusion constraint on the temporal care relationship. And a partial unique index makes "a connection bills at most once" a property of the schema. In an event-sourced model, those invariants move into application code and aggregate boundaries. There, they are enforced by everyone remembering.
- **Schema evolution becomes permanent.** You can never delete an old event shape. Code written in year five must still correctly replay an event written in year one. That means upcasters, version tolerance, and a growing body of compatibility code that can never be removed. That is a very different maintenance profile from a migration that you apply once and then forget.
- **Erasure conflicts directly with immutability.** Against an append-only log, the right to erasure has one real answer: crypto-shredding, which means encrypting per subject and destroying the key. That is a key-management project with its own failure modes, not a checkbox. The platform already has a genuine conflict between retention and erasure, and it resolves that conflict deliberately. Adding an immutable event log makes the resolvable part unresolvable too.
- **Operational and cognitive cost.** Event sourcing changes how everyone reasons about the system. And this client values thoroughness over speed, and its leads review closely. A pattern that the whole team must learn before anyone can review a change honestly is a large bet.

**What I would take from it instead, and what both designs already do.** Append-only where the record must be immutable. Temporal validity ranges instead of overwriting a flag. Immutable versioned artefacts, pinned by identity and version. An outbox, so integration events are a durable record and not a side effect. That is event sourcing's *hygiene*, applied where it pays, without making every read a fold.

**Where I would say yes.** In a domain where the log is the product rather than an audit of it. Examples are a ledger, or a trading or settlement system. I would also say yes anywhere you must reconstruct exactly why a decision was made, from the state as it was at that instant. And I would say yes where regulators require replay rather than records. Even then, I would want a team that has operated projections before. The reason is that the pattern's failure mode is a rebuild that you cannot complete inside a maintenance window.

**The meta-point I would make in the room.** Being able to argue *against* a pattern you understand is worth more than being able to list its benefits. Both of these systems refuse things deliberately. There is no sharding at 200 queries per second, and no service mesh at nine workloads. One of them explicitly declined row-level security, because through a connection pool it is only as safe as the transaction discipline of every read path. A plain session setting leaks between pooled sessions, and a transaction-scoped setting issued outside a transaction has no effect, so the policy silently becomes a no-op. Each refusal is recorded with the condition that would reverse it. Event sourcing belongs on that list, not on the roadmap.

</details>

---

## 2. Resilience

---

### ARCH-08. A downstream dependency starts degrading. Walk me through timeouts, retries, circuit breakers and bulkheads — and how each one can make the situation worse.

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Timeouts come first, because without a bound nothing else works. An unbounded call holds resources without any limit. And the budget has to shrink as you go down the call chain. Retries turn a struggling dependency into a dead one if they have no jitter, have no budget, or are applied to non-idempotent calls. Circuit breakers make calls to a healthy dependency fail when the threshold is wrong, or when the breaker is shared across tenants. Bulkheads are the one that rarely backfires, and they are the one people implement last.

<details>
<summary><strong>Detailed answer</strong></summary>

**Timeouts, and they genuinely come first.** A call with no timeout holds a thread, a connection and a slot in whatever pool it came from, for an unlimited time. Under load, that is how one slow dependency uses up an entire service. People miss two details:

- **The budget must decrease down the chain.** Suppose the client waits 5 s, the gateway waits 5 s and the service waits 5 s. Then an inner retry outlives the outer deadline, and it does work that nobody is waiting for. Each hop should get the remaining budget minus a margin, and that budget should be propagated explicitly.
- **Connect and read timeouts are different settings**, and if you set only one, the other stays unbounded.

The marketplace has exactly one synchronous call that crosses a service boundary, and it has a 250 ms timeout. That is not a tuning value. It is a design constraint. Because the design keeps to one sync hop with a hard bound, a degrading peer cannot cause a cascade.

**Retries, and how they make it worse.** A retry multiplies load, and it aims that load at something that is already struggling. Three attempts at three layers is twenty-seven calls for one request. The dependency that was at 90% capacity is now at 300%. The failure modes are these:

- **No jitter.** Everyone backs off by the same amount and retries at the same time, so all the retries keep arriving together, forever. Exponential backoff *with jitter* is not an optimisation. It is the mechanism.
- **No budget.** A retry budget caps retries at a fraction of total traffic, for example 10%. So a broad outage can add at most about 10% more load. Without a budget, retry volume grows with the failure rate, and that is exactly backwards.
- **Retrying the wrong things.** Retry only idempotent operations, and only on retryable error classes. Retrying a `400` or a `422` can never succeed. Retrying a non-idempotent `POST` without an idempotency key is how a double charge happens. That is why the key is mandatory on mutating requests here. It is also why the guarantee behind the key lives in a unique constraint, not in a cache.
- **Retrying something that already succeeded.** A timeout does not mean that the work did not happen. That uncertainty is the whole reason the idempotency machinery exists.

**Circuit breakers.** A breaker tracks failures against a dependency. Above a threshold, it stops calling the dependency and fails fast. After a cooldown, it lets one probe through, and it closes if the probe succeeds. What it buys you is this: a dead dependency stops consuming your resources, and it stops adding load to its own recovery. How it makes things worse:

- **A threshold tuned too tight** trips on a short blip and cuts off a dependency that was fine. That turns a slow request into a total outage for that path.
- **Shared breaker state across tenants or endpoints.** If one tenant sends requests that legitimately fail, the circuit opens for everyone. Breakers should be scoped to what actually shares a failure mode.
- **Unlimited half-open probes.** If you let a burst through on recovery, the burst kills the dependency again immediately. Send one probe, then decide.
- **No fallback behind it.** A breaker without a defined fallback just turns a slow error into a fast one. That is better, but not much better.
- **Invisible state.** A breaker that nobody monitors is a silent outage: everything is fast, and everything is wrong. Its state belongs on a dashboard as a first-class metric.

**Fallbacks, and the decision that goes with them.** Each fallback needs an explicit fail-open or fail-closed choice, with a reason. The marketplace's single sync hop fails *open*. On timeout, it permits the connection instead of blocking it. The reason is that refusing a legitimate connection request costs the marketplace more than an occasional duplicate thread. And a unique constraint catches the duplicate anyway. The safety net is in the schema, and that is what makes failing open defensible rather than reckless. In the same system, business rate limiting fails **closed for writes and open for reads** when the cache is unavailable. Those are two different answers, and each one comes from what the control is protecting.

**Bulkheads, which are the underrated one.** Separate the resource pools, so that one dependency's slowness cannot consume everything. In these systems, the concrete bulkheads are these. Import workers run on their own deployment and their own queue, so a bulk load cannot starve indexing or notifications. A per-vendor concurrency semaphore means that one tenant cannot occupy even that pool. And there is the recommendation to keep a high-churn bulk pipeline off the broker that serves the latency-sensitive path, because otherwise a bulk backlog blocks interactive publishing. Separate connection pools per dependency belong in the same category. Bulkheads rarely backfire. Their cost is under-utilisation, because a partitioned pool cannot lend capacity. That is usually a price worth paying for a blast radius you can predict.

**The strongest version of the answer is architectural, not at library level.** The cancer platform's design states that no synchronous user path depends on `clinical-nlp-svc` at all. Requests queue on `celery.content`. So if the GPU cluster is unavailable, new page generation pauses, and not a single user-facing request is affected. A dependency that you do not call synchronously needs no breaker.

**The failure I have seen most.** All four are added at once, none of them is measured, and the total timeout ends up longer than the client's timeout. So the client gives up and retries, while the server is still patiently working through its own retry schedule. This is the order in which I would actually apply them. Bound everything with a timeout. Make the operation idempotent. Add jittered and budgeted retries. Add a breaker with a fallback and a dashboard. And partition the pools. Then load-test with the dependency deliberately degraded: not down, but *slow*, which is the harder and more common case. The reason is that a mock cannot be slow in the way a real dependency is.

</details>


---

### ARCH-09. Why can retries actually make an outage worse?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Because a retry multiplies load at exactly the moment when capacity has dropped. Three retries per request is four times the traffic. And that traffic arrives at a system that has just shown it cannot serve one times the traffic. If several layers each retry, the multiplication compounds. Without jitter, the retries arrive all at the same time. The result is a system that stays down after the original cause is gone.

<details>
<summary><strong>Detailed answer</strong></summary>

**The arithmetic.** A client that retries three times turns 100 requests per second into 400 when things start failing. Now stack the layers, which is the case people underestimate. Take a browser or [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") retry, a gateway retry, an application-level retry and a database driver retry, each with three attempts. In the worst case, that is 3⁴. Every layer looked reasonable on its own. This is why a retry budget belongs at the top of the stack. It is also why retries at more than one layer of a call chain are an anti-pattern, not defence in depth.

**Synchronisation.** Fixed backoff, or even plain exponential backoff without jitter, makes every failed client wait the same interval and retry at the same instant. The recovering service receives a huge burst of traffic at once, goes down, and produces another synchronised wave. **Full jitter** means sleeping for a random duration between zero and the current backoff ceiling. It spreads the retries out, and it is the single cheapest fix in this whole area.

**Work nobody is waiting for.** When the caller has already timed out, the request still in flight is dead work. But it still uses a worker, a connection and a database transaction. During a retry storm, a large fraction of the work a system does is for clients that have gone. The defence is deadline propagation. Pass the remaining budget down. And let each hop refuse work whose deadline has already passed, instead of doing the work and throwing away the result.

**Queue and pool poisoning.** Retries fill bounded resources. The connection pool saturates, so healthy endpoints start queueing behind the failing one. A broker's queue depth climbs. On a broker under memory pressure, that raises a memory alarm, which blocks publishers. This is a separate failure, and it spreads back into the services that do the publishing. It has exactly the shape of "millions of updates overloaded the broker and took production with it".

**Metastable failure, which is the name worth knowing.** The system enters a state where the retry load on its own is enough to keep it failing. So removing the original trigger does not fix it. The database is now slow *because* of the retries, and the retries are happening *because* the database is slow. Recovery requires shedding load from the outside, by rate-limiting at the edge or by literally turning clients away. That is a very uncomfortable incident to run. It matters to recognise a metastable failure, because the intuitive response, "wait for it to recover", never ends.

**So what makes a retry safe:**

- **A retry budget**, not a retry count. Cap retries at a small percentage of successful traffic. Then, under a broad failure, retries fall toward zero automatically. This is the control that fails safe as the failure widens.
- **Exponential backoff with full jitter**, and a hard ceiling on attempts.
- **Retry only retryable errors**, and only on idempotent operations or on operations that carry an idempotency key.
- **Retry at one layer**, chosen deliberately, and disable retries at the other layers.
- **A circuit breaker underneath**, so a sustained failure stops generating attempts at all.
- **Deadline propagation**, so a retry is never attempted after the caller's deadline has passed.

**And the detail on the recovery side that people miss:** the moment the dependency comes back is the most dangerous one. Every breaker half-opens, every backoff expires, every pool refills, and the caches are cold. So the returning traffic is larger, and more expensive per request, than the steady state. The marketplace design sizes for exactly this. It notes that a Redis loss multiplies PostgreSQL load roughly sixfold, and it provisions to survive that. It also names bounded reconnection as the specific mitigation for the storm after a failover.

</details>


---

### ARCH-10. Design a service that communicates with another unreliable service.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The first design decision is whether the call needs to be synchronous at all. If the user does not need the answer to get their response, put a queue between them, and most of the problem disappears. Where the call must be synchronous, the stack is this: a propagated deadline, a bulkhead, a timeout inside that deadline, budgeted and jittered retries on idempotent calls only, a circuit breaker, and a named fallback. Add per-dependency observability too, because you cannot operate what you cannot see failing.

<details>
<summary><strong>Detailed answer</strong></summary>

**Decide the interaction shape first.** This decision matters more than all the library-level ones. The cancer platform's rule is that no synchronous user path depends on `clinical-nlp-svc`. Page generation is enqueued on `celery.content`. If the GPU cluster is unreachable, new page generation pauses, while already-approved pages are served normally. The marketplace draws the same line at the outbox. Publishing a listing must not fail because the notifier is down. So the state change commits with an `outbox_event`, and delivery happens afterwards. Both are the same move: they turn a dependency on availability into a dependency on eventual delivery. Where that is possible, it beats every resilience pattern. The reason is that the failure stops being visible to the user, instead of just being handled gracefully.

**Where it must be synchronous, these are the layers, outermost first.**

1. **A deadline, propagated.** The incoming request has a budget. Each hop subtracts what it has spent and passes on the rest. A call whose deadline has already expired is not attempted.
2. **A bulkhead.** This is a dedicated connection pool or a bounded semaphore per dependency. Without it, one slow dependency eventually holds every worker in the process, and every unrelated endpoint fails with it. This is the control that keeps the blast radius to the feature, not the service.
3. **A timeout strictly inside the deadline**, with connect and read timeouts kept separate. Then the retry decision can tell "nothing was sent" apart from "something may have been applied".
4. **Retries, budgeted and jittered, on idempotent operations only.** Outbound mutations carry an idempotency key, so the remote side can deduplicate. The key is what makes a retry on a `POST` legitimate at all.
5. **A circuit breaker** with half-open probing, so a sustained outage costs no threads. The breaker also gives the dependency room to recover.
6. **A fallback that is named in the design, not improvised during the incident.** You can serve the last known good value from cache. You can degrade the feature and say so in the response. You can queue the work for later. Or you can fail open. The marketplace explicitly picks fail-open on its one synchronous inter-service hop. If `retailer-service` does not answer within 250 ms, the connection request goes ahead. The reason is that refusing a legitimate connection costs the marketplace more than an occasional duplicate thread. And the `UNIQUE (retail_group_id, idempotency_key)` constraint catches the duplicate anyway. That is the right shape for a fallback: a stated trade-off with a compensating control, not a choice made without thinking.

**Make the boundary observable.** Keep per-dependency metrics for call rate, error rate by class, latency percentiles, timeout count, breaker state and bulkhead saturation. Breaker transitions should be events that you can see on a dashboard. The reason is that "the breaker opened at 14:02" greatly shortens an investigation that would otherwise take an hour. Trace context propagates across the call, so a failure is one trace and not two partial stories.

**Two more belong in a senior answer.** The first is **contract testing**, because an unreliable dependency is often unreliable in its shape as well as in its availability. A field that becomes nullable is an outage that you caused by trusting a document. The second is to **treat the dependency's service level objective as a ceiling on yours**. If it offers 99.5% and you call it synchronously on every request, you cannot promise 99.9%. The only ways to break that arithmetic are caching, a fallback, or moving the call off the request path. Saying that out loud during design is more valuable than any amount of retry tuning.

</details>

---

## 3. Scaling and system composition

---

### ARCH-11. Explain purpose of each component from system design perspective: caching, replicas, queues, workers, object storage, observability, horizontal scaling?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Each one removes a specific pressure and adds a specific cost. The cost is the part worth knowing. Caching trades freshness for latency. Replicas trade consistency for read capacity. Queues trade immediacy for durability. Workers trade simplicity for isolation. Object storage keeps bytes off the application tier. Observability is what makes silent failures visible. And horizontal scaling is what statelessness buys you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Caching buys latency and load reduction. It costs freshness and an invalidation rule.** The marketplace caches hydrated listings at `cat:listing:{product_id}:v{rev}` and search pages at `cat:search:{filter_hash}`. Its latency budget assumes an 85% hit ratio on the search page. The discipline that makes caching safe is that **every layer has a stated invalidation rule**. Also, the revision in the key means that a stale entry cannot be reached, even if the purge message is lost. The rule I would state is that nothing patient-identifiable is cached at a layer that cannot see the requester's identity. That is why gateway response caching is switched off by policy in the cancer platform, and not just left unused. A cache with no invalidation story is a correctness bug with a latency benefit.

**Read replicas buy read capacity and isolation for heavy reads. They cost you read-your-writes.** The marketplace serves catalog search from a replica. It routes every write, and every read that must be fresh, to the primary. The cancer platform makes the opposite choice, for a reason that is worth learning from. Every read of patient data writes an audit row. So an audited read is a write, and it **cannot be served by a replica at all**. Replicas there carry only unaudited work: index rebuilds, reporting and backup verification. That is the clearest example I know that a replica is not free read capacity. It is read capacity for queries whose consistency and write requirements permit it.

**Queues buy durability and decoupling. They cost immediacy and an operational surface.** Queues take work off the request path, so a slow or unavailable downstream cannot fail the user's request. They also absorb bursts that you would otherwise have to provision for. The check-in path is the purest case. The message is durable on the broker before the record write, so an unreliable mobile connection cannot lose a patient's symptom entry. The costs are real. Delivery is at-least-once, so consumers must be idempotent. The backlog needs a metric. And somebody has to read the dead-letter queue.

**Workers buy isolation of the blast radius, and independent scaling.** Separate deployments consume separate queues. So a 20,000-row import scales the importers on queue depth without touching the web tier, and it cannot starve the indexer. The codebase is the same, but the process and the failure domain are different. The cost is more deployments to observe, and a second place where code runs.

**Object storage keeps large bytes out of the application entirely.** Documents upload directly to blob storage with a short-lived signed token, instead of being proxied through the API. So multi-megabyte scans never touch the pods that serve a clinician's timeline. The database row holds metadata and a path. Object storage is also where immutability and lifecycle live. A write-once audit archive with a seven-year retention period is a storage feature, not an application feature.

**Observability is the only reason anyone knows the system is broken.** It has three planes, joined by one trace identifier: metrics for the shape, traces for the path, and logs for the detail. Its real purpose is the failures that nothing else brings to the surface. A dead indexer raises no error anywhere. Listings simply stop becoming searchable. So `indexer_lag_seconds`, with its alert at 60 s, is the *only* thing between that failure and a silent product outage. That is the argument for treating observability as a component, not as a nice extra.

**Horizontal scaling buys capacity and, more importantly, redundancy.** You add identical stateless replicas behind a load balancer. That is how you absorb load, survive the loss of an instance, and deploy without downtime. It works only if the instances hold no request-affine state, and that is what statelessness is for. The limit is that it scales the tier you replicate, and nothing else. The database, the broker and the caches stay shared. So beyond a point, adding pods just concentrates more pressure on the same primary.

**The connecting idea.** None of these is a default. Both of these designs refuse components against a measured number. For example, there is no search cluster for 40,000 listings, and **ARCH-17** covers the rest of them. Each component that the designs do take is justified against a figure, and the condition that would reverse it is written down. That reasoning is more useful in an interview than the component list.

</details>


---

### ARCH-12. Explain load balancing. Why would we put a load balancer in front of three API instances? What happens if one instance dies?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace

**Brief answer**
A load balancer spreads requests across instances. More importantly, it continuously decides which instances are eligible to receive them. Three instances are not mainly about capacity. They let you lose one, or deliberately take one out to deploy, without an outage. When one dies, the health check removes it. In-flight requests to it fail and must be retried. The remaining two absorb the traffic, and that only works if you left headroom for it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Two jobs, and the second is the important one.** Distribution is the obvious job. Health checking is the job that turns three servers into an available service. The balancer probes each instance and routes only to the ones that pass. So a failed instance stops receiving traffic within a probe interval, instead of continuing to serve errors.

**Why three instead of one bigger box.** At 35 queries per second, capacity is the least interesting reason. The real reasons are these. An instance can fail without the service failing. You can deploy by rolling instances out one at a time while the others serve. And with instances spread across availability zones, the loss of a zone is a capacity reduction, not an outage. In the marketplace, `catalog-service` also runs a second deployment that receives about 10% of traffic as a canary. The canary is held for fifteen minutes against its error rate and latency before the weight advances. That is only possible because the balancer can weight destinations.

**Algorithms, briefly, and when the default is wrong.** Round robin is fine when requests cost roughly the same. **Least outstanding requests** is better when they do not. That is the usual case for an API, where one route is a ~35 ms cached search and another is a 107 ms uncached search. Round robin will happily keep sending requests to an instance that is already stuck behind slow work. Consistent hashing matters when the backends hold per-key state, such as a cache tier. It is unnecessary for stateless application pods.

**What happens when one dies, step by step.**

1. **In-flight requests on that instance fail.** Nothing saves them. This is why clients and gateways retry idempotent requests. It is also why a `POST` needs an idempotency key before a retry is safe.
2. **The health probe fails and the instance is removed**, after the configured threshold. That delay is a deliberate trade-off. If the removal is too aggressive, a garbage-collection pause ejects a healthy instance. If it is too slow, clients see errors for longer.
3. **The remaining two carry the load.** If the three were running at 70% processor use, two cannot carry 105%. You now have a cascade, not a degradation. Headroom for `n-1` is the actual design requirement. It is the reason why autoscaling targets are set well below saturation.
4. **The orchestrator replaces the instance**, and the new instance starts cold. Its in-process caches are empty, and its connection pool is cold. So recovery takes longer than the restart.

**Two distinctions are worth drawing without being asked.** The first is **readiness versus liveness**. Readiness controls traffic, and liveness controls restarts. Mixing them up is a classic self-inflicted outage. A readiness probe that depends on the database will correctly stop traffic during a database blip. But a *liveness* probe that does the same will restart every pod in the fleet at the same time, at the worst moment. The second is **connection draining**. A pod that is being removed deliberately should stop accepting new connections, finish what it has, and then exit. That means a `preStop` hook and a grace period. Otherwise, every deploy is a small burst of errors.

**Sticky sessions.** They exist. But I would treat needing them as a signal to fix the application instead. Affinity defeats even distribution. It makes the loss of an instance a loss of user state. And it blocks rolling deploys. Move the session into Redis or into a signed token, and the problem disappears. That is exactly the next question.

</details>


---

### ARCH-13. What does it mean for a service to be stateless? If our API needs user sessions, does that mean the API cannot be stateless?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Stateless means that no request depends on state held in *that particular process* from a previous request. So any instance can serve any request, and losing an instance loses nothing. Sessions do not break statelessness, as long as the session lives somewhere shared. That can be Redis, under a session identifier, or a signed token that the client carries. The application is stateless. The state is simply not in the application.

<details>
<summary><strong>Detailed answer</strong></summary>

**The precise claim.** Statelessness does not mean "holds nothing in memory". Every service holds connection pools, compiled validators, and in-process caches of near-static data, such as the category tree and facet schemas. Those are legitimate, because nothing breaks if a request lands on a different pod. The new pod rebuilds them, and no *correctness* depends on which instance handled the previous request. The test is this: can I kill any instance at any moment and lose nothing except the requests currently in flight? If yes, the service is stateless in the sense that matters. Then horizontal scaling, rolling deploys and instance replacement all work.

**Sessions, two ways, both stateless in that sense.**

- **Server-side session in a shared store.** The cancer platform keeps `sess:{session_id}` in Redis with a 30-minute sliding expiry. The client holds only an opaque identifier, and any pod resolves it. Revocation is immediate: you delete the key. Immediate revocation is the main advantage.
- **Self-contained signed token.** The marketplace issues [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Tokens with a 15-minute lifetime. The tokens carry account type, organisation and scopes. They are verified locally against a key set cached in Redis. There is no lookup per request at all. That is exactly why authorization costs about 1 ms in the latency budget, and not the 15–30 ms that an introspection round-trip would add.

**The trade-off between them is revocation, and it is worth naming.** A signed token cannot be un-issued, so revocation is bounded by the token lifetime. The marketplace answers that in layers. There are short access tokens. There is refresh-token rotation with reuse detection, which revokes the whole chain immediately. And there is the case where fifteen minutes is still too long: a suspended vendor. For that case, there is an `identity.user.deactivated` event plus a small Redis denylist of revoked token identifiers. Notice what that denylist is. It is a deliberate, bounded return of shared state, to fix the one thing that stateless tokens are bad at. That is a better answer than pretending the trade-off does not exist.

**What genuinely is not stateless, and what to do about it.** Long-lived connections bind a client to one process for as long as the connection lasts. Here that means WebSockets, server-sent events, and the [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") check-in listener. So scaling and deploys have to account for reconnection. In-memory rate-limit counters would be per pod, and so they would be wrong. That is why the buckets live in Redis at `rl:{subject_id}:{bucket}`. A file written to local disk during an upload is invisible to the next request. That is why documents go directly to blob storage. And the scheduler is an honest singleton: one replica that holds a distributed lock. The reason is that "exactly one process does the sweep" is inherently stateful. This is mitigated by keeping the due rows in the database, so a scheduler failure delays work instead of losing it.

**So the direct answer:** needing sessions does not make an API stateful. Needing sessions *in the process's own memory* does. So move the sessions out of that memory, and do not drop the requirement.

</details>


---

### ARCH-14. How do you choose between a managed cloud service and running the component yourself in the cluster?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Managed by default. Self-hosted when a specific requirement forces it: a feature the managed version lacks, a data-residency or tenancy constraint, or a cost profile that does not work. And the decision is written down with the condition that would reverse it, because it is expensive to revisit casually.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why managed is the default.** What you are buying is not the software. It is the operations: patching, backups, failover, upgrade paths, and someone else being on call for the storage layer. For a relational database, that is a very good trade. A managed instance with point-in-time restore and zone redundancy is better than what most teams will operate themselves. And the restore actually works.

**What pushed components into the cluster on the cancer platform.** The broker, the document store and the search cluster all run in the cluster, not as managed services. The honest reasons differ per component. The managed alternative for the broker has no MQTT ingress for the check-in path. The managed document store prices poorly for large document reads, and the brief specifies [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"). The design gives no reason for running the search cluster in the cluster.

**And the honest cost of that choice.** You own version upgrades, replica membership, shard and replica counts, persistent volume sizing, and the restore procedure. That is real operational work, similar to on-premises operations. The discipline it forces is to treat a rebuild as routine. The search index can be rebuilt from the primary stores, and that rebuild is rehearsed quarterly with a count reconciliation. The reason is that a mitigation nobody has executed is an assumption.

**The questions I actually ask.**

- Does the managed version support what we need, at the version we need? Feature gaps are the usual reason to rule a service out, and they are specific, not general.
- Is this stateful? Stateful components in a cluster are where the operational cost concentrates. So the bar is much higher for a database than for a stateless service.
- Who is on call for it at three in the morning, and do they have a rehearsed restore?
- What does it cost at our actual volume, including the operational time, not just the instance price?
- Is there an exit? A managed service with a proprietary interface is a different commitment from one that speaks a standard protocol.

**What I would resist.** Self-hosting because it is cheaper on paper. The instance cost is the visible part, and the smaller part. The invisible part is the upgrade that nobody scheduled and the restore that nobody tested. Equally, I would resist adopting a managed service whose behaviour under failure nobody has tested. Managed does not mean that it fails in the way you assumed.

</details>


---

### ARCH-15. Traffic goes up tenfold and stays there. Walk me through what breaks first, in what order, and which of those you can fix with configuration rather than code.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Connection limits break first, because they are a hard ceiling, not a gradual slope. The database connection limit and the pod thread pool saturate before the processor does. Then comes the single-writer database. Then any queue whose consumers do not scale with its producers. Then anything with a per-instance singleton. Configuration gets you through the first round: pool sizes, replica counts, autoscaler bounds, prefetch and cache TTLs. The things that need code are the ones with an architectural cause: an N+1, a synchronous audit write, or a scheduler singleton.

<details>
<summary><strong>Detailed answer</strong></summary>

**In order, with the reason for each position.**

1. **Connection pools, in the application and in the database.** This comes first because it is a cliff, not a slope. The pods scale out, each pod opens its pool, and the sum crosses the server's connection limit. New connections are refused, and the failure is total, not gradual. The marketplace sizes the sum of every pod's pool maximum to stay under the server limit. That means horizontal scaling has a ceiling, and the ceiling arrives without warning if nobody recomputed it. The configuration fix is smaller per-pod pools plus a connection proxy, such as PgBouncer in transaction mode. The trap is that transaction-mode pooling **breaks anything relying on session state**. In the cancer platform, the row-level security context is set per transaction with `SET LOCAL`. That is done specifically because a plain session-scoped `SET` would leak one caller's identity into the next caller's query through a reused backend. So "add a pooler" is a configuration change with a correctness precondition. I would check that precondition before making the change.
2. **The database primary.** Reads can go to replicas, but writes cannot. In the marketplace, catalogue reads already come from a replica. So the read side scales by adding replicas, and that is configuration. In the cancer platform, patient-facing reads cannot do that. Every protected-health-information read writes an audit row in the same transaction, and a replica cannot write. So patient-facing reads are served by the primary. Ten times the traffic on that path is ten times the write load, and no amount of replica provisioning helps. That is a code-and-design change. The options are batching audit writes, or accepting an audit trail with a hole in it. For a health record, a hole in the audit trail is the worse outcome. The fact that audited reads can only go to the primary is worth naming. It is the least obvious consequence of a security control.
3. **The thread pool and worker count.** For synchronous handlers, the `anyio` pool is a fixed ceiling, shared across every `def` route and dependency. Requests queue before they start, while the event loop looks idle. The configuration settings are pool size, worker processes per pod, replica count and autoscaler maximum. People forget the autoscaler maximum. A Horizontal Pod Autoscaler capped at 8 does not care that you need 30.
4. **Queues and their consumers.** Producers scale with request traffic automatically. Consumers scale only if something scales them. The marketplace autoscales worker pools on queue depth through a custom metric. That is the configuration answer. But it is bounded by the cluster autoscaler's node range, and in the end by the database that the consumers write to. An unbounded backlog then becomes the broker memory problem, where a shortage of consumers shows up as a producer outage.
5. **Cache and its stampede behaviour.** A tenfold traffic increase on a cache-aside layer multiplies the concurrency that hits each expiry. Without single-flight and probabilistic early expiry, every [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") boundary becomes a synchronised thundering herd at the database. Both of those are code. Both are already present in the marketplace design, precisely because the traffic pattern makes the herd inevitable.
6. **Singletons.** The Celery beat scheduler is one replica by design. It holds a distributed lock, so a restart cannot schedule the same work twice. It does not break under load in the same way. But it does not scale either, and the sweep still has to fit in its window. That is a design review, not a setting.
7. **The edge.** In both designs, the gateway and front door are a genuine single point of failure for north-south traffic, and that is accepted deliberately. At ten times the load, tier and quota configuration matter, and they are configuration. But the rate limits themselves need to be derived again, because limits calibrated for the old volume will now reject legitimate traffic.

**Configuration versus code, in summary.** Configuration covers pool sizes at every layer, replica and worker counts, autoscaler bounds, prefetch, cache TTLs, gateway tier, rate-limit thresholds, `work_mem` and autovacuum aggressiveness. Code and design cover N+1 queries that were tolerable at one times the load and are fatal at ten times. They also cover synchronous work on the request path, the audit-write coupling, and anything with a hidden singleton. And they cover query plans that flip when the table crosses a planner threshold. That is the failure that arrives without any deploy at all.

**The honest framing for these two systems specifically.** Both are sized against modest numbers: about 200 queries per second at peak in the cancer platform, and about 35 in the marketplace. Both explicitly refuse to buy sharding or a service mesh against numbers that do not require them. Ten times either figure is still well inside what a single well-tuned primary with replicas handles. So my answer is very clearly *not* "shard it". The documented evolution triggers say the same thing, in the right order, and **ARCH-17** sets them out. The append-only tables that nothing joins to and nothing reads on the request path come out first. Sharding is considered only a long way after that. Knowing the trigger *and* the order is more useful than knowing the techniques.

</details>


---

### ARCH-16. An enterprise client sends a bulk load that is orders of magnitude larger than normal traffic. How do you keep it from starving everyone else, and what do you do when shedding load is the only honest option left?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
Isolate it before it arrives. Use a separate queue and a separate worker deployment, so bulk work cannot consume the capacity that serves interactive requests. Add a per-tenant concurrency cap, so one client cannot occupy even that pool. When shedding is genuinely the only option left, shed deliberately and by class. Reject the bulk work with a retryable error and a clear signal, and protect the interactive path. And make sure the client can tell a "come back later" apart from a "this will never work".

<details>
<summary><strong>Detailed answer</strong></summary>

**The isolation, which is where nearly all the value is.**

1. **Bulk work is never a request.** A 20,000-row import is an upload to blob storage plus a job record, and it returns a job id immediately. The workspace polls a status endpoint that shows row totals, successes, failures and an error digest. Nothing about that occupies a web worker.
2. **A separate queue and a separate worker deployment.** `catalog-import-worker` runs on its own deployment, consumes its own queue, and autoscales on *that* queue's depth. It shares the codebase but not the request path. So a large import cannot exhaust web-tier capacity, and it cannot starve the indexing or notification queues either. A single shared worker pool is the failure that this prevents. It is also the most common way this goes wrong.
3. **A per-tenant concurrency cap.** At most four concurrent chunks per vendor, held as a Redis semaphore. Separate queues stop bulk work from starving interactive work. The cap stops *one* tenant's bulk work from starving the bulk work of every other tenant. Those are two different problems, and they need two different mechanisms. That is worth saying, because people implement the first mechanism and believe they have solved the second problem.
4. **Chunking.** The file becomes 500-row tasks. Each chunk is a short transaction. So a chunk does not hold locks, does not hold a snapshot open against vacuum, and can be resumed and observed on its own. Chunking also limits what a worker drain has to wait for. Chunks are sized to finish inside the termination grace period, so a deploy in the middle of an import does not kill work.
5. **Batched downstream effects.** This is the subtle one. A completed import emits *one* event, and the indexer re-projects the affected products in batches of 200. Without that, one import produces 20,000 events, 20,000 cache invalidations and 20,000 upserts. And the damage lands on the read path that everyone else is using, not on the import path. The blast radius of bulk work is usually downstream of the bulk work.
6. **Stage, then promote.** Rows land in staging and are validated against the category schema before any live row moves. A malformed file fails completely at validation, with a per-row digest. It is never half-applied. That matters for starvation too. Validation is cheap, and if you reject a bad file early, you avoid paying for the expensive path at all.
7. **Business rate limits, not just infrastructure ones.** Five import jobs per vendor per day, and 200 listing writes per vendor per hour. These are quotas expressed in domain terms, and they express something that a per-IP limit cannot. They are also the first thing to reach for when a client's "bulk load" is actually a misconfigured integration that is retrying.

**When shedding is the only honest option.** It happens. Capacity is finite, and the alternative to shedding is that everything fails, which is worse and less fair. The principles are these:

- **Shed by class, and decide the classes in advance.** The interactive read path is protected, and bulk ingestion is shed first. That ranking should exist in the design, and not be improvised during the incident.
- **Shed at the edge, cheaply.** A request rejected at the gateway costs nothing. A request rejected after it has taken a connection and a worker thread has already consumed the capacity that you were trying to protect.
- **Reject, do not drop.** Use `429` with `Retry-After`, or a queue policy of `reject-publish` instead of `drop-head`, so the producer knows and can back off. Silent dropping means the client retries harder, and the outcome is data loss that nobody can account for.
- **Distinguish retryable from terminal.** A client must be able to tell "the platform is busy, come back in ten minutes" apart from "this file is invalid and will never import". If you mix them up, you get either a permanent failure retried forever, or a temporary failure abandoned.
- **Preserve fairness while shedding.** If shedding is necessary, shed the heaviest tenant's excess first, instead of shedding uniformly. When one tenant causes the overload, uniform shedding punishes everyone for one client's behaviour.
- **Make it visible.** Shedding that is not on a dashboard cannot be told apart from a bug, and the support conversation that follows is much worse.

**And the commercial half, which is a real part of the answer.** When an enterprise client sends orders of magnitude more than normal, that is often a conversation rather than an engineering problem. The outcome can be a scheduled window, a negotiated quota, or a dedicated worker pool for that tenant. In a business where a large client's data volume *is* the product, the right answer is sometimes to provision for that client explicitly and bill for it, rather than to defend the platform against a customer who is using it as intended. I would want the quota conversation to happen before the incident. Having the per-tenant caps already in place is what makes that conversation possible. You can raise a named number for a named client, instead of rebuilding the mechanism under pressure.

</details>


---

### ARCH-17. Design a backend for an application with 10 million users. Start simple. What would you build, and where would you scale when traffic increases?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
First do the arithmetic, because ten million registered users is not a throughput figure. With ordinary engagement, it is a few thousand requests per second. Most of the architecture follows from that number, not from the headline. Start with one stateless API tier behind a load balancer, one relational primary with a replica, a cache, object storage for blobs, and a queue for anything slow. Then scale in the order in which things actually break: connections, then reads, then writes, then individual tables.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start with the estimate, and say it out loud.** Ten million registered users, perhaps 10% of them active daily, and say 30 requests each per day. That gives thirty million requests per day, about 350 per second on average, and roughly 2,800 per second at peak with an 8× peak factor. That is a large but entirely ordinary single-primary workload. Both designs in this case did the same arithmetic and reached ~200 and ~35 queries per second respectively. Both then **refused to shard** on that basis. Getting this step wrong in either direction is the most expensive mistake available. If you over-build, you spend a year paying the extra cost of distributed systems. If you under-build, you find out during a launch.

**The simple version, which should be genuinely simple.**

- A stateless API tier: three or more replicas behind a load balancer, autoscaling on processor use.
- One relational primary with a read replica, zone-redundant, with point-in-time recovery.
- A cache in front of the hot reads.
- Object storage for user-uploaded bytes. The bytes are uploaded directly with signed URLs, and never proxied through the API.
- One queue plus a worker pool for anything the user does not need to wait for, such as email, thumbnails, indexing and exports.
- A transactional outbox from day one, because adding it after the first lost event is much harder than starting with it.
- Observability and a pipeline with real gates from day one. These are not scaling features. They are what makes every later change survivable.

**Then scale in the order in which things break. That order is fairly reliable:**

1. **Connections before capacity.** The first limit you hit is usually the database connection limit multiplied by pod count, not database throughput. Use bounded pools, a transaction-mode pooler, and autoscaling limits that respect the global ceiling.
2. **Reads.** Add a cache with a stated invalidation rule, then read replicas for queries whose consistency budget allows them. Route writes and read-your-writes traffic to the primary explicitly. The marketplace does this by having the vendor workspace read the primary and the metadata document directly. So vendors get read-your-writes, while retailers get the fast, slightly stale projection.
3. **The hot query shape.** Almost always, one query is most of the load. Give it a denormalised projection table that it can serve from a single relation with no joins. Also give it indexes that match the access pattern rather than the columns, and keyset pagination. This is where the marketplace's `product_listing_facets` comes from, and it bought a 45 ms plan on the highest-traffic query in the system.
4. **Writes and unbounded tables.** Partition by month the two or three tables that grow forever (audit, and message or event tables). That way, retention is a detach instead of a long `DELETE`, and index maintenance stays in a small B-tree that fits in cache. Then move the append-only tables that nobody joins to onto their own instance. The cancer platform's evolution trigger is explicit. At 3,000 writes per second or 4 TB, extract audit first, then check-ins, and **only then** consider sharding. That trigger is roughly 20× the modelled load.
5. **Search, if the relational projection stops being enough.** A dedicated search engine is a second store, a second consistency lag, a rebuild procedure, and a scope filter that must never be left out. Take it on against a latency number, as the cancer platform did at 2.4 million notes, not against a preference.
6. **Fan-out and geography, last.** Multi-region active-active is a large step in cost and complexity. For most products, a four-hour regional recovery objective is the right business answer.

**What I would explicitly not do early:** shard, split into microservices, adopt a streaming platform for 0.2 events per second, or run a service mesh for nine workloads. Each of those is defensible at some scale. The discipline is to write down the number that would trigger it. Then the decision is made later against evidence, instead of now against ambition.

</details>


---

### ARCH-18. How do you make a backend service reliable? Imagine the service needs 99.9% availability.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
99.9% is about forty-three minutes a month. That means one bad deploy can use up the whole budget. So at that level, reliability is mostly about how you release, how fast you detect problems, and what you degrade to, rather than about extra replicas. In concrete terms, you need redundancy with named, accepted single points of failure. You need timeouts and breakers on every dependency, a stated fallback per feature, and capacity headroom for `n-1`. And you need backwards-compatible migrations, rehearsed restores, and alerts on the failures that nothing else brings to the surface.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start from the budget.** 99.9% monthly is ~43 minutes. A 60-second database failover costs 2% of it. A bad release that takes ten minutes to notice and five to roll back costs a third of it. That arithmetic tells you where to spend: deployment safety and detection speed matter most.

**Redundancy, and honesty about what is not redundant.** Use multiple stateless replicas across availability zones, and a zone-redundant database primary with automatic failover. Use a three-node broker with quorum queues, so nothing routed to those queues is acknowledged before a majority of replicas has it. Then name the single points of failure that you are *accepting*. Both designs name the edge gateway as a genuine one, and they accept it deliberately. For the cancer platform, the reason is that a second ingress path with its own authentication policy is a worse risk than the outage it prevents. An accepted single point of failure with a written reason is a design. An unnoticed one is an incident.

**Health checks that keep the two questions apart.** Readiness controls traffic, and liveness controls restarts. If you put a dependency check in a liveness probe, a database blip becomes a restart of the whole fleet at the worst possible moment.

**Every dependency call bounded.** Use timeouts derived from a propagated deadline, and bulkheads so that one dependency cannot consume every worker. Use budgeted and jittered retries on idempotent calls only, and circuit breakers. And there is the architectural version: move what you can off the request path, because a dependency you do not call synchronously cannot take you down.

**Graceful degradation, named per feature in advance.** This is what actually buys the number. Search degrades to a clearly labelled chronological browse, served from the relational store, instead of returning an error. Content generation builds up a backlog, while already-approved pages are served normally. In the marketplace, a Redis outage is explicitly "not an outage". Every read falls through to the source stores at higher latency, and capacity is sized to survive the sixfold database load that this causes. Deciding these during design, with the fallback path tested, is what separates a degradation from an outage.

**Capacity and dependency arithmetic.** Provision for `n-1`, so losing an instance is not a cascade. The marketplace provisions for roughly 3× its modelled peak, and it calls that one autoscaling step, not an architectural allowance. Also, your availability cannot exceed the product of the availabilities of every hard synchronous dependency. That is a strong argument for caching, fallbacks and asynchrony. It is also a strong argument against adding a synchronous hop casually.

**Release safety, which is where most of the budget goes.** Use expand/contract migrations. Then the previous image always runs against the new schema, and **rollback is a redeploy of the previous digest**, not a down-migration. Use blue-green for the service that holds the record, and canary where a regression is statistical rather than binary. Use blocking pipeline gates that can genuinely fail, with integration tests against real stores instead of mocks, because a mocked broker cannot fail the way a real one does. And drain workers instead of killing them.

**Backups you have restored.** Use point-in-time recovery with a stated recovery point objective and recovery time objective. Rehearse it quarterly against a scratch environment. That includes the rebuild of any derived store that you claim as a mitigation elsewhere. A backup that has never been restored is an assumption, not a control.

**Detection, and alerting on the silent failures specifically.** Error rate, latency and saturation are the basics. The alerts that earn their place are the ones on failures that raise no error: unpublished outbox age, indexer lag, reminder lateness, a dead-letter count above zero, and replica lag. A dead indexer produces no exception anywhere. Listings simply stop becoming searchable. So without that metric, the first report comes from a customer.

**And an error budget with a consequence.** The cancer platform states it plainly: if the record-path budget is exhausted, feature work stops for the sprint. A target with no consequence is a number in a document.

</details>


---

### ARCH-19. What happens if your database becomes unavailable for 30 seconds? What happens to your API? What happens if it stays unavailable for 30 minutes?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Thirty seconds is a failover, which is the case the design plans for. Connections fail, and the service fails fast with `503`. Bounded and jittered reconnection avoids a storm. Reads that the design permits are served from cache or from a replica. Writes that must not be lost are already durable on a broker. Thirty minutes is an incident. The error budget is gone, and queues and retries have been building up the whole time. The dangerous moment is the recovery, not the outage.

<details>
<summary><strong>Detailed answer</strong></summary>

**At 30 seconds, this is a zone failover, and it should be boring.**

- **Connection errors, not hangs.** A short connect timeout and pool pre-ping mean that the application discovers the loss quickly, instead of collecting stuck workers. Requests return `503` with a `Retry-After`, instead of timing out at the limit of the client's patience.
- **Bounded reconnection.** Every pod will try to refill its pool the instant the new primary accepts connections. Without backoff and jitter, hundreds of simultaneous authentication handshakes hit a cold instance and bring it down again. That is why the marketplace names pooling with bounded reconnection specifically as the mitigation for its 60–120 s failover window.
- **Readiness, not liveness.** Pods should report not-ready, so traffic stops. They must not be restarted. Otherwise, the fleet comes back cold exactly when the database returns.
- **What still works.** In the marketplace, catalog browse survives on the replica and the cache. A listing detail served from Redis needs no primary at all. In the cancer platform, check-ins are already durable on the broker before the record write. So the patient sees "recorded", and the projection catches up. By design, the recovery point objective is zero for accepted check-ins.
- **What deliberately does not work.** The cancer platform serves **no** cached fallback for a patient timeline. The reason is that every read of patient data writes an audit row, and a read that cannot be audited must not be served. Reads and writes both return `503` during failover. That is the stated price of synchronous audit, accepted knowingly. At a ~60 s failover, this price fits the budget, because the failover is roughly 2% of forty-three minutes.
- **Queued work waits instead of failing.** Consumers back off and retry. Messages stay on the broker. Reminders stay `pending` in the database and are swept again. The work is late, not lost.

**At 30 minutes, it is different in kind, not in degree.**

- **The budget is spent.** Thirty minutes is 70% of a 99.9% monthly allowance. This is a declared incident with a status page, not a blip.
- **Backlogs become their own problem.** Queue depth climbs for half an hour. A broker under memory pressure raises a memory alarm and blocks publishers. That pressure spreads back into services that were otherwise healthy. This is the failure mode where a backlog takes down components that the original outage never touched.
- **Shed, don't retry.** By now, retry budgets should be driving attempts toward zero, and breakers should be open. If you keep retrying into a dead database, you get the metastable pattern, where the retry load keeps the system down after the cause is gone.
- **Degrade explicitly.** Serve what is cached or replicated, with a clear indication of staleness. Put anything that must be durable onto the queue path. And disable features that cannot be served honestly, instead of letting them fail slowly.
- **Consider the restore path.** Beyond a failover, this becomes a recovery decision against the stated objectives. For the marketplace, those are a 15-minute recovery point and a 4-hour recovery time. For the cancer platform, they are 5 minutes and 30 minutes. Knowing those numbers, and having rehearsed a point-in-time restore, is what makes the decision take minutes instead of hours.

**The recovery is the risky part, and this is the most important point of the answer.** When the database comes back, three things arrive at once. Every client's backed-off retries arrive. Half an hour of queued work drains at full worker concurrency. And a cold buffer cache serves requests from disk. On top of that, the application caches have expired. So the arriving load is both larger and more expensive per request than the steady state. The marketplace's own figure is that a cold cache multiplies database load roughly sixfold. So recovery is deliberate. Bring workers back with reduced concurrency, and drain the backlog at a rate that the database can absorb. Admit user traffic behind a rate limit. Let the caches warm. Then lift the restrictions. A recovered database that is killed by its own backlog is a common second outage, and an avoidable one.

**Afterwards**, the useful question is not "why did the database fail". It failed, and that is what hardware does. The useful question is "which of our reactions made it worse", because those reactions are the ones you can fix.

</details>

