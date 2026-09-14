# Verification and Domain Knowledge

> 16 questions on pytest fixtures and async and consumer tests, test data and traceability, Prometheus, [APM](https://en.wikipedia.org/wiki/Application_performance_management "Application Performance Monitoring — Gives visibility into request latency, errors and traces in production") and Kibana, the log, metric, audit and trace boundary, alert fatigue and latency-incident diagnosis, and reasoning about the retail and [ERP](https://en.wikipedia.org/wiki/Enterprise_resource_planning "Enterprise Resource Planning — Integrated software that manages an organization's core business processes") domain and about a stack never used before. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except VER-01, VER-02, VER-03, VER-04, VER-05, VER-06, VER-08, VER-09, VER-10, VER-11, VER-13, VER-15 and VER-16, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — VER-01, VER-02, VER-03, VER-04, VER-05, VER-08, VER-09, VER-10, VER-11, VER-13
- **retail-software-marketplace** — VER-01, VER-02, VER-03, VER-04, VER-05, VER-07, VER-10, VER-12, VER-13, VER-15, VER-16
- **general** — VER-06, VER-14

---

## 1. Testing

---

### VER-01. Describe your experience with Pytest. What do your fixtures look like on a project with real data stores?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Session-scoped fixtures bring the containers up once and run migrations; a function-scoped fixture wraps each test in a transaction that is rolled back afterwards. That combination gives real database behaviour with per-test isolation and no teardown cost.

<details>
<summary><strong>Detailed answer</strong></summary>

**The layering.**

- **Session scope**: start the containers — database, document store, cache, broker, search — at pinned versions matching production, and run the migrations once. Expensive, done once.
- **Function scope**: open a connection, begin a transaction, hand the test a session bound to it, and roll back at the end. Every test sees a clean database without truncating tables or re-running migrations, which is what keeps a suite with real stores fast enough to be tolerable.
- **Factories rather than fixture data files.** A helper that creates a valid entity with sensible defaults and accepts overrides for the fields the test cares about. A test then reads as "a published listing from a suspended vendor" rather than as twenty lines of setup, and the intent is visible.

**The stores that do not participate in a transaction.** The document store, the cache, the broker and the search index have to be cleaned explicitly — a per-test namespace or prefix, or a truncation between tests. Getting this wrong produces the worst kind of flakiness: order-dependent failures where a test passes alone and fails in the suite.

**The fixture discipline I care most about**, because I have been bitten by it. One fixture, one behaviour. A fixture carrying several conditions can only honestly exercise the first that fires, and every later assertion on it is decoration. I had a set of checks pass for reasons unrelated to what they named because a fixture carried a condition that short-circuited before the logic under test was ever reached — so both the thing being tested and a second thing looked covered, and neither was. Now the trigger for the behaviour under test appears only in the region under test, and nothing else in the fixture can satisfy the assertion.

**Other things I rely on.** Parametrisation for boundary cases, so one test body covers the empty, single and many cases with the failure naming the case. Marks to separate fast unit runs from the slow integration suite, so the local loop stays quick. Dependency overrides at the application level to substitute a controlled principal or an external client.

**And the check I run on any test I intend to trust.** Break the behaviour it names, confirm it goes red for the expected reason, restore. A test that has never failed has not been shown to test anything, and this takes seconds at the time of writing and is nearly impossible to retrofit honestly later.

</details>


---

### VER-02. How do you test asynchronous code and message consumers?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Against a real broker, not a mock, because the behaviours worth testing are redelivery, acknowledgement and ordering — none of which a mock reproduces. And the important tests are the unpleasant ones: kill the consumer mid-task, deliver the same message twice, deliver two messages out of order.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why a mocked broker is close to worthless here.** It confirms the handler function does what the handler function does. Everything that actually goes wrong is in the interaction: a message acknowledged before the work completed, a handler that is not idempotent under redelivery, a binding pattern that matches nothing, a payload that fails validation and is retried forever. A mock passes all of those while broken.

**The tests I would insist on for any consumer.**

- **Redelivery is harmless.** Deliver the same message twice, assert one row and one side effect. This is the test that proves the idempotency guarantee is real — and it should be proving a database constraint rather than an in-memory check, so it still holds after a restart.
- **Out-of-order delivery does not roll state backwards.** Deliver a newer event then an older one, assert the newer state survives. This is what the source revision on the event is for, and without the test it is an intention.
- **A crash mid-task causes redelivery, not loss.** Kill the worker while a task is in flight and assert the work completes afterwards. This is the test that actually verifies acknowledgement mode is configured as believed, and it is the one nobody writes.
- **A poison message dead-letters rather than looping.** Assert the attempt count is bounded and the message ends up somewhere visible.
- **The binding topology is what you think.** Publish with the routing key the producer really uses and assert it arrives. Binding configuration is silent when wrong — a queue bound with a typo receives nothing and reports no error — which is exactly why it belongs in a test rather than in a management interface someone eyeballs.

**On the asynchronous code itself.** An async-aware test runner, and time controlled rather than waited on — no sleeps, because a sleep-based test is either slow or flaky and usually both. Where a test must wait for a consumer, poll for the expected condition with a timeout and fail with a message naming what was expected, rather than sleeping a fixed interval and hoping.

**And the trap specific to async testing.** An unawaited coroutine silently does nothing and the test passes. The type checker catches most of these, and a warnings-as-errors setting catches the rest — worth configuring, because the failure is completely silent otherwise.

</details>


---

### VER-03. What is your approach to test data, and why not use production data?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Synthetic, generated by factories, with realistic volume where volume is the thing under test. Production data is not an option on a clinical system for legal reasons, and it is a bad idea generally — it makes tests non-reproducible and it silently spreads sensitive material into every environment.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not production data.** On the health platform it is disqualified outright: patient data outside the production tenancy has no lawful basis and anonymisation of clinical free text is far harder than people assume — a note can identify someone through circumstance without containing a name. Beyond that, and applying to any system: a test whose fixture is a snapshot is not reproducible, it drifts, it fails for reasons unrelated to the change, and copies of it end up on laptops and in backups nobody tracks.

**What I use instead.**

- **Factories producing valid entities with overrides**, so a test declares only what it cares about.
- **Deterministic generation with a fixed seed** where randomness is useful. Random data finds edge cases; unseeded random data produces failures nobody can reproduce, which is the worst of both.
- **Realistic volume where volume is the point.** This one is worth insisting on: a query performance test against a hundred rows tells you nothing, because the planner chooses differently at different scales and a sequential scan on a small table is correct. So the integration environment seeds a table to a size where the plan is the production plan. Without that, every plan assertion is meaningless.
- **Deliberately awkward values**, since real data is not tidy: names with non-Latin characters and apostrophes, timestamps across a daylight-saving boundary, an empty collection, a maximum-length string, a zero, a negative. Most boundary defects are found here rather than by volume.

**Where a production shape is genuinely needed** — investigating a defect that only occurs on real data — the answer is a controlled export with the sensitive fields replaced, produced by a reviewed process into a restricted environment, with an expiry. Not a copy of the database onto someone's machine. And on the clinical system, not at all: the investigation happens in production with the access audited, rather than by moving the data.

**One thing I would add.** The same factories are useful for seeding a local environment, which means the development stack is populated with data that exercises the awkward cases by default. A developer whose local data is all tidy will keep writing code that assumes tidy data.

</details>


---

### VER-04. The suite passes on merge requests and fails on the default branch. What is going on?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Usually one of four things: the branch ran a different subset, two independently-green branches merged into a conflict no test saw, the default branch runs against something merge requests do not, or a test is order-dependent and the fuller run changes the order.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four causes, and how to tell them apart quickly.**

- **Different scope.** If merge requests run an affected subset and the default branch runs the full matrix, then a passing merge request never proved anything about the failing test. This is the most common cause and it is a deliberate trade-off rather than a bug — the cost of a shorter feedback loop is exactly this. The check is whether the failing test was in the merge request's selection at all.
- **Semantic merge conflict.** Two branches, each green, each correct against the base. One renames a function, the other adds a call site. Version control merges both cleanly and the result is broken. Nothing tested the combination, because the combination did not exist until the merge. This is what a merge queue or a required rebase-and-rerun against the current default branch exists to prevent, and if it happens more than occasionally that is the fix.
- **Environment difference.** The default branch pipeline has credentials, a real external dependency, or a deploy target that merge request pipelines do not — often for good security reasons, since secrets are scoped to protected branches. So a whole class of test only ever runs there, and the first time it runs is after merge.
- **Order dependence.** A fuller run changes ordering or parallelism, and a test that leaks state into another surfaces. Confirmable in a minute by running with randomised order locally.

**What I do first regardless of cause.** Establish whether the default branch is broken for everyone, because that blocks the whole team and outranks diagnosis. If it is, revert the merge rather than fixing forward — a revert is fast, reversible and does not require understanding the problem yet. Fixing forward under pressure with everyone blocked is how a second defect arrives.

**Then the structural fix rather than the instance fix.** If it was a semantic merge conflict, require branches to be current with the default branch before merging, or use a merge queue that tests the merged result. If it was scope, make sure the selection logic is conservative — better to run too much than to have a class of change routinely untested. If it was environment, get an equivalent running on merge requests even if it is against a stub, so the shape of the failure is at least reachable earlier.

**And I would look at how often it happens.** An occasional default-branch failure is the normal cost of a subset strategy. A regular one means the subset selection is wrong, and the team has quietly stopped trusting merge request pipelines — which is worse than the time they save.

</details>


---

### VER-05. How do you decide what not to test?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By asking what the test would catch that something else does not, and what it costs to maintain. I do not test the framework, the language, or code whose failure is loud and immediate — and I am deliberate about it rather than just leaving gaps.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I actively choose not to test.**

- **The framework and the libraries.** A test asserting that the validation library rejects a wrong type is testing someone else's suite. The exception is where I depend on a behaviour that is version-specific or contested — a broker's semantics under a particular acknowledgement configuration, whether an instrumentation version really propagates trace context. Those get a test precisely because they are claims I would otherwise be assuming.
- **Anything a type checker already proves.** A test that a function rejects a string where an integer is expected duplicates the checker and costs maintenance on every refactor.
- **Trivial accessors and pass-throughs.** They contribute coverage and no information, and a suite full of them is what a coverage target produces when it is chased rather than used.
- **Failures that are loud, immediate and unmissable.** A missing configuration value that stops the process at startup does not need a test — it cannot ship unnoticed. Contrast that with a permission check that silently permits, which needs one badly.
- **Exact wording of user-facing strings**, unless the wording is itself a requirement. Otherwise every copy change is a red build and people learn to update assertions without reading them.
- **Third-party integrations at their own boundary.** I test that we call correctly and handle each documented response; I do not test their service. That belongs in a monitored synthetic check, not in a pipeline.

**How I decide the marginal case.** Two questions. If this broke, would anything else notice — a type error, a failing integration test, a loud crash, a metric? And what does the test cost when the code changes for an unrelated reason? A test that catches nothing new and breaks on every refactor has negative value, and removing one is a legitimate act rather than a retreat.

**Where I spend the effort saved.** On the tests that are hard: integration against real stores, the negative authorization cases, redelivery and crash-recovery, the plan shape on a query whose performance is a design property. Those cost more to write and each is worth ten trivial unit tests, and they also happen to move coverage.

**The thing I insist on when I skip something.** Say so. An uncovered path that was considered and deliberately left is a decision; one that was never noticed is a gap. So it goes in the merge request description, or in an explicit coverage exclusion with a reason — visible and reviewable — rather than being papered over with a test that asserts nothing, which is camouflage rather than coverage.

</details>


---

### VER-06. The client wants traceability from requirement to test evidence for every release. What would you put in place?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
A link that lives in the code and moves with it — tests carrying the identifier of the requirement they cover, reported automatically from the pipeline — so the evidence is generated rather than maintained. A traceability matrix kept by hand is out of date within one sprint.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the requirement really is.** Someone must be able to ask, for a given release, which requirements are covered, by what, and whether it passed. That is a legitimate need on a regulated or heavily audited product, and it is a question a code suite alone answers badly — a test file does not know why it exists.

**How I would build it.**

- **The link lives in the test.** A marker or naming convention carrying the requirement identifier, so it moves with the code, appears in the diff, and disappears when the test is deleted. A mapping maintained in a separate document is a mapping that rots, and it rots invisibly.
- **Evidence is emitted by the pipeline, not entered by a person.** Each run produces a machine-readable report of which tests ran, which requirements they cover and what the outcome was, attached to the release artifact. Nobody transcribes anything, so nobody transcribes it wrongly or late.
- **A gap report as a build output.** Requirements with no linked test listed on every run. That is the actual value — not the matrix, which is a formality, but the list of things nobody has verified, which is a finding.
- **Manual test cases confined to what genuinely cannot be automated** — exploratory work, something needing a real external system, an accessibility judgement. Each is a recurring cost forever, so the list should be short and deliberately chosen rather than accumulated.
- **The release record assembled automatically**: which commit, which image digest, which requirements, which evidence. On a system where "what was running last Tuesday and what proved it" is a real question, that record is the answer.

**The failure mode I would work hardest to avoid.** Two catalogues drifting — a managed set of test cases and a code suite that no longer correspond. A manual case survives for a year after the behaviour it describes was removed, and each regression run someone marks it passed because investigating is harder. That produces a document asserting coverage that does not exist, which is worse than having no document at all.

**What I would ask early.** What happens when an automated test is deleted — because that is where the drift starts, and the answer is usually that nobody has thought about it. And who owns the requirement identifiers, since the whole scheme rests on them being stable.

**My honest position on the tooling.** I have kept traceability through tickets with explicit acceptance criteria, tests identifiably covering them, and release notes recording what was verified. A dedicated test-management tool sitting alongside the issue tracker is a workflow I have not used; the concepts are the same and I would expect the tool itself to take days rather than weeks.

</details>

---

## 2. Observability and production diagnosis

---

### VER-07. Suppose one API endpoint suddenly becomes 10× slower. How would you investigate it?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Establish the shape before the cause: when did it start, is it one endpoint or the whole service, and is it the median or only the tail. Those three answers eliminate most of the search space. Then work the dependency chain from the trace, not from a hypothesis — the trace tells you which span grew, and the growth is almost always a plan flip, a cache that stopped hitting, a pool that started queueing, or a dependency that got slower.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three questions first, because each cuts the space in half.**

1. **When, exactly, and what changed then?** Overlay the latency graph with the deployment timeline, the configuration and feature-flag history, and the infrastructure change log. A step change at a deploy boundary is a code or migration cause; a gradual ramp over days is data volume or index bloat; a step change with no deploy is a dependency, a plan flip, or a traffic-mix change.
2. **One endpoint or all of them?** If every route on the service degraded together, the cause is shared — the event loop is blocked, the pool is saturated, the node is throttled, or the database is slow for everyone. If genuinely only one route moved, the cause is in that route's own work.
3. **p50 or only p95/p99?** A shifted median means every request now does more work. An unchanged median with a much worse tail means a subset of requests — one tenant, one large payload, one uncached path, one unlucky lock — and the fix is different in kind.

**Then follow the trace.** With distributed tracing in place — Application Insights in the marketplace, Elastic Application Performance Monitoring in the cancer platform — I compare a slow trace now against a fast trace from before the change and look at which span grew. This is the step that replaces guessing. The usual answers:

- **The database span grew.** Run `EXPLAIN (ANALYZE, BUFFERS)` on the actual query with the actual parameters. A plan flip is the most common cause of a sudden tenfold change: statistics went stale after a bulk load, a table crossed the size at which the planner stopped preferring an index, or an unselective predicate combination degraded a bitmap `AND` across several generalized-inverted indexes into a sequential scan — which the marketplace design flags in advance as this system's defining performance risk. Check `pg_stat_statements` for the query's mean time and call count, and check whether autovacuum has fallen behind on the table.
- **The database span did not grow, but the time before it did.** That is pool checkout wait — the pool is queueing. It is a distinct metric and it is the difference between "the database is slow" and "I have no connections", which have opposite fixes.
- **A cache span started missing.** `redis_cache_hit_ratio` for the keyspace is an explicit service level indicator in the marketplace precisely because the latency budget assumes 85% on the search page. A ratio collapse — a key format change on deploy, an eviction from memory pressure, a stampede after a mass invalidation — moves p95 from the ~35 ms cached path to the ~107 ms uncached path in one step, and further if the database is now carrying six times its usual load.
- **Call count grew rather than call duration.** One span taking 50 ms became forty spans taking 2 ms each: a lazy relationship became an N+1, or a bulk `$in` hydration became a per-item loop. The marketplace calls that out by name as the way its catalog design would have failed.
- **No span grew and the sum does not reconcile.** That is time in the process, not in a dependency: a blocking call on the event loop, garbage-collection pauses, or CPU throttling from a container limit. Event-loop lag and container throttling metrics settle it.
- **Everything is slow and the replica lag graph is climbing.** `postgres_replica_lag_seconds` above threshold makes `catalog-service` fail back to the primary, which is correct behaviour and also a latency change with no code cause.

**What I would not do.** Restart the pods to see if it helps, or enlarge the pool, before I know which span grew — both destroy the evidence and one of them makes a saturated database worse. And I would check whether the endpoint is actually slower or merely slower *for someone*: a tenant whose data volume grew, or a client that started sending a new filter combination, looks identical on an aggregate graph and is a different problem.

</details>


---

### VER-08. Describe your experience with Prometheus. What did you instrument, and what do your queries look like?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Application metrics exposed on a scrape endpoint and alert rules held in infrastructure code. What I instrumented was chosen so each metric names a specific failure rather than a general notion of health — index freshness, reminder lateness, consumer duration and failures, queue depth.

<details>
<summary><strong>Detailed answer</strong></summary>

**The metrics that earn their place, and what each is for.**

- **The age of the oldest unpublished outbox row.** This is index freshness expressed as a number: a stalled relay means search results silently stop updating while every request stays fast. Alerted above thirty seconds.
- **Reminder dispatch lateness at the high percentile, and delivery outcomes by state.** Reminder delivery is the clinical objective, so its lateness is a first-class metric rather than something inferred from logs.
- **Consumer task duration and failure counts per queue**, plus broker queue depth and unacknowledged counts. Queue depth doubles as the autoscaling signal, so the same number drives both scaling and paging, which keeps the two from disagreeing.
- **Authentication failures by reason, and identity provisioning failures.** A deprovisioning that did not land is a security event, not a background job, so it pages.
- **The standard request rate, error rate and duration histograms**, which are necessary and are not where the interesting failures are.

**What the queries look like in practice.** Rates over counters rather than raw counters — a counter's value is meaningless, its rate is the signal. Ratios computed from two counters for error rates rather than a pre-computed percentage, so the numerator and denominator can be inspected separately. Histogram quantiles for latency, with the caveat that quantiles from histograms are estimates bounded by bucket boundaries, so the buckets have to be chosen around the thresholds that matter rather than left at a default. And alerts written with a duration condition so a single scrape does not page anyone.

**On cardinality**, which is the mistake that hurts. A label carrying a user identifier, a request path with an identifier in it, or an unbounded error string will multiply the series count until the server degrades. Labels are bounded sets — service, queue, outcome, status class — and anything unbounded belongs in a log line, not a label. This is easy to get wrong and expensive to undo.

**Alert rules in infrastructure code.** The detail I would emphasise, because it is the one people skip. An alert silenced by hand during an incident and never restored is the standard way monitoring rots. In code, a silenced alert is a reviewable diff rather than something discovered six months later when the thing it watched failed quietly.

</details>


---

### VER-09. What does an application performance monitoring tool give you that metrics and logs do not?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
The causal path of one request across every hop. Metrics tell you something is slow in aggregate and logs tell you what happened at points; a trace tells you where the time went in this specific request, including the hops through a broker that logs and metrics show as two unrelated halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each of the three actually answers.** Metrics answer "is it happening and how much" — cheap, aggregate, no per-request detail. Logs answer "what happened here" — detailed, per-event, and disconnected across services unless correlated. Traces answer "where did the time go for this request, across everything it touched", which neither of the others can reconstruct.

**Where it earns its cost on these systems.** A request touches the gateway, the service, the database, the cache and possibly the broker. A trace with spans for each shows immediately whether the time is in query execution, in waiting for a connection from the pool, in an outbound call, or in the application itself. That distinction — waiting versus working — is the one that decides the whole diagnosis, and it is invisible in a latency metric.

**The asynchronous case is where it becomes essential rather than convenient.** A check-in arrives over the message transport, is bridged into the broker, consumed by a worker, written, and indexed. Without trace context propagating across those hops it is four unrelated log streams. With it, one trace covers the request, the event, the consumer and the index write — so when a reminder fails between the worker and the delivery function, it is one picture rather than two half-stories assembled during an incident.

**The honest caveat, which I would state before relying on it.** Trace continuity across a message broker is the claim most likely to be false as written, because it depends on the instrumentation versions actually injecting and extracting the context header on that transport. And on the older version of the lightweight publish-subscribe protocol there is no user-property header at all, so the context has to travel inside the payload envelope — a decision that must be made before instrumenting, because retrofitting it breaks every published client. So the versions are pinned and an end-to-end trace identifier is asserted in an integration test. That is a claim you do not want to discover is false during an incident.

**On sampling.** Deliberately uneven: everything for errors and for the paths carrying the important guarantees, a small percentage of routine reads. Uniform sampling at a low rate means the interesting request is the one you did not keep.

**And what it does not replace.** Audit. A trace is telemetry with a retention policy and sampling; an audit record is a durable row written in the same transaction as the access. Conflating them means the telemetry retention policy silently becomes the audit policy.

</details>


---

### VER-10. You are paged: latency is up and the error rate is flat. Walk me through it.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A flat error rate with rising latency means the system is still working and something is queueing. So the question is what everything is waiting for — a shared dependency, a saturated pool, or a cache that has stopped absorbing load — rather than what is broken.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start by bounding it.** Is it everything or one endpoint? All pods or one? When did it start, and what changed near then — a deploy, a configuration change, a scheduled job, a traffic pattern? The deploy timeline is the first thing I look at because it is the cheapest to rule out and the most common cause.

**Then split waiting from working, using traces.** The spans say whether the added time is in query execution, in acquiring a connection, in an outbound call, or in the application. That one distinction eliminates most of the space.

**The usual causes for this specific signature.**

- **A shared downstream saturated.** The database at its connection limit, or the cache slow. Everything that touches it slows together and nothing fails, because requests are queueing rather than being rejected. The tell is that unrelated endpoints degrade in step.
- **Connection pool exhaustion.** Time spent waiting to acquire, not executing — which is precisely why the database can look idle while the application is slow. Instrumenting pool wait as its own metric is what makes this a five-second diagnosis instead of an hour.
- **A cache hit ratio drop.** More requests falling through to the database, so latency rises and the database load multiplies. Causes: an eviction storm because memory filled, a key format changed by a deploy so every read misses, or an invalidation that removed more than intended.
- **A derived store falling behind**, which shows as latency on the paths that fall back to the primary.
- **Processor throttling from a limit set too low**, which looks exactly like slow code and is invisible unless the throttling metric is on the dashboard.
- **A blocking call introduced into an asynchronous path**, degrading everything on that worker together including the health probe.
- **A query plan change** after a data volume threshold or a statistics refresh. Slow suddenly, on one endpoint, with no deploy.

**What I do while diagnosing.** If it is degrading toward an outage, mitigate first — scale the affected tier, shed non-essential load, or roll back a recent deploy — and diagnose after, with the evidence captured before anything is restarted. If it is stable and merely worse, take the time to find the cause, because mitigating a latency problem without understanding it usually just moves it.

**And I check the obvious thing last but I do check it:** whether the latency is real or the measurement changed. A new endpoint with a different profile entering the same aggregate will move a percentile without anything having got slower.

</details>


---

### VER-11. Where is the line between a log, a metric, an audit record and a trace — and what goes wrong when it blurs?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Different durability, retention and access requirements, which is the whole point. The failure that matters most is treating logs as an audit trail: the log retention policy then silently becomes the audit policy, and nobody notices until someone asks for a record older than the window.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each one is for.**

- **A metric** is an aggregate number for alerting and trend. Cheap, bounded, no per-request detail. Its constraint is cardinality: a label carrying a user identifier or an unbounded error string multiplies the series count until the monitoring system degrades. Anything unbounded belongs in a log line, not a label.
- **A log** is a structured event describing what happened at a point. Sampled or dropped under pressure in some pipelines, retained for weeks, queryable by anyone with access to the log store.
- **A trace** is the causal path of one request across every hop, deliberately sampled — everything for errors and the paths carrying the important guarantees, a small percentage of routine reads.
- **An audit record** is a durable, immutable business fact about who accessed or changed what. It is written in the same transaction as the access it records, so it cannot be lost independently of the thing it describes.

**Why conflating audit and logs is the serious one.** They look similar — both are append-only records of events — so it is a natural economy to say the logs are the audit trail. Then: log retention is weeks and audit retention is years, so the record is gone when it is needed. Logs are sampled or dropped under load, so the trail has holes exactly when the system was under stress. Logs go to a store with broad read access, so an audit trail of sensitive access is readable by everyone who can query logs. And a log line is written after the fact rather than transactionally, so a crash between the action and the log leaves an unrecorded access.

That is why audit is a database table here, with its own retention, its own access control and an archive under a write-once policy with a long legal hold — and why the audit write is in the same transaction as the access, which is a deliberate coupling rather than an oversight.

**The other blurs, more briefly.** Metrics used as logs produces a cardinality explosion that takes the monitoring system down. Logs used as metrics means alerting depends on the log pipeline, which may be the thing that is failing. Traces used as audit fails because they are sampled — the request you need is the one that was not kept.

**And the content rule that cuts across all of them.** No clinical free text, no symptom values, no message bodies in telemetry of any kind. Enforced mechanically rather than culturally: a redaction filter at the formatter dropping fields marked sensitive on the model, and a pipeline check failing the build if a log call passes such a model. Intention does not survive contact with an incident at two in the morning, which is exactly when someone adds a debug line containing the object.

</details>


---

### VER-12. Nothing changed in the code, there was no deployment and no traffic spike, but lag suddenly appeared. How do you debug this, and where do you look first?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
"Nothing changed" almost always means nothing changed *in the things we deploy* — so I look first at the things that change themselves: data volume crossing a planner threshold, a background maintenance job, a partition boundary, a certificate or credential rotation, a managed-service failover, and an upstream provider. The first number I pull is which lag it is, because replica lag, projection lag, queue lag and cache-miss latency have entirely different causes and only one of them is a database problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one is refusing to accept the word "lag" undefined.** In the marketplace there are at least four distinct numbers that a user would describe the same way, and each has its own alert: `postgres_replica_lag_seconds`, `indexer_lag_seconds` (event `occurred_at` → row `projected_at`), `outbox_unpublished_age_seconds`, and `celery_queue_depth` per queue. Knowing which one moved localises the problem before any hypothesis is formed. If none of them moved and users still see staleness, the problem is in the cache layer or the client, not the pipeline.

**Then the categories of thing that change without a deploy, in the order I check them.**

1. **Data crossing a threshold.** This is the most common cause of an overnight change with no deploy. A table grows past the point where the planner's estimate flips a nested loop into a hash join, or an index stops fitting in the buffer cache, and a query that was 40 ms becomes 4 s. Stale statistics do the same thing: autovacuum falls behind on a write-heavy table, estimates drift from reality, and the plan degrades. The check is `EXPLAIN (ANALYZE, BUFFERS)` on the slow query and a comparison of estimated against actual rows — a three-orders-of-magnitude divergence is a statistics problem, and `ANALYZE` is the immediate test.
2. **Autovacuum itself.** A long-running transaction somewhere is pinning the oldest snapshot, so vacuum cannot reclaim dead tuples across the whole database. Table bloat rises, scans read more pages for the same rows, and everything gets slower with no change anywhere. `pg_stat_activity` ordered by `xact_start` finds it in one query, and this is the case where the cause and the symptom are in different services entirely.
3. **A time-driven job.** A monthly partition boundary, a nightly reconciliation sweep, a retention detach, a backup window, a [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") expiry wave in Mongo. These are in the design and they are still surprising at 03:00 because nobody correlates them by default. Worth putting the schedule on the same dashboard as the lag.
4. **The managed service moved.** A Flexible Server maintenance failover, a replica rebuild, a [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") node swap. Failover is 60–120 s of failed writes by design, but the after-effects are longer: a cold buffer cache on the new primary, a reconnect storm, and a replica that has to catch up. The platform's activity log answers this and it is not somewhere application engineers instinctively look.
5. **A credential or certificate rotation.** Key rotation with an overlap window that turned out to be shorter than a cache's refresh interval produces intermittent failures that look like latency because of the retries in front of them. In the marketplace the specific known trap is the gateway's [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")) cache refreshing on a different schedule from the application's, so during a signing-key rotation the two can disagree.
6. **Upstream.** A third-party provider slowing down turns into queue depth on our side. If the queue that is backing up is the dispatch queue, the problem is probably not ours at all.
7. **A noisy neighbour on shared infrastructure** — one tenant's bulk import occupying the worker pool, which is the specific failure the per-vendor concurrency cap exists to prevent, and worth confirming rather than assuming the cap held.

**What I would not do.** Start by reading recent commits. The premise says there were none, and the single biggest waste of an incident hour is refusing to believe the premise. I would also not restart anything before capturing the lock graph, the running queries and the plan — a restart usually clears the symptom and destroys the evidence, and then it recurs.

**What I would put in place afterwards.** If this was a silent degradation, the gap is not the fix, it is the detection. `indexer_lag_seconds` alerting at 60 s exists precisely because a dead indexer raises no error — new listings simply stop becoming searchable. Every derived or projected view needs a freshness metric with an alert, because the failure mode of a projection is silence. And the deployment timeline, the maintenance-event feed and the scheduled-job calendar belong on the same dashboard as the latency graph, so "did anything change" is a glance rather than an investigation.

</details>


---

### VER-13. Your team is getting too many alerts. How do you fix that without going blind?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By auditing every alert against one test — did a human need to act, and did they — then deleting or demoting the ones that fail it. Alert fatigue is not solved by tuning thresholds; it is solved by having far fewer things that page, each of which is trusted.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it has to be fixed rather than tolerated.** An on-call rotation receiving twenty pages a night learns to acknowledge without reading. At that point the alerting system has negative value: it costs sleep and it provides no detection, and the one real incident arrives in a stream of noise that has already trained everyone to dismiss it. Muting is what happens next, and a muted alert is worse than an absent one because everyone still believes it is there.

**The audit.** For every alert that fired in the last month: did it require a human to act immediately, and did a human act? Four outcomes.

- **Fired and needed action** — keep, and check the runbook is accurate.
- **Fired and nobody acted, and nothing bad happened** — it should not page. Demote to a dashboard or a ticket.
- **Fired repeatedly for the same underlying cause** — a symptom of over-alerting on causes. Replace several cause-alerts with one symptom-alert on the objective, and let the dashboard explain why.
- **Never fired** — either the condition never occurred, or the rule is broken. A rule with a typo in a label matches nothing forever, so this needs checking rather than assuming.

**The structural changes that usually follow.**

- **Alert on symptoms, not causes.** One alert on the user-facing objective, with the causes as dashboard panels. Alerting on every possible cause guarantees a storm during an incident, which is precisely when clarity matters most.
- **Duration conditions**, so a single scrape does not page.
- **Thresholds derived from the objective** rather than from a round number someone liked.
- **Grouping and inhibition**, so a downstream failure does not page for every dependent service.
- **Every paging alert names an owner and a runbook.** An alert with neither will be muted, deservedly.
- **A message stating what is wrong and what it means**, not a metric expression. The reader is half asleep.

**What I would protect from the cull.** The alerts for silent failures, even though they fire rarely — index freshness, projection lag, dead-letter depth, identity provisioning failures. Those are precisely the ones nothing else surfaces, and their rarity is an argument for keeping them rather than against.

**And the rules go in infrastructure code**, so a threshold change or a silence is a reviewed diff rather than a click. That is what stops the set decaying again six months later, which is otherwise exactly what happens.

</details>

---

## 3. Domain and unfamiliar stacks

---

### VER-14. This vacancy involves working with InterSystems IRIS, which supports both relational and document data models; given your experience with both PostgreSQL and MongoDB, how would you approach designing a data access layer in Python that effectively bridges these two different storage paradigms?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
I have not worked with InterSystems [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage"), so I would answer this from the two-store version of the same problem, which I have built twice. The design principle transfers directly: the access layer exposes one repository per aggregate returning typed domain objects, and which paradigm serves a given field is an implementation detail behind that boundary — with the important difference that on a single engine, the two halves can share a transaction, which removes the projection pipeline and the reconciliation job that the two-store version has to pay for.

<details>
<summary><strong>Detailed answer</strong></summary>

**Being straight about what I have and have not done.** My experience is [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") plus [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") as separate engines, and PostgreSQL `jsonb` as a document model inside a relational one. IRIS's model — where the same data is reachable as objects, as relational tables and as globals over one storage engine — is adjacent to the second of those rather than the first, and I would expect the first week to be spent learning where its abstractions leak rather than assuming my Postgres intuitions hold.

**What transfers, and I would argue it transfers strongly.**

*One repository per aggregate, not one per table.* Callers ask `ProductRepository.get(product_id)` and receive a typed [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") or dataclass object. Whether the price tiers came from a relational table and the free-form attributes from a document is not the caller's business. This is the boundary that makes the storage decision reversible; without it, the paradigm split leaks into every endpoint and you can never change it.

*A validated schema on the schemaless half.* The mistake with any document model is letting "no fixed columns" mean "no contract". In the marketplace, vendor-supplied attributes are validated at write time against a per-category schema document, so the store is flexible and the data is still governable. On IRIS I would do the same thing: the storage engine's permissiveness is not an excuse to skip the application-level schema, and the per-category schema is a document, so adding a category stays a data change rather than a migration.

*Filterable attributes are the seam.* Anything a user filters or sorts on has to be reachable by an index. In the two-store design that forced a projection table; on a single engine it should instead be a typed, indexed property alongside the flexible ones. I would expect the real design conversation on IRIS to be exactly this — which attributes get promoted to indexed properties and which stay in the flexible body — and the answer comes from the query list, not from the data's shape.

*Migrations stay explicit.* Even where the engine does not force one, I want a versioned migration history for the relational half and an explicit `schema_version` on documents, with the read path able to handle the previous version. Lazy migrate-on-read versus a backfill job is a decision to make per change, and pretending a schemaless store means no migrations just moves the migration into unowned runtime code.

**What I would expect to be genuinely different, and would check rather than assume.**

- **Transactions across both halves.** On one engine this should be a single transaction, which deletes the outbox, the projection lag and the reconciliation sweep. That is a real simplification and the main reason to prefer the single-engine model — but I would verify the isolation semantics across the object and relational access paths before relying on it, because "same engine" does not automatically mean "same isolation guarantees through every access path".
- **Which driver, and what it costs.** Whether the Python layer goes through a Database [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") (DB-API) driver, an object binding, or both, decides whether [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") is usable and therefore whether the repository layer looks familiar. On a non-mainstream database I would expect the Object-Relational Mapping ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) dialect support to be the constraint that shapes the code, and I would want to know early whether the hot queries must be hand-written Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Queries and manipulates data in a relational database")).
- **Plan behaviour on large tables.** The brief mentions tables above 100 million rows. Every instinct I have about index selection and partition pruning comes from PostgreSQL's planner, and the only honest way to carry that across is to read this engine's execution plans against realistic data rather than assume the shape is the same.

**The one thing I would refuse to do.** Write an abstraction that pretends the two paradigms are one. A repository interface that hides the storage decision is worth having; a generic "store anything" layer that makes a relational query and a document query look identical produces code where nobody can tell which one they wrote, and the performance cliff arrives without warning. The layer should be thin, typed, and honest about which half it is touching.

</details>


---

### VER-15. How much of your marketplace work would transfer to a retail or enterprise resource planning catalogue, and what would not?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
The data modelling transfers well — a per-category attribute set, a schemaless metadata store with a validated write path, and a maintained projection for search. What does not transfer is the operational scale of continuous attribute churn, and the entire transactional side of retail, which I have not built.

<details>
<summary><strong>Detailed answer</strong></summary>

**What genuinely transfers.**

- **Modelling a catalogue whose attribute set differs per category.** Attributes are data, not columns, so the contract has to come from a per-category schema document validated on write. That is the same problem an enterprise catalogue has, and the failure mode is identical: without the validated write path, "no fixed column set" becomes "no contract" within a quarter.
- **Separating the descriptive from the filterable.** Anything filtered gets a defined type and an index in a projection; anything purely descriptive stays in the document. That separation is what keeps search on indexes rather than scanning documents.
- **Immutable revisions with a current pointer.** A comparison or a shortlist must show what a vendor said at a version, not a record that changes underneath it. In a retail catalogue the equivalent is price and specification history, which is usually a hard requirement rather than a nicety.
- **The consistency machinery.** One owning store per fact, an outbox so a fact and its event cannot disagree, source revisions on events so redelivery is a no-op and out-of-order delivery cannot roll a listing backwards, and a reconciliation sweep as the backstop for a lost event.
- **Bulk import as a first-class path**, chunked onto its own queue with a per-supplier concurrency cap so one supplier cannot occupy the pool.

**What does not transfer, stated plainly.**

- **Scale of churn.** The marketplace handled hundreds of imports a day. A large retail or resource-planning catalogue has continuous attribute updates at a rate where the update path, not the read path, is the design centre. I have designed for a burst; I have not operated a continuous multi-million-update feed, and I would expect the topology itself to change at that volume.
- **The transactional side of retail entirely.** Stock movements, promotions and pricing engines, order and fulfilment flows, tax and fiscal receipt rules, integration with point-of-sale networks. None of that is work I have done. My platform was where retailers choose software, not the software that runs a store.
- **Resource planning as a domain.** I have not worked inside one of those products, so its module structure, its customisation model and the constraints that come with a decades-old data model are things I would be learning.

**How I would frame that in a conversation.** The shapes I would meet are ones I have built — catalogue modelling, bulk updates, projection maintenance, search over faceted data. The domain vocabulary and the transactional processes are ones I would need to learn, and I would rather say that than discover it in the third week.

</details>


---

### VER-16. Retail is seasonal. What does a peak window change about how you plan and operate a release?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
It turns a peak into a change freeze with a deliberate boundary, moves risky work well before it, and makes capacity a decision taken in advance rather than by an autoscaler during the event. Most of what changes is planning discipline rather than architecture.

<details>
<summary><strong>Detailed answer</strong></summary>

**The freeze, and what it should actually cover.** A blanket ban on all changes is the wrong shape — it prevents fixes as well as features, and it produces a large batch of accumulated change landing immediately afterwards, which is its own risk. What I would freeze is the class of change that is hard to reverse: schema migrations, infrastructure changes, anything altering a hot query plan, and dependency or runtime upgrades. Behaviour behind a flag and genuine fixes stay possible, because the alternative is being unable to respond during the period when responding matters most.

**What moves before the window.**

- **Migrations and backfills**, finished and verified with time to spare, so nothing large is in flight when traffic arrives.
- **Capacity decisions taken in advance.** Autoscaling reacts, which is fine for a spike and inadequate for a sustained peak with a hard downstream limit — the connection budget does not scale with the autoscaler. So the ceilings are raised deliberately and the database sizing is decided ahead, not during.
- **A load test at peak shape rather than at average volume.** The interesting failures are all at the peak, and testing at the mean finds none of them. Shape matters as much as volume: a concentrated two-hour burst behaves nothing like the same daily total spread evenly.
- **A cold-start rehearsal.** If capacity has quietly been sized on a warm cache, then a restart during the peak is an outage. Knowing what happens with an empty cache — and having sized for it — is a different statement from hoping it does not happen.

**What changes operationally during it.** Higher alerting sensitivity on the things that degrade before they fail — queue depth trends, connection pool waits, cache hit ratio, projection lag. A named person who can decide to roll back without assembling a meeting. And a rehearsed rollback, because the window is exactly when nobody wants to attempt one for the first time.

**Afterwards.** The peak is the best data anyone will get all year, so the numbers get recorded and become next year's sizing input rather than being forgotten. And the changes deferred by the freeze land in a planned sequence rather than as one large batch — the post-freeze release is where the accumulated risk actually sits, and treating it as a return to normal is how a freeze causes the incident it was meant to prevent.

**The honest scope of my experience here.** The marketplace had no strong seasonality — its load was steady business-to-business traffic. The discipline above is what I would apply, drawn from the burst work I did do (the morning check-in concentration on the health platform, and bulk imports on the marketplace) rather than from having run a retail peak.

</details>

