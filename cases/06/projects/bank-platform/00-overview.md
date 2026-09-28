# Overview

**Project:** Банковская платформа управления ликвидностью и финансовой аналитики (bank liquidity management and financial analytics platform)

## Table of Contents

- [Executive Summary](#executive-summary)
- [Sections](#sections)
- [Tech Stack and Roles](#tech-stack-and-roles)
- [Requirement Traceability](#requirement-traceability)

## Executive Summary

An on-premise treasury and finance analytics slice of a bank's Greenplum [DWH](https://en.wikipedia.org/wiki/Data_warehouse "Data Warehouse — Central store that integrates historical data from many sources for reporting and analysis"). Nightly extracts and intraday [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") events land in a staging layer, Greenplum stored procedures consolidate 500K+ records a day into conformed history and calculate 20+ marts for cash positions, liquidity, cash flow and financial KPIs, and 25+ Power [BI](https://en.wikipedia.org/wiki/Business_intelligence "Business Intelligence — Tools and practices that turn stored business data into reports and dashboards for decisions") and Superset reports read them through one view per report. A [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") control plane runs the job graph, holds reconciliation results, field mappings, [KPI](https://en.wikipedia.org/wiki/Performance_indicator "Key Performance Indicator — Measurable value that tracks how well an operation meets its targets") definitions and approved adjustments, and enforces the publication gate: a business date becomes visible only when every blocking reconciliation rule passes. The design's central choices are thin BI (all KPI logic in [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database"), so two BI tools share one definition), idempotent per-date rebuilds (so a 99.9% run success rate comes from safe retries), a per-report parallel run for the legacy-mart migration, and physical plus logical Greenplum tuning behind the ~40% report-time reduction.

## Sections

| File | Covers |
|---|---|
| [01-requirements.md](01-requirements.md) | Assumptions, audience, functional and non-functional requirements, scale estimates |
| [02-high-level-design.md](02-high-level-design.md) | Component names, architecture, the four interface contracts, technology mapping, stack gaps |
| [03-data-modeling.md](03-data-modeling.md) | Greenplum layers and marts, the `ctl` control plane, distribution and partitioning |
| [04-deep-dive.md](04-deep-dive.md) | Communication patterns, daily and intraday paths, the 40% bottleneck, migration, failure modes, trade-offs |
| [05-reliability.md](05-reliability.md) | Indexes, workload isolation, caching, telemetry, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") |
| [06-security.md](06-security.md) | Identity, per-component grants, data protection, regulation, perimeter |

## Tech Stack and Roles

- **Python** — `stg-loader` (Kafka consumer), `etl-runner` (scheduler and executor), `recon-checker` (reconciliation), `lineage-publisher`, migration runner, analysts' spot checks.
- **SQL** — all calculation logic: `core.load_*` and `dm.build_*` stored procedures, `rpt` views, reconciliation rule queries, impact-analysis CTEs.
- **Greenplum** — `gp-dwh`: `stg`, `core`, `dm`, `dm_legacy`, `rpt` layers; [MPP](https://en.wikipedia.org/wiki/Massively_parallel "Massively Parallel Processing — Splits one query across many nodes that each process their own slice of the data at the same time") builds and report queries; resource groups for workload isolation.
- **PostgreSQL** — `pg-ctl`: `ctl` control plane with trigger-enforced rules (four-eyes adjustments, publication gate, migration gate, audit) and `superset_meta` (Superset metadata and data cache).
- **Kafka** — intraday transport on `fin.postings.v1` and `fin.acct-balance.v1`.
- **Power BI** — Power BI Report Server: treasury and finance reports on import models refreshed after each publish.
- **Apache Superset** — operational control, intraday position and platform health dashboards; SQL Lab for analysts.
- **on-premise** — every component on bank infrastructure; no cloud service.
- **GitLab** — repository for SQL, Python, rules, mappings, BI artefacts and adjustments; CI/CD with data-diff regression; merge-request approval as the four-eyes control.
- **Jira** — change and discrepancy tickets, referenced by key from `ctl.recon_break`, `ctl.source_change` and `ctl.adjustment`.
- **Confluence** — lineage and data-flow pages generated by `lineage-publisher`.
- **Codex, Claude Code** — developer tools; no role in the running system.

## Requirement Traceability

Responsibilities are quoted as `inputs.txt` states them.

| # | Responsibility | Addressed in |
|---|---|---|
| 1 | Анализ изменений в системах-источниках и оценка их влияния на действующую отчётность и DWH; | `04-deep-dive.md` — Source Change Impact Analysis; `03-data-modeling.md` — `ctl.source_change`, `ctl.field_mapping`, `ctl.object_dependency` |
| 2 | Перенос 25+ финансовых отчётов на обновлённые аналитические витрины с сохранением непрерывности регламентных процессов; | `04-deep-dive.md` — Report Migration Without a Missed Delivery; `02-high-level-design.md` — `rpt` view contract |
| 3 | Сопоставление полей и бизнес-показателей между источниками и целевыми витринами для формирования единой структуры данных; | `03-data-modeling.md` — `ctl.field_mapping`, `ctl.kpi_definition`, layer principles |
| 4 | Описание data lineage, источников показателей и межсистемных зависимостей в Confluence; | `02-high-level-design.md` — `lineage-publisher`; `03-data-modeling.md` — `ctl.object_dependency`. The writing itself is process; the design's part is generating pages from the registry |
| 5 | Разработка и сопровождение 20+ Data Marts для ликвидности, денежных позиций, cash flow и финансовых KPI; | `03-data-modeling.md` — `dm` marts |
| 6 | Подготовка аналитических SQL-запросов с [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement"), оконными функциями и сложными агрегациями для расчёта отчётных показателей; | `04-deep-dive.md` — Bottleneck, logical design; `02-high-level-design.md` — SQL role |
| 7 | Разработка Power BI и Apache Superset дашбордов для treasury, финансовых подразделений и операционного контроля; | `02-high-level-design.md` — architecture, thin-BI rule, technology mapping; `05-reliability.md` — caching |
| 8 | Моделирование DWH и Data Marts: проектирование структуры витрин, слоёв хранения и расчётной логики; | `03-data-modeling.md` |
| 9 | Автоматизация ежедневной консолидации 500K+ финансовых записей из нескольких источников; | `04-deep-dive.md` — Daily Consolidation and Publication; `01-requirements.md` — scale |
| 10 | Реализация Python-проверок для автоматической сверки данных между источниками, DWH и отчётными витринами; | `02-high-level-design.md` — `recon-checker`; `03-data-modeling.md` — `ctl.recon_rule`, `ctl.recon_result`; `04-deep-dive.md` — publication gate |
| 11 | Оптимизация Greenplum-витрин с использованием распределения данных, партиционирования и настройки запросов, сократившая время формирования ключевых отчётов на ~40%; | `04-deep-dive.md` — Bottleneck, physical design; `03-data-modeling.md` — distribution and partitioning. Same ~40% as row 14 |
| 12 | Разработка хранимых процедур и триггеров для расчётной логики и регламентных операций; | `02-high-level-design.md` — processing contract; `03-data-modeling.md` — `ctl` triggers |
| 13 | Анализ и оптимизация унаследованных SQL-запросов и логики расчёта финансовых показателей; | `04-deep-dive.md` — Bottleneck, logical design |
| 14 | Оптимизация структуры витрин и SQL-логики, сократившая время формирования ключевых отчётов на ~40%; | `04-deep-dive.md` — Bottleneck. Same ~40% as row 11: one outcome with two groups of causes, not two savings to add |
| 15 | Настройка приёма данных из Kafka в staging-слой для формирования отчётности с минимальной задержкой; | `02-high-level-design.md` — `stg-loader`, topic contract; `04-deep-dive.md` — intraday latency budget |
| 16 | Валидация отчётности на уровне репортов: сверка контрольных сумм, проверка показателей после изменений источников и расчётной логики; | `03-data-modeling.md` — `ctl.report_control_total`; `04-deep-dive.md` — `HISTORY` rule; `05-reliability.md` — regression stage |
| 17 | Анализ причин расхождений и подготовка корректирующих решений совместно с командами DWH и систем-источников; | `03-data-modeling.md` — `ctl.recon_break`, `ctl.adjustment`; `05-reliability.md` — adjustments as code. The cross-team work is process |
| 18 | Контроль стабильности регулярных загрузок и отчётных процессов с уровнем успешного выполнения 99.9%+; | `04-deep-dive.md` — Run Success at 99.9%; `05-reliability.md` — SLIs and alerting |
| 19 | Использование Python и SQL для точечных проверок, анализа больших наборов данных и подготовки корректировок; | Mostly process. Architectural implication only: `grp_analyst` grants (`06-security.md`) and the `rg_adhoc` resource group (`05-reliability.md`) |
| 20 | Использование Codex и Claude Code для анализа SQL, ускорения подготовки запросов и документации с последующей ручной проверкой результатов; | No architectural implication — developer tooling |
| 21 | Ведение задач и изменений в Jira, подготовка технической документации и описаний data flows в Confluence. | No architectural implication — process; Jira keys are stored in `ctl` only as references |
