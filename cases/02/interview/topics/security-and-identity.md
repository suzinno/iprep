# Security and Identity

> 15 questions on token validation and claims design, tenant isolation and cross-customer access, [SCIM](https://scim.cloud/ "System for Cross-domain Identity Management — Standardizes automated provisioning and deprovisioning of user identities between systems") provisioning and deprovisioning against Entra ID, key compromise, secrets handling, and personal data in logs and traces. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except SEC-02, SEC-03, SEC-04, SEC-06, SEC-07, SEC-08, SEC-09, SEC-10, SEC-11, SEC-12 and SEC-14, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-06, SEC-07, SEC-08, SEC-09, SEC-10, SEC-11, SEC-12, SEC-13, SEC-14, SEC-15
- **retail-software-marketplace** — SEC-02, SEC-03, SEC-04, SEC-05, SEC-07, SEC-13, SEC-14, SEC-15

---

## 1. Authentication and token validation

---

### SEC-01. You implemented SCIM 2.0 and Azure Entra ID for clinician account provisioning; can you explain how you structured the JWT validation logic within FastAPI to ensure secure, isolated access between the clinician care-team views and the patient portal?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Two identity planes with two distinct token audiences, and the separation is an audience check that fails closed at the gateway before application code runs — a clinician token presented on a patient route is rejected with a `403` at Azure [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management, and vice versa. The service then re-validates rather than trusting a header, so bypassing the gateway is not bypassing authentication. Beyond authentication, *reach* is enforced in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") by row-level security joining through the temporal care-relationship table, so a query somebody forgets to scope returns zero rows instead of another patient's record.

<details>
<summary><strong>Detailed answer</strong></summary>

**The two planes.** Patients self-register into an external tenant and receive tokens with the audience `api://care-platform/patient`. Clinicians and care-team staff exist only in the hospital's Azure Entra ID tenant, are **never** self-service, and receive `api://care-platform/clinician`. The brief's requirement that clinician accounts "stay off the patient portal" is therefore not a user-interface rule — it is an audience value, checked before anything else.

**Where validation happens, and why twice.** The gateway validates signature against a cached [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")), issuer, expiry and **audience against the route's plane**. That means a forged or wrong-plane token never reaches the cluster at all. Then `care-core` validates again locally, and this second check is the one I would defend hardest: a service that trusts an `X-User-Id` header set by the gateway has made the gateway the only thing between an attacker inside the network and every record. The edge is a filter, never the authority. Neither check makes a network call per request — JWKS is cached in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") with a twelve-hour lifetime — which is both a latency decision and, deliberately, the identity-provider outage mitigation: during an Entra ID outage, existing tokens keep validating and active sessions are unaffected, while new sign-ins fail.

**How it is structured in [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation").** A dependency on the router, not a check in each endpoint. The patient router carries a dependency requiring the patient audience; the clinician router requires the clinician audience. Declaring it on the router is the design decision that matters: adding an endpoint under that prefix inherits the check rather than needing someone to remember it, and a per-endpoint check is a control that works until the day someone adds an endpoint. The dependency returns a typed principal — subject, audience, roles, plane — so handlers work against a value rather than reaching into the request, and the requirement shows up in the generated [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document.

Access tokens are short-lived at fifteen minutes with rotated, client-bound refresh tokens, using authorization code flow with Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")). Multi-factor authentication on the clinician side is the hospital's conditional access policy, which the platform does not weaken.

**The part that actually protects data, which is not the token.** Authentication establishes *who*; the harder question is *which patients*. That check — does an active care relationship exist between this clinician and this patient at this instant — lives in the database as row-level security. Each request sets a session configuration parameter with `SET LOCAL` inside the request transaction, and policies on every patient-scoped table join through the temporal `care_relationship` range. Application-layer checks exist too, but they are the second line. The reason this is the strongest control in the design is that it converts the most common class of application bug — a query missing a scope clause — into an empty result set rather than a disclosure.

Three implementation details decide whether that is real, and each is asserted by a test rather than left to review:

- **`SET LOCAL`, never a plain `SET`.** A transaction-mode pooler reuses a backend across requests, and a session-scoped setting would leak one caller's identity into the next caller's query — turning the strongest control into its exact opposite. There is a pooled-connection leakage test for precisely this.
- **The application role is `NOSUPERUSER` and lacks `BYPASSRLS`**, and migrations run as a separate owning role that never serves a request. A role-privilege assertion runs in the pipeline.
- **Policies are written so the patient predicate still reaches the planner**, keeping partition pruning intact on the monthly-partitioned tables. A policy hiding the key behind an opaque subquery silently turns a pruned index scan into a full sweep, so there is an `EXPLAIN` assertion guarding the plan shape.

**SCIM's role in all of this.** `scim-provisioning-svc` implements Users and Groups, with Entra ID as the sole authorised caller, authenticated by its own client credential and network-restricted. Create, update and `active: false` map to clinician and care-team-member rows — and **a deprovisioning closes every open care relationship for that clinician in the same transaction.** Access ends when employment ends, with no platform-side action. That is why a SCIM sync failure is a *paged* alert rather than a ticket: a deprovisioning that did not land means access that should have ended has not, which is a security event rather than an integration hiccup.

**And the seam nobody expects.** The [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") check-in listener authenticates the *connection*, not each publish, and authorises publishes only to the topic matching the token's subject. Because authentication is per connection, a long-lived mobile connection has to be re-validated against token expiry out of band — so connections carry a maximum lifetime shorter than the refresh window and are forced to re-authenticate. That gap is flagged explicitly in the design rather than assumed away, and it is the kind of detail I would rather raise myself than be caught by.

</details>


---

### SEC-02. A new requirement needs the caller's identity to carry more than it does today. How do you avoid solving that by adding claims?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By asking whether the thing being added changes independently of the token's lifetime. Anything that can change while a token is live does not belong in it — because a claim is a snapshot, and a stale snapshot of a permission is an authorization defect that no expiry short enough will fix.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the pull to add a claim is strong.** It is free at read time: no lookup, no network call, no dependency. On a system whose entire latency budget rests on validating tokens locally against a cached key set rather than calling an introspection endpoint, adding one more field to something already being parsed looks like the obvious answer.

**The test I apply.** Does this fact change on the token's schedule or on its own? Issuer, audience, subject, account type and coarse scopes change when the session does, so they belong in the token. A record-level permission, a team membership, an organisation's subscription state or an entitlement changes whenever the business changes it — which may be thirty seconds after the token was minted. Putting it in the token means the system is enforcing yesterday's answer, and the only remedies are shortening the token life, which costs the latency you were protecting, or reissuing on every change, which is a distributed invalidation problem far worse than the lookup you avoided.

**So where does it go instead.** Into the data layer, evaluated per request against the store that owns it. On the health platform, "may this clinician see this patient" is an active row in a relationship table with a validity period — access has a start and an end, history is not overwritten, and revocation takes effect on the next request rather than on the next token. On the marketplace it is the organisation on the token compared against the organisation owning the row, applied in one place by the repository layer. Both are lookups, both are indexed, and both are correct at the moment of use.

**Three more reasons not to grow the token.**

- **A token is signed, not encrypted.** Anything in it is readable by anyone holding it, including on a device you do not control. An entitlement list is a description of your permission model handed to whoever asks.
- **Size.** Tokens travel on every request and often in a header with a size limit somewhere in the path. Growth is discovered as a mysterious failure at a proxy.
- **It becomes an interface.** Once a consumer reads a claim, removing it is a breaking change, and now the identity provider's schema is coupled to application logic.

**Where I would genuinely add one.** A stable, coarse fact that gates routing rather than records — an account type or a tenant identifier — because those are what the gateway needs to reject a request before any application code runs, and they do not change while a fifteen-minute token is alive.

</details>


---

### SEC-03. Your API accepts tokens issued by a hospital's Entra tenant. What exactly do you validate, and what is the mistake that lets a token from any other organisation in?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Signature against the tenant's published keys, then issuer, audience, expiry and not-before — and then the one people miss, the tenant identifier against an allowlist. The mistake is configuring the application as multi-tenant and validating the issuer against the shared metadata endpoint, whose issuer value is a template. Accept that and every Entra tenant in the world satisfies your issuer check, which means anyone with a Microsoft work account can obtain a token your API will honour.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checks, in order, and none of them is optional.**

1. **Signature**, against the keys published at the tenant's key-set endpoint, selecting by the `kid` header. Keys rotate, so the set is cached — twelve hours here — and refreshed on an unrecognised `kid` rather than on a timer alone. The long cache is deliberate: it is also the identity-provider outage mitigation, since existing tokens keep validating while new sign-ins fail.
2. **Algorithm**, pinned. Accept the asymmetric algorithm you expect and nothing else — never read the algorithm out of the token header and trust it, which is how signature bypasses happen.
3. **Issuer**, exactly. Entra's version 2 issuer is the login host plus the tenant identifier plus a version suffix; version 1 tokens use a different host entirely. Accepting either loosely is a common mistake, and so is failing to notice that the two token versions carry different claim shapes.
4. **Audience**, against this API's identifier — not the client's. Two distinct planes exist here with two distinct audience values, and the gateway checks the audience against the route's plane so a clinician token on a patient path is rejected before application code runs.
5. **Tenant identifier against an allowlist.** The check that actually establishes *which organisation* this is.
6. **Expiry and not-before**, with a small clock-skew tolerance and no more.
7. **Token type.** An identity token is not an access token; its audience is the client application, not your API. Accepting one because it parses and has a valid signature is a real and recurring vulnerability.
8. **Delegated scope versus application role.** A token from the client-credentials flow has no user behind it, and treating its application permissions as though a person consented to them is how a service integration acquires user-level reach.

**The multi-tenant trap, spelled out.** A single-tenant application resolves metadata from its own tenant, and the published issuer is a concrete value containing that tenant's identifier — so the issuer check does the tenant check for free. A multi-tenant application resolves metadata from the shared endpoint, and the published issuer is *templated* with a placeholder for the tenant. Libraries handle this by substituting the tenant identifier from the token itself, which means the issuer always matches. The check passes for every tenant on the platform, and unless you then compare the tenant identifier against a list you maintain, any Microsoft work or school account can obtain a token your API accepts. What saves you afterwards is that the principal still has no care relationship and therefore reaches no data — but that is defence in depth doing the work of authentication, and it is not a position to be in deliberately.

**Identity claims, which is the other recurring mistake.** The stable identifier for a principal is the object identifier together with the tenant identifier. Email address, user principal name and preferred username are all mutable, are not guaranteed to be verified, and can in some configurations be set by a directory administrator to a value that collides with something meaningful in your system. Anything keyed on an email address as a user identity is a rename away from an account-takeover story. The clinician record here keys on the directory object identifier for exactly this reason.

**Validate twice, and mean it.** The gateway validates signature, issuer, expiry and audience so a forged or wrong-plane token never reaches the cluster. The service then validates again locally against the cached key set and applies its own rules. A service that trusts a header the gateway set has made the gateway the only thing standing between anyone inside the network and every record. The edge is a filter; it is never the authority.

**A rotation hazard worth raising unprompted**, because the marketplace design flags exactly this: a gateway caches the key set on its own schedule, independent of the application's cache. During a signing-key rotation the two can disagree, and tokens signed with the new key are rejected at the edge while the cluster would have accepted them. The fix is to make the key-overlap window strictly longer than the slowest cache's refresh interval — which requires knowing that interval on the specific tier you are running, not assuming it.

**And the limitation to state honestly.** All of this is authentication. None of it decides what the principal may reach. In this design that decision is a database join against a temporal care relationship, evaluated per request — which is the reason a validated token from an unexpected tenant returns empty results rather than someone's record.

</details>


---

### SEC-04. How would you bound the damage from a leaked signing key?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By being able to rotate without an outage, which means the key set is fetched by identifier and cached with a known refresh interval, more than one key is trusted at a time, and the overlap window is longer than every cache in the path. Without that, rotation is itself an outage and so it never happens.

<details>
<summary><strong>Detailed answer</strong></summary>

**What a leaked signing key means.** Anyone holding it can mint a token that every validator accepts, with any subject, any audience and any scopes. Every downstream control that trusts the token is bypassed. It is the closest thing to a total authentication compromise, so the only question that matters is how quickly the key can stop being trusted.

**What makes rotation possible.**

- **Tokens carry a key identifier**, and validators select the key by it rather than assuming a single key. Without that, two keys cannot be trusted at once and rotation is a hard cut.
- **The key set is fetched from the provider and cached**, and the cache refreshes on a known interval. Every validator must be able to pick up a new key without a deploy.
- **More than one key is published during a transition**, so tokens signed with either verify.
- **The overlap window exceeds every cache in the path.** This is the specific trap on these systems: the gateway caches the key set on its own schedule, independently of the application's cache. During a rotation the two can disagree, so tokens signed with the new key are rejected at the edge while services would accept them. The fix is to make the overlap strictly longer than the gateway's refresh interval — and to confirm what that interval actually is on the tier in use, rather than assuming the documented default, before the first rotation rather than after.

**The emergency sequence, if a key is actually leaked.** Publish a new key and get it into every cache. Start signing with it. Then remove the old key from the published set, which is the moment forged tokens stop working — so the exposure window is bounded by the slowest cache refresh, which is exactly why that number needs to be known in advance. Then force re-authentication by invalidating refresh token families, because tokens minted with the leaked key must not be exchangeable for new legitimate ones.

**Reducing the blast radius beforehand.** Keys held in a managed store, never in configuration or an image. Ideally never exported at all — signing performed by the store — so there is nothing to leak. Separate keys per environment, so a non-production leak is not a production incident. And short access token lifetimes, so the residual damage after the key is withdrawn expires quickly.

**The part I would insist on.** Rehearsing a rotation on a schedule, in production, before there is an incident. A rotation procedure that has never been executed is an assumption, and this is one where the failure mode — everyone logged out simultaneously — is severe enough that nobody will attempt it for the first time under pressure.

</details>

---

## 2. Authorization and tenant isolation

---

### SEC-05. What should happen when an authenticated user tries to access another customer's data?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
For cross-tenant access the honest status is `403` (authenticated but not permitted), but the better answer is usually `404`: revealing that a resource exists in someone else's tenant is itself a leak. Either way the decision must be enforced server-side, in one place, and the attempt must be audited.

<details>
<summary><strong>Detailed answer</strong></summary>

**The scenario.** A category manager at retail group A requests a shortlist belonging to retail group B. Three things have to be true.

**First, the check must be server-side and in one place.** The marketplace enforces tenant scope as a session-level filter applied by the repository layer, deliberately not per endpoint, because a per-endpoint check "is a control that works until the day someone adds an endpoint". The cancer platform goes further and pushes it into the database as row-level security, so a query a developer forgets to scope returns zero rows rather than another patient's record — its design calls this the single most important control it has, because it converts the most common class of application bug into an empty result set. Hiding the resource in the user interface is not a control at all; the request is being made against the API, not against the page.

**Second, choose the status deliberately.** `403` is semantically correct. But `403` on an identifier that exists and `404` on one that does not is an oracle: an attacker can enumerate valid identifiers across tenants without ever reading a record. So the common — and I think correct — choice for cross-tenant access is to return `404` and make "not yours" and "not there" indistinguishable. This falls out naturally from the enforcement mechanism: if the tenant filter is in the query, the row is simply not found, and `404` is what the handler would produce anyway. That is a nice property — the safe status code is the one the safe implementation produces without anyone deciding.

**Third, the attempt is a security event.** A cross-tenant request is not a routine `403`. Both designs audit it: the cancer platform's detection rules over the audit stream name "a clinician reading records outside their care team" as a specific rule rather than a generic anomaly, and the marketplace writes an `audit_event` for every tenant-scope bypass a platform admin performs. Rate-limit the caller too, because one such request is a bug in their client and a hundred is enumeration.

**The name for this class.** Broken object-level authorization — the vulnerability where an endpoint checks that you are logged in but not that the object belongs to you. It is consistently the most common serious API flaw in the field, and the defence is structural: one enforcement layer, plus a test that asserts a cross-tenant read returns empty for **every** org-owned repository method, which is exactly the compensating control the marketplace names for choosing application-layer filtering over database row-level security.

*The other half of this question — what `401` and `403` each mean and which to return when — is **API-03** in [api-and-read-paths.md](api-and-read-paths.md).*

</details>


---

### SEC-06. How would you demonstrate to an auditor that an access control actually works?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
With three kinds of evidence rather than an assertion: the control's definition in version control with its review history, an automated check that fails when the control is removed, and production records showing it operating — access logged, exceptions recorded and reviewed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why "we have row-level policies" is not an answer.** It describes an intention. An auditor's question is whether the control is present, effective and continuously operating, and each of those needs different evidence. The useful thing about preparing for that question is that answering it properly also makes the control genuinely better — most of what an auditor wants is what an engineer should want anyway.

**Present.** The policy definitions are in migrations in version control, so what is deployed is reviewable and its history shows who changed it and when. Any change went through review. That is a much stronger statement than a screenshot of a current configuration, because it covers the whole period rather than this moment.

**Effective — and this is where most of the work is.**

- **A test asserting the negative case**, and crucially one that enumerates rather than exemplifies: every scoped repository method called with a principal from another scope, asserting empty. A new method is covered automatically, which is the only version that stays true.
- **Evidence that the test can fail.** A check that has never failed has not been shown to check anything, so the control is removed deliberately, the test is observed going red, and the control is restored. For a control whose failure is silent that is the only feedback available, and demonstrating it is what converts a green pipeline from a claim into evidence.
- **Assertions on the control's preconditions.** That the application's database role has no bypass privilege. That the identity is applied with transaction scope, proved by a test running two requests through the same pooled connection and asserting the second sees nothing of the first — because a pooler reusing a backend across requests is exactly where this control silently becomes its opposite.
- **A plan assertion**, since a policy rewritten for readability can hide the partition key from the planner and convert a pruned scan into a full sweep. That is a performance failure rather than a security one, but it is the same class: a change that looks like a tidy-up and is not.

**Continuously operating.** Every access writes an audit row in the same transaction as the access itself, so the trail cannot be lost in a queue. Exceptional access — break-glass — is a distinct, time-boxed grant with a recorded reason and a review inside a day, and the review is itself evidenced. Alert rules live in infrastructure code, so a silenced alert is a reviewable diff rather than a slow decay nobody sees.

**What I would say honestly if asked what could still go wrong.** A platform administrator path exists and is audited rather than prevented; the audit's completeness depends on the write path being the only path; and none of this addresses someone with legitimate access misusing it, which is a detection problem rather than a prevention one.

</details>


---

### SEC-07. Where should an authorization decision live — the gateway, the application, or the database? How do you choose?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
As deep as the mechanism can be made trustworthy. The gateway is a filter and never the authority; the application is where most decisions land; the database is the strongest place and only where the deployment topology actually supports it. These two systems chose differently for that reason.

<details>
<summary><strong>Detailed answer</strong></summary>

**The gateway.** Good for coarse, route-level decisions: is this token valid, is it the right audience, does this account type belong on this route family. On the health platform the patient and clinician planes are separate audiences, so a clinician token on a patient route is rejected before any application code runs. But it is a filter, never the authority — each service revalidates locally, so bypassing the gateway is not bypassing authentication. A control that only exists at the edge is a control that assumes nothing ever reaches the service another way.

**The application.** Where most record-level decisions live, because that is where the caller, the resource and the business rule are all in scope. The risk is well known: a check that must be remembered at each call site is a control that works until someone adds a call site. The mitigations are structural — enforce it at the router as a dependency rather than inside handlers, and apply the scope in the repository layer in one place rather than per endpoint.

**The database.** The strongest, because a query someone forgets to scope returns zero rows rather than someone else's record. On the health platform the policies are the single most important control in the design, joining through the relationship table so that access is a data question rather than a code question.

**Why the marketplace deliberately did not use it**, which is the interesting half. The catalog read path uses a pooled connection under a shared role. Database-level filtering depends on a per-request session setting, and with a transaction-mode pooler reusing a backend across requests, a session-scoped setting leaks one caller's identity into the next caller's query — turning the strongest control in the design into its exact opposite. Relying on a mechanism the topology cannot support is worse than not relying on it, because everyone believes it is there.

**So the choice rule.** Push it as deep as the mechanism is trustworthy in this deployment, and pay for a weaker mechanism with a stronger test. The marketplace pays for its application-layer filter with a test asserting a cross-scope read returns empty for every scoped repository method, plus an audit row on every administrative bypass. The health platform pays for its database-level control with a pooled-connection leakage test, a role-privilege assertion and a plan assertion.

**And the anti-pattern worth naming.** The same decision implemented in two places with two definitions. Then they disagree eventually, and the one that is wrong is the one nobody is testing. One owner per rule, enforced in the deepest layer it can be, and referenced elsewhere rather than restated.

</details>

---

## 3. SCIM and directory integration

---

### SEC-08. Walk me through implementing SCIM 2.0 `PATCH`. Why is that the part that breaks, and how do you keep it correct when two updates for the same user arrive at once?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
`PATCH` breaks because it is the only part of SCIM that is a small expression language rather than a document swap: each operation carries an `op`, an optional `path` that can contain a filter, and a `value` whose shape depends on both. Getting multi-valued attributes right — emails, group members, roles — is most of the work. Concurrency is handled by serialising per directory object rather than by optimistic locking, because the client will not resolve a version conflict for you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why `PATCH` and not `PUT`.** `PUT` replaces the whole resource, so any attribute the client omits is semantically deleted — which means a client that does not send every attribute silently destroys data. `PATCH` sends only what changed, which is both safer and what Entra ID actually prefers to send. So `PATCH` is the path that carries almost all real traffic, and it is the one worth building carefully.

**The three operations, and where each goes wrong.**

- **`replace` with no path** — the value is an object whose keys are merged into the resource. The common mistake is treating it as a full replacement.
- **`replace` with a simple path** — `{"op":"replace","path":"active","value":false}`. This is the disable path and therefore the most security-relevant single message the service receives.
- **`add`** — on a single-valued attribute it behaves as replace; on a multi-valued attribute it *appends*. Implementing `add` as assignment for both is the classic bug: a user's second email address overwrites the first.
- **`remove`** — requires a path, and on a multi-valued attribute the path usually carries a filter: `path: members[value eq "abc"]`. So the implementation needs a small filter parser, not a dictionary lookup. Treating `members` as a scalar and clearing the whole collection is how a single group-membership removal empties a care team.

**The details that are easy to miss.**

- **Attribute names are case-insensitive** per the specification. Matching them case-sensitively produces intermittent failures that look random.
- **`externalId` is the client's identifier and `id` is yours**, and they are not interchangeable. Here the clinician row carries both — `entra_object_id` and `scim_external_id`, each unique — because the directory's object identifier is the stable join key and the SCIM identifier is what appears in request paths.
- **Type coercion.** Values that arrive as a string where the schema says boolean are a known class of client quirk. Coerce deliberately and reject what you cannot interpret rather than treating a truthy string as true.
- **`active: false` is a soft delete**, and it is the deprovisioning signal. Treating it as an ordinary attribute update rather than as a lifecycle event is how access outlives employment. Here it maps to closing every open care relationship for that clinician **in the same transaction** — the whole point of the integration.
- **Return the updated resource**, or `204` consistently, and set `ETag` if you claim to support versioning. Claiming versioning support in `ServiceProviderConfig` and then ignoring `If-Match` is worse than not claiming it.
- **Error bodies matter**, because the client branches on them. A `409` for a duplicate `userName`, a `400` with a `scimType` of `invalidValue` for a malformed patch, a `404` for an unknown identifier. A generic `500` for a bad request causes the client to retry forever.

**Concurrency, which is the second half of the question.** Two updates for the same user can arrive concurrently — a role change and a disable, or a retry overlapping the original. Last-write-wins on the whole row is wrong here: a disable being overwritten by an in-flight role update means an account that should be closed is open, which is a security failure rather than a data-quality one.

Optimistic concurrency via `ETag`/`If-Match` is the specification's answer, and it is the wrong tool in this case because the client is not going to re-read and merge on a `412` — it will escrow the record and retry it later, if at all. So this design serialises instead: a Redis lock keyed on the directory object identifier (`lock:scim:{entra_object_id}`) with a short expiry, held for the duration of the operation. Concurrent updates for *one* user queue; updates for different users run fully parallel, so the throughput cost is nothing at this volume. A short expiry matters — a lock that outlives a crashed pod blocks that user's provisioning until it expires.

Underneath the lock the operation is still idempotent and still transactional: the patch is applied and any lifecycle consequence — closing care relationships — commits with it. So a redelivery after a lock expiry converges rather than double-applying.

**And the constraint that keeps the blast radius small.** This service writes the identity schema only — clinician rows, care-team membership, and the care relationships a deprovisioning closes. It never touches the record, diary or content schemas. That is what makes a bug here an identity problem rather than a clinical-record problem, and it is the reason the extraction was defensible at all.

</details>


---

### SEC-09. Entra ID is the only client of your SCIM service. What does it actually do that the specification does not require, and what breaks if you implement the specification literally?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It matches existing users by issuing a filtered `GET` before deciding whether to create — so if you do not implement filtering on the matching attribute, every cycle creates duplicates instead of updating. It runs a full initial cycle and then incremental cycles on a schedule measured in tens of minutes, escrows and retries individual failures with backoff, and puts the whole job into quarantine after sustained failures. Implementing the specification literally and testing only against your own client is how all of that is discovered in production.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it does that the specification does not require.**

- **It discovers your capabilities and believes you.** It reads `ServiceProviderConfig`, and on some configurations `Schemas` and `ResourceTypes`. Advertising support for something you have not implemented — `PATCH`, filtering, sorting, `ETag` — makes it use a path that then fails. The honest move is to advertise exactly what works.
- **It matches before it writes.** The provisioning cycle asks "does this user already exist" with a filtered query on the matching attribute, typically `GET /scim/v2/Users?filter=userName eq "someone@trust.example"`. If filtering is unimplemented or returns everything, the match fails and the client concludes the user is new. The result is duplicate accounts on every cycle rather than a visible error — silent, cumulative, and exactly the sort of failure this pipeline exists to prevent. Filtering is not optional in practice even though the specification treats much of it as such.
- **It prefers `PATCH` over `PUT`**, so `PATCH` carries the real traffic.
- **It disables rather than deletes.** The normal lifecycle signal for a departing clinician is `active: false`, not `DELETE`. A hard delete arrives only in narrower circumstances. An implementation that only handles `DELETE` as deprovisioning will never deprovision anyone.
- **It runs an initial cycle then incremental ones**, and the incremental interval is measured in tens of minutes rather than seconds. That interval dominates the end-to-end deprovisioning latency, which is a separate question worth its own answer.
- **It escrows failures and retries them.** A record that fails is retried on later cycles with decreasing frequency, and eventually abandoned. So a transient bug does not lose the change immediately — but a persistent one loses it quietly, weeks later, with nobody watching.
- **It quarantines the job.** Sustained failures — most often authentication failures — put the whole provisioning job into quarantine, after which it retries on a much slower schedule. The important operational consequence: **provisioning can stop entirely while every dashboard on our side looks perfectly healthy**, because a service that receives no requests reports no errors.
- **It respects throttling.** A `429` with `Retry-After` is handled properly, which means rate limiting this endpoint is safe — and is worth having, since an endpoint that can disable accounts should not be unbounded.
- **It sends attributes shaped by the tenant's mapping configuration**, not by your schema. Someone in the directory team can change a mapping and change what arrives, with no code change on either side.

**What breaks if you implement the specification literally.** Duplicates from missing filter support; deprovisioning that never fires because only `DELETE` was handled; retry storms from returning `500` on malformed input the client will never fix; an integration that quarantines because a credential expired and nobody noticed; and multi-valued attribute corruption from treating `add` as assignment.

**So how do you test it when the client is a product you do not control?**

1. **A SCIM specification compliance suite** as the baseline — it catches the protocol-level mistakes cheaply.
2. **Contract tests against captured real payloads.** Record what the tenant actually sends for create, update, disable, group add and group remove, and replay those as fixtures. This is the highest-value suite by a distance, because it tests the client you actually have rather than the one the specification describes.
3. **A staging tenant doing a real provisioning cycle** before anything reaches production. Nothing else exercises matching, escrow and quarantine behaviour.
4. **Integration tests against a real database**, since the lifecycle consequence — closing care relationships transactionally — is the part that matters and is exactly what a mocked repository would pass while broken.

**And the monitoring that follows from all of the above.** Because the failure mode is silence, the alerts cannot be error-rate alerts. What is needed is a *liveness* signal on the integration: time since the last successful provisioning request, alerting when it exceeds a couple of cycles. Alongside it, a periodic reconciliation comparing the directory's view with the local clinician table, so an account active here and disabled there is surfaced rather than assumed impossible. A SCIM sync failure is a paged alert in this design, not a ticket, and that is the reason: a deprovisioning that did not land means access that should have ended has not, which is a security event.

</details>


---

### SEC-10. How do a clinician's roles and team memberships get from the directory into an authorization decision, and what happens when a user belongs to more than two hundred groups?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
They mostly do not travel in the token, and that is deliberate. App roles give coarse capability in the `roles` claim; everything about *reach* — which patients, which team — is resolved from the database on every request, because it changes faster than a token lives. The two-hundred-group case is the reason to avoid group claims entirely: past that limit Entra omits the groups claim and substitutes an overage indicator pointing at Microsoft Graph, so any design that reads groups from the token silently stops working for exactly the most senior users.

<details>
<summary><strong>Detailed answer</strong></summary>

**The three mechanisms, and what each is good for.**

- **Group claims.** The token carries directory group identifiers — opaque object identifiers, not names. Useful if the directory's groups genuinely are your authorization model. Two problems: the identifiers are meaningless without a mapping you maintain, and the claim has a hard size limit.
- **App roles.** Roles are declared on the application registration, assigned to users or groups in the directory, and emitted in the `roles` claim. They are your vocabulary rather than the directory's, they are bounded by what you defined, and an administrator assigning them is making a statement about *your* application rather than about a mailing list. This is the better mechanism for capability and it is what the role model here maps onto — clinician, care-team administrator, content author, content approver, platform operator.
- **Nothing in the token at all**, with the decision resolved server-side per request. This is what carries the important half of the model.

**The overage behaviour, precisely.** Past roughly two hundred groups in a JSON Web Token — the limits differ by token type and are lower for some flows — Entra stops emitting the groups claim and instead includes an overage indicator with a pointer to a Microsoft Graph endpoint that returns the full list. Any code doing `if "nurse-group-guid" in token["groups"]` now throws a key error or, far worse, evaluates to false and denies a legitimate user. And it happens to the users with the most memberships, who tend to be the longest-serving and most senior clinicians. The workaround — calling Graph per request to resolve the real list — adds a network round trip to every authorization decision, which is precisely what both these designs refuse to do: the latency budget rests on authorization requiring no network call.

So the overage rule is not a corner case to handle; it is an argument against the mechanism.

**What this system actually does.** Capability comes from the role; **reach comes from the database**. The question "may this clinician see this patient" is answered by a row-level security policy joining through the temporal care-relationship table, evaluated inside the request transaction. That has three consequences worth saying out loud:

1. **Freshness.** A clinician removed from a care team loses reach on their very next query, with no token refresh and no waiting fifteen minutes. Putting reach in a token means access outlives the decision to revoke it by the token's lifetime — unacceptable for a record where team membership is the access-control boundary.
2. **Size.** A clinician may follow hundreds of patients. That list can never be a claim; tokens would be enormous and stale.
3. **Single definition.** There is exactly one place that defines the relationship, and both the record layer and the search layer derive scope from it. A token-carried copy would be a second definition, and two definitions of an authorization fact is how they drift.

The membership *is* cached, but only for the duration of a single request — explicitly never longer, because a stale authorization fact is a disclosure rather than a slow page.

**Where directory groups still earn their place.** Group-to-role assignment in the directory is a good administrative model: the hospital manages a group, the group is assigned an app role, and the role arrives in the token. That keeps the directory team's workflow intact without making group identifiers part of the application's logic. Group *provisioning* over SCIM is also how care-team membership arrives here as data — which is the right place for it, since it then lives in the database where reach is evaluated rather than in a claim.

**The general principle.** Put in the token what is stable for the token's lifetime and small enough to carry: who you are, which tenant, what kind of principal, what capability. Resolve everything volatile or large at request time from the system of record. The test I would apply to any claim someone proposes adding is: if this changes one minute after the token is issued, what happens? If the answer is "they keep the access for fifteen minutes", it does not belong in the token.

</details>


---

### SEC-11. A clinician is deprovisioned in the hospital directory at nine in the morning. When exactly do they lose access, and what dominates that number?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Not immediately, and the dominant term is not the one people expect. The access token's fifteen-minute lifetime is the small part; the directory's provisioning cycle — tens of minutes — is what actually sets the number. But the honest answer is better than that arithmetic suggests, because a still-valid token buys almost nothing here: reach is resolved from the database on every request, and the deprovisioning closes the care relationships in the same transaction, so the moment the SCIM call lands the record goes empty even for a token that has not expired.

<details>
<summary><strong>Detailed answer</strong></summary>

**The chain, with each link's contribution.**

1. **Directory change at 09:00.** Instant, and invisible to us.
2. **Waiting for the next incremental provisioning cycle.** Tens of minutes. **This dominates.** It is a schedule inside a product we do not control, and no amount of engineering on our side shortens it.
3. **The SCIM request arrives and commits.** Milliseconds. `active: false` maps to the clinician row and closes every open care relationship for that clinician in the same transaction.
4. **Their existing access token remains cryptographically valid** for up to its full fifteen minutes, and their session may hold a refresh token too.

Naively that is a cycle plus fifteen minutes. In practice the fourth term mostly does not matter, and understanding why is the interesting part.

**Why the token lifetime is nearly irrelevant here.** The token establishes *who*, not *what they may reach*. Reach is a row-level security policy joining through the temporal care-relationship range, evaluated inside each request's transaction against the current state of the database. Closing those relationships in step three means the very next query from that still-valid token returns zero rows — not an error, an empty record. The same scope is projected into the search index as a mandatory filter derived from the caller's token and the current relationships, so search closes at the same moment rather than becoming the way around it.

So the effective exposure window is step two, and the mitigations belong there rather than in token lifetimes. That is a direct payoff of a design decision made much earlier — putting the authorization boundary in the database instead of in a claim — and it is worth naming as such, because the alternative design would have had a genuinely fifteen-minute hole.

**What is left exposed, and I would not gloss over it.** Anything the token authorises that is *not* patient-scoped: reading their own profile, endpoints gated by role alone. And the long-lived device connection path — the broker authenticates a connection rather than each publish, so a connection established before the revocation persists until its maximum lifetime forces re-authentication. That gap is flagged explicitly in the design rather than assumed away, and connection lifetimes are deliberately set shorter than the refresh window because of it.

**What to do when tens of minutes is not acceptable.** It depends entirely on why someone is being removed. Routine offboarding at the end of a notice period does not need to be fast. A suspension for cause does, and for that the answer is not to speed up the provisioning cycle — it is to have a second, immediate path:

- **Revoke the sign-in session in the directory**, which invalidates refresh tokens so nothing new is issued. It does not retract the access token already in the wild.
- **A denylist consulted at validation time**, checked against a small, fast store. This is what the marketplace does for a suspended vendor — an event publishes the deactivation and services consult a denylist of revoked token identifiers — and it is the general answer to the gap between "token issued" and "token should no longer work". The cost is a lookup on every request, which is why it holds only the exceptions rather than every principal.
- **Continuous Access Evaluation**, which exists for exactly this and lets a resource reject a token near-real-time on a critical directory event. It is worth knowing about, and worth being precise that a custom API has to participate in it — it is not something you inherit by pointing at Entra.
- **An in-platform emergency disable** that does not wait for the directory at all: set the clinician inactive and close their relationships now, and let the SCIM cycle reconcile later. Since every operation here is idempotent, an out-of-band disable followed by the directory's own disable converges rather than conflicting.

**And the detection that makes the whole thing trustworthy.** A SCIM sync failure is a *paged* alert in this design, not a ticket, precisely because the failure mode is silence: a quarantined provisioning job means deprovisionings simply stop arriving while every dashboard on our side looks healthy. There is a detection rule over the audit stream for a deprovisioning that did not close its care relationships, and a periodic reconciliation between the directory's view and the local clinician table catches an account active here and disabled there. Without those, the answer to "when do they lose access" would be "we believe within an hour", and belief is not a control.

</details>


---

### SEC-12. The SCIM endpoint can create and disable clinician accounts and is called by something outside your network. Threat-model it.

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
It is the highest-privilege external surface in the system — it writes the table that authorization is derived from — and the two worst outcomes are opposite: mass deprovisioning, which takes clinicians out of the record mid-consultation and is a patient-safety event, and unauthorised provisioning, which is an attempt to manufacture an insider. The controls are a strong client credential with no shared secret, network restriction, strict separation from the patient plane, a volume circuit-breaker on destructive operations, and audit on everything.

<details>
<summary><strong>Detailed answer</strong></summary>

**The threats, ranked by what they actually cost.**

| Threat | Consequence | Control |
|---|---|---|
| Mass deprovisioning, malicious or from a mapping error | Clinicians lose the record mid-consultation. In a clinical setting this is a safety event, not an outage | Volume threshold on destructive operations with human confirmation above it; audit and alert on disable rate |
| Credential compromise, then unauthorised provisioning | An attacker tries to manufacture a clinician account | Certificate or federated credential, no shared secret; network restriction; and the fact that a row alone grants nothing without a directory-issued token |
| User enumeration through the filter endpoint | The staff directory of a hospital trust is itself sensitive | Authenticated caller only, rate limiting, uniform responses, audit on query volume |
| Injection through attribute values | Stored cross-site scripting or a broken record downstream | Strict schema validation; unknown fields rejected rather than absorbed |
| Replay of a captured request | Duplicate or reverted lifecycle changes | Transport security, short-lived credentials, idempotent operations keyed on the directory identifier |
| Exposure of the endpoint on the patient plane | A patient-audience token reaching provisioning | Separate route and audience; never published through the patient-facing surface |
| Directory compromise upstream | Full legitimate-looking access | Accepted and stated; detection rather than prevention |

**The nuance that makes the provisioning threat less bad than it first looks, and worth saying.** Writing a clinician row does not by itself grant access. Authentication still requires a token issued by the hospital's directory for that object identifier, and reach still requires an active care relationship. So an attacker holding only the SCIM credential can create a row that nobody can authenticate as. To get an actual session they would need to compromise the directory too — at which point they have a legitimate identity and this endpoint is not their problem. That is defence in depth genuinely working, and it is an argument for keeping the authorization boundary in the database rather than in provisioning.

**Which is also why mass *deprovisioning* is the more serious direction.** It needs no second compromise to do damage: it is a single credential away, it is fast, it looks exactly like normal traffic, and its effect is immediate because reach is resolved per request. A bad attribute mapping configured by a well-meaning administrator produces the same outcome as an attacker. So the control I would insist on is a rate threshold on the disable path — beyond some number of deprovisionings in a window, stop and require a human decision. It is mildly annoying during a genuine bulk offboarding and it is the difference between an incident and a catastrophe.

**The controls, concretely.**

- **The directory is the sole authorised caller**, authenticated with its own client credential and network-restricted. I would push for a certificate or a federated credential over a shared secret — a long-lived secret in a directory configuration is a credential nobody rotates, and its expiry is also a favourite cause of a silently quarantined provisioning job.
- **Strict input validation.** Every request body is a typed model, so unknown fields are rejected rather than absorbed. The attribute set arriving here is shaped by a tenant-side mapping that someone can change without touching our code, which makes validation a genuine boundary rather than a formality.
- **Rate limiting**, safe to apply because the client honours throttling responses correctly.
- **Everything is audited** — actor, operation, target, and the trace identifier joining it to the rest of the telemetry. The lifecycle consequence is audited as its own event, not folded into a generic update.
- **Detection rules that name specific misuse** rather than generic anomalies: a deprovisioning that did not close its care relationships, an unusual volume of disables, provisioning activity outside the directory team's normal pattern.
- **Deployment must not drop requests.** This service uses a rolling update precisely because it has an external caller and idempotent operations; the client's escrow-and-retry behaviour is the safety net, and it only works because every operation is idempotent.
- **Blast radius is bounded by schema ownership.** This service writes the identity schema and nothing else. A compromise here cannot rewrite a prescription.

**What I would state as accepted rather than solved.** The hospital directory becomes a trust dependency of the platform: compromise it and platform access follows, and no control on our side prevents that. The answer is detection — out-of-team access rules, volume anomalies, break-glass review within twenty-four hours — plus the fact that every patient-data access writes an immutable audit row in the same transaction as the access, so a legitimate-looking insider leaves a complete trail. Being explicit about where prevention ends and detection begins is more useful than implying the controls are stronger than they are.

</details>

---

## 4. Secrets and data protection

---

### SEC-13. Threat-model an endpoint that accepts file uploads from an untrusted client. What are you defending against, and in what order do the controls go in?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Against four categories: the file harming the server that receives it, the file harming whoever downloads it later, the upload path being used to exhaust resources, and the storage location being used to reach things it should not. The controls go in from the outside inward — authenticate and authorise, cap size and rate before reading a byte, validate type by content rather than by what the client claimed, quarantine and scan before the file is addressable, and serve it back from an origin where a malicious file cannot do damage.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I am defending against, named concretely.**

- **Malware distributed through us.** A vendor uploads a datasheet, a retailer downloads it, and the platform was the delivery mechanism. Reputationally this is the worst outcome even though the platform itself was never compromised.
- **Stored cross-site scripting.** An SVG or [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers") file served inline from the application's own origin executes with that origin's privileges — it can read the session and act as the user. This is the most likely real exploit and the least dramatic-sounding.
- **Parser exploits and decompression bombs.** Image and document libraries are large C surfaces; a crafted file can crash or exploit the process that parses it, and a zip bomb or a pixel-flood image exhausts memory during thumbnailing.
- **Server-side request forgery and path traversal.** A filename with traversal sequences, or an ingestion step that fetches a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") the file specifies.
- **Resource exhaustion.** Very large files, many concurrent uploads, or many small ones occupying the processing pool.
- **The upload being a data-exfiltration or storage-abuse channel** — using the platform as free file hosting, or writing to a prefix another tenant reads.
- **[XML](https://www.w3.org/XML/ "Extensible Markup Language — Markup format for structured, machine and human readable documents") External Entity and formula injection** in the structured-import case, where the "file" is a spreadsheet or an XML document that a parser will interpret.

**The controls, in the order they go in.**

1. **Authenticate and authorise first.** Anonymous upload is a different and much harder problem. Both these systems only accept uploads from an authenticated principal scoped to an organisation, and the quota is per organisation.
2. **Bound it before reading it.** A declared size in the upload intent, a hard cap enforced at the gateway and the web application firewall, and a per-tenant rate quota — five import jobs per vendor per day in the marketplace. Reject at the edge; a request rejected after it has consumed a worker has already cost what you were protecting.
3. **Keep the bytes off the application entirely.** This is the highest-leverage structural decision. The clinical platform issues a scoped, short-lived Shared Access Signature ([SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Time-limited token granting scoped access to an Azure Storage resource")) so the client uploads directly to blob storage; multi-megabyte scans never touch the pods serving a clinician's timeline. That removes memory exhaustion, parser exposure and bandwidth contention from the API tier in one move — and the metadata write stays transactional because the intent is recorded before the bytes arrive.
4. **Land it somewhere it cannot be reached.** Uploads go to a quarantine container, not to the served location. In the clinical design a document row is not visible to any client until its scan state is clean, and the file is promoted to the documents container only after `fn-blob-ingest` reports a clean scan. **An unscanned file is never addressable**, which is the property that makes the whole thing defensible rather than a race.
5. **Validate type by content, not by claim.** Content-type headers and file extensions are client-supplied. Sniff the magic bytes, enforce an allowlist — never a denylist — and reject anything that does not match what was declared. An allowlist fails closed on a format nobody thought about.
6. **Scan, then transform.** Malware scanning, then re-encoding rather than passing the original through: the marketplace re-encodes images in `fn-media-process`, which strips metadata and defeats most polyglot and parser-exploit files as a side effect. Do the parsing in an isolated, resource-limited, time-limited worker — never in the request path — because a decompression bomb should kill a bounded job, not a web pod.
7. **Strip metadata.** Images carry location and device data; documents carry author and revision history. For patient-uploaded documents in a clinical system that is a privacy obligation, not a nicety.
8. **Control the download path, which is where the stored-[XSS](https://owasp.org/www-community/attacks/xss/ "Cross Site Scripting — Attack that injects malicious script into content viewed by other users") defence actually lives.** Content-addressed paths with a generated identifier, never the client's filename. `Content-Disposition: attachment` so nothing renders inline. A strict `Content-Type` from your own detection rather than the client's. And — the control people miss — **serve user-supplied files from a separate hostname**, so even a successful stored XSS executes in an origin that holds no session and can reach nothing. The marketplace does exactly this: datasheets go out through a dedicated download hostname, so no vendor-supplied file is ever served from the origin hosting the admin console.
9. **Authorise the download too.** Short-lived, scoped read tokens rather than unguessable URLs. An unguessable URL is a bearer token with no expiry and no revocation.
10. **Audit and observe.** Who uploaded what, when, and what the scan concluded; alert on scan failures and on unusual volume per tenant.

**The ordering principle behind the list.** Cheap and certain checks before expensive and fallible ones — a size cap costs nothing and a malware scan costs seconds, so the cap goes first. And every control assumes the one before it failed, which is why "unscanned files are unreachable" matters more than any individual scanner: it is a structural property rather than a detection.

</details>


---

### SEC-14. How do you handle secrets and credentials in an application and its pipeline?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By having as few as possible. Workload identity federation means a service authenticates to cloud resources as itself with no stored credential, which removes the whole class of problem for most of them. What genuinely must be a secret lives in a managed store, is injected at runtime, and is never in an image or a repository.

<details>
<summary><strong>Detailed answer</strong></summary>

**Eliminate first.** The best secret is one that does not exist. A federated workload identity — a cluster service account trusted by the cloud identity provider, mapped to a managed identity per service — means database, storage and message access happen with no connection string and no stored key anywhere in the cluster. The same applies to the deployment pipeline: it authenticates by federation rather than holding a long-lived service principal secret. That removes rotation, leakage and expiry as concerns for the majority of what used to be secrets.

**What remains** — third-party credentials, signing keys, anything the platform does not federate — lives in a managed secret store, referenced by identity rather than copied, and injected at runtime as environment values or mounted files. Never baked into an image, because an image is distributed and cached and lives longer than anyone expects.

**In the pipeline.** Masked variables scoped to protected branches, so a fork or an unprotected branch cannot read them. No secret ever echoed, including in a debug run — and note that a value in a variable can still leak through a command that prints its own arguments or through a tool's verbose output, which masking does not always catch. Applies run only from the default branch under the federated identity.

**Detection, because prevention fails eventually.** A secret scanner in pre-commit and as a pipeline gate, and a scan of history when adopting it on an existing repository. A committed secret is compromised the moment it is pushed, so the response is always rotate first and then clean the history — removing it without rotating is theatre.

**Rotation.** Anything that cannot be federated has a rotation procedure that has actually been executed, because the failure mode of an untested rotation is discovering a consumer nobody knew about at the moment the old credential stops working. Rotation with an overlap window, and the overlap window longer than any cache that holds the credential — which is the same lesson as the signing key rotation, in a different guise.

**Where I would want a review.** Any change to identity configuration or role assignment. Role assignments are declared in infrastructure code specifically so that a widened permission is a reviewable diff rather than a click nobody sees, and I would flag any such change for someone else to look at rather than treat it as ordinary work.

</details>


---

### SEC-15. Personal data is flowing through logs, traces, error reports and a message payload. How do you keep it out of the places it does not belong, and how would you prove it is out?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Mark the sensitive fields once on the model that defines them, and let every output path — log formatter, trace attributes, error serialiser, message envelope — read that same mark, so there is one owner of "this field is sensitive" rather than four. Then make it impossible to regress: a pipeline check that fails the build when a log call passes a model carrying a sensitive field, and a periodic scan of what actually landed in the log store. Proving it means sampling the destinations, not reading the code.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four leaks, because each needs a different mechanism.**

*Logs.* The obvious one, and the easiest to fix structurally. The rule in the clinical platform is absolute: **no clinical free text, no symptom values, no document contents are ever logged.** Every line is JSON carrying `trace_id`, `span_id`, `service`, `module`, `actor_kind` and where applicable a patient identifier — identifiers, never content. A redaction filter driven by the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") model drops known-sensitive fields at the formatter, which is the right layer because it catches every call site including the ones in libraries. The marketplace has the same rule for message bodies, tokens and client secrets.

*Traces.* Easier to forget and just as exposed. Auto-instrumentation captures database statement text and [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") request attributes, and a statement with a bound literal or a query string with an email address is now in the tracing backend, which frequently has different retention and different access control from the log store. Disable statement-parameter capture, allowlist span attributes rather than denylisting them, and apply the same redaction to the exporter.

*Error reports.* The worst offender, because the whole point of an error report is to capture state. A framework validation error will happily include the rejected value; an exception handler that logs the request body defeats every other control at once. So: never serialise a request body into an error; report the field name and the rule that failed, never the value. Both these systems use problem-detail bodies, and the discipline is that `detail` is a description, not a dump.

*Message payloads.* The one people forget entirely, because a queue feels internal. It is not — it is a store with its own retention, its own dead-letter queue that someone will read during an incident, and its own access control. The pattern I prefer is a thin event carrying identifiers and letting the consumer read what it needs under its own authorisation, rather than a fat event carrying the data. The clinical design does the strong version of this at the model boundary: the [NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Natural Language Processing — Computational techniques for analyzing and generating human language") service receives diagnosis code, treatment line, stage and locale for page composition — *not* the patient's identity, name or contact details — and extraction calls that must see note text receive the text and a correlation id, never the patient identifier. Data minimisation applied to an internal hop, which is where it is usually skipped.

**Making it one owner rather than four.** The property that makes this maintainable is that "sensitive" is declared once, on the Pydantic model that defines the field, and the log formatter, the span exporter, the error serialiser and the event envelope all read that same declaration. Four independent redaction lists is four things to drift, and the one that drifts is the one you find out about from a regulator.

**Keeping it out permanently.** A rule enforced by review is a rule that holds until a busy week. The clinical platform makes it a build gate: **a continuous-integration check fails the build if a log call passes a model containing a field marked sensitive.** That turns a convention into a control. Alongside it: a linter banning direct formatting of request bodies into log calls, and default-deny allowlists for span attributes — because a denylist is a list of the leaks you thought of.

**And the distinction that keeps the whole design honest.** Audit is a database table, never a log stream. Logs are for operators; audit is for the regulator. Conflating them means log retention policy silently becomes audit policy — and it also means the thing you most want to redact aggressively and the thing you must retain immutably for seven years are the same pipeline, which is an impossible position. Separating them lets logs be ruthlessly minimal.

**Proving it is out.** Code review proves intent; only the destination proves outcome.

1. **Sample the log store and search it.** Pattern-match for the shapes that should never appear — identifier formats, email addresses, free-text fields, token prefixes — as a scheduled job with an alert, not a one-off audit. This is the check that finds the leak nobody anticipated, which is by definition the one the allowlist missed.
2. **Do the same in the tracing backend and the error reporter.** Different systems, different teams, frequently different retention. A control verified in one and assumed in the others is unverified.
3. **Inspect a dead-letter queue's contents** as part of the exercise, since that is a message store with a long tail and human readers.
4. **Test the redaction with a known-positive and a known-negative.** Log a model with a sensitive field populated and assert it is absent from the output; log one without and assert the surrounding structure is intact. A redaction filter that has never been shown to redact is an assumption — and the failure mode of a broken one is silence, which looks exactly like success.
5. **Verify the build gate can actually fail.** Introduce a violating log call on a branch and confirm the pipeline goes red. A gate that has only ever passed has not been demonstrated to do anything.
6. **Check retention and access on each destination**, because "it is only in logs" is not a defence if the logs are retained for two years and broadly readable. Residency too — for the clinical system, all resources and all backups sit in a single region with no cross-border transfer, and a telemetry backend outside that region would breach it as surely as a database would.
7. **Prove deletion works end to end.** A data subject access request or an erasure request has to reach every destination, and a personal identifier sitting in a log store nobody enumerated is the reason erasure requests are hard. The right answer is usually that logs carry pseudonymous identifiers only, so there is nothing to erase there — but that has to be true, not assumed.

**One honest note on scope.** Erasure and retention genuinely conflict, and in both these systems retention wins for a defined class of data — a medical record is retained under health-records law, and a vendor's record of a commercial negotiation is not the individual's to delete. Those positions are stated to the user at consent and are defensible; what is not defensible is promising deletion and quietly not performing it. Keeping personal data out of the peripheral systems in the first place is what makes the remaining conflict small enough to explain.

</details>

