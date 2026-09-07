# Personalized Cancer Support Platform
## System Design Overview

---

## Executive Summary

This document presents the system architecture for a personalized cancer support platform that assists patients from the point of diagnosis through treatment. The platform combines a traditional CRUD backend for managing medical records (appointments, prescriptions, documents) with an AI-powered conversational assistant that delivers personalized, citation-backed medical information via retrieval-augmented generation (RAG). The architecture runs on Azure — core services are containerized on AKS for persistent workloads, while event-driven processing leverages Azure Functions for cost-efficient, bursty operations like document OCR and analytics. All design decisions are anchored in HIPAA compliance, with PHI protection enforced at every layer: encrypted storage, row-level access control, audit logging, and strict data boundaries around the AI pipeline.

---

## Section Index

| # | Section | File | Summary |
|---|---------|------|---------|
| 1 | [Requirement Clarification & Scoping](./01-requirements.md) | `01-requirements.md` | Target audience, functional/non-functional requirements, and back-of-the-envelope scale estimates (~15K DAU, ~500 QPS peak, ~12 TB 5-year storage). |
| 2 | [High-Level Design](./02-high-level-design.md) | `02-high-level-design.md` | Service definitions, REST API contracts, architecture diagram, and technology mapping with justifications for each stack component. |
| 3 | [Data Modeling & Storage](./03-data-modeling.md) | `03-data-modeling.md` | ER diagram, schema design across PostgreSQL/Cosmos DB/Milvus/Redis/Blob Storage, and partitioning strategy. |
| 4 | [Deep Dive & Bottlenecks](./04-deep-dive.md) | `04-deep-dive.md` | Sync/async/streaming communication patterns, failure mode analysis, and key architectural trade-offs (latency vs. accuracy, consistency vs. availability). |
| 5 | [Reliability & Observability](./05-reliability.md) | `05-reliability.md` | Indexing strategies, multi-layer caching with cache-aside invalidation, OpenTelemetry observability, and CI/CD with canary deployments. |
| 6 | [Security & Compliance](./06-security.md) | `06-security.md` | OAuth 2.0/OIDC via AAD B2C, RBAC with row-level scoping, TLS/mTLS encryption, HIPAA compliance mapping, and perimeter defense (WAF, rate limiting, DDoS). |

---

## Tech Stack — Role Assignments

| Technology | Role |
|------------|------|
| **Python / FastAPI / Pydantic** | Backend services runtime, API schema validation |
| **SQLAlchemy / Alembic** | ORM and versioned database migrations |
| **LangChain / LangGraph** | AI conversational agent orchestration, RAG pipeline, stateful graph-based flows |
| **Milvus** | Vector store for semantic search in RAG (medical knowledge + patient documents) |
| **Redis** | Session cache, application-level cache (patient profiles, wellbeing), rate limiting counters |
| **PostgreSQL (Azure Database for PostgreSQL)** | Primary relational store — patients, appointments, prescriptions, wellbeing, messages, audit logs |
| **Cosmos DB** | Conversation history storage (flexible schema, TTL, partitioned by patient_id) |
| **Azure Blob Storage** | Medical document storage with lifecycle tiering (hot -> cool -> archive) |
| **Azure Service Bus** | Async event messaging — document processing, notifications, analytics triggers |
| **Azure Functions** | Serverless event-driven processing — blob-triggered OCR, Service Bus-triggered analytics |
| **AKS (Azure Kubernetes Service)** | Container orchestration for long-lived services with auto-scaling and health checks |
| **Azure API Management** | API gateway — JWT validation, rate limiting, request routing, API versioning |
| **React / Redux / Redux Toolkit / MUI** | Frontend SPA with centralized state management and accessible UI components |
| **Axios** | HTTP client for frontend-to-API communication |
| **Webpack** | Frontend bundling with HMR for development workflow |
| **Docker / Docker Compose** | Containerization and local multi-service development environment |
| **Kubernetes (AKS)** | Production container orchestration with ingress controllers and network policies |
| **GitHub Actions** | CI pipeline — lint, test, build, security scan |
| **Azure DevOps** | CD pipeline — staging deployment, approval gates, canary rollout to production |
| **Azure Monitor / Application Insights** | Metrics, structured logging, distributed tracing (OpenTelemetry backend) |
| **Azure Key Vault** | Secret management and encryption key storage (CMK for HIPAA compliance) |
| **Azure AD B2C** | Identity provider — patient/provider/admin authentication with MFA and federated SSO |
| **Bash** | Automation scripts for data processing, infrastructure management, and CI/CD support |
| **Cursor / Claude** | AI-assisted development tooling for code analysis, bottleneck identification, and optimization |
