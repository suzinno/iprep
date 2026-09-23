# Responsibility Questions — Robotic & Industrial AI Intelligence Platform
> Auto-generated from the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") brief. Questions use only what the CV states; answers draw on the system design documents.

## Table of Contents
- [R1. Architecture — FastAPI service design](#r1-architecture--fastapi-service-design)
- [R2. Architecture — React review interfaces](#r2-architecture--react-review-interfaces)
- [R3. APIs — API Gateway edge](#r3-apis--api-gateway-edge)
- [R4. APIs — React Query server state](#r4-apis--react-query-server-state)
- [R5. Databases — DynamoDB and PostgreSQL](#r5-databases--dynamodb-and-postgresql)
- [R6. Databases — S3 storage](#r6-databases--s3-storage)
- [R7. Messaging — Step Functions pipelines](#r7-messaging--step-functions-pipelines)
- [R8. Messaging — Async AI processing](#r8-messaging--async-ai-processing)
- [R9. AI pipelines — LangChain and LangGraph](#r9-ai-pipelines--langchain-and-langgraph)
- [R10. AI pipelines — MCP tools](#r10-ai-pipelines--mcp-tools)
- [R11. AI pipelines — RAG retrieval](#r11-ai-pipelines--rag-retrieval)
- [R12. Security — tenant-aware access control](#r12-security--tenant-aware-access-control)
- [R13. Cloud infrastructure — Terraform and EKS](#r13-cloud-infrastructure--terraform-and-eks)
- [R14. Continuous delivery — GitLab pipeline](#r14-continuous-delivery--gitlab-pipeline)
- [R15. Performance — FastAPI and async paths](#r15-performance--fastapi-and-async-paths)
- [R16. Testing and observability — CloudWatch](#r16-testing-and-observability--cloudwatch)
- [R17. Testing and observability — Pytest, moto and React Testing Library](#r17-testing-and-observability--pytest-moto-and-react-testing-library)
- [R18. Testing and observability — Cursor as development environment](#r18-testing-and-observability--cursor-as-development-environment)

## R1. Architecture — FastAPI service design

> Designed [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") services for robotic data processing and [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") workflows, using dependency injection, and reusable service modules for high-concurrency application workloads;

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

### Q2. How did you structure the reusable service modules so that several services could share them, and where did you draw the boundaries?

**Brief answer**
I put logic that more than one service needs into small modules with one owner each: the token-budget check, the tenant context and the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") contracts. Each module takes its clients by injection, so the application programming interface ([API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data")), the workers and the Lambdas can all call it.

<details>
<summary><strong>Must cover</strong></summary>

- **token-budget module** — one owner, enforced in `run-validate-request`
- **tenant-context dependency** — shared by every service
- **Pydantic models** — one contract, also source of the gateway models
- **same image** — `agent-service-api` and `agent-worker`
- **clients by injection**
- package layout not fixed by the design

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I drew the boundary around rules, not around services. A rule that two services must apply in the same way gets one module. Then both services call it.

The clearest example is the **token-budget module**. Each tenant has a daily token budget, counted in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"). Three places need it. `run-validate-request` enforces it for pipeline runs. `agent-service-api` calls it before each assist answer. `platform-api` calls it only to reject a request early. If each place had its own copy, the three copies would drift. Then one path would let a tenant spend past its budget.

The **tenant-context dependency** is the second shared module. `platform-api`, `mcp-gateway` and the telemetry consumers all set `app.tenant_id` before they touch PostgreSQL. So row-level security applies to every writer in the same way.

The **Pydantic models** are the third. They are the request and response contract, and they also define the structured output schemas for the models. The API Gateway request models are generated from them in continuous integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")). So there is one source for every schema.

`agent-service-api` and `agent-worker` run the **same image**. The assist endpoint and the pipeline worker share the LangGraph code, the tool client and the prompt templates.

Every module takes its **clients by injection**. That is why a Lambda, a pod and a test can all use it.

The design docs do not fix the exact package layout. I would not claim a specific folder structure. The rule I applied was simple: one owner per rule, and no module reaches out to build its own clients.

</details>

---

### Q3. How did you split the platform into separate FastAPI services, and why not one service?

**Brief answer**
I split by how each part scales, where it may be reached from and how it fails. `platform-api` serves the core Representational State Transfer ([REST](https://en.wikipedia.org/wiki/REST "Architectural style for stateless, resource-oriented HTTP APIs")) API, `agent-service-api` serves synchronous assist, and `mcp-gateway` serves agent tools. One service would force one scaling rule and one exposure on work that needs different ones.

<details>
<summary><strong>Must cover</strong></summary>

- **`platform-api`** — core REST API and telemetry ingest
- **`agent-service-api`** — synchronous assist
- **`mcp-gateway`** — cluster-internal, reached only by agents
- **different scaling** — agent capacity follows the Bedrock quota
- **failure isolation**
- **stateless pods** — all state in the data stores
- **the cost** — more services to deploy and watch
- NetworkPolicy, three replicas across zones, workers behind queues

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

There are three FastAPI services on Amazon Elastic [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Service ([EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS")). Each one has a different job.

**`platform-api`** is the core REST API. It serves devices, telemetry ingest and queries, runs, outputs, reviews, datasets and audit lookups. Its load is many short requests.

**`agent-service-api`** serves the synchronous assist endpoint. One request can take several seconds, because it calls a model twice.

**`mcp-gateway`** serves the Model Context Protocol ([MCP](https://modelcontextprotocol.io/ "Open protocol that exposes tools and data to AI agents through a standard interface")) tools for agents. It has no public route. A Kubernetes NetworkPolicy lets only `agent-worker` and `agent-service-api` reach it.

The main reason for the split is **different scaling**. `platform-api` scales with request count. Agent capacity is sized to the Bedrock token quota, not to CPU. Adding agent pods beyond the quota only produces throttling. With one service, I could not scale these two separately.

The second reason is exposure. `mcp-gateway` reads telemetry, alarms and knowledge for any run. It should never be on the public edge. A separate service makes that a network rule, not a code rule.

The third reason is **failure isolation**. A slow model call in assist should not hold threads or connections that ingest needs. Ingest has a 99.9% availability target.

All services use **stateless pods**. Every service runs at least three replicas across three zones, so a pod can die at any time.

The workers, `agent-worker` and `celery-worker`, sit behind queues and are not Hypertext Transfer Protocol ([HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Application protocol used to request and transfer web resources")) services at all.

**The cost** is more services to deploy, version and watch. I kept the number small. I did not split `platform-api` further, because its parts share the same database, scaling rule and exposure.

</details>

## R2. Architecture — React review interfaces

> Developed React and TypeScript interfaces for AI-powered inspection, analysis, and generation-review workflows;

---

### Q2. Walk me through the generation-review workflow in the interface. What does a reviewer see, and what can they do with an AI output?

**Brief answer**
A reviewer opens a pending output and sees the content with its citations and its validation result. They approve, edit or reject it. Nothing can be exported until a person approves it, and an output that failed validation can never be exported.

<details>
<summary><strong>Must cover</strong></summary>

- **review queue** — outputs with `review_status` pending
- **citations and validation result**
- **approve, edit or reject**
- **new version on edit** — earlier versions stay unchanged
- **`completed_unvalidated`** — shown with its failures, never exportable
- **no self-approval** — reviewer differs from the requester
- **annotation canvas** — bounding boxes, held in Redux
- role check, work-order drafts

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The workflow starts in the **review queue**. It lists outputs whose `review_status` is `pending`. Inspection results, generated documents and work-order drafts start as `pending`. Analyses start as `not_required`, because they are advice and not exported.

When a reviewer opens an output, they see the content next to its **citations and validation result**. Citations point to the document chunks and tool results the agent used. The validation block shows each check that ran and whether it passed.

The reviewer can **approve, edit or reject**. Each decision creates a row in `reviews`. An edit creates a **new version on edit** in `ai_outputs`. The original version stays as it was. So the audit trail shows what the model wrote and what the person changed.

Some runs end as **`completed_unvalidated`**. That means the output still failed validation after two regenerations. The interface shows it with its failures, so the reviewer can see the problem. The export action is disabled for it, and the backend also refuses the export.

There is **no self-approval**. The backend checks that `reviews.reviewer_id` differs from `ai_runs.requested_by`. The interface hides the approve action in that case, but the backend is the authority.

For inspections, the reviewer works on an **annotation canvas**. It shows each image with the model's bounding boxes, defect type, severity and rationale. The reviewer can adjust or remove a finding. The canvas state and the unsaved review draft live in Redux, because they are client-only state.

Only `reviewer` and `tenant_admin` may review. The same screen approves work-order drafts that an agent proposed.

</details>

---

### Q3. What risks come with showing AI-generated content in a web interface, and how did your interface deal with them?

**Brief answer**
Two risks: the content could inject script into the console, and people could trust it more than they should. I rendered everything through React's escaping and never as raw HyperText Markup Language ([HTML](https://html.spec.whatwg.org/ "Markup format that structures content for web browsers")). I also labelled every output as generated by artificial intelligence (AI) and kept a human review step before export.

<details>
<summary><strong>Must cover</strong></summary>

- **script injection** — model output is untrusted text
- **React's escaping** — never raw HTML
- **exported artifact** — download from another origin
- **over-trust**
- **AI-generated label** — with model and prompt version
- **human review before export**
- EU AI Act, unvalidated outputs flagged, no edge caching

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first risk is **script injection**. Model input includes text the platform does not control, such as documents, maintenance notes and text inside images. So a prompt injection could make the model write HTML or script into its output. If the console rendered that output as HTML, the script would run in the reviewer's session.

The console renders every output through **React's escaping**. It never uses raw HTML injection. Generated text shows as text, even when it contains tags.

The **exported artifact** is a second path. `run-persist-output` builds the HTML file from escaped Markdown. S3 serves it as a download with `Content-Disposition: attachment`, on a different origin from the console. So even a bad file cannot read the console's session.

The second risk is **over-trust**. A clean, confident report looks correct even when it is not. I dealt with it in three ways. Every output carries an **AI-generated label** with its model and prompt version. An output that failed validation shows its failures, and it cannot be exported. And there is always **human review before export** for inspections and generated documents. That gate also supports the EU AI Act work for EU tenants.

A smaller risk is caching. API responses are tenant-specific, so there is **no edge caching** of them in CloudFront. Only the static assets are cached.

These controls do not stop the model from following an injected instruction. They limit what that instruction can do in the browser.

</details>

## R3. APIs — API Gateway edge

> Exposed backend services through API Gateway with request validation, throttling, and [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf")-based authorization;

---

### Q1. Which OAuth2 flows did you use for the different clients of the API, and why?

**Brief answer**
Console users log in with the Authorization Code flow with Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")). Edge gateways and internal agents use the client credentials flow, and each gateway has its own client. Every caller has exactly one identity type.

<details>
<summary><strong>Must cover</strong></summary>

- **Authorization Code with PKCE** — the browser holds no secret
- **client credentials** — one app client per gateway
- **scopes** — say which kind of caller, not which role
- **token verified twice** — gateway authorizer, then `platform-api`
- multi-factor authentication, refresh token rotation, JWKS cache, OIDC federation

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

All identities come from one Amazon Cognito user pool, `platform-users`. There are three kinds of caller.

Console users use **Authorization Code with PKCE** through Cognito managed login. The single-page app runs in a browser, so it cannot keep a client secret. PKCE protects the code exchange without one. The access token lives 1 hour. The refresh token lives 12 hours and rotates on use. **Multi-factor authentication** ([MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity")) is required for `tenant_admin` and `auditor`. A tenant can also federate to its own identity provider through [OpenID](https://openid.net/ "OpenID — Federated identity standard letting a user authenticate once and reuse that identity across sites") Connect ([OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users")).

Edge gateways use **client credentials**. Each gateway has its own Cognito app client. That client maps to exactly one row in `core.devices`. So one gateway's credential can be revoked without touching the others. The gateway caches its token for the hour.

Agents that call `mcp-gateway` also use client credentials, with the scope `platform/mcp.tools`.

The **scopes** are coarse on purpose. `platform/api` says "a console user", and `platform/telemetry.write` says "a gateway". Roles are checked in `platform-api`, because a role is a tenant decision and not a token scope.

The **token verified twice** rule matters. The API Gateway Cognito authorizer checks signature, expiry and scope. Then `platform-api` verifies the token again against a cached JavaScript Object Notation ([JSON](https://www.json.org/json-en.html "Lightweight text format for structured data exchange")) Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")). If a request ever bypassed the gateway, the service would still reject it. The JWKS cache refreshes hourly and when an unknown key ID appears.

</details>

---

### Q2. How did you set up request validation at API Gateway, and how did you keep it in step with the service's own models?

**Brief answer**
API Gateway rejects malformed bodies before they reach a pod, and Pydantic in the service stays the authority. I generated the gateway models from the Pydantic models in CI, so the two cannot drift apart silently.

<details>
<summary><strong>Must cover</strong></summary>

- **validated twice** — at the gateway and in the service
- **Pydantic stays the authority**
- **generated in CI** — gateway models from Pydantic models
- **JSON Schema draft 4** — needs a conversion step
- **a passing and a failing request** — test in CI
- **ingest payload** — decompressed and checked in `platform-api`
- **422 before the queue** — a bad batch never blocks its group
- WAF body size limits, RFC 9457 problem details

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Every body is **validated twice**. API Gateway request models reject a malformed body at the edge. Then the Pydantic models in the service check it again. The gateway check saves pod time on bad traffic. But **Pydantic stays the authority**, because it runs next to the code that uses the data.

Two schemas for one body will drift if people write them by hand. So the gateway models are **generated in CI** from the Pydantic models. There is one source.

This has a known risk. API Gateway models use **JSON Schema draft 4**. Pydantic v2 emits JSON Schema 2020-12. So the export needs a conversion step. Some constructs, such as `anyOf` with `null`, may need rewriting. The check is to send **a passing and a failing request** against the generated models in CI. If the failing request passes, the conversion is wrong.

The **ingest payload** needs more than a schema. Gateways send a gzip payload encoded in base64. The gateway cannot look inside it. So `platform-api` decompresses and validates it, which the latency budget puts at about 15 ms. It rejects anything over 192 KB compressed. That keeps the message under the Amazon Simple Notification Service ([SNS](https://aws.amazon.com/sns/ "Managed publish-subscribe topics that fan one message out to many subscribers")) size limit after base64 encoding.

The **422 before the queue** rule is the important part. The telemetry queues are ordered per gateway. A malformed batch inside an ordered group would block every later batch from that gateway. So bad data must fail at the API, not in a consumer.

AWS Web Application Firewall ([WAF](https://owasp.org/www-community/Web_Application_Firewall "Filters and blocks malicious HTTP traffic before it reaches an application")) adds body size limits in front: 300 KB on ingest and 64 KB elsewhere. Errors use Request for Comments ([RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols")) 9457 problem details.

</details>

---

### Q3. How did you decide the throttling limits at API Gateway, and how did they fit with the other limits in the system?

**Brief answer**
Each limit protects a different thing, so I layered them. There is a per-IP rule at WAF, stage and method limits at API Gateway, per-tenant usage plans, and per-tenant run and token limits in the application. I sized the stage limit at about five times the estimated peak.

<details>
<summary><strong>Must cover</strong></summary>

- **WAF rate rule per IP** — plant users share one address
- **stage limit** — about five times the estimated peak
- **method limits** — tighter on ingest, run creation and assist
- **usage plans** — per-tenant API key meters ingest, never authenticates
- **application limits** — per-tenant run rate and token budget
- **integration timeout** — assist fits under 29 seconds
- Shield Standard, gateway paths excluded

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I started from the question "what does each limit protect?". The answer gave four layers.

The first is the **WAF rate rule per IP**. It allows 10,000 requests per 5 minutes per IP on console paths. One polling console makes about 160 requests in that time. A plant's users share one egress address, so the limit allows about 60 users behind one address. Gateway paths are excluded for the same reason.

The second is the API Gateway **stage limit**: 1,000 requests per second with a burst of 2,000. The estimated peak is about 200 requests per second. So the limit is about five times the peak. It protects the pods from a flood, not from normal growth.

The third is **method limits**. Ingest gets 300 requests per second. Run creation and assist get 20 per second each, because each call there costs model tokens.

The fourth is **usage plans**. Each gateway sends a per-tenant API key tied to a usage plan. It meters and caps each tenant's ingest. The key only identifies usage. It is never treated as authentication.

API Gateway cannot count tokens. So the **application limits** live in Redis. A counter caps AI run creation per tenant per minute. A daily token budget caps spend.

The **integration timeout** is a limit too. API Gateway's default is 29 seconds. Assist has a hard timeout of 25 seconds, so it always answers before the gateway times out. Larger questions become analysis runs.

Shield Standard covers volumetric attacks. These throttles cover fairness between tenants and cost.

</details>

## R4. APIs — React Query server state

> Implemented React Query for server-state management and asynchronous AI request handling, and built reusable components with React Router, Redux, TailwindCSS, and Vite;

---

### Q1. How did you divide state between React Query and Redux, and why?

**Brief answer**
React Query owns everything that comes from the server: caching, polling and invalidation. Redux owns only client state that the server never sees, such as the annotation canvas and unsaved review drafts.

<details>
<summary><strong>Must cover</strong></summary>

- **server state** — owned by React Query
- **client-only state** — owned by Redux
- **`staleTime` per resource** — outputs `Infinity`, a version never changes
- **mutations invalidate query keys**
- React Router, TailwindCSS, Vite with hashed assets

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The rule was simple: data that the server owns is **server state**, and React Query holds it. Data that exists only in the browser is **client-only state**, and Redux holds it.

Server state includes devices, alarms, run status and outputs. React Query caches it, fetches it again when it gets old, and polls runs while they are active.

Client-only state includes the annotation canvas for inspection images and the unsaved review draft. These change on every mouse move or key press. They are not saved until the reviewer submits.

The mistake I avoided is **copying server data into Redux**. Then there are two copies. One copy gets updated after a mutation and the other does not. The screen shows old data, and the bug is hard to find.

I set **`staleTime` per resource**, based on how fast the data changes. Devices use 60 seconds. Alarms use 15 seconds. Run status uses 0, with polling while the run is active.

**Outputs never go stale**, so their `staleTime` is `Infinity`. An edit creates a new version with its own ID. The content of one version never changes, so there is nothing to fetch again.

After a write, **mutations invalidate query keys**. For example, a review decision invalidates that output and the review queue. React Query then fetches the new state from the server. The client does not guess it.

React Router handles the screens, TailwindCSS the styling and Vite the build. Vite gives assets hashed file names, so CloudFront can cache them for a year.

</details>

---

### Q2. How did the interface handle an AI request that takes minutes, from the click to the result, and why did you choose that approach?

**Brief answer**
The click sends a `POST` with an idempotency key and gets back `202` with a `run_id`. React Query then polls the run every 3 seconds until it reaches a terminal status. I chose polling over a push channel because it uses the existing REST edge and stays bounded at this scale.

<details>
<summary><strong>Must cover</strong></summary>

- **`Idempotency-Key`** — a double click creates one run
- **`202` with a `run_id`**
- **poll every 3 seconds** — stops on a terminal status
- **fetch the output**
- **polling vs push** — bounded at about 50 queries per second
- **about 1,000 concurrent runs** — where push becomes worth it
- cancel, second authorizer path

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The flow has four steps.

First, the user starts an analysis. The console sends `POST /v1/analyses` with an **`Idempotency-Key`** header. If the user clicks twice, or the network retries, the backend returns the same run. A unique index on `(tenant_id, idempotency_key)` enforces that.

Second, the API answers **`202` with a `run_id`** in well under a second. It does not wait for the model.

Third, React Query starts to **poll every 3 seconds** on `GET /v1/runs/{run_id}`. The query sets its refetch interval only while the status is `queued`, `running` or `validating`. On `completed`, `completed_unvalidated`, `failed` or `cancelled`, polling stops. The user can cancel through `POST /v1/runs/{run_id}/cancel`.

Fourth, when the status has an `output_id`, the console will **fetch the output** once. It never changes, so it is cached with no expiry.

The design choice was **polling vs push**. At design load, up to 150 active runs polled every 3 seconds give at most 50 queries per second. That fits the REST edge, the authorizer and the caching I already had.

A WebSocket API in API Gateway would need connection state and a second authorizer path. It also needs reconnect handling in the browser. That cost is worth it only above **about 1,000 concurrent runs**, a number from the design estimate, not from production.

The trade-off is up to 3 seconds of delay before the user sees a result. For runs that take minutes, that delay does not matter.

</details>

## R5. Databases — DynamoDB and PostgreSQL

> Modeled DynamoDB tables for telemetry checkpoints and audit-log lookups, and designed PostgreSQL schemas, indexes, and SQLAlchemy/[Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") migrations for operational and AI-generated data;

---

### Q1. How did you decide which data went to DynamoDB and which went to PostgreSQL?

**Brief answer**
Relational, transactional or tenant-filtered data went to PostgreSQL. High-rate key-value writes and append-only lookups went to DynamoDB. That put the telemetry checkpoints and the audit log in DynamoDB, and everything else in PostgreSQL.

<details>
<summary><strong>Must cover</strong></summary>

- **the storage rule** — access pattern decides the store
- **telemetry checkpoints** — conditional writes kept off PostgreSQL
- **audit log** — not written to the database it audits
- **consistency per store** — PostgreSQL consistent, telemetry eventually consistent
- **no sharding** — one PostgreSQL primary is enough
- TTL and Streams, joins and row-level security

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used **the storage rule**: each store holds the data whose access pattern it serves best.

PostgreSQL holds tenants, devices, alarms, maintenance history, rollups, runs, outputs, reviews, inspections and document embeddings. This data needs joins, transactions and row-level security. A review decision must never be lost or applied twice.

DynamoDB holds two tables.

The first is the **telemetry checkpoints** table. Three consumers each record how far they got for each gateway. At design load that is about 81 conditional writes per second. Each write only needs consistency within one item. That load does not belong on the main database, where it would compete with user queries.

The second is the **audit log**. It records every mutation, sensitive read and AI tool call. It is append-only and read by key. DynamoDB also gives time to live ([TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires")) for expiry and Streams for the archive. And there is a design reason: if audit writes went to PostgreSQL, a problem with that database would also stop the audit trail of that problem.

The choice also sets **consistency per store**. PostgreSQL is the consistent store. During a failover, it rejects writes rather than let them diverge. The telemetry path chooses availability, and a reader may see status up to 30 seconds old. In DynamoDB, a checkpoint update is consistent within its item. Audit lookups through a secondary index are eventually consistent.

**No sharding** was needed. The five-year estimate is about 650 GB and under 2,000 row writes per second. That fits one PostgreSQL primary with a standby.

</details>

---

### Q2. How did you design the DynamoDB keys for the telemetry checkpoints and the audit-log lookups?

**Brief answer**
Checkpoints are keyed by gateway with the consumer name as the sort key, and updated with a conditional write. Audit events are keyed by tenant and resource, with two secondary indexes for lookups by actor and by day, and every key starts with the tenant.

<details>
<summary><strong>Must cover</strong></summary>

- **gateway as partition key** — consumer name as sort key
- **conditional update** — only moves the watermark forward
- **gaps**
- **strongly consistent read** — for gateway replay
- **tenant first in every key** — lets IAM scope a session
- **two secondary indexes** — by actor, and by day in four shards
- **TTL and Streams** — archive before expiry

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

`telemetry_checkpoints` uses the **gateway as partition key** and the consumer name as the sort key: `archiver`, `rollup` or `rules`. Each item holds `high_watermark_seq`, `last_batch_id`, `gaps` and `updated_at`. The table has about 1,200 items. The load is the write rate, not the size.

A consumer skips a batch whose sequence is at or below the watermark. After it applies a batch, it runs a **conditional update**. The condition is `high_watermark_seq < :seq`, or the attribute does not exist yet. So a late or repeated message can never move the watermark back.

If the new sequence is more than one above the watermark, the missing range goes into **gaps**. The list holds at most 20 ranges. A gap means data the gateway lost, so it raises an alarm.

When a gateway reconnects, `GET /v1/telemetry/checkpoints/{gateway_id}` reads the archiver item with a **strongly consistent read**. So the gateway replays from exactly the right place.

`audit_log` uses a partition key of `T#<tenant_id>#R#<resource_type>#<resource_id>`. The sort key is the timestamp plus an event ID. So the main lookup, "history of this resource", is one query.

The **tenant first in every key** rule is for security. An Identity and Access Management ([IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources")) condition on `dynamodb:LeadingKeys` can then limit a tenant-scoped session to its own keys.

There are **two secondary indexes**. `by_actor` answers "what did this user do". `by_day` answers "what happened on this day". The **sharded day index** splits each day into four shards, so a busy day does not load one partition.

**TTL and Streams** handle retention. `expires_at` is set 400 days ahead. DynamoDB Streams feed `audit-archiver`, which writes to S3 before TTL removes the item.

</details>

---

### Q3. How did you design the PostgreSQL schemas, indexes and migrations so that the database could grow and change without downtime?

**Brief answer**
I split the database into four schemas, partitioned the large time-series tables by time, and gave every index a named query. Alembic migrations follow expand and contract and build indexes concurrently, so the running version keeps working during every deploy.

<details>
<summary><strong>Must cover</strong></summary>

- **four schemas** — `core`, `telemetry`, `ai`, `agent_state`
- **time partitions** — retention is a `DROP`
- **partial indexes** — each one serves a named query
- **heap-only updates** — `fillfactor` 70 on rollups
- **expand and contract**
- **`CREATE INDEX CONCURRENTLY`** — per partition, then attached
- **migration Job** — runs before new pods roll out
- migration role for extensions

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The database has **four schemas**. `core` holds operational data such as devices and alarms. `telemetry` holds rollups. `ai` holds runs, outputs, reviews and documents. `agent_state` holds the LangGraph checkpointer tables, and only the agent worker's role can reach it.

Growth comes mainly from rollups. So `rollups_5m` and `rollups_1h` use **time partitions**: daily and monthly. Retention is a `DROP` of the oldest partition. There is no mass `DELETE` and no vacuum debt. A scheduled task creates partitions days ahead, and an alarm fires if tomorrow's partition is missing.

Every index answers a named query. Several are **partial indexes**:

- One active alarm per device and rule: unique on `(device_id, rule_id)` where the state is open or acknowledged.
- The stale-run sweeper: runs where the status is queued, running or validating. It stays small because finished runs leave it.
- The review queue: outputs where `review_status` is pending.

Rollups change about 1,500 rows per second at design load. I set **heap-only updates** as the goal: `fillfactor = 70` and no index on the aggregate columns. Then an update does not rewrite indexes.

For change, Alembic owns every table, index and policy. Migrations follow **expand and contract**. A new column is added as nullable, backfilled, then made required in a later release. So old pods keep working, and a code rollback never needs a down-migration.

Indexes use **`CREATE INDEX CONCURRENTLY`** in an autocommit block. On partitioned tables I build it per partition and then attach it to the parent.

The **migration Job** runs in Kubernetes before new pods roll out. `CREATE EXTENSION` runs under a migration role. The application roles do not have those rights.

</details>

## R6. Databases — S3 storage

> Configured AWS S3 for robotic datasets, generated assets, and intermediate AI processing artifacts;

---

### Q1. How did you organise the S3 buckets and object keys, and how did you manage the data over time?

**Brief answer**
One bucket per data class, and every key starts with the tenant, so IAM can scope access by prefix. Lifecycle rules move raw data to cheaper tiers and expire intermediate AI artifacts after 14 days, while final outputs are kept.

<details>
<summary><strong>Must cover</strong></summary>

- **one bucket per data class**
- **tenant prefix first** — `tenant=<tenant_id>/`
- **deterministic key** — a repeated archive write overwrites itself
- **lifecycle tiers** — raw telemetry to archive tiers
- **intermediate artifacts** — pointers between steps, expire at 14 days
- **finding-free images deleted** — tag-based rule after one year
- **KMS key per data class**
- versioning on datasets, public access blocked, TLS only

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used **one bucket per data class**: `telemetry-raw`, `robotic-datasets`, `ai-artifacts` and `audit-archive`. Each bucket has its own lifecycle, and each data class has its own encryption key. A mixed bucket would need complex rules to tell them apart.

Every key has the **tenant prefix first**, as `tenant=<tenant_id>/`. An IAM policy can then limit a tenant-scoped session to its own prefix.

Raw telemetry uses a **deterministic key**: gateway, date, then the first and last sequence number. If a batch is delivered twice, the archiver writes the same key again. There is no duplicate object.

**Lifecycle tiers** control cost. Raw telemetry moves to Standard-Infrequent Access at 30 days, Glacier Instant Retrieval at 90 and Deep Archive at 365. It is deleted at 5 years. The five-year estimate is about 330 TB, so tiering matters more than anything else here.

`ai-artifacts` has two prefixes. **Intermediate artifacts** go under `intermediate/`. Step Functions caps state payloads at 256 KB, so each pipeline state writes its data to S3 and passes a pointer. These objects expire at 14 days, which also leaves an inspectable record of each step for that time. Final outputs go under `outputs/` and are kept.

`robotic-datasets` is versioned. Inspection originals are uploaded with the tag `has_finding=false`. `run-persist-output` changes the tag on images that have findings. **Finding-free images deleted** after one year is a lifecycle rule on that tag. It supports the privacy work, because workers can appear in images.

Every bucket uses a Key Management Service ([KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use")) key, a **KMS key per data class**, with S3 Bucket Keys. All buckets block public access and refuse requests without Transport Layer Security ([TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Encrypts and authenticates data sent over a network connection")).

</details>

---

### Q2. How did large datasets and images get into S3 — through your API or around it?

**Brief answer**
Around it. The API creates the record and returns pre-signed upload URLs, and the client uploads straight to S3. The URLs are signed with a tenant-scoped session, so they cannot reach another tenant's prefix.

<details>
<summary><strong>Must cover</strong></summary>

- **declared size and SHA-256**
- **pre-signed upload URLs** — multipart for datasets
- **tenant-scoped session** — a tampered key is still refused
- **complete or start call** — client says the upload is done
- **status row** — `uploading`, `processing`, `ready`, `failed`
- **metadata stripped** — before any model sees an image
- why not through the API, Celery media queue

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Uploads go around the API. Recorded datasets add about 1 TB a month in the estimate, and a single file can be large. Sending that through API Gateway and a pod would hit body limits and use pod memory. It would also pay for the same bytes twice.

The client first calls `POST /v1/datasets` or `POST /v1/inspections`. It lists each file with a **declared size and [SHA-256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity")**. [SHA](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm — Family of cryptographic hash functions used to verify content integrity")-256 is the Secure Hash Algorithm 256-bit digest of the file. The API creates the record and returns **pre-signed upload URLs**. Datasets use multipart upload, so a large file can resume after a failure.

The URLs are signed with a **tenant-scoped session**. `platform-api` assumes the `tenant-data-access` role with a session tag for the tenant. That role only allows keys under that tenant's prefix. If someone edits the key in a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web"), S3 still refuses the request.

When the upload finishes, the client makes a **complete or start call**. For a dataset that is `POST /v1/datasets/{id}/complete`. For an inspection it is `POST /v1/inspections/{id}/start`, and it only works once every image is uploaded.

The dataset then moves through its **status row**: `uploading`, `processing`, then `ready` or `failed`. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") jobs on the `media` queue build manifests and thumbnails. A sweeper picks up any dataset that stays in `processing` for more than 15 minutes.

For inspections, `image-preprocess` resizes each image and writes it to `intermediate/`. At that step, each image also gets its **metadata stripped**. The model only sees the cleaned copy.

</details>

## R7. Messaging — Step Functions pipelines

> Designed AWS Step Functions state machines orchestrating multi-step AI analysis, generation, and validation pipelines with retries and failure handling;

---

### Q1. Why did you use Step Functions for these pipelines, and did you choose Standard or Express workflows?

**Brief answer**
Our AI runs are multi-step, can take many minutes, and need retries and a history per run, so Step Functions fit well. We used Standard workflows because Express workflows are too short-lived and do not support the callback step our agent needs.

<details>
<summary><strong>Must cover</strong></summary>

- **Standard workflow** — a run can outlast the Express five-minute limit
- **execution history**
- **callback pattern**
- **Map state** — MaxConcurrency bounds parallel image and section work
- **claim-check** — state passes S3 pointers, not content
- cost per state transition

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

We had three state machines: `analysis-pipeline`, `inspection-pipeline` and `generation-pipeline`. All three are a **Standard workflow**. An Express workflow can run for at most five minutes. Our target for a generation run was under 15 minutes at the 95th percentile (p95), and a run with two regenerations can take about 9 minutes. So duration alone excluded Express.

Standard workflows gave us two more things we needed. The first is a full **execution history** for every run. Each execution is named after its `run_id`, so on-call engineers can open one run and see every state, input pointer and error. The second is the **callback pattern**. The agent step does not run in Lambda. Step Functions puts a message with a task token on the Amazon Simple Queue Service ([SQS](https://aws.amazon.com/sqs/ "Managed message queue that decouples producers from consumers")) queue `agent-tasks`. A worker on EKS returns the result with that token. Express workflows do not support this wait-for-token integration.

The three pipelines share one shape: validate the request, set the run to running, build context, run the agent, validate the output, persist it, and publish an event. The inspection pipeline uses a **Map state** for image preprocessing (MaxConcurrency 10) and another for vision tasks (MaxConcurrency 5). The generation pipeline drafts sections in a Map with MaxConcurrency 4. The vision and section limits protect the model quota.

Step Functions limits a state payload to 256 KB. So every state passes a **claim-check**: a pointer to an object under `intermediate/` in S3, not the content itself.

The alternative was Celery chains. Celery has no durable per-step state and no visual history for long runs. The cost of our choice is a second system and about 50–100 ms per state transition. That cost is small next to model calls of 8–10 seconds.

</details>

> **Footnotes:**
> - **Claim-check pattern:** A message carries a reference to data kept in a store, and the receiver fetches the data itself. It keeps large payloads out of size-limited messages.

---

### Q2. How did you set up retries and failure handling in the state machines? Which errors did you retry, and what happened when the retries ran out?

**Brief answer**
Each kind of error had its own retry policy, with backoff sized to the failure it covers. Anything that still failed went through a `Catch` to one failure state, which recorded an error code and a metric.

<details>
<summary><strong>Must cover</strong></summary>

- **retry policy** — different per error type
- **backoff** — step retries span longer than a database failover
- **heartbeat timeout**
- **Agent.Throttled** — about 15 minutes of waiting before failing
- **Catch** — every state routes to `MarkFailed`
- **error_code**
- **idempotent start** — execution name equals `run_id`
- GenerationFailures, budget_exceeded, model_unavailable

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I set a separate **retry policy** for each kind of error, because each error has a different cause and a different recovery time.

- **Step Lambdas.** We retried `Lambda.ServiceException`, `Lambda.TooManyRequestsException` and database errors. The interval is 5 s with **backoff** ×2 and 5 attempts. That spans about 155 s. A PostgreSQL failover takes 60–120 s, so a step can survive a failover without failing the run.
- **The agent step.** We retried `States.HeartbeatTimeout` and `States.Timeout` with 30 s, ×2, 2 attempts. A **heartbeat timeout** means the worker pod has probably crashed. The retry sends a new task token, and the new attempt resumes from the last LangGraph checkpoint.
- **Model throttling.** The worker raises **Agent.Throttled** when Bedrock keeps throttling after the adaptive retry built into the software development kit ([SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform")). We retried it with 60 s, ×2, 4 attempts. That is about 15 minutes of waiting before the run fails with `model_unavailable`.

Some errors are never retried. A request over the tenant's token budget fails at once with `budget_exceeded`, because a retry cannot fix it.

When retries run out, a **Catch** on every state routes to `MarkFailed`. That state calls the `run-set-status` Lambda. It records the **error_code** on the `ai_runs` row and emits the `GenerationFailures` metric. So the user always sees a terminal status, and on-call sees the failure grouped by cause.

Retries only work if repeats are safe. The API starts each execution with the name set to the `run_id`. This gives an **idempotent start**: a retried `StartExecution` with the same name and input returns the existing execution. `ai_outputs` also has a unique key on run and version, so a repeated write cannot create a duplicate version.

</details>

---

### Q3. How did the validation step in your pipelines work, and what happened when an AI output failed it?

**Brief answer**
The validation step ran the cheapest checks first and stopped at the first failure. A failed output went back to the agent with the failures as feedback, up to two times. After that, the output was kept but marked so it could never be exported.

<details>
<summary><strong>Must cover</strong></summary>

- **cheapest first** — stops at the first failed check
- **schema validation**
- **citation check** — every cited source was retrieved in this run
- **numeric grounding**
- **grounding review** — a small model, only after deterministic checks pass
- **regeneration** — failures fed back, at most twice
- **completed_unvalidated** — kept and reviewable, never exportable
- self_check, latency against accuracy

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The `run-validate-output` Lambda owns validation. It runs the checks **cheapest first** and stops at the first failure.

1. **Schema validation** against the Pydantic model for the output kind. It takes about 50 ms.
2. A **citation check**. Every chunk or tool result the output cites must have been retrieved during this run. This catches invented sources.
3. **Numeric grounding**. Every number in the output must appear in the evidence, within a tolerance. A wrong torque value or temperature in a maintenance report is a real risk, so numbers get their own check.
4. Only then a **grounding review** by a Haiku-class model. It checks that the claims follow from the evidence. It takes about 2 s and about 10% extra tokens.

If a check fails, the state machine loops back to the agent step. It passes the failures in as feedback, and the run's `regen_count` goes up. We allowed **regeneration** at most twice. After two failed regenerations, `run-persist-output` saves the output and sets the run status to **completed_unvalidated**. A reviewer sees it together with the failures, but it can never be exported.

Why keep a failed output at all? Much of it may still be useful, and a reviewer can fix one bad claim faster than we can run a new analysis. The export block keeps an unchecked document from reaching a plant.

Inside the LangGraph workflow there is also a `self_check` node. That is the model checking itself. The pipeline step is the authority, and it is deterministic wherever possible.

The trade-off is latency against accuracy. Two regenerations can push an analysis from about 2 to about 4.5 minutes. We accepted that, because a wrong maintenance instruction costs more than a slow one. The target was that fewer than 5% of runs need two regenerations.

</details>

## R8. Messaging — Async AI processing

> Developed async AI processing with AsyncIO, Celery (Redis broker), SQS with SNS fan-out, and Lambda for long-running tasks;

---

### Q1. You list AsyncIO, Celery, SQS with SNS, and Lambda. How did you decide which one handled which kind of work?

**Brief answer**
One rule decided it: who starts the work, how long it runs, and what code it needs. AsyncIO handled concurrency inside every process, Celery took short app jobs, Lambda behind SQS took event-driven work, and Step Functions with an SQS callback took the long AI runs.

<details>
<summary><strong>Must cover</strong></summary>

- **AsyncIO** — concurrency inside one process, not a job system
- **Celery** — app-started, under 10 minutes, restartable from a status row
- **Lambda behind SQS** — event-driven, stateless, under 15 minutes
- **SQS callback** — steps that need the LangGraph stack
- **acks_late**
- **noeviction** — a separate broker the cache cannot evict from
- **sweeper** — re-enqueues jobs stuck for 15 minutes
- visibility_timeout, task_time_limit, results ignored

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

These tools answer different questions, so I gave each one a clear job.

**AsyncIO** is not a job system. It runs inside every service, worker and Lambda. It lets one process wait on hundreds of model, database and AWS calls on few threads.

For background jobs I used one rule:

- **Celery** takes work that the app starts itself and that finishes in under 10 minutes. The work needs the app's object-relational mapping ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) and code, and it can restart from a PostgreSQL status row. Examples are document parsing and embedding, thumbnails, partition upkeep and hourly rollups.
- **Lambda behind SQS** takes event-driven, stateless work under 15 minutes that AWS triggers. Examples are the three telemetry consumers, webhooks, follow-ups and the audit archive.
- Step Functions takes multi-step work that needs per-step retries and a history: the three AI pipelines.
- An **SQS callback** to `agent-worker` takes a pipeline step that needs the LangGraph stack and may run for minutes.

Celery needed care to be reliable. We set **acks_late** so a task is acknowledged only after it finishes. `task_time_limit` is 600 s, and the broker `visibility_timeout` is 3,600 s. The timeout is longer than any task, so a slow task is never delivered twice. Results are ignored; job state lives in PostgreSQL rows such as `datasets.status`.

Celery runs on its own Redis, `celery-broker`, with **noeviction**. The cache Redis uses `allkeys-lru`. If they shared one cluster, cache eviction could delete a queued job. The broker's replication is asynchronous, so a failover can still lose messages. A `celery-beat` **sweeper** covers that: it re-enqueues any dataset or document stuck in `processing` or `pending` for more than 15 minutes.

The mistake I avoided is using one tool for everything. Celery chains for AI runs would lose durable history. Lambda for agent steps would hit the 15-minute limit.

</details>

---

### Q2. How did you use SNS fan-out with SQS, and how did you keep the consumers correct when a message arrived twice or out of order?

**Brief answer**
Each telemetry batch went to an SNS First In, First Out ([FIFO](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-fifo-queues.html "Queue and topic mode that preserves message order within a group and removes duplicates")) topic that fanned out to three ordered SQS queues, one per consumer, grouped by gateway. Each consumer skipped what it had already seen, applied an effect that is safe to repeat, and then advanced its checkpoint.

<details>
<summary><strong>Must cover</strong></summary>

- **SNS FIFO** — fan-out to three ordered queues, one per consumer
- **message group** — the gateway ID; ordering is per gateway
- **deduplication ID** — the `batch_id`, over a five-minute window
- **high watermark** — skip any batch at or below it
- **idempotent effect**
- **conditional update** — the checkpoint only moves forward
- **dead-letter queue (DLQ)** — only that gateway's group is blocked
- exactly-once effect, last_seq guard, ai-run-events

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

`platform-api` publishes each telemetry batch to `telemetry-batches.fifo`, an SNS topic in **SNS FIFO** mode. The topic fans out to three FIFO queues: archive, rollup and rules. A Lambda reads each queue. So each consumer fails, retries and scales on its own.

The **message group** is the gateway ID. Order holds per gateway, and one slow gateway never blocks another. The **deduplication ID** is the `batch_id`, so SNS drops a retry within five minutes.

Longer-range duplicates still happen, for example when a gateway replays its buffer after an outage. So every consumer follows three steps:

1. Read its checkpoint in DynamoDB and skip any batch whose `seq` is at or below the **high watermark**.
2. Apply the batch with an **idempotent effect**. The archiver writes to a deterministic S3 key. The rollup upsert only changes a row when `last_seq` is lower than the new one. The rules consumer relies on a partial unique index that allows one active alarm per device and rule.
3. Advance the checkpoint with a **conditional update**. It succeeds only if the stored watermark is lower than the new `seq`.

A crash between step 2 and step 3 causes a redelivery. The idempotent effect absorbs it. The checkpoint and the effect live in different stores, so neither one alone could guarantee this. Together they give an exactly-once effect on top of at-least-once delivery.

A poison message is different. After 5 receives it moves to the **dead-letter queue ([DLQ](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html "Dead-Letter Queue — Holds messages that failed processing repeatedly so they can be inspected and redriven"))**. For about 5 minutes only that gateway's group is blocked. An alarm fires on any DLQ message, and we redrive after the fix. Malformed batches never get this far: `platform-api` rejects them with `422` at ingest.

The same fan-out idea serves run events. `ai-run-events` fans out to the webhook and follow-up queues, so a new subscriber never changes the pipelines.

</details>

---

### Q3. Lambda has a 15-minute limit. How did you run AI tasks that could take longer than that?

**Brief answer**
The agent step ran on a worker pool on EKS, not in Lambda. Step Functions sent the task with a callback token through SQS and waited. The worker sent heartbeats while it worked and returned the result with the token.

<details>
<summary><strong>Must cover</strong></summary>

- **task token** — Step Functions waits until the worker returns it
- **long-poll**
- **deletes the message** — right after recording the token
- **SendTaskHeartbeat** — every 60 s against a 180 s heartbeat limit
- **resume** — from the last LangGraph checkpoint
- **Bedrock quota** — sets worker capacity, not CPU
- queue age alarm, TimeoutSeconds 900

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The agent step can take minutes and needs the full Python AI stack. So it runs on `agent-worker`, a deployment on EKS. The state machine uses the `sqs:sendMessage.waitForTaskToken` integration. It puts a message with a **task token** on `agent-tasks` and waits.

The worker protocol has four rules.

- The worker uses **long-poll** reads on `agent-tasks`.
- It records the task token and then **deletes the message** at once. Retrying belongs to Step Functions alone. If SQS also redelivered the message, one failure could run twice.
- While it works, it calls **SendTaskHeartbeat** every 60 s. The task state sets `HeartbeatSeconds: 180` and `TimeoutSeconds: 900`. If a pod crashes, Step Functions notices within 3 minutes and retries the step with a new token.
- A retried attempt uses the same LangGraph thread. So it can **resume** from the last checkpoint and does not repeat completed model and tool calls.

At the end the worker calls `SendTaskSuccess` with a pointer to its output in S3, or `SendTaskFailure` with an error.

Capacity was the interesting part. Each pod runs up to 16 tasks at once on AsyncIO. Four replicas give 64 slots against about 25 concurrent tasks at the estimated peak. The limit is the **Bedrock quota**, not CPU. More pods than the quota allows only produce throttling. So the replica count changes when the quota changes, and bursts wait in `agent-tasks`. A queue age alarm fires when the oldest message is older than 600 s.

</details>

## R9. AI pipelines — LangChain and LangGraph

> Built LangChain pipelines on AWS Bedrock for contextual analysis and tool execution, and LangGraph workflows for multi-step reasoning, state management, and validation;

---

### Q1. Where did you use LangChain on its own, and where did you need LangGraph?

**Brief answer**
LangChain gave us the building blocks — model and tool bindings, retrievers and structured output — and ran the short synchronous assist chain alone. LangGraph ran every multi-step run, because those need loops, explicit state and a way to resume after a crash.

<details>
<summary><strong>Must cover</strong></summary>

- **bindings** — for Bedrock models, MCP tools and retrievers
- **structured output**
- **assist chain** — synchronous and bounded by a timeout
- **explicit state**
- **checkpointer** — resumable state after a crash

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I used LangChain as the layer that talks to models and tools. It gave us **bindings** for Bedrock models, for the MCP tools, and for the retrievers. It also gave us **structured output**: the model returns data that must match a Pydantic schema for the output kind.

On its own, LangChain ran the **assist chain**. Assist answers one small question about one device inside the request. It does one retrieval, one tool call and about two model calls. It has a hard timeout of 25 s, under API Gateway's 29 s limit. A straight chain is enough there. Anything larger becomes an analysis run.

Analysis, inspection and generation runs needed more. The agent plans, retrieves, calls tools, drafts, checks its own draft, and may loop back once. That is a graph with loops and branches, not a chain. LangGraph gave us three things here:

- **Explicit state** that every node reads and writes, so each step is easy to test and inspect.
- Conditional edges, for example from the self-check back to the tool step.
- A PostgreSQL **checkpointer**, so a crashed worker can resume the run from the last completed step.

The alternative was a hand-written loop around the model. It is simple at first. But it has no resumable state after a crash. Our agent steps can run for minutes, and Kubernetes can kill a pod at any time. With retries from Step Functions, a hand-written loop would repeat every model call from the start.

</details>

---

### Q2. Walk me through the nodes of your LangGraph workflow. How did state move between them, and where was it stored?

**Brief answer**
The graph had five nodes: plan, retrieve, act, draft and self-check, with one allowed loop back from self-check to act. State was saved after each step by the LangGraph checkpointer in PostgreSQL, keyed by run and regeneration count.

<details>
<summary><strong>Must cover</strong></summary>

- **plan**
- **retrieve** — hybrid retrieval over the tenant's chunks
- **act** — at most 6 tool calls, run concurrently
- **draft** — structured output against the Pydantic schema
- **self_check** — may loop back to act once
- **PostgreSQL checkpointer** — keyed by `run_id:regen_count`
- **pin the library** — capture its tables in Alembic before build
- asyncio.gather, 7-day cleanup

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The graph that the agent step runs has five nodes.

1. **plan** — a Sonnet-class model turns the question and the context bundle into a short plan. The plan names the tools it needs.
2. **retrieve** — hybrid retrieval over the tenant's document chunks returns the best 8 chunks.
3. **act** — tool calls through `mcp-gateway`, at most 6 per attempt. Independent calls run concurrently with `asyncio.gather`.
4. **draft** — the model writes a structured output, validated against the Pydantic schema for the run's output kind.
5. **self_check** — the model reviews its draft against the evidence once. It may loop back to act once, for example to fetch a missing reading.

State is one object that each node reads and extends: the plan, retrieved chunks, tool results, the draft and the check result. A **PostgreSQL checkpointer** saves it after each step. The thread ID is `<run_id>:<regen_count>`. When a pod crashes, Step Functions retries the step, and the new attempt uses the same thread ID. It resumes from the last saved step. A regeneration gets a new thread ID, because it must start fresh with the validation feedback.

The checkpointer tables live in the `agent_state` schema. They have no `tenant_id` and no row-level security, so only the `agent_worker` database role can reach them. `celery-beat` deletes threads 7 days after their run ends.

One risk: the checkpointer creates its own tables through `setup()`, and a library upgrade may change them. So before build we must **pin the library** version and capture its table definitions in an Alembic migration. Then schema changes go through review like every other table.

</details>

---

### Q3. How did you choose Bedrock models for the different steps, and how did Bedrock quotas shape the design?

**Brief answer**
Sonnet-class models did reasoning and vision, Haiku-class models did checks and small tasks, and Titan made embeddings. The Bedrock token quota, not compute, was the limit the whole AI side was sized against.

<details>
<summary><strong>Must cover</strong></summary>

- **model tier** — Sonnet-class for reasoning, Haiku-class for checks
- **model_id and prompt_version** — recorded on every run
- **token quota** — the binding limit, not CPU
- **worker count** — sized to the quota
- **daily token budget** — per tenant, checked before work starts
- **prompt caching** — support per model to confirm
- Titan embeddings, adaptive retry, cross-region inference profile

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I split the work by **model tier**. Sonnet-class models did planning, reasoning, drafting and vision for inspections. Haiku-class models did the grounding review and short summaries. Titan made the embeddings. The split is configuration, not code, and every run records its **model_id and prompt_version**. So we can compare quality and cost when we change a model.

The quota decided more than the model choice did. Our estimate was about 58,500 large language model ([LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language")) calls per day, with a peak of about 2.5 calls per second. At about 4,000 input tokens per call, the peak is about 600,000 input tokens per minute. The on-demand **token quota** for a model and region is often far below that. So quota increases had to be requested before launch.

This changed several design choices.

- The **worker count** follows the quota. Extra pods beyond the quota only add throttling. Bursts wait in the `agent-tasks` queue.
- Throttling has its own path: the SDK's adaptive retry first, then the pipeline's `Agent.Throttled` retries for about 15 minutes.
- Each tenant has a **daily token budget** in Redis. One shared budget module checks it before a run starts and before each assist answer. So one tenant's daily use is capped, which limits how much of the shared quota it can take.
- **Prompt caching** helps a long, stable system prompt. Support differs by model version, so it has to be confirmed for the model we choose.

A cross-region inference profile can raise throughput. But it must keep requests inside the tenant's geography, so that too is a check before use. Bedrock also keeps model traffic inside the AWS account boundary, but its data-handling terms still had to be confirmed for each region.

</details>

## R10. AI pipelines — MCP tools

> Developed MCP integrations exposing robotic telemetry, operational data, and internal services as controlled tools for AI agents;

---

### Q1. Why did you expose these tools through MCP instead of writing them directly into each agent?

**Brief answer**
One MCP server gave every agent the same tools behind one policy layer. Writing tools into each agent would repeat the tenant checks and limits in every agent, and one agent would sooner or later get them wrong.

<details>
<summary><strong>Must cover</strong></summary>

- **mcp-gateway** — one internal service for every agent
- **one policy layer**
- **Streamable HTTP** — inside the cluster only
- **client credentials** — a dedicated scope for tool access
- **extra network hop** — the cost of a separate service
- get_device_status, query_telemetry, draft_work_order

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Two kinds of agent needed tools: the analysis, inspection and generation workers, and the synchronous assist service. I put the tools in one service, **mcp-gateway**, a FastAPI service built on the MCP SDK.

It exposes tools for device status, telemetry queries, alarms, maintenance history, knowledge search and inspection findings. It also has one write tool, `draft_work_order`, which only creates a draft for a person to approve.

The main reason was **one policy layer**. Every tool call must be bound to one tenant and one run, limited in size, and written to the audit log. If each agent had its own copy of the tools, each copy would need those checks. A new agent would be one place to forget them. With one server, the rules live in one place and one security review covers them.

The transport is **Streamable HTTP** at `/mcp` inside the cluster. The service has no public route. Kubernetes NetworkPolicies let only the agent workers and the assist service reach it. Callers authenticate with Cognito **client credentials** with the scope `platform/mcp.tools`.

The server also scales and fails on its own. It runs 3 replicas. An agent retries a failed tool call twice, and then the pipeline retries the step.

The cost is an **extra network hop** and one more service to run. A tool call is part of a reasoning step that already waits seconds for a model, so a few milliseconds of network time do not matter.

</details>

---

### Q2. What made these tools "controlled"? How did you stop an agent from reaching data or actions it should not?

**Brief answer**
The server enforced every control, never the prompt. Each call was bound to an active run that fixed the tenant. Each run type had its own tool allowlist. Results and calls were capped, and every call was audited. The one write tool only created a draft for a person to approve.

<details>
<summary><strong>Must cover</strong></summary>

- **run binding** — the tenant comes from the run, not the arguments
- **allowlist per run type** — enforced in the server
- **draft_work_order** — creates only a pending draft
- **caps** — 16 KB results, 15-minute raw windows, 6 calls per attempt
- **audit log** — every call, with the agent as actor
- **no credentials** in model context
- NetworkPolicy, timeouts

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I assumed the model could be tricked, so no control depends on the model behaving.

- **Run binding.** Every call carries a `run_id`. For assist, it is the `assist` run that the service records before answering. `mcp-gateway` loads that run, takes `tenant_id` from it, and sets the database tenant variable itself. Tool arguments cannot name a tenant. A run that is no longer active is refused.
- **An allowlist per run type.** Analysis, generation and assist get the read tools. Inspection gets only device status and inspection findings. The server enforces the list. A prompt that says "you may not" is not a control.
- **One write tool.** Only analysis may call **draft_work_order**. It creates a pending `ai_outputs` row, and a reviewer must approve it. Nothing the platform does reaches a robot or a control system.
- **Caps.** Results are capped at 16 KB, raw telemetry windows at 15 minutes, and tool calls at 6 per attempt. Each tool has a timeout. These limits stop an agent from pulling a huge data set into its context.
- **An audit log entry** for every call, with `actor_type = agent` and the `run_id`. An auditor can see exactly what an agent read.
- **No credentials** enter model context. Tools call services with their own identity.

Kubernetes NetworkPolicies add a network layer: only the agent services can reach `mcp-gateway`.

I flagged the run binding and the allowlist for security review. They are the only barrier between an injected instruction and another tenant's data.

</details>

---

### Q3. What happens when a document or an image tells the agent to do something it should not? How did you think about prompt injection?

**Brief answer**
We assumed prompt injection would happen, because documents, notes and image text are outside our control. The design limits what an injected instruction can do. Validation and human review can catch some of the result, but the design cannot stop the model from following the instruction.

<details>
<summary><strong>Must cover</strong></summary>

- **prompt injection as a given** — the input is text we do not control
- **what the model can do, not whether it follows**
- **blast radius** — one tenant, allowed tools, no autonomous writes
- **validation gate**
- **human review** — before any export
- **output escaping**
- **red-team** — the honest next step, with a measured catch rate

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Model input includes text we do not control: uploaded manuals, maintenance notes, alarm context and text inside inspection images. So I treated **prompt injection as a given**, not as a rare case.

The honest point is this. Our controls limit **what the model can do, not whether it follows** an injected instruction. The model may still follow it. So the design keeps the **blast radius** small:

- The agent's tenant comes from its run. An injected "look at tenant B" has no way to name tenant B.
- The tool allowlist for the run type still applies. An inspection run can call only `get_device_status` and `get_inspection_findings`.
- There are no autonomous writes. The only write tool creates a draft that a person approves, and nothing reaches a robot.
- Tool results are capped, so an injected "dump everything" gets at most 16 KB per call, and at most 6 calls per attempt.

Then the output passes the **validation gate**. The citation and numeric checks can catch some effects of an injection, for example a made-up number or a source the run never retrieved. After that comes **human review** before any generated document or inspection result is exported.

The browser side matters too. Outputs are rendered through React's **output escaping**, never as raw HTML. So an injected script in generated text cannot run in the console.

What we had not yet done is measure it. The next step is to **red-team** the analysis and inspection pipelines with planted instructions in documents and image text. Then we measure how often validation or review catches the result. Until then I would not claim a catch rate.

</details>

## R11. AI pipelines — RAG retrieval

> Built [RAG](https://en.wikipedia.org/wiki/Retrieval-augmented_generation "Retrieval-Augmented Generation — Grounds a model's answer in documents retrieved at query time") workflows using PostgreSQL and vector retrieval to enrich AI responses with operational context;

---

### Q1. How did documents get into your vector store, and how did you keep it up to date?

**Brief answer**
Engineers uploaded documents as a dataset. A Celery ingest job extracted the text, split it into chunks and embedded each chunk with Titan. It stored each vector in the chunk's row in PostgreSQL. Duplicate chunks were skipped by content hash, and re-ingesting a document replaced its chunks.

<details>
<summary><strong>Must cover</strong></summary>

- **ingest queue** — Celery, restartable from a status row
- **text extractor**
- **chunks**
- **Titan embeddings** — stored as `halfvec(1024)`
- **content_sha256** — skip duplicate chunks before embedding
- **re-ingestion** — replaces a document's chunks
- **ingest_status**
- sweeper, full-text column

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Engineers upload manuals, standard operating procedures, incident reports and maintenance logs as a document dataset. The files go straight to S3 through pre-signed URLs. Completing the dataset puts a job on the Celery **ingest queue**.

The ingest job does four things for each document.

1. A Portable Document Format ([PDF](https://en.wikipedia.org/wiki/PDF "Fixed-layout document format for reliable printing and viewing")) **text extractor** turns the file into text.
2. The job splits the text into **chunks**. Each chunk keeps its document ID, its index and a metadata field.
3. It calls **Titan embeddings** on Bedrock and stores each vector as `halfvec(1024)` in `document_chunks`. Half precision halves storage against `vector(1024)`, with little loss in recall for this kind of retrieval.
4. PostgreSQL fills a generated full-text column from the chunk text, so the keyword half of retrieval needs no extra step.

Keeping it up to date had two parts. Each chunk carries a **content_sha256**. The job skips a chunk whose hash already exists before it asks for an embedding. That saves tokens when a manual changes only a little. **Re-ingestion** of a document replaces its chunks through the `(document_id, chunk_index)` index, so old text does not stay behind.

Each document has an **ingest_status**: `pending`, `embedded` or `failed`. The Celery results are ignored, so the status row is the truth. A sweeper re-enqueues any document stuck in `pending` for more than 15 minutes.

I should be honest about chunk size. The design does not fix one number. I would choose it by testing retrieval quality on real questions from reviewed runs, not by picking a common default.

</details>

---

### Q2. How did you retrieve context for the model — plain vector search, or something more?

**Brief answer**
Hybrid retrieval: a vector search and a full-text search each returned their top 40 chunks, and reciprocal rank fusion merged them into the best 8. Plain vector search can miss exact tokens such as part numbers and error codes, which industrial questions depend on.

<details>
<summary><strong>Must cover</strong></summary>

- **hybrid retrieval**
- **HNSW** — top 40 by cosine distance
- **full-text search** — top 40, served by a GIN index
- **reciprocal rank fusion** — merges both lists into the best 8
- **exact tokens** — part numbers and error codes
- ef_search, citation check, tools for telemetry and maintenance data

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The retrieve node in the agent graph runs **hybrid retrieval** over the tenant's `document_chunks`.

- The vector half uses a Hierarchical Navigable Small World (**[HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors")**) index with `halfvec_cosine_ops`. It returns the top 40 chunks by cosine distance.
- The keyword half runs **full-text search** on the `tsv` column and returns its top 40. A Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) on `tsv` serves it.
- **Reciprocal rank fusion** merges the two ranked lists into the best 8 chunks for the model.

Why not plain vector search? Industrial questions often turn on **exact tokens**: a part number, an alarm code, a model name. Embeddings capture meaning well, but they can rank a chunk with the exact code below chunks that only sound similar. Full-text search finds the exact token. Fusion ranks a chunk high if it ranks well in either list. Fusion also needs no score tuning between the two lists.

The HNSW index uses `m = 16` and `ef_construction = 64`, and queries set **ef_search** to 80. A higher `ef_search` improves recall and costs latency. Retrieval has a 300 ms share of the assist latency budget, and a retrieval p95 above 300 ms is an evolution trigger.

Retrieval is only one source of context. Telemetry, alarms and maintenance history reach the model through MCP tools. Telemetry and alarms change every few seconds, so they do not belong in the vector store.

Every chunk the model cites is checked later. The validation step confirms that each cited chunk was actually retrieved in this run.

</details>

> **Footnotes:**
> - **Reciprocal rank fusion:** Scores each result by the sum of 1 / (k + rank) over the lists it appears in, so it merges rankings without comparing raw scores.

---

### Q3. How did you keep each tenant's documents apart in a shared PostgreSQL vector store, and where does that design stop scaling?

**Brief answer**
Each tenant had its own partition of the chunk table with its own vector index, plus row-level security on top. It stops scaling when one tenant grows past about 10 million chunks or retrieval gets slow, and then that tenant moves to a dedicated index.

<details>
<summary><strong>Must cover</strong></summary>

- **list-partitioned by tenant** — one HNSW index per partition
- **filtered vector search** — loses recall when other tenants crowd results
- **row-level security**
- **default partition**
- **partition pruning** — confirm with EXPLAIN as the application role
- **evolution trigger** — 10 million chunks or retrieval p95 over 300 ms
- pgvector against a dedicated vector store, fewer than 40 tenants

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

`document_chunks` is **list-partitioned by tenant**. Each tenant has one partition and one HNSW index. A query that names its tenant touches only that tenant's index.

This solves a real problem. With one shared index, you would run a **filtered vector search**: find the nearest neighbours, then drop other tenants' rows. HNSW returns a limited candidate list. If other tenants' chunks fill that list, the filter leaves too few results, and recall drops without any error.

**Row-level security** sits on top. Every tenant-owned table has a policy on `app.tenant_id`, set per transaction. Even a query that forgot its tenant filter would see only its own tenant's rows. A **default partition** catches a new tenant's chunks until its own partition is created.

One risk needs checking. RLS adds a condition to every query, and the planner may then skip an index. So the check is to run `EXPLAIN (ANALYZE)` as the application role, not as the table owner, who bypasses RLS. It must show **partition pruning** and an HNSW index scan.

Where does it stop scaling? The design assumes fewer than about 40 tenants over five years, so one partition per tenant stays practical. The **evolution trigger** is a tenant above 10 million chunks, or retrieval p95 above 300 ms. Then that tenant's vectors move to a dedicated index service.

The trade-off was deliberate. pgvector means one fewer system, vectors inside the same transactions and RLS as the rest, and joins with operational data. A dedicated vector store gives more headroom per tenant, but it adds a second place where tenant isolation must be right.

</details>

## R12. Security — tenant-aware access control

> Implemented tenant-aware access control using AWS Cognito and IAM policies, and stored service credentials in Secrets Manager;

---

### Q1. Where did the tenant identity come from on each request, and how did you make sure a client could not choose it?

**Brief answer**
For users, the tenant came from a claim that a Cognito trigger added to the access token from an attribute that only the admin API can write. For edge gateways, it came from the gateway's client ID through a lookup; it never came from a path, query or body.

<details>
<summary><strong>Must cover</strong></summary>

- **pre-token-generation trigger** — adds `tenant_id` and roles claims
- **custom:tenant_id** — writable only through the admin API
- **client ID** — maps each gateway to its tenant
- **never from the request**
- **verified twice** — at API Gateway and again in the service
- **per-route dependency** — role checks inside the tenant
- **site scoping**
- Cognito feature plan, users table fallback

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Users log in through Cognito. A Lambda called `token-enricher` runs as a Cognito **pre-token-generation trigger**. It adds `tenant_id` and `roles` claims to the access token. It reads the tenant from the user's **custom:tenant_id** attribute and the roles from Cognito groups. App clients cannot write that attribute; only the admin API can. So a user cannot move themselves to another tenant.

Edge gateways use their own app client. Each gateway's **client ID** maps to one row in `core.devices`. `platform-api` looks it up through a Redis cache and takes the tenant from there.

The rule is that the tenant comes **never from the request**: not from a path, a query parameter or a body field. A `tenant_id` field in the body never decides the tenant.

The token is **verified twice**. API Gateway's Cognito authorizer checks signature, expiry and scope. `platform-api` checks the token again against the cached JWKS, because a request that bypassed the gateway must not be trusted.

Inside a tenant, roles decide what a user may do. A FastAPI **per-route dependency** enforces them, so no route can skip the check. On top of that there is attribute-based **site scoping**: a user with rows in `user_site_access` sees only those sites.

There is one risk to confirm. Custom claims in access tokens need a Cognito feature plan above Lite and the version 2 trigger event. If the plan lacks it, the fallback is to resolve tenant and roles in `platform-api` from `core.users` by the token subject, cached in Redis.

</details>

---

### Q2. How did you manage service credentials with Secrets Manager, and how did rotation work without breaking running services?

**Brief answer**
Database credentials used managed rotation every 30 days, and other secrets rotated on a schedule. Services cached each secret and fetched it again when authentication failed, so a rotation should not need a restart. AWS access itself used short-lived role credentials, not stored keys.

<details>
<summary><strong>Must cover</strong></summary>

- **managed rotation** — database credentials every 30 days
- **refresh on authentication failure**
- **Parameters and Secrets extension** — for Lambdas
- **secret ARN** — stored in the database instead of the secret
- **no static keys** — Pod Identity and OIDC instead
- Redis AUTH token, webhook signing secrets, KMS

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Secrets Manager held every credential a service needs that AWS identity cannot replace.

- Database credentials use **managed rotation** every 30 days.
- The Redis AUTH token and the per-tenant webhook signing secrets rotate on a schedule.

Rotation breaks services when a pod keeps an old secret in memory. So pods read secrets through the SDK with a local cache. They **refresh on authentication failure**: when a call fails authentication, they fetch the secret again and retry. A rotation then costs one failed attempt, not an outage or a restart. Lambdas use the AWS **Parameters and Secrets extension**, which caches for them.

The database never holds a secret. The `integrations` table stores a **secret [ARN](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html "Amazon Resource Name — Globally unique identifier of an AWS resource, used in policies and cross-service references")**, an Amazon Resource Name that points to Secrets Manager. A database dump or a wrong query cannot leak a tenant's webhook secret.

For AWS itself we had **no static keys**. Each Kubernetes service account gets its own IAM role through EKS Pod Identity, with short-lived credentials that rotate automatically. Each Lambda has its own execution role. GitLab reaches AWS through OIDC federation, so no long-lived AWS keys exist in CI.

Credentials also never enter model context (see the MCP tools section).

Encryption keys are separate. Each data class has its own customer-managed KMS key, so key use is logged and can be revoked. Secrets rotation and the pods' refresh behaviour were on the list for security review before build.

</details>

---

### Q3. If one tenant-isolation check had a bug, what stopped one tenant's data from reaching another tenant?

**Brief answer**
Isolation had five independent layers: the tenant from a verified identity, row-level security in PostgreSQL, IAM session tags for S3 and DynamoDB, run binding for agents, and tenant-keyed caches. A bug in one layer still leaves the others in place.

<details>
<summary><strong>Must cover</strong></summary>

- **five independent layers**
- **row-level security** — no BYPASSRLS, not the table owner
- **per-tenant iteration** — cross-tenant jobs set the tenant each time
- **session tags** — on the tenant-scoped IAM role
- **dynamodb:LeadingKeys** — test against both secondary indexes too
- **pre-signed URLs** — signed with the tenant session
- **run binding**
- tenant-keyed caches, no edge caching, security review

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I did not trust any single check, so isolation has **five independent layers**.

1. **Identity.** The tenant comes only from a verified token claim or the gateway mapping.
2. **PostgreSQL row-level security.** Every tenant-owned table has a policy on `app.tenant_id`, set with `SET LOCAL` in each transaction. Application roles lack `BYPASSRLS` and do not own the tables, because owners bypass the policy. A query with a missing `WHERE tenant_id` still sees one tenant. Jobs that serve all tenants, such as sweepers and nightly reconciliation, use **per-tenant iteration**: they set the variable for one tenant at a time. No query ever reads across tenants.
3. **IAM session tags.** For S3 and the audit log, `platform-api` assumes the `tenant-data-access` role with **session tags** carrying `tenant_id`. It caches the session for 15 minutes per tenant. The policy allows S3 only under `tenant=${aws:PrincipalTag/tenant_id}/*`. For DynamoDB it uses **dynamodb:LeadingKeys** to match keys that start with `T#<tenant_id>#`. **Pre-signed URLs** are signed with this session, so a tampered key cannot reach another tenant's prefix.
4. **Run binding** for agents. `mcp-gateway` takes the tenant from the run, never from the model.
5. **Caches.** Every Redis key with tenant data is keyed by tenant, and API responses are never cached at the edge.

So IAM still blocks an application bug that builds the wrong S3 key, and row-level security still blocks a query with a missing filter.

One risk needs a real test. The `LeadingKeys` condition must also hold on the two secondary indexes of `audit_log`. The check is the IAM policy simulator plus a live query that must be denied. The role's trust policy and conditions were first on the list for security review.

</details>

## R13. Cloud infrastructure — Terraform and EKS

> Managed Step Functions, Lambda, queues, and IAM resources with [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files"), and deployed backend services to AWS EKS from [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment") images using Docker, Docker Compose, and Kubernetes(k8s);

---

### Q1. How did you structure your Terraform code and state across environments?

**Brief answer**
Each environment — `dev`, `staging` and `prod` — is a separate AWS account, built from one set of Terraform modules with per-environment variables. State is split so that one apply can only change one environment and one group of resources.

<details>
<summary><strong>Must cover</strong></summary>

- **separate AWS accounts** — one per environment
- **same Terraform modules** — only the variables change
- **S3 with locking**
- **one state per environment and module group**
- **saved plan** — the apply runs exactly what was reviewed
- terraform validate, CloudFormation

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

We ran three environments as separate AWS accounts. An account is the strongest boundary AWS offers. A mistake in `dev` cannot delete a resource in `prod`, and each account has its own quotas and its own bill.

All three accounts are built from the same Terraform modules. Only the variables change per environment, for example instance sizes and replica counts. So `staging` is a real rehearsal for `prod`, not a similar copy that drifts away over time.

Terraform state is stored in S3 with locking. I split it into one state per environment and module group. The groups are network, cluster, data, messaging, workflows, identity and observability. The split has three effects:

- A change to a Step Functions state machine plans only the workflows state. It never touches the database.
- Two engineers can work on different groups without waiting for the same lock.
- The damage from a bad apply stays inside one group, not the whole account.

The cost is the wiring between states. A group that needs a value from another group, such as a queue or a role, has to read it from that group's outputs. So the groups have a dependency order.

In the pipeline, `terraform validate` runs in the static checks stage. `terraform plan` runs per environment, and the pipeline keeps the saved plan. The deploy applies exactly that saved plan, so the change a reviewer approved is the change that runs.

We chose Terraform over CloudFormation because CloudFormation is AWS-only and has weaker module reuse.

</details>

---

### Q2. How did you get a backend service from a Docker image to running pods on EKS, and how did you roll it back?

**Brief answer**
The pipeline builds each image once, tags it with the commit SHA and pushes it to Elastic Container Registry (ECR). The deploy applies Kustomize overlays, and Kubernetes replaces pods without losing capacity. Rollback is `kubectl rollout undo` for the API services and deleting the canary for workers.

<details>
<summary><strong>Must cover</strong></summary>

- **commit SHA** — one image, promoted and never rebuilt
- **ECR**
- **Kustomize overlays**
- **rolling update** — new pods start before old pods stop
- **readiness probe** — checks database and Redis reachability
- **PodDisruptionBudget**
- **canary Deployment** — workers judged on failure metrics
- **kubectl rollout undo**
- SBOM, image scan, Docker Compose, moto in server mode

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The build stage builds each Docker image once. The tag is the commit SHA, never `latest`, so every environment runs a known build. The same stage produces a Software Bill of Materials ([SBOM](https://www.cisa.gov/sbom "Inventory of every component and dependency in a build")) and scans the image. Then it pushes the image to ECR. `dev`, `staging` and `prod` pull that same image. We promote a build between environments, and we never rebuild it.

The deploy step runs `kubectl apply` on Kustomize overlays. The base manifests are shared, and each overlay sets the per-environment values and the image tag.

For `platform-api`, `agent-service-api` and `mcp-gateway` we use a rolling update with `maxUnavailable: 0` and `maxSurge: 25%`. New pods start before old pods stop. A readiness probe checks that the pod can reach the database and Redis. A pod that fails the probe gets no traffic. So a bad configuration stops the rollout instead of taking the service down.

Every service runs at least 3 replicas spread across three Availability Zones. A PodDisruptionBudget with `minAvailable: 2` stops node drains and upgrades from removing too many pods at once.

Workers need a different approach. A bad worker does not fail a request. It fails AI runs, and that shows up minutes later. So `agent-worker` and `celery-worker` get a one-replica canary Deployment. It takes a share of the queue for 30 minutes. The pipeline compares its `GenerationFailures` and `ValidationFailures` with the stable pods before it promotes.

Rollback is `kubectl rollout undo` for the API services, and deleting the canary Deployment for workers. Rollback is safe because migrations are expand-only, so the old code still works with the new schema.

Docker Compose runs the same stack locally, with moto in server mode in place of AWS. The pipeline also uses Compose for its integration tests.

</details>

---

### Q3. Your Step Functions and Lambdas were managed in Terraform, but your services on EKS were deployed from images. How did you keep the two in step during a release?

**Brief answer**
With a fixed deployment order in which each step must succeed before the next: infrastructure first, then migrations, then pods, then the Lambda and state machine aliases, then the console. And with a rule that old and new versions must work side by side during every step.

<details>
<summary><strong>Must cover</strong></summary>

- **deployment order** — each step must succeed before the next
- **expand-only** — migrations keep the running version working
- **aliases** — weighted shift for Lambdas and state machines
- **compatible in both directions** — for one release
- terraform apply first, Bash alarm check, index.html invalidation, down-migration

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

One release changes two kinds of thing. Terraform owns queues, state machines, Lambdas and IAM roles. Images own the code in the pods. If the two move out of order, new code can call a queue that does not exist yet. Or a new state machine can send a message that the old worker cannot read.

We solved this with a fixed deployment order. Each step must succeed before the next one starts:

1. `terraform apply` of the saved plan: queues, state machines, Lambdas, IAM.
2. Alembic migrations as a Kubernetes Job. They are expand-only, so the running version keeps working.
3. EKS workloads through `kubectl apply`.
4. Lambda and Step Functions aliases shifted to the new versions.
5. `ops-console` assets synced to S3, then `/index.html` invalidated in CloudFront.

The order builds infrastructure first and moves traffic last. But order alone is not enough, because a rollout is not instant. For some minutes, old and new versions run together. So every change must be compatible in both directions for one release. Three mechanisms make that true:

- **Expand, then contract** for the database. A column is added as nullable first, and it becomes required only in a later release.
- **State machine versions behind an alias.** A new version is published. The alias sends 10% of executions to it for 30 minutes, then 100%.
- **Weighted Lambda aliases.** The alias sends 10% of calls for 15 minutes, then 100%. A Bash step checks the function's error alarms before it promotes.

Rollback follows the same split. We re-point the alias for Lambdas and state machines, and we run `kubectl rollout undo` for pods. We never need a down-migration, because the schema only expanded.

</details>

## R14. Continuous delivery — GitLab pipeline

> Automated image builds, test runs, and multi-environment deployments through GitLab CI/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") with Bash scripts on Linux build agents;

---

### Q2. Walk me through the stages of your GitLab pipeline. What had to pass before a change reached production?

**Brief answer**
Static checks, tests, an image build and a Terraform plan per environment, then automatic deploys to `dev` and `staging`. Production needed smoke tests to pass in staging, and an AI evaluation whenever a prompt or model changed. Then came a manual approval, and the change went out as a canary before promotion.

<details>
<summary><strong>Must cover</strong></summary>

- **static checks**
- **Pytest with moto**
- **commit SHA** — the same image runs in every environment
- **terraform plan** — per environment, saved for the deploy
- **smoke tests**
- **AI evaluation** — blocks promotion if the pass rate drops over 5 points
- **manual approval**
- **canary**
- SBOM, image scan, fake chat model, Bash alarm check

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The GitLab continuous integration and continuous delivery (CI/CD) pipeline has these stages:

1. **Static checks:** type checks and `terraform validate`.
2. **Tests:** Pytest with moto, Docker Compose integration tests against real PostgreSQL and Redis, and React Testing Library tests.
3. **Build:** Docker images pushed to ECR and tagged with the commit SHA, with an SBOM and an image scan.
4. **Plan:** `terraform plan` per environment, saved for the deploy.
5. **Deploy dev:** automatic on `main`.
6. **Deploy staging:** automatic, followed by smoke tests, and by the AI evaluation when a prompt or model changed.
7. **Manual approval.**
8. **Deploy prod:** a canary first, then promotion.

The image is built once. The same commit SHA runs in `dev`, `staging` and `prod`. So a production image is always one that passed every earlier stage.

The AI evaluation is the stage that is special to this system. Ordinary tests cannot tell whether a new prompt gives worse answers. The integration tests replace Bedrock with a fake chat model that replays recorded responses. So staging is the first place where real model output is checked. A fixed evaluation set, drawn from reviewed runs, runs whenever `prompt_version` or `model_id` changes. Promotion is blocked if the pass rate drops by more than 5 points.

Bash scripts carry the deploy and verification steps, such as the alarm check before a Lambda alias moves to 100%.

Rollout mechanics on EKS, such as rolling updates and the worker canary, sit in the deploy stages. The pipeline's job is to decide whether a build may move forward at all.

</details>

---

### Q3. How did the pipeline get access to AWS, and how did you protect the production deployment?

**Brief answer**
The runners reach AWS through federation with GitLab's identity tokens, into one role per environment, so no long-lived AWS keys exist anywhere in GitLab. The production role accepts only protected branches and tags, and a manual approval stands in front of it.

<details>
<summary><strong>Must cover</strong></summary>

- **self-managed Linux runners** — inside the VPC
- **OIDC federation**
- **one IAM role per environment**
- **no long-lived AWS keys**
- **protected branches and tags** — the only trust for the production role
- **private EKS API endpoint** — reachable only from the runners
- **manual approval**
- **trust conditions** — a too-broad match lets any branch deploy
- reviewed merge requests, ISO 27001, SOC 2, security review

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline runs on self-managed Linux runners inside our Virtual Private Cloud ([VPC](https://aws.amazon.com/vpc/ "Isolated private network in which cloud resources run")). They reach AWS through GitLab OIDC. Each job gets a signed ID token from GitLab. AWS exchanges that token for a session in an IAM role. This OIDC federation uses one IAM role per environment. A session lasts 1 hour.

The main benefit is that no long-lived AWS keys exist in GitLab. A leaked CI variable cannot give anyone access to AWS, because there is no key to leak.

The production role has a stricter trust policy. It trusts only tokens from protected branches and tags. A developer can push a feature branch and run its pipeline, but that job cannot take the production role. Only protected branches can, so a change must pass a reviewed merge request first.

Two more controls sit around it:

- A private EKS API endpoint. Only the runners inside the VPC can reach it, so nobody can run `kubectl` against production from outside.
- A manual approval between staging and production.

This also supports compliance. For International Organization for Standardization ([ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "Publishes international standards, including information security management")) 27001 and System and Organization Controls ([SOC](https://www.aicpa-cima.com/topic/audit-assurance/audit-and-assurance-greater-than-soc-2 "Audit reports on a service organization's security, availability and confidentiality controls")) 2, auditors expect changes to reach production only through reviewed merge requests and the pipeline.

The weak point is the trust conditions themselves. A condition that matches too broadly, for example a wildcard on the branch name, would let any branch deploy to production. So the OIDC trust conditions for each environment's deploy role are on the security review list. The production role's branch and tag rule matters most.

</details>

## R15. Performance — FastAPI and async paths

> Optimized FastAPI and asynchronous processing paths to improve responsiveness of AI-powered application workflows;

---

### Q1. What is the main risk when you write async code in FastAPI, and how did you avoid it?

**Brief answer**
One blocking call inside an async endpoint stops the event loop, and with it every request on that worker. We kept the loop free: async SQLAlchemy over asyncpg for the database, async clients for AWS, and a thread pool for the few sync-only libraries.

<details>
<summary><strong>Must cover</strong></summary>

- **event loop** — one blocking call stalls every request on the worker
- **asyncpg**
- **async clients** — for every AWS call
- **thread pool** — for sync-only libraries, and it has a size limit
- **plain `def`** — FastAPI runs these routes in the thread pool
- asyncio debug mode, trace spans

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

FastAPI runs `async def` endpoints on one event loop per Uvicorn worker. The loop switches between requests only at an `await`. So a call that blocks freezes every request on that worker until it returns. Examples are a sync database driver, a sync HTTP call, `time.sleep`, or heavy CPU work. Under load this looks like random latency spikes on unrelated endpoints, which makes it hard to trace.

On this platform the risk was high, because most work is waiting on input and output. The services wait on the database, Redis, S3, Step Functions and Bedrock. We kept the loop free in three ways:

- **Database:** SQLAlchemy in async mode over asyncpg. The session comes from a FastAPI dependency, so every route uses the async path.
- **AWS calls:** async clients.
- **Sync-only libraries:** the few we had run in a thread pool.

A thread pool is not free capacity. It has a fixed size, so too many sync calls just move the queue from the loop into the pool.

One FastAPI detail helps and also hides problems. A route written with plain `def` runs in the thread pool automatically. A route written with `async def` runs on the loop. So a blocking call inside `async def` is the dangerous case. The same call inside a `def` route is only slower.

To find a blocking call, asyncio debug mode is the first tool. It logs any step that holds the loop longer than a threshold. Traces help too. A slow span with no database or network call inside it points to CPU work or a blocking call.

</details>

---

### Q2. What did you change so that AI-powered workflows felt fast to users, even when the AI work itself took minutes?

**Brief answer**
Only assist made a user wait on the model, for at most 25 s. Every other model-backed endpoint accepts the work at once, and the console follows the run. Around that, we cut the waits we could control — parallel calls inside a run, Redis for the frequent reads, and cheaper model calls.

<details>
<summary><strong>Must cover</strong></summary>

- **acknowledge, then work** — `202` with a `run_id`, target under 100 ms
- **bounded synchronous assist** — 25-second hard timeout
- **parallel fan-out** — the wait becomes the slowest call
- **live status** — written to Redis by the rollup consumer
- **Haiku-class model** — for small tasks
- **prompt caching** — model support to confirm before build
- **latency budget** — design budgets, not measured results
- 29-second gateway timeout, cache-aside, Map states

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Most AI work here takes minutes. No code change makes a seven-step agent run feel instant. So the first decision was about what the user experiences, not about raw speed.

**Acknowledge, then work.** Every model-backed endpoint except assist returns `202` with a `run_id`. The target is under 100 ms. The request writes an `ai_runs` row and starts the pipeline, and nothing more. The console then polls the run status every 3 s. A connection held open for minutes would hit the API Gateway 29-second timeout anyway.

**Bounded synchronous assist.** A small question about one device goes to assist, which answers directly. Its target is a p95 under 8 s, with a hard timeout of 25 s. Anything larger becomes an analysis run. So users get a fast path for small questions and a status view for large ones.

**Parallel fan-out.** Inside a run, independent tool calls run together with `asyncio.gather`. Retrieval queries run concurrently. Inspection images and generation sections run in parallel in Map states. The wait becomes the slowest call, not the sum of all calls.

**Caching the reads.** Dashboards poll often. The rollup consumer writes live status to Redis on every batch, so a status read is one Redis lookup. Registry data uses cache-aside, and `platform-api` deletes the key after the change commits. Dashboard aggregates are cached for 30 s, which is inside the freshness target.

**Cheaper model calls.** Small tasks, such as checks and summaries, use the Haiku-class model. A long, stable system prompt can use Bedrock prompt caching. Whether the chosen model version supports it is a point to confirm before build.

Each target has a latency budget. For example, the analysis target is a p95 under 5 minutes, and the nominal path is about 2 minutes. These are design budgets, not measured results. The budget shows which step to work on first when a target slips.

</details>

---

### Q3. How did you size connection pools and concurrency across API pods, workers and Lambdas, so that the database was not overloaded?

**Brief answer**
I worked outwards from the database's connection limit. The API pods use about 240 connections in total, well below the instance limit. Lambdas reach the database through a proxy, with capped concurrency. The agent workers are sized to the Bedrock quota, not to CPU.

<details>
<summary><strong>Must cover</strong></summary>

- **asyncpg pool** — one per process, multiplied by workers and pods
- **240 connections**
- **RDS Proxy** — pools the Lambda connections
- **reserved concurrency**
- **session pinning** — `SET LOCAL` may stop the proxy from pooling
- **Bedrock token quota** — sizes the agent workers
- maxSurge, connections alarm at 80%, read replica

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The database is the shared resource that everything else can overload. So I started from its connection limit and worked outwards.

**API pods.** Each `platform-api` pod runs 4 Uvicorn workers. Each worker has its own asyncpg pool of 10, because a pool belongs to one process. With 6 pods that is 240 connections. The database runs on Amazon Relational Database Service ([RDS](https://aws.amazon.com/rds/ "Managed hosting for relational databases such as PostgreSQL, with backups and failover")), and its `db.r6g.xlarge` instance allows about 3,400 connections. That leaves room for scaling out, for deploys and for the other services. A rolling update with `maxSurge: 25%` adds new pods before it removes old ones. So the peak count during a deploy is higher than the normal count.

**Lambdas.** Lambda is the risky client. It scales with queue depth, and each instance opens its own connection. So `telemetry-rollup` and `telemetry-rules` connect through RDS Proxy, which pools connections for them. Each function also has reserved concurrency of 20, which caps how many instances run at once.

RDS Proxy brings one risk. We set the tenant with `SET LOCAL app.tenant_id` in every transaction, for row-level security. The proxy may keep a client on one connection because of that. This is called session pinning, and it stops pooling. The check is the proxy's `DatabaseConnectionsCurrentlySessionPinned` metric. The fallback is `set_config('app.tenant_id', …, true)`.

**Agent workers.** Their limit is not the database but the Bedrock token quota. Each pod runs up to 16 tasks at once on AsyncIO. Four replicas give 64 slots, against about 25 concurrent tasks at the estimated peak. Pods beyond the quota only produce throttling. So the replica count changes when the quota changes, and bursts wait in the `agent-tasks` queue.

**Guard rails.** An alarm fires when connections pass 80% of the maximum. If primary CPU stays above 60% for a week, or read p95 goes above 300 ms, the next step is a read replica for rollup and retrieval reads.

</details>

## R16. Testing and observability — CloudWatch

> Established CloudWatch metrics, logs, and alarms for APIs, queues, Step Functions executions, and generation failures;

---

### Q1. Which metrics did you alarm on for the APIs, queues and Step Functions executions, and why those?

**Brief answer**
I alarmed on what a user or a run would feel: the API 5xx rate, the age of the oldest message on each queue, any message in a dead-letter queue, and failed, timed-out or throttled executions. Paging comes from error-budget burn rates against the service level objectives.

<details>
<summary><strong>Must cover</strong></summary>

- **5xx rate** — per method group
- **ApproximateAgeOfOldestMessage** — age, not depth
- **DLQ** — any message alarms
- **ExecutionsFailed**
- **SLOs**
- **burn-rate alarms** — page at 14.4×, ticket at 6×
- ExecutionThrottled, Lambda Throttles, ops-alerts

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

All alarms publish to the `ops-alerts` topic in SNS, which reaches the on-call engineer.

**APIs.** The alarm is a 5xx rate above 1% for 5 minutes, per method group. The grouping matters. A broken ingest endpoint would hide inside the total of many dashboard reads.

**Queues.** I used `ApproximateAgeOfOldestMessage`, not queue depth. Depth depends on traffic, and a deep queue at a busy hour is normal. Age shows directly whether work is getting stale. Telemetry queues alarm above 120 s. At that age, live status has already missed its 30-second freshness target. `agent-tasks` alarms above 600 s. An analysis has a 5-minute p95 target, and some queueing during bursts is by design there.

**Dead-letter queues.** Any message in any DLQ raises an alarm. On the FIFO telemetry queues, a poison message blocks one gateway's group until it moves to the DLQ. So a DLQ message means one gateway's data stopped and needs a redrive after the fix.

**Step Functions.** `ExecutionsFailed` or `ExecutionsTimedOut` above 0 for 5 minutes, and any `ExecutionThrottled`.

**Lambda.** `Errors` above 1%, or any `Throttles` on the telemetry consumers.

Above these thresholds sit the Service Level Objectives (SLOs). For example, API availability is 99.9% over 30 days. I use multi-window burn-rate alarms. The system pages when 2% of the monthly error budget burns in 1 hour, which is 14.4 times the normal rate. It opens a ticket when 5% burns in 6 hours, which is 6 times the normal rate. A fast burn pages the on-call engineer at once. A slow burn opens a ticket for working hours.

The risk on the other side is alarm noise. An alarm that fires every day gets ignored. So each threshold is tied to a user-facing target. The DLQ alarm is "any message" because a DLQ should normally be empty.

</details>

---

### Q2. How did you track generation failures? What counted as a failure, and how did you record it?

**Brief answer**
A generation failure is a pipeline run that ends in the failure state. That state records an error code and emits a failure metric, broken down by run type and error code. Next to it I tracked validation failures, regenerations and the review rejection rate, the closest live signal of output quality.

<details>
<summary><strong>Must cover</strong></summary>

- **MarkFailed** — reached through a Catch on every state
- **error_code** — a dimension that separates causes by owner
- **Embedded Metric Format**
- **completed_unvalidated** — not a failure, but never exportable
- **ValidationFailures** — by check
- **ReviewRejectionRate** — closest live signal of quality
- **offline evaluation set** — catches what validation misses
- RegenerationCount, budget_exceeded, run-success SLO

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Every state in `analysis-pipeline` has a `Catch` that routes to `MarkFailed`, which runs `run-set-status`. It records `error_code` on the `ai_runs` row. It also emits `GenerationFailures` with the dimensions `run_type` and `error_code`. The metric goes out through the CloudWatch Embedded Metric Format. So it is a structured log line, and it needs no extra API call.

The `error_code` dimension is important. A `model_unavailable` failure after Bedrock throttling, a `budget_exceeded` rejection and a crash look the same in a total count. They need different people to act.

What counts as a failure needed a clear rule. A run that ends as `completed_unvalidated` is not a generation failure. It produced an output, but the output still failed validation after two regenerations. The platform keeps it and shows it to a reviewer with the failures, but it can never be exported. So it counts as a success in the run-success [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), and it shows up in the quality metrics instead. The run-success SLO also excludes `budget_exceeded` and `cancelled` runs, because those are not platform faults.

The quality metrics are:

- `ValidationFailures`, by check: schema, citation, numeric grounding, or the model-based grounding review.
- `RegenerationCount`. A rise suggests that drafts are getting worse, for example after a prompt change.
- `ReviewRejectionRate` per output kind. This is the closest live signal of real quality, because a person judged the output.

The alarm fires when `GenerationFailures` goes above 5 in 15 minutes for any `error_code`, or on any `budget_exceeded`.

There is an honest limit. Validation catches malformed and ungrounded output. It does not catch subtly wrong reasoning. For that, the design uses an offline evaluation set built from reviewed runs. It runs in staging whenever `prompt_version` or `model_id` changes.

</details>

---

### Q3. When an AI run was slow or failed, how did you trace it across the API, the queues, the state machine and the workers?

**Brief answer**
One run ID joins everything — the run row, the execution, the logs, the traces and the audit trail. Traces cross every hop, and each model and tool call gets its own span, so a slow run shows which step was slow.

<details>
<summary><strong>Must cover</strong></summary>

- **run_id** — joins row, execution, logs, traces and audit
- **structured logs**
- **OpenTelemetry**
- **traceparent** — and `AWSTraceHeader` through SQS
- **LangChain callback** — one span per model and tool call
- **sampling** — 100% of AI runs and errors
- **not logged by default** — prompts and outputs carry tenant data
- X-Ray, execution_arn, KMS-encrypted debug log group

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The first tool is the `run_id`. It is the primary key of the `ai_runs` row. It is also the Step Functions execution name, because we start each execution named after its run. Every log line, trace and `audit_log` entry for the run carries it. So from a user's report I can go straight to the execution history, the agent's logs and its tool calls.

**Structured logs.** Every service and Lambda logs one JSON object per line. The fields include `tenant_id`, `request_id`, `run_id`, `execution_arn` and `trace_id`. One CloudWatch query can then filter a single run across all components.

**Distributed tracing.** OpenTelemetry SDKs instrument FastAPI, SQLAlchemy, the AWS SDK, Celery and HTTP clients. The AWS Distro for OpenTelemetry collector exports the traces to X-Ray. X-Ray is not in the CV's stack list. It is an AWS addition in the design. Trace context crosses every hop. The World Wide Web Consortium ([W3C](https://www.w3.org/ "Develops open web standards such as trace context propagation")) `traceparent` header travels over HTTP, including agent calls to the Model Context Protocol (MCP) gateway. The `AWSTraceHeader` attribute travels through Simple Queue Service (SQS). X-Ray tracing is on for API Gateway, Lambda and the three state machines.

**Spans for the model.** A LangChain callback opens a span for each model call and each tool call. The span records the model ID, token counts and latency. So a slow run shows whether the time went to queue wait, a throttled model call or a slow tool.

**Sampling.** The sampling rate is 5% of ordinary requests, but 100% of AI runs and of any request that errors. AI runs are few and expensive, so every one is worth a full trace.

One rule limits what we can see. Prompts and outputs are not logged by default, because they contain tenant data. Logs carry token counts, hashes and IDs. The content stays in `ai_outputs` and in the S3 `intermediate/` objects, under access control. For debugging, a tenant can turn on prompt logging. That goes to a separate log group, encrypted with KMS and kept for 14 days.

</details>

## R17. Testing and observability — Pytest, moto and React Testing Library

> Wrote Pytest suites with moto for Lambda handlers, SQS consumers, and DynamoDB access, plus React Testing Library tests for frontend workflows;

---

### Q1. What did your React Testing Library tests check, and how did you handle the API in them?

**Brief answer**
They checked the inspection, analysis and review workflows the way a user meets them — what appears on screen and what a click does. The API was mocked at the network layer, so our own client code and React Query still ran for real.

<details>
<summary><strong>Must cover</strong></summary>

- **user-visible behaviour** — found by role and text, not by internals
- **mocked at the network layer**
- **polling** — a sequence of statuses, then the final screen
- **completed_unvalidated** — shows its failures and offers no export
- fake timers, accessibility, Vitest

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The React Testing Library tests covered the three workflows that matter most. These are starting an inspection, starting an analysis and following it to a result, and reviewing an output. Each test renders the components inside a React Query client and a router, as the app does. Then it acts like a user. It finds a button by its role or label, clicks it, and checks what appears.

The tests check user-visible behaviour, not implementation details. A test does not check component state or which hook was called. If a test depends on internals, a refactor breaks it even when the user sees no change. Queries by role and label also give a basic accessibility check, because a button without a label cannot be found.

The API is mocked at the network layer. The components, React Query and our API client code all run for real. Only the HTTP response is fake. This catches bugs that sit between layers, for example a wrong query key that stops the review list from refreshing after an approval.

Some behaviours need special care:

- **Polling.** A run moves from `queued` to `running` to `validating` to `completed`. The mock returns that sequence of statuses, and the test waits for the final screen. Fake timers can remove the real 3-second wait between polls.
- **Review rules.** An output in `completed_unvalidated` must show its validation failures, and it must not offer export. The review tests are the place for rules like this one. They protect the human-review rule, not only the layout.

Vitest is the test runner. It is not in the CV's stack list, but React Testing Library needs a runner, and Vitest fits a Vite build.

</details>

---

### Q2. How did you test Lambda handlers and SQS consumers with moto, and what did you change in the handler code to make that work?

**Brief answer**
The handlers take their AWS clients by injection instead of building them at import time, so a test can pass in clients that moto backs. Each test then sets up the fake queue or table, calls the handler with a real-shaped event, and checks the effect, including duplicate and out-of-order delivery.

<details>
<summary><strong>Must cover</strong></summary>

- **by injection** — clients passed in, never built at import time
- **Pytest fixture** — fake credentials, region and resources
- **duplicate delivery** — the same batch twice gives one effect
- **high watermark** — a stale sequence number is skipped
- **gap** — recorded when a sequence number is missing
- **conditional update** — must not overwrite a newer checkpoint
- moto fakes SNS and Step Functions, Docker Compose integration tests

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The change in the handler code came first. A common Lambda pattern builds AWS clients at module import, outside the handler. That makes testing hard. The client exists before moto can take over the AWS calls, and it may pick up real credentials. So our handlers take their AWS clients by injection. In production the default clients are real. In a test, the setup passes in clients created under moto.

The setup is a Pytest fixture. It sets fake AWS credentials and a region, starts moto, and creates the resources the handler needs. Examples are the SQS FIFO queue, the DynamoDB `telemetry_checkpoints` table and the S3 bucket. moto fakes SQS, SNS, DynamoDB, S3 and Step Functions.

The tests follow the delivery guarantees, because that is where consumers break:

- **Duplicate delivery.** The test calls the handler with the same batch twice. The effect must happen once: one S3 object, one checkpoint advance.
- **Stale sequence.** The test delivers a batch whose `seq` is at or below the high watermark. The handler must skip it.
- **Gap.** The test delivers `seq` 12 after 10. The checkpoint must record the missing range `[11, 11]` as a gap.
- **Race on the checkpoint.** The test advances the checkpoint first, then lets the handler try its own advance. The conditional update must fail cleanly and must not overwrite the newer value.

Each event is built in the real SQS event shape, so the parsing code runs too.

These are unit tests, and they stop at AWS. Effects inside PostgreSQL, such as the rollup `last_seq` guard, run against a real database in the Docker Compose integration tests.

</details>

---

### Q3. What can moto not tell you, and how did you cover those gaps?

**Brief answer**
moto shows that my code calls AWS correctly, not that AWS will behave that way in production. It does not prove permissions, quotas, timing or every detail of queue behaviour. I covered those with integration tests on real databases, a replayed fake model, a staging evaluation, and explicit checks for the permission conditions.

<details>
<summary><strong>Must cover</strong></summary>

- **does not enforce IAM policies** — by default
- **quotas** — none of the real service limits
- **Docker Compose** — real PostgreSQL with pgvector and both Redis roles
- **row-level security**
- **fake chat model** — replays recorded responses
- **staging AI evaluation**
- **IAM policy simulator** — plus a live denied query
- **smoke tests**
- timing, FIFO deduplication, dynamodb:LeadingKeys

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

moto is an in-memory imitation of AWS services. It is fast, and it is good for handler logic. But it only approximates behaviour, and some things it does not model at all:

- **IAM.** By default, moto does not enforce IAM policies. A test passes even if the Lambda's role lacks the permission it needs.
- **Quotas.** There are no real service limits, such as FIFO topic throughput or Lambda concurrency.
- **Timing.** There is no real latency, and no race between consumers under load.
- **Exact semantics.** FIFO deduplication and ordering are approximations. A test that passes on moto does not prove the real service does the same.

We covered these gaps in other places:

- **Integration tests on real databases.** Docker Compose in CI brings up PostgreSQL with pgvector and both Redis roles. The tests run the migrations, then check row-level security, rollup idempotency and retrieval against the real engines. Row-level security is the key one. moto does not test it at all, and a wrong policy would expose tenant data.
- **A fake chat model.** Bedrock is replaced by a fake chat model that replays recorded responses. So the graph logic is tested without paying for tokens or depending on a live model.
- **Staging AI evaluation.** Real model output is first checked here. The evaluation set runs when `prompt_version` or `model_id` changes.
- **IAM conditions.** The tenant condition on `dynamodb:LeadingKeys` must hold for the `audit_log` table and for its `by_actor` and `by_day` indexes. That needs the IAM policy simulator and a live denied query, which is a real request that must fail. It is a check to run before build, and moto cannot replace it.
- **Smoke tests** after each staging deploy, against real AWS.

The real quotas are not a test at all. The SNS FIFO throughput and the Bedrock token quota are checked against current AWS quotas, and increases are requested before launch.

</details>

## R18. Testing and observability — Cursor as development environment

> Used Cursor as the main development environment for prototyping, multi-file refactoring, debugging, and Pytest generation, and for navigating unfamiliar service code before changing it.

---

### Q2. How did you use Cursor on this project, and how did you check the code it produced before you trusted it?

**Brief answer**
Cursor was my main editor for prototyping, multi-file refactoring, debugging, drafting Pytest tests and reading unfamiliar service code. Its output got the same checks as any code before I trusted it: tests that fail when the code is broken, static checks, integration tests and a reviewed merge request.

<details>
<summary><strong>Must cover</strong></summary>

- **no role in the architecture** — a tooling choice
- **navigating unfamiliar code** — then reading the code myself
- **Pytest generation** — a first draft only
- **must fail on broken code**
- **static checks**
- **integration tests** — real PostgreSQL and Redis
- **reviewed merge request**
- **secrets or tenant data** — never in a prompt
- prototyping, multi-file refactoring, debugging

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Cursor was a tooling choice. It has no role in the architecture, and nothing in the platform depends on it. I used it for five kinds of work:

- **Navigating unfamiliar code.** Before I changed a service I had not written, I asked it to trace a path, for example from an endpoint to the tables it writes. Then I read that code myself.
- **Prototyping** a new endpoint or handler quickly, to test an idea before I designed it properly.
- **Multi-file refactoring**, for example a rename that crosses models, services and tests.
- **Debugging**, by giving it a stack trace and the related files.
- **Pytest generation**, as a first draft of test cases.

Generated code is a draft. I trusted it only after the same checks as hand-written code. Those checks come from the project, not from the tool:

- **A generated test must fail on broken code.** A test that always passes proves nothing. The way to check is to break the code on purpose, for example by removing the watermark check in a telemetry consumer. The test must then fail.
- **Static checks and type checks** run in the first CI stage.
- **Integration tests** in Docker Compose run against real PostgreSQL and Redis. Mistakes in generated database code show up there, including row-level security mistakes.
- **A reviewed merge request.** Every change reaches production only through review and the pipeline.

Two rules protected the data. Secrets or tenant data never went into a prompt. And changes to tenant isolation, IAM policies or the MCP tool allowlist needed the closest review. In those areas a small mistake can expose another tenant's data.

</details>
