# Security & Compliance

*Robotic & Industrial [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Intelligence Platform*

**Table of Contents**
- [Identity and Access](#identity-and-access)
- [Tenant Isolation](#tenant-isolation)
- [AI and Tool Security](#ai-and-tool-security)
- [Data Protection](#data-protection)
- [Regulatory and Compliance](#regulatory-and-compliance)
- [Perimeter Defense](#perimeter-defense)
- [Items for Security Review](#items-for-security-review)

## Identity and Access

**Authentication** — every caller has exactly one identity type.

| Caller | Mechanism | Token and lifetime |
|---|---|---|
| Console user | Cognito `platform-users`, [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") Authorization Code with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") through Cognito managed login; [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity") required for `tenant_admin` and `auditor`; optional [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") federation to a tenant's own [IdP](https://en.wikipedia.org/wiki/Identity_provider "Identity Provider — Service that authenticates users and issues identity assertions to relying applications") | Access token 1 h; refresh token 12 h with rotation |
| Edge gateway | OAuth2 client credentials; one Cognito app client per gateway, mapped to `core.devices.cognito_client_id` | Access token 1 h, cached by the gateway |
| [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS") workload | EKS Pod Identity: one [IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources") role per [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") service account | Short-lived [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") credentials, rotated automatically |
| `agent-worker` / `agent-service-api` → `mcp-gateway` | Cognito client credentials with scope `platform/mcp.tools`, plus the run context described below | Access token 1 h |
| Lambda | Execution role per function | — |
| GitLab [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") | GitLab OIDC ID token exchanged for an environment-specific IAM role; the production role trusts only protected branches and tags | 1 h session |

- **Token enrichment.** The `token-enricher` Lambda (a Cognito pre-token-generation trigger) adds `tenant_id` and `roles` claims to user access tokens from the user's immutable `custom:tenant_id` attribute and Cognito groups. App clients cannot write `custom:tenant_id`; only the admin [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") can.
- **Platform staff.** Engineers who run the platform hold no standing access to tenant data. A break-glass IAM role, assumable only with MFA and a second approver, grants time-boxed read access; every use raises an alarm and lands in CloudTrail.
- **Verification in two places.** API Gateway's Cognito authorizer checks signature, expiry and scope; `platform-api` verifies the token again against the cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), because a request that bypassed the gateway must not be trusted. A gateway's tenant comes from its `client_id` through the `gwclient:` lookup, never from the request body.

> **Verify Before Build:** adding custom claims to *access* tokens with a pre-token-generation trigger requires a Cognito feature plan above Lite and the version 2 trigger event. If the chosen plan lacks it, resolve `tenant_id` and roles in `platform-api` from `core.users` keyed by `sub`, cached in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), and drop `token-enricher`.

**Authorization — [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") within a tenant, [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") across sites.** Roles come from Cognito groups; `platform-api` enforces them in a [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") dependency per route, so no route can omit the check.

| Action | `operator` | `engineer` | `reviewer` | `tenant_admin` | `auditor` |
|---|---|---|---|---|---|
| Read fleet, telemetry, alarms | ✓ | ✓ | ✓ | ✓ | ✓ |
| Start inspection | ✓ | ✓ | — | ✓ | — |
| Start analysis or generation, use assist | — | ✓ | — | ✓ | — |
| Manage datasets and knowledge documents | — | ✓ | — | ✓ | — |
| Review outputs, approve work-order drafts | — | — | ✓ | ✓ | — |
| Manage users, devices, rules, integrations, budget | — | — | — | ✓ | — |
| Read audit log | — | — | — | ✓ | ✓ |

**Site scoping (ABAC).** A user with rows in `core.user_site_access` sees only those sites; a user without rows sees the whole tenant. The tenant-context dependency adds the site list to the session alongside `app.tenant_id`, and site-bearing queries filter on it. A reviewer cannot approve their own run's output: `reviews.reviewer_id` must differ from `ai_runs.requested_by`.

## Tenant Isolation

Isolation is enforced at five independent layers, so a defect in one does not expose another tenant's data.

1. **Identity.** `tenant_id` comes only from a verified token claim or the gateway mapping — never from a path, query or body parameter.
2. **[PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") row-level security.** Every tenant-owned table has a policy on `app.tenant_id`, set with `SET LOCAL` per transaction (03). Application roles lack `BYPASSRLS` and do not own the tables. Cross-tenant jobs — sweepers, partition upkeep, nightly reconciliation — iterate over tenants and set the variable for each, so no process ever reads across tenants in one query.
3. **IAM session tags.** For [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") and the audit log, `platform-api` calls `sts:AssumeRole` on `tenant-data-access` with a session tag `tenant_id`, caching the session for 15 minutes per tenant. The role's policy allows S3 only under `tenant=${aws:PrincipalTag/tenant_id}/*` and DynamoDB `audit_log` only where `dynamodb:LeadingKeys` matches `T#${aws:PrincipalTag/tenant_id}#*`. Pre-signed upload and download URLs are signed with this session, so a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") cannot reach another tenant's prefix even if the key is tampered with.
4. **Agent runs.** An agent's tenant comes from its run, not from what the model asks for (below).
5. **Caches and logs.** Every Redis key containing tenant data is keyed by tenant or by a tenant-owned ID; API responses are never cached at the edge (05).

> **Verify Before Build:** `dynamodb:LeadingKeys` with `ForAllValues:StringLike` and a policy variable must be tested against queries on the `by_actor` and `by_day` indexes as well as the table — confirm with the IAM policy simulator and a live denied query that a session tagged for one tenant cannot read another's keys through either index.

## AI and Tool Security

Model input includes text the platform does not control — documents, maintenance notes, alarm context, text inside images — so prompt injection is assumed, and controls do not depend on the model behaving.

- **Tenant and run binding.** Each call to `mcp-gateway` carries a `run_id` — for assist, the `assist` run that `agent-service-api` records before answering (04). `mcp-gateway` loads that run, takes `tenant_id` from it, and sets `app.tenant_id` itself; tool arguments cannot name a tenant. A run that is not active is refused.
- **Tool allowlist per run type.** Analysis, generation and assist get the read tools; only analysis may call `draft_work_order`; inspection gets `get_device_status` and `get_inspection_findings`. The allowlist is enforced in `mcp-gateway`, not in the prompt.
- **No autonomous writes.** The only write tool creates a pending draft for a person to approve (04). Nothing the platform does reaches a robot or a control system.
- **Bounded tools.** Results are capped at 16 KB, raw telemetry windows at 15 minutes, and tool calls at 6 per attempt; each tool has a timeout. Every call is written to `audit_log` with `actor_type = agent` and the `run_id`.
- **Output handling.** Outputs are validated against schemas (04) and rendered in `ops-console` through React's escaping, never injected as raw [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers"), so generated content cannot inject script into the console. The exported HTML artifact is built from escaped Markdown and served from S3 as a download (`Content-Disposition: attachment`), on a different origin from the console. Every output is labelled as AI-generated, with its model and prompt version.
- **No secrets in prompts.** Credentials never enter model context; tools call services with their own identity.

> **Deep Dive Reference:** Indirect prompt injection through retrieved documents and images — the controls above limit what an injected instruction can *do*, not whether the model follows it. Red-team the analysis and inspection pipelines with planted instructions in documents and image text, and measure how often validation or review catches the result.

## Data Protection

**In transit**

- **Edge.** [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") 1.2 minimum on CloudFront and the API Gateway custom domain, with TLS 1.3 negotiated where the security policy allows; [HSTS](https://datatracker.ietf.org/doc/html/rfc6797 "HTTP Strict Transport Security — Instructs browsers to only ever connect to a site over HTTPS") on the console domain.
- **Inside AWS.** API Gateway to the [NLB](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html "Network Load Balancer — Layer 4 load balancer that forwards TCP and TLS connections to targets") over TLS; [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") with `rds.force_ssl = 1`; ElastiCache with in-transit encryption and an `AUTH` token; S3, DynamoDB, [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers"), [SNS](https://aws.amazon.com/sns/ "Amazon Simple Notification Service — Managed publish-subscribe topics that fan one message out to many subscribers"), Step Functions, Bedrock and Secrets Manager reached over [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit") through [VPC](https://aws.amazon.com/vpc/ "Virtual Private Cloud — Isolated private network in which cloud resources run") endpoints. Bucket and queue policies deny any request where `aws:SecureTransport` is false.
- **Pod to pod.** Plain [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") inside the cluster, limited by Kubernetes NetworkPolicies (only `agent-worker` and `agent-service-api` may reach `mcp-gateway`) and authenticated by bearer token. mTLS through a service mesh is not in the stack; it is the upgrade if a tenant contract requires encrypted in-cluster traffic, at the cost of running a mesh.

> **Verify Before Build:** TLS 1.3 availability depends on the API Gateway and CloudFront security policy chosen for the custom domain. Check which policies the region offers and confirm the negotiated version with a TLS client.

**At rest** — [AES-256](https://csrc.nist.gov/pubs/fips/197/final "Advanced Encryption Standard with a 256-bit key — Symmetric encryption of data at rest and in transit") everywhere, with customer-managed [KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use") keys per data class rather than AWS-owned keys, so key use is logged and can be revoked.

| Data class | Key | Covers |
|---|---|---|
| Operational database | `platform-db-key` | RDS storage, snapshots, [PITR](https://www.postgresql.org/docs/current/continuous-archiving.html "Point in Time Recovery — Restores a database to a specific past moment using base backups and archived logs") |
| Telemetry and datasets | `data-objects-key` | `telemetry-raw`, `robotic-datasets` with S3 Bucket Keys, `telemetry_checkpoints` |
| AI artifacts | `ai-artifacts-key` | `ai-artifacts`, the debug prompt log group |
| Audit | `audit-key` | `audit_log`, `audit-archive` |
| Messaging | `messaging-key` | SQS queues, SNS topics, Step Functions execution data |

- **Field-level protection.** No secrets are stored in PostgreSQL: `integrations.secret_arn` points to Secrets Manager. Email and phone numbers stay in Cognito; `core.users` holds only a display name and role.
- **Secrets Manager.** Database credentials use managed rotation every 30 days; the Redis `AUTH` token and tenant webhook signing secrets rotate on a schedule. Pods read secrets through the [SDK](https://en.wikipedia.org/wiki/Software_development_kit "Software Development Kit — Packaged set of tools and libraries for building against a platform") with a local cache and refresh on an authentication failure; Lambdas use the Parameters and Secrets extension.
- **Webhooks** are signed with [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash-based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") using a per-integration secret, so the tenant's system can verify the sender.
- **Per-tenant keys** are the upgrade path when a tenant requires its own revocable key; key policies and ABAC conditions already carry `tenant_id`.

## Regulatory and Compliance

| Framework | Why it applies | How the design meets it |
|---|---|---|
| [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") | User identities, actor IDs and IP addresses in `audit_log`; workers may appear in inspection images | Personal data minimised to Cognito; region per tenant for residency; image metadata stripped on preprocessing; inspection originals without findings deleted after 1 year; a [DPIA](https://gdpr-info.eu/art-35-gdpr/ "Data Protection Impact Assessment — GDPR process for assessing privacy risk before high-risk data processing") for image inspection; erasure requests handled by pseudonymising actor IDs in audit records |
| [IEC](https://www.iec.ch/ "International Electrotechnical Commission — Publishes international standards for electrical and industrial technology, including the IEC 62443 industrial security series") 62443 | Customers' [OT](https://en.wikipedia.org/wiki/Operational_technology "Operational Technology — Hardware and software that monitors and controls industrial equipment and processes") networks connect to the platform through gateways | Gateways only initiate outbound HTTPS; the platform never sends commands; each gateway has its own revocable credential — this fits the zone-and-conduit model and keeps the platform out of the control zone |
| [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 27001, [SOC](https://www.aicpa-cima.com/topic/audit-assurance/audit-and-assurance-greater-than-soc-2 "System and Organization Controls — Audit reports on a service organization's security, availability and confidentiality controls") 2 type 2 | Expected of a [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") [SaaS](https://en.wikipedia.org/wiki/Software_as_a_service "Software as a Service — Delivers an application as a hosted service that customers use rather than install") provider holding operational data | Audit log with 5-year immutable archive; changes only through reviewed merge requests and the pipeline; least-privilege IAM; quarterly access reviews; encryption and key logging |
| EU AI Act | AI analysis of industrial equipment for EU tenants | Human review before any generated document or finding is exported; outputs labelled as AI-generated; `model_id` and `prompt_version` recorded per run for traceability |

[HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") and [PCI-DSS](https://www.pcisecuritystandards.org/ "Payment Card Industry Data Security Standard — Security requirements for organizations that handle payment card data") do not apply: the platform holds no health or payment-card data.

> **Deep Dive Reference:** EU AI Act classification — whether inspection findings count as a safety component of machinery depends on how tenants use them. Legal review should classify the use cases before EU launch; the human-review gate and run records are designed to support the stricter outcome.

> **Verify Before Build:** Bedrock's data-handling terms — that prompts and outputs are not stored or used for training — and whether a cross-region inference profile keeps requests within the tenant's geography. Confirm both for each region used.

## Perimeter Defense

- **AWS [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application")** on the CloudFront distribution and the API Gateway stage: AWS managed rule groups for common exploits, known bad inputs and IP reputation; a rate-based rule of 10,000 requests per 5 minutes per IP on console paths — one polling console makes about 160, and a plant's users share one egress address, so the limit allows about 60 users behind one address; gateway paths are excluded for the same reason. Body size limits are 300 KB on ingest, enough for the 192 KB compressed payload after base64 encoding (04), and 64 KB elsewhere.
- **API Gateway throttling.** Stage default 1,000 requests/s with a burst of 2,000 — 5× the estimated peak (01). Method limits: 300 requests/s on ingest; 20 requests/s each on run creation and assist. Gateways also send a per-tenant API key tied to a usage plan, which meters and caps each tenant's ingest; the key identifies usage only and is never treated as authentication.
- **Application limits.** Redis counters cap AI run creation per tenant per minute, and the daily token budget caps spend (04).
- **[DDoS](https://en.wikipedia.org/wiki/Denial-of-service_attack "Distributed Denial of Service — Attack that floods a system with traffic from many sources to make it unavailable").** Shield Standard is included on CloudFront and API Gateway. Shield Advanced (about US$3,000/month) is not justified at this scale; the trigger is a DDoS incident or a contract that requires it.
- **Network.** Private subnets for all compute and data; the EKS API endpoint is private and reachable only from the in-VPC CI runners; no public IPs on nodes; security groups allow the NLB to reach pods only on service ports.

> **Verify Before Build:** AWS WAF inspects only the first part of a request body — the limit differs for CloudFront and regional resources and can be raised at extra cost. Size-limit rules must match that limit, or oversize bodies need an explicit rule.

## Items for Security Review

These decisions touch identity, secrets or cross-tenant access and need a reviewer before build:

1. The `tenant-data-access` role: its trust policy (only the `platform-api` pod role may assume it, with `sts:TagSession`) and its S3 and DynamoDB conditions.
2. The `token-enricher` trigger and the rule that `custom:tenant_id` is writable only by the admin API.
3. GitLab OIDC trust conditions for each environment's deploy role, especially the production role's branch and tag restriction.
4. KMS key policies per data class, and who may decrypt with `audit-key`.
5. Secrets Manager rotation for database credentials, and the pods' refresh-on-failure behaviour.
6. `mcp-gateway`'s run-binding and per-run-type allowlist — the only barrier between an injected instruction and another tenant's data.
