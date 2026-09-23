# Robotic & Industrial AI Intelligence Platform

*System design overview*

**Table of Contents**
- [Executive Summary](#executive-summary)
- [Document Set](#document-set)
- [Tech Stack and Roles](#tech-stack-and-roles)
- [Requirement Traceability](#requirement-traceability)

## Executive Summary

A multi-tenant [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") platform on [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") that takes in telemetry from robot fleets and industrial sensors and runs [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") workflows on it. Edge gateways push ordered, batched telemetry through [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Gateway to [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services on [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS"). An [SNS](https://aws.amazon.com/sns/ "Amazon Simple Notification Service — Managed publish-subscribe topics that fan one message out to many subscribers") [FIFO](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-fifo-queues.html "First In, First Out — Queue and topic mode that preserves message order within a group and removes duplicates") fan-out feeds three Lambda consumers that archive raw data to [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives"), maintain rollups and live status in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), and turn rule breaches into alarms; DynamoDB telemetry checkpoints make every consumer safe to repeat. AI work — contextual analysis, image inspection and document generation — runs as Step Functions pipelines whose agent steps are handed to LangGraph workers on EKS through an [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers") callback. The workers reason with Bedrock models over hybrid pgvector and full-text retrieval and a controlled set of [MCP](https://modelcontextprotocol.io/ "Model Context Protocol — Open protocol that exposes tools and data to AI agents through a standard interface") tools, and every output passes a deterministic-first validation gate and, for anything exported, human review. Tenant isolation is layered: Cognito claims, PostgreSQL row-level security, [IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources") session tags on S3 and DynamoDB, and run-bound tool access. The design targets 99.9% availability, live status within 30 s and a 5-minute p95 for analyses. The binding scale limit is the Bedrock token quota, not compute.

## Document Set

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Personas, must-have and nice-to-have features, non-functional targets, [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning, scale and storage estimates |
| [02-high-level-design.md](02-high-level-design.md) | Architecture diagram, the component catalogue that owns every name, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") API, technology mapping and stack gaps |
| [03-data-modeling.md](03-data-modeling.md) | PostgreSQL schemas, DynamoDB tables, S3 layout, Redis keyspace, partitioning, evolution triggers, migrations |
| [04-deep-dive.md](04-deep-dive.md) | Sync and async flows, the telemetry pipeline, the async execution model, AI pipelines, latency budgets, failure modes, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes per query, caching layers and invalidation, SLOs, logs, traces, alarms, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") and deployment strategy |
| [06-security.md](06-security.md) | Authentication, [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") and [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles"), tenant isolation, AI tool security, encryption, compliance, perimeter defence, items for security review |

## Tech Stack and Roles

| Technology | Role |
|---|---|
| Python, AsyncIO | Backend services, workers and Lambdas; concurrent I/O for model, database and AWS calls |
| FastAPI | `platform-api`, `agent-service-api`, `mcp-gateway`; dependency injection for sessions, tenant context and service modules |
| [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") | API models, [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") structured-output schemas, the output-validation contract |
| [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") | Async data access; migrations run as a [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Job before each deploy |
| [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") | Background jobs on the `celery-broker` Redis: document ingestion, thumbnails, partitions, hourly rollups, sweepers |
| [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf"), Cognito | User login with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"), machine clients for gateways and agents, groups as roles |
| IAM, Secrets Manager | Per-workload roles, tenant-scoped sessions, rotated credentials |
| API Gateway | Public REST edge: authorizer, request validation, throttling, usage plans |
| Step Functions | `analysis-pipeline`, `inspection-pipeline`, `generation-pipeline` |
| Lambda | Telemetry consumers, pipeline steps, run-event subscribers, audit archiver, token enrichment |
| SQS, SNS | Ordered telemetry fan-out, the agent callback queue, run-event fan-out, operational alerts |
| DynamoDB | `telemetry_checkpoints`, `audit_log` |
| S3 | Raw telemetry, robotic datasets, run intermediates and outputs, audit archive, [SPA](https://en.wikipedia.org/wiki/Single-page_application "Single Page Application — Web application that updates its content in place without full page reloads") hosting |
| PostgreSQL | System of record; pgvector retrieval; row-level security; LangGraph checkpoints |
| Redis | `platform-cache` for live status, cache-aside entries and limits; `celery-broker` for Celery |
| Bedrock | Sonnet-class reasoning and vision, Haiku-class checks, Titan embeddings |
| LangChain, LangGraph | Model and tool bindings, retrieval, the assist chain; resumable multi-step agent graphs |
| MCP | `mcp-gateway` tools for telemetry, alarms, maintenance history, knowledge search and work-order drafts |
| React, TypeScript, React Router, React Query, Redux, TailwindCSS, Vite, [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers")/[CSS](https://developer.mozilla.org/en-US/docs/Web/CSS "Cascading Style Sheets — Describes how HTML elements are laid out and styled in a browser") | `ops-console`: server state and polling in React Query, client-only state in Redux |
| Docker, Docker Compose, [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment"), EKS, Kubernetes | Images built once and stored in ECR; EKS in three zones; Docker Compose for local and CI integration |
| [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") | Every AWS resource, per environment account |
| GitLab CI/CD, Bash, Linux | Pipeline on in-[VPC](https://aws.amazon.com/vpc/ "Virtual Private Cloud — Isolated private network in which cloud resources run") runners; Bash deploy and verification steps |
| Pytest, moto, React Testing Library | Unit, integration and frontend tests; moto fakes AWS services |
| CloudWatch | Metrics, logs, alarms, dashboards |
| JavaScript, Cursor | Build configuration; development environment — no architectural role |

Additions outside the brief — pgvector, [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") Proxy, ElastiCache, CloudFront, a Network Load Balancer, AWS [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application"), [KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use"), [STS](https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html "AWS Security Token Service — Issues short-lived credentials for assumed roles"), X-Ray, VPC endpoints, a [PDF](https://en.wikipedia.org/wiki/PDF "Portable Document Format — Fixed-layout document format for reliable printing and viewing") text extractor and Vitest — are listed and justified in 02.

## Requirement Traceability

| # | Responsibility (brief) | Addressed in |
|---|---|---|
| 1 | FastAPI services with dependency injection and reusable service modules for high concurrency | 02 (catalogue, mapping); 04 (responsiveness mechanisms); 06 (per-route role dependency) |
| 2 | Step Functions state machines for analysis, generation and validation with retries and failure handling | 04 (AI pipelines, retry policy, failure modes) |
| 3 | Async processing with AsyncIO, Celery on Redis, SQS with SNS fan-out, Lambda for long-running tasks | 04 (communication patterns, async execution model); 03 (`celery-broker`) |
| 4 | API Gateway with request validation, throttling and OAuth2 authorization | 02 (API design); 06 (authentication, perimeter defence) |
| 5 | Tenant-aware access control with Cognito and IAM; credentials in Secrets Manager | 06 (identity, tenant isolation, data protection) |
| 6 | DynamoDB for telemetry checkpoints and audit lookups; PostgreSQL schemas, indexes and migrations | 03 (all sections); 05 (indexes) |
| 7 | S3 for robotic datasets, generated assets and intermediate artifacts | 03 (S3 layout); 02 (dataset and inspection upload endpoints) |
| 8 | LangChain on Bedrock for contextual analysis and tool execution; LangGraph for multi-step reasoning, state and validation | 04 (LangGraph workflow, validation); 03 (`agent_state`) |
| 9 | MCP integrations exposing telemetry, operational data and services as controlled tools | 04 (MCP tools); 06 (AI and tool security) |
| 10 | [RAG](https://en.wikipedia.org/wiki/Retrieval-augmented_generation "Retrieval-Augmented Generation — Grounds a model's answer in documents retrieved at query time") with PostgreSQL and vector retrieval | 04 (hybrid retrieval); 03 (`document_chunks`, tenant partitions); 05 ([HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") and [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") indexes) |
| 11 | Optimized FastAPI and async paths for responsiveness | 04 (latency budgets and responsiveness mechanisms); 05 (caching) |
| 12 | CloudWatch metrics, logs and alarms for APIs, queues, executions and generation failures | 05 (telemetry, alarms) |
| 13 | Terraform for Step Functions, Lambda, queues and IAM; EKS deploys from ECR with Docker and Kubernetes | 05 (automation); 02 (technology mapping) |
| 14 | React and TypeScript interfaces for inspection, analysis and generation review | 02 (`ops-console`, review endpoints); 06 (RBAC matrix, output rendering) |
| 15 | React Query for server state and async AI requests; React Router, Redux, TailwindCSS, Vite | 05 (client caching and polling); 04 (polling trade-off); 02 (mapping) |
| 16 | Pytest with moto for Lambda handlers, SQS consumers and DynamoDB; React Testing Library | 05 (tests) — a process item whose one architectural effect is that handlers take AWS clients by injection |
| 17 | GitLab CI/CD image builds, tests and multi-environment deployments with Bash on Linux agents | 05 (automation); 06 (GitLab [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") trust) |
| 18 | Cursor as the development environment | No architectural implication — a tooling choice |
