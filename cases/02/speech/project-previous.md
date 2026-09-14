# Retail Software Marketplace — Vendor / Retailer Sourcing Platform

**Table of Contents**

- [Retail Software Marketplace — Vendor / Retailer Sourcing Platform](#retail-software-marketplace--vendor--retailer-sourcing-platform)
  - [The Spine — Ten Lines to Memorise](#the-spine--ten-lines-to-memorise)
  - [What the Product Is (~60 s)](#what-the-product-is-60-s)
  - [My Role, in One Line](#my-role-in-one-line)
  - [The Shape of the System (~90 s)](#the-shape-of-the-system-90-s)
    - [The six services](#the-six-services)
  - [The Data Layer (~115 s)](#the-data-layer-115-s)
    - [Two honest cuts on the same path](#two-honest-cuts-on-the-same-path)
  - [Authentication and Authorization (~90 s)](#authentication-and-authorization-90-s)
  - [How Services Talk, and How They Stay Consistent (~155 s)](#how-services-talk-and-how-they-stay-consistent-155-s)
  - [Optional — The Vendor Workspace and Bulk Imports (~40 s)](#optional--the-vendor-workspace-and-bulk-imports-40-s)
  - [Optional — How It Ships (~40 s)](#optional--how-it-ships-40-s)
  - [Optional — Logs, Metrics and Traces (~40 s)](#optional--logs-metrics-and-traces-40-s)
  - [If Asked — Two Problems That Cost Us (~80 s)](#if-asked--two-problems-that-cost-us-80-s)
    - [Problem one — the publish that looked lost](#problem-one--the-publish-that-looked-lost)
    - [Problem two — the cache that made the spike worse](#problem-two--the-cache-that-made-the-spike-worse)
  - [Close (~20 s)](#close-20-s)

---

## The Spine — Ten Lines to Memorise

1. Three-sided marketplace. Competing vendors and competing retail chains on one platform.
2. Small traffic, hard isolation. Thirty-five requests a second at peak — nothing here is a throughput problem.
3. Six services, one repository, one pipeline. Split for blast radius and tenant data, not for load.
4. Postgres is the spine. Mongo is the body. A projection table is the seam between them.
5. One denormalised table, partial indexes, keyset pagination — the hot query joins nothing. → **107 ms**
6. Cache-aside, revision-keyed, expendable. Single-flight and early expiry, never a bare [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"). → **85% hit**
7. Three checks: account type, role, tenant scope. Tenant scope lives in one layer, not per endpoint.
8. I rejected row-level security deliberately — a pooled connection is where it silently stops working.
9. Outbox, not dual write. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for work we own, Service Bus across a boundary.
10. Two war stories: the publish that looked lost, and the cache that made the spike worse.

## What the Product Is (~60 s)

Quick shape first — what the product does, then how it's built. I'll point out my own work as I pass through it.

It's a [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") marketplace for retail operations software. Software vendors publish their products — point-of-sale, inventory, loyalty, payment and reconciliation tools. Category managers at retail chains compare features, pricing and country coverage, shortlist what fits, and open a conversation with the vendor directly.

**The problem product resolves:** Before this, a chain with a gap in checkout or stock software ran a full sourcing round — an [RFP](https://en.wikipedia.org/wiki/Request_for_proposal "Request For Proposal — Formal solicitation inviting vendors to bid on a project"), a spreadsheet of vendors, weeks of email — to reach a conversation it could have had on day one. The platform replaces the round, not the negotiation.

> **"It's three-sided: vendors, retail chains, and us in the middle. Which means competitors are on the same platform."**

A vendor must never see a competitor's drafts, or which chains are shopping. A retail chain must never see another chain's shortlist — that's their sourcing strategy. And a vendor learns a chain even exists only when that chain opens a conversation first.

That imbalance is what most of the design is answering.

**One number for scale:** Around three thousand active users a day, thirty-five requests a second at peak, forty thousand listings at the five-year mark.

> **"Nothing in this system is hard because of load. It's hard because of who must not see what — and because product metadata has no fixed shape."**

## My Role, in One Line

I sat on the backend team for the marketplace platform, and my area was the catalog data layer and search, the vendor and retailer APIs, the identity and authorization model, the async and import paths, and the Azure infrastructure and the pipeline that ships it.

## The Shape of the System (~90 s)

Six [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services, clean architecture, each owning its own tables and exposing them to nobody. If a service needs data it doesn't own, it calls an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") or consumes an event.

<details>
<summary><strong>If asked: "six services, so six databases?"</strong></summary>

No — one Postgres instance, and I'd rather be straight about what that means. The boundary is real in code: a service owns its tables and nothing else reads them, and if you need data you don't own you go through an API or an event. But it is not enforced at the database — same instance, and the read path runs on a shared role. So what the process boundary actually bought is blast radius, not data isolation. Per-service roles and grants were the next step and we hadn't taken it.

> **"The honest version is: the rule is enforced in the process, documented in the schema, and not yet enforced by the database."**

</details>

### The six services

- **catalog-service** — the read side. Search, facets, detail, compare. Highest traffic, purely read.
- **vendor-service** — the write side. Listing authoring, publish, bulk imports.
- **retailer-service** — the buyer's private working set: groups, stores, shortlists.
- **connection-service** — requests, threads, messages. The platform's commercial event.
- **billing-service** — vendor plans and charges.
- **identity-service** — the [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") authorization server. A different trust boundary from everything else.

Plus three Celery worker pools: imports, indexing, notifications. Same codebase, different deployment — so a twenty-thousand-row import can't eat web-tier capacity.

The requirement I was given was that a listing change must never spill into a connection or a billing flow. That's the reason for the split, and I want to state the trade-off plainly, because a modular monolith is genuinely defensible at thirty-five requests a second — and cheaper.

> **"A module boundary documents that rule. A process boundary enforces it. We paid for enforcement."**

What makes it affordable is that it isn't nine repositories. One repository, one [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") migration history, one pipeline, one cluster. Splitting the repos at this scale would have cost more in coordination than the boundaries are worth.

<details>
<summary><strong>If asked: "would you build it as a monolith today?"</strong></summary>

For a smaller team, yes — one deployable, the same six modules, the same schema-per-module boundary. I'd extract on a real trigger: a component with its own release cadence, its own hardware, or its own owner. Here the trigger was blast radius on data two competitors share.

> **"Carve a system up by domain nouns and you get the coupling of a monolith with the failure modes of a network."**

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed a marketplace backend with clean architecture, splitting catalog, vendor, and retailer modules so listing changes did not spill into connection and billing flows</summary>

**The layering.** Three rings. The innermost holds domain entities and the rules that are true regardless of technology — a listing cannot be published while its vendor is still `pending`, a connection request bills at most once. The middle ring holds use cases that orchestrate those rules and speak only to abstract repository interfaces. The outer ring holds everything that would change if we swapped a technology: the FastAPI routers, the [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") repositories, the Mongo document mapper, the Celery task definitions.

**What actually enforces it.** Python has no visibility modifiers — `from app.infrastructure.db import session` inside a domain module compiles and runs perfectly. So the rule is mechanical: an import-linter contract in the pipeline declares the layer graph and fails the build on a back-edge. Without that check, "clean architecture" degrades into a folder naming convention, which is what most codebases claiming it actually have.

**Where the module boundary becomes a process boundary.** Six services, each owning its own tables and exposing them to nobody; a peer that needs data it doesn't own calls an API or consumes an event. `billing-service` is separate specifically because the brief named billing as a flow listing changes must not reach — separation is the mechanism, not a preference.

**The one place I broke the abstraction deliberately.** The catalog search query uses SQLAlchemy Core with hand-written predicates rather than the [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries"), because the generated plan is the thing being engineered. Hiding it behind a generic repository method would mean nobody could see what the database was being asked to do. Abstraction is worth it where the implementation is genuinely interchangeable and it's a liability where the implementation *is* the design.

**The honest limit.** One Postgres instance, and the read path runs on a shared role. The boundary is enforced in the process and documented in the schema, not enforced by the database. Per-service roles and grants were the next step and we hadn't taken it.

</details></li>

<li><details>
<summary>Built FastAPI REST APIs for catalog browse and vendor–retailer connection so a chain could go from a listing to an open conversation without a separate sourcing tool</summary>

**The browse surface.** `GET /v1/catalog/products` takes `q`, `category`, `country`, `deployment_model`, `price_max`, `integrations[]`, `sort`, `cursor` and `limit` capped at 50, and returns `PagedProducts { items, next_cursor, total_estimate }`. Then `GET /v1/catalog/products/{id}` for detail — spine from Postgres, metadata document from Mongo, media URLs signed against blob storage — `GET /v1/catalog/categories/{slug}/facets` for the counts, and `POST /v1/catalog/compare` for two to five products, which returns the union of their categories' facet schemas with null cells where a vendor didn't supply an attribute.

**The connection surface.** `POST /v1/connections` takes `{ product_id, message, store_scope? }` plus a required `Idempotency-Key` header. That header is the whole point — a double-submitted form from a category manager must not create two threads and must not bill the vendor twice — and it's backed by a unique constraint in the database, not by the cache.

**Contract mechanics.** Versioned at `/v1`. [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models define every request and response body and generate the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document, so the contract is a build artefact rather than documentation, and the functional stage in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") tests against it. Unknown fields are rejected rather than absorbed. Keyset pagination everywhere — offset degrades badly on exactly the deep result pages a comparison workflow produces.

**Why async handlers.** The workload is dominated by waiting on Postgres, Mongo and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") rather than by CPU, so a small connection pool per pod is sufficient and the sum of all pod pool maxima stays under the Flexible Server connection limit.

**The asymmetry is in the surface itself.** No vendor-side endpoint returns retail group, store or retailer user data at all. A vendor learns a retail group exists only through a connection request that group initiated. That's an API design decision, not a filter applied later.

**The trade-off I'd state.** The admin console calls these same versioned public APIs rather than a private backend. It costs a chattier UI on entity screens that join across services; it buys that no admin capability exists which the public contract doesn't already describe and test.

</details></li>
</ul>

</details>

## The Data Layer (~115 s)

This is the part I designed most of, and it starts from a contradiction in the requirements. Product metadata has to have no fixed column set — a [POS](https://en.wikipedia.org/wiki/Point_of_sale "Point of Sale — The system and moment at which a retail transaction is completed") system and a loyalty engine describe themselves with completely different attributes — but retailers still have to filter and compare on those attributes.

The resolution is that a listing has two halves with different governance:

- **The spine** is relational, in Postgres — identity, vendor, category, status, publication date, price tiers. It has referential integrity, it takes part in shortlists and connections, and it's what the admin workspace edits.
- **The body** is a document in [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") — everything specific to being a POS or an inventory system. Validated at write time against a per-category facet schema, and stored as immutable revisions.

> **"Schemaless doesn't mean uncontracted. Adding a category is a document insert, not a migration."**

Then the seam: an indexer worker projects the filterable subset of the Mongo document into a single Postgres table, with the free-text vector and the facets alongside it.

> **"Postgres owns what has to be correct. Mongo owns the shape we can't pin down. The projection table is a read model — we can rebuild it from both."**

Four things about that table, because it's where the performance lives:

- It's denormalised by design. Vendor, status and publication date are copied onto it, so the hot search query touches exactly one relation and never joins.
- Partial indexes carry the status predicate — the browse index is defined WHERE status = published, which keeps drafts and archived rows out of the index entirely and removes the filter from every plan.
- Keyset pagination, never offset. Page forty of a comparison costs the same as page one — with offset, the database counts past every row it skips before it can return anything.
- No index goes in without a query behind it. If there's no access pattern that needs it, it's write amplification on every insert, and it doesn't get created.

> **"That's how a faceted search lands around a hundred milliseconds uncached, and thirty-five from cache."**

<details>
<summary><strong>If asked: "how do you know it's a hundred milliseconds?"</strong></summary>

Because that number is a query plan, not a guess — and the plan is the part that can be wrong. The risk is specific: Postgres has to combine those [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") indexes into a bitmap AND, and its selectivity estimates for array containment and jsonb are poor, so on an unselective combination it can degrade toward a sequential scan as the table grows. So it's EXPLAIN ANALYZE against a seeded forty-thousand-row table on the pinned minor version, not an eyeball in staging. And if the plan comes out wrong, the fix is a composite covering index per high-traffic category — not a bigger instance.

</details>

### Two honest cuts on the same path

And one honest constraint I put in the API rather than in the database: a query with more than two facet predicates has to name a category. That guarantees a viable leading index instead of a bitmap scan over the whole table — and it matches how sourcing actually works. Nobody compares a POS against a loyalty engine.

One more cut on the same path: the API returns an estimated result count, not an exact one, and stops counting at a thousand. An exact count over a filtered GIN scan costs about as much as the page you're returning. So the UI says "1,000+" rather than "1,247" — which is what a sourcing workflow needs anyway.

Redis sits in front of all of it, cache-aside, and it holds nothing durable — hot listings, search pages, facet counts, rate limits, idempotency keys.

> **"Losing Redis costs us latency, never correctness. It goes from thirty-five milliseconds to a hundred, and Postgres takes about six times the load. Capacity is sized to survive exactly that."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed MongoDB schemas for product metadata so vendors could publish POS, inventory, and loyalty tools without a fixed column set</summary>

**Four collections, one database.** `product_metadata` holds the live document — `category_slug`, `revision`, `schema_version`, free-form `attributes`, plus `modules`, `integrations`, `compliance` and `media`. `product_metadata_revisions` holds an immutable snapshot per publish. `facet_schemas` holds, per category, which attribute keys are typed, which are facetable, their value domains and their display order. `import_staging` holds one document per parsed import row.

**The join is free.** `product_metadata._id` *is* the Postgres `product.id`. No mapping table, no lookup collection. The only pointer in the other direction is `product_category.facet_schema_ref`, which names a `facet_schemas` document — the single cross-store reference in the whole schema.

**What makes schemaless governable.** Pydantic validates a vendor's submitted `attributes` against the category's `facet_schemas` document at write time, in `vendor-service`. So "no fixed column set" never degrades into "no contract". Adding a category is a document insert plus a facet-projection mapping — not a migration, not a release.

**Indexes.** `{category_slug: 1}` and `{updated_at: -1}` on the live documents; `{product_id: 1, revision: -1}` on revisions, which is the only access pattern revisions have; `{category_slug: 1, version: -1}` on the schemas; and a TTL index on `import_staging.created_at` at 30 days, so staging expires without anybody running a job.

**What never goes in Mongo.** Media and datasheets. `media[].blob_key` references blob storage; the 16 MB document limit is not a boundary this design should ever approach.

**Deployment shape.** A three-member replica set — primary for writes and revisions, secondaries readable for the detail-page hydration path, where a few hundred milliseconds of staleness is irrelevant. ~15 GB at the five-year mark, so no sharding, ever, on this horizon.

**The honest limit.** Facet schema evolution is unresolved. When a category's `facet_schemas` document changes shape, existing documents stay on the old `schema_version` and the projection has to handle both. Lazy migrate-on-read, a backfill job, or a hard version cutover per category — which one you pick determines how expensive category changes are for the rest of the platform's life, and it deserves a prototype before the first category ships rather than a decision under pressure afterwards.

</details></li>

<li><details>
<summary>Built PostgreSQL schemas for vendors, retailers, and product listings used by search, shortlists, and the admin workspace</summary>

**Conventions across every table.** `uuid` primary key defaulting to `gen_random_uuid()`, `created_at timestamptz` defaulting to `now()`, `updated_at` where the row is mutable. Money is integer minor units with an explicit [ISO-4217](https://www.six-group.com/en/products-services/financial-information/data-standards.html "ISO 4217 — Standardizes three-letter currency codes for unambiguous monetary values") `currency char(3)` — never floating point, anywhere.

**Four groups of tables.** Organisations and people: `vendor`, `vendor_user`, `retail_group`, `store`, `retailer_user`, `platform_user`. `auth_subject` is the [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") `sub`, and no password material is stored on these tables at all. The catalog spine: `product_category`, `product` with `UNIQUE (vendor_id, slug)` and a `current_revision_id` pointing into Mongo, `product_price_tier`, and the projection. The buyer's working set: `shortlist` and `shortlist_item`. The commercial side: `connection_request`, `connection_thread`, `connection_message`, `billing_account`, `billing_charge`.

**Rules I pushed into the schema rather than into code.** `UNIQUE (retail_group_id, idempotency_key)` on `connection_request` — the database, not the cache, is what finally prevents a duplicate thread. `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge` — a connection bills at most once, enforced by a constraint rather than by retry logic. `PRIMARY KEY (shortlist_id, product_id)` on shortlist items. `UNIQUE (retail_group_id, external_ref)` on stores. At-least-once delivery should land on a constraint, not on a code path that hopes it never fires twice.

**Why pricing is split across both stores.** `product_price_tier` is structured and relational — tier name, `price_minor`, currency, unit, store-count band — because the comparison view sorts and ranges over it. Free-form pricing prose stays in the Mongo document, where it can't be queried and doesn't need to be.

**Denormalisation, each instance deliberate.** `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product` so the search query never joins. `connection_request.vendor_id` is copied from `product` so a vendor's open-connections query is served entirely by `idx_conn_vendor` with no join.

**Partitioning where growth is unbounded.** `connection_message` and `audit_event` are declaratively range-partitioned by month. Retention is then a partition detach — one metadata operation — rather than a long-running `DELETE` competing with live traffic. `audit_event` is additionally append-only: the application role holds `INSERT` and `SELECT` and no `UPDATE` or `DELETE` grant.

**Platform mechanics that also live here.** `oauth_client`, `refresh_token` with its rotation chain, `catalog_import_job` — job state is relational so the vendor workspace can query progress, while row-level detail stays in Mongo staging — and `outbox_event`, which carries exactly one index: `BTREE (occurred_at) WHERE published_at IS NULL`, the relay's only query.

**The honest limit.** Neither store is sharded and both should stay that way for the full five-year horizon — roughly 110 GB and about two writes a second. The trigger to reconsider is ~2,000 sustained write [TPS](https://en.wikipedia.org/wiki/Transaction_processing "Transactions Per Second — Throughput measure of how many transactions a system completes each second") or a ~1 TB working set, and the far likelier first move is pushing `audit_event` out to blob-backed cold storage, which removes ~25 GB and most of the growth.

</details></li>

<li><details>
<summary>Optimized SQL queries and indexes for catalog search and listing filters used when chains compare coverage and pricing</summary>

**The first optimization is the table.** All of it happens on `product_listing_facets`, the projection — written only by the indexer, read only by the catalog service. Vendor, status and publication date are copied onto it, so the hot query touches exactly one relation and never joins.

**Five indexes, five named access patterns.**

- `idx_plf_browse` — `BTREE (category_slug, published_at DESC, product_id) WHERE status = 'published'`. Composite *and* partial, each for a separate reason. Composite because the default browse is "this category, newest first, paged", and the trailing `product_id` is what turns keyset pagination into a single index read. Partial because roughly 40,000 of 55,000 rows are published — drafts and archived rows never enter the index at all, and the status predicate disappears from every plan that uses it.
- `idx_plf_price` — `BTREE (category_slug, price_from_minor) WHERE status = 'published' AND price_from_minor IS NOT NULL`. The price-sorted variant of the same browse, partial on the same grounds plus the null exclusion.
- `idx_plf_search` — `GIN (search_vector)`, over a `tsvector` built from name, summary and vendor name. GIN rather than [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") because the column is read far more often than it is written and GIN's lookups are the faster half of that trade.
- `idx_plf_arrays` — `GIN` on `country_coverage` and on `integrations`. Array containment is the actual predicate: "sells in DE", "integrates with SAP".
- `idx_plf_facets` — `GIN (facets jsonb_path_ops)`. `jsonb_path_ops` rather than the default operator class, because containment is the only operator the facet filter ever uses — it gives a smaller index and faster containment in exchange for key-existence operators I don't need.

**Composite, partial, full-text and TTL are each doing distinct work here** — composite for ordered browse, partial to keep unpublished rows out of the hot indexes entirely, GIN and `tsvector` for text and containment, and a Mongo TTL index for staging that must expire without a job. That's not four names for one idea.

**The query side, which matters as much as the indexes.**

- Keyset pagination, never offset: `(published_at, product_id) < cursor`. Page 40 of a comparison costs what page 1 costs; with offset the database counts past every row it skips before it can return anything.
- `total_estimate` rather than `total`, derived from the planner and capped at 1,000. An exact count over a filtered GIN scan costs about as much as the page you're returning.
- A query carrying more than two facet predicates has to name a category. That's a product constraint buying a performance guarantee — it makes `idx_plf_browse` or `idx_plf_price` always a viable leading index instead of a bitmap OR over the whole table — and it matches how sourcing works, since nobody compares a POS against a loyalty engine.
- SQLAlchemy Core with hand-written predicates on this path rather than the ORM, so the plan stays visible to whoever reads the code.
- `search_vector` is maintained by the indexer worker, not by a database trigger. A trigger would run inside the vendor's publish transaction, coupling write latency to text-search maintenance for a value only the projection needs.
- Projection upserts are batched 200 rows to a statement during imports.
- No index goes in without a named access pattern behind it. Otherwise it's write amplification on every upsert, paid forever.

**The honest limit.** The 45 ms figure is `EXPLAIN (ANALYZE, BUFFERS)` against a seeded 40,000-row table on the pinned [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") 15 minor version, not an eyeball in staging — and the plan is the part that can be wrong. Postgres's selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor, so on an unselective combination the bitmap AND I'm relying on can degrade toward a sequential scan as the table grows. If it does, the fix is a composite covering index per high-traffic category, not a bigger instance.

**The one I'd flag as unprototyped.** `to_tsvector` with a single dictionary handles a monolingual catalog well and handles "Kassensystem" versus "POS" not at all. A multilingual European marketplace needs a language-per-listing configuration and probably trigram similarity for vendor-name fuzziness — and that, rather than volume, is the most likely trigger for a dedicated search engine.

</details></li>

<li><details>
<summary>Cached hot catalog reads in Redis to cut database load on popular POS and inventory listings</summary>

**Cache-aside, not write-through, and deliberately.** Write-through would put cache population inside the vendor's publish transaction, coupling a write path to a cache the design treats as expendable. Cache-aside keeps Redis strictly optional: if it's gone, everything still works, more slowly.

**Keyspaces, each with its own invalidation rule.**

- `cat:listing:{product_id}:v{rev}` — the fully hydrated detail: spine, metadata document, signed media URLs. 15-minute TTL, and the indexer deletes the key on a publish or update event. The `v{rev}` suffix is the important part: a stale key is *unreachable* even if the purge message is lost, because the reader composes the key from the revision pointer in Postgres. Invalidation correctness doesn't depend on a message arriving.
- `cat:search:{filter_hash}` — the ordered product-id list for one filter-and-cursor combination. 60-second TTL and nothing else. Enumerating every filter combination a single listing change affects is intractable, so freshness is bought with a short TTL rather than with a purge.
- `cat:facets:{category_slug}` — facet value counts, 5 minutes, purged by the indexer on any projection write in that category.
- `authz:jwks` — the identity provider's signing keys, 10 minutes, refreshed on an unknown `kid`. This is the reason authorization costs 1 ms in the latency budget rather than an introspection round trip.
- `rl:*` and `idem:*` — rate-limit counters and idempotency keys, expiry only.
- In-process, not Redis: the category tree and the facet schemas, both tiny and near-static, 60-second TTL. A stale category label for a minute is harmless.

**How a read actually uses it.** Search returns ids from `cat:search`, then one `MGET` across the listing keys, then a single bulk `$in` into Mongo for whatever missed — never one lookup per item. That shape is what keeps the uncached path at ~107 ms rather than thirty round trips.

**The hit ratio is an [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health"), not a statistic.** Above 0.85 on `cat:search`, because the latency budget assumes it. If it drops, the p95 moves before anything else tells you.

**Degradation is specified, not hoped for.** Losing Redis is not an outage — every read falls through. Latency goes from ~35 ms to ~107 ms and Postgres load multiplies about six times, and capacity is sized to survive exactly that. Rate limiting and idempotency degrade with it, and they do so asymmetrically on purpose: both fail *closed* for writes and *open* for reads.

**The honest limit.** A bare TTL on the hot listing key is what turned this cache into a synchronised stampede under concentrated traffic. The two mechanisms that fixed it — single-flight and probabilistic early expiry — are under "Two Problems That Cost Us", because the story is worth more than the mechanism.

</details></li>
</ul>

</details>

## Authentication and Authorization (~90 s)

This is the section that matters most, because every serious threat here is an authenticated one. The dangerous actor isn't an intruder — it's a legitimate vendor enumerating the buyer side to build a sales list.

Identity first. One service is the OAuth2 authorization server; nothing else authenticates anybody. Authorization code with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") for the web app and the admin console, client credentials for vendor systems pushing catalog data. Access tokens are [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs"), fifteen minutes, signing key in Key Vault with a rotation overlap. Refresh tokens rotate — a one-time-use identifier, and presenting a revoked one revokes the whole chain and raises an alert.

Verification happens twice, deliberately. The gateway validates signature, expiry and audience at the edge, so a forged token never reaches the cluster. Each service validates again locally against a cached key set and then applies its own rules.

> **"The edge is a filter, never the authority. And neither check makes a network call — an introspection round-trip per request would have eaten a fifth of the latency budget."**

Then authorization, which is three checks in order:

- **Account type**, from a claim on the token. Vendor routes require a vendor token, retailer routes a retailer token, admin routes a platform token. A retailer token cannot reach a vendor route whatever its scopes.
- **Role to scope.** A vendor viewer gets read only; a category manager gets connection-write but not group administration, so they can't add stores or change who's in the group.
- **Tenant scope** — which organisation's rows you can reach.

That third one is the one that matters, and I enforced it in exactly one place: a session-level filter in the repository layer, not a check in each endpoint.

> **"A per-endpoint check is a control that works right up until the day someone adds an endpoint."**

Platform admins bypass it explicitly, and every bypass writes an audit row.

And one decision I want to state plainly, because it's the opposite of what I'd normally reach for. Postgres row-level security is the stronger mechanism, and I chose not to use it as the primary control here. The read path runs on a replica through a pooled connection with a shared role, and setting a per-request session variable through a transaction-mode pooler is exactly where row-level security silently becomes a no-op — or worse, leaks into the next caller's query.

> **"A security control that quietly stops working is worse than one you never had. If I can't guarantee it under real connection handling, it doesn't get to be the primary control."**

The compensating control is that the filter lives in one auditable layer, with a test asserting that a cross-tenant read returns empty for every repository method that touches an org-owned table.

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Implemented OAuth2 and JWT authentication for vendors and retailers so catalog and connection APIs stayed behind the right account type</summary>

**Two grants, for two genuinely different clients.** Authorization code with PKCE for the marketplace web app and the admin console — both public clients holding no secret, with the refresh token in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie scoped to the API origin. Client credentials for vendor system integrations pushing catalog data — confidential clients, with the secret stored as an Argon2id hash on `oauth_client`.

**Token shape.** RS256, fifteen-minute lifetime. Claims are `sub`, `act` for account type — vendor, retailer or platform — `org_id`, `roles[]`, `scopes[]`, `jti` and `exp`. The signing key lives in Key Vault on a 90-day rotation, with both keys published at the [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") endpoint through the overlap window. Refresh tokens live 30 days and rotate: one-time-use `jti`, and presenting a revoked one revokes the entire chain and raises an alert.

**Verification happens twice, and that's the design.** The gateway validates signature, expiry and audience at the edge, so a forged or expired token never reaches the cluster. Each service then validates again locally against the JWKS cached in Redis and applies its own scope and tenant rules. The edge is a filter, never the authority. And neither check makes a network call per request — an introspection round trip would add 15 to 30 ms to every hop in both the cached and uncached columns of the latency budget.

**Then three authorization checks, in order.**

- *Account type*, from the `act` claim, enforced by a FastAPI dependency on every router. `/v1/vendor/*` requires a vendor token, `/v1/retailer/*` a retailer token, `/v1/admin/*` a platform token. A retailer token cannot reach a vendor route whatever its scopes — and that coarse check is the one the brief actually named.
- *Role to scope*, resolved at token issue rather than at request time. A vendor `viewer` receives `vendor:read` only. A `category_manager` receives `retailer:read` and `connection:write` but not `retailer:admin`, so they can shortlist and open conversations but cannot add stores or change who is in the group.
- *Tenant scope*, which is the one that matters — every query touching an org-owned table filtered on `org_id` from the token, enforced in exactly one place: a SQLAlchemy session-level filter applied by the repository layer. Not a check in each endpoint, because a per-endpoint check is a control that works right up until the day someone adds an endpoint. Platform admins bypass it explicitly, and every bypass writes an audit row.

**What revocation actually costs.** Because nothing calls the identity service per request, revocation is bounded by the fifteen-minute access-token lifetime. The refresh chain is revoked immediately, and for the one case where fifteen minutes isn't good enough — a suspended vendor — the identity service publishes a deactivation event and services consult a small Redis denylist of revoked `jti` values.

**The honest limit, and it's the decision I'd lead with.** Postgres row-level security is the stronger mechanism and I chose not to use it as the primary control. The read path runs on a replica through a pooled connection with a shared role, and setting a per-request session variable through a transaction-mode pooler is exactly where [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") silently becomes a no-op — or worse, leaks into the next caller's query. A security control that quietly stops working is worse than one you never had. The compensating control is that the filter lives in one auditable layer, with a test asserting a cross-tenant read returns empty for every repository method that touches an org-owned table.

**The second limit, which is operational.** The gateway caches the JWKS on its own schedule, independent of the `authz:jwks` key in Redis. During a signing-key rotation the two caches can disagree, and tokens signed with the new key may be rejected at the edge while the cluster accepts them. The key-overlap window has to be strictly longer than the gateway's [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") configuration refresh interval, and that interval has to be confirmed on the target tier before the first rotation — not discovered during one.

</details></li>
</ul>

</details>

## How Services Talk, and How They Stay Consistent (~155 s)

The rule is one sentence: synchronous when the caller can't act without the answer, asynchronous when the caller only needs the work to happen.

In practice there are four transports and each has a stated job:

- **Synchronous [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs")** on anything with a user attached to it.
- **Azure Service Bus topics** for domain facts that cross a boundary — listing published, connection requested, user deactivated.
- **Celery** for the jobs we're on the hook for and have to retry — imports, indexing, notification policy.
- **Azure Functions** for delivery and media processing, triggered off a queue and off blob writes.

> **"Celery moves work between Python processes we own. Service Bus moves events across a boundary. That split is a rule, not a preference."**

One event is worth pausing on, because it's the only place a commercial event writes into the buyer's private working set. When a category manager opens a connection, that event sets the product's shortlist row to "contacted" — the requirement to track who is already in talks. It's asynchronous and idempotent, so somebody may briefly still see "candidate". That's acceptable, because the authoritative signal in the UI is the connection list itself, not the badge on the shortlist.

> **"Everything else about the buyer's working set is invisible to the vendor side. This is the one write that goes into it — and nothing goes back out."**

I'll flag one thing on the sync side: exactly one synchronous call crosses a service boundary in the whole design — connection-service asking retailer-service whether that group already has an open thread. It has a 250-millisecond timeout, and on timeout it fails open and permits the connection.

> **"Refusing a real connection request costs the marketplace more than an occasional duplicate thread — and the duplicate is caught by a unique constraint anyway."**

Keeping two stores and a projection in agreement is where most of my design time went — they cannot be one transaction. Three rules:

- **First** — nothing is dual-written. A publish writes the revision document to Mongo, then commits the Postgres pointer alongside an outbox row in one transaction, and the relay ships it from there. Mongo first is deliberate: an orphaned document nothing points at is invisible garbage we can sweep, whereas a committed pointer to a document that doesn't exist is a broken listing. We pay for that in freshness: a listing is searchable in about five seconds, thirty at p99. Dual-writing gets you the case where the commit lands and the publish doesn't, and from then on the two stores disagree forever with nothing raising a hand. With an outbox the failure is just an unpublished row — visible on a dashboard, and it clears itself once the consumer is back.
- **Second** — the schema does the deduplication, not a retry handler. The projection upserts on product id and ignores any event whose revision is older than the row's current one, so redelivery is a no-op and out-of-order delivery can't roll a listing backwards. A connection request carries an idempotency key with a unique constraint on it, so a double-clicked form can't create two threads or bill the vendor twice.

  > **"At-least-once delivery should land on a constraint, not on a code path that hopes it never fires twice."**

- **Third** — there's a reconciliation job, because an event can still be lost. Nightly, it re-projects any listing whose projection timestamp trails its update timestamp by more than five minutes, and sweeps orphaned revisions. And the lag itself is a metric with an alert on it, because a dead indexer is a silent failure — nothing else surfaces it. New listings simply stop appearing, and no error is raised anywhere.

**On the security side of all that:** [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") everywhere, private endpoints on every data store — none of them has a public IP — default-deny network policy inside the cluster with explicit allows per pair, default-deny egress, and workload identity so there are no connection strings and no static credentials anywhere in the cluster or in CI.

I did not implement mutual TLS between services, and that's a stated choice rather than an oversight: doing it properly means a service mesh, and a mesh's cost is disproportionate for nine workloads in one namespace where no untrusted container runs. The trigger to revisit it is concrete — a third-party workload in the cluster, or a compliance requirement that names it.

<details>
<summary><strong>If asked about GDPR</strong></summary>

The personal data here is occupational — names, work email addresses, and the messages staff write to each other. No consumer data, no special-category data, no profiling. The one genuine conflict is erasure. When someone leaves a chain, we tombstone their identity — auth subject, email, name — revoke their refresh chains, and pseudonymise them in the audit trail. But we retain the message bodies they wrote, re-attributed to a deleted-user tombstone, under Article 17(3)(e): a vendor's record of a commercial negotiation isn't the individual's to delete.

And the cost of that, stated plainly: the erasure isn't total, and the retained text may still identify its author from context. So the position has to be in the privacy notice and defensible to a supervisory authority. The alternative — deleting the messages — destroys the counterparty's business record, and that's the worse failure.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Configured Celery for catalog imports and notification jobs so new listings and connection requests did not block the API</summary>

*The import mechanics are under "The Vendor Workspace and Bulk Imports"; this is the transport rule and the durability question.*

**The rule that decides which system carries a piece of work.** Celery moves work between Python processes we own. Service Bus moves events across a boundary — to Functions, to another service, to any future consumer. That split is a rule, not a preference, and the alternative in either direction puts one system in a role it's bad at: Celery reaching out to a Function, or Service Bus scheduling in-process Python work.

**Three queues, three separate worker deployments.** `imports`, `indexing`, `notifications`. Same application codebase, different deployment — which is the whole point, because a twenty-thousand-row import running in the web tier eats the capacity that browse needs. Separate queues mean imports cannot starve indexing either.

**Queue depth does three jobs at once.** It's the autoscaling signal — an [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") on `celery_queue_depth` through a custom metric adapter, so a large import scales the importers and never touches the web tier. It's an SLI, with thresholds of 500 on `imports` and 100 on the others. And it's an alert input. Task failures are their own metric per task name, alerting on any sustained rate — that's the brief's "job failures", made concrete.

**One owner per step in the notification path.** The notification worker decides *whether and what* to notify, which is a policy decision needing database context and therefore belongs in Python. The Function performs *delivery* to the email provider. No overlap, and neither half re-implements the other.

**Workers are drained, not killed.** A `preStop` hook stops queue consumption and waits for the in-flight task, bounded by a 120-second termination grace period, and chunk sizes are chosen to finish well inside it. A rolling deploy therefore doesn't abandon work mid-task.

**The honest limit, and it's a real one.** Celery here runs on Redis, and Redis has no true acknowledgement semantics. `acks_late` plus a visibility timeout is what makes it tolerable, with [AOF](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ "Append Only File — Redis persistence mode that logs every write for durability") persistence at `everysec` underneath — but a worker killed mid-task relies on that visibility timeout expiring, and a broker failover can still drop an unacknowledged task. That needed a kill-the-worker test on the pinned Celery and Redis versions before I'd call imports durable. And if they had to be genuinely durable, the move was to run the `imports` queue on Service Bus, which was already in the stack, keeping Redis for `notifications` and `indexing` — whose work is fully rebuildable from the outbox and therefore doesn't need the guarantee.

</details></li>

<li><details>
<summary>Integrated Azure Functions, Blob Storage, and Service Bus for catalog updates and vendor–retailer notifications when a listing changed or a chain opened a thread</summary>

**Service Bus topology.** Two topics and one queue: catalog events, connection events, and a notification-dispatch queue. Topics because the pattern is fan-out with competing consumers, plus dead-lettering and a native Function trigger, with no cluster to run. [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") and Event Hubs were considered and rejected on volume — this system emits roughly 0.2 events a second.

**Every event carries the same envelope** — event id, type, occurrence time, aggregate id, an optional source revision id, and a payload — and every consumer is idempotent on the event id.

**The catalogue itself, with consumers named.** A listing published fans out to the indexer and the notification worker, so facets project, the cache invalidates and saved-search subscribers are alerted. Updated goes to the indexer alone. Archived goes to both, because retailers holding that product in a shortlist need warning. Import completed goes to notification, so the vendor sees the row-level outcome. A connection requested fans out three ways — notify the vendor, accrue the billing charge, and set the shortlist item to "contacted". A connection responded stamps the first-response timestamp, which is the input to the liquidity metric. A user deactivated goes to both the retailer and vendor services to revoke the refresh chain and tombstone the actor.

**Nothing is published directly.** Every one of those is written to the outbox table in the same Postgres transaction as the state change; the relay publishes afterwards and stamps `published_at`. Delivery is at-least-once and never zero-times, which is why consumers must be idempotent rather than merely careful.

**Two Functions, each with a reason to exist off the request path.** Media processing is blob-triggered — thumbnails and [PDF](https://en.wikipedia.org/wiki/PDF "Portable Document Format — Fixed-layout document format for reliable printing and viewing") previews, because thumbnailing a forty-page datasheet must never hold an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") connection open. It's also a security control: it re-encodes vendor-supplied images, which is what neutralises a malicious upload. Notification dispatch is queue-triggered and does delivery only.

**Blob layout is by prefix, with a lifecycle rule per prefix.** Listing media under the product and revision, moving to cool tier after 180 days. Derived thumbnails under that, regenerable and deleted with the revision. Import uploads under the vendor and job, deleted after 90 days. The admin console bundle under its build [SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity"), last five builds retained. [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") state in its own container, versioned and lease-locked. Because those paths are content-addressed, [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") invalidation is never needed — a new revision is simply a new [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web").

**One deliberate separation on the serving side.** Vendor-supplied files go out with `Content-Disposition: attachment` through a dedicated download hostname, so no vendor file is ever served from the origin that hosts the admin console.

**Least privilege is per workload, not per cluster.** Only the outbox relay may send on the two topics. Only the vendor service and the import worker may write the import and listing blob prefixes. The catalog service gets read on its own secrets and nothing on Service Bus at all.

**The honest limit.** If Service Bus is down, events simply queue at the outbox — `published_at` stays null, the relay resumes, and nothing is lost. What you get instead is projection and notification lag for the duration of the outage. Functions dead-letter after ten attempts with an alert on it: delayed email, no data loss. The residual risk I'd name is that a dead indexer is a *silent* failure — new listings just stop appearing and no error is raised anywhere — which is why the projection lag is a metric with a page on it rather than something you notice from a support ticket.

</details></li>
</ul>

</details>

## Optional — The Vendor Workspace and Bulk Imports (~40 s)

I built the admin workspace over vendors, chains, stores and products — the point being that every entity a support ticket would otherwise touch is editable by the right role without an engineering change. It's a static console calling the same versioned public API, not a private backend.

> **"The benefit is that no admin capability exists which the public contract doesn't already describe and test."**

Imports are the other half. A vendor uploading twenty thousand rows must not degrade browse for everyone else, so: the file is chunked into five-hundred-row tasks on their own queue and their own worker pool, with a per-vendor concurrency cap held as a Redis semaphore, so one vendor can't occupy the pool. Rows land in a staging collection and are validated against the category schema before any live row moves — a malformed file fails wholly, with a per-row error digest, never half-applied. And the projection is batched: a completed import re-projects in batches of two hundred, otherwise one import means twenty thousand cache invalidations.

<details>
<summary><strong>If asked: "what happens if an import worker dies mid-chunk?"</strong></summary>

Nothing is half-applied — that's what the staging collection is for. A dead chunk means the import doesn't complete, not that the catalog is left inconsistent. But I'll flag the limit honestly, because it's a real one: Celery is running on Redis, and Redis has no true acknowledgement semantics. Redelivery of an in-flight chunk depends on a visibility timeout expiring, and a broker failover can still drop an unacknowledged task. That needed a kill-the-worker test before I'd call imports durable — and if they had to be genuinely durable, the move was to run that one queue on Service Bus, which was already in the stack.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Built an admin panel for vendors, retail chains, stores, and software products so vendor teams could update listings and category managers could shortlist without engineering tickets</summary>

**What it is architecturally.** A static single-page bundle served from blob storage through the CDN, keyed by build SHA, calling the same versioned `/v1` APIs everything else calls. There is no private admin backend anywhere in this design.

**The surface.** Admin routes over vendors, retail groups, stores and products — each with list, detail, patch and a state-transition endpoint. They sit behind `act = platform` and the `platform:admin` scope, and they are the one part of the system with no org scoping applied.

**What that buys operationally.** Every entity a support ticket would otherwise touch is editable by the right role without an engineering change: vendor vetting state, which is what gates publication; retail group status; a chain's store footprint, which feeds coverage matching; and product status transitions. The failure mode it removes is the one where "change this vendor's status" is a database console and a Slack message.

**Bypass is explicit and audited.** Platform admins skip the tenant filter deliberately rather than by accident of scope, and every bypass writes an audit row — as does every admin action, into an append-only, monthly-partitioned table with no update or delete grant.

**The cost, stated.** A chattier UI on entity screens that join across services, since the console has to call several APIs where a private backend would have done one query. What it buys is that no admin capability exists which the public contract doesn't already describe and which the functional test stage doesn't already exercise.

**One routing rule that belongs here.** The vendor workspace reads the authoritative sources directly — the Postgres primary and the metadata document — never the projection and never the cache, so vendors get read-your-writes. The single place a vendor sees the projection is an explicit "preview as a retailer sees it" view, where the staleness is the point rather than a defect.

</details></li>

<li><details>
<summary>Configured Celery for catalog imports and notification jobs so new listings and connection requests did not block the API</summary>

*The transport rule and the Celery-on-Redis durability question are under "How Services Talk"; this is what an import actually does.*

**Chunking.** The uploaded file is parsed and split into 500-row tasks on the `imports` queue. A twenty-thousand-row file is forty tasks, not one long-running job whose failure costs everything.

**A per-vendor concurrency cap.** At most four concurrent chunks per vendor, held as a Redis semaphore. One vendor uploading their full catalogue cannot occupy the pool and delay everyone else's imports — which is a fairness property the queue alone doesn't give you.

**A separate worker deployment on a separate queue.** Import workers scale on `imports` queue depth and cannot starve indexing or notifications. This is the mechanism behind "an import must not degrade browse".

**Staged, then promoted.** Rows land in a Mongo staging collection and are validated against the category's facet schema *before any live product row moves*. A malformed file fails wholly at validation with a per-row error digest — never half-applied. The staging collection carries a 30-day TTL index, so it cleans itself up without a job.

**Batched projection.** A completed import emits one completion event, and the indexer re-projects the affected products in batches of 200. Without that, one import means twenty thousand upserts and twenty thousand cache invalidations, and the import becomes exactly the browse-degrading event it was designed not to be.

**Job state is queryable.** Status, row total, rows succeeded, rows failed and the error digest live in a relational table so the vendor workspace can show progress and the outcome; the per-row detail stays in Mongo staging where it belongs.

**Two limits around the edges.** Imports are rate-limited to five jobs per vendor per day, as a marketplace-integrity control rather than a capacity one. And failures above 5% of a job's rows raise a ticket, with the vendor seeing the same error digest the alert names.

</details></li>
</ul>

</details>

## Optional — How It Ships (~40 s)

GitLab CI is the only path to production, and none of the gates are decorative: ruff, type checking, unit tests, then integration tests against real containers — real Postgres, real Mongo, real Redis — then a functional pass against the OpenAPI contract, then image and dependency scanning.

> **"The projection pipeline and the query plans are exactly the things a mocked test passes while broken."**

Terraform owns every Azure resource, including the alert rules — an alert silenced by hand during an incident and never restored is the standard way monitoring rots. It applies only from CI, authenticated by [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") federation rather than a stored secret.

The step teams tend to skip is the migration discipline, so I'll name it: every migration here is expand-contract. One release adds nullable columns and builds indexes concurrently; dropping what nothing reads any more is a separate merge request, at least one release later.

> **"That's what makes rollback real. The old image has to be able to run against the new schema — otherwise 'roll back' is just a word."**

The read service gets a canary at ten percent held against its error rate and p95, because it carries the risky query plans. Everything else is a rolling update, and workers are drained rather than killed.

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Automated GitLab CI pipelines for test and deploy across marketplace services</summary>

**One repository, one pipeline, nine deployable images.** Stages in order: lint with ruff and mypy, unit tests, integration tests against real data stores brought up by Compose, a functional pass against the OpenAPI contract, image build with digest pinning, image [CVE](https://www.cve.org/ "Common Vulnerabilities and Exposures — Public identifier for a known software security flaw") and dependency scanning, the expand migration, staging deploy, smoke, then production as canary into rolling — with the contract migration landing later as a separate merge request.

**No gate is decorative.** Dependencies are pinned by hash, images by digest, base images rebuilt weekly. The scan stage blocks rather than reports.

**The step teams skip, which I'd name unprompted.** Every migration is expand-contract. One release adds nullable columns, new tables and indexes built `CONCURRENTLY`, so the previous image keeps running against the new schema throughout the rollout. Dropping a column nothing reads any more is a separate merge request at least one release later. That is what makes rollback real — the old image has to be able to run against the new schema, otherwise "roll back" is just a word. Rollback itself is a redeploy of the previous image digest, safe by construction because the schema is compatible in both directions during the window.

**CI authenticates to Azure by OIDC federation**, not a stored service principal secret, and Terraform applies only from the default branch.

**The honest limit.** The CI deploy identity is the single largest concentration of privilege in the design — it can apply Terraform across the whole subscription. Splitting it into a plan-only identity for merge requests and an apply identity gated on protected-branch pipelines, and separating the network and data-plane modules into their own state with their own identity, is worth designing before the first production apply rather than after an incident.

</details></li>

<li><details>
<summary>Provisioned Azure marketplace infrastructure with Terraform so AKS, storage, and functions stayed in versioned config</summary>

**What it owns — which is everything.** The cluster and its node pools, the Postgres Flexible Server and its read replica, both Redis instances, the Mongo deployment, blob containers and their lifecycle rules, the Service Bus namespace with its topics, subscriptions and dead-letter settings, both Function Apps, the API gateway, the CDN and [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") edge, Key Vault, and every monitoring alert rule.

**State handling.** State lives in its own blob container with versioning and lease locking, so two concurrent applies can't interleave.

**Environments are workspaces over one module set**, differing only in a variables file. Staging is therefore the same topology at smaller instance sizes — which is the thing that makes a staging smoke test meaningful rather than theatre.

**Alert rules are Terraform-managed and not editable in the portal.** An alert silenced by hand during an incident and never restored is the standard way monitoring rots, and this removes the mechanism rather than trusting the discipline.

**Role assignments are Terraform resources too**, which is the point I'd make about security here: a widened permission shows up as a reviewable diff rather than as something nobody notices. None of this section is enforced by code review alone.

</details></li>

<li><details>
<summary>Deployed services to Azure AKS with Docker and Kubernetes</summary>

**Shape.** One cluster, one namespace, nine workloads — six services and three worker pools. Compose reproduces the full data-store set for local development and for CI integration tests, so the containers a developer runs and the ones CI tests against are the same images at the same pinned versions.

**Autoscaling on two different signals.** HPA on CPU at a 65% target for the six services; HPA on Celery queue depth through a custom metric adapter for the three worker pools, so a large import scales the importers without touching the web tier. Cluster autoscaler between three and eight nodes.

**Rollout strategy differs by risk, deliberately.** The catalog service gets a canary — a second deployment receiving about 10% through ingress weighting, held for fifteen minutes against its error rate and p95 — because it takes the traffic and carries the risky query plans. Everything else is a rolling update with readiness and liveness probes. Workers are drained rather than killed, with a `preStop` hook and a 120-second grace period.

**Blue/green was considered and rejected**, and the reason is worth giving: it doubles the pod footprint and, because both colours share the same Postgres, delivers no database-level isolation — which is the only part of the risk that expand-contract migrations don't already cover.

**Network posture inside the cluster.** Default-deny NetworkPolicy with explicit allows per service pair, and default-deny egress that reaches only the payment provider, the email provider and Azure service endpoints. Workload identity federates each [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") service account to its own managed identity, so there are no connection strings and no static credentials anywhere in the cluster.

**The honest limit.** There is no mutual TLS between services, and that's a stated choice rather than an oversight. Doing it properly means a service mesh, and a mesh's cost — sidecar lifecycle, certificate rotation, a new failure mode in every request path — is disproportionate for nine workloads in one namespace where no untrusted container runs. The trigger to revisit it is concrete: a third-party or customer-supplied container in the cluster, a second tenant-facing workload, or a compliance requirement that names encryption in transit between internal services. Any of those, and a mesh goes in.

</details></li>

<li><details>
<summary>Wrote unit, integration, and functional tests with Pytest for catalog, auth, and connection paths</summary>

**Three levels with three different jobs.** Unit tests cover domain rules with no database at all — which is the payoff of the clean-architecture layering, not a separate discipline. Integration tests run against real Postgres, Mongo and Redis brought up by Compose at the pinned versions. Functional tests exercise the API against the generated OpenAPI contract.

**Why real data stores rather than mocks**, which is the choice I'd defend hardest: the projection pipeline and the GIN query plans are exactly the things a mocked test passes while broken. A mock of the indexer will happily confirm a projection that never happens.

**The security test I'd name specifically.** A cross-tenant read returns empty for every repository method that touches an org-owned table. That test *is* the compensating control for not using row-level security — without it, the argument for the repository-layer filter doesn't hold.

**The contract tests are load-bearing beyond testing.** They're what makes it safe for the admin console to share the public API: no admin capability exists that the contract doesn't describe and the functional stage doesn't exercise.

**Three things I'd single out as needing a test before being believed rather than assumed.** The query plan, via `EXPLAIN (ANALYZE, BUFFERS)` on a seeded 40,000-row table at the pinned Postgres minor version. Celery-on-Redis redelivery, via a kill-the-worker test, before calling imports durable. And an end-to-end trace id across a publish-to-notify flow, because the OpenTelemetry propagation through Service Bus and Celery has been partly manual in the past and is the claim most likely to be false as written.

</details></li>
</ul>

</details>

## Optional — Logs, Metrics and Traces (~40 s)

Azure Monitor and Application Insights, with one OpenTelemetry [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") emitting metrics, logs and traces — so all three carry the same resource attributes and one instrumentation dependency.

What makes it usable is that the trace id rides along in Service Bus message properties, not only in HTTP headers. So one trace covers the request, the outbox publish, the projection and the cache invalidation — precisely the chain nobody can debug from logs alone.

Every log line carries a request id, a trace id, and the organisation id — so a support question can be scoped to one tenant without a full-text sweep. Two standing rules: no conversation message body, token or secret is ever logged.

> **"And the audit trail doesn't live in the logs at all. It's a table, append-only, with no update or delete grant — because if it were a log stream, whoever tunes log retention would be setting your audit policy for you."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Monitored services with Azure Monitor, tracking API errors and job failures on catalog and connection flows</summary>

**One SDK for all three signals.** Metrics, logs and traces all emit through the same OpenTelemetry SDK into Azure Monitor and Application Insights — so there is one instrumentation dependency to keep pinned and one set of resource attributes shared across every signal. That's what makes it possible to move from a metric to the trace behind it without correlating by hand.

**The SLIs, each existing for a reason.** Catalog search latency p95 against a 200 ms target. Catalog read availability at 99.9% monthly, and write-path availability at 99.5% — deliberately different, because browse and publish are not the same promise. Indexer lag, event-occurrence to projection, p95 under 5 seconds and p99 under 30: that's the staleness the availability choice bought, and it's the number that tells you the projection died. Outbox unpublished age, which catches a stalled relay before any consumer notices. Celery queue depth per queue, which doubles as the autoscaling signal. Task failures per task name — the brief's "job failures". Cache hit ratio above 0.85 on the search keyspace, because the latency budget assumes it. Replica lag under 5 seconds, with the catalog service failing back to the primary above 30. And first-response time on connections, p50 — tracked but not targeted, because it's the metric that says whether the platform actually shortens sourcing.

**What pages versus what raises a ticket.** Pages: catalog read error-budget burn at 14.4× over an hour, connection-create 5xx above 1% over five minutes, indexer lag p95 above 60 seconds for ten minutes, outbox age above 300 seconds. Tickets: any dead-letter on any subscription, an import job failing more than 5% of its rows, replica lag above 30 seconds for ten minutes, and a certificate or Key Vault secret thirty days from expiry. Each rule names an owner and a runbook, and all of them are Terraform resources rather than portal edits.

**Logging rules.** [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") to stdout. Every line carries request id, trace id, service, actor side, org id, route and status — org id always present, so a support question can be scoped to one tenant without a full-text sweep. Two standing prohibitions: no connection message body, no token, no client secret, ever.

**Tracing, and the part that makes it useful.** Auto-instrumentation for FastAPI, SQLAlchemy, the Mongo driver, Redis and Celery. Trace context propagates through Service Bus *message properties*, not only HTTP headers — so one trace spans publish, projection, cache invalidation and notification, which is precisely the chain nobody can reconstruct from logs alone. Sampling is 100% of errors and of write-path requests, 5% of catalog reads.

**The audit trail is not the logs, and that's a boundary I'd insist on.** Audit events are a table — append-only, insert and select grants only, monthly partitions archived to immutable storage — written asynchronously off the outbox rather than synchronously in the request path, because a synchronous audit write on read would make replica-served catalog reads impossible. If the audit trail were a log stream, whoever tunes log retention would be setting audit policy.

**The honest limit.** Trace continuity across Service Bus and Celery is the claim here most likely to be false as written: it depends on the instrumentation versions actually injecting and extracting the trace header, and both have been partly manual. The versions are pinned and an integration test asserts an end-to-end trace id across a publish-to-notify flow — because the moment you discover it doesn't work is during an incident, which is the worst possible time.

</details></li>
</ul>

</details>

## If Asked — Two Problems That Cost Us (~80 s)

### Problem one — the publish that looked lost

Eventual consistency was invisible to retailers and glaring to vendors. A vendor clicked publish, the API returned two-oh-one, and their own listing page showed the old content for the next few seconds. So they clicked publish again. And again. We got support tickets saying the platform had lost their changes — and a burst of duplicate work behind every one of them.

The lag was within budget. The mistake was mine, and it was a routing mistake, not a latency one: the vendor workspace was reading the same cached projection the retailer-facing catalog reads.

The fix was to route by audience rather than by endpoint. The vendor workspace now reads the authoritative sources directly — the Postgres primary and the metadata document — never the projection and never the cache. Vendors get read-your-writes; retailers get the fast, slightly stale, cached view. The one place a vendor sees the projection is an explicit "preview as a retailer sees it", where the staleness is the point.

> **"What I took from it: eventual consistency isn't a property of a system. It's a property of a reader. Decide per audience who's allowed to see stale data, and route the query accordingly."**

### Problem two — the cache that made the spike worse

We cached hot listings on a plain fifteen-minute TTL, which is the obvious thing to do and is fine almost all of the time. Then a vendor's product got featured in a trade newsletter.

Under concentrated traffic the failure is precise: the key expires, every concurrent request misses in the same instant, and all of them hit Postgres and Mongo together. The cache didn't absorb the spike — it synchronised it. And it did that at exactly the moment the traffic was highest, which is the only moment it mattered.

Two mechanisms fixed it, both small. Single-flight per key: on a miss the first pod takes a short lock and recomputes, and the others poll briefly and then serve the stale value. And probabilistic early expiry, so readers recompute a little before the TTL with a rising probability — recomputation spreads over a window instead of landing on one instant. Together they bound database load on any one listing to roughly one recomputation per TTL, no matter how many concurrent readers there are.

> **"And much the same shape again: a cache changes when the load arrives, not just how much. A bare TTL is a scheduled thundering herd — you just haven't been popular enough to see it yet."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Cached hot catalog reads in Redis to cut database load on popular POS and inventory listings</summary>

*The keyspaces, TTLs and invalidation rules are under "The Data Layer"; this is the stampede fix, in mechanism.*

**Single-flight, concretely.** On a miss the pod attempts `SET cat:lock:{key} NX EX 5`. The winner recomputes. The losers poll the key for up to 200 milliseconds and then serve the stale value if one exists. The five-second lock expiry is what stops a pod dying mid-recomputation from wedging the key.

**Probabilistic early expiry, concretely.** Each cached value carries its own computation cost and a tuning delta, and a reader recomputes early with a probability that rises as the TTL approaches. The effect is that recomputation spreads across a window instead of landing on one instant — which is the actual disease. The expiry wasn't too short; it was too *synchronised*.

**What the two together bound.** Roughly one recomputation per TTL per key, regardless of how many concurrent readers there are. That's the property worth stating, because it's independent of traffic — it doesn't degrade as the listing gets more popular, which a bigger cache or a longer TTL would.

**What it costs.** Up to ~200 ms of extra latency on a losing request, a possible 200 ms of staleness on the value it serves, and a small amount of code that only pays off under exactly the traffic pattern the brief describes. Cheap, but not free, and not worth adding speculatively to every cache in a system.

**Which key this is really about.** The hot listing detail key at a fifteen-minute TTL. The search-page key at sixty seconds is a different shape — its TTL is short precisely because enumerating the filter combinations one listing change affects is intractable, so it was never the stampede risk the detail key was.

**Why the blast radius stayed survivable while we had it wrong.** Cache-aside means Redis is expendable by design: losing it entirely takes latency from ~35 ms to ~107 ms and multiplies Postgres load about six times, and capacity is sized for exactly that. The stampede was *worse* than losing the cache — it delivered that same multiplied load concentrated onto a single instant rather than spread across the minute.

</details></li>
</ul>

</details>

## Close (~20 s)

So, in one line: six services split for isolation rather than for throughput, a relational spine with a schemaless body joined by a projection I can rebuild, tenant scoping enforced in one auditable layer, and every write that crosses a boundary going through an outbox instead of a dual write.

The catalog data layer and search, the vendor and retailer APIs, the identity and authorization model, the async and import paths, and the infrastructure and pipeline underneath — that was my share of it.

Happy to take any of that apart in more detail.
