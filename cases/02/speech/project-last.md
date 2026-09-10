# Latest Project — Personalized Cancer Support Platform

**Table of Contents**

- [The Spine — Ten Lines to Memorise](#the-spine--ten-lines-to-memorise)
- [What the Product Is (~60 s)](#what-the-product-is-60-s)
- [My Role, in One Line](#my-role-in-one-line)
- [The Shape of the System (~90 s)](#the-shape-of-the-system-90-s)
- [The Data Layer (~120 s)](#the-data-layer-120-s)
- [Authentication and Authorization (~150 s)](#authentication-and-authorization-150-s)
- [How Services Talk, and How They Stay Consistent (~180 s)](#how-services-talk-and-how-they-stay-consistent-180-s)
- [Optional — The AI Part (~60 s)](#optional--the-ai-part-60-s)
- [Optional — How It Ships (~40 s)](#optional--how-it-ships-40-s)
- [Optional — Logs, Metrics and Traces (~40 s)](#optional--logs-metrics-and-traces-40-s)
- [If Asked — Two Problems That Cost Us (~80 s)](#if-asked--two-problems-that-cost-us-80-s)
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

### If asked: "your CV says three modules"

It does — diary, clinical content, identity. Records is the fourth, and I split it out deliberately. The clinical record is a different write model, with different consistency and audit obligations from authored content. Folding it into clinical content would have put a prescription and a leaflet behind the same code path.

### The split, and what left

I designed that split, and two things were pulled out into their own services:

- The first is SCIM provisioning — the service the hospital directory calls to create and disable clinician accounts. It left because its release schedule belongs to the hospital, not to us.
- The second is the clinical NLP service. It left because it needs GPUs, and it ships when a new model version is ready, not when the product ships.

> **"A service leaves when it has its own reason to be released. Not because the diagram looks cleaner."**

And the honest trade-off: keeping four modules in one deployable means one person's release blocks someone else's feature. But we accepted that, because, at two hundred requests a second, splitting them would have bought us distributed transactions and more on-call pages, and no extra throughput.

### If asked: "how would you decompose further?"

Three seams that actually justify a split: a different release cadence, different hardware, or a different owner. I'd take them one at a time — strangle one module out, keep the schema boundary that's already there as the seam, and stop as soon as the reason runs out.

> **"Splitting by domain nouns is how you end up with a distributed monolith."**

<details>
<summary><strong>Responsibilities</strong></summary>

- Designed a FastAPI modular monolith with separate patient diary, clinical content, and identity modules, and extracted microservices for SCIM provisioning and clinical NLP so those releases no longer blocked the rest of the product

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

- Designed PostgreSQL schemas and Elasticsearch indexes for clinical content search so patients and clinicians could find notes, guidance, and visit history without scanning the full record, cutting query latency by 35%
- Migrated data access to SQLAlchemy 2 and tightened SQL for clinical record queries used on the patient timeline and care-team views

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

- Implemented REST APIs with SCIM 2.0 and Azure Entra ID JWT so clinician and care-team accounts stay provisioned from the hospital directory and stay off the patient portal

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

- Implemented event-driven FastAPI services with RabbitMQ AMQP and MQTT to take wellbeing check-ins and appointment reminders off the request path, cutting missed reminders by 22%
- Migrated file ingestion and async notifications to Azure Blob Storage, Service Bus, and Event Grid so scans, letters, and follow-up messages no longer sat in ad-hoc folders

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

- Fine-tuned Hugging Face models with transfer learning and built LangChain workflows that turn diagnosis and treatment context into education pages patients actually read, raising relevance scores by 28%

</details>

## Optional — How It Ships (~40 s)

GitLab CI, and every gate can genuinely fail the build: ruff, pyright in strict mode, unit and contract tests, integration tests against real containers — real Postgres, real Elasticsearch, real RabbitMQ — then a SonarQube gate.

CI never touches the cluster. Its last act is a commit to the GitOps repo, and ArgoCD syncs that onto OpenShift and AKS.

One thing I'd call out, because it's the piece people skip: every migration is expand-contract. One release adds columns and backfills, a later one removes what's no longer read.

> **"That's what makes blue-green possible. Both versions run against the same schema, so a rollback is reverting a revision — there's no down-migration to get wrong."**

<details>
<summary><strong>Responsibilities</strong></summary>

- Moved core FastAPI services to Python 3.14 with Poetry-managed dependencies so runtime and packages stayed consistent across modules
- Configured GitLab CI with ruff, pyright, and SonarQube gates, automating lint, type checks, and test runs before OpenShift deploys, and fixed failing pipeline and deploy jobs
- Wrote Pytest unit and integration tests for API contracts, identity flows, and clinical content services so SCIM and portal changes did not break patient access
- Deployed releases with ArgoCD to OpenShift and Kubernetes so diary, content, and identity services rolled out on the same GitOps path

</details>

## Optional — Logs, Metrics and Traces (~40 s)

Prometheus for metrics, Elastic APM for traces, Kibana as the single pane. Azure's own logs get shipped into the same Elasticsearch, so we're not reading two half-stories of the same incident.

The piece that makes it actually work is that trace context travels in message headers, not just HTTP headers. So one trace covers the HTTP request, the broker hop, the Celery task and the index write — end to end across the async boundary.

Two rules on logging. No clinical text is ever logged: sensitive fields are marked on the Pydantic model, a formatter drops them, and CI fails the build if a log call passes one.

> **"And audit is a database table, never a log stream. Mix them, and your log retention quietly becomes your audit policy."**

<details>
<summary><strong>Responsibilities</strong></summary>

- Instrumented Elastic APM, Prometheus, and Kibana to track API and consumer latency and error rates on wellbeing and reminder traffic.

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
