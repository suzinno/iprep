# Requirement Clarification & Scoping
## Personalized Cancer Support Platform

## Table of Contents
- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation (Back-of-the-Envelope)](#scale-estimation-back-of-the-envelope)

---

## Target Audience

| Segment | Description |
|---------|-------------|
| **Primary — Cancer Patients (B2C)** | Individuals from point of diagnosis seeking reliable information, treatment tracking, and wellbeing monitoring. |
| **Secondary — Healthcare Providers** | Oncologists, nurses, and care coordinators who review patient-reported data and communicate through the platform. |
| **Tertiary — Platform Administrators** | Internal ops and clinical content teams managing medical knowledge bases, user accounts, and compliance audits. |

---

## Functional Requirements

### Core Features (Must Have)

1. **Personalized Diagnosis & Treatment Information** — Deliver curated, condition-specific content using RAG (Retrieval-Augmented Generation) over a verified medical knowledge base. Content is tailored to the patient's cancer type, stage, and treatment plan.
2. **Daily Wellbeing Tracker** — Patients log symptoms, mood, side effects, and vitals daily. Data is stored longitudinally for trend analysis and shared with providers on consent.
3. **Medical Records Vault** — Centralized storage for appointments, prescriptions, lab results, doctor's notes, and uploaded documents (PDFs, images). Accessible from a single patient dashboard.
4. **AI Conversational Assistant** — LangChain/LangGraph-powered chatbot that answers patient questions with citations from the knowledge base, respects conversation context, and escalates to human support when confidence is low.
5. **Provider Communication Hub** — Secure messaging between patients and care teams, with structured summaries of recent wellbeing data attached to conversations.

### Supplementary Features (Nice to Have)

1. **Appointment Reminders & Medication Alerts** — Push/email notifications triggered by upcoming events.
2. **Treatment Timeline Visualization** — Interactive timeline showing past and upcoming treatments, milestones, and wellbeing trends.
3. **Community Support Groups** — Moderated forums connecting patients with similar diagnoses.
4. **Data Export for Second Opinions** — FHIR-compatible export of medical records.
5. **Caregiver Access** — Delegated read/write access for family members or caregivers.

---

## Non-Functional Requirements

| Requirement | Target | Rationale |
|-------------|--------|-----------|
| **Availability** | 99.9% uptime SLO (< 8.76 h downtime/year) | Patients depend on the platform for time-sensitive medical information; downtime erodes trust. |
| **Latency** | p95 < 300 ms for API responses; p95 < 2 s for AI assistant first-token | Standard UX threshold for interactive applications; streaming mitigates perceived AI latency. |
| **Scalability** | Horizontal scaling to 10x baseline load within 15 minutes | Oncology awareness campaigns and media coverage can cause traffic spikes. |
| **Consistency** | Strong consistency for medical records and prescriptions; eventual consistency acceptable for wellbeing analytics and AI conversation history | Medical data correctness is non-negotiable (CP positioning for critical paths); analytics can tolerate short lag. |
| **Compliance** | HIPAA (PHI handling), SOC 2 Type II | Healthcare data in the US; platform stores and processes Protected Health Information. |

---

## Scale Estimation (Back-of-the-Envelope)

**Assumptions:** Mid-stage product targeting a national oncology network (~50 partner clinics).

| Metric | Estimate | Derivation |
|--------|----------|------------|
| **Registered Users** | ~100,000 patients | ~50 clinics x ~2,000 active patients each |
| **DAU** | ~15,000 | ~15% daily engagement rate (chronic condition = high engagement) |
| **Peak QPS (API)** | ~500 req/s | 15K DAU x ~20 requests/session x 2 sessions/day, concentrated in 8-hour window. Peak = ~3x average. |
| **AI Assistant QPS** | ~50 req/s peak | ~30% of active users engage the assistant; queries are longer-running but lower volume. |
| **Write QPS** | ~80 req/s peak | Wellbeing logs, document uploads, message sends. |
| **Storage (5-year)** | ~12 TB | ~100K users x (5 KB/day wellbeing data x 1825 days) + ~50 KB avg documents x 20 docs/user + conversation history (~10 MB/user). Blob storage for documents dominates. |
| **Vector Store** | ~5 M vectors | Medical knowledge base (~500K articles x 10 chunks avg) |

> **Deep Dive Reference:** Storage growth modeling — actual document sizes (DICOM images, pathology reports) could push blob storage significantly higher. A lifecycle policy analysis is warranted before production.
