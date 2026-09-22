# Security & Compliance

**Tender Platform for a MENA Police Department**

## Table of Contents

- [Threat Model](#threat-model)
- [Identity & Access](#identity--access)
- [Authorization: Role, Tenant, Assignment, Recusal](#authorization-role-tenant-assignment-recusal)
- [Sealed Bid Custody](#sealed-bid-custody)
- [The Model Egress Boundary](#the-model-egress-boundary)
- [Data Protection](#data-protection)
- [Secrets and Cloud Identity](#secrets-and-cloud-identity)
- [Regulatory & Compliance](#regulatory--compliance)
- [Perimeter Defense](#perimeter-defense)
- [Audit](#audit)

## Threat Model

The adversaries worth designing against, in the order they matter for a procurement platform.

| Threat | Actor | Design response |
|---|---|---|
| Reading a competitor's sealed bid before the deadline | A vendor, or an insider acting for one | Envelope encryption with grant-based key release; no principal holds read access to the `bids/` prefix before unsealing |
| Submitting after the deadline and having it recorded as on time | A vendor, or a sympathetic insider | Server-authoritative `sealed_at` inside the ledger transaction; an append-only hash chain whose head is mirrored to Object Lock storage |
| Altering a score or an award after the fact | An insider with database access | Chain-verified ledger, immutable audit sink, scorecard locking, and segregation of duties as a schema constraint rather than a role check |
| Steering an award through the [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") assistance | Anyone who can influence a prompt or a document | AI output is advisory, citation-validated and never an input to a score; prompts are versioned artifacts in the repository, not runtime values |
| Exfiltrating tender or bid content to a third party | The model integration itself | A single egress-controlled subnet, redaction before egress, per-tender opt-out, and full logging of what left |
| Malware or a decompression bomb in an uploaded pack | A vendor | Scanning and structural validation before any object is readable or extractable |
| Credential theft leading to deployment access | External | [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") federation for [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") with no long-lived keys; [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity") and [IdP](https://en.wikipedia.org/wiki/Identity_provider "Identity Provider — Service that authenticates users and issues identity assertions to relying applications") federation for staff |
| Enumeration of vendors or tenders | External | Authorization checked on every object, not only at the collection endpoint; rate limiting per principal |

## Identity & Access

**Two Cognito user pools, never one.** `cognito-staff` federates by SAML to the department's identity provider, so joiners and leavers are handled where they are already handled and no staff password exists on the platform. `cognito-vendors` holds self-registered external users with mandatory MFA on any account carrying the `submitter` role. Separating the pools means a misconfigured group, a token audience mistake or a pool-level compromise cannot cross the boundary that matters most.

Tokens are [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") / OIDC access tokens, [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs"), validated at `apigw-edge` by the [JWT](https://datatracker.ietf.org/doc/html/rfc7519 "JSON Web Token — Compact, signed token format for carrying claims between parties") authorizer against the pool's [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), and validated again in each service — the gateway is a filter, not the authority. Claims carried: `sub`, `act` (`staff` or `vendor`), `org` (`org_unit_id` or `vendor_org_id`), `roles`, `scope`. Access tokens live 15 minutes; refresh tokens 8 hours for staff and 12 for vendors, bound to the client and revocable centrally.

Service-to-service identity is IAM, not a shared secret. Each deployment runs under its own IRSA role whose policy names only the S3 prefixes, SQS queues, KMS grants and Secrets Manager entries it needs — `search-service` cannot read a secret, `ai-service` cannot read the `bids/` prefix, and only `bid-service` holds a grant on `kms-bid-custody`.

**Break-glass.** Two local administrator accounts exist for an IdP outage, protected by hardware MFA, disabled by default, enabled only by a two-person action, and every use pages the security lead and writes an `audit_event` that cannot be suppressed.

## Authorization: Role, Tenant, Assignment, Recusal

Four checks, in order, on every request that touches tender or bid data. The first that fails ends the request.

1. **Account type** (`act` claim) — a vendor token can never reach an internal endpoint, and this is checked before routing, not inside a handler.
2. **Tenant scope** — a vendor principal's `org` claim must match the row's `vendor_org_id`. Enforced in the repository layer as a mandatory predicate, so a query written without it does not compile past the base class rather than silently returning everything.
3. **Role** — [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") within the account type: `procurement_officer`, `evaluator`, `committee_chair`, `legal`, `finance`, `platform_admin` on the staff side; `admin`, `submitter`, `viewer` on the vendor side.
4. **Assignment and recusal** — [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") on the evaluation path. An evaluator may read a bid only if an `evaluator_assignment` row links them to that tender's session, the session is past unsealing, and no `recusal` row exists for the assignment. A recusal is irreversible for the session.

**Segregation of duties** is enforced where it cannot be argued with: a `evaluator_assignment` insert is rejected if the staff user created the tender or any of its versions, and an `award` insert is rejected unless the signer is the committee chair and every non-recused assignment has a locked scorecard. These are database-level constraints and service-level checks, not a policy document.

## Sealed Bid Custody

The guarantee: **between submission and unsealing, no human principal can read bid content.**

- Bid objects are written to `s3-documents/bids/` with SSE-KMS under a per-bid data key generated at sealing. The data key is stored, encrypted, in `bid_manifest.sealed_data_key`.
- The bucket policy denies `s3:GetObject` on the `bids/` prefix to every principal except `bid-service`'s IRSA role. There is no console path and no administrator exception.
- The KMS grant that lets `bid-service` decrypt a data key is created only when `POST /v1/tenders/{id}/unseal` succeeds, which requires: the tender is past `closes_at`, the tender is in `under_evaluation`, the caller holds `committee_chair`, and an `evaluation_session` exists. The unsealing writes `BidUnsealed` to `bid.events` and an `audit_event` per bid.
- After unsealing, a presigned GET is issued by `bid-service` only, expires in 60 seconds, and **writes an `audit_event` before the [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") is returned**. This is the one audit-on-read in the system, and it is deliberately scoped to this path: it runs in `bid-service` against the primary, so it does not conflict with the replica-served reads in `03` and `05`. Extending audit-on-read to ordinary browse traffic would make those replica reads impossible, and the value would not justify it.
- `manifest_entry.sha256` is captured at seal time, so an object substituted afterwards is detectable by comparison and the mismatch disqualifies the bid rather than being repaired.

## The Model Egress Boundary

Sending police-department procurement documents to a third-party model endpoint is the sharpest tension in this brief. The brief names the OpenAI [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), so the design uses it — and constrains it.

- `ai-service` and `celery-ai` are the only workloads with a route to the internet, through one egress-controlled subnet whose [NAT](https://datatracker.ietf.org/doc/html/rfc3022 "Network Address Translation — Maps multiple private addresses to a shared public address") allows exactly the model endpoint's hostname. Every other pod has a `NetworkPolicy` with no egress beyond VPC endpoints.
- **Redaction before egress.** Names, national identity numbers, phone numbers, email addresses and bank details are detected and replaced with stable placeholders before any text leaves; the mapping stays in `postgres-core` and is reapplied to the artifact on the way back. A redaction failure fails the job — it does not send the unredacted text.
- **Per-tender classification gate.** A tender marked above the platform's egress classification runs with `ai.enabled=false` for its entire lifecycle. Officers and evaluators work manually; no artifact is generated and none can be requested.
- Every egress call is logged with the artifact id, model id, prompt version, token counts and a hash of the payload — never the payload — so what left can be accounted for without the log itself becoming an exfiltration path.

> **Verify Before Build:** the design assumes the model provider is used under a zero-data-retention arrangement with no training on submitted content, and that a suitable regional endpoint exists. Both are contractual and regional questions, not technical ones. If neither holds, the correct answer is a self-hosted model inside the VPC, and the pipeline in `04` is deliberately built so the model client is the only thing that would change.

## Data Protection

**In transit.** [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") 1.3 from the client to CloudFront and from CloudFront to the ALB, with certificates issued by ACM and validated through Route 53. Inside the cluster, mTLS between services via the service mesh, with a `STRICT` peer authentication policy so a workload without a valid identity cannot receive traffic. TLS to RDS, ElastiCache, OpenSearch, MSK and SQS, all enforced at the resource, not merely requested by the client.

**At rest.** [AES-256](https://csrc.nist.gov/pubs/fips/197/final "Advanced Encryption Standard with a 256-bit key — Symmetric encryption of data at rest and in transit") everywhere: RDS storage and snapshots under `kms-data`, S3 objects under SSE-KMS, OpenSearch and MSK volumes encrypted, ElastiCache encrypted at rest and in transit. Bid content uses the separate `kms-bid-custody` key with its own grant policy and its own rotation schedule, so custody does not inherit the general data key's access.

**Field level.** Vendor bank details and contact identifiers are encrypted in the application before insert using a data key from `kms-data`, so a database snapshot leak does not disclose them. This costs the ability to index those columns, which is acceptable — nothing searches on a bank account.

**Data residency.** Every resource is provisioned in a single in-region AWS region, and the [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") configuration carries an `aws:RequestedRegion` condition on the deployment role so a resource cannot be created elsewhere by accident. Backups are copied to a second account in the same region, not to a second region — the cross-region DR trade-off recorded in `04` is a residency consequence, not an oversight.

## Secrets and Cloud Identity

- **AWS Secrets Manager** holds the model API key, database credentials, mesh and mail-relay credentials, and the SAML signing material. Rotation is automatic for the database credentials and scheduled with an alert for the rest.
- **No secret is ever in an image, a manifest, a Terraform variable file or a repository.** The External Secrets Operator pulls into [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") secrets under the service's own IRSA role, and a `gitleaks` scan runs as a blocking CI stage and as a pre-commit hook.
- **CI has no static credentials.** GitHub Actions assumes an AWS role via OIDC, with the trust policy restricted by repository, by branch and by environment, so a workflow on a fork or a feature branch cannot assume the production role.
- **KMS keys** — `kms-bid-custody` and `kms-data` — have key policies that deny deletion and policy modification to every principal except a break-glass administrator role, with CloudTrail alerting on both.
- Terraform state in `s3-tfstate` is encrypted, versioned, and readable only by the CI roles; it contains resource identifiers and is treated as sensitive.

## Regulatory & Compliance

- **National data protection law.** The deploying country's regime governs vendor contacts and staff personal data. The design provides the mechanisms these regimes have in common: lawful-basis recording, data subject access via the CRM export, erasure of personal data without destroying the award trail (`03`), breach detection through the alerting in `05`, and residency enforcement above.

  > **Verify Before Build:** "MENA" is not a jurisdiction. The applicable statute, its residency rule and its breach-notification deadline differ by country, and the retention floor for police procurement records may override the erasure path in `03`. Confirm the specific law with the department's legal office before implementation — this design provides the mechanisms, not the determination of which apply.

- **Public procurement rules.** Sealed-bid confidentiality, an auditable award trail, segregation of duties and conflict-of-interest declaration are implemented as described above, because in a procurement dispute the platform's records are the evidence.
- **[ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 27001-aligned controls** as the operating framework: asset inventory from Terraform state, access review from the IAM and Cognito group membership, change management from the CI pipeline, and incident response from the alerting in `05`.
- **No payment card data** is processed — the platform hands an award to the finance system and holds no card details, which keeps [PCI-DSS](https://www.pcisecuritystandards.org/ "Payment Card Industry Data Security Standard — Security requirements for organizations that handle payment card data") out of scope. Worth stating explicitly so a future feature does not quietly bring it in.

## Perimeter Defense

- **CloudFront + AWS [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application")** terminates TLS and applies the AWS managed [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") core rule set, the known-bad-inputs set and the IP-reputation list, plus a rule blocking requests to `/v1/admin/*` from outside the department's address ranges. Absorbs L3/L4 volumetric traffic via Shield Standard.
- **Rate limiting** in two layers: API Gateway usage plans per stage and per API key for integrations, and per-principal token buckets in `redis-cache` for authenticated traffic — 60 requests/minute for a vendor user, 20/minute on presigned-URL issue, 5/hour on bid submission. The presign limit is set above the deadline-surge pattern in `04` so legitimate last-hour behaviour is not throttled.
- **Upload defenses.** Presigned URLs are single-use, scoped to one key, expire in 15 minutes and carry a content-length range condition. `fn-object-intake` validates the magic bytes against the declared content type and rejects archives whose declared expansion ratio exceeds a threshold. ClamAV scanning in `celery-documents` runs before any object is readable or extractable, and an infected object is moved to a quarantine prefix, never deleted, because it is evidence.
- **Network.** Public subnets hold only the ALB and the NAT gateways; EKS nodes, RDS, ElastiCache, OpenSearch and MSK are private, reached through VPC endpoints. Security groups reference other security groups, never CIDR ranges, so a topology change cannot silently widen an allowance.
- **Isolation.** Production is a separate AWS account from `dev` and `staging` (`05`), with no trust relationship between them, and production data is never copied into a lower environment — test fixtures are generated, not restored.

## Audit

`audit_event` records every state transition, every authorization denial, every document access on the bid path, every unsealing, every break-glass use, every egress call and every administrative change. Entries are append-only, monthly-partitioned, and mirrored to `s3-documents/audit/` under Object Lock in compliance mode.

What makes the trail worth having is that it is checked rather than merely written: the ledger chain is recomputed nightly and on demand, and a mismatch between the recomputed head and the Object Lock sink pages the security lead as an incident (`05`). An audit log nobody verifies is a log, not a control.
