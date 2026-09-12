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
Choreography — services reacting to published facts with no coordinator — when the reactions are genuinely independent and adding a consumer should not touch the publisher. Orchestration — one component that knows the whole sequence — when the sequence itself is the business logic, when order or compensation must be coordinated, or when someone needs to ask "where did this get to". The debugging cost is the mirror image: choreography has no single place that describes the flow, and orchestration has a coupling point that every change goes through.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction I actually use** is not about technology, it is about where the knowledge of the sequence lives. In choreography, no component knows the flow; each knows only what it reacts to, and the flow is an emergent property of the bindings. In orchestration, one component holds the sequence explicitly and tells the others what to do.

The clinical platform states the boundary as a rule rather than deciding case by case, and I think that is the right way to hold it: **[Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") models work we schedule and retry for ourselves; a topic exchange models facts we publish for others.** Collapsing them makes every consumer a Celery task and couples independent services to one task registry. So reminder sweeps, page generation and index projection are orchestrated work with owners, deadlines and retry policies; `checkin.recorded` and `visitnote.created` are facts published to whoever cares. The same seam exists in the marketplace: Celery moves work between Python processes we own, Service Bus moves events across a boundary, and the notification split follows it exactly — the worker decides *whether and what* to notify, which is a policy decision needing database context, and the Function performs *delivery*. One owner per step, no overlap.

**Choose choreography when:** the consumers are independent of each other; adding one should not require touching or redeploying the publisher; the publisher genuinely should not know who reacts; and no consumer's failure changes what another consumer should do. The concrete payoff in the clinical platform is that the publisher of a visit note is the module that owns the clinical record — the highest-risk deployable in the system — and a new downstream feature must never require redeploying it.

**Choose orchestration when:** the order of steps is part of the business rule; a step's outcome decides whether a later step happens; compensation has to be coordinated across steps; you need to query the state of an in-flight operation; or the flow has a timeout as a whole rather than per step. Anything shaped like the saga in the previous question wants an orchestrator, because "which step are we on" has to be a row somebody can select.

**Debugging choreography.** There is no file you can open that describes the flow. Answering "what happens when a listing is published" means reading the bindings, the subscriptions and the consumers, and the topology *is* the program. The specific failure mode is the one nobody sees: a binding that matches nothing. The broker accepts the publish, returns a confirm, and discards the message — so the defences are structural rather than diagnostic. An alternate exchange turning unroutable publishes into visible backlog, an event catalogue that is maintained as a real artefact listing every event with its emitter and consumers, binding topology declared in code and asserted in integration tests rather than eyeballed in a management interface, and trace context propagated through message headers so one trace spans publish through project through invalidate through notify. Without that last one, a failure between a worker and a Function is two unconnected half-stories.

**Debugging orchestration.** Much easier — the sequence is in one place, the state is a row, and "where did this get to" is a query. What you pay is coupling: the orchestrator knows every participant, so every new step is a change to it, and it becomes a deployment bottleneck and a single component whose failure stalls every flow it drives. It also drifts toward becoming the place all the business logic accumulates, at which point the services around it are anaemic and you have a distributed monolith with extra network hops.

**The anti-pattern worth naming.** Choreography where the services are not actually independent — every consumer must be deployed in lockstep because event shapes are coupled and a change to one ripples through all of them. That is a distributed monolith wearing an event-driven costume: you have paid every cost of asynchrony and kept every cost of coupling. The tell is whether you can add a consumer without coordinating a release, and whether you can change an event's shape additively. If the answer to either is no, the choreography is nominal.

**What I would do in practice**, and have: choreograph the fan-out of facts, orchestrate anything transaction-shaped, keep the rule written down once so it is not relitigated per feature, and instrument both the same way — because the observability requirement is identical and it is the only thing that makes either debuggable at three in the morning.

</details>


---

### ARCH-02. When is a separate read model worth building, and when is it over-engineering?

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

### ARCH-03. What's the difference between strong consistency and eventual consistency? What business trade-off exists here?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Under strong consistency a successful write is visible to every subsequent read; under eventual consistency reads may see an older value for a bounded period. The business trade-off is not abstract: it is whether a stale answer is recoverable. A listing that takes five seconds to appear in search costs nothing; a lost prescription write or a double-counted charge cannot be undone, so those paths pay for consistency with availability.

<details>
<summary><strong>Detailed answer</strong></summary>

**The definitions, tightened.** Strong consistency means reads are ordered after writes that completed before them — what a single primary gives you by default. Eventual consistency means replicas converge given no new writes, with no promise about when unless you make one. "Read-your-writes" is a weaker, often sufficient guarantee: *you* see your own write immediately, other people may not.

**The decision is per path, not per system, and that is the main point.** Both designs are explicitly mixed:

- The marketplace is **consistent and partition-tolerant for connections, billing and identity, available and partition-tolerant for catalog reads**. A connection request, a charge or a token must never be lost or double-counted; a listing edit invisible for a few seconds costs nothing.
- The cancer platform is consistent for the clinical record — under a partition it returns `503` rather than serve a possibly-stale prescription — and available for diary ingest, where a check-in is durable on the broker and acknowledged before it reaches the record, because losing a patient's symptom entry to a partition is worse than showing it a few seconds late.

Both state the boundary in the requirements document rather than discovering it per endpoint, and in the cancer platform the boundary between the two positions is literally a queue.

**What eventual consistency actually costs, which is the part that separates a real answer from a definition.** It is never free and it is never just "a bit stale":

- **A bounded lag, and therefore a budget and an alert.** The marketplace budgets projection freshness at p95 under 5 s, p99 under 30 s, and measures it as `indexer_lag_seconds` alerting at 60 s. The cancer platform composes its search budget rather than asserting it — a 2 s outbox relay plus a 5 s bulk flush plus a 5 s refresh interval gives p95 under 15 s, and it notes that tightening any one of the three alone buys nothing. "Eventually consistent" without a number and a metric means "eventually, possibly".
- **A reconciliation job.** Without one, a single lost event is permanent. Both designs have a nightly sweep that re-projects anything whose projection timestamp predates its update timestamp.
- **Read-your-writes routing for the author.** The vendor who just clicked publish is the one person for whom the lag is glaring, so the vendor workspace reads the primary and the document store directly, never the projection or the cache. The design does not shrink the lag; it routes around it for the one party who notices.
- **A second authorization surface.** Every store that can answer a query is a path around your access control, which is why every document in the clinical search index carries mandatory scope fields.

**How I would frame the trade-off to a business stakeholder.** Not as consistency versus availability, but as: *what does a wrong answer cost, and can we undo it?* A stale search result is a refresh. A double charge is a refund, a support conversation and a trust cost. A missing clinical record entry during a consultation is a safety incident. Once the question is asked that way the answer is usually obvious, and it is almost always different for different paths in the same product — which is exactly why a single system-wide consistency choice is the wrong shape of decision.

</details>


---

### ARCH-04. Six services and three worker pools share a lot of code. How do you avoid building a distributed monolith?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

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
- **A shared data access layer over a shared database.** This is the strongest form of coupling there is, and it is the one that always arrives by accident. Each service owns its tables. Another service asking for that data gets an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") or an event, not a query.
- **A shared library containing business rules.** The rule then lives nowhere in particular and changing it means a coordinated release of everything.

**What keeps it honest mechanically.** Import rules in the linter declaring the layer graph and failing the build on a back edge, because nothing in Python prevents a domain module importing the database session — without that check, the architecture degrades into a folder naming convention within about two sprints. Separate schemas per owning service with permissions enforcing it, so a cross-service query fails rather than works. And versioning the shared library properly with services able to lag, so an upgrade is per service rather than a fleet operation.

**The signal that it has gone wrong.** A change that requires touching four repositories, or a deploy order that matters. Either of those means the boundaries are in the wrong place, and the honest response is either to fix the boundary or to admit that these should be one deployable — which for a system at this traffic level would be a defensible answer rather than a defeat.

</details>


---

### ARCH-05. In your recent work on the Cancer Support Platform, you transitioned from a FastAPI modular monolith to extracted microservices for SCIM and NLP; what specific technical criteria did you use to define the service boundaries, and how did you handle data consistency between these services using RabbitMQ?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Only two things left, and each left for a reason that survives scrutiny: `scim-provisioning-svc` because its release cadence belongs to the hospital directory rather than to us, and `clinical-nlp-svc` because it needs GPU hardware and ships on a model's schedule. Everything else stayed in `care-core` because at roughly 200 queries per second a distributed transaction across `diary` and `records` buys latency and on-call load for no throughput. Consistency is not two-phase commit — it is a transactional outbox publishing domain facts to the `care.events` topic exchange, with idempotent consumers and a natural key in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") underneath.

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

### ARCH-06. A business operation spans three services and cannot be one transaction. How do you make it eventually correct, and what happens when a compensating step itself fails?

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

### ARCH-07. Would you event-source either of these systems? Argue it either way.

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

## 2. Resilience

---

### ARCH-08. A downstream dependency starts degrading. Walk me through timeouts, retries, circuit breakers and bulkheads — and how each one can make the situation worse.

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

**The strongest version of the answer is architectural rather than library-level.** The cancer platform's design states that no synchronous user path depends on `clinical-nlp-svc` at all: requests queue on `celery.content`, so the GPU cluster being unavailable pauses new page generation and does not touch a single user-facing request. A dependency you do not call synchronously needs no breaker.

**The failure I have seen most.** All four added at once, none measured, and the aggregate timeout ends up longer than the client's — so the client gives up and retries while the server is still patiently working through its own retry schedule. The order I would actually apply them: bound everything with a timeout, make the operation idempotent, add jittered and budgeted retries, add a breaker with a fallback and a dashboard, and partition the pools. Then load-test with the dependency deliberately degraded — not down, *slow*, which is the harder and more common case — because a mock cannot be slow in the way a real dependency is.

</details>


---

### ARCH-09. Why can retries actually make an outage worse?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Because a retry multiplies load at exactly the moment capacity has dropped. Three attempts per request is four times the traffic arriving at a system that just proved it cannot serve one times — and if several layers each retry, the multiplication compounds. Without jitter they arrive synchronised, and the result is a system that stays down after the original cause is gone.

<details>
<summary><strong>Detailed answer</strong></summary>

**The arithmetic.** A client that retries three times turns 100 requests per second into 400 when things start failing. Now stack the layers, which is the case people underestimate: a browser or [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") retry, a gateway retry, an application-level retry, and a database driver retry — each with three attempts — is 3⁴ in the worst case. Every layer looked reasonable in isolation. This is why a retry budget belongs at the top of the stack, and why retries at more than one layer of a call chain is an anti-pattern rather than defence in depth.

**Synchronisation.** Fixed backoff, or even plain exponential backoff without jitter, makes every failed client wait the same interval and retry at the same instant. The recovering service receives a wall of traffic, falls over, and produces another synchronised wave. **Full jitter** — sleep a random duration between zero and the current backoff ceiling — spreads them out, and it is the single cheapest fix in this entire area.

**Work nobody is waiting for.** When the caller has already timed out, the request still in flight is dead work, but it still consumes a worker, a connection and a database transaction. Under a retry storm, a large fraction of the work a system is doing is for clients that have gone. The defence is deadline propagation: pass the remaining budget down, and let each hop refuse work whose deadline has already passed rather than doing it and discarding the result.

**Queue and pool poisoning.** Retries fill bounded resources. The connection pool saturates, so healthy endpoints start queueing behind the failing one. A broker's queue depth climbs, and on a broker under memory pressure that becomes flow control on publishers — a distinct failure that spreads back into the services doing the publishing, which is exactly the shape of "millions of updates overloaded the broker and took production with it".

**Metastable failure, which is the name worth knowing.** The system enters a state where the retry load is itself sufficient to keep it failing, so removing the original trigger does not fix it. The database is now slow *because* of the retries, which are happening *because* it is slow. Recovery requires shedding load from the outside — rate-limiting at the edge, or literally turning clients away — and that is a very uncomfortable incident to run. Recognising it matters because the intuitive response, "wait for it to recover", never terminates.

**So what makes a retry safe:**

- **A retry budget**, not a retry count — cap retries at a small percentage of successful traffic, so under a broad failure retries approach zero automatically. This is the control that fails safe as the failure widens.
- **Exponential backoff with full jitter**, and a hard attempt ceiling.
- **Retry only retryable errors**, and only idempotent operations or ones carrying an idempotency key.
- **Retry at one layer**, chosen deliberately, and disable it at the others.
- **A circuit breaker underneath**, so a sustained failure stops generating attempts at all.
- **Deadline propagation**, so a retry is never attempted past the caller's deadline.

**And the recovery-side detail people miss:** the moment the dependency comes back is the most dangerous one. Every breaker half-opens, every backoff expires, every pool refills, and the caches are cold — so the returning traffic is larger and more expensive per request than the steady state. The marketplace design sizes for exactly this by noting that a Redis loss multiplies PostgreSQL load roughly sixfold and provisioning to survive it, and it names bounded reconnection as the specific mitigation for the post-failover storm.

</details>


---

### ARCH-10. Design a service that communicates with another unreliable service.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The first design decision is whether the call needs to be synchronous at all; if the user does not need the answer to get their response, put a queue between them and most of the problem disappears. Where it must be synchronous, the stack is a propagated deadline, a bulkhead, a timeout inside that deadline, budgeted and jittered retries on idempotent calls only, a circuit breaker, and a named fallback — plus per-dependency observability, because you cannot operate what you cannot see failing.

<details>
<summary><strong>Detailed answer</strong></summary>

**Decide the interaction shape first.** This is the decision that dominates all the library-level ones. The cancer platform's rule is that no synchronous user path depends on `clinical-nlp-svc`: page generation is enqueued on `celery.content`, and the GPU cluster being unreachable means new page generation pauses while already-approved pages serve normally. The marketplace draws the same line at the outbox — publishing a listing must not fail because the notifier is down, so the state change commits with an `outbox_event` and delivery happens afterwards. Both are the same move: convert a dependency on availability into a dependency on eventual delivery. Where that is possible it beats every resilience pattern, because the failure stops being user-visible rather than being handled gracefully.

**Where it must be synchronous, the layers, outermost first.**

1. **A deadline, propagated.** The incoming request has a budget. Each hop subtracts what it has spent and passes the remainder. A call whose deadline has already expired is not attempted.
2. **A bulkhead.** A dedicated connection pool or a bounded semaphore per dependency. Without it, one slow dependency eventually holds every worker in the process and every unrelated endpoint fails alongside it. This is the control that keeps the blast radius to the feature rather than the service.
3. **A timeout strictly inside the deadline**, with connect and read timeouts separated so the retry decision can distinguish "nothing was sent" from "something may have been applied".
4. **Retries, budgeted and jittered, on idempotent operations only.** Outbound mutations carry an idempotency key so the remote side can deduplicate, which is what makes a retry on a `POST` legitimate at all.
5. **A circuit breaker** with half-open probing, so a sustained outage costs no threads and gives the dependency room to recover.
6. **A fallback that is named in the design, not improvised in the incident.** Serve last-known-good from cache; degrade the feature and say so in the response; queue the work for later; or fail open. The marketplace picks fail-open explicitly on its one synchronous inter-service hop — if `retailer-service` does not answer within 250 ms, the connection request proceeds, because refusing a legitimate connection costs the marketplace more than an occasional duplicate thread, and the `UNIQUE (retail_group_id, idempotency_key)` constraint catches the duplicate anyway. That is the right shape for a fallback: a stated trade-off with a compensating control, not a shrug.

**Make the boundary observable.** Per-dependency metrics for call rate, error rate by class, latency percentiles, timeout count, breaker state and bulkhead saturation. Breaker transitions should be events you can see on a dashboard, because "the breaker opened at 14:02" collapses an investigation that otherwise takes an hour. Trace context propagates across the call so a failure is one trace and not two half-stories.

**Two more that belong in a senior answer.** **Contract testing**, because an unreliable dependency is often unreliable in shape as well as availability — a field that becomes nullable is an outage you caused by trusting a document. And **treat the dependency's service level objective as a ceiling on yours**: if it offers 99.5% and you call it synchronously on every request, you cannot promise 99.9%, and the only ways to break that arithmetic are caching, a fallback, or moving the call off the request path. Saying that out loud during design is more valuable than any amount of retry tuning.

</details>

---

## 3. Scaling and system composition

---

### ARCH-11. Explain purpose of each component from system design perspective: caching, replicas, queues, workers, object storage, observability, horizontal scaling?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Each one removes a specific pressure and adds a specific cost, and the cost is the part worth knowing. Caching trades freshness for latency, replicas trade consistency for read capacity, queues trade immediacy for durability, workers trade simplicity for isolation, object storage keeps bytes off the application tier, observability is what makes silent failures visible, and horizontal scaling is what statelessness buys you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Caching — buys latency and load reduction, costs freshness and an invalidation rule.** The marketplace caches hydrated listings at `cat:listing:{product_id}:v{rev}` and search pages at `cat:search:{filter_hash}`, and the latency budget assumes an 85% hit ratio on the search page. The discipline that makes it safe: **every layer has a stated invalidation rule**, and the revision in the key means a stale entry is unreachable even if the purge message is lost. The rule I would state is that nothing patient-identifiable is cached at a layer that cannot see the requester's identity — which is why gateway response caching is switched off by policy in the cancer platform rather than merely unused. A cache with no invalidation story is a correctness bug with a latency benefit.

**Read replicas — buy read capacity and isolation for heavy reads, cost you read-your-writes.** The marketplace serves catalog search from a replica and routes every write and every must-be-fresh read to the primary. The cancer platform makes the opposite call for an instructive reason: every read of patient data writes an audit row, so an audited read is a write and **cannot be served by a replica at all**. Replicas there carry only unaudited work — index rebuilds, reporting, backup verification. That is the clearest example I know that a replica is not free read capacity; it is read capacity for queries whose consistency and write requirements permit it.

**Queues — buy durability and decoupling, cost immediacy and an operational surface.** They take work off the request path so a slow or unavailable downstream cannot fail the user's request, and they absorb bursts that would otherwise have to be provisioned for. The check-in path is the purest case: the message is durable on the broker before the record write, so a flaky mobile connection cannot lose a patient's symptom entry. The costs are real — at-least-once delivery, therefore idempotent consumers; a backlog that needs a metric; and a dead-letter queue somebody has to read.

**Workers — buy isolation of blast radius and independent scaling.** Separate deployments consuming separate queues mean a 20,000-row import scales the importers on queue depth without touching the web tier, and cannot starve the indexer. Same codebase, different process, different failure domain. The cost is more deployments to observe and a second place where code runs.

**Object storage — keeps large bytes out of the application entirely.** Documents upload directly to blob storage with a short-lived signed token rather than proxying through the API, so multi-megabyte scans never touch the pods serving a clinician's timeline, and the database row holds metadata and a path. It is also where immutability and lifecycle live: a write-once audit archive with a seven-year legal hold is a storage feature, not an application feature.

**Observability — the only reason anyone knows the system is broken.** Three planes joined by one trace identifier: metrics for the shape, traces for the path, logs for the detail. Its real purpose is the failures nothing else surfaces. A dead indexer raises no error anywhere — listings simply stop becoming searchable — so `indexer_lag_seconds` alerting at 60 s is the *only* thing standing between that and a silent product outage. That is the argument for observability as a component rather than a nicety.

**Horizontal scaling — buys capacity and, more importantly, redundancy.** Adding identical stateless replicas behind a load balancer is how you absorb load, survive an instance loss, and deploy without downtime. It works only if the instances hold no request-affine state, which is what statelessness is for. The limit is that it scales the tier you replicate and nothing else: the database, the broker and the caches remain shared, so beyond a point adding pods just concentrates more pressure on the same primary.

**The connecting idea.** None of these is a default. Both of these designs refuse components against a measured number — no sharding at 200 queries per second, no search cluster for 40,000 listings, no service mesh for nine workloads — and each component taken is justified against a figure with the condition that would reverse it written down. That reasoning is more useful in an interview than the component list.

</details>


---

### ARCH-12. Explain load balancing. Why would we put a load balancer in front of three API instances? What happens if one instance dies?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace

**Brief answer**
A load balancer spreads requests across instances and, more importantly, continuously decides which instances are eligible to receive them. Three instances are not primarily about capacity — they are what lets you lose one, or deliberately take one out to deploy, without an outage. When one dies, the health check removes it, in-flight requests to it fail and must be retried, and the remaining two absorb the traffic, which only works if you left headroom for that.

<details>
<summary><strong>Detailed answer</strong></summary>

**Two jobs, and the second is the important one.** Distribution is the obvious job. Health checking is the one that turns three servers into an available service: the balancer probes each instance and routes only to the ones passing, so a failed instance stops receiving traffic within a probe interval rather than continuing to serve errors.

**Why three rather than one bigger box.** Capacity is the least interesting reason at 35 queries per second. The real ones are: an instance can fail without the service failing; you can deploy by rolling instances out one at a time while the others serve; and with instances spread across availability zones the loss of a zone is a capacity reduction rather than an outage. In the marketplace `catalog-service` additionally runs a second deployment receiving about 10% of traffic as a canary, held for fifteen minutes against its error rate and latency before the weight advances — which is only possible because the balancer can weight destinations.

**Algorithms, briefly, and when the default is wrong.** Round robin is fine when requests cost roughly the same. **Least outstanding requests** is better when they do not, which is the usual case for an API where one route is a 3 ms cache hit and another is a 107 ms uncached search — round robin will happily keep feeding an instance that is already stuck behind slow work. Consistent hashing matters when the backends hold per-key state, such as a cache tier, and is unnecessary for stateless application pods.

**What happens when one dies, step by step.**

1. **In-flight requests on that instance fail.** Nothing saves them — this is why clients and gateways retry idempotent requests, and why a `POST` needs an idempotency key before a retry is safe.
2. **The health probe fails and the instance is removed**, after the configured threshold. That delay is a deliberate trade: too aggressive and a garbage-collection pause ejects a healthy instance, too slow and clients see errors for longer.
3. **The remaining two carry the load.** If the three were running at 70% CPU, two cannot carry 105% and you now have a cascade rather than a degradation. Headroom for `n-1` is the actual design requirement, and it is the reason autoscaling targets are set well below saturation.
4. **The orchestrator replaces the instance**, and the new one starts cold — empty in-process caches, a cold connection pool — so recovery takes longer than the restart.

**Two distinctions worth drawing unprompted.** **Readiness versus liveness**: readiness controls traffic, liveness controls restarts, and conflating them is a classic self-inflicted outage — a readiness probe that depends on the database will correctly stop traffic during a database blip, but a *liveness* probe that does the same will restart every pod in the fleet simultaneously at the worst moment. And **connection draining**: a pod being removed deliberately should stop accepting new connections, finish what it has, and then exit — a `preStop` hook and a grace period — otherwise every deploy is a small burst of errors.

**Sticky sessions.** They exist, and I would treat needing them as a signal to fix the application instead. Affinity defeats even distribution, makes the loss of an instance a loss of user state, and blocks rolling deploys. Move the session into Redis or a signed token and the problem disappears — which is exactly the next question.

</details>


---

### ARCH-13. What does it mean for a service to be stateless? If our API needs user sessions, does that mean the API cannot be stateless?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Stateless means no request depends on state held in *that particular process* from a previous request — so any instance can serve any request and losing an instance loses nothing. Sessions do not break it, provided the session lives somewhere shared: in Redis under a session identifier, or in a signed token the client carries. The application is stateless; the state is simply not in the application.

<details>
<summary><strong>Detailed answer</strong></summary>

**The precise claim.** Statelessness is not "holds nothing in memory" — every service holds connection pools, compiled validators, and in-process caches of near-static data such as the category tree and facet schemas. Those are legitimate because nothing breaks if a request lands on a different pod: the new pod rebuilds them, and no *correctness* depends on which instance handled the previous request. The test is: can I kill any instance at any moment and lose nothing but the requests currently in flight? If yes, it is stateless in the sense that matters, and horizontal scaling, rolling deploys and instance replacement all work.

**Sessions, two ways, both stateless in that sense.**

- **Server-side session in a shared store.** The cancer platform keeps `sess:{session_id}` in Redis with a 30-minute sliding expiry. The client holds only an opaque identifier; any pod resolves it. Revocation is immediate — delete the key — which is the main advantage.
- **Self-contained signed token.** The marketplace issues [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Tokens with a 15-minute lifetime carrying account type, organisation and scopes, verified locally against a key set cached in Redis. No lookup per request at all, which is precisely why authorization costs about 1 ms in the latency budget rather than the 15–30 ms an introspection round-trip would add.

**The trade-off between them is revocation, and it is worth naming.** A signed token cannot be un-issued, so revocation is bounded by the token lifetime. The marketplace answers that in layers: short access tokens, refresh-token rotation with reuse detection that revokes the whole chain immediately, and for the case where fifteen minutes is still too long — a suspended vendor — an `identity.user.deactivated` event plus a small Redis denylist of revoked token identifiers. Note what that denylist is: a deliberate, bounded reintroduction of shared state to fix the one thing stateless tokens are bad at. That is a better answer than pretending the trade-off does not exist.

**What genuinely is not stateless, and what to do about it.** Long-lived connections — WebSockets, server-sent events, and the [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") check-in listener — bind a client to one process for the connection's duration, so scaling and deploys have to account for reconnection. In-memory rate-limit counters would be per-pod and therefore wrong, which is why the buckets live in Redis at `rl:{subject_id}:{bucket}`. A file written to local disk during an upload is invisible to the next request, which is why documents go directly to blob storage. And the scheduler is an honest singleton: one replica holding a distributed lock, because "exactly one process does the sweep" is inherently stateful — mitigated by keeping the due rows in the database so its failure delays work rather than losing it.

**So the direct answer:** needing sessions does not make an API stateful. Needing sessions *in the process's own memory* does, and that is the thing to move, not the requirement to drop.

</details>


---

### ARCH-14. How do you choose between a managed cloud service and running the component yourself in the cluster?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

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

### ARCH-15. Traffic goes up tenfold and stays there. Walk me through what breaks first, in what order, and which of those you can fix with configuration rather than code.

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
5. **Cache and its stampede behaviour.** A tenfold traffic increase on a cache-aside layer multiplies the concurrency hitting each expiry. Without single-flight and probabilistic early expiry, every [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") boundary becomes a synchronised thundering herd at the database. Both are code, and both are already present in the marketplace design precisely because the traffic pattern makes it inevitable.
6. **Singletons.** The Celery beat scheduler is one replica by design, holding a distributed lock so a restart cannot double-schedule. It does not break under load in the same way, but it does not scale either, and the sweep window has to still fit. That is a design review, not a setting.
7. **The edge.** The gateway and front door are a genuine single point of failure for north-south traffic in both designs, accepted deliberately. At ten times load, tier and quota configuration matter, and they are configuration — but the rate limits themselves need re-deriving, because limits calibrated for the old volume will now reject legitimate traffic.

**Configuration versus code, summarised.** Configuration: pool sizes at every layer, replica and worker counts, autoscaler bounds, prefetch, cache TTLs, gateway tier, rate-limit thresholds, `work_mem` and autovacuum aggressiveness. Code and design: N+1 queries that were tolerable at one times and are fatal at ten; synchronous work on the request path; the audit-write coupling; anything with a hidden singleton; and query plans that flip when the table crosses a planner threshold — which is the failure that arrives without any deploy at all.

**The honest framing for these two systems specifically.** Both are sized against modest numbers — about 200 queries per second peak in the clinical platform, about 35 in the marketplace — and both explicitly refuse to buy sharding or a service mesh against numbers that do not require them. Ten times either figure is still well inside what a single well-tuned primary with replicas handles, so my answer is emphatically *not* "shard it". The documented evolution triggers say the same thing in the right order: above about 3,000 sustained writes per second or 4 TB hot, the first move is extracting the append-only audit and check-in tables to their own instance — they are referenced by no foreign key and read by nothing on the request path — and only after that would sharding the record by patient be considered, which is roughly twenty times the modelled load. Knowing the trigger *and* the order is more useful than knowing the techniques.

</details>


---

### ARCH-16. An enterprise client sends a bulk load that is orders of magnitude larger than normal traffic. How do you keep it from starving everyone else, and what do you do when shedding load is the only honest option left?

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

### ARCH-17. Design a backend for an application with 10 million users. Start simple. What would you build, and where would you scale when traffic increases?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
First do the arithmetic, because ten million registered users is not a throughput figure — with ordinary engagement it is a few thousand requests per second, and most of the architecture follows from that number rather than from the headline. Start with one stateless API tier behind a load balancer, one relational primary with a replica, a cache, object storage for blobs, and a queue for anything slow. Then scale in the order things actually break: connections, then reads, then writes, then individual tables.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start with the estimate, out loud.** Ten million registered, perhaps 10% daily active, say 30 requests each per day: three million requests per day, about 35 per second average, and with an 8× peak factor roughly 300 per second at peak. That is a large but entirely ordinary single-primary workload. Both designs in this case did the same arithmetic and reached ~200 and ~35 queries per second respectively, and both then **refused to shard** on that basis. Getting this step wrong in either direction is the most expensive mistake available: over-build and you spend a year on distributed-systems tax, under-build and you find out during a launch.

**The simple version, which should be genuinely simple.**

- A stateless API tier, three or more replicas behind a load balancer, autoscaling on CPU.
- One relational primary with a read replica, zone-redundant, with point-in-time recovery.
- A cache in front of the hot reads.
- Object storage for user-uploaded bytes, uploaded directly with signed URLs, never proxied through the API.
- One queue plus a worker pool for anything the user does not need to wait for — email, thumbnails, indexing, exports.
- A transactional outbox from day one, because retrofitting it after the first lost event is much harder than starting with it.
- Observability and a pipeline with real gates from day one. These are not scaling features, they are what makes every later change survivable.

**Then scale in the order things break, which is fairly reliable:**

1. **Connections before capacity.** The first wall is usually the database connection limit multiplied by pod count, not database throughput. Bounded pools, a transaction-mode pooler, and autoscaling limits that respect the global ceiling.
2. **Reads.** A cache with a stated invalidation rule, then read replicas for queries whose consistency budget allows them. Route writes and read-your-writes traffic to the primary explicitly — the marketplace does this by having the vendor workspace read the primary and the metadata document directly, so vendors get read-your-writes while retailers get the fast, slightly stale projection.
3. **The hot query shape.** Almost always one query is most of the load. Give it a denormalised projection table it can serve from a single relation with no joins, indexes that match the access pattern rather than the columns, and keyset pagination. This is where the marketplace's `product_listing_facets` comes from, and it bought a 45 ms plan on the highest-traffic query in the system.
4. **Writes and unbounded tables.** Partition the two or three tables that grow forever — audit and message or event tables — by month, so retention is a detach rather than a long `DELETE`, and index maintenance stays in a small cache-resident B-tree. Then move the append-only, nobody-joins-to-it tables to their own instance. The cancer platform's evolution trigger is explicit: at 3,000 writes per second or 4 TB, extract audit first, then check-ins, and **only then** consider sharding — which is roughly 20× the modelled load.
5. **Search, if the relational projection stops being enough.** A dedicated search engine is a second store, a second consistency lag, a rebuild procedure and a scope filter that must never be omitted. Take it against a latency number, as the cancer platform did at 2.4 million notes, not against a preference.
6. **Fan-out and geography, last.** Multi-region active-active is a large step in cost and complexity, and for most products a four-hour regional recovery objective is the right business answer.

**What I would explicitly not do early:** shard, split into microservices, adopt a streaming platform for 0.2 events per second, or run a service mesh for nine workloads. Each of those is defensible at some scale, and the discipline is writing down the number that would trigger it so the decision is made against evidence later instead of against ambition now.

</details>


---

### ARCH-18. How do you make a backend service reliable? Imagine the service needs 99.9% availability.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
99.9% is about forty-three minutes a month, which means one bad deploy can consume the whole budget — so reliability at that level is mostly about how you release, how fast you detect, and what you degrade to, rather than about extra replicas. Concretely: redundancy with named accepted single points of failure, timeouts and breakers on every dependency, a stated fallback per feature, capacity headroom for `n-1`, backwards-compatible migrations, rehearsed restores, and alerts on the failures nothing else surfaces.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start from the budget.** 99.9% monthly is ~43 minutes. A 60-second database failover costs 2% of it; a bad release that takes ten minutes to notice and five to roll back costs a third. That arithmetic tells you where to spend: deployment safety and detection speed dominate.

**Redundancy, and honesty about what is not redundant.** Multiple stateless replicas across availability zones; a zone-redundant database primary with automatic failover; a three-node broker with quorum queues so nothing is acknowledged that is not replicated. Then name the single points of failure you are *accepting*: both designs name the edge gateway as a genuine one and take it deliberately — for the cancer platform, because a second ingress path with its own authentication policy is a worse risk than the outage it prevents. An accepted single point of failure with a written reason is a design; an unnoticed one is an incident.

**Health checks that distinguish the two questions.** Readiness controls traffic, liveness controls restarts. Putting a dependency check in a liveness probe is how a database blip becomes a fleet-wide restart at the worst possible moment.

**Every dependency call bounded.** Timeouts derived from a propagated deadline, bulkheads so one dependency cannot consume every worker, budgeted and jittered retries on idempotent calls only, and circuit breakers. And the architectural version: move what you can off the request path, because a dependency you do not call synchronously cannot take you down.

**Graceful degradation, named per feature in advance.** This is what actually buys the number. Search degrades to a clearly-labelled chronological browse served from the relational store rather than erroring. Content generation backlogs while already-approved pages serve normally. A Redis outage in the marketplace is explicitly "not an outage" — every read falls through to the source stores at higher latency, and capacity is sized to survive the sixfold database load that causes. Deciding these during design, with the fallback path tested, is what separates a degradation from an outage.

**Capacity and dependency arithmetic.** Provision for `n-1` so losing an instance is not a cascade — the marketplace provisions for roughly 3× its modelled peak and calls that one autoscaling step rather than an architectural allowance. And your availability cannot exceed the product of the availabilities of every hard synchronous dependency, which is a strong argument for caching, fallbacks and asynchrony, and a strong argument against adding a synchronous hop casually.

**Release safety, which is where most of the budget goes.** Expand/contract migrations, so the previous image always runs against the new schema and **rollback is a redeploy of the previous digest** rather than a down-migration. Blue-green for the service holding the record, canary where a regression is statistical rather than binary. Blocking pipeline gates that can genuinely fail, with integration tests against real stores rather than mocks, because a mocked broker cannot fail the way a real one does. Workers drained rather than killed.

**Backups you have restored.** Point-in-time recovery with a stated recovery point and time objective, rehearsed quarterly against a scratch environment — including the rebuild of any derived store you claim as a mitigation elsewhere. A backup that has never been restored is an assumption, not a control.

**Detection, and alerting on the silent failures specifically.** Error rate, latency and saturation are table stakes. The alerts that earn their place are the ones on failures that raise no error: unpublished outbox age, indexer lag, reminder lateness, dead-letter count above zero, replica lag. A dead indexer produces no exception anywhere — listings simply stop becoming searchable — so without that metric the first report comes from a customer.

**And an error budget with a consequence.** The cancer platform states it plainly: exhaust the record-path budget and feature work stops for the sprint. A target with no consequence is a number in a document.

</details>


---

### ARCH-19. What happens if your database becomes unavailable for 30 seconds? What happens to your API? What happens if it stays unavailable for 30 minutes?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Thirty seconds is a failover — the designed case. Connections fail, the service fails fast with `503`, bounded and jittered reconnection avoids a storm, reads that the design permits are served from cache or replica, and writes that must not be lost are already durable on a broker. Thirty minutes is an incident: the error budget is gone, queues and retries have been accumulating the whole time, and the dangerous moment is the recovery, not the outage.

<details>
<summary><strong>Detailed answer</strong></summary>

**At 30 seconds — this is a zone failover, and it should be boring.**

- **Connection errors, not hangs.** A short connect timeout and pool pre-ping mean the application discovers the loss quickly instead of accumulating stuck workers. Requests return `503` with a `Retry-After` rather than timing out at the client's patience limit.
- **Bounded reconnection.** Every pod will try to refill its pool the instant the new primary accepts connections. Without backoff and jitter, hundreds of simultaneous authentication handshakes hit a cold instance and knock it over again — which is why the marketplace names pooling with bounded reconnection specifically as the mitigation for its 60–120 s failover window.
- **Readiness, not liveness.** Pods should report not-ready so traffic stops; they must not be restarted, or the fleet comes back cold precisely when the database returns.
- **What still works.** Catalog browse in the marketplace survives on the replica and the cache — a Redis-served listing detail needs no primary at all. Check-ins in the cancer platform are already durable on the broker before the record write, so the patient sees "recorded" and the projection catches up: recovery point objective zero for accepted check-ins, by design.
- **What deliberately does not.** The cancer platform serves **no** cached fallback for a patient timeline, because every read of patient data writes an audit row and a read that cannot be audited must not be served. Reads and writes both return `503` during failover. That is the stated price of synchronous audit, taken knowingly, and it fits the budget at a ~60 s failover — roughly 2% of forty-three minutes.
- **Queued work waits rather than fails.** Consumers back off and retry; messages stay on the broker; reminders stay `pending` in the database and are re-swept. Late, not lost.

**At 30 minutes — different in kind, not degree.**

- **The budget is spent.** Thirty minutes is 70% of a 99.9% monthly allowance. This is a declared incident with a status page, not a blip.
- **Backlogs become their own problem.** Queue depth climbs for half an hour. A broker under memory pressure applies flow control to publishers, and that pressure propagates back into services that were otherwise healthy — the failure mode where a backlog takes down components the original outage never touched.
- **Shed, don't retry.** Retry budgets should be driving attempts toward zero by now; breakers should be open. Continuing to retry into a dead database is the metastable pattern, where the retry load keeps the system down after the cause is gone.
- **Degrade explicitly.** Serve what is cached or replicated with a clear staleness indication, put anything that must be durable onto the queue path, and disable features that cannot be served honestly rather than letting them fail slowly.
- **Consider the restore path.** Beyond a failover this becomes a recovery decision against the stated objectives — the marketplace's 15-minute recovery point and 4-hour recovery time, the cancer platform's 5 minutes and 30 minutes. Knowing those numbers, and having rehearsed a point-in-time restore, is what makes the decision take minutes instead of hours.

**The recovery is the risky part, and this is the answer's real payload.** When the database comes back, three things arrive at once: every client's backed-off retries, half an hour of queued work draining at full worker concurrency, and a cold buffer cache serving requests from disk. On top of that the application caches have expired, so the load arriving is both larger and more expensive per request than the steady state — the marketplace's own figure is that a cold cache multiplies database load roughly sixfold. So recovery is deliberate: bring workers back with reduced concurrency and drain the backlog at a rate the database can absorb, admit user traffic behind a rate limit, let the caches warm, then lift. A recovered database killed by its own backlog is a common second outage and an avoidable one.

**Afterwards**, the useful question is not "why did the database fail" — it failed, that is what hardware does — but "which of our reactions made it worse", because those are the ones you can fix.

</details>

