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

### Q1. How did you decide where one microservice ends and the next one begins?

**Brief answer**
I cut the services along business domains, and each service owns its own data. There are ten [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services, and a change of state crosses a service boundary only as an event.

<details>
<summary><strong>Must cover</strong></summary>

- **business domain** — one service and one namespace per domain
- **data ownership** — only the owning service writes its tables
- **schema per service** — own PostgreSQL role, no joins across schemas
- **shared chassis library**
- **split trigger** — when a schema moves to its own instance
- noisy neighbour, workers as separate Deployments

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from the **business domain**. Each domain became one service in its own [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") namespace on Amazon Elastic Kubernetes Service ([EKS](https://aws.amazon.com/eks/ "Managed Kubernetes hosting on AWS")). The ten services are `tenant-service`, `catalog-service`, `search-service`, `inventory-service`, `order-service`, `pricing-service`, `conversation-service`, `recommendation-service`, `analytics-service` and `channel-connector`.

The main rule is **data ownership**. Only the owning service writes its tables. Other services learn about a change from a [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") event. For example, `order-service` publishes `orders.events`, and `inventory-service` consumes them to adjust stock. It never reads the orders tables directly.

I enforced the rule in the database, not only in code review. The data lives in one shared [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") instance, `core-db`, with a **schema per service**. Each service connects with its own PostgreSQL role, and that role has privileges on its own schema only. So `order-service` cannot join `catalog.products` even by mistake.

Some parts repeat in every service: authentication middleware, the event publishing code, metrics and logging. I put them in a **shared chassis library**, so a new service does not have to build them again.

Sharing one database instance was a deliberate trade-off. It costs some noisy-neighbour risk. In return, a team of 8 to 12 engineers runs one Multi-Availability-Zone (Multi-[AZ](https://aws.amazon.com/about-aws/global-infrastructure/regions_az/ "Availability Zone — Isolated group of data centres within an AWS Region, used to survive a single-site failure")) database pair instead of eight. I wrote down a **split trigger**. If the primary's CPU stays above 60% at peak for 7 days, the `pricing` and `analytics` schemas move to their own instance first. Those two are write-heavy but not latency-critical.

Long-running work also has its own boundary. `catalog-worker` and `agent-worker` are separate Deployments from their services, so a slow import or agent run never takes capacity from request handling.

</details>

---

### Q2. How did you make sure an event is published every time a service commits a change to its database?

**Brief answer**
I used the transactional outbox pattern. The service writes its change and an outbox row in one PostgreSQL transaction, and a relay publishes the row to Kafka afterwards. So the database and Kafka never disagree about what happened.

<details>
<summary><strong>Must cover</strong></summary>

- **dual-write problem** — database commits, Kafka never hears about it
- **transactional outbox** — state change and event row in one transaction
- **relay** — polls unpublished rows with `FOR UPDATE SKIP LOCKED`
- **advisory lock** — one relay leader, so commit order per key
- **at-least-once** — consumers must handle duplicates
- **inbox table** — consumer records the event id in its own transaction
- partial index on unpublished rows, outbox age alert, direct publish for analytics-only events

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The problem to avoid is the **dual-write problem**. If a service commits to PostgreSQL and then publishes to Kafka, a crash between the two steps loses the event. The database says the price changed, but search and the sales channels never hear about it. Publishing first is worse, because the event can go out for a change that then rolls back.

So every publishing service uses a **transactional outbox**. The service writes its state change and a row in its own `outbox` table in the same transaction. Both commit or neither does.

A **relay** Deployment per service moves rows to Kafka. Every 200 ms it selects `outbox WHERE published_at IS NULL` with `FOR UPDATE SKIP LOCKED`, publishes the rows, and sets `published_at`. A partial index on unpublished rows keeps this poll small, however large the table grows.

Only one relay replica publishes at a time. It holds a PostgreSQL **advisory lock**, so events for one key leave in commit order. If the leader dies, the lock is released and a standby takes over within 10 seconds.

The relay can publish a row and crash before it sets `published_at`. So delivery is **at-least-once**, and consumers must handle duplicates. Each consuming schema has an **inbox table** keyed on (`consumer_group`, `event_id`). The consumer inserts the event id in the same transaction as its own write. A redelivered event hits the primary key and changes nothing.

The cost is about 200 ms of extra delay and one poll per service. I alert when the oldest unpublished row is older than 60 seconds, because that means Kafka or the relay has a problem. One stream skips the outbox on purpose: chat intent events are analytics only, so losing one breaks nothing, and they are published directly.

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

## R2. Frontend — Merchant analytics dashboards

> Developed interactive merchant analytics dashboards using React, TypeScript, [MobX](https://mobx.js.org/ "MobX — Makes application state observable so that views update when the data they read changes"), and custom state containers;

---

### Q1. How did you structure the MobX stores behind the merchant dashboards?

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

---

### Q3. How did you keep the TypeScript types in the console in step with the backend API?

**Brief answer**
I did not write the API types by hand. FastAPI generates an [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document from the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models, and the TypeScript client types are generated from that document. So a backend change that breaks the console fails the frontend type check.

<details>
<summary><strong>Must cover</strong></summary>

- **Pydantic models are the source**
- **OpenAPI document** — FastAPI generates it
- **generated TypeScript types** — no hand-written copies
- **strict type check** — fails in the pull request
- **separate deploys** — the API must still serve the old console
- shared types in the storefront widget, cursor pagination, `If-Match` on `version`

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The single source of truth is the backend. Every request and response body is a Pydantic model. So the **Pydantic models are the source** of the contract.

FastAPI generates an **OpenAPI document** from those models. I build the **generated TypeScript types** for the console's API client from that document. Nobody writes an API type by hand in the frontend. When a backend engineer renames a field, the generated types change. Then the console fails its strict type check in continuous integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")) wherever it still uses the old name. The error shows up in the pull request, not in production.

The same generated types serve the storefront widget. The widget is also written in TypeScript and compiled to a small plain JavaScript bundle. A separate JavaScript codebase would need a second copy of the same types.

Generation covers the shape of the data. Some API rules are conventions that every endpoint follows, and the console must follow them too. Lists use cursor pagination with `cursor` and `limit`. Updates send `If-Match` with the row `version`, so a stale edit is rejected instead of overwriting newer data.

The console and the services have **separate deploys**. The console goes to Amazon Simple Storage Service ([S3](https://aws.amazon.com/s3/ "Durable object storage for files, datasets and archives")) behind CloudFront, and the services go to EKS through a canary. So for a while, a new API version serves an old console that is still cached in a browser. This means a change must be additive first: add the new field, move the console to it, then remove the old field. Generated types do not protect against this timing problem, so I treated it as a rule for API changes.

</details>

## R3. Frontend — D3 heatmaps and treemaps

> Rendered category sales breakdowns and customer behavior flows using D3.js heatmaps and Treemap visualizations;

---

### Q1. How did you turn category sales data into a D3 treemap?

**Brief answer**
The API returns the category sales as a nested tree, and `d3-hierarchy` sums revenue up the tree. The treemap layout then gives each category a rectangle whose area matches its share of revenue.

<details>
<summary><strong>Must cover</strong></summary>

- **nested tree from the API** — name, revenue, units, children
- **pre-aggregated rollups** — no scan of raw orders
- **`d3.hierarchy`** — `sum` adds revenue up the tree
- **treemap layout** — area proportional to revenue
- **data-level tests** — not pixels
- sort by value, padding for labels, lazy-loaded D3

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The shape of the data decides most of the work, so I designed the API around the chart. `GET /v1/analytics/category-sales` takes `from`, `to` and an optional `channel`. It returns a `CategorySalesTree`: a **nested tree from the API** where each node has `name`, `revenue`, `units` and `children`.

The endpoint never scans raw orders. `analytics-service` reads **pre-aggregated rollups** from the `analytics.sales_daily_category` table. The table holds orders, units and revenue per tenant, day, channel and category. Categories carry a materialised path, such as `apparel/footwear/running`, so building the tree is a grouping by path.

In the browser I pass the tree to **`d3.hierarchy`** and call **`sum`** on revenue. Only leaf categories carry their own revenue, and `sum` adds the totals up to every parent. Then I sort children by value, so the biggest categories sit in the top-left corner.

The **treemap layout** from `d3-hierarchy` then computes one rectangle per node. The area of each rectangle is proportional to its revenue. I add padding at the top of parent nodes, so a category label does not cover its children.

I chose D3 over a ready-made chart library because I needed control of the treemap layout. D3 is large, so React Router lazy-loads the analytics routes, and D3 downloads only when a merchant opens analytics.

I tested the chart with **data-level tests**. A test checks the tree the chart receives and the rectangles the layout computes, not the pixels it draws. Pixel tests break on every style change and prove little about the numbers.

</details>

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

### Q1. How did you build a shared component library with Tailwind CSS and shadcn/ui?

**Brief answer**
shadcn/ui gives you component source code, not a package, so I copied the components into our own shared package, `@cap/ui`, and styled them with Tailwind utility classes. The console and the onboarding wizard both import from that one package.

<details>
<summary><strong>Must cover</strong></summary>

- **component source into our repository** — shadcn/ui copies, it does not install
- **`@cap/ui`** — one package for every screen
- **Tailwind utility classes**
- **theme tokens** — CSS variables, not hard-coded colours
- **accessible primitives** — Radix under shadcn/ui

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

shadcn/ui works differently from a normal component library. Its command-line tool copies the **component source into our repository**. We own the code after that. This matters for a library that must grow, because we can change a component without waiting for an upstream release or fighting an override.

I collected the components in one shared package, **`@cap/ui`**. The merchant console and the onboarding wizard import buttons, forms, dialogs, tables and step indicators from it. A screen never builds its own button. This is what "scalable" means here: new screens reuse the same parts, and a fix in one place reaches every screen.

Styling uses **Tailwind utility classes** inside the components. A screen that uses a component does not write its own Cascading Style Sheets (CSS) for it. Tailwind removes unused classes at build time, so the CSS bundle stays small as the library grows.

Colours, radius and spacing come from **theme tokens**. shadcn/ui defines these as CSS variables, and Tailwind classes point at the variables. That is why I did not choose Material UI: its theming is harder to adjust per tenant.

The interactive components, such as dialogs, menus and popovers, are built on Radix primitives. So they come with **accessible primitives**: keyboard navigation, focus handling and Accessible Rich Internet Applications (ARIA) attributes. We do not write those ourselves.

The risk of owning the code is drift. A copied component does not get upstream fixes automatically. I handled that by keeping all copies in `@cap/ui`, so there is one place to compare with upstream.

</details>

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
I chose by access pattern. Catalog and search tables are hash-partitioned on the tenant, because every query names one tenant. Orders, stock adjustments, market signals and rollups are range-partitioned by time, because they are read by date and deleted by age.

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

---

### Q3. How would this database set-up hold up at ten times the load?

**Brief answer**
Not as it is, but the next steps are written down with the metric that starts each one. First I would move the pricing and analytics schemas to their own instance, then add read replicas, and only then shard catalog and inventory by tenant.

<details>
<summary><strong>Must cover</strong></summary>

- **one primary at ≤ 40% CPU**
- **connection budget** — pool per pod against `max_connections`
- **evolution triggers** — a metric starts each step
- **split schemas** — pricing and analytics first
- **read replica** — for replica lag
- **shard by `tenant_id`** — at sustained 3,000 writes per second
- Aurora, cache for capacity

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Today there is **one primary at ≤ 40% CPU**: a single `db.r6g.2xlarge` for `core-db`, sized to serve the full 4,500 RPS peak even with Redis empty. Ten times that load would be 45,000 RPS. One instance would not serve that from the database alone.

The first limit I would hit is connections, not CPU. The **connection budget** is `pool_size = 5` and `max_overflow = 5` per pod. At peak replica counts that is about 450 connections against `max_connections = 1,000`. Ten times the pods would break that, so the pool settings have to change with the replica counts.

I did not want to shard on day one. Sharding adds routing, cross-shard analytics and rebalancing, and the team is 8 to 12 engineers. So I wrote **evolution triggers**: each step starts when a metric crosses a line.

1. Primary CPU above 60% at peak for 7 days: **split schemas**. The `pricing` and `analytics` schemas move to their own Amazon Relational Database Service ([RDS](https://aws.amazon.com/rds/ "Managed hosting for relational databases such as PostgreSQL, with backups and failover")) instance first. They are write-heavy but not latency-critical. The schema-per-service layout makes this a move, not a rewrite.
2. Replica lag above 30 seconds at peak: add a second **read replica**, or move analytics reads to a Glue and Athena path.
3. Sustained writes above 3,000 per second: **shard by `tenant_id`** for `catalog` and `inventory`. Every key already starts with `tenant_id`, so the data is ready for it.

At ten times the read load, Redis also changes role. Today it cuts latency but does not supply capacity. At 45,000 RPS it would have to carry the load, so its failure would become a capacity problem. I would also re-check Aurora, which has better replica lag at a higher price.

</details>

## R6. Data and AI pipelines — Glue ETL for supplier catalogs

> Constructed AWS Glue [ETL](https://en.wikipedia.org/wiki/Extract,_transform,_load "Extract, Transform, Load — Moves data out of source systems, reshapes it and loads it into a target store") pipelines to clean, chunk, and structure massive supplier catalogs for downstream [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") processing;

---

### Q1. What did the cleaning step in your Glue jobs actually do to a supplier feed?

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

### Q1. What made the product search "context-aware"?

**Brief answer**
Two things. The ranking is boosted towards the categories the shopper just viewed in this session. In chat, the agent first rewrites a follow-up such as "cheaper ones in blue" into a full, standalone query.

<details>
<summary><strong>Must cover</strong></summary>

- **hybrid retrieval** — vector and keyword, fused by rank
- **session boost** — categories the shopper just viewed
- **session key in Redis** — last 20 product ids, one-hour sliding expiry
- **query rewrite in chat** — a follow-up becomes a standalone query
- **tenant and stock filters**
- hand-set weights, offline click-log evaluation

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The base is **hybrid retrieval**. `search-service` runs a custom LangChain retriever. It runs a vector search and a full-text keyword search in parallel, and fuses the two ranked lists by reciprocal rank. Vector search finds meaning, such as "trainers" for "running shoes". Keyword search finds exact terms, such as a model number. Neither is enough alone.

The context comes on top of that, in two forms.

The first is the **session boost**. The ranking is pushed towards the categories the shopper viewed in this session. If they have been looking at running shoes, the query "jacket" ranks running jackets higher. The data comes from a **session key in Redis**, `sess:{tenant_id}:{shopper_ref}`. It holds the last 20 product ids and expires one hour after the last activity. The consumer of `shopper.interactions` keeps it up to date. `shopper_ref` is a pseudonymous hash, so the key holds no name or email address.

The second is the **query rewrite in chat**. A shopper in chat writes follow-ups like "cheaper ones in blue". That text alone is a bad query. So the chat agent rewrites it into a standalone query, using the conversation, before it calls retrieval. The rewrite is a model call in the chat turn, so it is not part of the retrieval latency figure.

Both searches also apply **tenant and stock filters**: `tenant_id`, `status = 'active'`, and optional `category_path` and `in_stock`. A shopper never sees another merchant's products.

One honest limit: I set the fusion constant and the session boost weight by hand. The right way to tune them is an offline evaluation on click logs, with normalized discounted cumulative gain ([NDCG](https://en.wikipedia.org/wiki/Discounted_cumulative_gain "Normalized Discounted Cumulative Gain — Ranking metric that rewards relevant results appearing near the top")) on held-out sessions.

</details>

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

### Q3. How would this search design hold up with ten times the catalog?

**Brief answer**
The limit is the vector index, not the query path. At about 50 million chunks, or when an index rebuild takes over four hours, I would move to a dedicated vector engine. It would sit behind the same LangChain retriever interface, so the services above it do not change.

<details>
<summary><strong>Must cover</strong></summary>

- **per-tenant partitions** — query cost follows the tenant, not the total
- **HNSW memory and build time**
- **evolution trigger** — 50 million chunks or a 4-hour rebuild
- **OpenSearch k-NN**
- **same retriever interface**
- **large tenant** — its own partition
- half-precision vectors, read replica

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Today `search-db` holds about 12 million chunks. The HNSW indexes are about 60 GB. Ten times the catalog is about 120 million chunks.

The query path scales better than that number suggests. Queries always filter on one tenant, and each tenant partition has its own index. So the cost of a query depends on the size of the **per-tenant partitions**, not on the total. If each tenant grows ten times, each index gets larger, but HNSW search time grows slowly with size.

The real limit is **HNSW memory and build time**. An HNSW index is fast only when it fits in memory. Building one is memory-heavy, and a rebuild after a model change touches every vector. Recall under filters also depends on the pgvector version.

So I set an **evolution trigger**: more than 50 million chunks, or an HNSW rebuild longer than 4 hours. At that point I would evaluate OpenSearch and its k-nearest neighbours (k-NN) search as a dedicated vector engine. **OpenSearch k-NN** spreads the index over several nodes and rebuilds without blocking one database.

The key design decision is that the change stays behind the **same retriever interface**. `search-service` calls a LangChain retriever. A new retriever class can use OpenSearch, and `conversation-service` and `recommendation-service` do not change.

Before that point, there are cheaper steps. The embeddings are already stored as `halfvec(512)`, half-precision, which halves their size. Reads already go to `search-db-replica`, so another replica adds read capacity. The hash partitions also hide one risk: a **large tenant** with a big share of all chunks would dominate its partition. That tenant can get its own partition.

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

### Q2. How did you stop an autonomous pricing agent from setting a bad price?

**Brief answer**
The model never invents a price. It only chooses between prices that tested arithmetic computed, and plain Python guardrails check its choice. Small changes apply automatically, larger ones wait for a merchant, and a kill switch stops a tenant's pricing at once.

<details>
<summary><strong>Must cover</strong></summary>

- **deterministic candidates** — 3 to 5 prices from tested arithmetic
- **structured output** — a Pydantic proposal, not free text
- **guardrails in plain Python** — margin floor, MAP floor, maximum daily change
- **auto-apply band**
- **human approval** — expires after 24 hours
- **kill switch** — per tenant and global
- blocked status, rationale stored, table tests

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I did not let the model set a price. `compute_candidates` produces **deterministic candidates**: 3 to 5 prices from price elasticity, a competitor price index and days of stock cover. That is arithmetic the team can test.

The model, through the OpenAI software development kit (SDK), only chooses one of those candidates. It returns **structured output**: a `PriceProposal` Pydantic model with the chosen price and a rationale. A response that does not parse is rejected. The rationale is stored with the decision, so a merchant can see why a price changed.

Then the **guardrails in plain Python** check the choice. There are three rules from the tenant's pricing rule: a minimum margin, the minimum advertised price (MAP) floor, and a maximum change per day. They are plain code, so every price that ships has passed rules a unit test can prove. The candidate arithmetic and the guardrails have exhaustive table tests. A proposal that breaks a rule gets the status `blocked_by_guardrail` and is never applied.

A valid proposal then meets the **auto-apply band**. A change inside the band applies at once. A change outside it waits for **human approval** by a pricing manager. An approval that does not come within 24 hours expires, so an old proposal never applies to a changed market.

If something still goes wrong, there is a **kill switch**. Each tenant's pricing can be turned off through `pricing_rules.enabled`, and a global flag stops all runs.

The trade-off is that the model cannot find a price outside the candidate set. I accepted that, because a wrong price costs money directly, and the accuracy lost is small. The worst case is a bounded price error.

</details>

---

### Q3. What happened to prices when the OpenAI API was slow or down?

**Brief answer**
Pricing fails static. If the agent cannot run, no price changes, and the run is retried when the provider is back. A wrong price costs money, but a price that stays the same for a while does not.

<details>
<summary><strong>Must cover</strong></summary>

- **fail static** — no run, no change
- **token bucket** — per provider and model
- **retry with backoff and jitter** — on a 429
- **one run per SKU in flight** — `SET NX` with a 15-minute TTL
- **visibility timeout** — longer than the slowest run
- **five-minute target** — p95 about 2.8 minutes when healthy
- no personal data sent to OpenAI

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The pricing agents are the one place that calls OpenAI. So I designed them to **fail static**. If a run cannot finish, nothing changes: the old price stays, and nothing is shown as wrong. Pricing has no availability target of its own for this reason. It is best-effort.

Slowness is more common than an outage. The provider's quota, not the number of pods, sets the throughput. A Redis **token bucket** per provider and model keeps the platform under its quota. If OpenAI still returns 429, Celery schedules a **retry with backoff and jitter**. Jitter stops all the waiting tasks from retrying in the same second.

A slow provider can also create duplicates. New signals keep arriving while one run is waiting. So only **one run per SKU in flight** is allowed. The trigger takes a Redis key `pricing:inflight:{tenant_id}:{sku}` with `SET NX` and a 15-minute time to live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires")). Further signals for that SKU do not start a second run.

Celery on SQS has one more trap. If a task runs longer than the SQS **visibility timeout**, SQS delivers it a second time while the first copy still runs. Agent runs can take up to about 10 minutes, so the timeout on that queue must be longer than the slowest run plus the retry delay.

When the provider is healthy, the **five-minute target** holds with room to spare. A signal triggers a run in under 5 seconds, the queue wait is under 60 seconds at p95, and the graph takes about 40 seconds for three model calls. The price reaches the channels in under 60 seconds more. The total is about 2.8 minutes at p95.

Only `agent-worker` can reach OpenAI, and its calls hold product, price and signal data only.

</details>

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

### Q2. How did you arrive at the 35% cost cut?

**Brief answer**
A response cache avoids about a quarter of the calls, and token optimisation makes each remaining call about 13% cheaper. 0.75 × 0.87 is about 0.65 of the earlier spend per product, which is the 35% cut.

<details>
<summary><strong>Must cover</strong></summary>

- **content hash** — unchanged products never reach the model
- **response cache key** — model, prompt version, normalised attributes
- **two cache tiers** — Redis, then DynamoDB
- **about 25% of calls avoided**
- **token optimisation** — about 13% cheaper per call
- **0.75 × 0.87 ≈ 0.65**
- cached prompt prefix, same GTIN from several suppliers

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The saving comes from mechanisms applied in order.

First, unchanged content never reaches the model. Suppliers re-send whole catalogs, but the merge compares a **content hash** and only passes the roughly 5% of products that really changed. This decides what counts as work at all.

Second, a response cache. The **response cache key** is a [SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity")-256 hash of the model id, the prompt version and the normalised attributes. The lookup has **two cache tiers**: Redis `llm:` first, then the [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes") table `llm-response-cache`. Redis keeps entries 24 hours and DynamoDB 180 days. The cache hits more than you might expect. Variants of one parent product share attributes. Different suppliers of the same Global Trade Item Number ([GTIN](https://www.gs1.org/standards/id-keys/gtin "GS1 identifier that labels the same product across sellers and suppliers")) send the same product. In total, **about 25% of calls avoided**.

Third, **token optimisation** on the calls that remain:

- Attributes go in as compact `key: value` lines instead of JSON.
- HTML is already stripped in Glue.
- Supplier text is cut to 1,500 tokens.
- `max_tokens` is 350.
- The static style guide sits in a cached prompt prefix.

Together that makes each call about 13% cheaper.

The arithmetic is **0.75 × 0.87 ≈ 0.65** of the earlier spend per product, which is the 35% cut.

One condition: Bedrock prompt caching works only for certain models and above a minimum prefix length. The design docs mark it to confirm for the chosen model and Region before counting it in the saving. So in an interview I would say the cache and the input trimming carry the result, and the prompt prefix cache is the part to verify.

</details>

---

### Q3. How did you keep cached descriptions correct when you changed the prompt or the model?

**Brief answer**
The model id and the prompt version are part of the cache key. A change to either one makes every old entry a miss, so a new prompt can never be served an old answer. Rewriting the whole catalog then runs as a batch job.

<details>
<summary><strong>Must cover</strong></summary>

- **version in the cache key** — model id and prompt version
- **stale until the version changes** — the trade-off accepted
- **prompt version on the product row**
- **backfill through batch inference**
- **canary** — prompt changes follow the code path
- **schema validation and HTML sanitising** — before saving
- per-tenant token budget

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A response cache has one classic bug: you change the prompt, and the cache keeps serving answers from the old prompt. I avoided it by putting the **version in the cache key**. The key hashes the model id, the prompt version and the normalised input. A new prompt version or a new model produces new keys. Old entries are never read again, and they expire on their own.

The rule has a cost: an entry is **stale until the version changes**. If a description has a problem but the prompt stays the same, the cache keeps serving it. I accepted that, because the invalidation is clean and easy to reason about. A bad output is fixed by a new prompt version, not by deleting entries by hand.

Each product also stores its **prompt version on the product row**, in `seo_prompt_version`. So after a prompt change I can query exactly which products still have the old description.

Those products need new descriptions. A **backfill through batch inference** handles that. The job uses Bedrock batch inference instead of on-demand calls, so it does not use up the live quota that new imports need. A per-tenant daily token budget in Redis also pauses enrichment for a tenant whose budget is spent.

A prompt change is a code change, so it goes through the **canary** like any release. The prompt version is in the cache key, so canary output stays apart from stable output.

Model output is also untrusted text. Before a description is saved or pushed to a channel, it passes **schema validation and HTML sanitising**. The generation step has no tools, so text from a supplier cannot make the model take an action.

</details>

## R10. Data and AI pipelines — Function-calling tools

> Built custom function-calling tools with LangChain and Pydantic to enable [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") agents to execute secure inventory lookups and stock updates;

---

### Q1. What role did Pydantic play in the function-calling tools?

**Brief answer**
Each tool's arguments are a Pydantic model. LangChain turns that model into the schema the language model sees. Pydantic validates every call before the tool runs. So limits such as the size of a stock change sit in the schema, not in the prompt.

<details>
<summary><strong>Must cover</strong></summary>

- **`StructuredTool`** — arguments defined by a Pydantic model
- **JSON Schema for the model**
- **validation before execution**
- **limits in the schema** — change size, reason as an enum
- **validation error back to the model**
- **negative tests** — out-of-range change
- same Pydantic models across API, events and tools

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Every tool is a LangChain **`StructuredTool`** whose arguments are a Pydantic model. For example, the stock lookup takes a list of SKUs. The stock update takes `StockUpdateInput`.

LangChain turns the Pydantic model into a **JSON Schema for the model**, in JavaScript Object Notation (JSON). The large language model (LLM) sees field names, types and descriptions, and it produces a function call that should match. "Should" is the key word. A model can still produce a wrong type, a missing field or a silly value.

So the tool runs **validation before execution**. Pydantic parses the arguments first. The tool code runs only with a valid object.

I put the business **limits in the schema**, not in the prompt. `StockUpdateInput` limits `delta` to plus or minus 1,000 units. `reason` is an enum, not free text. An `idempotency_key` is required. A prompt can say "never change stock by more than 1,000", but the model can ignore a prompt. It cannot ignore a validator.

When validation fails, the tool returns the **validation error back to the model** as the tool result. The model usually corrects the call on the next step. The recursion limit stops it from trying forever.

The schemas have **negative tests** in Pytest. One sends a `delta` out of range and expects a rejection. Another sends a SKU from a different tenant and expects nothing to be found.

Using Pydantic here also meant one way of working across the platform. The same library defines the API bodies, the event payloads and the model outputs.

</details>

---

### Q2. How did you make sure an agent could only read or change stock that the user was allowed to touch?

**Brief answer**
The tool acts with the caller's own permissions, never more. The tenant comes from the verified token, not from the model. The user's own access token goes to the inventory service, and shoppers get a read-only set of tools.

<details>
<summary><strong>Must cover</strong></summary>

- **tenant is injected, never an argument** — a closure over the verified principal
- **prompt injection** — no parameter to put another tenant in
- **caller's own token** — forwarded to the inventory service
- **tool registry per principal** — shoppers read-only
- **read-only service token** — `inventory.read` for shopper chat
- **row-level security** — a second check in the database
- 403 if called anyway, untrusted text has no tools

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The model is not a security boundary. Anything a shopper types can reach it, so I assumed the model might ask for anything.

The first rule: the **tenant is injected, never an argument**. No tool schema has a `tenant_id` field. Each tool is built per request as a closure over the verified principal from the token. This defeats **prompt injection** aimed at other tenants. A message saying "look up the stock of tenant X" has no parameter to put X in.

The second rule: the tool uses the **caller's own token**. In the merchant copilot, `conversation-service` forwards the user's own access token to `inventory-service`. The user's role then limits the tool. A user whose role cannot adjust stock cannot do it through the copilot either.

The third rule: a **tool registry per principal**. Shoppers get read-only tools. The merchant copilot adds the stock update tool. Shoppers have no token of their own. So shopper chat calls `inventory-service` with a **read-only service token**: the client-credentials token of `conversation-service`, which Cognito issues with the `inventory.read` scope only. If the stock update tool were ever called in shopper chat, `inventory-service` would return 403.

Under all of this, PostgreSQL enforces **row-level security** ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")). Each transaction sets `app.tenant_id` from the verified claim, and the policy hides every row of another tenant. A bug that forgets the tenant filter returns no rows, not another tenant's rows.

Text from suppliers is also untrusted. The steps that process it run with no tools bound at all.

</details>

---

### Q3. What stopped a stock update from being applied twice when an agent or a network call retried?

**Brief answer**
Every stock update carries an idempotency key. The key, the stock change and the audit row are written in one transaction. A retry with the same key gets back the first response instead of changing stock again.

<details>
<summary><strong>Must cover</strong></summary>

- **idempotency key** — required in the tool schema
- **user confirmation** — an interrupt shows the exact change first
- **one transaction** — stock level, audit row, key
- **separate key table** — the partition column rule
- **stored response** — returned unchanged
- **audit trail** — actor type, user and agent run
- keys deleted after 48 hours, row `version`

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Retries happen at several levels. The model can call the same tool twice. The Hypertext Transfer Protocol ([HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Application protocol used to request and transfer web resources")) client can retry after a timeout. A Celery task can be delivered again. Stock is consistency-critical, so an update must never apply twice or go missing.

The base is the **idempotency key**. The tool schema requires it, and the inventory API takes it as the `Idempotency-Key` header on `POST /v1/inventory/adjustments`.

Before any write, the merchant copilot asks for **user confirmation**. It pauses the graph with a LangGraph interrupt and shows the exact change. Only the user's click resumes it. So the model cannot change stock on its own.

The write itself is **one transaction**. It updates `stock_levels`, appends a row to `stock_adjustments` and inserts the key into `idempotency_keys`. All three commit or none do.

The key lives in a **separate key table** for a reason. `stock_adjustments` is partitioned on `created_at`, and PostgreSQL requires a unique key on a partitioned table to include the partition column. A retry one second later has a new timestamp, so a unique key there would not catch it. The small, unpartitioned `idempotency_keys` table holds the guarantee instead.

A retry hits the primary key of that table. The service then returns the **stored response** unchanged. The caller cannot tell a retry from the first call, and stock moved once.

Every change also leaves an **audit trail** in `stock_adjustments`: `actor_type = 'agent'`, the user's `sub` as `actor_id`, and the `agent_run_id`. Keys older than 48 hours are deleted every hour, which is far longer than any retry window.

</details>

## R11. Continuous delivery — Deployment to EKS

> Deployed Docker-containerized microservices to AWS EKS clusters using Bitbucket Pipelines for automated CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") deployment;

---

### Q1. Which steps did your Bitbucket pipeline run between a pull request and new pods on EKS?

**Brief answer**
Tests first, then an integration run on Docker Compose and a migration check, then images built and pushed to Amazon Elastic Container Registry ([ECR](https://aws.amazon.com/ecr/ "Stores, scans and serves container images for deployment")), tagged by commit hash. The images go to staging with smoke tests, and after a manual gate a canary goes to production.

<details>
<summary><strong>Must cover</strong></summary>

- **unit and UI tests** — lint, type check, Pytest, React Testing Library
- **integration stack on Docker Compose**
- **migration check on an empty database**
- **image tagged by commit SHA** — never `latest`
- **scan on push** — a critical CVE fails the build
- **staging and a manual gate**
- pre-deploy migration Job, frontend to S3 and CloudFront, Glue and Lambda from the same pipeline

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline runs in Bitbucket Pipelines on every pull request, and the steps are ordered so the cheap checks fail first.

1. **Unit and UI tests.** Lint, the type check, Pytest unit tests and React Testing Library tests. They take minutes and catch most mistakes.
2. **Integration stack on Docker Compose.** The same Compose file developers use locally starts PostgreSQL with pgvector, Redis and Kafka. Integration tests run against real services, not mocks.
3. **Migration check on an empty database.** The step runs `alembic upgrade head` from nothing. A broken migration chain fails here, not during a production deploy.
4. **Image tagged by commit SHA.** Each service's Docker image is built and pushed to ECR. The tag is the commit's Secure Hash Algorithm (SHA) id, never `latest`. So every running pod maps to exactly one commit, and a rollback means deploying an older tag.
5. **Scan on push.** ECR scans each image when it arrives. A critical Common Vulnerabilities and Exposures ([CVE](https://www.cve.org/ "Public identifier for a known software security flaw")) finding fails the build.
6. **Staging and a manual gate.** The images deploy to a staging EKS cluster, and smoke tests run. A person then approves production.
7. The production release goes out as a canary.

Before a service's pods change, a Kubernetes Job runs `alembic upgrade head` against production. The migration must work with the previous release too, so the old pods keep running during the rollout.

The same pipeline ships the parts that are not containers. The console and the widget go to S3 with a CloudFront invalidation. Glue scripts and Lambda packages are versioned by commit SHA as well.

</details>

---

### Q2. How did the pipeline get permission to deploy into AWS?

**Brief answer**
Through [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect. Bitbucket Pipelines proves its identity to AWS with a short-lived token and assumes a deploy role. No long-lived AWS keys are stored anywhere.

<details>
<summary><strong>Must cover</strong></summary>

- **OIDC federation** — short-lived credentials per run
- **role limited to this repository**
- **least privilege** — push to ECR, deploy to EKS
- **no stored keys**
- **IAM roles for service accounts** — pods have their own roles
- Secrets Manager for runtime secrets

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The old way is to store an AWS access key in the CI settings. That key never expires, and a leak gives an attacker deploy rights until someone notices. I did not use it.

Instead, the pipeline uses OpenID Connect ([OIDC](https://openid.net/developers/how-connect-works/ "Identity layer on top of OAuth 2.0 for authenticating users")). With **OIDC federation**, Bitbucket issues each pipeline run a signed identity token. AWS trusts Bitbucket as an identity provider, checks the token, and returns temporary credentials for a deploy role. The credentials expire soon after the run.

The trust policy is a **role limited to this repository**. A pipeline in another repository in the same workspace cannot assume it.

The role follows **least privilege**. It can push images to ECR and deploy to EKS. It cannot read data stores or change IAM. So even a compromised pipeline step has a small blast radius.

The result is **no stored keys**: no long-lived AWS keys exist for deployment. That also helps with the System and Organization Controls ([SOC](https://www.aicpa-cima.com/topic/audit-assurance/audit-and-assurance-greater-than-soc-2 "Audit reports on a service organization's security, availability and confidentiality controls")) 2 audit, because the evidence comes from the pipeline's change record and the IAM audit trail.

Deploy identity and runtime identity are separate. Running pods use **IAM roles for service accounts**, one role per service, each listing only its own resources. For example, only `agent-worker` can read the OpenAI key from Secrets Manager. The pipeline deploys the pods but never holds their runtime permissions.

This area touches cloud identity, so I would always have it reviewed. A trust policy that forgets the repository condition would let any repository in the workspace deploy.

</details>

---

### Q3. How did you roll out a release so that a bad one could be undone quickly?

**Brief answer**
Every release starts as a canary with 10% of the replicas. A Bash step compares the canary with the stable version in Prometheus for 15 minutes and either promotes it or scales it to zero. Migrations are backward compatible, so a rollback never needs a database downgrade.

<details>
<summary><strong>Must cover</strong></summary>

- **canary Deployment** — 10% of the replicas behind the same Service
- **automated analysis** — a Bash step queries Prometheus
- **promotion thresholds** — 5xx within 0.5 points, p95 within 1.2 times
- **scale the canary to zero**
- **expand and contract** — no downgrade on rollback
- **prompt changes on the same path**
- split by replica count, not exact traffic weight

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Each release first runs as a **canary Deployment**. A `-canary` Deployment with 10% of the replicas shares the Kubernetes Service with the stable Deployment, so it gets roughly 10% of the traffic. The split is by replica count, not an exact traffic weight. With 10 or more replicas that is precise enough, and it needs no service mesh routing rules.

The decision is **automated analysis**, not a person watching a dashboard. A Bash step in the pipeline queries Prometheus for 15 minutes and compares the canary with stable.

The **promotion thresholds** are two. The canary's 5xx rate must be within 0.5 percentage points of stable. Its p95 latency must be within 1.2 times stable. If both hold, the canary is promoted to 100%.

If either fails, the step will **scale the canary to zero**. Stable never changed, so the rollback takes seconds and does not depend on the new code.

Database changes are the hard part of a rollback. I used **expand and contract**. A migration first adds, for example a new nullable column. The new code starts using it. A later release removes the old column. Every migration must be compatible with the previous release. So after a rollback the old code runs against the new schema, and I never run a downgrade migration under pressure.

**Prompt changes on the same path** matter for this platform. A new prompt or agent graph is a code change, so it also goes out as a canary. The prompt version is in the LLM cache keys, so the canary's outputs never mix with stable's cached outputs.

</details>

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

---

### Q2. How did you key and partition the order event stream in Kafka, and why?

**Brief answer**
The key is the tenant plus the order id. Kafka keeps order within a partition, so every lifecycle event of one order is read in sequence. Different orders spread across 12 partitions and are processed in parallel.

<details>
<summary><strong>Must cover</strong></summary>

- **partition key** — tenant and order id
- **ordering per order** — lifecycle events in sequence
- **12 partitions** — the upper bound on consumer parallelism
- **webhook de-duplication** — before the event exists
- **SQS absorbs bursts** — channels send webhooks in spikes
- **consumer groups** — each reader keeps its own offset
- **14-day retention** — replay after a bug
- acks from all in-sync replicas

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The topic is `orders.events`. Its **partition key** is `tenant_id:order_id`. Kafka guarantees order only inside one partition, and one key always goes to the same partition. So the key decides what stays in order.

I needed **ordering per order**. An order goes through about five lifecycle events, for example placed, shipped or cancelled. If "cancelled" were processed before "placed", inventory would release stock it never reserved. With the order id in the key, all events of one order are in sequence.

I did not need order across orders. So keying by order, not by tenant, spreads the load. A large tenant with many orders does not make one hot partition. The topic has **12 partitions**, which is also the upper bound on parallel consumers per group. At about 250 order events per second at peak, 12 is plenty.

Duplicates are handled before the event exists. Channels send webhooks to Lambda `webhook-ingest`. It checks the Hash-based Message Authentication Code ([HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")) signature and records the webhook id in DynamoDB `webhook-dedupe`, kept 7 days. This **webhook de-duplication** means a retried webhook does not create a second order. The Lambda then writes to SQS `order-ingest`. **SQS absorbs bursts**, so `order-service` consumes at its own pace. The Lambda returns 5xx on an error, and the channel retries.

`order-service` publishes through the outbox. Three **consumer groups** read the topic: analytics, pricing and inventory. Each keeps its own offset, so a slow analytics consumer never delays inventory.

The **14-day retention** is longer than on other topics. If a consumer has a bug, I can fix it and replay two weeks of orders. Producers use `acks=all` with a minimum of two in-sync replicas, so an acknowledged event survives a broker loss.

</details>

---

### Q3. What happened to catalog lookups when Redis went down at peak load?

**Brief answer**
They kept working. I sized PostgreSQL to serve the full 4,500 requests per second with an empty cache, so Redis cuts latency but does not supply capacity. Lookups get slower but stay under the 50 ms target.

<details>
<summary><strong>Must cover</strong></summary>

- **Redis for latency, not capacity**
- **database sized for a cold cache** — about 0.3 ms CPU per covered lookup
- **replica per shard** — automatic failover
- **degraded latency** — lookups near 50 ms, search about 160 ms
- **fail open** — a cache error is treated as a miss
- **verify with a replayed load** — buffer hit ratio
- single-flight lock prevents a stampede on refill

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I made one decision early: **Redis for latency, not capacity**. A cache that is needed for capacity is a single point of failure. When it goes down, the database gets the full load and falls over too.

So I made the **database sized for a cold cache**. A covered point lookup on `core-db` costs about 0.3 ms of CPU. 4,500 lookups per second is about 1.35 CPU-seconds per second, or about 17% of 8 virtual CPUs. Writes at about 300 per second, at about 2 ms each, add about 7%. Vacuum, replication and the outbox relays take the rest. The peak stays at or below 40% CPU even with Redis empty.

Redis itself rarely goes down completely. `cap-redis` runs in cluster mode, with a **replica per shard** and automatic failover. If one primary node fails, its replica takes over for that shard, which holds about a third of the keys.

If the whole cluster is lost, the effect is **degraded latency**. Catalog lookups stay under 50 ms at p95, but close to it. Search gets slower, from about 110 ms to about 160 ms on average, because query embeddings are no longer cached.

The services **fail open** on the cache. A Redis error or timeout is treated as a miss, and the request goes to PostgreSQL. A cache outage must not become an error for the shopper. When Redis comes back, the single-flight lock stops a stampede of refills on hot keys.

The 0.3 ms figure has a condition. It assumes the lookup index and the hot pages stay in `shared_buffers`. The design docs mark it to **verify with a replayed load** against a production-sized snapshot, checking the buffer hit ratio. I would not claim the cold-cache guarantee without that test.

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

---

### Q3. How did you keep per-tenant detail without overloading Prometheus?

**Brief answer**
I kept the tenant id out of Prometheus labels, because 800 tenants multiply every time series. Metrics carry a tenant tier instead, and the per-tenant detail lives in structured logs and in the agent runs table.

<details>
<summary><strong>Must cover</strong></summary>

- **label cardinality** — every label value is a new series
- **tenant tier label**
- **structured logs** — tenant, request, trace, run and node ids
- **agent runs table** — tokens and cost per run
- **one dashboard layer** — Grafana over Prometheus and CloudWatch
- redacted prompt sample, 30 days in CloudWatch then S3

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The issue is **label cardinality**. In Prometheus every distinct combination of label values is its own time series. A histogram already has a series per bucket. Adding `tenant_id` with 800 tenants to a per-node histogram, across graphs and nodes, multiplies the series count by 800. That uses a lot of memory and makes queries slow.

So the metrics use a **tenant tier label** instead, for example on `agent_run_cost_usd_total{graph, tenant_tier}`. A handful of tiers answers the operational questions: are enterprise tenants slower, which tier drives cost?

The per-tenant detail lives where cardinality is cheap.

**Structured logs** are JSON lines on stdout, shipped by Fluent Bit to CloudWatch Logs. Every line has `ts`, `level`, `service`, `tenant_id`, `request_id` and `trace_id`. Agent logs add `run_id` and `node`. So I can filter one tenant's slow run in CloudWatch Logs Insights, then open the trace by its id. Prompts and completions are not logged by default. A 1% sample, passed through a personal-data redactor, is logged for evaluation.

The **agent runs table**, `pricing.agent_runs`, stores tokens in and out, cost, status and timing for every pricing and trend run, per tenant. A per-tenant cost question is a Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Queries and manipulates data in a relational database")) query, not a Prometheus query.

All of this sits behind **one dashboard layer**. Grafana reads Prometheus for the application and agent metrics and CloudWatch for the AWS-managed services. I chose this over a hosted monitoring product because of its cost at this metric cardinality.

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

---

### Q2. How did you test the multi-step onboarding flow with React Testing Library?

**Brief answer**
I tested it the way a seller uses it. The tests fill in a step, try to move on with invalid data, and reload in the middle of the flow. They check what the seller sees, not the component's internal state.

<details>
<summary><strong>Must cover</strong></summary>

- **behaviour, not implementation** — query by role and label
- **step validation** — cannot move on with invalid data
- **resume after reload** — the flow opens at the saved step
- **stubbed API responses**
- **dashboard filters** — the other covered workflow
- **chart data, not pixels**

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

React Testing Library pushes you to test **behaviour, not implementation**. A test finds elements by role and label, as a user or a screen reader would. It types, clicks and checks what appears. It never reads a component's state or calls its methods. So a refactor that keeps the behaviour does not break the tests. That was also the reason I did not use Enzyme, which tests implementation details.

Onboarding is a critical workflow, because a seller who gets stuck does not become a customer. I covered two behaviours.

The first is **step validation**. A test fills a step with invalid data and clicks "Next". It expects an error message and the same step still showing. Then it fixes the data and expects the next step.

The second is **resume after reload**. The session is saved on the server after every step. A test renders the wizard with a saved session whose current step is, for example, the third one. It expects the wizard to open at that step with the earlier answers filled in.

The tests use **stubbed API responses** at the network level, so the component code runs unchanged.

The other covered workflow is **dashboard filters**: changing the date range or channel must update what the dashboard shows. For the D3 charts I test **chart data, not pixels**. The test checks the data the chart receives. Pixel tests would break on every style change and prove little about the numbers.

</details>

## R15. Testing and observability — Cursor and Codex

> Accelerated feature development and prototyping by integrating Cursor and Codex workflows into daily coding tasks.

---

### Q2. How did you make sure code written with Cursor or Codex was safe to merge?

**Brief answer**
AI-written code got no special path. It went through the same pull request review and the same pipeline gates as any other code, and I stayed the author responsible for it.

<details>
<summary><strong>Must cover</strong></summary>

- **developer tooling only** — no architectural role
- **same pipeline gates** — no special path
- **type check and tests**
- **migration check**
- **canary** — a production regression is rolled back
- **the author owns it** — review before merge

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Cursor and Codex were **developer tooling only**. They helped me write and prototype code faster. They had no role in the system's architecture, and nothing in production depends on them. The design docs record them that way and say nothing more. So I can describe the safety net around them, but not a specific workflow for each tool.

The safety net is that AI-written code gets the **same pipeline gates** as code I type myself. A pull request cannot skip any of them.

The first gates are the **type check and tests**. Python is type-checked and TypeScript runs in strict mode. Generated code often looks right but uses a wrong type or an API that does not exist, and the type check catches much of that. Pytest and React Testing Library then check behaviour. The integration tests run against real PostgreSQL, Redis and Kafka.

The **migration check** runs `alembic upgrade head` on an empty database. Generated migrations are a classic risk, for example a column drop that breaks the previous release. The expand-and-contract rule is reviewed by a person, because no tool knows the release order.

In production the **canary** is the last net. A release that raises the error rate or p95 latency is scaled to zero after the 15-minute analysis.

The most important rule is that **the author owns it**. If I merge code, I must be able to explain it in review.

</details>
