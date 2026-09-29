# Requirement Clarification & Scoping

*[AI](https://en.wikipedia.org/wiki/Artificial_intelligence "Artificial Intelligence — Software that generates or assists with tasks such as writing code") Conversational Recruitment & Candidate Matching Ecosystem*

## Table of Contents

- [Target Audience](#target-audience)
- [Functional Requirements](#functional-requirements)
- [Non-Functional Requirements](#non-functional-requirements)
- [Scale Estimation](#scale-estimation)
- [Assumptions and Open Questions](#assumptions-and-open-questions)

---

## Target Audience

The platform is **[B2B](https://en.wikipedia.org/wiki/Business-to-business "Business to Business — Describes commerce conducted between organizations rather than to individual consumers") first, with a [B2C](https://en.wikipedia.org/wiki/Retail "Business to Consumer — Describes commerce sold directly to individual consumers") side**. Employers pay for it; candidates use it for free.

| Group | Who | How they use the platform |
|---|---|---|
| Employer users (B2B) | Recruiters, hiring managers and org admins in client companies | Build job descriptions in a chat, review ranked shortlists, move applicants through stages |
| Candidates (B2C) | Job seekers, plus applicants imported from a client's legacy systems | Build a profile in a chat instead of a form, upload a [CV](https://en.wikipedia.org/wiki/Curriculum_vitae "Curriculum Vitae — Document summarizing a candidate's work history and qualifications"), see matching jobs, apply |
| Enterprise identity owners | The client's IT team | Connect their Active Directory through [SAML](https://docs.oasis-open.org/security/saml/v2.0/ "Security Assertion Markup Language — XML standard an identity provider uses to pass sign-in assertions to an application") 2.0 single sign-on |
| Internal operators | Platform operations engineers and the security team | Watch platform health and threat dashboards in Splunk, on desktop and on Splunk Mobile |

Enterprise clients sign in through their own identity provider. This is why SAML 2.0, [SSO](https://en.wikipedia.org/wiki/Single_sign-on "Single Sign-On — Lets a user sign in once with one identity provider and reach several applications") and Active Directory appear in the stack. Candidates sign in with email or a social login and can turn on [TFA](https://en.wikipedia.org/wiki/Multi-factor_authentication "Two-Factor Authentication — Requires a second proof of identity besides a password at sign-in").

## Functional Requirements

### Core features (must have)

1. **Conversational job description builder.** A recruiter describes a role in natural language. The assistant asks follow-up questions and fills a structured job draft (title, must-have skills, seniority, location, salary band) while the recruiter talks. The recruiter confirms the draft, and it becomes a job.
2. **Conversational candidate profile builder.** A candidate talks about their experience. The assistant fills a structured profile draft and asks about gaps. The candidate confirms the profile and gives consent for matching.
3. **Real-time streaming dialogue.** Assistant replies stream token by token over a WebSocket. The draft panel next to the chat updates as the system evaluates each answer.
4. **[RAG](https://en.wikipedia.org/wiki/Retrieval-augmented_generation "Retrieval-Augmented Generation — Grounds a model's answer in documents retrieved at query time")-based matching.** For a published job, the system retrieves candidates whose profile text and dialogue answers fit the requirements. An [LLM](https://en.wikipedia.org/wiki/Large_language_model "Large Language Model — Neural network trained on text that generates and interprets natural language") reranks the top candidates and explains each score with cited evidence. Candidates see matching jobs for their own profile.
5. **Bulk import of legacy applicant data.** A recruiter uploads a legacy export ([CSV](https://datatracker.ietf.org/doc/html/rfc4180 "Comma Separated Values — Plain text format for exchanging tabular data") or Excel, optionally with CV files). The system cleans, deduplicates and indexes it so those applicants can be matched too.

### Supplementary features (nice to have)

1. Pipeline management: application stages, notes and shortlist export.
2. Resume of an interrupted chat on another device, including a reply that was still streaming.
3. Per-tenant job description library, so the assistant can suggest wording from the tenant's past approved jobs.
4. Match explanations a recruiter can rate, fed back into prompt evaluation.
5. Operational and security alerts on Splunk Mobile for on-call staff.

## Non-Functional Requirements

| Property | Target | Notes |
|---|---|---|
| Availability | 99.9% monthly for the [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") and WebSocket connect (about 43 min of downtime per month) | Measured at the edge. [OpenAI](https://platform.openai.com/docs/ "OpenAI — Provides GPT models through an API and official SDKs") outages are tracked in a separate chat turn success [SLO](https://sre.google/sre-book/service-level-objectives/ "Service Level Objective — Target value for a service level indicator that a service commits to meet"), because the platform cannot control them |
| Chat turn success | 99.5% of turns complete without a user-visible error | Includes retries against the LLM provider |
| Time to first token | p95 ≤ 1.5 s from user message to first streamed token | Budget is summed in `04-deep-dive.md` |
| Draft update | p95 ≤ 3 s after the reply finishes | Extraction runs next to the reply, not inside it |
| REST latency | Reads p95 ≤ 300 ms, writes p95 ≤ 500 ms | At API Gateway, excluding match runs |
| Match run | p95 ≤ 60 s for one job against the full pool | Asynchronous; the UI polls for the result |
| Index freshness | p95 ≤ 60 s from profile confirmation to searchable | Bulk imports must not break this |
| Scalability | Horizontal for all stateless services; ten times today's load without a redesign | Evolution triggers are named in `03` and `05` |
| Durability | [RPO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Point Objective — Maximum acceptable amount of data loss, measured in time since the last recovery point") 5 min, [RTO](https://en.wikipedia.org/wiki/Disaster_recovery "Recovery Time Objective — Maximum acceptable duration to restore a system after a disruption") 1 h inside the region; RPO and RTO 24 h for loss of the whole region | Single-region design, see `04-deep-dive.md` |

**Consistency and [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") positioning.**

- **Domain records are [CP](https://en.wikipedia.org/wiki/CAP_theorem "Consistent and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay strictly consistent under a network partition at the cost of availability").** Jobs, applications, profiles and consent live in [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") on one primary. A write is either committed or rejected. During a network partition, writes fail rather than diverge.
- **Conversation state is read strongly consistent.** [DynamoDB](https://aws.amazon.com/dynamodb/ "Amazon DynamoDB — Managed key-value and document database with single-digit-millisecond reads and writes") is [AP](https://en.wikipedia.org/wiki/CAP_theorem "Available and Partition tolerant — Names the CAP-theorem choice a subsystem makes to stay available under a network partition at the cost of strict consistency") by design, but the chat engine reads a conversation with strongly consistent reads on the base table. A reconnect therefore never sees an older turn list.
- **The search index is eventually consistent.** A confirmed profile becomes searchable within the freshness target. Consent is never read from the index: withdrawal takes effect at once, because the matching engine checks consent in PostgreSQL for every result (see `04-deep-dive.md`).
- **Events are at-least-once.** Duplicates are expected, and consumers remove them. There is no exactly-once promise.

## Scale Estimation

The brief states no figures. The brief uses words like "massive", "high-throughput" and "instantaneous", but gives no numbers. All numbers below are **design assumptions** for a mid-sized platform. They are not results the brief reports.

| Input | Assumption |
|---|---|
| Employer tenants | 300 companies, 3,000 recruiter seats |
| Candidate pool | 2.0 M profiles at launch (1.5 M from legacy imports), plus 0.5 M per year, so 4.5 M after 5 years |
| [DAU](https://en.wikipedia.org/wiki/Active_users "Daily Active Users — Count of distinct users who use a product on a given day") | 1,500 recruiters + 20,000 candidates ≈ 21,500 |
| Conversations | 10,000 candidate chats × 15 turns + 1,500 recruiter chats × 20 turns = 180,000 turns per day |
| Peak factor | 5× the daily average, because use concentrates in business hours |

A **turn** is one user message plus one assistant reply.

| Metric | Derivation | Result |
|---|---|---|
| Chat turns | 180,000 / 86,400 s × 5 | ≈ 11 turns/s at peak |
| OpenAI calls | 11 × (reply + extraction + indexing embedding + 0.4 retrieval embedding) | ≈ 40 calls/s at peak |
| Chat model tokens | 11 × ~3,250 tokens per reply × 60 | ≈ 2.1 M tokens per minute at peak |
| Concurrent WebSockets | 12% of DAU online at peak | ≈ 2,600 sockets |
| REST [QPS](https://en.wikipedia.org/wiki/Queries_per_second "Queries Per Second — Throughput measure of how many requests a system serves each second") | Lists, drafts, match polling, pipeline actions | ≈ 60 req/s average, 300 req/s peak |
| Recruiter match runs | 1,000 per day, each reranking 50 candidates in 5 LLM calls | 5,000 rerank calls per day |
| Candidate "jobs for me" | 20,000 per day, retrieval only, no LLM | ≈ 1 req/s peak |

**5-year storage.**

| Store | Calculation | 5-year size |
|---|---|---|
| DynamoDB `conversations` | 360,000 items per day × 1.5 KB, kept 180 days after last activity | ≈ 100 GB steady state |
| PostgreSQL relational rows | 4.5 M candidates × 8 KB + 1.5 M jobs × 10 KB + 20 M applications × 0.5 KB + 12 months of match results | ≈ 70 GB |
| PostgreSQL vectors | 4.5 M candidates × 5 chunks × (2 KB vector + 1 KB text), plus the [HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") index | ≈ 120 GB |
| [S3](https://aws.amazon.com/s3/ "Amazon Simple Storage Service — Durable object storage for files, datasets and archives") | CV files at 12 GB per month, legacy CV files ≈ 300 GB, import files ≈ 100 GB | ≈ 1.1 TB |
| Langfuse traces | ≈ 3.6 GB per day, kept 30 days | ≈ 110 GB |
| Splunk ingest | Platform logs and audit ≈ 5 GB per day, network security events ≈ 15 GB per day | ≈ 20 GB per day of licence |

> **Verify Before Build:** About 2.1 M chat-model tokens per minute at peak, plus extraction and embedding traffic — check these against the OpenAI organization's rate-limit tier for each model before launch, because a tier below this turns peak hours into 429 errors.

The vector estimate assumes 512-dimension embeddings. At 1,536 dimensions it would triple (see the trade-off in `04-deep-dive.md`). The network-event volume is the security team's number to confirm, because [FMC](https://www.cisco.com/c/en/us/support/security/defense-center/series.html "Cisco Secure Firewall Management Center — Central console that configures Cisco firewalls and streams their intrusion and connection events") and [SNA](https://www.cisco.com/c/en/us/support/security/stealthwatch/series.html "Cisco Secure Network Analytics — Analyses network flow telemetry to detect threats and unusual host behaviour") volumes depend on firewall rules this design does not own.

## Assumptions and Open Questions

- **Jurisdiction.** The design assumes EU and US candidates. This makes [GDPR](https://gdpr-info.eu/ "General Data Protection Regulation — EU regulation governing the processing of personal data") and the EU AI Act high-risk rules apply (see `06-security.md`).
- **Firewall placement.** The brief says FMC events reach Splunk and that external APIs sit in a [DMZ](https://csrc.nist.gov/glossary/term/demilitarized_zone "Demilitarized Zone — Network zone that holds internet-facing components and separates them from internal networks"). This design assumes the Cisco firewalls that FMC manages inspect traffic entering and leaving the DMZ. The security team owns where they physically sit.
- **Splunk ownership.** Splunk Enterprise belongs to the security team. The platform sends data to it and does not run it.
- **Claude Code and Gemini** are read as developer tools used to build the platform. They have no runtime role. If Gemini was a runtime model, `04-deep-dive.md` names the fallback design it would fit.
- **Team size.** About 8–12 engineers. This rules out running more stateful systems than the brief lists without a clear reason.
