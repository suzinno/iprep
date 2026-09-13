# Latest Project — Personalized Cancer Support Platform

**Table of Contents**

- [Latest Project — Personalized Cancer Support Platform](#latest-project--personalized-cancer-support-platform)
  - [The Spine — Ten Lines to Memorise](#the-spine--ten-lines-to-memorise)
  - [What the Product Is (~60 s)](#what-the-product-is-60-s)
  - [My Role, in One Line](#my-role-in-one-line)
  - [The Shape of the System (~90 s)](#the-shape-of-the-system-90-s)
    - [The split, and what left](#the-split-and-what-left)
  - [The Data Layer (~120 s)](#the-data-layer-120-s)
  - [Authentication and Authorization (~150 s)](#authentication-and-authorization-150-s)
  - [How Services Talk, and How They Stay Consistent (~180 s)](#how-services-talk-and-how-they-stay-consistent-180-s)
  - [Optional — The AI Part (~60 s)](#optional--the-ai-part-60-s)
  - [Optional — How It Ships (~40 s)](#optional--how-it-ships-40-s)
  - [Optional — Logs, Metrics and Traces (~40 s)](#optional--logs-metrics-and-traces-40-s)
  - [If Asked — Two Problems That Cost Us (~80 s)](#if-asked--two-problems-that-cost-us-80-s)
    - [Problem one — the acknowledgement that meant nothing](#problem-one--the-acknowledgement-that-meant-nothing)
    - [Problem two — the control that could have inverted](#problem-two--the-control-that-could-have-inverted)
  - [Close (~20 s)](#close-20-s)

---

## The Spine — Ten Lines to Memorise

1. Two audiences, one record, opposite access rules.
2. Small traffic, heavy rules — that's why it isn't twenty services.
3. Modular monolith, four modules. Two services left, each with its own release cadence.
4. Postgres holds the truth. Mongo holds content. Elasticsearch is a view. Redis is disposable. Blob holds the bytes.
5. Indexes for named queries, tables partitioned, timeline keyset not offset. → **35%**
6. Two identity planes. Gateway checks the audience. SCIM provisions and revokes clinicians.
7. Reach lives in the database — row-level security. Forget to scope, get nothing. And every read is audited, so reads run on the primary.
8. Facts on the exchange, jobs on Celery, check-ins over MQTT, delivery over Service Bus.
9. Outbox not dual write. Unique keys absorb duplicates. Reminder state in Postgres. → **22%**
10. Two war stories: the acknowledgement that meant nothing, and the leaking connection.

## What the Product Is (~60 s)

Let me start with what the product does, then go through the architecture, and I'll flag my piece in each part as I go.

It's a support platform for people diagnosed with cancer, and for the clinicians who look after them. A patient logs how they feel every day. They read guidance written for their exact diagnosis and treatment. They keep appointments, prescriptions, visit notes and scans in one place. The care team sees the same record.

**The problem product resolves:** Before this, all of that lived in paper packs, email threads and phone calls.

> **"One record, two audiences — and their access rules are opposite."**

A patient sees everything about themselves and nothing about anyone else. A clinician sees a narrow slice of many patients, and only while they're actually on that patient's care team.

That division actually shaped most of the design.

**One number for scale:** About twenty-five thousand patients a day, roughly two hundred requests a second at peak.

> **"Small traffic, heavy rules. That's the whole reason this isn't twenty microservices."**

## My Role, in One Line

I was a backend engineer on the core platform. I owned the data and search layer, the event-driven paths, the identity and provisioning APIs, the model side of the content pipeline, and the CI/CD pipeline.

## The Shape of the System (~90 s)

The core is a modular monolith in FastAPI. One deployable unit consisting of four modules: patient diary, clinical records, clinical content, and identity.

Each module is its own package with its own database schema. Modules don't import each other directly — they go through a published interface instead. That is what makes the boundaries real. They're just not network boundaries.

<details>
<summary><strong>If asked: "your CV says three modules"</strong></summary>

It does — diary, clinical content, identity. Records is the fourth, and I split it out deliberately. The clinical record is a different write model, with different consistency and audit obligations from authored content. Folding it into clinical content would have put a prescription and a leaflet behind the same code path.

</details>

### The split, and what left

I designed that split, and two things were pulled out into their own services:

- The first is SCIM provisioning — the service the hospital directory calls to create and disable clinician accounts. It left because its release schedule belongs to the hospital, not to us.
- The second is the clinical NLP service. It left because it needs GPUs, and it ships when a new model version is ready, not when the product ships.

> **"A service leaves when it has its own reason to be released. Not because the diagram looks cleaner."**

And the honest trade-off: keeping four modules in one deployable means one person's release blocks someone else's feature. But we accepted that, because, at two hundred requests a second, splitting them would have bought us distributed transactions and more on-call pages, and no extra throughput.

<details>
<summary><strong>If asked: "how would you decompose further?"</strong></summary>

Three seams that actually justify a split: a different release cadence, different hardware, or a different owner. I'd take them one at a time — strangle one module out, keep the schema boundary that's already there as the seam, and stop as soon as the reason runs out.

> **"Splitting by domain nouns is how you end up with a distributed monolith."**

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Designed a FastAPI modular monolith with separate patient diary, clinical content, and identity modules, and extracted microservices for SCIM provisioning and clinical NLP so those releases no longer blocked the rest of the product</summary>

*Why `records` is a fourth module is answered in the "your CV says three modules" note above; this is what the split buys and what it costs.*

**What a module owns.** `diary` — check-in capture, schedules, adherence. `records` — appointments, prescriptions, visit notes, document metadata, timeline assembly. `clinical-content` — page assignment, delivery, read-state. `identity` — patient portal auth, care-relationship authorization, consent. Each is its own Python package and its own PostgreSQL schema — `identity`, `records`, `diary`, `content`, `audit` — so the boundary that exists in the code also exists in the database, rather than decaying into a shared-table free-for-all.

**How they talk.** A module reads its own schema directly and another module's only through a published in-process interface. That keeps the seam real while the call stays a function call: no serialisation, no network failure mode, and the whole request still commits in one transaction. That last property is the thing a split would take away.

**What made each extracted service leave.** `scim-provisioning-svc` releases on the hospital directory's cadence, not ours — when the trust changes its directory configuration, that is not a reason to ship the patient portal. `clinical-nlp-svc` needs a GPU node pool and ships when a model version is ready; it runs on the second cluster, `aks-ml`, which deliberately holds no state so it can be folded back into `aro-primary` if GPU inference ever moves to a managed endpoint.

**Each one releases differently, and the strategy follows the failure it has to survive.** `care-core` is blue-green — a single Route switch, because the service holding the clinical record needs the cleanest rollback available. `clinical-nlp-svc` is canary at 5% → 25% → 100%, because a model regression shows up statistically and never in a health check. `scim-provisioning-svc` is a rolling update: an external caller, idempotent operations, no user-visible surface.

**What the extraction did not buy.** `scim-provisioning-svc` writes `pg-clinical` as well — the `identity` schema only, the `clinician` and `care_team_member` rows and the `care_relationship` rows a deprovisioning closes. So the separation is deployment-level, not data-level: it releases on its own cadence, but it cannot evolve those tables without regard for `care-core`. Schema ownership is what keeps that honest, and a second proposed cross-schema writer is the point at which it stops being tolerable.

**The honest limit.** Nothing mechanical enforces the module boundary. Python has no visibility modifier, and there is no import check in the pipeline that fails the build on a cross-module import — schema ownership plus code review is what holds it. On a codebase this size that is weaker than it sounds, and adding that check is what I would do before splitting anything further.

</details>

</details>

## The Data Layer (~120 s)

There are five stores, and each one has exactly one job:

- **Postgres** is the system of record — patients, care relationships, appointments, prescriptions, notes, check-ins, consent, audit.
- **MongoDB** holds the education content, because every page is versioned and the shape changes by cancer type, treatment line and language. Modelling that relationally would give a very wide, mostly empty table.
- **Elasticsearch** serves search over notes and guidance. It's a projection — we can rebuild the whole index from Postgres and Mongo.
- **Redis** holds nothing durable — sessions, caches, rate limits, idempotency keys. If we lose Redis we get slow, NOT wrong.
- **Azure Blob Storage** holds the document bytes — scans, letters, the audit archive. About twelve terabytes at the five-year mark, which is more than every other store put together.

> **"Postgres holds the truth. Mongo holds the content. Elasticsearch serves as a view. Redis is disposable. Blob holds the bytes."**

I designed the Postgres schemas and the Elasticsearch indexes. And here I think, 4 patterns worth mentioning:

- Schema per module, so a module boundary is also a database boundary.
- The big tables are partitioned by month — check-ins and audit. Check-ins are around a hundred and ten million rows.
- Every index exists for one named query in the API. If I can't name the endpoint, the index doesn't get created.
- The patient timeline is a union across five tables, and each one orders on a different natural column — one of them is a date, not a timestamp. A union across those can't be ordered deterministically and can't be served from one index shape. So every timeline table carries a normalised ordering column, and the cursor is a triple: that column, the source table, the row id. Ties across sources break the same way every time. That's what makes it keyset paginated rather than offset. Offset pagination looks fine in staging and falls over in production.

> **"That work cut query latency by about thirty-five percent — the Postgres side on the timeline and record queries, the Elasticsearch side on search."**

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Designed PostgreSQL schemas and Elasticsearch indexes for clinical content search so patients and clinicians could find notes, guidance, and visit history without scanning the full record, cutting query latency by 35%</summary>

**One owning store per fact.** `pg-clinical` carries the `identity`, `records`, `diary`, `content` and `audit` schemas and is the only store a client read is served from without qualification. `mongo-content` owns the pages and the guidance corpus. `es-clinical` owns nothing at all — it is a projection, fully rebuildable from the other two, which is what makes a complete reindex a routine operation rather than a disaster procedure.

**The table the whole authorization model hangs on.** `care_relationship` is temporal: `valid_period` is a `tstzrange` with a GiST exclusion constraint, so a clinician's access to a patient has a start and an end and history is never overwritten. There is exactly one definition of "may this clinician see this patient", and the row-level security policies join through it.

**Rules pushed into the schema rather than into code.** `wellbeing_checkin` is unique on `(patient_id, recorded_for)`, so at-least-once redelivery lands on an `INSERT ... ON CONFLICT DO UPDATE` instead of application dedupe. `outbox_event` is written in the same transaction as the business change and is the only thing that ever writes to `es-clinical` or `sb-integration`. `reminder` and `reminder_delivery` are separate tables — one reminder, many attempts — so "was it delivered" is a query. `audit_event` has `UPDATE` and `DELETE` revoked from every application role plus a blocking trigger. `document` holds metadata only and is invisible to a client until `scan_state = 'clean'`. And soft deletion is not used on clinical rows at all: retention law governs the record, and withdrawing consent restricts further processing through `consent` rather than tombstoning a prescription.

**Where the shape is deliberately not columns.** `symptom_scores` is `jsonb` with a GIN index, because the symptom set differs by cancer type and evolves with the clinical protocol — a column per symptom is a migration per protocol change. `external_mrn` is encrypted, and carries an HMAC-SHA256 blind index over the normalised value keyed separately in Key Vault, so hospital sync can still find a patient by medical record number and only the matched row is ever decrypted.

**Indexes, one per named access pattern.**

- Timeline, most recent first: composite B-tree `(patient_id, timeline_at DESC)` on all five timeline-feeding tables.
- Check-ins over a date window: monthly range partition plus a BRIN index on `recorded_at`. Physical order matches insert order on 110 million rows, so BRIN costs a fraction of a B-tree for the same range scan.
- Symptom trend: GIN on `symptom_scores`.
- "May this clinician see this patient", evaluated on every clinician request: GiST on `care_relationship (patient_id, clinician_id, valid_period)` — the exclusion constraint and the index are the same object.
- A clinician's patient list: `(care_team_id, patient_id)`, partial on `WHERE upper(valid_period) IS NULL`.
- Due reminders, swept every 60 seconds: partial B-tree on `(scheduled_for) WHERE state = 'pending'`, which keeps the hot index at the size of the pending set rather than all history.
- Outbox relay: partial B-tree on `(occurred_at) WHERE published_at IS NULL` — the relay's only query.
- Audit by subject, for compliance and subject-access requests: monthly partition plus `(patient_id, occurred_at DESC)`.

**Three Elasticsearch indices behind one alias.** `clinical-search` fronts `es-clinical-notes` (visit notes with entity enrichment from the extraction model, English analyser plus a clinical synonym filter), `es-clinical-content` (approved page versions only) and `es-clinical-history` (appointments, prescriptions, document titles — the visit-history surface). Three primary shards and one replica each, around 150 GB in total on three data nodes.

**Scope is an index-level property, not an application convention.** Every document in every index carries `patient_id` and `care_team_ids`, and `care-core` builds every query — no client ever reaches `es-clinical` directly. A search engine that can return a document the record layer would refuse is a disclosure path, so the filter is mandatory rather than customary.

**What actually produced the latency.** Scope and date clauses go in `filter` context, which is cacheable and unscored; only the user's text goes in `must`. So the expensive scoring pass runs on an already-narrowed set instead of the whole index. Bulk indexing flushes at 5 seconds or 1,000 documents, and `refresh_interval` is 5 seconds rather than the 1 second default, which roughly halves segment-merge pressure.

**The honest limit.** Search quality on oncology notes depends on a synonym and abbreviation set — drug brand versus generic names, staging notation — and building and maintaining that is clinical work, not engineering work. It needs a named owner before a latency number can be paired with a relevance claim. The other rough edge is scope change: reassigning a patient to a different care team rewrites `care_team_ids` on that patient's documents, and until `celery.index` finishes that reindex the outgoing team can still match in search. That is precisely why reassignment also closes the `care_relationship` row, which the record layer honours immediately.

</details>

<details>
<summary>Migrated data access to SQLAlchemy 2 and tightened SQL for clinical record queries used on the patient timeline and care-team views</summary>

*The indexes behind these queries are under the previous bullet; this is the query side and the ORM.*

**Why the 2.x typed API mattered more than the rewrite did.** SQLAlchemy 2's typed constructs are checkable by `pyright --strict`, which is a blocking gate in the pipeline. On a clinical record a wrong join is not a bug, it is a disclosure, so having the query shape checked at build time justified the migration on its own.

**The timeline query, which is the most-executed clinician query in the system.** It is a union across five tables that each order on a different natural column — `starts_at`, `prescribed_on`, `encounter_date` (a `date`, not a timestamp), `uploaded_at`, `recorded_at`. A `UNION ALL` mixing a `date` with a `timestamptz` can neither be ordered deterministically nor served from one index shape. So every timeline-feeding table carries `timeline_at timestamptz`, populated from its own natural column, and that is the only column the query orders on. The natural columns stay, because `encounter_date` is the clinical fact and `timeline_at` is only a presentation key.

**Keyset, with the `LIMIT` pushed into each branch.** The cursor is the tuple `(timeline_at, source_table, id)`, so ties across sources break the same way every time. Each branch of the union carries its own window and its own `LIMIT`, so Postgres reads at most `limit` rows per source instead of materialising and sorting the entire union before discarding most of it. Offset pagination on this query is prohibited outright — it is exactly what the composite indexes exist to avoid, and it is the version that looks fine in staging.

**The care-team views.** A clinician's patient list is served from the partial index over open `care_relationship` rows, so the query touches the currently-active set rather than the full history the temporal table keeps. Which patients are reachable is not a `WHERE` clause the query author has to remember — that is row-level security, and it is the subject of the authorization chapter above.

**One constraint row-level security puts on the SQL.** Policies are written so the `patient_id` predicate still reaches the planner. A policy that hides `patient_id` behind an opaque subquery silently turns a pruned index scan into a sweep of every monthly partition of `wellbeing_checkin` and `audit_event` — the query is still correct and quietly becomes unusable. An `EXPLAIN` assertion in CI guards the plan shape instead of trusting review to notice.

**Alembic, and why migrations are a deploy-time concern here.** Migrations run as an ArgoCD PreSync hook under a separate owning role that never serves a request, and they are expand-contract, which is what lets both colours of a blue-green cut-over run against one schema.

**The honest limit.** Every audited read is a write, so none of this runs on a replica — the timeline is served by the primary and the headroom is the primary's headroom. And the targets the design records are p95 under 120 ms cached and under 250 ms cold, with a named index behind every query; what it does not record is the pre-migration baseline those improvements were measured against.

</details>

</details>

## Authentication and Authorization (~150 s)

This is the part I'd call the heart of the system.

There are two identity planes:

- Patients sign up themselves, in their own tenant.
- Clinicians never do — they're provisioned from the hospital's Entra ID directory over SCIM 2.0.

Both use OAuth2 authorization code with PKCE, and access tokens are short-lived.

The two planes get different token audiences, and the gateway checks the audience against the route.

> **"A patient token on a clinician endpoint is rejected before it ever reaches the code."**

Then authorization, which splits in two:

- Roles say what you can *do* — write a visit note, approve content, manage a care team.
- BUT *which patients you can reach* isn't a role. It's a fact that changes with time. So that check lives in the database, as Postgres row-level security (RLS).

Every request sets the actor inside the transaction, and the policies join through the care relationship (which is stored as a time range, with a start and an end).

That's the point of putting it there: it turns the most common application bug into an empty result instead of a data breach. The application checks still exist, they're just the second line.

> **"If I forget to scope a query, it returns nothing. It doesn't return someone else's record."**

And I built the SCIM side, so when the hospital disables a clinician, we close every open care relationship in the same transaction. Access ends when employment ends, with nobody on our side doing anything.

And one consequence of all that I want to state, because it's the least obvious thing in the design. Every read of patient data writes an audit row — including a read served from cache, because a cache hit is still an access. That makes an audited read a write. So it can't be served from a read replica, and it fails when the primary fails.

> **"Read availability is bounded by write availability, and we chose that."**

The alternative was queueing the audit rows so reads survive a failover — and living with an audit trail that has a hole in it. For a health record, the hole is the worse outcome. So we paid for the coupling instead: zone-redundant HA and a sixty-second failover, which fits the availability budget. The replicas exist, they just don't carry audited patient reads — index rebuilds, reporting, backup verification.

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Implemented REST APIs with SCIM 2.0 and Azure Entra ID JWT so clinician and care-team accounts stay provisioned from the hospital directory and stay off the patient portal</summary>

**The SCIM surface, and who is allowed to call it.** `scim-provisioning-svc` implements `Users` and `Groups` with the standard verbs — `GET|POST /scim/v2/Users`, `GET|PATCH|DELETE /scim/v2/Users/{id}`, the `Groups` equivalents, and `GET /scim/v2/ServiceProviderConfig` so Entra can discover what is supported rather than assume it. Entra ID is the only authorised caller: its own client credential, network-restricted, and never reachable through the patient plane.

**What a directory operation does on our side.** Create and update map to `clinician` and `care_team_member` rows. `active: false` is the one that matters — it closes every open `care_relationship` for that clinician in the same transaction. Access ends when employment ends, with no platform-side step and therefore nobody to forget it. Concurrent operations on one directory object serialise on a short-lived Redis lock keyed by the Entra object id.

**A failed sync is a security event, not a background-job failure.** SCIM sync failures are paged, because a deprovisioning that did not land is access that should have ended and has not. It is the one alert in the set where the *absence* of a change is the incident.

**Two audiences, checked before any code runs.** Patients authenticate in the patient tenant and receive `api://care-platform/patient`; clinicians authenticate in the hospital tenant and receive `api://care-platform/clinician`. APIM validates the signature against cached JWKS, then issuer, expiry, and audience against the route's plane — so a clinician token on a diary endpoint is rejected with `403` at the gateway. `care-core` re-validates rather than trusting a header the gateway set, which means bypassing APIM is not bypassing authentication.

**Token mechanics.** OAuth 2.0 authorisation code with PKCE, OIDC for identity, 15-minute access tokens, refresh tokens rotated and bound to the client. Multi-factor at patient enrolment and on sensitive operations; on the clinician side it is the hospital's own conditional access, which the platform consumes and does not weaken.

**The JWKS cache is an availability choice, not a performance one.** Entra's signing keys sit in `redis-cache` for 12 hours and refresh on an unknown `kid`. That long TTL is exactly why an Entra outage leaves existing sessions working and only fails new sign-in.

**The honest limit — two of them.** Deprovisioning closes the care relationships instantly, but a token already issued stays valid until it expires, so there is a 15-minute window where authentication succeeds and every reach check returns nothing. And the check-in transport authenticates per *connection*, not per publish, because RabbitMQ's MQTT plugin has no per-message authentication. A long-lived mobile connection therefore has to carry a maximum lifetime shorter than the refresh window and be forced to re-authenticate — a gap the design flags as needing a prototype against real token lifetimes before that transport is committed to. The transport itself is the next chapter.

</details>

</details>

## How Services Talk, and How They Stay Consistent (~180 s)

Five transports, each with a stated job, so nobody has to guess which one to use.

- **Synchronous REST** for anything a user is waiting for. A screen someone is looking at has no business being eventually consistent.
- **A RabbitMQ topic exchange** for domain facts — check-in recorded, note created, appointment scheduled.
- **Celery** for work we own and must retry — reminder sweeps, page generation, indexing.
- **MQTT** for check-ins from the phone.
- **Azure Service Bus** at the edge where work leaves for somebody else — reminder delivery out, document ingest in. That's what the Functions hang off.

> **"The exchange is for facts we publish. Celery is for work we owe. Service Bus is where work leaves the building. They're not the same thing."**

MQTT is there for a specific reason. A patient is often in a hospital basement or on a bad connection. With MQTT the phone queues the check-in locally and delivers it when it reconnects. And it's the same broker, so an MQTT check-in lands on the same exchange everything else consumes.

Documents work the same way at the other edge, and I moved that path off ad-hoc folders onto Azure. A scan or a letter never goes through the API — the client gets a short-lived signed URL and uploads straight to Blob Storage, so multi-megabyte files never touch the pods serving a clinician's timeline. The upload lands in a quarantine container, a blob-created event triggers a Function that scans and text-extracts it, and only then is the file promoted and the document row made visible.

> **"An unscanned file is never addressable by a record row."**

Consistency is where I spent most of my design time. Three rules:

- **First** — nothing writes to Elasticsearch directly. Every write commits to Postgres with an outbox row in the same transaction, and a relay publishes it. The cost is honest: a new note is searchable in about eight seconds, fifteen at p95. **Reason:** With a dual write, a successful commit plus a failed index leaves you permanently wrong with nothing to detect it. With an outbox, the backlog is a metric and it drains by itself.
- **Second** — duplicates are absorbed by the schema, not by code. A redelivered check-in hits a unique key on patient and date and becomes an update. At-least-once delivery turns into arithmetic instead of a bug.
- **Third** — the state machine lives in the database, not in the queue. Every reminder is a row with a state, and every delivery attempt is its own row. A worker claims what's due with FOR UPDATE SKIP LOCKED so workers scale without double-dispatching, writes the attempt row, then hands the delivery to Service Bus, where a Function does the actual send and posts the provider's receipt back. So "was it delivered" is a query, not a guess, and a final failure escalates to the care team instead of ending in a log line.

> **"If the queue is down, reminders are late. They are never lost."**

The third rule is what cut missed reminders by over twenty percent. Before, reminders went out inline during a request — so if the request died, the reminder died with it, and nothing recorded that it never arrived.

**On the security side of all that:** TLS everywhere, no data store has a public endpoint, the one cross-cluster hop carries clinical free text and runs on mutual TLS, and the MQTT listener only lets a device publish to the topic matching its own token.

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Implemented event-driven FastAPI services with RabbitMQ AMQP and MQTT to take wellbeing check-ins and appointment reminders off the request path, cutting missed reminders by 22%</summary>

**What goes on the exchange.** `care.events` is a topic exchange carrying domain facts — `checkin.recorded`, `visitnote.created`, `appointment.scheduled`, `carerelationship.changed`. Publishing a fact does not entitle the publisher to know who consumes it, which is the reason these are not Celery tasks: a task registry couples every consumer to the publisher's deployment.

**What goes on Celery.** Three queues with three separate concerns — `celery.reminders` for the beat-driven sweep, `celery.content` for page generation, `celery.index` for the outbox projection into `es-clinical` and for reindexes. This is work the platform owns, with owners, deadlines and retry policies, which is Celery's model and not a fire-and-forget event's.

**The check-in path, and the three broker settings it rests on.** The phone publishes to `care/checkin/{patient_id}` at QoS 1 and the broker acknowledges once the message is durable on a quorum queue — from that moment the recovery point is zero and the UI can honestly say "recorded". Three settings carry that claim, and none of them is a default: `mqtt.exchange` has to point at `care.events` or the plugin publishes to `amq.topic` instead; MQTT's `/` separator becomes AMQP's `.`, so the topic binds as `care.checkin.{patient_id}`; and `care.events` needs an alternate exchange, because RabbitMQ returns a PUBACK for a QoS 1 publish that routes to no queue at all. The war story at the end of this document is that third one.

**Quorum queues, because there is no longer an alternative.** RabbitMQ 4 removed classic mirrored queues, so `care.events` and every Celery queue is a quorum queue on a three-node cluster with publisher confirms mandatory. Nothing is acknowledged that is not replicated.

**Where the 22% comes from, and it is not the queue.** It is the state machine living in `pg-clinical` rather than in the transport. Every reminder is a row with a state; beat ticks every 60 seconds; a worker claims what is due with `FOR UPDATE SKIP LOCKED`, so workers scale out without double-dispatching; each attempt is its own `reminder_delivery` row carrying the channel, the provider message id and a terminal state; delivery itself crosses to `sb.notify`, where `fn-notify-dispatch` sends and posts the provider's receipt back. A terminal failure escalates to the care team instead of ending in a log line, and "how many reminders were missed" is a query rather than a log grep — which is what makes the number reportable at all.

**The scheduler is a singleton, and that is survivable by design.** Celery beat runs as a single replica holding a Redis-backed RedBeat lock so a restart cannot double-schedule, with a liveness probe on last-tick age. If it stops, reminder rows stay `pending` and the next sweep catches up: late, not lost. `reminder_dispatch_lateness_seconds` at p99 alerts long before a patient would notice.

**The honest limits, and there are two real ones.** Celery's support for quorum queues is recent and interacts with `task_acks_late`, global QoS and priority; that combination has to be pinned and tested against the broker version before the reminder path is committed to it, and the fallback — raw AMQP consumers for `celery.reminders` — is something the topic-exchange design already accommodates. The second is accepted rather than fixed: if a receipt is lost after delivery, a reminder can go out twice. A patient seeing a reminder twice is a far better failure than not seeing it.

</details>

<details>
<summary>Migrated file ingestion and async notifications to Azure Blob Storage, Service Bus, and Event Grid so scans, letters, and follow-up messages no longer sat in ad-hoc folders</summary>

**The upload never touches the API.** `POST /api/v1/documents:upload-intent` returns a `document_id` and a short-lived signed URL, and the client sends the bytes straight into the `ingest-quarantine` container. Proxying multi-megabyte scans through `care-core` would put them on the same pods serving a clinician's timeline; the signed URL moves the bytes elsewhere while the metadata write stays transactional.

**What happens between quarantine and visible.** A `BlobCreated` event on `evtgrid-blob` triggers `fn-blob-ingest`, which validates, scans and text-extracts. Only on a clean result is the blob promoted into the `documents` container and the row's `scan_state` set to `clean` — and no client can see the row before that. An unscanned file is never addressable by a record row.

**Layout is by container, with a lifecycle rule per container.** `documents` at `{patient_id}/{document_id}/{sha256}`, hot for 90 days, cool for a year, then archive. `ingest-quarantine` at `{upload_id}`, deleted on promotion or after 24 hours, whichever comes first. `audit-archive` at `{yyyy}/{mm}/audit-{partition}.parquet.zst` under a write-once policy and a seven-year legal hold — that is where the monthly `audit_event` partitions go when they age out of the 13 months kept hot.

**The notification edge.** `sb.notify` carries the dispatch command with the `reminder_delivery_id` as its idempotency key; `fn-notify-dispatch` delivers by push, email or SMS and enqueues the provider's receipt back. Functions are the right shape at both edges because the work is bursty, short and event-triggered — paying for idle pods to wait for an upload is the wrong shape — and Service Bus brings durable dead-lettering exactly where work leaves for a third party.

**Posture on the storage account itself.** Customer-managed key, HTTPS only, public access disabled, zone-redundant replication, soft delete, and an immutability policy on the audit container. About twelve terabytes at the five-year mark, which is more than every other store put together.

**The honest limit.** Running `rmq-core` and `sb-integration` means two brokers to operate, and that cost is real. The seam is drawn where the platform hands work to Azure, which keeps the rule memorable, but it is the first thing to revisit if MQTT ingress is ever dropped — at that point Service Bus could carry the whole estate. The smaller one: if Blob is unavailable, document download fails while the rest of the record loads, because the metadata is in Postgres and only the bytes are over there.

</details>

</details>

## Optional — The AI Part (~60 s)

I fine-tuned Hugging Face models with transfer learning — one that pulls clinical entities and codes out of visit notes, one that re-ranks guidance passages. LangChain composes the page.

The constraint that shapes the whole pipeline is two approval gates, not one.

The first is on the input: the model can only draw on passages a clinician has already approved, and every block carries a citation back to the passage it came from. It selects and rewrites approved material. It doesn't author clinical claims.

The second is on the output: what the pipeline produces is a page in pending-review. A clinical reviewer approves it before it's ever assigned to a patient — and whoever authored the source can't be the one who approves it, because those are separate roles on purpose. Otherwise the second pair of eyes is nominal and the safety property is just a claim.

That costs us fluency. A freely generating model writes nicer pages. We took that cost deliberately —

> **"In cancer guidance, an unsourced sentence isn't a quality problem. It's a safety problem."**

Relevance went up twenty-eight percent, and that came from re-ranking against the patient's actual diagnosis and treatment line, instead of serving one generic leaflet per cancer type.

The whole pipeline runs off the request path, so nobody ever waits on a GPU.

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Fine-tuned Hugging Face models with transfer learning and built LangChain workflows that turn diagnosis and treatment context into education pages patients actually read, raising relevance scores by 28%</summary>

**Two models, two jobs.** One extracts clinical entities and codes from visit notes; its output lands in `nlp_extractions` and enriches the notes index. The other reranks candidate guidance passages during retrieval. The 28% is attributable to the two together — reranking approved passages against the patient's actual diagnosis, treatment line and stage, instead of serving one generic leaflet per cancer type.

**What LangChain composes, and out of what.** Retrieval pulls `guidance_sources` passages that a clinician authored or curated and that have not been retired; the reranker orders them; composition writes a `content_pages` version in which every block carries a citation back to the passage it came from. The model selects, ranks and rewrites approved material. It does not author clinical claims.

**Two gates, not one.** The input gate is the approved corpus. The output gate is `review_state` — a page is written as `pending_review`, and a clinical reviewer has to approve it before `content_assignment` pins a patient to an exact `(page_id, page_version)`. The version pinning matters because the text a patient was shown is the record of the advice they were given; a later revision must never silently change it. And `content_author` and `content_approver` are separate roles on purpose: if one person could author and approve, the second pair of eyes is nominal and the safety property is a claim rather than a control.

**What the model is allowed to see.** Composition calls carry diagnosis code, treatment line, stage and locale — not identity, not name, not contact details. Extraction calls that must see note text get the text and a correlation id, never the patient identifier. The weights are self-hosted so patient text stays inside the tenancy and no third-party model API is involved, and the one hop carrying clinical free text — `care-core` to `clinical-nlp-svc`, across the peering into the other cluster — runs on mutual TLS with certificates issued and rotated by cert-manager, since the platform's built-in service certificates do not span clusters.

**None of it is on the request path.** Generation is enqueued on `celery.content` against a p95 budget of 45 seconds; extraction runs inside a background task against a bounded two-second deadline. If the GPU pool is unavailable, new generation pauses and queues while already-approved assigned pages serve normally.

**A model version is a rollback unit.** Every artifact is stamped with the model version, every version is evaluated against a held-out clinical set, and `clinical-nlp-svc` rolls out by canary with confidence and latency compared at each step — because a model regression shows up statistically, not in a health check. `nlp_extractions` contains nothing absent from the source note, so reverting a bad model version is a reindex rather than a migration.

**The honest limit.** The fine-tuning itself is the unresolved part. Transfer learning on real visit notes means patient text in a training corpus, and whether that is lawful processing, what de-identification standard applies, and whether the resulting weights can leak training text all need a completed impact assessment before the first tuning run, not a retrospective one — it is the highest-risk processing in the system. The smaller and deliberately accepted cost is fluency: constraining generation to approved passages measurably narrows what a page can say, and that is the intended outcome.

</details>

</details>

## Optional — How It Ships (~40 s)

GitLab CI, and every gate can genuinely fail the build: ruff, pyright in strict mode, unit and contract tests, integration tests against real containers — real Postgres, real Elasticsearch, real RabbitMQ — then a SonarQube gate.

CI never touches the cluster. Its last act is a commit to the GitOps repo, and ArgoCD syncs that onto OpenShift and AKS.

One thing I'd call out, because it's the piece people skip: every migration is expand-contract. One release adds columns and backfills, a later one removes what's no longer read.

> **"That's what makes blue-green possible. Both versions run against the same schema, so a rollback is reverting a revision — there's no down-migration to get wrong."**

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Moved core FastAPI services to Python 3.14 with Poetry-managed dependencies so runtime and packages stayed consistent across modules</summary>

**What the lock actually covers.** One Poetry lockfile per service — `care-core`, `scim-provisioning-svc`, `clinical-nlp-svc` — resolved once and installed identically in CI and in the image, with the interpreter version pinned the same way across all three. The drift this removes was a deploy-time surprise: a dependency that resolved one way in the pipeline and another way on a developer's machine, discovered in the cluster.

**The pinning does not stop at Python.** Images are built from pinned digests and scanned at build time, and ArgoCD deploys only digest-pinned images from the registry — so a mutable tag cannot be swapped underneath a running cluster between a sync and the next one.

**The honest limit.** Three lockfiles is three things that can diverge. The design states that versions are pinned identically across services; it names no check that fails the build when they stop being identical, so that consistency is currently a convention held by review rather than a gate.

</details>

<details>
<summary>Configured GitLab CI with ruff, pyright, and SonarQube gates, automating lint, type checks, and test runs before OpenShift deploys, and fixed failing pipeline and deploy jobs</summary>

**The chain, and every link can genuinely fail the build.** `ruff` on lint, then `pyright --strict` on types, then Pytest unit and contract suites, then Pytest integration against real `pg-clinical`, `mongo-content`, `es-clinical`, `redis-cache` and `rmq-core` containers on Docker Compose, then the SonarQube quality gate on coverage and new-code quality, then a Docker build with an image scan and a digest-pinned push. Integration runs against the real brokers and the real search engine because a mocked broker cannot fail the way a real one does.

**CI never touches the cluster.** No pipeline job holds cluster credentials. The pipeline's last act is committing the image digest to the GitOps manifest repository, and ArgoCD reconciles from there — which is also why a rollback is a Git operation rather than a deploy.

**Four of the gates are security controls wearing a quality gate's clothes.** A check fails the build if a log call passes a Pydantic model carrying a field marked sensitive. A role-privilege assertion fails if the application's database role is superuser or holds `BYPASSRLS`. A pooled-connection test pushes two different actors through one pooled backend and asserts the second cannot see the first one's rows. And an `EXPLAIN` assertion fails if a row-level security policy has stopped the `patient_id` predicate reaching the planner, which is how partition pruning disappears without anything looking broken.

**The honest limit.** Running the real broker in CI is not the same as having settled the flagged question about Celery on quorum queues — that needs a pinned-version test of `task_acks_late`, global QoS and priority against the broker, and the pipeline as designed does not assert it yet.

</details>

<details>
<summary>Wrote Pytest unit and integration tests for API contracts, identity flows, and clinical content services so SCIM and portal changes did not break patient access</summary>

**The contract is an artifact, not a document.** Pydantic models define every request and response body, FastAPI emits the OpenAPI document from them, and the contract suite tests against that document. A breaking change to a response shape fails the pipeline rather than a client.

**What the suites cover, chosen by consequence.** The identity flows: audience separation between the two planes, SCIM create and update, and `active: false` closing the care relationships it has to close. The clinical content services: `review_state` transitions, and the rule that only an approved version can ever be assigned to a patient. The record paths: the timeline union, its cursor, and the scoping behaviour. These are the paths where a regression either removes a patient's access or hands them someone else's.

**Integration means the real dependencies.** The Compose stack developers run locally is the same one the integration stage runs against, which is what makes the database-level assertions possible at all — row-level security behaviour cannot be tested against a fake.

**The honest limit.** The pooled-connection leakage test is only meaningful against the transaction-mode pooler production runs behind, and the Compose stack the design lists names Postgres, not the pooler. That is exactly the gap that makes a control look tested when it is not, and it is the piece of the test suite I would want proven before trusting it. Beyond SonarQube's gate on new code, no coverage figure is claimed — the useful statement is which paths are covered and why, not a percentage.

</details>

<details>
<summary>Deployed releases with ArgoCD to OpenShift and Kubernetes so diary, content, and identity services rolled out on the same GitOps path</summary>

**One declared desired state, two clusters.** ArgoCD syncs `aro-primary` — `care-core`, `scim-provisioning-svc`, `celery-worker`, `rmq-core`, `mongo-content`, `es-clinical` — and `aks-ml`, which carries `clinical-nlp-svc` and nothing else. There are no cluster-side imperative deploys, so "what is running" is a question the Git history answers rather than the cluster.

**Migrations run as a PreSync hook.** `alembic upgrade head` runs before the new revision's pods appear, under an owning role separate from the one that serves requests.

**Expand-contract is what makes the rollback trivial.** One release adds columns and backfills; a later one removes what is no longer read. Because every migration is backwards-compatible with the previous image, both colours run against the same schema through a blue-green cut-over, and a rollback is reverting an ArgoCD revision — there is no down-migration to get wrong. A migration that cannot be written that way gets split across two releases instead.

**Infrastructure takes the same path.** Terraform provisions all Azure and cluster resources with state in Azure Storage, applied from CI behind a plan-review gate on production. A resource created by hand is drift, and drift is reported as a failure rather than quietly reconciled.

**The honest limit.** Two clusters is the most expensive choice in the design, and it is justified only by GPU node-pool management and the independent NLP release cadence. It is kept collapsible on purpose — `aks-ml` holds no state — so if GPU inference ever moves to a managed endpoint, the right move is folding it back into `aro-primary` rather than continuing to pay for it.

</details>

</details>

## Optional — Logs, Metrics and Traces (~40 s)

Prometheus for metrics, Elastic APM for traces, Kibana as the single pane. Azure's own logs get shipped into the same Elasticsearch, so we're not reading two half-stories of the same incident.

The piece that makes it actually work is that trace context travels in message headers, not just HTTP headers. So one trace covers the HTTP request, the broker hop, the Celery task and the index write — end to end across the async boundary.

Two rules on logging. No clinical text is ever logged: sensitive fields are marked on the Pydantic model, a formatter drops them, and CI fails the build if a log call passes one.

> **"And audit is a database table, never a log stream. Mix them, and your log retention quietly becomes your audit policy."**

<details>
<summary><strong>Responsibilities</strong></summary>

<details>
<summary>Instrumented Elastic APM, Prometheus, and Kibana to track API and consumer latency and error rates on wellbeing and reminder traffic.</summary>

**The join is the whole trick.** There are two telemetry planes — the clusters, and the Azure-native services — and they are joined rather than left side by side. `traceparent` propagates on every hop including AMQP, MQTT and Service Bus message headers, and Azure Monitor's diagnostic logs from the gateway, Functions, Service Bus and Blob are shipped into the same Elasticsearch. So one trace covers the HTTP request, the broker hop, the Celery task and the index write, and Kibana is a single pane. Without that join, a reminder that fails between `celery.reminders` and `fn-notify-dispatch` is two unconnected half-stories.

**The consumer-side indicators, which are what this bullet is actually about.** `consumer_task_duration_seconds` p95 by queue, alerting above 5 seconds on `celery.reminders` or `celery.index`; `consumer_task_failed_total` over `consumer_task_total` by queue, alerting above 1% over 15 minutes; broker queue depth and unacked counts. On the reminder path specifically, `reminder_dispatch_lateness_seconds` at p99 and `reminder_delivery_total{state}` — that second one is what turns "missed reminders" into a number. On the API side, `http_request_duration_seconds` p95 by route and the 5xx rate on mutating routes.

**Sampling is weighted by what is worth reconstructing.** All errors and all reminder and NLP traffic; 10% of routine reads.

**Two rules about logs.** No clinical free text, no symptom values and no document contents are ever logged — a Pydantic-driven redaction filter drops fields marked sensitive at the formatter, and CI fails the build if a log call passes one. And audit is a database table, never a log stream: logs are for operators, audit is for the regulator, and conflating them means log retention policy quietly becomes audit policy.

**The honest limit.** Trace continuity through MQTT is unresolved. MQTT 3.1.1 has no user-property header to carry `traceparent`, so either the check-in clients move to MQTT 5 or the context travels inside the payload envelope — and that has to be decided before instrumenting, because retrofitting it breaks every published client.

</details>

</details>

## If Asked — Two Problems That Cost Us (~80 s)

### Problem one — the acknowledgement that meant nothing

The check-in path promises no data loss. The phone publishes, gets an acknowledgement back, and the screen says "recorded".

We found that the broker returns that acknowledgement even when the message routes to no queue at all. So an unbound topic gets acknowledged to the device and then silently dropped — which is exactly the loss the path existed to prevent.

The fix was small: an alternate exchange, so an unroutable message becomes a visible dead letter instead of nothing. We also had to point the MQTT plugin at our exchange explicitly, because it defaults somewhere else.

> **"The lesson: an acknowledgement is a promise from one component, not from the system."**

Now I test the unhappy path inside the transport itself, not only in the application.

### Problem two — the control that could have inverted

Row-level security depends on setting the current actor on the connection. But we run Postgres behind a transaction-mode pooler, which reuses backend connections between requests. Set that value the normal way and it survives the request and leaks into the next caller's query.

> **"The strongest control in the system would have become the worst bug in the system."**

The code fix is one word — scope it to the transaction. But the real fix was the test: two different users pushed through one pooled connection, asserting the second can't see the first one's rows. Plus a CI check that the application's database role can't bypass row-level security at all.

> **"The lesson: a security control you haven't tested under real connection handling isn't a control. It's an intention."**

## Close (~20 s)

So, in one line: a modular monolith with two services that had a real reason to leave, Postgres as the source of truth with the access rules enforced inside it, and everything slow or unreliable pushed off the request path onto queues.

My part was the data and search layer, the event-driven paths, the identity and provisioning APIs, and the pipeline that ships all of it.

I'm happy to go deeper anywhere.
