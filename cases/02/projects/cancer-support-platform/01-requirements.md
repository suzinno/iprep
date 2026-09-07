# 1. Requirement Clarification & Scoping
## Personalized Cancer Support Platform

**Table of Contents**

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Explicit Scope Boundaries](#explicit-scope-boundaries)

---

## Target Audience

The platform serves two populations with opposing access models, and that asymmetry drives most of the design.

| Audience | Type | Volume | Access model |
|---|---|---|---|
| **Patients** diagnosed with cancer | B2C | ~250K registered over 5 years | Self-registered into the patient portal; sees only their own record |
| **Clinicians** (oncologists, nurse specialists) | B2B | ~3.5K seats | Provisioned from the hospital directory via SCIM 2.0; sees patients they have a care relationship with |
| **Care-team coordinators** | B2B | ~400 seats | Directory-provisioned; manages care-team membership and appointment logistics |
| **Clinical content authors** | Internal | ~30 seats | Directory-provisioned; authors and approves guidance that the NLP pipeline may draw on |
| **Platform operators** | Internal | ~15 seats | Directory-provisioned; no routine access to patient data (break-glass only) |

Clinician accounts originate in the hospital's Azure Entra ID tenant and are **never** valid on the patient portal — the two identity planes are separate audiences enforced at the gateway (see [`06-security.md`](./06-security.md)). A clinician who leaves the trust loses platform access through directory deprovisioning, not through a manual step in this product.

## Functional Requirements

### Must have

1. **Daily wellbeing diary.** A patient records a structured check-in (symptom scores, treatment side effects, free text, adherence confirmation). Check-ins are accepted off the request path so a flaky mobile connection never loses one.
2. **Unified clinical record and timeline.** Appointments, prescriptions, visit notes, and uploaded documents (scans, letters) presented as one chronological timeline, identical in substance for the patient and their care team.
3. **Diagnosis- and treatment-specific education.** Guidance pages assembled for the patient's diagnosis, treatment line, and stage from a clinician-approved corpus, with visible provenance.
4. **Clinical content search.** Full-text and filtered search across visit notes, guidance, and visit history, scoped to what the requester is entitled to see, so neither patient nor clinician scans a whole record to find one fact.
5. **Appointment and check-in reminders.** Scheduled, delivered asynchronously, with delivery receipts — a missed reminder is a clinical safety issue, not a UX annoyance.
6. **Directory-driven identity.** SCIM 2.0 provisioning of clinician and care-team accounts from Azure Entra ID, with OAuth2/OIDC JWT authentication.

### Nice to have

1. **Care-team messaging** — asynchronous, record-attached messages between patient and named care team.
2. **Trend surfacing** — flagging a sustained deterioration in check-in scores to the care team.
3. **Document auto-classification** — routing an uploaded letter or scan report to the right record slot without manual filing.
4. **Multi-language guidance** — the same approved source content rendered per locale.
5. **Patient-facing data export** — a portable copy of the record on request.

## Non-Functional Requirements

| Dimension | Target | Rationale |
|---|---|---|
| **Availability** | 99.9% monthly for record read/write and diary capture; 99.5% for search and content generation | Record access is the product; search and generation degrade to a usable fallback (chronological browse, previously published page) rather than an outage |
| **Latency** | Timeline read p95 < 120 ms (cached) / < 250 ms (cold); search p95 < 400 ms; write p95 < 300 ms; education page generation p95 < 45 s (asynchronous, never on the request path) | Clinicians open a timeline mid-consultation; a 2 s load is the behaviour the product exists to remove |
| **Reminder timeliness** | Delivered within ±2 min of the scheduled window, p99 < 5 min late | The reminder pipeline's whole justification is reliability, not speed |
| **Scalability** | Horizontal on stateless services; vertical + read replicas on `pg-clinical` until the documented evolution triggers below | Peak load is ~200 QPS — this is not a sharding-scale system, and pretending otherwise buys operational cost for nothing |
| **Consistency** | **CP for the clinical record.** `pg-clinical` is the single source of truth; a clinician's write is read-your-writes for every party on the next read. **AP/eventual for derived views** — `es-clinical` search index lag p50 < 8 s, p95 < 15 s, p99 < 30 s (budget itemised in `05-reliability.md`), content pages eventually consistent on publish | A stale search hit is recoverable; a lost prescription write is not. The record refuses to trade correctness for availability |
| **Durability** | RPO 5 min, RTO 30 min for `pg-clinical`; RPO 0 for accepted check-ins (durable on the broker before acknowledgement) | Health record loss is not commercially or legally survivable |
| **Auditability** | Every read and write of patient data recorded, retained 7 years, immutable | Regulatory floor, not a feature |

**CAP positioning.** Under a partition, the record layer chooses consistency and returns `503` rather than serving a possibly-stale prescription or accepting a write it cannot durably order. The diary ingest path chooses availability — a check-in is accepted onto the broker and acknowledged before it is projected into `pg-clinical`, because losing a patient's symptom entry to a partition is worse than showing it a few seconds late.

## Scale Estimation

Back-of-the-envelope figures below are the baseline every capacity decision in `02`–`05` is proportional to.

**Users**

- 250K registered patients over 5 years; ~60K monthly-active (patients leave the platform as treatment concludes)
- 25K patient DAU + 2.5K clinician DAU

**Request volume**

| Source | Calculation | Result |
|---|---|---|
| Patient API calls | 25K DAU × 4 sessions × 15 calls | 1.5M/day |
| Clinician API calls | 2.5K DAU × 200 calls | 0.5M/day |
| **Total** | | **~2.0M/day → 23 QPS average** |
| Business-hours concentration | 70% of traffic in an 8-hour window | ~50 QPS sustained |
| **Peak (clinic hours)** | 4× the in-window average | **~200 QPS sustained, ~400 QPS burst** |
| Check-in ingest burst | 25K check-ins, most between 07:00–09:00 | ~50 msg/s peak on MQTT |

**5-year storage**

| Store | Calculation | Size |
|---|---|---|
| `pg-clinical` — check-ins | 60K active × 1/day × 365 × 5 ≈ 110M rows × ~1 KB | ~110 GB + ~40 GB indexes |
| `pg-clinical` — visit notes | 60K × 8/yr × 5 = 2.4M × 4 KB | ~10 GB |
| `pg-clinical` — appointments + prescriptions | 6M + 4.5M rows | ~12 GB |
| `pg-clinical` — audit events | ~1M/day (the PHI-touching subset of 2.0M API calls; health checks, static content and unauthenticated routes are not audited) × 1825 = 1.8B × 300 B | ~550 GB (13 months retained hot ≈ 110 GB; older archived to `blob-documents`) |
| **`pg-clinical` hot total** | | **~1.0 TB** |
| `mongo-content` | ~500K page versions + templates + NLP extractions | ~120 GB |
| `es-clinical` | 2.4M notes + 500K pages, ~3× source with per-field indexing | ~150 GB |
| `redis-cache` | working set of hot timelines, sessions, counters | ~24 GB |
| `blob-documents` | 250K patients × ~25 documents × 1.5 MB + audit archive | **~12 TB** |

**Evolution triggers.** A single `pg-clinical` primary with two read replicas carries this comfortably. Revisit only when sustained write throughput exceeds ~3K TPS or the primary's hot volume exceeds 4 TB — at which point the first move is extracting `audit_event` and `wellbeing_checkin` to their own instance, **not** sharding the record by patient.

> **Deep Dive Reference:** Audit volume dominance — audit events outweigh all clinical data combined by roughly 5:1. Before build, validate the real per-session event count against a clinical pilot; a factor-of-two error here changes the storage plan more than any other single assumption.

## Explicit Scope Boundaries

Out of scope, stated so the design is not read as claiming them: no diagnostic or triage decision support; no e-prescribing or order entry (prescriptions are recorded, not issued); no DICOM imaging viewer (imaging *reports* are stored as documents, pixel data is not); no billing or claims; no direct EHR write-back — the hospital directory is consumed via SCIM, but clinical integration is one-way import in this iteration.
