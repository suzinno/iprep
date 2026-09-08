# Retail Software Aggregation Platform — System Design Overview

A B2B marketplace where software vendors publish POS, inventory, loyalty and related retail tools, and category managers at retail chains compare features, pricing and coverage, shortlist candidates, and open a direct conversation with a vendor without running a separate sourcing round. The architecture is built around two problems that are genuinely hard at this scale, and one that is not: product metadata has no fixed shape across categories yet must remain filterable, and competing vendors and competing retail groups share one platform and must never see each other's data — while raw throughput, at a modelled 35 QPS peak, is unremarkable. The resolution is a **relational spine in PostgreSQL with a schemaless body in MongoDB, joined by an asynchronously maintained search projection**, six clean-architecture services on AKS that keep listing changes out of connection and billing flows, Redis as an expendable cache on the read path, and a transactional outbox feeding Azure Service Bus so that publishing a listing never fails because a downstream consumer is unavailable.

## Sections

| File | Contents |
|---|---|
| [01-requirements.md](01-requirements.md) | Scoping decision on "banking" vs. retail, actors, functional and non-functional requirements, CAP positioning, and the DAU/QPS/5-year storage estimates every later capacity decision is held to |
| [02-high-level-design.md](02-high-level-design.md) | Service decomposition, architecture and sequence diagrams, the REST API surface, and the technology mapping — **the single source of truth for component names and technology choices** |
| [03-data-modeling.md](03-data-modeling.md) | The PostgreSQL/MongoDB split, full schema and index declarations, blob layout, partitioning, cross-store consistency rules, and retention |
| [04-deep-dive.md](04-deep-dive.md) | Sync vs. async patterns, the event catalogue, the decomposed latency budget, four named bottlenecks with mitigations, SPOF analysis, and the explicit trade-off register |
| [05-reliability.md](05-reliability.md) | Access-pattern-driven indexing, the three-layer caching strategy with invalidation rules, SLIs/SLOs, logging, tracing, alerting, and the GitLab CI/CD and Terraform automation |
| [06-security.md](06-security.md) | Threat model, OAuth2/JWT identity, the three-layer authorization model, data protection, cloud identity and secrets, GDPR and PCI-DSS posture, and perimeter defense |

## Technology Stack and Roles

| Technology | Role |
|---|---|
| **Python / FastAPI** | All six services and three Celery worker deployments; async request handling for an I/O-bound workload |
| **Pydantic** | Request/response contracts, OpenAPI generation, config, and validation of vendor metadata against per-category facet schemas |
| **SQLAlchemy** | ORM for domain writes; Core for the catalog search query where the plan matters |
| **Alembic** | Migration history, expand/contract only, run before deploy so rollback stays possible |
| **Pytest** | Unit, integration (against real Postgres/Mongo/Redis) and functional API tests; the CI gate |
| **Celery** | Work queues between Python processes: `imports`, `indexing`, `notifications` |
| **PostgreSQL** (`postgres-core`) | System of record — vendors, retailers, stores, listing spine, shortlists, connections, billing, audit — plus the `product_listing_facets` search projection. Primary + one read replica |
| **MongoDB** (`mongo-catalog`) | Per-category product metadata with no fixed column set, immutable revisions, facet schemas, import staging |
| **Redis** (`redis-cache`) | Hot listings, search pages, facet counts, JWKS, rate-limit counters, idempotency keys — cache-aside and fully expendable |
| **Redis** (`redis-broker`) | Celery transport, separate instance from the cache |
| **OAuth2 / JWT** | Authorization code + PKCE for humans, client credentials for vendor integrations; RS256 tokens carrying account type, org and scopes |
| **Docker / Docker Compose** | Image build; Compose reproduces the full data-store set for local development and CI integration tests |
| **Kubernetes (AKS)** | Runtime for nine deployments; HPA on CPU and on Celery queue depth |
| **Terraform** | Every Azure resource, state in a locked Blob container, applied only from CI |
| **GitLab / GitLab CI** | Source of truth and the only path to production; canary for `catalog-service`, rolling elsewhere |
| **Azure Blob Storage** (`blob-media`) | Listing media, datasheets, import files, admin console bundle, Terraform state |
| **Azure Service Bus** | `sb-catalog-events`, `sb-connection-events`, `sb-notification-dispatch` — durable fan-out across boundaries |
| **Azure Functions** | `fn-media-process` (blob-triggered derivatives), `fn-notify-dispatch` (queue-triggered delivery) |
| **Azure Monitor / App Insights** | Metrics, structured logs, OpenTelemetry traces, and the alerts on API errors and job failures |
| **Azure API Management** | Edge routing, per-subscription quotas, JWT pre-validation |
| **Azure Front Door + WAF** | *Addition beyond the brief's stack* — TLS termination, CDN, OWASP WAF, L7 DDoS absorption |
| **Azure Key Vault** | *Addition beyond the brief's stack* — JWT signing keys, customer-managed encryption keys, service secrets |
| **Linux** | Container base images and AKS node pools |

## Requirement Traceability

Every responsibility from `inputs.txt`, mapped to where the design addresses it.

| # | Responsibility | Addressed in |
|---|---|---|
| 1 | Marketplace backend with clean architecture; catalog, vendor and retailer split so listing changes do not spill into connection and billing flows | `02` — Service Decomposition (six services, `connection-service` and `billing-service` isolated); `04` — Trade-offs (isolation vs. operational complexity) |
| 2 | MongoDB schemas for product metadata without a fixed column set | `03` — MongoDB Collections, `facet_schemas` as the governing contract |
| 3 | PostgreSQL schemas for vendors, retailers and product listings used by search, shortlists and the admin workspace | `03` — PostgreSQL Schema, `product_listing_facets` as the search read-model |
| 4 | Admin panel for vendors, retail chains, stores and software products | `02` — API Design, `/v1/admin/*` on the same versioned contract; `06` — the `platform` account type and audited scope bypass |
| 5 | OAuth2 and JWT authentication keeping catalog and connection APIs behind the right account type | `06` — Identity & Access; Authorization (the `act` claim is the first of three checks) |
| 6 | FastAPI REST APIs for catalog browse and vendor–retailer connection | `02` — API Design and Request Flows; `03` — `connection_request` / `connection_thread` / `connection_message` |
| 7 | Optimized SQL queries and indexes for catalog search and listing filters | `05` — Read/Write Optimizations; `04` — Bottleneck 1, with the plan verification callout |
| 8 | Cached hot catalog reads in Redis to cut database load on popular listings | `05` — Caching Strategy (cache-aside, revision-keyed); `04` — Bottleneck 2 (stampede protection) |
| 9 | Celery for catalog imports and notification jobs so they do not block the API | `04` — Communication Patterns and Bottleneck 3; `02` — the three worker deployments |
| 10 | Automated GitLab CI pipelines for test and deploy | `05` — Automation: CI/CD and Deployment |
| 11 | Azure infrastructure provisioned with Terraform | `05` — Infrastructure as Code |
| 12 | Services deployed to Azure AKS with Docker and Kubernetes | `05` — Automation (canary/rolling, drain, autoscaling); `02` — Architecture Diagram |
| 13 | Azure Functions, Blob Storage and Service Bus for catalog updates and vendor–retailer notifications | `02` — Technology Mapping ("why two messaging systems"); `04` — Event Catalogue; `03` — Blob Layout |
| 14 | Monitored with Azure Monitor, tracking API errors and job failures on catalog and connection flows | `05` — Telemetry and Alerting |
| 15 | Reviewed pull requests and refactored catalog and auth modules | **No architectural implication** — an engineering practice, not system behaviour. Its nearest structural trace is that the module boundaries in `02` are what make catalog and auth independently refactorable |
| 16 | Unit, integration and functional tests with Pytest for catalog, auth and connection paths | `05` — Automation, where the test stages are the blocking CI gate and integration tests run against real data stores |
| 17 | Documented workflows, deployment steps and data models | **No architectural implication** — this document set is the artefact the responsibility describes |
| 18 | Administered Linux hosts for production and development | **No architectural implication** — an operations practice. It touches the design only as AKS node-pool image maintenance, noted in `02`'s technology mapping |

## Open Items Flagged in the Design

Each is marked in place with its rationale; collected here so none is discovered late.

**Verify Before Build** — claims that may be false as written, listed with the file that owns them:

- MongoDB deployed as Cosmos DB for MongoDB vCore may not support the aggregation stages and text index types the workers use (`02`).
- The 45 ms search figure assumes the planner combines `GIN` indexes into a bitmap `AND` rather than degrading to a sequential scan (`04`).
- Celery on Redis does not have true acknowledgement semantics; import durability depends on a visibility-timeout behaviour that needs a kill test (`04`).
- OpenTelemetry trace continuity across Service Bus and Celery depends on instrumentation versions actually propagating `traceparent` (`05`).
- APIM's JWKS cache and the application's `authz:jwks` cache refresh independently, which can break a signing-key rotation (`06`).

**Deep Dive Reference** — topics needing research or a prototype before build: marketplace liquidity instrumentation (`01`), facet schema evolution and versioning (`03`), multilingual text search quality (`05`), and splitting the CI deploy identity's privilege (`06`).

**Decisions made against a defensible alternative**, each stated with its cost in the file that owns it: retail rather than banking scope (`01`), six services rather than a modular monolith (`02`), two data stores rather than Postgres `JSONB` alone (`02`), application-layer tenant filtering rather than PostgreSQL RLS (`06`), no service mesh and therefore no internal mTLS (`06`), and retaining message bodies through a GDPR erasure request (`06`).
