# Reliability & Observability

*[AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Conversational Recruitment & Candidate Matching Ecosystem*

## Table of Contents

- [Read and Write Optimizations](#read-and-write-optimizations)
- [Caching Strategy](#caching-strategy)
- [Telemetry](#telemetry)
- [Splunk Monitoring and Mobile Access](#splunk-monitoring-and-mobile-access)
- [Automation](#automation)

---

## Read and Write Optimizations

Every index below serves a named query. Columns are the ones `03-data-modeling.md` declares.

| Table | Index | Type | Query it serves |
|---|---|---|---|
| `matching.chunks` | `embedding vector_cosine_ops`, `m = 16`, `ef_construction = 64` | [HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") | Vector leg of hybrid retrieval, `ORDER BY embedding <=> :q LIMIT 500` |
| `matching.chunks` | `content_tsv` | [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") | Full-text leg of hybrid retrieval, must-have skill terms |
| `matching.chunks` | `(candidate_id, source_type, source_ref, content_hash)` | Unique B-tree | Idempotent upsert from `indexing-worker`; delete on erasure |
| `matching.chunks` | `(owner_tenant_id)` | B-tree | Visibility filter and tenant offboarding |
| `matching.job_embeddings` | `embedding vector_cosine_ops` | HNSW | Candidate "jobs for me" and chat suggestions from past jobs |
| `matching.match_runs` | `(job_id, finished_at DESC)` | Composite | Latest run for a job |
| `matching.match_results` | `(run_id, rank)` | Composite | Ordered shortlist page |
| `candidate.candidates` | `(COALESCE(owner_tenant_id, '00000000-0000-0000-0000-000000000000'), email_hash) WHERE deleted_at IS NULL` | Unique partial | Deduplication during import and sign-up |
| `candidate.candidates` | `profile jsonb_path_ops` | GIN | Recruiter filters on skills and languages |
| `candidate.consents` | `(candidate_id, purpose, recorded_at DESC)` | Composite | Current consent and consent history |
| `employer.jobs` | `(tenant_id, status, published_at DESC)` | Composite | Job lists in the employer portal |
| `employer.applications` | `(job_id, candidate_id)` unique; `(job_id, stage)` | B-tree | Duplicate applications; pipeline board |
| every `outbox` | `(id) WHERE published_at IS NULL` | Partial | Relay poll; stays small because published rows leave the index |
| [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes") `conversations` | `gsi1_owner`; [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") on `expires_at` | [GSI](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html "Global Secondary Index — DynamoDB index with its own partition key that serves an alternative access pattern"), TTL | Conversation list; transcript retention |

- **HNSW settings.** Queries set `hnsw.ef_search = 100` and `hnsw.iterative_scan = relaxed_order`. Without iterative scans, the visibility filter runs after the index returns its first `ef_search` rows. A tenant's private applicants could then be filtered away before enough rows remain.
- **Bulk writes.** `import-worker` writes candidates in batches of 1,000 rows with multi-row `INSERT ... ON CONFLICT`, one transaction per batch, including the batch's outbox rows.
- **Initial index build.** The 10 M-chunk HNSW build for the legacy pool runs once, with `maintenance_work_mem` raised and parallel workers, before the index is used.
- **Connection limits.** Each pod uses a [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") pool of 10 connections. About 40 pods at peak need about 400 connections, which fits the [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") limit for the instance in `03-data-modeling.md`. RDS Proxy is the evolution trigger if the pod count doubles.

> **Verify Before Build:** `hnsw.iterative_scan` exists only in pgvector 0.8.0 and later. Run `SELECT * FROM pg_available_extension_versions WHERE name = 'vector'` on the chosen RDS engine version; without it, raise `ef_search` and accept lower recall for small tenants.

## Caching Strategy

| Layer | What | Policy | Invalidation |
|---|---|---|---|
| [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") (CloudFront) | [SPA](https://en.wikipedia.org/wiki/Single-page_application "Single Page Application — Web application that updates its content in place without full page reloads") assets | Hashed file names cached for 1 year; `index.html` `no-cache` | A new deploy changes the file names |
| CDN | [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") and WebSocket paths | Never cached; they carry user data | — |
| API Gateway | Authorizer results | 300 s per token | Token expiry; a revoked user can keep access for up to 300 s (see `06-security.md`) |
| [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") | `cache:job:<id>:v<version>` | Cache-aside, 1 h | Versioned key: a new job version is a new key, so a stale read is impossible, and old keys expire |
| Redis | `emb:<model>:<sha256>` | Cache-aside, 30 days | Content hash: the same text always has the same vector for the same model |
| Application | [Auth0](https://auth0.com/docs "Auth0 — Hosted identity platform that brokers sign-in, single sign-on and multi-factor authentication for applications") [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") | In memory, 10 min | Unknown `kid` forces a refresh |
| Application | Langfuse prompts | [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") cache, 60 s | A new prompt label reaches all pods within 60 s |
| Application | Skill taxonomy | In memory, reload every 15 min | — |

**Cache-aside, not write-through.** Writes go to [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") through the outbox, and events already carry the new version. Write-through would put Redis in the write transaction's failure path for no gain, because versioned keys cannot serve stale data.

**Not cached on purpose.** Consent is always read from PostgreSQL in `candidates:batchGet`, because a cached consent could show a candidate who has withdrawn it. Candidate features are not cached either, because 200 reads by primary key take a few milliseconds.

## Telemetry

**Metrics: SLIs and SLOs.**

| [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health") | [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") | Source |
|---|---|---|
| Time to first token | p95 ≤ 1.5 s over 28 days | `chat-engine` histogram, user message received → first delta sent |
| Chat turn success | ≥ 99.5% of turns without `turn.failed` | `chat-engine` counter |
| API availability | ≥ 99.9% non-5xx at API Gateway | API Gateway metrics |
| WebSocket connect success | ≥ 99.9% | [ALB](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html "Application Load Balancer — AWS layer-7 load balancer that routes HTTP and WebSocket traffic to targets") and `chat-engine` |
| Index freshness | p95 ≤ 60 s, `candidate.confirmed` → chunk searchable | `indexing-worker` |
| Match run duration | p95 ≤ 60 s | `matching-engine` |
| Outbox publish lag | p99 ≤ 5 s, `created_at` → `published_at` | Relays |
| Dead-letter depth | 0 for more than 10 min | [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") and [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers") DLQs |
| [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") cost | Tokens and cost per conversation and per tenant | Langfuse |

Alerts use multi-window burn rates on these SLOs: page at a 14× burn over 1 hour, open a ticket at a 3× burn over 1 day.

**Structured logging.** Every service logs [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") to stdout with `timestamp`, `level`, `service`, `trace_id`, `span_id`, `tenant_id`, `user_ref` (hashed), `conversation_id` and `event_id`. Prompts, replies and [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") text never go to logs. They go to Langfuse after masking (`06-security.md`). The Splunk OpenTelemetry Collector ships the logs to the `recruit_app` index through [HEC](https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector "HTTP Event Collector — Splunk endpoint that receives events over HTTPS, authenticated with a token").

**Audit logs** are a separate stream. They are domain events written through the outbox to the `audit.events` exchange. `audit-shipper` consumes queue `audit.hec`, sends batches to the `recruit_audit` index with HEC indexer acknowledgement, and acks RabbitMQ only after Splunk confirms. This is how the design guarantees that an audit event is never lost.

**Distributed tracing.** The OpenTelemetry SDK instruments [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"), HTTPx and SQLAlchemy. [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") `traceparent` travels in [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") headers, RabbitMQ message headers, SQS message attributes and the Protobuf envelope. So one trace id covers a turn, its indexing event and a later match run. Langfuse holds the LLM side of each trace (prompt version, tokens, latency, scores) and stores the OpenTelemetry trace id as metadata. Every log line has the trace id, so in Splunk one search joins logs, audit and the Langfuse link.

> **Deep Dive Reference:** Span storage — the Environment has no trace backend. Traces are joined today through ids in Splunk and Langfuse. Add a span store (Splunk [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production") or an open-source one) when a latency incident cannot be explained from those two.

## Splunk Monitoring and Mobile Access

| Splunk index | Source | Path |
|---|---|---|
| `recruit_app`, `recruit_metrics` | Pod logs and metrics | Splunk OpenTelemetry Collector → HEC |
| `recruit_audit` | Audit events | `audit-shipper` → HEC |
| `auth0` | Sign-in, [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity") and admin events | Auth0 log stream → HEC |
| `netsec_fmc` | Intrusion, connection and file events from the firewalls [FMC](https://www.cisco.com/c/en/us/support/security/defense-center/series.html "Cisco Secure Firewall Management Center — Central console that configures Cisco firewalls and streams their intrusion and connection events") manages | eStreamer client add-on pulling from FMC over [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") with a client certificate |
| `netsec_sna` | Flow alarms and host behaviour from [SNA](https://www.cisco.com/c/en/us/support/security/stealthwatch/series.html "Cisco Secure Network Analytics — Analyses network flow telemetry to detect threats and unusual host behaviour") | SNA's Splunk integration |

**Dashboards.** Platform health (the SLO table above), LLM cost and errors, queue depth, and threat monitoring. The threat dashboard joins firewall intrusion events and SNA alarms with `auth0` sign-in failures and API Gateway 4xx bursts by source IP. So one attacker's network scan and the password spraying that follows show up on one screen.

**Splunk Mobile.** Splunk Secure Gateway runs on the Splunk Enterprise search head. It opens an **outbound** TLS connection to Splunk Spacebridge, and Splunk Mobile reaches the search head only through that relay. No inbound port is opened. Messages between the app and Secure Gateway are end-to-end encrypted, so Spacebridge relays them without reading them. Each device is registered to a Splunk user with a one-time code, and Splunk roles limit which dashboards and alerts it sees. Critical alerts (SLO page, dead-letter depth, a threat correlation hit) go to on-call phones as Splunk Mobile push notifications.

> **Verify Before Build:** The Secure Gateway and Spacebridge behaviour above (outbound-only connection, end-to-end encryption, device registration, Spacebridge region) and the eStreamer add-on for your FMC version — check the Splunk Secure Gateway documentation for the Splunk Enterprise version in use, check whether Cisco has moved eStreamer ingestion into a newer Splunk app, and check that the Auth0 plan in use includes a Splunk log stream.

## Automation

**[CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") pipeline** (runs on every pull request against the monorepo, and only for changed services and libraries):

1. Lint and type checks for Python and TypeScript.
2. PyTest: unit tests, plus API tests for the AI endpoints with the [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") API replaced by recorded responses. Integration tests run against PostgreSQL with pgvector, Redis and RabbitMQ in containers, including an outbox crash-and-replay test that must end with exactly one side effect.
3. Jest and React Testing Library: store tests that feed out-of-order `draft.patch` frames and reconnect sequences to the Zustand stores, and component tests for streaming and `turn.failed`.
4. Protobuf breaking-change check against `main`.
5. [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy"): `upgrade head` on an empty database and on a copy of the previous schema. Migrations follow expand, then migrate, then contract, so the old and new pod versions can run on one schema.
6. LLM evaluation gate: a changed prompt or model runs the Langfuse evaluation dataset. Extraction field accuracy and rerank [NDCG](https://en.wikipedia.org/wiki/Discounted_cumulative_gain "Normalized Discounted Cumulative Gain — Ranking metric that rewards relevant results appearing near the top") must not fall more than 2 points below the current production label.
7. Docker build, image scan on push to [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment"), Helm lint and template tests.
8. `terraform plan` for infrastructure changes, reviewed by a person before `apply`.

**Deployment.**

- **Stateless services:** a canary with one new pod among the stable pods for 30 minutes, promoted by `helm upgrade` when error rate and latency SLIs hold, and rolled back with `helm rollback` otherwise.
- **`chat-engine`:** the same canary, but new sockets reach the canary and old sockets drain through `server.draining`. `terminationGracePeriodSeconds` is 150, so a 120 s drain fits.
- **Prompts:** a new prompt version goes out as a Langfuse label to 10% of conversations, and then to all after its scores hold. Rolling back a prompt needs no deploy.
- **Lambdas and [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") resources:** [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files"), with Lambda aliases and a weighted alias for `api-authorizer`.
- **Environments:** `dev`, `staging` and `prod` are separate AWS accounts with the same Terraform modules. Terraform state is in [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") with locking.
- **Stateful charts** (`recruit-redis`, `recruit-mq`): upgraded one pod at a time with PodDisruptionBudgets that allow one pod down, never in the same window as an application release.

> **Verify Before Build:** Terraform state locking — native S3 locking (`use_lockfile`) needs Terraform 1.10 or later; older versions need a DynamoDB lock table. Check the pinned Terraform version.
