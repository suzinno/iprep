# Inputs
- **Project Description:** [INSERT DESCRIPTION]
- **Environment/Tech Stack:** [INSERT TECH STACK]
- **Known Core Responsibilities:** [INSERT RESPONSIBILITIES]

# Instructions
Follow the industry-standard System Design Framework to deliver your analysis. Complete each section thoroughly:

---

## 1. Requirement Clarification & Scoping
Before proposing a design, define the following based on the project context:
* **Target Audience:** Define the primary users (e.g., B2B, B2C, internal).
* **Functional Requirements:** List the top 3-5 core features (must have) the system must support. List the top 3-5 supplementary features (nice to have) the system must support.
* **Non-Functional Requirements:** Define goals for Availability, Latency, Scalability, and Consistency (CAP Theorem positioning).
* **Scale Estimation:** Provide "back-of-the-envelope" estimates for DAU (Daily Active Users), QPS (Queries Per Second), and 5-year storage requirements.

## 2. High-Level Design (HLD)
* **API Design:** Define the primary REST/GraphQL/gRPC endpoints (input parameters and return types).
* **Architecture Diagram:** Describe the high-level flow from Client -> Load Balancer -> Services -> Data Store.
* **Technology Mapping:** Justify how the provided [TECH STACK] (Environment/Tech Stack from Inputs) fits into this architecture. Briefly mention alternatives which could be, but were not chosen, provide reasoning.

## 3. Data Modeling & Storage
* **Schema Design:** Define the core entities and their relationships.
* **Storage Choice:** Explain the partitioning/sharding strategy if applicable to the provided environment.

## 4. Deep Dive & Bottlenecks
* **Communication patterns:** Specify Sync (REST/GraphQL/gRPC) vs. Async (Message Queues/Event-sourcing) flows.
* **Failure Modes:** Identify Single Points of Failure (SPOFs) and how to mitigate them (propose redundancy or failover plans).
* **Trade-offs:** Explain the trade-offs made (e.g., Latency vs. Accuracy or Throughput vs. Cost).

## 5. Reliability & Observability
* **Read/Write Optimizations:** Define indexing strategies (e.g., Composite, TTL, or Full-text) based on specific query patterns.
* **Caching Strategy:** Propose a multi-layer caching approach (CDN, Redis/Memcached, Application-level) and explicit cache invalidation logic (Write-through vs. Cache-aside).
* **Telemetry:** Outline the strategy for the "Three Pillars": Metrics (SLIs/SLOs), Structured Logging, and Distributed Tracing (e.g., OpenTelemetry).
* **Automation:** Outline a CI/CD pipeline and deployment strategy (e.g., Canary or Blue-Green) to ensure system stability.

## 6. Security & Compliance
* **Identity & Access:** Detail Authentication (OAuth2/OIDC) and fine-grained Authorization (RBAC/ABAC) mechanisms.
* **Data Protection:** Specify standards for service-to-service communication - data In-Transit (TLS 1.3/mTLS) and encryption for database volumes and sensitive fields - At-Rest (AES-256).
* **Regulatory/Compliance:** Ensure the design adheres to relevant frameworks based on context (e.g., GDPR for privacy, HIPAA for healthcare, PCI-DSS for payments, etc.).
* **Perimeter Defense:** Implementation of WAF (Web Application Firewall), Rate Limiting, and DDoS protection.

---
# Output Format
Provide the response in a structured, professional report format using Markdown headings and Mermaid.js diagrams (if applicable) for the architecture flow.
