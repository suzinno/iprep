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

## Data Modeling and Transactional Integrity

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

## Performance, Caching and Observability

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
