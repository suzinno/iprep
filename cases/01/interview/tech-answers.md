# Technical — Interview Answers

---

### Q1. Django, FastAPI, Flask — what's the difference when working with them. From the technical point and 'how to work with' point?

**Brief answer**
Django is a batteries-included framework with ORM, admin, and auth built in — best for conventional web apps. Flask is a minimal micro-framework where you pick every component yourself. FastAPI is built on Starlette and Pydantic, designed for async-first APIs with automatic OpenAPI docs and type-driven validation.

<details>
<summary><strong>Detailed answer</strong></summary>

**Django:**
- Comes with its own Object-Relational Mapping (ORM), admin panel, authentication system, form handling, template engine, and migration framework out of the box. You start productive immediately for standard web applications.
- Follows "convention over configuration" — there's a Django way to do things, and fighting it creates friction. This is a strength for teams (consistency) but a constraint when your architecture doesn't fit Django's assumptions.
- Synchronous by default. Django added async view support in 3.1+, but the ORM is still largely synchronous. Running async workloads requires careful handling with `sync_to_async` wrappers or switching to an async ORM.
- Best for: content-heavy apps, admin-driven systems, projects where rapid prototyping of CRUD operations matters, teams that benefit from strong conventions.

**Flask:**
- Truly minimal — gives you routing, request/response handling, and a Jinja2 template engine. Everything else (ORM, auth, validation, migrations) you bring yourself via extensions like Flask-SQLAlchemy, Flask-Login, Flask-Marshmallow.
- Maximum flexibility but maximum decision fatigue. Every project can look structurally different, which hurts onboarding and consistency across teams.
- Synchronous by default. Async support was added in Flask 2.0, but the ecosystem (extensions, middleware) is still predominantly sync.
- Best for: small services, prototypes, projects where you need full control over the stack, developers who prefer explicit wiring over framework magic.

**FastAPI:**
- Built on top of Starlette (async web framework) and Pydantic (data validation). Async is a first-class citizen — you write `async def` endpoints and get true concurrent I/O handling.
- Type hints drive everything: request validation, response serialization, and automatic OpenAPI/Swagger documentation. You define a Pydantic model and FastAPI handles parsing, validation, and doc generation from it.
- Dependency Injection (DI) is built into the framework via `Depends()`. This makes managing database sessions, auth, and service layers clean and testable without external DI containers.
- No built-in ORM or admin — you pair it with SQLAlchemy, Tortoise ORM, or similar. Migrations come from Alembic.
- Best for: API-first services, ML/AI serving (like our RAG pipeline), high-concurrency workloads, projects that benefit from strong typing and auto-generated docs.

**How I choose:** On our cancer support platform, we chose FastAPI because we needed async I/O for LLM API calls, type safety for healthcare data models, and clean dependency injection for layered architecture. If we'd been building a traditional CMS with an admin panel, Django would've been the obvious pick.

</details>

---

### Q2. Important aspect for FastAPI is concurrent execution by using async calls. How do you manage in the entire app the asynchronous calls starting from the endpoints, starting from the routers and to the DB? Is it easy to do out of the box or does it need some special arrangements in your code for FastAPI?

**Brief answer**
It requires deliberate setup — you need an async database driver, an async SQLAlchemy session, and consistent use of `async def` throughout the call stack. It's not fully "out of the box" because mixing sync and async code introduces subtle bugs and performance pitfalls.

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI's async support is excellent at the router level, but making the *entire stack* truly async requires attention at every layer:

**Router/endpoint level:** Straightforward — declare endpoints with `async def` instead of `def`. FastAPI runs `async def` endpoints on the event loop and `def` endpoints in a thread pool. The trap: if you declare `async def` but then call blocking (sync) code inside it, you block the entire event loop. So the decision of `async def` vs `def` must match what happens inside the function.

**Database layer — the main challenge:**
- SQLAlchemy 1.4+ introduced `AsyncSession` and `create_async_engine`, but you need an async-compatible database driver. For PostgreSQL, that means `asyncpg` instead of `psycopg2`. This is not a drop-in swap — connection strings change, and some driver-specific features differ.
- You configure `create_async_engine` and `async_sessionmaker`, then yield async sessions through FastAPI's `Depends()` system:
  ```python
  async def get_db() -> AsyncGenerator[AsyncSession, None]:
      async with async_session_factory() as session:
          yield session
  ```
- Lazy loading of relationships becomes a problem. In sync SQLAlchemy, accessing `user.posts` transparently fires a query. In async mode, this raises `MissingGreenlet` errors because implicit I/O can't happen on the event loop. You must use `selectinload()`, `joinedload()`, or explicit `await session.execute()` calls. This is probably the single biggest source of bugs when migrating to async SQLAlchemy.

**Service/domain layer:** All service methods that touch the database or call external APIs (like our LLM calls to Azure OpenAI) must be `async def`. This propagates upward — once your repository is async, your service must be async, and your router endpoint must be async. It's "async all the way down."

**External API calls:** Use `httpx.AsyncClient` instead of `requests` for calling external services. On our project, LangChain's async interfaces (`achain.ainvoke()`) were essential for non-blocking LLM calls.

**Special arrangements we made:**
- Configured connection pooling carefully on `create_async_engine` — async pools behave differently under concurrency than sync pools.
- Used `asyncio.gather()` for parallelizing independent I/O operations (e.g., fetching from Milvus and PostgreSQL simultaneously).
- Set up middleware to ensure each request gets its own session scope and that sessions are properly closed even on exceptions.

So to directly answer the question: it's not out of the box. The framework supports it well, but you need to make conscious, consistent choices at every layer. One blocking call in the wrong place silently degrades your entire application's throughput.

</details>

---

### Q3. Assume we decided to use FastAPI for RAG project with LLMs to be used.

#### Q3.1. How do you structure the project in the beginning? Focus on the FastAPI — how to structure (folders, modules).

**Brief answer**
I use a layered, domain-oriented structure: separate packages for API (routers), services (business logic), repositories (data access), models (SQLAlchemy), schemas (Pydantic), and a dedicated package for the RAG pipeline. Each domain concept gets its own module within these layers.

<details>
<summary><strong>Detailed answer</strong></summary>

Here's the structure I'd set up for a FastAPI RAG project, similar to what we used on the cancer support platform:

```
project-root/
├── app/
│   ├── __init__.py
│   ├── main.py                  # FastAPI app factory, middleware, lifespan
│   ├── config.py                # Settings via pydantic-settings
│   ├── api/
│   │   ├── __init__.py
│   │   ├── deps.py              # Shared dependencies (get_db, get_current_user)
│   │   ├── v1/
│   │   │   ├── __init__.py
│   │   │   ├── router.py        # Aggregates all v1 routers
│   │   │   ├── patients.py
│   │   │   ├── chat.py          # RAG conversation endpoints
│   │   │   └── documents.py     # Document upload/management
│   ├── services/
│   │   ├── __init__.py
│   │   ├── patient_service.py
│   │   ├── chat_service.py
│   │   └── document_service.py
│   ├── repositories/
│   │   ├── __init__.py
│   │   ├── patient_repo.py
│   │   └── document_repo.py
│   ├── models/
│   │   ├── __init__.py
│   │   ├── patient.py           # SQLAlchemy models
│   │   └── document.py
│   ├── schemas/
│   │   ├── __init__.py
│   │   ├── patient.py           # Pydantic request/response schemas
│   │   └── chat.py
│   ├── pipeline/
│   │   ├── __init__.py
│   │   ├── rag.py               # RAG chain orchestration
│   │   ├── embeddings.py        # Embedding generation
│   │   ├── vectorstore.py       # Milvus/vector DB client
│   │   ├── prompts.py           # Prompt templates
│   │   └── agents.py            # LangGraph agent definitions
│   └── core/
│       ├── __init__.py
│       ├── database.py          # Engine, session factory
│       ├── security.py          # Auth utilities
│       └── exceptions.py        # Custom exception handlers
├── migrations/                  # Alembic
│   ├── env.py
│   └── versions/
├── tests/
│   ├── unit/
│   ├── integration/
│   └── conftest.py
├── pyproject.toml
├── Dockerfile
└── docker-compose.yml
```

**Key principles behind this structure:**

- **Separation by layer, not by feature.** Each layer (api, services, repositories, models, schemas) is its own package. This makes dependency direction clear: routers → services → repositories → models. No layer skips.
- **Dedicated pipeline package.** The RAG/LLM logic lives in `pipeline/`, separate from the web layer. This is critical because the pipeline has its own dependencies (LangChain, vector store clients, embedding models) and its own testing strategy. It should be invocable independently of HTTP.
- **Schemas separate from models.** SQLAlchemy models define the database shape. Pydantic schemas define the API contract. Keeping them separate prevents leaking internal DB details into API responses and allows them to evolve independently.
- **Versioned API routers.** The `api/v1/` pattern allows introducing `v2/` without breaking existing clients.
- **Config via pydantic-settings.** All environment variables, API keys, and connection strings are validated at startup through a Pydantic `BaseSettings` class. Fail fast if config is missing.

</details>

#### Q3.2. How do you design the initial steps for having a FastAPI application? Including DB.

**Brief answer**
I start with: project scaffolding and dependency management (pyproject.toml), config via pydantic-settings, async database engine and session setup, Alembic for migrations, a health-check endpoint, and Docker Compose for local Postgres — all before writing any business logic.

<details>
<summary><strong>Detailed answer</strong></summary>

Here's my step-by-step for bootstrapping a FastAPI application with a database:

**Step 1 — Project and dependency setup.** Initialize with `pyproject.toml` (using Poetry or uv). Pin core dependencies: `fastapi`, `uvicorn`, `sqlalchemy[asyncio]`, `asyncpg`, `alembic`, `pydantic-settings`. Add dev dependencies: `pytest`, `pytest-asyncio`, `httpx` (for async test client), `ruff` (linting).

**Step 2 — Configuration.** Create a `config.py` with a Pydantic `BaseSettings` class that reads from environment variables:
```python
class Settings(BaseSettings):
    database_url: str
    redis_url: str
    openai_api_key: str
    model_config = SettingsConfigDict(env_file=".env")
```
This validates all required config at startup. If `DATABASE_URL` is missing, the app won't start — fail fast.

**Step 3 — Database setup.** Configure `create_async_engine` and `async_sessionmaker` in `core/database.py`. Define a `Base` declarative base for SQLAlchemy models. Write the first model (even a simple `User` or `Patient`). Set up the async session dependency for FastAPI's DI system.

**Step 4 — Alembic initialization.** Run `alembic init migrations`, configure `env.py` to use the async engine and import your models' metadata. Generate the first migration: `alembic revision --autogenerate -m "initial"`. Run it: `alembic upgrade head`. This establishes the migration workflow from day one — never create tables manually.

**Step 5 — App factory and lifespan.** In `main.py`, create the FastAPI app with a lifespan context manager that handles startup (verify DB connection, warm up caches) and shutdown (close connection pools, flush pending writes):
```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup
    yield
    # shutdown
    await engine.dispose()
```

**Step 6 — Health check and first router.** Add a `/health` endpoint that pings the database. This verifies the full stack works end-to-end before adding business logic. It also gives your load balancer and Kubernetes readiness probes something to hit.

**Step 7 — Docker Compose.** Create a `docker-compose.yml` with PostgreSQL (and Redis, Milvus if needed). Map ports, set environment variables, add a volume for data persistence. This ensures every developer on the team has an identical local environment.

**Step 8 — Tests.** Set up `conftest.py` with an async test client and a test database. Write one test that hits the health endpoint. This confirms the test infrastructure works before you start writing business logic.

On our cancer support platform, having this foundation solid from day one meant we never had to retrofit migrations, fix config loading bugs, or debug "it works on my machine" issues. The upfront investment pays for itself within the first week.

</details>

#### Q3.3. How do you design routers and entrypoint?

**Brief answer**
Routers are thin — they handle HTTP concerns (request parsing, status codes, response formatting) and delegate all business logic to the service layer via dependency injection. The entrypoint (`main.py`) assembles the app, mounts routers with prefixes and tags, and configures middleware.

<details>
<summary><strong>Detailed answer</strong></summary>

**Router design principles:**

A router should be "dumb" in terms of business logic. Its responsibilities are strictly:
1. Receive and validate the HTTP request (FastAPI + Pydantic handle this automatically)
2. Extract dependencies (DB session, current user, services) via `Depends()`
3. Call the appropriate service method
4. Return the response with the correct status code

Example:
```python
@router.post("/", status_code=status.HTTP_201_CREATED, response_model=PatientResponse)
async def create_patient(
    payload: PatientCreate,
    service: PatientService = Depends(get_patient_service),
    current_user: User = Depends(get_current_user),
):
    return await service.create(payload, created_by=current_user.id)
```

No database queries, no validation logic beyond what Pydantic provides, no business rules. If you see an `if` statement in a router that isn't about HTTP concerns, it probably belongs in the service layer.

**Router organization:** Group by domain resource, not by HTTP method. One file per resource (`patients.py`, `chat.py`, `documents.py`). Each file creates its own `APIRouter` with a prefix and tag:
```python
router = APIRouter(prefix="/patients", tags=["patients"])
```

**Aggregation:** A `v1/router.py` includes all domain routers:
```python
api_router = APIRouter(prefix="/api/v1")
api_router.include_router(patients.router)
api_router.include_router(chat.router)
```

**Entrypoint (`main.py`):** This is the composition root. It:
- Creates the FastAPI instance with metadata (title, version, description for the auto-generated docs)
- Registers the lifespan handler for startup/shutdown
- Mounts the aggregated router
- Adds middleware (CORS, request ID, logging, error handlers)
- Registers exception handlers that convert domain exceptions to proper HTTP responses

The entrypoint should read like a table of contents for the application — you should be able to open `main.py` and understand what the app does, what middleware is active, and where routes are defined, without reading any business logic.

On our project, this separation kept routers under 50 lines each. When the clinical team asked for a new endpoint, adding it was a matter of writing the service method and a thin router function — no risk of accidentally breaking other routes.

</details>

---

### Q4. Assume you already have separate layers for domain and for the services.

#### Q4.1. What is the best way (talking about FastAPI) of managing the dependencies? For the dependencies how to reach the loose coupling in all the code and really have good separation of concerns?

**Brief answer**
Use FastAPI's built-in `Depends()` system to inject services, repositories, and sessions. Define dependencies as factory functions that compose smaller dependencies, creating a chain that wires everything together without any layer knowing about the layers above it.

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI's Dependency Injection (DI) system via `Depends()` is the primary mechanism, and it's surprisingly powerful without needing external DI containers.

**The pattern:** Define factory functions that yield or return the dependency. Compose them by having higher-level factories depend on lower-level ones:

```python
# Database session — lowest level
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session

# Repository depends on session
async def get_patient_repo(db: AsyncSession = Depends(get_db)) -> PatientRepository:
    return PatientRepository(db)

# Service depends on repository
async def get_patient_service(
    repo: PatientRepository = Depends(get_patient_repo),
) -> PatientService:
    return PatientService(repo)
```

The router only sees `Depends(get_patient_service)`. It doesn't know or care that the service needs a repository, or that the repository needs a session. This is loose coupling — each layer depends on abstractions (or at least on the layer directly below it), not on concrete implementations two layers down.

**Achieving loose coupling:**

1. **Program to interfaces (protocols).** Define Python `Protocol` classes for repositories and services. The DI factories return the protocol type, not the concrete class. This lets you swap implementations (e.g., a mock repository for testing) without changing the router or service code.

2. **No imports across layer boundaries except downward.** Routers import from services (via DI), services import from repositories, repositories import from models. Never the reverse. Never skip layers.

3. **Configuration as a dependency.** Inject settings via `Depends()` too. This means services don't read environment variables directly — they receive config, making them testable without mocking `os.environ`.

4. **Scoping.** FastAPI's DI handles per-request scoping automatically. If multiple dependencies in the same request both depend on `get_db`, they get the same session instance. This is critical for transactional consistency.

**Why not a DI container (like `dependency-injector`)?** For most FastAPI projects, `Depends()` is sufficient and keeps things explicit. External DI containers add indirection that can make the codebase harder to navigate. I'd only reach for one if the dependency graph becomes very deep or if you need advanced features like singleton scoping across requests.

</details>

#### Q4.2. Does it make sense to have layering in a hierarchical manner? Doesn't it affect the code itself or maintainability?

**Brief answer**
Yes, hierarchical layering makes sense — the small cost of extra boilerplate is far outweighed by the clarity, testability, and enforced dependency direction it provides. The key is keeping layers thin so the hierarchy helps rather than hinders.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why hierarchical layering works:**

The standard layered architecture (Presentation → Service → Repository → Model) creates a clear, one-directional dependency flow. Each layer has a single responsibility:
- **Presentation (routers):** HTTP concerns — parsing, validation, status codes
- **Service:** Business logic, orchestration, transaction management
- **Repository:** Data access, query construction
- **Model:** Data shape and relationships

This hierarchy makes the codebase predictable. When debugging a business logic bug, you go to the service layer. When debugging a query issue, you go to the repository. New developers onboard faster because the pattern is consistent and well-known.

**The maintainability concern — and why it's manageable:**

The criticism is real: strict layering means a simple "get patient by ID" requires a router function → service method → repository method → SQLAlchemy query. That's boilerplate for trivial operations. But the trade-offs favor layering:

- **Testability.** You can test each layer in isolation. Service logic is tested without HTTP. Repository queries are tested without business rules. On our cancer support project, this meant we could verify RAG pipeline logic independently of the API.
- **Change isolation.** Switching from PostgreSQL to a different store means changing repositories, not services. Adding caching means wrapping repositories, not modifying routers. Swapping LLM providers means updating the pipeline service, not the chat endpoint.
- **Code review clarity.** PRs that touch a single layer are easy to review and reason about.

**When layering hurts:**

- If every layer is just passing data through without transformation, you've over-layered. A repository method that's literally `return await session.get(Patient, id)` wrapped by a service method that's literally `return await self.repo.get(id)` is boilerplate with no value. In these cases, I allow the service to use the session directly for simple reads — pragmatism over purity.
- If your service layer grows to hundreds of lines orchestrating many repositories, consider extracting domain services or use cases for specific operations.

The rule I follow: **layering should reduce cognitive load per file, not increase total file count for its own sake.** If a layer is doing meaningful work (validation, transformation, orchestration, abstraction), keep it. If it's pure pass-through, question whether it's earning its place.

</details>

#### Q4.3. Imagine we use dependency injection, we have good separation of concerns. How the layers should be structured and how should they call each other? Can the entrypoint directly have the dependency to the DB or how do you deal with that? Why do you have dependency to the DB session, but not to the repositories (on the presentation layer or on the routers)?

**Brief answer**
Routers should depend on services, not on the DB session or repositories directly. The reason the session appears in `Depends()` chains is that it's the infrastructure root — but it flows through repositories, not into routers. Routers seeing the session would bypass the service layer and break separation of concerns.

<details>
<summary><strong>Detailed answer</strong></summary>

**How layers should call each other:**

The rule is strict and one-directional:
```
Router → Service → Repository → Database
```

Each layer only knows about the layer directly below it. A router never imports a repository. A service never constructs HTTP responses. This is enforced through DI — the dependency chain is wired in `Depends()` functions, not through direct imports.

**Can the entrypoint (router) directly depend on the DB?**

Technically, yes — nothing in FastAPI prevents you from writing:
```python
@router.get("/patients/{id}")
async def get_patient(id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Patient).where(Patient.id == id))
    return result.scalar_one()
```

This works, but it's a design mistake for anything beyond a prototype. Here's why:

1. **Business logic leaks into the router.** The moment you need to add authorization ("can this user see this patient?"), data transformation, caching, or logging, that logic goes into the router. The router bloats, becomes hard to test, and mixes HTTP concerns with domain concerns.

2. **No reuse.** If a background task, a CLI command, or another service needs the same "get patient" logic, you can't reuse it — it's trapped inside an HTTP handler.

3. **Testing burden.** To test the query logic, you need to spin up a full HTTP test client. With proper layering, you test the repository with just a database session.

**Why does the session appear in `Depends()` but not in the router?**

The DB session is an *infrastructure dependency* — it's the lowest-level building block that repositories need. The `Depends()` chain wires it through:

```python
get_db → get_patient_repo(db) → get_patient_service(repo) → router
```

The router only sees `Depends(get_patient_service)`. The session is resolved internally by the DI chain. This is the beauty of FastAPI's `Depends()` — it lets you compose a deep dependency graph while keeping each level's interface clean.

**Why not inject repositories directly into routers?**

If routers depend on repositories, you skip the service layer. This means:
- Business logic (validation, authorization, orchestration of multiple repositories) has nowhere to live except the router
- If a single operation needs to coordinate two repositories (e.g., create a patient record AND log an audit event), the router becomes the orchestrator — a role it shouldn't have
- Transaction boundaries become ambiguous — who commits? The router? Each repository independently?

The service layer exists precisely to be the orchestrator: it receives repositories, coordinates operations, manages transactions, and returns domain results. The router's job is simply to translate between HTTP and the service interface.

</details>

---

### Q5. Let's assume we already created our FastAPI app and we want to use the RAG pipeline.

#### Q5.1. How do you integrate the pipeline? That could be an external LLM call over OpenAI or from Azure. How do you integrate it to your existing implementation? What components to consider?

**Brief answer**
Wrap the RAG pipeline in a service that the chat router depends on via DI. The key components are: an embedding service, a vector store client, a retrieval chain, a prompt template, and the LLM client — all configured through dependency injection and async-compatible.

<details>
<summary><strong>Detailed answer</strong></summary>

**Integration architecture:**

The RAG pipeline is treated as a service — it sits in the service layer (or a dedicated `pipeline/` package) and is injected into routers via `Depends()`, just like any other service. The router doesn't know or care how retrieval works internally.

**Components to consider:**

1. **LLM client.** Whether you use OpenAI directly or Azure OpenAI, wrap the client in a configuration-driven factory. Use `AzureChatOpenAI` or `ChatOpenAI` from LangChain, configured via your `Settings` class. This client should be async (`acall`/`ainvoke`) for non-blocking execution. On our project, we used Azure OpenAI, and switching between models (GPT-4, GPT-3.5-turbo) was just a config change.

2. **Embedding model.** You need an embedding model to convert user queries and documents into vectors. Use the same provider (Azure OpenAI embeddings) or a separate model. This runs at ingestion time (for documents) and query time (for user questions). Make it async.

3. **Vector store client.** The component that stores and retrieves embeddings. We used Milvus, connected via `langchain_milvus`. The vector store client handles similarity search, filtering by metadata (e.g., only retrieve documents relevant to a specific cancer type), and top-k configuration.

4. **Document ingestion pipeline.** A background process (or endpoint) that takes raw documents (PDFs, clinical notes), splits them into chunks using a text splitter (e.g., `RecursiveCharacterTextSplitter`), generates embeddings, and stores them in the vector store. This is separate from the query pipeline and typically runs asynchronously via Azure Functions or a background task.

5. **Retrieval chain.** The orchestration that ties query embedding → vector search → context assembly → prompt construction → LLM call → response parsing. With LangChain, this is a chain or a LangGraph graph. We used LangGraph for more complex flows (multi-turn conversations, conditional branching based on query intent).

6. **Prompt templates.** System prompts that instruct the LLM how to use the retrieved context. These should be versioned and stored in code (not hardcoded in chain definitions). Include instructions about citing sources, handling cases where context is insufficient, and maintaining the appropriate tone (critical for healthcare).

7. **Context and memory management.** For conversational agents, you need to manage chat history. We used Redis to store conversation context with TTL-based expiration. LangChain's memory abstractions (e.g., `ConversationBufferWindowMemory`) plug into this.

8. **Error handling and fallbacks.** LLM calls fail — rate limits, timeouts, content filtering. Implement retry logic with exponential backoff, fallback to a smaller model if the primary is unavailable, and graceful error messages to the user. Never let an LLM timeout crash your API.

9. **Streaming.** For better UX, stream LLM responses using FastAPI's `StreamingResponse` and LangChain's streaming callbacks. This is especially important for longer responses — users see tokens appear progressively instead of waiting for the full generation.

10. **Observability.** Log prompts, retrieved context, and responses (with PII redaction for healthcare). Set up latency tracking for each pipeline stage. On our project, Azure Monitor dashboards showed us where bottlenecks were — usually the LLM call, sometimes the vector search.

</details>

#### Q5.2. If you already use Postgres in your project, what will you choose, still Pinecone or an alternative?

**Brief answer**
If you already have Postgres, consider pgvector first — it adds vector similarity search directly to your existing database, eliminating the need for a separate vector store. I'd choose a dedicated vector DB like Milvus only when you outgrow pgvector's performance or need advanced features.

<details>
<summary><strong>Detailed answer</strong></summary>

**pgvector — the pragmatic default:**

pgvector is a PostgreSQL extension that adds vector data types and similarity search operators (cosine distance, L2, inner product) directly to Postgres. If you're already running Postgres, this is compelling:

- **No additional infrastructure.** No separate database to deploy, monitor, back up, and secure. Fewer moving parts means fewer failure modes.
- **Transactional consistency.** Your document metadata and embeddings live in the same database, in the same transaction. Insert a document, store its embedding, and update a status flag — all atomically. With a separate vector DB, you need to handle consistency between two systems.
- **Familiar tooling.** You query vectors with SQL. Your existing Alembic migrations manage the schema. Your existing monitoring covers it. Your team already knows Postgres.
- **LangChain integration.** `langchain_postgres` provides a `PGVector` class that plugs into LangChain's retriever interface seamlessly.

**When pgvector isn't enough:**

- **Scale.** pgvector uses IVFFlat or HNSW indexes. For millions of high-dimensional vectors, dedicated vector databases like Milvus are optimized with purpose-built indexing (IVF_PQ, DiskANN) and can handle larger scale more efficiently.
- **Advanced features.** Milvus and Pinecone offer features like hybrid search (combining vector similarity with keyword/BM25 search), built-in re-ranking, and multi-tenancy that pgvector doesn't natively support.
- **Query latency at scale.** For sub-10ms retrieval over 100M+ vectors, dedicated vector databases are tuned for this. pgvector on a standard Postgres instance will struggle.

**What we chose and why:**

On the cancer support platform, we used Milvus because we anticipated scaling to a large corpus of medical literature and needed metadata filtering (filter by cancer type, treatment phase, language) combined with vector similarity. But for a project starting out with tens of thousands of documents, I'd start with pgvector and migrate to a dedicated store only when benchmarks justify the operational complexity.

**My decision framework:**
- Under 1M vectors, moderate query volume → pgvector
- Over 1M vectors, need hybrid search, high QPS → Milvus, Qdrant, or Weaviate (self-hosted options) or Pinecone (managed)
- Healthcare/regulated data with residency requirements → self-hosted (Milvus, pgvector), not Pinecone (cloud-managed, data leaves your infrastructure)

</details>

#### Q5.3. Expand on LangChain usage in the pipeline.

**Brief answer**
LangChain provides the orchestration layer: document loading and splitting, embedding generation, vector store abstraction, retrieval strategies, prompt templates, chain composition, and output parsing. We used it as the glue connecting our vector store, LLM, and application logic into a coherent RAG pipeline.

<details>
<summary><strong>Detailed answer</strong></summary>

**How we used LangChain in the cancer support platform RAG pipeline:**

**Document loading and splitting.** LangChain's document loaders (`PyPDFLoader`, `TextLoader`, `UnstructuredLoader`) handle ingesting clinical documents in various formats. After loading, `RecursiveCharacterTextSplitter` breaks documents into chunks optimized for embedding. We tuned `chunk_size` and `chunk_overlap` parameters — too small and you lose context, too large and retrieval precision drops. For medical documents, we found ~500-800 token chunks with ~100 token overlap worked well.

**Embedding generation.** `AzureOpenAIEmbeddings` wraps the Azure OpenAI embedding API. LangChain abstracts the batching and rate limiting, so we pass in a list of texts and get vectors back. This abstraction also made it trivial to swap embedding models for experimentation (e.g., testing `text-embedding-3-large` vs `text-embedding-ada-002`).

**Vector store integration.** LangChain's vector store interface (`VectorStore`) provides a consistent API regardless of the backend. We used `Milvus` from `langchain_milvus`. The key methods — `add_documents()`, `similarity_search()`, `as_retriever()` — are the same whether you're using Milvus, pgvector, or FAISS. This abstraction is one of LangChain's strongest features because it makes the backend swappable.

**Retrieval strategies.** Beyond basic similarity search, we used:
- `MultiQueryRetriever` — generates multiple rephrasings of the user's question and retrieves for each, then deduplicates. This improves recall for ambiguous medical queries.
- Metadata filtering — the retriever filters by patient-relevant metadata (cancer type, treatment stage) before similarity ranking.
- Re-ranking — after initial retrieval, a secondary scoring pass prioritizes the most relevant chunks.

**Prompt templates.** LangChain's `ChatPromptTemplate` and `MessagesPlaceholder` structured our prompts:
```python
prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a medical information assistant. Use the following context to answer. "
               "If the context doesn't contain the answer, say so. Context: {context}"),
    MessagesPlaceholder("chat_history"),
    ("human", "{question}"),
])
```
Templates are versioned in code and parameterized — the system prompt for a newly diagnosed patient differs from one undergoing treatment.

**Chain composition with LangChain Expression Language (LCEL).** LCEL lets you pipe components together:
```python
chain = (
    {"context": retriever | format_docs, "question": RunnablePassthrough()}
    | prompt
    | llm
    | StrOutputParser()
)
```
This declarative style makes the data flow visible. Each step is independently testable and replaceable.

**LangGraph for complex flows.** For multi-step agent workflows (e.g., "classify the question intent → retrieve from appropriate source → generate response → check for safety"), we used LangGraph. It provides stateful graphs with conditional edges, which LangChain's simple chains can't express. LangGraph was essential for our conversational agents where the flow branched based on whether the user asked a factual question, reported a symptom, or requested appointment information.

**Where LangChain adds value vs. where it adds complexity:**
- **Value:** Abstractions over vector stores, embedding models, and LLM providers. These save significant boilerplate and make swapping components practical.
- **Complexity risk:** LangChain's abstractions can obscure what's happening. Debugging a chain failure requires understanding the internal data flow. We mitigated this with verbose logging at each chain step and by keeping chains short — if a chain has more than 4-5 steps, it's time to break it into sub-chains or move to LangGraph.

</details>

---

### Q6. Authentication in FastAPI apps.

#### Q6.1. How do you deal with it? How do you design it?

**Brief answer**
I use JWT-based authentication with FastAPI's dependency system — a `get_current_user` dependency that extracts and validates the token from the `Authorization` header, then injects the authenticated user into every protected endpoint.

<details>
<summary><strong>Detailed answer</strong></summary>

**Design approach:**

Authentication in FastAPI is implemented as a dependency that sits between the request and your business logic. The core pattern:

1. **Token-based auth with JSON Web Tokens (JWT).** The client authenticates (username/password, OAuth flow, etc.) and receives a JWT access token (and optionally a refresh token). Subsequent requests include the token in the `Authorization: Bearer <token>` header.

2. **The `get_current_user` dependency.** This is the central piece:
```python
async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
    user = await db.get(User, payload["sub"])
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user
```
`oauth2_scheme` is `OAuth2PasswordBearer(tokenUrl="/auth/token")`, which tells FastAPI where to find the token and generates the correct OpenAPI security scheme in the docs.

3. **Protecting endpoints.** Any endpoint that needs authentication simply adds the dependency:
```python
@router.get("/patients/me")
async def get_my_profile(current_user: User = Depends(get_current_user)):
    ...
```
Unauthenticated requests get a 401 before the endpoint function runs.

4. **Role-based access.** Build on top of `get_current_user`:
```python
def require_role(role: str):
    async def check(user: User = Depends(get_current_user)):
        if user.role != role:
            raise HTTPException(status_code=403, detail="Insufficient permissions")
        return user
    return check
```
Then use `Depends(require_role("clinician"))` on endpoints restricted to specific roles.

5. **Password hashing.** Use `passlib` with bcrypt for storing passwords. Never store plaintext. Hash on registration, verify on login.

6. **Token refresh.** Issue short-lived access tokens (15-30 minutes) and longer-lived refresh tokens (days/weeks). The refresh endpoint issues a new access token without requiring re-authentication. Store refresh tokens in the database so they can be revoked.

7. **Security headers and CORS.** Configure `CORSMiddleware` to restrict which origins can call your API. Set `httponly` and `secure` flags on cookies if using cookie-based token storage for browser clients.

On the cancer support platform, authentication was critical because we handled sensitive patient health information. We implemented role-based access so patients could only see their own data, clinicians could see their assigned patients, and admins had broader access. The `get_current_user` dependency was the single enforcement point — every protected endpoint went through it.

</details>

#### Q6.2. Let's assume you need SSO (Single Sign-On). How would you implement it?

**Brief answer**
Implement SSO using OAuth 2.0 / OpenID Connect (OIDC) with an identity provider like Azure Active Directory (Azure AD) or Okta. FastAPI acts as a relying party — it redirects users to the Identity Provider (IdP), receives an authorization code, exchanges it for tokens, and creates a local session.

<details>
<summary><strong>Detailed answer</strong></summary>

**Single Sign-On (SSO) implementation with OpenID Connect (OIDC):**

SSO means users authenticate once with a centralized Identity Provider (IdP) and get access to multiple applications without re-entering credentials. The standard protocol for this is OIDC, which is built on top of OAuth 2.0.

**The flow (Authorization Code Flow):**

1. User hits a protected endpoint → FastAPI redirects to the IdP's authorization endpoint (e.g., `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize`) with `client_id`, `redirect_uri`, `scope=openid profile email`, and a `state` parameter (for CSRF protection).

2. User authenticates with the IdP (enters credentials, MFA, etc.). The IdP redirects back to your `redirect_uri` with an authorization code.

3. FastAPI's callback endpoint exchanges the authorization code for tokens by calling the IdP's token endpoint (server-to-server, using `client_id` and `client_secret`). You receive an `id_token` (user identity), `access_token` (for API calls to the IdP), and optionally a `refresh_token`.

4. Validate the `id_token`: verify the JWT signature against the IdP's public keys (fetched from the JWKS endpoint), check `iss`, `aud`, `exp` claims. Extract user information (email, name, roles/groups).

5. Create or update the local user record. Map IdP claims to your user model. Issue your own JWT session token so subsequent requests don't require round-trips to the IdP.

**Implementation in FastAPI:**

Use the `authlib` library — it provides an OAuth/OIDC client that handles the flow:

```python
from authlib.integrations.starlette_client import OAuth

oauth = OAuth()
oauth.register(
    name="azure",
    client_id=settings.azure_client_id,
    client_secret=settings.azure_client_secret,
    server_metadata_url="https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile email"},
)

@router.get("/auth/login")
async def login(request: Request):
    redirect_uri = request.url_for("auth_callback")
    return await oauth.azure.authorize_redirect(request, redirect_uri)

@router.get("/auth/callback")
async def auth_callback(request: Request, db: AsyncSession = Depends(get_db)):
    token = await oauth.azure.authorize_access_token(request)
    user_info = token.get("userinfo")
    # Find or create local user from user_info
    # Issue your own JWT
    ...
```

**Key considerations:**

- **Group/role mapping.** Azure AD can include group memberships in the token claims. Map these to your application's roles (patient, clinician, admin). Configure this in the Azure AD app registration.
- **Token storage.** Store the IdP's refresh token securely if you need to make API calls on behalf of the user (e.g., reading their Microsoft calendar). Encrypt at rest.
- **Session management.** After SSO login, issue your own session token. Don't rely on the IdP for every request — that would add latency and a dependency on IdP availability.
- **Single Logout (SLO).** When the user logs out of your app, optionally redirect to the IdP's logout endpoint to end the SSO session across all applications.
- **Multi-tenant vs. single-tenant.** If your app serves multiple organizations, configure multi-tenant Azure AD and validate the `iss` claim to ensure the token came from an expected tenant.

On our cancer support platform, we used Azure AD for SSO because the healthcare organization already had Azure infrastructure. Clinicians logged in with their hospital credentials, and patients used a separate flow. The IdP handled MFA and password policies — we didn't have to build or maintain any of that.

</details>

---

### Q7. Python specifics.

#### Q7.1. Is it object-oriented or is it functional or procedural paradigm? How do you decide what to use and when? What is preferred and what are best practices?

**Brief answer**
Python is multi-paradigm — it supports object-oriented, functional, and procedural styles equally well. The best practice is to use the right paradigm for the situation: classes for stateful entities and complex domain models, functions for stateless transformations and utilities, and procedural style for scripts and glue code.

<details>
<summary><strong>Detailed answer</strong></summary>

Python doesn't force a paradigm — it gives you all three and lets you mix them. The skill is knowing when each fits:

**Object-Oriented Programming (OOP) — use when:**
- You have entities with both state and behavior (e.g., a `Patient` model with methods, a `RAGPipeline` class that holds configuration and exposes `query()` and `ingest()` methods)
- You need polymorphism — different implementations behind a common interface (e.g., `VectorStore` base class with `MilvusStore` and `PGVectorStore` implementations)
- You're building frameworks or libraries where extension via inheritance or composition is expected
- You need encapsulation — grouping related state and behavior so the internal representation can change without affecting consumers

In our FastAPI project, services and repositories were classes because they held dependencies (DB session, config) as instance state and exposed methods as the interface.

**Functional style — use when:**
- You're transforming data without side effects. Python's `map()`, `filter()`, list comprehensions, generators, and `functools` tools (especially `reduce`, `partial`) support this well.
- You're building data processing pipelines — chain pure functions that take input and produce output. LangChain's LCEL is essentially functional composition.
- You want composability and testability — pure functions are trivially testable (no setup, no mocks, just input → output).
- Decorators are a functional pattern that Python uses extensively (`@router.get`, `@cached_property`, `@retry`).

**Procedural — use when:**
- You're writing scripts, CLI tools, or glue code. A sequence of steps that runs top-to-bottom is the simplest correct solution.
- Alembic migrations are procedural — `op.add_column(...)`, `op.create_index(...)`. Wrapping them in classes would add complexity for no benefit.
- Simple utility modules with standalone functions (e.g., `format_date()`, `sanitize_input()`) are procedural and that's fine.

**Best practice:** Don't default to OOP because it feels "professional." Python's culture favors simplicity — a module-level function is preferred over a class with a single method. The Zen of Python applies: "Simple is better than complex." Use classes when they reduce complexity, not when they add ceremony.

**How I decide:** If the code has state that persists across calls → class. If it's a pure transformation → function. If it's a one-off script → procedural. Most real projects use all three — classes for the domain model and services, functions for utilities and transformations, procedural code for migrations and scripts.

</details>

#### Q7.2. What are the disadvantages of Python being object-oriented?

**Brief answer**
Python's OOP has no true encapsulation (no enforced private access), multiple inheritance creates complexity (diamond problem), there's runtime overhead from attribute lookups and dynamic dispatch, and the temptation to over-engineer with deep class hierarchies leads to unnecessary complexity.

<details>
<summary><strong>Detailed answer</strong></summary>

**1. No true encapsulation.** Python has no access modifiers like `private` or `protected` in the Java/C++ sense. The single underscore `_method` is a convention ("please don't use this"), and the double underscore `__method` triggers name mangling but can still be accessed via `_ClassName__method`. This means you can't enforce API boundaries at the language level — you rely on developer discipline and code review. In large teams or public libraries, this is a real risk because internal implementation details leak into consumer code.

**2. Multiple inheritance complexity.** Python supports multiple inheritance, which enables the diamond problem: if class D inherits from both B and C, and both B and C inherit from A, which version of A's method does D get? Python solves this with the Method Resolution Order (MRO) using C3 linearization, but the resolution can be surprising. Deep multiple inheritance hierarchies become hard to reason about and debug.

**3. Runtime overhead.** Python's OOP is dynamic. Every attribute access goes through `__getattribute__`, which checks the instance dict, then the class dict, then parent classes via MRO. Method calls involve creating bound method objects. This is significantly slower than static dispatch in compiled languages. For hot loops, this overhead matters — it's why performance-critical Python code often avoids OOP patterns in favor of NumPy arrays or C extensions.

**4. Over-engineering temptation.** Python's flexibility makes it easy to build elaborate class hierarchies, abstract base classes, mixins, and metaclasses when simpler constructs would suffice. A common antipattern: a class with only `__init__` and one method, which should just be a function. Or an abstract base class with one implementation, which adds indirection without polymorphism. The Python community's phrase "we're all consenting adults" cuts both ways — the freedom that enables elegant solutions also enables over-abstraction.

**5. `self` boilerplate.** Every instance method requires `self` as the first parameter. Every attribute access requires `self.`. This is verbose compared to languages with implicit `this`. It's a minor annoyance but adds visual noise, especially in data-heavy classes (though `dataclasses` and Pydantic mitigate this).

**6. Weak type enforcement on OOP constructs.** Python's `abc.ABC` provides abstract base classes, but there's no compile-time enforcement. You can instantiate a "concrete" class that forgets to implement an abstract method and only discover it at runtime. Type checkers like `mypy` catch this, but it's opt-in, not enforced.

</details>

> **Footnotes:**
> - **MRO (Method Resolution Order):** The algorithm Python uses to determine which method to call in a class hierarchy with multiple inheritance. Python uses C3 linearization, which guarantees a consistent, predictable order.
> - **C3 linearization:** The specific algorithm that produces the MRO. It preserves local precedence order (children before parents) and monotonicity (the order in a subclass is consistent with the order in parent classes).

#### Q7.3. How to deal with diamond inheritance problem (occurring from having multiple superclasses)? What kind of structures does Python provide to deal with such problems?

**Brief answer**
Python resolves the diamond problem using the MRO based on C3 linearization, and provides `super()` for cooperative multiple inheritance. To avoid the problem entirely, prefer composition over inheritance, use mixins for behavior reuse, or use abstract base classes and protocols for interface contracts.

<details>
<summary><strong>Detailed answer</strong></summary>

**The diamond problem illustrated:**

```python
class A:
    def method(self):
        return "A"

class B(A):
    def method(self):
        return "B"

class C(A):
    def method(self):
        return "C"

class D(B, C):
    pass

D().method()  # Returns "B" — but why?
```

**Python's built-in solution — MRO with C3 linearization:**

Python computes a deterministic Method Resolution Order for every class. For `D(B, C)`, the MRO is `D → B → C → A → object`. You can inspect it with `D.__mro__` or `D.mro()`. When `D().method()` is called, Python walks the MRO and uses the first class that defines `method` — in this case, `B`.

C3 linearization guarantees:
- Children come before parents
- The order of base classes in the class definition is preserved (B before C because `class D(B, C)`)
- If a consistent MRO can't be computed (conflicting orderings), Python raises a `TypeError` at class definition time — you catch the problem immediately, not at runtime.

**`super()` for cooperative inheritance:**

`super()` doesn't just call the parent class — it calls the *next class in the MRO*. This enables cooperative multiple inheritance where every class in the hierarchy calls `super()`, ensuring all implementations run:

```python
class B(A):
    def method(self):
        result = super().method()  # Calls C.method(), not A.method()!
        return f"B + {result}"

class C(A):
    def method(self):
        result = super().method()  # Calls A.method()
        return f"C + {result}"
```

This is powerful but surprising if you're not thinking about MRO. The rule: if you use multiple inheritance, *always* use `super()` and ensure every class in the chain calls `super()`.

**Structures to avoid the diamond problem entirely:**

1. **Composition over inheritance.** Instead of `class D(B, C)`, give D instances of B and C:
   ```python
   class D:
       def __init__(self):
           self.b = B()
           self.c = C()
   ```
   This is almost always cleaner. You delegate explicitly and there's no ambiguity.

2. **Mixins.** Small classes that provide a single behavior and don't define `__init__`. They're designed to be mixed in without creating deep hierarchies:
   ```python
   class LoggingMixin:
       def log(self, msg): ...

   class TimestampMixin:
       created_at: datetime = field(default_factory=datetime.utcnow)
   ```
   Mixins work well because they're orthogonal — they add behavior without overlapping with each other or the base class.

3. **Abstract Base Classes (ABCs) and Protocols.** Define interfaces without implementation. `abc.ABC` with `@abstractmethod` enforces that subclasses implement required methods. Python 3.8+ `Protocol` (from `typing`) enables structural subtyping — a class satisfies a Protocol if it has the right methods, without explicit inheritance. This is duck typing formalized.

**My preference:** In production code, I almost never use multiple inheritance beyond simple mixins. Composition gives you the same code reuse with explicit, debuggable wiring. On our FastAPI project, service classes used composition (receiving repositories via DI) rather than inheriting from multiple base classes.

</details>

#### Q7.4. Are there private methods in Python?

**Brief answer**
No, Python has no truly private methods. It has naming conventions: a single underscore prefix (`_method`) signals "internal, don't use from outside," and a double underscore prefix (`__method`) triggers name mangling — but neither enforces access restriction at the language level.

<details>
<summary><strong>Detailed answer</strong></summary>

**Single underscore `_method`:**
This is a convention that means "this is internal to this class/module, don't rely on it." Nothing in the language prevents external code from calling `obj._method()`. Python's philosophy is "we're all consenting adults" — the underscore is a communication signal to other developers, not an enforcement mechanism.

Some effects of the single underscore:
- `from module import *` will NOT import names starting with `_` (unless explicitly listed in `__all__`). This is the only place where `_` has actual language-level behavior.
- IDEs and linters (like ruff/pylint) will warn if external code accesses `_`-prefixed members.
- It's the standard used across the Python ecosystem. When you see `_`, respect it.

**Double underscore `__method` (name mangling):**
Python transforms `__method` into `_ClassName__method` at compile time. This prevents accidental name collisions in subclasses, not intentional access:

```python
class Parent:
    def __secret(self):
        return "parent secret"

class Child(Parent):
    def __secret(self):  # This is _Child__secret, not _Parent__secret
        return "child secret"

p = Parent()
p._Parent__secret()  # Still accessible — not truly private
```

Name mangling was designed to solve the fragile base class problem (a subclass accidentally overriding a parent's internal method), not to enforce encapsulation. It's a name collision prevention mechanism.

**Why Python doesn't have true privacy:**
It's a deliberate design choice aligned with Python's philosophy. Guido van Rossum argued that enforced privacy creates more problems than it solves — it forces workarounds (reflection, friend classes) and makes debugging harder. Python trusts developers to respect conventions.

**Practical implications:**
- Use `_method` for all internal methods. It's the Pythonic way.
- Use `__method` rarely — only when you specifically need to avoid name collisions in class hierarchies.
- If you need stronger contracts, use `Protocol` or `ABC` to define public interfaces explicitly. Consumers program to the interface, and internal methods remain undiscoverable through the interface type.
- For libraries, document the public API clearly. Everything not documented is implicitly internal.

</details>

#### Q7.5. SQLAlchemy and ORMs. How do you prefer to work with them — using directly mapped columns coming out of SQLAlchemy or something else like data classes, Pydantic?

**Brief answer**
I use SQLAlchemy models for the database layer and Pydantic models for the API layer, keeping them separate. SQLAlchemy handles persistence concerns (relationships, lazy loading, column types), while Pydantic handles validation, serialization, and the API contract.

<details>
<summary><strong>Detailed answer</strong></summary>

**My preferred approach — separate SQLAlchemy and Pydantic models:**

```python
# SQLAlchemy model — database concern
class Patient(Base):
    __tablename__ = "patients"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    diagnosis_code: Mapped[str] = mapped_column(String(10))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now())
    appointments: Mapped[list["Appointment"]] = relationship(back_populates="patient")

# Pydantic schemas — API concern
class PatientCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    diagnosis_code: str = Field(pattern=r"^[A-Z]\d{2}(\.\d{1,2})?$")

class PatientResponse(BaseModel):
    id: int
    name: str
    diagnosis_code: str
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)
```

**Why separate them:**

1. **Different responsibilities.** SQLAlchemy models define storage (column types, indexes, relationships, constraints). Pydantic models define the API contract (what fields to expose, validation rules, serialization format). These concerns evolve independently — you might add a database column that's never exposed in the API, or add a computed field to the response that doesn't exist in the database.

2. **Security.** If your SQLAlchemy model IS your response model, you risk leaking internal fields (password hashes, soft-delete flags, internal IDs). Separate Pydantic models let you explicitly choose what to expose.

3. **Validation flexibility.** Pydantic gives you rich validation: regex patterns, value ranges, custom validators, dependent field validation. SQLAlchemy's validation is limited to database-level constraints. For healthcare data (ICD codes, date ranges, required fields based on patient status), Pydantic's validation is essential.

4. **Multiple representations.** A single SQLAlchemy model often needs multiple Pydantic schemas: `PatientCreate` (input for creation), `PatientUpdate` (partial update), `PatientResponse` (full output), `PatientSummary` (list view with fewer fields). This is natural with separate schemas, awkward with a single model.

**`from_attributes=True` (formerly `orm_mode`):** This Pydantic config allows creating Pydantic models directly from SQLAlchemy instances: `PatientResponse.model_validate(db_patient)`. It bridges the two worlds cleanly — the service layer queries via SQLAlchemy, and the router serializes via Pydantic.

**What about dataclasses?** Python's `dataclasses` are lighter than both SQLAlchemy and Pydantic. I use them for internal domain objects that aren't persisted or serialized — DTOs between services, configuration objects, value types. But for database models and API schemas, SQLAlchemy and Pydantic are better suited because they're purpose-built for those roles.

**SQLAlchemy 2.0 style:** I use the modern `Mapped[]` annotation style (as shown above) rather than the legacy `Column()` style. It integrates better with type checkers and makes the code more readable. Combined with `mapped_column()`, you get type-safe ORM models that work well with `mypy`.

</details>

#### Q7.6. How do you deal with the validation in data classes?

**Brief answer**
Python's built-in `dataclasses` don't provide validation out of the box — you add it via `__post_init__`, descriptors, or by using Pydantic's `@dataclass` decorator instead. For anything beyond trivial validation, I prefer Pydantic `BaseModel` or `pydantic.dataclasses` over stdlib `dataclasses`.

<details>
<summary><strong>Detailed answer</strong></summary>

**The problem:** Standard library `dataclasses` are data containers with auto-generated `__init__`, `__repr__`, and `__eq__`. They don't validate anything — you can pass a string where an int is expected and it won't complain:

```python
@dataclass
class Patient:
    name: str
    age: int

Patient(name=123, age="not a number")  # No error — type hints are ignored at runtime
```

**Option 1 — `__post_init__` validation:**

```python
@dataclass
class Patient:
    name: str
    age: int

    def __post_init__(self):
        if not isinstance(self.name, str):
            raise TypeError("name must be a string")
        if not 0 <= self.age <= 150:
            raise ValueError("age must be between 0 and 150")
```

This works but is tedious. You write validation logic manually for every field. It doesn't scale well and there's no standard error format.

**Option 2 — Pydantic's `@dataclass` decorator:**

```python
from pydantic.dataclasses import dataclass

@dataclass
class Patient:
    name: str
    age: int = Field(ge=0, le=150)
```

Pydantic's `@dataclass` replaces stdlib's `@dataclass` and adds full Pydantic validation while keeping the dataclass interface. Type hints are enforced at runtime, `Field()` provides declarative constraints, and you get structured validation errors. This is the best of both worlds if you want dataclass syntax with Pydantic validation.

**Option 3 — `attrs` with validators:**

The `attrs` library predates dataclasses and has built-in validation support:

```python
import attrs

@attrs.define
class Patient:
    name: str = attrs.field(validator=attrs.validators.instance_of(str))
    age: int = attrs.field(validator=[
        attrs.validators.instance_of(int),
        attrs.validators.ge(0),
        attrs.validators.le(150),
    ])
```

`attrs` is more powerful than stdlib dataclasses (slots by default, validators, converters) but less feature-rich than Pydantic for serialization and parsing.

**My preference and when to use what:**

- **API boundaries (request/response models):** Pydantic `BaseModel`. Full validation, serialization, OpenAPI generation, `from_attributes` for ORM integration. This is non-negotiable in FastAPI.
- **Internal domain objects with validation:** Pydantic `@dataclass` — keeps the dataclass feel while adding validation. Use when the object isn't an API schema but still needs correctness guarantees.
- **Simple internal DTOs without validation needs:** Stdlib `@dataclass`. Lightweight, no dependencies, good enough when the data comes from trusted internal sources (already validated at the API boundary).
- **Configuration objects:** Pydantic `BaseSettings` — validates and parses environment variables with type coercion.

The key insight: validation should happen at system boundaries. If data enters through a Pydantic model at the API layer and flows through your services, internal dataclasses don't need to re-validate — the data is already clean. Add validation to internal objects only when they can be constructed from untrusted sources or when domain invariants must be enforced regardless of the caller.

</details>
