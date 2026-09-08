# Soft Skills — Interview Answers

> Questions supplied by the client.
> Weighted toward the client brief in `candidate-profile.txt`.

---

### Q1. Describe your role and responsibilities in the project.

**Brief answer**
Senior backend engineer on two Python/[FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") systems in the same case: a personalized cancer support platform and a retail software aggregation marketplace. On both I owned the data model, the asynchronous paths that keep work off the request path, and the delivery pipeline from merge request to deploy.

<details>
<summary><strong>Detailed answer</strong></summary>

**Cancer support platform.** The product is `care-core`, a FastAPI modular monolith with four modules — `diary`, `records`, `clinical-content`, `identity` — plus two services that were extracted for reasons that hold up: `scim-provisioning-svc`, which releases on the hospital directory's cadence, and `clinical-nlp-svc`, which needs graphics processing unit (GPU) hardware and ships on a model's schedule. My work there:

- Designed the [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") schemas in `pg-clinical` — one schema per module, with `care_relationship` as the temporal authorization table at the centre — and the Elasticsearch indexes behind the `clinical-search` alias.
- Built the event-driven paths: [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") `care.events` for domain facts over Advanced Message Queuing Protocol ([AMQP](https://www.amqp.org/ "Standardizes reliable message queueing and routing between applications")), the Message Queuing Telemetry Transport ([MQTT](https://mqtt.org/ "Lightweight publish-subscribe protocol for constrained devices and unreliable networks")) plugin for check-in ingress from patient devices, and [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") for the work the platform owns and must retry (`celery.reminders`, `celery.content`, `celery.index`).
- Implemented the two identity planes — self-registered patients and directory-provisioned clinicians over System for Cross-domain Identity Management ([SCIM](https://scim.cloud/ "Standardizes automated provisioning and deprovisioning of user identities between systems")) 2.0 — so a clinician token is rejected on a patient route at the gateway rather than in application code.
- Configured the GitLab Continuous Integration ([CI](https://en.wikipedia.org/wiki/Continuous_integration "Automatically builds and tests code on every change")) gates (ruff, `pyright --strict`, Pytest, SonarQube) and the Argo [CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") sync to Azure Red Hat OpenShift.

**Retail software marketplace.** Six clean-architecture services on Azure [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Service ([AKS](https://learn.microsoft.com/en-us/azure/aks/ "Azure Kubernetes Service — Managed Kubernetes hosting on Azure")) — `catalog-service`, `vendor-service`, `retailer-service`, `connection-service`, `billing-service`, `identity-service` — plus three Celery worker deployments. My work there was the storage split (a relational spine in `postgres-core`, a schemaless body in `mongo-catalog`, joined by the `product_listing_facets` projection that `indexer-worker` maintains), the catalog search and caching path, the transactional outbox feeding Azure Service Bus, and the [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") that owns every Azure resource.

**Around the code.** On both I kept estimates and remaining work current in Jira and release and incident notes in Confluence, so the deploy runbook was shared across modules rather than living in one person's head. That is not decoration on this kind of system: the restore rehearsal and the breach-reporting path both depend on one runbook existing.

</details>

---

### Q2. Tell where in the project you were responsible for a critical part of a system?

**Brief answer**
Two: the authorization boundary on the cancer platform, which lives in PostgreSQL as row-level security rather than only in application code, and the connection-request path on the marketplace, where a double-submitted request must not create two conversations or bill a vendor twice.

<details>
<summary><strong>Detailed answer</strong></summary>

**Row-level security ([RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user")) as the authorization boundary.** On the cancer platform the question "may this clinician see this patient" has exactly one definition: an active row in `care_relationship`, whose `valid_period` is a `tstzrange` with a Generalized Search Tree ([GiST](https://www.postgresql.org/docs/current/gist.html "PostgreSQL index type supporting range and exclusion constraints")) exclusion constraint, so access has a start and an end and history is not overwritten. RLS policies on every patient-scoped table join through that table. The point of putting it in the database is that a query someone forgets to scope returns zero rows instead of another patient's record.

Three implementation details decide whether that control is real, and each is asserted by a test rather than left to review:

- The session setting carrying the caller's identity is applied with `SET LOCAL` inside the request transaction, never a plain `SET`. Azure Database for PostgreSQL Flexible Server behind a transaction-mode pooler reuses a backend across requests, and a session-scoped setting would leak one caller's identity into the next caller's query — turning the strongest control in the design into its exact opposite. A pooled-connection leakage test asserts it.
- The application role is `NOSUPERUSER` and lacks `BYPASSRLS`; migrations run as a separate owning role that never serves a request. A role-privilege assertion runs in CI.
- Policies are written so the `patient_id` predicate still reaches the planner. A policy that hides it behind an opaque subquery silently converts a pruned index scan into a full sweep of a monthly-partitioned 110-million-row table, so an `EXPLAIN` assertion guards the plan shape.

**The connection request on the marketplace.** A category manager opening a conversation with a vendor is the platform's commercial event: it creates a thread, moves a `shortlist_item` to `contacted`, and accrues a `billing_charge`. A double submit must produce one of each. The guarantee is not the [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") idempotency key — that is the optimisation. It is `UNIQUE (retail_group_id, idempotency_key)` on `connection_request` and `UNIQUE (connection_request_id) WHERE kind = 'connection'` on `billing_charge`. The database is what finally prevents the duplicate thread and the duplicate charge, which is why the one synchronous inter-service hop in that path is allowed to fail open on a 250 ms timeout: refusing a legitimate connection costs the marketplace more than an occasional duplicate the constraint catches anyway.

**What "critical" meant in practice.** Both are places where the failure is silent. A leaked scope returns data and looks like a working request; a duplicated charge looks like a working request too. So both got the same treatment: state the property, put the enforcement in the layer that cannot be bypassed, and write the test that fails when someone removes it.

</details>

---

### Q3. Tell about the team structure and the people you worked with.

**Brief answer**
One product team owning the backend, working across a wider set of named roles rather than only with other engineers — clinical content authors and approvers, care-team coordinators and platform operators on the health platform; vendor-side, retailer-side and platform-operator stakeholders on the marketplace — plus a frontend team consuming the same [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") contract.

<details>
<summary><strong>Detailed answer</strong></summary>

I will describe this by the interfaces I actually worked across, since those are what shaped the work.

**On the cancer platform**, the roles are in the design because they are authorization boundaries, not org-chart decoration:

- **Clinical content authors and approvers.** These are separate roles on purpose — an author cannot approve their own guidance. The generated-page pipeline only ever assigns clinician-approved passages, so approval being a real second pair of eyes is a safety property, not a workflow preference. Working with them meant treating "why can the model not just write this" as a question with a documented answer.
- **Care-team coordinators**, who manage team membership and appointment logistics. Their edits change who can see a record, which is why a reassignment closes the `care_relationship` row immediately and triggers a reindex of that patient's search documents.
- **Platform operators**, who have no routine access to patient data at all — break-glass only, with a reason string, a time-boxed relationship and a review inside 24 hours.

**On the marketplace**, the equivalent split is vendor teams publishing listings, category managers sourcing on the retailer side, and platform operators vetting and moderating. The important structural fact is that competing vendors and competing retail groups share one platform, so most conversations about a feature ended up being conversations about what each side may see.

**With the frontend team.** On both systems the OpenAPI document that FastAPI emits from the [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") models is the published contract, and it is contract-tested in CI rather than written by hand. That is the thing that makes the collaboration workable: when the frontend generates a client from the specification, a breaking change shows up as a failing contract test in my pipeline rather than as a broken screen in theirs. I would rather find a contract break in a CI job than in a standup.

</details>

---

### Q4. What methodology did your team follow, and which rituals did you use?

**Brief answer**
Iterative delivery with a heavy written trail: daily standups, Jira kept current every day including the remaining estimate, Confluence for release and incident notes, and merge requests as the real quality ritual. Two engineering rituals mattered more than any ceremony: expand/contract migrations and a rehearsed restore.

<details>
<summary><strong>Detailed answer</strong></summary>

**The routine part.** Daily standup, Jira updated the same day rather than at the end of a sprint, time tracked accurately, and every release and incident written up in Confluence so the diary, content and identity deploys shared one runbook. I am comfortable with that overhead. A process that produces a written record is what lets a restore rehearsal, an incident review or a regulatory question be answered from artifacts instead of from memory, and I would rather spend ten minutes a day on it than reconstruct a week later.

**The merge request is where quality actually happens.** Every change goes through blocking gates — lint, strict type checking, unit, contract and integration tests against real data stores, and a quality gate — and then through review. I read my own diff first as if someone else wrote it, because a reviewer's time is better spent on the design question than on the thing I could have caught myself.

**Two rituals that are specific to these systems:**

- **Expand/contract migrations, always.** A release adds columns and backfills; a later one removes what is no longer read. Because every migration is backwards-compatible with the previous image, both versions can run against the same schema during a cut-over, and a rollback is a revision revert with no down-migration. A migration that cannot be written that way gets split across two releases — that is a rule, not a judgement call, and it is what makes rollback possible at all.
- **A rehearsed restore, quarterly.** On the cancer platform that means a point-in-time restore of `pg-clinical` to a chosen timestamp and a full Elasticsearch rebuild from PostgreSQL and [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") with a document-count reconciliation afterwards. A backup that has never been restored is an assumption, not a control — and the rebuild is also the mitigation the search-outage plan relies on, so leaving it untested would leave that plan unproven.

**On cadence.** Estimates on this kind of work are frequently wrong in one direction: a task that touches a migration on a large table, or an authorization boundary, takes longer than it looks. My response is to update the remaining estimate daily and flag the reason, rather than to hold the original number and deliver a surprise.

</details>

---

### Q5. What quality criteria do you use, such as test coverage, and how do you ensure robust development?

**Brief answer**
Coverage is a floor, not the goal. The criteria I actually hold a change to are: every gate in the pipeline can genuinely fail, integration tests run against real data stores rather than mocks, and the properties that would fail silently in production each have a test that fails when someone removes the control.

<details>
<summary><strong>Detailed answer</strong></summary>

**The gates.** On both systems the pipeline is the same shape and every stage is blocking: `ruff` on lint, `pyright --strict` (or `mypy`) on types, Pytest for unit and contract suites, Pytest again for integration against real PostgreSQL, MongoDB, Elasticsearch, Redis and RabbitMQ containers brought up with Docker Compose, a SonarQube quality gate, then an image build with a vulnerability scan. The marketplace pipeline adds a functional stage that tests the running Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")) against the OpenAPI document.

Integration tests against real stores are not a stylistic preference. The projection pipeline and the Generalized Inverted Index ([GIN](https://www.postgresql.org/docs/current/gin.html "PostgreSQL index type suited to values containing multiple keys, such as arrays or text search")) query plans on the catalog search are exactly the things a mocked test passes while broken, and a mocked broker cannot fail the way a real one does.

**A coverage target is worth having and worth being honest about.** A high number tells you the suite executes the code; it does not tell you the suite asserts anything useful. So alongside it I look at whether the tests that matter exist:

- the pooled-connection leakage test on the RLS session setting, and the role-privilege assertion that the application role has no `BYPASSRLS`;
- an `EXPLAIN` assertion that the policy has not destroyed partition pruning;
- on the marketplace, a test asserting that a cross-tenant read returns empty for **every** org-scoped repository method — because a per-endpoint check is a control that works until the day someone adds an endpoint;
- a CI check that fails the build if a log call passes a model containing a field marked sensitive, since no clinical free text may reach a log line.

**Claims that might be false get a test before they get trusted.** A few examples I deliberately left flagged rather than assumed: Celery's support for RabbitMQ quorum queues interacts with late acknowledgement and prefetch, so it gets a pinned version and a real test before the reminder path depends on it; Celery on Redis has no true acknowledgement, so import durability gets a kill-the-worker test; and trace continuity across Service Bus and Celery gets an end-to-end assertion in an integration test, because that is a claim you do not want to discover is false during an incident.

**On slow pipelines.** A twenty- to thirty-minute pipeline changes how you work rather than how much you deliver: batch related changes into one merge request, run the fast gates locally first, and do not push a branch to see whether it compiles. I would rather wait for a real gate than have a fast one that cannot fail.

</details>

---

### Q6. Specify which AIs and which tools exactly did you use for development process and as a components within the system

**Brief answer**
As system components: self-hosted fine-tuned Hugging Face models and LangChain composition workflows in `clinical-nlp-svc`, constrained so the model never authors a clinical claim. In the development process: assistant tooling in the editor and on the command line, under a rule that nothing reaches a merge request I have not read and cannot explain.

<details>
<summary><strong>Detailed answer</strong></summary>

**As components in the system.** On the cancer platform, `clinical-nlp-svc` uses fine-tuned Hugging Face models at two points — clinical entity and code extraction from visit notes, which enriches the search index, and passage reranking during retrieval — with LangChain running the retrieval, reranking and citation-assembly workflow that composes an education page. Four constraints define that pipeline and I would lead with them in any conversation about it:

- **Composition draws only from clinician-approved `guidance_sources` passages**, and every block carries a citation to the passage it came from. The model selects, ranks and rewrites approved material for the patient's context; it does not author clinical claims. That measurably narrows what a page can say, and the cost is accepted deliberately — an unsourced sentence in cancer guidance is a patient-safety defect, not a quality regression.
- **A page a reviewer has not approved is never assigned**, and the assignment pins an exact page version, so a later revision cannot silently change what a patient was shown.
- **The weights are self-hosted** so patient text stays inside the tenancy; there is no third-party model API and no cross-border transfer. The service receives diagnosis code, treatment line, stage and locale for composition — not the patient's identity.
- **The model version is stamped on every artifact**, so a regression is attributable and a rollback is a reindex rather than a migration. The rollout is a canary for exactly this reason: model quality shows up statistically, so a percentage rollout with confidence and latency comparison is the only way to see a regression before everyone gets it.

The honest open item there is data governance on fine-tuning: transfer learning on real visit notes means patient text in a training corpus, and lawful basis, de-identification standard and extraction risk in the resulting weights need a completed assessment before a tuning run, not after.

**In the development process.** I use assistant tooling in the editor and a command-line agent for the ordinary things it is good at — navigating an unfamiliar module, drafting boilerplate around Pydantic models and [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") mappings, generating test cases to react to, explaining a stack trace. My working rules are fixed:

- I read and understand every line before it reaches a merge request. If I cannot explain why a branch is there, it does not go in. That applies to generated tests especially, because a test that passes for the wrong reason is worse than no test.
- The quality gates apply identically. Generated code does not get a lighter review, and it has to be readable by whoever picks it up next — a reviewer should not be able to tell which lines came from where.
- Nothing confidential goes into a tool that would take it outside the tenancy: no patient text, no client brief, no secret material. On a health-data system that is a legal constraint, not a preference.

Where I find the tooling genuinely useful is at the start of a task — turning a vague ticket into a list of questions to check against the code — and at the end, as a second reader on my own diff before I ask a person to spend time on it.

</details>

---

### Q7. Provide an example of disagreement that you had with another engineer \ product owner \ a team member and how did you resolve it

**Brief answer**
The clearest one was over where tenant isolation belongs — PostgreSQL row-level security, or a filter in the application layer. I had argued for RLS on the health platform and was arguing against it on the marketplace, which looked inconsistent until we wrote down the constraint that actually differed.

<details>
<summary><strong>Detailed answer</strong></summary>

**The disagreement.** RLS is the stronger mechanism, and on the cancer platform it is the single most important control in the design: a forgotten scope returns zero rows instead of someone else's record. So when the marketplace design chose an application-layer tenant filter instead, the reasonable objection was that we were picking the weaker control on the system with competing vendors and competing retail groups on it — exactly where an authorization gap is the whole threat model.

**How it was resolved.** Not by seniority and not by preference, but by naming the mechanism each design depends on:

- On the health platform the identity is set with `SET LOCAL` inside the request transaction, and the pooled-connection leakage test proves it does not survive into the next caller's query. That is what makes RLS trustworthy there.
- On the marketplace, `catalog-service` reads a replica through a pooled connection under a shared role. Setting a per-request session variable through that pool is exactly where RLS silently becomes a no-op or leaks across sessions. Getting that wrong is worse than not relying on it.

So the marketplace filters on the token's `org_id` in **one** place — a session-level filter applied by the repository layer, never per endpoint — and pays for the weaker mechanism with a test that asserts a cross-tenant read returns empty for every org-owned repository method, plus an audit row on every platform-admin bypass. The disagreement ended when both positions were written into the design file with the trigger that would reverse them, rather than settled in a conversation nobody could reconstruct later.

**How I handle this generally.** I take a technical disagreement to the person who owns the decision, in the merge request or the design document where it belongs, and I try to state the other position accurately before I state mine — if I cannot, I do not understand it yet. I do not argue technology choices in shared channels, and I do not join in when a stack is being criticised generally; a complaint that names no mechanism cannot be acted on and costs the team more than it returns. Where I think a choice is wrong, I want it written down with the condition that would change it, so the next person inherits the reasoning instead of the argument.

</details>

---

### Q8. How do you proceed if you get task with unclear requirements - just one-liner telling you to do something abstract (with no acceptance criteria, no real value)?

**Brief answer**
I do the homework first, then ask. I reconstruct as much of the intent as the code and existing artifacts support, write down my reading plus the specific decisions I cannot make alone, and take that to a short call with whoever owns the business logic — so they react to a proposal instead of facing an open question.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: reverse-engineer what already exists.** A one-line ticket is usually less empty than it looks, because the system constrains the answer. Take a real example — "surface deteriorating patients to the care team", which is one of the nice-to-haves on the cancer platform. Before asking anything I can establish that check-ins carry `symptom_scores` as `jsonb` with a GIN index behind the trend endpoint, that the audience is the care team resolved through `care_relationship`, and that the platform's scope boundary explicitly excludes diagnostic or triage decision support. That last one already rules out a whole class of interpretation.

**Step two: write the reading down and list the real decisions.** What I take into the call is a short note: here is what I think this means, here are the acceptance criteria I would propose, and here are the four things only you can decide — over what window is a deterioration "sustained", what magnitude counts, does this reach the whole care team or the named clinician, and is the flag advisory or does it create an obligation to act? Those are business questions with clinical and legal consequences, and guessing at them is how you build the wrong thing carefully.

**Step three: get the call, and be specific about who.** I do not wait for a better ticket to arrive. I book a short slot with the application manager or product owner who holds the business logic, and I come with the proposal rather than with "what did you mean?", because reacting to a concrete reading is much faster for them than authoring one from scratch. It usually takes twenty minutes and saves a week.

**Step four: record it where the work happens.** The agreed criteria go on the ticket, not into a chat thread, and anything that changes a documented boundary goes into the design file that owns it. Then the estimate gets set — after the scope lands, not before — and updated as it moves.

**What I do not do.** I do not sit on a blocked ticket quietly, and I do not build the most expansive interpretation because it is the most impressive. On a system with scope boundaries this explicit, the risk in an abstract ticket is not doing too little; it is quietly crossing a line the product said it would not cross.

</details>

---

### Q9. How to balance speed and quality? you have a tight deadline so you have to make decision of which one to prioritize - how do you handle this type of situation: delivery vs. quality? what is your negotiation approach?

**Brief answer**
I negotiate scope, not gates. Some properties cannot be traded because their failure is silent and expensive to undo — authorization, audit completeness, idempotency, migration reversibility. Almost everything else is a candidate, and my job is to arrive with a smaller shippable slice rather than with a request for more time.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction I use: is the failure loud or silent, and is it reversible?**

*Not tradeable*, because failure is silent and the cost lands later:

- The authorization boundary. Shipping the tenant filter or the RLS policy "next sprint" means shipping a disclosure path now and finding out from someone else.
- Audit completeness on the health platform. Every access writes its row in the same transaction as the access, and that coupling is deliberate — an audit trail that can be lost in a queue is not an audit trail.
- Idempotency on anything that must not double-apply: the unique key on a check-in, the unique constraint on a connection request and its charge.
- Expand/contract on migrations. Skipping it to save an hour removes the ability to roll back for the whole release window, which is precisely the capability you want on a rushed release.

*Genuinely tradeable*, and I would rather propose these than be asked:

- Exactness where nobody needs it. The marketplace returns `total_estimate` capped at 1,000 rather than a real count, because an exact count over a filtered index scan costs as much as the page — and "1,000+" is what a sourcing workflow needs anyway.
- Degraded modes instead of features. If search is not ready, chronological browse from the primary store is a labelled fallback that ships.
- Scope of a first cut: one category, one locale, one channel. Coverage of the remaining ones is usually the part that expands, not the mechanism.

**The negotiation itself.** I go in with three things: what is at risk if we hold the date, a concrete reduced scope that still delivers the value, and the cost of the shortcut stated plainly and in writing — what breaks, when it surfaces, and what it will cost to undo. If the decision is to take the shortcut anyway, that is a legitimate call for the person who owns the deadline to make; my responsibility is that it is made knowingly, and that the follow-up work exists as a ticket rather than as a memory.

**On the deadline itself.** Estimates on migrations, authorization changes and anything touching a very large table are unreliable in one direction, so I would rather flag a slip on day three with a revised remaining estimate than defend the original number until the due date. Raising it early is almost always cheap; raising it late is never. And I do this without pushing on the people around me — steady, visible progress with an honest number attached is what makes the pace predictable, which is worth more to a team than a burst of speed followed by a rollback.

</details>
