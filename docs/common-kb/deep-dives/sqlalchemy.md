# SQLAlchemy: when queries run and what stays in memory

SQLAlchemy 2.0. The examples use one small domain throughout: a `Patient` with collections `checkins` and `prescriptions`, and an `Appointment` with a many-to-one `patient`.

A free-form deep dive beneath two survey topics that stay framework-neutral: [N+1 in `DBs.md`](../DBs.md#4-the-n1-problem) and [ORM behaviour in `Python-applications.md`](../Python-applications.md#8-orm-behaviour). Those own the recall-level answer; this file owns the SQLAlchemy mechanics.

## Contents

- [The mental model](#the-mental-model)
- [The identity map](#the-identity-map)
  - [Where it is used](#where-it-is-used)
  - [What it keeps alive](#what-it-keeps-alive)
  - [What it is not](#what-it-is-not)
- [Lazy loading and N+1](#lazy-loading-and-n1)
- [`joinedload` vs `selectinload`](#joinedload-vs-selectinload)
  - [Join type, `.unique()` and filtering](#join-type-unique-and-filtering)
- [Session scope](#session-scope)
  - [Several transactions in one session](#several-transactions-in-one-session)
- [Detached objects and `expire_on_commit`](#detached-objects-and-expire_on_commit)
- [Reading large results](#reading-large-results)
  - [Execute vs fetch](#execute-vs-fetch)
- [Bulk writes](#bulk-writes)
- [Connection pool sizing](#connection-pool-sizing)
- [Guarding against N+1](#guarding-against-n1)
  - [1. Make unplanned lazy loads fail](#1-make-unplanned-lazy-loads-fail)
  - [2. Assert the query count is constant as data grows](#2-assert-the-query-count-is-constant-as-data-grows)
  - [3. Watch query spans per request in traces](#3-watch-query-spans-per-request-in-traces)
  - [Counting vs query plans](#counting-vs-query-plans)

## The mental model

An ORM object looks like plain Python data. It is a copy of a row that remembers which session it came from and which of its fields have not been loaded yet.

SQLAlchemy sends a query at two moments: when you execute a statement, and when you touch an attribute that is not loaded yet (lazy loading).

The session tracks every object it loaded (the identity map), but keeps alive only the ones with pending work. Rows you only read stay in memory because your own code holds them, such as the list `.all()` returns.

Almost every problem below reduces to one question about a line of code: is the data already in memory, and is the session still open? Answer that, and N+1, memory blow-ups and `DetachedInstanceError` are predictable before the code runs.

## The identity map

A structure owned by the session, not part of each object. The link runs both ways:

- **Session side:** `session.identity_map` is dictionary-like. The key is the class, the primary key and an identity token (usually `None`), e.g. `(Patient, (42,), None)`. The value is the Python object for that row.
- **Object side:** each object's hidden state records its own key and its session. That is how a lazy load knows which session to query through, and why `DetachedInstanceError` appears once that session is gone.

The rule it enforces: inside one session, one row is always the same Python object.

```python
a = session.get(Patient, 42)
b = session.scalars(select(Patient).where(Patient.id == 42)).one()
assert a is b
```

### Where it is used

1. **Building objects from results.** For each row, SQLAlchemy builds the key and looks it up. An object already in the map is returned as is: attributes it already loaded are **not** overwritten, even if the row changed in the database; only expired or unloaded attributes are filled in. Force a refresh with `.execution_options(populate_existing=True)`.
2. **`session.get()`** checks the map first. If the object is there and not expired, no SQL is sent. A `select()` always sends SQL.
3. **Lazy loading a many-to-one** (`checkin.patient`): if the target is already in the map, no query runs. Collections (`patient.checkins`) always query, because the map cannot know whether it holds all the children.
4. **`flush()`** writes the new, changed and deleted objects. It also runs automatically before every query (autoflush, on by default), so unflushed edits reach the database before a `SELECT` that might read them.
5. **`commit()`** expires every object by default (`expire_on_commit=True`), so the next attribute read reloads it; `rollback()` expires them too. **`close()`** empties the map and detaches the objects.

### What it keeps alive

The map holds weak references. It keeps an object alive only while it has pending work — added via `session.add()`, changed, or marked for deletion — and only until the next flush.

- On a big read, memory comes from your own references, above all the list `.all()` returns.
- On a big write, memory comes from new objects waiting for a flush; the larger cost is per-object bookkeeping.

In short: the session holds what you changed; `.all()` holds what you read.

### What it is not

Not a cache shared across requests, workers or processes. It lives and dies with one session. A long-lived session keeps returning the version of a row it loaded first (rule 1), so another transaction's update stays invisible until the object is expired.

## Lazy loading and N+1

**Mechanism.** Related objects are not loaded by default. `patient.checkins` is a query waiting to run on first access. Cheap for one object; inside a loop it runs once per item.

```python
patients = session.scalars(select(Patient).where(Patient.team_id == team_id)).all()
for p in patients:
    out.append({"name": p.name, "checkins": len(p.checkins)})  # one SELECT per patient
```

One query for the list plus one per patient: 200 patients, 201 queries.

**Symptoms.**

- Fast with 3 test rows, slow with 200.
- Database CPU low, each query about a millisecond, so the database or network gets blamed.
- A trace shows the same `SELECT ... WHERE patient_id = ?` repeated hundreds of times.
- Response time grows linearly with list length.

**Where it hides.** Often not in your loop. Serialisers such as Pydantic with `from_attributes` touch every attribute in the response schema, so the N+1 happens after the handler returns.

**Async.** Under `AsyncSession`, the same attribute access does not query; it raises `MissingGreenlet`.

**Fix.** Declare what you need at query time:

```python
select(Patient).where(...).options(selectinload(Patient.checkins))
```

Two queries in total, whatever the list size.

**When the fix is wrong.**

1. **Eager loading on the model** (`lazy="selectin"` on the relationship) makes every query for `Patient` pull its check-ins, including everywhere they are unused. Choose the loading strategy per query, not per model.
2. **Only a number is needed.** One `func.count()` with `GROUP BY` returns 200 rows of name and count instead of 200 patients plus thousands of child objects. Aggregate; don't eager-load.

## `joinedload` vs `selectinload`

**Mechanism.**

- **`joinedload`** sends one query with a `LEFT OUTER JOIN`. One row per parent–child pair, so parent columns repeat on every child row. For a collection, SQLAlchemy 2.0 requires `.unique()` on the result.
- **`selectinload`** sends a second query for all children, with no parent columns repeated. Large parent lists are split into batches of 500.

```sql
SELECT ... FROM checkin WHERE patient_id IN (1, 2, ..., 200)
```

**Failure: rows multiply (cartesian blow-up).**

```python
.options(joinedload(Patient.checkins), joinedload(Patient.prescriptions))
```

200 patients × 90 check-ins × 10 prescriptions = 180,000 rows for about 20,000 rows of real data. Two collections joined to the same parent multiply, they don't add.

**Symptoms.**

- `EXPLAIN` looks fine: the joins use indexed foreign keys.
- The response is slow, a lot of data crosses the network, and process memory jumps per request — under a fixed memory limit, an OOM kill from a query defect.
- A second `joinedload` added "to fix N+1" makes the page ten times slower.

**Default.**

- Collections (one-to-many, many-to-many): `selectinload`. One extra query per collection.
- Single related object (many-to-one): `joinedload`. Nothing multiplies, one round trip.

**When `selectinload` is wrong.**

1. **One parent, small collection** (a detail page). The blow-up is negligible and `joinedload` saves a round trip — more valuable when each round trip has real latency.
2. **A huge parent list** (50,000 parents, 100 `IN` batches). The strategy is not the problem; loading 50,000 objects at once is. Stream instead.

### Join type, `.unique()` and filtering

- `joinedload` is an outer join by default, so a parent with no children still comes back with an empty collection. Eager loading must never change which parents a query returns.
- `.unique()` is not SQL and does not change the join. It de-duplicates in Python: 90 rows for patient 42 become the same object via the identity map, and without `.unique()` the list would hold it 90 times. Required only when `joinedload` loads a collection.
- An `INNER JOIN` comes from a loader flag: `joinedload(Checkin.patient, innerjoin=True)`. Safe on a many-to-one with a non-nullable foreign key; wrong on a collection, where it silently drops every parent without children.
- You cannot filter through a `joinedload`: its join uses an anonymous alias, so `.where(Checkin.mood < 3)` does not touch the loaded collection. It adds `checkin` as a second, unjoined table instead, and SQLAlchemy warns about a cartesian product. Write the join yourself and fill the collection from it:

```python
stmt = (
    select(Patient)
    .join(Patient.checkins)
    .where(Checkin.mood < 3)
    .options(contains_eager(Patient.checkins))
    .execution_options(populate_existing=True)
)
patients = session.scalars(stmt).unique().all()
```

- Rows still repeat the parent, so call `.unique()`, as with `joinedload`.
- `populate_existing` is needed because of identity-map rule 1: a parent already loaded with its full collection keeps it unless told to overwrite.
- The reverse trap: once filled, the collection holds only the filtered children, and later code in the same session reads it as complete.

Rule of thumb: `joinedload` is for loading, `.join()` is for filtering, `contains_eager` connects the two.

## Session scope

**Mechanism.** A session is one unit of work: the identity map, the pending changes and — once the first query runs — a connection with an open transaction. It is not safe to share between threads or concurrent tasks. Scope it to one unit of work, which in a web app is one request:

```python
def get_session():
    with SessionLocal() as session, session.begin():  # commit on success, rollback on exception
        yield session
```

**Failure: a module-level session** (`session = SessionLocal()` at import time).

- One flush fails on a constraint violation; from then on every use of that session raises `PendingRollbackError`, because nobody rolled the failed transaction back.
- Concurrent use raises `IllegalStateChangeError` or driver errors (threads on a `Session`), or `InvalidRequestError` about concurrent operations (tasks on an `AsyncSession`).
- Stale reads between commits: objects loaded earlier keep old values until something commits or rolls back. Read-only paths see it most.
- A connection sits idle in transaction, holding locks.

**Fix.** One session per request or per unit of work. ORM objects do not leave it: convert them to plain values or response models inside.

**When the fix is wrong.**

1. **Work outside the request** — background tasks, task queues, message consumers. Pass IDs, not objects; each task or message opens its own session.

   <span style="color:gray">Aside (FastAPI): from 0.106 to 0.117, cleanup after `yield` in a dependency runs before the response is sent, so a `BackgroundTasks` task sees a closed session and gets `DetachedInstanceError`. From 0.118 cleanup runs after the response is sent, so the task can run while the request's session is still open and its transaction uncommitted — for example, sending a confirmation for a row that may never commit.</span>
2. **A slow call inside the request** (an external HTTP or LLM call). Session-per-request keeps the connection checked out and the transaction open throughout, and concurrent requests exhaust the pool. Make the slow call before the first query, or commit and start a fresh transaction afterwards.

### Several transactions in one session

1. **Sequential.** `commit()` ends the transaction; the next query starts a new one (autobegin). The identity map carries on, with every object expired.

   ```python
   with SessionLocal() as session:
       with session.begin():   # transaction 1
           ...
       call_llm()              # no connection held, as long as no ORM object is read
       with session.begin():   # transaction 2
           ...
   ```

   Reading an ORM object between the blocks triggers autobegin, and the second `session.begin()` then raises. A session dependency that already wraps the request in `session.begin()` rules this pattern out; if an endpoint needs several transactions, the dependency only opens and closes the session and service code owns the `begin()` blocks.

2. **Nested: a savepoint.** `session.begin_nested()` emits `SAVEPOINT`; a failure inside rolls back only that part.

   ```python
   for item in batch:
       try:
           with session.begin_nested():
               session.add(Checkin(**item))
       except IntegrityError:
           skipped.append(item)
   session.commit()
   ```

   - A savepoint is not durable; nothing is permanent until the outer `commit()`.
   - On savepoint rollback, objects added inside are expunged and objects changed inside are expired.
   - Each savepoint flushes and adds round trips (`SAVEPOINT`, `RELEASE`). Fine for hundreds of rows, too slow for 100,000 — check duplicates in one query or use a conflict-skipping insert instead.
   - Dialect support varies; verify before relying on it.

3. **Independent: a second session.** For a write that must survive the main transaction's rollback, such as an audit record. It uses its own connection and commits separately.
   - Each request now takes two pool connections.
   - If both transactions touch the same rows, the second waits on a lock the first holds, and the request blocks itself.

A transaction boundary belongs where data must be consistent, not where the request ends.

## Detached objects and `expire_on_commit`

**Mechanism.** When its session closes, an object is detached. Loaded attributes remain readable; anything unloaded needs a query, and with no session SQLAlchemy raises `DetachedInstanceError`. Two kinds of attribute are unloaded:

- a lazy relationship never touched, such as `appointment.patient`;
- every attribute after a commit, since `commit()` expires all objects by default — even `appointment.id`.

```python
def create_appointment(data) -> Appointment:
    with SessionLocal.begin() as session:  # commits and closes on exit
        appointment = Appointment(**data)
        session.add(appointment)
    return appointment

appointment = create_appointment(data)
send_confirmation(appointment)  # reads appointment.patient.email → DetachedInstanceError
```

**Symptoms.**

- The row is committed but the request fails afterwards; a client retry creates a duplicate.
- The traceback points at the attribute read, far from where the session closed.
- Tests pass because the test fixture keeps one session open throughout.

**Two naive fixes and their cost.**

1. **`expire_on_commit=False` everywhere.**
   - Lazy relationships still raise, so the example above still fails.
   - Objects keep their commit-time values; concurrent changes are invisible without warning.
   - It is a global switch that changes every commit in the codebase.
2. **`lazy="joined"` on the model.** The relationship is always present, but every query for that model now joins it — on collections, bringing back the row explosion. Per query, not per model.

**Fix.** Decide what leaves the session. Load exactly what is needed with explicit loader options, convert to plain values or response models inside the session, pass IDs to background work, and set `lazy="raise"` so a forgotten relationship fails in tests.

**When the standard answer is wrong.** With `AsyncSession`, `expire_on_commit=False` is SQLAlchemy's own recommendation: an expired attribute cannot reload without awaiting I/O, so it would fail anyway. Fine as a deliberate choice paired with explicit loading; not as a patch over detached access.

## Reading large results

**Mechanism.** Memory is held at three layers:

1. **Driver.** Most DBAPI drivers download the whole result set when the query executes, before the first row is read.
2. **ORM.** By default the ORM builds every object before returning the first.
3. **Your code.** `.all()` keeps all of them in a list.

Iterating instead of calling `.all()` fixes only layer 3.

### Execute vs fetch

- **Execute** (`cursor.execute(sql)`) sends the query and the database runs it.
- **Fetch** (`fetchone()`, `fetchmany(n)`, `fetchall()`) takes rows out of the result.

With a client-side cursor — the default in psycopg2, psycopg 3 and most drivers — `execute()` returns only once every row sits in driver memory; fetching one row just reads the local copy. With a server-side cursor, `execute()` opens a cursor on the database and each `fetchmany(n)` retrieves the next batch.

```python
result = session.scalars(select(VisitNote))  # execute: all rows in driver memory, all objects built
note = result.first()                        # fetch: one row from memory, the rest discarded
```

`.first()` without a `LIMIT` still downloads everything.

**Symptoms of loading everything.** A batch job is OOM-killed at about the same row count each run; memory climbs linearly, then drops to zero; it works on small staging data; raising the memory limit helps only until the data grows.

**Fix: stream columns in batches.**

```python
stmt = select(VisitNote.id, VisitNote.patient_id, VisitNote.body).execution_options(yield_per=1000)
for batch in session.execute(stmt).partitions():
    export([row._asdict() for row in batch])
```

- **Columns, not entities**, when you only export: plain rows, no identity map, no change tracking, no lazy loads. Removes layer 2.
- **`yield_per`** hands rows over in batches and sets `stream_results`, requesting a server-side cursor. Covers layer 1 — where the driver supports server-side cursors.
- **`.partitions()`** yields one batch at a time; nothing retains earlier batches. Covers layer 3.
- `yield_per` is incompatible with `joinedload` on a collection; `selectinload` works per batch.

**Cost of streaming.** A server-side cursor holds one connection and one transaction for the entire run: a pool connection taken, an old snapshot held, and a failure near the end restarts from zero. For long jobs, use keyset chunks, each in its own short transaction:

```sql
SELECT ... FROM visit_note WHERE id > :last_id ORDER BY id LIMIT 1000
```

Persist `last_id` after each chunk to resume. Avoid `OFFSET`: the database reads and discards every skipped row, so each page is slower than the last, and concurrent inserts shift pages so rows are skipped or repeated. A keyset over a non-unique sort column needs a unique tiebreaker in the cursor tuple.

**When streaming is wrong.**

1. **The data need not reach Python.** When source and destination are the same database, use `INSERT ... SELECT` or `UPDATE` in SQL. On a large table, chunk the statement by key range and commit each chunk, since one statement over millions of rows is one long transaction holding every row lock.
2. **Random page access** ("jump to page 37", total page count). Keyset cannot jump; `OFFSET` is fine for the first pages of a small list.

## Bulk writes

**Mechanism.** `session.add()` is built for a handful of objects. For each row it creates a tracked object, holds it until flush, and at flush the unit of work orders the inserts and fetches each generated primary key to populate `obj.id`.

In 2.0, dialects that support `RETURNING` batch these into multi-row `INSERT ... RETURNING` statements ("insertmanyvalues"). If a dialect cannot return keys and the database generates them, the ORM falls back to one `INSERT` per row. Client-set keys, such as UUIDs, are batched regardless.

```python
for row in rows:
    session.add(Product(**row))
session.commit()
```

**Symptoms, by dominant cost.**

- **Row-by-row inserts** (1.x, or the fallback): one network round trip per row — 20,000 rows at 5 ms is 100 s of waiting. Worker and database CPU both low; a trace shows 20,000 `INSERT` spans.
- **Object overhead** (batched path): 20,000 rows take seconds. At hundreds of thousands, worker CPU sits at 100% in Python, a profile shows time in flush and attribute instrumentation, and memory climbs until the single flush.
- **One huge transaction** holds row locks for its duration, blocking concurrent updates to the same rows.
- **The opposite mistake**, `commit()` per row, pays a durable write per row.

**Fix.** Pass dictionaries, not objects, in committed chunks, and make each chunk idempotent:

```python
for chunk in batched(rows, 1000):  # itertools.batched, Python 3.12+
    session.execute(insert(Product), list(chunk))  # ORM bulk INSERT: no objects, no identity map
    session.commit()
```

- Use an upsert on a natural key (on PostgreSQL, `insert()` from `sqlalchemy.dialects.postgresql` with `on_conflict_do_update`) so a retried chunk does not duplicate rows.
- `bulk_insert_mappings` is the legacy 1.x API for the same idea; on 2.0 use `insert()` with a list of dicts.
- For millions of rows, a database-native bulk load (PostgreSQL `COPY`) is faster again — use it once measured.

**When the fix is wrong.**

1. **You rely on ORM behaviour.** No objects are created, so `@validates`, `before_insert` listeners and relationship cascades do not run. Validation or audit logic in ORM events is skipped silently.
2. **You need all-or-nothing.** Chunked commits can leave a load half-applied. Rather than one giant transaction, validate everything first (for example in a staging table), then promote in chunks.
3. **A few dozen rows.** `add_all()` is fine.

## Connection pool sizing

**Mechanism.** Each process that creates an engine has its own pool; pools are not shared across processes. Defaults: `pool_size=5`, `max_overflow=10`, so up to 15 connections per process. When all are checked out, the next checkout waits up to `pool_timeout` (30 s) and then raises `QueuePool limit of size 5 overflow 10 reached, connection timed out`.

The real total is a multiplication:

```
(pool_size + max_overflow) × processes per host or pod × hosts or pods
```

summed over every deployment using the database — API, workers, scheduled jobs, migrations. For example, 48 processes × 15 = 720 potential connections against a database allowing 300.

**Two symptoms that look alike.**

1. **Pool too small for in-process concurrency.** A sync endpoint served from a 40-thread pool with 15 connections leaves 25 threads queued.
   - Latency rises while database CPU stays low.
   - Traces show a gap before the first query span: time waiting for a connection.
   - Sessions that are never closed drain the pool the same way, slowly; a restart "fixes" it.
2. **Total too large for the database.** Autoscaling adds processes under load, each opening connections; the database refuses new ones and every instance fails. Scaling out deepens the outage.

**Fix.** Size backwards from the database's connection limit:

```
(300 − 30 reserved for admin and migrations) ÷ 48 processes at maximum scale ≈ 5 per process
```

```python
engine = create_engine(url, pool_size=5, max_overflow=0, pool_timeout=5)
```

- Size for the maximum instance count the autoscaler allows.
- Keep `max_overflow` low or zero so the total is predictable.
- Match in-process concurrency to the pool: five connections behind 40 threads means 35 threads queue, and with a 5-second timeout they fail. Lower the thread limit, or use more processes with fewer threads.
- Use a short `pool_timeout` so waiting fails fast and visibly.
- Monitor checked-out connections and checkout wait time.
- **Dead idle connections.** A proxy, firewall or the database closes connections idle past its timeout, and the pool does not know. The first query after a quiet period fails with "server closed the connection unexpectedly" — unlike the fork case below, it follows idle time, not load. `pool_pre_ping=True` tests each connection on checkout and replaces a dead one, at the cost of a small round trip per checkout; `pool_recycle=<seconds>`, set below the shortest idle timeout on the path, retires connections by age with no per-checkout cost.
- **Across `fork`,** create the engine in each child, or call `engine.dispose(close=False)` in the child. A connection inherited across a fork is used by two processes at once, surfacing as random `SSL error: decryption failed or bad record mac` or "server closed the connection unexpectedly".

**When the fix is wrong.**

1. **Raising the database's connection limit.** More connections than the database can serve concurrently slow it through contention. Fewer, busier connections win.
2. **An external pooler** (PgBouncer in transaction mode) lets many application connections share few real ones; use `NullPool` in the application and let the pooler pool. Transaction mode breaks connection-scoped state: `SET` values, advisory locks, and prepared statements unless PgBouncer is 1.21+ with `max_prepared_statements` set (otherwise, with the asyncpg dialect, set `prepared_statement_cache_size=0`).

   <span style="color:gray">Aside (PgBouncer): transaction mode hands out a server connection per transaction, not per client session, which is why state tied to a session does not survive from one transaction to the next. A managed database service may not offer an external pooler at all; check before planning on one.</span>

## Guarding against N+1

Count queries, don't time them. With small development data N+1 costs milliseconds and no timing test notices, and code review misses it when a serialiser does the touching. The number of queries does not depend on machine speed: 4 queries for 3 rows and 31 for 30 is visible on a laptop.

### 1. Make unplanned lazy loads fail

Batching and joining fix one query; neither stops the next attribute access from reintroducing the problem. Guards make a lazy load fail loudly instead:

- `raiseload("*")` as a query option — suits hot read paths.
- `lazy="raise"` on a relationship — every query of that model.
- `lazy="raise_on_sql"` — the milder model-wide default: allows a many-to-one load the identity map can satisfy without SQL, and raises only when SQL would be emitted.
- The raise strategies do not apply during a flush.

### 2. Assert the query count is constant as data grows

```python
@contextmanager
def count_queries(engine):
    counter = SimpleNamespace(value=0)
    def on_execute(*args):
        counter.value += 1
    event.listen(engine, "before_cursor_execute", on_execute)
    try:
        yield counter
    finally:
        event.remove(engine, "before_cursor_execute", on_execute)

def test_patient_list_query_count_is_constant(client, engine, make_patients):
    counts = []
    for size in (3, 30):
        make_patients(size)                # cumulative: 3, then 33
        client.get("/patients")            # warm-up, outside the count
        with count_queries(engine) as n:
            client.get("/patients")
        counts.append(n.value)
    assert counts[0] == counts[1]
```

- Compare counts across sizes rather than asserting a fixed number. `assert n == 4` breaks on the first harmless extra query, gets updated blindly, and stops testing anything.
- Watch it fail once: remove the `selectinload`, confirm red, restore. A query-count test that has never failed has not been shown to catch anything.
- Warm up first: one-time queries on the first connection would inflate the small-size count.
- Cover the few hot list endpoints, not every endpoint.

### 3. Watch query spans per request in traces

With SQLAlchemy instrumented by a tracing agent, a request showing hundreds of identical `SELECT` spans is N+1 caught before production.

### Counting vs query plans

- **Many fast queries** is an application problem — N+1 — found by counting.
- **One slow query** is a plan problem — a sequential scan, an unusable index — found with the database's plan tool (`EXPLAIN ANALYZE`), run against production-sized data and, for writes, inside a rolled-back transaction.

<span style="color:gray">Aside (database): `EXPLAIN ANALYZE` executes the statement for real, which is why writes need the rolled-back transaction. The planner's choice depends on data volume: a sequential scan over 1,000 rows is the correct plan and a bad one over 10 million, so a plan read on small data can look broken when it is fine. Other databases have their own plan output; the habit is the same.</span>
