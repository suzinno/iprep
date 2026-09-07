# Soft Skills — Interview Answers

---

### Q1. Where in the project were you responsible for a critical part of a system? Also for ensuring the quality and reliability under pressure. Tell about those critical parts.

**Brief answer**
I owned the core RAG pipeline and the real-time data ingestion layer — both were on the critical path for the product's main value proposition, and any regression there meant broken answers for end users.

<details>
<summary><strong>Detailed answer</strong></summary>

In one project I was the sole engineer responsible for the Retrieval-Augmented Generation (RAG) pipeline that powered the product's AI search feature. This component sat between the user-facing API and multiple Large Language Model (LLM) providers. It handled document chunking, embedding generation, vector store upserts, and query-time retrieval with re-ranking. A bug anywhere in that chain would either produce hallucinated answers or return nothing at all — both unacceptable for a production product that customers relied on for compliance decisions.

To ensure quality under pressure I took several concrete steps:

- **Contract tests on every boundary.** The pipeline had integration tests that ran against a real Postgres + pgvector instance, not mocks. This caught schema drift and embedding dimension mismatches before they hit staging.
- **Observability first.** I instrumented each pipeline stage with structured logging and latency histograms. When response times spiked during a demo week, I pinpointed the bottleneck (a missing HNSW index on the vector column) within minutes instead of hours.
- **Graceful degradation.** If the LLM provider timed out, the system returned cached results with a staleness indicator rather than a 500 error. This decision was made proactively during design, not reactively after an outage.
- **Load-tested before launch.** I used Locust to simulate concurrent query traffic at 3× expected peak. This revealed a connection pool exhaustion issue in SQLAlchemy's async engine that I fixed by tuning pool size and overflow settings.

The reliability aspect was not just technical — it also meant communicating risk clearly to the product owner. When a deadline coincided with a major provider API change, I flagged the risk early, proposed a feature flag to gate the new integration, and we shipped on time with a safe rollback path.

</details>

---

### Q2. Specify which AIs and which tools exactly did you use for development process and as components within the system.

**Brief answer**
For development I use Claude Code, GitHub Copilot, and ChatGPT for research. As system components I've integrated OpenAI GPT-4o, Azure OpenAI, and embedding models via LangChain, with pgvector or Pinecone as the vector store.

<details>
<summary><strong>Detailed answer</strong></summary>

**AI in the development process (tooling):**

- **Claude Code (Anthropic)** — my primary coding assistant. I use it for implementation, refactoring, code review, and generating tests. It excels at multi-file changes and understanding project context.
- **GitHub Copilot** — for inline completions in the IDE, especially useful for boilerplate, repetitive patterns, and test scaffolding.
- **ChatGPT (OpenAI)** — primarily for research, brainstorming architectural decisions, and exploring unfamiliar APIs. I treat it as a conversational reference, not a code generator.
- **Cursor / AI-assisted IDE features** — for rapid prototyping and exploring codebases I'm unfamiliar with.

**AI as system components (in production):**

- **OpenAI GPT-4o / GPT-4 Turbo** — used as the generation model in RAG pipelines. I call it via the OpenAI Python SDK with structured output (function calling / JSON mode) to ensure parseable responses.
- **Azure OpenAI Service** — same models but deployed in Azure for projects with data residency requirements. The SDK is nearly identical; the main difference is endpoint configuration and Azure Active Directory (AAD) token-based auth.
- **Embedding models** — `text-embedding-3-small` or `text-embedding-ada-002` for generating vector representations of documents and queries.
- **LangChain** — used as an orchestration layer to chain retrieval, prompt construction, and LLM calls. I use it selectively — mostly for document loaders, text splitters, and retriever abstractions — rather than adopting the entire framework.
- **Vector stores** — pgvector (PostgreSQL extension) when the project already uses Postgres, Pinecone when the scale or query pattern demands a dedicated managed service.
- **Guardrails / validation** — Pydantic models to validate LLM output structure, with retry logic when the model returns malformed responses.

The key decision criterion is always: does adding this AI component solve a real user problem, and can I observe and debug it in production? I avoid adding AI tools that create black boxes.

</details>

---

### Q3. Provide an example of a disagreement you had with another engineer or product owner or team member and how you resolved it.

**Brief answer**
I disagreed with a product owner who wanted to skip input validation on an internal tool "because only our team uses it." I resolved it by showing a concrete risk scenario and proposing a minimal validation layer that added less than a day of work.

<details>
<summary><strong>Detailed answer</strong></summary>

The situation: we were building an internal admin panel for managing RAG pipeline configurations — things like chunk sizes, overlap settings, and which embedding model to use. The product owner wanted to ship it fast and argued that since only three engineers would use it, we didn't need input validation or confirmation dialogs. "Just ship the form, we're all adults."

My concern was that a misconfigured chunk size (say, set to 0 or a negative number) would silently corrupt the entire vector store during the next re-indexing job. Re-indexing took 4+ hours and wasn't easily reversible.

**How I resolved it:**

1. **I didn't argue in abstract terms.** Instead of saying "we should follow best practices," I walked through a specific scenario: "If someone accidentally types 0 in the chunk size field and hits save, the next re-index job will produce zero-length chunks, the embeddings will be meaningless, and every search query will return garbage until we re-index again — that's half a day of downtime."

2. **I proposed a proportional solution.** I didn't push for a full validation framework. I suggested three things: a Pydantic model with `gt=0` constraints on numeric fields (10 minutes of work), a confirmation dialog before saving (30 minutes), and a dry-run mode for re-indexing that processes 10 documents first and reports stats before committing (2-3 hours). Total: less than a day.

3. **I framed it as risk reduction, not quality dogma.** The product owner cared about speed, and I respected that. By quantifying the downside (half-day outage, lost trust) versus the cost (one day of work), the decision became obvious.

The product owner agreed, and we shipped with the validation. Two weeks later, someone on the team actually did enter an invalid value — the validation caught it. That moment built lasting trust.

**Takeaway:** disagreements resolve faster when you replace opinions with scenarios and propose solutions that respect the other person's priorities.

</details>

---

### Q4. Task with unclear requirements — a one-liner telling you to do something (with no acceptance criteria, no real value). How do you proceed?

**Brief answer**
I don't start coding. I write down what I think the task means, list my assumptions, and send it back to the requester as a short proposal with explicit acceptance criteria for them to confirm or correct.

<details>
<summary><strong>Detailed answer</strong></summary>

A vague ticket like "add export functionality" is not a task — it's a conversation starter. Here's my concrete process:

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

**Step 3 — Timebox and check in**

If I genuinely cannot reach the requester (they're on vacation, different timezone, etc.), I timebox the ambiguity: I pick the simplest reasonable interpretation, build it behind a feature flag, and document my assumptions in the PR description. When they're back, the conversation is grounded in working code rather than hypotheticals.

**What I never do:** silently build something based on my guess and present it as done. That's how you waste a sprint.

</details>

---

### Q5. How to balance speed and quality? You have a tight deadline so you have to make a decision of which one to prioritize. How do you handle delivery vs. quality? What is your negotiation approach?

**Brief answer**
I negotiate scope, not quality. I identify what can be deferred versus what's essential, propose a phased delivery, and make the tradeoffs explicit so the decision-maker owns the risk.

<details>
<summary><strong>Detailed answer</strong></summary>

The framing of "speed vs. quality" is usually a false dichotomy. In practice, the real negotiation is about **scope**. Here's how I handle it:

**1. Separate "must have" from "nice to have" — ruthlessly**

When a deadline is tight, I break the deliverable into three tiers:
- **Core:** the minimum that delivers user value and won't embarrass us (e.g., the feature works for the primary use case with proper error handling)
- **Important:** edge cases, polish, secondary use cases (e.g., CSV export also supports Excel)
- **Nice to have:** optimizations, extra configurability, UI polish

I present this breakdown to the product owner or stakeholder and say: "We can ship Core by the deadline with full test coverage. Important adds 3 days. Which tier is the deadline for?"

**2. Never negotiate on the things that bite you later**

There are things I refuse to cut regardless of deadline:
- Input validation and basic security (SQL injection, auth checks)
- Error handling on external boundaries (API calls, file I/O)
- A minimum set of tests covering the happy path and the most dangerous failure mode
- Database migrations that are backwards-compatible

These aren't "quality extras" — they're the difference between "shipped fast" and "shipped a liability."

**3. Make technical debt visible**

If we do cut corners (and sometimes that's the right call), I document it explicitly:
- A `TODO(tech-debt)` comment in the code with a linked ticket
- A follow-up ticket in the backlog with clear description of what was deferred and why
- A verbal agreement on when it gets addressed (next sprint, not "someday")

**4. My negotiation approach**

I don't say "we can't do it in time." I say: "Here are three options with different scope/time tradeoffs. Option A ships Thursday with X. Option B ships next Tuesday with X + Y. Option C is the full vision and needs two weeks. Which one aligns with the business need?"

This shifts the conversation from "can you go faster?" to "what do we actually need by Thursday?" — which is a much more productive question. The decision-maker gets to own the tradeoff instead of feeling like engineering is blocking them.

**5. What I've learned the hard way**

Cutting tests to meet a deadline has never, in my experience, actually saved time. The bugs surface in production, the debugging takes longer without tests, and the trust damage with stakeholders costs more than the two days you "saved." Ship less scope with solid quality — that's the real speed hack.

</details>
