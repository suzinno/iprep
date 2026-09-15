# Retail Software Marketplace — Vendor / Retailer Sourcing Platform

**Table of Contents**

- [Retail Software Marketplace — Vendor / Retailer Sourcing Platform](#retail-software-marketplace--vendor--retailer-sourcing-platform)
  - [The Spine — Ten Lines to Memorise](#the-spine--ten-lines-to-memorise)
  - [What the Product Is (~65 s)](#what-the-product-is-65-s)
  - [My Role, in One Line](#my-role-in-one-line)
  - [The Shape of the System (~105 s)](#the-shape-of-the-system-105-s)
    - [The six services](#the-six-services)
  - [The Data Layer (~120 s)](#the-data-layer-120-s)
    - [Two honest cuts on the same path](#two-honest-cuts-on-the-same-path)
  - [Authentication and Authorization (~105 s)](#authentication-and-authorization-105-s)
  - [How Services Talk, and How They Stay Consistent (~165 s)](#how-services-talk-and-how-they-stay-consistent-165-s)
  - [Optional — The Vendor Workspace and Bulk Imports (~45 s)](#optional--the-vendor-workspace-and-bulk-imports-45-s)
  - [Optional — How It Ships (~45 s)](#optional--how-it-ships-45-s)
  - [Optional — Logs, Metrics and Traces (~45 s)](#optional--logs-metrics-and-traces-45-s)
  - [If Asked — Two Problems That Cost Us (~85 s)](#if-asked--two-problems-that-cost-us-85-s)
    - [Problem one — the publish that looked lost](#problem-one--the-publish-that-looked-lost)
    - [Problem two — the cache that made the spike worse](#problem-two--the-cache-that-made-the-spike-worse)
  - [Close (~20 s)](#close-20-s)

---

## The Spine — Ten Lines to Memorise

1. It's a three-sided marketplace. Competing vendors and competing retail chains are on one platform.
2. The traffic is small, but the isolation is strict. The peak is thirty-five requests a second, so nothing here is a throughput problem.
3. There are six services, one repository and one pipeline. We split for blast radius and tenant data, not for load.
4. Postgres is the spine. Mongo is the body. A projection table connects them.
5. One denormalised table, partial indexes and keyset pagination. The hot query joins nothing. → **107 ms**
6. The cache is cache-aside, keyed by revision, and expendable. It uses single-flight and early expiry, never a bare [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"). → **85% hit**
7. There are three checks: account type, role and tenant scope. Tenant scope lives in one layer, not in each endpoint.
8. I rejected row-level security on purpose. Through a pooled connection, it works only if every read sets the tenant inside its own transaction.
9. We use an outbox, not a dual write. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") is for work we own. Service Bus is for work that crosses a boundary.
10. Two problems that cost us: the publish that looked lost, and the cache that made the spike worse.

## What the Product Is (~65 s)

First, a quick shape: what the product does, and then how it's built. I'll point out my own work as I go through it.

It's a [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") marketplace for retail operations software. Software vendors publish their products. These are point-of-sale, inventory, loyalty, payment and reconciliation tools. Category managers at retail chains compare features, pricing and country coverage. They shortlist what fits. Then they open a conversation with the vendor directly.

**The problem the product solves:** Before this, a chain with a gap in its checkout or stock software ran a full sourcing round. That meant an [RFP](https://en.wikipedia.org/wiki/Request_for_proposal "Request For Proposal — Formal solicitation inviting vendors to bid on a project"), a spreadsheet of vendors and weeks of email. All of that was just to reach a conversation the chain could have had on day one. The platform replaces the sourcing round. It does not replace the negotiation.

> **"It's three-sided: vendors, retail chains, and us in the middle. So competitors are on the same platform."**

A vendor must never see a competitor's drafts. A vendor must also never see which chains are shopping. A retail chain must never see another chain's shortlist, because that shortlist is the chain's sourcing strategy. And a vendor learns that a chain exists only when that chain opens a conversation first.

That imbalance explains most of the design.

**One number for scale:** There are around three thousand active users a day. The peak is thirty-five requests a second. By year five, there will be forty thousand listings.

> **"Nothing in this system is hard because of load. It's hard because of who must not see what. It's also hard because product metadata has no fixed shape."**

## My Role, in One Line

I was on the backend team for the marketplace platform. My area covered five things. First, the catalog data layer and search. Second, the vendor and retailer APIs. Third, the identity and authorization model. Fourth, the async and import paths. And fifth, the Azure infrastructure and the pipeline that ships it.

## The Shape of the System (~105 s)

There are six [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services with clean architecture. Each service owns its own tables and exposes them to nobody. If a service needs data it doesn't own, it calls an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") or consumes an event.

<details>
<summary><strong>If asked: "six services, so six databases?"</strong></summary>

No. There is one Postgres instance, and I want to be clear about what that means. The boundary is real in the code. A service owns its tables, and nothing else reads them. If you need data you don't own, you go through an API or an event. But the database does not enforce that boundary. It's the same instance, and the read path runs on a shared role. So the process boundary gave us blast radius, not data isolation. The next step was per-service roles and grants, and we hadn't taken that step.

> **"The honest version is this: the process enforces the rule, the schema documents it, and the database does not enforce it yet."**

</details>

### The six services

- **catalog-service** is the read side. It handles search, facets, detail and compare. It has the highest traffic, and it only reads.
- **vendor-service** is the write side. It handles listing authoring, publish and bulk imports.
- **retailer-service** holds the buyer's private working set: groups, stores and shortlists.
- **connection-service** holds requests, threads and messages. A connection is the platform's commercial event.
- **billing-service** holds vendor plans and charges.
- **identity-service** is the [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") authorization server. It is a different trust boundary from everything else.

There are also three Celery worker pools: imports, indexing and notifications. They use the same codebase but a different deployment. So a twenty-thousand-row import can't use up the web tier's capacity.

The requirement I was given was this: a listing change must never spill into a connection flow or a billing flow. That requirement is the reason for the split. I want to state the trade-off plainly. A modular monolith is a fair choice at thirty-five requests a second, and it's cheaper.

> **"A module boundary documents that rule. A process boundary enforces it. We paid for enforcement."**

What makes the split affordable is that it isn't nine repositories. There is one repository, one [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") migration history, one pipeline and one cluster. At this scale, splitting the repositories would have cost more in coordination than the boundaries are worth.

<details>
<summary><strong>If asked: "would you build it as a monolith today?"</strong></summary>

For a smaller team, yes. I would build one deployable with the same six modules and the same schema-per-module boundary. I would move a component out only when there is a real trigger. The trigger is a component with its own release cadence, its own hardware or its own owner. Here, the trigger was blast radius on data that two competitors share.

> **"If you split a system by domain nouns, you get the coupling of a monolith and the failure modes of a network."**

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed a marketplace backend with clean architecture, splitting catalog, vendor, and retailer modules so listing changes did not spill into connection and billing flows</summary>

**The layering.** There are three rings.

- The innermost ring holds domain entities and the rules that are true whatever the technology. For example, a listing cannot be published while its vendor is still `pending`. And a connection request bills at most once.
- The middle ring holds use cases. They orchestrate those rules, and they speak only to abstract repository interfaces.
- The outer ring holds everything that would change if we swapped a technology. That means the FastAPI routers, the [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") repositories, the Mongo document mapper and the Celery task definitions.

**What actually enforces the layering.** Python has no visibility modifiers. So `from app.infrastructure.db import session` inside a domain module compiles and runs without any problem. That is why the rule is mechanical. An import-linter contract in the pipeline declares the layer graph. It fails the build on a back-edge. Without that check, "clean architecture" becomes just a folder naming convention. Most codebases that claim clean architecture actually have only that.

**Where the module boundary becomes a process boundary.** There are six services. Each one owns its own tables and exposes them to nobody. If a service needs data it doesn't own, it calls an API or consumes an event. `billing-service` is separate for one specific reason. The brief named billing as a flow that listing changes must not reach. So the separation is the mechanism, not a preference.

**The one place I broke the abstraction on purpose.** The catalog search query uses SQLAlchemy Core with hand-written predicates, not the [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries"). This is because the generated plan is the thing we are engineering. If I hid the query behind a generic repository method, nobody could see what the database was being asked to do. An abstraction is worth it where the implementation is really interchangeable. But it's a liability where the implementation *is* the design.

**The honest limit.** There is one Postgres instance, and the read path runs on a shared role. The process enforces the boundary, and the schema documents it. The database does not enforce it. The next step was per-service roles and grants, and we hadn't taken that step.

</details></li>

<li><details>
<summary>Built FastAPI REST APIs for catalog browse and vendor–retailer connection so a chain could go from a listing to an open conversation without a separate sourcing tool</summary>

**The browse surface.**

- `GET /v1/catalog/products` takes `q`, `category`, `country`, `deployment_model`, `price_max`, `integrations[]`, `sort`, `cursor` and `limit`. The limit is capped at 50. The endpoint returns `PagedProducts { items, next_cursor, total_estimate }`.
- `GET /v1/catalog/products/{id}` returns the detail. The spine comes from Postgres, and the metadata document comes from Mongo. The media URLs are signed against blob storage.
- `GET /v1/catalog/categories/{slug}/facets` returns the counts.
- `POST /v1/catalog/compare` takes two to five products. It returns the union of their categories' facet schemas. A cell is null where a vendor didn't supply an attribute.

**The connection surface.** `POST /v1/connections` takes `{ product_id, message, store_scope? }`. It also needs an `Idempotency-Key` header. That header is the whole point. A category manager may submit a form twice. That must not create two threads, and it must not bill the vendor twice. The header is backed by a unique constraint in the database, not by the cache.

**Contract mechanics.** The API is versioned at `/v1`. [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models define every request and response body. They also generate the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document. So the contract is a build artefact, not documentation. The functional stage in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") tests against it. The API rejects unknown fields instead of accepting them. We use keyset pagination everywhere. Offset pagination gets much slower on deep result pages, and a comparison workflow produces exactly those pages.

**Why the handlers are async.** Most of the work is waiting on Postgres, Mongo and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), not CPU work. So a small connection pool per pod is enough. And the sum of all the pod pool maximums stays under the Flexible Server connection limit.

**The asymmetry is in the surface itself.** No vendor-side endpoint returns retail group, store or retailer user data at all. A vendor learns that a retail group exists only through a connection request that the group started. That's an API design decision, not a filter we apply later.

**The trade-off I'd state.** The admin console calls these same versioned public APIs, not a private backend. The cost is a chattier UI on entity screens that join data across services. The benefit is that no admin capability exists that the public contract doesn't already describe and test.

</details></li>
</ul>

</details>

## The Data Layer (~120 s)

I designed most of this part. It starts from a contradiction in the requirements. Product metadata must have no fixed column set, because a [POS](https://en.wikipedia.org/wiki/Point_of_sale "Point of Sale — The system and moment at which a retail transaction is completed") system and a loyalty engine describe themselves with completely different attributes. But retailers still have to filter and compare on those attributes.

The answer is that a listing has two halves, and each half has different rules:

- **The spine** is relational, in Postgres. It holds identity, vendor, category, status, publication date and price tiers. It has referential integrity. Shortlists and connections use it. And the admin workspace edits it.
- **The body** is a document in [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents"). It holds everything specific to being a POS or an inventory system. We validate it at write time against a facet schema for each category. And we store it as immutable revisions.

> **"Schemaless doesn't mean there is no contract. Adding a category is a document insert, not a migration."**

Then there is the projection. An indexer worker copies the filterable part of the Mongo document into a single Postgres table. That table also holds the free-text vector and the facets.

> **"Postgres owns what has to be correct. Mongo owns the shape we can't fix in advance. The projection table is a read model, and we can rebuild it from both."**

I want to say four things about that table, because that's where the performance comes from:

- It's denormalised on purpose. Vendor, status and publication date are copied onto it. So the hot search query touches exactly one table and never joins.
- Partial indexes carry the status condition. The browse index is defined WHERE status = published. So drafts and archived rows never enter the index, and the filter disappears from every plan.
- We use keyset pagination, never offset. Page forty of a comparison costs the same as page one. With offset, the database counts past every row it skips before it can return anything.
- No index goes in without a query behind it. An index with no access pattern is write amplification on every insert. So we don't create it.

> **"That's how a faceted search lands around a hundred milliseconds uncached, and thirty-five milliseconds from cache."**

<details>
<summary><strong>If asked: "how do you know it's a hundred milliseconds?"</strong></summary>

That number comes from a query plan, not a guess. And the plan is the part that can be wrong. The risk is specific. Postgres has to combine those [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search") indexes into a bitmap AND. Its selectivity estimates for array containment and jsonb are poor. So on an unselective combination, the plan can slowly move toward a sequential scan as the table grows. That's why we run EXPLAIN ANALYZE against a seeded table of forty thousand rows, on the pinned minor version. We don't just look at staging. And if the plan comes out wrong, the fix is a composite covering index for each high-traffic category. The fix is not a bigger instance.

</details>

### Two honest cuts on the same path

Here is one honest constraint that I put in the API, not in the database. A query with more than two facet conditions has to name a category. That guarantees a usable leading index instead of a bitmap scan over the whole table. It also matches how sourcing actually works. Nobody compares a POS against a loyalty engine.

Here is one more cut on the same path. The API returns an estimated result count, not an exact one. It stops counting at a thousand. An exact count over a filtered GIN scan costs about as much as the page you're returning. So the UI says "1,000+", not "1,247". A sourcing workflow only needs that anyway.

Redis sits in front of all of it, as a cache-aside cache. It holds nothing durable. It holds hot listings, search pages, facet counts, rate limits and idempotency keys.

> **"If we lose Redis, latency gets worse, but correctness never does. Latency goes from thirty-five milliseconds to a hundred, and Postgres takes about six times the load. Capacity is sized to survive exactly that."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Designed MongoDB schemas for product metadata so vendors could publish POS, inventory, and loyalty tools without a fixed column set</summary>

**Four collections in one database.**

- `product_metadata` holds the live document. It has `category_slug`, `revision`, `schema_version` and free-form `attributes`. It also has `modules`, `integrations`, `compliance` and `media`.
- `product_metadata_revisions` holds an immutable snapshot for each publish.
- `facet_schemas` holds the rules for each category. It says which attribute keys are typed and which are facetable. It also holds their value domains and their display order.
- `import_staging` holds one document for each parsed import row.

**The join costs nothing.** `product_metadata._id` *is* the Postgres `product.id`. There is no mapping table and no lookup collection. Only one pointer goes the other way. `product_category.facet_schema_ref` names a `facet_schemas` document. It is the only cross-store reference in the whole schema.

**What keeps schemaless data under control.** In `vendor-service`, Pydantic validates a vendor's submitted `attributes` against the category's `facet_schemas` document at write time. So "no fixed column set" never becomes "no contract". Adding a category is a document insert plus a facet-projection mapping. It is not a migration, and it is not a release.

**Indexes.**

- `{category_slug: 1}` and `{updated_at: -1}` on the live documents.
- `{product_id: 1, revision: -1}` on revisions. This is the only access pattern that revisions have.
- `{category_slug: 1, version: -1}` on the schemas.
- A TTL index on `import_staging.created_at` at 30 days. So staging data expires without anybody running a job.

**What never goes in Mongo.** Media and datasheets. `media[].blob_key` references blob storage. This design should never come close to the 16 MB document limit.

**Deployment shape.** It is a replica set with three members. The primary takes writes and revisions. The secondaries are readable for loading the detail page. On that path, a few hundred milliseconds of staleness doesn't matter. The data is about 15 GB by year five. So there is no sharding at all in that time frame.

**The honest limit.** We haven't solved facet schema evolution. When a category's `facet_schemas` document changes shape, existing documents stay on the old `schema_version`. Then the projection has to handle both versions. There are three options: migrate lazily on read, run a backfill job, or do a hard version cutover for each category. The choice decides how expensive category changes are for the rest of the platform's life. So it deserves a prototype before the first category ships. It should not be a decision made under pressure later.

</details></li>

<li><details>
<summary>Built PostgreSQL schemas for vendors, retailers, and product listings used by search, shortlists, and the admin workspace</summary>

**Conventions on every table.** The primary key is a `uuid` with the default `gen_random_uuid()`. `created_at timestamptz` defaults to `now()`. A table has `updated_at` where the row can change. Money is stored as integer minor units with an explicit [ISO-4217](https://www.six-group.com/en/products-services/financial-information/data-standards.html "ISO 4217 — Standardizes three-letter currency codes for unambiguous monetary values") `currency char(3)`. Money is never floating point, anywhere.

**Four groups of tables.**

- Organisations and people: `vendor`, `vendor_user`, `retail_group`, `store`, `retailer_user` and `platform_user`. `auth_subject` is the [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") `sub`. These tables store no password material at all.
- The catalog spine: `product_category`, and `product` with `UNIQUE (vendor_id, slug)` and a `current_revision_id` that points into Mongo. Also `product_price_tier`, and the projection.
- The buyer's working set: `shortlist` and `shortlist_item`.
- The commercial side: `connection_request`, `connection_thread`, `connection_message`, `billing_account` and `billing_charge`.

**Rules I put in the schema, not in code.**

- `UNIQUE (retail_group_id, idempotency_key)` on `connection_request`. The database, not the cache, is what finally prevents a duplicate thread.
- `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge`. A connection bills at most once. A constraint enforces that, not retry logic.
- `PRIMARY KEY (shortlist_id, product_id)` on shortlist items.
- `UNIQUE (retail_group_id, external_ref)` on stores.

At-least-once delivery should land on a constraint. It should not depend on a code path that hopes it never runs twice.

**Why pricing is split across both stores.** `product_price_tier` is structured and relational. It holds the tier name, `price_minor`, currency, unit and store-count band. The reason is that the comparison view sorts and filters by range over it. Free-form pricing text stays in the Mongo document. Nobody can query it there, and nobody needs to.

**Each denormalisation is on purpose.** `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product`, so the search query never joins. `connection_request.vendor_id` is copied from `product`. So `idx_conn_vendor` alone serves a vendor's open-connections query, with no join.

**Partitioning where growth has no limit.** `connection_message` and `audit_event` are range-partitioned by month, using declarative partitioning. So retention is a partition detach, which is one metadata operation. It is not a long-running `DELETE` that competes with live traffic. `audit_event` is also append-only. The application role has `INSERT` and `SELECT`, and it has no `UPDATE` or `DELETE` grant.

**Platform mechanics that also live here.**

- `oauth_client`.
- `refresh_token`, with its rotation chain.
- `catalog_import_job`. Job state is relational, so the vendor workspace can query progress. The row-level detail stays in Mongo staging.
- `outbox_event`. It has exactly one index: `BTREE (occurred_at) WHERE published_at IS NULL`. That is the relay's only query.

**The honest limit.** Neither store is sharded. Both should stay that way for the full five years. By then there is roughly 110 GB and about two writes a second. The trigger to think again is about 2,000 sustained write [TPS](https://en.wikipedia.org/wiki/Transaction_processing "Transactions Per Second — Throughput measure of how many transactions a system completes each second") or a working set of about 1 TB. And the much more likely first step is moving `audit_event` out to cold storage in blob storage. That removes about 25 GB and most of the growth.

</details></li>

<li><details>
<summary>Optimized SQL queries and indexes for catalog search and listing filters used when chains compare coverage and pricing</summary>

**The first optimization is the table.** All of this work happens on `product_listing_facets`, the projection. Only the indexer writes to it, and only the catalog service reads it. Vendor, status and publication date are copied onto it. So the hot query touches exactly one table and never joins.

**Five indexes for five named access patterns.**

- `idx_plf_browse` is `BTREE (category_slug, published_at DESC, product_id) WHERE status = 'published'`. It is composite *and* partial, and each has its own reason. It is composite because the default browse is "this category, newest first, paged". The trailing `product_id` turns keyset pagination into a single index read. It is partial because roughly 40,000 of 55,000 rows are published. Drafts and archived rows never enter the index. And the status condition disappears from every plan that uses the index.
- `idx_plf_price` is `BTREE (category_slug, price_from_minor) WHERE status = 'published' AND price_from_minor IS NOT NULL`. It is the price-sorted version of the same browse. It is partial for the same reason, and it also excludes nulls.
- `idx_plf_search` is `GIN (search_vector)`. It covers a `tsvector` built from the name, the summary and the vendor name. I chose GIN, not [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints"), because we read the column far more often than we write it. GIN has the faster lookups, and lookups are the side that matters here.
- `idx_plf_arrays` is a `GIN` index on `country_coverage` and on `integrations`. Array containment is the actual condition, for example "sells in DE" or "integrates with SAP".
- `idx_plf_facets` is `GIN (facets jsonb_path_ops)`. I chose `jsonb_path_ops`, not the default operator class, because the facet filter only ever uses containment. It gives a smaller index and faster containment. In exchange, we lose key-existence operators, and I don't need them.

**Composite, partial, full-text and TTL indexes each do different work here.** Composite is for ordered browse. Partial keeps unpublished rows out of the hot indexes. GIN and `tsvector` are for text and containment. And a Mongo TTL index expires staging data without a job. These are not four names for one idea.

**The query side matters as much as the indexes.**

- Keyset pagination, never offset: `(published_at, product_id) < cursor`. Page 40 of a comparison costs what page 1 costs. With offset, the database counts past every row it skips before it can return anything.
- `total_estimate`, not `total`. The planner gives the estimate, and it is capped at 1,000. An exact count over a filtered GIN scan costs about as much as the page you're returning.
- A query with more than two facet conditions has to name a category. That product constraint buys a performance guarantee. `idx_plf_browse` or `idx_plf_price` is then always a usable leading index, instead of a bitmap OR over the whole table. It also matches how sourcing works, because nobody compares a POS against a loyalty engine.
- This path uses SQLAlchemy Core with hand-written predicates, not the ORM. So the plan stays visible to whoever reads the code.
- The indexer worker maintains `search_vector`, not a database trigger. A trigger would run inside the vendor's publish transaction. That would tie write latency to text-search maintenance, and only the projection needs that value.
- During imports, projection upserts are batched at 200 rows per statement.
- No index goes in without a named access pattern behind it. Otherwise it's write amplification on every upsert, and we pay for it forever.

**The honest limit.** The 45 ms figure comes from `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table of 40,000 rows, on the pinned [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") 15 minor version. We didn't just look at staging. And the plan is the part that can be wrong. Postgres's selectivity estimates for `text[]` containment and `jsonb_path_ops` are poor. So on an unselective combination, the bitmap AND I rely on can slowly move toward a sequential scan as the table grows. If that happens, the fix is a composite covering index for each high-traffic category. The fix is not a bigger instance.

**The one I'd flag as not prototyped.** `to_tsvector` with a single dictionary handles a catalog in one language well. It does not handle "Kassensystem" versus "POS" at all. A multilingual European marketplace needs a language setting for each listing. It probably also needs trigram similarity for vendor names that are spelled differently. That need, not volume, is the most likely trigger for a dedicated search engine.

</details></li>

<li><details>
<summary>Cached hot catalog reads in Redis to cut database load on popular POS and inventory listings</summary>

**Cache-aside, not write-through, and on purpose.** Write-through would put cache population inside the vendor's publish transaction. That would tie a write path to a cache that the design treats as expendable. Cache-aside keeps Redis strictly optional. If Redis is gone, everything still works, just more slowly.

**Keyspaces, and each one has its own invalidation rule.**

- `cat:listing:{product_id}:v{rev}` holds the fully loaded detail: the spine, the metadata document and the signed media URLs. The TTL is 15 minutes. The indexer deletes the key on a publish or update event. The `v{rev}` suffix is the important part. A stale key is *unreachable* even if the purge message is lost. This is because the reader builds the key from the revision pointer in Postgres. So correct invalidation doesn't depend on a message arriving.
- `cat:search:{filter_hash}` holds the ordered list of product IDs for one combination of filter and cursor. The TTL is 60 seconds, and there is no other rule. One listing change can affect too many filter combinations to list them all. So we keep the data fresh with a short TTL, not with a purge.
- `cat:facets:{category_slug}` holds facet value counts. The TTL is 5 minutes. The indexer purges it on any projection write in that category.
- `authz:jwks` holds the identity provider's signing keys. The TTL is 10 minutes, and the cache entry refreshes on an unknown `kid`. Because of this cache entry, authorization costs 1 ms in the latency budget, not an introspection round trip.
- `rl:*` and `idem:*` hold rate-limit counters and idempotency keys. They use expiry only.
- Two things are cached in the process, not in Redis: the category tree and the facet schemas. Both are tiny and almost never change. Their TTL is 60 seconds. A category label that is stale for a minute does no harm.

**How a read actually uses the cache.** Search gets IDs from `cat:search`. Then one `MGET` reads all the listing keys. Then a single bulk `$in` query goes into Mongo for whatever missed. It's never one lookup per item. That shape keeps the uncached path at about 107 ms instead of thirty round trips.

**The hit ratio is an [SLI](https://sre.google/sre-book/service-level-objectives/ "Service Level Indicator — Measured metric, such as latency or error rate, used to judge service health"), not just a statistic.** It must stay above 0.85 on `cat:search`, because the latency budget assumes it. If the ratio drops, the p95 changes before any other signal tells you.

**We specified how the system degrades. We don't just hope.** Losing Redis is not an outage, because every read falls through to the database. Latency goes from about 35 ms to about 107 ms. Postgres load goes up about six times, and capacity is sized to survive exactly that. Rate limiting and idempotency degrade with Redis. They do it differently on purpose: both fail *closed* for writes and *open* for reads.

**The honest limit.** A bare TTL on the hot listing key turned this cache into a synchronised stampede under concentrated traffic. Two mechanisms fixed it: single-flight and probabilistic early expiry. They are described under "Two Problems That Cost Us", because the story is worth more than the mechanism.

</details></li>
</ul>

</details>

## Authentication and Authorization (~105 s)

This section matters most, because every serious threat here comes from someone who is logged in. The dangerous actor isn't an intruder. It's a legitimate vendor who goes through the buyer side, record by record, to build a sales list.

Identity comes first. One service is the OAuth2 authorization server. No other service authenticates anybody. The web app and the admin console use the authorization code flow with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret"). Vendor systems that push catalog data use client credentials. Access tokens are signed with [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") and last fifteen minutes. The signing key is in Key Vault, and during rotation the old and new keys overlap. Refresh tokens rotate. Each one has a one-time-use identifier. If someone presents a revoked refresh token, the whole chain is revoked and an alert fires.

We verify the token twice, on purpose. The gateway checks the signature, the expiry and the audience at the edge. So a forged token never reaches the cluster. Then each service checks the token again locally, against a cached key set. After that, the service applies its own rules.

> **"The edge is a filter, never the authority. And neither check makes a network call. An introspection round trip on every request would have used a fifth of the latency budget."**

Then comes authorization. It is three checks, in this order:

- **Account type**, from a claim on the token. Vendor routes need a vendor token. Retailer routes need a retailer token. Admin routes need a platform token. A retailer token cannot reach a vendor route, whatever its scopes are.
- **Role to scope.** A vendor viewer gets read only. A category manager gets connection-write but not group administration. So a category manager can't add stores or change who is in the group.
- **Tenant scope.** This decides which organisation's rows you can reach.

The third check is the one that matters. I enforced it in exactly one place: a session-level filter in the repository layer. It is not a check in each endpoint.

> **"A check in each endpoint works right up until the day someone adds a new endpoint."**

Platform admins skip the filter explicitly. Every time they skip it, the system writes an audit row.

I want to state one decision plainly, because it's the opposite of what I'd normally choose. Postgres row-level security is the stronger mechanism. But I chose not to use it as the main control here. The read path runs on a replica, through a pooled connection with a shared role. Row-level security can work there. But each request would have to set its session variable with `SET LOCAL`, inside its own transaction. If one path gets that wrong, a `SET LOCAL` outside the transaction silently does nothing. And a plain `SET` leaks into the next caller's query.

> **"A security control that quietly stops working is worse than no control at all. If I can't guarantee it under real connection handling, it can't be the main control."**

The compensating control is this. The filter lives in one layer that we can audit. And a test checks every repository method that touches a table owned by an organisation. For each one, it asserts that a cross-tenant read returns nothing.

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Implemented OAuth2 and JWT authentication for vendors and retailers so catalog and connection APIs stayed behind the right account type</summary>

**Two grants, for two really different clients.**

- The marketplace web app and the admin console use the authorization code flow with PKCE. Both are public clients that hold no secret. The refresh token is in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie scoped to the API origin.
- Vendor system integrations that push catalog data use client credentials. They are confidential clients. Their secret is stored as an Argon2id hash on `oauth_client`.

**Token shape.** Tokens are signed with RS256 and last fifteen minutes. The claims are `sub`, `act` for the account type (vendor, retailer or platform), `org_id`, `roles[]`, `scopes[]`, `jti` and `exp`. The signing key is in Key Vault and rotates every 90 days. During the overlap window, the [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token") endpoint publishes both keys. Refresh tokens last 30 days and rotate. Each one has a one-time-use `jti`. If someone presents a revoked refresh token, the whole chain is revoked and an alert fires.

**We verify twice, and that's the design.** The gateway checks the signature, the expiry and the audience at the edge. So a forged or expired token never reaches the cluster. Then each service checks the token again locally, against the JWKS cached in Redis. After that, the service applies its own scope and tenant rules. The edge is a filter, never the authority. And neither check makes a network call per request. An introspection round trip would add 15 to 30 ms to every hop. It would add that in both the cached and the uncached columns of the latency budget.

**Then three authorization checks, in this order.**

- *Account type* comes from the `act` claim. A FastAPI dependency on every router enforces it. `/v1/vendor/*` needs a vendor token. `/v1/retailer/*` needs a retailer token. `/v1/admin/*` needs a platform token. A retailer token cannot reach a vendor route, whatever its scopes are. This coarse check is the one the brief actually named.
- *Role to scope* is resolved when the token is issued, not at request time. A vendor `viewer` gets `vendor:read` only. A `category_manager` gets `retailer:read` and `connection:write`, but not `retailer:admin`. So a category manager can shortlist and open conversations. But they cannot add stores or change who is in the group.
- *Tenant scope* is the one that matters. Every query on a table owned by an organisation is filtered on `org_id` from the token. It is enforced in exactly one place: a SQLAlchemy session-level filter that the repository layer applies. It is not a check in each endpoint, because a check in each endpoint works right up until the day someone adds a new endpoint. Platform admins skip the filter explicitly, and every time they do, the system writes an audit row.

**What revocation actually costs.** Nothing calls the identity service on each request. So the fifteen-minute access-token lifetime limits how fast revocation works. The refresh chain is revoked immediately. In one case, fifteen minutes is not good enough: a suspended vendor. For that case, the identity service publishes a deactivation event. Then services check a small Redis denylist of revoked `jti` values.

**The honest limit, and it's the decision I'd start with.** Postgres row-level security is the stronger mechanism, and I chose not to use it as the main control. The read path runs on a replica, through a pooled connection with a shared role. [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") can work there. But each request would have to set its session variable with `SET LOCAL`, inside its own transaction. If one path gets that wrong, a `SET LOCAL` outside the transaction silently does nothing. And a plain `SET` leaks into the next caller's query. A security control that quietly stops working is worse than no control at all. The compensating control is that the filter lives in one layer we can audit. A test checks every repository method that touches a table owned by an organisation. It asserts that a cross-tenant read returns nothing.

**The second limit is operational.** The gateway caches the JWKS on its own schedule. That schedule is separate from the `authz:jwks` key in Redis. So during a signing-key rotation, the two caches can disagree. Then the edge may reject tokens signed with the new key while the cluster accepts them. The key-overlap window must be strictly longer than the gateway's [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") configuration refresh interval. And we have to confirm that interval on the target tier before the first rotation. We must not find it out during a rotation.

</details></li>
</ul>

</details>

## How Services Talk, and How They Stay Consistent (~165 s)

The rule fits in one sentence. We use a synchronous call when the caller can't act without the answer. We use an asynchronous one when the caller only needs the work to happen.

In practice, there are four transports, and each one has a stated job:

- **Synchronous [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs")** is for anything a user is waiting on.
- **Azure Service Bus topics** are for domain facts that cross a boundary. For example: listing published, connection requested, user deactivated.
- **Celery** is for the jobs we are responsible for and have to retry. For example: imports, indexing and notification policy.
- **Azure Functions** are for delivery and media processing. A queue triggers them, and so do blob writes.

> **"Celery moves work between Python processes we own. Service Bus moves events across a boundary. That split is a rule, not a preference."**

One event is worth a closer look. It's the only place where a commercial event writes into the buyer's private working set. When a category manager opens a connection, that event sets the product's shortlist row to "contacted". The requirement was to track who is already in talks. The write is asynchronous and idempotent. So for a short time, somebody may still see "candidate". That's acceptable, because the connection list itself is the source of truth in the UI. The badge on the shortlist is not.

> **"The vendor side can't see anything else in the buyer's working set. This is the one write that goes into it, and nothing comes back out."**

I'll point out one thing on the synchronous side. In the whole design, exactly one synchronous call crosses a service boundary. connection-service asks retailer-service whether that group already has an open thread. The call has a 250-millisecond timeout. On timeout, it fails open and allows the connection.

> **"Refusing a real connection request costs the marketplace more than an occasional duplicate thread. And a unique constraint catches the duplicate anyway."**

I spent most of my design time on keeping two stores and a projection in agreement. They cannot share one transaction. There are three rules:

- **First**, nothing is dual-written. A publish writes the revision document to Mongo first. Then, in one Postgres transaction, it commits the pointer together with an outbox row. The relay ships the event from there. Mongo goes first on purpose. A leftover document that nothing points at is invisible garbage, and we can clean it up. But a committed pointer to a document that doesn't exist is a broken listing. We pay for this in freshness. A listing becomes searchable in about five seconds, or thirty seconds at p99. With a dual write, the commit can succeed while the publish fails. From then on, the two stores disagree forever, and nothing reports it. With an outbox, the failure is just an unpublished row. You can see it on a dashboard, and it clears by itself once the consumer is back.
- **Second**, the schema removes duplicates. We don't rely on a retry handler for that. The projection upserts on the product ID. It ignores any event whose revision is older than the row's current revision. So a redelivery changes nothing. And out-of-order delivery can't move a listing back to an older version. A connection request carries an idempotency key with a unique constraint on it. So a double-clicked form can't create two threads or bill the vendor twice.

  > **"At-least-once delivery should land on a constraint. It should not depend on a code path that hopes it never runs twice."**

- **Third**, there is a reconciliation job, because an event can still be lost. It runs every night. It re-projects any listing whose projection timestamp is more than five minutes behind its update timestamp. It also cleans up leftover revisions. And the lag itself is a metric with an alert on it. This is because a dead indexer fails silently, and nothing else would show it. New listings just stop appearing, and no error appears anywhere.

**On the security side:** We use [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") everywhere. Every data store has a private endpoint, and none of them has a public IP. Inside the cluster, the network policy denies by default, with an explicit allow for each pair of services. Egress is also denied by default. And we use workload identity. So there are no connection strings and no static credentials anywhere in the cluster or in CI.

I did not add mutual TLS between services. That's a stated choice, not something I forgot. Doing it properly means a service mesh. A mesh costs too much for nine workloads in one namespace where no untrusted container runs. The trigger to think again is concrete. It is a third-party workload in the cluster, or a compliance requirement that names mutual TLS.

<details>
<summary><strong>If asked about GDPR</strong></summary>

The personal data here is work data: names, work email addresses, and the messages staff write to each other. There is no consumer data, no special-category data and no profiling. The one real conflict is erasure. When someone leaves a chain, we tombstone their identity: the auth subject, the email and the name. We revoke their refresh chains. And we pseudonymise them in the audit trail. But we keep the message bodies they wrote, and we assign them to a deleted-user tombstone. We do that under Article 17(3)(e). A vendor's record of a commercial negotiation isn't the individual's to delete.

And here is the cost, stated plainly. The erasure isn't total. The text we keep may still identify its author from the context. So the privacy notice has to state this position, and we have to be able to defend it to a supervisory authority. The alternative is deleting the messages. That destroys the other party's business record, and that's the worse failure.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Configured Celery for catalog imports and notification jobs so new listings and connection requests did not block the API</summary>

*The import mechanics are under "The Vendor Workspace and Bulk Imports". This note covers the transport rule and the durability question.*

**The rule that decides which system carries a piece of work.** Celery moves work between Python processes we own. Service Bus moves events across a boundary: to Functions, to another service, or to any future consumer. That split is a rule, not a preference. Breaking it in either direction puts one system in a role it's bad at. That would mean Celery calling out to a Function, or Service Bus scheduling in-process Python work.

**Three queues and three separate worker deployments.** The queues are `imports`, `indexing` and `notifications`. They use the same application codebase, but a different deployment. The separate deployment is the whole point, because a twenty-thousand-row import running in the web tier would use up the capacity that browse needs. And separate queues mean imports cannot starve indexing either.

**Queue depth does three jobs at once.**

- It's the autoscaling signal. An [HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ "Horizontal Pod Autoscaler — Automatically adjusts the number of Kubernetes pod replicas to match load") scales on `celery_queue_depth` through a custom metric adapter. So a large import scales the importers and never touches the web tier.
- It's an SLI. The threshold is 500 on `imports` and 100 on the other queues.
- It's an alert input.

Task failures have their own metric for each task name. They alert on any sustained failure rate. That makes the brief's "job failures" concrete.

**One owner for each step in the notification path.** The notification worker decides *whether* to notify and *what* to send. That's a policy decision that needs database context, so it belongs in Python. The Function does the *delivery* to the email provider. The two halves don't overlap, and neither one re-implements the other.

**Workers are drained, not killed.** A `preStop` hook stops queue consumption and waits for the task in progress. The 120-second termination grace period limits that wait. We choose chunk sizes so a chunk finishes well inside that period. So a rolling deploy doesn't abandon work in the middle of a task.

**The honest limit, and it's a real one.** Celery here runs on Redis, and Redis has no true acknowledgement semantics. `acks_late` plus a visibility timeout make it acceptable. Underneath, [AOF](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ "Append Only File — Redis persistence mode that logs every write for durability") persistence runs at `everysec`. But if a worker is killed in the middle of a task, recovery depends on that visibility timeout expiring. And a broker failover can still drop a task that wasn't acknowledged. So we needed a kill-the-worker test on the pinned Celery and Redis versions before I'd call imports durable. If imports had to be truly durable, the next step was to run the `imports` queue on Service Bus. Service Bus was already in the stack. Redis would stay for `notifications` and `indexing`. We can fully rebuild their work from the outbox, so they don't need the guarantee.

</details></li>

<li><details>
<summary>Integrated Azure Functions, Blob Storage, and Service Bus for catalog updates and vendor–retailer notifications when a listing changed or a chain opened a thread</summary>

**Service Bus topology.** There are two topics and one queue: catalog events, connection events, and a notification-dispatch queue. We use topics because the pattern is fan-out with competing consumers. Topics also give dead-lettering and a native Function trigger, with no cluster to run. We considered [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") and Event Hubs and rejected them on volume. This system sends roughly 0.2 events a second.

**Every event has the same envelope.** It carries an event ID, a type, the time it happened, an aggregate ID, an optional source revision ID and a payload. Every consumer is idempotent on the event ID.

**The event list, with the consumers named.**

- Listing published goes to the indexer and the notification worker. So facets are projected, the cache is invalidated, and saved-search subscribers get an alert.
- Listing updated goes to the indexer only.
- Listing archived goes to both. Retailers who have that product in a shortlist need a warning.
- Import completed goes to notification. So the vendor sees the outcome for each row.
- Connection requested goes to three places. It notifies the vendor, adds the billing charge, and sets the shortlist item to "contacted".
- Connection responded records the first-response timestamp. That timestamp is the input to the liquidity metric.
- User deactivated goes to both the retailer service and the vendor service. They revoke the refresh chain and tombstone the actor.

**Nothing is published directly.** Each of those events is written to the outbox table in the same Postgres transaction as the state change. The relay publishes it afterwards and sets `published_at`. Delivery is at-least-once, and never zero times. That is why consumers must be idempotent, not just careful.

**Two Functions, and each one has a reason to be off the request path.**

- Media processing is triggered by blobs. It makes thumbnails and [PDF](https://en.wikipedia.org/wiki/PDF "Portable Document Format — Fixed-layout document format for reliable printing and viewing") previews. Making thumbnails for a forty-page datasheet must never hold an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") connection open. It's also a security control. It re-encodes the images vendors upload, and that neutralises a malicious upload.
- Notification dispatch is triggered by a queue. It does delivery only.

**The blob layout is by prefix, and each prefix has its own lifecycle rule.**

- Listing media sits under the product and the revision. It moves to the cool tier after 180 days.
- Derived thumbnails sit under that path. We can regenerate them, and they are deleted with the revision.
- Import uploads sit under the vendor and the job. They are deleted after 90 days.
- The admin console bundle sits under its build [SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity"). We keep the last five builds.
- [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") state has its own container. It is versioned and lease-locked.

Those paths are content-addressed. So we never need [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") invalidation. A new revision is just a new [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web").

**One separation on the serving side, on purpose.** Files that vendors supply go out with `Content-Disposition: attachment`, through a separate download hostname. So we never serve a vendor file from the origin that hosts the admin console.

**Least privilege is set for each workload, not for the whole cluster.** Only the outbox relay can send on the two topics. Only the vendor service and the import worker can write the import and listing blob prefixes. The catalog service can read its own secrets, and it has no access to Service Bus at all.

**The honest limit.** If Service Bus is down, events simply wait in the outbox. `published_at` stays null, the relay continues later, and nothing is lost. Instead, you get projection lag and notification lag while the outage lasts. Functions dead-letter after ten attempts, with an alert on that. The result is a delayed email, not data loss. The remaining risk I'd name is that a dead indexer fails *silently*. New listings just stop appearing, and no error appears anywhere. That's why projection lag is a metric that pages someone. We don't want to find out from a support ticket.

</details></li>
</ul>

</details>

## Optional — The Vendor Workspace and Bulk Imports (~45 s)

I built the admin workspace over vendors, chains, stores and products. The point is this. Every entity that a support ticket would otherwise touch can be edited by the right role, with no engineering change. It's a static console that calls the same versioned public API. It is not a private backend.

> **"The benefit is that no admin capability exists that the public contract doesn't already describe and test."**

Imports are the other half. A vendor who uploads twenty thousand rows must not slow down browse for everyone else. So here is how it works:

- The file is split into tasks of five hundred rows. The tasks run on their own queue and their own worker pool. Each vendor has a concurrency cap, held as a Redis semaphore. So one vendor can't take over the pool.
- Rows go into a staging collection first. We validate them against the category schema before any live row changes. A malformed file fails completely, with an error digest for each row. It is never half-applied.
- The projection is batched. A completed import re-projects in batches of two hundred. Otherwise, one import would mean twenty thousand cache invalidations.

<details>
<summary><strong>If asked: "what happens if an import worker dies mid-chunk?"</strong></summary>

Nothing is half-applied, and that's what the staging collection is for. A dead chunk means the import doesn't complete. It does not leave the catalog inconsistent. But I'll point out the limit honestly, because it's a real one. Celery runs on Redis, and Redis has no true acknowledgement semantics. Redelivery of a chunk in progress depends on a visibility timeout expiring. And a broker failover can still drop a task that wasn't acknowledged. So we needed a kill-the-worker test before I'd call imports durable. If imports had to be truly durable, the next step was to run that one queue on Service Bus. Service Bus was already in the stack.

</details>

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Built an admin panel for vendors, retail chains, stores, and software products so vendor teams could update listings and category managers could shortlist without engineering tickets</summary>

**What it is in the architecture.** It's a static single-page bundle. Blob storage serves it through the CDN, keyed by build SHA. It calls the same versioned `/v1` APIs that everything else calls. There is no private admin backend anywhere in this design.

**The surface.** There are admin routes over vendors, retail groups, stores and products. Each one has list, detail, patch and a state-transition endpoint. They need `act = platform` and the `platform:admin` scope. They are the one part of the system with no org scoping.

**What that gives us in operations.** Every entity that a support ticket would otherwise touch can be edited by the right role, with no engineering change. That covers:

- vendor vetting state, which controls whether a vendor can publish;
- retail group status;
- a chain's store footprint, which feeds coverage matching;
- product status transitions.

It removes one failure mode: "change this vendor's status" being a database console and a Slack message.

**Skipping the filter is explicit and audited.** Platform admins skip the tenant filter on purpose, not by an accident of scope. Every time they skip it, the system writes an audit row. Every admin action also writes an audit row. The rows go into an append-only table, partitioned by month, with no update or delete grant.

**The cost, stated.** The UI is chattier on entity screens that join data across services. The console has to call several APIs where a private backend would have run one query. The benefit is that no admin capability exists that the public contract doesn't already describe. And the functional test stage already exercises every one of them.

**One routing rule that belongs here.** The vendor workspace reads the sources of truth directly: the Postgres primary and the metadata document. It never reads the projection or the cache. So vendors can read their own writes. A vendor sees the projection in only one place: an explicit "preview as a retailer sees it" view. There, the staleness is the point, not a defect.

</details></li>

<li><details>
<summary>Configured Celery for catalog imports and notification jobs so new listings and connection requests did not block the API</summary>

*The transport rule and the Celery-on-Redis durability question are under "How Services Talk". This note covers what an import actually does.*

**Chunking.** The uploaded file is parsed and split into tasks of 500 rows on the `imports` queue. A twenty-thousand-row file is forty tasks. It is not one long-running job where one failure costs everything.

**A concurrency cap for each vendor.** Each vendor can run at most four chunks at the same time. A Redis semaphore holds that cap. So one vendor uploading their full catalogue cannot take over the pool and delay everyone else's imports. The queue alone doesn't give you that fairness.

**A separate worker deployment on a separate queue.** Import workers scale on the depth of the `imports` queue. They cannot starve indexing or notifications. This is the mechanism behind "an import must not slow down browse".

**Staged first, then promoted.** Rows go into a Mongo staging collection. We validate them against the category's facet schema *before any live product row changes*. A malformed file fails completely at validation, with an error digest for each row. It is never half-applied. The staging collection has a 30-day TTL index, so it cleans itself up without a job.

**Batched projection.** A completed import sends one completion event. Then the indexer re-projects the affected products in batches of 200. Without batching, one import means twenty thousand upserts and twenty thousand cache invalidations. Then the import would become exactly the event that slows down browse, which it was designed not to be.

**The job state can be queried.** Status, total rows, successful rows, failed rows and the error digest live in a relational table. So the vendor workspace can show progress and the outcome. The detail for each row stays in Mongo staging, where it belongs.

**Two limits at the edges.** First, each vendor can run at most five import jobs a day. That is a marketplace-integrity control, not a capacity control. Second, if more than 5% of a job's rows fail, the system raises a ticket. The vendor sees the same error digest that the alert names.

</details></li>
</ul>

</details>

## Optional — How It Ships (~45 s)

GitLab CI is the only path to production, and every gate can really fail the build. The gates run in this order. First ruff, type checking and unit tests. Then integration tests against real containers: real Postgres, real Mongo and real Redis. Then a functional pass against the OpenAPI contract. Then image scanning and dependency scanning.

> **"The projection pipeline and the query plans are exactly the things a mocked test passes while they are broken."**

Terraform owns every Azure resource, including the alert rules. This matters because of a common failure. Someone silences an alert by hand during an incident, and nobody turns it back on. That is how monitoring slowly stops working. Terraform applies only from CI. CI authenticates with [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") federation, not with a stored secret.

Teams often skip the migration rules, so I'll name them. Every migration here is expand-contract. One release adds nullable columns and builds indexes concurrently. Dropping what nothing reads any more is a separate merge request. It comes at least one release later.

> **"That's what makes rollback real. The old image has to be able to run against the new schema. Otherwise, 'roll back' is just a word."**

The read service gets a canary at ten percent. We hold the canary against its error rate and its p95, because the read service carries the risky query plans. Everything else uses a rolling update. And workers are drained, not killed.

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Automated GitLab CI pipelines for test and deploy across marketplace services</summary>

**One repository, one pipeline, nine deployable images.** The stages run in this order:

1. Lint with ruff and mypy.
2. Unit tests.
3. Integration tests against real data stores that Compose starts.
4. A functional pass against the OpenAPI contract.
5. Image build with digest pinning.
6. Image [CVE](https://www.cve.org/ "Common Vulnerabilities and Exposures — Public identifier for a known software security flaw") scanning and dependency scanning.
7. The expand migration.
8. Staging deploy.
9. Smoke tests.
10. Production, as a canary and then a rolling update.

The contract migration comes later, as a separate merge request.

**Every gate can really fail the build.** Dependencies are pinned by hash, and images are pinned by digest. Base images are rebuilt every week. The scan stage blocks the build. It doesn't just report.

**The step teams skip, which I'd name without being asked.** Every migration is expand-contract. One release adds nullable columns and new tables. It builds indexes `CONCURRENTLY`. So with these changes, the previous image keeps running against the new schema during the whole rollout. Dropping a column that nothing reads any more is a separate merge request, at least one release later. That is what makes rollback real. The old image has to be able to run against the new schema. Otherwise, "roll back" is just a word. The rollback itself is a redeploy of the previous image digest. It is safe by construction, because during the window the schema is compatible in both directions.

**CI authenticates to Azure with OIDC federation**, not with a stored service principal secret. Terraform applies only from the default branch.

**The honest limit.** The CI deploy identity holds more privilege than anything else in the design. It can apply Terraform across the whole subscription. A split of this identity is worth designing before the first production apply, not after an incident. The split has two parts. First, a plan-only identity for merge requests, and an apply identity that runs only on protected-branch pipelines. Second, the network modules and the data-plane modules each get their own state and their own identity.

</details></li>

<li><details>
<summary>Provisioned Azure marketplace infrastructure with Terraform so AKS, storage, and functions stayed in versioned config</summary>

**What Terraform owns: everything.** That includes:

- the cluster and its node pools;
- the Postgres Flexible Server and its read replica;
- both Redis instances;
- the Mongo deployment;
- blob containers and their lifecycle rules;
- the Service Bus namespace, with its topics, subscriptions and dead-letter settings;
- both Function Apps;
- the API gateway;
- the CDN and [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") edge;
- Key Vault;
- every monitoring alert rule.

**State handling.** The state lives in its own blob container, with versioning and lease locking. So two applies that run at the same time can't mix their changes.

**Environments are workspaces over one set of modules.** They differ only in a variables file. So staging has the same topology, with smaller instance sizes. That is what makes a staging smoke test meaningful, not just for show.

**Terraform manages the alert rules, and nobody can edit them in the portal.** A common failure is this: someone silences an alert by hand during an incident, and nobody turns it back on. That is how monitoring slowly stops working. This setup removes the way to do that. It doesn't rely on people's discipline.

**Role assignments are Terraform resources too.** That's the point I'd make about security here. A wider permission shows up as a diff that someone can review. It is not a change that nobody notices. Nothing in this section depends on code review alone.

</details></li>

<li><details>
<summary>Deployed services to Azure AKS with Docker and Kubernetes</summary>

**Shape.** There is one cluster, one namespace and nine workloads: six services and three worker pools. Compose starts the full set of data stores for local development and for CI integration tests. So the containers a developer runs and the containers CI tests against are the same images, at the same pinned versions.

**Autoscaling on two different signals.** The six services use an HPA on CPU, with a 65% target. The three worker pools use an HPA on Celery queue depth, through a custom metric adapter. So a large import scales the importers without touching the web tier. The cluster autoscaler runs between three and eight nodes.

**The rollout strategy depends on the risk, on purpose.** The catalog service gets a canary. That is a second deployment that receives about 10% of traffic through ingress weighting. We hold it for fifteen minutes against its error rate and its p95. The reason is that the catalog service takes the traffic and carries the risky query plans. Everything else uses a rolling update with readiness and liveness probes. Workers are drained, not killed, with a `preStop` hook and a 120-second grace period.

**We considered blue/green and rejected it**, and the reason is worth giving. It doubles the number of pods. And both colours share the same Postgres, so it gives no isolation at the database level. That database isolation is the only part of the risk that expand-contract migrations don't already cover.

**Network setup inside the cluster.** NetworkPolicy denies by default, with an explicit allow for each pair of services. Egress also denies by default. It reaches only the payment provider, the email provider and Azure service endpoints. Workload identity links each [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") service account to its own managed identity. So there are no connection strings and no static credentials anywhere in the cluster.

**The honest limit.** There is no mutual TLS between services. That's a stated choice, not something I forgot. Doing it properly means a service mesh. A mesh has real costs: the sidecar lifecycle, certificate rotation, and a new failure mode in every request path. Those costs are too high for nine workloads in one namespace where no untrusted container runs. The trigger to think again is concrete. It is one of these:

- a third-party or customer-supplied container in the cluster;
- a second workload that faces tenants;
- a compliance requirement that names encryption in transit between internal services.

If any of those happens, a mesh goes in.

</details></li>

<li><details>
<summary>Wrote unit, integration, and functional tests with Pytest for catalog, auth, and connection paths</summary>

**Three levels with three different jobs.** Unit tests cover domain rules with no database at all. That comes from the clean-architecture layering. It isn't a separate practice. Integration tests run against real Postgres, Mongo and Redis, which Compose starts at the pinned versions. Functional tests exercise the API against the generated OpenAPI contract.

**Why real data stores and not mocks.** This is the choice I'd defend hardest. The projection pipeline and the GIN query plans are exactly the things a mocked test passes while they are broken. A mock of the indexer will happily confirm a projection that never happens.

**The security test I'd name specifically.** A cross-tenant read returns nothing for every repository method that touches a table owned by an organisation. That test *is* the compensating control for not using row-level security. Without the test, the argument for the repository-layer filter doesn't hold.

**The contract tests matter beyond testing.** They make it safe for the admin console to share the public API. No admin capability exists that the contract doesn't describe and the functional stage doesn't exercise.

**Three things that need a test before I'd believe them.**

- The query plan. We test it with `EXPLAIN (ANALYZE, BUFFERS)` on a seeded table of 40,000 rows, at the pinned Postgres minor version.
- Celery-on-Redis redelivery. We test it with a kill-the-worker test before calling imports durable.
- An end-to-end trace ID across a publish-to-notify flow. We need this test because the OpenTelemetry propagation through Service Bus and Celery has been partly manual in the past. That propagation is the claim most likely to be false as written.

</details></li>
</ul>

</details>

## Optional — Logs, Metrics and Traces (~45 s)

We use Azure Monitor and Application Insights. One OpenTelemetry [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") sends metrics, logs and traces. So all three carry the same resource attributes, and there is one instrumentation dependency.

What makes it useful is where the trace ID travels. It goes in Service Bus message properties, not only in HTTP headers. So one trace covers the request, the outbox publish, the projection and the cache invalidation. Nobody can debug exactly that chain from logs alone.

Every log line carries a request ID, a trace ID and the organisation ID. So we can limit a support question to one tenant without searching all the text. And there are two standing rules. We never log a conversation message body. And we never log a token or a secret.

> **"And the audit trail doesn't live in the logs at all. It's a table. It's append-only, with no update or delete grant. It's not a log stream, because then whoever tunes log retention would be setting your audit policy for you."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Monitored services with Azure Monitor, tracking API errors and job failures on catalog and connection flows</summary>

**One SDK for all three signals.** Metrics, logs and traces all go through the same OpenTelemetry SDK into Azure Monitor and Application Insights. So there is one instrumentation dependency to keep pinned. And every signal shares one set of resource attributes. That's what lets you move from a metric to the trace behind it without matching them by hand.

**The SLIs, and each one exists for a reason.**

- Catalog search latency at p95, against a 200 ms target.
- Catalog read availability at 99.9% a month, and write-path availability at 99.5%. They are different on purpose, because browse and publish are not the same promise.
- Indexer lag, from the event to the projection: p95 under 5 seconds and p99 under 30. That's the staleness that the availability choice bought. It's also the number that tells you the projection died.
- Outbox unpublished age. It catches a stalled relay before any consumer notices.
- Celery queue depth for each queue. It is also the autoscaling signal.
- Task failures for each task name. These are the brief's "job failures".
- Cache hit ratio above 0.85 on the search keyspace, because the latency budget assumes it.
- Replica lag under 5 seconds. Above 30 seconds, the catalog service falls back to the primary.
- First-response time on connections, at p50. We track it but set no target, because it's the metric that says whether the platform actually makes sourcing shorter.

**What pages someone, and what raises a ticket.**

- Pages: catalog read error-budget burn at 14.4× over an hour; connection-create 5xx above 1% over five minutes; indexer lag p95 above 60 seconds for ten minutes; outbox age above 300 seconds.
- Tickets: any dead-letter on any subscription; an import job failing more than 5% of its rows; replica lag above 30 seconds for ten minutes; a certificate or Key Vault secret thirty days before it expires.

Each rule names an owner and a runbook. All of them are Terraform resources, not portal edits.

**Logging rules.** Logs are [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") to stdout. Every line carries the request ID, trace ID, service, actor side, org ID, route and status. The org ID is always there. So we can limit a support question to one tenant without searching all the text. There are two standing bans: no connection message body, and no token or client secret, ever.

**Tracing, and the part that makes it useful.** There is auto-instrumentation for FastAPI, SQLAlchemy, the Mongo driver, Redis and Celery. Trace context travels in Service Bus *message properties*, not only in HTTP headers. So one trace covers publish, projection, cache invalidation and notification. Nobody can rebuild exactly that chain from logs alone. We sample 100% of errors and of write-path requests. We sample 5% of catalog reads.

**The audit trail is not the logs, and I'd insist on that boundary.** Audit events are a table. The table is append-only, with insert and select grants only. Its monthly partitions are archived to immutable storage. Audit rows are written asynchronously from the outbox, not synchronously in the request path. This is because a synchronous audit write on a read would make it impossible to serve catalog reads from a replica. If the audit trail were a log stream, whoever tunes log retention would be setting audit policy.

**The honest limit.** Trace continuity across Service Bus and Celery is the claim here most likely to be false as written. It depends on the instrumentation versions actually injecting and extracting the trace header. Both have been partly manual. The versions are pinned. And an integration test asserts one end-to-end trace ID across a publish-to-notify flow. Otherwise, you find out it doesn't work during an incident, and that's the worst possible time.

</details></li>
</ul>

</details>

## If Asked — Two Problems That Cost Us (~85 s)

### Problem one — the publish that looked lost

Retailers could not see the eventual consistency, but vendors saw it very clearly. A vendor clicked publish, and the API returned two-oh-one. But for the next few seconds, their own listing page showed the old content. So they clicked publish again. And again. We got support tickets saying the platform had lost their changes. And behind every ticket, there was a burst of duplicate work.

The lag was within the budget. The mistake was mine. It was a routing mistake, not a latency mistake. The vendor workspace was reading the same cached projection that the retailer catalog reads.

The fix was to route by audience, not by endpoint. The vendor workspace now reads the sources of truth directly: the Postgres primary and the metadata document. It never reads the projection or the cache. Vendors can read their own writes. Retailers get the fast, cached view that is a little stale. A vendor sees the projection in only one place: an explicit "preview as a retailer sees it". There, the staleness is the point.

> **"What I learned: eventual consistency isn't a property of a system. It's a property of a reader. Decide for each audience who can see stale data, and route the query to match."**

### Problem two — the cache that made the spike worse

We cached hot listings with a plain fifteen-minute TTL. That's the obvious thing to do, and it works almost all of the time. Then a trade newsletter featured one vendor's product.

Under concentrated traffic, the failure is exact. The key expires. Every request at that moment misses at the same instant. And all of them hit Postgres and Mongo together. The cache didn't absorb the spike. It synchronised it. And it did that exactly when the traffic was highest, which is the only moment that mattered.

Two small mechanisms fixed it.

- The first is single-flight for each key. On a miss, the first pod takes a short lock and recomputes the value. The other pods check again for a short time, and then they serve the stale value.
- The second is probabilistic early expiry. Readers recompute a little before the TTL ends, and the probability rises as the TTL gets closer. So recomputation spreads over a window instead of landing on one instant.

Together, they limit the database load for any one listing to roughly one recomputation per TTL. That stays true however many readers arrive at the same time.

> **"And the lesson has much the same shape: a cache changes when the load arrives, not just how much load arrives. A bare TTL is a scheduled thundering herd. You just haven't been popular enough to see it yet."**

<details>
<summary><strong>Responsibilities</strong></summary>

<ul>
<li><details>
<summary>Cached hot catalog reads in Redis to cut database load on popular POS and inventory listings</summary>

*The keyspaces, TTLs and invalidation rules are under "The Data Layer". This note covers how the stampede fix works.*

**Single-flight, in detail.** On a miss, the pod tries `SET cat:lock:{key} NX EX 5`. The pod that wins recomputes the value. The pods that lose check the key again for up to 200 milliseconds. Then they serve the stale value, if one exists. The lock expires after five seconds. So if a pod dies in the middle of recomputing, the key doesn't stay locked.

**Probabilistic early expiry, in detail.** Each cached value carries its own computation cost and a tuning delta. A reader recomputes early with a probability that rises as the TTL gets closer. So recomputation spreads across a window instead of landing on one instant. That was the real problem. The expiry wasn't too short. It was too *synchronised*.

**What the two together limit.** Roughly one recomputation per TTL for each key, however many readers arrive at the same time. That property is worth stating because it doesn't depend on traffic. It doesn't get worse as the listing gets more popular. A bigger cache or a longer TTL would get worse.

**What it costs.** A losing request can wait up to about 200 ms longer. The value it serves can be up to 200 ms stale. And there is a small amount of code that only helps under exactly the traffic pattern the brief describes. It's cheap, but not free. It's not worth adding to every cache in a system just in case.

**Which key this is really about.** It's the hot listing detail key, with a fifteen-minute TTL. The search-page key, with a sixty-second TTL, is a different case. Its TTL is short because one listing change can affect too many filter combinations to list them all. So the search-page key was never the stampede risk that the detail key was.

**Why the damage stayed survivable while we had it wrong.** Cache-aside means Redis is expendable by design. Losing Redis completely takes latency from about 35 ms to about 107 ms. It also makes Postgres load about six times higher, and capacity is sized for exactly that. The stampede was *worse* than losing the cache. It delivered that same higher load, but concentrated on a single instant instead of spread across the minute.

</details></li>
</ul>

</details>

## Close (~20 s)

So, to sum up. There are six services, split for isolation, not for throughput. There is a relational spine and a schemaless body, joined by a projection that I can rebuild. Tenant scoping is enforced in one layer that we can audit. And every write that crosses a boundary goes through an outbox, not a dual write.

My share of the work was the catalog data layer and search, and the vendor and retailer APIs. It was also the identity and authorization model, and the async and import paths. And it was the infrastructure and the pipeline underneath.

I'm happy to go into any of that in more detail.
