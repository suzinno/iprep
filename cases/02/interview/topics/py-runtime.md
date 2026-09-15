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
`async def` runs the handler directly on the event loop. `def` runs it in a bounded worker thread pool. So `def` is correct for blocking work: a synchronous database driver, a library with no async version, or anything processor-bound. `async def` is correct only when every await inside it is genuinely non-blocking. The dangerous combination is an `async def` that contains a blocking call. That call stalls the whole event loop for every concurrent request, not just for its own request.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each one actually does.** FastAPI inspects the signature. An `async def` route is awaited on the event loop, in the same thread that handles every other request. A plain `def` route is dispatched to an `anyio` worker thread pool, which has 40 threads by default. The event loop awaits the result, so the event loop stays free while that thread blocks.

**The failure mode that matters.** One blocking call inside an `async def` holds the event loop for as long as the call runs. That call can be a synchronous database driver, `requests`, `time.sleep`, a large JSON parse, a bcrypt or [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive") hash, or a Pandas operation. During that time *no other request progresses at all*, not even the ones that are ready. The symptom has a clear pattern, and it is easy to misread. Latency gets worse non-linearly as concurrency rises. At the same time, processor use stays low, and every endpoint slows down together, including the health check. People see the low processor use and conclude that the service is not the bottleneck.

The opposite mistake costs less, but it is real. If you write `def` for a handler that only awaits network input/output, you use a whole thread for work that the event loop could have multiplexed. Then the 40 slots of the thread pool become the concurrency ceiling. Requests beyond that limit queue silently.

**So this is the rule I apply.** Use `async def` if and only if every call inside it is awaitable and non-blocking, at every level underneath. That includes the driver, the client library and the serialization. Otherwise use `def`, and let the thread pool do its job. A mixed handler is the worst of both: it is mostly async, with one blocking call. The fix is `run_in_threadpool` (or `asyncio.to_thread`) around the blocking part, not converting the whole route.

**The thread pool is a resource with a limited size, and it is shared.** The default 40 threads are shared by every `def` route *and* every `def` dependency. A slow blocking endpoint can use up all of them. Then it stalls unrelated `def` endpoints while the event loop sits idle. Raising the limit gives you more concurrency, but you pay for it with memory and context switching. It is worth doing deliberately, with a chosen number. It is not worth doing by doubling the limit again and again until the problem goes away. The same applies to the database connection pool underneath. If threads wait on a connection pool that has fewer connections than threads, that is queueing you cannot see from the outside.

**How this connects to the stack in this vacancy.** This vacancy involves optimising a *synchronous* FastAPI architecture under heavy enterprise load. That architecture is deliberate, not an oversight. With a synchronous database driver, `def` routes plus a correctly sized thread pool are the right answer. Converting handlers to `async def` without converting the driver would be actively harmful. In that setup, the tuning levers are the thread pool size, the connection pool size, the worker process count and the relationship between them. The keyword on the function is not a tuning lever.

**How I would show it instead of just stating it.** I would use two endpoints: one `async def` with a `time.sleep(1)`, and one `def` with the same call. Then I would run a load test at concurrency 20. The first endpoint handles the requests one at a time, so together they take twenty seconds, and the health check goes down with them. The second endpoint finishes in about one second. The demonstration takes thirty seconds, and after it nobody can remember the mechanism wrongly.

</details>


---

### PY-02. Talking about FastAPI, explain sync vs async and where blocking operations can hurt an async service.

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
`async def` runs on the event loop and must never block. Plain `def` is handed to a bounded thread pool exactly so that it can block. The harmful case is a third combination that nobody declares deliberately: a blocking call inside an `async def`. That call stalls the entire event loop. So it also stalls every other request that the worker process is serving, not just the request that made the call.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each choice actually does.** FastAPI inspects the handler. `async def` is awaited directly on the event loop. The event loop is one thread with cooperative scheduling, and it holds thousands of in-flight requests that are each waiting on a socket. Plain `def` runs in an anyio worker thread pool, which is capped by default at around forty threads. So a synchronous handler is safe, but the thread pool size becomes your concurrency ceiling. The same rule applies to dependencies, and people forget this: a `def` dependency runs in a thread, and an `async def` dependency does not.

**The failure mode.** A single blocking call inside an `async def` does not slow that request. It stops the event loop. Every other coroutine on that worker process waits for the call, including coroutines that were about to finish. So a 300 ms blocking call under 50 concurrent requests does not cost 300 ms. It makes the whole worker process handle the requests one at a time. The tail latency rises very steeply while the processor is almost idle. That pattern is the one to recognise: flat processor use, collapsing throughput, and p99 far above p50. It is worth being able to name it as soon as you see it.

**The specific causes, in the order I have actually seen them:**

- **A synchronous database driver in an async handler.** `psycopg2` or a synchronous [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") `Session` inside an `async def` is the classic case. Either use the async engine with `asyncpg`, or declare the handler `def` and let the thread pool absorb the blocking. But do not mix the two.
- **`requests` instead of an async [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client.** One outbound call to a slow dependency blocks the whole event loop while that call waits.
- **Processor-heavy work.** Examples are large JSON serialization, image handling, password hashing with [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive") or bcrypt, and a regex over a big document. This work blocks however it is written. So it belongs in a thread, in a process pool, or off the request path entirely.
- **`time.sleep`, blocking file input/output, and synchronous client libraries** for brokers, caches and cloud storage. Many Software Development Kits (SDKs) ship both a synchronous and an async client, and they use the synchronous one by default.
- **Lock and queue primitives from `threading` or `queue`** used inside coroutines.

**Detecting it instead of guessing.** `asyncio` debug mode logs callbacks that run longer than a threshold. An Application Performance Monitoring agent shows a span whose duration no child span explains. Event-loop lag as a metric is the most direct signal there is, and it is worth exporting. Event-loop lag is the difference between the time a scheduled callback should have run and the time it actually ran.

**One honest note that matters for this role.** The client runs FastAPI synchronously under heavy enterprise load. That is a legitimate configuration, and it is not a mistake. With `def` handlers, the framework runs the work in threads. The tuning levers then move to worker processes per pod, the thread pool size, and the database connection pool behind them, not to coroutines. The mistake would be a half-migration: `async def` signatures over synchronous drivers. That gives you the fragility of the event loop with none of the concurrency.

</details>


---

### PY-03. Why can an async Python service handle many requests even though Python has the GIL?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
Because the work is waiting, not computing. The Global Interpreter Lock lets Python bytecode run on only one thread at a time. But a socket read runs no bytecode: it releases the lock and waits (parks). So one thread can hold thousands of outstanding requests that are all blocked on the network. Concurrency and parallelism are different things, and this workload only needs the first.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** The Global Interpreter Lock ([GIL](https://wiki.python.org/moin/GlobalInterpreterLock "CPython mechanism that lets only one thread execute Python bytecode at a time")) means that only one thread executes Python bytecode at a time in a given interpreter. The important point is that it is **released around blocking operations**: socket reads and writes, file input/output, and time inside a C extension that releases it. An async service never uses threads for this anyway. It runs one event loop on one thread. Every `await` on a socket gives control back to the event loop. The event loop is then free to advance any other coroutine whose socket has become ready. So the limit on in-flight requests becomes memory and file descriptors, not the lock.

**Why this fits the workload exactly.** Break down the marketplace's catalog search budget: 12 ms at the gateway, 3 ms at the ingress, 1 ms of local authorization, 3 ms and 4 ms in Redis, 45 ms in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), 25 ms in [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), and about 14 ms of serialization. The total is 107 ms. The 12 ms and the 3 ms pass before the request reaches the process. Of the 92 ms inside the process, roughly 77 ms is the process waiting on something else. Only the authorization check and the serialization are real Python bytecode. So one worker process can hold a large number of concurrent requests, because at any moment almost all of them are waiting (parked) on a socket. That is the whole argument for async here. It is an argument based on a measured budget, not a preference.

**Where the GIL really causes problems, and what to do about it.** The 14 ms of Pydantic serialization for thirty product summaries *is* bytecode. That part does not scale with coroutines. More concurrency makes that queue longer, not shorter. The fixes all have the same shape: get more interpreters.

- **More Uvicorn worker processes per pod, and more pods behind the load balancer.** Parallelism at the process level avoids the lock entirely. That is why horizontal scaling is the answer to processor pressure, and vertical concurrency is not.
- **Move the processor work out of the request.** The cancer platform's page composition is seconds of model work. So it was moved off the request path onto a [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") queue, instead of being trimmed to fit. The user never waits, and the pipeline can afford to be expensive.
- **Push the work into C.** Pydantic v2 does its validation in Rust. `orjson` serializes in native code, but it holds the GIL for the whole call. Numeric libraries release the GIL for the whole time they run. Time in a C extension is parallel only when that extension releases the GIL.

**The honest caveats.** Two of them are worth mentioning without being asked. First, async does not make anything faster. It improves throughput and resource efficiency under concurrency, and a single request is, if anything, slightly slower. Second, [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") now has a free-threaded build in which the GIL can be disabled. It is real, and it is supported. But nothing in this design relies on it. I would not plan capacity around it without benchmarking the actual workload. The reason is that single-threaded performance and C-extension compatibility are both still changing.

</details>


---

### PY-04. You are asked to migrate a synchronous FastAPI service to async. How would you sequence it, and when would you refuse?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Every layer or none: async session, async driver, async repositories, async handlers. That is because a partial migration is strictly worse than the synchronous version. And I would refuse when the bottleneck is not concurrency at all. Usually it is not.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, establish that the migration is the answer.** Async concurrency helps a request that spends its time waiting. It does nothing for a request doing forty-five seconds of work. It also does nothing for a request that issues thirty queries. So before I propose the migration, I want a trace breakdown per endpoint: time in the database, time in outbound calls, and time in Python. If the time is in the query count or in the query plan, the migration is a large, risky project that will not move the number. Saying so is more valuable than doing the migration.

**When it really is the answer.** Handlers that spend most of their time waiting on input/output, high concurrency, and a connection or thread budget that binds. That budget binds because each synchronous request holds a worker for its whole duration.

**Why a partial migration is worse than none.** Suppose a handler is declared `async def` while it still calls a synchronous driver. That moves the blocking from a thread pool, where it is contained, onto the event loop. On the event loop, it stalls every other request that the worker process is serving, including the health check. The synchronous version was safe and bounded. The half-migrated version is neither. So the migration spreads through the layers: an async session implies an async driver, which implies async repositories, which implies async services, which implies async handlers.

**The order I would use.**

1. **Get the blocking work out first**, onto a queue. This is worth doing anyway. It reduces the surface you have to migrate. And it frequently removes the need for the migration.
2. **Introduce the async driver and session next to the existing ones**, so both exist during the transition.
3. **Migrate by vertical slice**, not by layer. A vertical slice is one router with its services and repositories, end to end. A migration layer by layer leaves a boundary where async code calls synchronous code, and that is exactly the unsafe state.
4. **Set relationships to raise on lazy access before migrating**, not after. Under an async session, an implicit lazy load raises anyway. If you discover that during the migration, you have to debug it at the worst time. If you turn the setting on beforehand, it shows you every site while the code still works.
5. **Move the blocking calls that really cannot be removed into a bounded thread pool.** The bound is the point. An unbounded offload just moves the queue to a place where you cannot see it.
6. **Load test each slice**, because the failure mode is a single overlooked blocking call. That kind of call will not show up under low concurrency.

**When I would refuse outright.** I would refuse if the team is not going to keep the discipline afterwards. One synchronous call added later brings back the whole failure mode, silently. And someone acting reasonably will add it. Without the linting and the lazy-load setting to catch it, the migration gives up a robust system and gets a fragile one in return.

</details>

---

## 2. The request path and service structure

---

### PY-05. What happens when a FastAPI endpoint receives an HTTP request? Walk me through the request from the client all the way to the application and back.

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Transport Layer Security terminates at the edge. A gateway validates the token before any of my code runs. An ingress picks a pod. Only after that, an Asynchronous Server Gateway Interface server hands the application three things: a scope and two callables. Inside the process, the order is fixed: middleware from the outside in, routing, dependency resolution, body validation, the handler, serialization, and then middleware from the inside out on the way back.

<details>
<summary><strong>Detailed answer</strong></summary>

**The part before the application, because most of the interesting failures happen there.** In the marketplace, the chain is Azure Front Door with a Web Application Firewall, then Azure [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management, then the NGINX ingress on the cluster, then the pod. Front Door terminates Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")) 1.3 and runs the Open Worldwide Application Security Project rule set. API Management validates the [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Token ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties")) signature, expiry and audience. It also applies the per-subscription quota, and it routes the request. That order matters. A forged or expired token never reaches my code, and a volumetric flood never reaches the cluster. In the cancer platform, the same gateway does one extra thing, and that extra thing is the whole point of the design. It checks the token's **audience against the route's plane**. So a clinician token on `/api/v1/diary/check-ins` is rejected with `403` before application code runs.

The edge is a filter, not the authority. Every service validates the token again locally, against a JSON Web Key Set cached in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"). The reason is that a bypass of the gateway must not be a bypass of authentication. Neither check makes a network call per request. The whole latency budget depends on that assumption. An introspection round-trip would add 15–30 ms to every request in the system.

**The Asynchronous Server Gateway Interface ([ASGI](https://asgi.readthedocs.io/en/latest/ "Standard interface between asynchronous Python web servers and applications")) boundary.** Uvicorn parses the request and calls the application with three things: a `scope` dict that describes the connection and the request, an awaitable `receive` for reading the body in chunks, and an awaitable `send` for writing the response. That is the entire contract. It is also why streaming, WebSockets and background work all fit the same interface. The body has not been read yet at this point. The application reads it one event at a time, only when it awaits `receive`. So a large upload is not loaded into memory just because the request arrived.

**Inside the application, in order:**

1. **Middleware, outermost first.** ASGI middleware wraps the app in layers, like an onion: request-id assignment, trace-context extraction, logging, error trapping. A middleware can inspect on the way out everything that it added on the way in. That is why timing and structured-log enrichment belong here and not in handlers.
2. **Routing.** Starlette matches the method and the path against the compiled route table. It extracts path parameters as strings. If nothing matches, the result is a `404` before any of the application's own logic runs. If the path matches but the method is wrong, the result is a `405`.
3. **Dependency resolution.** [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") walks the dependency graph for that route and resolves it: authentication and the account-type check, the database session, the tenant scope. Sub-dependencies are cached **per request**, so a dependency that three others require is executed once. A dependency declared with `yield` runs its teardown after the response. That is how a session is guaranteed to close.
4. **Validation and coercion.** Path, query, header and body are parsed into the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models declared on the signature. A failure here is a `422` with a field-level error body. It is produced before the handler is entered, and that is the reason a handler can treat its arguments as already correct. In the marketplace, this is also where a vendor's free-form `attributes` are validated against the category's facet schema. So "no fixed column set" does not turn into "no contract".
5. **The handler.** An `async def` runs on the event loop. A plain `def` is dispatched to a worker thread pool, so it cannot block the event loop. This difference is the one line of code that matters most in an async service, and it is the subject of the next question.
6. **Response construction.** The return value is validated against `response_model`, serialized to JSON, and given a status and headers. `response_model` is not decoration. It is what stops a field that the handler happened to load from leaking into the response.
7. **Back out through the middleware**, and each layer sees the finished response. Then `send` writes the headers and the body back through the ASGI server to the ingress, the gateway and the client. That usually happens over a connection that is kept alive and reused.

**What I would add without being asked**, because it is what makes this debuggable in production. The `traceparent` header is extracted at the first middleware and propagated onward. That includes message headers when the handler publishes an event. Without that, a request that ends in a queue becomes two unconnected halves of one flow.

</details>


---

### PY-06. What belongs in a FastAPI dependency, what belongs in middleware, and what belongs in the handler itself — and how do you keep a dependency chain from becoming a hidden call graph nobody can follow?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Middleware is for anything that must apply to every request, whatever the route, and that needs the raw request or response. Examples are correlation ids, timing, compression and catch-all error shaping. Dependencies are for anything route-scoped that produces a typed value or enforces a precondition. Examples are authentication, tenant scope, the database session and pagination parameters. The handler is for the business decision and nothing else. The chain stays easy to follow when you keep it shallow and typed, and when you treat dependencies as *inputs*, not as a place to put side effects.

<details>
<summary><strong>Detailed answer</strong></summary>

**Middleware is the narrow case.** Middleware runs for every request, including 404s and validation failures. It sees the raw request and response. It cannot be applied selectively per route, and it cannot return a typed value. So it is right for these jobs: assigning and propagating `request_id` and trace context; request timing and metrics; response compression; security headers; and a final exception boundary that turns anything unhandled into a problem-detail body instead of a stack trace. It is wrong for authorization. The reason is that middleware has to pattern-match on paths to know what to enforce. A path-matching rule is a control that silently stops covering a route. That happens on the day someone adds a route under a prefix that the pattern missed.

**Dependencies are the default.** They are route-scoped, typed, testable and composable. They are declared in the signature, so they appear in the generated [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document. This is what lives here:

- **Authentication.** Decode and verify the token, and return a typed principal. Both systems validate locally against a cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), with no network call per request. The latency budget rests on that assumption.
- **Authorization preconditions.** Account type and scope. In the marketplace, `/v1/vendor/*` requires `act = vendor`, and a dependency on the router enforces it. So a retailer token cannot reach a vendor route, whatever its scopes are. Declaring the check on the router, not per endpoint, is the point. A new endpoint under that prefix inherits the check, and nobody has to remember to add it.
- **The database session**, with deterministic cleanup.
- **Parameter objects**, such as pagination cursors and filter models. Then validation is declarative, and it appears in the schema.
- **Tenant scope**, resolved once and attached to the repository layer.

**The handler.** The business decision, expressed against typed inputs. If a handler starts with fifteen lines that extract things from the request, those lines are dependencies that nobody has written yet.

**Keeping the chain easy to follow is the real question.** A deep dependency graph is genuinely hard to read. The signature shows one parameter, and behind it are six layers, each with its own side effects. These rules keep it manageable:

- **A depth of two or three, not six.** A dependency may depend on another dependency. A chain of five levels means the abstraction is wrong.
- **Dependencies return values. They do not change global state.** As soon as a dependency writes to `request.state` for another dependency to read, the graph stops being a graph and becomes implicit coupling. Now the order matters, and nothing declares it.
- **Type the return.** `current_user: Annotated[Principal, Depends(get_current_user)]` tells a reader what arrives, without opening the dependency. An untyped `dict` forces everyone to go and read the dependency.
- **One clear name per concern**, and the same dependency reused everywhere. Do not have three near-identical auth dependencies that drift apart. Three copies of an authorization decision are the defect, not the convention.
- **Router-level dependencies for invariants**, and endpoint-level dependencies for specifics. Then the invariant is visible in one place instead of being repeated thirty times, and nobody can forget it on the thirty-first endpoint.
- **No heavy or side-effecting work in a dependency.** Dependencies run before the handler, and they run on every request, including requests that will be rejected later. A dependency that makes a network call adds that latency to every request on the route. A dependency that writes makes a side effect happen for a request that may never be processed.
- **Read the generated OpenAPI document when in doubt.** Dependencies appear in it as parameters and security schemes, so the spec shows the chain. That makes it a genuinely useful review artefact. It is also one reason to prefer dependencies to middleware for anything a client needs to know about.

**The one exception I would make explicitly.** Cross-cutting concerns that have to apply to routes nobody has written yet are worth putting in middleware. Examples are the exception boundary and correlation ids. They belong there exactly because they should not be forgettable. When every other concern is a dependency, that concern is visible in the signature, and visible is better than implicit.

</details>


---

### PY-07. A dependency opens a database session and has to close it whatever happens. How do you write that, what does sub-dependency caching do within one request, and how do you override the whole chain in a test without touching real infrastructure?

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
A generator dependency with `try/finally`, or a context manager. Then the session closes on the normal path, on an exception and on a client disconnect. Within one request, FastAPI caches the result of each dependency by its callable, its security scopes and its `scope` setting. So every dependency that asks for the session gets the same session, and the request has a single transaction. In tests, `app.dependency_overrides` replaces the session provider at the top of the chain. Everything beneath it follows, without a single mock at the call sites.

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

The `finally` is the line that the whole pattern depends on. It runs on the happy path, on an exception raised in the handler, and when the client disconnects mid-request. Without it, a leaked session holds a pooled connection. Under load, the connection pool runs out, and every request blocks while it waits for a connection. That looks like a total hang, not an error. It is one of the harder failures to diagnose, because nothing has raised. Whether to commit in the dependency or in a unit-of-work object inside the handler is a real choice. Committing here keeps the request/transaction boundary in one place. The cost is that it commits work that the handler may not have considered final.

Two details are specific to this pattern. First, by default the code after `yield` runs *after the response has been sent*. So raising there cannot change the status code that the client already received. That includes a failed `session.commit()` in the dependency above: the client may already have a success response. Cleanup that must affect the response belongs before the yield, in an exception handler, or in a dependency declared with `scope="function"`, whose code after `yield` runs before the response is sent. Second, an `async def` session dependency must use an async driver and an async session. A synchronous session inside an async dependency blocks the event loop during every database call. That is the single most common way a FastAPI service becomes slow under concurrency for no obvious reason.

**Sub-dependency caching.** Within one request, FastAPI caches by the callable, its security scopes and its `scope` setting. So if `get_session` is required by `get_repository`, by `get_current_user` and by the handler itself, it is called once and all three receive the same object. That is what makes a request one transaction instead of three. It is also why a dependency with a side effect is dangerous. The side effect fires once per request, not once per declaration, and you can only reason about that if you know this rule. `Depends(fn, use_cache=False)` opts out where a fresh value is genuinely required. That is rare, and it is worth a comment when it happens.

The caching is per request, not global. A request-scoped cache of care-team membership is fine and correct. The cancer platform caches exactly that for the duration of the request. It also states that the membership never outlives one request, because a stale authorization fact is a disclosure, not a slow page.

**Overriding in tests.**

```python
app.dependency_overrides[get_session] = lambda: test_session
```

What makes this good is that the override happens at the *top* of the chain. Every dependency and every handler that asks for a session now receives the test session. There is no patching at the call sites, and there are no mock objects pretending to be a session. The same applies to `get_current_user`. Override it with a fixture principal, and every authorization dependency downstream works against a real token-shaped object.

**But what I would fake, and what I would not.** The override mechanism lets you replace the session with an in-memory SQLite session, and I would mostly refuse to do that. Both these projects run integration tests against real PostgreSQL, MongoDB and Redis in Docker Compose, at the pinned versions. The reason is that the things a mock passes while they are broken are exactly the interesting ones: [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") query plans, the projection pipeline, `ON CONFLICT` behaviour, partial index selection, row-level security policies, and how a real broker behaves under flow control. A test suite that only proves the Python is consistent with itself confirms whatever you already expected.

The override is worth using at the *edges*: a transaction rolled back per test for isolation, a fixture principal instead of minting real tokens, and a stubbed external provider so the suite does not send email. The rule I would state is this: fake what you do not own, and run what you do own.

</details>


---

### PY-08. The same data arrives over HTTP, from a broker, and from a bulk import. Where does validation belong?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
At every boundary where data enters the process, including the broker. A message is untrusted input, whatever the transport. What differs is the cost model. Validation per request costs nothing at request scale, but it is expensive at import scale. So the bulk path validates once at the edge and works with plain structures internally.

<details>
<summary><strong>Detailed answer</strong></summary>

**The rule: the boundary, not the transport.** It is tempting to treat a message from your own broker as trusted, because it came from inside the estate. But it is not trusted. It may have been published by an older version of a producer, by a device on a lossy connection, or by a producer whose schema changed. On the cancer platform, check-ins arrive from patient handsets over a publish-subscribe transport. They are validated against a typed model on the consumer side, for exactly that reason. A device is untrusted input, whatever protocol it speaks.

**What differs between the three paths.**

- **The request path.** Validate the whole body into a typed model. The cost does not matter at one body per request. The benefit is a structured error that names the field that caused the error, and that is what makes an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") usable.
- **The message path.** Validate the envelope into a typed model too. But the failure handling is completely different. A request can return a 400 to a caller who will fix it. A message has nobody to tell. So an invalid message must dead-letter after bounded attempts, and it must not be retried forever. The dead-letter queue has to be monitored, because a poison message that loops consumes capacity and looks like healthy throughput.
- **The bulk path.** Suppose a twenty-thousand-row import is validated as twenty thousand rich model instances at every stage. That is real cost for no additional safety. Validate each row once at the edge. Collect the failures instead of aborting on the first one. Then work with plain structures through the batching and writing stages. And the response has to be per row. A bulk operation that fails completely on one bad row is unusable, because the caller cannot make progress.

**What must never be skipped anywhere.** Anything that crosses a trust boundary, and anything where the field decides authorization or money. The types for those come from the model. The model is the same one wherever the data enters, so there is one definition, not three definitions that drift apart.

**Where validation must not live.** In a validator that queries the database. That turns parsing into an N+1. It also runs before any authorization has been applied, so it is also a way to probe whether a record exists. Cross-record checks belong in the service layer, after the caller's scope is known.

**And the response side.** A declared response model is not decoration. It is what stops an internal field leaking into an API response. That is a security property. It is the one reason I would keep response models on an endpoint whose input was already validated.

</details>


---

### PY-09. Explain how you manage a SQLAlchemy session's lifetime in a web application, and what goes wrong when you get it wrong.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
One session per request, opened and closed by a dependency. The transaction boundary is at the unit of work, not per statement. The failures are a session shared across concurrent requests, a session held open across a slow external call, and objects used after the session has closed.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape.** A session factory at application startup. A dependency that yields a session per request and closes it afterwards, including on an exception. And an explicit commit at the end of the successful path. Handlers do not commit individually. The request is the unit of work, so a partial write cannot survive a later failure in the same request.

**What goes wrong.**

- **A session shared between requests or tasks.** A session is not safe for concurrent use. A module-level session, or a session captured in a closure and reused, produces symptoms that look like data corruption. They are genuinely hard to trace, because two requests interleave on one connection.
- **Holding a transaction open across a slow call.** Suppose a handler opens a transaction, calls an external service, waits three hundred milliseconds and then writes. That handler has held a connection and a set of locks for the whole call. Under load, that exhausts the connection pool. It also creates lock contention that looks like a database problem. The transaction should be as short as the work that has to be atomic.
- **Access to a detached instance.** Touching an attribute that was not loaded before the session closed raises an error. The fix is to convert to the response model inside the request, and a response model does that for you anyway.
- **Lazy loading in a loop.** This is the classic N+1. If you set relationships to raise on lazy access, the N+1 becomes a loud error at development time, instead of a silent extra query per row in production. Under an async session it raises anyway, because implicit input/output on the event loop is not permitted. This is one of the rare cases where the runtime enforces the discipline for you.
- **`expire_on_commit` surprises.** By default, attributes that you access after a commit are fetched again. That is a hidden query at exactly the moment you thought you were done.

**Sessions outside the request.** A worker task creates its own session with its own lifetime. It does not inherit anything from a request context. Sharing an engine is fine, but sharing a session is not. Each task is its own unit of work, and that is also what makes retries safe.

**The one setting that is not about sessions, but always comes up with them.** The pool size per process, multiplied by the processes and the replicas, compared with the database's connection limit. That is the constraint that actually binds in production. If it is not calculated in advance, it is discovered during a spike.

</details>

---

## 3. Pools, sizing and concurrency diagnosis

---

### PY-10. How would you handle a database connection pool in a FastAPI application?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
One engine per process, created in the lifespan hook and disposed on shutdown. One session per request, handed out by a dependency with a `yield`, so teardown is guaranteed. And a pool size chosen so that the sum of every pod's maximum stays under the server's connection limit. That is arithmetic, not a default.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape that works.** The engine is a process-level object, and it owns the connection pool. So it is created once in the application's lifespan startup and disposed on shutdown. It is never created at module import. The reason is that import happens before the fork in some worker models, and any connection opened before the fork ends up shared by the child processes through their socket file descriptors. The session is per request, and a dependency produces it:

```python
async def get_session() -> AsyncIterator[AsyncSession]:
    async with session_factory() as session:
        yield session
```

The `yield` form is what makes closing unconditional. The connection returns to the pool whether the handler returned, raised, or the client disconnected mid-response. Nothing in the handler has to remember to do it.

**Sizing, which is the part people skip.** The constraint is global, not per pod. Azure Database for PostgreSQL Flexible Server has a connection limit that depends on its tier. PostgreSQL allocates a backend process per connection, so connections are genuinely expensive. In the marketplace, six services and three worker pools autoscale between three and eight nodes. So the sum of `pool_size + max_overflow` across every replica of every deployment has to stay below that ceiling. It also has to leave headroom for migrations, the outbox relay and an operator's psql session. A small pool per pod is enough exactly because the handlers are async and hold a connection only for the duration of the transaction.

**The settings that are worth using:**

- **`pool_pre_ping`** issues a cheap liveness check before it hands out a connection. Without it, the first request after a failover, or after an idle timeout has closed (reaped) the connection, fails with a stale socket. With it, the pool discards the connection and reopens it transparently.
- **`pool_recycle`** below the shortest idle timeout on any hop. That means the database's own idle timeout, plus the idle timeout of any load balancer or firewall between you and the database. The load balancer or firewall is usually the shorter one, and usually the one that surprises people.
- **A pool checkout timeout.** A request that cannot get a connection within a couple of seconds should fail fast with a `503`, not queue indefinitely. Unbounded queueing inside the pool is how a slow database becomes an unbounded latency spike.
- **`expire_on_commit=False`** on the async session. Then touching an attribute after commit does not trigger implicit input/output on a connection that has already been returned.

**Two traps specific to a pooler in front of the database.** PgBouncer in transaction mode does not keep a backend bound to a client between transactions, and that has two consequences. First, before PgBouncer 1.21, or with `max_prepared_statements` set to 0, prepared statements break, so `asyncpg` needs its statement cache disabled. Second, and more seriously, **anything set at session scope leaks between callers**. That is exactly why the cancer platform sets its row-level-security identity with `SET LOCAL` inside the request transaction. The cancer platform also asserts that with a pooled-connection leakage test. A plain `SET` there would hand one caller's identity to the next caller's query. It would turn the strongest control in that design into its exact opposite.

**And keep the workers separate.** Celery workers run their own engines with their own pools, and those pools are sized separately. The reason is that a bulk import doing long-running writes and a web tier doing 5 ms reads want different pool shapes. And they must not be able to starve each other.

</details>


---

### PY-11. Response times get worse under concurrency but the database looks idle. Walk me through the diagnosis.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
That combination almost always means that requests are queuing on something with a fixed width. That something is an event loop blocked by a synchronous call, a saturated thread pool, or an exhausted connection pool. The idle database is the clue: nothing is working, and everything is waiting.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the shape tells you.** Latency rises with concurrency while the downstream is idle. That means the bottleneck is in the process, and it is a queue, not slow work. There are three candidates, and you can tell them apart.

**1. A blocking call on the event loop.** The pattern is that every endpoint on that worker process degrades together, including trivial ones and the health check. Processor use is moderate, not at its maximum (pinned). To confirm it, enable the event loop's debug mode or an equivalent slow-callback warning. That warning names the coroutine that held the event loop. Common causes are a synchronous database driver in an async handler, a synchronous [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client, a lazy-loaded relationship that fires a query, and a large parse or crypto operation.

**2. A saturated thread pool.** If handlers are synchronous, concurrency is capped at the thread pool size, and request N+1 waits for a slot. The pattern is a hard plateau in throughput, with latency rising linearly beyond it. That is the textbook shape of a queue. To confirm it, compare in-flight requests against the configured thread pool size.

**3. Connection pool exhaustion.** Time is spent waiting to acquire a connection, not executing a query. That is exactly why the database looks idle. It has few active sessions, because the application cannot get to it. To confirm it, instrument pool wait time as its own metric, or look at pool checkout counts against the maximum. This one is easy to misdiagnose as a database problem. And the fix is often the opposite of what instinct says: fewer, better-used connections, not more.

**What I look at, in order.** First, a trace with spans for connection acquisition, query execution and outbound calls, because it separates waiting from working immediately. Then the in-flight request count against the concurrency limits. Then, if it is still unclear, a stack sample of the worker processes under load. A profiler that shows where threads actually are will show the whole pool waiting (parked) in the same place.

**What I would not do first.** Add replicas. If the constraint is per-process concurrency, more replicas help. If the constraint is the connection limit, more replicas make it strictly worse. And you have now changed two things while the graph is moving.

</details>


---

### PY-12. You inherit a synchronous FastAPI service that is slow under concurrency. What do you measure first, and which optimisations would you do before anyone mentions rewriting it as async?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Measure where the time goes before you change anything. That means request latency broken into its components by trace, worker and thread pool saturation, connection pool wait time, and the slow-query log. In my experience, the cause is almost never "it is synchronous". It is a pool with the wrong size, an N+1 query, a missing index, or a blocking call inside an `async def` route. All of those are cheaper to fix than a rewrite. And a rewrite that lands on top of them fixes nothing.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I measure, in order, and why in that order.**

1. **A distributed trace of a slow request, broken into its parts.** Time in the gateway, time queued before the handler, time in each database call, time in outbound calls, and time in serialization. This single artefact usually ends the debate. The reason is that "slow under concurrency" describes three completely different problems: queueing, contention and per-request cost. The trace tells them apart immediately.
2. **Queueing versus service time.** If per-request work is unchanged under load but total latency rises linearly with concurrency, the service is queueing. Then the fix is capacity or pool sizing. If the per-request work itself degrades, the problem is contention: locks, pool waits, or an overloaded database.
3. **Thread pool saturation.** For `def` routes, the `anyio` thread pool has 40 threads by default, and every `def` route and dependency shares it. If it is full, requests wait before they start, and the event loop looks idle the whole time.
4. **Connection pool wait time.** Threads waiting for a connection are invisible unless you instrument the wait. This is where a service with 40 threads and a pool of 5 spends most of its time.
5. **Worker process count versus cores.** A single Uvicorn worker on an eight-core node caps throughput at one core for anything processor-bound. That is free throughput, and it is frequently not used.
6. **The slow-query log and `pg_stat_statements`**, ordered by *total* time, not by mean. The query that takes 20 ms and runs 400 times per request is the problem. The 2-second report that runs hourly is not.
7. **Whether any `async def` route contains a blocking call.** One `requests` call or one synchronous driver call inside an `async def` stalls the event loop for every concurrent request. The pattern is low processor use, with everything slow at the same time, including the health check.

**The optimisations I would do first, roughly in order of value per unit of risk.**

- **Fix the N+1s.** They are almost always present, almost always the biggest single win, and completely independent of async. In the marketplace, this is the difference between hydrating thirty listings with one bulk `$in` and doing thirty round trips. Eager-load explicitly. The tracing view makes N+1s obvious, because you see thirty identical spans.
- **Size the pools coherently.** The thread pool, the connection pool and the worker count are one system, not three settings. The sum of every pod's pool maximum must stay under the server's connection limit. A thread pool larger than the connection pool just moves the queue.
- **Add the missing indexes, based on the plan and not on intuition**, and check that the planner uses them.
- **Move the blocking call out of the event loop.** Use `run_in_threadpool` around the part that blocks, not a rewrite of the route.
- **Take work off the request path entirely.** A request that sends an email, generates a thumbnail or re-indexes a document synchronously is doing work that the user is not waiting for. Both these systems push that work to a queue and return `202`. That is often a larger win than any tuning.
- **Cache the expensive read**, with a stated invalidation rule and stampede protection. Then the cache does not become its own incident when entries expire.
- **Add more workers or pods.** This is unfashionable and frequently correct. If the service is input/output-bound and the database has headroom, horizontal scale is cheaper than an engineering quarter.
- **Reduce payload size**: fewer fields, pagination limits, compression. Serialization of large response bodies takes real processor time, and it is easy to overlook.

**What I would say about the rewrite.** Async gains throughput when a process spends most of its time waiting on the network and the concurrency ceiling is the thread count. It gains nothing when the bottleneck is the database. And it makes things worse when a single blocking call remains anywhere in the path. In a codebase that is converted step by step, a blocking call will remain. A conversion also means an async driver, an async session, async-safe libraries, and re-testing every path. So it is a large change with a wide blast radius, on a system that is already under pressure.

So my position would be: measure, take the cheap wins, and measure again. If the profile after that shows threads waiting on the network with the database idle, then async is the right answer, and now there is evidence for it. This stack is explicitly a synchronous architecture under heavy enterprise load. So I would expect to be tuning the pool relationships and the query layer, not proposing a rewrite. And I would want the before-and-after numbers on the same graph either way, because "it feels faster" is not a result.

</details>


---

### PY-13. Why increasing the pool indefinitely can actually make the system worse?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Because a pool is not a throughput control. It is a queue whose length you can see. Past the point where the database is saturated, extra connections do not add capacity. They move the queue out of your application, where you can measure and shed it, and into the database. In the database, contention makes every query slower, and nobody is holding a timeout.

<details>
<summary><strong>Detailed answer</strong></summary>

**The database's own limits come first.** PostgreSQL forks a backend process per connection. Each process has its own memory and its own share of the shared structures. Beyond roughly the number of effective cores times a small factor, more concurrent active connections get no additional work done. They also cost real overhead: context switching, cache-line contention on shared buffers and the lock manager, and more processes competing for the same input/output queue. Throughput flattens and then bends downward, while latency climbs. That is a classic congestion curve. Adding connections past the knee of the curve is strictly negative.

**The queueing argument, which is the one I would start with.** Little's law says that concurrency equals arrival rate times the average time a request spends in the system (waiting plus service). If the database can serve 200 statements per second and 250 arrive, a queue forms. That is arithmetic, and no pool size changes it. What the pool size decides is *where* the queue forms. A bounded pool puts the queue in the application. There it has a name, a metric, a timeout and a shedding policy. A request that waits too long for a checkout gets a `503`, and the caller is told quickly. An unbounded pool puts the queue inside the database. There, 500 backends each make slow progress, the latency of every query has tripled, and there is no mechanism to reject anything. Backpressure has been removed, and backpressure is the feature.

**Three concrete ways a large pool makes an incident worse:**

- **It turns a slow dependency into a total outage.** With a small pool, a query that has become slow occupies a few connections, and the rest of the traffic still flows. With a huge pool, every arriving request takes a connection and joins the others that are waiting. So one bad query plan takes down everything the database serves.
- **It turns a failover into a connection storm.** When the primary comes back after a zone failover, every pod in every deployment tries to refill its pool at the same time. Hundreds of authentication handshakes arrive at a cold instance at once, and the instance goes down again. This is why the marketplace design names PgBouncer-style pooling with bounded reconnection specifically as the mitigation for the 60–120 s failover window.
- **It silently breaks the ceiling that is shared with everything else.** The limit is per server, not per service. A pool enlarged in one deployment starves the outbox relay, the migration job, and the operator who is trying to connect to diagnose the incident. And the symptom appears somewhere other than the change.

**So what do you do when the pool really is the bottleneck?** Prove it first. Pool wait time is a metric, and it is the only thing that separates "the pool is too small" from "the database is too slow". If pool wait time is near zero and query time is high, a bigger pool makes it worse. If pool wait time is high while the database is comfortably idle, the pool really is small. And even then, the ceiling is the server's limit divided by the replica count. Beyond that, the honest answers are fewer or cheaper queries, a read replica for the reads that tolerate staleness, a cache in front of the hot path, or a transaction-mode pooler that multiplexes many clients onto few backends. All of those add capacity. A bigger number does not.

</details>


---

### PY-14. How do you size workers, threads and connection pools for a deployed service, and which of those constraints actually binds?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Work backwards from the database's connection limit, because that is the constraint that binds in practice. Workers per pod, times connections per worker, times replicas, has to stay under that limit. Everything else, such as thread pool size and autoscaler bounds, is chosen inside that budget.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the database limit is the real ceiling.** Every other number is elastic. The autoscaler will add pods, each pod starts its workers, and each worker opens its pool. Nobody notices until a spike. At that point, the autoscaler starts pods that cannot connect. The failure then looks like a database problem, while every application dashboard is green. So the budget is computed first, and everything else is fitted to it.

**The arithmetic, and where people get it wrong.** Take the maximum pool size per worker, times workers per pod, times the maximum replica count. Then add the workers, the migration job, and any analytics or administrative client that shares the same instance. That last group is what is usually forgotten. It is also what uses up the headroom during an incident, when someone opens a session to look at something.

**What to do when the numbers do not fit.**

- **Shrink the per-pod pool instead of raising the limit.** A pod that serves async handlers genuinely needs a small pool, because connections are held only while a transaction is open. Generous pools per pod are a habit from synchronous deployments.
- **Put a pooler in front, in transaction mode**, which multiplexes many client connections onto few server connections. The caveat is important. Transaction-mode pooling breaks anything that relies on session state. That includes session-scoped settings used for authorization. Such a control becomes its exact opposite when one caller's identity survives into the next request's query.
- **Cap the autoscaler's maximum deliberately**, so that the scaling ceiling and the connection budget are one decision, not two.

**The thread pool.** In a service with any synchronous handlers, the thread pool size is the concurrency limit for those paths, and the thread pool consumes connections too. If the thread pool is too small, requests queue invisibly. If it is too large, threads contend for the interpreter, and the connection budget is exceeded. The size is derived, not left at the default.

**Workers per pod.** I prefer one, and the orchestrator owns the replica count. Two layers of scaling that do not know about each other are a bad combination. And one process per container makes the memory limit meaningful and the metrics attributable.

**And I instrument pool wait time as its own metric.** Time spent waiting to acquire a connection is invisible in query latency, and it is exactly what saturation looks like. Without that metric, the diagnosis is guesswork. With it, the diagnosis is a five-second answer.

</details>

