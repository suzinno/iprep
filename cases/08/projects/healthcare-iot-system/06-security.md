# Security & Compliance

*Smart Healthcare System ([IoT](https://en.wikipedia.org/wiki/Internet_of_things "Internet of Things — Networked physical devices that report telemetry and receive commands over constrained links"))*

## Table of Contents

- [Identity and Authentication](#identity-and-authentication)
- [Authorization](#authorization)
- [Workload Identity and Grants](#workload-identity-and-grants)
- [Data Protection](#data-protection)
- [Regulatory and Compliance](#regulatory-and-compliance)
- [Perimeter Defense](#perimeter-defense)

## Identity and Authentication

Microsoft Entra ID is the only identity provider. Every caller, human or machine, presents an [OAuth2](https://datatracker.ietf.org/doc/html/rfc6749 "OAuth 2.0 — Authorization framework that lets an application access resources on a user's behalf") access token issued by it.

| Caller | Flow | Token check |
|---|---|---|
| Staff [SPA](https://en.wikipedia.org/wiki/Single-page_application "Single Page Application — Web application that updates its content in place without full page reloads") and mobile app | [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") authorization code with [PKCE](https://datatracker.ietf.org/doc/html/rfc7636 "Proof Key for Code Exchange — Protects an OAuth authorization code exchange for clients that cannot hold a secret") ([MSAL](https://learn.microsoft.com/en-us/entra/identity-platform/msal-overview "Microsoft Authentication Library — Client library that obtains tokens from Microsoft Entra ID")); [MFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Multi Factor Authentication — Requires more than one form of evidence to verify a user's identity") and compliant-device rules through Conditional Access; access tokens live 60 min, refresh tokens are rotated | [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") Management `validate-jwt` (issuer, audience, signature, expiry), then the service validates again |
| Ward gateway | OAuth2 client credentials with a **certificate** credential; the private key never leaves the gateway's [TPM](https://trustedcomputinggroup.org/resource/trusted-platform-module-tpm-summary/ "Trusted Platform Module — Hardware chip that stores cryptographic keys so they cannot be copied off the device"). One Entra app registration per gateway, created by [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files"), app role `Telemetry.Write`; certificates rotate every 90 days | `telemetry-service` validates the token itself (ingest bypasses API Management), maps the token's client ID to `gateway:{client_id}`, and rejects any frame whose device is not bound to that gateway's ward |
| Transport robot | Same client-credentials pattern, app role `Robot.Operate` | `robot-service` rejects a call when the `robot_id` in the path does not match the robot row whose `entra_client_id` issued the token |
| Pods calling Azure services | [AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure") workload identity: each service account is federated to its own user-assigned managed identity | Azure [RBAC](https://en.wikipedia.org/wiki/Role-based_access_control "Role Based Access Control — Grants permissions to users based on assigned roles rather than individually") on the target resource |
| GitHub Actions | OIDC federation to a deploy identity per environment; no stored cloud secrets | Azure RBAC scoped to that environment's resource group |

**Why every service validates the token again.** API Management is not on the ingest path, and inside the cluster a compromised pod could otherwise call a service directly. Each service checks issuer, audience and signature against cached Entra signing keys (`05-reliability.md`), which costs under a millisecond per request.

## Authorization

**RBAC — Entra app roles** carried in the token's `roles` claim:

| Role | Can |
|---|---|
| `Nurse` | Read vitals, alerts and files for patients they can access; acknowledge and resolve alerts; request robot missions |
| `ChargeNurse` | Nurse rights, plus edit thresholds for their ward |
| `Physician` | Read patient data they can access; edit per-admission thresholds |
| `WardManager` | Configure beds, devices, gateway bindings and rosters for their own ward; no clinical data by default |
| `TransportCoordinator` | Manage missions and robots; sees a patient ID on a mission, not the patient record |
| `KnowledgeEditor` | Upload and retire assistant corpus documents |
| `Admin` | Platform configuration; **no clinical read access** (separation of duties) |

**[ABAC](https://en.wikipedia.org/wiki/Attribute-based_access_control "Attribute Based Access Control — Grants access based on attributes of the subject, resource and environment rather than fixed roles") — patient-level access.** A role allows a type of action; whether it applies to *this* patient is decided by `care.v_patient_access`. The staff member must be on the admission's care team or rostered on the patient's ward right now. Services check with an `EXISTS` query, cached for 60 s in `access:{entra_object_id}:{patient_id}`. `care-core` implements the check as a [DRF](https://www.django-rest-framework.org/ "Django REST Framework — Toolkit for building REST APIs on Django with serializers and permission classes") permission class; Flask services use a shared decorator from the same `care_access` package, so the rule has one implementation.

**Break-glass.** A `Nurse` or `Physician` outside the care team can open a record in an emergency by giving a reason. The access is logged with `purpose = 'break_glass'`, notifies the privacy officer, and appears in the weekly access review.

**Access auditing.** Every [PHI](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160/subpart-A/section-160.103 "Protected Health Information — Individually identifiable health data that HIPAA regulates") read or write inserts a row in `audit.access_event` synchronously, before the response. Reads are coalesced: the first access per actor, resource and 15-minute window is logged, guarded by `SET NX audit:seen:…`. If [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") is unavailable, the guard fails open and every access is logged, so the log can over-count but never under-count. **Dependency:** because the audit insert happens inside the request, PHI reads are served from the [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") primary. The cross-region replica in `04-deep-dive.md` is for [DR](https://en.wikipedia.org/wiki/Disaster_recovery "Disaster Recovery — Restores a system in another location after a failure too large for in-place redundancy") only and never serves reads.

## Workload Identity and Grants

Each runtime component has its own PostgreSQL login (Entra authentication mapped to its managed identity), its own [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") user and its own managed identity. No runtime role owns a schema: each schema is owned by a `NOLOGIN` `<schema>_owner` role used only by that schema's migration job. `SECURITY DEFINER` routines run as their schema's owner. The one cross-schema read by an owner is `care_owner`'s SELECT on `alerting.alert`, which `care.ward_census` needs for its open-alert count.

| Component | PostgreSQL | Other stores | RabbitMQ (vhost `care`) | Secrets and external |
|---|---|---|---|---|
| `care-core` | `care`: all [DML](https://en.wikipedia.org/wiki/Data_manipulation_language "Data Manipulation Language — The SQL statements that read and change rows"); `audit.access_event`: INSERT; EXECUTE `care.ward_census` | Redis: `thresholds:*`, `devbind:*`, `gateway:*`, `access:*`, `audit:seen:*`, `idem:*`; Blob: Data Contributor + Delegator on `patient-files` | none | Key Vault: wrap/unwrap on the field-encryption key; read the [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash-based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key") key |
| `telemetry-service` | SELECT `telemetry.vitals_minute`, `vitals_hour`, `risk_score`; SELECT `care.v_device_binding`, `care.v_patient_access`; INSERT `audit.access_event` | Redis: read `vitals:latest:*`, `replay:*`, `access:*`; read and fill `gateway:*`; write `batch:*`, `gateway:lastseen:*`, `ratelimit:*`, `audit:seen:*`; Cosmos: `find` on `vitals_raw` | write exchange `telemetry` | — |
| `vitals-processor` | SELECT `care.v_device_binding`, `care.v_effective_threshold` | Redis: `vitals:latest:*`, `vitals:win:*`; read and fill `thresholds:*`, `devbind:*` | read `vitals.processor`; write exchange `alerts` | — |
| `vitals-writer` | none | Cosmos: `insert`, `update` on `vitals_raw` | read `vitals.writer` | — |
| `alert-service` | `alerting`: all DML; EXECUTE `alerting.*` routines; SELECT `care.v_on_duty_staff`, `care.v_patient_access`, `care.v_device_binding`; INSERT `audit.access_event` | Redis: read `gateway:lastseen:*`, `access:*`; write `oncall:*`, `audit:seen:*` | read `alert-service.raised`, `alerts.scheduled`; write `notify`, `alerts.scheduled` | — |
| `notification-service` | `notify`: all DML | — | read `notify` | Key Vault: Firebase and Apple push credentials |
| `robot-service` | `robotics`: all DML; EXECUTE `robotics.assign_next_mission`; SELECT `care.v_patient_access`; INSERT `audit.access_event` | Redis: `robot:state:*`, `access:*`, `audit:seen:*`, `idem:*` | write `notify` | — |
| `assistant-service` | `kb`: SELECT `document`, `chunk`; INSERT `document`, `chat_log` | Redis: `assistant:cache:*`, `ratelimit:*`, read `assistant:corpus_version`; Blob: Data Contributor + Delegator on `kb-documents` | none | Key Vault: [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") key (assistant) |
| `func-knowledge` | `kb`: SELECT, INSERT, UPDATE on `document`, `chunk` | Blob: Data Reader on `kb-documents`; Redis: `assistant:corpus_version` | none | Key Vault: OpenAI key (ingest) |
| `func-analytics` | `telemetry`: all DML; EXECUTE `telemetry.upsert_minute_rollups`, `telemetry.create_next_partitions`, `audit.create_next_partitions`; SELECT `care.v_admission_outcome`, `audit.access_event` | Cosmos: `find` on `vitals_raw`; Blob: Data Contributor on `vitals-archive`, `audit-archive`, `ml-datasets` | write exchange `alerts` | Azure [ML](https://en.wikipedia.org/wiki/Machine_learning "Machine Learning — Algorithms that learn patterns from data rather than following explicit rules"): score action on `deterioration-risk`; Key Vault: pseudonymisation HMAC key |
| Azure ML workspace | none | Blob: Data Reader on `ml-datasets` | none | — |

Each component's RabbitMQ password, and any store credential that cannot use Entra authentication, is a Key Vault secret that only that component's identity can read. It is mounted into the pod by the Key Vault provider for the Secrets Store [CSI](https://kubernetes-csi.github.io/docs/ "Container Storage Interface — Standard plugin interface through which Kubernetes attaches storage volumes") driver (an AKS add-on), never baked into an image or a manifest.

RabbitMQ permissions are regex-scoped per user with `configure` denied: Terraform declares the topology, and services only publish and consume. [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") remote control and task events are turned off, so workers need no access to the `celery.pidbox` and `celeryev` exchanges.

> **Verify Before Build:** Fine-grained data-plane access — confirm that Azure Cache for Redis data access policies can restrict an Entra identity to key patterns such as `~vitals:*` on the chosen tier, and that role-based access control for Cosmos DB for [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") ([RU](https://learn.microsoft.com/en-us/azure/cosmos-db/request-units "Request Unit — Azure Cosmos DB's currency for provisioned throughput, charged per request regardless of operation type")) supports per-collection `find` and `insert`/`update` roles. Where either is missing, the fallback is a shared credential per store, which weakens the rows above to "any service that holds the credential".

## Data Protection

**In transit.**

- The public listener on Application Gateway accepts [TLS](https://datatracker.ietf.org/doc/html/rfc8446 "Transport Layer Security — Encrypts and authenticates data sent over a network connection") 1.2 and 1.3 only, with a modern cipher policy and [HSTS](https://datatracker.ietf.org/doc/html/rfc6797 "HTTP Strict Transport Security — Instructs browsers to only ever connect to a site over HTTPS").
- Application Gateway re-encrypts to API Management and to the Istio ingress. Inside the cluster, Istio enforces **[mTLS](https://en.wikipedia.org/wiki/Mutual_authentication "Mutual TLS — TLS in which client and server both present certificates, so each authenticates the other") in STRICT mode**, so no pod accepts plain-text traffic from another pod.
- Managed services accept TLS only: PostgreSQL with `require_secure_transport`, Redis on its TLS port only, Cosmos DB with TLS 1.2 minimum. RabbitMQ listens on [AMQPS](https://www.amqp.org/ "AMQP over TLS — Encrypts an AMQP broker connection in transit") (5671) only; the plain [AMQP](https://www.amqp.org/ "Advanced Message Queuing Protocol — Standardizes reliable message queueing and routing between applications") listener is disabled.

**At rest.**

- [AES-256](https://csrc.nist.gov/pubs/fips/197/final "Advanced Encryption Standard with a 256-bit key — Symmetric encryption of data at rest and in transit") encryption is on for every store: PostgreSQL, Cosmos DB, Blob Storage, Redis persistence, and the AKS managed disks (including RabbitMQ volumes). Node temporary disks use host-based encryption.
- PHI stores (PostgreSQL, Cosmos DB, Blob Storage, AKS disks) use **customer-managed keys** in Key Vault, with purge protection and yearly rotation. Backups inherit the same keys.

**Field level.** `care.patient.national_id_enc` and `phone_enc` are encrypted in `care-core` with AES-256 in Galois/Counter Mode, using a data key wrapped by a Key Vault key (envelope encryption). `national_id_hmac` is an HMAC-[SHA256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity") under a separate key, so exact-match lookup works without decrypting. A database dump or an administrator's session therefore never shows these values in clear text.

**Assistant data boundary.** The corpus contains guidelines, not patient records, and `assistant-service` has no grant on any patient table (see the grants table). A staff member can still type PHI into a question, so each question passes a redaction step before it leaves the tenant. The step masks [MRN](https://en.wikipedia.org/wiki/Medical_record "Medical Record Number — Unique identifier a healthcare provider assigns to a patient's record") and national-ID patterns, phone numbers and dates. Free-text names are the residual risk: rule-based redaction cannot catch them reliably, so the UI warns the user and the OpenAI organisation is configured for zero data retention. `chat_log` stores only the redacted question, for 90 days.

> **Verify Before Build:** OpenAI contract terms — zero data retention and a [BAA](https://www.hhs.gov/hipaa/for-professionals/covered-entities/sample-business-associate-agreement-provisions/index.html "Business Associate Agreement — HIPAA contract under which a vendor may handle protected health information for a covered entity") from OpenAI are available only to approved API customers. Confirm both for this organisation before go-live; without them, move the assistant to Azure OpenAI Service as described in `04-deep-dive.md`.

## Regulatory and Compliance

- **[HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") (baseline).**
  - A BAA is in place with Microsoft for the Azure services used, and with OpenAI as above.
  - Access control is RBAC + ABAC. Audit controls are `audit.access_event`, archived monthly to the `audit-archive` container under a 6-year immutability policy. Integrity is protected by insert-only audit grants. Transmission security is covered by the controls above. Minimum necessary is enforced by the ABAC rule and the `Admin` and `TransportCoordinator` scopes.
- **[GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") (where EU residents' data is processed).**
  - Health data is a special category (Article 9), so a [DPIA](https://gdpr-info.eu/art-35-gdpr/ "Data Protection Impact Assessment — GDPR process for assessing privacy risk before high-risk data processing") is required before go-live.
  - All regions, including DR, sit in an EU region pair.
  - Access reports from `audit.access_event` support [DSAR](https://gdpr-info.eu/art-15-gdpr/ "Data Subject Access Request — Request by an individual to see the personal data an organization holds about them") responses.
  - Erasure requests are weighed against medical-record retention law, which usually prevails for clinical records but not for chat logs or push tokens.
  - ML datasets are **pseudonymised**, not anonymised: patient IDs are replaced by an HMAC with a key in Key Vault. They therefore remain personal data, are deleted after 1 year, and are available only to the Azure ML workspace.
- **Records retention.** Clinical data follows local medical-records law. The 5-year figures in `01-requirements.md` are capacity estimates, not a retention policy.

> **Deep Dive Reference:** Medical device regulation — software that raises clinical alerts from patient data can qualify as software as a medical device under the EU Medical Device Regulation or [FDA](https://www.fda.gov/medical-devices/digital-health-center-excellence/software-medical-device-samd "Food and Drug Administration — US regulator whose remit includes software used as a medical device") guidance, bringing [IEC](https://www.iec.ch/ "International Electrotechnical Commission — Publishes international standards for electrical and industrial technology, including the IEC 62443 industrial security series") 62304 life-cycle and risk-management duties. The "secondary notification, bedside alarm primary" positioning in `01-requirements.md` affects the classification and needs regulatory review, not an architect's judgement.

## Perimeter Defense

- **[WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application").** Application Gateway WAF v2 runs the [OWASP](https://owasp.org/ "Open Worldwide Application Security Project — Community effort publishing practices and tools for building secure software") Core Rule Set in prevention mode, with custom rules for these paths:
  - `/ingest/*` and the robot paths accept requests only from registered hospital egress IP addresses.
  - `/ingest/*` is rate limited to 2,400 requests/min per client IP. About 10 gateways share one hospital egress address: they send ~600/min normally and ~1,200/min while all replay after an uplink outage (`04-deep-dive.md`), so the limit keeps 2× headroom over the replay peak.
  - Geo-filtering allows only the operating countries.
- **[DDoS](https://en.wikipedia.org/wiki/Denial-of-service_attack "Distributed Denial of Service — Attack that floods a system with traffic from many sources to make it unavailable").** Azure DDoS IP Protection covers the single public IP on Application Gateway. The network-wide DDoS Protection plan (~$2.9k/month list price) is not proportionate for one public endpoint. Evolution trigger: a second public endpoint or a public-facing app.
- **Rate limiting.**
  - API Management applies `rate-limit-by-key` on the user's object ID: 300 calls/min for general APIs, and 20 questions/min for the assistant.
  - `assistant-service` also enforces a daily token budget per user in Redis, which caps [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") spend.
  - `telemetry-service` limits each gateway to 5 batches/s through `ratelimit:*`, in addition to the WAF limit.
- **Network isolation.**
  - The AKS API server is private. PostgreSQL, Cosmos DB, Redis, Blob Storage, Key Vault, [ACR](https://learn.microsoft.com/en-us/azure/container-registry/ "Azure Container Registry — Stores and geo-replicates container images for Azure deployments") and API Management inbound are reached over private endpoints, with public network access disabled.
  - [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") network policies deny all traffic by default and allow only the flows in `04-deep-dive.md`.
- **Egress control.** Istio runs with `outboundTrafficPolicy: REGISTRY_ONLY`, and ServiceEntries allow only the OpenAI API, the Firebase and Apple push endpoints, and Entra ID. A network policy stops pods from reaching the internet except through the mesh egress gateway. A compromised pod therefore cannot send PHI to an arbitrary host.
- **Functions egress.** `func-analytics` needs no internet access: its subnet's network security group denies outbound internet, and it reaches every store over private endpoints. `func-knowledge` must reach the OpenAI API, and a network security group filters by IP address, not host name, so its outbound [HTTPS](https://datatracker.ietf.org/doc/html/rfc9110 "HTTP Secure — HTTP encrypted with TLS to protect requests and responses in transit") is open. This is a known residual risk, reduced by `func-knowledge` having no grant on any patient data. Evolution trigger: Azure Firewall with host-name rules, if a second function needs internet egress or an audit requires host-level egress control.
- **Workload hardening.** Pod Security Admission runs at the `restricted` level; containers are non-root with read-only root filesystems; Azure Policy for AKS admits only images from ACR; [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") fails a build on critical CVEs in the image.
