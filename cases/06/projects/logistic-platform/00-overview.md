# Logistics Platform for Transport Management and Analytics

*System design overview*

## Executive Summary

An enterprise platform that manages transport orders, routes, delivery statuses and carrier interaction, and turns that operational data into reconciled analytics. Operational traffic runs through `tms-api` on [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees"), while external carriers send messages to `carrier-gateway`, which keeps every raw payload in the existing Oracle hub. A nightly Python-orchestrated, [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database")-driven consolidation conforms internal, carrier and file data into a PostgreSQL star schema and rebuilds sixteen data marts. Data-quality checks and three-layer reconciliation must pass before the marts are published to Power [BI](https://en.wikipedia.org/wiki/Business_intelligence "Business Intelligence — Tools and practices that turn stored business data into reports and dashboards for decisions") and Tableau. A second, near-real-time path carries status events through [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") into a "deliveries today" table within minutes, and is explicitly unreconciled. Every correction is an audited overlay, every mapping is versioned in metadata tables, and every [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") has exactly one SQL definition shared by both BI tools.

## Sections

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Audience, core and supplementary features, SLOs, the two consistency tiers, volume and storage estimates |
| [02-high-level-design.md](02-high-level-design.md) | Component names, [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") endpoints, the architecture diagram, technology mapping and stack gaps |
| [03-data-modeling.md](03-data-modeling.md) | Operational schema, raw payload store, star schema, the sixteen marts, metadata and quality tables, partitioning |
| [04-deep-dive.md](04-deep-dive.md) | Sync and async flows, the near-real-time latency budget, nightly consolidation, KPI SQL, reconciliation, change safety, failure modes, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes, legacy query tuning, caching and invalidation, telemetry and SLOs, release pipeline, backup and recovery |
| [06-security.md](06-security.md) | Trust boundaries, authentication and roles, encryption, personal data and jurisdiction, perimeter controls |

## Tech Stack

| Technology | Role |
|---|---|
| Python | `tms-api`, `carrier-gateway`, `quality-api`, `nrt-loader`; orchestration in `consolidation-runner`; checks in `quality-runner` |
| SQL | Every transformation, mart definition, data-quality rule and reconciliation query |
| PostgreSQL | `tms_db` (operational system of record, with `tms_db_replica`); `analytics_dwh` (staging, core star schema, marts, near-real-time table, quality and metadata) |
| Oracle | `ext_hub` — raw carrier payloads in [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"); payload profiling with Oracle JSON functions |
| RabbitMQ | Exchange `logistics.events`: carrier intake buffer (`tms.carrier-status`) and domain events for analytics (`analytics.nrt`) |
| Power BI | Management dashboards for cost, [SLA](https://en.wikipedia.org/wiki/Service-level_agreement "Service Level Agreement — Commitment between a provider and its customer on measurable service targets, such as delivery time") and KPIs; import-mode datasets, DirectQuery for the near-real-time page, row-level security by region |
| Tableau | Operations analysts' workbooks on delivery, vehicle load and routes |
| [AWS](https://aws.amazon.com/ "Amazon Web Services — Cloud provider whose managed compute, storage and messaging services host a system") [RDS](https://aws.amazon.com/rds/ "Amazon Relational Database Service — Managed hosting for relational databases such as PostgreSQL, with backups and failover") | Managed hosting for `tms_db`, `analytics_dwh` and `ext_hub` |
| AWS [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") | `lp-landing` (carrier files, nightly extracts) and `lp-archive` (snapshots and expired partitions) |
| AWS CloudWatch | Metrics, [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet") alarms, structured logs |
| AWS, added (stack gaps) | [ECS](https://aws.amazon.com/ecs/ "Amazon Elastic Container Service — Managed container orchestration on AWS; with Fargate it runs containers without managing servers") Fargate for services and jobs, EventBridge Scheduler for the nightly run, [WAF](https://owasp.org/www-community/Web_Application_Firewall "Web Application Firewall — Filters and blocks malicious HTTP traffic before it reaches an application") with a load balancer, Amazon MQ as the RabbitMQ host, Secrets Manager, [KMS](https://aws.amazon.com/kms/ "AWS Key Management Service — Creates and controls the keys that encrypt data at rest, and logs every use") |
| Jira, Confluence | Task tracking and release records; Confluence mapping pages generated from `meta` tables |

## Requirement Traceability

Each responsibility is quoted as `inputs.txt` states it; the numbering follows its order.

| # | Responsibility | Addressed in |
|---|---|---|
| 1 | Сопровождение изменений в отчётности при обновлении источников и структуры аналитических витрин; | `04-deep-dive.md` — Changing Sources and Mappings Safely; `05-reliability.md` — blue-green marts |
| 2 | Формирование Source-to-Target Mapping для консолидации данных из транспортных и внутренних систем; | `03-data-modeling.md` — `meta.sttm_mapping`; `04-deep-dive.md` — versioned mappings |
| 3 | Описание data lineage, структуры показателей и зависимостей между источниками и отчётными витринами; | `03-data-modeling.md` — `meta.lineage_edge`; `02-high-level-design.md` — `GET /quality/v1/lineage` |
| 4 | Разработка 15+ Data Marts для анализа перевозок, доставки, загрузки транспорта, SLA и операционной эффективности; | `03-data-modeling.md` — Data Marts: sixteen marts on shared dimensions, rebuilt nightly |
| 5 | Подготовка сложных SQL-запросов с [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement"), оконными функциями и агрегациями для расчёта логистических показателей; | `04-deep-dive.md` — Calculating Logistics KPIs in SQL |
| 6 | Разработка дашбордов в Power BI и Tableau для мониторинга доставки, затрат, SLA и ключевых операционных KPI; | `02-high-level-design.md` — Technology Mapping, one KPI definition; `05-reliability.md` — caching and refresh |
| 7 | Автоматизация ежедневной консолидации и подготовки больших объёмов транспортных данных с использованием Python; | `04-deep-dive.md` — Nightly Consolidation |
| 8 | Реализация Python-проверок для сверки данных между источниками, аналитическими витринами и итоговой отчётностью; | `04-deep-dive.md` — Reconciliation: `source_core`, `core_mart`, `mart_report` |
| 9 | Настройка контроля качества данных: полнота, уникальность, корректность справочников и контроль расхождений; | `03-data-modeling.md` — `meta.dq_rule`, `dq.check_result`; `04-deep-dive.md` — blocking and warning checks |
| 10 | Проведение reconciliation по заказам, маршрутам, статусам доставки и расчётным показателям; | `04-deep-dive.md` — Reconciliation, `recon_key` examples |
| 11 | Анализ и оптимизация унаследованных SQL-запросов PostgreSQL для операционной и аналитической отчётности; | `05-reliability.md` — Optimizing Legacy Report Queries |
| 12 | Оптимизация структуры PostgreSQL-витрин и запросов для ускорения формирования регулярных отчётов; | `05-reliability.md` — indexes, mart structure; `03-data-modeling.md` — partitioning |
| 13 | Использование Oracle для анализа гибких данных, поступающих от внешних транспортных систем; | `03-data-modeling.md` — `ext_hub`; `04-deep-dive.md` — Profiling carrier payloads in Oracle |
| 14 | Подготовка данных для near-real-time отчётности через RabbitMQ и асинхронные процессы; | `04-deep-dive.md` — Near-Real-Time Path |
| 15 | Анализ расхождений между данными перевозчиков и внутренними системами, подготовка корректирующих решений; | `04-deep-dive.md` — carrier discrepancies; `03-data-modeling.md` — `core.data_correction` |
| 16 | Тестирование отчётности после изменений источников, mapping-логики и расчётных правил; | `04-deep-dive.md` — KPI regression; `05-reliability.md` — integration stage |
| 17 | Автоматизация регулярных проверок и контрольных сверок на Python, сокращающая объём ручной работы; | `04-deep-dive.md` — `quality-runner` inside the nightly flow; `05-reliability.md` — alerts replace manual review. The brief gives no figure for the reduction |
| 18 | Участие в подготовке релизов аналитической отчётности и проверке показателей после внедрения изменений; | `05-reliability.md` — Automation and Release, steps 3 and 6 |
| 19 | Ведение задач и технической документации в Jira и Confluence. | **No architectural implication** — process tooling. The one design link: Confluence mapping pages are generated from `meta` |

The only quantified outcome in the brief is "15+ data marts"; the design names sixteen in `03-data-modeling.md`. No other responsibility states a number, so no latency or percentage in this design comes from the brief. All of them are targets derived in `01-requirements.md`.
