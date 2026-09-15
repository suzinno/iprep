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
A good API is one that a competent consumer can predict without asking you. In concrete terms, it has one executable contract, not a document. Its resource model stays consistent as it grows. Its status codes are honest and its errors are machine-readable. Every mutation is safe to retry. Its pagination and result sizes do not degrade as the data volume grows. And it has an evolution story that does not break the caller you cannot deploy alongside.

<details>
<summary><strong>Detailed answer</strong></summary>

**The contract is a build artefact, not documentation.** In both designs the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models define every request and response body. [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") emits the [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document from those models, and that document is contract-tested in the pipeline. The marketplace goes one step further. It builds its admin console against the same versioned public API, not against a private backend. The cost is a chattier user interface on entity screens. What it buys is a guarantee: no admin capability exists that the public contract does not already describe and test. A specification that people maintain by hand alongside the code is a specification that is wrong. And the consumer finds that out at runtime.

**Predictability across the surface.** The same pagination everywhere, the same error envelope everywhere, the same identifier style, the same date format and the same naming. Both designs use cursor pagination on every collection. The reason is that offset pagination degrades on exactly the deep pages that a comparison or timeline workflow produces. But the more important property is that it is *everywhere*, so a consumer learns it once.

**Honest semantics.** The status code is part of the contract. A creation returns `201` with a `Location`. `202` is for work that is genuinely async, and a status [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") is returned with it. `409` is for a state conflict, and `422` is for a body that fails validation. `503` is for when a dependency is down and a retry is appropriate. Error bodies are [RFC](https://www.rfc-editor.org/ "Request For Comments — Numbered document series that defines internet standards and protocols") 9457 problem details: a stable `type`, a human `detail`, and field-level errors. The reason is that a client cannot branch on prose. The cancer platform returns `202 Accepted` for a check-in, instead of pretending that the write is synchronous. It also returns a status URL for page generation, instead of holding a connection open for 45 seconds. Lying about which of these a call is causes more consumer bugs than any amount of naming.

**Safety and bounds.** Every mutation accepts an `Idempotency-Key`, so a retry after a timeout cannot apply the change twice. The key is required on all `POST` mutations in the cancer platform. In the marketplace it is required on `POST /v1/connections`, because a connection request that is submitted twice must not create two threads and bill the vendor twice. Responses are bounded. The marketplace returns `total_estimate` capped at 1,000 instead of an exact count. The reason is that an exact count over a filtered index scan costs as much as the page itself. And a sourcing workflow needs "1,000+", not "1,247". In the same way, the API refuses an uncategorised query that carries more than two facet predicates. That is a small product constraint, and it removes a whole class of performance problem.

**Evolution.** The version goes in the path (`/api/v1`, `/v1`). Inside a version, the API evolves additively: new optional fields and new endpoints, but never a changed meaning or a removed field. A consumer that you cannot deploy together with is the normal case. So the test is whether the old client keeps working unchanged.

**Authorization at the resource, not the route.** A route-level check tells you that the caller is a clinician. It does not tell you that they may see *this* patient. Good APIs answer both questions, and they answer the second one in one place, not per endpoint.

**And the property that is easy to forget:** the API should be observable from the outside. That means a request identifier echoed back, a propagated trace header, and a status endpoint for anything async. With these, a consumer can tell you *which* call failed, instead of "it was slow yesterday".

</details>


---

### API-02. Explain DNS, TCP and HTTP. What happens when I type https://api.example.com/users into my browser?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
Name resolution finds an address. A [TCP](https://datatracker.ietf.org/doc/html/rfc9293 "Transmission Control Protocol — Provides reliable, ordered byte-stream delivery between two endpoints") handshake establishes a reliable byte stream to that address. A [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") handshake authenticates the server and encrypts that stream. HTTP is the request-and-response protocol spoken inside the stream. In concrete steps: the DNS lookup, the three-way handshake, the TLS 1.3 handshake with protocol negotiation, the request, the server's work, and the response. Then the connection is kept alive, so the next request skips almost all of it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before any packet.** The browser parses the URL and checks its HTTP Strict Transport Security list. If the host has declared it, the browser rewrites `http://` to `https://` locally, and it never attempts a downgrade on the wire.

**DNS — turning `api.example.com` into an address.** The stub resolver checks its cache, then the operating system's cache, and then asks a recursive resolver. On a cold cache, the recursive resolver walks the hierarchy. It asks a root server for `.com`, then the `.com` servers for `example.com`'s authoritative nameservers, and then those nameservers for the record itself. It caches each answer for its time-to-live. In practice, a global service returns an anycast address, or a provider-specific alias that resolves to the nearest edge. Two operational consequences are worth stating. First, **the record's time-to-live is your failover speed**, because clients keep using a cached address until it expires. Second, DNS resolution is a synchronous dependency that can fail on its own. That is why resolver latency and failures deserve a metric.

**TCP — a reliable ordered byte stream.** A three-way handshake (SYN, SYN-ACK, ACK) costs one round trip and establishes sequence numbers and window sizes. From there, TCP provides ordering, retransmission and flow control. Its relevant cost is that every new connection pays that round trip plus the slow-start ramp. That is why connection reuse matters so much. It is also why a client library that opens a fresh connection per request is measurably slower.

**TLS — authenticating and encrypting the stream.** TLS 1.3 completes in one round trip. The client sends its supported parameters and a key share. It also sends the Server Name Indication, which names the host. That is how one address serves many certificates. And it sends the Application-Layer Protocol Negotiation list, which offers HTTP/2. The server responds with its certificate and its key share, and traffic is encrypted from that point. The client validates the chain to a trusted root, checks the name and the validity, and consults revocation. Session resumption lets a returning client skip most of this. 0-RTT resumption removes the round trip entirely, but the cost is replay exposure. So it is appropriate for idempotent requests only.

**HTTP — the conversation inside the tunnel.** Over HTTP/2, the request is a set of compressed header frames. For a `GET`, there is no body. The request carries the method `GET`, the path `/users`, `authorization`, `accept`, and typically a propagated trace header. Multiple requests are multiplexed over the one connection, instead of waiting in a queue behind each other.

**What the server does with it**, which is where the previous answers connect. The edge terminates TLS. A gateway validates the token. A load balancer picks a healthy instance. The application resolves dependencies, validates, handles, serializes, and returns a status code, headers and a body. The response travels back over the same connection, which is **kept alive**. So the second request to the same host pays for neither the DNS lookup, nor the handshake, nor the TLS negotiation. That is the single biggest reason to reuse a client object instead of constructing one per call.

**The detail I would add.** You can observe each of those stages separately, and each one can break separately. In a "the API is slow from our office" report, naming which stage is slow is most of the work. DNS resolution time, connect time, TLS handshake time and time-to-first-byte are four different numbers. Any HTTP client can be made to report all four.

</details>


---

### API-03. What is the difference between HTTP 401 and 403?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
`401` means the request is not authenticated: there is no credential, or the credential is expired or invalid. The response must say how to authenticate. `403` means the request is authenticated but not permitted, and repeating it with the same credential will not help.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction as the specification draws it.** The name `401 Unauthorized` is misleading. It means *unauthenticated*. A compliant response carries a `WWW-Authenticate` header, which tells the client what to present. The right client reaction is to obtain a credential and retry. `403 Forbidden` means that the server understood who you are and is refusing anyway. Retrying with the same identity is pointless, so a client must not treat it as retryable. Getting this wrong causes real bugs. A client that sees `401` for a permission failure loops through a refresh that it does not need. A client that sees `403` on an expired token does not refresh, so the user gets a failure that a refresh would have fixed.

**Which one to return when.** No token, a malformed token, a bad signature, an expired token or an unknown key: `401`. A valid token with the wrong scope, the wrong role, the wrong account type or the wrong tenant: `403`. The cancer platform's gateway does exactly this. A clinician token presented on a patient route is rejected with `403` at the edge. The reason is that the token is perfectly valid, and it simply has the wrong audience for that plane.

*The other half of this question — what should happen when an authenticated user reaches for another customer's data — is **SEC-05** in [security-and-identity.md](security-and-identity.md).*

</details>


---

### API-04. How do you version an API, and how do you tell a breaking change from a safe one when the consumer is another team you cannot deploy with?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
A major version in the path (`/v1`) for changes that cannot be made compatibly, and additive evolution inside that version for everything else. The test for breaking is not a judgement call. A change is safe if every request that a conforming old client can send still succeeds, and every response it receives still parses under its old schema. A generated contract and a contract test can check that property. It is not something a reviewer checks by eye.

<details>
<summary><strong>Detailed answer</strong></summary>

**The scheme, and why.** Both these systems version in the path: `/api/v1` and `/v1`. The reasons are that a path version is visible in logs, trivially routable at the gateway, and unambiguous in a bug report. Header or media-type versioning is purer in theory and worse in practice. It is invisible in an access log, easy to omit, and harder to route on. The important part is not which scheme you pick. It is that **a new major version is a last resort**, because it means running two implementations and migrating every consumer. Most evolution should be additive inside the current version.

**The compatibility rules, stated as rules so they are checkable.**

*Safe, additively:*

- adding an optional request field with a sensible default;
- adding a response field;
- adding a new endpoint;
- adding a new enum value **only if** the contract already told clients how to handle unknown values;
- relaxing a validation rule;
- adding an optional query parameter.

*Breaking:*

- removing or renaming any field;
- making an optional request field required;
- narrowing a type or a validation rule;
- changing the meaning of an existing field while keeping its name, which is the worst one because nothing detects it;
- changing the default sort or pagination behaviour;
- changing a status code for an existing condition;
- changing an error code's meaning;
- removing an enum value that a client may send.

*The two that generate arguments:* **adding a response field** breaks a client that rejects unknown fields. **Adding an enum value** breaks a client that switches exhaustively. Both are really contract questions. If the published contract says that clients must tolerate unknown fields and unknown enum values, then both changes are safe, and a client that breaks is non-conforming. If the contract does not say so, both changes are breaking. So I would put that statement in the contract on day one, because it is the cheapest thing you will ever do for your future self.

**Making the check mechanical rather than social.** The generated [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document is the published contract, and it is contract-tested in the pipeline. **API-01** covers how it is produced. That gives two things. First, a diff of the schema on every merge request, which makes a breaking change visible during review, not after release. Second, a document that consumers generate a client from. On this vacancy's stack, the frontend generates its client from the OpenAPI document, and that raises the stakes in a useful way. A breaking schema change surfaces as a compilation failure on the frontend's side, not as a runtime error in someone's browser. And the generated client is a strong argument for keeping the document honest.

**When you cannot deploy together — which is the actual question.**

- **Expand/contract, exactly as with a database.** Add the new field alongside the old one. Populate both. Announce the change. Give a deprecation window with a date. Remove the old field only after telemetry shows that nobody uses it. Per-field usage telemetry is what turns "I think nobody uses it" into "nobody used it in ninety days", and it is worth the instrumentation.
- **Tolerant reading on our side too.** We are somebody's consumer as well. If we ignore unknown fields on inbound payloads, their additive change does not break us.
- **Consumer-driven contract tests where the consumer is internal.** Their expectations run in our pipeline, so we find out at merge time, not at their deploy time.
- **`Deprecation` and `Sunset` headers plus telemetry on old-version usage**, so the deprecation is a measured process, not an email.
- **Run both versions concurrently when a break is unavoidable**, with an explicit end-of-life date, and accept that you now maintain two versions. That cost is the reason to try every additive option first.

**And the one I would push back on.** People often propose versioning as the solution to a change that should simply not be made. If a field's meaning is changing, the right move is usually a *new field with a new name* and a deprecation of the old field, not `/v2`. The reason is that `/v2` migrates every consumer for a change that affected one field. Use a major version only for a genuine change of resource model.

</details>


---

### API-05. Design a REST API for creating and retrieving orders.

**Level:** Q2 — deep dive · **Project:** general

**Brief answer**
`POST /v1/orders` with a required `Idempotency-Key`, returning `201` and a `Location`. `GET /v1/orders/{order_id}`. `GET /v1/orders` with keyset pagination and a small set of filters. State changes are explicit sub-resource actions, not a patchable `status` field. Money is integer minor units with an explicit currency. Concurrent edits are settled with `ETag` and `If-Match`.

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

Four decisions in that block are worth defending. First, the **idempotency key is required, not optional**. A client that retries a timed-out create has no other way to avoid a duplicate order. For a repeat of the same key, I would return the stored original response. For the same key with a different body, I would return `422`. Second, **money is `*_minor` integers plus an [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 4217 currency code**, never a float. The marketplace schema does exactly this, with `price_minor bigint` and `currency char(3)`. Third, **the server computes the total**, because a total supplied by the client is a pricing vulnerability. And fourth, **line items are part of the create**, not a sequence of `POST /orders/{id}/lines` calls. The reason is that an order with no lines is not a valid intermediate state, and nobody should be able to reach it.

**Read.**

```
GET /v1/orders/{order_id}          → 200 + ETag
GET /v1/orders?status=pending&created_after=…&cursor=…&limit=50
                                   → { items: [...], next_cursor: "…" }
```

Keyset pagination on `(created_at, order_id)` instead of `OFFSET`, so page 40 costs what page 1 costs. An opaque cursor, so the ordering key can change without breaking clients. `limit` capped on the server side. The list returns summaries, and the detail endpoint returns lines and history. The reason is that a list of 50 fully-expanded orders is a payload that nobody wanted.

**State transitions as actions, not as a patchable field.**

```
POST /v1/orders/{id}:cancel   { "reason": "customer_request" }
POST /v1/orders/{id}:confirm
```

`PATCH {"status": "cancelled"}` looks tidier, and it is worse. It invites an arbitrary transition. It has nowhere to carry the reason that a cancellation needs. And it makes the state machine implicit. An explicit action endpoint can be authorized on its own and audited on its own. It returns `409` when the transition is illegal from the current state. `cancel` on a shipped order is a conflict, not a validation error.

**Concurrency.** The detail response carries an `ETag`. An update requires `If-Match`, and a mismatch is `412 Precondition Failed`. That is optimistic locking expressed in the protocol. It is the right default for a resource that a human edits. The alternative, last-write-wins, silently discards someone's change.

**What I would say about the parts people miss:**

- **Partial failure on a bulk endpoint.** If `POST /v1/orders:bulk` exists, it returns `207`-style per-item results with a stable index. It never returns a single `200` that hides three failures.
- **Asynchrony where it is real.** If confirming an order triggers a payment capture that takes seconds, the action returns `202` with a status URL, instead of holding the connection. And the state change and the event that announces it commit together through an outbox. So "the order was confirmed but nothing downstream heard" is not a reachable state.
- **Authorization is per order, not per route.** A customer may read their own orders. A support agent may read any order, and that read is audited.
- **Retention and immutability.** An order is a commercial record. Cancellation is a state, not a delete. `DELETE /v1/orders/{id}` should not exist.

</details>


---

### API-06. How do you agree an API contract before either side has built anything?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By writing the typed models first and publishing the generated document as a draft. Then the discussion is about a concrete artifact, not about intentions. The frontend can generate a client and work against a stub while the implementation is still being written.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not a document written by hand.** A hand-written specification diverges from the implementation immediately, and nobody notices, because nothing checks it. Now suppose the document is emitted from the typed models that the code actually uses. Then it cannot describe something the service does not do, because the schema is executable, not described. So the sequence is: write the models, emit the document, publish it as a draft, and only then write the handlers.

**What the conversation is about, given a draft.** Mostly not field names. Those settle in minutes once there is something to look at. The useful discussion is about shape, and it is worth having that discussion deliberately:

- **What one screen needs in one call.** If a view always needs a list plus one field from each related entity, that field belongs in the list response. Designing endpoints around screens, not around tables, is what prevents a chatty interface. And that is far easier to argue about while the response is still a model in a branch. After both sides have built against it, it is much harder.
- **Where a batch verb is needed.** A comparison view that needs two to five items should make one request, not five. That is a contract decision, not an optimisation.
- **What is optional versus nullable.** Those two generate different types, and the difference is invisible until someone's client breaks.
- **What the error shapes are.** If only the success shape is declared, every consumer invents its own failure handling. Declaring the error responses is part of the contract, not an afterthought.
- **Which enumerations are open.** A closed set generates a closed type, and adding a member later breaks strict clients.

**Working in parallel after that.** The frontend generates a client from the draft. It works against a mock served from the same document, so both sides make progress against one artifact. The contract test in the pipeline diffs the emitted document against the published one. So if the implementation drifts from what was agreed, the result is a red build, not a discovery.

**What I ask for in return.** First, that they regenerate in their own pipeline against the latest published document. Then drift shows up as a red build on their side too. Second, that changes requested after agreement come as a change to the document, not as a message. Otherwise the contract quietly becomes whatever was said in a call. That is the state the whole arrangement exists to avoid.

</details>

---

## 2. Idempotency and bulk operations

---

### API-07. An endpoint takes a list of identifiers and acts on all of them. What failure modes do people miss, and what does the response body look like when half of them fail?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Almost all the missed failure modes come from one decision that nobody made explicitly: whether the operation is atomic or per-item. Everything else follows from that decision: partial failure, retry semantics, unbounded input, duplicate ids and mixed authorization outcomes. When half the items fail, the response has to be per-item and machine-readable. Each entry needs a stable identifier, its own status, and an error code that the client can branch on. It is never a prose summary.

<details>
<summary><strong>Detailed answer</strong></summary>

**The decision that has to be made first.** All-or-nothing, or best-effort per item? Both are defensible. The failure is leaving the choice implicit, because then the behaviour depends on which exception fired. A bulk import of vendor catalogue rows is validated as a whole and fails as a whole. The rows land in staging and are checked against the category schema. Nothing moves into the live tables unless the file is acceptable, and a per-row `error_digest` explains why. A bulk archive of listings is per-item, because one bad id is no reason to refuse the other forty-nine. State the choice in the contract, and make the status code match it. Use `200` or `207` for a partial result. Never use `200` with the failures buried in the body, and never use `500` because one item failed.

**What people miss.**

- **Unbounded input.** There is no maximum list length. So someone sends 100,000 ids, and the request times out halfway, with an unknown amount already applied. The fix is a hard cap in the schema (50, 200, whatever the operation supports), plus an async job endpoint for genuinely large work. The marketplace draws this line explicitly. A 20,000-row import is not a request. It is an upload that returns a job id. The work is chunked into 500-row tasks, with a status endpoint that the workspace polls.
- **Retry after a partial failure.** The client retries the whole list, including the items that succeeded. Without per-item idempotency, you apply those items twice. The key must be per item, or derived from the operation and the item id. It must not be per request.
- **Duplicate ids in one list.** `[a, a, b]`. Does `a` get processed twice? Deduplicate on arrival, and say so.
- **Mixed authorization outcomes.** Some ids belong to the caller's organisation and some do not. The unsafe response tells the caller which ids exist but are forbidden. That lets the caller find out which ids exist (an enumeration oracle). In a marketplace where competitors share the platform, that matters. Return `not_found` for anything outside the caller's tenant scope, the same way every time, so nobody can use the response to probe.
- **Ordering and interdependence.** If the items are not independent, a partial application can leave an inconsistent state that neither a retry nor a rollback can repair.
- **One transaction for the whole list.** A 500-item batch in one transaction holds locks for as long as it runs. It risks a deadlock against a concurrent batch that works in a different order. And it rolls back everything when the last item fails. Chunk it, sort by primary key, and commit per chunk.
- **The timeout.** Fifty items times 200 ms is ten seconds, which is past most client and gateway timeouts. The client then retries, and now two runs are in flight.
- **No per-item observability.** Only the request is traced, so nobody can trace a failure inside item 37 back to that item.

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

The properties that matter:

- The client can retry exactly the failed subset.
- `code` is a stable enumeration that the client can branch on, while `detail` is human text that may change.
- `retryable` separates a transient failure from a permanent one, so a client does not keep retrying a validation error.
- The order and the identifiers let the client reconcile the results against what it sent.

`RFC` 9457 problem-detail bodies are the convention in both these systems for single-resource errors. The per-item objects use the same field vocabulary, so clients learn one error model.

**Response codes.** `207 Multi-Status` if the contract embraces it. Otherwise `200` with the per-item statuses, documented. What I would not do is return `400` for a partial success. The request was valid, and two items were applied. A `400` invites a client to retry the whole thing.

</details>


---

### API-08. What happens if the client sends the same POST request three times?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By default, the endpoint does whatever it does three times. And this is the normal case, not a client bug. The reason is that a client retrying after a timeout cannot tell a lost response from a lost request. The design answer is an idempotency key that makes the second and third calls return the first call's result. A unique constraint in the database backs that key. The reason is that the key store is an optimisation, and the constraint is the guarantee.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the three come from.** A human double-clicking is the least interesting source. Two sources matter. The first is a client that timed out and retried, because it has no way to know whether the server committed before the connection dropped. The second is infrastructure that retried on its own, which gateways and [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") layers do more often than people expect. So duplicate delivery is a property of the network, and "tell clients not to do that" is not a design.

**The mechanism.** The client generates a key per logical operation and sends it as `Idempotency-Key`. It reuses the same key across retries of that operation. It generates a fresh key for a genuinely new attempt. On the server side:

1. Look the key up. If a completed record exists, **return the stored response** with its original status code. Do not return a `409`. The client's goal is the outcome, and a retry that returns `201`-equivalent semantics is exactly right.
2. If the key exists but the fingerprint of the request body differs, return `422`. Reusing a key for a different operation is a client bug, and it should be loud.
3. If the key exists and its request is still in flight, return `409` with a retry hint, instead of starting a second execution.
4. Otherwise, claim the key, execute, and store the response.

**Why the client generates the key, and why it is required.** A key generated by the server is useless here. The client cannot ask for one, because asking is itself a request that can fail. And `Idempotency-Key` is required on all mutating `POST`s, not optional. An optional idempotency mechanism is absent exactly when someone forgot it.

**The key is scoped and it expires.** It is scoped to the tenant, so one organisation cannot collide with another organisation's keys or probe them. In the marketplace, that is what `UNIQUE (retail_group_id, idempotency_key)` buys beyond deduplication. The expiry is about 24 hours, which matches the outer limit of any sane retry.

**And the part that makes it actually correct.** Both designs say this in the same words, from opposite directions. The notes on the cancer platform's Redis keyspace say that `idem:` keys are the *optimisation* for duplicate suppression, **not the guarantee**. If a flush loses them, a duplicate can be reprocessed. So any mutation that must not apply twice carries a natural key in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"). Check-ins are unique on `(patient_id, recorded_for)`, and the projection is an `INSERT … ON CONFLICT DO UPDATE`. So a redelivered message is just a repeated calculation, not a bug. The marketplace does the same at the commercial boundary. `connection_request` carries `UNIQUE (retail_group_id, idempotency_key)`. Its own schema note says that the database, not the cache, is what finally prevents a duplicate thread and a duplicate charge. `billing_charge` adds a partial unique index on `(connection_request_id)` `WHERE kind = 'connection'`, so a connection bills at most once. That is enforced in the schema, not in retry logic, and that is the distinction worth drawing.

**The test of whether the guarantee is real** is to flush the key store and replay the request. If a duplicate appears, the guarantee was never there. It lived in the cache, which is the one place where both designs say it must not live.

**The natural key is better than the generated key wherever a natural key exists,** because it does not depend on the client behaving. One check-in per patient per day is a domain truth. An idempotency key is a client promise.

**What the key cannot protect.** Side effects outside the transaction. Suppose the first attempt committed and then sent an email. A retry that returns the stored response does not send a second email. But a crash between the commit and the send means no email at all. That is why anything that must follow a commit goes through the outbox, instead of being fired inline. The state change and the intent to notify commit together. The relay then delivers at-least-once.

**The same ambiguity exists past the API.** At-least-once delivery between the broker and the consumer makes duplicates normal there too. And exactly-once does not exist across a broker and a database without a distributed transaction. So every consumer is idempotent against the same natural keys. The API and the message path share one mechanism, not two.

**And where duplicates are simply accepted.** The cancer platform's reminder path can deliver a reminder twice under a receipt-loss race. The design says so explicitly and accepts it. The reason is that a patient seeing a reminder twice is a far better failure than not seeing it at all. If you can name which duplicates you have chosen to tolerate, and why, that is a stronger answer than claiming you have eliminated them.

</details>


---

### API-09. A bulk endpoint takes a list of identifiers. What failure modes do people miss?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
An unbounded list. Partial failure with an all-or-nothing response. Losing the ordering that the caller sent. And silently dropping identifiers that the caller may not access. If that last one is done inconsistently, it turns an authorization boundary into a way to find out which identifiers exist (an enumeration oracle).

<details>
<summary><strong>Detailed answer</strong></summary>

**The failure modes, in the order they cause trouble.**

- **No cap on the list.** Someone adds a batch endpoint to fix an N+1, and it becomes a way to ask for fifty thousand objects in one request. That is an unbounded query and an unbounded response. It is also a denial-of-service tool handed to any authenticated caller. The cap is part of the contract, and it is validated, not hoped for. The comparison endpoint on the marketplace takes between two and five products for exactly this reason. The bound comes from the product requirement, and that is the best kind of bound.
- **Partial failure with no partial result.** Forty-nine of fifty are found, one is missing, and the whole request returns an error. The caller has no way to make progress. The response should be per-item: what was found, what was not, and why. Its overall status should say that the request itself succeeded.
- **Order and duplicates.** Callers often assume that the response is in the order they sent. But a bulk query returns whatever the database returns. One option is to key the response by identifier. I prefer that, because it removes the assumption entirely. The other option is to state the ordering guarantee explicitly. Duplicates in the input need a defined behaviour too.
- **Authorization applied inconsistently.** This is the one with a security consequence. If a forbidden identifier returns "not found" and a nonexistent one also returns "not found", that is fine. If one returns "forbidden" and the other returns "not found", the endpoint tells an attacker which identifiers exist. And a bulk endpoint lets the attacker ask about five hundred at a time. On a marketplace, a vendor enumerating the retailer directory would be commercially fatal. So this is not a theoretical concern. The scope filter is applied in the query, and nobody can tell unauthorised items apart from absent ones.
- **The internal N+1.** A batch endpoint that loops internally has moved the problem, not fixed it. It has to become one query with an `IN`, one multi-get, or one bulk document fetch.
- **Rate limits counted per request, not per item.** One request that asks for five hundred items is not the same load as one request that asks for one item. A limiter that counts requests will happily allow the expensive pattern.

**The general principle.** A batch endpoint multiplies load, and the caller chooses how much it multiplies. Every limit, every check and every cost has to be reasoned about per item, not per request.

</details>

---

## 3. Search

---

### API-10. What is the difference between filtering and ranking, and why does confusing them cause most bad search?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A filter decides whether a document may appear. Ranking decides where it appears. They are different questions with different correctness requirements. If you treat a filter as a strong ranking signal, a search can return something that it should never have returned at all.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why they must be separate.**

- **A filter is binary, and it is a correctness property.** May the caller see this document? Is it published? Is it within the requested date range? There is no "slightly". Suppose a scope filter is expressed as a score boost. Then a strong enough text match can outrank it, and now the search has disclosed something. On a system where authorization is the whole threat model, that is not a subtle bug.
- **Ranking is continuous, and it is a quality property.** It decides which of the permitted documents is most useful. If ranking is wrong, the result is disappointing. If the filter is wrong, the result is an incident.

**The engineering consequences of separating them.** Clauses that only include or exclude go in filter context. There they contribute nothing to the score, and they are cacheable. That is also a real performance benefit, because a cached filter bitmap is reused across queries. Scoring clauses are only the ones that express relevance. The scope fields are on every document, and the query is always wrapped in a filter on those fields. That is a property of the index, not an application convention. So a query written by someone who forgets the scope returns nothing, not someone else's data.

**Where the confusion actually shows up in practice.**

- **Status expressed as a boost.** "Prefer published listings" instead of "only published listings". Eventually a draft appears, because its text matched better. The marketplace instead carries the status predicate in a partial index. That keeps unpublished rows out of the index entirely, and it removes the filter from every plan.
- **Recency as a filter when it should be a signal.** This is the opposite mistake: a hard cut on anything older than a year. Then a highly relevant older document is unreachable, and nobody knows why. Recency belongs in the score.
- **A relevance threshold used as a filter.** Scores are not comparable across queries. So a fixed cutoff makes results vanish for some queries and not for others, with no pattern that anyone can explain.

**How I keep it honest.** The filter set is tested for absence. A query from one scope must return zero documents from another scope. A test asserts this, instead of anyone just assuming it. Relevance changes are evaluated against a judged set, so a boost adjustment is measured, not checked by eye. And no relevance work is ever allowed to touch the scope filter. That is stated as a rule, not left to judgement, because the scope filter is the one clause where a well-meant tuning change becomes a disclosure.

</details>


---

### API-11. Describe your experience with Elasticsearch. What did you index, and how did you keep it in step with the database?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Clinical content search on the cancer platform: visit notes, guidance and visit history, behind a single alias. It is kept in step by never being written to directly. The relational store is the source of truth. A transactional outbox drives an index consumer. And the whole index can be rebuilt from the primary stores.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it.** Documents for the searchable clinical content. Each document carries the scope fields that decide who may see it: the patient identifier and the care-team identifiers. Next to those are the searchable text and the filterable metadata. The scope fields are on every document on purpose, so the filter is a property of the index, not an application convention.

**How it stays in step, which is the part that matters.** The application never writes to the index from a request handler. The sequence is this. The fact is written to the relational store, and an outbox row is written in the same transaction. A relay publishes that row, and only then marks it as published. An index consumer reads the event and bulk-indexes it. That single-writer rule is what makes dual-write drift impossible. There is no code path where the database and the index can disagree because one write succeeded and the other did not.

**Freshness is stated as a composed budget, instead of being asserted.** The relay takes under a couple of seconds. Add the bulk flush interval and the index refresh interval. Together, they mean that a newly saved note is searchable within about eight seconds at the median. The useful property of writing it as a sum is that it shows that tightening any single component alone cannot bring the total below the sum of the other components.

**Rebuildability, and why it is the important property.** The index holds nothing that cannot be derived from the relational and document stores. So losing the cluster entirely means a rebuild, not a data loss. That is what makes the disaster recovery plan honest. And a mitigation that nobody has run is an assumption. So the rebuild is rehearsed quarterly, with a document-count reconciliation between the sources and the index.

**What I would flag as the operational risk.** A consumer that stops is silent. Search keeps working, and every request is fast. The results simply stop including anything new. So the metric that matters is the lag from the source event's timestamp to the index write. That lag is alerted on, because nothing else surfaces the problem.

**And the honest limit of my experience.** I ran this at a scale of a couple of million documents, on a self-managed cluster in the platform's own cluster. That was real operations, including shard sizing, replica counts and version upgrades. But it was not a very large multi-node search estate. What I have not done is run a cluster at tens of terabytes with hot-warm-cold tiering.

</details>


---

### API-12. Explain mappings and analyzers, and why a mapping change is harder than a schema change.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
A mapping declares each field's type and how its text is analysed into terms. An analyzer is the pipeline that turns text into those terms, at index time and at query time. Most mapping changes cannot be applied in place. The reason is that existing documents were already tokenised under the old rules. So the change is a reindex, not an alter.

<details>
<summary><strong>Detailed answer</strong></summary>

**Analyzers, concretely.** A character filter, a tokenizer, and then token filters: lowercasing, stop words, stemming, synonyms. Analysis happens twice. At index time, it produces the terms stored in the inverted index. At query time, it produces the terms to look up. The two must agree, or nothing matches. This causes the most common confusing bug in search: a field is analysed one way and queried another way. The result is zero results for a document that is obviously there.

**Where the clinical synonym filter is worth having.** The same condition appears as a clinical term, as an abbreviation and as a lay phrase. A clinician who searches for one must find a note written with another. That mapping is what makes the search useful instead of literal. The operational consequence is worth knowing. Synonyms applied at index time need a reindex to change. Synonyms applied at query time can be updated without a reindex, but they cost more per query. Choosing query time is usually right, precisely because the vocabulary will change.

**Why a mapping change is not an alter.** The inverted index holds terms produced by the old analyzer. Changing the analyzer does not go back and re-tokenise them. Changing a field's type is generally not permitted at all. So the change is: create a new index with the new mapping, reindex into it, and switch.

**Which is why every index sits behind an alias**, and this is the single most important operational decision in a search deployment. The application only ever talks to the alias. A mapping change then becomes: build the new index, reindex, verify document counts and spot-check queries, then atomically move the alias. There is zero downtime, and the rollback is moving the alias back. That is why the old index is kept until confidence is established, instead of being deleted at switchover.

**During the reindex**, new writes still arrive. One option is to dual-write to both indices for that window. The other is to reindex to a point in time, and then replay the events since that point. The event-driven design makes the second option straightforward, because the outbox is an ordered log of what changed.

**What I would add for anything non-trivial.** A field that is both analysed for search and kept as an exact keyword for filtering and aggregation. You almost always need both, and adding the second one later is another reindex. And dynamic mapping switched off in production. When a document with an unexpected field silently creates a mapping, the index ends up with a type that nobody chose and nobody can change.

</details>


---

### API-13. How do you tune relevance, and how do you know a relevance change is actually an improvement?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
By evaluating against a judged set, not by looking at results. In engineering, relevance changes are the easiest thing to fool yourself about. Every change looks better on the three queries you tested it with, and those are the queries that motivated the change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The levers, briefly.** Field boosting, so a match in a title outweighs a match in the body. Analyzer choices: stemming, synonyms, and how abbreviations are handled. Phrase matching and proximity for multi-word queries. Filters versus scoring clauses, which matters both for correctness and for cost. A clause that only includes or excludes belongs in filter context, where it is cacheable and does not contribute to the score. And a reranking pass over the top results, when the first-stage retrieval is broad.

**The problem with tuning by inspection.** You change a boost and run your query. The result you wanted moves up, and you ship it. What you cannot see is the thousand queries that the change made worse. Relevance is a distribution, and inspection samples it in the least representative way possible.

**What I would insist on instead.**

- **A judged set.** A few hundred real queries, with relevance labels for the returned documents. On a clinical system, those judgements have to come from clinicians. I cannot label whether a note is relevant to a query. If I pretended otherwise, the result would be a metric that measures my guesses.
- **A metric that reflects the interface.** Something rank-weighted over the first page, because that is what a user sees. That can be normalised discounted cumulative gain, mean reciprocal rank, or precision at 10, depending on what the surface is for. Precision over the whole result set measures something that nobody experiences.
- **Baseline first, then change one thing.** If you make two changes at once, you cannot tell which one caused the movement.
- **Look at what regressed, not just the aggregate.** A change that lifts the mean while badly breaking one query class is usually a bad change. And the aggregate hides it.
- **Online evidence where it is available.** Click rates and reformulation rates. The caveat is that they measure engagement, not correctness, and on a clinical tool that difference matters in practice. Where traffic is modest, interleaving is much more sensitive than a plain A/B test. Interleaving mixes results from both rankers into one list.

**Where the [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications") claims a relevance improvement**, the honest framing is this. The number comes from an offline evaluation on a judged set with clinician labels. It compares a defined baseline against the tuned configuration. These would make it a false claim:

- measuring on the queries that the change was designed for;
- changing the judged set at the same time as the configuration;
- reporting an aggregate that hides a subgroup regression.

I would rather state the evaluation method together with the number than state the number alone.

**And a constraint that outranks relevance here.** Nothing may be returned outside the caller's scope. The scope filter is not a ranking input. It is a filter, applied at the index level, and no relevance tuning is allowed to touch it.

</details>


---

### API-14. What do you use Kibana for beyond looking at logs?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
As the single pane where the two telemetry planes meet. Application traces, cluster metrics and the cloud provider's own diagnostic logs are shipped into the same store. Its real value is that it is the one place where you can follow a request across a broker boundary. Without it, you have to put together two incomplete stories during an incident.

<details>
<summary><strong>Detailed answer</strong></summary>

**The joining problem it solves.** The estate spans services in the cluster and managed cloud services, so there are always going to be two sources of telemetry. Two things make them one system. The first is the trace context that propagates on every hop, including the message headers on the broker, the transport bridge and the service bus. The second is that the cloud provider's diagnostic logs are shipped into the same store as everything else. Without that, a reminder that fails between a worker and the delivery function is two disconnected halves. And you discover that during an incident, not before one.

**What I actually build in it.**

- **A dashboard per objective, not per service.** The question during an incident is "are we meeting the reminder delivery target", not "how is service seven". A per-service dashboard forces the person under pressure to assemble the answer.
- **Saved searches for the recurring investigations.** "All events for this correlation identifier across every service" is the query you want to run in an incident. You do not want to compose it in one.
- **The traces view for latency work.** It shows where the time actually goes in a request, including the spans for connection acquisition and outbound calls. That is what separates waiting from working.
- **Ad hoc analysis over structured logs.** The logs are structured with trace identifiers, service, module and actor kind. So they can be aggregated as data, instead of grepped as text: error rates by reason, the distribution of a field, the shape of a spike.

**Two rules I hold about it.**

- **No clinical free text, no symptom values and no message bodies ever reach it.** A redaction filter drops fields marked as sensitive at the formatter. And a pipeline check fails the build if a log call passes a model that contains one of those fields. A log store is not a place where sensitive content is acceptable just because the store is internal.
- **Audit is a database table, never a log stream.** If you mix the two up, the log retention policy silently becomes the audit retention policy. That is a compliance failure that nobody notices until someone asks for a record older than the retention window.

**And what I would not use it for.** Alerting that needs to be reliable during a partial outage. The alerting path should not depend on the same store that may be the thing that is failing. Metric-based alerting on the metrics system is the more robust arrangement, with the log store as the investigation tool.

</details>


---

### API-15. How do you run a reindex with no search downtime?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Through an alias, always. Build the new index alongside the old one, and reindex into it. Verify the counts and sample queries. Then move the alias atomically. The application never names a concrete index, so the switch is invisible, and the rollback is moving the alias back.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.**

1. **Create the target index** with the new mapping and settings. During the bulk load, set the replica count to zero and disable the refresh interval. Both cost throughput that you do not need until the index is live. Restore both before the switch.
2. **Reindex.** Reindex from the existing index where the source documents are unchanged and only the mapping differs. Reindex from the primary stores where the document shape itself is changing, because then the old index is the wrong source. On this system the second path is always available. That is the point of the index holding nothing that cannot be derived.
3. **Handle writes that arrive during the window.** Either write to both indices for that time, or reindex to a point in time and then replay the events since that point from the outbox. The second is cleaner when there is an ordered event log, and there is one.
4. **Verify before switching.** Reconcile the document counts against the source. Run a set of known queries against both indices and compare them. Spot-check documents that exercise the changed mapping. Counting is the cheapest assertion that catches a reindex that was silently truncated.
5. **Move the alias in one atomic action** that removes the old index and adds the new one. There is no window where the alias points at nothing, or at both.
6. **Keep the old index** until confidence is established. It is the rollback. If you delete it at switchover, a two-second recovery turns into a rebuild.

**What goes wrong when people skip the alias.** The application holds a concrete index name. So the switch means a configuration change and a deploy. And that means a window where some pods query the old index and some query the new one. For search that is not a catastrophe, but you can avoid it for free. The alias also makes the emergency case work, where you need to point at a rebuilt index right now.

**On throughput during the reindex.** The reindex competes with production traffic for the same cluster resources. So it is throttled deliberately and run when traffic is low, and the cluster's own load is watched while it runs. A reindex that saturates the cluster degrades live search, which is exactly the outcome the whole exercise was meant to avoid.

**And the same procedure covers disaster recovery**, which is why it is worth rehearsing it instead of documenting it. Losing the cluster entirely means the same sequence, starting from step two. And because it has been run quarterly, the duration is a number, not a hope.

</details>

---

## 4. Caching

---

### API-16. Describe your experience with Redis. What did you use it for beyond caching?

**Level:** Q1 — baseline · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Cache-aside for the hot catalog reads, a task broker for one system's workers, idempotency keys, a per-vendor concurrency semaphore, and rate limiting. The important decision was to run two separate instances, one for the cache and one for the broker. The alternative was one instance with separate logical databases.

<details>
<summary><strong>Detailed answer</strong></summary>

**The uses, and what each one demands of the deployment.**

- **Cache-aside on the catalog read path.** Listing details, keyed with the revision in the key. Search result pages, with a short expiry. And facet counts. Loss is acceptable by design: a cold cache means slower reads, not wrong ones.
- **A task broker for the marketplace workers.** The requirements are completely different. This data is not disposable, and losing it means losing queued work. That is why the broker is a separate instance, with different persistence and a different memory policy.
- **Idempotency keys** on mutating requests, as an optimisation in front of the real guarantee. The durable guarantee is a unique constraint in the database. The cache stops the duplicate early, before it reaches the database. If the keys are lost, a duplicate can be reprocessed, and the constraint is what makes that safe.
- **A per-vendor concurrency semaphore**, so one vendor's large import cannot occupy the whole worker pool. It is a counter with an expiry, so a crashed worker releases its slot instead of blocking the vendor forever (a deadlock).
- **Rate limiting** as a per-subject token bucket in the application, beneath the coarser limits at the gateway.

**Why two instances rather than one with separate databases.** Because the two uses must not share failure modes. A cache should evict under memory pressure, and that is correct behaviour. A broker must never evict, because eviction there is silent data loss. Those are opposite memory policies, and one instance has only one eviction policy. One instance can combine the two only by evicting just the keys that have an expiry, and the Redis documentation advises two separate instances for that case where possible. There are more reasons. A cache flush to clear a bad entry must not touch queued work. The persistence requirements differ. And the traffic burst from a cache stampede must not slow down task dispatch. Two instances is a small cost for keeping a disposable store and a durable store from failing together.

**What I am careful about.** Every use above is either disposable or backed by a durable guarantee somewhere else. Nothing is the only record of anything. The moment a cache becomes the only place where a fact lives, it has silently become a database without backups. And that change happens gradually and by accident.

</details>


---

### API-17. Your cache hit ratio drops sharply with no change in traffic. Where do you look, and how do you decide whether the cache is now doing more harm than good?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
A hit ratio falls for one of four reasons. The keyspace got wider. The entries are being evicted. They are being invalidated more aggressively. Or the cache lost its data. Look at key cardinality, the eviction count, and memory against `maxmemory`. Also check whether a deploy or a data change altered how keys are constructed. The cache is doing harm when the miss path plus the lookup and write cost is more than the direct path. It is also doing harm when it has started serving answers that are wrong.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where I look, and the specific signal each place gives.**

1. **Key cardinality.** A hit ratio depends on how concentrated the key distribution is. Suppose a new filter parameter, a new sort option or a locale got folded into the key. Then the same traffic now spreads over ten times as many keys, and each key is cold. In the marketplace, the search cache is keyed on `cat:search:{filter_hash}`. A hash over a filter set is exactly the kind of key that widens silently when someone adds a facet to the interface. That is a client-side change with no backend deploy. That is why "nothing changed" can be true, and the ratio can still halve.
2. **Evictions and memory.** If `evicted_keys` is rising and memory is at `maxmemory`, entries are being pushed out before their [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") ends. That is a capacity answer. The fix is either more memory or a smaller working set. A smaller working set usually means caching fewer, larger, more reusable things, instead of many small ones.
3. **Invalidation volume.** An event-driven purge that now fires far more often. In the marketplace, the specific shape is a bulk import. If each row emitted its own event, 20,000 rows would produce 20,000 cache invalidations and 20,000 upserts. That is precisely why the import emits one completion event, and the indexer re-projects in batches of 200. A regression that reverts that batching would show up first as a collapsed hit ratio, not as an import failure.
4. **Did the cache lose its data?** A Redis failover, a restart, a `maxmemory-policy` change, or a key-prefix change in a deploy. A prefix change is a total cold start. It looks like a catastrophic ratio drop, and it resolves on its own, but only if you know to wait instead of intervening.
5. **TTL changes.** Someone shortened a TTL for freshness and paid for it in hit ratio. That trade should be made deliberately, and often it is not.
6. **A shift in the traffic *mix*, not its volume.** The question says that traffic did not change. But "the same requests per second" and "the same distribution" are different claims. Think of a crawler, an integration partner, or a scripted comparison workflow that enumerates listings. It produces the same request rate over a completely flat key distribution, and no cache can help with that. In the marketplace, this also has a security reading. Systematic enumeration is catalogue scraping. There are per-vendor detail-fetch caps, designed to make scraping slow enough to notice.

**Deciding whether it is now doing harm.** There are three tests.

*The arithmetic one.* The cache helps when `hit_ratio × saved_cost > lookup_cost + (1 − hit_ratio) × write_cost`. A Redis round trip is a few milliseconds. The uncached path on the marketplace search is about 45 ms in Postgres plus 25 ms in Mongo. At an 85% hit ratio, that is strongly positive. At 10%, you are adding 3–7 ms to nearly every request, to save the database occasionally. There is a crossover point, and it is worth computing it instead of arguing about it.

*The capacity one.* Even a poor hit ratio can be worth keeping if the backing store cannot survive the full load. The marketplace design states the number plainly. Losing `redis-cache` entirely is not an outage, because with cache-aside every read falls through. But latency rises from about 35 ms to about 107 ms, and Postgres load multiplies roughly sixfold. Capacity is sized to survive that. Knowing that number is what turns "should we keep the cache" from an opinion into a decision.

*The correctness one, which outranks both.* A cache that serves stale data beyond what the product can tolerate is doing harm at any hit ratio. The structural protection here is that the listing key carries the revision: `cat:listing:{id}:v{rev}`. So a stale key is simply unreachable, even if the purge message is lost. Invalidation correctness depends on the revision pointer in Postgres being current, not on a message arriving. That is the pattern I would reach for in general. Prefer a key design where staleness is impossible over an invalidation protocol that must not fail.

**What I would do instead of removing it.** First, fix the key design. Normalise filter parameters, so equivalent queries hash identically. Drop parameters that do not affect the result. And cache the expensive shared fragment, not the whole thing per user. Then check that the stampede protections still work. A low hit ratio together with a hot key is how a cache expiry becomes a database incident. Single-flight per key plus probabilistic early expiry limit the recomputation to roughly one per TTL, regardless of concurrency. But those only help if they are still in the path.

**And one thing I would check before any of it.** Did the ratio drop, or did the *metric* drop? A relabelled metric, a new keyspace that is not included in the aggregation, or a scrape failure all look identical to a real regression on a dashboard. Confirming the measurement before acting on it costs a minute. Sometimes it saves the entire investigation.

</details>


---

### API-18. How do you decide a cache is doing more harm than good?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
There are three cases. The first is when the hit ratio is so low that the cache mostly adds a round trip and an invalidation risk to a query that was fine. The second is when the staleness it introduces is producing support tickets. The third is when it has become the thing that must not fail. Any of those is a reason to remove the cache, not to tune it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The signals I actually look at.**

- **A low hit ratio.** A cache that hits only a small fraction of the time pays the lookup cost on every request. It pays the write cost on every miss. And it buys very little. Usually the cause is a key that is too specific, meaning a key that includes a parameter that varies per caller. Or the cause is a working set far larger than the memory allocated. Either way, the honest options are to fix the key, size the cache properly, or remove it. Leaving a low-hit cache in place is pure overhead, with an invalidation liability attached.
- **Staleness producing tickets.** If people report that they published something and cannot see it, the tolerance assumed at design time was wrong. Sometimes the fix is invalidation. Sometimes the honest fix is to accept that this data should not have been cached.
- **It has stopped being optional.** The test is whether the system is correct and survivable with the cache empty. If capacity has quietly been sized on the assumption of a warm cache, then a restart or a flush is an outage. The cache has become a load-bearing component without anyone deciding that. The marketplace writes that down as a number, not a hope: see **API-17** above, and **ARCH-19** in [architecture.md](architecture.md) for what it costs on recovery.
- **The invalidation logic is now the complicated part.** When more code exists to keep the cache correct than to compute the value, the cache now increases the cost it was meant to reduce.

**What I check before removing it.** Whether the underlying query is actually slow now. Caches are often added for a query that was later fixed with an index, and then nobody removed the cache. So it protects nothing while it carries all the risk. Measuring the uncached path is a ten-minute experiment, and occasionally it deletes a whole subsystem.

**How I remove one safely.** Reduce the expiry step by step instead of deleting the cache outright, and watch the database load at each step. That turns a scary change into a measured one. If load rises unacceptably at some point, that is the evidence that the cache is genuinely needed. That evidence is a much better basis for keeping it than the fact that it is already there.

**And the case for keeping one that looks marginal.** A cache that absorbs a burst is not judged by its average hit ratio. Think of a key that is hit fifty times in one second during a spike, and never otherwise. It has a poor overall ratio, and it is doing exactly the job it exists for. So I look at the distribution, not the mean, before I conclude anything.

</details>


---

### API-19. What makes cache invalidation go wrong, and what do you do about it?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Almost always, it is a key that nobody deleted. Either the delete was in a code path that failed, or the set of affected keys cannot be enumerated. The structural fix is to make invalidation unnecessary. Put the version in the key. Then a new version is a new key, and the old key simply ages out.

<details>
<summary><strong>Detailed answer</strong></summary>

**The recurring failure modes.**

- **A delete that did not happen.** The write succeeded, but the invalidation ran after the commit and the process died. Or the call raised an exception and the exception was swallowed. Now a stale value is served indefinitely. This is common precisely because invalidation is usually the line in a function that looks least important.
- **A key set you cannot enumerate.** One change affects an unknown number of cached queries. People respond with a pattern-based delete, which is a scan of the keyspace and a serious operational hazard on a large instance. Or they respond with a full flush, which turns a small update into a total cache loss and a stampede.
- **The wrong key.** Keys are constructed in two places with slightly different rules, such as a missing parameter or a different order. So the write path deletes one key, and the read path reads another. Nothing raises an error.
- **A cross-tenant key.** A key that leaves out the scope, so one organisation's cached response is served to another organisation. That is a disclosure, not a staleness bug. It is the reason that gateway response caching is disabled on data paths by policy, not by omission.
- **The race.** A read misses and fetches the value. Meanwhile a concurrent update has already invalidated the key. The read then writes the cache after that delete. So the stale value lives out its full expiry.

**What I do, in order of preference.**

1. **Version the key.** Include the entity's revision in it. A change produces a new key. The old key is never read again, and it expires quietly. No delete has to succeed for correctness. This removes the first, third and fifth failure modes at once.
2. **Invalidate from the event, not from the request.** The consumer that already handles the change deletes the keys. So invalidation is retried and dead-lettered like any other message handling. It is not a fire-and-forget call at the end of a request.
3. **Where the key set cannot be enumerated, do not pretend.** Use a short expiry, and say so. An honest bounded staleness is better than an invalidation strategy that silently misses keys.
4. **Build the key in exactly one place**, a single function, with the scope always in it.
5. **Never flush globally as an operational habit.** If that is the recovery procedure, the caching design has a defect.

**And the property I would state for any cache:** every cached value can be derived from a source of truth, and the system is correct with the cache empty. If that is not true, it is not a cache.

</details>


---

### API-20. Redis is memory-bound. What happens when it fills, and how do you configure for that?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
It depends entirely on the eviction policy. That is why a cache and a broker should not share an instance. A cache should evict least-recently-used keys, and that is correct. A broker, or anything durable, must refuse writes instead of evicting, because eviction there is silent data loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the memory limit does.** When usage reaches the configured maximum, the eviction policy decides what happens. With no eviction, writes are refused with an error, and reads keep working. With a least-recently-used or least-frequently-used policy, keys are discarded to make room. That happens either across all keys, or only across the keys that have an expiry set.

**Why that single setting decides the architecture.**

- **The cache instance** is configured to evict least-recently-used keys that have expiries. Filling up is a normal operating state, and eviction is the designed behaviour. The consequence is a lower hit ratio and more database load. That is visible in metrics, and it is survivable, because capacity is sized for a cold cache.
- **The broker instance** is configured to refuse writes instead of evicting. If it evicts, queued tasks vanish with no error anywhere. The producer got an acknowledgement, the consumer never sees the task, and nothing anywhere reports a problem. A publish that fails loudly is far better, because the caller can retry, or the outbox can hold the row.

They are opposite settings, and one instance has only one eviction policy. One instance can combine the two roles only by evicting just the keys that have an expiry, and the Redis documentation advises two separate instances for that case where possible. That is the concrete reason for two instances. It is not a preference for tidiness.

**What I monitor.** Used memory against the maximum, the eviction rate, the hit ratio, and the count of keys without an expiry. That last one is the leak detector. A cache that steadily collects keys that nobody set an expiry on will eventually consist entirely of those keys. Then the eviction policy that only considers keys with expiries has nothing to evict.

**Fragmentation** is worth naming, because it surprises people. The ratio of memory that the allocator holds to memory actually used can drift well above one. So the instance appears full while it holds much less. It is a metric to watch, not a number to assume.

**On persistence.** Snapshotting has a fork cost that can briefly double memory. That is exactly the wrong thing to happen on an instance near its limit. The append-only log is more durable, and it has its own rewrite behaviour. For the cache, persistence is unnecessary, because a cold restart is a designed state. For the broker, persistence matters, and that is another reason the two are separate.

**And the deployment consequence.** Memory limits are set explicitly, instead of being left to the container's limit. That way the process makes its own eviction decision, instead of being killed by the platform. Being terminated for exceeding memory is the worst outcome: total loss, with no eviction and no error.

</details>


---

### API-21. Where would you not use Redis?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
I would not use it as the source of truth for anything, or as the only holder of a durability guarantee. I would not use it for a distributed lock that protects something where double execution actually matters. And I would not use it for large objects. In each of those cases, its speed is being used to hide a guarantee that it does not provide.

<details>
<summary><strong>Detailed answer</strong></summary>

**As a source of truth.** It is memory-first with configurable persistence, and all the persistence options have a window. That is fine for a cache and unacceptable for a fact. The failure is gradual, not dramatic. Something is cached. Then something is stored there because it was convenient. And eventually a value exists nowhere else. My rule is that the system must be correct with it empty. If that is not true, something has quietly become a database without backups.

**As the durability guarantee for idempotency.** Idempotency keys held there are an optimisation. If they are flushed, a duplicate request gets reprocessed. The thing that must prevent a double charge is a unique constraint in the database. If you rely on the cache alone, the guarantee disappears with a restart, and it disappears silently.

**For a distributed lock protecting something that actually matters.** Single-instance locks are unsafe under failover. The multi-instance algorithm is contested. It depends on timing assumptions that do not hold with process pauses or clock drift. My position is practical, not a matter of principle. I use it for advisory coordination where a rare double execution is tolerable. An example is a semaphore that limits a vendor's import concurrency, where two extra workers once in a while do no harm. Where double execution is not tolerable, the correctness comes from the database: a unique constraint, or a row claimed with a lock that skips rows already claimed. Then the lock is an optimisation to reduce contention. It is not the thing that prevents the error.

**For large objects.** Storing files or large documents fills memory fast, and memory is the most expensive storage in the estate. Those objects belong in object storage, with a reference held somewhere else.

**For anything that needs queries.** There are no secondary indexes worth relying on and no joins. And scanning the keyspace on a large instance is an operational hazard. If the access pattern needs a query, it needs a database.

**And as a queue where durability matters**, which is the specific case worth stating. Used as a task broker, it lacks true acknowledgement semantics, so a worker that dies in the middle of a task can lose the work. That is acceptable for tasks that can be derived again, and not for tasks that cannot. The honest way to hold that position is to test it by killing a worker in the middle of a task. Do not assume that the configuration protects you.

</details>

