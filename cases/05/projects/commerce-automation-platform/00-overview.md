# Intelligent Commerce Automation Platform

*System design overview*

## Table of Contents

- [Executive Summary](#executive-summary)
- [Section Index](#section-index)
- [Tech Stack and Roles](#tech-stack-and-roles)
- [Requirement Traceability](#requirement-traceability)

## Executive Summary

This is a multi-tenant [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") [SaaS](https://en.wikipedia.org/wiki/Software_as_a_service "Software as a Service — Delivers an application as a hosted service that customers use rather than install") platform for 800 multi-channel merchants and the 1.5M daily shoppers on their storefronts. Ten [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") microservices run on Amazon [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS"). They exchange domain events over [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") through a transactional outbox, and use [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers") and [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for long-running [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") work. The main flows are:

- **Catalog:** supplier feeds pass through [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") Glue, which cleans and chunks them. Amazon Bedrock then extracts attributes and writes [SEO](https://developers.google.com/search/docs/fundamentals/seo-starter-guide "Search Engine Optimization — Shapes page content so that search engines rank it higher") copy, but only for products whose content hash changed. Layered response caching cuts that generation cost by 35%.
- **Search and recommendations:** a hybrid pgvector and full-text retriever, with a per-tenant [HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") index, answers searches in ~110 ms on average, down from 450 ms. Recommendations draw on the same index.
- **Pricing:** LangGraph agents on the [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") choose between prices computed deterministically. Guardrails bound every choice, and a human must approve changes above the auto-apply band.
- **Conversation:** agents call typed tools that can never do more than the caller's own permissions allow.
- **Storage:** a partitioned, index-tuned [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") primary carries 4,500+ requests per second at p95 < 50 ms, even with the cache cold.
- **Console:** a React/[MobX](https://mobx.js.org/ "MobX — Makes application state observable so that views update when the data they read changes") console gives merchants [D3](https://d3js.org/ "D3.js — JavaScript library that binds data to SVG and HTML for custom visualisations") treemaps and heatmaps, and a multi-step onboarding flow.

## Section Index

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Audiences, must-have and nice-to-have features, non-functional targets, [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") position per domain, scale and 5-year storage estimates |
| [02-high-level-design.md](02-high-level-design.md) | Service topology, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), architecture and ingestion diagrams, technology mapping, and additions outside the stated stack |
| [03-data-modeling.md](03-data-modeling.md) | `core-db` and `search-db` schemas, [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes") and [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") layout, partitioning, evolution triggers |
| [04-deep-dive.md](04-deep-dive.md) | Sync and async patterns, Kafka topics and outbox, search latency budget, pricing and chat agents, [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") cost control, failure modes, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes per query, write-path tuning, cache layers and invalidation, SLOs, agent-chain telemetry, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") and canary |
| [06-security.md](06-security.md) | Cognito [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf")/[OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users"), [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") plus tenant [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") and [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user"), agent tool security, encryption, [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data"), [PCI-DSS](https://www.pcisecuritystandards.org/ "Payment Card Industry Data Security Standard — Security requirements for organizations that handle payment card data") and the AI Act, [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") and rate limits |

## Tech Stack and Roles

| Technology | Role |
|---|---|
| Python, FastAPI, [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") | All backend services; API, event and tool schemas |
| [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") | Async [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") and bulk merges; migrations per service schema |
| Celery | `catalog-worker` (import, enrichment) and `agent-worker` (pricing and trend agents) on an SQS broker |
| LangChain | Hybrid retriever, structured tools, model abstraction |
| LangGraph | Pricing, trend and chat agent graphs with checkpoints and approval interrupts |
| OpenAI SDK | Pricing and trend agent reasoning |
| Amazon Bedrock | Attribute extraction, SEO copy, embeddings, the shopper chat model |
| PostgreSQL ([RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover")) | `core-db` [OLTP](https://en.wikipedia.org/wiki/Online_transaction_processing "Online Transaction Processing — Workload of many short read and write transactions serving an application"), one schema per service; `search-db` with pgvector |
| [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") (ElastiCache) | Catalog lookup cache, query-embedding cache, first-tier LLM response cache, signal windows, rate and token budgets |
| Kafka ([MSK](https://aws.amazon.com/msk/ "Amazon Managed Streaming for Apache Kafka — Runs Apache Kafka clusters as a managed AWS service")) | Domain events: catalog, inventory, orders, market signals, pricing decisions, interactions |
| SQS, [SNS](https://aws.amazon.com/sns/ "Amazon Simple Notification Service — Managed publish-subscribe topics that fan one message out to many subscribers") | Celery broker queues, `order-ingest`, `catalog-batch-ready`; batch and ops fan-out |
| DynamoDB | Webhook de-duplication, LLM response cache, conversation state |
| S3, Glue | Supplier feeds (raw, curated, chunks) and archives; cleaning, chunking, affinity and archive jobs |
| Lambda | `feed-intake`, `webhook-ingest`, `cognito-pre-token` |
| API Gateway | Public API: Cognito authorizer, API keys, usage plans, webhook routes |
| Cognito, [IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources") | Merchant identity and partner OAuth2; per-service AWS permissions |
| EKS, [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications"), Docker, [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment") | Runtime for all services and workers; image registry |
| CloudWatch, Prometheus, Grafana | AWS service metrics and logs; application and agent-chain metrics; one dashboard layer |
| React, TypeScript, React Router, MobX | `merchant-console` [SPA](https://en.wikipedia.org/wiki/Single-page_application "Single Page Application — Web application that updates its content in place without full page reloads") and its dashboard and onboarding stores |
| JavaScript, Webpack | `storefront-widget` bundle; code-split builds |
| [TailwindCSS](https://tailwindcss.com/ "Tailwind CSS — Utility-first CSS framework for styling components directly in markup"), shadcn/ui, [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers")/[CSS](https://developer.mozilla.org/en-US/docs/Web/CSS "Cascading Style Sheets — Describes how HTML elements are laid out and styled in a browser") | Shared `@cap/ui` library; onboarding wizard |
| D3.js, Treemaps | Category-sales treemap; behaviour-flow heatmap |
| Pytest, React Testing Library, Docker Compose | Unit, integration and UI tests; local and CI integration stack |
| Bitbucket, Bitbucket Pipelines, Bash | Source, CI/CD, canary analysis scripts |
| Cursor, Codex | Developer tooling only |

The additions outside the stated stack (MSK, ElastiCache, pgvector, CloudFront, WAF, Secrets Manager, [KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use"), ingress-nginx, Linkerd, OpenTelemetry with X-Ray) are listed with their reasons in `02-high-level-design.md`.

## Requirement Traceability

| # | Responsibility (from `inputs.txt`) | Addressed in |
|---|---|---|
| 1 | Distributed microservices on AWS with asynchronous event-driven communication | `02` Service Topology; `04` Communication Patterns (outbox, Kafka topics, SQS/SNS) |
| 2 | PostgreSQL indexes and partitioning; 4,500+ requests per second at sub-50 ms | `03` Partitioning Strategy; `05` Read/Write Optimizations and lookup budget; `04` capacity with Redis cold |
| 3 | Glue [ETL](https://en.wikipedia.org/wiki/Extract,_transform,_load "Extract, Transform, Load — Moves data out of source systems, reshapes it and loads it into a target store") to clean, chunk and structure supplier catalogs | `02` Catalog Ingestion Flow; `03` staging table and S3 layout |
| 4 | Context-aware search with LangChain and pgvector, 450 ms → 110 ms | `04` Search Retrieval Path (latency budget); `03` `search.product_documents` partitions |
| 5 | Dynamic pricing and trend agents with LangGraph and the OpenAI SDK | `04` Pricing and Trend Agents; `03` `pricing` schema |
| 6 | Bedrock SEO synthesis, 35% cost cut through caching and token optimisation | `04` LLM Cost and Rate Control; `05` `llm:` cache; `03` `llm-response-cache` |
| 7 | LangChain + Pydantic function-calling tools for secure inventory lookups and stock updates | `04` Conversational Agents and Tools; `06` Agent and Tool Security; `03` `idempotency_keys` |
| 8 | Merchant analytics dashboards with React, TypeScript, MobX and custom state containers | `02` API Design (analytics endpoints) and Technology Mapping; `03` `analytics` rollups |
| 9 | D3 heatmaps and treemaps for category sales and behaviour flows | `02` `CategorySalesTree` and `BehaviorMatrix` contracts; `03` `sales_daily_category`, `behavior_hourly` |
| 10 | Tailwind and shadcn/ui component library; multi-step seller onboarding | `02` Technology Mapping and `PUT /v1/onboarding/steps/{step}`; `03` `onboarding_sessions` |
| 11 | Docker microservices to EKS through Bitbucket Pipelines | `05` Automation; `06` OIDC deploy role |
| 12 | Redis caching and Kafka streams for high-concurrency catalog lookups and order events | `05` Caching Strategy; `04` Kafka topics (`orders.events`) |
| 13 | Prometheus and Grafana to find latency bottlenecks in AI agent chains | `05` Telemetry (agent chain metrics, tracing) |
| 14 | Code quality with Pytest and React Testing Library | `05` Automation (tests); no further architectural implication |
| 15 | Cursor and Codex in daily coding | No architectural implication: developer tooling |
