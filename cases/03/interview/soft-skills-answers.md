# Soft Skills — Interview Answers

> Questions supplied by the client.

---

### Q1. How do you suggest your ideas on improvements to the team?

**Brief answer**
I bring a proposal with evidence, not an opinion. I show what the current approach costs us, name one change, and say up front how we would know it worked.

<details>
<summary><strong>Must cover</strong></summary>

- **start from a number**, not from a feeling
- **one small, reversible change** rather than a redesign
- **the test named up front**, alongside the change
- **accepting the answer when it is no**, and recording the trade-off
- timing it away from a deadline, writing it down so it outlives me

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

I start from a number, not from a feeling. On the tender platform the submission path sees about 25 requests per second most of the day. It sees roughly 260 for ten to twenty minutes, when several hundred vendors finish against the same closing time. Reactive autoscaling adds pods after the errors have already happened. So I proposed one change: raise the pod floor on a schedule built from `tender.closes_at`, because closing times are known days ahead. The proposal named the test as well as the change — the error rate at the surge must not differ from the error rate at baseline.

Three things make this land with a team. I keep the change small and reversible, so saying yes is cheap. I bring it when nobody is mid-release. And I write it into the design document afterwards, so the reason survives me leaving the room.

The other half of the skill is accepting no. I also proposed dropping [Kafka](https://kafka.apache.org/documentation/ "Apache Kafka — Distributed log that stores partitioned, replicated streams of records for publish-subscribe and stream processing") and moving the audit log into partitioned [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") tables, because three asynchronous mechanisms is a lot of machinery at this volume. The team pushed back: the audit sink and the search projection both rebuild by replaying an ordered log, and the outbox alone does not give that. They were right. I recorded it as a costed trade-off, with the condition that would change the answer. If operational load becomes the binding constraint, that is the first simplification to reach for. An idea that gets written down as a condition is not a lost idea.

</details>

---

### Q2. How do you estimate tasks, ensuring efficient planning and meeting deadlines?

**Brief answer**
I split the work until each piece resembles something I have done before. I estimate those pieces, and I name the ones I cannot estimate instead of padding them silently.

<details>
<summary><strong>Must cover</strong></summary>

- **split until each piece is familiar**
- **estimate the known parts, name the unknown ones separately**
- **a time-boxed spike** for each unknown, with a decision at the end
- **re-estimate at the first checkpoint** and report a slip early
- ranges rather than single numbers, tracking actuals against estimates

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

An estimate is only reliable for work that looks like work I have done. So I decompose until most pieces do, and I treat what is left as a separate line item.

The sealing commit on the tender platform is a good example. Most of it was familiar: a transaction across four tables, an advisory lock per tender, an append to a hash-chained ledger. I could estimate that within a day. One part was not familiar — releasing a key through a grant that only exists after unsealing. I did not guess. I put a two-day time-boxed spike against it, with a clear decision at the end. Either grant-based release works as documented, or we fall back to a simpler key model and accept a weaker custody claim.

Two habits keep the plan honest after that. First, I quote a range and say what drives the top of it, because a single number hides the risk I just measured. Second, I set a checkpoint early enough to still matter, usually at the first third. If the spike overruns, I say so that week, not at the deadline. A late estimate that arrives early is a planning input; the same news on the due date is only an apology.

I also use a measurable target where one exists. The sealing path had a budget of 1.2 seconds at the 95th percentile, and the design recorded a worst case near 800 milliseconds. That turns "is it fast enough" from a debate into a benchmark, so the work has an end.

</details>

---

### Q3. What is your approach to decomposing complex tasks?

**Brief answer**
I cut first along the lines where a mistake would be expensive, then by what can be tested on its own. The riskiest piece goes first, not last.

<details>
<summary><strong>Must cover</strong></summary>

- **cut by blast radius first** — what can destroy something is separated from what only reads
- **each slice demonstrable by itself**
- **the risky piece first**, while there is still time to be wrong
- **a thin path end to end** before any depth
- interfaces agreed early, vertical slices instead of layers

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The tender platform's eight services follow one rule, and it is the same rule I use on a task. Anything that can decide or destroy a submission is kept apart from anything that merely reads, searches or generates. That is why bid custody is its own service, and why the language-model work has its own service with its own network route out. Decomposition by blast radius gives boundaries that stay correct as the system grows. Decomposition by layer — controllers, services, repositories — gives pieces that cannot be released or tested alone.

Inside a feature I use the same order. For bid submission the slices were: issue a presigned upload, accept the upload, scan and extract the file, build the manifest, seal, append the ledger row. Each slice is demonstrable by itself. Then I reorder them by risk rather than by sequence, and build the ledger append first. It is the part that must never be wrong, and finding a flaw in it during week one is cheap.

I also build a thin path end to end before going deep anywhere. One tender, one document, one bid, sealed and unsealed. That surfaces the interface mistakes that are expensive later. One example: the timestamp deciding lateness has to be written by the server inside the ledger transaction, never sent by the client.

The last step is naming the interface between the pieces before the pieces exist, so two people can work in parallel without merging each other's guesses.

</details>

---

### Q4. How would you onboard a new engineer on a complex distributed system?

**Brief answer**
I give them one real request path end to end, running on their own machine, and a small real change on that path merged in the first week.

<details>
<summary><strong>Must cover</strong></summary>

- **one path taught properly**, not a tour of every service
- **running locally on day one**, with stubs instead of cloud accounts
- **a small real change merged in week one**
- **the written design set as the map**, kept current
- **the domain vocabulary**, which is half the difficulty
- pairing on a real incident, reading the alert list

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A tour of twelve deployments teaches nothing. One path taught properly teaches the system.

Day one is about running it. The platform's Docker Compose stack brings up PostgreSQL, [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), OpenSearch, LocalStack in place of the Amazon Web Services dependencies, and a recorded model stub instead of the real model endpoint. A new engineer needs no cloud account to see a tender created and a bid sealed. Anything that needs a cloud account on day one becomes a week of waiting for access.

Day two is the sealing path, walked in order. The client asks for a presigned upload, and the bytes go straight to object storage. A Lambda validates the object, and a worker scans and extracts it. Then the submit call takes a per-tender lock, seals the key, appends the ledger row and commits. That one walk explains why bytes never cross the Application Programming Interface ([API](https://en.wikipedia.org/wiki/API "Defines the contract by which software components exchange requests and data")), why the lock exists, and why the server sets the timestamp.

Week one is a real change on that path — a new domain metric, or an index with its query plan checked. Something small, reviewed and merged. Reading code without changing it does not build confidence.

Two supports run alongside. The design set, files `00` through `06`, is the map, and I treat a wrong page in it as a bug. And I teach the vocabulary deliberately: tender version, sealed bid, recusal, consensus scorecard, debarment. On a domain system the words are harder than the code, and nobody admits to not knowing them.

</details>

---

### Q5. How do you explain technical trade-offs to non-technical stakeholders?

**Brief answer**
I state the choice as two outcomes they already care about, give the cost of each in their own units, and make a recommendation rather than handing them a menu.

<details>
<summary><strong>Must cover</strong></summary>

- **frame as outcomes**, not as components
- **cost in their units** — money, delay, legal exposure
- **a clear recommendation**, one sentence
- **what we lose**, said plainly
- **write the decision down** afterwards, with the date and the owner
- no jargon without a plain-word version beside it

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Stakeholders do not choose between technologies. They choose between outcomes, and my job is to translate honestly in both directions.

The tender platform runs in one region, with no second region for disaster recovery. I did not present that as an architecture discussion. I said this. If that region has a bad day, the platform is unavailable for up to an hour and no bid is lost. A second site costs money we have not been given. The data residency rule may also forbid putting a copy of this data outside the country. My recommendation was to stay in one region and record the exposure openly. The department could then decide as a budget and legal question, which is what it actually was.

The second example is the key service the sealing path depends on. If it is unavailable, we refuse to accept a bid rather than accept one we cannot prove was sealed. In their terms: a vendor sees a clear error and retries, instead of an award that a competitor can challenge and we cannot defend. Put like that, a fail-closed design stops sounding like an outage and starts sounding like the safer option, which it is.

Three rules keep this working. I never use a term without a plain-word version next to it. I say what we lose, because a trade-off with no cost is a sales pitch and people stop trusting it. And I write the decision down afterwards with the date and who made it, so nobody has to remember six months later why the system is single-region.

</details>

---

### Q6. How do you balance technical leadership with hands-on engineering?

**Brief answer**
I stay hands-on where a mistake is unrecoverable, and lead everywhere else through written design and review instead of through meetings.

<details>
<summary><strong>Must cover</strong></summary>

- **decide in advance where my hands belong**
- **lead in writing** — design documents and reviews, not meeting time
- **hand work over with the context**, not only the task
- **protect blocks of focus time** for both roles
- the warning sign of over-committing, and what I drop first

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The two roles compete for the same hours, so I decide in advance where my hands belong. On the tender platform that was the custody path — sealing, the ledger, the key grant, the unsealing check. A defect there is not a bug report, it is a disputed award. I wrote and reviewed that code myself.

Everything else I lead by writing. A design document states the rule, the alternative that was rejected and the cost we accepted. It does more than a meeting, because it is still there next month and a new joiner can read it. The same goes for review: a comment explaining why the eligibility check must read the primary and not a replica teaches more than me writing the line myself.

When I hand work over, I hand over the context with it. Not "add an index on debarment", but "this index sits on the sealing path, so its query plan is the one we verify in the pipeline". Without the why, people make locally reasonable choices that break a system property.

I protect time for both. Leadership work expands to fill any gap, and deep work does not survive being cut into twenty-minute pieces. My own signal that I am over-committed is that reviews start queueing behind my own branch. When that happens I drop my branch first, not the reviews, because my branch blocks one person and the review queue blocks everyone.

</details>

---

### Q7. How do you handle knowledge gaps on your team?

**Brief answer**
I treat a gap as a design problem rather than a people problem. I make the knowledge reachable in one place, then spread it through real work rather than a lecture.

<details>
<summary><strong>Must cover</strong></summary>

- **a gap is nobody’s fault**, and usually a sign the system is too hard
- **write it down once, in one place** that owns the fact
- **pair on real work** instead of running a training session
- **rotate the task** so it does not stay with one person
- **check the bus factor** on the critical paths
- recorded decisions, so the reason is available later

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

A knowledge gap usually means the system is harder than it needs to be, or the knowledge lives only in someone's head. Both are fixable, and neither is anyone's fault.

The first move is to write the fact down once, in the file that owns it. On the tender platform the technology choices live in the high-level design and nowhere else. So a question about why there are two search clusters has one answer, not three slightly different ones. Duplicated explanations drift, and drifted explanations are worse than no explanation because people trust them.

The second move is to spread the knowledge on work that was going to happen anyway. If only one person understands the ledger chain, I pair with someone else on the next change to it. That is a real task with a real review at the end, so it sticks better than a session nobody has a reason to remember.

The third is rotation, deliberately. The restore drill on this platform runs quarterly — a point-in-time restore, a ledger verification, a projection replay. I make sure a different person runs it each time. A procedure only one person can execute is an outage waiting for that person's holiday.

Finally I check the bus factor along the paths that matter, not everywhere. Custody, sealing and the deployment pipeline need two people who can work on them. Reference-data imports do not.

</details>

---

### Q8. How do you handle your own knowledge gaps?

**Brief answer**
I say "I don't know" early and plainly, then close the gap with a small experiment rather than by reading alone. What I could not verify, I write down as unverified.

<details>
<summary><strong>Must cover</strong></summary>

- **say it early**, because a hidden gap becomes a design defect
- **prove it with a small experiment**, not with reading
- **mark the gap where the decision is recorded**
- asking the person who already knows, marking assumptions in the design

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Not knowing is normal. Hiding it is what turns it into a defect, because a guess written into a design document stops looking like a guess within a week.

My habit is to mark the gap where the decision is recorded. The tender platform's design carries several of these, written as explicit checks to make before building. One says that reducing the embedding vector to 768 dimensions is only safe if the model supports truncation properly. The recall has to be re-measured on real tender packs before the index mapping is fixed. Another says the statutory retention period for police procurement records is set by national law. It may exceed the five-year storage model, so the figure has to come from the department's legal office. A third says a range check on the debarment table is only index-assisted if the query is written a particular way. The plan has to be confirmed with real data volumes.

None of those is me being clever. Each is me refusing to write a number I cannot support. The alternative is a design that reads as settled and is not.

For closing the gap, I prefer a small experiment over more reading. Reading tells me what is claimed; a one-hour test against a realistic data set tells me what happens here. And I go and ask the person who already knows, before spending a day on it. That is usually the fastest step, and the one people skip because it feels like an admission.

</details>

---

### Q9. What drives you in your work?

**Brief answer**
Work where being wrong has a real cost, and where the claim can be checked. I like systems that can prove the thing they promise.

<details>
<summary><strong>Must cover</strong></summary>

- **problems where correctness is not decorative**
- **provable claims** — a guarantee you can verify, not assert
- **evidence over opinion** in how decisions get made
- **seeing the system used** by real people
- honest review, and learning at the edge of what I know

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

What holds my attention is a problem where the correctness is not decorative. A sealed bid must be unreadable until the deadline and provably unaltered afterwards. That is not a feature preference. If it fails, a public procurement decision is open to challenge and the department cannot defend it. Work with that kind of consequence makes the engineering decisions sharp, because there is a right answer and it is testable.

The second thing is being able to prove the claim rather than assert it. An append-only ledger whose chain is recomputed nightly and compared against a copy that not even a database administrator can rewrite is a real guarantee. A policy document saying nobody should edit the table is not. I get more satisfaction from a control that holds by construction than from one that holds because everyone behaves.

Third, I like teams that decide with evidence. A measured latency budget beats an argument about which design feels faster, and it ends the argument in an afternoon.

And I want to see the thing used. A platform that a procurement officer actually runs a tender on will teach me more in a month than any amount of design. That is also where I learn: at the edge, on the parts I had to look up. I want people who review honestly enough to tell me when I am wrong.

</details>

---

### Q10. What are your expectations of the future project?

**Brief answer**
A reachable decision-maker, quality gates that can actually fail, and honest scope — trade-offs recorded rather than hidden.

<details>
<summary><strong>Must cover</strong></summary>

- **a real decision-maker** available for the domain questions
- **gates that can fail**, so the pipeline means something
- **honest scope** — recorded trade-offs instead of quiet ones
- **time for the unglamorous work** — migrations, updates, restore drills
- a team that reviews properly, and access to the domain experts

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

My expectations are modest and mostly about how decisions get made.

First, someone who can answer domain questions and decide. On the tender platform several questions were not engineering questions at all. Which country's data protection law applies? What is the retention floor for police procurement records? Can the model provider be used under a no-retention arrangement? An engineer cannot resolve those, and guessing is how a compliance defect gets built. I want to know who decides and how to reach them.

Second, a pipeline whose gates can fail. The platform's pipeline includes a test that submits a bid after the closing time and fails if the system accepts it. A gate that has never failed has not been shown to test anything. I would rather join a project with three gates that bite than twelve that always pass.

Third, honest scope. I do not expect a project without compromises. This one runs in a single region and accepts a single point of failure on the key service. It also keeps three asynchronous mechanisms it does not strictly need at this volume. All three are written down with their cost and the condition that would change them. That is the difference between a trade-off and a surprise.

Fourth, time for the unglamorous work: migrations, dependency updates, restore drills. And a team that reviews properly, because that is where I learn fastest and where quality actually comes from.

</details>

---

### Q11. Tell me about the most interesting bug you have dealt with.

**Brief answer**
Bids submitted in the final second were being rejected as late. The clock was correct; the rule was wrong — we measured lateness at the moment the write committed, not when the submission began.

<details>
<summary><strong>Must cover</strong></summary>

- **the symptom** — vendors rejected at the closing second, with no explanation they could act on
- **the false lead** — clock skew between the vendor's machine and the server
- **the real cause** — lateness judged at commit time, after locking and key sealing
- **why it was hard to see** — it only appears under contention at the deadline
- **the fix** — record both timestamps and accept a commit whose transaction started before closing
- **the guard** — a test that fails if a genuinely late bid is accepted
- the deliberate choice to keep the server as the only clock

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The symptom was rare and bad. A handful of vendors submitted just before a tender closed and got a rejection saying their bid was late, even though they had pressed submit before the deadline.

The first theory was clock skew, because that is the usual answer. It was wrong, and checking it cost a day. The platform never consults the vendor's clock. The sealing timestamp is written by the server, inside the transaction that appends the ledger row. That transaction is the definition of being on time.

The real cause was where we measured. The submit call does several things before it commits. It checks eligibility against the primary database, and confirms every document in the manifest is present in object storage. Then it takes a per-tender advisory lock, generates and seals the encryption key, appends the ledger row and commits. Normally that whole sequence takes about 200 milliseconds. At the deadline, with several hundred vendors finishing against the same closing minute, lock contention pushes it towards 800. A submission that began at 23:59:59.8 would commit at 00:00:00.1 and be recorded as late.

It was hard to see because it only appears under contention, at exactly the moment nobody wants to be debugging.

The fix was to make the rule match the promise. The ledger now records both timestamps, and a commit is accepted if its transaction started before the closing time. The rejection stays for anything that genuinely started late, and the pipeline carries a test that submits after the deadline and fails if the platform accepts it. This is the case I remember, because the code was doing exactly what it was written to do and the defect was in what we had decided to measure.

</details>

---

### Q12. What is your code review approach?

**Brief answer**
I read for correctness and for the contract first, and leave style to the tools. Most of my comments are questions, and I say which ones block a merge.

<details>
<summary><strong>Must cover</strong></summary>

- **contracts and failure modes first** — what breaks and who depends on it
- **tests in the same diff**, and whether they can fail
- **style left to the linter and the type checker**
- **questions rather than instructions** in comments
- **blocking and non-blocking comments labelled**
- small pull requests, and reviewing the migration as carefully as the code

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

My first pass is not line by line. I read the change for what it promises and what depends on it. Does this endpoint alter a response other services already parse? Does this migration narrow a column, so a rollback would meet a schema the previous image cannot use? Those defects are expensive and invisible in a diff read line by line.

The second pass is domain rules, and on the tender platform there is a fixed list I check. Does every query carry the tenant predicate, so a vendor cannot reach another vendor's rows? Does anything on the eligibility, sealing or scoring paths read a cache or a replica, when those paths must read the primary? Does a new log line risk carrying bid content or a model prompt? Does this change touch the ledger, and if so, is there a test that fails when it is wrong?

The third pass is the tests. I ask whether the test would fail if the behaviour regressed. A test that passes in both directions is a comment with extra steps.

What I deliberately do not review is formatting and naming style. The pipeline runs a linter and a strict type checker before a human sees the change, and arguing about what a tool can decide wastes the reviewer's attention.

On tone: I ask rather than instruct, because I am often missing context. And I mark clearly which comments block the merge and which are suggestions, so the author is not left guessing whether a remark is a veto.

</details>

---

### Q13. Describe your Definition of Done.

**Brief answer**
Reviewed, merged, migrated, observable and reversible. If I cannot see it working in production and undo it safely, it is not done.

<details>
<summary><strong>Must cover</strong></summary>

- **reviewed and merged**, with the pipeline green
- **tests that can fail**, including the negative case
- **migrations expand-only**, so a rollback meets a schema it can use
- **observable** — a metric, log line or trace that shows it working
- **reversible** — a named rollback path
- **the decision recorded** where that fact is owned
- alerts or dashboards updated when the change adds a failure mode

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

"It works on my branch" is the start of the checklist, not the end.

Reviewed and merged with the pipeline green is the easy part. The pipeline on this platform runs a linter, a strict type check, unit tests, and integration tests against real dependencies in containers. It also runs contract tests on the sealing path, a migration check, and a performance benchmark compared against the recorded latency budget. All of them block.

Tests have to be able to fail. For anything on the critical path I want the negative case present. For the sealing work, that is a bid submitted after the closing time which the test expects to be rejected.

Migrations are expand-and-contract only, applied as a job before the rollout, so the previous image always runs against the new schema. That is what makes rollback a redeploy of the previous image tag rather than a schema reversal at three in the morning.

Observable means I can point at something. A metric, a log line with the request and trace identifiers, or a span in a trace. A change may add a new way to fail — a queue that can back up, a job that can be quarantined. Then the alert or the dashboard is part of the change, not follow-up work. On this platform that included things like the count of documents waiting to be scanned and the share of model artifacts quarantined for unresolvable citations.

Finally, the decision is written where that fact is owned, once. A design choice explained in three files drifts in two of them.

</details>

---

### Q14. How do you maintain code quality (for example code reviews, tests, linters)?

**Brief answer**
Gates in the pipeline that block the merge, plus human review for the things no tool can see — contracts, domain rules and whether a test could ever fail.

<details>
<summary><strong>Must cover</strong></summary>

- **blocking gates** — linter, strict type checking, unit and integration tests
- **integration tests against real dependencies**, not mocks
- **a gate proven capable of failing** on the path that must never be wrong
- **a performance regression gate** measured against a recorded budget
- **human review for contracts and domain rules**
- secret scanning and container image scanning as blocking stages

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Quality that depends on everyone remembering does not hold. I put as much of it as possible into gates that block, and spend human attention on what gates cannot check.

The tender platform's pipeline runs in a fixed order, each stage blocking the next. First `ruff` and `mypy --strict`, then unit tests. Then integration tests against real PostgreSQL, Redis, OpenSearch and LocalStack in Docker Compose. A recorded model stub means no test reaches the real model endpoint. Then contract tests on the sealing path, and a migration check that applies and reverses the migration against a copy of the staging schema. Then performance benchmarks for sealing and search latency. A regression beyond twenty percent fails the build instead of filing a ticket. Finally the image build with a vulnerability scan. Secret scanning runs as a blocking stage and as a commit hook.

Two details matter more than the list. Integration tests run against the real dependency rather than a mock. The defects worth catching are the ones in how the dependency actually behaves — a query plan, a visibility timeout, an index that is not used. And at least one gate has to be proven capable of failing: the sealing contract test submits a bid after the closing time and fails if the platform accepts it. A suite that has only ever passed confirms whatever we already believed.

Human review then covers the rest. Does a change break a consumer's contract? Does a domain rule such as reading the primary on the eligibility path still hold? Could the new tests ever go red?

</details>

---

### Q15. Explain a technical challenge you faced and how you solved it.

**Brief answer**
Making a third-party language model genuinely useful over police procurement documents, without letting it leak a sealed bid or influence an award. The answer was to constrain it structurally, not by policy.

<details>
<summary><strong>Must cover</strong></summary>

- **the tension** — useful assistance over documents that must not leave or be influenced
- **one egress route** — a single controlled subnet, every other workload blocked
- **redaction before egress**, with the mapping reapplied on the way back
- **citation validation** — a claim that does not resolve to a real page kills the artifact
- **advisory only** — no generated output is ever an input to a score or an award
- **the kill switch**, so the platform is fully usable with the feature off
- per-tender opt-out, logging the payload hash rather than the payload

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The brief asked for two things that pull against each other. Requirement documents should be parsed and analysed so criteria and deadlines are proposed to the drafting officer, and long vendor proposals should be summarized for evaluators. The same documents are confidential government procurement material, and the award they feed into has to survive a legal challenge.

Policy alone does not solve that, so we made it structural in four places.

Network. Only the model service and its workers have any route to the internet, through one egress-controlled subnet whose address translation allows exactly the model endpoint's hostname. Every other pod has a network policy with no egress beyond internal endpoints. The boundary is therefore enforceable as configuration, not as a code review habit.

Content. Names, national identity numbers, phone numbers, email addresses and bank details are replaced with stable placeholders before any text leaves. The mapping stays in the database and is reapplied to the result. If redaction fails, the job fails — it never falls back to sending the original text.

Grounding. The pipeline emits structured claims, and each one names the chunk it came from. A validation step resolves every claim back to a real chunk of a real document belonging to that tender or bid. One unresolvable claim fails the whole artifact, which is then quarantined and never shown. An unsupported sentence cannot reach a human.

Authority. No generated output is ever written into a score, an eligibility verdict or an award. Extraction proposes criteria that the officer accepts or discards, and the criteria themselves are only ever written by the ordinary endpoint. The whole feature sits behind a switch, and with it off evaluators read the source documents and score exactly as they would without it. A tender classified above the egress threshold runs that way for its entire life.

The hardest part was resisting the useful-sounding middle ground — "the model suggests a score and a human confirms it". An award a model influenced, which nobody can trace, is indefensible in a procurement audit.

</details>

---

### Q16. What did you learn from working on the recent project that you would apply elsewhere?

**Brief answer**
Put a guarantee into a structure rather than into a rule people follow. If breaking it requires changing the schema or the network policy, it holds.

<details>
<summary><strong>Must cover</strong></summary>

- **where a guarantee lives** — in a constraint, not in a handbook
- **a worked example** — segregation of duties as a database rule
- **a gate that has never failed proves nothing**
- **write unknowns down as unknowns** rather than guessing a number
- **record the cost of a trade-off**, and the condition that would change it
- pre-scaling from events you already know about

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

The lesson I would take anywhere is about where a guarantee lives.

On this platform, segregation of duties is not a paragraph in a handbook. Adding an evaluator is rejected if that person created the tender or any of its versions. Signing an award is rejected unless the signer is the committee chair and every non-recused evaluator has a locked scorecard. Those are constraints and service checks. The sealed-bid guarantee works the same way: no principal except one service can read the bid prefix, and the key grant that allows decryption is only created when unsealing succeeds. Breaking either one takes a schema change or an infrastructure change, both of which are visible in review. A rule that only needs someone to forget is not a control.

The second lesson is about verification. A test suite that has always passed has not been shown to test anything. I kept one deliberate negative case on the path that matters: a bid submitted after the deadline that must be rejected. That changed how I think about every other gate I write.

Third: write down what you do not know, as an unknown. The design carries several explicit checks to make before building, on embedding truncation, on the statutory retention period, on a query plan. Each one is a place I refused to invent a number. That habit costs nothing and prevents a whole class of confident mistakes.

Fourth, a smaller one that transfers immediately: if you know when the load is coming, scale before it. Tender closing times are known days ahead, so the pod floor rises on a schedule rather than reacting after the first errors.

</details>

---

### Q17. How do you deal with unclear requirements?

**Brief answer**
I turn the unclear part into a few concrete cases and take those back for a yes or no. Meanwhile I build everything that does not depend on the answer.

<details>
<summary><strong>Must cover</strong></summary>

- **turn the question into examples** somebody can accept or reject
- **find who actually decides**
- **keep building what does not depend on the answer**
- **record the assumption where the decision lives**, marked as unverified
- **an assumption written down as a fact becomes one**
- make the code easy to change at that point, rather than guessing widely

</details>

<details>
<summary><strong>Detailed answer</strong></summary>

Asking "can you clarify the requirement?" usually returns the same sentence again. Asking "is this right?" with three concrete cases returns a decision.

So I write the cases. For the tender clarification period, that looked like this. A vendor asks a question two days before closing, the officer answers, and the answer is broadcast anonymously to every bidder on that tender. Yes or no? A question arrives after closing — rejected or held? Those can be confirmed by someone who does not read specifications, which is usually exactly who knows the answer.

Then I find who decides. On a government platform that is often not the person who wrote the brief. The applicable data protection law, the retention floor for procurement records, and whether the model provider may be used at all were legal and contractual questions. I stopped guessing and named them as questions for the department's legal office.

While waiting, I build what does not depend on the answer, and I keep the undecided point easy to change. The design provides the mechanisms every such regime has in common, without deciding which statute applies. Those are recording a lawful basis, exporting a subject's data, erasing personal data without destroying the award trail, and enforcing residency. That way the answer, when it comes, changes configuration rather than architecture.

Finally, I record the assumption in the design and mark it unverified. An assumption that is written down as a fact becomes one within a week, and then nobody remembers to check it.

</details>
