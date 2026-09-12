# API Contracts and Read Paths

> 21 questions on [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") contract design and versioning, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") and [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") semantics, idempotent and bulk operations, Elasticsearch mappings, analyzers and relevance, and [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") caching, invalidation and eviction. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except API-06, API-09, API-10, API-11, API-12, API-13, API-14, API-15, API-16, API-18, API-19, API-20 and API-21, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — API-01, API-03, API-04, API-06, API-08, API-10, API-11, API-12, API-13, API-14, API-15, API-16, API-19, API-21
- **retail-software-marketplace** — API-01, API-03, API-04, API-06, API-07, API-08, API-09, API-10, API-16, API-17, API-18, API-19, API-20, API-21
- **general** — API-02, API-05

---

## 1. Contracts and versioning

---

### API-01. What makes an API "good"?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
That a competent consumer can predict it without asking you. Concretely: one executable contract rather than a document, a resource model that stays consistent as it grows, honest status codes and machine-readable errors, safe retries on every mutation, pagination and result sizes that do not degrade with data volume, and an evolution story that does not break the caller you cannot deploy alongside.

<details>
<summary><strong>Detailed answer</strong></summary>

**The contract is a build artefact, not documentation.** In both designs the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models define every request and response body and FastAPI emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document from them, and that document is contract-tested in the pipeline. The marketplace goes one step further and builds its admin console against the same versioned public API rather than a private backend — which costs a chattier user interface on entity screens and buys the guarantee that no admin capability exists that the public contract does not already describe and test. A specification maintained by hand alongside the code is a specification that is wrong, and the consumer finds out at runtime.

**Predictability across the surface.** Same pagination everywhere, same error envelope everywhere, same identifier style, same date format, same naming. Both designs use cursor pagination on every collection because offset pagination degrades on exactly the deep pages a comparison or timeline workflow produces — but the more important property is that it is *everywhere*, so a consumer learns it once.

**Honest semantics.** The status code is part of the contract: `201` with a `Location` for a creation, `202` when the work is genuinely asynchronous and a status [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") is returned with it, `409` for a state conflict, `422` for a body that fails validation, `503` when a dependency is down and a retry is appropriate. Error bodies are [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details — a stable `type`, a human `detail`, and field-level errors — because a client cannot branch on prose. The cancer platform returns `202 Accepted` for a check-in rather than pretending the write is synchronous, and returns a status URL for page generation rather than holding a connection open for 45 seconds. Lying about which of these a call is causes more consumer bugs than any amount of naming.

**Safety and bounds.** Every mutation accepts an `Idempotency-Key` so a retry after a timeout cannot double-apply — required on all `POST` mutations in the cancer platform, and required on `POST /v1/connections` in the marketplace because a double-submitted connection request must not create two threads and bill the vendor twice. Responses are bounded: the marketplace returns `total_estimate` capped at 1,000 rather than an exact count, because an exact count over a filtered index scan costs as much as the page itself, and a sourcing workflow needs "1,000+" rather than "1,247". Similarly, the API refuses an uncategorised query carrying more than two facet predicates — a small product constraint that removes a whole class of performance problem.

**Evolution.** Version in the path (`/api/v1`, `/v1`), and inside a version evolve additively: new optional fields, new endpoints, never a changed meaning or a removed field. A consumer you cannot deploy in lockstep with is the normal case, so the test is whether the old client keeps working unchanged.

**Authorization at the resource, not the route.** A route-level check tells you the caller is a clinician; it does not tell you they may see *this* patient. Good APIs answer both, and answer the second in one place rather than per endpoint.

**And the property that is easy to forget:** the API should be observable from the outside. A request identifier echoed back, a propagated trace header, and a status endpoint for anything asynchronous mean a consumer can tell you *which* call failed instead of "it was slow yesterday".

</details>


---

### API-02. Explain DNS, TCP and HTTP. What happens when I type https://api.example.com/users into my browser?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
Name resolution finds an address, a [TCP](https://datatracker.ietf.org/doc/html/rfc9293 "Transmission Control Protocol — Provides reliable, ordered byte-stream delivery between two endpoints") handshake establishes a reliable byte stream to it, a [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") handshake authenticates the server and encrypts that stream, and HTTP is the request-and-response protocol spoken inside it. Concretely: DNS lookup, three-way handshake, TLS 1.3 handshake with protocol negotiation, the request, the server's work, the response — and then the connection is kept alive so the next request skips almost all of it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before any packet.** The browser parses the URL and checks its HTTP Strict Transport Security list; for a host that has declared it, `http://` is rewritten to `https://` locally and a downgrade is never attempted on the wire.

**DNS — turning `api.example.com` into an address.** The stub resolver checks its cache, then the operating system's, then asks a recursive resolver. On a cold cache the recursive resolver walks the hierarchy — a root server for `.com`, the `.com` servers for `example.com`'s authoritative nameservers, those for the record itself — and caches each answer for its time-to-live. In practice a global service returns an anycast address or a provider-specific alias that resolves to the nearest edge. Two operational consequences worth stating: **the record's time-to-live is your failover speed**, because clients keep using a cached address until it expires; and DNS resolution is a synchronous dependency that can fail on its own, which is why resolver latency and failures deserve a metric.

**TCP — a reliable ordered byte stream.** A three-way handshake, SYN, SYN-ACK, ACK, costing one round trip, establishes sequence numbers and window sizes. From there TCP provides ordering, retransmission and flow control. Its relevant cost is that every new connection pays that round trip plus the slow-start ramp, which is why connection reuse matters so much and why a client library that opens a fresh connection per request is measurably slower.

**TLS — authenticating and encrypting the stream.** TLS 1.3 completes in one round trip. The client sends its supported parameters, a key share, the Server Name Indication naming the host — which is how one address serves many certificates — and the Application-Layer Protocol Negotiation list offering HTTP/2. The server responds with its certificate and key share, and traffic is encrypted from that point. The client validates the chain to a trusted root, checks the name and validity, and consults revocation. Session resumption lets a returning client skip most of this, and 0-RTT resumption removes the round trip entirely at the cost of replay exposure — so it is appropriate for idempotent requests only.

**HTTP — the conversation inside the tunnel.** Over HTTP/2 the request is a set of compressed header frames and, for a `GET`, no body: method `GET`, path `/users`, `authorization`, `accept`, and typically a propagated trace header. Multiple requests are multiplexed over the one connection rather than queued behind each other.

**What the server does with it**, which is where the previous answers connect: the edge terminates TLS, a gateway validates the token, a load balancer picks a healthy instance, and the application resolves dependencies, validates, handles, serializes and returns a status code, headers and body. The response travels back over the same connection, which is **kept alive** — so the second request to the same host pays neither the DNS lookup, nor the handshake, nor the TLS negotiation. That is the single biggest reason to reuse a client object rather than constructing one per call.

**The detail I would add.** Each of those stages is separately observable and separately breakable, and naming which one is slow is most of the work in a "the API is slow from our office" report — DNS resolution time, connect time, TLS handshake time and time-to-first-byte are four different numbers, and any HTTP client can be made to report all four.

</details>


---

### API-03. What is the difference between HTTP 401 and 403?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
`401` means the request is not authenticated — no credential, expired, or invalid — and the response must say how to authenticate; `403` means authenticated but not permitted, and repeating with the same credential will not help.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction as the specification draws it.** `401 Unauthorized` is a misnomer — it means *unauthenticated*, and a compliant response carries a `WWW-Authenticate` header telling the client what to present. The right client reaction is to obtain a credential and retry. `403 Forbidden` means the server understood who you are and is refusing anyway; retrying with the same identity is pointless, so a client must not treat it as retryable. Getting this wrong causes real bugs: a client that sees `403` on an expired token loops through a refresh it does not need, and a client that sees `401` for a permission failure logs the user out for no reason.

**Which one to return when.** No token, malformed token, bad signature, expired token, unknown key: `401`. Valid token, wrong scope, wrong role, wrong account type, wrong tenant: `403`. The cancer platform's gateway does exactly this — a clinician token presented on a patient route is rejected with `403` at the edge, because the token is perfectly valid and simply has the wrong audience for that plane.

*The other half of this question — what should happen when an authenticated user reaches for another customer's data — is **SEC-05** in [security-and-identity.md](security-and-identity.md).*

</details>


---

### API-04. How do you version an API, and how do you tell a breaking change from a safe one when the consumer is another team you cannot deploy with?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
A major version in the path (`/v1`) for changes that cannot be made compatibly, and additive evolution inside it for everything else. The test for breaking is not a judgement call: a change is safe if every request a conforming old client can send still succeeds and every response it receives still parses under its old schema — which is a property a generated contract and a contract test can check, rather than something a reviewer eyeballs.

<details>
<summary><strong>Detailed answer</strong></summary>

**The scheme, and why.** Both these systems version in the path — `/api/v1` and `/v1` — because it is visible in logs, trivially routable at the gateway, and unambiguous in a bug report. Header or media-type versioning is more theoretically pure and worse in practice: it is invisible in an access log, easy to omit, and harder to route on. The important part is not which scheme, it is that **a new major version is a last resort**, because it means running two implementations and migrating every consumer. Most evolution should be additive inside the current version.

**The compatibility rules, stated as rules so they are checkable.**

*Safe, additively:* adding an optional request field with a sensible default; adding a response field; adding a new endpoint; adding a new enum value **only if** the contract already told clients how to handle unknown values; relaxing a validation rule; adding an optional query parameter.

*Breaking:* removing or renaming any field; making an optional request field required; narrowing a type or a validation rule; changing the meaning of an existing field while keeping its name — the worst one, because nothing detects it; changing default sort or pagination behaviour; changing a status code for an existing condition; changing an error code's meaning; removing an enum value a client may send.

*The two that generate arguments:* **adding a response field** breaks a client that rejects unknown fields, and **adding an enum value** breaks a client that switches exhaustively. Both are really contract questions — if the published contract says clients must tolerate unknown fields and unknown enum values, then they are safe and a client that breaks is non-conforming. If it does not say so, they are breaking. So I would put that statement in the contract on day one, because it is the cheapest thing you will ever do for your future self.

**Making the check mechanical rather than social.** Pydantic models define every request and response, [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document, and **that document is the published contract and is contract-tested in continuous integration**. That gives two things: a diff of the schema on every merge request, which makes a breaking change visible during review rather than after release; and a spec that consumers generate a client from. On this vacancy's stack the frontend generates its client from the OpenAPI document, which raises the stakes usefully — a breaking schema change surfaces as a compilation failure on their side rather than a runtime error in someone's browser, and the generated client is a strong argument for keeping the spec honest.

**When you cannot deploy together — which is the actual question.**

- **Expand/contract, exactly as with a database.** Add the new field alongside the old; populate both; announce; give a deprecation window with a date; remove only after telemetry shows nobody uses the old one. Per-field usage telemetry is what turns "I think nobody uses it" into "nobody used it in ninety days", and it is worth the instrumentation.
- **Tolerant reading on our side too.** We are somebody's consumer as well. Ignoring unknown fields on inbound payloads means their additive change does not break us.
- **Consumer-driven contract tests where the consumer is internal.** Their expectations run in our pipeline, so we find out at merge time rather than at their deploy time.
- **`Deprecation` and `Sunset` headers plus telemetry on old-version usage**, so the deprecation is a measured process rather than an email.
- **Run both versions concurrently when a break is unavoidable**, with an explicit end-of-life date, and accept that you now maintain two. That cost is the reason to exhaust additive options first.

**And the one I would push back on.** Versioning is frequently proposed as the solution to a change that should simply not be made. If a field's meaning is changing, the right move is usually a *new field with a new name* and a deprecation of the old, not `/v2` — because `/v2` migrates every consumer for a change that affected one field. Reserve the major version for a genuine change of resource model.

</details>


---

### API-05. Design a REST API for creating and retrieving orders.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
`POST /v1/orders` with a required `Idempotency-Key`, returning `201` and a `Location`; `GET /v1/orders/{order_id}`; `GET /v1/orders` with keyset pagination and a small set of filters. State changes are explicit sub-resource actions rather than a patchable `status` field, money is integer minor units with an explicit currency, and concurrent edits are settled with `ETag` and `If-Match`.

<details>
<summary><strong>Detailed answer</strong></summary>

**Create.**

```
POST /v1/orders
Idempotency-Key: 7f1c…          (required)
{ "customer_id": "…", "currency": "EUR",
  "lines": [ { "sku": "…", "quantity": 2, "unit_price_minor": 1499 } ],
  "shipping_address_id": "…" }
→ 201 Created
  Location: /v1/orders/018f…
  { "order_id": "018f…", "status": "pending", "total_minor": 2998, "currency": "EUR", … }
```

Four decisions in that block are worth defending. The **idempotency key is required, not optional**, because a client that retries a timed-out create has no other way to avoid a duplicate order — and I would return the stored original response for a repeat of the same key, and `409` for the same key with a different body. **Money is `*_minor` integers plus an [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 4217 currency code**, never a float; the marketplace schema does exactly this with `price_minor bigint` and `currency char(3)`. **The server computes the total**, because a client-supplied total is a pricing vulnerability. And **line items are part of the create**, not a sequence of `POST /orders/{id}/lines` calls, because an order with no lines is not a valid intermediate state and should not be reachable.

**Read.**

```
GET /v1/orders/{order_id}          → 200 + ETag
GET /v1/orders?status=pending&created_after=…&cursor=…&limit=50
                                   → { items: [...], next_cursor: "…" }
```

Keyset pagination on `(created_at, order_id)` rather than `OFFSET`, so page 40 costs what page 1 costs. An opaque cursor, so the ordering key can change without breaking clients. `limit` capped server-side. The list returns summaries and the detail endpoint returns lines and history, because a list of 50 fully-expanded orders is a payload nobody wanted.

**State transitions as actions, not as a patchable field.**

```
POST /v1/orders/{id}:cancel   { "reason": "customer_request" }
POST /v1/orders/{id}:confirm
```

`PATCH {"status": "cancelled"}` looks tidier and is worse: it invites an arbitrary transition, it has nowhere to carry the reason a cancellation needs, and it makes the state machine implicit. An explicit action endpoint is authorizable on its own, auditable on its own, and returns `409` when the transition is illegal from the current state — `cancel` on a shipped order is a conflict, not a validation error.

**Concurrency.** The detail response carries an `ETag`; an update requires `If-Match`, and a mismatch is `412 Precondition Failed`. That is optimistic locking expressed in the protocol, and it is the right default for a resource a human edits — the alternative, last-write-wins, silently discards someone's change.

**What I would say about the parts people miss:**

- **Partial failure on a bulk endpoint.** If `POST /v1/orders:bulk` exists, it returns `207`-style per-item results with a stable index, never a single `200` that hides three failures.
- **Asynchrony where it is real.** If confirming an order triggers payment capture that takes seconds, the action returns `202` with a status URL rather than holding the connection. And the state change plus the event that announces it commit together through an outbox, so "the order was confirmed but nothing downstream heard" is not a reachable state.
- **Authorization is per order, not per route.** A customer may read their own orders; a support agent may read any, and that read is audited.
- **Retention and immutability.** An order is a commercial record. Cancellation is a state, not a delete; `DELETE /v1/orders/{id}` should not exist.

</details>


---

### API-06. How do you agree an API contract before either side has built anything?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By writing the typed models first and publishing the generated document as a draft, so the discussion is about a concrete artifact rather than about intentions. The frontend can generate a client and work against a stub while the implementation is still being written.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not a document written by hand.** A hand-written specification diverges from the implementation immediately and nobody notices, because nothing checks it. If the document is emitted from the typed models that the code actually uses, it cannot describe something the service does not do — the schema is executable rather than described. So the sequence is: write the models, emit the document, publish it as a draft, and only then write the handlers.

**What the conversation is about, given a draft.** Not field names, mostly — those settle in minutes once there is something to look at. The useful discussion is about shape, and it is worth having deliberately:

- **What one screen needs in one call.** If a view always needs a list plus one field from each related entity, that field belongs in the list response. Designing endpoints around screens rather than around tables is what prevents a chatty interface, and it is far easier to argue about while the response is still a model in a branch than after both sides have built against it.
- **Where a batch verb is needed.** A comparison view needing two to five items should be one request, not five, and that is a contract decision rather than an optimisation.
- **What is optional versus nullable**, since those generate different types and the distinction is invisible until someone's client breaks.
- **What the error shapes are.** If only the success shape is declared, every consumer invents its own failure handling. Declaring the error responses is part of the contract, not an afterthought.
- **Which enumerations are open.** A closed set generates a closed type, and adding a member later breaks strict clients.

**Working in parallel after that.** The frontend generates a client from the draft and works against a mock served from the same document, so both sides progress against one artifact. The contract test in the pipeline diffs the emitted document against the published one, so if the implementation drifts from what was agreed, it is a red build rather than a discovery.

**What I ask for in return.** That they regenerate in their own pipeline against the latest published document, so drift shows up as a red build on their side too. And that changes requested after agreement come as a change to the document rather than as a message — because otherwise the contract quietly becomes whatever was said in a call, which is the state the whole arrangement exists to avoid.

</details>

---

## 2. Idempotency and bulk operations

---

### API-07. An endpoint takes a list of identifiers and acts on all of them. What failure modes do people miss, and what does the response body look like when half of them fail?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
The missed failure modes are almost all consequences of one decision nobody made explicitly: whether the operation is atomic or per-item. Everything else — partial failure, retry semantics, unbounded input, duplicate ids, mixed authorization outcomes — follows from that. When half fail, the response has to be per-item and machine-readable: a stable identifier per entry, its own status, and an error code the client can branch on, never a prose summary.

<details>
<summary><strong>Detailed answer</strong></summary>

**The decision that has to be made first.** All-or-nothing, or best-effort per item? Both are defensible, and the failure is leaving it implicit, because then the answer varies by which exception fired. A bulk import of vendor catalogue rows is validated wholly and fails wholly — rows land in staging, are checked against the category schema, and nothing moves into the live tables unless the file is acceptable, with a per-row `error_digest` explaining why. A bulk archive of listings is per-item, because one bad id is no reason to refuse the other forty-nine. State it in the contract, and make the status code match: `200` or `207` for partial, never `200` with failures buried in the body and never `500` because one item failed.

**What people miss.**

- **Unbounded input.** No maximum list length, so someone sends 100,000 ids and the request times out halfway with an unknown amount applied. A hard cap in the schema — 50, 200, whatever the operation supports — plus an asynchronous job endpoint for genuinely large work. The marketplace draws this line explicitly: a 20,000-row import is not a request; it is an upload that returns a job id, chunked into 500-row tasks with a status endpoint the workspace polls.
- **Retry after a partial failure.** The client retries the whole list, including the items that succeeded. Without per-item idempotency you double-apply. The key must be per item — or derived from the operation and the item id — not per request.
- **Duplicate ids in one list.** `[a, a, b]`. Does `a` get processed twice? Deduplicate on arrival and say so.
- **Mixed authorization outcomes.** Some ids belong to the caller's organisation and some do not. The unsafe response tells the caller which ids exist but are forbidden — that is an enumeration oracle, and in a marketplace where competitors share the platform it matters. `not_found` for anything outside the caller's tenant scope, uniformly, so the response cannot be used to probe.
- **Ordering and interdependence.** If the items are not independent, a partial application can leave an inconsistent state that neither a retry nor a rollback repairs.
- **One transaction for the whole list.** A 500-item batch in one transaction holds locks for its duration, risks deadlock against a concurrent batch in a different order, and rolls back everything on the last item's failure. Chunk it, sort by primary key, and commit per chunk.
- **The timeout.** Fifty items times 200 ms is ten seconds, which is past most client and gateway timeouts. The client then retries, and now two runs are in flight.
- **No per-item observability.** Only the request is traced, so a failure inside item 37 is unattributable.

**The response shape.** Per item, with a stable identifier, a status, and a structured error:

```json
{
  "summary": { "requested": 4, "succeeded": 2, "failed": 2 },
  "results": [
    { "id": "p_01", "status": "ok" },
    { "id": "p_02", "status": "ok" },
    { "id": "p_03", "status": "error", "code": "not_found", "detail": "No such product for this organisation." },
    { "id": "p_04", "status": "error", "code": "conflict", "detail": "Listing is archived and cannot be republished.", "retryable": false }
  ]
}
```

The properties that matter: the client can retry precisely the failed subset; `code` is a stable enumeration it can branch on while `detail` is human text that may change; `retryable` distinguishes a transient failure from a permanent one so a client does not hammer a validation error; and the order and identifiers let it reconcile against what it sent. `RFC` 9457 problem-detail bodies are the convention in both these systems for single-resource errors, and the per-item objects follow the same field vocabulary so clients learn one error model.

**Response codes.** `207 Multi-Status` if the contract embraces it; otherwise `200` with the per-item statuses, documented. What I would not do is return `400` for a partial success — the request was valid and two items were applied, and a `400` invites a client to retry the whole thing.

</details>


---

### API-08. What happens if the client sends the same POST request three times?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By default, three of whatever it does — and this is the normal case, not a client bug, because a retry after a timeout cannot tell a lost response from a lost request. The design answer is an idempotency key that makes the second and third calls return the first call's result, backed by a uniqueness constraint in the database, because the key store is an optimisation and the constraint is the guarantee.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the three come from.** A human double-clicking is the least interesting source. The two that matter are a client that timed out and retried — having no way to know whether the server committed before the connection dropped — and infrastructure that retried on its own, which gateways and [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") layers do more often than people expect. So duplicate delivery is a property of the network, and "tell clients not to do that" is not a design.

**The mechanism.** The client generates a key per logical operation and sends it as `Idempotency-Key`; it reuses the same key across retries of that operation, and generates a fresh one for a genuinely new attempt. Server-side:

1. Look the key up. If a completed record exists, **return the stored response** with its original status code — not a `409`, because the client's goal is the outcome, and a retry that returns `201`-equivalent semantics is exactly right.
2. If the key exists but the request body's fingerprint differs, return `422` or `409`. Reusing a key for a different operation is a client bug and should be loud.
3. If the key exists and is still in flight, return `409` with a retry hint rather than starting a second execution.
4. Otherwise claim the key, execute, and store the response.

**Why the client generates the key, and why it is required.** A server-generated key is useless here — the client cannot ask for one, because asking is itself a request that can fail. And `Idempotency-Key` is required on all mutating `POST`s, not optional: an optional idempotency mechanism is one that is absent exactly when someone forgot.

**The key is scoped and it expires.** Scoped to the tenant, so one organisation cannot collide with or probe another's keys — in the marketplace that is what `UNIQUE (retail_group_id, idempotency_key)` buys beyond deduplication. Expiry of about 24 hours, matching the outer bound of any sane retry.

**And the part that makes it actually correct.** Both designs say this in the same words, from opposite directions. The cancer platform's Redis keyspace notes that `idem:` keys are the *optimisation* for duplicate suppression, **not the guarantee** — losing them to a flush permits a duplicate to be reprocessed, so any mutation that must not double-apply carries a natural key in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"). Check-ins are unique on `(patient_id, recorded_for)` and the projection is an `INSERT … ON CONFLICT DO UPDATE`, so a redelivered message is arithmetic rather than a bug. The marketplace does the same at the commercial boundary: `connection_request` carries `UNIQUE (retail_group_id, idempotency_key)`, and its own schema note says the database, not the cache, is what finally prevents a duplicate thread and a duplicate charge. `billing_charge` adds `UNIQUE (connection_request_id) WHERE kind = 'connection'`, so a connection bills at most once — enforced in the schema rather than in retry logic, which is the distinction worth drawing.

**The test of whether the guarantee is real** is to flush the key store and replay the request. If a duplicate appears, the guarantee was never there — it lived in the cache, which is the one place both designs say it must not live.

**The natural key is better than the generated key wherever one exists,** because it does not depend on the client behaving. One check-in per patient per day is a domain truth; an idempotency key is a client promise.

**What the key cannot protect.** Side effects outside the transaction. If the first attempt committed and then sent an email, a retry that returns the stored response does not send a second email — but a crash between the commit and the send means no email at all. That is why anything that must follow a commit goes through the outbox rather than being fired inline: the state change and the intent to notify commit together, and the relay delivers at-least-once afterwards.

**The same ambiguity exists past the API.** At-least-once delivery between the broker and the consumer makes duplicates normal there too, and exactly-once does not exist across a broker and a database without a distributed transaction. So every consumer is idempotent against the same natural keys, and the API and the message path share one mechanism rather than two.

**And where duplicates are simply accepted.** The cancer platform's reminder path can deliver twice under a receipt-loss race, and the design says so explicitly and takes it: a patient seeing a reminder twice is a far better failure than not seeing it at all. Being able to name which duplicates you have chosen to tolerate, and why, is a stronger answer than claiming you have eliminated them.

</details>


---

### API-09. A bulk endpoint takes a list of identifiers. What failure modes do people miss?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
An unbounded list, partial failure with an all-or-nothing response, losing the ordering the caller sent, and silently dropping identifiers the caller may not access — which turns an authorization boundary into an enumeration oracle if it is done inconsistently.

<details>
<summary><strong>Detailed answer</strong></summary>

**The failure modes, in the order they bite.**

- **No cap on the list.** A batch endpoint added to fix an N+1 becomes a way to ask for fifty thousand objects in one request. That is an unbounded query, an unbounded response and a denial-of-service primitive handed to any authenticated caller. The cap is part of the contract and it is validated, not hoped for. The comparison endpoint on the marketplace takes between two and five products for exactly this reason — the bound comes from the product requirement, which is the best kind of bound.
- **Partial failure with no partial result.** Forty-nine of fifty found, one missing, and the whole request returns an error. The caller has no way to make progress. The response should be per-item: what was found, what was not, and why, with an overall status that says the request itself succeeded.
- **Order and duplicates.** Callers frequently assume the response is in the order they sent, and a bulk query returns whatever the database returns. Either key the response by identifier — which I prefer, because it removes the assumption entirely — or state the ordering guarantee explicitly. Duplicates in the input need a defined behaviour too.
- **Authorization applied inconsistently.** This is the one with a security consequence. If a forbidden identifier returns "not found" and a nonexistent one returns "not found", fine. If one returns "forbidden" and the other "not found", the endpoint tells an attacker which identifiers exist — and a bulk endpoint lets them ask five hundred at a time. On a marketplace where a vendor enumerating the retailer directory would be commercially fatal, that is not a theoretical concern. The scope filter is applied in the query, and unauthorised items are indistinguishable from absent ones.
- **The internal N+1.** A batch endpoint that loops internally has moved the problem rather than fixed it. It has to become one query with an `IN`, one multi-get, one bulk document fetch.
- **Rate limits counted per request rather than per item.** One request asking for five hundred items is not the same load as one asking for one, and a limiter counting requests will happily allow the expensive pattern.

**The general principle.** A batch endpoint is a load amplifier with the amplification factor chosen by the caller. Every limit, every check and every cost has to be reasoned about per item, not per request.

</details>

---

## 3. Search

---

### API-10. What is the difference between filtering and ranking, and why does confusing them cause most bad search?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A filter decides whether a document may appear; ranking decides where. They are different questions with different correctness requirements, and treating a filter as a strong ranking signal is how a search returns something it should never have returned at all.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why they must be separate.**

- **A filter is binary and it is a correctness property.** Whether the caller may see this document, whether it is published, whether it is within the requested date range. There is no "slightly" — a scope filter that is expressed as a score boost means a sufficiently strong text match can outrank it, and now the search has disclosed something. On a system where authorization is the whole threat model, that is not a subtle bug.
- **Ranking is continuous and it is a quality property.** Which of the permitted documents is most useful. Getting it wrong is disappointing; getting the filter wrong is an incident.

**The engineering consequences of separating them.** Clauses that only include or exclude go in filter context, where they contribute nothing to the score and are cacheable — which is also a real performance benefit, because a cached filter bitmap is reused across queries. Scoring clauses are only the ones expressing relevance. The scope fields are on every document and the query is always wrapped in a filter on them, as an index-level property rather than an application convention, so a query written by someone who forgets returns nothing rather than someone else's data.

**Where the confusion actually shows up in practice.**

- **Status expressed as a boost.** "Prefer published listings" rather than "only published listings" — and eventually a draft appears because its text matched better. The marketplace instead carries the status predicate in a partial index, which keeps unpublished rows out of the index entirely and removes the filter from every plan.
- **Recency as a filter when it should be a signal.** The inverse mistake: hard-cutting anything older than a year, so a highly relevant older document is unreachable and nobody knows why. Recency belongs in the score.
- **A relevance threshold used as a filter.** Scores are not comparable across queries, so a fixed cutoff means results vanish for some queries and not others, with no pattern anyone can explain.

**How I keep it honest.** The filter set is tested for absence — a query from one scope must return zero documents from another, asserted rather than assumed. Relevance changes are evaluated against a judged set, so a boost adjustment is measured rather than eyeballed. And no relevance work is ever permitted to touch the scope filter, which is stated as a rule rather than left to judgement, because that is the one clause where a well-meant tuning change becomes a disclosure.

</details>


---

### API-11. Describe your experience with Elasticsearch. What did you index, and how did you keep it in step with the database?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Clinical content search on the health platform — visit notes, guidance and visit history behind a single alias. It is kept in step by never being written directly: the relational store is the source of truth, a transactional outbox drives an index consumer, and the whole index is rebuildable from the primary stores.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it.** Documents for the searchable clinical content, each carrying the scope fields that decide who may see it — the patient identifier and the care-team identifiers — alongside the searchable text and the filterable metadata. The scope fields are on every document deliberately, so the filter is an index-level property rather than an application convention.

**How it stays in step, which is the part that matters.** The application never writes to the index from a request handler. The sequence is: the fact is written to the relational store, and in the same transaction an outbox row is written. A relay publishes that row and only then marks it published. An index consumer reads the event and bulk-indexes. That single-writer rule is what makes dual-write drift impossible — there is no code path where the database and the index can disagree because one write succeeded and the other did not.

**Freshness is stated as a composed budget rather than asserted.** The relay under a couple of seconds, plus the bulk flush interval, plus the index refresh interval, which together give a newly saved note searchable within about eight seconds at the median. The useful property of writing it as a sum is that it shows tightening any single component alone buys nothing.

**Rebuildability, and why it is the important property.** The index holds nothing that is not derivable from the relational and document stores, so losing the cluster entirely is a rebuild rather than a data loss. That is what makes the disaster recovery plan honest — and because a mitigation nobody has run is an assumption, the rebuild is rehearsed quarterly with a document-count reconciliation between sources and index.

**What I would flag as the operational risk.** A consumer that stops is silent: search keeps working, every request is fast, and the results simply stop including anything new. So the metric that matters is the lag from the source event's timestamp to the index write, alerted on, because nothing else surfaces it.

**And the honest limit of my experience.** I ran this at a scale of a couple of million documents on a self-managed cluster in the platform's own cluster — real operations including shard sizing, replica counts and version upgrades, but not a very large multi-node search estate. What I have not done is run a cluster at tens of terabytes with hot-warm-cold tiering.

</details>


---

### API-12. Explain mappings and analyzers, and why a mapping change is harder than a schema change.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
A mapping declares each field's type and how text is analysed into terms; an analyzer is the pipeline that turns text into those terms at index time and at query time. Most mapping changes cannot be applied in place, because existing documents were already tokenised under the old rules — so the change is a reindex, not an alter.

<details>
<summary><strong>Detailed answer</strong></summary>

**Analyzers, concretely.** A character filter, a tokenizer, then token filters — lowercasing, stop words, stemming, synonyms. Analysis happens twice: at index time, producing the terms stored in the inverted index, and at query time, producing the terms to look up. They must agree, or nothing matches. This is the source of the most common confusing bug in search: a field analysed one way and queried another, giving zero results for a document that is obviously there.

**Where the clinical synonym filter earns its place.** The same condition appears as a clinical term, an abbreviation and a lay phrase, and a clinician searching one must find a note written with another. That mapping is what makes the search useful rather than literal. The operational consequence is worth knowing — synonyms applied at index time require a reindex to change, while synonyms applied at query time can be updated without one but cost more per query. Choosing the second is usually right precisely because the vocabulary will change.

**Why a mapping change is not an alter.** The inverted index holds terms produced by the old analyzer. Changing the analyzer does not retroactively re-tokenise them. Changing a field's type is generally not permitted at all. So the change is: create a new index with the new mapping, reindex into it, and switch.

**Which is why every index sits behind an alias**, and this is the single most important operational decision in a search deployment. The application only ever talks to the alias. A mapping change becomes: build the new index, reindex, verify document counts and spot-check queries, then atomically move the alias. Zero downtime, and the rollback is moving the alias back — which is why the old index is kept until confidence is established rather than deleted at switchover.

**During the reindex**, new writes still arrive. Either dual-write to both indices for the window, or reindex to a point in time and then replay events since. The event-driven design makes the second option straightforward, because the outbox is an ordered log of what changed.

**What I would add for anything non-trivial.** A field that is both analysed for search and kept as an exact keyword for filtering and aggregation — you almost always need both, and adding the second later is another reindex. And dynamic mapping switched off in production: a document with an unexpected field silently creating a mapping is how an index ends up with a type nobody chose and cannot change.

</details>


---

### API-13. How do you tune relevance, and how do you know a relevance change is actually an improvement?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
By evaluating against a judged set rather than by looking at results. Relevance changes are the easiest thing in engineering to fool yourself about — every change looks better on the three queries you tested it with, which are the queries that motivated the change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The levers, briefly.** Field boosting, so a match in a title outweighs a match in the body. Analyzer choices — stemming, synonyms, handling of abbreviations. Phrase matching and proximity for multi-word queries. Filters versus scoring clauses, which matters both for correctness and for cost: a clause that only includes or excludes belongs in filter context, where it is cacheable and does not contribute to the score. And a reranking pass over the top results where the first-stage retrieval is broad.

**The problem with tuning by inspection.** You change a boost, run your query, the result you wanted moves up, you ship it. What you cannot see is the thousand queries it made worse. Relevance is a distribution and inspection samples it in the least representative way possible.

**What I would insist on instead.**

- **A judged set.** A few hundred real queries with relevance labels for the returned documents. On a clinical system those judgements have to come from clinicians — I cannot label whether a note is relevant to a query, and pretending otherwise produces a metric that measures my guesses.
- **A metric that reflects the interface.** Something rank-weighted over the first page, because that is what a user sees. Precision over the whole result set is measuring something nobody experiences.
- **Baseline first, then change one thing.** Two changes at once and you cannot attribute the movement.
- **Look at what regressed, not just the aggregate.** A change lifting the mean while badly breaking one query class is usually a bad change, and the aggregate hides it.
- **Online evidence where it is available.** Click and reformulation rates, with the caveat that they measure engagement rather than correctness, and on a clinical tool that difference is not academic.

**Where the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") claims a relevance improvement**, the honest framing is that the number comes from an offline evaluation on a judged set with clinician labels, comparing a defined baseline against the tuned configuration. What would make it a false claim: measuring on the queries the change was designed for, changing the judged set at the same time as the configuration, or reporting an aggregate that a subgroup regression is hiding. I would rather state the evaluation method with the number than state the number alone.

**And a constraint that outranks relevance here.** Nothing may be returned outside the caller's scope, and the scope filter is not a ranking input — it is a filter, applied at the index level, and no relevance tuning is permitted to touch it.

</details>


---

### API-14. What do you use Kibana for beyond looking at logs?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
As the single pane where the two telemetry planes meet — application traces, cluster metrics and the cloud provider's own diagnostic logs shipped into the same store. Its real value is being the one place you can follow a request across a broker boundary rather than assembling two half-stories during an incident.

<details>
<summary><strong>Detailed answer</strong></summary>

**The joining problem it solves.** The estate spans services in the cluster and managed cloud services, so there are inevitably two sources of telemetry. What makes them one system is the trace context propagating on every hop — including the message headers on the broker, the transport bridge and the service bus — and the cloud provider's diagnostic logs being shipped into the same store as everything else. Without that, a reminder failing between a worker and the delivery function is two disconnected halves, and you discover that during an incident rather than before one.

**What I actually build in it.**

- **A dashboard per objective rather than per service.** The question during an incident is "are we meeting the reminder delivery target", not "how is service seven". A per-service dashboard forces the person under pressure to assemble the answer.
- **Saved searches for the recurring investigations.** "All events for this correlation identifier across every service" is the query you want to run in an incident, not compose in one.
- **The traces view for latency work.** Where the time actually goes in a request, including the spans for connection acquisition and outbound calls, which is what separates waiting from working.
- **Ad hoc analysis over structured logs.** Because logs are structured with trace identifiers, service, module and actor kind, they can be aggregated as data rather than grepped as text — error rates by reason, a distribution of a field, the shape of a spike.

**Two rules I hold about it.**

- **No clinical free text, no symptom values, no message bodies ever reach it.** A redaction filter drops fields marked sensitive at the formatter, and a pipeline check fails the build if a log call passes a model containing one. A log store is not a place where sensitive content is acceptable just because it is internal.
- **Audit is a database table, never a log stream.** Conflating them means the log retention policy silently becomes the audit retention policy, which is a compliance failure nobody notices until someone asks for a record older than the retention window.

**And what I would not use it for.** Alerting that needs to be reliable during a partial outage — the alerting path should not depend on the same store that may be the thing failing. Metric-based alerting on the metrics system is the more robust arrangement, with the log store as the investigation tool.

</details>


---

### API-15. How do you run a reindex with no search downtime?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Through an alias, always. Build the new index alongside the old, reindex into it, verify counts and sample queries, then move the alias atomically. The application never names a concrete index, so the switch is invisible and the rollback is moving the alias back.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.**

1. **Create the target index** with the new mapping and settings. Replica count set to zero and the refresh interval disabled during the bulk load, because both cost throughput you do not need until the index is live — then restored before the switch.
2. **Reindex.** From the existing index where the source documents are unchanged and only the mapping differs; from the primary stores where the document shape itself is changing, because then the old index is the wrong source. On this system the second path is always available, which is the point of the index holding nothing that is not derivable.
3. **Handle writes arriving during the window.** Either write to both indices for the duration, or reindex to a point in time and replay the events since from the outbox. The second is cleaner when there is an ordered event log, which there is.
4. **Verify before switching.** Document counts reconciled against the source, a set of known queries run against both indices and compared, and a spot check on documents that exercise the changed mapping. Counting is the cheapest assertion that catches a silently truncated reindex.
5. **Move the alias in one atomic action** that removes the old index and adds the new one. No window where the alias points at nothing or at both.
6. **Keep the old index** until confidence is established. It is the rollback, and deleting it at switchover converts a two-second recovery into a rebuild.

**What goes wrong when people skip the alias.** The application holds a concrete index name, so the switch means a configuration change and a deploy, which means a window where some pods query the old index and some the new. That is not a catastrophe for search, but it is avoidable for free — and the alias also makes the emergency case work, where you need to point at a rebuilt index right now.

**On throughput during the reindex.** It competes with production traffic for the same cluster resources. It is throttled deliberately and run when traffic is low, and the cluster's own load is watched during it. A reindex that saturates the cluster degrades live search, which is the outcome the whole exercise was meant to avoid.

**And the same procedure covers disaster recovery**, which is why it is worth rehearsing rather than documenting. Losing the cluster entirely is the same sequence starting from step two, and having run it quarterly means the duration is a number rather than a hope.

</details>

---

## 4. Caching

---

### API-16. Describe your experience with Redis. What did you use it for beyond caching?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Cache-aside for the hot catalog reads, a task broker for one system's workers, idempotency keys, a per-vendor concurrency semaphore, and rate limiting. The important decision was running two separate instances — cache and broker — rather than one with separate logical databases.

<details>
<summary><strong>Detailed answer</strong></summary>

**The uses, and what each demands of the deployment.**

- **Cache-aside on the catalog read path.** Listing details keyed with the revision in the key, search result pages with a short expiry, and facet counts. Loss is acceptable by construction: a cold cache means slower reads, not wrong ones.
- **A task broker for the marketplace workers.** Completely different requirements — this is not disposable, and losing it means losing queued work. That is why it is a separate instance with different persistence and different memory policy.
- **Idempotency keys** on mutating requests, as an optimisation in front of the real guarantee. The durable guarantee is a unique constraint in the database; the cache short-circuits the duplicate before it reaches the database. Losing the keys permits a duplicate to be reprocessed, and the constraint is what makes that safe.
- **A per-vendor concurrency semaphore** so one vendor's large import cannot occupy the whole worker pool. A counter with an expiry, so a crashed worker releases its slot rather than deadlocking the vendor forever.
- **Rate limiting** as a per-subject token bucket in the application, beneath the coarser limits at the gateway.

**Why two instances rather than one with separate databases.** Because the failure modes must not be shared. A cache should evict under memory pressure — that is correct behaviour. A broker must never evict, because eviction there is silent data loss. Those are opposite memory policies and they cannot both be configured on one instance. Beyond that, a cache flush to clear a bad entry must not touch queued work, the persistence requirements differ, and a cache stampede's traffic burst must not slow down task dispatch. Two instances is a small cost for keeping a disposable store and a durable one from sharing a fate.

**What I am careful about.** Every use above is either disposable or backed by a durable guarantee elsewhere. Nothing is the sole record of anything. The moment a cache becomes the only place a fact lives, it has silently become a database without backups, and that transition happens gradually and by accident.

</details>


---

### API-17. Your cache hit ratio drops sharply with no change in traffic. Where do you look, and how do you decide whether the cache is now doing more harm than good?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
A hit ratio falls for one of four reasons: the keyspace got wider, the entries are being evicted, they are being invalidated more aggressively, or the cache lost its data. Look at key cardinality, eviction count, memory against `maxmemory`, and whether a deploy or a data change altered how keys are constructed. You decide it is doing harm when the miss path plus the lookup and write cost exceeds the direct path, or when it has started serving answers that are wrong.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where I look, and the specific signal each gives.**

1. **Key cardinality.** A hit ratio is a function of how concentrated the key distribution is. If a new filter parameter, a new sort option or a locale got folded into the key, the same traffic now spreads over ten times as many keys and each one is cold. In the marketplace the search cache is keyed on `cat:search:{filter_hash}`, and a hash over a filter set is exactly the kind of key that widens silently when someone adds a facet to the interface. That is a client-side change with no backend deploy, which is why "nothing changed" can be true and the ratio can still halve.
2. **Evictions and memory.** `evicted_keys` rising with memory at `maxmemory` means entries are being pushed out before their [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"). That is a capacity answer, and the fix is either more memory or a smaller working set — the latter usually meaning caching fewer, larger, more reusable things rather than many small ones.
3. **Invalidation volume.** An event-driven purge that is now firing far more often. The specific shape in the marketplace is a bulk import: 20,000 rows would produce 20,000 cache invalidations and 20,000 upserts if each row emitted its own event, which is precisely why the import emits one completion event and the indexer re-projects in batches of 200. A regression that reverts that batching would show up first as a collapsed hit ratio, not as an import failure.
4. **Did the cache lose its data?** A Redis failover, a restart, a `maxmemory-policy` change, a key-prefix change in a deploy. A prefix change is a total cold start that looks like a catastrophic ratio drop and resolves on its own — but only if you know to wait rather than to intervene.
5. **TTL changes.** Someone shortened a TTL for freshness and paid for it in hit ratio. This is a trade that should be made deliberately, and it often is not.
6. **A shift in the traffic *mix* rather than its volume.** The question says traffic did not change, but "same requests per second" and "same distribution" are different claims. A crawler, an integration partner, or a scripted comparison workflow enumerating listings produces the same request rate over a completely flat key distribution and no cache can help with that. In the marketplace this also has a security reading — systematic enumeration is catalogue scraping, and there are per-vendor detail-fetch caps designed to make it slow enough to notice.

**Deciding whether it is now doing harm.** Three tests:

*The arithmetic one.* The cache helps when `hit_ratio × saved_cost > lookup_cost + write_cost`. A Redis round trip is a few milliseconds; the uncached path on the marketplace search is about 45 ms in Postgres plus 25 ms in Mongo. At an 85% hit ratio that is strongly positive; at 10% you are adding 3–7 ms to nearly every request to save the database occasionally. There is a crossover, and it is worth computing rather than arguing about.

*The capacity one.* Even a poor hit ratio can be worth keeping if the backing store cannot survive the full load. The marketplace design states the number plainly: losing `redis-cache` entirely is not an outage — cache-aside means every read falls through — but latency rises from about 35 ms to about 107 ms and Postgres load multiplies roughly sixfold, and capacity is sized to survive that. Knowing that number is what turns "should we keep the cache" from an opinion into a decision.

*The correctness one, which outranks both.* A cache that serves stale data past what the product can tolerate is doing harm at any hit ratio. The structural protection here is that the listing key carries the revision — `cat:listing:{id}:v{rev}` — so a stale key is simply unreachable even if the purge message is lost; invalidation correctness depends on the revision pointer in Postgres being current, not on a message arriving. That is the pattern I would reach for generally: prefer a key design where staleness is impossible over an invalidation protocol that must not fail.

**What I would do rather than remove it.** Fix the key design first — normalise filter parameters so equivalent queries hash identically, drop parameters that do not affect the result, and cache the expensive shared fragment rather than the per-user whole. Then check the stampede protections still work, because a low hit ratio and a hot key together are how a cache expiry becomes a database incident: single-flight per key plus probabilistic early expiry bound the recomputation to roughly one per TTL regardless of concurrency, and those only help if they are still in the path.

**And one thing I would check before any of it.** Whether the ratio dropped or the *metric* dropped. A relabelled metric, a new keyspace not included in the aggregation, or a scrape failure all look identical to a real regression on a dashboard. Confirming the measurement before acting on it costs a minute and occasionally saves the entire investigation.

</details>


---

### API-18. How do you decide a cache is doing more harm than good?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
When the hit ratio is low enough that it is mostly adding a round trip and an invalidation risk to a query that was fine, when the staleness it introduces is producing support tickets, or when it has become the thing that must not fail. Any of those is a reason to remove it rather than tune it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The signals I actually look at.**

- **A low hit ratio.** A cache hitting a small fraction of the time is paying the lookup cost on every request, paying the write cost on every miss, and buying very little. Usually the cause is a key too specific — a key including a parameter that varies per caller — or a working set far larger than the memory allocated. Either way, the honest options are to fix the key, size it properly, or remove it. Leaving a low-hit cache in place is pure overhead with an invalidation liability attached.
- **Staleness producing tickets.** If people are reporting that they published something and cannot see it, the tolerance assumed at design time was wrong. Sometimes the fix is invalidation, and sometimes the honest fix is that this data should not have been cached.
- **It has stopped being optional.** The test is whether the system is correct and survivable with the cache empty. If capacity has quietly been sized on the assumption of a warm cache, then a restart or a flush is an outage, and the cache has become a load-bearing component without anyone deciding that. On the marketplace this is written down as a number instead of a hope: with the cache gone entirely, latency roughly triples and database load multiplies about sixfold, and capacity is sized so that is survivable.
- **The invalidation logic is now the complicated part.** When more code exists to keep the cache correct than to compute the value, the cache has inverted the cost it was meant to reduce.

**What I check before removing it.** Whether the underlying query is actually slow now. Caches are often added for a query that was later fixed with an index, and nobody removed the cache — so it is protecting nothing while carrying all the risk. Measuring the uncached path is a ten-minute experiment that occasionally deletes a whole subsystem.

**How I remove one safely.** Reduce the expiry progressively rather than deleting it outright, watching the database load at each step. That converts a scary change into a measured one, and if load rises unacceptably at some point, that is the evidence that the cache is genuinely needed — which is a much better basis for keeping it than the fact that it is already there.

**And the case for keeping one that looks marginal.** A cache absorbing a burst is not judged by its average hit ratio. A key that is hit fifty times in one second during a spike and never otherwise has a poor overall ratio and is doing exactly the job it exists for. So I look at the distribution rather than the mean before concluding anything.

</details>


---

### API-19. What makes cache invalidation go wrong, and what do you do about it?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Almost always a key that nobody deleted — because the delete was in a code path that failed, or because the set of affected keys is not enumerable. The structural fix is to make invalidation unnecessary: put the version in the key, so a new version is a new key and the old one simply ages out.

<details>
<summary><strong>Detailed answer</strong></summary>

**The recurring failure modes.**

- **A delete that did not happen.** The write succeeded, the invalidation was after the commit and the process died, or the call raised and was swallowed. Now a stale value is served indefinitely. This is common precisely because invalidation is usually the least important-looking line in a function.
- **An unenumerable key set.** One change affects an unknown number of cached queries. People respond with a pattern-based delete, which is a scan of the keyspace and a serious operational hazard on a large instance, or with a full flush, which converts a small update into a total cache loss and a stampede.
- **The wrong key.** Keys constructed in two places with slightly different rules — a missing parameter, a different order — so the write path deletes one key and the read path reads another. Nothing errors.
- **A cross-tenant key.** A key that omits the scope, so one organisation's cached response is served to another. That is a disclosure rather than a staleness bug, and it is the reason gateway response caching is disabled on data paths by policy rather than by omission.
- **The race.** Read misses, fetches, and writes the cache after a concurrent update has already invalidated it — so the stale value is written after the delete and lives out its full expiry.

**What I do, in order of preference.**

1. **Version the key.** Include the entity's revision. A change produces a new key, the old one is never read again and expires quietly. No delete has to succeed for correctness. This eliminates the first, third and fifth failure modes at once.
2. **Invalidate from the event, not the request.** The consumer that already handles the change deletes the keys, so invalidation is retried and dead-lettered like any other message handling rather than being a fire-and-forget call at the end of a request.
3. **Where the key set is not enumerable, do not pretend.** Use a short expiry and say so. An honest bounded staleness beats an invalidation strategy that silently misses.
4. **Build the key in exactly one place**, a single function, with the scope always in it.
5. **Never flush globally as an operational habit.** If that is the recovery procedure, the caching design has a defect.

**And the property I would state for any cache:** every cached value is derivable from a source of truth, and the system is correct with the cache empty. If that is not true, it is not a cache.

</details>


---

### API-20. Redis is memory-bound. What happens when it fills, and how do you configure for that?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
It depends entirely on the eviction policy, which is why a cache and a broker cannot share an instance. A cache should evict least-recently-used keys — that is correct. A broker or anything durable must refuse writes rather than evict, because eviction there is silent data loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the memory limit does.** When usage reaches the configured maximum, behaviour is governed by the eviction policy. With no eviction, writes are refused with an error and reads keep working. With a least-recently-used or least-frequently-used policy, keys are discarded to make room — either across all keys or only those with an expiry set.

**Why that single setting decides the architecture.**

- **The cache instance** is configured to evict least-recently-used keys with expiries. Filling up is a normal operating state, and eviction is the designed behaviour. The consequence is a lower hit ratio and more database load, which is visible in metrics and survivable because capacity is sized for a cold cache.
- **The broker instance** is configured to refuse writes rather than evict. If it evicts, queued tasks vanish with no error anywhere — the producer got an acknowledgement, the consumer never sees the task, and nothing anywhere reports a problem. A publish failing loudly is far better, because the caller can retry or the outbox can hold the row.

They are opposite settings, so one instance cannot serve both roles correctly. That is the concrete reason for two instances rather than a preference for tidiness.

**What I monitor.** Used memory against the maximum, the eviction rate, the hit ratio, and the count of keys without an expiry. That last one is the leak detector: a cache steadily accumulating keys nobody set an expiry on will eventually be entirely composed of them, and the eviction policy that only considers keys with expiries then has nothing to evict.

**Fragmentation** is worth naming because it surprises people — the ratio of memory the allocator holds to memory actually used can drift well above one, so the instance appears full while holding much less. It is a metric to watch rather than a number to assume.

**On persistence.** Snapshotting has a fork cost that can briefly double memory, which is exactly the wrong thing to happen on an instance near its limit. The append-only log is more durable and has its own rewrite behaviour. For the cache, persistence is unnecessary — a cold restart is a designed state. For the broker, it matters, and that is another reason the two are separate.

**And the deployment consequence.** Memory limits are set explicitly rather than left to the container's limit, so the process makes its own eviction decision instead of being killed by the platform. Being terminated for exceeding memory is the worst outcome: total loss with no eviction and no error.

</details>


---

### API-21. Where would you not use Redis?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
As the source of truth for anything, as the sole holder of a durability guarantee, for a distributed lock protecting something whose double-execution actually matters, and for large objects. Each of those is a case where its speed is being used to paper over a guarantee it does not provide.

<details>
<summary><strong>Detailed answer</strong></summary>

**As a source of truth.** It is memory-first with configurable persistence, and the persistence options all have a window. That is fine for a cache and unacceptable for a fact. The failure is gradual rather than dramatic: something is cached, then something is stored there because it was convenient, and eventually a value exists nowhere else. My rule is that the system must be correct with it empty — if that is not true, something has quietly become a database without backups.

**As the durability guarantee for idempotency.** Idempotency keys held there are an optimisation. If they are flushed, a duplicate request gets reprocessed, and the thing that must prevent a double charge is a unique constraint in the database. Relying on the cache alone means the guarantee disappears with a restart, and it disappears silently.

**For a distributed lock protecting something that actually matters.** Single-instance locks are unsafe under failover; the multi-instance algorithm is contested and depends on timing assumptions that do not hold with process pauses or clock drift. My position is practical rather than doctrinal: I use it for advisory coordination where a rare double execution is tolerable — a semaphore limiting a vendor's import concurrency, where two extra workers occasionally is harmless. Where double execution is not tolerable, the correctness comes from the database: a unique constraint, or a row claimed with a lock that skips already-claimed rows. Then the lock is an optimisation to reduce contention rather than the thing preventing the error.

**For large objects.** Storing files or large documents fills memory fast and it is the most expensive storage in the estate. Those belong in object storage with a reference held elsewhere.

**For anything needing queries.** No secondary indexes worth relying on, no joins, and scanning the keyspace on a large instance is an operational hazard. If the access pattern needs a query, it needs a database.

**And as a queue where durability matters**, which is the specific case worth stating: used as a task broker it lacks true acknowledgement semantics, so a worker that dies mid-task can lose the work. That is acceptable for tasks that are re-derivable and not for tasks that are not — and the honest way to hold that position is to test it by killing a worker mid-task rather than to assume the configuration protects you.

</details>

