# Deep Dive & Bottlenecks

*Retail Software Aggregation Platform*

## Table of Contents

- [Communication Patterns](#communication-patterns)
- [Event Catalogue](#event-catalogue)
- [The Latency Budget](#the-latency-budget)
- [Bottleneck 1: The Faceted Search Query](#bottleneck-1-the-faceted-search-query)
- [Bottleneck 2: Cache Stampede on a Popular Listing](#bottleneck-2-cache-stampede-on-a-popular-listing)
- [Bottleneck 3: Bulk Catalog Import](#bottleneck-3-bulk-catalog-import)
- [Bottleneck 4: Projection Lag Visible to the Vendor](#bottleneck-4-projection-lag-visible-to-the-vendor)
- [Failure Modes and Single Points of Failure](#failure-modes-and-single-points-of-failure)
- [Trade-offs](#trade-offs)

## Communication Patterns

The rule is one sentence: **synchronous when the caller cannot act without the answer; asynchronous when the caller only needs the work to happen.**

| Flow | Pattern | Why |
|---|---|---|
| Client → any service | Sync REST via Front Door → APIM → Ingress | The user is waiting |
| `catalog-service` → `postgres-core` replica, `mongo-catalog`, `redis-cache` | Sync | Inside the response the user is waiting for |
| `connection-service` → `retailer-service` (does this group already have an open thread?) | Sync REST | The answer changes what the caller returns |
| `vendor-service` / `connection-service` → downstream effects | Async via `outbox_event` → Service Bus | Publishing a listing must not fail because the notifier is down |
| `sb-catalog-events` → `indexer-worker` | Async, competing consumers | Projection is allowed to trail; `01-requirements.md` budgets p95 < 5 s |
| `sb-connection-events` → `billing-service`, `notification-worker` | Async, one subscription each | Billing a connection is not on the retailer's critical path |
| `notification-worker` → `sb-notification-dispatch` → `fn-notify-dispatch` | Async queue | Policy in Python, delivery in a Function; the split is a rule from `02-high-level-design.md` |
| API upload → `blob-media` → `fn-media-process` | Async blob trigger | Thumbnailing a 40-page PDF datasheet must never hold an HTTP connection |
| `vendor-service` → `redis-broker` → `catalog-import-worker` | Async Celery | A 20,000-row import is not a request |

**No synchronous call crosses more than one service boundary.** `connection-service` calling `retailer-service` is the only inter-service sync hop in the design, and it has a 250 ms timeout with a fallback that permits the connection rather than blocking it — an availability choice, since refusing a legitimate connection request costs the marketplace more than allowing an occasional duplicate thread, which the `UNIQUE (retail_group_id, idempotency_key)` constraint in `03-data-modeling.md` catches anyway.

## Event Catalogue

Every event is emitted through `outbox_event` and carries `{event_id, type, occurred_at, aggregate_id, source_revision_id?, payload}`. Consumers are idempotent on `event_id`.

| Event | Emitter | Consumers | Effect |
|---|---|---|---|
| `catalog.listing.published` | `vendor-service` | `indexer-worker`, `notification-worker` | Project facets, invalidate cache, alert saved-search subscribers |
| `catalog.listing.updated` | `vendor-service` | `indexer-worker` | Re-project |
| `catalog.listing.archived` | `vendor-service` | `indexer-worker`, `notification-worker` | Remove from search, warn retailers holding it in a shortlist |
| `catalog.import.completed` | `catalog-import-worker` | `notification-worker` | Vendor sees the row-level outcome |
| `connection.requested` | `connection-service` | `notification-worker`, `billing-service`, `retailer-service` | Notify vendor, accrue `billing_charge`, set `shortlist_item.status = 'contacted'` |
| `connection.responded` | `connection-service` | `notification-worker` | Stamps `first_response_at`; the input to the liquidity metric in `05-reliability.md` |
| `identity.user.deactivated` | `identity-service` | `retailer-service`, `vendor-service` | Revoke refresh chain, tombstone the actor |

`shortlist_item.status` moving to `contacted` via `connection.requested` is worth pausing on: it is the brief's "track who is already in talks", and it is the one place where a commercial event writes into the buyer's private working set. It is asynchronous and idempotent, so a category manager may briefly see a stale `candidate` — acceptable, because the authoritative signal in the UI is the connection list itself.

## The Latency Budget

The p95 < 200 ms catalog search target from `01-requirements.md`, decomposed. Two paths, and the target is met by the blend rather than by either alone.

| Hop | Cached path | Uncached path |
|---|---|---|
| Front Door + APIM (routing, quota, JWT signature check against cached JWKS) | 12 ms | 12 ms |
| Ingress → pod | 3 ms | 3 ms |
| Authorization: local claim check, no network call | 1 ms | 1 ms |
| Redis `GET cat:search:{filter_hash}` | 3 ms | 3 ms (miss) |
| PostgreSQL replica: keyset query on `product_listing_facets` | — | 45 ms |
| Redis `MGET cat:listing:*` | 4 ms | 4 ms |
| MongoDB bulk `$in` hydration of misses | — | 25 ms |
| Serialization (Pydantic, ~30 summaries) | 12 ms | 14 ms |
| **Total (server-side)** | **~35 ms** | **~107 ms** |

At the modelled 85% search-page hit ratio the p95 falls on the uncached path, ~107 ms, leaving roughly 90 ms of margin for the tail: a cold Postgres buffer cache, a GC pause, an autoscaling cold start. The p99 < 500 ms target absorbs a full uncached page with a `GIN` scan over an unselective predicate. **The budget only holds because authorization requires no network call** — JWTs are verified locally against a JWKS cached in `redis-cache`, and an introspection round-trip per request would add 15–30 ms to every hop in both columns.

## Bottleneck 1: The Faceted Search Query

This is the system's defining performance problem. A comparison workflow produces queries with many optional predicates over `product_listing_facets`: free text, a category, two or three array containments, a price ceiling, a deployment model. The planner's failure mode is a bitmap `OR` across several `GIN` indexes on an unselective combination, degrading toward a sequential scan as the table grows.

Mitigations, in the order they matter:

1. **Query on one denormalised table.** `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product` so the hot query touches exactly one relation and never joins (`03-data-modeling.md`).
2. **A partial index carrying the status predicate.** `idx_plf_browse` is defined `WHERE status = 'published'`, which keeps roughly 40,000 rows out of ~55,000 in the index and removes the filter from every plan.
3. **Keyset pagination.** `(published_at, product_id) < (cursor)` rather than `OFFSET`. Page 40 of a comparison costs the same as page 1.
4. **A category is required for facet-heavy queries.** The API refuses an uncategorised query carrying more than two facet predicates, which guarantees `idx_plf_browse` or `idx_plf_price` is always a viable leading index. This is a product constraint that buys a performance guarantee, and it matches how sourcing actually works — nobody compares a POS against a loyalty engine.
5. **`total_estimate`, not `total`.** Exact counts over a filtered `GIN` scan cost as much as the page itself. The API returns an estimate derived from the planner and stops counting at 1,000.

> **Verify Before Build:** The claim that `idx_plf_arrays` and `idx_plf_facets` combine into a bitmap `AND` rather than degrading to a sequential scan depends on the planner's selectivity estimates for `text[]` containment and `jsonb_path_ops`, which are poor for high-cardinality arrays. Confirm with `EXPLAIN (ANALYZE, BUFFERS)` against a seeded 40,000-row table on the pinned PostgreSQL 15 minor version *before* relying on the 45 ms figure above. If the plan is wrong, the fix is a composite covering index per high-traffic category, not a bigger instance.

## Bottleneck 2: Cache Stampede on a Popular Listing

The brief calls for caching hot catalog reads to cut database load on popular POS and inventory listings. Naive TTL caching does the opposite at exactly the wrong moment: a widely-viewed listing's key expires, and every concurrent request misses together and hits Postgres and Mongo simultaneously.

Two mechanisms, both in `catalog-service`:

- **Single-flight per key.** On a miss the pod takes `SET cat:lock:{key} NX EX 5`. The winner recomputes; losers poll the key for up to 200 ms and then serve the stale value if one exists.
- **Probabilistic early expiry.** Each cached value carries its computation cost and a `delta`; a reader recomputes early with probability rising as the TTL approaches. Recomputation spreads over a window instead of landing on one instant.

Together these bound Postgres load on a listing to roughly one recomputation per TTL regardless of concurrency. The cost is ~200 ms of possible staleness on a losing request and a small amount of code that only pays off under exactly the traffic pattern the brief describes.

## Bottleneck 3: Bulk Catalog Import

A vendor uploading 20,000 rows must not degrade browse for everyone else. `catalog-import-worker` chunks the file into 500-row Celery tasks on the `imports` queue, and:

- **Per-vendor concurrency cap** — at most 4 concurrent chunks per `vendor_id`, held as a Redis semaphore. One vendor cannot occupy the pool.
- **Separate worker deployment and separate queue.** Import workers scale on `imports` queue depth and cannot starve `indexing` or `notifications`.
- **Batched projection.** A completed import emits one `catalog.import.completed` event, and `indexer-worker` re-projects the affected products in batches of 200 rather than one event per row — otherwise a single import produces 20,000 cache invalidations and 20,000 upserts.
- **Staged, then promoted.** Rows land in `import_staging` and are validated against the category `facet_schemas` before any `product` row moves. A malformed file fails wholly at validation with a per-row `error_digest`, never half-applied.

## Bottleneck 4: Projection Lag Visible to the Vendor

Eventual consistency is invisible to a retailer and glaring to the vendor who just clicked publish and does not see the change. The design does not shrink the lag; it routes around it. **The vendor workspace reads the authoritative sources directly** — `product` from the Postgres primary and the metadata document from `mongo-catalog` — never `product_listing_facets` and never `redis-cache`. Vendors therefore have read-your-writes; retailers get the fast, cached, slightly-stale projection. The one place a vendor sees the projection is an explicit "preview as a retailer sees it" view, where the lag is the point.

## Failure Modes and Single Points of Failure

| Component | Failure impact | Mitigation | Residual risk |
|---|---|---|---|
| `postgres-core` primary | Total write outage; catalog browse survives on the replica and cache | Zone-redundant HA, automatic failover 60–120 s; app retries with exponential backoff; PgBouncer-style pooling so reconnect storms do not follow | 1–2 min of failed writes. Accepted at 99.5% write availability |
| `postgres-core` replica | Catalog reads fail over to the primary | `catalog-service` health-checks replica lag and falls back above 30 s | Elevated primary load during the window |
| `mongo-catalog` primary | Listing publishes and imports fail; browse and detail survive from `redis-cache` and secondaries | 3-member replica set, automatic election ~10–30 s | Vendor writes rejected briefly with a retryable 503 |
| `redis-cache` | **Not an outage.** Cache-aside means every read falls through to Postgres and Mongo | Rate limiting and idempotency degrade with it — both fail *closed* for writes and *open* for reads | Latency rises from ~35 ms to ~107 ms and Postgres load multiplies ~6×. Capacity is sized to survive this |
| `redis-broker` | In-flight Celery tasks at risk; queued work stalls | AOF persistence with `everysec`, `acks_late=True` and a visibility timeout so an unacknowledged task is redelivered rather than lost | See the note below |
| Azure Service Bus | Events queue at the outbox; nothing is lost | `outbox_event.published_at` stays null and the relay resumes; consumers are idempotent | Projection and notification lag for the outage's duration |
| APIM / Front Door | Total outage — a genuine SPOF | Both are Azure-managed, zone-redundant, and multi-instance | Accepted. A second edge is not proportional at this scale |
| Azure Functions | Notifications and thumbnails stall | Service Bus retains messages; dead-letter after 10 attempts with an Azure Monitor alert | Delayed email, no data loss |
| `indexer-worker` down | New listings never become searchable — a silent failure | `indexer_lag_seconds` alerts at 60 s; the reconciliation job in `03-data-modeling.md` re-projects any stale row | Bounded to the reconciliation interval |
| Whole region | Total outage | Geo-redundant backups; RTO 4 h, RPO 15 min from `01-requirements.md` | Deliberate. Active-active multi-region for a B2B sourcing tool at 35 QPS is cost the business would not choose |

> **Verify Before Build:** `acks_late` plus a visibility timeout is what makes Celery-on-Redis tolerable, but Redis is not a broker with real acknowledgement semantics — a worker killed mid-task relies on the visibility timeout expiring, and a `redis-broker` failover can still drop unacknowledged tasks. Confirm the behaviour on the pinned Celery and Redis versions with a kill-the-worker test before treating imports as durable. If they must be durable, the correct move is to run the `imports` queue on Azure Service Bus, which is already in the stack, and keep Redis only for `notifications` and `indexing`, whose work is fully rebuildable from the outbox.

## Trade-offs

| Trade-off | Choice | What it costs |
|---|---|---|
| **Consistency vs. latency** on catalog reads | Eventual; replica-served and Redis-cached | A listing edit is invisible to retailers for a few seconds. Bought back for vendors by the read-routing in Bottleneck 4 |
| **Two data stores vs. one** | Postgres + MongoDB | A projection pipeline, a lag SLI, and a reconciliation job that would not exist under a Postgres-only `JSONB` design. Bought: a genuinely open metadata surface where a new category is a document, not a migration |
| **Accuracy vs. cost** on result counts | `total_estimate` capped at 1,000 | The UI cannot show "1,247 results". It shows "1,000+" — which is what a sourcing workflow needs anyway |
| **Throughput vs. cost** on infrastructure | Single region, one replica, autoscale 3–8 nodes | A regional outage is a four-hour event, not a failover |
| **Isolation vs. operational complexity** | Six services, three worker pools, one repository | More deployments to observe than 35 QPS justifies; the boundary the brief asked for is enforced rather than documented |
| **Availability vs. duplicate suppression** on the one sync inter-service hop | Fail open on the `retailer-service` timeout | An occasional duplicate thread, caught by a unique constraint, in exchange for never blocking a connection request |
| **Vendor freedom vs. comparability** in metadata | Schema-validated free-form attributes | A vendor may omit an attribute, so the comparison matrix has null cells. Enforcing completeness would block listings; the matrix shows the gap instead, which is itself sourcing signal |
