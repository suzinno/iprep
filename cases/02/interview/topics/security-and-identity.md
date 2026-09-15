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
There are two identity planes, with two distinct token audiences. The separation is an audience check at the gateway, and it fails closed before application code runs. A clinician token presented on a patient route is rejected with a `403` at Azure [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management. A patient token on a clinician route is rejected the same way. The service then validates the token again instead of trusting a header. So bypassing the gateway is not bypassing authentication. Beyond authentication, *reach* is enforced in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") by row-level security, which joins through the temporal care-relationship table. So if somebody forgets to scope a query, it returns zero rows instead of another patient's record.

<details>
<summary><strong>Detailed answer</strong></summary>

**The two planes.** Patients self-register into an external tenant. They receive tokens with the audience `api://care-platform/patient`. Clinicians and care-team staff exist only in the hospital's Azure Entra ID tenant. They are **never** self-service, and they receive `api://care-platform/clinician`. The brief requires that clinician accounts "stay off the patient portal". Because of the two planes, that requirement is not a user-interface rule. It is an audience value, and it is checked before anything else.

**Where validation happens, and why it happens twice.** The gateway validates the signature against a cached [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")). It also validates the issuer, the expiry and **the audience against the route's plane**. That means a forged or wrong-plane token never reaches the cluster at all. Then `care-core` validates the token again, locally. This second check is the one I would defend hardest. A service that trusts an `X-User-Id` header set by the gateway has made the gateway the only thing between an attacker inside the network and every record. The edge is a filter, never the authority. Neither check makes a network call per request. The gateway caches the JWKS itself, and `care-core` caches it in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") with a twelve-hour lifetime. That Redis cache is a latency decision. It is also, deliberately, the mitigation for an identity-provider outage. During an Entra ID outage, existing tokens keep validating until they expire. So active sessions keep working until their access tokens run out, while new sign-ins fail.

**How it is structured in [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation").** A dependency on the router, not a check in each endpoint. The patient router carries a dependency that requires the patient audience. The clinician router requires the clinician audience. Declaring it on the router is the design decision that matters. A new endpoint added under that prefix inherits the check, so nobody needs to remember it. A per-endpoint check is a control that works until the day someone adds an endpoint. The dependency returns a typed principal: subject, audience, roles and plane. So handlers work with a value instead of reaching into the request. Also, the requirement shows up in the generated [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") document.

Access tokens are short-lived, at fifteen minutes, and the refresh tokens are rotated and bound to the client. The tokens come from the authorization code flow with Proof Key for Code Exchange ([PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Protects an OAuth authorization code exchange for clients that cannot hold a secret")). On the clinician side, multi-factor authentication is the hospital's conditional access policy, and the platform does not weaken that policy.

**The part that actually protects data, which is not the token.** Authentication establishes *who*. The harder question is *which patients*. That check asks one thing: does an active care relationship exist between this clinician and this patient at this instant? The check lives in the database as row-level security. Each request sets a session configuration parameter with `SET LOCAL` inside the request transaction. Policies on every patient-scoped table join through the temporal `care_relationship` range. Application-layer checks exist too, but they are the second line. This is the strongest control in the design for one reason. It converts the most common class of application bug, a query missing a scope clause, into an empty result set instead of a disclosure.

Three implementation details decide whether that protection is real. A test asserts each one, so none of them is left to review:

- **`SET LOCAL`, never a plain `SET`.** A transaction-mode pooler reuses a backend across requests. So a session-scoped setting would leak one caller's identity into the next caller's query. That would turn the strongest control into its exact opposite. There is a pooled-connection leakage test for exactly this.
- **The application role is `NOSUPERUSER` and lacks `BYPASSRLS`.** Migrations run as a separate owning role that never serves a request. A role-privilege assertion runs in the pipeline.
- **Policies are written so the patient scope can use the index.** Some queries rely on the policy for their patient scope. Those queries use the patient index only when the policy is written in a form that becomes an index condition. Otherwise the policy runs as a filter over every row of each monthly partition the query reads. Partition pruning is not affected, because it comes from the time bound. So an `EXPLAIN` assertion guards the plan shape.

**SCIM's role in all of this.** `scim-provisioning-svc` implements Users and Groups. Entra ID is the only authorised caller. It authenticates with its own client credential, and the SCIM service is network-restricted. Create, update and `active: false` map to clinician and care-team-member rows. And **a deprovisioning closes every open care relationship for that clinician in the same transaction.** Access ends when employment ends, with no action on the platform side. That is why a SCIM sync failure is a *paged* alert and not a ticket. A deprovisioning that did not land means that access which should have ended has not ended. That is a security event, not a small integration problem.

**And the gap nobody expects.** The [MQTT](https://mqtt.org/ "Message Queuing Telemetry Transport — Lightweight publish-subscribe protocol for constrained devices and unreliable networks") check-in listener authenticates the *connection*, not each publish. It authorises publishes only to the topic that matches the token's subject. Authentication happens per connection, so a long-lived mobile connection has to be validated again against token expiry, out of band. For that reason, connections carry a maximum lifetime shorter than the refresh window, and they are forced to authenticate again. The design flags that gap explicitly instead of assuming it does not exist. It is the kind of detail I would rather raise myself than have someone else point out.

</details>


---

### SEC-02. A new requirement needs the caller's identity to carry more than it does today. How do you avoid solving that by adding claims?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By asking whether the thing being added changes independently of the token's lifetime. Anything that can change while a token is live does not belong in the token. The reason is that a claim is a snapshot. A stale snapshot of a permission is an authorization defect, and no expiry will fix it, however short it is.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why adding a claim is so tempting.** It is free at read time: no lookup, no network call, no dependency. Take a system whose whole latency budget rests on validating tokens locally, against a cached key set, instead of calling an introspection endpoint. On that system, adding one more field to something already being parsed looks like the obvious answer.

**The test I apply.** Does this fact change on the token's schedule, or on its own schedule? Issuer, audience, subject, account type and coarse scopes change when the session does. So they belong in the token. A record-level permission, a team membership, an organisation's subscription state or an entitlement changes whenever the business changes it. That may be thirty seconds after the token was issued. If you put that fact in the token, the system enforces yesterday's answer. Then there are only two remedies. You can shorten the token life, which costs the latency you were protecting. Or you can reissue the token on every change, which is a distributed invalidation problem far worse than the lookup you avoided.

**So where does it go instead.** Into the data layer, evaluated per request against the store that owns the fact. On the cancer platform, "may this clinician see this patient" is an active row in a relationship table with a validity period. Access has a start and an end. History is not overwritten. And revocation takes effect on the next request, not on the next token. On the marketplace, the organisation on the token is compared with the organisation that owns the row. The repository layer applies that check in one place. Both are lookups, both are indexed, and both are correct at the moment of use.

**Three more reasons not to grow the token.**

- **A token is signed, not encrypted.** Anyone holding it can read anything in it, including on a device you do not control. So an entitlement list in a token is a description of your permission model, handed to whoever asks.
- **Size.** Tokens travel on every request. They often travel in a header, with a size limit somewhere in the path. So you discover token growth as a mysterious failure at a proxy.
- **It becomes an interface.** Once a consumer reads a claim, removing that claim is a breaking change. And now the identity provider's schema is coupled to application logic.

**Where I would genuinely add one.** A stable, coarse fact that gates routing, not records: an account type or a tenant identifier. The gateway needs those facts to reject a request before any application code runs. And they do not change while a fifteen-minute token is alive.

</details>


---

### SEC-03. Your API accepts tokens issued by a hospital's Entra tenant. What exactly do you validate, and what is the mistake that lets a token from any other organisation in?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First the signature, against the tenant's published keys. Then the issuer, audience, expiry and not-before. And then the one people miss: the tenant identifier, against an allowlist. The mistake is to configure the application as multi-tenant and to validate the issuer against the shared metadata endpoint. The issuer value on that endpoint is a template. If you accept that value, every Entra tenant in the world satisfies your issuer check. That means anyone with a Microsoft work account can obtain a token your API will honour.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checks, in order, and none of them is optional.**

1. **Signature**, against the keys published at the tenant's key-set endpoint, selecting the key by the `kid` header. Keys rotate, so the set is cached, for twelve hours here. The set is refreshed when a `kid` is not recognised, not only on a timer. The long cache is deliberate. It is also the identity-provider outage mitigation, because existing tokens keep validating while new sign-ins fail.
2. **Algorithm**, pinned. Accept the asymmetric algorithm you expect and nothing else. Never read the algorithm out of the token header and trust it, because that is how signature bypasses happen.
3. **Issuer**, exactly. Entra's version 2 issuer is the login host, plus the tenant identifier, plus a version suffix. Version 1 tokens use a different host entirely. Accepting either issuer loosely is a common mistake. Another common mistake is not noticing that the two token versions carry different claim shapes.
4. **Audience**, against this API's identifier, not the client's. Here there are two distinct planes with two distinct audience values. The gateway checks the audience against the route's plane, so a clinician token on a patient path is rejected before application code runs.
5. **Tenant identifier against an allowlist.** This is the check that actually establishes *which organisation* this is.
6. **Expiry and not-before**, with a small clock-skew tolerance and no more.
7. **Token type.** An identity token is not an access token. Its audience is the client application, not your API. Accepting one because it parses and has a valid signature is a real and recurring vulnerability.
8. **Delegated scope versus application role.** A token from the client-credentials flow has no user behind it. Treating its application permissions as though a person consented to them is how a service integration gets user-level reach.

**The multi-tenant trap, in detail.** A single-tenant application resolves metadata from its own tenant. The published issuer is then a concrete value that contains that tenant's identifier. So the issuer check also does the tenant check, with no extra work. A multi-tenant application resolves metadata from the shared endpoint. There, the published issuer is *templated*, with a placeholder for the tenant. Libraries handle this by substituting the tenant identifier from the token itself. That means the issuer always matches. The check passes for every tenant on the platform. Unless you then compare the tenant identifier against a list you maintain, any Microsoft work or school account can obtain a token your API accepts. What protects you after that is that the principal still has no care relationship, so it reaches no data. But that is defence in depth doing the work of authentication. It is not a position to be in deliberately.

**Identity claims, which is the other recurring mistake.** The stable identifier for a principal is the object identifier together with the tenant identifier. Email address, user principal name and preferred username can all change. They are not guaranteed to be verified. And in some configurations a directory administrator can set them to a value that collides with something meaningful in your system. So if anything is keyed on an email address as a user identity, a single rename can lead to an account takeover. The clinician record here is keyed on the directory object identifier for exactly this reason.

**Validate twice, and do both checks for real.** Everything above runs at the gateway and again in the service. The reason is that a service that trusts a header the gateway set has made the gateway the only thing standing between anyone inside the network and every record. The edge is a filter. It is never the authority. **SEC-01** explains how the two checks are structured.

**A rotation hazard worth raising before anyone asks**, because the marketplace design flags exactly this. A gateway caches the key set on its own schedule, independently of the application's cache. During a signing-key rotation the two caches can disagree. Then tokens signed with the new key are rejected at the edge, while the cluster would have accepted them. The fix is to make the key-overlap window strictly longer than the refresh interval of the slowest cache. That requires knowing that interval on the specific tier you are running, not assuming it.

**And the limitation to state honestly.** All of this is authentication. None of it decides what the principal may reach. In this design, that decision is a database join against a temporal care relationship, evaluated per request. That is the reason a validated token from an unexpected tenant returns empty results instead of someone's record.

</details>


---

### SEC-04. How would you bound the damage from a leaked signing key?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By being able to rotate the key without an outage. For that, the key set is fetched by identifier and cached with a known refresh interval. More than one key is trusted at a time. And the overlap window is longer than every cache in the path. Without that, rotation is itself an outage, so it never happens.

<details>
<summary><strong>Detailed answer</strong></summary>

**What a leaked signing key means.** Anyone holding it can create and sign a token that every validator accepts, with any subject, any audience and any scopes. Every downstream control that trusts the token is bypassed. It is the closest thing to a total authentication compromise. So the only question that matters is how quickly the key can stop being trusted.

**What makes rotation possible.**

- **Tokens carry a key identifier**, and validators select the key by that identifier instead of assuming a single key. Without that, two keys cannot be trusted at once, and rotation becomes a hard switch from the old key to the new one.
- **The key set is fetched from the provider and cached**, and the cache refreshes on a known interval. Every validator must be able to pick up a new key without a deploy.
- **More than one key is published during a transition**, so tokens signed with either key verify.
- **The overlap window is longer than every cache in the path.** This is the specific trap on these systems. The gateway caches the key set on its own schedule, independently of the application's cache. During a rotation the two caches can disagree. So tokens signed with the new key are rejected at the edge, while services would accept them. The fix is to make the overlap strictly longer than the gateway's refresh interval. The fix also means confirming what that interval actually is on the tier in use, instead of assuming the documented default. Do that before the first rotation, not after it.

**The emergency sequence, if a key is actually leaked.** Publish a new key and get it into every cache. Start signing with it. Then remove the old key from the published set. That is the moment forged tokens stop working. So the exposure window is limited by the slowest cache refresh, and that is exactly why that number needs to be known in advance. Then force re-authentication by invalidating refresh token families. The reason is that tokens created with the leaked key must not be exchangeable for new legitimate ones.

**Reducing the blast radius beforehand.** Keys are held in a managed store, never in configuration or an image. Ideally the store performs the signing itself, so the keys are never exported and there is nothing to leak. Separate keys per environment, so a non-production leak is not a production incident. And short access token lifetimes, so the damage that remains after the key is withdrawn expires quickly.

**The part I would insist on.** Rehearsing a rotation on a schedule, in production, before there is an incident. A rotation procedure that has never been executed is an assumption. Here the failure mode is that everyone is logged out at the same time. That is severe enough that nobody will attempt a rotation for the first time under pressure.

</details>

---

## 2. Authorization and tenant isolation

---

### SEC-05. What should happen when an authenticated user tries to access another customer's data?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
For cross-tenant access, the honest status is `403` (authenticated but not permitted). But the better answer is usually `404`, because revealing that a resource exists in someone else's tenant is itself a leak. Either way, the decision must be enforced server-side, in one place, and the attempt must be audited.

<details>
<summary><strong>Detailed answer</strong></summary>

**The scenario.** A category manager at retail group A requests a shortlist that belongs to retail group B. Three things have to be true.

**First, the check must be server-side and in one place.** The marketplace enforces tenant scope as a session-level filter that the repository layer applies. It deliberately does not enforce it per endpoint, because a per-endpoint check "is a control that works until the day someone adds an endpoint". The cancer platform goes further and pushes the check into the database as row-level security. So if a developer forgets to scope a query, the query returns zero rows instead of another patient's record. **SEC-07** is where that choice is argued in full, together with the pooled-connection discipline it depends on. Hiding the resource in the user interface is not a control at all. The request is made against the API, not against the page.

**Second, choose the status deliberately.** `403` is semantically correct. But returning `403` on an identifier that exists and `404` on one that does not is an oracle. An attacker can use it to enumerate valid identifiers across tenants without ever reading a record. So for cross-tenant access the common choice, and I think the correct one, is to return `404`. That makes "not yours" and "not there" impossible to tell apart. This choice follows naturally from the enforcement mechanism. If the tenant filter is in the query, the row is simply not found, and `404` is what the handler would produce anyway. That is a nice property. The safe status code is the one that the safe implementation produces without anyone deciding.

**Third, the attempt is a security event.** A cross-tenant request is not a routine `403`. Both designs audit it. The cancer platform has detection rules over the audit stream. They name "a clinician reading records outside their care team" as a specific rule, not as a generic anomaly. The marketplace writes an `audit_event` for every tenant-scope bypass that a platform admin performs. Rate-limit the caller too. One such request is a bug in their client, but a hundred is enumeration.

**The name for this class.** Broken object-level authorization. It is the vulnerability where an endpoint checks that you are logged in, but not that the object belongs to you. It is consistently the most common serious API flaw in the field. The defence is structural: one enforcement layer, plus a test that asserts a cross-tenant read returns empty for **every** org-owned repository method. That test is exactly the compensating control the marketplace names for choosing application-layer filtering over database row-level security.

*The other half of this question is what `401` and `403` each mean, and which one to return when. That is **API-03** in [api-and-read-paths.md](api-and-read-paths.md).*

</details>


---

### SEC-06. How would you demonstrate to an auditor that an access control actually works?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
With three kinds of evidence, not an assertion. First, the control's definition in version control, with its review history. Second, an automated check that fails when the control is removed. Third, production records that show the control operating: access is logged, and exceptions are recorded and reviewed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why "we have row-level policies" is not an answer.** It describes an intention. An auditor asks whether the control is present, effective and continuously operating. Each of those needs different evidence. Preparing for that question has a useful effect: answering it properly also makes the control genuinely better. Most of what an auditor wants is what an engineer should want anyway.

**Present.** The policy definitions are in migrations in version control. So what is deployed is reviewable, and its history shows who changed it and when. Any change went through review. That is a much stronger statement than a screenshot of the current configuration, because it covers the whole period and not only this moment.

**Effective. This is where most of the work is.**

- **A test asserting the negative case.** Crucially, the test goes through every method instead of picking a few examples. It calls every scoped repository method with a principal from another scope, and it asserts an empty result. A new method is covered automatically. That is the only version that stays true.
- **Evidence that the test can fail.** A check that has never failed has not been shown to check anything. So the control is removed deliberately, the test is seen going red, and the control is restored. When a control fails silently, that is the only feedback available. Demonstrating it is what turns a green pipeline from a claim into evidence.
- **Assertions on the control's preconditions.** One asserts that the application's database role has no bypass privilege. Another asserts that the identity is applied with transaction scope. A test proves this by running two requests through the same pooled connection and asserting that the second sees nothing of the first. The reason is that a pooler reusing a backend across requests is exactly where this control silently becomes its opposite.
- **A plan assertion**, because a policy rewritten for readability can stop the patient index from being used. The rewritten policy then filters every row of the partitions the query reads. That failure is about performance, not security. But it is the same class: a change that looks like a tidy-up and is not.

**Continuously operating.** Every access writes an audit row in the same transaction as the access itself. So the trail cannot be lost in a queue. Exceptional access (break-glass) is a distinct, time-limited grant. It has a recorded reason and a review within a day, and the review itself is evidenced. Alert rules live in infrastructure code. So a silenced alert is a reviewable diff, not a slow loss of alerting that nobody sees.

**What I would say honestly if asked what could still go wrong.** A platform administrator path exists, and it is audited, not prevented. The audit's completeness depends on the write path being the only path. And none of this addresses someone with legitimate access who misuses it. That is a detection problem, not a prevention problem.

</details>


---

### SEC-07. Where should an authorization decision live — the gateway, the application, or the database? How do you choose?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
As deep as the mechanism can be made trustworthy. The gateway is a filter and never the authority. The application is where most decisions land. The database is the strongest place, but only where the mechanism can be made trustworthy in that deployment. These two systems chose differently for that reason.

<details>
<summary><strong>Detailed answer</strong></summary>

**The gateway.** It is good for coarse, route-level decisions. Is this token valid? Is it the right audience? Does this account type belong on this route family? On the cancer platform, the patient and clinician planes are separate audiences. So a clinician token on a patient route is rejected before any application code runs. But the gateway is a filter, never the authority. Each service validates the token again locally, so bypassing the gateway is not bypassing authentication. A control that exists only at the edge assumes that nothing ever reaches the service another way.

**The application.** This is where most record-level decisions live, because the caller, the resource and the business rule are all in scope there. The risk is well known. A check that must be remembered at each call site is a control that works until someone adds a call site. The mitigations are structural. Enforce the check at the router as a dependency, not inside handlers. And apply the scope in the repository layer, in one place, not per endpoint.

**The database.** The strongest place, because a query someone forgets to scope returns zero rows instead of someone else's record. On the cancer platform, the policies are the single most important control in the design. They join through the relationship table, so access is a data question and not a code question.

**Why the marketplace deliberately did not use it**, and this is the interesting half. The catalog read path uses a pooled connection under a shared role. Database-level filtering depends on a per-request session setting. With a transaction-mode pooler that reuses a backend across requests, a session-scoped setting leaks one caller's identity into the next caller's query. That turns the strongest control in the design into its exact opposite. `SET LOCAL` avoids the leak, because the setting ends with the transaction, and the cancer platform relies on exactly that. But a `SET LOCAL` outside a transaction has no effect, so the policy silently does nothing. So the topology can support database-level filtering, but only if every read path sets the session setting with `SET LOCAL` inside a transaction. The marketplace chose not to depend on it. Relying on a mechanism that is not enforced on every path is worse than not relying on it, because everyone believes it is there.

**So the choice rule.** Push the decision as deep as the mechanism is trustworthy in this deployment. And pay for a weaker mechanism with a stronger test. The marketplace pays for its application-layer filter with a test that asserts a cross-scope read returns empty for every scoped repository method. It also pays with an audit row on every administrative bypass. The cancer platform pays for its database-level control with a pooled-connection leakage test, a role-privilege assertion and a plan assertion.

**And the anti-pattern worth naming.** The same decision, implemented in two places with two definitions. Then the two eventually disagree, and the wrong one is the one nobody is testing. One owner per rule, enforced in the deepest layer it can be, and referenced elsewhere instead of restated.

</details>

---

## 3. SCIM and directory integration

---

### SEC-08. Walk me through implementing SCIM 2.0 `PATCH`. Why is that the part that breaks, and how do you keep it correct when two updates for the same user arrive at once?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
`PATCH` breaks because it is the only part of SCIM that is a small expression language, not a replacement of a whole document. Each operation carries an `op`, an optional `path` that can contain a filter, and a `value` whose shape depends on both. Most of the work is getting multi-valued attributes right: emails, group members, roles. Concurrency is handled by serialising per directory object, not by optimistic locking. The reason is that the client will not resolve a version conflict for you.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why `PATCH` and not `PUT`.** `PUT` replaces the whole resource. So any attribute the client leaves out is semantically deleted. That means a client that does not send every attribute silently destroys data. `PATCH` sends only what changed. That is safer, and it is also what Entra ID actually prefers to send. So `PATCH` is the path that carries almost all real traffic, and it is the one worth building carefully.

**The three operations, and where each goes wrong.**

- **`replace` with no path.** The value is an object, and its keys are merged into the resource. The common mistake is to treat it as a full replacement.
- **`replace` with a simple path.** `{"op":"replace","path":"active","value":false}` is the disable path. So it is the most security-relevant single message the service receives.
- **`add`.** On a single-valued attribute it behaves as replace. On a multi-valued attribute it *appends*. The classic bug is to implement `add` as assignment for both. Then a user's second email address overwrites the first.
- **`remove`.** It requires a path. On a multi-valued attribute, the path can carry a filter: `path: members[value eq "abc"]`. Entra's default request puts `members` in the path and the member in `value` instead. So the implementation needs a small filter parser, not a dictionary lookup, and it must read `value` as well. Treating `members` as a scalar and clearing the whole collection is how a single group-membership removal empties a care team.

**The details that are easy to miss.**

- **Attribute names are case-insensitive** per the specification. If you match them case-sensitively, you get intermittent failures that look random.
- **`externalId` is the client's identifier and `id` is yours**, and they are not interchangeable. Here the clinician row carries both, `entra_object_id` and `scim_external_id`, and each is unique. The reason is that the directory's object identifier is the stable join key, and the SCIM identifier is what appears in request paths.
- **Type coercion.** Values that arrive as a string where the schema says boolean are a known class of odd client behaviour. Coerce deliberately. Reject what you cannot interpret, instead of treating a truthy string as true.
- **`active: false` is a soft delete**, and it is the deprovisioning signal. If you treat it as an ordinary attribute update and not as a lifecycle event, access continues after employment ends. Here it maps to closing every open care relationship for that clinician **in the same transaction**. That is the whole point of the integration.
- **Return the updated resource**, or `204` consistently. Set `ETag` if you claim to support versioning. Claiming versioning support in `ServiceProviderConfig` and then ignoring `If-Match` is worse than not claiming it.
- **Error bodies matter**, because the client branches on them. A `409` for a duplicate `userName`. A `400` with a `scimType` of `invalidValue` for a malformed patch. A `404` for an unknown identifier. A generic `500` for a bad request makes the client keep retrying it for weeks.

**Concurrency, which is the second half of the question.** Two updates for the same user can arrive at the same time: a role change and a disable, or a retry that overlaps the original. Last-write-wins on the whole row is wrong here. If an in-flight role update overwrites a disable, an account that should be closed is open. That is a security failure, not a data-quality one.

Optimistic concurrency via `ETag`/`If-Match` is the specification's answer. In this case it is the wrong tool, because the client is not going to re-read and merge on a `412`. It will escrow the record and retry it later, if at all. So this design serialises instead. It uses a Redis lock keyed on the directory object identifier (`lock:scim:{entra_object_id}`), with a short expiry, held for the duration of the operation. Concurrent updates for *one* user queue. Updates for different users run fully in parallel, so the throughput cost is nothing at this volume. A short expiry matters, because a lock that outlives a crashed pod blocks that user's provisioning until it expires.

Underneath the lock, the operation is still idempotent and still transactional. The patch is applied, and any lifecycle consequence (closing care relationships) commits with it. So a redelivery after a lock expiry converges instead of being applied twice.

**And the constraint that keeps the blast radius small.** This service writes the identity schema only: clinician rows, care-team membership, and the care relationships that a deprovisioning closes. It never touches the record, diary or content schemas. That is what makes a bug here an identity problem, not a clinical-record problem. It is also the reason the extraction was defensible at all.

</details>


---

### SEC-09. Entra ID is the only client of your SCIM service. What does it actually do that the specification does not require, and what breaks if you implement the specification literally?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It matches existing users by issuing a filtered `GET` before it decides whether to create a user. So if you do not implement filtering on the matching attribute, every cycle creates duplicates instead of updating. It runs a full initial cycle, and then incremental cycles on a schedule measured in tens of minutes. It escrows individual failures and retries them with backoff. And after sustained failures, it puts the whole job into quarantine. If you implement the specification literally and test only against your own client, you discover all of that in production.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it does that the specification does not require.**

- **It discovers your capabilities and believes you.** It reads `ServiceProviderConfig`, and on some configurations also `Schemas` and `ResourceTypes`. If you advertise support for something you have not implemented (`PATCH`, filtering, sorting, `ETag`), it uses a path that then fails. The honest move is to advertise exactly what works.
- **It matches before it writes.** The provisioning cycle asks "does this user already exist" with a filtered query on the matching attribute. Typically that query is `GET /scim/v2/Users?filter=userName eq "someone@trust.example"`. If filtering is not implemented, or returns everything, the match fails and the client concludes the user is new. The result is duplicate accounts on every cycle instead of a visible error. That failure is silent and cumulative, and it is exactly the sort of failure this pipeline exists to prevent. Filtering is not optional in practice, even though the specification treats much of it as optional.
- **It prefers `PATCH` over `PUT`**, so `PATCH` carries the real traffic.
- **It disables rather than deletes.** The normal lifecycle signal for a departing clinician is `active: false`, not `DELETE`. A hard delete arrives only in narrower circumstances. An implementation that handles only `DELETE` as deprovisioning will miss every disable. It will deprovision a deleted user only when the hard delete arrives, which by default is 30 days later.
- **It runs an initial cycle, then incremental ones**, and the incremental interval is measured in tens of minutes, not seconds. That interval dominates the end-to-end deprovisioning latency. The latency is a separate question, worth its own answer.
- **It escrows failures and retries them.** A record that fails is retried on later cycles, with decreasing frequency, and it is eventually abandoned. So a transient bug does not lose the change immediately. But a persistent bug loses it quietly, weeks later, with nobody watching.
- **It quarantines the job.** Sustained failures, most often authentication failures, put the whole provisioning job into quarantine. After that, the job retries on a much slower schedule. The important operational consequence is this: **provisioning can stop entirely while every dashboard on our side looks perfectly healthy**. The reason is that a service that receives no requests reports no errors.
- **It respects throttling.** It handles a `429` with `Retry-After` properly. That means rate limiting this endpoint is safe. Rate limiting is also worth having, because an endpoint that can disable accounts should not be unbounded.
- **It sends attributes shaped by the tenant's mapping configuration**, not by your schema. Someone in the directory team can change a mapping and so change what arrives, with no code change on either side.

**What breaks if you implement the specification literally.** You get duplicates from missing filter support. Deprovisioning misses every disable, because only `DELETE` was handled. Retry storms come from returning `500` on malformed input that the client will never fix. An integration quarantines because a credential expired and nobody noticed. And multi-valued attributes get corrupted because `add` was treated as assignment.

**So how do you test it when the client is a product you do not control?**

1. **A SCIM specification compliance suite** as the baseline. It catches the protocol-level mistakes cheaply.
2. **Contract tests against captured real payloads.** Record what the tenant actually sends for create, update, disable, group add and group remove. Replay those payloads as fixtures. This is by far the highest-value suite, because it tests the client you actually have, not the one the specification describes.
3. **A staging tenant doing a real provisioning cycle** before anything reaches production. Nothing else exercises the matching, escrow and quarantine behaviour.
4. **Integration tests against a real database**, because the lifecycle consequence is the part that matters: closing care relationships transactionally. A mocked repository would pass exactly that part while it is broken.

**And the monitoring that follows from all of the above.** The failure mode is silence, so the alerts cannot be error-rate alerts. What is needed is a *liveness* signal on the integration. It measures the time since the last successful provisioning request, and it alerts when that time exceeds a couple of cycles. Alongside it runs a periodic reconciliation that compares the directory's view with the local clinician table. So an account that is active here and disabled there is surfaced, not assumed impossible. In this design a SCIM sync failure is a paged alert, not a ticket. The reason is that a deprovisioning that did not land means that access which should have ended has not ended, and that is a security event.

</details>


---

### SEC-10. How do a clinician's roles and team memberships get from the directory into an authorization decision, and what happens when a user belongs to more than two hundred groups?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
They mostly do not travel in the token, and that is deliberate. App roles give coarse capability in the `roles` claim. Everything about *reach*, meaning which patients and which team, is resolved from the database on every request. The reason is that reach changes faster than a token lives. The two-hundred-group case is the reason to avoid group claims entirely. Past that limit, Entra omits the groups claim and substitutes an overage indicator that points at Microsoft Graph. So any design that reads groups from the token silently stops working for exactly the most senior users.

<details>
<summary><strong>Detailed answer</strong></summary>

**The three mechanisms, and what each is good for.**

- **Group claims.** The token carries directory group identifiers. These are opaque object identifiers, not names. Group claims are useful if the directory's groups genuinely are your authorization model. There are two problems. The identifiers mean nothing without a mapping you maintain. And the claim has a hard size limit.
- **App roles.** Roles are declared on the application registration, assigned to users or groups in the directory, and emitted in the `roles` claim. They are your vocabulary, not the directory's. They are limited to what you defined. And an administrator who assigns them makes a statement about *your* application, not about a mailing list. This is the better mechanism for capability. It is also what the role model here maps onto: clinician, care-team administrator, content author, content approver, platform operator.
- **Nothing in the token at all**, with the decision resolved server-side per request. This mechanism carries the important half of the model.

**The overage behaviour, precisely.** Past roughly two hundred groups in a JSON Web Token, Entra stops emitting the groups claim. The limits differ by token type, and they are lower for some flows. Instead of the groups claim, Entra includes an overage indicator, with a pointer to a Microsoft Graph endpoint that returns the full list. Any code doing `if "nurse-group-guid" in token["groups"]` now throws a key error. Or, far worse, it evaluates to false and denies a legitimate user. And it happens to the users with the most memberships. They tend to be the longest-serving and most senior clinicians. The workaround is to call Graph per request to resolve the real list. That adds a network round trip to every authorization decision. Both these designs refuse to do precisely that, because the latency budget rests on authorization needing no network call.

So the overage rule is not a corner case to handle. It is an argument against the mechanism.

**What this system actually does.** Capability comes from the role, and **reach comes from the database**. The question "may this clinician see this patient" is answered by a row-level security policy. The policy joins through the temporal care-relationship table, and it is evaluated inside the request transaction. That has three consequences worth saying out loud:

1. **Freshness.** A clinician removed from a care team loses reach on their very next query. There is no token refresh and no waiting fifteen minutes. If reach is in a token, access continues after the decision to revoke it, for as long as the token lives. That is unacceptable for a record where team membership is the access-control boundary.
2. **Size.** A clinician may follow hundreds of patients. That list can never be a claim, because tokens would be enormous and stale.
3. **Single definition.** Exactly one place defines the relationship. Both the record layer and the search layer derive scope from it. A copy carried in the token would be a second definition, and two definitions of an authorization fact is how they drift apart.

The membership *is* cached, but only for the duration of a single request. It is explicitly never cached for longer, because a stale authorization fact is a disclosure, not a slow page.

**Where directory groups are still useful.** Group-to-role assignment in the directory is a good administrative model. The hospital manages a group, the group is assigned an app role, and the role arrives in the token. That keeps the directory team's workflow intact, without making group identifiers part of the application's logic. Group *provisioning* over SCIM is also how care-team membership arrives here as data. That is the right place for it, because the membership then lives in the database where reach is evaluated, not in a claim.

**The general principle.** Put in the token what is stable for the token's lifetime and small enough to carry: who you are, which tenant, what kind of principal, what capability. Resolve everything volatile or large at request time, from the system of record. The test I would apply to any claim someone proposes adding is a question. If this changes one minute after the token is issued, what happens? If the answer is "they keep the access for fifteen minutes", it does not belong in the token.

</details>


---

### SEC-11. A clinician is deprovisioned in the hospital directory at nine in the morning. When exactly do they lose access, and what dominates that number?

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
Not immediately, and the part that dominates is not the one people expect. The access token's fifteen-minute lifetime is the small part. The directory's provisioning cycle, which takes tens of minutes, is what actually sets the number. But the honest answer is better than that arithmetic suggests, because a still-valid token gives almost nothing here. Reach is resolved from the database on every request. And the deprovisioning closes the care relationships in the same transaction. So the moment the SCIM call lands, the record goes empty, even for a token that has not expired.

<details>
<summary><strong>Detailed answer</strong></summary>

**The steps, and how much each one adds.**

1. **Directory change at 09:00.** Instant, and invisible to us.
2. **Waiting for the next incremental provisioning cycle.** Tens of minutes. **This dominates.** It is a schedule inside a product we do not control, and no amount of engineering on our side shortens it.
3. **The SCIM request arrives and commits.** Milliseconds. `active: false` maps to the clinician row and closes every open care relationship for that clinician in the same transaction.
4. **Their existing access token remains cryptographically valid** for up to its full fifteen minutes. Their session may also hold a refresh token.

Naively, that is a cycle plus fifteen minutes. In practice the fourth step mostly does not matter, and understanding why is the interesting part.

**Why the token lifetime is nearly irrelevant here.** The token establishes *who*, not *what they may reach*. Reach is a row-level security policy that joins through the temporal care-relationship range. The policy is evaluated inside each request's transaction, against the current state of the database. Step three closes those relationships. So the very next query from that still-valid token returns zero rows: not an error, but an empty record. The same scope is projected into the search index as a mandatory filter. That filter is derived from the caller's token and the current relationships. So search closes at the same moment, instead of becoming the way around it.

So the effective exposure window is step two, and the mitigations belong there, not in token lifetimes. That is a direct benefit of a design decision made much earlier: putting the authorization boundary in the database instead of in a claim. It is worth naming as such, because the alternative design would have had a genuinely fifteen-minute hole.

**What is left exposed, and I would state it openly.** Anything the token authorises that is *not* patient-scoped: reading their own profile, and endpoints gated by role alone. And the long-lived device connection path. The broker authenticates a connection, not each publish. So a connection established before the revocation persists until its maximum lifetime forces re-authentication. The design flags that gap explicitly instead of assuming it does not exist. And connection lifetimes are deliberately set shorter than the refresh window because of that gap.

**What to do when tens of minutes is not acceptable.** It depends entirely on why someone is being removed. Routine offboarding at the end of a notice period does not need to be fast. A suspension for cause does. For that, the answer is not to speed up the provisioning cycle. It is to have a second, immediate path:

- **Revoke the sign-in session in the directory.** This invalidates refresh tokens, so nothing new is issued. It does not retract the access token that is already issued.
- **A denylist consulted at validation time**, checked against a small, fast store. The marketplace does this for a suspended vendor. An event publishes the deactivation, and services consult a denylist of revoked token identifiers. A denylist is the general answer to the gap between "token issued" and "token should no longer work". The cost is a lookup on every request. That is why the denylist holds only the exceptions and not every principal.
- **Continuous Access Evaluation**, which exists for exactly this. It lets a resource reject a token in near real time on a critical directory event. It is worth knowing about. It is also worth being precise that a custom API has to participate in it. A custom API does not inherit it just by pointing at Entra.
- **An in-platform emergency disable** that does not wait for the directory at all. Set the clinician inactive and close their relationships now, and let the SCIM cycle reconcile later. Every operation here is idempotent. So an out-of-band disable followed by the directory's own disable converges instead of conflicting.

**And the detection that makes the whole thing trustworthy.** In this design a SCIM sync failure is a *paged* alert, not a ticket. That is exactly because the failure mode is silence. A quarantined provisioning job means that deprovisionings simply stop arriving, while every dashboard on our side looks healthy. There is a detection rule over the audit stream for a deprovisioning that did not close its care relationships. **SEC-09** has the liveness signal and the directory reconciliation that sit alongside that rule. Without those, the answer to "when do they lose access" would be "we believe within an hour". And belief is not a control.

</details>


---

### SEC-12. The SCIM endpoint can create and disable clinician accounts and is called by something outside your network. Threat-model it.

**Level:** Q3 — architectural · **Project:** cancer-support-platform

**Brief answer**
It is the highest-privilege external surface in the system, because it writes the table that authorization is derived from. The two worst outcomes are opposite. One is mass deprovisioning, which takes clinicians out of the record mid-consultation and is a patient-safety event. The other is unauthorised provisioning, which is an attempt to create a fake insider. The controls are a strong client credential with no shared secret, network restriction, strict separation from the patient plane, a volume circuit-breaker on destructive operations, and audit on everything.

<details>
<summary><strong>Detailed answer</strong></summary>

**The threats, ranked by what they actually cost.**

| Threat | Consequence | Control |
|---|---|---|
| Mass deprovisioning, malicious or from a mapping error | Clinicians lose the record mid-consultation. In a clinical setting this is a safety event, not an outage | Volume threshold on destructive operations, with human confirmation above it; audit and alert on the disable rate |
| Credential compromise, then unauthorised provisioning | An attacker tries to create a fake clinician account | Certificate or federated credential, no shared secret; network restriction; and the fact that a row alone grants nothing without a token issued by the directory |
| User enumeration through the filter endpoint | The staff directory of a hospital trust is itself sensitive | Authenticated caller only, rate limiting, uniform responses, audit on query volume |
| Injection through attribute values | Stored cross-site scripting, or a broken record downstream | Strict schema validation; unknown fields rejected, not silently accepted |
| Replay of a captured request | Duplicate or reverted lifecycle changes | Transport security, short-lived credentials, idempotent operations keyed on the directory identifier |
| Exposure of the endpoint on the patient plane | A patient-audience token reaching provisioning | Separate route and audience; never published through the patient-facing surface |
| Directory compromise upstream | Full access that looks legitimate | Accepted and stated; detection instead of prevention |

**Why the provisioning threat is less bad than it first looks, and why that is worth saying.** Writing a clinician row does not by itself grant access. Authentication still requires a token that the hospital's directory issued for that object identifier. And reach still requires an active care relationship. So an attacker who holds only the SCIM credential can create a row that nobody can authenticate as. To get an actual session, they would need to compromise the directory too. At that point they have a legitimate identity, and this endpoint is not their problem. That is defence in depth genuinely working. It is also an argument for keeping the authorization boundary in the database, not in provisioning.

**That is also why mass *deprovisioning* is the more serious direction.** It needs no second compromise to do damage. It needs only a single credential, it is fast, and it looks exactly like normal traffic. Its effect is immediate, because reach is resolved per request. A bad attribute mapping, configured by a well-meaning administrator, produces the same outcome as an attacker. So the control I would insist on is a rate threshold on the disable path. Beyond some number of deprovisionings in a window, the service stops and requires a human decision. It is mildly annoying during a genuine bulk offboarding. And it is the difference between an incident and a catastrophe.

**The controls, concretely.**

- **The directory is the only authorised caller.** It authenticates with its own client credential, and the endpoint is network-restricted. I would push for a certificate or a federated credential over a shared secret. A long-lived secret in a directory configuration is a credential nobody rotates. Its expiry is also a common cause of a silently quarantined provisioning job.
- **Strict input validation.** Every request body is a typed model, so unknown fields are rejected, not silently accepted. A tenant-side mapping shapes the attribute set that arrives here, and someone can change that mapping without touching our code. That makes validation a genuine boundary, not a formality.
- **Rate limiting**, which is safe to apply because the client honours throttling responses correctly.
- **Everything is audited**: actor, operation, target, and the trace identifier that joins the event to the rest of the telemetry. The lifecycle consequence is audited as its own event, not folded into a generic update.
- **Detection rules that name specific misuse**, not generic anomalies. The rules cover a deprovisioning that did not close its care relationships, an unusual volume of disables, and provisioning activity outside the directory team's normal pattern.
- **Deployment must not drop requests.** This service uses a rolling update precisely because it has an external caller and idempotent operations. The client's escrow-and-retry behaviour is the safety net. And that safety net works only because every operation is idempotent.
- **Blast radius is limited by schema ownership.** This service writes the identity schema and nothing else. A compromise here cannot rewrite a prescription.

**What I would state as accepted rather than solved.** The hospital directory becomes a trust dependency of the platform. If someone compromises the directory, platform access follows, and no control on our side prevents that. The answer is detection: out-of-team access rules, volume anomalies, and break-glass review within twenty-four hours. The answer also includes the fact that every patient-data access writes an immutable audit row in the same transaction as the access. So a legitimate-looking insider leaves a complete trail. Being explicit about where prevention ends and detection begins is more useful than implying that the controls are stronger than they are.

</details>

---

## 4. Secrets and data protection

---

### SEC-13. Threat-model an endpoint that accepts file uploads from an untrusted client. What are you defending against, and in what order do the controls go in?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace, cancer-support-platform

**Brief answer**
Against four categories. First, the file harming the server that receives it. Second, the file harming whoever downloads it later. Third, the upload path being used to exhaust resources. Fourth, the storage location being used to reach things it should not. The controls go in from the outside inward. Authenticate and authorise. Cap size and rate before reading a byte. Validate the type by content, not by what the client claimed. Quarantine and scan before the file is addressable. And serve it back from an origin where a malicious file cannot do damage.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I am defending against, named concretely.**

- **Malware distributed through us.** A vendor uploads a datasheet, a retailer downloads it, and the platform was the delivery mechanism. For the platform's reputation, this is the worst outcome, even though the platform itself was never compromised.
- **Stored cross-site scripting.** An SVG or [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers") file served inline from the application's own origin executes with that origin's privileges. It can read the session and act as the user. This is the most likely real exploit, and the least dramatic-sounding one.
- **Parser exploits and decompression bombs.** Image and document libraries are large C surfaces. A crafted file can crash or exploit the process that parses it. And a zip bomb or a pixel-flood image exhausts memory during thumbnailing.
- **Server-side request forgery and path traversal.** A filename with traversal sequences, or an ingestion step that fetches a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") the file specifies.
- **Resource exhaustion.** Very large files, many concurrent uploads, or many small ones that occupy the processing pool.
- **The upload being a data-exfiltration or storage-abuse channel**: using the platform as free file hosting, or writing to a prefix that another tenant reads.
- **[XML](https://www.w3.org/XML/ "Extensible Markup Language — Markup format for structured, machine and human readable documents") External Entity and formula injection** in the structured-import case. There, the "file" is a spreadsheet or an XML document that a parser will interpret.

**The controls, in the order they go in.**

1. **Authenticate and authorise first.** Anonymous upload is a different and much harder problem. Both these systems accept uploads only from an authenticated principal scoped to an organisation, and the quota is per organisation.
2. **Limit it before reading it.** A declared size in the upload intent. A hard cap enforced at the gateway and the web application firewall. And a per-tenant rate quota: five import jobs per vendor per day in the marketplace. Reject at the edge. A request rejected after it has used a worker has already cost what you were protecting.
3. **Keep the bytes off the application entirely.** This is the most effective structural decision. The cancer platform issues a scoped, short-lived Shared Access Signature ([SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview "Time-limited token granting scoped access to an Azure Storage resource")), so the client uploads directly to blob storage. Multi-megabyte scans never touch the pods that serve a clinician's timeline. That removes memory exhaustion, parser exposure and bandwidth contention from the API tier in one move. And the metadata write stays transactional, because the intent is recorded before the bytes arrive.
4. **Land it somewhere it cannot be reached.** Uploads go to a quarantine container, not to the served location. In the cancer platform's design, a document row is not visible to any client until its scan state is clean. The file is promoted to the documents container only after `fn-blob-ingest` reports a clean scan. **An unscanned file is never addressable**. That property is what makes the whole thing defensible, instead of a race.
5. **Validate type by content, not by claim.** Content-type headers and file extensions are supplied by the client. Sniff the magic bytes. Enforce an allowlist, never a denylist. Reject anything that does not match what was declared. An allowlist fails closed on a format nobody thought about.
6. **Scan, then transform.** Run malware scanning, then re-encode instead of passing the original through. The marketplace re-encodes images in `fn-media-process`. As a side effect, that strips metadata and defeats most polyglot and parser-exploit files. Do the parsing in an isolated worker with resource limits and time limits, never in the request path. The reason is that a decompression bomb should kill a bounded job, not a web pod.
7. **Strip metadata.** Images carry location and device data. Documents carry author and revision history. For patient-uploaded documents in a clinical system, that is a privacy obligation, not a nice extra.
8. **Control the download path. This is where the stored-[XSS](https://owasp.org/www-community/attacks/xss/ "Cross Site Scripting — Attack that injects malicious script into content viewed by other users") defence actually lives.** Use content-addressed paths with a generated identifier, never the client's filename. Send `Content-Disposition: attachment`, so nothing renders inline. Send a strict `Content-Type` from your own detection, not the client's. And there is the control people miss: **serve user-supplied files from a separate hostname**. Then even a successful stored XSS executes in an origin that holds no session and can reach nothing. The marketplace does exactly this. Datasheets go out through a dedicated download hostname, so no vendor-supplied file is ever served from the origin that hosts the admin console.
9. **Authorise the download too.** Use short-lived, scoped read tokens, not unguessable URLs. An unguessable URL is a bearer token with no expiry and no revocation.
10. **Audit and observe.** Record who uploaded what, when, and what the scan concluded. Alert on scan failures and on unusual volume per tenant.

**The ordering principle behind the list.** Cheap and certain checks go before expensive and fallible ones. A size cap costs nothing and a malware scan costs seconds, so the cap goes first. Also, every control assumes that the one before it failed. That is why "unscanned files are unreachable" matters more than any individual scanner. It is a structural property, not a detection.

</details>


---

### SEC-14. How do you handle secrets and credentials in an application and its pipeline?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By having as few as possible. With workload identity federation, a service authenticates to cloud resources as itself, with no stored credential. That removes the whole class of problem for most of them. What genuinely must be a secret lives in a managed store. It is injected at runtime, and it is never in an image or a repository.

<details>
<summary><strong>Detailed answer</strong></summary>

**Eliminate first.** The best secret is one that does not exist. Take a federated workload identity: a cluster service account that the cloud identity provider trusts, mapped to a managed identity per service. With it, database, storage and message access happen with no connection string and no stored key anywhere in the cluster. The same applies to the deployment pipeline. It authenticates by federation, instead of holding a long-lived service principal secret. For the majority of what used to be secrets, that removes rotation, leakage and expiry as concerns.

**What remains**: third-party credentials, signing keys, and anything the platform does not federate. These secrets live in a managed secret store, referenced by identity instead of copied. They are injected at runtime as environment values or mounted files. They are never baked into an image, because an image is distributed and cached and lives longer than anyone expects.

**In the pipeline.** Masked variables, scoped to protected branches, so a fork or an unprotected branch cannot read them. No secret is ever echoed, including in a debug run. And note that a value in a variable can still leak through a command that prints its own arguments, or through a tool's verbose output. Masking does not always catch those leaks. Applies run only from the default branch, under the federated identity.

**Detection, because prevention fails eventually.** A secret scanner in pre-commit and as a pipeline gate. And a scan of history when you adopt the scanner on an existing repository. A committed secret is compromised the moment it is pushed. So the response is always to rotate first and then clean the history. Removing the secret without rotating it is only for show.

**Rotation.** Anything that cannot be federated has a rotation procedure that has actually been executed. The failure mode of an untested rotation is this: you discover a consumer nobody knew about at the moment the old credential stops working. Rotate with an overlap window, and make the overlap window longer than any cache that holds the credential. That is the same lesson as the signing key rotation, in a different form.

**Where I would want a review.** Any change to identity configuration or role assignment. Role assignments are declared in infrastructure code specifically so that a widened permission is a reviewable diff, not a click nobody sees. I would flag any such change for someone else to look at, instead of treating it as ordinary work.

</details>


---

### SEC-15. Personal data is flowing through logs, traces, error reports and a message payload. How do you keep it out of the places it does not belong, and how would you prove it is out?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Mark the sensitive fields once, on the model that defines them. Then let every output path read that same mark: log formatter, trace attributes, error serialiser and message envelope. So there is one owner of "this field is sensitive", not four. Then make regression impossible. Add a pipeline check that fails the build when a log call passes a model carrying a sensitive field. And add a periodic scan of what actually landed in the log store. Proving it means sampling the destinations, not reading the code.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four leaks, one at a time, because each needs a different mechanism.**

*Logs.* The obvious one, and the easiest to fix structurally. The rule in the cancer platform is absolute: **no clinical free text, no symptom values, no document contents are ever logged.** Every line is JSON. It carries `trace_id`, `span_id`, `service`, `module`, `actor_kind` and, where applicable, a patient identifier. So a line holds identifiers, never content. A redaction filter driven by the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") model drops known-sensitive fields at the formatter. That is the right layer, because it catches every call site, including the ones in libraries. The marketplace has the same rule for message bodies, tokens and client secrets.

*Traces.* Easier to forget, and just as exposed. Auto-instrumentation captures database statement text and [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") request attributes. So a statement with a bound literal, or a query string with an email address, is now in the tracing backend. The tracing backend frequently has different retention and different access control from the log store. Disable statement-parameter capture. Allowlist span attributes instead of denylisting them. And apply the same redaction to the exporter.

*Error reports.* The worst offender, because the whole point of an error report is to capture state. A framework validation error will simply include the rejected value. An exception handler that logs the request body defeats every other control at once. So never serialise a request body into an error. Report the field name and the rule that failed, never the value. Both these systems use problem-detail bodies, and the discipline is that `detail` is a description, not a dump.

*Message payloads.* The one people forget entirely, because a queue feels internal. It is not internal. It is a store with its own retention, its own dead-letter queue that someone will read during an incident, and its own access control. The pattern I prefer is a thin event that carries identifiers, and a consumer that reads what it needs under its own authorisation. I prefer that to a fat event that carries the data. The cancer platform's design does the strong version of this at the model boundary. The [NLP](https://en.wikipedia.org/wiki/Natural_language_processing "Natural Language Processing — Computational techniques for analyzing and generating human language") service receives diagnosis code, treatment line, stage and locale for page composition. It does *not* receive the patient's identity, name or contact details. Extraction calls that must see note text receive the text and a correlation id, never the patient identifier. This is data minimisation applied to an internal hop, which is where it is usually skipped.

**Making it one owner rather than four.** What makes this maintainable is one property. "Sensitive" is declared once, on the Pydantic model that defines the field. The log formatter, the span exporter, the error serialiser and the event envelope all read that same declaration. Four independent redaction lists are four things that drift. And the one that drifts is the one you find out about from a regulator.

**Keeping it out permanently.** A rule enforced by review is a rule that holds until a busy week. The cancer platform makes it a build gate: **a continuous-integration check fails the build if a log call passes a model containing a field marked sensitive.** That turns a convention into a control. Alongside it, a linter bans direct formatting of request bodies into log calls. And span attributes use default-deny allowlists, because a denylist is a list of the leaks you thought of.

**And the distinction that keeps the whole design honest.** Audit is a database table, never a log stream. Logs are for operators. Audit is for the regulator. If you treat them as one thing, log retention policy silently becomes audit policy. Treating them as one also puts two things in the same pipeline. One is the thing you most want to redact aggressively. The other is the thing you must retain immutably for seven years. That is an impossible position. Separating them lets logs be strictly minimal.

**Proving it is out.** Code review proves intent. Only the destination proves outcome.

1. **Sample the log store and search it.** Pattern-match for the shapes that should never appear: identifier formats, email addresses, free-text fields, token prefixes. Run this as a scheduled job with an alert, not as a one-off audit. This is the check that finds the leak nobody anticipated. By definition, that is the leak the allowlist missed.
2. **Do the same in the tracing backend and the error reporter.** They are different systems, with different teams and frequently different retention. A control verified in one and assumed in the others is unverified.
3. **Inspect a dead-letter queue's contents** as part of the exercise, since that is a message store with a long tail and human readers.
4. **Test the redaction with a known-positive and a known-negative.** Log a model with a sensitive field populated, and assert that the field is absent from the output. Log a model without one, and assert that the surrounding structure is intact. A redaction filter that has never been shown to redact is an assumption. And the failure mode of a broken filter is silence, which looks exactly like success.
5. **Verify that the build gate can actually fail.** Introduce a violating log call on a branch, and confirm that the pipeline goes red. A gate that has only ever passed has not been shown to do anything.
6. **Check retention and access on each destination**, because "it is only in logs" is not a defence if the logs are retained for two years and broadly readable. Check residency too. For the cancer platform, all resources and all backups sit in a single region, with no cross-border transfer. A telemetry backend outside that region would breach residency as surely as a database would.
7. **Prove that deletion works end to end.** A data subject access request or an erasure request has to reach every destination. A personal identifier sitting in a log store that nobody enumerated is the reason erasure requests are hard. The right answer is usually that logs carry pseudonymous identifiers only, so there is nothing to erase there. But that has to be true, not assumed.

**One honest note on scope.** Erasure and retention genuinely conflict. In both these systems, retention wins for a defined class of data. A medical record is retained under health-records law. And a vendor's record of a commercial negotiation is not the individual's to delete. Those positions are stated to the user at consent, and they are defensible. What is not defensible is promising deletion and quietly not performing it. Keeping personal data out of the peripheral systems in the first place is what makes the remaining conflict small enough to explain.

</details>

