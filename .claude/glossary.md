# Glossary

Sole owner of what every abbreviation in a generated document expands to, what it is for, and where its official source lives.

Links are written by `.claude/scripts/link-abbreviations.py`, never by hand. It links the **first eligible occurrence per file** — skipping fenced blocks, headings, inline code and existing links — and composes the hover title from context: where the prose already expands the term, the title carries the purpose alone; where it does not, the title carries `Expansion — purpose`. No fact is stated twice.

A term used in a generated document belongs in one of the two tables below. `--check` reports any that is in neither.

## Linked terms

| Term | Expansion | Purpose | Source |
|---|---|---|---|
| ABAC | Attribute Based Access Control | Grants access based on attributes of the subject, resource and environment rather than fixed roles | https://en.wikipedia.org/wiki/Attribute-based_access_control |
| AES-256 | Advanced Encryption Standard with a 256-bit key | Symmetric encryption of data at rest and in transit | https://csrc.nist.gov/pubs/fips/197/final |
| AI | Artificial Intelligence | Software that generates or assists with tasks such as writing code | https://en.wikipedia.org/wiki/Artificial_intelligence |
| AKS | Azure Kubernetes Service | Managed Kubernetes hosting on Azure | https://learn.microsoft.com/en-us/azure/aks/ |
| AMQP | Advanced Message Queuing Protocol | Standardizes reliable message queueing and routing between applications | https://www.amqp.org/ |
| AMQPS | AMQP over TLS | Encrypts an AMQP broker connection in transit | https://www.amqp.org/ |
| AOF | Append Only File | Redis persistence mode that logs every write for durability | https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ |
| API | Application Programming Interface | Defines the contract by which software components exchange requests and data | https://en.wikipedia.org/wiki/API |
| APIM | Azure API Management | Publishes, secures and rate limits APIs behind a managed gateway | https://learn.microsoft.com/en-us/azure/api-management/ |
| APM | Application Performance Monitoring | Gives visibility into request latency, errors and traces in production | https://en.wikipedia.org/wiki/Application_performance_management |
| ASGI | Asynchronous Server Gateway Interface | Standard interface between asynchronous Python web servers and applications | https://asgi.readthedocs.io/en/latest/ |
| Alembic | Alembic | Applies and versions database schema migrations for SQLAlchemy | https://alembic.sqlalchemy.org/en/latest/ |
| ArgoCD | Argo CD | GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository | https://argo-cd.readthedocs.io/en/stable/ |
| B2B | Business to Business | Describes commerce conducted between organizations rather than to individual consumers | https://en.wikipedia.org/wiki/Business-to-business |
| B2C | Business to Consumer | Describes commerce sold directly to individual consumers | https://en.wikipedia.org/wiki/Retail |
| BM25 | Best Matching 25 | Ranking function that scores how relevant a document is to a search query | https://en.wikipedia.org/wiki/Okapi_BM25 |
| BRIN | Block Range Index | Compact PostgreSQL index type suited to large, sequentially correlated tables | https://www.postgresql.org/docs/current/brin.html |
| CAP | Consistency, Availability and Partition tolerance | Names the theorem that a distributed system can guarantee only two of the three during a network partition | https://en.wikipedia.org/wiki/CAP_theorem |
| CDN | Content Delivery Network | Distributes cached content across edge locations to reduce latency | https://en.wikipedia.org/wiki/Content_delivery_network |
| CI | Continuous Integration | Automatically builds and tests code on every change | https://en.wikipedia.org/wiki/Continuous_integration |
| CMK | Customer Managed Key | An encryption key the customer controls rather than the cloud provider | https://learn.microsoft.com/en-us/azure/key-vault/keys/about-keys |
| CONNECT | MQTT CONNECT packet | Opens a client session with the broker and authenticates the client | https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html |
| CSV | Comma Separated Values | Plain text format for exchanging tabular data | https://datatracker.ietf.org/doc/html/rfc4180 |
| CV | Curriculum Vitae | Document summarizing a candidate's work history and qualifications | https://en.wikipedia.org/wiki/Curriculum_vitae |
| CVE | Common Vulnerabilities and Exposures | Public identifier for a known software security flaw | https://www.cve.org/ |
| Celery | Celery | Distributed task queue that runs background and scheduled jobs outside the request cycle | https://docs.celeryq.dev/en/stable/ |
| DAU | Daily Active Users | Count of distinct users who use a product on a given day | https://en.wikipedia.org/wiki/Active_users |
| DDoS | Distributed Denial of Service | Attack that floods a system with traffic from many sources to make it unavailable | https://en.wikipedia.org/wiki/Denial-of-service_attack |
| DICOM | Digital Imaging and Communications in Medicine | Standard for storing and transmitting medical images and related data | https://www.dicomstandard.org/ |
| DPIA | Data Protection Impact Assessment | GDPR process for assessing privacy risk before high-risk data processing | https://gdpr-info.eu/art-35-gdpr/ |
| DSAR | Data Subject Access Request | Request by an individual to see the personal data an organization holds about them | https://gdpr-info.eu/art-15-gdpr/ |
| EAV | Entity Attribute Value | Schema pattern for storing entities whose attributes vary and are not known in advance | https://en.wikipedia.org/wiki/Entity%E2%80%93attribute%E2%80%93value_model |
| EHR | Electronic Health Record | Digital record of a patient's medical history maintained by a provider | https://en.wikipedia.org/wiki/Electronic_health_record |
| ERP | Enterprise Resource Planning | Integrated software that manages an organization's core business processes | https://en.wikipedia.org/wiki/Enterprise_resource_planning |
| FastAPI | FastAPI | Python web framework for building HTTP APIs with async support and automatic schema generation | https://fastapi.tiangolo.com/ |
| Flake8 | Flake8 | Lint tool that checks Python code for style and programming errors | https://flake8.pycqa.org/en/latest/ |
| GDPR | General Data Protection Regulation | EU regulation governing the processing of personal data | https://gdpr-info.eu/ |
| GIL | Global Interpreter Lock | CPython mechanism that lets only one thread execute Python bytecode at a time | https://wiki.python.org/moin/GlobalInterpreterLock |
| GIN | Generalized Inverted Index | PostgreSQL index type suited to values containing multiple keys, such as arrays or text search | https://www.postgresql.org/docs/current/gin.html |
| GUC | Grand Unified Configuration | PostgreSQL's mechanism for setting configuration parameters at the server, session or transaction scope | https://www.postgresql.org/docs/current/config-setting.html |
| GiST | Generalized Search Tree | PostgreSQL index type supporting range and exclusion constraints | https://www.postgresql.org/docs/current/gist.html |
| HA | High Availability | System design goal of remaining operational despite component failure | https://en.wikipedia.org/wiki/High_availability |
| HIPAA | Health Insurance Portability and Accountability Act | US law setting standards for protecting health information | https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 |
| HMAC | Hash based Message Authentication Code | Verifies both the integrity and authenticity of a message using a shared secret key | https://datatracker.ietf.org/doc/html/rfc2104 |
| HPA | Horizontal Pod Autoscaler | Automatically adjusts the number of Kubernetes pod replicas to match load | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| HSTS | HTTP Strict Transport Security | Instructs browsers to only ever connect to a site over HTTPS | https://datatracker.ietf.org/doc/html/rfc6797 |
| HTTP | Hypertext Transfer Protocol | Application protocol used to request and transfer web resources | https://datatracker.ietf.org/doc/html/rfc9110 |
| HTTPS | HTTP Secure | HTTP encrypted with TLS to protect requests and responses in transit | https://datatracker.ietf.org/doc/html/rfc9110 |
| IRIS | InterSystems IRIS | Multi-model database combining a relational surface with globals-based storage | https://docs.intersystems.com/ |
| ISO | International Organization for Standardization | Publishes international standards, including information security management | https://en.wikipedia.org/wiki/International_Organization_for_Standardization |
| ISO-4217 | ISO 4217 | Standardizes three-letter currency codes for unambiguous monetary values | https://www.six-group.com/en/products-services/financial-information/data-standards.html |
| IdP | Identity Provider | Service that authenticates users and issues identity assertions to relying applications | https://en.wikipedia.org/wiki/Identity_provider |
| JSON | JavaScript Object Notation | Lightweight text format for structured data exchange | https://www.json.org/json-en.html |
| JWKS | JSON Web Key Set | Publishes the public keys a party needs to verify a signed token | https://datatracker.ietf.org/doc/html/rfc7517 |
| JWT | JSON Web Token | Compact, signed token format for carrying claims between parties | https://datatracker.ietf.org/doc/html/rfc7519 |
| Kubernetes | Kubernetes | Automates deployment, scaling and management of containerized applications | https://kubernetes.io/ |
| L7 | Layer 7 | The application layer of the OSI model, where content-aware filtering such as a web application firewall operates | https://en.wikipedia.org/wiki/OSI_model |
| MAU | Monthly Active Users | Count of distinct users who use a product within a calendar month | https://en.wikipedia.org/wiki/Active_users |
| MFA | Multi Factor Authentication | Requires more than one form of evidence to verify a user's identity | https://en.wikipedia.org/wiki/Multi-factor_authentication |
| ML | Machine Learning | Algorithms that learn patterns from data rather than following explicit rules | https://en.wikipedia.org/wiki/Machine_learning |
| MQTT | Message Queuing Telemetry Transport | Lightweight publish-subscribe protocol for constrained devices and unreliable networks | https://mqtt.org/ |
| MRN | Medical Record Number | Unique identifier a healthcare provider assigns to a patient's record | https://en.wikipedia.org/wiki/Medical_record |
| MVCC | Multi Version Concurrency Control | Lets readers and writers proceed concurrently by keeping multiple versions of a row | https://www.postgresql.org/docs/current/mvcc.html |
| MongoDB | MongoDB | Document database that stores schema-flexible JSON-like documents | https://www.mongodb.com/docs/ |
| NAT | Network Address Translation | Maps multiple private addresses to a shared public address | https://datatracker.ietf.org/doc/html/rfc3022 |
| NLP | Natural Language Processing | Computational techniques for analyzing and generating human language | https://en.wikipedia.org/wiki/Natural_language_processing |
| NoSQL | Not Only SQL | Describes non-relational databases optimized for flexible schemas or horizontal scale | https://en.wikipedia.org/wiki/NoSQL |
| OAuth2 | OAuth 2.0 | Authorization framework that lets an application access resources on a user's behalf | https://datatracker.ietf.org/doc/html/rfc6749 |
| OIDC | OpenID Connect | Identity layer on top of OAuth 2.0 for authenticating users | https://openid.net/developers/how-connect-works/ |
| ORM | Object Relational Mapper | Maps application objects to relational database rows and queries | https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping |
| OWASP | Open Worldwide Application Security Project | Community effort publishing practices and tools for building secure software | https://owasp.org/ |
| OpenAPI | OpenAPI Specification | Describes an HTTP API's endpoints, schemas and behavior in a machine readable format | https://www.openapis.org/ |
| OpenID | OpenID | Federated identity standard letting a user authenticate once and reuse that identity across sites | https://openid.net/ |
| PCI-DSS | Payment Card Industry Data Security Standard | Security requirements for organizations that handle payment card data | https://www.pcisecuritystandards.org/ |
| PDF | Portable Document Format | Fixed-layout document format for reliable printing and viewing | https://en.wikipedia.org/wiki/PDF |
| PHI | Protected Health Information | Individually identifiable health data that HIPAA regulates | https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160/subpart-A/section-160.103 |
| PITR | Point in Time Recovery | Restores a database to a specific past moment using base backups and archived logs | https://www.postgresql.org/docs/current/continuous-archiving.html |
| PKCE | Proof Key for Code Exchange | Protects an OAuth authorization code exchange for clients that cannot hold a secret | https://datatracker.ietf.org/doc/html/rfc7636 |
| POS | Point of Sale | The system and moment at which a retail transaction is completed | https://en.wikipedia.org/wiki/Point_of_sale |
| POST | HTTP POST | HTTP method that submits data to a server to create or process a resource | https://datatracker.ietf.org/doc/html/rfc9110 |
| PSD2 | Revised Payment Services Directive | EU regulation governing payment services and strong customer authentication | https://finance.ec.europa.eu/regulation-and-supervision/financial-services-legislation/implementing-and-delegated-acts/payment-services-directive_en |
| PSP | Payment Service Provider | Third party that processes card and payment transactions on a merchant's behalf | https://en.wikipedia.org/wiki/Payment_service_provider |
| PUBACK | MQTT PUBACK packet | Confirms receipt of a QoS 1 published message | https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html |
| Poetry | Poetry | Python dependency and packaging tool that manages, builds and publishes projects | https://python-poetry.org/docs/ |
| PostgreSQL | PostgreSQL | Relational database storing and querying structured data with strong transactional guarantees | https://www.postgresql.org/docs/current/ |
| PromQL | Prometheus Query Language | Queries and aggregates time series metrics collected by Prometheus | https://prometheus.io/docs/prometheus/latest/querying/basics/ |
| Pydantic | Pydantic | Python library that validates and parses data against typed models at runtime | https://docs.pydantic.dev/latest/ |
| QPS | Queries Per Second | Throughput measure of how many requests a system serves each second | https://en.wikipedia.org/wiki/Queries_per_second |
| QoS | Quality of Service | Delivery guarantee level, such as MQTT's at-most-once, at-least-once and exactly-once modes | https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html |
| RBAC | Role Based Access Control | Grants permissions to users based on assigned roles rather than individually | https://en.wikipedia.org/wiki/Role-based_access_control |
| REST | Representational State Transfer | Architectural style for stateless, resource-oriented HTTP APIs | https://en.wikipedia.org/wiki/REST |
| RFC | Request For Comments | Numbered document series that defines internet standards and protocols | https://www.rfc-editor.org/ |
| RFP | Request For Proposal | Formal solicitation inviting vendors to bid on a project | https://en.wikipedia.org/wiki/Request_for_proposal |
| RLS | Row Level Security | Restricts which rows a database query can see or modify based on the current user | https://www.postgresql.org/docs/current/ddl-rowsecurity.html |
| RPO | Recovery Point Objective | Maximum acceptable amount of data loss, measured in time since the last recovery point | https://en.wikipedia.org/wiki/Disaster_recovery |
| RS256 | RSA Signature with SHA-256 | Asymmetric signing algorithm commonly used to sign JWTs | https://datatracker.ietf.org/doc/html/rfc7518 |
| RTO | Recovery Time Objective | Maximum acceptable duration to restore a system after a disruption | https://en.wikipedia.org/wiki/Disaster_recovery |
| RabbitMQ | RabbitMQ | Message broker that routes and queues messages between producers and consumers | https://www.rabbitmq.com/docs |
| Redis | Redis | In-memory data store used as a cache and fast key-value store | https://redis.io/docs/latest/ |
| SAQ-A | Self-Assessment Questionnaire A | Lightest PCI-DSS compliance tier for merchants who fully outsource card data handling | https://www.pcisecuritystandards.org/document_library/ |
| SAS | Shared Access Signature | Time-limited token granting scoped access to an Azure Storage resource | https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview |
| SCIM | System for Cross-domain Identity Management | Standardizes automated provisioning and deprovisioning of user identities between systems | https://scim.cloud/ |
| SDK | Software Development Kit | Packaged set of tools and libraries for building against a platform | https://en.wikipedia.org/wiki/Software_development_kit |
| SHA-256 | Secure Hash Algorithm 256-bit | Produces a fixed-size digest used to verify content integrity | https://csrc.nist.gov/pubs/fips/180-4/upd1/final |
| SHA256 | Secure Hash Algorithm 256-bit | Produces a fixed-size digest used to verify content integrity | https://csrc.nist.gov/pubs/fips/180-4/upd1/final |
| SLI | Service Level Indicator | Measured metric, such as latency or error rate, used to judge service health | https://sre.google/sre-book/service-level-objectives/ |
| SLO | Service Level Objective | Target value for a service level indicator that a service commits to meet | https://sre.google/sre-book/service-level-objectives/ |
| SMS | Short Message Service | Delivers short text messages over a mobile network | https://en.wikipedia.org/wiki/SMS |
| SPA | Single Page Application | Web application that updates its content in place without full page reloads | https://en.wikipedia.org/wiki/Single-page_application |
| SPOF | Single Point of Failure | A component whose failure alone can bring down the whole system | https://en.wikipedia.org/wiki/Single_point_of_failure |
| SQL | Structured Query Language | Queries and manipulates data in a relational database | https://en.wikipedia.org/wiki/SQL |
| SQLAlchemy | SQLAlchemy | Python SQL toolkit and ORM that maps objects to relational tables and builds queries | https://www.sqlalchemy.org/ |
| TLS | Transport Layer Security | Encrypts and authenticates data sent over a network connection | https://datatracker.ietf.org/doc/html/rfc8446 |
| TPS | Transactions Per Second | Throughput measure of how many transactions a system completes each second | https://en.wikipedia.org/wiki/Transaction_processing |
| TTL | Time To Live | Duration after which a cached or stored value expires | https://en.wikipedia.org/wiki/Time_to_live |
| Terraform | Terraform | Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files | https://developer.hashicorp.com/terraform/docs |
| UK | United Kingdom | Names the jurisdiction whose data protection regime applies alongside the EU's | https://en.wikipedia.org/wiki/United_Kingdom |
| URL | Uniform Resource Locator | Addresses the location and access method of a resource on the web | https://datatracker.ietf.org/doc/html/rfc3986 |
| W3C | World Wide Web Consortium | Develops open web standards such as trace context propagation | https://www.w3.org/ |
| WAF | Web Application Firewall | Filters and blocks malicious HTTP traffic before it reaches an application | https://owasp.org/www-community/Web_Application_Firewall |
| WORM | Write Once Read Many | Storage mode that prevents a written object from being modified or deleted before a retention period ends | https://en.wikipedia.org/wiki/Write_once_read_many |
| XML | Extensible Markup Language | Markup format for structured, machine and human readable documents | https://www.w3.org/XML/ |
| XSS | Cross Site Scripting | Attack that injects malicious script into content viewed by other users | https://owasp.org/www-community/attacks/xss/ |
| ZRS | Zone Redundant Storage | Replicates Azure storage data synchronously across multiple availability zones | https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy |
| AP | Available and Partition tolerant | Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency | https://en.wikipedia.org/wiki/CAP_theorem |
| CP | Consistent and Partition tolerant | Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability | https://en.wikipedia.org/wiki/CAP_theorem |
| ER | Entity Relationship | Models entities and the relationships between them as a precursor to a relational schema | https://en.wikipedia.org/wiki/Entity%E2%80%93relationship_model |
| ES | Elasticsearch | Distributed search and analytics engine used to index and query documents | https://www.elastic.co/elasticsearch |
| GC | Garbage Collection | Automatically reclaims memory no longer reachable by a running program | https://en.wikipedia.org/wiki/Garbage_collection |
| RU | Request Unit | Azure Cosmos DB's currency for provisioned throughput, charged per request regardless of operation type | https://learn.microsoft.com/en-us/azure/cosmos-db/request-units |

## Deliberately not linked

| Term | Reason |
|---|---|
| CPU | universally known; a link would be clutter |
| GPU | universally known; a link would be clutter |
| RAM | universally known; a link would be clutter |
| GB | universally known; a link would be clutter |
| TB | universally known; a link would be clutter |
| MB | universally known; a link would be clutter |
| KB | universally known; a link would be clutter |
| ID | universally known; a link would be clutter |
| DB | universally known; a link would be clutter |
| UI | universally known; a link would be clutter |
| UX | universally known; a link would be clutter |
| IP | universally known; a link would be clutter |
| IT | universally known; a link would be clutter |
| EU | universally known; a link would be clutter |
| US | universally known; a link would be clutter |
| CD | only ever appears inside the compound CI/CD, never standalone prose |
| SHA | only ever appears inside the compound build-SHA, never standalone prose |
