# AI Conversational Recruitment & Candidate Matching Ecosystem

*System design overview*

## Table of Contents

- [Executive Summary](#executive-summary)
- [Sections](#sections)
- [Tech Stack and Roles](#tech-stack-and-roles)
- [Requirement Traceability](#requirement-traceability)

---

## Executive Summary

The platform replaces job-board forms with two chats: recruiters build job descriptions, and candidates build profiles, while an assistant evaluates each answer and fills a structured draft in real time. [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services on [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS") own the employer, candidate, conversation and matching domains in one repository. Replies stream over WebSockets from `chat-engine`, which keeps conversation state in [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes"). Confirmed records live in [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), where pgvector and full-text indexes serve a hybrid [RAG](https://en.wikipedia.org/wiki/Retrieval-augmented_generation "Retrieval-Augmented Generation — Grounds a model's answer in documents retrieved at query time") retrieval that an [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") model reranks with cited evidence. Changes leave PostgreSQL through transactional outboxes to [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers"), and events from [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") managed services travel through Lambda to [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers"). [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") deduplication and idempotent sinks make at-least-once delivery safe. Externally reachable parts sit in a [DMZ](https://csrc.nist.gov/glossary/term/demilitarized_zone "Demilitarized Zone — Network zone that holds internet-facing components and separates them from internal networks") behind CloudFront and AWS [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application"), identities come from [Auth0](https://auth0.com/docs "Auth0 — Hosted identity platform that brokers sign-in, single sign-on and multi-factor authentication for applications") with [SAML](https://docs.oasis-open.org/security/saml/v2.0/ "Security Assertion Markup Language — XML standard an identity provider uses to pass sign-in assertions to an application") 2.0 [SSO](https://en.wikipedia.org/wiki/Single_sign-on "Single Sign-On — Lets a user sign in once with one identity provider and reach several applications") to clients' Active Directory, and audit, application and network security events meet in Splunk, which on-call staff reach from Splunk Mobile through Secure Gateway and Spacebridge. The brief gives no quantified outcomes, so every number in this design is a stated assumption or target (`01-requirements.md`).

## Sections

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Users, core and supplementary features, non-functional targets, scale and 5-year storage estimates, assumptions |
| [02-high-level-design.md](02-high-level-design.md) | Service map and naming, architecture diagram, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs"), WebSocket and internal Protobuf APIs, technology mapping, stack gaps |
| [03-data-modeling.md](03-data-modeling.md) | PostgreSQL schemas, DynamoDB item layout, Redis keys, [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") layout, partitioning and evolution triggers |
| [04-deep-dive.md](04-deep-dive.md) | Communication patterns, live dialogue path, outbox and deduplication, RAG indexing and matching, [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") retries, failure modes, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes per query, caching layers, SLOs, logging and tracing, Splunk monitoring and mobile access, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") |
| [06-security.md](06-security.md) | Authentication and authorization, grants per component, encryption, [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") and EU [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Act, DMZ zones, WAF and rate limits |

## Tech Stack and Roles

| Technology | Role |
|---|---|
| Python, FastAPI, [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") | Backend services and workers; REST contracts; draft extraction schemas |
| TypeScript, JavaScript, React, [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers")/[CSS](https://developer.mozilla.org/en-US/docs/Web/CSS "Cascading Style Sheets — Describes how HTML elements are laid out and styled in a browser"), Tailwind CSS | Single-page app for chats, drafts, shortlists and pipeline |
| Zustand | Client state for streamed tokens, draft patches and connection status |
| REST [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), WebSockets | External and internal APIs; token streaming and draft patches |
| Protobuf | Internal matching payloads and every event envelope |
| [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") | Async [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries"); one migration history per schema |
| [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf"), Auth0, SSO, SAML 2.0, Active Directory, [TFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Two-Factor Authentication — Requires a second proof of identity besides a password at sign-in") | Sign-in, per-tenant enterprise SSO, second factor |
| OpenAI API, LangChain, RAG | Reply, extraction and rerank models; embeddings; retrieval chains |
| Langfuse | Prompt versions, LLM traces, cost, evaluation datasets |
| PostgreSQL (RDS) | Domain records, outboxes, vector and full-text search |
| DynamoDB | Conversation turns and drafts; stream source for indexing |
| Redis | Deduplication, in-flight stream buffer, WebSocket tickets, rate limits, cache |
| RabbitMQ | Domain event bus from the outboxes |
| SQS | Buffer for turn events and import jobs from Lambda |
| Pandas, [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") | Cleaning and deduplication of legacy exports |
| HTTPx, Tenacity | Shared async LLM client with the only retry layer |
| PyTest, Jest, React Testing Library | Backend, store and component test gates |
| Splunk, Splunk [HEC](https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector "HTTP Event Collector — Splunk endpoint that receives events over HTTPS, authenticated with a token") | Logs, metrics, audit and threat dashboards; ingest path |
| Splunk Secure Gateway, Splunk Spacebridge | Outbound-only mobile access to dashboards and alerts |
| [FMC](https://www.cisco.com/c/en/us/support/security/defense-center/series.html "Cisco Secure Firewall Management Center — Central console that configures Cisco firewalls and streams their intrusion and connection events"), [SNA](https://www.cisco.com/c/en/us/support/security/stealthwatch/series.html "Cisco Secure Network Analytics — Analyses network flow telemetry to detect threats and unusual host behaviour"), eStreamer | Firewall and network flow events for threat monitoring |
| [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") | All AWS resources and [IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources") |
| AWS (IAM, RDS, Lambda, EKS, [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment"), SQS, [VPC](https://aws.amazon.com/vpc/ "Virtual Private Cloud — Isolated private network in which cloud resources run"), S3, API Gateway, DynamoDB) | Identity, managed data, serverless routing, cluster, registry, network |
| Docker, [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") (k8s), Helm, Linux | Images, orchestration, charts, runtime |
| Claude Code, Gemini | Developer tools; no runtime role |

Components the Environment does not list, and the gap each fills, are in `02-high-level-design.md` under Stack Gaps.

## Requirement Traceability

| Responsibility (quoted from `inputs.txt`) | Addressed in |
|---|---|
| Designed and optimized distributed microservices utilizing FastAPI to expose secure REST APIs and manage core domains (candidate processing, employer portals, and conversational engines) across a unified repository; | `02` Service Map and Naming, API Design; `06` Identity and Access |
| Engineered a highly responsive conversational frontend interface utilizing React and Tailwind CSS, leveraging Zustand to manage complex, real-time state mutations during live AI dialogues; | `04` Live Dialogue Path (frontend state, resume); `05` Automation (store tests) |
| Built real-time bidirectional communication channels via WebSockets within the runtime chat engine to support instantaneous LLM token streaming and seamless frontend synchronization; | `02` API Design (WebSocket); `04` Live Dialogue Path |
| Architected advanced RAG (Retrieval-Augmented Generation) workflows using LangChain and OpenAI models to parse, analyze, and semantically index unstructured text data from live recruitment dialogues; | `04` Live Dialogue Path (real-time evaluation), RAG Indexing and Matching; `03` Schema Design (`chunks`) |
| Configured Splunk Secure Gateway and Spacebridge to securely expose enterprise monitoring data for Splunk Mobile, enabling authenticated access to operational dashboards and critical recruitment platform alerts without direct inbound network exposure; | `05` Splunk Monitoring and Mobile Access |
| Integrated comprehensive security observability by routing application audit logs via Splunk HEC, while aggregating network events from FMC, Secure Network Analytics (SNA), and eStreamer Client Add-On into centralized Splunk dashboards for threat monitoring; | `05` Telemetry (audit logs), Splunk Monitoring and Mobile Access |
| Optimized inter-service communication overhead by migrating heavy [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") payloads to Protobuf, ensuring rapid, schema-validated data exchange between the LLM matching engine and core backend modules; | `02` API Design (internal APIs); `04` Communication Patterns |
| Structured massive event-driven datasets using Pandas and NumPy to clean, parse, and manipulate legacy [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") structures and bulk applicant profiles; | `02` Service Map (`import-worker`); `05` Read and Write Optimizations (bulk writes); `04` RAG Indexing (`indexing.bulk`) |
| Implemented a robust Transactional Outbox pattern alongside Redis-based deduplication layers to ensure strict at-least-once message delivery via RabbitMQ and prevent duplicate side effects upon worker retries; | `04` Event Delivery with Outbox and Deduplication; `03` Ownership Rules |
| Constructed fault-tolerant integrations with third-party LLM gateways by deploying asynchronous HTTPx clients with sophisticated Tenacity retry and backoff strategies; | `04` LLM Client Resilience |
| Provisioned scalable cloud infrastructure utilizing Terraform, configuring AWS API Gateway and Lambda for serverless event routing, alongside DynamoDB for high-throughput, low-latency conversational state storage; | `02` Service Map (Lambdas), Architecture Diagram; `03` Conversation State in DynamoDB; `05` Automation |
| Collaborated with infrastructure and security teams on deploying externally accessible API components within a DMZ architecture, ensuring secure traffic isolation, controlled ingress routing, and protected communication between services; | `06` Perimeter Defense and the DMZ, Data Protection (in transit) |
| Implemented Splunk Mobile deployment by integrating it with Splunk Enterprise and Secure Gateway, enabling secure remote monitoring of platform health and operational alerts; | `05` Splunk Monitoring and Mobile Access |
| Guarded application reliability and frontend state integrity by authoring comprehensive Jest and React Testing Library suites, coupled with exhaustive PyTest coverage for backend AI endpoints. | No architectural implication — a testing practice; the CI gates it feeds are in `05` Automation |
