# Interview Questions — Personalized Cancer Support Platform

> Auto-generated from [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") and system design documents. Questions target stated responsibilities and technical pillars.
> Weighted toward the client brief in `candidate-profile.txt`.

## Table of Contents

- [Event-Driven Architecture and the Messaging Estate](#event-driven-architecture-and-the-messaging-estate)
- [Database Engineering and SQL at Scale](#database-engineering-and-sql-at-scale)
- [Search and Relevance Engineering](#search-and-relevance-engineering)
- [FastAPI Service Design and Performance Under Load](#fastapi-service-design-and-performance-under-load)
- [Identity, Provisioning, and Access Control](#identity-provisioning-and-access-control)
- [Applied Machine Learning for Clinical Content](#applied-machine-learning-for-clinical-content)
- [Testing and Quality Gates](#testing-and-quality-gates)
- [GitOps Delivery and Observability](#gitops-delivery-and-observability)

---

## Event-Driven Architecture and the Messaging Estate

---

### Q1. What is the difference between a queue and a topic exchange, and why does this platform publish domain events to a RabbitMQ topic exchange rather than pushing them onto a queue per consumer?

**Brief answer**
A queue holds messages for one logical consumer group; a topic exchange is a router that copies a published message into every queue whose binding pattern matches the routing key. `care.events` is a topic exchange because publishing a fact should not require the publisher to know who reacts to it.

<details>
<summary><strong>Detailed answer</strong></summary>

In Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")) terms a publisher never writes to a queue — it writes to an exchange, and bindings decide where the copy lands. A direct exchange matches the routing key exactly, a fanout ignores it, and a topic exchange matches it against wildcard patterns (`*` for one word, `#` for any number). `care.events` is a topic exchange carrying `checkin.recorded`, `visitnote.created`, `appointment.scheduled`, and `carerelationship.changed`.

The reason that matters here is coupling. When a visit note is created, the search projection worker on `celery.index` needs to know, the timeline cache invalidator needs to know, and tomorrow something else will too. If `care-core` enqueued directly to a named queue, adding the third consumer would mean editing the publisher and redeploying the module that owns the clinical record — the highest-risk deployable in the system — to satisfy a downstream feature. With a topic exchange the new consumer declares its own queue, binds `visitnote.*`, and the publisher never changes.

The trade-off is that fan-out makes delivery guarantees per-binding rather than global. A queue bound with a typo receives nothing and reports no error, which is exactly the class of silent failure the alternate exchange on `care.events` exists to catch: an unroutable publish is diverted somewhere visible instead of being accepted and discarded. Binding topology is therefore configuration that has to be asserted in integration tests, not something you eyeball in the management UI.

</details>

---

### Q1. What does at-least-once delivery mean, and what does it force you to build on the consumer side?

**Brief answer**
At-least-once means the broker will redeliver anything it cannot prove was processed, so duplicates are normal rather than exceptional. Every consumer must therefore be idempotent — reprocessing the same message must produce the same end state.

<details>
<summary><strong>Detailed answer</strong></summary>

The guarantee comes from acknowledgement timing. With late acknowledgement, a consumer acknowledges only after its work commits; if it crashes between the database commit and the ack, the broker sees an unacknowledged message and hands it to another consumer. The message was already applied once, so the second delivery is a duplicate. Exactly-once does not exist across a broker and a database without a distributed transaction, and paying for one at this scale would be absurd.

The consequence is that idempotency is a design obligation on every handler, and the cheapest place to enforce it is the database rather than the application. In this platform the check-in projection is `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE` against `diary.wellbeing_checkin`, which carries a unique constraint on that pair. A redelivered check-in becomes an update of the row it already wrote — arithmetic, not a bug. Nothing counts duplicates in Python, and nothing consults a "have I seen this message id" set that could itself be lost.

[Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency keys (`idem:{idempotency_key}`) exist too, but they are explicitly the optimisation and not the guarantee: flushing `redis-cache` permits a duplicate `POST` to be reprocessed, and what makes that safe is the natural key in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") underneath. The rule I apply is that any mutation which must not double-apply needs a natural key or a unique constraint in the system of record; a cache-based dedupe is a latency saving that must never be load-bearing.

The one place duplicates are accepted rather than removed is reminder delivery. A receipt lost between `fn-notify-dispatch` and `celery.reminders` can produce a second send, and a patient seeing a reminder twice is a much better failure than not seeing it at all.

</details>

---

### Q1. What is Message Queuing Telemetry Transport (MQTT) Quality of Service (QoS) 1, and why is it the transport for patient check-ins instead of a plain Hypertext Transfer Protocol Secure (HTTPS) POST?

**Brief answer**
[QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") 1 is at-least-once publish with a broker acknowledgement ([PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message")) and client-side retry, so the phone holds the message until the broker confirms it. It is chosen because a patient on a lossy mobile connection must never lose a check-in they believe they submitted.

<details>
<summary><strong>Detailed answer</strong></summary>

[MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") defines three delivery levels: QoS 0 fires and forgets, QoS 1 retries until a PUBACK arrives, and QoS 2 performs a four-step handshake for exactly-once. QoS 1 is the right level here because the duplicate it can produce is already absorbed by the unique key on `(patient_id, recorded_for)`, and QoS 2's extra round trips buy nothing once the receiving side is idempotent.

The reason it beats an [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit") [POST](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP POST — HTTP method that submits data to a server to create or process a resource") is the client library, not the wire protocol. An MQTT client with a persistent session queues publishes locally while offline and flushes them on reconnect without the application writing retry logic. Patients complete check-ins on hospital wifi, in a lift, on a train — the transport was chosen against that behaviour. With a POST, the equivalent reliability means a client-side outbox, a retry schedule, and a way to survive the app being killed, all reimplemented per platform.

The design keeps a Representational State Transfer ([REST](https://en.wikipedia.org/wiki/REST "Architectural style for stateless, resource-oriented HTTP APIs")) alternative (`POST /api/v1/diary/check-ins` returning `202 Accepted`) for the web client, with identical downstream semantics — both land as a `checkin.recorded` event and both project through the same idempotent write. That symmetry is deliberate: one ingestion path, two front doors, so there is no second copy of the projection logic to drift.

[RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") makes this work by bridging: its MQTT plugin translates the topic `care/checkin/{patient_id}` into the AMQP routing key `care.checkin.{patient_id}` on the same `care.events` exchange, so device traffic and internal events are consumed by the same workers rather than through a separate ingestion service.

</details>

---

### Q1. What is a quorum queue, and why does this design mandate them for `care.events` and every Celery queue?

**Brief answer**
A quorum queue replicates messages across a majority of broker nodes using Raft, so a message acknowledged to a publisher survives the loss of a node. RabbitMQ 4 removed classic mirrored queues, so it is also the only supported replication option.

<details>
<summary><strong>Detailed answer</strong></summary>

A classic queue lives on one node. If that node dies, the queue and everything durable in it is unavailable until it returns, which contradicts the check-in path's claim that a PUBACK means the data is safe. Quorum queues run a Raft consensus group across an odd number of nodes — three, matching the `rmq-core` cluster — and a publish is confirmed only once a majority has it on disk. That is what makes "acknowledged means durable" true rather than aspirational.

Publisher confirms are the other half and are mandatory in this design. Without confirms the client's `publish()` returns as soon as the frame is written to the socket, which says nothing about replication. With confirms plus quorum queues, a confirmed publish has been accepted by a majority; anything unconfirmed is retried by the publisher.

The costs are real and worth stating in an interview. Quorum queues use more memory and disk than classic queues, they do not support some legacy features such as per-message priority in the same way, and every publish pays a majority round trip. There is also a specific risk this design flags: [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle")'s support for quorum queues is comparatively recent and interacts with `task_acks_late`, global prefetch, and priority settings, so the Celery and RabbitMQ versions have to be pinned and integration-tested together. The documented fallback is raw AMQP consumers for `celery.reminders`, which the topic-exchange design already accommodates — the point being that the risky dependency has an exit, not that it is assumed to work.

</details>

---

### Q2. The check-in path claims a Recovery Point Objective (RPO) of zero from the moment the broker acknowledges. Three RabbitMQ settings carry that claim and none of them is a default. What are they, and what breaks without each?

**Brief answer**
The MQTT plugin's `mqtt.exchange` must point at `care.events`, the topic separator translation must be accounted for, and `care.events` needs an alternate exchange. Without the last one RabbitMQ acknowledges a QoS 1 publish that routes nowhere, which is exactly the silent loss the path exists to prevent.

<details>
<summary><strong>Detailed answer</strong></summary>

**`mqtt.exchange`.** By default the RabbitMQ MQTT plugin publishes into `amq.topic`, not into whatever exchange the rest of your platform consumes. Leave it at the default and check-ins are published successfully, acknowledged to the device, and consumed by nobody, because every binding in the system is on `care.events`. Nothing errors. The queue depth on `celery.index` simply stays flat while patients see "recorded" in the app.

**Separator translation.** MQTT topics are slash-separated and AMQP routing keys are dot-separated, and the plugin translates between them. `care/checkin/{patient_id}` arrives as the routing key `care.checkin.{patient_id}`. That matters because the consumer binding has to be written in AMQP terms — a binding on `care/checkin/#` matches nothing. It is the kind of detail that is obvious once and invisible forever after, which is why it belongs in an integration test that publishes over MQTT and asserts an AMQP consumer received it.

**Alternate exchange.** This is the important one. RabbitMQ returns a PUBACK for a QoS 1 publish that matches no binding — from the protocol's point of view the broker did accept the message; there was simply nowhere to route it. So a mistyped topic, a new patient cohort publishing on an unbound pattern, or a binding lost in a redeploy produces a device that is told the check-in is safe and a message that is discarded. Configuring an alternate exchange on `care.events` diverts unroutable publishes into a dead-letter queue where the count is a metric and an alert, converting silent loss into visible backlog.

The general principle I would take to any broker: an acknowledgement is a statement about the broker's obligations, not about your application's. You have to close the gap between "the broker accepted it" and "a consumer will see it" yourself, and the closing mechanism is the one you should be able to name.

</details>

---

### Q2. A system pushes millions of attribute updates through RabbitMQ and has taken production down with broker memory overloads. Walk me through how a broker runs out of memory, and what you would change.

**Brief answer**
Broker memory grows when publish rate exceeds consume rate, because unconsumed messages, unacknowledged deliveries, and per-connection buffers all accumulate. RabbitMQ then trips its memory alarm and blocks publishers, so a consumer problem surfaces as a producer outage.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** RabbitMQ holds a queue's messages in memory and pages them to disk under pressure, but several things resist paging: messages currently delivered-but-unacknowledged, message metadata (an index entry per message stays resident even when the body is paged), and connection and channel buffers. A consumer with a large prefetch and slow handlers can hold tens of thousands of messages in flight per channel, none of which the broker may release. When the resident total crosses `vm_memory_high_watermark` the broker raises a memory alarm and applies flow control by blocking publishing connections. Producers stall, their request threads pile up, upstream timeouts cascade, and what began as a lag problem is now an availability incident.

**The specific bulk-update shape.** Millions of attribute updates arriving as millions of tiny messages is close to the worst case: per-message overhead dominates the payload, the queue index alone becomes enormous, and if any consumer is doing a row-at-a-time database write it will never keep up with a publisher writing in a tight loop.

**What I would change, in the order I would try it.**

1. **Bound prefetch.** An unbounded or very high `prefetch_count` is the most common single cause. Set it to a small multiple of what one worker can process concurrently, so unacknowledged messages cannot become an unpaged backlog.
2. **Batch on both sides.** Publish one message describing many attribute changes rather than one per attribute, and have the consumer write with a bulk statement. In this platform the equivalent decision is the `es-clinical` bulk indexer flushing at 1000 documents or 5 seconds rather than indexing per document — the same shape of fix.
3. **Set queue limits with an explicit overflow policy.** `max-length` or `max-length-bytes` with `overflow: reject-publish` makes the producer feel backpressure directly and fail fast, instead of letting the broker absorb the problem until it takes everyone down. Choosing to reject rather than drop-head is a domain decision: dropping the oldest attribute update may be acceptable, dropping a clinical check-in is not.
4. **Lazy or quorum queues with disk-first behaviour** for anything expected to build a long backlog, so depth costs disk rather than RAM.
5. **Separate the estate.** A high-churn bulk pipeline should not share a broker, or at least not a virtual host and node set, with the latency-sensitive path. Colocating them means a bulk backlog blocks interactive publishing.
6. **Alert on the leading indicator.** `rmq_queue_depth` and unacked-message count rising for fifteen minutes is the signal; memory alarm is the outcome. The dashboard in this platform alerts on depth above 10K or a sustained rise precisely so that the page arrives before flow control does.

**And the detection I would add regardless:** a load test that publishes at a multiple of peak with consumers deliberately throttled, run against the real broker in Docker Compose rather than a mock, so the flow-control behaviour is observed once in a controlled setting rather than discovered in production.

</details>

---

### Q2. Celery and raw AMQP consumers both exist in this design. Where is the boundary, and what goes wrong if you collapse them into one?

**Brief answer**
Celery models work the platform owns and must retry — reminder sweeps, page generation, index projection. The `care.events` topic exchange models facts the platform publishes for anyone to react to. Collapsing them couples every consumer to one task registry.

<details>
<summary><strong>Detailed answer</strong></summary>

The distinction is about who owns the outcome. A Celery task has an owner, a deadline, a retry policy, and a result: `celery.reminders` sweeps for due reminders every sixty seconds and is responsible for each one reaching a terminal state. An event on `care.events` is a statement that something happened — `visitnote.created` — and the publisher has no opinion about who consumes it or what they do.

If you make everything a Celery task, three things degrade. First, the publisher must name the task, which means it must know the consumer; adding a subscriber becomes a change to `care-core`. Second, every consumer must share the task registry and therefore the same code base and deployment, which is exactly the coupling the modular monolith is trying to bound. Third, fan-out becomes explicit: publishing one fact to three consumers means enqueuing three tasks, and if the second enqueue fails you have partially published a fact — a distributed-consistency problem invented by the transport choice.

Collapsing the other way — dropping Celery and consuming raw AMQP everywhere — costs you scheduling and retry semantics you would then rebuild. Celery beat drives the reminder window, `autoretry_for` with exponential backoff handles a transient provider failure, and dead-lettering after bounded retries is configuration rather than code.

They coexist cleanly because they share one broker, `rmq-core`, but not one abstraction: Celery uses it as a task transport on `celery.reminders`, `celery.content`, and `celery.index`, while `care.events` is a genuine pub/sub topology alongside. The rule I would state in a design review is that the choice follows the sentence you would write in the log: "I must do X" is Celery, "X happened" is an event.

</details>

---

### Q2. Walk me through the reminder delivery path. Which specific mechanisms turn "did the reminder arrive" from a log grep into a query?

**Brief answer**
A `reminder` row holds the state machine and a `reminder_delivery` row is written per attempt, with channel, provider message id, and terminal state. Because every attempt is a row in PostgreSQL, missed-reminder reporting is [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") over the delivery table.

<details>
<summary><strong>Detailed answer</strong></summary>

The path: Celery beat ticks every sixty seconds; a `celery.reminders` worker selects reminders due within the next two minutes with `SELECT ... FOR UPDATE SKIP LOCKED`, moves them to `dispatching` and writes a `reminder_delivery` attempt row; the command is enqueued to `sb.notify` on Azure Service Bus keyed by `reminder_delivery_id`; `fn-notify-dispatch` delivers over push, email, or Short Message Service ([SMS](https://en.wikipedia.org/wiki/SMS "Delivers short text messages over a mobile network")) and enqueues the provider receipt; a worker consumes the receipt and sets the attempt to `delivered` or `failed`. A terminal failure retries with backoff, then tries an alternate channel, then raises a flag to the care team.

Three properties make the 22% reduction in missed reminders a measurable claim rather than a hope:

**`FOR UPDATE SKIP LOCKED` on the claim.** Multiple workers sweep the same window concurrently; each locks the rows it takes and skips rows another worker holds. Without it you either serialise the sweep behind one worker or double-dispatch. It also means adding workers is a scaling knob with no coordination service behind it.

**One row per attempt.** The temptation is to keep `attempts_count` on the reminder and log the rest. Then "how many reminders failed on SMS last month, and did the fallback channel work" is unanswerable without parsing logs that have a retention policy nobody chose for reporting purposes. With `reminder_delivery` as a table, it is a `GROUP BY` — and the metric `reminder_delivery_total{state}` alerting on a failed ratio above 2% comes from the same source of truth.

**The state machine lives in the database, not in the queue.** If Service Bus is degraded or `fn-notify-dispatch` is down, reminders stay `pending` in `pg-clinical` and the next sweep re-dispatches them. Nothing is lost in a queue outage because the queue was never where the state was. The same property covers a Celery beat outage: the scheduler stopping delays reminders, it does not lose them, and `reminder_dispatch_lateness_seconds` at p99 above five minutes pages long before a patient notices.

The accepted failure is duplication: a receipt lost after delivery leads to a retry and a second send. For a reminder that is the right side to fail on, and it is written down as a deliberate choice rather than discovered later.

</details>

---

### Q2. The document ingestion path goes Blob Storage to Event Grid to an Azure Function to Service Bus. Why does an upload land in a quarantine container first, and what does that buy?

**Brief answer**
Uploads land in `ingest-quarantine` and are promoted to the `documents` container only after `fn-blob-ingest` reports a clean scan, so an unscanned file is never addressable by a `document` row a patient or clinician can open.

<details>
<summary><strong>Detailed answer</strong></summary>

The client uploads directly to Blob Storage with a short-lived Shared Access Signature ([SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Time-limited token granting scoped access to an Azure Storage resource")), which keeps multi-megabyte scans and letters off the `care-core` pods entirely — those pods are serving a clinician's timeline mid-consultation and have no business streaming file bytes. The metadata row is written transactionally by the Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")); the bytes never pass through it.

That efficiency creates a problem: the platform now accepts bytes it has not inspected, written by a client, into its own storage account. Quarantine resolves it structurally. `evtgrid-blob` fires `BlobCreated` against the quarantine container, `fn-blob-ingest` scans, validates the content type against the declared one, and extracts text; only then is the blob promoted to `documents/{patient_id}/{document_id}/{sha256}` and the `document` row's `scan_state` set to `clean`. The row is not visible to any client until that transition, so there is no window in which an unscanned file is reachable through the API.

The path-shape choices are worth noting too. The blob path includes the [SHA-256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") of the content, so the same file uploaded twice is content-addressed rather than duplicated, and a mismatch between the recorded hash and the stored object is detectable. Quarantine objects are deleted on promotion or after 24 hours, so a failed ingestion does not accumulate cost indefinitely.

What I would watch in operations: Event Grid delivery is at-least-once, so `fn-blob-ingest` must be idempotent — scanning the same blob twice must not produce two `document` rows, which the `document_id` in the path already prevents. And the failure mode where the Function scans successfully but the promotion fails needs a reconciliation sweep, otherwise a clean file sits in quarantine until its 24-hour deletion and the patient's upload silently vanishes.

</details>

---

### Q3. RabbitMQ trips its memory alarm and blocks publishers. Celery beat keeps ticking and PostgreSQL keeps committing outbox rows. Describe what happens across the system, and the order in which you would recover it.

**Brief answer**
Blocked publishers means the outbox relay stops draining and `care-core` requests that publish start timing out, while the database keeps accepting writes — so backlog moves from the broker to `outbox_event`. Recovery is: restore consumption first, then drain, then unblock publishing.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the failure looks like from each component.**

`care-core` writes still commit, because a business change and its `outbox_event` row are one transaction against `pg-clinical` and nothing in that transaction touches the broker. That is the design's insurance: a broker outage cannot fail a clinician's visit note. The relay that reads unpublished outbox rows and publishes to `care.events` is blocked, so `outbox_unpublished_age_seconds` climbs and its alert fires at 30 seconds — that is the first page, and it is the correct first page because it is the leading indicator.

`celery.index` stops receiving work, so `es-clinical` freshness decays past the p95 of 15 seconds and search silently serves stale results. Nothing errors; results are simply missing recent notes. Celery beat keeps ticking and keeps trying to enqueue reminder sweeps into a blocked broker, so reminder dispatch stalls — but the reminders themselves stay `pending` in `pg-clinical`, so they are late, not lost. `reminder_dispatch_lateness_seconds` is the second page and the clinically significant one.

MQTT check-in publishes are refused, which means devices hold them under QoS 1 and retry. That is the path behaving as designed: patients keep checking in, their phones queue, and nothing is acknowledged that is not durable.

**Recovery order, and why.**

1. **Diagnose which queue is growing and why the consumer stopped.** Unblocking publishers first is the instinct and it is wrong — it lets more messages into a broker that is already over its watermark, and the alarm re-trips immediately.
2. **Restore or scale consumers.** If the cause is a poison message wedging a handler, dead-letter it; if it is a downstream dependency (a slow `es-clinical`, a database lock), fix that first, because a consumer that cannot commit cannot ack.
3. **Reduce prefetch if unacked messages are the resident memory**, so the broker can page what it holds.
4. **Let the queue drain below the watermark**, at which point RabbitMQ clears the alarm and unblocks publishers on its own.
5. **Watch the outbox drain**, which is the moment the real load arrives — every write that accumulated during the outage publishes at once. That burst is the second failure opportunity, so the relay should publish at a bounded rate rather than in one unthrottled sweep.
6. **Reconcile.** The nightly job comparing per-patient document counts between `pg-clinical` and `es-clinical` is the backstop; after an incident of this shape I would run it immediately rather than wait for the schedule.

**The design lesson underneath.** This incident is survivable specifically because no state lives in the broker. Reminder state is in `pg-clinical`, index content is rebuildable from `pg-clinical` and `mongo-content`, check-ins are on the device. If any of those had been broker-resident the same alarm would have been a data-loss event rather than a latency event.

</details>

---

### Q3. You operate two brokers, `rmq-core` and Azure Service Bus. Justify that cost, and name the condition under which you would collapse to one.

**Brief answer**
Service Bus cannot terminate MQTT, so removing RabbitMQ means building a bridge for device check-ins; RabbitMQ alone forfeits native Azure Function triggering and managed dead-lettering at the third-party delivery boundary. The seam is drawn where work leaves the platform for Azure.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why each earns its place.** `rmq-core` is non-negotiable for two reasons: the MQTT plugin is the check-in ingress, and it bridges MQTT topics into the same AMQP exchange internal consumers already use, so there is one ingestion topology rather than a protocol adapter service. It is also the Celery broker. `sb-integration` earns its place at the Azure boundary: `fn-blob-ingest` triggers natively from Event Grid and `fn-notify-dispatch` from a Service Bus queue, with managed dead-lettering and replay. Making Functions consume from RabbitMQ means either self-hosting the extension and its scaling behaviour or running a polling bridge — and this is precisely the boundary where the platform hands work to third-party push, email, and SMS providers, which is where durable dead-lettering matters most.

**What the cost actually is.** Two sets of credentials, two dead-letter surfaces to monitor, two mental models for retry and visibility timeout, and a trace that has to be stitched across the hop — which is why `traceparent` is propagated in Service Bus message headers, not only in AMQP ones. Also two capacity stories: Service Bus throughput is a pricing tier, RabbitMQ throughput is a cluster you operate.

**The rule that keeps it memorable and therefore correct.** The seam is jurisdictional, not technical: internal domain events and platform-owned work live on `rmq-core`; anything crossing into Azure-managed compute or leaving for a third-party channel goes through `sb-integration`. A rule engineers can restate is a rule that survives; "use whichever is convenient" produces a topology nobody can draw after a year.

**The collapse condition.** If MQTT ingress is dropped — say check-ins move to the REST endpoint only, because the mobile clients gain a reliable local outbox of their own — then RabbitMQ's unique capability is gone. At that point Celery on Service Bus, or a rewrite of the three worker queues onto Service Bus sessions, becomes worth evaluating, and the estate could be one broker. I would not do it the other way round: dropping Service Bus while keeping Functions means owning the trigger integration, which is more work than it removes.

I would also state the honest asymmetry: this is the second most expensive structural choice in the design after the two-cluster split, and unlike that one it is reversible without moving state.

</details>

---

### Q3. Celery beat is a scheduler singleton. What is the blast radius if it stops for two hours, and what would you change if reminders had a sixty-second delivery guarantee?

**Brief answer**
Nothing is lost — `reminder` rows stay `pending` in `pg-clinical` and the next sweep catches up, so the impact is lateness bounded by the outage. Under a sixty-second guarantee the singleton becomes unacceptable and the sweep has to be leader-elected across replicas.

<details>
<summary><strong>Detailed answer</strong></summary>

**Blast radius today.** Beat drives three things: the reminder window sweep, periodic content and index maintenance, and the outbox relay tick. Its absence delays all three. Reminders are the clinically significant one, and because their state machine lives in the database rather than the scheduler, a two-hour outage produces two hours of late reminders and then a catch-up burst — not two hours of lost reminders. The current mitigations are a single-replica Deployment holding a Redis-backed lock so a restart cannot double-schedule, plus a liveness probe on last-tick age so the pod is restarted rather than sitting alive and idle.

**Why a singleton was acceptable.** The delivery target is ±2 minutes with p99 under five minutes late, against a 99.5% service level objective on reminder delivery within window. A pod restart takes seconds and the catch-up sweep is designed for it. Running two beats without coordination would double-schedule, and the coordination needed to avoid that is real work — so the design bought a probe instead, and named the exposure.

**What changes under a sixty-second guarantee.** A restart gap of even thirty seconds is now a violation, so:

- Replace the single replica with **leader election** — a [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Lease, or RedBeat's lock held by several candidates — so a standby takes over in seconds rather than after a pod schedule.
- Shorten the tick and widen the lookahead window so a missed tick is covered by the next one; sweeping for reminders due within the next five minutes on a ten-second tick makes any single missed tick harmless.
- Move claim contention onto the database, which `FOR UPDATE SKIP LOCKED` already supports, so multiple sweepers running simultaneously during a leader handover is safe rather than a double-dispatch bug.
- Alert on **tick age**, not on pod health. A beat process that is running but wedged on a slow broker publish is the failure a liveness probe on the container will not see.
- Reconsider the end-to-end budget, not just the scheduler: a sixty-second guarantee spans the sweep, the Service Bus hop, `fn-notify-dispatch`, and a third-party provider whose latency you do not control. I would push back on committing to sixty seconds end to end and instead commit to sixty seconds to *dispatch*, with provider latency measured and reported separately — because promising a number you cannot observe is how an [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") becomes theatre.

</details>

---

### Q3. `celery.index` needs to handle ten times the write volume without breaking the p95 freshness budget of fifteen seconds. What do you change, and what breaks first?

**Brief answer**
Scale consumers horizontally and increase bulk batch size, but the budget is a composed sum — outbox relay 2 s, bulk flush 5 s, refresh interval 5 s — so tuning one leg alone buys nothing. The first thing to break is Elasticsearch segment-merge pressure, not consumer throughput.

<details>
<summary><strong>Detailed answer</strong></summary>

**Read the budget first.** p95 under 15 seconds is not a knob; it is relay latency plus flush interval plus `refresh_interval`. Adding consumers reduces only the queueing component. If the flush is 5 seconds and refresh is 5 seconds, ten times the workers still cannot make a document searchable in 3 seconds. Knowing which leg dominates is the whole diagnosis, and it is why the design writes the budget as a sum instead of a single target.

**What I would change, in order.**

1. **Widen the outbox relay.** At 10× write volume a single relay sweeping `WHERE published_at IS NULL` on a partial index becomes the bottleneck. Shard it by aggregate id hash so several relays claim disjoint ranges with `FOR UPDATE SKIP LOCKED`, keeping per-aggregate ordering while parallelising across aggregates.
2. **Scale `celery.index` consumers and raise the bulk batch.** Larger batches are strictly better for Elasticsearch throughput up to the point where a single bulk request exceeds a comfortable size; 1000 documents or 5 seconds is a starting point, and at 10× I would expect to raise the document count and keep the time trigger.
3. **Check the shard count before adding nodes.** Three primaries with one replica is sized for ~150 GB. Indexing throughput scales with primaries, so 10× write volume may need a reindex into a higher primary count — which is only cheap because every index here is fully rebuildable from `pg-clinical` and `mongo-content`.

**What breaks first, and why it is not the consumers.** Elasticsearch indexing is cheap to accept and expensive to merge. Ten times the document rate means ten times the segment creation, and the background merge threads start competing with search for input/output and CPU. The symptom is search p95 rising while indexing looks healthy — the opposite of where you would look. The design already trades in this direction by setting `refresh_interval` to 5 seconds instead of the 1-second default, roughly halving merge pressure; at 10× I would consider going further on the notes index and paying with freshness, because a clinician tolerates a note appearing in search 20 seconds later far better than a search that takes two seconds.

**What must not change.** Ordering per patient, so a delete does not overtake the update that preceded it — bulk operations should carry the source version. And the scope fields `patient_id` and `care_team_ids` on every document, because a throughput optimisation that drops a mandatory filter field converts a performance change into a disclosure.

</details>

---

### Q3. Suppose the workload were not 50 check-ins per second but millions of product-attribute updates a day, as in a large retail or Enterprise Resource Planning (ERP) catalogue. How would this topology change?

**Brief answer**
The shape inverts: ingestion becomes bulk and throughput-bound rather than per-event and latency-bound, so I would batch at the producer, partition by entity key, and put explicit backpressure between stages. My experience here is clinical rather than retail, and I would say so.

<details>
<summary><strong>Detailed answer</strong></summary>

**Honest framing first.** I have not built an [ERP](https://en.wikipedia.org/wiki/Enterprise_resource_planning "Enterprise Resource Planning — Integrated software that manages an organization's core business processes") or retail catalogue system. What transfers is the shape of the problem — high-volume derived-data propagation with a system of record behind it — and I would rather describe the transfer accurately than claim domain experience I do not have.

**What changes structurally.**

*Message granularity.* A check-in is a user-meaningful event and deserves its own message. A product attribute update is not; a million of them are one bulk change. I would publish batched change sets keyed by product, not per-attribute messages, because per-message broker overhead is what turns a throughput problem into a memory incident.

*Ordering.* Check-ins are independent per patient, so parallelism is free. Attribute updates for the same product must apply in order or the final state is wrong. That means partitioning by entity key and keeping one consumer per partition — the point where a log-structured broker such as [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") starts to look more natural than RabbitMQ, since partitioned ordered consumption is its native model rather than something to construct.

*Backpressure.* At this volume the producer is usually another system's batch job, which will happily publish faster than anything downstream can absorb. Queue length limits with `overflow: reject-publish`, or a pull-based transport, are what stop a bulk job from taking the interactive path down with it.

*Idempotency by version, not by natural key.* `(patient_id, recorded_for)` works because a check-in is unique per day. For attribute updates I would carry a monotonic version or sequence per entity and apply with a conditional write, so a redelivered older update is discarded rather than overwriting a newer one — the pattern this design already uses at the Elasticsearch layer.

**What stays the same, and this is the part I would emphasise.** The outbox pattern, because dual-writing to a database and a broker produces drift no metric catches. Consumer idempotency. The rule that no derived store is authoritative and every one is rebuildable from source. Separating the bulk pipeline from the interactive one so a catalogue reload cannot block a user request. Those are not clinical-domain properties; they are what makes high-volume propagation survivable anywhere, and they are the parts of this project I would bring to that problem.

</details>

## Database Engineering and SQL at Scale

---

### Q1. What changed between SQLAlchemy 1.x and SQLAlchemy 2, and why does the typed API matter more on a clinical record than on an ordinary application?

**Brief answer**
[SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") 2 unifies Core and Object-Relational Mapping ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) around a single `select()` construct and adds real typing, so `pyright --strict` can check a query. On a patient record a wrong join is not a bug, it is a disclosure — so a type checker that catches it before review is a security control.

<details>
<summary><strong>Detailed answer</strong></summary>

The mechanical changes: the legacy `Query` object is superseded by `select()` for both Core and ORM, `Session.execute()` returns uniform `Result` objects, lazy loading in an async context raises rather than silently emitting input/output, and `Mapped[...]` annotations make the model's column types visible to a static checker. `DeclarativeBase` with annotated attributes means `patient.diagnosis_code` is typed `str` and `patient.diagnosed_on` is typed `date`, and passing one where the other belongs fails the build.

Why that matters here specifically. The most dangerous defect class in this system is not a crash — it is a query that returns the wrong patient's rows and looks entirely normal. Row-level security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")) in PostgreSQL is the real defence and I will not pretend a type checker replaces it. But typing removes an adjacent class of error cheaply: joining `visit_note` to the wrong foreign key, filtering on `clinician_id` where `patient_id` was meant, or passing a `str` where a `UUID` was expected and getting a silent cast. Those are exactly the mistakes that survive code review because the code reads plausibly.

The migration itself is worth talking about honestly, since the responsibility says "migrated data access to SQLAlchemy 2". The `future=True` flag in 1.4 is the bridge: you move to 2.0-style `select()` and session semantics while still on 1.4, get the test suite green, and only then bump the major version. The genuinely disruptive parts are implicit autocommit disappearing, `Query.get()` moving to `Session.get()`, and lazy-load behaviour under async — all of which surface as test failures rather than runtime surprises if the integration suite runs against a real PostgreSQL container rather than SQLite.

The one thing typing does not give you is query *plan* safety. A perfectly typed query can still be a sequential scan on 110 million rows. That is what the access-pattern index table and the `EXPLAIN` assertions are for.

</details>

---

### Q1. What is declarative range partitioning, and why are `wellbeing_checkin` and `audit_event` partitioned by month while the other tables are not?

**Brief answer**
Range partitioning splits one logical table into physical child tables by a key range, so the planner can prune irrelevant partitions from every query. Those two tables are partitioned because they are append-only, read by recent time window, and enormous — 110 million and 1.8 billion rows over five years.

<details>
<summary><strong>Detailed answer</strong></summary>

**How pruning pays.** A check-in query filtered on a date window touches one or two monthly partitions instead of the whole table. The planner eliminates the rest before executing, so index size, buffer pressure, and vacuum cost all scale with the window rather than with history. On a 1.8-billion-row audit table that is the difference between a viable query and an unusable one.

**Archival becomes metadata.** Detaching a partition older than the thirteen-month hot retention is a catalogue operation that completes in milliseconds; the equivalent `DELETE` would rewrite hundreds of gigabytes, bloat the table, and hold locks. The audit archive path — detach, export to `blob-documents` as compressed Parquet under a seven-year legal hold, drop — exists because the table is partitioned. This is the practical answer to "why partition": not query speed alone, but that data lifecycle stops being a batch job you fear.

**Why not partition everything.** Partitioning costs you: a unique constraint must include the partition key, cross-partition queries pay planning overhead, foreign keys pointing *into* a partitioned table are constrained, and you need automation to create next month's partition before it is needed — a missing partition is an insert failure at midnight on the first. `appointment`, `prescription`, and `visit_note` are millions of rows, not hundreds of millions, and are queried by patient rather than by time window. They get composite B-tree indexes instead. Partitioning them would buy pruning that patient-scoped queries do not need and impose constraints on the tables most involved in joins.

**The detail that connects to security.** RLS policies on the partitioned tables must be written so the `patient_id` predicate still reaches the planner. A policy that wraps the check in an opaque subquery defeats pruning and turns an index scan into a full sweep across every partition — which is why the design guards the plan shape with an `EXPLAIN` assertion in the test suite rather than trusting review.

</details>

---

### Q1. What is a Block Range Index (BRIN), and when is it the right choice over a B-tree?

**Brief answer**
A [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") stores the minimum and maximum value per block range rather than an entry per row, so it is orders of magnitude smaller. It works when physical row order correlates with the indexed column — which append-only time-series data gives you for free.

<details>
<summary><strong>Detailed answer</strong></summary>

A B-tree on `recorded_at` across 110 million check-ins is several gigabytes and has to be maintained on every insert. A BRIN on the same column stores, per 128-page range, the minimum and maximum timestamp in that range — a few hundred kilobytes total. A range query consults the summary, discards ranges whose bounds cannot match, and scans the survivors.

The correlation requirement is the whole story. Check-ins and audit events are inserted in time order and never updated, so block N contains timestamps strictly after block N−1 and the summary is tight. If rows were updated or inserted out of order the min/max per range would widen until nearly every range matched every query, and the index would degenerate into a sequential scan with extra steps. That is the failure mode to name in an interview: a BRIN never returns wrong results when correlation is poor, it just silently stops helping.

In this design the two indexes are complementary rather than competing. BRIN on the time column serves the range scan cheaply; the composite B-tree `(patient_id, timeline_at DESC)` serves the patient-scoped access pattern where selectivity comes from the patient, not the time. Both exist because both access patterns are named in the API contract, and the design is explicit that an index with no query behind it is write amplification on a 110-million-row table — which is a real cost, not a stylistic preference.

You can check correlation directly with `pg_stats.correlation` for the column, and if it has drifted, `CLUSTER` or a repack restores it. On an append-only partitioned table it does not drift, which is precisely why BRIN is the right tool here and would be the wrong tool on a table with heavy updates.

</details>

---

### Q1. `symptom_scores` is a `jsonb` column rather than a set of typed columns. Why, and what do you give up?

**Brief answer**
The symptom set differs by cancer type and changes with the clinical protocol, so columns would mean a migration on a 110-million-row table every time an oncology team revises a questionnaire. A Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) on the document supports the trend query without that.

<details>
<summary><strong>Detailed answer</strong></summary>

**The case for `jsonb`.** Breast, lung, and haematological protocols score different symptoms; a shared relational shape would be a wide sparse table where most columns are null for most rows, or an Entity-Attribute-Value design where every read is a pivot. `jsonb` stores the document in a parsed binary form, supports containment and path operators, and a GIN index over it makes `symptom_scores @> '{"fatigue": ...}'` and key-existence queries indexable. The trend endpoint `GET /api/v1/patients/{id}/checkin-trend` is served from that index.

**What you give up, stated plainly.**

- *Type safety at the database.* Nothing stops a client writing `"3"` where `3` was meant. The defence moves up into [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") validation, which means it is only as good as the single write path — acceptable here because `celery.index` is the only writer, but it would not be acceptable if several services wrote the table.
- *Referential integrity.* A symptom code in the document cannot have a foreign key to a symptom catalogue. Validating that a code is real becomes application logic or a check constraint over the document.
- *Statistics quality.* The planner's estimates for `jsonb` containment are far weaker than for a typed column, so a query that mixes a `jsonb` predicate with a selective one can get a bad plan. In practice you keep the selective predicate — `patient_id` — leading and let `jsonb` filter what remains.
- *Storage.* Keys are repeated in every row. On 110 million rows that is real, and short key names are worth the ugliness.

**The line I would draw.** Anything the system must join on, enforce, or index for selectivity gets a column: `patient_id`, `recorded_for`, `adherence`. Anything whose shape is owned by a clinical protocol that will change without a software release stays in the document. Putting `adherence` in the `jsonb` would have been the mistake — it is a stable, universal, queryable fact, and it belongs in a boolean column, which is where it is.

</details>

---

### Q2. The patient timeline unions five tables. Explain the `timeline_at` normalisation and the keyset cursor, and why offset pagination is prohibited on this query.

**Brief answer**
Each source table orders by a different natural column, one of which is a `date` rather than a `timestamptz`, so a `UNION ALL` cannot be ordered deterministically or served from one index shape. `timeline_at` normalises the ordering key, and the cursor is the tuple `(timeline_at, source_table, id)` so ties break deterministically.

<details>
<summary><strong>Detailed answer</strong></summary>

**The problem.** Appointments order by `starts_at`, prescriptions by `prescribed_on`, visit notes by `encounter_date` (a `date`, so all of a day's notes collide at midnight), documents by `uploaded_at`, check-ins by `recorded_at`. Mixing a `date` and a `timestamptz` in one sort produces ties that no single column can break, and each branch would need its own index shape for its own column.

**The fix.** Every timeline-feeding table carries `timeline_at timestamptz`, populated from its natural column. The natural columns stay, because `encounter_date` is the clinical fact and `timeline_at` is only a presentation key — conflating them would mean a display concern silently rewriting a record field. Every one of those tables then carries the same composite B-tree `(patient_id, timeline_at DESC)`, so all five branches use identical index shapes.

**The query.** It is a keyset-paginated `UNION ALL` with the `LIMIT` pushed *into each branch*, so PostgreSQL reads at most `limit` rows per source and merges, instead of materialising the whole union and sorting it. That distinction is the entire performance story: the naive version reads a patient's full history on every page load.

**The cursor.** `(timeline_at, source_table, id)`. The timestamp alone is not unique — an appointment and a check-in can share a millisecond — so a two-column cursor would either skip or repeat rows at a page boundary. Adding the source table and the row id makes the tuple total, and the next page is `WHERE (timeline_at, source_table, id) < (:cursor_ts, :cursor_src, :cursor_id)`, which PostgreSQL evaluates as a row comparison against the composite index.

**Why offset is prohibited.** `OFFSET 10000` makes the database produce and discard ten thousand rows before returning anything, so page cost grows linearly with page number — on a 110-million-row check-in table the deep pages are unusable. Worse, offset is *wrong* under concurrent writes: a new check-in inserted while a clinician pages shifts every subsequent row by one, so a record can be skipped entirely. On a clinical timeline, "the page silently omitted a prescription" is not a performance issue. Keyset pagination is stable under insertion because the cursor names a position in the data, not a count of rows already seen.

</details>

---

### Q2. Migrations are expand/contract and run as an ArgoCD PreSync hook. Walk me through adding a non-nullable column to the 110-million-row check-in table without downtime.

**Brief answer**
Split it across two releases: the first adds the column as nullable with a default, backfills in batches, and starts writing it; the second adds the constraint and removes the old path. Both database states must be compatible with both application versions, because blue-green runs them concurrently.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it must be two releases.** `care-core` deploys blue-green: for the duration of the cut-over, the old image and the new image are both running against the same schema. A migration that is only compatible with the new code breaks the old colour, which destroys the rollback path — and rollback here is an [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") revision revert with no down-migration, which only works if every schema state is backwards-compatible. That constraint is what makes the expand/contract discipline non-optional rather than a nicety.

**Release one — expand.**

1. `ALTER TABLE ... ADD COLUMN adherence_source text` with no `NOT NULL` and no volatile default. On modern PostgreSQL a nullable add is a catalogue-only operation, so it does not rewrite 110 million rows or hold a long lock. This is the step people get wrong: a `NOT NULL` with a default on an older version, or any default that is not constant, forces a full table rewrite and an `ACCESS EXCLUSIVE` lock for the duration.
2. Deploy code that **writes both** the old representation and the new column, and reads the old one. Now the old colour and the new colour are both correct.
3. **Backfill in batches**, partition by partition, with a bounded batch size and a pause between batches, committing each. A single `UPDATE` over the whole table would hold a transaction open for hours, block autovacuum, and bloat the table by the size of the rows it rewrites. Because the table is monthly-partitioned, the backfill is naturally chunked and progress is observable.
4. Add a `NOT VALID` check constraint so new rows are constrained immediately, then `VALIDATE CONSTRAINT` separately — validation takes a `SHARE UPDATE EXCLUSIVE` lock rather than blocking writes.

**Release two — contract.** Once every row is populated and the previous image is no longer deployable, promote to `SET NOT NULL` (cheap, because the validated constraint proves it), switch reads to the new column, and remove the dual-write.

**Where the ArgoCD PreSync hook fits.** `alembic upgrade head` runs before the new pods start, so the schema is always ahead of or equal to the code. That ordering is only safe because migrations are additive — a destructive migration in a PreSync hook would break the currently-running version before the new one exists.

**What I would do differently on an unfamiliar database.** Everything above depends on PostgreSQL's specific lock and rewrite semantics. On another engine — the client's InterSystems [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage"), for example — I would not assume any of it. I would establish, with a copy of production-sized data, which alterations are catalogue-only, which rewrite, and which lock, before writing the first migration. Guessing that is how a "quick column add" becomes a two-hour outage.

</details>

---

### Q2. `external_mrn` is encrypted at rest but hospital sync still has to look a patient up by it. How does that work, and what does the mechanism leak?

**Brief answer**
The row stores the encrypted value plus a blind index — a keyed Hash-based Message Authentication Code ([HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity")) over the normalised Medical Record Number ([MRN](https://en.wikipedia.org/wiki/Medical_record "Unique identifier a healthcare provider assigns to a patient's record")). Lookups match the blind index; only the matched row is ever decrypted. It leaks equality — identical MRNs produce identical index values.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why plain encryption is not enough.** Non-deterministic encryption is what you want for confidentiality — the same plaintext encrypts differently each time, so an attacker with the ciphertext column learns nothing about repetition. But it also makes `WHERE external_mrn = :value` impossible, because you cannot reproduce the ciphertext to compare against. Deterministic encryption restores lookup and gives back exactly what non-determinism was protecting: equality patterns across the whole column.

**The blind index.** Store both. The ciphertext is non-deterministic and is the thing that actually protects the value. Alongside it sits `HMAC-SHA256(normalised_mrn, index_key)` where `index_key` lives in Key Vault, separate from the encryption key. A lookup computes the same HMAC and matches on it; the single matching row is decrypted to confirm. Normalisation — case, whitespace, leading zeros — has to happen before the HMAC or two spellings of the same MRN produce different index values and the lookup silently misses.

**What it leaks, and why that is acceptable here.** Equality is visible: an attacker with the column can tell two rows share an MRN, and can confirm a guessed MRN if they also hold the index key. They cannot recover the MRN from the index without the key, because HMAC is keyed — this is precisely why a plain `SHA256` would be wrong. MRNs come from a small structured space and an unkeyed hash of the whole column is a dictionary attack an afternoon long.

**The key separation is the control that makes it work.** Encryption key and index key are distinct and separately access-controlled, so compromising one does not give both capabilities. Rotating the index key means recomputing the column, which is a batch job to plan for, not an incident.

**Where the design stops.** Diagnosis and treatment data are deliberately *not* field-encrypted, and the docs say so rather than dressing it up: they are the substance of every query and index, encrypting them would either break search or be defeated by a decryption path the application holds anyway. The honest control there is RLS, audit, and least privilege. I think being able to say which data is encrypted, which is not, and why, is more valuable in a review than claiming everything is.

</details>

---

### Q2. The clinician timeline query has become slow in production. Walk me through diagnosing it.

**Brief answer**
Confirm it from the metric first, then get the real plan with `EXPLAIN (ANALYZE, BUFFERS)` on a representative patient, and compare estimated against actual rows to find where the planner is wrong. On this query the usual answers are a lost keyset cursor, an RLS policy defeating partition pruning, or plan drift from stale statistics.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step 1 — establish the fact.** `http_request_duration_seconds` p95 by route tells me whether it is the timeline route or everything, and whether the change is a step or a drift. A step change points at a deploy or a migration; a drift points at data growth or statistics. Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production") gives me the span breakdown inside the request — if the database span is 40 ms and the request is 900 ms, the query is not the problem and I have just saved myself a day.

**Step 2 — reproduce the real plan.** `EXPLAIN (ANALYZE, BUFFERS)` with a patient whose history is representative — not a test patient with six rows. Two things I look at before anything else: rows estimated versus rows actual at each node, because a large divergence is the planner being misled and is the root of most bad plans; and `Buffers: shared read` versus `hit`, which distinguishes a slow query from a cold cache.

**Step 3 — the specific suspects on this query.**

- *Offset pagination has crept back in.* Somebody added a page-number parameter for a report and the branch `LIMIT` push-down is gone. The tell is a `Sort` node above the union with a row count far larger than the page size.
- *Partition pruning is not happening.* The plan lists every monthly partition of `wellbeing_checkin` instead of one or two. The usual cause is an RLS policy that buries `patient_id` in a form the planner cannot use, which is why the design asserts plan shape in a test rather than trusting that it stayed correct.
- *The composite index is not being used on one branch.* Often because a new column was added to the sort, or a branch filters on `encounter_date` instead of `timeline_at` and so cannot use `(patient_id, timeline_at DESC)`.
- *Statistics are stale* after a bulk backfill; `ANALYZE` on the affected tables is the cheap first thing to try and takes seconds.
- *Not the query at all.* `pg_stat_activity` for lock waits, and check whether an audit write is contending — remembering that every patient-facing read here is also a write, so the read path is subject to write-path contention in a way that surprises people.

**Step 4 — fix and prove.** Whatever the change, I want the plan before and after on the same data, and an assertion in the test suite that pins the property that broke — the partition count, or the absence of a sort node. A fix with no regression test is a fix that comes back.

</details>

---

### Q2. There are two read replicas, but patient-facing reads are served by the primary. Explain that, and how you would verify it stays true.

**Brief answer**
Every read of patient data writes an `audit_event` row in the same transaction, and a replica cannot write. So an audited read is a write, and read availability is coupled to the primary. Replicas carry only unaudited work: index rebuilds, reporting aggregates, backup verification.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the audit is synchronous.** An audit trail that can be lost in a queue is not an audit trail — that is the regulatory position, and it drives the rest. Writing the audit row in the same transaction as the access means the two cannot diverge: either both happened or neither did. Queuing audit rows instead would let reads survive a primary failover, at the cost of a trail with a hole in it whose size you learn about after the incident.

**What it costs, stated as a trade-off rather than hidden.** During a zone failover of the Flexible Server primary — roughly sixty seconds — reads and writes both return `503`. A cached timeline is deliberately *not* served as a fallback, because serving it could not be audited. So read availability is bounded by write availability. That fits the 99.9% monthly budget of about 43 minutes at a sixty-second failover, and it is written down as the accepted price of a control chosen in the security design rather than discovered during an outage.

**A cache hit is still an access.** Serving a timeline from `redis-cache` writes the same audit row as serving it from PostgreSQL. Caching reduces read cost, never audit coverage. This is the property most likely to be broken accidentally by a well-meaning optimisation, so it deserves an explicit test.

**How I would verify it stays true.** Three checks, and the point of all three is that they fail loudly rather than requiring someone to remember the rule.

1. *A routing assertion.* The session factory that binds to a replica engine is a distinct object from the one that binds to the primary, and a test asserts that no request-scoped handler can obtain the replica session. Making it a type distinction rather than a configuration flag means the checker catches the mistake, not a reviewer.
2. *A behavioural test.* Point a patient read at a replica in a test environment and assert it fails. If it succeeds, the audit write was skipped somewhere — which is the actual defect, and it would otherwise be invisible.
3. *A detection rule.* One of the Kibana rules over the audit stream fires on any direct query against `pg-clinical` from a non-application principal, and I would pair it with a reconciliation comparing Protected Health Information ([PHI](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160/subpart-A/section-160.103 "Individually identifiable health data that HIPAA regulates")) read counts in the API metrics against audit row counts. A sustained gap means some read path is not auditing.

**When I would revisit it.** The design's own evolution trigger is honest here: at sustained write throughput above 3K transactions per second, the first move is extracting `audit_event` to its own instance — it is append-only and referenced by no foreign key — which decouples audit write load from record read load without weakening the guarantee.

</details>

---

### Q3. The client's system of record is InterSystems IRIS with tables over 100 million rows. You have not used IRIS. What transfers from this work, and what would you refuse to assume?

**Brief answer**
The reasoning transfers — access-pattern-driven indexing, keyset pagination, expand/contract migrations, plan verification against production-sized data. The engine-specific mechanics do not, and I would establish IRIS's actual lock, rewrite, and planner behaviour empirically before writing a migration.

<details>
<summary><strong>Detailed answer</strong></summary>

**Saying the honest thing first.** My large-table experience is PostgreSQL: a 110-million-row partitioned check-in table and a 1.8-billion-row audit table, with the query and migration discipline that goes with them. I have not worked with IRIS, and I would not claim otherwise in an interview or on the job.

**What transfers, because it is not engine-specific.**

- *Index for named access patterns, not defensively.* Every index in this design exists for a query in an API contract, because an index with no query behind it is pure write amplification on a large table. That reasoning holds on any engine.
- *Keyset pagination over offset.* Offset's linear cost and its instability under concurrent inserts are properties of the operation, not of PostgreSQL.
- *Expand/contract migrations.* Never requiring the schema and one deployed version to change together is what makes rollback possible, whatever the engine.
- *Batch large backfills; never hold a long transaction.* Universally true, even though the specific consequences (bloat, autovacuum starvation) are Postgres-flavoured.
- *Prove the plan on production-sized data.* A query that is fast on ten thousand rows tells you nothing about a hundred million.

**What I would refuse to assume, and would test on day one.**

- Which `ALTER TABLE` forms are catalogue-only and which rewrite the table, and what lock each takes and for how long. This is the single most expensive thing to get wrong and it differs sharply between engines.
- How the optimiser uses statistics, whether it supports the equivalent of a row-comparison predicate for a keyset cursor, and how to read its plan output.
- What IRIS's globals-based storage means for physical row ordering — the assumption underneath BRIN-style range indexing may have no analogue, or a better one.
- Concurrency and isolation defaults, and whether a long read blocks writers.
- Whether there is a partitioning analogue and what the archival story is, because "how does old data leave the table" determines the whole retention design.

**How I would get there.** A restored copy of a production-sized table in a scratch environment, a small set of representative queries and one representative migration, and measurements rather than documentation claims. The client's brief says migrations must be extremely careful — I would rather spend the first week building that evidence than be careful in the abstract. And I would expect to ask their database contacts a lot of questions, which is faster than rediscovering what they already know.

</details>

---

### Q3. The evolution triggers say that above 3,000 transactions per second or 4 TB hot, you extract `audit_event` first and only consider sharding by `patient_id` last. Defend that order.

**Brief answer**
`audit_event` is append-only, referenced by no foreign key, and read by nothing on the request path — so moving it is the largest relief for the least coupling. Sharding the record by patient is the most invasive change available and should be the last resort, not the first instinct.

<details>
<summary><strong>Detailed answer</strong></summary>

**Size the problem honestly first.** Audit events outweigh all clinical data combined by roughly five to one — around 550 GB against about 130 GB of check-ins, notes, appointments, and prescriptions over five years. So the table causing the pressure is not the clinical record; it is the compliance artefact attached to it. Any plan that starts by restructuring the record is optimising the wrong table.

**Why `audit_event` moves cheaply.** It has three properties that make extraction almost free. It is append-only, so there is no update or delete path to keep consistent. No foreign key points at it, so no join breaks. Nothing on the request path reads it — it is queried for compliance and Data Subject Access Requests ([DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them")), which tolerate a different instance and a different latency profile. The one genuine coupling is that the audit row is written in the same transaction as the access, and moving the table to another instance breaks that atomicity. That is the real cost of this step and I would want it on the table: either accept a two-phase write with a reconciliation sweep, or keep a small local staging table that is drained. The design should be honest that step one is not free, only *cheapest*.

**Why `wellbeing_checkin` is second.** Same append-only shape, 110 million rows, and already partitioned — so it detaches cleanly. But it *is* read on the request path (the timeline and the trend endpoint), so extracting it means a cross-instance read for the timeline union, which is a genuine architectural change rather than a relocation.

**Why sharding is last.** Sharding the record by `patient_id` touches every query, every migration, and the RLS model; it breaks cross-patient queries like a clinician's patient list; it makes the timeline union a scatter-gather; and it is close to irreversible. Reaching the point where it is necessary means roughly twenty times the modelled load. Doing it earlier buys operational complexity against a number the system does not have — which is the same reasoning that rejected a microservice fleet at 200 queries per second.

**The general principle.** Take capacity relief in order of coupling, not in order of how interesting the change is. Move what nothing depends on, then what one path depends on, and only reshape the thing everything depends on when there is no alternative left. And attach each step to a measured trigger, so the decision is made by a metric rather than by whoever is most worried that quarter.

</details>

---

### Q3. Row-level security, monthly partitioning, and connection pooling all interact on the same query. Describe the failure that arises from each pair.

**Brief answer**
RLS with pooling can leak identity across requests if the session variable is not transaction-scoped; RLS with partitioning can defeat pruning if the policy hides the partition key from the planner; pooling with partitioning affects plan caching. All three are silent — none produces an error.

<details>
<summary><strong>Detailed answer</strong></summary>

**RLS × pooling — the dangerous one.** Each request sets a session parameter (`app.actor_id`, `app.actor_kind`) that the policies read. Azure Flexible Server fronted by a transaction-mode pooler reuses a backend connection across requests, so a plain `SET` persists past the request that issued it and the next caller inherits the previous caller's identity. The strongest control in the design becomes its exact opposite: a clinician sees a patient they have no relationship with, and every layer reports success. The fix is `SET LOCAL` inside the request transaction, so the value dies with the transaction. Because the failure is invisible, this is asserted by a pooled-connection leakage test rather than left to review — the test runs two requests as different actors over the same pooled backend and asserts the second sees nothing of the first.

**RLS × partitioning.** The policy on `wellbeing_checkin` must express the patient constraint in a form the planner can push down. Written as a direct predicate, pruning survives and a windowed query touches one or two partitions. Written as an opaque subquery or a function the planner cannot inline, the predicate is applied after the scan — so every monthly partition is read, and a query that should touch 2 million rows touches 110 million. It returns correct results, just slowly, which is why it survives testing on a small dataset and appears in production three months later. The guard is an `EXPLAIN` assertion on plan shape.

**Pooling × partitioning.** With many partitions and a pooled backend, PostgreSQL's generic plan caching can choose a plan that does not prune, because a generic plan cannot know the parameter value. The symptom is a query that is fast the first five times and slow on the sixth — the point where the planner switches from custom to generic plans. It is diagnosable, and the mitigations are ensuring the partition key is a directly-bound parameter or forcing custom plans for that statement.

**The property they share.** Every one of these failures returns correct-looking output. There is no exception, no 500, no log line. That is why each has a specific test attached rather than a convention: a control you cannot observe failing is a control you do not have. The same reasoning puts `NOSUPERUSER` and the absence of `BYPASSRLS` on the application role under a continuous integration assertion — a privilege that silently grew would disable RLS entirely without changing a single line of application code.

</details>

---

### Q3. The design uses `jsonb` for a variable attribute set. At ten times the volume, with high-churn attribute updates, would you still make that call?

**Brief answer**
For a bounded per-row document that is read whole and rarely updated in place, yes. For millions of individually-mutating attributes it is the wrong shape — updating one key rewrites the whole document row, and Multi-Version Concurrency Control ([MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row")) makes that expensive.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the current call is right.** A check-in's `symptom_scores` is written once, read whole, and never updated. PostgreSQL's MVCC rewrites the entire row on any update, so document size only matters if you update — and here you do not. The document is small, the protocol owns its shape, and a GIN index serves the trend query. Correct choice for this workload.

**Why high-churn attributes break it.** If each of a million entities has fifty attributes and individual attributes change constantly, every single-key update rewrites the whole document, produces a dead tuple, and drives autovacuum load proportional to churn × document size. Add a GIN index and it gets worse: GIN maintenance on update is expensive, and the pending-list behaviour means index updates arrive in bursts. You end up with table bloat, vacuum falling behind, and index maintenance dominating the write path.

**What I would use instead, and how I would choose.**

- *A narrow attribute table* — `(entity_id, attribute_key, value, version, updated_at)` with a primary key on the first two. An update touches one small row. This is the Entity-Attribute-Value pattern, which has a bad reputation earned mostly from people using it for *everything*; used for a genuinely open attribute set with a strict access pattern it is the right relational answer. Reads that need many attributes at once pay a pivot, so it suits write-heavy, targeted-read workloads.
- *Typed columns for the stable core, a document for the tail.* Most catalogues have twenty attributes that everything has and a long tail that varies. Splitting them gives you indexing and constraints where they pay and flexibility where you need it, and it is what I would try first.
- *A different store for the tail* only if the relational options genuinely fail, because a second store means a consistency problem you did not have.

**The decision rule.** Write granularity against read granularity. If you read the whole thing and write the whole thing, use a document. If you write one field at a time, use rows. `symptom_scores` is read-whole and write-once, which is why it is `jsonb`; a product attribute catalogue under constant partial update is the opposite case, and I would expect to reach a different answer there — and to say so rather than defend the pattern I happened to use last.

</details>

## Search and Relevance Engineering

---

### Q1. PostgreSQL has full-text search built in. Why does this platform pay for a second store?

**Brief answer**
PostgreSQL full-text search is adequate at around 100,000 notes; it is not adequate at 2.4 million with per-clause filtering, highlighting, and relevance tuning. The cost was taken against a measured latency target, not a preference.

<details>
<summary><strong>Detailed answer</strong></summary>

**What PostgreSQL gives you.** `tsvector` with a GIN index handles stemming, stop words, and boolean queries well, and it keeps everything in one store with one consistency model and one backup. For a lot of applications that is the correct answer and adding Elasticsearch is over-engineering.

**Where it stops.** Three things break down at this scale and shape. Relevance scoring is coarse — `ts_rank` is not tunable per field the way [BM25](https://en.wikipedia.org/wiki/Okapi_BM25 "Best Matching 25 — Ranking function that scores how relevant a document is to a search query") with per-field boosts is, so you cannot say a match in a note's title matters more than one in its body. Highlighting via `ts_headline` re-parses the document at query time, which is expensive on a 4 KB note and gets worse the more results you return. And combining a text match with several filters (date range, tags, entity codes, patient scope) tends to produce plans where the planner must choose between the GIN index and the filter indexes and gets it wrong on one side or the other.

**What the second store actually costs, which is the part worth saying out loud.** An index to keep consistent, a rebuild procedure to rehearse, and a scope filter that must never be omitted — three new failure modes, one of which is a disclosure path. The design does not pretend those away. It buys them down deliberately: nothing originates in `es-clinical` so it is fully rebuildable from `pg-clinical` and `mongo-content`; the rebuild is rehearsed quarterly rather than assumed; and the scope fields are mandatory in the mapping so a missing filter is a schema violation rather than a code review miss.

**The test I would apply before adding a search engine anywhere.** Is there a latency or relevance number the existing store provably cannot hit, measured on production-sized data? Here there is — a 35% latency reduction against a defined query set. Without such a number, the honest recommendation is to stay on one store, and I would rather make that recommendation than add infrastructure because it is the expected shape.

</details>

---

### Q1. What is the difference between `filter` and `must` context in an Elasticsearch query, and why does this design put scope and date clauses in `filter`?

**Brief answer**
`must` clauses contribute to the relevance score and are not cacheable; `filter` clauses are boolean yes/no, skip scoring entirely, and are cached as bitsets. Scope and date do not affect how relevant a result is, so scoring them wastes work.

<details>
<summary><strong>Detailed answer</strong></summary>

Elasticsearch evaluates a `bool` query in two modes. Anything under `must` or `should` runs the similarity algorithm — by default BM25 — computing term frequency and inverse document frequency per matching document. Anything under `filter` or `must_not` answers only "does this document match", produces no score contribution, and can have its result cached as a bitset reused across queries.

The practical consequence here is large. `patient_id` and `care_team_ids` are the same for every query a given clinician issues, so their filter bitset is cached after the first query and effectively free afterwards. Date ranges cache well too when they align to common windows. Because the expensive scoring pass then runs only over the pre-filtered candidate set instead of the whole index, the cost of a search scales with what the user is allowed to see rather than with the size of the index.

There is a correctness dimension as well. Putting `patient_id` under `must` would mean a document could rank into the results on text relevance alone if the clause were ever weakened or reordered — scope would be participating in a scoring competition rather than being a gate. As a `filter` it is binary and cannot be traded off. That distinction matters because the scope clause is the control that stops search becoming the path around row-level security.

The mistake I would look for in a review is a range or terms clause placed in `must` out of habit. It usually shows up as a query that gets slower as the index grows even though the result set is small — a signal that scoring is running over far more documents than the user can actually see.

</details>

---

### Q1. What is an analyzer, and what work does the clinical synonym filter do on the notes index?

**Brief answer**
An analyzer is the pipeline that turns text into indexed tokens — character filters, a tokenizer, then token filters. The notes index uses an English analyzer plus a clinical synonym filter so a search for a drug's generic name also matches its brand name.

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline runs at index time and at query time, and the two must be compatible or matches silently disappear. For `es-clinical-notes` the `body` field uses an English analyzer — lowercasing, stop words, and stemming, so "treated", "treating", and "treatment" reduce toward a shared root — plus a synonym filter carrying oncology vocabulary.

Why the synonym set matters more here than in a general search box: clinical writing is full of equivalences that a stemmer cannot possibly know. Brand and generic drug names, abbreviations that vary by hospital, staging notation written several ways. A clinician searching for one form and getting no results does not conclude the synonym set is incomplete; they conclude the search is broken and go back to scrolling the record — which is the behaviour the product exists to remove.

Two engineering details worth knowing. Synonyms applied at index time bloat the index and require a reindex to change; applied at query time they are cheap to update but expand every query and interact awkwardly with multi-word phrases. Most deployments use query-time synonyms with a managed synonym set for exactly that update flexibility. And field types have to match intent: `body` is `text` so it is analyzed, while `tags`, `entities`, and `patient_id` are `keyword` so they are stored verbatim and are usable for exact filters and aggregations. Making an identifier `text` is a classic mapping bug — it gets analyzed, and an exact-match filter on it starts matching things it should not.

**The part that is not an engineering problem.** Building and maintaining the oncology synonym and abbreviation set is clinical work, not engineering work. The design flags this explicitly: it needs a named clinical owner, because without one the relevance claim has nothing behind it. I would rather raise that as a dependency than quietly ship a default English analyzer and describe the result as tuned.

</details>

---

### Q2. Every document carries `patient_id` and `care_team_ids`, and every query is wrapped in a filter on them. Why is that an index-level property rather than an application convention?

**Brief answer**
Because a search engine that can return a document the record layer would refuse is a disclosure path, and a convention is something a single new code path can forget. Making the fields mandatory in the mapping and building every query in one place turns "remember the filter" into "you cannot construct a query without it".

<details>
<summary><strong>Detailed answer</strong></summary>

**The threat model.** Row-level security in PostgreSQL makes a forgotten scope in application code return zero rows instead of another patient's record. That control lives in the database and cannot be bypassed by application error. Elasticsearch has no equivalent — it happily returns anything matching the query it was given. So the moment search exists, there is a second read path to patient data whose authorization is entirely in application hands. If that path is protected only by developers remembering, the strongest control in the system has a documented bypass.

**What the design does about it.** Clients never query `es-clinical` directly; there is no proxied search endpoint and no direct network route. `care-core` builds every query, and it injects the scope filter derived from the caller's token and their `care_relationship` rows — the same table row-level security joins through, so there is one definition of "may this actor see this patient" rather than two that can drift. The scope fields are mandatory in the mapping, so a document indexed without them fails rather than becoming invisible-to-the-filter and therefore visible-to-everyone.

**How I would harden it further, since "one place builds the query" is still a convention about code structure.** Make the query builder the only exported way to reach the client — the raw Elasticsearch client is private to that module, so a new feature physically cannot construct an unscoped query without editing the module that owns scoping, which is where a reviewer will look. Add a test that issues a search as clinician A for a patient only clinician B follows and asserts zero hits; that test is the one that catches a regression, not a code review. And keep the detection rule over the audit stream for out-of-team access, because the search path writes audit rows too.

**The general principle.** When you add a second read path to protected data, the authorization for it has to be structural — in the schema, in the type system, or in a single chokepoint — not procedural. Anything that relies on every future developer knowing a rule will eventually meet a developer who does not.

</details>

---

### Q2. A clinician leaving a care team loses search reach immediately, but a patient being reassigned to a different team requires a reindex. Why are these different?

**Brief answer**
Team membership is resolved fresh from `pg-clinical` on every query, so it takes effect instantly. `care_team_ids` is a property of the indexed *document*, so changing which team owns a patient means rewriting that patient's documents — which is eventually consistent.

<details>
<summary><strong>Detailed answer</strong></summary>

**The asymmetry comes from which side of the filter each fact sits on.** A search query is "documents where `care_team_ids` intersects the set of teams this caller belongs to". The caller's side is computed per request from the current `care_relationship` and `care_team_member` rows, so revoking a clinician's membership takes effect on the next query with no reindex at all. The document's side is baked into the index at write time, so reassigning a patient to a different team requires rewriting every document belonging to that patient.

**How the reindex is driven.** `celery.index` consumes `carerelationship.changed` from `care.events` and reindexes exactly that patient's documents — a bounded amount of work, not a full rebuild. It is subject to the same composed freshness budget as any other index write: p95 under fifteen seconds.

**The window, and what closes it.** Until that reindex completes, documents still carry the outgoing team's id, so a clinician on the outgoing team could still match them in search. Fifteen seconds is short but it is not zero, and on a clinical record "briefly" is not a defence. What closes it is that reassignment *also* closes the `care_relationship` row, and the record layer honours that immediately through row-level security. So the outgoing clinician may momentarily see a search *hit*, but opening it returns nothing — the record refuses. The exposure is reduced to result metadata for a bounded window rather than record content.

**Would I accept that?** As designed, yes, provided the search result snippet does not itself contain clinical text — and that is worth checking, because a highlighted excerpt of a visit note *is* record content. If highlighting is enabled on the notes index, I would want the reassignment path to either suppress highlights during the reindex window or perform a synchronous targeted delete of that patient's documents from the outgoing scope before the asynchronous rebuild. That is the kind of detail where a design's stated guarantee and its actual behaviour diverge, and it is worth raising rather than assuming the budget covers it.

</details>

---

### Q2. The CV claims a 35% reduction in query latency. How would you establish that number, and what would make it a false claim?

**Brief answer**
Measure a fixed query set against production-shaped data before and after, at the same percentile, with cache state controlled — and report p95 rather than a mean. It becomes false if the comparison changes more than one variable, or if the "before" was never a realistic baseline.

<details>
<summary><strong>Detailed answer</strong></summary>

**What a defensible measurement looks like.**

- *A fixed query set* drawn from real usage — the actual mix of clinician note searches, patient guidance lookups, and filtered history queries — not a synthetic query written after the optimisation.
- *Production-shaped data*: 2.4 million notes, real length distribution, real term distribution. Search latency is dominated by the tail of the term frequency distribution, and a uniform synthetic corpus does not have one.
- *The same percentile on both sides.* p95 is the honest one for search, because the mean hides exactly the queries users complain about. Reporting a mean improvement against a p95 problem is the most common way this number is inflated without anyone intending to lie.
- *Controlled cache state.* Filter bitset caches and the operating system page cache make a second run of the same query dramatically faster. Either warm both sides identically or measure cold on both.
- *Enough samples to have a confidence interval*, and the interval quoted alongside the number.

**What would make it false.**

- *Changing more than one thing.* If the migration to Elasticsearch coincided with adding indexes in PostgreSQL and a hardware change, the 35% belongs to the bundle and not to the search layer. Attribution requires isolating the change.
- *An unrealistic baseline.* Comparing a tuned Elasticsearch query against an untuned `LIKE '%term%'` scan proves nothing except that nobody tried. The honest baseline is a reasonably-tuned PostgreSQL full-text query with the appropriate GIN index.
- *A different result set.* If the new path returns ten results and the old returned a hundred, latency fell because the work fell.
- *Measuring the wrong span.* Elasticsearch's own `took` field excludes network, coordination, and the application's scope resolution. The number a clinician experiences is end-to-end, and those are different figures.

**And the qualification the design itself makes.** Latency and relevance are separate claims. Search can get faster and worse at the same time. The 35% latency figure says nothing about whether clinicians find what they need, which depends on the analyzer and the synonym set — clinical work with a named owner. I would present the two numbers separately rather than let a latency improvement imply a quality improvement.

</details>

---

### Q2. Search freshness is p95 under fifteen seconds, composed of three parts. What are they, and what would you do if a note had to be searchable within two seconds?

**Brief answer**
Outbox relay under 2 seconds, plus a bulk flush under 5 seconds, plus a 5-second `refresh_interval`. It is a sum, so tightening one leg alone buys almost nothing — a two-second target means changing all three and paying for it in merge pressure.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it is written as a sum.** Each stage adds its own delay: the outbox relay polls for unpublished rows, the bulk indexer batches until 1000 documents or 5 seconds, and Elasticsearch only makes a document visible to search at the next refresh. Someone asked to "make search fresher" will instinctively tune whichever knob they know about. Dropping `refresh_interval` from 5 s to 1 s while the flush stays at 5 s changes the p95 by almost nothing and costs five times the segment-merge load — a pure loss. Stating the budget as a composed figure is what stops that.

**Reaching two seconds.** All three legs have to move, and each has a price.

- *Relay:* replace polling with a notification-driven relay (`LISTEN`/`NOTIFY` or logical decoding) so publication follows the commit rather than waiting for the next poll. This one is genuinely cheap.
- *Flush:* drop the time trigger to well under a second, which means far smaller batches. Bulk indexing efficiency falls sharply with batch size, so throughput capacity drops and CPU per document rises.
- *Refresh:* to under a second, which multiplies segment creation and therefore merge work. The observable symptom is search p95 rising while indexing looks fine — you have traded read latency for write freshness.

At that point I would expect roughly an order of magnitude more indexing cost for a freshness improvement most users cannot perceive.

**What I would propose instead.** Ask what the two seconds is actually for. Almost always it is one workflow — a clinician saves a note and immediately searches for it, or a test expects it. Both have cheaper answers. For the user-visible case, read-your-writes can be served from `pg-clinical` for the author's own recent writes and merged into the search results, so the person who just wrote the note always sees it while everyone else is on the normal budget. For the test case, use Elasticsearch's explicit refresh in test setup rather than reshaping production for a test's convenience.

**And the honest framing.** A global freshness target is expensive; a targeted guarantee for the one case that needs it is cheap. If someone insists on the global number, I would give them the cost estimate — indexing capacity, node count, and the search latency regression — and let them decide with the price in front of them.

</details>

---

### Q3. `es-clinical` is lost entirely — cluster gone, snapshots questionable. Walk me through the recovery, and explain what makes this routine rather than a disaster.

**Brief answer**
Nothing originates in the search index, so it is fully rebuildable from `pg-clinical` and `mongo-content`. Recovery is: serve the labelled fallback, stand up a new cluster, rebuild, reconcile document counts, then swap the alias. The reason it is routine is that the rebuild is rehearsed quarterly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step 0 — degrade visibly.** Search fails over to a clearly-labelled fallback: chronological browse and structured filters served from `pg-clinical`. Clinicians can still reach every record, they just cannot free-text search. Labelling matters — a silently degraded search that returns fewer results is worse than one that says it is degraded, because the clinician trusts the empty result.

**Step 1 — stand up a replacement.** Three data nodes, the index templates from version control, three primaries and one replica per index. Because the mappings are code, this is a deploy, not a reconstruction from memory.

**Step 2 — rebuild from source.** `es-clinical-notes` from `records.visit_note` enriched with `nlp_extractions`; `es-clinical-content` from `content_pages` where `review_state` is `approved`; `es-clinical-history` from appointments, prescriptions, and document titles. Two tuning points during a bulk rebuild: set `refresh_interval` to `-1` and replicas to zero while loading, then restore both — this can halve the load time. Feed it from the partitioned tables in time order so progress is measurable and resumable.

**Step 3 — reconcile before trusting it.** Compare document counts per patient between the new index and the source stores. The nightly reconciliation job already does exactly this comparison, so the tooling exists; the rebuild just runs it as a gate rather than a monitor. A rebuild that quietly dropped a shard's worth of documents produces a search that looks fine and is missing a cohort — the failure I would most want to catch before swap.

**Step 4 — swap the alias.** Clients read through the `clinical-search` alias, so cutting over is an atomic alias update with no client change and an instant rollback.

**What makes it routine.** Three things, and none of them is luck. The store owns no data, which is a design property enforced by the rule that a fact has exactly one owning store. The rebuild is rehearsed quarterly against a scratch environment with the count reconciliation afterwards — and it is rehearsed specifically *because* the reliability design leans on rebuildability as the mitigation for search failure, so leaving it untested would leave that mitigation unproven. And the index is small enough at around 150 GB that a full rebuild is hours, not days. A backup that has never been restored is an assumption, not a control; the same is true of a rebuild path.

**What I would still verify.** That the fallback is exercised regularly, not just implemented. It is the code path nobody runs until the worst day, and it is where I would expect to find the bug.

</details>

---

### Q3. A clinician searches while `pg-clinical` is mid-failover. The scope filter is derived from PostgreSQL. What happens, and what should happen?

**Brief answer**
Scope cannot be resolved, so the search must fail closed with a `503` rather than run unscoped or fall back to a cached scope. Elasticsearch being healthy is irrelevant if the authorization input is unavailable.

<details>
<summary><strong>Detailed answer</strong></summary>

**What actually happens.** Every search resolves the caller's team membership and `care_relationship` rows from `pg-clinical` before building the query. During a zone failover — roughly sixty seconds — that read fails. Because a patient-facing read also writes an `audit_event` row in the same transaction, the read path is coupled to the primary and there is no replica to fall back to. So the request errors. That is correct behaviour, and the design's stated position on consistency versus availability says so explicitly: under partition the record layer returns `503` rather than serving something it cannot fully justify.

**The two tempting wrong answers, and why they are wrong.**

*Use a cached scope.* Team membership is already cached per-request, and extending that to a Redis-backed cache across requests looks harmless. It is not: the entire point of resolving membership fresh is that a clinician removed from a team loses search reach immediately. A scope cache reintroduces a revocation window, and it does so precisely during an incident when a stale scope is least likely to be noticed. If it were ever done, the time-to-live would need to be seconds and the cache would need explicit invalidation on `carerelationship.changed` — at which point it is complexity buying very little.

*Run the search unscoped and filter results afterwards.* This means Elasticsearch returns documents the caller may not see, and correctness now depends on the post-filter being right, including for counts, aggregations, and highlight snippets. It converts a structural guarantee into an application one, in the failure path, which is the worst place to have made that trade.

**What should happen, concretely.** Fail closed with a problem-detail body that says the record service is temporarily unavailable — not "no results", which a clinician will read as "there is nothing there". The distinction between "we cannot answer" and "the answer is empty" is a safety property on a clinical record, and it should be visible in the response shape, not only in a log.

**The wider point.** Availability composes multiplicatively across a dependency chain, and search's real availability is bounded by the availability of the thing that authorizes it. Search carries a 99.5% objective while the record carries 99.9%, and the honest reading is that search cannot exceed the record's availability no matter how healthy its own cluster is. That is worth stating in a design review, because a team that measures Elasticsearch uptime alone will report a number that its users do not experience.

</details>

---

### Q3. Notes grow tenfold, to roughly 24 million. What changes in the index design, and what stops being true?

**Brief answer**
Three primary shards sized for 150 GB no longer fit, so the notes index needs resharding and probably a time-based index strategy with an alias. What stops being true is that a full rebuild is a routine operation — at 1.5 TB it becomes a planned procedure.

<details>
<summary><strong>Detailed answer</strong></summary>

**Shard sizing.** The working guidance is tens of gigabytes per shard, and shard count is fixed at creation, so at ten times the volume the notes index needs more primaries. The move is a reindex into a new index and an alias swap — cheap here only because clients read through the `clinical-search` alias and nothing addresses the concrete index name.

**Time-based indices become worth it.** At this size I would split notes into monthly or quarterly indices behind the alias. Clinical search is overwhelmingly recent-weighted, so a date filter lets the coordinating node skip whole indices; older indices can move to cheaper nodes or be force-merged into a single read-only segment; and a mapping change stops meaning a rewrite of everything, only of new indices. The cost is more shards to manage and cross-index queries to reason about, and I would not take it at 2.4 million notes — which is why the current design does not.

**What stops being true, and this is the important half.** "Fully rebuildable from source, and a rebuild is routine" is load-bearing in the reliability design: it is the stated mitigation for losing the cluster, and the reason the search store is allowed to have a weaker backup target than everything else. A 1.5 TB rebuild from `pg-clinical` is no longer hours — it is a long, database-loading operation that competes with production traffic on the same primary that also serves every audited read. So at that scale the mitigation has to be re-earned: snapshot restore becomes the primary recovery path with rebuild as the backstop, the rebuild source becomes a replica or a restored copy rather than the live primary, and the quarterly rehearsal has to actually be run at the new size rather than assumed to scale.

**What I would watch for on the way there.** Merge pressure rising with indexing volume, which shows up as search p95 degrading while indexing metrics look healthy. Field data and mapping explosion if `entities` grows unbounded from the extraction pipeline — a `keyword` field with millions of distinct values is fine, but a mapping that grows a field per entity type is not. And the reconciliation job's own runtime, since a per-patient count comparison across 24 million documents is itself a job that needs to be incremental rather than a nightly full sweep.

**The framing I would give a lead.** The current design is correctly sized for its stated load and says so; scaling it tenfold is not a tuning exercise but a re-derivation, and the first question is whether note volume really grew tenfold or whether one cohort did — because the answer changes whether this is a sharding problem or a retention problem.

</details>

## FastAPI Service Design and Performance Under Load

---

### Q1. In FastAPI, what is the difference between declaring an endpoint `async def` and declaring it `def`?

**Brief answer**
An `async def` endpoint runs on the event loop in the main thread; a plain `def` endpoint is run in a bounded worker threadpool so it cannot block the loop. The dangerous case is neither of those — it is blocking code inside an `async def`.

<details>
<summary><strong>Detailed answer</strong></summary>

[FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") sits on Starlette and the Asynchronous Server Gateway Interface ([ASGI](https://asgi.readthedocs.io/en/latest/ "Standard interface between asynchronous Python web servers and applications")). When you declare `async def`, your coroutine is scheduled directly on the event loop; every `await` yields control so other requests progress. When you declare `def`, Starlette runs the function in an `anyio` threadpool — by default 40 threads — so synchronous work does not stall the loop. Both are legitimate. Choosing `def` for a genuinely blocking library is the *correct* choice, not a fallback.

The failure is putting blocking code in an `async def`: a synchronous database driver, `requests`, `time.sleep`, a CPU-heavy loop, or an ordinary file read. Nothing yields, so the single event loop thread stops serving every other in-flight request for that duration. One 500 ms blocking call in an async handler at moderate concurrency turns into seconds of tail latency across unrelated endpoints. It does not raise, it does not log, and it looks like "the service got slow" — which is why it is usually found by tracing rather than by reading code.

Two second-order effects worth knowing. The threadpool is bounded, so a service where every endpoint is `def` and every handler takes 100 ms tops out at roughly 400 requests per second regardless of pod resources — the threadpool becomes the capacity limit and the symptom is queueing, not CPU saturation. And dependencies follow the same rule: a `def` dependency runs in the threadpool even for an `async def` endpoint, so a synchronous authorization check quietly consumes threadpool capacity on every request.

The rule I apply: pick one model per call path and be deliberate. If the data access layer is synchronous, make the endpoints `def` and size the threadpool against measured handler duration. If it is async, make it async all the way down and treat any synchronous library as something that must be wrapped explicitly.

</details>

---

### Q1. What does Pydantic actually do on each request, and what does it cost?

**Brief answer**
It parses and validates the request body against a declared model, coerces types, and produces a typed object — then does the reverse on the way out. The cost is real but small since Pydantic v2 moved the core to Rust; the larger cost is usually response serialization on big payloads.

<details>
<summary><strong>Detailed answer</strong></summary>

Pydantic compiles each model once into a validator, then runs it per request: parse JavaScript Object Notation ([JSON](https://www.json.org/json-en.html "Lightweight text format for structured data exchange")), check types, apply constraints and custom validators, and build the model instance. FastAPI uses the same machinery for responses when `response_model` is declared, which additionally *filters* the output to the declared fields — that filtering is a security feature, not a formality, because it is what stops an internal field added to a database model from leaking into an API response.

Why it earns its place here beyond convenience: the models are the contract. The [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document FastAPI emits is generated from them and is contract-tested in continuous integration, so the schema the frontend generates its client from cannot drift from what the server actually accepts. The System for Cross-domain Identity Management ([SCIM](https://scim.cloud/ "Standardizes automated provisioning and deprovisioning of user identities between systems")) 2.0 schemas are Pydantic models too, which makes an externally-specified protocol executable rather than documented. And the sensitive-field marks that the logging redaction filter reads live on the models, so "this field must never be logged" is declared once next to the field rather than remembered at every log call.

**Costs and where they bite.** v2's Rust core made validation roughly an order of magnitude faster than v1, so input validation is rarely the bottleneck. Response serialization of large collections can be — returning a page of 500 timeline entries through a `response_model` does real work per item. Mitigations in rough order of preference: keep pages small (cursor pagination already does), avoid deeply nested response models where a flat one will do, and only in a genuinely hot path consider bypassing the response model in favour of a pre-serialized payload — accepting that you have then given up the output filtering, which on a patient record is a trade I would want written down rather than made quietly.

The other cost is subtler: over-permissive coercion. Pydantic will happily turn `"3"` into `3` unless you configure strictness, and on a clinical field that silent acceptance can mask a client bug. Strict mode on the fields where it matters is worth the extra rejections.

</details>

---

### Q1. What is a modular monolith, and how is it different from a monolith that simply has not been split yet?

**Brief answer**
A modular monolith enforces internal boundaries — separate packages, separate database schemas, and no cross-module imports except through a published interface — while deploying as one unit. The difference from an unsplit monolith is that the boundaries are enforced, not aspirational.

<details>
<summary><strong>Detailed answer</strong></summary>

`care-core` has four modules: `diary`, `records`, `clinical-content`, and `identity`. Each owns a PostgreSQL schema of the same name, each is a separate Python package, and cross-module access goes through a published in-process interface rather than by importing another module's internals or querying its tables. So the boundary that exists in the code also exists in the database, and neither can decay into a shared-table free-for-all without someone deliberately breaking the rule.

**What that buys.** The modules share a transaction, which is the whole reason for staying in one process: recording a visit note and writing its outbox event and its audit row is one commit, not a distributed saga. Refactoring across a boundary is a compiler-and-test-suite exercise rather than a coordinated release. And when a module genuinely needs to leave, its data and its interface are already separated, so extraction is a deployment change rather than an archaeology project.

**What it costs.** One release blocks another's features — a change in `diary` that fails a gate holds up a `records` fix. That is a real price and the design names it. It was accepted because at around 200 requests per second peak with one team, distributed transactions across four services would buy latency and on-call load for no throughput gain.

**How the boundary is actually kept.** This is the part that separates a modular monolith from a monolith with good intentions. Enforcement has to be mechanical: an import-linter rule in the pipeline that fails the build on a forbidden cross-module import, and per-schema database roles so a module physically cannot read another's tables. Without a gate, module boundaries erode at exactly the rate of deadline pressure — and then the architecture diagram describes something that stopped being true a year ago.

**The two exceptions prove the rule.** `scim-provisioning-svc` and `clinical-nlp-svc` were extracted because each has a release driver outside the team's control: the hospital directory's cadence and the model release cycle. Neither left for throughput. "It has an independent reason to be deployed on a different schedule" is a much better extraction criterion than "it feels like a separate thing".

</details>

---

### Q1. What does moving to Python 3.14 with Poetry-managed dependencies actually give you, and what is the risk?

**Brief answer**
[Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects")'s lockfile pins the full resolved dependency graph including transitive packages and hashes, so the image you test is the image you deploy. Pinning the interpreter version identically across services removes a class of "works in one module" bug. The risk is that a major interpreter bump exposes native-extension incompatibilities.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the lockfile is for.** A `requirements.txt` with loose bounds resolves differently depending on when the build runs, so a rebuild of an unchanged commit can produce a different image — the deploy-time surprise this migration removed. `poetry.lock` records the exact resolved version and hash of every direct and transitive dependency; installing from it is reproducible and hash-verified, which is also a supply-chain property, since a package swapped upstream fails the hash check rather than silently installing.

Per-service lockfiles matter here because `care-core`, `scim-provisioning-svc`, and `clinical-nlp-svc` have genuinely different dependency sets — the [NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Natural Language Processing — Computational techniques for analyzing and generating human language") service pulls a deep machine-learning stack that has no business in the API image. Separate locks keep the API image small and its attack surface narrow, while the pinned interpreter version keeps runtime behaviour identical across all three.

**Where the risk lives, and it is not the pure-Python code.** A major interpreter version bump is mostly painless for application code and painful for compiled extensions: database drivers, cryptography, `numpy`-adjacent packages, and machine-learning wheels. If a wheel is not published for the new version, the build either falls back to compiling from source — slow, and dependent on toolchain packages being in the image — or fails. That is where a version migration actually stalls.

**How I would run it.** One service at a time, starting with the one with the shallowest dependency tree, on a branch with the full pipeline green before merging. Check wheel availability for the whole locked graph before starting, because that is the go/no-go and it takes minutes to determine. Run the integration suite against real containers, since native driver behaviour is exactly what a mocked test will not exercise. And update the lockfile and the base image in one commit, so the interpreter and the packages built against it never disagree.

**The honest caveat.** Very recent interpreter releases lag on ecosystem support, particularly for the machine-learning stack. If the NLP service's dependencies were not ready, the correct answer is to move the API services and leave that one behind temporarily — the lockfiles are per-service precisely so that is possible — rather than block the migration or pin an unsupported build.

</details>

---

### Q2. Suppose the service is a synchronous FastAPI application under heavy enterprise load and you cannot rewrite it to async. How do you optimise it?

**Brief answer**
Measure where the time goes first, then size the threadpool and the process model against measured handler duration, cut per-request database work, and push slow work off the request path. A synchronous stack scales perfectly well — it just scales on different knobs than an async one.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, establish the shape of the load.** Concurrency, not throughput, is what breaks a synchronous stack. With Little's Law, required concurrency equals arrival rate times average latency — 200 requests per second at 150 ms is about 30 concurrent requests, which is comfortable; the same rate at 800 ms is 160, which is not. So the first artefact I want is p50/p95 handler duration by route from Prometheus, and the span breakdown from Elastic APM showing how much of it is database, how much is an outbound call, and how much is actually Python.

**Then the knobs, in the order they pay.**

1. **Threadpool size.** In a synchronous FastAPI app every handler runs in the `anyio` threadpool, default 40 threads. If handlers are input/output-bound at 100 ms, that pool caps you near 400 requests per second per process no matter what the CPU does. Raising it helps until context-switching and — more often — the database connection pool becomes the real limit. This is the single most common misconfiguration and it presents as queueing latency with idle CPU.
2. **Connection pooling.** Threads are useless without connections. Pool size per pod times pod count must stay under the database's connection limit, which is the constraint people discover during an autoscaling event. A transaction-mode pooler in front is usually the right answer — with the `SET LOCAL` caveat that makes row-level security safe under connection reuse.
3. **Worker processes.** Because of the Global Interpreter Lock ([GIL](https://wiki.python.org/moin/GlobalInterpreterLock "CPython mechanism that lets only one thread execute Python bytecode at a time")), one process uses one core for Python bytecode. Run roughly one Uvicorn worker per available core (or several single-worker pods, which is friendlier to Kubernetes autoscaling), and size the container's CPU request accordingly.
4. **Cut per-request work.** This is where the real wins usually are and they are not framework-level: N+1 query patterns from lazy loading, serialization of oversized responses, an authorization check that re-queries what the request already loaded, a chatty external call in the hot path. One removed N+1 typically beats every tuning knob above.
5. **Take work off the request path entirely.** The pattern this whole platform is built on — accept, enqueue, return `202`. Reminders, indexing, and page generation are asynchronous not because async is fashionable but because they do not belong in a request.
6. **Cache with an invalidation rule you can state.** The timeline cache is cache-aside with a 60-second time-to-live and explicit invalidation on any record write for that patient. A cache without a stated invalidation rule is a correctness bug scheduled for later.

**What I would not do.** Rewrite to async as the opening move. It is a large, risky change that fixes only the case where the bottleneck is thread-count for input/output waiting — and if the real limit is the database connection pool or an N+1, async makes the problem arrive faster rather than removing it. I would want a profile that specifically shows threadpool saturation with idle CPU and headroom in the database before proposing that rewrite, and I would expect to say so to a lead who asked for async on principle.

</details>

---

### Q2. Someone adds a blocking call inside an `async def` endpoint. Describe the symptom and how you would find it.

**Brief answer**
Unrelated endpoints get slower and their p95 develops a plateau, while CPU sits low — because one coroutine is holding the event loop. Elastic APM span timing finds it, and `asyncio` debug mode names it directly.

<details>
<summary><strong>Detailed answer</strong></summary>

**The symptom, and why it misleads.** Latency rises on endpoints that have nothing to do with the change, because the event loop serves all of them. The p95 develops a step rather than a slope — it plateaus around the duration of the blocking call, since that is how long every queued request waits. CPU utilisation stays low, which is the confusing part: the process looks idle while requests queue. If you only watch CPU and request rate you will conclude the service is healthy and start looking at the database.

**How I would find it.**

- *Elastic APM first.* The transaction breakdown shows a large span of time not attributed to any instrumented operation — no database span, no Hypertext Transfer Protocol ([HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Application protocol used to request and transfer web resources")) span, just unaccounted duration. That gap is the blocking call. Because the agent auto-instruments SQLAlchemy and outbound HTTP, anything it cannot see is a strong hint on its own.
- *`asyncio` debug mode* in a non-production environment logs any callback that occupies the loop beyond a threshold, with a traceback. That turns a hypothesis into a filename and line number in one run.
- *Correlate with deploys.* A step change in p95 on an unrelated route at a deploy boundary is the shortest path to the commit.
- *Reproduce under concurrency.* A blocking call is invisible with one request at a time. The load test that shows it needs concurrency at least equal to the number of workers.

**The fixes, in order.** If the library has an async equivalent, use it. If not, wrap the call in `run_in_threadpool` so it leaves the loop — or, honestly, just declare the endpoint `def` and let Starlette do that for you, which is simpler and is exactly what that mechanism exists for. For genuinely CPU-bound work, neither helps: threads do not escape the Global Interpreter Lock, so it belongs in a Celery task or a separate process.

**How I would stop it recurring.** This is a class of bug that review catches unreliably, because the offending line looks completely normal. The durable answers are structural: keep the synchronous data-access layer out of async handlers by construction, and add a load-test assertion on a fast endpoint's p95 while a slow endpoint is being hammered — a test that fails when the loop is blocked, rather than a rule people are asked to remember.

</details>

---

### Q2. Only SCIM provisioning and clinical NLP were extracted as services. Defend that boundary, and tell me what would make you extract a third.

**Brief answer**
Each left for a release driver outside the team's control — the hospital directory's cadence and the model release cycle — not for throughput. I would extract a third only when it has an independent release driver, a hardware requirement, or an isolation requirement that the monolith cannot satisfy.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why these two.** `scim-provisioning-svc` implements an externally-specified protocol consumed by the hospital's Azure Entra ID tenant. When the hospital changes its provisioning configuration, this service changes — on their schedule, not the product's. Bundling it into `care-core` means a directory-driven fix waits for the product release train, and a product release risks the identity path that gates every clinician's access. `clinical-nlp-svc` needs Graphics Processing Unit (GPU) nodes and ships on a model's schedule; its dependency stack is enormous and has no place in the API image; and model rollout wants a canary with statistical comparison, which is a completely different deployment strategy from the record service's blue-green.

**Why nothing else left.** `diary`, `records`, `clinical-content`, and `identity` share transactions and change together. Splitting `records` from `diary` would turn "write the check-in and its outbox event and its audit row" into a distributed transaction, and at around 200 requests per second there is no throughput argument to pay for that with. The design is explicit that a microservice fleet at this scale buys latency and on-call burden for nothing.

**The extraction criteria I would actually apply, in order.**

1. *An independent release driver.* Something outside the team dictates when it changes.
2. *A different hardware or runtime requirement.* GPUs, or a dependency set that would bloat every other image.
3. *A different failure or isolation requirement.* A component that must survive when the rest does not, or must not be able to take the rest down.
4. *A genuinely different scaling curve*, with measurements — not an expectation.

Notably absent: team size, code size, and "it feels like its own domain". Those produce services that are deployed together, released together, and fail together, with network calls added.

**What would trigger a third extraction here.** The most plausible candidate is `audit` — but as a datastore move rather than a service, and the evolution triggers already say so. A second candidate would be document ingestion if it grew beyond `fn-blob-ingest` into a real pipeline with its own scaling profile. The one I would resist is extracting `records`, because it holds the transaction everything else joins.

**And the reverse move, which people forget is available.** If GPU inference moves to a managed endpoint, `clinical-nlp-svc` and the entire `aks-ml` cluster collapse back into `aro-primary` — the design deliberately keeps no state there so that stays possible. Being able to state the condition that reverses an expensive decision is, to me, the mark of a decision that was actually made rather than defaulted into.

</details>

---

### Q2. The frontend team generates its client from your OpenAPI document. What counts as a breaking change, and how do you stop one reaching them?

**Brief answer**
Anything that invalidates a previously-valid client: removing or renaming a field, narrowing a type, adding a required request field, changing an enum's members, or changing status-code semantics. The defence is a schema diff gate in the pipeline plus contract tests, not a review convention.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the contract is load-bearing here.** The frontend generates typed clients and hooks from the OpenAPI document — with Orval or an equivalent generator — so the schema is not documentation, it is the frontend's source code. A silent schema change does not produce a runtime error somebody notices; it produces a regenerated client that no longer compiles, or worse, one that compiles and sends a field the server now ignores. The document is emitted from the Pydantic models, which is a real advantage: the schema cannot drift from what the server actually accepts, because it is derived from the same objects that validate the request.

**What breaks a generated client.**

- Removing a response field, or renaming one — the generated type no longer matches.
- Narrowing a type or making a nullable field non-nullable in a request, or the reverse in a response.
- Adding a **required** request field. Adding an optional one is safe.
- Changing enum members. Adding a value is breaking for a client that exhaustively switches on it, which typed generators encourage — this one surprises people.
- Changing which status codes an operation can return, or the error body shape. The design uses [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details, which helps only if it is applied consistently.
- Changing an `operationId`, which usually renames the generated function.

**How to stop it.** Three mechanisms, none of which is "be careful".

1. **A schema diff gate.** Generate the OpenAPI document in the pipeline, diff it against the committed baseline, and fail the build on a breaking change unless the merge request carries an explicit acknowledgement. This makes the conversation happen before merge rather than after deploy.
2. **Contract tests as a blocking gate.** Already part of the pipeline: they assert the emitted schema against expectations, so a model change with no intent behind it fails.
3. **Version at the path, evolve additively within it.** `/api/v1` exists; breaking changes go to `/api/v2` with both served during migration. Within a version, only additive changes.

**And the human half, which matters more than any of it.** For a genuinely necessary breaking change, the schema diff is the artefact I would take to the frontend leads *before* implementing — here is the change, here is what it breaks in your generated client, here is the window where both versions are served. Blue-green deployment of `care-core` makes running both cheap. Discovering the break in their build is a worse start to the conversation than opening it with a diff, and given a client that values thoroughness over speed, that is the sequencing they would expect.

</details>

---

### Q2. Every `POST` mutation requires an `Idempotency-Key`. How would you implement that correctly, and where does it fail?

**Brief answer**
Store the key with the completed response, return the stored response on a repeat, and reject a repeat that carries a different body. It fails when the cache holding the keys is lost — which is why anything that must not double-apply also has a natural key in PostgreSQL.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** On arrival, look up `idem:{key}` in `redis-cache`. If a completed response is stored, return it verbatim with the original status code — the client gets exactly what it would have got, so a retry after a network timeout is transparent. If the key is present but marked in-flight, return `409` rather than processing concurrently. If absent, claim it atomically (`SET NX`), process, and store the response with a 24-hour time-to-live.

**The details that are easy to get wrong.**

- *Claim before processing, not after.* Otherwise two concurrent retries both find nothing and both execute.
- *Bind the key to the request body.* Store a hash of the payload with the key; if a client reuses a key with a different body, that is a client bug and should return `422`, not silently replay an unrelated response.
- *Scope the key to the authenticated subject.* A globally-scoped key namespace lets one caller's key collide with another's — and on a patient record, replaying a stored response across subjects is a disclosure.
- *Store the response, not just a flag.* A retry that gets `200` with an empty body is not idempotent from the client's point of view.
- *Decide what happens on a failed request.* If processing raised, the key should generally be released so a retry can genuinely retry; if it half-succeeded, the underlying operation needs to be idempotent anyway.

**Where it fails, and the honest framing.** These keys live in Redis, which holds nothing durable. A flush, a failover, or an eviction under memory pressure loses them, and a duplicate `POST` is then reprocessed. So the key mechanism is an *optimisation* for duplicate suppression, not a guarantee — the design says so explicitly rather than implying Redis is a correctness store.

**What makes it actually safe.** Any mutation that must not double-apply carries a natural key in `pg-clinical`: `(patient_id, recorded_for)` for a check-in, `reminder_delivery_id` for a dispatch. The database makes it idempotent; the cache makes it fast and gives the client a clean replay. That layering is the point — a cache that is load-bearing for correctness is a correctness bug waiting for a maintenance window, and the way to find out whether a system has made that mistake is to ask what happens when the cache is flushed.

</details>

---

### Q3. Size the service for 200 requests per second sustained with 400 burst on a synchronous stack. What fails first?

**Brief answer**
Concurrency is what matters: at 200 requests per second and 150 ms mean latency you need about 30 concurrent slots, at 400 burst about 60. The first thing to fail is almost never CPU — it is the database connection pool, then the threadpool, then the pod's memory.

<details>
<summary><strong>Detailed answer</strong></summary>

**The arithmetic.** Little's Law: concurrency = arrival rate × latency. 200 requests per second × 0.15 s ≈ 30 in flight; the 400 burst ≈ 60. But the mean is the wrong number to provision against — you provision against the tail, because the slow requests are the ones occupying slots. If p95 is 400 ms, the tail alone contributes 200 × 0.05 × 0.4 = 4 more concurrent slots, and during an incident where p95 becomes 2 s that same 5% needs 20. Headroom is not generosity, it is what absorbs latency excursions without queueing.

**Provisioning from that.** Run several pods each with a single Uvicorn worker rather than one pod with many workers — it gives the Horizontal Pod Autoscaler a real unit to scale and keeps a crash's blast radius to one worker. Six to eight pods with a threadpool sized to about 20 gives comfortable headroom at 60 concurrent, and the CPU request follows from measured per-request CPU time, not from the concurrency number.

**What fails first, in the order I would actually see it.**

1. **Database connections.** Pool size per pod × pod count is the number that hits `max_connections`, and it hits it during an autoscaling event — precisely when you most need the new pods. Eight pods with a pool of 20 is 160 connections before anything else in the estate has asked for one. A transaction-mode pooler in front is the standard answer, with `SET LOCAL` for the row-level security session variables so connection reuse cannot leak identity.
2. **Threadpool saturation.** Presents as rising queueing latency with low CPU. Easy to fix once identified, easy to misdiagnose as a database problem.
3. **Memory.** Each thread has a stack and each in-flight request holds its parsed request, its ORM identity map, and its response. A large paginated response times 60 concurrent requests is where an out-of-memory kill comes from — and the kill takes the whole pod, including the 59 healthy requests.
4. **The primary database itself**, since every audited patient read is a write and cannot go to a replica. At 200 requests per second that is comfortable; it is the ceiling that matters at 10×.

**What I would do before believing any of this.** Load test at 400 requests per second against the real stack in Docker Compose — real PostgreSQL, real broker, real Elasticsearch — because the failure I am trying to find is a resource interaction and a mocked dependency cannot produce one. The number I want out of it is not "it survived" but "which resource saturated first", because that determines the autoscaling signal. Scaling on CPU when the limit is the connection pool means the autoscaler adds pods that make the problem worse.

</details>

---

### Q3. `care-core` deploys blue-green, so both versions run against one database. What does that constrain beyond migrations?

**Brief answer**
Everything shared between the two colours: the schema, the cache keyspace, the message formats on `care.events`, and in-flight Celery task signatures. Anything one colour writes and the other reads must be understood by both.

<details>
<summary><strong>Detailed answer</strong></summary>

**The schema** is the well-known one — expand/contract, every state backwards-compatible, `alembic upgrade head` in the ArgoCD PreSync hook so the schema leads the code. But it is not the only shared surface, and the others are the ones that bite.

**The cache keyspace.** If the new version changes the shape of what it stores under `tl:{patient_id}:{window_hash}`, the old version reads a structure it does not understand — a deserialization error at best, a wrong render at worst. The fix is to version the cache key, not the value: a new value shape gets a new key prefix, so the two colours simply do not share entries and the old ones expire. The design's content page key already carries the version for a related reason, and the same discipline applies to any shape change.

**Message formats on `care.events`.** During cut-over, blue publishes and green consumes, and vice versa. So a new required field in an event payload breaks a consumer that has not been deployed — and message schema changes are less visible than API schema changes because there is no generated client to fail to compile. Events evolve additively, consumers ignore unknown fields, and a required field arrives in two releases exactly like a database column.

**In-flight Celery tasks.** A task enqueued by the old version may be executed by a new worker, so task signatures cannot change in one release. Renaming a task, changing its arguments, or removing it strands whatever is already on the queue — and `celery.reminders` always has work in flight. Same rule: add the new task, migrate producers, remove the old one a release later.

**Long-running requests during the switch.** The Route switch is instantaneous but in-flight requests on the old colour are not. Connection draining with a grace period longer than the slowest request, plus a `preStop` hook, is what stops the cut-over from producing a burst of 502s.

**The unifying rule.** Blue-green means the *shared* state must tolerate two versions of the code simultaneously — schema, cache, messages, queues. The reason to accept that constraint is what it buys: the cleanest possible rollback for the service that holds the clinical record, which is an ArgoCD revision revert with no down-migration and no data reconstruction. On a system where a bad release could corrupt or expose patient data, that rollback property is worth more than the freedom to make breaking changes in one step.

</details>

---

### Q3. At ten times the load, would you extract `records` into its own service? What would you want to see first?

**Brief answer**
Probably not — 2,000 requests per second is still not a scale that requires distribution, and `records` holds the transaction the other modules join. I would want evidence that vertical scaling and the documented storage extractions are exhausted before paying for a distributed record.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the instinct is wrong here.** 10× is roughly 2,000 requests per second peak. Stateless FastAPI pods scale horizontally to that without architectural change; the constraint is the database, and the design already names the order for relieving it — extract `audit_event` first, then `wellbeing_checkin`, and only then consider sharding. Extracting `records` as a service does not relieve database load at all. It moves API compute that was already horizontally scalable, and adds a network hop to the query the clinician runs most.

**What extracting `records` would actually cost.** The timeline is a union across five tables, three of which are owned by other modules; across a service boundary it becomes a scatter-gather with partial-failure semantics on the product's most important read. The visit-note write currently commits the note, its outbox event, and its audit row in one transaction; split, that becomes a distributed write and the audit guarantee — the one the design refuses to weaken — needs a new mechanism. And row-level security enforces authorization in the database on the assumption that the actor identity is set in the transaction touching the data; two services each setting their own session context is a larger surface for exactly the leak the `SET LOCAL` rule exists to prevent.

**What would change my mind.** Any of the extraction criteria actually being met, with evidence:

- *An independent release driver* — for example a regulatory integration forcing `records` onto an external schedule.
- *A measured, divergent scaling curve*: `records` saturating a resource the other modules do not touch, shown in profiling rather than assumed.
- *An isolation requirement*: `records` must stay available when the rest is degraded, or must not be able to take the rest down.
- *Team structure* — genuinely separate teams with separate on-call, where the coordination cost of a shared deployable is measurably worse than the coordination cost of a network boundary. This is a legitimate reason and it is usually the real one; I would just want it stated honestly rather than dressed as a performance argument.

**What I would do instead at 10×.** Take the storage extractions in the documented order, add read capacity where reads are not audited, and revisit the synchronous-audit trade-off — because at that scale, coupling every patient read to the primary is the constraint that actually binds, and it is a security decision to re-examine with the security owner rather than an architecture decision to make alone.

</details>

---

### Q3. A frontend change needs a request field that is required, but existing clients do not send it. Ship it.

**Brief answer**
In two releases. First accept it as optional with a defined behaviour when absent, deploy, and let the generated clients update; then make it required once telemetry shows no traffic without it. Never both in one release, because blue-green runs both versions at once.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why one release cannot work.** During blue-green cut-over both images serve traffic. If green requires the field and blue's clients do not send it, requests fail for the duration of the switch — and a rollback to blue does not help clients that already updated if the field also became required in the persisted shape. The same reasoning as expand/contract migrations, applied to the API surface.

**The sequence.**

1. **Add it optional**, with an explicitly defined meaning when absent — a default, or a documented degraded behaviour. "Optional with undefined behaviour" is not a step, it is a bug with a schedule.
2. **Ship and regenerate.** The schema diff shows an additive change, so the gate passes without an override, and the frontend regenerates a client where the field is optional. They adopt it on their own timeline.
3. **Measure.** Count requests arriving without the field, by client version, from the existing request metrics. This is the step that turns "I think everyone has updated" into evidence, and it is the one most often skipped.
4. **Make it required** once that count is zero and has been zero for longer than the longest plausible client cache or app-store update window. Mobile clients are the constraint here — a patient who has not updated the app in six weeks is a normal patient, not an edge case.
5. **Then** tighten the persisted shape if it needs tightening, as a separate database expand/contract.

**If it genuinely cannot be optional** — the field is required for correctness and guessing a default would be wrong — then it is a new version of the operation, or `/api/v2`, with both served during migration. That is more work and it is the honest answer rather than shipping a break and calling it a fix.

**The conversation, not just the mechanism.** With a frontend team generating typed clients, I would bring them the schema diff and the two-release plan before writing the code, and agree the window. On a project where thoroughness is valued over speed, arriving with "here is the change, here is what it breaks, here is the sequence and the date I need you by" is the version of proactivity that helps — as distinct from shipping quickly and letting their build discover it.

</details>

## Identity, Provisioning, and Access Control

---

### Q1. What is SCIM 2.0, and what does it solve that OAuth 2.0 does not?

**Brief answer**
OAuth answers "is this person authenticated right now"; SCIM answers "which accounts should exist at all". SCIM is a lifecycle protocol — the directory pushes creates, updates, and deactivations into the application, so access ends when employment ends without anyone in the product doing anything.

<details>
<summary><strong>Detailed answer</strong></summary>

OAuth 2.0 with [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect gets a clinician a token at sign-in. It says nothing about the account existing beforehand, about their role, or about what happens the day they leave the trust. Without provisioning you end up with just-in-time account creation on first login and manual deactivation afterwards — and manual deactivation is the step that does not happen. A clinician who left three months ago still has an account, and nobody notices until an audit.

SCIM 2.0 is a REST protocol with a defined schema for `Users` and `Groups` and defined semantics for create, update, patch, and deactivate. Azure Entra ID is the identity provider and the sole authorized caller of `scim-provisioning-svc`, authenticated with its own client credential and network-restricted. `active: false` in a `PATCH` maps to deactivating the `clinician` row, and — this is the part that matters clinically — it closes every open `care_relationship` for that clinician **in the same transaction**. Access to patient records ends atomically with the deactivation, not on a nightly sweep.

Two implementation notes that separate a working SCIM endpoint from a nominal one. `PATCH` semantics are the fiddly part of the specification — path expressions, multi-valued attribute operations, and `add`/`replace`/`remove` on sub-attributes — and identity providers differ in what they actually send, so this is a place to test against the real provider rather than the specification alone. And operations must be idempotent, because a provider that times out will retry; that is what the `lock:scim:{entra_object_id}` serialization lock in Redis is for, so two concurrent operations on the same user cannot interleave.

The operational consequence the design draws: SCIM sync failure is a **paged** alert, not a dashboard number. A silent failure means a deprovisioning that did not land — access that should have ended and has not — which is a security event, not a background job that will catch up.

</details>

---

### Q1. Clinician and patient tokens are separate audiences checked at the gateway. Why is that stronger than checking the user's role in application code?

**Brief answer**
Because it fails closed before application code runs. A clinician token presented on a patient-portal path is rejected at Azure API Management ([APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Publishes, secures and rate limits APIs behind a managed gateway")) with a `403`, so a routing mistake or a missing role check inside the application cannot expose the wrong plane.

<details>
<summary><strong>Detailed answer</strong></summary>

There are two identity planes with genuinely different trust models. Patients self-register into an Entra External ID tenant with identity proofing at enrolment, and receive tokens with audience `api://care-platform/patient`. Clinicians exist only because the hospital directory provisioned them — never self-service — and receive `api://care-platform/clinician`, with multi-factor authentication enforced by the hospital's conditional access, which the platform does not weaken.

The brief's requirement that clinician accounts "stay off the patient portal" could have been implemented as a role check in a dependency. The reason it is an audience check at the gateway instead is defence in depth with a specific ordering property: the check runs before any application code, so it holds even for a route someone forgot to decorate, a route added in a hurry, or a route whose role check was written against the wrong enum member. Those are the realistic failure modes, and an audience mismatch is not something the application can get wrong because the application never sees the request.

`care-core` re-validates the token rather than trusting a gateway-set header. That matters: if the only validation is at APIM and the application trusts a header, then anything that reaches the pods directly — a misconfigured network policy, a port-forward, a compromised sidecar — bypasses authentication entirely. Re-validating means a bypass of the gateway is not a bypass of authentication, only of rate limiting.

What this does *not* do is authorize the request. The audience check says "this is a clinician on a clinician path". It says nothing about whether this clinician may see *this* patient — that is the `care_relationship` check, enforced in the database by row-level security. Keeping those two separated is deliberate: coarse plane separation at the edge where it is cheap and unconditional, fine-grained reach in the database where it cannot be forgotten.

</details>

---

### Q1. What is row-level security, and how is it different from filtering by patient in application code?

**Brief answer**
Row-level security is a PostgreSQL feature that attaches a predicate to a table so every query is automatically constrained, regardless of what the query says. The difference is the failure mode: a forgotten scope in application code returns another patient's record, whereas with row-level security it returns nothing.

<details>
<summary><strong>Detailed answer</strong></summary>

With `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` and a policy, PostgreSQL rewrites every query against that table to include the policy's predicate. Here the predicate joins through `care_relationship` — the temporal table whose `valid_period` says when a clinician's access to a patient started and ended — using session variables set inside the request transaction (`app.actor_id`, `app.actor_kind`). Application-layer checks still exist, but they are the second line.

**Why the failure mode is the whole argument.** Application filtering fails open: a developer writes a query without the patient predicate, it passes review because it reads plausibly, tests pass because the test fixture has one patient, and it returns everything. Row-level security fails closed: the same forgotten predicate returns zero rows. A developer notices an empty result set within minutes; nobody notices an over-broad one until a patient complains or an audit finds it. Converting the most common class of application bug into an empty result set is the single most valuable property in this design.

**Three implementation details decide whether the control is real**, and each is asserted by a test rather than left to review:

- The session variable is set with **`SET LOCAL`** inside the transaction. A plain `SET` persists on a pooled backend and leaks one caller's identity into the next caller's query — turning the strongest control into its exact inverse. A pooled-connection leakage test asserts it.
- The application role is `NOSUPERUSER` and lacks `BYPASSRLS`; migrations run as a separate owning role that never serves a request. A privilege that quietly grew would disable every policy without changing a line of application code, so a role-privilege assertion runs in the pipeline.
- Policies keep the `patient_id` predicate reachable by the planner, so partition pruning survives on the monthly-partitioned tables. An `EXPLAIN` assertion guards the plan shape.

**And the boundary of the control.** Row-level security protects PostgreSQL. It does nothing for Elasticsearch, which is why search carries mandatory scope fields and a filter injected from the same `care_relationship` table — one definition of reach, projected into the second store, rather than a second definition that can drift.

</details>

---

### Q2. A clinician leaves the trust. Trace what happens, end to end.

**Brief answer**
Entra ID sends a SCIM `PATCH` setting `active: false`; `scim-provisioning-svc` deactivates the `clinician` row and closes every open `care_relationship` in the same transaction. Record access ends immediately through row-level security; search reach ends on the next query because membership is resolved fresh.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence.**

1. Human Resources marks the leaver in the hospital's directory. Nothing in this product is involved in that decision, which is the point.
2. Entra ID calls `PATCH /scim/v2/Users/{id}` with `active: false`. It authenticates with its own client credential, and the endpoint is network-restricted to that caller.
3. `scim-provisioning-svc` opens one transaction against the `identity` schema: set `clinician.active = false`, and close every `care_relationship` whose `valid_period` is still open by setting its upper bound to now. One transaction, so there is no window where the account is disabled but relationships remain open.
4. **Record access ends at once.** Row-level security policies join through `care_relationship` and evaluate the temporal range at query time, so the next query from any session — including one already authenticated — returns nothing for those patients.
5. **Search reach ends on the next query**, because the caller's team membership is resolved fresh from PostgreSQL per request rather than cached.
6. **The existing token still validates** until it expires, because it is a signed bearer token and nothing revokes it. Access tokens are 15 minutes, so that is the outer bound of the window — and during it, every data path returns nothing, so a valid token buys an authenticated session with no reach. That is the correct layering: revoke *reach*, not tokens.
7. `carerelationship.changed` publishes to `care.events`; `celery.index` reindexes the affected patients' documents.
8. The event is audited, and a detection rule watches specifically for a SCIM deprovisioning that did not close its care relationships.

**Where it can fail, and what catches it.** If the SCIM call itself fails — network, an application error, a lock timeout — the leaver keeps access. This is why SCIM sync failure is paged rather than logged: it is the one background failure in the system whose silent version is a security incident. If the transaction were split into two statements across two transactions, a crash between them would leave a deactivated clinician with open relationships, which is why the atomicity is stated as a requirement rather than an implementation detail.

**The property worth naming in an interview.** Access follows employment, and the platform has no step in it. Any design where someone must remember to remove access is a design where access is eventually not removed.

</details>

---

### Q2. Explain how a transaction-mode connection pooler could turn row-level security into its opposite.

**Brief answer**
A transaction pooler hands the same backend connection to different requests. A session-scoped `SET app.actor_id` outlives the request that issued it, so the next request inherits the previous caller's identity and the policies happily scope to the wrong person.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism, step by step.** Request A, from clinician A, checks out a pooled connection and executes `SET app.actor_id = 'A'`. It runs its queries, the policies scope to A's care relationships, everything is correct. The transaction ends and the pooler returns the backend to the pool — but a plain `SET` is session-scoped, and the session is the backend, not the transaction. Request B from clinician B checks out that same backend. If anything runs before B's own `SET` — or if B's code path sets the variable only in some branches — the policy evaluates against A's identity. Clinician B reads clinician A's patients. Every layer reports success: no exception, no `403`, correct-looking data on screen.

**Why it is worse than an ordinary bug.** It is intermittent and load-dependent, because it requires a specific pooling reuse. It disappears under low concurrency, so it will not reproduce in a developer's environment. It leaves no distinguishing trace in the audit table, because the audit row records the actor the application *believed* it was serving. And the data returned is real, well-formed patient data — nothing downstream can detect it.

**The fix.** `SET LOCAL`, which is transaction-scoped and is discarded at commit or rollback, so the value cannot outlive the unit of work. The corollary is that the variable must be set inside a transaction — `SET LOCAL` outside one is a no-op with a warning, which would leave the policy evaluating against an unset variable. A policy that treats an unset actor as "no rows" fails closed; one that treats it as "no constraint" fails open, so the policy has to be written for that case explicitly.

**How it is proven rather than believed.** A test that runs two requests as different actors over a pooler configured in transaction mode, against a real PostgreSQL instance, and asserts the second sees nothing belonging to the first. It has to use a real pooler and real concurrency — a mocked session or a direct connection cannot reproduce the reuse, so the test would pass while the property was broken. That is the general lesson I would draw: for a control whose failure is silent, the test has to reproduce the exact mechanism, and a test that cannot fail for the right reason is not evidence.

</details>

---

### Q2. RabbitMQ's MQTT plugin authenticates per connection, not per publish. What is the security gap, and how do you close it?

**Brief answer**
A long-lived mobile connection is authenticated once at connect time, so a token that later expires or is revoked keeps publishing. The gap is closed by capping connection lifetime below the refresh-token window and forcing re-authentication.

<details>
<summary><strong>Detailed answer</strong></summary>

**The gap.** HTTP re-presents a token on every request, so expiry and revocation take effect within the token's lifetime — 15 minutes here. MQTT establishes a session and keeps it open; the broker authenticates the [CONNECT](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT CONNECT packet — Opens a client session with the broker and authenticates the client") packet and then authorizes publishes against whatever it decided at that moment. A phone that connects in the morning and stays connected all day was authorized once. If the patient's account is disabled, or the token is revoked, or their consent changes, the connection carries on.

**How it is closed.** The listener authenticates the connection with the patient's access token and authorizes publishes only to `care/checkin/{patient_id}` matching the token subject — so a compromised connection cannot publish as someone else, which bounds the damage to the account it belongs to. Then connections carry a **maximum lifetime shorter than the refresh-token window**, forcing a reconnect and a fresh authentication. That converts an unbounded authorization into one bounded by the connection cap.

**What that costs and what it does not break.** A forced disconnect is invisible to the user because MQTT QoS 1 with a persistent session means the client queues locally and redelivers on reconnect — the same mechanism that already handles a tunnel or a dead spot. So the security control rides on a resilience property that already had to exist.

**The honest residual.** The window is still the connection cap, not zero. Anything requiring immediate revocation cannot rely on the MQTT path alone. In practice that is acceptable here because the only operation available on that transport is publishing a check-in for oneself — the blast radius of a stale authorization is that a patient's own check-in is accepted slightly after their account should have stopped, which is not a disclosure. I would give a different answer if the transport carried reads.

**And the thing to do before committing.** The design flags this as something to prototype against real token lifetimes before building on it, rather than assuming the plugin's behaviour. That is the right instinct: the gap is in a third-party plugin's authentication model, and the mitigation depends on details — reconnect storms when many connections expire simultaneously, whether the client library re-authenticates cleanly, whether the broker's authorization backend can be consulted per publish at acceptable cost. Those are measurable in a day and expensive to discover later.

</details>

---

### Q2. Design break-glass access: a clinician must see a patient they have no care relationship with, right now.

**Brief answer**
Grant a time-boxed `care_relationship` with a mandatory reason string, notify the patient's named care team, raise a high-priority audit event, and review it within 24 hours. It is a recorded exception, not a role.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it must exist.** A patient arrives unconscious in an emergency department; the clinician in front of them is not on their care team. A system that cannot be overridden in that situation will be worked around — shared logins, a colleague clicking through, a call to an administrator with standing access. Every workaround is worse than a designed break-glass, because none of them is recorded.

**Why it must not be a role.** A `read_any_patient` role is permanent, invisible in use, and accumulates holders. The design's own role table is explicit that `platform_operator` has *no* routine patient-data access precisely to avoid a standing capability that nobody is watching.

**The design.**

1. **A reason string, required and free-text.** Not a dropdown — a dropdown becomes muscle memory and the reason field stops carrying information. Free text is what makes review meaningful.
2. **It creates a real `care_relationship`** with a bounded `valid_period`, typically hours. This is the elegant part: no new authorization path is introduced. Row-level security, search scope, and audit all work unchanged because break-glass produces exactly the data structure normal access produces. A parallel bypass path would be a second definition of reach and would eventually diverge from the first.
3. **Notify the patient's named care team immediately**, so the people who should know are told by the system rather than discovering it later.
4. **A high-priority audit event**, distinguishable from ordinary access, feeding a Kibana detection rule.
5. **Review within 24 hours**, by a named owner. An exception process with no review is a permission with extra steps.
6. **It expires by itself.** Because `valid_period` is a range with an end, nothing has to remember to revoke it.

**What I would add if I owned it.** Patient-visible transparency where the law and clinical judgement allow — a record of who accessed the file and why is something patients increasingly expect. And a rate signal: one break-glass a month in an emergency department is normal, forty is either a workflow problem the care-team assignment process should be fixing, or misuse. The metric that matters is the trend, not the individual event, and it is the one most break-glass implementations forget to collect.

</details>

---

### Q3. The design calls APIM a genuine single point of failure for north-south traffic and accepts it. Defend that, then argue against it.

**Brief answer**
The defence is that a second ingress path needs its own authentication policy, and a divergent second copy of an auth policy is a worse risk than the outage it prevents. The argument against is that a 99.9% record objective now depends entirely on one managed component's availability.

<details>
<summary><strong>Detailed answer</strong></summary>

**The defence.** APIM does the audience separation that keeps clinician tokens off the patient plane, plus signature and issuer validation and coarse rate limiting. A second ingress means a second implementation of that policy. The failure mode of divergence is not an outage — it is a path where the audience check is subtly weaker, exercised only during an incident, when scrutiny is lowest. Given a choice between a rare, visible, bounded outage and a rare, invisible authorization gap on a health record, the outage is clearly the better failure. The mitigations that remain are multi-instance APIM with Front Door health probes and, underneath, `care-core` re-validating every token so the gateway is not the only thing standing between a request and the data.

**The argument against.** Availability composes: the record's 99.9% monthly budget is about 43 minutes, and that budget is now shared with a component whose failures the team cannot fix, only wait out. A regional APIM control-plane problem is not something a runbook resolves. And the "divergent policy" risk is a risk of *implementation*, which is exactly the class of risk that automation removes — if the policy is [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files")-declared and deployed identically to both paths, with a conformance test asserting that both reject a clinician token on a patient route, then the divergence argument weakens considerably. Rejecting redundancy because a duplicate might drift is, in that light, an argument for testing the duplicate rather than for having none.

**Where I actually land.** The decision is right for now and the reasoning is sound, but the *justification* would be stronger if it were expressed as a condition rather than a principle. Concretely: the accepted exposure is bounded by APIM's own availability, and if observed availability erodes the record's error budget over a couple of quarters, a second path becomes worth its risk — with the policy as shared declarative configuration and a conformance test proving both paths enforce the audience split identically.

**What I would raise in the design review.** Not "add redundancy", but "what would we do during a two-hour APIM outage?" If the answer is "wait", that should be a written, accepted position with the clinical stakeholders, not an implicit one — because the people who bear that outage are clinicians mid-consultation, and they are entitled to know it is a choice rather than an accident.

</details>

---

### Q3. Entra ID has a regional outage. The JSON Web Key Set (JWKS) cache holds signing keys for twelve hours. Walk through what works, what does not, and what that long time-to-live risks.

**Brief answer**
Existing tokens keep validating for as long as the cached keys survive, so active sessions continue and SCIM sync queues for replay. New sign-ins fail, because nothing but the identity provider can issue a token. The long cache is a deliberate outage mitigation whose cost is slower key-rotation propagation.

<details>
<summary><strong>Detailed answer</strong></summary>

**What keeps working.** Token *validation* is local: APIM and `care-core` verify the signature against cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") material, plus issuer, expiry, and audience. None of that calls Entra ID. So a clinician mid-shift with a valid token keeps working, their refresh may still succeed if it is served by a cached path, and every data path behaves normally. SCIM operations queue and replay when the provider returns, so provisioning is delayed rather than lost.

**What stops.** Any new interactive sign-in, because only the identity provider can authenticate a user and mint a token. With 15-minute access tokens, sessions that cannot refresh degrade within the outage regardless of the JWKS cache — the cache protects validation, not issuance, and it is worth being precise about that distinction because it is often blurred. So a multi-hour outage means clinicians progressively lose access as their refresh attempts fail.

**What the twelve hours risks.** Key rotation. If Entra ID rotates a signing key, a token signed with the new key fails validation against the cached set. The design handles that by refreshing on a validation failure against an unknown `kid` rather than waiting for the time-to-live to expire — which is the correct mechanism, and it means the long cache does not delay the *good* case. The residual risk is the bad case: if a key is rotated because it was **compromised**, tokens signed with the revoked key remain acceptable to this platform for up to twelve hours. That is a real, if unlikely, exposure and it deserves an explicit operational answer — a manual cache purge in the incident runbook, so responding to a compromised key does not mean waiting out a cache.

**The trade being made.** Long cache: better survival of a provider outage, slower propagation of a revocation. Short cache: the reverse, plus a hard dependency on the provider's availability for every validation. Twelve hours is a deliberate choice in favour of outage survival, and the platform's own detection rules and audit trail are what compensate on the revocation side.

**What I would add.** An explicit runbook step to purge `jwks:{tenant}` from `redis-cache`, tested — because the mitigation for the only real risk of this design is an operation nobody will have performed before the day they need it.

</details>

---

### Q3. Row-level security is called the single most important control here. What is the strongest argument against relying on it, and how would you satisfy an auditor that it works?

**Brief answer**
The strongest argument is that it is invisible: it protects perfectly right up until a configuration change silently disables it, and nothing in the application changes when that happens. Satisfying an auditor means evidence that it fails closed, not a description of how it is written.

<details>
<summary><strong>Detailed answer</strong></summary>

**The case against, taken seriously.**

- *It can be turned off without touching application code.* A role granted `BYPASSRLS`, a table created without `ENABLE ROW LEVEL SECURITY`, a migration run as a superuser that leaves ownership wrong, a `FORCE ROW LEVEL SECURITY` missing so the table owner bypasses its own policies. Every one of those is a database-level change that no application test would notice.
- *It only covers PostgreSQL.* Elasticsearch, `mongo-content`, Redis-cached renders, and Blob documents are all outside it, and each needed its own answer.
- *It concentrates authorization logic in an unfamiliar place.* Most application developers do not read policy definitions, so a subtle policy change gets less review than an equivalent change in Python would.
- *It interacts with the planner*, so a security change can become a performance incident, and a performance fix can weaken a security control. That coupling is genuinely uncomfortable.
- *A policy is only as correct as the temporal join underneath it.* If `care_relationship`'s `valid_period` were ever written wrongly — an unbounded range, a wrong time zone — the policy would faithfully enforce the wrong thing.

**Why I would still rely on it.** The alternative is authorization that fails open. Every argument above describes a way the control could be *disabled*, and each is detectable by a test; the alternative's failure is undetectable by construction. Preferring a control whose failures you can assert over one whose failures you cannot is the right trade on a patient record.

**The evidence I would put in front of an auditor**, which is a different thing from an explanation:

1. **A negative test suite.** Actor A queries actor B's patient and receives zero rows, run against every patient-scoped table, in the pipeline, on every merge.
2. **The pooled-connection leakage test**, run against a real pooler in transaction mode — proof the `SET LOCAL` discipline holds under connection reuse.
3. **A role-privilege assertion**: the application role is `NOSUPERUSER`, lacks `BYPASSRLS`, and is not the owner of any policied table.
4. **A schema conformance check**: every table containing `patient_id` has row-level security enabled and forced, and at least one policy. This is the one that catches the *new* table added next quarter without a policy — the most likely real-world failure, and the one no existing test would cover.
5. **An `EXPLAIN` assertion** on plan shape, showing the security predicate reaches the planner and pruning survives.
6. **Detection rules over the audit stream** for out-of-team access and direct database queries from non-application principals — evidence that the control is monitored in production, not only tested in the pipeline.
7. **Mutation evidence.** The most persuasive artefact of all: deliberately break each control in a scratch environment and show the corresponding test failing. A test suite that has only ever passed proves that it runs, not that it detects anything.

That last point is the one I would lead with. An auditor is entitled to ask "how do you know this test would catch it", and the only honest answer is that you have watched it fail.

</details>

## Applied Machine Learning for Clinical Content

---

### Q1. What is transfer learning, and why fine-tune a Hugging Face model here rather than prompting a large general-purpose model?

**Brief answer**
Transfer learning starts from a model that already has general language representations and adapts it to a narrow task with a comparatively small labelled set. It is used here for entity extraction and passage reranking — narrow, repetitive, latency-sensitive tasks where a small self-hosted model beats a large general one on cost, control, and data residency.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** A pretrained encoder has learned representations from a large corpus; fine-tuning continues training on a domain-specific labelled set so the model adapts to oncology notes — the abbreviations, the staging notation, the drug naming, the sentence shapes clinicians actually write. Because the representations already exist, useful results come from thousands of examples rather than millions.

**Why fine-tuning rather than a general model behind an API.**

- *Data residency.* Every Azure resource, both clusters, and all backups are in a single region with no cross-border transfer and **no third-party model API**. Patient text leaving the tenancy is not a latency question, it is a lawfulness question. Self-hosting the weights is what keeps the text inside.
- *Task shape.* The two jobs are extraction (entities and codes from a note) and reranking (ordering candidate passages by relevance to a diagnosis and treatment line). Both are classification-shaped, run at high volume, and have a right answer you can measure. A small fine-tuned encoder is faster, cheaper, and more consistent at those than a large generative model, and it does not invent anything.
- *Versioning and attribution.* The model version is stamped on every artifact, so a regression is attributable and a rollback is a reindex rather than a mystery.

**Where a generative model is still used, and where it is fenced.** LangChain composition does rewrite approved passages into patient-readable prose. But it draws only from `guidance_sources` passages a clinician has approved, every block carries a citation to the passage it came from, and a page a reviewer has not approved is never assigned to a patient. So the generative step is constrained to selecting, ranking, and rewriting approved material — it does not author clinical claims.

**The honest trade.** That constraint costs relevance. A freely generating model would produce more fluent, more specific pages. The cost is accepted deliberately, because an unsourced sentence in cancer guidance is a patient-safety defect rather than a quality regression. Being able to state which capability was given up, and why, is more useful than claiming the pipeline is both maximally capable and maximally safe.

</details>

---

### Q1. What does LangChain actually contribute to this pipeline that you would otherwise write yourself?

**Brief answer**
It gives the retrieval, reranking, templating, and citation-assembly steps a declared shape — a pipeline you can read, version, and test stage by stage — instead of bespoke glue. What it does not give you is the safety property; that comes from the corpus constraint and the review gate.

<details>
<summary><strong>Detailed answer</strong></summary>

**The steps it structures.** Take a diagnosis code, treatment line, stage, and locale; retrieve candidate passages from `guidance_sources` in `mongo-content`; rerank them with the fine-tuned model against the patient's context; compose a page from the top passages using a template; and assemble citations mapping each block back to the `(source_id, passage_id, span)` it came from. Each of those is a stage with typed inputs and outputs, which means each is independently testable and the prompt version is a versioned artefact stamped onto the output alongside the model version.

**What I would write by hand instead.** Honestly, all of it — none of the steps is difficult individually. The argument for the framework is that the pipeline becomes a declared object rather than a function that grew, so swapping the reranker or adding a stage is a local change, and the composition is legible to someone who did not write it. The argument against is real too: an abstraction layer over calls you fully control adds a dependency, a version-upgrade surface, and indirection when debugging. On a small pipeline that is a genuine trade rather than an obvious win, and I would be comfortable arguing either side depending on how many pipelines the team expects to maintain.

**What it definitively does not provide.** The safety property. Nothing in a composition framework stops a model asserting something that was not in the retrieved passages. That comes from three things outside the framework: the corpus is restricted to clinician-approved passages, every block carries a citation, and `review_state` must reach `approved` before a page can be assigned — with `content_author` and `content_approver` as separate roles so the approval is a real second pair of eyes rather than a formality.

**Where I would put the engineering effort.** Citation fidelity, which is the claim most likely to be quietly false: verifying that each block's cited span actually supports its text, rather than trusting that the pipeline wired them up correctly. That is a testable property — take a composed page, check each block against its cited passage — and it is the one that would embarrass the platform if it were wrong.

</details>

---

### Q2. Composition draws only from approved passages, and each block carries a citation. How is that actually enforced, and what does it cost?

**Brief answer**
Retrieval queries only `guidance_sources`, the assignment in PostgreSQL pins an exact `(page_id, page_version)` that must be `approved`, and separated author and approver roles make the review real. The cost is measurably narrower pages — accepted, because an unsourced sentence in cancer guidance is a safety defect.

<details>
<summary><strong>Detailed answer</strong></summary>

**The chain of enforcement, in the order a page travels.**

1. **Retrieval scope.** `clinical-nlp-svc` retrieves from `guidance_sources` — clinician-authored and curated passages with provenance and an `effective_from`/`retired_at` lifecycle. There is no path that retrieves from the open web or from the model's own parametric knowledge as a source.
2. **Citation assembly.** Every block carries `{source_id, passage_id, span}`. A block with no citation is a defect the pipeline should reject, not render.
3. **Review state.** A page moves `draft` → `pending_review` → `approved` → `retired`, and only `approved` versions are assigned. The state machine is in `mongo-content`, and the assignment row in `pg-clinical` pins an exact `(page_id, page_version)`.
4. **Version pinning.** A later revision never silently changes what a patient was shown. That matters because the shown text is the record of what advice they were given — if the page could change under them, the record of the advice would be unreliable.
5. **Separation of duties.** `content_author` cannot approve their own content, and `content_approver` has no patient-record access. Without that separation the safety property the pipeline claims would be nominal.

**What it costs, stated plainly.** Pages are less specific and less fluent than a freely generating model would produce, and coverage is bounded by the corpus — if no approved passage addresses a patient's situation, no page can be generated for it, and that gap has to surface to a clinician rather than being filled by the model. There is also a throughput cost: human review is in the loop, so generation capacity is bounded by reviewer availability, not by GPUs.

**Where I would look for the weak link.** Citation fidelity. Everything above enforces that a page was *assembled from* approved passages and *reviewed*. Nothing structurally guarantees that a given sentence is actually supported by the passage cited next to it — a rewrite step can drift. A reviewer reading a fluent page with plausible citations is exactly the situation where a subtle unsupported claim survives. I would want an automated check comparing each block against its cited span, presented to the reviewer as a confidence signal, so review effort concentrates where the evidence is weakest. That is the improvement I would argue for, and I would frame it as strengthening a control that is already there rather than as a defect in the design.

</details>

---

### Q2. The CV claims a 28% relevance improvement. Where does it come from, and how would you evaluate it honestly?

**Brief answer**
From two fine-tuned models together — entity extraction enriching the notes index, and passage reranking during retrieval — replacing one generic leaflet per cancer type with passages ranked against the patient's diagnosis, treatment line, and stage. Honest evaluation means a held-out clinical set with clinician-assigned labels, offline first and online second.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the gain comes from.** The baseline is a generic page per cancer type. The improvement is selecting and ordering approved passages against the specific patient's context, which is what the reranker does, plus better retrieval candidates because extracted entities and codes enrich the index the retrieval draws on. Both models are evaluated against a held-out clinical set on every model version, and the version is stamped on every artifact so a regression is attributable.

**Offline evaluation.** For a reranker the natural metrics are normalized Discounted Cumulative Gain (nDCG) and precision at small k, against relevance labels. The hard part is not the metric, it is the labels: relevance for cancer guidance is a clinical judgement, so the labelled set has to be built by clinicians, ideally more than one per item so inter-annotator agreement is measurable. If two oncologists disagree about relevance 30% of the time, a 28% model improvement measured against one of them means considerably less, and stating that agreement figure alongside the result is what makes the claim credible.

**What makes the number honest.**

- *A held-out set the model never trained on*, split by patient rather than by document so passages from one patient's context cannot appear on both sides.
- *A realistic baseline* — the generic-leaflet system as actually deployed, not a strawman.
- *Reported with a confidence interval*, since these sets are usually small.
- *One variable at a time.* If extraction and reranking shipped together, the 28% belongs to the pair; attributing it to reranking alone requires an ablation.

**Online evaluation, which is what actually matters.** Offline relevance is a proxy. The product claim is that patients read the guidance and stay on their treatment schedule, so the real signals are page open rate, read-through, and — the outcome the product exists for — adherence and check-in schedule maintenance. Those are slow, confounded, and worth measuring anyway. Canary deployment of `clinical-nlp-svc` exists precisely because model quality shows up statistically: a percentage rollout with confidence and latency comparison is the only way to see a regression before everyone gets it.

**And the qualification I would give unprompted.** Relevance and latency are separate claims that are easy to blur. Search got 35% faster; pages got 28% more relevant. Neither implies the other, and presenting them as one improvement would be overstating what was measured.

</details>

---

### Q2. Fine-tuning on real visit notes means patient text in a training corpus. What has to be resolved before the first tuning run?

**Brief answer**
Lawful basis for that processing, the required de-identification standard, and whether the resulting weights can leak training text. All three need a completed Data Protection Impact Assessment ([DPIA](https://gdpr-info.eu/art-35-gdpr/ "GDPR process for assessing privacy risk before high-risk data processing")) before the first run, not a retrospective one.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why this is the highest-risk processing in the system.** Everything else is storage and retrieval of data the patient provided for their care, under consent bound to that purpose. Training is different: it is a *new* purpose, it produces an artefact derived from many patients' data that is not itself a record, and that artefact is copied, versioned, and deployed. Consent for treatment support does not automatically extend to model training, and under the General Data Protection Regulation ([GDPR](https://gdpr-info.eu/ "EU regulation governing the processing of personal data")) health data is Article 9 special-category, so the lawful basis has to be established rather than assumed.

**The three questions, and why none has an obvious answer.**

1. **Lawful basis.** Explicit consent for the training purpose, or a research basis with its own safeguards. This is a decision for the data controller — the trust — not for the engineering team, and it determines whether the corpus can be built at all.
2. **De-identification standard.** Removing names and identifiers from clinical free text is genuinely hard: notes contain rare diagnoses, place names, dates, and phrasing that re-identify in combination. The standard has to be named and the residual risk accepted explicitly. "We ran a de-identification tool" is not a standard.
3. **Memorisation and extraction.** Language models can reproduce training data, and the risk rises with rare sequences — which is exactly what an unusual clinical case is. Whether the deployed weights can leak text needs testing, not assertion. Extraction attempts against the fine-tuned model on known training examples are a concrete evaluation, and differential privacy in training is the mitigation if the risk is judged unacceptable.

**What the design already does that helps.** Weights are self-hosted so no third party receives the corpus or the model; residency is single-region; `nlp_extractions` are derived artifacts rebuildable by re-running the model, so they can be purged freely; and a DPIA is maintained for the NLP pipeline specifically.

**How I would behave here.** This is the clearest example in the project of a technical decision that is not mine to make. My job is to state the risk precisely, describe what is technically possible under each option, and refuse to start a tuning run before the assessment is complete — including when there is schedule pressure. Doing the run first and documenting afterwards is the failure mode, and it is unrecoverable: you cannot un-train a model, and weights derived from an unlawful corpus are themselves a liability.

</details>

---

### Q3. A new model version ships and quality regresses. How do you notice before every patient sees it, and how do you get back?

**Brief answer**
`clinical-nlp-svc` deploys canary at 5%, then 25%, then 100%, comparing confidence and latency against the incumbent, because model quality shows up statistically rather than as an error. Rollback is a revision revert plus a reindex, which is cheap because the model version is stamped on every artifact.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why canary rather than blue-green here.** A bad model does not throw. It returns confident, well-formed, slightly worse output. There is no error rate to alert on, so the only way to see the regression is to compare populations — which requires both versions serving simultaneously and enough volume on the new one to be significant. That is the reason the deployment strategy differs by service and it is not a stylistic choice: the record service is blue-green because an instantaneous switch gives the cleanest rollback, and the model service is canary because a percentage rollout is the only way to detect a statistical regression.

**What I would compare at each canary stage.** Offline metrics on the held-out clinical set as a gate before any traffic. Then, on live traffic: `nlp_low_confidence_total` — a confidence dip on a new model version is one of the design's named alerts — plus the p95 inference latency, the generation queue depth, and, over a longer window, the clinical reviewer rejection rate. That last one is the highest-signal metric in the system for this purpose, because reviewers are domain experts and their rejections are labelled data arriving for free. It is also the slowest, which is why it cannot be the only gate.

**Rollback.** ArgoCD reverts to the previous revision, and the previous image is digest-pinned so there is no ambiguity about what comes back. The artifacts are the interesting part: `nlp_extractions` carry `model_version`, and `content_pages` carry `generated_by{model, prompt_version}`. So identifying what the bad version produced is a query, and regenerating it is a reindex rather than a migration — the design's phrasing, and it is accurate. Nothing was destructively overwritten, because published page versions are immutable and assignments pin an exact version.

**What stays safe throughout.** No page reaches a patient without clinician approval, so even a badly regressed model produces work for reviewers rather than harm to patients. The review gate is the backstop that makes an aggressive canary acceptable — and it is worth naming that dependency explicitly, because if review were ever automated away for throughput, the canary strategy alone would no longer be sufficient protection.

**The gap I would close.** A confidence metric measures the model's self-assessment, which is exactly what a miscalibrated model gets wrong. I would want a periodic offline evaluation of the *live* model against a refreshed held-out set, so quality is measured against ground truth on a schedule rather than only at release — otherwise a slow drift as clinical vocabulary changes is invisible between deployments.

</details>

---

### Q3. `clinical-nlp-svc` runs on a separate GPU cluster, which the design calls its most expensive choice. When would you collapse it, and what changes if inference moves to a managed endpoint?

**Brief answer**
Collapse it when GPU node-pool management or the independent release cadence stops justifying a second cluster — which a managed inference endpoint would achieve directly. The design deliberately keeps no state on `aks-ml` so the move stays cheap, but a managed endpoint reopens the data-residency question that self-hosting settled.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the second cluster is buying.** Two things only: GPU node-pool management, which OpenShift can do with a MachineSet but less comfortably, and an independent release cadence for a service that ships on a model's schedule rather than the product's. It is not buying isolation of any user-facing path — no synchronous request depends on it, and a cross-cluster partition affects page generation alone.

**What it costs.** Virtual network (VNet) peering, network security groups and a private endpoint on the one cross-cluster hop, mutual Transport Layer Security (mTLS) with certificates issued by cert-manager in each cluster because OpenShift's built-in service-serving certificates do not span clusters, a second set of cluster operations, and a NetworkPolicy model that governs traffic inside a cluster and therefore cannot see that hop at all. Three mechanisms guarding one connection where one would do inside a single cluster.

**The collapse conditions.** Either the GPU pool becomes manageable within `aro-primary` — a MachineSet, or the workload becomes small enough for CPU inference — or the release cadence converges with the product's. The design keeps no state on `aks-ml` specifically so that collapse is a redeploy rather than a migration, and being able to name the reversal condition is what distinguishes an accepted cost from a permanent one.

**What a managed inference endpoint changes.**

- *It removes the cluster entirely*, which is the largest single simplification available in this architecture.
- *It reopens data residency.* The current posture is explicit: no third-party model API, weights self-hosted so patient text stays in the tenancy, everything in one region. A managed endpoint is acceptable only if it is in-region, in-tenancy, and contractually covered by the same processor obligations — otherwise it is the one thing the compliance model rules out. That is not a preference; it is the difference between lawful and unlawful processing of Article 9 data.
- *It changes the fine-tuning story.* Hosting a fine-tuned model on a managed endpoint means uploading weights derived from clinical notes, which brings back the assessment questions the self-hosted design contained.
- *It changes the failure model* from "our GPU pool is unavailable" to "a vendor's service is degraded", which is a different runbook and one the team cannot resolve, only wait out.

**Where I would land.** I would pursue it, because collapsing a cluster is a genuine reduction in operational surface and the current design invites exactly this move. But I would treat residency and the fine-tuning path as gating questions answered with the data controller before any technical evaluation — and I would expect to say so to whoever proposed the migration on cost grounds, because the cost saving is real and the compliance constraint is not negotiable against it.

</details>

## Testing and Quality Gates

---

### Q1. Unit, contract, and integration tests all run in this pipeline. What does each catch that the others cannot?

**Brief answer**
Unit tests catch logic errors in isolation and run in milliseconds. Contract tests catch schema drift between the API and its consumers. Integration tests catch everything that only exists when real components interact — driver behaviour, transactions, broker semantics, index mappings.

<details>
<summary><strong>Detailed answer</strong></summary>

**Unit tests** cover a function or class with its collaborators substituted. They are where the branch-heavy logic belongs: reminder state transitions, the timeline cursor comparison, scope-filter construction, Pydantic validators. They are fast enough to run on save, which is what makes them useful during development rather than only in the pipeline.

**Contract tests** assert the published interface. Here the OpenAPI document is generated from the Pydantic models, so the contract test asserts the emitted schema against expectations — catching a field rename, a type narrowing, or a new required field before it reaches a frontend that generates its client from that document. The SCIM endpoints need the same treatment against the SCIM 2.0 schema, since the consumer is Entra ID and not a team you can ask to adapt.

**Integration tests** run against real `pg-clinical`, `mongo-content`, `es-clinical`, `redis-cache`, and `rmq-core` containers in Docker Compose. These catch what mocks structurally cannot: whether row-level security actually returns zero rows for the wrong actor, whether a redelivered message is absorbed by the unique constraint, whether the migration applies, whether an Elasticsearch mapping accepts the document the indexer builds, whether a `SET LOCAL` survives a pooled connection. A mocked broker cannot fail the way a real one does — it cannot run out of memory, redeliver, or reorder.

**Where each fails.** Unit tests confirm the code does what its author thought, including when the author's model of the database was wrong. Contract tests say nothing about behaviour — a schema can be perfectly stable while the endpoint returns the wrong patient's data. Integration tests are slow, and their failures are less specific, so a suite made only of them is a suite people stop reading.

**The split I would aim for on this system.** Heavier on integration than a typical application, because the highest-severity defects here — authorization scope, audit completeness, message redelivery, migration safety — are all interaction defects that unit tests cannot reach. That is a deliberate trade of pipeline duration for the ability to detect the failures that actually matter, and it is the reason a twenty-minute pipeline is a reasonable price rather than a symptom of neglect.

</details>

---

### Q1. What does a test coverage number actually tell you, and what does it not?

**Brief answer**
Line coverage tells you which lines executed during the suite. It does not tell you whether anything was asserted, whether the assertions are right, or whether the untested 10% is the important 10%. It is a floor, not a measure of quality.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it genuinely gives you.** Coverage is excellent at finding code nobody exercises at all — an error branch never entered, a module orphaned by a refactor, a new file merged with no tests. As a **gate on new code** it is particularly effective, because it makes "I will add tests later" visible at merge time. SonarQube's new-code focus is exactly that use, and it is the right one.

**What it does not give you.**

- *Assertion quality.* A test that calls a function and asserts nothing produces full coverage of it. This is the single most common way a coverage target is met without value being created.
- *Branch and path completeness.* Line coverage counts a line executed once; a conditional with two outcomes can be fully line-covered by exercising one. Branch coverage is the more honest metric and it is worth configuring.
- *Whether the covered behaviour is correct.* Coverage measures execution, not truth.
- *Whether the uncovered part matters.* 90% coverage with the row-level security policies, the audit write, and the scope-filter construction in the uncovered 10% is worse than 70% with those fully covered. The number is an average over code that is not equally important.

**How I would use a 90% target without degrading the suite.** Treat it as a floor on new code and pair it with something that measures assertion strength. Mutation testing is the honest complement: deliberately break a line and confirm a test fails. If a mutation survives, the code was executed but nothing checked it — which is precisely the gap coverage cannot see. Running full mutation testing on every merge is too slow, but running it on the security-critical modules on a schedule is affordable and is what I would propose.

**And the position I would take with a lead who asked for 90%.** I would meet the number — it is their project and it is a defensible floor. But I would also say, once, that a coverage percentage and a set of properties the tests provably detect are different things, and offer to demonstrate the second on the modules where a silent failure would matter. That is a more useful conversation than either arguing about the number or hitting it with tests that assert nothing.

</details>

---

### Q1. `ruff`, a strict type checker, SonarQube, and Trivy all gate the pipeline. What does each catch that the others do not?

**Brief answer**
`ruff` catches style and simple correctness patterns in milliseconds; the type checker catches contract mismatches across function and module boundaries; SonarQube catches maintainability, duplication, and coverage on new code; Trivy catches vulnerable dependencies and image layers. Their overlaps are small and their blind spots are different.

<details>
<summary><strong>Detailed answer</strong></summary>

**`ruff`** is a linter and formatter fast enough to run on save and in a pre-commit hook, and it subsumes what Black and isort do separately — formatting and import ordering — which is worth knowing when a project's tooling list names all three. Beyond formatting it catches unused imports, shadowed names, mutable default arguments, bare `except`, and a large set of bug-prone patterns — the class of defect that is obvious once pointed out and invisible during review. Its value is that it is instant, so it never becomes a reason to skip the check.

**A strict type checker** — `pyright --strict` here, `mypy` in the client's stack; the distinction matters less than the strictness setting — catches what a linter cannot: a function called with the wrong argument type, an `Optional` dereferenced without a guard, a return type that does not match, a refactor that changed a signature and missed three call sites. On typed SQLAlchemy 2 models it also catches column type mismatches, which on a patient record is where a wrong join starts. Strict mode is what makes it worth having; permissive typing catches the errors you would have found anyway.

**SonarQube** operates at a different altitude: cognitive complexity, duplicated blocks, coverage on new code, and a curated set of security hotspots. Its most valuable feature here is the new-code quality gate, because it applies the standard to what is changing rather than demanding a legacy cleanup nobody scheduled. Its weakness is a tendency toward findings that are true but not important, so the gate's rule set needs curating or the team learns to override it — and an override that becomes routine is a gate that no longer exists.

**Trivy** scans dependencies and image layers for known vulnerabilities. Nothing above looks at your base image's system packages, which is where a large share of real exposure lives. It pairs with digest-pinned images and a dependency audit so that what was scanned is provably what deploys — a mutable tag cannot be swapped underneath a running cluster.

**The shared blind spot, and the reason none of them is the real gate.** Every one of these tools analyses artefacts, not behaviour. None can tell you that a clinician can read a patient they should not, that an audit row was not written, or that a redelivered message double-applied. That is what the integration suite is for, and it is why the static gates are the cheap first filter rather than the assurance.

</details>

---

### Q2. The client targets 90% test coverage. How would you reach that without filling the suite with tests that assert nothing?

**Brief answer**
Cover behaviour rather than lines: work outward from the properties that must hold, use branch coverage rather than line coverage, gate on new code, and verify assertion strength with mutation testing on the modules where a silent failure matters.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start from properties, not from a percentage.** For each module, write down what must be true: a clinician cannot read outside their care relationships; every patient-data read writes an audit row; a redelivered check-in produces one row; an unapproved page is never assigned; a reminder reaches a terminal state. Tests for those properties are the ones that would catch a real regression, and they naturally cover a lot of code. Coverage then arrives as a by-product of testing what matters, which is a very different suite from one written to move a number.

**Use the right coverage metric.** Branch coverage rather than line coverage, because a conditional executed once counts as covered while half its behaviour is untested. Ninety per cent branch coverage is a meaningfully stronger statement than ninety per cent line coverage and costs little more to configure.

**Gate on new code.** Requiring the whole repository to jump to 90% produces a fortnight of low-value test writing. Requiring changed code to meet it is enforceable immediately, applies the standard where the risk actually is, and is what SonarQube's new-code gate does well.

**Verify the tests actually detect things.** Mutation testing on the security-critical modules: break a line, confirm a test fails. A surviving mutant means the line was executed and nothing checked it. Running it on every merge is too slow; running it nightly or weekly on `identity`, the scope-filter construction, and the audit path is affordable and gives evidence the suite has teeth.

**Be willing to exclude honestly.** Generated code, trivial property accessors, and `__repr__` methods can be excluded from the metric with a stated reason. That is more honest than writing a test for `__repr__` to lift the average — and an exclusion list someone reviewed is better than a suite padded to hit a target.

**And the parts I would say out loud to the lead.** First, that some of the highest-value tests here — the pooled-connection leakage test, the plan-shape assertion, the redelivery test — barely move coverage at all, so a team optimising the number alone will under-invest in exactly them. Second, that if the standard is 90%, I will meet it; the suggestions above are about making the number mean something, not about negotiating it down.

</details>

---

### Q2. Integration tests run against real PostgreSQL, MongoDB, Elasticsearch, Redis, and RabbitMQ containers rather than mocks. That is a large part of a twenty-minute pipeline. Defend it.

**Brief answer**
Because the defects that matter here only exist in the interaction: row-level security behaviour, redelivery, migration safety, index mappings, pooled-connection identity leakage. A mocked broker cannot fail the way a real one does, so a suite of mocks would pass while the system was broken.

<details>
<summary><strong>Detailed answer</strong></summary>

**What mocks cannot reproduce, concretely.** A mocked PostgreSQL does not enforce row-level security, so the single most important control in the design would be untested. It does not enforce a unique constraint, so the idempotency of the check-in projection would be an assumption. It does not exhibit transaction-mode pooling, so the `SET LOCAL` leakage test — which is the difference between the control working and inverting — cannot exist. A mocked RabbitMQ does not redeliver, does not apply flow control, and does not translate MQTT topic separators into AMQP routing keys, so three of the four things that make the check-in path lose data silently are invisible. A mocked Elasticsearch accepts any document, so a mapping mismatch ships.

**And the ones that are genuinely subtle.** Driver behaviour under a real connection pool. Migration application against a table that already has data. Whether the query planner still prunes partitions with the security policy applied. None of those is expressible as an assertion about a mock, because the thing being asserted is the real component's behaviour.

**The developer-experience argument, which matters as much.** The same Docker Compose stack developers run locally is what the pipeline tests against, so "works on my machine" and "works in the pipeline" converge. Developers running the real brokers and the real search engine rather than fakes is a stated design property, not an accident.

**What I would do to keep the cost honest**, because defending the approach is not the same as accepting any duration:

- Run the fast gates first — `ruff`, then types, then unit and contract tests — so a trivial mistake fails in two minutes and never reaches the expensive stage.
- Start containers once per pipeline run and share them across tests, with per-test isolation by transaction rollback or by schema rather than by restarting the stack.
- Parallelise integration tests across workers with isolated schemas.
- Keep a *small* set of full end-to-end paths and push everything else down to the cheapest layer that can still detect the defect. Integration testing is a tool for interaction defects, not a default.

**The trade in one sentence.** A twenty-minute pipeline that can detect an authorization regression is worth substantially more than a three-minute one that cannot, and on a system holding patient records that is not a close call.

</details>

---

### Q2. How do you test a control whose failure is silent — row-level security, the audit write, the search scope filter?

**Brief answer**
Write the negative test, reproduce the exact failure mechanism rather than a convenient approximation, and then prove the test detects it by deliberately breaking the control and watching the test fail. A test that has only ever passed is evidence that it runs, not that it detects anything.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why these need different treatment.** An ordinary bug announces itself — an exception, a wrong number, a failing assertion. These controls fail by returning plausible data: the wrong patient's record, a search hit that should not exist, a read with no audit trail. Nothing downstream can distinguish success from failure, so the test is the only observer, and a test with a subtle gap leaves the control unverified while reporting green.

**The discipline I would apply.**

1. **Assert the negative.** Not "clinician A can read their patient" but "clinician A reads clinician B's patient and gets zero rows". The positive test passes with the control entirely disabled; only the negative one is evidence.
2. **Reproduce the actual mechanism.** The `SET LOCAL` leakage test must run through a real pooler in transaction mode, with two requests as different actors. Run against a direct connection it passes whether or not the bug exists, because the reuse never happens — a test that cannot fail for the right reason is not a test.
3. **Distinguish three outcomes, never two.** Pass, fail, and could-not-run. A test harness that folds "the database was not migrated" or "the container did not start" into one of the other two branches will fold it toward whichever branch was written first, which is almost always the one confirming the expectation. An environment error must be loudly distinct from a detected violation.
4. **Prove detection by mutation.** Grant `BYPASSRLS` to the application role, change `SET LOCAL` to `SET`, drop the scope filter from the query builder, remove the audit write — and confirm the corresponding test fails each time. Then restore. This is the step that converts a suite into evidence, and it is the artefact I would put in front of an auditor or a lead.
5. **Cover the structural gap, not just the current code.** The most likely real-world failure is not a policy being changed; it is a *new* table being added without one. So a conformance check — every table containing `patient_id` has row-level security enabled and forced — catches next quarter's mistake, which no behavioural test written today would.
6. **Detect in production too.** Kibana rules over the audit stream for out-of-team access and for direct database queries from non-application principals. Pipeline tests prove the control at merge; detection rules prove it at runtime.

**The generalisation.** Any check whose output you will act on deserves more scrutiny than the code it checks, because a broken check does not fail — it confirms whatever you already believed. Feeding it a known-pass and a known-fail before trusting it takes minutes and is the difference between a control and a comforting green tick.

</details>

---

### Q2. The client manages test cases in Xray, linked to Jira. How would you work with that, and what is your experience?

**Brief answer**
I have used Jira for estimates and tracking but not Xray specifically. It is a test-management layer over Jira — test cases as issues, executions linked to requirements — and the integration work is mapping Pytest results onto those test issues, which is a reporting concern rather than a change to how tests are written.

<details>
<summary><strong>Detailed answer</strong></summary>

**Saying the gap plainly.** My tracking experience is Jira for estimates and remaining work, and Confluence for release and incident notes on a shared runbook. I have not used Xray. I would not want to imply otherwise, and it is a tool I would expect to be productive with in days rather than weeks, because the thing it changes is traceability and reporting rather than test design.

**What I understand it to do, and would confirm on day one.** Xray adds test-management types to Jira: tests, preconditions, test sets, test plans, and executions, with links from a test to the requirement or story it covers. The value is a query that answers "which requirements have passing tests, and when did they last run" — which is the question an audited or regulated project has to answer and which a pipeline's pass/fail history alone does not.

**The engineering integration.** Pytest emits JUnit [XML](https://www.w3.org/XML/ "Extensible Markup Language — Markup format for structured, machine and human readable documents"); Xray ingests results and matches them to test issues by a key, usually carried as a marker or in the test id. So the pipeline gains a reporting step that uploads results against a test execution. The two things I would want to get right early: a stable, meaningful mapping between automated tests and test issues, so renaming a test does not orphan its history; and clarity about which tests are managed in Xray at all — mirroring every unit test into a tracker produces thousands of issues nobody reads. Acceptance-level and requirement-linked tests belong there; a parametrised validator unit test does not.

**Where I would expect friction, and how I would handle it.** Manual test cases and automated tests can drift, so a requirement can look covered by a manual case that has not been executed in a year. And keeping the tracker in step is administrative work that engineers under deadline pressure skip. Both are process problems rather than technical ones, and the answer is to automate the upload so it happens on every pipeline run rather than depending on anyone remembering.

**The attitude I would bring.** A client that tracks coverage this way is doing it for traceability reasons that usually have an audit behind them. Treating it as bureaucracy to be minimised is the wrong instinct; keeping the records accurate is part of the work, and the useful contribution is making it automatic so it stays accurate without costing anyone an afternoon.

</details>

---

### Q2. The client welcomes AI tooling but the leads do not accept purely AI-generated code, and expect the author to fully understand what they submitted. How do you work under that?

**Brief answer**
Use it where it is genuinely good — boilerplate, test scaffolding, unfamiliar syntax, a first draft to react to — and treat every line as mine to justify in review. The standard I hold is that I could have written it and can explain why it is correct.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where it helps most, in my experience.** Repetitive structure: Pydantic models from a specification, parametrised test cases, a migration skeleton, a mapping between two similar shapes. Exploring an unfamiliar library faster than reading its documentation front to back. Producing a first draft of something I know how to review, which is often quicker than a blank file. And explaining unfamiliar code — genuinely useful when joining a codebase.

**Where I do not rely on it.** Anything where being subtly wrong is invisible: an authorization predicate, a migration against a large table, a concurrency or ordering property, a security control. Generated code in those areas is confident and plausible, which is the worst combination when the failure mode is silent. Those I write deliberately and test negatively.

**The self-review that satisfies the requirement.** Before submitting, I read the diff as if someone else wrote it and ask three things of every line: do I know why it is here, what happens when it fails, and would I write it this way. Anything I cannot answer gets rewritten or removed. In practice the tell for unreviewed generated code is not that it is wrong — it is that it is *more* than needed: an abstraction with one caller, error handling for a condition that cannot occur, a comment restating the line above. Those are the things a lead notices, and they are what makes code read as unowned.

**Meeting the gates rather than arguing with them.** `ruff`, strict typing, SonarQube, and the coverage gate apply identically whatever produced the code, and generated code often needs work to pass them — types the checker rejects, complexity SonarQube flags, tests that assert nothing. Getting it through the gates is part of the authoring, not a separate step.

**On the review culture itself.** A lead who has rejected [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code")-generated code before will be reading for it, and the way to build trust is to be someone whose submissions are consistently explainable — not to argue about the policy. If I disagreed with a specific review comment I would raise it with reasoning and evidence, with the technical contact for that area, and accept the outcome. Reworking a test to a lead's preference is a normal cost of working on someone else's codebase, and treating it as friction rather than as part of the job is how a good engineer becomes difficult to work with.

</details>

---

### Q3. The pipeline takes twenty to thirty minutes. How do you work around that, and how would you make it faster without weakening any gate?

**Brief answer**
Work around it by shifting the fast feedback left — pre-commit hooks and the local Compose stack — and by batching, so you are not idle waiting. Speed it up by ordering gates cheapest-first, parallelising, and caching, never by removing a check or making one non-blocking.

<details>
<summary><strong>Detailed answer</strong></summary>

**Working with it.** A twenty-minute pipeline stops being painful when it is not the first place you learn something is wrong.

- Pre-commit hooks run `ruff` and the type checker locally, so the failures that would cost a full cycle cost seconds.
- The same Docker Compose stack runs locally, so the integration tests relevant to my change run before I push. Running the *whole* suite locally is not the point; running the twenty tests around what I touched is.
- Push early to a draft merge request so the pipeline runs while I am still writing, rather than at the end.
- Batch: while a pipeline runs, review someone else's merge request, write the next test, or update the Jira remaining estimate. Long pipelines punish serialised work, not the person.
- Never push a speculative fix to see what the pipeline says. That is the habit that turns a twenty-minute pipeline into a three-hour afternoon, and it is a bigger cost than the pipeline itself.

**Making it faster, in the order I would try.**

1. **Order gates cheapest-first.** `ruff` in seconds, types in a minute, unit and contract tests, then the container-backed integration stage. A typo fails in ninety seconds instead of twenty-five minutes. This is usually the largest perceived improvement and costs nothing.
2. **Cache aggressively.** The Poetry virtual environment keyed on the lockfile hash, Docker layers, and the container images pulled once. Dependency installation is often a surprisingly large share of the total.
3. **Parallelise the integration stage** across workers with isolated schemas, and start the containers once per run rather than per suite.
4. **Split by change scope** where the module boundaries genuinely allow it — a change confined to `clinical-content` need not run every `identity` integration test on every push, provided the full suite runs before merge to the main branch.
5. **Attack the slowest tests specifically.** There is usually a small number of tests contributing a disproportionate share, and they are often slow for an avoidable reason: sleeping instead of polling for a condition, rebuilding a fixture per test, waiting on a fixed timeout.

**What I would not do.** Make a gate non-blocking, sample the tests, or move a check to a nightly run. A gate that cannot fail the pipeline is not a gate, and the coverage gate and the integration suite are precisely the ones under pressure when someone wants a faster pipeline. If the honest answer is that the suite is expensive because the system is safety-critical, that is a reasonable thing to say to a lead — along with the cheap improvements above, which usually recover enough time that the question stops being asked.

</details>

---

### Q3. An integration test fails intermittently and is blocking merges. Walk me through what you do.

**Brief answer**
Quarantine it from the blocking path only with a ticket and an owner, never delete or retry it into silence, then find the actual cause — which is almost always shared state, a timing assumption, or a real race in the code. Retry-until-green is the response that hides a production bug.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, decide whether it is flaky or whether it is right.** An intermittently failing test on a system with brokers, async projection, and eventual consistency is at least as likely to be reporting a genuine race as it is to be badly written. The check-in path is at-least-once, the search index is eventually consistent, and the reminder sweep runs concurrently across workers — these are areas where a real race would present exactly as flakiness. So the first question is not "how do I stabilise this test" but "what is the failure telling me". Assuming flakiness is how a production defect gets a `@retry` decorator instead of a fix.

**Then investigate properly.** Run it in a loop until it fails and capture the state at failure; run it in isolation versus in the full suite, since passing alone and failing together points squarely at shared state; check whether it fails only under parallel execution; look at the trace, since `traceparent` propagates through the async hops and Elastic APM will show where the timing actually went.

**The usual causes, roughly in order.**

- *Shared state between tests* — a database row, an Elasticsearch index, a Redis key, a queue not drained. The fix is isolation per test: a transaction rolled back, or a schema and index per worker.
- *A timing assumption.* Sleeping for two seconds and expecting the index to be fresh, when the freshness budget is a p95 of fifteen seconds. The fix is to poll for the condition with a generous bound, or to force an explicit Elasticsearch refresh in test setup rather than guessing.
- *Test-order dependence*, exposed the day the runner shuffles.
- *A genuine race in the code*, which is the outcome you want to find.

**What I would do while investigating.** Move it out of the blocking path — but with a ticket, an owner, and a date, and never by deleting it or wrapping it in a retry. A test that is retried until green is worse than no test: it consumes time and reports success regardless of the truth. If it must be quarantined, the quarantined list should be small, visible, and reviewed, because a growing quarantine is a suite quietly being switched off.

**And the honest escalation.** If the cause turns out to be a real race in the reminder or check-in path, that is not a test problem and it should be raised as a defect with the same weight as a production incident — with the trace and the reproduction, to the technical contact for that area. Reporting "the test is flaky, I have quarantined it" when the truth is "there is a race in the dispatch path" is the kind of quiet inaccuracy that costs a team a great deal later.

</details>

---

### Q3. Coverage is at 90%, every gate is green, and a defect reaches production anyway. What does that tell you, and what would you change?

**Brief answer**
That the gates measure what they can measure, not what matters — and that this particular defect had no observer. The response is to add the specific check that would have caught it, prove that check fails when the defect is reintroduced, and resist the instinct to raise a threshold that was never the problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it does not mean.** It does not mean the gates are worthless or that the coverage target should rise to 95%. Raising a threshold in response to an escape is the most common reaction and usually the least effective: the defect was in the covered 90% or in a category coverage cannot see, and the higher number costs everyone time without addressing either.

**The diagnosis I would run.**

1. **Classify the defect.** Was it a logic error (unit tests should have caught it), an interaction failure (integration), a contract break (contract tests), a silent authorization or audit failure (negative tests), a configuration or infrastructure difference (nothing in the pipeline was ever going to catch it), or a requirement misunderstanding (no test could catch it, because the tests encoded the same misunderstanding)?
2. **Ask why the existing test did not fail.** Usually one of: the code path was executed but nothing asserted the property; the test used a mock that could not exhibit the behaviour; the test asserted the happy path only; or the scenario was outside what anyone thought to write.
3. **Ask whether it was observable in production.** An escape that ran for a week before anyone noticed is two failures — a testing gap and a monitoring gap — and the monitoring one is often the more important, because the next unforeseen defect will also be unforeseen.

**What I would change.**

- Add a test that fails on the defect, and **prove it** by reintroducing the defect and watching it fail. Without that step you have added a test that may or may not detect anything.
- If the category is one the pipeline structurally cannot see — configuration drift, an environment difference, a third-party behaviour change — add a post-deploy check instead. The pipeline already runs a smoke and objective check after sync; that is the right place for it.
- Add or sharpen the production signal, so the *class* of failure is detectable next time even when the specific instance is new.
- If the cause was a requirement misunderstanding, the fix is not in the test suite at all. It is in how the requirement was clarified — which on a project where task descriptions are often abstract means going to the person who owns the business logic before writing code, not after the escape.

**The framing I would bring to the post-mortem.** Every gate is a specific hypothesis about how software fails, and an escape is evidence that one hypothesis was missing. The useful output is a new, narrow check with demonstrated detection — not a tighter version of a check that was never relevant, and not a conclusion about whose fault it was.

</details>

## GitOps Delivery and Observability

---

### Q1. What is GitOps, and what does "no pipeline job holds cluster credentials" actually buy?

**Brief answer**
GitOps means the desired state of the cluster lives in a Git repository and an in-cluster agent reconciles reality toward it. Because ArgoCD pulls rather than the pipeline pushing, no continuous integration job needs cluster credentials — so a compromised pipeline cannot deploy to production.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism here.** GitLab [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") builds, gates, scans, and pushes a digest-pinned image, and its final act is a commit to the GitOps manifest repository recording that digest. ArgoCD, running inside `aro-primary` and `aks-ml`, watches that repository and reconciles both clusters toward what it says. Nothing in the pipeline ever talks to a cluster.

**What that buys, in order of importance.**

- *Credential blast radius.* A pipeline is a large attack surface: every dependency, every runner, every merge request that can execute a job. If it holds cluster credentials, compromising it means compromising production. With pull-based reconciliation the credential lives in the cluster and points *outward* at the repository, so the worst a compromised pipeline can do is propose a manifest change — which is a reviewable commit, not a silent deploy.
- *One rollback mechanism.* Reverting the manifest commit is the rollback for every service, so there is no per-service imperative procedure to remember at three in the morning.
- *Drift detection.* Anything changed by hand in the cluster diverges from the declared state and ArgoCD reports it. The same principle applies to Terraform for the Azure and cluster infrastructure: a resource created by hand is drift and is reported as a failure, so console history stops being a hidden part of the system.
- *An audit trail that is a by-product.* Every change to production is a commit with an author and a review. For a regulated system that is the record an auditor asks for, produced without anyone maintaining it.

**What it costs.** A second repository and the discipline to keep it authoritative. Deployment becomes asynchronous — the pipeline goes green before the change is live, so "deployed" and "merged" are different events and the pipeline cannot report deployment success on its own. That is why the sync ends with a PostSync smoke and objective check: something has to close the loop, and it belongs on the cluster side rather than in the pipeline.

</details>

---

### Q1. Three services use three deployment strategies — blue-green, canary, and rolling. Why not one?

**Brief answer**
Because they fail differently. `care-core` is blue-green for the cleanest possible rollback on the service holding the record; `clinical-nlp-svc` is canary because model regressions are statistical and invisible in a binary switch; `scim-provisioning-svc` is rolling because it has an external, idempotent caller and no user-visible surface.

<details>
<summary><strong>Detailed answer</strong></summary>

**`care-core` — blue-green.** Two complete environments, one Route switch, instantaneous cut-over and instantaneous return. For the service that holds the clinical record, rollback speed and rollback certainty matter more than resource efficiency: you never have a partially-migrated fleet, and reverting is a single switch rather than waiting for pods to roll back. The cost is running two full copies during a release, and the constraint is that both colours run against one database — which is what forces expand/contract migrations and additive event and cache changes.

**`clinical-nlp-svc` — canary at 5%, 25%, 100%.** A bad model does not error; it returns worse output confidently. There is no failure rate to trip a rollback, so the only way to see the regression is to run both versions and compare — confidence distribution, latency, low-confidence counts, and over a longer window the clinical reviewer rejection rate. A binary switch would give the whole population to a regressed model before anyone could measure it.

**`scim-provisioning-svc` — rolling.** Its caller is Entra ID, its operations are idempotent, and a brief mixed-version window is harmless because SCIM retries. There is no user staring at a screen. Blue-green would cost double the resources for a service where nobody would notice the difference.

**Azure Functions deploy via slot swap**, which is the platform's native equivalent of blue-green.

**The principle.** The deployment strategy should be chosen by how the service fails and how much a bad release costs, not standardised for tidiness. Standardising on canary would put a statistical rollout in front of the record service, where the failure is binary and you want an instant switch. Standardising on blue-green would hide model regressions. Being able to say *why* each service has the strategy it has is the difference between a considered delivery design and a template someone copied.

</details>

---

### Q1. What are the three pillars of observability, and how are they joined in this system?

**Brief answer**
Metrics (Prometheus), logs (structured JSON to Elasticsearch), and traces (Elastic APM). They are joined by the [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") `traceparent` propagating on every hop — including AMQP, MQTT, and Service Bus message headers — and by Kibana as a single pane.

<details>
<summary><strong>Detailed answer</strong></summary>

**Metrics** answer "is something wrong, and how wrong" — aggregates, cheap to store, suitable for alerting. Here they are the service level indicators: request duration p95 by route, 5xx rate on mutating routes, `outbox_unpublished_age_seconds`, `reminder_dispatch_lateness_seconds`, consumer task duration and failure ratio by queue, broker queue depth.

**Logs** answer "what exactly happened in this one case". Structured JSON to stdout, shipped to Elasticsearch, every line carrying `trace_id`, `span_id`, `service`, `module`, `actor_kind`, and where applicable `patient_id`.

**Traces** answer "where did the time go, across components". Elastic APM auto-instruments FastAPI, SQLAlchemy, Celery, RabbitMQ, and outbound HTTP.

**The join is what makes them useful.** A single trace covers `POST /diary/check-ins` → `care.events` → `celery.index` → `es-clinical`, because `traceparent` travels in message headers rather than stopping at the process boundary. Without that, an asynchronous system produces three disconnected half-stories and correlating them is manual archaeology. The same reasoning drives shipping Azure Monitor's diagnostics for APIM, Functions, Service Bus, and Blob into the same Elasticsearch deployment: a reminder failing between `celery.reminders` and `fn-notify-dispatch` spans both telemetry planes, and two unjoined stories is not an investigation.

**One deliberate exclusion.** Audit is a database table, never a log stream. Logs are for operators and have an operator's retention policy; audit is for the regulator and has a seven-year one. Conflating them means log retention silently becomes audit policy — and the day someone shortens log retention for cost, the audit trail shortens with it without a decision being made.

**Sampling, which is where cost is controlled.** 100% of errors and of all reminder and NLP traffic, 10% of routine reads. The reasoning is that reminders are the clinical-safety path and models need statistical comparison, while routine reads are high volume and low information — so sampling follows importance rather than a uniform rate.

</details>

---

### Q1. What is the difference between a service level indicator, an objective, and an error budget?

**Brief answer**
An indicator is the measurement, an objective is the target for it, and the error budget is what the objective permits you to spend — the difference between the target and perfection, expressed as time or events.

<details>
<summary><strong>Detailed answer</strong></summary>

A **service level indicator** is a number you actually measure: the proportion of record reads served successfully, or the p95 latency of a route. It has to be measured where the user experiences it, which is a more common mistake than it sounds — Elasticsearch's own `took` figure excludes coordination and network, so an indicator built on it reports a number no user has.

A **service level objective** is a target for that indicator over a window: 99.9% monthly for record read/write and diary capture, 99.5% for search and content generation, 99.5% of reminders delivered within their window.

An **error budget** is the inverse: 99.9% monthly permits roughly 43 minutes of failure, 99.5% permits about 3.6 hours. It is what makes the objective a decision-making tool rather than a wish. Budget remaining means you can ship; budget exhausted means feature work stops and reliability work takes the sprint — which is exactly what this design writes down as the consequence.

**Why the consequences differ by service, which is the interesting part.** Search exhausting its budget degrades to the PostgreSQL chronological fallback rather than erroring, so the consequence is a worse product, not an outage. Content generation exhausting its budget drains a backlog and assigned pages are unaffected. Reminder delivery is different: it is **paged**, and it is explicitly not traded for feature velocity, because a missed reminder is a clinical safety issue rather than a user-experience annoyance. Three objectives, three genuinely different responses — which is what makes them real rather than decorative.

**The judgement an objective encodes.** 99.9% is not "as good as we can manage"; it is a statement that about 43 minutes of monthly unavailability is acceptable and that buying the next nine is not worth what it costs. Here that number is coherent with a design decision made elsewhere: auditing every patient-data read synchronously means read availability is bounded by a roughly sixty-second zone failover, which fits inside 43 minutes. Choosing 99.99% would have meant reopening the audit design. Objectives and architecture constrain each other, and an objective picked without checking that is a number nobody can meet.

</details>

---

### Q2. Alembic migrations run as an ArgoCD PreSync hook. What ordering does that guarantee, and where is it dangerous?

**Brief answer**
It guarantees the schema is applied before any new pod starts, so the code never runs ahead of its schema. It is dangerous because a failed hook blocks the sync, and because a destructive migration in PreSync breaks the currently-running version before its replacement exists.

<details>
<summary><strong>Detailed answer</strong></summary>

**The guarantee.** ArgoCD runs PreSync hooks to completion before applying the rest of the manifests. So `alembic upgrade head` finishes before the new ReplicaSet is created, and the schema is always at or ahead of every running version. That ordering is what lets application code assume its columns exist.

**Why it is only safe with expand/contract.** During a blue-green cut-over the old image is still serving. A PreSync migration that drops a column, renames one, or adds a `NOT NULL` constraint the old code cannot satisfy breaks production *before* the new version is running — and the rollback, an ArgoCD revision revert, restores the old image against the new schema, which is the exact combination just proven broken. So the hook's safety depends entirely on every migration being backwards-compatible with the previous image. That is not a convention; it is the precondition of the rollback story.

**The other failure modes.**

- *A long migration blocks the sync.* A backfill inside a PreSync hook stalls the deployment for its duration and may hit the hook timeout, leaving a half-applied state. Backfills belong in batched background jobs, not in the hook — the hook does schema changes that are fast by construction.
- *Concurrency.* Two syncs, or a retried hook, must not run two migrations at once. [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy")'s version table plus an advisory lock is the answer; without it a retry after a timeout can attempt a migration already in progress.
- *Rollback is not symmetric.* There is no down-migration in this model. Reverting the manifest reverts the image, not the schema. That is a deliberate choice — down-migrations against production data are more dangerous than the forward-only discipline — but it means the schema only ever moves forward, and a genuinely wrong migration needs a new forward migration to correct it.

**What I would verify before trusting it.** That the hook actually fails the sync when the migration fails, rather than being reported as succeeded — a hook whose failure does not block is worse than no hook, because it creates confidence that the schema is current. And I would verify it by breaking a migration deliberately in a scratch environment and watching the sync fail, because a gate that has only ever passed is not evidence of anything.

</details>

---

### Q2. There are two telemetry planes. How are they joined, and what specifically breaks without the join?

**Brief answer**
Prometheus, Elastic APM, and application logs cover the clusters; Azure Monitor covers APIM, Functions, Service Bus, and Blob. They are joined by propagating `traceparent` through Service Bus message headers and by shipping Azure Monitor diagnostics into the same Elasticsearch deployment, so Kibana is one pane.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why two planes exist at all.** The estate genuinely spans two operating models. OpenShift and [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") workloads are instrumented by agents the team controls. APIM, Functions, Service Bus, Event Grid, and Blob are managed services whose telemetry only Azure produces. Neither can be made to cover the other, so the choice is not "one plane or two" but "two joined or two separate".

**The concrete failure without the join.** A reminder is dispatched by `celery.reminders`, enqueued to `sb.notify`, delivered by `fn-notify-dispatch`, and the receipt comes back. If the delivery fails, the cluster plane shows a Celery task that enqueued successfully and then a receipt that never arrived; the Azure plane shows a Function invocation that failed. Nothing connects them. The investigator has two half-stories, a timestamp, and a guess — and reconstructing which of thousands of dispatches corresponds to which invocation is manual work performed under incident pressure. That is not a hypothetical inconvenience; reminder delivery is the paged clinical-safety objective, so it is the one path where an unjoined investigation is least acceptable.

**How the join is built.** The `traceparent` header travels in the Service Bus message, so the Function's telemetry carries the same trace identifier as the Celery task that enqueued it. Azure Monitor diagnostic logs are shipped into the Elastic deployment, so a Kibana query on `trace_id` returns spans and log lines from both sides in one timeline. The correlation identifier is the same one already carried through AMQP and used in every application log line and every `audit_event` row — which means an incident investigation and a compliance question can be answered from the same key.

**Where I would expect the join to be weakest.** MQTT 3.1.1 has no user-property mechanism for context propagation, so the device-to-broker hop cannot carry `traceparent` in a header. The design flags this and offers two options — move clients to MQTT 5, or carry the context inside the payload envelope — and notes the decision has to be made before instrumenting, because retrofitting it breaks every published client. That is the right call: the cost of choosing late is borne by mobile clients that update slowly, which makes it effectively irreversible.

</details>

---

### Q2. No clinical free text is ever logged, enforced by a redaction filter and a pipeline check. How does that work, and where could it leak anyway?

**Brief answer**
Sensitive fields are marked on the Pydantic models, a logging formatter drops them, and a pipeline check fails the build if a log call passes a model containing a marked field. It leaks through anything that bypasses the models — exception messages, database driver errors, third-party libraries, and URLs.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.** The marks live on the model next to the field, so "this must never be logged" is declared once at the definition rather than remembered at every call site. The redaction filter runs at the formatter, which is the last point before output and therefore catches every logger in the process, including ones added later by someone unaware of the rule. The pipeline check adds a static gate so the failure is caught at merge rather than discovered in a log index that already contains the data.

**Why it matters more than it sounds.** Logs are shipped to Elasticsearch and queryable in Kibana by operators, who have no routine patient-data access by design — `platform_operator` is explicitly excluded from the record. Clinical free text in a log stream hands them exactly what the role model withholds, without an audit row, in a store with an operator's retention policy rather than the record's.

**Where it leaks anyway, which is the more useful half of the answer.**

- **Exception messages.** A database driver's integrity error can quote the offending row. A validation error can echo the invalid value. Tracebacks capture local variables in some configurations. None of this passes through a Pydantic model, so none of it is caught by the filter.
- **Third-party library logging.** An HTTP client at debug level logs request bodies. A search client logs the query — which contains the clinician's search terms, themselves clinical content. These loggers must be configured explicitly, and the default is usually wrong.
- **URLs and query strings.** A search term in a query parameter reaches access logs at the gateway, the ingress, and the application. The design's rule that no patient identifier appears in a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") path that is not already token-scoped points the right way, but search terms are the case people forget.
- **Structured context added ad hoc.** A developer adds `extra={"note": note}` for debugging. If `note` is a raw string rather than a marked model, the filter never sees a mark.
- **Aggregate leakage.** A log line saying a patient viewed a page about a specific treatment is clinical information even with no free text in it.

**What I would add.** A canary test that emits known sentinel values through the paths above — an exception carrying the sentinel, a third-party debug log, a query parameter — and asserts none reaches the log index. That converts "we have a filter" into "we have evidence the filter covers the routes data actually takes", which is a different and much stronger claim.

</details>

---

### Q2. A patient reports they never received an appointment reminder. Walk me through the investigation.

**Brief answer**
Start in the database, not the logs: the `reminder` row and its `reminder_delivery` attempts give the state machine's own account. Then use the `trace_id` to follow the dispatch across Celery, Service Bus, and the Function, and the provider receipt to determine whether it was the platform or the channel that failed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step 1 — ask the database what it believes.** Find the `reminder` row for that patient and subject. Its `state` distinguishes the four possibilities immediately: `pending` and overdue means the sweep never claimed it; `dispatching` means it was claimed and never resolved; a `reminder_delivery` row with state `failed` means a channel rejected it; `delivered` means the platform did its job and the failure is downstream or in the patient's device. This is the whole reason every attempt is a row rather than a log line — the first question is answered by a query in seconds, not by grepping.

**Step 2 — follow the branch.**

- *Never scheduled.* Did the appointment carry a `reminder_policy`, and did the creation path write a `reminder` row? This is an application bug, not a delivery one.
- *Pending and overdue.* Celery beat stopped, or the sweep is failing. `reminder_dispatch_lateness_seconds` should already have paged, so check whether it did — if it did not, there is a second defect in the alerting.
- *Stuck dispatching.* A receipt was lost, or the worker crashed after claiming and before enqueuing. The dead-letter queue on `sb.notify` is the first place to look.
- *Failed.* Read the provider error. An invalid number or an unsubscribed push token is a data problem; a provider 5xx is a channel problem; and the retry-then-alternate-channel-then-care-team-flag escalation should have run — if it did not, that path is broken.
- *Delivered.* The provider accepted it. Now the question is device-side: notifications disabled, an email in spam, a number changed. Worth being precise that "delivered" means the provider acknowledged, which is not the same as the patient seeing it — overstating that distinction is how an investigation stops one step early.

**Step 3 — use the trace for anything ambiguous.** The `trace_id` on the delivery row joins the Celery span, the Service Bus hop, and the Function invocation in Kibana, because Azure Monitor telemetry is shipped into the same place. That is what makes a cross-plane failure a single query rather than two investigations.

**Step 4 — decide whether it is one or many.** `reminder_delivery_total{state}` by channel over the period tells you immediately whether this is an individual case or a channel-wide failure with one patient as the presenting symptom. Answering that before going deep is what stops a systemic outage being investigated as an anecdote.

**Step 5 — close the loop.** If the cause was a gap in detection rather than in delivery, the fix is the alert, not the reminder. And it goes in the shared runbook, because the next person to see this symptom should not repeat the investigation.

</details>

---

### Q2. MQTT 3.1.1 has no header for trace context. What do you do, and why does the decision have to be made early?

**Brief answer**
Either move check-in clients to MQTT 5, which has user properties, or carry `traceparent` inside the payload envelope. It has to be decided before instrumenting because retrofitting it breaks every published client — and mobile clients update slowly.

<details>
<summary><strong>Detailed answer</strong></summary>

**The problem.** Distributed tracing needs the context to travel with the message. AMQP has headers, Service Bus has application properties, HTTP has headers. MQTT 3.1.1 has none — the packet carries a topic and a payload, and nothing else you can use. So the trace that starts on the patient's device dies at the broker, and the span for the projection into `pg-clinical` and the index write begins a new, unconnected trace.

**Option one — MQTT 5.** User properties are exactly this mechanism, and they are the clean answer: the context stays out of the payload, so the message schema is unchanged and the broker and any intermediary can see it. The constraint is client support across the mobile platforms and library versions in use, and whether the RabbitMQ MQTT plugin's version supports it fully.

**Option two — an envelope field.** Wrap the check-in payload in `{traceparent, payload}`. Works on any MQTT version, but the context is now part of the message schema, so every publisher and consumer must agree on it, and adding it later is a schema change — which is where the timing problem bites.

**Why the decision cannot be deferred.** Published mobile clients are the slowest-updating component in any system. A patient who has not updated the app in six weeks is normal. Changing either the protocol version or the payload shape after clients are in the field means supporting both indefinitely, or losing check-ins from clients that have not updated — and losing a check-in is the exact failure the whole MQTT path exists to prevent. So this is a decision whose cost multiplies with delay, which is a good reason to make it before the first client ships rather than when tracing gaps become annoying.

**What I would choose, and how I would frame it.** MQTT 5 if client support allows, because keeping transport concerns out of the message schema is worth a lot over time. The envelope otherwise, defined generously from the start — a `meta` object rather than a single field — so that adding the next piece of context is not another breaking change. And I would raise it as a decision needing a call with whoever owns the mobile clients, rather than picking one unilaterally, since the constraint that decides it lives on their side.

</details>

---

### Q3. Of the alerts in this design, which would you page a human for at three in the morning, and which are dashboards?

**Brief answer**
Page for what is clinically unsafe or silently losing data: reminder lateness and failure ratio, SCIM sync failure, write availability. Dashboard the rest. The test is whether a human waking up can do something that matters before the metric would have recovered on its own.

<details>
<summary><strong>Detailed answer</strong></summary>

**Page.**

- **`reminder_dispatch_lateness_seconds` p99 above five minutes**, and a `failed` delivery ratio above 2%. Reminder delivery is the clinical-safety objective and the design says explicitly it is not traded for feature velocity. A missed reminder is a patient not taking a treatment.
- **SCIM sync failure.** A deprovisioning that did not land is access that should have ended and has not. It is a security event wearing the costume of a background job, and it will never resolve itself.
- **Write availability — 5xx on mutating routes above 0.1% over five minutes.** A clinician cannot record a visit note. Nothing recovers this without intervention.
- **Broker queue depth above 10K or rising for fifteen minutes**, because the endpoint of that trend is a memory alarm blocking publishers, and the leading indicator is the only point at which a human can act cheaply.

**Dashboard, or a ticket the next working day.**

- **`outbox_unpublished_age_seconds` above 30 s for five minutes.** This is a judgement call and I would argue it either way. Sustained, it means search is going stale and the backlog is growing — but nothing is lost, the outbox is durable, and it drains on recovery. I would start it as a high-priority daytime alert and promote it to a page only if experience showed it reliably precedes something worse.
- **Search latency p95 above 400 ms.** Search degrades to the chronological fallback and has a 3.6-hour budget. Nobody needs to wake up.
- **NLP queue depth and low-confidence counts.** Generation pauses, assigned pages are unaffected. Daytime.
- **Consumer error rate above 1% over fifteen minutes** — depends on the queue. On `celery.reminders` it escalates; on `celery.index` it is a ticket.
- **Record read latency p95 above 250 ms.** Degraded, not broken.

**The principles I would apply.**

*Page on symptoms, not causes.* A page should correspond to something a user is experiencing or about to experience. Alerting on every cause produces five pages for one incident and teaches people to silence them.

*Every page needs a runbook entry.* If the responder cannot do anything, it should not have woken them — that is the definition of alert fatigue, and fatigue is what makes the *real* page get acknowledged and ignored.

*Alert on the leading indicator where one exists.* Queue depth rather than memory alarm; outbox age rather than user-visible staleness.

*Review the alerts after every incident.* Which fired, which should have, which were noise. An alert set that is never pruned only grows, and its signal-to-noise ratio only falls.

</details>

---

### Q3. Terraform, ArgoCD, and GitLab CI are three declarative systems with overlapping reach. How do you keep one owner per fact?

**Brief answer**
Terraform owns cloud and cluster infrastructure, ArgoCD owns everything inside the clusters, and GitLab CI owns building and gating — it deploys nothing. The boundary that needs deliberate care is the handful of resources both Terraform and Kubernetes can create.

<details>
<summary><strong>Detailed answer</strong></summary>

**The clean division.** Terraform provisions Azure and the clusters themselves: resource groups, networking and peering, private endpoints, `pg-clinical`, `blob-documents`, `sb-integration`, Key Vault, APIM, Front Door, and the OpenShift and AKS clusters including the GPU node pool. State lives in Azure Storage; environments are the same code with different variable files. ArgoCD owns what runs inside the clusters: Deployments, Services, Routes, ConfigMaps, NetworkPolicies, the Celery workers, the operators for `rmq-core`, `mongo-content`, and `es-clinical`. GitLab CI builds images, runs gates, and commits a digest to the GitOps repository — it holds no cluster credentials and performs no deployment.

**Where they genuinely overlap, and how I would resolve each.**

- *Secrets.* Terraform creates Key Vault and the secrets; workloads reach them by workload identity federation and they are projected as files. So Terraform owns the secret's existence and the cluster owns its consumption — and crucially, no secret is ever materialised into a Kubernetes manifest in the GitOps repository, which would put it in Git.
- *Identity and role assignments.* Workload identity involves both a managed identity in Azure and a ServiceAccount in the cluster. Terraform owns the Azure side and the federation; the manifests own the ServiceAccount. Splitting it any other way produces two systems each believing they own the binding.
- *Namespaces and cluster-level policy.* I would put these in Terraform if they are part of the cluster's construction and in ArgoCD if they are part of the workload's definition — and, more importantly, write down which, because this is the exact place where a resource ends up declared twice and the two systems fight, each reverting the other on its own reconciliation cycle. That failure presents as intermittent, self-healing weirdness and is genuinely unpleasant to diagnose.
- *Database schema.* Owned by neither. Alembic owns it, applied through the ArgoCD PreSync hook. Terraform creates the server; it does not create tables.

**The enforcement.** Drift is a failure in both systems: a hand-made Azure resource is reported by `terraform plan` in the pipeline, and a hand-edited Kubernetes object is reported by ArgoCD as out of sync. Production Terraform applies go through a plan-review gate. The combination means the declared state and reality cannot silently diverge — which is the property that makes "the repository describes production" a fact rather than a hope.

**The rule I would state in a review.** Every resource has exactly one system that creates it, and the others reference it. When two could, pick one and write down why — because the cost of ambiguity here is not confusion, it is two controllers reconciling in opposite directions.

</details>

---

### Q3. Task descriptions arrive abstract, estimates are frequently wrong, and one runbook spans diary, content, and identity. How do you run your work so nobody has to ask where you are?

**Brief answer**
Clarify before coding rather than guessing, keep the remaining estimate in the tracker current daily so the number is trustworthy without anyone chasing it, and treat the shared runbook as a deliverable of each release rather than something written after an incident.

<details>
<summary><strong>Detailed answer</strong></summary>

**Abstract requirements.** A ticket that says "improve the timeline" is not a blocker, it is the normal starting condition. What I do is write my own understanding down first — the endpoints affected, the data involved, what I believe "improved" means, and the two or three points where I could be wrong — and then take that to whoever owns the business logic. Arriving with a specific reading to confirm or correct is far more efficient for them than arriving with an open question, and it usually converts a thirty-minute meeting into a five-minute one. Then the clarified understanding goes back into the ticket, so the next person does not repeat the conversation. What I would not do is wait for a better ticket, and I would not guess and build the wrong thing quietly.

**Estimates that slip.** A three-day task becoming a week is common and mostly not a failure — it is discovering the real shape of the work. What matters is that the person planning around it knows on day two rather than day five. So I update remaining estimate daily, and when something changes materially I say so with the reason: "the migration needs batching because the table is larger than I assumed; that is two more days". A stale estimate is worse than a wrong one, because a wrong estimate that is updated is information and a stale estimate is misinformation someone is planning against.

**Blockers.** Raised the day they appear, with what I have tried and what I need, to the right technical contact — and I keep working on something else in the meantime rather than treating the blocker as a stop.

**The shared runbook.** One operational document spanning diary, content, and identity deploys is a real asset and it decays fast. I treat it as part of the change: if a release adds a step, changes a rollback, or adds an alert, the runbook entry is part of that merge request, not a follow-up. After an incident, the entry gets what was actually done — including the parts that did not work, which are the most useful lines in any runbook. And the restore rehearsal is the forcing function: a quarterly rehearsal against a scratch environment finds the runbook steps that stopped being true, which is precisely why the rehearsal is worth more than the document alone.

**The underlying attitude.** Process work on a project like this is not overhead separate from engineering — daily tracker updates, accurate time, standups, an accurate runbook. It is what lets a team of people who are not in the same room plan around each other. I would rather be the person whose status is always current and boring than the person whose work is invisible until it lands.

</details>

---

### Q3. The dashboards say p95 is well within target, but clinicians say the timeline is slow. Reconcile that.

**Brief answer**
Almost always the metric and the experience are measuring different things: a percentile hides the tail a specific user lives in, the measurement excludes part of the path, or the aggregate mixes populations. Find the population whose experience differs, and measure where the user is.

<details>
<summary><strong>Detailed answer</strong></summary>

**The candidate explanations, in the order I would test them.**

1. **The tail is the experience.** p95 within 250 ms means one request in twenty is worse, and a clinician making 200 calls a day meets the slow ones ten times. Check p99 and the maximum. A per-user percentile is the honest view for a workflow complaint: a global p95 can be healthy while a specific clinician's personal p95 is terrible.
2. **The measurement excludes part of the path.** `http_request_duration_seconds` is measured inside the application. It excludes Front Door, APIM, [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") negotiation, the clinician's network — often hospital wifi — and every millisecond of frontend rendering. A 120 ms server response inside a 2-second page load is a true metric and an irrelevant one. Azure Monitor covers the gateway side, and real-user monitoring in the browser covers the rest; without both, the server metric is a claim about a fragment.
3. **The aggregate mixes populations.** Patient timeline reads are small and cache-friendly; a clinician opening a patient with five years of history is not. A single p95 across both is dominated by the numerous cheap requests. Breaking the metric down by actor kind, and by record size, usually makes the complaint appear immediately.
4. **It is a different operation than reported.** "The timeline is slow" often means the search that precedes it, or the document that fails to open, or a synchronous call the frontend makes before rendering. The trace for a real slow session is the fastest way to find out which.
5. **Cold versus cached.** The target is under 120 ms cached and under 250 ms cold, and the timeline cache has a 60-second time-to-live with invalidation on any write for that patient. A clinician working actively on a record invalidates their own cache repeatedly, so they may be on the cold path almost every time — meaning the users with the worst experience are the ones using the product most.

**How I would settle it.** Get one specific complaint with a timestamp and a user, pull that trace, and look at where the time actually went. One real trace beats an hour of dashboard theorising, and it also tells the clinician they were listened to — which matters, because the next report will be more precise as a result.

**And the conclusion I would be willing to reach.** That the service level indicator is measuring the wrong thing. If the number is green and users are unhappy, the number has failed at its only job. Adding client-side timing and a per-user percentile, and re-baselining the objective against it, is a better response than defending an indicator that no longer describes anyone's experience.

</details>

