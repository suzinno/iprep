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
You stop them by never dual-writing. The outbox row commits in the same transaction as the state change, and a relay publishes it afterwards. So "the change happened but the event did not" is not a state the system can reach. You find a missing one by making every stage of the pipeline a counter you can query: unpublished outbox age, queue depth, dead-letter count and projection lag. You also run a reconciliation job that compares source and projection and re-emits the difference.

<details>
<summary><strong>Detailed answer</strong></summary>

**The first rule is that the event must not be a second write.** The classic loss is a handler that commits to the database and then publishes to the broker. If the process dies between the two, the fact exists and the event does not, and nothing anywhere knows. Both systems in my recent work use a transactional outbox for exactly this reason. In the marketplace, `vendor-service` inserts `outbox_event` in the same [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") transaction that changes `product.current_revision_id`. A relay then publishes to `sb-catalog-events` and sets `published_at`. In the cancer platform the same pattern feeds `care.events`. This outbox pattern is the only mechanism that writes to `es-clinical` or `sb-integration`, and that is exactly why index drift cannot occur there.

**The second rule is that a successful publish does not mean the message was routed.** This is the rule that most often causes problems for people. [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") acknowledges a publish that matches no binding. The broker did its job, but there was simply nowhere to put the message. So a mistyped routing key, a binding lost in a redeploy, or a new tenant publishing on an unbound pattern all produce the same result: a confirmed publish and a discarded message. The fix is an **alternate exchange** on the topic exchange. It diverts unroutable publishes into a queue, and the depth of that queue is a metric and an alert. That turns silent loss into a visible backlog, and that is what matters most.

**The third rule is at-least-once plus idempotency, never exactly-once.** Consumers acknowledge late, after their work commits, so a crash produces a redelivery rather than a gap. That makes duplicates normal, so every handler has to be idempotent. The cheapest place to enforce that is the database. For check-ins, the enforcement is `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE`. For the catalog projection, it is an upsert on `product_id` that ignores an event whose `source_revision_id` is older than the row's current value. The second form also makes out-of-order delivery safe, which redelivery alone does not.

**Finding out where one went.** Before I look at a log, I want four numbers:

1. `outbox_unpublished_age_seconds` — if this is rising, the relay is the problem, and nothing downstream has seen anything.
2. Broker queue depth and unacknowledged count per queue — these separate "nobody is consuming" from "the consumer is slow".
3. Dead-letter count per subscription, with an alert when it is greater than zero. A message that failed its retries is *somewhere*, and the dead-letter queue is where you read the actual exception.
4. Projection lag, measured as `occurred_at` → `projected_at` — in the marketplace that is `indexer_lag_seconds`, with an alert at 60 s. The alert is needed because a dead indexer is otherwise completely silent: listings simply stop becoming searchable, and no error is raised anywhere.

Those four numbers narrow the loss down to a stage. After that, distributed tracing narrows it down to a message. `traceparent` propagates in message headers on every hop, so a single trace spans publish → project → invalidate → notify. Without that link, a failure between a worker and a Function is two unconnected pieces, and each piece shows only half of what happened.

**And the final safeguard, which assumes all of the above failed.** Both designs carry a reconciliation sweep. One is a nightly job that re-projects any `product` whose `projected_at` is more than five minutes earlier than its `updated_at`. The other is a document-count comparison per patient between `pg-clinical` and `es-clinical`, which reindexes the patients whose data has diverged. Monitoring tells you that an event went missing. Reconciliation is what makes the system repair itself (self-heal), without someone writing a one-off script at 2 a.m. I would treat a design with no reconciliation path as incomplete, however good its alerting is.

</details>


---

### MSG-02. Your queue delivers the same message twice. What happens?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
That depends entirely on the consumer. In both of these systems the answer is "nothing", and that is by design. At-least-once delivery is the guarantee we chose, so duplicates are normal traffic, not an incident. Every handler is idempotent against a key in the database. Where that is impossible, the duplicate is explicitly tolerated.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it happens, and why it is not a bug to fix.** Consumers acknowledge **after** their work commits (late acknowledgement). So a crash between the work and the acknowledgement produces a redelivery rather than a lost message. That trade-off was taken deliberately: at-least-once with duplicates, instead of at-most-once with gaps. Redelivery also happens when a handler is only slow. On Celery with Redis, the visibility timeout expires, and the task is redelivered to another worker. On RabbitMQ, the delivery acknowledgement timeout (30 minutes by default) closes the channel, and the broker requeues every unacknowledged delivery on that channel. Redelivery also happens after a broker failover, or when a publisher retried after a lost confirm. No broker offers "exactly-once delivery". What you can achieve is an exactly-once *effect*, and that is the consumer's job.

**So the handler is responsible for the guarantee.** There are four mechanisms, in my order of preference:

1. **A natural key with an upsert.** Check-ins are unique on `(patient_id, recorded_for)`, and the projection is `INSERT … ON CONFLICT (patient_id, recorded_for) DO UPDATE`. A redelivered message writes the same row. The design says explicitly that this choice was made so that a redelivery is just a repeated calculation, not a bug. That is the right way to see it: the correctness is in the schema, where the next handler someone writes cannot forget it.
2. **A monotonic guard, which also handles out-of-order delivery.** `indexer-worker` upserts `product_listing_facets` on `product_id`, and it ignores an event whose `source_revision_id` is older than the row's current value. Deduplication alone would not give you this. Two distinct events that arrive out of order would leave the listing on the older revision. The version comparison fixes both problems with one predicate, and out-of-order delivery is the failure people forget to test.
3. **A uniqueness constraint on the effect.** `UNIQUE (connection_request_id) WHERE kind = 'connection'` means that the second delivery of `connection.requested` cannot produce a second charge. This holds whatever the handler does.
4. **A dedupe table on `event_id`**, for handlers with no natural key. The important detail is that the dedupe insert and the side effect must commit **in the same transaction**. Otherwise you have moved the race, not removed it. A crash between them then produces either a lost effect or a duplicate, depending on the order.

**Note what is deliberately not the mechanism.** [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency keys exist in the cancer platform, and they are documented as the *optimisation*, not the guarantee. Flushing the cache allows a duplicate to be reprocessed, and the database key is what stops it. An application-side "have I seen this" set that can itself be lost is not a control.

**Where duplicates are accepted rather than eliminated.** Reminder delivery can send a reminder twice when a receipt is lost in a race. The design accepts that deliberately, because a patient seeing a reminder twice is a far better failure than not seeing it. Being able to say which duplicates you have chosen to live with, and why that choice is better than the reverse, is what separates a designed system from one that only hopes.

**And the operational side.** A duplicate that a handler cannot handle safely ends up in a dead-letter queue, instead of being retried forever. A dead-letter count greater than zero is an alert in both designs. A sudden rise in redeliveries usually means that handlers have become slow enough to exceed the visibility timeout on Celery with Redis, or the delivery acknowledgement timeout on RabbitMQ. In that case the queue is telling you about a latency problem, not a delivery problem, and reading it that way saves a lot of time.

</details>


---

### MSG-03. An endpoint has to write to two stores. How do you handle partial failure?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Never with two writes in one request, hoping both succeed. One store owns the fact, and that store is written transactionally. Everything else is driven from that write through an outbox. So a failure leaves an unpublished row that drains on recovery, not a fact that only half happened.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the obvious approach fails.** The obvious approach is to write to the database, then publish an event, then update the cache. If the process dies between the first and the second step, the fact exists and nothing downstream knows. If the publish succeeds and the commit rolls back, downstream knows about something that never happened. No ordering of two independent writes is safe, and the failure is silent in both directions.

**The transactional outbox.** The fact and a row that describes the event it should produce are written in one transaction, so they cannot disagree. A relay reads unpublished rows, publishes them, and only then marks them published. If the broker is unavailable, rows build up and drain on recovery. If the relay dies after publishing but before marking, the event is delivered twice. That is why every consumer is idempotent, and why at-least-once is the honest guarantee, not exactly-once.

**Ordering when two stores really are both written.** On the marketplace, a listing publish first writes the immutable revision document to the document store. Then, in one relational transaction, it updates the current-revision pointer and inserts the outbox row. The order is deliberate. An orphaned revision that nothing points at is invisible and can be reclaimed. A committed pointer to a missing document is a broken listing. The general rule is to write the referenced thing before the reference, so a failure leaves garbage, not a dangling pointer.

**What makes the whole arrangement work.** There is one owning store per fact, and every derived store (the search index, the projection, every cache) can be rebuilt from it. That is what makes the recovery procedures real, not just intentions. It is also why the index is never written from a request handler: having a single writer is what makes drift impossible, not just unlikely.

**The monitoring it requires.** The age of the oldest unpublished row, with an alert on it. Otherwise a stalled relay is completely silent: every request succeeds, latency is flat, and everything downstream just stops updating.

**And what I would not use.** A distributed transaction across two heterogeneous stores. Its coordination cost and its failure modes are worse than the problem. The outbox gives you the property that actually matters, which is no fact without its event. And its mechanisms fail in ways you can reason about.

</details>


---

### MSG-04. The outbox pattern appears all over your designs. What does it actually guarantee, what does it not guarantee, and what does it cost to run?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It guarantees that a state change and the intent to publish it commit or fail together. That removes the dual-write failure entirely. It does not guarantee exactly-once delivery, global ordering, or that any consumer succeeded. It only guarantees that the event will eventually be published at least once. Its costs are an extra write per business write, a relay to operate and monitor, a table that grows without limit unless you prune it, and seconds of lag.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it guarantees, precisely.** The outbox row is inserted in the same transaction as the state change. So there is no window in which the fact exists and the intent to publish it does not. That is the whole guarantee, and it is narrow. It is a statement about *durability of intent*, not about delivery. A relay then reads unpublished rows, publishes them, and marks them published. Publication is a separate step that can be retried, so delivery is at-least-once and never zero-times.

**What it does not guarantee, which is the more useful half.**

- **Not exactly-once.** The relay can publish and then crash before marking the row, so the same event goes out twice. Consumers must be idempotent against a natural key in the system of record, not against an in-memory set. In the marketplace, the projection worker upserts keyed on the product, and it ignores an event whose source revision is older than the row's current value. That makes both redelivery *and* out-of-order delivery no-ops.
- **Not globally ordered, and this is where the subtle bug is.** A relay that polls `WHERE id > :watermark ORDER BY id` looks correct, but it is not. Identifiers are assigned when a row is inserted, but rows become *visible* when their transaction commits. Two concurrent transactions can commit in the opposite order to their identifiers. If a relay has already moved its watermark past the higher id, it will never see the lower one when that row commits a moment later. The event is silently lost forever. The defence both these designs use is to avoid a watermark entirely. The relay's only query is a partial index on `WHERE published_at IS NULL`. So a row that becomes visible late is still picked up on the next sweep, whatever its identifier. If you do need a watermark, it has to lag behind the oldest in-flight transaction, not behind the highest identifier.
- **Ordering is at best per-aggregate**, and only if you arrange it: one consumer per aggregate key, or a routing key that keeps an aggregate's events on one queue. With competing consumers on a shared queue, two events for the same entity can be processed concurrently and out of order. Designing handlers to be order-independent is cheaper than enforcing order, and that is why the ignore-if-older comparison exists.
- **Not delivery, and not success.** A published event says nothing about whether a consumer has applied it. That is a separate concern with its own metric: projection lag, measured from event time to projection time.
- **Not freshness.** There is a relay interval, plus a broker hop, plus consumer processing, and the result is seconds. If a reader cannot tolerate that, the answer is to read the source of truth directly, not to tune the relay. That is exactly what the vendor workspace does.

**Running the relay.** Poll on the partial index. Claim rows with `FOR UPDATE SKIP LOCKED`, so several relay instances can run without double-publishing or blocking each other. Publish in batches, then mark the rows published. Publisher confirms are mandatory. Without them, the relay marks a row published when the frame hit the socket, and that brings back the loss the pattern exists to prevent. The relay also needs its own liveness signal. A stopped relay is completely silent, so the alert is on `outbox_unpublished_age_seconds`, not on an error rate.

**What it costs, stated plainly.**

- **An extra write on every business transaction.** This is real write amplification on a hot path, and it shows up in write-ahead log volume as well as in latency.
- **Unbounded table growth.** Published rows have to be pruned or partitioned. A common outcome is a forgotten outbox table that quietly becomes the largest thing in the database. The retention decision is part of the pattern, not an afterthought.
- **A component to operate.** The relay is a thing that can be down, and without instrumentation its failure is invisible.
- **Lag, and therefore a lag budget.** That budget then has to be stated and defended. In the cancer platform, the search freshness budget is calculated as relay plus bulk flush plus refresh interval. It is calculated that way precisely because tightening only one of them gains nothing.
- **Discipline.** Every writer has to remember to write the outbox row. A developer who writes state and publishes directly has bypassed the whole mechanism, and nothing raises an error. That is a code-review and lint concern, and it is the pattern's real weakness.

**The alternative worth naming: Change Data Capture ([CDC](https://en.wikipedia.org/wiki/Change_data_capture "Streams row-level changes out of a database by reading its transaction log")).** Read the write-ahead log directly and derive events from row changes. It removes the extra write, removes the growth problem, and removes the discipline problem entirely. Nothing can bypass it, because it observes the log instead of trusting the application. CDC has its own costs. First, there is a connector to operate. Second, there is a replication slot that retains write-ahead log if the consumer stalls. By default a slot can retain an unlimited amount of write-ahead log. So it can fill the primary's disk and take the database down, which is a truly dangerous failure mode. Setting `max_slot_wal_keep_size` caps what a slot retains. But then a slot that falls too far behind loses the write-ahead log it needs, and the consumer can no longer continue from that slot. Third, events are shaped like table rows, not like curated domain facts, and that couples every consumer to your schema. My default is the outbox, because a hand-written event is a published contract, and a row diff is an implementation detail that leaks out. I would move to CDC when the number of writers makes the discipline impossible to enforce. On the same day, I would make replication-slot lag a paging alert.

</details>

---

## 2. RabbitMQ topology and operations

---

### MSG-05. A RabbitMQ cluster loses a node mid-traffic. What actually happens to queues, consumers and unacknowledged messages, and how does that differ between classic, mirrored and quorum queues?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
A classic queue lives on one node. So if that node is lost, the queue and everything in it are unavailable until the node returns. A quorum queue replicates through Raft across a majority. So a confirmed publish survives the loss, and a new leader is elected in seconds. Unacknowledged messages are requeued and redelivered as long as their queue is still available, and that is exactly why every consumer has to be idempotent. On a classic queue whose node was lost, unacknowledged messages come back only when the node returns, and only if they are persistent messages in a durable queue. Classic mirrored queues are gone, because they were removed in RabbitMQ 4. So quorum queues are not one option among several. They are the supported option.

<details>
<summary><strong>Detailed answer</strong></summary>

**What happens, by queue type.**

*Classic (non-replicated).* The queue is hosted on exactly one node. If that node dies, the queue is unavailable. Persistent messages in a durable queue survive on disk and come back when the node does, but transient messages do not. Consumers connected to other nodes get a consumer cancel notification, if their client supports it, and consumers connected to the failed node lose their connection. Publishers that target the queue fail, or worse, publish into an exchange whose binding leads nowhere. This is the mode that contradicts any claim that an acknowledgement means the data is safe.

*Classic mirrored.* This was the historical answer: a leader plus mirrors, with promotion on failure. It had real problems. In particular, there was the risk of confirming a publish that an unsynchronised mirror did not hold, and the expensive resynchronisation when a mirror rejoined. **It was removed in RabbitMQ 4**, and part of the answer is being able to say that, instead of describing it as a live option.

*Quorum.* A quorum queue is a Raft consensus group across an odd number of members. Here there are three, which matches the cluster. A publish is confirmed only once a majority has it on disk. If one of three members is lost, a majority remains, so the queue stays available. A new leader is elected in seconds, and consumers reconnect and continue. If two of three are lost, quorum is lost. The queue then becomes unavailable for both publishing and consuming until a majority is back, instead of losing data. It refuses instead of diverging, and that is the correct failure for a clinical check-in. If two of three members are lost permanently, the queue has to be force-deleted and recreated.

**Unacknowledged messages, which is the part that surprises people.** A message that was delivered but not acknowledged is not gone. When the consumer's channel dies with the node, the broker requeues the message and delivers it to another consumer, as long as the queue itself is still available. So a node loss produces a burst of redeliveries, and the duplicate is *normal*, not exceptional. That is why the design's dedupe is in the database. A redelivered check-in is `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE`, so it is just a repeated calculation, not a bug. The dedupe is not in an in-memory set, which would have died with the node.

**What the application must have been written to do.**

- **Publisher confirms, mandatory.** Without them, `publish()` returns as soon as the frame is written to the socket, and that says nothing about replication. With them, the publisher retries unconfirmed publishes.
- **Late acknowledgement.** Acknowledge after the work commits, not on receipt, so a crash produces a redelivery rather than a gap.
- **Connection recovery with jitter.** If every client reconnects to the surviving nodes at the same time, that is a thundering herd on a cluster that has just lost a third of its capacity.
- **Idempotent handlers against a natural key.** This is not optional, as above.
- **Bounded prefetch.** A large prefetch means more messages in flight to redeliver, and more memory held on the surviving nodes.

**Where this is felt at the edges of this system.** Patient check-ins arrive over Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")) with Quality of Service ([QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")) 1. So the phone holds the message until it gets a broker acknowledgement, and with a persistent session it resends the message when it reconnects. With that session, a node loss becomes a slightly later check-in, not a lost one. That is the whole reason the ingest path can claim a Recovery Point Objective ([RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Maximum acceptable amount of data loss, measured in time since the last recovery point")) of zero from the moment of acknowledgement. And that claim only holds because the queue behind it is replicated.

**The costs, which I would state before anyone asks.** Quorum queues use more memory and disk than classic ones, and every publish pays for a majority round trip. They also do not support some legacy features in the same way. In particular, this applies to per-message priority. On a quorum queue, RabbitMQ 4.0 to 4.2 offer only two priority levels, normal and high, and RabbitMQ 4.3 replaces them with 32 strict levels. There is also a specific risk worth naming. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle")'s support for quorum queues is relatively recent, and it interacts with `task_acks_late`, global prefetch and priority settings. So the Celery and broker versions have to be pinned and integration-tested together. The documented fallback is raw Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")) consumers for the reminder queue, and the topic-exchange design already allows for that. The point is that the risky dependency has a way out, instead of being assumed to work.

</details>


---

### MSG-06. How do you design the exchange and routing-key topology for a multi-tenant fan-out, and what happens to a message that matches no binding?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Use a topic exchange with a hierarchical routing key, ordered from most stable to most specific. Give each consumer its own queue with its own binding pattern, so adding a consumer never touches the publisher. A message that matches no binding is **silently discarded**, and the broker acknowledges it. The only defence is an alternate exchange. It diverts unroutable publishes somewhere visible, and it turns silent loss into a queue depth you can alert on.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why a topic exchange rather than a queue per consumer.** In AMQP, a publisher never writes to a queue. It writes to an exchange, and bindings decide where copies land. A direct exchange matches the routing key exactly. A fanout exchange ignores it. A topic exchange matches wildcard patterns (`*` for one word, `#` for zero or more). This matters because of coupling. When a visit note is created, the search projection worker needs to know, and so does the timeline cache invalidator. Next quarter, something else will need to know too. If the publisher enqueued directly to named queues, adding the third consumer would mean editing and redeploying the module that owns the clinical record. That module is the highest-risk deployable in the system, and you would change it to satisfy a downstream feature. With a topic exchange, the new consumer declares its own queue and binds its pattern, and the publisher never changes.

**Designing the routing key.** Order the segments from most stable to most specific. The reason is that binding patterns work well with prefixes, and the leading segments are the ones consumers will filter on for years. The shape here is `{domain}.{entity}.{event}`: `checkin.recorded`, `visitnote.created`, `appointment.scheduled`, `carerelationship.changed`. The device ingress path adds a tenant-like segment, `care.checkin.{patient_id}`.

**On putting the tenant in the routing key.** It is the right call when consumers have a valid need for per-tenant subscriptions. It is the wrong call when it produces unbounded binding cardinality. A binding per tenant across thousands of tenants is a real operational cost. Every binding is metadata that the cluster has to store and keep on every node, and the topology becomes something nobody can reason about. My default is this. The tenant goes in the routing key, so a consumer *can* filter on it. But consumers bind broadly (`care.checkin.#`) and filter in the handler. Per-tenant bindings are kept for the small number of cases that really need physical isolation: a tenant with a separate retention obligation, or a tenant whose volume must not share a queue with everyone else's. Isolation by queue is a decision to take deliberately for named tenants, not a default for all of them.

**One more topology rule this design follows.** Celery queues and the domain-event exchange are kept separate on purpose. Celery models *work we schedule and retry for ourselves*, and a topic exchange models *facts we publish for others*. Merging them makes every consumer a Celery task, and it couples independent services to one task registry. That boundary is stated once and respected, and that is worth more than any single naming convention.

**A message matching no binding.** This is the important half of the question. RabbitMQ accepts the publish and discards the message. Critically, it also returns a publisher confirm, and over MQTT it returns a [PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message") for a QoS 1 publish. Over MQTT 5, that PUBACK carries the reason code "No matching subscribers", but the device only learns about the loss if it checks that code. Over MQTT 3.1.1, the PUBACK carries no reason code at all. From the protocol's point of view, the broker did accept the message, but there was simply nowhere to route it. So a mistyped topic, a new patient cohort publishing on an unbound pattern, or a binding lost in a redeploy all have the same result. The device is told that the check-in is safe, and the message never existed. **Nothing errors.** The queue depth downstream simply stays flat, while users see "recorded" in the application.

The defences, in order:

1. **An alternate exchange on the topic exchange.** Unroutable publishes are re-published to the alternate exchange and land in the queue bound to it, and the depth of that queue is a metric and an alert. This turns silent loss into a visible backlog, and it is the single most important setting on the exchange.
2. **The `mandatory` flag** with a return listener, if the publisher needs to know synchronously. The alternate exchange is the system-wide answer, and `mandatory` is the per-publish answer.
3. **Assert the topology in integration tests.** Bindings are configuration, and configuration with no test is only a convention. A test that publishes and asserts that a consumer received the message catches the mistyped pattern. Checking the management interface by eye does not.
4. **Declare bindings in code or infrastructure-as-code**, never by hand, so a redeploy cannot lose one.

**The specific trap in this system, which I would mention without being asked.** MQTT topics are separated by slashes, and AMQP routing keys are separated by dots. The plugin translates between them: `care/checkin/{patient_id}` arrives as the routing key `care.checkin.{patient_id}`. A consumer binding written in MQTT terms, `care/checkin/#`, matches nothing at all, and there is no error. On top of that, the plugin publishes to `amq.topic` by default, not to the exchange the rest of the platform consumes. If you leave that at the default, every check-in is published successfully, acknowledged to the device, and consumed by nobody. The reliability claim on that path depends on two settings that are not defaults, and on one fixed translation. That is the general lesson: **an acknowledgement is a statement about the broker's obligations, not about your application's**. Closing the gap between "accepted" and "a consumer will see it" is your job.

</details>


---

### MSG-07. How do you decide what goes in a message payload and what does not — and why does that decide whether a broker survives a bulk update?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A message carries the identity of what changed, the revision, and the routing information. It does not carry the changed object. Broker memory is message size multiplied by backlog depth. So payload size is one of only two factors you control, and it is the one that costs nothing to fix.

<details>
<summary><strong>Detailed answer</strong></summary>

**The rule: reference, not content.** An event says "product 4471 revision 19 was published", and the consumer reads the current revision from the store that owns it. The event does not carry the product document. There are four reasons, and memory is only the first:

- **Size times depth is the memory cost.** A five-kilobyte payload with a two-million-message backlog is ten gigabytes that the broker has to hold or page. A two-hundred-byte payload is four hundred megabytes. The backlog is the same, but the outcome is completely different. This is the difference between a broker that degrades and a broker that hits its high watermark and blocks every publisher.
- **A large payload is stale by the time it is consumed.** If the object changed twice while the message was queued, a message that carries content applies an old state. A message that carries a reference reads the current state, so it is naturally correct.
- **Redelivery and out-of-order delivery become manageable.** When the message carries the source revision, the consumer can ignore an event older than what it has already projected. That makes redelivery a no-op, and it stops out-of-order delivery from moving a record back to an older state.
- **The broker stops being a data store.** Once payloads carry content, people start reading the queue for data. Then there is a copy of the truth with no query interface and no backup.

**What does go in.** The entity identifier and kind, the revision or a version counter, the event name, an occurrence timestamp, a correlation identifier and the trace context. That is small and fixed, and it is enough for every consumer to decide whether it cares and to fetch what it needs.

**The exception, stated.** Sometimes a consumer really cannot read the source: a message crosses a boundary to a system with no access to our store. Then content has to travel. In that case the content is bounded explicitly, and anything large goes to object storage, with the message carrying the reference. A message is not the place for a document.

**The second factor, since I said there were two.** The second factor is backlog depth. Backlog depth is controlled by consumer prefetch, by whether the queue pages to disk, by message expiry with a dead-letter destination, and by scaling consumers on queue depth rather than on processor use. But payload size is the one you fix once, in the schema, and never think about again. That makes it the cheapest control in the set.

**And the bulk-update case specifically.** A twenty-thousand-row import that emits one message per row is twenty thousand messages, twenty thousand cache invalidations and twenty thousand projection writes. One completion event, with the consumer re-projecting the affected rows in batches, is one message. The payload rule and the granularity rule are the same decision, seen from two sides.

</details>


---

### MSG-08. Explain publisher confirms, consumer acknowledgements and prefetch. Which do you tune first when a backlog is growing?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Confirms protect the publisher's claim that a message is safe. Acknowledgements protect the consumer's claim that the message was handled. Prefetch limits how much a consumer holds at once. When a backlog grows, prefetch is the first thing I look at, because it is the usual cause of a consumer running out of memory.

<details>
<summary><strong>Detailed answer</strong></summary>

**Publisher confirms.** Without them, publishing is fire-and-forget. The broker may have accepted the message, or it may have died, and the publisher cannot tell. With confirms, the broker acknowledges once the message is durable. On a replicated queue, that means once the message is replicated. That is what makes a zero recovery-point claim meaningful. It is also why the check-in path can tell the patient's device "recorded" the moment the confirm arrives.

The trap that comes with it: a publish that routes to no queue is still confirmed. The broker did its job, but there was simply nowhere to put the message. So an exchange that carries a durability guarantee needs an alternate exchange. Otherwise an unbound routing key is acknowledged to the publisher and silently discarded. That is the exact loss the path exists to prevent, and the mechanism meant to prevent it makes the loss invisible.

**Consumer acknowledgements.** With automatic acknowledgement, the message counts as delivered when it leaves the broker, so a worker that crashes mid-task loses it. With manual acknowledgement after the work completes, a crash causes redelivery instead. Redelivery then requires idempotent handlers. The durable version of that is a natural key in the database: an upsert on a unique constraint makes a redelivered check-in just a repeated calculation, not a bug. Deduplication in a cache is an optimisation. The constraint is the guarantee.

**Prefetch.** Prefetch is how many unacknowledged messages the broker will push to one consumer. Unlimited prefetch is the default in some clients. It means that a consumer with a large backlog available will pull as much as it can into memory. That is the classic out-of-memory failure on the consumer side. Unlimited prefetch also destroys load balancing, because one worker takes the backlog while the other workers sit idle. A small prefetch is almost always right: in the low tens for ordinary work, and often one for long tasks.

**The order I tune.** Prefetch first, because it is the usual cause of both the memory symptom and the uneven distribution, and it is a one-line change. Then acknowledgement mode, to find out whether the backlog is real work or redelivery churn from tasks that crash and come back. Then consumer concurrency and replica count, scaled on queue depth rather than processor use. A worker blocked on input/output shows low processor use while the queue grows. So a processor-based autoscaler does nothing during exactly the event it exists for. Adding consumers first, before you understand the shape of the problem, often makes it worse, because it multiplies the pressure on whatever the consumers are waiting on.

</details>


---

### MSG-09. Classic queues, quorum queues, lazy behaviour, streams — what would you choose for a continuous high-volume attribute update feed, and why?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Use quorum queues for anything whose loss matters. That is the default now that classic mirrored queues are gone. For a truly continuous high-volume feed with several independent consumers, a stream is the better fit, because a stream is a replayable log rather than a destructive queue.

<details>
<summary><strong>Detailed answer</strong></summary>

**Quorum queues.** They are replicated with a consensus protocol, durable by design, and the supported answer for high availability in current versions. The cancer platform uses them for the queues bound to the domain event exchange and for the task queues. The trade-offs are real and worth knowing. Write amplification is higher, because every message is replicated. Memory use grows with queue length, whatever the message size, because each quorum queue keeps an in-memory index of at least 32 bytes per message. And poison messages are handled with a delivery limit and a dead-letter, not with infinite redelivery. That last one is a feature: a message that fails forever should leave the queue.

**Classic queues** are still reasonable for truly transient work, where loss is acceptable and throughput matters more than durability. Mirroring them is no longer available, so "classic and reliable" is not a combination you can have.

**Lazy behaviour** means paging messages to disk instead of holding them in memory. It is what stops a growing backlog from becoming a broker memory incident. On quorum queues, this is effectively the normal way of operating, not a separate mode. The general principle is what matters: a backlog is an acceptable state, and it must be paid for in disk, not in memory. If it is paid for in memory, the broker fails, and production fails with it.

**Streams**, and why I would choose one for the described workload. A stream is an append-only log with offset-based consumption and a retention policy. Several consumers read the same messages independently, each at its own position, and reading does not remove anything. For millions of attribute updates flowing continuously, that fits better than a queue in three ways. First, throughput is much higher, because there is no per-message bookkeeping. Second, a slow consumer falls behind, instead of causing the backlog to build up against every consumer. Third, a consumer can be rewound and replayed, and that is exactly what you want when a projection needs rebuilding.

**What a stream costs.** Retention is based on time or size, not on consumption, so you size storage deliberately. Consumers must track offsets. Per-message routing is less flexible. And the semantics are different enough that a stream is not a drop-in replacement for a work queue.

**How I would actually decide.** Work with an owner that must complete once goes on a queue: a quorum queue, with a dead-letter. A continuous fact stream with several independent readers and a need to replay goes on a stream. The mistake I would avoid is using one queue for both, because the requirements conflict. A work queue is designed to forget messages, and a fact log is designed to remember them.

</details>


---

### MSG-10. Connection and channel churn on a broker: why does it matter, and what does it look like when it goes wrong?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Connections and channels are expensive to set up, and they are held on the server side. So opening one per message turns the broker into the bottleneck. It shows up as high broker processor use with low message throughput. It often also shows up as file-descriptor exhaustion, which is a resource problem that looks nothing like a messaging problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**The model.** A connection is a long-lived transport connection. It is authenticated once, and it has a real setup cost, including the security handshake. Channels are lightweight multiplexed sessions inside a connection. The intended shape is a small number of long-lived connections per process, with a channel per thread or per consumer.

**The anti-pattern.** Code that opens a connection, publishes one message and closes it. It works perfectly in development and at low volume. At a thousand messages a second, it is a thousand handshakes a second. The broker spends its capacity on connection setup. Every connection also uses a file descriptor and memory, until the operating system refuses more.

**What the symptoms look like**, and why they mislead:

- Broker processor use is high while message rates are normal. The work is not messaging.
- Connection count climbs steadily and never drops. That usually means connections are not being closed on error paths.
- File descriptor or socket exhaustion, which appears as connection refusals that look like a network fault.
- Latency spikes that line up with deploys, because a rolling restart reconnects everything at once. The broker then handles a thundering herd of handshakes.
- On the client side, timeouts that go away on retry, which sends people to look at the network.

**What I do about it.**

- **One long-lived connection per process, channels per unit of concurrency**, with a pool instead of creating one per call. Publisher and consumer connections are kept separate. The reason is that the broker's flow control blocks publishers, and you do not want that to stall consumers on the same connection.
- **Heartbeats configured deliberately**, so that a connection dropped by an intermediary is detected, instead of staying half-open. Half-open connections are worse than closed ones, because they use broker resources and the client thinks it is fine.
- **Reconnection with backoff and jitter.** Without jitter, a broker restart brings every client back at the same time, and the reconnect storm is an outage of its own.
- **Monitor connection and channel counts as first-class metrics**, with an alert on a rising trend. A count that only grows is a leak, and it is invisible until the limit is hit.

**One more issue that is specific to a long-lived connection.** The broker authenticates a connection, not each publish. So a long-lived mobile client connection needs a maximum lifetime that is shorter than the credential's validity window, and it must be forced to reconnect. Otherwise an expired credential can keep publishing on that connection, unless the credential is a token and the broker itself checks its expiry for that protocol.

</details>


---

### MSG-11. The broker hits its memory high-watermark. What does RabbitMQ do to publishers, what does that look like from the application side, and what should the application have been written to do about it?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
It raises a memory alarm and applies flow control by blocking publishing connections. So a consumer problem shows up as a producer outage. From the application side, that is not an error: the connection simply stops accepting publishes. So request threads build up behind a socket that never returns, and upstream timeouts cascade. The application should have bounded prefetch and batched on both sides. It should also have set an explicit queue overflow policy, so that backpressure is felt as a fast failure instead of being absorbed. And it should have alerted on queue depth long before memory.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** RabbitMQ holds a queue's messages in memory and pages them to disk under pressure. But several things resist paging: messages that are currently delivered but unacknowledged, per-message index metadata that stays in memory even when the body is paged out, and connection and channel buffers. A consumer with a large prefetch and slow handlers can hold tens of thousands of messages in flight per channel, and the broker cannot release any of them. When the total held in memory crosses `vm_memory_high_watermark`, the broker raises an alarm and blocks publishing connections. There is also a disk-space alarm with the same effect. It is worth knowing that both exist, because the symptom is identical.

**What it looks like from the application.** This is the part that makes it hard to diagnose. The publisher does not receive an exception. The connection is *blocked*, and a `basic.publish` simply does not complete. With a synchronous client, the calling thread waits. Under load, every request thread that does a publish waits with it, and the thread pool runs out. Then the service stops serving *every* endpoint, including ones that never touch the broker. Health checks fail, the orchestrator restarts pods, and the new pods immediately block too. The incident looks like a total application outage, but its actual cause is a slow consumer. The AMQP protocol does signal this with `connection.blocked`, and most clients expose a callback for it. Almost nobody registers that callback.

**The workload that brings a broker to this point.** Millions of small attribute updates, published one per attribute, are close to the worst case. Per-message overhead outweighs the payload. The queue index alone becomes enormous. And any consumer that writes to the database one row at a time will never keep up with a publisher that writes in a tight loop. The producer is fast because it is doing nothing. The consumer is slow because it is doing the work. That difference in speed is what fills a broker.

**What the application should have been written to do, in the order I would apply it.**

1. **Bound prefetch.** An unbounded or very high `prefetch_count` is the most common single cause. Set it to a small multiple of what one worker processes at the same time, so that unacknowledged messages cannot become a backlog that cannot be paged.
2. **Batch on both sides.** Publish one message that describes many changes, instead of one message per change, and have the consumer write with a bulk statement. In this platform, the equivalent decision is the search indexer flushing at 1,000 documents or 5 seconds, instead of indexing per document. In the marketplace, it is an import that emits one completion event and re-projects in batches of 200, instead of 20,000 individual events. It is the same shape of fix, twice.
3. **Set queue limits with an explicit overflow policy.** `max-length` or `max-length-bytes` with `overflow: reject-publish` makes the producer feel backpressure directly and fail fast. Without it, the broker absorbs the problem until the broker stops working for everyone. Choosing `reject-publish` over `drop-head` is a domain decision. Dropping the oldest attribute update may be acceptable, but dropping a clinical check-in is not.
4. **Register the `connection.blocked` callback**, and expose it as a metric and as an input to a circuit breaker. Then the application can shed load or fail fast, instead of letting threads build up against a blocked socket.
5. **Publish off the request path.** A publish inside a request handler ties user-facing availability to broker health. The outbox pattern already does this: the request writes a row and commits, and a relay publishes. So a blocked broker produces a growing outbox, not failing requests.
6. **Queues that expect long backlogs cost disk, not RAM.** That means quorum queues with disk-first behaviour, not anything that keeps messages in memory.
7. **Separate the estate.** A high-churn bulk pipeline should not share a broker with the latency-sensitive path. At minimum, it should not share a virtual host and node set with that path. If the two share a broker, or a virtual host and node set, a bulk backlog blocks interactive publishing, and that is how one feature's load becomes every feature's outage.

**Alert on the leading indicator, not the outcome.** The signal is `rmq_queue_depth` and unacknowledged-message count rising for fifteen minutes. The memory alarm is the consequence. The dashboard here alerts on depth above 10,000 or on a sustained rise, precisely so that the page arrives before flow control does. Consumer processing latency per queue and consumer error rate are the two metrics that tell you *why* the depth is rising.

**And the detection I would add, whatever else is in place.** A load test that publishes at a multiple of peak, with consumers deliberately throttled. It is run against a real broker in Docker Compose, not against a mock. That way the flow-control behaviour is observed once in a controlled setting, instead of being discovered in production. A mocked broker cannot block a connection, so it cannot fail the way the real one does. And that is exactly the failure worth rehearsing.

</details>


---

### MSG-12. How would you upgrade a broker cluster that is carrying production traffic?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Read the release notes for that specific version pair, and rehearse the whole upgrade on a copy. Then roll one node at a time, with the cluster staying quorate. Before the roll, you must already have confirmed that every client version in the estate is compatible with both the old and the new broker.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before touching anything.**

- **Read the upgrade notes for the exact version pair**, not the general guidance. Broker upgrades are where features get removed. Classic mirrored queues disappearing is the obvious recent example, and a cluster that relies on them does not upgrade. It migrates.
- **Inventory what the estate actually uses.** Queue types, plugins, policies, exchange types, and every client library version. A plugin that is not available on the new version is a blocker that is discovered at the worst time. The protocol bridge plugins are the ones people forget most often.
- **Check client compatibility in both directions**, because during the roll, clients talk to both versions.
- **Rehearse on a copy** with representative topology and message volume, and rehearse the rollback too. An upgrade path that has not been reversed is a one-way change.

**The roll itself.**

- **One node at a time.** Wait until the cluster is fully healthy and the replicated queues are back to full membership before you touch the next node. Rushing this is how you lose quorum, and losing quorum on a replicated queue is much worse than a slow upgrade.
- **Drain the node first** with `rabbitmq-upgrade drain`. This puts the node into maintenance mode: it stops accepting new client connections, closes the existing ones, and moves quorum queue leaders to other nodes. So clients are disconnected, and they have to reconnect to the other nodes and recover.
- **Watch the right signals during the roll**: queue depth, unacknowledged counts, publish confirm latency, consumer counts and the memory watermark. Do not only watch whether the node came back.
- **Expect and tolerate reconnection.** Clients must reconnect with backoff and jitter, and publishers must handle a confirm that does not arrive. If they do not, the upgrade is blocked until the clients are fixed. That is a legitimate outcome, and it is better to find it in the rehearsal.

**Feature flags, and doing it in two steps.** Where the new version changes a default or offers a new queue type, I would separate the upgrade from the adoption. Upgrade first and verify stability. Then change queue types or settings in a later, separate change. Bundling them means an incident has two possible causes. RabbitMQ's own feature flags follow the same idea. After an upgrade, new feature flags stay disabled, and a flag can be enabled only when every node in the cluster supports it. Feature flags also become mandatory over time. The flags that a new version requires must be enabled before the upgrade, or the upgraded node refuses to start.

**And the honest caveat.** Some upgrades are not rolling. A change that alters the cluster's internal format may need a full stop, and there is no clever way around that. It needs a maintenance window, a tested restore, and publishers that queue at the outbox instead of losing anything. The design already has that property, and that is the point of publishing through an outbox. An unavailable broker leaves unpublished rows that drain on recovery, not facts that never left.

</details>

---

## 3. Asynchronous jobs and workers

---

### MSG-13. How do you decide between a background task in the web process, a task queue, and a scheduled sweep?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It depends on whether losing the work is acceptable. An in-process background task dies with the process and has no retry, so it is only ever right for something truly disposable. Anything the system owes gets a queue. Anything time-based gets a scheduled sweep over durable state.

<details>
<summary><strong>Detailed answer</strong></summary>

**In-process background work.** [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") can run a coroutine after the response is sent. That coroutine shares the process. So it competes for the same event loop, it dies if the pod is rescheduled, and there is no retry, no visibility and no dead-letter. That makes it acceptable for exactly one category: work whose loss is invisible and harmless, such as a best-effort cache warm. I have seen it used for things that matter, such as sending an email or writing an audit row. Every time, it has eventually lost work during a deploy, and the loss was silent.

**A task queue** is the default for anything the platform owns and must complete: imports, indexing, notification decisions, document processing. It gives you retry with a bounded attempt count, a dead-letter destination, workers that scale independently of the web tier, and visibility of the backlog. The cost is a broker and a second deployment shape, and that cost is worth it as soon as the work matters.

**A scheduled sweep over durable state** is the right answer for anything time-based, and it is underrated. Reminders are not queued when they are created. They are rows with a due time. A periodic task claims the due rows with a row-level lock that skips rows already claimed, so several workers can run without double-dispatching. That is more robust than scheduling a delayed message, because the state is in the database, not in the broker. If the broker is rebuilt, nothing is lost. And a bug can be fixed, and the sweep will pick up what it missed.

**The rule.** Work that has an owner and a deadline lives in the database, and the queue moves it. If the only record that something needs doing is a message in flight, then the broker has become a database with no query interface and no backup.

**And the dividing line between the two brokers**, since both systems have two. The task queue moves work between processes we own. The service bus moves events across a boundary to something we do not own. Merging them into one, in either direction, puts one system in a role it is bad at.

</details>


---

### MSG-14. When would you not use a broker at all?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
When the work is time-based rather than event-based, when the volume does not justify a second piece of infrastructure, or when the caller really needs the answer now. A broker between two services that must agree synchronously adds latency and a failure mode, and it gives you nothing in return.

<details>
<summary><strong>Detailed answer</strong></summary>

**Time-based work belongs in the database, not the queue.** Reminders are the example. The instinct is to publish a delayed message when the appointment is created. What that actually does is put the schedule inside the broker. There, the schedule cannot be queried, cannot be corrected in bulk, and disappears if the broker is rebuilt. The durable version is a row with a due time and a state, plus a periodic sweep. The sweep claims due rows with a lock that skips rows already claimed, so several workers run without double-dispatching. Every attempt writes a row, and that turns "was it delivered" into a query instead of a log search. If a bug means a batch went out wrong, the state is in the database and can be fixed.

**Low volume does not justify the infrastructure.** A broker is a component to run, upgrade, monitor, back up and reason about during an incident. For a small number of background jobs a day, a job table with a poller is less machinery and easier to debug. I would rather add the broker when there is a reason than have it because it is the pattern.

**When the caller needs the answer.** Asynchronous messaging cannot make a synchronous requirement disappear. It moves the requirement into a correlation-and-wait pattern, and that pattern is strictly more complicated than a call. When one service must ask another a question to complete a request, the honest design is a bounded synchronous call with a short timeout and a defined behaviour on failure. The marketplace has exactly one such hop, with a 250 millisecond timeout and a deliberate decision to fail open. And the correctness guarantee still comes from a unique constraint in the database, not from the call.

**When ordering across many keys must be strict.** A queue with competing consumers does not preserve global order. Getting order back means one consumer or per-key partitioning. At that point, a log or the database's own sequencing may be the better primitive.

**And where an outbox is enough.** If the only requirement is that a fact reliably reaches one other component, a table written in the same transaction as the fact, plus a relay, provides the durability. The broker is then a transport choice, not the source of the guarantee. That is the correct relationship, and it is what makes a broker outage a delay rather than a loss.

</details>


---

### MSG-15. Design an asynchronous job system.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Keep the state machine in the database, and use the broker only for transport. A job is a row with a state. It is claimed with `FOR UPDATE SKIP LOCKED` and enqueued transactionally through an outbox. An idempotent handler executes it with late acknowledgement. It is retried with bounded backoff, and then dead-lettered with an alert. With that arrangement, a broker outage produces lateness rather than loss, and "was it done?" becomes a query rather than a log search.

<details>
<summary><strong>Detailed answer</strong></summary>

**The organising principle.** The cancer platform states it as a property: reminders stay `pending` in PostgreSQL and are re-swept, so a broker or Function outage makes them **late, not lost**. Everything below follows from putting the state in the database instead of in the queue. A message in flight is invisible, cannot be queried and cannot be reported on. A row is none of those things.

**Submission.** The job row and the business change commit together. The event that hands the job to a worker goes through `outbox_event` in the same transaction. There is no window in which the work was requested and nothing knows about it. The submitting [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") returns `202` with a status [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web"), because a client that cannot poll for an outcome will poll you instead. The marketplace's `ImportJob { id, status: queued }` and the cancer platform's `{request_id, status_url}` both have this shape.

**Claiming.** Workers take due rows with `SELECT … FOR UPDATE SKIP LOCKED`, change the state to `dispatching`, and write an attempt row. Skip-locked is what lets the pool scale horizontally, with no double-dispatch and no workers blocked behind each other. Every attempt is a **row**, not a log line. That is why "were the reminders delivered" is a query, and why the brief's 22% improvement can be measured at all.

**Execution and acknowledgement.** Handlers acknowledge late, after the work commits, so a crash is a redelivery. So every handler is idempotent against a database key, as in the previous question. Durable queues matter here: quorum queues on a three-node [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") cluster, with mandatory publisher confirms. The confirms are mandatory because a publish that returns when the frame hits the socket tells you nothing about replication.

**Time limits, so a stuck task is bounded.** Every handler has a soft limit and a hard limit. The soft limit raises an exception inside the task, so the task can clean up. The hard limit kills the task if it does not clean up. Without both limits, one task that hangs on a slow dependency holds its worker slot indefinitely. The pool then quietly runs one worker short, and nothing in the metrics says why.

**Retries, and then a place to stop.** Exponential backoff with jitter, a hard attempt ceiling, and then a dead-letter queue. `dead-letter count > 0` is an alert, because a message that used up its retries is *somewhere*, and the dead-letter queue is where you read the actual exception. A terminal failure should escalate into the product, not end in a log. For example, a reminder that cannot be delivered raises a care-team flag.

**Isolation, which is where the client's stated problem is.** A bulk load must not degrade anything else, and three separate mechanisms enforce that:

- **Separate queues per work class** — `celery.reminders`, `celery.content`, `celery.index`; `imports`, `indexing`, `notifications` — with separate worker deployments. So importers scale on import depth and cannot starve the indexer.
- **A per-tenant concurrency cap**: at most four concurrent import chunks per vendor, held as a Redis semaphore. So one vendor cannot take over the pool.
- **Batching and coalescing.** A completed import emits **one** event, and the indexer re-projects in batches of 200. The alternative would be one event and one cache invalidation per row. This is the specific defence against the failure where millions of attribute updates overload a broker. The fix is not a bigger broker. The fix is to stop producing one message per row. Prefetch limits and bounded payloads (a reference rather than the document) are the other two parts of keeping broker memory flat under a burst.

**Scheduling.** A singleton scheduler holds a distributed lock, so a restart cannot double-schedule. It has a liveness probe on last-tick age. It is a single point of failure because of how it is built. The mitigation is that its failure delays work instead of losing it, again because the due rows live in the database.

**Observability, the four numbers I want before I want a log:** unpublished outbox age, queue depth and unacknowledged count per queue, dead-letter count, and end-to-end lag from `occurred_at` to completion. Each number narrows a failure down to a stage. Queue depth is also the autoscaling signal.

**Shutdown.** Workers are drained, not killed. `preStop` stops consumption and waits for the in-flight task, within a bounded grace period. Chunk sizes are chosen so that a chunk finishes well inside that period.

**What I verify rather than assume.** Kill a worker mid-task and confirm that the work completes after redelivery. Every setting above *claims* durability, and that test is the one that checks the claim. It proves that late acknowledgement is actually configured, not just believed to be. And it takes minutes.

**One honest caveat I would raise without being asked.** Celery on Redis does not have real acknowledgement semantics. Its durability rests on a visibility timeout, and a broker failover can still drop unacknowledged tasks. If the work must be durable, move that queue onto a broker that acknowledges properly. Keep Redis for the work that can be fully rebuilt from the outbox. Make that decision based on a kill-the-worker test, not on the documentation.

</details>

