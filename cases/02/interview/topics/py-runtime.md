# Python and the FastAPI Runtime

> 14 questions on the asynchronous model and the Global Interpreter Lock, the FastAPI request path, session lifetime, and pool, worker and thread sizing. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except PY-04, PY-08, PY-09, PY-11 and PY-14, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — PY-05, PY-06, PY-08, PY-09, PY-13, PY-14
- **retail-software-marketplace** — PY-05, PY-06, PY-08, PY-09, PY-10, PY-13, PY-14
- **general** — PY-01, PY-02, PY-03, PY-04, PY-07, PY-11, PY-12

---

## 1. Async model and the runtime

---

### PY-01. When do you write a route as `def` rather than `async def` in FastAPI, and what does each choice actually do to the thread pool and the event loop under load?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
`async def` runs the handler directly on the event loop; `def` runs it in a bounded worker thread pool. So `def` is correct for blocking work — a synchronous database driver, a library with no async version, anything central-processing-unit-bound — and `async def` is correct only when every await inside it is genuinely non-blocking. The dangerous combination is `async def` containing a blocking call, which stalls the whole event loop for every concurrent request, not just the one.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each actually does.** FastAPI inspects the signature. An `async def` route is awaited on the event loop in the same thread that is handling every other request. A plain `def` route is dispatched to an `anyio` worker thread pool — by default 40 threads — and the event loop awaits its completion, so the loop stays free while that thread blocks.

**The failure mode that matters.** One blocking call inside an `async def` — a synchronous database driver, `requests`, `time.sleep`, a large JSON parse, a bcrypt or [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive") hash, a Pandas operation — holds the event loop for its whole duration. During that time *no other request progresses at all*, not even ones that are ready. The symptom is characteristic and easy to misread: latency that degrades non-linearly with concurrency while central-processing-unit utilisation stays low and every endpoint slows down together, including the health check. People see low utilisation and conclude the service is not the bottleneck.

The inverse mistake is cheaper but real: writing `def` for a handler that only awaits network input-output means burning a thread for something the loop could have multiplexed, and the thread pool's 40 slots become the concurrency ceiling. Requests beyond that queue silently.

**So the rule I apply.** `async def` if and only if every call inside it is awaitable and non-blocking, all the way down — including the driver, the client library and the serialisation. Otherwise `def`, and let the thread pool do its job. A mixed handler — mostly async with one blocking call — is the worst of both, and the fix is `run_in_threadpool` (or `asyncio.to_thread`) around the blocking part rather than converting the whole route.

**The pool is a resource with a size, and it is shared.** The default 40 threads are shared by every `def` route *and* every `def` dependency. A slow blocking endpoint can exhaust it and stall unrelated `def` endpoints while the event loop sits idle. Raising the limit trades memory and context-switching for concurrency and is worth doing deliberately with a number, not by doubling until it stops hurting. The same applies to the database connection pool underneath: threads waiting on a pool with fewer connections than threads is queueing you cannot see from the outside.

**Where this connects to the stack in front of me.** This vacancy involves optimising a *synchronous* FastAPI architecture under heavy enterprise load, and that is a deliberate architecture rather than an oversight: with a synchronous database driver, `def` routes plus a correctly-sized thread pool are the right answer, and converting handlers to `async def` without converting the driver would be actively harmful. The tuning levers in that world are the thread pool size, the connection pool size, the worker-process count and the relationship between them — not the keyword on the function.

**How I would demonstrate it rather than assert it.** Two endpoints, one `async def` with a `time.sleep(1)` and one `def` with the same, and a load test at concurrency 20. The first serialises to twenty seconds and takes the health check down with it; the second finishes in about one second. It is a thirty-second demonstration and it makes the mechanism impossible to misremember.

</details>


---

### PY-02. Talking about FastAPI, explain sync vs async and where blocking operations can hurt an async service.

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

### PY-03. Why can an async Python service handle many requests even though Python has the GIL?

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

### PY-04. You are asked to migrate a synchronous FastAPI service to async. How would you sequence it, and when would you refuse?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
All the way down or not at all — async session, async driver, async repositories, async handlers — because a partial migration is strictly worse than the synchronous version. And I would refuse when the bottleneck is not concurrency at all, which it usually is not.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, establish that it is the answer.** Async concurrency helps a request that spends its time waiting. It does nothing for a request doing forty-five seconds of work, and nothing for a request issuing thirty queries. So before proposing the migration I want a trace breakdown per endpoint: time in the database, time in outbound calls, time in Python. If the time is in query count or in the plan, the migration is a large risky project that will not move the number, and saying so is more valuable than doing it.

**When it genuinely is the answer.** Handlers that spend most of their time waiting on input and output, high concurrency, and a connection or thread budget that binds because each synchronous request holds a worker for its whole duration.

**Why partial is worse than none.** Declaring a handler `async def` while it still calls a synchronous driver moves the blocking from a thread pool, where it is contained, onto the event loop, where it stalls every other request that worker is serving — including the health probe. The synchronous version was safe and bounded; the half-migrated one is neither. So the migration propagates: an async session implies an async driver, which implies async repositories, which implies async services, which implies async handlers.

**The sequencing I would use.**

1. **Get the blocking work out first**, onto a queue. This is worth doing regardless, it reduces the surface being migrated, and it frequently removes the need for the migration.
2. **Introduce the async driver and session alongside the existing one**, so both exist during the transition.
3. **Migrate by vertical slice** — one router with its services and repositories, end to end — rather than by layer. A layer-wise migration leaves a boundary where async calls synchronous, which is precisely the unsafe state.
4. **Set relationships to raise on lazy access before migrating**, not after. Under an async session an implicit lazy load raises anyway; discovering that during the migration means debugging it at the worst time, whereas turning it on beforehand surfaces every site while the code still works.
5. **Move the blocking calls that genuinely cannot be removed into a bounded thread pool.** The bound is the point — an unbounded offload just moves the queue somewhere invisible.
6. **Load test each slice**, because the failure mode is a single overlooked blocking call and it will not show up under low concurrency.

**When I would refuse outright.** If the team is not going to maintain the discipline afterwards. One synchronous call added later reintroduces the whole failure mode, silently, and it will be added by someone acting reasonably. Without the linting and the lazy-load setting to catch it, the migration buys a fragile system in exchange for a robust one.

</details>

---

## 2. The request path and service structure

---

### PY-05. What happens when a FastAPI endpoint receives an HTTP request? Walk me through the request from the client all the way to the application and back.

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

### PY-06. What belongs in a FastAPI dependency, what belongs in middleware, and what belongs in the handler itself — and how do you keep a dependency chain from becoming a hidden call graph nobody can follow?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Middleware for anything that must apply to every request regardless of route and needs the raw request or response — correlation ids, timing, compression, catch-all error shaping. Dependencies for anything route-scoped that produces a typed value or enforces a precondition — authentication, tenant scope, the database session, pagination parameters. The handler for the business decision and nothing else. The chain stays followable by keeping it shallow and typed, and by treating dependencies as *inputs*, not as a place to put side effects.

<details>
<summary><strong>Detailed answer</strong></summary>

**Middleware — the narrow case.** Middleware runs for every request including 404s and validation failures, sees the raw request and response, and cannot be selectively applied per route or return a typed value. So it is right for: assigning and propagating `request_id` and trace context; request timing and metrics; response compression; security headers; and a final exception boundary that turns anything unhandled into a problem-detail body rather than a stack trace. It is wrong for authorization, because middleware has to pattern-match on paths to know what to enforce, and a path-matching rule is a control that silently stops covering a route the day someone adds one under a prefix the pattern missed.

**Dependencies — the default.** Route-scoped, typed, testable, composable, and declared in the signature so they appear in the generated [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document. What lives here:

- **Authentication** — decode and verify the token, return a typed principal. Both systems validate locally against a cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") with no network call per request, which is the assumption the latency budget rests on.
- **Authorization preconditions** — account type and scope. In the marketplace `/v1/vendor/*` requires `act = vendor`, enforced by a dependency on the router, so a retailer token cannot reach a vendor route regardless of its scopes. Declaring it on the router rather than per endpoint is the point: adding an endpoint under that prefix inherits the check instead of needing someone to remember it.
- **The database session**, with deterministic cleanup.
- **Parameter objects** — pagination cursors, filter models — so validation is declarative and appears in the schema.
- **Tenant scope**, resolved once and attached to the repository layer.

**The handler.** The business decision, expressed against typed inputs. If a handler starts with fifteen lines of extracting things from the request, those lines are dependencies that have not been written yet.

**Keeping the chain followable — the real question.** A deep dependency graph is genuinely hard to read: the signature shows one parameter, and behind it are six layers each with its own side effects. What keeps it manageable:

- **Depth of two or three, not six.** A dependency may depend on another; a five-level chain means the abstraction is wrong.
- **Dependencies return values; they do not mutate global state.** The moment a dependency writes to `request.state` for another dependency to read, the graph has stopped being a graph and become implicit coupling. Ordering now matters and nothing declares it.
- **Type the return.** `current_user: Annotated[Principal, Depends(get_current_user)]` tells a reader what arrives without opening the dependency. An untyped `dict` forces everyone to go read it.
- **One clear name per concern**, and the same dependency reused everywhere rather than three near-identical auth dependencies that drift. Three copies of an authorization decision is the defect, not the convention.
- **Router-level dependencies for invariants**, endpoint-level for specifics — so the invariant is visible in one place rather than repeated thirty times, and cannot be forgotten on the thirty-first.
- **No heavy or side-effecting work in a dependency.** Dependencies run before the handler and on every request including ones that will be rejected later. A dependency that makes a network call has added that latency to every request on the route, and a dependency that writes has made a side effect happen for a request that may never be processed.
- **Read the generated OpenAPI document when in doubt.** Because dependencies surface as parameters and security schemes, the spec is a rendering of the chain — which is a genuinely useful review artefact, and one reason to prefer dependencies to middleware for anything a client needs to know about.

**The one exception I would make explicitly.** Cross-cutting concerns that have to apply to routes nobody has written yet — the exception boundary, correlation ids — are worth putting in middleware precisely because they should not be forgettable. Everything else being a dependency means it is visible in the signature, and visible beats implicit.

</details>


---

### PY-07. A dependency opens a database session and has to close it whatever happens. How do you write that, what does sub-dependency caching do within one request, and how do you override the whole chain in a test without touching real infrastructure?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
A generator dependency with `try/finally` — or a context manager — so the session closes on the normal path, on an exception and on a client disconnect. Within one request FastAPI caches each dependency's result by its callable and parameters, so every dependency that asks for the session gets the same one and the request has a single transaction. In tests, `app.dependency_overrides` replaces the session provider at the top of the chain, and everything beneath it follows without a single mock at the call sites.

<details>
<summary><strong>Detailed answer</strong></summary>

**Writing it.**

```python
def get_session() -> Iterator[Session]:
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
```

The `finally` is the load-bearing line: it runs on the happy path, on an exception raised in the handler, and when the client disconnects mid-request. Without it a leaked session holds a pooled connection, and under load the pool exhausts and every request blocks waiting for one — which presents as a total hang rather than an error, and is one of the harder failures to diagnose because nothing has raised. Whether to commit in the dependency or in a unit-of-work object inside the handler is a real choice; committing here keeps the request/transaction boundary in one place, at the cost of committing work the handler may not have considered final.

Two details specific to this pattern. First, the code after `yield` runs *after the response has been generated*, so raising there cannot change the status code the client already received — cleanup that must affect the response belongs before the yield or in an exception handler. Second, an `async def` session dependency must use an async driver and an async session; a synchronous session inside an async dependency blocks the event loop for the whole request, which is the single most common way a FastAPI service becomes mysteriously slow under concurrency.

**Sub-dependency caching.** Within one request, FastAPI caches by `(callable, parameters)`. So if `get_session` is required by `get_repository`, by `get_current_user` and by the handler itself, it is called once and all three receive the same object. That is what makes a request one transaction rather than three, and it is also why a dependency with a side effect is dangerous — it fires once per request, not once per declaration, and reasoning about that requires knowing this rule. `Depends(fn, use_cache=False)` opts out where a fresh value is genuinely required, which is rare and worth a comment when it happens.

The caching is per request, not global. A request-scoped cache of care-team membership is fine and correct; the cancer platform caches exactly that for the request's duration and states that the membership never outlives one request, because a stale authorization fact is a disclosure rather than a slow page.

**Overriding in tests.**

```python
app.dependency_overrides[get_session] = lambda: test_session
```

The property that makes this good is that the override happens at the *top* of the chain. Every dependency and every handler that asks for a session now receives the test one, with no patching at the call sites and no mock objects pretending to be a session. The same applies to `get_current_user` — override it with a fixture principal and every authorization dependency downstream works against a real token-shaped object.

**What I would and would not fake, though.** The override mechanism lets you replace the session with an in-memory SQLite one, and I would mostly refuse to. Both these projects run integration tests against real PostgreSQL, MongoDB and Redis in Docker Compose at the pinned versions, because the things a mock passes while broken are exactly the interesting ones: [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") query plans, the projection pipeline, `ON CONFLICT` behaviour, partial index selection, row-level security policies, and how a real broker behaves under flow control. A test suite that only proves the Python is self-consistent confirms whatever you already expected.

Where the override earns its place is at the *edges*: a transaction rolled back per test for isolation, a fixture principal instead of minting real tokens, and a stubbed external provider so the suite does not send email. The rule I would state is that you fake what you do not own and run what you do.

</details>


---

### PY-08. The same data arrives over HTTP, from a broker, and from a bulk import. Where does validation belong?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
At every boundary where data enters the process, including the broker — a message is untrusted input regardless of transport. What differs is the cost model: per-request validation is free at request scale and expensive at import scale, so the bulk path validates once at the edge and works with plain structures internally.

<details>
<summary><strong>Detailed answer</strong></summary>

**The rule: the boundary, not the transport.** It is tempting to treat a message from your own broker as trusted because it came from inside the estate. It is not: it may have been published by an older version of a producer, by a device on a lossy connection, or by a producer whose schema changed. On the health platform, check-ins arrive from patient handsets over a publish-subscribe transport and are validated against a typed model on the consumer side for exactly that reason. A device is untrusted input whatever protocol it speaks.

**What differs between the three paths.**

- **The request path.** Validate the whole body into a typed model. The cost is irrelevant at one body per request, and the payoff is a structured error naming the offending field, which is what makes an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") usable.
- **The message path.** Validate the envelope into a typed model too, but the failure handling is completely different. A request can return a 400 to a caller who will fix it; a message has nobody to tell. So an invalid message must dead-letter after bounded attempts rather than being retried forever, and the dead-letter has to be monitored — a poison message looping is capacity consumption that looks like healthy throughput.
- **The bulk path.** A twenty-thousand-row import validated as twenty thousand rich model instances at every stage is real cost for no additional safety. Validate each row once at the edge, collect the failures rather than aborting on the first, and work with plain structures through the batching and writing stages. And the response has to be per-row: a bulk operation that fails wholesale on one bad row is unusable, because the caller cannot make progress.

**What must never be skipped anywhere.** Anything crossing a trust boundary, and anything where the field decides authorization or money. Types on those come from the model, and the model is the same one wherever the data enters, so there is one definition rather than three that drift.

**Where validation must not live.** In a validator that queries the database. That turns parsing into an N+1 and it runs before any authorization has been applied, so it is also a way to probe for existence. Cross-record checks belong in the service layer, after the caller's scope is known.

**And the response side.** A declared response model is not decoration — it is what stops an internal field leaking into an API response. That is a security property, and it is the one reason I would keep response models on an endpoint whose input was already validated.

</details>


---

### PY-09. Explain how you manage a SQLAlchemy session's lifetime in a web application, and what goes wrong when you get it wrong.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
One session per request, opened and closed by a dependency, with the transaction boundary at the unit of work rather than per statement. The failures are a session shared across concurrent requests, a session held open across a slow external call, and objects used after the session has closed.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape.** A session factory at application startup, a dependency that yields a session per request and closes it afterwards including on an exception, and an explicit commit at the end of the successful path. Handlers do not commit individually — the request is the unit of work, so a partial write cannot survive a later failure in the same request.

**What goes wrong.**

- **A session shared between requests or tasks.** A session is not safe for concurrent use. A module-level session, or one captured in a closure and reused, produces symptoms that look like data corruption and are genuinely hard to trace, because two requests interleave on one connection.
- **Holding a transaction open across a slow call.** A handler that opens a transaction, calls an external service, waits three hundred milliseconds and then writes has held a connection and a set of locks for the whole call. Under load that exhausts the pool and creates lock contention that looks like a database problem. The transaction should be as short as the work that has to be atomic.
- **Detached instance access.** Touching an attribute after the session closed raises, or worse, quietly re-queries in a synchronous stack. The fix is to convert to the response model inside the request, which is what a response model does for you anyway.
- **Lazy loading in a loop.** The classic N+1. Setting relationships to raise on lazy access turns it into a loud error at development time instead of a silent extra query per row in production. Under an asynchronous session it raises anyway, because implicit input/output on the event loop is not permitted — one of the rare cases where the runtime enforces the discipline for you.
- **`expire_on_commit` surprises.** Attributes accessed after a commit re-fetch by default, which is a hidden query at exactly the moment you thought you were done.

**Sessions outside the request.** A worker task creates its own session with its own lifetime and does not inherit anything from a request context. Sharing an engine is fine; sharing a session is not. Each task is its own unit of work, which is also what makes retries safe.

**The one setting that is not about sessions but always comes up with them.** The pool size per process, multiplied by processes and replicas, against the database's connection limit. That is the constraint that actually binds in production, and it is discovered during a spike if it is not calculated in advance.

</details>

---

## 3. Pools, sizing and concurrency diagnosis

---

### PY-10. How would you handle a database connection pool in a FastAPI application?

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

### PY-11. Response times get worse under concurrency but the database looks idle. Walk me through the diagnosis.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
That combination almost always means requests are queuing on something with a fixed width — an event loop blocked by a synchronous call, a saturated thread pool, or an exhausted connection pool. The database being idle is the clue: nothing is working, everything is waiting.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the shape tells you.** Latency rising with concurrency while the downstream is idle means the bottleneck is in the process, and it is a queue rather than slow work. Three candidates, and they are distinguishable.

**1. A blocking call on the event loop.** The signature is that every endpoint on that worker degrades together, including trivial ones and the health probe, and processor use is moderate rather than pinned. Confirmation: enable the loop's debug mode or an equivalent slow-callback warning, which names the coroutine that held the loop. Common culprits are a synchronous database driver in an async handler, a synchronous [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client, a lazy-loaded relationship firing a query, and a large parse or crypto operation.

**2. A saturated thread pool.** If handlers are synchronous, concurrency is capped at the pool size and request N+1 waits for a slot. The signature is a hard plateau in throughput with latency rising linearly beyond it — a queue, textbook shape. Confirmation is comparing in-flight requests against the configured pool size.

**3. Connection pool exhaustion.** Time is spent waiting to acquire a connection, not executing a query, which is precisely why the database looks idle — it has few active sessions because the application cannot get to it. Confirmation: instrument pool wait time as its own metric, or look at pool checkout counts against the maximum. This one is easy to misdiagnose as a database problem and the fix is often the opposite of the instinct — fewer, better-used connections rather than more.

**What I look at, in order.** A trace with spans for connection acquisition, query execution and outbound calls, because that separates waiting from working immediately. Then in-flight request count against the concurrency limits. Then, if it is still unclear, a stack sample of the workers under load — a profiler that shows where threads actually are will show the whole pool parked in the same place.

**What I would not do first.** Add replicas. If the constraint is per-process concurrency, more replicas help; if it is the connection limit, more replicas make it strictly worse, and you have now changed two things while the graph moves.

</details>


---

### PY-12. You inherit a synchronous FastAPI service that is slow under concurrency. What do you measure first, and which optimisations would you do before anyone mentions rewriting it as async?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Measure where the time goes before changing anything: request latency broken into its components by trace, worker and thread-pool saturation, database connection-pool wait time, and the slow-query log. In my experience the cause is almost never "it is synchronous" — it is a pool sized wrong, an N+1 query, a missing index, or a blocking call sitting inside an `async def` route. All of those are cheaper to fix than a rewrite, and a rewrite that lands on top of them fixes nothing.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I measure, in order, and why that order.**

1. **A distributed trace of a slow request, decomposed.** Time in the gateway, time queued before the handler, time in each database call, time in outbound calls, time in serialisation. This single artefact usually ends the debate, because "slow under concurrency" describes three completely different problems — queueing, contention and per-request cost — and the trace distinguishes them immediately.
2. **Queueing versus service time.** If per-request work is unchanged under load but total latency rises linearly with concurrency, the service is queueing and the fix is capacity or pool sizing. If per-request work itself degrades, it is contention — locks, pool waits, or an overloaded database.
3. **Thread-pool saturation.** For `def` routes, the `anyio` pool defaults to 40 threads and is shared across every `def` route and dependency. If it is full, requests wait before they start, and the event loop looks idle the whole time.
4. **Database connection-pool wait time.** Threads waiting for a connection is invisible unless you instrument it. This is where a service with 40 threads and a pool of 5 spends its life.
5. **Worker process count versus cores.** A single Uvicorn worker on an eight-core node caps throughput at one core for anything central-processing-unit-bound. Free throughput, frequently unclaimed.
6. **The slow-query log and `pg_stat_statements`**, ordered by *total* time rather than by mean. The query that takes 20 ms and runs 400 times per request is the problem; the 2-second report that runs hourly is not.
7. **Whether any `async def` route contains a blocking call.** One `requests` call or one synchronous driver call inside an `async def` stalls the event loop for every concurrent request. The signature is low central-processing-unit utilisation with everything slow simultaneously, including the health check.

**The optimisations I would do first, roughly in order of value per unit of risk.**

- **Fix the N+1s.** Almost always present, almost always the biggest single win, and completely independent of async. In the marketplace this is the difference between hydrating thirty listings with one bulk `$in` and doing thirty round trips. Eager-load explicitly; the tracing view makes them obvious because you see thirty identical spans.
- **Size the pools coherently.** Thread pool, database pool and worker count are one system, not three settings. The sum of every pod's pool maximum must stay under the server's connection limit, and a thread pool larger than the connection pool just moves the queue.
- **Add the missing indexes, informed by the plan rather than by intuition**, and check the planner adopts them.
- **Move the blocking call out of the event loop** — `run_in_threadpool` around the offending part, not a rewrite of the route.
- **Take work off the request path entirely.** A request that sends an email, generates a thumbnail or re-indexes a document synchronously is doing work the user is not waiting for. Both these systems push that to a queue and return `202`, and it is often a larger win than any tuning.
- **Cache the expensive read**, with a stated invalidation rule and stampede protection, so the cache does not become its own incident at expiry.
- **Add more workers or pods.** Unfashionable and frequently correct: if the service is input-output-bound and the database has headroom, horizontal scale is cheaper than an engineering quarter.
- **Reduce payload size** — fewer fields, pagination limits, compression. Serialisation of large response bodies is real central-processing-unit time and is easy to overlook.

**What I would say about the rewrite.** Async gains throughput when a process spends most of its time waiting on the network and the concurrency ceiling is thread count. It gains nothing when the bottleneck is the database, and it makes things worse when a single blocking call remains anywhere in the path — which, in a codebase being converted incrementally, it will. A conversion also means an async driver, an async session, async-safe libraries, and re-testing every path, so it is a large change with a wide blast radius on a system that is already under pressure.

So my position would be: measure, take the cheap wins, and re-measure. If after that the profile shows threads waiting on the network with the database idle, then async is the right answer and now there is evidence for it. Given that this stack is explicitly a synchronous architecture under heavy enterprise load, I would expect to be tuning the pool relationships and the query layer rather than proposing a rewrite — and I would want the before-and-after numbers on the same graph either way, because "it feels faster" is not a result.

</details>


---

### PY-13. Why increasing the pool indefinitely can actually make the system worse?

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

### PY-14. How do you size workers, threads and connection pools for a deployed service, and which of those constraints actually binds?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Work backwards from the database's connection limit, because that is the constraint that binds in practice. Workers per pod times connections per worker times replicas has to stay under it, and everything else — thread pool size, autoscaler bounds — is chosen inside that budget.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the database limit is the real ceiling.** Every other number is elastic. The autoscaler will add pods, each pod starts its workers, and each worker opens its pool. Nobody notices until a spike, at which point the autoscaler cheerfully starts pods that cannot connect, and the failure presents as a database problem with every application dashboard green. So the budget is computed first and everything else is fitted to it.

**The arithmetic, and where people get it wrong.** Maximum pool size per worker, times workers per pod, times the maximum replica count — plus the workers, the migration job, and any analytics or administrative client that shares the same instance. That last group is what is usually forgotten, and it is what consumes the headroom during an incident when someone opens a session to look at something.

**What to do when the numbers do not fit.**

- **Shrink the per-pod pool rather than raising the limit.** A pod serving asynchronous handlers genuinely needs a small pool, because connections are held only while a query is in flight. Generous pools per pod are a habit from synchronous deployments.
- **Put a pooler in front in transaction mode**, which multiplexes many client connections onto few server ones. The caveat is important: transaction-mode pooling breaks anything relying on session state, which includes session-scoped settings used for authorization — a control that becomes its exact opposite when one caller's identity survives into the next request's query.
- **Cap the autoscaler's maximum deliberately**, so the scaling ceiling and the connection budget are the same decision rather than two.

**The thread pool.** In a service with any synchronous handlers, the pool size is the concurrency limit for those paths, and it consumes connections too. Too small and requests queue invisibly; too large and you have threads contending for the interpreter and a connection budget blown. It is derived, not defaulted.

**Workers per pod.** I prefer one, with the replica count owned by the orchestrator. Two layers of scaling that do not know about each other is a bad combination, and one process per container makes the memory limit meaningful and the metrics attributable.

**And I instrument pool wait time as its own metric.** Time spent waiting to acquire a connection is invisible in query latency and is exactly what saturation looks like. Without it, the diagnosis is guesswork; with it, it is a five-second answer.

</details>

