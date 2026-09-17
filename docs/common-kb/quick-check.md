# Quick check

## Contents

- [Concurrency](#concurrency)
- [Databases](#databases)
- [Messaging](#messaging)
- [APIs and security](#apis-and-security)
- [Reliability](#reliability)

## Concurrency

<details>
<summary>threading, multiprocessing, async</summary>

**Three ways to handle more than one task at once. Threads and async take turns (concurrency). Processes really run in parallel.**

**Threads** share memory inside one process. They help when work waits on I/O. In standard CPython, only one thread runs Python code at a time (the Global Interpreter Lock, GIL). So threads don't speed up CPU work. Shared memory also needs locks, and locks can cause deadlocks.

**Processes** each have their own memory and their own interpreter, so they use several CPU cores. The cost is slower start-up and copying data between them. With large data, the copying can cancel the speed-up.

**Async** runs many tasks on one thread. A task gives control back while it waits on I/O, so one process can hold thousands of connections cheaply. But one blocking call, like a sync database driver, stops every task.

My rule: CPU work goes to processes, lots of I/O goes to async, and blocking libraries or small load go to threads.

</details>

## Databases

<details>
<summary>db transactions</summary>

**A group of statements that either all take effect or none do.**

The ACID properties describe it. Atomicity: commit applies everything, rollback applies nothing. Consistency: the database enforces the constraints you declared, but business rules are still your job. Isolation: how much one transaction sees of other transactions' unfinished work. Durability: after commit, the change survives a crash, because it is in the write-ahead log on disk.

I keep transactions short, with no network calls inside, because a transaction holds its locks until it ends. Locking rows in the same order makes deadlocks rare. When one still happens, I retry.

A transaction stops at the database. It can't cover a message broker or another service. For that you need an outbox, or a saga that undoes steps instead of rolling back.

</details>

<details>
<summary>isolation levels</summary>

**How much one transaction can see of other transactions' unfinished work. Higher levels stop more errors (anomalies) but allow less concurrency.**

Read uncommitted allows dirty reads. Read committed hides uncommitted data, but two reads in one transaction can differ. Repeatable read keeps your reads stable for the whole transaction. Serializable gives the same result as running the transactions one at a time.

No level below serializable stops one error (write skew). Two doctors both check that someone else is on call, and both sign off. Nobody overwrote anything, but the rule is broken.

Defaults differ: Postgres uses read committed, MySQL uses repeatable read. I use read committed and protect rules with constraints or `SELECT ... FOR UPDATE`. I use serializable only when a rule across rows can't be a constraint, and then I add retries.

</details>

<details>
<summary>optimistic locking</summary>

**Don't lock the row. Instead, check at write time that nobody changed it since you read it.**

Optimistic and pessimistic locking both stop the same problem (a lost update). Two users read the same record, and the second save silently overwrites the first.

With optimistic locking, each row has a version number. You update `WHERE id = ? AND version = ?` and increase the version. If zero rows change, someone else won, so you retry or show a conflict. With pessimistic locking, `SELECT ... FOR UPDATE` locks the row until commit, and other requests wait.

My rule: use optimistic when conflicts are rare, like a user editing a form for minutes. You can't hold a database lock that long. Use pessimistic when many requests compete for one row, like the last item in stock. There, optimistic turns into many wasted retries.

</details>

<details>
<summary>n+1 problem</summary>

**You run one query for a list, then one more query for every item in it. That is 1 + N trips to the database when 2 would be enough.**

It usually comes from lazy loading in an ORM. You load 200 orders and loop over them. Each read of `order.customer` runs its own query. GraphQL causes it too, because a resolver runs once per parent object.

Each query is fast, so the slow-query log shows nothing. But 200 trips at 2 ms is 400 ms of waiting. That cost grows with the number of rows.

The fix is one query for all the IDs: eager loading, `WHERE id IN (...)`, or a DataLoader in GraphQL. I catch it with query-count checks in tests.

But I don't eager-load everything by default, because that fetches data nobody uses.

</details>

<details>
<summary>splitting logic between app and database</summary>

**The database owns what must stay true no matter who writes the data. The app owns the business decisions.**

Constraints like foreign keys, unique and not-null belong in the database, because the app is never the only writer. Also, a check in the app can't guarantee uniqueness when two requests run at the same time. Business rules and workflow belong in the app, where you can test and review them.

Work on sets of rows also stays in the database. Filter, join and aggregate there, instead of loading rows into the app to count them. I avoid heavy logic in stored procedures, because they are hard to test, version and deploy.

</details>

## Messaging

<details>
<summary>delivery guarantee</summary>

**How many times a message can arrive. There are three levels, and a stronger level costs more speed and complexity.**

**At most once:** send once and never retry. It is fast, but messages can get lost. That is fine for metrics. **At least once:** retry until the other side confirms (an acknowledgement). Nothing is lost, but duplicates can arrive. This is the usual default, for example in SQS standard queues and Pub/Sub.

**Exactly once:** each message changes the data only one time. A network can't give you this for free, so you build it from at-least-once plus skipping duplicates. The consumer saves each message ID in the same transaction as the change, and skips IDs it has already seen (an idempotent consumer).

My rule: ask what is worse, a lost message or a duplicate. For payments, a duplicate is worse. For analytics, losing a few events is OK.

</details>

<details>
<summary>outbox</summary>

**A way to save a change and publish its event without the two getting out of sync.**

The database and the message broker can't share one transaction. If you save first and the publish fails, the event is lost. If you publish first and the save fails, you announce something that never happened.

So you write the event into an outbox table, in the same transaction as the change. Either both are saved or neither is. A separate worker then publishes unsent rows and marks them as sent. The worker finds them by polling the table or by reading the database log (change data capture).

The worker can crash after publishing but before marking the row. So delivery is at-least-once, and consumers must skip duplicates by event ID. That is a good trade, because a duplicate is easier to handle than a lost event.

</details>

## APIs and security

<details>
<summary>a well-designed api</summary>

**One that a caller can use correctly without reading your code, and that keeps working when you change it.**

It is consistent: the same naming, pagination and error format everywhere. So after one endpoint, a caller can guess the next. It models what the caller wants to do, not your database tables, so your internals stay free to change. Errors use the correct status code plus a stable error code the client can check.

Changes are additive: add fields, don't change what a field means, and remove things only after a deprecation notice. Lists are paginated by default. Writes accept an idempotency key, so clients can retry safely.

The choice of REST, GraphQL or gRPC matters much less than consistency and careful change.

</details>

<details>
<summary>jwt</summary>

**A signed JSON token that a client carries to prove who it is.**

It is signed, not encrypted, so anyone who has the token can read the claims. Secrets never go in it. A service checks the signature locally, with no session lookup. If other services verify it, sign with a private key and share only the public key. With one shared secret, anyone who can check a token can also create one.

The cost is that you can't revoke it. It stays valid until it expires, even after logout. So access tokens are short-lived. The refresh token is stored, so you can revoke it, and access ends when the current access token expires.

Check `exp`, `iss` and `aud`, not just the signature, because a token for another service is still validly signed. Set the allowed algorithm on the server, so the token can't choose how it is checked.

For one app with one database, a plain session is simpler, and you can revoke it at once.

</details>

## Reliability

<details>
<summary>timeout, retry, circuit breaker</summary>

**Three layers of one idea: don't wait forever, retry when it is worth it, and stop when it isn't.**

**Timeout** limits how long one call can take, so a slow service can't use up all your threads. **Retry** handles a failure that would probably work next time. Retry only if the call is safe to run twice (idempotent), and wait a bit longer each time, with some randomness (backoff and jitter). **Circuit breaker** notices that too many calls fail, stops calls for a while, and gives the other service time to recover.

Retries without a breaker add load exactly when the service is already failing.

</details>

<details>
<summary>circuit breaker implementation</summary>

**Three states and a failure counter.**

**Closed:** calls go through, and you count failures over a rolling window. When the failure rate goes over a threshold, the breaker opens. **Open:** every call fails at once without calling the service, until a cooldown ends. **Half-open:** one trial call goes through. If it works, the breaker closes. If not, it opens again.

Get two things right. Trip only after a minimum number of calls, so two failures at startup don't open it. And use one breaker per dependency, not one for everything.

</details>

<details>
<summary>99% availability</summary>

**99% allows 3.65 days of downtime a year, about 7.3 hours a month. First I check they don't mean 99.9%, because that needs a different design.**

For 99% you don't need multi-region or automatic failover. One region, managed services, health checks with auto-restart, tested backups and on-call alerts are enough.

At this level, most downtime comes from your own deploys and config changes. So safe deploys and fast rollback help more than extra servers. Measure availability from the user's side, not from server uptime. Three hard dependencies at 99.9% each limit you to about 99.7%, unless you degrade gracefully when one fails.

A 10-minute outage barely touches a 7-hour budget, but a 4-hour outage uses more than half of it. So fast recovery matters more than preventing every failure.

</details>

<details>
<summary>99.99% availability</summary>

**99.99% allows 52 minutes of downtime a year, about 4 minutes a month. That is too short for a human to fix things, so recovery must be automatic.**

Nothing in the request path can be a single point of failure. Run across several zones, with enough spare capacity to lose one zone at peak. Otherwise a zone failure becomes a total outage. The database is the hard part: you need replicas with automatic promotion, and clear targets for data loss and recovery time (RPO and RTO).

Changes still cause most downtime. So deploys go to a small share of traffic first (a canary) and roll back automatically when errors rise. Every dependency gets a timeout, a circuit breaker and a degraded mode.

Big outages usually hit all replicas at once, for example one bad config pushed to all of them. Extra servers don't help against that. Test failover on a schedule, because an untested failover often fails too.

The cost is 24/7 on-call and slower change, so I first ask if the business really needs four nines.

</details>
