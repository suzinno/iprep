# Fundamental Topics: Message Brokers

**Table of Contents**

**[Common Topics](#common-topics)**

- [1. RabbitMQ and Kafka Compared](#1-rabbitmq-and-kafka-compared)
- [2. Async and Sync Communication Compared](#2-async-and-sync-communication-compared)
- [3. Push and Pull Models in Message Brokers](#3-push-and-pull-models-in-message-brokers)
- [4. Async Communication Protocols](#4-async-communication-protocols)

**[RabbitMQ Topics](#rabbitmq-topics)**

- [5. Core Concepts: Exchanges, Queues and Streams](#5-core-concepts-exchanges-queues-and-streams)
- [6. Routing: Fanout, Direct and Topic](#6-routing-fanout-direct-and-topic)
- [7. Consumer Acknowledgements](#7-consumer-acknowledgements)
- [8. Publisher Confirms](#8-publisher-confirms)
- [9. Dead Letter Queues](#9-dead-letter-queues)
- [10. Durable and Ephemeral Queues](#10-durable-and-ephemeral-queues)
- [11. Quorum Queues](#11-quorum-queues)
- [12. Queues and Streams Compared](#12-queues-and-streams-compared)
- [13. Bindings](#13-bindings)
- [14. Remote Procedure Calls over RabbitMQ](#14-remote-procedure-calls-over-rabbitmq)

**[Kafka Topics](#kafka-topics)**

- [15. Topics and Partitions](#15-topics-and-partitions)
- [16. Consumer Groups](#16-consumer-groups)
- [17. Offsets and Their Management](#17-offsets-and-their-management)
- [18. Exactly-Once Delivery and Processing End to End](#18-exactly-once-delivery-and-processing-end-to-end)
- [19. Partitions for Throughput and Partitions for Redundancy](#19-partitions-for-throughput-and-partitions-for-redundancy)
- [20. Cluster Replication](#20-cluster-replication)
- [21. In-Sync Replicas](#21-in-sync-replicas)
- [22. Rebalancing and Re-partitioning](#22-rebalancing-and-re-partitioning)
- [23. Leader Election](#23-leader-election)
- [24. Data Retention Settings](#24-data-retention-settings)
- [25. The Cluster Controller](#25-the-cluster-controller)
- [26. ZooKeeper and KRaft Quorums](#26-zookeeper-and-kraft-quorums)
- [27. Controller Metadata and Broker Metadata](#27-controller-metadata-and-broker-metadata)
- [28. Kafka Connect](#28-kafka-connect)
- [29. Change Data Capture with Debezium](#29-change-data-capture-with-debezium)
- [30. Schema Registry](#30-schema-registry)
- [31. Kafka Streams](#31-kafka-streams)

**What this is.** The message-broker topics a backend engineer is expected to reason about rather than recite, taken from the list in `docs/tmp/common-kb/MBs.txt`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. The subject names its own reference technologies — [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") for the broker-and-queue model and [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") for the distributed-log model — because the two are the standard pair an interviewer compares, and because almost every concept in messaging appears in one shape in each. [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") and [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications") are the reference protocols for the same reason: they are the two most often named at the edge and inside the datacentre respectively.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1, 5 and 15 are the ones you are most likely to be asked. The grouping follows `MBs.txt`: what holds for messaging in general, then what is specific to RabbitMQ, then what is specific to Kafka.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 146 MUST, 62 NICE and 31 OPTIONAL across 31 topics. The proportion is higher on MUST than a topic list usually warrants, and that is what the source list is: broker fundamentals asked as a proxy for whether distributed-systems reasoning is there at all, rather than a survey of range.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.
## Common Topics

## 1. RabbitMQ and Kafka Compared

**Why it comes up:** it is the "can you choose a broker for a reason rather than a habit" question, and almost every later topic is a detail of one side of it.

- **MUST** — The one-line difference: a queue that forgets against a log that remembers

  <details><summary><strong>Answer</strong></summary>

  RabbitMQ is a **message broker**: a producer hands a message to an exchange, the broker routes it into one or more queues, a consumer takes it, acknowledges it, and the broker deletes it. The queue is a buffer whose healthy steady state is empty. Kafka is a **distributed log**: producers append to partitions, records stay for a configured retention period whether or not anyone has read them, and each consumer tracks its own offset into the log.

  That single difference explains nearly everything downstream. Replay, several independent consumer groups reading the same data, and moving back to a past position are free in Kafka and absent in RabbitMQ; per-message routing, per-message acknowledgement and per-message redelivery are natural in RabbitMQ and awkward in Kafka.

  The line worth saying is that Kafka's storage is the feature rather than an implementation detail of its queueing.

  </details>

- **MUST** — Throughput: where each one's ceiling comes from

  <details><summary><strong>Answer</strong></summary>

  Kafka's ceiling comes from sequential appends and batching: records go to the end of a per-partition segment file, the producer batches them by `linger.ms` and `batch.size`, and consumers are served from the page cache, so the broker does very little work per individual message. Throughput scales by adding partitions, because a partition is the unit of parallelism for storage and for consumption alike.

  RabbitMQ does per-message work — match the message against an exchange's bindings, track each unacknowledged delivery, remove the message on ack — so its cost is per message rather than per batch, and one queue is effectively one Erlang process and therefore one bottleneck however large the cluster. **The scaling move is** more queues, through sharding or a consistent-hash exchange, not a bigger one.

  Quoting figures without the message size and the durability settings is meaningless: a broker running `acks=1` is a different machine from the same broker running `acks=all` against three replicas, and the honest answer names the settings before the number.

  </details>

- **MUST** — Fault tolerance: quorum queues and partition replicas are the same idea in different shapes

  <details><summary><strong>Answer</strong></summary>

  Both replicate, and both make you choose between losing data and losing availability. Kafka replicates each partition across brokers; a write with `acks=all` is acknowledged once every in-sync replica holds it, and `min.insync.replicas` is what stops the cluster accepting a write only one machine has. RabbitMQ's quorum queues replicate a queue's log across an odd number of nodes by consensus and acknowledge on a majority.

  **The difference is** what failover moves. A topic has many partitions spread over many brokers, so losing a broker moves leadership for a fraction of them while the rest keep serving. A RabbitMQ classic queue lives on exactly one node and is simply unavailable while that node is down — which is why mirrored classic queues were deprecated and removed, and why quorum queues are the current answer for anything that must survive a node loss.

  Naming replication factor 3 with `min.insync.replicas=2` as the standard safe pairing, and explaining why 2 rather than 3, is the sentence that separates operating a cluster from reading about one.

  </details>

- **MUST** — Delivery guarantees: both are at-least-once, and what exactly-once means on each

  <details><summary><strong>Answer</strong></summary>

  Both default to **at-least-once** and both expect the consumer to be idempotent. RabbitMQ gives publisher confirms on the way in and consumer acknowledgements on the way out; a redelivery after a lost ack is normal operation, and the `redelivered` flag is a hint rather than a count.

  Kafka's idempotent producer removes the duplicates that producer retries create within a partition, and its transactions make a read-process-write loop atomic across the records written and the offsets committed — which is exactly-once **inside Kafka**. Neither system can make an effect outside itself exactly-once: an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") call or a non-transactional database write in the consumer is at-least-once whatever the broker does.

  The answer being listened for is that exactly-once is a property of the whole path, and that its practical form is at-least-once delivery into an idempotent sink.

  </details>

- **MUST** — Choosing: the questions that actually decide it

  <details><summary><strong>Answer</strong></summary>

  Ask what the data is. If consumers need to replay history, if more than one independent consumer needs the same stream, or if ordering per key has to hold over a long window, that is a log and the answer is Kafka. If the work is a task queue — give this job to whichever worker is free, retry it, give up after a few attempts and dead-letter it, hold a per-message deadline — that is RabbitMQ, and building it on Kafka means reimplementing routing and per-message retry by hand.

  Latency and fan-out shape the rest: RabbitMQ pushes the moment a message arrives, while a Kafka consumer polls and trades a few milliseconds for batching. Volume decides it far less often than people expect, because most systems sit nowhere near either ceiling.

  A good answer refuses the question as posed and names the workload first. "Kafka because it is faster" is the version that fails.

  </details>

- **NICE** — Quality of Service in the [IoT](https://en.wikipedia.org/wiki/Internet_of_things "Internet of Things — Networked physical devices that report telemetry and receive commands over constrained links") world, and why MQTT usually sits in front of either broker

  <details><summary><strong>Answer</strong></summary>

  MQTT is the device-side protocol and its [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") levels are chosen per message: 0 is at-most-once, fire and forget; 1 is at-least-once, confirmed by a [PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message") and therefore duplicable; 2 is exactly-once through a four-packet handshake costing two round trips and broker-side state per message. Fleets on flaky links usually run QoS 1 and deduplicate on the server, because the cost of QoS 2 is real and its guarantee stops at the broker.

  The common shape is MQTT at the edge terminating in a broker that bridges into Kafka or RabbitMQ for the backend, because MQTT is good at very many intermittently connected sessions and has nothing to say about replay or stream processing. The bridge is where the guarantee must be re-established: an at-least-once MQTT delivery followed by an at-least-once produce is still at-least-once, and a device-supplied message identifier is what lets the backend deduplicate.

  </details>

- **NICE** — Consumer scaling: competing consumers against partition assignment

  <details><summary><strong>Answer</strong></summary>

  RabbitMQ uses competing consumers: any number of consumers subscribe to the same queue, the broker gives each message to one of them, and adding a consumer adds throughput immediately. Kafka assigns whole partitions to the members of a consumer group, so consumers beyond the partition count sit idle and the partition count becomes a capacity decision taken when the topic is created.

  **The consequence is** that Kafka couples parallelism to ordering — a key always lands in the same partition and is processed by one consumer in order — while RabbitMQ surrenders ordering the moment there is a second consumer. Which of those two you need is usually the real question hiding behind "which broker".

  </details>

- **OPTIONAL** — Operational cost and the ecosystem around each

  <details><summary><strong>Answer</strong></summary>

  Kafka is a cluster with replication, a controller quorum, partition rebalancing and a large ecosystem around it — Connect, Streams, a schema registry — and it expects people who operate it. RabbitMQ runs happily as a single node, has a management interface most teams can use on day one, and becomes operationally interesting only once clustering and quorum queues are in play.

  Managed offerings flatten most of this, so the honest framing is that the operational argument weighs heavily for a self-hosted deployment and very little for a team already paying for a managed cluster.

  </details>

## 2. Async and Sync Communication Compared

**Why it comes up:** it is the question behind every "should this be an event" decision, and a loose answer usually predicts a distributed monolith held together by synchronous calls.

- **MUST** — What actually differs: temporal coupling, not a language keyword

  <details><summary><strong>Answer</strong></summary>

  **Synchronous** here means the caller's progress depends on the callee being available and answering now: request goes out, the caller waits, and the callee's latency and failure become the caller's. **Asynchronous** means the caller hands the message to a durable intermediary and continues; the receiver may process it in a second or an hour, and may not exist yet when the message is sent.

  The distinction is temporal coupling, not a non-blocking client library. An `async def` function calling an HTTP endpoint and awaiting the response is still synchronous communication — it frees a thread, not the dependency. Getting this right in the first sentence matters, because interviewers hear the confusion often.

  </details>

- **MUST** — What asynchrony buys

  <details><summary><strong>Answer</strong></summary>

  Three things, and naming them separately is the good answer. Availability: the sender succeeds while the receiver is down, so a deployment or an outage downstream becomes a growing queue rather than a failed request. Load levelling: a burst is absorbed by the queue and drained at the consumer's pace, so capacity is sized for the average rather than the peak. Fan-out: a new consumer subscribes without the producer knowing, so adding a search indexer or an audit trail is not a change to the service that emits the event.

  The multiplicative failure argument is worth making explicitly — a synchronous chain of five services each at 99.9% gives roughly 99.5% end to end, while a broker turns four of those dependencies into ones that can be down without the user seeing it.

  </details>

- **MUST** — What it costs

  <details><summary><strong>Answer</strong></summary>

  You trade a simple failure for a hard one. The write is now eventually consistent, so a user who creates something and immediately reads it may not see it, and the interface has to say "processing" rather than lie. Ordering stops being free: two messages about the same entity can be handled out of order or concurrently, so handlers need to be idempotent and often need a version or timestamp to reject stale updates.

  Debugging is the underrated cost. A synchronous failure gives a stack trace and a status code at the moment of the call; an asynchronous failure gives a message sitting in a dead letter queue an hour later with no caller left to return to, which is why correlation identifiers and distributed tracing stop being optional the moment a broker appears.

  **The judgment being tested is** whether you treat these as consequences to design for rather than as surprises to discover in production.

  </details>

- **MUST** — Request-reply over a broker is still request-reply

  <details><summary><strong>Answer</strong></summary>

  Sending a request onto a queue, waiting for a correlated reply and blocking the caller reintroduces every property of a synchronous call — temporal coupling, a timeout to choose, a caller holding state — and adds broker hops and a reply queue to operate. It is occasionally the right thing, usually for load levelling in front of a slow worker or to reach a service that only speaks the broker's protocol.

  Most of the time it is a sign the interaction was never asynchronous in nature and a direct call would be simpler and easier to debug. Saying plainly that a broker does not make a synchronous interaction asynchronous is a strong answer, because the anti-pattern is common.

  </details>

- **MUST** — Choosing per interaction, not per system

  <details><summary><strong>Answer</strong></summary>

  The decision belongs to each interaction. If the caller needs the result to continue — a price, an authorization decision, a validation — that is synchronous, and wrapping it in a queue only hides the dependency. If the caller is announcing that something happened and does not need to know who cares, that is an event and it belongs on a broker.

  The useful test is what the caller does with a failure. If the only sensible response is to retry later, the retry belongs to the infrastructure and the call should have been a message. If the caller must tell the user something different depending on the answer, it has to be synchronous.

  Real systems mix both, and an answer that declares one style correct is a weaker answer than one that gives the rule for picking.

  </details>

- **NICE** — The transactional outbox, where a database write and a publish meet

  <details><summary><strong>Answer</strong></summary>

  The common bug in asynchronous systems is "save the row, then publish the event": a crash between the two loses the event silently, and no retry can recover it because nothing recorded that it was owed. The **transactional outbox** fixes it by writing the business row and an outbox row in the same local transaction, then having a separate relay read the outbox and publish, deleting or marking rows once the broker confirms.

  **The cost is** at-least-once publication — the relay can crash after publishing and before marking — so consumers must deduplicate. The relay itself is either a poller or a change data capture connector reading the database log, which is where this topic meets [CDC](https://en.wikipedia.org/wiki/Change_data_capture "Change Data Capture — Streams row-level changes out of a database by reading its transaction log").

  </details>

- **NICE** — Backpressure behaves differently in each

  <details><summary><strong>Answer</strong></summary>

  A synchronous call applies backpressure by construction: a slow callee makes the caller slow, which is unpleasant but visible immediately, and the usual protections are timeouts, bulkheads and a circuit breaker. Asynchronous communication removes that feedback — the producer keeps accepting work at full speed while the queue grows, and nothing is obviously wrong until the queue is hours deep or the broker hits a resource limit.

  That is why consumer lag, and not broker health, is the metric to alert on, and why a queue needs a declared maximum length with a stated policy for what happens when it is reached.

  </details>

- **OPTIONAL** — The hybrid shapes

  <details><summary><strong>Answer</strong></summary>

  Most production designs are mixed: a synchronous call that validates and returns an identifier, with the slow work published as an event and the result delivered later over polling, WebSocket or a callback. Command Query Responsibility Segregation is the same idea taken further, with writes going through events and reads served from a projection built by a consumer.

  Being able to describe the handoff — what the user sees between the accepted request and the finished work — is what makes the pattern sound implemented rather than read about.

  </details>

## 3. Push and Pull Models in Message Brokers

**Why it comes up:** it is a proxy for whether you know where flow control lives, which is the first thing that breaks when a consumer is slower than a producer.

- **MUST** — The two models in one sentence each

  <details><summary><strong>Answer</strong></summary>

  In a **push** model the broker sends messages to a subscribed consumer as they arrive; the consumer is passive and the broker decides the rate. In a **pull** model the consumer asks for a batch of records whenever it is ready; the broker is passive and the consumer decides the rate. RabbitMQ pushes, Kafka pulls, and almost every practical difference in their consumer APIs follows from that.

  The reason the question is asked is the next sentence: whoever chooses the rate is where you must implement flow control, and whoever does not choose it needs a way to say stop.

  </details>

- **MUST** — Why Kafka pulls

  <details><summary><strong>Answer</strong></summary>

  A pulling consumer can never be overwhelmed, because it asks for the next batch only when it has finished the last one — so the slow-consumer problem that requires a credit protocol in a push system does not exist. Pull also makes batching natural: the consumer requests up to `max.poll.records` or `fetch.max.bytes` at a time and the broker serves a contiguous range straight from the log, which is what makes reading cheap.

  Pull is what makes replay possible at all. A consumer that names its own offset can rewind to an arbitrary position, and a broker that pushed would have to keep per-consumer state to offer the same thing.

  **The cost is** that an idle consumer polls a broker with nothing to give it, which is wasted work and added latency — solved by long polling rather than by abandoning the model.

  </details>

- **MUST** — Why RabbitMQ pushes, and what prefetch does

  <details><summary><strong>Answer</strong></summary>

  Push gives the lowest possible latency: the message reaches a waiting consumer as soon as it is routed, with no poll interval in between, which suits task queues where an idle worker should start work immediately. The broker also gets to pick which consumer receives a message, which is what makes competing consumers and fair dispatch possible.

  **Prefetch** — `basic.qos` with a prefetch count — is the credit mechanism that stops push becoming a flood: it caps how many unacknowledged messages one channel may hold, so the broker stops sending until acks come back. A prefetch of 1 gives the fairest dispatch and the most round trips; an unlimited prefetch hands the whole queue to whichever consumer connected first, which is the classic mistake of one worker at 100% and three idle.

  Choosing prefetch by processing time is the practical answer: low for slow, uneven jobs so work spreads, higher for fast uniform jobs so throughput is not dominated by round trips.

  </details>

- **MUST** — Where backpressure lives in each

  <details><summary><strong>Answer</strong></summary>

  In Kafka, backpressure is implicit and invisible: a slow consumer simply falls behind, records accumulate in a log that was going to hold them anyway, and the only symptom is growing consumer lag. Nothing breaks until lag exceeds retention, at which point the consumer's next fetch fails or silently resets to the earliest available offset and records are lost to that consumer for good.

  In RabbitMQ, backpressure reaches the producer. Unacknowledged messages pile up to the prefetch limit, the queue grows, and the broker's memory and disk alarms eventually block publishing connections outright — a publisher that suddenly stops is usually a consumer problem, not a network problem.

  The pairing worth naming is that Kafka's failure mode is silent data loss past retention and RabbitMQ's is a stalled producer, so the alert is consumer lag on one and blocked connections plus queue depth on the other.

  </details>

- **NICE** — Long polling removes most of pull's latency cost

  <details><summary><strong>Answer</strong></summary>

  A Kafka fetch carries `fetch.min.bytes` and `fetch.max.wait.ms`: the broker holds the request open until it has enough data or the wait expires, so an idle consumer makes one parked request rather than a tight loop, and a record arriving mid-wait is returned immediately. With the defaults the added latency is small, and raising `fetch.min.bytes` deliberately trades latency for larger batches and less broker work.

  Knowing that the consumer is not spinning is the detail that shows the model was understood rather than repeated.

  </details>

- **NICE** — RabbitMQ can pull, and why you should not

  <details><summary><strong>Answer</strong></summary>

  `basic.get` fetches a single message on demand, which looks convenient for a cron-style worker but costs a full round trip per message, cannot use prefetch, and gives up the fair dispatch that a subscription provides. Throughput collapses compared with `basic.consume`, and a loop of `basic.get` calls against an empty queue is pure overhead.

  It has real uses — a one-off drain, an administrative inspection — and naming those while saying it is not how a consumer should be written is the complete answer.

  </details>

- **OPTIONAL** — Where the model is chosen for you

  <details><summary><strong>Answer</strong></summary>

  Cloud queues mostly pull with long polling for the same reasons Kafka does, MQTT pushes to subscribed sessions and uses in-flight windows as its credit mechanism, and webhooks are push with no credit mechanism at all, which is why they need retries with exponential backoff and an endpoint that returns quickly.

  Recognising that the same two designs recur across every messaging technology, with different names for the credit, is the useful generalisation.

  </details>

## 4. Async Communication Protocols

**Why it comes up:** it checks whether you can match a protocol to a constraint rather than name the one you used last.

- **MUST** — MQTT: what it is for and what it gives

  <details><summary><strong>Answer</strong></summary>

  MQTT is a publish-subscribe protocol designed for constrained devices on unreliable networks: a two-byte minimum header, topic strings with `/` hierarchy and `+` and `#` wildcards, three QoS levels, and sessions that survive disconnection so a device that drops off receives what it missed when it returns. Retained messages give a new subscriber the last known value of a topic immediately, and a last will and testament lets the broker announce a device's disappearance on its behalf.

  What it does not give is routing beyond topic matching, server-side processing, replay of anything older than the session, or throughput of the kind Kafka targets. **The rule is** that MQTT ends at the broker, and everything the backend needs afterwards is a different system's job.

  </details>

- **MUST** — AMQP 0-9-1 and why RabbitMQ's model is the protocol's model

  <details><summary><strong>Answer</strong></summary>

  AMQP 0-9-1 is not a transport with a queue bolted on: exchanges, queues, bindings, channels, acknowledgements and publisher confirms are defined by the protocol itself, which is why RabbitMQ's concepts are the ones you find in every AMQP client. Channels multiplex many logical connections over one [TCP](https://datatracker.ietf.org/doc/html/rfc9293 "Transmission Control Protocol — Provides reliable, ordered byte-stream delivery between two endpoints") connection, which matters because connections are expensive and a channel is not thread-safe.

  The practical consequence is portability of concepts rather than portability of code: the broker still owns queue types, dead-lettering policy and clustering, so an AMQP client library does not make brokers interchangeable.

  </details>

- **MUST** — [gRPC](https://grpc.io/docs/ "gRPC Remote Procedure Calls — Contract-first remote procedure call framework running over HTTP/2 with protocol buffer payloads") is not a broker

  <details><summary><strong>Answer</strong></summary>

  gRPC is point-to-point remote procedure calling over HTTP/2 with protocol buffers: a schema-first contract, generated clients, and four call shapes including bidirectional streaming. The streaming modes look asynchronous and are not — the stream lives for the duration of a connection between two live processes, with no durability, no buffering for an absent peer and no replay.

  It belongs in this list because it is the right answer when you want a typed, low-latency internal call and the alternative on the table is a broker used as a request-reply channel. Saying clearly that gRPC gives no temporal decoupling, and that a dead server means a failed call rather than a stored message, is what distinguishes it from the rest.

  </details>

- **MUST** — Kafka speaks its own protocol, and that shapes the client

  <details><summary><strong>Answer</strong></summary>

  Kafka does not implement AMQP or MQTT; it defines a binary protocol over TCP with requests such as Metadata, Produce, Fetch, JoinGroup and OffsetCommit, and a client is expected to be substantial — it discovers which broker leads each partition, batches, retries, participates in group membership and manages offsets.

  That is why a Kafka client is a library with real behaviour and configuration rather than a thin socket wrapper, and why client version differences produce behaviour differences that a protocol-level answer would not predict. Bridges exist in both directions, and they are a translation layer with its own delivery semantics, not transparency.

  </details>

- **NICE** — AMQP 1.0 is a different protocol from AMQP 0-9-1

  <details><summary><strong>Answer</strong></summary>

  Despite the version numbering they are separate designs. AMQP 1.0 is an [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management")-standard peer-to-peer messaging protocol that defines links, sessions and message format but deliberately says nothing about exchanges or bindings, leaving the broker's topology model out of scope; 0-9-1 specifies that model in detail.

  Azure Service Bus and ActiveMQ speak 1.0, RabbitMQ speaks 0-9-1 natively and 1.0 through a plugin, and assuming a client for one will work with the other is a mistake worth having made once. Knowing the version numbers are not a lineage is a small detail that lands well.

  </details>

- **NICE** — HTTP, webhooks and why they persist

  <details><summary><strong>Answer</strong></summary>

  **Webhooks** are asynchronous delivery over ordinary HTTP, and they survive because they cross organisational boundaries where no shared broker exists. What they lack is everything a broker provides: no durability on the receiver's behalf, no ordering, no replay, and delivery semantics that amount to whatever retry policy the sender implements.

  A serious webhook consumer therefore acknowledges quickly, verifies a signature, deduplicates on an event identifier and enqueues the work internally — which is to say it puts a real broker behind the endpoint. Naming that pattern is the answer, because it explains both why webhooks are ubiquitous and why they are never the whole design.

  </details>

- **NICE** — Choosing by constraint

  <details><summary><strong>Answer</strong></summary>

  Battery and bandwidth at the edge with intermittent connectivity points to MQTT. Rich routing, per-message retry and dead-lettering points to AMQP and RabbitMQ. High-volume streams that several teams consume independently and replay points to Kafka. A typed internal call whose result the caller needs now points to gRPC. Crossing a company boundary usually leaves only HTTP.

  The good answer picks the constraint first and lets it select the protocol, and says plainly where two candidates would both work and something other than the protocol decides.

  </details>

- **OPTIONAL** — The browser edge

  <details><summary><strong>Answer</strong></summary>

  WebSockets give a bidirectional connection and Server-Sent Events give a one-way stream with automatic reconnection over plain HTTP, and both are delivery mechanisms to a client rather than messaging systems — they hold no state, guarantee nothing across a reconnect, and scale by pinning connections to servers.

  The usual architecture is a broker internally with a gateway that fans messages out over one of these, plus a way for a reconnecting client to fetch what it missed, since the socket itself will not provide it.

  </details>

## RabbitMQ Topics

## 5. Core Concepts: Exchanges, Queues and Streams

**Why it comes up:** it is the vocabulary check, and every later RabbitMQ answer is unintelligible if the split between exchange and queue is fuzzy.

- **MUST** — A producer never publishes to a queue

  <details><summary><strong>Answer</strong></summary>

  A producer publishes to an **exchange** with a routing key. The exchange holds no messages; it is a matching rule that compares the message against its bindings and copies the message into every queue that matches, or discards it if none does. Consumers subscribe to queues, never to exchanges.

  The indirection is the whole point: the producer states what happened and the routing key describes it, while the set of queues that care is a deployment decision that can change without touching the producer. A design where the producer knows the consumer's queue name has thrown that away and would be simpler as a direct call.

  </details>

- **MUST** — What a queue is, and the three queue types

  <details><summary><strong>Answer</strong></summary>

  A **queue** is an ordered buffer of messages owned by one node, from which messages are removed once acknowledged. Three types exist and they are chosen at declaration time. Classic queues are the original, live on a single node, and are the right choice only where losing the queue with its node is acceptable. Quorum queues replicate a queue across an odd number of nodes by consensus and are the default choice for anything durable. Streams are append-only logs that are read without being consumed.

  The type cannot be changed after declaration — you declare a new queue and migrate — so it is a decision made once and lived with. Knowing that mirrored classic queues were deprecated and then removed, and that quorum queues replaced them, is the version-awareness the question is really checking.

  </details>

- **MUST** — What a stream is and why it was added

  <details><summary><strong>Answer</strong></summary>

  A **stream** is an append-only, replicated log with non-destructive reads: consumers hold an offset, several consumers can read the same data independently, and messages are retained by age or total size rather than until acknowledgement. It exists because RabbitMQ users kept needing replay and fan-out to many independent readers and had to reach for a second system to get it.

  It is reachable over AMQP, where it looks like a queue, and over a dedicated binary stream protocol that is far faster because it avoids per-message routing and acknowledgement. **The trade is** that a stream gives up per-message redelivery, per-message routing and selective acknowledgement — the things that make a queue a queue.

  </details>

- **MUST** — Connections, channels and consumers

  <details><summary><strong>Answer</strong></summary>

  A connection is one TCP connection and is comparatively expensive; a **channel** is a lightweight session multiplexed over it, and it is the unit almost everything is scoped to — publisher confirm mode, prefetch, transactions, delivery tags and consumer subscriptions all belong to a channel. Applications should open one connection per process and one channel per thread or per concurrent worker.

  Channels are not thread-safe, and sharing one across threads is the most common client bug, producing interleaved frames and errors that look like broker faults. A channel error closes the channel rather than the connection, so a client must handle a channel-level close and reopen; a connection error takes every channel on it with it.

  </details>

- **MUST** — Who declares what, and why declaration is idempotent

  <details><summary><strong>Answer</strong></summary>

  Exchanges, queues and bindings are declared by clients and declaration is idempotent: declaring something that already exists with identical arguments succeeds and does nothing, while declaring it with different arguments fails the channel with a `PRECONDITION_FAILED` error. That is why changing a queue's arguments in code does not migrate anything — it breaks on startup until someone deletes the old queue.

  The practical convention is that a consumer declares the queue and its bindings so it cannot start against a missing topology, while a producer declares only the exchange. Treating topology as something the application asserts at startup, rather than something an operator set up once by hand, is what makes a deployment reproducible.

  </details>

- **NICE** — The default exchange, and the illusion of publishing to a queue

  <details><summary><strong>Answer</strong></summary>

  Every virtual host has a nameless direct exchange to which every queue is automatically bound by its own name, so publishing with an empty exchange name and a routing key equal to a queue name delivers straight to that queue. Tutorials use it because it removes a concept, which is exactly why people come away believing producers publish to queues.

  It is fine for a simple worker queue and wrong as a default, because it hardcodes the consumer's queue name into the producer and forecloses adding a second consumer later without changing the publisher.

  </details>

- **NICE** — Virtual hosts as the isolation boundary

  <details><summary><strong>Answer</strong></summary>

  A **virtual host** is a namespace holding its own exchanges, queues, bindings and permissions; names collide only within one, and a user is granted configure, write and read permissions per virtual host by regular expression. It is the standard way to separate environments or tenants on a shared cluster.

  What it does not give is resource isolation — virtual hosts share the node's memory, disk and connections, so a runaway queue in one affects every other. Saying that plainly is the useful part, because the name suggests more separation than exists.

  </details>

- **OPTIONAL** — The management interface and what to look at first

  <details><summary><strong>Answer</strong></summary>

  The management plugin exposes queue depth, publish and deliver rates, unacknowledged counts, consumer counts and memory per queue, plus an HTTP [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") that is the right basis for monitoring. The three numbers worth naming are queue depth and its trend, unacknowledged message count relative to prefetch, and consumer count — a queue with depth and zero consumers is the failure that is invisible from the application side.

  </details>

## 6. Routing: Fanout, Direct and Topic

**Why it comes up:** routing is the thing RabbitMQ does that a log does not, and the answer shows whether you designed a topology or inherited one.

- **MUST** — Direct: exact match on the routing key

  <details><summary><strong>Answer</strong></summary>

  A **direct** exchange delivers a message to every queue bound with a binding key exactly equal to the message's routing key. Several queues may share a binding key, in which case each gets a copy, and one queue may be bound with several keys.

  It is the right choice when the categories are a small closed set known in advance — severity levels, a handful of job types — because it is the cheapest to match and the easiest to read. The moment the set of categories grows or acquires structure, the bindings multiply and a topic exchange is the honest replacement.

  </details>

- **MUST** — Fanout: ignore the key, copy to everything bound

  <details><summary><strong>Answer</strong></summary>

  A **fanout** exchange ignores the routing key entirely and copies every message to every bound queue. It is the broadcast primitive, and it is what you want when each consumer needs the full stream and filtering, if any, is the consumer's business.

  The cost is that filtering then happens after delivery, so every consumer pays for every message in network, memory and deserialisation. That is fine for a low-volume notification stream and wasteful for a high-volume one, where a topic exchange moves the filter to the broker and the queue only receives what it asked for.

  </details>

- **MUST** — Topic: pattern matching, and the two wildcards

  <details><summary><strong>Answer</strong></summary>

  A **topic** exchange treats the routing key as dot-separated words and matches binding patterns against it, where `*` matches exactly one word and `#` matches zero or more. A key of `order.eu.created` matches `order.#`, `*.eu.*` and `order.eu.created`, and a binding of `#` alone makes the exchange behave as a fanout.

  It is the default choice for an event backbone because the producer publishes one well-structured key and each consumer declares the slice it wants without any producer change. The design work is the key itself: a hierarchy from general to specific — domain, then entity, then event, then qualifiers — because everything a consumer will ever want to filter on has to be in the key, and adding a field later means republishing with a new shape.

  </details>

- **MUST** — The producer chooses the key, the consumer chooses the filter

  <details><summary><strong>Answer</strong></summary>

  This is the sentence the whole topic reduces to. The producer's only job is to describe the message accurately in the routing key; which queues exist, what they bind to and who consumes them is decided independently and can change while the producer runs untouched.

  **The failure mode is** a routing key that encodes a destination rather than a description — `email-service` instead of `order.created` — which reintroduces the coupling the exchange exists to remove and guarantees a producer change the first time a second consumer appears.

  </details>

- **MUST** — Unroutable messages vanish unless you ask

  <details><summary><strong>Answer</strong></summary>

  A message that matches no binding is silently dropped, and with publisher confirms enabled it is still confirmed, because the confirm means the broker accepted responsibility and not that anything received it. That combination — a successful publish, a confirmed message, and nothing anywhere — is the routing bug that takes longest to find.

  The two defences are the `mandatory` flag, which makes the broker return the message to the publisher with a `basic.return` before the confirm, and an **alternate exchange** on the exchange, which routes anything unmatched to a catch-all queue. Naming one of these unprompted is a strong signal, because it is exactly the thing that is missing in most first implementations.

  </details>

- **NICE** — Headers exchanges, and why they are rarely worth it

  <details><summary><strong>Answer</strong></summary>

  A **headers exchange** ignores the routing key and matches on message header attributes, with `x-match` set to `all` or `any` to choose between conjunction and disjunction. It buys multi-dimensional matching that a single dot-separated key cannot express cleanly.

  It is slower than topic matching and much less common, so it is unfamiliar to whoever maintains the system next. The usual advice holds: flatten the dimensions into a structured routing key and use a topic exchange unless the matching is genuinely orthogonal.

  </details>

- **NICE** — Consistent hash and other plugin exchanges

  <details><summary><strong>Answer</strong></summary>

  The consistent hash exchange distributes messages across several bound queues by hashing the routing key, which is how you shard one logical queue across nodes while keeping all messages with the same key in the same queue and therefore in order. It is the RabbitMQ analogue of Kafka's key-to-partition mapping and the standard answer to a single queue being the throughput ceiling.

  Other plugins add delayed delivery and shovel-style forwarding. **The caveat is** that plugins are per-cluster operational commitments, so they are a topology decision rather than an application one.

  </details>

- **OPTIONAL** — Exchange-to-exchange bindings

  <details><summary><strong>Answer</strong></summary>

  An exchange can be bound to another exchange, so a message routed into the first is re-evaluated by the second. It lets a topology be layered — a fanout distributing to several topic exchanges owned by different teams, for example — without the producer knowing.

  It is genuinely useful for large topologies and genuinely confusing to debug, because the path a message took is no longer visible from one exchange's bindings. Use it where teams own separate subtrees, and document the layering somewhere a person can read.

  </details>

## 7. Consumer Acknowledgements

**Why it comes up:** it is where at-least-once is actually implemented, and the follow-up is always about the message nobody acknowledged.

- **MUST** — Manual acknowledgement is what makes redelivery possible

  <details><summary><strong>Answer</strong></summary>

  With `autoAck` set, the broker considers a message delivered the instant it is written to the socket and removes it immediately; if the consumer crashes a microsecond later, the message is gone. That is **at-most-once**, and it is the correct choice only for data whose loss costs nothing, such as a metrics sample.

  With manual acknowledgement, the broker holds the message as unacknowledged until the consumer sends an ack, and returns it to the queue if the channel or connection closes first. That is **at-least-once**, it is the default posture for anything that matters, and it is why every consumer must be idempotent — a crash after the work and before the ack redelivers a message whose effects already happened.

  </details>

- **MUST** — ack, nack and reject, and what requeue does

  <details><summary><strong>Answer</strong></summary>

  `basic.ack` says the message is done and the broker may forget it. `basic.reject` and `basic.nack` both say it was not processed; `nack` differs by being able to cover a range of messages at once. Both carry a `requeue` flag, and that flag is the decision that matters: true puts the message back at the head of the queue for immediate redelivery, false sends it to the dead letter exchange if one is configured and discards it if not.

  **The rule is** to requeue only for failures that might resolve on a different attempt or a different consumer — a transient dependency outage — and never for a message that is simply malformed, because that message will fail identically forever.

  </details>

- **MUST** — The poison message loop

  <details><summary><strong>Answer</strong></summary>

  A consumer that catches every exception and calls `nack` with requeue true turns one bad message into an infinite loop: the message returns to the head of the queue, is redelivered immediately, fails again, and the consumer spends all of its capacity on it while the rest of the queue waits behind it. The symptom is 100% consumer CPU with zero throughput and a queue depth that does not move.

  The fix is to distinguish the two failure classes in the handler — retry transient errors with a bounded count, dead-letter permanent ones on the first failure — and the operational safety net is a delivery limit on the queue so the broker caps redeliveries even when the handler's logic is wrong.

  Having seen this in production is audible in the answer, because the naive implementation looks perfectly reasonable on review.

  </details>

- **MUST** — Prefetch is part of the acknowledgement story

  <details><summary><strong>Answer</strong></summary>

  **Prefetch** limits how many messages a channel may hold unacknowledged at once, so it only has meaning under manual acknowledgement and it is the credit mechanism that keeps a push broker from flooding a consumer. Unlimited prefetch — the default in some clients — means the broker hands the entire queue to the first consumer that connects, so a second consumer starts idle and stays idle.

  Choose it by processing time: a prefetch of 1 for slow, uneven jobs so work spreads across workers, a higher value for fast uniform messages so throughput is not dominated by round trips. The other reason to keep it low is memory, since unacknowledged messages are held in the consumer's buffer.

  </details>

- **MUST** — Acknowledge after the work, not after receipt

  <details><summary><strong>Answer</strong></summary>

  Acknowledging on receipt and then processing converts the queue into at-most-once delivery while looking like at-least-once, and it is a common accidental design when the handler is asynchronous — the callback returns, the ack fires, and the work is still on an executor somewhere.

  The ordering is: do the work, make it durable, then acknowledge. If the work is long, the correct answer is not to ack early but to make the unit of work smaller or to raise the broker's consumer timeout deliberately, so that a stuck consumer is still detected.

  </details>

- **NICE** — Consumer timeout and the long job

  <details><summary><strong>Answer</strong></summary>

  RabbitMQ closes a channel whose delivery has gone unacknowledged for longer than `consumer_timeout`, which defaults to 30 minutes, and the message is requeued. A job that legitimately takes an hour therefore fails and retries forever unless the timeout is raised or the job is restructured.

  The better shape is almost always to split the work: acknowledge the message quickly after recording the job durably somewhere the long processing can be driven and resumed from. Raising the timeout is the honest short-term fix and worth naming as such.

  </details>

- **NICE** — Delivery tags and multiple acknowledgement

  <details><summary><strong>Answer</strong></summary>

  A delivery tag is a per-channel sequence number, and `basic.ack` carries a `multiple` flag that acknowledges every outstanding delivery up to and including that tag. Batching acknowledgements this way cuts round trips substantially at high rates.

  **The risk is** that it acknowledges messages whose processing may not have finished if deliveries complete out of order, so it is safe with sequential processing and dangerous with a concurrent handler. The tag is also meaningless on another channel, which is why an ack must be sent on the channel that received the delivery.

  </details>

- **OPTIONAL** — What a connection drop does to in-flight messages

  <details><summary><strong>Answer</strong></summary>

  Every unacknowledged delivery on a closed channel or connection is requeued at the head of the queue and redelivered, with the `redelivered` flag set. That flag says a previous delivery attempt existed, not how many, so it cannot be used as a retry counter — a mistake worth naming, since it looks like one.

  A rolling deployment therefore produces a burst of redeliveries by design, which is another way of saying idempotent consumers are not optional.

  </details>

## 8. Publisher Confirms

**Why it comes up:** it is the producer half of the durability story, and most candidates can describe consumer acknowledgements but not this.

- **MUST** — What a confirm actually promises

  <details><summary><strong>Answer</strong></summary>

  Without confirms, publishing is fire-and-forget: the broker sends no response, so a message lost to a network failure or to a broker restart before it reached disk looks exactly like a successful publish. **Publisher confirms** put the channel into a mode where the broker sends `basic.ack` carrying the delivery tag of a message it has taken responsibility for.

  The promise is precise. For a persistent message on a durable classic queue, the confirm comes after the message has been written to disk; for a quorum queue, after a majority of replicas have accepted it; for a transient message, after it has been enqueued in memory. **The consequence is** that a confirm is only as strong as the durability of the queue underneath it — confirms on a transient queue confirm very little.

  </details>

- **MUST** — Confirms are asynchronous, and the three ways to use them

  <details><summary><strong>Answer</strong></summary>

  The broker confirms out of band and may confirm many messages at once with the `multiple` flag, so the client keeps a map of unconfirmed delivery tags and resolves them as acks arrive. That gives three usable strategies.

  Publish and wait for each confirm is the simplest and the slowest, because it costs a round trip per message. Publishing in batches and waiting for the batch is a middle ground, at the cost of not knowing which message in a failed batch was the problem. Fully asynchronous handling — a callback that resolves outstanding tags and retries on a nack — is the fastest and the one worth describing, because it shows the client keeps state rather than blocking.

  </details>

- **MUST** — A confirm does not mean the message was routed

  <details><summary><strong>Answer</strong></summary>

  A message that matches no binding is unroutable, and the broker still confirms it, because the exchange accepted it and correctly decided that nobody wanted it. Treating a confirm as proof of delivery is the single most common misreading of the feature.

  Routing is established separately: publish with the `mandatory` flag and handle `basic.return`, which arrives before the confirm for a message that could not be routed, or configure an alternate exchange so unmatched messages land in a queue that can be inspected. Saying this before being asked is the mark of someone who has debugged a silently disappearing message.

  </details>

- **MUST** — AMQP transactions exist and are the wrong tool

  <details><summary><strong>Answer</strong></summary>

  `tx.select` and `tx.commit` wrap publishes in a transaction, which sounds like the stronger guarantee and is not what anyone wants here. A commit is synchronous and forces a disk flush per transaction, costing roughly two orders of magnitude in throughput against asynchronous confirms.

  They also do not solve the real problem, since a transaction spanning the broker and your database does not exist — the atomicity you actually need is between the database write and the publish, and that is what the transactional outbox is for. Naming confirms as the answer and transactions as the historical alternative is the complete response.

  </details>

- **NICE** — Confirms are one link in a chain

  <details><summary><strong>Answer</strong></summary>

  A message survives a broker restart only if every link holds: the queue is declared durable, the message is published with `delivery_mode` set to persistent, publisher confirms are on and the publisher acts on them, and the queue is a quorum queue if the message must also survive losing the node. Missing any one makes the others decorative — a persistent message on a transient queue dies with the queue, and a durable queue full of transient messages comes back empty.

  Being able to recite the chain in order, and to say which link the interviewer's scenario is missing, is what the question is for.

  </details>

- **NICE** — What to do on a nack or a timeout

  <details><summary><strong>Answer</strong></summary>

  A `basic.nack` on a publish means the broker could not take responsibility, usually an internal error or a resource alarm, and the only correct response is to republish. Because republishing after a timeout may duplicate a message that was in fact accepted, publishers should carry a stable message identifier so consumers can deduplicate — at-least-once on the producer side for the same reason as on the consumer side.

  A confirm that never arrives is more often a blocked connection than a lost message: when the broker hits its memory or disk alarm it stops reading from publishing connections, and the symptom is publishes that hang rather than fail.

  </details>

- **OPTIONAL** — What confirms cost

  <details><summary><strong>Answer</strong></summary>

  Per-message synchronous confirms are the expensive case, since throughput becomes one message per round trip. Asynchronous confirms cost very little beyond the client-side bookkeeping, and the dominant cost in the durable path is the disk flush for persistent messages rather than the confirm frame itself.

  The practical tuning conversation is therefore about persistence and queue type, not about whether to enable confirms.

  </details>

## 9. Dead Letter Queues

**Why it comes up:** it is the "what happens to the message you cannot process" question, and it exposes how retry was designed.

- **MUST** — What dead-lettering is and how it is configured

  <details><summary><strong>Answer</strong></summary>

  Dead-lettering is a per-queue policy: set `x-dead-letter-exchange` on a queue and any message that leaves it for one of a fixed set of reasons is republished to that exchange instead of being discarded, optionally with `x-dead-letter-routing-key` overriding the original key. The **dead letter queue** is then an ordinary queue bound to that exchange.

  There is nothing special about it. It is a normal queue with a name and a purpose, which is why it needs its own monitoring, its own retention thinking and a decision about who looks at it — it is not a feature that handles failure, it is a place failures accumulate.

  </details>

- **MUST** — The reasons a message is dead-lettered

  <details><summary><strong>Answer</strong></summary>

  Four, and naming all of them is the answer. The consumer rejected it with `requeue` false. Its time to live expired, either a per-message expiration or the queue's `x-message-ttl`. The queue hit its `x-max-length` or `x-max-length-bytes` limit and the overflow policy dropped it. Or, on a quorum queue, its delivery count exceeded `x-delivery-limit`.

  Most people name only the first, and the others are what make the topic interesting: a dead letter queue filling up with expired messages is a consumer that is too slow rather than a consumer that is broken, and the two need opposite responses.

  </details>

- **MUST** — A dead letter queue is not a retry mechanism

  <details><summary><strong>Answer</strong></summary>

  Dead-lettering moves a message aside once, and that is all it does. It has no backoff, no attempt counter that stops the loop on its own, and no automatic return path. A design that sends failures to a dead letter queue and then has a consumer immediately republish them to the original queue is an infinite loop with extra hops.

  Retry belongs to the consumer or to an explicit delay topology, and the dead letter queue is the terminus for messages that have exhausted it. Stating that boundary — retry in front, dead letter at the end — is the structure the question is looking for.

  </details>

- **MUST** — The delayed retry pattern and its trap

  <details><summary><strong>Answer</strong></summary>

  The standard delay topology is a wait queue with no consumer, an `x-message-ttl` and an `x-dead-letter-exchange` pointing back at the work exchange: a failed message is published there, expires after the delay, and is dead-lettered back to be retried. A ladder of such queues with growing time to live gives exponential backoff, and the delayed message exchange plugin does the same thing in one queue.

  **The trap is** that a classic queue expires messages only from the head, so one message with a long time to live blocks every shorter one behind it — a five-second retry sitting behind a one-hour retry waits an hour. That is why the ladder uses one queue per delay level and why per-message expiration on a shared wait queue is wrong.

  RabbitMQ does detect a cycle in which every hop was an expiry and drops the message, but a cycle involving rejections is not detected, so the attempt cap has to be yours.

  </details>

- **MUST** — Operating one

  <details><summary><strong>Answer</strong></summary>

  A dead letter queue that nobody watches is a silent data loss mechanism with good intentions, so the first requirement is an alert on depth greater than zero, or on its rate of growth where a trickle is expected. The second is that the message carries enough context to diagnose it without the original request — a correlation identifier, the failure reason and the original routing key.

  The third is a replay path: a deliberate, rate-limited tool that republishes selected messages to the work exchange after the bug is fixed, rather than a consumer that drains the queue automatically. Manual by default is the right posture, because the reason the messages are there is that something needed a human.

  </details>

- **NICE** — The x-death header and counting attempts

  <details><summary><strong>Answer</strong></summary>

  When a message is dead-lettered, the broker prepends an entry to an `x-death` header array recording the queue, the reason, the exchange, the original routing keys, a timestamp and a count of how many times this exact combination has occurred. It is the audit trail for where a message has been, and reading the reason from it is how you tell an expiry from a rejection.

  It is also the closest thing to a redelivery counter for classic queues, which is why retry ladders commonly read the count from it. Note that the count aggregates by queue and reason rather than counting total attempts, so treating it as a simple attempt number is slightly wrong in ways that matter at the boundary.

  </details>

- **NICE** — Delivery limit on quorum queues

  <details><summary><strong>Answer</strong></summary>

  Quorum queues count redeliveries per message and honour `x-delivery-limit`, dead-lettering a message once it is exceeded. That is a broker-enforced poison message guard rather than an application-enforced one, and it is the feature that makes the infinite requeue loop impossible regardless of consumer bugs.

  The default has changed across major versions — unlimited historically, finite in recent releases — so the answer worth giving is to set it explicitly rather than to quote a default.

  </details>

- **OPTIONAL** — The same idea elsewhere

  <details><summary><strong>Answer</strong></summary>

  Cloud queues implement it as a redrive policy with a maximum receive count, Kafka has no native equivalent so Connect and most consumer frameworks implement a dead letter topic in the consumer, and MQTT has nothing of the kind because it has no per-message acknowledgement to fail.

  The generalisation is that dead-lettering is a property of systems that acknowledge individual messages, which is also why it does not translate cleanly onto a log.

  </details>

## 10. Durable and Ephemeral Queues

**Why it comes up:** it is the "what survives a restart" question, and the answer usually reveals whether durability and replication have been conflated.

- **MUST** — Durable queue and persistent message are two separate flags

  <details><summary><strong>Answer</strong></summary>

  A **durable** queue is one whose definition is written to disk, so the queue still exists after the broker restarts. A **persistent** message is one published with `delivery_mode` set to 2, so the message itself is written to disk. They are independent, and only the combination survives a restart with its contents.

  The two broken combinations are worth naming. A persistent message on a transient queue dies with the queue, because the queue is gone and there is nothing to restore it into. A durable queue full of transient messages comes back empty. Both look correct in code review and fail exactly once, in production, at the worst moment.

  </details>

- **MUST** — What ephemeral queues are for

  <details><summary><strong>Answer</strong></summary>

  Transient, exclusive and auto-delete queues exist for the case where the queue is meaningful only while one consumer is connected: a reply queue for a request, a per-connection subscription to a live feed, a temporary diagnostic tap. Declared with a server-generated name, exclusive to one connection and deleted when it closes, they need no cleanup and leave nothing behind.

  The design signal is that the data has no value once the consumer is gone. A live dashboard missing three seconds of updates because it reconnected is fine; an order that vanished because its consumer restarted is not, and that queue was never a candidate for being ephemeral.

  </details>

- **MUST** — Durability is not replication

  <details><summary><strong>Answer</strong></summary>

  A durable classic queue lives on exactly one node and is written to that node's disk. If the node stops, the queue and its messages are unavailable until the node comes back, and if the disk is lost they are gone — durability protects against a process restart, not against losing a machine.

  Surviving a node failure requires replication, which means a quorum queue or a stream. **The distinction being tested is** exactly this: people say "the queue is durable so we cannot lose messages" and mean two different guarantees at once. Separating restart survival from node-loss survival in the first sentence is the whole answer.

  </details>

- **MUST** — What persistence costs

  <details><summary><strong>Answer</strong></summary>

  A persistent message must reach disk before its publisher confirm, so the publish path acquires a disk flush and throughput drops from memory speed to storage speed. The broker amortises this by batching flushes across concurrent publishers, which is why persistent throughput rises with publisher concurrency rather than falling.

  **The second cost is** that persistence is not free even when the queue is empty and fast: messages are written on the way through regardless of whether a consumer takes them immediately. Deciding per queue rather than globally is the practical answer — telemetry and cache invalidation can be transient, anything representing a commitment to a user should not be.

  </details>

- **NICE** — Where messages actually live

  <details><summary><strong>Answer</strong></summary>

  Classic queues historically had a **lazy mode** that kept messages on disk rather than in memory, trading latency for a queue that could grow to millions without pushing the node into its memory alarm. That mode became the default behaviour and the setting was deprecated, because operating a broker whose memory usage depends on how far behind consumers are is unpleasant.

  The reason to know this is that it explains a real production pattern: a broker healthy for months falls over when one consumer group stops and queue depth climbs. Quorum queues sidestep it by always writing to disk.

  </details>

- **NICE** — Time to live and length limits are the other half of the policy

  <details><summary><strong>Answer</strong></summary>

  A durable queue with no bound is a slow-motion outage: nothing deletes messages, so a stopped consumer eventually fills the disk and takes down every queue on the node. `x-message-ttl`, `x-max-length` and `x-max-length-bytes` bound it, and `x-overflow` decides what happens at the limit — drop the oldest, reject new publishes, or dead-letter the overflow.

  Choosing deliberately is the point: dropping the head is right for a telemetry stream where the newest data matters, rejecting publishes is right where losing a message is worse than failing a producer, and dead-lettering the overflow is right where someone must see what was shed.

  </details>

- **OPTIONAL** — Recovering topology after a restart

  <details><summary><strong>Answer</strong></summary>

  Durable queues, exchanges and bindings come back with the broker; transient ones do not, and the clients that declared them have to redeclare. Most client libraries offer topology recovery that replays declarations on reconnect, which works well and hides a failure mode — a client that reconnects to a broker whose definitions were restored from an older backup can silently disagree about arguments and fail its channel.

  Exporting definitions and treating them as configuration is the operational answer for anything a client does not own.

  </details>

## 11. Quorum Queues

**Why it comes up:** it is the current answer to "how does RabbitMQ survive losing a node", and the follow-up is always what it costs.

- **MUST** — What a quorum queue is

  <details><summary><strong>Answer</strong></summary>

  A **quorum queue** is a queue whose contents are a replicated log maintained by a consensus protocol across an odd number of nodes. One replica is the leader and handles all client traffic; a publish is confirmed once a majority of replicas have written it to disk, and if the leader fails the remaining replicas elect a new one and clients reconnect to it.

  It is declared by setting `x-queue-type` to `quorum` and it is always durable — there is no transient variant, because the replicated log is the queue. That design is why it is the default recommendation for anything whose loss matters, and why it behaves predictably during a failover rather than needing an operator to decide what to do.

  </details>

- **MUST** — Why mirrored classic queues were replaced

  <details><summary><strong>Answer</strong></summary>

  Classic mirroring copied a queue to other nodes without consensus, so a network partition could produce two masters, and healing the partition meant one side's messages were discarded — a documented, accepted data loss. Synchronising a new mirror also blocked the queue, so recovering redundancy after a node replacement caused an outage of the thing it was protecting.

  Consensus removes both: there is never more than one leader because a leader needs a majority, and a rejoining replica catches up from the log without stopping the queue. Mirroring was deprecated and then removed, so the version-aware answer is that on any current release the choice is between a classic queue on one node and a quorum queue.

  </details>

- **MUST** — Sizing, and what a majority means

  <details><summary><strong>Answer</strong></summary>

  Replica count should be odd, because tolerance is determined by the majority threshold: three replicas tolerate one failure, five tolerate two, and four tolerate only one while costing more than three. A queue that cannot reach a majority stops accepting publishes rather than accepting writes it might lose, which is the correct behaviour and looks like an outage.

  **The consequence people miss is** that a three-node cluster with one node down has no fault tolerance left, so a rolling restart during a degraded period can take the queue offline entirely. Five replicas are for clusters where two simultaneous failures are realistic, not as a general upgrade.

  </details>

- **MUST** — What they cost

  <details><summary><strong>Answer</strong></summary>

  Every publish must reach a majority of disks before it is confirmed, so latency includes a network round trip plus a flush, and throughput per queue is meaningfully lower than a classic queue on one node. Every message is stored on every replica, multiplying disk use by the replica count.

  The cost that surprises people is per-queue overhead: each quorum queue is its own consensus group with its own processes and its own state, so thousands of them are far more expensive than thousands of classic queues. **The design consequence is** that quorum queues suit a moderate number of important queues, and a topology that creates a queue per user or per session should not use them.

  </details>

- **MUST** — What to check before assuming feature parity

  <details><summary><strong>Answer</strong></summary>

  Quorum queues are not a drop-in for every classic queue feature. There is no transient or exclusive quorum queue, global prefetch is not supported, and capabilities such as message priorities and per-message time to live arrived in later releases than the queue type itself.

  The right answer is therefore to name the shape of the gap and say the list is version-dependent, rather than to recite features confidently. What has not changed is the direction: each release closes more of the gap, and new work should default to quorum unless something specific rules it out.

  </details>

- **NICE** — Leader placement and rebalancing

  <details><summary><strong>Answer</strong></summary>

  All traffic for a queue goes through its leader, so if leaders cluster on one node that node becomes the bottleneck and the others idle. Declaration-time leader locator strategies spread new queues by balancing on client-local or least-loaded nodes, and leaders can be rebalanced afterwards by an administrative command.

  This is the operational detail that shows the queue type has actually been run: after a node is restarted, leadership does not return on its own, so a cluster slowly becomes unbalanced through ordinary maintenance unless someone rebalances.

  </details>

- **NICE** — Poison message handling comes with them

  <details><summary><strong>Answer</strong></summary>

  Quorum queues track a redelivery count per message and enforce `x-delivery-limit`, dead-lettering a message that exceeds it. Classic queues have no such counter, which is why the same protection there depends on the consumer reading the `x-death` header and getting the logic right.

  A broker-enforced cap is strictly better than an application-enforced one, because it holds when the consumer is the thing that is broken. It is a good secondary reason to choose the queue type, and worth raising unprompted.

  </details>

- **OPTIONAL** — Partitions and what the cluster does about them

  <details><summary><strong>Answer</strong></summary>

  RabbitMQ clusters expect a low-latency network and handle partitions according to a configured strategy — ignore, pause the minority, or automatically heal by restarting one side. Quorum queues make the choice far less dramatic than it was with mirroring, since a minority simply cannot make progress and no divergent history is created.

  Running a cluster across regions remains a bad idea; the supported pattern for crossing a wide-area link is federation or a shovel between two clusters, which is asynchronous replication with different semantics rather than one stretched cluster.

  </details>

## 12. Queues and Streams Compared

**Why it comes up:** it is the "when would you use a stream instead of a queue" question, and it is really asking whether you would reach for Kafka and why.

- **MUST** — Destructive and non-destructive reads

  <details><summary><strong>Answer</strong></summary>

  A queue delivers a message to one consumer and deletes it on acknowledgement, so the message exists once and reading it consumes it. A stream appends to a log that every consumer reads independently at its own offset, so reading changes nothing and ten consumers see the same records without ten copies being stored.

  Everything else about streams follows from this. Replay is possible because the data is still there, several independent consumers are cheap because they are just different offsets, and the broker no longer needs per-message state per consumer, which is what makes streams dramatically faster.

  </details>

- **MUST** — Retention replaces acknowledgement as the deletion rule

  <details><summary><strong>Answer</strong></summary>

  Because reads do not delete, a stream needs an explicit retention policy: `max-age` for time, `max-length-bytes` for total size, or a segment size that bounds how coarsely the truncation happens. Data is removed when the policy says so, whether or not every consumer has read it.

  **The consequence is** a failure mode queues do not have. A consumer that falls further behind than retention loses records permanently and silently, so the thing to monitor is lag against retention rather than depth. Sizing retention is a real decision — long enough to survive a weekend outage and a replay, short enough to afford.

  </details>

- **MUST** — What you give up

  <details><summary><strong>Answer</strong></summary>

  Everything per-message. There is no per-message acknowledgement, so a consumer cannot mark one record as failed and continue; no redelivery of an individual message; no dead-lettering, because leaving a record aside would mean leaving a hole in an ordered log; and no routing, because a stream is a single ordered sequence rather than something an exchange distributes into.

  A consumer that hits a record it cannot process must therefore choose: stop, skip and record the failure elsewhere, or write the record to a separate error destination itself. Being able to state that the retry and dead-letter machinery becomes the application's job is what distinguishes a designed answer from an enthusiastic one.

  </details>

- **MUST** — Offsets and where a consumer resumes

  <details><summary><strong>Answer</strong></summary>

  A stream consumer specifies where to start — the first available offset, the current end, a specific offset, or a timestamp — and then tracks its position as it reads. Positions can be stored server-side against a named reference so a restarting consumer resumes where it stopped, or kept by the application if it has a better place for them.

  Storing the offset with the result of the work is the strong pattern, because it makes progress and effect atomic. Storing it separately means a crash between the two either replays or skips, which is the same offset-management problem every log-based system has, and it is worth saying that it is the same problem.

  </details>

- **MUST** — When to choose which

  <details><summary><strong>Answer</strong></summary>

  Choose a queue when messages are tasks: each is handled once, by any available worker, with per-message retry and a dead letter path, and the queue should be empty when things are healthy. Choose a stream when messages are facts: several consumers want the same records, order matters, and replaying history has value.

  The clarifying question is whether a second consumer of the same data is plausible. If it is, a queue forces a second binding and a second copy while a stream costs nothing extra. If the answer is no and per-message retry matters, a stream is strictly worse.

  </details>

- **NICE** — The stream protocol and why it is faster

  <details><summary><strong>Answer</strong></summary>

  Streams are reachable over AMQP, where they look like a queue and are limited by per-message frame handling, and over a dedicated binary protocol on its own port that supports batching, flow control by credit, and offset addressing directly. The dedicated protocol is roughly an order of magnitude faster, and it is the reason streams are viable at volumes classic queues are not.

  Mentioning that the AMQP path exists for compatibility rather than performance is the detail that shows the feature has been used rather than read about.

  </details>

- **NICE** — Super streams and partitioning

  <details><summary><strong>Answer</strong></summary>

  A single stream is ordered and therefore has a single-writer ceiling. A **super stream** is a logical stream split into several partitions, with a routing key deciding which partition a message lands in, so throughput scales while all messages sharing a key stay ordered relative to each other.

  That is the same design as Kafka topic partitioning, including the same consequence: ordering is per partition, never global, and the partition count is chosen up front.

  </details>

- **OPTIONAL** — Streams against Kafka

  <details><summary><strong>Answer</strong></summary>

  Streams give a Kafka-shaped capability inside a broker a team may already run, which is genuinely valuable when the requirement is replay and fan-out rather than a stream-processing platform. What they do not give is the ecosystem — no Connect, no Streams library, no schema registry, and a far smaller set of integrations.

  The honest framing is that streams stop RabbitMQ users needing Kafka for a modest requirement, and do not replace Kafka where the requirement is the platform around it.

  </details>

## 13. Bindings

**Why it comes up:** it is a small topic that separates people who have designed a topology from people who have inherited one.

- **MUST** — A binding is the rule, and it belongs to the consumer's side

  <details><summary><strong>Answer</strong></summary>

  A **binding** links an exchange to a queue and carries a binding key whose meaning depends on the exchange type — an exact match for direct, a pattern for topic, ignored for fanout. Without a binding an exchange has nowhere to route, so messages published to it are discarded.

  The ownership point is the substance of the question: the producer chooses the routing key, the team that owns a queue chooses what it binds to, and those are separate decisions made by separate people. That is the decoupling exchanges exist to provide, and a topology where one service declares another's bindings has quietly given it up.

  </details>

- **MUST** — Bindings are many-to-many, and each match is a copy

  <details><summary><strong>Answer</strong></summary>

  One exchange may be bound to many queues and one queue may be bound to one exchange several times with different keys, or to several exchanges. A message is copied into every queue whose binding matches, so three matching queues mean three independent messages with independent acknowledgement and independent failure.

  A queue matching the same message through two of its own bindings receives it once, not twice, which is the small detail worth knowing. The larger point is that fan-out multiplies storage and consumer load, so a binding of `#` added for convenience quietly doubles the broker's work.

  </details>

- **MUST** — Binding arguments

  <details><summary><strong>Answer</strong></summary>

  A binding can carry an arguments table as well as a key, and for a headers exchange that table is the matching rule: `x-match` set to `all` or `any` alongside the header values to compare. For direct, topic and fanout exchanges the arguments are ignored, which is a common source of confusion when a headers-style binding is attached to a topic exchange and silently does nothing.

  Binding arguments also participate in the identity of a binding, so unbinding must supply the same arguments that were used to bind.

  </details>

- **NICE** — Bindings are what changes at deploy time

  <details><summary><strong>Answer</strong></summary>

  Adding a consumer to an existing event stream is a new queue and a new binding, with no change to any producer and no downtime — that is the operational payoff of the whole exchange model and the sentence worth landing.

  It also implies that bindings are configuration rather than code in any topology larger than one team's, which is why exported definitions, or a tool that applies a declared topology, tend to appear as systems grow.

  </details>

- **NICE** — Unbinding, and what happens to messages in flight

  <details><summary><strong>Answer</strong></summary>

  Unbinding takes effect for routing decisions made afterwards; messages already routed into the queue stay there and are still delivered, so removing a binding does not drain a queue. Deleting the queue is what discards them, and doing that while a consumer holds unacknowledged deliveries loses those too.

  The safe retirement order is therefore unbind, let the queue drain to zero, confirm the consumer count is zero, then delete. Being able to give that order is a small piece of operational credibility.

  </details>

- **OPTIONAL** — How many bindings are too many

  <details><summary><strong>Answer</strong></summary>

  Topic exchange matching is implemented as a trie over the key's words, so it scales well with binding count, and thousands of bindings on one exchange are workable. What degrades first is comprehensibility, and then the cost of a binding churn pattern where queues and bindings are created and destroyed per request.

  If a topology needs a binding per entity, the design is usually wrong and the entity identifier belongs in the routing key or in the message with filtering in the consumer.

  </details>

## 14. Remote Procedure Calls over RabbitMQ

**Why it comes up:** it is a design question wearing a feature question's clothes, and the interesting half of the answer is when not to do it.

- **MUST** — The mechanism

  <details><summary><strong>Answer</strong></summary>

  The client publishes a request carrying two standard properties: `reply_to`, naming a queue the server should send the response to, and `correlation_id`, an identifier the server copies onto the response. The client consumes its reply queue and matches responses to outstanding requests by that identifier, because replies arrive in whatever order the servers finish.

  Both properties are conventions the protocol reserves rather than behaviour the broker implements — the broker routes the reply like any other message. Saying that the client is doing the correlation itself is the part that shows the pattern is understood rather than copied.

  </details>

- **MUST** — Direct reply-to, and why the naive version does not scale

  <details><summary><strong>Answer</strong></summary>

  Declaring a fresh exclusive reply queue per request means a queue declaration, a consumer, and a deletion for every call, which is expensive and can leave orphaned queues behind when clients die badly. Declaring one long-lived reply queue per client avoids that and requires correlation identifiers to be handled properly, which was always true.

  RabbitMQ's `amq.rabbitmq.reply-to` pseudo-queue removes the cost entirely: the client consumes from it with no declaration, the broker routes the response straight back over the client's own channel, and nothing is created or persisted. **The limitation is** that the reply cannot be persistent or routed elsewhere — if no one is listening on that channel, it is dropped — which is correct for a request whose caller is waiting and wrong for anything else.

  </details>

- **MUST** — Timeouts and orphaned replies

  <details><summary><strong>Answer</strong></summary>

  The client must impose its own deadline, because nothing in the broker will fail a request whose server never answers. When the deadline expires the client abandons the correlation identifier, and a late reply then arrives for a request nobody is waiting for and must be discarded rather than misattributed.

  The other half is that the work may have happened even though the caller timed out, so the request needs to be idempotent or to carry an identifier the server deduplicates on. This is the same at-least-once reasoning as everywhere else, and pointing that out is better than treating it as a special case.

  </details>

- **MUST** — When it is the wrong shape

  <details><summary><strong>Answer</strong></summary>

  Request-reply over a broker has every property of a synchronous call — the caller waits, the callee must be up, a timeout must be chosen — plus two broker hops, a reply path to operate and a correlation layer to get right. Debugging is harder because there is no connection between caller and callee to inspect.

  If the caller needs an answer now and both services are internal, a direct call over HTTP or gRPC is simpler, faster and easier to trace. Saying that plainly, rather than defending the pattern, is the answer that lands.

  </details>

- **NICE** — When it is the right shape

  <details><summary><strong>Answer</strong></summary>

  Three cases justify it. The worker pool is elastic or its members are not individually addressable, so the queue is doing service discovery and load balancing. The work is slow and bursty, and queueing in front of it is load levelling the caller wants. Or the callee only speaks the broker's protocol, which is common for legacy and for embedded workers.

  A fourth, weaker case is wanting one transport for everything. It is a real argument and worth naming as an organisational preference rather than a technical one.

  </details>

- **OPTIONAL** — Adjacent patterns

  <details><summary><strong>Answer</strong></summary>

  Between synchronous request-reply and fire-and-forget sit several useful shapes: accept the request, return an identifier immediately and let the caller poll or subscribe for the result; return a callback destination in the request so the reply is itself an event; or use a scatter-gather, publishing one request to several workers and aggregating replies until a quorum or a deadline.

  Recognising that request-reply is one point on a spectrum, and that most long-running work belongs further along it, is the closing thought.

  </details>

## Kafka Topics

## 15. Topics and Partitions

**Why it comes up:** it is the foundation, and ordering, parallelism, retention and scaling are all consequences of it rather than separate features.

- **MUST** — A partition is the unit of everything

  <details><summary><strong>Answer</strong></summary>

  A topic is a name; a **partition** is the thing that exists. Each partition is an ordered, append-only log on disk with its own offsets, its own leader broker and its own replicas, and a topic is simply the set of partitions that share a name and a configuration.

  Every property people attribute to topics is really a property of partitions: ordering holds within one, replication is per partition, a partition is assigned to exactly one consumer in a group, and throughput scales by having more of them. Starting the answer here makes the rest of the topic follow, and starting it at "a topic is like a queue" makes the rest of the topic wrong.

  </details>

- **MUST** — How a record picks its partition

  <details><summary><strong>Answer</strong></summary>

  If the producer sets an explicit partition, that wins. Otherwise, if the record has a key, the default partitioner hashes the serialised key and takes it modulo the partition count, so the same key always lands in the same partition — which is the entire mechanism behind per-key ordering. If there is no key, the producer batches records to one partition at a time and switches when the batch is sent, which produces an even spread with better batching than per-record round robin.

  **The consequence is** that the key is a routing decision, not metadata. Choosing the entity identifier as the key gives per-entity ordering; choosing something low-cardinality gives hot partitions; choosing nothing gives no ordering guarantee at all.

  </details>

- **MUST** — Ordering is per partition, never per topic

  <details><summary><strong>Answer</strong></summary>

  Kafka guarantees that records in one partition are read in the order they were written, and guarantees nothing about the relative order of records in different partitions. A topic with twelve partitions has twelve independent orderings, and a consumer group reading it sees them interleaved arbitrarily.

  Total ordering across a topic therefore requires exactly one partition, which caps throughput at one broker and one consumer and is almost always the wrong trade. The correct move is to identify the scope that genuinely needs ordering — an account, an order, a device — and make it the key, which gives ordering where it matters and parallelism everywhere else.

  Naming that reframing is the answer; saying "Kafka guarantees ordering" without the qualifier is the failure.

  </details>

- **MUST** — Choosing a partition count

  <details><summary><strong>Answer</strong></summary>

  The partition count is the ceiling on consumer parallelism for a group, so it must be at least the largest number of consumer instances you ever want, and it is best derived from target throughput divided by the throughput one consumer instance sustains, plus headroom. It can be increased later but never decreased.

  More partitions are not free: each is files and open handles on the broker, memory in every producer's buffer, an entry in every metadata response, and a unit of work during leader failover — so a cluster with very many partitions fails over more slowly. Over-provisioning slightly is sensible and over-provisioning wildly is a real operational cost.

  **The tell is** whether the answer mentions that increasing the count changes the key-to-partition mapping for future records, which is the expensive part and the subject of its own topic.

  </details>

- **MUST** — What a record is

  <details><summary><strong>Answer</strong></summary>

  A **record** carries a key, a value, a timestamp, optional headers, and — once written — a partition and an offset. Key and value are opaque bytes to the broker: it does no validation, no schema checking and no content inspection, which is why a schema registry is a separate component rather than a broker feature.

  Headers are the place for cross-cutting metadata such as a correlation identifier, a trace context or a schema hint, because putting them there keeps the value payload clean and lets infrastructure read them without deserialising the body. Timestamps come in two flavours, the producer's creation time or the broker's log-append time, chosen by topic configuration, and which one is in effect determines what a time-based lookup or a time-based retention policy actually means.

  </details>

- **NICE** — Segments, indexes and how a fetch is served

  <details><summary><strong>Answer</strong></summary>

  A partition on disk is a series of **segment files** rolled by size or by age, each with a sparse offset index and a time index beside it. A fetch binary-searches the index to a nearby position and then reads sequentially, and the broker can hand bytes from the page cache to the socket without copying them through user space.

  That zero-copy path is why a healthy Kafka broker serves consumers at close to disk or network speed while doing little work — and it quietly stops applying when the broker must touch the bytes, for example to encrypt them for a client connection or to convert between record formats. Knowing when the fast path is not in effect is the useful half of this.

  </details>

- **NICE** — Compaction is a per-topic alternative to deletion

  <details><summary><strong>Answer</strong></summary>

  A topic configured with `cleanup.policy=compact` retains at least the most recent record for every key rather than a window of time, turning the log into a durable, replayable snapshot of current state — which is what makes it usable as a changelog for a store or a table.

  It is worth knowing here because it changes what a partition means: with compaction, reading from the beginning gives current state rather than full history, and deletions must be expressed as a null-valued tombstone record. The detail is developed further under retention.

  </details>

- **OPTIONAL** — How many topics, and what to name them

  <details><summary><strong>Answer</strong></summary>

  Brokers handle many thousands of partitions but the metadata cost is real, so a topic per entity instance is an anti-pattern and the entity identifier belongs in the key. A topic should be one kind of fact, with one schema and one retention policy, because those are the things configured per topic.

  Naming conventions that encode domain, entity and event, and that reserve a prefix for environment where clusters are shared, are worth agreeing early; renaming a topic later means a new topic, a dual-write period and a consumer migration.

  </details>

## 16. Consumer Groups

**Why it comes up:** one mechanism gives both competing consumers and fan-out, and the rebalance is where production incidents come from.

- **MUST** — What a group is and the assignment rule

  <details><summary><strong>Answer</strong></summary>

  Consumers sharing a `group.id` form a **consumer group**, and the cluster assigns every partition of the subscribed topics to exactly one member. Adding a member redistributes partitions and adds throughput; removing one redistributes its partitions to the survivors.

  The hard limit follows directly: a group can have at most as many working members as there are partitions, and any extra members are assigned nothing and sit idle. Scaling a consumer beyond the partition count does nothing at all, which is the single most common Kafka scaling surprise.

  </details>

- **MUST** — Fan-out and load balancing from one primitive

  <details><summary><strong>Answer</strong></summary>

  Within a group, members share the work — competing consumers. Across groups, every group gets every record independently, each with its own offsets — publish-subscribe. So the group identifier is the only thing distinguishing "another instance of the same consumer" from "a different consumer of the same data".

  **The practical rule is** one group per logical application, not per instance and not per deployment. Generating a group identifier at startup, which happens accidentally with a random suffix, turns every restart into a brand-new consumer that starts at whatever `auto.offset.reset` says, and it is a bug that presents as either duplicated work or a silently skipped backlog.

  </details>

- **MUST** — The coordinator, and how membership is maintained

  <details><summary><strong>Answer</strong></summary>

  One broker acts as the **group coordinator**, chosen by hashing the group identifier onto a partition of the internal offsets topic. Members join through it, it tracks liveness, and it distributes the assignment; in the long-standing protocol it elects one consumer as group leader to compute the assignment, while the newer protocol moves that computation to the broker.

  The coordinator is also where offset commits go. That is why a broker failure can briefly stall a group even when it leads none of the group's partitions — coordinator failover is its own small event, and knowing the two roles are separate is the detail being probed.

  </details>

- **MUST** — Liveness has two independent timers

  <details><summary><strong>Answer</strong></summary>

  A background thread sends heartbeats every `heartbeat.interval.ms`, and the coordinator removes a member that misses them for `session.timeout.ms` — that timer detects a dead process or a network problem. A separate timer, `max.poll.interval.ms`, detects a live process that has stopped making progress: if the application does not call poll again within it, the member is removed and its partitions reassigned.

  The distinction matters because the heartbeat thread is independent of the poll loop, so a consumer stuck processing one record keeps heartbeating happily and is still evicted when the poll interval expires. The classic incident is a batch that occasionally takes longer than the default five minutes: the member is kicked out, its work is reassigned and reprocessed, it finishes and tries to commit, and the group rebalances in a loop.

  The fixes are to process less per poll, raise the interval deliberately, or move slow work off the poll thread — and naming which one fits the scenario is the answer.

  </details>

- **MUST** — What a rebalance costs

  <details><summary><strong>Answer</strong></summary>

  In the eager protocol a rebalance is a stop-the-world event: every member revokes every partition, the assignment is recomputed, and consumption resumes — so the whole group pauses even when a single instance was added. During that pause nothing is consumed and lag grows, and uncommitted work is repeated after reassignment.

  Rebalances are triggered by a member joining or leaving, by a member being evicted on either timer, and by a change in partition count or subscription. **The failure to recognise is** the rebalance storm, where evictions caused by slow processing trigger rebalances that make processing slower, and the group never stabilises.

  </details>

- **NICE** — Assignment strategies

  <details><summary><strong>Answer</strong></summary>

  Range assigns contiguous partition ranges per topic and skews load when partition counts are not multiples of the member count; round robin spreads more evenly across topics; sticky tries to keep existing assignments stable so fewer partitions move.

  Cooperative sticky assignment is the one worth naming, because it changes the rebalance from stop-the-world to incremental: members keep the partitions they are retaining and only the moving ones are revoked, so a rolling deployment no longer pauses the whole group. Migrating to it requires a two-step upgrade across the group, which is the kind of detail that only comes from having done it.

  </details>

- **NICE** — Static membership

  <details><summary><strong>Answer</strong></summary>

  Setting `group.instance.id` gives a member a stable identity, so a restart within the session timeout rejoins with its previous assignment and triggers no rebalance at all. For a group deployed as a stateful set with predictable identities, that removes rebalances from routine restarts entirely.

  **The cost is** that a genuinely dead member is not noticed until its session timeout expires, so failure detection is as slow as that timeout — which is the trade being made deliberately, and saying so is better than presenting it as a free win.

  </details>

- **OPTIONAL** — Consuming without a group

  <details><summary><strong>Answer</strong></summary>

  A consumer can assign partitions to itself directly rather than subscribing, in which case there is no group, no coordinator, no rebalance and no automatic failover. It is the right tool when the application manages partition ownership itself or when a tool needs to read a specific partition, and the wrong tool as a way of avoiding rebalances in an ordinary service.

  Offsets can still be committed under a group identifier, which makes for a confusing hybrid worth avoiding unless deliberate.

  </details>

## 17. Offsets and Their Management

**Why it comes up:** the delivery guarantee lives here, so "at-least-once or at-most-once" is decided by where the commit sits rather than by a broker setting.

- **MUST** — What an offset is and where a committed one lives

  <details><summary><strong>Answer</strong></summary>

  An **offset** is a monotonically increasing position within one partition, assigned by the leader and never reused. It is meaningless outside its partition, so an offset is always the triple of topic, partition and position.

  A consumer's current position is client-side state. A **committed** offset is written to the internal `__consumer_offsets` topic, keyed by group, topic and partition and compacted so only the latest survives, and it is what a restarting or reassigned member resumes from. The convention worth stating precisely is that the committed value is the next offset to read — the last processed offset plus one — which is the off-by-one that produces a duplicated or skipped record when hand-managed.

  </details>

- **MUST** — Auto-commit, and what it actually guarantees

  <details><summary><strong>Answer</strong></summary>

  With `enable.auto.commit` left at its default, the client commits during a poll call, at most every `auto.commit.interval.ms`, and what it commits is the position reached by records already returned to the application — not records the application has finished with.

  That produces both failure modes. A crash after processing but before the next commit replays up to an interval of records, which is at-least-once. A crash after the commit but before the processing finishes loses those records, which is at-most-once. Auto-commit therefore gives neither guarantee reliably, and it is fine only where losing or repeating a few seconds of records is genuinely acceptable.

  Saying "it is on by default and it is not a guarantee" is the sentence being listened for.

  </details>

- **MUST** — The guarantee is a commit-ordering decision

  <details><summary><strong>Answer</strong></summary>

  Disable auto-commit and the choice becomes explicit. Process the records, then commit: a crash between them replays, so it is **at-least-once** and the consumer must be idempotent. Commit first, then process: a crash between them loses the records, so it is **at-most-once**, which is correct only for data whose loss is cheaper than its duplication.

  Exactly-once is neither of these; it is the third option, and it requires the effect and the offset to be committed atomically — either inside Kafka using transactions, or in an external store by writing the offset in the same transaction as the result.

  Stating the three options as one decision about where the commit goes is a much stronger answer than listing three configuration flags.

  </details>

- **MUST** — Committing synchronously or asynchronously

  <details><summary><strong>Answer</strong></summary>

  A synchronous commit blocks until the coordinator acknowledges and retries on retriable errors, so it is safe and it costs a round trip per call — acceptable per batch, expensive per record. An asynchronous commit returns immediately with a callback, is much faster, and deliberately does not retry, because a retry could land after a later commit and move the group backwards.

  The idiomatic pattern is asynchronous commits during normal operation for throughput, with a synchronous commit in the shutdown and partition-revoked paths so the last position is not lost. Being able to explain why the asynchronous version must not retry is the part that shows the reasoning rather than the recipe.

  </details>

- **MUST** — auto.offset.reset and the mornings it ruins

  <details><summary><strong>Answer</strong></summary>

  This setting applies only when there is no valid committed offset — a brand-new group, or a committed offset that no longer exists because retention deleted it. `latest` starts at the end and silently skips everything already in the topic; `earliest` starts at the beginning and reprocesses the entire history; `none` raises an error and makes the situation visible.

  The three incidents follow mechanically. A new service deployed with `latest` processes nothing and looks fine. A consumer down longer than retention resumes with `earliest` and replays millions of records into a downstream system. A group idle for longer than the offsets retention period loses its commits and does one or the other on its next start, despite nothing having changed in its code.

  **The defensive posture is** `none` in anything critical, with an explicit, deliberate decision made by a human when it fires.

  </details>

- **NICE** — Storing offsets outside Kafka

  <details><summary><strong>Answer</strong></summary>

  A consumer can keep its offsets anywhere and call seek on startup. That is not an eccentricity: writing the offset into the same database transaction as the work makes the effect and the position atomic, which is exactly-once for that sink without Kafka transactions being involved at all.

  The cost is that the group's progress is no longer visible to the standard tooling, so lag monitoring has to be built rather than read off. It is the right trade for a sink that is a transactional database and the wrong one for everything else.

  </details>

- **NICE** — Seeking, resetting and replay

  <details><summary><strong>Answer</strong></summary>

  Replay is one of the reasons to be on a log at all, and it is done by moving a group's committed offsets — to the beginning, to a timestamp, or by a relative shift — using the consumer group tool while the group is stopped. The requirement that the group be inactive is the guard that stops two members disagreeing about position.

  The operational discipline matters more than the command: replay into a live downstream system duplicates side effects, so the safe pattern is a fresh group identifier writing to a separate destination, or a downstream that is idempotent by construction. Saying that unprompted is the difference between knowing the feature and having used it.

  </details>

- **OPTIONAL** — Offset retention and lag as a metric

  <details><summary><strong>Answer</strong></summary>

  Committed offsets for a group that stops committing are themselves deleted after a retention period, which is why a group idle over a long holiday can come back without a position. Consumer lag — the difference between the end of the partition and the committed offset — is the primary health metric for any consumer, and the one to alert on.

  Lag should be read per partition rather than summed, because one stuck partition inside an otherwise healthy group is invisible in the total and is the failure that actually happens.

  </details>

## 18. Exactly-Once Delivery and Processing End to End

**Why it comes up:** it is the flagship distributed-systems question, and most answers either deny it is possible or claim a flag turns it on.

- **MUST** — What exactly-once can and cannot mean

  <details><summary><strong>Answer</strong></summary>

  Exactly-once *delivery* over an unreliable network is impossible: the sender cannot distinguish a lost message from a lost acknowledgement, so it must either retry and risk a duplicate or not retry and risk a loss. What is achievable is exactly-once *processing* — duplicates may be delivered, and the observable effect happens once.

  Kafka provides that within its own boundary: a read-process-write loop whose input offsets and output records commit atomically. Outside that boundary it provides deduplication primitives and nothing more.

  Opening with that distinction is what separates a real answer from both the sceptical one and the credulous one.

  </details>

- **MUST** — The idempotent producer

  <details><summary><strong>Answer</strong></summary>

  Enabling idempotence — the default on current clients — gives the producer a producer identifier and an epoch, and stamps each batch with a sequence number per partition. The broker tracks the last sequence it accepted and silently discards a duplicate caused by a retry, so the classic "the ack was lost so we sent it twice" duplicate disappears.

  It requires `acks=all`, retries enabled, and at most five in-flight requests per connection, which is also what preserves ordering under retry — without idempotence, a retried batch can be written after a later one and silently reorder the partition.

  **The boundary is** that this covers one producer session and its own retries. A producer that restarts gets a new identifier, and an application that sends the same logical event twice is sending two different records as far as the broker is concerned.

  </details>

- **MUST** — Transactions and the read-process-write loop

  <details><summary><strong>Answer</strong></summary>

  A producer configured with a `transactional.id` can open a transaction, write records to any number of partitions, submit its consumer's input offsets into the same transaction, and commit — so either every output record and the input offsets become visible, or none do. The broker side is a transaction coordinator with its own internal state topic, and commit markers written into each partition involved.

  Two details make the pattern work. The consumer must have auto-commit disabled, because offsets travel through the producer's transaction rather than through the consumer. And the `transactional.id` must be stable across restarts, because that is what lets the coordinator fence a previous instance that is still alive — the zombie that would otherwise keep writing after its replacement started.

  </details>

- **MUST** — read_committed on the consumer side

  <details><summary><strong>Answer</strong></summary>

  Transactions guarantee nothing unless the downstream consumer sets `isolation.level` to `read_committed`; the default reads uncommitted records and therefore sees output from transactions that later abort. A committed-only consumer reads no further than the last stable offset — the point beyond which some transaction is still open — and filters records belonging to aborted transactions.

  **The consequence is** latency: an open transaction holds the last stable offset back, so downstream consumers cannot see anything after it until it commits or times out. A long transaction, or one from a producer that died and must wait out `transaction.timeout.ms`, stalls every committed-read consumer of that partition.

  That coupling — one producer's transaction duration becomes another team's consumer latency — is the operational point worth making.

  </details>

- **MUST** — The end-to-end checklist

  <details><summary><strong>Answer</strong></summary>

  Producer: idempotence on, `acks=all`, a stable `transactional.id`, and every send inside a transaction. Broker: replication factor of three with `min.insync.replicas` of two, so `acks=all` means a real quorum rather than one surviving replica. Consumer of the input: auto-commit off, offsets sent through the producer's transaction. Consumer of the output: `isolation.level=read_committed`.

  Every one of those is required, and missing any single one silently downgrades the guarantee to at-least-once with no error anywhere. Being able to recite the chain and name which link a given scenario is missing is precisely what the question tests.

  </details>

- **MUST** — Where it stops: the external sink

  <details><summary><strong>Answer</strong></summary>

  The guarantee holds for Kafka-to-Kafka. The moment the consumer calls an HTTP endpoint, writes to a database that is not in the transaction, sends an email or charges a card, exactly-once is gone — the transaction can commit and the side effect can have happened twice, or happened and then been rolled back on the Kafka side.

  There are two honest answers for that boundary. Make the sink idempotent, keyed by something stable — a business identifier, or the topic-partition-offset triple — so a repeat is absorbed. Or move the offset into the sink's own transaction, writing result and position together and seeking to the stored position on startup, which makes the database the authority on progress.

  Volunteering that boundary before being pushed to it is the strongest version of this answer.

  </details>

- **NICE** — Kafka Streams does the wiring

  <details><summary><strong>Answer</strong></summary>

  Setting `processing.guarantee` to the exactly-once mode in a Streams application turns on the whole pattern — transactional producers, offsets committed inside transactions, and state store changelogs written in the same transaction as the output — so state, output and position stay consistent across a failure.

  That is the practical recommendation for anything whose topology fits: the hand-rolled version is entirely doable and has several places to get subtly wrong. The same reservation about external sinks still applies, because a Streams application calling out to a service is no different from a plain consumer doing it.

  </details>

- **NICE** — What it costs

  <details><summary><strong>Answer</strong></summary>

  Transactions add commit markers to every partition written, coordinator round trips per transaction, and the last-stable-offset delay for downstream readers. The overhead is dominated by transaction count rather than record count, so committing per record is very expensive while committing per batch of a few thousand is close to free.

  **The honest framing is** that the cost is modest and the complexity is not: more configuration that must agree across services, and a failure mode where a stuck transaction stalls unrelated consumers. Recommending it where correctness demands it and at-least-once with an idempotent sink everywhere else is a defensible position and a good closing line.

  </details>

- **OPTIONAL** — Operational gotchas

  <details><summary><strong>Answer</strong></summary>

  The `transactional.id` must be stable and unique per logical producer instance, which is awkward for autoscaled deployments and is exactly why Streams derives it from the task identity. The broker caps transaction timeouts, so a client asking for more than the broker allows fails at startup rather than at commit. And a transaction abandoned by a crashed producer holds the last stable offset until its timeout expires, so downstream lag can spike for reasons entirely outside that team's system.

  Knowing where to look when consumers stall with no apparent producer problem is the payoff for knowing this.

  </details>

## 19. Partitions for Throughput and Partitions for Redundancy

**Why it comes up:** the two words get used interchangeably and they are different mechanisms, so the question is really whether you can separate dividing data from duplicating it.

- **MUST** — Partitions divide, replicas duplicate

  <details><summary><strong>Answer</strong></summary>

  A **partition** splits a topic's data into independent logs so that different brokers hold different records and different consumers process them in parallel. A **replica** is a copy of one partition on another broker holding exactly the same records, so that losing a broker loses no data.

  Scaling throughput means more partitions; surviving failure means a higher replication factor. They are orthogonal settings on the same topic, and a topic with one partition and three replicas is highly durable and strictly single-threaded, while a topic with fifty partitions and one replica is fast and loses data permanently when any broker dies.

  Getting those two sentences out first is most of the answer, because the phrase "partitions for redundancy" is a category error the question is inviting you to correct.

  </details>

- **MUST** — What more partitions buys, and where it stops helping

  <details><summary><strong>Answer</strong></summary>

  More partitions raise the ceiling on three things at once: producer parallelism, broker-side spread across disks and machines, and the number of consumers in a group that can do useful work. Below that ceiling they do nothing — a topic with twelve partitions and three consumers is not slow because of partitioning.

  They stop helping when the bottleneck moves elsewhere: a single slow downstream dependency in the consumer, a key distribution that concentrates traffic on a few partitions, or a broker's network and disk. **The specific failure is** the hot partition, where a low-cardinality or skewed key sends most traffic to one log, and no partition count fixes it because the key is the problem.

  </details>

- **MUST** — What replication factor buys, and what it costs

  <details><summary><strong>Answer</strong></summary>

  Replication factor is how many copies of each partition exist, and it determines how many brokers can be lost without losing data or availability for that partition. Three is the standard because it tolerates one failure while still allowing a write quorum of two, which means a rolling restart does not stop writes.

  The cost is multiplicative in disk and in network: every record is stored three times and crosses the network twice more as followers fetch it. With `acks=all`, it also adds latency, because the producer waits for the followers rather than for the leader alone. Replication factor two is a trap worth naming — it costs nearly as much as three and leaves no safe write quorum, since requiring two in-sync replicas means any single failure stops writes.

  </details>

- **MUST** — The two multiply

  <details><summary><strong>Answer</strong></summary>

  A cluster's real load is partitions times replication factor: a hundred topics with fifty partitions at replication factor three is fifteen thousand partition replicas to lead, fetch, index and fail over. Brokers have practical limits on that total, and exceeding them shows up as slow controller operations and long failover times rather than as slow message throughput.

  That is why partition count is not a free dial. The honest sizing answer starts from required throughput and required consumer parallelism, sets replication factor from the durability requirement, and then checks the product against what the cluster can carry.

  </details>

- **MUST** — The mistake each way

  <details><summary><strong>Answer</strong></summary>

  Adding partitions to improve durability does nothing at all and makes failover slower. Adding replicas to improve throughput makes throughput worse, because every extra copy costs network and, under `acks=all`, latency. Both mistakes are common enough that the question exists to catch them.

  **The one real interaction is** worth naming: more partitions means a broker failure affects a smaller share of each topic, so the blast radius of a failure is smaller even though durability is unchanged. That is availability granularity, not redundancy, and saying it precisely is what a good answer sounds like.

  </details>

- **NICE** — Rack and zone awareness

  <details><summary><strong>Answer</strong></summary>

  Setting `broker.rack` makes the cluster place a partition's replicas in different racks or availability zones, so replication factor three survives losing a zone rather than merely three machines that might share one. Without it, a replica assignment can put all three copies in one failure domain and the replication factor is a number rather than a guarantee.

  The cost is cross-zone network charges on every replication hop, which in a cloud deployment is a real line on the bill and one of the few places where a durability setting is argued about on price.

  </details>

- **NICE** — Fetch from the closest replica

  <details><summary><strong>Answer</strong></summary>

  Consumers read from the partition leader by default, which in a multi-zone cluster means most reads cross a zone boundary. Configuring the client's rack and a rack-aware replica selector lets a consumer fetch from a follower in its own zone instead, cutting cross-zone traffic substantially.

  It changes nothing about correctness — a follower still only serves records up to the high watermark — but it can add latency, because a follower is by definition slightly behind. It is an operational optimisation worth knowing exists, and worth measuring rather than assuming.

  </details>

- **OPTIONAL** — Deriving both from requirements

  <details><summary><strong>Answer</strong></summary>

  Take peak records per second and the throughput one consumer instance sustains to get a minimum partition count, add headroom because the count can only grow, and round to something that divides evenly by the expected consumer count. Take the durability requirement — how many simultaneous broker or zone failures must be survivable without data loss — to get replication factor, then set `min.insync.replicas` one below it.

  Writing those two derivations down, rather than copying a topic's settings from a neighbouring one, is the practice the question is ultimately about.

  </details>

## 20. Cluster Replication

**Why it comes up:** two different mechanisms share the name, and separating replication inside a cluster from replication between clusters is half the answer.

- **MUST** — Inside a cluster: leaders, followers and the fetch loop

  <details><summary><strong>Answer</strong></summary>

  Each partition has one **leader** replica and some followers. Producers and consumers talk only to the leader; followers replicate by issuing fetch requests to it exactly as a consumer would, and the leader tracks how far each follower has got.

  That design is why replication needs no separate protocol and why a follower that falls behind is visible as a lagging reader rather than as a broken link. It also explains failover: a follower that is caught up already holds the leader's log, so promoting it is a metadata change rather than a data movement.

  </details>

- **MUST** — What each acks level promises

  <details><summary><strong>Answer</strong></summary>

  `acks=0` means the producer does not wait at all — the fastest and the one that loses records to a closed connection without noticing. `acks=1` waits for the leader to write the record to its own log, which still loses the record if that leader fails before any follower has fetched it, and this is the setting people believe is safe. `acks=all` waits until every in-sync replica has the record.

  The point to make is that `acks=all` alone is not enough: if the in-sync set has shrunk to the leader alone, "all replicas" means one machine, and the write is acknowledged with no redundancy whatsoever. The setting that closes that hole is the next bullet, and naming the pair together is the complete answer.

  </details>

- **MUST** — min.insync.replicas is what makes acks=all mean something

  <details><summary><strong>Answer</strong></summary>

  `min.insync.replicas` is a broker or topic setting that refuses a write when fewer than that many replicas are in sync, returning an error to the producer rather than accepting a record that only one machine holds. With replication factor three it is set to two: a write needs the leader plus one follower, one broker can be lost without stopping writes, and no acknowledged record exists on fewer than two machines.

  Setting it equal to the replication factor makes any single broker loss stop writes for that partition, which trades availability for a durability improvement most systems do not need. Setting it to one makes `acks=all` meaningless. **The pairing to remember is** replication factor three with a minimum of two, and being able to say why each number is what it is.

  </details>

- **MUST** — Between clusters is a different problem

  <details><summary><strong>Answer</strong></summary>

  Replication inside a cluster is synchronous, consistent and part of the protocol. Replication between clusters is asynchronous by necessity, because a wide-area link cannot be in the write path, so the target cluster is always somewhat behind and a failover has a real recovery point.

  The other thing that does not carry across is offsets. A record that is offset 1000 in the source partition can be at a different offset in the target, because the target's log started at a different point and may have compacted differently — so a consumer that fails over cannot simply use its old committed offsets. That is the detail that makes cross-cluster failover hard, and naming it is what shows the topic is understood beyond "you run a mirroring tool".

  </details>

- **MUST** — MirrorMaker and what it actually does

  <details><summary><strong>Answer</strong></summary>

  The current tool runs as a set of Kafka Connect connectors: one copies records, one propagates consumer group offsets by writing checkpoints, and one emits heartbeats so the link's health is observable. Topic configurations and access rules can be synchronised too, so the target is not just data but a usable replica of the topology.

  Offset translation is handled by a topic that records correspondences between source and target offsets, from which translated group offsets are derived — approximate rather than exact, which is why a failed-over consumer should expect to reprocess some records. By default the replicated topics are renamed with a source cluster prefix, and understanding that this is cycle prevention rather than cosmetics leads directly into the next bullet.

  </details>

- **NICE** — Active-active and the loop problem

  <details><summary><strong>Answer</strong></summary>

  Mirroring both ways between two clusters creates an obvious loop: a record copied from A to B is then copied back to A forever. The prefix naming convention breaks it, because the connector never replicates a topic that already carries the other cluster's prefix, so consumers in each region read both the local topic and the remote-prefixed one.

  That works and it pushes a real cost onto consumers, which must now handle two topics per logical stream and deal with the fact that the same logical entity can be written in both regions with no global ordering between them. Active-active is a data modelling decision before it is a replication one, and saying that is the stronger answer.

  </details>

- **NICE** — Stretch clusters

  <details><summary><strong>Answer</strong></summary>

  One cluster spanning availability zones in a single region is standard and works well, because the latency is a few milliseconds and rack awareness places replicas across zones. One cluster stretched across distant regions is a different proposition: every `acks=all` write pays the inter-region round trip, and a partition of the link makes a minority region unable to write at all.

  **The rule of thumb worth stating is** one cluster per region with asynchronous mirroring between them, and a stretched cluster only where the link is short enough to sit in the write path.

  </details>

- **OPTIONAL** — Recovery objectives

  <details><summary><strong>Answer</strong></summary>

  Asynchronous mirroring means a non-zero recovery point: whatever had not yet been copied when the source was lost is lost, and the size of that window is mirroring lag, which should be monitored as a business metric rather than an infrastructure one. Recovery time is dominated by repointing producers and consumers and by their offset uncertainty, not by the data being absent.

  The honest summary is that cross-cluster replication gives a warm copy and a bounded loss, and any claim of zero data loss across regions needs the write path to be synchronous and to say what that costs.

  </details>

## 21. In-Sync Replicas

**Why it comes up:** the in-sync set is where durability and availability are actually traded, and the follow-up is always unclean leader election.

- **MUST** — What the in-sync set is and how membership is decided

  <details><summary><strong>Answer</strong></summary>

  The [ISR](https://kafka.apache.org/documentation/#design_replicatedlog "In-Sync Replicas — The set of partition replicas caught up with the leader and eligible to acknowledge a write") is the subset of a partition's replicas that are considered caught up with the leader — the leader itself plus every follower whose fetches have kept it within `replica.lag.time.max.ms` of the leader's end of log. A follower that stops fetching, or falls behind for longer than that window, is removed from the set by the controller, and rejoins once it has caught up.

  Membership is time-based rather than message-based, which is deliberate: an older message-count threshold marked healthy followers as out of sync whenever a burst arrived, because being a thousand records behind is normal during a spike and says nothing about the follower's health.

  </details>

- **MUST** — Why an in-sync subset rather than all replicas

  <details><summary><strong>Answer</strong></summary>

  Waiting for every replica would mean one slow or dead broker stalls every write to every partition it holds — availability hostage to the worst machine. Waiting for a fixed majority, as a consensus protocol does, tolerates failure but requires more replicas to achieve the same durability.

  Kafka's design keeps the acknowledgement set dynamic: writes wait for the replicas that are currently keeping up, and a straggler is ejected rather than tolerated. The durability floor is then supplied separately by `min.insync.replicas`, which refuses writes once the set is too small. Describing it as a dynamic set with a floor is the precise framing, and it is more accurate than calling it a quorum.

  </details>

- **MUST** — The high watermark and what consumers can see

  <details><summary><strong>Answer</strong></summary>

  The **high watermark** is the highest offset that every in-sync replica has, and consumers cannot read past it. That is why a record is invisible until it is replicated: if consumers could read ahead of the watermark, a leader failure could un-publish a record a consumer had already acted on.

  The consequence is a latency floor — a record's visibility waits for replication — and a useful diagnostic, since a growing gap between a leader's end of log and its high watermark means followers are struggling, which is a broker or network problem rather than a consumer one.

  </details>

- **MUST** — What happens when the set shrinks

  <details><summary><strong>Answer</strong></summary>

  As followers drop out the partition stays writable until the in-sync count falls below `min.insync.replicas`, at which point producers using `acks=all` start receiving a not-enough-replicas error and the partition is effectively read-only. Consumers keep reading; only writes stop.

  That is the system doing exactly what it was told — refusing to accept data it cannot store redundantly — and the correct response is to fix the broker rather than to lower the setting. **The alert worth having is** on under-replicated partitions, because it fires while writes still succeed, whereas the producer error fires when the outage has already started.

  </details>

- **MUST** — Unclean leader election

  <details><summary><strong>Answer</strong></summary>

  If every in-sync replica for a partition is unavailable, there are two options: wait for one to return, leaving the partition offline, or promote an out-of-sync replica and resume immediately. The second is **unclean leader election**, and it silently discards every record the old leader had that the new one does not — including records that were acknowledged with `acks=all` and already consumed by someone.

  It is disabled by default, which is the right default, and the answer should say why: a partition that is offline is a visible incident, while one that has silently lost a window of acknowledged data is a correctness problem nobody sees until reconciliation. Enabling it is a deliberate choice for streams where availability beats completeness, such as telemetry, and never for financial or transactional data.

  </details>

- **NICE** — Why a replica falls out

  <details><summary><strong>Answer</strong></summary>

  The usual causes are slow disks on the follower, a saturated network between brokers, a long garbage collection pause, or a follower catching up after a restart. Occasionally it is the leader — a leader with too many partitions cannot serve follower fetches quickly enough, so the followers look broken and the leader is the problem.

  The diagnostic that separates these is whether one broker's replicas are lagging everywhere, which points at that broker, or whether one partition lags across brokers, which points at its leader or its traffic.

  </details>

- **NICE** — The metrics that matter

  <details><summary><strong>Answer</strong></summary>

  Under-replicated partitions greater than zero means some partition's in-sync set is smaller than its replication factor and durability is degraded, which is the primary Kafka alert. Offline partitions greater than zero means some partition has no leader at all and is unavailable, which is an outage. Replicas fetching from the wrong place, and a growing leader-to-watermark gap, are the leading indicators.

  A steady non-zero under-replicated count that nobody investigates is the common organisational failure, because the cluster keeps serving traffic and the safety margin is gone.

  </details>

- **OPTIONAL** — Where the in-sync set is recorded

  <details><summary><strong>Answer</strong></summary>

  The set is maintained by the leader and published through the controller into cluster metadata, so every broker and client agrees on it. Historically that meant a write to the coordination service on every change, which made very frequent membership churn expensive; with metadata held in a replicated log instead, those updates are ordinary log appends.

  It is a small detail that explains why large clusters with unstable followers behaved badly on older versions, and why the metadata redesign improved more than just controller failover.

  </details>

## 22. Rebalancing and Re-partitioning

**Why it comes up:** three unrelated operations get called rebalancing, and a good answer separates them before explaining any of them.

- **MUST** — Three different things share the word

  <details><summary><strong>Answer</strong></summary>

  A **consumer group rebalance** reassigns partitions among the members of a group and touches no data. A **partition reassignment** moves partition replicas between brokers and copies real data across the network. **Changing the partition count** alters the topic's shape and changes which partition future keys map to.

  They have different triggers, different costs and different risks, and conflating them produces answers that are half right about each. Separating them in the first sentence is the single most useful thing to do with this question.

  </details>

- **MUST** — Consumer group rebalance

  <details><summary><strong>Answer</strong></summary>

  Triggered when a member joins or leaves, when a member is evicted for missing heartbeats or for exceeding the poll interval, or when the subscription or partition count changes. Under the eager protocol every member revokes everything and the group pauses while the assignment is recomputed; under cooperative incremental rebalancing only the partitions that actually move are revoked.

  The cost is a consumption pause and the reprocessing of whatever was uncommitted, so rebalances are not free even when nothing failed. The pathology to name is the rebalance storm, where evictions caused by slow processing trigger rebalances that slow processing further, and the group never reaches a stable assignment.

  </details>

- **MUST** — Partition reassignment across brokers

  <details><summary><strong>Answer</strong></summary>

  Adding a broker does not move anything — Kafka does not automatically redistribute existing partitions, so a new broker sits idle until an operator generates and executes a reassignment plan that names which replicas move where. Removing a broker requires the same operation in reverse before decommissioning it.

  Reassignment copies the full partition data to the new replica, so it is the one operation here that saturates networks and disks. That is why it must be throttled: an unthrottled reassignment of large partitions starves the replication traffic of everything else and pushes healthy partitions out of their in-sync sets, turning a planned expansion into an incident.

  **The line worth saying is** that the throttle is not an optimisation, it is the difference between a maintenance task and an outage.

  </details>

- **MUST** — Increasing the partition count breaks key mapping

  <details><summary><strong>Answer</strong></summary>

  Partition assignment for keyed records is a hash modulo the partition count, so changing the count changes the destination of most keys. Existing records stay where they are, which means a key's history is now split across two partitions — the old records in one, the new in another — and per-key ordering is broken across the boundary for any consumer that cares.

  For a compacted topic it is worse: two versions of the same key living in different partitions will never compact against each other, so the log permanently holds a stale value that a consumer reading from the start will see.

  The practical answers are to over-provision partitions at creation, to accept the break for topics where per-key ordering does not matter, or to create a new topic with the target count and migrate consumers deliberately. Volunteering the compacted-topic case is what makes this answer stand out.

  </details>

- **MUST** — The count cannot go down

  <details><summary><strong>Answer</strong></summary>

  There is no operation to reduce a topic's partition count, because it would mean merging logs with independent offset sequences and no sensible way to preserve order or offsets. The only route is a new topic and a migration.

  This is what makes over-provisioning asymmetric: too few partitions is a painful, disruptive fix, too many is a steady, tolerable cost. **That asymmetry is** the reason to err upward within reason, and stating the reasoning is better than quoting a number.

  </details>

- **NICE** — Repartition topics in stream processing

  <details><summary><strong>Answer</strong></summary>

  When a stream processing application changes a record's key before an aggregation or a join, the data must be physically redistributed so that all records for a key reach one task — so the framework writes to an internal **repartition topic** and reads back from it. That is a full network round trip through the cluster, and it is the hidden cost behind an innocuous-looking key change in a topology.

  It also explains the co-partitioning requirement for joins: two topics can only be joined task-locally if they share a partition count and a partitioning strategy, and otherwise one of them must be repartitioned first.

  </details>

- **NICE** — Automated balancing

  <details><summary><strong>Answer</strong></summary>

  Leadership and replica placement drift over time as brokers restart and topics are created, so clusters become unbalanced through ordinary operation. Preferred leader election restores leadership to the intended replica cheaply; genuine data balancing needs a reassignment, and tools exist that plan and execute those continuously against a goal set such as disk use, network use and rack spread.

  Knowing that the built-in tooling plans nothing for you — it executes a plan you supply — is the practical distinction worth drawing.

  </details>

- **OPTIONAL** — What to watch during any of them

  <details><summary><strong>Answer</strong></summary>

  For a consumer rebalance, watch group state and lag per partition. For a reassignment, watch under-replicated partitions, replication throughput against the configured throttle, and disk use on the receiving brokers. For a partition count change, watch consumers for ordering assumptions and compacted topics for stale keys.

  The common thread is that each operation has one leading indicator that says it is going badly, and knowing which one is what separates having run these from having read about them.

  </details>

## 23. Leader Election

**Why it comes up:** Kafka runs three unrelated elections and they get answered as if they were one, so naming which is meant is the first move.

- **MUST** — Partition leader election

  <details><summary><strong>Answer</strong></summary>

  Every partition has one **leader replica** serving all reads and writes for it. When a leader's broker fails, the controller picks a replacement from that partition's in-sync set, publishes the change in cluster metadata, and clients discover it on their next metadata refresh.

  Choosing only from the in-sync set is what makes the election safe: any of those replicas already holds every acknowledged record, so promoting one loses nothing. That single constraint is the whole correctness argument, and it is why the unclean variant — promoting a replica that is not in the set — is a data loss decision rather than an availability tuning knob.

  </details>

- **MUST** — The preferred leader, and why leadership drifts

  <details><summary><strong>Answer</strong></summary>

  Each partition has a **preferred leader**, the first broker in its replica list, chosen so that leadership is spread evenly when the topic is created. After a broker restarts, its partitions have already failed over elsewhere and leadership does not come back on its own, so a cluster that has had a few rolling restarts ends up with leaders concentrated on the brokers that restarted least recently.

  Preferred leader election moves leadership back to the intended replica, and the cluster will do it automatically on an interval when the imbalance exceeds a threshold. The operational point is that this is cheap — no data moves, only which replica serves — which is what makes it safe to run routinely, unlike a reassignment.

  </details>

- **MUST** — Controller election

  <details><summary><strong>Answer</strong></summary>

  Separately from partition leaders, one component leads the cluster: the **controller**, which decides partition leadership, tracks in-sync sets, and applies topic creation and reassignment. Under the older architecture it was a broker that won a race to create an ephemeral node in the coordination service, and losing its session triggered a fresh race.

  With metadata held in a replicated log, controller election is an ordinary consensus leader election among the controller quorum, with the usual epoch numbering that fences a deposed leader. The reason to mention the epoch is that it is what prevents the split brain the older design guarded against with session timeouts.

  </details>

- **MUST** — Clean and unclean, stated as a choice

  <details><summary><strong>Answer</strong></summary>

  A clean election promotes an in-sync replica and loses nothing; if none is available the partition goes offline and waits. An unclean election promotes an out-of-sync replica, restoring availability immediately and discarding every record the failed leader had that the promoted replica does not — including acknowledged records that consumers may already have processed.

  It is off by default. Turning it on is defensible for streams where a gap is cheaper than an outage, and indefensible for anything where a lost record is a lost fact. **The framing that lands is** that this setting is the partition-level answer to the consistency against availability question, made explicit and configurable.

  </details>

- **NICE** — What clients see during an election

  <details><summary><strong>Answer</strong></summary>

  A producer or consumer holding stale metadata sends its request to the old leader and gets a not-leader error, which the client treats as retriable: it refreshes metadata, finds the new leader and retries. Well-configured clients therefore ride out a leader change as a short latency bump rather than as failures.

  That is why those errors appear in logs during a rolling restart and are not an incident, and why a producer that surfaces them to the application usually has its retry or delivery timeout set too aggressively. Being able to say that these errors are expected and absorbed is a useful piece of operational calm.

  </details>

- **NICE** — The consumer group leader is a third, unrelated thing

  <details><summary><strong>Answer</strong></summary>

  In the long-standing group protocol, one consumer in a group is designated leader and computes the partition assignment for the whole group, with the coordinator distributing the result. It is a client-side role with nothing to do with partition leaders or the controller, and its only power is deciding who gets which partition.

  Newer protocol versions move that computation to the broker, removing the role entirely. Noticing that three different things in Kafka are called leaders, and saying which one the question meant, is a good way to answer this topic.

  </details>

- **OPTIONAL** — Election latency and cluster size

  <details><summary><strong>Answer</strong></summary>

  Failing over one partition is fast; failing over every partition a dead broker led is proportional to how many that was, because each is a metadata change that must be decided and propagated. On very large clusters that made controller failover measurably slow under the older architecture, which was one of the motivations for the metadata redesign.

  The practical implication is that partition count affects recovery time, which is another reason the count is a sizing decision rather than a free dial.

  </details>

## 24. Data Retention Settings

**Why it comes up:** retention is the only thing that deletes data, so it is a cost decision, a replay window and a compliance obligation at the same time.

- **MUST** — The two deletion limits

  <details><summary><strong>Answer</strong></summary>

  `retention.ms` deletes data older than a given age and defaults to seven days. `retention.bytes` deletes the oldest data once a partition exceeds a size, and defaults to unlimited. When both are set, whichever triggers first wins.

  The detail people get wrong is that the size limit is **per partition**, not per topic, so a topic with fifty partitions and a size limit configured as if it were a topic-wide budget can hold fifty times the intended data. Getting that right in the answer is a small but reliable signal.

  </details>

- **MUST** — Retention acts on whole segments

  <details><summary><strong>Answer</strong></summary>

  A partition is a sequence of segment files, and deletion removes an entire segment once its newest record is older than the retention window. The active segment is never deleted, so data is retained until the segment rolls — by size or by `segment.ms` — and only then becomes eligible.

  **The consequence is** that a low-traffic topic keeps data far longer than its retention setting suggests: with a one-hour retention and a segment that rolls weekly, records survive for over a week. Anyone who has set a short retention for compliance reasons and then found the data still present has met this, and naming it is a strong answer.

  </details>

- **MUST** — Compaction is the other cleanup policy

  <details><summary><strong>Answer</strong></summary>

  With `cleanup.policy=compact`, the broker retains at least the most recent record for each key and removes superseded ones in the background, so the log becomes a durable snapshot of current state rather than a window of history. Offsets remain the ones originally assigned, so a **compacted log** has gaps; ordering among surviving records is preserved.

  This is what makes a topic usable as a changelog: a consumer reading from the beginning reconstructs current state for every key, however old the last write. It is the right policy for state — configuration, a materialised table, a stream processor's store — and the wrong one for events, where the history is the point.

  </details>

- **MUST** — Tombstones, and how deletion works on a compacted topic

  <details><summary><strong>Answer</strong></summary>

  A key is removed by writing a record with that key and a null value: a **tombstone**. Compaction removes the earlier values immediately and keeps the tombstone itself for a further configured period so that consumers currently reading have a chance to observe the deletion, after which it too is removed.

  The failure this prevents is a consumer that was offline during the tombstone's lifetime rebuilding its state and never learning the key was deleted. **The rule is** that the tombstone retention must exceed the longest realistic consumer outage, and treating it as an arbitrary default is how a deleted record reappears downstream.

  </details>

- **MUST** — Retention is a replay window and a liability at once

  <details><summary><strong>Answer</strong></summary>

  Retention decides how far back a consumer can be rebuilt from, so it must exceed the longest outage you intend to survive plus the time it takes to notice — a consumer down longer than retention does not catch up, it loses records permanently and resets to whatever `auto.offset.reset` says.

  It is simultaneously a liability, because a topic carrying personal data retains it for exactly that long and an erasure obligation does not care that the log is append-only. **The three honest techniques are** a short retention, a keyed compacted topic where a tombstone removes the subject, or encrypting per subject and destroying the key so the retained bytes are unreadable.

  Raising the compliance dimension unprompted is unusual and it lands well, because most answers treat retention purely as a disk cost.

  </details>

- **NICE** — Compaction and deletion together

  <details><summary><strong>Answer</strong></summary>

  Setting both policies keeps the latest value per key and also drops anything older than the time limit, which is what a stream processor's windowed state store wants — current values, bounded by the window's usefulness, rather than a snapshot that grows for ever.

  It is also the pragmatic choice for a changelog of a key space that churns, where compaction alone leaves a long tail of keys that will never be written again.

  </details>

- **NICE** — Tiered storage

  <details><summary><strong>Answer</strong></summary>

  **Tiered storage** offloads closed segments to object storage while keeping a recent local window on the brokers, so retention can be months without sizing broker disks for months. Consumers read historical data transparently, more slowly, and the broker keeps serving recent reads from the page cache at full speed.

  It changes the economics of the earlier trade-off, because long retention stops competing with cluster sizing, and it is the modern answer to "we would like to replay a quarter but cannot afford the disks". The cost is added read latency for cold data and a dependency on the object store's availability.

  </details>

- **OPTIONAL** — Deleting data on demand

  <details><summary><strong>Answer</strong></summary>

  Records before a given offset can be deleted administratively, which truncates the head of a partition and is the blunt instrument for clearing a topic that has gone wrong. It works at partition and offset granularity, not by content, so it cannot remove one record.

  That limitation is the point: an append-only log has no update-in-place, which is why deletion on a log is always either a retention policy, a tombstone on a keyed topic, or cryptographic erasure.

  </details>

## 25. The Cluster Controller

**Why it comes up:** it is the "what is the cluster leader for" question, and the useful answer explains what it does *not* do.

- **MUST** — What the controller is for

  <details><summary><strong>Answer</strong></summary>

  Exactly one broker or controller node acts as the **controller**, and it owns the cluster's administrative decisions: which replica leads each partition, which replicas are in sync, what happens when a broker joins or leaves, and the execution of topic creation, deletion, partition changes and reassignments.

  Everything it does is metadata. It decides, records the decision, and propagates it; the brokers then act on it. Framing it as the cluster's decision-maker rather than its coordinator is the clearest way in, because it explains why there is exactly one and why its failure is survivable.

  </details>

- **MUST** — It is not in the data path

  <details><summary><strong>Answer</strong></summary>

  No produced record and no consumed record passes through the controller. Clients talk to partition leaders directly, and a controller that is briefly absent does not stop traffic — existing leaders keep serving, producers keep producing and consumers keep consuming.

  What stops during a controller outage is change: no failover for a broker that dies, no topic creation, no reassignment progress. **The distinction being tested is** exactly this — the controller is a single point of decision, not a single point of failure for throughput, and answering that it would take the cluster down is the mistake the question is hunting for.

  </details>

- **MUST** — How it is elected and what its epoch is for

  <details><summary><strong>Answer</strong></summary>

  Under the older architecture the controller was whichever broker first created an ephemeral node in the coordination service; losing that session triggered a new race. Under the current architecture, controller nodes form a consensus quorum and elect a leader among themselves in the ordinary way.

  Either way the controller carries an **epoch** that increments on every election, and every decision it publishes is stamped with it. A broker ignores instructions carrying an older epoch, which is what fences a controller that believes it is still in charge after a network glitch — the split brain that would otherwise assign two leaders to one partition.

  </details>

- **MUST** — What a controller failover costs

  <details><summary><strong>Answer</strong></summary>

  Under the older design the new controller had to load the entire cluster's metadata from the coordination service before it could act, so failover time grew with the number of partitions and could reach minutes on a large cluster — during which no partition could fail over.

  With metadata as a replicated log, the standby controllers are already following that log, so taking over is a matter of an election rather than a load, and failover is effectively immediate regardless of cluster size. That contrast is the clearest way to explain why the architecture changed, and it is what the question usually leads to.

  </details>

- **NICE** — Dedicated controller nodes

  <details><summary><strong>Answer</strong></summary>

  Current deployments run a small odd-numbered set of nodes in the controller role, either dedicated or combined with the broker role on the same process. Dedicated controllers are the production recommendation: the controller's work is isolated from broker load, a busy broker cannot slow cluster decisions, and the two roles can be sized and upgraded independently.

  Combined mode exists for development and small clusters, where running three extra processes is not worth it. Saying which you would use and why is a better answer than describing both neutrally.

  </details>

- **NICE** — What to watch

  <details><summary><strong>Answer</strong></summary>

  Active controller count across the cluster should be exactly one — zero means no decisions are being made and two means something is badly wrong. Frequent controller elections point at instability in the quorum or the network rather than at load, and a growing queue of unapplied metadata changes means the controller is behind.

  Alerting on active controller count not equal to one is the cheapest useful Kafka alert there is.

  </details>

- **OPTIONAL** — The same role elsewhere

  <details><summary><strong>Answer</strong></summary>

  Almost every replicated data system has this component under a different name — a coordinator, a master, a config server, a cluster manager — and it almost always follows the same rules: one at a time, elected by consensus, fenced by an epoch, and deliberately outside the data path so that its absence degrades administration rather than service.

  Recognising the shape means the first questions to ask about an unfamiliar clustered system are where its decisions are made, how that component is elected, and what stops working when it is gone.

  </details>

## 26. ZooKeeper and KRaft Quorums

**Why it comes up:** it is a version-awareness question as much as an architecture one, and the interesting part is why the dependency was removed.

- **MUST** — What [ZooKeeper](https://zookeeper.apache.org/doc/current/ "Apache ZooKeeper — Coordination service that stores cluster metadata and elects leaders for distributed systems") held

  <details><summary><strong>Answer</strong></summary>

  Historically Kafka delegated all cluster coordination to **ZooKeeper**: which brokers are alive, which topics exist with what configuration, each partition's replica list and in-sync set, access control rules, and the ephemeral node whose ownership decided the controller. ZooKeeper is a replicated, strongly consistent hierarchical store with its own consensus protocol and its own odd-numbered quorum.

  The relevant mental model is that Kafka's durable data lived in Kafka and Kafka's truth about itself lived somewhere else, which is the seam the redesign removed.

  </details>

- **MUST** — What [KRaft](https://kafka.apache.org/documentation/#kraft "Kafka Raft — Kafka's consensus protocol that holds cluster metadata in a replicated log rather than in ZooKeeper") replaced it with

  <details><summary><strong>Answer</strong></summary>

  **KRaft** stores cluster metadata in an internal Kafka topic replicated by a consensus protocol among a quorum of controller nodes. Every metadata change — a leadership change, a topic creation, an in-sync set update — is an append to that log, and brokers consume it exactly as consumers consume any other topic, applying changes in order.

  The elegance is that Kafka now uses its own primitives for its own state: an ordered replicated log with offsets, which is the thing it was always good at. A broker that reconnects catches up by reading from its last metadata offset rather than by fetching a full snapshot, which is where most of the improvement comes from.

  </details>

- **MUST** — Why the change was worth making

  <details><summary><strong>Answer</strong></summary>

  Four reasons, and naming several is the good answer. Operationally, one system to deploy, secure, monitor and upgrade instead of two with different configuration and security models. Scalability, because metadata propagation as an incremental log lifted the practical ceiling on partition count by roughly an order of magnitude. Recovery, because controller failover stopped being proportional to cluster size. And correctness, because one replicated log with epochs is a simpler thing to reason about than two consensus systems whose views can disagree.

  The version-aware part is the ending: ZooKeeper support was deprecated and then removed, so on current releases the question is only about migration and history.

  </details>

- **MUST** — Quorum sizing is the same reasoning in both

  <details><summary><strong>Answer</strong></summary>

  Both use an odd-numbered quorum with majority agreement, so three nodes tolerate one failure and five tolerate two; even numbers add cost without adding tolerance. Losing the quorum means no metadata changes can be made, which stops failover, topic creation and reassignment while leaving existing traffic flowing.

  Three is the normal choice, five where two simultaneous failures must be survivable. That the reasoning is identical between the two systems is worth saying, because it makes clear the change was about where the consensus lives rather than about the consensus itself.

  </details>

- **MUST** — Migration, and what version awareness means here

  <details><summary><strong>Answer</strong></summary>

  Migration is a documented, staged process: provision controllers, put the cluster into a dual-write mode where metadata goes to both, roll the brokers, then finalise and decommission the old ensemble — with a point of no return partway through. It is not a configuration flip, and treating it as one is how a migration goes wrong.

  The answer that lands is to state which architecture you have worked with and to be accurate about the version boundary rather than to describe both as if they were current options. Claiming familiarity with a migration you have not done is exactly the kind of thing a follow-up question exposes.

  </details>

- **NICE** — Combined and separated modes

  <details><summary><strong>Answer</strong></summary>

  A node can take the controller role, the broker role, or both. Combined mode keeps small clusters and development environments simple; separated mode is the production recommendation, because it isolates cluster decision-making from data-path load and lets the two be scaled and restarted independently.

  The rollout detail worth knowing is that controllers and brokers are upgraded in a defined order, which is the kind of thing that only matters once and matters a great deal then.

  </details>

- **NICE** — What else used to depend on ZooKeeper

  <details><summary><strong>Answer</strong></summary>

  Old consumer clients stored their offsets in ZooKeeper before the internal offsets topic existed, which is why very old tooling asks for a ZooKeeper connection string and why offset migration was once a real operation. Access control rules and dynamic configuration also lived there, and the security model was separate from Kafka's, so an unprotected ensemble was a genuine hole in an otherwise secured cluster.

  That last point is a good concrete answer to why one system is better than two.

  </details>

- **OPTIONAL** — ZooKeeper on its own terms

  <details><summary><strong>Answer</strong></summary>

  **ZooKeeper** is a general coordination service: a small hierarchical namespace of nodes, sequential and ephemeral node types, watches that notify a client of changes, and linearizable writes through its own consensus protocol. Those primitives compose into distributed locks, leader election and membership, which is why it sat under so much of the ecosystem.

  Kafka removing it is one instance of a broader move away from a shared external coordinator toward systems that carry their own consensus, and being able to place it in that trend is a good closing observation.

  </details>

## 27. Controller Metadata and Broker Metadata

**Why it comes up:** it sounds like one question and is two — where the cluster's truth is stored, and what a broker tells a client — and the answer is about how they stay in step.

- **MUST** — Two different questions wearing one name

  <details><summary><strong>Answer</strong></summary>

  The first is where the authoritative record lives: which topics exist, each partition's replicas, its in-sync set and its current leader. That is owned by the controller and stored in the metadata log, or historically in the coordination service.

  The second is what a broker serves when a client asks where to send a produce request. Every broker holds a **local cache** of cluster metadata and answers metadata requests from it, so any broker can tell a client which broker leads a partition without the client ever contacting the controller. Separating the authority from the cache is the whole topic.

  </details>

- **MUST** — How the cache is kept current

  <details><summary><strong>Answer</strong></summary>

  Under the older architecture the controller pushed updates to brokers, so a broker's cache was as current as the last message it received and a missed update left it stale until the next one. Under the current architecture each broker follows the metadata log itself and applies records in order, so a broker's view is a prefix of the authoritative history rather than an accumulation of pushes.

  **The improvement is** that a lagging broker is behind by a measurable offset rather than wrong in an unknown way, which makes staleness observable — there is a metric for how far behind a broker's metadata is, and that is a genuinely different operational position.

  </details>

- **MUST** — Stale metadata is normal and clients expect it

  <details><summary><strong>Answer</strong></summary>

  A client caches the leader for each partition and refreshes periodically, so immediately after a leader change some clients are certainly wrong. They send to the old leader, receive a not-leader error, refresh and retry — the error is retriable by design and the client library absorbs it.

  That is why brief bursts of these errors during a rolling restart are expected rather than alarming, and why a client that surfaces them as failures usually has a delivery timeout shorter than its metadata refresh. **The rule is** that metadata is eventually consistent and correctness comes from the leader rejecting requests it should not serve, not from clients being up to date.

  </details>

- **MUST** — Why a partition leader's own view is not authoritative

  <details><summary><strong>Answer</strong></summary>

  A partition leader knows its own log and its followers' fetch positions, and it proposes in-sync set changes — but it does not decide them, and it cannot decide that it is no longer the leader. Only the controller makes that call and records it with an epoch.

  This is what stops a leader that has been partitioned away from continuing to accept writes after it has been replaced: its epoch is stale, so followers and clients reject it. Being able to say that leadership is a fact in the metadata log rather than a belief held by a broker is the precise version of the answer.

  </details>

- **NICE** — Metadata size and refresh

  <details><summary><strong>Answer</strong></summary>

  A metadata response carries brokers, topics, partitions, leaders and replica lists, so it grows with the cluster and a client subscribing to everything on a large cluster is fetching a substantial structure on every refresh. Clients refresh on an interval and on demand when they hit a retriable routing error, and requesting metadata for only the topics in use keeps the response small.

  It is a real cost at scale and a classic reason a cluster with very many partitions feels slow in ways unrelated to message throughput.

  </details>

- **NICE** — Debugging a disagreement

  <details><summary><strong>Answer</strong></summary>

  When a client insists a partition has a different leader from what an administrative tool reports, the order to check is the metadata log or controller view first as the authority, then the broker's cached view and how far behind it is, then the client's own refresh interval. In most cases the answer is that something is behind rather than that something is wrong.

  The one genuinely broken state is a broker whose metadata application has stalled, which presents as that broker persistently disagreeing while others are correct, and it is the case where restarting it is actually the right move.

  </details>

- **OPTIONAL** — Bootstrap servers are not a cluster list

  <details><summary><strong>Answer</strong></summary>

  The bootstrap configuration is only a starting point for discovery: a client connects to any of them, fetches metadata, and from then on talks to whichever brokers actually lead its partitions, including ones not in the list. That is why a client can keep working after every bootstrap broker has been replaced, and why listing only one is a startup availability risk rather than a steady-state one.

  Listing two or three across failure domains is the practical guidance.

  </details>

## 28. Kafka Connect

**Why it comes up:** it is the "would you write a consumer for that" question, and for moving data between Kafka and a well-known system the answer is usually no.

- **MUST** — What it is and why it exists

  <details><summary><strong>Answer</strong></summary>

  **Kafka Connect** is a framework and a runtime for moving data between Kafka and other systems using configuration rather than code. A source connector reads from an external system and produces to Kafka; a sink connector consumes from Kafka and writes outward.

  It exists because the hundredth bespoke consumer that writes to a database re-implements the same things badly: offset tracking, restart-safe progress, schema handling, retries, backoff, dead-lettering, parallelism and metrics. Connect implements those once and leaves the connector author with the part that is actually specific to the system.

  The judgement being tested is whether you reach for configuration before code for a solved integration.

  </details>

- **MUST** — Workers, connectors and tasks

  <details><summary><strong>Answer</strong></summary>

  A **connector** is a configuration describing what to move. The runtime splits it into **tasks**, each of which is the unit of parallelism — a sink connector's tasks are consumers in a group, so its parallelism is capped by the topic's partition count, and a source connector's tasks are whatever partitioning the source offers, such as tables or file directories. **Workers** are the processes that run tasks.

  Setting `tasks.max` above the available parallelism creates idle tasks and no throughput, which is the same lesson as consumers exceeding partitions and is worth naming as the same lesson.

  </details>

- **MUST** — Distributed mode and where state lives

  <details><summary><strong>Answer</strong></summary>

  Standalone mode runs one worker with local state and exists for development. **Distributed mode** runs a group of workers that share the load, rebalance tasks when a worker joins or dies, and keep everything in Kafka itself: three internal topics holding connector configurations, source offsets and task status.

  Because the state is in Kafka, a worker is disposable — it can be killed and replaced, and its tasks resume from the recorded offsets on another worker. Connectors are managed through a [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") interface rather than by editing files, which also means the running configuration is not in version control unless someone deliberately puts it there, and that is a real operational gap worth mentioning.

  </details>

- **MUST** — Converters decide what is on the wire

  <details><summary><strong>Answer</strong></summary>

  A connector produces or consumes an internal record structure, and a **converter** turns it into the bytes in the topic — [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") with or without an embedded schema, Avro, Protobuf, or raw strings and bytes. Key and value converters are configured separately, and they are properties of the pipeline rather than of the connector.

  The most common Connect failure is a converter mismatch: a sink configured for Avro reading a topic written as plain JSON fails on the first record with a deserialisation error that names the converter rather than the cause. Knowing that the converter, not the connector, is where serialisation is decided is what makes that error readable.

  </details>

- **MUST** — Error handling and the dead letter topic

  <details><summary><strong>Answer</strong></summary>

  By default a task that hits a bad record fails and stops, which is safe and also means one malformed message halts a pipeline. The error handling settings change that: tolerate all errors, retry a configurable number of times with backoff, and route failed records to a **dead letter topic** with headers recording the original topic, partition, offset and the exception.

  Enabling tolerance without a dead letter topic is the mistake to warn against, because records are then dropped silently. Enabling both, and alerting on the dead letter topic having any records at all, is the configuration worth recommending out loud.

  </details>

- **NICE** — Single message transforms, and their limit

  <details><summary><strong>Answer</strong></summary>

  **Transforms** are small, chained, stateless functions applied to each record in flight: rename or drop a field, mask a value, cast a type, route to a topic based on content, or flatten a nested structure. They are the reason a large share of pipelines need no code at all.

  Their limit is in the name. A transform sees one record with no state, no access to other topics and no ability to join or aggregate, so anything requiring memory belongs in a stream processor between two Connect pipelines rather than in a transform. Stating that boundary is more useful than listing transforms.

  </details>

- **NICE** — What a connector actually guarantees

  <details><summary><strong>Answer</strong></summary>

  Connect's framework-level guarantee is at-least-once in both directions, because offsets are flushed periodically rather than atomically with the write. Some sinks do better by being idempotent or by committing offsets inside the destination's own transaction, and some source connectors support exactly-once via Kafka transactions.

  **The honest answer is** therefore that the guarantee is a property of the specific connector and its configuration, not of Connect, and that the safe assumption for a sink you have not verified is at-least-once with duplicates after every restart.

  </details>

- **OPTIONAL** — When to write a consumer instead

  <details><summary><strong>Answer</strong></summary>

  Write code when the transformation is genuinely business logic, when the destination has no maintained connector, or when the work needs state, joins or calls to other services. Use Connect when the shape is "read from here, write to there" against a system someone has already written a connector for.

  Operating Connect is its own commitment — another cluster, another upgrade path, another thing to monitor — so for a single simple pipeline in a team that already runs consumers, a small consumer can be the cheaper choice, and saying so is more credible than recommending the framework unconditionally.

  </details>

## 29. Change Data Capture with Debezium

**Why it comes up:** it is the standard answer to getting data out of a database without changing the application, and the follow-up is always what it costs that database.

- **MUST** — What it is, and why the log rather than a query

  <details><summary><strong>Answer</strong></summary>

  **Change data capture** turns a database's own write-ahead log into a stream of row-level change events, so every insert, update and delete is published in commit order without the application knowing.

  The alternative — polling a table for rows whose timestamp changed — has three defects that log reading does not. It cannot see deletes, because the row is gone. It misses intermediate states, since a row updated three times between polls yields one event. And it puts query load on the database that grows with polling frequency. Reading the log has none of these, because the log is the complete, ordered record the database already writes for its own recovery.

  Naming those three gaps is the fastest way to show the topic is understood rather than named.

  </details>

- **MUST** — How the connector gets at the log

  <details><summary><strong>Answer</strong></summary>

  [Debezium](https://debezium.io/documentation/reference/stable/ "Debezium — Change data capture platform that publishes database row changes as event streams") is the reference implementation and the one most often named, and it works against each database's native replication interface rather than through anything of its own. On [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") it uses logical decoding: the server is configured for logical replication, the connector creates a **replication slot** and a publication, and the server decodes write-ahead log records into row changes for that slot. On MySQL it reads the binary log directly, which must be in row-based format so that full before and after images are available rather than the statements that produced them.

  In both cases the connector presents itself as a replication client, which is the design's strength — it uses a mechanism the database already supports and maintains — and the source of its operational risk, which is the next bullet.

  </details>

- **MUST** — Snapshot, then stream

  <details><summary><strong>Answer</strong></summary>

  A connector starting against an existing database first takes a consistent **snapshot** of the captured tables, emitting a read event per row, then switches to streaming from the log position recorded at the snapshot's start, so no change is missed or duplicated across the handover.

  The snapshot is the expensive part: it reads every row of every captured table, and on older versions it took locks that could block writes. Incremental snapshotting removed that by chunking the snapshot and interleaving it with live streaming, using watermarks to reconcile the two — which also makes it possible to re-snapshot one table on demand without restarting the connector. Knowing that a re-snapshot is a chunked background operation rather than a restart is the current, credible version of this answer.

  </details>

- **MUST** — The event envelope

  <details><summary><strong>Answer</strong></summary>

  Each event carries the row before the change, the row after it, an operation code for create, update, delete or snapshot read, and a source block with the table, the log position and timestamps. The key is the row's primary key, so a topic per table with that key gives per-row ordering and makes the topic compactable into current state.

  Two consequences follow. A delete produces a delete event and then a null-valued tombstone under the same key, so that compaction can remove the row entirely. And consumers usually do not want the envelope, so a transform that extracts the after-image and leaves the operation in a header is the near-universal first step of any pipeline built on this.

  </details>

- **MUST** — What it costs the database

  <details><summary><strong>Answer</strong></summary>

  The dangerous one is the **replication slot**. PostgreSQL retains every write-ahead log segment a slot has not yet consumed, so a connector that is stopped, stuck, or slower than the write rate causes unbounded log growth and eventually fills the disk and takes the database down. It is the classic incident, and it is caused by the connector being down rather than by it running.

  Two further details complete the answer. A quiet captured table on a busy database has the same effect, because the slot's position only advances on changes it cares about — which is what the connector's heartbeat exists to fix, by periodically advancing the slot. And a replication slot has historically not survived a failover to a standby, so a promoted replica starts with no slot and the connector must be re-established, which is a real disaster-recovery consideration rather than a footnote.

  Monitoring slot lag as a database metric, not a pipeline metric, is the operational conclusion.

  </details>

- **MUST** — The guarantee it gives

  <details><summary><strong>Answer</strong></summary>

  At-least-once. The connector records its log position periodically, so a crash replays from the last recorded position and re-emits events already published — a consumer must be idempotent, and the log position in the event makes a good deduplication key.

  Ordering is guaranteed per table and per key, because events for one primary key go to one partition in log order. Ordering *across* tables is not: a parent and child row written in the same database transaction become events on different topics with no ordering relationship, so a consumer that assumes it will see the parent first is wrong. The transaction metadata a connector can emit lets a careful consumer reassemble transaction boundaries, and saying that unprompted is a strong depth signal.

  </details>

- **NICE** — Where it meets the outbox pattern

  <details><summary><strong>Answer</strong></summary>

  Capturing every table publishes the database's internal schema as a public contract, which couples every consumer to a table layout nobody intended to freeze. The **outbox** pattern avoids that: the application writes a purpose-built event row in the same transaction as the business change, and the connector captures only that one table, routing rows to topics by a column in them.

  This is the best of both — atomicity between the write and the event, a deliberate published contract, and no dual write — and it is the shape worth recommending for a service publishing domain events. Capturing tables directly is better suited to replication, analytics and search indexing, where the consumer genuinely wants the table.

  </details>

- **NICE** — Schema changes

  <details><summary><strong>Answer</strong></summary>

  Schema changes appear in the log too, and the connector tracks them so that events are decoded against the schema in force at their position — MySQL requires a dedicated history topic for this, since the binary log alone does not carry enough. The consequence is that a column added upstream shows up in downstream events without anyone being consulted.

  The practical defence is compatibility rules in a schema registry plus consumers that ignore unknown fields, and a working agreement that a destructive change upstream is coordinated. Saying that change data capture makes schema evolution a cross-team concern, rather than a database concern, is the point.

  </details>

- **OPTIONAL** — When not to use it

  <details><summary><strong>Answer</strong></summary>

  It is the wrong tool when the application can simply publish the event itself and owns that contract, when the database is not one with a usable log interface, or when the consumer wants a business event and would have to reconstruct it from row changes across several tables — which is a query, not a stream.

  Trigger-based capture and query-based polling remain the fallbacks where the log is unavailable, and both are worse in the specific ways named at the top. Being able to say which fallback you would accept, and what you would lose, is the complete answer.

  </details>

## 30. Schema Registry

**Why it comes up:** it is the "how do you change a message format without breaking consumers" question, which is the real operational problem with any long-lived topic.

- **MUST** — What it is, and what is actually on the wire

  <details><summary><strong>Answer</strong></summary>

  A **schema registry** is a service that stores message schemas, assigns each a version and an identifier, and enforces a compatibility rule when a new version is registered. The serialiser registers or looks up the schema, then writes a small identifier prefix followed by the encoded payload; the deserialiser reads the identifier, fetches that exact schema, and decodes.

  The schema itself is never in the message, which is the point: the payload stays compact and every consumer can still decode any record, including one written years ago by a producer that no longer exists. Clients cache schemas by identifier, so a registry outage does not stop steady-state traffic but does stop new schemas and cold starts.

  </details>

- **MUST** — Subjects, versions and compatibility

  <details><summary><strong>Answer</strong></summary>

  Schemas are grouped under a **subject**, by default one per topic and field — key and value separately — each holding an ordered list of versions. Registering a new version succeeds only if it satisfies the subject's compatibility rule.

  Backward compatibility means the new schema can read data written with the old one; forward means the old schema can read data written with the new one; full means both; none disables the check. Each also has a transitive form that checks against every previous version rather than only the most recent, which is the one you want if consumers may be replaying old data — and the non-transitive default is a subtle trap for exactly that case.

  </details>

- **MUST** — Which side upgrades first

  <details><summary><strong>Answer</strong></summary>

  This is the question the modes exist to answer. Under backward compatibility, **consumers upgrade first**: the new schema can read old data, so consumers running it cope with both while producers are still on the old version. Under forward compatibility, **producers upgrade first**, because old consumers can read the new data.

  Backward is the sensible default for a stream with many independent consumers, since the producer is the one thing you want to be able to change without coordinating a fleet. The permitted changes follow mechanically: under backward you may remove a field or add one with a default, and adding a required field is what breaks it.

  Being able to derive the rollout order from the mode, rather than recite the modes, is what the question is for.

  </details>

- **MUST** — What it does not do

  <details><summary><strong>Answer</strong></summary>

  It checks structural compatibility, not meaning. Changing a field from storing minor units to storing decimal amounts, or repurposing a status value, passes every compatibility check and breaks every consumer — the structure is unchanged and the semantics are not.

  It also does not validate that a producer's data is correct, does not apply to topics whose producers bypass it, and does not stop a consumer ignoring a field it should have handled. **The boundary worth naming is** that the registry automates the mechanical half of compatibility and leaves the semantic half to people, which is why a schema change still deserves a review.

  </details>

- **NICE** — Avro, Protobuf and JSON Schema

  <details><summary><strong>Answer</strong></summary>

  **Avro** was the original pairing and remains the most idiomatic: compact binary encoding, schemas as data, and defaults and aliases designed for exactly this kind of evolution. Protocol buffers bring field numbering and strong cross-language tooling, and suit organisations already using them for their service contracts. JSON Schema keeps the payload human-readable at a significant size cost and is easiest to adopt where consumers are heterogeneous.

  The choice matters less than consistency across a platform, because every consumer needs the matching deserialiser. Picking a default and sticking to it is the recommendation.

  </details>

- **NICE** — Governance in practice

  <details><summary><strong>Answer</strong></summary>

  The registry becomes valuable when schema changes are reviewed like interface changes: schemas in version control, a pipeline step that checks a proposed schema against the registry's compatibility rule before merge, and the registry itself locked down so that production schemas are not registered ad hoc by a developer's client.

  Without that discipline, the first producer to run in an environment silently defines the schema for everyone, which is how an experiment becomes a contract. Naming the pipeline check is the concrete part of this answer.

  </details>

- **OPTIONAL** — It is not part of Apache Kafka

  <details><summary><strong>Answer</strong></summary>

  The registry is an ecosystem component rather than part of the broker, originating with Confluent and also implemented by other projects with compatible interfaces. That matters for licensing, for what a managed offering includes, and for portability between vendors.

  The wire format's identifier prefix is the de facto interoperability point, which is why alternative implementations aim to match it. Knowing the component is separable is enough; the detail only matters when someone is choosing a platform.

  </details>

## 31. Kafka Streams

**Why it comes up:** it is the "do you process streams or only move them" question, and the first sentence people get wrong is what kind of thing it is.

- **MUST** — It is a library, not a cluster

  <details><summary><strong>Answer</strong></summary>

  **Kafka Streams** is a client library linked into an ordinary application. There is no processing cluster, no job submission and no scheduler — you run more instances of your own service and they coordinate through the same consumer group mechanism everything else uses.

  That is its main advantage over a separate stream processing platform: deployment, scaling, monitoring and on-call are whatever they already are for a service. Its main limitation follows from the same fact — it runs on the Java virtual machine, so a team working in another language reaches for a cluster-based processor or a plain consumer instead, and saying that plainly is better than pretending the choice is purely technical.

  </details>

- **MUST** — Streams and tables are the same data seen two ways

  <details><summary><strong>Answer</strong></summary>

  A **KStream** is an unbounded sequence of independent events, where every record is a fact that happened. A **KTable** is a changelog, where a record with a key replaces the previous value for that key, so it represents current state.

  The duality is the central idea: aggregating a stream produces a table, and reading a table's changes produces a stream. Choosing correctly is a modelling decision — clicks are a stream and account balances are a table — and modelling one as the other produces either lost updates or double counting. A third form, replicated in full to every instance, exists for lookup data small enough to hold everywhere, which removes the co-partitioning requirement for joins against it.

  </details>

- **MUST** — State stores and changelogs

  <details><summary><strong>Answer</strong></summary>

  Anything stateful — an aggregation, a join, a window — keeps local state in an embedded key-value store on the instance's disk, which is what makes lookups fast and avoids a network call per record. That local state is backed by a compacted **changelog topic** in Kafka, written as the state changes.

  So durability comes from Kafka rather than from the local disk: an instance that dies takes its state with it, and its replacement rebuilds by replaying the changelog. **The cost is** that restore time is proportional to state size, so a large store means a slow recovery, which is what standby replicas exist to avoid — they keep a warm copy on another instance so a failover is fast. Volunteering restore time as the operational risk is what shows this has been run rather than read.

  </details>

- **MUST** — Repartitioning and co-partitioning

  <details><summary><strong>Answer</strong></summary>

  Local state only works if every record for a key reaches the same task, so changing a record's key before a stateful operation forces the data to be redistributed — written to an internal repartition topic and read back. That is a full round trip through the cluster hidden behind an innocuous-looking key change, and it is the usual explanation for a topology that is far slower than expected.

  Joining two streams requires them to be **co-partitioned**: same partition count, same key, same partitioning strategy. If they are not, one side is repartitioned first, or the join fails to produce matches that clearly should exist — which is a genuinely confusing bug and a good thing to have met once.

  </details>

- **MUST** — Time, windows and late data

  <details><summary><strong>Answer</strong></summary>

  Operations are by default driven by **event time**, taken from the record's timestamp, rather than by when processing happened — which is what makes results reproducible on replay. Windows come in tumbling, hopping, sliding and session forms, and each carries a grace period saying how long after a window closes a late record is still accepted.

  Two facts do the real work. Stream time advances only as records are observed, so a quiet partition holds the whole application's notion of time back and windows do not close; and a record later than the grace period is dropped, which is a deliberate, configurable data loss that needs to be a conscious choice. Naming the grace period as the correctness against latency knob is the substance of this answer.

  </details>

- **NICE** — Scaling and parallelism

  <details><summary><strong>Answer</strong></summary>

  **Parallelism** is the partition count of the input topics: the topology is split into tasks, one per input partition, and tasks are distributed across instances and threads exactly as partitions are distributed across a consumer group. Adding instances beyond the partition count adds nothing, which is the same ceiling as every other Kafka consumer.

  Rebalances therefore move state, not just assignment, so scaling a stateful application is more disruptive than scaling a stateless consumer — another reason standby replicas and a sensible partition count matter more here than elsewhere.

  </details>

- **NICE** — When it is the right tool

  <details><summary><strong>Answer</strong></summary>

  It fits when the work is genuinely stream shaped — enrichment by joining a stream to a table, windowed aggregation, deduplication, materialising a view — and the team already deploys services. It does not fit when the processing is a simple map best written as a consumer, when the language is not on the Java virtual machine, when state is very large, or when the requirement is really batch analytics over history, which belongs in a warehouse.

  A cluster-based processor is the alternative to name for large state and cross-language teams, and a query layer over streams is the alternative for teams that want declarative topologies without writing an application at all.

  </details>

- **OPTIONAL** — Interactive queries

  <details><summary><strong>Answer</strong></summary>

  Because state lives locally, an application can serve reads directly from its own store instead of writing results out to a database first — with the caveat that each instance holds only the keys for its assigned partitions, so a request must be routed to whichever instance owns the key, and the library exposes the metadata needed to do that routing.

  It removes a whole external store for some designs and adds a routing layer and a state-availability concern for others. It is worth knowing about and worth adopting deliberately rather than by default.

  </details>
