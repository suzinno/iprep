# Requirement Clarification & Scoping

*Robotic & Industrial [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Intelligence Platform*

**Table of Contents**
- [Context and Reading Notes](#context-and-reading-notes)
- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Scope Boundaries and Assumptions](#scope-boundaries-and-assumptions)

## Context and Reading Notes

The platform takes in operational telemetry from robot fleets and industrial sensors. It turns that telemetry into live status, alarms and rollups, and runs AI workflows on top of it: contextual analysis of an alarm or a time window, image-based inspection, and generation of documents such as maintenance reports that a person reviews before they count. It runs on [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system"), with [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services on [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS") and AWS-managed orchestration (Step Functions, Lambda, [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers"), [SNS](https://aws.amazon.com/sns/ "Amazon Simple Notification Service — Managed publish-subscribe topics that fan one message out to many subscribers")) for asynchronous work.

- **The brief has no quantified outcomes.** It names no percentage, latency or volume. Every figure in this document set is a design target derived from the scale estimate below, not a claim about what the original system achieved.
- **"Real-time" means seconds-level freshness**, not hard real-time control: live status within 30 s of the data being produced. The platform observes and advises; it never sends a command to a robot. That boundary keeps the platform outside the safety-control loop, and 06 relies on it.
- **Naming.** The component catalogue in 02 owns every service, store, queue and state machine name; this file uses those names.

## Target Audience

A **[B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers")**, multi-tenant platform. Each tenant is an industrial customer — a manufacturer, warehouse operator or plant owner — with one or more sites.

| Persona | Tenant role | What they do on the platform |
|---|---|---|
| Reliability or process engineer | `engineer` | Investigates alarms, starts analyses, curates knowledge documents and datasets |
| Line operator or shift lead | `operator` | Watches fleet status, starts image inspections, reads shift summaries |
| Quality inspector | `reviewer` | Reviews AI inspection findings and generated documents; approves, edits or rejects |
| Tenant administrator | `tenant_admin` | Manages users, devices, alarm rules, integrations and the tenant's AI budget |
| Auditor | `auditor` | Read-only audit-log lookups |
| Edge gateway | machine client | Pushes telemetry batches from the plant network; asks where to resume after an outage |
| AI agent | internal | Reads platform data through controlled [MCP](https://modelcontextprotocol.io/ "Model Context Protocol — Open protocol that exposes tools and data to AI agents through a standard interface") tools, on behalf of one run |

The platform team operates the system; it is not a tenant and has no standing access to tenant data (06).

## Functional Requirements

**Must have**

1. **Telemetry ingestion and processing.** Accept batched telemetry from edge gateways over [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit"), apply each batch exactly once per consumer, archive the raw batch, maintain rollups and live status, and evaluate alarm rules. Gateways can ask for their last archived sequence number and replay from it.
2. **AI analysis runs.** Analyse an alarm, a device or a time window with an agent that combines retrieved documents, telemetry and maintenance history. Each run is orchestrated with retries, output validation and a terminal status the user can see.
3. **Image inspection and robotic datasets.** Upload image sets and recorded datasets through direct-to-storage uploads; a multimodal model returns structured findings — defect type, severity, bounding box, rationale — for each image.
4. **Generation with human review.** Generate maintenance reports, procedures and shift summaries. Every generated document and every inspection result passes a validation gate and then a human reviewer before it can be exported.
5. **Tenant-isolated access with an audit trail.** [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") login, role-based permissions inside a tenant, and an audit record for every mutation, sensitive read and AI tool call.

**Nice to have**

1. **Interactive assist** — a synchronous question about one device, answered within seconds, for questions too small to justify a run.
2. **Automatic follow-ups** — a high-severity analysis triggers a draft maintenance report without a user asking.
3. **Outbound webhooks** to a tenant's [CMMS](https://en.wikipedia.org/wiki/Computerized_maintenance_management_system "Computerized Maintenance Management System — Tracks industrial assets, work orders and maintenance history") when a run completes or a work-order draft is approved.
4. **Work-order drafts** proposed by an agent and confirmed by a person.
5. **Per-tenant AI usage reporting** — tokens, run counts and failure rates per day.

## Non-Functional Requirements

| Attribute | Target | Where the mechanism lives |
|---|---|---|
| Availability | 99.9% per 30 days for `platform-api`, including ingest; at least 99% of AI runs finish with an output rather than failing, excluding budget rejections and cancellations | Multi-[AZ](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/ "Availability Zone — Isolated group of data centres within an AWS Region, used to survive a single-site failure") topology and failover in 04 |
| Latency — reads | p95 < 300 ms for indexed read endpoints | Indexes and caching in 05 |
| Latency — ingest | p95 < 500 ms from request to acknowledgement | Ingest path in 04 |
| Freshness | Live device status p95 < 30 s old | Telemetry fan-out in 04 |
| AI completion | p95: analysis < 5 min; inspection of up to 20 images < 8 min; generation < 15 min; assist < 8 s | Latency budgets in 04 |
| Scalability | 3× growth in gateways and AI runs with configuration changes, not redesign | Evolution triggers in 03 and 04 |
| Durability | No telemetry loss for any platform outage under 24 h; [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") ≈ 0 within the region | Edge buffering, Multi-AZ, backups in 04 |
| Cost control | Each tenant's AI spend is capped by a daily token budget | Budget check in 04 |

**[CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning.** The system is not one point on the CAP spectrum; each store takes the position its data needs.

- **Runs, reviews and operational records (PostgreSQL) — [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability").** One writer with a synchronous standby. During a failover (60–120 s) writes are rejected rather than allowed to diverge; a review decision must never be lost or applied twice.
- **Telemetry pipeline — [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency"), eventually consistent.** Ordered per gateway, archived and rolled up within seconds. A reader may see status up to 30 s old, and during a partition ingest keeps accepting batches.
- **DynamoDB** — checkpoint updates are conditional writes, consistent within an item; audit lookups through a secondary index are eventually consistent.
- **[Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") caches** — eventually consistent, bounded by each key's [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") (05).

Under [PACELC](https://en.wikipedia.org/wiki/PACELC_design_principle "Partition, Availability, Consistency, Else Latency, Consistency — Extends CAP by naming the latency against consistency trade that applies when there is no partition"), normal operation chooses latency over consistency for telemetry reads and caches, and consistency over latency for runs, outputs and reviews.

## Scale Estimation

**Assumptions (year 1).** The platform grows to 3× these figures by year 5; with roughly linear growth, 5-year cumulative storage is about 10× the year-1 annual volume.

| Input | Value |
|---|---|
| Tenants / sites | 12 / 40 |
| Edge gateways | 400, each serving about 5 robots and 15 sensors |
| Robots / sensors | 2,000 / 6,000 |
| Signals | 40 per robot and 1 per sensor, sampled at 1 Hz → 86,000 samples/s fleet-wide |
| [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") series kept in PostgreSQL | 8 per robot + 1 per sensor = 22,000 series |
| Batch interval | 15 s per gateway |
| Users | 1,200 registered, 600 [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day") |
| AI work per day | 3,000 analyses, 1,500 inspections averaging 12 images, 500 generations, 6,000 assist queries |

**Request rates**

- **Ingest:** 400 gateways ÷ 15 s = 27 batches/s on average; 80/s at peak, when gateways replay a buffer after a network outage.
- **User APIs:** 600 DAU × about 400 requests/day, mostly dashboard polling = 240k/day → 3 [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") on average. Peak about 110 QPS: 200 open dashboards polling 3 queries every 15 s (40 QPS), up to 150 active runs polled every 3 s (50 QPS), plus interactive use.
- **[API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Gateway total at peak:** about 200 requests/s.
- **[LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") calls:** analysis 7 per run (21k), inspection 13 per run (19.5k), generation 12 per run (6k), assist 2 per query (12k) → about 58,500 calls/day. With 60% in a 10-hour day shift that is 1 call/s, peaking at 2.5 calls/s. At about 4,000 input tokens per call, peak demand is about 600k input tokens per minute — the binding external limit in the design (04).
- **MCP tool calls:** about 4 per analysis and 1 per assist query → about 18,000/day.
- **Telemetry checkpoint writes:** 27 batches/s × 3 consumers = 81 conditional writes/s.

**Storage**

| Store | Year-1 growth | 5-year total |
|---|---|---|
| [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") `telemetry-raw` | 86,000 samples/s × ~12 B compressed ≈ 1 MB/s → 90 GB/day → 33 TB/year | ~330 TB, mostly in archive tiers (05) |
| S3 `robotic-datasets` | Inspection images 18k/day × 2 MB (13 TB/year) + recorded runs 1 TB/month (12 TB/year) | ~250 TB |
| S3 `ai-artifacts` | Retained outputs 50 MB/day; intermediates 5 GB/day, expired after 14 days | ~0.2 TB retained + 70 GB rolling |
| PostgreSQL | 5-min rollups: 6.3M rows/day ≈ 1 GB/day, kept 30 days (30 GB rolling). Hourly rollups: 193M rows/year ≈ 25 GB, kept 2 years. Document chunks: 3.6M ≈ 21 GB with index. Runs and outputs: ≈ 36 GB/year | ~650 GB: rollups and chunks at 3× plus 5 years of runs and outputs |
| DynamoDB `telemetry_checkpoints` | 400 gateways × 3 consumers = 1,200 items | Negligible |
| DynamoDB `audit_log` | ~110k events/day × 1 KB = 110 MB/day, 400-day TTL → 45 GB hot | 130 GB hot at 3×; ~0.4 TB archived to S3 |

**What the numbers decide.** About 650 GB and under 2,000 row writes per second fit a single PostgreSQL primary with no sharding (03). Eighty messages per second at peak should sit well inside the ordered-topic throughput limits; 04 marks the quota to confirm. Raw telemetry at 330 TB belongs in object storage, not a database. The token rate, not compute, decides how many AI workers run (04).

## Scope Boundaries and Assumptions

- **Out of scope:** commanding or controlling robots; edge gateway firmware; training or fine-tuning models, since the platform uses Bedrock foundation models; the CMMS itself, which the platform notifies but does not replace.
- **Gateways buffer 24 h** of telemetry locally and replay in sequence order. This assumption carries the telemetry durability target.
- **One AWS region per deployment**, chosen by tenant data residency; an EU tenant is served from an EU region (06).
- **Tenant count stays under about 40** over five years, which keeps one partition per tenant practical for vector search (03).
- **Rollups cover KPI signals only.** Full-resolution signals stay in S3 and are read in bounded windows (04).
