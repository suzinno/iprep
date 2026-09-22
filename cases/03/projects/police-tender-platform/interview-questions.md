# Interview Questions — Tender Platform for a MENA Police Department

> Auto-generated from [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") and system design documents. Questions target stated responsibilities and technical pillars.

## Table of Contents

- [API and Service Design](#api-and-service-design)
- [Data Modeling and Transactional Integrity](#data-modeling-and-transactional-integrity)
- [Asynchronous Processing and Messaging](#asynchronous-processing-and-messaging)
- [Document Intelligence with LangChain and LangGraph](#document-intelligence-with-langchain-and-langgraph)
- [Search and Analytics with OpenSearch](#search-and-analytics-with-opensearch)
- [Identity, Access and Secrets](#identity-access-and-secrets)
- [Cloud Infrastructure, Kubernetes and Delivery](#cloud-infrastructure-kubernetes-and-delivery)
- [Performance, Caching and Observability](#performance-caching-and-observability)

---

## API and Service Design

---

### Q1. The eight services all run on FastAPI with asynchronous handlers. What does that buy this platform, and when would `async def` make a request slower?

**Brief answer**
Async handling lets one worker hold many in-flight requests that are all waiting on something else — [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), S3, OpenSearch or the model endpoint. It stops paying as soon as a handler does real processor work, because that work blocks the event loop for every other request on the same worker.

<details>
<summary><strong>Must cover</strong></summary>

- **input/output bound workload** — almost every hop here is a wait, not a computation
- **event loop** — one blocking call stalls every request on that worker
- **blocking driver inside `async def`** — the mistake that turns async into worse-than-sync
- **processor work belongs in Celery** — parsing, hashing and chunking never run in the request path
- thread pool for plain `def` handlers, connection pool sizing, `run_in_executor`

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Almost nothing in these services computes. A tender listing waits on a PostgreSQL query. Issuing a presigned upload waits on S3. A search query waits on OpenSearch and on an embedding call. When the work is waiting, one process can hold hundreds of open requests at once, and that is what makes the 260 requests per second deadline surge cheap for `document-service`.

The failure comes from mixing the two models. If a handler declared `async def` calls a blocking database driver, the whole event loop stops until that call returns. Every other request on that worker waits too, so p95 latency collapses under load while the processor sits idle. The same is true of processor work: hashing a 55 MB pack or parsing a document inside a request handler would freeze the loop for seconds. That is exactly why parsing, chunking and thumbnailing live in `celery-documents` and never in `document-service` itself.

Two practical rules follow. First, a handler that must call something synchronous is better written as a plain `def` — [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") runs those in a thread pool, so they cannot stall the loop. Second, async concurrency is not free capacity. The database connection pool, summed across all pods, still has to stay under the Postgres connection limit. Otherwise async simply moves the queue from the application to the database.

</details>

---

### Q1. What does Pydantic do in these services beyond validating a request body?

**Brief answer**
[Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") is the type boundary at four separate places: incoming requests, outgoing responses, the settings a pod starts with, and the output of the model pipeline before any artifact is stored. It also generates the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document, so the published contract and the executed contract come from one definition.

<details>
<summary><strong>Must cover</strong></summary>

- **request and response contracts** — one model defines both the check and the published schema
- **OpenAPI generation** — the documentation cannot drift from the code
- **settings validation at startup** — a missing or malformed value fails the pod immediately
- **model output validation** — an artifact that fails the schema never reaches `ready`
- import row validation, one schema shared by Compose and Helm

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The request and response models are the obvious use. The valuable part is that the same models generate the OpenAPI document, which is the Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")) contract the portal teams build against. Documentation written by hand drifts; documentation generated from the objects that actually run cannot.

Settings validation matters more than it sounds. Configuration is environment variables parsed by a Pydantic settings model at startup. A missing secret reference or a malformed queue name kills the pod immediately, instead of raising an error hours later on the first request that needs it. The Docker Compose file and the Helm values share that one schema, so a variable cannot exist locally and be missing in production.

The fourth use is the interesting one. Output from the language model is parsed into a strict Pydantic model before anything is written. A summary claim has to carry a document reference, a page and a character range. If the parse fails, the artifact is quarantined rather than repaired. That turns "the model should cite its sources" from a prompt instruction, which is advice, into a schema rule, which is a gate.

</details>

---

### Q1. Every mutating endpoint takes an `Idempotency-Key` header. What problem does that solve here, and what happens without it?

**Brief answer**
It makes a retried request safe. The client sends a key, the service stores the result against that key in `redis-cache` for 24 hours, and a repeat of the same key returns the stored result instead of performing the write twice.

<details>
<summary><strong>Must cover</strong></summary>

- **retry after an uncertain outcome** — a timeout does not tell the client whether the write happened
- **key scoped to the caller and the operation** — two different requests must never share a key
- **stored result, not just a marker** — the retry gets the original response back
- **24-hour window in `redis-cache`** — long enough for a human retry, short enough to expire
- unique constraints as the second line, the sealing path's one-bid-per-vendor rule

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A vendor on a poor connection presses submit, the response times out, and the client retries. Without idempotency the second request is indistinguishable from a genuine second action. On the bid path that could mean two ledger rows for one bid; on the Customer Relationship Management (CRM) side it means duplicate activity records that someone has to clean up by hand.

The mechanism is simple. The client generates a key per logical action and repeats it on every retry of that action. The service records the key together with the response it produced. A second request with the same key returns the stored response, including its original status code. The key lives in `redis-cache` with a 24-hour expiry, which covers network retries and a person retrying after lunch, without keeping the table forever.

Two things make this honest rather than decorative. The key must be scoped so that two genuinely different requests cannot collide — the same key with a different body is a client error, not a cache hit. And idempotency keys sit in an expendable store, so they are a convenience, not the correctness guarantee. The real guarantee is in the schema: `bid` is unique on `(tender_id, vendor_org_id)`, so even a lost cache cannot produce a second bid for the same vendor on the same tender.

</details>

---

### Q1. The API is versioned at `/v1`. How would you ship a breaking change to the bid submission contract?

**Brief answer**
Not by bumping to `/v2` first. The default is an additive change behind the same version, with the old shape still accepted; a new version is reserved for a change that genuinely cannot be expressed as an addition.

<details>
<summary><strong>Must cover</strong></summary>

- **additive first** — new optional fields, old shape still accepted
- **two populations move at different speeds** — internal portals update, thousands of vendor clients do not
- **a new version means running both** — double the surface to test and audit
- **deprecation with a measured date** — driven by observed traffic on the old shape, not a guess
- response field removal as the real breaking case, usage metrics per field

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Versioning at the path is cheap to declare and expensive to use. The reason is the vendor population: around 14,000 users across 6,000 organizations, many of them using the portal directly and some scripting against it. The internal staff portal can be updated on a release; the vendor side cannot be made to move on a date the platform chooses.

So the first question is whether the change is really breaking. Adding an optional field to `POST /v1/bids/{id}/submit` is not. Making a previously optional field required is. Removing a response field is, and it is the one that catches teams out, because nothing in the request fails — a client quietly reads a missing value and misbehaves later.

When a change is genuinely breaking, `/v2` means running two contracts at once, and that is the cost to be explicit about. Both need contract tests, both need the four authorization checks, and both appear in the audit trail. The sealing path makes this sharper than usual: the submission receipt is legal evidence of a timely bid, so two versions of it must produce identical ledger content or an award becomes arguable. The retirement of `/v1` is then driven by measured traffic per client, with the deprecation notice sent through the same notification path the platform already uses for deadlines.

</details>

---

### Q2. Walk me through `POST /v1/bids/{id}/submit` from the call arriving to the receipt going back. Why is the order what it is?

**Brief answer**
Edge authorization, then a live eligibility check, then a parallel `HeadObject` over every manifest entry, then the advisory lock, the key seal, the ledger append and the commit. Everything that can be done without the lock happens before the lock is taken.

<details>
<summary><strong>Must cover</strong></summary>

- **eligibility read from the primary** — a stale answer would let a debarred vendor bid
- **`HeadObject` fan-out before the lock** — 16 in parallel, the slowest step, deliberately outside the serialized section
- **per-tender advisory lock** — allocates the ledger sequence number, held for tens of milliseconds
- **envelope key sealed at commit** — `kms-bid-custody` generates the per-bid data key
- **`sealed_at` set server side inside the transaction** — the vendor's clock is never consulted
- **outbox write in the same transaction** — the event cannot be lost or published early
- 798 ms worst case against a 1.2 s target, receipt carries the ledger hash

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The gateway validates the token and routes to `bid-service`, which validates it again and runs the four authorization checks. `bid-service` then asks `vendor-service` for an eligibility verdict. That is the only synchronous service-to-service call in the whole platform. It reads the PostgreSQL primary rather than the replica. An out-of-date answer to "may this vendor bid" is a legal defect, not a stale page.

Next comes the expensive part: a `HeadObject` against S3 for every document in the manifest, 16 at a time. A 60-document pack costs about 210 ms here. This confirms every object exists and records its hash into `manifest_entry.sha256`, so an object swapped afterwards is detectable. It runs before the lock on purpose.

Only then does the transaction take a PostgreSQL advisory lock on the tender row. Under the lock, `kms-bid-custody` generates a per-bid data key, the manifest key is sealed, the `submission_ledger` row is appended with its hash chain link, the bid moves to `submitted`, and an `event_outbox` row is written. All of it commits together. `sealed_at` is assigned inside that transaction, which is the definition of being on time — the client's clock never enters the decision.

The ordering is the design. The lock is the only serialized resource on the surge path, and it covers the ledger append alone. That is why the worst case measures around 798 ms against a 1.2 second target, even with 60 documents and contention.

</details>

---

### Q2. `GET /v1/vendors/{id}/eligibility` is documented as "read from the primary, never a replica". Why, and how do you stop someone moving it to the replica next year?

**Brief answer**
Replica lag means a debarment recorded seconds ago may not be visible, and an eligible-looking debarred vendor gets a bid accepted. Documentation alone will not hold the rule, so the session used on that path is bound to the primary in code and asserted by a test.

<details>
<summary><strong>Must cover</strong></summary>

- **replication lag is the whole risk** — a debarment written moments ago
- **the consequence is legal, not cosmetic** — a bid accepted from a debarred vendor invalidates an award
- **separate session bound to the primary** — the reader object differs, not a flag on a call
- **a test that fails if the path touches a replica** — the rule needs a guard, not a comment
- cached values banned on this path too, the rule stated once in the requirements

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The read replica exists to take listing and reporting load off the write node, and for a tender browse a second of lag costs nothing. Eligibility is different. A debarment row written a moment ago decides whether a vendor may submit at all. If the check reads a lagging replica, a debarred vendor's bid is accepted, sealed, and recorded in an append-only ledger that cannot be edited. Undoing that means disqualifying the bid after the fact and defending the decision in a procurement dispute.

Writing "read from the primary" in the design does not stop the regression. What does is making the wrong thing awkward to write. `vendor-service` exposes two session dependencies with different names, and the eligibility repository can only be constructed with the primary one. A developer optimising listing queries will not stumble into changing this, because there is no shared flag to flip.

The second half is a test. The integration suite runs the eligibility call against a database pair with artificial replica lag and a debarment written only on the primary; the call must return `ineligible`. That test fails if someone reroutes the read, which is the point — a rule with no failing case is a convention. The same reasoning bans a cached eligibility answer: `redis-cache` is expendable by construction and nothing on the eligibility, sealing or scoring path may read it.

</details>

---

### Q2. How do you keep the API documentation and the deployment notes from drifting away from what the code actually does?

**Brief answer**
By generating what can be generated and keeping the rest next to the thing it describes. The OpenAPI document comes from the Pydantic models, the infrastructure description is the [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") configuration, and the decisions that neither of those can express are written as short architecture decision records in the repository.

<details>
<summary><strong>Must cover</strong></summary>

- **generate the API reference** — Pydantic models are the one definition
- **the pipeline is the deployment document** — the GitHub Actions workflow is executable, so it cannot be stale
- **decision records for the "why"** — the reasons a schema and a pipeline cannot carry
- **review the record with the change that caused it** — documentation in the same pull request
- onboarding read order, the design set as the entry point, dated open questions

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Three kinds of documentation fail in three different ways, so they get three different answers.

The API reference is mechanical, so it is generated. Pydantic models produce the OpenAPI document at build time, and it is published as a pipeline artifact. Nobody writes an endpoint table by hand, so nobody can forget to update one.

The deployment description is executable. The GitHub Actions workflow and the Terraform configuration are how the system is actually built and released. A reader who wants to know how production is deployed reads the workflow, and a resource that exists without a Terraform declaration is treated as an incident. A separate prose document describing the same steps would be a second owner of the same fact, and the second copy is always the one that goes stale.

What is left is the "why", and that genuinely needs prose. Sealing fails closed when the key service is unavailable. Eligibility is read from the primary. Production is a separate account rather than a namespace. Each of these is a short record naming the decision, the alternatives and the cost accepted. They are reviewed in the same pull request as the change that caused them, which is the only mechanism I have found that keeps them current. For onboarding, the design document set is the entry point and each record links from the part of the system it governs.

</details>

---

### Q2. `POST /v1/ai/proposal-summary` returns a job handle rather than a summary. Explain that choice and what it costs the client.

**Brief answer**
A summarization run takes minutes, so it cannot sit behind a 250 ms read target, and a model outage would otherwise take down the pages that embed it. The client gets an `AiJob` and polls `GET /v1/ai/jobs/{id}`, which is a worse experience and the correct one.

<details>
<summary><strong>Must cover</strong></summary>

- **minutes against a 250 ms target** — the numbers make a synchronous call impossible
- **availability coupling** — a third-party outage would take tender pages with it
- **job handle and poll** — state, then an artifact with citations on success
- **resumable work** — a checkpointed run survives a rate-limit error mid-way
- **`409` while the bid is sealed** — the endpoint refuses before the deadline
- kill switch, no downstream feature depends on the artifact

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The target for proposal summarization is a p95 under three minutes. The read target for ordinary pages is 250 ms. Those cannot share a request. Even if a caller were willing to wait, a synchronous design would mean an evaluator's page holding an open connection for minutes, and a gateway timeout turning a completed run into a lost one.

The availability argument is stronger than the latency one. The model endpoint is a third party outside the department's control. If a page waited on it, an outage there would take out evaluation screens that work perfectly well without any summary. The job model keeps that blast radius to one feature: with `ai.enabled=false`, evaluators read source documents and score exactly as they would without the platform's help.

The client cost is real. Instead of an answer, a caller receives a job handle and polls for state, then receives an artifact whose every claim carries a document, a page and a character range. In exchange the work becomes resumable — a rate-limit error two thirds of the way through a long pack resumes from a checkpoint rather than restarting, and the caller sees no difference. The endpoint also refuses outright with `409` while the bid is still sealed, which is not a scheduling detail but the custody rule: nothing may read bid content before unsealing, including the summarizer.

</details>

---

### Q3. The service boundary rule is that anything which can decide or destroy a submission is separated from anything that merely reads, searches or generates. Defend that against a simpler split of three services.

**Brief answer**
The boundaries buy blast radius and provable custody, not scale — at 70 requests per second nothing here needs eight deployments for throughput. A three-service split would put bid custody in the same process as search and generation, and the sealed-bid guarantee would become a code review rather than a network and identity boundary.

<details>
<summary><strong>Must cover</strong></summary>

- **the boundaries are for custody, not throughput** — the load does not justify them
- **`bid-service` alone holds the key grant** — a separable identity is what makes that enforceable
- **`ai-service` alone has model egress** — a network policy, not a rule in a review checklist
- **segregation of duties as a boundary** — evaluation is separate from tender authoring
- **the cost is honest** — more deployments, more dashboards, one synchronous call that must not fail
- twelve deployments to operate, a small backend team, event-carried copies instead of chatty calls

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Start with the honest part: throughput does not justify this. The modelled load is 25 requests per second baseline and 70 at ordinary peak. One well-built service would serve that. So the split has to earn its keep somewhere else, and it does, in two places.

The first is custody. Only `bid-service` holds the Identity and Access Management (IAM) role that the bucket policy on the `bids/` prefix permits, and only its role holds a grant on `kms-bid-custody`. That is enforceable precisely because it is a separate deployment with its own identity. Merge it into a general "core" service and every code path in that service inherits the ability to read sealed bids. The guarantee becomes "no developer wrote that call", which is not a guarantee.

The second is model egress. `ai-service` and `celery-ai` are the only workloads with a route to the internet, through one egress-controlled subnet. As a separate deployment that is a network policy. Inside a merged service it would be a convention, and the platform sends police procurement documents to a third party, so the difference matters.

Segregation of duties is the third piece: evaluation is not a role check inside the tender service, it is a different service with different data access.

The cost is real and worth stating. Twelve deployments, three asynchronous mechanisms, and one synchronous dependency — sealing calling eligibility — that has to be available during the busiest minute of the tender. I would defend the current split, and I would not defend adding a ninth service without a custody or egress argument behind it.

</details>

---

### Q3. API Gateway validates the token, and then every service validates it again. Is that not redundant work on every request?

**Brief answer**
It is deliberate duplication. The gateway is a filter that rejects obvious garbage at the edge. The service is the authority, for two reasons: a request can reach a pod without passing the gateway, and only the service knows what the token permits for this specific row.

<details>
<summary><strong>Must cover</strong></summary>

- **the gateway is a filter, not the authority** — it rejects bad tokens early and cheaply
- **the edge cannot see the row** — tenant scope and evaluator assignment need the database
- **network position is not identity** — a pod reachable inside the cluster must still check
- **the cost is small and cached** — signature checks against keys held in `redis-cache`
- mutual authentication between services, the four ordered checks, defence in depth without a second owner of the rule

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The gateway does what an edge can do well. It checks that a [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Token ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties")) is present, correctly signed by the right user pool, unexpired, and aimed at an audience this API serves. Rejecting there keeps junk traffic off the cluster during a deadline surge, and it is cheap because the signing keys are cached.

What the edge cannot do is authorize. Three of the four checks need data. Tenant scope compares the token's `org` claim to a row's `vendor_org_id`. The assignment check asks whether an `evaluator_assignment` row links this person to this tender's session, whether the session is past unsealing, and whether a recusal exists. None of that is in the token, and putting it there would mean a token that goes stale the moment a recusal is filed.

The second reason is architectural. Being inside the cluster is not an identity. Services accept traffic under a strict mutual authentication policy, so a workload without a valid identity cannot even connect, but a valid workload could still forward a request. If the service trusted the gateway's verdict, one routing mistake would mean unauthenticated access to bid metadata.

So the duplicated part is only the signature check, which is a few milliseconds against locally cached keys. The valuable part — who may see this row, right now — happens once, in the only place that can answer it.

</details>

---

### Q3. At ten times the tender volume, which part of this API surface breaks first, and what do you do about it?

**Brief answer**
Not the read paths and not the uploads. The first thing to bend is the eligibility read on the primary during a surge, and close behind it the analytics endpoints that aggregate across a corpus grown tenfold.

<details>
<summary><strong>Must cover</strong></summary>

- **reads and uploads scale flatly** — replicas, edge caching and presigned uploads already absorb growth
- **eligibility on the primary** — every sealing call adds load to the write node
- **the advisory lock stays per tender** — more tenders means more locks, not more contention
- **analytics is the second strain** — aggregation moves off Postgres onto the corpus
- **what I would measure before changing anything** — lock wait time, primary connection saturation, sealing p95
- a debarment cache with a hard invalidation as a last resort, not a first move

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Growth here is mostly benign, which is worth saying before naming a bottleneck. Ten times the tenders means ten times the browsing, and browsing is served from a replica and an edge cache. Ten times the uploads costs the platform almost nothing, because bytes go straight to S3 under a presigned Uniform Resource Locator ([URL](https://datatracker.ietf.org/doc/html/rfc3986 "Addresses the location and access method of a resource on the web")) and never cross the API. The advisory lock is taken per tender, so ten tenders closing together contend on ten different locks, not one.

The pressure lands on the primary. Every sealing call makes a live eligibility read there, by design, and the primary also carries every domain write. At ten times the volume that is the node to watch. Three measurements matter: connection pool saturation summed across pods, lock wait time on the tender row, and sealing p95 during a closing window.

My first move would be capacity and pooling, not architecture: a larger write instance and a connection pooler in transaction mode, because most of these connections are idle between statements. The second, which the design already names, is to move analytics aggregation off Postgres onto `opensearch-corpus`, which holds the same dimensions and is rebuildable.

What I would resist is caching the eligibility verdict. It is the one read the design deliberately keeps live, and trading that for primary load reintroduces exactly the failure the rule exists to prevent.

</details>

---

### Q3. The department asks for a read-only API so other government systems can pull tender notices. What changes?

**Brief answer**
The data is easy — published notices are already public and already cached at the edge. The work is in a third identity model, a separate rate-limiting and quota story, and a contract that a consuming system can depend on for years.

<details>
<summary><strong>Must cover</strong></summary>

- **a third principal type** — neither staff nor vendor, so neither user pool fits
- **machine credentials and quotas** — API keys with usage plans, not interactive sign-in
- **exposure is the published version only** — drafts, bids, scores and CRM records stay invisible
- **a stable contract** — a consuming department cannot be asked to migrate on our schedule
- **cache and isolate the path** — a partner integration must not compete with the submission path
- conditional requests, a change feed rather than repeated full scans

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The content question is the small one. A published tender version is already a frozen, public artifact, and the notice board is already cached at CloudFront. Exposing it costs almost nothing in data terms.

Identity is where the design actually changes. The platform has exactly two populations today, staff and vendor, in two separate user pools, and the account type claim is the first authorization check. A machine consumer is a third kind of principal. I would not stretch the vendor pool to hold it — the whole point of two pools is that a group or audience mistake cannot cross the boundary that matters. A separate client-credentials flow, with API keys and usage plans at the gateway, keeps quota and throttling per consumer and keeps the new principal out of the existing checks.

The second change is contractual. An internal portal can be updated with a release. A finance system in another department cannot, so this surface has to be additive for a long time, with a deprecation process measured in quarters. I would expose a change feed rather than inviting full scans, and support conditional requests so a polling consumer is cheap.

The third is isolation. This traffic must never compete with the submission path during a closing window. That means its own gateway stage, its own throttle, and a dashboard that shows partner traffic separately, so a misbehaving integration is visible as itself rather than as unexplained load.

</details>

---

## Data Modeling and Transactional Integrity

---

### Q1. SQLAlchemy is used as an Object Relational Mapper for domain writes but as Core for reporting queries. Why the split?

**Brief answer**
Domain writes are small, well-shaped object graphs where mapping and unit-of-work tracking save real work. Reporting and search-adjacent queries are shaped by the query plan, and an Object Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Maps application objects to relational database rows and queries")) hides exactly the part you need to control there.

<details>
<summary><strong>Must cover</strong></summary>

- **unit of work** — one flush, ordered inserts, relationships maintained for you
- **identity map and lazy loading** — helpful on a write path, a source of hidden queries on a read path
- **Core gives you the statement you wrote** — joins, aggregates and window functions stay visible
- **the plan is the product on reporting queries** — the index chosen matters more than the object shape
- explicit loader options, `EXPLAIN` against the real statement, no surprise round trips

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A sealing transaction writes a bid row, a manifest, a set of manifest entries, a ledger row and an outbox row. That is a small graph with real relationships, and the unit-of-work pattern earns its place: objects are tracked, inserts are ordered by dependency, and one flush writes them in the right sequence inside the transaction.

Reporting is the opposite shape. A cycle-time report groups across tenders, versions and awards. Written through the ORM it becomes a series of object loads, and the lazy-loading behaviour that is convenient on a write path turns into a query per row that nobody asked for. Worse, the generated statement is at one remove, so when the plan goes wrong you are tuning through a translation layer.

With Core the statement is the thing you wrote. You can read it, run `EXPLAIN (ANALYZE, BUFFERS)` against exactly what the application sends, and see which index was used. On the queries where the plan is the product — analytics, the ledger verification walk, the outbox relay poll — that visibility is worth more than object mapping.

The rule I would state to a team is narrow: use the ORM where the result is a domain object you will modify, use Core where the result is a report you will serialize. On the ORM side, set loader options explicitly rather than relying on defaults. A lazy load inside a loop is the most common way a fast endpoint becomes slow without anyone changing a query.

</details>

---

### Q1. What is an expand/contract migration, and why is it the only pattern Alembic runs here?

**Brief answer**
Expand adds the new shape without removing the old one, the application moves over, and contract removes the old shape in a later release. It is the only pattern here because migrations run as a job before the rollout, so the previous image must keep working against the new schema.

<details>
<summary><strong>Must cover</strong></summary>

- **three phases across releases** — add, migrate the code, remove later
- **migration runs before the rollout** — old pods meet the new schema first
- **rollback is a redeploy** — no schema reversal is ever required
- **a destructive step in one release breaks the rollback** — dropping a column strands the old image
- adding a column nullable then backfilling, dual writes during the middle phase

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Renaming a column looks like one change. In a rolling deployment it is three. The [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") job runs as a [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") `Job` before any new pod starts, so for a period the old image is talking to the new schema. A rename executed in one step means every running pod is querying a column that no longer exists.

Expand/contract splits it. First release: add the new column, keep the old one, write to both, read from the old. Second release: read from the new column. Third release, once nothing reads the old one: drop it. Each step leaves both the current and the previous image able to run.

The property this buys is the one that matters during an incident. Rollback is simply a redeploy of the previous image tag. Nobody has to reason at two in the morning about whether a down migration will destroy data, because there is no down migration on the critical path — the schema only ever grew.

The pipeline checks this rather than trusting it. One stage runs an Alembic upgrade and then a downgrade against a restored copy of the staging schema, so a migration that quietly breaks the discipline fails a build instead of a deployment. On a table like `audit_event`, which is partitioned and large, the same thinking extends to how the change is applied. Add the column nullable, backfill in batches, then add the constraint. The alternative is one statement that holds a lock while it rewrites the table.

</details>

---

### Q1. Primary keys are UUIDs generated by the application, not by the database. What does that buy and what does it cost?

**Brief answer**
It gives a row an identity before it is inserted, which lets one transaction build a whole object graph and lets a client retry safely. The cost is index locality: random keys scatter writes across the index instead of appending to one end.

<details>
<summary><strong>Must cover</strong></summary>

- **identity before insert** — the graph can reference itself without a round trip
- **safe retries and idempotency** — the same identifier on a repeat, not a second row
- **no cross-store identifier gap** — the same key names the row, the S3 object and the search chunk
- **random keys hurt index locality** — page splits and a larger working set than a sequential key
- time-ordered variants as the mitigation, the human-facing reference number kept separate

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A sealing transaction writes a bid, a manifest, several manifest entries, a ledger row and an outbox row, and they all reference each other. With database-generated keys that means insert, read back, insert again. With application-generated identifiers the whole graph is built in memory and written in one flush. That is simpler and it is fewer round trips inside the most latency-sensitive transaction in the system.

It also matters across stores. A document identifier names a row in PostgreSQL, an object key under `s3-documents`, and a chunk prefix in `opensearch-corpus`. Generating that identifier in the application means all three agree from the beginning, with no step where a row exists but its object key is not yet known.

The cost is real and physical. A B-tree on a random key means each insert lands on an arbitrary page, so the hot part of the index is the whole index rather than its right-hand edge. On a table taking constant inserts, that shows up as page splits and more pages in memory than a sequential key would need. At this volume — about 130 GB over five years — it is affordable, and I would measure before changing anything. If it did bite, the fix is a time-ordered identifier variant, which keeps the "identity before insert" property while restoring locality.

One thing the identifier is not is the human-facing reference. `tender.reference_no` in the form `T-YYYY-NNNNN` exists for exactly that, because nobody reads a tender number aloud in a committee meeting.

</details>

---

### Q1. What is a PostgreSQL advisory lock, and why is one used in the sealing transaction rather than locking the tender row?

**Brief answer**
An advisory lock is a named lock the application takes for its own purposes; the database enforces it but attaches no meaning to it. It is used here because what needs serializing is the allocation of the next ledger sequence number, not any change to the tender row.

<details>
<summary><strong>Must cover</strong></summary>

- **application-defined, database-enforced** — a lock on a number, not on a row
- **what is serialized is sequence allocation** — the chain must be totally ordered per tender
- **a row lock would say the wrong thing** — sealing does not update the tender
- **scoped per tender** — ten tenders closing together contend on ten locks
- **held for the append only** — tens of milliseconds, after the object checks
- transaction-scoped release, 380 ms worst case under contention

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The submission ledger is a hash chain: each row stores the previous row's hash, and `seq` is unique per tender. For that chain to be verifiable, two bids for the same tender must never take the same sequence number or compute their link from the same predecessor. Something has to serialize that step.

A row lock on `tender` would do it, but it would lie about intent. Sealing does not modify the tender; taking `SELECT ... FOR UPDATE` on it means any future code that legitimately locks that row for a real update now contends with sealing, and the reason is invisible in the schema. An advisory lock keyed on the tender identifier names the actual invariant: one sealing at a time per tender.

The scope matters twice over. It is per tender, so a closing window with ten tenders ending at the same minute produces ten independent locks and no global serialization point. And it is transaction-scoped, so it is released at commit or rollback without cleanup code — a crashed pod does not leave a tender unsealable.

The last property is how briefly it is held. Everything expensive happens before it: the eligibility check and the parallel `HeadObject` fan-out across manifest entries. Under the lock there is a key generation call, an insert and a state change. The measured worst case for lock acquisition under surge contention is around 380 ms, and the whole sealing path still finishes well inside its 1.2 second target.

</details>

---

### Q2. Explain the submission ledger hash chain. What attack does it stop, and what does it not stop?

**Brief answer**
Each row stores the previous entry's hash, so `entry_hash` covers the whole history of that tender. Rewriting any past row changes every hash after it, and the chain head is mirrored to storage under Object Lock that nobody can rewrite. It stops silent tampering; it does not stop a wrong value being written in the first place.

<details>
<summary><strong>Must cover</strong></summary>

- **each hash covers its predecessor** — one edit invalidates the whole tail
- **append-only grants** — no application role holds update or delete on the table
- **the head is mirrored to Object Lock storage** — a database administrator cannot rewrite the copy
- **verification is a recomputation** — nightly and on demand, with a mismatch paged as a security incident
- **what it does not cover** — a correctly signed but wrong entry, or a bid never submitted at all
- Object Lock in compliance mode, the ordering supplied by the advisory lock

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Each ledger row holds `prev_hash` and `entry_hash`, where the entry hash is computed over the previous hash plus the tender, the sequence number, the bid, the manifest hash and `sealed_at`. Because every hash includes its predecessor, altering row 3 of a tender changes row 3's hash, which invalidates row 4, and so on to the head. There is no way to edit one row quietly.

Three things turn that arithmetic into a control. No application role has `UPDATE` or `DELETE` on the table, so the ordinary path cannot rewrite history at all. The chain head is published to an audit topic on every append. It is written into an object store prefix under Object Lock in compliance mode. Not even an account administrator can replace it during the retention window. And the chain is recomputed on a schedule and compared against that mirrored head; a mismatch pages the security lead and is handled as a security incident rather than a data quality ticket.

What it does not do is equally important to say in an interview. The chain proves that what was recorded has not changed. It does not prove the record was correct when written. If a service wrote the wrong manifest hash, the chain faithfully protects the wrong value. It also says nothing about a bid that was never accepted — a vendor whose submission failed during a failover has no ledger row, and the chain is perfectly consistent without them. That gap is covered elsewhere: by the sealing failure alerts, by the grace window for a transaction that started before the deadline, and by audit events recorded on rejected attempts.

</details>

---

### Q2. Criteria weights must sum to 1.0000 when a tender is published, enforced by a deferred constraint trigger. Why deferred, and why in the database at all?

**Brief answer**
Deferred because the rule is about the finished set, not about any single row — during an edit the set is legitimately unbalanced. In the database because the rule decides an award, and every path that writes criteria has to obey it, including a migration or a repair script.

<details>
<summary><strong>Must cover</strong></summary>

- **the invariant is over a set** — no individual row can be judged
- **checked at commit, not per statement** — an intermediate state is allowed
- **the rule survives paths the service does not own** — scripts, imports, future services
- **weights decide the weighted total** — a broken set makes an award arguable
- **pass/fail criteria are excluded** — they carry no weight in the sum
- application-side validation kept for the error message, not as the guarantee

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Consider an officer editing a criteria set: they lower one weight from 0.4 to 0.3 and raise another from 0.2 to 0.3. Between those two statements the set sums to 0.9. An immediate check would reject a perfectly valid edit and force the client to submit the whole set in a shape the database dictates. Deferring the check to commit time means the intermediate state is allowed and only the outcome is judged, which is what the business rule actually says.

Putting it in the database rather than in the service is a question about who else can write. The service is not the only writer over a system's life: there are data repair scripts, a bulk import path, migrations and, eventually, a second service. Every one of them can forget a validation that lives in application code. None of them can get past a constraint trigger.

The weight matters because it feeds `consensus_scorecard.weighted_total`, and that number, with its recorded `formula_version`, is what an award is justified by. A set that sums to 0.9 does not fail loudly — it quietly produces totals that are all scaled down, which nobody notices until a losing vendor's lawyer recomputes them.

The detail worth naming is the exclusion: criteria with a `pass_fail` scale are not part of the sum, because they gate rather than score. And the service still validates the same rule before submitting, not as the guarantee but so the officer gets a clear message instead of a database error.

</details>

---

### Q2. Walk me through the indexes on the sealing path. Why is the debarment index singled out as the one whose plan is verified in continuous integration?

**Brief answer**
Sealing touches four tables and depends on a small number of indexes, but only one of them is a range query whose plan the planner might reasonably get wrong. The debarment check asks whether a vendor is debarred right now, and a range predicate on a small table is exactly where a sequential scan can be chosen and nobody notices.

<details>
<summary><strong>Must cover</strong></summary>

- **the unique constraint is the guard** — one bid per vendor per tender, enforced by the index
- **the ledger index serves verification, not the write** — the chain walk reads in sequence order
- **the debarment check is a range predicate** — two open-ended comparisons on an effective window
- **a small table invites a sequential scan** — correct in staging, wrong at production size
- **`EXPLAIN` in the pipeline against production-sized data** — an assertion, not an inspection
- a range column with a suitable index as the fallback, the equality-then-range column order

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The sealing transaction is deliberately narrow. It reads the tender row, checks eligibility, writes to `bid`, `bid_manifest`, `manifest_entry`, `submission_ledger` and `event_outbox`. Most of those are served by a primary key, or by a unique constraint doing double duty. `bid (tender_id, vendor_org_id)` is unique, which is both the lookup and the rule that a vendor cannot submit twice. `submission_ledger (tender_id, seq)` is unique too, and it is what makes the verification walk read the chain in order rather than sorting it.

The debarment check is different in kind. It asks whether a debarment exists for this vendor whose effective window contains the current moment. That is an equality on the vendor plus two range comparisons, and range predicates are where a planner's estimate matters. On a debarment table holding a few hundred rows, a sequential scan is genuinely cheaper, so a test environment will happily report a plan that is nothing like production's. The query also has to be written as two explicit range predicates; expressed as a single comparison against the current time, the planner may not push it down at all.

So the pipeline asserts the plan rather than trusting it. A stage runs `EXPLAIN (ANALYZE, BUFFERS)` against a seeded, production-sized table and fails the build if the expected index is not used. That is the honest version of "we have an index on it". If the plan does turn out to be wrong at scale, the fallback is a range-typed column with an index built for ranges, which the design already names rather than discovering under load.

</details>

---

### Q2. `audit_event` is monthly range-partitioned, and the design says indexes are created on each partition rather than on the parent. What is the reasoning?

**Brief answer**
Creating an index on the partitioned parent applies it to every partition in one operation, and that operation cannot be run without blocking writes the way a concurrent build can on an ordinary table. Per-partition creation lets the live month be indexed concurrently and lets old months be detached and archived without dragging a parent-level definition along.

<details>
<summary><strong>Must cover</strong></summary>

- **a parent index is a definition applied to every child** — one statement, every partition rebuilt
- **concurrent builds are not available at the parent level** — the live table would block
- **only the recent partitions need the index** — old months are detached and exported
- **detach stays cheap** — a partition leaving does not renegotiate a parent definition
- **partition pruning does the coarse filtering** — the index only has to serve within a month
- actor and subject lookups, monthly range on the timestamp, retention governed elsewhere

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Range partitioning by month is here for two reasons. Audit queries are nearly always time-bounded, so the planner prunes to one or two partitions before it reads an index at all. And retention becomes a detach instead of a delete over a table that only ever grows.

Index creation interacts with both. Declaring an index on the partitioned parent creates it on every existing partition as one operation, and it is not available in the non-blocking form that an ordinary table allows. This table receives an insert for every state transition, every authorization denial and every bid document access. Blocking writes on it to rebuild five years of monthly partitions is not something to do during business hours. Creating per partition means the current month is indexed concurrently and the old ones are left as they are.

The second reason is lifecycle. Partitions older than twelve months are detached and exported to the audit sink. A partition that carries its own indexes detaches as a self-contained table, which is exactly what you want to hand to an archive. If the definition lived on the parent, every detach and attach would have to reconcile against it.

The indexes themselves follow the two questions that get asked: what did this actor do, and what happened to this subject. So each partition carries an actor-and-time index and a subject-and-time index. The retention floor is how long these must be kept at all. That is a legal question, not a schema one. The design defers it to the department's legal office rather than assuming a number.

</details>

---

### Q3. Nothing in this design is sharded, and the document insists that is a decision rather than an omission. Defend it, and tell me what would change your mind.

**Brief answer**
The volume is around 130 GB over five years, with a peak under 300 requests per second. At that size a single Multi-AZ instance with one read replica is the right answer. Sharding would also make the ledger's per-tender ordering substantially harder to guarantee. The triggers that would change it are named in order, and none of them is "the data got big".

<details>
<summary><strong>Must cover</strong></summary>

- **the numbers do not call for it** — five-year volume sits comfortably on one node
- **sharding fights the ledger** — a totally ordered chain per tender is easier with one writer
- **cross-shard transactions would appear on the sealing path** — the one path that must stay atomic
- **first trigger is replica saturation** — move analytics aggregation onto the corpus
- **second is sustained write throughput or data volume** — partition the two largest tables first
- **third is a second tenant** — the only case where partitioning by organizational unit is right
- a second department is explicitly out of scope, operational cost of a distributed write path

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The estimate is about 40 GB of transactional rows over five years, plus roughly 90 GB of partitioned audit and ledger history. The ordinary peak is 70 requests per second, with a deadline surge near 260. That is a single well-provisioned node with room to spare. Sharding at that size buys nothing measurable and costs a great deal.

The specific cost here is the submission ledger. Its guarantee is a totally ordered hash chain per tender, allocated under one advisory lock inside one transaction. With a single primary that is a short lock and a local insert. Spread across shards it becomes a distributed ordering problem. The sealing transaction also writes the bid, the manifest, the entries and the outbox row. All of that would become a distributed transaction on the platform's most correctness-critical path. Trading an atomic commit for a coordination protocol to solve a capacity problem that does not exist is a poor bargain.

The triggers are ordered by which pressure appears first. Read replica saturation on analytics comes first, and the answer is not sharding but moving those aggregations onto `opensearch-corpus`, which already carries the dimensions. Next comes sustained write throughput around 2,000 transactions per second, or a data volume past roughly 1.5 TB. At that point `score` and `crm_activity` get partitioned by year. Partitioning, not sharding, because it keeps one writer. Only a second department, explicitly out of scope today, makes horizontal partitioning by organizational unit the right answer, and that is a tenancy change rather than a scale one.

I would add one operational point. Sharding also multiplies the failure modes an on-call engineer has to reason about during a closing window, and this is a backend team, not a platform team.

</details>

---

### Q3. What is the transactional outbox pattern, and why not just publish to Kafka inside the request?

**Brief answer**
The event is written to an `event_outbox` row in the same transaction as the domain change, and a relay publishes it afterwards. Publishing inside the request would mean two systems and no shared transaction, so a crash between them either loses an event or announces something that never committed.

<details>
<summary><strong>Must cover</strong></summary>

- **the dual-write problem** — a database commit and a broker publish cannot be made atomic
- **the outbox row commits with the domain change** — one transaction, one outcome
- **a relay publishes and marks the row** — a crash yields a duplicate, never a loss
- **consumers are keyed on aggregate and version** — duplicates are idempotent by construction
- **the broker stops being on the write path** — a broker outage delays projections, it never fails a write
- the partial index on unpublished rows, replay after a cluster loss

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The problem is that a domain change lands in PostgreSQL and the event announcing it lands in [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing"), and no transaction spans both. Publish before the commit and a rollback leaves an event claiming a bid was submitted when it was not. Publish after the commit and a crash in between loses the event silently — the bid exists, the search projection never hears about it, and the audit sink has a gap.

The outbox removes the second system from the decision. The event is a row in `event_outbox`, written in the same transaction as the bid and the ledger entry. Either everything commits or nothing does. A separate relay then reads unpublished rows, publishes them and marks them as published.

The remaining failure is a crash between publishing and marking, which re-publishes the same event later. That is deliberate: the pattern converts a possible loss into a possible duplicate, and duplicates are solvable. Every event carries `(aggregate_kind, aggregate_id, aggregate_version)` with a uniqueness constraint behind it, so a consumer that has already applied version 7 ignores a second copy.

The operational payoff shows up in the failure table. If the Kafka cluster is lost, projections and notifications lag and the outbox retains everything, but no domain write fails. That is the property worth protecting: a vendor must be able to submit a bid during a broker incident, because the deadline does not move for infrastructure.

The relay's scan cost is kept proportional to the backlog rather than to history by a partial index over rows whose published timestamp is still null.

</details>

---

### Q3. The platform is deliberately consistent for anything that decides and available for anything that informs. Where does that line get hard to hold?

**Brief answer**
The line is clean where it was drawn — eligibility, sealing, scoring and awards read PostgreSQL; search, analytics, notifications and generated artifacts are projections. It gets hard when a convenient projection starts answering a question that decides something, and the two cases here are search-driven shortlisting and analytics used to justify a decision.

<details>
<summary><strong>Must cover</strong></summary>

- **the stated rule** — no eventually consistent store answers eligibility or scoring questions
- **the pressure comes from product requests** — a projection is faster and already has the data
- **shortlisting from search** — ranking that looks advisory and becomes a filter
- **analytics in an award justification** — a lagging number quoted as a fact in a decision
- **generated artifacts are advisory by construction** — citation-validated and never an input
- **how to hold the line** — separate the store per question, not per screen
- the 30-second lag budget, the primary read that costs write-node load

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The split itself is not difficult to implement. Anything that decides an outcome lives in one PostgreSQL primary and is read there, refusing writes during a partition rather than accepting a divergent one. Anything that informs is a projection rebuilt from the event log with a 30-second lag budget.

The difficulty is social. A projection is faster, already aggregated, and always looks like a reasonable source. Two requests reliably arrive. The first is shortlisting: rank the bids by relevance to the requirement pack, so the committee has somewhere to start. That is advisory until someone hides the rest of the list behind a "show all" link, at which point a lagging, approximate index has become an eligibility filter. The second is analytics in the award justification. A participation or spend figure is pasted into a document that will be read in a dispute. It came from a store that may be 30 seconds behind, and that is rebuildable rather than authoritative.

Generated artifacts sit in the same category and are handled structurally. Every claim resolves to a document, a page and a character range, and no artifact is ever an input to a score, an eligibility verdict or an award. The kill switch exists so the platform is fully usable without any of it.

The way I hold the line is to separate by question rather than by screen. A screen may absolutely mix both, as long as each number names its source: this ranking is advisory and may lag, this eligibility verdict was read live from the primary. What is not allowed is a single number whose provenance nobody can state. That discipline costs extra load on the write node for eligibility reads, and the design accepts it in writing.

</details>

---

### Q3. The database fails over during the closing minute of a tender. What does a vendor see, and what would you change?

**Brief answer**
For roughly 60 to 120 seconds writes are refused, so a sealing attempt returns `503` with a `Retry-After` rather than a fabricated receipt. The grace window saves the vendor: a transaction that started before the closing time is still on time when it commits after it.

<details>
<summary><strong>Must cover</strong></summary>

- **Multi-AZ failover is 60 to 120 seconds** — writes rejected, not accepted and lost
- **sealing fails visibly** — a `503` with `Retry-After`, never a silent success
- **the grace window covers the gap** — start time before the deadline decides lateness
- **both timestamps are recorded** — the ledger carries start and seal, so the decision is reviewable
- **the client must retry with the same idempotency key** — one bid, not two
- **what I would add** — a queued submission intent, rehearsed in a restore drill
- alerting on sealing 5xx while a window is open, failover as a paging event

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Automatic failover on a Multi-AZ instance takes roughly one to two minutes, and during it writes are rejected. That is the correct behaviour for this platform. A bid accepted without a ledger row is worse than a bid visibly refused. The vendor can act on a refusal, and cannot act on a silent loss. The vendor sees a `503` with a `Retry-After` header, and the portal should show it as "submission not yet recorded, retrying" rather than an error page that invites them to start again.

The part that makes this survivable is the grace window. Sealing accepts a commit whose transaction started before the tender's closing time, and the ledger records both timestamps. Without it, a submission that began at one second to midnight and committed after a failover would be rejected. The reason would be entirely outside the vendor's control, and that is the kind of decision that ends up in a procurement dispute.

Operationally, a failover during an open window is a paging alert, as is any sealing `5xx` while a tender is open. Retries carry the same idempotency key. A retry that succeeds after the original actually committed returns the original receipt, rather than producing a second bid. The unique constraint on `(tender_id, vendor_org_id)` is the backstop if the cache is gone.

If the department wanted a stronger promise, I would add a durable submission intent. Record the attempt with its start time on a path that survives a primary outage. Then complete the seal when writes return. That is real work and it moves part of the custody story onto a second store, so I would want the requirement in writing first. What I would not do is widen the grace window as a substitute — that turns a technical failure into a permanently looser deadline, and the deadline is the product.

</details>

---

## Asynchronous Processing and Messaging

---

### Q1. There are two Redis instances, `redis-cache` and `redis-broker`. Why not one?

**Brief answer**
Because they have opposite failure behaviour. The cache is expendable and every key in it has a source of truth elsewhere; the broker holds work that has been accepted and not yet done. Sharing one instance lets a task backlog evict cached values, and lets a cache flush drop queued work.

<details>
<summary><strong>Must cover</strong></summary>

- **opposite value of the data** — expendable keys against accepted work
- **memory pressure crosses over** — a backlog evicts cache entries, or eviction drops tasks
- **eviction policy cannot suit both** — a cache wants to discard, a broker must not
- **different durability settings** — the broker persists to an append-only file, the cache need not
- **blast radius during an incident** — a flush to recover latency would destroy queued work
- separate sizing, separate dashboards, cache loss as a latency event only

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The two roles want contradictory configuration. A cache should evict under memory pressure — that is the behaviour that keeps it useful. A broker must never evict, because an evicted message is a document that will never be scanned or a scoring job that will never run.

Put them on one instance and the interaction shows up exactly when you least want it. A bulk import queues tens of thousands of tasks, memory fills, and the eviction policy starts discarding the least recently used keys. Depending on which keys those are, either the tender listings go cold and every request falls through to PostgreSQL during a closing window, or queued tasks disappear with no error anywhere.

The reverse direction is just as bad. During an incident, flushing a cache is a normal recovery step — it is safe precisely because every cached value can be rebuilt. If the broker shares the instance, that routine action destroys accepted work.

So they are separate instances with separate settings. `redis-broker` runs with append-only file persistence and replication across availability zones, so tasks in flight survive an instance loss and are re-delivered; that re-delivery is safe because every task is idempotent. `redis-cache` needs none of that — losing it entirely is a latency event with no correctness impact, and the design says so plainly.

</details>

---

### Q1. What does a visibility timeout do in Amazon SQS, and what is a dead-letter queue for?

**Brief answer**
A visibility timeout hides a message from other consumers while one consumer works on it; if that consumer does not delete the message in time, it becomes visible again and someone else picks it up. A dead-letter queue (DLQ) catches a message that has failed that cycle too many times, so a poison message stops circulating and becomes visible to a human.

<details>
<summary><strong>Must cover</strong></summary>

- **the message is hidden, not removed** — deletion is the consumer's acknowledgement
- **a crash means redelivery, not loss** — the timeout expiring is the recovery mechanism
- **the timeout must exceed the real work time** — too short means duplicate processing
- **the DLQ ends the retry loop** — after a set receive count, the message is set aside
- **a DLQ with anything in it is a signal** — any message here raises a ticket
- long polling, extending the timeout on a long-running job

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A consumer receives a message and the queue makes it invisible for the visibility timeout. Processing ends with an explicit delete, which is the acknowledgement. If the pod is evicted, the process crashes, or the work simply takes longer than the timeout, the message becomes visible again and another consumer takes it. Nothing is lost; that is where the at-least-once guarantee comes from.

Two mistakes follow from that mechanism. If the timeout is shorter than the real work, the message reappears while the first consumer is still busy, and the job runs twice concurrently. On this platform a model summarization job can run for minutes. That is one of the reasons `celery-ai` is brokered by SQS at all. The timeout can be set to match, and extended while work is in progress. If the timeout is far too long, a genuine crash leaves work stalled until it expires.

The dead-letter queue handles the message that will never succeed. A corrupt archive that crashes the parser will fail, reappear, fail again, and occupy a consumer forever. After a configured number of receives the queue moves it to `sq-document-intake-dlq` or `sq-ai-jobs-dlq` and stops re-delivering it.

What makes the DLQ useful here is that its depth is alerted on. Any message in either dead-letter queue raises a ticket. The point of a dead-letter queue is not storage. It is that a poison message becomes something a person can see, instead of an invisible retry loop burning worker capacity during a tender window.

</details>

---

### Q1. Why does `fn-object-intake` run as a Lambda function on the S3 event rather than as a poller inside `document-service`?

**Brief answer**
Upload completion is a notification from S3, not a request from a user, and the work is a few hundred milliseconds of validation. A function triggered by `ObjectCreated` scales with the surge on its own and costs nothing between tenders, while a poller would be a deployment to run, scale and watch for the same result.

<details>
<summary><strong>Must cover</strong></summary>

- **the event source is S3, not a client** — nobody is waiting for the answer
- **it scales with the surge automatically** — hundreds of concurrent objects, no pre-scaling
- **the work is short and stateless** — checksum, size and declared type validation
- **it hands off to a queue, not to a database** — the function's output is a message
- **keeping it off the request path protects the surge** — the API never sees the upload completing
- narrow role permissions, magic-byte and expansion-ratio checks at this step

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The upload itself never touches the platform. A vendor receives presigned multipart URLs and writes the bytes straight to `s3-documents`. That is what makes a tenfold deadline surge affordable, and it means the platform learns that an object exists only from S3's own notification.

A Lambda function fits that shape exactly. It is triggered per object, it runs for a few hundred milliseconds, and it holds no state. During a closing window several hundred objects may land in the same minute, and the function scales to that without anyone raising a replica floor. Between tenders it costs nothing. A poller inside `document-service` would need to be scaled for the same peak. It would put that load on a deployment that is simultaneously issuing presigned URLs. That is the one call which must stay fast during the surge.

The function's job is deliberately small. Validate the checksum against what the client declared, and check the size. Confirm the magic bytes match the declared content type. Reject an archive whose declared expansion ratio looks like a decompression attack. Then it enqueues onto `sq-document-intake`, and `document-service` picks the work up for scanning, extraction and chunking.

That handoff is the second reason for the split. The function writes to a queue rather than to the database. So it needs a very narrow role: read the object's metadata, send one message. It also means a spike in uploads becomes queue depth. Otherwise it would become a wave of database connections from a function that scales faster than PostgreSQL can accept them.

</details>

---

### Q1. What makes a Celery task idempotent, and why does every task in this system have to be?

**Brief answer**
An idempotent task produces the same end state whether it runs once or five times, usually by keying its work on something stable and checking for the result before doing it again. Every task here needs it because both brokers deliver at least once, so redelivery after a crash is normal operation rather than an error.

<details>
<summary><strong>Must cover</strong></summary>

- **at-least-once delivery is the baseline** — a broker restart or a lost acknowledgement re-runs a task
- **key the work on stable input** — content hashes and identifiers, not a generated value
- **check before acting** — read the current state, do nothing if it is already the target
- **avoid non-repeatable side effects** — sending an email or charging something needs its own guard
- **the model pipeline keys on the input hash** — a rerun resolves to the same cached result
- scoring recomputation as naturally idempotent, unique constraints as the final guard

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Redelivery is not an exception path here. `redis-broker` replicates and persists, so a failed pod's in-flight tasks come back. SQS re-delivers anything not deleted before its visibility timeout. Either way a task that has already done half its work will be asked to do all of it again.

The general technique is to make the task a function of stable inputs and to check the world before changing it. Text extraction for a document is keyed on the document identifier: if the row already says `extracted` and the extracted text exists in S3 with a matching hash, the task returns. Weighted total computation reads scores and writes a result; running it twice produces the same number, so it is naturally safe. The model pipeline keys map-stage results on the hash of the chunk text, the prompt version and the model identifier. A rerun of an interrupted job therefore resolves to cached results for everything already done, and pays only for the remainder.

The tasks that need care are the ones with side effects outside the database. Dispatching a deadline notice twice means every vendor on a tender gets two emails, which is not a data problem but is a credibility problem with the department's suppliers. That path is guarded by the `notification_outbox` row and its state, so the dispatch is recorded before the send and a redelivery sees it.

The last line of defence is the schema. A unique constraint means a duplicated insert fails loudly instead of creating a second row. A task that catches that specific conflict and treats it as success is idempotent in the only way that survives a redelivery you did not anticipate.

</details>

---

### Q2. Three of the four Celery worker deployments are brokered by Redis, but `celery-ai` uses SQS. Explain that split.

**Brief answer**
Model jobs run for minutes and need a per-message visibility timeout and a dead-letter queue, which SQS provides and a [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") list does not. The other three workers run short tasks where Redis is faster, simpler and already in the stack.

<details>
<summary><strong>Must cover</strong></summary>

- **duration is the deciding property** — minutes per job against seconds per task
- **visibility timeout matches long work** — a Redis list has no equivalent per-message lease
- **a dead-letter queue makes a stuck job visible** — the retry loop has to end somewhere
- **queue depth drives the autoscaler** — `sq-ai-jobs` depth is the scaling signal for `celery-ai`
- **the cost is a second mechanism** — two broker behaviours to operate and understand
- checkpointed resumption, rate-limit errors as the common failure

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The split is by task duration and failure mode, not by preference. `celery-documents`, `celery-scoring` and `celery-imports` run tasks measured in seconds: parse a file, compute a weighted total, load a batch of vendor rows. Redis as a broker is low-latency and already running, and a redelivery after a worker loss costs a few seconds of repeated work.

A model job is a different animal. A 60-page requirement pack is dozens of calls to a third party, and the pipeline's target is a p95 under six minutes. The failure most likely to hit it is a rate-limit response part of the way through. SQS gives per-message visibility timeouts long enough to cover that work, extended while the job progresses, plus a dead-letter queue when a job has failed too many times. A Redis list offers neither without building them.

The second benefit is operational. `celery-ai` scales on the depth of `sq-ai-jobs`, which is a queue metric the autoscaler can read directly. That is a better signal than processor use for work that is mostly waiting on a remote endpoint.

The cost is honest: two broker mechanisms, two sets of failure modes, two dashboards. I would not defend that for two similar workloads. I defend it here for two reasons. The visibility timeout and the dead-letter queue are the exact properties a minutes-long third-party call needs. And the alternative — long jobs on a Redis list — fails in the way that is hardest to see. Work quietly re-runs, and nobody notices until the token bill arrives.

</details>

---

### Q2. A supplier registry import carries tens of thousands of rows. Walk me through how it is processed, and why batches of 500 in separate transactions rather than one transaction.

**Brief answer**
The file is uploaded to S3 and handled by `celery-imports`. It validates every row against a Pydantic model, then applies the rows in batches of 500, each in its own transaction. Rejected rows are written to a downloadable error report. One large transaction would turn a single bad row into a total failure and would hold locks for the length of the whole import.

<details>
<summary><strong>Must cover</strong></summary>

- **validate every row before applying** — a schema check, not a database error
- **a bad row fails its batch, not the import** — partial progress is recorded, not lost
- **a rejected-row report** — the import is never partially applied without a record of what was skipped
- **long transactions are costly** — held locks and bloat while an import runs for minutes
- **bulk load into a staging table, then a set-based merge** — not row-by-row inserts
- **imports emit ordinary domain events** — one write path into the search projection, not a second
- resumability on redelivery, the error report as the operator's artifact

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The file lands in S3 like any other upload, and `celery-imports` picks the work up. Every row is parsed into a Pydantic model first, so a malformed registration number or an impossible date is a validation result with a row number, not a database exception halfway through a write.

The batching decision is about what failure should cost. With one transaction around fifty thousand rows, row 49,000 failing discards everything, and the operator retries the whole file hoping it works this time. With batches of 500, a bad batch is isolated: the rest of the import is applied, and the rejected rows are written to a report the operator downloads. That report is the important half — an import that silently skipped rows is worse than one that failed, because nobody knows what is missing.

There is a database argument too. A transaction open for several minutes holds its locks and keeps old row versions alive for the whole duration, which costs the same instance that is serving tender browsing. Short transactions release as they go.

Inside a batch the work is a bulk load into a staging table followed by a set-based merge, rather than fifty thousand individual inserts. That is dramatically less round-trip overhead and lets the database do the matching in one statement.

The last property is that imports emit the same domain events an interactive change emits. There is no second write path into `opensearch-corpus`. An imported vendor is indexed by exactly the mechanism that indexes a vendor created through the API. Any bug there shows up in both, rather than only in the path nobody tests.

</details>

---

### Q2. Kafka, SQS and Celery all carry work here. At 70 requests per second that is a lot of machinery. What does each do that the others cannot?

**Brief answer**
Kafka is an ordered, replayable log with long retention, which is what the audit sink and the search projection rebuild from. SQS is point-to-point delivery with a visibility timeout and a dead-letter queue, which is what a Lambda-to-service handoff needs. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") is the worker runtime the Python services already use.

<details>
<summary><strong>Must cover</strong></summary>

- **Kafka: retained, ordered, replayable** — many consumers read the same log independently
- **SQS: per-message lease and a dead-letter queue** — the right semantics for a handoff, and no broker credentials for a Lambda
- **Celery: a worker runtime, not a transport** — it is where the Python task code runs
- **the cost is three sets of failure modes** — three dashboards at a scale none of them is stretched by
- **the named simplification** — move the audit log into partitioned Postgres and Kafka can go
- consumer groups against competing consumers, replay as the projection rebuild mechanism

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

They answer three different questions, and the honest framing is that only two of them are load-bearing.

Kafka is a log. Events stay for a long retention period, they are ordered within a partition, and several independent consumers read the same stream at their own positions. That is what `opensearch-corpus` needs: the index is a projection with no backup, and a rebuild is a replay of `document.events` plus the extracted text in S3. It is also what the audit sink needs, since the ledger head is published on every append and mirrored into storage under Object Lock. A queue cannot serve that, because a queue's message is consumed and gone.

SQS is point-to-point delivery with a per-message lease. Its natural users here are handoffs: an S3-triggered Lambda to `document-service`, a service to a long-running worker, a service to a dispatch function. Using Kafka for the Lambda handoff would mean giving a function broker credentials and managing consumer group membership for something that runs for 200 milliseconds.

Celery is not a transport at all — it is the runtime that executes Python tasks, with retries, scheduling and result handling. It sits on top of one of the other two.

The cost is real: three sets of failure modes and three dashboards, at a scale none of them is stretched by. The design records it as a trade-off and names the exit. If operational load ever becomes the binding constraint, the audit log moves into partitioned PostgreSQL tables behind the outbox, and Kafka can be removed outright.

</details>

---

### Q2. How does trace context survive the hop from an HTTP request into a Celery task and an SQS message?

**Brief answer**
It is carried explicitly. The trace identifier travels in SQS message attributes and Kafka headers, and the instrumentation on the consumer side restores it as the parent of the new span. Without that, each asynchronous hop starts a fresh trace and the picture breaks into five unrelated ones.

<details>
<summary><strong>Must cover</strong></summary>

- **context propagation is not automatic across a queue** — it must ride with the message
- **SQS message attributes and Kafka headers** — the carrier on each transport
- **the consumer restores the parent span** — the task's work attaches to the original trace
- **one trace covers upload, scan, extraction, chunking and indexing** — instead of five fragments
- **sampling must be decided once, at the start** — a partial trace is worse than none
- log correlation through the same identifiers, 100% sampling on sealing and model jobs

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Inside one process, instrumentation propagates context implicitly. Across a queue there is no call stack to carry it, so the context has to be written into the message. The producer injects the trace and span identifiers into SQS message attributes or Kafka headers, and the consumer extracts them and starts its span with that as the parent.

The payoff is a document's whole life as one picture. A vendor uploads a pack, S3 notifies a Lambda, the Lambda enqueues, `document-service` scans and extracts, `celery-documents` chunks, and the search projection indexes. Without propagation that is five traces that a person has to join by timestamp and document identifier. With it, one trace shows where the eight minutes went.

Two details matter in practice. Sampling has to be decided at the head of the trace and carried with it. Otherwise the middle of a trace is sampled and the ends are not. That produces a picture which is actively misleading. Here the policy is to sample everything on sealing, unsealing, award and model jobs, and 5% of ordinary reads. The same identifiers go into the structured log line. Every line carries `request_id`, `trace_id`, actor fields and the tender identifier where known. So a trace found in the trace backend leads straight to the log lines for that work in Kibana, and back again.

</details>

---

### Q3. `bid.events` and `evaluation.events` are keyed by `tender_id` rather than by the entity identifier. What does that buy, and what does it cost?

**Brief answer**
It puts one tender's whole history in one partition, in order, so the audit sink and the evaluation projection can replay a single tender without reordering anything. The cost is that a tender is the unit of parallelism, so one very large tender cannot be spread across consumers, and an unusually busy tender can create a hot partition.

<details>
<summary><strong>Must cover</strong></summary>

- **ordering is per partition** — the key decides what is ordered with what
- **one tender's history stays together** — submission, unsealing, scoring and award in sequence
- **replay of a single tender is possible** — audit and projection rebuild without a sort
- **the cost is a hot partition** — a deadline surge concentrates on one key
- **parallelism is bounded by the tender count** — not by the number of bids
- keying by bid identifier as the rejected alternative, ordering that matters to the audit trail

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Kafka guarantees order within a partition, and the key decides the partition. Keying `bid.events` by `bid_id` would spread one tender's events across many partitions, and a consumer would see `BidUnsealed` for one bid before `BidSubmitted` for another with no way to know the true sequence. For search that would be tolerable. For the audit sink it is not: the trail's value is that it shows what happened in what order for a given procurement.

With `tender_id` as the key, every event for a tender — every submission, the unsealing, every scorecard lock, the consensus and the award — lands in one partition in the order it was produced. Replaying one tender means reading one partition from an offset. Rebuilding the evaluation projection for a disputed award is then a bounded, repeatable operation rather than a distributed sort.

The cost appears at the closing minute. Several hundred bids submitted against one tender all key to the same partition, so that partition is hot while its neighbours are idle. Two things keep it acceptable. The event is small — the bytes are in S3 and the domain row is in PostgreSQL — and nothing on the vendor's path waits for it, because the outbox relay publishes after the commit. If a single tender ever did become too large for one partition, the answer is not to change the key. It is to split the consumers so that the audit sink, which needs the ordering, stays on this stream while a projection that does not need it consumes a differently keyed derivative.

</details>

---

### Q3. The design names dropping Kafka as its first simplification, moving the audit log into partitioned PostgreSQL. Walk me through that change.

**Brief answer**
The outbox already exists, so the change is mostly about the consumers: the audit sink becomes a partitioned table plus an export job, and the search projection reads unpublished outbox rows instead of a topic. The property that has to be replaced deliberately is replay — a projection rebuild currently means reading a retained log.

<details>
<summary><strong>Must cover</strong></summary>

- **the outbox is already the source** — events are written transactionally today
- **the audit sink becomes a table plus an export** — monthly partitions, then Object Lock storage
- **the projection reads the outbox directly** — a relay per consumer instead of a shared log
- **replay is the property that must be rebuilt** — retention in a table, not in a broker
- **run both in parallel and compare** — the migration is verified, not declared
- **what is gained** — one fewer cluster, one fewer set of failure modes and dashboards
- ordering from the aggregate version, the trigger for doing this at all

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The precondition is already met. Events are written to `event_outbox` inside the domain transaction, with a unique key on aggregate and version, and a relay publishes them. Kafka is a consumer of that, not the origin.

The migration has three parts. First, the audit sink. Today the ledger head goes to `audit.events` and into an object prefix under Object Lock. Afterwards, audit entries accumulate in the monthly-partitioned `audit_event` table — which exists — and a scheduled job exports detached partitions to the same Object Lock prefix. The immutability guarantee is unchanged, because it was never Kafka providing it; it was the object store.

Second, the search projection. Instead of consuming a topic, `search-service` reads unpublished outbox rows for the event types it cares about and marks its own position. That is a relay per consumer rather than one shared log, which is more code than a consumer group and much less infrastructure.

Third, and this is the part to be deliberate about, replay. Rebuilding `opensearch-corpus` today is a topic replay. Afterwards it is a scan of retained outbox rows plus extracted text in S3. Outbox retention then becomes a decision rather than a side effect. Rows cannot be deleted as soon as they are published.

I would run both paths in parallel first and compare the resulting index and audit exports, because "the projection still rebuilds correctly" is a claim that deserves evidence. And I would only start if the trigger were real: three messaging systems is an operational cost, and it is worth paying until the on-call load says otherwise.

</details>

---

### Q3. Delivery is at-least-once everywhere. Where does a duplicate actually hurt, and how is each case handled?

**Brief answer**
In most places it does nothing, because consumers are keyed on aggregate and version and tasks check state before acting. It hurts in exactly three places: anything that sends to a person, anything that spends money at a third party, and anything that appends to the ledger.

<details>
<summary><strong>Must cover</strong></summary>

- **the default is harmless** — consumers keyed on aggregate and version discard a repeat
- **notifications reach people** — a duplicate is a credibility problem, guarded by the dispatch outbox
- **model calls cost money** — the content-hash cache turns a rerun into a lookup
- **the ledger must not gain a row** — the unique key and the advisory lock make it impossible
- **projections are naturally repeatable** — reindexing the same chunk is a no-op
- the report of what was skipped on imports, alerting on duplicate rates as a signal

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Start with why at-least-once is chosen. The outbox converts a possible lost event into a possible duplicate event. That is the right trade here. A missing `BidSubmitted` would mean a bid that exists and is invisible to evaluation. So duplicates are designed for, not avoided.

Most consumers do not care. Every event carries `(aggregate_kind, aggregate_id, aggregate_version)`, and a consumer that has applied version 7 ignores a second copy. Reindexing an unchanged chunk into `opensearch-corpus` produces the same document. Recomputing a weighted total produces the same number.

Three places are different. Notifications reach humans. A duplicated deadline notice to a few thousand vendor contacts is not a data defect, but it damages trust in the platform's messages. So the `notification_outbox` row and its state are written before the dispatch and checked on redelivery. Model calls cost money — roughly 2.8 billion input tokens a year is the platform's largest variable cost — so a rerun that repeats the map stage is a direct bill. The content-addressed cache handles it: the key is the hash of the chunk text, the prompt version and the model identifier, so a redelivered job resolves to stored results.

The third is the ledger, and there the answer is structural rather than behavioural. `submission_ledger` is unique on `(tender_id, seq)`, `bid` is unique on `(tender_id, vendor_org_id)`, and sequence allocation happens under the per-tender advisory lock inside the sealing transaction. A duplicate submission attempt cannot produce a second chain entry; it fails the constraint, and with an idempotency key it returns the original receipt instead.

I would also watch the duplicate rate rather than only tolerating it. A sudden rise usually means a visibility timeout is shorter than the work, which is a configuration bug that idempotency is quietly hiding.

</details>

---

### Q3. During a tender window, a corrupt upload repeatedly fails scanning and fills the dead-letter queue. What do you do live, and what do you change afterwards?

**Brief answer**
Live: confirm the blast radius is one document rather than the whole intake path, and keep the queue moving. Then make sure the affected vendor is told their document is not usable, while they still have time to replace it. Afterwards: make that failure class fail fast at validation instead of in the parser, and check whether the quarantine path handled the object as evidence.

<details>
<summary><strong>Must cover</strong></summary>

- **first question is scope** — one poison object or every document failing
- **the deadline is the constraint** — the vendor needs to know in time to re-upload
- **the DLQ has already done its job** — the message stopped circulating and raised a ticket
- **do not delete the object** — an infected or corrupt upload is evidence, it moves to quarantine
- **afterwards, move the check earlier** — magic bytes and expansion ratio at intake, not in the parser
- **a regression test from the real object** — a fixture, kept, that reproduces the crash
- backlog alerting on pending scans, capacity protected by the queue

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first thing to establish is whether this is one object or a class. A single corrupt file producing repeated failures is contained: the dead-letter queue has stopped the retry loop, the ticket exists, and the rest of the intake path is unaffected. Every document pending scan for more than fifteen minutes alerts separately, so if that alert is also firing, the problem is the scanner or the worker, not the file, and that is a different incident.

Assuming it is one file, the urgent matter is not technical. A vendor has uploaded something that will never become part of a valid bid, and the deadline does not move. They need to know while they can still replace it. That means checking the document's owner, confirming the state visible to them says the document is unusable rather than "processing", and making sure the notification actually went out.

What I would not do is delete the object. An upload that fails structurally may be a mistake, or may be an attack. The design treats an infected object the same way. It moves to a quarantine prefix and is never deleted, because it is evidence.

Afterwards there are two changes. The first is to move the detection earlier. `fn-object-intake` already validates magic bytes against the declared content type and rejects archives whose expansion ratio looks like a decompression attack. If this file got past that and crashed the parser, the intake check is missing a case, and rejecting at intake gives the vendor a synchronous error instead of a silent failure minutes later. The second is a regression test built from the real object, stored as a fixture, so the parser's behaviour on it is asserted rather than remembered.

</details>

---

## Document Intelligence with LangChain and LangGraph

---

### Q1. What do LangChain's loaders, splitters and retrieval pieces actually do in this pipeline?

**Brief answer**
They are the plumbing around the model, not the intelligence. Loaders turn an uploaded pack into text with page positions. Splitters cut that text into chunks a model call can hold. The retrieval pieces embed those chunks, and fetch the relevant ones back at query time.

<details>
<summary><strong>Must cover</strong></summary>

- **loaders produce page-anchored text** — position is kept, because citations depend on it
- **splitters bound the model call** — chunks sized to a context window, with overlap
- **chunk boundaries decide answer quality** — a split table damages both summary and citation
- **embeddings and retrieval** — chunks become vectors written to the corpus index
- **the model does none of this** — it sees only what the plumbing hands it
- structure-aware splitting over fixed character counts, the extracted text stored in S3

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A requirement pack arrives as a set of documents averaging 35 MB. The loader's job is to turn that into text while keeping the position of every piece, as a page number and a character range. Position is kept because the whole platform's rule is that a generated claim must resolve back to a page of a real document. Extraction output is stored in S3 as page-anchored text, and the chunk fields in the search index carry `page`, `char_start` and `char_end` for exactly this reason.

The splitter decides what one model call sees. Chunks have to fit the context window with room for the prompt and the answer, and they usually overlap slightly so a sentence spanning a boundary is not lost from both sides. This is where quality is won or lost: a splitter that cuts by character count will slice a requirements table in half, and the model then summarizes half a table confidently. Structure-aware splitting — on headings, sections and table boundaries — is worth the extra work on documents like these.

The retrieval pieces embed each chunk into a 768-dimension vector and write it to `corpus-current`, and at query time they embed the query and fetch nearest neighbours to hand to the model.

The framing I would keep in an interview is that none of this is the model. These are ordinary engineering decisions — parsing, chunking, indexing — and they determine more of the output quality than the choice of model does. When a summary is wrong here, the splitter is a more likely cause than the model.

</details>

---

### Q1. Why LangGraph rather than a plain LangChain chain?

**Brief answer**
Because these pipelines are not a straight line. They validate, retry with different settings, and quarantine rather than guess, and LangGraph makes each step's state a checkpoint. A rate-limit error two thirds of the way through a long pack resumes from the last checkpoint instead of restarting from the first token.

<details>
<summary><strong>Must cover</strong></summary>

- **the pipeline has branches** — validate, retry, quarantine, not one sequence
- **checkpointed state per node** — written to PostgreSQL, keyed by job and node
- **resume instead of restart** — the dominant failure is a transient limit mid-run
- **restarting costs real money** — dozens of calls per pack, repeated for nothing
- **retry with lowered temperature, bounded at two** — a retry loop needs an end
- the state machine as the readable artifact, quarantine as a terminal state

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A plain chain models one path: input, steps, output. These pipelines branch. After the map stage, output is validated against a Pydantic schema and checked for a citation. Invalid output retries at a lower temperature, at most twice, and if it is still invalid the run is quarantined. After the reduce stage, every claim is resolved back to a real chunk, and an unresolvable claim fails the whole artifact. That is a state machine, and writing it as a chain means encoding the branches in application code around the chain, which is where the control flow stops being visible.

The practical reason is checkpointing. A 60-page requirement pack is dozens of model calls spread over minutes. The most common failure is not a bad answer but a transient rate-limit response. With state checkpointed to `postgres-core` after each node, keyed by job and node, the resumed run picks up where it stopped. Without that, every transient error costs the whole run again — in time against a six-minute target, and in tokens against a cost line that is the platform's largest variable expense.

There is a second, quieter benefit. Because the run's state is persisted per node, a job that ends badly is inspectable afterwards. You can see which node failed, with what input, rather than reading a stack trace from a process that has gone. On a pipeline whose output has to be defensible in a procurement audit, that is worth more than the convenience of a shorter definition.

</details>

---

### Q1. What is map-reduce summarization, and why is it necessary for a 55 MB bid pack?

**Brief answer**
The pack is split into chunks, each chunk is summarized independently in the map stage, and the reduce stage composes those summaries into one report. It is necessary because a bid pack is roughly 120,000 tokens of extracted text, which no single call is going to handle well even if it fits.

<details>
<summary><strong>Must cover</strong></summary>

- **the input exceeds one call** — roughly 120,000 tokens per pack
- **map stage runs per chunk group** — independent, parallel, and cacheable
- **reduce composes the result** — the stage where the report takes shape
- **each stage is validated separately** — a bad chunk summary is caught before it is composed
- **the map results are content-addressed** — repeated boilerplate is summarized once
- **model tier differs by stage** — cheaper on map, larger only on reduce
- fan-out limited by the account rate limit, eleven packs arriving together

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A 55 MB bid pack extracts to about 120,000 tokens, and around eleven of them arrive when a tender closes. Sending that to one call is either impossible or unwise: even where a context window is large enough, quality falls on long inputs and one failure discards everything.

Map-reduce splits it. Each chunk group is summarized on its own, against the criteria the evaluator asked about. Those partial summaries are then composed into the report in the reduce stage. Because the map calls are independent they run in parallel across `celery-ai`, and because they are small they are cheap on a lower model tier, with only the reduce step using the larger one.

Two properties come from the split rather than from the model. The first is validation granularity: a chunk summary that fails its schema or omits a citation is retried by itself, not by restarting the pack. The second is caching. Map results are keyed by the hash of the chunk text with the prompt version and model identifier, and vendors reuse boilerplate heavily across bids — company profiles, certifications, standard terms. That repetition is summarized once and reused, which is the single largest lever on the token cost.

The limit that actually binds the fan-out is not pod count but the account's model rate limit. Scaling workers past it converts one slow job into eleven failing ones, so the concurrency ceiling is set from the limit, not from the cluster.

</details>

---

### Q1. The design says the model is advisory. What does that mean in concrete terms?

**Brief answer**
No model output is ever written into a score, an eligibility verdict or an award record. Generated artifacts are separate rows with their own lifecycle. Every claim in them resolves to a page of a real document. And the whole feature has a switch that turns it off without disabling anything else.

<details>
<summary><strong>Must cover</strong></summary>

- **separate storage, never a decision column** — artifacts live in their own tables and bucket
- **proposed criteria are suggestions** — criteria are only written by the officer's own call
- **every claim carries a citation** — document, page and character range, or the artifact is rejected
- **a kill switch that costs no function** — with it off, evaluators work from the source documents
- **structural rather than procedural** — the rule is enforced by schema and network, not a policy note
- per-tender classification gate, artifacts deleted after the award

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

"Advisory" is easy to write in a policy and hard to prove, so the design makes it structural in four places.

Storage first. A generated artifact is an `ai_artifact` row and an object in `s3-artifacts`, with its citations in `ai_citation`. There is no column on `score`, `consensus_scorecard` or `award` that a model can write. An award is bound to a consensus scorecard built from human-entered scores, and the schema offers no other path.

Second, extraction proposes rather than sets. The pipeline reads a requirement pack and suggests criteria, deadlines and mandatory qualifications, and the drafting officer accepts or discards them. Criteria reach the database only through the officer's own call, which is also where the weight-sum rule is enforced.

Third, grounding. The reduce stage emits structured claims each naming a chunk, and validation resolves every one back to a real chunk of a real document belonging to that subject. A claim that does not resolve fails the entire artifact, which is quarantined and never shown. So an unsupported sentence does not reach a human at all.

Fourth, the switch. With the feature disabled, evaluators read source documents and score as they would without the platform. Nothing downstream depends on an artifact existing. A tender classified above the platform's egress threshold runs that way for its whole life.

The test I would apply to any future feature request is simple: if the model stopped working today, would any decision become impossible? If yes, it is no longer advisory.

</details>

---

### Q2. Walk me through citation validation. What happens to a claim that does not resolve?

**Brief answer**
The reduce stage emits structured claims, each naming a chunk identifier. Validation resolves every claim back to a real chunk of a real document belonging to that subject. One unresolvable claim fails the whole artifact, which moves to quarantine — the officer is told, and nothing is shown.

<details>
<summary><strong>Must cover</strong></summary>

- **claims are structured output, not prose** — each names the chunk it came from
- **resolution checks three things** — the chunk exists, its document is real, and it belongs to this subject
- **failure is whole-artifact, not per claim** — a partly-grounded report is more dangerous than none
- **quarantine is a terminal state** — recorded as failed, the officer notified, nothing displayed
- **citations are stored for the reader** — document, page and character range on every claim
- the quarantine rate as a prompt or model regression signal, artifacts never updated in place

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The reduce stage does not return an essay. It returns a structured object whose claims each carry the identifier of the chunk they came from, and that object is parsed by a strict Pydantic model before anything else happens. A response that will not parse never becomes an artifact.

Resolution then asks three questions per claim. Does that chunk exist? Does it belong to a document that exists? Is that document owned by the subject of this job — this bid, this tender version, this evaluation session? The third is the one that matters most, because it is what stops a summary of bid A quoting a chunk from bid B.

If any single claim fails, the whole artifact fails. That is deliberate and worth defending in an interview, because dropping the bad claim and keeping the rest is the tempting alternative. It is the wrong one: a report that is 90% grounded reads exactly like a report that is 100% grounded, and the reader has no way to tell which sentence was the ungrounded one. An artifact that does not appear is honest.

The failed run is recorded with `state = 'failed'` and the officer is notified. Artifacts are never updated in place — a rerun writes a new row, with its own model identifier, prompt version and input hash, so the history of what was generated stays intact.

The quarantine rate is monitored rather than merely logged. More than 10% of artifacts quarantined over a day raises a ticket, because that pattern usually means a prompt change or a model revision has regressed, not that the documents got worse.

</details>

---

### Q2. The map-stage cache key is the hash of the chunk text together with the prompt version and the model identifier. Why all three parts?

**Brief answer**
Each part is something that changes the output. The chunk text is the input, the prompt version is the instruction, and the model identifier is the function being applied. Leave any one out and a cache hit returns a result that was produced under different conditions.

<details>
<summary><strong>Must cover</strong></summary>

- **the key must cover every input to the result** — text, instruction and model
- **a prompt change must invalidate** — otherwise a fix silently does nothing for cached chunks
- **a model change must invalidate** — the same text and prompt produce different output
- **content addressing is what makes boilerplate cheap** — repeated vendor material summarized once
- **the cache is an optimisation, not a source of truth** — losing it costs money and time, not correctness
- 30-day expiry with object storage behind it, the largest lever on token cost

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The rule for any cache key is that it has to include everything the value depends on. Here the value is a chunk summary, and it depends on three things.

The chunk text is the obvious one, and hashing it is what makes the cache useful at all. Vendors reuse the same company profile, certifications and standard terms across many bids, so the same chunk appears repeatedly across the corpus and is summarized once.

The prompt version matters because a prompt is code. When someone improves the extraction prompt to handle a phrasing the old one mishandled, every cached result from the old prompt is stale. If the key ignored the prompt version, the improvement would apply only to chunks nobody had seen before — the bug would persist exactly where it had already occurred, which is the worst possible distribution. Prompts are versioned artifacts in the repository rather than runtime values, precisely so this identifier exists.

The model identifier matters for the same reason at a larger scale. The same text and the same prompt against a different model produce different output, and a tier change or a provider version bump would otherwise be invisible.

One thing to be clear about: this cache stores money and time, never truth. It lives in `redis-cache` with a 30-day expiry and object storage behind it, and losing it entirely means the next runs are slower and dearer. It is not a store anything depends on for correctness, which is consistent with the rule that nothing on a deciding path reads a cache.

</details>

---

### Q2. How does redaction before egress work, and what happens when it fails?

**Brief answer**
Names, national identity numbers, phone numbers, email addresses and bank details are detected before any text leaves the network. Each is replaced with a stable placeholder. The mapping is held in PostgreSQL and reapplied to the artifact on the way back. If redaction fails, the job fails — it does not send the unredacted text.

<details>
<summary><strong>Must cover</strong></summary>

- **replace before egress, restore after** — placeholders go out, real values are put back locally
- **stable placeholders** — the same person maps to the same token, so the text still reads coherently
- **the mapping never leaves** — it lives in PostgreSQL, not in the request
- **failure fails the job** — the unsafe path is closed, not degraded
- **enforced at a network boundary too** — one egress-controlled subnet, everything else has no route out
- **the egress log records the hash, never the payload** — accounting without a second copy
- detection limits on free prose, the per-tender classification gate as the stronger control

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Sending police-department procurement documents to a third-party endpoint is the sharpest tension in the whole brief, so the controls are layered rather than single.

The mechanism is substitution. Before text leaves, identifiers are detected and replaced with stable placeholders — the same individual becomes the same token everywhere in the pack, so a summary that refers to them still reads sensibly. The mapping is stored in `postgres-core`, never sent, and reapplied when the artifact comes back. The model therefore works on structure and content while the identifying values stay inside the network.

Failure behaviour is the part I would emphasise. If the redaction step errors, the job fails. It does not send the text unredacted and log a warning. That is the same fail-closed reasoning as sealing failing when the key service is unavailable: the risk of the unsafe path is larger than the cost of the feature being unavailable.

Around that sit two stronger controls, because detection over free prose is never perfect. The first is the network boundary. `ai-service` and `celery-ai` are the only workloads with a route out, through one egress-controlled subnet that allows exactly the model endpoint. Every other pod has no egress beyond internal endpoints. The second is the per-tender classification gate — a tender above the platform's egress classification runs with the feature off for its entire lifecycle, so the most sensitive material never enters this path at all.

Every egress call is logged with the artifact, model, prompt version, token counts and a hash of the payload, never the payload itself. That gives an auditor an account of what left, without the log becoming a second copy of the thing being protected.

</details>

---

### Q2. Embeddings are stored at 768 dimensions rather than the model's full width. What is the risk, and how would you check it?

**Brief answer**
The risk is recall: a narrower vector carries less information, so semantic retrieval can miss a relevant chunk. The check is a measurement on real tender packs, not an assumption — and the reduction is only safe if the model supports truncation natively rather than by slicing the vector.

<details>
<summary><strong>Must cover</strong></summary>

- **the saving is index footprint and memory** — the hot window's size assumes this width
- **the cost is recall** — a missed chunk means a missed requirement, not a slower query
- **truncation must be supported by the model** — naive slicing is not the same operation
- **measure recall on real packs** — a labelled sample from the domain, before committing the mapping
- **the mapping is hard to change later** — a width change means reindexing the whole corpus
- bilingual prose as the difficult case, `pipeline_version` on each chunk for targeted reindexing

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The reason to reduce is capacity. Only a 24-month hot window stays in the vector index — roughly 10 million chunks at about 63 GB including graph overhead — and that estimate assumes 768 dimensions. Doubling the width roughly doubles the memory the approximate-nearest-neighbour graph needs, and that is the cluster's dominant cost.

The risk is not performance but recall. A vector with less information separates near-neighbours less well. In this domain a miss is not a cosmetic ranking difference. It is a mandatory qualification in a requirement pack that the extraction step never saw, or a clause in a proposal that the summary never mentions. That is a quality failure the user cannot detect, because nothing tells them a chunk was missed.

Two conditions make the reduction defensible. First, the model must support producing a shorter vector natively. Some embedding models are trained so that a prefix of the vector remains meaningful; others are not, and slicing those simply discards information. That is a fact to confirm on the model card, not to assume.

Second, measure. Take a sample of real tender packs, build a small set of queries with known relevant passages, and compare recall at full width against the reduced width. If the gap is small, the saving is worth it. If it is not, the index mapping is the wrong place to economise.

The reason to settle this before building is that the mapping is expensive to change: a different width means reindexing the entire corpus. The chunk fields carry `pipeline_version` and `indexed_at`, so a reindex can be targeted rather than total. It is still a large operation. That is exactly why the design flags it as a question to answer before committing.

</details>

---

### Q3. A procurement auditor asks you to prove the model did not influence an award. What do you show them?

**Brief answer**
Three things. The schema, which has no path from an artifact to a score or an award. The audit trail and ledger, which show what was recorded and that it has not changed. And the artifact rows, which record what was generated, from what input, and where every claim came from.

<details>
<summary><strong>Must cover</strong></summary>

- **the schema is the first proof** — an award binds to a consensus scorecard from human-entered scores
- **artifacts are stored separately** — their own table and bucket, with no decision column to write
- **reproducibility of the artifact** — input hash, model identifier, prompt version, all recorded
- **citations are checkable by the auditor** — every claim resolves to a page of a named document
- **the audit trail is verified, not just written** — the ledger chain is recomputed against Object Lock storage
- **the platform runs with the feature off** — availability of the alternative is itself evidence
- versioned prompts in the repository, the egress log of what left and when

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would answer structurally rather than with assurances, because an auditor is right to distrust assurances.

The strongest evidence is the schema. An `award` row references a `consensus_scorecard`, which is built from `score` rows written by identified evaluators through their own scorecards, each locked. The award is rejected unless the signer is the committee chair and every non-recused assignment has a locked scorecard. There is no column anywhere on that path that a generated artifact can write into, and artifacts live in separate tables with a separate bucket. So the question is not whether anyone chose not to use model output in a score — there is no field in which to put it.

The second is the trail. Every state transition, every authorization denial, every bid document access, every unsealing and every egress call is an append-only audit entry, monthly-partitioned and mirrored to storage under Object Lock in compliance mode. The submission ledger's hash chain is recomputed nightly and compared against that mirrored head, and a mismatch is handled as a security incident. That means the records being shown have been verified, not merely produced.

The third is the artifacts themselves, which I would hand over rather than hide. Each records its model identifier, prompt version, pipeline version and input hash, and every claim in it carries a document, a page and a character range. An auditor can open the cited page and check the claim. Prompts are versioned files in the repository, so what was asked is reviewable too.

The last point is the kill switch. Tenders above the egress classification run with the feature off for their whole lifecycle, and those awards are produced by the identical path. The mechanism that would have to be trusted is demonstrably optional.

</details>

---

### Q3. The autoscaler scales `celery-ai` on queue depth, but the real concurrency limit is the account's model rate limit. How do those two interact, and what goes wrong?

**Brief answer**
They fight if nobody arbitrates. Queue depth rises, the autoscaler adds pods, the extra pods send more requests, the endpoint starts rejecting them, jobs fail and return to the queue, depth rises again. The fix is to make the rate limit the ceiling in the application and let the autoscaler work below it.

<details>
<summary><strong>Must cover</strong></summary>

- **queue depth is the scaling signal, not the capacity signal** — it says work is waiting, not that more workers help
- **the binding limit is external** — the account's token and request allowance
- **a feedback loop forms** — rejections become retries, retries become depth, depth becomes pods
- **cap concurrency where the calls are made** — a shared limiter, not a replica count
- **wasted capacity has a real cost** — partial runs and repeated tokens
- **set the autoscaler maximum from the limit** — scaling stops where the endpoint stops
- backoff with jitter, checkpointed resumption limiting the damage

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The autoscaler reads the depth of `sq-ai-jobs` and adds replicas. That is the right signal for a worker whose time is spent waiting, because processor use would stay low while jobs queue. The trap is that depth measures demand, not whether more workers can serve it.

When a tender closes, eleven bid packs arrive together and depth jumps. Pods are added, and each one starts issuing model calls. Past the account's allowance the endpoint returns rate-limit errors. Those jobs retry, and the design already says the consequence plainly: exceeding the ceiling converts one slow job into eleven failing ones. Failures return to the queue, depth stays high, and the autoscaler adds more pods, which makes the rejection rate worse. The system has built a positive feedback loop out of two reasonable components.

The arbitration has to happen where the calls are made. Concurrency against the model endpoint is capped by a shared limiter sized from the account's limit, so total in-flight requests stay under it regardless of replica count. Extra pods then add queue-draining capacity for everything except the constrained hop, and back off politely when they reach it, with jitter so they do not retry in lockstep.

The autoscaler's maximum is set from the same number rather than left open, which makes the relationship explicit to whoever reads the manifest later.

Two things limit the damage while this is being tuned. Checkpointing means a job interrupted by a rate limit resumes rather than restarting, and the content-addressed map cache means the repeated portion is usually free. And the whole peak sits after the deadline surge by construction, because summarization never starts before unsealing — so the two busy periods do not overlap.

</details>

---

### Q3. Requirement packs mix Arabic and English, sometimes in the same table. How would you handle chunk boundaries that split a bilingual table?

**Brief answer**
Not by tuning chunk size. A table is a structure, so the splitter has to recognise it and keep it whole, and the extraction step has to preserve enough layout for that to be possible. This is one I would prove on real packs before choosing an approach.

<details>
<summary><strong>Must cover</strong></summary>

- **the damage is to summary and citation together** — half a table produces a claim anchored to the wrong range
- **structure-aware splitting** — never split a table, split between rows if a table must be divided
- **extraction has to keep layout** — a splitter cannot respect a structure the loader discarded
- **mixed direction text complicates both** — reading order and character ranges in the same cell
- **the search index already separates language analysis** — Arabic and English sub-fields on the text field
- **prove it on real packs** — a labelled sample, measured, before committing a splitter
- header repetition on a divided table, a chunk-level language tag

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The failure is worse than a poor summary. If a table of mandatory qualifications is split, the first chunk has headers with no rows and the second has rows with no headers. The model summarizes each plausibly, and the citation anchors to a character range that does not contain what the claim says. So the platform's central guarantee — every claim resolves to its source — is technically satisfied while being practically wrong.

The fix begins before the splitter. Extraction has to keep enough layout to know a table exists, with page and character positions per cell. A loader that flattens everything to a stream of text has already destroyed the information the splitter would need. Right-to-left and left-to-right text in one cell complicates both the reading order and the character ranges, so the extraction step is where I would spend the first effort.

Then the splitter becomes structure-aware: chunk on section and table boundaries, never mid-table. If a table is genuinely too large for one chunk, divide it between rows. Repeat the header rows in each part, so every chunk is self-describing. Tagging each chunk with its dominant language also helps the prompt. It matches what the index already does. The text field carries Arabic and English sub-fields, so keyword scoring uses the right analysis for each.

I would treat all of this as a hypothesis until measured. The honest plan is a proof of concept on a sample of real packs. Compare splitters on two things: whether extracted criteria match what an officer identifies by hand, and whether the citations land on the right rows. Choosing a splitter from its documentation and hoping is how this kind of defect reaches production, where nobody can see it.

</details>

---

### Q3. Suppose the department cannot obtain a zero-data-retention arrangement with the model provider. What changes?

**Brief answer**
The model moves inside the network. The pipeline is deliberately built so that the model client is the only component that would change — the stages, validation, checkpointing and citation rules stay as they are. What changes around it is capacity planning, quality and cost.

<details>
<summary><strong>Must cover</strong></summary>

- **the boundary was designed for this** — the client is the replaceable part
- **the egress subnet stops being needed** — the network control moves to a local endpoint
- **cost shifts from tokens to hardware** — a fixed platform bill instead of a variable one
- **quality has to be re-measured** — extraction and summarization accuracy on real packs
- **the fallbacks stay the same** — the kill switch and the classification gate are unaffected
- **the decision is contractual, not technical** — legal confirms it, engineering implements it
- capacity planning against a fixed local limit, embedding model change forcing a reindex

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The design already names this as a live question rather than a solved one: it assumes a zero-data-retention arrangement with no training on submitted content, and a suitable regional endpoint. Both are contractual and regional matters, not technical ones, and the correct answer if either fails is a model hosted inside the network.

The architecture absorbs that better than most, because the substitutable piece was kept small. The LangGraph pipeline, the validation stages, the checkpointing, the citation index and the artifact schema do not care which endpoint answers. The model client does. Redaction before egress becomes unnecessary in its current form, and the egress-controlled subnet stops being the sole control. I would keep the network policies even so. A self-hosted model does not make an accidental outbound route acceptable.

Three things genuinely change. Cost moves from a per-token bill of roughly 2.8 billion input tokens a year to a fixed hardware and operations bill, which is usually better at this volume and worse at low volume. Capacity becomes a hard local limit instead of an account allowance, so the concurrency ceiling is now something the team provisions rather than negotiates. And quality must be re-measured — extraction accuracy on bilingual procurement prose is the thing to test, on real packs, before anyone promises the same experience.

The embedding model deserves separate mention, because changing it forces a reindex of the whole corpus. If that switch is coming, it is far cheaper to make it before the corpus grows than after.

What does not change is the safety posture. The output is still advisory, still citation-validated, still behind a kill switch, and a tender above the classification threshold still runs without it.

</details>

---

## Search and Analytics with OpenSearch

---

### Q1. The corpus is searched by both BM25 and vector similarity. What is the difference, and why run both?

**Brief answer**
Best Matching 25 ([BM25](https://en.wikipedia.org/wiki/Okapi_BM25 "Ranking function that scores how relevant a document is to a search query")) scores how well a document matches the words in the query; vector search scores how close the query's meaning is to a chunk's meaning. They fail in opposite directions, so running both covers the exact term a procurement officer types and the paraphrase a vendor wrote.

<details>
<summary><strong>Must cover</strong></summary>

- **BM25 matches terms** — term frequency weighted against how rare the term is
- **vector search matches meaning** — nearest neighbours in an embedding space
- **each fails where the other works** — exact identifiers against paraphrase and synonym
- **procurement text has both kinds of query** — a clause reference and a description of a capability
- **hybrid means combining two score scales** — the merge is a design decision, not a default
- approximate search over a graph index, the same tenancy and sensitivity filters on both

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

BM25 is a refinement of classic term scoring. It rewards a document for containing the query's terms, dampens the reward as a term repeats, and weights rare terms above common ones. It is excellent when the user knows the words: a standard reference number, a specific certification name, a clause title. It is useless when the document says "traffic incident recording equipment" and the query says "body cameras".

Vector search handles that second case. Each chunk is embedded into a 768-dimension vector and stored in a `knn_vector` field, and a query is embedded the same way, with the nearest neighbours returned. Similar meaning lands near in that space regardless of shared words. Its weakness mirrors BM25's strength: an exact identifier can be lexically unique and semantically unremarkable, so a pure vector search returns things that are about the right topic and not the thing you asked for.

Both run over `corpus-hot` and the results are combined. The combination is the part that needs thought, because the two produce scores on different scales and a naive sum lets whichever scale is larger dominate. The target is a p95 under 700 milliseconds, with the measured cold path around 488, so there is room to do this properly.

Two things are the same for both paths and must stay so: the tenancy filter that scopes results to the principal's organization, and the `sensitivity` filter that hides a sealed chunk. A retrieval mode that skipped either would be a data leak, not a ranking bug.

</details>

---

### Q1. Why is `opensearch-corpus` a different cluster from `es-logs` when both are the same technology?

**Brief answer**
Because their load profiles collide at exactly the wrong moment. Log volume is bursty and unbounded during an incident, and that is precisely when internal users need tender search to work. Two clusters cost more; one cluster couples the two failures.

<details>
<summary><strong>Must cover</strong></summary>

- **log volume is unbounded during an incident** — the burst arrives when search is most needed
- **shared resources mean shared failure** — heap, disk and shards are all contended
- **different lifecycles** — a 30-day log window against a 24-month hot corpus
- **different data sensitivity** — logs carry no bid content, and are read by more people
- **the cost is a second cluster** — stated plainly rather than hidden
- rebuildable corpus against disposable logs, separate retention and backup answers

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The argument is about correlated failure, not about technology. When something goes wrong in production, log throughput rises sharply — retries, stack traces, debug output someone raised to investigate. On one shared cluster that burst competes for heap, disk and indexing threads with the tender and bid search that evaluators are using. The result is that search degrades during an incident, which is the one time engineers and committee members both need it.

The lifecycles argue the same way. Logs are hot for 30 days, warm for 90 and then deleted, and they are not backed up because they are disposable. The corpus keeps a 24-month hot vector window with older chunks re-indexable on demand from extracted text in S3. Those are different shard sizing, different retention and different node types on one cluster, and every tuning decision becomes a compromise between two unrelated workloads.

There is a data argument too. Logs are read by more people than bid content is, and the redaction rules mean no log line may carry bid content, extracted text, a prompt body or a completion. Keeping the two in separate clusters means an access grant on log analysis can never accidentally reach the document corpus.

The cost is a second cluster to run and pay for, and the design records it as a trade-off rather than pretending it is free. At three data nodes each, that is a real line item, and the thing it buys is that a log flood during an incident cannot make the incident harder to investigate.

</details>

---

### Q1. The corpus uses one index per quarter behind a read alias and a write alias. What does that make cheap?

**Brief answer**
Ageing the corpus out becomes an alias change instead of a mass delete, and writes always go to one current index without the application knowing its name. It also makes a reindex swappable: build the new index alongside and move the alias.

<details>
<summary><strong>Must cover</strong></summary>

- **aliases decouple the application from index names** — code writes to `corpus-current`, reads `corpus-hot`
- **retention is an alias change** — an old quarter leaves the hot set without deleting documents
- **delete-by-query is avoided** — a mass delete on a live index is expensive and leaves tombstones
- **a rebuild can be swapped atomically** — build beside, then repoint
- **shard sizing stays predictable** — each index covers a bounded period
- older chunks re-indexed on demand from extracted text, the 24-month hot window

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Three operations get easier, and they are the three that hurt on a single large index.

Retention is the obvious one. Only a 24-month hot window stays in the vector index — roughly 10 million chunks — and older material keeps its extracted text in S3 and is re-indexed on demand. Ageing a quarter out means removing one index from the `corpus-hot` alias. The alternative on a single index is a delete-by-query across millions of documents, which is slow, produces deleted-document overhead until segments merge, and competes with live queries while it runs.

The second is that the application does not know index names. Writes go to `corpus-current` and reads to `corpus-hot`. The quarterly rollover is an operational action, not a deployment, and no code changes when the calendar does.

The third is rebuilding. Because the corpus is a projection with no backup — it is rebuilt from `document.events` plus the extracted text in S3 — a rebuild is a normal operation, exercised quarterly. With aliases, the new indices are built alongside the old and the alias is moved in one atomic step, so readers never see a partially built index. Without aliases, the same operation is a window of missing results.

A fourth, quieter benefit is predictable shard sizing. Each index holds one quarter of a known ingest rate, so shard counts are chosen once from a bounded estimate rather than guessed for an index that grows forever.

</details>

---

### Q2. The design insists that `sensitivity` filtering is a filter clause and not a post-filter. Why does that distinction matter here?

**Brief answer**
A filter clause removes sealed chunks before scoring, so they never influence ranking and never appear in a highlight fragment. A post-filter drops them from the result list after the query has already read them, which leaks through relevance scores, result counts and highlighted snippets.

<details>
<summary><strong>Must cover</strong></summary>

- **the filter runs before scoring** — an excluded chunk never enters the calculation
- **a post-filter leaks through totals and scores** — the presence of hidden matches is inferable
- **highlight fragments are the sharpest leak** — a snippet quotes text the user may not read
- **sealed content is the thing being protected** — confidentiality until unsealing is the platform's core promise
- **the tenancy filter has the same shape** — the vendor scope is applied the same way
- an inference attack by repeated querying, a test asserting a sealed chunk is unreachable

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Both approaches return a list without sealed chunks in it, which is why the distinction is easy to get wrong. The difference is everything the query reveals besides the list.

With a post-filter, the sealed chunks take part in the search. They contribute to the total match count, they affect relative scores, and they can be selected for highlighting before the filter removes them. A curious evaluator, or a vendor with an account, can then learn things they should not. Whether any competitor's bid mentions a particular product, and roughly how many do. If a highlight fragment escapes, a sentence of the text itself. Repeating that with varied queries before a deadline is a workable inference attack against the exact secret the platform exists to keep.

As a filter clause, the sealed chunks are excluded from the candidate set before scoring. They contribute nothing to the counts, nothing to the scores, and cannot be highlighted, because the query never considered them.

The tenancy filter is applied the same way and for the same reason: a vendor must not be able to infer the existence of another organization's documents from result counts.

This is also something I would assert rather than assume. Query builders get refactored, and a filter quietly moved into a post-filter position produces identical results in a normal test. The test that catches it indexes a sealed chunk with a distinctive term, queries that term, and asserts the total is zero — not merely that the chunk is absent from the first page.

</details>

---

### Q2. The query embedding hop is 220 milliseconds cold and 3 milliseconds warm. Walk me through the cache and the fallback.

**Brief answer**
Query embeddings are cached in `redis-cache` on the normalised query string with a 30-day expiry, which works because a committee converges on the same handful of phrases. If the embedding call degrades, `search-service` drops to keyword-only and returns a `degraded: true` flag rather than exceeding its target.

<details>
<summary><strong>Must cover</strong></summary>

- **the key is the normalised query string** — plus the embedding model, since it changes the vector
- **committee behaviour makes the cache effective** — the same phrases repeat within a session
- **the embedding hop is the only third-party term in the budget** — it can degrade without warning
- **fallback to keyword-only** — a usable answer instead of a timeout
- **the degradation is declared to the caller** — a flag, not a silent quality drop
- 212 milliseconds of deliberate headroom, the index hop unchanged by the fallback

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Of the hops in the hybrid search budget, one is not under the platform's control. Edge and authorization, the index query, result assembly and serialization are all local and predictable. The embedding call crosses the egress path to a third party, and it is the term that can slow down or fail without notice. The total measures around 488 milliseconds against a 700 millisecond target, and that 212 milliseconds of headroom exists for this hop specifically.

The cache is simple and effective because of how the feature is used. Evaluators in a session search for the same concepts repeatedly, with small variations in wording. Normalising the query string — trimming, lowercasing, collapsing whitespace — collapses those variants onto one key, and the stored vector is reused. The key has to include the embedding model identifier, for the same reason the map cache includes it: a different model produces a different vector space, and a stale vector would be silently meaningless. A 30-day expiry is generous because a query embedding does not go stale on its own.

The fallback is the availability answer. If the embedding call fails or exceeds its budget, the query runs as keyword-only over the same index with the same tenancy and sensitivity filters. The user gets results rather than an error, and the response carries `degraded: true` so the interface can say that semantic matching is unavailable.

That declaration matters more than it looks. Silently returning keyword-only results means an evaluator believes they have searched semantically when they have not, and concludes that nothing relevant exists. An honest flag turns a degraded search into a known limitation instead of a wrong answer.

</details>

---

### Q2. Analytics aggregations are served from OpenSearch rather than PostgreSQL. Given a 30-second lag budget, what is the risk?

**Brief answer**
The risk is not the lag itself — a cycle-time report is not harmed by half a minute. It is that a number from a rebuildable, lagging projection gets quoted in a document that decides or justifies something, at which point an informative store has become a deciding one.

<details>
<summary><strong>Must cover</strong></summary>

- **the lag is harmless for the intended use** — period reporting over months
- **the real risk is provenance** — a projection figure reused in a decision
- **projections can be behind or rebuilt** — a number may legitimately change between readings
- **reconciliation exists** — a nightly comparison against the source re-emits gaps
- **label the source in the response** — the report says what it is and when it was current
- **the deciding path never reads it** — eligibility, sealing and scoring stay on the primary
- moving aggregation off Postgres as the named first evolution trigger

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The reason to aggregate here is sound. `opensearch-corpus` already holds the dimensions these reports group by, aggregation is what it is good at, and the alternative puts heavy grouping queries on a replica of the node that also serves sealing. The design names moving reporting fully off PostgreSQL as the first evolution trigger for exactly that reason.

The lag itself is not the problem. Spend, participation and cycle-time reports cover periods of months. A 30-second delay is invisible.

The problem is what happens to a number once it exists on a screen. Someone puts a participation figure into an award justification, or a committee cites a spend total in a decision memo. That document may be read in a procurement dispute. The figure came from a store that is rebuildable and may lag. After a reindex or a reconciliation, it may legitimately produce a slightly different answer tomorrow. Nothing was tampered with, but the number is not reproducible in the way a court-facing record needs to be.

Two things keep this honest. The pipeline reconciles nightly, comparing row counts and update watermarks per tender against the source and re-emitting any gap, so drift is detected rather than assumed absent. And the report response should carry its own provenance — the period it covers, when the projection was last current, and that it is a derived figure. If a number genuinely has to be citable in a decision, it should be computed from `postgres-core` at that moment and stored with the decision, rather than linked to a dashboard.

</details>

---

### Q3. The corpus has no backup because it is rebuildable. Walk me through a full rebuild while a tender window is open.

**Brief answer**
Build into new indices beside the live ones, replay `document.events` with the extracted text from S3, verify counts and a sample of queries, then move the aliases. Nothing that decides an outcome depends on the corpus, so the failure mode during the rebuild is degraded search, not a blocked submission.

<details>
<summary><strong>Must cover</strong></summary>

- **nothing on the deciding path depends on it** — submission and scoring are unaffected
- **build beside, then swap the alias** — readers never see a half-built index
- **replay from the event log plus extracted text** — the two sources that make it reproducible
- **embedding cost is the real constraint** — re-embedding millions of chunks is the expensive part
- **verify before swapping** — counts per tender, plus a sample of known queries
- **the sensitivity field must be rebuilt correctly** — a sealed chunk marked wrong is a leak, not a bug
- throttled indexing to protect live queries, the rebuild exercised quarterly

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first thing to say is what is not at risk. The corpus is a projection. Tender state, bid custody, the ledger, scores and awards are in PostgreSQL, and eligibility and sealing never read the index. So a rebuild during an open window degrades search and analytics and cannot cost anyone a submission. That is exactly why the design accepts having no backup for it.

The mechanics are an alias swap. New quarterly indices are created with the current mapping, and the rebuild replays `document.events` and reads the page-anchored extracted text from S3 for each document. Because writes go to `corpus-current`, live indexing continues against the existing index until the moment of the swap, and the replay is caught up from the event log rather than frozen.

The expensive part is embeddings, not indexing. Re-embedding on the order of 10 million hot-window chunks is a large number of calls to the same endpoint the pipeline uses. So it is throttled well below the account's limit, at a rate that leaves capacity for the interactive query path. Indexing itself is throttled too, so the cluster does not fall behind on live queries while the rebuild proceeds.

Verification happens before the swap, not after. Compare chunk counts per tender against the source, check that documents whose owner is a sealed bid carry `sensitivity = sealed`, and run a fixed set of known queries against both indices to compare results. The sensitivity field deserves its own check, because getting it wrong is a confidentiality failure rather than a quality one.

Then the aliases move, atomically, and the old indices are kept until the next day in case a comparison turns up something the checks missed. This is rehearsed quarterly as part of the restore drills, which is what makes it a procedure rather than an improvisation.

</details>

---

### Q3. The embedding model is being replaced. Plan the reindex of ten million chunks.

**Brief answer**
Treat it as a migration with a cutover, not a batch job. New vectors cannot share an index with old ones, because they are not in the same space. So build new indices with the new mapping and re-embed in controlled batches. Verify retrieval quality against a labelled sample, then swap the aliases in one step.

<details>
<summary><strong>Must cover</strong></summary>

- **vectors from two models are not comparable** — mixing them silently corrupts ranking
- **build new indices, do not update in place** — the mapping and the space both change
- **`pipeline_version` per chunk makes progress trackable** — the field exists for this
- **rate and cost are the constraints** — millions of embedding calls against a shared allowance
- **verify recall on a labelled sample before swapping** — quality is the reason for the change
- **the cached query embeddings must be invalidated** — their key carries the model for this reason
- keyword-only as the fallback during the work, a rollback that is an alias move back

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The property that shapes everything is that two embedding models produce incompatible spaces. A query vector from the new model compared against chunk vectors from the old one yields distances that are arithmetic without meaning. So there is no partial state where a mixed index is usable, and an in-place update is not an option — this is a build-beside-and-swap, using the same alias mechanism the quarterly layout already provides.

The work is dominated by the embedding calls, not by indexing. Ten million chunks against a shared account allowance is the constraint, and it has to be paced so the interactive search path and the extraction pipeline keep working. Each chunk carries `indexed_at` and `pipeline_version`, which is exactly what makes progress measurable and makes a resumed run possible after an interruption.

Verification is the part I would insist on before the swap. The reason for changing models is quality, so the claim must be measured: take a labelled sample of real tender queries with known relevant passages and compare recall on old and new indices. If the new model is not better on this corpus, the migration should not happen, however good the model card looks. This is also the moment to re-check the 768-dimension decision, since truncation behaviour is model-specific.

Two smaller things matter at cutover. Cached query embeddings must be invalidated, which happens naturally because their key includes the model identifier — a detail that costs nothing to include beforehand and is painful to add afterwards. And during the transition, semantic search can fall back to keyword-only with the `degraded` flag, so the feature never disappears entirely.

Rollback is an alias move back to the old indices, which is why they are kept until the new ones have been watched for a day.

</details>

---

### Q3. As this platform grows, where do you draw the line between search and the AI pipeline? They both retrieve from the same corpus.

**Brief answer**
Search answers "find me the passages"; the pipeline answers "compose something from passages". They share retrieval, and they should share exactly that and nothing else — the moment search starts generating, its availability and its ranking become decision-adjacent.

<details>
<summary><strong>Must cover</strong></summary>

- **shared retrieval, different outputs** — passages against composed artifacts
- **availability targets differ** — search is interactive, generation is a job with a handle
- **generated output needs the citation gate** — search results are already their own evidence
- **an answer box inside search is the tempting mistake** — it inherits none of the artifact controls
- **the corpus is the shared contract** — chunk mapping, filters and sensitivity belong to it
- keep egress in one service, degraded keyword search as the search-side fallback

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The shared part is genuine: both embed a query, both retrieve chunks from `corpus-hot`, and both must apply the tenancy and sensitivity filters identically. That common ground belongs to the corpus contract — the chunk mapping, the filters, the citation anchors — and should not be implemented twice.

Everything after retrieval differs. `search-service` returns passages with highlights and scores, within an interactive budget, and nothing behind it can write. `ai-service` composes artifacts over minutes, validates every claim against its source, writes citation rows and is the only deployment with model egress. Those are different availability targets, different failure modes and different security boundaries.

The request that blurs the line is an answer box: a generated summary at the top of the search results. It is appealing and it quietly discards every control. It would put a model call inside an interactive request with a 700 millisecond target. It would give `search-service` egress it does not currently have. And evaluators would read generated text with none of the artifact lifecycle behind it: no stored model identifier, no prompt version, no citation validation, no retention rule, no kill switch.

If that feature were genuinely wanted, I would build it as what it already is. An asynchronous artifact with a job handle, generated by `ai-service`, displayed beside the results rather than inside them. It would follow the same rule as every other artifact: advisory, cited, and never an input to a decision. What I would refuse is the version that looks like a search feature, because then the platform is generating text on a path nobody audits.

</details>

---

## Identity, Access and Secrets

---

### Q1. Where does authentication happen in this platform, and where does authorization happen?

**Brief answer**
Authentication happens at Cognito and is checked at the gateway and again in each service: the token proves who the caller is. Authorization happens in the service, against the row being touched, because only the service knows whether this person may see this bid right now.

<details>
<summary><strong>Must cover</strong></summary>

- **authentication answers "who"** — a signed token from one of two user pools
- **the gateway checks the signature, the service checks it again** — the gateway is a filter, not the authority
- **authorization answers "may they, on this row"** — three of the four checks need the database
- **claims carried** — account type, organization, roles and scope
- **short-lived access tokens** — 15 minutes, with refresh handled centrally
- identity provider federation for staff, multi-factor authentication for vendor submitters

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Authentication is delegated. Staff sign in through the department's own identity provider, federated into `cognito-staff` by Security Assertion Markup Language (SAML). Joiners and leavers are then handled where they are already handled, and no staff password exists on the platform. Vendors self-register into `cognito-vendors`, and Multi-Factor Authentication ([MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity")) is mandatory on any account with the submitter role. Both issue OAuth 2.0 and [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect access tokens signed with [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs").

The token is verified twice. `apigw-edge` validates the signature against the pool's key set, plus expiry and audience, and rejects obvious garbage at the edge. Each service validates it again, because network position is not identity and the gateway is a filter rather than the authority. The claims that travel are the subject, the account type, the organization — an organizational unit for staff or a vendor organization for vendors — the roles and the scope.

Authorization is separate work and happens in the service, because it needs data. Whether a vendor may read a bid depends on whether the bid's `vendor_org_id` matches their claim. Whether an evaluator may read a bid depends on an assignment row, the session's state, and the absence of a recusal. None of that can live in a token without going stale the moment a recusal is filed.

The practical rule is that the token says who you are and roughly what kind of thing you may do, and the database says whether you may do it to this row.

</details>

---

### Q1. Why two Cognito user pools rather than one pool with groups?

**Brief answer**
Because the staff and vendor populations share no data and must never reach each other's records, and a group membership is a much weaker boundary than a separate pool. One misconfigured group or one token audience mistake in a single pool crosses the line that matters most.

<details>
<summary><strong>Must cover</strong></summary>

- **the two populations are genuinely separate** — no shared records, opposite sides of a procurement
- **a group is one attribute** — a single mistake moves a principal across the boundary
- **different authentication requirements** — federated sign-in against self-registration with mandatory MFA
- **a pool compromise stays on one side** — blast radius follows the boundary
- **the account type claim is the first authorization check** — checked before routing
- different token lifetimes per side, vendor sign-in unaffected by an identity provider outage

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The populations are not two kinds of user in one system. They are the two sides of a procurement. Internal staff draft tenders, score bids and sign awards. Vendors register, ask questions and submit. The CRM records about a vendor are department-owned records the vendor does not edit. There is no legitimate operation in which a principal is both.

With one pool, that boundary is a group membership, which is a single attribute on a single record. An administrative mistake, a bug in a self-registration flow, or a misapplied migration puts a vendor account in a staff group. From then on the account type check passes for the wrong person. That check is the first of the four and runs before routing, so everything after it is decided wrongly. With two pools, the boundary is which pool issued the token, and there is no field that moves an account from one to the other.

The pools also want different configuration. Staff federate by SAML to the department's identity provider, so there are no staff passwords here at all. Vendors self-register with mandatory MFA on submitters, and their refresh tokens live slightly longer because they use the platform in a different rhythm. One pool would mean compromising on both.

The failure case shows the benefit clearly. If the department's identity provider has an outage, staff sign-in is blocked and break-glass accounts exist for that. Vendor submission is entirely unaffected, because it depends on a different pool — and a deadline that falls during an identity provider outage is not the vendors' problem.

</details>

---

### Q1. Services authenticate to AWS using IRSA. What is it, and what does it replace?

**Brief answer**
IAM Roles for Service Accounts (IRSA) gives each Kubernetes deployment its own cloud identity through a short-lived token exchanged for temporary credentials. It replaces the two bad alternatives: a shared node role that every pod on the node inherits, and long-lived access keys sitting in a secret.

<details>
<summary><strong>Must cover</strong></summary>

- **identity per deployment, not per node** — the pod's service account maps to a role
- **credentials are short-lived and rotated** — nothing durable to steal from a container
- **it replaces node roles and static keys** — both of which over-grant badly
- **least privilege becomes expressible** — each role names only the prefixes, queues, keys and secrets it needs
- **it is what makes the custody boundary real** — only one role holds the bid key grant
- audit trails attributing calls to a service, a compromised pod bounded by its own role

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Without IRSA there are two ways for a pod to call AWS, and both are poor. A node instance role means every pod scheduled on that node has the same permissions. The role must then be the union of everything anything needs. So a compromise of the least important workload grants the most important one's access. Static access keys in a Kubernetes secret are worse: they are long-lived, they end up copied into a local environment file, and revoking one means finding everywhere it went.

IRSA ties a Kubernetes service account to an IAM role through a trust relationship. The pod receives a short-lived projected token, exchanges it for temporary credentials, and those credentials refresh automatically. There is nothing durable in the container to steal.

What that buys here is that least privilege becomes something you can actually write down. `search-service` cannot read a secret. `ai-service` cannot read the `bids/` prefix. Only `bid-service` holds a grant on `kms-bid-custody`. Each role names the specific object prefixes, queues, keys and secret entries its deployment needs, and nothing else.

That last point is what makes the sealed-bid guarantee enforceable rather than aspirational. The bucket policy on the `bids/` prefix denies read access to every principal except one role, and that role belongs to one deployment. If all services shared a node identity, that policy would be meaningless, and the custody promise would rest on nobody having written the wrong call.

A secondary benefit is attribution: cloud trail entries name the service that made a call, so an unexpected access is traceable to a deployment rather than to "the cluster".

</details>

---

### Q1. What does AWS Secrets Manager hold here, and why is a secret never an environment value in a manifest?

**Brief answer**
It holds the model API key, database credentials with rotation, the SAML signing material, and mesh and mail-relay credentials. A secret in a manifest is a secret in version control, in every build log that echoes configuration, and in every copy of the deployment history.

<details>
<summary><strong>Must cover</strong></summary>

- **what is held** — model key, database credentials, signing material, integration credentials
- **rotation needs a single source** — a value pasted into manifests cannot be rotated
- **a manifest is source control** — the secret spreads everywhere the repository goes
- **the operator pulls and mounts** — pods receive secrets at runtime under their own role
- **scanning is a blocking gate** — a credential scan runs in the pipeline and before commit
- **Terraform state is sensitive too** — encrypted, versioned, readable only by the deploy roles
- automatic rotation for the database, alerting on the scheduled ones

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The inventory is small and deliberate: the model endpoint's key, database credentials, the SAML signing material used for staff federation, and credentials for the service mesh and mail relay.

The reason none of these appears in a manifest is that a manifest is code. Put a database password in one and it is in the repository forever. It is in every fork and clone, in the pull request that added it, and in the build log of any job that prints its configuration. Rotating it then means finding every one of those places, which is why credentials that live in manifests are almost never rotated.

Instead, secrets live in Secrets Manager and are pulled at runtime by the External Secrets Operator into a Kubernetes secret, under the service's own role, and mounted. The database credentials rotate automatically; the others rotate on a schedule with an alert when one is due. Because there is one source, rotation is a change in one place rather than a search.

Two supporting controls matter as much as the storage choice. A credential scan runs as a blocking stage in the pipeline and as a pre-commit hook, so an accidental key in a commit fails the build rather than reaching the default branch. And Terraform state is treated as sensitive in its own right — encrypted, versioned, and readable only by the continuous integration roles — because state files contain resource identifiers and sometimes more than people expect.

The related point is that there are no long-lived deployment credentials at all: the pipeline assumes a role by federation rather than holding a key. The best-protected secret is the one that does not exist.

</details>

---

### Q2. Walk me through the four authorization checks in order. Why that order?

**Brief answer**
Account type, then tenant scope, then role, then assignment and recusal. Each is cheaper and broader than the next, and the first failure ends the request — so the checks that need no database lookup run before the ones that do.

<details>
<summary><strong>Must cover</strong></summary>

- **account type first** — a vendor token can never reach an internal endpoint, checked before routing
- **tenant scope second** — the organization claim must match the row
- **role third** — what this kind of user may do within their side
- **assignment and recusal last** — attribute-based, and the only check that needs session state
- **cheapest and broadest first** — a failure ends the request, so ordering is both security and cost
- **recusal is irreversible for the session** — it cannot be undone to regain access
- denial recorded as an audit event, checks applied per object rather than per collection

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first check is the account type claim, and it runs before routing rather than inside a handler. A vendor token must never reach an internal endpoint at all. Doing this first means the broadest possible boundary is enforced without touching the database, and it cannot be bypassed by a handler that forgot a decorator.

The second is tenant scope. A vendor principal's organization claim must match the row's `vendor_org_id`. It is enforced in the repository layer as a mandatory predicate, so this is not a check a query can skip — a query written without it does not compile past the base class. This placement is deliberate: tenancy is about which rows exist for you, and the cheapest correct behaviour is for the wrong rows never to be selected.

The third is role-based access control within the account type — procurement officer, evaluator, committee chair, legal, finance, platform administrator on the staff side; administrator, submitter, viewer on the vendor side. This answers what kind of operation a person may perform.

The fourth is attribute-based and applies to the evaluation path. An evaluator may read a bid only if an assignment row links them to that tender's session, the session is past unsealing, and no recusal exists for the assignment. It is last because it is the most specific and the most expensive, needing session and assignment state.

The ordering is not only about cost. Each check is a strictly narrower question than the one before, so a failure at any level is unambiguous — the log and the audit entry say which boundary was crossed, rather than "denied". And a recusal is irreversible for the session, which means the last check cannot be reversed by the person it constrains.

</details>

---

### Q2. Tenant scope is described as a mandatory predicate in the repository layer. How do you make that impossible to forget rather than merely required?

**Brief answer**
By removing the ability to construct a query without it. The base repository takes the principal's scope at construction and applies the predicate itself. No public method returns an unscoped query. So forgetting it is a compile or construction failure, not a review finding.

<details>
<summary><strong>Must cover</strong></summary>

- **a rule enforced by review is not enforced** — the failure is silent and looks correct
- **scope supplied at construction** — the repository cannot exist without a principal
- **no unscoped escape hatch in the public surface** — the unsafe call is not available to write
- **a test that fails when the predicate is missing** — the guard needs its own known-fail case
- **row-level policy in the database as a second layer** — defence that survives a new service
- **the failure is invisible without a guard** — an unscoped query returns more data and no error
- named administrative paths that are explicitly unscoped and audited

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

This is the class of bug I would design hardest against, because it does not announce itself. A query missing its tenant predicate returns results, renders fine, and passes tests written by someone who only has one organization's data in their fixture. It is discovered when a vendor sees another vendor's record.

So the goal is to make the unsafe version unavailable rather than discouraged. The repository base class takes the principal's scope as a constructor argument and applies the predicate when it builds the statement. Handlers receive a repository that is already scoped; there is no method that hands back a raw, unscoped query builder. A developer adding a new query inherits the predicate because it is not theirs to add.

Administrative paths that genuinely need to cross organizations exist — a platform administrator managing vendor qualification categories, for example. Those are named explicitly, live in a separate repository type, and write an audit entry. The point is that crossing the boundary is a visible, deliberate act with a name, not the default behaviour of a forgotten filter.

Then it is tested as a rule rather than assumed. A test creates two vendor organizations, queries as one, and asserts the other's rows are absent — and crucially, it is verified by breaking the predicate deliberately and confirming the test fails. A guard that has never failed has not been shown to guard anything.

Row-level security policies in PostgreSQL enforce the same predicate at the database itself. That is the second layer I would add if I wanted the rule to survive a future service written by someone who never read any of this. The boundary then holds even for a connection the application layer does not control.

</details>

---

### Q2. Access tokens live 15 minutes. What does that number actually buy, and what would change it?

**Brief answer**
It bounds how long a stolen token is useful and how long a revoked user keeps working. Shortening it increases refresh traffic and the number of times an identity provider outage becomes visible; lengthening it extends the window in which a leaked token still opens doors.

<details>
<summary><strong>Must cover</strong></summary>

- **the window of a stolen token** — a bearer token is useful to anyone holding it
- **revocation lag** — a disabled account keeps working until its access token expires
- **refresh tokens carry the session** — 8 hours for staff, 12 for vendors, revocable centrally
- **shorter costs availability and load** — more refreshes, more dependence on the identity path
- **the deadline surge argues against very short tokens** — a refresh storm at the worst minute
- **authorization is checked per request anyway** — a recusal takes effect immediately, unlike a role
- key set caching, the audience and issuer checks that go with expiry

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

An access token is a bearer credential: whoever holds it can use it until it expires. Fifteen minutes is a statement about that exposure. If a token leaks through a log, a browser extension or a shared device, the useful window is a quarter of an hour rather than a working day.

The second thing it bounds is revocation lag. Disabling an account stops new tokens being issued, but an access token already in the wild keeps working until it expires, because verifying it requires no call to the pool. Fifteen minutes is the worst case for a leaver still being able to read tender data.

The costs of shortening it further are real. Every expiry means a refresh, and refreshes depend on the identity path being available. During a deadline surge, hundreds of vendors are active at once. Five-minute tokens would triple the refresh traffic at exactly the busiest moment. An identity provider hiccup would then become visible to users three times as often.

Lengthening it trades in the other direction, and for this platform I would resist that. The data is sealed bids and police procurement records, and a token that works for hours is a much better prize.

One thing the token lifetime does not govern is fine-grained authorization. Assignment and recusal are checked against the database on every request, so a recusal filed now takes effect now, regardless of the token in hand. That separation is what lets the token lifetime be a security-and-load decision rather than a correctness one.

</details>

---

### Q2. Break-glass administrator accounts exist for an identity provider outage. How do you make accounts like that safe to have?

**Brief answer**
By making them useless in normal times and impossible to use quietly. They are disabled by default, require a two-person action to enable, are protected by hardware multi-factor devices, and every use pages the security lead and writes an audit entry that cannot be suppressed.

<details>
<summary><strong>Must cover</strong></summary>

- **disabled by default** — the account is not a standing credential
- **two-person enablement** — one compromised administrator is not enough
- **hardware multi-factor** — phishing-resistant, not a code in an application
- **every use pages a human** — the alert is the control, not the log entry
- **an unsuppressable audit entry** — including any attempt to disable the alerting
- **rehearsed, and re-disabled afterwards** — an untested emergency path fails when needed
- credentials held in escrow, scope limited to restoring access

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A break-glass account is a deliberate hole in the identity model. It is obviously a risk. The question is whether that risk is smaller than being locked out of the system during a tender window.

Four controls make it defensible. The account is disabled by default, so it is not a credential someone can simply use. Enabling it takes two people acting together, so a single compromised or coerced administrator cannot reach it. Authentication uses a hardware device rather than a code generated in an application, which resists phishing, the most likely path to an administrator account. And every use writes an audit entry and pages the security lead immediately.

The paging matters more than the logging. A log entry is evidence after the fact; a page means a human learns about the use while it is happening and can confirm whether it was expected. The audit entry is specifically designed not to be suppressible, including by the account itself, and any attempt to change that alerting is itself alerted on.

Two operational details complete it. The credentials are held in escrow: split, sealed and physically stored. They are not in a password manager that depends on the identity system being available. A break-glass path that depends on the thing that is broken is decoration. And it is rehearsed: the procedure is exercised, and part of that exercise is confirming the account is disabled again afterwards, since the most common failure of emergency access is that it quietly stays enabled.

The scope is limited too. This account restores access and administers users. It does not carry a grant on the bid custody key, because no emergency requires reading a sealed bid.

</details>

---

### Q3. Segregation of duties is implemented as database constraints and service checks rather than in a policy engine. Defend that.

**Brief answer**
Because these rules are properties of the data, and the data outlives every service that touches it. A constraint rejecting an evaluator who authored the tender cannot be bypassed by a script, a migration or a future service, and an external policy engine can be unavailable, misconfigured or simply not consulted.

<details>
<summary><strong>Must cover</strong></summary>

- **the rules are relational facts** — who created the tender, who has a locked scorecard
- **every writer is covered** — scripts, imports and future services included
- **a policy engine is another dependency** — availability and configuration become part of correctness
- **the constraint cannot be forgotten** — there is no code path that skips it
- **the award rule is a completeness check** — no signature unless every non-recused assignment is locked
- **where a policy engine would be better** — broad, frequently changing access rules
- evidence for an auditor, recusal as an irreversible row

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Look at what the rules actually are. An evaluator assignment is rejected if that staff user created the tender or any of its versions. An award is rejected unless the signer is the committee chair and every non-recused assignment has a locked scorecard. Both are statements about rows that already exist — authorship, assignments, scorecard states. They are relational questions, and the database is where relational questions are answered atomically, inside the transaction that would otherwise create the violation.

The durability argument is the strong one. A service is one writer among several over a system's life: there are repair scripts, imports, migrations, and eventually another service written by someone who never read this design. Application-level checks cover exactly the paths their authors remembered. A constraint covers every path there will ever be.

A policy engine adds a dependency to the correctness of an award. It has to be reachable when the award is signed, configured with the right policy version, and actually consulted by the call path. Each of those is a way for the rule to quietly not apply, and in a procurement dispute "the policy service was returning stale decisions that week" is not an answer anyone wants to give.

I would not extend this argument everywhere. Broad, frequently changing access rules — which roles may read which reports, adjusted quarterly — are miserable as constraints and are exactly what a policy engine is good at. The distinction is that those decisions are about convenience and workflow, while these two decide whether an award stands.

The auditor's view settles it for me. Showing a constraint definition is showing that the violation could not have been recorded. Showing a policy file is showing what the system was meant to do.

</details>

---

### Q3. Walk me through the whole custody chain for a sealed bid, and tell me where it could break.

**Brief answer**
Bytes go straight to a restricted prefix under a per-bid key, the key material is sealed at submission, and the grant that allows decryption is created only when unsealing succeeds. It could break at the bucket policy, at the grant condition, at the presigned link, and at the point where a document is re-used outside the bid path.

<details>
<summary><strong>Must cover</strong></summary>

- **upload lands encrypted in a restricted prefix** — only one role may read it, with no console path
- **a per-bid data key sealed at submission** — stored encrypted on the manifest
- **the grant is created at unsealing, not before** — the decrypt capability does not exist earlier
- **unsealing has four conditions** — past the deadline, correct state, chair role, session exists
- **reads are short-lived and audited before the link is issued** — the one audit-on-read in the system
- **content hashes captured at seal time** — a substituted object is detectable and disqualifying
- **where it could break** — a widened bucket policy, a loosened grant condition, a leaked link, a document reachable through another owner
- key policy protection against deletion, no administrator exception

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The chain starts before submission. A vendor uploads to `s3-documents/bids/` through a presigned link, written with server-side encryption under `kms-bid-custody`. The bucket policy denies read access on that prefix to every principal except `bid-service`'s role — no console path, no administrator exception.

At submission, a per-bid data key is generated and the manifest key is sealed, stored encrypted in `bid_manifest.sealed_data_key`. At the same moment each entry's content hash is captured, so an object replaced afterwards is detectable by comparison and the mismatch disqualifies the bid rather than being silently repaired.

The decisive property is that the capability to decrypt does not exist yet. The grant permitting `bid-service` to decrypt is created only when the unseal call succeeds. That call requires four things: the tender is past its closing time, the tender is in evaluation, the caller holds the committee chair role, and an evaluation session exists. Until then, no principal — staff, administrator or service — can turn stored bytes into readable content.

After unsealing, reads are still narrow. `bid-service` alone issues a presigned link, it expires in 60 seconds, and an audit entry is written before the link is returned. That is the system's one audit-on-read, scoped deliberately to this path.

Where could it break? Four places. A bucket policy widened during an unrelated change, which is why policies are Terraform-managed and drift-checked nightly. A grant condition loosened to make testing easier, which is why the unseal preconditions deserve their own contract test. A presigned link forwarded within its 60 seconds — short but not zero, and the audit entry is what makes that traceable. And the subtlest one: a document reachable through a different owner reference, so the bid path's controls are bypassed by asking the document service instead. That is why document content access is subject to the same custody check, and why I would test it from the document endpoint rather than only from the bid endpoint.

</details>

---

### Q3. The department asks you to let the platform team recover a bid for a vendor who lost their own copy. What do you say?

**Brief answer**
Before the deadline, no — and not because of policy, but because the system is built so that no human principal can read sealed content, and I would not remove that. After unsealing it is an ordinary access question, and I would answer it through the existing audited path rather than a new one.

<details>
<summary><strong>Must cover</strong></summary>

- **separate the request into two cases** — before unsealing and after
- **before unsealing the answer is structural** — the grant does not exist, and creating an exception removes the guarantee
- **the exception is what the threat model names first** — an insider reading a competitor's bid
- **after unsealing it is a normal authorized read** — presigned, short-lived, audited before issue
- **offer the real remedy** — the vendor's own receipt, hashes, and the ability to resubmit before the deadline
- **put the decision where it belongs** — say clearly what would be lost, then let the department decide knowingly
- audit evidence as the department's own protection in a dispute

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would first split the request, because it contains two very different asks.

After unsealing, this is ordinary. The bid is readable by authorized principals, `bid-service` can issue a short-lived link, and an audit entry is written before the link is returned. If the department wants a documented support process for handing a vendor back their own submission at that stage, that is a workflow, not an architectural change.

Before the deadline, the answer is no, and the reason is not that a rule forbids it. It is that the capability does not exist: the key grant is created only at unsealing, and the bucket policy admits one role. Building an exception means building a path by which a member of staff can read a sealed bid before the deadline. That is the first entry in the threat model: an insider reading a competitor's submission. Once that path exists, the guarantee is no longer "no human principal can read this"; it is "only authorised staff do", and every award becomes arguable by anyone who can allege misuse. The audit trail would show a read; it could not show what was done with what was read.

I would not stop at no. The vendor's actual problem is usually that they cannot confirm what they submitted. They already have the submission receipt with its sealed timestamp and ledger hash, and the manifest records each document's hash — enough to verify a local copy is the one submitted. If they genuinely lost the content and the deadline has not passed, the remedy is to withdraw and resubmit, which the platform supports and the ledger records.

And I would make the trade-off explicit to the department rather than deciding alone. If they still want the exception after hearing what it costs, that is their decision to make knowingly. I would want it written down. The audit trail is the department's protection as much as the vendors'.

</details>

---

## Cloud Infrastructure, Kubernetes and Delivery

---

### Q1. Terraform state lives in S3 with DynamoDB locking. What does the lock prevent?

**Brief answer**
It stops two applies running against the same state at once. Without it, two concurrent runs read the same state, and each plans against a world the other is changing. The second write overwrites the first. The state file is then describing infrastructure that does not exist.

<details>
<summary><strong>Must cover</strong></summary>

- **state is the record of what exists** — a corrupted state means resources nobody tracks
- **the lock serializes applies** — one writer at a time per environment
- **concurrent runs are normal, not exotic** — a merge and a nightly drift check overlap easily
- **one state file per environment** — a failure is contained to one environment
- **recovery relies on versioning** — the bucket keeps previous state versions
- orphaned resources as the real damage, the lock released on failure

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Terraform decides what to change by comparing configuration against state. State is therefore the record of which real resources correspond to which declarations, and if it is wrong, the next plan is wrong in a way that is hard to see.

Two simultaneous applies are how it goes wrong. Both read the same state, both compute a plan based on it, and both write their result. The second write wins, so the first run's changes are real in the cloud but absent from state. Those resources are now orphaned: Terraform does not know they exist, will not update them, and may create duplicates beside them. Cleaning that up means reconciling a live account against a file by hand, which is slow, risky and usually done under pressure.

Concurrency is not unusual. A merge to the protected branch triggers an apply while the nightly drift check is running, or two pull requests merge within a minute of each other. The lock makes the second wait rather than race.

Two supporting decisions matter as much. There is one state file per environment, so a problem in staging cannot touch production's record. And the bucket is versioned, so recovery from a bad write is restoring a previous state version rather than reconstructing it.

The related discipline is that nothing is created by hand at all. A resource that exists without a declaration is treated as an incident, which is what keeps state meaningful in the first place — locking protects a record that is only valuable if it is complete.

</details>

---

### Q1. `dev` and `staging` are namespaces in one cluster, but `prod` is a separate cluster in a separate account. Why the inconsistency?

**Brief answer**
It is not an inconsistency, it is the line where isolation has to become real. A namespace is an organizational boundary with shared control plane, nodes and account; that is fine between two non-production environments and not fine between anything and sealed bid content.

<details>
<summary><strong>Must cover</strong></summary>

- **a namespace is not a security boundary** — shared nodes, control plane and account permissions
- **production holds sealed bids** — the data class justifies the separation
- **account separation bounds credential blast radius** — no trust relationship between them
- **cost and convenience justify sharing below production** — two environments, one cluster
- **production data is never copied down** — fixtures are generated, not restored
- separate state files and roles, network policy between the lower namespaces

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Namespaces separate names, quotas and default network policy. They do not separate the control plane, the nodes, the container runtime, or the cloud account's permissions. A container escape, a node-level compromise or an over-broad role in a shared account reaches everything on that cluster. For two environments that hold generated test data, that risk is acceptable and the saving is real — one cluster, one set of node groups, one upgrade cycle.

Production holds sealed vendor bids, police procurement records and the audit trail that decides disputes. Against that data class, "isolated by namespace" is not a claim I would want to defend. So production is a separate cluster in a separate AWS account with no trust relationship to the lower one. A compromised credential in the development account grants nothing in production, and there is no role chain to walk.

The account boundary carries other things with it. Snapshots are copied to a separate account too, so a compromise of the production account cannot destroy the backups. Terraform state is per environment, and the deployment roles are restricted by environment in the federation trust policy, so a workflow on a feature branch cannot assume the production role.

The rule that completes it is about data direction: production data is never copied into a lower environment. Test fixtures are generated. That is what keeps the lower cluster's weaker isolation honest — there is nothing there worth the stronger boundary.

</details>

---

### Q1. What does Route 53 do for this platform beyond turning a name into an address?

**Brief answer**
It owns the public zone and carries health-checked records, so a failing endpoint stops receiving traffic. It also holds the validation records that let ACM issue and renew certificates. Those certificates terminate Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")) at CloudFront and the load balancer.

<details>
<summary><strong>Must cover</strong></summary>

- **the public zone is the entry point** — the vendor and staff portals resolve through it
- **health-checked records** — traffic follows health rather than a static answer
- **certificate validation lives in DNS** — ACM renewal depends on those records existing
- **an expired certificate is a full outage** — for a deadline-driven platform, on the worst possible day
- **the zone is Terraform-managed** — a hand-edited record is the classic silent breakage
- short record lifetimes for failover, certificates terminating at two places

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Three roles, and the third is the one people forget until it bites.

First, it owns the public zone that the vendor portal and the internal staff portal resolve through, in front of CloudFront and the load balancer. Second, records are health-checked, so an endpoint that fails its check stops being handed to clients, with record lifetimes short enough that a change propagates in minutes rather than hours.

Third, it holds the validation records for the certificates issued by ACM. Those certificates terminate TLS at CloudFront and at the load balancer, and they renew automatically — but only while the validation records remain in place. Delete or alter them during an unrelated cleanup and renewal silently fails. Nobody notices until the certificate expires, at which point every client sees a security warning and the platform is entirely unusable. On a system where vendors submit against a legal deadline, that is the worst possible failure, and it always arrives at an awkward hour.

This is why the zone is Terraform-managed like everything else, with the nightly drift check watching it. A record edited by hand in a console to fix something quickly is exactly how the validation record disappears. The drift check turns that into a visible finding rather than a time bomb.

I would also monitor certificate expiry directly as a separate alert, rather than trusting that automatic renewal is happening. Renewal is a process, and a process that nobody observes is an assumption.

</details>

---

### Q1. The local environment is Docker Compose with LocalStack and a recorded model stub. What does that reproduce, and what can it not?

**Brief answer**
It reproduces every dependency's interface — PostgreSQL, Redis, OpenSearch, the AWS services through LocalStack, and the model through a recorded stub — so a developer needs no cloud account. It cannot reproduce scale, real network behaviour, the identity federation, or the sharp edges of the managed services.

<details>
<summary><strong>Must cover</strong></summary>

- **interfaces, not scale** — the calls are the same, the conditions are not
- **no cloud account needed** — onboarding and integration tests both use it
- **a recorded model stub** — no test reaches the third-party endpoint, so tests are deterministic and free
- **what is missing** — failover, throttling, replica lag, real identity federation
- **one settings schema across Compose and Helm** — a variable cannot exist locally and be absent in production
- **the pipeline runs against this too** — integration tests use real dependencies, not mocks
- the sealing path as the case where the gap matters most

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

What it gets right is the contract. It runs real PostgreSQL, real Redis and real OpenSearch, with LocalStack standing in for S3, SQS and the key service. Code therefore exercises actual clients, and actual query and message semantics. Mocks would instead agree with whatever the developer believed. The model client is a recorded stub, so no test reaches the third party: tests are deterministic, free, and do not send anything outward. The same environment backs the integration test stage in the pipeline, which is what stops local and continuous integration from drifting apart.

The gaps are worth naming precisely, because they decide what has to be tested elsewhere. There is no failover, so the behaviour of sealing during a one-to-two-minute write outage cannot be observed here. There is no replica lag, so the rule that eligibility reads the primary cannot be demonstrated locally without artificial delay. Throttling and quotas do not exist, so a rate-limit path is only reachable by a fault injected on purpose. Identity federation is stubbed, so a misconfigured audience or a group mapping error will not appear. And managed-service behaviour differs from its local imitation in exactly the corners that matter — visibility timeouts, eventual consistency, key policy evaluation.

The discipline that keeps the gap from widening is the shared settings schema. The Compose file and the Helm values validate against the same Pydantic model. So a configuration variable cannot exist locally and be missing in production.

What I would not do is treat local passing as evidence about the sealing path. That path is verified by contract tests with a known-fail case, by benchmarks against a seeded corpus, and by the restore drills — not by the fact that it worked on a laptop.

</details>

---

### Q2. Walk me through the delivery pipeline stage by stage. Which stage would you refuse to remove?

**Brief answer**
Lint and type checking, unit tests, then integration tests against real dependencies. Then sealing contract tests, a migration up-and-down check, and performance benchmarks. Then container build and scan, staging with a smoke suite, and a manual approval for production. The one I would refuse to remove is the sealing contract test, because it is the only stage that proves the platform's central promise.

<details>
<summary><strong>Must cover</strong></summary>

- **static checks first** — the cheapest failures fail fastest
- **integration tests against real dependencies** — in containers, not mocks
- **sealing contract tests with a known-fail case** — a late bid must be rejected
- **migration upgrade and downgrade against a restored schema** — expand/contract proven, not assumed
- **benchmarks compared to the recorded budget** — a regression fails the build
- **build, scan, push by commit hash** — the image is identified by what produced it
- **staging, smoke, then a human approval** — the last gate is deliberate
- no path to production outside the pipeline, federated credentials only

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The order is cheapest-first. Linting and strict type checking run on every package, then unit tests. Then integration tests against real PostgreSQL, Redis, OpenSearch and LocalStack in containers, with the recorded model stub so nothing reaches the third party.

Stage four is the sealing contract tests, and that is my answer to the second half of the question. Among them is a deliberate known-fail case: a bid committed after the closing time must be rejected, and the test fails if it is accepted. Everything else in this platform — the services, the pipeline, the search — exists to support a promise that a sealed bid is confidential until the deadline and provably on time or not. This stage is the only place that promise is mechanically checked. A suite that only ever passes proves nothing, which is exactly why a case that must fail is included.

Stage five runs an Alembic upgrade and then a downgrade against a restored copy of the staging schema, so the expand/contract discipline is proven rather than trusted — the property that makes rollback a redeploy.

Stage six runs sealing and hybrid search benchmarks against a seeded corpus and compares them with the budget recorded in the design. A regression beyond 20% fails the build instead of filing a ticket for later.

Stage seven builds the container, scans it, and pushes to the registry tagged by commit hash, so a running image traces back to the commit that produced it. Stage eight deploys to staging, runs a smoke suite, and then waits for a human approval before production.

The frame around all of it is that this is the only path to production. No person holds credentials that can deploy; the workflow assumes a role by federation, per environment.

</details>

---

### Q2. The sealing test suite includes a case that is expected to fail. Why is that in the pipeline rather than in someone's notes?

**Brief answer**
Because a test suite that only ever passes cannot distinguish "the rule is enforced" from "the test does not exercise the rule". A case that must fail is the control: if a late bid is ever accepted, the build breaks, which is the only evidence that the deadline check is doing anything.

<details>
<summary><strong>Must cover</strong></summary>

- **a passing suite is ambiguous** — enforcement and a broken test look identical
- **the control is a known-fail input** — a bid committed after the closing time
- **the rule decides legal outcomes** — lateness is the platform's most consequential verdict
- **regressions here are silent** — nothing in production announces that a late bid was accepted
- **the same discipline elsewhere** — drift checks, redaction assertions, ledger verification
- **three states, not two** — a stage that could not run is not a pass
- the grace window as the case that makes the boundary subtle

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Consider the alternative. The suite contains tests that submit bids before the deadline and assert receipts. They pass. Someone then refactors the sealing transaction and the deadline comparison stops being applied. Every one of those tests still passes, because they were all submitting on time. The suite is green and the guarantee is gone.

A known-fail case closes that. It submits after the closing time and asserts rejection. If the check is removed, that test fails and the build stops. It is the only member of the suite whose result changes when the rule breaks.

Why it matters here more than in most systems: lateness is the most consequential verdict this platform issues. A late bid accepted as on time is not a defect a user reports. The vendor is pleased and the competitors cannot see it. The problem surfaces in a dispute months later, when the ledger is examined. There is no production signal for it. The pipeline is the only place it can be caught.

The boundary is also subtle enough to deserve testing rather than reading. Sealing accepts a commit whose transaction started before the closing time, and records both timestamps. So the rule is not "committed before the deadline" and not "started before the deadline and we hope", and a refactor can easily move which timestamp is compared.

The same thinking appears elsewhere in the design: a planted marker string asserts no bid content reaches the logs, the migration stage runs a downgrade, and the ledger chain is recomputed rather than assumed intact. In each case the check has a way to fail, and something has confirmed it does.

</details>

---

### Q2. `bid-service` is never deployed within an hour of a tender closing. How is that enforced, and what does it cost?

**Brief answer**
The pipeline reads the nearest closing time and refuses the deployment, so it is a gate rather than a convention. The cost is that the most correctness-critical service is also the one whose urgent fixes can be blocked, which has to be an explicit, audited override rather than an argument at the time.

<details>
<summary><strong>Must cover</strong></summary>

- **the pipeline checks the data** — nearest `closes_at`, refusing rather than warning
- **rolling a pod during sealing is a live risk** — in-flight transactions and connection churn at the worst minute
- **the cost is delayed fixes** — including a fix to this very service
- **an override must exist and be visible** — a documented, logged, human decision
- **closing times are known days ahead** — release planning can avoid the window
- **other services still deploy** — the restriction is scoped to custody
- canary treatment for the two third-party-dependent services, the deadline as immovable

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Enforcement is mechanical. Before rolling `bid-service`, the pipeline queries the nearest tender closing time and refuses if it is within an hour. That makes it a gate, not an instruction in a runbook that a person applies under pressure at the moment they are least likely to apply it.

The risk it addresses is specific. A rolling update terminates pods holding in-flight sealing transactions. Those transactions fail cleanly and the client retries with its idempotency key. But the failures land in the exact minutes when hundreds of vendors are submitting against an immovable deadline. A new image is also, by definition, the version with the least production evidence behind it. This is the path where a defect is least recoverable. A bid rejected because of a deployment is a vendor excluded from a procurement.

The cost is real and worth stating rather than glossing. If a bug in `bid-service` is discovered forty minutes before a closing, the mechanism that protects the window also blocks the fix. So an override has to exist, and it has to be a deliberate, recorded human decision — named approver, reason, and an audit entry — not a flag someone discovers and sets quietly. A gate with no override becomes a gate people route around.

Two things reduce how often this hurts. Closing times are known days in advance, so release scheduling can avoid them. The restriction is also scoped: other services deploy normally. `ai-service` and `search-service` go out as canaries, because their behaviour depends on a third party and on query shapes staging does not reproduce.

</details>

---

### Q2. The workflow assumes an AWS role through federation rather than holding a key. What must the trust policy restrict, and why each condition?

**Brief answer**
It must restrict the repository, the branch or tag, and the environment. Without those, anyone whose workflow can obtain a token from the same identity provider can assume the role — including a workflow on a fork or a feature branch of this repository.

<details>
<summary><strong>Must cover</strong></summary>

- **the identity provider alone is not a boundary** — every repository using it presents similar tokens
- **restrict by repository** — otherwise another project's workflow can assume the role
- **restrict by branch or environment** — a feature branch must not reach production
- **pull requests from forks are the classic hole** — untrusted code proposing changes
- **the role's own permissions still matter** — federation replaces the credential, not least privilege
- **no long-lived key exists to steal** — the property that makes this worth doing
- separate roles per environment, credential scanning as the backstop

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Federation swaps a stored key for a short-lived token, which removes the worst risk outright. There is no long-lived deployment credential in a secret store, a laptop or a build log. So there is nothing to leak and nothing to rotate.

What it introduces is a trust decision. The cloud account trusts tokens from the continuous integration provider's identity service, and every workflow on that platform gets tokens from the same issuer. So the trust policy must narrow it on the claims inside the token.

Repository first: only this repository may assume this role. Without that condition, any project on the same platform can request a token and assume it. Branch or environment second: the production role is assumable only from the protected branch, or through a named deployment environment with its own approval. A feature branch runs the same workflow file with the same steps, and the only thing that should stop it reaching production is this condition.

The fork case is the one that catches people. A pull request from a fork runs workflow code the repository's maintainers have not reviewed. If the policy allows any reference from the repository, a proposed change can be crafted to assume the role and do as it pleases. Restricting by branch and by environment closes it, and workflows triggered by external pull requests should not be able to request the token at all.

Federation does not replace least privilege. The role still grants only what deployment needs, and there is a separate role per environment, so a mistake in the staging workflow cannot touch production. The credential scan in the pipeline remains as a backstop for the secrets that federation does not cover, such as the model key.

</details>

---

### Q3. `document-service` scales on processor use, but with a replica floor raised on a schedule derived from tender closing times. Why is reactive autoscaling not enough?

**Brief answer**
Because reactive scaling responds to load that has already arrived. The surge is roughly tenfold in a minute or two, and by the time metrics rise, pods are scheduled and containers are ready, the errors have already happened. The closing times are known days ahead, so this is scheduling, not guessing.

<details>
<summary><strong>Must cover</strong></summary>

- **autoscaling has a lag** — metric window, scheduling and readiness all cost time
- **the surge is faster than the loop** — tenfold in minutes, not gradually
- **the trigger is known in advance** — `closes_at` is data, not a prediction
- **pre-scale the floor, keep reactive scaling above it** — the two are complementary
- **what happens without it** — presign failures at the moment vendors cannot retry later
- **other layers absorb the rest** — presigned uploads, edge-cached polling, per-tender locks
- node capacity as the slower constraint, scale-down after the window

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A horizontal autoscaler works on a feedback loop: observe a metric, compare with a target, change the replica count. Each step has latency — the metric window, the scaling decision, pod scheduling, image pull if the node is cold, and the readiness probe. Under a gradual ramp that is fine. The surge runs from 25 to about 260 requests per second inside a couple of minutes. The loop is still catching up when the peak has passed. The requests that failed in the meantime were the ones that mattered.

The alternative here is not cleverness, it is data. The platform knows every tender's closing time, and those times are set days in advance. Raising the replica floor on a schedule derived from them is not a forecast, it is reading a column. Reactive scaling still runs above that floor and handles anything the schedule underestimates.

The consequence of getting it wrong is disproportionate. The surge is dominated by presigned URL issue, upload-progress polling and the sealing commit, and a vendor who cannot get a presigned link at three minutes to the deadline cannot simply come back later. Everything else on that path is already designed to be cheap. Bytes go straight to S3. Status polling is cached for five seconds at the edge, so a client polling every two seconds reaches the origin at most once per five. And locks are per tender rather than global. Pre-scaling is what stops the one remaining synchronous call from being the weak point.

One thing to watch is that pod scaling assumes nodes exist. If the cluster autoscaler has to add nodes, the delay is minutes rather than seconds, so the scheduled floor has to account for node capacity and not just replicas. And the floor comes back down after the window, so this costs capacity for an hour, not permanently.

</details>

---

### Q3. The nightly drift check reports a security group changed by hand. What is the correct response?

**Brief answer**
Treat it as an incident, not a tidy-up. Find out what the change allows and whether it was used, then restore the declared state through the pipeline. The important half is afterwards: someone had console access that let them do it, and the drift check caught it a day late.

<details>
<summary><strong>Must cover</strong></summary>

- **first question is what it permits** — a widened ingress rule is a potential exposure
- **check whether it was used** — network and access logs over the whole window
- **restore through Terraform, not by hand** — the fix must not repeat the cause
- **understand why someone needed it** — a blocked legitimate need will recur
- **a day of detection lag** — nightly is the current answer, and it has a cost
- **access review follows** — who can change production infrastructure directly
- the declared rule that a hand-made resource is an incident, security groups referencing groups rather than ranges

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first question is what the change actually permits. A security group edit can be harmless or can expose a database to a wider range. Until that is known, treat it as potential exposure. The design's own convention helps: security groups reference other security groups rather than address ranges, so a hand-edited rule using a raw range is doubly out of pattern and easy to spot.

The second question is whether anything used it. That means access and flow logs across the entire window between the last clean check and this one — not just since it was noticed — because the change may be a day old.

Only then comes remediation, and it goes through the pipeline. Re-running apply restores the declared state. Fixing it by hand in the console would be repeating the behaviour that caused the finding, and it would leave nothing in the history explaining what happened.

Then the part that actually matters. Somebody had permissions to change production infrastructure outside Terraform, and in a model where the pipeline is the only path to production, that is the finding. Either those permissions should not exist, or there is a legitimate need the pipeline does not serve. If it is the second, the need will recur. It then belongs in the configuration rather than in someone's console session.

Last, the detection lag. Nightly means up to 24 hours of an undetected change to production networking. That is a deliberate trade against noise and cost, and it is fine for catching mistakes. It is not fine as a security control, which is why the change alerting on the key policies is separate and immediate. If hand edits happened more than once, I would argue for continuous configuration monitoring on the network and identity resources rather than a faster full drift check.

</details>

---

### Q3. A performance regression beyond 20% fails the build. Defend the number and the placement.

**Brief answer**
The number is a threshold chosen to sit above benchmark noise and below the headroom the latency budget actually has. The placement — blocking a build rather than filing a ticket — is the real decision, because performance work that becomes a ticket is performance work that does not happen.

<details>
<summary><strong>Must cover</strong></summary>

- **the threshold must exceed measurement noise** — a seeded corpus on shared runners varies
- **it must sit inside the real headroom** — sealing measures 208 ms against a 1.2 s target
- **relative, not absolute** — it catches the change, not the accumulated position
- **blocking makes it a decision at the right moment** — the author is present and the change is small
- **a ticket defers it indefinitely** — regressions accumulate until one becomes an incident
- **it needs an override** — a justified regression is a legitimate outcome, recorded
- the budget in the design as the comparison point, the surge as the case with least margin

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Two constraints bracket the number. Below it is noise: benchmarks run on shared runners against a seeded corpus, and 5% swings mean nothing. A threshold inside that band produces failures nobody believes, and a gate nobody believes gets disabled. Above it is the actual headroom. Sealing measures about 208 milliseconds typical and 798 in the worst case against a 1.2 second target; hybrid search measures 488 cold against 700. A single change that costs a fifth of the current figure is well inside the budget, which is why it is worth catching rather than panicking about — it is a signal, not an outage.

The weakness of a relative threshold is worth admitting: four consecutive 15% regressions pass individually and nearly double the time between them. So the absolute numbers are tracked against the recorded budget as well, and the budget is the comparison point in the design rather than a moving average of recent builds.

The placement is the part I would defend hardest. Failing the build puts the decision in front of the person who caused it, while the change is small and the cause is obvious. A ticket puts it in a backlog where it competes with feature work and is investigated weeks later by someone reconstructing what changed across fifty commits. That is why the design says a regression fails the build rather than filing a ticket — performance defended by a ticket is performance not defended.

The gate needs an override, because sometimes a regression is the right trade — a correctness fix that costs latency, for example. An override is fine as long as it is explicit, recorded, and shows up in the benchmark history, so the new number is a decision rather than a drift.

</details>

---

### Q3. The platform runs in one region with no cross-region disaster recovery. How do you present that to the department?

**Brief answer**
As a decision with a named owner and a known cost, not as a gap. Data residency constrains where a replica may lawfully live, and a second site has not been funded. So the honest framing is three things: what the current posture guarantees, what it does not, and what it would take to change.

<details>
<summary><strong>Must cover</strong></summary>

- **residency is a legal constraint, not a preference** — a replica's location may not be permitted
- **state the current guarantee plainly** — recovery point of 5 minutes, recovery time of 1 hour, within one region
- **name the uncovered case** — a whole-region loss, against which none of that applies
- **the mitigations that do exist** — Multi-AZ, 35-day recovery window, snapshots in a separate account, a rebuildable index
- **drills are the evidence** — a recovery objective is a claim until it has been exercised
- **the decision belongs to the department** — present cost and risk, let them choose knowingly
- the deadline window as the period where downtime is most damaging

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would open with the constraint rather than the limitation, because the order changes the conversation. Every resource is provisioned in one region, and the deployment role carries a condition so a resource cannot be created elsewhere by accident. That is residency enforcement, and it exists because the applicable national law may not permit this data to leave. A cross-region replica is therefore not simply a budget question.

Then the current position, stated in the department's terms. Within the region, the database is multi-zone with automatic failover, and there is point-in-time recovery to any second in a 35-day window. Snapshots are copied to a separate account, so a compromise of the production account cannot destroy them. Object storage is cross-zone with versioning, and the audit prefix is write-once. The search index is not backed up at all because it is a projection rebuilt from the event log, and that replay is exercised quarterly. The stated objectives are five minutes of data loss and one hour to restore.

Then the uncovered case, without softening: if the entire region is lost, none of the above applies, and the platform is unavailable until it returns. For a system where vendors submit against legal deadlines, that means a closing time may pass during an outage, so the department should decide in advance how a deadline is extended when it happens. That is a procurement policy question, and it costs nothing to answer before it is needed.

Finally, the evidence and the choice. Quarterly restore drills — a recovery into an isolated account, a ledger chain verification, a projection replay — are what make the objectives claims rather than hopes. And the options are laid out with their costs: a second region where residency permits it, or a documented deadline-extension policy, which is far cheaper and covers the business consequence rather than the technical one. The department decides; my job is to make sure they are deciding rather than assuming.

</details>

---

## Performance, Caching and Observability

---

### Q1. What is cache-aside, and why is write-through used nowhere in this design?

**Brief answer**
Cache-aside means the application reads the cache, falls through to the database on a miss, and stores the result. Write-through would make every write also a cache write, which turns a cache failure into a write failure — and here the cache is meant to be entirely expendable.

<details>
<summary><strong>Must cover</strong></summary>

- **read, miss, load, store** — the cache is never on the write path
- **a cache failure stays a latency event** — no correctness impact, by construction
- **write-through couples writes to the cache** — an outage there would fail domain writes
- **read-heavy entities make it the right shape** — tenders and vendor records are read far more than written
- **every cached value has a source of truth** — that is what makes losing it safe
- **no cached value is read on a deciding path** — eligibility, sealing and scoring go to the primary
- event-driven invalidation with expiry as the backstop

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

With cache-aside, a read checks `redis-cache`, and on a miss queries PostgreSQL, returns the answer and stores it. Writes go to the database and invalidate or simply stop addressing the cached entry. The cache is never in the path of a write.

Write-through inverts that: every write updates both stores. It keeps the cache warmer and avoids a miss after a write, but it makes the cache a participant in the write. If Redis is unavailable or slow, either writes fail or the code silently diverges from its own contract. For a platform where a write may be a bid submission during a closing window, that is an unacceptable coupling for a component whose stated property is that it is expendable.

The access pattern supports the choice anyway. Tender listings and details, vendor summary records and reference data are read far more often than they change. A publish happens once; the page is then opened by thousands of vendors. The cost of a single miss after a write is nothing compared with the value of the cache never being able to break a write.

The rule that ties it together is that every cached value has a source of truth in PostgreSQL, and nothing on the eligibility, sealing or scoring path reads a cached value at all. So losing Redis entirely is a latency event: pages get slower until it returns, and no decision is affected. Invalidation is event-driven on the matching domain event, with expiry as a backstop — ten minutes for listings, an hour for vendor records, longer for embeddings and key sets.

</details>

---

### Q1. Several indexes here are partial, such as the one on documents pending a scan. What does that buy over a full index?

**Brief answer**
A partial index only contains the rows matching its condition, so an index over pending documents stays tiny no matter how large the document table grows. The queries that use it are looking for a small backlog inside a corpus of millions.

<details>
<summary><strong>Must cover</strong></summary>

- **only matching rows are indexed** — size tracks the backlog, not the table
- **a small index stays in memory** — the lookup is cheap regardless of history
- **entries disappear as rows leave the condition** — a scanned document falls out of the index
- **cheaper writes** — an insert that does not match the condition does not touch the index
- **the query must match the condition** — the planner will not use it otherwise
- the outbox relay poll and the qualification expiry sweep as the same pattern

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The `document` table grows forever: roughly 15,400 bids a year plus requirement packs, each with many documents. The question the worker asks is small — which documents are still waiting to be scanned or extracted — and the answer is normally a handful.

A full index on the scan state would contain a row for every document ever uploaded, nearly all of them in a state nobody queries. It would be large, its useful part would be a sliver, and it would grow in proportion to history rather than to the work outstanding.

A partial index restricted to the pending state contains only the backlog. It stays small enough to remain in memory permanently, so the sweep is fast on day one and on day two thousand. When a document is scanned, its row stops satisfying the condition and leaves the index entirely — the index shrinks as work completes, which is exactly the behaviour a queue-shaped query wants. Writes get cheaper too: uploading a document that goes straight to a non-pending state costs nothing in this index.

The same pattern appears twice more. The outbox relay polls unpublished rows, so its scan cost is proportional to the backlog rather than to event history. The qualification expiry sweep indexes only verified qualifications, because unverified ones never expire.

The condition that makes partial indexes bite is that the query has to match the index predicate closely enough for the planner to prove it applies. A query written with a variable that could include other states will not use the index, and that failure is silent — it simply gets slower as the table grows. That is a good reason to assert the plan rather than assume it, as the design already does for the debarment lookup on the sealing path.

</details>

---

### Q1. Every log line carries `request_id` and `trace_id`. Why both, and what else is on the line?

**Brief answer**
The request identifier ties together everything done for one incoming call; the trace identifier ties together work that spans services and asynchronous hops. Alongside them each line carries the actor, the tender where known, and the service and version.

<details>
<summary><strong>Must cover</strong></summary>

- **the request identifier scopes one call** — every line that call produced
- **the trace identifier spans services and queues** — the same work after it leaves the request
- **actor fields answer "who"** — needed for an access question, not only a performance one
- **the tender identifier is the domain anchor** — most questions here are about one procurement
- **service and version** — which build produced this behaviour
- **structured output, not free text** — fields are queried, not grepped
- redaction rules removing content fields, the link from a trace back to its lines

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

They answer different questions. A request identifier answers "what happened during this call": every line emitted while handling one [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") request, including validation failures and database timings. A trace identifier answers "what happened to this piece of work", and that work usually outlives the request. An upload triggers a function, a queue message, a scan, an extraction, a chunking task and an index write. That runs across several services and two transports. Without a shared trace identifier propagated in message attributes and headers, those are six unrelated sets of lines.

The other fields exist because of the kinds of question this platform gets asked. Actor kind and actor identifier are there because many investigations are access questions rather than performance ones — who saw this, and when. The tender identifier is the domain anchor: almost every real question is about one procurement, and being able to filter every service's lines to one tender is what turns a search into a timeline. Service and version identify the build, so behaviour that changed at a release is visible as such.

All of it is structured output rather than formatted sentences, which is what makes these fields filterable in Kibana rather than something to grep for.

Equally important is what is not on the line. No log line may carry bid content, extracted document text, a prompt body or a completion. The shipping pipeline drops fields matching the redaction rules, and a test asserts that a marker string planted in a bid never appears in the shipped logs. The identifiers are enough to investigate; the content would turn the log cluster into a second, less protected copy of the sealed material.

</details>

---

### Q2. Explain the stampede protection on the tender detail key. What does the 50 millisecond wait actually do?

**Brief answer**
On a miss, the first reader takes a short lock and loads from the database while other readers wait up to 50 milliseconds for that fill. It converts a thousand simultaneous identical queries into one query and a brief pause, and the cap guarantees nobody waits on a lock holder that has died.

<details>
<summary><strong>Must cover</strong></summary>

- **the stampede is simultaneous identical misses** — a popular tender publishing, or an expiry
- **one loader, many waiters** — a short lock decides who queries the database
- **the wait is bounded** — after 50 milliseconds a waiter falls through to PostgreSQL itself
- **the cap protects against a dead holder** — availability never depends on the lock being released
- **falling through is a slow success, not an error** — worst case is the unprotected behaviour
- **version-keyed entries reduce how often it happens** — a publish does not expire the old key
- the lock's own expiry, the deadline window as the moment this matters

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The problem is narrow and sharp. A high-profile tender publishes, a notification goes to thousands of vendors, and they all open the same page within a minute. The first request misses the cache and queries PostgreSQL. Without protection, so do the next several hundred, because none of them has finished writing the result yet. One cache miss becomes hundreds of identical queries against the same node that is serving the submission path.

The mechanism is a short-lived lock on the key. The first reader to take it becomes the loader; it queries the database and writes the value. Other readers see the lock and wait briefly for the value to appear.

The 50 millisecond cap is the safety property, and it is the part worth explaining. A waiter that waits indefinitely has made its availability depend on the loader finishing — and the loader may have been evicted mid-query, in which case the lock sits there until its own expiry. Capping the wait means the worst case is that waiters fall through and query the database themselves, which is exactly the behaviour without stampede protection. So the mechanism can only improve on the unprotected case, never make it worse. The lock also carries its own expiry so a dead holder cannot block the next fill.

This is also why the keys carry the entity's version. A publish does not need old entries deleted — they simply stop being addressed — so the common case of a change does not produce a synchronised miss at all. The stampede protection is there for the genuinely simultaneous first read, which is the case the version trick cannot remove.

</details>

---

### Q2. Cache keys include the entity's version, such as `tender:{id}:v{current_version_id}`. What problem does that solve?

**Brief answer**
It removes the need to find and delete stale entries. A new version is a new key, so the old entry is simply never addressed again and expires on its own. Invalidation becomes a consequence of how the key is built rather than an operation that can be forgotten.

<details>
<summary><strong>Must cover</strong></summary>

- **the new version is a new key** — the old value cannot be served by accident
- **no delete step to get wrong** — the classic invalidation bug disappears
- **a distributed delete is unreliable** — a failed invalidation leaves stale data with no error
- **stale entries expire by themselves** — memory is reclaimed by the backstop expiry
- **it matches an immutable-version domain** — a published version is frozen by design
- **explicit invalidation still exists where the shape does not fit** — entities without a version
- the edge cache invalidated on publish, expiry as the backstop everywhere

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Ordinary invalidation is an action: write the row, then delete the cached entry. Every step in that sequence can fail independently. The delete may be issued against the wrong key after a refactor. It may be skipped on one of three code paths that update the entity. It may simply fail while Redis is briefly unavailable. A failed delete produces no error anywhere, just a stale page served until its expiry.

Version-keyed entries remove the step. The key contains the current version identifier, so when a tender is published as version 3, readers compute a key ending `v3` and cannot reach the `v2` entry at all. Nothing has to be deleted for the new value to be correct. The old entry expires on its own and the memory returns.

It fits this domain particularly well, because a published tender version is frozen by design: criteria and weights cannot change, and a correction is a new version with its own notice. The cache key is therefore modelling something real rather than adding a trick.

It is not universal. Entities with no natural version — a vendor record edited in place — still need explicit invalidation on the matching domain event, with expiry as the backstop. And the edge cache is invalidated explicitly when a tender is published or cancelled, because a content delivery network is not addressed by application keys.

The property I would emphasise is failure behaviour. With version keys, a Redis problem during a publish means slower reads. With delete-based invalidation, the same problem means confidently serving last week's criteria to a vendor about to bid.

</details>

---

### Q2. A vendor says their bid has disappeared. Walk me through the investigation.

**Brief answer**
Establish what actually exists before explaining anything: the bid row and its state, a ledger entry, the documents and their scan states. Then use the tender identifier across logs and the trace for the submission attempt to find where it stopped. The answer is usually that sealing never completed, and the timeline says why.

<details>
<summary><strong>Must cover</strong></summary>

- **check the record first** — a ledger row means it was accepted, and that ends one branch
- **the bid state distinguishes the cases** — draft, submitted, withdrawn or disqualified
- **filter every service's logs by tender and vendor** — the shared fields make this a timeline
- **traces cover the asynchronous half** — upload, scan, extraction and chunking as one picture
- **common causes** — a document never cleared scanning, an abandoned draft, a failure during a database failover
- **audit entries answer the access half** — who did what, and what was denied
- **say what you can prove** — the receipt and hashes are the evidence, not recollection
- sampling at 100% on sealing, the grace window as an explanation for a near-deadline case

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would resist forming a theory before looking. The first questions are factual. Is there a `bid` row for this vendor on this tender, and what state is it in? Is there a `submission_ledger` entry? If the ledger has an entry, the bid was accepted and the receipt exists with its sealed timestamp and chain hash. The conversation then changes completely. The content is sealed and invisible until unsealing, which may be the whole misunderstanding.

If there is no ledger entry, sealing never completed. The records then say why. Documents carry their scan and extraction states, so a pack containing one file stuck pending — or quarantined as infected — explains a submit that could not proceed. The bid state distinguishes an abandoned draft from a withdrawal.

Then the timeline. Every line carries the tender identifier, the actor fields and the request identifier, so filtering Kibana to that tender and that vendor produces the sequence across all services rather than one service's view. Sealing is sampled at 100%, so a submission attempt has a full trace, covering the eligibility check, the object checks, the lock and the commit. That is where a failure during a database failover shows up as a `503` at a specific second.

The audit trail covers the access half of the question: who acted on this bid, what was denied, and whether anything was read.

What I would tell the vendor is only what can be proved. If there is a receipt, the ledger hash and the manifest hashes let them verify their own copy. If there is no receipt, the platform has no record of a completed submission, and the logs give the time and the reason. If the attempt failed inside a failover window near the deadline, the grace window and the recorded start timestamp are relevant, and that becomes a decision for the procurement officer rather than an engineering answer.

</details>

---

### Q3. Tracing samples 100% of sealing, unsealing, award and model jobs, but 5% of reads. Defend the split, and say what you would change first.

**Brief answer**
Sampling is a cost decision, and the cost should fall where the evidence is cheapest to lose. A read that was slow is one of millions and a sample describes the population perfectly; a sealing attempt is a legal event that happens once and cannot be reconstructed from a sample.

<details>
<summary><strong>Must cover</strong></summary>

- **reads are statistical, sealing is individual** — one matters as a population, the other as an event
- **a missing sealing trace is unrecoverable** — there is no second attempt to sample
- **read volume dominates cost** — 5% of the largest category is where the saving is
- **model jobs are expensive and rare** — full tracing is cheap relative to the work traced
- **sampling is decided at the head and carried** — a partial trace is worse than none
- **what I would change** — tail-based sampling so slow and failed reads are always kept
- the 30-day log lifecycle, error traces as the ones you always want

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Traces cost money to produce, ship and store, so the question is where to spend rather than whether to. The split follows the nature of the evidence.

Reads are a population. Tender browsing happens constantly, and what anyone needs to know is the distribution — is p95 within 250 milliseconds, which hop moved. A 5% sample answers that with high confidence, and the ninety-five traces you discarded were saying the same thing as the five you kept.

Sealing is not a population. A given vendor's submission on a given tender happens once, and if it goes wrong it becomes a question of legal fact: what the platform did, at which second, and why it rejected or accepted. A sampled trace either exists or does not, and "we did not record that one" is not an acceptable answer in a procurement dispute. The same reasoning covers unsealing and award, which are the other events an auditor asks about. Model jobs are traced fully for a different reason: they are few, they run for minutes, and they cost real money per run, so the trace is cheap relative to the work it describes.

The mechanical detail worth naming is that the decision is made at the head of the trace and propagated with the context through message attributes and headers. Deciding per hop would produce traces with sampled middles and unsampled ends, which is actively misleading.

What I would change first is the read policy, not the rate. Head-based sampling at 5% keeps a random slice, which means a rare slow read is probably discarded — and the slow ones are the only ones anybody looks at. Tail-based sampling keeps a trace after seeing how it ended, so every error and every request over a latency threshold is retained while ordinary fast reads are dropped. That gives better evidence for less volume, at the cost of buffering in the collector.

</details>

---

### Q3. No log line may carry bid content, and a test plants a marker string in a bid to check. Why is the test the important half?

**Brief answer**
Because the redaction rules are a claim and the test is the evidence. Log redaction fails silently by nature: a new field, a changed logger, an exception that includes a payload, and content starts flowing into a cluster with weaker access controls than the one it came from.

<details>
<summary><strong>Must cover</strong></summary>

- **the failure is silent** — nothing signals that a line now contains too much
- **the log cluster is a second copy with different access** — more readers, different retention
- **new fields and exception payloads are the usual leak** — nobody adds one intending to log content
- **the test asserts absence end to end** — planted marker, shipped log, searched afterwards
- **it must be run the way the pipeline runs it** — testing the redaction rules in isolation proves less
- **an absence test needs a known-fail control** — confirm it detects the marker when redaction is off
- separate cluster and lifecycle, the same discipline as the ledger verification

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Redaction is a filter applied to fields, and filters go stale. Somebody adds a field to a structured log line for debugging, an exception handler includes the request body, or a library upgrade changes how an error is rendered. None of those is a mistake anyone would recognise as "leaking sealed bid content", and none of them produces an error. The lines look normal and go to the log cluster.

That cluster is the problem. `es-logs` is separate from the document corpus, has a 30-day hot and 90-day warm lifecycle, and is read by more people than bid content is — engineers investigating incidents, not evaluators with an assignment row. Content leaking there bypasses the entire custody model: no key grant, no bucket policy, no audit entry per read.

So the platform asserts absence rather than asserting configuration. A test plants a recognisable marker string inside a bid, exercises the paths that handle it, and then searches the shipped logs for that marker. Finding it fails the build.

Two things make that test worth trusting. It has to run the way the real pipeline runs, through the actual shipping and filtering path, because checking the redaction rules in isolation only proves the rules parse. And an assertion of absence needs a control: disable the redaction deliberately and confirm the test then fails. Without that, a test that searches the wrong index or a log that never arrived both report a clean pass, and the difference between "no content leaked" and "nothing was checked" is invisible.

That is the same discipline as the known-fail sealing case and the nightly ledger recomputation. In each of them the claim is only worth as much as the demonstration that it can fail.

</details>

---

### Q3. `redis-cache` is lost entirely in the middle of a tender window. Walk me through the impact, path by path.

**Brief answer**
Nothing that decides anything is affected, because no cached value is read on the eligibility, sealing or scoring paths. Reads get slower, token verification and rate limiting degrade, idempotency keys and cached model work are gone — a latency and cost event, not a correctness one.

<details>
<summary><strong>Must cover</strong></summary>

- **the deciding paths are untouched** — eligibility, sealing and scoring read the primary
- **reads fall through to PostgreSQL** — a cold-cache load spike on the write node's replica
- **key set caching gone** — signature verification fetches keys again until refilled
- **rate-limit counters reset** — per-principal limits start from zero, briefly permissive
- **idempotency keys lost** — the unique constraints remain as the real guard
- **the model map cache is the expensive loss** — repeated work and repeated tokens
- **stampede protection matters most here** — many simultaneous misses on the same keys
- broker unaffected because it is a separate instance, ordinary recovery is refill

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would answer in order of consequence, starting with what is not affected, because that is the design's main claim. Eligibility, sealing and scoring read PostgreSQL directly, never a cached value. So a vendor can still submit, the ledger still appends, evaluators still score, and no decision changes. The Celery broker is a separate Redis instance, so queued work is untouched.

The visible effect is latency. Tender listings and details, vendor summary records and reference data all fall through to the database. The measured difference for a tender browse is roughly 57 milliseconds warm against 93 cold. That is fine for one reader. But every reader misses at once, so this is where the stampede protection on the detail key earns its place. The 50 millisecond fall-through cap is what keeps a cold cache from becoming a queue.

Then the supporting functions. Cached signing keys are gone, so token verification fetches them again from the pools until the cache refills; that is a brief extra dependency on an external endpoint. Rate-limit counters reset, so the per-principal limits are briefly more permissive than intended — worth knowing during a surge, though the gateway's own throttling and the web firewall still apply. Idempotency keys disappear, which means a retry during the outage can reach the service as a new request. The unique constraints on `bid` and the ledger are the guard that survives, which is exactly why they exist.

The costliest loss is the model map cache with its 30-day retention. Content-addressed summaries have to be recomputed, and that is billed in tokens. It is backed by object storage, so this is degradation rather than total loss.

Recovery is simply refill under load, and I would watch database connection saturation while it happens rather than assuming the fall-through is free.

</details>
