# Personalized Cancer Support Platform
## System Design Overview

---

## Executive Summary

This document set reverse-engineers the architecture of a platform serving people diagnosed with cancer and the clinicians who follow them. Patients log daily wellbeing, read guidance specific to their diagnosis and treatment, and keep appointments, prescriptions, visit notes, and documents in one record; the care team sees the same record without a phone call or a paper pack. The system is a **[FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") modular monolith (`care-core`) with four modules — `diary`, `records`, `clinical-content`, `identity` — plus two services extracted for reasons that survive scrutiny**: `scim-provisioning-svc`, whose release cadence belongs to the hospital directory, and `clinical-nlp-svc`, which needs GPUs and ships on a model's schedule. [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") is the system of record and the place authorization is enforced, with [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") holding versioned education content, Elasticsearch serving search, and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") carrying nothing durable. Work leaves the request path through [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") — [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications") for domain events, [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") for check-in ingress from patient devices — and crosses into Azure Service Bus at the boundary where files and notifications are handled by Functions. [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") deploys from GitLab [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") to Azure Red Hat OpenShift and [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure").

Peak load is roughly **200 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second")**. The design says so explicitly and refuses to buy sharding, meshes, or a microservice fleet against a number that does not require them. Where cost is taken anyway — a second broker, a second cluster, a second index — the file that takes it names the price and the condition that would reverse it. Two properties are treated as non-negotiable and shape everything else: **patient-record authorization lives in the database as row-level security**, so a forgotten scope in application code returns nothing rather than someone else's record; and **generated patient guidance is assembled only from clinician-approved, cited passages**, which measurably narrows what a page can say and is meant to.

---

## Section Index

| # | Section | File | Summary |
|---|---|---|---|
| 1 | [Requirement Clarification & Scoping](./01-requirements.md) | `01-requirements.md` | Audiences and their opposing access models, functional and non-functional requirements, per-path [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning, and the scale baseline every later decision is proportional to (~25K patient [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day"), ~200 QPS peak, ~1 TB hot relational + ~12 TB documents over 5 years). |
| 2 | [High-Level Design](./02-high-level-design.md) | `02-high-level-design.md` | Service topology and the naming every other file uses, architecture diagram, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") contracts for both identity planes, technology mapping, rejected alternatives with reasons, and four stack gaps flagged rather than quietly adopted. |
| 3 | [Data Modeling & Storage](./03-data-modeling.md) | `03-data-modeling.md` | [ER](https://en.wikipedia.org/wiki/Entity%E2%80%93relationship_model "Entity Relationship — Models entities and the relationships between them as a precursor to a relational schema") model, PostgreSQL schema-per-module design with the temporal `care_relationship` at its centre, MongoDB content versioning, Elasticsearch mappings with mandatory scope fields, Redis keyspace, Blob layout, and why nothing is sharded yet. |
| 4 | [Deep Dive & Bottlenecks](./04-deep-dive.md) | `04-deep-dive.md` | Transport jurisdictions, sequence diagrams for check-in ingest, reminder delivery, and content generation, outbox-driven search freshness, [SPOF](https://en.wikipedia.org/wiki/Single_point_of_failure "Single Point of Failure — A component whose failure alone can bring down the whole system") analysis including the ones accepted, and the trade-offs stated as trade-offs. |
| 5 | [Reliability & Observability](./05-reliability.md) | `05-reliability.md` | Indexes tied to named access patterns, four cache layers each with an invalidation rule, two telemetry planes joined by trace context, SLOs with consequences, and a GitLab CI → ArgoCD pipeline whose gates can genuinely fail. |
| 6 | [Security & Compliance](./06-security.md) | `06-security.md` | Trust boundaries, two separated identity planes with [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems")-driven clinician lifecycle, [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") plus database-enforced [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles"), encryption posture including what is deliberately *not* field-encrypted, [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") Article 9 mapping, and perimeter defence. |

---

## Tech Stack — Role Assignments

| Technology | Role |
|---|---|
| **Python 3.14** | Runtime for every service, versions pinned identically across modules |
| **FastAPI** | `care-core`, `scim-provisioning-svc`, `clinical-nlp-svc` |
| **[Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime")** | Request/response contracts, SCIM schemas, and the sensitive-field marks the log redaction filter reads |
| **[SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") 2** | Typed data access to `pg-clinical`; keyset-paginated timeline queries |
| **[Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy")** | Expand/contract migrations run as an ArgoCD PreSync hook |
| **[Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects")** | Per-service dependency locking |
| **[Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle")** | Scheduled and retryable work — `celery.reminders`, `celery.content`, `celery.index`; Celery beat drives the reminder window |
| **RabbitMQ (`rmq-core`)** | `care.events` topic exchange (AMQP), MQTT plugin for device check-in ingress, Celery broker; quorum queues |
| **PostgreSQL (`pg-clinical`)** | System of record — patients, care relationships, appointments, prescriptions, visit notes, check-ins, reminders, consent, audit, outbox. Row-level security is the authorization boundary |
| **MongoDB (`mongo-content`)** | Versioned education pages, approved guidance passages, [NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Natural Language Processing — Computational techniques for analyzing and generating human language") extraction artifacts |
| **Elasticsearch (`es-clinical`)** | Search over notes, content, and visit history; every document scope-tagged, fully rebuildable from source |
| **Redis (`redis-cache`)** | Sessions, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") cache, timeline and page caches, rate-limit buckets, idempotency keys, Celery results — nothing durable |
| **Hugging Face** | Fine-tuned clinical entity extraction and passage reranking models, self-hosted so patient text stays in tenancy |
| **LangChain** | Retrieval, reranking, and citation-assembly workflow for education page composition |
| **Azure Blob Storage (`blob-documents`)** | Documents via direct [SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") upload, quarantine container, immutable audit archive |
| **Azure Service Bus (`sb-integration`)** | `sb.ingest` and `sb.notify` — the Azure-side integration edge |
| **Azure Event Grid (`evtgrid-blob`)** | `BlobCreated` triggering for document ingestion |
| **Azure Functions** | `fn-blob-ingest` (scan, validate, extract), `fn-notify-dispatch` (deliver, record receipt) |
| **Azure API Management** | North-south gateway: [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") validation, patient/clinician audience separation, coarse rate limiting, versioning |
| **Azure Entra ID + [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf")/[OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") + SCIM 2.0** | Clinician identity and lifecycle; deprovisioning closes care relationships transactionally |
| **OpenShift — `aro-primary`** | Primary cluster: `care-core`, `scim-provisioning-svc`, `celery-worker`, `rmq-core`, `mongo-content`, `es-clinical` |
| **[Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") / AKS — `aks-ml`** | GPU node pool for `clinical-nlp-svc` only; holds no state, so it can be collapsed back |
| **ArgoCD** | GitOps sync to both clusters; blue-green for `care-core`, canary for `clinical-nlp-svc` |
| **GitLab / GitLab CI** | Source, pipeline, container registry, GitOps manifest repository |
| **ruff / pyright / Pytest / SonarQube** | Blocking pipeline gates — lint, strict types, unit/contract/integration tests, quality gate |
| **[Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files")** | All Azure and cluster infrastructure; state in Azure Storage; hand-made resources are reported as drift |
| **Docker / Docker Compose** | Image builds; local stack running the real brokers and search engine, and the same stack CI integration-tests against |
| **Elastic [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production")** | Distributed tracing across FastAPI, SQLAlchemy, Celery, and RabbitMQ, continuous through async hops via `traceparent` |
| **Prometheus** | Metrics and [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health") collection from every service |
| **Kibana** | Single observability pane — logs, APM traces, dashboards, and audit detection rules |
| **Azure Monitor** | Telemetry for [APIM](https://learn.microsoft.com/en-us/azure/api-management/ "Azure API Management — Publishes, secures and rate limits APIs behind a managed gateway"), Functions, Service Bus, and Blob, shipped into Elasticsearch for correlation |
| **Azure Key Vault** | Customer-managed keys and secrets, reached by workload identity *(flagged in `02` — not in the original stack list)* |
| **Azure Front Door + [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application")** | [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") 1.3 termination, [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency"), [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") rule set, [DDoS](https://en.wikipedia.org/wiki/Denial-of-service_attack "Distributed Denial of Service — Attack that floods a system with traffic from many sources to make it unavailable") Standard *(flagged in `02` — not in the original stack list)* |
| **Linux** | Container base images and every runtime host |

---

## Requirement Traceability

Every responsibility in `inputs.txt`, and where the design answers it.

| # | Responsibility | Addressed in |
|---|---|---|
| 1 | PostgreSQL schemas and Elasticsearch indexes for clinical content search (35% latency reduction) | [`03`](./03-data-modeling.md) schema and index design; [`05`](./05-reliability.md) access-pattern indexing |
| 2 | Fine-tuned Hugging Face models and LangChain workflows for education pages (28% relevance gain) | [`04`](./04-deep-dive.md) education page generation path; [`02`](./02-high-level-design.md) technology mapping |
| 3 | Event-driven FastAPI with RabbitMQ AMQP and MQTT, check-ins and reminders off the request path (22% fewer missed reminders) | [`04`](./04-deep-dive.md) check-in ingest and reminder delivery paths |
| 4 | REST APIs with SCIM 2.0 and Entra ID JWT; clinicians provisioned from the directory and kept off the patient portal | [`02`](./02-high-level-design.md) API design; [`06`](./06-security.md) two separated identity planes |
| 5 | FastAPI modular monolith with SCIM provisioning and clinical NLP extracted | [`02`](./02-high-level-design.md) service topology and rejected alternatives |
| 6 | File ingestion and async notifications on Blob Storage, Service Bus, Event Grid | [`02`](./02-high-level-design.md) architecture diagram; [`04`](./04-deep-dive.md) cloud integration edge |
| 7 | SQLAlchemy 2 data access; tightened [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") for the timeline and care-team views | [`05`](./05-reliability.md) timeline query discipline; [`03`](./03-data-modeling.md) `timeline_at` normalisation |
| 8 | Python 3.14 with Poetry-managed dependencies | [`02`](./02-high-level-design.md) technology mapping |
| 9 | GitLab CI with ruff, pyright and SonarQube gates before OpenShift deploys | [`05`](./05-reliability.md) CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") pipeline |
| 10 | Pytest unit and integration tests for API contracts, identity flows, content services | [`05`](./05-reliability.md) blocking gates |
| 11 | ArgoCD releases to OpenShift and Kubernetes | [`05`](./05-reliability.md) GitOps delivery; [`02`](./02-high-level-design.md) cluster split |
| 12 | Jira estimates and Confluence release/incident notes on a shared runbook | **No architectural implication** — process tooling, not system behaviour. The one property that is architectural, a single operational runbook across diary, content and identity, appears in [`05`](./05-reliability.md) restore rehearsal and [`06`](./06-security.md) breach reporting |
| 13 | Elastic APM, Prometheus and Kibana on API and consumer latency and error rates | [`05`](./05-reliability.md) telemetry and SLI table |

---

## Reading Order

`01` sets the numbers; `02` fixes the names and technology choices that `03`–`06` are bound to; `04` explains the paths the earlier files assume; `05` and `06` are the operational and regulatory consequences. Deviating from `02`'s naming or technology anywhere in `03`–`06` is a defect in this document set, not a variation.
