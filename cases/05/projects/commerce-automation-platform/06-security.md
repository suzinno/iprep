# Security & Compliance

*Intelligent Commerce Automation Platform*

## Table of Contents

- [Trust Boundaries](#trust-boundaries)
- [Identity & Access](#identity--access)
- [Agent and Tool Security](#agent-and-tool-security)
- [Data Protection](#data-protection)
- [Regulatory and Compliance](#regulatory-and-compliance)
- [Perimeter Defense](#perimeter-defense)

## Trust Boundaries

| Boundary | Crosses it | Control |
|---|---|---|
| Internet → [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Gateway `cap-public-api` | Console, widget, partners, channel webhooks | [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application"), [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection"), Cognito authorizer or API key, usage plans |
| API Gateway → [EKS](https://aws.amazon.com/eks/ "Amazon Elastic Kubernetes Service — Managed Kubernetes hosting on AWS") | All `/v1/*` routes | [VPC](https://aws.amazon.com/vpc/ "Virtual Private Cloud — Isolated private network in which cloud resources run") Link to an internal [NLB](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html "Network Load Balancer — Layer 4 load balancer that forwards TCP and TLS connections to targets"); no public load balancer on the cluster |
| Pod → pod | Internal [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") (`/internal/*`), [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing"), [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") | Linkerd mTLS; [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") NetworkPolicies deny by default |
| Pod → AWS services | Bedrock, [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives"), [SQS](https://aws.amazon.com/sqs/ "Amazon Simple Queue Service — Managed message queue that decouples producers from consumers"), [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes"), Secrets Manager | [IAM](https://aws.amazon.com/iam/ "AWS Identity and Access Management — Controls which principals may perform which actions on which AWS resources") roles for service accounts, one role per service |
| Platform → [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") API | `agent-worker` only | Egress allowed only from that namespace; the key comes from Secrets Manager |
| Untrusted content → [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") | Supplier feed text, shopper messages, competitor listings | Treated as data, never as instructions (see [Agent and Tool Security](#agent-and-tool-security)) |

## Identity & Access

**Authentication ([OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") / [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users"), Amazon Cognito user pool `cap-merchants`)**

- **Merchant users** sign in to `merchant-console` with the authorization code flow and [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") (a public client with no secret). Enterprise tenants federate their own [IdP](https://en.wikipedia.org/wiki/Identity_provider "Identity Provider — Service that authenticates users and issues identity assertions to relying applications") through federation (OIDC or the enterprise's single sign-on standard) OIDC. [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity") is required for the `owner` and `admin` roles.
- **Tokens:** access tokens last 15 minutes and refresh tokens 12 hours, with rotation. Lambda `cognito-pre-token` adds `tenant_id` and the user's scopes to the access token. Services verify the [RS256](https://datatracker.ietf.org/doc/html/rfc7518 "RSA Signature with SHA-256 — Asymmetric signing algorithm commonly used to sign JWTs") signature against a cached [JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token"), then check `iss`, `aud`, `exp` and `token_use = access`.
- **Partners** use the client credentials grant against resource server `cap-api`, with custom scopes: `catalog.read`, `catalog.write`, `inventory.read`, `inventory.write`, `pricing.approve`, `analytics.read`.
- **Storefront widget:** a publishable API key identifies the tenant and is bound to that tenant's allowed origins. It is **not a secret**. Its only power is to call the read-only storefront routes, which have per-key usage plans. Shoppers are never Cognito users. `shopper_ref` is an [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key")-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") of the storefront's own shopper id, computed with a key per tenant, so the platform cannot reverse it to an identity.
- **Channel webhooks** are verified by `webhook-ingest` with each channel's HMAC scheme. The per-connection secret is in Secrets Manager, and `platform.channel_connections.credentials_secret_arn` points to it.

> **Verify Before Build:** adding custom claims to Cognito **access** tokens needs version 2 of the pre-token-generation trigger, which is only available on the Essentials or Plus feature plan — confirm the user pool's plan before relying on `tenant_id` in access tokens.

**Authorization ([RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") + [ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles"))**

- **RBAC:** Cognito groups map to roles, and the chassis maps roles to permissions.

| Role | Can |
|---|---|
| `owner` | Everything, including billing and channel connections |
| `admin` | Users, rules, channel connections |
| `catalog_manager` | Imports, product edits, stock adjustments |
| `pricing_manager` | Pricing rules, approve or reject price decisions |
| `analyst` | Dashboards and trend reports, read-only |

- **ABAC on tenant:** each request's `tenant_id` claim must equal the resource's `tenant_id`. The chassis checks this first, and [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") enforces it a second time with **row-level security** on every tenant table. Each transaction runs `SET LOCAL app.tenant_id` from the verified claim. The policy is `USING (tenant_id = current_setting('app.tenant_id')::uuid)`. A missing `WHERE tenant_id = …` in application code then returns no rows instead of another tenant's rows.
- [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") applies equally to reads on `core-db-replica`, because the policy needs no writes. Read-only analytics queries on the replica are not audited per row. Only writes are audited, on the primary in the same transaction, so no control here requires a write on a replica.
- **Roles that bypass RLS** exist only for the outbox relays, the partition job and Glue's two [JDBC](https://docs.oracle.com/javase/tutorial/jdbc/overview/index.html "Java Database Connectivity — Standard driver interface that Spark and AWS Glue use to read and write relational databases") connections: one writes to the `staging` schema only; the other reads `orders` on `core-db-replica` for `affinity-builder` and `orders-archive`. `catalog-worker` and `recommendation-service` may read only their own `staging` tables. None of these roles is reachable from a request path.

> **Verify Before Build:** RLS policies can stop the planner from using the `(tenant_id, …)` indexes if the policy expression is not treated as a constant — check `EXPLAIN` of the variant lookup with RLS enabled on the production PostgreSQL version, and confirm the plan is still an index-only scan.

## Agent and Tool Security

The tools `check_availability`, `update_stock`, `search_products` and the pricing context tools follow four rules:

1. **Tenant is injected, never an argument.** A tool's [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") schema has no `tenant_id` field. The tool is built per request as a closure over the verified principal. A prompt-injected "look up tenant X" has no parameter to put X in.
2. **Tools act with the caller's permissions, never more.** In the merchant copilot, `conversation-service` forwards the user's own access token to `inventory-service`, so the user's role limits the tool. Shoppers have no token (see the storefront widget above). Shopper chat therefore calls with `conversation-service`'s own client-credentials token, which Cognito issues with `inventory.read` only. `update_stock` is not in the shopper tool registry, and if it were called anyway, `inventory-service` would return 403.
3. **Writes are bounded and confirmed.** `StockUpdateInput` limits `delta` to ±1,000 and `reason` to an enum, and requires an `idempotency_key`. The merchant copilot pauses with a LangGraph `interrupt` and shows the exact change. Only the user's click resumes the graph. Every change is written to `inventory.stock_adjustments` with `actor_type = 'agent'`, `actor_id` = the user's `sub`, and `agent_run_id`.
4. **Untrusted text has no tools.** [SEO](https://developers.google.com/search/docs/fundamentals/seo-starter-guide "Search Engine Optimization — Shapes page content so that search engines rank it higher") and attribute extraction over supplier text run with no tools bound. Their output is schema-validated (Pydantic) and [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers")-sanitised before it is saved or pushed to a channel.

> **Deep Dive Reference:** indirect prompt injection — competitor listings and supplier text reach the pricing and chat agents as tool output; a red-team suite of injected payloads, run in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") against recorded fixtures, is the way to show the four rules hold.

## Data Protection

**In transit**

| Path | Standard |
|---|---|
| Client → CloudFront, API Gateway | TLS 1.2 minimum, TLS 1.3 preferred; [HSTS](https://datatracker.ietf.org/doc/html/rfc6797 "HTTP Strict Transport Security — Instructs browsers to only ever connect to a site over HTTPS") on the console |
| API Gateway → NLB → ingress-nginx | TLS re-encrypted through the VPC Link |
| Pod ↔ pod | Linkerd mTLS (automatic certificate rotation every 24 h) |
| Services → [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") | TLS required (`rds.force_ssl = 1`), certificate verified |
| Services → [MSK](https://aws.amazon.com/msk/ "Amazon Managed Streaming for Apache Kafka — Runs Apache Kafka clusters as a managed AWS service") | TLS with IAM authentication |
| Services → ElastiCache | In-transit encryption plus IAM authentication |
| Services → Bedrock, OpenAI, DynamoDB, S3, SQS | TLS 1.2+ to AWS or provider endpoints; Bedrock through a VPC interface endpoint |

> **Verify Before Build:** API Gateway custom domains negotiate TLS 1.3 only under specific security policies — select the policy explicitly and test the handshake rather than assuming 1.3 by default.

**At rest ([AES-256](https://csrc.nist.gov/pubs/fips/197/final "Advanced Encryption Standard with a 256-bit key — Symmetric encryption of data at rest and in transit") through [KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use") customer-managed keys, with rotation on)**

- RDS `core-db` and `search-db`, their snapshots and cross-region backup copies.
- S3 buckets with KMS-managed server-side encryption and a bucket policy that denies unencrypted puts; DynamoDB tables; MSK storage; ElastiCache; the disk volumes of EKS nodes.
- **Sensitive fields:** channel credentials never enter PostgreSQL; only a Secrets Manager [ARN](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html "Amazon Resource Name — Globally unique identifier of an AWS resource, used in policies and cross-service references") does. Chat transcripts in `conversation-state` may hold what shoppers type, so they have a 30-day [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires"), and a redactor masks emails, phone numbers and card-like numbers before any log line is written.

**Data minimisation.** `webhook-ingest` and `order-service` keep an allowlist of order fields. Name, address, email and payment fields are dropped before the order is persisted, and only `ship_country` is kept. The pricing agent's OpenAI calls contain product, price and signal data only.

## Regulatory and Compliance

| Framework | Applies because | Design response |
|---|---|---|
| [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") / [CCPA](https://oag.ca.gov/privacy/ccpa "California Consumer Privacy Act — Gives California residents rights over the personal data businesses hold about them") | EU and California shoppers interact through the widget and chat | The platform is a processor under each merchant's data processing agreement. Shoppers are identified only by pseudonymous `shopper_ref`. Erasure by `shopper_ref` removes `conversation-state` items via the `by-shopper` [GSI](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html "Global Secondary Index — DynamoDB index with its own partition key that serves an alternative access pattern") and nulls `orders.orders.shopper_ref`. Redis and Kafka copies expire within their TTL and retention (≤ 14 d), which the privacy notice states |
| [PCI-DSS](https://www.pcisecuritystandards.org/ "Payment Card Industry Data Security Standard — Security requirements for organizations that handle payment card data") | Orders come from channels that process cards | **Out of scope by design:** no cardholder data is ever stored or sent on. The field allowlist drops payment data, and a test asserts no card-like pattern reaches `orders.orders` |
| [SOC](https://www.aicpa-cima.com/topic/audit-assurance/audit-and-assurance-greater-than-soc-2 "System and Organization Controls — Audit reports on a service organization's security, availability and confidentiality controls") 2 (Type 2) | Enterprise merchants require it | Evidence comes from the CloudTrail, KMS and IAM audit trails, the pipeline's change record, and quarterly access reviews |
| EU [AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Act (transparency) | The chat widget talks to EU shoppers | The widget states that the assistant is AI. Pricing decisions keep their rationale and human approval above the auto-apply band |
| Competition law | One pricing engine serves competing merchants | Pricing inputs are strictly per tenant: public competitor prices plus the tenant's own data. No tenant's data or decisions feed another tenant's run, which rules out a shared algorithm aligning competitors' prices |

## Perimeter Defense

- **AWS WAF** on CloudFront and on `cap-public-api`: AWS managed rule groups (core rule set, known bad inputs, [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") injection), Bot Control on the storefront routes against catalog scraping, a 256 KB body limit, and a rate-based rule of 2,000 requests per 5 minutes per IP on storefront routes.
- **Rate limiting in layers:** API Gateway usage plans per API key and per partner client (steady rate plus burst). The token budget per tenant in Redis (`04-deep-dive.md`) protects LLM spend, which a flood of chat messages would otherwise turn into a bill.
- **[DDoS](https://en.wikipedia.org/wiki/Denial-of-service_attack "Distributed Denial of Service — Attack that floods a system with traffic from many sources to make it unavailable"):** Shield Standard on CloudFront and API Gateway covers layer 3/4 attacks at no cost. Layer 7 floods meet the WAF rate rules. Shield Advanced (~$3k per month) is deferred until a tenant's contract requires it.
- **Deploy and cloud identity:** Bitbucket Pipelines assumes a deploy role through OIDC, limited to this repository and to pushing to [ECR](https://aws.amazon.com/ecr/ "Amazon Elastic Container Registry — Stores, scans and serves container images for deployment") and deploying to EKS. No long-lived AWS keys exist. Each service account's IAM role lists only its own resources: `catalog-worker` may invoke only the configured Bedrock models and read only `cap-supplier-feeds`, and only `agent-worker` can read the OpenAI key.
