# Fundamental Topics

## Personalized Cancer Support Platform

**Table of Contents**

- [1. Modular Monolith, Module Boundaries, and Selective Extraction](#1-modular-monolith-module-boundaries-and-selective-extraction)
- [2. Async Python and FastAPI Runtime Mechanics](#2-async-python-and-fastapi-runtime-mechanics)
- [3. REST API Design Under Load and Under Retry](#3-rest-api-design-under-load-and-under-retry)
- [4. Authentication: OAuth 2.0, OIDC, JWT, Entra ID](#4-authentication-oauth-20-oidc-jwt-entra-id)
- [5. SCIM 2.0 and Directory-Driven Lifecycle](#5-scim-20-and-directory-driven-lifecycle)
- [6. Authorization: RBAC, ABAC, and PostgreSQL Row-Level Security](#6-authorization-rbac-abac-and-postgresql-row-level-security)
- [7. PostgreSQL Data Modelling for a Clinical Record](#7-postgresql-data-modelling-for-a-clinical-record)
- [8. Query Performance and Execution Plans](#8-query-performance-and-execution-plans)
- [9. SQLAlchemy 2 and Alembic](#9-sqlalchemy-2-and-alembic)
- [10. Elasticsearch Index and Query Design](#10-elasticsearch-index-and-query-design)
- [11. Messaging with RabbitMQ: AMQP and MQTT](#11-messaging-with-rabbitmq-amqp-and-mqtt)
- [12. Celery and Scheduled Work](#12-celery-and-scheduled-work)
- [13. Event-Driven Architecture and the Transactional Outbox](#13-event-driven-architecture-and-the-transactional-outbox)
- [14. Caching with Redis](#14-caching-with-redis)
- [15. Transfer Learning and Fine-Tuning Hugging Face Models](#15-transfer-learning-and-fine-tuning-hugging-face-models)
- [16. Retrieval Pipelines and LangChain Composition](#16-retrieval-pipelines-and-langchain-composition)
- [17. Azure Platform Services in This Design](#17-azure-platform-services-in-this-design)
- [18. Kubernetes, OpenShift and GitOps Delivery](#18-kubernetes-openshift-and-gitops-delivery)
- [19. CI/CD and Quality Gates](#19-cicd-and-quality-gates)
- [20. Observability: Metrics, Logs, Traces](#20-observability-metrics-logs-traces)
- [21. Reliability, Failure Modes and Recovery](#21-reliability-failure-modes-and-recovery)
- [22. Security and Regulatory Compliance for Health Data](#22-security-and-regulatory-compliance-for-health-data)
- [23. Defending the Numbers](#23-defending-the-numbers)

**What this is.** The topics an engineer who claims the responsibilities in `cases/02/projects/cancer-support-platform/inputs.txt` must be able to discuss from first principles, not recite. Grounded in the design docs 00-06 in that folder. Self-contained — it assumes no other project's list.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every MUST bullet carries one; NICE and OPTIONAL bullets do not, because a gap there is survivable and worth admitting plainly. A topic you can only define is not yet known.

**What an answer block is.** Three to five sentences shaped the way the same answer should sound in the room: what it is, the trade-off it buys and what it costs, and where it lands in *this* system. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Where a question in [`interview-questions.md`](./interview-questions.md) already owns the depth, the block ends with a **Deeper:** pointer to it instead of restating it here.

**The exception.** Topic 23 asks what you personally measured, and no answer here can be honest on your behalf. Those blocks hold a prompt skeleton — the facts to have ready — for you to fill in.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | You cannot defend the responsibility without it. Expect it to be probed directly, and expect a wrong or vague answer to cast doubt on the claim itself. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 148 MUST, 48 NICE, 13 OPTIONAL across 23 topics. A MUST-heavy list is the honest consequence of a responsibility list this specific: most of these topics are named or implied by the brief itself rather than added around it.

**Backs:** under each heading names the responsibility line the topic defends. This file is a study aid, not a pipeline artifact: no skill mode reads it and no gate checks it.

## 1. Modular Monolith, Module Boundaries, and Selective Extraction

**Backs:** the [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") modular monolith with diary / clinical-content / identity modules, and the extraction of [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") provisioning and clinical [NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Natural Language Processing — Computational techniques for analyzing and generating human language").

- **MUST** — What makes a module a module: package boundary, its own database schema, no cross-module imports except a published in-process interface

  <details><summary><strong>Answer</strong></summary>

  A module is a boundary you can name and enforce, not a folder: its own package, its own database schema, and no reachable entry point except a published in-process interface. The test is whether you could replace a module's internals without any other module noticing — if another module imports its models or queries its tables, the boundary is decorative. In `care-core` the four modules each own a PostgreSQL schema and reach each other's data only through that interface, so the boundary that exists in code also exists in the database. That costs directness — a cross-module read is a call rather than a join — and you pay it deliberately, because the alternative decays into a shared-table free-for-all that makes later extraction impossible. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-modular-monolith-and-how-is-it-different-from-a-monolith-that-simply-has-not-been-split-yet) — "What is a modular monolith, and how is it different from a monolith that simply has not been split yet?"

  </details>

- **OPTIONAL** — Coupling and cohesion; afferent/efferent dependency direction
- **MUST** — Bounded context and aggregate — where a transaction may and may not span

  <details><summary><strong>Answer</strong></summary>

  A bounded context is the scope within which a term has one meaning and one model owns it; an aggregate is the smallest cluster of data that must change together, and it is the unit a transaction is allowed to span. The working rule is that a transaction may span an aggregate and must not span a context — the moment two contexts must be consistent in one commit, either the boundary is wrong or the link should be an event and eventual consistency. Here `records` and `diary` are separate contexts: a visit note and a check-in never update in one transaction, and what joins them is `care.events` plus the timeline projection. Where I do keep a transaction is inside a context — a check-in row and its `outbox_event` row commit together, because they are one fact.

  </details>

- **MUST** — Criteria that justify extracting a service: independent release cadence, different hardware (GPU), different failure domain — not "it feels big"

  <details><summary><strong>Answer</strong></summary>

  Three things justify a service, and "it feels big" is not among them: a release cadence driven by someone outside your team, different hardware, or a failure domain you actually want isolated. Only two components here met that bar — `scim-provisioning-svc`, whose cadence belongs to the hospital directory, and `clinical-nlp-svc`, which needs GPUs and ships on a model's schedule. Everything else stayed in `care-core`, because at ~200 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") peak with one team a distributed transaction across `diary` and `records` buys latency and on-call load and no throughput. The question I ask is what gets worse if this stays a module; if the honest answer is "nothing", the network hop is pure cost. **Deeper:** [interview-questions.md](./interview-questions.md#q2-only-scim-provisioning-and-clinical-nlp-were-extracted-as-services-defend-that-boundary-and-tell-me-what-would-make-you-extract-a-third) — "Only SCIM provisioning and clinical NLP were extracted as services. Defend that boundary, and tell me what would make you extract a third."

  </details>

- **NICE** — Distributed monolith as the failure mode: services that must deploy together
- **MUST** — Cost of extraction: network calls, partial failure, no shared transaction, versioned contracts, on-call surface

  <details><summary><strong>Answer</strong></summary>

  Extraction turns a function call into a network call, and everything downstream of that is the bill: partial failure becomes a state you have to model, a shared transaction is gone so you need events and idempotent consumers, the interface becomes a versioned contract you can no longer refactor unilaterally, and someone carries a new pager. You also pay in diagnosis, because one user action now spans two deployables — which is why `traceparent` propagation stops being optional. The rule I hold is that you should be able to name what the extraction buys before enumerating what it costs; if the benefit list is shorter, it stays a module. **Deeper:** [interview-questions.md](./interview-questions.md#q3-at-ten-times-the-load-would-you-extract-records-into-its-own-service-what-would-you-want-to-see-first) — "At ten times the load, would you extract `records` into its own service? What would you want to see first?"

  </details>

- **NICE** — The strangler-fig pattern for extracting an existing module incrementally
- **MUST** — Why a fourth module (records) was split from clinical content: different consistency and audit obligations behind the same code path is the defect

  <details><summary><strong>Answer</strong></summary>

  The brief named three modules — diary, clinical content, identity — and I split a fourth, `records`, because the clinical record is a different write model from authored content: different consistency obligations, different audit obligations, different retention. Folding them together puts a prescription and an education leaflet behind one code path, and that is where the defect comes from — a caching or authorization rule that is correct for a leaflet is wrong for a prescription. It costs a fourth boundary and one more in-process interface to maintain. I flag it as a deliberate addition to the brief rather than presenting it as something the brief asked for.

  </details>


## 2. Async Python and FastAPI Runtime Mechanics

**Backs:** event-driven FastAPI services; moving core services to Python 3.14.

- **MUST** — [ASGI](https://asgi.readthedocs.io/en/latest/ "Asynchronous Server Gateway Interface — Standard interface between asynchronous Python web servers and applications") vs WSGI; how uvicorn/gunicorn workers, the event loop and the thread pool actually run your handlers

  <details><summary><strong>Answer</strong></summary>

  WSGI is a synchronous contract — one request occupies one worker for its whole life — while ASGI hands the application an event loop, so one process can hold many in-flight requests as long as each is awaiting I/O rather than computing. In practice gunicorn is the process manager and uvicorn workers are the processes: each worker has one event loop, so concurrency comes from the loop and parallelism comes from the process count. FastAPI runs an `async def` handler directly on the loop and a plain `def` handler in a bounded thread pool — a sync handler is not an error, it is a different execution model with a finite pool behind it. Confusing the two is how a service gets "scaled" by adding workers that then sit idle while one loop is blocked. **Deeper:** [interview-questions.md](./interview-questions.md#q1-in-fastapi-what-is-the-difference-between-declaring-an-endpoint-async-def-and-declaring-it-def) — "In FastAPI, what is the difference between declaring an endpoint `async def` and declaring it `def`?"

  </details>

- **MUST** — async/await, coroutines, tasks, cancellation, timeouts (asyncio.timeout)

  <details><summary><strong>Answer</strong></summary>

  A coroutine is a function that can suspend at an `await` and hand control back to the loop; a Task is a coroutine scheduled to run independently, which is what actually produces concurrency rather than a sequence of awaits. Cancellation is cooperative — cancelling raises `CancelledError` at the next suspension point, so a coroutine that never awaits cannot be cancelled, and a handler that swallows `CancelledError` breaks graceful shutdown. Every outbound call gets a deadline, and `asyncio.timeout` is the right form because it cancels the inner task rather than abandoning it behind a caller that has already given up. In this design that matters most on the `care-core` to `clinical-nlp-svc` hop, which carries a bounded 2 s deadline so a slow model cannot pin a worker.

  </details>

- **MUST** — The blocking-call trap: a sync DB driver or CPU work inside an async handler stalls the whole loop; run_in_executor / threadpool as the escape hatch

  <details><summary><strong>Answer</strong></summary>

  An async handler shares one thread with every other request on that worker, so anything that blocks — a sync database driver, a `requests` call, a large parse, a password hash — stalls every concurrent request on the process, not just its own. The symptom is distinctive and easy to misread: p99 climbs across unrelated endpoints while CPU looks unremarkable and the database looks idle. The escape hatch is to get the work off the loop with `run_in_executor`, or to declare the endpoint `def` so FastAPI uses the threadpool, but the real fix is an async driver — which is why data access here is SQLAlchemy 2 async over asyncpg. I find these with asyncio debug mode's slow-callback warnings and with event-loop lag as a metric, because per-request timings alone will not show you the cause. **Deeper:** [interview-questions.md](./interview-questions.md#q2-someone-adds-a-blocking-call-inside-an-async-def-endpoint-describe-the-symptom-and-how-you-would-find-it) — "Someone adds a blocking call inside an `async def` endpoint. Describe the symptom and how you would find it."

  </details>

- **NICE** — Structured concurrency: gather vs TaskGroup, exception propagation
- **NICE** — Backpressure and concurrency limits; why unbounded fan-out melts a pod
- **MUST** — FastAPI specifics: dependency injection and its caching, routers, lifespan, middleware order, exception handlers, BackgroundTasks vs a real queue

  <details><summary><strong>Answer</strong></summary>

  FastAPI resolves a dependency graph per request and caches each dependency within that request, so a dependency that opens a session is shared by everything below it — and `use_cache=False` is the opt-out when you genuinely want two. Middleware is an onion and order decides what sees what: correlation-id and redaction middleware must sit outside anything that logs, and an app-level exception handler only sees what was raised beneath it. Lifespan is where things that must outlive a request get built — connection pools, the [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client, the search client — because building those per request is a quiet source of connection storms. `BackgroundTasks` runs after the response on the same process and dies with the pod, so anything that must survive a crash goes to Celery instead, which is exactly the line this design draws for check-ins and reminders.

  </details>

- **MUST** — [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") v2: validation vs serialization, model_config (extra=forbid), validators, discriminated unions, settings loading, performance of the Rust core, and why the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") doc is a build artefact rather than a doc

  <details><summary><strong>Answer</strong></summary>

  Pydantic v2 treats validation and serialization as two separate models of the same class — a field can be accepted and coerced on the way in and excluded on the way out. `model_config` is where the contract gets strict: `extra='forbid'` turns a client's typo into a 422 instead of a silently dropped field, and discriminated unions let a polymorphic body such as a timeline entry validate as one declared shape rather than a chain of attempts. The v2 core is Rust so per-field cost is small; what actually costs is building models or validators per request instead of once at import. Because FastAPI derives the OpenAPI document from these models, the published contract is generated from executable code rather than maintained beside it — which is why it is contract-tested in CI as a build artefact. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-pydantic-actually-do-on-each-request-and-what-does-it-cost) — "What does Pydantic actually do on each request, and what does it cost?"

  </details>

- **MUST** — Python 3.14 migration concerns generally: deprecations, C-extension and wheel availability, free-threaded/[GIL](https://wiki.python.org/moin/GlobalInterpreterLock "Global Interpreter Lock — CPython mechanism that lets only one thread execute Python bytecode at a time") discussion, per-interpreter changes

  <details><summary><strong>Answer</strong></summary>

  A runtime move is mostly a dependency problem rather than a language one: language deprecations are documented and mechanical, but a C extension with no wheel for the new interpreter blocks the whole image — on this stack that means asyncpg, the Elasticsearch and Redis clients, and the tokenizer and model stack. So it runs bottom-up: check wheel availability for every pinned dependency first, run the suite on both interpreters for a period, and cut over one service at a time rather than all at once. Free-threaded builds are worth discussing but not adopting here, because dropping the GIL pays off for CPU-bound work and `care-core` is I/O-bound, while the CPU-bound work sits on GPUs in `clinical-nlp-svc`. The payoff actually claimed is consistency — one pinned interpreter and one lockfile per service, so "works in one module, breaks in another" stops being a deploy-time discovery. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-moving-to-python-314-with-poetry-managed-dependencies-actually-give-you-and-what-is-the-risk) — "What does moving to Python 3.14 with Poetry-managed dependencies actually give you, and what is the risk?"

  </details>

- **MUST** — [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects"): lockfile semantics, resolution, groups, why a lockfile removes the "works in one module, breaks in another" class of deploy surprise

  <details><summary><strong>Answer</strong></summary>

  A lockfile pins the exact resolved version and hash of every transitive dependency, so an image built today and rebuilt in six months installs the same tree — `pyproject.toml` states intent, the lock states fact. Groups keep test and lint tooling out of the runtime image, which is both a size and an attack-surface argument. The failure it removes is the one the brief names: two modules resolving different versions of a shared library and diverging at runtime, which shows up at deploy rather than in tests. The cost is discipline — a lock regenerated carelessly to settle a merge conflict quietly undoes the guarantee, so lock changes get reviewed like code.

  </details>


## 3. REST API Design Under Load and Under Retry

**Backs:** [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") APIs for patient and clinician planes; the 202-accepted diary path.

- **MUST** — Resource modelling, URI design, versioning strategy (/api/v1) and how a breaking change is actually rolled out

  <details><summary><strong>Answer</strong></summary>

  Resources are nouns with stable identity and the URI names the thing rather than the action — `/api/v1/patients/{id}/timeline`, never `/getTimeline`; the verb is the method. Versioning is a URI prefix here because that is what a gateway can route on without parsing a body, but the prefix is not the discipline: the rule is that `v1` never breaks, additive changes ship in place, and a breaking change means `v2` running alongside until clients move. Rolling one out is a sequence rather than an event — publish, migrate consumers, watch traffic on the old version, retire on an announced date. What counts as breaking is decided against the OpenAPI document rather than by opinion: removing a field, tightening a type, making an optional field required, or changing a status code all break a generated client. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-frontend-team-generates-its-client-from-your-openapi-document-what-counts-as-a-breaking-change-and-how-do-you-stop-one-reaching-them) — "The frontend team generates its client from your OpenAPI document. What counts as a breaking change, and how do you stop one reaching them?"

  </details>

- **MUST** — Status code semantics that matter here: 202 Accepted and what the client is promised, 409, 412, 422, 503 with Retry-After

  <details><summary><strong>Answer</strong></summary>

  `202 Accepted` promises one thing — the request is durably accepted and will be processed — so it is honest only when durability is genuinely established first, which for a check-in means the broker has acknowledged, and it has to hand back a way to observe the outcome. `409` is a conflict with current state, `412` a failed precondition on a validator the client supplied, and `422` a well-formed request whose content fails validation; the distinction matters because a client should retry only some of those. `503` with `Retry-After` is what the record layer returns during a `pg-clinical` failover — a deliberate refusal to serve a possibly-stale prescription, with a header that turns a retry storm into a schedule. A status code is a contract with the client's retry logic, so choosing one loosely produces either duplicate writes or a client that hangs.

  </details>

- **MUST** — Idempotency keys: storage, [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"), replaying the stored response, why the cache is an optimisation and a natural key in the database is the guarantee

  <details><summary><strong>Answer</strong></summary>

  An idempotency key identifies an *intent*, so a retried [POST](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP POST — HTTP method that submits data to a server to create or process a resource") is recognised as the same intent and replays the stored response instead of performing the mutation twice. The implementation is a record keyed on the key plus the caller, holding the response and a state, with a short TTL and a lock so two concurrent retries cannot both execute. The honest part is where it fails: that record lives in `redis-cache`, and a flush loses it — so the cache is an optimisation and never the guarantee. The guarantee is a natural key in `pg-clinical`, `(patient_id, recorded_for)` for check-ins and `reminder_delivery_id` for dispatches, which makes a duplicate an `ON CONFLICT DO UPDATE` — arithmetic rather than a bug. **Deeper:** [interview-questions.md](./interview-questions.md#q2-every-post-mutation-requires-an-idempotency-key-how-would-you-implement-that-correctly-and-where-does-it-fail) — "Every `POST` mutation requires an `Idempotency-Key`. How would you implement that correctly, and where does it fail?"

  </details>

- **MUST** — Cursor/keyset pagination vs offset — and why offset dies on a 110M-row table

  <details><summary><strong>Answer</strong></summary>

  Offset pagination makes the database produce and discard every row before the offset, so cost grows with depth — `OFFSET 100000` reads a hundred thousand rows to return ten, and on a 110M-row check-in table deep pages degrade into scans. It is also incorrect under concurrent writes: a row inserted ahead of your position shifts every later page, so the client either sees a duplicate or silently misses one. Keyset pagination carries the last row's ordering values as a cursor and asks for rows after them, which is an index seek at constant cost and stable under inserts. Here the cursor is the tuple `(timeline_at, source_table, id)` so ties across the five timeline sources break deterministically; the price is that you cannot jump to page 47, which nobody does on a record view. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-patient-timeline-unions-five-tables-explain-the-timeline_at-normalisation-and-the-keyset-cursor-and-why-offset-pagination-is-prohibited-on-this-query) — "The patient timeline unions five tables. Explain the `timeline_at` normalisation and the keyset cursor, and why offset pagination is prohibited on this query."

  </details>

- **NICE** — Error contracts: [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details, machine-readable error codes
- **NICE** — Contract-first vs code-first; contract tests against the OpenAPI document
- **MUST** — Rate limiting semantics: per-subject vs per-IP, token bucket vs sliding window, and why a hospital behind one [NAT](https://datatracker.ietf.org/doc/html/rfc3022 "Network Address Translation — Maps multiple private addresses to a shared public address") must not rate-limit itself

  <details><summary><strong>Answer</strong></summary>

  A rate limit protects a resource, so it has to be keyed on whoever consumes that resource — the authenticated subject — rather than on an IP address, which is a network accident. That is not pedantry here: a hospital sits behind one NAT address, so a per-IP limit lets one busy clinic throttle a whole trust, while an attacker who is not authenticated can rotate addresses freely. A token bucket permits a burst up to bucket size then refills steadily, which matches human traffic; a sliding window is stricter and suits endpoints where the burst itself is the abuse. The layers here differ by what they protect: [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway") applies a coarse per-subscription and per-IP limit at the edge, and `care-core` applies the per-subject bucket in `redis-cache`, with tighter buckets on authentication, search and document download.

  </details>

- **NICE** — Request correlation: request id, [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") traceparent, propagation obligations

## 4. Authentication: OAuth 2.0, OIDC, JWT, Entra ID

**Backs:** Azure Entra ID [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") authentication; two identity planes.

- **MUST** — [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") roles and grants: authorization code + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), client credentials, refresh; why implicit and ROPC are dead

  <details><summary><strong>Answer</strong></summary>

  OAuth 2.0 has four roles — resource owner, client, authorization server, resource server — and a grant is simply how the client obtains a token without ever handling the user's password. Authorization code with PKCE is the answer for anything with a user, mobile and browser clients included, because PKCE binds the code to the client that requested it and defeats interception of the redirect; client credentials is the machine-to-machine answer, which here is Entra ID calling `scim-provisioning-svc` with its own credential. Implicit is dead because it returned tokens in the [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") fragment where they leak through history and referrers; ROPC is dead because it makes the client handle the password, which forfeits MFA and federation entirely. The consequence here is that both the patient app and the clinician workstation use code plus PKCE against different tenants, and neither client holds a secret it could leak.

  </details>

- **MUST** — [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") on top of OAuth2: id_token vs access_token, claims, scopes, audiences

  <details><summary><strong>Answer</strong></summary>

  OIDC is a thin identity layer on top of OAuth 2.0: OAuth answers whether a client may act on a resource, OIDC adds who the user is, delivered as an `id_token`. The two tokens have different jobs and different audiences — the `id_token` is for the client, is not a credential for your API, and must never be accepted as one, while the `access_token` is for the resource server and is the only thing the API validates. Scopes describe what the client asked for, claims describe the subject, and `aud` names who the token is for — the claim this design leans on hardest. Treating an `id_token` as an access token is a common and serious bug, because it is often longer-lived and issued to a client you do not control.

  </details>

- **MUST** — JWT anatomy: header/kid, claims, [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") signing, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") endpoint, key rotation and the overlap window; local verification vs introspection round-trip

  <details><summary><strong>Answer</strong></summary>

  A JWT is three base64url segments — header, claims, signature — where the header's `kid` names the signing key and the claims carry `iss`, `aud`, `exp`, `nbf` and `sub`. With RS256 the issuer signs with a private key and you verify with the matching public key from the JWKS endpoint, so verification is local and needs no round trip to the identity provider, which is what makes a stateless token cheap at request rate. Rotation works because JWKS publishes several keys at once and `kid` selects one: the issuer starts signing with the new key while the old one is still published, so tokens minted before the rotation keep validating through the overlap window. That is why the JWKS cache here holds 12 h and refreshes on an unknown `kid` — the long TTL is deliberate, because it keeps existing tokens validating through an Entra ID outage. **Deeper:** [interview-questions.md](./interview-questions.md#q3-entra-id-has-a-regional-outage-the-json-web-key-set-jwks-cache-holds-signing-keys-for-twelve-hours-walk-through-what-works-what-does-not-and-what-that-long-time-to-live-risks) — "Entra ID has a regional outage. The JSON Web Key Set (JWKS) cache holds signing keys for twelve hours. Walk through what works, what does not, and what that long time-to-live risks."

  </details>

- **MUST** — Audience separation as an authorization boundary — a clinician token rejected on a patient route before application code runs

  <details><summary><strong>Answer</strong></summary>

  The `aud` claim says which API a token was minted for, so checking it is an authorization decision rather than a formality: a clinician token carries the clinician audience and is rejected on a patient route before any application code runs. That is stronger than a role check inside the handler for two reasons — it fails closed at the gateway, so a route someone adds without an authorization decorator is still protected, and it cannot be undone by a bug in the code that maps roles to permissions. It also enforces the brief's actual requirement that clinician accounts stay off the patient portal: separate tenants issue separate audiences, so a clinician cannot accidentally become a patient. The cost is that anything genuinely needing both planes must be an explicit, audited crossing rather than a convenience. **Deeper:** [interview-questions.md](./interview-questions.md#q1-clinician-and-patient-tokens-are-separate-audiences-checked-at-the-gateway-why-is-that-stronger-than-checking-the-users-role-in-application-code) — "Clinician and patient tokens are separate audiences checked at the gateway. Why is that stronger than checking the user's role in application code?"

  </details>

- **MUST** — Token lifetime as a revocation window; refresh rotation, reuse detection, denylists, and what "revoked" really means with stateless tokens

  <details><summary><strong>Answer</strong></summary>

  With stateless tokens there is no revocation — the resource server checks a signature and an expiry, so a token stays valid until it expires regardless of what happened to the account. Lifetime is therefore the revocation window, and it trades directly against traffic to the identity provider; 15 minutes is the compromise here, with rotated refresh tokens carrying the real session. Rotation issues a new refresh token on every use and invalidates the old one, so reuse of a consumed token is detectable and revokes the whole family. A denylist shrinks the window further but reintroduces exactly the shared state stateless tokens exist to avoid, so I would rather keep access tokens short and put the durable decision where it belongs — deprovisioning closes the `care_relationship` rows, so a still-valid token stops seeing patients.

  </details>

- **NICE** — Where to store tokens in a browser: HttpOnly/Secure/SameSite cookies, CSRF
- **MUST** — Validating twice (gateway and service) — why the edge is a filter, never the authority

  <details><summary><strong>Answer</strong></summary>

  The gateway validates the JWT — signature, issuer, expiry, audience — and `care-core` validates it again rather than trusting a header the gateway set. The edge is a filter, not the authority: anything reaching the service by another path, a loosened NetworkPolicy, a port-forward, a second ingress added under time pressure, would otherwise arrive already trusted. Trusting an injected header makes your authentication exactly as strong as your network configuration, which is not a property you can assert in a test. The duplication costs a signature verification against a cached JWKS, which is microseconds; the alternative is a control that silently disappears the day the topology changes.

  </details>

- **OPTIONAL** — [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity"), conditional access, and identity proofing at enrolment

## 5. SCIM 2.0 and Directory-Driven Lifecycle

**Backs:** SCIM 2.0 so clinician accounts stay provisioned from the hospital directory and stay off the patient portal.

- **MUST** — The SCIM object model: /Users, /Groups, ServiceProviderConfig, Schemas, core and enterprise attributes, externalId vs id

  <details><summary><strong>Answer</strong></summary>

  SCIM 2.0 is a REST protocol with a fixed identity schema: `/Users` and `/Groups` as resources, with `/Schemas` and `/ServiceProviderConfig` as discovery endpoints that tell a client which optional features you actually implement. The core user schema carries `userName`, `name`, `emails` and `active`; the enterprise extension adds employment attributes such as department and manager. The distinction that causes the most bugs is `id` versus `externalId` — `id` is yours and immutable, `externalId` is the directory's, and the mapping between them is the thing you must store, here as `scim_external_id` and `entra_object_id` on the `clinician` row. Keeping `ServiceProviderConfig` honest matters too, because Entra ID reads it and will use whatever you claim to support. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-scim-20-and-what-does-it-solve-that-oauth-20-does-not) — "What is SCIM 2.0, and what does it solve that OAuth 2.0 does not?"

  </details>

- **MUST** — PATCH operation semantics (add/replace/remove, path filters) and why they are the hard part of a compliant implementation

  <details><summary><strong>Answer</strong></summary>

  SCIM `PATCH` is where compliance is actually decided: the operations are `add`, `replace` and `remove`, each with an optional `path` that may itself be a filter expression such as `emails[type eq 'work'].value`. So a correct implementation has to parse a small query language and apply it to a nested document, and semantics differ with multiplicity — `add` appends on a multi-valued attribute and replaces on a single-valued one. It is the hard part because identity providers send patches you did not anticipate, and a half-applied patch leaves an account in a state neither side believes in. My approach is to apply the whole patch in one transaction and reject it outright rather than apply it approximately, and to keep a fixture suite of real directory payloads rather than invented ones.

  </details>

- **OPTIONAL** — Filtering, pagination and sorting the spec requires
- **MUST** — Deprovisioning: active:false vs DELETE; what must happen transactionally on the platform side (closing every open care relationship)

  <details><summary><strong>Answer</strong></summary>

  `active: false` is a soft disable and `DELETE` is a hard removal; for a clinical record you want the former, because the account must stop working immediately while authorship of past visit notes and the audit trail must survive. What matters is what happens on your side of that call: deprovisioning is not a flag flip, it has to close every open `care_relationship` for that clinician in the same transaction, or the account is disabled while the access it granted is still described as current. Doing it transactionally is what makes "access ends when employment ends" true rather than aspirational, and it is also what removes the clinician's search reach, since scope is resolved from those rows on every query. The cost is a multi-row write on a hot table, which takes the same care as any other write that must not half-apply. **Deeper:** [interview-questions.md](./interview-questions.md#q2-a-clinician-leaves-the-trust-trace-what-happens-end-to-end) — "A clinician leaves the trust. Trace what happens, end to end."

  </details>

- **MUST** — Idempotency and ordering of provisioning calls; serialization locks per directory object

  <details><summary><strong>Answer</strong></summary>

  A directory retries and does not promise ordering, so the same create can arrive twice and an update can arrive before the create it depends on. Idempotency comes from keying on `externalId` rather than on an id you generate, so a repeated create is an upsert; ordering comes from serialising per directory object rather than globally — a short-lived lock on `lock:scim:{entra_object_id}` — so two operations on one clinician cannot interleave while different clinicians still process in parallel. Where the payload carries a version or timestamp I use it as a monotonic guard and drop the stale operation rather than apply it. The alternative, a single-threaded consumer, is correct but turns a directory-wide sync into a serial job, which is a real cost at several thousand seats.

  </details>

- **MUST** — Failure handling: a silently failed sync is access that should have ended and has not — which is why it pages

  <details><summary><strong>Answer</strong></summary>

  A failed SCIM sync is not a data-quality issue, it is a security event: the case it represents is a clinician who has left the trust whose access has not been closed. That is why it pages rather than retrying quietly into a dashboard — the failure is silent by nature, since nothing on the platform misbehaves, and the sync is the only observable. So the handling is retry with backoff for transient errors, dead-letter with the payload for anything structural, alert on sustained failure rate, and reconcile periodically by comparing the directory's active set against `clinician.active` instead of assuming the stream was complete. The principle generalises: a control whose failure produces no symptom needs monitoring of its own, because nobody is going to report it.

  </details>

- **OPTIONAL** — Just-in-time provisioning vs SCIM; SAML/OIDC claims mapping as alternatives
- **OPTIONAL** — Testing against a real Entra ID tenant vs a mock; the compliance test suites

## 6. Authorization: RBAC, ABAC, and PostgreSQL Row-Level Security

**Backs:** clinician/care-team access to only their patients; identity module.

- **MUST** — [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") for capability vs [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") for reach — why roles alone cannot express "this clinician, this patient, right now"

  <details><summary><strong>Answer</strong></summary>

  RBAC answers what kind of thing you may do — a clinician may write a visit note, a coordinator may not — and it fits capability well because roles are few, stable and reviewable. It cannot express reach: "this clinician, this patient, right now" is not a role, and forcing it into one produces a role per patient, which is neither manageable nor auditable. ABAC decides from attributes of subject, resource and environment, which is the actual shape of reach — does an active care relationship exist between these two at this instant. This design uses both deliberately, RBAC for capability in the application and ABAC for reach in the database, so neither mechanism has to do the other's job badly.

  </details>

- **MUST** — Relationship-based access control; the care relationship as the single definition of "may this clinician see this patient"

  <details><summary><strong>Answer</strong></summary>

  Relationship-based access control makes the edge between two entities the unit of authorization, which is exactly the shape of clinical access — a clinician sees a patient because a care relationship exists, not because of anything intrinsic to either party. The design property I care about most is that this relationship has one definition, `care_relationship` in `pg-clinical`, joined by the RLS policies, with no second copy in application code, in the search layer, or in a cached role list. One definition is what makes it auditable and what makes revocation a single write. The cost is a join on every clinician request, which is why there is a GiST index on `(patient_id, clinician_id, valid_period)` sized for exactly that pattern.

  </details>

- **MUST** — Temporal authorization: tstzrange, [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") exclusion constraints, why history is not overwritten and access has an end

  <details><summary><strong>Answer</strong></summary>

  Access with no end is a defect, so `valid_period` is a `tstzrange` and the check asks whether `now()` falls inside it rather than whether a boolean is true. A GiST exclusion constraint prevents two overlapping relationships for the same pair from existing at once, so the invariant is enforced by the schema rather than by application discipline. Closing access sets the range's upper bound instead of deleting the row, so history survives and "who could see this patient last March" is a query rather than an archaeology exercise. That matters here because an audit trail that cannot reconstruct past authorization cannot answer the question a regulator actually asks.

  </details>

- **MUST** — [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user"): policies, USING vs WITH CHECK, FORCE ROW LEVEL SECURITY, BYPASSRLS, the owning role vs the application role

  <details><summary><strong>Answer</strong></summary>

  Row-level security attaches a policy to a table so the database filters rows against the current session's identity: `USING` governs which rows a query may see and `WITH CHECK` governs which rows a write may produce, and they differ — you can be allowed to read a row you may not create. `FORCE ROW LEVEL SECURITY` matters because the table owner is exempt by default, so the application role is `NOSUPERUSER` without `BYPASSRLS` and migrations run as a separate owning role that never serves a request. Here each request sets `app.actor_id` and `app.actor_kind` and the policies join through `care_relationship`, so a query a developer forgot to scope returns zero rows instead of another patient's record. The cost is that the policy is now part of every plan, which is why the predicate is written to stay visible to the planner rather than hidden behind an opaque subquery. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-row-level-security-and-how-is-it-different-from-filtering-by-patient-in-application-code) — "What is row-level security, and how is it different from filtering by patient in application code?"

  </details>

- **MUST** — The pooling trap: SET LOCAL inside the transaction vs SET; a transaction-mode pooler reusing a backend leaks one caller's identity into the next

  <details><summary><strong>Answer</strong></summary>

  The identity is a session [GUC](https://www.postgresql.org/docs/current/config-setting.html "Grand Unified Configuration — PostgreSQL's mechanism for setting configuration parameters at the server, session or transaction scope"), so it lives on the database backend — and a transaction-mode pooler hands that same backend to a different caller the moment your transaction ends. A plain `SET` therefore leaks one caller's identity into the next caller's query, and it does not fail loudly: it silently authorizes the wrong person, turning the strongest control in the design into its exact opposite. `SET LOCAL` scopes the value to the transaction so it is discarded on commit and the next borrower starts clean. This is not left to review — a pooled-connection leakage test runs two identities through one pooled backend and asserts the second sees nothing of the first. **Deeper:** [interview-questions.md](./interview-questions.md#q2-explain-how-a-transaction-mode-connection-pooler-could-turn-row-level-security-into-its-opposite) — "Explain how a transaction-mode connection pooler could turn row-level security into its opposite."

  </details>

- **NICE** — Keeping the predicate visible to the planner so partition pruning survives
- **MUST** — Defence in depth: application check first line, database second, and why the ordering matters (a forgotten scope returns zero rows, not another patient)

  <details><summary><strong>Answer</strong></summary>

  The application check is the first line because it produces a correct error — a refusal with a reason — and the database is the second because it is the one that cannot be forgotten. The ordering matters for both usability and failure mode: when application code is right you get a clean `403`, and when it is wrong you get an empty result set rather than a disclosure. That inversion is the whole point, because the most common bug in a system like this is a missing scope clause, and RLS converts that entire bug class from "returns everyone" into "returns nothing". The honest caveat is that RLS protects rows rather than aggregates or side channels, and it is only as good as the session variable being set correctly — which is why the pooling test and the role-privilege assertion exist. **Deeper:** [interview-questions.md](./interview-questions.md#q3-row-level-security-is-called-the-single-most-important-control-here-what-is-the-strongest-argument-against-relying-on-it-and-how-would-you-satisfy-an-auditor-that-it-works) — "Row-level security is called the single most important control here. What is the strongest argument against relying on it, and how would you satisfy an auditor that it works?"

  </details>

- **MUST** — IDOR / broken object-level authorization as the bug class this removes

  <details><summary><strong>Answer</strong></summary>

  Insecure direct object reference — broken object-level authorization in the OWASP API list — is a handler that uses an identifier from the request to fetch a resource without checking the caller is entitled to it. It tops that list precisely because it is invisible in review: the code looks like every other fetch by id, and the tests pass because tests fetch their own data. Unguessable identifiers are an obstacle rather than a fix; the UUIDs here are for distribution, not secrecy. The structural fix is to make the entitlement check unavoidable, which is what RLS does — the fetch by id returns zero rows for a caller with no care relationship, so the bug degrades into a 404 instead of a disclosure.

  </details>

- **NICE** — Break-glass: reason string, time-boxed grant, notification, review
- **NICE** — Separation of duties (author cannot approve their own content)

## 7. PostgreSQL Data Modelling for a Clinical Record

**Backs:** designed PostgreSQL schemas; migrated data access and tightened [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database").

- **MUST** — Normalisation and when denormalisation is deliberate rather than lazy

  <details><summary><strong>Answer</strong></summary>

  Normalisation gives a fact one place to live and therefore one place to change; denormalisation reintroduces a copy to avoid a join, and it is deliberate only when you can name the read it serves and the mechanism that keeps the copy true. On a clinical record I default hard to normalised, because a duplicated fact that drifts is a wrong clinical answer rather than a stale counter. The one denormalisation in this schema is `timeline_at`, copied from each table's natural column on write — defensible because the source column never changes meaning and because the natural column stays as the clinical fact. Anything I could not justify that precisely stays normalised and pays for the join.

  </details>

- **MUST** — Keys: uuid vs bigint, natural vs surrogate, uniqueness as an invariant enforced by the schema instead of by retry logic

  <details><summary><strong>Answer</strong></summary>

  A surrogate key exists to be stable, so it should carry no business meaning — an [MRN](https://en.wikipedia.org/wiki/Medical_record "Medical Record Number — Unique identifier a healthcare provider assigns to a patient's record") or an email is a natural key that will eventually change and drag every foreign key with it. UUIDs are used here because identifiers are minted by several writers and appear in URLs, where a sequential integer leaks volume and invites enumeration; the cost is index size and, with random values, page splits on insert, which is why a time-ordered variant is worth considering on the hottest tables. Natural keys still earn their place as constraints rather than as primary keys, and `(patient_id, recorded_for)` unique on `wellbeing_checkin` is the clearest case. That is the general point: uniqueness is an invariant, and the schema is the only place it can actually be enforced — a select-then-insert in application code is a race that retry logic hides rather than fixes.

  </details>

- **MUST** — Constraints as correctness: unique, partial unique, check, exclusion, FK actions; unique (patient_id, recorded_for) absorbing at-least-once delivery

  <details><summary><strong>Answer</strong></summary>

  Constraints are how correctness gets written where it cannot be bypassed: unique for identity, partial unique for "only one active X per Y", check for value invariants, exclusion for "these ranges may not overlap", and foreign keys with an action someone actually chose. They belong in the schema rather than the service because every writer is subject to them — including migrations, a backfill script, and the second service that writes the `identity` schema here. The concrete payoff is the unique key on `(patient_id, recorded_for)`: at-least-once redelivery is a fact of the MQTT ingest path, so the projection is an `INSERT ... ON CONFLICT DO UPDATE` and a duplicate check-in becomes an update rather than a second row. The cost is that a violation arrives as an error you must handle deliberately, which is the right trade — a loud failure instead of a quiet duplicate.

  </details>

- **MUST** — jsonb vs columns vs [EAV](https://en.wikipedia.org/wiki/Entity%E2%80%93attribute%E2%80%93value_model "Entity Attribute Value — Schema pattern for storing entities whose attributes vary and are not known in advance") — what jsonb costs (statistics, TOAST, write amplification) and what a [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") index over it buys

  <details><summary><strong>Answer</strong></summary>

  There are three ways to hold a variable attribute set: typed columns, which are fastest and most checkable but need a migration per attribute; EAV, which is flexible and turns every query into a self-join; and `jsonb`, which keeps the document together and stays queryable and indexable. `symptom_scores` is `jsonb` because the symptom set differs by cancer type and moves with clinical protocol, so typed columns would mean a migration against a 110M-row table every time the protocol changes. What it costs is concrete: no per-key statistics, so the planner estimates selective keys badly; TOAST compression and out-of-line storage on larger documents; and write amplification, since updating one key rewrites the whole value. A GIN index buys containment and key-existence queries — what the trend query needs — at the price of an index that is larger and slower to update than a B-tree on a column. **Deeper:** [interview-questions.md](./interview-questions.md#q1-symptom_scores-is-a-jsonb-column-rather-than-a-set-of-typed-columns-why-and-what-do-you-give-up) — "`symptom_scores` is a `jsonb` column rather than a set of typed columns. Why, and what do you give up?"

  </details>

- **NICE** — Temporal and append-only tables; audit tables with UPDATE/DELETE revoked
- **MUST** — Normalising an ordering column (timeline_at) across heterogeneous sources so one index shape and one deterministic cursor serve a union

  <details><summary><strong>Answer</strong></summary>

  Five tables feed the timeline and each has a different natural ordering column, one of them a `date` rather than a `timestamptz`, so a `UNION ALL` across them can neither be ordered deterministically nor served from a single index shape. `timeline_at` is a normalised ordering column populated on write from each table's natural column, so all five carry the same type and one composite index `(patient_id, timeline_at DESC)` serves every branch. It is also what makes the keyset cursor possible: the cursor is the tuple `(timeline_at, source_table, id)`, and the second and third elements exist to break ties across sources deterministically, because two events can share a timestamp. The natural columns stay, because `encounter_date` is the clinical fact and `timeline_at` is only a presentation key — collapsing them would let a display concern rewrite the record. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-patient-timeline-unions-five-tables-explain-the-timeline_at-normalisation-and-the-keyset-cursor-and-why-offset-pagination-is-prohibited-on-this-query) — "The patient timeline unions five tables. Explain the `timeline_at` normalisation and the keyset cursor, and why offset pagination is prohibited on this query."

  </details>

- **NICE** — Soft delete: why it is refused here, and consent-based restriction instead
- **NICE** — Searchable encryption: deterministic vs non-deterministic encryption, [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key") blind index, key separation, and what a blind index leaks
- **MUST** — Declarative partitioning: range by month, pruning, attach/detach as a metadata operation, constraints and index inheritance, partition-wise joins

  <details><summary><strong>Answer</strong></summary>

  Declarative range partitioning splits one logical table into physical children by a key range — by month here — so a query bounded on that key prunes to the partitions it needs and never touches the rest. It fits `wellbeing_checkin` and `audit_event` because both are written append-only and read by recent time window, which is exactly the access pattern pruning rewards, and fits nothing else in this schema. The operational payoff is as large as the query one: archiving a month is `DETACH PARTITION`, a metadata operation, rather than a `DELETE` across hundreds of gigabytes that bloats the table and holds locks. The costs worth naming are that indexes and constraints are per partition, a unique constraint must include the partition key, planning time grows with partition count, and a query with no predicate on the key scans everything — which is why the RLS policy is written to keep both `patient_id` and the time bound visible to the planner. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-declarative-range-partitioning-and-why-are-wellbeing_checkin-and-audit_event-partitioned-by-month-while-the-other-tables-are-not) — "What is declarative range partitioning, and why are `wellbeing_checkin` and `audit_event` partitioned by month while the other tables are not?"

  </details>

- **NICE** — [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") vs B-tree when physical order matches insert order
- **NICE** — Schema-per-module in one database; migration ownership across two writers

## 8. Query Performance and Execution Plans

**Backs:** cutting query latency by 35%; tightening SQL for timeline and care-team views.

- **MUST** — EXPLAIN (ANALYZE, BUFFERS): scan types, join strategies, rows-estimated vs rows-actual, the meaning of a bad estimate

  <details><summary><strong>Answer</strong></summary>

  `EXPLAIN` shows the plan the planner chose; `EXPLAIN (ANALYZE, BUFFERS)` runs it and shows what happened, including block reads split into shared hits and reads, which is how you separate a cold cache from real work. The first thing I read is rows-estimated against rows-actual at each node, because a large divergence means the planner worked from wrong statistics and every choice above that node — the join strategy especially — rests on a false premise. Scan choice follows selectivity, so a sequential scan on a big table is only a bug if the predicate was genuinely selective, and the join strategies fail differently: a nested loop is excellent on a few rows and catastrophic on many. The fix follows the cause rather than the symptom — stale statistics get `ANALYZE` or a higher statistics target, correlated predicates may need extended statistics, and only after that does an index change earn consideration. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-clinician-timeline-query-has-become-slow-in-production-walk-me-through-diagnosing-it) — "The clinician timeline query has become slow in production. Walk me through diagnosing it."

  </details>

- **OPTIONAL** — Planner statistics, n_distinct, extended statistics, ANALYZE cadence
- **MUST** — Index selection: composite index column order, leading-column rule, index-only scans and the visibility map, partial indexes for hot subsets

  <details><summary><strong>Answer</strong></summary>

  A composite index is ordered left to right, so it serves any prefix of its columns: `(patient_id, timeline_at DESC)` answers a patient filter, and a patient filter with a time range and ordering, but nothing keyed on time alone. Column order therefore follows the predicate shape — equality columns first, then the range or ordering column — which is why that index is patient then time rather than the reverse. An index-only scan skips the heap entirely, but only when the visibility map marks the pages all-visible, so it depends on vacuum having run; a plan that regresses right after a bulk load is often exactly this. Partial indexes are the highest-value trick in this schema: `WHERE state = 'pending'` on reminders and `WHERE published_at IS NULL` on the outbox keep the hot index the size of the pending set instead of the size of all history.

  </details>

- **MUST** — Access-pattern-first indexing; every index is a write tax on inserts

  <details><summary><strong>Answer</strong></summary>

  Every index is paid for on every write — an insert maintains all of them — so on a 110M-row table an index nobody queries is write amplification plus storage plus vacuum work, permanently. The rule I follow is that an index is created against a named access pattern from a named endpoint, and if you cannot name the query, you do not add the index. That is why the index list in this design is deliberately short and each entry maps to an endpoint: the timeline composite, the reminders partial, the outbox partial, the GiST on care relationships, the GIN on symptom scores. The other half of the rule is removal — `pg_stat_user_indexes` shows what is never scanned, and dropping those is a real write-path win that people rarely take.

  </details>

- **MUST** — Data access patterns and their pathologies: N+1 queries, SELECT *, implicit casts defeating an index, functions on the indexed column, OR-chains

  <details><summary><strong>Answer</strong></summary>

  N+1 is the common one: an ORM lazily loads a relationship inside a loop, so one endpoint issues a query per row and no individual query looks slow — the cure is eager loading with `selectinload`, plus `raiseload` so an accidental lazy load raises rather than merely costs. `SELECT *` wastes bandwidth, forces detoasting of large values, and quietly forfeits index-only scans, which is why the projection is explicit. The subtler pathologies all defeat an index the same way: an implicit cast between a column type and a parameter type, a function wrapped around the indexed column instead of the value, a leading-wildcard `LIKE`, and long `OR` chains the planner cannot collapse into one scan. What they share is that none of them fail — they just get slow at production volume, which is why the plan gets checked rather than assumed.

  </details>

- **MUST** — UNION ALL with LIMIT pushed into each branch vs materialise-then-sort

  <details><summary><strong>Answer</strong></summary>

  The naive union materialises every matching row from all five tables, sorts the whole set, and returns the first page — so a patient with years of history pays for their entire record on every timeline read. Pushing the `ORDER BY` and `LIMIT` into each branch means PostgreSQL reads at most `limit` rows per source straight from the composite index, then merges a handful of short sorted streams. `UNION ALL` rather than `UNION` matters too, because `UNION` implies a de-duplication pass over the whole result and the branches are disjoint by construction. The cost is a verbose query in which every branch must keep the same shape and ordering column — which is exactly why that column was normalised.

  </details>

- **MUST** — Keyset pagination cursors over a tuple; ties broken deterministically

  <details><summary><strong>Answer</strong></summary>

  A keyset cursor is the ordering values of the last row returned, passed back so the next query asks for rows strictly after that point — an index seek rather than a count-and-discard. It only works if the ordering is total, so the tuple has to end in something unique; here it is `(timeline_at, source_table, id)`, because two sources can share a timestamp and a two-element cursor would then drop or repeat a row at the page boundary. The comparison is written as a row-wise one rather than a chain of ANDs and ORs, so the index can serve it directly. I also keep the cursor opaque to the client — encoded rather than a readable timestamp — because a client that builds its own cursor has quietly become a consumer of your internal ordering.

  </details>

- **MUST** — Locking and concurrency: [MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row"), isolation levels, FOR UPDATE SKIP LOCKED for queue-like claiming, lock waits, deadlock detection

  <details><summary><strong>Answer</strong></summary>

  MVCC means a write never blocks a read: an update writes a new row version and readers keep seeing the version valid for their snapshot, which is why long-running transactions are expensive — they hold back cleanup of versions nobody needs. Read Committed takes a fresh snapshot per statement and is the sensible default; Repeatable Read pins one snapshot for the transaction and can raise a serialization error the application must be prepared to retry. `FOR UPDATE SKIP LOCKED` is the queue-claiming pattern and is what lets several workers sweep due reminders at once, each taking rows nobody else holds instead of all of them contending on the head of the queue. Deadlocks come from inconsistent lock ordering between transactions; PostgreSQL detects them and kills one, so the fix is to order writes consistently rather than to retry harder.

  </details>

- **NICE** — Bloat, autovacuum, HOT updates, index maintenance
- **MUST** — Connection pooling: server connection limits, pgbouncer pool modes and what each mode forbids (prepared statements, session GUCs, advisory locks)

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL backends are processes, so `max_connections` is a hard resource ceiling and a few hundred mostly-idle connections cost far more than they appear to; a pooler exists to keep a small number of busy backends rather than a large number of idle ones. Session mode hands a client a backend for its whole session and forfeits most of the benefit; transaction mode is where the throughput is, and it is the mode that forbids things — session-level `SET`, session advisory locks, `LISTEN/NOTIFY`, and server-side prepared statements unless pooler and driver negotiate them. That list is not trivia in this design, because the RLS identity is set as a session GUC, which is precisely a session-level `SET` — hence `SET LOCAL` inside the transaction. Statement mode goes further and forbids multi-statement transactions altogether, which is unusable for a record that must write its audit row and serve its read in one transaction. **Deeper:** [interview-questions.md](./interview-questions.md#q3-row-level-security-monthly-partitioning-and-connection-pooling-all-interact-on-the-same-query-describe-the-failure-that-arises-from-each-pair) — "Row-level security, monthly partitioning, and connection pooling all interact on the same query. Describe the failure that arises from each pair."

  </details>

- **MUST** — Measuring rather than asserting: pg_stat_statements, auto_explain, a baseline before the change and the same query shape after

  <details><summary><strong>Answer</strong></summary>

  `pg_stat_statements` is the starting point because it aggregates by normalised query text, so you find the query whose *total* time dominates rather than the one that felt slow — and the biggest win is often a fast query executed absurdly often. `auto_explain` with a duration threshold captures the plan of the slow execution in production, which matters because the plan you reproduce by hand against a warm cache is frequently not the plan that hurt. The discipline is the same as any other measurement: capture a baseline on the same query shape, same data volume and same cache state before the change, then re-measure the identical shape after. Without that you are comparing a cold run to a warm one and crediting your index for the difference, which is exactly how a latency improvement becomes an indefensible claim.

  </details>


## 9. SQLAlchemy 2 and Alembic

**Backs:** migrated data access to [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") 2; [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") in the deploy path.

- **MUST** — Core vs [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") and when the generated plan matters more than the mapping

  <details><summary><strong>Answer</strong></summary>

  Core is a SQL expression language — you compose the statement and that statement is what runs; the ORM adds an identity map, unit of work and relationship loading on top of the same construction machinery. The ORM earns its place on the write side of a record, where a unit of work keeps a set of related changes coherent in one flush. It earns it less on read paths whose plan you care about: the five-branch timeline union with per-branch limits is written explicitly because the shape of the emitted SQL is the entire point of it. So the rule is that the mapping matters where correctness across related objects matters, the plan matters where the query is hot, and on the hot ones I read the emitted SQL rather than trusting the mapping produced what I meant.

  </details>

- **MUST** — The 2.0 style: select() everywhere, typed Mapped[] annotations, removal of the legacy Query [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), what a 1.x → 2.0 migration actually breaks

  <details><summary><strong>Answer</strong></summary>

  The 2.0 style unifies Core and ORM on `select()` and `session.execute()`, retires the legacy `Query` object, and moves the mapping into `Mapped[]` annotations so the model is typed rather than described in loosely-typed constructs. The typing is the point on a clinical record: pyright in strict mode can tell you a column is `str | None`, or that a relationship does not exist, before a wrong join becomes a disclosure at runtime. A 1.x to 2.0 migration mostly breaks in three places — every `session.query(...)` call site, implicit autocommit patterns that no longer exist, and attribute access after commit, since results come back as rows rather than instances and `expire_on_commit` bites harder. The route through it is the 1.4 compatibility step with deprecation warnings turned into errors, converting call sites incrementally rather than in one commit. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-changed-between-sqlalchemy-1x-and-sqlalchemy-2-and-why-does-the-typed-api-matter-more-on-a-clinical-record-than-on-an-ordinary-application) — "What changed between SQLAlchemy 1.x and SQLAlchemy 2, and why does the typed API matter more on a clinical record than on an ordinary application?"

  </details>

- **MUST** — Session as unit of work: identity map, flush vs commit, expire_on_commit, session lifecycle bound to a request

  <details><summary><strong>Answer</strong></summary>

  A Session is a unit of work: it holds an identity map so one row becomes one object, tracks changes, and emits them in dependency order on flush. Flush sends the SQL, commit ends the transaction — so a flushed-but-uncommitted change is visible to your own later queries and to nobody else, which is what makes read-your-writes work within a request. `expire_on_commit` marks instances stale after commit, so touching an attribute afterwards issues a fresh query, which is convenient inside a request and a source of surprise lazy loads at its edge. The lifecycle rule I hold is one session per request, opened and closed by a dependency, never shared across tasks and never held across work that leaves the request — a Session is neither thread-safe nor concurrency-safe.

  </details>

- **MUST** — Lazy loading and the N+1 it creates; selectinload / joinedload / raiseload

  <details><summary><strong>Answer</strong></summary>

  A lazily-loaded relationship issues its query the first time you touch the attribute, so a loop over fifty rows that reads a relationship runs fifty-one queries — each fast, none of them slow enough to appear in a slow-query log. `selectinload` fetches the children for the whole batch in a second query with an `IN` list, which is the right default for collections; `joinedload` fetches in one query with a join, better for a single related row but it multiplies parent rows for a collection. `raiseload` is the underused one: it turns an unplanned lazy load into an exception, so the N+1 fails a test instead of degrading production latency. In an async session lazy loading raises anyway, because the implicit IO cannot happen at attribute access — arguably the healthier default.

  </details>

- **MUST** — Async engine and session; asyncpg driver differences; greenlet boundary

  <details><summary><strong>Answer</strong></summary>

  The async engine runs the same Core and ORM constructs, but IO happens only at explicit await points, so anything that would trigger implicit IO — a lazy relationship load, an expired attribute after commit — raises rather than quietly querying. Underneath, SQLAlchemy bridges its synchronous internals with greenlets, which is why an occasional error message mentions greenlets when what it really means is implicit IO in an async context. asyncpg differs from psycopg in ways that surface in practice: it is stricter about types, it keeps its own prepared-statement cache that conflicts with a transaction-mode pooler unless disabled, and its parameter style differs, so raw SQL is not portable between the two for free. The payoff is the one this stack needs — no synchronous driver blocking the event loop on the request path.

  </details>

- **NICE** — Bulk operations, insert().on_conflict_do_update(), returning()
- **NICE** — Alembic: revision graph, branches and merges, autogenerate's blind spots (server defaults, index changes, enums, data migrations)
- **MUST** — Expand/contract migrations: why the previous image must run against the new schema, CREATE INDEX CONCURRENTLY, lock-taking DDL and statement timeouts

  <details><summary><strong>Answer</strong></summary>

  Expand/contract splits a schema change across two releases: the first only adds — a nullable column, an index, a backfill, dual writes — and the second removes what is no longer read, once nothing running depends on it. The reason is that during a blue-green cut-over both image versions run against one database, so every migration has to be compatible with the previous image, and that is precisely what makes rollback an ArgoCD revision revert rather than a down-migration. The mechanics that keep it non-blocking on a 110M-row table are specific: `CREATE INDEX CONCURRENTLY` instead of a plain create, adding a column without a volatile default, backfilling in bounded batches rather than one statement, and a `lock_timeout` so DDL that cannot take its lock fails fast instead of queueing and blocking every reader behind it. A migration that cannot be written this way is a signal to split it across two releases, not to book a maintenance window. **Deeper:** [interview-questions.md](./interview-questions.md#q2-migrations-are-expandcontract-and-run-as-an-argocd-presync-hook-walk-me-through-adding-a-non-nullable-column-to-the-110-million-row-check-in-table-without-downtime) — "Migrations are expand/contract and run as an ArgoCD PreSync hook. Walk me through adding a non-nullable column to the 110-million-row check-in table without downtime."

  </details>

- **OPTIONAL** — Running migrations as a pre-sync hook rather than from an application pod

## 10. Elasticsearch Index and Query Design

**Backs:** designed Elasticsearch indexes for clinical content search.

- **MUST** — Inverted index, analysers, tokenizers, filters; stemming, stopwords, synonyms, and why a clinical synonym set is domain work not engineering work

  <details><summary><strong>Answer</strong></summary>

  An inverted index maps each term to the documents containing it, which is why search cost scales with the number of matching terms rather than with corpus size. An analyzer is the pipeline that produces those terms — a character filter, a tokenizer, then token filters such as lowercasing, stemming, stopwords and synonyms — and the same analyzer must apply at index time and query time, or the two vocabularies never meet. Synonyms are the highest-leverage filter on clinical text, because a note carries a drug's brand name while the search uses the generic, and staging notation is written several ways. Curating that set is clinical work rather than engineering work — declaring two oncology terms equivalent is a clinical judgement with patient-safety consequences — so the design names an owner for it instead of assuming someone will maintain it. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-an-analyzer-and-what-work-does-the-clinical-synonym-filter-do-on-the-notes-index) — "What is an analyzer, and what work does the clinical synonym filter do on the notes index?"

  </details>

- **MUST** — Mappings: text vs keyword, multi-fields, dynamic mapping hazards, date types

  <details><summary><strong>Answer</strong></summary>

  `text` is analyzed and searchable by term; `keyword` is stored whole and is what you filter, sort and aggregate on — getting that backwards leaves you with a field you cannot match into or one you cannot filter exactly. A multi-field gives you both from one source, `body` as text alongside `body.raw` as keyword, which is the usual resolution. Dynamic mapping is the hazard: the first document to arrive fixes the type, so a numeric-looking string becomes a number and the next document fails to index — and you cannot change a mapping in place, you reindex behind an alias. So mappings here are explicit and versioned with the index, and date fields carry an explicit format rather than relying on detection.

  </details>

- **MUST** — Query DSL: filter context (cacheable, unscored) vs must (scored), bool composition, term vs match, highlighting

  <details><summary><strong>Answer</strong></summary>

  A `bool` query has four clause types and the split that matters is `must` versus `filter`: `must` contributes to the relevance score, `filter` does not, and because a filter clause is a yes-or-no decision it is cacheable per segment and reusable across queries. So scope, date ranges and type filters go in `filter` and only the user's text goes in `must`, which means the expensive scoring pass runs over a pre-filtered set rather than the whole index. `term` matches an indexed token exactly while `match` runs the query text through the analyzer first, which is why `term` against an analyzed field is the classic silent-empty-result bug. Highlighting is what makes a hit usable in a clinical UI and it costs a re-analysis of the matched documents, so it is requested for the page being shown rather than for the whole result set. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-the-difference-between-filter-and-must-context-in-an-elasticsearch-query-and-why-does-this-design-put-scope-and-date-clauses-in-filter) — "What is the difference between `filter` and `must` context in an Elasticsearch query, and why does this design put scope and date clauses in `filter`?"

  </details>

- **NICE** — Relevance: [BM25](https://en.wikipedia.org/wiki/Okapi_BM25 "Best Matching 25 — Ranking function that scores how relevant a document is to a search query") basics, boosting, why "relevance improved" needs an evaluation set, not an anecdote
- **MUST** — Shards, replicas, sizing, and why a small index makes a full rebuild routine

  <details><summary><strong>Answer</strong></summary>

  A shard is a Lucene index and the unit of distribution and parallelism; a replica is a copy that serves reads and provides failover. Over-sharding is the usual mistake, because every shard costs heap and every query fans out to all of them — at roughly 150 GB across three indices, three primaries with one replica each across three data nodes is proportionate rather than conservative. The property that matters more than sizing is that this index is derived: nothing originates in `es-clinical`, so it is fully rebuildable from `pg-clinical` and `mongo-content`. That is what turns "the cluster is gone" from a disaster procedure into a routine one — and it only stays true because the rebuild is rehearsed quarterly rather than assumed. **Deeper:** [interview-questions.md](./interview-questions.md#q3-es-clinical-is-lost-entirely--cluster-gone-snapshots-questionable-walk-me-through-the-recovery-and-explain-what-makes-this-routine-rather-than-a-disaster) — "`es-clinical` is lost entirely — cluster gone, snapshots questionable. Walk me through the recovery, and explain what makes this routine rather than a disaster."

  </details>

- **NICE** — Aliases and zero-downtime reindex; reindex as the rollback for a model change
- **MUST** — Bulk indexing: batch size, flush interval, refresh_interval vs the 1 s default, segment merge pressure, near-real-time semantics

  <details><summary><strong>Answer</strong></summary>

  Indexing one document per request wastes a round trip and a refresh cycle each time, so writes are batched — here a flush at 1000 documents or 5 seconds, whichever comes first. `refresh_interval` decides when new documents become visible to search: the 1 s default creates a segment every second and every segment is later merged, so raising it to 5 s roughly halves merge pressure at the cost of four more seconds of invisibility. That is the near-real-time part people state wrongly — Elasticsearch is not real-time, a document is searchable after a refresh, and `refresh=wait_for` on a write is a correctness tool for a test rather than a production pattern. Batch size is bounded by request size and by the bulk queue, so too large gives you rejections and heap pressure — which makes the bulk rejection rate a metric rather than an assumption.

  </details>

- **NICE** — Search authorization: mandatory scope filters carried in every document, and the rule that search must never become the path around the record layer
- **MUST** — The freshness budget composed of relay + flush + refresh, not one knob

  <details><summary><strong>Answer</strong></summary>

  The budget is the sum of three independent stages: the outbox relay picking up the committed row, the bulk flush window, and the index refresh interval — roughly 2 s plus 5 s plus 5 s, which is where p95 under 15 s comes from. Stating it as a composition rather than as a single number is what makes it actionable, because tightening one stage alone buys almost nothing: dropping `refresh_interval` to 1 s while the flush window is still 5 s moves the total by a second and doubles merge pressure. It also tells you where to look when freshness degrades, since outbox lag, consumer lag and refresh are three metrics with three different causes. If a note genuinely had to be searchable in under a second, the honest answer is that you change the path rather than the knobs and read that one document from `pg-clinical`. **Deeper:** [interview-questions.md](./interview-questions.md#q2-search-freshness-is-p95-under-fifteen-seconds-composed-of-three-parts-what-are-they-and-what-would-you-do-if-a-note-had-to-be-searchable-within-two-seconds) — "Search freshness is p95 under fifteen seconds, composed of three parts. What are they, and what would you do if a note had to be searchable within two seconds?"

  </details>

- **MUST** — When PostgreSQL full-text search is enough and when it is not

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL full-text search is genuinely capable and it removes an entire store from the design: `tsvector` with a GIN index, ranking, and no second system to keep consistent, rebuild, or secure. It is enough when the corpus is modest, the queries are mostly filters with a little text, and relevance is not something you intend to tune. It stops being enough exactly where this design sits — 2.4M notes with per-clause filtering, highlighting, custom analyzers carrying a clinical synonym set, and a latency target that is a stated number rather than a feeling. So the second store was bought against a measured target rather than a preference, and its price is on the books honestly: an index to keep consistent, a rebuild to rehearse, and a scope filter that must never be omitted. **Deeper:** [interview-questions.md](./interview-questions.md#q1-postgresql-has-full-text-search-built-in-why-does-this-platform-pay-for-a-second-store) — "PostgreSQL has full-text search built in. Why does this platform pay for a second store?"

  </details>


## 11. Messaging with RabbitMQ: AMQP and MQTT

**Backs:** event-driven services with [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications") and [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") for check-ins and reminders.

- **MUST** — AMQP 0-9-1 model: exchanges (direct/topic/fanout/headers), bindings, routing keys, queues, consumers; publisher confirms and transactions

  <details><summary><strong>Answer</strong></summary>

  In AMQP 0-9-1 a publisher never writes to a queue — it publishes to an exchange with a routing key, and bindings decide which queues get a copy. Direct matches the routing key exactly, fanout ignores it, topic matches wildcard patterns and headers matches on attributes; `care.events` is a topic exchange so a new consumer declares its own queue and binds a pattern, and the publisher never changes. Publisher confirms are the guarantee worth insisting on: without them a publish is fire-and-forget into a socket, and with them the broker acknowledges only once the message is safely handled — which on a quorum queue means replicated. AMQP transactions exist and are effectively unusable at throughput, so confirms are the mechanism in practice. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-the-difference-between-a-queue-and-a-topic-exchange-and-why-does-this-platform-publish-domain-events-to-a-rabbitmq-topic-exchange-rather-than-pushing-them-onto-a-queue-per-consumer) — "What is the difference between a queue and a topic exchange, and why does this platform publish domain events to a RabbitMQ topic exchange rather than pushing them onto a queue per consumer?"

  </details>

- **MUST** — Quorum queues vs classic mirrored queues (removed in RabbitMQ 4): raft replication, availability and the cost

  <details><summary><strong>Answer</strong></summary>

  A quorum queue replicates through Raft: a write is acknowledged once a majority of replicas hold it, and leadership fails over deterministically when a node is lost. Classic mirrored queues did something superficially similar with a mirroring model that could lose messages under partition and diverge on recovery, and they were removed in RabbitMQ 4 — so this is not a preference. The cost is real: replication means more disk and network per message, higher publish latency, and memory behaviour that punishes very long backlogs, so quorum queues suit work queues rather than vast buffers. Every `care.events` and Celery queue here is quorum, because the RPO 0 claim on an accepted check-in is only true if an acknowledgement means replicated. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-quorum-queue-and-why-does-this-design-mandate-them-for-careevents-and-every-celery-queue) — "What is a quorum queue, and why does this design mandate them for `care.events` and every Celery queue?"

  </details>

- **MUST** — Alternate exchanges: a [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")-1 publish that routes to no queue is still ACKed — the silent-loss trap the alternate exchange converts into a visible dead letter

  <details><summary><strong>Answer</strong></summary>

  A publish that matches no binding is discarded by the exchange, and — this is the trap — the publisher is still told it succeeded, because a confirm means the broker handled the message, not that anyone will receive it. On the check-in path that is precisely the failure the design exists to prevent: the device gets its acknowledgement for a QoS 1 publish, the app shows "recorded", and the check-in goes nowhere. An alternate exchange gives the exchange somewhere to route the otherwise-unroutable, so a typo'd binding or an unbound topic becomes a visible dead letter with a queue depth you can alert on. The general lesson is that a silent success is worse than a failure, and the fix is usually to give the unroutable case a destination rather than to trust that the topology is right. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-check-in-path-claims-a-recovery-point-objective-rpo-of-zero-from-the-moment-the-broker-acknowledges-three-rabbitmq-settings-carry-that-claim-and-none-of-them-is-a-default-what-are-they-and-what-breaks-without-each) — "The check-in path claims a Recovery Point Objective (RPO) of zero from the moment the broker acknowledges. Three RabbitMQ settings carry that claim and none of them is a default. What are they, and what breaks without each?"

  </details>

- **MUST** — Dead-letter exchanges, TTLs, delayed messages, poison-message handling

  <details><summary><strong>Answer</strong></summary>

  A dead-letter exchange is where a message goes when it is rejected without requeue, expires, or exceeds a length limit — so a poison message leaves the working queue instead of being redelivered forever and blocking everything behind it. Message and queue TTLs express "this is worthless if it is late", and a TTL-plus-dead-letter pair, or the delayed-message plugin, is how you get retry-after-delay without a worker spinning. Poison handling needs a bound: count deliveries and, after a small number, route to the dead-letter queue with the reason attached rather than retrying indefinitely. The half people skip is the other one — a dead-letter queue nobody monitors and nobody replays is a data-loss mechanism with extra steps.

  </details>

- **MUST** — Prefetch (QoS), consumer acknowledgement modes, redelivery

  <details><summary><strong>Answer</strong></summary>

  Prefetch, the AMQP QoS setting, caps how many unacknowledged messages a consumer may hold at once. Set it too high and one consumer hoards a batch while its peers idle, and a crash redelivers all of them; set it to one and you pay a round trip per message. With manual acknowledgement the consumer acknowledges after its work commits, so a crash mid-task means redelivery rather than loss — which is exactly why every handler has to be idempotent. Automatic acknowledgement acknowledges on delivery and is a data-loss setting dressed up as a throughput setting, so it belongs only on genuinely disposable messages.

  </details>

- **MUST** — MQTT: QoS 0/1/2 semantics, clean vs persistent sessions, client-side offline queueing, retained messages, last will, topic wildcards

  <details><summary><strong>Answer</strong></summary>

  QoS 0 is fire-and-forget, QoS 1 guarantees at least once with an acknowledgement and possible duplicates, and QoS 2 adds a four-packet handshake for exactly-once at a cost few applications need. QoS 1 is right for patient check-ins because the client keeps the message until it is acknowledged, so a phone in a lift or a basement holds the check-in and delivers it on reconnect — and the duplicates that come with it are absorbed by the unique key in the database. A persistent session, meaning a stable client id without a clean start, is what preserves that queue and the subscriptions across reconnects; a clean session throws both away. Last will and retained messages matter more for device telemetry than here, but it is worth knowing a retained message is delivered to every new subscriber, which is a quiet way to leak the last payload.

  </details>

- **MUST** — MQTT-to-AMQP bridging: topic separator translation, the target exchange setting, and per-connection (not per-publish) authentication with a token that expires mid-connection

  <details><summary><strong>Answer</strong></summary>

  The MQTT plugin translates an MQTT publish into an AMQP one, and three settings decide whether it lands where you think: the target exchange defaults to `amq.topic` and must be pointed at `care.events`, the topic separator `/` is translated to AMQP's `.` so `care/checkin/{patient_id}` binds as `care.checkin.{patient_id}`, and that exchange needs an alternate exchange because an unroutable QoS 1 publish is still acknowledged. The security seam is the second half: the plugin authenticates the connection rather than each publish, so a long-lived mobile connection outlives the token that opened it. The mitigation is a maximum connection lifetime shorter than the refresh window, forcing re-authentication, plus authorization of publishes to the topic matching the token's subject. The design flags this as something to prototype against real token lifetimes rather than assume, because it is the kind of gap that only appears at production session durations. **Deeper:** [interview-questions.md](./interview-questions.md#q2-rabbitmqs-mqtt-plugin-authenticates-per-connection-not-per-publish-what-is-the-security-gap-and-how-do-you-close-it) — "RabbitMQ's MQTT plugin authenticates per connection, not per publish. What is the security gap, and how do you close it?"

  </details>

- **MUST** — Delivery guarantees in plain terms: at-most-once, at-least-once, why exactly-once is a property of the consumer, not the broker

  <details><summary><strong>Answer</strong></summary>

  At-most-once means the broker never redelivers, so a crash loses the message; at-least-once means it redelivers anything it cannot prove was processed, so duplicates are normal rather than exceptional. Exactly-once across a broker and a database does not exist without a distributed transaction, and paying for one at this scale would be absurd — so what people call exactly-once is at-least-once delivery plus an idempotent consumer, and the guarantee lives on the consumer's side of the wire. That is why the guarantee here sits in the database: `(patient_id, recorded_for)` unique makes a redelivered check-in an update, and `reminder_delivery_id` makes a redelivered dispatch a no-op. The one place duplicates are accepted rather than removed is reminder delivery, where a patient seeing a reminder twice is a far better failure than not seeing it at all. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-at-least-once-delivery-mean-and-what-does-it-force-you-to-build-on-the-consumer-side) — "What does at-least-once delivery mean, and what does it force you to build on the consumer side?"

  </details>

- **NICE** — Ordering guarantees and when you actually need them

## 12. Celery and Scheduled Work

**Backs:** taking check-ins and reminders off the request path.

- **MUST** — Broker vs result backend; what a result backend is and is not for

  <details><summary><strong>Answer</strong></summary>

  The broker carries the work — it is the queue Celery publishes tasks to and workers consume from, `rmq-core` here. The result backend is a separate store holding a task's return value and state, `redis-cache` here, and it exists so someone can ask what happened to a task. The mistake is treating it as durable state: results carry a TTL, the backend is a cache, and a workflow that depends on reading them back has made a cache load-bearing. So anything that must survive lives in `pg-clinical` — the reminder state machine is rows in the database, and the result backend only ever answers a status query.

  </details>

- **MUST** — task_acks_late, visibility timeout, prefetch multiplier, worker concurrency models (prefork vs gevent vs threads)

  <details><summary><strong>Answer</strong></summary>

  `task_acks_late` acknowledges after the task completes rather than on delivery, so a worker that dies mid-task causes redelivery instead of loss — the setting you want for anything that matters, provided the task is idempotent. The prefetch multiplier decides how many tasks a worker reserves per concurrency slot; the default is tuned for many short tasks and is wrong for long ones, because reserved tasks sit idle behind a slow one and are all redelivered on a crash. The concurrency model follows the workload: prefork gives process isolation and real parallelism for CPU-bound work, while gevent or threads pack far more concurrent IO-bound tasks into a process — and the index and content tasks here are IO-bound. Visibility timeout is a Redis-broker concept rather than an AMQP one, and confusing the two is how people wait for a redelivery that is never coming.

  </details>

- **MUST** — Retries: backoff, jitter, max attempts, giving up into a dead-letter queue

  <details><summary><strong>Answer</strong></summary>

  A retry policy needs three bounds: backoff so a struggling dependency is not hammered, jitter so a fleet of workers does not retry in lockstep, and a maximum attempt count with somewhere to go afterwards. Which errors to retry is the part that actually matters — a timeout or a 503 is worth retrying, a validation error never is, and retrying a non-transient failure converts one error into a burst of them. After the cap the task goes to a dead-letter queue with its payload and the reason, because the alternative is a task that simply vanishes. And none of it is safe unless the task is idempotent, since a retry after a timeout that actually succeeded is exactly the case the policy cannot distinguish.

  </details>

- **MUST** — Idempotent task design; a task is a message that may run twice

  <details><summary><strong>Answer</strong></summary>

  A task is a message and a message may run twice — from an at-least-once redelivery, from a retry after a timeout that in fact succeeded, or from a duplicate publish. So a handler is written to reach the same end state on a second run: upsert on a natural key rather than insert, a state transition guarded by the current state rather than an unconditional update, and an external call carrying an idempotency key the provider honours. Where the effect genuinely cannot be made idempotent — sending a message to a person — I decide which failure is preferable and record the attempt either way. What I avoid is deduplicating by remembering task ids in a cache, because that makes a cache the correctness boundary, and it will be flushed.

  </details>

- **MUST** — Queue separation by workload so one flood cannot starve another

  <details><summary><strong>Answer</strong></summary>

  Separate queues exist so one workload cannot starve another: `celery.index`, `celery.content` and `celery.reminders` have different latency requirements, different failure modes and very different task durations. Without the split a reindex backlog of thousands of documents sits in front of the reminder sweep, and a clinical-safety task waits behind a bulk job — a priority inversion nobody chose. The split also lets workers be scaled and tuned per queue, so the content queue runs few long tasks while the index queue runs many short ones. The cost is more worker deployments and more queue-depth metrics to watch, which is cheap against the failure it prevents.

  </details>

- **MUST** — [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") beat as a singleton: leader election / RedBeat lock, last-tick liveness, and why the state machine belongs in the database so a stopped scheduler delays work rather than losing it

  <details><summary><strong>Answer</strong></summary>

  Celery beat is a scheduler, and a scheduler has to be a singleton or every tick fires once per replica. So it runs as a single-replica deployment holding a Redis-backed lock through RedBeat, which stops a restart or a slow-terminating pod from double-scheduling, with a liveness probe on last-tick age so a wedged scheduler is restarted rather than quietly silent. The blast radius of it stopping is bounded because the state machine lives in the database rather than in the scheduler: `reminder` rows stay `pending` and the next sweep catches up on everything due. That is the property worth stating plainly — reminders are delayed rather than lost, and `reminder_dispatch_lateness_seconds` alerts long before a patient notices. **Deeper:** [interview-questions.md](./interview-questions.md#q3-celery-beat-is-a-scheduler-singleton-what-is-the-blast-radius-if-it-stops-for-two-hours-and-what-would-you-change-if-reminders-had-a-sixty-second-delivery-guarantee) — "Celery beat is a scheduler singleton. What is the blast radius if it stops for two hours, and what would you change if reminders had a sixty-second delivery guarantee?"

  </details>

- **NICE** — Graceful shutdown, warm shutdown, preStop draining, long-task sizing
- **MUST** — Celery vs a raw AMQP consumer: work we schedule and retry for ourselves vs facts we publish for others — the boundary rule, stated once

  <details><summary><strong>Answer</strong></summary>

  Celery models work the platform schedules and retries for itself — it has an owner, a deadline, a retry policy and a queue, like a reminder sweep or a page generation. A topic exchange models a fact the platform publishes for whoever cares, where the publisher deliberately does not know its consumers. Collapsing them makes every consumer a Celery task, which couples independent services to one task registry and one serialization format, and means adding a consumer requires editing the publisher. Keeping both costs a boundary you have to explain once — which is why the design states it once in the communication-patterns table and then honours it, rather than re-deciding per feature. **Deeper:** [interview-questions.md](./interview-questions.md#q2-celery-and-raw-amqp-consumers-both-exist-in-this-design-where-is-the-boundary-and-what-goes-wrong-if-you-collapse-them-into-one) — "Celery and raw AMQP consumers both exist in this design. Where is the boundary, and what goes wrong if you collapse them into one?"

  </details>


## 13. Event-Driven Architecture and the Transactional Outbox

**Backs:** event-driven services; keeping the search index and integrations correct.

- **MUST** — The dual-write problem: commit succeeds, publish fails, nothing detects it

  <details><summary><strong>Answer</strong></summary>

  The dual-write problem is what happens when one operation has to change two systems: you commit the note to PostgreSQL, then publish to the broker, and the publish fails — or the process dies between the two. There is no ordering that fixes it: publish first and you can announce a transaction that then rolls back, commit first and you can lose the event. The worst part is that nothing detects it — the database is correct, the index is quietly missing a document, and no error was ever raised anywhere. That is the class of defect the outbox removes, and it is why `care-core` never writes to `es-clinical` directly.

  </details>

- **MUST** — Transactional outbox: event row in the same transaction, relay, published_at, the relay's only query and its index

  <details><summary><strong>Answer</strong></summary>

  The outbox collapses a dual write into a single transaction: the business change and an `outbox_event` row commit together, so either both happen or neither does. A relay then reads unpublished rows, publishes them to `care.events` and stamps `published_at` — and because a crash between publish and stamp republishes, delivery is at-least-once and consumers absorb the repeat. The relay's only query is "unpublished, oldest first", so it gets a partial index on `(occurred_at) WHERE published_at IS NULL`, which keeps the hot index the size of the backlog rather than of all history. The payoff beyond correctness is observability: unpublished age is a number, so a stalled pipeline shows up as `outbox_unpublished_age_seconds` rising rather than as a support ticket three weeks later.

  </details>

- **OPTIONAL** — Change data capture as the alternative and its operational cost
- **MUST** — At-least-once delivery and idempotent consumers: dedupe on event id, monotonic revision guards against out-of-order redelivery

  <details><summary><strong>Answer</strong></summary>

  Because the relay republishes on any uncertainty, consumers have to be idempotent, and the cheapest place to enforce that is the database rather than application memory — an upsert on a natural key, or the event id recorded in the same transaction as its effect. Out-of-order redelivery is the second problem and deduplication alone does not solve it, because an older version of a document can arrive after a newer one and overwrite it. The guard is a monotonic revision: carry a version or the source row's updated timestamp on the event and refuse to apply anything not newer than what is stored, which Elasticsearch supports directly through external versioning. That turns ordering from something you hope the broker preserved into something the consumer enforces.

  </details>

- **NICE** — Command vs event; choreography vs orchestration; saga and compensation
- **MUST** — Eventual consistency made observable: lag as a metric with an [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), backlog age alerts, and a reconciliation job as the backstop for a lost event

  <details><summary><strong>Answer</strong></summary>

  Eventual consistency is only acceptable when "eventually" is a number you measure rather than a word in a design document. Here the lag budget is p95 under 15 seconds, instrumented as `outbox_unpublished_age_seconds` plus consumer lag, and alerted on backlog *age* rather than error rate — because the failure mode is silence, not errors. Age is the right metric rather than depth: a queue of ten thousand draining quickly is healthy, and a queue of three stuck for a minute is not. And because any event stream can lose a message to a bug rather than a crash, there is a backstop — a nightly reconciliation comparing document counts per patient between `pg-clinical` and `es-clinical`, reindexing the divergent ones. Convergence you have not verified is a hope.

  </details>

- **NICE** — Read-your-writes routing for the party who just wrote
- **NICE** — Schema evolution of events; consumer-driven contracts

## 14. Caching with Redis

**Backs:** [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") in the stack for sessions, timelines, JWKS, rate limits.

- **MUST** — Cache-aside vs write-through vs write-behind, and choosing per data shape: write-through only for immutable versioned content

  <details><summary><strong>Answer</strong></summary>

  Cache-aside means the reader checks the cache, misses, loads from the source and populates it, so the cache never sits in the write path and a cache failure is a latency event rather than a correctness one. Write-through populates the cache as part of the write, which keeps it warm and consistent but couples the write path to the cache's availability. Write-behind acknowledges into the cache and persists later, buying latency at the cost of a durability hole — not a trade a clinical record can make. The rule here follows data shape: cache-aside by default, and write-through only for rendered content pages, because a published version is immutable so there is no invalidation left to get wrong.

  </details>

- **MUST** — Invalidation: event-driven purge with TTL as the backstop, version-suffixed keys that make a stale key unreachable

  <details><summary><strong>Answer</strong></summary>

  There are two ways to stop serving a cached value: delete it, or make its key unreachable. Event-driven purge is the mechanism for mutable data — the `care.events` consumer deletes `tl:{patient_id}:*` on any record write for that patient — and the TTL is the backstop that bounds how wrong you can be when a purge is missed, 60 seconds here. Version-suffixed keys are the better trick where they apply: `page:{page_id}:{version}:{locale}` never needs purging, because a new version writes a new key and the old one ages out unreferenced. The framing I use is that the TTL bounds the damage and the event provides the correctness — a design relying on TTL alone has chosen a staleness window rather than an invalidation strategy.

  </details>

- **NICE** — Stampede protection: single-flight locks, probabilistic early expiry, stale-while-revalidate
- **NICE** — Hit ratio arithmetic: what the origin load becomes when the cache is empty
- **MUST** — Key design and namespacing; patient-scoped keys, and the rule that nothing identifiable is cached at a layer blind to the requester (why the gateway response cache is off by policy)

  <details><summary><strong>Answer</strong></summary>

  A cache key must contain everything the value depends on, and when the value is scoped to a person, that includes who is asking. That is why timeline keys are `tl:{patient_id}:{window_hash}` — patient-scoped and parameter-scoped — rather than keyed on the query alone. The same rule is why APIM response caching is disabled on every `/api/v1` path by policy rather than by omission: a gateway cache keys on a URL that does not name the subject, so it is a cross-patient disclosure waiting for a cache hit. Stated generally, nothing patient-identifiable is cached at a layer blind to the requester, and that is enforced where the cache lives rather than in a review checklist.

  </details>

- **MUST** — TTL strategy, eviction policies, memory sizing, hot keys

  <details><summary><strong>Answer</strong></summary>

  A TTL is chosen from how wrong you can afford to be, not from how long the value is likely to remain accurate — 60 seconds on a timeline, 12 hours on JWKS because the long TTL *is* the outage mitigation, 24 hours on an immutable rendered page. Eviction policy is a separate decision: `allkeys-lru` is right for a pure cache, while `noeviction` turns a full instance into write errors and is only correct where the data cannot be reconstructed. Memory is sized against the working set rather than the whole keyspace, and the numbers to watch are hit rate together with evicted keys, because rising evictions mean the TTLs and the memory disagree. Hot keys survive all of that: one key hit thousands of times a second saturates a single node however many you run, and the answers are a short-lived in-process cache in front of it or splitting the key.

  </details>

- **OPTIONAL** — Redis data structures and atomicity; Lua scripts; SETNX locks and the honest limits of distributed locking
- **MUST** — Redis as a cache, never a store; what a flush is allowed to cost

  <details><summary><strong>Answer</strong></summary>

  Redis holds sessions, JWKS, rendered pages, rate-limit buckets, idempotency keys and Celery results here — and nothing that could not be rebuilt from another store. The test I apply is blunt: if the instance were flushed right now, what breaks? Here, latency rises to cold-path figures, some users re-authenticate, and one duplicate mutation may get through — and that last one is exactly why the real idempotency guarantee is a natural key in PostgreSQL rather than the `idem:` keys. Nothing else is lost, and keeping it that way is a constraint rather than a description: the moment something durable lives in Redis, its backup and failover story becomes the platform's problem.

  </details>

- **MUST** — Audit obligations that survive a cache hit

  <details><summary><strong>Answer</strong></summary>

  A cache hit is still an access, so serving a timeline from Redis writes the same `audit_event` row as serving it from PostgreSQL — caching reduces read cost, never audit coverage. It follows that an audited read is a write, which is why patient-facing reads are served by the primary rather than a replica, and why read availability ends up coupled to write availability. That coupling is a real cost and the design names it rather than glossing it: during a failover reads return `503` instead of being served from cache, because a cached read could not be audited. The alternative, queueing audit rows asynchronously, would keep reads up at the price of an audit trail with a hole in it — and for a health record the hole is the worse outcome.

  </details>


## 15. Transfer Learning and Fine-Tuning Hugging Face Models

**Backs:** fine-tuned Hugging Face models with transfer learning, +28% relevance.

- **MUST** — Transfer learning: pretrained encoder, task head, full fine-tune vs frozen layers vs parameter-efficient methods (LoRA/adapters) and when each is right

  <details><summary><strong>Answer</strong></summary>

  Transfer learning reuses a model that has already learned general language structure from a large corpus and adapts it to your task, so you need thousands of labelled examples rather than millions. A full fine-tune updates every weight and adapts most, at the cost of compute and of catastrophic forgetting on a small corpus; freezing the encoder and training only a task head is cheap and safe but limited when the domain vocabulary diverges sharply from the pretraining data, which oncology notes do; parameter-efficient methods such as LoRA or adapters train a small set of added parameters, get most of the benefit for a fraction of the memory, and make per-version rollback trivial because the base model is untouched. For a clinical corpus of the size realistically available here I would start parameter-efficient and justify a full fine-tune only with an evaluation that shows the difference. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-transfer-learning-and-why-fine-tune-a-hugging-face-model-here-rather-than-prompting-a-large-general-purpose-model) — "What is transfer learning, and why fine-tune a Hugging Face model here rather than prompting a large general-purpose model?"

  </details>

- **MUST** — The task shapes used here: token classification for clinical entity/code extraction, and cross-encoder reranking for retrieval

  <details><summary><strong>Answer</strong></summary>

  Two tasks, and they are different shapes. Entity and code extraction from visit notes is token classification — the model labels each token with an entity type, which is what enriches `es-clinical-notes` with structured entities and codes to filter on. Passage reranking is a cross-encoder: query and candidate passage go through the model together and it scores their relevance, which is more accurate than comparing separately-computed embeddings because the two texts attend to each other, and far too slow to run over a whole corpus — so it reranks the top candidates a cheaper retriever returned. Naming the task shape matters because it determines the labelled data you need, the metric you evaluate against, and where the model can sit in the pipeline at all.

  </details>

- **MUST** — Tokenizers, subword vocabularies, max sequence length, chunking long notes

  <details><summary><strong>Answer</strong></summary>

  A subword tokenizer splits text into pieces from a fixed vocabulary, so an unseen word degrades into pieces rather than an unknown token — which matters on clinical text, where drug names and staging notation are precisely the words a general vocabulary never saw. That has a cost: domain terms fragment into many tokens, so clinical prose consumes more of the sequence budget than ordinary prose does. Models have a maximum sequence length and a visit note frequently exceeds it, so notes are chunked with overlap, because an entity straddling a boundary is otherwise lost, and boundaries are drawn at sentences rather than mid-word. The consequence worth stating is that chunking changes what the model can see, so an entity whose meaning depends on context two paragraphs earlier is not recovered by a larger GPU.

  </details>

- **MUST** — Training mechanics: learning rate and schedule, batch size, early stopping, class imbalance, overfitting on a small clinical corpus

  <details><summary><strong>Answer</strong></summary>

  On a small domain corpus the parameters that matter most are learning rate and schedule: too high erases the pretrained representation, which is why fine-tuning uses a far smaller rate than pretraining, usually with warmup and decay. Batch size interacts with it and is bounded by GPU memory, so gradient accumulation stands in for a larger batch. Early stopping on a validation metric, plus few epochs, is what actually protects against overfitting a few thousand clinical notes. Class imbalance is the specific trap in clinical extraction — the rare entity types are the clinically interesting ones, and a model that never predicts them still scores well on accuracy — so the loss is weighted or the sampling adjusted, and the metric is reported per class rather than aggregated.

  </details>

- **MUST** — Evaluation that means something: held-out set, precision/recall/F1 per entity type, NDCG/MRR for reranking, a baseline to beat, statistical noise

  <details><summary><strong>Answer</strong></summary>

  An evaluation only means something against a held-out set the model never saw, split so no note from a training patient appears in test: patient-level splitting, not row-level, or you are measuring memorisation. For extraction the metric is precision, recall and F1 per entity type rather than overall, because an aggregate hides exactly the rare classes that matter; for reranking it is NDCG or MRR at a cut-off matching how many passages are actually consumed. Every number needs a baseline to beat — the previous model version, and a non-model baseline such as BM25 alone — or it says nothing. And a difference measured on a few hundred examples is noise until you show otherwise, so a confidence interval or a significance test is what separates a real gain from a favourable split. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-cv-claims-a-28-relevance-improvement-where-does-it-come-from-and-how-would-you-evaluate-it-honestly) — "The [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") claims a 28% relevance improvement. Where does it come from, and how would you evaluate it honestly?"

  </details>

- **MUST** — Model versioning: stamping the version on every artifact so a regression is attributable and a rollback is a reindex

  <details><summary><strong>Answer</strong></summary>

  Every artifact the pipeline produces carries the model version that produced it — `nlp_extractions` stamps `model_version`, and `content_pages` records model and prompt version under `generated_by`. That is what makes a regression attributable: when quality drops you can tell which artifacts came from which version instead of comparing two undifferentiated pools of output. It is also what makes rollback tractable, because those artifacts are derived and rebuildable — reverting a model version is a reindex rather than a migration, since nothing in `nlp_extractions` exists that cannot be recomputed from the source note. The discipline the whole thing rests on is that the derived store never becomes the only copy of anything. **Deeper:** [interview-questions.md](./interview-questions.md#q3-a-new-model-version-ships-and-quality-regresses-how-do-you-notice-before-every-patient-sees-it-and-how-do-you-get-back) — "A new model version ships and quality regresses. How do you notice before every patient sees it, and how do you get back?"

  </details>

- **OPTIONAL** — Serving: GPU vs CPU inference, batching, latency budgets, model warm-up, quantisation, ONNX/TorchScript
- **MUST** — Governance of training data: patient text in a corpus, de-identification, memorisation and extraction risk, lawful basis before the first tuning run

  <details><summary><strong>Answer</strong></summary>

  Fine-tuning on real visit notes puts patient text into a training corpus, which is a new processing purpose rather than a technical detail — so it needs a lawful basis consistent with the consent the patient actually gave, and a DPIA completed before the first run rather than after it. De-identification is necessary and not sufficient: clinical free text re-identifies through combinations of rare diagnosis, date and location that no scrubber catches reliably. The risk people underweight is memorisation — a fine-tuned model can reproduce training text under the right prompt, so the weights themselves become personal data and inherit the residency and access constraints of the corpus they came from. My position is that this is settled with the data controller before any tuning run, and until it is, the pipeline draws on approved published guidance rather than patient notes. **Deeper:** [interview-questions.md](./interview-questions.md#q2-fine-tuning-on-real-visit-notes-means-patient-text-in-a-training-corpus-what-has-to-be-resolved-before-the-first-tuning-run) — "Fine-tuning on real visit notes means patient text in a training corpus. What has to be resolved before the first tuning run?"

  </details>


## 16. Retrieval Pipelines and LangChain Composition

**Backs:** LangChain workflows turning diagnosis and treatment context into education pages.

- **MUST** — RAG anatomy: chunking, retrieval, reranking, composition, citation assembly

  <details><summary><strong>Answer</strong></summary>

  Retrieval-augmented generation is a pipeline of five stages and the failures are stage-specific. Chunking decides what a retrievable unit is and gets the least attention for the most damage — a chunk that separates a clinical qualifier from its claim retrieves as a true statement that is not one. Retrieval selects candidates, reranking reorders them with a more expensive and more accurate model, composition writes from what survived, and citation assembly records which passage each block came from. The property worth stating out loud is that the generator can only be as good as what retrieval handed it, so most of the quality work sits upstream of the model that writes the words.

  </details>

- **MUST** — Retrieval methods: lexical (BM25) vs dense embeddings vs hybrid; why the retriever, not the generator, decides quality

  <details><summary><strong>Answer</strong></summary>

  Lexical retrieval such as BM25 matches terms and is strongest exactly where the vocabulary is exact and rare — a drug name, a staging code — which is much of clinical text. Dense embedding retrieval matches meaning and finds a passage that says the same thing in different words, which lexical search misses entirely. Hybrid runs both and fuses the rankings, and it is usually the right default because the two failure modes are complementary. The line I would hold in an interview is that the retriever rather than the generator decides quality: a fluent model handed the wrong three passages produces a confident wrong answer, and no amount of prompt engineering recovers a passage that was never retrieved.

  </details>

- **MUST** — Grounding and provenance: composing only from approved passages, a citation per block, and refusing to author claims — a safety property, not a style

  <details><summary><strong>Answer</strong></summary>

  Composition draws only from `guidance_sources` passages a clinician has approved, and every block in a generated page carries a citation to the passage it came from. That is enforced structurally rather than by instruction — retrieval is restricted to the approved corpus, each block is emitted with its source and passage id, and a block without a citation is a validation failure rather than a stylistic lapse — and beyond that a human reviewer approves the page before `review_state` permits it to be assigned. The cost is measurable and accepted: a freely generating model would write more fluent and more specific pages, and this constraint narrows what a page can say. That narrowing is the intended outcome, because an unsourced sentence in cancer guidance is a patient-safety defect rather than a quality regression. **Deeper:** [interview-questions.md](./interview-questions.md#q2-composition-draws-only-from-approved-passages-and-each-block-carries-a-citation-how-is-that-actually-enforced-and-what-does-it-cost) — "Composition draws only from approved passages, and each block carries a citation. How is that actually enforced, and what does it cost?"

  </details>

- **MUST** — Hallucination: what causes it and which controls actually reduce it

  <details><summary><strong>Answer</strong></summary>

  A language model is trained to produce likely continuations rather than true ones, so it has no internal notion of not knowing — when retrieval returns nothing useful, fluent invention is the default behaviour rather than an anomaly. The controls that measurably help all concern what the model is given and what it may emit: restricting it to retrieved passages, requiring a citation per claim so an uncited sentence is mechanically detectable, and abstaining when retrieval confidence is low instead of composing from weak material. The controls that help least are prompt instructions telling it to be accurate, and the model's own confidence score. In this design the final control is not technical at all — a clinician approves the page before any patient sees it — which is the honest answer in a clinical setting.

  </details>

- **NICE** — Prompt versioning and prompt/response logging with sensitive-data rules
- **MUST** — Evaluation of a generation pipeline: golden sets, human review, regression tests on prompt or model change

  <details><summary><strong>Answer</strong></summary>

  A generation pipeline needs a golden set: representative inputs with an agreed acceptable output, versioned alongside the code, so a prompt or model change becomes a regression test rather than a vibe check. What can be automated is retrieval quality — did the right passages come back, measured as recall at k and NDCG — plus mechanical checks that every block carries a citation and every citation resolves to a currently-approved passage. What cannot be automated is whether the page is clinically appropriate, so human review is part of the evaluation and not only part of the runtime. Prompt version and model version are stamped on every artifact, so a quality change is traced to a change rather than argued about.

  </details>

- **NICE** — Human-in-the-loop review states (draft → pending_review → approved → retired) and pinning an exact version to what a patient was shown
- **MUST** — Cost, latency, and why generation belongs off the request path

  <details><summary><strong>Answer</strong></summary>

  Retrieval, a cross-encoder reranking pass and citation assembly take seconds rather than milliseconds, and a GPU is billed by the second whether it is reranking or idle. Two things follow. The pipeline stays off the request path entirely — a generation request returns `202` with a status URL and the work runs on `celery.content` — so nobody waits and the pipeline can afford the reranking pass that makes the output specific. And nothing on a user's synchronous path depends on `aks-ml`, which is why a GPU cluster outage pauses new generation while already-approved assigned pages serve normally. The price is that a newly requested page is not instantly available, which is the right trade when the alternative is trimming the pipeline to fit a request timeout.

  </details>

- **NICE** — LangChain specifically: what it gives you (composition, retrievers, output parsing) and where hand-written glue is clearer

## 17. Azure Platform Services in This Design

**Backs:** migrated file ingestion and async notifications to Blob, Service Bus and Event Grid; Azure in the environment list.

- **MUST** — Blob Storage: containers, access tiers and lifecycle, [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") (user-delegation vs account key), direct client upload and why it keeps bytes off API pods, immutability/[WORM](https://en.wikipedia.org/wiki/Write_once_read_many "Write Once Read Many — Storage mode that prevents a written object from being modified or deleted before a retention period ends") policies and legal hold, soft delete, [ZRS](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy "Zone Redundant Storage — Replicates Azure storage data synchronously across multiple availability zones")/GRS

  <details><summary><strong>Answer</strong></summary>

  Blob Storage is containers of objects with access tiers — hot, cool, archive — moved by lifecycle rules, which is how documents here go hot for 90 days, then cool, then archive. A SAS is a time-limited signed URL granting scoped access, and a user-delegation SAS signed with Entra credentials beats an account-key SAS because it is attributable to an identity and revocable without rotating the storage key. Direct client upload with a SAS is what keeps multi-megabyte scans off the API pods entirely — bytes go client to storage and `care-core` only writes metadata — and the upload lands in `ingest-quarantine` so an unscanned file is never addressable by a `document` row. An immutability policy with a legal hold is what makes the audit archive genuinely append-only for its seven years, while soft delete and zone-redundant replication cover the operational failures rather than the regulatory ones. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-document-ingestion-path-goes-blob-storage-to-event-grid-to-an-azure-function-to-service-bus-why-does-an-upload-land-in-a-quarantine-container-first-and-what-does-that-buy) — "The document ingestion path goes Blob Storage to Event Grid to an Azure Function to Service Bus. Why does an upload land in a quarantine container first, and what does that buy?"

  </details>

- **MUST** — Event Grid: BlobCreated eventing, delivery retries, dead-lettering, and the at-least-once semantics its consumers must tolerate

  <details><summary><strong>Answer</strong></summary>

  Event Grid is a push-based event router: `BlobCreated` fires when an upload completes and it delivers to a subscriber such as `fn-blob-ingest`, with retries and exponential backoff and a dead-letter destination for what it eventually cannot deliver. Delivery is at-least-once and ordering is not guaranteed, so the handler has to be idempotent — the same blob can be announced twice and processing it twice must not produce two document rows. The other property to plan for is that the event carries a reference rather than the data, so the handler reads the blob itself and must tolerate it having changed or been removed since. Configuring the dead-letter destination is the step people skip, and without it a permanently failing event is discarded silently once the retry window closes.

  </details>

- **MUST** — Service Bus: queues vs topics/subscriptions, peek-lock vs receive-and-delete, lock renewal, dead-letter queues and replay, duplicate detection, sessions for ordering, scheduled messages

  <details><summary><strong>Answer</strong></summary>

  A queue is point-to-point; a topic with subscriptions is publish-subscribe with per-subscriber filters. Peek-lock is the mode to use: the message is invisible while locked, the consumer completes it on success or abandons it to make it immediately available again, and lock renewal is required for anything slower than the lock duration — receive-and-delete drops the message on delivery and is a data-loss mode. Dead-lettering happens on delivery-count exhaustion or explicit rejection, and the dead-letter queue is a real queue you can inspect and replay, which is its operational virtue here. Duplicate detection deduplicates by message id within a window and sessions give FIFO within a session key; both are useful, and both are unnecessary when the consumer is idempotent, which is the cheaper design.

  </details>

- **MUST** — Azure Functions: triggers and bindings, consumption vs premium plans, cold start, concurrency and scale controllers, idempotent handlers, slot swap

  <details><summary><strong>Answer</strong></summary>

  A Function is a handler bound to a trigger, with input and output bindings that remove most of the client boilerplate — an Event Grid trigger for blob ingestion and a Service Bus trigger for notification dispatch here. The consumption plan scales to zero and bills per execution, which suits bursty upload traffic and pays for it in cold starts; a premium plan keeps instances warm and gives VNet integration, which matters when every store is behind a private endpoint. The scale controller adds instances from queue depth, so concurrency is elastic in a way that will happily overwhelm a downstream database unless it is capped. Triggers are at-least-once, so handlers are idempotent — `fn-notify-dispatch` keys on `reminder_delivery_id` rather than trusting single delivery — and deployment is a slot swap, so a bad version is reversible without a rebuild.

  </details>

- **MUST** — API Management: JWT validation policy, audience routing, rate limits and quotas, versioning, and its JWKS cache being independent of yours

  <details><summary><strong>Answer</strong></summary>

  APIM is the north-south gateway and it does four things here: validates the JWT against cached JWKS, enforces the audience matching the route's plane, applies coarse rate limits and quotas, and routes by API version. The property that matters is that it rejects a clinician token on a patient route before application code runs, which makes the identity-plane separation structural rather than conventional. Its JWKS cache is independent of the one in `redis-cache`, which is worth knowing during a key rotation or an Entra ID outage — the two can disagree, and the service revalidating rather than trusting the gateway is what stops that becoming an authentication gap. The honest cost is that APIM is a genuine single point of failure for north-south traffic, accepted deliberately because a second ingress carrying its own copy of the authentication policy is the worse risk. **Deeper:** [interview-questions.md](./interview-questions.md#q3-the-design-calls-apim-a-genuine-single-point-of-failure-for-north-south-traffic-and-accepts-it-defend-that-then-argue-against-it) — "The design calls APIM a genuine single point of failure for north-south traffic and accepts it. Defend that, then argue against it."

  </details>

- **NICE** — Entra ID and Entra External ID as two tenants/two planes
- **MUST** — Workload identity federation: no static credentials in images or manifests

  <details><summary><strong>Answer</strong></summary>

  Workload identity federation lets a pod present its Kubernetes service account token to Entra ID and exchange it for an Azure token, so no client secret or certificate ever exists in an image, a manifest or a CI variable. That removes the entire class of incident where a credential is committed, logged or left in an image layer, and it removes credential rotation as an operational task because the tokens are short-lived by construction. What replaces it is a trust configuration — the federated credential binds a specific namespace and service account to a specific identity — so the thing to review is that binding rather than a secret. Secrets that genuinely must exist, such as the database password and the blind-index key, live in Key Vault and are projected as files rather than baked into environment variables.

  </details>

- **NICE** — Key Vault: secrets vs keys vs certificates, [CMK](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys "Customer Managed Key — An encryption key the customer controls rather than the cloud provider"), soft-delete and purge protection, rotation, projection as files rather than environment variables
- **OPTIONAL** — Choosing between an Azure-native and a self-hosted equivalent, and the cost of running two brokers rather than one

## 18. Kubernetes, OpenShift and GitOps Delivery

**Backs:** deployed releases with [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") to OpenShift and [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications").

- **MUST** — Core objects: Deployment, ReplicaSet, Service, Ingress/Route, ConfigMap, Secret, Job/CronJob, StatefulSet

  <details><summary><strong>Answer</strong></summary>

  A Deployment declares desired state for a stateless workload and manages ReplicaSets to reach it, which is what makes a rollout and a rollback the same mechanism. A Service gives a stable virtual IP and DNS name across pod churn, and an Ingress — a Route on OpenShift — publishes it outside the cluster. ConfigMaps and Secrets separate configuration from image so one digest runs in every environment, with Secrets being base64-encoded rather than encrypted, which is exactly why the real ones come from Key Vault. Jobs and CronJobs run work to completion, and StatefulSets exist for workloads needing stable network identity and per-pod storage — which is why `rmq-core` and `es-clinical` are StatefulSets while `care-core` is a Deployment.

  </details>

- **MUST** — Probes: liveness vs readiness vs startup, and the outage a wrong liveness probe causes

  <details><summary><strong>Answer</strong></summary>

  Readiness decides whether a pod receives traffic and liveness decides whether it is restarted, and confusing them causes outages rather than preventing them: a liveness probe that fails under load restarts a pod that was merely busy, sheds its in-flight requests onto equally busy peers, and cascades. So a liveness probe should detect that the process is wedged, never that its dependencies are unhealthy — a liveness check that queries `pg-clinical` restarts every pod in the cluster during a failover. Readiness is where dependency checks belong, because a pod that cannot reach its database should stop taking traffic and resume when it can, without being killed. A startup probe covers slow initialisation so the liveness timer does not fire during a legitimately long start, which matters for anything loading a model.

  </details>

- **MUST** — Requests and limits, QoS classes, OOMKill, CPU throttling

  <details><summary><strong>Answer</strong></summary>

  A request is what the scheduler reserves; a limit is what the runtime enforces — and exceeding them behaves very differently. Memory over the limit is an immediate OOMKill, while CPU over the limit is throttling: the process is not killed, it is quietly slowed, which surfaces as latency with no error anywhere in the logs. QoS class follows from the pair — requests equal to limits gives Guaranteed, requests below limits gives Burstable, neither gives BestEffort, which is evicted first under node pressure. For latency-sensitive services I set the memory request equal to the limit so the pod is never evicted for memory, and I am cautious with tight CPU limits, because throttling looks exactly like a slow dependency in a trace.

  </details>

- **MUST** — Rollout strategies: rolling, blue-green (a Route switch), canary, and which service earns which — model quality shows up statistically, so canary

  <details><summary><strong>Answer</strong></summary>

  A rolling update replaces pods gradually and suits an external, idempotent caller, which is `scim-provisioning-svc`. Blue-green stands the new version up in full and switches traffic at once — a single Route switch here — so cut-over is instantaneous and rollback is switching back, the cleanest guarantee for the service holding the record. Canary sends a small percentage to the new version and increases it while comparing metrics, and it is the only one of the three that catches a statistical regression: model quality does not fail loudly, it shifts a distribution, so `clinical-nlp-svc` goes 5% to 25% to 100% with confidence and latency compared at each step. Using one strategy everywhere would either forfeit that comparison or pay for a full duplicate GPU fleet, so the differences are chosen rather than accidental. **Deeper:** [interview-questions.md](./interview-questions.md#q1-three-services-use-three-deployment-strategies--blue-green-canary-and-rolling-why-not-one) — "Three services use three deployment strategies — blue-green, canary, and rolling. Why not one?"

  </details>

- **NICE** — Graceful termination: preStop, terminationGracePeriodSeconds, draining workers vs killing them
- **NICE** — Autoscaling: [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on CPU and on custom/queue-depth metrics, cluster autoscaler
- **NICE** — NetworkPolicy default-deny and what it cannot see (cross-cluster hops)
- **MUST** — OpenShift specifics: SCCs, Routes, image streams, and how they differ from vanilla Kubernetes

  <details><summary><strong>Answer</strong></summary>

  Security Context Constraints are OpenShift's admission-level policy on what a pod may do — run as root, mount host paths, hold capabilities — and the default restricted SCC assigns an arbitrary non-root UID, which is why images assuming UID 0 or a fixed user fail on OpenShift and run fine on vanilla Kubernetes. Routes predate and differ from Ingress, with their own TLS termination modes, and a Route is what the blue-green switch flips here. Image streams add indirection over registry tags with triggers on change, which is useful in an OpenShift-native flow and mostly bypassed here, because ArgoCD deploys digest-pinned images from the GitLab registry instead. The general point is that OpenShift is Kubernetes with policy switched on by default, and most porting pain is that policy doing its job.

  </details>

- **MUST** — GitOps with ArgoCD: declared desired state, sync waves, pre/post-sync hooks, drift detection, rollback as a revision revert, and why no [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") job holds cluster credentials

  <details><summary><strong>Answer</strong></summary>

  GitOps makes a Git repository the single declared desired state and puts a controller inside the cluster that continuously reconciles reality to it — so a deploy is a commit, drift is detected and corrected, and a rollback is reverting a revision rather than running a different procedure. The pull model is what removes cluster credentials from CI: the pipeline's final act is a commit to the manifest repository, and ArgoCD, running in the cluster, pulls from there. That matters because a compromised CI job is then limited to proposing a reviewable, revertible change instead of holding a credential with cluster-admin reach over production. Sync waves order what must go first, and the PreSync hook is where `alembic upgrade head` runs so the schema is ahead of the pods that need it. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-gitops-and-what-does-no-pipeline-job-holds-cluster-credentials-actually-buy) — "What is GitOps, and what does 'no pipeline job holds cluster credentials' actually buy?"

  </details>

- **NICE** — Digest-pinned images so a mutable tag cannot be swapped under a cluster
- **NICE** — Multi-cluster topology cost, and the rule that nothing on the request path lives on the second cluster

## 19. CI/CD and Quality Gates

**Backs:** GitLab CI with ruff, pyright and SonarQube gates; fixing failing jobs.

- **MUST** — Pipeline structure: stages, jobs, artifacts, caches, services containers, parallelism, needs/DAG

  <details><summary><strong>Answer</strong></summary>

  A pipeline is stages of jobs, where jobs within a stage run in parallel and artifacts carry declared outputs forward — and `needs` turns the sequence into a DAG so a job starts as soon as its own dependencies finish rather than waiting for a whole stage. Caches and artifacts are different things and confusing them costs correctness: a cache is a best-effort speed-up that may be absent, an artifact is a declared output the next job depends on. Service containers are how integration tests get a real PostgreSQL, Elasticsearch and RabbitMQ instead of mocks. The structural rule I hold is that the fast cheap gates run first — lint and types before a twenty-minute integration suite — so a trivial mistake fails in a minute rather than half an hour.

  </details>

- **MUST** — A gate is only a gate if it can fail: proving each one blocks by making it fail on purpose

  <details><summary><strong>Answer</strong></summary>

  A gate that has never failed has not been shown to do anything, so I prove each one by making it fail on purpose: introduce a lint error, an untyped value, a failing contract test, a deliberately vulnerable dependency, and confirm the pipeline goes red at that stage rather than sailing through. That catches the failures which are otherwise invisible — a step whose exit status is swallowed by a pipe, a tool that prints findings and returns zero, a job left as allow-failure, a suite that silently collected no tests. Three outcomes, never two: pass, fail and could-not-run, because a job that errored before reaching its assertion is not a pass. And the invocation has to match the real one exactly, because a tool run against one file can behave differently from the same tool run across a directory.

  </details>

- **MUST** — ruff: lint and format, rule selection, per-file ignores, autofix in CI vs locally

  <details><summary><strong>Answer</strong></summary>

  `ruff` is a linter and formatter fast enough to run on save, and most of its value is in rule selection: the defaults handle style, and the rules worth enabling are the ones that find bugs — mutable default arguments, shadowed builtins, bare excepts, unused arguments, and the security and comprehension sets. Per-file ignores exist for genuine exceptions such as a generated module or an `__init__` re-export, and they belong in configuration with a reason rather than scattered as inline comments. Autofix belongs locally rather than in CI, because a CI job that rewrites code is committing on the author's behalf; in the pipeline it runs in check mode and fails. The point of the gate is not tidiness — it is that a reviewer's attention should go to logic instead of formatting. **Deeper:** [interview-questions.md](./interview-questions.md#q1-ruff-a-strict-type-checker-sonarqube-and-trivy-all-gate-the-pipeline-what-does-each-catch-that-the-others-do-not) — "`ruff`, a strict type checker, SonarQube, and Trivy all gate the pipeline. What does each catch that the others do not?"

  </details>

- **MUST** — pyright/mypy in strict mode: gradual typing, Any leakage, third-party stubs, what strict actually forbids

  <details><summary><strong>Answer</strong></summary>

  Strict mode forbids the ways typing quietly stops meaning anything: implicit `Any` on parameters and returns, unchecked bodies of untyped functions, unknown member types, and unnecessary casts. The subtle problem is `Any` leakage — one untyped third-party call returns `Any`, and everything derived from it is unchecked, so a large part of a nominally typed codebase can be effectively untyped without a single reported error. That is why third-party stubs matter and why an untyped dependency gets a thin typed adapter rather than being used directly. On this codebase the payoff is concrete: SQLAlchemy 2's `Mapped[]` annotations make a wrong column type or a non-existent relationship a type error rather than a runtime disclosure on a clinical record.

  </details>

- **MUST** — SonarQube: quality gate on new code, coverage thresholds, hotspots, and how a gate becomes theatre if it is bypassed

  <details><summary><strong>Answer</strong></summary>

  SonarQube's useful setting is a quality gate on *new* code rather than on the whole codebase: every change has to meet the standard without demanding a rewrite of history, so debt is paid down as files are touched. Coverage thresholds sit in that gate alongside duplication and security hotspots, which are flagged for review rather than failed automatically. The failure mode is theatre and it arrives in specific ways — the gate is advisory, or the job is allow-failure, or exclusions have grown until the interesting code sits outside the measurement, or coverage is met by tests that execute lines and assert nothing. So what I check is not the number but whether the gate has ever actually blocked a merge, and what has been excluded from it. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-a-test-coverage-number-actually-tell-you-and-what-does-it-not) — "What does a test coverage number actually tell you, and what does it not?"

  </details>

- **MUST** — Test layering: unit, contract (OpenAPI), integration against real containers, functional; why a mocked broker cannot fail the way a real one does

  <details><summary><strong>Answer</strong></summary>

  Unit tests check a decision in isolation and are where edge cases belong, because they are fast enough to run hundreds of them per change. Contract tests check the boundary — that the OpenAPI document the service emits still matches what clients generate from — and they are the only layer that catches a breaking change to a published schema. Integration tests check the assumptions the other layers had to mock away, and here they run against real PostgreSQL, [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), Elasticsearch, Redis and RabbitMQ containers, because a mocked broker cannot fail the way a real one does: it never redelivers on a lost acknowledgement, never returns a duplicate, never trips a memory alarm. It is also the only layer that can exercise row-level security, since a mocked database has no policies. Each layer catches what the one below cannot see, which is why the answer to a production defect is usually a test at a different level rather than another unit test. **Deeper:** [interview-questions.md](./interview-questions.md#q1-unit-contract-and-integration-tests-all-run-in-this-pipeline-what-does-each-catch-that-the-others-cannot) — "Unit, contract, and integration tests all run in this pipeline. What does each catch that the others cannot?"

  </details>

- **NICE** — Build and supply chain: digest pinning, image scanning, dependency audit, SBOM, reproducibility
- **MUST** — Migration ordering relative to deploy, and rollback that needs no down-migration

  <details><summary><strong>Answer</strong></summary>

  Running `alembic upgrade head` as an ArgoCD PreSync hook guarantees the schema is applied before new pods start, so no pod ever runs against a schema older than the code expects. What it does not guarantee is the other direction: during a blue-green cut-over the *old* image is still running against the new schema, which is exactly why every migration must be expand-only and backwards compatible. The dangerous part is that a PreSync hook blocks the sync, so a migration that takes a lock on a 110M-row table stalls the deploy and holds it there — which is why DDL runs with a `lock_timeout` and index creation is concurrent. Rollback runs no down-migration either: reverting an ArgoCD revision reverts the images and leaves the schema ahead, which is only safe because of expand/contract. **Deeper:** [interview-questions.md](./interview-questions.md#q2-alembic-migrations-run-as-an-argocd-presync-hook-what-ordering-does-that-guarantee-and-where-is-it-dangerous) — "Alembic migrations run as an ArgoCD PreSync hook. What ordering does that guarantee, and where is it dangerous?"

  </details>

- **MUST** — Debugging a failing pipeline: reproducing the runner environment, exit codes vs output text, the pipe that swallows a status

  <details><summary><strong>Answer</strong></summary>

  The first question is whether it fails only in CI, and answering it means reproducing the runner environment rather than the command — same image, same variables, same working directory, same shell flags — because a step under `bash -e` dies on a `grep` that correctly finds nothing, while the same line in a local shell passes. The second is to trust exit codes over output text: a command piped through `tail` or `grep` reports the last stage's status rather than its own, so a failing step can look green, and the fix is `pipefail` or capturing the status on the command's own line. After that it is ordinary bisection — rerun the single job, put diagnostics in artifacts rather than stdout, and check whether the failure correlates with parallelism or with a shared resource such as one test database. The failure I look for first is the silent one: a suite that collected zero tests and exited zero. **Deeper:** [interview-questions.md](./interview-questions.md#q3-an-integration-test-fails-intermittently-and-is-blocking-merges-walk-me-through-what-you-do) — "An integration test fails intermittently and is blocking merges. Walk me through what you do."

  </details>


## 20. Observability: Metrics, Logs, Traces

**Backs:** instrumented Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production"), Prometheus and Kibana on API and consumer latency and error rates.

- **MUST** — The three pillars and what each is bad at; when a trace is the only tool

  <details><summary><strong>Answer</strong></summary>

  Metrics are cheap, aggregated and unbounded in time, so they are what you alert on — and they are bad at explaining, because a p95 tells you something is slow and nothing about which request. Logs carry per-event detail and are good for reconstructing one case, bad at aggregate questions and expensive at volume. Traces are the only thing that shows one request's path across services and async hops, which is exactly the question this system asks most often: where did a check-in go between the phone and the search index. Here they are joined rather than merely coexisting — `traceparent` propagates through AMQP, MQTT and Service Bus headers, every log line carries `trace_id`, and Azure Monitor telemetry is shipped into Elasticsearch so Kibana is one pane. Without that join, a reminder failing between Celery and a Function is two unconnected half-stories. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-are-the-three-pillars-of-observability-and-how-are-they-joined-in-this-system) — "What are the three pillars of observability, and how are they joined in this system?"

  </details>

- **MUST** — Prometheus model: counters, gauges, histograms and summaries, labels and cardinality, scrape vs push, recording and alerting rules, [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/ "Prometheus Query Language — Queries and aggregates time series metrics collected by Prometheus") basics, histogram_quantile and what a p95 from a histogram really means

  <details><summary><strong>Answer</strong></summary>

  A counter only increases and you rate it; a gauge moves both ways and you read it directly; a histogram buckets observations so quantiles are computed at query time, while a summary computes them in the client — which is why histograms are preferred, since summaries cannot be aggregated across instances. Labels are both the power and the danger: every distinct label combination is a separate time series, so a label carrying a patient id, or a URL with an id in it, is a cardinality explosion that can take the server down. Prometheus scrapes rather than receives, so a target that disappears shows up as a target being down instead of as silence. `histogram_quantile` interpolates within a bucket, so a p95 from a histogram is only as precise as the bucket boundaries — worth knowing before quoting one to two decimal places, and a reason to place buckets around the SLO.

  </details>

- **NICE** — RED and USE method for choosing what to measure
- **MUST** — Distributed tracing: spans, context propagation, W3C traceparent, sampling strategies (head vs tail, always-on for errors), and propagation across queue boundaries — including transports with no header slot (MQTT 3.1.1)

  <details><summary><strong>Answer</strong></summary>

  A trace is a tree of spans sharing a trace id, and it only works if context propagates at every hop — W3C `traceparent` in HTTP headers, and in message headers for AMQP and Service Bus, because a queue is where a trace usually breaks. Sampling is a cost decision: head sampling decides at the start and is cheap but discards the rare interesting trace, while tail sampling decides after seeing the whole trace and keeps the slow and failed ones at the price of buffering. Here it is 100% of errors and of all reminder and NLP traffic with 10% of routine reads, which is head sampling with a rule rather than a flat rate. MQTT 3.1.1 is the awkward case, because it has no user-property header at all, so context either moves to MQTT 5 or travels inside the payload envelope — and that must be decided before clients ship, since retrofitting it breaks every published client. **Deeper:** [interview-questions.md](./interview-questions.md#q2-mqtt-311-has-no-header-for-trace-context-what-do-you-do-and-why-does-the-decision-have-to-be-made-early) — "MQTT 3.1.1 has no header for trace context. What do you do, and why does the decision have to be made early?"

  </details>

- **OPTIONAL** — Elastic APM agent auto-instrumentation and its blind spots
- **MUST** — Structured logging: [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"), correlation fields, log levels, and a redaction filter that drops sensitive fields at the formatter

  <details><summary><strong>Answer</strong></summary>

  Logs are JSON to stdout so the shipper does not parse prose, and every line carries `trace_id`, `span_id`, `service`, `module`, `actor_kind` and where applicable `patient_id` — which is what makes them joinable with traces rather than merely readable. Levels mean what they say: warn for something a human should look at eventually, error for something that failed, and nothing at info that fires per request per field. The control that matters most here is redaction at the formatter rather than at the call site — fields marked sensitive on Pydantic models are dropped by the filter, so no clinical free text, symptom value or document content reaches a log regardless of what a caller passed. Enforcing it at the formatter is deliberate, because a rule enforced at the call site is a rule someone eventually forgets, and a CI check fails the build if a log call passes a model carrying a sensitive field. **Deeper:** [interview-questions.md](./interview-questions.md#q2-no-clinical-free-text-is-ever-logged-enforced-by-a-redaction-filter-and-a-pipeline-check-how-does-that-work-and-where-could-it-leak-anyway) — "No clinical free text is ever logged, enforced by a redaction filter and a pipeline check. How does that work, and where could it leak anyway?"

  </details>

- **MUST** — Logs are for operators, audit is for the regulator — conflating them makes log retention silently become audit policy

  <details><summary><strong>Answer</strong></summary>

  Logs are operational telemetry for engineers: sampled, retained for weeks, shipped through pipelines that may drop under pressure, and readable by whoever is on call. An audit trail is a regulatory record of who accessed which patient's data: complete, immutable, retained for seven years, and access-controlled in its own right. Conflating them means log retention policy silently becomes audit policy — the day someone shortens retention to control cost, a compliance obligation disappears with no discussion and no approval. So audit here is a partitioned, append-only table in `pg-clinical` written in the same transaction as the access, and logs are a separate stream that deliberately carries no clinical content at all.

  </details>

- **MUST** — Detecting silent failures: lag and backlog-age metrics that alert when nothing is erroring

  <details><summary><strong>Answer</strong></summary>

  The failures that hurt in an event-driven system produce no errors at all: a consumer that stopped consuming, a relay that is not relaying, a scheduler that stopped ticking. Error-rate alerting is blind to every one of them, because the error rate of work that never started is zero. So the alerts are on age rather than count — `outbox_unpublished_age_seconds`, consumer lag, reminder dispatch lateness, last-tick age on the scheduler — since age rises whether the cause was a crash, a deadlock, or a deployment that quietly scaled a worker to zero. The rule generalises: for anything that is meant to happen continuously, alert on the absence of progress rather than on the presence of errors.

  </details>

- **MUST** — [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health")/SLO/error budget, burn-rate alerting, page vs ticket, alert fatigue

  <details><summary><strong>Answer</strong></summary>

  An SLI is a measured number, such as the proportion of record reads served under 250 ms; an SLO is the target committed to for it, 99.9% monthly here; and the error budget is what that target permits you to spend, roughly 43 minutes a month. The budget is the useful part, because it turns reliability from an argument into arithmetic: while budget remains, ship; when it is exhausted, the consequence was agreed in advance — feature work stops and reliability work takes the sprint. Burn-rate alerting makes that operational, paging on a fast burn that would exhaust the budget within the hour and raising a ticket for a slow burn that would take a week, which is how you avoid paging on every blip. The discipline underneath is that an alert with no consequence gets ignored, so page versus ticket is decided by whether a human must act now. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-the-difference-between-a-service-level-indicator-an-objective-and-an-error-budget) — "What is the difference between a service level indicator, an objective, and an error budget?"

  </details>


## 21. Reliability, Failure Modes and Recovery

**Backs:** availability targets, reminder timeliness, deploy and incident runbooks.

- **NICE** — Availability arithmetic; where a 99.9% budget actually goes
- **NICE** — Single points of failure and honest acceptance of one
- **MUST** — [HA](https://en.wikipedia.org/wiki/High_availability "High Availability — System design goal of remaining operational despite component failure") and failover: zone redundancy, failover time as a budget line, connection storms after failover and pooling as the mitigation

  <details><summary><strong>Answer</strong></summary>

  Zone-redundant HA keeps a synchronous standby in another availability zone and fails over automatically, which for `pg-clinical` is roughly 60 seconds — and that number is a line in the availability budget rather than an aside, since a handful of failovers a month is most of a 99.9% allowance. During the failover reads and writes both return `503`, because every audited read is a write. The failure people forget is what happens afterwards: every application instance reconnects at once, and a connection storm against a freshly promoted standby can turn a 60-second failover into a multi-minute outage. Pooling is the mitigation, together with bounded pool sizes and reconnect backoff with jitter, so recovery is paced instead of a stampede.

  </details>

- **MUST** — [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") and [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") as separate promises; [PITR](https://www.postgresql.org/docs/current/continuous-archiving.html "Point in Time Recovery — Restores a database to a specific past moment using base backups and archived logs"); a backup that has never been restored is an assumption, not a control

  <details><summary><strong>Answer</strong></summary>

  RPO is how much data you may lose, measured backwards from the incident; RTO is how long you may take to come back. They are separate promises bought with separate mechanisms — RPO with replication and backup frequency, RTO with automation and rehearsal — and here they are 5 minutes and 30 minutes for `pg-clinical`, with RPO 0 for an accepted check-in because the broker replicated it before acknowledging. Point-in-time recovery is what makes the RPO number real, replaying archived write-ahead log to a chosen timestamp, and it is also the only remedy for logical damage such as a bad migration, since replication faithfully replicates the mistake. What turns all of this from a claim into a control is rehearsal: a backup that has never been restored is an assumption, so a PITR restore and a full `es-clinical` rebuild are exercised quarterly against a scratch environment.

  </details>

- **NICE** — Rebuildable derived stores as a recovery strategy (index rebuild from source)
- **NICE** — Graceful degradation: a labelled fallback path beats an error page
- **MUST** — Retries done properly: idempotency, exponential backoff with jitter, budget caps, circuit breakers, timeouts everywhere

  <details><summary><strong>Answer</strong></summary>

  Retries are how a transient failure becomes invisible and how a struggling dependency becomes a dead one, so each one needs four bounds: idempotency so retrying is safe at all, exponential backoff so pressure decreases, jitter so callers do not synchronise, and a cap with a defined destination afterwards. A retry budget matters more than a per-call limit, because capping retries as a fraction of total traffic prevents the storm where every layer multiplies the layer beneath it. Circuit breakers supply the missing behaviour — fail fast while a dependency is known bad, so callers are not queueing behind timeouts, then probe before restoring. And every outbound call carries a timeout, because a call with no deadline is not a call but a resource leak, which on an async service means a task holding its slot indefinitely.

  </details>

- **MUST** — Queue-backed work as a shock absorber; the state machine in the database so outages delay rather than lose

  <details><summary><strong>Answer</strong></summary>

  A queue in front of slow or unreliable work is a shock absorber: a burst is buffered rather than rejected, a downstream outage becomes a backlog rather than a user-visible failure, and consumers scale independently of producers. But it only absorbs the shock if the work's state lives somewhere durable, and that is the property that matters here. Reminders are rows in `pg-clinical` with a state machine, not messages that exist only in flight, so a broker outage, a Function outage or a two-hour scheduler stop delays them rather than losing them — the next sweep re-reads whatever is still pending. Put the state machine in the queue instead and every one of those outages becomes permanent loss, with no way even to enumerate what was lost.

  </details>

- **MUST** — Runbooks, incident review, and what "22% fewer missed reminders" requires: a delivery-attempt table so the question is a query, not a log grep

  <details><summary><strong>Answer</strong></summary>

  Runbooks matter most for the paths nobody runs often — a point-in-time restore, an `es-clinical` rebuild, a break-glass grant — and the honest test of one is whether someone who did not write it can follow it under pressure, which is what quarterly rehearsal checks. Incident review is where a fix goes back into the system as a test or an alert rather than as a lesson someone remembers. On the reminder figure specifically the point is architectural: it is measurable at all because every delivery attempt is a `reminder_delivery` row with a channel, a provider receipt and a terminal state, so "was it delivered" is a query rather than a log grep, and a terminal failure escalates to the care team instead of ending in a log line. Before that table existed nothing recorded a reminder that never arrived, which is exactly why the old failure was invisible. **Deeper:** [interview-questions.md](./interview-questions.md#q2-walk-me-through-the-reminder-delivery-path-which-specific-mechanisms-turn-did-the-reminder-arrive-from-a-log-grep-into-a-query) — "Walk me through the reminder delivery path. Which specific mechanisms turn 'did the reminder arrive' from a log grep into a query?"

  </details>


## 22. Security and Regulatory Compliance for Health Data

**Backs:** identity work, data protection, and the clinical setting of the product.

- **MUST** — Threat modelling: trust boundaries, STRIDE, and the fact that the dangerous adversary here is authenticated

  <details><summary><strong>Answer</strong></summary>

  Threat modelling starts from the data and the boundaries it crosses: draw the trust boundaries — internet to edge, edge to application, application to data, and the cross-cluster hop to `aks-ml` — then enumerate what an attacker could do at each, with something structured such as STRIDE so it does not become a brainstorm about firewalls. The property that shapes this system is that the dangerous adversary is authenticated: a clinician with a valid token and a legitimate role reading records they have no relationship with. Perimeter controls do nothing against that, which is why the primary defences are relationship-based authorization enforced in the database, an audit trail of every access, and detection rules naming specific misuse rather than generic anomalies. Modelling only the outsider would have produced a very secure system with the wrong controls.

  </details>

- **MUST** — [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") API Top 10, especially broken object-level and function-level authorization

  <details><summary><strong>Answer</strong></summary>

  The API list is not the web application one, and its top two entries are both authorization: broken object-level authorization, where a handler fetches by an id from the request without checking entitlement, and broken function-level authorization, where an endpoint is reachable by a role that should not have it. They dominate because they are invisible to scanners and to review — the code looks like every other fetch, and the tests pass because tests use their own data. The structural answers are already in this design: RLS makes object-level access a database decision so a missed check returns nothing, and audience separation at the gateway makes function-level access fail before application code runs. The rest of the list maps onto controls that are here for other reasons too — rate limiting for unrestricted resource consumption, `extra='forbid'` for mass assignment, and treating the directory's payloads as untrusted input.

  </details>

- **MUST** — Encryption at rest: TDE, customer-managed keys, envelope encryption, key rotation; what encryption at rest does and does not protect against

  <details><summary><strong>Answer</strong></summary>

  Transparent data encryption encrypts the files the database writes, so it protects against someone taking the disk, the backup or the storage account — and against nothing else. It does not protect against a compromised application, a stolen credential or an over-privileged query, because to the database those are legitimate reads that receive decrypted data. A customer-managed key in Key Vault changes who can revoke access rather than how the data is encrypted, and envelope encryption is what makes rotation affordable: a data key encrypts the data and a key-encryption key wraps the data key, so rotating the outer key rewraps a small key instead of re-encrypting terabytes. Being precise about this matters, because "encrypted at rest" is offered constantly as an answer to a threat it does not address.

  </details>

- **NICE** — Field-level encryption trade-offs and the honest position that data used by every query cannot be meaningfully field-encrypted
- **MUST** — [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection"): versions, cipher choice, certificate verification modes (verify-full), mTLS, certificate issuance and rotation without a service mesh (cert-manager)

  <details><summary><strong>Answer</strong></summary>

  TLS 1.3 is the target and 1.2 the floor for older mobile clients, with nothing below it negotiated; 1.3 removed the legacy cipher suites, so cipher choice is mostly a 1.2 concern and the answer there is forward-secret suites only. Verification mode is where real deployments go wrong: `verify-full` checks the chain *and* that the hostname matches, while `verify-ca` accepts any certificate that CA issued — which on a shared cloud CA can mean accepting another tenant's server, so store connections here are `verify-full`. mTLS adds client authentication, and it is how `care-core` and `clinical-nlp-svc` authenticate each other on the one hop that crosses clusters and carries clinical free text. Without a service mesh something still has to issue and rotate those certificates, which is why cert-manager is named explicitly rather than assumed — declining the mesh removed the component that would otherwise have done it.

  </details>

- **NICE** — Network controls: private endpoints, VNet peering, NSGs, default-deny NetworkPolicy and egress control
- **MUST** — Secrets management and the elimination of static credentials

  <details><summary><strong>Answer</strong></summary>

  The goal is that no long-lived credential exists anywhere it could be copied — not in an image layer, a manifest, a CI variable, or an environment variable visible in a process listing or a crash dump. Workload identity federation removes most of them outright by exchanging a pod's service account token for an Azure token, so the credential is short-lived and issued per workload. What genuinely must be a secret — the database password, the blind-index key — lives in Key Vault with soft delete, purge protection and annual rotation, and is projected into the pod as a file rather than an environment variable. And rotation only counts once it has been exercised: a secret nobody has ever rotated is a secret whose rotation procedure does not work yet.

  </details>

- **MUST** — Audit trail design: synchronous vs asynchronous, append-only enforcement, partitioning, retention and immutable archive; the read-availability cost of auditing reads synchronously

  <details><summary><strong>Answer</strong></summary>

  Every read and write of patient data writes an `audit.audit_event` row in the same transaction as the access — synchronously, because an audit trail that can be lost in a queue is not an audit trail. Append-only is enforced at the database rather than by convention: `UPDATE` and `DELETE` are revoked from every application role and a trigger blocks them, so even a compromised application cannot rewrite history. Volume is the design constraint, since audit outweighs all clinical data here by roughly five to one, which is why the table is partitioned monthly, kept thirteen months hot, and archived to an immutable container for the full seven years. The cost is stated rather than hidden: auditing reads synchronously makes an audited read a write, so it cannot be served from a replica and it fails when the primary fails — read availability is bounded by write availability, and for a health record that is the better of the two failures. **Deeper:** [interview-questions.md](./interview-questions.md#q2-there-are-two-read-replicas-but-patient-facing-reads-are-served-by-the-primary-explain-that-and-how-you-would-verify-it-stays-true) — "There are two read replicas, but patient-facing reads are served by the primary. Explain that, and how you would verify it stays true."

  </details>

- **NICE** — Detection rules over the audit stream that name a specific misuse
- **MUST** — [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data"): lawful basis, Article 9 special-category data, consent versioning and withdrawal, minimisation, purpose limitation, [DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them"), residency, [DPIA](https://gdpr-info.eu/art-35-gdpr/ "Data Protection Impact Assessment — GDPR process for assessing privacy risk before high-risk data processing")

  <details><summary><strong>Answer</strong></summary>

  Health data is Article 9 special-category data, so processing needs both a lawful basis and an Article 9 condition — here explicit consent, captured in `consent`, versioned and withdrawable, with processing purposes bound to the consent scope so a withdrawal actually changes behaviour. Minimisation and purpose limitation are architectural rather than declarative: the model receives diagnosis, treatment line, stage and locale and never the patient's identity, logs carry no clinical content, and `platform_operator` has no routine record access. A DSAR is answerable because the record can be assembled from `pg-clinical`, `blob-documents` and the assigned content pages within statutory time, and residency holds because every resource, both clusters and all backups sit in one region with no third-party model API. A DPIA is maintained specifically for the NLP pipeline, because training on clinical text is the highest-risk processing in the system.

  </details>

- **MUST** — Erasure vs statutory retention: which wins for a medical record and how that is stated to the patient

  <details><summary><strong>Answer</strong></summary>

  They conflict, and retention wins: a medical record is retained under health-records law for its statutory period, so a right-to-erasure request cannot delete a prescription or a visit note. What erasure does reach is everything outside the record — marketing preferences, optional profile fields, derived analytics — plus the right to stop further processing, which is what withdrawal of consent actually delivers. The part that matters more than the legal answer is when the patient is told: this is stated at consent rather than discovered at the point of request, because promising a deletion you cannot lawfully perform is the worse failure by far. Related and worth adding: soft deletion is not used on clinical rows here, because tombstoning a prescription would be neither erasure nor honest retention.

  </details>

- **OPTIONAL** — [HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") mapping of the same technical safeguards; [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 27001/27701 framing

## 23. Defending the Numbers

**Backs:** "35% lower query latency", "28% higher relevance", "22% fewer missed reminders".

- **MUST** — What was measured, at which percentile, over what window, on what traffic

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in — no canned answer can be honest on your behalf.** Have ready: which metric, on which endpoint or query shape; which percentile rather than an average; over what window; on what traffic mix; and whether the figure came from production telemetry or a benchmark run. State the measurement before the improvement, because an interviewer who has to ask for it has already formed a view. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-cv-claims-a-35-reduction-in-query-latency-how-would-you-establish-that-number-and-what-would-make-it-a-false-claim) — "The CV claims a 35% reduction in query latency. How would you establish that number, and what would make it a false claim?"

  </details>

- **MUST** — The baseline: how it was captured and why it is comparable

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in.** Be able to say how the baseline was captured — same query shape, same data volume, same cache state, same traffic mix — and over what period. The trap is a baseline taken on a cold cache or against a smaller dataset, which flatters every later number and makes the whole claim collapse under one follow-up question. If the baseline was captured less rigorously than you would like, saying so plainly is stronger than defending it.

  </details>

- **MUST** — Confounders: a cache added at the same time, a data-volume change, a different query mix, a warm buffer pool

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in.** List what else changed in the same window — an index and a cache added together, a data-volume change, a different query mix after a UI change, a warm buffer pool, a hardware or version upgrade — and say which of them you can rule out and how. The credible version of this answer is not "nothing else changed"; it is naming the one or two confounders you could not eliminate and explaining why you still attribute the gain.

  </details>

- **MUST** — Percentiles vs averages; why p50 improvements can hide p99 regressions

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in for your figures; the mechanics are general.** An average is dominated by the bulk of fast requests and hides the tail, so a p50 improvement can sit alongside a p99 regression — and the tail is what a clinician experiences mid-consultation. Percentiles also do not average across instances or time windows, so aggregating them naively reports a number nobody experienced. Be ready to say which percentile your figure is, and what happened to the others.

  </details>

- **MUST** — For relevance: the evaluation set, the metric, who labelled it, whether the gain survives a second model version

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in.** Be able to describe the evaluation set: how many items, drawn from what population, split at patient level so no training patient appears in test; the metric and its cut-off, NDCG or MRR for reranking; who produced the labels and whether their agreement was measured; and whether the gain survived the next model version or was a one-off. If clinicians labelled it, say how many and how disagreements were settled.

  </details>

- **MUST** — For reminders: the denominator — what counts as "missed", and how it became observable at all

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in.** The number rests entirely on the denominator, so define "missed" precisely — never delivered, delivered outside the window, or delivered and unacknowledged — and say where that is recorded. The honest half of this answer is architectural rather than statistical: the figure is measurable at all because every attempt is a `reminder_delivery` row with a channel, a provider receipt and a terminal state. Before that table existed nothing recorded a reminder that had not arrived, which is what explains the improvement rather than merely asserting it.

  </details>

- **MUST** — Being able to say "measured this way, and here is what it does not prove"

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in, and the most important line on this list.** Finish every numeric claim with its boundary: measured this way, over this window, on this traffic — and here is what it does not prove. A candidate who volunteers the limitation is trusted with the number; a candidate who defends it against every probe invites the interviewer to keep pulling. If a figure is one you inherited rather than measured, say so plainly rather than adopting it.

  </details>

