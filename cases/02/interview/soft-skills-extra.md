# Soft Skills — Extended Questions & Answers

> Generated as a continuation of the original question set. Same interviewer style, new angles.
> Weighted toward the client brief in `candidate-profile.txt`.

## Contents

- [Role, Ownership and Judgement](#role-ownership-and-judgement)
- [Team, Stakeholders and Cross-Functional Work](#team-stakeholders-and-cross-functional-work)
- [Methodology, Rituals and Process Discipline](#methodology-rituals-and-process-discipline)
- [Quality Culture and Robust Development](#quality-culture-and-robust-development)
- [AI Tooling and Policy](#ai-tooling-and-policy)
- [Conflict, Communication and Professional Conduct](#conflict-communication-and-professional-conduct)
- [Unclear Requirements, Autonomy and Proactivity](#unclear-requirements-autonomy-and-proactivity)
- [Delivery, Estimation and Negotiation](#delivery-estimation-and-negotiation)

---

## Role, Ownership and Judgement

---

### Q10. Which decision on either system are you least confident was right, and what would make you change it?

**Brief answer**
The two-cluster split on the cancer platform — a separate Azure [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") Service cluster with a graphics-processing-unit node pool for one stateless inference service. It is the most expensive line in that design and it buys one thing: hardware isolation. If inference moved to a managed endpoint, I would collapse it.

<details>
<summary><strong>Detailed answer</strong></summary>

The case for it is real. Inference needs graphics hardware, and a node pool with that hardware in the primary cluster means every node group, every autoscaler decision and every upgrade in the cluster holding the clinical record now has an expensive, differently-shaped member. Keeping it out means the primary cluster stays uniform and the model service ships on the model's schedule rather than the product's.

The case against it is that a second cluster is a second control plane, a second upgrade cycle, a second set of network policies, a second place for configuration to drift — and the service in it holds no state, which is exactly the property that would let it live anywhere. Two clusters for one stateless deployment is a lot of operational surface for a boundary that could have been a node selector and a taint.

What would change my mind, and I would rather state it as a trigger than as an opinion: if inference moves to a managed endpoint, the graphics hardware requirement disappears and the cluster has no reason to exist. If it stays self-hosted but the model service grows state — a feature store, a cache of embeddings — then the isolation argument gets stronger, not weaker, and I would keep it.

What I try to do with any decision in this shape is write down the condition that reverses it, in the design file, at the time. A choice with a stated trigger is a decision the next person can revisit. A choice without one becomes a fact of the system that nobody feels entitled to question.

</details>

---

### Q11. What did you take ownership of that nobody assigned to you?

**Brief answer**
The restore rehearsal. Backups existed on both systems and nobody had ever restored one, which means the recovery plan was an assumption rather than a control. I made it a quarterly exercise with a written reconciliation, and it changed two designs.

<details>
<summary><strong>Detailed answer</strong></summary>

The trigger was writing the search-outage section of a design document and noticing that the mitigation was "rebuild the index from the primary stores" — a sentence I had written with confidence and never executed. A mitigation nobody has run is a hypothesis. So I ran it.

What it involved: a point-in-time restore of the clinical database to a chosen timestamp into a scratch environment, then a full search index rebuild from the relational and document stores, then a document-count reconciliation between the sources and the rebuilt index. The reconciliation is the part that matters — a rebuild that finishes is not a rebuild that is correct, and the count is the cheapest assertion that catches a silently truncated source.

Two things came out of it that would otherwise have been discovered during an incident. The rebuild took materially longer than anyone had assumed, which changed the recovery time objective we were willing to publish. And the index alias switchover needed a step nobody had written down, because the rebuild writes to a new index and the alias move is what makes it live — obvious in hindsight, absent from the runbook.

The general habit: I look for the sentences in a design that describe something nobody has done. Restore, failover, key rotation, the dead-letter drain, the rollback. Those are the places where a document and reality diverge quietly, and the fix is always the same — do it once on a calm afternoon, write down what actually happened, and put it on a schedule.

I would not describe that as heroic. It is closer to the opposite: it is the cheap, boring work that stops an incident from being the first rehearsal.

</details>

---

### Q12. If you left the project tomorrow, what would stall first — and what did you do about that while you were there?

**Brief answer**
The two places where the knowledge was thinnest were the query plans on the catalog search and the row-level security policies on the clinical database. Both are areas where the code looks ordinary and the reasoning is not, so both got written reasoning and a test that fails when someone removes the property.

<details>
<summary><strong>Detailed answer</strong></summary>

I treat "what would stall without me" as a design question rather than a career one, because a system that needs a specific person is a system with a defect.

**Where the risk actually was.** The catalog search query is a hand-written statement over a projection table with a partial index, a keyset cursor and a deliberate product constraint limiting facet predicates. Every one of those is a decision with a reason, and none of the reasons are visible in the code. Someone maintaining it in good faith could relax the predicate limit, or switch the cursor to an offset, and the query would keep returning correct rows while getting quietly slower on the pages nobody looks at in staging.

The clinical authorization policies are the same shape with a worse failure. A policy rewritten to be more readable can hide the partition key from the planner, or a session setting applied without transaction scope can leak one caller's identity into the next request through a pooled connection. Both look like tidy-ups.

**What I did.** Three things, in increasing order of usefulness. The reasoning went into the design document that owns that area, with the trigger that would reverse each decision. The non-obvious constraints went into comments in the code — not comments restating what the code does, but the single line the code cannot show, such as why the session setting is transaction-scoped. And the properties got tests that fail when the control is removed: a query-plan assertion, a pooled-connection leakage test, a role-privilege check.

The tests are the only part of that list I fully trust. Documentation goes stale and comments get deleted; a failing pipeline stops the merge. If I had to keep one, it would be the test.

</details>

---

### Q13. Tell about a change of yours that caused a production problem. What happened, and what changed afterwards?

**Brief answer**
The one I would lead with is a projection worker that stopped, quietly. Nothing errored, no request failed, latency was flat — new listings simply never became searchable. The lesson was that the failures worth designing for are the ones that do not show up as errors.

<details>
<summary><strong>Detailed answer</strong></summary>

**What happened.** The catalog search reads a projection table maintained by a worker that consumes publish events. The worker stopped making progress. Every dashboard stayed green: the application programming interface was fast, the error rate was zero, the pods were healthy and the queue was being consumed. The only symptom was that a vendor who had published a listing could not find it, and that reached us as a support message rather than as an alert.

**Why it was invisible.** Every signal we had measured the read path, and the read path was genuinely fine — it was serving a stale projection quickly and correctly. There was no metric for the distance between when a fact happened and when the derived copy caught up. A green dashboard was accurately describing a broken system.

**What changed.** A single metric: the lag in seconds from an event's occurrence timestamp to the projection's write timestamp, with an alert that pages rather than emails, because nothing else surfaces this class of failure. Alongside it, a nightly reconciliation sweep that re-projects any row whose projection timestamp predates its source update by more than a few minutes — the backstop for a lost event, and the thing that turns "we hope every event was handled" into a job with an output.

**The wider habit it produced.** When I design something now, I ask what its silent failure looks like, and whether any existing signal would show it. Search that returns stale results, an audit row that was not written, a reminder that was never dispatched, a permission check that passes when it should not — all of those are fast, green and wrong. The check for a control's absence has to be built deliberately, because no amount of ordinary monitoring stumbles onto it.

I also stopped treating "no alerts fired" as evidence of anything until I know what an alert would have had to notice.

</details>

---

### Q14. The marketplace is retail software — point of sale, inventory, loyalty for chain retail. How much retail or enterprise resource planning domain knowledge did that actually require, and how did you get it?

**Brief answer**
Less than the category suggests, and I would rather be exact about that than overclaim. I built the platform that retail chains use to source software, not the point-of-sale or inventory software itself. The domain knowledge I needed was about how a chain sources, not about how a till works.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the domain actually demanded.** The entities that mattered were vendors, retail groups, the stores under them, product listings with a per-category attribute set, shortlists and connection threads. The retail-specific parts were real but bounded: a retail group is a hierarchy rather than a flat account, so a category manager at group level and a manager at a single chain see different scopes; coverage matters as much as features, so "which countries and which store formats does this product actually support" is a first-class filterable attribute rather than marketing text; and integration with the systems a retailer already runs — enterprise resource planning and inventory platforms — is what decides a shortlist, which is why the integrations list is a filterable facet and not prose.

**How I got it.** By talking to the people who did the sourcing, not by reading about retail. Category managers described what a comparison actually has to answer, and it turned out to be narrower and more specific than the feature matrix we had assumed — coverage, integration, and price shape, in that order. That conversation changed the data model: it is why price is modelled relationally with tiers and an explicit currency rather than left as free text, and why null cells in a comparison are shown as nulls rather than hidden, because a vendor declining to state something is itself a sourcing signal.

**What I have not done, stated plainly.** I have not worked inside an enterprise resource planning product, I have not implemented inventory or point-of-sale logic, and I have not dealt with the parts of retail that get hard — stock movements, promotions engines, tax and fiscal receipt rules, or the seasonal peaks a till network sees. If that experience is what the role needs, I would be starting from adjacent rather than from inside.

**What does transfer.** Modelling a catalogue whose attribute set differs per category, keeping a schemaless metadata store from degrading into no contract, and handling bulk attribute updates without taking the read path down with them. Those are the shapes I would expect to meet again in an enterprise resource planning catalogue, and they are the parts I have actually built.

</details>

---

### Q15. Which of the two systems was harder to work on, and what made it harder?

**Brief answer**
The cancer platform, and not for a technical reason. The work was slower because a mistake there has a different cost — a leaked record or a missed reminder is not a defect you fix next sprint — and almost every design decision had a second question attached to it about who may see the result.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the difficulty came from.** On the marketplace, "who can see this" has a clean answer: an organisation owns a row, and a filter enforces it. On the health platform the same question is temporal and relational — a clinician may see a patient because a care relationship exists now, that relationship has a start and an end, and history must not be overwritten when it changes. That single fact propagates everywhere. It is why the relationship is a table with a time range rather than a membership list, why a reassignment triggers a search reindex rather than just an update, and why the authorization lives in the database rather than only in application code.

**The second thing that slowed it down was the class of failure.** On the marketplace, most failures are loud and recoverable: a job fails and retries, a page is slow, an import needs re-running. On the health platform the failures that matter are silent — a scope that returns the wrong rows, an audit row that was not written, a reminder that never dispatched. None of those page anyone by default. Building the detection for each one is work that produces no visible feature, and it is most of the reason a change took longer than its size suggested.

**And the content constraints are genuinely hard.** Generated patient guidance may only assemble clinician-approved material with a citation per block, which measurably narrows what a page can say. That is a real product cost, accepted on purpose. Working within it means the interesting engineering question is often "how do we make this good enough while staying inside the constraint" rather than "how do we make this good".

**What I would say about the marketplace in fairness.** It was harder in a different dimension — nine deployables, two data stores with a consistency seam between them, and a search path where the performance is the design. That is more moving parts. But the cost of getting one wrong is lower, and that difference is what makes the health platform the one I would call harder.

</details>

---

## Team, Stakeholders and Cross-Functional Work

---

### Q16. How did you actually work with the frontend team day to day, and who owned the API contract when it had to change?

**Brief answer**
The contract was the schema document the backend emits from its typed request and response models, and it is generated rather than written. That makes ownership unambiguous — the backend owns the contract — and it makes a breaking change something a pipeline catches rather than something a screen discovers.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanic.** Request and response bodies are typed models, and the interface description document falls out of them. The frontend generates its client from that document rather than hand-writing types. Two consequences follow, and they are the whole reason the arrangement works: the frontend never has to ask what a field is called, and a change I make that breaks them shows up as a failing contract test in my pipeline instead of as a broken screen in theirs. I would rather find a contract break in a continuous integration job than in a standup.

**Who owns it when it changes.** The backend owns the document, but not the decision. In practice a change falls into one of three cases and each has a different conversation:

- **Additive** — a new optional field, a new endpoint. I ship it, they pick it up when they need it, no conversation required.
- **Breaking** — a field removed, renamed, or made required. That never ships as one change. It goes out as an expand step (add the new shape alongside the old, both accepted), then the frontend migrates, then a contract step removes the old one in a later release. The same discipline as a database migration, for the same reason: two versions have to run against one contract during the window.
- **Semantically breaking but structurally identical** — the shape is unchanged and the meaning is not, which is the dangerous one because no generated client and no contract test will notice. That one is a conversation before it is a commit.

**How it actually ran day to day.** Short and asynchronous, mostly. A change to a shared endpoint got flagged in the merge request with the frontend reviewers added, and anything in the third category got a fifteen-minute call. What I would not do is negotiate a contract in a chat thread and then rely on both sides remembering — the agreement belongs in the schema and in a test, because that is the version that survives.

**What I would push for on a team like this one.** That the generated client is regenerated in the frontend's own pipeline against the latest published document, so drift between the two sides is a red build somewhere rather than a discovery.

</details>

---

### Q17. Tell about working with a non-engineering stakeholder whose request you had to push back on.

**Brief answer**
A request to enforce completeness on vendor-supplied product attributes so comparison tables would have no empty cells. The request was reasonable and the fix would have been wrong, and the resolution was to show what the empty cells actually meant rather than to argue about the requirement.

<details>
<summary><strong>Detailed answer</strong></summary>

**The request.** Comparison views on the marketplace show product attributes side by side, and a vendor whose cells were sparse looked worse than a competitor who had filled everything in. The ask was to make the attributes mandatory so the table would be complete.

**Why I pushed back.** Requiring every attribute in a per-category schema means a vendor either does not publish or fills fields with placeholder values to get past validation, and the second outcome is much more likely. That converts a table with honest gaps into a table with confident-looking noise, which is strictly worse for the person doing the sourcing — they can no longer tell "does not support this" from "did not say". It also freezes the schema, because adding an attribute to a category would instantly invalidate every existing listing in it.

**How I handled the conversation.** Not by leading with the objection. I asked what the empty cells were costing, and the answer was that they read as a defect in the product rather than as information. That reframed it: the problem was presentation, not validation. So the proposal became to render an unstated attribute explicitly as unstated and distinguish it from a stated "not supported", and to give vendors a completeness indicator in their own workspace so the incentive to fill it in is theirs rather than enforced by a validator.

That solved the actual complaint — a sparse row now reads as a vendor's choice rather than as a broken page — without buying a schema we could not evolve.

**The general approach.** When someone asks for a mechanism, I try to find the outcome they want first, because the mechanism is usually the first thing that came to mind rather than the requirement. And when I disagree, I want to be able to state their position accurately before I state mine; if I cannot, I have not understood it yet and I am about to argue with a version of it I invented.

**What I would not do** is implement a request I think is harmful without saying so, or block it indefinitely on my own judgement. If the person who owns the decision hears the cost and still wants it, that is a legitimate call and I write down the cost rather than relitigating it.

</details>

---

### Q18. How do you onboard onto an unfamiliar codebase and an unfamiliar team?

**Brief answer**
Data model first, then the delivery pipeline, then one real ticket end to end. I read the schema and the migration history before I read the application code, because that is where the constraints actually live and where the previous decisions are still visible.

<details>
<summary><strong>Detailed answer</strong></summary>

**Days one to three: the shape of the thing.** The migration history is the most honest document in a repository — it shows what was added, what was walked back, and where the pain was. After that: what deployables exist, what data stores exist and which service owns each one, and where the boundaries are. I try to be able to draw the system on one page before I change anything in it.

**Then the pipeline, before the code.** What gates a merge, what deploys, how a rollback happens, and how long the loop takes. This is not administrative — it tells me how the team actually works. A pipeline with a quality gate and an integration stage against real data stores describes a different culture from one with a lint step, and it tells me how much I can rely on the build to catch my mistakes versus how much I have to verify by hand.

**Then a small real ticket, end to end.** Not a warm-up task in a corner: something that touches the request path, the data model, a test and a deploy, so I exercise every part of the loop once while the stakes are low. What I am looking for is the friction the team has stopped noticing — the step that is undocumented, the local setup that only works if you already know the trick. That is the most valuable thing a new person can see, and the window for seeing it closes within about a month.

**With the team.** I ask each person what they own and what they wish someone would take off them. And I ask the reviewers, early, what they care about in a review — this saves genuine time later, because a lot of review friction is a house style nobody has written down and everybody enforces.

**What I try not to do.** Propose changes in the first weeks. Almost everything that looks wrong on day three has a reason, and the ones that do not are still not worth the credibility it costs to raise them before I have shipped anything. I keep a note of them and come back after a month, by which time about half have explained themselves.

</details>

---

### Q19. Have you mentored or reviewed someone more junior? What did you focus on?

**Brief answer**
Yes, mostly through review rather than formal mentoring. What I focus on is the reasoning rather than the code: I would rather someone leave a review knowing why a change was risky than knowing which line to edit.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I actually comment on.** Three things, in order. Whether the change is safe to roll back — which for anything touching the schema means expand and contract, and for anything touching a hot query means someone has looked at the plan. Whether the failure mode is loud or silent, because a silent one needs a test and a loud one usually does not. And whether the test asserts the thing the change is about, rather than asserting that the code ran.

**How I phrase it matters more than I used to think.** A comment that says "use `selectinload` here" teaches one line. A comment that says "this loops over the results and touches a relationship, so it will issue one query per row — try it against a realistic row count and look at the query log" teaches the shape, and the person finds the next one themselves. It costs me an extra minute and it is the difference between review as a gate and review as the main way a team's standards actually propagate.

**Separating "wrong" from "not how I would do it".** I try to be explicit about which one a comment is, because a junior engineer cannot tell the difference from tone alone and will treat every comment as blocking. So preferences get labelled as preferences and I let most of them go. If I find myself making the same preference comment repeatedly across people, that is a signal it belongs in a linter rule or a written convention rather than in review — enforcing a house style by hand, one person at a time, is both slow and demoralising.

**Pairing beats review for some things.** Anything involving a query plan, a migration on a large table, or an authorization boundary I would rather do side by side once than review three times. Those are the areas where the reasoning is not visible in the diff, so review is a bad channel for it.

**And I ask them to review my work.** Partly because it is the fastest way for someone to learn a codebase, and partly because a reviewer who is not yet fluent asks the question everyone else has stopped asking, which is regularly the useful one.

</details>

---

### Q20. How do you review someone else's merge request — what do you comment on and what do you let go?

**Brief answer**
I look for the things a machine cannot catch and let the machine have the rest. Correctness under failure, rollback safety, silent-failure surface, and whether the contract changed. Style, naming and formatting are for the linter, and if I am arguing about them the tooling is misconfigured.

<details>
<summary><strong>Detailed answer</strong></summary>

**The order I read in.** The description and the ticket first, so I know what it is supposed to do. Then the schema changes, then the tests, then the code. Reading the tests before the implementation is deliberate — it tells me what the author believed the change was about, and a test that only asserts the happy path usually means the failure cases were not considered rather than that they do not exist.

**What gets a blocking comment:**

- A migration that is not backwards compatible with the running image, because it removes the ability to roll back for the whole release window.
- A change to a hot query with no evidence anyone looked at the plan.
- A new code path whose failure is silent — a write that can be lost, a permission check that can be skipped, a derived store that can drift — with no assertion that the control exists.
- A contract change that is breaking, shipped as one step.
- A test that passes whether or not the code works. This is the one I am strictest about, because a test like that is worse than no test: it occupies the space where a real one would go and it reports confidence forever.

**What I let go.** Naming I would have chosen differently, structure I would have arranged differently, an abstraction I think is slightly early. None of those are worth a round trip, and a review that comments on everything trains people to stop reading the comments. If a preference matters enough to enforce, it goes in a tool or a written convention, not in a person's inbox.

**On the client's culture here specifically.** I am aware that on some teams a review can turn into several rounds over subjective test style. I do not enjoy that, but I also do not think it is a reason to push back on the reviewer — a lead who cares that much about the test suite usually has a reason, even if it is unstated, and the cheap move is to ask what the underlying rule is so I can apply it myself next time rather than rediscover it per merge request. If it turns out there is no rule, that is worth raising once, privately, as a request for a written convention.

</details>

---

### Q21. Tell about a time you needed something from a team that had no reason to prioritise you.

**Brief answer**
Identity provisioning from a hospital directory, owned by an infrastructure team with their own roadmap. The thing that worked was reducing my ask to something small, dated and clearly theirs to approve, rather than describing the feature I was blocked on.

<details>
<summary><strong>Detailed answer</strong></summary>

**The situation.** Clinician accounts on the health platform are provisioned from the hospital's directory rather than self-registered, which means a directory-side configuration — an application registration, the provisioning connector pointed at our endpoint, and a decision about which attributes are sent. None of that is work I could do, all of it sat with a team whose priorities had nothing to do with our product, and "we are blocked" is not a compelling message to a team hearing it from four projects at once.

**What worked.**

- **I did everything that did not depend on them first.** The provisioning endpoint was built, deployed and testable against a fake directory before I asked for anything. That changed the ask from "please help us build this" to "please point your connector at this [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") and tell us if the attribute mapping is wrong" — an afternoon rather than a project.
- **I made the ask specific and bounded.** One named endpoint, one list of attributes, one test account. Not a meeting to discuss provisioning.
- **I gave them the artifact.** A short page with the endpoint, the expected payload, the attribute mapping and what a successful test looks like. Whoever picked it up did not have to reconstruct anything.
- **I asked for a date rather than urgency.** A date I can plan around is worth far more than a promise to look at it soon, and it is a much easier thing for someone to give.

**What I avoided.** Escalating early. Going over a team's head gets you the thing once and costs you the relationship for everything after, and on a long engagement I will need them again. I also did not describe their work as blocking mine in a shared channel, because that is a complaint dressed as a status update and it makes the next ask harder.

**The general rule.** Reduce what you need to the smallest thing only they can do, do everything around it yourself, hand it over with the context already assembled, and ask for a date. If it slips twice, then raise it — with my own manager first, not theirs.

</details>

---

## Methodology, Rituals and Process Discipline

---

### Q22. This client runs daily standups, expects Jira updated every day and time tracked accurately in a separate system. Some engineers find that overhead. How do you feel about it?

**Brief answer**
I am comfortable with it and I do not think of it as overhead. On both systems the written trail was what made a restore rehearsal, an incident review and a regulatory question answerable from artifacts rather than from someone's memory. Ten minutes a day is cheaper than reconstructing a week.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I actually keep it current rather than tolerating it.** A status updated once at the end of a sprint is fiction — it is written from memory, by someone with an interest in the story being tidy. A status updated the same day is a record. The difference shows up the moment anyone needs to answer a question about the past: when did this change go out, what did we know at the time, why did the estimate move. On a health platform that question sometimes comes from outside the team and "I think it was around then" is not an acceptable answer.

**The specific habits.** The remaining estimate gets updated daily, not the original — the original is a historical artifact and revising it hides exactly the information a planner needs. Blockers go on the ticket the day they appear, with what I have already tried. Time is tracked as it happens rather than reconstructed on Friday, because reconstructed time is guesswork rounded to the nearest convenient number. Release and incident notes go in the shared space so the runbook is one document rather than several people's recollections.

**Where I think the overhead complaint is fair.** Duplicated reporting — writing the same status in a ticket, a chat channel and a spreadsheet — is genuinely waste, and I would raise that once, politely, as a suggestion to pick one. But that is an argument about a specific duplication, not about the principle, and I would drop it if the answer is that both audiences need their own.

**On standups.** I keep mine short and specific: what moved, what is next, what is in my way. What I try not to do is use it to solve a problem — if two of us need twenty minutes, we take it after, rather than holding six other people while we work it out.

**Honestly stated:** I would rather work somewhere with too much written record than too little. I have spent time reconstructing what happened on a system where nobody wrote anything down, and the bureaucracy is much cheaper than that was.

</details>

---

### Q23. What does a good standup update from you sound like?

**Brief answer**
Three sentences: what actually moved since yesterday, what I am on today, and what is in my way — with the blocker named as a specific thing a specific person can unblock, not as a general difficulty.

<details>
<summary><strong>Detailed answer</strong></summary>

**The shape.** "Yesterday I got the projection backfill running against a seeded copy and the plan is doing what we wanted. Today I am writing the reconciliation job. I am waiting on the read-replica credentials from platform — I have raised it, no date yet." That is enough for anyone to know whether they need to act, and short enough that six of these fit in the time people will actually give it.

**What I leave out.** How the work felt, how much of it there was, and anything that is a status of a status. Also the word "still" — "still on the migration" is a sentence that carries no information, and if a task is on its third day of "still", the useful update is why the shape of it changed, not that it continues.

**Being specific about a blocker is the whole value.** "Blocked on infrastructure" produces sympathy. "Waiting on one connector configuration from the identity team, asked Tuesday, I have unblocked myself by testing against a fake directory so this is not stopping me yet — it will on Friday" produces a decision. The second version also tells people they do not need to help, which is information too.

**Flagging a slipping estimate there rather than later.** If yesterday changed my view of how long something takes, the standup is where I say so, in one sentence, on the day I formed the view. Raising it early is nearly free; raising it on the due date is a surprise, and surprises are what make people stop trusting estimates in general rather than just mine.

**What I am careful about.** Not turning it into a design discussion, and not using it to report other people's status. If I have a strong opinion about someone else's work, that belongs in their merge request or a direct conversation, not announced to the group while they are listening.

</details>

---

### Q24. How do you track your own work during the day, and what do you do when you have several things half-finished?

**Brief answer**
One ticket in progress at a time, wherever the process allows it, and a plain running note for everything else. The half-finished state I care about most is a branch — anything unmerged for more than a couple of days is a risk, so I would rather ship a smaller slice than hold three.

<details>
<summary><strong>Detailed answer</strong></summary>

**The running note.** A single scratch file per task with what I have established, what I have ruled out, and the next thing to check. It costs almost nothing and it is what lets me pick a task back up after an interruption without re-deriving the first hour. It is also, in practice, the first draft of the merge request description and of whatever I need to explain in review — the reasoning is already written down while it was fresh.

**On parallel work.** I try hard to keep it to one, because switching costs more than it looks and because two half-finished branches on the same area produce a merge I will spend an afternoon on. Where I genuinely have two, I want them to be in different states rather than both mid-flight: one waiting on review or on a slow pipeline, one being written. Waiting on a twenty-minute pipeline is exactly the window for the second thing, and that is the honest answer to how you work with a slow build — you arrange to have something else legitimately in flight rather than pushing speculatively to see whether it compiles.

**Long-running work.** Anything that will take more than a couple of days gets split so that something lands regularly. Expand and contract migrations force this naturally, and I have come to like that: it means the risky part is a small merge with a rollback, and the visible progress is real rather than a percentage.

**When something is genuinely stuck.** I timebox it. If I have been on the same wall for more than about ninety minutes without a new hypothesis, I write down what I know, ask someone, and pick up something else while I wait. That is a discipline I had to learn — the instinct is to keep going because the answer feels close, and it usually is not.

**And I close things.** A branch that will not be finished gets deleted with a note on the ticket, rather than kept around in case. Unfinished work sitting in a repository is not an asset.

</details>

---

### Q25. Tell about a process on a previous project that you thought was wrong. What did you do?

**Brief answer**
A quality gate that had been configured so it could not fail. It reported green on every build and everyone treated it as coverage. I raised it once with evidence, proposed the smallest change that would make it real, and let the owner decide the threshold.

<details>
<summary><strong>Detailed answer</strong></summary>

**The situation.** A pipeline stage existed, ran on every merge and had never once gone red. That is not reassuring, it is a symptom — a gate that cannot fail is a comment. In this case the configuration meant its findings were reported but not enforced, so a genuinely failing condition still exited zero, and the pipe it was in reported the exit status of the last command rather than of the check.

**How I raised it.** Not as an opinion. I demonstrated it: introduced a change that should obviously have been caught, showed the build going green, and showed the one-line reason. That took twenty minutes and it converted an argument about process into a fact everyone could see. This is the thing I would say generally about process disagreements — a demonstration ends the conversation, an opinion starts one.

**What I proposed.** The smallest change that made the gate real, plus a known-good and known-bad pair committed as a check on the check, so that if someone loosens it later the loosening itself fails. I deliberately did not propose a strict threshold at the same time. Bundling "make this work" with "and make it stricter" gives people a reason to reject both, and the threshold is genuinely the lead's call, not mine.

**How it landed.** It was accepted, with a lower threshold than I would have picked. That is fine — a gate that fires at a modest level is infinitely better than one that cannot fire, and the level is easy to raise later once people have seen it catch something real.

**What I would not have done.** Complained about it in a channel, or fixed it unilaterally in a merge request that also did four other things. A process change that arrives as a surprise inside someone else's diff generates resistance out of proportion to its size, and reasonably so.

**The general rule I take from it:** before trusting any check, I want to have seen it fail once for a real reason. That applies to a pipeline stage, a test, an alert and a monitoring dashboard equally. A check that has only ever passed has not been shown to check anything.

</details>

---

### Q26. Documentation: what did you actually write, and what did you find was worth keeping current?

**Brief answer**
Design decisions with the trigger that would reverse them, and runbooks for things that are executed under pressure. Everything else rots. Anything that describes what the code does is better generated or deleted, because it will diverge and nobody will notice.

<details>
<summary><strong>Detailed answer</strong></summary>

**What survives contact with a changing system.**

- **Why a decision was made, and what would reverse it.** This is the only documentation I have seen stay true, because it describes a judgement rather than a state. "We use an event-maintained projection rather than a materialised view because refreshes must be incremental; we would switch if the read model became small and whole-table refresh became cheap." That paragraph is still correct in two years even if every identifier in it changed.
- **Runbooks for procedures executed rarely and under stress.** Restore, failover, key rotation, the dead-letter drain, the rollback. These stay current because they get executed — and if they are rehearsed on a schedule, the rehearsal is what corrects them. A runbook nobody runs is a wish list.
- **The data model, at the level of what owns what.** Which store is the source of truth for a fact and which stores are derived from it. That changes rarely and it is the thing a new person most needs.

**What rots, reliably.**

- Anything restating what the code does. It is out of date by the second sprint and it is confidently wrong, which is worse than absent.
- Screenshots of anything.
- Setup instructions that are not executed by a script or a pipeline. If the local stack is described in prose rather than in a compose file, the prose is wrong.
- Sequence diagrams for a flow that is still being changed.

**The rule I work to.** One owner per fact. If a fact has a home — a schema, a configuration file, the interface description document — every other document references it and adds nothing. Restating it elsewhere is duplication even when the wording differs, and duplication is precisely what drifts. When something genuinely needs a new home, I would rather add one tight document that owns it than spread the same explanation across three that already exist.

**Where I write it.** In the repository, next to the thing it describes, so it appears in the diff when the thing changes. Documentation in a separate system is documentation nobody is prompted to update.

</details>

---

### Q27. How do you hand over work — to a reviewer, to the next person, or across a holiday?

**Brief answer**
The merge request description does most of it: what the change is for, what I decided and why, what I deliberately did not do, and what a reviewer should look hardest at. For a holiday, anything unmerged gets written down on the ticket in enough detail that someone else could take it, and then I assume nobody will.

<details>
<summary><strong>Detailed answer</strong></summary>

**To a reviewer.** I write the description as if the reviewer has not seen the ticket, because half the time they have not. Four things: the problem, the approach and the alternative I rejected, the risk and how it rolls back, and where I want attention. That last one is worth more than people expect — "the query plan on the second commit is the part I am least sure about" directs a reviewer's limited attention to where it pays, rather than having them spend it on the boilerplate.

I also read my own diff first, as if someone else wrote it, and fix what I find before asking for anyone's time. A reviewer's attention is a scarce resource on a team with slow pipelines, and spending it on things I could have caught myself is a bad trade.

**Across a holiday.** Everything unmerged either gets landed behind a flag, or gets closed with the reasoning captured on the ticket. What I write is the state of my understanding, not just the state of the code: what I established, what I ruled out and why, what I would do next and what I am unsure about. The code is in the branch and can be read; the reasoning only exists in my head and is the part that is expensive to reconstruct.

I also name the two or three things most likely to break while I am away and who knows about each. Not because I expect them to break, but because the cost of writing that is five minutes and the cost of not having it is someone's afternoon.

**On permanent handover.** The honest version of this is that a handover document is a poor substitute for the things that should have been in place all along — tests that fail when a control is removed, reasoning in the design file, a runbook that has been executed. If a handover needs to be long, that is usually a sign the knowledge was never externalised, and the fix is retrospective rather than documentary.

**One thing I insist on:** whoever picks it up gets a conversation, not just a document. Twenty minutes of questions is worth more than two pages, and it tells me which parts of what I wrote were not as clear as I thought.

</details>

---

## Quality Culture and Robust Development

---

### Q28. How do you argue for the time to write tests when a lead already considers the feature done?

**Project:** general

**Brief answer**
By not treating it as a separate phase to negotiate. Tests are part of the change, so the estimate includes them and the merge request contains them. Where I genuinely need extra time, I ask for it in terms of a specific risk rather than as a general principle.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the argument is usually lost before it starts.** If the ticket was estimated as "build the feature" and testing is proposed afterwards, it looks like additional scope arriving late, and it will be cut — reasonably, from the perspective of the person planning. So the estimate covers the whole change from the beginning, and the merge request lands complete. Nobody has to approve tests that were never presented as optional.

**When the conversation genuinely has to happen**, it is usually about a specific hard test rather than about testing in general: an integration test against real data stores for a path that has been guessed at, a crash-recovery test on a consumer, a negative authorization test that requires new fixtures. Those are real additional days and they deserve a real conversation.

**How I frame it.** Not "we should have better test coverage", which is a principle nobody disagrees with and nobody funds. Instead: here is the specific failure this catches, here is why it would be silent in production, here is what it would cost us to find it the other way. "If the tenant filter regresses we will find out from a customer, and this test is half a day" is a decision someone can make. A general appeal is not.

**What I do when the answer is no.** Ship it, and record the gap explicitly — in the merge request and as a ticket, saying what is untested and what the exposure is. That is not passive aggression; it is so that the decision is visible and revisitable rather than becoming an invisible property of the codebase. Quite often the ticket gets picked up later by someone who has more room than I did.

**Where I would not take no for an answer.** A control whose failure is silent and whose consequence is a disclosure or a lost fact. Those I would treat as part of the change rather than as a negotiable extra, because shipping the control without the test that proves it exists means shipping something nobody can verify. If that is genuinely contested, it goes to the lead as a risk statement in writing rather than as an argument in a review thread.

**The thing that removes most of these conversations.** Being fast at the tests that matter. A lot of resistance to testing is really resistance to a slow, awkward test suite — good fixtures, factories and a stack that starts quickly change the economics enough that the argument stops being necessary.

</details>

---

### Q29. Pipelines here take twenty to thirty minutes. Realistically, how does that change your day?

**Brief answer**
It changes what I push, not how much I deliver. I run the fast gates locally before pushing, batch related changes into one merge request rather than pushing per commit, and always have a second thing legitimately in flight so the wait is not idle.

<details>
<summary><strong>Detailed answer</strong></summary>

**The habit that matters most: do not push to find out.** A twenty-minute pipeline punishes speculative pushes brutally, so the loop moves locally. Formatting, linting and type checking run on commit through a hook — those catch the majority of what a pipeline would reject, in seconds. The relevant unit tests run before I push. The integration suite against the real data stores I run locally for the area I touched, not the whole thing.

**Batching.** Three small pushes in sequence cost an hour of pipeline; one merge request with the same three changes costs twenty minutes. So I hold related work together, which has a side benefit — a merge request that represents one complete change is easier to review and easier to roll back than three that only make sense as a set.

**Filling the wait honestly.** The second task is real work, not context-switching for its own sake: reviewing someone else's merge request, writing the description for the thing in flight, updating the ticket, or starting a task I can pause cleanly. What I avoid is starting something that will itself be half-finished when the pipeline comes back, because then I have two half-things.

**What I would not do, and this is where I would push back if asked.** I would not shorten it by weakening a gate. A fast pipeline that cannot catch a broken migration is worse than a slow one that can, and the integration stage against real stores is exactly the part people propose cutting because it is the slow part — and it is the part that catches the query plans and the broker behaviour that mocked tests pass while broken.

**Where I would look for real time, if asked to.** Parallelising independent stages rather than removing them; caching dependency installation and the built image layers properly; running the full integration matrix on the merge to the default branch while merge requests run the affected subset; and making sure the slow stage is slow for a reason rather than because containers are being rebuilt from scratch each run. Those are engineering fixes to the pipeline, not reductions in what it proves.

**And there is a temperament question underneath this.** I am fine with it. The alternative — a fast loop with weak gates — moves the wait to production, where it is much more expensive and lands on someone else.

</details>

---

### Q30. A technical lead sends your merge request back for a third time over test style you do not think is better. What do you do?

**Brief answer**
I make the change and ask, once and privately, what the underlying rule is so I can apply it myself next time. Three rounds on style is a signal that a convention exists in someone's head and not in writing, and the useful outcome is getting it written down — not winning the round.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I make the change rather than argue it.** Test style is almost never worth the cost of the disagreement. The reviewer owns the standard for the codebase they will maintain, my preference is genuinely just a preference, and the currency I would spend arguing it is currency I want available for the review where something is actually wrong. Being difficult about small things makes people discount you on large ones.

**What I do alongside making the change.** I ask what the rule is, in a direct message rather than in the thread, phrased as wanting to get it right next time rather than as a challenge. Most of the time there is a real rule — a naming pattern that makes failures greppable, a fixture convention that keeps the suite parallel-safe, an aversion to a mocking style that has burned them before — and once I know it, the problem disappears permanently. Occasionally the honest answer is that it is taste, and knowing that is also useful: I just apply their taste.

**Then I suggest writing it down, once.** Not as a criticism. Something like: this came up a few times, would it help to put it in the contributing notes so the next person gets it on their first merge request rather than their third. That is an easy yes for most leads and it converts a recurring friction into a one-line convention. If the answer is no, I drop it and keep applying the taste.

**What I would not do.** Argue it in the thread across three rounds, escalate it, complain about it to teammates, or comply while making it obvious I am complying grudgingly — that last one is the most damaging and the easiest to do accidentally in written comments.

**Where I would hold my ground.** If the requested change makes the test worse in a way that matters — a test that no longer asserts the property, a fixture that makes a real failure mode untestable — I say so, once, specifically, with the failure it would stop catching. That is a different conversation from style and it is worth having. If the lead still wants it after hearing that, I do it and note the gap on the ticket rather than relitigating.

**Honestly:** I expect some of this on any team and I do not find it demoralising. It costs a day now and then. A codebase where the tests all look the same is worth a fair amount of that.

</details>

---

### Q31. The client says quality is valued far more than speed. What does "moving cautiously" look like in your actual work?

**Brief answer**
Mostly it looks like doing the reading before the writing: reconstructing what the requirement actually implies, checking the plan on anything touching a large table, and making every change rollback-safe by default. It is not slower typing, it is fewer things discovered late.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before writing anything.** I reconstruct what the ticket implies from the system rather than assuming, because on a mature codebase the constraints usually decide most of the answer. That means reading the schema and the migration history for the area, finding what already writes to it, and identifying which invariants my change could break. On a table with a hundred million rows and a partitioning scheme, half the possible implementations are ruled out before the first line.

**While writing.** Expand and contract on anything touching the schema, as a rule rather than a judgement call — a release only adds; removals land at least one release later. That single discipline is most of what "cautious" means in practice, because it is what keeps rollback available for the whole window. Anything touching a hot query gets the plan looked at against realistic data before I claim it is fine. Anything whose failure is silent gets a test that fails when the control is removed.

**Before asking for review.** Read my own diff as if someone else wrote it. Run the fast gates locally. Check the change against the acceptance criteria on the ticket line by line — cross-checking the requirement is a separate act from believing I have met it, and I have been wrong often enough to make it a step rather than a feeling.

**Where cautious costs real time and I would spend it anyway.** Verifying a performance claim before quoting it, rather than repeating a number from a design document. Testing a claim the system's correctness depends on — that a library version actually propagates trace context, that a queue type actually behaves as documented under the settings we use — rather than assuming. Those are the assumptions that are cheap to check now and expensive to discover during an incident.

**What cautious does not mean.** It does not mean gold-plating, adding abstraction for futures nobody has asked for, or refusing to ship until everything is perfect. It also does not mean silence — moving carefully and going quiet for a week are different things, and the second one is what makes people nervous. I would rather ship a smaller slice carefully and say so daily.

</details>

---

### Q32. How do you cross-check that what you built is actually what was asked for?

**Brief answer**
Against the written acceptance criteria, item by item, as an explicit step before review — and if there are no written criteria, I write them and get them confirmed before I start. Checking against my memory of a conversation is not checking.

<details>
<summary><strong>Detailed answer</strong></summary>

**The step itself.** Before I open a merge request I put the acceptance criteria next to the diff and go through them one at a time, marking each as met, not met, or met differently. The third category is the valuable one — it is where I implemented something reasonable that is not what was asked, usually because the system pushed me somewhere, and it always needs to be said out loud rather than absorbed. That goes in the merge request description and on the ticket.

**When there are no criteria, which is common.** A one-line ticket has none by definition. So I write what I believe the criteria are, in the ticket, before starting, and ask the person who owns the business logic to confirm or correct them. That converts an ambiguous task into a checkable one and it takes about ten minutes. It also means the record of what was agreed lives on the ticket rather than in a chat thread that scrolls away.

**Three checks beyond the criteria list**, because criteria describe the happy path and rarely describe the boundaries:

- **What should still be true afterwards.** The invariants nobody wrote down because they are assumed — no cross-tenant read, no unaudited access, no double charge. A change that satisfies every criterion and breaks one of those has failed.
- **What is explicitly out of scope.** Both these systems have stated scope boundaries, and the risk in an abstract ticket is not doing too little, it is quietly crossing a line the product said it would not cross. So I check against the exclusions as deliberately as against the requirements.
- **What the person will actually do with it.** Reading the criteria as a workflow rather than a list catches the case where every item is satisfied and the screen is still unusable.

**And I demo it, briefly, to whoever asked.** Five minutes of showing the thing working catches misunderstandings that no amount of written criteria does, and it catches them before review rather than after release. This is the cheapest quality step there is and the one I skipped most often earlier in my career.

</details>

---

### Q33. What do you do about linters and formatters that disagree with you?

**Brief answer**
I lose the argument on purpose. A formatter's job is to end the conversation, and the value is in there being one answer rather than in it being my answer. Where a linter rule is genuinely wrong for the codebase, I would change the configuration for everyone rather than suppress it locally.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I do not fight the formatter.** Formatting is the lowest-value thing a human can spend attention on and the easiest thing to argue about, which is a bad combination. Once it is automatic and runs on commit, nobody discusses it, diffs stay small because reformatting churn disappears, and review attention goes to the change. I have preferences and I abandon them cheerfully.

**Linters are different because they can be wrong.** A formatter has no opinion about correctness; a linter does, and sometimes its opinion does not fit. My order of response:

1. **Assume it is right first.** Most of the time the rule is catching something real and my irritation is that the fix is inconvenient. A broad exception clause, a mutable default, a shadowed name — those look pedantic and are not.
2. **If it is genuinely wrong here, fix it at the configuration.** Turn the rule off for the codebase or for a directory, in the shared configuration, with a comment saying why. That is reviewable and it applies to everyone.
3. **A line-level suppression is a last resort and needs a reason attached.** A bare suppression comment with no explanation is a defect in its own right — the next person cannot tell whether it was considered or whether someone was in a hurry.

**What I watch for.** Suppressions accumulating in one area is a signal about the code rather than about the linter. If a module needs five exceptions, the module is fighting the language's grain and that is worth a conversation.

**On introducing new rules.** Turning on a strict rule in a large codebase produces hundreds of findings and a demoralised team. I would rather enable it in warning mode, fix the findings area by area in separate small merge requests, and make it blocking only when the count is zero. Enabling it and leaving a backlog of failures teaches everyone to ignore the tool, which is worse than never having enabled it.

**And I would push for one tool over several where possible.** A single fast linter that also formats removes an entire class of tools disagreeing with each other, and the second-order benefit — a pre-commit hook that finishes in a second — is what makes people actually leave it switched on.

</details>

---

### Q34. Tell about a bug that got past your tests. What did you conclude?

**Brief answer**
A check that had never failed. It looked like a passing test and it was structurally incapable of failing — the fixture it ran against short-circuited before the logic under test was reached. The conclusion was that a check which has only ever passed has not been shown to check anything.

<details>
<summary><strong>Detailed answer</strong></summary>

**What happened.** A test asserted a behaviour on a fixture that also carried an earlier condition, and the earlier condition matched first. The code path the test was named after was never executed. The test passed, always, for a reason unrelated to its name — and because it passed, everyone including me read the suite as covering that behaviour. When the behaviour broke, nothing went red.

**Why it is a hard class of defect.** A failing test announces itself. A test that passes for the wrong reason is invisible by construction, it accumulates trust over time, and it actively prevents someone from writing the real test because the area already looks covered. It is worse than no test.

**What I changed.** Three things, and they are now habits rather than reactions.

- **One fixture, one behaviour.** If a fixture carries several conditions, the test can only honestly assert the first that fires, and every later assertion on it is decoration. So the trigger for the behaviour under test appears only in the region under test, and nothing else in the fixture can satisfy the assertion.
- **Confirm the test fails before trusting it.** Mutate the behaviour it names, run it, see it go red for the expected reason, restore. Ten seconds, and it is the only evidence that a check checks anything. I do this when I write the test, not later.
- **Three outcomes, never two.** Pass, fail, and could-not-run. A check whose harness errored, or whose mutation did not take, must not be able to report as either a pass or a catch — otherwise it silently folds into whichever branch was written first, and that is always the one confirming what you already expected.

**What I also concluded about mutations specifically.** A mutation that introduces a syntax error makes everything fail at once, which reads as overwhelming evidence and is worthless — it is a could-not-run. So the mutated file gets parsed before any conclusion is drawn from it.

**And the general shift in how I read a suite.** A green build is evidence only about the checks that can fail. So the question I ask about any gate, test or alert is: have I seen this go red for a real reason? If not, it is decoration until proven otherwise.

</details>

---

## AI Tooling and Policy

---

### Q35. What would make you stop using an assistant tool part-way through a task?

**Project:** general

**Brief answer**
When I notice I am accepting output faster than I am understanding it, when the task turns out to depend on a constraint the tool cannot see, or the moment the work touches material that must not leave the tenancy. The first is the one that requires self-awareness rather than a rule.

<details>
<summary><strong>Detailed answer</strong></summary>

**The signal I watch for in myself.** A rhythm where I am reading the output for plausibility rather than for correctness. It feels productive and it is the exact failure the client's leads are concerned about — code that is fine-looking and unowned. When I catch it, I stop, and I usually go back over what I have already accepted, because the drift starts earlier than the moment I notice it.

**When the task turns out to be the wrong shape for it.** These tools are strong where the answer is conventional and the cost of a mistake is low. They are weak where the answer depends on a constraint specific to this system that is not visible in the code — a partitioning scheme, an authorization boundary, a query plan, a rollback window. The suggested migration is textbook-correct and wrong here because it takes a lock the table cannot afford. Once I realise a task is in that category, the round trip of prompting, reading and correcting exceeds just thinking it through, and continuing is a way of avoiding the thinking.

**Immediately, on data.** The moment the work involves patient text, client-confidential material, or anything with credentials in it. That is not a judgement call in the moment — it is why the test data is synthetic by construction, so what I paste from a failing test is harmless by default rather than by my remembering.

**Two smaller ones.** When I have asked the same thing three times and the answers are circling, which means my question is wrong rather than the answers. And when I find myself unable to explain a branch to a hypothetical reviewer — that is the point where it does not go any further, because I will be the one debugging it.

**What I do instead of pushing on.** Go back to the primary source — the engine's documentation, the library's release notes, the migration history — and read. That is slower and it is the thing that leaves me able to answer the next question, which is the part that gets lost when the tooling does the understanding.

**And the honest observation.** I find these tools most useful at the start of a task and at the end — orientation, and a second reader on my own diff before I spend a person's attention on it. In the middle, where the decisions are, they mostly help me type things I already knew, and noticing when I have crossed from one mode into the other is most of using them well.

</details>

---

### Q36. How do you review generated tests specifically?

**Brief answer**
By checking that each one can fail. I mutate the behaviour the test names and confirm it goes red for the right reason. Generated tests are unusually likely to assert that code ran rather than that it is correct, and they arrive green, which is exactly the combination that gets them accepted.

<details>
<summary><strong>Detailed answer</strong></summary>

**The specific failure patterns I look for**, because they recur:

- **Asserting the mock rather than the outcome.** A test that verifies a function was called with certain arguments verifies that the implementation is the implementation. It passes forever and it fails on every refactor while never failing on a behaviour change — the exact inverse of what a test should do.
- **Asserting that nothing raised.** Calling the function and checking it did not throw is coverage without verification. It is the single most common shape in generated suites because it always passes.
- **Fixtures that satisfy the assertion by themselves.** A fixture carrying a condition that short-circuits before the logic under test is reached. The test then passes for a reason unrelated to its name. This is the one I have actually been bitten by and it is undetectable by reading.
- **Over-broad exception assertions.** Asserting that some error was raised, when the interesting property is which one and with what message. A test that accepts any failure will happily accept a completely different bug.
- **Tests that restate the implementation.** If the assertion is derived from the code rather than from the requirement, it will follow the code into being wrong.

**The check I actually run.** Break the thing on purpose, run the test, confirm it goes red, confirm it goes red for the expected reason rather than for a setup error, restore. That takes seconds and it is the only evidence that separates a test from a comment. I do the same for tests I wrote by hand, but I do it without exception for generated ones.

**What I keep and what I throw away.** I mostly keep the list of situations and rewrite the assertions. The genuinely valuable output is "here are eight cases you did not think of" — the boundary values, the empty collection, the concurrent case. The assertions I write myself, from the requirement, because that is the part that has to be right.

**And I never let coverage be the justification for keeping one.** A test kept because it moves a percentage is worse than the uncovered line it replaced, because the uncovered line was at least visible as a gap.

</details>

---

### Q37. What would you never put into an assistant tool at work, and how do you make sure that rule holds?

**Brief answer**
Patient data, client material, credentials and anything covered by a confidentiality obligation. The rule holds because it is enforced by configuration and habit rather than by intention — a rule I have to remember at the moment of temptation is a rule that will fail once.

<details>
<summary><strong>Detailed answer</strong></summary>

**The categories, concretely.** Clinical free text, symptom values and anything identifying a patient. Client-confidential material, including briefs and internal documents. Secrets of any kind — connection strings, tokens, keys — and this includes pasting a stack trace or a configuration block without checking what is embedded in it, which is how most accidental disclosures actually happen. Third-party material we are contractually bound on.

**Why "I will be careful" is not a control.** It relies on me noticing at exactly the moment I am tired and trying to get an error understood. So the controls have to be structural:

- **Use tooling approved for the tenancy**, and know whether it retains input, rather than assuming. That is a question with a documented answer and it should be answered before the tool is installed, not after an incident.
- **Redact at the source.** Test data and fixtures are synthetic, so what I paste from a failing test is synthetic by construction. This is the single highest-leverage control — if the data I work with locally is never real, the accidental paste is harmless.
- **Never paste a raw configuration or environment block.** If I need help with a configuration, I reproduce the shape with placeholder values.
- **Keep the boundary at the tool, not at the prompt.** Anything indexing a whole repository is a different risk category from something answering one question, and it needs to be an explicit decision with the client rather than a personal one.

**On the client's position here.** They are becoming more open to these tools while keeping security and data protection in mind, and I think that is exactly the right posture. What I would want, joining a team like that, is to know where the line is drawn rather than to infer it — which tools are approved, whether repository-wide indexing is permitted, and whether anything about the client's own systems may go into a prompt. I would ask that in the first week rather than guess, because guessing conservatively costs a little productivity and guessing liberally costs the engagement.

**If I made a mistake.** I would report it immediately, to the lead and to whoever owns security, with exactly what was disclosed and when. The instinct to quietly hope is the thing that turns a small incident into a serious one.

</details>

---

### Q38. Where has assistant tooling actually not helped you?

**Brief answer**
Anywhere the reasoning is the deliverable. Migration strategy on a very large table, an authorization boundary, a query plan, a concurrency decision. It produces something plausible in those areas, and plausible is precisely the failure mode — checking it costs more than thinking it through.

<details>
<summary><strong>Detailed answer</strong></summary>

**The pattern.** These tools are strongest where the answer is conventional and the cost of a mistake is low, and weakest where the answer depends on a constraint specific to this system that is not visible in the code. Both of those are true at once in exactly the places that matter most.

**Concrete examples from this work.**

- **Migrations on a hundred-million-row table.** The suggested migration is almost always correct in a textbook sense and wrong here, because it takes a lock the table cannot afford, or it adds a non-null column in one step, or it builds an index without the concurrent option. The right answer depends on the partitioning scheme, the traffic pattern and the rollback window, none of which appear in the diff.
- **Anything about a query plan.** A suggested index is a guess. The only thing that settles it is the plan against realistic data on the pinned server version, and no amount of reasoning about the query substitutes for that.
- **Authorization.** The suggested check is usually the per-endpoint one, which works until someone adds an endpoint. The design decision — put the control in the layer that cannot be bypassed — is not the obvious answer and it will not be proposed.
- **Concurrency and idempotency.** Where the guarantee has to come from a database constraint rather than from application logic, the generated version reliably puts it in application logic, because that is what most code does.

**The second thing it does not help with**, which is less about correctness: understanding a system well enough to make a judgement about it. Reading the code and the migration history myself is slower and it is the thing that lets me answer the next question. Outsourcing that leaves me with a change I can defend and a system I cannot.

**And a small honest one.** It is not faster for anything I already know how to write. The round trip of prompting, reading and correcting exceeds just typing it, and the temptation to accept what came back because it is there is real.

**Where that leaves me.** I use it heavily for the first and last ten percent of a task — orientation and self-review — and barely at all in the middle, where the decisions are.

</details>

---

### Q39. A teammate submits a large merge request that reads as fully generated. What do you do?

**Brief answer**
I review it exactly as I would any other change, and where I cannot follow the reasoning I ask them to explain it rather than commenting on how it was written. If they cannot explain it, that is the finding — and it is a finding about ownership, not about tooling.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I do not lead with the accusation.** I cannot actually tell how code was written, and being wrong about that is both insulting and unrecoverable. What I can tell is whether the change is coherent, whether the tests assert anything, whether the error handling is real, and whether the author can explain the decisions. Those are the properties that matter, and they are reviewable without any claim about provenance.

**What the review looks like.** The same checks as always, applied without shortcuts: does the failure mode get handled or swallowed, is the migration rollback-safe, does the test go red if the behaviour breaks, is there an abstraction here that no requirement asked for. Generated changes tend to fail in characteristic ways — broad exception handling, tests asserting the mock, a layer of indirection nobody needed, comments restating the code — so those get specific attention, but as findings rather than as evidence.

**The one question that resolves it.** "Walk me through why this branch is here." A short call rather than a comment thread. If the answer is fluent, the code is owned and I was wrong about the shape. If the answer is not there, the conversation is already happening in the most productive form — not "this looks generated" but "we need to work out what this does before it merges", which is a thing we can do together.

**On size.** A very large merge request is its own problem regardless of authorship, and it is worth saying so plainly: I cannot review a thousand-line change properly and neither can anyone else, so the honest response is to ask for it to be split. That is a request I would make of anyone, and it happens to address most of the risk here anyway.

**Escalation.** I would not take this to a lead on a first occurrence. If it were a pattern — repeated large changes the author cannot explain — that is a conversation with them first, directly and privately, and then with the lead if it continued, framed as a maintainability risk rather than as a policy violation. The team's problem is unowned code; how it got there is secondary.

</details>

---

## Conflict, Communication and Professional Conduct

---

### Q40. A team chat thread is openly critical of a core technology choice on the project, and others are piling on. You privately share some of the frustration. What do you do?

**Brief answer**
Nothing in the thread — no reply, no reaction, not even a supportive one. If I have a real technical objection I take it to the person who owns that decision, in writing, naming a mechanism and a cost. A complaint that names no mechanism cannot be acted on and costs the team more than it returns.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why silence rather than participation.** A public complaint about a platform choice reaches people who were not in the conversation and cannot answer it — including the people who made the decision, and often the client. It reads as a verdict on their judgement rather than as a technical point, and it has no path to a fix. Adding a reaction to it is not a neutral act either: it is a signal of agreement with the framing, it is visible to everyone, and it is exactly as attributable as writing the message myself. So I do not react.

**Why I would not privately agree in a side conversation either.** That is the same act with a smaller audience and it still spreads the framing. If the frustration is real, the useful version of it is a specific problem, and the way to be useful is to write that down.

**What I do instead, when the frustration has substance.** Convert it into something actionable and take it to the designated technical contact for that area: here is the specific thing that is slow or awkward, here is the mechanism behind it, here is what I would try, here is what it would cost. Sometimes the answer is that it is a known constraint with a reason. Sometimes it is a real problem nobody had stated precisely, and stating it precisely is worth more than any amount of agreement in a channel.

**And where the frustration has no substance**, which is often — it is fatigue rather than a technical position — I let it be fatigue and do not dress it up as engineering. Not every irritation is a design finding.

**On the professional stakes.** I have worked in environments where publicly criticising the stack damages trust badly and irreversibly, and I think that reaction is more reasonable than engineers usually credit: from outside, it looks like the people paid to make something work have decided it cannot. Rebuilding that trust costs far more than the complaint was ever worth. So my line is simple and I hold it consistently — technical criticism goes to the people who own the decision, never to a room.

**If I felt something was genuinely wrong and being ignored**, I would escalate it properly: raise it with my lead, in writing, with the cost stated. That path exists and it works. It is a different act from complaining, and it is the one that changes things.

</details>

---

### Q41. You think a core technology choice on the project is wrong. Who do you raise it with, and how?

**Brief answer**
The person who owns the decision, in the artifact where the decision lives — a design document or a merge request — and framed as a trigger rather than a verdict: here is the condition under which this choice stops working, here is what it would cost to change, here is what I would want to measure first.

<details>
<summary><strong>Detailed answer</strong></summary>

**Before raising it at all, I do the work.** Most objections to an established choice dissolve on contact with the reason it was made, and raising one that dissolves costs credibility I will want later. So: find out why it was chosen, what was considered and rejected, and what has changed since. If there is no written reason, that is itself worth surfacing, gently — a choice nobody can explain is a genuine risk regardless of whether it is right.

**How I frame it.** Not "this is the wrong database". Rather: this workload has a property the current choice handles badly, here is the specific mechanism, here is the measurement that would confirm or refute it, and here is what changing would cost. That framing does three things — it makes the objection checkable, it separates my hypothesis from a fact, and it gives the owner something to decide rather than something to defend.

**I try to state their position accurately first.** If I cannot articulate why the current choice is reasonable, I have not understood it yet and I am about to argue with a version of it I invented. That habit has stopped me raising several objections that were simply wrong.

**Where it goes.** In the design document that owns the area, or in a merge request comment where the code makes the trade-off. Not in a chat channel, not in a standup, and not as a general observation to the team. The written form matters because the outcome I actually want is not "we change it" — it is that the reasoning and the reversing condition are recorded, so the next person inherits a decision rather than an argument.

**When the answer is no.** That is a legitimate outcome and I take it. What I ask for in that case is that the trade-off and its trigger get written down, so that when the condition arrives someone recognises it. Then I get on with it, and I do not keep reopening it — relitigating a settled decision is corrosive and it is how someone becomes the person others route around.

**The one exception.** If the concern is a security or data-protection issue rather than an engineering preference, it does not go through this process. It goes immediately to the lead and to whoever owns security, in writing, and I do not let it rest on a design discussion.

</details>

---

### Q42. Tell about feedback you received that you disagreed with at the time.

**Brief answer**
Being told my merge requests were too large. I thought the change was cohesive and splitting it would be artificial. The reviewer was right, and what convinced me was not the argument but noticing how much of my own review feedback on large changes was superficial.

<details>
<summary><strong>Detailed answer</strong></summary>

**The feedback.** That my changes were hard to review because they arrived as one piece — a schema change, the code that used it, a refactor of the surrounding module and the tests, all together. My position was that they were one logical change and splitting them would produce commits that did not make sense on their own.

**Why I was wrong.** Two reasons I came to independently.

The first is about review quality. I noticed that when I reviewed a very large change, my comments were about naming and structure — the things you can see without holding the whole thing in your head — and that I had not actually verified the risky part. Reviewers were doing the same to mine. So the large merge request was not getting more review, it was getting less, while looking like it had been reviewed.

The second is about rollback. A change bundling a schema migration with a refactor cannot be reverted cleanly, because the revert takes the migration with it. Splitting them is not cosmetic — it is what makes each part independently reversible, and that is precisely the capability you want on the release that turns out to have a problem.

**What I do now.** Expand and contract on migrations forces a split naturally, and I lean on that. Refactors go in their own change, before or after, never inside a behavioural one. If a change cannot be split, that is usually a signal the boundaries in the code are wrong, which is worth knowing.

**How I handled the disagreement at the time**, which is the part I would want to convey: I said I disagreed, said why, and then did it their way while I found out. I did not comply silently and resent it, and I did not argue it across three reviews. Doing it their way for a few weeks is a much cheaper experiment than a debate, and it is the one that actually settles which of us was right.

**The general lesson.** Feedback about process is usually feedback about an effect the giver has observed and the receiver has not. Asking what they have seen go wrong is more productive than defending the position, and it is what I do now when I disagree with a review comment.

</details>

---

### Q43. How do you raise a problem you have found in someone else's area?

**Brief answer**
Directly to them first, privately, with evidence rather than a conclusion — and with an offer to help rather than a handover. What I try hardest to avoid is discovering it publicly, because being surprised in front of the team is what makes someone defensive about a problem they would otherwise have fixed.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence.** Verify it myself first, so I am reporting a fact rather than a suspicion — a reproduction, a query plan, a log line. Then a direct message to the owner: here is what I saw, here is how to reproduce it, I might be missing context. That last clause is not politeness for its own sake; I frequently am missing context, and leaving room for it is what stops the conversation starting adversarially.

**Then it becomes theirs.** They own the area, so they decide the severity and the fix. If they want help, I help. If they disagree that it is a problem, I ask what I am missing, and quite often the answer is satisfying. If I still think it matters after that, it goes into a ticket with both positions stated, which is a legitimate place for a disagreement to rest.

**Where the sequence changes.** If it is a live incident or a security issue, it goes to the lead and the owner simultaneously and immediately — the courtesy of a private first conversation is worth less than the hours. I would say that explicitly to the person rather than quietly go around them: I am raising this now because of what it is, not because I doubted you.

**What I avoid.**

- Raising it in a group channel or a standup first. That converts a technical finding into a status judgement in front of an audience.
- Fixing it silently in someone else's area. It looks helpful and it is not — they now maintain a change they did not make and did not learn from, and I have taken a decision that was theirs.
- Framing it as a category. "The import path is fragile" is an opinion about their work; "the import path retries without an idempotency key, so a redelivery double-applies, here is the reproduction" is a finding about the code. The second is easy to act on and takes nothing personally.

**And I follow up once, then let go.** If it is not fixed and it is not mine, I have raised it, it is written down, and the decision belongs to them. Continuing to push on someone else's backlog is not diligence.

</details>

---

### Q44. What does professionalism mean to you when you are working inside a client's team rather than your own company's?

**Brief answer**
Being straightforward about what is true, careful about what is theirs to decide, and consistent about how I behave whether or not anyone is watching. Practically it means their processes are followed even when I would do it differently, and their internal dynamics are not mine to comment on.

<details>
<summary><strong>Detailed answer</strong></summary>

**Following their process rather than importing mine.** Their ticketing, their branch conventions, their review standards, their reporting cadence. I might think a step is inefficient; I follow it anyway and raise the suggestion once through the proper channel. Arriving and reforming someone's process is a way of telling a team their judgement is worse than yours, and it rarely goes well even when you are right.

**Being honest about capability.** If I have not used something, I say so and describe what is adjacent. Overclaiming buys a few weeks and then costs the engagement — and it is much worse for a client than a straight answer at the start, because they have planned around the claim. The same goes for progress: a task that is going badly gets reported as going badly on the day, not on the due date.

**Staying out of their internal dynamics.** Every organisation has friction, and as an external engineer I see it without the history that produced it. It is not mine to have an opinion about, and taking a side in something I only half understand is both unhelpful and very hard to undo. I keep technical conversations technical and route them through the designated contacts.

**Their data is theirs.** Access is used for the work and nothing else. Nothing confidential leaves the tenancy, including into tooling. And I do not carry material from one engagement into another, in either direction — that is the whole basis on which a client can trust an external engineer at all.

**Consistency.** How I write in a review, in a ticket comment, in a chat message and in a meeting should be the same. Written communication is permanent, it is read by people who were not there, and tone does not survive the trip — so I write plainly, without sarcasm, and I assume anything I write may be read by the client's management. That is not paranoia; it is just accurate about how these environments work.

**And doing the unglamorous parts.** Daily updates, accurate time tracking, mandatory training, the routines that make an organisation legible to itself. Treating those as beneath the engineering work is the most common way external engineers become unpopular, and it is entirely avoidable.

</details>

---

### Q45. You are joining a team that runs mandatory security and inclusivity training and places real weight on how people speak to each other. How do you approach that?

**Brief answer**
As part of the job rather than as an interruption to it. I do the training when it is scheduled rather than at the deadline, and I take the underlying expectation seriously — most of what makes a team pleasant to work in is small, repeated behaviour rather than policy.

<details>
<summary><strong>Detailed answer</strong></summary>

**On the training itself.** I do it early. It takes an afternoon, it is a condition of access on a system holding sensitive data, and treating it as an imposition signals something about how seriously I take the rest of the obligations that come with that access. On the security side specifically, I have found it genuinely useful more than once — the parts about how disclosure actually happens in practice tend to be more concrete than engineers expect.

**On the behaviour it is trying to produce**, which is the substantive part. What I try to do:

- **Write as if the reader is having a bad day**, because a proportion of the time they are, and text carries no tone. Sarcasm and jokes at the code's expense read very differently to the person who wrote it than to the person writing them.
- **Criticise the change, never the person.** "This query will issue one round trip per row" rather than "you have written an N+1 again". The information content is identical and only one of them is something to defend against.
- **Be careful with humour in a group setting**, particularly across languages and cultures. What lands as light in one register lands as dismissive in another, and I am not always the best judge of which.
- **Make room in meetings.** Noticing who has not spoken and asking them directly is a small habit with a disproportionate effect, especially on a distributed team where interrupting is harder for some people than others.
- **Assume good faith about a process I find annoying.** It usually exists because something went wrong once.

**On working across cultures and languages.** I write plainly, avoid idiom, and check understanding rather than assuming agreement — a nod in a call is not confirmation. And if I get something wrong, I would rather be told directly than have someone work around me, so I try to make it easy to tell me.

**Honestly.** I do not think of this as a constraint on how I would otherwise behave. A team where people are careful with each other is a team where problems get raised early, and problems raised early are the entire game in this work.

</details>

---

### Q46. How do you handle a disagreement when you are working in a language or a culture that is not your own?

**Brief answer**
I move it to writing, because writing gives everyone time and removes the disadvantage of speed. And I check understanding explicitly rather than reading agreement into a silence, since silence means very different things in different places.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why writing helps.** In a live conversation in a second language, the fastest and most confident speaker wins by default, which has nothing to do with who is right. Putting the disagreement in a merge request comment or a short document levels that: everyone can take their time, re-read, and answer precisely. It also produces a record, which means the outcome is something the team can look at later rather than something two people remember differently.

**Not reading agreement into silence.** In some working cultures, disagreeing with a more senior person directly and publicly is not done, so "no objection" can mean anything from consent to strong disagreement expressed by not speaking. So I ask specifically — "what would make this a bad idea?" rather than "does everyone agree?" — and I ask individuals rather than the room. If someone has a concern, I would much rather hear it now.

**Being explicit about what kind of statement I am making.** A strong technical opinion and a casual suggestion sound very similar in a second language, particularly in writing, and getting that wrong in either direction is costly. So I label it: this is a blocking concern, or this is a preference and I will drop it. That removes a whole class of misreading.

**Assuming the misunderstanding is mine first.** When something reads as brusque or dismissive, the most likely explanation is register rather than intent — someone writing in their second or third language does not have the softening vocabulary available, and directness is the default in plenty of places. Taking offence at that is my error, not theirs. So I ask what they meant before reacting to what I read.

**And the same courtesy in reverse.** I write simply, avoid idiom and humour that depends on a shared culture, and keep sentences short. It costs me nothing and it removes a real barrier for people doing more work than I am to have the conversation at all.

**Where I would ask for help.** If a disagreement is not resolving and I suspect it is not about the technical question, I would ask someone who knows the organisation — a lead or a colleague who has been there longer — rather than pushing harder. That is usually a five-minute conversation that reframes the whole thing.

</details>

---

## Unclear Requirements, Autonomy and Proactivity

---

### Q47. Who do you go to when a ticket is abstract and the lead who wrote it is unavailable for two days?

**Brief answer**
Whoever holds the business logic rather than whoever wrote the ticket — usually an application manager or a product owner. Meanwhile I do all the work that does not depend on the answer, and I write down the specific decisions I cannot make alone so the conversation is short when it happens.

<details>
<summary><strong>Detailed answer</strong></summary>

**First: the ticket author is often not the person with the answer.** A lead writing a one-line ticket is frequently relaying a requirement rather than owning it. So the question is who owns the business logic, and on both these systems that was an application manager or a product owner rather than an engineering lead. Going to them directly is not going around anyone — it is going to the source — and I would mention to the lead that I did.

**Second: the system already answers a lot of it.** Before asking anyone I reconstruct what the existing code, schema and stated scope boundaries imply. On a mature system that usually eliminates most of the interpretations. If the product has an explicit exclusion — no diagnostic or triage decision support, say — that rules out a whole class of readings before anyone is asked anything.

**Third: do everything that does not depend on the answer.** There is almost always real work that is invariant across the plausible interpretations: the data access, the test scaffolding, the migration shape. Two days is not a blocked two days unless I let it be, and arriving at the conversation with the mechanical part already built changes the ask from "what did you mean" to "does this do what you wanted".

**Fourth: write down the decisions only they can make.** Not questions — proposals with a default. "I propose a sustained deterioration means three consecutive days below the baseline; I propose it notifies the named clinician rather than the whole care team; I propose the flag is advisory. Tell me which of these is wrong." Reacting to a concrete reading is much faster for someone than authoring one, and it takes twenty minutes instead of a week.

**What I do not do.** Sit on it quietly and report it as blocked, or pick the most expansive interpretation because it is the most impressive. And I put the blocker on the ticket the day it appears, with what I have already done, so nobody has to ask.

**If two days becomes a week**, I raise it with my own lead — not as a complaint, but because a decision waiting on one person for a week is a planning problem someone else should know about.

</details>

---

### Q48. How do you decide when you have asked enough questions and should start building?

**Brief answer**
When the remaining unknowns no longer change the shape of the work — only its details. If a question's two possible answers lead to the same data model and the same interfaces, I build and confirm the detail later. If they lead to different models, I stop and get it answered.

<details>
<summary><strong>Detailed answer</strong></summary>

**The test I apply.** For each open question: does the answer change something expensive to reverse? Schema, an interface other teams consume, a boundary about who can see what, a decision that would require a migration to undo. Those get answered first, always. A threshold, a label, a default value, an ordering — those can be a parameter with a sensible default and a comment saying it is a placeholder, agreed later without rework.

**Why not just ask everything up front.** Two reasons. It is expensive for the person answering, and a long list of questions before any work has started invites the answer "let's have a workshop", which is a week. And a lot of questions answer themselves once something exists — people are far better at reacting to a working thing than at specifying one, so getting a rough version in front of them is often the fastest way to get the requirement.

**What I do with the ones I proceed past.** They go on the ticket explicitly as assumptions, phrased so that someone reading it can object. "Assuming this applies to the named clinician only, not the whole care team — say if that is wrong." Making the assumption visible is what makes proceeding safe. An assumption held privately is a guess; an assumption written down is a decision someone can correct cheaply.

**When I stop and refuse to proceed.** Where every interpretation is unsafe if wrong — anything touching who may see what, anything with a clinical or financial consequence, anything crossing a stated scope boundary. Building carefully in the wrong direction on one of those is worse than waiting, because the wrong version is the one that ships.

**Timeboxing the ask.** If I have raised something and it is not answered within a reasonable window, I proceed on the most conservative interpretation — the one that does the least and is easiest to extend — and say so clearly. Conservative is the right default because the risk in an abstract ticket is rarely doing too little.

**And I timebox my own thinking too.** If I have spent more than an hour trying to infer intent from the code, that is a signal to go and ask rather than to keep inferring.

</details>

---

### Q49. What does proactivity look like on a team whose stated preference is steady progress and no pressure?

**Brief answer**
Doing things nobody had to ask for, at a pace nobody has to absorb. Fixing the thing that will bite in a month, writing down the reasoning that only exists in someone's head, raising a risk early — none of which requires anyone else to move faster.

<details>
<summary><strong>Detailed answer</strong></summary>

**The distinction I would draw.** Aggressive proactivity is about pace and it lands on other people: pushing for a faster decision, escalating to force a priority, shipping something unasked and presenting it as a fait accompli, being visibly impatient with a process. Every one of those transfers my urgency onto someone else's day. Quiet proactivity is about scope and it lands on me: doing the extra thing inside my own work, surfacing information early, reducing what someone else has to do.

**What that looks like concretely.**

- **Raising a risk the day I see it**, with a proposal attached. Early information costs the recipient nothing and is the single most valuable thing I can offer. Raising it late is what creates pressure.
- **Doing the adjacent thing while I am in there.** The missing test on the control I just touched, the runbook step that turned out to be wrong, the metric that would have caught the failure I just debugged. Small, in scope, nobody else has to react.
- **Executing the thing that is written down but never done.** A restore, a failover, a key rotation. That is proactive and it disturbs no one.
- **Offering an option rather than pushing a decision.** "Here are two ways, here is what each costs, I would pick the first" — the decision stays with whoever owns it, and I have made it cheap for them.
- **Asking what would help.** Frequently the answer is not what I would have guessed.

**What I would not do here.** Push someone for an answer twice in a day. Reopen a settled decision because I have new enthusiasm for my original position. Ship an unrequested refactor across someone else's area. Treat a slow process as an obstacle to route around — that reads as contempt for how the team works, even when it is not meant that way.

**On pace generally.** I would rather deliver steadily and predictably than in bursts. A team can plan around someone whose output is even; nobody can plan around a burst followed by a rollback. And on a system where a mistake is expensive and slow to surface, a measured pace is not a cultural preference — it is the correct engineering speed.

</details>

---

### Q50. Tell about a time you reverse-engineered business logic from an existing system. How did you do it, and how did you check you were right?

**Brief answer**
By reading the schema and the constraints first, then the code paths that write to it, then confirming the reconstruction with the person who owns the rules. The database is the most honest description of what a system actually enforces, because it is the part that cannot be bypassed.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the schema first.** Application code describes what someone intended on the day they wrote it, and there may be five paths with five interpretations. The unique constraints, the foreign keys, the check constraints and the exclusion constraints describe what is actually true of every row, including the ones written before anyone joined. On a catalog system, discovering that a listing revision is immutable and that the current pointer is a column on the parent tells you more about the domain rules than a directory of service code.

**Then the migration history**, which is the record of what changed and, more usefully, what got walked back. A column added and removed two releases later is a business rule that was tried and rejected, and knowing that stops you proposing it again.

**Then the write paths.** Not all the code — the places that mutate the tables I care about. What validates, what refuses, what is idempotent, what emits an event. That is where the rules that are not in the schema live, and it is a much smaller surface than the whole codebase.

**Then the data itself**, where I have access to a safe copy. Distributions answer questions no document does: how many listings actually use this optional field, do these two columns ever disagree, is this nullable column ever null in practice. A rule that the code enforces and the data violates means the rule arrived after the data, which is important context.

**How I check I am right.** I write the reconstruction down as a short set of statements — "a listing cannot be published while its vendor is pending", "a connection request bills at most once" — and take it to whoever owns the business logic with the question "which of these is wrong?". That is a five-minute conversation and far more productive than asking them to explain the system from scratch. People are much better at correcting a wrong statement than at generating a complete one.

**And where a rule matters, I assert it in a test.** That converts my reconstruction from a belief into something that fails when it stops being true, which is the only version that survives.

</details>

---

### Q51. You realise mid-task that the requirement as written will not work. What then?

**Brief answer**
Stop, work out precisely why, and go back within the day with the problem and at least one alternative. What I try not to do is quietly implement the nearest thing that does work, because then the decision has been made by me and nobody knows it happened.

<details>
<summary><strong>Detailed answer</strong></summary>

**First, establish that it genuinely will not work.** "Will not work" comes in several strengths and they call for different conversations: it is technically impossible; it is possible but would break something else; it is possible but the cost is far beyond what anyone expects; or it will work and produce an outcome nobody wants. Only the first is really a blocker. The others are trade-offs, and presenting a trade-off as an impossibility is a bad habit — it removes someone else's decision by mislabelling it.

**Then go back the same day.** Not at the end of the task, not in the review. What I bring: what the requirement implies, the specific reason it fails, what it would cost to do anyway, and one or two alternatives that deliver most of the value. The alternatives are the important part — arriving with only a problem hands someone a decision with no options, which is the slowest possible way to resolve it.

**Concretely, the shape it usually takes.** Someone asks for a field to be required so a view looks complete, and requiring it would either stop vendors publishing or fill the field with noise. The response is not "no", it is: here is what requiring it does, here is what I think you actually want, here is a way to get that. Nine times out of ten the underlying goal is achievable by a different mechanism and the conversation takes fifteen minutes.

**If the answer is to do it anyway.** That is a legitimate call for whoever owns it. I state the cost plainly and in writing — what breaks, when it surfaces, what it will take to undo — and then I build it properly. What I do not do is build it grudgingly, or badly, or with an "I told you so" comment in the code. The follow-up work goes on the backlog as a ticket rather than as a memory.

**And I write down what changed.** The agreed criteria go on the ticket, and anything that alters a documented boundary goes into the design file that owns it. Otherwise the next person finds a system that does not match its own specification and cannot tell whether that is a bug.

</details>

---

### Q52. How do you avoid building the most expansive interpretation of a vague ticket?

**Brief answer**
By checking against the stated scope boundaries as deliberately as against the requirements, and by defaulting to the smallest version that delivers the value. On a system with explicit exclusions, the risk in an abstract ticket is not doing too little — it is quietly crossing a line the product said it would not cross.

<details>
<summary><strong>Detailed answer</strong></summary>

**The pull towards expansion is real and it is not laziness — it is the opposite.** A vague ticket invites you to imagine the impressive version, and building the impressive version feels like initiative. It is usually a mistake: it takes longer, it is harder to review, it commits the product to a shape nobody agreed, and it is much harder to take away later than it would have been to add.

**What I check against.**

- **The stated exclusions.** Both these systems have explicit scope boundaries — things the product has decided it does not do. A generous reading of "surface deteriorating patients to the care team" slides very easily into triage decision support, which is out of scope for good reasons. Checking the exclusions is a separate act from checking the requirements and it catches a different class of error.
- **What the smallest useful version is.** One category, one locale, one channel, one audience. If the mechanism is right, coverage is the part that expands later and it expands cheaply. Building the mechanism for five cases when one is needed is the expensive direction.
- **Whether I am building for a requirement or for a hypothetical.** "We will probably want this configurable" is the classic tell. If nobody has asked, it is a constant.

**When the expansive version is genuinely better**, which happens — I propose it rather than build it. "The ticket asks for A; for roughly the same effort we could do A and B, which I think is what you actually want. Say which." That keeps the decision where it belongs and costs one message.

**And I make the smallness visible.** The merge request says what I deliberately did not do and why. That is important: a reviewer seeing a narrow implementation cannot tell whether the author considered the wider case and chose against it, or never thought about it. Saying so converts a possible oversight into a stated decision.

**The underlying instinct.** Adding is cheap and reversible; removing is expensive and political. So when I am uncertain, I do less and say so.

</details>

---

## Delivery, Estimation and Negotiation

---

### Q53. Estimates here are frequently wrong — a task estimated at three days can take a week. What do you actually do on day two when you can see that happening?

**Brief answer**
Update the remaining estimate that day and say why in one sentence, on the ticket and in the standup. Not on the due date. Raising a slip early is almost free; raising it late is never, and the cost is not the delay — it is the surprise.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** I revise the remaining estimate, not the original. The original is a historical artifact and rewriting it destroys the only information a planner has about how the work is diverging. Alongside the new number goes the reason, specifically: not "taking longer than expected" but "the column has to be added in three releases because the table is partitioned and the backfill cannot hold a lock, so the migration is two more days than I planned".

**Why the reason matters more than the number.** A reason lets someone decide something. If the delay is the migration, maybe the migration can be split and the rest can ship. If it is a dependency on another team, maybe someone can chase it. A bare slip with no cause gives the recipient nothing to act on and reads as an apology, which is not what they need.

**Why I do not wait to be sure.** The instinct is to hold on for another day in case it recovers, and it usually does not, and now the news is worse and later. I would rather revise upward on day two and revise back down on day four than deliver a surprise on day five. Nobody has ever been annoyed with me for the first pattern.

**On the estimates being wrong in the first place.** They are, systematically and in one direction, on this kind of work. Anything touching a migration on a very large table, an authorization boundary, or a query plan takes longer than it looks, because the implementation is small and the verification is not. I try to say that when estimating rather than after — "this is two days of code and three days of verifying the plan and the rollback" makes the number legible and much more likely to survive.

**And I do not stress about it, which I think is the actual question.** An estimate is a forecast made with the least information anyone will ever have about the task. Being wrong is normal. What is not acceptable is being wrong quietly. As long as the number in the tracker reflects what I currently believe, updated daily, the process is working even when the original estimate was poor.

</details>

---

### Q54. How do you estimate a task that touches a migration on a very large table?

**Brief answer**
By estimating the verification rather than the code, because the code is an hour and the verification is the task. And by splitting it into releases up front — expand, backfill, contract — so the estimate is for three small landings rather than one uncertain one.

<details>
<summary><strong>Detailed answer</strong></summary>

**What actually consumes the time.**

- **Deciding the shape.** Adding a non-nullable column to a hundred-million-row table is not one operation; it is add nullable, backfill in bounded batches, add the constraint as not-valid, validate it, and only then make anything depend on it. Working out which of those the table and its partitioning can tolerate is most of the thinking.
- **The backfill.** Batched, throttled, resumable, and rehearsed against a realistic copy so the duration is a measurement rather than a guess. This is the part that is genuinely unpredictable and it is why I want a rehearsal in the estimate.
- **Verifying rollback.** The previous image has to run against the new schema for the whole window. Confirming that is a test, not an assertion.
- **The plan.** A new index changes plans on queries nobody mentioned. Checking the affected ones against realistic data is work.

**How I present the number.** Split by release rather than as a total: expand is a day, the backfill is a day plus a rehearsal, contract is half a day in a later release, and the verification is spread across them. That is more useful than a single figure because it shows what can be parallelised, what can be deferred, and where the risk sits. It also makes the trade-off visible if someone wants it faster — the thing you would cut is the rehearsal, and I would want that decision made knowingly.

**What I refuse to compress.** The expand-and-contract discipline itself. Skipping it to save a few hours removes the ability to roll back for the entire release window, which is precisely the capability you want on a release that turned out to have a problem. If a migration cannot be written that way, it gets split across two releases — that is a rule I apply rather than a judgement I make case by case.

**The honest caveat I attach.** Anything involving a lock on a large table has a tail risk that no estimate covers: it behaves differently under production traffic than under a rehearsal. So the estimate comes with a stated plan for what happens if the backfill has to be stopped halfway, which is a question I would rather answer in advance than at two in the morning.

</details>

---

### Q55. What do you put in a ticket comment when you are blocked?

**Brief answer**
What I need, from whom, what I have already tried, and what I am doing in the meantime. A blocker written that way can be acted on by someone reading it cold; "blocked on infrastructure" cannot.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four parts, and why each is there.**

- **The specific thing needed, and who owns it.** Not "waiting on the platform team" but "waiting on the read-replica connection string for staging, raised with the platform team on Tuesday, their ticket number is on this one". Someone can pick that up without asking me anything.
- **What I have already tried.** This prevents the most annoying possible reply, which is a suggestion I ruled out two days ago. It also demonstrates the blocker is real rather than a first hurdle.
- **What it is costing.** Is this stopping me, or will it stop me on Friday? Those need completely different responses and only I know which it is. Saying "not blocking yet, I have unblocked myself by testing against a fake, it becomes blocking Friday" tells people they can leave it alone, which is genuinely useful information.
- **What I am doing meanwhile.** So nobody has to wonder whether I am idle, and so the status is complete rather than a fragment.

**Where it goes and when.** On the ticket, the day it appears, and mentioned once in the standup. The ticket rather than a chat thread, because chat scrolls and the ticket is where someone looks in a week when they want to know why this took as long as it did.

**Escalation, and how I pace it.** Raised with the owner directly first. If there is no response in a reasonable window, a follow-up with a date attached — "we need this by Thursday to hold the release, can you tell me if that is realistic". If that goes nowhere, it goes to my own lead, not to theirs. Going over someone's head gets the thing once and costs the relationship for every subsequent ask, and on a long engagement I will need them again.

**And I close the loop.** When it unblocks, the ticket says so and thanks whoever did it, publicly. That costs nothing and it is a large part of why the next request gets picked up faster.

**One thing I try to avoid:** describing another team as blocking me in a shared channel. It is a complaint dressed as a status update, and it makes the next ask harder for no gain.

</details>

---

### Q56. Tell about a deadline you missed. What did you do about it?

**Brief answer**
A search feature that slipped because the index rebuild turned out to take materially longer than anyone had assumed. I flagged it as soon as I had the measurement, proposed a reduced first cut that shipped on the date, and the full version landed later.

<details>
<summary><strong>Detailed answer</strong></summary>

**What happened.** The plan assumed a rebuild from the primary stores was a background detail. It was not — the actual duration, measured rather than estimated, changed both the release plan and the recovery objective we had been prepared to publish. I found that out by running it, which is the good news; the bad news is that it was late enough that the date was already committed.

**What I did in order.**

- **Measured it properly before saying anything, but only just.** I wanted to bring a number rather than a worry, and that took a few hours, not a few days. There is a real temptation to keep investigating until you have a solution — that is how a slip becomes a surprise.
- **Told the people who owned the date the same day**, with the measurement, the reason, and the impact stated in their terms rather than mine.
- **Brought a reduced scope rather than a request for time.** A labelled fallback — chronological browse from the primary store — was a fraction of the work and delivered most of the value for the first release. That is the thing I would most want to convey: arriving with a smaller shippable slice is a much better conversation than arriving with a request for two more weeks.
- **Said plainly what the reduced version does not do**, so nobody discovered it later.

**What I changed afterwards.** The estimate now includes the rehearsal explicitly, as a line item rather than as an implicit part of "build the thing". And more generally I stopped treating any documented procedure as costed until someone had run it — a design sentence describing a rebuild, a restore or a failover is an assumption about duration as well as about feasibility.

**What I would not do differently.** Flagging early even though I did not yet have a full plan. There is a strong instinct to arrive with the problem solved, and it is wrong: the people planning around the date can do more with three days' notice and no solution than with one day's notice and a good one.

</details>

---

### Q57. How do you say no, or not yet, to a request from someone senior?

**Brief answer**
By not saying no. I say what it would cost and what it would displace, and let them decide — most requests that look like they need refusing actually need a price attached. Where I do have to refuse outright, it is because the thing is unsafe, and I say that specifically rather than generally.

<details>
<summary><strong>Detailed answer</strong></summary>

**The default response.** "Yes, and here is what it displaces." A senior person asking for something usually does not have visibility into what else is in flight, and supplying that is more useful than a refusal. "I can have that by Thursday if the import work waits until next week — which would you rather?" hands the prioritisation back to the person who owns it, which is where it belongs. It also means I am never the obstacle; the constraint is.

**Where the answer really is not yet.** Same shape, with the reason attached: this depends on a decision we have not made, or on a migration that has to land first, so it cannot start before then. Being specific about the dependency is what makes it credible — a vague "we are not ready" invites pressure, a named prerequisite invites help removing it.

**Where I genuinely refuse.** A small set of things where the failure is silent and expensive to undo: shipping something with the authorization boundary incomplete, skipping expand-and-contract on a migration, disabling a gate to get a release out, putting confidential data somewhere it should not go. On those I say clearly that I am not comfortable doing it and why, in one or two sentences, without a lecture. And then — this part matters — I offer the nearest thing I can do: a smaller scope that is safe, a feature flag, a manual step with an audit record.

**If they insist after hearing the cost.** For anything that is a trade-off rather than a safety issue, that is their call to make and I make it work. I write the cost down — what breaks, when it surfaces, what it takes to undo — and the follow-up becomes a ticket rather than a grievance. For an actual safety or compliance issue, I would escalate rather than comply, and I would tell them I was doing that rather than doing it quietly.

**Tone.** No drama, no implied criticism, no visible reluctance. The goal is that asking me a question is cheap and gets an honest answer, and anything that makes someone hesitate before asking is a cost I do not want to introduce.

</details>

---

### Q58. What makes you comfortable that a piece of work is actually finished?

**Brief answer**
That it is deployed, that I have seen it work with real traffic, that the failure I most expect would be visible, and that someone else could roll it back without me. Merged is not finished, and green is not finished either.

<details>
<summary><strong>Detailed answer</strong></summary>

**The checklist I actually run.**

- **The acceptance criteria are met, checked item by item against the diff**, with anything met differently stated explicitly rather than absorbed.
- **The tests assert the property, not the implementation**, and I have seen at least the important ones fail for the right reason.
- **It is rollback-safe.** The previous image runs against the current schema; the rollback is a revision revert rather than a bespoke recovery. If I cannot describe how someone undoes this without me, it is not finished.
- **Its failure is visible.** If this can break silently — a derived store drifting, a permission being wrong, a job not running — there is a metric or an alert that would show it. This is the step most often skipped and it is the one that separates finished from merged.
- **It has run in production long enough to see real traffic.** Staging tells you the code works; production tells you the assumptions did. For anything touching a query plan or a broker, that means watching the relevant numbers for a day, not glancing at a dashboard on release.
- **The written trail is updated.** Ticket closed with what actually shipped, design file amended if a documented decision changed, runbook updated if the operational procedure changed.

**What I explicitly do not count as finished.** Merged with a green pipeline. Deployed but never exercised. Working but only understood by me. And "done except for the tests", which is a category I try not to have.

**The one that took me longest to learn.** Watching it after release. There is a strong pull to move to the next ticket the moment something merges, and most of what a change teaches you arrives in the following day or two — the plan that regressed on a query nobody mentioned, the queue that grew slightly, the cache hit ratio that moved. Being present for that is part of the work, and it is also how you find out whether the thing you built is the thing anyone needed.

</details>
