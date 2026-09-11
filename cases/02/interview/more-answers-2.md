# Supplied Questions — Answers by Topic (Set 2)

> Answers throughout are generated from the project briefs and system design documents in this case.
> Grouped by topic and tiered by difficulty.
> Weighted toward the client brief in `candidate-profile.txt`.

**Difficulty tiers.** `Q1` baseline — the foundational knowledge behind a stated responsibility. `Q2` deep dive — implementation detail, failure modes, the gotchas only someone who did the work has. `Q3` architectural — trade-offs, system-wide impact, what changes at scale. The tier follows the question that was asked, so not every topic carries all three.

## Questions by project

- **cancer-support-platform** — 49, 53, 55, 57, 58, 59, 60, 62, 63, 64, 65, 67, 70, 71, 72, 73
- **retail-software-marketplace** — 49, 52, 53, 54, 55, 57, 58, 59, 60, 62, 63, 64, 65, 66, 67, 70, 71, 72, 73
- **general** — 50, 51, 56, 61, 68, 69

## Table of Contents

- [FastAPI Runtime and the Request Path](#fastapi-runtime-and-the-request-path)
- [Latency Regressions and Connection Pooling](#latency-regressions-and-connection-pooling)
- [API Design, Contracts and Idempotency](#api-design-contracts-and-idempotency)
- [Transactions, Atomicity and Locking](#transactions-atomicity-and-locking)
- [Timeouts, Retries and Circuit Breakers](#timeouts-retries-and-circuit-breakers)
- [Asynchronous Jobs and Duplicate Delivery](#asynchronous-jobs-and-duplicate-delivery)
- [Scaling and System Composition](#scaling-and-system-composition)
- [Networking, HTTP and Access Control](#networking-http-and-access-control)
- [Availability, Failure and Consistency Trade-offs](#availability-failure-and-consistency-trade-offs)

---

## FastAPI Runtime and the Request Path

---

### 49. What happens when a FastAPI endpoint receives an HTTP request? Walk me through the request from the client all the way to the application and back.

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Transport Layer Security terminates at the edge, a gateway validates the token before anything of mine runs, an ingress picks a pod, and only then does an Asynchronous Server Gateway Interface server hand the application a scope-and-callables triple. Inside the process it is a fixed order: middleware outward-in, routing, dependency resolution, body validation, the handler, serialization, then middleware inward-out on the way back.

<details>
<summary><strong>Detailed answer</strong></summary>

**The part before the application, because most of the interesting failures live there.** In the marketplace the chain is Azure Front Door with a Web Application Firewall, then Azure [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management, then the NGINX ingress on the cluster, then the pod. Front Door terminates Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")) 1.3 and runs the Open Worldwide Application Security Project rule set; API Management validates the [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Token ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties")) signature, expiry and audience, applies the per-subscription quota, and routes. That ordering matters: a forged or expired token never reaches my code, and a volumetric flood never reaches the cluster. In the cancer platform the same gateway does one extra thing that is the whole point of the design — it checks the token's **audience against the route's plane**, so a clinician token on `/api/v1/diary/check-ins` is rejected with `403` before application code runs.

The edge is a filter, not the authority. Every service re-validates the token locally against a JSON Web Key Set cached in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), because a bypass of the gateway must not be a bypass of authentication. Neither check makes a network call per request, which is the assumption the whole latency budget rests on — an introspection round-trip would add 15–30 ms to every request in the system.

**The Asynchronous Server Gateway Interface ([ASGI](https://asgi.readthedocs.io/en/latest/ "Standard interface between asynchronous Python web servers and applications")) boundary.** Uvicorn parses the request and calls the application with three things: a `scope` dict describing the connection and the request, an awaitable `receive` for reading the body in chunks, and an awaitable `send` for writing the response. That is the entire contract, and it is why streaming, WebSockets and background work all fit the same interface. The body is not read yet at this point — `receive` is a generator, so a large upload does not materialise in memory just because the request arrived.

**Inside the application, in order:**

1. **Middleware, outermost first.** ASGI middleware wraps the app like an onion — request-id assignment, trace-context extraction, logging, error trapping. Everything a middleware adds on the way in, it can inspect on the way out, which is why timing and structured-log enrichment belong here and not in handlers.
2. **Routing.** Starlette matches method and path against the compiled route table and extracts path parameters as strings. No match is a `404` before any of the application's own logic runs; a path match with the wrong method is a `405`.
3. **Dependency resolution.** [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") walks the dependency graph for that route and resolves it — authentication and the account-type check, the database session, the tenant scope. Sub-dependencies are cached **per request**, so a dependency required by three others is executed once. A dependency declared with `yield` runs its teardown after the response, which is how a session is guaranteed to close.
4. **Validation and coercion.** Path, query, header and body are parsed into the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models declared on the signature. A failure here is a `422` with a field-level error body, produced before the handler is entered — which is the reason a handler can treat its arguments as already correct. In the marketplace this is also where a vendor's free-form `attributes` are validated against the category's facet schema, so "no fixed column set" does not degrade into "no contract".
5. **The handler.** An `async def` runs on the event loop; a plain `def` is dispatched to a worker thread pool so it cannot block the loop. This distinction is the single most consequential line of code in an async service and is the subject of the next question.
6. **Response construction.** The return value is validated against `response_model`, serialized to JSON, and given status and headers. `response_model` is not decoration — it is what stops a field the handler happened to load from leaking into the response.
7. **Back out through the middleware**, each layer seeing the finished response, then `send` writes headers and body back through the ASGI server to the ingress, the gateway and the client — usually over a connection that is kept alive and reused.

**What I would add unprompted**, because it is what makes this debuggable in production: the `traceparent` header is extracted at the first middleware and propagated onward — including into message headers when the handler publishes an event. Without that, a request that ends in a queue is two unconnected half-stories.

</details>

---

### 50. Talking about FastAPI, explain sync vs async and where blocking operations can hurt an async service.

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
`async def` runs on the event loop and must never block; plain `def` is handed to a bounded thread pool precisely so that it can. The damage case is the third combination nobody declares deliberately — a blocking call inside an `async def`, which stalls the entire loop and therefore every other request that worker is serving, not just the one that made the call.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each choice actually does.** FastAPI inspects the handler. `async def` is awaited directly on the event loop — one thread, cooperatively scheduled, holding thousands of in-flight requests that are each waiting on a socket. Plain `def` is run in an anyio worker thread pool, capped by default at around forty threads, so a synchronous handler is safe but the pool size becomes your concurrency ceiling. The same rule applies to dependencies, which people forget: a `def` dependency is threaded, an `async def` dependency is not.

**The failure mode.** A single blocking call inside an `async def` does not slow that request — it stops the loop. Every other coroutine on that worker waits for it, including ones that were about to finish. So a 300 ms blocking call under 50 concurrent requests does not cost 300 ms; it serialises the whole worker and the tail latency goes through the roof while CPU sits near idle. That signature — flat CPU, collapsing throughput, p99 far above p50 — is the fingerprint, and it is worth being able to name it on sight.

**The specific offenders, in the order I have actually seen them:**

- **A synchronous database driver in an async handler.** `psycopg2` or a sync [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") `Session` under `async def` is the classic. Either use the async engine with `asyncpg`, or declare the handler `def` and let the thread pool absorb it — but do not mix.
- **`requests` instead of an async [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client.** One outbound call to a slow dependency takes the loop with it.
- **CPU-heavy work.** Large JSON serialization, image handling, password hashing with [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive") or bcrypt, a regex over a big document. These block regardless of how they are written, so they belong in a thread, a process pool, or off the request path entirely.
- **`time.sleep`, blocking file input/output, and synchronous client libraries** for brokers, caches and cloud storage. Many Software Development Kits (SDKs) ship both a sync and an async client and default to the sync one.
- **Lock and queue primitives from `threading` or `queue`** used inside coroutines.

**Detecting it rather than guessing.** `asyncio` debug mode logs callbacks that exceed a threshold; an Application Performance Monitoring agent shows a span whose duration is unaccounted for by any child span; and event-loop lag as a metric — the difference between when a scheduled callback should have run and when it did — is the most direct signal there is, and it is worth exporting.

**One honest note relevant to this role.** The client runs FastAPI synchronously under heavy enterprise load, which is a legitimate configuration and not a mistake — with `def` handlers the framework threads the work, and the tuning levers move to worker processes per pod, thread-pool size, and the database connection pool behind them rather than to coroutines. The mistake would be a half-migration: `async def` signatures over synchronous drivers, which gets you the fragility of the event loop with none of the concurrency.

</details>

---

### 51. Why can an async Python service handle many requests even though Python has the GIL?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Because the work is waiting, not computing. The Global Interpreter Lock serialises the execution of Python bytecode, but a socket read holds no bytecode — it releases the lock and parks, so one thread can hold thousands of outstanding requests that are all blocked on the network. Concurrency and parallelism are different things, and this workload only needs the first.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** The Global Interpreter Lock ([GIL](https://wiki.python.org/moin/GlobalInterpreterLock "CPython mechanism that lets only one thread execute Python bytecode at a time")) means one thread executes Python bytecode at a time in a given interpreter. Crucially, it is **released around blocking operations** — socket reads and writes, file input/output, and most of the time spent inside a C extension. An async service never uses threads for this anyway: it runs one event loop on one thread, and every `await` on a socket yields control back to the loop, which is free to advance any other coroutine whose socket has become ready. The limit on in-flight requests becomes memory and file descriptors, not the lock.

**Why this fits the workload exactly.** Decompose the marketplace's catalog search budget: 12 ms at the gateway, 3 ms at the ingress, 3 ms in Redis, 45 ms in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), 25 ms in [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), about 14 ms of serialization. Roughly 88 of 107 ms is the process waiting on something else, and only the serialization is real Python bytecode. One worker can therefore hold a large number of concurrent requests, because at any instant almost all of them are parked on a socket. That is the whole argument for async here, and it is an empirical argument about a measured budget rather than a preference.

**Where the GIL genuinely bites, and what to do about it.** The 14 ms of Pydantic serialization for thirty product summaries *is* bytecode, and it is the part that does not scale with coroutines. More concurrency makes that queue longer, not shorter. The fixes are all the same shape — get more interpreters:

- **More Uvicorn worker processes per pod, more pods behind the load balancer.** Process-level parallelism sidesteps the lock entirely, which is why horizontal scaling is the answer to CPU pressure and vertical concurrency is not.
- **Move the CPU work out of the request.** The cancer platform's page composition is seconds of model work, so it was moved off the request path onto a [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") queue rather than trimmed to fit. The user never waits and the pipeline can afford to be expensive.
- **Push the work into C.** Pydantic v2 does its validation in Rust, `orjson` serializes outside the interpreter, and numeric libraries release the GIL for the duration. A profile that shows time in a C extension is a profile that is already parallel.

**The honest qualifications.** Two are worth volunteering. First, async does not make anything faster — it improves throughput and resource efficiency under concurrency, and a single request is, if anything, marginally slower. Second, [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") now has a free-threaded build in which the GIL can be disabled; it is real and it is supported, but it is not what any of this design relies on, and I would not plan capacity around it without benchmarking the actual workload, since single-threaded performance and C-extension compatibility are both still in motion.

</details>

---

## Latency Regressions and Connection Pooling

---

### 52. How would you handle a database connection pool in a FastAPI application?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
One engine per process, created in the lifespan hook and disposed on shutdown; one session per request, handed out by a dependency with a `yield` so teardown is guaranteed; and a pool size chosen so that the sum of every pod's maximum stays under the server's connection limit — which is arithmetic, not a default.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape that works.** The engine is a process-level object and it owns the pool, so it is created once in the application's lifespan startup and disposed on shutdown — never at module import, because import happens before the fork in some worker models and you end up with child processes sharing socket file descriptors. The session is per request, produced by a dependency:

```python
async def get_session() -> AsyncIterator[AsyncSession]:
    async with session_factory() as session:
        yield session
```

The `yield` form is what makes closing unconditional. The connection returns to the pool whether the handler returned, raised, or the client disconnected mid-response, and nothing in the handler has to remember to do it.

**Sizing, which is the part people skip.** The constraint is global, not per pod. Azure Database for PostgreSQL Flexible Server has a connection limit driven by its tier, and PostgreSQL allocates a backend process per connection, so connections are genuinely expensive. In the marketplace six services and three worker pools autoscale between three and eight nodes, so the sum of `pool_size + max_overflow` across every replica of every deployment has to stay below that ceiling with headroom left for migrations, the outbox relay and an operator's psql session. A small pool per pod is sufficient precisely because the handlers are async and hold a connection only for the duration of the statement.

**The settings that earn their place:**

- **`pool_pre_ping`** — issues a cheap liveness check before handing out a connection. Without it, the first request after a failover or an idle-timeout reap fails with a stale socket. With it, the pool discards and reopens transparently.
- **`pool_recycle`** below the shortest idle timeout on any hop — the database's own, plus any load balancer or firewall between you and it, which is usually the shorter one and usually the one that surprises people.
- **A pool checkout timeout.** A request that cannot get a connection within a couple of seconds should fail fast with a `503`, not queue indefinitely. Unbounded queueing inside the pool is how a slow database becomes an unbounded latency spike.
- **`expire_on_commit=False`** on the async session, so touching an attribute after commit does not trigger implicit input/output on a connection that has already been returned.

**Two traps specific to a pooler in front of the database.** PgBouncer in transaction mode does not keep a backend bound to a client between statements, and that has two consequences. Prepared statements break, so `asyncpg` needs its statement cache disabled. And more seriously, **anything set at session scope leaks between callers** — which is exactly why the cancer platform sets its row-level-security identity with `SET LOCAL` inside the request transaction and asserts that with a pooled-connection leakage test. A plain `SET` there would hand one caller's identity to the next caller's query and turn the strongest control in that design into its exact opposite.

**And keep the workers separate.** Celery workers run their own engines with their own pools, sized separately, because a bulk import doing long-running writes and a web tier doing 5 ms reads want different pool shapes and must not be able to starve each other.

</details>

---

### 53. Why increasing the pool indefinitely can actually make the system worse?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Because a pool is not a throughput knob, it is a queue with a visible length. Past the point where the database is saturated, extra connections do not add capacity — they move the queue from your application, where you can measure and shed it, into the database, where contention makes every query slower and nobody is holding a timeout.

<details>
<summary><strong>Detailed answer</strong></summary>

**The database's own limits come first.** PostgreSQL forks a backend process per connection, each with its own memory and its own share of shared structures. Beyond roughly the number of effective cores times a small factor, more concurrent active connections buy no additional work done and cost real overhead: context switching, cache-line contention on shared buffers and the lock manager, more processes competing for the same input/output queue. Throughput flattens and then bends downward while latency climbs — a classic congestion curve. Adding connections past the knee is strictly negative.

**The queueing argument, which is the one I would lead with.** Little's law says concurrency equals arrival rate times service time. If the database can serve 200 statements per second and 250 arrive, a queue forms — that is arithmetic and no pool size changes it. What the pool size decides is *where* the queue forms. A bounded pool puts it in the application, where it has a name, a metric, a timeout and a shedding policy: a request that waits too long for a checkout gets a `503`, and the caller is told quickly. An unbounded pool puts it inside the database, where 500 backends are each making slow progress, every query's latency has tripled, and there is no mechanism to reject anything. Backpressure has been removed, and backpressure is the feature.

**Three concrete ways the large pool makes an incident worse:**

- **It converts a slow dependency into a total outage.** With a small pool, a query that has become slow occupies a few connections and the rest of the traffic still flows. With a huge pool, every arriving request grabs a connection and joins the pile, so one bad query plan takes down everything the database serves.
- **It turns a failover into a connection storm.** When the primary comes back after a zone failover, every pod in every deployment attempts to refill its pool simultaneously. Hundreds of authentication handshakes arrive at a cold instance at once, and it falls over again. This is why the marketplace design names PgBouncer-style pooling with bounded reconnection specifically as the mitigation for the 60–120 s failover window.
- **It silently breaks the ceiling shared with everything else.** The limit is per server, not per service. A pool enlarged in one deployment starves the outbox relay, the migration job, and the operator trying to connect to diagnose the incident — and the symptom appears somewhere other than the change.

**So what do you do when the pool is genuinely the bottleneck?** Prove it first: pool checkout wait time is a metric, and it is the only thing that distinguishes "the pool is too small" from "the database is too slow". If checkout wait is near zero and query time is high, a bigger pool makes it worse. If checkout wait is high while the database is comfortably idle, the pool is genuinely small — and even then the ceiling is the server's limit divided by the replica count. Beyond that the honest answers are fewer or cheaper queries, a read replica for the reads that tolerate staleness, a cache in front of the hot path, or a transaction-mode pooler that multiplexes many clients onto few backends. All of those add capacity. A bigger number does not.

</details>

---

### 54. Suppose one API endpoint suddenly becomes 10× slower. How would you investigate it?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Establish the shape before the cause: when did it start, is it one endpoint or the whole service, and is it the median or only the tail. Those three answers eliminate most of the search space. Then work the dependency chain from the trace, not from a hypothesis — the trace tells you which span grew, and the growth is almost always a plan flip, a cache that stopped hitting, a pool that started queueing, or a dependency that got slower.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three questions first, because each cuts the space in half.**

1. **When, exactly, and what changed then?** Overlay the latency graph with the deployment timeline, the configuration and feature-flag history, and the infrastructure change log. A step change at a deploy boundary is a code or migration cause; a gradual ramp over days is data volume or index bloat; a step change with no deploy is a dependency, a plan flip, or a traffic-mix change.
2. **One endpoint or all of them?** If every route on the service degraded together, the cause is shared — the event loop is blocked, the pool is saturated, the node is throttled, or the database is slow for everyone. If genuinely only one route moved, the cause is in that route's own work.
3. **p50 or only p95/p99?** A shifted median means every request now does more work. An unchanged median with a much worse tail means a subset of requests — one tenant, one large payload, one uncached path, one unlucky lock — and the fix is different in kind.

**Then follow the trace.** With distributed tracing in place — Application Insights in the marketplace, Elastic Application Performance Monitoring in the cancer platform — I compare a slow trace now against a fast trace from before the change and look at which span grew. This is the step that replaces guessing. The usual answers:

- **The database span grew.** Run `EXPLAIN (ANALYZE, BUFFERS)` on the actual query with the actual parameters. A plan flip is the most common cause of a sudden tenfold change: statistics went stale after a bulk load, a table crossed the size at which the planner stopped preferring an index, or an unselective predicate combination degraded a bitmap `AND` across several generalized-inverted indexes into a sequential scan — which the marketplace design flags in advance as this system's defining performance risk. Check `pg_stat_statements` for the query's mean time and call count, and check whether autovacuum has fallen behind on the table.
- **The database span did not grow, but the time before it did.** That is pool checkout wait — the pool is queueing. It is a distinct metric and it is the difference between "the database is slow" and "I have no connections", which have opposite fixes.
- **A cache span started missing.** `redis_cache_hit_ratio` for the keyspace is an explicit service level indicator in the marketplace precisely because the latency budget assumes 85% on the search page. A ratio collapse — a key format change on deploy, an eviction from memory pressure, a stampede after a mass invalidation — moves p95 from the ~35 ms cached path to the ~107 ms uncached path in one step, and further if the database is now carrying six times its usual load.
- **Call count grew rather than call duration.** One span taking 50 ms became forty spans taking 2 ms each: a lazy relationship became an N+1, or a bulk `$in` hydration became a per-item loop. The marketplace calls that out by name as the way its catalog design would have failed.
- **No span grew and the sum does not reconcile.** That is time in the process, not in a dependency: a blocking call on the event loop, garbage-collection pauses, or CPU throttling from a container limit. Event-loop lag and container throttling metrics settle it.
- **Everything is slow and the replica lag graph is climbing.** `postgres_replica_lag_seconds` above threshold makes `catalog-service` fail back to the primary, which is correct behaviour and also a latency change with no code cause.

**What I would not do.** Restart the pods to see if it helps, or enlarge the pool, before I know which span grew — both destroy the evidence and one of them makes a saturated database worse. And I would check whether the endpoint is actually slower or merely slower *for someone*: a tenant whose data volume grew, or a client that started sending a new filter combination, looks identical on an aggregate graph and is a different problem.

</details>

---

## API Design, Contracts and Idempotency

---

### 55. What makes an API "good"?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
That a competent consumer can predict it without asking you. Concretely: one executable contract rather than a document, a resource model that stays consistent as it grows, honest status codes and machine-readable errors, safe retries on every mutation, pagination and result sizes that do not degrade with data volume, and an evolution story that does not break the caller you cannot deploy alongside.

<details>
<summary><strong>Detailed answer</strong></summary>

**The contract is a build artefact, not documentation.** In both designs the Pydantic models define every request and response body and FastAPI emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document from them, and that document is contract-tested in the pipeline. The marketplace goes one step further and builds its admin console against the same versioned public API rather than a private backend — which costs a chattier user interface on entity screens and buys the guarantee that no admin capability exists that the public contract does not already describe and test. A specification maintained by hand alongside the code is a specification that is wrong, and the consumer finds out at runtime.

**Predictability across the surface.** Same pagination everywhere, same error envelope everywhere, same identifier style, same date format, same naming. Both designs use cursor pagination on every collection because offset pagination degrades on exactly the deep pages a comparison or timeline workflow produces — but the more important property is that it is *everywhere*, so a consumer learns it once.

**Honest semantics.** The status code is part of the contract: `201` with a `Location` for a creation, `202` when the work is genuinely asynchronous and a status [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") is returned with it, `409` for a state conflict, `422` for a body that fails validation, `503` when a dependency is down and a retry is appropriate. Error bodies are [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details — a stable `type`, a human `detail`, and field-level errors — because a client cannot branch on prose. The cancer platform returns `202 Accepted` for a check-in rather than pretending the write is synchronous, and returns a status URL for page generation rather than holding a connection open for 45 seconds. Lying about which of these a call is causes more consumer bugs than any amount of naming.

**Safety and bounds.** Every mutation accepts an `Idempotency-Key` so a retry after a timeout cannot double-apply — required on all `POST` mutations in the cancer platform, and required on `POST /v1/connections` in the marketplace because a double-submitted connection request must not create two threads and bill the vendor twice. Responses are bounded: the marketplace returns `total_estimate` capped at 1,000 rather than an exact count, because an exact count over a filtered index scan costs as much as the page itself, and a sourcing workflow needs "1,000+" rather than "1,247". Similarly, the API refuses an uncategorised query carrying more than two facet predicates — a small product constraint that removes a whole class of performance problem.

**Evolution.** Version in the path (`/api/v1`, `/v1`), and inside a version evolve additively: new optional fields, new endpoints, never a changed meaning or a removed field. A consumer you cannot deploy in lockstep with is the normal case, so the test is whether the old client keeps working unchanged.

**Authorization at the resource, not the route.** A route-level check tells you the caller is a clinician; it does not tell you they may see *this* patient. Good APIs answer both, and answer the second in one place rather than per endpoint.

**And the property that is easy to forget:** the API should be observable from the outside. A request identifier echoed back, a propagated trace header, and a status endpoint for anything asynchronous mean a consumer can tell you *which* call failed instead of "it was slow yesterday".

</details>

---

### 56. Design a REST API for creating and retrieving orders.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
`POST /v1/orders` with a required `Idempotency-Key`, returning `201` and a `Location`; `GET /v1/orders/{order_id}`; `GET /v1/orders` with keyset pagination and a small set of filters. State changes are explicit sub-resource actions rather than a patchable `status` field, money is integer minor units with an explicit currency, and concurrent edits are settled with `ETag` and `If-Match`.

<details>
<summary><strong>Detailed answer</strong></summary>

**Create.**

```
POST /v1/orders
Idempotency-Key: 7f1c…          (required)
{ "customer_id": "…", "currency": "EUR",
  "lines": [ { "sku": "…", "quantity": 2, "unit_price_minor": 1499 } ],
  "shipping_address_id": "…" }
→ 201 Created
  Location: /v1/orders/018f…
  { "order_id": "018f…", "status": "pending", "total_minor": 2998, "currency": "EUR", … }
```

Four decisions in that block are worth defending. The **idempotency key is required, not optional**, because a client that retries a timed-out create has no other way to avoid a duplicate order — and I would return the stored original response for a repeat of the same key, and `409` for the same key with a different body. **Money is `*_minor` integers plus an [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 4217 currency code**, never a float; the marketplace schema does exactly this with `price_minor bigint` and `currency char(3)`. **The server computes the total**, because a client-supplied total is a pricing vulnerability. And **line items are part of the create**, not a sequence of `POST /orders/{id}/lines` calls, because an order with no lines is not a valid intermediate state and should not be reachable.

**Read.**

```
GET /v1/orders/{order_id}          → 200 + ETag
GET /v1/orders?status=pending&created_after=…&cursor=…&limit=50
                                   → { items: [...], next_cursor: "…" }
```

Keyset pagination on `(created_at, order_id)` rather than `OFFSET`, so page 40 costs what page 1 costs. An opaque cursor, so the ordering key can change without breaking clients. `limit` capped server-side. The list returns summaries and the detail endpoint returns lines and history, because a list of 50 fully-expanded orders is a payload nobody wanted.

**State transitions as actions, not as a patchable field.**

```
POST /v1/orders/{id}:cancel   { "reason": "customer_request" }
POST /v1/orders/{id}:confirm
```

`PATCH {"status": "cancelled"}` looks tidier and is worse: it invites an arbitrary transition, it has nowhere to carry the reason a cancellation needs, and it makes the state machine implicit. An explicit action endpoint is authorizable on its own, auditable on its own, and returns `409` when the transition is illegal from the current state — `cancel` on a shipped order is a conflict, not a validation error.

**Concurrency.** The detail response carries an `ETag`; an update requires `If-Match`, and a mismatch is `412 Precondition Failed`. That is optimistic locking expressed in the protocol, and it is the right default for a resource a human edits — the alternative, last-write-wins, silently discards someone's change.

**What I would say about the parts people miss:**

- **Partial failure on a bulk endpoint.** If `POST /v1/orders:bulk` exists, it returns `207`-style per-item results with a stable index, never a single `200` that hides three failures.
- **Asynchrony where it is real.** If confirming an order triggers payment capture that takes seconds, the action returns `202` with a status URL rather than holding the connection. And the state change plus the event that announces it commit together through an outbox, so "the order was confirmed but nothing downstream heard" is not a reachable state.
- **Authorization is per order, not per route.** A customer may read their own orders; a support agent may read any, and that read is audited.
- **Retention and immutability.** An order is a commercial record. Cancellation is a state, not a delete; `DELETE /v1/orders/{id}` should not exist.

</details>

---

### 57. What happens if the client sends the same POST request three times?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By default, three of whatever it does — and this is the normal case, not a client bug, because a retry after a timeout cannot tell a lost response from a lost request. The design answer is an idempotency key that makes the second and third calls return the first call's result, backed by a uniqueness constraint in the database, because the key store is an optimisation and the constraint is the guarantee.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the three come from.** A human double-clicking is the least interesting source. The two that matter are a client that timed out and retried — having no way to know whether the server committed before the connection dropped — and infrastructure that retried on its own, which gateways and [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") layers do more often than people expect. So duplicate delivery is a property of the network, and "tell clients not to do that" is not a design.

**The mechanism.** The client generates a key per logical operation and sends it as `Idempotency-Key`; it reuses the same key across retries of that operation, and generates a fresh one for a genuinely new attempt. Server-side:

1. Look the key up. If a completed record exists, **return the stored response** with its original status code — not a `409`, because the client's goal is the outcome, and a retry that returns `201`-equivalent semantics is exactly right.
2. If the key exists but the request body's fingerprint differs, return `422` or `409`. Reusing a key for a different operation is a client bug and should be loud.
3. If the key exists and is still in flight, return `409` with a retry hint rather than starting a second execution.
4. Otherwise claim the key, execute, and store the response.

**And the part that makes it actually correct.** Both designs say this in the same words, from opposite directions. The cancer platform's Redis keyspace notes that `idem:` keys are the *optimisation* for duplicate suppression, **not the guarantee** — losing them to a flush permits a duplicate to be reprocessed, so any mutation that must not double-apply carries a natural key in PostgreSQL. Check-ins are unique on `(patient_id, recorded_for)` and the projection is an `INSERT … ON CONFLICT DO UPDATE`, so a redelivered message is arithmetic rather than a bug. The marketplace does the same at the commercial boundary: `connection_request` carries `UNIQUE (retail_group_id, idempotency_key)`, and its own schema note says the database, not the cache, is what finally prevents a duplicate thread and a duplicate charge. `billing_charge` adds `UNIQUE (connection_request_id) WHERE kind = 'connection'`, so a connection bills at most once — enforced in the schema rather than in retry logic, which is the distinction worth drawing.

**The natural key is better than the generated key wherever one exists,** because it does not depend on the client behaving. One check-in per patient per day is a domain truth; an idempotency key is a client promise.

**What the key cannot protect.** Side effects outside the transaction. If the first attempt committed and then sent an email, a retry that returns the stored response does not send a second email — but a crash between the commit and the send means no email at all. That is why anything that must follow a commit goes through the outbox rather than being fired inline: the state change and the intent to notify commit together, and the relay delivers at-least-once afterwards.

**And where duplicates are simply accepted.** The cancer platform's reminder path can deliver twice under a receipt-loss race, and the design says so explicitly and takes it: a patient seeing a reminder twice is a far better failure than not seeing it at all. Being able to name which duplicates you have chosen to tolerate, and why, is a stronger answer than claiming you have eliminated them.

</details>

---

## Transactions, Atomicity and Locking

---

### 58. Explain optimistic vs pessimistic locking.

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Pessimistic locking takes the lock before doing the work and makes conflicting writers wait; optimistic locking does the work, then checks at commit whether anyone else changed the row, and fails the loser. The choice follows contention and who can retry: low contention with a client that can redo the work favours optimistic, high contention or a client that cannot resolve a conflict favours pessimistic.

<details>
<summary><strong>Detailed answer</strong></summary>

**Pessimistic.** `SELECT … FOR UPDATE` takes a row lock for the rest of the transaction; other writers block. It is the right answer when a conflict is likely, when the work between read and write is short, and when the correct resolution of a conflict is "wait your turn". The costs are real: waiting writers hold connections, lock waits can escalate into a pileup under load, and any lock held across a network call or a user's think-time is a design defect rather than a tuning problem.

**Optimistic.** The row carries a version — an explicit `version` column, an `updated_at`, or PostgreSQL's system `xmin`. The write is `UPDATE … WHERE id = ? AND version = ?`, and an affected-row count of zero means somebody else got there first. No locks are held while the user thinks, so it scales well when conflicts are rare, and it degrades badly when they are not: under heavy contention you spend all your work on retries. Over HTTP this is exactly `ETag` plus `If-Match` returning `412` — the same mechanism surfaced in the protocol so the client can decide what to do.

**Where each one is used in these systems, which is the more interesting half of the question.**

- **Optimistic, expressed as a monotonic guard rather than a version check.** `indexer-worker` upserts `product_listing_facets` keyed on `product_id` and **ignores an event whose `source_revision_id` is older than the row's current value**. That is optimistic concurrency for a projection: redelivery is a no-op and out-of-order delivery cannot roll a listing backwards. A plain version check would reject the stale write with an error; here the correct action is to drop it silently, which is the same idea with a domain-appropriate resolution.
- **Pessimistic, chosen deliberately over optimistic.** [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") updates from the hospital directory serialise per directory object on a Redis lock, `lock:scim:{entra_object_id}`. The reason is not contention — it is that **the client will not resolve a version conflict for you**. Entra ID sends a `PATCH` and expects it applied; returning a `412` and hoping it re-reads and re-applies is not a contract that provider honours. When the counterparty cannot participate in the retry, optimistic locking is not available to you, and that is the cleanest test I know for choosing between the two.
- **The third option people forget: `FOR UPDATE SKIP LOCKED`.** The reminder sweep claims due rows with `SELECT … FOR UPDATE SKIP LOCKED`, which is pessimistic locking with the waiting removed — a worker takes what is free and leaves contended rows to whoever holds them. That is what lets the worker pool scale horizontally without double-dispatch and without a queue of blocked workers, and it is the right primitive for work-claiming specifically.
- **The fourth option: neither.** The best concurrency control is often a constraint. `UNIQUE (patient_id, recorded_for)` with `ON CONFLICT DO UPDATE`, or `UNIQUE (connection_request_id) WHERE kind = 'connection'`, resolves the race in the database with no lock and no retry loop. If the conflict has a correct deterministic resolution, express it as a constraint rather than as a protocol.

**Two details worth adding.** Deadlocks are a pessimistic-locking phenomenon and the practical defence is a consistent lock ordering plus short transactions; PostgreSQL detects them and kills a victim, so the application must be able to retry a serialization failure. And isolation level matters: at `SERIALIZABLE`, PostgreSQL gives you optimistic behaviour for free, aborting transactions whose interleaving was not serialisable — which is elegant, and means every write path needs a retry loop.

</details>

---

### 59. Give an example where two database operations MUST be atomic. When would you deliberately NOT use one large transaction?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The canonical must-be-atomic pair is a state change and the outbox row that announces it: commit them together and "it happened but nobody heard" stops being a reachable state. The deliberate refusal is anything long, anything crossing a network boundary, and anything bulk — because a long transaction in PostgreSQL holds back vacuum and holds locks, so its cost is paid by every other query on the system.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three examples where atomicity is genuinely required.**

1. **The state change and its outbox event.** `vendor-service` updates `product.current_revision_id` and inserts `outbox_event` in one PostgreSQL transaction; the relay publishes afterwards and stamps `published_at`. The alternative — commit, then publish — has a window in which the process dies and the fact exists while the event does not, permanently and undetectably. This is the single most common place people accidentally dual-write, and the outbox exists for exactly this pair.
2. **Deprovisioning a clinician.** When SCIM marks a clinician inactive, the `clinician` row flips **and every open `care_relationship` for that clinician closes in the same transaction**. A partial application here is an access-control failure: the account is disabled but the relationship rows that row-level security joins through are still open, or vice versa. Either half alone is wrong, and the wrongness is a security event rather than a data inconsistency.
3. **A charge and the thing it charges for.** `connection_request` and the `billing_charge` that accrues from it must not diverge — a charge with no connection is a refund conversation, and a connection with no charge is revenue lost silently. Here the design takes an extra belt: the charge is derived asynchronously from the event, and the schema carries `UNIQUE (connection_request_id) WHERE kind = 'connection'` so at-least-once delivery cannot produce two.

**Where I would deliberately not open one big transaction.**

- **Bulk work.** A 20,000-row catalog import is not one transaction. It is chunked into 500-row tasks, rows land in `import_staging`, they are validated against the category's facet schema, and only then are products promoted. That gives per-row error reporting, resumability, and a bounded lock footprint. A single transaction would hold locks for minutes, produce one all-or-nothing verdict with no per-row detail, and roll back an hour of work on row 19,998.
- **Anything crossing a network boundary.** Never hold a transaction open across an HTTP call to another service, a blob upload, or a broker publish. The transaction's duration becomes the remote system's latency plus its failure modes, and a hung call becomes a held lock. The cancer platform's composition path calls `clinical-nlp-svc` from a Celery task with a bounded deadline, entirely outside any database transaction, and writes the result afterwards.
- **Two stores.** The Mongo write and the Postgres commit in the marketplace's publish path are explicitly not one transaction and cannot be. The ordering rule does the work instead: Mongo first, Postgres second, because an orphaned revision document is invisible garbage while a committed pointer to a missing document is a broken listing. A nightly reconciliation sweeps the orphans.
- **Backfills and migrations.** Batched with a keyset cursor and a commit per batch, for the same reasons plus one more: a long `UPDATE` over a large table is an index-maintenance and write-amplification event that competes with live traffic.

**Why long transactions are specifically expensive in PostgreSQL,** which is the detail that turns this from a style preference into an operational argument: an open transaction pins the oldest transaction horizon, so **autovacuum cannot reclaim dead tuples anywhere in the database** for as long as it runs. Bloat accumulates, table and index scans get slower for every other query, and on a replica a long-running read can cause recovery conflicts or force a lag increase. A transaction that holds locks also parks every conflicting writer behind it, and on a 110-million-row partitioned table that is not a local effect. So "keep transactions short" is not tidiness — it is a property the rest of the system depends on.

**The rule I would state.** A transaction should span exactly the set of writes that must be true together, and nothing else. If you cannot name why a second write belongs inside it, it does not.

</details>

---

## Timeouts, Retries and Circuit Breakers

---

### 60. What's the difference between a timeout, retry, and circuit breaker?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
They protect different parties. A timeout protects the caller's own resources by bounding how long a request may occupy them; a retry protects the caller's success rate against a transient failure; a circuit breaker protects the callee — and, second-order, the caller's thread pool — by stopping the calls entirely once it is clear they are not going to work. You need all three, and the retry is the one that is dangerous without the other two.

<details>
<summary><strong>Detailed answer</strong></summary>

**Timeout.** A bound on how long you will wait. Without one, a hung dependency is an unbounded resource leak: workers, connections and memory accumulate until the caller dies of a failure that happened somewhere else. Two details matter. Separate the **connect** timeout from the **read** timeout — a connect failure is safe to retry because nothing was sent, while a read timeout on a `POST` may mean the server committed and the response was lost, which is a different risk. And a timeout should be derived from a **deadline that propagates**: if the user's request has 400 ms left, an inner call with a 2 s timeout is meaningless, because the caller will have given up before it fires. In the marketplace the one synchronous inter-service hop, `connection-service` asking `retailer-service` whether a thread already exists, carries a 250 ms timeout; in the cancer platform the extraction call into `clinical-nlp-svc` carries a 2 s deadline and runs inside a background task rather than a request.

**Retry.** A second attempt on the assumption the failure was transient. Three conditions have to hold before it is legitimate. The operation must be **safe to repeat** — idempotent by nature, or carrying an idempotency key. The error must be in a **retryable class** — a connection refused, a `503`, a serialization failure; never a `400`, a `403` or a `422`, where the second attempt is guaranteed to fail identically. And the retry must be **bounded and spread**: exponential backoff with full jitter, a small maximum attempt count, and a retry budget expressed as a fraction of total traffic so the retries cannot become the load. Retrying without these is the subject of the next question.

**Circuit breaker.** A state machine in front of the dependency. Closed, calls pass and failures are counted. Once the failure rate crosses a threshold it opens and calls fail immediately without touching the network. After a cooldown it goes half-open and lets a small number of probes through: success closes it, failure re-opens it with a longer cooldown. It buys two things — the struggling dependency gets a chance to recover instead of being held at full load while it is failing, and the caller stops spending its own workers waiting for calls it already knows will fail. That second effect is the one that prevents a dependency's outage from becoming your outage.

**How they compose, and what each is not.** The timeout makes the failure *fast*; the retry makes a transient failure *invisible*; the breaker makes a sustained failure *cheap*. A retry without a timeout retries something that never finished. A retry without a breaker keeps a dying dependency dying. A breaker without a fallback turns a degraded feature into an error page, so the fourth element — a named degraded behaviour — is what makes the pattern useful rather than merely defensive.

**Bulkheads are the fourth member of this family** and belong in the same answer. A separate connection pool or a bounded semaphore per dependency means that however badly one dependency behaves, it can only consume its own share of workers. Without a bulkhead, a single slow dependency eventually occupies every worker in the process, and every unrelated endpoint fails with it.

**The strongest version of the answer is architectural rather than library-level.** The cancer platform's design states that no synchronous user path depends on `clinical-nlp-svc` at all: requests queue on `celery.content`, so the GPU cluster being unavailable pauses new page generation and does not touch a single user-facing request. A dependency you do not call synchronously needs no breaker.

</details>

---

### 61. Why can retries actually make an outage worse?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Because a retry multiplies load at exactly the moment capacity has dropped. Three attempts per request is four times the traffic arriving at a system that just proved it cannot serve one times — and if several layers each retry, the multiplication compounds. Without jitter they arrive synchronised, and the result is a system that stays down after the original cause is gone.

<details>
<summary><strong>Detailed answer</strong></summary>

**The arithmetic.** A client that retries three times turns 100 requests per second into 400 when things start failing. Now stack the layers, which is the case people underestimate: a browser or SDK retry, a gateway retry, an application-level retry, and a database driver retry — each with three attempts — is 3⁴ in the worst case. Every layer looked reasonable in isolation. This is why a retry budget belongs at the top of the stack, and why retries at more than one layer of a call chain is an anti-pattern rather than defence in depth.

**Synchronisation.** Fixed backoff, or even plain exponential backoff without jitter, makes every failed client wait the same interval and retry at the same instant. The recovering service receives a wall of traffic, falls over, and produces another synchronised wave. **Full jitter** — sleep a random duration between zero and the current backoff ceiling — spreads them out, and it is the single cheapest fix in this entire area.

**Work nobody is waiting for.** When the caller has already timed out, the request still in flight is dead work, but it still consumes a worker, a connection and a database transaction. Under a retry storm, a large fraction of the work a system is doing is for clients that have gone. The defence is deadline propagation: pass the remaining budget down, and let each hop refuse work whose deadline has already passed rather than doing it and discarding the result.

**Queue and pool poisoning.** Retries fill bounded resources. The connection pool saturates, so healthy endpoints start queueing behind the failing one. A broker's queue depth climbs, and on a broker under memory pressure that becomes flow control on publishers — a distinct failure that spreads back into the services doing the publishing, which is exactly the shape of "millions of updates overloaded the broker and took production with it".

**Metastable failure, which is the name worth knowing.** The system enters a state where the retry load is itself sufficient to keep it failing, so removing the original trigger does not fix it. The database is now slow *because* of the retries, which are happening *because* it is slow. Recovery requires shedding load from the outside — rate-limiting at the edge, or literally turning clients away — and that is a very uncomfortable incident to run. Recognising it matters because the intuitive response, "wait for it to recover", never terminates.

**So what makes a retry safe:**

- **A retry budget**, not a retry count — cap retries at a small percentage of successful traffic, so under a broad failure retries approach zero automatically. This is the control that fails safe as the failure widens.
- **Exponential backoff with full jitter**, and a hard attempt ceiling.
- **Retry only retryable errors**, and only idempotent operations or ones carrying an idempotency key.
- **Retry at one layer**, chosen deliberately, and disable it at the others.
- **A circuit breaker underneath**, so a sustained failure stops generating attempts at all.
- **Deadline propagation**, so a retry is never attempted past the caller's deadline.

**And the recovery-side detail people miss:** the moment the dependency comes back is the most dangerous one. Every breaker half-opens, every backoff expires, every pool refills, and the caches are cold — so the returning traffic is larger and more expensive per request than the steady state. The marketplace design sizes for exactly this by noting that a Redis loss multiplies PostgreSQL load roughly sixfold and provisioning to survive it, and it names bounded reconnection as the specific mitigation for the post-failover storm.

</details>

---

### 62. Design a service that communicates with another unreliable service.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The first design decision is whether the call needs to be synchronous at all; if the user does not need the answer to get their response, put a queue between them and most of the problem disappears. Where it must be synchronous, the stack is a propagated deadline, a bulkhead, a timeout inside that deadline, budgeted and jittered retries on idempotent calls only, a circuit breaker, and a named fallback — plus per-dependency observability, because you cannot operate what you cannot see failing.

<details>
<summary><strong>Detailed answer</strong></summary>

**Decide the interaction shape first.** This is the decision that dominates all the library-level ones. The cancer platform's rule is that no synchronous user path depends on `clinical-nlp-svc`: page generation is enqueued on `celery.content`, and the GPU cluster being unreachable means new page generation pauses while already-approved pages serve normally. The marketplace draws the same line at the outbox — publishing a listing must not fail because the notifier is down, so the state change commits with an `outbox_event` and delivery happens afterwards. Both are the same move: convert a dependency on availability into a dependency on eventual delivery. Where that is possible it beats every resilience pattern, because the failure stops being user-visible rather than being handled gracefully.

**Where it must be synchronous, the layers, outermost first.**

1. **A deadline, propagated.** The incoming request has a budget. Each hop subtracts what it has spent and passes the remainder. A call whose deadline has already expired is not attempted.
2. **A bulkhead.** A dedicated connection pool or a bounded semaphore per dependency. Without it, one slow dependency eventually holds every worker in the process and every unrelated endpoint fails alongside it. This is the control that keeps the blast radius to the feature rather than the service.
3. **A timeout strictly inside the deadline**, with connect and read timeouts separated so the retry decision can distinguish "nothing was sent" from "something may have been applied".
4. **Retries, budgeted and jittered, on idempotent operations only.** Outbound mutations carry an idempotency key so the remote side can deduplicate, which is what makes a retry on a `POST` legitimate at all.
5. **A circuit breaker** with half-open probing, so a sustained outage costs no threads and gives the dependency room to recover.
6. **A fallback that is named in the design, not improvised in the incident.** Serve last-known-good from cache; degrade the feature and say so in the response; queue the work for later; or fail open. The marketplace picks fail-open explicitly on its one synchronous inter-service hop — if `retailer-service` does not answer within 250 ms, the connection request proceeds, because refusing a legitimate connection costs the marketplace more than an occasional duplicate thread, and the `UNIQUE (retail_group_id, idempotency_key)` constraint catches the duplicate anyway. That is the right shape for a fallback: a stated trade-off with a compensating control, not a shrug.

**Make the boundary observable.** Per-dependency metrics for call rate, error rate by class, latency percentiles, timeout count, breaker state and bulkhead saturation. Breaker transitions should be events you can see on a dashboard, because "the breaker opened at 14:02" collapses an investigation that otherwise takes an hour. Trace context propagates across the call so a failure is one trace and not two half-stories.

**Two more that belong in a senior answer.** **Contract testing**, because an unreliable dependency is often unreliable in shape as well as availability — a field that becomes nullable is an outage you caused by trusting a document. And **treat the dependency's service level objective as a ceiling on yours**: if it offers 99.5% and you call it synchronously on every request, you cannot promise 99.9%, and the only ways to break that arithmetic are caching, a fallback, or moving the call off the request path. Saying that out loud during design is more valuable than any amount of retry tuning.

</details>

---

## Asynchronous Jobs and Duplicate Delivery

---

### 63. Your queue delivers the same message twice. What happens?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
That depends entirely on the consumer, and in both of these systems the answer is "nothing" — by design, because at-least-once delivery is the guarantee we chose and duplicates are therefore normal traffic rather than an incident. Every handler is idempotent against a key in the database, and where that is impossible the duplicate is explicitly tolerated.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it happens, and why it is not a bug to fix.** Consumers acknowledge **after** their work commits — late acknowledgement — so a crash between the work and the acknowledgement produces a redelivery rather than a lost message. That is the trade deliberately taken: at-least-once with duplicates, instead of at-most-once with gaps. Redelivery also follows a visibility-timeout expiry when a handler is merely slow, a broker failover, a consumer rebalance, or a publisher that retried after a lost confirm. "Exactly-once delivery" is not on offer from any broker; what is achievable is exactly-once *effect*, and that is the consumer's job.

**So the handler carries the guarantee.** Four mechanisms, in the order I reach for them:

1. **A natural key with an upsert.** Check-ins are unique on `(patient_id, recorded_for)` and the projection is `INSERT … ON CONFLICT (patient_id, recorded_for) DO UPDATE`. A redelivered message writes the same row. The design says explicitly that this choice was made so a redelivery is arithmetic rather than a bug, and that is the right framing — the correctness lives in the schema, where it cannot be forgotten by the next handler someone writes.
2. **A monotonic guard, which also handles out-of-order.** `indexer-worker` upserts `product_listing_facets` on `product_id` and ignores an event whose `source_revision_id` is older than the row's current value. Deduplication alone would not give you this: two distinct events arriving out of order would leave the listing on the older revision. The version comparison fixes both problems with one predicate, and out-of-order is the failure people forget to test.
3. **A uniqueness constraint on the effect.** `UNIQUE (connection_request_id) WHERE kind = 'connection'` means the second delivery of `connection.requested` cannot produce a second charge, regardless of what the handler does.
4. **A dedupe table on `event_id`**, for handlers with no natural key. The important detail is that the dedupe insert and the side effect must commit **in the same transaction** — otherwise you have moved the race rather than removed it, and a crash between them produces either a lost effect or a duplicate depending on the order.

**Note what is deliberately not the mechanism.** Redis idempotency keys exist in the cancer platform and are documented as the *optimisation*, not the guarantee — flushing the cache permits a duplicate to be reprocessed, and the database key is what stops it. An application-side "have I seen this" set that can itself be lost is not a control.

**Where duplicates are accepted rather than eliminated.** Reminder delivery can send twice under a receipt-loss race, and the design takes that deliberately: a patient seeing a reminder twice is a far better failure than not seeing it. Being able to say which duplicates you have chosen to live with, and why that choice is the right way round, is the part that distinguishes a designed system from a hopeful one.

**And the operational side.** A duplicate that a handler cannot absorb ends up in a dead-letter queue rather than being retried forever, and dead-letter count greater than zero is an alert in both designs. A sudden rise in redeliveries usually means handlers have become slow enough to exceed the visibility timeout — the queue is telling you about a latency problem, not a delivery problem, and reading it that way saves a lot of time.

</details>

---

### 64. Design an asynchronous job system.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Keep the state machine in the database and use the broker only for transport. A job is a row with a state, claimed with `FOR UPDATE SKIP LOCKED`, enqueued transactionally through an outbox, executed by an idempotent handler with late acknowledgement, retried with bounded backoff and then dead-lettered with an alert. That arrangement makes a broker outage produce lateness rather than loss, and makes "was it done?" a query rather than a log search.

<details>
<summary><strong>Detailed answer</strong></summary>

**The organising principle.** The cancer platform states it as a property: reminders stay `pending` in PostgreSQL and are re-swept, so a broker or Function outage makes them **late, not lost**. Everything below follows from putting the state in the database rather than in the queue. A message in flight is invisible, unqueryable and unreportable; a row is none of those things.

**Submission.** The job row and the business change commit together, and the event that hands it to a worker goes through `outbox_event` in the same transaction. There is no window in which the work was requested and nothing knows about it. The submitting API returns `202` with a status URL — the marketplace's `ImportJob { id, status: queued }` and the cancer platform's `{request_id, status_url}` are both this shape — because a client that cannot poll for an outcome will poll you instead.

**Claiming.** Workers take due rows with `SELECT … FOR UPDATE SKIP LOCKED`, flip the state to `dispatching`, and write an attempt row. Skip-locked is what lets the pool scale horizontally with no double-dispatch and no workers blocked behind each other. Every attempt is a **row**, not a log line — which is why "were the reminders delivered" is a query and why the brief's 22% improvement is measurable at all.

**Execution and acknowledgement.** Handlers acknowledge late, after the work commits, so a crash is a redelivery. Therefore every handler is idempotent against a database key, as in the previous question. Durable queues matter here: quorum queues on a three-node [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") cluster with mandatory publisher confirms, because a publish that returns when the frame hits the socket tells you nothing about replication.

**Retries, and then a place to stop.** Exponential backoff with jitter, a hard attempt ceiling, and then a dead-letter queue — with `dead-letter count > 0` as an alert, because a message that exhausted its retries is *somewhere*, and the dead-letter queue is where you read the actual exception. A terminal failure should escalate into the product, not end in a log: a reminder that cannot be delivered raises a care-team flag.

**Isolation, which is where the client's stated pain lives.** A bulk load must not degrade anything else, and three separate mechanisms enforce that:

- **Separate queues per work class** — `celery.reminders`, `celery.content`, `celery.index`; `imports`, `indexing`, `notifications` — with separate worker deployments, so importers scale on import depth and cannot starve the indexer.
- **A per-tenant concurrency cap** — at most four concurrent import chunks per vendor, held as a Redis semaphore, so one vendor cannot occupy the pool.
- **Batching and coalescing.** A completed import emits **one** event and the indexer re-projects in batches of 200, rather than one event and one cache invalidation per row. This is the specific defence against the failure where millions of attribute updates flood a broker: the fix is not a bigger broker, it is not producing one message per row. Prefetch limits and bounded payloads — a reference rather than the document — are the other two halves of keeping broker memory flat under a burst.

**Scheduling.** A singleton scheduler holding a distributed lock, so a restart cannot double-schedule, with a liveness probe on last-tick age. It is a single point of failure by construction, and the mitigation is that its failure delays rather than loses work — again because the due rows live in the database.

**Observability, the four numbers I want before I want a log:** unpublished outbox age, queue depth and unacknowledged count per queue, dead-letter count, and end-to-end lag from `occurred_at` to completion. Each localises a failure to a stage. Queue depth is also the autoscaling signal.

**Shutdown.** Workers are drained, not killed: `preStop` stops consumption and waits for the in-flight task within a bounded grace period, and chunk sizes are chosen to finish well inside it.

**One honest caveat I would raise unprompted.** Celery on Redis does not have real acknowledgement semantics — durability rests on a visibility timeout, and a broker failover can still drop unacknowledged tasks. If the work must be durable, move that queue onto a broker that acknowledges properly, and keep Redis for the work that is fully rebuildable from the outbox. That is a decision to make with a kill-the-worker test in front of you, not from the documentation.

</details>

---

## Scaling and System Composition

---

### 65. Explain purpose of each component from system design perspective: caching, replicas, queues, workers, object storage, observability, horizontal scaling?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Each one removes a specific pressure and adds a specific cost, and the cost is the part worth knowing. Caching trades freshness for latency, replicas trade consistency for read capacity, queues trade immediacy for durability, workers trade simplicity for isolation, object storage keeps bytes off the application tier, observability is what makes silent failures visible, and horizontal scaling is what statelessness buys you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Caching — buys latency and load reduction, costs freshness and an invalidation rule.** The marketplace caches hydrated listings at `cat:listing:{product_id}:v{rev}` and search pages at `cat:search:{filter_hash}`, and the latency budget assumes an 85% hit ratio on the search page. The discipline that makes it safe: **every layer has a stated invalidation rule**, and the revision in the key means a stale entry is unreachable even if the purge message is lost. The rule I would state is that nothing patient-identifiable is cached at a layer that cannot see the requester's identity — which is why gateway response caching is switched off by policy in the cancer platform rather than merely unused. A cache with no invalidation story is a correctness bug with a latency benefit.

**Read replicas — buy read capacity and isolation for heavy reads, cost you read-your-writes.** The marketplace serves catalog search from a replica and routes every write and every must-be-fresh read to the primary. The cancer platform makes the opposite call for an instructive reason: every read of patient data writes an audit row, so an audited read is a write and **cannot be served by a replica at all**. Replicas there carry only unaudited work — index rebuilds, reporting, backup verification. That is the clearest example I know that a replica is not free read capacity; it is read capacity for queries whose consistency and write requirements permit it.

**Queues — buy durability and decoupling, cost immediacy and an operational surface.** They take work off the request path so a slow or unavailable downstream cannot fail the user's request, and they absorb bursts that would otherwise have to be provisioned for. The check-in path is the purest case: the message is durable on the broker before the record write, so a flaky mobile connection cannot lose a patient's symptom entry. The costs are real — at-least-once delivery, therefore idempotent consumers; a backlog that needs a metric; and a dead-letter queue somebody has to read.

**Workers — buy isolation of blast radius and independent scaling.** Separate deployments consuming separate queues mean a 20,000-row import scales the importers on queue depth without touching the web tier, and cannot starve the indexer. Same codebase, different process, different failure domain. The cost is more deployments to observe and a second place where code runs.

**Object storage — keeps large bytes out of the application entirely.** Documents upload directly to blob storage with a short-lived signed token rather than proxying through the API, so multi-megabyte scans never touch the pods serving a clinician's timeline, and the database row holds metadata and a path. It is also where immutability and lifecycle live: a write-once audit archive with a seven-year legal hold is a storage feature, not an application feature.

**Observability — the only reason anyone knows the system is broken.** Three planes joined by one trace identifier: metrics for the shape, traces for the path, logs for the detail. Its real purpose is the failures nothing else surfaces. A dead indexer raises no error anywhere — listings simply stop becoming searchable — so `indexer_lag_seconds` alerting at 60 s is the *only* thing standing between that and a silent product outage. That is the argument for observability as a component rather than a nicety.

**Horizontal scaling — buys capacity and, more importantly, redundancy.** Adding identical stateless replicas behind a load balancer is how you absorb load, survive an instance loss, and deploy without downtime. It works only if the instances hold no request-affine state, which is what statelessness is for. The limit is that it scales the tier you replicate and nothing else: the database, the broker and the caches remain shared, so beyond a point adding pods just concentrates more pressure on the same primary.

**The connecting idea.** None of these is a default. Both of these designs refuse components against a measured number — no sharding at 200 queries per second, no search cluster for 40,000 listings, no service mesh for nine workloads — and each component taken is justified against a figure with the condition that would reverse it written down. That reasoning is more useful in an interview than the component list.

</details>

---

### 66. Explain load balancing. Why would we put a load balancer in front of three API instances? What happens if one instance dies?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace

**Brief answer**
A load balancer spreads requests across instances and, more importantly, continuously decides which instances are eligible to receive them. Three instances are not primarily about capacity — they are what lets you lose one, or deliberately take one out to deploy, without an outage. When one dies, the health check removes it, in-flight requests to it fail and must be retried, and the remaining two absorb the traffic, which only works if you left headroom for that.

<details>
<summary><strong>Detailed answer</strong></summary>

**Two jobs, and the second is the important one.** Distribution is the obvious job. Health checking is the one that turns three servers into an available service: the balancer probes each instance and routes only to the ones passing, so a failed instance stops receiving traffic within a probe interval rather than continuing to serve errors.

**Why three rather than one bigger box.** Capacity is the least interesting reason at 35 queries per second. The real ones are: an instance can fail without the service failing; you can deploy by rolling instances out one at a time while the others serve; and with instances spread across availability zones the loss of a zone is a capacity reduction rather than an outage. In the marketplace `catalog-service` additionally runs a second deployment receiving about 10% of traffic as a canary, held for fifteen minutes against its error rate and latency before the weight advances — which is only possible because the balancer can weight destinations.

**Algorithms, briefly, and when the default is wrong.** Round robin is fine when requests cost roughly the same. **Least outstanding requests** is better when they do not, which is the usual case for an API where one route is a 3 ms cache hit and another is a 107 ms uncached search — round robin will happily keep feeding an instance that is already stuck behind slow work. Consistent hashing matters when the backends hold per-key state, such as a cache tier, and is unnecessary for stateless application pods.

**What happens when one dies, step by step.**

1. **In-flight requests on that instance fail.** Nothing saves them — this is why clients and gateways retry idempotent requests, and why a `POST` needs an idempotency key before a retry is safe.
2. **The health probe fails and the instance is removed**, after the configured threshold. That delay is a deliberate trade: too aggressive and a garbage-collection pause ejects a healthy instance, too slow and clients see errors for longer.
3. **The remaining two carry the load.** If the three were running at 70% CPU, two cannot carry 105% and you now have a cascade rather than a degradation. Headroom for `n-1` is the actual design requirement, and it is the reason autoscaling targets are set well below saturation.
4. **The orchestrator replaces the instance**, and the new one starts cold — empty in-process caches, a cold connection pool — so recovery takes longer than the restart.

**Two distinctions worth drawing unprompted.** **Readiness versus liveness**: readiness controls traffic, liveness controls restarts, and conflating them is a classic self-inflicted outage — a readiness probe that depends on the database will correctly stop traffic during a database blip, but a *liveness* probe that does the same will restart every pod in the fleet simultaneously at the worst moment. And **connection draining**: a pod being removed deliberately should stop accepting new connections, finish what it has, and then exit — a `preStop` hook and a grace period — otherwise every deploy is a small burst of errors.

**Sticky sessions.** They exist, and I would treat needing them as a signal to fix the application instead. Affinity defeats even distribution, makes the loss of an instance a loss of user state, and blocks rolling deploys. Move the session into Redis or a signed token and the problem disappears — which is exactly the next question.

</details>

---

### 67. What does it mean for a service to be stateless? If our API needs user sessions, does that mean the API cannot be stateless?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Stateless means no request depends on state held in *that particular process* from a previous request — so any instance can serve any request and losing an instance loses nothing. Sessions do not break it, provided the session lives somewhere shared: in Redis under a session identifier, or in a signed token the client carries. The application is stateless; the state is simply not in the application.

<details>
<summary><strong>Detailed answer</strong></summary>

**The precise claim.** Statelessness is not "holds nothing in memory" — every service holds connection pools, compiled validators, and in-process caches of near-static data such as the category tree and facet schemas. Those are legitimate because nothing breaks if a request lands on a different pod: the new pod rebuilds them, and no *correctness* depends on which instance handled the previous request. The test is: can I kill any instance at any moment and lose nothing but the requests currently in flight? If yes, it is stateless in the sense that matters, and horizontal scaling, rolling deploys and instance replacement all work.

**Sessions, two ways, both stateless in that sense.**

- **Server-side session in a shared store.** The cancer platform keeps `sess:{session_id}` in Redis with a 30-minute sliding expiry. The client holds only an opaque identifier; any pod resolves it. Revocation is immediate — delete the key — which is the main advantage.
- **Self-contained signed token.** The marketplace issues [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") JSON Web Tokens with a 15-minute lifetime carrying account type, organisation and scopes, verified locally against a key set cached in Redis. No lookup per request at all, which is precisely why authorization costs about 1 ms in the latency budget rather than the 15–30 ms an introspection round-trip would add.

**The trade-off between them is revocation, and it is worth naming.** A signed token cannot be un-issued, so revocation is bounded by the token lifetime. The marketplace answers that in layers: short access tokens, refresh-token rotation with reuse detection that revokes the whole chain immediately, and for the case where fifteen minutes is still too long — a suspended vendor — an `identity.user.deactivated` event plus a small Redis denylist of revoked token identifiers. Note what that denylist is: a deliberate, bounded reintroduction of shared state to fix the one thing stateless tokens are bad at. That is a better answer than pretending the trade-off does not exist.

**What genuinely is not stateless, and what to do about it.** Long-lived connections — WebSockets, server-sent events, and the [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") check-in listener — bind a client to one process for the connection's duration, so scaling and deploys have to account for reconnection. In-memory rate-limit counters would be per-pod and therefore wrong, which is why the buckets live in Redis at `rl:{subject_id}:{bucket}`. A file written to local disk during an upload is invisible to the next request, which is why documents go directly to blob storage. And the scheduler is an honest singleton: one replica holding a distributed lock, because "exactly one process does the sweep" is inherently stateful — mitigated by keeping the due rows in the database so its failure delays work rather than losing it.

**So the direct answer:** needing sessions does not make an API stateful. Needing sessions *in the process's own memory* does, and that is the thing to move, not the requirement to drop.

</details>

---

### 68. Design a backend for an application with 10 million users. Start simple. What would you build, and where would you scale when traffic increases?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
First do the arithmetic, because ten million registered users is not a throughput figure — with ordinary engagement it is a few thousand requests per second, and most of the architecture follows from that number rather than from the headline. Start with one stateless API tier behind a load balancer, one relational primary with a replica, a cache, object storage for blobs, and a queue for anything slow. Then scale in the order things actually break: connections, then reads, then writes, then individual tables.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start with the estimate, out loud.** Ten million registered, perhaps 10% daily active, say 30 requests each per day: three million requests per day, about 35 per second average, and with an 8× peak factor roughly 300 per second at peak. That is a large but entirely ordinary single-primary workload. Both designs in this case did the same arithmetic and reached ~200 and ~35 queries per second respectively, and both then **refused to shard** on that basis. Getting this step wrong in either direction is the most expensive mistake available: over-build and you spend a year on distributed-systems tax, under-build and you find out during a launch.

**The simple version, which should be genuinely simple.**

- A stateless API tier, three or more replicas behind a load balancer, autoscaling on CPU.
- One relational primary with a read replica, zone-redundant, with point-in-time recovery.
- A cache in front of the hot reads.
- Object storage for user-uploaded bytes, uploaded directly with signed URLs, never proxied through the API.
- One queue plus a worker pool for anything the user does not need to wait for — email, thumbnails, indexing, exports.
- A transactional outbox from day one, because retrofitting it after the first lost event is much harder than starting with it.
- Observability and a pipeline with real gates from day one. These are not scaling features, they are what makes every later change survivable.

**Then scale in the order things break, which is fairly reliable:**

1. **Connections before capacity.** The first wall is usually the database connection limit multiplied by pod count, not database throughput. Bounded pools, a transaction-mode pooler, and autoscaling limits that respect the global ceiling.
2. **Reads.** A cache with a stated invalidation rule, then read replicas for queries whose consistency budget allows them. Route writes and read-your-writes traffic to the primary explicitly — the marketplace does this by having the vendor workspace read the primary and the metadata document directly, so vendors get read-your-writes while retailers get the fast, slightly stale projection.
3. **The hot query shape.** Almost always one query is most of the load. Give it a denormalised projection table it can serve from a single relation with no joins, indexes that match the access pattern rather than the columns, and keyset pagination. This is where the marketplace's `product_listing_facets` comes from, and it bought a 45 ms plan on the highest-traffic query in the system.
4. **Writes and unbounded tables.** Partition the two or three tables that grow forever — audit and message or event tables — by month, so retention is a detach rather than a long `DELETE`, and index maintenance stays in a small cache-resident B-tree. Then move the append-only, nobody-joins-to-it tables to their own instance. The cancer platform's evolution trigger is explicit: at 3,000 writes per second or 4 TB, extract audit first, then check-ins, and **only then** consider sharding — which is roughly 20× the modelled load.
5. **Search, if the relational projection stops being enough.** A dedicated search engine is a second store, a second consistency lag, a rebuild procedure and a scope filter that must never be omitted. Take it against a latency number, as the cancer platform did at 2.4 million notes, not against a preference.
6. **Fan-out and geography, last.** Multi-region active-active is a large step in cost and complexity, and for most products a four-hour regional recovery objective is the right business answer.

**What I would explicitly not do early:** shard, split into microservices, adopt a streaming platform for 0.2 events per second, or run a service mesh for nine workloads. Each of those is defensible at some scale, and the discipline is writing down the number that would trigger it so the decision is made against evidence later instead of against ambition now.

</details>

---

## Networking, HTTP and Access Control

---

### 69. Explain DNS, TCP and HTTP. What happens when I type https://api.example.com/users into my browser?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
Name resolution finds an address, a [TCP](https://datatracker.ietf.org/doc/html/rfc9293 "Transmission Control Protocol — Provides reliable, ordered byte-stream delivery between two endpoints") handshake establishes a reliable byte stream to it, a TLS handshake authenticates the server and encrypts that stream, and HTTP is the request-and-response protocol spoken inside it. Concretely: DNS lookup, three-way handshake, TLS 1.3 handshake with protocol negotiation, the request, the server's work, the response — and then the connection is kept alive so the next request skips almost all of it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before any packet.** The browser parses the URL and checks its HTTP Strict Transport Security list; for a host that has declared it, `http://` is rewritten to `https://` locally and a downgrade is never attempted on the wire.

**DNS — turning `api.example.com` into an address.** The stub resolver checks its cache, then the operating system's, then asks a recursive resolver. On a cold cache the recursive resolver walks the hierarchy — a root server for `.com`, the `.com` servers for `example.com`'s authoritative nameservers, those for the record itself — and caches each answer for its time-to-live. In practice a global service returns an anycast address or a provider-specific alias that resolves to the nearest edge. Two operational consequences worth stating: **the record's time-to-live is your failover speed**, because clients keep using a cached address until it expires; and DNS resolution is a synchronous dependency that can fail on its own, which is why resolver latency and failures deserve a metric.

**TCP — a reliable ordered byte stream.** A three-way handshake, SYN, SYN-ACK, ACK, costing one round trip, establishes sequence numbers and window sizes. From there TCP provides ordering, retransmission and flow control. Its relevant cost is that every new connection pays that round trip plus the slow-start ramp, which is why connection reuse matters so much and why a client library that opens a fresh connection per request is measurably slower.

**TLS — authenticating and encrypting the stream.** TLS 1.3 completes in one round trip. The client sends its supported parameters, a key share, the Server Name Indication naming the host — which is how one address serves many certificates — and the Application-Layer Protocol Negotiation list offering HTTP/2. The server responds with its certificate and key share, and traffic is encrypted from that point. The client validates the chain to a trusted root, checks the name and validity, and consults revocation. Session resumption lets a returning client skip most of this, and 0-RTT resumption removes the round trip entirely at the cost of replay exposure — so it is appropriate for idempotent requests only.

**HTTP — the conversation inside the tunnel.** Over HTTP/2 the request is a set of compressed header frames and, for a `GET`, no body: method `GET`, path `/users`, `authorization`, `accept`, and typically a propagated trace header. Multiple requests are multiplexed over the one connection rather than queued behind each other.

**What the server does with it**, which is where the previous answers connect: the edge terminates TLS, a gateway validates the token, a load balancer picks a healthy instance, and the application resolves dependencies, validates, handles, serializes and returns a status code, headers and body. The response travels back over the same connection, which is **kept alive** — so the second request to the same host pays neither the DNS lookup, nor the handshake, nor the TLS negotiation. That is the single biggest reason to reuse a client object rather than constructing one per call.

**The detail I would add.** Each of those stages is separately observable and separately breakable, and naming which one is slow is most of the work in a "the API is slow from our office" report — DNS resolution time, connect time, TLS handshake time and time-to-first-byte are four different numbers, and any HTTP client can be made to report all four.

</details>

---

### 70. What is the difference between HTTP 401 and 403? What should happen when an authenticated user tries to access another customer's data?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
`401` means the request is not authenticated — no credential, expired, or invalid — and the response must say how to authenticate; `403` means authenticated but not permitted, and repeating with the same credential will not help. For cross-tenant access the honest status is `403`, but the better answer is usually `404`: revealing that a resource exists in someone else's tenant is itself a leak. Either way the decision must be enforced server-side, in one place, and the attempt must be audited.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction as the specification draws it.** `401 Unauthorized` is a misnomer — it means *unauthenticated*, and a compliant response carries a `WWW-Authenticate` header telling the client what to present. The right client reaction is to obtain a credential and retry. `403 Forbidden` means the server understood who you are and is refusing anyway; retrying with the same identity is pointless, so a client must not treat it as retryable. Getting this wrong causes real bugs: a client that sees `403` on an expired token loops through a refresh it does not need, and a client that sees `401` for a permission failure logs the user out for no reason.

**Which one to return when.** No token, malformed token, bad signature, expired token, unknown key: `401`. Valid token, wrong scope, wrong role, wrong account type, wrong tenant: `403`. The cancer platform's gateway does exactly this — a clinician token presented on a patient route is rejected with `403` at the edge, because the token is perfectly valid and simply has the wrong audience for that plane.

**Now the harder half of the question.** A category manager at retail group A requests a shortlist belonging to retail group B. Three things have to be true.

**First, the check must be server-side and in one place.** The marketplace enforces tenant scope as a session-level filter applied by the repository layer, deliberately not per endpoint, because a per-endpoint check "is a control that works until the day someone adds an endpoint". The cancer platform goes further and pushes it into the database as row-level security, so a query a developer forgets to scope returns zero rows rather than another patient's record — its design calls this the single most important control it has, because it converts the most common class of application bug into an empty result set. Hiding the resource in the user interface is not a control at all; the request is being made against the API, not against the page.

**Second, choose the status deliberately.** `403` is semantically correct. But `403` on an identifier that exists and `404` on one that does not is an oracle: an attacker can enumerate valid identifiers across tenants without ever reading a record. So the common — and I think correct — choice for cross-tenant access is to return `404` and make "not yours" and "not there" indistinguishable. This falls out naturally from the enforcement mechanism: if the tenant filter is in the query, the row is simply not found, and `404` is what the handler would produce anyway. That is a nice property — the safe status code is the one the safe implementation produces without anyone deciding.

**Third, the attempt is a security event.** A cross-tenant request is not a routine `403`. Both designs audit it: the cancer platform's detection rules over the audit stream name "a clinician reading records outside their care team" as a specific rule rather than a generic anomaly, and the marketplace writes an `audit_event` for every tenant-scope bypass a platform admin performs. Rate-limit the caller too, because one such request is a bug in their client and a hundred is enumeration.

**The name for this class.** Broken object-level authorization — the vulnerability where an endpoint checks that you are logged in but not that the object belongs to you. It is consistently the most common serious API flaw in the field, and the defence is structural: one enforcement layer, plus a test that asserts a cross-tenant read returns empty for **every** org-owned repository method, which is exactly the compensating control the marketplace names for choosing application-layer filtering over database row-level security.

</details>

---

## Availability, Failure and Consistency Trade-offs

---

### 71. What's the difference between strong consistency and eventual consistency? What business trade-off exists here?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Under strong consistency a successful write is visible to every subsequent read; under eventual consistency reads may see an older value for a bounded period. The business trade-off is not abstract: it is whether a stale answer is recoverable. A listing that takes five seconds to appear in search costs nothing; a lost prescription write or a double-counted charge cannot be undone, so those paths pay for consistency with availability.

<details>
<summary><strong>Detailed answer</strong></summary>

**The definitions, tightened.** Strong consistency means reads are ordered after writes that completed before them — what a single primary gives you by default. Eventual consistency means replicas converge given no new writes, with no promise about when unless you make one. "Read-your-writes" is a weaker, often sufficient guarantee: *you* see your own write immediately, other people may not.

**The decision is per path, not per system, and that is the main point.** Both designs are explicitly mixed:

- The marketplace is **consistent and partition-tolerant for connections, billing and identity, available and partition-tolerant for catalog reads**. A connection request, a charge or a token must never be lost or double-counted; a listing edit invisible for a few seconds costs nothing.
- The cancer platform is consistent for the clinical record — under a partition it returns `503` rather than serve a possibly-stale prescription — and available for diary ingest, where a check-in is durable on the broker and acknowledged before it reaches the record, because losing a patient's symptom entry to a partition is worse than showing it a few seconds late.

Both state the boundary in the requirements document rather than discovering it per endpoint, and in the cancer platform the boundary between the two positions is literally a queue.

**What eventual consistency actually costs, which is the part that separates a real answer from a definition.** It is never free and it is never just "a bit stale":

- **A bounded lag, and therefore a budget and an alert.** The marketplace budgets projection freshness at p95 under 5 s, p99 under 30 s, and measures it as `indexer_lag_seconds` alerting at 60 s. The cancer platform composes its search budget rather than asserting it — a 2 s outbox relay plus a 5 s bulk flush plus a 5 s refresh interval gives p95 under 15 s, and it notes that tightening any one of the three alone buys nothing. "Eventually consistent" without a number and a metric means "eventually, possibly".
- **A reconciliation job.** Without one, a single lost event is permanent. Both designs have a nightly sweep that re-projects anything whose projection timestamp predates its update timestamp.
- **Read-your-writes routing for the author.** The vendor who just clicked publish is the one person for whom the lag is glaring, so the vendor workspace reads the primary and the document store directly, never the projection or the cache. The design does not shrink the lag; it routes around it for the one party who notices.
- **A second authorization surface.** Every store that can answer a query is a path around your access control, which is why every document in the clinical search index carries mandatory scope fields.

**How I would frame the trade-off to a business stakeholder.** Not as consistency versus availability, but as: *what does a wrong answer cost, and can we undo it?* A stale search result is a refresh. A double charge is a refund, a support conversation and a trust cost. A missing clinical record entry during a consultation is a safety incident. Once the question is asked that way the answer is usually obvious, and it is almost always different for different paths in the same product — which is exactly why a single system-wide consistency choice is the wrong shape of decision.

</details>

---

### 72. How do you make a backend service reliable? Imagine the service needs 99.9% availability.

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
99.9% is about forty-three minutes a month, which means one bad deploy can consume the whole budget — so reliability at that level is mostly about how you release, how fast you detect, and what you degrade to, rather than about extra replicas. Concretely: redundancy with named accepted single points of failure, timeouts and breakers on every dependency, a stated fallback per feature, capacity headroom for `n-1`, backwards-compatible migrations, rehearsed restores, and alerts on the failures nothing else surfaces.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start from the budget.** 99.9% monthly is ~43 minutes. A 60-second database failover costs 2% of it; a bad release that takes ten minutes to notice and five to roll back costs a third. That arithmetic tells you where to spend: deployment safety and detection speed dominate.

**Redundancy, and honesty about what is not redundant.** Multiple stateless replicas across availability zones; a zone-redundant database primary with automatic failover; a three-node broker with quorum queues so nothing is acknowledged that is not replicated. Then name the single points of failure you are *accepting*: both designs name the edge gateway as a genuine one and take it deliberately — for the cancer platform, because a second ingress path with its own authentication policy is a worse risk than the outage it prevents. An accepted single point of failure with a written reason is a design; an unnoticed one is an incident.

**Health checks that distinguish the two questions.** Readiness controls traffic, liveness controls restarts. Putting a dependency check in a liveness probe is how a database blip becomes a fleet-wide restart at the worst possible moment.

**Every dependency call bounded.** Timeouts derived from a propagated deadline, bulkheads so one dependency cannot consume every worker, budgeted and jittered retries on idempotent calls only, and circuit breakers. And the architectural version: move what you can off the request path, because a dependency you do not call synchronously cannot take you down.

**Graceful degradation, named per feature in advance.** This is what actually buys the number. Search degrades to a clearly-labelled chronological browse served from the relational store rather than erroring. Content generation backlogs while already-approved pages serve normally. A Redis outage in the marketplace is explicitly "not an outage" — every read falls through to the source stores at higher latency, and capacity is sized to survive the sixfold database load that causes. Deciding these during design, with the fallback path tested, is what separates a degradation from an outage.

**Capacity and dependency arithmetic.** Provision for `n-1` so losing an instance is not a cascade — the marketplace provisions for roughly 3× its modelled peak and calls that one autoscaling step rather than an architectural allowance. And your availability cannot exceed the product of the availabilities of every hard synchronous dependency, which is a strong argument for caching, fallbacks and asynchrony, and a strong argument against adding a synchronous hop casually.

**Release safety, which is where most of the budget goes.** Expand/contract migrations, so the previous image always runs against the new schema and **rollback is a redeploy of the previous digest** rather than a down-migration. Blue-green for the service holding the record, canary where a regression is statistical rather than binary. Blocking pipeline gates that can genuinely fail, with integration tests against real stores rather than mocks, because a mocked broker cannot fail the way a real one does. Workers drained rather than killed.

**Backups you have restored.** Point-in-time recovery with a stated recovery point and time objective, rehearsed quarterly against a scratch environment — including the rebuild of any derived store you claim as a mitigation elsewhere. A backup that has never been restored is an assumption, not a control.

**Detection, and alerting on the silent failures specifically.** Error rate, latency and saturation are table stakes. The alerts that earn their place are the ones on failures that raise no error: unpublished outbox age, indexer lag, reminder lateness, dead-letter count above zero, replica lag. A dead indexer produces no exception anywhere — listings simply stop becoming searchable — so without that metric the first report comes from a customer.

**And an error budget with a consequence.** The cancer platform states it plainly: exhaust the record-path budget and feature work stops for the sprint. A target with no consequence is a number in a document.

</details>

---

### 73. What happens if your database becomes unavailable for 30 seconds? What happens to your API? What happens if it stays unavailable for 30 minutes?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Thirty seconds is a failover — the designed case. Connections fail, the service fails fast with `503`, bounded and jittered reconnection avoids a storm, reads that the design permits are served from cache or replica, and writes that must not be lost are already durable on a broker. Thirty minutes is an incident: the error budget is gone, queues and retries have been accumulating the whole time, and the dangerous moment is the recovery, not the outage.

<details>
<summary><strong>Detailed answer</strong></summary>

**At 30 seconds — this is a zone failover, and it should be boring.**

- **Connection errors, not hangs.** A short connect timeout and pool pre-ping mean the application discovers the loss quickly instead of accumulating stuck workers. Requests return `503` with a `Retry-After` rather than timing out at the client's patience limit.
- **Bounded reconnection.** Every pod will try to refill its pool the instant the new primary accepts connections. Without backoff and jitter, hundreds of simultaneous authentication handshakes hit a cold instance and knock it over again — which is why the marketplace names pooling with bounded reconnection specifically as the mitigation for its 60–120 s failover window.
- **Readiness, not liveness.** Pods should report not-ready so traffic stops; they must not be restarted, or the fleet comes back cold precisely when the database returns.
- **What still works.** Catalog browse in the marketplace survives on the replica and the cache — a Redis-served listing detail needs no primary at all. Check-ins in the cancer platform are already durable on the broker before the record write, so the patient sees "recorded" and the projection catches up: recovery point objective zero for accepted check-ins, by design.
- **What deliberately does not.** The cancer platform serves **no** cached fallback for a patient timeline, because every read of patient data writes an audit row and a read that cannot be audited must not be served. Reads and writes both return `503` during failover. That is the stated price of synchronous audit, taken knowingly, and it fits the budget at a ~60 s failover — roughly 2% of forty-three minutes.
- **Queued work waits rather than fails.** Consumers back off and retry; messages stay on the broker; reminders stay `pending` in the database and are re-swept. Late, not lost.

**At 30 minutes — different in kind, not degree.**

- **The budget is spent.** Thirty minutes is 70% of a 99.9% monthly allowance. This is a declared incident with a status page, not a blip.
- **Backlogs become their own problem.** Queue depth climbs for half an hour. A broker under memory pressure applies flow control to publishers, and that pressure propagates back into services that were otherwise healthy — the failure mode where a backlog takes down components the original outage never touched.
- **Shed, don't retry.** Retry budgets should be driving attempts toward zero by now; breakers should be open. Continuing to retry into a dead database is the metastable pattern, where the retry load keeps the system down after the cause is gone.
- **Degrade explicitly.** Serve what is cached or replicated with a clear staleness indication, put anything that must be durable onto the queue path, and disable features that cannot be served honestly rather than letting them fail slowly.
- **Consider the restore path.** Beyond a failover this becomes a recovery decision against the stated objectives — the marketplace's 15-minute recovery point and 4-hour recovery time, the cancer platform's 5 minutes and 30 minutes. Knowing those numbers, and having rehearsed a point-in-time restore, is what makes the decision take minutes instead of hours.

**The recovery is the risky part, and this is the answer's real payload.** When the database comes back, three things arrive at once: every client's backed-off retries, half an hour of queued work draining at full worker concurrency, and a cold buffer cache serving requests from disk. On top of that the application caches have expired, so the load arriving is both larger and more expensive per request than the steady state — the marketplace's own figure is that a cold cache multiplies database load roughly sixfold. So recovery is deliberate: bring workers back with reduced concurrency and drain the backlog at a rate the database can absorb, admit user traffic behind a rate limit, let the caches warm, then lift. A recovered database killed by its own backlog is a common second outage and an avoidable one.

**Afterwards**, the useful question is not "why did the database fail" — it failed, that is what hardware does — but "which of our reactions made it worse", because those are the ones you can fix.

</details>
