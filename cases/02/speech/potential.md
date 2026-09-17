# Potential follow-up questions

All points come from cases/02/interview/tmp/interview2/transcript.txt, the Tech Lead's interview with another candidate. PERM-01, PERM-02 and PERF-01 were asked by the Tech Lead [35:36, 38:23, 31:41]; after PERF-01 the Tech Lead named the steps they expected, the browser network tab first and then the traces in ELK [34:17–35:35]. ENT-01, ENT-02 and PERM-03 are generated, not asked: ENT-01 and ENT-02 follow from the SCIM 2.0 work on deleted users [21:19] and Entra ID as the identity provider [35:36]; PERM-03 turns the permission design the Tech Lead described [39:23–40:48] into a question; PERF-02 takes PERF-01 one step further, from the slow span to its cause; PERF-03 follows from the Tech Lead's mention of the right indexing [31:41]; PERF-04 applies PERF-03 to the cancer platform's own indexes; PERF-05 moves PERF-02's N+1 from debugging to prevention from the first line of code; MOD-01 follows from the Tech Lead's description of their modular monolith, which has become a plain monolith that they want to split into clear boundaries again by the end of the year [04:20]. CONC-01, APD-01, MIG-01, EVT-01 and EVT-02 are general questions with no source in the transcript. Answers draw on the cancer-support-platform design docs. Existing answers are cited by ID, not restated; SEC IDs live in cases/02/interview/topics/security-and-identity.md, VER IDs in verification-and-domain.md, DB IDs in databases.md, MSG IDs in messaging.md, PY IDs in py-runtime.md, INF IDs in infrastructure.md, API IDs in api-and-read-paths.md and ARCH IDs in architecture.md.

Questions are grouped by topic. Each topic has its own ID prefix — ENT, PERM, CONC, PERF, MOD, APD, MIG and EVT — and numbering starts at 01 within each topic, so a new question takes the next free number in its own topic.

## Topics

- [Entra ID](#entra-id) — ENT-01, ENT-02
- [Permissions](#permissions) — PERM-01, PERM-02, PERM-03
- [Concurrency](#concurrency) — CONC-01
- [Performance](#performance) — PERF-01, PERF-02, PERF-03, PERF-04, PERF-05
- [Module boundaries in a monolith](#module-boundaries-in-a-monolith) — MOD-01
- [API design](#api-design) — APD-01
- [Database migrations](#database-migrations) — MIG-01
- [Events and consistency](#events-and-consistency) — EVT-01, EVT-02

---

## Entra ID

### ENT-01. How would you handle an Entra ID outage gracefully?

**Brief answer**
Users who are already signed in keep working, because tokens are checked locally against cached keys and roles are read from our own database. New sign-ins fail with a clear message, and nothing ever lets a request through unchecked.

<details>
<summary><strong>Detailed answer</strong></summary>

**What an outage actually breaks.** Split it by flow, because each one fails differently:

- **New sign-in through OpenID Connect (OIDC):** fails. Nothing replaces the identity provider here, and nothing should.
- **A request carrying a valid access token:** keeps working, but only if the service verifies the JSON Web Token (JWT) locally (ENT-02).
- **Token refresh:** fails, so each user lasts until their current access token expires, which is 60 to 90 minutes by default on Entra.
- **Role or group lookups against Microsoft Graph at request time:** fail, unless the roles are stored locally.
- **System for Cross-domain Identity Management (SCIM) provisioning:** pauses. Entra is the caller, so creates and deletions arrive late, once it recovers.

**How to make it degrade gracefully.**

1. **Verify tokens locally** against the cached key set (ENT-02). Never call Entra on each request.
2. **Read roles from the app's own database.** SCIM already keeps users and group memberships there, so authorisation keeps working without Entra. The deleted-users work is useful a second time.
3. **Choose the app-side session length on purpose.** A longer session keeps users working during an outage, but a revoked user also keeps access longer. Don't stretch token lifetimes just for resilience; that undoes what SCIM is fixing.
4. **Know what Microsoft already covers.** Entra's backup authentication system keeps issuing tokens for many existing sessions during an outage, but not for every flow, so don't design as if it does.
5. **Make the failure clear.** Tell "identity provider unreachable" apart from "wrong credentials", show a status message instead of a bare 401, and alert on a spike in sign-in failures.
6. **Plan for late deprovisioning.** Give admins a way to disable a user directly in the app when a leaver must lose access now. The timing itself is SEC-11.
7. **Keep break-glass accounts.** One or two local admin accounts that don't depend on Entra, for operators during an incident only: tightly held, audited, and alerted on every use.

**What goes wrong.** Failing open, meaning accepting an unverified token or skipping the check "until Entra is back", turns an availability incident into a security incident. The session length, the emergency disable and the break-glass accounts all touch authentication, so they go to the security champion for review rather than being decided by one developer.

</details>

---

### ENT-02. How does JWKS caching work, and what does it protect you from?

**Brief answer**
Entra publishes the public keys that verify its tokens as a JSON Web Key Set (JWKS). The service downloads them, keeps them in memory by key ID, and checks every token's signature locally, refreshing on a timer or when it sees a key ID it doesn't know.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanism.**

1. **Find the keys.** Entra's OpenID discovery document gives the `jwks_uri`, for example `https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys`.
2. **Store them by key ID.** Each key has a `kid`, and the cache maps `kid` to public key.
3. **Verify.** The token header names the `kid` it was signed with. Look up that key, check the signature, then check issuer, audience and expiry. The full list, and the tenant check people miss, is SEC-03. There is no network call per request.
4. **Refresh.** On a timer, because Entra rolls its keys regularly and publishes a new key before signing with it. And at once on an unknown `kid`, but rate-limited, or junk tokens with random key IDs make the service send large numbers of requests to Entra.

**What it protects you from.** Latency, because there is no call to Entra per request, and an Entra outage (ENT-01). With multiprocessing each worker keeps its own copy, which is fine: it's a few small keys.

**The trap: the library default is not outage-tolerant.** Current PyJWT's `PyJWKClient` caches the key set for five minutes by default (`lifespan=300`). When that expires and the re-fetch fails, it raises an error; it does not fall back to the keys it already had. So five minutes into an Entra outage, every request fails. The options:

- **A longer `lifespan`, in hours.** Simple, but every refresh after expiry still needs Entra to be up.
- **`cache_keys=True`.** Keeps each key it has already resolved in a cache with no expiry, so known key IDs survive an outage. But a key Entra has withdrawn stays trusted until the process restarts.
- **A thin wrapper that keeps its own last-good copy** and serves it when a refresh fails, up to a maximum stale age such as 24 hours, and alerts while it is serving stale keys. This is the one I'd pick.

**Why stale keys need a limit.** Entra can roll a key immediately in an emergency, which is exactly when a key may be compromised. A cache that serves stale keys forever keeps trusting the key being withdrawn. Rotation and overlap windows are SEC-04.

**Security rules.**

- Fetch keys only from the configured `jwks_uri`. Never follow a `jku` or `x5u` URL from the token itself; an attacker controls that.
- Pin the algorithm (`RS256`). Never trust the token's own `alg`, and reject `alg: none`.
- A cached key never makes an expired token valid; the expiry check always applies.

</details>

---

## Permissions

### PERM-01. Your last project was a modular monolith with extracted services. How did you handle permissions — spread across the services, or a central permission system?

**Brief answer**
In between: staff roles were defined once, in Entra ID, and every service checked them locally on its own routes. Which patients a user could see was decided where the data lives, in the database, on every request.

<details>
<summary><strong>Detailed answer</strong></summary>

**Three layers, each with one job.**

1. **Gateway: is the token valid, and is it the right kind of user.** Azure API Management checks the token and its audience. Patients and clinicians get tokens for different audiences, so a clinician token on a patient route is rejected before any of our code runs. The gateway is a filter, never the final authority; the service checks the token again itself.
2. **Service: what kind of action.** Clinician and staff roles are Entra app roles, delivered in the token's `roles` claim. Hospital admins assign them to directory groups, so the hospital manages access with the tools it already uses. Patients are never provisioned: they sign themselves up in a separate patient tenant, and a patient-audience token gives access to their own record only. Each service checks the role on its own routes (PERM-02).
3. **Database: on whose record.** "May this clinician see this patient" means an active care relationship exists, and PostgreSQL row-level security (RLS) enforces it. A query someone forgets to scope returns zero rows instead of another patient's record. The search index gets the same scope as a mandatory filter, so search can't be used to skip the scope.

**Why not a central permission service called on every request.** It puts a network call and one more dependency on every request, and the answer it would give — who may see which patient — is data the database already holds. Checking locally meant no network call per authorization decision.

**Why not rules written separately into each service.** Two copies of a rule end up disagreeing. So each fact has one owner: roles live in Entra, care relationships live in the database, and services read them rather than redefine them.

**How access changes.** SCIM 2.0 provisions clinicians and care-team membership from the hospital directory into the database; patients don't go through it. Deprovisioning a clinician closes all their care relationships in the same transaction, so their next query returns nothing, even with a still-valid token (SEC-11). Why roles are in the token but relationships are not is SEC-10.

</details>

---

### PERM-02. Did you have role-based access, and how did each service handle its own permissions?

**Brief answer**
Yes: role-based access control (RBAC) with six roles decided what kind of action a user could take, and the care relationship decided on whose record. Each service's permissions followed from who was allowed to call it: the user-facing monolith checked roles and scope, and the extracted services accepted exactly one known caller.

<details>
<summary><strong>Detailed answer</strong></summary>

**The roles.**

- `patient`: their own record and diary only.
- `clinician`: records of patients they have an active care relationship with.
- `care_team_admin`: team membership and appointments, no clinical writes.
- `content_author` and `content_approver`: separate on purpose, so nobody approves their own content.
- `platform_operator`: infrastructure only, no routine access to patient data.

**Per service.**

- **The monolith (`care-core`)**, with diary, records, clinical content and identity modules. Every user-facing check lives here. The required role is declared once per router as a FastAPI dependency, so a new endpoint inherits it, and the dependency returns a typed principal: who, which roles, which plane. Modules call each other in-process with that same principal, so there is no second authorization hop inside the monolith (SEC-01).
- **SCIM service.** One caller only: Entra ID, with its own client credential, and network-restricted. No user roles at all.
- **Clinical NLP service.** Not user-facing. Only `care-core` can reach it, over mutual TLS (mTLS), so the user's permission check has already happened before the call.
- **Check-in broker.** A patient's device may publish only to its own check-in topic, matched to the token's subject.
- **Workers and Azure access.** Workload identity federation, so no stored credentials in images or config.

**When one call triggers another.** Inside the monolith, the same principal is passed in-process. To the extracted services, the trust is between services, not the user's token passed along. If an extracted service had needed to act as the user, the right tool is the OAuth 2.0 on-behalf-of flow, not forwarding the token — we didn't need it there.

**Exceptions are recorded, not roles.** Emergency access needs a written reason, grants a time-limited care relationship, notifies the patient's team, and raises an audit event reviewed within 24 hours. The audit trail is append-only.

</details>

---

### PERM-03. Our plan is endpoint-level permissions — get product, create product, delete product. An Entra ID custom claims provider calls our own authorization service at sign-in, and the permissions go into the token. We ruled out Open Policy Agent (OPA). What do you think?

**Brief answer**
It fits: endpoint permissions change slowly, which is exactly what belongs in a token, and business users can manage roles in your own service instead of writing Rego. Three things are worth settling early: how fast a removed permission stops working, what happens to sign-in when the authorization service is slow, and where country or store scope lives, since "may call get product" doesn't say whose products.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it's sound.** It's close to what we did: permissions in the token, checked locally, no call per request. We used Entra app roles; your version goes further, because the permissions come from your own service, where business users can administer them, and it avoids group claims and their cut-off at around two hundred groups (SEC-10). I agree on OPA: for endpoint-level role checks a policy engine is more than you need, and business users can't maintain Rego.

**What to settle.**

1. **A removed permission keeps working until the token expires**, 60 to 90 minutes by default, because a claim is a snapshot. That's fine for routine role changes. Urgent removal needs a faster path: revoke the sessions in Entra, plus an in-app disable (SEC-11).
2. **Sign-in now depends on the authorization service.** Entra calls it on every token issuance, so its speed and uptime become sign-in's. Keep it fast, cache the role-to-permission expansion, and decide on purpose what happens when it fails. Entra also has to reach it over HTTPS, which matters for a service on on-prem OpenShift.
3. **Token size.** One entry per endpoint grows with the API, and the token is sent in a header on every call. Send named roles or short permission codes rather than hundreds of strings.
4. **Endpoint permission is not data scope.** "May call get product" doesn't say whether a user in Hungary may read Austrian data. Resolve country and store scope per request, in one place. We did it with PostgreSQL row-level security; on IRIS I'd first check what it supports, and otherwise enforce it in a single repository layer (SEC-05, SEC-07).
5. **Enforcement.** The same router-level dependency as PERM-02, deny by default, plus a test that walks `app.routes` and fails on any route with no permission declared, so a new endpoint can't ship unprotected.
6. **Administration.** Roles as named bundles of permissions, an audit trail of every grant, and nobody able to grant themselves.

**One configuration detail to check in the current Entra docs:** custom claims need the app registration to accept mapped claims or use its own signing key, and an app-specific signing key changes where the service fetches its keys (ENT-02).

</details>

---

## Concurrency

### CONC-01. What are the main differences between processes and threads, and what are the specific hazards of threads?

**Brief answer**
A process has its own memory. Threads run inside one process and share its memory. So threads are cheap to start and can share data directly, but one thread can break data another thread is using, and a crash takes down the whole process. Processes are isolated and safer, but they cost more memory and have to send data to each other. In CPython with the GIL, threads also don't run Python code in parallel, so threads suit waiting on I/O, and processes suit CPU-heavy work. The main hazards of threads are race conditions, deadlocks, objects that aren't thread-safe, and forking a process that already runs threads.

<details>
<summary><strong>Detailed answer</strong></summary>

**The main differences.**

- **Memory.** Each process has its own address space. Threads share the memory of their process, including every global variable and every object they can reach.
- **Cost.** Starting a process is slower and each one needs its own memory, often tens of megabytes for a Python app. A thread is much cheaper to start and to keep.
- **Communication.** Threads just read the same objects. Processes need a pipe, a queue, shared memory or the network, and in Python the data is usually pickled on the way, which costs time and doesn't work for every object.
- **Failure isolation.** If a process crashes, the others keep running and can be restarted. If a native library crashes inside one thread, the whole process dies with every thread in it.
- **Parallelism in CPython.** The GIL lets only one thread run Python code at a time, so threads help when the work is waiting on the network or disk, and don't help for CPU-heavy Python code. Processes avoid the lock completely (PY-03). Python 3.14 officially supports a free-threaded build without the GIL, but it's optional, and many C extensions aren't ready for it yet.

**How a FastAPI service uses both.** Uvicorn runs several worker processes per pod, for parallelism and isolation. Inside each process, plain `def` routes run in a shared thread pool, so they can block without stopping the event loop (PY-01). How many of each to run is decided by the database connection limit (PY-14).

**The hazards of threads.**

1. **Race conditions.** Two threads read and change the same data, and the result depends on timing. Even `counter += 1` is a read, an add and a write, so two threads can both read 5 and both write 6. The GIL doesn't prevent this: it protects the interpreter's own state, not your logic. The typical case is "check, then act": two threads both see that a cache key is missing, and both do the expensive load. Protect shared state with a lock, or better, don't share it.
2. **Deadlocks.** Thread A holds lock 1 and waits for lock 2, and thread B holds lock 2 and waits for lock 1. Both wait forever, and the process looks alive but does nothing. Always take locks in the same order, hold them for a short time, and use a timeout where you can.
3. **Objects that aren't thread-safe.** A SQLAlchemy session, a database connection and many client libraries must not be used by two threads at once. Share the engine, which is thread-safe, and give each request or task its own session (PY-09).
4. **State that leaks between requests.** A thread pool reuses its threads, so a thread-local value set for one request can still be there for the next request on the same thread. Use context variables for request state, or clear the value when the request ends.
5. **Errors that disappear.** An exception in a background thread doesn't stop the program. It's printed once, or it stays inside a future that nobody reads, and the work silently stops. Always read the result of a future, and log errors in the thread itself.
6. **Forking after threads have started.** Forking copies only the thread that called it. If another thread held a lock at that moment, for example the logging lock, the lock stays locked in the child forever, and the child hangs. This is why Python 3.14 no longer uses `fork` as the default start method for `multiprocessing` on Linux. Start worker processes before starting threads, or use the `spawn` or `forkserver` start method.
7. **Threads can't be stopped from outside.** Python has no safe way to kill a thread. The thread must check a stop flag itself, and a daemon thread is simply cut off at exit, even in the middle of a write.
8. **Bugs that are hard to reproduce.** All of these depend on timing, so they pass in tests and on a laptop and appear under production load. That's the strongest argument for sharing as little as possible between threads: pass data through a queue, and keep each object owned by one thread.

</details>

---

## Performance

### PERF-01. The product detail page is slow, and you don't know yet whether it's the front end or the back end. How do you start investigating?

**Brief answer**
First I check in the browser whether the front end or the back end is slow. I open the network tab, find the product detail API call and read its timing. If the call itself is slow, I use its trace ID to open the trace in the tracing tool and find the span that got longer, which is usually a database query. If the call is fast, the time is spent in the page itself.

<details>
<summary><strong>Detailed answer</strong></summary>

**1. Find out exactly what is slow, in minutes.** Which product, which users, since when? One product with hundreds of variants, one country, and everything since yesterday's deploy are three different problems. I ask the reporter for an example link, then reproduce it myself instead of waiting for their analysis.

**2. Network tab: is the API call the slow part?** Open the browser's developer tools, tick "Disable cache", filter to Fetch/XHR and reload. Click the product detail request and open its Timing tab, which splits the request into phases. The longest phase shows where to look:

- **Long "Waiting for server response"** (time to first byte): the server took that long before sending the first byte, so the back end is slow. If the back end sends a `Server-Timing` header, its breakdown shows up in the same tab. Go to step 3.
- **Long "Content Download":** the server answered quickly, but the response took a long time to arrive. Check the Size column, which shows the bytes transferred and the uncompressed size. A response of several megabytes is too big, for example every variant with stock for every store. If the two sizes are about equal and the response headers have no `Content-Encoding: gzip` or `br`, compression is off. The Preview tab shows what is actually in the response. Make the payload smaller, paginate the variants, or turn compression on.
- **Long "Queueing" or "Stalled":** the request waited in the browser before it was sent. Over HTTP/1.1 the browser opens only six connections per host, so other requests were holding them. The Protocol column (right-click the column header to add it) shows whether HTTP/2 is in use.
- **Many requests in sequence:** in the Waterfall column each bar starts only when the previous one ends, or there is one call per variant. The Initiator column shows which script sent each call. Batch the calls or run them in parallel.
- **Long "Initial connection" or "SSL" on every request:** connections are not being reused, which usually means a proxy or load balancer setting.
- **Every call is fast but the page is still slow:** compare the request times with the DOMContentLoaded and Load times in the status bar. The time is in the page: rendering, a large JavaScript bundle or heavy images. Record the load in the Performance tab and look for long tasks on the main thread (marked in red), and use the Img filter in the Network tab to find oversized images.

**3. Trace: which span got longer.** Take the trace ID from the response header or the logs and open the trace in application performance monitoring (APM): Elastic APM in your ELK stack. The trace covers everything from the API call to every database query and every event it publishes, so it shows where the time went and I don't have to guess.<br>
The cancer platform worked the same way: Elastic APM in Kibana, with the `trace_id` on every log line, so logs and traces are linked by the same ID. What each kind of longer span means, such as a query plan that changed, a cache whose hit rate dropped, requests queueing for a connection pool, or an N+1, is VER-07. Reading the query plan is DB-10.

**4. Is the whole endpoint slow, or just some requests?** Compare the route's median and 95th percentile in the metrics, and show the deploy times on the same graph. A worse tail with an unchanged median suggests the problem is in certain products, such as the one with 500 variants, not to every request.

**5. Fix it and prove it.** Fix the cause the trace showed: an index that matches the actual query, variants loaded in one query instead of one per row, or a cached product detail that is invalidated when the product changes. Then compare the route's 95th percentile before and after in production, not on my laptop (DB-16).

</details>

---

### PERF-02. We've confirmed it's the back end, and APM shows which part is slow. What are the next steps? How do you debug that code, for example to tell an N+1 apart from other causes?

**Brief answer**
First I look at the pattern of spans in the slow part, because each cause shows a different pattern in the trace. Many short, identical queries are an N+1. One long query is a query or plan problem. A long span whose child spans add up to much less is time spent in Python itself. Then I reproduce that exact request, count and time its queries or profile it, and confirm the cause by changing one thing. Last, I fix it and add a test that fails if the problem appears again.

<details>
<summary><strong>Detailed answer</strong></summary>

**1. Find the pattern in the trace.** Compare a slow trace with a fast one for the same route:

- **Dozens of short, identical SQL spans**, the same statement with a different ID each time, and their number grows with the data: a product with 3 variants runs 4 queries, one with 500 runs 501. That's an N+1. Elastic APM can show identical spans as one row with a count, so check the count, not just the durations.
- **The repeated queries come after the handler's own spans have finished:** the N+1 is in response serialisation. The response model reads a lazily loaded relationship, so the handler code itself shows no problem.
- **Many different queries, each fast:** not an N+1, just an endpoint that makes too many separate queries. Combine the queries, or cache the complete product detail.
- **One long SQL span:** the query itself. Run it with the same parameters through EXPLAIN (DB-10). If it's slow only for some products, see DB-12.
- **One long SQL span, but the same query is fast when I run it by hand:** the query was waiting, not running. It was blocked by a lock (DB-06), or those parameters get a different plan (DB-12).
- **A gap before the first SQL span:** the request waited for a free database connection (PY-11).
- **A long parent span whose children add up to much less:** the time is spent in Python: turning thousands of rows into ORM objects, serialising a large response, or a blocking call on the event loop (PY-02). The trace can't tell these apart; a profiler can (step 2).
- **A long outbound HTTP span:** a slow dependency. Timeouts and fallbacks are ARCH-08.

**2. Reproduce that exact request and measure it.** Take the product ID from the trace and call the endpoint locally or in a test environment, with production-sized generated data (VER-03). Then measure the cause the trace suggested:

- **Count the queries per request.** Add a SQLAlchemy `before_cursor_execute` event listener that counts statements, groups them by SQL text and logs the totals when the request ends. The same statement 500 times confirms the N+1. `echo=True` works for a quick look, but it writes far too much to the log.
- **Check in the database.** In `pg_stat_statements`, a statement with a huge `calls` count and a tiny mean time is an N+1. A few calls with a large mean time is a slow query. `auto_explain` logs the plan of slow statements with their real parameters, and it is safe to run in production.
- **Profile time spent in Python.** Profile the single request with pyinstrument locally, or attach py-spy to the running process for a flame graph without restarting it. py-spy needs the ptrace capability, which OpenShift's default security policy doesn't grant, so arrange that with the platform team before an incident. asyncio debug mode logs every callback that blocks the event loop for more than 100 ms.

**3. Confirm by changing one thing.** Change only the suspected cause and measure again. For an N+1, load the variants eagerly: the query count should fall from 501 to 2, and the response time should fall with it. If the count falls but the time doesn't, the N+1 was real but wasn't what made the endpoint slow, so look for another cause.

**4. Fix the confirmed cause.**

- **N+1:** use `selectinload` for collections such as a product's variants, which adds one query and doesn't duplicate rows, and `joinedload` for a single related object such as the brand. Set `lazy="raise"` on relationships, so a missing eager load fails in development instead of running extra queries without any warning.
- **Too many ORM objects:** select only the columns the response needs, and on read-only paths return plain rows instead of ORM objects.
- **A slow query:** add an index for the actual query (DB-09), or change a query whose structure gets slower as the table grows (DB-14).
- **Time in Python:** move blocking work off the event loop (PY-02), and shrink or paginate the response.

**5. Stop it from happening again, and prove the fix.** A test that asserts the endpoint's query count fails if the N+1 appears again (DB-15). Then compare the route's 95th percentile in production before and after (DB-16).

</details>

---

### PERF-03. Which index types are used most often, and how do you choose one?

**Brief answer**
B-tree by default. GIN for JSON, arrays and full-text search. GiST for ranges and nearest-neighbour searches. BRIN for very large tables ordered by time. The bigger decision is usually the column order, and whether the index should be partial or covering. I choose from the query's operators and prove the choice with `EXPLAIN ANALYZE`.

<details>
<summary><strong>Detailed answer</strong></summary>

In PostgreSQL, choose an index from the query, not from the table (DB-09). The operator in the `WHERE`, `JOIN` or `ORDER BY` decides the index type. The columns the query filters and sorts on together decide the column order.

**Index types.**

| Type | Use it for | Operators and queries it serves | Notes |
|---|---|---|---|
| **B-tree** (default) | Nearly everything: IDs, foreign keys, dates, status, names | `=`, `<`, `>`, `BETWEEN`, `IN`, `IS NULL`, `ORDER BY`, `LIKE 'prefix%'` | The right choice for most queries. `LIKE 'prefix%'` works only with `text_pattern_ops` or the C collation. |
| **GIN** | Values that contain many items: `jsonb`, arrays, full-text search | `@>`, `?`, `&&`, `@@` (tsvector); with `pg_trgm`, also `LIKE '%term%'` | Fast reads, slower writes. Can be large. |
| **GiST** | Data that overlaps or has a distance: ranges, geometry (PostGIS) | `&&` on ranges, `<->` nearest-neighbour, exclusion constraints such as "no overlapping bookings" | Also works with `pg_trgm`. Compared with GIN it is smaller and faster to update, but slower to search. |
| **BRIN** | Very large tables where the column follows insert order: log time, event time | Range filters on that column | Very small, often kilobytes for millions of rows. Useless when the values are scattered across the table. |
| **Hash** | Only `=` | `=` | Rarely better than B-tree, and it can't sort or serve ranges. Usually not worth it. |
| **SP-GiST** | IP addresses, points, text prefixes | Special cases | Rare in business applications. |

**Variations that matter more than the type.**

- **Composite** `(a, b, c)`:
  - It helps queries that filter on `a`, on `a, b`, or on `a, b, c`. It doesn't help a filter on `b` alone.
  - Order the columns: equality columns first, then the range column, then the sort column. For `WHERE store_id = ? AND status = ? AND created_at > ? ORDER BY created_at`, use `(store_id, status, created_at)`.
- **Partial:** `CREATE INDEX … WHERE status = 'pending'`. Small and fast when queries only ever read a small subset of rows.
- **Covering:** `CREATE INDEX … (customer_id) INCLUDE (total, created_at)`. The database can answer the query from the index alone (an index-only scan) without reading the table. This works best when vacuum keeps up.
- **Expression:** `CREATE INDEX … (lower(email))`. For queries that must use a function on the column. The query has to use exactly the same expression.
- **Unique:** enforces a rule, such as no duplicate emails, and also serves lookups.

**How to choose, step by step.**

1. **Take the slow query** and write down its `WHERE`, `JOIN ON` and `ORDER BY` columns and their operators.
2. **Operator → type.**
   - `=`, `<`, `>` or sorting → B-tree.
   - Contains, JSON, arrays or full text → GIN.
   - Overlap or nearest → GiST.
   - Very large table ordered by time → BRIN.
3. **Columns → order.** Equality first, then range, then sort.
4. **Only a small subset queried?** Make the index partial. Only a few columns returned? Consider `INCLUDE`.
5. **Check selectivity.** The planner usually won't use an index on a column where most rows share one value, such as `is_active = true` on 95% of rows. A partial index on the rare value can be used.
6. **Prove it.** Run `EXPLAIN (ANALYZE, BUFFERS)` before and after. If the plan doesn't use the index, or the time doesn't drop, remove the index.

**Costs.**

- Every index slows down every `INSERT` and `UPDATE` on the table, and uses disk.
- An index on a column that gets updated can stop PostgreSQL's cheaper in-place updates (HOT updates).
- Look for unused indexes: rows in `pg_stat_user_indexes` where `idx_scan = 0` over a long period.
- In production, use `CREATE INDEX CONCURRENTLY`, so writes to the table aren't blocked while the index builds.

</details>

---

### PERF-04. Which indexes did you use on the cancer platform, and why?

**Brief answer**
Mostly B-tree: a composite index for the patient timeline, a unique index for idempotent check-ins, and partial indexes for small, frequently read subsets such as pending reminders and the outbox. BRIN on the two very large tables partitioned by time. GIN on the flexible symptom JSON. GiST on the care-relationship time ranges, where the same index also blocks overlapping relationships. Every index exists for a named endpoint or job, because an index with no query behind it only slows writes on a 46-million-row table.

<details>
<summary><strong>Detailed answer</strong></summary>

**B-tree**

- **Patient timeline, newest first** (`GET /api/v1/timeline`): composite `(patient_id, timeline_at DESC)` on the five timeline tables. The index is already in the order the page needs, so each table reads only the first rows for one patient, with no sort. Keyset pagination continues from the last row instead of skipping rows with `OFFSET`.
- **Check-in ingest:** unique `(patient_id, recorded_for)` on `wellbeing_checkin`. MQTT delivers at least once, so a redelivered message matches the unique key, and `INSERT … ON CONFLICT DO UPDATE` rewrites the same row instead of adding a duplicate.
- **Clinician's patient list** (`GET /api/v1/patients`): partial `(care_team_id, patient_id)` on `care_relationship` `WHERE upper(valid_period) IS NULL`. The index holds only relationships with no end date, so it stays small and returns a team's current patients directly. Limit: time-limited relationships, such as emergency access, have an end date, so they are not in this index.
- **Due reminders** (Celery beat, every 60 s): partial `(scheduled_for)` `WHERE state = 'pending'`. The job runs every minute but needs only the few pending reminders, not the whole history, so it reads a small index.
- **Outbox relay:** partial `(occurred_at)` `WHERE published_at IS NULL`. The relay reads only unpublished events, oldest first. A published row no longer matches the index condition, so the index stays small.
- **Hospital sync lookup by MRN:** an equality match on the HMAC blind-index column stored next to the encrypted `external_mrn`. The service finds the patient without decrypting anything, and decrypts only the matched row. The design doesn't name the index type; for an equality lookup a B-tree is the natural choice.

**How row-level security uses the patient index.** The policies are written as `patient_id = ANY (ARRAY(SELECT …))`, so the patient scope becomes an index condition. The same check written as `patient_id IN (SELECT …)`, or inside a function, runs as a filter, and the query reads every row of each partition it touches. The result is correct either way, so an `EXPLAIN` assertion in the tests checks the plan shape.

**BRIN**

- **Check-ins over a date window** (46 million rows): monthly range partitions on `recorded_for`, plus BRIN on `recorded_at`. Rows arrive in time order, so their physical order matches the time column. BRIN stores only a minimum and maximum per block range, so it costs a fraction of a B-tree's size for the same range scan. Limit: for queries on `recorded_for`, partition pruning already does most of the work, and the upsert rewrites rows, which can weaken the physical order BRIN depends on.
- **Audit trail** (1.8 billion rows, append-only): monthly partitions on `occurred_at`, plus BRIN on the time column. Rows are never updated, so physical order follows time exactly, which is the best case for BRIN.

**GIN**

- **Symptom data** (`GET /api/v1/patients/{patient_id}/checkin-trend`): GIN on `symptom_scores jsonb`. The symptom set differs by cancer type and changes with the clinical protocol, so symptoms are stored in one JSON document, not in columns. GIN indexes every key in the document, so a query can filter by symptom (`@>`, `?`) without a new column or a migration per symptom. Limit: GIN finds rows by what the document contains. It doesn't speed up reading score values over a time window, so the trend query finds its rows by patient and date.

**GiST**

- **"May this clinician see this patient"**, on every clinician request: GiST on `care_relationship (patient_id, clinician_id, valid_period)`, with the `btree_gist` extension because the index mixes plain columns with a `tstzrange`. GiST supports range operators, so "is there a relationship valid now" is one index lookup. The same index enforces an exclusion constraint, so two overlapping relationships for the same clinician and patient can't exist. Row-level security joins through this table.

**MongoDB (`mongo-content`)**

- **`content_pages`, unique `{page_id: 1, version: -1}`:** returns the newest version of a page first, and stops two documents having the same version. Approved versions never change, so reads never wait for a writer.
- **`content_pages`, `{diagnosis_code: 1, treatment_line: 1, locale: 1, review_state: 1}`:** finds the pages for one diagnosis, treatment line, language and review state in one index lookup.
- **`guidance_sources`, unique `{source_id: 1, passage_id: 1}`:** looks up a cited passage directly, and stops duplicate passages. **`{retired_at: 1}`** separates current passages from retired ones.

**Not used:** expression indexes, covering indexes (`INCLUDE`) and Hash indexes (PERF-03).

</details>

---

### PERF-05. What is the N+1 problem, and how do you avoid it from the start of development? Show an example in SQLAlchemy.

**Brief answer**
N+1 means one query loads a list, and then the code runs one more query for each item in the list. 50 products with their variants become 51 queries instead of 2. The code looks innocent, because the extra queries are hidden behind a normal attribute access. To avoid it from day one, load everything the response needs in the query itself, make lazy loading raise an error, and add a test that counts the queries.

<details>
<summary><strong>Detailed answer</strong></summary>

**What it looks like.** In SQLAlchemy, a `Product` model has a `brand` relationship and a `variants` relationship. The list endpoint selects 50 products, and then the response reads `product.variants` for each one. By default that relationship is loaded lazily, so every access runs its own query. That's 1 query for the list and 50 more for the variants. With 3 test products in development it feels fast, so nobody notices. In production, the count grows with the data. Each query is fast, but together they are slow, and they also hold a database connection for the whole time.

**The fix: say in the query what you need.** Add loader options to the same `select(Product)`:

- **`selectinload(Product.variants)` for collections** (one-to-many, many-to-many). It runs one extra query that loads the variants for all 50 products together, with `WHERE product_id IN (...)`, and it doesn't multiply rows.
- **`joinedload(Product.brand)` for a single related object** (many-to-one). The brand comes in the same query, through a join.

That's 2 queries in total, whether the page shows 50 products or 5,000.
**How to avoid it from the start.**

1. **Make lazy loading raise, from the first model.** Set `relationship(lazy="raise")` on every relationship, or add `raiseload("*")` to queries. Then `product.variants` without an eager load raises an error in development instead of running a hidden query. A forgotten eager load becomes a failing test, not a slow page later. With an `AsyncSession`, a hidden lazy load raises anyway (PY-04), but the error message is less clear, so set it explicitly.
2. **Each repository function loads exactly what its response needs.** The function that serves the product list declares its eager loads in one place. The response schema then only reads data that's already loaded, and a Pydantic model with `from_attributes=True` can't start queries by accident.
3. **For read-only lists, don't load ORM objects at all.** Select only the columns the page shows, with a join or an aggregate, for example `func.count(Variant.id)` grouped by product. There are no relationships left to load lazily.
4. **Make the query count visible while you work.** A statement counter per request in the development log (PERF-02, step 2) shows "51 queries" straight away.
5. **Test the query count on list endpoints.** The fixture must have several items with several children each, or an N+1 and the fixed version give the same count (DB-15).

**The same problem outside the database.** A cache lookup or an HTTP call per item in a loop is the same N+1. Use a multi-get or a batch endpoint (DB-15).

</details>

---

## Module boundaries in a monolith

### MOD-01. How do you define and keep boundaries in a modular monolith?

**Brief answer**
Define each module by the business facts it owns, not by technical layers. Each module gets its own package, its own database schema and a small public interface, and everything else stays private. Then keep the boundaries with checks that fail the build, not with a team agreement: import rules for the code, and a test for the SQL, because the import checker can't see SQL. On the cancer platform, `care-core` had four modules, and both checks blocked the pipeline.

<details>
<summary><strong>Detailed answer</strong></summary>

**1. Define the boundaries by ownership.**

- **One owner per fact.** For each table and each business rule, ask which module owns it. Only that module writes it, and the other modules ask the owner.
- **Split where the rules differ, not where the names differ.** In `care-core`, `records` (appointments, prescriptions, visit notes) is a separate module from `clinical-content` (education pages), because the clinical record has different consistency and audit rules. A prescription and a leaflet shouldn't share one code path.
- **Things that change together stay together.** If two parts almost always change in the same pull request, keep them in one module. A boundary between them only adds work.

**2. Give each module a clear shape.**

- **Its own package and its own schema.** In `care-core` there are four packages (`diary`, `records`, `clinical-content`, `identity`) and one PostgreSQL schema for each. So the boundary exists in the database too, not only in the code.
- **A small published interface.** Other modules call only this interface, in-process. The models, repositories and helpers behind it are private.
- **Events for reactions.** When other parts only need to react to a change, the owner writes an event to the outbox in the same transaction and publishes it to `care.events`. The owner then doesn't need to know who reacts. The outbox and its consumers are ARCH-05.
- **One deliberate exception, written down.** The `audit` schema belongs to no module, and every module appends to it. It is named as a shared append-only target, so nobody reads it as a gap in the rules.

**3. Keep the boundaries with checks that fail the build.**

- **Import contracts.** `import-linter` contracts are in the repository and declare the four modules independent of each other. An import that goes around the published interface fails the build. The check runs next to `ruff` and takes seconds.
- **No exceptions list.** The contracts use no `ignore_imports`. `care-core` was a new project, and we wrote the contracts together with the first module, so there was never a list of old violations to allow.
- **A test for the SQL.** An import checker can't see raw SQL. So each module's SQLAlchemy metadata is bound to its own schema, and an integration test fails a module that runs SQL against a schema it doesn't own. We chose this test instead of separate database permissions for each module.
- **A check that the check still works.** The pipeline includes one deliberate cross-module import that must fail. After a package rename, a contract can silently stop matching anything and pass every time. With this fixture, a broken contract fails loudly instead.

**4. When the boundaries have already broken down.** Our project didn't have this problem, but for an existing codebase I would do it in this order:

1. **Draw the target modules first,** by ownership as in step 1. Then run the import checker once to measure the real dependencies.
2. **Record today's violations as a baseline,** and make the check block every new one from the first day. Fixing the old ones can wait; stopping new ones can't.
3. **Remove the baseline step by step,** module by module. Start with the module that changes most often, because that's where the coupling costs most.
4. **Treat a deleted baseline entry as done,** and never add a new one without review.

A check that everyone can run and that fails the build is the answer to "every developer has their own style". The rule is the same for everyone, and nobody has to act as the police in code review.

**Signs that a boundary is in the wrong place.** One feature often needs changes in several modules, or a module keeps needing another module's tables. Then move the boundary or merge the modules, and don't just add another exception. The same test for services is ARCH-04. Moving a module out into its own service is a separate decision, made for deployment reasons such as release timing or hardware (ARCH-05). A clear boundary alone isn't a reason.

</details>

---

## API design

### APD-01. What do you keep in mind to build a reliable, well-shaped API?

**Brief answer**
I want a client developer to guess how the API works without asking me. So the contract is generated from code and tested, and every endpoint follows the same rules for naming, pagination and errors. Status codes tell the truth, and errors are machine-readable. Every write is safe to retry, every list is limited, and changes never break an old client. On the cancer platform, all of this ran through FastAPI and Pydantic, with the OpenAPI document tested in CI.

<details>
<summary><strong>Detailed answer</strong></summary>

The full reasoning and the examples from both projects are in API-01. This is the checklist I go through, in the order I'd say it.

**1. Shape: make it predictable.**

- **Resources are nouns, and the HTTP method is the verb.** For example `GET /api/v1/patients/{patient_id}/timeline` and `POST /api/v1/patients/{patient_id}/visit-notes`. A state change that isn't a simple edit, such as cancelling an order, is its own action, not a `status` field that anyone can patch (API-05).
- **One style everywhere.** The same naming, the same ID format, dates in ISO 8601 with a time zone, and the same error body on every endpoint. A client developer learns it once.
- **Contract first.** Agree the Pydantic models and publish the generated OpenAPI document as a draft before building, so the front end can start against a stub (API-06).

**2. Honest responses.**

- **Status codes mean something.** `201` for a create, `202` when the work really continues in the background, `409` for a conflict, `422` for invalid input, `503` when a retry makes sense (API-01). `401` and `403` are different things (API-03).
- **Errors a program can read.** RFC 9457 problem details: a stable `type` the client can check, a message for people, and errors per field. Never a stack trace or a database message in the response.
- **Long work doesn't hold the connection.** Return `202` with a status URL, as the cancer platform does for page generation, instead of making the client wait 45 seconds.

**3. Reliability.**

- **Every write is safe to retry.** A client that times out can't know if the request arrived, so it sends it again. An `Idempotency-Key` makes the second call return the first result, and a unique constraint in the database is the real guarantee (API-08). The cancer platform requires the key on all `POST` requests.
- **Concurrent edits don't overwrite each other.** Use `ETag` with `If-Match`, and return `412` when the version has changed (API-05).
- **Bulk endpoints decide one thing first:** all or nothing, or per item. A partial result reports a status for each item (API-07).

**4. Limits.**

- **Every list is paginated, with a cursor.** Offset pagination gets slower on deep pages, and the check-in table has 46 million rows (DB-11).
- **Every input has a limit:** body size, list length, page size and filter count. An API with no limits lets one client cause an outage.
- **Rate limits per user, not only per IP.** On the cancer platform, API Management applies a coarse limit, and `care-core` applies a stricter token bucket in Redis for login, search and document download. A whole hospital can sit behind one IP address, so limiting by IP alone would block the whole hospital. Return `429` with `Retry-After`, so good clients know when to try again.

**5. Changes over time.**

- **The major version in the path** (`/api/v1`), and inside a version, only additive changes: new optional fields and new endpoints, never a renamed field or a changed meaning (API-04).
- **Test compatibility, don't judge it by eye.** A contract test in the pipeline checks that an old client's requests still work and its responses still parse.
- **Announce removals.** Mark deprecated fields in the OpenAPI document, give a date, and watch the logs until nobody calls the old version.

**6. Security and observability.**

- **Check access to the resource, not only to the route.** "Is this a clinician" isn't enough; the question is "may this clinician see this patient" (PERM-01).
- **Make every call traceable.** Return a request ID, and pass the `traceparent` header on, so a client can say which call failed, not just "it was slow yesterday".

</details>

---

## Database migrations

### MIG-01. How do you organise backward-compatible database migrations?

**Brief answer**
One rule: every migration must work with the application version that is already running. So a breaking change is split into small steps across several releases: first add the new shape, then move the code and the data to it, and only later remove the old shape. That's called expand and contract. Then the old and new versions can run side by side during a deploy, and a rollback is just a redeploy of the previous image, with no down-migration. On the cancer platform, Alembic ran the migrations as an ArgoCD PreSync hook before the blue-green switch.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the rule exists.** During any rolling or blue-green deploy, the old and the new code run against the same database for a while. The migration runs first, so the old code must survive the new schema. If the rule holds, a rollback only changes the code, and the schema stays where it is (DB-21, INF-13).

**Example: renaming `product.name` to `product.display_name`.** A plain rename breaks the running version immediately. Split into releases, it looks like this:

1. **Release 1, expand.** Add `display_name` as a nullable column. The old code doesn't know it exists, so nothing breaks.
2. **Release 2, write both.** The new code writes both columns and still reads `name`. A batched background job copies old values into `display_name`, in small transactions, not one huge `UPDATE`.
3. **Release 3, switch reads.** The code reads `display_name`. `name` is still written, so a rollback to release 2 is still safe.
4. **Release 4, contract.** The code stops writing `name`. A later migration drops the column and adds `NOT NULL` to `display_name` if needed.

The detail of each step, and which operations lock a table, is DB-17.

**How I organise it in the team.**

- **Migrations live in the repository, next to the code,** with one migration tool, here Alembic. They run automatically in the pipeline before the rollout, never by hand from a laptop.
- **One change, one small migration.** Never mix an expand and a contract in one release. The contract step goes in a later merge request, so it can be reverted on its own.
- **Always review an autogenerated migration.** Alembic can see a renamed column as a drop plus an add, which deletes the data. Read what it generated before merging it.
- **One linear history.** Two branches that both add a migration create two Alembic heads. The pipeline fails on more than one head, and the developer merges them before the release.
- **No down-migrations as the rollback plan.** They are almost never tested, and they can't bring back deleted data. Rollback means redeploying the previous image (DB-21).
- **Test compatibility in the pipeline.** Run the migration against a production-sized copy to see how long it takes and what it locks, and run the previous version's tests against the new schema.
- **Safe defaults in every migration session:** a short `lock_timeout` with retries, indexes created `CONCURRENTLY`, and constraints added as `NOT VALID` and validated later (DB-17).
- **A reviewer checks every migration before release,** for locks, the size of any data update, and whether the previous image still runs (DB-18).
- **Record what's still open.** After an expand, write down which contract step is still waiting, so old columns don't stay forever.

**If a migration fails halfway,** first check what was really applied, stop the deploy, and then choose between rolling forward and rolling back (DB-20).

</details>

---

## Events and consistency

### EVT-01. How do you keep data consistent between services, for example when RabbitMQ is in place?

**Brief answer**
There's no single transaction across services, so I don't try to fake one. First I decide what really must change together; that stays inside one service and one database transaction. Everything else is eventually consistent, and I make sure "eventually" really happens. Each service owns its data. It saves the change and the event in the same transaction with an outbox, RabbitMQ delivers the event at least once, and every consumer is idempotent, so a duplicate does no harm. Failed messages go to a dead-letter queue, and a lag metric shows when things fall behind. A process across several services is a saga with compensating steps.

<details>
<summary><strong>Detailed answer</strong></summary>

**An example from the cancer platform.** A clinician saves a visit note. `care-core` writes the note and an `outbox_event` row in one PostgreSQL transaction. A relay publishes `visitnote.created` to the `care.events` topic exchange, and a Celery consumer indexes the note in Elasticsearch. If RabbitMQ is down, the note is still saved, and the event waits in the outbox. If the consumer crashes, the message is delivered again, and indexing the same note twice gives the same result. The note is searchable within 15 seconds at p95, and it is never lost.

**How I organise it, step by step.**

1. **Decide where you need strong consistency.** A lost prescription can't be fixed later; a search result that is a few seconds old can. Data that must change atomically stays in one service and one transaction. If two services always need one transaction, the boundary is probably in the wrong place (ARCH-03, ARCH-05).
2. **One owner per piece of data.** Only the owning service writes it. Other services get events or call its API, and never write to its tables.
3. **Never write to the database and the broker separately.** If the commit works and the publish fails, or the other way round, the two sides disagree forever. The outbox saves the event in the same transaction, and a relay publishes it afterwards (MSG-03, MSG-04).
4. **Make RabbitMQ keep what it accepted.** Quorum queues, persistent messages and publisher confirms, so the relay marks an event as published only after the broker has confirmed it. Consumers acknowledge a message only after their own transaction has committed (MSG-05, MSG-08).
5. **Make every consumer idempotent.** At-least-once delivery means duplicates are normal. Use a natural key or a unique constraint, like the check-in's `(patient_id, recorded_for)`, or record processed event IDs in the same transaction as the change. A Redis key can make this faster, but it isn't the guarantee (MSG-02).
6. **Don't rely on message order.** With retries and several consumers, an older event can arrive after a newer one. Put a version or a timestamp in the event and ignore anything older than what you already have, or let the consumer read the current state from the owner.
7. **Publish facts, not commands.** `visitnote.created` says what happened, and the publisher doesn't need to know who listens. Keep the payload small and add an event ID and a schema version (MSG-07).
8. **Plan for messages that keep failing.** A few retries with backoff, then a dead-letter queue with an alert, and a way to replay messages after the fix. One bad message must not block the queue (MSG-01).
9. **A business process across services is a saga.** Each step commits locally and has a compensating step, for example a credit instead of deleting a charge. If a compensating step fails, retry it; if it can't be done automatically, a person has to decide (ARCH-06).
10. **Watch for drift, and repair it.** An `outbox_lag` alert shows when events stop flowing. For data that can't be allowed to drift, a scheduled job compares both sides and fixes the differences. On the cancer platform, reminders stay `pending` in PostgreSQL until they are sent, so a broker outage makes them late, not lost.

</details>

---

### EVT-02. Explain the outbox pattern.

**Brief answer**
The outbox pattern solves one problem: saving data and sending a message about it can't be one transaction, so one of them can fail. With an outbox, the service doesn't send the message directly. It saves the event as a row in an outbox table, in the same database transaction as the business change. A separate relay then reads the new rows, publishes them to the broker, and marks them as published. So either the change and its event are both saved, or neither is, and every saved event is published at least once.

<details>
<summary><strong>Detailed answer</strong></summary>

**The problem: a dual write.** A service saves a visit note to PostgreSQL and then publishes `visitnote.created` to RabbitMQ. These are two systems, so there are two ways to fail:

- **The commit works, the publish fails.** The broker is down, or the process crashes between the two steps. The note exists, but search never hears about it.
- **The publish works, the commit fails.** Consumers react to a note that doesn't exist.

Retrying doesn't fully fix this, because the process can crash at any moment between the two steps. The outbox removes the gap.

**How it works.**

1. **Write.** In one transaction, insert the visit note and an `outbox_event` row with the event ID, the type, the entity ID, a small JSON payload, the time, and an empty `published_at`.
2. **Relay.** A background process regularly selects rows where `published_at` is empty, oldest first, and publishes them to the `care.events` exchange.
3. **Confirm.** The relay waits for RabbitMQ's publisher confirm, and only then sets `published_at`.
4. **Consume.** Consumers process the event. Because it can arrive twice, each consumer is idempotent.
5. **Clean up.** Published rows are deleted or archived after a while, so the table doesn't grow forever.

**Why a message can arrive twice.** The relay can publish a row and crash before it marks it as published. After a restart, it publishes the same row again. That's why the outbox gives at-least-once delivery, not exactly-once, and why consumers must handle duplicates.

**What it gives and what it doesn't.**

- **Gives:** a change and its event are never out of step, and events survive a broker outage, because they wait in the database.
- **Doesn't give:** exactly-once delivery, a global order, or proof that a consumer succeeded. It also adds a few seconds of delay.

**On the cancer platform.** Every write in `care-core` that other parts need to know about goes through `outbox_event` in `pg-clinical`, and nothing writes to Elasticsearch or Service Bus directly. A partial index on unpublished rows keeps the relay's query small. The relay publishes within about 2 seconds, and a note is searchable within 15 seconds at p95. An alert fires when the oldest unpublished event is older than 30 seconds for 5 minutes, because a stopped relay produces no errors, only silence.

**Going deeper.** Why the relay must not track "the last ID I published", how to run several relays with `FOR UPDATE SKIP LOCKED`, what the pattern costs, and change data capture as the alternative are all in MSG-04.

</details>
