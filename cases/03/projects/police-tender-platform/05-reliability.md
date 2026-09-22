# Reliability & Observability

**Tender Platform for a MENA Police Department**

## Table of Contents

- [Read/Write Optimizations](#readwrite-optimizations)
- [Caching Strategy](#caching-strategy)
- [Telemetry](#telemetry)
- [Alerting](#alerting)
- [Automation: CI/CD and Deployment](#automation-cicd-and-deployment)
- [Environments and Configuration](#environments-and-configuration)
- [Infrastructure as Code](#infrastructure-as-code)
- [Backup and Restore](#backup-and-restore)

## Read/Write Optimizations

Indexes are derived from the access patterns below, and every column named here is declared in `03`. Anything not on this list is served by a primary key or a foreign-key index.

| Access pattern | Index | Notes |
|---|---|---|
| Vendor browses open tenders by closing date | `tender (status, closes_at)` | Covers the default portal listing and the closing-soon widget |
| Vendor or officer filters by category | `tender (category_id, status, published_at DESC)` | The three-column order matters: equality, equality, then the sort |
| Officer sees their unit's pipeline | `tender (org_unit_id, status)` | |
| Resolving a published version | `tender_version (tender_id, version_no)` unique | Also the uniqueness constraint |
| Criteria for a version, in display order | `criterion (tender_version_id, display_order)` | |
| Vendor lookup by name in the CRM | `vendor_org` [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") trigram on `legal_name` | Fuzzy staff-side lookup; distinct from the full-text search in `opensearch-corpus`, which covers document bodies, not vendor names |
| Vendor lookup by registration number | `vendor_org (registration_no)` unique | |
| Qualification expiry sweep | `qualification (expires_at) WHERE verified_at IS NOT NULL` | Partial: unverified qualifications never expire |
| Debarment check during eligibility | `debarment (vendor_org_id, effective_from, effective_to)` | On the sealing path, so it is the one index whose plan is verified in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") |
| CRM timeline page | `crm_activity (vendor_org_id, occurred_at DESC)` | |
| Documents of an owner | `document (owner_kind, owner_id)` | |
| Scan and extraction backlog | `document (scan_state) WHERE scan_state = 'pending'` and `document (extract_state) WHERE extract_state = 'pending'` | Partial indexes stay tiny regardless of corpus size |
| One bid per vendor per tender | `bid (tender_id, vendor_org_id)` unique | The constraint is the guard, not application logic |
| Bids of a tender by state | `bid (tender_id, state)` | |
| Manifest expansion at unsealing | `manifest_entry (bid_manifest_id, display_order)` | |
| Ledger chain verification | `submission_ledger (tender_id, seq)` unique, `submission_ledger (bid_id)` | Verification walks the chain in `seq` order for one tender |
| Evaluator's scorecards | `scorecard (evaluator_assignment_id, bid_id)` unique | |
| Scores of a scorecard | `score (scorecard_id, criterion_id)` unique | |
| Consensus and award lookup | `consensus_scorecard (evaluation_session_id, bid_id)` unique | |
| Latest artifact for a subject | `ai_artifact (subject_kind, subject_id, created_at DESC)` | |
| Resolving a citation back to a document | `ai_citation (ai_artifact_id)`, `ai_citation (document_id)` | |
| Audit query by actor or subject | Per-partition `audit_event (actor_id, occurred_at)` and `audit_event (subject_kind, subject_id, occurred_at)` | Created on each monthly partition, not on the parent |
| Outbox relay poll | `event_outbox (id) WHERE published_at IS NULL` | Partial, so the relay's scan cost is proportional to the backlog, not to history |
| Dispatch sweep | `notification_outbox (scheduled_for) WHERE state = 'pending'` | |

**Write-side choices.** The sealing transaction touches four tables and holds one advisory lock; it takes no other lock and performs no fan-out, which is what keeps the worst case in `04` under 800 ms. Bulk imports use `COPY` into a staging table followed by a set-based merge rather than row-by-row inserts. `audit_event` is inserted with no returning clause and never read on a write path.

> **Verify Before Build:** the `debarment` range check is only index-assisted if the query is written as two range predicates on `effective_from` and `effective_to` rather than as a `BETWEEN` against `now()` that the planner cannot push down, and [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") may prefer a sequential scan on a small `debarment` table anyway. Confirm with `EXPLAIN (ANALYZE, BUFFERS)` against production-sized data; a `daterange` column with a [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") index is the fallback if the plan is wrong.

## Caching Strategy

Three layers, each with an explicit invalidation rule. Every cached value has a source of truth in `postgres-core`, and **no cached value is read on the eligibility, sealing or scoring paths** — the rule from `01`, enforced by the services rather than by discipline.

| Layer | Contents | Strategy | Invalidation |
|---|---|---|---|
| **CloudFront** | Public tender notice board, static portal assets, `GET /v1/documents/{id}` status | Edge cache; 5 s [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") on the status endpoint, 5 min on the notice board, immutable hashed assets | TTL only, plus an explicit invalidation on `TenderPublished` and `TenderCancelled` |
| **`redis-cache`** | Tender detail and listing pages, vendor summary records, [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), rate-limit counters, idempotency keys, query embeddings, [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") map-stage results | Cache-aside; keys carry the entity's version (`tender:{id}:v{current_version_id}`) | Event-driven delete on the matching domain event, with TTL as the backstop: 10 min for listings, 1 h for vendor records, 24 h for JWKS and idempotency keys, 30 days for embeddings and map results |
| **Application** | Criteria sets and reference data (categories, qualification types, scoring scales) | In-process, 60 s TTL | Time only. These change on the order of weeks, and a 60 s window is cheaper than a cache-coherence protocol across twelve pods |

**Write-through is used nowhere.** Every cached entity here is read far more often than it is written, and cache-aside keeps a [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") failure to a latency event rather than a write failure. The version-keyed tender keys mean a publish never needs to find and delete the old entries — they simply stop being addressed and expire.

**Stampede protection** on the tender detail key: a miss takes a short-lived `SET NX` lock, and concurrent readers wait up to 50 ms for the winner's fill before falling through to Postgres. This matters when a high-profile tender publishes and thousands of vendors open it in the same minute.

## Telemetry

**Metrics.** Every service exports OpenTelemetry metrics to CloudWatch. The SLIs are the SLOs from `01`, measured where the user feels them — at `apigw-edge`, not inside the pod.

| [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health") | [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") | Error budget |
|---|---|---|
| Submission path availability during an open tender window | 99.9% monthly | 43 min/month |
| Internal CRM and analytics availability | 99.5% monthly | 3 h 39 min/month |
| Tender browse p95 | < 250 ms | — |
| Hybrid search p95 | < 700 ms | — |
| Bid sealing p95 | < 1.2 s | — |
| Requirement extraction p95 | < 6 min | — |
| Proposal summarization p95 | < 3 min | — |
| Search projection lag p95 | < 30 s | — |

Domain metrics matter as much as infrastructure ones here: sealing attempts and rejections by reason, documents in `scan_state = 'pending'`, AI artifacts quarantined for unresolvable citations, ledger chain verification result, and model token spend per tender.

**Structured logging.** [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") to stdout, shipped by Fluent Bit to Logstash, enriched with the [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") and trace context, stored in `es-logs`, read in Kibana. Every line carries `request_id`, `trace_id`, `actor_kind`, `actor_id`, `tender_id` where known, and the service and version. **No log line ever carries bid content, extracted document text, a model prompt body or a model completion** — Logstash drops fields matching the redaction rules in `06`, and a CI test asserts a known marker string planted in a bid does not appear in the shipped log.

**Distributed tracing.** OpenTelemetry auto-instrumentation for [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"), [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle"), boto3 and the [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") client, exported through a collector DaemonSet to AWS X-Ray. Trace context is propagated across the async hops — carried in SQS message attributes and [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") headers — so a trace covers upload, scan, extraction, chunking and indexing as one picture rather than five. Sampling: 100% of sealing, unsealing, award and AI jobs; 5% of reads.

## Alerting

Paging alerts are restricted to things a human must act on now.

| Alert | Condition | Severity |
|---|---|---|
| Sealing failures | Any sealing `5xx` while a tender window is open | Page |
| Ledger chain mismatch | Recomputed head ≠ audit-sink head | Page, handled as a security incident |
| Database failover | RDS failover event | Page |
| Document scan backlog | `scan_state = 'pending'` older than 15 min | Page while a window is open |
| Error budget burn | 2% of the monthly budget consumed in 1 h | Page |
| DLQ depth | Any message in `sq-document-intake-dlq` or `sq-ai-jobs-dlq` | Ticket |
| Projection lag | Search lag p95 > 30 s for 10 min | Ticket |
| Qualification expiry sweep failed | Sweep did not complete in its window | Ticket |
| Model spend | Daily token spend > 150% of the 7-day trailing mean | Ticket |
| AI quarantine rate | > 10% of artifacts quarantined over 24 h | Ticket — signals a prompt or model regression |

## Automation: CI/CD and Deployment

GitHub Actions is the only path to production. No human holds AWS credentials that can deploy; the workflow assumes a role via GitHub's [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") provider, scoped per environment.

**Pipeline**, in order, each stage blocking the next:

1. `ruff` and `mypy --strict` on every package.
2. Unit tests.
3. Integration tests against real dependencies in Docker Compose — PostgreSQL, Redis, OpenSearch, LocalStack for S3/SQS/KMS, and a recorded model stub so no test reaches the OpenAI [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data").
4. **Contract tests on the sealing path**, including a known-fail case: a bid committed after `closes_at` must be rejected, and the test fails if it is accepted. A gate that has never failed has not been shown to test anything.
5. Migration check — [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") upgrade then downgrade against a restored copy of the staging schema, asserting the expand/contract discipline holds.
6. Performance benchmarks — sealing latency and hybrid search latency against a seeded corpus, compared against the budget in `04`; a regression beyond 20% fails the build rather than filing a ticket.
7. Container build, `trivy` scan, push to ECR with scan-on-push, image tagged by commit [SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity").
8. Deploy to staging, smoke suite, then a manual approval gate for production.

**Deployment.** Alembic migrations run as a Kubernetes `Job` before the rollout, expand/contract only, so the previous image always runs against the new schema. Services roll normally. `ai-service` and `search-service` deploy as a canary at 10% of traffic via ALB weighted target groups for 30 minutes, watched on error rate and p95 — they are the two whose behaviour depends on a third party and on query shapes that staging traffic does not reproduce. `bid-service` is deliberately **never** deployed while a tender window is within an hour of closing; the pipeline checks `closes_at` and refuses.

**Rollback** is a redeploy of the previous image tag. Because migrations are additive, no rollback ever requires a schema reversal.

## Environments and Configuration

Four environments — `local`, `dev`, `staging`, `prod` — with one configuration model across all of them.

- **Local** is Docker Compose: every dependency runs as a container, LocalStack stands in for the AWS services, and the model client is a recorded stub. A developer needs no cloud account.
- **`dev` and `staging`** are Kubernetes namespaces in one non-production EKS cluster, separated by namespace, network policy and separate IAM roles. **`prod` is a separate cluster in a separate AWS account** — namespace isolation is not a security boundary for bid content.
- Configuration is environment variables validated by a [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") settings model at startup; a missing or malformed value fails the pod immediately rather than at first use. Secrets are never environment values in a manifest: they are pulled from Secrets Manager by the External Secrets Operator into a Kubernetes secret, mounted, and rotated by the operator.
- The Compose file and the Helm values share one schema, so the same settings model validates both and a variable cannot exist locally but be missing in production.

## Infrastructure as Code

[Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") describes every AWS resource — VPC and subnets, RDS, ElastiCache, OpenSearch, MSK, S3 buckets and their policies, SQS queues and DLQs, Lambda functions, EKS and its node groups, ECR, Cognito pools, IAM roles and IRSA trust policies, Secrets Manager entries, KMS keys and grants, Route 53 zones and ACM certificates, CloudFront and the [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") rule set.

State lives in `s3-tfstate` with DynamoDB locking, one state file per environment. `terraform plan` runs on every pull request and posts the diff; `terraform apply` runs only from the protected branch, only through the OIDC role. Nothing is created by hand — a resource that exists without a Terraform declaration is treated as an incident, and a drift check runs nightly against every environment.

## Backup and Restore

- **`postgres-core`** — automated snapshots with a 35-day [PITR](https://www.postgresql.org/docs/current/continuous-archiving.html "Point in Time Recovery — Restores a database to a specific past moment using base backups and archived logs") window, meeting the 5-minute [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") in `01`. Snapshots are copied to a separate account so a compromise of the production account cannot destroy them.
- **`s3-documents`** — versioning on every prefix, Object Lock in compliance mode on `audit/`. There is no delete path for the ledger or the audit sink, by design.
- **`opensearch-corpus`** — not backed up. It is a projection, rebuilt from `document.events` and the extracted text in S3; a restore is a replay, and the replay is exercised quarterly.
- **`es-logs`** — not backed up; 30-day hot, 90-day warm, then deleted.
- **Restore drills** run quarterly: a PITR restore into an isolated account, a ledger chain verification against the restored data, and a projection replay. The drill is the only evidence the [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") is real, and its result is recorded rather than assumed.
