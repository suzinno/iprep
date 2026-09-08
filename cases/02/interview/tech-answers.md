# Technical — Interview Answers

> Questions supplied by the client.
> Weighted toward the client brief in `candidate-profile.txt`.

## Questions by project

- **cancer-support-platform** — Q1, Q3, Q4.2, Q4.5, Q4.6, Q5, Q6, Q7, Q8.1, Q8.2, Q8.3, Q9, Q10, Q11, Q12, Q13
- **banking-software-marketplace** — Q1, Q3, Q4.2, Q4.3, Q4.4, Q4.5, Q4.6, Q6, Q8.1, Q8.2, Q8.3, Q9, Q10, Q11, Q12, Q13
- **general** — Q2, Q4.1

---

### Q1. Describe your experience with FastAPI and Asyncio in your recent project.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
[FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") is the runtime for every service in both systems — a modular monolith plus two extracted services on the health platform, six services plus three [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") worker deployments on the marketplace. The interesting part is not the async syntax; it is deciding which work belongs on the event loop at all, and which belongs off the request path entirely.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where FastAPI carries its weight.** [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models define every request and response body, and the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document FastAPI emits *is* the published contract — contract-tested in Continuous Integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Automatically builds and tests code on every change")) rather than written by hand. On the marketplace that same mechanism validates vendor-supplied metadata against a per-category facet schema, which is what keeps "no fixed column set" from degrading into "no contract". The dependency system is where the authorization checks live: on the marketplace, the account-type check on the token's `act` claim is a router-level dependency, so a retailer token cannot reach a vendor route regardless of its scopes.

**Async is a decision per path, not a default.** The rule I work to: `async def` when the handler awaits Input/Output (I/O), plain `def` when it does not, and never a blocking call inside an `async def` — one synchronous database driver call inside a coroutine stalls the whole event loop for every request that worker is serving. That means the async choice propagates: an async session implies an async driver (`asyncpg` rather than `psycopg2`), which implies async repositories, which implies async services. The trap on the way there is lazy loading — accessing a relationship attribute that would transparently fire a query raises rather than doing implicit I/O on the loop, so relationships get `selectinload`/`joinedload` or an explicit statement.

**The bigger lever is what never runs in the request at all.** Async concurrency helps a request that waits; it does nothing for a request that is doing 45 seconds of work. So on the health platform, education page generation is asynchronous by design and capped — the user never waits, and the pipeline can afford the reranking pass that makes the output specific. Check-ins are accepted onto the broker before the record write. Reminders are swept by a scheduled task. On the marketplace, a 20,000-row import is chunked onto a Celery queue with its own worker deployment, so a large import cannot exhaust web-tier capacity.

**On optimising a synchronous framework under heavy load** — the case I would expect to face on an enterprise workload — the moves that actually pay are, in order: get blocking work out of the worker process entirely (queue it), keep the connection pool sized so the sum of all pod maxima stays under the database's connection limit rather than letting each pod be generous, push anything that can be precomputed into a projection or a cache read, and only then add workers. Adding processes in front of a saturated database makes the problem arrive faster. Where a genuinely synchronous call cannot be removed, it belongs in a thread pool with a bounded size, not on the loop — and the bound is the point, because an unbounded offload just moves the queue somewhere you cannot see it.

</details>

---

### Q2. Describe your experience with Django, Django REST, and Flask in earlier projects.

**Project:** general

**Brief answer**
Both systems in this case are FastAPI, not Django or Flask, so I would rather be straight about that than claim otherwise. I know the frameworks and the differences that matter in practice, and the concepts transfer directly — but my recent production work is FastAPI with [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") and [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy").

<details>
<summary><strong>Detailed answer</strong></summary>

**What the three actually differ on.**

- **Django** is batteries-included: its own Object-Relational Mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")), migrations, admin, auth, forms and templates. You are productive immediately on conventional applications, and the admin alone can remove months of internal tooling. The cost is that there is a Django way, and architectures that do not fit its assumptions spend their time fighting it. It is synchronous at heart — async views arrived, but the ORM is still largely synchronous, so async work means `sync_to_async` wrappers or careful boundaries.
- **Django [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") Framework (DRF)** adds serializers, viewsets, routers, permission and throttling classes on top. Its strength is that a standard Create/Read/Update/Delete (CRUD) resource is genuinely a few lines; its weakness is that serializers become the place complexity hides, and a deeply nested serializer is where the N+1 query problem is usually born.
- **Flask** gives routing, request handling and templating, and nothing else — every other component is a choice you make. Maximum flexibility, maximum decision fatigue, and every Flask project looks structurally different, which is a real onboarding cost across a team.
- **FastAPI**, by contrast, is async-first, and its validation and documentation come from the same type-annotated Pydantic models, so the schema is executable rather than described.

**Where my experience maps.** Everything I do daily has a Django counterpart: SQLAlchemy sessions and `selectinload` map onto the ORM and `select_related`/`prefetch_related`; Alembic's expand/contract discipline maps onto Django migrations, with the same rule that a release must be able to run against both schemas; Pydantic request models map onto DRF serializers; FastAPI router dependencies map onto DRF permission classes. The one thing I would want to relearn deliberately rather than assume is Django's ORM query-generation behaviour under load — knowing that `prefetch_related` exists is not the same as knowing what it emits on a 100-million-row join, and I would rather read the generated Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database")) than trust my instinct from another toolchain.

**How I would approach picking one up on a live codebase.** Read the models and the migration history first, because that is where the real constraints are; then find where the query counts are, because in a Django application the performance conversation is almost always about the ORM rather than about the framework.

</details>

---

### Q3. Describe your experience with SQLAlchemy Core and building custom queries.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
I use the ORM for domain writes and drop to Core exactly where the generated plan matters — the catalog search on the marketplace and the patient timeline on the health platform. Both are queries where I need to see the SQL I am sending, because the index it must use is a design decision, not an implementation detail.

<details>
<summary><strong>Detailed answer</strong></summary>

**The split is deliberate.** ORM for writes and for anything whose shape follows the object model; Core for the two or three queries that carry the traffic, because there the question is not "does this return the right rows" but "does the planner choose `idx_plf_browse`". Wrapping that in ORM constructs adds a layer between me and the plan for no benefit.

**The catalog search on the marketplace** is the defining performance problem there: many optional predicates over `product_listing_facets` — free text, category, two or three array containments, a price ceiling, a deployment model. The failure mode is the planner producing a bitmap `OR` across several Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) indexes on an unselective combination and degrading toward a sequential scan. The query is written to avoid that rather than to survive it:

- **One relation, no joins.** `product_listing_facets` copies `vendor_id`, `status` and `published_at` from `product` deliberately, so the hot query touches exactly one table.
- **A partial index carrying the status predicate** — `idx_plf_browse` is defined `WHERE status = 'published'`, which keeps unpublished and archived rows out of the index entirely and removes the filter from every plan.
- **Keyset pagination**, `(published_at, product_id) < (cursor)`, never `OFFSET`. Page 40 of a comparison costs the same as page 1.
- **A product constraint that buys a performance guarantee:** the Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data")) refuses an uncategorised query carrying more than two facet predicates, which guarantees a viable leading index always exists.
- **`total_estimate`, not `total`**, capped at 1,000, because an exact count over a filtered GIN scan costs as much as the page itself.

And the honest part: the claim that the array and `jsonb_path_ops` indexes combine into a bitmap `AND` rather than degrading depends on the planner's selectivity estimates for high-cardinality arrays, which are poor. That gets confirmed with `EXPLAIN (ANALYZE, BUFFERS)` against a seeded table on the pinned server version before anyone quotes the latency figure — and if the plan is wrong, the fix is a composite covering index per high-traffic category, not a bigger instance.

**The timeline query on the health platform** is the most-executed clinician query and a union across five tables. It is a keyset-paginated `UNION ALL` over per-table windows with the `LIMIT` pushed into each branch, so [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") reads at most `limit` rows per source instead of materialising and sorting the whole union. The cursor is the tuple `(timeline_at, source_table, id)`. That is why every timeline-feeding table carries a normalised `timeline_at` column rather than each branch sorting on its own natural column — a union mixing a `date` and a `timestamptz` can neither be ordered deterministically nor served from one index shape.

**On very large tables**, which is where custom SQL earns its keep: `wellbeing_checkin` is around 110 million rows over five years and `audit_event` around 1.8 billion. Both are range-partitioned by month with Block Range Index ([BRIN](https://www.postgresql.org/docs/current/brin.html "Compact PostgreSQL index type suited to large, sequentially correlated tables")) indexes on the time column, so partition pruning removes almost all of the table from every query and archival is a partition detach rather than a `DELETE` of hundreds of gigabytes. The subtle part is that a row-level security policy that hides the partition key behind an opaque subquery silently converts a pruned index scan into a full sweep — so the plan shape is asserted in a test, not assumed.

</details>

---

### Q4. N+1 problem

#### Q4.1. What are the solutions to the N+1 problem in Django, such as select_related and prefetch_related?

**Project:** general

**Brief answer**
`select_related` follows forward single-valued relationships with a SQL `JOIN` in one query; `prefetch_related` handles multi-valued and reverse relationships with a second query and an in-Python join. The equivalents I use daily are SQLAlchemy's `joinedload` and `selectinload`, which split along the same line for the same reasons.

<details>
<summary><strong>Detailed answer</strong></summary>

**`select_related`** takes foreign-key and one-to-one relationships in the forward direction and pulls them into the same query as a join. One round trip, no extra objects, and the cost is row width — joining several one-to-many relationships this way multiplies rows and is where a "fix" makes things slower.

**`prefetch_related`** issues a second query per relationship with an `IN` over the collected keys, then stitches the results together in Python. It handles many-to-many and reverse foreign keys, which a join cannot do without duplicating parent rows. `Prefetch` objects let you constrain or order the inner queryset, which matters when the relationship is large and you only want a slice of it.

**Beyond those two**, the ones worth naming because they are the real answers on a large table:

- **`only` / `defer` / `values`** — the N+1 is sometimes not a relationship at all but a deferred column being touched in a loop.
- **Annotation instead of iteration** — `Count`, `Sum` and `Subquery`/`OuterRef` push aggregation into the database instead of counting related rows per object.
- **`iterator()` with a chunk size** on a large scan, so the result set does not materialise in memory.
- **Detection rather than inspection.** The reliable way to find these is to assert query counts in tests (`assertNumQueries`, or the equivalent hook in any toolkit) so a regression fails a build. Reading code for N+1 works until the day someone adds a property that touches a relationship.

**The SQLAlchemy mapping**, since that is my daily toolchain: `joinedload` is the `select_related` analogue, `selectinload` is the `prefetch_related` analogue and is the one I reach for by default because it issues a clean `IN` query without row multiplication, and `lazy="raise"` on relationships is the strongest tool of all — it turns an accidental lazy load into a loud error at development time rather than a silent extra query per row in production. Under async that is not even optional: implicit I/O on the event loop raises anyway, which is a rare case of the runtime enforcing the discipline for you.

</details>

#### Q4.2. Explain the N+1 problem in microservices or backend applications. Where it can appear, and how it can be solved?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
It is the same shape wherever it appears: one call fetches a list, then a per-item call fetches each item's detail. In a distributed system the per-item call is a network hop or a message rather than a query, so the cost is worse and the profiler does not show it in one place.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where it shows up beyond the ORM:**

- **Per-item store lookups.** The marketplace's catalog search returns roughly 30 summaries per page and then has to hydrate each from `mongo-catalog`. The naive version is 30 finds. The design forbids it: the pods issue an `MGET` against [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") for the cached listings and then a single bulk `$in` against [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") for the misses — never per item. That is the difference between about 25 ms of hydration and 30 sequential round trips.
- **Per-item service calls.** A list endpoint that enriches each row by calling another service is the distributed version. The marketplace's rule is that no synchronous call crosses more than one service boundary, and the one hop that exists is a single question with a 250 ms timeout, not a per-row lookup. Where a peer's data is needed on a hot path, it is denormalised instead: `connection_request.vendor_id` is copied from `product` precisely so the vendor's connection list needs no join and no call.
- **Per-item event handling.** This is the version that bites hardest and is easy to miss. A vendor import of 20,000 rows emitting one event per row would produce 20,000 cache invalidations and 20,000 projection upserts. The design emits **one** `catalog.import.completed` event and the indexer re-projects the affected products in batches of 200.
- **Per-item authorization.** A permission check that queries the database once per row is an N+1 that also happens to be a security-critical path. On the health platform the reach check is a single indexed lookup through `care_relationship` and the resulting scope is held for the request's duration rather than resolved per object.

**The solutions, in the order I reach for them:** batch the call (`IN`, `MGET`, bulk `$in`); precompute a read model so the join does not happen at read time at all (`product_listing_facets` is exactly that); denormalise the one or two fields that force a join; cache with a key that includes the revision so invalidation cannot be missed; and where the client controls the shape, give it one endpoint that returns what it needs instead of a list plus a detail call. What I do not do is fix it by adding concurrency — 30 parallel round trips still cost 30 round trips of load on the store, and under a burst that is the thing that falls over.

</details>

#### Q4.3. Explain how the N+1 problem can appear at the frontend or backend design level when the UI requests information through separate endpoints.

**Project:** banking-software-marketplace

**Brief answer**
It appears as a chatty screen: the client calls a list endpoint, then loops over the results calling a detail endpoint per row. The backend logs look healthy — every request is fast — and the page is still slow, because the cost is in the count of requests, not in any one of them.

<details>
<summary><strong>Detailed answer</strong></summary>

**A concrete case from the marketplace.** The admin console is a static single-page application served from blob storage, and it deliberately calls the same public versioned APIs rather than a private backend-for-frontend. The design states the cost of that plainly: a chattier user interface on entity screens that join across services. That is an accepted, named trade-off — the benefit is that no admin capability exists which the public contract does not already describe and test — but it is exactly the shape that becomes an N+1 if a screen is built naively. An admin view listing vendors and showing each one's open connection count is one list call plus one call per vendor unless someone designs it otherwise.

**The comparison view is the other one.** Comparing up to five products means five listing details plus their category facet schemas. Left to the client, that is a request per product plus a request per schema. The design gives it a single endpoint — `POST /v1/catalog/compare` taking two to five product identifiers and returning a comparison matrix that is the union of the categories' facet schemas, with null cells where a vendor supplied nothing. One request, and the nulls are themselves sourcing signal rather than an error.

**How I prevent it at design time rather than fixing it later:**

- **Design endpoints around screens, not around tables.** If a view always needs a list plus one field from each related entity, that field belongs in the list response. The list response for the catalog is a `ProductSummary` for exactly this reason.
- **Give the client an explicit batch verb** when a genuine many-to-one fetch is needed, as the compare endpoint does.
- **Make the pattern visible in review.** A response shape that forces a loop on the client is a backend design defect, and it is easier to argue about while the contract is still a Pydantic model.
- **Watch requests-per-page-view**, not just request latency. The observability that catches this is a count, and the server-side p95 will look perfect throughout.

The general failure mode is that the API is designed as a projection of the data model, and the frontend then reassembles the screen from pieces. The fix is not more caching; it is agreeing what one screen needs and returning it.

</details>

#### Q4.4. What could be a good solution for reducing that problem if REST is not being used?

**Project:** banking-software-marketplace

**Brief answer**
GraphQL is the obvious answer — the client declares the shape it wants and gets one round trip — but it moves the N+1 into the resolver, so it only helps if you also add batching. gRPC helps with hop cost, not with hop count. A backend-for-frontend is often the smaller, more honest fix.

<details>
<summary><strong>Detailed answer</strong></summary>

**GraphQL**, honestly assessed. It genuinely removes the client-side N+1: one query, one response, exactly the fields the screen needs, and no over-fetch. What it does not remove is the server-side one — a nested resolver that runs per parent object is the same problem one layer down, which is why dataloader-style batching (collect the keys requested during a tick, issue one batched fetch) is not an optional extra but the thing that makes GraphQL viable at all. The costs are real: query cost analysis and depth limiting become a security requirement, since an arbitrarily nested query is a denial-of-service primitive; caching is harder because responses are no longer addressable by Uniform Resource Locator ([URL](https://datatracker.ietf.org/doc/html/rfc3986 "Addresses the location and access method of a resource on the web")); and per-field authorization is more work than per-route authorization. On a system where authorization is the whole threat model, that last point is not small.

**gRPC** reduces the *cost* of a hop — binary framing, multiplexed streams, generated clients — but not the *number* of them. It is the right answer for chatty internal traffic at volume; it is not an answer to a screen making 30 calls. The marketplace rejected it internally for a stated reason: nine deployments at that traffic level gain nothing from binary framing, and Representational State Transfer (REST) keeps one contract style and one test approach across internal and external surfaces. Where it does shine is streaming — a long-running import's progress is a better fit for a server stream than for polling.

**Batch endpoints and a backend-for-frontend.** Usually the cheapest fix. A single endpoint that takes a list of identifiers and returns the objects, or a thin service that composes one screen's data from several sources, gets you most of GraphQL's benefit without a new contract language, a new authorization model and a new caching story.

**Server-driven composition** is the fourth option: server-sent events or a websocket pushing updates instead of the client polling per item, and server-rendered fragments where the page is mostly read-only. On the marketplace the equivalent choice is the projection table — the composition happens once, asynchronously, in `indexer-worker`, and the read path fetches one prepared row. That is the pattern I reach for first, because the cheapest join is the one that already happened.

</details>

#### Q4.5. Could the N+1 problem be handled on the database side, for example by creating a view that joins tables so data is always accessible?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Yes, and it is often the right instinct — but a plain view is a stored query, not stored data, so it changes what you type and not what the database does. What actually helps is a materialised view or a maintained projection table, and then you have bought a refresh problem in exchange for the join.

<details>
<summary><strong>Detailed answer</strong></summary>

**What a plain view does and does not do.** A view is macro expansion: the planner inlines it and plans the underlying query. That genuinely fixes an *application-side* N+1 — one statement instead of a loop — and it centralises a join that would otherwise be copied into several places. What it does not do is make the join cheaper. It also has a real failure mode on complex definitions: predicates from the outer query do not always push down through aggregates, `DISTINCT` or window functions, so a view that is fast when you select all of it can be dramatically slow when you filter it, and you find out at the worst moment.

**A materialised view** stores the result and is a genuine read-model. Now the join cost is paid at refresh time, and you inherit the refresh question: `REFRESH MATERIALIZED VIEW CONCURRENTLY` needs a unique index and still rewrites the whole thing, which is fine for a small aggregate and not fine for a wide table refreshed often. Staleness becomes a property you must state.

**What both systems actually do.** On the marketplace, `product_listing_facets` is precisely the "join it once, keep it ready" idea, implemented as a table rather than a materialised view. It is written only by `indexer-worker` and read only by `catalog-service`; it carries a `search_vector`, the facet `jsonb`, the arrays, and the columns copied from `product` so the search query touches one relation. The reason it is a table and not a materialised view is that refreshes are **incremental and event-driven** — one product re-projected on a `catalog.listing.published` event — where a materialised view refresh is all-or-nothing. It is upserted keyed on `product_id`, ignores an event whose source revision is older than the current one, so redelivery is a no-op and out-of-order delivery cannot roll a listing backwards.

On the health platform the same problem is solved without a view at all: the timeline is a keyset-paginated `UNION ALL` across five tables with the limit pushed into each branch, served by a composite index per table. A view over that union would have been the natural-looking answer and would have made the keyset cursor harder to express, not easier.

</details>

#### Q4.6. How much does using a database view cost, and did you try solving something like that with a view? What did you conclude in the end?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
A plain view costs nothing at runtime and buys nothing at runtime. A materialised view costs storage plus a refresh you have to schedule and monitor. I concluded on both systems that an event-maintained projection table beats both, and that a union query with the right indexes beats all three where the sources are heterogeneous.

<details>
<summary><strong>Detailed answer</strong></summary>

**The costs, itemised.**

- **Plain view:** no storage, no refresh, no maintenance window. The cost is entirely in what it hides — a plan you no longer look at, and predicate push-down that can fail silently on aggregates or window functions. It is documentation with a `SELECT` attached, which is genuinely useful for consistency and useless for performance.
- **Materialised view:** storage for the result, plus write amplification at refresh, plus a lock consideration (`CONCURRENTLY` avoids blocking readers but needs a unique index and does more work), plus the operational question of what refreshes it and what alerts when that stops. On a large base table the refresh cost is the real number, and it is paid whether or not anything changed.
- **Projection table:** the same storage cost, plus code you own — but the refresh becomes incremental and event-driven, and staleness becomes a metric instead of a schedule.

**What we concluded on the marketplace.** The search read-model went to a projection table for three reasons. The refresh is per-product rather than whole-table, which matters because a bulk import touches thousands of rows and a full refresh per import would be absurd. The lag becomes measurable — `indexer_lag_seconds` from the event's occurrence to `projected_at`, budgeted at p95 under 5 seconds — with an alert at 60 seconds, because a dead indexer is a *silent* failure where new listings simply never become searchable. And a projection can carry columns a view cannot compute cheaply, like a maintained `tsvector`. The `search_vector` is deliberately **not** maintained by a database trigger, because a trigger would run inside the vendor's publish transaction and couple write latency to text-search maintenance for a value only the read path needs.

The price is honest and worth stating: a projection needs a reconciliation job. A nightly sweep re-projects any product whose `projected_at` predates its `updated_at` by more than five minutes, which is the backstop for a lost event — a materialised view would not need that, because it recomputes from truth every time.

**What we concluded on the health platform.** No view. The timeline spans five tables with different natural ordering columns, so the enabling change was normalising a `timeline_at` column across all five and indexing `(patient_id, timeline_at DESC)` on each — after which the union query is fast and the keyset cursor `(timeline_at, source_table, id)` breaks ties deterministically across sources. A view would have wrapped the complexity without removing it.

**The rule I took away:** use a view for consistency of expression, a materialised view when the result is small and the refresh is cheap and whole-table, and a maintained projection when the read model is hot, the updates are incremental, and you are prepared to own the lag metric and the reconciliation job that go with it.

</details>

---

### Q5. How did you handle sending JSON over MQTT? How to manage legacy units that only support raw UDP protocols?

**Project:** cancer-support-platform

**Brief answer**
Check-ins are published as JavaScript Object Notation ([JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange")) envelopes over Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")) with Quality of Service ([QoS](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html "Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes")) 1 to `care/checkin/{patient_id}`, bridged by [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers")'s MQTT plugin into the same Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications")) exchange everything else consumes. I have not worked with raw User Datagram Protocol (UDP) devices, so I would answer that half from the pattern rather than from experience.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why MQTT at all.** The client is a phone on a lossy connection. QoS 1 with client-side offline queueing is the whole point: the handset holds the check-in through a tunnel or a dead spot and delivers it on reconnect. That is also why the broker is RabbitMQ rather than a cloud queue service — the MQTT plugin bridges MQTT topics into the same `care.events` exchange the rest of the platform consumes, so there is no separate ingress path to keep consistent.

**The payload and the three settings that carry the durability claim.** The message is a JSON envelope — the check-in fields plus a correlation identifier and the trace context — validated by a Pydantic model on the consumer side, because a device is untrusted input regardless of transport. Three broker settings are non-default and each one matters:

- `mqtt.exchange` must point at `care.events`, or the plugin publishes to the default topic exchange instead and nothing consumes it.
- MQTT's `/` separator is translated to AMQP's `.`, so `care/checkin/{patient_id}` binds as `care.checkin.{patient_id}` — the binding pattern has to be written for the translated form.
- `care.events` needs an **alternate exchange**, because RabbitMQ returns a publish acknowledgement for a QoS 1 message that routes to no queue. Without one, an unbound topic is acknowledged to the device and silently dropped — the exact loss the path exists to prevent. The alternate exchange turns it into a visible dead-letter.

**Delivery is at-least-once, so the write is idempotent.** The projection is an `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE`. Redelivery is arithmetic, not a bug, and no application-side deduplication is needed.

**Two honest wrinkles.** RabbitMQ authenticates an MQTT *connection*, not each publish, so a long-lived mobile connection must be re-validated against token expiry out of band — connections carry a maximum lifetime shorter than the refresh window and are forced to reconnect. And MQTT 3.1.1 has no user-property header, so trace context cannot ride in the headers: either move clients to MQTT 5 or carry `traceparent` inside the payload envelope, decided before instrumenting because retrofitting it breaks every published client.

**On legacy units that speak only raw UDP.** I have not built this, so what follows is how I would approach it rather than something I have run. UDP gives you no ordering, no delivery guarantee, no session and no built-in security, so the answer is a protocol adapter at the edge that terminates UDP and converts to the internal transport as early as possible — a small, stateless gateway whose only job is parse, validate, authenticate and publish. The specifics I would insist on: a binary parser with an explicit length and version field and a strict maximum datagram size, since a malformed packet must be droppable without affecting the next one; a device identifier plus a monotonic sequence number in every datagram so the gateway can detect gaps and duplicates that the transport will not; a shared-secret or certificate-based message authentication code, because a plain UDP listener is trivially spoofable and amplifiable; publisher confirms on the internal side, so the gateway only treats a datagram as handled once the broker has it; and if the device supports it at all, an application-level acknowledgement so the unit can retransmit — without that, "no loss" is not achievable and the honest design records the gap rate as a metric instead of pretending otherwise.

</details>

---

### Q6. Describe the general data flow in the project, from MQTT brokers or queues through decoding and storage.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Both systems follow the same principle from different ends: a fact is written to its owning store in one transaction, and everything downstream is driven from that write rather than from a second call. On the health platform the ingress is MQTT; on the marketplace it is a user action. In both, the fan-out is an outbox.

<details>
<summary><strong>Detailed answer</strong></summary>

**Cancer platform — check-in ingest, end to end.**

1. The patient app publishes to `care/checkin/{patient_id}` at QoS 1 over Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")). RabbitMQ returns the publish acknowledgement once the message is durable on a quorum queue — from that instant the recovery point objective is zero, and the app shows "recorded".
2. The MQTT plugin routes it into the `care.events` topic exchange as `care.checkin.{patient_id}`.
3. A Celery worker on `celery.index` consumes it, validates the envelope against a Pydantic model, and writes to PostgreSQL with `INSERT ... ON CONFLICT (patient_id, recorded_for) DO UPDATE`.
4. That same transaction writes an `outbox_event` row. The relay publishes it to `care.events`, and only then marks it published.
5. The index consumer bulk-indexes into Elasticsearch. `care-core` never writes the search index directly — that is what makes dual-write drift impossible.

The composed freshness budget is stated as a sum rather than asserted: outbox relay under 2 seconds, plus a bulk flush of 5 seconds or 1,000 documents, plus a 5-second refresh interval, gives a newly-saved note searchable at p50 under 8 seconds and p95 under 15. Tightening any one of the three alone buys nothing.

The reminder path runs on the same principles from the other direction: Celery beat ticks every 60 seconds, claims due rows with `FOR UPDATE SKIP LOCKED` so workers scale without double-dispatch, writes a `reminder_delivery` row per attempt, hands the command to Azure Service Bus, and an Azure Function delivers and returns a receipt that closes the row. Every attempt being a row is what makes "was it delivered" a query instead of a log grep.

**Marketplace — listing publish, end to end.**

1. `vendor-service` writes the immutable revision document to MongoDB **first**.
2. Then, in one PostgreSQL transaction: update `product.current_revision_id`, insert `outbox_event`, commit. The order is deliberate — an orphaned revision nobody points at is invisible and reclaimable, whereas a committed pointer to a missing document is a broken listing.
3. The relay publishes `catalog.listing.published` to the Service Bus topic and stamps `published_at`.
4. `indexer-worker` reads the current revision, upserts `product_listing_facets` with its `search_vector`, and deletes the affected cache keys.
5. `notification-worker` decides *whether and what* to notify; a Function performs delivery. One owner per step.

**The rule underneath both.** A fact has exactly one owning store, and the derived stores — the search index, the projection, every cache — are rebuildable from it. That is what makes the recovery procedures honest: the Elasticsearch index is fully rebuildable from PostgreSQL plus MongoDB, and rehearsing that rebuild is part of the quarterly restore drill rather than something discovered during an incident.

</details>

---

### Q7. How did you ensure data was not lost during spikes, especially when using RabbitMQ as buffer?

**Project:** cancer-support-platform

**Brief answer**
By making durability a property of the acknowledgement rather than of the consumer keeping up: quorum queues with publisher confirms, an alternate exchange so an unroutable message cannot be acknowledged into nothing, late acknowledgement on consumers, and a natural key in the database so redelivery is harmless. The backlog is then allowed to grow — visibly.

<details>
<summary><strong>Detailed answer</strong></summary>

**The spike is designed for, not absorbed by luck.** The check-in burst is concentrated: roughly 25,000 check-ins with most between 07:00 and 09:00, about 50 messages a second at peak, against an API peak of around 200 queries per second sustained and 400 in burst. The whole reason check-ins go onto the broker before the record write is that the write path does not have to be sized for the morning burst — the queue is the buffer, and the consumer drains at its own rate.

**The mechanisms, in the order they matter:**

- **Quorum queues** for `care.events` and every Celery queue, with **publisher confirms mandatory**. Nothing is acknowledged that is not replicated. RabbitMQ 4 removed classic mirrored queues, so this is also the only supported answer.
- **An alternate exchange on the topic exchange.** This is the subtle one: a QoS 1 publish that routes to no queue still gets acknowledged, so an unbound topic would be confirmed to the device and dropped. The alternate exchange converts that into a visible dead-letter.
- **Late acknowledgement and idempotent handlers** on consumers, with bounded retries and then a dead-letter queue. A worker that crashes mid-task causes redelivery, not loss.
- **The database, not the cache, provides idempotency.** `(patient_id, recorded_for)` is unique, so redelivery is an upsert. Redis idempotency keys are an optimisation; losing them to a flush permits a duplicate request to be reprocessed, and the natural key is what makes that safe.
- **The transactional outbox** for everything the platform publishes, so a commit followed by a broker failure leaves an unpublished row that drains on recovery rather than a fact that never left.

**Memory pressure is the failure mode I would watch most closely**, because a broker that runs out of memory takes production with it, and the classic cause is a queue growing without bound while nobody looks. The controls are: a consumer prefetch limit so a worker cannot pull an unbounded window into memory; lazy/quorum queue behaviour that pages messages to disk instead of holding the backlog in RAM; message time-to-live and dead-lettering so an unconsumed queue drains somewhere rather than growing forever; and the broker's own memory and disk high-watermark flow control, which blocks publishers rather than dying — which is the correct failure, and one your publishers must be written to tolerate. Then the alerting: `rmq_queue_depth` and unacknowledged counts alert on depth over 10,000 or on a rising trend over 15 minutes, and `outbox_unpublished_age_seconds` alerts at 30 seconds. A backlog is acceptable; an invisible backlog is not.

**Also worth being honest about**, since it is a live open item: Celery's support for quorum queues is recent and interacts with late acknowledgement, global prefetch and priorities, so the Celery and broker versions are pinned and tested together before the reminder path depends on them — with raw AMQP consumers as the fallback, which the topic-exchange design already accommodates.

</details>

---

### Q8.1. Describe your experience with Azure and on-premises infrastructure in your recent projects.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Both systems run on Azure and both are provisioned entirely with [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files"). The health platform is the closest to an on-premises operating model I have worked on — Azure Red Hat OpenShift with a self-managed MongoDB replica set, Elasticsearch and RabbitMQ running in the cluster — but I would not call either a datacentre deployment.

<details>
<summary><strong>Detailed answer</strong></summary>

**Cancer platform.** Two clusters, and the split is the most expensive decision in that design, so it is stated with the condition that would reverse it. `aro-primary`, an Azure Red Hat OpenShift cluster, hosts `care-core`, `scim-provisioning-svc`, the Celery workers, and the stateful components run in-cluster: RabbitMQ, MongoDB, Elasticsearch. `aks-ml` is a small Azure Kubernetes Service ([AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure")) cluster with a graphics-processing-unit node pool hosting only `clinical-nlp-svc`, which holds no state precisely so it can be collapsed back into the primary if inference ever moves to a managed endpoint. Around them, the managed Azure services: PostgreSQL Flexible Server, Cache for Redis, Blob Storage, Service Bus, Event Grid, Functions, API Management, Front Door with a web application firewall, Key Vault.

Running your own broker, search cluster and document store in a cluster is where the work resembles on-premises operations: you own version upgrades, replica-set membership, shard and replica counts, persistent-volume sizing, and the restore procedure. The specific discipline that came from that is treating a rebuild as a routine operation — the Elasticsearch index is fully rebuildable from PostgreSQL and MongoDB, and that rebuild is rehearsed quarterly with a document-count reconciliation, because a mitigation nobody has executed is an assumption.

**Marketplace.** Single AKS cluster, one namespace, nine deployments, with the managed services around it: PostgreSQL Flexible Server plus a read replica, two Redis instances (cache and Celery broker, deliberately separate), a MongoDB replica set, Blob Storage, Service Bus, Functions, API Management, Front Door, Key Vault. Single region, zone-redundant, geo-redundant backups — active-active multi-region for a business-to-business sourcing tool at 35 queries per second is cost the business would not choose, and that is written down as a choice rather than left as an omission.

**Where "on-premises" honestly applies.** Administering Linux hosts for production and development was part of the marketplace work, and the container base images and node pools are Linux throughout. What I have not done recently is run a datacentre — no bare-metal provisioning, no physical networking, no storage-array work. What transfers is the operating mindset: no store has a public endpoint, everything is reached over private endpoints from the application network, and every resource that exists is in Terraform, so anything created by hand shows up as drift and fails the pipeline rather than surviving as tribal knowledge.

</details>

---

### Q8.2. Describe your experience with Azure Service Bus, and AKS.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Service Bus is the integration edge in both systems — the boundary where work leaves for Functions and third-party delivery — and it is deliberately not the internal work queue. AKS runs the marketplace's nine deployments with autoscaling on both processor use and queue depth, and hosts the health platform's inference node pool.

<details>
<summary><strong>Detailed answer</strong></summary>

**Service Bus, and the rule for when to use it.** On the marketplace there are three: `sb-catalog-events` and `sb-connection-events` as topics with competing-consumer subscriptions, and `sb-notification-dispatch` as a queue feeding a Function. On the health platform there are two queues, `sb.ingest` and `sb.notify`. The rule that keeps the estate coherent is one sentence: **Celery moves work between Python processes we own; Service Bus moves events across a boundary** — to Functions, to another service, to any future consumer. Collapsing them either way puts one system in a role it is bad at, and the operational cost of two broker technologies is accepted with that justification written down.

What I use it for specifically: durable dead-lettering at the boundary where the platform hands work to a third-party delivery provider, native Function triggering without an adapter, and at-least-once delivery paired with idempotent consumers keyed on the event identifier. Every event is emitted through the transactional outbox, so publishing is at-least-once and never zero-times: if Service Bus is unavailable, events simply queue at the outbox with `published_at` still null and the relay resumes.

The operational details worth knowing: dead-letter after a bounded attempt count with an alert on any dead-letter depth above zero, because a message in a dead-letter queue is not an error rate, it is a stuck fact; trace context propagated in message properties, though that is a claim to assert in an integration test rather than assume, since the instrumentation for context propagation has historically been partly manual.

**AKS.** On the marketplace, one cluster and one namespace running six services and three worker deployments. What I actually operated:

- **Autoscaling on the right signal.** Horizontal Pod Autoscaler on processor use at a 65% target for the six services, and on Celery queue depth via a custom metric adapter for the three worker pools — so a large import scales the importers without touching the web tier. Cluster autoscaler between three and eight nodes.
- **Graceful shutdown that actually works.** Workers are drained, not killed: a `preStop` hook stops queue consumption and waits for the in-flight task, bounded by a 120-second termination grace period, and import chunks are sized to finish well inside it.
- **Deployment strategy by risk.** Canary for `catalog-service`, which takes the traffic and carries the risky query plans — roughly 10% of traffic through ingress weighting, held 15 minutes against error rate and p95 before the weight advances — and rolling updates with readiness and liveness probes elsewhere. Blue/green was rejected for a stated reason: it doubles the pod footprint and, because both colours share one database, delivers no database-level isolation, which is the only part of the risk that expand/contract does not already cover.
- **Identity without secrets.** Workload identity federates a [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") service account to an Azure managed identity per service, so there are no connection strings and no static credentials in the cluster.

On the health platform, `aks-ml` is a deliberately minimal cluster: a graphics-processing-unit node pool hosting one stateless service, with a canary rollout because model quality shows up statistically rather than as an error.

</details>

---

### Q8.3. Describe your experience with Azure services such as Azure Functions, Blob Storage, and API Management.

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Functions for bursty, event-shaped work at the edges — document ingestion, media processing, notification delivery. Blob Storage as the only place bytes live, with direct signed uploads so large files never touch the API pods. API Management as the gateway that rejects a wrong-audience token before it reaches application code.

<details>
<summary><strong>Detailed answer</strong></summary>

**Azure Functions.** Four across the two systems, and each exists because the work is bursty and short: paying for idle pods to wait for an upload is the wrong shape. On the health platform, `fn-blob-ingest` is Event Grid–triggered on `BlobCreated` and validates, virus-scans and text-extracts an uploaded document; `fn-notify-dispatch` is Service Bus–triggered and delivers push, email or short message service, then records a receipt. On the marketplace, `fn-media-process` is blob-triggered and generates thumbnails and document previews — re-encoding images is also a security control, since a vendor-supplied file is untrusted; `fn-notify-dispatch` again performs delivery while the Python worker owns the policy decision of whether and what to notify.

**Blob Storage, and the upload pattern that matters.** Patients upload documents by requesting an upload intent, which returns a short-lived shared access signature; the client writes the bytes directly to storage. Proxying multi-megabyte scans through the API would put them on the same pods serving a clinician's timeline. The metadata row stays transactional, and the two are tied together by state: uploads land in an `ingest-quarantine` container and are promoted only after a clean scan, so an unscanned file is never addressable by a document row.

The layout is governed rather than ad hoc — containers with path conventions and lifecycle rules (hot 90 days, cool at one year, then archive), an `audit-archive` container under a write-once-read-many policy with a seven-year legal hold, and on the marketplace, content-addressed paths (`listings/{product_id}/{revision}/…`) so a new revision is a new URL and the content delivery network never needs purging. Vendor-supplied files are served with `Content-Disposition: attachment` from a dedicated download hostname, so no untrusted file is ever served from the origin hosting the admin console.

**API Management.** The north-south gateway: routing, versioning, per-subscription quotas, per-address burst limits, and JSON Web Token ([JWT](https://datatracker.ietf.org/doc/html/rfc7519 "Compact, signed token format for carrying claims between parties")) pre-validation. On the health platform its most important job is audience separation — the patient plane and the clinician plane are different token audiences, so a clinician token presented on a patient route is rejected at the gateway with a 403 before any application code runs. Two disciplines around it:

- **The edge is a filter, never the authority.** Each service re-validates the token locally against a cached key set, so a bypass of the gateway is not a bypass of authentication. Neither check makes a network call per request, which is the assumption the entire latency budget rests on — an introspection round trip would add 15–30 ms to every request.
- **Response caching is off on every data path, by policy rather than by omission.** A gateway cache keyed on a URL that omits the subject is a cross-tenant disclosure waiting to happen.

One genuine trap worth naming: the gateway caches the signing key set on its own schedule, independently of the application's cache, so during a key rotation the two can disagree and tokens signed with the new key can be rejected at the edge while services accept them. The fix is to make the key-overlap window strictly longer than the gateway's refresh interval — and to confirm that interval on the actual tier before the first rotation, not after.

</details>

---

### Q9. What was your experience handling traffic spikes in Kubernetes?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Scale on the signal that reflects the work, not just on processor use; get the burst off the request path onto a queue where it can wait; and make sure the thing behind the pods can survive the number of pods you are about to start. Autoscaling into a saturated database is how a spike becomes an outage.

<details>
<summary><strong>Detailed answer</strong></summary>

**Scale on the right signal.** On the marketplace the six services autoscale on processor use at a 65% target, but the three worker pools autoscale on `celery_queue_depth` through a custom metric adapter. That distinction is the whole point: a worker pool blocked on Input/Output shows low processor use while the queue grows, so a processor-based autoscaler would sit still through exactly the event it exists for. Queue depth is also the alert threshold — `imports` under 500, other queues under 100 — so the same number drives both the scaling and the paging.

**Get the spike off the synchronous path.** The health platform's morning check-in burst is roughly 50 messages a second concentrated between 07:00 and 09:00, and none of it touches the API: it lands on the broker, is acknowledged durably, and drains at the consumers' pace. On the marketplace a 20,000-row import is chunked onto its own queue with a per-vendor concurrency cap of four held as a Redis semaphore, so one vendor cannot occupy the pool, and the importers scale on their own queue without touching the web tier. The general form is that the thing that spikes should be allowed to wait somewhere durable and visible.

**Protect the shared resources the pods depend on.**

- **Connection pools.** Sized so the sum of every pod's maximum stays below the database's connection limit. This is the constraint people discover during a spike: the autoscaler happily starts pods that then exhaust the database's connections, and the failure looks like a database problem. Async handlers help here — a small pool per pod is genuinely sufficient when the handlers are non-blocking.
- **Cache stampede.** The moment a popular listing's key expires under concentrated traffic, every concurrent request misses together. Two mechanisms bound it: single-flight per key (`SET NX EX`, losers poll briefly then serve the stale value) and probabilistic early expiry, where a reader recomputes early with a probability rising as the time-to-live approaches, so recomputation spreads over a window instead of landing on one instant. Together they cap database load at roughly one recomputation per interval regardless of concurrency.
- **Layered rate limiting.** Coarse per-subscription and per-address limits at the gateway, and a fine-grained per-subject token bucket in the application. Limits are per authenticated subject, not per address alone — a hospital behind one address must not rate-limit itself.

**Survive the pods you are replacing, too.** Readiness probes so traffic does not reach a pod that is still warming, a `preStop` drain bounded by the termination grace period so in-flight work finishes, and a rollout strategy chosen by risk rather than by habit. And I would rather know the degraded behaviour in advance: if the cache is gone entirely, every read falls through and latency roughly triples while database load multiplies about sixfold — capacity is sized so that is survivable, which is a different statement from hoping it does not happen.

</details>

---

### Q10. How did you use Terraform to support the architecture and deployment infrastructure?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Terraform owns every Azure resource in both systems, with state in a locked blob container and applies only from CI. Environments are the same module set with different variable files, and anything created by hand is drift — reported as a failure, not reconciled quietly.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is actually in it.** On the marketplace: AKS and its node pools, PostgreSQL Flexible Server and its read replica, both Redis instances, the MongoDB deployment, blob containers and their lifecycle rules, the Service Bus namespace with its topics, subscriptions and dead-letter settings, the Function Apps, API Management, Front Door with the web application firewall, Key Vault — and every Azure Monitor alert rule. On the health platform, the same shape across both clusters plus Event Grid and the identity configuration.

**Alert rules in Terraform is the one people skip, and it is the one that matters most.** An alert silenced by hand during an incident and never restored is the standard way monitoring rots. Putting the rules in code means a silenced alert is a reviewable diff, not something discovered six months later when the thing it watched failed quietly.

**How it runs.**

- **State** lives in a dedicated container with versioning and lease locking, so two concurrent applies cannot corrupt it.
- **Applies run only from CI on the default branch**, authenticated by workload identity federation rather than a stored service-principal secret, and production carries a plan-review gate.
- **Environments are workspaces over one module set**, differing only in a variables file. That is what makes a staging smoke test meaningful — staging is the same topology at smaller instance sizes, not a different architecture.
- **Drift is a failure.** A resource created in the portal shows up in the plan and fails the pipeline. Reconciling it silently would mean the code stops describing reality, which is the moment infrastructure-as-code becomes decorative.
- **Role assignments are Terraform resources**, so a widened permission appears as a reviewable diff rather than as a click nobody sees.

**The concentration of privilege, stated honestly.** The CI deploy identity is the single largest concentration of privilege in either design — it can apply across the whole subscription. The right shape is to split it: a plan-only identity for merge requests and an apply identity gated on protected-branch pipelines, with the network and data-plane modules in their own state under their own identity. That is a design decision worth taking before the first production apply rather than after an incident, and it is written down as an open item rather than left implicit. A human needing production data access goes through a time-bound privileged-access elevation that writes an audit record — the deploy identity itself holds no standing data-plane rights.

</details>

---

### Q11. What is your experience with GitLab CI, ArgoCD, and Terraform for CI/CD and provisioning?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
GitLab CI builds and gates on both systems. On the health platform it does not deploy — its final act is a commit to a manifest repository that Argo [CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") reconciles onto the clusters, so no pipeline job ever holds cluster credentials. Terraform provisions everything underneath, applied only from CI.

<details>
<summary><strong>Detailed answer</strong></summary>

**The pipeline, and the property that every gate can actually fail.** Lint (`ruff`), strict type checking (`pyright --strict` or `mypy`), unit and contract tests, integration tests against real PostgreSQL, MongoDB, Elasticsearch, Redis and RabbitMQ containers via Docker Compose, a SonarQube quality gate, image build with a vulnerability scan, and on the marketplace a functional stage testing the running service against its OpenAPI document. A gate that cannot fail is a comment, so the question I ask of any pipeline is whether I have seen each stage go red for a real reason.

**Argo CD and the credential boundary.** On the health platform, GitLab CI's last step is committing a digest-pinned image reference to the GitOps manifest repository. Argo CD reconciles that onto `aro-primary` and `aks-ml`. Two consequences I value: the pipeline holds no cluster credentials at all, and the cluster's desired state is a commit — so a rollback is a revision revert rather than a re-run of a deploy job, and drift between what is declared and what is running is visible rather than inferred.

Migrations run as an Argo CD PreSync hook (`alembic upgrade head`), and deployment strategy differs by service for a reason in each case: `care-core` is blue-green, a single instantaneous route switch and the cleanest rollback for the service holding the clinical record; `clinical-nlp-svc` is a canary at 5%, 25% then 100%, because model quality shows up statistically and a percentage rollout with confidence and latency comparison is the only way to see a regression before everyone gets it; `scim-provisioning-svc` is a rolling update, since its caller is external and its operations are idempotent. Functions deploy by slot swap. A post-sync hook runs a smoke test and an objective check.

**The rule that makes any of this rollback-safe: expand/contract, always.** `alembic upgrade head` only ever adds nullable columns, new tables and new indexes (built `CONCURRENTLY`), so the previous image keeps running against the new schema throughout the rollout. Dropping a column is a separate merge request landed at least one release later. That is what makes rollback possible at all — the old image must be able to run against the new schema — and on a table with hundreds of millions of rows it is also what keeps a migration from being an outage. A migration that cannot be written this way gets split across two releases rather than argued about.

**Terraform** provisions everything underneath both systems, as described above: state in a locked blob container, applies only from CI, workspaces per environment over one module set, drift reported as a failure.

**Where the marketplace differs:** no Argo CD — GitLab CI deploys directly, canary for the highest-traffic service and rolling elsewhere, with rollback as a redeploy of the previous image digest, safe by construction because the schema is compatible in both directions during the window. Both approaches work; the GitOps one is stricter about credentials and gives a better audit trail of what was running when, which is why the regulated system has it.

</details>

---

### Q12. What is your experience with Docker and Podman for containerization?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
Docker and Docker Compose on both systems — for image builds, for the local stack running the real brokers and search engine, and for the CI integration tests that run against that same stack. Podman I know rather than have run in production, so I would say so.

<details>
<summary><strong>Detailed answer</strong></summary>

**What Compose is actually for here, and why it is not a convenience.** The local stack brings up the real components — PostgreSQL, MongoDB, Elasticsearch, Redis and RabbitMQ on the health platform; PostgreSQL, MongoDB and Redis on the marketplace — and the CI integration stage runs against that same stack at the same pinned versions. Developers run the real brokers and the real search engine, not fakes, because the two things a mocked test would pass while broken are precisely the projection pipeline and the index query plans. A mocked broker also cannot fail the way a real one does, which is the failure mode you most want a test for.

**Image discipline.** Linux base images, dependencies pinned by hash and images pinned by digest, vulnerability scanning as a blocking pipeline gate, base images rebuilt weekly, and deployment only of digest-pinned images — a mutable tag cannot be swapped underneath a running cluster. Multi-stage builds so the runtime image carries no build toolchain, a non-root user, and [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects")'s lockfile committed so the runtime and its packages are identical across services and environments. That last one removed a class of deploy-time surprise that had previously come from dependency drift between modules.

**Podman, honestly.** I have used it enough to be comfortable and have not operated it in production, so what I would offer is the differences that actually matter rather than a claim of depth:

- **Daemonless and rootless by default.** There is no privileged long-running daemon; containers are child processes of the invoking user. That is a genuine security improvement — membership of the docker group is effectively root on the host — and it is why it is the default tooling on Red Hat systems, which is relevant given the OpenShift cluster.
- **A near-identical command-line interface**, so `podman` aliased to `docker` covers most day-to-day use, and it can serve a Docker-compatible socket for tools that expect one.
- **Pods as a first-class concept**, closer to the Kubernetes model, and it can generate Kubernetes manifests from a running pod.
- **The friction points are real:** rootless networking and volume permissions behave differently, anything expecting the Docker socket (Testcontainers, docker-in-docker builds) needs configuration, and Compose support goes through `podman-compose` or the compatibility socket rather than being native. Those are the things I would check before proposing a switch, and I would check them by running the integration suite under it rather than by reading about it.

For image building specifically, Buildah and Kaniko are the daemonless options I would look at for CI, since building images inside a pipeline is where the privileged-daemon requirement is most awkward.

</details>

---

### Q13. What tools did you use for observability and monitoring, such as Prometheus, Kibana, Elastic APM?

**Project:** cancer-support-platform, banking-software-marketplace

**Brief answer**
On the health platform: Prometheus for metrics, Elastic Application Performance Monitoring ([APM](https://en.wikipedia.org/wiki/Application_performance_management "Gives visibility into request latency, errors and traces in production")) for traces, Kibana as the single pane, with Azure Monitor's telemetry shipped into the same Elasticsearch deployment so there is one place to look. On the marketplace: OpenTelemetry exported to Azure Monitor and Application Insights.

<details>
<summary><strong>Detailed answer</strong></summary>

**Two telemetry planes, joined rather than left separate.** The estate spans the clusters and Azure-native services, so there are inevitably two sources. What makes them one system is that the [W3C](https://www.w3.org/ "World Wide Web Consortium — Develops open web standards such as trace context propagation") `traceparent` propagates on **every** hop including AMQP, MQTT and Service Bus message headers, and that Azure Monitor diagnostic logs are shipped into the Elastic deployment. Without that join, a reminder that fails between the Celery worker and the delivery Function is two unconnected half-stories, and you find that out during an incident.

**Metrics that mean something.** The service level indicators are chosen so each one names a specific failure rather than a generic health notion:

- `outbox_unpublished_age_seconds` — index freshness; alerts above 30 seconds. This catches a stalled relay before any user sees stale search results.
- `reminder_dispatch_lateness_seconds` at p99, and `reminder_delivery_total{state}` — a failed ratio above 2% over an hour. Reminder delivery is the clinical-safety objective and is not traded for feature velocity.
- `consumer_task_duration_seconds` and `consumer_task_failed_total` per queue, and broker queue depth with unacknowledged counts.
- On the marketplace, `indexer_lag_seconds` — event occurrence to projection — which is the number that tells you the projection died. Its alert is a page specifically because nothing else surfaces it: new listings simply never become searchable, and every request stays fast and green.
- Authentication failures by reason, and identity-provisioning sync failures, which page — a deprovisioning that did not land is a security event, not a background job.

**Logging, and the line between logs and audit.** Structured JSON to stdout, shipped and queryable, every line carrying trace and span identifiers, service, module and actor kind. Two rules I would defend anywhere: **no clinical free text, no symptom values and no message bodies are ever logged** — a redaction filter drops fields marked sensitive at the formatter, and a CI check fails the build if a log call passes a model containing one — and **audit is a database table, never a log stream**. Conflating them means log retention policy silently becomes audit policy, which is a compliance failure nobody notices until an auditor asks.

**Tracing.** The agent auto-instruments FastAPI, SQLAlchemy, Celery, the broker and outbound [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources"), so a single trace covers the request, the event, the consumer and the index write. Sampling is deliberately uneven: 100% of errors and of the paths that carry the clinical guarantees, roughly 5–10% of routine reads. And the honest caveat — trace continuity across a message broker is the claim most likely to be false as written, because context propagation depends on the instrumentation versions actually injecting and extracting the header. Pin the versions and assert an end-to-end trace identifier in an integration test before relying on it during an incident.

**What I would add if it were not there.** A dashboard per objective rather than per service, so the question "are we meeting the target" is answerable without assembling it; alerts that name an owner and a runbook, since an alert with neither gets muted; and the alert rules themselves in infrastructure code, so a hand-silenced alert is a diff rather than a slow decay.

</details>
