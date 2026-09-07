# Security & Compliance
## Personalized Cancer Support Platform

## Table of Contents
- [Identity & Access](#identity--access)
- [Data Protection](#data-protection)
- [Regulatory Compliance — HIPAA](#regulatory-compliance--hipaa)
- [Perimeter Defense](#perimeter-defense)

---

## Identity & Access

### Authentication — OAuth 2.0 / OIDC

Authentication is handled via **Azure Active Directory B2C** (AAD B2C), providing:
- **Patient login:** Email/password with mandatory MFA (SMS or authenticator app). Social login (Google, Apple) available as convenience — all mapped to a canonical AAD B2C identity.
- **Provider login:** Federated SSO with the healthcare organization's identity provider via OIDC. Enforces the organization's existing MFA and password policies.
- **Admin login:** AAD B2C with Conditional Access policies requiring compliant devices and phishing-resistant MFA (FIDO2).

**Token flow:** AAD B2C issues JWT access tokens (15-min expiry) and refresh tokens (24-hour expiry, rotated on use). Azure API Management validates JWTs on every request before forwarding to backend services. Services never handle raw credentials.

### Authorization — RBAC with Row-Level Scoping

| Role | Permissions | Scope |
|------|-------------|-------|
| `patient` | Read/write own profile, wellbeing, documents, messages. Use AI Assistant. | Own data only (`patient_id` must match JWT `sub` claim) |
| `caregiver` | Read delegated patient's data. Write messages on their behalf. | Delegated patient(s) via `caregiver_delegation` table |
| `provider` | Read assigned patients' profiles, wellbeing, documents. Write messages, appointments, prescriptions. | Assigned patients via `provider_patient_assignment` table |
| `admin` | Manage users, roles, content. View audit logs. No direct PHI access without explicit grant. | Platform-wide, with PHI access requiring break-glass justification |

**Implementation:** FastAPI dependency injection middleware extracts the role and user ID from the JWT and enforces row-level filtering on all database queries. No endpoint returns data outside the caller's authorized scope.

```python
# Simplified authorization dependency
async def get_current_patient(token: JWT = Depends(validate_jwt)):
    if token.role != "patient":
        raise HTTPException(403)
    return token.sub  # patient_id used to scope all queries
```

**Break-glass access:** Admin role can request temporary PHI access for support/compliance cases. Each access is logged to an immutable audit table with justification, reviewer, and expiry time. Alerts fire on any break-glass event.

---

## Data Protection

### In-Transit Encryption

| Path | Protocol | Implementation |
|------|----------|---------------|
| Client <-> API Management | TLS 1.3 | Azure-managed certificate on APIM custom domain. HSTS enforced. |
| APIM <-> AKS Services | mTLS | AKS service mesh (Istio or Linkerd) enforces mutual TLS between all pods. Certificates auto-rotated via cert-manager. |
| Services <-> PostgreSQL | TLS 1.2+ | Azure Database for PostgreSQL enforces encrypted connections. Connection strings include `sslmode=require`. |
| Services <-> Cosmos DB | TLS 1.2+ | Azure-managed, always encrypted. |
| Services <-> Redis | TLS 1.2+ | Azure Cache for Redis with TLS-only access (non-TLS port disabled). |
| Services <-> Milvus | TLS 1.2 | Milvus deployed on AKS with TLS configured via Helm chart. Internal cluster traffic only. |

### At-Rest Encryption

| Data Store | Encryption | Key Management |
|------------|-----------|---------------|
| **PostgreSQL (Azure Database for PostgreSQL)** | AES-256 TDE (Transparent Data Encryption) | Azure Key Vault — customer-managed keys (CMK) for HIPAA compliance. Auto-rotated annually. |
| **Cosmos DB** | AES-256 SSE | Azure Key Vault CMK. |
| **Blob Storage** | AES-256 SSE | Azure Key Vault CMK. |
| **Redis** | AES-256 (Azure-managed) | Microsoft-managed keys (cache is ephemeral; CMK not required for transient data). |
| **Milvus** | AES-256 disk encryption on AKS persistent volumes | Azure Disk Encryption with Key Vault CMK. |

### Field-Level Encryption

Sensitive PHI fields that require additional protection beyond volume encryption:
- `patient.phone_hash` — phone numbers stored as HMAC-SHA256 hashes (lookup-only, not reversible).
- `patient.email` — encrypted at application level using Azure Key Vault SDK before storage. Decrypted only when needed for notifications.
- Conversation content in Cosmos DB — encrypted at the application layer for defense-in-depth (volume encryption + field encryption).

---

## Regulatory Compliance — HIPAA

This platform processes Protected Health Information (PHI) and must comply with HIPAA Security Rule, Privacy Rule, and Breach Notification Rule.

### Technical Safeguards

| HIPAA Requirement | Implementation |
|-------------------|---------------|
| **Access Control (§164.312(a))** | RBAC with row-level scoping (see above). Unique user IDs via AAD B2C. Emergency access via break-glass procedure. |
| **Audit Controls (§164.312(b))** | Immutable audit log in PostgreSQL for all PHI access: who, what, when, from where. Azure Monitor captures infrastructure-level access. Logs retained for 6 years. |
| **Integrity (§164.312(c))** | Database checksums on critical tables. Blob Storage uses MD5 verification on upload. Alembic migrations are version-controlled and peer-reviewed. |
| **Transmission Security (§164.312(e))** | TLS 1.2+ on all channels (see above). mTLS for service-to-service. |
| **Person or Entity Auth (§164.312(d))** | MFA enforced for all user roles. Provider SSO federates with existing hospital identity systems. |

### Administrative Safeguards

- **Business Associate Agreements (BAAs):** Azure provides a HIPAA BAA covering all listed Azure services. Any third-party LLM provider must also sign a BAA — verify that PHI is not used for model training.
- **Risk Assessment:** Annual security risk assessment per §164.308(a)(1). Document in Azure DevOps wiki.
- **Training:** All team members handling PHI complete annual HIPAA training.

### PHI in AI Pipeline

The AI Assistant processes PHI (patient questions about their specific condition). Safeguards:
- Patient conversation data is stored in Cosmos DB with patient-scoped access only (partition key = `patient_id`).
- RAG queries to Milvus use patient-scoped collections for personal documents; medical knowledge queries do not contain PHI.
- LLM provider must be configured to **not retain or train on input data**. Azure OpenAI Service provides this guarantee under the Azure HIPAA BAA. If using a third-party LLM, API calls must use a data processing agreement with equivalent guarantees.
- Prompt injection protection: user input is sanitized and bounded. System prompts include instructions to refuse requests outside the medical support domain.

---

## Perimeter Defense

### Web Application Firewall (WAF)

Azure Front Door WAF (or Azure Application Gateway WAF v2) deployed in front of API Management:
- **OWASP Core Rule Set 3.2** enabled in prevention mode — blocks SQL injection, XSS, command injection, and other OWASP Top 10 attacks.
- **Custom rules:** Block requests with PHI patterns in query strings (e.g., SSN-like patterns in URL parameters). Rate limit by IP per endpoint.
- **Bot protection:** Azure Bot Manager rule set to block known malicious bots while allowing legitimate health information crawlers.

### Rate Limiting

Implemented at two layers for defense-in-depth:

| Layer | Limit | Scope |
|-------|-------|-------|
| **Azure API Management** | 100 req/min per authenticated user; 20 req/min for unauthenticated | Per JWT `sub` claim or client IP |
| **Redis (application-level)** | 10 req/min for AI Assistant per patient | Prevents abuse of expensive LLM calls. Sliding window counter in Redis. |

### DDoS Protection

- **Azure DDoS Protection Standard** enabled on the virtual network containing AKS and APIM. Provides real-time traffic analysis and automatic mitigation for volumetric, protocol, and application-layer attacks.
- **AKS Network Policies:** Calico network policies restrict pod-to-pod communication to only declared dependencies (e.g., Patient Service can reach PostgreSQL and Redis but not Milvus directly).

### Infrastructure Security

- **AKS hardening:** Pod security standards enforced (restricted profile). No privileged containers. Image scanning via Trivy in CI and Azure Defender for Containers at runtime.
- **Secret management:** All secrets (DB connection strings, API keys, encryption keys) stored in Azure Key Vault. Injected into pods via CSI Secret Store driver — never in environment variables or config maps.
- **Network segmentation:** AKS uses private endpoint connections to Azure Database for PostgreSQL, Cosmos DB, Redis, and Blob Storage. No public IP exposure for data tier services.

> **Deep Dive Reference:** LLM prompt injection hardening — beyond input sanitization, evaluate techniques like instruction hierarchy, output filtering, and canary tokens to detect and prevent prompt injection attacks targeting the AI Assistant's medical advice capability. This is a critical attack vector given the healthcare context.
