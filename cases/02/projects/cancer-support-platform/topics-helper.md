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

**How to use it.** For each topic, be able to (a) say what it is in two sentences, (b) name the trade-off it buys and what it costs, (c) point at where it shows up in this system. A topic you can only define is not yet known.

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
- **OPTIONAL** — Coupling and cohesion; afferent/efferent dependency direction
- **MUST** — Bounded context and aggregate — where a transaction may and may not span
- **MUST** — Criteria that justify extracting a service: independent release cadence, different hardware (GPU), different failure domain — not "it feels big"
- **NICE** — Distributed monolith as the failure mode: services that must deploy together
- **MUST** — Cost of extraction: network calls, partial failure, no shared transaction, versioned contracts, on-call surface
- **NICE** — The strangler-fig pattern for extracting an existing module incrementally
- **MUST** — Why a fourth module (records) was split from clinical content: different consistency and audit obligations behind the same code path is the defect

## 2. Async Python and FastAPI Runtime Mechanics

**Backs:** event-driven FastAPI services; moving core services to Python 3.14.

- **MUST** — [ASGI](https://asgi.readthedocs.io/en/latest/ "Asynchronous Server Gateway Interface — Standard interface between asynchronous Python web servers and applications") vs WSGI; how uvicorn/gunicorn workers, the event loop and the thread pool actually run your handlers
- **MUST** — async/await, coroutines, tasks, cancellation, timeouts (asyncio.timeout)
- **MUST** — The blocking-call trap: a sync DB driver or CPU work inside an async handler stalls the whole loop; run_in_executor / threadpool as the escape hatch
- **NICE** — Structured concurrency: gather vs TaskGroup, exception propagation
- **NICE** — Backpressure and concurrency limits; why unbounded fan-out melts a pod
- **MUST** — FastAPI specifics: dependency injection and its caching, routers, lifespan, middleware order, exception handlers, BackgroundTasks vs a real queue
- **MUST** — [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") v2: validation vs serialization, model_config (extra=forbid), validators, discriminated unions, settings loading, performance of the Rust core, and why the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") doc is a build artefact rather than a doc
- **MUST** — Python 3.14 migration concerns generally: deprecations, C-extension and wheel availability, free-threaded/[GIL](https://wiki.python.org/moin/GlobalInterpreterLock "Global Interpreter Lock — CPython mechanism that lets only one thread execute Python bytecode at a time") discussion, per-interpreter changes
- **MUST** — [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects"): lockfile semantics, resolution, groups, why a lockfile removes the "works in one module, breaks in another" class of deploy surprise

## 3. REST API Design Under Load and Under Retry

**Backs:** [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") APIs for patient and clinician planes; the 202-accepted diary path.

- **MUST** — Resource modelling, URI design, versioning strategy (/api/v1) and how a breaking change is actually rolled out
- **MUST** — Status code semantics that matter here: 202 Accepted and what the client is promised, 409, 412, 422, 503 with Retry-After
- **MUST** — Idempotency keys: storage, [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"), replaying the stored response, why the cache is an optimisation and a natural key in the database is the guarantee
- **MUST** — Cursor/keyset pagination vs offset — and why offset dies on a 110M-row table
- **NICE** — Error contracts: [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details, machine-readable error codes
- **NICE** — Contract-first vs code-first; contract tests against the OpenAPI document
- **MUST** — Rate limiting semantics: per-subject vs per-IP, token bucket vs sliding window, and why a hospital behind one [NAT](https://datatracker.ietf.org/doc/html/rfc3022 "Network Address Translation — Maps multiple private addresses to a shared public address") must not rate-limit itself
- **NICE** — Request correlation: request id, [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") traceparent, propagation obligations

## 4. Authentication: OAuth 2.0, OIDC, JWT, Entra ID

**Backs:** Azure Entra ID [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") authentication; two identity planes.

- **MUST** — [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") roles and grants: authorization code + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), client credentials, refresh; why implicit and ROPC are dead
- **MUST** — [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") on top of OAuth2: id_token vs access_token, claims, scopes, audiences
- **MUST** — JWT anatomy: header/kid, claims, [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") signing, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") endpoint, key rotation and the overlap window; local verification vs introspection round-trip
- **MUST** — Audience separation as an authorization boundary — a clinician token rejected on a patient route before application code runs
- **MUST** — Token lifetime as a revocation window; refresh rotation, reuse detection, denylists, and what "revoked" really means with stateless tokens
- **NICE** — Where to store tokens in a browser: HttpOnly/Secure/SameSite cookies, CSRF
- **MUST** — Validating twice (gateway and service) — why the edge is a filter, never the authority
- **OPTIONAL** — [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity"), conditional access, and identity proofing at enrolment

## 5. SCIM 2.0 and Directory-Driven Lifecycle

**Backs:** SCIM 2.0 so clinician accounts stay provisioned from the hospital directory and stay off the patient portal.

- **MUST** — The SCIM object model: /Users, /Groups, ServiceProviderConfig, Schemas, core and enterprise attributes, externalId vs id
- **MUST** — PATCH operation semantics (add/replace/remove, path filters) and why they are the hard part of a compliant implementation
- **OPTIONAL** — Filtering, pagination and sorting the spec requires
- **MUST** — Deprovisioning: active:false vs DELETE; what must happen transactionally on the platform side (closing every open care relationship)
- **MUST** — Idempotency and ordering of provisioning calls; serialization locks per directory object
- **MUST** — Failure handling: a silently failed sync is access that should have ended and has not — which is why it pages
- **OPTIONAL** — Just-in-time provisioning vs SCIM; SAML/OIDC claims mapping as alternatives
- **OPTIONAL** — Testing against a real Entra ID tenant vs a mock; the compliance test suites

## 6. Authorization: RBAC, ABAC, and PostgreSQL Row-Level Security

**Backs:** clinician/care-team access to only their patients; identity module.

- **MUST** — [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") for capability vs [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") for reach — why roles alone cannot express "this clinician, this patient, right now"
- **MUST** — Relationship-based access control; the care relationship as the single definition of "may this clinician see this patient"
- **MUST** — Temporal authorization: tstzrange, [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") exclusion constraints, why history is not overwritten and access has an end
- **MUST** — [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user"): policies, USING vs WITH CHECK, FORCE ROW LEVEL SECURITY, BYPASSRLS, the owning role vs the application role
- **MUST** — The pooling trap: SET LOCAL inside the transaction vs SET; a transaction-mode pooler reusing a backend leaks one caller's identity into the next
- **NICE** — Keeping the predicate visible to the planner so partition pruning survives
- **MUST** — Defence in depth: application check first line, database second, and why the ordering matters (a forgotten scope returns zero rows, not another patient)
- **MUST** — IDOR / broken object-level authorization as the bug class this removes
- **NICE** — Break-glass: reason string, time-boxed grant, notification, review
- **NICE** — Separation of duties (author cannot approve their own content)

## 7. PostgreSQL Data Modelling for a Clinical Record

**Backs:** designed PostgreSQL schemas; migrated data access and tightened [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database").

- **MUST** — Normalisation and when denormalisation is deliberate rather than lazy
- **MUST** — Keys: uuid vs bigint, natural vs surrogate, uniqueness as an invariant enforced by the schema instead of by retry logic
- **MUST** — Constraints as correctness: unique, partial unique, check, exclusion, FK actions; unique (patient_id, recorded_for) absorbing at-least-once delivery
- **MUST** — jsonb vs columns vs [EAV](https://en.wikipedia.org/wiki/Entity%E2%80%93attribute%E2%80%93value_model "Entity Attribute Value — Schema pattern for storing entities whose attributes vary and are not known in advance") — what jsonb costs (statistics, TOAST, write amplification) and what a [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") index over it buys
- **NICE** — Temporal and append-only tables; audit tables with UPDATE/DELETE revoked
- **MUST** — Normalising an ordering column (timeline_at) across heterogeneous sources so one index shape and one deterministic cursor serve a union
- **NICE** — Soft delete: why it is refused here, and consent-based restriction instead
- **NICE** — Searchable encryption: deterministic vs non-deterministic encryption, [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key") blind index, key separation, and what a blind index leaks
- **MUST** — Declarative partitioning: range by month, pruning, attach/detach as a metadata operation, constraints and index inheritance, partition-wise joins
- **NICE** — [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") vs B-tree when physical order matches insert order
- **NICE** — Schema-per-module in one database; migration ownership across two writers

## 8. Query Performance and Execution Plans

**Backs:** cutting query latency by 35%; tightening SQL for timeline and care-team views.

- **MUST** — EXPLAIN (ANALYZE, BUFFERS): scan types, join strategies, rows-estimated vs rows-actual, the meaning of a bad estimate
- **OPTIONAL** — Planner statistics, n_distinct, extended statistics, ANALYZE cadence
- **MUST** — Index selection: composite index column order, leading-column rule, index-only scans and the visibility map, partial indexes for hot subsets
- **MUST** — Access-pattern-first indexing; every index is a write tax on inserts
- **MUST** — Data access patterns and their pathologies: N+1 queries, SELECT *, implicit casts defeating an index, functions on the indexed column, OR-chains
- **MUST** — UNION ALL with LIMIT pushed into each branch vs materialise-then-sort
- **MUST** — Keyset pagination cursors over a tuple; ties broken deterministically
- **MUST** — Locking and concurrency: [MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row"), isolation levels, FOR UPDATE SKIP LOCKED for queue-like claiming, lock waits, deadlock detection
- **NICE** — Bloat, autovacuum, HOT updates, index maintenance
- **MUST** — Connection pooling: server connection limits, pgbouncer pool modes and what each mode forbids (prepared statements, session GUCs, advisory locks)
- **MUST** — Measuring rather than asserting: pg_stat_statements, auto_explain, a baseline before the change and the same query shape after

## 9. SQLAlchemy 2 and Alembic

**Backs:** migrated data access to [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") 2; [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") in the deploy path.

- **MUST** — Core vs [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") and when the generated plan matters more than the mapping
- **MUST** — The 2.0 style: select() everywhere, typed Mapped[] annotations, removal of the legacy Query [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), what a 1.x → 2.0 migration actually breaks
- **MUST** — Session as unit of work: identity map, flush vs commit, expire_on_commit, session lifecycle bound to a request
- **MUST** — Lazy loading and the N+1 it creates; selectinload / joinedload / raiseload
- **MUST** — Async engine and session; asyncpg driver differences; greenlet boundary
- **NICE** — Bulk operations, insert().on_conflict_do_update(), returning()
- **NICE** — Alembic: revision graph, branches and merges, autogenerate's blind spots (server defaults, index changes, enums, data migrations)
- **MUST** — Expand/contract migrations: why the previous image must run against the new schema, CREATE INDEX CONCURRENTLY, lock-taking DDL and statement timeouts
- **OPTIONAL** — Running migrations as a pre-sync hook rather than from an application pod

## 10. Elasticsearch Index and Query Design

**Backs:** designed Elasticsearch indexes for clinical content search.

- **MUST** — Inverted index, analysers, tokenizers, filters; stemming, stopwords, synonyms, and why a clinical synonym set is domain work not engineering work
- **MUST** — Mappings: text vs keyword, multi-fields, dynamic mapping hazards, date types
- **MUST** — Query DSL: filter context (cacheable, unscored) vs must (scored), bool composition, term vs match, highlighting
- **NICE** — Relevance: [BM25](https://en.wikipedia.org/wiki/Okapi_BM25 "Best Matching 25 — Ranking function that scores how relevant a document is to a search query") basics, boosting, why "relevance improved" needs an evaluation set, not an anecdote
- **MUST** — Shards, replicas, sizing, and why a small index makes a full rebuild routine
- **NICE** — Aliases and zero-downtime reindex; reindex as the rollback for a model change
- **MUST** — Bulk indexing: batch size, flush interval, refresh_interval vs the 1 s default, segment merge pressure, near-real-time semantics
- **NICE** — Search authorization: mandatory scope filters carried in every document, and the rule that search must never become the path around the record layer
- **MUST** — The freshness budget composed of relay + flush + refresh, not one knob
- **MUST** — When PostgreSQL full-text search is enough and when it is not

## 11. Messaging with RabbitMQ: AMQP and MQTT

**Backs:** event-driven services with [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications") and [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") for check-ins and reminders.

- **MUST** — AMQP 0-9-1 model: exchanges (direct/topic/fanout/headers), bindings, routing keys, queues, consumers; publisher confirms and transactions
- **MUST** — Quorum queues vs classic mirrored queues (removed in RabbitMQ 4): raft replication, availability and the cost
- **MUST** — Alternate exchanges: a [QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Quality of Service — Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")-1 publish that routes to no queue is still ACKed — the silent-loss trap the alternate exchange converts into a visible dead letter
- **MUST** — Dead-letter exchanges, TTLs, delayed messages, poison-message handling
- **MUST** — Prefetch (QoS), consumer acknowledgement modes, redelivery
- **MUST** — MQTT: QoS 0/1/2 semantics, clean vs persistent sessions, client-side offline queueing, retained messages, last will, topic wildcards
- **MUST** — MQTT-to-AMQP bridging: topic separator translation, the target exchange setting, and per-connection (not per-publish) authentication with a token that expires mid-connection
- **MUST** — Delivery guarantees in plain terms: at-most-once, at-least-once, why exactly-once is a property of the consumer, not the broker
- **NICE** — Ordering guarantees and when you actually need them

## 12. Celery and Scheduled Work

**Backs:** taking check-ins and reminders off the request path.

- **MUST** — Broker vs result backend; what a result backend is and is not for
- **MUST** — task_acks_late, visibility timeout, prefetch multiplier, worker concurrency models (prefork vs gevent vs threads)
- **MUST** — Retries: backoff, jitter, max attempts, giving up into a dead-letter queue
- **MUST** — Idempotent task design; a task is a message that may run twice
- **MUST** — Queue separation by workload so one flood cannot starve another
- **MUST** — [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") beat as a singleton: leader election / RedBeat lock, last-tick liveness, and why the state machine belongs in the database so a stopped scheduler delays work rather than losing it
- **NICE** — Graceful shutdown, warm shutdown, preStop draining, long-task sizing
- **MUST** — Celery vs a raw AMQP consumer: work we schedule and retry for ourselves vs facts we publish for others — the boundary rule, stated once

## 13. Event-Driven Architecture and the Transactional Outbox

**Backs:** event-driven services; keeping the search index and integrations correct.

- **MUST** — The dual-write problem: commit succeeds, publish fails, nothing detects it
- **MUST** — Transactional outbox: event row in the same transaction, relay, published_at, the relay's only query and its index
- **OPTIONAL** — Change data capture as the alternative and its operational cost
- **MUST** — At-least-once delivery and idempotent consumers: dedupe on event id, monotonic revision guards against out-of-order redelivery
- **NICE** — Command vs event; choreography vs orchestration; saga and compensation
- **MUST** — Eventual consistency made observable: lag as a metric with an [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), backlog age alerts, and a reconciliation job as the backstop for a lost event
- **NICE** — Read-your-writes routing for the party who just wrote
- **NICE** — Schema evolution of events; consumer-driven contracts

## 14. Caching with Redis

**Backs:** [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") in the stack for sessions, timelines, JWKS, rate limits.

- **MUST** — Cache-aside vs write-through vs write-behind, and choosing per data shape: write-through only for immutable versioned content
- **MUST** — Invalidation: event-driven purge with TTL as the backstop, version-suffixed keys that make a stale key unreachable
- **NICE** — Stampede protection: single-flight locks, probabilistic early expiry, stale-while-revalidate
- **NICE** — Hit ratio arithmetic: what the origin load becomes when the cache is empty
- **MUST** — Key design and namespacing; patient-scoped keys, and the rule that nothing identifiable is cached at a layer blind to the requester (why the gateway response cache is off by policy)
- **MUST** — TTL strategy, eviction policies, memory sizing, hot keys
- **OPTIONAL** — Redis data structures and atomicity; Lua scripts; SETNX locks and the honest limits of distributed locking
- **MUST** — Redis as a cache, never a store; what a flush is allowed to cost
- **MUST** — Audit obligations that survive a cache hit

## 15. Transfer Learning and Fine-Tuning Hugging Face Models

**Backs:** fine-tuned Hugging Face models with transfer learning, +28% relevance.

- **MUST** — Transfer learning: pretrained encoder, task head, full fine-tune vs frozen layers vs parameter-efficient methods (LoRA/adapters) and when each is right
- **MUST** — The task shapes used here: token classification for clinical entity/code extraction, and cross-encoder reranking for retrieval
- **MUST** — Tokenizers, subword vocabularies, max sequence length, chunking long notes
- **MUST** — Training mechanics: learning rate and schedule, batch size, early stopping, class imbalance, overfitting on a small clinical corpus
- **MUST** — Evaluation that means something: held-out set, precision/recall/F1 per entity type, NDCG/MRR for reranking, a baseline to beat, statistical noise
- **MUST** — Model versioning: stamping the version on every artifact so a regression is attributable and a rollback is a reindex
- **OPTIONAL** — Serving: GPU vs CPU inference, batching, latency budgets, model warm-up, quantisation, ONNX/TorchScript
- **MUST** — Governance of training data: patient text in a corpus, de-identification, memorisation and extraction risk, lawful basis before the first tuning run

## 16. Retrieval Pipelines and LangChain Composition

**Backs:** LangChain workflows turning diagnosis and treatment context into education pages.

- **MUST** — RAG anatomy: chunking, retrieval, reranking, composition, citation assembly
- **MUST** — Retrieval methods: lexical (BM25) vs dense embeddings vs hybrid; why the retriever, not the generator, decides quality
- **MUST** — Grounding and provenance: composing only from approved passages, a citation per block, and refusing to author claims — a safety property, not a style
- **MUST** — Hallucination: what causes it and which controls actually reduce it
- **NICE** — Prompt versioning and prompt/response logging with sensitive-data rules
- **MUST** — Evaluation of a generation pipeline: golden sets, human review, regression tests on prompt or model change
- **NICE** — Human-in-the-loop review states (draft → pending_review → approved → retired) and pinning an exact version to what a patient was shown
- **MUST** — Cost, latency, and why generation belongs off the request path
- **NICE** — LangChain specifically: what it gives you (composition, retrievers, output parsing) and where hand-written glue is clearer

## 17. Azure Platform Services in This Design

**Backs:** migrated file ingestion and async notifications to Blob, Service Bus and Event Grid; Azure in the environment list.

- **MUST** — Blob Storage: containers, access tiers and lifecycle, [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") (user-delegation vs account key), direct client upload and why it keeps bytes off API pods, immutability/[WORM](https://en.wikipedia.org/wiki/Write_once_read_many "Write Once Read Many — Storage mode that prevents a written object from being modified or deleted before a retention period ends") policies and legal hold, soft delete, [ZRS](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy "Zone Redundant Storage — Replicates Azure storage data synchronously across multiple availability zones")/GRS
- **MUST** — Event Grid: BlobCreated eventing, delivery retries, dead-lettering, and the at-least-once semantics its consumers must tolerate
- **MUST** — Service Bus: queues vs topics/subscriptions, peek-lock vs receive-and-delete, lock renewal, dead-letter queues and replay, duplicate detection, sessions for ordering, scheduled messages
- **MUST** — Azure Functions: triggers and bindings, consumption vs premium plans, cold start, concurrency and scale controllers, idempotent handlers, slot swap
- **MUST** — API Management: JWT validation policy, audience routing, rate limits and quotas, versioning, and its JWKS cache being independent of yours
- **NICE** — Entra ID and Entra External ID as two tenants/two planes
- **MUST** — Workload identity federation: no static credentials in images or manifests
- **NICE** — Key Vault: secrets vs keys vs certificates, [CMK](https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys "Customer Managed Key — An encryption key the customer controls rather than the cloud provider"), soft-delete and purge protection, rotation, projection as files rather than environment variables
- **OPTIONAL** — Choosing between an Azure-native and a self-hosted equivalent, and the cost of running two brokers rather than one

## 18. Kubernetes, OpenShift and GitOps Delivery

**Backs:** deployed releases with [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") to OpenShift and [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications").

- **MUST** — Core objects: Deployment, ReplicaSet, Service, Ingress/Route, ConfigMap, Secret, Job/CronJob, StatefulSet
- **MUST** — Probes: liveness vs readiness vs startup, and the outage a wrong liveness probe causes
- **MUST** — Requests and limits, QoS classes, OOMKill, CPU throttling
- **MUST** — Rollout strategies: rolling, blue-green (a Route switch), canary, and which service earns which — model quality shows up statistically, so canary
- **NICE** — Graceful termination: preStop, terminationGracePeriodSeconds, draining workers vs killing them
- **NICE** — Autoscaling: [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on CPU and on custom/queue-depth metrics, cluster autoscaler
- **NICE** — NetworkPolicy default-deny and what it cannot see (cross-cluster hops)
- **MUST** — OpenShift specifics: SCCs, Routes, image streams, and how they differ from vanilla Kubernetes
- **MUST** — GitOps with ArgoCD: declared desired state, sync waves, pre/post-sync hooks, drift detection, rollback as a revision revert, and why no [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") job holds cluster credentials
- **NICE** — Digest-pinned images so a mutable tag cannot be swapped under a cluster
- **NICE** — Multi-cluster topology cost, and the rule that nothing on the request path lives on the second cluster

## 19. CI/CD and Quality Gates

**Backs:** GitLab CI with ruff, pyright and SonarQube gates; fixing failing jobs.

- **MUST** — Pipeline structure: stages, jobs, artifacts, caches, services containers, parallelism, needs/DAG
- **MUST** — A gate is only a gate if it can fail: proving each one blocks by making it fail on purpose
- **MUST** — ruff: lint and format, rule selection, per-file ignores, autofix in CI vs locally
- **MUST** — pyright/mypy in strict mode: gradual typing, Any leakage, third-party stubs, what strict actually forbids
- **MUST** — SonarQube: quality gate on new code, coverage thresholds, hotspots, and how a gate becomes theatre if it is bypassed
- **MUST** — Test layering: unit, contract (OpenAPI), integration against real containers, functional; why a mocked broker cannot fail the way a real one does
- **NICE** — Build and supply chain: digest pinning, image scanning, dependency audit, SBOM, reproducibility
- **MUST** — Migration ordering relative to deploy, and rollback that needs no down-migration
- **MUST** — Debugging a failing pipeline: reproducing the runner environment, exit codes vs output text, the pipe that swallows a status

## 20. Observability: Metrics, Logs, Traces

**Backs:** instrumented Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production"), Prometheus and Kibana on API and consumer latency and error rates.

- **MUST** — The three pillars and what each is bad at; when a trace is the only tool
- **MUST** — Prometheus model: counters, gauges, histograms and summaries, labels and cardinality, scrape vs push, recording and alerting rules, [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/ "Prometheus Query Language — Queries and aggregates time series metrics collected by Prometheus") basics, histogram_quantile and what a p95 from a histogram really means
- **NICE** — RED and USE method for choosing what to measure
- **MUST** — Distributed tracing: spans, context propagation, W3C traceparent, sampling strategies (head vs tail, always-on for errors), and propagation across queue boundaries — including transports with no header slot (MQTT 3.1.1)
- **OPTIONAL** — Elastic APM agent auto-instrumentation and its blind spots
- **MUST** — Structured logging: [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"), correlation fields, log levels, and a redaction filter that drops sensitive fields at the formatter
- **MUST** — Logs are for operators, audit is for the regulator — conflating them makes log retention silently become audit policy
- **MUST** — Detecting silent failures: lag and backlog-age metrics that alert when nothing is erroring
- **MUST** — [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health")/SLO/error budget, burn-rate alerting, page vs ticket, alert fatigue

## 21. Reliability, Failure Modes and Recovery

**Backs:** availability targets, reminder timeliness, deploy and incident runbooks.

- **NICE** — Availability arithmetic; where a 99.9% budget actually goes
- **NICE** — Single points of failure and honest acceptance of one
- **MUST** — [HA](https://en.wikipedia.org/wiki/High_availability "High Availability — System design goal of remaining operational despite component failure") and failover: zone redundancy, failover time as a budget line, connection storms after failover and pooling as the mitigation
- **MUST** — [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") and [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") as separate promises; [PITR](https://www.postgresql.org/docs/current/continuous-archiving.html "Point in Time Recovery — Restores a database to a specific past moment using base backups and archived logs"); a backup that has never been restored is an assumption, not a control
- **NICE** — Rebuildable derived stores as a recovery strategy (index rebuild from source)
- **NICE** — Graceful degradation: a labelled fallback path beats an error page
- **MUST** — Retries done properly: idempotency, exponential backoff with jitter, budget caps, circuit breakers, timeouts everywhere
- **MUST** — Queue-backed work as a shock absorber; the state machine in the database so outages delay rather than lose
- **MUST** — Runbooks, incident review, and what "22% fewer missed reminders" requires: a delivery-attempt table so the question is a query, not a log grep

## 22. Security and Regulatory Compliance for Health Data

**Backs:** identity work, data protection, and the clinical setting of the product.

- **MUST** — Threat modelling: trust boundaries, STRIDE, and the fact that the dangerous adversary here is authenticated
- **MUST** — [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") API Top 10, especially broken object-level and function-level authorization
- **MUST** — Encryption at rest: TDE, customer-managed keys, envelope encryption, key rotation; what encryption at rest does and does not protect against
- **NICE** — Field-level encryption trade-offs and the honest position that data used by every query cannot be meaningfully field-encrypted
- **MUST** — [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection"): versions, cipher choice, certificate verification modes (verify-full), mTLS, certificate issuance and rotation without a service mesh (cert-manager)
- **NICE** — Network controls: private endpoints, VNet peering, NSGs, default-deny NetworkPolicy and egress control
- **MUST** — Secrets management and the elimination of static credentials
- **MUST** — Audit trail design: synchronous vs asynchronous, append-only enforcement, partitioning, retention and immutable archive; the read-availability cost of auditing reads synchronously
- **NICE** — Detection rules over the audit stream that name a specific misuse
- **MUST** — [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data"): lawful basis, Article 9 special-category data, consent versioning and withdrawal, minimisation, purpose limitation, [DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them"), residency, [DPIA](https://gdpr-info.eu/art-35-gdpr/ "Data Protection Impact Assessment — GDPR process for assessing privacy risk before high-risk data processing")
- **MUST** — Erasure vs statutory retention: which wins for a medical record and how that is stated to the patient
- **OPTIONAL** — [HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") mapping of the same technical safeguards; [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 27001/27701 framing

## 23. Defending the Numbers

**Backs:** "35% lower query latency", "28% higher relevance", "22% fewer missed reminders".

- **MUST** — What was measured, at which percentile, over what window, on what traffic
- **MUST** — The baseline: how it was captured and why it is comparable
- **MUST** — Confounders: a cache added at the same time, a data-volume change, a different query mix, a warm buffer pool
- **MUST** — Percentiles vs averages; why p50 improvements can hide p99 regressions
- **MUST** — For relevance: the evaluation set, the metric, who labelled it, whether the gain survives a second model version
- **MUST** — For reminders: the denominator — what counts as "missed", and how it became observable at all
- **MUST** — Being able to say "measured this way, and here is what it does not prove"
