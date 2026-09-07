# Soft Skills — Interview Answers

---

### Q1. Where in the project were you responsible for a critical part of a system? Also for ensuring the quality and reliability under pressure. Tell about those critical parts.

**Brief answer**
I owned the RAG pipeline and the database layer for our cancer support platform — both were critical because patients depended on accurate, timely medical information and any downtime or incorrect retrieval directly impacted care quality.

<details>
<summary><strong>Detailed answer</strong></summary>

On the personalized cancer support platform, I was responsible for several critical subsystems that had to work reliably under pressure:

**RAG pipeline and conversational agents.** I designed the memory and context management strategies for our LangChain/LangGraph-based conversational agents. This is a very critical feature of the system that helped patients understand their diagnosis and treatment options. So, this was high-stakes because the system served medical information — hallucinations or retrieval failures weren't just bugs, they were patient safety risks.
I combined LangChain pipelines with Milvus for semantic search and built asynchronous, event-driven execution flows in LangGraph to keep the pipeline scalable. Reliability meant implementing proper fallback chains, embedding validation layers, and monitoring retrieval quality metrics through Azure Monitor.

**Database design and performance.** I designed the overall schema for PostgreSQL and Azure SQL, and worked on optimizing large, complicated SQL statements. When we hit slow response times under growing patient load, I profiled stored procedures, identified suboptimal joins and found places missing indexes. That helped me to bring query times down significantly.

**Cache invalidation strategy.** I developed the cache invalidation approach using Redis to ensure data consistency. In a healthcare context, stale data (e.g., outdated prescriptions or appointment info) is dangerous, so the invalidation logic had to be perfect. I designed it around event-driven triggers so that writes to the database would propagate cache evictions predictably.

**Quality assurance under pressure.** I configured pre-commit hooks to enforce code quality standards, wrote unit and integration tests, and set up CI/CD pipelines in Azure DevOps and GitHub Actions. When deployment issues occurred — and they did, especially around AKS networking — I was the one diagnosing pipeline failures and getting services back online. The combination of automated quality gates and hands-on incident response is how I maintained reliability across these critical systems.

</details>

---

### Q2. Specify which AIs and which tools exactly did you use for the development process and as components within the system.

**Brief answer**
For development I used Claude (with Sonnet as the backing model) daily for code analysis, refactoring, and generation.
For fast research, solutions design, just facts checking I prefer to use Gemini or ChatGPT. Surely considering that different models are good at different things.
As system components, we integrated OpenAI and Azure OpenAI models through LangChain and LangGraph for our RAG pipeline, with Milvus as the vector store.

<details>
<summary><strong>Detailed answer</strong></summary>

**AI tools in the development process:**

- **Claude Code (Anthropic)** — my primary AI-assistant (via Claude Code CLI). I used it extensively for analyzing existing codebases, identifying bottlenecks, and suggesting optimizations. It was especially valuable for navigating unfamiliar parts of the codebase and generating boilerplate for FastAPI routers, Pydantic models, and SQLAlchemy mappings. I always validated and refined the AI-generated code to ensure compliance with our project standards and performance requirements — I never merged AI output without review.
From time to time also used it for more complex tasks: designing database schemas, reasoning about cache invalidation strategies, reviewing architectural decisions, and writing thorough test cases.

**AI as system components:**

- **Azure OpenAI / OpenAI API** — the Large Language Model (LLM) backbone for our conversational agents. We used GPT-4-class models for generating patient-facing responses about diagnosis and treatment information.
- **LangChain** — the orchestration framework for building our Retrieval-Augmented Generation (RAG) pipeline. It handled prompt templating, chain composition, document loading, text splitting, and embedding generation.
- **LangGraph** — used for implementing asynchronous, event-driven execution flows. This gave us stateful, multi-step agent workflows with proper branching and error handling — more control than simple LangChain chains.
- **Milvus** — our vector database for semantic search. Patient-relevant medical documents were embedded and stored in Milvus, and the RAG pipeline queried it for context retrieval before generating responses.

The key distinction I maintain: AI tools accelerate my development workflow, but I remain accountable for every line that ships. For system components, the AI models are treated like any external dependency — monitored, tested, and wrapped in error handling.

</details>

---

### Q3. Provide an example of a disagreement that you had with another engineer or product owner or a team member and how did you resolve it.

**Brief answer**
I disagreed with a product owner who wanted to skip input validation on an internal tool "because only our team uses it." I resolved it by showing a concrete risk scenario and proposing a minimal validation layer that added less than a day of work.

<details>
<summary><strong>Detailed answer</strong></summary>

The situation: we were building an internal admin panel for managing RAG pipeline configurations — things like chunk sizes, overlap settings, and which embedding model to use. The product owner wanted to ship it fast and argued that since only three engineers would use it, we didn't need input validation or confirmation dialogs.

My concern was that a misconfigured chunk size (say, set to 0 or a negative number) would silently corrupt the entire vector store during the next re-indexing job. Re-indexing took 4+ hours and wasn't easily reversible.

How I resolved it: I didn't argue in abstract terms, I walked the product owner through a specific scenario: "If someone accidentally types 0 in the chunk size field and hits save, the next re-index job will produce zero-length chunks, the embeddings will be meaningless, and every search query will return garbage until we re-index again — that's half a day of downtime."

I proposed a proportional solution. I didn't push for a full validation framework. I suggested three things: a Pydantic model with gt=0 constraints on numeric fields (10 minutes of work), a confirmation dialog before saving (30 minutes), and a dry-run mode for re-indexing that processes 10 documents first and reports stats before committing (2-3 hours). Total: less than a day.
The product owner agreed, and we shipped with the validation.

**What I learned:** disagreements are usually about incomplete information, not bad intentions.

</details>

---

### Q4. Task with unclear requirements — a one-liner telling you to do something (with no acceptance criteria, no real value). How do you proceed?

**Brief answer**
I don't start coding. I write down my assumptions, define what "done" looks like, and bring that back to the requester for confirmation before touching any code.

<details>
<summary><strong>Detailed answer</strong></summary>

When I get a vague one-liner — say, "add patient export feature" with no further context — I resist the urge to just build something. The worst outcome is spending days building the wrong thing. A 20-minute conversation saves 20 hours of rework.
So, I treat a vague ticket not as a task — it's a conversation starter. I try to follow a consistent approach:

**Step 1 — Interpret and document assumptions (15-30 min)**

I read the one-liner and write down everything I'm assuming:
- What data is being exported? (All records? Filtered view? Current page?)
- What format? (CSV? Excel? PDF?)
- Who triggers it? (User button click? Scheduled job? API endpoint?)
- What's the expected volume? (100 rows? 1M rows? This changes the architecture.)
- Are there access control implications? (Can any user export any data?)

**Step 2 — Propose, don't ask open-ended questions**

Instead of asking "what do you mean by export?", I send a short message like:

> "Here's what I'm planning to build for the export task. Tell me what's wrong:
> - CSV export of the current filtered view, triggered by a button in the UI
> - Max 10k rows; for larger sets, we queue a background job and email the file
> - Respects existing role-based access — users only export what they can see
> - Acceptance criteria: user clicks Export → gets a .csv file within 5 seconds for <10k rows; gets an email within 2 minutes for larger sets"

This approach is faster than a back-and-forth Q&A because it gives the requester something concrete to react to. People are much better at saying "no, not that" than answering "what do you want?"

**Step 3 —  Bring it back to the requester.** I schedule a quick sync or send the assumptions asynchronously. The key question is: "Does this match what you had in mind, or am I off track?" Nine times out of ten, the requester says "oh, I actually meant something simpler" or "you're missing this critical constraint."

**Step 4 —  Timebox if I can't reach the requester.** If the person is unavailable and there's time pressure, I build the smallest possible version that's easy to extend, document my assumptions in the PR description, and flag it for review.

On our cancer support project, this came up regularly. The clinical team would request features in medical terminology that didn't translate directly to technical requirements. I learned that investing in clarification upfront — even when it felt slow — consistently led to faster delivery because we avoided rework cycles.

</details>

---

### Q5. How to balance speed and quality? You have a tight deadline so you have to make a decision of which one to prioritize. How do you handle this: delivery vs. quality? What is your negotiation approach?

**Brief answer**
I negotiate scope, not quality. I identify what can be deferred versus what's essential — which quality trade-offs are reversible (and therefore acceptable under time pressure) versus ones which create long-term damage. I propose a phased delivery, and make the tradeoffs explicit so the decision-maker understands the risk.
The framing of "speed vs. quality" is usually a false approach. In practice, the real negotiation is about scope.

<details>
<summary><strong>Detailed answer</strong></summary>

My framework for this is **never compromise on correctness, negotiate on scope and polish:**

**1. Separate "must have" from "nice to have" — ruthlessly**

When a deadline is tight, I break the deliverable into three tiers:
- **Core:** the minimum that delivers user value and won't embarrass us (e.g., the feature works for the primary use case with proper error handling)
- **Important:** edge cases, polish, secondary use cases (e.g., CSV export also supports Excel)
- **Nice to have:** optimizations, extra configurability, UI polish

I present this breakdown to the product owner or stakeholder and say: "We can ship Core by the deadline with full test coverage. Important adds 3 days. Which tier is the deadline for?"

**2. Never negotiate on the things that bite you later**

**What I won't cut:**
- Security and data validation (especially in a healthcare context — this is non-negotiable)
- Tests for critical paths (in our case, anything touching patient data or the RAG pipeline's retrieval accuracy)
- Basic error handling on external boundaries (API calls to Azure OpenAI, database connections)
- Database migrations that are backwards-compatible

**What I will defer:**
- Comprehensive edge-case coverage for non-critical flows
- Performance optimization beyond "acceptable" (optimize later when you have production metrics)
- UI polish, detailed logging, admin tooling
- Refactoring code that works but isn't elegant

**3. Make technical debt visible**

If we do cut corners (and sometimes that's the right call), I document it explicitly:
- A `TODO(tech-debt)` comment in the code with a linked ticket
- A follow-up ticket in the backlog with clear description of what was deferred and why
- A verbal agreement on when it gets addressed (next sprint, not "someday")

**4. My negotiation approach**

I don't say "we can't do it in time." I say: "Here are three options with different scope/time tradeoffs. Option A ships Thursday with X. Option B ships next Tuesday with X + Y. Option C is the full vision and needs two weeks. Which one aligns with the business need?"

This shifts the conversation from "can you go faster?" to "what do we actually need by Thursday?" — which is a much more productive question. The decision-maker gets to own the tradeoff instead of feeling like engineering is blocking them.

**The underlying principle:** speed and quality aren't opposites. The fastest path is usually the one with the fewest surprises, and quality practices like testing and clear interfaces reduce surprises. The real negotiation is about scope: ship less scope with solid quality — that's the real speed hack..

</details>
