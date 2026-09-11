# Fundamental Topics: Python Concurrency and Parallelism

**Table of Contents**

[Concurrency and Parallelism Topics](#concurrency-and-parallelism-topics)

- [1. Choosing Threads, Processes or asyncio](#1-choosing-threads-processes-or-asyncio)
- [2. The asyncio Event Loop](#2-the-asyncio-event-loop)
- [3. Blocking Calls Inside Async Code](#3-blocking-calls-inside-async-code)
- [4. gather, TaskGroup, Cancellation and Timeouts](#4-gather-taskgroup-cancellation-and-timeouts)
- [5. Thread Safety Primitives](#5-thread-safety-primitives)
- [6. Queue as the Channel Between Threads](#6-queue-as-the-channel-between-threads)
- [7. concurrent.futures Executors](#7-concurrentfutures-executors)
- [8. Multiprocessing Start Methods](#8-multiprocessing-start-methods)
- [9. Inter-Process Communication](#9-inter-process-communication)
- [10. Graceful Shutdown and Signals](#10-graceful-shutdown-and-signals)
- [11. Free-Threaded CPython and Subinterpreters](#11-free-threaded-cpython-and-subinterpreters)
**What this is.** The concurrency and parallelism topics a backend engineer is expected to reason about rather than recite, taken from one group of the list in `docs/tmp/common-kb/Python.txt`. That list is long enough to be five documents; the others are `Python-language.md`, `Python-data-structures.md`, `Python-typing-stdlib.md` and `Python-applications.md`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") is the concrete reference throughout, at a 3.12 baseline with later behaviour named where it differs, because every trade-off in this group follows from that implementation's interpreter lock and its process model rather than from anything in the language specification.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first, and bullets run the same way inside a topic. The first bullets of topic 1 are the ones you are most likely to be asked, and every later topic assumes the choice made there. The group is a single one in `Python.txt`, so the order runs from the decision, through the async model that dominates modern backend Python, to threads, processes and the shutdown behaviour that production depends on.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 44 MUST, 22 NICE and 11 OPTIONAL across 11 topics. Concurrency is where an interviewer expects the fundamentals to be firm before hearing about anything you have built, which is why two thirds of this list is probed directly rather than offered.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Concurrency and Parallelism Topics

## 1. Choosing Threads, Processes or asyncio

**Why it comes up:** it is the first concurrency question and the one every later answer depends on, because picking the model by habit rather than by workload is the mistake that cannot be recovered later.

- **MUST** — The three models in one sentence each

  <details><summary><strong>Answer</strong></summary>

  **Threads** share memory in one process and are pre-emptively scheduled, so they overlap blocking calls but do not run Python bytecode in parallel. **Processes** each have their own interpreter and memory, so they achieve real parallelism and pay for it in start-up cost and in serialising everything that crosses between them. **asyncio** is one thread running many coroutines that yield at explicit `await` points, so it overlaps I/O at a fraction of the per-task cost and does nothing for computation.

  The distinction underneath all three is concurrency against parallelism: making progress on several things by interleaving, against literally executing at the same instant. Threads and asyncio give the first; only processes give the second in a standard build.

  </details>

- **MUST** — The decision, by workload

  <details><summary><strong>Answer</strong></summary>

  I/O-bound with many concurrent operations, and libraries that support it: **asyncio**. I/O-bound but the libraries are blocking: **threads**, because rewriting a synchronous driver is not on the table. CPU-bound in Python: **processes**. CPU-bound already inside a compiled library that releases the interpreter lock: **threads**, because you keep shared memory and pay no serialisation.

  **The judgment being tested is** whether you name the workload before the tool. Saying "it depends on whether the hot path is Python bytecode, a blocking call, or a native call" is the answer; the tool follows from it mechanically.

  </details>

- **MUST** — What each one costs

  <details><summary><strong>Answer</strong></summary>

  A thread is roughly 8 MB of virtual stack and a context switch measured in microseconds, so a few hundred is comfortable and tens of thousands is not. A coroutine is a few hundred bytes and a switch is a function call, so tens of thousands are routine. A process is tens of megabytes and tens of milliseconds to start, plus pickling on every argument and every result.

  Those numbers are the whole reason the models exist separately. They also explain the common failure of each: thread-pool exhaustion, an event loop blocked by one bad call, and a process pool whose serialisation costs more than the work.

  </details>

- **MUST** — Mixing them deliberately

  <details><summary><strong>Answer</strong></summary>

  The production shape for a Python web service is usually several processes, each running one event loop, with a bounded thread pool inside each for the blocking calls that remain. Processes give core parallelism, the loop gives cheap I/O concurrency, and the thread pool is the escape hatch.

  That is exactly what a gunicorn-managed set of uvicorn workers is, which is worth saying out loud, because it shows the deployment and the concurrency model are the same decision seen from two ends.

  </details>

- **NICE** — Why the interpreter lock shapes all of this

  <details><summary><strong>Answer</strong></summary>

  Threads do not run Python bytecode in parallel because of the interpreter lock, which is what pushes CPU-bound work to processes and makes native libraries the exception. What the lock is, what it protects and what it does not serialise are covered in `Python-language.md`.

  The part that belongs here is the consequence: the concurrency model is chosen around that constraint, and in a free-threaded build the constraint changes.

  </details>

- **NICE** — Concurrency you did not write

  <details><summary><strong>Answer</strong></summary>

  A web framework already runs your handler concurrently, a database driver may hold a pool with its own threads, and a numeric library may start one thread per core. Reasoning about a service as single-threaded because your own code creates no threads is how oversubscription and shared-state bugs get in.

  </details>

- **OPTIONAL** — Green threads and the alternatives

  <details><summary><strong>Answer</strong></summary>

  `gevent` and `eventlet` monkey-patch the standard library so synchronous code yields at I/O, which was the pre-asyncio answer and still runs in production. The trade is that the yield points are invisible, so the reasoning advantage of explicit `await` is lost — which is precisely the argument that settled the language on asyncio.

  </details>

## 2. The asyncio Event Loop

**Why it comes up:** the difference between a coroutine, a task and a future is the check for whether async is understood as a scheduler or as a keyword.

- **MUST** — What the loop actually does

  <details><summary><strong>Answer</strong></summary>

  The **event loop** is a single-threaded scheduler around an operating-system readiness call such as `epoll`. It runs one callback at a time to completion, and when a coroutine hits an `await` that cannot complete immediately, the coroutine suspends and the loop picks the next ready one.

  Everything follows from "one at a time": there is no pre-emption, so a coroutine keeps the loop until it yields, and two coroutines never execute simultaneously. That is why most shared-state races cannot happen, and why one blocking call stops everything.

  </details>

- **MUST** — Coroutine, task and future

  <details><summary><strong>Answer</strong></summary>

  Calling an `async def` function returns a **coroutine** object and runs none of its body — the same property a generator has. `await`ing it runs it to completion inside the current task, sequentially. Wrapping it with `asyncio.create_task` schedules it on the loop as a **task**, which is what makes it run concurrently with the awaiting code.

  A **future** is the lower-level placeholder for a result that will arrive; a task is a future that wraps a coroutine. The mistake this distinction catches is `await fetch(a); await fetch(b)`, which is two sequential requests, against creating two tasks and awaiting both, which is one round trip's worth of time.

  </details>

- **MUST** — `await` points are where everything can change

  <details><summary><strong>Answer</strong></summary>

  Between two `await`s the code is effectively atomic, because nothing else on that loop can run. At an `await`, any other task may run and mutate whatever it can reach — so a read-modify-write that spans an `await` is a race even in single-threaded async code.

  This is the useful mental model: `await` is the only place a context switch happens, which makes async races both rarer and easier to find than threaded ones. Where one is genuinely possible, `asyncio.Lock` is the tool, and it is not interchangeable with `threading.Lock`.

  </details>

- **MUST** — Getting into and out of async code

  <details><summary><strong>Answer</strong></summary>

  `asyncio.run(main())` creates a loop, runs the coroutine and shuts the loop down; it is the entry point, and calling it twice or inside a running loop raises. From synchronous code inside a running loop, the bridge is `loop.call_soon_threadsafe` or `asyncio.run_coroutine_threadsafe` from another thread.

  Async is famously colour-sticky: an `async def` can only be awaited by another `async def`, so one async call at the bottom pulls the whole call chain with it. That is a design consequence worth naming rather than a flaw to work around with hidden `run` calls.

  </details>

- **NICE** — Forgetting to await, and losing a task

  <details><summary><strong>Answer</strong></summary>

  Calling a coroutine without awaiting it produces a coroutine object and a `RuntimeWarning: coroutine was never awaited` — a whole function silently never ran. A task created and not referenced can be garbage-collected mid-flight, which is why `asyncio.create_task` results should be held in a set, or created inside a task group that holds them.

  Both are silent failures rather than exceptions, which is what makes them worth naming.

  </details>

- **NICE** — Debug mode

  <details><summary><strong>Answer</strong></summary>

  `asyncio.run(main(), debug=True)` or `PYTHONASYNCIODEBUG=1` logs coroutines that were never awaited, callbacks that blocked the loop for longer than 100 ms, and exceptions that were never retrieved from a task. The slow-callback log line is usually the direct answer to "why is this service intermittently unresponsive".

  </details>

- **OPTIONAL** — Loop implementations

  <details><summary><strong>Answer</strong></summary>

  `uvloop` replaces the default loop with one built on libuv and is meaningfully faster at the socket layer, which is why uvicorn uses it where available. It changes no semantics, so it is a configuration choice rather than a design one.

  </details>

## 3. Blocking Calls Inside Async Code

**Why it comes up:** it is the single most common way a production async service fails, and the fix is a specific [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") rather than a principle.

- **MUST** — What one blocking call does

  <details><summary><strong>Answer</strong></summary>

  The loop runs one callback at a time, so a synchronous call that takes 200 ms stops **every** other request on that worker for 200 ms — not just the one making the call. Throughput collapses, latency percentiles spike, and health checks start failing, all from code that is correct in isolation.

  The usual culprits are `requests` instead of an async client, a synchronous database driver, `time.sleep`, a large `json.loads`, file I/O, and password hashing. None of them looks dangerous in review, which is why the symptom is so often diagnosed as "the server is slow" rather than as one call.

  </details>

- **MUST** — `run_in_executor` and `asyncio.to_thread`

  <details><summary><strong>Answer</strong></summary>

  `await asyncio.to_thread(blocking_fn, arg)` — or `loop.run_in_executor(None, fn, arg)` — hands the work to a thread pool and gives the loop back a future to await, so the loop stays responsive while the call blocks. It is the sanctioned escape hatch for a library with no async version.

  Two limits belong in the answer: the default pool is bounded, so enough concurrent blocking calls will queue behind each other, and CPU-bound work moved to a thread still contends for the interpreter lock, so it needs a `ProcessPoolExecutor` instead. The pool is a place to put waiting, not a place to put computation.

  </details>

- **MUST** — Finding the blocking call

  <details><summary><strong>Answer</strong></summary>

  Enable `asyncio` debug mode and read the slow-callback warnings; they name the coroutine that held the loop. `py-spy dump` against the running process shows where it is at that instant, which catches the case that is too rare to reproduce.

  The preventive version is a lint rule or a review habit: any import of a known-synchronous client in an async module is the defect, before any measurement is taken.

  </details>

- **MUST** — Async all the way down

  <details><summary><strong>Answer</strong></summary>

  An async service needs async drivers throughout: `httpx` or `aiohttp` rather than `requests`, `asyncpg` or [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries")'s async engine rather than a blocking one, `aiofiles` where file work is significant, and an async [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") client. Half-converting produces a service with all the complexity of async and the throughput of a thread pool.

  Where no async driver exists, the honest choice is to wrap it in a thread pool and size that pool deliberately, or to run that part of the system as a synchronous service with more workers.

  </details>

- **NICE** — `def` against `async def` in a framework handler

  <details><summary><strong>Answer</strong></summary>

  [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation") and Starlette run an `async def` handler on the loop and a plain `def` handler in a bounded thread pool. That means a synchronous handler is safe but limited by the pool size, while an `async def` handler containing a blocking call is the dangerous combination — the framework trusted you and the loop is now stopped.

  Declaring a handler `def` when it calls blocking code is therefore the correct choice, not a fallback.

  </details>

- **NICE** — CPU work in an async service

  <details><summary><strong>Answer</strong></summary>

  Image processing, [PDF](https://en.wikipedia.org/wiki/PDF "Portable Document Format — Fixed-layout document format for reliable printing and viewing") generation, large serialisation and cryptographic hashing all belong off the loop: a `ProcessPoolExecutor` for a bounded amount, or a task queue for anything that can be deferred. The rule of thumb worth stating is that anything over a few milliseconds of computation does not belong inline in a request on an event loop.

  </details>

- **OPTIONAL** — Thread-safety of the loop itself

  <details><summary><strong>Answer</strong></summary>

  Almost no `asyncio` object is thread-safe, so calling loop methods from another thread is undefined behaviour with the two documented exceptions: `call_soon_threadsafe` and `run_coroutine_threadsafe`. A background thread that touches loop objects directly produces corruption that looks random.

  </details>

## 4. gather, TaskGroup, Cancellation and Timeouts

**Why it comes up:** running things concurrently is easy; deciding what happens when one of them fails or takes too long is the part that shows experience.

- **MUST** — `gather` and what its arguments mean

  <details><summary><strong>Answer</strong></summary>

  `await asyncio.gather(*coros)` schedules everything concurrently and returns results in the order given, not the order of completion. By default the first exception propagates immediately while **the other tasks keep running**, unawaited and unobserved — which is the detail that surprises people.

  `return_exceptions=True` instead returns exceptions in the result list, so nothing is lost and the caller decides per item. That is the right choice for a fan-out where partial success is meaningful, such as calling twelve services and rendering what came back.

  </details>

- **MUST** — `TaskGroup` and structured concurrency

  <details><summary><strong>Answer</strong></summary>

  `async with asyncio.TaskGroup() as tg:` from 3.11 creates tasks that cannot outlive the block: on exit it waits for all of them, and if one fails it **cancels the siblings** and raises an `ExceptionGroup` when they have finished unwinding. Nothing is left running and nothing is left unobserved.

  That is the structured-concurrency guarantee, and it is why `TaskGroup` is the default choice for new code, with `gather` reserved for the case where you genuinely want independent tasks to continue after one fails. `except*` is the syntax for handling an `ExceptionGroup` by member type.

  </details>

- **MUST** — Timeouts

  <details><summary><strong>Answer</strong></summary>

  `async with asyncio.timeout(5):` from 3.11 cancels whatever is inside when the deadline passes and raises `TimeoutError`; `wait_for` is the older per-awaitable form. A network call without a timeout is a resource leak waiting for a slow peer, and the default in most clients is either none or far too generous.

  Timeouts compose badly if each layer sets its own: an outer five seconds around three inner four-second calls means the outer one always wins and the inner ones never fire. Setting the budget at the edge and passing a deadline down is the version that behaves predictably.

  </details>

- **MUST** — How cancellation actually works

  <details><summary><strong>Answer</strong></summary>

  `task.cancel()` requests cancellation by raising `CancelledError` **at the task's next await point** — it does not stop anything immediately, and a task that never awaits again is never cancelled. Since 3.8 `CancelledError` inherits from `BaseException`, specifically so that a bare `except Exception` does not swallow it.

  Catching it to clean up is legitimate; catching it and continuing is how a shutdown hangs. Re-raise after cleanup, put the cleanup in `finally`, and use `asyncio.shield` for the rare operation that must complete even if its caller goes away.

  </details>

- **NICE** — `as_completed` and `wait`

  <details><summary><strong>Answer</strong></summary>

  `as_completed` yields futures as they finish, which is what you want for streaming partial results or for stopping early once enough have arrived. `asyncio.wait` with `FIRST_COMPLETED` gives the same ability with explicit done and pending sets — and leaves the pending ones running, so cancelling them is the caller's job.

  </details>

- **NICE** — Bounding concurrency

  <details><summary><strong>Answer</strong></summary>

  Creating ten thousand tasks against one API is a self-inflicted denial of service and will usually exhaust the connection pool or earn a rate-limit ban. `asyncio.Semaphore(n)` around the unit of work bounds it, and it is the missing line in most fan-out code written quickly.

  </details>

- **OPTIONAL** — Exception groups outside task groups

  <details><summary><strong>Answer</strong></summary>

  `ExceptionGroup` and `except*` are general: they exist so that several unrelated failures can propagate together rather than the first one winning. A task group is the common source, but any code that fans out can raise one deliberately.

  </details>

## 5. Thread Safety Primitives

**Why it comes up:** it is the classic concurrency interview area, and in Python the first thing a good answer says is that the interpreter lock does not make your code thread-safe.

- **MUST** — Why a race exists despite the interpreter lock

  <details><summary><strong>Answer</strong></summary>

  The lock guarantees that one thread executes bytecode at a time, not that a statement is atomic. `counter += 1` compiles to a load, an add and a store, and the interpreter can switch threads between any two of them — so two threads can both read 5 and both write 6, losing an increment.

  The generalisation is that any **read-modify-write** on shared state needs a lock: a counter, a check-then-act on a dict, appending to a list after testing its length. Single operations on built-in containers are effectively atomic because they happen inside one bytecode, which is why `list.append` needs no lock and `if x not in lst: lst.append(x)` does.

  </details>

- **MUST** — `Lock` and `RLock`

  <details><summary><strong>Answer</strong></summary>

  `threading.Lock` is a plain mutex: acquiring it twice from the same thread deadlocks against itself, which happens the moment a method holding it calls another method that takes it. `RLock` counts acquisitions by the owning thread and releases when the count returns to zero, which is what makes recursive and re-entrant call patterns work.

  Always acquire with `with lock:` so the release happens on every path including an exception. Choosing `RLock` by default hides a design problem — needing re-entrancy usually means the locked region is larger than the invariant it protects.

  </details>

- **MUST** — `Semaphore`, `Event` and `Condition`

  <details><summary><strong>Answer</strong></summary>

  A **Semaphore** admits n holders at once and is the tool for bounding concurrency against a limited resource — a connection pool, an API rate limit. An **Event** is a one-way flag that threads wait on, which is the clean way to signal shutdown or readiness. A **Condition** pairs a lock with a wait-and-notify, for "wait until this state changes" where a busy loop would otherwise appear.

  `Condition.wait` must be called in a `while` loop that rechecks the predicate, because a thread can wake without the condition holding. That detail is what the question is usually probing.

  </details>

- **MUST** — Deadlock, and the rules that prevent it

  <details><summary><strong>Answer</strong></summary>

  Deadlock needs mutual exclusion, hold-and-wait, no pre-emption and a circular wait, and breaking any one of them is enough. In practice two rules do it: acquire locks in a globally consistent order everywhere, and do not hold a lock while calling code you do not control — a callback, a network call, another module's method.

  `acquire(timeout=...)` turns a deadlock into a detectable error rather than a hang, which is worth having in a long-running service even when the ordering is believed to be correct.

  </details>

- **NICE** — Thread-local state and `contextvars`

  <details><summary><strong>Answer</strong></summary>

  `threading.local()` gives each thread its own copy of an attribute, which is how request-scoped state was historically carried without passing it. It does not work with `asyncio`, since many tasks share one thread.

  `contextvars.ContextVar` is the modern replacement: it follows the logical flow of execution, so it is correct in async code and in threads, and it is what a request ID or a correlation ID should live in.

  </details>

- **NICE** — The lock that is not needed

  <details><summary><strong>Answer</strong></summary>

  The cheapest thread-safety is not sharing: give each thread its own data and combine at the end, use immutable values, or pass messages through a queue instead of sharing state. Most locking bugs are in code where sharing was never required.

  Where sharing is genuine, keep the critical section as small as the invariant — a lock held across an I/O call has turned a parallel program back into a serial one.

  </details>

- **OPTIONAL** — Atomicity that is an implementation detail

  <details><summary><strong>Answer</strong></summary>

  Which operations are atomic follows from how CPython compiles them, not from a promise in the language reference, and a free-threaded build changes the answer for some of them. Writing code that depends on that accident is how a program passes for years and then fails on a new interpreter.

  </details>

## 6. Queue as the Channel Between Threads

**Why it comes up:** it is the answer that makes most locking unnecessary, and the producer-consumer shape is the one concurrency design everyone is expected to be able to sketch.

- **MUST** — Why a queue instead of shared state

  <details><summary><strong>Answer</strong></summary>

  `queue.Queue` is internally locked, so producers and consumers hand items over without any shared mutable state between them and without a lock written by hand. The design principle is to communicate by sharing nothing rather than to share and then coordinate.

  `put` and `get` block by default, which is the feature: a consumer with nothing to do waits instead of spinning, and a producer facing a full queue waits instead of growing memory.

  </details>

- **MUST** — `maxsize` is backpressure

  <details><summary><strong>Answer</strong></summary>

  An unbounded queue turns a producer that is faster than its consumers into unbounded memory growth and then a process that is killed — the failure looks like a memory leak and is a design error. `Queue(maxsize=n)` makes `put` block when full, which propagates the slowness back to the producer where it can be handled.

  Choosing the bound is a real decision: large enough to absorb bursts, small enough that the memory is affordable and that a failure loses little work.

  </details>

- **MUST** — Shutting a worker pool down

  <details><summary><strong>Answer</strong></summary>

  The standard mechanism is a sentinel: put one `None` per worker, and have each worker exit when it receives one. Daemon threads are the alternative and they are killed abruptly at interpreter exit, which is fine for a cache warmer and not for anything mid-write.

  `task_done` and `join` let the producer wait until every item has been processed rather than merely dequeued — the distinction that decides whether "finished" means the work is done or only handed over.

  </details>

- **MUST** — Handling an exception in a worker

  <details><summary><strong>Answer</strong></summary>

  An exception in a thread does not propagate to the main thread: it prints and that thread dies, so a pool silently shrinks to nothing while the queue fills. Every worker loop therefore needs a `try/except` around the item, with the failure logged and either dropped or put on a failure queue.

  The consequence worth naming is that a health check on queue depth, or a counter of failures, is what tells you the pool has died. Nothing in the language will.

  </details>

- **NICE** — The variants

  <details><summary><strong>Answer</strong></summary>

  `LifoQueue` for stack order, `PriorityQueue` for ordered work — which compares the tuples put into it, so a counter between the priority and the payload avoids comparing unorderable items. `SimpleQueue` is unbounded and faster where no `join` or bound is needed.

  `asyncio.Queue` is the coroutine equivalent with the same API and no locking, and `multiprocessing.Queue` is the cross-process one, which pickles every item.

  </details>

- **NICE** — When the queue should be outside the process

  <details><summary><strong>Answer</strong></summary>

  An in-process queue is lost when the process restarts, so anything that must survive a deploy or a crash belongs in a broker or a database-backed queue. In-process is right for a bounded pipeline inside one request or one job; it is not a task queue.

  </details>

- **OPTIONAL** — `deque` as a lighter channel

  <details><summary><strong>Answer</strong></summary>

  `collections.deque` has atomic appends and pops, so for a simple hand-off with no blocking, no bound and no join, it is faster than a `Queue`. What it does not give you is the waiting, which is usually the reason the queue was wanted.

  </details>

## 7. concurrent.futures Executors

**Why it comes up:** it is the one API that covers both threads and processes, so it is where the difference between the two becomes concrete.

- **MUST** — The common interface

  <details><summary><strong>Answer</strong></summary>

  `ThreadPoolExecutor` and `ProcessPoolExecutor` share an API: `submit` returns a **Future**, `map` applies a function over an iterable, and `as_completed` yields futures in completion order. Switching between threads and processes is therefore one line — which is exactly what makes measuring both easy.

  Using the executor as a context manager is what guarantees the pool is shut down and the workers joined; forgetting it leaves a process that will not exit.

  </details>

- **MUST** — Futures, results and exceptions

  <details><summary><strong>Answer</strong></summary>

  `future.result()` blocks until the value is ready and **re-raises** any exception from the worker in the calling thread, with the remote traceback attached. A future whose result is never retrieved swallows its exception silently, which is the most common way a pool appears to work while doing nothing.

  `as_completed` is the right pattern for a fan-out, because it lets you handle each failure as it arrives rather than after the slowest task. `map` propagates the first exception and abandons the rest, which is sometimes what you want and rarely what you meant.

  </details>

- **MUST** — What changes with a process pool

  <details><summary><strong>Answer</strong></summary>

  Arguments and return values must be picklable, so a lambda, a local function, an open file or a database connection cannot cross. There is no shared memory, so globals are copies and mutating one in a worker changes nothing. And every call pays serialisation both ways, so fine-grained tasks can cost more to dispatch than to run.

  The design that follows is coarse tasks over large inputs, with `chunksize` on `map` to amortise the dispatch. A process pool over a million one-microsecond calls is slower than a plain loop.

  </details>

- **MUST** — Sizing the pool

  <details><summary><strong>Answer</strong></summary>

  For processes, the core count is the ceiling and `os.cpu_count()` is the default — but in a container the right number comes from the CPU limit, not from the host, and `len(os.sched_getaffinity(0))` is the honest source. For threads doing I/O, the size follows the downstream capacity: the connection pool, the rate limit, or the remote service's tolerance.

  Oversizing a thread pool converts a bottleneck into a queue with worse latency and no more throughput, which is the failure mode that looks like a fix.

  </details>

- **NICE** — Failure of a worker process

  <details><summary><strong>Answer</strong></summary>

  If a worker is killed — an out-of-memory kill, a segmentation fault in a native library — the pool raises `BrokenProcessPool` and every pending future fails. There is no automatic replacement, so a long-running service using a process pool needs to recreate it, and the memory limit that killed the worker needs addressing rather than retrying.

  </details>

- **NICE** — `initializer` and per-worker setup

  <details><summary><strong>Answer</strong></summary>

  `ProcessPoolExecutor(initializer=fn)` runs once per worker, which is where an expensive per-process resource belongs — a loaded model, a compiled regex set, a database connection. Creating it inside the task instead pays the cost on every call.

  </details>

- **OPTIONAL** — The relationship to asyncio

  <details><summary><strong>Answer</strong></summary>

  `loop.run_in_executor` takes exactly these executors, so the same pool serves both a synchronous program and an async one. That is the bridge that lets an async service run blocking or CPU-bound work without leaving the framework.

  </details>

## 8. Multiprocessing Start Methods

**Why it comes up:** the default changed, `fork` in a threaded process is genuinely unsafe, and the resulting bugs are platform-specific and hard to reproduce.

- **MUST** — The three methods

  <details><summary><strong>Answer</strong></summary>

  **fork** clones the parent process, so the child starts with everything already imported and every object in place; it is fast and available only on Unix. **spawn** starts a fresh interpreter and re-imports the target module, so the child inherits nothing but what is explicitly passed; it is slower and is the default on Windows and macOS. **forkserver** forks from a small, clean server process started early, giving fork's speed without inheriting the main process's threads.

  The defaults matter for portability: code that works on Linux by relying on inherited globals fails on macOS, where `spawn` has been the default since 3.8 and where the same code sees none of them.

  </details>

- **MUST** — Why `fork` with threads is unsafe

  <details><summary><strong>Answer</strong></summary>

  `fork` duplicates only the calling thread, so any lock held by another thread at that instant is copied in the locked state with no owner to release it — and the child deadlocks the first time it touches that lock. Since threads are started by logging handlers, [gRPC](https://grpc.io/docs/ "gRPC Remote Procedure Calls — Contract-first remote procedure call framework running over HTTP/2 with protocol buffer payloads"), database drivers and [BLAS](https://www.netlib.org/blas/ "Basic Linear Algebra Subprograms — Standard low-level routines that numeric libraries use for vector and matrix operations") backends without anyone asking, this is far more common than it sounds.

  Python 3.12 warns when forking a process with multiple threads, and 3.14 changes the default on Linux to `forkserver` for exactly this reason. Naming it before being asked is a strong production signal.

  </details>

- **MUST** — The `spawn` requirements

  <details><summary><strong>Answer</strong></summary>

  Because the child re-imports the module, everything at module level runs again — so the entry point must be guarded by `if __name__ == "__main__":`, or the program forks recursively until the machine gives up. Everything passed to the child must be picklable, which rules out lambdas, local functions, open files and connections.

  Writing for `spawn` from the start is the portable choice, and it also forces the dependencies to be explicit rather than inherited, which is easier to test.

  </details>

- **MUST** — What is not inherited, and the surprises

  <details><summary><strong>Answer</strong></summary>

  With `spawn`: no globals, no loaded configuration, no open connections, no logging configuration, no random seed continuity. With `fork`: all of it, including a database connection that is now shared by two processes and will corrupt its protocol the moment both use it.

  Both directions bite. The reliable pattern is to create resources *inside* the child — in the executor's `initializer`, or at the top of the worker function — rather than relying on or fighting inheritance.

  </details>

- **NICE** — Copy-on-write is not the saving it appears to be

  <details><summary><strong>Answer</strong></summary>

  A forked child shares the parent's memory until it writes, which suggests a large preloaded structure is free to share. Reference counting defeats that, because reading an object writes to its refcount and dirties the page.

  `gc.freeze()` after loading and before forking moves those objects out of the collector's reach and reduces the damage; genuine sharing needs `shared_memory` or an `mmap`.

  </details>

- **NICE** — Choosing one explicitly

  <details><summary><strong>Answer</strong></summary>

  `multiprocessing.set_start_method("spawn", force=True)` at the top of the entry point, or `get_context("spawn")` for a local context, makes the behaviour the same everywhere instead of depending on the platform and the release. A library should use `get_context` rather than set the global default, since the application owns that choice.

  </details>

- **OPTIONAL** — Signals and orphans

  <details><summary><strong>Answer</strong></summary>

  Children do not inherit the parent's signal handlers usefully, and a parent killed with `SIGKILL` leaves orphans behind. A supervisor, a process group, or the `atexit` and `terminate` handling that the executors already implement is what keeps a pool from outliving its owner.

  </details>

## 9. Inter-Process Communication

**Why it comes up:** it is the cost that decides whether multiprocessing pays for itself, and the answer should start with serialisation rather than with an API list.

- **MUST** — Everything crosses as bytes

  <details><summary><strong>Answer</strong></summary>

  Processes share no memory, so every argument and every result is pickled, written to a pipe and unpickled. That is the dominant cost of multiprocessing, and it is why passing a large DataFrame to a worker can take longer than the computation it enables.

  The design consequence is to send the smallest thing that identifies the work — a file path, a row range, an object key — and let the worker read the data itself, rather than sending the data through the parent.

  </details>

- **MUST** — Queues and pipes

  <details><summary><strong>Answer</strong></summary>

  `multiprocessing.Queue` is the general channel: it pickles items, has a feeder thread behind it, and supports many producers and consumers. `Pipe` is a lower-level pair of connection objects, faster and limited to two endpoints.

  The trap in `Queue` is at shutdown: a process that has put items on a queue will not exit until they have been consumed, so a parent joining a child that is still holding queued data deadlocks. Draining before joining, or `cancel_join_thread` where the data is expendable, is the fix.

  </details>

- **MUST** — Shared memory for large data

  <details><summary><strong>Answer</strong></summary>

  `multiprocessing.shared_memory.SharedMemory` gives a named block that several processes map directly, so a [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") array built over it is visible to all of them with no copy and no pickling. That is the only way to share gigabytes cheaply.

  The costs are the ones shared memory always has: no synchronisation, so a lock is still needed for anything but read-only data; and the block must be explicitly unlinked, or it survives the process and leaks until reboot.

  </details>

- **MUST** — `Value`, `Array` and `Manager`

  <details><summary><strong>Answer</strong></summary>

  `Value` and `Array` are small shared ctypes objects with an optional lock, suitable for a counter or a flag. A `Manager` offers shared `dict`, `list` and other objects — but it does this by running a **server process** and proxying every operation through it, so each access is a round trip and pickling, which is orders of magnitude slower than it looks.

  A `Manager().dict()` used inside a loop is a common accidental bottleneck. It is for convenience and low-frequency coordination, not for data exchange.

  </details>

- **NICE** — Not using the standard library at all

  <details><summary><strong>Answer</strong></summary>

  Once the processes might live on different machines, the answer moves outward: a message broker, Redis, or a database as the shared state. That also removes the pickling-compatibility constraint that ties every worker to the same Python version and the same code.

  Choosing this early is often right, because "several processes on one machine" tends to become "several machines" in production.

  </details>

- **NICE** — Pickle's limits and its danger

  <details><summary><strong>Answer</strong></summary>

  Pickle handles most objects but not open files, sockets, locks, generators, lambdas or locally defined classes, and it ties both ends to compatible class definitions. It also executes code on load, so it must never be used across a trust boundary — inside one application's own process tree it is fine, and over a network it is a remote code execution vulnerability.

  </details>

- **OPTIONAL** — Faster serialisation between workers

  <details><summary><strong>Answer</strong></summary>

  Where the payload is tabular or numeric, Arrow's [IPC](https://en.wikipedia.org/wiki/Inter-process_communication "Inter Process Communication — Mechanisms by which separate processes exchange data") format or a memory-mapped file is dramatically cheaper than pickle and is what the data-processing frameworks use underneath. It is worth reaching for only once serialisation has been measured to dominate.

  </details>

## 10. Graceful Shutdown and Signals

**Why it comes up:** every container is stopped by a signal, and whether the service loses in-flight work on a deploy is decided entirely by what it does with that signal.

- **MUST** — What the orchestrator actually does

  <details><summary><strong>Answer</strong></summary>

  A container runtime sends `SIGTERM`, waits a grace period — 30 seconds by default in [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") — and then sends `SIGKILL`, which cannot be caught. So the contract is simple: stop accepting new work on `SIGTERM`, finish what is in flight, release resources, and exit before the deadline.

  A service that ignores `SIGTERM` loses every in-flight request on every deploy, which shows up as a small, regular error spike that nobody attributes to the deployment.

  </details>

- **MUST** — Handling a signal in Python

  <details><summary><strong>Answer</strong></summary>

  `signal.signal(signal.SIGTERM, handler)` registers a handler that runs in the **main thread**, between bytecodes, whenever the interpreter next gets control. The handler should do almost nothing — set a flag or an `Event` — because it interrupts arbitrary code and can itself be interrupted.

  In `asyncio`, `loop.add_signal_handler` is the correct form, since it schedules the callback on the loop rather than running it at an arbitrary suspension point. A blocking system call is interrupted and may raise, which is why the retry rules around `EINTR` exist.

  </details>

- **MUST** — The shutdown sequence for a server

  <details><summary><strong>Answer</strong></summary>

  Fail the readiness probe first so the load balancer stops sending traffic, then stop accepting connections, then wait for in-flight requests up to a timeout shorter than the grace period, then close database and broker connections, flush logs and metrics, and exit zero.

  The ordering is the answer: closing the listener before the load balancer has noticed produces connection errors for clients, which is the bug that makes people believe graceful shutdown does not work.

  </details>

- **MUST** — Workers and children

  <details><summary><strong>Answer</strong></summary>

  A process manager such as gunicorn forwards the signal to its workers and waits for them; a worker that ignores it is killed at the timeout. A consumer of a queue or a broker must stop fetching, finish the current message, acknowledge it and only then exit — dropping an unacknowledged message is usually safe because it is redelivered, but acknowledging and then dying loses it.

  In a container, [PID](https://en.wikipedia.org/wiki/Process_identifier "Process Identifier — Number the operating system assigns to a running process") 1 does not get default signal handling, so a shell-wrapped entry point can swallow the signal entirely. Running the process directly, or using an init such as `tini`, is what fixes it.

  </details>

- **NICE** — `KeyboardInterrupt` and `SIGINT`

  <details><summary><strong>Answer</strong></summary>

  `SIGINT` is delivered as `KeyboardInterrupt` in the main thread, so a bare `except Exception` does not swallow it — it derives from `BaseException` for the same reason `CancelledError` does. Code that catches `BaseException` broadly makes a program unkillable from the terminal.

  </details>

- **NICE** — Idempotency as the real defence

  <details><summary><strong>Answer</strong></summary>

  A process can always be killed without warning — an out-of-memory kill, a node failure, a `SIGKILL` after the grace period — so graceful shutdown reduces the frequency of lost work rather than eliminating it. Work that must not be lost needs to be restartable: a transaction, an idempotency key, or a message that is only acknowledged after the effect is durable.

  </details>

- **OPTIONAL** — Draining a long job

  <details><summary><strong>Answer</strong></summary>

  A job longer than the grace period cannot finish in it, so the options are checkpointing so a restart resumes, splitting the work into shorter units, or raising `terminationGracePeriodSeconds` deliberately. Hoping it finishes is not one of them.

  </details>

## 11. Free-Threaded CPython and Subinterpreters

**Why it comes up:** it is the live question in Python concurrency right now, and the useful answer is about what it changes for your code rather than about the release notes.

- **MUST** — What the free-threaded build is

  <details><summary><strong>Answer</strong></summary>

  It is a separate build of CPython with the interpreter lock removed, official since 3.13 and supported rather than experimental from 3.14. Threads in it execute Python bytecode genuinely in parallel, which removes the reason most CPU-bound Python work is pushed into processes. What the lock itself protects is covered in `Python-language.md`.

  It is selected at build time and reported by `sys._is_gil_enabled()`, so a program can check rather than assume. The single-threaded cost has fallen from roughly 40% in the early prototypes into the high single digits.

  </details>

- **MUST** — What it does not fix

  <details><summary><strong>Answer</strong></summary>

  It does not make existing threaded code correct. A great deal of Python code has relied, knowingly or not, on operations being effectively atomic because the lock made them so — and with the lock gone those become real data races that appear under load and not in tests.

  Locking discipline therefore matters more in a free-threaded build, not less. The rule stays what it was: any read-modify-write on shared state needs a lock, and the free-threaded build simply removes the accident that was hiding the omissions.

  </details>

- **MUST** — What it means for choosing a model

  <details><summary><strong>Answer</strong></summary>

  Where it applies, CPU-bound work can move from processes to threads, which removes pickling, removes the memory duplication of a process per core, and makes sharing a large in-memory structure trivial. That is a substantial simplification for anything that was using `multiprocessing` only to escape the lock.

  The constraint is the ecosystem: every C extension in the dependency tree must be rebuilt and declared compatible, so the practical answer for most services today is still the conventional build. Saying that plainly is better than enthusiasm.

  </details>

- **MUST** — Subinterpreters as the other route

  <details><summary><strong>Answer</strong></summary>

  A subinterpreter has its own interpreter state and, since 3.12, its own lock, so several can run in parallel inside one process; `concurrent.interpreters` is the standard-library surface from 3.14, alongside an interpreter-backed executor.

  They sit between threads and processes: no separate process to start and no memory duplication of the process image, but no shared object graph either, so data still crosses by copying or through a small set of shareable types. The limit is the same as for the free-threaded build — extensions must support per-interpreter state, and many do not yet.

  </details>

- **NICE** — How to be ready for it

  <details><summary><strong>Answer</strong></summary>

  Lock shared mutable state explicitly rather than relying on atomicity, prefer queues and immutable messages between threads, keep module-level mutable globals out of libraries, and test under real concurrency rather than with a single worker. All of that is good practice in the current build and is what makes the transition uneventful.

  </details>

- **NICE** — What to say when asked whether to adopt it

  <details><summary><strong>Answer</strong></summary>

  Adopt it where the workload is CPU-bound pure Python, the dependency set is small or already compatible, and the benchmark is run rather than assumed. Do not adopt it to speed up an I/O-bound service, where it changes nothing that asyncio or threads were not already doing.

  </details>

- **OPTIONAL** — Checking whether your dependencies are ready

  <details><summary><strong>Answer</strong></summary>

  Free-threaded wheels carry their own tag — `cp314t` rather than `cp314` — so `pip` simply fails to find a wheel for a package that has not published one, and falls back to building from source or to an error. That is the practical readiness test, and it is faster than reading release notes.

  At run time, `sys._is_gil_enabled()` reports which build is actually executing, which is worth asserting at start-up in any code whose correctness assumptions differ between the two.

  </details>
