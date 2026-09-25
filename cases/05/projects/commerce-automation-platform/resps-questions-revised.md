# Responsibility Questions — Intelligent Commerce Automation Platform
> Auto-generated from the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") brief. Questions use only what the CV states; answers draw on the system design documents.

## Table of Contents
- [R1. Architecture — Microservices and event-driven communication](#r1-architecture--microservices-and-event-driven-communication)
- [R2. Frontend — Merchant analytics dashboards](#r2-frontend--merchant-analytics-dashboards)
- [R3. Frontend — D3 heatmaps and treemaps](#r3-frontend--d3-heatmaps-and-treemaps)
- [R4. Frontend — UI library and seller onboarding](#r4-frontend--ui-library-and-seller-onboarding)
- [R5. Databases — PostgreSQL indexes and partitioning](#r5-databases--postgresql-indexes-and-partitioning)
- [R6. Data and AI pipelines — Glue ETL for supplier catalogs](#r6-data-and-ai-pipelines--glue-etl-for-supplier-catalogs)
- [R7. Data and AI pipelines — Context-aware product search](#r7-data-and-ai-pipelines--context-aware-product-search)
- [R8. Data and AI pipelines — Pricing and trend agents](#r8-data-and-ai-pipelines--pricing-and-trend-agents)
- [R9. Data and AI pipelines — Bedrock SEO descriptions](#r9-data-and-ai-pipelines--bedrock-seo-descriptions)
- [R10. Data and AI pipelines — Function-calling tools](#r10-data-and-ai-pipelines--function-calling-tools)
- [R11. Continuous delivery — Deployment to EKS](#r11-continuous-delivery--deployment-to-eks)
- [R12. Performance — Redis caching and Kafka streams](#r12-performance--redis-caching-and-kafka-streams)
- [R13. Testing and observability — Agent chain monitoring](#r13-testing-and-observability--agent-chain-monitoring)
- [R14. Testing and observability — Pytest and React Testing Library](#r14-testing-and-observability--pytest-and-react-testing-library)
- [R15. Testing and observability — Cursor and Codex](#r15-testing-and-observability--cursor-and-codex)

## R1. Architecture — Microservices and event-driven communication

> Architected distributed microservices topology on [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system"), establishing asynchronous event-driven communication across core services;

---

### Q1. How did you use FastAPI's dependency injection in these services, and what did you inject?

**Brief answer**
I used `Depends` to give every route the things it needs from outside: an async database session, the tenant context, a role check and the service modules. So a route handler only holds business logic, and tests can swap any of those parts.

<details>
<summary><strong>Must cover</strong></summary>

- **async database session** — one per request, closed after it
- **tenant-context dependency** — sets `app.tenant_id` with `SET LOCAL`
- **role dependency** — one per route
- **service modules**
- **AWS clients**
- **dependency overrides** — how tests swap real parts for fakes
- site list, token verification, dependency caching per request

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There are three FastAPI services: `platform-api`, `agent-service-api` and `mcp-gateway`. All three use `Depends` in the same way.

The first dependency is the **async database session**. It uses [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") in async mode over asyncpg. The dependency opens a session for the request and closes it when the request ends. A route never builds its own session.

The second is the **tenant-context dependency**. It reads the verified token and finds the tenant. Then it starts the transaction and runs `SET LOCAL app.tenant_id`. [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") row-level security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")) filters every tenant-owned table on that value. The dependency also adds the user's site list for site scoping. Because every route gets its session through this dependency, no route can forget to set the tenant.

The third is the **role dependency**. Each route declares which roles may call it, for example `reviewer` or `tenant_admin`. The check runs before the handler. The check runs in a dependency on every route, so no route can omit it.

Routes also receive **service modules**, such as the token-budget module. They also receive clients for Amazon Web Services ([AWS](https://aws.amazon.com/ "Cloud provider whose managed compute, storage and messaging services host a system")), the **AWS clients**, such as the Amazon Simple Storage Service ([S3](https://aws.amazon.com/s3/ "Durable object storage for files, datasets and archives")) or Step Functions client. The modules take their clients as arguments. They never build them at import time.

The main benefit shows in tests. With **dependency overrides**, a test replaces the session, the tenant context or an AWS client with a fake. It does not patch module globals.

One thing to watch: FastAPI caches a dependency once per request. That is what I want for the session and the tenant. It means two dependencies that share a sub-dependency also share the same instance inside one request.

</details>

---

### Q3. How did you decide between central orchestration and event-driven choreography?

**Brief answer**
I orchestrated work whose steps depend on each other and that needs one final status, which is every AI run. I used choreography where several consumers react to the same event and do not depend on each other, such as telemetry batches and run events.

<details>
<summary><strong>Must cover</strong></summary>

- **the rule** — dependent steps orchestrated, independent reactions choreographed
- **telemetry fan-out** — three consumers fail and scale alone
- **AI pipelines** — fixed order, branching, one status
- **execution history**
- **run events** — side effects subscribe; pipelines unchanged
- **subscriber failure** — never fails the run
- **cost** — per-transition latency against a hidden flow
- nothing to undo, saga

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used both, and **the rule** was whether the steps depend on each other. If a step needs the result of the step before it, and the work needs one final status, I orchestrate it. If several consumers react to the same event and do not depend on each other, I use choreography.

The **telemetry fan-out** is choreography. Each batch goes to an ordered SNS topic, and three queues receive it: the archiver, the rollup consumer and the rules consumer. None of them waits for another. Each one fails, retries and scales on its own. If the rules consumer has a bug, archiving and rollups continue.

The **AI pipelines** are orchestrated with Step Functions. An analysis has a fixed order: validate the request, build the context, run the agent, validate the output and save it. The validation step can send the run back to the agent. Every step has its own retry policy and timeout. The user needs one run status at the end. With choreography, this logic would be spread across several consumers, and no single component would own the status.

Orchestration also gives an **execution history** for every run. When a run fails, I open the execution and see which state failed and with what input. With choreography, I would have to rebuild that picture from logs.

At the end of a run, I switch to choreography. The pipeline publishes **run events** to the `ai-run-events` topic. The webhook dispatcher and the follow-up trigger subscribe to it. Adding a subscriber does not change the pipelines.

A **subscriber failure** never fails the run. If a tenant's webhook endpoint is down, the dispatcher retries from its own queue. After 8 attempts the message goes to a dead-letter queue, and the tenant is notified. The run itself is already complete.

Each style has a **cost**. Step Functions adds about 50–100 ms per state transition and charges per transition. That is acceptable for runs that take minutes. Choreography hides the overall flow. So every consumer must be safe to repeat, and tracing must join the hops.

Partial failure stays simple in the analysis pipeline. It writes its output only in the persist step, and intermediate results sit in S3 and expire after 14 days. So a failed analysis leaves nothing in PostgreSQL to undo, and `MarkFailed` only records the status and the error code. That is why the pipeline needs no saga with compensating steps.

</details>

---

### Q3. When did you use Kafka for communication, and when did you use SQS or SNS instead?

**Brief answer**
Kafka carries domain events that many services read and may need to replay. Amazon Simple Queue Service ([SQS](https://aws.amazon.com/sqs/ "Managed message queue that decouples producers from consumers")) carries units of work that need their own retries and a dead-letter queue. Amazon Simple Notification Service ([SNS](https://aws.amazon.com/sns/ "Managed publish-subscribe topics that fan one message out to many subscribers")) fans one notification out to several subscribers.

<details>
<summary><strong>Must cover</strong></summary>

- **synchronous only when a person waits**
- **Kafka for domain events** — ordered per key, replayable, many consumer groups
- **SQS for work** — visibility timeout, retries, dead-letter queue
- **SNS fan-out** — Glue has no consumer of its own
- **two messaging systems** — the cost I accepted
- webhooks through SQS, 300 ms internal timeout

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first rule decides between synchronous and asynchronous. A call is **synchronous only when a person waits** for the result. The console and the storefront widget call services over Representational State Transfer ([REST](https://en.wikipedia.org/wiki/REST "Architectural style for stateless, resource-oriented HTTP APIs")) through Amazon [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Gateway. A live chat turn calls `search-service` and `inventory-service` over internal REST, with a 300 ms timeout and one retry. Everything else is asynchronous.

I use **Kafka for domain events**, on Amazon Managed Streaming for Apache Kafka ([MSK](https://aws.amazon.com/msk/ "Runs Apache Kafka clusters as a managed AWS service")). These are facts about a change of state: a product changed, stock moved, a price decision was made. Kafka keeps them ordered per key and lets many consumer groups read the same topic. For example, `catalog.product-events` feeds the search indexer, the channel connector and the cache invalidator. Retention of 3 to 14 days also lets a consumer replay after a bug.

I use **SQS for work**. A [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") task, a channel webhook or a merge job is one item that one worker must finish. SQS gives each message a visibility timeout, retries and a dead-letter queue ([DLQ](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html "Dead-Letter Queue — Holds messages that failed processing repeatedly so they can be inspected and redriven")). Kafka has no per-message retry, so a single failing message would block its partition. Channel webhooks go through the `order-ingest` queue because SQS absorbs bursts, and channels retry when they get a 5xx.

I use **SNS fan-out** where one notification has several readers. Amazon Web Services (AWS) Glue cannot consume from anything when it finishes a job. So it publishes `batch.staged` to SNS. SNS sends it to the `catalog-batch-ready` queue, and on failure also to `ops-alerts`.

Running **two messaging systems** has a cost: two sets of metrics, alerts and client libraries. I accepted it because each covers what the other lacks. Both are managed services. Using SNS and SQS for everything would lose replay and get expensive at 3,500 interaction events per second.

</details>

---

### Q3. Which data had to be strongly consistent across your services, and where did you accept eventual consistency?

**Brief answer**
Stock, orders and price decisions had to be strongly consistent, so each one changes inside one service's own PostgreSQL transaction. Everything built from them, such as search, the cache, channel listings and analytics, is eventually consistent and lags by seconds or minutes. No transaction ever spans two services.

<details>
<summary><strong>Must cover</strong></summary>

- **consistency per domain** — not one CAP choice for the whole system
- **strong consistency inside one service** — a single PostgreSQL transaction
- **fail rather than diverge** — writes stop during a failover
- **eventual consistency for read models** — search, cache, channels, analytics
- **no distributed transaction** — no two-phase commit, no saga
- **bounded and measured** — searchable and priced everywhere within 2 minutes
- **the channel's checkout re-validates**
- optimistic concurrency with `version`, outbox and inbox

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I did not make one consistency choice for the whole platform. I used the Consistency, Availability and Partition tolerance ([CAP](https://en.wikipedia.org/wiki/CAP_theorem "Names the theorem that a distributed system can guarantee only two of the three during a network partition")) theorem as a frame and chose **consistency per domain**.

Three kinds of data must never be wrong: stock levels, orders and price decisions. An agent's stock update must never apply twice or go missing. For these I kept **strong consistency inside one service**. One service owns each of them, and each change is one PostgreSQL transaction on the `core-db` primary. The primary has a synchronous standby in a second Availability Zone (AZ). So a committed write survives the loss of a zone.

The trade-off is availability. During a network partition or a failover, these writes **fail rather than diverge**. A failover takes 60 to 120 seconds, and writes fail for about two minutes. Reads keep working from Redis and the read replica. I accepted that. A stock level that is wrong in two places is worse than a stock update that fails and is retried.

Everything else is a copy built from events. Catalog lookups through Redis, search, recommendations, the listings on sales channels and the analytics rollups use **eventual consistency for read models**. A shopper who sees a price that is a few seconds old is acceptable. A search that fails is not.

So there is **no distributed transaction** anywhere. There is no two-phase commit and no saga with compensating steps. A saga was not needed, because checkout and payment happen on the channels, not on the platform. Each service gets local atomicity instead. The state change and its outbox row commit together, and consumers de-duplicate with an inbox table. An event can arrive late, but it is never lost and never applied twice.

The lag has targets, so it is **bounded and measured**. A catalog change must be searchable within 2 minutes. A price can differ between the catalog, search and the channels for less than 2 minutes. Kafka consumer lag has its own target of 30 seconds at p95.

The last safety net is that **the channel's checkout re-validates** price and stock. A stale value on a storefront can mislead a shopper for a short time, but it cannot create a wrong order. Inside one service, a `version` column guards concurrent edits. An update that sends an old `If-Match` value is rejected.

</details>

## R2. Frontend — Merchant analytics dashboards

> Developed interactive merchant analytics dashboards using React, TypeScript, [MobX](https://mobx.js.org/ "MobX — Makes application state observable so that views update when the data they read changes"), and custom state containers;

---

### Q1. How did you structure the MobX stores behind the merchant dashboards? Was it a **store per dashboard** or one global store?

**Brief answer**
Each dashboard has its own observable store. The raw data from the application programming interface (API) and the active filters are observable state. Every total and chart input is a computed value. So a view re-renders only when the data it reads changes.

<details>
<summary><strong>Must cover</strong></summary>

- **store per dashboard** — scoped, not one global store
- **observable state** — raw API response and filters
- **computed value** — derived totals and chart inputs
- **observer components**
- **actions** — the only place state changes
- lazy-loaded analytics routes, `dash:` cache

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The console is a React single-page application ([SPA](https://en.wikipedia.org/wiki/Single-page_application "Single Page Application — Web application that updates its content in place without full page reloads")) written in strict TypeScript. I gave each dashboard a **store per dashboard** instead of one global store. The category sales dashboard and the behaviour flow dashboard each have their own. So one dashboard's state cannot leak into another, and each store stays small enough to test on its own.

A store holds two kinds of **observable state**. The first is the raw response from the analytics API, for example `GET /v1/analytics/category-sales` with its `from`, `to` and `channel` parameters. The second is the filters the merchant sets, such as the date range or a category.

Everything else is a **computed value**: totals, the share of each category, the sorted list, and the exact data shape each chart needs. MobX caches a computed value and recalculates it only when the observables it reads change. This is the reason I chose MobX over Redux here. Dashboard state is mostly derived, and Redux would need selectors and memoisation for every derived value.

The React components are **observer components**. Each one re-renders only when an observable or computed value it read during its last render changes. A change to the date filter re-renders the charts, but not the page header.

State changes only inside **actions**, for example when the merchant changes a filter or a new API response arrives. That keeps the flow easy to follow and to test.

Two things keep the dashboards fast outside MobX. React Router lazy-loads the analytics routes, so the [D3](https://d3js.org/ "D3.js — JavaScript library that binds data to SVG and HTML for custom visualisations") code downloads only when a merchant opens analytics. The dashboard endpoints read pre-aggregated rollup tables with a 60-second [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") cache, and their p95 target is 800 ms.

</details>

---

### Q2. What did you use the custom state containers for, and why did that state not live in the MobX stores?

**Brief answer**
The custom containers hold chart state that D3 owns, such as layout and hover, outside React renders. D3 updates the Scalable Vector Graphics (SVG) directly, so moving the mouse over a chart does not re-render the React tree.

<details>
<summary><strong>Must cover</strong></summary>

- **D3 owns the SVG** — React renders only the host element
- **chart state outside React renders**
- **one-way data flow** — the MobX store pushes new data into the container
- **re-render cost** — high-frequency events stay out of React
- **cleanup on unmount**
- data-level tests

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

React and D3 both want to control the Document Object Model ([DOM](https://dom.spec.whatwg.org/ "Tree representation of a document that programs traverse and modify")). If both do, they overwrite each other. So in my design **D3 owns the SVG**. React renders one host element, and D3 draws everything inside it.

The custom container is a small class that sits between the two. It keeps **chart state outside React renders**, such as the computed layout and the element under the pointer. D3 reads and writes that state directly.

The **one-way data flow** goes from the store to the chart. The MobX store holds the business data, such as the category tree for the treemap. When a computed value in the store changes, a MobX reaction passes the new data into the container. The container then runs the D3 update. D3 never writes back into the MobX store, except through an explicit action such as "the merchant selected this category".

The reason is **re-render cost**. Hover and mouse-move events fire many times per second. If they changed MobX state that a React component observes, every event would re-render part of the component tree. Inside the container they only update a few SVG attributes.

The container also handles **cleanup on unmount**. It removes D3 event listeners and disposes the MobX reaction. Otherwise a merchant who switches between dashboards leaks listeners.

The design docs record the decision itself: custom containers keep D3 chart state outside React renders. They do not describe the container API in more detail, so this is the pattern rather than a recorded class design. One benefit is testing. React Testing Library checks what data the chart receives, not its pixels.

</details>

## R3. Frontend — D3 heatmaps and treemaps

> Rendered category sales breakdowns and customer behavior flows using D3.js heatmaps and Treemap visualizations;

---

### Q2. How did the behaviour flow heatmap get its data fast enough for an interactive dashboard?

**Brief answer**
The heatmap reads a small hourly rollup table, not raw events. Interaction events flow through Kafka into that table, the API returns a matrix of stage transitions per hour, and a 60-second cache sits in front of it.

<details>
<summary><strong>Must cover</strong></summary>

- **interaction events** — widget batches into Kafka
- **hourly rollup table** — transitions per stage pair and hour
- **matrix response** — stages, hours, cells
- **dashboard cache** — 60 seconds, keyed by the query parameters
- **p95 under 800 ms**
- colour scale, freshness within minutes

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The heatmap shows how shoppers move between stages, for example from viewing a product to adding it to the cart, per hour of the day.

The raw data comes from **interaction events**. The storefront widget sends them in batches of up to 100 to `POST /v1/storefront/events`, which returns `202 Accepted`. The collector writes them to the Kafka topic `shopper.interactions`. At peak that is about 3,500 events per second, so no dashboard query may touch them directly.

`analytics-service` consumes the topic and keeps an **hourly rollup table**, `analytics.behavior_hourly`. Its key is tenant, hour, category, `stage_from` and `stage_to`, and it holds a count of transitions. The table is partitioned by month, and a dashboard always asks for a bounded date range.

`GET /v1/analytics/behavior-flows` returns a **matrix response**: a `BehaviorMatrix` with a list of stages, a list of hours and cells of `{stage_from, stage_to, hour, transitions}`. That is exactly what the heatmap draws, so the browser does no aggregation. D3 maps each cell to a rectangle and each count to a colour on a sequential colour scale.

In front of the endpoint there is a **dashboard cache** in Redis. The key holds the tenant, the endpoint and a hash of the parameters, and it lives 60 seconds. The rollups refresh every minute, so a longer cache would only show older data.

Together these keep the dashboard at **p95 under 800 ms**. The trade-off is freshness. Analytics is eventually consistent, and a new interaction appears within minutes, not instantly. That is fine for a merchant who looks at behaviour by the hour.

</details>

## R4. Frontend — UI library and seller onboarding

> Utilized Tailwind [CSS](https://developer.mozilla.org/en-US/docs/Web/CSS "Cascading Style Sheets — Describes how HTML elements are laid out and styled in a browser") and shadcn/ui components to build scalable UI libraries and multi-step seller onboarding workflows;

---

### Q2. How did you keep a seller's progress in the multi-step onboarding flow when they left halfway?

**Brief answer**
Every step is saved on the server as soon as the seller completes it. The onboarding session row stores the current step, the data of each step and a version. So the seller can reload, switch device or come back days later and continue.

<details>
<summary><strong>Must cover</strong></summary>

- **save per step on the server** — `PUT` one step at a time
- **onboarding session row** — current step, step data, version
- **step validation** — in the browser and again on the server
- **resume after reload**
- **optimistic concurrency** — `version` guards against two tabs
- store per step, React Router step routes

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Onboarding sets up a seller's account in several steps. A seller may stop halfway and come back later. So I made **save per step on the server** the core rule. Each step ends with `PUT /v1/onboarding/steps/{step}` and the step's payload. The response is the `OnboardingSession` with `current_step` and `status`.

`tenant-service` stores an **onboarding session row** in `platform.onboarding_sessions`. It holds `current_step`, `step_data` as `jsonb`, `status` and `version`. `jsonb` fits here because each step has a different shape, and the flow changes more often than the rest of the schema.

Each step has **step validation** twice. In the browser, the step's MobX store checks the form, and the wizard does not move on while the step is invalid. On the server, the Pydantic model for that step checks it again. The browser check is for the user. The server check is the one I trust.

**Resume after reload** comes from the server state. When the wizard loads, it fetches the session and opens `current_step`, with earlier answers filled in. React Router gives each step its own route, so the browser's back button moves between steps.

Two tabs can edit the same session. The row's `version` gives **optimistic concurrency**: an update sends the version it read, and a stale version is rejected instead of overwriting newer data.

React Testing Library tests cover step validation and resume after reload, because those are the two behaviours a seller notices when they break.

</details>

## R5. Databases — PostgreSQL indexes and partitioning

> Tuned PostgreSQL with optimized indexes and partitioning, sustaining 4,500+ RPS under peak load while maintaining sub-50ms response times;

---

### Q1. Which indexes did you add to reach sub-50 ms responses at 4,500 requests per second, and why those?

**Brief answer**
The key one is a covering index on the tenant and the stock keeping unit ([SKU](https://en.wikipedia.org/wiki/Stock_keeping_unit "Stock Keeping Unit — Identifies one sellable variant of a product for inventory and pricing")) that includes the price columns. With it, the hot variant lookup is an index-only scan. Every other index exists for one named query, because each extra index slows the bulk import.

<details>
<summary><strong>Must cover</strong></summary>

- **index per named query** — every index costs merge writes
- **`tenant_id` first** in every key
- **covering index** — `INCLUDE` for the variant card
- **index-only scan** — needs a current visibility map
- **partial index** — only active products
- **latency budget** — about 15 ms on a cache miss
- `text_pattern_ops` for category subtrees, autovacuum scale factor, cursor pagination index

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The 4,500 requests per second (RPS) are mostly one query: the variant card behind `GET /v1/catalog/variants/{sku}`. Storefronts, agents and the channel sync all call it. So I tuned for that query first.

My rule was an **index per named query**. If nobody could name the query an index serves, I did not build it. Every index costs write throughput, and the bulk import merges up to a million rows at a time.

Every key starts with **`tenant_id` first**. Every query filters on the tenant, and row-level security adds that filter anyway.

The most important index is a **covering index**: a unique index on (`tenant_id`, `sku`) with `INCLUDE (product_id, price_amount, currency)`. The lookup then reads everything it needs from the index. That is an **index-only scan**, with no visit to the table. An index-only scan works only while the visibility map is current. So I set `autovacuum_vacuum_scale_factor = 0.02` on `variants` and `stock_levels`. Otherwise the scan falls back to reading the heap.

Other indexes each serve one query. A **partial index** on (`tenant_id`, `category_id`) `WHERE status = 'active'` serves category lists and the channel sync. Archived products never enter it. An index on (`tenant_id`, `updated_at`, `product_id`) serves cursor pagination. `text_pattern_ops` on the category path serves subtree queries such as `path LIKE 'apparel/%'`.

The result is a **latency budget** I can explain. On a Redis miss, the path has four steps:

- about 3 ms for ingress and authentication
- 1 ms for the Redis miss
- 4 to 8 ms for the covering-index scan plus one primary-key lookup
- 3 ms to serialise the response

That is about 15 ms. The gap to 50 ms absorbs pool waits and event-loop stalls.

</details>

---

### Q2. How did you choose the partition key for each large table?

**Brief answer**
I chose by access pattern. Catalog and search tables are __hash-partitioned on the tenant__, because every query names one tenant. Orders, stock adjustments, market signals and rollups are __range-partitioned by time__, because they are read by date and deleted by age.

<details>
<summary><strong>Must cover</strong></summary>

- **hash partitioning on `tenant_id`** — 16 partitions, partition pruning
- **smaller indexes per partition**
- **range partitioning by time** — orders monthly, signals daily
- **retention by dropping partitions** — no bulk `DELETE`
- **partitions created ahead** — a scheduled job alerts
- **skewed tenant** — its own `LIST` partition
- vacuum one partition, archive to S3 by Glue

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I asked one question per table: what does every query filter on, and how does old data leave?

For `catalog.products`, `catalog.variants` and the search documents, the answer is the tenant. So they use **hash partitioning on `tenant_id`**, with 16 partitions. Every lookup includes `tenant_id`, so the planner uses partition pruning and touches one partition. Each partition has **smaller indexes per partition**, about 1/16 of the size, so more of them stay in memory. A large import also vacuums one partition instead of the whole table.

Time-series tables use **range partitioning by time**. `orders` and `order_lines` are monthly on `placed_at`, because a query for recent orders touches one or two partitions. `stock_adjustments` is monthly and `market_signals` is daily.

The biggest win of time partitions is **retention by dropping partitions**. Market signals are kept 30 days. Dropping a daily partition is instant. A bulk `DELETE` would write dead tuples and leave vacuum debt on a busy primary. Orders older than 24 months are detached, exported to S3 by a Glue job, then dropped.

Range partitioning has one sharp edge. An insert with no matching partition fails. So a scheduled Kubernetes Job keeps **partitions created ahead**, three periods in advance, and it alerts if fewer than two remain.

Hash partitioning has a risk too: a **skewed tenant**. With 16 partitions, one tenant with 30% of all SKUs would unbalance its partition. The design docs flag this as a check to make against the real tenant sizes before fixing the modulus. The fix is to give that tenant its own `LIST` partition in front of the hash partitions.

</details>

## R6. Data and AI pipelines — Glue ETL for supplier catalogs

> Constructed AWS Glue [ETL](https://en.wikipedia.org/wiki/Extract,_transform,_load "Extract, Transform, Load — Moves data out of source systems, reshapes it and loads it into a target store") pipelines to clean, chunk, and structure massive supplier catalogs for downstream [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") processing;

---

### Q1. What did the cleaning step in your Glue jobs actually do to a supplier feed? How did you deal with the situation that every supplier sends a different format?

**Brief answer**
It mapped each supplier's columns to one schema and stripped HyperText Markup Language ([HTML](https://html.spec.whatwg.org/ "Markup format that structures content for web browsers")). It validated every row, set failed rows aside, removed duplicates and computed a content hash per product. The hash is what lets the rest of the pipeline skip products that did not change.

<details>
<summary><strong>Must cover</strong></summary>

- **supplier mapping** — one schema from many feed formats
- **strip HTML**
- **row validation** — failed rows to `rejected/`
- **de-duplication**
- **content hash** — SHA-256 of the normalised fields
- PySpark, Parquet in `curated/`, Glue Data Catalog

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A merchant uploads a supplier feed of up to 2 million rows to S3. The upload triggers Lambda `feed-intake`, which starts the Glue job `supplier-feed-normalize` for that tenant and batch. The job is written in PySpark.

The first step is **supplier mapping**. Every supplier sends a different format. The supplier record holds `feed_format` and a `mapping_config`, and the job uses them to map each feed onto one product schema.

Then it cleans the text. The job will **strip HTML** from descriptions. HTML adds tokens without adding meaning, and it would cost money later in the model calls.

**Row validation** checks every row. A row that fails, for example because a required field is missing, goes to the `rejected/` prefix in S3. The merchant sees the count as `rows_rejected` on the import batch, and the reason in the import status. One bad row never fails the whole feed.

**De-duplication** removes repeated rows within the feed.

The last step is the **content hash**: a Secure Hash Algorithm 256-bit ([SHA-256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Produces a fixed-size digest used to verify content integrity")) hash of the normalised product fields. This is the most important output of the cleaning. Suppliers re-send the whole catalog every time, but only about 5% of products really change. Later, the merge updates a product only when its hash differs. So a million re-sent rows turn into roughly 50,000 real changes, and only those go on to the artificial intelligence (AI) enrichment.

The cleaned rows are written as Parquet under `curated/` and registered in the Glue Data Catalog. So a failed later step can restart from the cleaned data.

</details>

---

### Q2. How did you chunk the catalog data for the AI processing, and why that way?

**Brief answer**
Each product becomes one short first chunk with its title and key attributes. Its descriptions and spec sheets become chunks of about 512 tokens, with a 64-token overlap. The first chunk makes short queries match well, and the overlap keeps a fact that falls on a boundary.

<details>
<summary><strong>Must cover</strong></summary>

- **chunk 0** — title plus key attributes
- **~512-token slices** — descriptions and spec sheets
- **64-token overlap** — a fact on a boundary survives
- **chunk key** — tenant, product and chunk number
- **collapse chunks to products** — at query time
- NDJSON in `chunks/`, content hash per chunk

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Chunking decides what one embedding represents. If a chunk is too large, one vector mixes several topics and matches none of them well. If it is too small, a chunk loses its context.

I used two kinds of chunk. **Chunk 0** is always the title plus the key attributes, such as brand and category. Most shopper queries are short, like "waterproof running shoes". They match a short, dense chunk best.

The other chunks are **~512-token slices** of the long text: descriptions and spec sheets. Each slice has a **64-token overlap** with the one before it. Without the overlap, a sentence that crosses a boundary is cut in half, and neither half matches a query about it.

The design docs record these sizes but not a tuning study behind them. So I would not claim 512 was the measured optimum. It is a common size that keeps one topic per chunk and stays far inside the embedding model's input limit. The way to tune it is an offline recall test on real tenant queries.

The Glue job writes chunks as newline-delimited [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") ([NDJSON](https://github.com/ndjson/ndjson-spec "Newline-Delimited JSON — Stores one JSON record per line so files can be streamed and appended")) to `chunks/{tenant_id}/{batch_id}/`. The staging row keeps a list of its chunk keys. `search-indexer` embeds them later and writes them to `search.product_documents`. The **chunk key** there is (`tenant_id`, `product_id`, `chunk_no`).

One product can match on several chunks. So the retriever will **collapse chunks to products** at query time. The shopper sees a product once, ranked by its best chunk.

</details>

---

### Q3. How did you make the catalog pipeline safe to re-run when one step failed partway?

**Brief answer**
Every hand-off between steps is a durable artifact: an S3 object, a staging row or a queue message. So any step can restart from the output of the step before it, and the merge is idempotent because it only writes rows whose hash changed.

<details>
<summary><strong>Must cover</strong></summary>

- **durable artifact per hand-off**
- **batch status** — a state per step, `failed` with a reason
- **SNS to SQS** — Glue has no consumer
- **unlogged staging table** — a failover empties it
- **re-run from `curated/`**
- **idempotent merge** — only changed hashes write
- **late acknowledgement** — a crashed Celery task is redelivered
- dead-letter queue, rows in batches of 5,000

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline crosses S3, Lambda, Glue, PostgreSQL, SNS, SQS and Celery. Any of them can fail. So I made each step read a **durable artifact per hand-off**, never an in-memory result. The raw feed is in `raw/`, the cleaned data in `curated/`, the chunks in `chunks/`, the rows in a staging table, and the signal to continue is a queue message.

Each import has a **batch status** in `catalog.import_batches`: `awaiting_upload`, `normalizing`, `staged`, `merging`, `enriching`, then `completed` or `failed`. The status shows exactly where a batch stopped. The merchant sees it in the console.

Glue writes the rows to `staging.product_import_rows` over Java Database Connectivity ([JDBC](https://docs.oracle.com/javase/tutorial/jdbc/overview/index.html "Standard driver interface that Spark and AWS Glue use to read and write relational databases")). Then it publishes `batch.staged` to SNS. Glue has no consumer of its own, so it uses **SNS to SQS**: SNS fans the message to the `catalog-batch-ready` queue. `catalog-service` reads it, sets the batch to `merging` and queues the merge task.

The staging table is an **unlogged staging table**. It writes no write-ahead log ([WAL](https://www.postgresql.org/docs/current/wal-intro.html "Write Ahead Log — Sequential log written before data pages so committed transactions survive a crash")), so loading a million rows is much faster. The cost is that a crash or a Multi-AZ failover empties it. That is acceptable because staging is not the source: a batch left in `staged` can **re-run from `curated/`**.

The merge is an **idempotent merge**. It runs `INSERT … ON CONFLICT (tenant_id, parent_sku) DO UPDATE … WHERE products.content_hash <> EXCLUDED.content_hash` in batches of 5,000 rows. Running it twice changes nothing the second time.

The Celery tasks use **late acknowledgement** (`acks_late`). A worker that crashes mid-task never acknowledges it, so SQS delivers it again when the visibility timeout ends. A task that keeps failing ends in a dead-letter queue.

</details>

## R7. Data and AI pipelines — Context-aware product search

> Engineered context-aware product search pipelines using LangChain and PostgreSQL vector extensions, dropping average retrieval latency from 450ms to 110ms;

---

### Q2. What did you change to bring average retrieval latency from 450 ms to 110 ms?

**Brief answer**
I measured each stage first. The first big win was caching query embeddings and using a smaller model. The second was a per-tenant vector index, which replaced an index whose tenant filter fell back to an exact scan. A batched product lookup instead of one query per result did the rest.

<details>
<summary><strong>Must cover</strong></summary>

- **latency per stage** — measured before changing anything
- **query-embedding cache** — about 50% hit rate on head queries
- **512-dimension model** — instead of 1,536 dimensions
- **per-tenant HNSW index** — replaces IVFFlat with a post-filter
- **iterative index scan** — filtered recall, pgvector 0.8
- **N+1 queries** — replaced by one `MGET` and one batch call
- `ef_search = 40`, keyword search recovers exact terms

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started by measuring the **latency per stage**. The 450 ms were 190 ms for the query embedding, 170 ms for the vector search, 60 ms to fill in product data and 30 ms of framework and network.

**Embedding: 190 ms to about 50 ms.** Every search called the Bedrock embedding model. I added a **query-embedding cache** in Redis, keyed by the model name and a hash of the query. Popular queries repeat a lot, so it hits about 50% of the time, and a hit costs about 1 ms. I also moved to a **512-dimension model** (Amazon Titan Text Embeddings) instead of 1,536 dimensions. Smaller vectors are faster to create, store and compare.

**Vector search: 170 ms to about 20 ms.** This was the real bug. The old index was IVFFlat on the whole table, with the tenant filter applied after the index. For a small tenant, the index returned too few matching rows, and PostgreSQL fell back to an exact scan. I hash-partitioned the table by tenant, and each partition got its own Hierarchical Navigable Small World ([HNSW](https://arxiv.org/abs/1603.09320 "Graph index for approximate nearest-neighbour search over vectors")) index. With a **per-tenant HNSW index**, a query now searches about 750,000 chunks instead of 12 million. The keyword search runs in parallel at about 12 ms.

Filters still reduce recall in HNSW. pgvector 0.8 added the **iterative index scan**, which keeps scanning until enough rows pass the filter. That needs a re-sort by distance in an outer query. I use `ef_search = 40`, which trades a little recall for speed. The keyword search recovers exact-term misses.

**Filling in products: 60 ms to about 12 ms.** The old code ran **N+1 queries** through the object-relational mapper ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")), one per result. Now it runs one Redis `MGET` and one batched call for the misses.

Fusion and the session boost add about 3 ms. The p95 stays under 200 ms, because the tail is mostly embedding-cache misses.

</details>

---

### Q2. How did you protect the search endpoints from a flood of traffic, such as a scraping bot?

**Brief answer**
In layers. At the edge, a web application firewall blocks known bots and limits requests per IP address. API Gateway gives each storefront key its own rate limit. Behind that, a cap on result size and the query-embedding cache keep the cost of one request small.

<details>
<summary><strong>Must cover</strong></summary>

- **limits in layers** — edge, key, request, spend
- **bot control** — against catalog scraping
- **rate-based rule** — 2,000 requests per 5 minutes per IP
- **usage plan per key** — steady rate plus burst
- **publishable key is not a secret** — read-only routes, allowed origins only
- **bounded request** — at most 50 results
- **token budget per tenant** — protects model spend in chat
- 429 to the caller, repeated queries hit the embedding cache, capacity sized for the peak

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Storefront search is a public endpoint. The storefront widget calls it from the shopper's browser, so anyone can call it. That makes it a target for bots that copy a merchant's catalog and prices. So I put **limits in layers**, each one against a different kind of abuse.

The first layer is the edge. AWS Web Application Firewall ([WAF](https://owasp.org/www-community/Web_Application_Firewall "Filters and blocks malicious HTTP traffic before it reaches an application")) sits in front of CloudFront and API Gateway. Its **bot control** rule group runs on the storefront routes, against catalog scraping. A **rate-based rule** blocks an IP address after 2,000 requests in 5 minutes. That stops a simple script, but not a bot spread over many addresses.

The second layer is the key. Each storefront calls the API with a publishable API key that identifies the tenant. API Gateway applies a **usage plan per key**, with a steady rate and a burst. A traffic spike on one tenant's key is throttled with a 429. So it cannot use up the capacity that the other 800 tenants share.

The **publishable key is not a secret**. It sits in the page's code, and anyone can read it. So its only power is the read-only storefront routes, and it works only from the tenant's allowed origins. A stolen key can search, but it cannot change anything.

The third layer is the request itself. Search is a **bounded request**: `limit` is at most 50 results, so one call cannot ask for the whole catalog. Repeated queries also hit the query-embedding cache in Redis. A bot that sends the same query again costs about 1 ms of embedding time, not a Bedrock call.

The fourth layer protects money, not capacity. Chat reaches the same retrieval through the chat agent, and every chat turn calls a model. A **token budget per tenant**, a daily counter in Redis, caps that spend. Without it, a flood of chat messages would turn into a bill.

Behind all the layers, capacity is sized for a peak of about 600 search retrievals per second. The limits keep abuse away from that capacity. They do not make up for missing capacity.

</details>

## R8. Data and AI pipelines — Pricing and trend agents

> Built autonomous dynamic pricing and trend-analysis agents using LangGraph workflows and the [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform");

---

### Q1. Why did you build the pricing agents as LangGraph workflows rather than a single model call?

**Brief answer**
Pricing needs fixed steps, a pause for human approval that can last hours, and a hard limit on how long a run can loop. LangGraph gives explicit nodes, checkpoints and interrupts, so a run can wait for approval and resume on any worker.

<details>
<summary><strong>Must cover</strong></summary>

- **explicit nodes** — load context, compute, select, check, apply
- **checkpoints in PostgreSQL**
- **interrupt for approval** — resumes hours later on any worker
- **recursion limit** — and a token cap per run
- **Celery task on the agent worker**
- **trend agent** — nightly, read as context by pricing
- run id as the thread id, run cost recorded

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A pricing decision is not one question to a model. It is a fixed process with a model in one step. LangGraph lets me write that process as a graph of **explicit nodes**:

1. `load_context` calls tools for the signals, the sales trend, stock, cost and the pricing rules.
2. `compute_candidates` calculates 3 to 5 prices with plain arithmetic.
3. `llm_select` asks the OpenAI model to choose one candidate and explain why.
4. `guardrails` checks the choice.
5. The graph then applies the price, blocks it, or waits for approval.

A single model call cannot pause. A price change outside the auto-apply band needs a merchant's approval, and that can take hours. LangGraph writes **checkpoints in PostgreSQL** after each node. At the approval step the graph raises an **interrupt for approval**. The run is saved, and the worker is released. When the merchant calls the approve endpoint, the same thread resumes, on any worker. Decisions that nobody approves expire after 24 hours.

A free-form agent loop can also run away. So each run has a **recursion limit** of 12 steps and a token cap per run. A bad model response cannot turn into an endless, expensive loop.

Each run is a **Celery task on the agent worker**, on the `celery-agents` queue. The run id is the LangGraph thread id. `pricing.agent_runs` records the tokens in and out and the cost of every run.

The **trend agent** uses the same approach on a different schedule. A Kubernetes CronJob starts one run per tenant and category each night. It reads category sales through the analytics API and recent market signals, then writes a trend report. The pricing graph reads the latest report as context, and the console shows it to the merchant.

</details>

---

### Q1. Name the models which you chose for different types of work.

## R9. Data and AI pipelines — Bedrock SEO descriptions

> Leveraged Amazon Bedrock foundation models to automate [SEO](https://developers.google.com/search/docs/fundamentals/seo-starter-guide "Search Engine Optimization — Shapes page content so that search engines rank it higher") description synthesis, cutting operational API costs by 35% through response caching and token optimization;

---

### Q1. Why did you use Amazon Bedrock for the SEO descriptions rather than calling a model provider directly?

**Brief answer**
Bedrock keeps the catalog workload inside AWS. Access is controlled by the same AWS Identity and Access Management ([IAM](https://aws.amazon.com/iam/ "Controls which principals may perform which actions on which AWS resources")) roles as the rest of the platform. Traffic goes through a private endpoint, and Bedrock offers batch inference for large backfills.

<details>
<summary><strong>Must cover</strong></summary>

- **data stays inside AWS** — a VPC interface endpoint
- **IAM role per service account** — only the configured models
- **one provider for catalog and chat** — shopper text stays in AWS
- **batch inference** — for backfills
- **quota is the limit** — not compute
- LangChain model abstraction, OpenAI kept for pricing

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The catalog enrichment runs in `catalog-worker`. For every changed product it extracts structured attributes and writes a search engine optimization (SEO) description. At about 200,000 attribute extractions and 130,000 SEO generations a day, it is a large and steady model workload.

The first reason for Bedrock is that the **data stays inside AWS**. Calls go through a virtual private cloud ([VPC](https://aws.amazon.com/vpc/ "Virtual Private Cloud — Isolated private network in which cloud resources run")) interface endpoint, not over the public internet.

The second reason is access control. Pods get AWS permissions through an **IAM role per service account**. The role of `catalog-worker` may invoke only the configured Bedrock models and read only the supplier feeds bucket. There is no provider API key to store or rotate for this workload.

The third reason is consistency with chat. The shopper chat model is also on Bedrock, because shopper messages may contain personal data and must stay inside AWS. So there is **one provider for catalog and chat**, with one quota to plan and one data processing agreement. OpenAI is used only for the pricing agents, where the inputs hold no personal data.

Bedrock also supports **batch inference**. When I change the prompt version, every product needs a new description. That backfill runs as a Bedrock batch job, not as millions of on-demand calls.

At this volume, the **quota is the limit**, not compute. So each Celery queue has a fixed concurrency, and a Redis token bucket keeps the calls under the quota. LangChain wraps both providers behind one model interface, so the calling code does not depend on the provider.

</details>

---

### Q2. Taking these 2 pipelines: autonomous dynamic pricing and trend-analysis agents and automate SEO description synthesis, why did you choose the the OpenAI SDK for the first one and Amazon Bedrock for the second?

**My vision**
Because from my perspective, it would be more efficient vise versa:
For a financial or analytical agent that acts autonomously, Amazon Bedrock is the safer, more logical choice.
For high-volume text transformations like generating meta descriptions or product SEO text, the OpenAI Native API is significantly more efficient and cost-effective.

## R12. Performance — Redis caching and Kafka streams

> Leveraged Redis caching and Kafka event streams to handle high-concurrency catalog lookups and order events;

---

### Q1. Which caching pattern did you use for the catalog lookups, and why that one?

**Brief answer**
Cache-aside with delete on change. A read fills the cache on a miss, and a write deletes the key after the commit and again when its event arrives. A hot key that expires is refilled by one request under a short lock, not by hundreds.

<details>
<summary><strong>Must cover</strong></summary>

- **cache-aside** — fill on a miss
- **delete after commit**
- **second delete from the event** — catches other writers
- **TTL with jitter** — 600 seconds plus or minus 10%
- **single-flight lock** — one database read for a hot key
- **stock not cached** — for correctness
- version in the key prefix

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The hot path is the variant card: SKU, title, price and status. Storefronts, agents and the channel sync read it thousands of times per second at peak.

I used **cache-aside**. The service reads `cat:v1:{tenant_id}:{sku}` from Redis. On a miss, it reads PostgreSQL and fills the key. The `v1` in the key lets me change the cached shape without reading old entries.

For invalidation I chose delete, not write-through. With write-through, if the cache write fails after the database commit, the cache holds a stale value until the TTL ends. So `catalog-service` will **delete after commit**. Other writers can also change a variant. For example, the consumer of `pricing.decisions` updates prices. So a cache invalidator on `catalog.product-events` does a **second delete from the event**. The worst-case staleness is then the event lag, a few seconds.

Every key also has a **TTL with jitter**: 600 seconds, plus or minus 10%. Keys filled at the same moment do not all expire in the same second.

A flash sale creates one more problem. A popular SKU expires, and hundreds of requests miss at once. Each would go to the database. So the fill uses a **single-flight lock**: `lock:{key}` with `SET NX PX 2000`. One request reads the database and fills the key. The others wait briefly and then read the cache.

I left one thing out of the cache on purpose. The **stock not cached** rule is for correctness. The in-stock flag in search comes from the search documents, updated from `inventory.events` within seconds. The final check happens at the channel's own checkout.

</details>

## R13. Testing and observability — Agent chain monitoring

> Configured full-stack observability with Prometheus and Grafana to detect latency bottlenecks in AI agent chains;

---

### Q1. Which metrics did you expose to see where the time goes inside an AI agent chain?

**Brief answer**
A LangChain callback handler in the shared service library records the duration of every graph node, every model request and every tool call, plus tokens and cost. Prometheus scrapes them and Grafana shows the p95 per node.

<details>
<summary><strong>Must cover</strong></summary>

- **callback handler** — in the shared chassis, so every agent gets it
- **node duration histogram** — per graph and node
- **model request duration** — per provider, model and cache hit
- **token counter** — per direction
- **tool call duration** — per tool and outcome
- **run cost** — per graph and tenant tier
- CloudWatch as a second Grafana source, request rate and errors per route

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Standard web metrics were not enough. Request rate, error rate and duration per route tell you a chat turn took 6 seconds. They do not tell you which step took 5 of them.

So I added a LangChain **callback handler** to the chassis library that every service uses. LangChain calls it at the start and end of every node, model request and tool call. Every agent gets the same metrics without extra code.

It exports four families of metrics:

- `agent_node_duration_seconds{graph, node}`: a **node duration histogram**. It shows which step of the pricing, trend or chat graph is slow.
- `llm_request_duration_seconds{provider, model, cache}`: the **model request duration**. The `cache` label separates cache hits from real calls, so hits do not hide slow calls.
- `llm_tokens_total{provider, model, direction}`: a **token counter** for input and output tokens. A slow call is often a long call.
- `tool_call_duration_seconds{tool, outcome}`: the **tool call duration**. A slow inventory lookup shows up here, not as a slow model.

There is also `agent_run_cost_usd_total{graph, tenant_tier}` for **run cost**. Latency and cost usually move together in agent chains, so I watch both.

Histograms matter here. An average hides the tail, and the tail is what a shopper waiting for a chat reply notices. With a histogram, Grafana can show p95 per node over time.

AWS-managed services report to CloudWatch instead: Glue, Lambda, SQS, DynamoDB and RDS Performance Insights. Grafana reads CloudWatch as a second data source, so there is one set of dashboards.

</details>

---

### Q2. Tell me about a latency bottleneck in an agent chain that your dashboards showed, and how you fixed it.

**Brief answer**
The pattern the p95-by-node panel is built to catch is serial tool calls. In the pricing graph, a context step that fetches signals, sales trend, stock, cost and rules one after another shows as one long node. The fix is a parallel fan-out in LangGraph, and the same panel confirms it.

<details>
<summary><strong>Must cover</strong></summary>

- **p95 by node** — a Grafana panel over time
- **serial tool calls** — one long context-loading node
- **tool call durations** — each call fast, the sum slow
- **parallel fan-out** — LangGraph branches that join
- **confirm on the same panel**
- **trace spans** — per node, tool call and model request
- price decision lag objective, slow traces always kept

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I built a Grafana panel showing **p95 by node** over time for each graph. The node that holds a bottleneck stands out at a glance.

The clearest case, and the one the design names, is the pricing graph's first node, `load_context`. It calls five tools: market signals, the sales trend, stock, cost and the pricing rules. If it makes those calls one after another, the panel shows **serial tool calls** as one long `load_context` node.

The **tool call durations** then explain it. Each call on its own is fast. The problem is the sum, not any single tool.

The fix is a **parallel fan-out** in LangGraph. The graph starts the independent tool calls as parallel branches and joins them before `compute_candidates`. The node then takes about as long as its slowest tool, not the sum of all five.

A fix is not done until the metric moves. So I **confirm on the same panel** that the p95 of that node drops after the release.

Metrics show which node is slow, but not always why. For that I use traces. OpenTelemetry callbacks open **trace spans** per graph node, tool call and model request. Trace context travels in Kafka and Celery headers, so one trace covers the signal, the queue wait and the run. Traces are sampled at 10%, but every trace with an error or longer than 2 seconds is kept.

This matters because pricing has a service level objective ([SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet")): a price decision applied within 5 minutes of the signal, at p95. One honest limit: the design docs describe this case without before-and-after numbers, so I would not quote numbers for it in an interview.

</details>

## R14. Testing and observability — Pytest and React Testing Library

> Maintained high code quality and software stability using Pytest and React Testing Library across critical workflows;

---

### Q1. How did you write Pytest tests for code that calls an LLM?

**Brief answer**
I split the code into a deterministic part and a model part. The model calls are replayed from recorded fixtures, so the tests are fast and repeatable, and the deterministic parts, such as the pricing guardrails, get exhaustive table tests.

<details>
<summary><strong>Must cover</strong></summary>

- **recorded fixtures** — model calls replayed, not live
- **deterministic core** — guardrails and candidate arithmetic
- **table tests** — parametrised, every rule edge
- **negative schema tests** — cross-tenant SKU, change out of range
- **integration on Docker Compose** — real PostgreSQL, Redis, Kafka
- **no card data** — a test asserts it never reaches orders

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A live model call in a unit test is slow, costs money and gives a different answer each time. So in unit tests every LLM call uses **recorded fixtures**. The test replays a stored model response. It checks what my code does with that response: the parsing, the next graph step and the tool call.

The design helps here. In pricing the model only chooses between candidates, so most of the logic is a **deterministic core**: the candidate arithmetic and the guardrails. That core has **table tests**, parametrised Pytest cases that cover every rule edge. A price exactly at the margin floor, just below the MAP floor, or at the maximum daily change are all rows in a table. These tests are the reason every applied price has passed rules a unit test can prove.

The tool schemas get **negative schema tests**. One sends a SKU from another tenant. Another sends a stock change outside the allowed range. Both must be rejected. A test that only checks the happy path would not show that the limit works.

**Integration on Docker Compose** runs in the pipeline with real PostgreSQL with pgvector, Redis and Kafka. This catches what mocks hide, such as row-level security policies, the outbox relay and consumer idempotency.

Some tests guard compliance rules. Orders must never store payment card data. So a test asserts that **no card data**, in the form of a card-like number pattern, reaches `orders.orders`.

Model quality itself is not what a unit test measures. For that, a 1% sample of prompts and completions is logged, with personal data redacted, for evaluation.

</details>
