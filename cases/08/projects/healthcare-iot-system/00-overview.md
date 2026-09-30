# Smart Healthcare System (IoT)

*System design overview*

## Table of Contents

- [Executive Summary](#executive-summary)
- [Sections](#sections)
- [Tech Stack and Roles](#tech-stack-and-roles)
- [Requirement Traceability](#requirement-traceability)

## Executive Summary

The Smart Healthcare System streams vital signs from bedside devices in ~1,200 monitored beds across a group of hospitals. Ward edge gateways upload them every second to Python microservices on Azure [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Service. There, a rule engine (per-patient thresholds and [NEWS2](https://www.rcp.ac.uk/improving-care/resources/national-early-warning-score-news-2/ "National Early Warning Score 2 — Scores routine vital signs to detect clinical deterioration in adult patients")) detects deterioration and pushes alerts to on-duty nurses within a 5-second p95 budget, escalating when nobody acknowledges. Bedside monitors keep their own alarms, so the platform is a secondary, remote notification layer. That positioning sets its availability target (99.9%) and its [DR](https://en.wikipedia.org/wiki/Disaster_recovery "Disaster Recovery — Restores a system in another location after a failure too large for in-place redundancy") stance (zone-redundant, with a pilot-light second region). [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") decouples alerting from raw storage, so a slow telemetry store can never delay an alert. [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") is the system of record, with one schema per service. Cosmos DB holds 30 days of raw frames, and Azure Functions compute rollups and an Azure [ML](https://en.wikipedia.org/wiki/Machine_learning "Machine Learning — Algorithms that learn patterns from data rather than following explicit rules") risk score. The same platform runs a transport-robot mission service and a [ChatGPT](https://openai.com/chatgpt/ "ChatGPT — OpenAI's conversational large language model product") assistant that answers questions from a curated corpus of expert recommendations with cited sources. Security rests on Entra ID for every caller, patient-level access rules with audited break-glass, and [mTLS](https://en.wikipedia.org/wiki/Mutual_authentication "Mutual TLS — TLS in which client and server both present certificates, so each authenticates the other") inside the cluster. The brief states no quantified outcomes, so every number in these documents is a design target.

## Sections

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Assumptions, users, functional and non-functional requirements, [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning, scale and 5-year storage estimates |
| [02-high-level-design.md](02-high-level-design.md) | Architecture diagram, service catalogue, [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") contracts, technology mapping, stack gaps and the unused Azure [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") Database |
| [03-data-modeling.md](03-data-modeling.md) | PostgreSQL schemas per service, published views and stored procedures, raw-telemetry documents, [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") keys, Blob containers, partitioning |
| [04-deep-dive.md](04-deep-dive.md) | Sync vs async flows, RabbitMQ topology, alert latency budget, failure modes, Kubernetes disaster recovery, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes per query, query optimization, caching and invalidation, SLOs, logging through Grafana, tracing, cluster health, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") |
| [06-security.md](06-security.md) | OAuth flows, [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") and [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles"), per-component grants, encryption, [HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") and [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data"), [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application"), rate limits and egress control |

## Tech Stack and Roles

| Technology | Role |
|---|---|
| Python | All services, workers, Functions and the ward-gateway agent |
| Django, Django [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") Framework | `care-core`: patients, admissions, beds, devices, thresholds, admin UI |
| Flask | `telemetry-service`, `alert-service`, `notification-service`, `robot-service`, `assistant-service` |
| [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") | [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") and migrations for Flask services and `func-analytics` |
| [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") | API validation and versioned message contracts (`VitalsBatchV1`, `AlertRaisedV1`) |
| OAuth (Entra ID) | [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") + [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") for staff; certificate-based client credentials for gateways and robots |
| [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") | Chat completions and embeddings for the assistant |
| [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") | `notify.send` delivery with retries; beat for escalation and gateway-silence checks |
| RabbitMQ | Topic exchanges `telemetry` and `alerts`, Celery broker, quorum queues across three zones |
| PostgreSQL | System of record, stored procedures, partitioned rollups and audit, `pgvector` hybrid search |
| [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") (Cosmos DB for MongoDB) | `vitals_raw`: 30 days of raw frames; MongoDB container for local development |
| Redis | Latest vitals, rule windows, write-through threshold and binding caches, dedup, rate limits, answer cache |
| Pandas | Resampling and inspection in rollups; data-quality report; ML dataset preparation |
| [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") | Concatenate, sort and transpose frame arrays for vectorised statistics and model features |
| Azure Functions | `func-analytics` (rollups, archive, risk scoring, exports, partitions); `func-knowledge` (document ingest) |
| Azure Machine Learning | `deterioration-risk` model training and online endpoint |
| Azure Blob Storage | Patient files, corpus documents, telemetry and audit archives, ML datasets |
| Azure [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") | Three-zone cluster running every service, worker and RabbitMQ |
| Azure Container Registry | Images, geo-replicated for DR |
| Azure API Management | Gateway for staff, robot and assistant APIs |
| Azure SQL Database | No role — PostgreSQL covers every relational need (`02-high-level-design.md`) |
| Azure Cosmos DB | Managed host for the MongoDB API store |
| Azure Monitor | Log Analytics, Application Insights, managed Prometheus |
| Prometheus | Metrics, SLIs and [PromQL](https://prometheus.io/docs/prometheus/latest/querying/basics/ "Prometheus Query Language — Queries and aggregates time series metrics collected by Prometheus") alert rules |
| Grafana | Dashboards over metrics and, through the Azure Monitor data source, over logs |
| [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") | All Azure resources, Entra app registrations, RabbitMQ definitions, DR region build |
| Docker, Docker Compose | Images; local dependency stack and CI integration tests |
| Kubernetes | Deployments, [KEDA](https://keda.sh/ "Kubernetes Event-driven Autoscaling — Scales Kubernetes workloads on external event sources such as queue depth") scaled objects, RabbitMQ StatefulSet, PodDisruptionBudgets |
| GitHub, GitHub Actions | Source; CI with change detection, parallel matrix jobs and layer caching; canary CD |
| Bash | CI change detection, canary gates, DR runbooks, gateway provisioning |

## Requirement Traceability

| Responsibility (quoted from `inputs.txt`) | Addressed in |
|---|---|
| Designing the overall structure and schema of the databases and microservices, and ensuring that they are scalable, secure, and easy to maintain; | `02` Service Catalogue; `03` Relational Schema and Partitioning and Sharding Strategy; `06` Workload Identity and Grants |
| Identifying the appropriate technology stack and tools to use for the design and implementation of microservices; | `02` Technology Mapping and Stack Gaps and Unused Items |
| Designing and implementing disaster recovery plans for Kubernetes(k8s) environments; | `04` Disaster Recovery for Kubernetes |
| Developing optimized SQL queries and stored procedures for PostgreSQL; | `03` Stored Procedures and Views; `05` Query Optimization Practice |
| Optimize CI/CD pipelines for speed and efficiency, reducing build and deployment times through caching and parallel jobs; | `05` Automation (change detection, parallel matrix jobs, pip and Buildx layer caches, build once). The brief gives no figure for the reduction, and none is claimed |
| Integration with [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") ChatGPT for creating a chatbot that answers expert questions and quickly searches for information among a corpus of documents with expert recommendations; | `02` `assistant-service` and `func-knowledge`; `03` schema `kb`; `05` hybrid search and answer cache; `06` assistant data boundary |
| Define and manage Azure infrastructure components using Terraform; | `02` Technology Mapping; `04` Disaster Recovery for Kubernetes (cluster and region rebuild); `05` Automation (plan and apply) |
| Configuring OAuth authentication in the application; | `06` Identity and Authentication |
| Azure Blob Storage configuration for storing images and other files; | `02` file APIs ([SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Shared Access Signature — Time-limited token granting scoped access to an Azure Storage resource") upload); `03` Blob Containers; `06` grants and encryption |
| Implement monitoring and logging mechanisms to track the health and performance of the microservices; | `05` Telemetry |
| Data normalization and data inspection using Pandas; | `02` `func-analytics`; `03` `telemetry.data_quality_daily`. Unit normalization happens at the gateway, and Pandas resamples and inspects the data in rollups |
| Utilizing NumPy for transposing, sorting and concatenating data; | `02` Technology Mapping (`func-analytics` rollups and risk-model features) |
| Implement serverless calculations using Azure Functions; | `02` Service Catalogue; `04` Trade-offs (Functions vs CronJobs) |
| Configure and deploy Kubernetes(k8s) clusters using Azure AKS; | `02` Architecture Diagram; `05` Cluster Health and Maintenance (node pools, upgrades) |
| RabbitMQ configuration for communication between services; | `04` Communication Patterns and RabbitMQ Topology; `06` RabbitMQ permissions |
| Setting up logging for the system using Grafana; | `05` Structured logging (Grafana over Log Analytics through the Azure Monitor data source) |
| Monitoring and maintaining the health of the Kubernetes(k8s) cluster, and troubleshooting any issues that may arise; | `05` Cluster Health and Maintenance |
| Build indexes on SQL tables and optimization of existing raw queries. | `05` Read and Write Optimizations and Query Optimization Practice |
