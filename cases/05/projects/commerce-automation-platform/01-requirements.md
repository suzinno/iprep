# Requirement Clarification & Scoping

*Intelligent Commerce Automation Platform*

## Table of Contents

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Scope Boundaries](#scope-boundaries)

## Target Audience

The platform is a multi-tenant [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") [SaaS](https://en.wikipedia.org/wiki/Software_as_a_service "Software as a Service — Delivers an application as a hosted service that customers use rather than install") product. Merchants pay for it, and their shoppers use part of it without knowing it exists.

| Audience | Who | How they reach the system |
|---|---|---|
| Merchants (primary, B2B) | Mid-market and enterprise sellers on several sales channels: catalog managers, pricing managers, analysts, owners | `merchant-console` React app; partner [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") with [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") client credentials |
| Shoppers (indirect, [B2C](https://en.wikipedia.org/wiki/Retail "Business to Consumer — Describes commerce sold directly to individual consumers")) | Visitors to a merchant's own storefront | `storefront-widget` embedded in the storefront: search, recommendations, chat |
| Sales channels and suppliers | Marketplaces and shop platforms that send order webhooks; suppliers that send catalog feeds | Signed webhooks; file uploads to [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") |
| Internal operations | Platform engineers and support staff | Grafana, CloudWatch, admin endpoints |

A **tenant** is one merchant organisation. Every table, cache key, event and agent run carries a `tenant_id`, and no data from one tenant is ever used to serve or price for another (see `06-security.md`).

## Functional Requirements

### Must have

1. **Bulk catalog ingestion and [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") enrichment.** Merchants upload supplier feeds of up to 2M rows. [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") Glue cleans, de-duplicates and chunks them. Amazon Bedrock extracts structured attributes and writes [SEO](https://developers.google.com/search/docs/fundamentals/seo-starter-guide "Search Engine Optimization — Shapes page content so that search engines rank it higher") descriptions only for products whose content changed.
2. **Context-aware search and personalised recommendations.** Hybrid vector and keyword search over the tenant's catalog, shaped by the shopper's session. Recommendations are drawn from co-purchase data and session similarity.
3. **Dynamic pricing and trend agents.** LangGraph agents react to market signals (competitor prices, sales velocity, stock cover) and propose prices. Deterministic guardrails bound every proposal. Small changes apply automatically; larger ones wait for merchant approval.
4. **Conversational agents with secure inventory tools.** A shopper assistant answers product questions and finds items. A merchant copilot can also look up and change stock. Both call typed tools, and the caller's own permissions limit what a tool can do.
5. **Multi-channel order sync and merchant console.** Channel order webhooks feed a unified order stream. The console shows analytics dashboards (a category-sales treemap and a behaviour-flow heatmap) and runs multi-step seller onboarding.

### Nice to have

- Price experiments (A/B price tests) with automatic stop rules.
- Multilingual SEO descriptions per channel locale.
- Image-based attribute extraction from product photos.
- Natural-language analytics questions in the merchant copilot ("why did footwear revenue drop last week?").
- Outbound webhooks so merchants can react to price decisions in their own systems.

## Non-Functional Requirements

| Property | Target | Notes |
|---|---|---|
| Availability | 99.9% monthly for catalog lookup, search, recommendations and the console; 99.5% for chat | Chat depends on an external model provider, so it gets a lower target. Pricing agents are best-effort and **fail static**: if they are down, prices stay as they are |
| Latency: catalog lookup | p95 < 50 ms at the service, at a peak of 4,500+ requests per second | The API tier over [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"). Mechanism in `03-data-modeling.md` and `05-reliability.md` |
| Latency: search retrieval | average ~110 ms, p95 < 200 ms | Down from a 450 ms baseline. The latency budget is in `04-deep-dive.md` |
| Latency: recommendations | p95 < 150 ms | Candidates come from [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") and indexed tables |
| Latency: chat | first token p95 < 1.5 s; complete turn p95 < 6 s | Streamed to the widget |
| Latency: dashboards | p95 < 800 ms | Served from pre-aggregated rollup tables |
| Freshness | Price decision applied ≤ 5 min after a qualifying signal; catalog change searchable ≤ 2 min | Eventual consistency, bounded and measured |
| Throughput: bulk import | 1M-row feed staged, merged and enriched in ≤ 2 h | Glue scales out; Bedrock quota is the limit |
| Scalability | Stateless services scale horizontally on [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS"); storage scales vertically first, with triggers written down | See the evolution triggers in `03` and `04` |

**Consistency ([CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning).** The system is not one CAP choice; each domain picks its own:

- **Inventory, orders and price decisions are [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability").** They live on one PostgreSQL primary with a synchronous Multi-[AZ](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/ "Availability Zone — Isolated group of data centres within an AWS Region, used to survive a single-site failure") standby. An agent's stock update must never apply twice or go missing. During a partition these writes fail rather than diverge.
- **Catalog reads, search and recommendations are [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency").** They are served from Redis, read replicas and `search-db`, which lag the source by seconds. A shopper who sees a price a few seconds old is acceptable. A search that fails is not.
- **Analytics is eventually consistent within minutes.** Rollups are built from [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") events.

## Scale Estimation

**Tenants and users**

| Quantity | Estimate | Basis |
|---|---|---|
| Tenants | 800 | Mid-market and enterprise merchants |
| Merchant users / [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day") | 6,000 / 2,500 | ~8 seats per tenant; ~40% daily active |
| Shopper sessions (DAU) | 1.5M | Across all storefronts that embed the widget |
| Chat conversations | 30k/day, 5 turns each | ~2% of shopper sessions open chat |
| Catalog size | 4M products, 12M variants (SKUs) | ~15k SKUs per tenant, ~3 variants per product |
| Changed products per day | 200k | Supplier feeds re-send whole catalogs; ~5% of products really change |
| Orders | 400k/day, ~5 lifecycle events each | ~500 orders per tenant per day |

**Queries per second**

| Flow | Average | Peak (×10, holiday or flash sale) |
|---|---|---|
| Storefront requests (search, recommendations, lookups) | 1.5M × 20 / 86,400 ≈ 350 | ~3,500 |
| Internal lookups (agents, `channel-connector` sync, indexer) | ~100 | ~1,000 |
| **Catalog / inventory API tier over PostgreSQL** | **~450** | **~4,500** |
| Search retrievals | ~60 | ~600 |
| Interaction events into Kafka | ~350 | ~3,500 |
| Chat turns | ~2 | ~20 |
| Order events | ~25 | ~250 |

`core-db` is sized to serve the whole 4,500 requests-per-second peak **with Redis cold**. Redis is there to cut latency, not to supply capacity, so losing it does not overload the database (see `04-deep-dive.md`).

**[LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") volume (daily).** 200k attribute extractions and ~130k SEO generations (Bedrock) after caching; ~600k chunk embeddings; ~300k chat model calls (Bedrock); ~40k pricing and trend agent runs, about 3 [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") calls each. At this volume the provider quota, not the compute, is the limit that matters. `04-deep-dive.md` covers the rate control.

**Storage over 5 years**

| Store | Size | Calculation |
|---|---|---|
| `core-db` catalog | ~75 GB | 4M × 6 KB products + 12M × 0.5 KB variants ≈ 30 GB, growing ×2.5 |
| `core-db` orders (hot, 24 months) | ~290 GB | 400k/day × 1 KB × 730 days; older partitions archived to S3 |
| `core-db` stock adjustments and market signals | ~120 GB hot | Adjustments kept 13 months; signals kept 30 days |
| `search-db` | ~150 GB | 12M chunks × ~3.5 KB (vector, text, `tsvector`) + [HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") index ≈ 60 GB, growing ×2.5 |
| S3 feeds and archive | ~40 TB, mostly Glacier | 20 GB/day of raw feeds, moved to Glacier after 90 days; order archive |
| [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes") | ~60 GB, steady | Conversation state (30-day [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires")) plus LLM response cache |
| Kafka ([MSK](https://aws.amazon.com/msk/ "Amazon Managed Streaming for Apache Kafka — Runs Apache Kafka clusters as a managed AWS service")) | ~500 GB provisioned | 3-day retention on interactions, 14 days on orders, replication factor 3 |

## Scope Boundaries

- **Out of scope:** checkout and payments (the channels own them), warehouse management, shipping labels, and supplier procurement.
- **Assumptions:** one AWS Region with three Availability Zones; tenants accept that a catalog change takes up to a few minutes to reach search and channels; each channel's API allows reading its own competitor price data.
- **Team:** 8–12 engineers. This constraint limits how much new infrastructure the design can take on. Every addition outside the stated stack is flagged in `02-high-level-design.md`.
