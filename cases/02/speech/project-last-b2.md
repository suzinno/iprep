# Latest Project — Personalized Cancer Support Platform

**Table of Contents**

- [Latest Project — Personalized Cancer Support Platform](#latest-project--personalized-cancer-support-platform)
  - [The Spine — Ten Lines to Memorise](#the-spine--ten-lines-to-memorise)
  - [What the Product Is (~50 s)](#what-the-product-is-50-s)
  - [My Role, in One Line (~10 s)](#my-role-in-one-line-10-s)
  - [The Shape of the System (~90 s)](#the-shape-of-the-system-90-s)
  - [The Data Layer (~70 s)](#the-data-layer-70-s)
  - [Identity and Access (~80 s)](#identity-and-access-80-s)
  - [How Services Talk, and How They Stay Consistent (~100 s)](#how-services-talk-and-how-they-stay-consistent-100-s)
  - [How It Ships, and How We See It (~25 s)](#how-it-ships-and-how-we-see-it-25-s)
  - [Close (~35 s)](#close-35-s)
  - [If Asked — Two Problems That Cost Us (~125 s)](#if-asked--two-problems-that-cost-us-125-s)
    - [Problem one — the acknowledgement that meant nothing](#problem-one--the-acknowledgement-that-meant-nothing)
    - [Problem two — the connection that could leak data](#problem-two--the-connection-that-could-leak-data)
  - [Optional — The AI Part (~100 s)](#optional--the-ai-part-100-s)
  - [Optional — How It Ships, in Full (~55 s)](#optional--how-it-ships-in-full-55-s)
  - [Optional — Logs, Metrics and Traces, in Full (~60 s)](#optional--logs-metrics-and-traces-in-full-60-s)

---

## The Spine — Ten Lines to Memorise

1. One record has two audiences, and their access rules are opposite.
2. The request rate was low. The tables were not. The low rate is why this isn't twenty services.
3. The core is a modular monolith with four modules. Two services moved out, and each had its own reason to be released.
4. The module boundary was a build gate, not a habit. An import across a boundary failed the build, and a test caught a module reading another module's schema.
5. Postgres holds the truth. Mongo holds the content. Elasticsearch is a view. [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") is disposable. Blob holds the bytes.
6. Every index serves a named query. The big tables are partitioned. Check-ins is 110 million rows. The timeline is keyset, not offset. → **35%** (search)
7. Two identity planes. Patients sign up. Clinicians are provisioned, and the gateway checks the token audience.
8. Roles say what you may *do*. Which rows you may *reach* is resolved per request, below the application. For us that was row-level security.
9. When the hospital disables a clinician, [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") closes every open care relationship in the same transaction.
10. Facts go on the exchange. Jobs go on [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle"). Outbox, not dual write. Unique keys turn duplicates into updates. Reminder state is a row in Postgres. → **22%**

## What the Product Is (~50 s)

Let me start with what the product does. Then I'll go through the architecture. And in each part, I'll point out which piece was mine.

It's a support platform for people diagnosed with cancer and for the clinicians who look after them. A patient logs how they feel every day, reads guidance written for their exact diagnosis and treatment, and keeps appointments, prescriptions and scans in one place. The care team sees the same record.
**So, the problem this platform resolves is that** before this, all of that was in paper packs, email threads and phone calls.

Technically that means:
> **"One record has two audiences, and their access rules are opposite."**

A patient sees everything about themselves and nothing about anyone else. A clinician sees a small part of many patients' records, and only while they are on that patient's care team.
Those opposite rules shaped most of the design.

## My Role, in One Line (~10 s)

What my role implied - I was a backend engineer on the core platform. I owned the data and search layer, the identity and provisioning APIs, the event-driven paths, and the pipeline.

## The Shape of the System (~90 s)

The system was designed to handle twenty-five thousand patients a day, which is about two hundred requests a second at peak.
The request rate was low. But the tables were not small — for instance, `check-ins` is around a hundred and ten million rows.

So, what influenced the architecture most:
> **"The rate is low, but the rules are strict. That's the whole reason this isn't twenty microservices."**

The core is a modular monolith in [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"): one deployable unit with four modules<span style="color:gray"> — patient diary, clinical records, clinical content and identity</span>. Each module has its own database schema, so the boundary in the code is also a boundary in the database.
Modules don't import each other. They rather call a published interface. And the pipeline enforced that. An import across a module boundary failed the build. <span style="color:gray">The published interface makes the module boundaries real. They are just not network boundaries.</span>

I designed that split. And also two parts moved out as separate microservies, each with its own reason:
- **SCIM provisioning** <span style="color:gray">(The hospital directory calls the SCIM service to create and disable clinician accounts.)</span>, because the hospital decides when this service is released,
- and **the clinical NLP (Natural Language Processing) service**, because it needs GPUs and it ships when a new model version is ready, not when the product ships.

So, the rule is:
> **"A service moves out when it has its own reason to be released. It does not move out because the diagram looks cleaner."**

<details>
<summary><strong>The trade-off we accepted</strong></summary>
With four modules in one deployable, one person's release blocks someone else's feature. But we accepted that. At two hundred requests a second, splitting the modules would have given us distributed transactions and more on-call alerts. It would have given us no extra throughput.
</details>

<details>
<summary><strong>Boundaries</strong></summary>
Here is what made that boundary real. The pipeline had import-linter contracts. They declared the four modules independent of each other, and they failed the build on any import that crossed a boundary outside the published interface. There was never an ignore list, because we wrote the contracts with the first module.

An import linter can't see raw SQL. So each module's models were bound to its own schema, and an integration test failed if a module ran SQL against a schema it didn't own.

If you start from a codebase that is already entangled, you do it the other way round. You record today's violations as a baseline, fail the build on every new one, and pay the baseline down. We never needed that, because we started with the gate.

> **"A gate you have never seen go red isn't a gate. So a deliberate cross-module import is one of the pipeline's own test cases."**
</details>

<details>
<summary><strong>If asked: "your CV says three modules"</strong></summary>
Yes, it does: diary, clinical content and identity. Records is the fourth module, and I split it out on purpose. The clinical record has a different write model from authored content. It also has different consistency and audit obligations. If I had put records inside clinical content, a prescription and a leaflet would have gone through the same code path.
</details>
<details>
<summary><strong>If asked: "how would you decompose further?"</strong></summary>
Three seams really justify a split: a different release cadence, different hardware, or a different owner. I'd take them one at a time. I'd move one module out with the strangler pattern. I'd use the schema boundary that already exists as the seam. And I'd stop as soon as there is no more reason to split.

> **"If you split by domain nouns, you end up with a distributed monolith."**
</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed a FastAPI modular monolith with separate patient diary, clinical content, and identity modules, and extracted microservices for SCIM provisioning and clinical NLP so those releases no longer blocked the rest of the product</summary>

*The "your [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") says three modules" note above explains why `records` is a fourth module. This note covers what the split gives us and what it costs.*

**What a module owns.**

- `diary`: check-in capture, schedules and adherence.
- `records`: appointments, prescriptions, visit notes, document metadata and timeline assembly.
- `clinical-content`: page assignment, delivery and read-state.
- `identity`: patient portal auth, care-relationship authorization and consent.

Each module is its own Python package and has its own [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") schema. The schemas are `identity`, `records`, `diary`, `content` and `audit`. So the boundary in the code also exists in the database. Without that, the boundary would slowly break down until any module could use any table.

**How modules talk.** A module reads its own schema directly. It reads another module's schema only through a published in-process interface. That keeps the seam real, and the call is still just a function call. There is no serialisation and no network failure mode. And the whole request still commits in one transaction. A split would take away that single transaction.

**Why each extracted service moved out.** `scim-provisioning-svc` releases on the hospital directory's cadence, not ours. When the hospital changes its directory configuration, that is not a reason to ship the patient portal. `clinical-nlp-svc` needs a GPU node pool, and it ships when a model version is ready. It runs on the second cluster, `aks-ml`. We keep that cluster free of state on purpose. So we can merge `aks-ml` back into `aro-primary` if GPU inference ever moves to a managed endpoint.

**Each one releases differently. Each service's release strategy depends on the failure that service has to survive.**

- `care-core` uses blue-green with a single Route switch. It holds the clinical record, so it needs the cleanest rollback available.
- `clinical-nlp-svc` uses a canary at 5% → 25% → 100%. This is because a model regression shows up statistically and never in a health check.
- `scim-provisioning-svc` uses a rolling update. It has an external caller and idempotent operations, and it has no part that users see.

**What moving the services out did not give us.** `scim-provisioning-svc` also writes to `pg-clinical`. It writes only to the `identity` schema. It writes the `clinician` and `care_team_member` rows, and the `care_relationship` rows that a deprovisioning closes. So the separation is at the deployment level, not the data level. The service releases on its own cadence. But it cannot change those tables without considering `care-core`. Schema ownership is what keeps this under control. If someone proposes a second service that writes across schemas, that is the point where this arrangement stops being acceptable.

**The honest limit.** The gate is static. It sees imports, not dynamic access — reaching into another module's package by name at run time, or an import built from a string. The schema test covers the SQL route. Nothing covers the dynamic route, and we accepted that, because it takes deliberate effort rather than carelessness. The contracts also police where you cross, not how much you expose. An interface module that grows into a god-object passes every contract, and keeping it thin is still a review judgement. And the database doesn't enforce any of it. `care-core` is one process behind one transaction-mode pooler. Per-module roles would mean per-module engines and pools, and that would give up the single commit across modules, which is the whole reason we stayed in one process.

</details></li>
</ul>

</details>

## The Data Layer (~70 s)

There are five stores, and each one has exactly one job.

> **"Postgres holds the truth. Mongo holds the content. Elasticsearch is a view. Redis is disposable. Blob holds the bytes."**

I designed the Postgres schemas and the Elasticsearch indexes. Three things are worth naming.

Every index exists for one named query in the [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"). If I can't name the endpoint, we don't create the index.

The two big tables are check-ins and audit, and both are partitioned by month. Check-ins is around a hundred and ten million rows.

And the patient timeline is a union across five tables, so the cursor carries a normalised ordering column plus the source table and the row ID. That is what makes it keyset pagination and not offset. Offset gets slower the deeper you page, and on a table that size it degrades badly.

> **"That work cut search latency by about thirty-five percent. The number is for clinical content search. I don't have a measured number for the timeline or the record queries."**

<details>
<summary><strong>The five stores, and the timeline cursor in full</strong></summary>

**Why each store is the store it is.**

- **Postgres** is the system of record: patients, care relationships, appointments, prescriptions, notes, check-ins, consent and audit.
- **[MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents")** holds the education content, for two reasons. Every page is versioned, and the page shape changes by cancer type, treatment line and language. In a relational model, this content would need a very wide table that is mostly empty.
- **Elasticsearch** serves search over notes and guidance. It is a projection, and we can rebuild the whole index from Postgres and Mongo.
- **Redis** holds nothing durable: sessions, caches, rate limits and idempotency keys. If we lose Redis, the system gets slow, but NOT wrong.
- **Azure Blob Storage** holds the document bytes — scans, letters and the audit archive. By year five, it will hold about twelve terabytes, more than all the other stores put together.

**Why the timeline cursor has three parts.** The five tables each order on a different natural column, and one of those columns is a date, not a timestamp. You can't order that union deterministically, and you can't serve it from one index shape either. So every timeline table has a normalised ordering column. The cursor carries that column, the source table and the row ID, so when rows from different sources tie, the tie breaks the same way every time.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed PostgreSQL schemas and Elasticsearch indexes for clinical content search so patients and clinicians could find notes, guidance, and visit history without scanning the full record, cutting query latency by 35%</summary>

**Each fact has one owning store.** `pg-clinical` holds the `identity`, `records`, `diary`, `content` and `audit` schemas. It is the only store we can serve a client read from without any caveat. `mongo-content` owns the pages and the guidance corpus. `es-clinical` owns nothing at all. It is a projection, and we can fully rebuild it from the other two stores. That is why a complete reindex is a routine operation, not a disaster procedure.

**The table the whole authorization model depends on.** `care_relationship` is temporal. `valid_period` is a `tstzrange` with a [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") exclusion constraint. So a clinician's access to a patient has a start and an end. And the history is never overwritten. There is exactly one definition of "may this clinician see this patient". The row-level security policies join through `care_relationship`.

**Rules we put in the schema, not in code.**

- `wellbeing_checkin` is unique on `(patient_id, recorded_for)`. So an at-least-once redelivery becomes an `INSERT ... ON CONFLICT DO UPDATE`. The application does not have to remove duplicates itself.
- `outbox_event` is written in the same transaction as the business change. It is the only thing that ever writes to `es-clinical` or `sb-integration`.
- `reminder` and `reminder_delivery` are separate tables. One reminder can have many delivery attempts. So "was it delivered" is a query.
- `audit_event` has `UPDATE` and `DELETE` revoked from every application role. It also has a trigger that blocks them.
- `document` holds only metadata. A client cannot see a `document` row until `scan_state = 'clean'`.
- We do not use soft deletion on clinical rows at all, because retention law governs the record. When a patient withdraws consent, the `consent` table restricts further processing. We do not tombstone their prescriptions.

**Where the data is deliberately not in columns.** `symptom_scores` is `jsonb` with a [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") index. The reason is that the symptom set differs by cancer type and changes with the clinical protocol. With one column per symptom, every protocol change would need a migration. `external_mrn` is encrypted. It also has an [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") blind index over the normalised value. The key for that index is kept separately in Key Vault. So hospital sync can still find a patient by medical record number. And only the matched row is ever decrypted.

**One index per named access pattern.**

- Timeline, most recent first: a composite B-tree on `(patient_id, timeline_at DESC)`, on all five tables that feed the timeline.
- Check-ins over a date window: a monthly range partition plus a [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") index on `recorded_at`. On 110 million rows, the physical order matches the insert order. So for the same range scan, BRIN costs a fraction of a B-tree.
- Symptom trend: a GIN index on `symptom_scores`.
- "May this clinician see this patient", checked on every clinician request: a GiST index on `care_relationship (patient_id, clinician_id, valid_period)`. The exclusion constraint and the index are the same object.
- A clinician's patient list: an index on `(care_team_id, patient_id)`, partial on `WHERE upper(valid_period) IS NULL`.
- Due reminders, swept every 60 seconds: a partial B-tree on `(scheduled_for) WHERE state = 'pending'`. This keeps the hot index at the size of the pending set, not the size of all history.
- Outbox relay: a partial B-tree on `(occurred_at) WHERE published_at IS NULL`. This is the relay's only query.
- Audit by subject, for compliance and subject-access requests: a monthly partition plus an index on `(patient_id, occurred_at DESC)`.

**Three Elasticsearch indexes behind one alias.** The alias `clinical-search` sits in front of three indexes:

- `es-clinical-notes` holds visit notes. The extraction model enriches them with entities. The index uses the English analyser plus a clinical synonym filter.
- `es-clinical-content` holds approved page versions only.
- `es-clinical-history` holds appointments, prescriptions and document titles. This is the visit-history surface.

Each index has three primary shards and one replica. In total, they hold around 150 GB on three data nodes.

**Scope is a property of the index, not an application convention.** Every document in every index carries `patient_id` and `care_team_ids`. `care-core` builds every query. No client ever reaches `es-clinical` directly. If a search engine can return a document that the record layer would refuse, it is a disclosure path. So the filter is mandatory, not just a habit.

**What actually produced the latency improvement.** Scope and date clauses go in `filter` context. That context is cacheable and unscored. Only the user's text goes in `must`. So the expensive scoring pass runs on a set that is already narrowed, not on the whole index. Bulk indexing flushes at 5 seconds or 1,000 documents. `refresh_interval` is 5 seconds, not the default of 1 second. The longer refresh interval roughly halves segment-merge pressure.

**The honest limit.** Search quality on oncology notes depends on a set of synonyms and abbreviations. The set covers, for example, drug brand names versus generic names, and staging notation. Building and maintaining that set is clinical work, not engineering work. The set needs a named owner before we can pair a latency number with a relevance claim. The other weak point is a scope change. Reassigning a patient to a different care team rewrites `care_team_ids` on that patient's documents. Until `celery.index` finishes that reindex, the old team can still match in search. That is exactly why reassignment also closes the `care_relationship` row. The record layer respects that closed row immediately.

</details></li>

<li><details>
<summary>Migrated data access to SQLAlchemy 2 and tightened SQL for clinical record queries used on the patient timeline and care-team views</summary>

*The previous bullet covers the indexes behind these queries. This one covers the query side and the [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries").*

**Why the 2.x typed API mattered more than the rewrite.** `pyright --strict` can check [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") 2's typed constructs. And `pyright --strict` is a blocking gate in the pipeline. On a clinical record, a wrong join is not a bug. It is a disclosure. So checking the query shape at build time was enough reason for the migration on its own.

**The timeline query.** It is the clinician query that runs most often in the system. It is a union across five tables. Each table orders on a different natural column: `starts_at`, `prescribed_on`, `encounter_date`, `uploaded_at` and `recorded_at`. `encounter_date` is a `date`, not a timestamp. A `UNION ALL` that mixes a `date` with a `timestamptz` cannot be ordered deterministically. It also cannot be served from one index shape. So every table that feeds the timeline has a `timeline_at timestamptz` column. Each table fills that column from its own natural column. The query orders only on `timeline_at`. The natural columns stay, because `encounter_date` is the clinical fact. `timeline_at` is only a presentation key.

**Keyset pagination, with the `LIMIT` in each branch.** The cursor is the tuple `(timeline_at, source_table, id)`. So ties across sources break the same way every time. Each branch of the union has its own window and its own `LIMIT`. So Postgres reads at most `limit` rows from each source. It does not materialise and sort the entire union and then discard most of it. Offset pagination on this query is not allowed at all. The composite indexes exist exactly to avoid it.

**The care-team views.** A clinician's patient list comes from the partial index over open `care_relationship` rows. So the query touches only the currently active rows. It does not touch the full history that the temporal table keeps. The query author does not have to remember a `WHERE` clause for which patients are reachable. Row-level security handles that, and the authorization section covers it.

**One constraint that row-level security puts on the [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database").** We write the policies so that the patient scope can use the index. Suppose a policy is written the wrong way, as a plain `IN` subquery or hidden in a function. Then the policy becomes a filter. A query that relies on it reads every row of the monthly partitions it touches in `wellbeing_checkin` and `audit_event`, not just the rows of reachable patients. Partition pruning still happens, because it comes from the time bound. The query is still correct, but it quietly becomes slow. An `EXPLAIN` assertion in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") guards the plan shape. We don't rely on code review to notice the problem.

**[Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy"), and why migrations are a deploy-time step here.** Migrations run as an [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") PreSync hook. They run under a separate owning role that never serves a request. And they are expand-contract. That is what lets both colours of a blue-green cut-over run against one schema.

**The honest limit.** Every audited read is a write, so none of this runs on a replica. The primary serves the timeline, so the headroom is the primary's headroom. The design records these targets: p95 under 120 ms when cached, and under 250 ms when cold. There is a named index behind every query. But the design does not record the pre-migration baseline that those improvements were measured against.

</details></li>
</ul>

</details>

## Identity and Access (~80 s)

I'd call this the most important part of the system.

Two identity planes. Patients sign up by themselves. Clinicians never sign up — they are provisioned from the hospital's Entra ID directory over SCIM 2.0. The two planes get different token audiences, and the gateway checks the audience against the route.

Then authorization, and I'd put it as a principle first. Roles say what you may *do*: write a visit note, approve content, manage a care team. But *which rows you may reach* is not a role. It is a fact that changes over time, so it is resolved per request, below the application. The mechanism in our case was Postgres row-level security.

> **"If I forget to scope a query, it returns nothing. It doesn't return someone else's record."**

I also built the SCIM side, and that is the part I'd most want to be asked about.

> **"When the hospital disables a clinician, we close every open care relationship in the same transaction."**

Access ends when employment ends, and there is no step on our side that anyone could forget.

<details>
<summary><strong>Token mechanics, how the reach check is wired, and audited reads</strong></summary>

**Token mechanics.** Both planes use the OAuth 2.0 authorization code flow with PKCE. Access tokens are short-lived.

> **"The gateway rejects a patient token on a clinician endpoint. The token never reaches the code."**

**How the check is wired.** Every request sets the actor inside the transaction, and the policies join through the care relationship, which is stored as a time range with a start and an end. Resolving reach below the application is what turns the most common application bug into an empty result rather than a data breach. The application checks still exist. They are just a second layer.

**Why a failed sync is paged.** A SCIM sync failure is a security event, not a background-job failure. It is the one alert where the *absence* of a change is the incident: some access should have ended and has not.

**Why an audited read can't be served from a replica.** Every read of patient data writes an audit row. This includes a read served from cache, because a cache hit is still an access. So an audited read is a write. That means it can't be served from a read replica, and it fails when the primary fails.

> **"Read availability is limited by write availability, and we chose that."**

The alternative was to queue the audit rows, so reads survive a failover. But then we would live with an audit trail that has a gap in it. For a health record, the gap is the worse outcome. So we paid for the coupling instead. We use zone-redundant [HA](https://en.wikipedia.org/wiki/High_availability "High Availability — System design goal of remaining operational despite component failure") and a sixty-second failover, and that fits the availability budget. The replicas still exist. They just don't carry audited patient reads. They carry index rebuilds, reporting and backup verification.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Implemented REST APIs with SCIM 2.0 and Azure Entra ID JWT so clinician and care-team accounts stay provisioned from the hospital directory and stay off the patient portal</summary>

**The SCIM surface, and who is allowed to call it.** `scim-provisioning-svc` implements `Users` and `Groups` with the standard verbs:

- `GET|POST /scim/v2/Users`
- `GET|PATCH|DELETE /scim/v2/Users/{id}`
- the same endpoints for `Groups`
- `GET /scim/v2/ServiceProviderConfig`, so Entra can discover what is supported instead of assuming it

Entra ID is the only authorized caller. Entra ID calls with its own client credential. Network access to this service is restricted. Nobody can reach it through the patient plane.

**What a directory operation does on our side.** Create and update map to `clinician` and `care_team_member` rows. `active: false` is the operation that matters. It closes every open `care_relationship` for that clinician in the same transaction. Access ends when employment ends. There is no step on the platform side, so nobody can forget that step. Concurrent operations on one directory object run one at a time. They use a short-lived Redis lock keyed by the Entra object ID.

**A failed sync is a security event, not a background-job failure.** SCIM sync failures are paged. This is because a deprovisioning that did not complete means some access should have ended, but it has not. It is the one alert in the set where the *absence* of a change is the incident.

**Two audiences, checked before any code runs.** Patients authenticate in the patient tenant and receive `api://care-platform/patient`. Clinicians authenticate in the hospital tenant and receive `api://care-platform/clinician`. [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway") first validates the signature against the cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"). Then it checks the issuer, the expiry, and the audience against the route's plane. So the gateway rejects a clinician token on a diary endpoint with `403`. `care-core` validates the token again. It does not trust a header that the gateway set. So if someone bypasses APIM, they still do not bypass authentication.

**Token mechanics.** We use the OAuth 2.0 authorization code flow with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), and [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") for identity. Access tokens last 15 minutes. Refresh tokens are rotated and bound to the client. Patients use multi-factor authentication at enrolment and on sensitive operations. On the clinician side, the hospital's own conditional access applies. The platform uses that conditional access as it is and does not weaken it.

**The JWKS cache is an availability choice, not a performance one.** Entra's signing keys stay in `redis-cache` for 12 hours. They refresh when an unknown `kid` arrives. That long [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") is exactly why an Entra outage leaves existing sessions working. The outage only makes new sign-ins fail.

**The honest limits. There are two.** First, deprovisioning closes the care relationships instantly. But a token that was already issued stays valid until it expires. So there is a 15-minute window. In that window, authentication succeeds, but every reach check returns nothing. Second, the check-in transport authenticates per *connection*, not per publish. This is because [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers")'s [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") plugin has no per-message authentication. So a long-lived mobile connection needs a maximum lifetime that is shorter than the refresh window. The connection must also be forced to re-authenticate. The design flags this gap. The gap needs a prototype against real token lifetimes before we commit to that transport. The next section covers the transport itself.

</details></li>
</ul>

</details>

## How Services Talk, and How They Stay Consistent (~100 s)

We have five transports, and each one has a stated job, so nobody has to guess which one to use.

> **"The exchange is for facts we publish. Celery is for work we owe. Service Bus is where work leaves our platform. They're not the same thing."**

The other two are [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs"), for anything a user is waiting for, and MQTT, for check-ins from the phone.

I spent most of my design time on consistency. Three rules.

**Nothing writes to Elasticsearch directly.** Every write commits to Postgres with an outbox row in the same transaction, and a relay publishes that row. The honest cost is about eight seconds before a new note is searchable. A dual write can commit and then fail the index write, and nothing detects that.

**The schema handles duplicates, not the code.** A redelivered check-in hits a unique key on patient and date, so it becomes an update instead of a second row.

**The state machine is in the database, not in the queue.** Every reminder is a row with a state, and every attempt is its own row. A worker claims what is due with `FOR UPDATE SKIP LOCKED`, so workers scale out without dispatching the same reminder twice.

> **"If the queue is down, reminders are late. They are never lost."**

That third rule is what cut missed reminders by over twenty percent.

<details>
<summary><strong>The five transports in full, and the rest of the consistency detail</strong></summary>

**The five transports, each with its stated job.**

- **Synchronous REST** is for anything a user is waiting for. A screen that someone is looking at should not be eventually consistent.
- **A RabbitMQ topic exchange** is for domain facts. For example: check-in recorded, note created, appointment scheduled.
- **Celery** is for work we own and must retry. For example: reminder sweeps, page generation and indexing.
- **MQTT** is for check-ins from the phone.
- **Azure Service Bus** is at the edge, where work goes to somebody else. At this edge, reminder delivery goes out and document ingest comes in. The Functions sit at that edge.

**Why MQTT for check-ins.** A patient is often in a hospital basement or on a bad connection. With MQTT, the phone queues the check-in locally and delivers it when the phone reconnects. MQTT runs on the same RabbitMQ broker, so an MQTT check-in arrives on the same exchange that everything else consumes.

**How documents get in.** I moved that path from ad-hoc folders to Azure. A scan or a letter never goes through the API. The client gets a short-lived signed [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") and uploads straight to Blob Storage, so multi-megabyte files never touch the pods that serve a clinician's timeline. The upload goes into a quarantine container. A blob-created event triggers a Function that scans the file and extracts its text. We promote the file and make the document row visible only after that.

> **"No record row ever points to an unscanned file."**

**Transport security.** We use [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") everywhere. No data store has a public endpoint. The one cross-cluster hop carries clinical free text, and it runs on mutual TLS. And the MQTT listener lets a device publish only to the topic that matches its own token.

**The outbox, in full.** A new note becomes searchable in about eight seconds, or fifteen seconds at p95. With an outbox, the backlog is a metric, and it clears by itself.

**The duplicate rule, in full.** A unique key turns at-least-once delivery into a predictable outcome instead of a bug.

**The reminder path, end to end.** The worker writes the attempt row, then hands the delivery to Service Bus, where a Function does the actual send and posts the provider's receipt back. So "was it delivered?" is a query, not a guess. And a final failure escalates to the care team, instead of ending as a log line. Before this, reminders went out inline during a request, so if the request failed the reminder failed with it, and nothing recorded that it never arrived.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Implemented event-driven FastAPI services with RabbitMQ AMQP and MQTT to take wellbeing check-ins and appointment reminders off the request path, cutting missed reminders by 22%</summary>

**What goes on the exchange.** `care.events` is a topic exchange that carries domain facts: `checkin.recorded`, `visitnote.created`, `appointment.scheduled` and `carerelationship.changed`. Publishing a fact does not give the publisher the right to know who consumes it. That is why these facts are not Celery tasks. A task registry couples every consumer to the publisher's deployment.

**What goes on Celery.** There are three queues, and each one has its own concern:

- `celery.reminders` is for the beat-driven sweep.
- `celery.content` is for page generation.
- `celery.index` is for the outbox projection into `es-clinical` and for reindexes.

This is work the platform owns. It has owners, deadlines and retry policies. That fits Celery's model, not the model of a fire-and-forget event.

**The check-in path, and the three broker details it depends on.** The phone publishes to `care/checkin/{patient_id}` at [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") 1. The broker acknowledges once the message is durable on a quorum queue. From that moment, the recovery point is zero, and the UI can honestly say "recorded". That claim depends on two settings that are not defaults, and on one fixed translation:

- `mqtt.exchange` has to point at `care.events`. Otherwise, the plugin publishes to `amq.topic`.
- MQTT's `/` separator always becomes [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications")'s `.`. So the topic binds as `care.checkin.{patient_id}`.
- `care.events` needs an alternate exchange. This is because RabbitMQ returns a [PUBACK](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "MQTT PUBACK packet — Confirms receipt of a QoS 1 published message") for a QoS 1 publish that routes to no queue at all.

Problem one at the end of this document is about that third setting.

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

</details></li>

<li><details>
<summary>Migrated file ingestion and async notifications to Azure Blob Storage, Service Bus, and Event Grid so scans, letters, and follow-up messages no longer sat in ad-hoc folders</summary>

**The upload never touches the API.** `POST /api/v1/documents:upload-intent` returns a `document_id` and a short-lived signed URL. The client sends the bytes straight into the `ingest-quarantine` container. If `care-core` proxied multi-megabyte scans, the scans would be on the same pods that serve a clinician's timeline. The signed URL sends the bytes somewhere else. But the metadata write stays transactional.

**From quarantine to visible.** A `BlobCreated` event on `evtgrid-blob` triggers `fn-blob-ingest`. That Function validates the file, scans it and extracts its text. The blob is promoted into the `documents` container only if the result is clean. Then the row's `scan_state` is set to `clean`. No client can see the row before that. No record row ever points to an unscanned file.

**The layout is by container, and each container has its own lifecycle rule.**

- `documents` uses the path `{patient_id}/{document_id}/{sha256}`. Files stay hot for 90 days, then cool for a year, then move to archive.
- `ingest-quarantine` uses the path `{upload_id}`. A file is deleted on promotion or after 24 hours, whichever comes first.
- `audit-archive` uses the path `{yyyy}/{mm}/audit-{partition}.parquet.zst`. It has a write-once policy with a seven-year retention period. We keep `audit_event` partitions hot for 13 months. After that, the monthly partitions move to `audit-archive`.

**The notification edge.** `sb.notify` carries the dispatch command. The `reminder_delivery_id` is its idempotency key. `fn-notify-dispatch` delivers by push, email or [SMS](https://en.wikipedia.org/wiki/SMS "Short Message Service — Delivers short text messages over a mobile network"). Then it puts the provider's receipt back on a queue. Functions fit both edges, because the work comes in bursts, is short, and is triggered by events. Paying for idle pods to wait for an upload would be the wrong fit. Service Bus adds durable dead-lettering exactly where work goes to a third party.

**Security settings on the storage account itself.** The storage account uses a customer-managed key and [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit") only. Public access is disabled. It has zone-redundant replication and soft delete. The audit container has an immutability policy. By year five, the account will hold about twelve terabytes. That is more than all the other stores put together.

**The honest limit.** Running `rmq-core` and `sb-integration` means we operate two brokers. That cost is real. We split the two brokers at the edge where the platform hands work to Azure. That keeps the rule easy to remember. But if we ever drop MQTT ingress, this choice is the first thing to revisit. At that point, Service Bus could carry all of the messaging. The smaller limit: if Blob is unavailable, document download fails. But the rest of the record still loads. That is because the metadata is in Postgres, and only the bytes are in Blob.

</details></li>
</ul>

</details>

## How It Ships, and How We See It (~25 s)

GitLab CI, then a GitOps commit that ArgoCD syncs onto OpenShift. Every migration is expand-contract, so both versions run against one schema and a rollback is reverting a revision.

And trace context travels in message headers, not just in HTTP headers, so one trace covers the HTTP request, the broker hop and the index write.

## Close (~35 s)

So, to sum up: a modular monolith with two services that had a real reason to move out, Postgres enforcing the access rules itself, and everything slow or unreliable on queues, off the request path.

## If Asked — Two Problems That Cost Us (~125 s)

### Problem one — the acknowledgement that meant nothing

The check-in path promises no data loss. The phone publishes a check-in and gets an acknowledgement back. Then the screen says "recorded".

We found that the broker returns that acknowledgement even when the message routes to no queue at all. So for an unbound topic, the broker acknowledges the message to the device and then silently drops it. That is exactly the loss the path existed to prevent.

The fix was small. We added an alternate exchange, so an unroutable message goes to a queue where we can see it, instead of nowhere. We also had to point the MQTT plugin at our exchange explicitly, because by default it publishes somewhere else.

> **"The lesson: an acknowledgement is a promise from one component, not from the system."**

Now I test the unhappy path inside the transport itself, not only in the application.

### Problem two — the connection that could leak data

Row-level security depends on setting the current actor on the connection. But we run Postgres behind a transaction-mode pooler. The pooler reuses backend connections between requests. If you set the actor the normal way, the value survives the request. Then it leaks into the next caller's query.

> **"The strongest control in the system would have become the worst bug in the system."**

The code fix is one word: scope the setting to the transaction. But the real fix was the test. It pushes two different users through one pooled connection. Then it asserts that the second user can't see the first user's rows. We also added a CI check that the application's database role can't bypass row-level security at all.

> **"The lesson: a security control you haven't tested under real connection handling isn't a control. It's an intention."**

## Optional — The AI Part (~100 s)

I fine-tuned Hugging Face models with transfer learning. One model extracts clinical entities and codes from visit notes. The other model re-ranks guidance passages. LangChain builds the page.

The whole pipeline is built around two approval gates, not one.

The first gate is on the input. The model can only use passages that a clinician has already approved. And every block carries a citation back to the passage it came from. The model selects and rewrites approved material. It doesn't write clinical claims of its own.

The second gate is on the output. The pipeline produces a page that is pending review. A clinical reviewer approves the page before it is ever assigned to a patient. The person who wrote the source can't be the one who approves the page. That is because author and approver are separate roles, on purpose. Otherwise, the second review is not a real check, and the safety property is just a claim.

That makes the pages less fluent. A model that generates freely writes nicer pages. We accepted that cost on purpose.

> **"In cancer guidance, a sentence without a source isn't a quality problem. It's a safety problem."**

Relevance went up twenty-eight percent. That came from re-ranking against the patient's actual diagnosis and treatment line. We re-rank instead of serving one generic leaflet per cancer type.

The whole pipeline runs off the request path, so nobody ever waits on a GPU.

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Fine-tuned Hugging Face models with transfer learning and built LangChain workflows that turn diagnosis and treatment context into education pages patients actually read, raising relevance scores by 28%</summary>

**Two models, two jobs.** One model extracts clinical entities and codes from visit notes. Its output goes into `nlp_extractions` and enriches the notes index. The other model re-ranks candidate guidance passages during retrieval. The 28% comes from the two models together. The gain comes from re-ranking approved passages against the patient's actual diagnosis, treatment line and stage. We re-rank instead of serving one generic leaflet per cancer type.

**What LangChain builds, and from what.** Retrieval pulls passages from `guidance_sources`. A clinician wrote or curated those passages, and they have not been retired. The reranker orders the passages. Then LangChain writes a `content_pages` version. In that version, every block carries a citation back to the passage it came from. The model selects, ranks and rewrites approved material. It doesn't write clinical claims of its own.

**Two gates, not one.** The input gate is the approved corpus. The output gate is `review_state`. A page is written as `pending_review`. A clinical reviewer has to approve the page before `content_assignment` links a patient to an exact `(page_id, page_version)`. Linking to the exact version matters, because the text a patient saw is the record of the advice they were given. A later revision must never silently change that text. `content_author` and `content_approver` are separate roles, on purpose. If one person could write and approve, the second review would not be a real check. Then the safety property would be a claim, not a control.

**What the model is allowed to see.** Calls that build a page carry the diagnosis code, treatment line, stage and locale. They do not carry identity, name or contact details. Extraction calls that must see note text get the text and a correlation ID. They never get the patient identifier. We self-host the weights. So patient text stays inside the tenancy, and no third-party model API is involved. Only one hop carries clinical free text: from `care-core` to `clinical-nlp-svc`, across the peering into the other cluster. That hop runs on mutual TLS. cert-manager issues and rotates the certificates for that hop, because the platform's built-in service certificates do not span clusters.

**None of it is on the request path.** Generation is queued on `celery.content`, with a p95 budget of 45 seconds. Extraction runs inside a background task, with a fixed two-second deadline. If the GPU pool is unavailable, new generation pauses and waits in the queue. Pages that are already approved and assigned still serve normally.

**A model version is a rollback unit.** Every artifact is stamped with the model version. Every version is evaluated against a held-out clinical set. `clinical-nlp-svc` rolls out by canary, and each step compares confidence and latency. This is because a model regression shows up statistically, not in a health check. `nlp_extractions` contains nothing that is not in the source note. So reverting a bad model version is a reindex, not a migration.

**The honest limit.** The fine-tuning itself is still unresolved. Transfer learning on real visit notes puts patient text into a training corpus. That raises three questions. Is that lawful processing? Which de-identification standard applies? Can the resulting weights leak training text? All three need a completed impact assessment before the first tuning run. An assessment done afterwards is not enough. Fine-tuning on visit notes is the highest-risk processing in the system. The smaller cost is fluency, and we accept it on purpose. Limiting generation to approved passages measurably narrows what a page can say. That is the intended outcome.

</details></li>
</ul>

</details>

## Optional — How It Ships, in Full (~55 s)

We use GitLab CI, and every gate can really fail the build. The first gates are ruff, the import-linter contracts, pyright in strict mode, and unit and contract tests. Then integration tests run against real containers: real Postgres, real Elasticsearch and real RabbitMQ. After that, there is a SonarQube gate.

CI never touches the cluster. The last thing CI does is commit to the GitOps repo. ArgoCD then syncs that commit onto OpenShift and [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure").

I want to point out one thing, because it's the part people skip. Every migration is expand-contract. One release adds columns and backfills them. A later release removes what is no longer read.

> **"That's what makes blue-green possible. Both versions run against the same schema. So a rollback is reverting a revision. There's no down-migration to get wrong."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Moved core FastAPI services to Python 3.14 with Poetry-managed dependencies so runtime and packages stayed consistent across modules</summary>

**What the lock actually covers.** Each service has one [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects") lockfile: `care-core`, `scim-provisioning-svc` and `clinical-nlp-svc`. Each lockfile is resolved once. It is installed the same way in CI and in the image. The interpreter version is pinned the same way across all three services. This removes a drift that surprised us at deploy time. A dependency resolved one way in the pipeline and another way on a developer's machine. We found the difference in the cluster.

**The pinning does not stop at Python.** Images are built from pinned digests and scanned at build time. ArgoCD deploys only digest-pinned images from the registry. So nobody can swap a mutable tag under a running cluster between one sync and the next.

**The honest limit.** Three lockfiles means three things that can become different. The design says versions are pinned the same way across services. But it names no check that fails the build when they stop being the same. So today, that consistency is a convention that code review enforces, not a gate.

</details></li>

<li><details>
<summary>Configured GitLab CI with ruff, pyright, and SonarQube gates, automating lint, type checks, and test runs before OpenShift deploys, and fixed failing pipeline and deploy jobs</summary>

**The gates, in order. Every gate can really fail the build.**

1. `ruff` for lint.
2. `import-linter` contracts on the `care-core` module boundary.
3. `pyright --strict` for types.
4. Pytest unit and contract suites.
5. Pytest integration tests against real `pg-clinical`, `mongo-content`, `es-clinical`, `redis-cache` and `rmq-core` containers on Docker Compose.
6. The SonarQube quality gate on coverage and new-code quality.
7. A Docker build with an image scan and a digest-pinned push.

Integration tests run against the real brokers and the real search engine. This is because a mocked broker cannot fail the way a real broker does.

**CI never touches the cluster.** No pipeline job holds cluster credentials. The last thing the pipeline does is commit the image digest to the GitOps manifest repository. ArgoCD reconciles from there. That is also why a rollback is a Git operation, not a deploy.

**Four of the gates look like quality gates, but they are really security controls.**

- One check fails the build if a log call passes a [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") model with a field marked as sensitive.
- A role-privilege assertion fails if the application's database role is superuser or holds `BYPASSRLS`.
- A pooled-connection test sends two different actors through one pooled backend. It asserts that the second actor cannot see the first actor's rows.
- An `EXPLAIN` assertion fails if a row-level security policy has stopped the patient index from being used. That is how a query starts reading every row of its partitions while nothing looks broken.

**The honest limit.** Running the real broker in CI does not settle the flagged question about Celery on quorum queues. That question needs a pinned-version test of `task_acks_late`, global QoS and priority against the broker. The pipeline, as designed, does not assert that yet.

</details></li>

<li><details>
<summary>Wrote Pytest unit and integration tests for API contracts, identity flows, and clinical content services so SCIM and portal changes did not break patient access</summary>

**The contract is an artifact, not a document.** Pydantic models define every request and response body. FastAPI emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document from those models. The contract suite tests against that document. A breaking change to a response shape fails the pipeline, not a client.

**What the suites cover, chosen by the consequence of a failure.**

- The identity flows: audience separation between the two planes, SCIM create and update, and `active: false` closing the care relationships it has to close.
- The clinical content services: `review_state` transitions, and the rule that only an approved version can ever be assigned to a patient.
- The record paths: the timeline union, its cursor and the scoping behaviour.

On these paths, a regression either removes a patient's access or gives them someone else's.

**Integration means the real dependencies.** Developers run a Compose stack locally. The integration stage runs against the same stack. That is what makes the database-level assertions possible at all. Row-level security behaviour cannot be tested against a fake.

**The honest limit.** The pooled-connection leakage test is only meaningful against the transaction-mode pooler that production runs behind. But the Compose stack in the design names Postgres, not the pooler. That is exactly the gap that makes a control look tested when it is not. It is the part of the test suite I would want proven before I trust it. Apart from SonarQube's gate on new code, we claim no coverage figure. The useful statement is which paths are covered and why, not a percentage.

</details></li>

<li><details>
<summary>Deployed releases with ArgoCD to OpenShift and Kubernetes so diary, content, and identity services rolled out on the same GitOps path</summary>

**One declared desired state, two clusters.** ArgoCD syncs two clusters. `aro-primary` runs `care-core`, `scim-provisioning-svc`, `celery-worker`, `rmq-core`, `mongo-content` and `es-clinical`. `aks-ml` runs `clinical-nlp-svc` and nothing else. There are no imperative deploys on the cluster side. So you ask the Git history what is running, not the cluster.

**Migrations run as a PreSync hook.** `alembic upgrade head` runs before the pods of the new revision appear. It runs under an owning role that is separate from the role that serves requests.

**Expand-contract is what makes the rollback simple.** One release adds columns and backfills them. A later release removes what is no longer read. Every migration is backwards-compatible with the previous image. So both colours run against the same schema during a blue-green cut-over. And a rollback is reverting an ArgoCD revision. There is no down-migration to get wrong. If a migration cannot be written that way, we split it across two releases instead.

**Infrastructure takes the same path.** [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") provisions all Azure and cluster resources. Its state is in Azure Storage. CI applies it, and production has a plan-review gate. A change made by hand to a resource Terraform manages is drift. Drift is reported as a failure. It is not quietly reconciled.

**The honest limit.** Two clusters is the most expensive choice in the design. Only two things justify it: GPU node-pool management and the independent NLP release cadence. On purpose, `aks-ml` holds no state, so it is easy to merge back. So if GPU inference ever moves to a managed endpoint, the right move is to merge `aks-ml` back into `aro-primary`. We should not keep paying for `aks-ml`.

</details></li>
</ul>

</details>

## Optional — Logs, Metrics and Traces, in Full (~60 s)

We use Prometheus for metrics and Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production") for traces. Kibana is the single view for all of it. We also ship Azure's own logs into the same Elasticsearch. So we don't read two separate, incomplete stories about the same incident.

What makes this really work is that trace context travels in message headers, not just in [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") headers. So one trace covers the HTTP request, the broker hop, the Celery task and the index write. It goes end to end across the async boundary.

We have two rules on logging. First, we never log clinical text. Sensitive fields are marked on the Pydantic model, and a formatter drops them. CI fails the build if a log call passes a sensitive field.

> **"Second, audit is a database table, never a log stream. If you mix them, your log retention quietly becomes your audit policy."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Instrumented Elastic APM, Prometheus, and Kibana to track API and consumer latency and error rates on wellbeing and reminder traffic.</summary>

**Joining the two planes is what makes it work.** There are two telemetry planes: the clusters and the Azure-native services. We join them instead of leaving them separate. `traceparent` propagates on every hop, including AMQP, MQTT and Service Bus message headers. Azure Monitor's diagnostic logs from the gateway, Functions, Service Bus and Blob are shipped into the same Elasticsearch. So one trace covers the HTTP request, the broker hop, the Celery task and the index write. And Kibana is the single view. Without that join, a reminder that fails between `celery.reminders` and `fn-notify-dispatch` leaves two separate, incomplete stories.

**The consumer-side indicators. This bullet is really about these.**

- `consumer_task_duration_seconds` p95 by queue. It alerts above 5 seconds on `celery.reminders` or `celery.index`.
- `consumer_task_failed_total` over `consumer_task_total`, by queue. It alerts above 1% over 15 minutes.
- Broker queue depth and unacked counts.
- On the reminder path: `reminder_dispatch_lateness_seconds` at p99, and `reminder_delivery_total{state}`. The second metric turns "missed reminders" into a number.
- On the API side: `http_request_duration_seconds` p95 by route, and the 5xx rate on mutating routes.

**Sampling depends on what is worth reconstructing.** We sample all errors and all reminder and NLP traffic. We sample 10% of routine reads.

**Two rules about logs.** We never log clinical free text, symptom values or document contents. A Pydantic-driven redaction filter drops fields marked as sensitive at the formatter. CI fails the build if a log call passes a sensitive field. Audit is a database table, never a log stream. Logs are for operators, and audit is for the regulator. If you mix them, log retention policy quietly becomes audit policy.

**The honest limit.** Trace continuity through MQTT is still unresolved. MQTT 3.1.1 has no user-property header to carry `traceparent`. So there are two options. Either the check-in clients move to MQTT 5, or the context travels inside the payload envelope. We have to decide that before instrumenting. This is because adding trace context later breaks every published client.

</details></li>
</ul>

</details>
