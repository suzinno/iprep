# Personalized Cancer Support Platform
## System Design Overview

---

## Executive Summary

This document set reverse-engineers the architecture of a platform serving people diagnosed with cancer and the clinicians who follow them. Patients log daily wellbeing, read guidance specific to their diagnosis and treatment, and keep appointments, prescriptions, visit notes, and documents in one record; the care team sees the same record without a phone call or a paper pack. The system is a **FastAPI modular monolith (`care-core`) with four modules — `diary`, `records`, `clinical-content`, `identity` — plus two services extracted for reasons that survive scrutiny**: `scim-provisioning-svc`, whose release cadence belongs to the hospital directory, and `clinical-nlp-svc`, which needs GPUs and ships on a model's schedule. PostgreSQL is the system of record and the place authorization is enforced, with MongoDB holding versioned education content, Elasticsearch serving search, and Redis carrying nothing durable. Work leaves the request path through RabbitMQ — AMQP for domain events, MQTT for check-in ingress from patient devices — and crosses into Azure Service Bus at the boundary where files and notifications are handled by Functions. ArgoCD deploys from GitLab CI to Azure Red Hat OpenShift and AKS.

Peak load is roughly **200 QPS**. The design says so explicitly and refuses to buy sharding, meshes, or a microservice fleet against a number that does not require them. Where cost is taken anyway — a second broker, a second cluster, a second index — the file that takes it names the price and the condition that would reverse it. Two properties are treated as non-negotiable and shape everything else: **patient-record authorization lives in the database as row-level security**, so a forgotten scope in application code returns nothing rather than someone else's record; and **generated patient guidance is assembled only from clinician-approved, cited passages**, which measurably narrows what a page can say and is meant to.

---

## Section Index

| # | Section | File | Summary |
|---|---|---|---|
| 1 | [Requirement Clarification & Scoping](./01-requirements.md) | `01-requirements.md` | Audiences and their opposing access models, functional and non-functional requirements, per-path CAP positioning, and the scale baseline every later decision is proportional to (~25K patient DAU, ~200 QPS peak, ~1 TB hot relational + ~12 TB documents over 5 years). |
| 2 | [High-Level Design](./02-high-level-design.md) | `02-high-level-design.md` | Service topology and the naming every other file uses, architecture diagram, REST API contracts for both identity planes, technology mapping, rejected alternatives with reasons, and four stack gaps flagged rather than quietly adopted. |
| 3 | [Data Modeling & Storage](./03-data-modeling.md) | `03-data-modeling.md` | ER model, PostgreSQL schema-per-module design with the temporal `care_relationship` at its centre, MongoDB content versioning, Elasticsearch mappings with mandatory scope fields, Redis keyspace, Blob layout, and why nothing is sharded yet. |
| 4 | [Deep Dive & Bottlenecks](./04-deep-dive.md) | `04-deep-dive.md` | Transport jurisdictions, sequence diagrams for check-in ingest, reminder delivery, and content generation, outbox-driven search freshness, SPOF analysis including the ones accepted, and the trade-offs stated as trade-offs. |
| 5 | [Reliability & Observability](./05-reliability.md) | `05-reliability.md` | Indexes tied to named access patterns, four cache layers each with an invalidation rule, two telemetry planes joined by trace context, SLOs with consequences, and a GitLab CI → ArgoCD pipeline whose gates can genuinely fail. |
| 6 | [Security & Compliance](./06-security.md) | `06-security.md` | Trust boundaries, two separated identity planes with SCIM-driven clinician lifecycle, RBAC plus database-enforced ABAC, encryption posture including what is deliberately *not* field-encrypted, GDPR Article 9 mapping, and perimeter defence. |

---

## Tech Stack — Role Assignments

| Technology | Role |
|---|---|
| **Python 3.14** | Runtime for every service, versions pinned identically across modules |
| **FastAPI** | `care-core`, `scim-provisioning-svc`, `clinical-nlp-svc` |
| **Pydantic** | Request/response contracts, SCIM schemas, and the sensitive-field marks the log redaction filter reads |
| **SQLAlchemy 2** | Typed data access to `pg-clinical`; keyset-paginated timeline queries |
| **Alembic** | Expand/contract migrations run as an ArgoCD PreSync hook |
| **Poetry** | Per-service dependency locking |
| **Celery** | Scheduled and retryable work — `celery.reminders`, `celery.content`, `celery.index`; Celery beat drives the reminder window |
| **RabbitMQ (`rmq-core`)** | `care.events` topic exchange (AMQP), MQTT plugin for device check-in ingress, Celery broker; quorum queues |
| **PostgreSQL (`pg-clinical`)** | System of record — patients, care relationships, appointments, prescriptions, visit notes, check-ins, reminders, consent, audit, outbox. Row-level security is the authorization boundary |
| **MongoDB (`mongo-content`)** | Versioned education pages, approved guidance passages, NLP extraction artifacts |
| **Elasticsearch (`es-clinical`)** | Search over notes, content, and visit history; every document scope-tagged, fully rebuildable from source |
| **Redis (`redis-cache`)** | Sessions, JWKS cache, timeline and page caches, rate-limit buckets, idempotency keys, Celery results — nothing durable |
| **Hugging Face** | Fine-tuned clinical entity extraction and passage reranking models, self-hosted so patient text stays in tenancy |
| **LangChain** | Retrieval, reranking, and citation-assembly workflow for education page composition |
| **Azure Blob Storage (`blob-documents`)** | Documents via direct SAS upload, quarantine container, immutable audit archive |
| **Azure Service Bus (`sb-integration`)** | `sb.ingest` and `sb.notify` — the Azure-side integration edge |
| **Azure Event Grid (`evtgrid-blob`)** | `BlobCreated` triggering for document ingestion |
| **Azure Functions** | `fn-blob-ingest` (scan, validate, extract), `fn-notify-dispatch` (deliver, record receipt) |
| **Azure API Management** | North-south gateway: JWT validation, patient/clinician audience separation, coarse rate limiting, versioning |
| **Azure Entra ID + OAuth2/OIDC + SCIM 2.0** | Clinician identity and lifecycle; deprovisioning closes care relationships transactionally |
| **OpenShift — `aro-primary`** | Primary cluster: `care-core`, `scim-provisioning-svc`, `celery-worker`, `rmq-core`, `mongo-content`, `es-clinical` |
| **Kubernetes / AKS — `aks-ml`** | GPU node pool for `clinical-nlp-svc` only; holds no state, so it can be collapsed back |
| **ArgoCD** | GitOps sync to both clusters; blue-green for `care-core`, canary for `clinical-nlp-svc` |
| **GitLab / GitLab CI** | Source, pipeline, container registry, GitOps manifest repository |
| **ruff / pyright / Pytest / SonarQube** | Blocking pipeline gates — lint, strict types, unit/contract/integration tests, quality gate |
| **Terraform** | All Azure and cluster infrastructure; state in Azure Storage; hand-made resources are reported as drift |
| **Docker / Docker Compose** | Image builds; local stack running the real brokers and search engine, and the same stack CI integration-tests against |
| **Elastic APM** | Distributed tracing across FastAPI, SQLAlchemy, Celery, and RabbitMQ, continuous through async hops via `traceparent` |
| **Prometheus** | Metrics and SLI collection from every service |
| **Kibana** | Single observability pane — logs, APM traces, dashboards, and audit detection rules |
| **Azure Monitor** | Telemetry for APIM, Functions, Service Bus, and Blob, shipped into Elasticsearch for correlation |
| **Azure Key Vault** | Customer-managed keys and secrets, reached by workload identity *(flagged in `02` — not in the original stack list)* |
| **Azure Front Door + WAF** | TLS 1.3 termination, CDN, OWASP rule set, DDoS Standard *(flagged in `02` — not in the original stack list)* |
| **Linux** | Container base images and every runtime host |

---

## Reading Order

`01` sets the numbers; `02` fixes the names and technology choices that `03`–`06` are bound to; `04` explains the paths the earlier files assume; `05` and `06` are the operational and regulatory consequences. Deviating from `02`'s naming or technology anywhere in `03`–`06` is a defect in this document set, not a variation.
