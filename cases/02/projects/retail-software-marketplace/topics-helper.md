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

**How to use it.** For each topic, be able to (a) say what it is in two sentences, (b) name the trade-off it buys and what it costs, (c) point at where it shows up in this system. A topic you can only define is not yet known.

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
- **MUST** — Ports and adapters (hexagonal); repository and unit-of-work patterns
- **MUST** — Where business rules live, and the smell of logic inside a route handler
- **MUST** — Bounded contexts and aggregates; one owner per fact, one writer per table
- **MUST** — Module boundary vs deployment boundary: which one the requirement actually demanded, and the honest difference between "enforced" and "documented"
- **MUST** — Service decomposition criteria: traffic shape, release cadence, data sensitivity, blast radius — not size
- **NICE** — Distributed monolith as the failure mode; the cost of nine deployments at low [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") and what makes it affordable (one repo, one migration history, one pipeline)
- **NICE** — Anti-corruption layer; no service reading another's database

## 2. Python, FastAPI and Pydantic Service Mechanics

**Backs:** FastAPI [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") APIs for catalog browse and vendor-retailer connection.

- **MUST** — [ASGI](https://asgi.readthedocs.io/en/latest/ "Asynchronous Server Gateway Interface — Standard interface between asynchronous Python web servers and applications") vs WSGI; uvicorn/gunicorn workers, the event loop, the thread pool
- **MUST** — async/await, tasks, cancellation, timeouts; when async actually helps (a workload dominated by waiting on Postgres, Mongo and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"))
- **MUST** — The blocking-call trap: one sync driver call stalls every request on that worker; run_in_executor as the escape hatch
- **NICE** — Concurrency limits and backpressure; unbounded fan-out as a self-DoS
- **MUST** — FastAPI: dependency injection and its caching, routers as an enforcement point, middleware order, lifespan, exception handlers, BackgroundTasks vs a real queue
- **MUST** — [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") v2: validation vs serialization, extra=forbid so unknown fields are rejected rather than absorbed, discriminated unions, custom validators, settings loading, the Rust core's performance profile
- **MUST** — Validating untyped input against a runtime schema (per-category facets) — "no fixed column set" without losing a contract
- **NICE** — The [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document as a build artefact the admin console and vendor integrations compile against

## 3. REST API Design Under Load and Under Retry

**Backs:** catalog browse, connection APIs, and the admin panel calling the same versioned APIs.

- **MUST** — Resource modelling, URI design, /v1 versioning and how a breaking change actually ships
- **MUST** — Pagination: keyset/cursor vs offset, cursor encoding, stable sort tuples, and why deep pages are the normal case in a comparison workflow
- **NICE** — Counting is expensive: exact total vs capped estimate, and the product consequence ("1,000+")
- **MUST** — Idempotency keys on [POST](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP POST — HTTP method that submits data to a server to create or process a resource"): storage, [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"), replaying the stored response, and why the database unique constraint is the guarantee and the cache is not
- **MUST** — Status codes and error contracts; machine-readable error codes
- **NICE** — Filtering and faceting as an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") surface; refusing query shapes that cannot be served — a product constraint that buys a performance guarantee
- **MUST** — Rate limiting and quotas: per-subject vs per-IP, token bucket vs sliding window, business limits vs infrastructure limits
- **NICE** — Contract testing against the OpenAPI document; no private admin backdoor API
- **NICE** — Request correlation ids and their propagation obligations

## 4. Authentication: OAuth 2.0, OIDC and JWT

**Backs:** implemented [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") and [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") authentication for vendors and retailers.

- **MUST** — OAuth2 roles, grant types and their fit: authorization code + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") for human/public clients, client credentials for machine integrations; why implicit and password grants are dead
- **MUST** — [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") vs OAuth2: authentication vs delegated authorization, id_token vs access_token, scopes vs claims
- **MUST** — JWT anatomy: header/kid, registered claims, [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") vs HS256, the alg=none and algorithm-confusion attacks, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") publication and key rotation with overlap
- **MUST** — Local verification vs introspection, and the latency consequence of choosing (a per-request round trip adds to every hop)
- **MUST** — Access-token lifetime as the revocation window; refresh rotation, one-time jti, reuse detection revoking the whole chain, denylists for the urgent case
- **NICE** — Token storage in a browser: HttpOnly/Secure/SameSite cookies vs localStorage, CSRF, and the trade-offs
- **MUST** — Client secret handling: Argon2id hashing, rotation, never in a repo
- **MUST** — Two-layer verification: an edge gateway is a filter, the service is the authority; both must be cheap enough to do per request

## 5. Authorization and Multi-Tenancy

**Backs:** "catalog and connection APIs stayed behind the right account type" — and everything that check alone does not cover.

- **MUST** — Three distinct checks: account type (coarse), role → scope ([RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually")), tenant scope ([ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles")), and why any one alone is insufficient
- **MUST** — Broken object-level authorization (IDOR/BOLA) as the dominant API vulnerability
- **MUST** — Enforcing the tenant filter in exactly one place (a session/repository-level filter) rather than per endpoint — a per-endpoint check works until someone adds an endpoint
- **MUST** — [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") Row-Level Security: how it works, and the pooled-connection trap (SET vs SET LOCAL) that makes it silently a no-op — why it was rejected here as the primary control and what the compensating control must then prove
- **MUST** — Tests that assert cross-tenant reads return empty for every repository method
- **MUST** — Marketplace-specific authorization: asymmetric visibility between two sides, a vendor never enumerating the buyer directory, drafts never projected
- **NICE** — Admin bypass paths and auditing every one of them
- **MUST** — Scope design: read vs write, org-scoped vs platform-scoped

## 6. PostgreSQL Data Modelling

**Backs:** built PostgreSQL schemas for vendors, retailers and product listings.

- **MUST** — Normalisation, and denormalisation as a deliberate read-model decision
- **MUST** — Keys: uuid vs bigint, natural vs surrogate, uniqueness as an invariant
- **MUST** — Constraints as correctness rather than convention: unique, partial unique (bill a connection at most once), check, exclusion, FK actions
- **NICE** — Money: integer minor units plus an explicit [ISO-4217](https://www.six-group.com/en/products-services/financial-information/data-standards.html "ISO 4217 — Standardizes three-letter currency codes for unambiguous monetary values") currency, never float
- **MUST** — Read models / projection tables: what they copy, who is allowed to write them, and why the hot query then touches one relation and never joins
- **MUST** — jsonb for open attributes: indexing it, statistics, TOAST, write amplification
- **NICE** — Arrays vs join tables; containment queries and their selectivity problems
- **NICE** — Declarative range partitioning by month on unbounded tables; pruning, detach-to-archive as a metadata operation instead of a long DELETE
- **NICE** — Append-only tables and revoked UPDATE/DELETE grants
- **MUST** — Transactions and isolation levels; [MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row"), locking, deadlocks, SKIP LOCKED
- **NICE** — Sharding: what it actually costs, and the evolution triggers that justify it (and the cheaper move that usually comes first)

## 7. Indexing and Query Performance

**Backs:** optimized [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") queries and indexes for catalog search and listing filters.

- **MUST** — EXPLAIN (ANALYZE, BUFFERS): scan and join types, estimated vs actual rows, what a bad estimate does downstream
- **NICE** — Planner statistics, selectivity, n_distinct, extended statistics, ANALYZE
- **MUST** — Index types and their jobs: B-tree, composite (column order, leading-column rule), partial, covering/index-only scans, [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") vs [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints"), jsonb_path_ops, array containment, tsvector full text, [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables")
- **MUST** — Bitmap index scans: AND vs OR combination, and the degradation to a sequential scan when the planner's selectivity estimate is wrong
- **MUST** — Faceted search as a performance problem: many optional predicates, and the mitigations in order of impact (one denormalised table, a partial index carrying the status predicate, keyset pagination, required category, estimated counts)
- **MUST** — Data access patterns and their pathologies: N+1 queries, chatty per-item lookups instead of one bulk $in / IN, SELECT *, implicit casts and functions defeating an index, OR-chains
- **MUST** — Every index is a tax on every write; index bloat, autovacuum, HOT updates
- **MUST** — Connection pooling: server connection limits, pgbouncer pool modes and what each forbids, sizing pod pools so their sum stays under the server limit
- **MUST** — Read replicas: replica lag as an [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health"), which reads may use one, read-your-writes, and falling back to the primary above a lag threshold
- **MUST** — Measuring: pg_stat_statements, auto_explain, a real-volume seeded table before trusting a latency figure

## 8. SQLAlchemy and Alembic

**Backs:** [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") and [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") across the marketplace services.

- **MUST** — Core vs [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries"), and choosing Core where the generated plan matters
- **MUST** — Session as unit of work: identity map, flush vs commit, expire_on_commit, session scoped to a request
- **MUST** — Lazy loading and the N+1 it creates; selectinload / joinedload / raiseload
- **MUST** — Async engine and session, asyncpg specifics
- **NICE** — Bulk operations: executemany, insert().on_conflict_do_update() for idempotent upserts, returning(), batching projection writes
- **MUST** — Repository layer as the single place a tenant filter can be enforced
- **NICE** — Alembic: revision graph, branches and merges, autogenerate's blind spots (server defaults, index changes, enums, data migrations)
- **MUST** — Expand/contract migrations: the previous image must run against the new schema, CREATE INDEX CONCURRENTLY, lock-taking DDL, statement timeouts
- **MUST** — Why that discipline is what makes rollback possible at all

## 9. MongoDB and Schemaless Modelling

**Backs:** designed [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") schemas for product metadata so vendors could publish without a fixed column set.

- **MUST** — Document modelling: embed vs reference, the 16 MB limit as a boundary you design away from, media never stored in the document
- **MUST** — Making a schemaless store governable: per-category schema documents, validation at write time, schema_version on every document
- **MUST** — Schema evolution: migrate-on-read vs backfill vs hard version cutover, and how that choice prices every future category change
- **MUST** — Indexes: single/compound, index prefix rules, TTL indexes for staging data, partial and sparse indexes, covered queries, explain() in Mongo
- **NICE** — Immutable revisions as a modelling pattern; append instead of update
- **MUST** — Replica sets: elections, primary/secondary reads, read preference, read concern and write concern, and what "eventually consistent secondary" costs
- **OPTIONAL** — Aggregation pipeline basics and where the work should not be done
- **OPTIONAL** — Multi-document transactions: available but expensive, and why the design avoids needing them
- **NICE** — Sharding: shard-key choice as a hard-to-reverse decision — and the case for not sharding
- **OPTIONAL** — Managed variants (Cosmos DB for MongoDB) diverging at runtime, not at deploy

## 10. Polyglot Persistence and Cross-Store Consistency

**Backs:** a listing whose spine is relational and whose body is a document, kept in step.

- **MUST** — Choosing which store owns which fact; one owning store per fact
- **MUST** — The dual-write problem: two stores, one logical operation, no shared transaction — and the ordering rule that makes a partial failure benign (an orphan document is reclaimable, a dangling pointer is a broken listing)
- **MUST** — Transactional outbox: the event row commits with the state change; the relay publishes and marks it; delivery becomes at-least-once, never zero
- **MUST** — Idempotent projection: upsert keyed on the entity, ignore an event older than the current revision — redelivery is a no-op, out-of-order cannot roll back
- **NICE** — Reconciliation jobs as the backstop for a lost event, and why a design that needs one should say so
- **MUST** — Eventual consistency made visible: projection lag as an SLI with an alert, because "the indexer died" is otherwise a silent failure
- **MUST** — Read-your-writes by routing: the writer reads the authoritative source, the reader gets the fast, slightly stale projection
- **OPTIONAL** — CQRS as the general name for this shape; when it is over-engineering
- **MUST** — The honest alternative (everything in Postgres with JSONB) and what it trades

## 11. Caching with Redis

**Backs:** cached hot catalog reads in Redis to cut database load on popular listings.

- **MUST** — Cache-aside vs write-through vs write-behind, and why cache-aside keeps the cache expendable
- **MUST** — Invalidation strategies: event-driven purge, TTL as a backstop, and version-suffixed keys that make a stale key unreachable even if the purge is lost
- **MUST** — Cache stampede / thundering herd: what happens when a hot key expires under concurrency; single-flight locks, probabilistic early expiry, serving stale
- **MUST** — Hit-ratio arithmetic: what origin load and latency become at 0% hit rate, and sizing the database to survive a cache loss
- **MUST** — Key design and namespacing; hashing a filter set into a key; what must never be cached at a layer blind to the requester
- **NICE** — TTL choice per data shape: 60 s for a search page because enumerating every affected filter combination is intractable
- **NICE** — Eviction policies, memory sizing, hot keys, big keys
- **OPTIONAL** — Redis data structures and atomicity; pipelines; Lua; SETNX locks and the honest limits of distributed locking
- **MUST** — Redis for rate-limit counters, idempotency keys and semaphores — and the fail-open/fail-closed decision when it is unavailable
- **MUST** — Redis as a cache, never a store

## 12. Asynchronous Work with Celery

**Backs:** configured [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for catalog imports and notification jobs so they did not block the API.

- **MUST** — Broker vs result backend; Redis as a broker and its weak acknowledgement semantics versus a real message broker
- **MUST** — task_acks_late, visibility timeout, prefetch multiplier, worker concurrency models (prefork vs gevent vs threads)
- **MUST** — At-least-once execution: every task must be idempotent, because it will run twice
- **MUST** — Retries: exponential backoff with jitter, max attempts, dead-lettering, poison messages
- **MUST** — Queue separation so imports cannot starve indexing or notifications; separate worker deployments scaled on their own queue depth
- **NICE** — Fairness: a per-tenant concurrency cap (a Redis semaphore) so one vendor cannot occupy the pool
- **MUST** — Chunking a large job into bounded tasks; batching downstream writes so one import does not produce 20,000 invalidations
- **MUST** — Staging then promoting: validate everything before any of it is applied, so a malformed file fails wholly rather than half-applying
- **NICE** — Graceful shutdown: preStop, draining, task size vs termination grace period
- **MUST** — Durability: what a broker failover can lose, and how to test it (kill the worker) rather than assume

## 13. Event-Driven Integration on Azure

**Backs:** integrated Azure Functions, Blob Storage and Service Bus for catalog updates and vendor-retailer notifications.

- **MUST** — Queue vs topic/subscription; competing consumers; fan-out to independent consumers
- **MUST** — Service Bus mechanics: peek-lock vs receive-and-delete, lock renewal, dead-letter queues and replay, duplicate detection, sessions for ordering, scheduled messages, retry policy
- **MUST** — Delivery semantics: at-most-once, at-least-once, and why exactly-once is a property of the consumer
- **NICE** — Event schema design and versioning; consumer-driven contracts
- **MUST** — Two messaging systems on purpose: an in-process work queue vs an event bus that crosses a boundary — one rule, no overlap
- **MUST** — Azure Functions: triggers and bindings (blob, queue), consumption vs premium, cold start, scaling behaviour, idempotent handlers, slot swap deploys
- **MUST** — Blob Storage: containers and prefixes, access tiers and lifecycle rules, [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") tokens, direct client upload, content-addressed paths, Content-Disposition and serving untrusted files from a separate hostname
- **NICE** — Splitting policy from delivery: deciding whether to notify in code that has database context, delivering in a function that does not

## 14. Search and Faceted Filtering in PostgreSQL

**Backs:** catalog search and listing filters used when chains compare coverage.

- **MUST** — Full-text search in Postgres: to_tsvector/to_tsquery, dictionaries and stemming, ts_rank, GIN vs GiST for tsvector, maintaining the vector in a worker rather than a trigger (and why the trigger couples write latency)
- **NICE** — Language handling: a single dictionary versus a multilingual catalog, and trigram similarity (pg_trgm) for fuzzy name matching
- **MUST** — Facet counts: how they are computed and why they cost as much as the page
- **MUST** — Filter selectivity and the combinatorics of optional predicates
- **MUST** — When Postgres search stops being enough: the concrete trigger for adopting a search engine, and what a dedicated engine adds (relevance tuning, analyzers, highlighting) and costs (a third store, a second lag, expertise)

## 15. Kubernetes and AKS

**Backs:** deployed services to Azure [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") with Docker and [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications").

- **MUST** — Core objects: Deployment, ReplicaSet, Service, Ingress, ConfigMap, Secret, Job/CronJob, Namespace
- **MUST** — Probes: liveness vs readiness vs startup, and the outage a wrong liveness probe causes
- **MUST** — Requests and limits, [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes") classes, OOMKill, CPU throttling
- **MUST** — Rollout strategies: rolling, canary (ingress weighting, hold time, the metric that decides promotion), blue-green and why it can be the wrong spend when both colours share one database
- **MUST** — Rollback as a redeploy of a previous image digest, and the schema discipline that makes it safe
- **NICE** — Graceful termination: preStop, terminationGracePeriodSeconds, draining workers rather than killing them
- **NICE** — Autoscaling: [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on CPU and on a custom queue-depth metric, cluster autoscaler
- **NICE** — NetworkPolicy default-deny, ingress and egress; service mesh and mTLS as a documented upgrade with a named trigger rather than a default
- **MUST** — Workload identity instead of mounted credentials
- **MUST** — Docker fundamentals: layers and caching, multi-stage builds, non-root users, small base images, digest pinning, Compose for a local and [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") stack of real data stores

## 16. CI/CD Pipelines

**Backs:** automated GitLab CI pipelines for test and deploy across services.

- **MUST** — Pipeline structure: stages, jobs, artifacts, caches, services containers, needs/DAG, parallelism, matrix builds
- **MUST** — A gate is only a gate if it can fail: proving each blocking step actually blocks by making it fail on purpose
- **MUST** — Test layering: lint, type check, unit, integration against real containers, functional/contract against the OpenAPI document, smoke after deploy
- **MUST** — Why integration tests use real Postgres/Mongo/Redis: query plans and a projection pipeline are exactly what a mock passes while broken
- **MUST** — Ordering migrations relative to deploy, and expand/contract as the rule
- **NICE** — Environment promotion, staging that is the same topology at smaller size, and what makes a staging smoke test meaningful
- **NICE** — Supply chain: digest-pinned images, hash-pinned dependencies, [CVE](https://www.cve.org/ "Common Vulnerabilities and Exposures — Public identifier for a known software security flaw") scanning, SBOM, weekly base-image rebuilds
- **MUST** — Secrets in CI: OIDC federation to the cloud instead of stored credentials
- **MUST** — Debugging a failing pipeline: reproducing the runner environment, exit codes versus output text, the pipe that swallows a status

## 17. Terraform and Infrastructure as Code

**Backs:** provisioned Azure marketplace infrastructure with [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files").

- **MUST** — The core loop: providers, resources, data sources, plan/apply, the graph
- **MUST** — State: what it is, remote backends, locking, why it is sensitive, and never editing it by hand
- **MUST** — Modules and composition; variables, outputs, locals; version pinning for providers and modules
- **MUST** — Environments: workspaces vs directories vs variable files, and keeping them one module set so staging really matches production
- **MUST** — Drift: a resource created in the portal is drift and should be reported as a failure; import for adopting existing resources
- **NICE** — Managing alert rules and IAM role assignments as code so a widened permission is a reviewable diff
- **MUST** — Applying only from CI, plan-review gates, and the blast radius of the deploy identity (splitting plan-only from apply, separating network/data-plane state)
- **MUST** — Secrets that must not enter state; Key Vault references
- **NICE** — What IaC does not give you: it is not a test that the topology works

## 18. Observability and Alerting

**Backs:** monitored services with Azure Monitor, tracking API errors and job failures on catalog and connection flows.

- **NICE** — RED and USE methods for choosing what to measure
- **MUST** — Metric types: counters, gauges, histograms; percentiles and what a p95 from a histogram really means; label cardinality
- **MUST** — SLI, [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), error budget, burn-rate alerting, and page vs ticket severity
- **MUST** — Detecting silent failure: lag and backlog-age metrics that fire when nothing is erroring at all (a dead indexer, a stalled outbox relay)
- **MUST** — Structured logging: [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"), correlation fields on every line, tenant id so a support query can be scoped, and hard rules on what never appears in a log (message bodies, tokens, secrets)
- **NICE** — Application logs are diagnostics; the audit table is the record — keeping them separate
- **MUST** — Distributed tracing: spans, context propagation, [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") traceparent, propagation through queue message properties, sampling strategy, and verifying end-to-end trace continuity rather than assuming the instrumentation does it
- **NICE** — OpenTelemetry as the instrumentation layer and Azure Monitor/App Insights as the backend
- **NICE** — Alert hygiene: alerts as code, an alert silenced by hand during an incident and never restored is how monitoring rots

## 19. Testing Practice

**Backs:** wrote unit, integration and functional tests with Pytest for catalog, auth and connection paths.

- **MUST** — The test pyramid and what each layer is actually for here
- **MUST** — Pytest mechanics: fixtures and scopes, parametrize, factories, markers, conftest layering, plugins for async
- **MUST** — Test data: factories over fixtures-as-files, deterministic seeds, realistic volume when the assertion is about a query plan
- **MUST** — Isolation: transactional rollback per test, database truncation, container reuse; parallel test runs and shared-state hazards
- **MUST** — Integration tests against real dependencies via Compose/testcontainers
- **MUST** — Functional/contract tests against the OpenAPI schema
- **MUST** — Authorization tests as first-class: cross-tenant reads must return empty for every repository method, on every endpoint
- **NICE** — Idempotency and retry tests; failure injection (kill the worker, drop the cache, stall the broker)
- **MUST** — What a test that has never failed proves: nothing — mutate the code and confirm the test catches it
- **NICE** — Coverage as a signal, not a target

## 20. Security Beyond Authentication

**Backs:** auth module refactoring, uploads, and operating a three-sided marketplace.

- **MUST** — Threat modelling: trust boundaries, STRIDE, and the insight that the dangerous adversary on a marketplace is authenticated and legitimate
- **MUST** — [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") API Top 10, especially object- and function-level authorization
- **MUST** — Injection and validation: parameterised queries, ORM escapes and where they leak, schema validation rejecting unknown fields
- **MUST** — File upload handling: content-type allowlists, size caps, re-encoding images, serving untrusted files from a separate hostname with attachment disposition, stored [XSS](https://owasp.org/www-community/attacks/xss/ "Cross Site Scripting — Attack that injects malicious script into content viewed by other users")
- **NICE** — Scraping and enumeration defence: per-subject limits, capped result counts, absence of a bulk export
- **MUST** — Encryption in transit ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") versions, [HSTS](https://datatracker.ietf.org/doc/html/rfc6797 "HTTP Strict Transport Security — Instructs browsers to only ever connect to a site over HTTPS"), certificate verification, private endpoints) and at rest (TDE, [CMK](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys "Customer Managed Key — An encryption key the customer controls rather than the cloud provider"), envelope encryption, key rotation)
- **MUST** — Secrets: managed vaults, workload identity, no static credentials, least privilege per workload, and the blast radius of the CI deploy identity
- **NICE** — Audit trail: append-only grants, partitioning, immutable archive, written asynchronously and why that is a constraint rather than an optimisation
- **MUST** — [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") for [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers")/occupational data: lawful basis, minimisation, residency, sub-processors, [DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them"), and erasure conflicting with a counterparty's business record
- **NICE** — Keeping PCI scope at [SAQ-A](https://www.pcisecuritystandards.org/document_library/ "Self-Assessment Questionnaire A — Lightest PCI-DSS compliance tier for merchants who fully outsource card data handling") by never touching cardholder data, and what changes the moment the platform intermediates a payment

## 21. Linux and Production Operations

**Backs:** administered Linux hosts for production and development.

- **MUST** — Processes and services: systemd units, journald, signals, exit codes, cron
- **MUST** — Users, groups, file permissions, sudo policy, SSH key management
- **MUST** — Networking: ip/ss, DNS resolution, ports and firewalls, tcpdump basics, debugging a TLS handshake and certificate chain with openssl s_client
- **MUST** — Resource troubleshooting: top/htop, iostat, vmstat, free, the OOM killer, ulimits, file-descriptor exhaustion, disk full and inode exhaustion
- **OPTIONAL** — Log rotation and retention
- **OPTIONAL** — Package management and patch cadence for container base images
- **MUST** — Shell fundamentals for safe operational scripting: exit status vs output, pipefail, quoting, and why a pipeline reports only its last stage

## 22. Code Review and Refactoring

**Backs:** reviewed pull requests and refactored catalog and auth modules.

- **MUST** — What a review is for: correctness, boundary violations, missing authorization checks, and a diff's effect on contracts others depend on
- **MUST** — Reviewing for duplication: a rule in two places is a defect, and the second occurrence is where you extract
- **MUST** — Refactoring an auth module without a behaviour change: characterisation tests first, small steps, one variable at a time
- **OPTIONAL** — Strangler-fig and branch-by-abstraction for larger moves
- **MUST** — Backwards compatibility of an API and a database schema during a refactor
- **OPTIONAL** — Review as knowledge transfer; disagreeing on substance, not on style a linter should own

## 23. Documentation and Operational Writing

**Backs:** documented workflows, deployment steps and data models.

- **MUST** — One owner per fact; other documents cite it rather than restating it
- **NICE** — A document states what is true now, not how it got that way
- **MUST** — Architecture decision records: the decision, the alternatives, the trade-off accepted — the part that is worth reading a year later
- **MUST** — Runbooks that are executable under pressure: symptom, check, action, escalate
- **OPTIONAL** — Data-model documentation that stays true (generated from the schema where possible)
- **NICE** — Diagrams at one level of abstraction each; naming components consistently across every document

## 24. Defending the Design's Numbers

**Backs:** any claim about latency, cache effect or query improvement.

- **MUST** — A latency budget decomposed hop by hop, and knowing which hop dominates
- **MUST** — Cached vs uncached paths, the hit ratio the budget assumes, and where the p95 actually falls
- **MUST** — What was measured, at which percentile, over what window, on what data volume
- **MUST** — The baseline and why it is comparable; confounders (a warm buffer pool, a different query mix, a change shipped in the same release)
- **MUST** — Percentiles vs averages, and p50 gains hiding p99 regressions
- **MUST** — Verifying a query plan against realistic volume before quoting a figure, and being willing to say what the measurement does not prove
