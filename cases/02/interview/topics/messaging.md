# Messaging and Asynchronous Work

> 15 questions on RabbitMQ topology and operations, queue types, publisher confirms, acknowledgements and prefetch, Celery workers, the transactional outbox, and delivery semantics. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except MSG-03, MSG-04, MSG-07, MSG-08, MSG-09, MSG-10, MSG-12, MSG-13 and MSG-14, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — MSG-01, MSG-02, MSG-03, MSG-04, MSG-05, MSG-06, MSG-07, MSG-08, MSG-09, MSG-10, MSG-11, MSG-12, MSG-13, MSG-14, MSG-15
- **retail-software-marketplace** — MSG-01, MSG-02, MSG-03, MSG-04, MSG-07, MSG-13, MSG-14, MSG-15

---

## 1. Delivery semantics and the outbox

---

### MSG-01. Tell me about best practices for handling missing events — how do you stop them, and how do you find out where one went?

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

### MSG-02. Your queue delivers the same message twice. What happens?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
That depends entirely on the consumer, and in both of these systems the answer is "nothing" — by design, because at-least-once delivery is the guarantee we chose and duplicates are therefore normal traffic rather than an incident. Every handler is idempotent against a key in the database, and where that is impossible the duplicate is explicitly tolerated.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it happens, and why it is not a bug to fix.** Consumers acknowledge **after** their work commits — late acknowledgement — so a crash between the work and the acknowledgement produces a redelivery rather than a lost message. That is the trade deliberately taken: at-least-once with duplicates, instead of at-most-once with gaps. Redelivery also follows a visibility-timeout expiry when a handler is merely slow, a broker failover, a consumer rebalance, or a publisher that retried after a lost confirm. "Exactly-once delivery" is not on offer from any broker; what is achievable is exactly-once *effect*, and that is the consumer's job.

**So the handler carries the guarantee.** Four mechanisms, in the order I reach for them:

1. **A natural key with an upsert.** Check-ins are unique on `(patient_id, recorded_for)` and the projection is `INSERT … ON CONFLICT (patient_id, recorded_for) DO UPDATE`. A redelivered message writes the same row. The design says explicitly that this choice was made so a redelivery is arithmetic rather than a bug, and that is the right framing — the correctness lives in the schema, where it cannot be forgotten by the next handler someone writes.
2. **A monotonic guard, which also handles out-of-order.** `indexer-worker` upserts `product_listing_facets` on `product_id` and ignores an event whose `source_revision_id` is older than the row's current value. Deduplication alone would not give you this: two distinct events arriving out of order would leave the listing on the older revision. The version comparison fixes both problems with one predicate, and out-of-order is the failure people forget to test.
3. **A uniqueness constraint on the effect.** `UNIQUE (connection_request_id) WHERE kind = 'connection'` means the second delivery of `connection.requested` cannot produce a second charge, regardless of what the handler does.
4. **A dedupe table on `event_id`**, for handlers with no natural key. The important detail is that the dedupe insert and the side effect must commit **in the same transaction** — otherwise you have moved the race rather than removed it, and a crash between them produces either a lost effect or a duplicate depending on the order.

**Note what is deliberately not the mechanism.** [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency keys exist in the cancer platform and are documented as the *optimisation*, not the guarantee — flushing the cache permits a duplicate to be reprocessed, and the database key is what stops it. An application-side "have I seen this" set that can itself be lost is not a control.

**Where duplicates are accepted rather than eliminated.** Reminder delivery can send twice under a receipt-loss race, and the design takes that deliberately: a patient seeing a reminder twice is a far better failure than not seeing it. Being able to say which duplicates you have chosen to live with, and why that choice is the right way round, is the part that distinguishes a designed system from a hopeful one.

**And the operational side.** A duplicate that a handler cannot absorb ends up in a dead-letter queue rather than being retried forever, and dead-letter count greater than zero is an alert in both designs. A sudden rise in redeliveries usually means handlers have become slow enough to exceed the visibility timeout — the queue is telling you about a latency problem, not a delivery problem, and reading it that way saves a lot of time.

</details>


---

### MSG-03. An endpoint has to write to two stores. How do you handle partial failure?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

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

### MSG-04. The outbox pattern appears all over your designs. What does it actually guarantee, what does it not guarantee, and what does it cost to run?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

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

## 2. RabbitMQ topology and operations

---

### MSG-05. A RabbitMQ cluster loses a node mid-traffic. What actually happens to queues, consumers and unacknowledged messages, and how does that differ between classic, mirrored and quorum queues?

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

### MSG-06. How do you design the exchange and routing-key topology for a multi-tenant fan-out, and what happens to a message that matches no binding?

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

### MSG-07. How do you decide what goes in a message payload and what does not — and why does that decide whether a broker survives a bulk update?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

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

### MSG-08. Explain publisher confirms, consumer acknowledgements and prefetch. Which do you tune first when a backlog is growing?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

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

### MSG-09. Classic queues, quorum queues, lazy behaviour, streams — what would you choose for a continuous high-volume attribute update feed, and why?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

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

### MSG-10. Connection and channel churn on a broker: why does it matter, and what does it look like when it goes wrong?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

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

### MSG-11. The broker hits its memory high-watermark. What does RabbitMQ do to publishers, what does that look like from the application side, and what should the application have been written to do about it?

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

### MSG-12. How would you upgrade a broker cluster that is carrying production traffic?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

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

## 3. Asynchronous jobs and workers

---

### MSG-13. How do you decide between a background task in the web process, a task queue, and a scheduled sweep?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

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

### MSG-14. When would you not use a broker at all?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

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

### MSG-15. Design an asynchronous job system.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Keep the state machine in the database and use the broker only for transport. A job is a row with a state, claimed with `FOR UPDATE SKIP LOCKED`, enqueued transactionally through an outbox, executed by an idempotent handler with late acknowledgement, retried with bounded backoff and then dead-lettered with an alert. That arrangement makes a broker outage produce lateness rather than loss, and makes "was it done?" a query rather than a log search.

<details>
<summary><strong>Detailed answer</strong></summary>

**The organising principle.** The cancer platform states it as a property: reminders stay `pending` in PostgreSQL and are re-swept, so a broker or Function outage makes them **late, not lost**. Everything below follows from putting the state in the database rather than in the queue. A message in flight is invisible, unqueryable and unreportable; a row is none of those things.

**Submission.** The job row and the business change commit together, and the event that hands it to a worker goes through `outbox_event` in the same transaction. There is no window in which the work was requested and nothing knows about it. The submitting [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") returns `202` with a status [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") — the marketplace's `ImportJob { id, status: queued }` and the cancer platform's `{request_id, status_url}` are both this shape — because a client that cannot poll for an outcome will poll you instead.

**Claiming.** Workers take due rows with `SELECT … FOR UPDATE SKIP LOCKED`, flip the state to `dispatching`, and write an attempt row. Skip-locked is what lets the pool scale horizontally with no double-dispatch and no workers blocked behind each other. Every attempt is a **row**, not a log line — which is why "were the reminders delivered" is a query and why the brief's 22% improvement is measurable at all.

**Execution and acknowledgement.** Handlers acknowledge late, after the work commits, so a crash is a redelivery. Therefore every handler is idempotent against a database key, as in the previous question. Durable queues matter here: quorum queues on a three-node [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") cluster with mandatory publisher confirms, because a publish that returns when the frame hits the socket tells you nothing about replication.

**Time limits, so a stuck task is bounded.** Every handler carries a soft limit that raises inside the task so it can clean up, and a hard limit that kills it if it does not. Without both, one task hanging on a slow dependency holds its worker slot indefinitely, and the pool quietly runs one worker short with nothing in the metrics naming why.

**Retries, and then a place to stop.** Exponential backoff with jitter, a hard attempt ceiling, and then a dead-letter queue — with `dead-letter count > 0` as an alert, because a message that exhausted its retries is *somewhere*, and the dead-letter queue is where you read the actual exception. A terminal failure should escalate into the product, not end in a log: a reminder that cannot be delivered raises a care-team flag.

**Isolation, which is where the client's stated pain lives.** A bulk load must not degrade anything else, and three separate mechanisms enforce that:

- **Separate queues per work class** — `celery.reminders`, `celery.content`, `celery.index`; `imports`, `indexing`, `notifications` — with separate worker deployments, so importers scale on import depth and cannot starve the indexer.
- **A per-tenant concurrency cap** — at most four concurrent import chunks per vendor, held as a Redis semaphore, so one vendor cannot occupy the pool.
- **Batching and coalescing.** A completed import emits **one** event and the indexer re-projects in batches of 200, rather than one event and one cache invalidation per row. This is the specific defence against the failure where millions of attribute updates flood a broker: the fix is not a bigger broker, it is not producing one message per row. Prefetch limits and bounded payloads — a reference rather than the document — are the other two halves of keeping broker memory flat under a burst.

**Scheduling.** A singleton scheduler holding a distributed lock, so a restart cannot double-schedule, with a liveness probe on last-tick age. It is a single point of failure by construction, and the mitigation is that its failure delays rather than loses work — again because the due rows live in the database.

**Observability, the four numbers I want before I want a log:** unpublished outbox age, queue depth and unacknowledged count per queue, dead-letter count, and end-to-end lag from `occurred_at` to completion. Each localises a failure to a stage. Queue depth is also the autoscaling signal.

**Shutdown.** Workers are drained, not killed: `preStop` stops consumption and waits for the in-flight task within a bounded grace period, and chunk sizes are chosen to finish well inside it.

**What I verify rather than assume.** Kill a worker mid-task and confirm the work completes after redelivery. Every setting above *claims* durability; that test is the one that checks the claim, it proves late acknowledgement is actually configured rather than believed, and it takes minutes.

**One honest caveat I would raise unprompted.** Celery on Redis does not have real acknowledgement semantics — durability rests on a visibility timeout, and a broker failover can still drop unacknowledged tasks. If the work must be durable, move that queue onto a broker that acknowledges properly, and keep Redis for the work that is fully rebuildable from the outbox. That is a decision to make with a kill-the-worker test in front of you, not from the documentation.

</details>

