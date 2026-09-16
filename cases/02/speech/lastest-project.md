# Latest Project — Personalized Cancer Support Platform

**Table of Contents**

- [Latest Project — Personalized Cancer Support Platform](#latest-project--personalized-cancer-support-platform)
  - [My Role](#my-role)
  - [The Product](#the-product)
  - [The Shape of the System](#the-shape-of-the-system)
  - [The Data Layer](#the-data-layer)
  - [Identity and Access Layer](#identity-and-access-layer)
  - [How Services Talk, and How They Stay Consistent](#how-services-talk-and-how-they-stay-consistent)
  - [The AI Part](#the-ai-part)
  - [Close](#close)

---

## My Role

What my role implied in brief: I was a backend engineer on the core platform. I owned the data and search layer, the identity and provisioning APIs, I contributed to the event-driven paths, and the pipeline.

## The Product

Let me start with what the product does to give you a common idea. Then I'll go through the architecture. And in each part, I'll point out which piece was mine.

It's a support platform for people diagnosed with cancer and for the clinicians who look after them.<br>
_A patient_ logs how they feel every day, reads guidance written for their exact diagnosis and treatment, and keeps appointments, prescriptions and scans in one place. _The care team_ sees the same record.<br>
**So, the problem this platform solves is** that before this, all of that was in paper packs, email threads and phone calls.

So, technically there is **one record that has two audiences (patients and clinicians), and their access rules are opposite**:
- _A patient_ sees everything about themselves and nothing about anyone else.<br>
- _A clinician_ sees a small part of many patients' records, and only while they are on that patient's care team.<br>

Those opposite rules actually shaped most of the design.

## The Shape of the System

The system was designed to handle 25 thousand patients a day, which is about 200 requests a second at peak. So, as you can see, the request rate was low.
But the tables were not small — for instance, `check-ins` is over forty-five million rows.

And what influenced the architecture most are basically 2 things: the rate is low, but the rules are strict.<br>
That's the whole reason this isn't twenty microservices.

<details>
<summary><strong>One of the main things I was responsible for was designing a modular monolith and extracting microservices.</strong></summary>

The core is a modular monolith in FastAPI, which is shipped as one deployable unit with four modules<span style="color:gray"> — patient diary, clinical records, clinical content and identity</span>. Each module has its own database schema, so the boundary in the code is also a boundary in the database.<br>
For decoupling modules don't import each other, they rather call a published interface. <span style="color:gray">The published interface makes the module boundaries real. They are just not network boundaries.</span>

I designed that split. And also two parts moved out as separate microservices, each with its own reason:
- **the SCIM provisioning service** <span style="color:gray">(The hospital directory calls the SCIM service to create and disable clinician accounts.)</span>, because the hospital decides when it is released <span style="color:gray">(When the hospital changes its directory configuration, that is not a reason to ship the patient portal)</span>,
- and **the clinical NLP service** <span style="color:gray">(Natural Language Processing service for building education pages - writes guidance for a patient's specific diagnosis, treatment line, stage and locale.)</span>, because it needs GPUs and it ships when a new model version is ready, not when the product ships.

So, the rule is:
> **"A service moves out when it has its own reason to be released. It does not move out because the diagram looks cleaner."**

<details>
<summary><strong>What made that boundary real</strong></summary>

The pipeline had **import-linter contracts**. They declared the four modules independent of each other, and they failed the build on any import that crossed a boundary outside the published interface.

An import linter can't see raw SQL. So each module's models were bound to its own schema, and an integration test failed if a module ran SQL against a schema it didn't own.

<span style="color:gray">If you start from a codebase that is already entangled, you do it the other way round. You record today's violations as a baseline, fail the build on every new one, and pay the baseline down. We never needed that, because we started with the gate.</span>

> **"A gate you have never seen go red isn't a gate. So a deliberate cross-module import is one of the pipeline's own test cases."**
</details>

</details>
<br>

<details>
<summary><strong>More details</strong></summary>

<details>
<summary><strong>The trade-off we accepted</strong></summary>

With four modules in one deployable unit, **one person's release blocks someone else's feature**. But we accepted that, because at 200 requests a second, splitting the modules would have given us _distributed transactions without giving extra throughput_.
</details>

<details>
<summary><strong>Each component releases differently</strong></summary>
Each service's release strategy depends on the failure that service has to survive:
- `care-core` uses blue-green with a single Route switch. It holds the clinical record, so it needs the cleanest rollback available.
- `clinical-nlp-svc` uses a canary at 5% → 25% → 100%. This is because a model regression shows up statistically and never in a health check.
- `scim-provisioning-svc` uses a rolling update. It has an external caller and idempotent operations, and it has no part that users see.
</details>

<details>
<summary><strong>What moving the services out did not give us</strong></summary>
`scim-provisioning-svc` also writes to `pg-clinical`. It writes only to the `identity` schema. It writes the `clinician` and `care_team_member` rows, and the `care_relationship` rows that a deprovisioning closes. So the separation is at the deployment level, not the data level. The service releases on its own cadence. But it cannot change those tables without considering `care-core`. Schema ownership is what keeps this under control. If someone proposes a second service that writes across schemas, that is the point where this arrangement stops being acceptable.
</details>

<details>
<summary><strong>The honest limit</strong></summary>
The gate is static. It sees imports, not dynamic access — reaching into another module's package by name at run time, or an import built from a string. The schema test covers the SQL route. Nothing covers the dynamic route, and we accepted that, because it takes deliberate effort rather than carelessness. The contracts also police where you cross, not how much you expose. An interface module that grows into a god-object passes every contract, and keeping it thin is still a review judgement. And the database doesn't enforce any of it. `care-core` is one process behind one transaction-mode pooler. Per-module roles would mean per-module engines and pools, and that would give up the single commit across modules, which is the whole reason we stayed in one process.
</details>

<br>
<details>
<summary><strong>If asked: "your CV says three modules"</strong></summary>
Yes, it does: diary, clinical content and identity. Records is the fourth module, and I split it out on purpose. The clinical record has a different write model from authored content. It also has different consistency and audit obligations. If I had put records inside clinical content, a prescription and a leaflet would have gone through the same code path.
</details>
<details>
<summary><strong>If asked: "how would you decompose further?"</strong></summary>
Three seams really justify a split: a different release cadence, different hardware, or a different owner. I'd take them one at a time. I'd move one module out with the strangler pattern (incremental replacing of a legacy monolithic system with new services). I'd use the schema boundary that already exists as the seam. And I'd stop as soon as there is no more reason to split.

> **"If you split by domain nouns, you end up with a distributed monolith."**
</details>

</details>

## The Data Layer

The Data Layer has five stores, and each one has exactly one job: **Postgres holds the truth. Mongo holds the content. Elasticsearch is a view. Redis is disposable. Blob holds the bytes.**

<details>
<summary><strong>Here I was responsible for designing PostgreSQL schemas and Elasticsearch indexes for clinical content search.</strong></summary>

**Three things are worth naming:**
- Every index exists for one named query in the API. If I can't name the endpoint, we don't create the index.
- The two big tables are `check-ins` and `audit`, and both are partitioned by month. <span style="color:gray">Check-ins is over forty-five million rows.</span>
- The patient timeline is a union across five tables, so the cursor carries a normalised ordering column plus the source table and the row ID. That is what makes it **keyset pagination** and not offset. <span style="color:gray">Offset gets slower the deeper you page, and on a table that size it degrades badly.</span>

> **"That work cut latency for clinical content search by about thirty-five percent."**

<details>
<summary><strong>What each store serves</strong></summary>

- **Postgres** is the system of record: patients, care relationships, appointments, prescriptions, notes, check-ins, consent and audit.
- **Mongo** holds the education content, for two reasons. Every page is versioned, and the page shape changes by cancer type, treatment line and language. <span style="color:gray">In a relational model, this content would need a very wide table that is mostly empty.</span>
- **Elasticsearch** serves search over notes and guidance. It is a projection, so the whole index can be rebuilt from Postgres and Mongo.
- **Redis** holds nothing durable: sessions, caches, rate limits and idempotency keys. Lose it and the record stays right. We get slow, and duplicate suppression drops from a guarantee to an optimisation. Two locks do ride on Redis, though: SCIM ordering and the beat scheduler. Those are the honest exception.
- **Azure Blob Storage** holds the document bytes — scans, letters and the audit archive. By year five, it will hold about twelve terabytes, more than all the other stores put together.
</details>
<br>
<details>
<summary><strong>More details</strong></summary>

<details>
<summary><strong>Why the timeline cursor has three parts</strong></summary>

The five tables each order on a different natural column, and one of those columns is a date, not a timestamp. You can't order that union deterministically, and you can't serve it from one index shape either. So every timeline table has a normalised ordering column. The cursor carries that column, the source table and the row ID, so when rows from different sources tie, the tie breaks the same way every time.
</details>

<details>
<summary><strong>Rules we put in the schema, not in code</strong></summary>

- `wellbeing_checkin` is unique on `(patient_id, recorded_for)`. So an at-least-once redelivery becomes an `INSERT ... ON CONFLICT DO UPDATE`. The application does not have to remove duplicates itself.
- `outbox_event` is written in the same transaction as the business change. It is the only thing that ever writes to `es-clinical` or `sb-integration`.
- `reminder` and `reminder_delivery` are separate tables. One reminder can have many delivery attempts. So "was it delivered" is a query.
- `audit_event` has `UPDATE` and `DELETE` revoked from every application role. It also has a trigger that blocks them.
- `document` holds only metadata. A client cannot see a `document` row until `scan_state = 'clean'`.
- We do not use soft deletion on clinical rows at all, because retention law governs the record. When a patient withdraws consent, the `consent` table restricts further processing. We do not retire their prescriptions.
</details>

<details>
<summary><strong>Where the data is deliberately not in columns</strong></summary>

- `symptom_scores` is `jsonb` with a [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") index. The reason is that the symptom set differs by cancer type and changes with the clinical protocol. With one column per symptom, every protocol change would need a migration. - `external_mrn` is encrypted. It also has an [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") blind index over the normalised value. The key for that index is kept separately in Key Vault. So hospital sync can still find a patient by medical record number. And only the matched row is ever decrypted.
</details>

<details>
<summary><strong>One index per named access pattern</strong></summary>

- Timeline, most recent first: a composite B-tree on `(patient_id, timeline_at DESC)`, on all five tables that feed the timeline.
- Check-ins over a date window: a monthly range partition plus a [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") index on `recorded_at`. On 46 million rows, the physical order matches the insert order. So for the same range scan, BRIN costs a fraction of a B-tree's size.
- Symptom trend: a GIN index on `symptom_scores`.
- "May this clinician see this patient", checked on every clinician request: a GiST index on `care_relationship (patient_id, clinician_id, valid_period)`. The exclusion constraint and the index are the same object. It needs the `btree_gist` extension, because the constraint mixes scalar columns with a range.
- A clinician's patient list: an index on `(care_team_id, patient_id)`, partial on `WHERE upper(valid_period) IS NULL`.
- Due reminders, swept every 60 seconds: a partial B-tree on `(scheduled_for) WHERE state = 'pending'`. This keeps the hot index at the size of the pending set, not the size of all history.
- Outbox relay: a partial B-tree on `(occurred_at) WHERE published_at IS NULL`. This is the relay's only query.
- Audit by subject, for compliance and subject-access requests: a monthly partition plus an index on `(patient_id, occurred_at DESC)`.
</details>

<details>
<summary><strong>Three Elasticsearch indexes behind one alias</strong></summary>

The alias `clinical-search` sits in front of three indexes:
- `es-clinical-notes` holds visit notes. The extraction model enriches them with entities. The index uses the English analyser plus a clinical synonym filter.
- `es-clinical-content` holds approved page versions only.
- `es-clinical-history` holds appointments, prescriptions and document titles. This is the visit-history surface.

Each index has three primary shards and one replica. In total, they hold around 150 GB on three data nodes.
</details>
</details>

</details>
<br>

<details>
<summary><strong>Also I migrated data access to SQLAlchemy 2</strong> and tightened SQL for clinical record queries used on the patient timeline and care-team views</summary>

**Why the 2.x typed API mattered more than the rewrite:**
`pyright --strict` can check SQLAlchemy 2's typed constructs. And `pyright --strict` is a blocking gate in the pipeline. On a clinical record, a wrong join is not a bug. It is a disclosure. So checking the query shape at build time was enough reason for the migration on its own.

<details>
<summary><strong>More details</strong></summary>

<details>
<summary><strong>The timeline query</strong></summary>

It is the clinician query that runs most often in the system. It is a union across five tables. Each table orders on a different natural column: `starts_at`, `prescribed_on`, `encounter_date`, `uploaded_at` and `recorded_at`. `encounter_date` is a `date`, not a timestamp. A `UNION ALL` that mixes a `date` with a `timestamptz` cannot be ordered deterministically. It also cannot be served from one index shape. So every table that feeds the timeline has a `timeline_at timestamptz` column. Each table fills that column from its own natural column. The query orders only on `timeline_at`. The natural columns stay, because `encounter_date` is the clinical fact. `timeline_at` is only a presentation key.
</details>

<details>
<summary><strong>Keyset pagination, with the `LIMIT` in each branch</strong></summary>

The cursor is the tuple `(timeline_at, source_table, id)`. So ties across sources break the same way every time. Each branch of the union has its own window and its own `LIMIT`. So Postgres reads at most `limit` rows from each source. It does not materialise and sort the entire union and then discard most of it. Offset pagination on this query is not allowed at all. The composite indexes exist exactly to avoid it.
</details>
</details>

</details>

## Identity and Access Layer

As for Identity and Access Layer - I'd call this the heart of the system.

<details>
<summary><strong>I implemented REST APIs with SCIM 2.0 and Azure Entra ID JWT for clinician and care-team accounts</strong></summary>

There are 2 identity planes:
- Patients sign up by themselves.
- Clinicians never sign up — they are provisioned from the hospital's Entra ID directory over SCIM 2.0.
<br>The two planes get different token audiences, and the gateway checks the audience against the route.

Then authorization:
- Roles say what you may *do*: write a visit note, approve content, manage a care team.
- But *which rows you may reach* is not a role. It is a fact that changes over time, so it is resolved per request, below the application. The mechanism in our case was Postgres RLS (row-level security). It allowes to prevent sensitive data leakage introduced via bug - **If developer forgets to scope a query, it returns nothing. It doesn't return someone else's record.**

What the SCIM side is about:
When the hospital disables a clinician, we close every open care relationship in the same transaction. So, **access ends when employment ends**, and there is no step on our side that anyone could forget.

**How the check is wired.** Every request sets the actor inside the transaction, and the policies join through the care relationship, which is stored as a time range with a start and an end.
Resolving reach below the application is what turns the most common application bug into an empty result rather than a data breach. The application checks still exist. They are just a second layer.

<details>
<summary><strong>More details</strong></summary>

<details>
<summary><strong>Token mechanics</strong></summary>

> **"The gateway rejects a patient token on a clinician endpoint. The token never reaches the code."**

We use the OAuth 2.0 authorization code flow with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), and [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") for identity. Access tokens last 15 minutes. Refresh tokens are rotated and bound to the client. Patients use multi-factor authentication at enrolment and on sensitive operations. On the clinician side, the hospital's own conditional access applies. The platform uses that conditional access as it is and does not weaken it.

</details>

<details>
<summary><strong>The SCIM surface, and who is allowed to call it</strong></summary>

`scim-provisioning-svc` implements `Users` and `Groups` with the standard verbs:
- `GET|POST /scim/v2/Users`
- `GET|PATCH|DELETE /scim/v2/Users/{id}`
- the same endpoints for `Groups`
- `GET /scim/v2/ServiceProviderConfig`, so Entra can discover what is supported instead of assuming it

Entra ID is the only authorized caller. Entra ID calls with its own client credential. Network access to this service is restricted. Nobody can reach it through the patient plane.
</details>

<details>
<summary><strong>What a directory operation does on our side</strong></summary>

Create and update map to `clinician` and `care_team_member` rows. `active: false` is the operation that matters. It closes every open `care_relationship` for that clinician in the same transaction. Access ends when employment ends. There is no step on the platform side, so nobody can forget that step. Concurrent operations on one directory object run one at a time. They use a short-lived Redis lock keyed by the Entra object ID.
</details>

<details>
<summary><strong>A failed sync is a security event, not a background-job failure</strong></summary>

SCIM sync failures are paged. This is because a deprovisioning that did not complete means some access should have ended, but it has not. It is the one alert in the set where the *absence* of a change is the incident.
</details>

<details>
<summary><strong>Two audiences, checked before any code runs</strong></summary>

Patients authenticate in the patient tenant and receive `api://care-platform/patient`. Clinicians authenticate in the hospital tenant and receive `api://care-platform/clinician`. [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway") first validates the signature against the cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"). Then it checks the issuer, the expiry, and the audience against the route's plane. So the gateway rejects a clinician token on a diary endpoint with `403`. `care-core` validates the token again. It does not trust a header that the gateway set. So if someone bypasses APIM, they still do not bypass authentication.
</details>

</details>

</details>

## How Services Talk, and How They Stay Consistent

For inter-service communication we have five transports, and each one has a stated job, so nobody has to guess which one to use:
- **Synchronous REST** is for anything a user is waiting for. <span style="color:gray">A screen that someone is looking at should not be eventually consistent.</span>
- **Celery** is for work we own and must retry. <span style="color:gray">For example: reminder sweeps, page generation and indexing.</span>
- **A RabbitMQ topic exchange** is for domain facts. <span style="color:gray">For example: check-in recorded, note created, appointment scheduled.</span>
- **MQTT** is for check-ins from the phone.
- **Azure Service Bus** is at the edge, where work goes to somewhere else.<span style="color:gray"> At this edge, reminder delivery goes out and document ingest comes in. The Functions sit at that edge.</span>

<details>
<summary><strong>Implemented event-driven FastAPI services with RabbitMQ AMQP and MQTT</strong></summary>

I spent most of my design time on consistency.
Three rules:
- **Nothing writes to Elasticsearch directly.** Every write commits to Postgres with an outbox row in the same transaction, and a relay publishes that row. The honest cost is about eight seconds before a new note is searchable.
- **The schema handles duplicates, not the code.** A redelivered check-in hits a unique key on patient and date, so it becomes an update instead of a second row.
- **The state machine is in the database, not in the queue.** Every reminder is a row with a state, and every attempt is its own row. A worker claims what is due with `FOR UPDATE SKIP LOCKED`, so workers scale out without dispatching the same reminder twice.

> **"If the queue is down, reminders are late. They are never lost."**

That third rule is what cut missed reminders by over twenty percent.

<br>
<details>
<summary><strong>More details</strong></summary>

**Why MQTT for check-ins.** A patient is often in a hospital basement or on a bad connection. With MQTT, the phone queues the check-in locally and delivers it when the phone reconnects. MQTT runs on the same RabbitMQ broker, so an MQTT check-in arrives on the same exchange that everything else consumes.

**How documents get in.** I moved that path from ad-hoc folders to Azure. A scan or a letter never goes through the API. The client gets a short-lived signed URL and uploads straight to Blob Storage, so multi-megabyte files never touch the pods that serve a clinician's timeline. The upload goes into a quarantine container. A blob-created event triggers a Function that scans the file and extracts its text. We promote the file and make the document row visible only after that.

> **"No record row ever points to an unscanned file."**

**Transport security.** We use [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") everywhere. No data store has a public endpoint. The one cross-cluster hop carries clinical free text, and it runs on mutual TLS. And the MQTT listener lets a device publish only to the topic that matches its own token.

**The outbox.** A new note becomes searchable in about eight seconds, or fifteen seconds at p95. With an outbox, the backlog is a metric, and it clears by itself.

**The duplicate rule.** A unique key turns at-least-once delivery into a predictable outcome instead of a bug.

**The reminder path, end to end.** The worker writes the attempt row, then hands the delivery to Service Bus, where a Function does the actual send and posts the provider's receipt back. So "was it delivered?" is a query, not a guess. And a final failure escalates to the care team, instead of ending as a log line. Before this, reminders went out inline during a request, so if the request failed the reminder failed with it, and nothing recorded that it never arrived.

**What goes on the exchange.** `care.events` is a topic exchange that carries domain facts: `checkin.recorded`, `visitnote.created`, `appointment.scheduled` and `carerelationship.changed`. Publishing a fact does not give the publisher the right to know who consumes it. That is why these facts are not Celery tasks. A task registry couples every consumer to the publisher's deployment.

**What goes on Celery.** There are three queues, and each one has its own concern:
- `celery.reminders` is for the beat-driven sweep.
- `celery.content` is for page generation.
- `celery.index` is for the outbox projection into `es-clinical` and for reindexes.

This is work the platform owns. It has owners, deadlines and retry policies. That fits Celery's model, not the model of a fire-and-forget event.

**The check-in path, and the broker details it depends on.** The phone publishes to `care/checkin/{patient_id}` at [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") 1. The broker acknowledges once the message is durable on a quorum queue. From that moment, the recovery point is zero, and the UI can honestly say "recorded".
That claim depends on two settings that are not defaults, and on one fixed translation:
- `mqtt.exchange` has to point at `care.events`. Otherwise, the plugin publishes to `amq.topic`.
- MQTT's `/` separator always becomes [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications")'s `.`. So the topic binds as `care.checkin.{patient_id}`.
- `care.events` needs an alternate exchange. This is because RabbitMQ returns a [PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message") for a QoS 1 publish that routes to no queue at all.

**Quorum queues, because there is no longer an alternative.** RabbitMQ 4 removed classic mirrored queues. So every queue bound to `care.events`, and every Celery queue, is a quorum queue on a three-node cluster. Publisher confirms are mandatory. The broker acknowledges a message routed to a quorum queue only after a majority of its replicas has it.

**Where the 22% comes from. It is not the queue.** The state machine is in `pg-clinical`, not in the transport. The 22% comes from that. The baseline it is measured against is the old path: reminders went out inline during a request, so if the request failed the reminder failed with it, and nothing recorded that it never arrived.

1. Every reminder is a row with a state.
2. Beat ticks every 60 seconds.
3. A worker uses `FOR UPDATE SKIP LOCKED` to claim what is due. So workers scale out without dispatching the same reminder twice.
4. Each attempt is its own `reminder_delivery` row. The row carries the channel, the provider message ID and a terminal state.
5. The delivery itself crosses to `sb.notify`. There, `fn-notify-dispatch` sends it and posts the provider's receipt back.

A terminal failure escalates to the care team instead of ending as a log line. "How many reminders were missed" is a query, not a log grep. That is what makes the number reportable at all.

**The scheduler is a singleton, and the design survives that.** Celery beat runs as a single replica. It holds a Redis-backed RedBeat lock, so a restart cannot schedule the same work twice. A liveness probe checks the age of the last tick. If beat stops, reminder rows stay `pending`. The next sweep catches up, so reminders are late, not lost. An alert on `reminder_dispatch_lateness_seconds` at p99 fires long before a patient would notice.

**The honest limits. There are two real ones.** First, Celery's support for quorum queues is recent. It interacts with `task_acks_late`, global QoS and priority. We have to pin that combination and test it against the broker version. That has to happen before we commit the reminder path to Celery on quorum queues. The fallback is raw AMQP consumers for `celery.reminders`, and the topic-exchange design already supports that fallback. The second limit is accepted, not fixed. If a receipt is lost after delivery, a reminder can go out twice. For a patient, seeing a reminder twice is a much better failure than not seeing it.

</details>
</details>

<details>
<summary>Migrated file ingestion and async notifications to Azure Blob Storage, Service Bus, and Event Grid so scans, letters, and follow-up messages no longer sat in ad-hoc folders</summary>

<details>
<summary><strong>Details</strong></summary>

**The upload never touches the API.** `POST /api/v1/documents:upload-intent` returns a `document_id` and a short-lived signed URL. The client sends the bytes straight into the `ingest-quarantine` container. If `care-core` proxied multi-megabyte scans, the scans would be on the same pods that serve a clinician's timeline. The signed URL sends the bytes somewhere else. But the metadata write stays transactional.

**From quarantine to visible.** A `BlobCreated` event on `evtgrid-blob` triggers `fn-blob-ingest`. That Function validates the file, scans it and extracts its text. The blob is promoted into the `documents` container only if the result is clean. Then the row's `scan_state` is set to `clean`. No client can see the row before that. No record row ever points to an unscanned file.

**The layout is by container, and each container has its own lifecycle rule:**
- `documents` uses the path `{patient_id}/{document_id}/{sha256}`. Files stay hot for 90 days, then cool for a year, then move to archive.
- `ingest-quarantine` uses the path `{upload_id}`. A file is deleted on promotion or after 24 hours, whichever comes first.
- `audit-archive` uses the path `{yyyy}/{mm}/audit-{partition}.parquet.zst`. It has a write-once policy with a seven-year retention period. We keep `audit_event` partitions hot for 13 months. After that, the monthly partitions move to `audit-archive`.

**The notification edge.** `sb.notify` carries the dispatch command. The `reminder_delivery_id` is its idempotency key. `fn-notify-dispatch` delivers by push, email or SMS. Then it puts the provider's receipt back on a queue. Functions fit both edges, because the work comes in bursts, is short, and is triggered by events. Paying for idle pods to wait for an upload would be the wrong fit. Service Bus adds durable dead-lettering exactly where work goes to a third party.

**Security settings on the storage account itself.** The storage account uses a customer-managed key and [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit") only. Public access is disabled. It has zone-redundant replication and soft delete. The audit container has an immutability policy. By year five, the account will hold about twelve terabytes. That is more than all the other stores put together.

**The honest limit.** Running `rmq-core` and `sb-integration` means we operate two brokers. That cost is real. We split the two brokers at the edge where the platform hands work to Azure. That keeps the rule easy to remember. But if we ever drop MQTT ingress, this choice is the first thing to revisit. At that point, Service Bus could carry all of the messaging. The smaller limit: if Blob is unavailable, document download fails. But the rest of the record still loads. That is because the metadata is in Postgres, and only the bytes are in Blob.
</details>

</details>

</details>

## The AI Part

<details>
<summary><strong>I fine-tuned Hugging Face models with transfer learning techniques and built education pages via LangChain workflows</strong></summary>

One model extracts clinical entities and codes from visit notes. The other model re-ranks guidance passages. LangChain builds the page.

The whole pipeline is built around two approval gates:
- The first gate is on the input. **The model can only use passages that a clinician has already approved.** And every block carries a citation back to the passage it came from. The model selects and rewrites approved material. It doesn't write clinical claims of its own.
- The second gate is on the output. **The pipeline produces a page that is pending review.** A clinical reviewer approves the page before it is ever assigned to a patient. The person who wrote the source can't be the one who approves the page. That is because author and approver are separate roles, on purpose. Otherwise, the second review is not a real check, and the safety property is just a claim.

That makes the pages less fluent. A model that generates freely writes nicer pages. We accepted that cost on purpose.

> **"In cancer guidance, a sentence without a source isn't a quality problem. It's a safety problem."**

Relevance went up twenty-eight percent. That came from re-ranking against the patient's actual diagnosis and treatment line. We re-rank instead of serving one generic leaflet per cancer type.

The whole pipeline runs off the request path, so nobody ever waits on a GPU.

</details>

## Close

So, to sum up: a modular monolith with two services that had a real reason to move out, Postgres enforcing the access rules itself, and everything slow or unreliable on queues, off the request path.
