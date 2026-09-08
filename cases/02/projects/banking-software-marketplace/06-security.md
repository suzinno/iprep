# Security & Compliance

*Retail Software Aggregation Platform*

## Table of Contents

- [Threat Model](#threat-model)
- [Identity & Access](#identity--access)
- [Authorization: Account Type, Role, and Tenant Scope](#authorization-account-type-role-and-tenant-scope)
- [Data Protection](#data-protection)
- [Secrets and Cloud Identity](#secrets-and-cloud-identity)
- [Regulatory & Compliance](#regulatory--compliance)
- [Perimeter Defense](#perimeter-defense)
- [Audit](#audit)

## Threat Model

The dangerous adversaries here are authenticated and legitimate. A three-sided marketplace puts competitors on the same platform, and the highest-value attacks need no exploit at all — only an authorization gap.

| Threat | Actor | Consequence | Control |
|---|---|---|---|
| A vendor enumerates the retailer directory to build a sales list | Authenticated vendor | The buyer side leaves; the marketplace dies | No vendor-side API returns `retail_group`, `store` or `retailer_user` data. A vendor learns a retail group's identity **only** through a `connection_request` that group initiated |
| A vendor reads a competitor's draft listings or connection volume | Authenticated vendor | Competitive intelligence, loss of vendor trust | Every vendor-scoped query is filtered on the token's `org_id`; drafts are never projected into `product_listing_facets` |
| A retail group reads another group's shortlists | Authenticated retailer | Leaks sourcing strategy | Same org-scope filter on `retail_group_id` |
| Connection-request spam to harvest vendor contacts | Authenticated retailer | Vendors disengage | Per-group quotas on `POST /v1/connections`, described under Perimeter Defense |
| Catalog scraping for a rival marketplace | Any authenticated account | Loss of the platform's core asset | Per-subject rate limits, `total_estimate` caps, no bulk export endpoint |
| Malicious upload in a vendor import or datasheet | Authenticated vendor | Stored XSS, malware served to retailers | Content-type allowlist, size caps, `fn-media-process` re-encodes images, datasheets served from `blob-media` with `Content-Disposition: attachment` through a dedicated download hostname on Front Door, so no vendor-supplied file is ever served from the origin that hosts the admin console |
| Stolen refresh token | External | Account takeover | Rotation with reuse detection (`03-data-modeling.md`) |

**Every one of these is an authorization problem, not a network problem.** That ordering drives the rest of this file: tenant scoping gets the most rigour, perimeter controls are competent but conventional.

## Identity & Access

`identity-service` is the OAuth2 authorization server; no other service authenticates a user.

| Grant | Used by | Details |
|---|---|---|
| Authorization code + PKCE | Marketplace web app, admin console SPA | Public clients, no client secret. Refresh token in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie scoped to the API origin |
| Client credentials | Vendor system integrations pushing catalog data | Confidential clients; `client_secret_hash` in `oauth_client`, Argon2id |
| Refresh token rotation | All | One-time-use `jti`; presenting a revoked `jti` revokes the entire chain and raises an alert |

**Tokens.** RS256 JWT access tokens, **15-minute** lifetime, signing key in Key Vault with 90-day rotation and both keys published at `/.well-known/jwks.json` through the overlap. Claims: `sub`, `act` (`vendor` \| `retailer` \| `platform`), `org_id`, `roles[]`, `scopes[]`, `jti`, `exp`. Refresh tokens live 30 days with rotation.

Verification happens twice, deliberately. APIM validates the signature, `exp` and audience at the edge, so a forged or expired token never reaches the cluster. Each service validates again locally against the JWKS cached in `redis-cache` and then applies its own scope and tenant rules — the edge is a filter, never the authority. **Neither check makes a network call per request**, which is the assumption the latency budget in `04-deep-dive.md` rests on. Token revocation is therefore bounded by the 15-minute access-token lifetime; the refresh chain is revoked immediately, and for the one case where that is not good enough — a suspended vendor — `identity-service` publishes `identity.user.deactivated` and services consult a small Redis denylist of revoked `jti` values.

> **Verify Before Build:** APIM's `validate-jwt` policy caches the JWKS on its own schedule, independent of the `authz:jwks` key in `redis-cache`. During a signing-key rotation the two caches can disagree, and tokens signed with the new key may be rejected at the edge while the cluster accepts them. Confirm the APIM `open-id-config` refresh interval on the target tier and make the key-overlap window strictly longer than it before the first rotation.

## Authorization: Account Type, Role, and Tenant Scope

Three checks, in order, on every request. The brief's requirement — that catalog and connection APIs stay behind the right account type — is the first of them, and alone it is not enough.

1. **Account type (`act` claim).** Coarse, enforced by a FastAPI dependency on every router. `/v1/vendor/*` requires `act = vendor`; `/v1/retailer/*` requires `act = retailer`; `/v1/admin/*` requires `act = platform`. A retailer token cannot reach a vendor route regardless of its scopes.
2. **Role → scope (RBAC).** Roles map to scopes at token issue: a vendor `viewer` receives `vendor:read` only; a `category_manager` receives `retailer:read` and `connection:write` but not `retailer:admin`, so it cannot add stores or change group membership.
3. **Tenant scope (ABAC).** Every query touching an org-owned table is filtered on `org_id` from the token. This is enforced in **one** place — a SQLAlchemy session-level filter applied by the repository layer — rather than in each endpoint, because a per-endpoint check is a control that works until the day someone adds an endpoint. Platform admins bypass it explicitly and every bypass writes an `audit_event`.

**Row-Level Security in PostgreSQL is deliberately not used as the primary control.** It is the stronger mechanism, and it is rejected because `catalog-service` reads a replica through a pooled connection with a shared role; setting a per-request session variable through a connection pool is exactly where RLS silently becomes a no-op or leaks across pooled sessions. Getting that wrong is worse than not relying on it. The compensating control is that tenant filtering lives in one auditable layer with a test that asserts cross-tenant reads return empty for every org-owned repository method.

## Data Protection

**In transit**

| Path | Protection |
|---|---|
| Client → Front Door → APIM | TLS 1.3, HSTS with preload, TLS 1.2 as the floor for older vendor integrations |
| APIM → AKS ingress | TLS 1.3 over the Azure backbone, ingress certificate from Key Vault |
| Service ↔ service inside the cluster | Plaintext HTTP within one namespace, constrained by a **default-deny NetworkPolicy** with explicit allows per pair. See the trade-off below |
| Service → `postgres-core`, `mongo-catalog`, `redis-cache`, `redis-broker` | TLS required, certificate verification on, private endpoints only — no data store has a public IP |
| Service → Service Bus, Blob, Key Vault | TLS 1.2+ over private endpoints, workload identity, no connection strings |

**mTLS between services is not implemented, and that is a stated choice.** Doing it properly means a service mesh, and a mesh's operational cost — sidecar lifecycle, certificate rotation, a new failure mode in every request path — is disproportionate for nine workloads in one namespace on one cluster. The compensating controls are default-deny NetworkPolicy, private endpoints on every data store, and the fact that no untrusted workload runs in the cluster. **The trigger to revisit is concrete: a second tenant-facing workload in the cluster, a third-party or customer-supplied container, or a compliance requirement naming encryption-in-transit between internal services.** Any of those, and Linkerd goes in.

**At rest**

- Azure Storage Service Encryption and Transparent Data Encryption, **AES-256**, on `postgres-core`, `mongo-catalog`, `blob-media` and `redis-cache`, with customer-managed keys in Key Vault (auto-rotating annually).
- **No payment instrument, no bank detail and no government identifier is stored anywhere in the system.** `billing_account.psp_customer_ref` and `billing_charge.psp_invoice_ref` are opaque references to the external PSP.
- **Application-level field encryption is not used, including on `connection_message.body`.** Message bodies are commercial correspondence between two consenting organisations, and encrypting them would defeat the operator's ability to moderate abuse and investigate disputes — a real product requirement. The protection is access control plus volume encryption. If a customer contract later requires message confidentiality from the operator, that is an envelope-encryption project with a real key-management design, not a column type change.
- **Backups inherit encryption and residency**: 35-day point-in-time restore on Postgres, daily Mongo snapshots to a geo-redundant EU-resident account.

## Secrets and Cloud Identity

- **No static credentials in the cluster or in CI.** AKS workload identity federates a Kubernetes service account to an Azure managed identity per service; GitLab CI authenticates to Azure by OIDC federation. `postgres-core` and `mongo-catalog` use Entra ID authentication where the driver supports it, with Key Vault–stored credentials as the fallback.
- **Least privilege per workload.** `catalog-service` gets read on its Key Vault secrets and nothing on Service Bus. Only `vendor-service` and `catalog-import-worker` may write the `imports/` and `listings/` blob prefixes. Only the outbox relay may send on `sb-catalog-events` and `sb-connection-events`.
- **Terraform applies from CI only**, with a single deploy identity holding no standing data-plane rights to production databases; a human requiring production data access goes through a time-bound Privileged Identity Management elevation that writes an audit record.
- **Nothing in this section is enforced by code review alone.** Role assignments are Terraform resources, so a widened permission appears as a reviewable diff.

> **Deep Dive Reference:** The blast radius of the CI deploy identity is the single largest concentration of privilege in this design — it can apply Terraform across the whole subscription. Splitting it into a plan-only identity for merge requests and an apply identity gated on protected-branch pipelines, and separating the network and data-plane modules into their own state with their own identity, is worth designing before the first production apply rather than after an incident.

## Regulatory & Compliance

**GDPR is the governing framework.** The personal data held is limited and occupational — names, work email addresses, roles, and the message bodies staff write to each other. There is no consumer data, no special-category data, and no profiling.

| Obligation | How it is met |
|---|---|
| Lawful basis | Contract for platform users; legitimate interest for marketplace operation, with a documented balancing test |
| Data minimisation | No personal data in `product_listing_facets` or in `mongo-catalog`; vendor listings describe products, not people |
| Residency | Single EU region for all data stores and backups; `blob-media` and Service Bus in the same region |
| Right of access | An export endpoint assembles a subject's profile, audit trail and authored messages from `postgres-core` |
| **Right to erasure** | **The one genuine conflict, resolved deliberately.** A departing category manager's identity is erased — `auth_subject`, `email` and name are tombstoned, refresh chains revoked, `audit_event` actor pseudonymised. **Message bodies they authored are retained** and re-attributed to a deleted-user tombstone, under Article 17(3)(e), because a vendor's record of a commercial negotiation is not the individual's to delete. *The cost of this choice:* an erasure is not total, the retained text may still identify its author from context, and the position must be stated in the privacy notice and defensible to a supervisory authority. The alternative — deleting the messages — destroys the counterparty's business record and is the worse failure |
| Processor obligations | The PSP, the email provider and Azure are documented sub-processors with data processing agreements |
| Retention | Enforced by the partition-detach and TTL mechanisms in `03-data-modeling.md`, not by policy documents |

**PCI-DSS scope is deliberately kept at SAQ-A.** Vendor subscription payments are collected through the PSP's hosted fields; no cardholder data enters the platform's network, storage or logs. This is why `01-requirements.md` excludes payment processing between retailer and vendor: the moment the platform intermediates a transaction, its compliance scope changes category. **No financial-services regulation applies** — the platform lists software, it does not provide a payment service or hold funds, so PSD2 and equivalent regimes are out of scope. That conclusion depends on the scoping decision in `01-requirements.md`; if the marketplace's buyers were regulated financial institutions, this section would need a lawyer, not an architect.

## Perimeter Defense

- **WAF** — Azure Front Door Standard with the managed OWASP rule set in prevention mode, plus custom rules for the upload endpoints. Flagged in `02-high-level-design.md` as an addition beyond the brief's literal stack, because APIM alone provides no WAF.
- **DDoS** — Azure DDoS Network Protection on the Front Door public endpoint; L7 absorption at the edge, so no volumetric traffic reaches AKS.
- **Rate limiting, in two layers with different jobs.**
  - *Infrastructure*, at APIM: per-subscription-key quotas and a per-IP burst limit, protecting the platform from volume.
  - *Business*, in the services against `redis-cache` (`rl:*` keys): a token bucket per `org_id` and per `sub`. The limits that matter are not request rates — **20 connection requests per retail group per day**, **200 listing writes per vendor per hour**, **5 import jobs per vendor per day**, and a per-vendor cap on catalog detail fetches that makes systematic scraping slow enough to notice. These are marketplace-integrity controls; an IP-based limit does not express them.
  - When `redis-cache` is unavailable, business rate limiting **fails closed for writes and open for reads**, matching the degradation described in `04-deep-dive.md`.
- **Input validation** — every request body is a Pydantic model, so unknown fields are rejected rather than absorbed. Vendor `attributes` are additionally validated against the category's `facet_schemas` document, which is the only untyped input the system accepts.
- **Egress control** — a default-deny egress NetworkPolicy; only the PSP, the email provider and Azure service endpoints are reachable from the cluster.
- **Supply chain** — dependencies pinned by hash, images pinned by digest, CVE scanning in the pipeline gate (`05-reliability.md`), and base images rebuilt weekly.

## Audit

`audit_event` (`03-data-modeling.md`) records every state transition on vendors, listings, retail groups, stores, connections and billing, plus every admin action and every tenant-scope bypass. It is append-only: the application role holds `INSERT` and `SELECT` and no `UPDATE` or `DELETE` grant, and monthly partitions are archived to immutable blob storage.

Writes are **asynchronous, off the outbox**, never synchronous in the request path. This is not an optimisation but a constraint the rest of the architecture imposes: a synchronous audit write on read would make replica-served catalog reads impossible, since a replica cannot write. The cost is that an audit record can trail its event by seconds and, in a total outbox loss, could be missed — accepted because `outbox_event` and the state change commit in the same transaction, so the record of what happened is durable even when the audit row is not yet written.
