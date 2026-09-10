# Fundamental Topics

*Retail Software Aggregation Platform*

## Table of Contents

- [1. Clean Architecture and Module Boundaries](#1-clean-architecture-and-module-boundaries)
- [2. Python, FastAPI and Pydantic Service Mechanics](#2-python-fastapi-and-pydantic-service-mechanics)
- [3. REST API Design Under Load and Under Retry](#3-rest-api-design-under-load-and-under-retry)
- [4. Authentication: OAuth 2.0, OIDC and JWT](#4-authentication-oauth-20-oidc-and-jwt)
- [5. Authorization and Multi-Tenancy](#5-authorization-and-multi-tenancy)
- [6. PostgreSQL Data Modelling](#6-postgresql-data-modelling)
- [7. Indexing and Query Performance](#7-indexing-and-query-performance)
- [8. SQLAlchemy and Alembic](#8-sqlalchemy-and-alembic)
- [9. MongoDB and Schemaless Modelling](#9-mongodb-and-schemaless-modelling)
- [10. Polyglot Persistence and Cross-Store Consistency](#10-polyglot-persistence-and-cross-store-consistency)
- [11. Caching with Redis](#11-caching-with-redis)
- [12. Asynchronous Work with Celery](#12-asynchronous-work-with-celery)
- [13. Event-Driven Integration on Azure](#13-event-driven-integration-on-azure)
- [14. Search and Faceted Filtering in PostgreSQL](#14-search-and-faceted-filtering-in-postgresql)
- [15. Kubernetes and AKS](#15-kubernetes-and-aks)
- [16. CI/CD Pipelines](#16-cicd-pipelines)
- [17. Terraform and Infrastructure as Code](#17-terraform-and-infrastructure-as-code)
- [18. Observability and Alerting](#18-observability-and-alerting)
- [19. Testing Practice](#19-testing-practice)
- [20. Security Beyond Authentication](#20-security-beyond-authentication)
- [21. Linux and Production Operations](#21-linux-and-production-operations)
- [22. Code Review and Refactoring](#22-code-review-and-refactoring)
- [23. Documentation and Operational Writing](#23-documentation-and-operational-writing)
- [24. Defending the Design's Numbers](#24-defending-the-designs-numbers)

**What this is.** The topics an engineer who claims the responsibilities in `cases/02/projects/retail-software-marketplace/inputs.txt` must be able to discuss from first principles, not recite. Grounded in the design docs 00-06 in that folder. Self-contained — it assumes no other project's list.

**How to use it.** Answer the bullet aloud before you open anything beneath it — the block is collapsed so the bullet stays a recall test rather than a page to read — then expand it and check what you said against what is there. A block now sits under every bullet, whatever its priority. A topic you can only define is not yet known.

**What an answer block is.** A target for what your own answer should have reached, in the register the answer wants in the room — what the thing is, the trade-off it buys and what that costs, and where it lands in *this* system, named component by named component. Its length tracks the bullet's priority, because a block is only as long as the answer is worth in the room: three to five sentences on a MUST, two to four on a NICE, one or two on an OPTIONAL, for the reasons the priority table below gives. Matching its wording is worth nothing and matching its substance is the whole test. Where a question in [`interview-questions.md`](./interview-questions.md) already carries the depth, the block stops short and ends with a **Deeper:** pointer to it rather than saying the same thing twice.

**The one exception.** Topic 24 asks what you personally measured, and nothing written here can answer that honestly for you. Those blocks hold a prompt skeleton instead — the facts to have ready — for you to complete.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | You cannot defend the responsibility without it. Expect it to be probed directly, and expect a wrong or vague answer to cast doubt on the claim itself. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 149 MUST, 46 NICE, 10 OPTIONAL across 24 topics. A MUST-heavy list is the honest consequence of a responsibility list this specific: most of these topics are named or implied by the brief itself rather than added around it.

**Backs:** under each heading names the responsibility line the topic defends. This file is a study aid, not a pipeline artifact: no skill mode reads it and no gate checks it.

## 1. Clean Architecture and Module Boundaries

**Backs:** a marketplace backend with clean architecture, splitting catalog, vendor and retailer modules so listing changes did not spill into connection and billing flows.

- **MUST** — The dependency rule: entities → use cases → adapters → frameworks, and what "the database is a detail" actually means in a [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") service

  <details><summary><strong>Answer</strong></summary>

  Dependencies point inward: entities know nothing, use cases know entities, adapters know use cases, and the framework ring knows everything and is known by nothing. "The database is a detail" means the use case that publishes a listing talks to a repository interface, not to a SQLAlchemy session, so the rule that a listing cannot publish while its vendor is still `pending` is testable with no database running at all. Python enforces none of that by construction — `from app.infrastructure.db import session` inside a domain module imports perfectly — so across the six marketplace services it has to be an import-linter contract in the pipeline that fails the build on a back-edge, or it decays into a folder-naming convention. What it costs is indirection you pay for even where the implementation will never change, which is why I broke it deliberately on the catalog search query: that path uses SQLAlchemy Core with hand-written predicates, because there the generated plan *is* the design and hiding it behind a generic repository method means nobody can see what the database is being asked to do. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-clean-architecture-mean-concretely-in-a-python-service-and-what-in-the-code-actually-stops-the-dependency-direction-from-being-violated) — "What does "clean architecture" mean concretely in a Python service, and what in the code actually stops the dependency direction from being violated?"

  </details>
- **MUST** — Ports and adapters (hexagonal); repository and unit-of-work patterns

  <details><summary><strong>Answer</strong></summary>

  A port is an interface the domain declares in its own terms — "give me the current revision of this listing" — and an adapter is the thing that satisfies it with Postgres, Mongo or a Service Bus client. The repository pattern is the port for persistence; the unit of work is the port for "these writes land together or not at all", which in `vendor-service` is what lets the `product` update and the `outbox_event` insert share one transaction without the use case ever naming a session. The payoff is that the metadata store is swappable and the domain tests need no container; the cost is a layer of interfaces that earns nothing where there will only ever be one adapter. My rule is that a port is worth it where the implementation is genuinely interchangeable or genuinely awkward to run in a test, and it is a liability everywhere else.

  </details>
- **MUST** — Where business rules live, and the smell of logic inside a route handler

  <details><summary><strong>Answer</strong></summary>

  Business rules live in the entity when they are invariants of the thing itself, and in the use case when they are invariants of an operation. "A connection bills at most once" is an entity-level truth and it is also a unique constraint in `postgres-core`; "publishing requires an active vendor and a metadata document that validates against the category's facet schema" is a use case. The smell in a route handler is any `if` that would still be true if the API disappeared — a status transition, a quota decision, a cross-entity check — as opposed to parsing, authorization plumbing and shaping a response. What it costs to be strict about this is that handlers look thin to the point of pointlessness in review; what it buys is that the same rule is reachable from a Celery task and from an admin endpoint without being written twice, which is exactly the trap the admin workspace would otherwise fall into.

  </details>
- **MUST** — Bounded contexts and aggregates; one owner per fact, one writer per table

  <details><summary><strong>Answer</strong></summary>

  A bounded context is a region within which a word means one thing — "product" means a listing spine to `catalog-service` and a billable relationship to `billing-service`, and pretending those are one model is how a shared schema starts. An aggregate is the consistency boundary inside a context: `connection_request` plus its thread and messages change together under one transaction, and nothing outside reaches into them. The rule that makes it operational here is one owner per fact and one writer per table, enforced by giving each service its own database role with grants managed in Terraform rather than by asking reviewers to notice. The one apparent exception is `product_listing_facets`, written only by `indexer-worker` and read only by `catalog-service` — that is a single-writer projection with a declared reader, which is a pattern, not shared ownership. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-it-mean-that-a-service-owns-its-tables-and-what-happens-the-first-time-someone-breaks-that) — "What does it mean that a service "owns its tables", and what happens the first time someone breaks that?"

  </details>
- **MUST** — Module boundary vs deployment boundary: which one the requirement actually demanded, and the honest difference between "enforced" and "documented"

  <details><summary><strong>Answer</strong></summary>

  The brief asked that listing changes not spill into connection and billing flows, and the honest difference is that a module boundary documents that and a process boundary enforces it. Inside one application, nothing but review discipline stops a listing handler importing the billing repository; across services, `vendor-service` has no write path into `connection_*` or `billing_*` at all, and its database role has no grant there. What the requirement actually demanded is arguable — at 35 QPS peak the modular monolith is genuinely defensible and cheaper to run — and I would say plainly that six services were chosen for isolation, not throughput. The cost is nine deployments to observe, affordable only because they share one repository, one Alembic history, one pipeline and one cluster. **Deeper:** [interview-questions.md](./interview-questions.md#q1-why-are-catalog-vendor-and-retailer-separate-services-here-rather-than-separate-modules-inside-one-application) — "Why are catalog, vendor and retailer separate services here rather than separate modules inside one application?"

  </details>
- **MUST** — Service decomposition criteria: traffic shape, release cadence, data sensitivity, blast radius — not size

  <details><summary><strong>Answer</strong></summary>

  Size is the worst possible criterion; what should decide a split is traffic shape, release cadence, data sensitivity and blast radius. Each of the six here answers to one of those: `catalog-service` is read-only and carries almost all the traffic, so it scales and degrades alone; `vendor-service` releases on vendor-tooling cadence and can be saturated by an import without touching browse; `retailer-service` holds the buyer's private working set, which is a sensitivity boundary; `identity-service` is a trust boundary where compromise is categorically worse. Applied honestly the criteria also argue against splitting — `billing-service` is separate because the brief named that flow, not because its load or cadence differs. The cost of getting this wrong in the other direction is a distributed monolith, where you pay every network and deployment cost and still cannot release one piece alone. **Deeper:** [interview-questions.md](./interview-questions.md#q3-six-services-and-three-worker-pools-for-a-system-peaking-around-35-qps-make-the-case-against-yourself-when-is-the-modular-monolith-the-right-call-and-what-would-make-you-collapse-these) — "Six services and three worker pools for a system peaking around 35 QPS. Make the case against yourself: when is the modular monolith the right call, and what would make you collapse these?"

  </details>
- **NICE** — Distributed monolith as the failure mode; the cost of nine deployments at low [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") and what makes it affordable (one repo, one migration history, one pipeline)

  <details><summary><strong>Answer</strong></summary>

  The cost of nine deployments and what makes it affordable are answered above under "Module boundary vs deployment boundary"; what this bullet adds is how you tell the failure mode has actually happened. The symptoms are diagnostic rather than architectural: two services that can never be released independently, a change that needs a coordinated deploy order, a synchronous call chain more than one hop deep, or a table two services both write. This design is checkable against each of those — no synchronous call crosses more than one service boundary, and `product_listing_facets` has exactly one writer — and the honest admission is that the single Alembic history is both the property that makes nine deployments cheap and the one that would let the distributed monolith in, because nothing structural stops a migration only the newest image can survive. **Deeper:** [interview-questions.md](./interview-questions.md#q3-six-services-and-three-worker-pools-for-a-system-peaking-around-35-qps-make-the-case-against-yourself-when-is-the-modular-monolith-the-right-call-and-what-would-make-you-collapse-these) — "Six services and three worker pools for a system peaking around 35 QPS. Make the case against yourself: when is the modular monolith the right call, and what would make you collapse these?"

  </details>
- **NICE** — Anti-corruption layer; no service reading another's database

  <details><summary><strong>Answer</strong></summary>

  An anti-corruption layer is a translation boundary: when `connection-service` consumes `connection.requested` or calls `retailer-service`, it maps the payload into its own model at the edge rather than letting a peer's field names spread inward, so a rename upstream breaks one adapter instead of a service. The no-shared-database half is the enforcement it rests on and is answered above under "Bounded contexts and aggregates" — a database role per service, and a peer that needs data it does not own calls an API or consumes an event. What the translation costs is a mapping nobody enjoys writing while the two models are still identical; what it buys is that they are allowed to stop being identical, because without it an event payload quietly becomes a shared schema with none of the visibility a shared table would at least have had.

  </details>

## 2. Python, FastAPI and Pydantic Service Mechanics

**Backs:** FastAPI [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") APIs for catalog browse and vendor-retailer connection.

- **MUST** — [ASGI](https://asgi.readthedocs.io/en/latest/ "Asynchronous Server Gateway Interface — Standard interface between asynchronous Python web servers and applications") vs WSGI; uvicorn/gunicorn workers, the event loop, the thread pool

  <details><summary><strong>Answer</strong></summary>

  WSGI is synchronous by construction: a worker is occupied by one request from first byte to last, so concurrency costs you a process or a thread each time. ASGI replaces that contract with an event-driven one, where a single process can hold thousands of requests in flight because nearly all of them are parked on a socket rather than running. In deployment that means gunicorn owns processes and uvicorn workers own an event loop each, so parallelism across CPU cores comes from processes and concurrency within a core comes from the loop. The thread pool matters because it is where FastAPI runs any handler you declare `def` rather than `async def`, and it is small and bounded, so a slow synchronous handler queues behind itself long before the loop is troubled. For this workload the choice is easy: every service spends its time waiting on Postgres, Mongo and Redis rather than computing, which is precisely the shape ASGI is good at. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-uvicorn-and-how-do-processes-threads-and-the-event-loop-relate-in-a-deployed-fastapi-service) — "What is Uvicorn, and how do processes, threads and the event loop relate in a deployed FastAPI service?"

  </details>
- **MUST** — async/await, tasks, cancellation, timeouts; when async actually helps (a workload dominated by waiting on Postgres, Mongo and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"))

  <details><summary><strong>Answer</strong></summary>

  `await` yields the loop at a point where the coroutine cannot progress, so one worker overlaps hundreds of database round trips; a task is a coroutine scheduled independently, which is also the only way to run two waits concurrently rather than in sequence. Timeouts and cancellation are the part people skip and the part that matters in production: the one synchronous inter-service hop here, `connection-service` calling `retailer-service`, carries a 250 ms timeout, and without cancellation propagating into the client a slow peer becomes a slow queue of held connections. Async earns its keep only when waiting dominates, which it does here — a catalog search is roughly 45 ms of Postgres, 25 ms of Mongo and a few milliseconds of Redis against about 12 ms of serialization. On a CPU-bound workload it buys nothing and costs you a harder debugging story. **Deeper:** [interview-questions.md](./interview-questions.md#q1-in-fastapi-what-actually-differs-between-declaring-an-endpoint-async-def-and-declaring-it-def) — "In FastAPI, what actually differs between declaring an endpoint `async def` and declaring it `def`?"

  </details>
- **MUST** — The blocking-call trap: one sync driver call stalls every request on that worker; run_in_executor as the escape hatch

  <details><summary><strong>Answer</strong></summary>

  One synchronous driver call inside an `async def` handler does not block that request, it blocks the event loop, and therefore every other request being served by that worker. The symptom is diagnostically nasty: p99 latency across unrelated endpoints rises, CPU looks fine, and the slow endpoint may not be the one you notice, because the victim is whoever shared the worker. The fixes in order are to use the async driver — asyncpg, the async Mongo and Redis clients, which this design assumes everywhere — and to push anything genuinely blocking into `run_in_executor` or a Celery task, with `def` handlers as the honest fallback since FastAPI will then run them in the thread pool rather than on the loop. The way I would find it is a loop-lag metric plus a blocking-call detector in development, not by reading diffs. **Deeper:** [interview-questions.md](./interview-questions.md#q2-someone-adds-a-blocking-call-inside-an-async-def-endpoint-describe-the-symptom-and-how-you-would-find-it) — "Someone adds a blocking call inside an `async def` endpoint. Describe the symptom and how you would find it."

  </details>
- **NICE** — Concurrency limits and backpressure; unbounded fan-out as a self-DoS

  <details><summary><strong>Answer</strong></summary>

  Backpressure is the property that a system given more work than it can serve refuses some of it rather than accepting all of it and degrading everything — a bounded connection pool, a bounded queue, a bounded fan-out. The self-DoS is what happens without it: an `async def` handler that gathers over an unbounded list opens as many concurrent round trips as the input happened to contain, so a caller passing a large `product_ids` array to `POST /v1/catalog/compare` would exhaust the pod's pool and stall every other request that worker is serving. That is why compare is capped at five products and the catalog list at `limit≤50` — the limit in the contract is the backpressure mechanism, applied where it is cheapest to enforce and easiest for a client to understand. Bounding the fan-out of bulk work is the same instinct one layer down, and is answered under "Chunking a large job into bounded tasks" in the Celery topic.

  </details>
- **MUST** — FastAPI: dependency injection and its caching, routers as an enforcement point, middleware order, lifespan, exception handlers, BackgroundTasks vs a real queue

  <details><summary><strong>Answer</strong></summary>

  Dependency injection in FastAPI is a way to declare what a handler needs and have the framework build it, and its real value here is that it is an enforcement point rather than a convenience: the account-type check on `/v1/vendor/*`, `/v1/retailer/*` and `/v1/admin/*` is a router-level dependency, so a new endpoint inherits it instead of remembering it. The caching is worth knowing — a dependency is resolved once per request, so a session or a resolved principal is shared rather than rebuilt — and so is middleware order, because a middleware that wants a request id on every log line has to run outside the one that might raise. `lifespan` is where pools and clients are opened and drained once per process rather than per request. `BackgroundTasks` runs after the response in the same process, which is fine for a fire-and-forget log write and wrong for anything that must survive a pod restart — that goes to Celery or the outbox. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-fastapis-dependency-injection-actually-for-and-what-does-this-system-use-it-for) — "What is FastAPI's dependency injection actually for, and what does this system use it for?"

  </details>
- **MUST** — [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") v2: validation vs serialization, extra=forbid so unknown fields are rejected rather than absorbed, discriminated unions, custom validators, settings loading, the Rust core's performance profile

  <details><summary><strong>Answer</strong></summary>

  Pydantic parses and validates on the way in and serializes on the way out, and in v2 that work happens in a Rust core, so the cost is real but small relative to a database round trip — about 12 ms for thirty listing summaries in this design's budget. The setting I care most about is `extra="forbid"`, because the alternative is that a vendor's typo in a request body is silently absorbed and the field they meant to set stays at its default. Discriminated unions are how the per-category product payloads stay typed at the edges, and custom validators are where the marketplace rules that are not shape rules live. It is also a build artefact, not documentation: the same models generate the OpenAPI document the admin console and vendor integrations compile against, which is what makes a contract test possible at all. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-pydantic-actually-do-on-each-request-and-what-does-it-cost) — "What does Pydantic actually do on each request, and what does it cost?"

  </details>
- **MUST** — Validating untyped input against a runtime schema (per-category facets) — "no fixed column set" without losing a contract

  <details><summary><strong>Answer</strong></summary>

  The trick is that "no fixed column set" is a statement about the *platform's* schema, not about the absence of a contract. A vendor's `attributes` document is validated at write time in `vendor-service` against the category's `facet_schemas` document, which declares which keys are typed, which are facetable and what value domains they take — so the contract exists, it just lives in data rather than in a table definition. Practically that means building a Pydantic model per category at runtime from the schema document and caching it, rather than writing one model per category by hand. What it buys is that adding a category is a document insert plus a projection mapping instead of a migration; what it costs is that schema evolution becomes a versioning problem you now own, which is why every document carries a `schema_version` and why the design flags facet schema evolution as needing a prototype. **Deeper:** [interview-questions.md](./interview-questions.md#q1-the-brief-asked-for-mongodb-schemas-for-product-metadata-without-a-fixed-column-set-what-does-schemaless-actually-buy-here-and-how-do-you-stop-it-degrading-into-no-contract) — "The brief asked for MongoDB schemas for product metadata "without a fixed column set". What does schemaless actually buy here, and how do you stop it degrading into "no contract"?"

  </details>
- **NICE** — The [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document as a build artefact the admin console and vendor integrations compile against

  <details><summary><strong>Answer</strong></summary>

  This is answered in full above — under Pydantic v2 in this topic for why the document is generated rather than written, and under "Functional/contract tests against the OpenAPI schema" in Testing Practice for what being a build artefact makes checkable. There is nothing left for this bullet to add beyond those two. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-frontend-team-generates-its-client-from-your-openapi-document-what-counts-as-a-breaking-change-and-how-do-you-ship-a-field-that-must-be-required) — "The frontend team generates its client from your OpenAPI document. What counts as a breaking change, and how do you ship a field that must be required?"

  </details>

## 3. REST API Design Under Load and Under Retry

**Backs:** catalog browse, connection APIs, and the admin panel calling the same versioned APIs.

- **MUST** — Resource modelling, URI design, /v1 versioning and how a breaking change actually ships

  <details><summary><strong>Answer</strong></summary>

  Resources are nouns the client can hold and re-fetch — `/v1/catalog/products/{id}`, `/v1/retailer/shortlists/{id}/items` — and the two places this design deviates are deliberate: `POST /v1/catalog/compare` is a computation over a set rather than a resource, and `:publish` is a state transition rather than a field write, because letting a client PATCH `status` to `published` invites it to skip the rules that transition carries. Versioning is `/v1` in the path, which is the crude option and the one that survives contact with vendor integrations that will not read a header. A breaking change ships as `/v2` living alongside `/v1`, with the old surface kept until the integrations move, and the honest cost is that you now run two contracts and two sets of tests over one set of tables. The cheaper move most of the time is to make the change additive and never need `v2` at all. **Deeper:** [interview-questions.md](./interview-questions.md#q3-the-api-is-versioned-as-v1-in-the-path-what-happens-when-you-need-v2-and-would-you-do-it-differently) — "The API is versioned as `/v1` in the path. What happens when you need `v2`, and would you do it differently?"

  </details>
- **MUST** — Pagination: keyset/cursor vs offset, cursor encoding, stable sort tuples, and why deep pages are the normal case in a comparison workflow

  <details><summary><strong>Answer</strong></summary>

  Offset pagination makes the database walk and discard every row before the page, so cost grows with depth, and it is also incorrect under concurrent writes — a listing published while you page shifts everything and you see a duplicate or miss a row. Keyset pagination carries the last row's sort tuple instead, so page 40 costs what page 1 costs and the sort key doubles as a stable position. The tuple has to be unique or the boundary is ambiguous, which is why the ordering here is `(published_at, product_id)` and why `idx_plf_browse` is built on exactly that. Deep pages are not an edge case in this product: a category manager comparing coverage across a category works through the result set rather than reading the first ten, and that is the whole reason this API is cursor-based everywhere rather than only where it looked slow. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-keyset-pagination-and-why-does-this-api-use-it-everywhere-instead-of-offset) — "What is keyset pagination, and why does this API use it everywhere instead of `OFFSET`?"

  </details>
- **NICE** — Counting is expensive: exact total vs capped estimate, and the product consequence ("1,000+")

  <details><summary><strong>Answer</strong></summary>

  Why an exact count costs what the page costs, and the "1,000+" concession, are owned by "Facet counts" in the search topic; what this bullet adds is that the concession lives in the API contract rather than in the UI. `PagedProducts` returns `total_estimate` and not `total`, so the field name itself tells an integrator the number is approximate and stops anyone building a page-count widget on it — the failure to avoid is a contract that says `total` and quietly means something else. It also pairs with keyset pagination: a cursor API has no page count to display in the first place, so the two decisions defend each other rather than each needing its own argument. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-api-returns-total_estimate-capped-at-1000-rather-than-an-exact-count-why-and-how-would-you-produce-the-estimate) — "The API returns `total_estimate` capped at 1,000 rather than an exact count. Why, and how would you produce the estimate?"

  </details>
- **MUST** — Idempotency keys on [POST](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP POST — HTTP method that submits data to a server to create or process a resource"): storage, [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"), replaying the stored response, and why the database unique constraint is the guarantee and the cache is not

  <details><summary><strong>Answer</strong></summary>

  An idempotency key lets a client retry a `POST` without creating a second thing: the server stores the key with the request fingerprint and the response, and a replay returns the stored response rather than executing again. On `POST /v1/connections` the header is required, because a double-submitted connection request must not create two threads and must not bill the vendor twice. The part I would insist on is that the `idem:*` entry in `redis-cache` is a fast path and not the guarantee — the guarantee is `UNIQUE (retail_group_id, idempotency_key)` on `connection_request`, because Redis is expendable by design and a cache that loses a key would otherwise lose the protection with it. The awkward cases are the ones worth naming: a retry arriving while the first is still in flight, which needs the insert to be the lock rather than a check-then-act, and a key replayed with a different body, which is a client bug and deserves a 422 rather than a silent overwrite. **Deeper:** [interview-questions.md](./interview-questions.md#q2-post-v1connections-requires-an-idempotency-key-implement-it-properly--what-are-the-failure-cases) — "`POST /v1/connections` requires an `Idempotency-Key`. Implement it properly — what are the failure cases?"

  </details>
- **MUST** — Status codes and error contracts; machine-readable error codes

  <details><summary><strong>Answer</strong></summary>

  Status codes carry the class of outcome and nothing more — 400 for a malformed request, 401 versus 403 for "who are you" versus "not yours", 409 for a state conflict, 422 for a body that parsed but violated a rule, 429 with `Retry-After` for a quota, 503 with a retryable hint for a Mongo primary election. The body has to carry a stable machine-readable code beside the human message, because the moment a client branches on message text you can never rewrite the message. For a marketplace there is a second rule that matters more than tidiness: an error must not leak existence. A vendor probing a retail group's shortlist id should get the same response whether it exists or not, or the error contract becomes an enumeration oracle for exactly the data the threat model says must never leave.

  </details>
- **NICE** — Filtering and faceting as an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") surface; refusing query shapes that cannot be served — a product constraint that buys a performance guarantee

  <details><summary><strong>Answer</strong></summary>

  The performance argument is owned above by "Faceted search as a performance problem" in Indexing and "Filter selectivity" in Search; the API-side addition is how a refusal is expressed. The filter surface is a closed set of named parameters — `category`, `country`, `deployment_model`, `price_max`, `integrations[]` — rather than a generic query language, which is what makes an unservable shape describable at all, and the refusal is a 422 carrying a machine-readable code that names the missing `category` rather than a slow success or a timeout. The rule I would generalise is that an API is allowed to refuse a shape it cannot serve inside its stated latency, and that refusing loudly at the contract is far better than degrading quietly under it. **Deeper:** [interview-questions.md](./interview-questions.md#q2-refusing-an-uncategorised-query-with-more-than-two-facet-predicates-is-a-product-constraint-bought-for-a-performance-guarantee-defend-that-and-tell-me-when-that-trade-is-wrong) — "Refusing an uncategorised query with more than two facet predicates is a product constraint bought for a performance guarantee. Defend that, and tell me when that trade is wrong."

  </details>
- **MUST** — Rate limiting and quotas: per-subject vs per-IP, token bucket vs sliding window, business limits vs infrastructure limits

  <details><summary><strong>Answer</strong></summary>

  Rate limiting has two jobs here and they need different mechanisms. Infrastructure limits live at [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway") — per-subscription quotas and a per-IP burst — and protect the platform from volume; business limits live in the services against `redis-cache` and protect the marketplace from behaviour, as a token bucket keyed on `org_id` and `sub`. The limits that matter are not request rates at all: twenty connection requests per retail group per day, two hundred listing writes per vendor per hour, five imports per vendor per day. An IP-based limit cannot express any of those, because the abuse is authenticated and comes from a legitimate office. Token bucket over sliding window because bursts are normal in this workload, and the decision that has to be made explicitly is what happens when Redis is gone: writes fail closed, reads fail open, which trades a little abuse exposure on browse for never blocking the buyer's critical path.

  </details>
- **NICE** — Contract testing against the OpenAPI document; no private admin backdoor API

  <details><summary><strong>Answer</strong></summary>

  The testing half is answered under "Functional/contract tests against the OpenAPI schema" in Testing Practice; what belongs here is the design decision those tests are checking. The admin console is a static single-page application served from `blob-media`, and it calls the same `/v1/admin/*` surface as everything else, so no admin capability exists that the public contract does not already describe, gate and test. The cost is a chattier UI on entity screens that join across services, and it is paid deliberately: a private admin backend is exactly the surface that never gets the contract test, the router-level account-type dependency or the rate limit, because it was "internal". **Deeper:** [interview-questions.md](./interview-questions.md#q3-the-admin-console-is-a-static-single-page-application-calling-the-same-public-api-with-no-dedicated-backend-defend-the-chattiness-and-say-when-you-would-add-an-aggregate-endpoint) — "The admin console is a static single-page application calling the same public API, with no dedicated backend. Defend the chattiness, and say when you would add an aggregate endpoint."

  </details>
- **NICE** — Request correlation ids and their propagation obligations

  <details><summary><strong>Answer</strong></summary>

  The logging and trace-propagation mechanics belong to Observability, under "Structured logging" and "Distributed tracing" there. This topic's share is the API obligation: APIM forwards `x-request-id` to the pod, a service accepts one if present and mints one if not, echoes it on the response and includes it in the error body — so a vendor integration reporting a failed publish can quote an identifier that finds the request across nine deployments. The rule that makes it worth anything is that propagation is an obligation on every outbound hop rather than a field on an inbound log line: a Celery task or a Service Bus message that drops the correlation id breaks the chain at exactly the point where an asynchronous failure is hardest to reconstruct.

  </details>

## 4. Authentication: OAuth 2.0, OIDC and JWT

**Backs:** implemented [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") and [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") authentication for vendors and retailers.

- **MUST** — OAuth2 roles, grant types and their fit: authorization code + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") for human/public clients, client credentials for machine integrations; why implicit and password grants are dead

  <details><summary><strong>Answer</strong></summary>

  OAuth2 separates four roles — resource owner, client, authorization server, resource server — and the grant is just how a client proves it may act. Here `identity-service` is the only authorization server, and two grants cover everything: authorization code with PKCE for the marketplace web app and the admin console, which are public clients that cannot hold a secret, and client credentials for vendor system integrations pushing catalog data, which are confidential and act as themselves rather than for a user. PKCE matters because a public client's redirect can be intercepted; the code verifier makes a stolen code useless. Implicit is dead because it puts a token in a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web"), and the password grant is dead because it teaches users to hand their credentials to third-party software and makes federation impossible — and neither is a loss for a system that already has a browser redirect flow. **Deeper:** [interview-questions.md](./interview-questions.md#q1-explain-the-oauth-20-authorization-code-flow-with-proof-key-for-code-exchange-and-why-the-web-clients-here-use-it) — "Explain the OAuth 2.0 authorization code flow with Proof Key for Code Exchange, and why the web clients here use it."

  </details>
- **MUST** — [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") vs OAuth2: authentication vs delegated authorization, id_token vs access_token, scopes vs claims

  <details><summary><strong>Answer</strong></summary>

  OAuth2 answers "may this client do this", and it deliberately says nothing about who the user is; OIDC is the thin identity layer on top that answers "who signed in", with an `id_token` for the client and a `/userinfo` endpoint. The practical distinction is which token goes where: the `id_token` is for the client that requested the login and must never be sent to an API, while the `access_token` is for the resource server and carries scopes. Scopes are permissions the client was granted; claims are facts about the subject — in this design `act`, `org_id` and `roles[]` are claims and `vendor:write`, `retailer:read`, `connection:write` are scopes, and conflating them is how you end up with an authorization model that cannot express "this user's org" at all. Using OAuth2 alone for login is the classic mistake: a valid access token proves delegation, not authentication.

  </details>
- **MUST** — JWT anatomy: header/kid, registered claims, [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") vs HS256, the alg=none and algorithm-confusion attacks, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") publication and key rotation with overlap

  <details><summary><strong>Answer</strong></summary>

  A JWT is three base64url segments: a header naming the algorithm and `kid`, a payload of claims, and a signature. Here they are RS256, so `identity-service` signs with a private key in Key Vault and every service verifies with a public key from `/.well-known/jwks.json` — asymmetric specifically so that a verifier cannot mint tokens, which HS256 with a shared secret across six services would allow. Two attacks are worth naming because they are library bugs rather than crypto failures: `alg=none`, where a verifier trusts the token's own claim that it is unsigned, and algorithm confusion, where an RS256 public key is fed to an [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key") verifier as a secret. The defence is to pin the expected algorithm rather than read it from the token. Key rotation is a 90-day cycle with both keys published through the overlap, and the trap this design flags explicitly is that APIM caches the JWKS on its own schedule independently of the `authz:jwks` key in `redis-cache`, so the overlap window has to be strictly longer than the slower cache. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-gateway-caches-the-signing-key-set-on-its-own-schedule-and-the-application-caches-it-separately-what-breaks-during-a-key-rotation-and-how-do-you-fix-it) — "The gateway caches the signing key set on its own schedule, and the application caches it separately. What breaks during a key rotation, and how do you fix it?"

  </details>
- **MUST** — Local verification vs introspection, and the latency consequence of choosing (a per-request round trip adds to every hop)

  <details><summary><strong>Answer</strong></summary>

  Local verification checks a signature against a cached public key and reads the claims; introspection asks the authorization server, per request, whether a token is still good. Introspection gives you immediate revocation and centralised policy, and it costs a network round trip on every hop — 15 to 30 ms added to every column of the latency budget, and a dependency that turns `identity-service` into a synchronous single point of failure for the whole platform. This design verifies locally against a JWKS cached in `redis-cache`, which is exactly why authorization costs about 1 ms in the search budget and why the p95 target is reachable at all. The price is paid honestly elsewhere: revocation is bounded by the 15-minute access-token lifetime, with a small Redis denylist of revoked `jti` values for the cases where fifteen minutes is too long. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-in-a-json-web-token-here-and-what-does-verifying-it-locally-against-a-cached-key-set-buy-over-calling-an-introspection-endpoint) — "What is in a JSON Web Token here, and what does verifying it locally against a cached key set buy over calling an introspection endpoint?"

  </details>
- **MUST** — Access-token lifetime as the revocation window; refresh rotation, one-time jti, reuse detection revoking the whole chain, denylists for the urgent case

  <details><summary><strong>Answer</strong></summary>

  Once you verify locally, the access-token lifetime *is* the revocation window — fifteen minutes here — and everything else is about making that window survivable. Refresh tokens live 30 days and rotate: each use issues a new one and marks the old `jti` spent, so presenting a spent `jti` means the chain was replayed, which revokes the entire chain and raises an alert rather than merely refusing the request. That converts a stolen refresh token from silent persistent access into a detectable event, at the cost of false positives when a client races itself. For the case fifteen minutes cannot cover — a vendor suspended for fraud — `identity-service` publishes `identity.user.deactivated` and services consult a small denylist of revoked `jti` values in `redis-cache`, which is the deliberate exception rather than the rule, because a denylist consulted on every request is introspection wearing a different hat. **Deeper:** [interview-questions.md](./interview-questions.md#q2-access-tokens-live-15-minutes-so-revocation-is-bounded-by-that-a-vendor-is-suspended-for-fraud-and-must-lose-access-now-walk-me-through-it) — "Access tokens live 15 minutes, so revocation is bounded by that. A vendor is suspended for fraud and must lose access now. Walk me through it."

  </details>
- **NICE** — Token storage in a browser: HttpOnly/Secure/SameSite cookies vs localStorage, CSRF, and the trade-offs

  <details><summary><strong>Answer</strong></summary>

  `localStorage` is readable by any script on the origin, so one cross-site scripting flaw or one compromised front-end dependency exfiltrates the token; an `HttpOnly` cookie is not reachable from script at all, which downgrades that whole class of attack from stealing the credential to riding the session. That is the trade, because a cookie is sent automatically and therefore reintroduces cross-site request forgery, answered by `SameSite` plus an origin check rather than by putting a token back in a header. Here the refresh token lives in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie scoped to the API origin while the fifteen-minute access token is held in memory by the single-page application — so the long-lived credential is the one script cannot read, and the one script can read dies on reload. `Lax` rather than `Strict` because the redirect back from `identity-service` is a top-level navigation that `Strict` would strip the cookie from, which is the detail that turns a correct-looking setting into a broken login.

  </details>
- **MUST** — Client secret handling: Argon2id hashing, rotation, never in a repo

  <details><summary><strong>Answer</strong></summary>

  A client secret is a credential, so it is hashed the way a password is — Argon2id in `oauth_client.client_secret_hash` — because the authorization server never needs to read it back, only to verify a presentation. Rotation has to be supported by allowing two live secrets per client at once, or every rotation is an outage for the vendor integration holding the old one. It never enters the repository, an image or a CI variable: the integrations hold their own, and everything the platform itself needs lives in Key Vault, reached by workload identity rather than by a connection string. The related rule is that a public client has no secret at all — the marketplace web app and admin console are authorization-code-plus-PKCE precisely because a secret shipped to a browser is not a secret, and pretending otherwise is worse than having none.

  </details>
- **MUST** — Two-layer verification: an edge gateway is a filter, the service is the authority; both must be cheap enough to do per request

  <details><summary><strong>Answer</strong></summary>

  APIM validates the signature, expiry and audience at the edge, so a forged or expired token never reaches the cluster and the cheapest possible rejection happens furthest out. Each service then validates again locally and applies its own scope and tenant rules, because the edge is a filter and never the authority — anything that can reach a pod directly, a misrouted internal call or a future workload in the namespace, would otherwise be trusted for free. The reason both layers are affordable is that neither makes a network call per request: the edge uses its own cached JWKS and the service uses `authz:jwks` in `redis-cache`. That is the assumption the whole latency budget rests on, and it is also the assumption that makes the two caches diverge during a key rotation, which is the one flagged risk in this arrangement.

  </details>

## 5. Authorization and Multi-Tenancy

**Backs:** "catalog and connection APIs stayed behind the right account type" — and everything that check alone does not cover.

- **MUST** — Three distinct checks: account type (coarse), role → scope ([RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually")), tenant scope ([ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles")), and why any one alone is insufficient

  <details><summary><strong>Answer</strong></summary>

  The three are different questions and each one alone is a hole. Account type from the `act` claim is coarse — a retailer token cannot reach `/v1/vendor/*` whatever its scopes — and it is the check the brief actually named; role to scope is what separates a vendor `viewer` from an `owner`, and a `category_manager` who may open connections from a group admin who may add stores. Tenant scope is the one that matters most, because `act = vendor` says you are a vendor and not *which*, so every query on an org-owned table is filtered on `org_id` from the token. Drop any one and the hole is concrete: account type alone lets any vendor read any vendor's drafts, roles alone let a `category_manager` read another chain's shortlists, tenant scope alone lets a viewer write. The cost is that authorization is never a single decorator, which is exactly why the third check lives in the repository layer rather than in each endpoint. **Deeper:** [interview-questions.md](./interview-questions.md#q1-distinguish-authentication-role-based-access-control-and-attribute-based-access-control-and-name-the-three-checks-this-system-runs) — "Distinguish authentication, role-based access control and attribute-based access control, and name the three checks this system runs."

  </details>
- **MUST** — Broken object-level authorization (IDOR/BOLA) as the dominant API vulnerability

  <details><summary><strong>Answer</strong></summary>

  Broken object-level authorization is the case where the endpoint checks that you are authenticated and authorised for the *route* and then trusts the identifier in the path. It is the top API vulnerability because it needs no exploit, no tooling and no unusual traffic — a category manager changes one UUID in a URL and reads another chain's shortlist, and every log line looks legitimate. The structural fix is that no repository method takes an id without also taking the tenant, so "fetch shortlist X" does not exist and "fetch shortlist X belonging to group Y" is the only shape available; the lookup returning empty is then indistinguishable from not found, which also closes the enumeration oracle. Unguessable identifiers are worth having and are not a control — they are why this schema uses UUIDs rather than sequential keys, but the check is what actually protects the row.

  </details>
- **MUST** — Enforcing the tenant filter in exactly one place (a session/repository-level filter) rather than per endpoint — a per-endpoint check works until someone adds an endpoint

  <details><summary><strong>Answer</strong></summary>

  A per-endpoint tenant check is a control that works until the day someone adds an endpoint, and that day always comes — usually as a small admin convenience under deadline. So the filter lives in one place, a SQLAlchemy session-level filter applied by the repository layer, and the endpoint cannot forget it because the endpoint never expresses it. The cost is that the one place is now a very expensive thing to get wrong and a slightly magical thing to read, and that any deliberate bypass has to be explicit — platform admins bypass it by asking for it, and every bypass writes an `audit_event`. The property I would actually assert in tests is not "the filter is applied" but its consequence: for every org-owned repository method, a caller from another org gets an empty result.

  </details>
- **MUST** — [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") Row-Level Security: how it works, and the pooled-connection trap (SET vs SET LOCAL) that makes it silently a no-op — why it was rejected here as the primary control and what the compensating control must then prove

  <details><summary><strong>Answer</strong></summary>

  Row-Level Security puts the predicate in the database, so a query with no `WHERE` still cannot see another tenant's rows — genuinely stronger than an application filter, because it survives a developer's mistake. It is rejected here as the primary control for a specific reason: `catalog-service` reads a replica through a pooled connection under a shared role, and [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") depends on a per-request session variable. `SET` persists for the life of the pooled connection, so it leaks to whoever gets that connection next, and `SET LOCAL` only lives inside a transaction, which means every read must be wrapped in one. Get that wrong and the policy is silently a no-op — worse than not relying on it, because you believe you are protected. Having rejected it, the compensating control has to prove itself: one auditable filtering layer plus a test asserting cross-tenant reads return empty for every org-owned repository method. **Deeper:** [interview-questions.md](./interview-questions.md#q2-postgresql-row-level-security-is-the-stronger-mechanism-for-tenant-isolation-and-this-design-rejects-it-as-the-primary-control-defend-that) — "PostgreSQL Row-Level Security is the stronger mechanism for tenant isolation, and this design rejects it as the primary control. Defend that."

  </details>
- **MUST** — Tests that assert cross-tenant reads return empty for every repository method

  <details><summary><strong>Answer</strong></summary>

  Tenant isolation is a silent control: when it breaks nothing errors, nothing pages, and the data simply flows the wrong way. So the test has to assert the absence directly — seed two vendors and two retail groups, then for every org-owned repository method call it as org A for org B's row and assert empty, not "not equal". Making that exhaustive rather than exemplary is the point: a parametrised sweep over the repository registry fails when someone adds a method and forgets, which a hand-written test per endpoint never does. And the test has to be shown to fail — remove the session filter and confirm the suite goes red, because a security test that has never failed has not been demonstrated to test anything. **Deeper:** [interview-questions.md](./interview-questions.md#q2-how-do-you-test-a-control-whose-failure-is-silent--the-tenant-filter-the-projection-the-audit-write-an-alert-rule) — "How do you test a control whose failure is silent — the tenant filter, the projection, the audit write, an alert rule?"

  </details>
- **MUST** — Marketplace-specific authorization: asymmetric visibility between two sides, a vendor never enumerating the buyer directory, drafts never projected

  <details><summary><strong>Answer</strong></summary>

  A marketplace is not symmetric, and modelling it as "both sides are tenants" misses the actual threat. A vendor may see a retail group's identity only through a `connection_request` that group initiated — there is no vendor-side endpoint that returns `retail_group`, `store` or `retailer_user` data at all, because a vendor who can enumerate the buyer directory has been handed a sales list and the buyer side leaves. Drafts are the mirror case: they are never projected into `product_listing_facets`, so a competitor cannot see what is coming. What makes this hard to hold is that it is a requirement about what does *not* exist, and absences are not tested by accident — the check is a contract test over the OpenAPI document asserting no vendor-scoped response schema carries a retailer field, which fails when someone adds the convenient endpoint. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-threat-model-says-a-vendor-enumerating-the-retailer-directory-would-kill-the-marketplace-how-is-that-prevented-and-how-do-you-test-for-an-absence) — "The threat model says a vendor enumerating the retailer directory would kill the marketplace. How is that prevented, and how do you test for an absence?"

  </details>
- **NICE** — Admin bypass paths and auditing every one of them

  <details><summary><strong>Answer</strong></summary>

  That every bypass is explicit and writes an `audit_event` is answered above, under "Enforcing the tenant filter in exactly one place" and "Scope design". What this bullet adds is the shape a safe bypass has to take: it is an argument on the individual repository call, not a session-wide flag or a role check made somewhere earlier, because a flag set once and read later is indistinguishable from the filter simply not being applied. The audit record is then the compensating control, and it only compensates if someone reads it — an operator opening one retail group is routine, the same operator opening two hundred in an hour is the signal, which means the bypass audit needs a query somebody actually runs rather than a table that merely exists. **Deeper:** [interview-questions.md](./interview-questions.md#q3-platform-admins-bypass-tenant-scoping-entirely-design-that-so-it-is-safe) — "Platform admins bypass tenant scoping entirely. Design that so it is safe."

  </details>
- **MUST** — Scope design: read vs write, org-scoped vs platform-scoped

  <details><summary><strong>Answer</strong></summary>

  Scopes should be few, coarse and named for what the caller does, not for endpoints — `vendor:read`, `vendor:write`, `retailer:read`, `retailer:admin`, `connection:write`, `platform:admin` — because a scope per route is a permission model nobody can reason about and every new endpoint invents one. Separating read from write is what lets a vendor integration hold client credentials that can publish nothing, and separating org-scoped from platform-scoped is what keeps `platform:admin` a distinct and visible thing rather than a role that quietly accumulates. Platform scope is the dangerous one because it deliberately bypasses tenant filtering, so it carries no `org_id`, it is held only by `platform_user` rows, and every bypass writes an `audit_event`. My rule is that a scope is worth minting when a real principal should hold one side and not the other; otherwise it is a role, and roles map to scopes at token issue. **Deeper:** [interview-questions.md](./interview-questions.md#q3-platform-admins-bypass-tenant-scoping-entirely-design-that-so-it-is-safe) — "Platform admins bypass tenant scoping entirely. Design that so it is safe."

  </details>

## 6. PostgreSQL Data Modelling

**Backs:** built PostgreSQL schemas for vendors, retailers and product listings.

- **MUST** — Normalisation, and denormalisation as a deliberate read-model decision

  <details><summary><strong>Answer</strong></summary>

  Normalisation means each fact has one home, so an update has one place to go and cannot leave two rows disagreeing — that is why `product`, `vendor` and `product_category` are properly normalised and why the admin workspace can edit them without a fan-out. Denormalisation is the deliberate opposite, and it is only defensible when the copy has a single writer and a rule for staying current. Here that shows up twice: `product_listing_facets` copies `vendor_id`, `status` and `published_at` so the search query touches one relation, and `connection_request.vendor_id` is copied from `product` so a vendor's connection list is served by `idx_conn_vendor` with no join. What it costs is that both copies can go stale, so both need an owner — the projection has `indexer-worker` and a lag SLI, and the connection copy is written once at creation and never changes, which is the easiest kind of denormalisation to defend.

  </details>
- **MUST** — Keys: uuid vs bigint, natural vs surrogate, uniqueness as an invariant

  <details><summary><strong>Answer</strong></summary>

  A `bigint` identity key is smaller, sorts in insertion order and keeps a B-tree dense; a random UUID is four times wider in every index that references it and scatters inserts across the tree, which costs write amplification and cache locality. This schema uses `uuid` everywhere anyway, and the reason is specific to a marketplace: sequential ids are an enumeration surface and a disclosure — a vendor can count how many listings the platform has, and a leaked identifier in a URL invites the neighbouring one to be tried. At 40,000 listings and roughly two writes a second, the cost is invisible; at a hundred million rows a day I would want `uuidv7` or a bigint plus an external identifier. The separate rule is that a surrogate key is not a substitute for the natural uniqueness — `UNIQUE (vendor_id, slug)` and `UNIQUE (retail_group_id, external_ref)` are the invariants, and the `uuid` is just how rows point at each other.

  </details>
- **MUST** — Constraints as correctness rather than convention: unique, partial unique (bill a connection at most once), check, exclusion, FK actions

  <details><summary><strong>Answer</strong></summary>

  A constraint in the schema is a guarantee; the same rule in application code is a convention that holds until a retry, a race or a second writer. The clearest example here is `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge` — a partial unique index that makes "a connection bills at most once" true no matter how many times an at-least-once event is delivered, which is precisely the case retry logic gets wrong under concurrency. `UNIQUE (retail_group_id, idempotency_key)` does the same job for duplicate threads. Check constraints carry the small truths, like a price tier's `max_stores` exceeding its `min_stores`; foreign keys carry the shape, and their `ON DELETE` action is a design decision rather than a default — restrict on anything a vendor owns and cascade only where the child genuinely has no independent life. The cost is that a constraint violation surfaces as a database error you have to translate into a decent API response.

  </details>
- **NICE** — Money: integer minor units plus an explicit [ISO-4217](https://www.six-group.com/en/products-services/financial-information/data-standards.html "ISO 4217 — Standardizes three-letter currency codes for unambiguous monetary values") currency, never float

  <details><summary><strong>Answer</strong></summary>

  Binary floating point cannot represent most decimal fractions exactly, so a price stored as a float accumulates error as soon as it is summed or compared, and the failure surfaces as a total that is a cent out with no bug to point at. So `product_price_tier.price_minor` is a `bigint` of minor units with an explicit `currency char(3)`, and every monetary column in the schema follows the same rule. The currency has to travel with the amount rather than being implied by the vendor's country or the request locale, because the comparison view sorts and ranges price tiers across vendors and an unlabelled 4900 is not a price. What it costs is conversion at every boundary and the discipline never to introduce a `numeric` column "just for this report". **Deeper:** [interview-questions.md](./interview-questions.md#q2-monetary-values-are-integer-minor-units-with-an-explicit-currency-price-tiers-are-relational-and-free-form-pricing-prose-stays-in-mongo-walk-me-through-each-of-those-three-decisions) — "Monetary values are integer minor units with an explicit currency, price tiers are relational, and free-form pricing prose stays in Mongo. Walk me through each of those three decisions."

  </details>
- **MUST** — Read models / projection tables: what they copy, who is allowed to write them, and why the hot query then touches one relation and never joins

  <details><summary><strong>Answer</strong></summary>

  A read model is a table that exists to answer one query shape, populated by copying from the system of record. `product_listing_facets` copies the facetable subset of the Mongo document plus `vendor_id`, `status`, `published_at` and a `search_vector`, and it is written only by `indexer-worker` and read only by `catalog-service`. Two rules make that safe rather than a second source of truth: exactly one writer, and a `source_revision_id` so the row knows which revision it reflects and can ignore an older event. The payoff is that the hot query touches one relation and never joins — no join to `product` for status, none to `vendor` for the name — which is what lets a partial index carry the whole predicate. The cost is real and stated: a projection pipeline, a lag SLI, a reconciliation job, and a listing that is seconds stale for retailers. **Deeper:** [interview-questions.md](./interview-questions.md#q1-product_listing_facets-copies-vendor_id-status-and-published_at-from-product-why-deliberately-denormalise-and-what-is-the-rule-for-when-that-is-acceptable) — "`product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product`. Why deliberately denormalise, and what is the rule for when that is acceptable?"

  </details>
- **MUST** — jsonb for open attributes: indexing it, statistics, TOAST, write amplification

  <details><summary><strong>Answer</strong></summary>

  `jsonb` is the right tool when the key set is genuinely open and the queries over it are containment rather than arithmetic — which is exactly `product_listing_facets.facets`, holding whatever the category's schema declares facetable. The index that makes it usable is `GIN (facets jsonb_path_ops)`, smaller and faster for containment than the default operator class at the price of supporting only `@>`. Three costs are worth stating rather than discovering: the planner's selectivity estimates for `jsonb` containment are poor, so a predicate it thinks is selective can wreck a plan downstream; a row wider than about two kilobytes goes to TOAST, making a large document an out-of-line read; and the column is rewritten whole on every update. That last one is why the authoring surface lives in Mongo and only the facetable subset is projected here — a high-churn attribute inside a wide document would be write amplification on the same table that serves search.

  </details>
- **NICE** — Arrays vs join tables; containment queries and their selectivity problems

  <details><summary><strong>Answer</strong></summary>

  A junction table is the normalised answer and gives you referential integrity, per-value statistics and a join the planner can estimate; an array column gives you one relation, no join, and a `GIN` containment index. `product_listing_facets.country_coverage` and `integrations` are arrays precisely because that table is a read model whose whole purpose is that the hot query touches a single relation — a junction table would put back the join the projection exists to remove, and there is nothing to enforce integrity against anyway, since the permitted values come from the category's facet schema rather than from a table. What it costs is the estimation problem owned above by "Bitmap index scans": there are no per-element statistics for `text[]`, so containment selectivity is guessed badly at high cardinality. In the normalised half of the schema I would not make the same trade — `store` is a table rather than an array on `retail_group`, because stores have identity, a lifecycle and their own uniqueness constraint. **Deeper:** [interview-questions.md](./interview-questions.md#q3-retailers-already-run-enterprise-resource-planning-and-inventory-systems-integrations-text-is-a-filterable-facet-what-does-taking-that-seriously-demand-of-the-model) — "Retailers already run enterprise resource planning and inventory systems. `integrations text[]` is a filterable facet. What does taking that seriously demand of the model?"

  </details>
- **NICE** — Declarative range partitioning by month on unbounded tables; pruning, detach-to-archive as a metadata operation instead of a long DELETE

  <details><summary><strong>Answer</strong></summary>

  `audit_event` and `connection_message` are the only two tables here that grow without bound, and both are declaratively range-partitioned by month on their timestamp. Two properties pay for that immediately: the planner prunes partitions the query's time predicate cannot touch, so a thread's recent messages scan one small B-tree rather than the whole history, and inserts land in the current partition where the index stays cache-resident. The one that matters most operationally is retention — dropping data past the window is `DETACH PARTITION` plus an archive to blob, a metadata operation, where the equivalent `DELETE` is a long transaction generating dead tuples that autovacuum then has to chase across a table still serving reads. What it costs is that a unique constraint now has to include the partition key, and that a query with no time predicate scans every partition instead of one index. **Deeper:** [interview-questions.md](./interview-questions.md#q3-audit_event-and-connection_message-grow-without-bound-explain-the-partitioning-strategy-and-what-changes-about-it-at-ten-times-the-volume) — "`audit_event` and `connection_message` grow without bound. Explain the partitioning strategy, and what changes about it at ten times the volume."

  </details>
- **NICE** — Append-only tables and revoked UPDATE/DELETE grants

  <details><summary><strong>Answer</strong></summary>

  Append-only is a grant rather than a convention: the application role on `audit_event` holds `INSERT` and `SELECT` and no `UPDATE` or `DELETE`, so a bug, a careless migration or a compromised service cannot rewrite history even where the code would happily try. That is the difference between a table nobody is supposed to modify and one nobody can, and it is checkable — the test is the role connecting and being refused, not a reviewer noticing. The cost lands on retention, because you have given up the mechanism that would normally trim the table, and that is answered by the monthly partitioning above: `DETACH` is a schema operation rather than a use of the `DELETE` grant the role does not have. Why the writes are asynchronous, and why that is a constraint rather than an optimisation, belongs to "Audit trail" in Security Beyond Authentication.

  </details>
- **MUST** — Transactions and isolation levels; [MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row"), locking, deadlocks, SKIP LOCKED

  <details><summary><strong>Answer</strong></summary>

  MVCC means a writer never blocks a reader: an update leaves the previous row version in place and writes a new one, and each reader continues to see whichever version its snapshot began with — which is why a projection upsert does not stall browse. Read Committed takes a fresh snapshot per statement, so two statements in one transaction can disagree; Repeatable Read holds one snapshot and will abort you with a serialization failure instead, which is fine as long as the caller retries. The default is right for almost everything here, and the places that need more use a constraint rather than a higher isolation level — the connection uniqueness is enforced by the unique index, not by hoping two concurrent transactions serialise. Deadlocks come from two transactions taking the same locks in different orders, so the rule is a consistent lock ordering and short transactions; and `SELECT ... FOR UPDATE SKIP LOCKED` is how a relay or a queue-shaped table hands rows to competing workers without them fighting over the same row.

  </details>
- **NICE** — Sharding: what it actually costs, and the evolution triggers that justify it (and the cheaper move that usually comes first)

  <details><summary><strong>Answer</strong></summary>

  Sharding buys write throughput and working-set capacity, and it costs cross-shard joins, cross-shard transactions, a rebalancing operation and a routing layer every query now passes through — none of it cheap to reverse. `postgres-core` is around 110 GB at year five against a roughly two-write-per-second peak, so the triggers here are stated as numbers rather than instincts: shard only above about 2,000 sustained write transactions per second or a working set near 1 TB. The cheaper move that comes first is worth naming because it usually removes the reason — `audit_event` is about 25 GB and most of the growth, so moving it to blob-backed cold storage buys years of headroom for a fraction of the disruption. Vertical scaling plus a read replica is the honest answer for the whole modelled horizon, and I have not operated a sharded PostgreSQL in production; what I have done is the partitioning and replica work that defers the question.

  </details>

## 7. Indexing and Query Performance

**Backs:** optimized [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") queries and indexes for catalog search and listing filters.

- **MUST** — EXPLAIN (ANALYZE, BUFFERS): scan and join types, estimated vs actual rows, what a bad estimate does downstream

  <details><summary><strong>Answer</strong></summary>

  `EXPLAIN` gives the plan, `ANALYZE` runs it and adds actual rows and timings, and `BUFFERS` tells you whether the pages came from shared buffers or the disk — which is what separates a genuinely fast query from one that was warm when you measured it. The first thing I look at is not the total time but estimated versus actual rows on the deepest node, because a bad estimate is what makes every choice above it wrong: the planner picks a nested loop for the fifty rows it expected and gets fifty thousand. After that, the scan and join types, and whether a bitmap heap scan reports lossy blocks. For this schema the specific thing I would be looking for is whether the `GIN` indexes on `country_coverage`, `integrations` and `facets` combine into a bitmap `AND` or collapse into a sequential scan on `product_listing_facets`, because the whole search latency figure rests on that and the design flags it as unverified. **Deeper:** [interview-questions.md](./interview-questions.md#q1-you-are-handed-a-slow-query-what-does-explain-analyze-buffers-tell-you-and-what-do-you-look-at-first) — "You are handed a slow query. What does `EXPLAIN (ANALYZE, BUFFERS)` tell you, and what do you look at first?"

  </details>
- **NICE** — Planner statistics, selectivity, n_distinct, extended statistics, ANALYZE

  <details><summary><strong>Answer</strong></summary>

  That a bad estimate is what wrecks a plan is answered above under "EXPLAIN (ANALYZE, BUFFERS)" and "Bitmap index scans"; the mechanism underneath is a sample of the table held in `pg_statistic` — most-common values, a histogram and `n_distinct` — refreshed by `ANALYZE` and by autovacuum. Two failure modes matter for this schema: `n_distinct` is extrapolated from a sample and goes badly wrong on a large skewed column, and the planner assumes predicates are independent, so `category_slug = 'pos' AND deployment_model = 'saas'` multiplies two selectivities that are in fact correlated and underestimates the result by an order of magnitude. `CREATE STATISTICS` on a correlated column pair addresses the second and a raised statistics target the first. Neither helps the `text[]` and `jsonb` containment estimates the catalog search actually depends on, which is why the design constrains the query shape instead of trying to tune its way out.

  </details>
- **MUST** — Index types and their jobs: B-tree, composite (column order, leading-column rule), partial, covering/index-only scans, [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") vs [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints"), jsonb_path_ops, array containment, tsvector full text, [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables")

  <details><summary><strong>Answer</strong></summary>

  A B-tree answers ordered and range questions on a scalar and is what `idx_plf_browse` and `idx_plf_price` are; in a composite index only a leading-column prefix is usable, which is why `(category_slug, published_at DESC, product_id)` serves a category browse and does nothing for a query with no category. A `GIN` index inverts a value into its parts, so it fits arrays, `jsonb` and `tsvector` — the three `GIN` indexes here cover text search, array containment and category-specific facets — at the cost of expensive updates, which is acceptable because a listing is written rarely and read constantly. `GiST` is the one for ranges and exclusion constraints rather than containment. Covering an index so the heap is never touched is the cheapest win available on a hot read path, and `BRIN` is the specialist for a huge, naturally ordered table — `audit_event` by `occurred_at` is the candidate here, though monthly partitioning already does most of that job. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-gin-index-how-does-it-differ-from-a-b-tree-and-where-is-each-one-right-in-this-schema) — "What is a GIN index, how does it differ from a B-tree, and where is each one right in this schema?"

  </details>
- **MUST** — Bitmap index scans: AND vs OR combination, and the degradation to a sequential scan when the planner's selectivity estimate is wrong

  <details><summary><strong>Answer</strong></summary>

  When several indexes are useful for one query, Postgres builds a bitmap from each and combines them — `AND` for intersecting predicates, `OR` for a union — then visits the heap once in physical order, which is why it beats repeated index lookups on a wide result. It is also where the faceted search either works or falls apart. A bitmap `AND` over three selective `GIN` indexes is fast; a bitmap `OR` over unselective ones produces a bitmap so large it goes lossy, degrades to a page-level recheck, and from there the planner is one bad estimate away from choosing a sequential scan. The estimate is the weak link, because selectivity for `text[]` containment and `jsonb_path_ops` is poor at high cardinality. That is exactly why the design refuses to trust its 45 ms figure without an `EXPLAIN (ANALYZE, BUFFERS)` against a seeded 40,000-row table, and why the stated fix is a composite covering index per high-traffic category rather than a bigger instance.

  </details>
- **MUST** — Faceted search as a performance problem: many optional predicates, and the mitigations in order of impact (one denormalised table, a partial index carrying the status predicate, keyset pagination, required category, estimated counts)

  <details><summary><strong>Answer</strong></summary>

  The shape is the problem: free text, a category, two or three array containments, a price ceiling and a deployment model, all optional, which is a different plan every time and no single index that serves them all. The mitigations are ordered by what they actually buy — one denormalised table so the hot query touches a single relation and never joins; a partial index carrying `WHERE status = 'published'`, which holds roughly forty thousand rows instead of fifty-five and removes the predicate from every plan; keyset pagination, so a deep comparison page costs what the first costs; a required category above two facet predicates; and a capped `total_estimate`, because an exact count over a filtered `GIN` scan costs as much as the page. The category requirement is the one to defend explicitly: it is a product constraint bought for a performance guarantee, and it works because it matches how sourcing happens — nobody compares a point-of-sale system against a loyalty engine. What it costs is a query shape the API refuses to serve at all, which is a better failure than one that degrades under load. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-faceted-search-accepts-free-text-a-category-two-or-three-array-containments-a-price-ceiling-and-a-deployment-model-all-optional-walk-me-through-why-that-degrades-and-how-you-fixed-it) — "The faceted search accepts free text, a category, two or three array containments, a price ceiling and a deployment model, all optional. Walk me through why that degrades, and how you fixed it."

  </details>
- **MUST** — Data access patterns and their pathologies: N+1 queries, chatty per-item lookups instead of one bulk $in / IN, SELECT *, implicit casts and functions defeating an index, OR-chains

  <details><summary><strong>Answer</strong></summary>

  N+1 is the dominant one and it hides well: the page looks correct, each query is a millisecond, and the total is two hundred round trips. In this design the detail-hydration path is the place it would appear, which is why the sequence is an `MGET` against `redis-cache` followed by a single bulk `$in` to Mongo for the misses, never a lookup per listing. `SELECT *` is the quiet version — it drags TOASTed `jsonb` off disk and defeats an index-only scan that would otherwise have answered from the index alone. The rest are about accidentally hiding the column from the index: a function or an implicit cast on the indexed side, a leading wildcard, or an `OR` chain that the planner cannot turn into a bitmap and rewrites best as a `UNION`. The way I would catch these is `pg_stat_statements` ordered by total time rather than mean, because N+1 never shows up as a slow query.

  </details>
- **MUST** — Every index is a tax on every write; index bloat, autovacuum, HOT updates

  <details><summary><strong>Answer</strong></summary>

  Every index has to be maintained by every insert, update and delete on the table, so an index added to fix one query slows every write to that relation and enlarges the working set. Postgres softens this with heap-only tuple updates, where a new row version stays on the same page and no index is touched — but only if no indexed column changed and the page has room, which is what `fillfactor` buys on a hot table. Dead versions accumulate until autovacuum reclaims them, and on a table with a heavy update pattern that lags, the index bloats and scans get slower while the row count stays flat. In this schema the write load is small enough that five indexes on `product_listing_facets` are affordable, and the discipline that keeps them cheap is that the two hottest are partial: `WHERE status = 'published'` means drafts and archived rows are never in the index at all, so they cost nothing to maintain and nothing to skip. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-partial-index-and-what-does-idx_plf_browse-specifically-buy-by-carrying-where-status--published) — "What is a partial index, and what does `idx_plf_browse` specifically buy by carrying `WHERE status = 'published'`?"

  </details>
- **MUST** — Connection pooling: server connection limits, pgbouncer pool modes and what each forbids, sizing pod pools so their sum stays under the server limit

  <details><summary><strong>Answer</strong></summary>

  A Postgres connection is a backend process with its own memory, so the server limit is a hard ceiling and exceeding it is a refusal, not a slowdown. The arithmetic that matters is that pods multiply: nine deployments, each autoscaling, each with a pool maximum, and the sum of all maxima has to stay under the Flexible Server limit at the *top* of the autoscaling range, not at the bottom — which is the mistake that only shows up under the load you provisioned for. Async handlers help here, because a pod serving many concurrent requests still only needs a small pool: connections are held for the query, not the request. PgBouncer sits in front for reconnect storms and for pushing the ceiling further, and its pool mode is a contract — transaction mode forbids anything that lives across statements, which means session variables, `SET`, prepared statements and advisory locks, and that is the same property that made RLS unusable on the pooled replica path. **Deeper:** [interview-questions.md](./interview-questions.md#q2-nine-deployments-autoscaling-one-postgresql-flexible-server-with-a-connection-limit-walk-me-through-sizing-the-connection-pools) — "Nine deployments, autoscaling, one PostgreSQL Flexible Server with a connection limit. Walk me through sizing the connection pools."

  </details>
- **MUST** — Read replicas: replica lag as an [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health"), which reads may use one, read-your-writes, and falling back to the primary above a lag threshold

  <details><summary><strong>Answer</strong></summary>

  A replica buys read capacity and an isolation boundary — a heavy catalog query cannot slow the writes — and it costs you a second copy of the truth that is always a little behind. Which reads may use it is a per-path decision, not a global switch: `catalog-service` reads the replica because a listing seconds stale is invisible to a retailer, while every write path and every read that must be read-your-writes goes to the primary. That is why the vendor workspace reads `product` from the primary and the metadata document from Mongo directly, never the projection — a vendor who clicks publish and does not see the change is the one user for whom the lag is glaring. Lag is an SLI with an alert at 30 seconds, and above that threshold `catalog-service` fails back to the primary, which trades elevated primary load for correctness. **Deeper:** [interview-questions.md](./interview-questions.md#q2-catalog-service-reads-a-replica-and-falls-back-to-the-primary-above-thirty-seconds-of-lag-what-does-that-protect-against-what-does-it-not-and-how-would-you-catch-a-read-your-writes-violation) — "`catalog-service` reads a replica and falls back to the primary above thirty seconds of lag. What does that protect against, what does it not, and how would you catch a read-your-writes violation?"

  </details>
- **MUST** — Measuring: pg_stat_statements, auto_explain, a real-volume seeded table before trusting a latency figure

  <details><summary><strong>Answer</strong></summary>

  `pg_stat_statements` is where you start, ordered by total time rather than mean, because the query that costs you most is usually a fast one run two hundred times. `auto_explain` with a duration threshold and `log_analyze` catches the plan that only goes wrong in production — the one that is fine on your data and picks a nested loop on theirs — which is the case you cannot reproduce by asking for the plan yourself. The part people skip is the data: a plan chosen against a thousand seeded rows tells you nothing about forty thousand, because the planner's choice between an index scan and a sequential scan is a function of table size and selectivity. So a latency figure quoted from a development database is not a measurement, and in this design that is not hypothetical — the 45 ms search figure is explicitly held as unverified until it is checked against a seeded, realistically-sized table on the pinned Postgres version.

  </details>

## 8. SQLAlchemy and Alembic

**Backs:** [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") and [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") across the marketplace services.

- **MUST** — Core vs [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries"), and choosing Core where the generated plan matters

  <details><summary><strong>Answer</strong></summary>

  The ORM maps rows to objects and gives you identity, change tracking and relationships, which is what you want for domain writes — publishing a listing, moving a `shortlist_item` to `contacted`, accruing a `billing_charge`. Core is the query builder underneath: no objects, no session bookkeeping, just SQL you can read. The rule I apply is that the ORM is right where the code is about the domain and Core is right where the code is about the plan. In this design that line falls on the catalog search query, which uses Core with hand-written predicates against `product_listing_facets`, because the generated plan is the thing being engineered and burying it behind a repository method means nobody can see what the database was asked to do. The cost of that choice is a query the type checker cannot fully protect and a second style in the codebase, which is why it is one path and not a habit.

  </details>
- **MUST** — Session as unit of work: identity map, flush vs commit, expire_on_commit, session scoped to a request

  <details><summary><strong>Answer</strong></summary>

  The session is a unit of work: it collects changes and writes them at flush, and it holds an identity map so the same row fetched twice in a request is the same object. Flush sends the SQL and takes the locks; commit ends the transaction — the distinction matters because a flush inside a request can hold a row lock far longer than you intended if the transaction stays open. `expire_on_commit` is the setting worth deciding rather than inheriting: left on, touching an attribute after commit issues a fresh `SELECT`, which is a surprise round trip in an async handler and a detached-instance error in the wrong place. Scoping the session to the request is what makes the whole thing coherent — one session, one transaction, opened by a FastAPI dependency and closed by it — and it is also what gives the tenant filter a single place to live. A Celery task gets its own session per task for the same reason.

  </details>
- **MUST** — Lazy loading and the N+1 it creates; selectinload / joinedload / raiseload

  <details><summary><strong>Answer</strong></summary>

  Lazy loading means a relationship is fetched when you touch it, so a loop over thirty listings that reads `product.vendor.legal_name` issues thirty-one queries and nothing in the code looks wrong. It is worse under async, where the implicit lazy load raises rather than quietly working, which is arguably a kindness. The fixes are eager strategies chosen per query rather than per model: `selectinload` for a collection, which issues one extra `IN` query and keeps the row count sane, and `joinedload` for a to-one, which adds a join and avoids the second round trip. The setting I would actually configure is `raiseload` as the default relationship strategy, so an unspecified load is an error at development time rather than a plan surprise in production — that turns an invisible performance defect into a loud one, which is the trade I want.

  </details>
- **MUST** — Async engine and session, asyncpg specifics

  <details><summary><strong>Answer</strong></summary>

  The async engine wraps a driver that speaks the protocol without blocking — asyncpg here — and the important consequence is that everything on the path has to be async too, because one synchronous call stalls the whole loop. asyncpg has its own specifics worth knowing: it prepares statements by default, which is a problem behind a transaction-mode pooler and is why prepared-statement caching has to be turned off there, and its type handling is stricter than psycopg's, so a `jsonb` column or an enum needs an explicit codec rather than a coincidence. Sessions are not shareable across tasks, so anything fanning out has to create its own. What async buys in this system is that a pod serving many concurrent searches needs a small pool, because a connection is held for the query rather than the request — which is what makes the pool arithmetic across nine autoscaling deployments work at all.

  </details>
- **NICE** — Bulk operations: executemany, insert().on_conflict_do_update() for idempotent upserts, returning(), batching projection writes

  <details><summary><strong>Answer</strong></summary>

  The upsert semantics and the batch size are owned by "Idempotent projection" in Polyglot Persistence and "Chunking a large job into bounded tasks" in Celery; what belongs here is the SQLAlchemy mechanism that expresses them. `insert(...).on_conflict_do_update(index_elements=["product_id"], set_=…, where=…)` is one PostgreSQL statement carrying the whole projection write including the stale-revision guard in its `WHERE`, so redelivery is a no-op decided by the database rather than by a read-modify-write the application would have to serialise. `executemany` sends two hundred rows in one round trip instead of two hundred, and `returning()` gives back the rows the statement actually changed — useful precisely here, because those are the cache keys `indexer-worker` then has to purge. The trap worth flagging is that this is Core, not the ORM: nothing passes through the session's identity map, so anything already loaded is stale afterwards.

  </details>
- **MUST** — Repository layer as the single place a tenant filter can be enforced

  <details><summary><strong>Answer</strong></summary>

  The repository is where the tenant filter can be enforced once, because it is the only layer that knows both the query and the caller's `org_id` — a session-level filter applied there means an endpoint cannot forget what it never expresses. That is the whole reason it exists in this design; it is not there to abstract the database, which it does badly, nor so the ORM could be swapped, which will not happen. Two things keep it honest: every method takes the tenant, so "fetch by id" is not an available shape, and the bypass is explicit and audited rather than a flag someone can pass casually. The cost is a chokepoint everyone must go through, including the catalog search that wanted raw Core — which is tolerable only because the projection it reads holds no personal data and is public to any authenticated account type, so it sits outside the filter by design rather than by accident.

  </details>
- **NICE** — Alembic: revision graph, branches and merges, autogenerate's blind spots (server defaults, index changes, enums, data migrations)

  <details><summary><strong>Answer</strong></summary>

  Alembic's history is a directed graph rather than a list — each revision names its `down_revision`, so two branches merged in Git leave two heads and `upgrade head` fails until a merge revision joins them, which is the correct failure and the one people work around by editing a down-revision by hand. Autogenerate is a first draft and not an answer: it misses server defaults, cannot generate a `CREATE INDEX CONCURRENTLY` at all because that must run outside a transaction, handles PostgreSQL enum changes badly, and by definition cannot invent a data migration. With one migration history shared across nine deployments the two-heads case is routine here rather than exotic, so the rules I would hold are that every generated revision is read and edited before it lands, and that a backfill is a job the release triggers rather than a loop inside the migration.

  </details>
- **MUST** — Expand/contract migrations: the previous image must run against the new schema, CREATE INDEX CONCURRENTLY, lock-taking DDL, statement timeouts

  <details><summary><strong>Answer</strong></summary>

  Expand/contract means a schema change is split so that the old and new application versions can both run against the schema at every instant. Expand adds — a nullable column, a new table, a new index built `CONCURRENTLY` so it does not take a write lock — and ships before the code that uses it; the code then backfills and starts writing both; contract drops the old column in a separate merge request at least one release later. The rule that makes it work is that `alembic upgrade head` in the pipeline only ever runs the expand half. What it costs is that a simple rename becomes three releases and a period where two columns hold the same fact. What it buys is that rollback is a redeploy of the previous image, because the previous image can still run against the new schema — and lock-taking DDL under a statement timeout means a migration that cannot get its lock fails the deploy rather than queueing behind a long read and stalling the table. **Deeper:** [interview-questions.md](./interview-questions.md#q2-you-need-to-add-a-non-nullable-column-and-an-index-to-a-table-with-well-over-a-hundred-million-rows-with-no-downtime-walk-me-through-it) — "You need to add a non-nullable column and an index to a table with well over a hundred million rows, with no downtime. Walk me through it."

  </details>
- **MUST** — Why that discipline is what makes rollback possible at all

  <details><summary><strong>Answer</strong></summary>

  Rollback is only a real option if the previous image can run against the current schema, and expand/contract is what guarantees that — so the migration discipline is not tidiness, it is the thing that makes the deploy strategy true. Without it, "roll back" means restoring a database, which at any interesting data volume is an outage measured in hours rather than a redeploy measured in seconds, and you discover that during an incident rather than in a planning meeting. It is also what makes the canary honest: `catalog-service` runs two versions side by side against one `postgres-core` for fifteen minutes, which is only safe because both versions are compatible with the schema by construction. The cost is paid up front and continuously, in three-step changes and in the discipline of landing the contract migration later, which is exactly the kind of cost teams stop paying when nothing has broken recently.

  </details>

## 9. MongoDB and Schemaless Modelling

**Backs:** designed [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") schemas for product metadata so vendors could publish without a fixed column set.

- **MUST** — Document modelling: embed vs reference, the 16 MB limit as a boundary you design away from, media never stored in the document

  <details><summary><strong>Answer</strong></summary>

  Embed what is read together and owned together, reference what has an independent life. A product's `attributes`, `modules`, `integrations` and `compliance` are embedded because they are meaningless apart from the listing and are always fetched with it; the vendor is a reference, because it is a relational entity that Postgres owns. The 16 MB document limit is not a constraint to design up to — it is a signal that a document is a boundary, and if you are approaching it you have modelled an unbounded collection as an embedded array. Here the deliberate line is that media and datasheets never live in the document: `media[].blob_key` points at `blob-media`, so a forty-page [PDF](https://en.wikipedia.org/wiki/PDF "Portable Document Format — Fixed-layout document format for reliable printing and viewing") is a blob read and not a document that has to be parsed on every detail page. The general rule I hold is that a document should be the unit you read and write atomically, and anything that grows without bound belongs somewhere else.

  </details>
- **MUST** — Making a schemaless store governable: per-category schema documents, validation at write time, schema_version on every document

  <details><summary><strong>Answer</strong></summary>

  Schemaless means the *store* fixes no columns; it does not mean the data has no contract, and the difference is the whole design. Per category, a `facet_schemas` document declares which `attributes` keys are typed, which are facetable, their value domains and their display order, and `vendor-service` validates a vendor's submitted document against it at write time with Pydantic — so a bad publish is rejected at the API rather than discovered by the projection. Every document carries a `schema_version`, which is what makes the next change tractable. What it buys is that adding a loyalty or reconciliation category is a document insert plus a projection mapping instead of a migration and a release. What it costs is that you now own schema governance in application code, and the failure mode is not a type error — it is drift, where documents written last year no longer match the schema anyone is reading against. **Deeper:** [interview-questions.md](./interview-questions.md#q1-the-brief-asked-for-mongodb-schemas-for-product-metadata-without-a-fixed-column-set-what-does-schemaless-actually-buy-here-and-how-do-you-stop-it-degrading-into-no-contract) — "The brief asked for MongoDB schemas for product metadata "without a fixed column set". What does schemaless actually buy here, and how do you stop it degrading into "no contract"?"

  </details>
- **MUST** — Schema evolution: migrate-on-read vs backfill vs hard version cutover, and how that choice prices every future category change

  <details><summary><strong>Answer</strong></summary>

  There are three honest options and they price the platform's whole future differently: migrate-on-read is cheap to ship and leaves every reader carrying an upgrade function forever, a backfill job is more work now and leaves one version afterwards, and a hard cutover per category is cleanest and only works when every document in that category can be moved at once. The choice is not local, because `indexer-worker` has to handle whatever versions are live and the comparison matrix unions facet schemas across categories. My default would be a backfill with a version-tolerant reader during the window, but I would not pretend that is settled here — the design explicitly flags facet schema evolution as needing a prototype before the first category ships. That is the honest framing: this decision determines how expensive every later category change is, which is exactly the kind of thing that should not be settled by whoever writes the first migration. **Deeper:** [interview-questions.md](./interview-questions.md#q2-a-categorys-facet_schemas-document-changes-shape--an-attribute-is-renamed-and-a-new-facet-is-added-what-breaks-and-what-are-your-options) — "A category's `facet_schemas` document changes shape — an attribute is renamed and a new facet is added. What breaks, and what are your options?"

  </details>
- **MUST** — Indexes: single/compound, index prefix rules, TTL indexes for staging data, partial and sparse indexes, covered queries, explain() in Mongo

  <details><summary><strong>Answer</strong></summary>

  Mongo's index rules are close enough to a B-tree's to be familiar and different enough to catch you: a compound index is usable by a leading prefix of its keys, and sort order in the index matters when the query sorts. The indexes here are deliberately few — `{category_slug: 1}` and `{updated_at: -1}` on `product_metadata`, `{product_id: 1, revision: -1}` on the revisions collection — because the dominant access is by `_id`, which *is* the Postgres `product.id`, so the two stores join without a mapping table and the hot read needs no index at all. A TTL index on `import_staging.created_at` expires staged rows after thirty days with no job to run or forget. Partial and sparse indexes keep an index off documents that do not have the key, which matters when the key set is open by design. And `explain()` is the same discipline as in Postgres — check that the query is `IXSCAN` and not `COLLSCAN`, and check `totalKeysExamined` against `nReturned` rather than trusting that an index existed.

  </details>
- **NICE** — Immutable revisions as a modelling pattern; append instead of update

  <details><summary><strong>Answer</strong></summary>

  Appending a new revision instead of updating in place makes a listing's history part of the data rather than something reconstructed later: `product_metadata_revisions` holds an immutable snapshot per publish, and `product.current_revision_id` in `postgres-core` is the single mutable pointer saying which one is live. Three things fall out of that — a publish becomes a pointer swap, so it is atomic and reversible; `cat:listing:{id}:v{rev}` becomes a cache key that a lost purge cannot make wrong; and "what did this listing claim when the retailer shortlisted it" is answerable. What it costs is storage that grows per publish and a compaction job to bound it, which is why retention is the latest ten revisions per product with a twelve-month floor. The pattern is right wherever the previous state has evidential value and wrong for high-churn data nobody will ever look back at.

  </details>
- **MUST** — Replica sets: elections, primary/secondary reads, read preference, read concern and write concern, and what "eventually consistent secondary" costs

  <details><summary><strong>Answer</strong></summary>

  A replica set is one primary and secondaries applying its oplog, with an election when the primary goes away — here three members, and an election takes roughly ten to thirty seconds during which writes are refused. That is why a Mongo primary failure means listing publishes and imports fail with a retryable 503 while browse survives, because browse is served from `redis-cache` and from secondaries. Read preference is the knob: the detail-page hydration path may read a secondary, where a few hundred milliseconds of staleness is irrelevant, but the vendor workspace must not, because it needs read-your-writes. Write concern is the durability side — `majority` means acknowledged by a majority and therefore survivable across an election, and anything less can be rolled back by the next primary. Read concern is the other half, and the honest summary of "eventually consistent secondary" is that it costs you the guarantee that what you just wrote is what you next read, which is a routing decision rather than a configuration one.

  </details>
- **OPTIONAL** — Aggregation pipeline basics and where the work should not be done

  <details><summary><strong>Answer</strong></summary>

  The aggregation pipeline is MongoDB's server-side stage chain — `$match`, `$group`, `$lookup`, `$project` — for work you would otherwise pull into the application. Here it should stay close to absent: anything a retailer filters, sorts or counts on is projected into `product_listing_facets` and answered by PostgreSQL, so `mongo-catalog`'s job is document reads by `_id`, and a `$lookup` in the read path would be re-implementing the projection in the store least able to index for it.

  </details>
- **OPTIONAL** — Multi-document transactions: available but expensive, and why the design avoids needing them

  <details><summary><strong>Answer</strong></summary>

  MongoDB does support multi-document transactions on a replica set, at the cost of holding a snapshot, a default sixty-second limit and real throughput loss on contended documents. This design never needs one because a listing publish writes exactly one Mongo document and then commits in PostgreSQL — the ordering rule owned by "The dual-write problem" removes the requirement, and a transaction here would only make the half that still cannot be atomic look safer than it is. **Deeper:** [interview-questions.md](./interview-questions.md#q2-on-a-listing-publish-the-mongodb-write-happens-before-the-postgresql-commit-why-that-order-specifically-and-what-cleans-up-when-it-goes-wrong) — "On a listing publish, the MongoDB write happens before the PostgreSQL commit. Why that order specifically, and what cleans up when it goes wrong?"

  </details>
- **NICE** — Sharding: shard-key choice as a hard-to-reverse decision — and the case for not sharding

  <details><summary><strong>Answer</strong></summary>

  The shard key decides everything downstream: it fixes which queries route to one shard and which must scatter-gather, and a poor choice gives you a hot shard that cannot be fixed without a full resharding. `mongo-catalog` is around 15 GB at year five and its dominant access is a point read by `_id`, which is the pattern that gains least from sharding, so the case here is simply not to — a three-member replica set holds it comfortably for the whole modelled horizon. If it were ever forced, `category_slug` is the tempting key and the wrong one, because category sizes are wildly uneven and the point read would then scatter; hashed `_id` routes that read correctly and gives up serving a category browse from one shard, which costs nothing because that query is answered in PostgreSQL anyway. The general cost this design deliberately avoids paying is that a wrong shard key is discovered under exactly the load that made you shard.

  </details>
- **OPTIONAL** — Managed variants (Cosmos DB for MongoDB) diverging at runtime, not at deploy

  <details><summary><strong>Answer</strong></summary>

  Cosmos DB for MongoDB vCore speaks the wire protocol without being the same engine, so an unsupported aggregation stage or text-index type fails when a query runs rather than when the deployment succeeds — the worst place to find out. It is a flagged verify-before-build item here: if `mongo-catalog` is deployed on vCore rather than a self-managed replica set, the index and query shapes used by `catalog-import-worker` and `indexer-worker` have to be checked against the pinned tier's feature matrix before the design leans on them.

  </details>

## 10. Polyglot Persistence and Cross-Store Consistency

**Backs:** a listing whose spine is relational and whose body is a document, kept in step.

- **MUST** — Choosing which store owns which fact; one owning store per fact

  <details><summary><strong>Answer</strong></summary>

  The seam is governance, not data type. A fact that needs referential integrity, participates in a transaction, or is queried by the platform belongs in `postgres-core`: identity, ownership, category, status, publication time, price tiers, shortlists, connections, billing. A fact that is specific to being a point-of-sale system or a loyalty engine, and that the platform cannot enumerate in advance without blocking the next category, belongs in `mongo-catalog`. The rule that keeps it from drifting is one owning store per fact — and the one deliberate exception, `product_category.facet_schema_ref` pointing at a Mongo document, is named as the only cross-store pointer in the schema precisely so nobody adds a second by accident. Where the two meet is the facetable subset, which is copied rather than shared: a filterable attribute has to be queryable relationally, so it is projected into `product_listing_facets` with a single writer, and the copy is a read model rather than a second owner. **Deeper:** [interview-questions.md](./interview-questions.md#q1-walk-me-through-what-lives-in-postgresql-versus-mongodb-and-what-decides-the-seam-between-them) — "Walk me through what lives in PostgreSQL versus MongoDB, and what decides the seam between them."

  </details>
- **MUST** — The dual-write problem: two stores, one logical operation, no shared transaction — and the ordering rule that makes a partial failure benign (an orphan document is reclaimable, a dangling pointer is a broken listing)

  <details><summary><strong>Answer</strong></summary>

  Publishing a listing writes a document to Mongo and a row to Postgres, and there is no transaction spanning both — so the process can die between them and you get half. You cannot make that impossible, so the design makes the surviving half harmless: the Mongo write goes first, and the Postgres commit that sets `current_revision_id` goes second. An orphaned revision document that no `product` row points at is invisible to every reader and reclaimable by a sweep; a committed pointer to a document that does not exist is a listing that renders as an error. That ordering rule is the entire trick — pick the order whose partial failure is garbage rather than corruption. The costs are stated: a nightly reconciliation job on the `indexing` queue that deletes orphaned revisions older than a day, and the acceptance that the store you wrote first is the one that accumulates junk. **Deeper:** [interview-questions.md](./interview-questions.md#q2-on-a-listing-publish-the-mongodb-write-happens-before-the-postgresql-commit-why-that-order-specifically-and-what-cleans-up-when-it-goes-wrong) — "On a listing publish, the MongoDB write happens before the PostgreSQL commit. Why that order specifically, and what cleans up when it goes wrong?"

  </details>
- **MUST** — Transactional outbox: the event row commits with the state change; the relay publishes and marks it; delivery becomes at-least-once, never zero

  <details><summary><strong>Answer</strong></summary>

  The problem is that "commit, then publish" has a gap: the transaction commits, the process dies, and the event is never sent — so the listing is published and nothing indexes it, with no error anywhere. The outbox closes it by making the event part of the state change: `outbox_event` is inserted in the same Postgres transaction as the `product` update, so either both exist or neither does. A relay then reads unpublished rows — served by `BTREE (occurred_at) WHERE published_at IS NULL`, which is the only query that table takes — publishes to `sb-catalog-events` or `sb-connection-events`, and marks `published_at`. What that converts is the failure mode: delivery becomes at-least-once rather than sometimes-zero, because the relay can crash after publishing and before marking, and will then publish again. Which is exactly why every consumer here is idempotent on `event_id`, and why the outbox is only half the pattern. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-transactional-outbox-and-what-exact-problem-does-it-solve-that-a-commit-then-publish-call-does-not) — "What is a transactional outbox, and what exact problem does it solve that a "commit then publish" call does not?"

  </details>
- **MUST** — Idempotent projection: upsert keyed on the entity, ignore an event older than the current revision — redelivery is a no-op, out-of-order cannot roll back

  <details><summary><strong>Answer</strong></summary>

  At-least-once delivery means the projection will see the same event twice and will see two events out of order, so it has to be written such that neither matters. `indexer-worker` upserts `product_listing_facets` keyed on `product_id` rather than inserting, so a redelivery overwrites with the same values and is a no-op. Out-of-order is the harder half and is handled by carrying `source_revision_id` on the row: an event whose revision is older than the row's current value is discarded, so a delayed revision 4 cannot roll a listing back over revision 5. Together those two properties mean the worker needs no deduplication table and no ordering guarantee from the broker, which is what lets Service Bus fan out to competing consumers. The cost is that the projection must carry a version column forever and that "ignore this event" is a legitimate outcome the metrics have to distinguish from "process this event". **Deeper:** [interview-questions.md](./interview-questions.md#q2-walk-me-through-what-happens-when-indexer-worker-receives-the-same-event-twice-and-when-it-receives-two-events-out-of-order) — "Walk me through what happens when `indexer-worker` receives the same event twice, and when it receives two events out of order."

  </details>
- **NICE** — Reconciliation jobs as the backstop for a lost event, and why a design that needs one should say so

  <details><summary><strong>Answer</strong></summary>

  The orphan sweep is named above under "The dual-write problem"; its other half is the backstop proper — the same nightly job re-projects any `product` whose `projected_at` trails its `updated_at` by more than five minutes, which closes the gap if an event is lost between the relay and `indexer-worker`. The reason a design that needs one should say so is that the job is an admission: at-least-once delivery plus idempotent consumers is not quite airtight, and the residual exposure is bounded by the reconciliation interval rather than by anything faster. Saying it converts an unknown into a number someone can argue with, and it makes the honest test available — a reconciliation job that routinely finds work is a defect report about the primary path, not a job doing its job.

  </details>
- **MUST** — Eventual consistency made visible: projection lag as an SLI with an alert, because "the indexer died" is otherwise a silent failure

  <details><summary><strong>Answer</strong></summary>

  The failure mode of an asynchronous projection is silence: `indexer-worker` dies, publishes still succeed, browse still serves, error rates stay flat, and new listings simply never become searchable — nothing in an error-rate dashboard will ever show that. So the lag is a first-class SLI, `indexer_lag_seconds`, measured from the event's `occurred_at` to the row's `projected_at`, targeted at p95 under five seconds and p99 under thirty, and paged at sixty. That number is also the honest statement of what the [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") choice bought: the staleness window is not "eventually", it is a figure with an alert on it, and `outbox_unpublished_age_seconds` does the same job one step earlier for a stalled relay. The rule I generalise is that any asynchronous step whose failure is invisible to the caller needs a freshness or backlog-age metric, because the alternative is finding out from a vendor.

  </details>
- **MUST** — Read-your-writes by routing: the writer reads the authoritative source, the reader gets the fast, slightly stale projection

  <details><summary><strong>Answer</strong></summary>

  Rather than shrinking the lag, the design routes around it by asking who is reading. The vendor workspace reads the authoritative sources — `product` from the Postgres primary and the metadata document from `mongo-catalog` — and never `product_listing_facets` or `redis-cache`, so a vendor who clicks publish sees the change immediately. Retailers read the projection through the cache and get the fast, slightly stale answer, which costs them nothing because a listing that becomes searchable five seconds later is invisible from the buying side. The one place a vendor meets the projection is an explicit "preview as a retailer sees it" view, where the lag is the point rather than a defect. What this costs is two read paths for the same entity and the discipline of keeping them apart; what it buys is that eventual consistency stops being a user-visible bug for the only user who would notice it.

  </details>
- **OPTIONAL** — CQRS as the general name for this shape; when it is over-engineering

  <details><summary><strong>Answer</strong></summary>

  Command Query Responsibility Segregation is the general name for what `product_listing_facets` already is: writes go to one model, reads to another shaped for the query, joined asynchronously. Naming it adds nothing here and risks importing the parts this design deliberately does not have — no command bus, no event-sourced write model, no second service to operate — which is where it becomes over-engineering, when the projection is adopted as a framework rather than as the answer to one query shape that actually hurt.

  </details>
- **MUST** — The honest alternative (everything in Postgres with JSONB) and what it trades

  <details><summary><strong>Answer</strong></summary>

  Everything in Postgres with `JSONB` is a real design, not a straw man: one store, one transaction, no projection pipeline, no lag SLI, no reconciliation job, and the dual-write problem simply does not exist. What it trades is the vendor-facing authoring surface — per-category schema validation, immutable document revisions and staged imports are Mongo's native shape and become application code plus tables in the Postgres-only variant. It also puts heavier `JSONB` write amplification on the same table that serves search, because a document rewrite touches the relation the hot query reads. My honest position is that the Postgres-only design is the right call for a smaller team, and the two-store design is defensible here mainly because the authoring surface is the part of the product with the most churn. What would move me back is the reconciliation job earning its keep — if lost events or orphans are ever routine rather than theoretical, the second store is not paying for itself. **Deeper:** [interview-questions.md](./interview-questions.md#q3-argue-the-other-side-everything-in-postgresql-jsonb-for-the-metadata-what-does-that-design-get-right-and-what-would-make-you-switch-to-it) — "Argue the other side: everything in PostgreSQL, `JSONB` for the metadata. What does that design get right, and what would make you switch to it?"

  </details>

## 11. Caching with Redis

**Backs:** cached hot catalog reads in Redis to cut database load on popular listings.

- **MUST** — Cache-aside vs write-through vs write-behind, and why cache-aside keeps the cache expendable

  <details><summary><strong>Answer</strong></summary>

  Cache-aside means the application reads the cache, and on a miss reads the source and populates it; write-through means the write path also writes the cache, and write-behind means the cache is written first and the store later. This design is cache-aside deliberately, because write-through would put cache population inside the vendor's publish transaction — coupling a write path to a system the design treats as entirely expendable. Cache-aside keeps that property true: if `redis-cache` disappears, every read falls through to Postgres and Mongo and the platform still works, more slowly. The costs are the ones cache-aside always has — a stampede on a miss, and a window where the cache and the source disagree — and both are answered here rather than ignored, by single-flight locks and by the `v{rev}` key suffix that makes a stale key unreachable rather than merely short-lived. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-cache-aside-and-why-is-this-design-cache-aside-rather-than-write-through) — "What is cache-aside, and why is this design cache-aside rather than write-through?"

  </details>
- **MUST** — Invalidation strategies: event-driven purge, TTL as a backstop, and version-suffixed keys that make a stale key unreachable even if the purge is lost

  <details><summary><strong>Answer</strong></summary>

  Three mechanisms, doing different jobs. Event-driven purge is the precise one: `indexer-worker` deletes `cat:listing:{id}:*` and `cat:facets:{category}` when it processes a listing change, so the change appears as soon as the projection does. TTL is the backstop for the case where enumerating what to purge is intractable — a listing change affects an unknowable number of `cat:search:{filter_hash}` keys, so those get a 60-second TTL instead and freshness is bought with time rather than with logic. The version suffix is the part I would defend hardest: because the key is `cat:listing:{product_id}:v{rev}` and the revision comes from the pointer in `postgres-core`, a reader looking for the current revision cannot reach a stale value even if the purge message was lost entirely. That makes invalidation correctness independent of message delivery, which is the only version of cache invalidation I trust; the cost is orphaned old-revision keys, which the TTL reaps. **Deeper:** [interview-questions.md](./interview-questions.md#q1-the-listing-detail-cache-key-is-catlistingproduct_idvrev-what-does-the-revision-suffix-buy) — "The listing detail cache key is `cat:listing:{product_id}:v{rev}`. What does the revision suffix buy?"

  </details>
- **MUST** — Cache stampede / thundering herd: what happens when a hot key expires under concurrency; single-flight locks, probabilistic early expiry, serving stale

  <details><summary><strong>Answer</strong></summary>

  A stampede is what a TTL does at exactly the wrong moment: a popular point-of-sale listing's key expires, every concurrent request misses together, and the cache converts steady load into a synchronised spike on Postgres and Mongo — the opposite of what the brief asked caching to do. Two mechanisms in `catalog-service` answer it. Single-flight: on a miss the pod takes `SET cat:lock:{key} NX EX 5`, the winner recomputes, and losers poll for up to 200 ms before serving the stale value if one exists. Probabilistic early expiry: each value carries its computation cost and a delta, and readers recompute early with rising probability as the TTL approaches, so recomputation spreads across a window instead of landing on one instant. Together they bound origin load to roughly one recomputation per TTL regardless of concurrency, at the cost of up to 200 ms of staleness on a losing request and a little code that only pays off under exactly the traffic pattern the brief describes. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-cache-stampede-and-why-does-naive-time-to-live-caching-make-it-worse-at-exactly-the-wrong-moment) — "What is a cache stampede, and why does naive time-to-live caching make it worse at exactly the wrong moment?"

  </details>
- **MUST** — Hit-ratio arithmetic: what origin load and latency become at 0% hit rate, and sizing the database to survive a cache loss

  <details><summary><strong>Answer</strong></summary>

  The arithmetic is the part people skip, and it is what decides whether the cache is an optimisation or a dependency. Here the search-page hit ratio is modelled at 0.85, and the budget says a cached search costs about 35 ms server-side against about 107 ms uncached — so at 0.85 the p95 already falls on the uncached path, which is why the design does not claim 35 ms. At a 0% hit rate, the latency is the uncached figure everywhere and Postgres load multiplies roughly sixfold, and the design's stated position is that capacity is sized to survive that: `redis-cache` disappearing is explicitly not an outage. The rule I take from it is that you size the database for the cache being gone, and you treat the hit ratio as an SLI with an alert rather than an assumption — because a hit ratio that quietly falls looks exactly like the database getting slower. **Deeper:** [interview-questions.md](./interview-questions.md#q3-production-hit-ratio-on-catsearch-drops-from-085-to-040-and-stays-there-walk-me-through-the-diagnosis) — "Production hit ratio on `cat:search` drops from 0.85 to 0.40 and stays there. Walk me through the diagnosis."

  </details>
- **MUST** — Key design and namespacing; hashing a filter set into a key; what must never be cached at a layer blind to the requester

  <details><summary><strong>Answer</strong></summary>

  A key has to say what it is, what it varies on and what version it reflects, which is why the namespaces here read as `cat:listing:`, `cat:search:`, `cat:facets:`, `authz:`, `rl:` and `idem:` — that makes a keyspace measurable, purgeable by prefix and legible in an incident. A search page varies on the whole filter set, so the key hashes a canonicalised filter tuple: sorted keys, normalised values, the cursor included, so two logically identical queries share a key and two different ones cannot collide. The rule that matters most is the one about what must never be cached at a layer blind to the requester. `cat:*` holds only published listing data, which is public to any authenticated account type, so a shared key is correct. Anything org-owned — a shortlist, a connection thread, a vendor's drafts — is not cached at this layer at all, because a cache keyed without the tenant is a cross-tenant leak waiting for one careless addition. **Deeper:** [interview-questions.md](./interview-questions.md#q3-a-cache-sits-in-front-of-tenant-scoped-data-how-do-you-guarantee-a-cached-value-never-crosses-an-organisation-boundary) — "A cache sits in front of tenant-scoped data. How do you guarantee a cached value never crosses an organisation boundary?"

  </details>
- **NICE** — TTL choice per data shape: 60 s for a search page because enumerating every affected filter combination is intractable

  <details><summary><strong>Answer</strong></summary>

  Why the search layer gets a TTL rather than a purge is answered above under "Invalidation strategies"; what this bullet adds is how the number itself is chosen. A TTL is a staleness budget you are buying, so it is set from what the reader can tolerate rather than from what the cache can bear: sixty seconds on a search page because a listing appearing a minute late costs a sourcing workflow nothing, fifteen minutes on `cat:listing:` where the revision suffix already makes a stale value unreachable and the TTL is only reaping orphans, five minutes on facet counts because they move far more slowly than the pages they decorate, and sixty seconds in-process on the near-static category tree. The one to watch is that a longer TTL raises the hit ratio and therefore looks like an improvement on every dashboard, which is why the tolerable staleness has to be the argument and the hit ratio only the consequence. **Deeper:** [interview-questions.md](./interview-questions.md#q2-three-redis-layers-three-different-invalidation-rules--event-driven-purge-for-listing-detail-ttl-only-for-search-pages-event-purge-for-facet-counts-why-does-the-search-layer-get-a-different-rule) — "Three Redis layers, three different invalidation rules — event-driven purge for listing detail, TTL only for search pages, event purge for facet counts. Why does the search layer get a different rule?"

  </details>
- **NICE** — Eviction policies, memory sizing, hot keys, big keys

  <details><summary><strong>Answer</strong></summary>

  The eviction policy has to be set deliberately, because the default is not what a cache wants: `allkeys-lru` is right for `redis-cache`, where everything is rebuildable from PostgreSQL and MongoDB, and would be actively wrong for `redis-broker`, which is one of the reasons those are separate instances rather than two databases on one server. Sizing comes from the working set — about 6 GB here for hot listings, search pages, facet counts and counters — with headroom, because a cache sitting at its `maxmemory` evicts on every write and the hit ratio then falls at exactly the moment traffic rises. A hot key is what one very popular listing produces and it is a concurrency problem rather than a memory one, answered here by single-flight rather than by more memory; a big key is the opposite failure, a single value large enough that fetching it stalls a single-threaded server for every other client. The signal that tells you either is happening is `redis_cache_hit_ratio` broken down by keyspace, which is why that SLI is defined per keyspace rather than as one number for the instance — a collapsed search-page ratio hidden behind a healthy overall figure is the case it exists to catch. **Deeper:** [interview-questions.md](./interview-questions.md#q3-at-ten-times-the-traffic-is-redis-still-the-right-layer-what-would-you-add-and-what-would-you-stop-caching) — "At ten times the traffic, is Redis still the right layer? What would you add, and what would you stop caching?"

  </details>
- **OPTIONAL** — Redis data structures and atomicity; pipelines; Lua; SETNX locks and the honest limits of distributed locking

  <details><summary><strong>Answer</strong></summary>

  Redis is single-threaded, so every command is atomic and a Lua script or a `MULTI` block is atomic as a unit — which is what makes the token bucket, the idempotency key and the per-vendor import semaphore correct across pods, while pipelining only amortises round trips and changes no semantics. The honest limit is `SET NX EX` as a lock: it is a lease that can expire while its holder is still working, so it is fine for the single-flight cache recompute here, where a lost lock costs one duplicate query, and it is not a mutual-exclusion primitive for anything two holders would corrupt. **Deeper:** [interview-questions.md](./interview-questions.md#q2-walk-me-through-single-flight-and-probabilistic-early-expiry-what-does-each-cover-that-the-other-does-not) — "Walk me through single-flight and probabilistic early expiry. What does each cover that the other does not?"

  </details>
- **MUST** — Redis for rate-limit counters, idempotency keys and semaphores — and the fail-open/fail-closed decision when it is unavailable

  <details><summary><strong>Answer</strong></summary>

  Redis holds three things here that are not caches — `rl:*` token buckets, `idem:*` idempotency keys and the per-vendor import semaphore — because each needs atomic increment-and-expire across pods, which no in-process structure gives you. But each one forces a decision about what happens when Redis is unavailable, and refusing to make it is how a degradation becomes an incident. The answer here is that business rate limiting fails closed for writes and open for reads: browse keeps working unmetered, while connection requests and listing writes are refused rather than allowed without a limit. Idempotency would be genuinely unsafe failing open, and it is safe here only because the real guarantee is the unique constraint in Postgres and the Redis entry is a fast path; the semaphore fails closed too, since an import ignoring its concurrency cap is precisely what the cap exists to prevent. **Deeper:** [interview-questions.md](./interview-questions.md#q2-redis-cache-disappears-entirely-walk-me-through-what-happens-across-the-system-and-what-fails-closed-rather-than-degrading) — "`redis-cache` disappears entirely. Walk me through what happens across the system, and what fails closed rather than degrading."

  </details>
- **MUST** — Redis as a cache, never a store

  <details><summary><strong>Answer</strong></summary>

  `redis-cache` holds nothing that cannot be rebuilt from Postgres and Mongo, and that is a design rule rather than an observation — it is what lets the failure analysis say a total Redis loss is latency and load, not data loss. The moment something lives only in Redis, every property of the system changes: you now need persistence, backup, a restore procedure and a durability story for an in-memory store, and you will get the first three wrong. The one place this design comes close is `redis-broker`, which holds in-flight Celery tasks — and it is called out honestly as a durability question with `acks_late`, a visibility timeout and [AOF](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ "Append Only File — Redis persistence mode that logs every write for durability") persistence, plus a flagged kill-test, rather than being waved through. The two are separate instances specifically so that a cache eviction policy cannot evict queued work and a broker's memory pressure cannot evict the cache. **Deeper:** [interview-questions.md](./interview-questions.md#q2-there-are-two-redis-instances--redis-cache-and-redis-broker-justify-running-two-rather-than-one-with-separate-databases) — "There are two Redis instances — `redis-cache` and `redis-broker`. Justify running two rather than one with separate databases."

  </details>

## 12. Asynchronous Work with Celery

**Backs:** configured [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for catalog imports and notification jobs so they did not block the API.

- **MUST** — Broker vs result backend; Redis as a broker and its weak acknowledgement semantics versus a real message broker

  <details><summary><strong>Answer</strong></summary>

  The broker carries the task message to a worker; the result backend stores what the task returned so a caller can ask later. They are separate concerns and the mistake is enabling a result backend by default — every task then writes a result nobody reads, which on Redis is memory you are paying for and eventually evicting. In this design almost nothing needs a return value: an import's outcome lives in `catalog_import_job` in Postgres, because the vendor workspace has to query it long after the task is gone, and a projection's outcome is the row it wrote. Redis is the broker here, and it is worth being plain that this is the weak point of the arrangement rather than a neutral choice — it has no real acknowledgement protocol, so "the worker took this message" is a visibility-timeout convention rather than a guarantee, which is why the design pairs it with `acks_late` and flags import durability as needing a kill test.

  </details>
- **MUST** — task_acks_late, visibility timeout, prefetch multiplier, worker concurrency models (prefork vs gevent vs threads)

  <details><summary><strong>Answer</strong></summary>

  `acks_late` moves the acknowledgement from "the worker received it" to "the worker finished it", so a pod killed mid-task gets the task redelivered instead of losing it — which is the setting that makes worker draining and node eviction survivable, and it is only correct because every task here is idempotent. The visibility timeout is what makes redelivery happen at all on Redis: an unacknowledged message becomes visible again after it expires, so the timeout has to exceed the longest task or a slow import chunk gets processed twice concurrently. Prefetch multiplier is the memory knob — a worker that grabs a large batch up front holds them all in memory and blocks other workers from taking them, which is how one greedy consumer starves a queue and then dies of memory pressure. For long, uneven tasks the right prefetch is one. Concurrency model follows the workload: prefork for the CPU-bound parsing in imports, and a threaded or gevent pool where the work is waiting on Mongo and Postgres. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-consumer-prefetch-and-why-is-it-the-first-thing-you-look-at-when-a-message-consumer-runs-out-of-memory) — "What is consumer prefetch, and why is it the first thing you look at when a message consumer runs out of memory?"

  </details>
- **MUST** — At-least-once execution: every task must be idempotent, because it will run twice

  <details><summary><strong>Answer</strong></summary>

  Every delivery guarantee that is not "sometimes zero" is at-least-once, so the honest statement is that every task will run twice eventually — after a redelivery, a retry, a visibility-timeout expiry or a broker failover. Idempotency is therefore not a nice property, it is the correctness condition, and it has to be designed into what the task writes rather than bolted on with a "have I run?" check, which is itself a race. In practice that means the projection upserts on `product_id` and discards stale revisions; an import chunk keys its staging rows on the job and row number so a rerun overwrites; a notification carries an `event_id` the dispatcher deduplicates on. Where the effect is genuinely external and not idempotent — sending an email — you cannot make it exactly-once, so you choose which failure you prefer, and here that is a duplicate notification rather than a missing one. The one place duplication is not acceptable is billing, and that is enforced by a unique constraint, not by the task.

  </details>
- **MUST** — Retries: exponential backoff with jitter, max attempts, dead-lettering, poison messages

  <details><summary><strong>Answer</strong></summary>

  Retries need three things decided together: a backoff that grows, jitter so retries do not synchronise into a second thundering herd, and a maximum attempt count after which the task stops. Without the cap, a task that fails deterministically retries forever and looks like a busy worker rather than a broken one. What happens at the cap is the part that gets skipped: the message goes to a dead-letter destination and someone is told, because a dead-letter queue that nobody watches is a silent data-loss mechanism with extra steps — which is why a Service Bus dead-letter count above zero on any subscription raises a ticket here. The distinction that decides everything is retryable versus poison: a Mongo primary election is retryable and will succeed in thirty seconds; a malformed import row will fail identically forever and should go to `error_digest` on the first failure rather than after twenty. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-is-a-dead-letter-queue-and-what-should-actually-happen-when-a-message-lands-in-one) — "What is a dead-letter queue, and what should actually happen when a message lands in one?"

  </details>
- **MUST** — Queue separation so imports cannot starve indexing or notifications; separate worker deployments scaled on their own queue depth

  <details><summary><strong>Answer</strong></summary>

  Three queues — `imports`, `indexing`, `notifications` — with three separate worker deployments, because work with different latency requirements must not share a pool. A 20,000-row import is allowed to take minutes; a projection has a five-second p95 budget; a notification is user-visible. Put them on one queue and the import's chunks sit in front of everything, so publishing a listing stops being searchable because a different vendor uploaded a spreadsheet. Separate deployments matter as much as separate queues, because it is the deployment that gets its own replica count and its own HPA on its own `celery_queue_depth` — so a large import scales the importers without touching the web tier or the indexers. The cost is three pools to size and observe rather than one, plus the possibility of idle capacity in one while another is saturated, which at this volume is a price worth paying for the isolation. **Deeper:** [interview-questions.md](./interview-questions.md#q2-a-vendor-uploads-a-20000-row-catalog-import-walk-me-through-the-path-and-every-mechanism-that-stops-it-degrading-browse-for-everyone-else) — "A vendor uploads a 20,000-row catalog import. Walk me through the path and every mechanism that stops it degrading browse for everyone else."

  </details>
- **NICE** — Fairness: a per-tenant concurrency cap (a Redis semaphore) so one vendor cannot occupy the pool

  <details><summary><strong>Answer</strong></summary>

  The cap itself is answered above under "Chunking a large job into bounded tasks"; what it adds as a subject is that queue separation and the semaphore solve two different fairness problems. Separate queues stop imports starving indexing and notifications — fairness across kinds of work — while the per-vendor semaphore stops one vendor's twenty thousand rows occupying all four import slots, which is fairness across tenants inside one kind and is something no amount of queue separation gives you. What neither fixes is ordering: a small vendor's job queued behind a large one still waits, because Celery has no per-tenant round-robin, and the honest options are a queue per tier or accepting the latency rather than pretending the cap solved it.

  </details>
- **MUST** — Chunking a large job into bounded tasks; batching downstream writes so one import does not produce 20,000 invalidations

  <details><summary><strong>Answer</strong></summary>

  A 20,000-row import is not a task, it is a job, and treating it as one task gives you something that cannot be retried without redoing everything, cannot be scaled across workers and will outlive any sensible visibility timeout. So it is chunked into 500-row tasks on the `imports` queue, each independently retryable, with a per-vendor cap of four concurrent chunks held as a Redis semaphore so one vendor cannot occupy the pool. The batching on the far side matters just as much: a completed import emits one `catalog.import.completed` event and `indexer-worker` re-projects the affected products in batches of two hundred, because one event per row would produce 20,000 cache invalidations and 20,000 upserts and turn a vendor's spreadsheet into a self-inflicted denial of service on browse. The general rule is that the fan-out of a bulk operation has to be bounded somewhere, and if you do not choose where, the broker chooses for you by falling over. **Deeper:** [interview-questions.md](./interview-questions.md#q2-a-system-pushing-millions-of-product-attribute-updates-through-a-broker-has-taken-production-down-with-memory-overloads-diagnose-the-likely-mechanism-and-say-what-you-would-put-in-place) — "A system pushing millions of product attribute updates through a broker has taken production down with memory overloads. Diagnose the likely mechanism, and say what you would put in place."

  </details>
- **MUST** — Staging then promoting: validate everything before any of it is applied, so a malformed file fails wholly rather than half-applying

  <details><summary><strong>Answer</strong></summary>

  Rows land in `import_staging` in Mongo and are validated against the category's `facet_schemas` before any `product` row moves, so a malformed file fails wholly at validation with a per-row `error_digest` rather than half-applying. The reason to insist on that is the alternative: a partially-applied import leaves a vendor's catalog in a state nobody designed, and the recovery is manual, per row, against a file the vendor has already edited. Staging also gives the vendor something useful — `row_total`, `row_ok`, `row_failed` and the error digest in `catalog_import_job`, which is job state in Postgres precisely because the workspace has to query it. What it costs is a full write of the parsed data before any of it counts, plus a thirty-day TTL on the staging collection so the intermediate state expires without a cleanup job. It is the same instinct as expand/contract: make the intermediate state safe rather than short.

  </details>
- **NICE** — Graceful shutdown: preStop, draining, task size vs termination grace period

  <details><summary><strong>Answer</strong></summary>

  The pod-lifecycle mechanics belong to Kubernetes and are answered under "Graceful termination" there; the Celery half of this is an arithmetic problem. A drain is only graceful if the longest in-flight task finishes inside `terminationGracePeriodSeconds`, which is 120 seconds here — and that is why imports are chunked at five hundred rows rather than run whole, so chunk size and shutdown are one decision rather than two. When the arithmetic fails anyway, `acks_late` is what stops it being data loss: the task was never acknowledged, so it is redelivered rather than lost, at the cost of possibly running twice, which is only acceptable because every task here is idempotent. The case to avoid is the task that neither fits the window nor is idempotent, because then the only choice left is between losing it and doing it twice.

  </details>
- **MUST** — Durability: what a broker failover can lose, and how to test it (kill the worker) rather than assume

  <details><summary><strong>Answer</strong></summary>

  The honest answer is that Celery on Redis does not give you a durability guarantee, it gives you a convention. `acks_late` plus a visibility timeout means a killed worker's task becomes visible again and is redelivered — but Redis has no acknowledgement protocol, so a `redis-broker` failover can still drop tasks that were taken and not yet finished, and AOF with `everysec` bounds but does not eliminate the loss. That is why the design flags this rather than asserting it. The way to settle it is a kill test on the pinned Celery and Redis versions: start an import, kill the worker mid-chunk, confirm the chunk reappears and completes exactly once against the staging rows — and pull the broker over too, because the two failures behave differently. If the answer is that imports must be durable, the stated fix is to move the `imports` queue onto Service Bus, which is already in the stack, and leave Redis carrying only `indexing` and `notifications`, whose work is fully rebuildable from the outbox. **Deeper:** [interview-questions.md](./interview-questions.md#q2-celery-on-redis-does-not-have-real-acknowledgement-semantics-what-is-the-risk-to-import-durability-and-how-would-you-actually-test-it-rather-than-assume) — "Celery on Redis does not have real acknowledgement semantics. What is the risk to import durability, and how would you actually test it rather than assume?"

  </details>

## 13. Event-Driven Integration on Azure

**Backs:** integrated Azure Functions, Blob Storage and Service Bus for catalog updates and vendor-retailer notifications.

- **MUST** — Queue vs topic/subscription; competing consumers; fan-out to independent consumers

  <details><summary><strong>Answer</strong></summary>

  A queue has one logical consumer group — many workers compete and each message is handled once — which is what you want when the message is a unit of work; a topic fans the same message to independent subscriptions, each with its own cursor and dead-letter queue, which is what you want when the message is a statement of fact several parties care about for different reasons. That is exactly the split here: `sb-catalog-events` is a topic because `catalog.listing.published` has to reach both `indexer-worker` and `notification-worker`, and a slow notifier must not delay the projection. `sb-notification-dispatch` is a queue because "send this email" is work with one owner, `fn-notify-dispatch`, and competing consumers are the scaling model. The cost of a topic is that adding a subscription silently adds a backlog nobody is watching, which is why dead-letter counts are alerted per subscription rather than per namespace. **Deeper:** [interview-questions.md](./interview-questions.md#q1-sb-catalog-events-is-a-topic-and-sb-notification-dispatch-is-a-queue-what-is-the-difference-and-why-is-each-right-where-it-is) — "`sb-catalog-events` is a topic and `sb-notification-dispatch` is a queue. What is the difference, and why is each right where it is?"

  </details>
- **MUST** — Service Bus mechanics: peek-lock vs receive-and-delete, lock renewal, dead-letter queues and replay, duplicate detection, sessions for ordering, scheduled messages, retry policy

  <details><summary><strong>Answer</strong></summary>

  Peek-lock is the mode that matters: the message is locked rather than removed, and it returns to the queue if the consumer dies before completing it — receive-and-delete is faster and loses the message on any failure, so it is only for telemetry you can afford to drop. A long handler has to renew its lock or the message is redelivered while it is still being processed, which looks like a duplicate and is really a timeout. Dead-letter queues hold what exceeded the delivery count or was explicitly rejected, and they are a real queue you can replay from once the cause is fixed, which is why the alert here is a ticket on any dead-letter count above zero. Duplicate detection is a broker-side window and is a convenience, not a substitute for idempotent consumers. Sessions give ordering within a key at the cost of serialising that key's consumption — this design deliberately does not use them, because the projection handles out-of-order events itself with `source_revision_id`.

  </details>
- **MUST** — Delivery semantics: at-most-once, at-least-once, and why exactly-once is a property of the consumer

  <details><summary><strong>Answer</strong></summary>

  At-most-once means a message may be lost and never duplicated; at-least-once means it may be duplicated and never lost. Real systems pick at-least-once because losing a listing publish is worse than indexing it twice, and every mechanism here follows from that: the outbox guarantees the event exists, the relay may publish twice, and Service Bus may redeliver. Exactly-once delivery is not something a broker can give you, because the acknowledgement can always be lost after the work is done and before it is recorded — what you can have is exactly-once *effect*, which is a property of the consumer. In this design that property is built three ways: an idempotent upsert with a revision guard for the projection, a unique constraint for the billing charge, and deduplication on `event_id` for notifications. The rule worth stating plainly is that anyone claiming exactly-once delivery has either moved the deduplication somewhere you have not looked, or has not looked.

  </details>
- **NICE** — Event schema design and versioning; consumer-driven contracts

  <details><summary><strong>Answer</strong></summary>

  Every event here carries the same envelope — `event_id`, `type`, `occurred_at`, `aggregate_id`, an optional `source_revision_id` and a payload — and that split is the design: the envelope is what every consumer depends on, the payload is what one consumer reads. Versioning then follows the same rule as the API: an added optional field is safe, a removed or retyped one is a new event type running alongside the old until every subscription has moved, and the emitter must never know who is listening. The rule I hold hardest is that an event carries a fact and an identifier rather than a whole entity — `catalog.listing.published` says which listing and which revision, and `indexer-worker` reads the current document itself, so a redelivered or delayed event cannot carry a stale copy of the truth. Consumer-driven contracts are the honest way to test any of that, because otherwise an emitter finds out what it broke from a dead-letter queue.

  </details>
- **MUST** — Two messaging systems on purpose: an in-process work queue vs an event bus that crosses a boundary — one rule, no overlap

  <details><summary><strong>Answer</strong></summary>

  Celery and Service Bus are not redundant here and the split is a rule rather than a preference: Celery moves work between Python processes we own, Service Bus moves events across a boundary — to Azure Functions, to `billing-service`, and to any future consumer. Work is imperative and addressed to a worker; an event is a statement of fact addressed to whoever cares, and the emitter must not know the list. Notification ownership follows the same rule and is the clearest example: `notification-worker` decides *whether and what* to notify, which needs database context and is therefore Python, and `fn-notify-dispatch` performs delivery, which needs no context at all. One owner per step, no overlap. The cost is two broker technologies to monitor and two sets of failure modes; the alternative — Celery reaching into Functions, or Service Bus scheduling in-process Python work — puts one system into the role it is worst at. **Deeper:** [interview-questions.md](./interview-questions.md#q1-this-system-runs-both-celery-and-azure-service-bus-why-two-messaging-systems-and-what-is-the-rule-that-decides-which-one-carries-a-given-piece-of-work) — "This system runs both Celery and Azure Service Bus. Why two messaging systems, and what is the rule that decides which one carries a given piece of work?"

  </details>
- **MUST** — Azure Functions: triggers and bindings (blob, queue), consumption vs premium, cold start, scaling behaviour, idempotent handlers, slot swap deploys

  <details><summary><strong>Answer</strong></summary>

  A Function is a handler bound to a trigger, and the two here are chosen for exactly that shape: `fn-media-process` on a blob trigger, because thumbnailing a forty-page datasheet must never hold an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") connection, and `fn-notify-dispatch` on a queue trigger, because delivery is stateless work with no database context. Consumption scales to zero and pays cold starts; premium keeps instances warm and is what you choose when the latency is user-visible — neither of these is, so consumption is defensible. The properties that make Functions safe are the same as for any consumer: handlers must be idempotent, because the platform retries, and a blob trigger in particular can fire twice for one upload, which is why derived paths are content-addressed and regenerable rather than appended. Deploying by slot swap keeps a rollout from dropping in-flight invocations. **Deeper:** [interview-questions.md](./interview-questions.md#q2-notification-policy-lives-in-notification-worker-and-delivery-lives-in-fn-notify-dispatch-why-split-those-and-what-breaks-if-the-boundary-blurs) — "Notification policy lives in `notification-worker` and delivery lives in `fn-notify-dispatch`. Why split those, and what breaks if the boundary blurs?"

  </details>
- **MUST** — Blob Storage: containers and prefixes, access tiers and lifecycle rules, [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") tokens, direct client upload, content-addressed paths, Content-Disposition and serving untrusted files from a separate hostname

  <details><summary><strong>Answer</strong></summary>

  Blob is the right home for anything large, immutable and served rather than queried, and the layout here is the design: `listings/{product_id}/{revision}/…` for vendor uploads with a `derived/` subtree written by `fn-media-process`, `imports/{vendor_id}/{job_id}` for raw uploads deleted after ninety days, `admin-console/{build_sha}/…` for the static bundle, and `tfstate/` for Terraform state. Content-addressed and revision-keyed paths are what make the [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") layer need no invalidation at all — a new revision is a new URL, so there is no purge to lose. Lifecycle rules move listing media to the cool tier after 180 days without a job. The security properties are the part I would not skip: uploads go direct from the client against a short-lived SAS token so no service proxies a large file, and vendor-supplied datasheets are served from a dedicated download hostname with `Content-Disposition: attachment`, so nothing untrusted is ever served from the origin hosting the admin console.

  </details>
- **NICE** — Splitting policy from delivery: deciding whether to notify in code that has database context, delivering in a function that does not

  <details><summary><strong>Answer</strong></summary>

  The rule is answered above under "Two messaging systems on purpose"; what this bullet adds is what blurring it looks like in each direction. Push policy into `fn-notify-dispatch` and the Function needs a database connection, the tenant filter and the notification-preference model — so it acquires everything the split existed to keep out, in the component with the least observability and the shortest execution budget. Pull delivery into `notification-worker` and an email-provider outage becomes retries held in a Celery worker on `redis-broker`, whose durability story is the weakest link in this design, rather than in `sb-notification-dispatch`, which has a dead-letter queue and an alert already watching it. **Deeper:** [interview-questions.md](./interview-questions.md#q2-notification-policy-lives-in-notification-worker-and-delivery-lives-in-fn-notify-dispatch-why-split-those-and-what-breaks-if-the-boundary-blurs) — "Notification policy lives in `notification-worker` and delivery lives in `fn-notify-dispatch`. Why split those, and what breaks if the boundary blurs?"

  </details>

## 14. Search and Faceted Filtering in PostgreSQL

**Backs:** catalog search and listing filters used when chains compare coverage.

- **MUST** — Full-text search in Postgres: to_tsvector/to_tsquery, dictionaries and stemming, ts_rank, GIN vs GiST for tsvector, maintaining the vector in a worker rather than a trigger (and why the trigger couples write latency)

  <details><summary><strong>Answer</strong></summary>

  `to_tsvector` turns text into normalised lexemes using a dictionary that handles stemming and stop words, `to_tsquery` does the same to the query, and matching happens between lexemes rather than strings — which is why "integrations" finds "integration" and why a plain `LIKE` does not. `ts_rank` orders results, and it is worth knowing it is a weak relevance model compared with a real search engine's. `GIN` is the right index for a `tsvector` here because the vectors are effectively static between publishes and reads dominate; `GiST` is lossy and rechecks, which suits high-churn text and does not describe this catalog. The decision I would defend most is maintaining `search_vector` in `indexer-worker` rather than in a trigger: a trigger runs inside the vendor's publish transaction, so text-search maintenance becomes part of write latency for a value only the projection ever reads — and it also silently couples every bulk import row to that cost.

  </details>
- **NICE** — Language handling: a single dictionary versus a multilingual catalog, and trigram similarity (pg_trgm) for fuzzy name matching

  <details><summary><strong>Answer</strong></summary>

  That a single dictionary breaks on a multilingual European catalog is noted above under "When Postgres search stops being enough"; the mechanism is that `to_tsvector` takes a text-search configuration, so the fix is a language per listing, a `search_vector` built with that listing's configuration, and a query stemmed the same way — which forces the search either to know the user's language or to run against several vectors. Trigram similarity solves a different problem and is worth keeping separate: `pg_trgm` matches on character overlap rather than lexemes, so it catches a misspelled or partially typed vendor name where stemming cannot, and it supports a leading wildcard a B-tree will not. Neither is in this design — the catalog is modelled as monolingual, and the flagged next step is a prototype against real vendor copy, which is also the most likely trigger for the dedicated search engine the design defers. I would rather say that plainly than imply a multilingual index I have not built. **Deeper:** [interview-questions.md](./interview-questions.md#q3-this-design-deliberately-rejected-elasticsearch-for-postgresql-full-text-search-defend-that-and-name-exactly-what-would-reverse-it) — "This design deliberately rejected Elasticsearch for PostgreSQL full-text search. Defend that, and name exactly what would reverse it."

  </details>
- **MUST** — Facet counts: how they are computed and why they cost as much as the page

  <details><summary><strong>Answer</strong></summary>

  A facet count is a `GROUP BY` over the same filtered set the page came from, so producing counts for six facets means scanning that set repeatedly or once with conditional aggregation — either way it costs about what the page costs, and often more, because the page stops at fifty rows and the counts cannot. That is the whole reason the design returns `total_estimate` capped at 1,000 rather than an exact total: an exact count over a filtered `GIN` scan is as expensive as the query itself, and no sourcing workflow is improved by knowing there are 1,247 results rather than "1,000+". Counts are cached separately under `cat:facets:{category_slug}` with a five-minute TTL and purged by `indexer-worker` on any projection write in that category, because they change far more slowly than the pages they decorate. The honest cost is that the UI cannot show an exact number, which is a product concession made deliberately rather than a limitation discovered late. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-api-returns-total_estimate-capped-at-1000-rather-than-an-exact-count-why-and-how-would-you-produce-the-estimate) — "The API returns `total_estimate` capped at 1,000 rather than an exact count. Why, and how would you produce the estimate?"

  </details>
- **MUST** — Filter selectivity and the combinatorics of optional predicates

  <details><summary><strong>Answer</strong></summary>

  With eight optional predicates there are hundreds of possible query shapes, and the planner has to guess the selectivity of each one — badly, in the two cases that matter most here, because estimates for `text[]` containment and `jsonb` containment are poor at high cardinality. A predicate the planner thinks removes 99% of rows and actually removes 10% turns a bitmap `AND` into something close to a full scan, and there is no index you can add that fixes a wrong estimate. The design's answer is to constrain the input rather than chase the planner: the API refuses an uncategorised query carrying more than two facet predicates, which guarantees `idx_plf_browse` or `idx_plf_price` is always a viable leading index. That is a product constraint bought for a performance guarantee, and it is defensible only because it matches how sourcing actually works — nobody compares a point-of-sale system against a loyalty engine. It would be the wrong trade in a marketplace where cross-category discovery is the point. **Deeper:** [interview-questions.md](./interview-questions.md#q2-refusing-an-uncategorised-query-with-more-than-two-facet-predicates-is-a-product-constraint-bought-for-a-performance-guarantee-defend-that-and-tell-me-when-that-trade-is-wrong) — "Refusing an uncategorised query with more than two facet predicates is a product constraint bought for a performance guarantee. Defend that, and tell me when that trade is wrong."

  </details>
- **MUST** — When Postgres search stops being enough: the concrete trigger for adopting a search engine, and what a dedicated engine adds (relevance tuning, analyzers, highlighting) and costs (a third store, a second lag, expertise)

  <details><summary><strong>Answer</strong></summary>

  The trigger is stated as a number rather than a feeling: adopt a dedicated engine if p95 catalog search exceeds 200 ms after the index work, or if free-text relevance ranking becomes a product requirement. At 40,000 listings with structured facets, Postgres is comfortably inside what it does well, and a search cluster would add a third data store, a second consistency lag and real operational expertise for ranking nobody has asked for. What an engine adds is genuine — proper relevance tuning, per-language analyzers, highlighting, and a query language built for exactly this shape of optional predicate. What it costs is the third store, the second lag, and the fact that relevance becomes an ongoing tuning job rather than a setting. The most likely thing to force it here is language: a single dictionary handles a monolingual catalog well and handles "Kassensystem" versus "point of sale" not at all, which the design flags as needing a prototype against real vendor copy. **Deeper:** [interview-questions.md](./interview-questions.md#q3-this-design-deliberately-rejected-elasticsearch-for-postgresql-full-text-search-defend-that-and-name-exactly-what-would-reverse-it) — "This design deliberately rejected Elasticsearch for PostgreSQL full-text search. Defend that, and name exactly what would reverse it."

  </details>

## 15. Kubernetes and AKS

**Backs:** deployed services to Azure [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") with Docker and [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications").

- **MUST** — Core objects: Deployment, ReplicaSet, Service, Ingress, ConfigMap, Secret, Job/CronJob, Namespace

  <details><summary><strong>Answer</strong></summary>

  A Deployment declares desired state and owns a ReplicaSet per revision, which is what makes a rollout and a rollback the same operation with a different revision number. A Service is a stable name and a load-balancing rule over whichever pods are currently ready; an Ingress is the HTTP-level router in front of it, and here it is NGINX behind APIM, which is also where the canary weighting for `catalog-service` lives. ConfigMap and Secret separate configuration from image so the same digest runs in staging and production — though in this design almost nothing is a Kubernetes Secret, because credentials come from Key Vault via workload identity rather than being mounted. Job and CronJob are for work with an end, which is where a one-off backfill belongs rather than in a long-lived worker. Namespace is the isolation and policy boundary, and all nine deployments share one here, which is precisely why the NetworkPolicy is default-deny and why the absence of a mesh is a stated trade-off rather than an oversight.

  </details>
- **MUST** — Probes: liveness vs readiness vs startup, and the outage a wrong liveness probe causes

  <details><summary><strong>Answer</strong></summary>

  Readiness answers "should traffic go here", liveness answers "should this container be killed", and startup exists so a slow boot does not get killed by the liveness probe before it has finished. Conflating readiness and liveness is the classic outage: point liveness at a check that touches Postgres, have Postgres get slow, and Kubernetes now kills every pod simultaneously — turning a degradation into a total outage and preventing the recovery, because the restarted pods hit the same dependency. So liveness should test only that the process itself is wedged, and readiness is where a dependency check belongs, because failing readiness removes one pod from the Service and leaves it running. For the workers the useful readiness signal is different again: `preStop` stops queue consumption and lets the in-flight task finish inside `terminationGracePeriodSeconds`, which is a drain rather than a probe, and it is what makes a rolling worker update not lose an import chunk.

  </details>
- **MUST** — Requests and limits, [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") classes, OOMKill, CPU throttling

  <details><summary><strong>Answer</strong></summary>

  A request is what the scheduler reserves and a limit is what the kernel enforces, and the gap between them is the QoS class: equal values are Guaranteed, request-below-limit is Burstable, neither is BestEffort and first to be evicted. The two enforcement mechanisms behave completely differently, which is the part worth knowing. Exceeding a memory limit is an OOMKill — immediate, no grace, no stack trace — and for a Celery worker that has prefetched a large batch, the memory limit is the thing that turns a prefetch mistake into a crash loop. Exceeding a CPU limit is throttling rather than killing, so the symptom is p99 latency that rises with no error and no obvious cause, and a CPU limit set tight on an async service is a very effective way to manufacture tail latency. My default here is generous requests, memory limits set from observed peaks with headroom, and CPU limits used sparingly on the services that carry user-facing latency.

  </details>
- **MUST** — Rollout strategies: rolling, canary (ingress weighting, hold time, the metric that decides promotion), blue-green and why it can be the wrong spend when both colours share one database

  <details><summary><strong>Answer</strong></summary>

  A rolling update replaces pods gradually under readiness gating and is the right default for the five services and three workers whose risk is ordinary. Canary is for the one that is not: `catalog-service` carries almost all the traffic and the risky query plans, so it gets a second Deployment taking about 10% via Ingress weighting, held fifteen minutes against its error rate and p95 before the weight advances — the hold time and the metric are the design, not the weighting. Blue-green was rejected here for a specific reason rather than a general preference: it doubles the pod footprint, and because both colours share one `postgres-core` it delivers no database-level isolation, which is the only part of the risk that expand/contract does not already cover. What canary costs is two versions live against one schema for fifteen minutes, which is safe only because the migration discipline guarantees it — the strategies are not independent choices.

  </details>
- **MUST** — Rollback as a redeploy of a previous image digest, and the schema discipline that makes it safe

  <details><summary><strong>Answer</strong></summary>

  Rollback here is redeploying the previous image digest, which is a seconds-long operation with a known-good artefact rather than a rebuild or a database restore. What makes it safe is entirely the schema discipline: because migrations are expand-only before deploy, the previous image can still run against the current schema, so going back does not require going back in the database. Digest rather than tag matters, because a tag can be moved and then "the previous version" is whatever someone pushed last. The thing that breaks this property is a contract migration landed too early — drop the column the old image still reads and rollback stops being available, silently, until the day you need it. That is why the contract step is a separate merge request at least one release later, and why I would treat "can we still roll back right now" as a question with a checkable answer rather than an assumption. **Deeper:** [interview-questions.md](./interview-questions.md#q2-migrations-are-expandcontract-and-run-before-deploy-catalog-service-deploys-by-canary-and-the-rest-roll-walk-me-through-a-bad-deploy-and-the-rollback) — "Migrations are expand/contract and run before deploy; `catalog-service` deploys by canary and the rest roll. Walk me through a bad deploy and the rollback."

  </details>
- **NICE** — Graceful termination: preStop, terminationGracePeriodSeconds, draining workers rather than killing them

  <details><summary><strong>Answer</strong></summary>

  The pod lifecycle is worth having exactly right: on delete, Kubernetes removes the pod from Service endpoints and runs `preStop` concurrently, then sends `SIGTERM`, then `SIGKILL` at `terminationGracePeriodSeconds`. Endpoint removal is eventually consistent across kube-proxy and the ingress, which is why a web pod's `preStop` is a short sleep — it keeps serving during the seconds when traffic is still being routed to it, and skipping that is the usual cause of 502s in an otherwise healthy rolling update. For the three worker deployments the same hook does something different: it stops queue consumption so nothing new is taken, and the container then finishes only what it already holds. Whether what it holds actually fits the window is the sizing question, and that belongs to "Graceful shutdown" in the Celery topic.

  </details>
- **NICE** — Autoscaling: [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on CPU and on a custom queue-depth metric, cluster autoscaler

  <details><summary><strong>Answer</strong></summary>

  CPU at a 65% target is the right signal for the six services, whose load is request-driven and roughly proportional to it. It is the wrong signal for a Celery worker, which can sit idle-waiting on MongoDB with a five-hundred-deep backlog and never trigger — so the three worker pools scale on `celery_queue_depth` through a custom metric adapter, which is the queue-separation decision paying off, because a per-queue depth only means anything if each queue has its own deployment. The cluster autoscaler is a second and slower loop underneath, three to eight nodes: the HPA asks for pods and, if none fit, a node has to be provisioned first, so real scale-up latency is node time rather than scheduling time — which is why capacity is provisioned at roughly three times the modelled peak instead of relying on autoscaling to absorb a burst. The failure worth naming is scaling on a signal the bottleneck does not move: more `catalog-service` pods against a saturated replica adds connections, not throughput.

  </details>
- **NICE** — NetworkPolicy default-deny, ingress and egress; service mesh and mTLS as a documented upgrade with a named trigger rather than a default

  <details><summary><strong>Answer</strong></summary>

  The mesh trade-off and its trigger are owned by "Encryption in transit and at rest" in Security Beyond Authentication; the Kubernetes half is what default-deny actually is. A NetworkPolicy is an allowlist of pod-selector pairs enforced by the container network plugin, and it is default-deny only in the sense that selecting a pod at all denies everything not explicitly allowed — so a namespace with no policy is fully open, and the classic mistake is a policy that names ingress and leaves egress unselected, which then permits everything outbound. Egress is the half that matters most here: only the payment provider, the email provider and Azure service endpoints are reachable from the cluster, which turns a compromised dependency into a blocked connection rather than an exfiltration. What it does not give you is authentication — it constrains which pod may reach which port and says nothing about who is calling, which is exactly the gap mTLS would close and the reason its absence is stated rather than silent. **Deeper:** [interview-questions.md](./interview-questions.md#q3-there-is-no-mutual-transport-layer-security-between-services-defend-that-and-name-the-exact-trigger-that-would-change-it) — "There is no mutual Transport Layer Security between services. Defend that, and name the exact trigger that would change it."

  </details>
- **MUST** — Workload identity instead of mounted credentials

  <details><summary><strong>Answer</strong></summary>

  Workload identity federates a Kubernetes service account to an Azure managed identity, so a pod gets a short-lived token from the platform instead of holding a credential. That removes the entire class of problem that mounted secrets create: nothing to rotate, nothing to leak in a log or an image layer, nothing that stays valid after the pod is gone, and no shared credential that makes "which service did this" unanswerable. It also makes least privilege practical, because identity is per service rather than per cluster — `catalog-service` gets read on its own Key Vault secrets and nothing on Service Bus, and only the outbox relay may send on `sb-catalog-events`. Those assignments are Terraform resources, so widening one is a reviewable diff rather than a portal click nobody sees. The fallback where a driver cannot do Entra ID authentication is a Key Vault-stored credential, which is a smaller exception than mounting secrets everywhere by default.

  </details>
- **MUST** — Docker fundamentals: layers and caching, multi-stage builds, non-root users, small base images, digest pinning, Compose for a local and [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") stack of real data stores

  <details><summary><strong>Answer</strong></summary>

  An image is layers, and the build cache keys on the instruction plus its inputs, so the ordering rule is dependencies before source — copy the lock file and install, then copy the application, or every code change reinstalls the world. A multi-stage build leaves the toolchain behind in the builder stage, so the shipped image carries the application and its runtime dependencies and nothing that was needed only to produce it — smaller to pull on every rollout, and with far less inside it worth exploiting. Running as a non-root user with a read-only root filesystem costs nothing and removes a whole category of container escape preconditions. Pinning matters twice over: base images by digest so a rebuild is reproducible, and dependencies by hash so the supply chain is not "whatever PyPI served that morning" — with weekly base-image rebuilds so pinning does not quietly mean unpatched. Compose is the other half of this in practice: it brings up real Postgres, Mongo and Redis at the pinned versions for local development and for the CI integration stage, which is what makes those tests worth running at all.

  </details>

## 16. CI/CD Pipelines

**Backs:** automated GitLab CI pipelines for test and deploy across services.

- **MUST** — Pipeline structure: stages, jobs, artifacts, caches, services containers, needs/DAG, parallelism, matrix builds

  <details><summary><strong>Answer</strong></summary>

  Stages give order, jobs give parallelism within a stage, and `needs` turns the whole thing into a DAG so a job runs the moment its inputs exist rather than waiting for a stage boundary — which is usually the single largest win available on a slow pipeline. Artifacts pass build outputs forward; caches make a job faster but must never be load-bearing, because a cache miss has to produce the same result. Services containers are how the integration stage gets real Postgres, Mongo and Redis. Parallelism and matrices are where a test suite gets cheap and where flakiness gets expensive, because shared state across parallel workers is the usual cause. Here it is one repository, one pipeline and nine deployable images, which is what makes six services affordable — and the thing I would watch is that a twenty-to-thirty-minute pipeline changes behaviour, because people batch merges to avoid it. **Deeper:** [interview-questions.md](./interview-questions.md#q3-the-pipeline-takes-twenty-to-thirty-minutes-how-do-you-work-with-that-and-how-would-you-shorten-it-without-weakening-the-gates) — "The pipeline takes twenty to thirty minutes. How do you work with that, and how would you shorten it without weakening the gates?"

  </details>
- **MUST** — A gate is only a gate if it can fail: proving each blocking step actually blocks by making it fail on purpose

  <details><summary><strong>Answer</strong></summary>

  A blocking step that has never blocked is not a gate, it is a decoration, and the difference is invisible until the day it matters. The check is to make it fail on purpose: push a change that violates the lint rule, break a type, delete an assertion, plant a known-vulnerable dependency, and confirm the pipeline goes red at the stage you expect. The specific traps in a shell-driven pipeline are worth naming, because both fail open: a command piped through `tail` or `grep` reports the pipe's last exit status rather than the command's, and a step that asserts an absence dies under `set -e` on a `grep` that correctly finds nothing. Both look like a passing gate. I would also check the gate the way CI invokes it rather than the way that is convenient locally, because a tool given one file and the same tool given a directory can disagree about that file. **Deeper:** [interview-questions.md](./interview-questions.md#q3-coverage-is-at-90-every-gate-is-green-and-a-defect-reaches-production-anyway-what-does-that-tell-you-and-what-do-you-change) — "Coverage is at 90%, every gate is green, and a defect reaches production anyway. What does that tell you, and what do you change?"

  </details>
- **MUST** — Test layering: lint, type check, unit, integration against real containers, functional/contract against the OpenAPI document, smoke after deploy

  <details><summary><strong>Answer</strong></summary>

  Each layer catches a class the others structurally cannot, which is why the pipeline runs lint, type check, unit, integration, functional and post-deploy smoke rather than picking a favourite. Lint plus the import-linter contract catches a boundary violation no test will ever notice, and a type check catches the mismatch between two modules no test exercises together. Unit tests catch the domain rules with no infrastructure; integration against real Postgres, Mongo and Redis catches the query plan and the projection, which are exactly what a mock passes while broken; functional tests against the OpenAPI document catch the contract the admin console and vendor integrations compile against; and the dependency and image scan catches what is true about the artefact rather than about the code. The failure mode is treating them as interchangeable and adding another unit test where an integration test was the only thing that would have caught it. **Deeper:** [interview-questions.md](./interview-questions.md#q1-ruff-a-type-checker-sonarqube-and-trivy-all-gate-this-kind-of-pipeline-what-does-each-catch-that-the-others-do-not) — "Ruff, a type checker, SonarQube and Trivy all gate this kind of pipeline. What does each catch that the others do not?"

  </details>
- **MUST** — Why integration tests use real Postgres/Mongo/Redis: query plans and a projection pipeline are exactly what a mock passes while broken

  <details><summary><strong>Answer</strong></summary>

  Because the things most likely to be wrong here are precisely the things a mock cannot have an opinion about: a mocked repository returns what you told it to and says nothing about whether the planner used `idx_plf_browse` or fell back to a sequential scan, a fake queue cannot reproduce redelivery, and an in-memory cache cannot reproduce a stampede. The projection pipeline in particular is only meaningful end to end — publish, relay, project, invalidate, read — so Docker Compose brings up Postgres, Mongo and Redis at the pinned versions and the tests run against them, seeded with enough rows that a plan assertion means something. Pinning matters as much as being real, since a plan or a driver behaviour that differs between minor versions is exactly what you are trying to catch. What it costs is a slower stage and a class of flakiness that comes from real infrastructure, and the answer to that is container reuse and proper isolation rather than going back to mocks. **Deeper:** [interview-questions.md](./interview-questions.md#q2-integration-tests-run-against-real-postgresql-mongodb-and-redis-in-docker-compose-rather-than-mocks-what-specifically-does-that-catch) — "Integration tests run against real PostgreSQL, MongoDB and Redis in Docker Compose rather than mocks. What specifically does that catch?"

  </details>
- **MUST** — Ordering migrations relative to deploy, and expand/contract as the rule

  <details><summary><strong>Answer</strong></summary>

  `alembic upgrade head` runs before the deploy, and it only ever runs the expand half — nullable columns, new tables, indexes built `CONCURRENTLY`. That ordering is what lets the old image keep serving during the rollout, and it is the reason rollback is a redeploy rather than a restore. The contract half, dropping what nothing reads any more, lands as a separate merge request at least one release later, which is a discipline that has to be defended in review because it always looks like unnecessary ceremony on a small change. The mirror rule is that a migration must not depend on the new code having deployed: a backfill runs after, as a job, not inside the migration, or a slow data migration holds the pipeline and takes a lock while it does. And every lock-taking statement runs under a statement timeout, so a migration that cannot get its lock fails the deploy loudly rather than queueing behind a long read and stalling the table.

  </details>
- **NICE** — Environment promotion, staging that is the same topology at smaller size, and what makes a staging smoke test meaningful

  <details><summary><strong>Answer</strong></summary>

  Why staging is the same topology at smaller instance sizes is owned by "Environments" in the Terraform topic; the pipeline's contribution is that promotion moves an artefact rather than rebuilding one — the digest that passed staging is the digest deployed to production, so "it worked in staging" is a statement about the same bytes rather than about the same commit. That narrows what the smoke test has to prove, and being explicit about it matters: that the thing which shipped is running, reachable through the real edge, talking to its real data stores and on the migration it expects — not that the feature is correct, which the earlier stages already gated. The honest limit is that staging carries neither production's data volume nor its traffic, so it cannot tell you anything about a query plan or a cache hit ratio; it tells you about wiring, and treating a green smoke as a performance signal is precisely how an unverified latency figure gets quoted.

  </details>
- **NICE** — Supply chain: digest-pinned images, hash-pinned dependencies, [CVE](https://www.cve.org/ "Common Vulnerabilities and Exposures — Public identifier for a known software security flaw") scanning, SBOM, weekly base-image rebuilds

  <details><summary><strong>Answer</strong></summary>

  Digest pinning, hash-pinned dependencies and the weekly rebuild are answered under "Docker fundamentals" in the Kubernetes topic; what is left here is the gate and the one piece this design does not have. The scan stage sits after build and before migrate, so it gates the artefact rather than the source — a dependency audit and an image CVE scan of the exact digest that would ship — and the decision that has to be made explicitly is which severity fails the build, because a gate that goes red on every medium finding is bypassed within a month. A software bill of materials is not in this design and I would not claim otherwise: it is the inventory that turns "are we exposed" from a rescan into a query, which is the difference between hours and minutes on the day a widely used library is disclosed. Generating one at build and storing it beside the digest is the cheap version, and its absence here is a gap rather than a rejection. **Deeper:** [interview-questions.md](./interview-questions.md#q1-ruff-a-type-checker-sonarqube-and-trivy-all-gate-this-kind-of-pipeline-what-does-each-catch-that-the-others-do-not) — "Ruff, a type checker, SonarQube and Trivy all gate this kind of pipeline. What does each catch that the others do not?"

  </details>
- **MUST** — Secrets in CI: OIDC federation to the cloud instead of stored credentials

  <details><summary><strong>Answer</strong></summary>

  Stored credentials in CI are the worst secret you have: long-lived, broadly scoped, readable by any job on a protected branch, and reused across every deploy. OIDC federation removes them — GitLab CI presents a short-lived token that Azure trusts for a specific project, branch and environment, so there is nothing to rotate and nothing that keeps working after the pipeline ends. The claims it federates on are the actual access control, and getting them too broad is the mistake worth checking: federating on "any pipeline in this project" is close to having a stored credential again. Beyond that, secrets should be masked and never echoed, and the real hazard is diagnostic — `set -x` in a deploy script, or a failing command printing its environment. The design also names the residual risk honestly: the CI deploy identity can apply Terraform across the subscription, which is the largest single concentration of privilege in the system and is flagged for splitting into plan-only and apply identities.

  </details>
- **MUST** — Debugging a failing pipeline: reproducing the runner environment, exit codes versus output text, the pipe that swallows a status

  <details><summary><strong>Answer</strong></summary>

  The first move is to reproduce the runner rather than argue with it: run the same image, the same command line and the same shell flags locally, because "works on my machine" here almost always means a different tool version, a warm cache the runner does not have, or a different working directory. The second is to distrust the output and look at exit codes — a pipeline that reports success because a command was piped into `tail`, or fails because a `grep` correctly found nothing under `set -e`, is a very common and very confusing class of bug. Write the output to a file and capture the status on the command's own line rather than reading the last line of a block. After that: is it order-dependent, does it pass alone and fail in parallel, is a service container slow to be ready, is the failure in the gate or in the thing being gated. And the answer that resolves fastest is usually to make the failure smaller before making it understandable.

  </details>

## 17. Terraform and Infrastructure as Code

**Backs:** provisioned Azure marketplace infrastructure with [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files").

- **MUST** — The core loop: providers, resources, data sources, plan/apply, the graph

  <details><summary><strong>Answer</strong></summary>

  A provider is the plugin that knows an API, a resource is a thing you declare, a data source is a thing you look up without owning, and `plan` shows the difference between the declaration and reality before `apply` makes it true. Underneath is a dependency graph built from references, which is why Terraform can create unrelated resources in parallel and why an implicit reference is usually better than `depends_on` — the graph should come from the data flow, not from a hint. The mental shift that matters is declarative rather than imperative: you describe the end state, and a resource whose immutable attribute changed is destroyed and recreated rather than edited, which for a database or a Service Bus namespace is an outage you find in the plan output. Reading the plan properly — and treating any unexpected replace as a stop — is the actual skill, more than writing the configuration.

  </details>
- **MUST** — State: what it is, remote backends, locking, why it is sensitive, and never editing it by hand

  <details><summary><strong>Answer</strong></summary>

  State is Terraform's record of which real resource each declared resource maps to, and without it a plan cannot tell "create this" from "this already exists". It lives here in the `tfstate/` container of `blob-media` with versioning and lease locking, and each of those three properties answers a specific failure: remote means every apply sees the same state rather than whatever is on someone's laptop; locking means two concurrent applies cannot interleave and corrupt it; versioning means a bad apply is recoverable to the previous state rather than being reconstructed by hand. It is sensitive because it contains resource attributes in the clear, which is why secrets must not enter it and why access to the container is a privilege on the level of database access. And it is never edited by hand — the supported operations are `import` to adopt an existing resource and `state mv`/`rm` for a refactor, both of which are auditable in a way that a text edit is not. **Deeper:** [interview-questions.md](./interview-questions.md#q1-terraform-state-lives-in-a-locked-versioned-blob-container-and-applies-run-only-from-ci-what-does-each-of-those-three-properties-protect-against) — "Terraform state lives in a locked, versioned blob container and applies run only from CI. What does each of those three properties protect against?"

  </details>
- **MUST** — Modules and composition; variables, outputs, locals; version pinning for providers and modules

  <details><summary><strong>Answer</strong></summary>

  A module is a unit of reuse with a declared interface — variables in, outputs out, locals for the arithmetic in between — and the useful discipline is that its interface should be about intent rather than about the provider, so a caller asks for an environment size rather than passing forty resource attributes through. Composition is where it gets abused: deeply nested modules make the plan unreadable and the graph hard to reason about, and my default is a shallow layer of modules over resources rather than a framework. Version pinning is not optional for either providers or modules, because both change behaviour between releases and an unpinned provider means a plan that differs by the day someone ran it — which destroys the property that makes plan review meaningful. Registry modules deserve particular suspicion, since a third-party module is code with your cloud credentials, and pinning it by version is the minimum rather than the answer.

  </details>
- **MUST** — Environments: workspaces vs directories vs variable files, and keeping them one module set so staging really matches production

  <details><summary><strong>Answer</strong></summary>

  The three options trade the same thing differently: workspaces share one configuration and one backend prefix, which is light but makes running the wrong one easy; separate directories are explicit and drift apart the moment someone fixes production without back-porting; variable files over one module set sit in between. This design takes the last of those — separate workspaces over one module set, differing only in a variables file — and the point is not tidiness but that staging is then the same topology at smaller instance sizes, which is the only thing that makes a staging smoke test predictive. A staging environment built from different modules tests the environment rather than the change. What it costs is that a production-only resource becomes a conditional in shared code, which is uglier than a separate directory and worth it, because the alternative decays into two topologies that no longer predict each other.

  </details>
- **MUST** — Drift: a resource created in the portal is drift and should be reported as a failure; import for adopting existing resources

  <details><summary><strong>Answer</strong></summary>

  Drift is the gap between what the configuration declares and what the cloud actually has, and it happens the first time somebody fixes something in the portal during an incident. The position I would hold is that drift is a failure to report, not a nuisance to reconcile silently — a scheduled `plan` on the default branch that exits non-zero when the diff is non-empty makes it visible on the day it happens rather than on the day the next apply reverts someone's fix and causes a second incident. That is also why alert rules here are Terraform-managed and explicitly not editable in the portal: an alert silenced by hand during an incident and never restored is the standard way monitoring rots. `import` is the escape hatch for adopting a resource that already exists — bringing it under management rather than recreating it — and it is the right response to discovered drift, along with asking why the portal was reachable for writes at all.

  </details>
- **NICE** — Managing alert rules and IAM role assignments as code so a widened permission is a reviewable diff

  <details><summary><strong>Answer</strong></summary>

  Both halves are answered above — the alert-rule case under "Drift" in this topic, the role-assignment case under "Workload identity" in Kubernetes and "Secrets" in Security Beyond Authentication. What is genuinely this bullet's own is why the two belong in one sentence: both are controls whose failure is invisible, so declaring them converts a silent widening into a diff somebody has to approve, which is the only review that catches a permission nobody would have thought to look for. The thing to watch is that it holds only while the portal is not a write path — one role assignment made by hand and the next apply either reverts it mid-incident or, worse, leaves it, because nothing was declared for it to conflict with.

  </details>
- **MUST** — Applying only from CI, plan-review gates, and the blast radius of the deploy identity (splitting plan-only from apply, separating network/data-plane state)

  <details><summary><strong>Answer</strong></summary>

  Applying only from CI is what makes every other control real: the pipeline is the only identity with apply rights, so the audit trail is complete, the state lock is respected, and nobody applies from a laptop with a stale provider version. Plan-review gating is the human part — the plan is the diff being reviewed, not the configuration, because the configuration change and its effect are not the same thing. The blast radius is the piece this design flags rather than solves: one deploy identity can apply Terraform across the whole subscription, which is the largest single concentration of privilege in the architecture. The stated remedy is to split plan-only from apply, gate apply on protected-branch pipelines, and separate the network and data-plane modules into their own state with their own identity — so that a compromised merge-request pipeline can read a plan and change nothing, and a compromised apply cannot reach the database plane.

  </details>
- **MUST** — Secrets that must not enter state; Key Vault references

  <details><summary><strong>Answer</strong></summary>

  Anything Terraform reads into a resource attribute ends up in state in plain text, so a password or key passed as a variable is now sitting in a blob container with a much wider reader set than the vault it came from. The rule is to reference rather than to carry: create the secret outside Terraform or let the resource generate it, then reference it by Key Vault URI so the value never becomes a Terraform value at all. Where a resource genuinely requires the secret, the honest position is that the state is now sensitive at that level and must be protected accordingly, rather than pretending it is not. The related trap is outputs — an output marked sensitive is hidden from the console and is still in state and still available to any module that consumes it, so `sensitive = true` is a display setting, not a control.

  </details>
- **NICE** — What IaC does not give you: it is not a test that the topology works

  <details><summary><strong>Answer</strong></summary>

  A successful `apply` proves the provider accepted the declarations, not that the system works: a NetworkPolicy can apply cleanly and deny a path the application needs, a private endpoint can exist with no DNS zone linked to it, an alert rule can be created against a metric nothing emits — and every one of those is green in Terraform. The gap is that Terraform asserts existence and configuration and never behaviour, so what closes it is the post-deploy smoke test and, for the controls specifically, a check that exercises them: a connection that should be refused being refused, an alert made to fire in staging by stopping the worker. The alert rule is the trap that catches people, because it is both declared as code and never observed until the day it was supposed to fire.

  </details>

## 18. Observability and Alerting

**Backs:** monitored services with Azure Monitor, tracking API errors and job failures on catalog and connection flows.

- **NICE** — RED and USE methods for choosing what to measure

  <details><summary><strong>Answer</strong></summary>

  RED — rate, errors, duration — is the request-shaped view, and it is what the service SLIs here are: `catalog_search_latency_seconds`, `catalog_read_availability`, `write_path_availability`. USE — utilisation, saturation, errors — is the resource-shaped view, and it is where `postgres_replica_lag_seconds`, `celery_queue_depth` and connection-pool occupancy live. They are complementary rather than alternatives: RED tells you a user is suffering, USE tells you which resource to look at, and a dashboard with only one of them either cannot see a cause or cannot see an effect. What neither method prompts you to add is the failure this system fears most — an asynchronous step that stops without erroring — which is why `indexer_lag_seconds` and `outbox_unpublished_age_seconds` exist as a third category, freshness, that has to be reasoned about rather than derived from a checklist.

  </details>
- **MUST** — Metric types: counters, gauges, histograms; percentiles and what a p95 from a histogram really means; label cardinality

  <details><summary><strong>Answer</strong></summary>

  A counter only goes up and you read its rate; a gauge is a level you read directly, like queue depth or replica lag; a histogram buckets observations so you can compute quantiles after the fact. The thing worth being precise about is what a p95 from a histogram actually is: it is an interpolation within whichever bucket the 95th observation falls into, so its accuracy is entirely a function of bucket boundaries — and if your buckets top out at 250 ms, every slow request reports as 250 ms and your tail simply disappears. Percentiles also do not average: you cannot mean the p95s of five pods, or of twelve five-minute windows, and get anything a user experienced. Label cardinality is the other trap, and it is an availability one rather than an accuracy one — a label carrying `product_id` or `request_id` multiplies series until the metrics backend is the outage. `org_id` is fine on a log line and would not be fine as a metric label here.

  </details>
- **MUST** — SLI, [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), error budget, burn-rate alerting, and page vs ticket severity

  <details><summary><strong>Answer</strong></summary>

  An SLI is a measured ratio of good events to valid events; an SLO is the target you commit to; the error budget is what the target leaves you — 99.9% monthly on catalog reads is roughly 43 minutes, which is a spendable quantity rather than a slogan. Burn-rate alerting is what makes that usable: you alert on the rate at which the budget is being consumed rather than on a raw threshold, so a 14.4× burn over an hour pages because it exhausts a month in two days, while a slow trickle raises a ticket. That distinction is the whole point — a threshold alert either pages on noise or misses a sustained slow burn. The severity rule I hold is that a page must be actionable now by the person woken, and everything else is a ticket: `indexer_lag_seconds` above sixty seconds pages because nothing else surfaces a dead indexer, whereas replica lag above thirty seconds is a ticket because the service already fails back to the primary on its own. **Deeper:** [interview-questions.md](./interview-questions.md#q3-of-the-alerts-in-this-design-which-would-you-page-a-human-for-at-three-in-the-morning-and-which-would-you-not) — "Of the alerts in this design, which would you page a human for at three in the morning, and which would you not?"

  </details>
- **MUST** — Detecting silent failure: lag and backlog-age metrics that fire when nothing is erroring at all (a dead indexer, a stalled outbox relay)

  <details><summary><strong>Answer</strong></summary>

  The failures that hurt most here produce no errors at all: `indexer-worker` dies and publishes still succeed, browse still serves, the error rate stays flat, and new listings never become searchable — you find out from a vendor. So the metrics that matter are freshness and backlog age rather than error rate: `indexer_lag_seconds` from the event's `occurred_at` to the row's `projected_at`, and `outbox_unpublished_age_seconds` on the oldest unpublished row, both gauges that rise when nothing is happening, which is exactly the signal a rate-based alert cannot produce. The rule I generalise is that any asynchronous step needs a metric that goes wrong when the step *stops*, not when it errors. And the alert itself has to be tested by stopping the worker in staging and confirming it fires, because an alert rule that has never fired is an untested assertion. **Deeper:** [interview-questions.md](./interview-questions.md#q2-how-do-you-test-a-control-whose-failure-is-silent--the-tenant-filter-the-projection-the-audit-write-an-alert-rule) — "How do you test a control whose failure is silent — the tenant filter, the projection, the audit write, an alert rule?"

  </details>
- **MUST** — Structured logging: [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"), correlation fields on every line, tenant id so a support query can be scoped, and hard rules on what never appears in a log (message bodies, tokens, secrets)

  <details><summary><strong>Answer</strong></summary>

  Logs are JSON to stdout, collected by Azure Monitor, and every line carries `request_id`, `trace_id`, `service`, `actor_side`, `org_id`, `route` and `status` — the correlation fields are what turn a log search into a query rather than a text hunt across nine deployments. `org_id` in particular is there so a support question about one retail group can be scoped without a full-text sweep, which is both a speed and a privacy property. The hard rules are what never appears: no `connection_message.body`, no token, no client secret — and those have to be enforced by a formatter and a test rather than by remembering, because the one place a body reaches a log is an exception handler someone added under pressure. The related distinction is that application logs are diagnostics with a short life, and the audit trail is a record: `audit_event` is a partitioned, append-only table written off the outbox, and reconstructing an audit trail from a log pipeline is a mistake you only make once.

  </details>
- **NICE** — Application logs are diagnostics; the audit table is the record — keeping them separate

  <details><summary><strong>Answer</strong></summary>

  That the two are different things is answered above under "Structured logging"; the reason neither can substitute for the other is a list of properties that differ. Logs are sampled, retained for weeks, silently reshaped by a formatter change and lossy by design under pressure; `audit_event` is complete, append-only by grant, partitioned to twenty-four months and archived to immutable blob storage. A log pipeline also decides what to keep on the collector's terms, which is exactly the wrong property for a record you may have to produce to a supervisory authority or to a vendor disputing what an operator did. What tempts people to conflate them is that both are written per action, and the discipline is that the audit write is a domain event off the outbox rather than a log line somebody promoted.

  </details>
- **MUST** — Distributed tracing: spans, context propagation, [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") traceparent, propagation through queue message properties, sampling strategy, and verifying end-to-end trace continuity rather than assuming the instrumentation does it

  <details><summary><strong>Answer</strong></summary>

  A trace stitches one logical operation's work into a tree of spans under a shared identifier, and what it buys here is exactly the chain nobody can reconstruct from logs alone: publish in `vendor-service`, commit the outbox row, relay to `sb-catalog-events`, project in `indexer-worker`, invalidate the cache, notify. Context propagation is what makes that one trace rather than six unrelated ones, and across an asynchronous boundary it means carrying W3C `traceparent` in Service Bus message properties and in Celery headers, since there is no incoming HTTP request to read it from. Sampling has to be biased rather than uniform — 100% of errors and write-path requests, 5% of catalog reads — because a 5% sample of an incident is not an investigation. And the part this design flags rather than assumes: continuity across Service Bus and Celery depends on the OpenTelemetry instrumentation versions actually injecting and extracting the header, which has been partly manual in the past, so the versions are pinned and an integration test asserts one trace id end to end rather than trusting it during an incident. **Deeper:** [interview-questions.md](./interview-questions.md#q3-telemetry-here-goes-to-azure-monitor-and-application-insights-the-target-environment-runs-the-elk-stack-with-kibana-and-elastic-apm-what-transfers-and-what-would-you-have-to-build-differently) — "Telemetry here goes to Azure Monitor and Application Insights. The target environment runs the ELK stack with Kibana and Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production"). What transfers, and what would you have to build differently?"

  </details>
- **NICE** — OpenTelemetry as the instrumentation layer and Azure Monitor/App Insights as the backend

  <details><summary><strong>Answer</strong></summary>

  The point of the split is that instrumentation and backend are separable: the application depends on the OpenTelemetry [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform"), and metrics, logs and traces leave through one exporter with one set of resource attributes, so Azure Monitor is a configuration rather than a coupling. That matters concretely here — no Azure-specific telemetry call appears in the code, so pointing the same instrumentation at Prometheus and an ELK stack is an exporter change plus rebuilding dashboards and alert rules, and the rebuilding is where the actual work is. What OpenTelemetry does not give you for free is portability at the semantic level: attribute names and histogram bucket boundaries still have to match what the destination queries, and the auto-instrumentation versions are a flagged risk in this design rather than a solved problem. **Deeper:** [interview-questions.md](./interview-questions.md#q3-telemetry-here-goes-to-azure-monitor-and-application-insights-the-target-environment-runs-the-elk-stack-with-kibana-and-elastic-apm-what-transfers-and-what-would-you-have-to-build-differently) — "Telemetry here goes to Azure Monitor and Application Insights. The target environment runs the ELK stack with Kibana and Elastic APM. What transfers, and what would you have to build differently?"

  </details>
- **NICE** — Alert hygiene: alerts as code, an alert silenced by hand during an incident and never restored is how monitoring rots

  <details><summary><strong>Answer</strong></summary>

  Alerts as code is answered under "Drift" in the Terraform topic, and the rest of alert hygiene is this bullet's own subject. The rot is rarely one hand-silenced rule: it is a page that fires weekly and is always dismissed, a threshold quietly loosened until it can no longer fire, and an alert with no named owner or runbook — each of which trains the on-call to read the channel as noise, after which the one real page is missed for the same reason. The countermeasures are boring and effective: every rule names an owner and a runbook, page versus ticket is decided by whether a human can act now, and an alert that has never fired is reviewed rather than trusted, because it is an untested assertion about a failure nobody has reproduced. **Deeper:** [interview-questions.md](./interview-questions.md#q3-of-the-alerts-in-this-design-which-would-you-page-a-human-for-at-three-in-the-morning-and-which-would-you-not) — "Of the alerts in this design, which would you page a human for at three in the morning, and which would you not?"

  </details>

## 19. Testing Practice

**Backs:** wrote unit, integration and functional tests with Pytest for catalog, auth and connection paths.

- **MUST** — The test pyramid and what each layer is actually for here

  <details><summary><strong>Answer</strong></summary>

  The shape is a consequence rather than a target: many fast tests that need nothing, fewer that need real infrastructure, fewest that drive the whole system. Unit tests own the domain rules — a listing cannot publish while its vendor is `pending`, a connection bills at most once — and they run with no container because the dependency rule made that possible. Integration tests own everything that is a property of the real dependency: the query plan on `product_listing_facets`, the projection round trip, a redelivered event being a no-op. Functional tests own the contract the admin console and vendor integrations compile against, and smoke after deploy owns the one question the others cannot answer, which is whether the thing that shipped is actually running. The failure mode is an inverted pyramid where every check needs the whole stack, and the pipeline gets slow enough that people stop running it. **Deeper:** [interview-questions.md](./interview-questions.md#q1-unit-integration-and-functional-tests-all-gate-this-pipeline-what-does-each-catch-that-the-others-do-not) — "Unit, integration and functional tests all gate this pipeline. What does each catch that the others do not?"

  </details>
- **MUST** — Pytest mechanics: fixtures and scopes, parametrize, factories, markers, conftest layering, plugins for async

  <details><summary><strong>Answer</strong></summary>

  Fixtures are dependency injection for tests, and scope is the lever that decides both speed and isolation — a session-scoped container with a function-scoped transaction is the combination that makes an integration suite fast without letting tests see each other's writes. `parametrize` is how one assertion covers every repository method or every account type, which is what turns an authorization test from exemplary into exhaustive. Factories beat fixture files because a test should state only the fields it cares about and let the rest be plausible defaults, so adding a required column does not break two hundred tests. Markers separate the fast suite from the ones needing Compose, which is what lets the pipeline stage them. `conftest.py` layering puts shared fixtures at the right level rather than in one god-module, and for this codebase `pytest-asyncio` is not optional, along with being deliberate about the event loop's scope — a loop shared across tests with an async engine bound to a different one is the most common async test failure there is.

  </details>
- **MUST** — Test data: factories over fixtures-as-files, deterministic seeds, realistic volume when the assertion is about a query plan

  <details><summary><strong>Answer</strong></summary>

  Factories beat fixture files, because a fixture file is a snapshot that rots while a factory states the intent — "a published listing in the point-of-sale category with two integrations" — and fills the rest with plausible defaults, so adding a required column does not break two hundred tests. Randomised data has to be seeded and the seed printed on failure, or a failure is not reproducible. The point I would insist on is volume, when the assertion is about a plan: a query tested against a hundred rows will use a sequential scan and pass, and tells you nothing about forty thousand, because the planner's choice is a function of table size and selectivity. So those tests seed realistic volume, run `ANALYZE` afterwards so the statistics describe the data rather than an empty table, and assert on the plan rather than on latency — latency in CI is noise, but "this query used `idx_plf_browse`" is a stable assertion.

  </details>
- **MUST** — Isolation: transactional rollback per test, database truncation, container reuse; parallel test runs and shared-state hazards

  <details><summary><strong>Answer</strong></summary>

  The fast pattern is a transaction per test rolled back at the end: no cleanup, no ordering dependency, and it works for everything except code that commits or that spans connections. Truncation between tests is the slower, more honest fallback, and it is what the projection tests need because they genuinely span a commit. Container reuse across the session is what makes either affordable. Parallelism is where isolation stops being free — a shared Postgres, a shared Redis keyspace and a shared Mongo database mean two workers fight, so each worker needs its own database or its own key prefix, and Redis is the one people forget because it has no schema to separate. The rule I hold is that a test that only passes when run alone is already broken, and a test that only passes in a particular order is worse, because the order will change and the failure will arrive attached to an unrelated merge request.

  </details>
- **MUST** — Integration tests against real dependencies via Compose/testcontainers

  <details><summary><strong>Answer</strong></summary>

  Compose or testcontainers brings up Postgres, Mongo and Redis at the pinned versions, and the reason is that the highest-risk parts of this system are the ones a mock cannot model: a `GIN` bitmap plan, a `jsonb` containment predicate, an upsert with a revision guard, a redelivered event, a TTL expiry. Every one of those passes trivially against a mock while being wrong. Pinning versions matters as much as being real, since a plan or a driver behaviour that differs between minor versions is exactly the thing you are trying to catch — testing against whatever `latest` pulled is testing a different system. What it costs is a slower stage and infrastructure flakiness, and the honest mitigation is container reuse, health-gated startup and proper isolation rather than retrying the test. The line I draw is that a mock is right for something you own and can change, and wrong for something whose behaviour is the thing under test.

  </details>
- **MUST** — Functional/contract tests against the OpenAPI schema

  <details><summary><strong>Answer</strong></summary>

  The OpenAPI document is generated from the Pydantic models, so it is a build artefact rather than documentation, and that is what makes contract testing possible at all: the tests assert that a real request against a running service matches the schema the admin console and vendor integrations compiled against. What that catches is drift nobody intended — a field quietly becoming optional, an enum gaining a value, an error shape changing — none of which any unit test is looking at. The breaking-change rules follow from who consumes it: removing a field or tightening a type breaks clients, adding an optional field does not, and shipping a field that must be required is a two-step — add it optional, wait for clients, then require it — which is expand/contract applied to an API instead of a schema. The other property worth asserting is negative: that no admin capability exists which the public contract does not already describe, since the admin console deliberately has no private backend. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-frontend-team-generates-its-client-from-your-openapi-document-what-counts-as-a-breaking-change-and-how-do-you-ship-a-field-that-must-be-required) — "The frontend team generates its client from your OpenAPI document. What counts as a breaking change, and how do you ship a field that must be required?"

  </details>
- **MUST** — Authorization tests as first-class: cross-tenant reads must return empty for every repository method, on every endpoint

  <details><summary><strong>Answer</strong></summary>

  Authorization is the one area where a failure is silent — no error, no alert, just the wrong data returned to someone entitled to be there — so the tests have to assert the absence directly and exhaustively. The shape is a parametrised sweep: for every org-owned repository method, call it as org A for org B's row and assert empty; for every endpoint, present each account type and assert the ones that should be refused are refused. Exhaustive rather than exemplary is the whole point, because the failure mode is the endpoint someone added last week, and a sweep over the route table fails on that where a hand-written test per endpoint never does. The marketplace-specific version is an assertion about a schema rather than a row: no vendor-scoped response carries a retailer field. And every one of these has to be shown to fail — remove the session filter and confirm the suite goes red, or you have written a test that asserts nothing. **Deeper:** [interview-questions.md](./interview-questions.md#q2-the-threat-model-says-a-vendor-enumerating-the-retailer-directory-would-kill-the-marketplace-how-is-that-prevented-and-how-do-you-test-for-an-absence) — "The threat model says a vendor enumerating the retailer directory would kill the marketplace. How is that prevented, and how do you test for an absence?"

  </details>
- **NICE** — Idempotency and retry tests; failure injection (kill the worker, drop the cache, stall the broker)

  <details><summary><strong>Answer</strong></summary>

  The kill test for import durability is owned by "Durability" in the Celery topic; what belongs here is that this is a test layer rather than a one-off exercise. The behaviours this design depends on are all invisible to ordinary tests: a redelivered event being a no-op, a stale-revision event being discarded, business rate limiting failing closed for writes and open for reads when `redis-cache` is gone, the reconciliation job re-projecting a row whose event was lost. Each is a test that injects the failure against the real dependency in Compose — kill the worker mid-chunk, stop Redis, pause the relay — and asserts the specific recovery rather than the absence of an error. What it costs is the slowest and flakiest stage in the suite, which is an argument for running it on merge rather than on every push, not for not having it.

  </details>
- **MUST** — What a test that has never failed proves: nothing — mutate the code and confirm the test catches it

  <details><summary><strong>Answer</strong></summary>

  Nothing — a test that has only ever passed is indistinguishable from a test that asserts nothing at all, and both are green. The cheap way to find out is to mutate the code the test claims to cover, flipping the comparison or deleting the filter, and confirm the test goes red for the reason you expect; if it fails for a different reason, it is testing something else. That is the only way to trust a check whose subject is an absence, like the tenant filter or the contract test asserting no retailer field appears in a vendor response. The related discipline is that a fixture exercising several behaviours can honestly test only the first that fires, so each behaviour needs a fixture where its trigger appears alone. Coverage says nothing about any of this, since a line can be executed by a test that makes no assertion on it — which is how a suite reaches ninety per cent and still lets a defect through. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-a-test-coverage-number-actually-tell-you-and-what-does-it-not) — "What does a test coverage number actually tell you, and what does it not?"

  </details>
- **NICE** — Coverage as a signal, not a target

  <details><summary><strong>Answer</strong></summary>

  Answered above, at the end of "What a test that has never failed proves": a line can be executed by a test that asserts nothing, so coverage measures reach and not assertion. The one thing to add is what it is genuinely good for — the delta rather than the level, because a merge request that drops coverage on a file it touched is a question worth asking, while an absolute target is a number people learn to satisfy. **Deeper:** [interview-questions.md](./interview-questions.md#q1-what-does-a-test-coverage-number-actually-tell-you-and-what-does-it-not) — "What does a test coverage number actually tell you, and what does it not?"

  </details>

## 20. Security Beyond Authentication

**Backs:** auth module refactoring, uploads, and operating a three-sided marketplace.

- **MUST** — Threat modelling: trust boundaries, STRIDE, and the insight that the dangerous adversary on a marketplace is authenticated and legitimate

  <details><summary><strong>Answer</strong></summary>

  Threat modelling is drawing the trust boundaries and then asking, per boundary, what an adversary on the wrong side could do — STRIDE is a useful checklist for that, prompting spoofing, tampering, repudiation, information disclosure, denial of service and elevation of privilege at each one. The insight that reorders everything on a three-sided marketplace is that the dangerous adversary is authenticated and legitimate: competing vendors and competing retail groups are on the same platform, and the highest-value attacks need no exploit at all. A vendor enumerating the retailer directory to build a sales list kills the buyer side; a vendor reading a competitor's drafts or connection volume is competitive intelligence; a retail group reading another's shortlists leaks sourcing strategy. Every one of those is an authorization problem, not a network problem, and that ordering is why tenant scoping gets the most rigour here and the perimeter controls are competent but conventional.

  </details>
- **MUST** — [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") API Top 10, especially object- and function-level authorization

  <details><summary><strong>Answer</strong></summary>

  The list is useful mostly because its top entries are boring and true: broken object-level authorization and broken function-level authorization sit at the top because they are the ones that require no skill to exploit and no anomaly to detect. Object level is "the endpoint checked who you are and then trusted the id in the path", and the structural answer here is that no repository method takes an id without the tenant. Function level is "the endpoint exists and nobody checked whether this account type may call it", answered by the router-level `act` dependency plus a contract test over the route table rather than per-endpoint decorators. Below those, unrestricted resource consumption is the marketplace-relevant one — it is what the per-org business quotas and the capped result counts address. The general lesson I take is that the top of that list is not about exotic vulnerabilities, it is about checks that were written once per endpoint instead of once per system.

  </details>
- **MUST** — Injection and validation: parameterised queries, ORM escapes and where they leak, schema validation rejecting unknown fields

  <details><summary><strong>Answer</strong></summary>

  Parameterised queries are the whole answer to SQL injection, and using an ORM gets you them by default — which is exactly why the leaks are worth knowing, because they are all the places you left the ORM: raw text fragments, a `text()` clause with interpolation, an ORDER BY column name taken from a query parameter, a `LIKE` pattern built by concatenation. The catalog search here uses SQLAlchemy Core with hand-written predicates for plan reasons, so it is the path where this needs actual attention rather than trust. Full-text search adds its own: `to_tsquery` will reject or misparse user input, so it goes through `websearch_to_tsquery` or a sanitiser rather than straight through. On the document side, a query built from a user-supplied dictionary can smuggle operators into Mongo, so input is validated into a typed model before it becomes a filter. And every request body is a Pydantic model with `extra="forbid"`, so an unknown field is rejected rather than absorbed — with vendor `attributes` additionally validated against the category's `facet_schemas`, which is the only untyped input this system accepts.

  </details>
- **MUST** — File upload handling: content-type allowlists, size caps, re-encoding images, serving untrusted files from a separate hostname with attachment disposition, stored [XSS](https://owasp.org/www-community/attacks/xss/ "Cross Site Scripting — Attack that injects malicious script into content viewed by other users")

  <details><summary><strong>Answer</strong></summary>

  Uploads are the one place a marketplace accepts arbitrary bytes from one tenant and serves them to another, so the defaults have to be hostile. Content type is an allowlist checked against the actual bytes rather than the declared header or the extension, with a size cap enforced at the edge rather than after buffering. Images are re-encoded by `fn-media-process` rather than passed through, which strips whatever was hiding in the container and normalises them at the same time. The property I would defend hardest is the serving side: vendor-supplied datasheets go out from `blob-media` with `Content-Disposition: attachment` through a dedicated download hostname on Front Door, so nothing untrusted is ever served from the origin that hosts the admin console — an origin boundary is what turns a stored cross-site scripting payload from an account takeover into a downloaded file. Content-addressed paths do the rest, since a vendor cannot overwrite an asset another revision is serving.

  </details>
- **NICE** — Scraping and enumeration defence: per-subject limits, capped result counts, absence of a bulk export

  <details><summary><strong>Answer</strong></summary>

  The individual mechanisms are answered elsewhere — per-subject business limits under "Rate limiting and quotas" in the API topic, capped counts under "Facet counts" in Search — and what makes them a defence rather than three unrelated settings is that they were chosen together against one adversary: an authenticated account copying the catalog for a rival marketplace. The three that carry it are a per-vendor cap on listing detail fetches, so systematic collection is slow enough to notice; `total_estimate` capped at 1,000, so the result set's size is not itself an inventory; and the absence of any bulk export endpoint, which is a deliberate hole in the API rather than a feature nobody got round to. The honest limit is that none of this stops a patient scraper — a rival with a legitimate account and a month can have the catalog — so the real control is detection and account termination, and the design's contribution is making the traffic shape visible rather than pretending at prevention.

  </details>
- **MUST** — Encryption in transit ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") versions, [HSTS](https://datatracker.ietf.org/doc/html/rfc6797 "HTTP Strict Transport Security — Instructs browsers to only ever connect to a site over HTTPS"), certificate verification, private endpoints) and at rest (TDE, [CMK](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys "Customer Managed Key — An encryption key the customer controls rather than the cloud provider"), envelope encryption, key rotation)

  <details><summary><strong>Answer</strong></summary>

  In transit is TLS 1.3 from client to Front Door with HSTS and preload, 1.2 as the floor for older vendor integrations, TLS with certificate verification to every data store, and private endpoints so no store has a public IP at all. The gap is deliberate and stated: service-to-service inside the namespace is plaintext HTTP behind a default-deny NetworkPolicy, because doing mTLS properly means a service mesh, and a mesh's cost — sidecar lifecycle, certificate rotation, a new failure mode in every request path — is disproportionate for nine workloads in one namespace with no untrusted tenant. The trigger to revisit is concrete rather than aspirational: a second tenant-facing workload in the cluster, a customer-supplied container, or a compliance requirement naming internal encryption in transit. At rest it is [AES-256](https://csrc.nist.gov/pubs/fips/197/final "Advanced Encryption Standard with a 256-bit key — Symmetric encryption of data at rest and in transit") storage and transparent database encryption with customer-managed keys in Key Vault, and the honest note is that volume encryption protects against a stolen disk and does nothing against a compromised application — which is why `connection_message.body` is protected by access control rather than by field encryption, so the operator can still moderate abuse. **Deeper:** [interview-questions.md](./interview-questions.md#q3-there-is-no-mutual-transport-layer-security-between-services-defend-that-and-name-the-exact-trigger-that-would-change-it) — "There is no mutual Transport Layer Security between services. Defend that, and name the exact trigger that would change it."

  </details>
- **MUST** — Secrets: managed vaults, workload identity, no static credentials, least privilege per workload, and the blast radius of the CI deploy identity

  <details><summary><strong>Answer</strong></summary>

  The rule is that nothing static exists to steal: AKS workload identity federates a Kubernetes service account to a managed identity per service, GitLab CI federates to Azure by OIDC, and the data stores use Entra ID authentication where the driver supports it, with Key Vault as the fallback rather than the default. Least privilege is per workload rather than per cluster — `catalog-service` reads its own secrets and has nothing on Service Bus, only `vendor-service` and `catalog-import-worker` may write the `listings/` and `imports/` prefixes, only the relay may send on the event topics. Those assignments are Terraform resources, so widening one is a reviewable diff rather than an invisible portal click. The residual risk is named rather than hidden: the CI deploy identity can apply across the whole subscription, which is the single largest concentration of privilege here, and splitting plan from apply and separating the data-plane state is flagged as work to do before the first production apply rather than after an incident.

  </details>
- **NICE** — Audit trail: append-only grants, partitioning, immutable archive, written asynchronously and why that is a constraint rather than an optimisation

  <details><summary><strong>Answer</strong></summary>

  The grant and partitioning mechanics belong to the data-modelling topic, under "Append-only tables and revoked UPDATE/DELETE grants"; what belongs to security is why the write is asynchronous. It is not a performance choice: a synchronous audit write on a read would make replica-served catalog reads impossible, because a replica cannot write — so the asynchrony is imposed by the read architecture, and calling it an optimisation would misrepresent what could actually be changed. The cost is stated rather than hidden, that an audit row can trail its event by seconds and in a total outbox loss could be missed. What makes that acceptable is that `outbox_event` commits in the same transaction as the state change, so the record of what happened is durable before the audit row exists at all.

  </details>
- **MUST** — [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") for [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers")/occupational data: lawful basis, minimisation, residency, sub-processors, [DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them"), and erasure conflicting with a counterparty's business record

  <details><summary><strong>Answer</strong></summary>

  Occupational data is still personal data, and the framing that keeps this proportionate is that what is held is limited — names, work email addresses, roles, and the message bodies staff write to each other — with no consumer data, no special-category data and no profiling. Lawful basis is contract for platform users and legitimate interest for marketplace operation with a documented balancing test; minimisation shows up structurally, in that no personal data is projected into `product_listing_facets` or stored in `mongo-catalog` at all. Residency is a single EU region including backups, and the sub-processors — the payment provider, the email provider, Azure — are documented with agreements. Access requests are served by an export endpoint that assembles a subject's profile, audit trail and authored messages. The genuine conflict is erasure, and it is resolved deliberately rather than avoided: identity is tombstoned and message bodies are retained under Article 17(3)(e), because a vendor's record of a commercial negotiation is not the individual's to delete. **Deeper:** [interview-questions.md](./interview-questions.md#q3-right-to-erasure-a-departing-category-managers-identity-is-tombstoned-but-the-messages-they-wrote-are-retained-defend-that-and-state-the-cost) — "Right to erasure: a departing category manager's identity is tombstoned but the messages they wrote are retained. Defend that, and state the cost."

  </details>
- **NICE** — Keeping PCI scope at [SAQ-A](https://www.pcisecuritystandards.org/document_library/ "Self-Assessment Questionnaire A — Lightest PCI-DSS compliance tier for merchants who fully outsource card data handling") by never touching cardholder data, and what changes the moment the platform intermediates a payment

  <details><summary><strong>Answer</strong></summary>

  SAQ-A is the lightest compliance tier and it is available only because no cardholder data enters the platform's network, storage or logs: vendor subscription payments go through the payment provider's hosted fields, and what the schema keeps is `billing_account.psp_customer_ref` and `billing_charge.psp_invoice_ref`, which are opaque external references. That is why payment between retailer and vendor is an explicit non-goal rather than a feature nobody built — the moment the platform intermediates a transaction it is in the flow of funds, and the scope changes category rather than degree, bringing financial-services questions with it that are not an architect's to answer. My position is that this boundary is an architectural asset and has to be defended in product conversations rather than only in the security document, because it is the kind of line that gets crossed by a feature request nobody recognised as one.

  </details>

## 21. Linux and Production Operations

**Backs:** administered Linux hosts for production and development.

- **MUST** — Processes and services: systemd units, journald, signals, exit codes, cron

  <details><summary><strong>Answer</strong></summary>

  A unit file is a declaration of how a process starts, what it depends on and what happens when it dies, and `systemctl status` plus `journalctl -u` is the loop for almost every "the service is not running" question. Exit codes and signals are the part that transfers directly to containers: a process that ignores `SIGTERM` gets `SIGKILL` after the grace period, which on a Celery worker is a lost in-flight task rather than a drained one, and that is the same mechanism as `terminationGracePeriodSeconds` in Kubernetes. `journalctl` versus a log file matters because a container's stdout is the modern equivalent and a service that writes its own log file inside a container is writing to a layer nobody will read. Cron is where scheduled work goes on a host and is precisely what you should *not* use in a cluster, because it runs per host with no coordination — the equivalent here is a CronJob or Celery beat, with the singleton problem stated rather than assumed. **Deeper:** [interview-questions.md](./interview-questions.md#q1-the-cv-lists-administering-linux-hosts-what-does-that-actually-mean-when-everything-runs-as-containers-on-a-managed-kubernetes-service) — "The [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") lists administering Linux hosts. What does that actually mean when everything runs as containers on a managed Kubernetes service?"

  </details>
- **MUST** — Users, groups, file permissions, sudo policy, SSH key management

  <details><summary><strong>Answer</strong></summary>

  The model is owner, group, other with read, write and execute, plus the two that actually catch people out: the execute bit on a directory means traverse rather than run, and a setuid binary runs as its owner rather than its caller. In containers this shows up as the non-root user in the image — a process running as root inside a container is root on the host kernel for anything that escapes, and the file ownership of a mounted volume is a UID number rather than a name, which is why a volume written by one image is unreadable by another. `sudo` policy should be specific commands rather than blanket access, because "who could have done this" is only answerable if the answer is not "everyone". SSH keys are the credential that outlives the person: per-user keys, no shared accounts, no password authentication, and an offboarding step that actually removes them — the same lifecycle problem as a departing category manager's refresh token, one layer down.

  </details>
- **MUST** — Networking: ip/ss, DNS resolution, ports and firewalls, tcpdump basics, debugging a TLS handshake and certificate chain with openssl s_client

  <details><summary><strong>Answer</strong></summary>

  `ss -tlnp` answers "is it listening and as whom", `ip` answers "what does this host think its addresses and routes are", and between them they resolve most of what looks like an application bug. DNS is the first thing to check and the last thing anyone checks: resolution order, search domains, and in a cluster the fact that a service name resolves differently depending on the namespace — a failure that presents as a connection refused rather than as a name error. Ports and firewalls are where a default-deny egress policy shows up, and the symptom of a blocked egress is a hang followed by a timeout, not a rejection. `tcpdump` is for when you no longer believe either side's account of what was sent. And `openssl s_client -connect host:443 -showcerts` is the tool for a TLS problem: it tells you the chain the server actually presented, the protocol version negotiated and whether the name matches — which is usually an expired intermediate or a missing chain rather than anything about the cipher.

  </details>
- **MUST** — Resource troubleshooting: top/htop, iostat, vmstat, free, the OOM killer, ulimits, file-descriptor exhaustion, disk full and inode exhaustion

  <details><summary><strong>Answer</strong></summary>

  The order I work in is: what is saturated, then who is doing it. `top` or `htop` for CPU and memory, `vmstat` for whether the CPU is waiting on I/O rather than working, `iostat` for whether the disk is the reason, and `free` read properly — cached memory is available, and a low "free" number is normal rather than a problem. The OOM killer is the one that leaves the least evidence at the application level: the process simply disappears, and the record is in the kernel log rather than in your logs, which in a container is a `137` exit and an `OOMKilled` reason. File-descriptor exhaustion presents as connection failures under load while everything else looks fine, and it is usually a leaked client rather than a low `ulimit`. Disk full has an evil twin: inode exhaustion, where `df -h` shows plenty of space and `df -i` shows the problem — which is what a directory of millions of small cached files produces.

  </details>
- **OPTIONAL** — Log rotation and retention

  <details><summary><strong>Answer</strong></summary>

  On a host this is `logrotate`: a size or time trigger, compression, a retention count, and either a signal to the writer or `copytruncate` so the process does not keep writing to a deleted inode. It barely applies here, because containers log JSON to stdout and Azure Monitor owns collection and retention — and the container-era version of the failure it guards against is already named under "Processes and services" above.

  </details>
- **OPTIONAL** — Package management and patch cadence for container base images

  <details><summary><strong>Answer</strong></summary>

  The cadence is answered under "Docker fundamentals" in the Kubernetes topic — base images pinned by digest and rebuilt weekly, so that pinning does not quietly come to mean unpatched. What is specific to the package manager is that the rebuild is what actually applies the distribution's security updates, so a `Dockerfile` that pins operating-system package versions as well as the base digest is perfectly reproducible and permanently vulnerable, which is the wrong end of that trade.

  </details>
- **MUST** — Shell fundamentals for safe operational scripting: exit status vs output, pipefail, quoting, and why a pipeline reports only its last stage

  <details><summary><strong>Answer</strong></summary>

  The single most important thing is that a shell reports the status of the last command in a pipeline, so `run | tee log` or `run | grep something` exits with `tee` or `grep`'s status and a failing command reads as a pass. `set -o pipefail` fixes that, or you capture `EXIT=$?` on the command's own line and write output to a file instead. The mirror trap is `set -e` with an assert-absent check: a `grep` that correctly finds nothing exits 1 and kills the script before it prints anything, so the passing branch is the one that dies. Quoting is the other half — an unquoted variable holding a path with a space becomes two arguments, and an unquoted glob expands against whatever happens to be in the directory. My rule for operational scripts is to decide on exit status rather than on output text, to assert the expected failure message rather than the absence of a success string, and to run `shellcheck` over the directory rather than over one file, because a solo invocation silences findings the sweep reports.

  </details>

## 22. Code Review and Refactoring

**Backs:** reviewed pull requests and refactored catalog and auth modules.

- **MUST** — What a review is for: correctness, boundary violations, missing authorization checks, and a diff's effect on contracts others depend on

  <details><summary><strong>Answer</strong></summary>

  A review is for the things a pipeline cannot see. Lint, types and tests already cover shape and behaviour, so a reviewer who spends the diff on formatting has spent it on the one thing a tool owns. What is left is correctness against intent, boundary violations, missing authorization checks, and the effect of the change on contracts other people depend on — a response field quietly becoming optional, a migration that is not expand-only, a new endpoint that skipped the router-level account-type dependency. In this codebase the specific things I would look for are a domain module importing infrastructure, a repository method that takes an id without a tenant, and a new consumer that is not idempotent. The general rule is that a reviewer should be asking what this makes true rather than whether it is written the way they would have written it, and disagreements about style belong to a linter so they stop consuming the attention the real questions need.

  </details>
- **MUST** — Reviewing for duplication: a rule in two places is a defect, and the second occurrence is where you extract

  <details><summary><strong>Answer</strong></summary>

  The rule I hold is that a rule appearing in two places is a defect, and the second occurrence is where you extract — not the third, because by the third the copies have already diverged and the extraction has become a merge. What makes duplication dangerous is not the repeated characters, it is that the two copies must change together and nothing says so; the tenant filter is the clearest example here, which is exactly why it lives in the repository layer rather than in each endpoint. The exception worth naming is the code that merely looks alike: a validation in `vendor-service` and one in `billing-service` may be textually identical and answer to different owners and different rules, and merging those creates a coupling that is worse than the repetition. So the test is not similarity, it is whether a change to one implies a change to the other — and existing repetition in a codebase is evidence of a defect, not evidence that the pattern was wanted.

  </details>
- **MUST** — Refactoring an auth module without a behaviour change: characterisation tests first, small steps, one variable at a time

  <details><summary><strong>Answer</strong></summary>

  The premise of a behaviour-preserving refactor is that you can tell whether behaviour was preserved, so characterisation tests come first: pin the current behaviour including the parts you suspect are wrong, because a refactor that fixes a bug on the way through is two changes and you will not be able to attribute the outcome. For an auth module that means the full matrix — each account type against each router, each role's scope mapping, expired and wrong-audience tokens, a revoked `jti`, a cross-tenant read from every org-owned repository method. Then small steps, one variable at a time, with the suite green between each, because two simultaneous changes give a clean-looking result you cannot trust. The property that makes it survivable here is structural: `identity-service` is its own trust boundary and the token contract — `act`, `org_id`, `roles[]`, `scopes[]` — is what every other service depends on, so as long as the claims are unchanged, the refactor is contained. Changing the claims is not a refactor. **Deeper:** [interview-questions.md](./interview-questions.md#q2-you-reviewed-pull-requests-and-refactored-the-catalog-and-auth-modules-give-me-a-refactor-these-boundaries-made-safe-and-one-that-would-still-be-dangerous) — "You reviewed pull requests and refactored the catalog and auth modules. Give me a refactor these boundaries made safe, and one that would still be dangerous."

  </details>
- **OPTIONAL** — Strangler-fig and branch-by-abstraction for larger moves

  <details><summary><strong>Answer</strong></summary>

  Strangler-fig routes traffic progressively from an old implementation to a new one behind a stable façade until nothing reaches the old one; branch-by-abstraction does the same inside a codebase, introducing an interface both implementations satisfy so the migration happens on the main branch instead of a long-lived one. Neither appears in this design, which is greenfield — the nearest thing it does is expand/contract, the same additive-first, remove-last shape applied to a schema — and if a module here did need replacing, branch-by-abstraction is what I would reach for, because it keeps the pipeline gating the change the whole way through.

  </details>
- **MUST** — Backwards compatibility of an API and a database schema during a refactor

  <details><summary><strong>Answer</strong></summary>

  A refactor is only internal if nothing outside can tell, and two things here can always tell: the API and the schema. On the API the constraint is the generated OpenAPI document that the admin console and vendor integrations compile against — removing a field or tightening a type breaks them, and a field that must become required ships in two steps, optional first and required once the clients have moved. On the schema it is expand/contract, for the same reason in a different vocabulary: the previous image must run against the new schema throughout the rollout, so a rename is add, dual-write, backfill, switch, drop later. The pattern is the same in both cases — additive first, cut over, remove last — and the discipline that actually enforces it is that both the contract test and the contract migration are separate, later merge requests, so the temptation to do it in one step has to survive a review.

  </details>
- **OPTIONAL** — Review as knowledge transfer; disagreeing on substance, not on style a linter should own

  <details><summary><strong>Answer</strong></summary>

  The style half is answered above under "What a review is for". What is left is that a review is often the only place a decision's reasoning reaches anyone else, so the comment worth writing on a nine-deployment codebase is the one that says why a boundary exists, and the question worth asking is the one that makes an author state an assumption they had not noticed making.

  </details>

## 23. Documentation and Operational Writing

**Backs:** documented workflows, deployment steps and data models.

- **MUST** — One owner per fact; other documents cite it rather than restating it

  <details><summary><strong>Answer</strong></summary>

  Every fact should have exactly one document that owns it, and every other document should cite that one rather than restating it — because the restatement is where drift happens, and it drifts silently, so both copies look authoritative and one is wrong. This document set is built that way on purpose: `02-high-level-design.md` owns component names and technology choices, `03-data-modeling.md` owns the schema, and the reliability file refers to indexes rather than redeclaring them, so an index renamed in one place cannot be right in one document and stale in another. The temptation is always to add a sentence of context for the reader, and the honest form of that is a link plus the reason it matters, not a paraphrase. The cost is real — a reader has to follow a reference rather than reading one page — and it is worth paying because the alternative is a set of documents that disagree, at which point none of them can be trusted and people stop reading all of them.

  </details>
- **NICE** — A document states what is true now, not how it got that way

  <details><summary><strong>Answer</strong></summary>

  A document should record the corrected fact and not the correction — no "previously we thought", no dated note narrating an edit — because version control already holds that history and a reader wants the current truth rather than its provenance. The exception worth carving out is a live-belief warning: where a reader may still absorb a stale belief from a source that is currently live, saying so plainly is actionable rather than archaeological. Architecture decision records are the deliberate other case and are not an exception to the rule, for the reason given under "Architecture decision records" below: each still states what was true at its own moment. The test I actually use is whether a sentence would make sense to somebody who had never read the previous version; if it only makes sense as a correction, it belongs in a commit message.

  </details>
- **MUST** — Architecture decision records: the decision, the alternatives, the trade-off accepted — the part that is worth reading a year later

  <details><summary><strong>Answer</strong></summary>

  The part of a decision worth reading a year later is not what was chosen, which is visible in the code — it is what else was considered and what the choice cost. So the shape is context, the options, the decision, and the consequences accepted, and the last one is what people skip and what future readers need. In this design that is why the rejected alternatives are written down with their reasoning rather than being invisible: a modular monolith instead of six services, everything in Postgres with `JSONB` instead of two stores, RLS instead of an application-layer tenant filter, a service mesh for internal mTLS. Each is defensible and each is recorded with what it would have bought, which is what lets someone revisit it without re-deriving the whole argument. The other property that keeps them useful is immutability: a record is superseded by a new one rather than edited, because rewriting the old decision destroys the reason the new one exists. **Deeper:** [interview-questions.md](./interview-questions.md#q2-you-documented-workflows-deployment-steps-and-data-models-in-your-experience-which-documentation-actually-survives-contact-with-a-changing-system-and-which-rots) — "You documented workflows, deployment steps and data models. In your experience, which documentation actually survives contact with a changing system, and which rots?"

  </details>
- **MUST** — Runbooks that are executable under pressure: symptom, check, action, escalate

  <details><summary><strong>Answer</strong></summary>

  A runbook is read by someone tired at three in the morning who did not write it, so it is a procedure rather than an essay: symptom, the checks that distinguish causes, the action for each, and when to escalate and to whom. Every alert here names an owner and a runbook for that reason — an alert without one is a page that becomes a research project. The properties that make one work are that the commands are copy-pasteable with no placeholders to guess, that each step says what a good result looks like so you know whether to continue, and that a destructive step is explicit about what it costs. The one for `indexer_lag_seconds` above sixty seconds is the useful example: check whether the worker is running, whether the outbox is publishing, whether Service Bus has a dead-letter backlog, then either scale the workers or trigger the reconciliation job — and the reason it is written down is that the failure is silent, so nobody has recent practice at it.

  </details>
- **OPTIONAL** — Data-model documentation that stays true (generated from the schema where possible)

  <details><summary><strong>Answer</strong></summary>

  Anything that can be generated should be — an entity-relationship diagram and a column list derived from the live schema or the SQLAlchemy metadata cannot drift, where a hand-written table starts drifting on the first migration nobody remembered to mirror. What generation cannot supply is the part actually worth reading, such as why `product_listing_facets` copies three columns from `product` or why `facet_schema_ref` is the only cross-store pointer, so the hand-written half should be exactly that and nothing a tool could have produced. **Deeper:** [interview-questions.md](./interview-questions.md#q2-you-documented-workflows-deployment-steps-and-data-models-in-your-experience-which-documentation-actually-survives-contact-with-a-changing-system-and-which-rots) — "You documented workflows, deployment steps and data models. In your experience, which documentation actually survives contact with a changing system, and which rots?"

  </details>
- **NICE** — Diagrams at one level of abstraction each; naming components consistently across every document

  <details><summary><strong>Answer</strong></summary>

  A diagram becomes unreadable when it mixes levels — a container beside a class, a queue beside a function call — so each one here answers a single question: the architecture diagram in `02-high-level-design.md` shows deployments and the stores they touch, the sequence diagrams show one flow's ordering, the entity-relationship diagram shows the schema, and none tries to do another's job. Naming is what lets them compose: `02` is the single source of truth for component names, and `catalog-service`, `product_listing_facets` and `sb-catalog-events` are spelled identically in every file, which is what makes one search across the set find everything rather than most things. What consistency costs is that renaming a component becomes a sweep rather than an edit — a fair price, because the alternative is a reader who cannot tell whether two names are two things.

  </details>

## 24. Defending the Design's Numbers

**Backs:** any claim about latency, cache effect or query improvement.

- **MUST** — A latency budget decomposed hop by hop, and knowing which hop dominates

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in for your own figures; the design's budget is already on the page.** Have ready the decomposition from `04-deep-dive.md` and be able to say which hop dominates and why: roughly 12 ms at Front Door and APIM, 3 ms of ingress, 1 ms of local authorization, a few milliseconds of Redis, then the two that decide the answer — about 45 ms for the keyset query on `product_listing_facets` and about 25 ms for the bulk Mongo hydration — and around 12 ms of serialization. Postgres dominates, which is why the index work is where the effort went rather than the serialization. What is yours rather than the design's is whether those hops were ever measured on real traffic or are modelled estimates, and the honest version of this answer says which, because a budget is a plan until someone instruments it.

  </details>
- **MUST** — Cached vs uncached paths, the hit ratio the budget assumes, and where the p95 actually falls

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in for your figures; the mechanics here are the design's.** Be able to state that there are two paths, roughly 35 ms cached and 107 ms uncached, that the budget assumes an 0.85 hit ratio on `cat:search`, and — the part that matters — that at 0.85 the p95 falls on the *uncached* path, so the number to quote is 107 ms and not 35 ms. Quoting the cached figure as the p95 is the single easiest way to lose an interviewer's trust, because it is the arithmetic they will check. What is yours is the observed hit ratio rather than the assumed one, and what it was during the window you measured; if the ratio was higher then than it is now, the figure is not reproducible and saying so first is stronger than being asked.

  </details>
- **MUST** — What was measured, at which percentile, over what window, on what data volume

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in — the design cannot supply a number you did not take.** The facts to hold ready are the ones an interviewer asks for in order: the exact metric and the endpoint or query shape it belongs to; the percentile, never the mean; the observation window, and whether it spanned an ordinary trading week; the row counts the tables actually held at the time; and the provenance — production telemetry, a load run, or a single `EXPLAIN ANALYZE` on a laptop. Lead with those rather than with the improvement, because a figure whose measurement has to be extracted reads as one that was not taken carefully. If the number is inherited rather than yours, say that before anything else.

  </details>
- **MUST** — The baseline and why it is comparable; confounders (a warm buffer pool, a different query mix, a change shipped in the same release)

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in.** Two halves, and the second is the one that gets skipped. The baseline: what the before-state was, taken on the same query shape, the same row counts, the same cache warmth and a comparable traffic mix, over a window long enough to contain a busy day rather than a quiet afternoon. The confounders: what else moved in that release — an index and a Redis layer landing together, a data-volume change, a query mix that shifted when the UI did, a buffer pool that had been warm for a week, a database version bump. The strong version of this answer is not a claim that nothing else changed; it is naming the one or two variables you could not isolate and saying why you still attribute the gain to the change you made.

  </details>
- **MUST** — Percentiles vs averages, and p50 gains hiding p99 regressions

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in for your figures; the statistics are general.** A mean is dragged down by the many fast requests and says nothing about the slow ones, so a change can move the median favourably while making the tail worse — and the tail is what a category manager meets in the middle of a comparison, which is the interaction the 200 ms target exists to protect. Two mechanical traps sit underneath that. Quantiles do not average, so a p95 aggregated naively across pods or across five-minute buckets describes nobody's experience. And a histogram quantile is an interpolation inside a bucket, so a p99 that lands in the top bucket is a floor rather than a measurement. Know which percentile you are quoting, and what the others did while it improved.

  </details>
- **MUST** — Verifying a query plan against realistic volume before quoting a figure, and being willing to say what the measurement does not prove

  <details><summary><strong>Answer</strong></summary>

  **Yours to fill in, and the line that matters most on this list.** The design already declines to trust its own 45 ms search figure: it holds only if the planner combines the `GIN` indexes into a bitmap `AND` rather than degrading to a sequential scan, and what it asks for is an `EXPLAIN (ANALYZE, BUFFERS)` against a seeded 40,000-row table on the pinned PostgreSQL version, with statistics refreshed, before anyone quotes the number. Be able to say whether you ran that, on what volume, and what the plan actually did. Then close every claim with its edges — this metric, this percentile, this window, this traffic — and say out loud what it does not establish. Volunteering the boundary is what makes a number credible; defending one against every probe is what invites the next probe. **Deeper:** [interview-questions.md](./interview-questions.md#q3-the-45-millisecond-search-figure-in-the-design-is-flagged-as-unverified-how-do-you-actually-establish-a-performance-claim-before-building-on-it) — "The 45-millisecond search figure in the design is flagged as unverified. How do you actually establish a performance claim before building on it?"

  </details>
