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
Session-scoped fixtures bring the containers up once and run migrations. A function-scoped fixture wraps each test in a transaction, and that transaction is rolled back afterwards. Together they give real database behaviour, isolation for each test and no teardown cost.

<details>
<summary><strong>Detailed answer</strong></summary>

**The layering.**

- **Session scope**: start the containers at pinned versions that match production, and run the migrations once. The containers are the database, the document store, the cache, the broker and search. This is expensive, and it is done once.
- **Function scope**: open a connection, begin a transaction, give the test a session bound to it, and roll back at the end. Every test sees a clean database without truncating tables or running the migrations again. That is what keeps a suite with real stores fast enough to be tolerable.
- **Factories rather than fixture data files.** A factory is a helper that creates a valid entity with sensible defaults. It accepts overrides for the fields the test cares about. A test then reads as "a published listing from a suspended vendor", not as twenty lines of setup, and the intent is visible.

**The stores that do not take part in a transaction.** The document store, the cache, the broker and the search index have to be cleaned explicitly. That means a namespace or prefix for each test, or a truncation between tests. Getting this wrong produces the worst kind of flakiness: order-dependent failures, where a test passes alone and fails in the suite.

**The fixture discipline I care about most**, because it has caused me a real problem. One fixture, one behaviour. A fixture that carries several conditions can only honestly exercise the first condition that fires. Every later assertion on that fixture proves nothing. I had a set of checks pass for reasons unrelated to what they named. The reason was a fixture that carried a condition, and that condition short-circuited before the logic under test was ever reached. So both the thing being tested and a second thing looked covered, and neither was. Now the trigger for the behaviour under test appears only in the region under test. And nothing else in the fixture can satisfy the assertion.

**Other things I rely on.** Parametrisation for boundary cases, so one test body covers the empty, single and many cases, and a failure names the case. Marks that separate fast unit runs from the slow integration suite, so the local loop stays quick. Dependency overrides at the application level, to substitute a controlled principal or an external client.

**And the check I run on any test I intend to trust.** Break the behaviour that the test names. Confirm that the test goes red for the expected reason. Then restore the behaviour. A test that has never failed has not been shown to test anything. This check takes seconds when you write the test, and it is nearly impossible to add honestly later.

</details>


---

### VER-02. How do you test asynchronous code and message consumers?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Against a real broker, not a mock, because the behaviours worth testing are redelivery, acknowledgement and ordering. A mock reproduces none of them. And the important tests are the unpleasant ones: kill the consumer in the middle of a task, deliver the same message twice, and deliver two messages out of order.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why a mocked broker is almost worthless here.** A mock confirms that the handler function does what the handler function does. Everything that really goes wrong is in the interaction:

- a message acknowledged before the work completed;
- a handler that is not idempotent under redelivery;
- a binding pattern that matches nothing;
- a payload that fails validation and is retried forever.

A mock passes all of those while they are broken.

**The tests I would insist on for any consumer.**

- **Redelivery is harmless.** Deliver the same message twice, then assert one row and one side effect. This is the test that proves the idempotency guarantee is real. The test should prove a database constraint, not an in-memory check, so the guarantee still holds after a restart.
- **Out-of-order delivery does not roll state backwards.** Deliver a newer event and then an older one, and assert that the newer state survives. This is what the source revision on the event is for. Without the test, it is only an intention.
- **A crash in the middle of a task causes redelivery, not loss.** Kill the worker while a task is in flight, and assert that the work completes afterwards. This is the test that really verifies that the acknowledgement mode is configured the way you believe. It is also the test that nobody writes.
- **A poison message is dead-lettered instead of looping.** Assert that the attempt count is bounded and that the message ends up somewhere visible.
- **The binding topology is what you think it is.** Publish with the routing key that the producer really uses, and assert that the message arrives. Binding configuration is silent when it is wrong: a queue bound with a typo receives nothing and reports no error. That is exactly why binding configuration belongs in a test, not in a management interface that someone checks by eye.

**On the async code itself.** An async-aware test runner, and time that the test controls instead of waiting for it. No sleeps, because a test based on sleeps is either slow or flaky, and usually both. Where a test must wait for a consumer, poll for the expected condition with a timeout. Make the test fail with a message that names what was expected. Do not sleep for a fixed interval and hope.

**And the trap that is specific to async testing.** An unawaited coroutine does nothing, and the test still passes. Python only emits a `RuntimeWarning`, and that warning is easy to miss in the test output. The type checker catches most unawaited coroutines. A warnings-as-errors setting catches the rest. That setting is worth configuring, because otherwise that warning is the only sign of the failure.

</details>


---

### VER-03. What is your approach to test data, and why not use production data?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Synthetic data, generated by factories, with realistic volume where volume is the thing under test. Production data is not an option on a clinical system, for legal reasons. It is also a bad idea in general, because it makes tests non-reproducible and it silently spreads sensitive material into every environment.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why not production data.** On the cancer platform, production data is ruled out completely. Patient data outside the production tenancy has no lawful basis. And anonymising clinical free text is far harder than people assume: a note can identify someone through circumstances without containing a name. Beyond that, and for any system, a test whose fixture is a snapshot is not reproducible. It drifts, and it fails for reasons unrelated to the change. Copies of the snapshot end up on laptops and in backups that nobody tracks.

**What I use instead.**

- **Factories that produce valid entities with overrides**, so a test declares only what it cares about.
- **Deterministic generation with a fixed seed** where randomness is useful. Random data finds edge cases. Unseeded random data produces failures that nobody can reproduce, which is the worst of both.
- **Realistic volume where volume is the point.** This one is worth insisting on. A query performance test against a hundred rows tells you nothing. That is because the planner chooses differently at different scales, and a sequential scan on a small table is correct. So the integration environment seeds a table to a size where the plan is the production plan. Without that, every plan assertion is meaningless.
- **Deliberately awkward values**, because real data is not tidy. Examples are names with non-Latin characters and apostrophes, timestamps across a daylight-saving boundary, an empty collection, a maximum-length string, a zero and a negative value. Most boundary defects are found here, not by volume.

**Where a production shape is really needed**, such as investigating a defect that only occurs on real data, the answer is a controlled export. The sensitive fields are replaced. A reviewed process produces the export into a restricted environment, and the export has an expiry. It is not a copy of the database on someone's machine. And on the cancer platform, it is not done at all. There, the investigation happens in production with the access audited, instead of moving the data.

**One thing I would add.** The same factories are useful for seeding a local environment. That means the development stack is filled with data that exercises the awkward cases by default. A developer whose local data is all tidy will keep writing code that assumes tidy data.

</details>


---

### VER-04. The suite passes on merge requests and fails on the default branch. What is going on?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Usually it is one of four things. The branch ran a different subset. Two branches that were green on their own merged into a conflict that no test saw. The default branch runs against something that merge requests do not. Or a test is order-dependent, and the fuller run changes the order.

<details>
<summary><strong>Detailed answer</strong></summary>

**The four causes, and how to tell them apart quickly.**

- **Different scope.** If merge requests run an affected subset and the default branch runs the full matrix, then a passing merge request never proved anything about the failing test. This is the most common cause. It is a deliberate trade-off, not a bug: this is exactly the cost of a shorter feedback loop. The check is whether the failing test was in the merge request's selection at all.
- **Semantic merge conflict.** Two branches are each green, and each is correct against the base. One renames a function, and the other adds a call site. Version control merges both cleanly, and the result is broken. Nothing tested the combination, because the combination did not exist until the merge. A merge queue, or a required rebase-and-rerun against the current default branch, exists to prevent this. If it happens more than occasionally, that is the fix.
- **Environment difference.** The default branch pipeline has credentials, a real external dependency, or a deploy target that merge request pipelines do not have. This is often for good security reasons, since secrets are scoped to protected branches. So a whole class of test only ever runs there, and the first time it runs is after the merge.
- **Order dependence.** A fuller run changes the ordering or the parallelism, and a test that leaks state into another test shows up. You can confirm this in a minute by running with randomised order locally.

**What I do first, whatever the cause.** Establish whether the default branch is broken for everyone, because that blocks the whole team and takes priority over diagnosis. If it is, revert the merge instead of fixing forward. A revert is fast and reversible, and it does not require understanding the problem yet. Fixing forward under pressure, with everyone blocked, is how a second defect arrives.

**Then the structural fix, not the fix for this one instance.** If it was a semantic merge conflict, require branches to be current with the default branch before merging, or use a merge queue that tests the merged result. If it was scope, make sure the selection logic is conservative. It is better to run too much than to have a class of change that is routinely untested. If it was environment, get an equivalent running on merge requests, even against a stub, so the shape of the failure is at least reachable earlier.

**And I would look at how often it happens.** An occasional default-branch failure is the normal cost of a subset strategy. A regular one means that the subset selection is wrong. It also means the team has quietly stopped trusting merge request pipelines, and that is worse than the time those pipelines save.

</details>


---

### VER-05. How do you decide what not to test?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By asking what the test would catch that something else does not, and what the test costs to maintain. I do not test the framework, the language, or code whose failure is loud and immediate. And I am deliberate about it, instead of just leaving gaps.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I actively choose not to test.**

- **The framework and the libraries.** A test that asserts the validation library rejects a wrong type is testing someone else's suite. The exception is where I depend on a behaviour that is version-specific or contested. Examples are a broker's semantics under a particular acknowledgement configuration, or whether an instrumentation version really propagates trace context. Those get a test exactly because they are claims that I would otherwise be assuming.
- **Anything a type checker already proves.** Take a test that a function rejects a string where an integer is expected. That test duplicates the checker, and it costs maintenance on every refactor.
- **Trivial accessors and pass-throughs.** They add coverage but no information. A suite full of them is what a coverage target produces when people chase the target instead of using it.
- **Failures that are loud, immediate and impossible to miss.** A missing configuration value that stops the process at startup does not need a test, because it cannot ship unnoticed. Compare that with a permission check that silently permits, which needs a test badly.
- **The exact wording of user-facing strings**, unless the wording is itself a requirement. Otherwise every copy change gives a red build, and people learn to update assertions without reading them.
- **Third-party integrations at their own boundary.** I test that we call them correctly and that we handle each documented response. I do not test their service. That belongs in a monitored synthetic check, not in a pipeline.

**How I decide the marginal case.** I ask two questions. First, if this broke, would anything else notice, such as a type error, a failing integration test, a loud crash or a metric? Second, what does the test cost when the code changes for an unrelated reason? A test that catches nothing new and breaks on every refactor has negative value. Removing such a test is a legitimate decision, not a step backwards.

**Where I spend the effort I save.** On the tests that are hard: integration against real stores, the negative authorization cases, redelivery and crash recovery, and the plan shape on a query whose performance is a design property. Those tests cost more to write, and each one is worth ten trivial unit tests. They also happen to move coverage.

**The thing I insist on when I skip something.** Say so. An uncovered path that was considered and deliberately left is a decision. An uncovered path that was never noticed is a gap. So the skip goes in the merge request description, or in an explicit coverage exclusion with a reason, where it is visible and reviewable. It is not hidden behind a test that asserts nothing. Such a test hides the gap instead of covering it.

</details>


---

### VER-06. The client wants traceability from requirement to test evidence for every release. What would you put in place?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
A link that lives in the code and moves with it. Tests carry the identifier of the requirement they cover, and the pipeline reports them automatically. So the evidence is generated, not maintained. A traceability matrix kept by hand is out of date within one sprint.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the requirement really is.** For a given release, someone must be able to ask which requirements are covered, by what, and whether it passed. That is a legitimate need on a regulated or heavily audited product. And a code suite alone answers that question badly, because a test file does not know why it exists.

**How I would build it.**

- **The link lives in the test.** A marker or naming convention carries the requirement identifier. So the link moves with the code, appears in the diff, and disappears when the test is deleted. A mapping kept in a separate document is a mapping that goes out of date, and nobody sees it go out of date.
- **Evidence is produced by the pipeline, not entered by a person.** Each run produces a machine-readable report of which tests ran, which requirements they cover and what the outcome was. The report is attached to the release artifact. Nobody copies anything by hand, so nobody copies it wrongly or late.
- **A gap report as a build output.** Every run lists the requirements that have no linked test. That is the real value. The value is not the matrix, which is a formality. It is the list of things that nobody has verified, and that list is a finding.
- **Manual test cases limited to what really cannot be automated**, such as exploratory work, something that needs a real external system, or an accessibility judgement. Each manual case is a recurring cost forever. So the list should be short and deliberately chosen, not accumulated.
- **The release record assembled automatically**: which commit, which image digest, which requirements, which evidence. On some systems, "what was running last Tuesday and what proved it" is a real question. On such a system, that record is the answer.

**The failure mode I would work hardest to avoid.** Two catalogues that drift apart: a managed set of test cases and a code suite that no longer match. A manual case survives for a year after the behaviour it describes was removed. In each regression run, someone marks it passed, because investigating is harder. That produces a document that asserts coverage that does not exist. That is worse than having no document at all.

**What I would ask early.** I would ask what happens when an automated test is deleted, because that is where the drift starts. The answer is usually that nobody has thought about it. And I would ask who owns the requirement identifiers, since the whole scheme depends on them being stable.

**My honest position on the tooling.** I have kept traceability through tickets with explicit acceptance criteria, tests that can be identified as covering them, and release notes that record what was verified. A dedicated test-management tool next to the issue tracker is a workflow that I have not used. The concepts are the same, and I would expect the tool itself to take days, not weeks.

</details>

---

## 2. Observability and production diagnosis

---

### VER-07. Suppose one API endpoint suddenly becomes 10× slower. How would you investigate it?

**Level:** Q2 — deep dive · **Project:** retail-software-marketplace

**Brief answer**
Establish the shape before the cause. When did it start? Is it one endpoint or the whole service? Is it the median, or only the tail? Those three answers remove most of the search space. Then follow the dependency chain from the trace, not from a hypothesis. The trace tells you which span grew. And the growth is almost always a plan flip, a cache that stopped hitting, a pool that started queueing, or a dependency that got slower.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three questions first, because each one cuts the space in half.**

1. **When exactly did it start, and what changed then?** Overlay the latency graph with the deployment timeline, the configuration and feature-flag history, and the infrastructure change log. A step change at a deploy boundary is a code or migration cause. A gradual ramp over days is data volume or index bloat. A step change with no deploy is a dependency, a plan flip, or a change in the traffic mix.
2. **One endpoint or all of them?** If every route on the service degraded together, the cause is shared. The event loop is blocked, the pool is saturated, the node is throttled, or the database is slow for everyone. If really only one route moved, the cause is in that route's own work.
3. **p50, or only p95/p99?** A shifted median means that every request now does more work. An unchanged median with a much worse tail means a subset of requests: one tenant, one large payload, one uncached path or one unlucky lock. And the fix is different in kind.

**Then follow the trace.** With distributed tracing in place, I compare a slow trace from now with a fast trace from before the change. Then I look at which span grew. The tracing is Application Insights in the marketplace and Elastic Application Performance Monitoring in the cancer platform. This is the step that replaces guessing. The usual answers:

- **The database span grew.** Run `EXPLAIN (ANALYZE, BUFFERS)` on the actual query with the actual parameters. A plan flip is the most common cause of a sudden tenfold change. The flip happens in one of these ways. Statistics went stale after a bulk load, or a table crossed the size at which the planner stopped preferring an index. Or an unselective predicate combination degraded a bitmap `AND` across several generalized-inverted indexes into a sequential scan. The marketplace design flags that case in advance as this system's defining performance risk. Check `pg_stat_statements` for the query's mean time and call count, and check whether autovacuum has fallen behind on the table.
- **The database span did not grow, but the time before it did.** That is time waiting for a connection from the pool (pool checkout wait), so the pool is queueing. Pool wait is a separate metric. It is the difference between "the database is slow" and "I have no connections", and those two have opposite fixes.
- **A cache span started missing.** `redis_cache_hit_ratio` for the keyspace is an explicit service level indicator in the marketplace. That is exactly because the latency budget assumes 85% on the search page. A ratio collapse can come from a key format change on deploy, an eviction from memory pressure, or a stampede after a mass invalidation. The collapse moves p95 from the ~35 ms cached path to the ~107 ms uncached path in one step. And p95 moves further if the database is now carrying six times its usual load.
- **The call count grew, not the call duration.** One span taking 50 ms became forty spans taking 2 ms each. A lazy relationship became an N+1, or a bulk `$in` hydration became a per-item loop. The marketplace names that explicitly as the way its catalog design would have failed.
- **No span grew, and the spans do not add up to the total.** That is time in the process, not in a dependency. The cause is a blocking call on the event loop, garbage-collection pauses, or processor throttling from a container limit. Event-loop lag and container throttling metrics decide which one it is.
- **Everything is slow, and the replica lag graph is climbing.** When `postgres_replica_lag_seconds` is above its threshold, `catalog-service` falls back to the primary. That is correct behaviour, and it is also a latency change with no code cause.

**What I would not do.** Restart the pods to see if that helps, or enlarge the pool, before I know which span grew. Both destroy the evidence, and one of them makes a saturated database worse. And I would check whether the endpoint is really slower, or only slower *for someone*. A tenant whose data volume grew, or a client that started sending a new filter combination, looks identical on an aggregate graph. And it is a different problem.

</details>


---

### VER-08. Describe your experience with Prometheus. What did you instrument, and what do your queries look like?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
Application metrics exposed on a scrape endpoint, and alert rules held in infrastructure code. I chose what to instrument so that each metric names a specific failure, not a general idea of health. That means index freshness, reminder lateness, consumer duration and failures, and queue depth.

<details>
<summary><strong>Detailed answer</strong></summary>

**The metrics that earn their place, and what each one is for.**

- **The age of the oldest unpublished outbox row.** This is index freshness as a number. A stalled relay means that search results silently stop updating while every request stays fast. The alert fires above thirty seconds.
- **Reminder dispatch lateness at the high percentile, and delivery outcomes by state.** Reminder delivery is the clinical objective. So its lateness is a first-class metric, not something inferred from logs.
- **Consumer task duration and failure counts per queue**, plus broker queue depth and unacknowledged counts.
- **Authentication failures by reason, and identity provisioning failures.** A deprovisioning that did not complete is a security event, not a background job, so it pages.
- **The standard request rate, error rate and duration histograms**, which are necessary but are not where the interesting failures are.

**What the queries look like in practice.** Rates over counters, not raw counters, because a counter's value is meaningless and its rate is the signal. Error rates as ratios computed from two counters, not a pre-computed percentage, so the numerator and the denominator can be inspected separately. Histogram quantiles for latency. The caveat is that quantiles from histograms are estimates bounded by bucket boundaries. So the buckets have to be chosen around the thresholds that matter, not left at a default. And alerts written with a duration condition, so a single scrape does not page anyone.

**On cardinality**, which is the mistake that does real damage. A label that carries a user identifier, a request path with an identifier in it, or an unbounded error string will multiply the series count until the server degrades. Labels are bounded sets, such as service, queue, outcome and status class. Anything unbounded belongs in a log line, not a label. This is easy to get wrong and expensive to undo.

**Alert rules in infrastructure code.** This is the detail I would emphasise, because it is the one people skip. An alert that is silenced by hand during an incident and never restored is the usual way that monitoring degrades. In code, a silenced alert is a reviewable diff. It is not something discovered six months later, when the thing it watched failed quietly.

</details>


---

### VER-09. What does an application performance monitoring tool give you that metrics and logs do not?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
The causal path of one request across every hop. Metrics tell you that something is slow in aggregate, and logs tell you what happened at points. A trace tells you where the time went in this specific request. That includes the hops through a broker, which logs and metrics show as two unrelated halves.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each of the three really answers.** Metrics answer "is it happening, and how much?" They are cheap and aggregate, with no per-request detail. Logs answer "what happened here?" They are detailed and per event, and they are disconnected across services unless they are correlated. Traces answer "where did the time go for this request, across everything it touched?" Neither of the others can reconstruct that.

**Where it is worth its cost on these systems.** A request touches the gateway, the service, the database, the cache and possibly the broker. A trace with a span for each one shows immediately where the time is. It is in query execution, in waiting for a connection from the pool, in an outbound call, or in the application itself. That distinction, waiting versus working, is the one that decides the whole diagnosis. And it is invisible in a latency metric.

**The async case is where it becomes essential, not just convenient.** A check-in arrives over the message transport and is bridged into the broker. It is consumed by a worker, written, and indexed. Without trace context propagating across those hops, it is four unrelated log streams. With trace context, one trace covers the request, the event, the consumer and the index write. So when a reminder fails between the worker and the delivery function, it is one picture, not two half-stories put together during an incident.

**The honest caveat, which I would state before relying on it.** Trace continuity across a message broker is the claim most likely to be false as written. That is because it depends on the instrumentation versions really injecting and extracting the context header on that transport. And on the older version of the lightweight publish-subscribe protocol, there is no user-property header at all. So the context has to travel inside the payload envelope. That decision must be made before instrumenting, because changing it later breaks every published client. So the versions are pinned, and an integration test asserts an end-to-end trace identifier. That is a claim you do not want to discover is false during an incident.

**On sampling.** It is deliberately uneven. Keep everything for errors and for the paths that carry the important guarantees, and keep a small percentage of routine reads. With uniform sampling at a low rate, the interesting request is the one you did not keep.

**And what it does not replace.** Audit. A trace is telemetry, with a retention policy and sampling. An audit record is a durable row, written in the same transaction as the access. Treating them as the same thing means the telemetry retention policy silently becomes the audit policy.

</details>


---

### VER-10. You are paged: latency is up and the error rate is flat. Walk me through it.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A flat error rate with rising latency means the system is still working and something is queueing. So the question is what everything is waiting for, not what is broken. It can be a shared dependency, a saturated pool, or a cache that has stopped absorbing load.

<details>
<summary><strong>Detailed answer</strong></summary>

**Start by narrowing it down.** Is it everything, or one endpoint? All pods, or one? When did it start, and what changed near that time: a deploy, a configuration change, a scheduled job, a traffic pattern? I look at the deploy timeline first, because a deploy is the cheapest cause to rule out and the most common one.

**Then separate waiting from working, using traces.** The spans show whether the added time is in query execution, in getting a connection, in an outbound call, or in the application. That one distinction removes most of the space.

**The usual causes for this specific pattern.**

- **A shared downstream is saturated.** The database is at its connection limit, or the cache is slow. Everything that touches it slows down together, and nothing fails, because requests are queueing instead of being rejected. The sign is that unrelated endpoints degrade at the same time.
- **Connection pool exhaustion.** Time is spent waiting to get a connection, not executing. That is exactly why the database can look idle while the application is slow. Instrumenting pool wait as its own metric turns this into a five-second diagnosis instead of an hour.
- **A drop in the cache hit ratio.** More requests fall through to the database, so latency rises and the database load multiplies. The causes are an eviction storm because memory filled, a key format changed by a deploy so every read misses, or an invalidation that removed more than intended.
- **A derived store falling behind**, which shows as latency on the paths that fall back to the primary.
- **Processor throttling from a limit set too low**, which looks exactly like slow code. It is invisible unless the throttling metric is on the dashboard.
- **A blocking call added to an async path**, which degrades everything on that worker together, including the health probe.
- **A query plan change** after a data volume threshold or a statistics refresh. It shows as a sudden slowdown on one endpoint, with no deploy.

**What I do while diagnosing.** If it is degrading toward an outage, mitigate first: scale the affected tier, shed non-essential load, or roll back a recent deploy. Then diagnose afterwards, with the evidence captured before anything is restarted. If it is stable and only worse, take the time to find the cause, because mitigating a latency problem without understanding it usually just moves the problem.

**And I check the obvious thing last, but I do check it:** whether the latency is real, or the measurement changed. A new endpoint with a different profile that enters the same aggregate will move a percentile, even though nothing got slower.

</details>


---

### VER-11. Where is the line between a log, a metric, an audit record and a trace — and what goes wrong when it blurs?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
They have different durability, retention and access requirements, and that is the whole point. The failure that matters most is treating logs as an audit trail. Then the log retention policy silently becomes the audit policy. Nobody notices until someone asks for a record older than that window.

<details>
<summary><strong>Detailed answer</strong></summary>

**What each one is for.**

- **A metric** is an aggregate number for alerting and trends. It is cheap and bounded, with no per-request detail. Its constraint is cardinality. A label that carries a user identifier or an unbounded error string multiplies the series count until the monitoring system degrades. Anything unbounded belongs in a log line, not a label.
- **A log** is a structured event that describes what happened at a point. In some pipelines, logs are sampled or dropped under pressure. Logs are retained for weeks, and anyone with access to the log store can query them.
- **A trace** is the causal path of one request across every hop. It is deliberately sampled: everything for errors and for the paths that carry the important guarantees, and a small percentage of routine reads.
- **An audit record** is a durable, immutable business fact about who accessed or changed what. It is written in the same transaction as the access it records. So it cannot be lost independently of the thing it describes.

**Why mixing up audit and logs is the serious one.** They look similar, because both are append-only records of events. So it is a natural saving to say that the logs are the audit trail. Then the following happens. Log retention is weeks and audit retention is years, so the record is gone when it is needed. Logs are sampled or dropped under load, so the trail has holes exactly when the system was under stress. Logs go to a store with broad read access, so an audit trail of sensitive access is readable by everyone who can query logs. And a log line is written after the fact, not in a transaction, so a crash between the action and the log leaves an unrecorded access.

That is why audit is a database table here. It has its own retention, its own access control, and an archive under a write-once policy with a long retention period. It is also why the audit write is in the same transaction as the access. That is a deliberate coupling, not an oversight.

**The other mix-ups, more briefly.** Metrics used as logs produce a cardinality explosion that takes the monitoring system down. Logs used as metrics mean that alerting depends on the log pipeline, and the log pipeline may be the thing that is failing. Traces used as audit fail because traces are sampled: the request you need is the one that was not kept.

**And the content rule that applies to all of them.** No clinical free text, no symptom values and no message bodies in telemetry of any kind. This is enforced mechanically, not culturally. A redaction filter at the formatter drops fields that are marked sensitive on the model. And a pipeline check fails the build if a log call passes such a model. Intention does not hold up during an incident at two in the morning, and that is exactly when someone adds a debug line that contains the object.

</details>


---

### VER-12. Nothing changed in the code, there was no deployment and no traffic spike, but lag suddenly appeared. How do you debug this, and where do you look first?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
"Nothing changed" almost always means that nothing changed *in the things we deploy*. So I look first at the things that change by themselves: data volume crossing a planner threshold, a background maintenance job, a partition boundary, a certificate or credential rotation, a managed-service failover, and an upstream provider. The first number I pull is which lag it is. That is because replica lag, projection lag, queue lag and cache-miss latency have entirely different causes, and only one of them is a database problem.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one is refusing to accept the word "lag" without a definition.** In the marketplace, there are at least four separate numbers that a user would describe the same way, and each one has its own target:

- `postgres_replica_lag_seconds`;
- `indexer_lag_seconds` (event `occurred_at` → row `projected_at`);
- `outbox_unpublished_age_seconds`;
- `celery_queue_depth` per queue.

Knowing which one moved shows where the problem is before any hypothesis is formed. If none of them moved and users still see staleness, the problem is in the cache layer or the client, not in the pipeline.

**Then the kinds of change that happen without a deploy, in the order I check them.**

1. **Data crossing a threshold.** This is the most common cause of an overnight change with no deploy. A table grows past the point where the planner's estimate flips a nested loop into a hash join, or an index stops fitting in the buffer cache. Then a query that was 40 ms becomes 4 s. Stale statistics do the same thing. Autovacuum falls behind on a write-heavy table, the estimates drift away from reality, and the plan degrades. The check is `EXPLAIN (ANALYZE, BUFFERS)` on the slow query, and a comparison of estimated rows against actual rows. A divergence of three orders of magnitude is a statistics problem, and `ANALYZE` is the immediate test.
2. **Autovacuum itself.** A long-running transaction somewhere is holding the oldest snapshot, so vacuum cannot reclaim dead tuples across the whole database. Table bloat rises, scans read more pages for the same rows, and everything gets slower with no change anywhere. `pg_stat_activity` ordered by `xact_start` finds that transaction in one query. And this is the case where the cause and the symptom are in entirely different services.
3. **A time-driven job.** A monthly partition boundary, a nightly reconciliation sweep, a retention detach, a backup window, or a [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") expiry wave in Mongo. These are in the design, and they are still surprising at 03:00, because nobody correlates them by default. It is worth putting the schedule on the same dashboard as the lag.
4. **The managed service moved.** A Flexible Server maintenance failover, a replica rebuild, or a [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") node swap. Failover is 60–120 s of failed writes by design. But the after-effects last longer: a cold buffer cache on the new primary, a reconnect storm, and a replica that has to catch up. The platform's activity log answers this, and it is not a place where application engineers naturally look.
5. **A credential or certificate rotation.** Suppose a key rotation has an overlap window that turned out to be shorter than a cache's refresh interval. That produces intermittent failures, and they look like latency because of the retries in front of them. In the marketplace, the specific known trap is the gateway's [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") Web Key Set ([JWKS](https://datatracker.ietf.org/doc/html/rfc7517 "JSON Web Key Set — Publishes the public keys a party needs to verify a signed token")) cache. It refreshes on a different schedule from the application's cache, so during a signing-key rotation the two can disagree.
6. **Upstream.** A third-party provider that slows down turns into queue depth on our side. If the queue that is backing up is the dispatch queue, the problem is probably not ours at all.
7. **A noisy neighbour on shared infrastructure.** One tenant's bulk import occupies the worker pool. That is the specific failure that the per-vendor concurrency cap exists to prevent. It is worth confirming that the cap held, instead of assuming it.

**What I would not do.** Start by reading recent commits. The premise says there were none, and the single biggest waste of an incident hour is refusing to believe the premise. I would also not restart anything before capturing the lock graph, the running queries and the plan. A restart usually clears the symptom and destroys the evidence, and then the problem comes back.

**What I would put in place afterwards.** If this was a silent degradation, the gap is not the fix. The gap is the detection. The alert on `indexer_lag_seconds` at 60 s exists exactly because a dead indexer raises no error: new listings simply stop becoming searchable. Every derived or projected view needs a freshness metric with an alert, because the failure mode of a projection is silence. And the deployment timeline, the maintenance-event feed and the scheduled-job calendar belong on the same dashboard as the latency graph. So "did anything change" becomes a quick look, not an investigation.

</details>


---

### VER-13. Your team is getting too many alerts. How do you fix that without going blind?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By auditing every alert against one test: did a human need to act, and did they act? Then I delete or demote the alerts that fail that test. Tuning thresholds does not solve alert fatigue. Having far fewer things that page, each of which is trusted, solves it.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it has to be fixed, not tolerated.** An on-call rotation that receives twenty pages a night learns to acknowledge them without reading them. At that point, the alerting system has negative value. It costs sleep and it provides no detection. And the one real incident arrives in a stream of noise that has already trained everyone to dismiss it. Muting is what happens next. A muted alert is worse than an absent one, because everyone still believes it is there.

**The audit.** For every alert that fired in the last month, ask: did it require a human to act immediately, and did a human act? There are four outcomes.

- **Fired and needed action**: keep it, and check that the runbook is accurate.
- **Fired, nobody acted, and nothing bad happened**: it should not page. Demote it to a dashboard or a ticket.
- **Fired repeatedly for the same underlying cause**: this is a symptom of over-alerting on causes. Replace several cause-alerts with one symptom-alert on the objective, and let the dashboard explain why.
- **Never fired**: either the condition never occurred, or the rule is broken. A rule with a typo in a label matches nothing forever, so this needs checking, not assuming.

**The structural changes that usually follow.**

- **Alert on symptoms, not causes.** One alert on the user-facing objective, with the causes as dashboard panels. Alerting on every possible cause guarantees a storm of alerts during an incident, and that is exactly when clarity matters most.
- **Duration conditions**, so a single scrape does not page.
- **Thresholds derived from the objective**, not from a round number that someone liked.
- **Grouping and inhibition**, so a downstream failure does not page for every dependent service.
- **Every paging alert names an owner and a runbook.** An alert with neither will be muted, and it deserves to be.
- **A message that states what is wrong and what it means**, not a metric expression. The reader is half asleep.

**What I would protect from the clean-up.** The alerts for silent failures, even though they fire rarely: index freshness, projection lag, dead-letter depth and identity provisioning failures. Those are exactly the ones that nothing else surfaces. Their rarity is an argument for keeping them, not against keeping them.

**And the rules go in infrastructure code**, so a threshold change or a silence is a reviewed diff, not a click. That is what stops the set of alerts from decaying again six months later. Otherwise, that decay is exactly what happens.

</details>

---

## 3. Domain and unfamiliar stacks

---

### VER-14. This vacancy involves working with InterSystems IRIS, which supports both relational and document data models; given your experience with both PostgreSQL and MongoDB, how would you approach designing a data access layer in Python that effectively bridges these two different storage paradigms?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
I have not worked with InterSystems [IRIS](https://docs.intersystems.com/ "InterSystems IRIS — Multi-model database combining a relational surface with globals-based storage"). So I would answer this from the two-store version of the same problem, which I have built twice. The design principle transfers directly. The access layer exposes one repository per aggregate, and each repository returns typed domain objects. Which paradigm serves a given field is an implementation detail behind that boundary. There is one important difference. On a single engine, the two halves can share a transaction. That removes the projection pipeline and the reconciliation job that the two-store version has to pay for.

<details>
<summary><strong>Detailed answer</strong></summary>

**Being honest about what I have and have not done.** My experience is [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") plus [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") as separate engines, and PostgreSQL `jsonb` as a document model inside a relational one. In IRIS's model, the same data is reachable as objects, as relational tables and as globals over one storage engine. Of my two experiences, that model is close to the second one, not the first. I would expect to spend the first week learning where its abstractions leak, instead of assuming that my Postgres intuitions hold.

**What transfers, and I would argue that it transfers strongly.**

*One repository per aggregate, not one per table.* Callers ask `ProductRepository.get(product_id)` and receive a typed [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") or dataclass object. Whether the price tiers came from a relational table and the free-form attributes from a document is not the caller's business. This boundary is what makes the storage decision reversible. Without it, the paradigm split leaks into every endpoint, and you can never change it.

*A validated schema on the schemaless half.* The mistake with any document model is to let "no fixed columns" mean "no contract". In the marketplace, vendor-supplied attributes are validated at write time against a per-category schema document. So the store is flexible, and the data can still be governed. On IRIS I would do the same thing. The fact that the storage engine is permissive is not an excuse to skip the application-level schema. And the per-category schema is a document, so adding a category stays a data change, not a migration.

*Filterable attributes are the dividing line.* Anything a user filters or sorts on has to be reachable by an index. In the two-store design, that forced a projection table. On a single engine, it should instead be a typed, indexed property next to the flexible ones. I would expect the real design conversation on IRIS to be exactly this: which attributes get promoted to indexed properties, and which stay in the flexible body. The answer comes from the query list, not from the shape of the data.

*Migrations stay explicit.* Even where the engine does not force a migration, I want a versioned migration history for the relational half and an explicit `schema_version` on documents. And I want the read path to be able to handle the previous version. Lazy migrate-on-read versus a backfill job is a decision to make for each change. Pretending that a schemaless store means no migrations just moves the migration into runtime code that nobody owns.

**What I would expect to be really different, and would check instead of assuming.**

- **Transactions across both halves.** On one engine this should be a single transaction, and that deletes the outbox, the projection lag and the reconciliation sweep. That is a real simplification, and it is the main reason to prefer the single-engine model. But I would verify the isolation semantics across the object and relational access paths before relying on it. That is because "same engine" does not automatically mean "same isolation guarantees through every access path".
- **Which driver, and what it costs.** Whether the Python layer goes through a Database [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") (DB-API) driver, an object binding, or both decides whether [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") is usable. So it also decides whether the repository layer looks familiar. On a non-mainstream database, I would expect the Object-Relational Mapping ([ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries")) dialect support to be the constraint that shapes the code. And I would want to know early whether the hot queries must be hand-written Structured Query Language ([SQL](https://en.wikipedia.org/wiki/SQL "Queries and manipulates data in a relational database")).
- **Plan behaviour on large tables.** The brief mentions tables above 100 million rows. Every instinct I have about index selection and partition pruning comes from PostgreSQL's planner. The only honest way to carry those instincts across is to read this engine's execution plans against realistic data, not to assume the shape is the same.

**The one thing I would refuse to do.** Write an abstraction that pretends the two paradigms are one. A repository interface that hides the storage decision is worth having. A generic "store anything" layer that makes a relational query and a document query look identical is different. It produces code where nobody can tell which one they wrote, and the sudden drop in performance (the performance cliff) arrives without warning. The layer should be thin, typed, and honest about which half it is touching.

</details>


---

### VER-15. How much of your marketplace work would transfer to a retail or enterprise resource planning catalogue, and what would not?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
The data modelling transfers well: a per-category attribute set, a schemaless metadata store with a validated write path, and a maintained projection for search. What does not transfer is the operational scale of continuous attribute churn. The entire transactional side of retail, which I have not built, does not transfer either.

<details>
<summary><strong>Detailed answer</strong></summary>

**What really transfers.**

- **Modelling a catalogue whose attribute set differs per category.** Attributes are data, not columns, so the contract has to come from a per-category schema document validated on write. An enterprise catalogue has the same problem, and the failure mode is identical. Without the validated write path, "no fixed column set" becomes "no contract" within a quarter.
- **Separating the descriptive from the filterable.** Anything that is filtered gets a defined type and an index in a projection. Anything that is only descriptive stays in the document. That separation is what keeps search on indexes, instead of scanning documents.
- **Immutable revisions with a current pointer.** A comparison or a shortlist must show what a vendor said at a version, not a record that changes underneath it. In a retail catalogue, the equivalent is price and specification history. That is usually a hard requirement, not a nice extra.
- **The consistency machinery.** One owning store per fact. An outbox, so a fact and its event cannot disagree. Source revisions on events, so redelivery is a no-op and out-of-order delivery cannot roll a listing backwards. And a reconciliation sweep as the backstop for a lost event.
- **Bulk import as a first-class path**, split into chunks on its own queue, with a per-supplier concurrency cap so one supplier cannot occupy the pool.

**What does not transfer, said plainly.**

- **Scale of churn.** The marketplace handled hundreds of imports a day. A large retail or resource-planning catalogue has continuous attribute updates, at a rate where the update path is the design centre, not the read path. I have designed for a burst. I have not operated a continuous multi-million-update feed, and I would expect the topology itself to change at that volume.
- **The transactional side of retail, entirely.** Stock movements, promotions and pricing engines, order and fulfilment flows, tax and fiscal receipt rules, and integration with point-of-sale networks. None of that is work I have done. My platform was where retailers choose software, not the software that runs a store.
- **Resource planning as a domain.** I have not worked inside one of those products. So its module structure, its customisation model and the constraints that come with a decades-old data model are things I would be learning.

**How I would frame that in a conversation.** The shapes I would meet are ones I have built: catalogue modelling, bulk updates, projection maintenance, and search over faceted data. The domain vocabulary and the transactional processes are ones I would need to learn. I would rather say that than discover it in the third week.

</details>


---

### VER-16. Retail is seasonal. What does a peak window change about how you plan and operate a release?

**Level:** Q3 — architectural · **Project:** retail-software-marketplace

**Brief answer**
It turns a peak into a change freeze with a deliberate boundary. It moves risky work well before the peak. And it makes capacity a decision taken in advance, not something an autoscaler decides during the event. Most of what changes is planning discipline, not architecture.

<details>
<summary><strong>Detailed answer</strong></summary>

**The freeze, and what it should really cover.** A blanket ban on all changes is the wrong shape. It prevents fixes as well as features. And it produces a large batch of accumulated change that lands immediately afterwards, which is a risk of its own. What I would freeze is the class of change that is hard to reverse: schema migrations, infrastructure changes, anything that alters a hot query plan, and dependency or runtime upgrades. Behaviour behind a flag and real fixes stay possible, because the alternative is being unable to respond during the period when responding matters most.

**What moves before the window.**

- **Migrations and backfills**, finished and verified with time to spare, so nothing large is in flight when traffic arrives.
- **Capacity decisions taken in advance.** Autoscaling reacts. That is fine for a spike, but not enough for a sustained peak with a hard downstream limit, because the connection budget does not scale with the autoscaler. So the ceilings are raised deliberately, and the database sizing is decided ahead of time, not during the peak.
- **A load test at peak shape, not at average volume.** The interesting failures are all at the peak, and testing at the mean finds none of them. Shape matters as much as volume. A concentrated two-hour burst behaves completely differently from the same daily total spread evenly.
- **A cold-start rehearsal.** If capacity has quietly been sized on a warm cache, then a restart during the peak is an outage. Knowing what happens with an empty cache, and having sized for it, is a different statement from hoping it does not happen.

**What changes operationally during the window.** Higher alerting sensitivity on the things that degrade before they fail: queue depth trends, connection pool waits, cache hit ratio and projection lag. A named person who can decide to roll back without calling a meeting. And a rehearsed rollback, because the window is exactly when nobody wants to try one for the first time.

**Afterwards.** The peak is the best data anyone will get all year. So the numbers get recorded and become next year's sizing input, instead of being forgotten. And the changes deferred by the freeze land in a planned sequence, not as one large batch. The release after the freeze is where the accumulated risk really sits. Treating it as a return to normal is how a freeze causes the incident it was meant to prevent.

**The honest scope of my experience here.** The marketplace had no strong seasonality: its load was steady business-to-business traffic. The discipline above is what I would apply. It is drawn from the burst work I did do, not from having run a retail peak. That burst work was the morning check-in concentration on the cancer platform, and bulk imports on the marketplace.

</details>

