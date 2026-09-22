# Technical — Interview Answers

> Questions supplied by the client.

## Questions by project

- **police-tender-platform** — Q1–Q10, Q13–Q16, Q18, Q19, Q21–Q41
- **general** — Q11, Q12, Q17, Q20

---

### Q1. What were your responsibilities on the project?

**Project:** police-tender-platform

**Brief answer**
Backend and platform engineering on a government tendering system with a vendor relationship module. I owned the Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")) surface for tenders, vendors and bids, and the sealed-bid custody path. I also owned the asynchronous processing, the model pipeline, and the infrastructure and delivery pipeline underneath them.

<details>
<summary><strong>Must cover</strong></summary>

- **the domain** — tenders for a police department, from requirement pack to award
- **the API surface** — tender lifecycle, vendor registration, evaluation
- **the custody path** — sealing, the submission ledger, unsealing
- **asynchronous processing** — Celery workers, queues and an object-storage trigger
- **the document and model pipeline** — extraction, summarization, citation validation
- **platform work** — Terraform, Kubernetes, the delivery pipeline, observability
- performance work on caching and indexing, incident investigation

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The platform runs tenders for a police department in the Middle East and North Africa region, from drafting a requirement pack through sealed vendor submission, committee evaluation and award. It also carries a Customer Relationship Management (CRM) module for vendor organizations, which is department-owned data about a vendor rather than data the vendor edits.

My responsibilities split into five areas.

The API surface. Tender lifecycle and versioning, vendor registration and qualification, the document upload flow, the bid endpoints and the evaluation endpoints. They are built with [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") and [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") contracts that also generate the schema document.

Bid custody. This was the part I owned most closely: the sealing commit, the per-bid envelope encryption, the append-only submission ledger with its hash chain, and the unsealing check. It is the guarantee the whole product rests on, so it lives in its own service with its own key grant.

Asynchronous processing. Four [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") worker deployments for parsing, scoring, model jobs and bulk imports. A Lambda triggered by object creation validates uploads, and the queues between them carry visibility timeouts and dead-letter queues.

The document and model pipeline. LangChain for loading, splitting, embedding and retrieval. LangGraph for the multi-step runs with validation and retry branches. And the validation layer that rejects any generated claim which does not resolve back to a real page of a real document.

Platform. [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") for every cloud resource, the [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") deployments, the GitHub Actions pipeline as the only path to production, and the metrics, logs and traces used to investigate incidents.

</details>

---

### Q2. Which features, modules or improvements did you design or implement?

**Project:** police-tender-platform

**Brief answer**
The sealed submission path end to end, the document intake and extraction chain, the model pipeline with its citation validation, the hybrid search facade, and the delivery and infrastructure automation.

<details>
<summary><strong>Must cover</strong></summary>

- **the submission path** — presigned upload, manifest, sealing commit, ledger append
- **document intake** — object trigger, scanning, extraction, chunking
- **the model pipeline** — map-reduce with validation and checkpointing
- **hybrid search** — keyword and vector retrieval behind one facade
- **the deadline-surge work** — pre-scaling and edge-cached polling
- **infrastructure and pipeline automation**
- the caching layers, the index set derived from access patterns

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The submission path was the largest single piece. A vendor requests a presigned multipart upload, sends the bytes straight to object storage, then commits a manifest. The commit checks eligibility against the primary database and confirms every manifest object exists. Then it takes a per-tender advisory lock, generates a per-bid data key, appends a row to the hash-chained ledger and returns a receipt. The chain head is mirrored to storage under an object lock in compliance mode. So verifying an award means recomputing the chain and comparing it against a record nobody can rewrite.

Document intake is the chain behind that. Object creation triggers a Lambda that checks the checksum, size, declared type and magic bytes, then hands off through a queue. A worker runs a virus scan, extracts page-anchored text and chunks it. Each step publishes a domain event, so search indexing and the model pipeline both follow from the same source.

The model pipeline is a LangGraph graph: load, chunk, embed, index, map per chunk group, validate, reduce, validate again, persist. Validation is a Pydantic schema plus a citation check. State is checkpointed after every node, so a rate-limited job resumes instead of restarting from the first token.

Search is a facade over one cluster, combining keyword scoring with vector retrieval. Tenancy and sensitivity are applied as filter clauses rather than after scoring, so a sealed chunk never enters the ranking.

The deadline-surge improvements were mine. Pre-scaling the upload service from known closing times. Caching the document status endpoint at the edge for five seconds. And moving the lock so it is held for the ledger append alone.

On the platform side: the Terraform for every resource and the eight-stage delivery pipeline. Also the three caching layers with their invalidation rules, and the index set derived from the actual access patterns.

</details>

---

### Q3. What functional and non-functional requirements did you define for this project?

**Project:** police-tender-platform

**Brief answer**
Six functional areas: tender lifecycle, sealed submission, evaluation and award, document intelligence, vendor relationship management, and search and analytics. They sit against availability, latency, durability and surge targets that every later decision was measured against.

<details>
<summary><strong>Must cover</strong></summary>

- **six functional areas**, with sealed submission as the hard one
- **an immutable version frozen at publication**
- **availability split** — 99.9% on submission, 99.5% on internal features
- **latency targets** — browse, search and sealing, each measured at the edge
- **durability** — no acknowledged submission may be lost or altered
- **the surge target** — absorb ten times the load on one path
- recovery point and recovery time objectives, explicit non-goals

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The functional requirements were grouped into six must-have areas. Tender lifecycle, from draft through approval, publication, clarification, closing, evaluation and award. The requirement pack and the criteria are frozen at publication, and a correction is a new version with its own notice, never an edit. Sealed bid submission, where content is unreadable to everybody, including platform staff, until the tender closes and an evaluation session opens. Evaluation and award, with weighted criteria, independent scoring, a consensus step, conflict-of-interest recusal, and an award bound to human-entered scores. Document intelligence, proposing criteria and deadlines from the uploaded pack and summarizing proposals with a citation back to the source page. Vendor relationship management, including qualification expiry and the debarment list that gates eligibility. Search and analytics across tenders, bids and vendor documents.

The non-functional requirements are the ones that shaped the architecture. Availability is split deliberately: 99.9 percent monthly for the submission path while a tender window is open, 99.5 percent for internal analytics and model assistance, where degraded operation is acceptable. Latency targets are set where the user feels them, at the edge. Browse under 250 milliseconds at the 95th percentile, hybrid search under 700, and the sealing commit under 1.2 seconds. Durability is stated as an absolute — no acknowledged submission may be lost or altered. Scalability is stated as a shape rather than a number: absorb a tenfold spike on the submission path with no change in error rate. Recovery point is five minutes and recovery time one hour, in a single region.

Non-goals were written down with the same care: no reverse auction, no cross-department federation, no purchase orders or invoicing, and the model never decides anything.

</details>

---

### Q4. What edge cases did you handle in the app?

**Project:** police-tender-platform

**Brief answer**
The ones clustered around the deadline and around document integrity. A commit that crosses the closing second, an object swapped after sealing, a document that fails extraction, and a duplicate submission.

<details>
<summary><strong>Must cover</strong></summary>

- **the deadline boundary** — a transaction that starts before closing and commits after
- **object substitution after sealing**, caught by the hash captured at seal time
- **duplicate submission**, prevented by a uniqueness constraint rather than by code
- **a failed or unsupported extraction**, which must not block submission
- **hostile uploads** — wrong magic bytes, archives that expand far beyond their size
- **recusal and self-assignment** on the evaluation path
- criteria weights that do not sum, a bilingual document split mid-table

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The deadline boundary is the sharpest one. A submission that begins at 23:59:59.8 and commits at 00:00:00.1 is not a late bid, and rejecting it for a reason the vendor cannot see or control is unfair. The ledger records both the start and the commit timestamp, and a commit is accepted if its transaction started before the closing time. Anything that genuinely started late is still rejected, by a check against the tender row read in the same transaction.

Object substitution is the second. The hash of every manifest entry is copied into the manifest row at seal time. If the stored object later differs, the mismatch is detectable, and it disqualifies the bid rather than being quietly repaired.

Duplicate submission is handled by a unique constraint on tender and vendor organization, not by an application check that races with itself. Every mutating endpoint also takes an idempotency key, held for 24 hours, so a retried request does not create a second draft.

Documents bring their own cases. Extraction can be unsupported or can fail, and neither may block a vendor from committing a pack that is already uploaded. The document carries its own extraction state, and sealing depends on the object existing, not on the text being readable. Uploads are validated on magic bytes against the declared type, and an archive whose declared expansion ratio is beyond a threshold is rejected. An infected file is moved to a quarantine prefix and never deleted, because it is evidence.

On the evaluation side, four rules. An evaluator cannot be assigned to a tender they created. A recusal is irreversible for that session. An award is refused unless every non-recused evaluator has a locked scorecard, and the weights of scored criteria must sum to one at publication.

One more we found by measurement rather than reasoning. A bilingual table split across two chunks degrades both the summary and its citations, which is a splitter problem, not a model problem.

</details>

---

### Q5. How many active users did the system support, approximately?

**Project:** police-tender-platform

**Brief answer**
About 1,400 daily active users in the sizing model — roughly 300 internal staff and 1,100 vendor users, drawn from around 14,000 registered vendor users across 6,000 organizations. These are modelled figures, not measured production numbers.

<details>
<summary><strong>Must cover</strong></summary>

- **a sizing model**, derived from the department rather than measured
- **the internal population** — officers, evaluators, chair, legal and finance, administrators
- **the vendor population** — around 14,000 users across 6,000 organizations
- **daily active users** — about 1,400, concentrated in a six-hour working window
- **why the concentration matters** more than the total
- what would change the model

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I want to be precise about what kind of number this is. The brief carried no measured traffic, so the figures come from a sizing model built from the department's size and its tender cadence. Every capacity decision in the design is held against that model, and the design says so rather than presenting the numbers as reported results.

The internal side is small and known. Around 120 procurement officers and 500 evaluators, often seconded from technical units rather than working on the platform daily. Then 60 committee chairs and awarding authorities, 180 people in legal, finance and audit, and 40 platform administrators. Around 900 internal accounts in total, of which roughly 300 are active on a given day.

The external side is larger and much less even: about 14,000 vendor users across roughly 6,000 vendor organizations, of which around 1,100 are active on a given day.

That gives about 1,400 daily active users. The total is not the interesting part. What matters is that the activity is concentrated in a six-hour regional working window, and that vendor activity clusters hard against tender closing times. A platform sized for the average here would fail on the only day that matters to a vendor.

The figures that would move the model are the tender cadence and the number of bidders per tender. The registered user count does not, because bids per closing window drive the peak.

</details>

---

### Q6. What was the peak load or traffic the system handled?

**Project:** police-tender-platform

**Brief answer**
About 25 requests per second at baseline, around 70 at an ordinary daily peak, and roughly 260 for ten to twenty minutes during a deadline surge. The surge is writes and upload coordination, not reads.

<details>
<summary><strong>Must cover</strong></summary>

- **baseline and ordinary peak** — about 25 and 70 requests per second
- **the deadline surge** — around 260 for ten to twenty minutes
- **what the surge is made of** — presigned upload issue, progress polling, the sealing commit
- **bytes never reach the platform**, so the surge is cheap in bandwidth
- **the volume model** — around 1,400 tenders and 15,400 bids a year
- why 70 requests per second needs no sharding

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Again these are modelled figures the design is sized against, not measured production output.

Baseline is about 25 requests per second, and an ordinary peak inside the working window is around 70. That is unremarkable, and the design says so plainly. At that level nothing needs sharding, and a single database instance with one read replica is the correct size rather than a compromise.

The number that shapes the architecture is the deadline surge. When several hundred vendors finish against the same closing minute, the platform sees roughly 260 requests per second for ten to twenty minutes. That is about ten times baseline, and it is almost entirely three things: issuing presigned upload parts, polling upload progress, and the sealing commit itself. It is not a read surge, which means caching does not help with it.

The crucial property is that the bytes are not in that traffic. Uploads are presigned multipart writes directly to object storage, so a 55 megabyte bid pack costs the platform one small presign call. Without that, a tenfold spike would also be a tenfold bandwidth spike through the API and the pods behind it.

For volume: about 1,400 tenders published a year with roughly 11 bids each, so around 15,400 bids a year. That is roughly 900 gigabytes of raw objects a year, about 5.4 terabytes over five years, against only 130 gigabytes of transactional and audit rows in the database.

</details>

---

### Q7. How do you design for peak traffic events, and when did peaks appear on your project?

**Project:** police-tender-platform

**Brief answer**
Peaks here are scheduled, not random — they arrive at tender closing times. So we pre-scale from the known closing time, keep the bytes off the platform, and make sure the surge path holds only one short lock.

<details>
<summary><strong>Must cover</strong></summary>

- **the peak is predictable** — closing times are known days ahead
- **pre-scale rather than react**, because reactive scaling arrives after the errors
- **keep bytes off the platform** — presigned direct uploads
- **push polling to the edge** — a short cache on the status endpoint
- **make the serialized resource small** — a per-tender lock held for the ledger append only
- **fairness at the boundary** — accept a commit whose transaction started before closing
- measured worst case against the budget, load testing the shape not the average

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first design question about a peak is whether you know when it is coming. Here we do. A tender's closing time is set at publication and is known days in advance, and the surge is several hundred vendors finishing against it.

That single fact changes the approach. Reactive autoscaling adds capacity after the queue has already grown and some requests have already failed. So the upload service raises its replica floor on a schedule derived from the closing times, and reactive scaling is only the backstop. This is the difference between planning and recovering.

The second lever is keeping expensive work off the platform entirely. Uploads go straight from the client to object storage, through presigned multipart Uniform Resource Locators (URLs). The surge costs the API one presign call per upload and nothing else. Any design where a large file passes through the application is a design where a traffic peak is also a bandwidth and memory peak.

The third is the polling that always accompanies uploads. Clients poll a status endpoint, typically every two seconds. That endpoint is cached at the edge for five seconds, so the origin sees at most one request per five seconds per document regardless of how often the client asks.

The fourth is the serialized resource. Sealing takes a per-tender advisory lock, so ten tenders closing at the same moment contend on ten different locks. The lock is taken after the parallel object checks and released after the ledger append, so it is held for tens of milliseconds. In the worst modelled case — sixty documents and real contention — the whole commit measures around 800 milliseconds against a 1.2 second target.

The fifth is fairness at the boundary: accept a commit whose transaction started before closing, and record both timestamps.

When testing, I load test the shape rather than the average — hundreds of clients converging on one closing second, not a smooth ramp.

</details>

---

### Q8. How was sensitive data handled and secured, and did the system comply with regulations such as GDPR or PCI-DSS?

**Project:** police-tender-platform

**Brief answer**
Encryption everywhere, with bid content under a separate key whose decryption grant only exists after unsealing. Payment card rules are out of scope because no card data is processed, and the applicable privacy law is a legal determination we deliberately did not guess.

<details>
<summary><strong>Must cover</strong></summary>

- **two classes of sensitive data** — bid content and personal data, protected differently
- **encryption in transit and at rest**, including mutual authentication between services
- **a per-bid key from a key service used for nothing else**, with the grant created only at unsealing
- **field-level encryption** for bank details and contact identifiers
- **erasure without destroying the award trail** — tombstone the individual, keep the organization
- **data residency**, enforced in the deployment role rather than by convention
- **no card data**, so the payment card standard stays out of scope
- the honest position on which privacy statute applies

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There are two different kinds of sensitive data here and they need different answers.

Bid content is confidential in a time-bound way: unreadable to everybody until the deadline passes, then readable only by assigned evaluators. It is written to object storage under a per-bid data key from a key service used for nothing else. The bucket policy denies read access on the bid prefix to every principal except the bid service, with no console path and no administrator exception. The grant that lets that service decrypt is created only when unsealing succeeds. That requires the tender to be past its closing time and in evaluation, the caller to be the committee chair, and a session to exist. After unsealing, a link is short-lived and an audit row is written before the link is returned.

Personal data is the second kind: vendor contacts, staff identities, and details held in the relationship module. Everything is encrypted in transit with modern Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")), including mutual authentication between services inside the cluster. At rest it is 256-bit encryption on the database, its snapshots, the object store, the search cluster and the message broker. Bank details and contact identifiers are additionally encrypted in the application before insert, so a database snapshot leak does not disclose them. That costs the ability to index those columns, which is acceptable because nothing searches on a bank account.

Erasure and retention pull against each other here, and the schema is what resolves it. The award trail references the vendor organization, never the individual. So a person's record can be tombstoned and their activity notes redacted, while every tender, bid, score and award stays intact.

On regulation, I will be direct. The Payment Card Industry Data Security Standard ([PCI-DSS](https://www.pcisecuritystandards.org/ "Security requirements for organizations that handle payment card data")) is out of scope, because the platform processes no card data at all. It hands an award to the department's finance system. For privacy, the General Data Protection Regulation ([GDPR](https://gdpr-info.eu/ "EU regulation governing the processing of personal data")) is not automatically the governing law here. "Middle East and North Africa" is not a jurisdiction, and the applicable statute, its residency rule and its breach deadline differ by country. The design provides the mechanisms these regimes share. Those are lawful-basis recording, subject access export, erasure that preserves the award trail, and breach detection through alerting. Residency is enforced by a condition on the deployment role, so a resource cannot be created in another region by accident. Which statute applies was raised as a question for the department's legal office rather than assumed.

</details>

---

### Q9. How did you design role-based access in a multi-actor system, and what were the authentication and authorization mechanisms?

**Project:** police-tender-platform

**Brief answer**
Two separate identity pools for staff and vendors, and standard signed tokens validated at the edge and again in each service. Then four authorization checks in a fixed order: account type, tenant, role, then assignment and recusal.

<details>
<summary><strong>Must cover</strong></summary>

- **two identity pools, never one** — federated staff, self-registered vendors
- **token validation twice** — the gateway is a filter, not the authority
- **short-lived access tokens** and the claims they carry
- **four checks in order** — account type, tenant scope, role, assignment and recusal
- **tenant scope enforced in the repository layer**, not in each handler
- **attribute-based rules** on the evaluation path, where a role is not enough
- **segregation of duties as a constraint**, not a policy
- service identity through per-deployment cloud roles, break-glass accounts

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Authentication first. There are two Cognito user pools and that is deliberate. Staff sign in through the department's own identity provider, by Security Assertion Markup Language (SAML) federation. Joiners and leavers are then handled where they are already handled, and no staff password exists on the platform. Vendors self-register in a separate pool, with multi-factor authentication mandatory on any account that can submit a bid. One pool for both populations would mean a group misconfiguration or a token audience mistake could cross the boundary that matters most.

Tokens are standard signed access tokens, validated at the gateway against the pool's key set and validated again inside each service. The gateway is a filter, not the authority — a service that trusts the gateway alone is one routing mistake away from an open endpoint. Access tokens live fifteen minutes; refresh tokens are longer and revocable centrally. The claims carried are the subject, the account type, the organization identifier, the roles and the scopes.

Authorization is four checks, in order, and the first failure ends the request.

Account type comes first, before routing: a vendor token can never reach an internal endpoint. Tenant scope is second. A vendor principal's organization claim must match the row's organization. This is a mandatory predicate in the repository layer, not a line each handler is trusted to write. A query without it does not get past the base class. Role is third — procurement officer, evaluator, committee chair, legal, finance and platform administrator internally; administrator, submitter and viewer on the vendor side.

The fourth check is where roles stop being enough. Being an evaluator does not entitle you to read a bid. You may read it only if an assignment row links you to that tender's session, the session is past unsealing, and no recusal exists for your assignment. That is attribute-based, and it is checked per object rather than at the collection endpoint, so enumeration does not leak anything either.

Two things sit underneath. Segregation of duties is enforced as a constraint. You cannot be assigned as an evaluator on a tender you created. An award cannot be signed unless the signer is the chair and every non-recused evaluator has a locked scorecard. And service-to-service identity is cloud identity, not a shared secret — each deployment has its own role naming only the prefixes, queues, key grants and secrets it needs.

</details>

---

### Q10. How do you structure CI/CD pipelines for microservices? What was your approach?

**Project:** police-tender-platform

**Brief answer**
One pipeline shape shared by every service, with blocking stages ordered cheapest first and no long-lived deployment credentials. Deployment rules also respect the domain — we never deploy the bid service near a closing time.

<details>
<summary><strong>Must cover</strong></summary>

- **one shape for every service**, so the pipeline is learnable
- **stages ordered cheapest first**, each blocking the next
- **integration tests against real dependencies** in containers
- **a test case that must fail** on the sealing path
- **migrations as a pre-deploy job**, expand and contract only
- **no static deploy credentials** — short-lived federated identity per environment
- **canary only where it pays**, and a domain-aware deploy freeze
- rollback as a redeploy of the previous image tag

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

With twelve deployments, the worst outcome is twelve different pipelines. Every service here runs the same stages in the same order, so a developer moving between services does not relearn delivery.

The order is cheapest first, each stage blocking the next. Linting and strict type checking. Unit tests. Integration tests against real [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), OpenSearch and a local cloud emulator in Docker Compose, with a recorded model stub so no test reaches the real model endpoint. Contract tests on the sealing path, including a case that must fail: a bid committed after the closing time has to be rejected. Then a migration check that applies and reverses the migration against a restored copy of the staging schema. Then performance benchmarks for sealing and search latency, compared against the recorded budget, where a regression beyond twenty percent fails the build rather than filing a ticket. Then the container build, a vulnerability scan, and a push to the registry tagged by commit hash. Then staging, a smoke suite and a manual approval before production.

Two structural rules matter more than the stage list.

First, no human holds credentials that can deploy. The workflow assumes a cloud role through the provider's federated identity, with the trust policy restricted by repository, branch and environment. So a workflow on a fork or a feature branch cannot reach production. There is no long-lived deployment key to steal.

Second, schema changes are a pre-deploy job and are expand-and-contract only, so the previous image always runs against the new schema. That is what makes rollback a redeploy of the previous tag instead of a schema reversal under pressure.

Two services deploy as a canary at ten percent of traffic for thirty minutes: the search service and the model service. Their behaviour depends on a third party, and on query shapes staging traffic does not reproduce. The rest roll normally, because a canary you do not watch is just a slower deploy.

The rule I like most is the domain-aware one: the bid service is never deployed while a tender window is within an hour of closing. The pipeline checks the closing times and refuses. Delivery has to know something about the business, or it will do the technically correct thing at exactly the wrong moment.

</details>

---

### Q11. How do you reduce Docker image size?

**Project:** general

**Brief answer**
Build in one stage and ship from another, so the compiler toolchain never reaches the final image. Then pick a smaller base, install only runtime dependencies, and keep the build context small.

<details>
<summary><strong>Must cover</strong></summary>

- **multi-stage build** — compile in one stage, copy artifacts into a clean one
- **a slim runtime base**, chosen for the libraries the application actually needs
- **runtime dependencies only** — no compiler, no headers, no package cache
- **a real `.dockerignore`**, so the context stays small
- **clean up in the same layer that created the files**
- measuring with a layer inspector before optimizing, pinning versions

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The single biggest win is nearly always a multi-stage build. The first stage has the compiler, the headers and the package manager, and produces wheels or a virtual environment. The final stage starts from a clean runtime base and copies only that result. For a Python service this typically removes hundreds of megabytes, because building some native dependencies pulls in a full toolchain that the running service never uses.

The base image is the second decision. A slim variant is usually right; a distroless or Alpine base is smaller again but comes with real costs. Alpine uses a different C library, so wheels that ship prebuilt for the usual platform get rebuilt from source, which makes builds slower and occasionally changes behaviour. I choose the smallest base that does not force a source build, and I measure rather than assume.

Then the details. Install runtime dependencies only, and remove the package manager cache in the same layer that created it. A separate cleanup layer does not shrink anything, because the earlier layer still holds the files. Keep a real `.dockerignore`. Without one, the build context carries the git history, test fixtures and local virtual environments into the daemon. That slows every build, and those files can end up in the image by a careless copy.

Two more habits. Do not install debugging tools "just in case"; attach an ephemeral container when you need them. And pin base image versions by digest, because reproducibility and size regressions are the same problem seen from two sides.

Finally, measure. A layer inspection tool shows which layer holds the weight, and the answer is often a single copy instruction rather than the base image everyone blames first.

</details>

---

### Q12. How do Docker cache layers work? Explain with an example of how to write a good Dockerfile.

**Project:** general

**Brief answer**
Each instruction creates a layer keyed by the instruction and its inputs. The cache is valid until the first change, and everything after that is rebuilt — so order instructions from least to most frequently changed.

<details>
<summary><strong>Must cover</strong></summary>

- **one instruction, one layer**, keyed by the instruction and its inputs
- **a miss invalidates everything after it**, not just that layer
- **a copy is keyed by file contents**, so touching one file busts the rest
- **order least-changing to most-changing** — dependencies before source
- **copy the dependency manifest first**, install, then copy the source
- build cache mounts for the package cache, and why the build context matters

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Each instruction in a Dockerfile produces a layer, and the builder keys that layer on the instruction text plus its inputs. For a copy instruction, the inputs are the contents of the files being copied, not their timestamps. When a key matches a previous build, the layer is reused. When one does not, that layer and every layer after it are rebuilt, even if those later instructions did not change. That cascade is the whole game.

So the ordering rule is: least frequently changed first. Dependencies change weekly, application source changes hourly. A Dockerfile that copies the whole project and then installs dependencies rebuilds the dependency install on every single source edit. The fix is two copies:

```dockerfile
FROM python:3.12-slim AS build
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY src/ ./src/

FROM python:3.12-slim
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
COPY --from=build /app/src /app/src
ENV PATH="/app/.venv/bin:$PATH"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0"]
```

The dependency manifest is copied alone, the install runs, and only then does the source arrive. Editing a source file now invalidates the last copy and nothing before it, so a rebuild is seconds rather than minutes.

Two extra points. A build cache mount keeps the package manager's own download cache between builds without putting it in the image, which helps most when the lock file does change. And the build context matters. Everything not excluded by `.dockerignore` is sent to the builder and participates in cache keys. So a stray log file can invalidate a layer for no reason at all.

</details>

---

### Q13. What external systems or third-party APIs were integrated with your platform?

**Project:** police-tender-platform

**Brief answer**
The department's own identity provider, the OpenAI endpoint for embeddings and summarization, a mail and message relay for notifications, and a handover to the department's finance system. No payment provider — the platform holds no money and no card data.

<details>
<summary><strong>Must cover</strong></summary>

- **the department identity provider**, federated for staff sign-in
- **the model endpoint**, the only integration with internet egress
- **the notification relay**, fanning out deadline notices
- **the finance system handover** — an award and a contract reference, not invoicing
- **no payment integration**, which is a scope decision with a compliance consequence
- managed cloud services treated as dependencies too
- each integration's failure treated as expected, not exceptional

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Four integrations, and it is worth naming what each one costs.

The department's identity provider is federated by assertion to the staff user pool. This is the integration with the least code and the most organizational value. Joiners and leavers are handled in the department's existing process, and no staff password exists on the platform. Its failure mode is total for staff sign-in, so two break-glass administrator accounts exist. They are protected by hardware tokens, disabled by default, and enabled only by a two-person action. Every use pages the security lead and writes an audit row. Vendor submission is unaffected, because vendors are in a separate pool.

The model endpoint is used for embeddings, per-chunk summarization and report composition. It is the only integration with a route to the internet, and that route is one egress-controlled subnet allowing exactly that hostname. It is also the most expensive dependency: bid summarization dominates the cost model at roughly 180,000 input tokens per bid pack.

The notification relay handles deadline notices and clarification broadcasts, which fan out to thousands of vendor contacts. It sits behind its own queue and a dispatch function, so a slow relay never competes with the submission path.

The finance system is a handover rather than a live integration. The platform passes an award and a contract reference, and purchase orders, invoicing and payment stay on the other side. That boundary is the reason the platform holds no card data, which keeps the payment card standard out of scope entirely. It is a scope decision worth stating explicitly, so a future feature does not quietly bring it back in.

I also treat the managed cloud services as third parties with real failure modes, especially the key service, because sealing depends on it.

</details>

---

### Q14. How do you handle failures while interacting with third-party APIs?

**Project:** police-tender-platform

**Brief answer**
Decide first whether the feature may degrade or must fail closed, then design the failure to match. Everything advisory retries and degrades; anything that decides an outcome refuses rather than guesses.

<details>
<summary><strong>Must cover</strong></summary>

- **classify the dependency first** — advisory or decisive
- **timeouts and a bounded retry budget**, never an unbounded loop
- **circuit breaking**, so a dead dependency is not called once per request
- **a degraded mode with a visible flag**, not a silent fallback
- **a kill switch** for the whole feature
- **fail closed where correctness matters**, with a clear retry signal to the caller
- idempotency on retry, and logging what left rather than what it contained

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first question is not technical. It is whether the feature may degrade. Getting that wrong in either direction is the real failure.

The model endpoint is advisory, so it degrades. Every call is a background job with a handle, never a synchronous call inside a request. A response time measured in minutes cannot sit behind a 250 millisecond target. A provider outage would otherwise take the tender pages down with it. Jobs retry with backoff, and the pipeline is checkpointed after every step, so a rate-limited job resumes instead of restarting. Search has a visible degraded path. If the embedding call fails, the service falls back to keyword-only results and returns a `degraded: true` flag. It does not exceed its latency target, and it does not return nothing. And the whole feature sits behind a switch — with it off, evaluators read the source documents and score exactly as they would have without the platform's help.

The key service is the opposite case. If it is unavailable, sealing fails closed. The submission returns a 503 with a retry header instead of recording a bid we cannot prove was sealed. That is an acknowledged single point of failure on the submission path, and it was accepted deliberately: an unprovable award is worse than a delayed submission. The grace window makes it recoverable, because a vendor retrying after a brief outage is still judged on when their transaction began.

The mechanics underneath are the same everywhere. Aggressive timeouts, because a hanging call holds a worker. A bounded retry budget with backoff and jitter, never an unbounded loop that turns a provider's slow minute into a self-inflicted overload. A circuit breaker so a dead dependency is not dialled once per request. Idempotency, so a retry cannot double-apply. And logging that records the artifact identifier, the model, the prompt version, the token counts and a hash of the payload. Never the payload itself, so the log does not become the leak.

</details>

---

### Q15. How do you design retry policies for transient versus permanent failures?

**Project:** police-tender-platform

**Brief answer**
Classify before retrying. Transient failures get bounded retries with exponential backoff and jitter; permanent failures go straight to a dead-letter queue with the reason recorded. Anything retried has to be idempotent.

<details>
<summary><strong>Must cover</strong></summary>

- **classification comes first** — a permanent failure retried only delays the truth
- **transient** — timeouts, connection resets, 429 and 5xx, throttling
- **permanent** — validation errors, 4xx, a malformed or unsupported document
- **exponential backoff with jitter**, so retries do not synchronise
- **a bounded budget**, then dead-letter rather than retry forever
- **idempotency as the precondition** for any retry
- **honour the retry hint** where the provider gives one, and make the dead-letter queue visible

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Retrying a permanent failure is not merely useless. It delays the moment somebody learns the truth, and it adds load to a system that is often already struggling.

So the policy starts with classification. Transient means the same request could succeed later: a timeout, a connection reset, a 429 rate-limit response, most 5xx responses, a database failover in progress, a throttled cloud call. Permanent means it cannot: a validation error, a 4xx other than 429, an unsupported file type, a document that fails extraction because it is a scan with no text layer. On this platform the model client classifies explicitly, rather than catching one broad exception. The difference between "rate limited" and "your prompt is invalid" is the difference between waiting and stopping.

Transient failures get exponential backoff with jitter. The jitter matters more than people expect. Without it, every worker that failed at the same moment retries at the same moment, and the retry storm is worse than the original incident. Where a provider returns a retry hint, that hint wins over my own schedule.

The budget is bounded. The model pipeline retries a map step at most twice, with a lowered temperature, and then quarantines the artifact rather than looping. Queue-driven work gets a small number of receives before the message moves to a dead-letter queue. Any message landing there raises a ticket, because an invisible dead-letter queue is just a slow way to lose data.

Two preconditions make all of this safe. Everything retried must be idempotent. Model jobs are keyed on a hash of their input. Event consumers are keyed on the aggregate identifier and version, so a duplicate delivery is a no-op. And the visibility timeout has to exceed the real processing time, or a slow job is redelivered while still running and does the work twice.

</details>

---

### Q16. How do you ensure backward compatibility in evolving APIs?

**Project:** police-tender-platform

**Brief answer**
Additive changes only inside a version. New optional fields, never a removed or retyped one, with the same expand-and-contract discipline applied to the database and to event schemas.

<details>
<summary><strong>Must cover</strong></summary>

- **additive within a version** — add optional fields, never remove or retype
- **a version prefix in the path**, and what actually justifies a new version
- **generated schema documents** from the request models, so the contract is not hand-written
- **tolerant readers** — consumers ignore unknown fields
- **expand and contract for the database**, so rollback meets a usable schema
- **event schemas versioned too**, with consumers keyed on aggregate and version
- a deprecation path with measurement, contract tests in the pipeline

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Inside a version the rule is simple and strict: you may add, you may not remove or change meaning. A new field is optional with a sensible default. A field is never retyped, never made required after the fact, and never repurposed. Repurposing is the worst of all, because every client keeps working and quietly means something different.

The path carries a version prefix, but I treat a new version as a last resort rather than a release ritual. It is justified when the resource model itself changes, not when a field is added.

The contract is generated, not written. Request and response models produce the schema document directly, so it cannot drift from the code, and a change that alters the schema is visible in the diff. Contract tests run in the pipeline against that schema.

Consumers are tolerant readers: unknown fields are ignored rather than rejected, so a producer can add a field before every consumer is updated. That single convention removes most coordinated deployments.

The same thinking applies below the API. Migrations are expand-and-contract only and run as a job before the rollout. The previous image always runs against the new schema, and a rollback never meets a column that has been removed. Add the column, write both, migrate readers, and only then remove the old one — in a later release, once nothing reads it.

Events need the same care and get it less often. Domain events carry a type and the aggregate's version, consumers are keyed on the aggregate identifier and version so duplicates are harmless, and event payloads only gain fields. A replayable log makes this stricter, not looser. An old event has to remain readable by today's consumer, because replaying from the log is how the search projection and the audit sink are rebuilt.

When something must eventually go, it gets a deprecation window with measurement — you cannot retire a field you are not counting.

</details>

---

### Q17. What defines a good SLA dashboard?

**Project:** general

**Brief answer**
It answers one question fast: are we keeping the promise, and how much room is left? That means a handful of user-facing indicators measured where the user is, with the error budget shown as a number.

<details>
<summary><strong>Must cover</strong></summary>

- **one job** — are we keeping the promise, and how much room is left
- **user-facing indicators only**, not resource graphs
- **measured where the user feels it**, at the edge rather than inside the pod
- **the error budget as a number**, with burn rate
- **percentiles, not averages**, and a stated window
- **scoped to what the agreement actually covers**
- a link from each indicator to the drill-down, and the domain metrics that matter here

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A Service Level Agreement (SLA) dashboard has one job, and most dashboards fail it by showing everything. The person opening it during an incident, or a manager opening it monthly, needs one answer: are we keeping the promise, and how much room is left this month?

So it shows indicators that correspond to user experience, not to machine health. Processor usage belongs on an engineering dashboard. What belongs here is availability of the path the agreement covers, and the latency of the operations users actually perform. On the tender platform that would be submission-path availability while a tender window is open, internal availability, browse latency, search latency and sealing latency.

Three properties separate a useful one from a decorative one.

Measurement point. The number has to be taken where the user feels it, at the edge, not inside the pod. A service can report a healthy latency while the gateway in front of it is queueing, and the pod-level graph will look fine throughout the outage.

Error budget. A percentage on its own does not tell you whether to act. The budget does. 99.9 percent monthly is 43 minutes. A dashboard saying twelve minutes are left this month causes a different decision than one saying the availability figure is 99.94 percent. The burn rate matters as much as the balance.

Percentiles and a stated window. Averages hide exactly the tail the agreement is about, and a figure with no window is not a figure. The 95th and 99th percentiles over a named period, with the target drawn on the chart, so meeting or missing is visible without arithmetic.

Beyond that: stay scoped to what the agreement covers, and link each indicator to the place you would investigate it. On a domain system I would also put the domain indicators beside the generic ones. Here that is sealing rejections by reason, because that is what an unhappy vendor is actually experiencing.

</details>

---

### Q18. What types of metrics are essential in this domain?

**Project:** police-tender-platform

**Brief answer**
The domain ones, not the infrastructure ones. Sealing attempts and rejections by reason, the document scan backlog, ledger verification results, quarantined model artifacts, projection lag and token spend.

<details>
<summary><strong>Must cover</strong></summary>

- **sealing attempts and rejections by reason**, which is the product working or failing
- **the document scan backlog**, because an unscanned file blocks a submission
- **ledger chain verification**, treated as a control rather than a statistic
- **quarantined model artifacts**, as a prompt or model regression signal
- **search projection lag**, against its stated budget
- **model token spend**, the largest variable cost
- the generic indicators underneath — availability, latency percentiles, queue depth, dead-letter depth

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The generic set is necessary and not sufficient: availability, latency percentiles, error rates, queue depth, dead-letter depth, database connections, replication lag. Every platform needs those. What makes a system supportable is the domain metrics beside them, because the infrastructure can look healthy while the product is failing.

Sealing attempts and rejections, broken down by reason, is the first one I would add. A rise in rejections is the sharpest possible signal, and the reason distinguishes a platform fault from correct behaviour. The reasons are: ineligible vendor, missing manifest object, past the closing time, key service unavailable. The same total number means completely different things depending on that split.

The document scan backlog is second — documents waiting to be scanned, and the age of the oldest. A vendor cannot rely on a pack that has not been scanned and extracted. So a backlog during an open window is urgent in a way it never is at night.

Ledger chain verification is third. The chain is recomputed nightly and on demand, and the recomputed head is compared against a copy held under an object lock. This is not a statistic, it is a control: a mismatch is a security incident, not a lag. An audit trail nobody verifies is a log, not a control.

Then the model-side ones. The share of artifacts quarantined for unresolvable citations, over 24 hours, is the earliest sign of a prompt or model regression. The artifacts are being refused correctly, which is the system working. But a rising rate means something changed upstream. Token spend per day against the trailing average is the cost signal, and cost is a real reliability concern when summarization dominates the bill.

Finally search projection lag against its 30-second budget, because search is allowed to be behind and needs a defined amount of behind.

</details>

---

### Q19. How do you avoid alert fatigue?

**Project:** police-tender-platform

**Brief answer**
Only page for something a human must act on now. Everything else becomes a ticket. Alert on symptoms the user feels rather than on causes, and delete any alert nobody acted on.

<details>
<summary><strong>Must cover</strong></summary>

- **two channels, one rule** — page only for act-now, ticket for everything else
- **alert on symptoms**, not on every cause
- **context-aware conditions**, so the same state is urgent only when it matters
- **error budget burn** instead of single-request thresholds
- **review and delete** alerts that nobody acted on
- grouping and inhibition, so one incident is one page

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Alert fatigue is not caused by the number of alerts. It is caused by alerts that do not require action, because after a few of those people stop reading all of them, including the one that mattered.

So there are exactly two channels and one rule. A page means a human must act now. Everything else is a ticket. On this platform the pages are these. Any server-side sealing failure while a tender window is open. A ledger chain mismatch, which is handled as a security incident. A database failover. A document scan backlog older than fifteen minutes while a window is open. And error budget burn of two percent of the monthly budget in an hour. The tickets are dead-letter queue depth, projection lag beyond its budget for ten minutes, and a failed qualification expiry sweep. Also unusual model spend, and a model quarantine rate above ten percent over a day. Every one of those tickets matters. None of them needs somebody awake.

Three techniques do most of the work.

Alert on the symptom. One page for "sealing is failing" is better than separate pages for the database, the key service and the queue. Those all fire together during the same incident, and none of them is the thing you care about.

Make conditions context-aware. The same scan backlog is an emergency while a tender window is open and a ticket at two in the morning with nothing closing. An alert that cannot tell the difference will be muted by whoever is on call, permanently.

Use budget burn instead of raw thresholds. A single slow request is noise; consuming two percent of a month's error budget in an hour is a trend worth waking for.

Then the maintenance: group related alerts into one notification, suppress downstream ones when an upstream cause is already firing, and review the alert list regularly. An alert that fired and produced no action is either a ticket or a deletion, and deleting it is a real improvement rather than an admission of anything.

</details>

---

### Q20. How do you distinguish a "distributed monolith" from true microservices in practice? (Also asked as: what are the first warning signs that a microservices system is drifting back into a distributed monolith, and what system characteristics would signal that it has?)

**Project:** general

**Brief answer**
Ask whether one service can be deployed, rolled back and stay available on its own. If a release requires ordering across services, or one service's outage stops the others, the boundaries are decorative.

<details>
<summary><strong>Must cover</strong></summary>

- **the test: independent deploy, rollback and failure**
- **warning sign: coordinated releases** and a required deployment order
- **warning sign: a shared database** written by several services
- **warning sign: synchronous call chains** several services deep
- **warning sign: a change that touches several services** for one feature
- **warning sign: shared models in a common library** that force a lockstep upgrade
- **what true separation looks like** — own data, events, tolerant readers
- the honest note that a modular monolith is often the better answer

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There is one practical test and everything else is a symptom of it. Can a single service be deployed on its own, rolled back on its own, and survive its neighbours being down? If yes, the boundaries are real. If no, you have a monolith with network calls between its modules, which is strictly worse than a monolith: the same coupling, plus serialization, plus partial failure.

The earliest warning sign is a release plan. As soon as someone writes "deploy the tender service, then the evaluation service, then the gateway", independence is gone. Real separation means old and new versions coexist, which is why additive-only contracts and tolerant readers matter so much.

The second sign is the database. Two services writing the same tables share a schema, which means they share a migration, which means they share a deployment. They are one service with two repositories. Reading another service's tables is nearly as bad, because you have then made that service's internal schema a public contract nobody documented.

The third is synchronous call chains. If serving one request means service A calls B calls C, availability multiplies downwards and latency adds upwards. Three services at 99.9 percent in a chain are 99.7 percent together, and a slow C makes A time out for reasons its owners cannot see. On the tender platform there is exactly one synchronous service-to-service call: the eligibility check during sealing. It is deliberate, because the answer must be current — a cached one would let a debarred vendor bid. Everything else consumes events and keeps its own copy.

The fourth is the shape of a feature. If adding one field means editing four services in one pull request, the boundary does not follow the domain — it cuts across it.

The fifth is a shared library holding domain models. It looks like reuse and behaves like coupling, because a change to it forces every service to upgrade together. Shared infrastructure code is fine; shared domain types are the monolith coming back through the package manager.

The honest closing point: if a system shows these signs, the answer is not always to fix the seams. Sometimes it is to merge the services back into a well-structured single deployment, which is a perfectly respectable design and much cheaper to operate.

</details>

---

### Q21. How do you choose between orchestration and choreography for saga implementations?

**Project:** police-tender-platform

**Brief answer**
Orchestration when a business person would recognise the process and someone has to answer "where is it now"; choreography when services react to a fact and nobody owns the sequence. The best answer is often to need neither.

<details>
<summary><strong>Must cover</strong></summary>

- **the first question** — can this be one local transaction instead of a saga
- **orchestration** — a named coordinator holding the state, visible and debuggable
- **choreography** — services react to events, no coordinator, looser coupling
- **the deciding test** — does anyone need to answer "where is this process now"
- **compensations are the hard part**, and they are business decisions
- **the worked split on this platform** — an orchestrated model pipeline, choreographed projections
- the hidden cost of choreography, which is that the process exists only in the logs

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first question I ask is whether a saga is needed at all. A saga is the price of splitting a decision across services, and on this platform we mostly refused to pay it. Everything that decides an outcome lives in one database: tender state, bid custody, the ledger, scores and the award. So the sealing commit is an ordinary local transaction with real atomicity. That is not avoidance; it is the strongest available answer, and a distributed protocol is what you reach for when it is genuinely unavailable.

Where a multi-step process does exist, the choice comes down to whether anyone needs to answer "where is this now".

Orchestration puts a named coordinator in charge. It holds the state, calls each step, and decides what to do on failure. The model pipeline works this way: a graph that loads, chunks, embeds, indexes, maps, validates, reduces, validates again and persists, with state checkpointed after every node. When a job fails two thirds of the way through, an operator can see which node it stopped on and it resumes rather than restarting from the first token. That visibility is the whole reason for the pattern. The cost is a component that knows about all the others.

Choreography has no coordinator. A service publishes a fact and whoever cares reacts. The projections work this way: a document is extracted, the event is published, and search indexing, the model pipeline and notifications each react without the publisher knowing they exist. Adding a consumer requires no change to the producer, which is exactly right for fan-out.

The failure mode to be honest about is that a choreographed process exists nowhere as a whole. It is implicit in a chain of handlers, and understanding it means reading logs across several services. That is acceptable for projections and a poor choice for anything a person will be asked to explain.

And compensations are the hard part of either style. Undoing a step is a business decision, not a technical one. That is another reason to keep anything irreversible, like sealing a bid, inside one transaction where a rollback is free.

</details>

---

### Q22. How do you prevent cascading failures in service-to-service calls?

**Project:** police-tender-platform

**Brief answer**
Remove most of the calls, then contain the ones that remain. Aggressive timeouts, bounded concurrency, circuit breaking, and a degraded answer instead of an error where the feature allows one.

<details>
<summary><strong>Must cover</strong></summary>

- **fewest calls first** — events and local copies instead of synchronous chains
- **timeouts shorter than the caller's own budget**
- **bounded concurrency and connection pools**, so one slow dependency cannot take every worker
- **circuit breaking**, with a half-open probe
- **bulkheads** — separate deployments, separate broker, separate search cluster
- **degrade visibly** where the feature permits, fail closed where it does not
- load shedding at the edge, and why retries need a budget

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The cheapest protection against a cascade is not having the call. This platform has exactly one synchronous service-to-service call on a critical path: the bid service asking the vendor service whether a vendor may bid. Everywhere else, a service that needs another's data consumes its events and keeps its own copy. A call that does not exist cannot time out, cannot retry and cannot propagate a failure.

For the call that remains, containment is layered.

Timeouts come first, and they must be shorter than the caller's own budget. The sealing commit has a 1.2 second target, and the eligibility check is budgeted at tens of milliseconds, so its timeout is set accordingly. An inherited default of thirty seconds is how one slow dependency consumes every worker in the caller.

Bounded concurrency is second and is often missed. Workers, connection pool sizes and client concurrency limits all cap how much of the caller a slow dependency can occupy. Without a cap, the queue in front of the caller grows until it is failing for its own reasons, long after the original dependency recovered.

Circuit breaking is third. After a threshold of failures, calls fail immediately instead of waiting for the timeout, with a half-open probe to test recovery. This protects the dependency too, by removing the retry pressure at exactly the moment it is trying to come back.

Bulkheads are structural. The workers run as separate deployments. The task broker is a separate instance from the cache, so a backlog cannot evict cached data. Log analytics runs on a different cluster from tender search, so a log flood during an incident cannot degrade search during the same incident.

Then the behaviour at the boundary. Where the feature allows it, degrade visibly: search drops to keyword-only and says so. Where correctness is at stake, fail closed and say so: sealing without the key service returns a 503 with a retry header rather than recording something unprovable.

Finally, every retry has a budget with jitter, and the edge sheds load with per-principal rate limits set above legitimate last-hour behaviour, so protection does not become the outage.

</details>

---

### Q23. How do you handle partial failures for transactions distributed across services?

**Project:** police-tender-platform

**Brief answer**
Make the local transaction the atomic unit, publish the fact through an outbox in that same transaction, and make every consumer idempotent. Then reconcile, because at-least-once delivery means duplicates and gaps are normal.

<details>
<summary><strong>Must cover</strong></summary>

- **one local transaction as the atomic unit**, with everything else following from it
- **the transactional outbox**, so a crash yields a duplicate, never a loss
- **at-least-once delivery**, so consumers must be idempotent
- **idempotency keyed on aggregate and version**
- **the cross-store cases** — a row with no object, an object with no row
- **reconciliation on a schedule**, not only on alerts
- dead-letter queues for what cannot be processed, compensation as a business decision

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Partial failure is the normal case, not an exception, so the design starts by shrinking what has to be atomic.

Everything that decides an outcome is written in one local transaction in one database. The sealing commit touches four tables — the bid, the manifest, the ledger and the outbox — and either all of it happens or none of it does. There is no two-phase commit anywhere, and that is a feature.

The outbox is what connects that transaction to the rest of the system. The domain event is written as a row in the same transaction as the domain change, and a relay publishes it afterwards and marks it published. A crash between those two steps produces a duplicate delivery, never a lost event. That asymmetry is the whole point: a duplicate is something you can defend against, a silent loss is not.

Defending against duplicates is the consumer's job. Every event carries the aggregate identifier and an aggregate version, and consumers are keyed on that pair, so processing the same event twice is a no-op. Model jobs are keyed on a hash of their input for the same reason.

Then the cross-store cases, which are where partial failure actually bites. A document row is only marked clean and extracted after the object is confirmed present with a matching hash. If an object exists with no row, it is an orphan and gets swept after seven days. If a row exists with no object, that is a hard failure and raises an alert, because it means a reference to something that is not there.

Reconciliation runs on a schedule rather than waiting for someone to notice. A nightly job compares row counts and update watermarks per tender between the database and the search index and re-emits the gap. The audit chain is recomputed and compared against the immutable copy, and a mismatch is treated as a security incident.

What cannot be processed goes to a dead-letter queue and raises a ticket. And where a business step genuinely has to be undone, the compensation is a domain decision. One example is disqualifying a bid whose object hash no longer matches, rather than quietly repairing it.

</details>

---

### Q24. How do you preserve "effective ACID" across microservices?

**Project:** police-tender-platform

**Brief answer**
By not distributing the part that needs it. Everything that decides an outcome lives in one database with real transactions; everything else is a projection that may lag and may be rebuilt.

<details>
<summary><strong>Must cover</strong></summary>

- **the honest answer** — you do not get these guarantees across services, so place the boundary instead
- **one store for everything that decides**, transactions and foreign keys included
- **constraint enforcement in the database**, not in application code
- **the outbox** as the bridge between a transaction and an event log
- **idempotent consumers** as the substitute for distributed isolation
- **verification after the fact** — a hash chain and an immutable copy
- what is deliberately not transactional, and why that is safe

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I would start by disagreeing gently with the framing. You do not get Atomicity, Consistency, Isolation and Durability ([ACID](https://en.wikipedia.org/wiki/ACID "Atomicity, Consistency, Isolation, Durability — Names the four guarantees a database transaction provides")) across services. Two-phase commit across independently deployed systems trades availability for a guarantee that is still weaker than people imagine. So the real skill is deciding where the boundary goes, and putting everything that needs the guarantee inside it.

On this platform the boundary is explicit. Tender state, bid custody, the submission ledger, scores and the award all live in one PostgreSQL instance and are read on the write path with no replica fallback. During a partition that half refuses writes rather than accepting a divergent one, because a silently accepted bid is worse than a rejected one. Search, analytics, notifications and every generated artifact are projections with a 30-second lag budget, and none of them is ever an input to eligibility, scoring or an award. That single rule — no eventually consistent store answers "may this vendor bid" or "what did the evaluator score" — is what makes the rest safe.

Inside the boundary, the guarantees are ordinary and strong. The sealing commit is one transaction. Uniqueness is a constraint, so one bid per vendor per tender cannot be violated by two concurrent requests. The ledger sequence is allocated under a per-tender advisory lock, which is what makes the chain totally ordered. Criteria weights are checked by a deferred constraint at publication. Segregation of duties is a rule in the database, not a policy document.

Across the boundary, three things substitute for what transactions would have given. The outbox makes the database write and the event publication effectively atomic, at the cost of possible duplicates. Consumers keyed on aggregate and version make those duplicates harmless, which is the practical replacement for isolation. And verification after the fact replaces trust. The ledger chain is recomputed and compared against a copy held under an object lock, so tampering or divergence is detectable rather than assumed absent.

The honest summary is that we get atomicity and durability where it matters, eventual consistency where it does not, and a way to prove the difference.

</details>

---

### Q25. How do you achieve strong consistency in distributed systems?

**Project:** police-tender-platform

**Brief answer**
Put the decision behind a single writer, read it from the primary on the paths that decide, and serialize the one operation that must be ordered. Strong consistency is bought with availability, so buy it only where needed.

<details>
<summary><strong>Must cover</strong></summary>

- **a single writer** for anything that decides
- **primary reads on decisive paths**, never a replica or a cache
- **serialize the one ordered operation** — a per-tender advisory lock
- **uniqueness and check constraints** as the enforcement
- **refuse rather than diverge** during a partition
- **the cost** — extra load on the primary, availability given up
- scope it narrowly, and verify with an append-only chain

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Strong consistency is not a property you enable. It is a set of choices you pay for, so the first step is deciding exactly which operations need it.

Here, four do: recording a submission, deciding eligibility, recording a score, and signing an award. Everything else can lag.

For those four, the mechanism is deliberately unglamorous. There is one writer — a single primary database — and nothing decisive is served from the read replica or from a cache. The eligibility check during sealing reads the primary explicitly, and the cost is accepted: extra load on the write node, and no ability to serve that query from the replica. The reason is that an eventually consistent answer to "may this vendor bid" is not a stale page, it is a debarred vendor bidding, which is a legal defect.

Ordering is the second mechanism. The submission ledger needs a total order per tender, so the sequence number is allocated under a per-tender advisory lock taken inside the sealing transaction. That makes the lock the only serialized resource on the surge path. It is held for the ledger append alone, and not for the object checks that come before it. Per-tender rather than global means ten tenders closing at once contend on ten different locks.

Enforcement is the third. Uniqueness on tender and vendor organization prevents a duplicate bid even under a race. A check against the tender row read in the same transaction rejects a genuinely late submission. Deferred constraints assert criteria weights at publication. Constraints hold under concurrency in a way application checks do not.

And the partition behaviour is stated rather than discovered: that half refuses writes rather than accepting a divergent one.

Two closing points. Scope it narrowly — the same system serves search and analytics with a 30-second lag, and that is correct. And verify rather than assume: the hash chain, recomputed nightly against an immutable copy, is what turns the claim into evidence.

</details>

---

### Q26. What trade-offs do you face between consistency and availability?

**Project:** police-tender-platform

**Brief answer**
You choose per operation, not per system. Here anything that decides an outcome refuses to serve during a partition; anything that only informs stays available and catches up.

<details>
<summary><strong>Must cover</strong></summary>

- **the choice is per operation**, not one answer for the whole platform
- **the consistent half** — tender state, custody, ledger, scores, award
- **the available half** — search, analytics, notifications, generated artifacts
- **the rule that keeps them apart** — no lagging store answers a deciding question
- **the cost of choosing consistency** — rejected writes during a failover, visible to the user
- **the cost of choosing availability** — stale results, which must be labelled
- degraded modes as a designed state, and a partition being rarer than a slow dependency

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Treating this as one decision for a whole platform is what produces bad answers. It is a decision per operation, and the same system can and should make it differently in different places.

The consistent half here covers tender state, bid custody, the submission ledger, scores and the award. These live in one primary, are read on the write path with no replica fallback, and refuse writes during a partition rather than accept a divergent one. The user-visible cost is real: during a database failover of roughly a minute or two, sealing returns a 503 with a retry header. A vendor at the deadline sees an error. That is only acceptable because the grace window judges them on when their transaction started, so retrying after the failover does not make them late. Without that pairing, the consistency choice would be unfair rather than merely strict.

The available half covers search, analytics, notification fan-out and every generated artifact. These are projections rebuilt from the event log with a 30-second lag budget. During a problem they serve older data rather than nothing, and search will fall back to keyword-only results with a visible flag when the embedding call fails. Stale but labelled is a good answer; stale and silent is not.

One rule keeps the two halves from contaminating each other, and I would state it as the actual design. No eventually consistent store is ever read to answer "may this vendor bid" or "what did the evaluator score". Search may show a tender that closed thirty seconds ago. It may never be the thing that decides eligibility.

One last piece of honesty. A true network partition is rare. What actually happens is a slow dependency, a failover, or a lagging consumer, and those are the cases the design has to handle gracefully. Naming the partition behaviour is useful because it forces the question, but the daily value comes from having defined degraded modes at all.

</details>

---

### Q27. How do you measure cache effectiveness?

**Project:** police-tender-platform

**Brief answer**
Hit ratio per key class, the latency difference between hit and miss, and the load actually removed from the source. A high overall hit ratio can hide a cache that helps nothing expensive.

<details>
<summary><strong>Must cover</strong></summary>

- **hit ratio per key class**, not one aggregate number
- **the latency difference** between a hit and a miss, measured end to end
- **load removed from the source**, which is the real benefit
- **cost saved**, where a miss costs money rather than milliseconds
- **eviction and expiry rates**, which tell you whether the cache is sized right
- **staleness**, measured against what the cached value is allowed to be
- the stampede case, and knowing what breaks if the cache is empty

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

An overall hit ratio is close to useless, because it averages a cheap key with an expensive one. I measure per key class.

On this platform the classes behave completely differently. Tender listings and details are read constantly and are cheap to recompute, so a high hit ratio there mostly saves database load. Query embeddings are the opposite: the hit ratio is lower, but a miss is a call across the network to a third party. The measured difference is about 220 milliseconds for a miss against about 3 milliseconds for a hit. That turns a hybrid search from roughly 488 milliseconds cold to about 271 on a repeat. That one class carries most of the value even though it is not the busiest.

So the second measure is the latency difference between a hit and a miss, measured where the user is. A tender browse is about 93 milliseconds cold and about 57 cached. Useful, but the search number is where I would spend effort.

Third is load actually removed from the source: queries per second against the database that no longer arrive, connection pool pressure, replica utilisation. That is the benefit in terms the capacity plan can use.

Fourth, and specific to systems with a model in them, is cost. The map stage of summarization is cached on a hash of the chunk text, the prompt version and the model identifier. Vendors reuse boilerplate heavily across bids — company profiles, certifications, standard terms — so that cache is the single largest lever on token spend. Its effectiveness is measured in currency, not milliseconds.

Fifth, eviction and expiry rates tell you whether the cache is sized correctly. A high eviction rate with a decent hit ratio means you are close to the edge.

Sixth, staleness against what the value is allowed to be. Listings tolerate ten minutes; the eligibility answer tolerates nothing and is therefore never cached at all.

The last check is a thought experiment I actually run: what happens with a cold cache? Here the answer is higher latency and no correctness change, which is the property cache-aside is chosen for. A cache whose absence breaks correctness is not a cache.

</details>

---

### Q28. How do you manage Celery worker concurrency while interacting with the database?

**Project:** police-tender-platform

**Brief answer**
Size concurrency from the database connection budget, not from the machine. Total workers times pool size must stay under the instance limit, with headroom for the web services that actually serve users.

<details>
<summary><strong>Must cover</strong></summary>

- **the connection budget is the constraint**, not processor count
- **the arithmetic** — replicas times concurrency times pool size, summed across deployments
- **web services get the headroom first**
- **separate worker deployments per workload**, so one backlog cannot starve another
- **short transactions** — never hold one across a model call or an object fetch
- **prefetch tuned down** for long tasks, so work is not hoarded by one worker
- scaling on queue depth rather than processor use, and idempotency because tasks are redelivered

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The mistake I see most often is sizing worker concurrency from the container's processor allocation. The binding constraint is almost always the database connection limit, and it is shared with everything else.

The arithmetic has to be done explicitly: replicas times worker concurrency times connection pool size, summed across every deployment, must sit under the instance's maximum with room to spare. On this platform there are four worker deployments — documents, scoring, model jobs and imports — plus eight services, all against one primary and a replica. The services get the headroom first, because a tender browse failing to get a connection is a user-facing outage while an import waiting two seconds is not. When the numbers do not fit, a connection proxy in front of the database is the right answer, not quietly raising the limit.

Separate deployments per workload matter for the same reason. A bulk import of tens of thousands of vendor rows must not starve document parsing while a tender window is open. Separate deployments also let each one scale on its own signal: the model workers scale on the depth of their queue, the others on broker queue length. Scaling on processor use is wrong for queue workers, because a worker blocked on a slow dependency looks idle by that measure.

Inside a task, the rule is that a transaction is short and holds no external call. Never open a transaction, call the model endpoint, and commit afterwards — that is minutes of an open transaction, an idle-in-transaction connection, and a growing risk of lock contention. Fetch, close, call, then reopen to write.

Prefetch is the setting people forget. The default lets a worker claim several messages at once. That is fine for tasks lasting milliseconds and harmful for tasks lasting minutes, because one worker hoards work others could do. For long tasks I set it to one and acknowledge late.

Finally, everything is idempotent, because at-least-once delivery means a task will eventually run twice. For the model workers the queue was also chosen for its visibility timeout. A job that runs for minutes is not redelivered while it is still working.

</details>

---

### Q29. How do you decide on synchronous versus asynchronous inter-service communication?

**Project:** police-tender-platform

**Brief answer**
Synchronous only when the caller cannot continue without a current answer. If the caller can carry on, or the answer may be a little old, it is a message — and most calls turn out to be messages.

<details>
<summary><strong>Must cover</strong></summary>

- **the test** — does the caller need a current answer to proceed right now
- **the cost of synchronous** — availability multiplies down, latency adds up
- **the cost of asynchronous** — no immediate answer, and a harder mental model
- **the one synchronous call here**, and why it earns the exception
- **commands versus facts** — point-to-point queue against a published event
- **long-running work is always a job** with a handle
- the operational price of asynchronous work, paid in dead-letter queues and lag metrics

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

My default is asynchronous, and synchronous calls have to justify themselves, because each one couples two services in availability and in latency.

The test is whether the caller can proceed without a current answer. On this platform exactly one call fails that test. During sealing, the bid service asks the vendor service whether the vendor may bid. A cached or eventually consistent answer would let a debarred vendor submit, which is a legal defect rather than a stale page. So that call is synchronous, budgeted in tens of milliseconds and read from the primary. Everywhere else, a service that needs another's data consumes its events and keeps its own copy.

The costs are worth stating plainly. A synchronous chain multiplies availability downwards and adds latency upwards, and it propagates a failure to a caller whose own dependency is healthy. An asynchronous design avoids that, but gives no immediate answer, needs idempotent consumers, and is harder for a new engineer to follow because the process is not in one place.

Beyond the yes-or-no, the shape of the message matters. A command addressed to one consumer goes on a point-to-point queue, with a visibility timeout and a dead-letter queue. That covers object intake to the document service, model jobs to the workers, and notification dispatch to the delivery function. A fact that several unknown consumers may care about is published to the event log, keyed by tender so a partition carries one tender's history in order. Commands use queues, facts use the log, and mixing them up is how a system ends up with one consumer secretly required to exist.

Long-running work is always a job with a handle, never a long request. Every model call returns a job identifier. A response time measured in minutes cannot sit behind a 250 millisecond target. A provider outage would otherwise take the tender pages down with it.

The honest cost of all this asynchrony is operational: dead-letter queues to watch, lag to measure against a stated budget, and duplicate delivery to design for. That is the price of not coupling the services, and at this scale it is worth paying.

</details>

---

### Q30. How do you design retry and dead-letter strategies?

**Project:** police-tender-platform

**Brief answer**
Retry only what can succeed later, a small bounded number of times, with the visibility timeout longer than the real processing time. Everything else lands in a dead-letter queue that somebody owns and looks at.

<details>
<summary><strong>Must cover</strong></summary>

- **the visibility timeout must exceed real processing time**, or slow work is duplicated
- **a small receive count**, then dead-letter rather than loop
- **one dead-letter queue per source queue**, keeping the failure identifiable
- **any message in a dead-letter queue raises a ticket** — depth is not a metric to watch idly
- **keep the original message and the failure reason**, so replay is possible
- **replay after a fix**, deliberately and idempotently
- poison messages versus a downstream outage, which need opposite responses

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A dead-letter queue is not an error log. It is a place work waits for a human decision, and it only works if somebody is told.

The first parameter is the visibility timeout, and it is the one most often wrong. It has to exceed the real processing time of the slowest legitimate job. Model jobs run for minutes, which is why they use a queue whose visibility timeout can be set accordingly rather than a simple broker list. Too short, and a job still running is handed to a second worker, so the work happens twice and the first result may be overwritten. That looks like a retry bug and is actually a configuration mistake.

The second is the receive count. A small number — typically three to five — then the message moves to the dead-letter queue. Retrying beyond that is rarely useful and is how a poison message consumes a worker forever.

Third, every source queue gets its own dead-letter queue. Document intake and model jobs each have one here, so the failure stays identifiable rather than pooled with unrelated failures.

Fourth, and the part that makes it real: any message arriving in a dead-letter queue raises a ticket. Not a dashboard entry someone might notice. A queue nobody is told about is just a slower way to lose data.

Fifth, the message has to be replayable. The original payload is kept along with the failure reason, so after a fix the messages can be moved back to the source queue. Because consumers are idempotent — keyed on the input hash for model jobs, on aggregate and version for event consumers — replaying is safe rather than a second incident.

The last distinction is diagnostic. A steady trickle into the dead-letter queue usually means poison messages: a malformed document, an unsupported file type, a row that fails validation. A sudden flood usually means a downstream outage, and the right response is the opposite — stop retrying, fix the dependency, then replay. Reading the dead-letter rate as one signal hides that difference.

</details>

---

### Q31. How do you secure service-to-service calls behind an API gateway, where there are no human users?

**Project:** police-tender-platform

**Brief answer**
Give each workload its own cloud identity instead of a shared secret, require mutual authentication inside the cluster, and keep every permission scoped to the exact resources that workload needs.

<details>
<summary><strong>Must cover</strong></summary>

- **workload identity, not a shared secret** — a role per deployment
- **least privilege per deployment**, named prefixes, queues, keys and secrets
- **mutual authentication inside the cluster**, with a strict policy
- **network policy as the second layer**, so identity is not the only control
- **the gateway is an edge control**, not an internal one
- **audit and rotate** — short-lived credentials, logged access
- the asynchronous alternative, where the queue's own permissions are the control

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The failure mode to design against is the shared service token: one secret every service holds, never rotated, and equivalent to full access the moment one pod is compromised.

The first control is identity per workload. Each deployment here runs under its own cloud role, bound to its Kubernetes service account, and the credentials are short-lived and issued automatically. There is no static key anywhere in a manifest or an image.

The second is least privilege expressed as resources rather than as roles. Each role names only the object-storage prefixes, queues, key grants and secrets that workload actually needs. The search service cannot read a secret. The model service cannot read the bid prefix. Only the bid service holds a grant on the custody key. This is the control that limits the damage when something does go wrong, and it is only meaningful if it is specific. A policy granting all object storage is a policy that has given up.

The third is mutual authentication inside the cluster. Service-to-service traffic runs over mutual transport encryption through the mesh, with a strict peer policy so a workload without a valid identity cannot receive traffic at all. That covers the case where an attacker is already inside the network, which is exactly the case an edge gateway does nothing about.

The fourth is network policy as a second, independent layer. Every pod has explicit egress rules, and only the model service and its workers have any route to the internet, through one controlled subnet. Two independent controls mean one misconfiguration is not sufficient.

On the gateway itself: it is an edge control. It validates tokens, throttles and routes, and it is deliberately not treated as the internal authority — services validate again. A gateway in front of services that trust it implicitly is one routing rule away from an open door.

Where the interaction can be asynchronous, the cleanest answer is that there is no call to secure. The publisher's permission to write to a queue and the consumer's permission to read it are the authorization, expressed as cloud policy and auditable centrally.

</details>

---

### Q32. What are the limitations of relying solely on a Cognito authorizer?

**Project:** police-tender-platform

**Brief answer**
It answers "is this token valid and from the right pool", and nothing more. It knows nothing about the object being requested, so every question that matters — whose row is this, are you assigned, are you recused — is still yours to answer.

<details>
<summary><strong>Must cover</strong></summary>

- **what it does** — signature, expiry, issuer, audience, sometimes scope
- **what it cannot do** — object-level decisions it has no data for
- **no tenant check** — the token says which organization, not which row
- **stale claims** — a token lives on after a role or status changes
- **the gateway is bypassable internally**, so services must validate again
- **coarse scopes**, which push real authorization into the application anyway
- availability and operational coupling, and why the four-check model exists

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A gateway authorizer is a good filter and a poor authority, and the distinction is where most of the risk sits.

What it does well. It checks the token's signature against the pool's key set, its expiry, its issuer and audience. It also rejects malformed or unsigned requests before they consume any application capacity. That is genuinely valuable, and it means a large class of junk never reaches a pod.

What it cannot do is decide anything about the object. It does not know that this bid belongs to another vendor organization, or that this evaluator was never assigned to this session. It does not know that the session has not reached unsealing, or that the evaluator declared a conflict of interest yesterday. Those are the decisions that matter on this platform, and the authorizer has no data with which to make them. Tenant scope is the clearest example: the token says which organization the caller belongs to, but only the application can compare that against the row being fetched. That is why the tenant predicate is mandatory in the repository layer rather than optional in a handler.

Staleness is the second limitation. An access token lives fifteen minutes here. A role change, a suspension or a debarment during that window is not reflected in the token. So anything security-critical is re-checked against current data rather than read from the claim. Short lifetimes reduce the window; they do not remove it.

Third, the gateway is not the only way in. Traffic that reaches a service by another route — a misrouted internal call, a port-forward, a future ingress — would arrive unchecked if the service trusted the gateway blindly. So each service validates the token again. The gateway is a filter, the service is the authority.

Fourth, scopes in a token are coarse. You can express "may submit bids". You cannot express "may read this bid". Trying to push object-level rules into scopes produces a token full of identifiers that is stale by design.

That is why the platform has four checks in order: account type, tenant, role, then assignment and recusal. The authorizer sits in front of all of them rather than replacing any.

</details>

---

### Q33. How do you handle roles and permissions from Cognito at the application level?

**Project:** police-tender-platform

**Brief answer**
Treat the token as a claim about identity, not as an authorization decision. Map groups to a role enum at the edge of the application, then decide against current data, per object.

<details>
<summary><strong>Must cover</strong></summary>

- **the token carries identity and coarse role**, not the decision
- **map groups to an internal role enum** in one place
- **the tenant predicate belongs in the data layer**, enforced by the base class
- **object-level checks**, not collection-level ones
- **re-read security-critical state** rather than trusting a fifteen-minute-old claim
- **keep the source of truth in the database** for anything fine-grained
- denials audited, and permission changes taking effect promptly

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The token gives me three useful things: who the caller is, which account type they belong to, and which organization they act for. Everything else I treat as a hint.

Group membership is mapped once, at the application boundary, into an internal role enum. That mapping lives in one place, so a renamed group is a one-line change rather than a search through handlers. An unrecognised group maps to no permissions rather than being ignored silently.

Tenant scope is not a check, it is a predicate. A vendor principal's organization claim becomes a mandatory filter in the repository layer, so a query written without it does not get past the base class. This matters more than any role logic. The common real-world breach here is not a privilege escalation — it is a listing endpoint that forgot its filter and returned every vendor's rows.

Role checks are then coarse and cheap: procurement officer, evaluator, committee chair, legal, finance, platform administrator internally; administrator, submitter, viewer on the vendor side. They gate which endpoints exist for you.

The fine-grained decisions live in the database because that is where the facts are. May this evaluator read this bid? Only if an assignment row links them to this tender's session, the session is past unsealing, and no recusal exists. None of that can come from a token, and it changes during the life of one. So anything security-critical is re-read rather than trusted from a claim that may be fifteen minutes old. A debarment or a suspension has to take effect now, not at the next refresh.

Checks are applied per object, not only at the collection endpoint, because otherwise a direct fetch by identifier becomes an enumeration tool.

Two supporting habits. Authorization denials are audited, because a pattern of denials is a signal rather than noise. And I keep the permission model small enough to hold in your head: four checks in a fixed order, the first failure ending the request. An authorization model nobody can recite is one nobody can review.

</details>

---

### Q34. What are Cognito triggers used for?

**Project:** police-tender-platform

**Brief answer**
They are hooks into the sign-up and sign-in flow. They enforce rules the pool cannot express, link an external account to an internal record, and put application context into the token.

<details>
<summary><strong>Must cover</strong></summary>

- **what a trigger is** — a function invoked at a point in the identity flow
- **pre-sign-up** — admit or reject a registration by your own rules
- **post-confirmation** — create the internal record and link it to the external identity
- **pre-token-generation** — add application claims such as the organization
- **custom message** — branded and localised emails, which matters in a bilingual deployment
- **migration and authentication challenge triggers**, for less common needs
- keeping them thin, because they sit on the sign-in path

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A trigger is a function the identity service calls at a defined moment in the sign-up or sign-in flow. It exists for the rules the pool itself cannot express, and for joining an external identity to your own data.

Pre-sign-up runs before a registration is accepted. It is where a policy such as "this domain is not allowed to self-register" or "this registration number already belongs to an existing vendor organization" lives. The platform's vendor pool is self-service, so admitting the wrong account is cheap to do and expensive to undo.

Post-confirmation runs after a user confirms their account. This is the linking step: create the internal vendor user row, store the external subject identifier against it, and put the organization into a pending qualification state. Without a step like this you end up with identities in one system and records in another, joined by an email address. That is exactly the kind of join that breaks when someone changes their email.

Pre-token-generation adds application claims to the issued token. The platform's tokens carry the account type, the organization identifier, roles and scopes, and those are application facts, not identity-provider facts. This is where they are attached, so a service does not have to fetch them on every request. The rule I apply is that only stable, coarse facts go in — anything that can change within the token's fifteen-minute life is read from the database instead.

Custom message shapes the verification and invitation emails. In a bilingual Arabic and English deployment that is not cosmetic, because the default wording is neither branded nor localised.

There are others worth knowing: a user migration trigger for moving an existing user store in gradually, and the authentication challenge triggers for custom verification steps. I would reach for those rarely, because each one puts more of your own code on the sign-in path.

That is also the design rule for all of them: keep them thin. A trigger is on the critical path of every sign-in, and its failures become sign-in failures.

</details>

---

### Q35. What are common pitfalls when using triggers?

**Project:** police-tender-platform

**Brief answer**
They run on the sign-in path with a tight time limit, so slow or failing code becomes a sign-in outage. The other traps are non-idempotent side effects, recursion, and putting volatile data into a token.

<details>
<summary><strong>Must cover</strong></summary>

- **a trigger failure is a sign-in failure** — the blast radius is everyone
- **a short timeout and cold starts**, on a latency-sensitive path
- **idempotency** — the same trigger can be invoked more than once
- **recursion**, when a trigger modifies the user it was invoked for
- **volatile claims in a token**, which are stale for the token's whole life
- **unhandled failure**, leaving an account in the pool and not in your system
- no local testing without deliberate effort

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first and biggest is blast radius. A trigger sits on the authentication path for every user of that pool. A bug that would be a minor incident in an API endpoint becomes "nobody can sign in". On this platform that would mean the vendor pool on the day a tender closes. So I treat trigger code as critical-path code: small, reviewed carefully, and with its own alert.

Second, the execution budget is short and the platform will not wait for you. A cold start plus a database call plus an external lookup can exceed it, and the user sees a failed sign-in with no useful message. That argues for minimal dependencies, and for generous provisioned capacity if the pool is busy. Keep any slow work out of the trigger entirely — publish an event and do it afterwards.

Third, idempotency. A post-confirmation trigger can be invoked more than once, and code that inserts a row without a uniqueness constraint will happily create two. The constraint belongs in the schema, not in a check the trigger performs and then races with itself.

Fourth, recursion. A trigger that updates the user it was called for can cause the same trigger to fire again. This is a classic and it presents as a mysterious loop rather than an obvious error.

Fifth, volatile claims. Anything put into a token at generation time is fixed for that token's life. A role, a status or an entitlement that changes will not be reflected until the token refreshes, and code that trusts the claim will act on stale data. Stable facts only; everything else is read at request time.

Sixth, error handling is usually untested. What happens when the database is unreachable during post-confirmation? If the answer is an unhandled exception, the user's account exists in the pool and not in your system, and nobody finds out until they try to do something. I want that path to fail loudly, to alert, and to be recoverable by a reconciliation that creates the missing record.

Finally, testing. Triggers are awkward to run locally, so they tend to be tested in a deployed environment by hand and then forgotten. Putting them behind an interface that can be exercised in the integration suite is worth the small amount of structure it costs.

</details>

---

### Q36. How do you secure S3 media uploads from users?

**Project:** police-tender-platform

**Brief answer**
Never let the client choose the destination. The server issues a presigned upload that is single-use, scoped to one key, short-lived and size-bounded, and nothing is readable until it has been validated and scanned.

<details>
<summary><strong>Must cover</strong></summary>

- **the server chooses the key**, so the client cannot write anywhere it likes
- **presigned uploads: single-use, short-lived, size-bounded**
- **validate after arrival** — magic bytes against the declared type, checksum, size
- **reject expansion bombs** by declared ratio
- **scan before anything is readable or extractable**, quarantine rather than delete
- **no public read** — bucket policy denies everything but the owning service
- **encrypt with a scoped key**, and never serve the object directly
- versioning on, and treating the stored file as untrusted forever

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Uploads from external users are the widest attack surface on a platform like this, so the design assumes every file is hostile.

The client never chooses where a file lands. It asks for an upload, giving a filename, a byte size, a content type and a checksum. The server allocates the key under a layout it controls, then returns presigned parts. Those presigned URLs are single-use, scoped to exactly that one key, and expire in fifteen minutes. They carry a content-length range condition, so an oversized file is refused by the storage service itself rather than after it has arrived.

The bytes go straight to object storage and never traverse the API. That is a security property as much as a performance one: the application never buffers an attacker-controlled multi-gigabyte file.

Validation happens on arrival. Object creation triggers a function that checks the checksum, the size and the magic bytes against the declared content type. A file called `proposal.pdf` that begins with a zip header is rejected. The function also refuses archives whose declared expansion ratio is beyond a threshold, which is the decompression bomb case. Then a worker runs a virus scan before the object is readable or extractable by anything. An infected object is moved to a quarantine prefix and never deleted, because on a procurement platform it is evidence.

Access is the other half. The bucket has no public read. The bid prefix denies read access to every principal except the owning service, with no console path and no administrator exception. Objects are encrypted with a scoped key, and bid content uses a separate key whose decryption grant only exists after unsealing. Nothing is ever served directly. A download is a short-lived link, issued by the owning service after its authorization check. On the bid path an audit row is written before the link is returned.

Two closing habits. Versioning is on for every prefix, so an accidental overwrite is recoverable. And the file stays untrusted after it is stored. The text extractor and the thumbnailer run in a worker deployment, not in the service that serves requests. Parsing untrusted documents is where the remaining risk lives.

</details>

---

### Q37. How do you structure a multi-step LLM workflow?

**Project:** police-tender-platform

**Brief answer**
As an explicit graph of small steps with validation between them, checkpointed so it can resume, and with a refusal path. A Large Language Model (LLM) step that cannot be validated should end the run, not pass its output along.

<details>
<summary><strong>Must cover</strong></summary>

- **explicit steps with validation between them**, not one long prompt
- **map then reduce**, so document size stops being the limit
- **a typed schema at every boundary**, rejected rather than parsed loosely
- **checkpoint after each step**, so a failed run resumes
- **at most two retries at a lowered temperature**, then stop
- **refusing as a first-class outcome** — quarantined, officer notified, nothing shown
- content-addressed caching per step, versioned prompts, recorded model and pipeline versions

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The structure I use is a graph, not a chain of calls, and every edge has a check on it.

The shape on this platform is: load the page-anchored text, chunk it, embed, index, run the map stage over chunk groups, validate, reduce into the final artifact, validate again, persist. Extraction and summarization share that shape, which means one set of operational tools covers both.

Map and reduce is what makes document size a non-issue. A 60-page requirement pack or a 55 megabyte bid pack is too large for one prompt, so each chunk group is summarized independently and the reduce step composes those results. It also parallelises, with the concurrency ceiling set by the account's rate limit rather than by pod count — exceeding it turns one slow job into eleven failing ones.

Validation between steps is the part that distinguishes a workflow from a demo. Every step emits a typed structure validated against a schema, and a response that does not fit is a failure rather than something to parse leniently. The reduce stage emits claims that each name their source chunk. A second validation resolves every claim back to a real chunk of a real document belonging to that subject. One unresolvable claim fails the entire artifact.

Failure handling has three states, not two. A map step that fails validation retries at most twice with a lowered temperature. If it still fails, the run is quarantined: the job is marked failed, the officer is notified, and no artifact is shown. Refusing is a first-class outcome, because on this platform a plausible-looking unsupported summary is worse than no summary.

Checkpointing is why the pipeline is a graph framework rather than a script. State is saved after each node, keyed by job and node. A rate-limit error two thirds of the way through a 60-page pack then resumes, instead of restarting from the first token. At these document sizes that is the difference between a recoverable job and a wasted hour of tokens.

Two more properties. Each step is content-addressed, so repeated boilerplate across bids is processed once. And every artifact records the model identifier, the prompt version, the pipeline version and a hash of the input, so any output can be traced to exactly what produced it.

</details>

---

### Q38. How do you structure modular LangChain workflows?

**Project:** police-tender-platform

**Brief answer**
Keep the framework at the edges. Loaders, splitters, embeddings and retrievers are swappable components behind my own interfaces; the domain rules and the validation live in my code, not in a chain.

<details>
<summary><strong>Must cover</strong></summary>

- **use it for plumbing**, not for business logic
- **own the interface** — the model client is one adapter, replaceable
- **small composable units** with typed inputs and outputs
- **prompts as versioned artifacts** in the repository, not runtime strings
- **the splitter is domain-specific**, and it is where quality is won or lost
- **testable without the network** — a recorded stub in the pipeline
- configuration as validated settings, and pinning versions because the ecosystem moves

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

My rule with any framework in this space is that it may own the plumbing and not the decisions. Loaders, text splitters, embedding clients and retrieval helpers save real work and are genuinely modular. Business rules expressed as a chain become logic you cannot read, test in isolation or reason about during an incident.

So the structure is layered. At the bottom, the framework's components do their jobs. Above them, my own interfaces: something that turns a document into page-anchored chunks, something that embeds, something that retrieves, something that calls the model. Each is a small unit with typed inputs and outputs, and each can be replaced. That last point is not theoretical here. The design states this explicitly. If the provider arrangement does not hold, the answer is a self-hosted model inside the private network. The pipeline is built so the model client is the only thing that changes. That property only exists because the framework is not woven through the domain code.

Prompts are versioned artifacts in the repository, not strings assembled at runtime, and every stored artifact records which prompt version produced it. That makes a regression investigable: you can compare two prompt versions against the same input hash. It is also a security property, because a prompt that cannot be altered at runtime cannot be steered by someone who can influence configuration.

The splitter deserves separate attention, because it is where quality is actually won or lost. Generic splitting on character counts damages procurement documents, which are full of tables and headed clauses. A bilingual table split across two chunks degrades both the summary and its citations. That is domain work and it belongs in domain code, not in a default.

Testability is the last piece. Every unit is exercisable without the network, and the integration suite runs against a recorded model stub so no test reaches the real endpoint. Without that, the tests are slow, expensive and non-deterministic, and people stop running them.

One practical note: pin the versions. This ecosystem moves quickly and interfaces change between minor releases more often than you would like.

</details>

---

### Q39. How do you maintain context persistence efficiently?

**Project:** police-tender-platform

**Brief answer**
Persist the state, not the conversation. Each step reads what it needs from the database and the document store, so nothing depends on a growing transcript being carried forward.

<details>
<summary><strong>Must cover</strong></summary>

- **persist structured state, not a transcript**
- **checkpoint per node**, keyed by job and step
- **retrieve what a step needs** instead of carrying everything
- **content-addressed caching**, so repeated input is processed once
- **summarize forward** where history genuinely matters
- **bound the context** deliberately, and measure tokens per job
- durable storage rather than in-memory, because workers are replaced

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The expensive mistake is treating context as a transcript that grows. Every step then pays for every earlier step, cost rises with the square of the work, and quality falls as the important part gets buried.

What I persist is structured state. After each node the pipeline writes a checkpoint to the database, keyed by job and node: which chunk groups are done, what each produced, which validations passed. That state is small, queryable and durable. It survives a worker being replaced mid-run, which matters because these jobs last minutes and pods are not permanent.

Each step then retrieves what it needs rather than being handed everything. The map stage needs one chunk group and the prompt. The reduce stage needs the validated map results, not the source text. The chunks themselves live in the search index and the extracted text in object storage, addressed by identifier, so nothing large is carried between steps.

Caching is the second lever, and on this platform it is the largest one. Map results are content-addressed on a hash of the chunk text, the prompt version and the model identifier, held for thirty days and backed by object storage. Vendors reuse boilerplate heavily across bids — company profiles, certifications, standard terms — so the same text is summarized once no matter how many bids contain it. That is the single biggest control on token spend, which dominates the running cost.

Where genuine history matters, the technique is to summarize forward. Keep a compact running state rather than the full exchange, and keep the source retrievable by reference in case detail is needed.

Two habits keep it honest. Bound the context deliberately — decide how many chunks a step may see and enforce it, rather than letting it grow until a request fails. And measure tokens per job, per tender, per artifact kind. Context management without measurement is guesswork, and here the measurement is also the cost report.

</details>

---

### Q40. How do you prevent hallucinations in transaction-related prompts?

**Project:** police-tender-platform

**Brief answer**
Do not ask the model for facts it would have to invent. Give it the source text, require a citation for every claim, resolve each citation against a real page, and discard the whole artifact if one does not resolve.

<details>
<summary><strong>Must cover</strong></summary>

- **ground every answer in supplied text**, never in the model's own memory
- **require a citation per claim**, with a resolvable anchor
- **validate the citation mechanically**, against a real chunk of the right document
- **fail the whole artifact** on one unresolvable claim
- **typed output**, rejected rather than parsed leniently
- **never compute from generated numbers** — arithmetic belongs in code
- **no generated output is an input to a decision**
- lower temperature, versioned prompts, and a quarantine rate watched as a signal

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

On a platform where the output sits near money and a legal decision, I do not try to make the model reliable. I make unreliable output unable to cause harm.

First, grounding. The model is never asked what a tender requires or what a vendor offered. It is given the extracted, page-anchored text and asked to summarize or extract from that. A question the supplied text cannot answer must come back as "not stated", and the prompt says so.

Second, citation as a structural requirement. The reduce stage emits structured claims, each naming the chunk it came from. This is not a formatting convention — it is the mechanism.

Third, mechanical validation. A validation step resolves every claim's anchor back to a real chunk of a real document belonging to that tender or bid. If a single claim does not resolve, the artifact fails, is quarantined, and is never shown. The officer is told the job failed. That is deliberately strict: a partially correct summary with one invented requirement is more dangerous than none, because a reader cannot tell which sentence is the invented one.

Fourth, typed output. Responses are validated against a schema before anything is stored, and a response that does not fit is a failure rather than something to salvage with a lenient parser.

Fifth, and specific to anything transactional: never let generated text carry arithmetic. Weighted totals are computed in code from human-entered scores, with the formula version recorded on the row. No number a model produced is used in a calculation, and no generated output is ever an input to a score, an eligibility verdict or an award. The criteria for a tender are only ever written through the ordinary endpoint, from an officer accepting or discarding a suggestion.

Sixth, the operational layer. Temperature is low and is lowered further on a retry. Prompts are versioned artifacts in the repository, so they cannot be altered at runtime by anyone who can influence configuration. That also closes the door on steering an award through the assistance. And the share of artifacts quarantined over twenty-four hours is monitored: a rising rate means the refusals are working and something upstream has changed.

The honest framing is that none of this makes the model truthful. It makes an untruthful answer detectable and harmless.

</details>

---

### Q41. What are the risks of multi-agent orchestration with LangGraph, and how do you mitigate them up front?

**Project:** police-tender-platform

**Brief answer**
Unbounded loops, compounding errors, cost that is hard to predict, and a process nobody can explain afterwards. I mitigate by bounding every loop, validating at each hop, and refusing to give agents authority over anything that decides.

<details>
<summary><strong>Must cover</strong></summary>

- **the graph does not terminate** — a loop with no hard bound, capped by step and budget limits
- **error compounding** — a wrong early step that later steps accept
- **unpredictable cost and latency**, capped per job and measured
- **non-determinism**, which makes reproduction and debugging hard
- **prompt injection through document content**, which is the real attack here
- **no authority** — an agent may propose, never decide
- **checkpointing and per-node observability**, so a failed run is explainable
- starting with a fixed graph rather than autonomy, and adding freedom only where it pays

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first risk is that the graph does not terminate. Agents that can call each other will, and a loop with no hard bound burns cost and time until something else stops it. Every cycle needs a maximum iteration count, and every job needs a wall-clock and token budget. Hitting a limit must be a defined outcome — quarantine and notify — rather than an exception nobody catches.

The second is error compounding. In a chain of steps, a wrong result early is treated as established fact by everything downstream, and the final output is confidently wrong. The mitigation is validation at every hop rather than only at the end. Here that means a typed schema plus a citation check between stages, with a bounded retry at lower temperature and a refusal after that.

The third is cost and latency you cannot predict. A fixed pipeline has a cost you can model; an agent that decides how many tool calls to make does not. Summarization already dominates this platform's variable cost, at roughly 180,000 input tokens per bid pack. So per-job caps, content-addressed caching and a daily spend alert against the trailing average are all necessary, not optional.

The fourth is non-determinism. The same input can take a different path, which makes reproduction and debugging hard. Recording the model identifier, prompt version, pipeline version and input hash on every artifact is what makes an investigation possible at all.

The fifth is the one specific to this domain: prompt injection through content. The documents are uploaded by external vendors, and a vendor has a direct incentive to include text instructing the model to rate their proposal favourably. Treating document text as data rather than as instructions is the design answer. Separate the source text from the instruction, keep prompts as versioned artifacts, and above all keep the authority away from the model.

Which is the real mitigation. Nothing generated here decides anything. Extraction proposes criteria a human accepts or discards. Summaries are advisory and citation-validated. No output reaches a score, an eligibility verdict or an award. The whole feature sits behind a switch, and with it off the platform is fully usable. An agent framework is much safer when the worst case is a discarded artifact.

Operationally, checkpointing per node and tracing every step is what makes a failed run explainable rather than mysterious. And I would start with a fixed graph and add autonomy only where it demonstrably pays, because a deterministic pipeline that works beats an agent system that sometimes does.

</details>
