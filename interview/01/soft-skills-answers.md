# Soft Skills — Interview Answers

---

### Q1. Where in the project were you responsible for a critical part of a system? Also for ensuring the quality and reliability under pressure. Tell about those critical parts.

**Brief answer**
I owned the RAG pipeline and the database layer for our cancer support platform — both were critical because patients depended on accurate, timely medical information and any downtime or incorrect retrieval directly impacted care quality.

<details>
<summary><strong>Detailed answer</strong></summary>

On the personalized cancer support platform, I was responsible for several critical subsystems that had to work reliably under pressure:

**RAG pipeline and conversational agents.** I designed the memory and context management strategies for our LangChain/LangGraph-based conversational agents that helped patients understand their diagnosis and treatment options. This was high-stakes because the system served medical information — hallucinations or retrieval failures weren't just bugs, they were patient safety risks. I combined LangChain pipelines with Milvus for semantic search and built asynchronous, event-driven execution flows in LangGraph to keep the pipeline scalable. Reliability meant implementing proper fallback chains, embedding validation layers, and monitoring retrieval quality metrics through Azure Monitor.

**Database design and performance.** I designed the overall schema for PostgreSQL and Azure SQL, and was the go-to person for optimizing large, complicated SQL statements. When we hit slow response times under growing patient load, I profiled stored procedures, identified missing indexes and suboptimal joins, and brought query times down significantly. This was pressure-driven work — the clinical team would flag sluggish dashboards, and I had to diagnose and fix in the same day.

**Cache invalidation strategy.** I developed the cache invalidation approach using Redis to ensure data consistency. In a healthcare context, stale data (e.g., outdated prescriptions or appointment info) is dangerous, so the invalidation logic had to be airtight. I designed it around event-driven triggers so that writes to the database would propagate cache evictions predictably.

**Quality assurance under pressure.** I configured pre-commit hooks to enforce code quality standards, wrote unit and integration tests, and set up CI/CD pipelines in Azure DevOps and GitHub Actions. When deployment issues occurred — and they did, especially around AKS networking — I was the one diagnosing pipeline failures and getting services back online. The combination of automated quality gates and hands-on incident response is how I maintained reliability across these critical systems.

</details>

---

### Q2. Specify which AIs and which tools exactly did you use for the development process and as components within the system.

**Brief answer**
For development I used Cursor (with Claude as the backing model) daily for code analysis, refactoring, and generation. As system components, we integrated OpenAI and Azure OpenAI models through LangChain and LangGraph for our RAG pipeline, with Milvus as the vector store.

<details>
<summary><strong>Detailed answer</strong></summary>

**AI tools in the development process:**

- **Cursor** — my primary AI-assisted IDE. I used it extensively for analyzing existing codebases, identifying bottlenecks, and suggesting optimizations. It was especially valuable for navigating unfamiliar parts of the codebase and generating boilerplate for FastAPI routers, Pydantic models, and SQLAlchemy mappings. I always validated and refined the AI-generated code to ensure compliance with our project standards and performance requirements — I never merged AI output without review.
- **Claude** — used both through Cursor and directly (via Claude Code CLI) for more complex tasks: designing database schemas, reasoning about cache invalidation strategies, reviewing architectural decisions, and writing thorough test cases.

**AI as system components:**

- **Azure OpenAI / OpenAI API** — the Large Language Model (LLM) backbone for our conversational agents. We used GPT-4-class models for generating patient-facing responses about diagnosis and treatment information.
- **LangChain** — the orchestration framework for building our Retrieval-Augmented Generation (RAG) pipeline. It handled prompt templating, chain composition, document loading, text splitting, and embedding generation.
- **LangGraph** — used for implementing asynchronous, event-driven execution flows. This gave us stateful, multi-step agent workflows with proper branching and error handling — more control than simple LangChain chains.
- **Milvus** — our vector database for semantic search. Patient-relevant medical documents were embedded and stored in Milvus, and the RAG pipeline queried it for context retrieval before generating responses.
- **Redis** — while not an AI tool per se, it played a critical role in caching LLM responses and managing session context for the conversational agents, reducing latency and API costs.

The key distinction I maintain: AI tools accelerate my development workflow, but I remain accountable for every line that ships. For system components, the AI models are treated like any external dependency — monitored, tested, and wrapped in error handling.

</details>

---

### Q3. Provide an example of a disagreement that you had with another engineer or product owner or a team member and how did you resolve it.

**Brief answer**
I disagreed with a teammate about whether to use a managed vector database (Pinecone) versus self-hosted Milvus for our RAG pipeline. I resolved it by preparing a comparison with concrete numbers on cost, latency, and operational overhead, then presenting it to the team so we could decide based on data rather than preference.

<details>
<summary><strong>Detailed answer</strong></summary>

During the cancer support platform project, we needed to choose a vector store for our RAG pipeline. A colleague advocated strongly for Pinecone because of its managed nature — zero operational overhead, simple API, and fast onboarding. I pushed for Milvus because we were already running on Azure Kubernetes Service (AKS) and I was concerned about data residency (healthcare data), vendor lock-in, and the recurring cost at our projected embedding volume.

The disagreement got heated in a design review because both sides had valid points. Rather than digging in, I proposed we take a step back and evaluate objectively. I spent a day building a comparison matrix covering: hosting cost at our projected scale, query latency benchmarks, data sovereignty compliance, integration complexity with our existing LangChain pipeline, and operational burden (who pages when it's down at 2 AM).

I shared the matrix in our next sync and walked through each dimension. The data showed that Milvus running in our existing AKS cluster was significantly cheaper at scale and kept patient data within our Azure tenant — a hard requirement we'd almost overlooked. My colleague's concerns about operational burden were valid, so we agreed to invest in proper Helm charts, monitoring dashboards in Azure Monitor, and runbooks.

**What I learned:** disagreements are usually about incomplete information, not bad intentions. By shifting from opinion to evidence, I removed the personal element. I also made sure to incorporate my colleague's valid concern (operational complexity) into the final solution rather than dismissing it. The result was a better architecture than either of us had proposed individually.

</details>

---

### Q4. Task with unclear requirements — a one-liner telling you to do something (with no acceptance criteria, no real value). How do you proceed?

**Brief answer**
I don't start coding. I write down my assumptions, define what "done" looks like, and bring that back to the requester for confirmation before touching any code.

<details>
<summary><strong>Detailed answer</strong></summary>

When I get a vague one-liner — say, "add patient export feature" with no further context — I follow a consistent approach:

**1. Resist the urge to just build something.** The worst outcome is spending days building the wrong thing. A 20-minute conversation saves 20 hours of rework.

**2. Write down my assumptions.** I draft a short document (even a Slack message) that captures: what I think this feature does, who uses it, what the happy path looks like, and what edge cases I can already foresee. For example: "I'm assuming 'patient export' means exporting a patient's appointment and prescription history as a PDF, triggered from the dashboard, available to the patient and their assigned clinician. Unclear: file format, data scope, access control, performance expectations for large histories."

**3. Propose acceptance criteria.** I write 3-5 concrete criteria like: "Given a patient with 100+ appointments, the export completes in under 5 seconds," or "The export excludes soft-deleted records." This forces specificity.

**4. Bring it back to the requester.** I schedule a quick sync or send the assumptions asynchronously. The key question is: "Does this match what you had in mind, or am I off track?" Nine times out of ten, the requester says "oh, I actually meant something simpler" or "you're missing this critical constraint."

**5. Timebox if I can't reach the requester.** If the person is unavailable and there's time pressure, I build the smallest possible version that's easy to extend, document my assumptions in the PR description, and flag it for review.

On our cancer support project, this came up regularly. The clinical team would request features in medical terminology that didn't translate directly to technical requirements. I learned that investing in clarification upfront — even when it felt slow — consistently led to faster delivery because we avoided rework cycles.

</details>

---

### Q5. How to balance speed and quality? You have a tight deadline so you have to make a decision of which one to prioritize. How do you handle this: delivery vs. quality? What is your negotiation approach?

**Brief answer**
I identify which quality trade-offs are reversible (and therefore acceptable under time pressure) versus which ones create long-term damage, then negotiate scope — not standards — with stakeholders.

<details>
<summary><strong>Detailed answer</strong></summary>

My framework for this is: **never compromise on correctness, negotiate on scope and polish.**

**What I won't cut:**
- Tests for critical paths (in our case, anything touching patient data or the RAG pipeline's retrieval accuracy)
- Security and data validation (especially in a healthcare context — this is non-negotiable)
- Basic error handling on external boundaries (API calls to Azure OpenAI, database connections)

**What I will defer:**
- Comprehensive edge-case coverage for non-critical flows
- Performance optimization beyond "acceptable" (optimize later when you have production metrics)
- UI polish, detailed logging, admin tooling
- Refactoring code that works but isn't elegant

**My negotiation approach:**

1. **Make the trade-off visible.** I don't just say "we need more time." I say: "We can ship features A, B, and C by Friday with full test coverage and proper error handling. Feature D requires an additional 3 days. Alternatively, we can ship A-D by Friday but without integration tests for C and D, which means we're accepting risk of regressions in the next sprint." Decision-makers respect concrete options over vague pushback.

2. **Propose a phased delivery.** Ship a solid MVP on time, then iterate. On our project, we did this with the RAG pipeline — the first release supported basic Q&A retrieval. Conversational memory and multi-turn context came in the next sprint. Both the product owner and clinical team preferred a reliable partial feature over a buggy complete one.

3. **Document the debt.** If we do cut corners, I create explicit tech debt tickets with context about what was deferred and why. This prevents the "we'll fix it later" amnesia that turns shortcuts into permanent liabilities.

4. **Protect the team.** If the pressure is coming from above, I push back on behalf of the team. I've found that saying "the team can deliver X by the deadline with confidence, or X+Y with significant risk" reframes the conversation from "are you fast enough" to "what level of risk is acceptable."

The underlying principle: speed and quality aren't opposites. The fastest path is usually the one with the fewest surprises, and quality practices like testing and clear interfaces reduce surprises. The real negotiation is about scope.

</details>
