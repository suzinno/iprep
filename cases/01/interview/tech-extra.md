# Technical — Extended Questions & Answers
> Generated as a continuation of the original question set. Same interviewer style, new angles.

---

### Q8. Let's talk about testing in a FastAPI application with a RAG pipeline.

#### Q8.1. How do you structure your test suite? What kind of tests do you write and at what proportions?

**Brief answer**
I split tests into three layers: unit tests (pure logic, fast, majority of the suite), integration tests (hitting real DB and services), and a thin layer of end-to-end tests for critical user flows. For the RAG pipeline, I add evaluation-style tests that check retrieval quality, not just code correctness.

<details>
<summary><strong>Detailed answer</strong></summary>

The test structure mirrors the application layers, and the proportions follow the testing pyramid — though with a RAG-specific twist:

**Unit tests (~60% of the suite).** These cover service-layer logic, Pydantic schema validation, utility functions, and pipeline components in isolation. They use mocked repositories and mocked LLM clients so they run in milliseconds. For example, testing that the `ChatService` correctly formats a prompt from patient context and chat history — without actually calling Azure OpenAI. I use `pytest` with `pytest-asyncio` since most of our service methods are async.

**Integration tests (~30%).** These hit real infrastructure: PostgreSQL via a test database (spun up in Docker Compose or using testcontainers), actual Redis for caching tests, and Milvus for vector store integration. The key difference from unit tests is that these verify the *boundaries* — does the SQLAlchemy query actually return what the repository method promises? Does the async session lifecycle work correctly under concurrent requests? I use FastAPI's `TestClient` (or `httpx.AsyncClient`) to test full request-response cycles, including dependency injection, middleware, and error handling.

**End-to-end / smoke tests (~5-10%).** A small set that exercises the most critical flows: user authentication, patient data creation, and a full RAG query (embed → retrieve → generate). These are expensive to run and maintain, so I keep them focused on high-risk paths.

**RAG-specific evaluation tests.** This is where it diverges from standard web app testing. I maintain a curated set of question-context-expected-answer triples. These tests check retrieval precision (did we pull the right documents from Milvus?) and generation quality (is the answer grounded in the retrieved context?). They don't run in CI on every commit — they run on a schedule or before major pipeline changes — because they require actual LLM calls and are non-deterministic. We use metrics like Mean Reciprocal Rank (MRR) for retrieval and human-reviewed rubrics for generation quality.

**Test configuration:** `conftest.py` at the root handles shared fixtures: async test client, test database creation/teardown, test Redis instance, and factory functions for creating test data (patients, documents, embeddings). Each test module can override fixtures as needed.

The principle: unit tests give you speed and confidence in logic, integration tests give you confidence in boundaries, and RAG evaluation tests give you confidence in the AI component — which is the part most likely to degrade silently.

</details>

#### Q8.2. How do you test async endpoints? Any gotchas with pytest and async FastAPI?

**Brief answer**
Use `httpx.AsyncClient` with `pytest-asyncio`, configure async fixtures carefully, and watch out for event loop scoping — the biggest gotcha is tests sharing state through a single event loop or leaking database sessions between tests.

<details>
<summary><strong>Detailed answer</strong></summary>

Testing async FastAPI endpoints requires specific tooling and awareness of several pitfalls:

**Setup:** Use `httpx.AsyncClient` as the test client instead of FastAPI's sync `TestClient` when testing async behavior properly:

```python
@pytest_asyncio.fixture
async def client(app: FastAPI) -> AsyncGenerator[AsyncClient, None]:
    async with AsyncClient(app=app, base_url="http://test") as ac:
        yield ac
```

Tests are marked with `@pytest.mark.asyncio` and use `async def`.

**Gotcha 1 — Event loop scope.** By default, `pytest-asyncio` creates a new event loop per test function. If your fixtures create database connections or other async resources, they need to share the same loop. Configure `pytest-asyncio` with `scope="session"` or `scope="module"` for long-lived fixtures like the database engine. Mismatched loop scopes cause `RuntimeError: Event loop is closed` or `attached to a different loop` errors that are painful to debug.

**Gotcha 2 — Database session isolation.** Each test must get its own transaction that rolls back after the test completes. Otherwise tests pollute each other's data and you get flaky failures. The pattern I use: wrap each test in a transaction using `begin_nested()` (savepoint), run the test, then roll back. This is faster than recreating the database per test and guarantees isolation.

**Gotcha 3 — Dependency overrides.** To inject test-specific dependencies (like a test database session), use `app.dependency_overrides`. But remember to clear overrides after each test — if you don't, the override leaks into subsequent tests:

```python
app.dependency_overrides[get_db] = lambda: test_session
yield
app.dependency_overrides.clear()
```

**Gotcha 4 — Mocking async dependencies.** When mocking services or external API calls, you need `AsyncMock`, not regular `Mock`. A regular `Mock` returned from an `await` expression won't raise an error — it returns a coroutine silently, which can lead to tests that pass but don't actually test what you think they test.

**Gotcha 5 — Timeouts.** Async tests that accidentally block (e.g., a sync database call inside an `async def`) will hang forever unless you configure pytest timeouts. I add `timeout = 10` to `pytest.ini` for early detection.

On our project, getting the async test infrastructure right took about a day of setup, but it paid off immediately. Once the fixtures were solid, writing new async tests was as fast as writing sync ones.

</details>

#### Q8.3. How do you mock or test the LLM calls in your RAG pipeline without hitting the actual API every time?

**Brief answer**
I use dependency injection to swap the LLM client with a fake that returns deterministic responses. For integration-level RAG tests, I record real API responses and replay them. For evaluation, I do hit the real API but on a separate schedule.

<details>
<summary><strong>Detailed answer</strong></summary>

Testing LLM-dependent code has unique challenges: the API is expensive, rate-limited, slow, and non-deterministic. You need a layered strategy:

**Layer 1 — Unit tests with fakes.** The RAG pipeline components (retriever, prompt builder, response formatter) are designed to accept the LLM client as a dependency. In unit tests, I inject a fake client that returns pre-defined responses:

```python
class FakeLLM:
    async def ainvoke(self, prompt: str) -> str:
        return "This is a test response about treatment options."
```

This tests that the pipeline correctly constructs prompts, handles the response, formats the output, and manages context — everything except the actual generation quality.

**Layer 2 — Recorded responses (cassettes).** For integration tests that exercise the full chain (embed → retrieve → generate), I use response recording. The first run hits the real API and records the request-response pairs. Subsequent runs replay the recordings. Libraries like `vcrpy` or custom fixtures work for this. The recordings are committed to the test fixtures directory and updated explicitly when the pipeline changes.

**Layer 3 — Contract tests for the API boundary.** I write tests that verify our code handles the API's actual response shape correctly — including error responses (rate limits, content filtering, timeouts). These use mocked HTTP responses that match the real Azure OpenAI API response schema, ensuring that if the API changes its response format, our deserialization breaks in tests, not production.

**Layer 4 — Evaluation suite (real API, scheduled).** A separate test suite that runs nightly or before releases, hitting the actual LLM API with a curated set of patient questions. This checks retrieval quality, answer groundedness, and catches regressions in the pipeline's end-to-end behavior. Results are tracked over time so we can spot degradation trends.

**Why this layering matters:** Developers run layer 1 and 2 on every commit (fast, free, deterministic). Layer 3 runs in CI. Layer 4 runs on a schedule. This gives you fast feedback loops for code changes and periodic confidence checks for model behavior — without burning API budget on every `git push`.

The design principle that makes all of this possible: the LLM client is never instantiated inside the pipeline code. It's always injected. If your pipeline hard-codes `openai.ChatCompletion.create()`, you can't test it without hitting the API. Dependency injection is a testing strategy, not just an architecture pattern.

</details>

---

### Q9. Error handling and resilience. Assume your FastAPI app calls Azure OpenAI, Milvus, and PostgreSQL.

#### Q9.1. How do you design error handling across these external dependencies? What patterns do you use?

**Brief answer**
I use typed domain exceptions that each layer can raise, catch infrastructure errors at the boundary and translate them into domain exceptions, and apply the Circuit Breaker (CB) pattern for external API calls that can degrade. Global exception handlers in FastAPI map domain exceptions to proper HTTP responses.

<details>
<summary><strong>Detailed answer</strong></summary>

When your application depends on three external systems (Azure OpenAI, Milvus, PostgreSQL), each can fail independently and in different ways. The error handling strategy needs to be layered:

**1. Boundary-level exception translation.** Each infrastructure client (database repository, vector store client, LLM client) catches its own infrastructure exceptions and translates them into domain exceptions. The service layer never sees `asyncpg.ConnectionError` or `pymilvus.MilvusException` — it sees `DatabaseUnavailableError` or `VectorStoreError`. This keeps the service layer decoupled from infrastructure specifics.

```python
class VectorStoreError(DomainException): ...
class LLMServiceError(DomainException): ...
class LLMRateLimitError(LLMServiceError): ...

# In the vector store client
async def search(self, query_embedding):
    try:
        return await self.milvus_client.search(...)
    except MilvusException as e:
        raise VectorStoreError(f"Retrieval failed: {e}") from e
```

**2. Circuit Breaker for external APIs.** Azure OpenAI and Milvus are the most likely to experience transient failures. I implement a CB pattern — after N consecutive failures within a time window, the circuit "opens" and subsequent calls fail immediately instead of waiting for a timeout. This prevents cascading failures where a slow LLM response blocks all request threads. After a cooldown period, the circuit allows a trial request to check if the service has recovered. Libraries like `circuitbreaker` or a simple custom implementation work here.

> **Footnotes:**
> - **Circuit breaker:** A pattern that prevents cascading failures by cutting off calls to an unresponsive service after a threshold of failures, with automatic recovery attempts after a cooldown.

**3. Retry with exponential backoff.** For transient errors (network blips, rate limits), retry with increasing delays: 1s → 2s → 4s, with jitter to avoid thundering herd. But only retry on errors that are *likely transient* — retrying a 400 Bad Request is pointless. For Azure OpenAI rate limits (429 responses), I respect the `Retry-After` header.

**4. Graceful degradation.** If Milvus is down, the RAG pipeline can't retrieve context — but the app shouldn't return a 500 for every request. I designed fallback behavior: if retrieval fails, the conversational agent acknowledges it can't search the knowledge base right now and offers to help with what it can (appointment info, general guidance from cached data). Partial functionality beats total failure.

**5. Global exception handlers in FastAPI.** Custom exception handlers map domain exceptions to HTTP responses:

```python
@app.exception_handler(LLMRateLimitError)
async def handle_rate_limit(request, exc):
    return JSONResponse(status_code=503, content={"detail": "Service temporarily busy"})
```

This ensures consistent error response formats across the API, and no stack traces leak to the client.

**6. Structured logging at every boundary.** Every caught exception is logged with context: which service failed, what the request was, how long it took, whether it was retried. This feeds into Azure Monitor dashboards and makes incident investigation possible.

</details>

#### Q9.2. How do you handle timeouts specifically for LLM calls, which can be unpredictably slow?

**Brief answer**
I set aggressive per-call timeouts using `asyncio.wait_for()`, implement streaming for long-running generations, and design the UX to handle the inherent latency — showing progressive results rather than making the user wait for a complete response.

<details>
<summary><strong>Detailed answer</strong></summary>

LLM calls are the most unpredictable dependency in the stack. A typical Azure OpenAI call might take 2-15 seconds depending on prompt complexity, model load, and response length. Here's how I manage that:

**1. Per-call timeouts with `asyncio.wait_for()`.** Every LLM call is wrapped in an async timeout. If the call exceeds the threshold (say 30 seconds for a complex query), it raises `asyncio.TimeoutError`, which my error handling translates into a domain exception. The timeout is configurable per pipeline stage — embedding calls get a shorter timeout (5 seconds) than generation calls (30 seconds) because their expected latency profiles differ.

```python
try:
    response = await asyncio.wait_for(
        self.llm_client.ainvoke(prompt),
        timeout=settings.llm_timeout_seconds,
    )
except asyncio.TimeoutError:
    raise LLMTimeoutError("Generation timed out")
```

**2. Streaming responses.** For patient-facing chat endpoints, I use Server-Sent Events (SSE) to stream tokens as they're generated rather than waiting for the full response. This transforms a 10-second wait into an immediately visible, progressively building answer. FastAPI supports this via `StreamingResponse`:

```python
@router.post("/chat")
async def chat(query: ChatRequest, ...):
    return StreamingResponse(
        pipeline.astream(query),
        media_type="text/event-stream",
    )
```

LangChain and LangGraph both support async streaming natively via `.astream()` and `.astream_events()`, which fit cleanly into this pattern.

**3. Separate timeouts for the HTTP layer.** The overall request timeout (e.g., set by the load balancer or Azure API Management) must be longer than the LLM call timeout. If your load balancer times out at 30 seconds but your LLM call timeout is also 30 seconds, the load balancer may kill the connection before your timeout handler has a chance to return a graceful error. I set the HTTP-level timeout at 60 seconds, the LLM call timeout at 30 seconds, giving room for error handling and response formatting.

**4. Queue-based approach for heavy workloads.** For batch operations — like processing a large set of medical documents through the embedding pipeline — I don't use synchronous HTTP requests. Instead, I publish tasks to Azure Service Bus, process them asynchronously, and notify the client via webhook or polling endpoint. This decouples the caller from the LLM latency entirely.

**5. Monitoring LLM latency as a first-class metric.** I track p50, p95, and p99 latency for every LLM call type in Azure Monitor. When p95 starts creeping up, it's an early warning to investigate — model throttling, prompt bloat, or infrastructure issues — before users start seeing timeouts. Alerting on latency percentile shifts catches degradation before it becomes an outage.

</details>

---

### Q10. Database performance and migrations. You mentioned optimizing complex SQL on the project.

#### Q10.1. Walk me through your approach when you receive a report that a specific query is slow. What's your diagnostic process?

**Brief answer**
I start with `EXPLAIN ANALYZE` to see the actual execution plan, identify whether the issue is missing indexes, bad join order, or excessive row scanning, then fix the most impactful bottleneck first and verify with before/after metrics.

<details>
<summary><strong>Detailed answer</strong></summary>

When a slow query report comes in — typically flagged by Azure Monitor alerts or the clinical team noticing dashboard lag — I follow a consistent diagnostic process:

**Step 1 — Reproduce and measure.** Get the exact query (or the ORM-generated SQL via SQLAlchemy's `echo=True` or query logging). Run it against a representative dataset with `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` in PostgreSQL. This gives me the actual execution plan with real timings, not just estimates. I note the total execution time as the baseline.

**Step 2 — Read the execution plan bottom-up.** I look for the most expensive nodes: `Seq Scan` on large tables (missing index), `Nested Loop` with high row counts (bad join strategy), `Sort` with `external merge` (insufficient `work_mem`), or `Hash Join` spilling to disk. The plan tells you exactly where time is spent — not where you assume it is.

**Step 3 — Check index usage.** I cross-reference the plan with existing indexes using `\di` in psql and `pg_stat_user_indexes` to see which indexes are being used and which aren't. Common findings: missing composite index for a multi-column `WHERE` clause, index on the wrong column order, or an index that exists but is ignored because the query's filter doesn't match the index's leading column.

**Step 4 — Fix the most impactful issue.** Usually it's one of: adding a targeted index, rewriting a subquery as a `JOIN` (or vice versa), adding a `WHERE` clause to reduce the scan scope, or precomputing a frequently joined aggregate into a materialized view. I fix one thing at a time and re-run `EXPLAIN ANALYZE` to verify the improvement.

**Step 5 — Verify at the ORM level.** After fixing the SQL, I verify that the SQLAlchemy query in the application generates the optimized version. Sometimes ORM abstractions produce inefficient SQL — unnecessary subqueries, N+1 patterns from lazy loading, or missing `selectinload()` for relationships. If the ORM is the bottleneck, I either adjust the ORM query or drop to raw SQL via `text()` for that specific case.

**Step 6 — Monitor post-fix.** Deploy the fix and watch the query's latency in Azure Monitor for a few days. What's fast on staging might behave differently under production concurrency and data volume. I also check for unintended regressions — sometimes a new index speeds up reads but slows down writes.

On the cancer support platform, this process brought a patient history query from 12 seconds down to 200 milliseconds. The issue was a sequential scan on a 2M-row appointments table that needed a composite index on `(patient_id, appointment_date)`. The fix was one line, but finding the right line required the diagnostic process above.

</details>

#### Q10.2. How do you manage Alembic migrations in a team? Any strategies for avoiding migration conflicts?

**Brief answer**
Linear migration chains with clear naming conventions, a CI check that detects branching heads, and a team rule that migration files are never manually edited after merging — if you need to fix a migration, create a new one.

<details>
<summary><strong>Detailed answer</strong></summary>

Alembic migrations in a team setting are a frequent source of merge conflicts and deployment issues. Here's the strategy I used on our project:

**1. Naming conventions.** Every migration file gets a descriptive message: `alembic revision --autogenerate -m "add_treatment_phase_to_patients"`. The auto-generated hash prefix handles uniqueness, but the human-readable suffix makes it possible to understand migration history at a glance without reading each file.

**2. CI detection of branching heads.** Alembic supports a single-head migration chain. When two developers independently create migrations from the same head, you get a branch — and `alembic upgrade head` fails. I added a CI step that runs `alembic heads` and fails if more than one head exists. This catches branches before they reach the main branch. The developer whose PR comes second is responsible for rebasing their migration: `alembic merge heads -m "merge_migrations"` or re-generating from the updated head.

**3. Never edit merged migrations.** Once a migration is merged to main and has potentially been applied to any environment, it's immutable. If you need to modify a table that a previous migration created, create a new migration. Editing old migrations creates a divergence between the migration file and the actual database state in environments that already ran the original version.

**4. Down migrations ("downgrade").** I always implement the `downgrade()` function in each migration. Not every team does this, but on our project it was essential — when a deployment to staging revealed issues, we needed the ability to roll back the database schema cleanly. A migration without a downgrade is a one-way door.

**5. Data migrations vs. schema migrations.** I keep these separate. Schema migrations (add column, create table) are auto-generated and straightforward. Data migrations (backfill a new column, transform existing data) are written manually in their own migration files. Mixing the two makes the migration hard to understand and impossible to roll back cleanly.

**6. Squashing for fresh environments.** Over time, the migrations directory grows large. Periodically (every major release), I squash all migrations into a single initial migration for fresh environments while keeping the full history available in git. This speeds up test database creation and new developer onboarding. The `alembic stamp` command is useful here for marking existing databases as up-to-date with the squashed migration.

**7. Pre-deployment verification.** Before deploying, the CI pipeline runs `alembic upgrade head` against a copy of the production database schema (restored from a recent backup). This catches issues like adding a `NOT NULL` column without a default to a table with existing rows — something that Alembic's autogenerate won't warn you about but PostgreSQL will reject.

</details>

---

### Q11. Caching with Redis. You mentioned cache invalidation on the project.

#### Q11.1. What caching patterns did you use, and how did you decide what to cache versus what to always fetch fresh?

**Brief answer**
I cached read-heavy, write-infrequent data (patient profile snapshots, LLM responses for repeated queries) and always fetched fresh for write-heavy or real-time-critical data (prescription updates, appointment changes). The decision framework: cache when staleness is tolerable, skip when it's not.

<details>
<summary><strong>Detailed answer</strong></summary>

Caching decisions on a healthcare platform are more consequential than in most applications because stale data can affect patient care. Here's the framework I applied:

**What we cached:**

- **LLM responses for identical or near-identical queries.** If a patient asks "what are common side effects of chemotherapy?" and we've seen this exact prompt+context combination before, we serve the cached response. This dramatically reduced Azure OpenAI API costs and latency. The cache key was a hash of the full prompt (including retrieved context), so any change in the knowledge base for that patient naturally invalidated the cache.
- **Patient profile summaries.** These were composed from multiple database tables (demographics, diagnosis, treatment plan) and displayed on the dashboard. Since they changed infrequently (maybe once per appointment), caching with event-driven invalidation made sense.
- **Configuration and reference data.** Treatment type taxonomies, ICD codes, facility information — data that changes rarely and is read on nearly every request.

**What we never cached:**

- **Prescriptions and medication data.** Changes must be visible immediately. A patient seeing a stale prescription list could miss a new medication or take a discontinued one.
- **Appointment schedules.** Frequently updated and time-sensitive. Caching introduces risk of showing cancelled or rescheduled appointments incorrectly.
- **Authentication tokens and session data.** Security-critical data that must always reflect the current state (is this session still valid? has the user's role changed?).

**The decision framework:**

1. **How often is it read vs. written?** High read-to-write ratio = good cache candidate.
2. **What's the cost of staleness?** If stale data causes inconvenience, cache it. If it causes patient harm or security risk, don't.
3. **How expensive is the fresh fetch?** An LLM call costs time and money. A simple PostgreSQL query on an indexed table is fast and cheap — caching it adds complexity with minimal benefit.
4. **Can you invalidate reliably?** If you can't confidently detect when cached data is stale, don't cache it. Unreliable invalidation is worse than no caching.

**Implementation:** We used Redis with separate key namespaces for each data category, different Time-To-Live (TTL) values per category (5 minutes for profile summaries, 1 hour for reference data, 24 hours for LLM responses), and event-driven invalidation for the categories that needed immediate freshness upon writes.

</details>

#### Q11.2. Explain the event-driven cache invalidation you designed. How does it work end to end?

**Brief answer**
Database writes publish invalidation events to Azure Service Bus. Consumers listen for these events and delete the corresponding Redis cache keys. This decouples the write path from the cache, ensuring that cache invalidation is reliable without adding latency to the write operation itself.

<details>
<summary><strong>Detailed answer</strong></summary>

The event-driven invalidation flow works end to end as follows:

**1. Write operation triggers an event.** When a service method updates patient data (e.g., a new prescription is added), it publishes an invalidation event after the database transaction commits. The event contains the entity type and identifier:

```python
async def update_prescription(self, patient_id: int, data: PrescriptionUpdate):
    async with self.db.begin():
        await self.repo.update(patient_id, data)
    await self.event_bus.publish(
        CacheInvalidationEvent(entity="patient_profile", id=patient_id)
    )
```

Crucially, the event is published *after* the transaction commits, not inside it. If the transaction rolls back, no invalidation event is sent — which is correct, because the data didn't actually change.

**2. Azure Service Bus as the event transport.** Events are published to an Azure Service Bus topic. We chose Service Bus over simpler alternatives (like Redis Pub/Sub) because it guarantees delivery. If the cache invalidation consumer is temporarily down, messages queue up and are processed when it recovers. Redis Pub/Sub is fire-and-forget — if the subscriber misses a message, the cache stays stale indefinitely.

**3. Consumer processes invalidation.** A background worker (running as a separate process in the same AKS pod or as an Azure Function) subscribes to the invalidation topic and deletes the corresponding Redis keys:

```python
async def handle_invalidation(event: CacheInvalidationEvent):
    cache_key = f"{event.entity}:{event.id}"
    await redis.delete(cache_key)
    # Also delete derived keys
    pattern = f"{event.entity}:{event.id}:*"
    keys = await redis.keys(pattern)
    if keys:
        await redis.delete(*keys)
```

**4. Pattern-based key deletion.** A single patient profile update might invalidate multiple cache entries: the profile summary, the dashboard snapshot, and any cached LLM responses that included that patient's data as context. We used a hierarchical key naming scheme (`patient_profile:123`, `patient_profile:123:dashboard`, `llm_response:patient:123:*`) so that a single invalidation event could clean all related keys.

**5. Fallback TTL as a safety net.** Even with event-driven invalidation, every cache entry has a maximum TTL. If the invalidation event is somehow lost (Service Bus guarantees delivery but defense in depth matters in healthcare), the data expires naturally within a bounded time. The TTL is the upper bound on staleness, not the expected freshness.

**6. Monitoring.** We tracked cache hit rates, invalidation event lag (time between DB write and cache deletion), and cache miss rates in Azure Monitor. A sudden drop in hit rate or spike in miss rate indicated an invalidation problem. A growing lag indicated the consumer was falling behind, which we addressed by scaling the consumer or partitioning the topic.

This design kept the write path fast (just a single message publish, non-blocking), the cache consistently fresh for data that mattered, and the system resilient to temporary consumer outages.

</details>

---

### Q12. Docker, Kubernetes, and deployment. You worked with AKS on the project.

#### Q12.1. How do you write a Dockerfile for a FastAPI application? What optimizations matter?

**Brief answer**
Multi-stage build to keep the final image small, non-root user for security, layer caching by copying dependency files before application code, and a health check instruction. The goal is a minimal, secure, reproducible image.

<details>
<summary><strong>Detailed answer</strong></summary>

A production Dockerfile for a FastAPI application should optimize for image size, build speed (via layer caching), security, and reproducibility. Here's the approach I used:

**Multi-stage build.** The first stage installs dependencies (including build tools for compiling native extensions like `asyncpg`). The second stage copies only the installed packages and application code into a slim base image:

```dockerfile
# Build stage
FROM python:3.12-slim AS builder
WORKDIR /app
COPY pyproject.toml poetry.lock ./
RUN pip install poetry && poetry export -f requirements.txt -o requirements.txt
RUN pip install --prefix=/install -r requirements.txt

# Runtime stage
FROM python:3.12-slim
COPY --from=builder /install /usr/local
COPY ./app /app/app
```

This keeps the final image free of build tools (gcc, poetry, etc.), often reducing size from 1GB+ to 200-300MB.

**Layer caching for dependencies.** The `COPY pyproject.toml poetry.lock` step is separate from `COPY ./app`. Since dependencies change less frequently than application code, Docker caches the dependency installation layer and only rebuilds it when `pyproject.toml` or `poetry.lock` change. On our project, this turned a 3-minute build into a 20-second build for code-only changes.

**Non-root user.** The runtime stage creates and switches to a non-root user. If the container is compromised, the attacker has limited privileges:

```dockerfile
RUN useradd -m appuser
USER appuser
```

**Health check.** A `HEALTHCHECK` instruction tells the container runtime (Docker or Kubernetes) how to verify the application is healthy:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1
```

Though in Kubernetes, liveness and readiness probes in the pod spec are preferred over the Dockerfile `HEALTHCHECK` because they offer more control.

**Pinned base image.** Use a specific Python image tag (`python:3.12.4-slim`) rather than `python:3.12-slim` to ensure reproducible builds. Floating tags can introduce unexpected base image changes.

**`.dockerignore`.** Exclude `tests/`, `.git/`, `__pycache__/`, `.env`, and other non-essential files from the build context. This reduces context transfer time and prevents secrets from accidentally ending up in the image.

**Uvicorn configuration.** The `CMD` starts Uvicorn with appropriate settings: `uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 4`. The number of workers depends on the container's CPU allocation. For async FastAPI apps, fewer workers with more concurrent connections (Uvicorn's default async handling) is typically better than many workers.

</details>

#### Q12.2. How did you manage networking and service communication in AKS? What challenges did you face?

**Brief answer**
We used Kubernetes Services for internal communication, an NGINX ingress controller for external traffic, and Network Policies to restrict pod-to-pod communication. The main challenges were configuring TLS termination, debugging DNS resolution issues, and managing Azure-specific load balancer integration.

<details>
<summary><strong>Detailed answer</strong></summary>

AKS networking was one of the more operationally complex parts of the cancer support platform, because we had multiple services (FastAPI backend, React frontend, Milvus, Redis, background workers) that needed to communicate securely.

**Internal service communication.** Each service was exposed via a Kubernetes `ClusterIP` Service, giving it a stable internal DNS name (e.g., `fastapi-backend.default.svc.cluster.local`). Services communicated over HTTP internally because TLS termination happened at the ingress level. The FastAPI backend called Milvus and Redis using their internal service DNS names, configured via environment variables in the deployment manifests.

**Ingress controller.** We used an NGINX Ingress Controller to route external traffic. Path-based routing directed `/api/*` to the FastAPI backend and `/*` to the React frontend's static file server. This was configured via `Ingress` resources:

```yaml
rules:
  - host: app.example.com
    http:
      paths:
        - path: /api
          pathType: Prefix
          backend:
            service:
              name: fastapi-backend
              port:
                number: 8000
        - path: /
          pathType: Prefix
          backend:
            service:
              name: react-frontend
              port:
                number: 80
```

**TLS termination.** We used cert-manager with Let's Encrypt to automate TLS certificate provisioning. The ingress controller terminated TLS, so internal traffic was unencrypted — acceptable within the cluster's network boundary but something we documented explicitly for compliance reviews.

**Challenges we faced:**

**1. DNS resolution timing.** On pod startup, the FastAPI application sometimes tried to connect to Milvus or Redis before the DNS entries were available. This caused startup crashes in rapid scaling scenarios. The fix was implementing connection retry logic in the application's lifespan handler rather than relying on Kubernetes readiness probes alone.

**2. Azure Load Balancer integration.** AKS automatically provisions an Azure Load Balancer for `LoadBalancer`-type Services. But configuring it to work with our specific requirements (static IP, specific subnet, health probe paths) required Azure-specific annotations on the Service manifest. Debugging these was trial-and-error because the feedback loop was slow — you'd change an annotation, apply the manifest, and wait minutes for the load balancer to reconfigure.

**3. Network Policies.** We implemented Kubernetes Network Policies to enforce that only the FastAPI backend could talk to the database and Milvus — preventing accidental or malicious direct access from other pods. Getting these right required understanding Kubernetes networking at a lower level than most application developers are used to. A misconfigured policy silently drops packets, making it hard to distinguish from application bugs.

**4. Resource limits and Horizontal Pod Autoscaler (HPA).** Setting CPU and memory limits for the FastAPI pods required load testing to find the right values. Too low and pods got OOMKilled during RAG queries (which are memory-intensive). Too high and we wasted cluster resources. We used HPA to scale pods based on CPU utilization, with a minimum of 2 replicas for availability.

</details>

---

### Q13. CI/CD pipeline design. You configured pipelines using Azure DevOps and GitHub Actions.

#### Q13.1. Walk me through the CI/CD pipeline you set up. What stages did it have and why?

**Brief answer**
Four stages: lint and type-check, unit tests, build and push Docker image, deploy to staging (then manual promotion to production). Each stage gates the next — a failure in tests blocks the image build, preventing broken code from reaching any environment.

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline was implemented in GitHub Actions (for the main application) and Azure DevOps (for infrastructure and AKS deployments). Here's the structure and rationale:

**Stage 1 — Lint, format, and type-check.** Runs `ruff check`, `ruff format --check`, and `mypy` (or `pyright` for stricter typing in the pipeline modules). This stage catches style violations and obvious type errors in seconds, before any tests run. It's the cheapest gate and catches the most common issues. The pre-commit hooks catch these locally too, but CI is the enforcement point for anything that slips through.

**Stage 2 — Unit and integration tests.** Spins up a PostgreSQL container (using GitHub Actions services), runs `pytest` with coverage reporting. Unit tests run first (fast, fail-fast). Integration tests run after, hitting the test database. If coverage drops below our threshold (80% for the overall project, 90% for the pipeline module), the stage fails. This threshold prevented gradual test coverage erosion.

We also ran the Alembic migration check here: verify that `alembic heads` returns a single head, and that `alembic upgrade head` succeeds against a fresh database. This is the safeguard against the missing-migration incident I mentioned earlier.

**Stage 3 — Build and push Docker image.** Multi-stage Docker build, tagged with the git commit SHA and `latest`. Pushed to Azure Container Registry (ACR). This stage only runs if tests pass. The commit SHA tag ensures every deployment is traceable to an exact code state.

**Stage 4a — Deploy to staging.** Automatically triggered on merge to `main`. Uses `kubectl set image` or Helm to update the AKS staging deployment with the new image tag. After deployment, runs a smoke test suite that hits the staging `/health` endpoint and a few critical API routes to verify the deployment is functional.

**Stage 4b — Deploy to production.** Manual approval gate. A team lead reviews the staging deployment, verifies the smoke tests, and approves the production deployment. Same mechanism as staging but targeting the production AKS cluster. We never automated production deployments fully — the manual gate was a deliberate safety choice for a healthcare application.

**Why this structure:**

- **Fast feedback.** Linting takes 10 seconds, unit tests take 1-2 minutes. Most failures are caught within the first two minutes, before the expensive Docker build.
- **Immutable artifacts.** The Docker image built in stage 3 is the exact same image deployed to staging and production. No "build per environment" — the only difference is configuration via environment variables.
- **Traceability.** Every deployed image is tagged with its commit SHA. If production has an issue, I can instantly identify which code is running.
- **Rollback capability.** Previous images are retained in ACR. Rolling back is a `kubectl set image` with the previous SHA tag — under 30 seconds.

</details>

#### Q13.2. How did you debug a failing CI/CD pipeline? Give me an example.

**Brief answer**
The most common failure was the Docker build stage running out of memory during `pip install` with native extensions. I diagnosed it by reading the CI logs, identified the OOMKill signal, and fixed it by adding a swap file step and splitting the dependency installation into stages.

<details>
<summary><strong>Detailed answer</strong></summary>

One memorable debugging session involved our GitHub Actions pipeline consistently failing on the Docker build step, but only for certain branches. The error wasn't obvious — the build just stopped mid-way with `error: subprocess-exited-with-error` during `pip install asyncpg`.

**Step 1 — Read the actual logs.** The first instinct is to re-run and hope it's flaky. I resisted that and read the full log output. Deep in the build output, I found `signal: killed` during the compilation of `asyncpg`'s C extension. This is the OOMKiller — the GitHub Actions runner ran out of memory.

**Step 2 — Understand why it only failed on some branches.** The branches that failed had added new dependencies that increased the peak memory usage during `pip install`. The base image compilation of native extensions (`asyncpg`, `cryptography`, `numpy` for embedding utilities) all ran concurrently and their combined memory exceeded the runner's 7GB limit.

**Step 3 — Fix.** I applied two changes:
- Added `--no-build-isolation` to `pip install` for the heavy packages, which reduced memory overhead by reusing the build environment.
- Split the Dockerfile's dependency installation into two layers: first install the packages with native extensions individually (sequential compilation, lower peak memory), then install the remaining pure-Python packages.

```dockerfile
# Heavy native dependencies first (sequential, lower peak memory)
RUN pip install asyncpg==0.29.0 cryptography==42.0.0
# Then everything else
RUN pip install -r requirements.txt
```

**Step 4 — Verify.** I pushed the fix, watched the pipeline succeed, and then checked that the layer caching still worked correctly — the heavy-dependencies layer was cached unless those specific versions changed.

**Step 5 — Prevent recurrence.** I added a comment in the Dockerfile explaining why the dependencies are split and added a CI step that reports the Docker build's peak memory usage, so we'd get an early warning if we approached the limit again.

The general lesson: CI failures that aren't obviously test failures are usually resource issues (memory, disk, time) or environment issues (missing services, wrong versions). Reading the full log — not just the last error line — almost always reveals the root cause. On our project, I also set up Slack notifications for CI failures with direct links to the failed step's log, which reduced the time between failure and investigation.

</details>

---

### Q14. Observability. How do you monitor a FastAPI application in production?

#### Q14.1. What do you monitor and what tools do you use?

**Brief answer**
I monitor four pillars: request metrics (latency, error rates, throughput), application logs (structured JSON), infrastructure metrics (CPU, memory, pod health), and business metrics (RAG retrieval quality, cache hit rates). Azure Monitor and Application Insights were our primary tools.

<details>
<summary><strong>Detailed answer</strong></summary>

Monitoring a FastAPI application in production — especially one with LLM dependencies — requires layered observability:

**1. Request metrics (RED method).**
- **Rate:** requests per second per endpoint. Sudden drops indicate an outage; spikes indicate load.
- **Errors:** error rate per endpoint (4xx and 5xx separately). A rising 5xx rate is an immediate alert.
- **Duration:** p50, p95, p99 latency per endpoint. The RAG-backed chat endpoint naturally has higher latency than CRUD endpoints, so each endpoint gets its own baseline and alerting threshold.

I instrumented these using middleware that records timing and status code for every request, exported to Azure Application Insights via the OpenTelemetry SDK.

**2. Structured application logs.** All logs are JSON-formatted with consistent fields: `timestamp`, `level`, `request_id`, `user_id`, `endpoint`, `message`, and any relevant context. Structured logs enable querying in Azure Monitor Log Analytics: "show me all ERROR logs for the `/chat` endpoint in the last hour where `user_id` is X." This is transformatively faster than grepping through unstructured text.

**3. Infrastructure metrics.** AKS provides pod-level CPU, memory, and network metrics through Azure Monitor for Containers. Key alerts: pod restarts (usually OOMKill), CPU throttling (indicates resource limits are too tight), and node-level resource pressure. Horizontal Pod Autoscaler (HPA) metrics are also tracked — if the HPA is constantly at max replicas, we need to either optimize the application or increase the autoscaling ceiling.

**4. Dependency health.** Dedicated health checks and metrics for each external dependency:
- **PostgreSQL:** connection pool usage, query latency, active connections.
- **Redis:** hit/miss ratio, memory usage, eviction rate.
- **Milvus:** search latency, index build status.
- **Azure OpenAI:** call latency, error rate, token usage (for cost tracking).

Each dependency has its own dashboard panel and alert threshold.

**5. Business metrics (RAG-specific).**
- Retrieval precision: what percentage of retrieved documents are relevant to the query?
- Fallback rate: how often does the system fail to retrieve context and fall back to a generic response?
- User satisfaction proxies: does the user ask a follow-up question (suggesting the answer was incomplete) or end the conversation (suggesting it was sufficient)?

These aren't traditional APM metrics, but they're the most important indicators for whether the RAG pipeline is actually serving patients well.

**Tooling:** Azure Application Insights (request tracing, dependency tracking), Azure Monitor Log Analytics (log querying), Azure Monitor Alerts (threshold-based and anomaly-based alerting), Grafana dashboards (for the team's day-to-day monitoring — more customizable than the Azure portal). The OpenTelemetry (OTel) SDK was the instrumentation layer, which kept us vendor-agnostic in the application code.

</details>

#### Q14.2. How do you trace a request end-to-end through the RAG pipeline when debugging a production issue?

**Brief answer**
Distributed tracing with correlation IDs. Every request gets a unique ID that propagates through the FastAPI handler, service layer, vector store query, LLM call, and database queries. I use OpenTelemetry spans to track each stage's timing and context, viewable in Application Insights as a single trace.

<details>
<summary><strong>Detailed answer</strong></summary>

End-to-end tracing through a RAG pipeline is essential because a single user query touches multiple systems: FastAPI → service layer → Milvus (retrieval) → prompt construction → Azure OpenAI (generation) → response formatting → cache write. When something goes wrong, you need to pinpoint which stage failed or degraded.

**Implementation:**

**1. Correlation ID generation.** Middleware assigns a unique `request_id` (UUID) to every incoming request and adds it to the response headers. This ID is stored in a `ContextVar` so it's accessible throughout the async call stack without explicit parameter passing:

```python
request_id_ctx: ContextVar[str] = ContextVar("request_id")

@app.middleware("http")
async def add_request_id(request: Request, call_next):
    rid = request.headers.get("X-Request-ID", str(uuid4()))
    token = request_id_ctx.set(rid)
    response = await call_next(request)
    response.headers["X-Request-ID"] = rid
    request_id_ctx.reset(token)
    return response
```

**2. OpenTelemetry spans for each pipeline stage.** I create child spans for each significant operation:

```python
with tracer.start_as_current_span("rag.retrieve") as span:
    span.set_attribute("query_length", len(query))
    documents = await vectorstore.similarity_search(query_embedding, k=5)
    span.set_attribute("documents_retrieved", len(documents))

with tracer.start_as_current_span("rag.generate") as span:
    span.set_attribute("prompt_tokens", count_tokens(prompt))
    response = await llm.ainvoke(prompt)
    span.set_attribute("response_tokens", count_tokens(response))
```

Each span records its start time, end time, and custom attributes (query length, number of documents retrieved, token counts, etc.). These spans are nested under the parent HTTP request span.

**3. Propagation to external services.** The OpenTelemetry SDK automatically propagates trace context in HTTP headers when calling external services. For Azure OpenAI calls via `httpx`, the trace context is included so that Application Insights can correlate our application's span with Azure's internal processing metrics.

**4. Debugging workflow.** When a patient reports a bad answer or a slow response, I:
1. Get the `request_id` from the response headers or logs.
2. Search Application Insights for that trace ID.
3. View the full trace waterfall: HTTP request → service → Milvus search (200ms) → prompt construction (5ms) → LLM call (8 seconds) → response formatting (2ms).
4. Identify the bottleneck immediately. In this example, the LLM call took 8 seconds — was it a large prompt? Model throttling? I check the span attributes for token counts and the LLM's response headers for rate limit information.

**5. Logging with trace context.** Every log line includes the `request_id` and current span ID. This means I can search logs filtered by a specific trace, seeing all debug output from every layer for that one request. Combined with the span waterfall, this gives me both the timing view and the detailed execution context.

On our project, this tracing setup was what made the difference between "the chat is slow sometimes" (useless) and "request abc-123 took 12 seconds because the Milvus search returned 0 documents, causing the LLM to generate a response without context, which triggered a retry" (actionable). Observability isn't overhead — it's the foundation of being able to operate a production system confidently.

</details>

