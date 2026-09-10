# Retail Software Aggregation Platform — System Design Overview

A [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") marketplace where software vendors publish [POS](https://en.wikipedia.org/wiki/Point_of_sale "Point of Sale — The system and moment at which a retail transaction is completed"), inventory, loyalty and related retail tools, and category managers at retail chains compare features, pricing and coverage, shortlist candidates, and open a direct conversation with a vendor without running a separate sourcing round. The architecture is built around two problems that are genuinely hard at this scale, and one that is not: product metadata has no fixed shape across categories yet must remain filterable, and competing vendors and competing retail groups share one platform and must never see each other's data — while raw throughput, at a modelled 35 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") peak, is unremarkable. The resolution is a **relational spine in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") with a schemaless body in [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"), joined by an asynchronously maintained search projection**, six clean-architecture services on [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") that keep listing changes out of connection and billing flows, [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") as an expendable cache on the read path, and a transactional outbox feeding Azure Service Bus so that publishing a listing never fails because a downstream consumer is unavailable.

## Sections

| File | Contents |
|---|---|
| [01-requirements.md](01-requirements.md) | Actors, functional and non-functional requirements, [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning, and the [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day")/QPS/5-year storage estimates every later capacity decision is held to |
| [02-high-level-design.md](02-high-level-design.md) | Service decomposition, architecture and sequence diagrams, the [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") surface, and the technology mapping — **the single source of truth for component names and technology choices** |
| [03-data-modeling.md](03-data-modeling.md) | The PostgreSQL/MongoDB split, full schema and index declarations, blob layout, partitioning, cross-store consistency rules, and retention |
| [04-deep-dive.md](04-deep-dive.md) | Sync vs. async patterns, the event catalogue, the decomposed latency budget, four named bottlenecks with mitigations, [SPOF](https://en.wikipedia.org/wiki/Single_point_of_failure "Single Point of Failure — A component whose failure alone can bring down the whole system") analysis, and the explicit trade-off register |
| [05-reliability.md](05-reliability.md) | Access-pattern-driven indexing, the three-layer caching strategy with invalidation rules, SLIs/SLOs, logging, tracing, alerting, and the GitLab [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") and [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") automation |
| [06-security.md](06-security.md) | Threat model, [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf")/[JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") identity, the three-layer authorization model, data protection, cloud identity and secrets, [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") and [PCI-DSS](https://www.pcisecuritystandards.org/ "Payment Card Industry Data Security Standard — Security requirements for organizations that handle payment card data") posture, and perimeter defense |

## Technology Stack and Roles

| Technology | Role |
|---|---|
| **Python / [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation")** | All six services and three [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") worker deployments; async request handling for an I/O-bound workload |
| **[Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime")** | Request/response contracts, [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") generation, config, and validation of vendor metadata against per-category facet schemas |
| **[SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries")** | [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") for domain writes; Core for the catalog search query where the plan matters |
| **[Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy")** | Migration history, expand/contract only, run before deploy so rollback stays possible |
| **Pytest** | Unit, integration (against real Postgres/Mongo/Redis) and functional API tests; the CI gate |
| **Celery** | Work queues between Python processes: `imports`, `indexing`, `notifications` |
| **PostgreSQL** (`postgres-core`) | System of record — vendors, retailers, stores, listing spine, shortlists, connections, billing, audit — plus the `product_listing_facets` search projection. Primary + one read replica |
| **MongoDB** (`mongo-catalog`) | Per-category product metadata with no fixed column set, immutable revisions, facet schemas, import staging |
| **Redis** (`redis-cache`) | Hot listings, search pages, facet counts, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), rate-limit counters, idempotency keys — cache-aside and fully expendable |
| **Redis** (`redis-broker`) | Celery transport, separate instance from the cache |
| **OAuth2 / JWT** | Authorization code + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") for humans, client credentials for vendor integrations; [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") tokens carrying account type, org and scopes |
| **Docker / Docker Compose** | Image build; Compose reproduces the full data-store set for local development and CI integration tests |
| **[Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") (AKS)** | Runtime for nine deployments; [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on CPU and on Celery queue depth |
| **Terraform** | Every Azure resource, state in a locked Blob container, applied only from CI |
| **GitLab / GitLab CI** | Source of truth and the only path to production; canary for `catalog-service`, rolling elsewhere |
| **Azure Blob Storage** (`blob-media`) | Listing media, datasheets, import files, admin console bundle, Terraform state |
| **Azure Service Bus** | `sb-catalog-events`, `sb-connection-events`, `sb-notification-dispatch` — durable fan-out across boundaries |
| **Azure Functions** | `fn-media-process` (blob-triggered derivatives), `fn-notify-dispatch` (queue-triggered delivery) |
| **Azure Monitor / App Insights** | Metrics, structured logs, OpenTelemetry traces, and the alerts on API errors and job failures |
| **Azure API Management** | Edge routing, per-subscription quotas, JWT pre-validation |
| **Azure Front Door + [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application")** | *Addition beyond the brief's stack* — [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") termination, [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency"), [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") WAF, [L7](https://en.wikipedia.org/wiki/OSI_model "Layer 7 — The application layer of the OSI model, where content-aware filtering such as a web application firewall operates") [DDoS](https://en.wikipedia.org/wiki/Denial-of-service_attack "Distributed Denial of Service — Attack that floods a system with traffic from many sources to make it unavailable") absorption |
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
| 7 | Optimized [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") queries and indexes for catalog search and listing filters | `05` — Read/Write Optimizations; `04` — Bottleneck 1, with the plan verification callout |
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
- [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway")'s JWKS cache and the application's `authz:jwks` cache refresh independently, which can break a signing-key rotation (`06`).

**Deep Dive Reference** — topics needing research or a prototype before build: marketplace liquidity instrumentation (`01`), facet schema evolution and versioning (`03`), multilingual text search quality (`05`), and splitting the CI deploy identity's privilege (`06`).

**Decisions made against a defensible alternative**, each stated with its cost in the file that owns it: six services rather than a modular monolith (`02`), two data stores rather than Postgres `JSONB` alone (`02`), application-layer tenant filtering rather than PostgreSQL [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") (`06`), no service mesh and therefore no internal mTLS (`06`), and retaining message bodies through a GDPR erasure request (`06`).
