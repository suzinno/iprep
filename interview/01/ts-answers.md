# Technical — Interview Answers

---

### Q1. Django, FastAPI, Flask — what's the difference when working with them? From the technical point and "how to work with" point.

**Brief answer**
Django is a batteries-included framework with ORM, admin, and auth built in. Flask is a micro-framework where you pick your own components. FastAPI is async-first, built on type hints and Pydantic, and auto-generates OpenAPI docs. Choose based on project needs: Django for full-stack web apps, Flask for simple services, FastAPI for high-performance APIs.

<details>
<summary><strong>Detailed answer</strong></summary>

**Django:**
- Ships with its own Object-Relational Mapping (ORM), authentication system, admin panel, form handling, template engine, and migration framework. You get a working app scaffold out of the box.
- Follows the "convention over configuration" philosophy. Project structure is opinionated: apps, models, views, urls, serializers (with Django REST Framework (DRF) for APIs).
- Synchronous by default, though Django 4.1+ added async view support. The ORM is still largely synchronous — truly async database access requires workarounds or third-party libraries.
- Best for: full-stack web applications, content-heavy sites, projects where you want admin panels and auth without building them yourself. Startups that need to move fast on a traditional web app.
- Working with it: you learn "the Django way." The framework makes decisions for you, which is productive until you need to deviate — then you fight the framework.

**Flask:**
- Micro-framework: gives you routing, request/response handling, and a template engine (Jinja2). Everything else — ORM, auth, validation, migrations — you add yourself.
- Extremely flexible. No opinions about project structure, database layer, or anything else. This is both its strength (freedom) and weakness (decision fatigue, inconsistency across projects).
- Synchronous by default. Async support exists (Flask 2.0+) but the ecosystem is largely sync.
- Best for: small to medium APIs, microservices, prototypes, or projects where you need full control over the stack.
- Working with it: you'll typically pair it with SQLAlchemy for ORM, Marshmallow or Pydantic for serialization/validation, and Flask-Migrate (Alembic wrapper) for migrations. You assemble your own stack.

**FastAPI:**
- Built on top of Starlette (ASGI framework) and Pydantic. Async-first — designed from the ground up for `async`/`await`.
- Type hints are not optional decoration — they drive request validation, response serialization, and OpenAPI schema generation. You define a Pydantic model, use it as a function parameter, and FastAPI handles parsing, validation, and documentation automatically.
- Auto-generates interactive API documentation (Swagger UI and ReDoc) from your code. No separate spec maintenance.
- Dependency injection (DI) system is built in and central to how you structure the app. You declare dependencies as function parameters and FastAPI resolves them.
- Best for: high-performance APIs, async workloads (LLM calls, external API integrations), projects where you want strong typing and automatic docs.
- Working with it: you need to understand Python type hints, Pydantic, and async programming. The learning curve is steeper than Flask but the payoff is significant for API-heavy projects.

**Key technical differences at a glance:**

| Aspect | Django | Flask | FastAPI |
|--------|--------|-------|---------|
| Async support | Partial (views only) | Partial | Native, full stack |
| Validation | Forms / DRF serializers | Manual / Marshmallow | Pydantic (built-in) |
| ORM | Django ORM (built-in) | Bring your own | Bring your own (typically SQLAlchemy) |
| API docs | DRF + drf-spectacular | Manual / Flask-RESTX | Auto-generated |
| DI system | None (middleware-based) | None | Built-in |
| Performance | Good | Good | Excellent (async + Starlette) |

The choice is not about which is "best" — it's about which fits the project's constraints. If I'm building a RAG API service with async LLM calls, FastAPI is the natural choice. If I'm building an internal tool with user management and an admin panel, Django saves weeks.

</details>

---

### Q2. Important aspect for FastAPI is concurrent execution by using async calls. How do you manage asynchronous calls in the entire app — from endpoints, routers, to the DB? Is it easy out of the box or does it need special arrangements?

**Brief answer**
It requires deliberate setup throughout the entire stack. Your endpoints must be `async def`, your database driver must be async (e.g., asyncpg), SQLAlchemy must use `AsyncSession` and `create_async_engine`, and you must avoid blocking calls in the async event loop.

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI makes async *possible* out of the box, but making it work correctly across the whole application requires careful setup at every layer.

**Endpoints and routers:**
- Define route handlers as `async def` instead of `def`. If you use plain `def`, FastAPI runs the handler in a thread pool — it still works, but you lose the concurrency benefits.
- All I/O operations inside an `async def` handler must themselves be awaitable. If you call a synchronous blocking function (like `requests.get()` or a sync ORM query) inside an `async def`, you block the event loop and kill concurrency for all other requests.

**Database layer — the critical piece:**

This is where most people get it wrong. You need:

1. **An async database driver.** For PostgreSQL, that's `asyncpg` (not `psycopg2`). For MySQL, `aiomysql`. The standard sync drivers will block the event loop.

2. **SQLAlchemy async engine and session:**
   ```python
   from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
   engine = create_async_engine("postgresql+asyncpg://...")
   ```
   The connection string uses the `+asyncpg` dialect prefix.

3. **AsyncSession throughout.** Every database operation goes through `AsyncSession`. You `await` queries:
   ```python
   result = await session.execute(select(User).where(User.id == user_id))
   ```

4. **Session lifecycle management** via FastAPI's dependency injection:
   ```python
   async def get_db() -> AsyncGenerator[AsyncSession, None]:
       async with async_session_factory() as session:
           yield session
   ```
   This ensures each request gets its own session and it's properly closed after the request.

**Special arrangements needed:**

- **Lazy loading is a trap.** SQLAlchemy's lazy loading (accessing `user.posts` triggers a query) is synchronous by nature. In async mode, this raises an error. You must use eager loading (`selectinload`, `joinedload`) or explicit queries. This is the single biggest pain point when migrating from sync to async SQLAlchemy.

- **Alembic migrations** remain synchronous — that's fine, migrations run at deploy time, not at request time. But you'll need a separate sync engine for Alembic's `env.py`.

- **Background tasks and blocking calls.** If you must call a synchronous library (e.g., a CPU-heavy computation, a library without async support), use `run_in_executor` to offload it to a thread pool:
  ```python
  import asyncio
  result = await asyncio.get_event_loop().run_in_executor(None, sync_function, args)
  ```
  Or use FastAPI's `BackgroundTasks` for fire-and-forget work.

- **Connection pooling** matters more in async mode. With sync code, each thread holds one connection. With async, a single event loop can fire many concurrent queries, so you need to tune `pool_size` and `max_overflow` on the async engine to avoid exhausting database connections.

**Bottom line:** async FastAPI is not "add `async` keyword and you're done." It requires an async-aware stack from top to bottom. The payoff is genuine concurrency — a single worker process can handle hundreds of concurrent I/O-bound requests (like LLM API calls) without threading overhead. But if any layer in the stack is synchronous, you lose that benefit for every request that touches that layer.

</details>

---

### Q3. Assume we decided to use FastAPI for a RAG project with LLMs.

#### Q3.1. How do you structure the project in the beginning? Focus on FastAPI — how to structure (folders, modules).

**Brief answer**
I use a layered, domain-oriented structure: separate packages for API routes, services (business logic), repositories (data access), models (SQLAlchemy), schemas (Pydantic), and a dedicated package for the RAG pipeline. Core configuration lives at the root level.

<details>
<summary><strong>Detailed answer</strong></summary>

Here's the concrete folder structure I'd start with for a FastAPI RAG project:

```
project-root/
├── app/
│   ├── __init__.py
│   ├── main.py              # FastAPI app factory, lifespan events, middleware
│   ├── config.py             # Settings via pydantic-settings (env vars)
│   ├── dependencies.py       # Shared DI providers (db session, current user)
│   │
│   ├── api/                  # Presentation layer — only routing, no logic
│   │   ├── __init__.py
│   │   ├── v1/
│   │   │   ├── __init__.py
│   │   │   ├── router.py     # Aggregates all v1 routers
│   │   │   ├── search.py     # Search/query endpoints
│   │   │   ├── documents.py  # Document upload/management
│   │   │   └── auth.py       # Auth endpoints
│   │   └── deps.py           # API-layer specific dependencies
│   │
│   ├── services/             # Business logic layer
│   │   ├── __init__.py
│   │   ├── search_service.py
│   │   ├── document_service.py
│   │   └── auth_service.py
│   │
│   ├── repositories/         # Data access layer
│   │   ├── __init__.py
│   │   ├── document_repo.py
│   │   └── user_repo.py
│   │
│   ├── models/               # SQLAlchemy ORM models
│   │   ├── __init__.py
│   │   ├── base.py           # Declarative base, common mixins
│   │   ├── document.py
│   │   └── user.py
│   │
│   ├── schemas/              # Pydantic models (request/response DTOs)
│   │   ├── __init__.py
│   │   ├── search.py
│   │   ├── document.py
│   │   └── user.py
│   │
│   ├── rag/                  # RAG pipeline — isolated domain
│   │   ├── __init__.py
│   │   ├── pipeline.py       # Orchestrates retrieve → augment → generate
│   │   ├── embeddings.py     # Embedding generation (OpenAI, local models)
│   │   ├── retriever.py      # Vector search logic
│   │   ├── chunking.py       # Document splitting strategies
│   │   └── prompts.py        # Prompt templates
│   │
│   └── db/
│       ├── __init__.py
│       ├── session.py        # Async engine, session factory
│       └── migrations/       # Alembic
│           ├── env.py
│           └── versions/
│
├── tests/
├── alembic.ini
├── pyproject.toml
└── .env
```

**Key principles behind this structure:**

- **Separation by layer, not by feature.** Routes in `api/`, logic in `services/`, data access in `repositories/`. This makes dependencies flow one direction: `api → services → repositories → models`. No layer skips.

- **RAG as its own package.** The RAG pipeline is a distinct domain with its own concerns (chunking, embedding, retrieval, generation). It doesn't belong inside `services/` because it has sub-components that would clutter the service layer. Services call into `rag/`, not the other way around.

- **Schemas separate from models.** SQLAlchemy models (`models/`) represent database tables. Pydantic schemas (`schemas/`) represent API contracts. They look similar but serve different purposes and change for different reasons. Coupling them leads to leaking database details into your API.

- **Versioned API routes.** The `v1/` folder allows you to introduce `v2/` later without breaking existing clients. The versioned router aggregates sub-routers.

- **Configuration via pydantic-settings.** One `config.py` file reads environment variables with type validation and defaults. No scattered `os.getenv()` calls.

This structure scales well. For a small project, some folders might have just one file — that's fine. The structure guides where new code goes as the project grows.

</details>

#### Q3.2. How do you design the initial steps for having a FastAPI application? Including DB.

**Brief answer**
I start with: project scaffolding → config and environment setup → async database engine and session → base SQLAlchemy model and first migration → health-check endpoint → a working test that hits the real database. Only then do I build features.

<details>
<summary><strong>Detailed answer</strong></summary>

Here's my step-by-step process for bootstrapping a FastAPI application from zero:

**Step 1 — Project scaffolding and dependencies**

Initialize with `pyproject.toml` (using Poetry or uv). Install core dependencies:
- `fastapi`, `uvicorn[standard]` — web framework and ASGI server
- `sqlalchemy[asyncio]`, `asyncpg` — async ORM and Postgres driver
- `alembic` — migrations
- `pydantic-settings` — configuration management
- `pytest`, `pytest-asyncio`, `httpx` — testing

**Step 2 — Configuration**

Create `config.py` using Pydantic's `BaseSettings`. This reads from `.env` and validates types:
```python
class Settings(BaseSettings):
    database_url: str
    debug: bool = False
    openai_api_key: str = ""
    model_config = SettingsConfigDict(env_file=".env")
```
One source of truth for all configuration. Every component receives settings via dependency injection, not by importing a global.

**Step 3 — Database engine and session**

Set up the async engine and session factory in `db/session.py`:
```python
engine = create_async_engine(settings.database_url, pool_size=10, max_overflow=20)
async_session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
```

Create a dependency that yields a session per request:
```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session
```

**Step 4 — Base model and first migration**

Define a `Base` declarative model with common fields (id, created_at, updated_at). Create the first SQLAlchemy model (even a simple `Document` table). Initialize Alembic with `alembic init`, configure `env.py` for async, and generate the first migration with `alembic revision --autogenerate`.

Run the migration against a local Postgres instance to verify everything connects.

**Step 5 — App factory and health check**

In `main.py`, create the FastAPI app with a lifespan handler that manages the database engine lifecycle (creates on startup, disposes on shutdown). Add a `GET /health` endpoint that queries the database (`SELECT 1`) to verify connectivity. This is your smoke test.

**Step 6 — First working test**

Write a test using `httpx.AsyncClient` with the `app` directly (no separate server needed). The test hits `/health` and asserts a 200 response. Use a test database — either a separate Postgres database or a transactional test that rolls back after each test.

**Why this order matters:**

You now have a running app with a verified database connection, configuration management, and a test. Every subsequent feature builds on this foundation. If you skip the database setup and jump to building endpoints, you'll end up with route handlers that can't actually persist data, and you'll retrofit the database layer under pressure.

</details>

#### Q3.3. How do you design routers and the entrypoint?

**Brief answer**
Routers are thin — they handle HTTP concerns (request parsing, status codes, response shaping) and delegate all logic to services. The entrypoint (`main.py`) creates the app, registers middleware, includes versioned routers, and manages lifecycle events.

<details>
<summary><strong>Detailed answer</strong></summary>

**Router design principles:**

A router (endpoint handler) should do exactly three things:
1. Receive and validate the request (FastAPI + Pydantic handle this automatically)
2. Call a service method with the validated data
3. Return the response with the appropriate status code

```python
@router.post("/documents", status_code=status.HTTP_201_CREATED, response_model=DocumentResponse)
async def upload_document(
    payload: DocumentCreate,
    service: DocumentService = Depends(get_document_service),
    current_user: User = Depends(get_current_user),
):
    document = await service.create_document(payload, current_user)
    return document
```

Notice what's NOT in the router: no database queries, no business logic, no direct LLM calls. The router doesn't know how documents are stored or what happens during creation. That's the service's job.

**Router organization:**

- One file per resource or domain area: `documents.py`, `search.py`, `auth.py`
- Each file creates its own `APIRouter` with a prefix and tags:
  ```python
  router = APIRouter(prefix="/documents", tags=["documents"])
  ```
- A parent `router.py` in the version folder aggregates them:
  ```python
  api_router = APIRouter(prefix="/v1")
  api_router.include_router(documents.router)
  api_router.include_router(search.router)
  api_router.include_router(auth.router)
  ```

**Entrypoint design (`main.py`):**

The entrypoint is the composition root — it wires everything together but contains no business logic:

```python
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: initialize resources
    await init_db_engine()
    yield
    # Shutdown: clean up
    await dispose_db_engine()

app = FastAPI(
    title="RAG API",
    version="1.0.0",
    lifespan=lifespan,
)

# Middleware
app.add_middleware(CORSMiddleware, allow_origins=settings.allowed_origins, ...)

# Routers
app.include_router(api_router)
app.include_router(health_router)
```

**Key design decisions:**

- **Lifespan over `on_event`:** Use the `lifespan` context manager (FastAPI 0.93+) instead of the deprecated `@app.on_event("startup")` decorator. It's cleaner, testable, and handles cleanup reliably.
- **No logic in `main.py`.** If you find yourself importing repository classes or writing query logic here, something has gone wrong. The entrypoint only composes; it doesn't compute.
- **Error handlers** are registered at the app level for consistent error response formats across all routes:
  ```python
  @app.exception_handler(DomainException)
  async def domain_exception_handler(request, exc):
      return JSONResponse(status_code=exc.status_code, content={"detail": exc.message})
  ```

This separation means you can test routers independently (mock the service), test services independently (mock the repository), and the entrypoint is just the wiring that connects them.

</details>

---

### Q4. Assume you already have separate layers for domain and for the services.

#### Q4.1. What is the best way (in FastAPI) of managing dependencies? How to achieve loose coupling and good separation of concerns?

**Brief answer**
Use FastAPI's built-in `Depends()` system for dependency injection (DI). Define interfaces (protocols or abstract base classes), inject implementations via `Depends`, and ensure each layer only depends on abstractions of the layer below it — never on concrete classes or layers above it.

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI's dependency injection system is the primary tool for managing dependencies and achieving loose coupling. Here's how to use it effectively:

**The core mechanism: `Depends()`**

FastAPI resolves dependencies declared as function parameters. You define provider functions and reference them with `Depends()`:

```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session

async def get_document_repo(db: AsyncSession = Depends(get_db)) -> DocumentRepository:
    return DocumentRepository(db)

async def get_document_service(repo: DocumentRepository = Depends(get_document_repo)) -> DocumentService:
    return DocumentService(repo)
```

This creates a chain: endpoint → service → repository → session. Each component receives its dependencies without knowing how they're created.

**Achieving loose coupling:**

1. **Depend on abstractions, not concretions.** Define protocols (Python's structural typing) or Abstract Base Classes (ABCs) for your repositories and services:
   ```python
   class DocumentRepositoryProtocol(Protocol):
       async def get_by_id(self, doc_id: UUID) -> Document | None: ...
       async def create(self, doc: DocumentCreate) -> Document: ...
   ```
   Services depend on the protocol, not the concrete `DocumentRepository`. In tests, you swap in a fake implementation.

2. **Dependencies flow downward only.** The rule is: `routers → services → repositories → database`. A repository never imports from a service. A service never imports from a router. Violations of this rule are the first sign of architecture rot.

3. **Use `Depends()` for cross-cutting concerns too.** Authentication, rate limiting, request logging — these are all dependencies:
   ```python
   async def get_current_user(token: str = Depends(oauth2_scheme)) -> User:
       # validate token, fetch user
       return user
   ```
   The router declares `current_user: User = Depends(get_current_user)` and gets a validated user object. It doesn't know or care how authentication works.

4. **Avoid global state.** Don't create singleton service instances at module level. Let FastAPI's DI system manage lifecycles. This makes testing trivial — just override the dependency:
   ```python
   app.dependency_overrides[get_document_repo] = lambda: FakeDocumentRepo()
   ```

**What makes FastAPI's DI different from frameworks like Spring:**

FastAPI's DI is function-based, not class/container-based. There's no XML configuration or annotation scanning. Dependencies are just functions that return things. This is simpler and more Pythonic, but it means you manage the wiring yourself (in provider functions) rather than relying on auto-discovery.

The tradeoff is worth it: the dependency chain is explicit, readable, and easy to trace. You can follow the chain from any endpoint to understand exactly what gets instantiated and in what order.

</details>

#### Q4.2. Does it make sense to have layering in a hierarchical manner? Doesn't it affect the code itself or maintainability?

**Brief answer**
Yes, hierarchical layering makes sense — it enforces clear responsibilities and prevents spaghetti dependencies. The overhead is minimal and pays for itself quickly in testability and onboarding speed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why hierarchical layering works:**

The typical hierarchy is: Presentation (routers) → Application (services) → Domain (models, business rules) → Infrastructure (repositories, external APIs, database).

Each layer has one job:
- **Routers:** translate HTTP ↔ application calls
- **Services:** orchestrate business operations, enforce rules
- **Repositories:** abstract data storage
- **Models/Domain:** represent the data and its invariants

The key constraint is: **dependencies point downward**. A router can call a service but a service never calls a router. A service can call a repository but a repository never calls a service.

**"Doesn't it add overhead?"**

The common objection is: "I have a simple CRUD (Create, Read, Update, Delete) endpoint. Why do I need a service layer that just passes data through to the repository?" Fair question. For a pure pass-through, the service layer does feel ceremonial. But here's what happens without it:

1. Business logic creeps into routers. First it's one `if` statement. Then validation. Then a second query. Before long, your router is 80 lines and untestable without standing up an HTTP server.
2. When a second route needs the same logic, you duplicate it — or you extract a function that's halfway between a router and a repository, and now your architecture is ad-hoc.
3. New team members can't predict where logic lives. Is the "cancel subscription" logic in the router? In a utility? In the repository?

With layers, the answer is always the same: business logic is in the service. Data access is in the repository. HTTP concerns are in the router. The predictability alone justifies the structure.

**Does it affect maintainability?**

Positively. Layered code is:
- **Testable in isolation.** Test services with a mocked repository. Test routers with a mocked service. No database, no HTTP server, fast tests.
- **Navigable.** New engineer joins → "where does the search logic live?" → `services/search_service.py`. Always.
- **Refactorable.** Want to swap Postgres for MongoDB? Change the repository. The service doesn't know or care.

**When it goes wrong:**

Layering becomes harmful when it's applied dogmatically without judgment. Signs of over-layering:
- Layers that exist "for completeness" but have no distinct responsibility
- Mapper classes that convert between nearly-identical objects at every boundary
- An interface for every class even when there's only one implementation and no plans for another

The fix isn't to remove layers — it's to remove unnecessary abstraction within layers. Keep the hierarchy, but keep each layer lean.

</details>

#### Q4.3. How should the layers be structured and call each other? Can the entrypoint directly depend on the DB? Why have a dependency on the DB session but not on repositories at the router level?

**Brief answer**
Routers should depend on services, services on repositories, repositories on the DB session. The router should never directly touch the DB session or repositories because that collapses layering and couples your HTTP layer to your storage implementation.

<details>
<summary><strong>Detailed answer</strong></summary>

**The correct dependency chain:**

```
Router → Service → Repository → DB Session
```

Each arrow means "depends on." Let me explain why each connection exists and why shortcuts are harmful.

**Why routers depend on services, not repositories:**

If a router directly depends on a repository, it means your HTTP endpoint handler is making data access calls. This has concrete consequences:

1. **Business logic leaks into the router.** Today the endpoint just fetches a document. Tomorrow it needs to check permissions, log an audit event, and trigger an async embedding job. Without a service layer, all of that ends up in the route handler — mixed with HTTP concerns like status codes and response serialization.

2. **Reuse becomes copy-paste.** If two endpoints need the same "fetch document and check permissions" logic, and that logic lives in the router, you either duplicate it or extract a function that's an informal, untested "service."

3. **Testing gets expensive.** To test the router, you now need a database (because the router depends on the repository, which depends on the session). With a service layer, you mock the service and test pure HTTP behavior.

**Why routers should NOT directly depend on the DB session:**

This is an even worse shortcut. If the router holds a DB session, it means:
- The router constructs queries directly (SQLAlchemy `select()` statements in your endpoint handler)
- There's no abstraction over data access — changing your database technology means changing every endpoint
- The session lifecycle is managed at the wrong level

**Why the DB session appears in the dependency chain at all:**

The session is an infrastructure dependency. It's injected into repositories because they need it to execute queries. FastAPI's `Depends()` chain handles this cleanly:

```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session_factory() as session:
        yield session

async def get_document_repo(db: AsyncSession = Depends(get_db)) -> DocumentRepository:
    return DocumentRepository(db)

async def get_document_service(repo: DocumentRepository = Depends(get_document_repo)) -> DocumentService:
    return DocumentService(repo)

# In the router:
@router.get("/documents/{doc_id}")
async def get_document(
    doc_id: UUID,
    service: DocumentService = Depends(get_document_service),
):
    return await service.get_document(doc_id)
```

The router never sees the session. It doesn't know SQL, doesn't know Postgres, doesn't even know that a database exists. It knows it has a service that can `get_document`. This is the correct level of abstraction.

**"But I see DB session in the router in many FastAPI tutorials."**

Yes — and this is a common source of confusion. Tutorials optimize for brevity, not architecture. A 20-line tutorial that queries the DB directly from the router is easy to follow. But that pattern doesn't scale to a real application with business logic, multiple data sources, and a team of engineers.

**The principle:** each layer should only know about the layer directly below it. The router knows about services. Services know about repositories. Repositories know about the DB session. No layer skips.

</details>

---

### Q5. Let's assume we already created our FastAPI app and we want to use the RAG pipeline.

#### Q5.1. How do you integrate the pipeline? That could be an external LLM call over OpenAI or from Azure. How do you integrate it to your existing implementation? What components to consider?

**Brief answer**
Wrap the RAG pipeline as a service with clear interfaces for each stage — document ingestion, embedding, retrieval, and generation. The LLM provider (OpenAI/Azure) is injected as a dependency behind an abstraction, so you can swap providers without touching business logic.

<details>
<summary><strong>Detailed answer</strong></summary>

**Components to consider when integrating a RAG pipeline:**

1. **Document ingestion and chunking**
   - A document loader that handles different file types (PDF, DOCX, plain text). Libraries like `unstructured` or LangChain's document loaders work here.
   - A chunking strategy: split documents into pieces that fit within the embedding model's token limit and are semantically meaningful. Common approaches: fixed-size chunks with overlap, recursive character splitting, or semantic chunking.
   - Store raw documents and their metadata in your relational database. Store the chunks and their embeddings in the vector store.

2. **Embedding generation**
   - An embedding service that takes text and returns vectors. Abstract this behind an interface:
     ```python
     class EmbeddingProvider(Protocol):
         async def embed(self, texts: list[str]) -> list[list[float]]: ...
     ```
   - Implementations: `OpenAIEmbeddingProvider`, `AzureEmbeddingProvider`, or a local model (Sentence Transformers). Swap via configuration, not code changes.
   - Batch embedding calls for efficiency (OpenAI supports batching up to 2048 inputs).

3. **Vector store and retrieval**
   - Store embeddings in pgvector (if you already use Postgres) or a dedicated vector database like Pinecone.
   - The retriever takes a query, embeds it, and performs a similarity search (cosine distance or inner product). Return the top-k relevant chunks with their metadata.
   - Consider a re-ranking step: retrieve top-20, then use a cross-encoder or LLM to re-rank and return top-5. This significantly improves relevance.

4. **Prompt construction**
   - Take the retrieved chunks and the user's query, assemble them into a prompt template. Keep templates in a dedicated `prompts.py` — don't bury them as string literals inside service methods.
   - Include system instructions, context window management (truncate if total tokens exceed the model's context limit), and source attribution metadata.

5. **LLM generation**
   - Call the LLM provider with the constructed prompt. Abstract behind an interface:
     ```python
     class LLMProvider(Protocol):
         async def generate(self, messages: list[dict], **kwargs) -> LLMResponse: ...
     ```
   - Handle: streaming responses (for real-time UI), structured output (JSON mode / function calling for parseable responses), retry logic with exponential backoff for rate limits and transient errors.
   - For Azure OpenAI: the API is nearly identical to OpenAI's, but you configure an Azure-specific endpoint, deployment name, and use AAD tokens or API keys. Use the `openai` Python SDK with `AzureOpenAI` client.

6. **Orchestration (the pipeline itself)**
   - A `RAGPipeline` class or service that chains: `embed query → retrieve → (optional) re-rank → construct prompt → generate → parse response`.
   - This is registered as a FastAPI dependency:
     ```python
     async def get_rag_pipeline(
         embedder: EmbeddingProvider = Depends(get_embedder),
         retriever: Retriever = Depends(get_retriever),
         llm: LLMProvider = Depends(get_llm),
     ) -> RAGPipeline:
         return RAGPipeline(embedder, retriever, llm)
     ```

7. **Cross-cutting concerns**
   - **Timeouts:** LLM calls can take 10-30 seconds. Set explicit timeouts and handle them gracefully.
   - **Cost tracking:** Log token usage per request for billing visibility.
   - **Observability:** Log each pipeline stage with latency, input/output sizes, and retrieved chunk IDs. When an answer is wrong, you need to trace back: was it a retrieval problem (wrong chunks) or a generation problem (right chunks, wrong answer)?
   - **Caching:** Cache embeddings for repeated queries. Consider caching LLM responses for identical query+context combinations.

</details>

#### Q5.2. If you already use Postgres in your project, what will you choose — still Pinecone, or an alternative?

**Brief answer**
Start with pgvector — it keeps your stack simple, eliminates a separate service to manage, and handles most RAG workloads up to millions of vectors. Only move to Pinecone if you hit specific scaling limits pgvector can't satisfy.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why pgvector first:**

pgvector is a PostgreSQL extension that adds vector data types and similarity search operators directly into your existing database. If you already run Postgres, adding pgvector is:

- **Zero additional infrastructure.** No new service to provision, monitor, or pay for. Your existing backup, replication, and access control cover the vector data too.
- **Transactional consistency.** Documents and their embeddings live in the same database. You can insert a document, generate chunks, store embeddings, and commit — all in one transaction. With a separate vector database, you have to handle distributed consistency (what if the Postgres insert succeeds but the Pinecone upsert fails?).
- **Simpler queries.** You can join vector search results with relational data in a single query:
  ```sql
  SELECT d.title, d.author, c.content
  FROM chunks c
  JOIN documents d ON c.document_id = d.id
  ORDER BY c.embedding <=> query_embedding
  LIMIT 10;
  ```
  With Pinecone, you'd query vectors first, get IDs back, then query Postgres for metadata — two round trips.
- **Familiar tooling.** Same SQLAlchemy models, same Alembic migrations, same connection pool.

**Performance considerations:**

pgvector supports two index types:
- **IVFFlat:** good for moderate-sized collections. Build time is fast, but recall degrades without proper tuning of `nlist` and `nprobe` parameters.
- **HNSW (Hierarchical Navigable Small World):** better recall, faster queries, but more memory-intensive and slower index builds. This is what you want for production.

For up to a few million vectors (typical for most RAG applications), pgvector with HNSW provides sub-100ms query latency. That's more than sufficient when the LLM call itself takes 2-10 seconds.

**When to choose Pinecone instead:**

- **Scale beyond tens of millions of vectors** where Postgres memory and index size become painful
- **You need serverless scaling** — Pinecone's serverless tier scales to zero and handles burst traffic without capacity planning
- **Multi-tenant isolation** — Pinecone namespaces provide clean per-tenant separation
- **You don't want to manage Postgres infrastructure** for vector search (index tuning, VACUUM, memory sizing)

**My recommendation:** start with pgvector. It covers 90% of RAG use cases. Introduce Pinecone when (and if) you hit a concrete limitation — not as a premature optimization. If you abstract the retriever behind an interface, swapping the vector store implementation later is a one-file change.

</details>

#### Q5.3. Expand on LangChain usage in the pipeline.

**Brief answer**
I use LangChain selectively — primarily for document loaders, text splitters, and retriever abstractions. I avoid using it for the core LLM call chain, preferring direct SDK calls for better control, debuggability, and fewer layers of abstraction.

<details>
<summary><strong>Detailed answer</strong></summary>

LangChain is a large framework, and the key to using it effectively is knowing which parts to adopt and which to skip.

**What I use LangChain for:**

1. **Document loaders.** LangChain provides loaders for PDFs (`PyPDFLoader`), Word documents (`Docx2txtLoader`), HTML, CSV, and many other formats. Writing these from scratch is tedious and error-prone. The loaders return a consistent `Document` object with `page_content` and `metadata`, which standardizes the ingestion pipeline.

2. **Text splitters.** `RecursiveCharacterTextSplitter` is genuinely useful. It splits text by trying multiple separators (paragraphs, sentences, words) in order, respecting chunk size and overlap. This produces better chunks than naive fixed-size splitting. You configure `chunk_size` (in characters or tokens) and `chunk_overlap`.

3. **Retriever abstractions.** LangChain's `VectorStoreRetriever` wraps your vector store and provides a consistent interface. Useful when you want to try different retrieval strategies (similarity search, Maximum Marginal Relevance (MMR), similarity with score threshold) without rewriting your pipeline.

4. **Embeddings interface.** `OpenAIEmbeddings`, `AzureOpenAIEmbeddings` — thin wrappers that handle batching and retry logic.

**What I avoid in LangChain:**

1. **Chains and agents for production code.** LangChain's `LLMChain`, `SequentialChain`, and agent framework add layers of abstraction that make debugging difficult. When an LLM call returns unexpected output, you want to see exactly what prompt was sent and what came back. With LangChain chains, you're debugging through multiple layers of abstraction, callbacks, and template rendering. I prefer direct OpenAI SDK calls where I construct the messages list explicitly.

2. **LangChain Expression Language (LCEL).** The pipe (`|`) syntax for composing chains is concise but opaque. It's hard to step through with a debugger, hard for new team members to understand, and the error messages when something fails are unhelpful.

3. **Memory abstractions.** LangChain's conversation memory classes (BufferMemory, SummaryMemory) are convenient for prototypes but too rigid for production. In a real app, conversation history is typically stored in your database and managed explicitly — you need control over what's included in the context window, how it's truncated, and how it's formatted.

**How I integrate LangChain pieces with the rest of the FastAPI app:**

```python
# In rag/chunking.py
from langchain_text_splitters import RecursiveCharacterTextSplitter

class DocumentChunker:
    def __init__(self, chunk_size: int = 1000, chunk_overlap: int = 200):
        self.splitter = RecursiveCharacterTextSplitter(
            chunk_size=chunk_size, chunk_overlap=chunk_overlap
        )

    def chunk(self, text: str, metadata: dict) -> list[Chunk]:
        lc_docs = self.splitter.create_documents([text], metadatas=[metadata])
        return [Chunk(content=doc.page_content, metadata=doc.metadata) for doc in lc_docs]
```

Notice the pattern: LangChain is used inside my own class, and the output is converted to my own `Chunk` domain object. The rest of the application never sees LangChain types. This isolation means I can replace LangChain's splitter with a custom one without touching anything outside this file.

**Bottom line:** LangChain is a toolbox, not a framework you commit to. Pick the tools that save you time (loaders, splitters, embeddings wrappers). Build the core pipeline yourself — you'll thank yourself during debugging and when LangChain releases a breaking change.

> **Footnotes:**
> - **MMR (Maximum Marginal Relevance):** A retrieval strategy that balances relevance to the query with diversity among results. It penalizes documents that are too similar to already-selected ones, reducing redundancy in retrieved chunks.
> - **LCEL (LangChain Expression Language):** A declarative syntax for composing LangChain components using the pipe operator (`|`), e.g., `prompt | llm | parser`.

</details>

---

### Q6. Authentication in FastAPI apps.

#### Q6.1. How do you deal with it? How do you design it?

**Brief answer**
I use FastAPI's dependency injection with OAuth2 bearer tokens (JSON Web Token (JWT)). A `get_current_user` dependency validates the token, extracts the user, and injects it into any endpoint that needs authentication — zero auth logic in route handlers.

<details>
<summary><strong>Detailed answer</strong></summary>

**The standard approach: JWT-based authentication**

For most FastAPI APIs, the flow is:
1. Client sends credentials (email + password) to a `/auth/login` endpoint
2. Server validates credentials, generates a JWT access token (and optionally a refresh token)
3. Client includes the token in subsequent requests via the `Authorization: Bearer <token>` header
4. Server validates the token on each request via a dependency

**Implementation:**

```python
from fastapi.security import OAuth2PasswordBearer

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login")

async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=["HS256"])
        user_id = payload.get("sub")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

    user = await user_repo.get_by_id(db, user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")
    return user
```

Any endpoint that needs auth declares `current_user: User = Depends(get_current_user)`. That's it — one line.

**Design decisions:**

1. **Token storage and expiry.** Short-lived access tokens (15-30 minutes) + longer-lived refresh tokens (7-30 days). The access token is stateless (validated purely from its signature). The refresh token is stored in the database so it can be revoked.

2. **Password hashing.** Use `passlib` with bcrypt. Never store plaintext passwords. Hash on registration, verify on login:
   ```python
   from passlib.context import CryptContext
   pwd_context = CryptContext(schemes=["bcrypt"])
   ```

3. **Role-based access control (RBAC).** Create additional dependencies that check roles:
   ```python
   def require_role(role: str):
       async def check(user: User = Depends(get_current_user)):
           if user.role != role:
               raise HTTPException(status_code=403, detail="Insufficient permissions")
           return user
       return check

   # Usage:
   @router.delete("/users/{user_id}")
   async def delete_user(user: User = Depends(require_role("admin"))):
       ...
   ```

4. **Auth as a cross-cutting concern.** Don't scatter token validation across endpoints. The `get_current_user` dependency is the single place where auth happens. Change the auth strategy (JWT → session → API key) by changing one function, not every endpoint.

5. **Protect routes by default.** I prefer explicit opt-out over opt-in. Include the auth dependency at the router level so all endpoints under that router require authentication. Public endpoints are explicitly excluded.

</details>

#### Q6.2. Let's assume you need Single Sign-On (SSO). How would you implement it?

**Brief answer**
Implement SSO using OpenID Connect (OIDC) with a provider like Azure Active Directory (AD), Google, or Okta. Use the `authlib` library to handle the OAuth2 authorization code flow, and map the provider's identity token to your internal user model.

<details>
<summary><strong>Detailed answer</strong></summary>

**What SSO means in practice:**

Single Sign-On (SSO) means users authenticate via their organization's Identity Provider (IdP) — like Azure AD, Okta, or Google Workspace — instead of maintaining separate credentials in your app. The standard protocol is OpenID Connect (OIDC), which is an identity layer built on top of OAuth 2.0.

**The flow (Authorization Code with PKCE):**

1. User clicks "Sign in with SSO" in your app
2. Your app redirects them to the IdP's authorization endpoint with a `code_challenge` (Proof Key for Code Exchange (PKCE))
3. User authenticates with the IdP (password, MFA, biometrics — not your concern)
4. IdP redirects back to your app's callback URL with an authorization `code`
5. Your backend exchanges the `code` for tokens (access token + ID token) by calling the IdP's token endpoint
6. The ID token (a JWT) contains the user's identity claims (email, name, groups)
7. You look up or create the user in your database, issue your own JWT, and the user is authenticated

**Implementation with `authlib`:**

```python
from authlib.integrations.starlette_client import OAuth

oauth = OAuth()
oauth.register(
    name="azure",
    client_id=settings.azure_client_id,
    client_secret=settings.azure_client_secret,
    server_metadata_url="https://login.microsoftonline.com/{tenant}/.well-known/openid-configuration",
    client_kwargs={"scope": "openid email profile"},
)

@router.get("/auth/sso/login")
async def sso_login(request: Request):
    redirect_uri = str(request.url_for("sso_callback"))
    return await oauth.azure.authorize_redirect(request, redirect_uri)

@router.get("/auth/sso/callback")
async def sso_callback(request: Request, db: AsyncSession = Depends(get_db)):
    token = await oauth.azure.authorize_access_token(request)
    id_token = token.get("userinfo") or await oauth.azure.parse_id_token(token)

    email = id_token["email"]
    user = await user_repo.get_by_email(db, email)
    if not user:
        user = await user_repo.create_from_sso(db, email=email, name=id_token.get("name"))

    # Issue your own JWT for subsequent API calls
    access_token = create_access_token(user_id=str(user.id))
    return {"access_token": access_token, "token_type": "bearer"}
```

**Key design decisions:**

1. **Map external identity to internal user.** The IdP's `sub` claim (or email) is the key. On first login, create a user record linked to the external identity. On subsequent logins, look up by that link. Support multiple IdPs per user if needed (store in a `user_identities` table with `provider` and `provider_user_id` columns).

2. **Group/role mapping.** Many IdPs include group memberships in the token claims. Use these to automatically assign roles in your app. For Azure AD, you configure "groups claim" in the app registration, and the token includes the user's group IDs.

3. **Session management after SSO.** After the OIDC flow completes, issue your own JWT. Don't pass the IdP's token to your frontend — its format and expiry are controlled by the IdP, not you. Your app's JWT has your own claims structure and expiry policy.

4. **PKCE is mandatory.** Authorization Code flow without PKCE is vulnerable to code interception. Always use PKCE, even for server-side apps. `authlib` handles this by default.

5. **Multi-tenant support.** If different customers use different IdPs (one uses Azure AD, another uses Okta), store the IdP configuration per tenant. The OIDC discovery document (`/.well-known/openid-configuration`) makes this manageable — each IdP publishes its endpoints at a known URL.

> **Footnotes:**
> - **OIDC (OpenID Connect):** An identity layer on top of OAuth 2.0 that adds a standardized ID token (JWT) containing user identity claims. OAuth 2.0 alone handles authorization; OIDC adds authentication.
> - **PKCE (Proof Key for Code Exchange):** A security extension to the OAuth 2.0 authorization code flow that prevents authorization code interception attacks by requiring a code verifier/challenge pair.

</details>

---

### Q7. Python specifics.

#### Q7.1. Is Python object-oriented, functional, or procedural? How do you decide what to use and when? What is preferred and what are best practices?

**Brief answer**
Python is multi-paradigm — it supports all three. In practice, I default to a mix: classes for stateful components (services, repositories) and plain functions for stateless logic (transformations, utilities). The best practice is to choose the paradigm that makes the code clearest for the problem at hand.

<details>
<summary><strong>Detailed answer</strong></summary>

**Python supports all three paradigms:**

- **Object-Oriented Programming (OOP):** classes, inheritance, encapsulation, polymorphism — all first-class features
- **Functional:** first-class functions, closures, `map`/`filter`/`reduce`, comprehensions, `functools` (partial, reduce, lru_cache), `itertools`, generators
- **Procedural:** top-level functions, scripts, sequential execution

Python doesn't force you into one paradigm. That's both its strength and the source of "how should I write this?" debates.

**How I decide:**

**Use classes when:**
- The component has state that needs to be managed (database connection, configuration, cache)
- You need a clear interface that can have multiple implementations (repository, LLM provider)
- The object has a lifecycle (initialize, use, clean up)
- Examples: `DocumentService`, `RAGPipeline`, `UserRepository` — these hold dependencies and expose methods

**Use plain functions when:**
- The operation is stateless — takes input, returns output, no side effects
- It's a transformation or computation
- Examples: `hash_password(plain: str) -> str`, `chunk_text(text: str, size: int) -> list[str]`, validation functions

**Use functional patterns (map, filter, comprehensions) when:**
- Processing collections: filtering, transforming, aggregating
- Building data pipelines where each step is a pure transformation
- `list(map(embed, chunks))` or `[c for c in chunks if len(c.content) > min_length]`

**Best practices:**

1. **Don't create a class when a function will do.** If your class has an `__init__` that sets one attribute and a single method, that's a function in disguise. The classic anti-pattern:
   ```python
   # Bad — unnecessary class
   class TextCleaner:
       def __init__(self, text):
           self.text = text
       def clean(self):
           return self.text.strip().lower()

   # Good — just a function
   def clean_text(text: str) -> str:
       return text.strip().lower()
   ```

2. **Don't avoid classes when they're the right tool.** If you find yourself passing 5 related arguments to every function in a module, that's a class waiting to be born.

3. **Prefer composition over inheritance.** In Python specifically, deep inheritance hierarchies are rare and usually a sign of Java-style thinking. Use mixins sparingly. Prefer injecting dependencies via `__init__`.

4. **Use dataclasses or Pydantic models for data containers.** Don't write boilerplate `__init__`, `__repr__`, `__eq__` — let `@dataclass` or `BaseModel` generate them.

5. **Leverage Python's functional tools for collection processing.** Comprehensions are more Pythonic than `map`/`filter` for simple cases. Use `functools.lru_cache` for memoization. Use generators for lazy evaluation of large datasets.

The Pythonic answer is: use the right paradigm for the right problem, often mixing them within the same project. Services are classes, utility functions are functions, data containers are dataclasses, and collection processing uses functional patterns.

</details>

#### Q7.2. What are the disadvantages of Python being object-oriented?

**Brief answer**
Python's OOP lacks true encapsulation (no real private members), multiple inheritance creates complexity (diamond problem), and the overhead of classes can lead to over-engineering when simpler functions would suffice.

<details>
<summary><strong>Detailed answer</strong></summary>

Python supports OOP, but its implementation has specific disadvantages compared to stricter OOP languages like Java or C#:

**1. No true encapsulation**

Python has no access modifiers (`private`, `protected`, `public`). The underscore convention (`_private`, `__mangled`) is just a naming convention — anyone can still access `obj._private_attr`. Name mangling with double underscores makes it harder but not impossible (`obj._ClassName__attr`). This means you can't enforce invariants through access control; you rely on developer discipline and documentation.

**2. Multiple inheritance complexity**

Python supports multiple inheritance, which brings the diamond problem (Q7.3 below) and makes class hierarchies harder to reason about. The Method Resolution Order (MRO) using C3 linearization is deterministic but not always intuitive. In practice, bugs from unexpected MRO resolution are subtle and hard to trace.

**3. Performance overhead**

Python objects carry significant overhead compared to plain data. Each object has a `__dict__` (a hash map), a pointer to its class, and reference counting metadata. For data-heavy applications, this memory overhead adds up. Creating millions of small objects is measurably slower than working with tuples, namedtuples, or `__slots__`-optimized classes.

**4. Over-engineering temptation**

Because Python makes OOP easy, developers coming from Java/C# backgrounds tend to over-apply it: abstract base classes with single implementations, factory patterns for objects that are created once, strategy patterns where an `if` statement would do. Python's philosophy ("simple is better than complex") pushes back against this, but the OOP facilities make it tempting.

**5. Duck typing vs. interface contracts**

Python uses duck typing — "if it walks like a duck, it's a duck." This means you get runtime errors instead of compile-time errors when an object doesn't implement the expected interface. Type hints and `Protocol` classes (from `typing`) mitigate this but aren't enforced at runtime by default. In stricter OOP languages, the compiler catches these mismatches before you run the code.

**6. `self` everywhere**

Every method must explicitly include `self` as the first parameter, and every attribute access requires `self.`. This is verbose compared to languages where instance scope is implicit. It's a design choice (explicit is better than implicit), but it does add noise to class definitions.

**The broader point:** Python's OOP disadvantages aren't reasons to avoid OOP in Python — they're reasons to use it judiciously. Use classes when they model your problem well. Don't use them just because "everything should be an object."

</details>

#### Q7.3. How to deal with the diamond inheritance problem (from having multiple superclasses)? What structures does Python provide to deal with such problems?

**Brief answer**
Python solves the diamond problem using the Method Resolution Order (MRO) based on C3 linearization. You can inspect it via `ClassName.__mro__`. To avoid issues, prefer composition over inheritance, use mixins for orthogonal behaviors, and use `super()` correctly to ensure cooperative multiple inheritance.

<details>
<summary><strong>Detailed answer</strong></summary>

**The diamond problem:**

```
       A
      / \
     B   C
      \ /
       D
```

Class `D` inherits from both `B` and `C`, which both inherit from `A`. If `A` defines a method and both `B` and `C` override it, which version does `D` get?

**Python's solution: MRO with C3 linearization**

Python computes a deterministic method lookup order using the C3 linearization algorithm. You can inspect it:

```python
class A:
    def method(self): print("A")

class B(A):
    def method(self): print("B")

class C(A):
    def method(self): print("C")

class D(B, C):
    pass

print(D.__mro__)
# (<class 'D'>, <class 'B'>, <class 'C'>, <class 'A'>, <class 'object'>)

D().method()  # prints "B" — B comes before C in MRO
```

The order is: D → B → C → A → object. Python searches left-to-right in the inheritance list, depth-first, but skips classes that would be visited again later (to handle the diamond).

**`super()` and cooperative inheritance:**

`super()` doesn't just call the parent class — it calls the next class in the MRO. This is crucial for diamond inheritance to work correctly:

```python
class A:
    def method(self):
        print("A")

class B(A):
    def method(self):
        print("B")
        super().method()  # calls C.method, not A.method!

class C(A):
    def method(self):
        print("C")
        super().method()  # calls A.method

class D(B, C):
    def method(self):
        print("D")
        super().method()

D().method()  # prints: D, B, C, A
```

Each class in the chain calls `super()`, and the MRO ensures every class's method is called exactly once. This is called "cooperative multiple inheritance."

**Structures Python provides:**

1. **`__mro__` attribute / `mro()` method** — inspect the resolution order
2. **`super()`** — delegates to the next class in MRO (not necessarily the direct parent)
3. **Abstract Base Classes (ABCs)** from `abc` module — define interfaces that subclasses must implement, making the contract explicit
4. **`Protocol`** from `typing` — structural subtyping (duck typing formalized). No inheritance needed; a class satisfies a Protocol if it has the right methods.

**Practical strategies to avoid diamond problems:**

1. **Prefer composition over inheritance.** Instead of `class D(B, C)`, have `D` hold instances of `B` and `C` as attributes and delegate explicitly. This is almost always clearer.

2. **Use mixins for orthogonal behavior.** A mixin is a class that adds one specific capability (like `LoggingMixin`, `SerializableMixin`). Mixins should not have `__init__` parameters and should not conflict with each other.

3. **Keep inheritance hierarchies shallow.** If you're more than 2-3 levels deep, reconsider the design.

4. **Always use `super()` consistently.** If any class in the hierarchy calls `super()`, all of them should — otherwise the chain breaks.

> **Footnotes:**
> - **C3 linearization:** The algorithm that computes Python's MRO. It guarantees: (1) subclasses come before superclasses, (2) the order of bases in the class definition is preserved, (3) each class appears exactly once. If these constraints can't be satisfied, Python raises a `TypeError`.

</details>

#### Q7.4. Are there private methods in Python?

**Brief answer**
No — Python has no true private methods. It has a convention (`_single_underscore` for "internal") and a mechanism (`__double_underscore` for name mangling), but neither actually prevents access.

<details>
<summary><strong>Detailed answer</strong></summary>

Python takes the approach of "we're all consenting adults" — it trusts developers to respect conventions rather than enforcing access restrictions.

**Single underscore prefix: `_method()`**

This is a convention meaning "this is internal, don't use it from outside." It has no enforcement:
```python
class MyClass:
    def _internal_helper(self):
        return "internal"

obj = MyClass()
obj._internal_helper()  # Works fine — no error
```

The only tool-level enforcement: `from module import *` will not import names starting with `_`. That's it.

**Double underscore prefix: `__method()`**

This triggers name mangling — Python renames the attribute to `_ClassName__method`. It's designed to prevent accidental name collisions in subclasses, not to enforce privacy:

```python
class MyClass:
    def __secret(self):
        return "secret"

obj = MyClass()
# obj.__secret()        # AttributeError
obj._MyClass__secret()  # Works — "secret"
```

The method still exists and is accessible; it's just renamed. Any developer who reads about name mangling can bypass it trivially.

**Why Python doesn't have real private methods:**

It's a deliberate design philosophy. Python values flexibility and introspection (you can inspect any object's attributes at runtime with `dir()`, `__dict__`, etc.). True private members would break introspection, testing (you often need to access internals in tests), and debugging. The tradeoff is: you get powerful introspection and flexibility at the cost of enforceable encapsulation.

**Practical guidance:**

- Use `_single_underscore` for methods and attributes that are internal implementation details. This is the Pythonic way to say "don't depend on this."
- Use `__double_underscore` only when you specifically need to avoid name collisions in inheritance hierarchies (rare in practice).
- Don't use double underscores thinking it makes things "private" — it doesn't, and it makes subclassing and testing harder.
- If you truly need to enforce an interface, use `Protocol` or ABC to define what's public, and document that the rest is internal.

</details>

#### Q7.5. SQLAlchemy and ORMs — how do you prefer to work with them? Using directly mapped columns from SQLAlchemy or something else like dataclasses, Pydantic?

**Brief answer**
I use SQLAlchemy models for the database layer and separate Pydantic models for API schemas and validation. I don't mix them — SQLAlchemy handles persistence, Pydantic handles serialization and validation, and I convert between them explicitly.

<details>
<summary><strong>Detailed answer</strong></summary>

**My approach: separate SQLAlchemy models and Pydantic schemas**

```python
# models/document.py — SQLAlchemy (persistence)
class Document(Base):
    __tablename__ = "documents"
    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(String(255))
    content: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=func.now())

# schemas/document.py — Pydantic (API contract)
class DocumentCreate(BaseModel):
    title: str = Field(max_length=255)
    content: str

class DocumentResponse(BaseModel):
    id: uuid.UUID
    title: str
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)
```

**Why separate them:**

1. **Different concerns.** SQLAlchemy models define how data is stored (column types, constraints, indexes, relationships). Pydantic models define how data enters and leaves your API (validation rules, field inclusion/exclusion, serialization format). These change for different reasons.

2. **Selective exposure.** Your API response doesn't include every database column. The `DocumentResponse` above excludes `content` (maybe it's large and you only return it in a detail endpoint). With separate models, this is trivial. With a single model, you'd need exclude lists or conditional serialization.

3. **Input ≠ output ≠ storage.** The create request (`DocumentCreate`) has no `id` or `created_at` — the database generates those. The response (`DocumentResponse`) has them. The database model has additional fields like `updated_at`, `deleted_at`, foreign keys. Three different shapes for three different purposes.

4. **Validation at the boundary.** Pydantic validates incoming data with rich constraints (`max_length`, regex patterns, custom validators). SQLAlchemy validates at the database level (NOT NULL, UNIQUE, CHECK). These are complementary, not redundant — Pydantic catches bad data before it hits the database, giving better error messages.

**What about SQLAlchemy + dataclasses?**

SQLAlchemy 2.0 supports mapping to dataclasses:
```python
@dataclass
class Document:
    __tablename__ = "documents"
    id: uuid.UUID = field(default_factory=uuid.uuid4)
    title: str = ""
```

This is useful for domain models that need to work outside of SQLAlchemy (in tests, in pure domain logic). But for FastAPI specifically, Pydantic models are still preferred for the API layer because FastAPI's validation, documentation generation, and serialization are built around Pydantic.

**The conversion:**

```python
# In the service layer:
async def create_document(self, payload: DocumentCreate) -> Document:
    doc = Document(**payload.model_dump())
    self.db.add(doc)
    await self.db.commit()
    return doc

# In the router, FastAPI handles the conversion back to Pydantic
# because DocumentResponse has `from_attributes=True`
```

The `from_attributes=True` (formerly `orm_mode`) config tells Pydantic to read attributes from an ORM object, not just a dict. This makes the conversion seamless.

**Bottom line:** the extra effort of maintaining separate models pays off in clarity, flexibility, and correctness. It's the standard pattern in production FastAPI applications for good reason.

</details>

#### Q7.6. How do you deal with validation in dataclasses?

**Brief answer**
Plain dataclasses have no built-in validation. I either use Pydantic's `BaseModel` (which has validation built in) or `@pydantic.dataclasses.dataclass` to add Pydantic validation to a dataclass. For simple cases, `__post_init__` with manual checks works too.

<details>
<summary><strong>Detailed answer</strong></summary>

**The problem: standard dataclasses don't validate**

```python
from dataclasses import dataclass

@dataclass
class User:
    name: str
    age: int

user = User(name=123, age="not a number")  # No error! Types are just hints.
```

Python's `@dataclass` uses type hints for documentation and tooling, but does not enforce them at runtime. `name` happily accepts `123`.

**Option 1: Pydantic `BaseModel` (preferred for FastAPI)**

Just use Pydantic instead of dataclasses:
```python
from pydantic import BaseModel, Field

class User(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    age: int = Field(ge=0, le=150)

User(name=123, age="not a number")  # ValidationError!
```

Pydantic validates types, coerces where possible (string "42" → int 42), and raises clear errors. It also handles nested models, custom validators, and serialization. For FastAPI projects, this is the default choice.

**Option 2: Pydantic dataclass decorator**

If you want the dataclass interface (positional args, no `.model_dump()` needed) but with validation:
```python
from pydantic.dataclasses import dataclass

@dataclass
class User:
    name: str
    age: int

User(name=123, age="not a number")  # ValidationError — Pydantic validates it
```

This gives you a class that behaves like a dataclass but has Pydantic validation under the hood. Useful when you want to gradually add validation to existing dataclass-based code.

**Option 3: `__post_init__` with manual validation**

For cases where you don't want a Pydantic dependency (e.g., a library or domain model):
```python
from dataclasses import dataclass

@dataclass
class ChunkConfig:
    chunk_size: int
    chunk_overlap: int

    def __post_init__(self):
        if self.chunk_size <= 0:
            raise ValueError(f"chunk_size must be positive, got {self.chunk_size}")
        if self.chunk_overlap >= self.chunk_size:
            raise ValueError("chunk_overlap must be less than chunk_size")
        if not isinstance(self.chunk_size, int):
            raise TypeError(f"chunk_size must be int, got {type(self.chunk_size)}")
```

`__post_init__` runs after `__init__`, so all fields are assigned and you can validate invariants. This works but gets tedious for many fields — you're writing validation logic that Pydantic gives you for free.

**Option 4: `attrs` library with validators**

The `attrs` library (predecessor to dataclasses, still actively maintained) has built-in validation:
```python
import attrs

@attrs.define
class User:
    name: str = attrs.field(validator=attrs.validators.instance_of(str))
    age: int = attrs.field(validator=[
        attrs.validators.instance_of(int),
        attrs.validators.ge(0),
    ])
```

`attrs` is lighter than Pydantic and doesn't do type coercion — it validates strictly. Good for internal domain models where you want validation without the full Pydantic machinery.

**My recommendation:** In a FastAPI project, use Pydantic models for anything that crosses a boundary (API input/output, configuration, external service responses). Use plain dataclasses only for internal value objects where type safety is guaranteed by the calling code. If a plain dataclass starts accumulating `__post_init__` checks, switch to Pydantic.

</details>
