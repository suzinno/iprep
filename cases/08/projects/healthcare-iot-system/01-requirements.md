# Requirement Clarification & Scoping

*Smart Healthcare System ([IoT](https://en.wikipedia.org/wiki/Internet_of_things "Internet of Things — Networked physical devices that report telemetry and receive commands over constrained links"))*

## Table of Contents

- [Context and Assumptions](#context-and-assumptions)
- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Out of Scope](#out-of-scope)

## Context and Assumptions

The platform collects vital signs from bedside medical devices across a group of hospitals, detects deterioration, and notifies the right clinical staff in time to intervene. Around that core sit three supporting capabilities named by the brief: a transport robot fleet, a [ChatGPT](https://openai.com/chatgpt/ "ChatGPT — OpenAI's conversational large language model product")-based assistant over a corpus of expert recommendations, and file storage for clinical images.

The brief leaves several facts open. Each assumption below drives later decisions and is stated so it can be challenged.

| Open point | Assumption used in this design | Where it matters |
|---|---|---|
| Size of the hospital group | 4 hospitals, ~2,000 beds, ~1,200 beds under continuous monitoring at any time | All capacity numbers below |
| Device connectivity | Bedside devices connect to a ward **edge gateway** (one per ward, ~40 in total); devices never talk to the cloud directly | `02` ingest path, `06` device identity |
| Role of the platform in alarming | Bedside monitors keep their own local alarms. The platform is a **secondary, remote notification** layer, not the primary alarm | Availability targets, `04` failure modes |
| "Transfer across hospitals" for the robot | Robots guide or carry patients and visitors between departments across a hospital campus. They do not travel between separate hospital sites | `02` robot-service, `03` robotics schema |
| Chatbot corpus | Curated clinical guidelines and expert recommendations, uploaded by designated editors. It holds no patient records | `06` data protection, `04` trade-offs |
| Jurisdiction | Not stated. [HIPAA](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-160 "Health Insurance Portability and Accountability Act — US law setting standards for protecting health information") is the baseline; [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") applies in addition wherever EU residents' data is processed | `06` compliance |
| Quantified outcomes | The responsibilities contain no percentages, latencies or volumes. Every number in this design is a design target, not a claim taken from the brief | All files |

## Target Audience

- **Internal, [B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers").** Hospital staff are the only human users. There is no patient-facing app in scope.
- **Nurses** watch ward dashboards and receive alerts on a mobile app; they acknowledge and escalate.
- **Physicians and rapid-response teams** receive escalated alerts and review vital-sign trends.
- **Ward managers and administrators** configure beds, devices, alert thresholds and staff rosters.
- **Knowledge editors** curate the expert-recommendation corpus used by the assistant.
- **Porters and transport coordinators** request robot missions and follow their progress.
- **Machine clients:** ward edge gateways (telemetry upload) and transport robots (mission pull and heartbeats).

## Functional Requirements

### Core (must have)

1. **Continuous vital-sign ingestion.** Edge gateways upload heart rate, oxygen saturation ([SpO2](https://en.wikipedia.org/wiki/Pulse_oximetry "Peripheral oxygen saturation — Percentage of haemoglobin carrying oxygen, measured by a pulse oximeter")), respiratory rate, blood pressure and temperature every second, with store-and-forward during network loss.
2. **Deterioration detection.** Each reading is evaluated against per-patient thresholds and the National Early Warning Score ([NEWS2](https://www.rcp.ac.uk/improving-care/resources/national-early-warning-score-news-2/ "National Early Warning Score 2 — Scores routine vital signs to detect clinical deterioration in adult patients")). Rules can require a condition to persist for a set time to suppress artefacts.
3. **Staff notification and escalation.** An alert is pushed to the on-duty nurses for the ward. If nobody acknowledges it within the configured time, it escalates to the next level.
4. **Live ward dashboard and patient trends.** Latest vitals per bed, open alerts, and trend charts at 1-second, 1-minute and 1-hour resolution.
5. **Patient, bed and device management.** Admissions, bed assignment, binding a device to a bed, alert thresholds, and staff ward assignments.

### Supplementary (nice to have)

1. **Expert assistant.** A chatbot that answers clinical-guideline questions with citations, plus a fast passage search over the same corpus.
2. **Transport robot missions.** Staff request a transport; the platform assigns an idle robot and tracks the mission.
3. **Clinical file storage.** Wound photos, scans and documents attached to a patient, uploaded directly to Blob Storage.
4. **Deterioration risk score.** An Azure Machine Learning model scores each monitored patient every 15 minutes and raises an advisory alert above a threshold.
5. **Admission sync from the hospital [EHR](https://en.wikipedia.org/wiki/Electronic_health_record "Electronic Health Record — Digital record of a patient's medical history maintained by a provider")** over [FHIR](https://hl7.org/fhir/ "Fast Healthcare Interoperability Resources — Healthcare standard for exchanging clinical records through REST APIs"), replacing manual admission entry. Not designed in detail here.

## Non-Functional Requirements

| Quality | Target | Reasoning |
|---|---|---|
| Availability — alert path (ingest → notify) | 99.9% monthly (≤ 43 min downtime) | Bedside alarms stay primary, so a short platform outage delays remote notification but does not silence alarms. Zone redundancy in one region reaches this without active-active regions |
| Availability — staff APIs and dashboards | 99.9% monthly | Same infrastructure as the alert path |
| Availability — assistant and robot APIs | 99.5% monthly | Not on the clinical alert path; depends on an external [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") |
| Latency — alert delivery | p95 ≤ 5 s from gateway receipt to handoff to the push provider; 99.9% within 30 s | Budget is summed in `04-deep-dive.md` |
| Latency — dashboard | Latest vitals p95 < 100 ms; other reads p95 < 300 ms; alert visible on dashboard p95 ≤ 8 s | Latest values come from [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") |
| Latency — assistant | Passage search p95 < 300 ms; full answer p95 ≤ 8 s, first streamed token ≤ 2 s | LLM generation dominates |
| Scalability | Linear growth by adding wards or hospitals; 3× current load without redesign | Stateless services and queue-based workers scale horizontally |
| Durability | Clinical records and alerts: [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") ≤ 5 min on region loss, 0 on zone loss. Raw telemetry: no loss while a gateway buffer holds the data | `04` disaster recovery |
| Consistency | See [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning below | |

**CAP positioning.**

- **Clinical records, alerts, acknowledgements — [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability").** One [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") primary with a synchronous standby in another zone. Two nurses must never both believe they own an alert, so a write that cannot reach the primary fails rather than diverges.
- **Raw telemetry and latest values — [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency").** Gateways keep buffering and the platform accepts data during partial failures. Readers may see values a few seconds old, which the dashboard shows as a data-age indicator.
- Under [PACELC](https://en.wikipedia.org/wiki/PACELC_design_principle "Partition, Availability, Consistency, Else Latency, Consistency — Extends CAP by naming the latency against consistency trade that applies when there is no partition"), the telemetry path trades consistency for latency even without a partition. The alert state path does not.

## Scale Estimation

**Users.** ~3,000 clinical and support staff; **~2,000 [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day")**; ~400 dashboard sessions open at peak.

**Telemetry.**

- 1,200 monitored beds × 1 frame/s = **1,200 frames/s**, ~5 signals per frame, ~100 bytes per frame.
- 40 gateways × 1 upload/s = **40 ingest requests/s**, each ~30 frames (~3 KB).
- ~10.4 GB/day of raw frames before storage overhead.

**API traffic (peak).**

| Source | Rate |
|---|---|
| Ward dashboards polling latest vitals every 3 s | ~135 req/s |
| Alert feed polling every 5 s | ~80 req/s |
| Other staff reads and writes | ~20 req/s |
| Gateway ingest | 40 req/s |
| Robots (20 robots: heartbeat every 5 s, mission long-poll) | ~15 req/s |
| Assistant (~300 questions/day) | < 1 req/s, but each answer holds a connection for up to 8 s |
| **Total at the edge, with 2× peak headroom** | **~600 req/s** |

**Alerts and notifications.** ~5,000 alerts/day across the group; ~15,000 push notifications/day including escalations.

**5-year storage.**

| Data | Retention in hot store | 5-year volume | Store |
|---|---|---|---|
| Raw telemetry (hot) | 30 days | ~450 GB steady state | Cosmos DB |
| Raw telemetry (archive) | 5 years+ | ~1.8 TB (Parquet, ~10:1 compression) | Blob Storage, cool then archive tier |
| 1-minute rollups | 90 days | ~25 GB steady state | PostgreSQL |
| 1-hour rollups | 5 years | ~8 GB | PostgreSQL |
| Clinical records, alerts, missions | 5 years | ~25 GB | PostgreSQL |
| Access audit log | 13 months in database; 6 years in archive | ~30 GB hot; ~15 GB archived (Parquet) | PostgreSQL, then Blob Storage |
| Knowledge corpus (5,000 documents, ~500k chunks with embeddings) | Current versions | ~4 GB | PostgreSQL |
| Clinical images and files (~2,000/day × 3 MB) | 30 days hot, then cool/cold | **~11 TB** | Blob Storage |

The dominant cost is image storage, not telemetry. PostgreSQL stays below ~200 GB, which fits one General Purpose server with room to grow. The audit volume assumes coalesced access events (one per user, resource and 15-minute window), explained in `06-security.md`; logging every dashboard poll would produce ~11 million rows a day.

## Out of Scope

- The bedside devices' own alarm logic, and the robot's onboard navigation and obstacle avoidance. The platform sends a robot a destination, never motion commands.
- A patient-facing application.
- Replacing the hospital EHR. Only the optional FHIR admission sync touches it.
- Clinical validation of thresholds and the risk model, which is a clinical-governance process, not an architecture decision.
