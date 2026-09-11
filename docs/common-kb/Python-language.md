# Fundamental Topics: Python Language and Data Model

**Table of Contents**

[Common Topics](#common-topics)

- [1. The GIL](#1-the-gil)
- [2. Mutable and Immutable Types](#2-mutable-and-immutable-types)
- [3. Pass by Object Reference](#3-pass-by-object-reference)
- [4. Reference Counting and Garbage Collection](#4-reference-counting-and-garbage-collection)
- [5. Equality, Identity and the Hash Contract](#5-equality-identity-and-the-hash-contract)
- [6. The CPython Interpreter Model](#6-the-cpython-interpreter-model)
- [7. Shallow and Deep Copy](#7-shallow-and-deep-copy)
- [8. Version Differences Worth Naming](#8-version-differences-worth-naming)

[Data Model Topics](#data-model-topics)

- [9. Decorators and Closures](#9-decorators-and-closures)
- [10. Iterators and Iterables](#10-iterators-and-iterables)
- [11. Generators](#11-generators)
- [12. Context Managers](#12-context-managers)
- [13. Dunder Methods and the Protocols](#13-dunder-methods-and-the-protocols)
- [14. Method Resolution Order and super](#14-method-resolution-order-and-super)
- [15. Class and Instance Attributes](#15-class-and-instance-attributes)
- [16. Slots](#16-slots)
- [17. Descriptors](#17-descriptors)
- [18. First-Class Functions and Callables](#18-first-class-functions-and-callables)
- [19. Metaclasses and Subclass Hooks](#19-metaclasses-and-subclass-hooks)
**What this is.** The Python language and data-model topics a backend engineer is expected to reason about from first principles rather than recite, taken from the first two groups of the list in `docs/tmp/common-kb/Python.txt`. That list is long enough to be five documents; the others are `Python-data-structures.md`, `Python-concurrency.md`, `Python-typing-stdlib.md` and `Python-applications.md`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") is the concrete reference throughout, at a 3.12 baseline with later behaviour named where it differs, because the topics in this half — the interpreter lock, reference counting, the bytecode model — are properties of that implementation rather than of the language, and saying so is half of what the questions are testing.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1 and topic 9 are the ones you are most likely to be asked. The grouping follows `Python.txt`: what holds for the language and its runtime, then the data model that every framework you have used is built from.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 78 MUST, 35 NICE and 20 OPTIONAL across 19 topics. Two thirds MUST is what this half of the list is: the interpreter model and the data model are where an interviewer checks that the foundation is there before asking about anything you have built.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Common Topics


## 1. The GIL

**Why it comes up:** it is the single most-asked Python question, and the answer reveals whether you choose a concurrency model by workload or by habit.

- **MUST** — What the [GIL](https://wiki.python.org/moin/GlobalInterpreterLock "Global Interpreter Lock — CPython mechanism that lets only one thread execute Python bytecode at a time") protects, and why it exists at all

  <details><summary><strong>Answer</strong></summary>

  The **Global Interpreter Lock** is a single mutex in the CPython process that a thread must hold to execute Python bytecode. What it protects is the interpreter's own internal state — above all the reference count on every object, which is a plain integer field that would otherwise need an atomic operation on every increment and decrement.

  It exists because that guarantee is enormously cheap to provide this way and enormously expensive to provide any other way. Making every refcount atomic costs perhaps 20-30% on single-threaded code, and fine-grained locking of interpreter internals is where the historical attempts at removal died. The GIL buys a fast single-threaded interpreter and a C extension [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") in which an author can touch Python objects without writing any locking.

  </details>

- **MUST** — What it costs: CPU-bound threads do not scale

  <details><summary><strong>Answer</strong></summary>

  Two threads running pure Python arithmetic on an eight-core machine finish no faster than one, and usually slightly slower, because they take turns holding the same lock and pay context-switch and lock-handoff cost on top. Threading gives you concurrency in CPython, never parallelism, for anything that computes in Python bytecode.

  The practical consequence is that a thread pool is the wrong tool for image resizing, parsing, serialisation or numeric work written in Python, and the fix is `multiprocessing` or `concurrent.futures.ProcessPoolExecutor`, which gives one GIL per process. The cost of that fix is real — pickling arguments and results across a pipe, and a fresh interpreter per worker.

  </details>

- **MUST** — What it does not serialise

  <details><summary><strong>Answer</strong></summary>

  The lock is released around anything that does not touch interpreter state: every blocking I/O call, `time.sleep`, and any C extension that brackets its work in `Py_BEGIN_ALLOW_THREADS`. That is why a hundred threads issuing [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") requests really do overlap, and why [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") matrix multiplication, `hashlib`, compression and most database drivers genuinely use several cores from threads.

  **The rule is** that the GIL serialises the interpreter, not the process. An answer that says "Python cannot use more than one core" is wrong in the direction that matters, because the workloads people actually parallelise — I/O and native numeric code — are exactly the ones that escape it. What that enables in practice, and how to tell whether a given library does it, is covered in `Python-data-structures.md`.

  </details>

- **MUST** — Why removing it was never simple

  <details><summary><strong>Answer</strong></summary>

  Every serious attempt made single-threaded code substantially slower. Greg Stein's 1999 patch removed the lock and roughly halved throughput; the Gilectomy a decade later landed in the same place, because making each reference count an atomic operation costs 20-30% on its own and fine-grained locking of interpreter internals costs more.

  What finally made it viable was changing the accounting rather than the locking: biased reference counting so the owning thread's updates stay cheap, deferred counting for long-lived objects, immortal objects that are never counted at all, and a new allocator. **The consequence is** that this is an engineering result rather than a decision someone could have taken earlier, which is the honest answer to "why did they not just remove it".

  </details>

- **NICE** — How the interpreter actually hands the lock over

  <details><summary><strong>Answer</strong></summary>

  A CPU-bound thread does not hold the lock forever. It checks a flag every so often and, if another thread has been waiting for longer than `sys.getswitchinterval` — 5 ms by default — drops the GIL and lets the waiter run. Before Python 3.2 the switch was counted in bytecodes rather than timed, which starved I/O threads badly on multicore machines.

  **The consequence is** that a latency-sensitive thread sharing a process with a busy computing thread can sit for milliseconds behind it, so the switch interval is occasionally worth tuning, and the fact that it is a wall-clock timer and not a fair scheduler is worth knowing.

  </details>

- **NICE** — Free-threaded CPython

  <details><summary><strong>Answer</strong></summary>

  Python 3.13 shipped an official build with the lock removed and 3.14 moved it from experimental to supported; it is chosen at build time and reported by `sys._is_gil_enabled`. Reference counting becomes biased and deferred, containers acquire internal locking, and the single-threaded cost is now in the high single digits.

  The boundary to state here is that removing the lock removes the accidental atomicity that existing threaded code has been relying on, so races that were masked become real. What that means for choosing a concurrency model, and for subinterpreters as the other route to parallelism, is covered in `Python-concurrency.md`.

  </details>

- **OPTIONAL** — It is a property of CPython, not of Python

  <details><summary><strong>Answer</strong></summary>

  Jython and IronPython never had one, because the [JVM](https://docs.oracle.com/javase/specs/jvms/se21/html/index.html "Java Virtual Machine — Runtime that executes Java bytecode and hosts other languages including Jython") and the [CLR](https://learn.microsoft.com/en-us/dotnet/standard/clr "Common Language Runtime — Execution engine for .NET languages, hosting IronPython among others") provide their own garbage collection and thread safety; PyPy has one for the same reasons CPython does; GraalPy inherits the JVM's model. The language specification says nothing about it.

  Saying so is worth a sentence, because it reframes the whole topic: the lock is an artefact of one implementation's memory management, and every argument about it is really an argument about reference counting.

  </details>

## 2. Mutable and Immutable Types

**Why it comes up:** the mutable default argument is the most common Python bug that survives code review, and it is a two-line demonstration of whether you understand when objects are created.

- **MUST** — The mutable default argument, and why it bites

  <details><summary><strong>Answer</strong></summary>

  A default value is evaluated **once, at definition time** — when the `def` statement runs, not on each call, and is stored on the function object in `__defaults__`. So `def add(item, target=[])` creates one list that every call without an explicit argument shares and mutates, and the function accumulates state across calls that look independent.

  The fix is `target=None` plus `if target is None: target = []` inside the body, which moves the construction to call time. The same trap covers `{}`, `set()`, and any object built at definition time — including a `datetime.now()` default, which silently freezes to the import timestamp.

  **The tell is** whether you can say *why* rather than just quoting the rule: a function is an object, and its defaults are attributes of that object.

  </details>

- **MUST** — Which built-in types are immutable, and what immutability actually means

  <details><summary><strong>Answer</strong></summary>

  Immutable: `int`, `float`, `str`, `bytes`, `tuple`, `frozenset`, `complex`, `bool`, `None`. Mutable: `list`, `dict`, `set`, `bytearray`, and by default any class you write. Immutable means the object's own value cannot change after construction, so any apparent mutation — `s += "x"`, `n += 1` — rebinds the name to a new object.

  The boundary that gets missed is that immutability is shallow. A tuple's identity of contents is fixed, but `t = ([1], [2])` still lets you do `t[0].append(3)`, because the tuple holds references and the referenced lists are their own objects. That is also why such a tuple is unhashable in practice: `hash(t)` recurses into its elements and fails.

  </details>

- **MUST** — Why it matters: hashing, sharing and thread safety

  <details><summary><strong>Answer</strong></summary>

  Only hashable objects can be dictionary keys or set members, and hashability requires a value that will not change, so immutability is what makes `str` and `tuple` usable as keys. It also makes sharing safe: an immutable object can be passed anywhere, cached and read from multiple threads with no defensive copy.

  **The costs are** allocation and copying. Building a string with `+=` in a loop is quadratic because each step allocates a new string and copies the old one, which is why `"".join(parts)` is the idiom rather than a style preference.

  </details>

- **MUST** — Making your own types immutable

  <details><summary><strong>Answer</strong></summary>

  `@dataclass(frozen=True)` generates `__setattr__` and `__delattr__` that raise, and gives you a `__hash__` derived from the fields when `eq` is also on. `typing.NamedTuple` gives a real immutable tuple subclass with named fields and the lowest memory footprint of the three.

  Neither is enforcement against a determined caller — `object.__setattr__` still works on a frozen dataclass — so the guarantee is against accident, not against attack.

  </details>

- **MUST** — Read-only views: `frozenset` and `MappingProxyType`

  <details><summary><strong>Answer</strong></summary>

  When a mapping must be exposed but not changed, `types.MappingProxyType(d)` wraps it in a read-only view — writes raise `TypeError`, and the view reflects later changes to the underlying dict rather than snapshotting it. `frozenset` is the immutable, hashable set, which is what lets a set of sets exist at all.

  Neither is a security boundary, since the caller can still reach the original object if it has a reference to it. They are a contract: a class exposing `config` as a proxy is saying that mutation goes through its own methods, and that is enough to stop the accidental case.

  </details>

- **NICE** — Interning and identity surprises

  <details><summary><strong>Answer</strong></summary>

  CPython caches small integers from -5 to 256 and interns string literals that look like identifiers, so `a = 256; b = 256; a is b` is True while the same with 257 is False — inside a single compiled block constant folding may make it True again. None of this is a language guarantee; it is an implementation detail of one interpreter.

  The correct conclusion is not a trick to exploit but a rule to follow: compare values with `==` and reserve `is` for `None`, `True`, `False` and sentinel objects. Relying on interning is how code passes locally and fails under a different build.

  </details>

- **OPTIONAL** — Copy-on-write and why forking is not free

  <details><summary><strong>Answer</strong></summary>

  A `fork` shares parent memory copy-on-write, which looks like a free way to share a large read-only structure with worker processes. Refcounting defeats it: merely reading an object touches its refcount field, dirtying the page and forcing a copy.

  That is the concrete reason a preloaded multi-gigabyte dataset in a gunicorn parent does not stay shared, and why the workarounds are `multiprocessing.shared_memory`, an `mmap`, or keeping the data in a native structure such as a NumPy array whose bulk does not carry per-element refcounts.

  </details>

## 3. Pass by Object Reference

**Why it comes up:** it is asked as "is Python pass by value or by reference", and both answers are wrong, so it separates people who have read a definition from people who can reason about names and objects.

- **MUST** — Neither by value nor by reference: names are bound to objects

  <details><summary><strong>Answer</strong></summary>

  Calling a function binds the parameter name to the *same object* the caller passed — no copy is made, and no alias to the caller's variable is created. The usual name for this is **pass by object reference** or call by sharing. The reference itself is passed by value, which is precisely why the two classical answers are both wrong.

  The practical rule follows directly: mutating the object through the parameter is visible to the caller, and rebinding the parameter is not. `items.append(1)` changes the caller's list; `items = [1]` does not.

  </details>

- **MUST** — Rebinding versus mutation, including the augmented-assignment trap

  <details><summary><strong>Answer</strong></summary>

  `x += y` is not sugar for `x = x + y`. It calls `__iadd__` if the type defines one, which mutates in place and returns `self`, and falls back to `__add__` plus a rebind if it does not. So `+=` on a list passed into a function mutates the caller's list, while `+=` on a tuple or an integer creates a new object and rebinds locally.

  The sharpest demonstration is `t = ([1],); t[0] += [2]` — the list is extended *and* a `TypeError` is raised, because `__iadd__` succeeded and the subsequent store into the tuple failed.

  </details>

- **MUST** — Scope rules: [LEGB](https://docs.python.org/3/reference/executionmodel.html "Local, Enclosing, Global, Built-in — Names the order in which Python resolves a variable name"), global and nonlocal

  <details><summary><strong>Answer</strong></summary>

  A name is looked up Local, Enclosing, Global, Built-in, and the decision about which scope a name belongs to is made **at compile time from assignment**: if a function assigns to a name anywhere in its body, that name is local throughout, which is why reading it before the assignment raises `UnboundLocalError` rather than falling through to the global.

  `global` and `nonlocal` change that classification, the first to module scope and the second to the nearest enclosing function scope. Needing either is usually a signal that the state wants to be an argument, a return value or an attribute instead.

  </details>

- **MUST** — Returning against mutating: pick one contract

  <details><summary><strong>Answer</strong></summary>

  The standard library is consistent about this and worth imitating: `list.sort` mutates and returns `None`, `sorted` returns a new list and leaves the input alone. A function that both mutates its argument and returns it invites `b = f(a)` followed by surprise that `a` changed too.

  **The rule is** to return `None` when you mutate, and to leave the argument untouched when you return a value. It makes the call site readable without checking the implementation, which is the whole reason the convention exists.

  </details>

- **NICE** — Defensive copying at a boundary

  <details><summary><strong>Answer</strong></summary>

  A function that stores a caller's mutable argument has taken a shared reference, and the caller can change it afterwards. The options are to copy on entry, to accept an immutable type in the signature such as `Sequence` or `tuple`, or to document that ownership transfers.

  The judgment is about where the boundary is: copying on every internal call is waste, and copying at a public API edge or before storing in a long-lived structure is cheap insurance.

  </details>

- **NICE** — Tuple unpacking and evaluation order

  <details><summary><strong>Answer</strong></summary>

  `a, b = b, a` works because the right-hand side is fully evaluated into a tuple before any binding happens, which is also why it needs no temporary variable. Extended unpacking — `first, *rest = seq` — follows the same rule and materialises `rest` as a list.

  Evaluation is left to right throughout, including function arguments, so an argument with a side effect runs before the call and in the order written.

  </details>

- **OPTIONAL** — Why the identity question is usually the wrong one

  <details><summary><strong>Answer</strong></summary>

  `id()` returns the memory address in CPython and a different implementation is free to return anything unique. Reasoning about semantics from `id()` output is reasoning from one interpreter's allocator, which is exactly the habit that produces code that works until it does not.

  </details>

## 4. Reference Counting and Garbage Collection

**Why it comes up:** it explains both the GIL and the memory profile of a long-running service, and the cycle collector is where "why is my process still growing" is usually answered.

- **MUST** — Reference counting as the primary mechanism

  <details><summary><strong>Answer</strong></summary>

  Every CPython object carries a count of how many references point at it; the count is incremented on binding and passing, decremented on rebinding, scope exit and container deletion, and the object is freed the instant it reaches zero. The upside is determinism — a file closed by refcount is closed at the end of the statement, not at some later collection — and low peak memory.

  The costs are three: the counter field on every object, the write traffic that defeats copy-on-write after a fork, and the mutation of that field on every read, which is the thing the GIL is protecting.

  **The boundary is** that refcounting alone cannot free a cycle, because two objects pointing at each other never reach zero.

  </details>

- **MUST** — The generational cycle collector

  <details><summary><strong>Answer</strong></summary>

  The `gc` module exists solely to find what refcounting cannot: unreachable cycles. It tracks container objects in three generations, and a generation is collected when its allocation-minus-deallocation counter passes a threshold — 700 for generation 0 by default, with 10 and 10 as the multipliers for the older two. Objects that survive a collection are promoted, on the generational hypothesis that most objects die young.

  It only tracks containers. A cycle of pure `int` and `str` cannot exist, so most objects are never examined, and `gc.freeze` before forking moves long-lived startup objects out of the way permanently.

  </details>

- **MUST** — Where cycles come from, and how to break them

  <details><summary><strong>Answer</strong></summary>

  The everyday sources are a parent-child pair where the child holds a back-reference, a closure captured by the object it closes over, an exception whose traceback holds the frame that holds the exception, and a class holding an instance of itself in a registry. None is exotic; the tree-with-parent-pointers case appears in almost every parser and [DOM](https://dom.spec.whatwg.org/ "Document Object Model — Tree representation of a document that programs traverse and modify").

  The fixes are `weakref` for the back-reference, and an explicit `close` or context manager where a resource is involved. **The rule is** never to rely on the cycle collector for anything holding a file handle, a socket or a lock, because you have given up determinism about when it is released.

  </details>

- **MUST** — Why `__del__` is not a destructor

  <details><summary><strong>Answer</strong></summary>

  `__del__` runs when the refcount hits zero, which may be never, may be at interpreter shutdown when module globals are already `None`, and may swallow exceptions raised inside it. Since 3.4 objects with `__del__` no longer make a cycle uncollectable, but the ordering within a cycle remains undefined.

  Use a context manager or an explicit `close` for anything that matters, and treat `__del__` as a last-resort safety net that logs rather than as the place the resource is actually released.

  </details>

- **MUST** — Diagnosing a growing process

  <details><summary><strong>Answer</strong></summary>

  The sequence is `tracemalloc` snapshots compared between two points to find the allocation site, `gc.get_objects` counted by type to see what class is accumulating, and `gc.set_debug(gc.DEBUG_LEAK)` or `gc.garbage` for uncollectable cycles. `objgraph` will draw the reference chain holding something alive.

  In practice a Python service that grows without a leak in the C sense is usually an unbounded cache, a logging handler holding formatted records, or a module-level list someone appends to — and none of those is a garbage collector problem. Allocator fragmentation is the other honest answer: freed memory is not always returned to the operating system, so resident size can stay high with no live objects behind it.

  </details>

- **NICE** — Weak references and `sys.getrefcount`

  <details><summary><strong>Answer</strong></summary>

  `weakref.ref(obj)` points at an object without keeping it alive, which is the standard break for a parent-child cycle and the right structure for a cache that should not prevent collection — `WeakValueDictionary` for cached objects, `WeakKeyDictionary` for metadata attached to objects you do not own.

  `sys.getrefcount` always reports one higher than you expect, because passing the object to the call created a reference. Not every type supports weak references: `int`, `str`, `tuple` and slotted classes without `__weakref__` cannot be referenced weakly.

  </details>

- **OPTIONAL** — Tuning or disabling the collector

  <details><summary><strong>Answer</strong></summary>

  `gc.disable` is a real technique for short-lived batch processes and for latency-sensitive request paths where a generation-2 pass shows up in the tail, but it is only safe if the workload genuinely produces no cycles, and it is easy to be wrong about that.

  The safer version is to raise the thresholds with `gc.set_threshold`, or to call `gc.freeze` after start-up so that everything allocated during import is never scanned again.

  </details>

## 5. Equality, Identity and the Hash Contract

**Why it comes up:** breaking the hash contract produces a dictionary that loses keys, and the failure is silent, so the question tests whether you know the invariant rather than the syntax.

- **MUST** — Equality against identity

  <details><summary><strong>Answer</strong></summary>

  `==` asks the objects whether they are equal, dispatching to `__eq__`; `is` asks whether they are the same object, comparing identity, and can never be overridden. The default `__eq__` inherited from `object` *is* identity, which is why two distinct instances of a plain class compare unequal until you define one.

  Use `is` for `None`, `True`, `False` and sentinels, and `==` for everything else. The specific trap is a value that overrides `__eq__` oddly — a NumPy array returns an array from `==`, so `if arr == other` raises rather than returning a bool.

  </details>

- **MUST** — The contract between equality and hashing

  <details><summary><strong>Answer</strong></summary>

  **The rule is** one-directional: objects that compare equal must have the same hash. Unequal objects may share a hash — that is a collision, and the dict handles it by comparing with `==` within the bucket.

  Breaking it breaks dictionaries silently. A lookup computes the hash, goes to a bucket, and never finds an equal key sitting in a different bucket, so `d[k]` raises `KeyError` for a key that is demonstrably `in` the list of keys. The second half of the contract is stability: a key's hash must not change while it is in a dict, which is why mutable objects are unhashable by design.

  </details>

- **MUST** — What defining one does to the other

  <details><summary><strong>Answer</strong></summary>

  Defining `__eq__` sets `__hash__` to `None`, making instances unhashable. That is deliberate — the inherited identity hash would be inconsistent with your new equality — and it is why adding an `__eq__` to an existing class suddenly breaks code that put instances in a set.

  To get both, define `__hash__` explicitly as a tuple of the same fields the equality uses: `def __hash__(self): return hash((self.a, self.b))`. `@dataclass(eq=True, frozen=True)` does exactly this for you, and `@dataclass(eq=True)` alone reproduces the unhashable result, which surprises people who expected the decorator to handle it.

  </details>

- **NICE** — Implementing equality without breaking symmetry

  <details><summary><strong>Answer</strong></summary>

  `__eq__` should return `NotImplemented` for a type it does not recognise rather than `False`, which lets Python try the reflected operation on the other operand and keeps subclass and mixed-type comparisons symmetric. Returning `False` blindly means `a == b` and `b == a` can disagree.

  `functools.total_ordering` fills in the remaining comparison methods from `__eq__` and one of `__lt__`, at a small performance cost compared to writing all four.

  </details>

- **NICE** — Hash randomisation

  <details><summary><strong>Answer</strong></summary>

  Since 3.3, `str` and `bytes` hashes are salted per process by default, so the same string hashes differently in two runs. It exists to stop an attacker feeding an application keys that all collide and turning a dict into a linked list — a denial-of-service class that hit several web frameworks.

  The consequences to know: never persist or compare a `hash()` across processes, use `hashlib` for anything that must be stable, and set `PYTHONHASHSEED` only to reproduce a specific run.

  </details>

- **NICE** — Comparing floating point values

  <details><summary><strong>Answer</strong></summary>

  `0.1 + 0.2 == 0.3` is False because binary floating point cannot represent those decimals exactly, so `==` on computed floats is the wrong tool. `math.isclose(a, b)` with an explicit tolerance is the comparison to use, and `Decimal` is the type to use when the values are money and the decimal digits are the point.

  This is not a Python quirk — it is IEEE 754 — but saying so and naming `Decimal` for currency is the answer an interviewer is listening for.

  </details>

- **OPTIONAL** — The dictionary side of the same contract

  <details><summary><strong>Answer</strong></summary>

  Two keys are the same key if they are equal and hash equally, which is why `d[1]`, `d[1.0]` and `d[True]` are one entry — the numeric tower makes them equal and CPython hashes them identically. It is a reasonable curiosity question and a genuine source of bugs in code that mixes booleans and integer keys.

  </details>

## 6. The CPython Interpreter Model

**Why it comes up:** it is the layer under the GIL, refcounting and every "why is Python slow" answer, and knowing it stops those answers from being folklore.

- **MUST** — Source to bytecode to the eval loop

  <details><summary><strong>Answer</strong></summary>

  CPython parses the source to an [AST](https://docs.python.org/3/library/ast.html "Abstract Syntax Tree — Tree representation of parsed source code that tools analyse and transform"), compiles that to **bytecode** — a flat instruction sequence for a stack machine — and executes it in the eval loop, a large dispatch over opcodes operating on a value stack per frame. `dis.dis` shows the instructions for any function, and reading it is the fastest way to settle arguments about what a construct actually costs.

  Python is therefore compiled and interpreted, not one or the other: compilation to bytecode happens ahead of execution, and the bytecode is interpreted rather than run natively. The absence of a native compilation step, plus the fact that every operand is a heap object whose type is resolved at run time, is the honest reason for the speed difference against C.

  </details>

- **MUST** — What `.pyc` caching does and does not do

  <details><summary><strong>Answer</strong></summary>

  On first import a module's bytecode is written to `__pycache__/name.cpython-312.pyc` and reused on subsequent imports while it is valid. Validation is by default the source's modification time and size, and can be switched to a hash of the source with `py_compile` for reproducible builds and containers where timestamps are unreliable.

  The boundary worth stating: it caches *compilation*, not execution, so it saves import time only. The top-level code of a module still runs on every import, and a slow import is almost always work being done at module level rather than parsing.

  </details>

- **MUST** — Why Python is slow, stated precisely

  <details><summary><strong>Answer</strong></summary>

  Three costs, in order of size: every value is a heap-allocated object with a header, so an integer addition means unboxing two objects and allocating a third; every operation dispatches dynamically through the type's method table because the type is not known until run time; and the eval loop itself costs an indirect branch per instruction.

  This is why the standard remedies are the ones that leave the loop — push the loop into C with NumPy or a library, cache with `functools.lru_cache`, or move the hot function into Cython or Rust. Micro-optimising Python inside the loop moves single-digit percentages; leaving the loop moves orders of magnitude.

  </details>

- **MUST** — Bytecode is not a security boundary

  <details><summary><strong>Answer</strong></summary>

  A `.pyc` file is trivially disassembled with `dis` and largely reconstructible with a decompiler, so shipping compiled Python is not obfuscation and certainly not protection. Anything embedded in the source — a key, a token, a password — is readable by whoever has the file.

  The same reasoning applies to `__private` attributes, to a `SECRET` constant and to client-side checks in general. Secrets come from the environment or a secret store at run time, and the boundary that actually holds is the one the server enforces.

  </details>

- **NICE** — The specialising adaptive interpreter

  <details><summary><strong>Answer</strong></summary>

  Since 3.11 the interpreter watches hot code and rewrites generic opcodes into specialised ones — `BINARY_OP` becomes an integer-specific variant once it has only ever seen integers — with a guard that falls back when the assumption breaks. 3.13 added a copy-and-patch [JIT](https://en.wikipedia.org/wiki/Just-in-time_compilation "Just In Time compilation — Compiles code to machine instructions during execution rather than ahead of time") behind a build flag, still modest in effect.

  The reason to know it is that Python-level micro-benchmarks now depend on warm-up, and that the old folklore optimisations such as hoisting `len` into a local are worth much less than they were.

  </details>

- **NICE** — Frames, tracebacks and their cost

  <details><summary><strong>Answer</strong></summary>

  Each call allocates a frame object holding the value stack, local variables and a pointer to the caller, which is what makes tracebacks and `inspect` possible and what makes Python function calls comparatively expensive. The default recursion limit of 1000 is a guard against blowing the C stack, not a language limit on recursion depth.

  Since 3.11 frames are lazily materialised and calls to Python functions are inlined into the eval loop rather than recursing into C, which is where a large part of that release's speed-up came from.

  </details>

- **OPTIONAL** — Other implementations and what they trade

  <details><summary><strong>Answer</strong></summary>

  PyPy is a tracing JIT that is several times faster on long-running pure-Python workloads and weaker where C extensions dominate; MicroPython targets microcontrollers; GraalPy runs on the JVM. Each trades ecosystem compatibility for its gain, which is why CPython remains the default despite being the slowest.

  </details>

## 7. Shallow and Deep Copy

**Why it comes up:** it is a short question with a precise answer, and the follow-up about shared nested state is where real bugs live.

- **MUST** — What each one copies

  <details><summary><strong>Answer</strong></summary>

  A **shallow copy** — `list(x)`, `x[:]`, `x.copy()`, `copy.copy(x)` — makes a new outer container holding references to the same inner objects. A **deep copy** — `copy.deepcopy(x)` — recursively copies the whole object graph, so nothing is shared.

  The consequence is the one that bites: after `b = a.copy()` on a list of dicts, `b.append(...)` leaves `a` alone but `b[0]["k"] = 1` changes `a[0]` too. Most "why did my original change" bugs are a shallow copy of a nested structure.

  </details>

- **MUST** — What `deepcopy` costs and where it breaks

  <details><summary><strong>Answer</strong></summary>

  It walks the entire reachable graph, so it is slow on anything large, and it keeps a memo dictionary keyed by `id()` so that shared references stay shared and cycles terminate rather than recursing forever.

  Where it breaks is on objects that are not values: a socket, a file handle, a database connection, a lock or a thread will be copied or will raise, and either outcome is wrong. `__deepcopy__` and `__copy__` let a class control this, and `copy.deepcopy` with the `memo` argument lets you pre-seed objects that should be shared rather than copied.

  **In practice** the better answer is usually to avoid needing it — rebuild from a serialisable representation, or use immutable values so that copying is unnecessary.

  </details>

- **MUST** — The idioms that look like copies and are not

  <details><summary><strong>Answer</strong></summary>

  `b = a` binds a second name to the same object and copies nothing. `[[0] * 3] * 3` creates three references to *one* list, so writing to one row writes to all three — the correct form is a comprehension. `dict(a)` and `{**a}` are shallow, and so is a `@dataclass` `replace`.

  </details>

- **MUST** — Copying a dataclass, a model or an array

  <details><summary><strong>Answer</strong></summary>

  `dataclasses.replace(obj, x=1)` builds a new instance with fields substituted and is shallow, so nested mutables stay shared. A [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") model has `model_copy(deep=True)` for the deep variant. A NumPy slice is a **view**, not a copy, so writing through it changes the original, and `arr.copy()` is the explicit break.

  The generalisation is that every library has its own answer and the default is nearly always shallow. Assuming otherwise is where the bug enters.

  </details>

- **NICE** — Controlling how your class is copied

  <details><summary><strong>Answer</strong></summary>

  `__copy__` and `__deepcopy__` let a class define both operations, and `__deepcopy__` receives the memo dict so it can pass it down to nested copies and keep shared references shared. `__reduce__` serves both `copy` and `pickle` at once.

  The usual reason to implement them is a resource member: copy the value fields, and reopen or share the connection deliberately rather than letting `deepcopy` try.

  </details>

- **OPTIONAL** — Copy by serialisation

  <details><summary><strong>Answer</strong></summary>

  `pickle.loads(pickle.dumps(x))` is sometimes faster than `deepcopy` for large plain-data structures because it avoids per-object Python-level dispatch. It changes the semantics, though: it will not preserve object identity sharing outside its own memo, it silently fails on unpicklable members, and it must never be used on data that crossed a trust boundary.

  </details>

- **OPTIONAL** — Copying in a concurrent context

  <details><summary><strong>Answer</strong></summary>

  A copy is not atomic. Copying a list while another thread appends to it can raise or produce a torn view, so the copy belongs inside whatever lock protects the structure — or the structure should be replaced wholesale by rebinding, since name rebinding is atomic.

  </details>

## 8. Version Differences Worth Naming

**Why it comes up:** it is a proxy for whether you have kept current, and the specific features you reach for say more than the version numbers you can recite.

- **MUST** — What Python 3 actually changed

  <details><summary><strong>Answer</strong></summary>

  The change that forced the break was text: `str` became Unicode and `bytes` a separate type with no implicit conversion between them, which is why the migration could not be automatic and why a 2-to-3 port surfaced every place encoding had been assumed. The rest — `print` as a function, integer division as `/` and `//`, iterators instead of lists from `range`, `dict.keys` and `map` — is small by comparison.

  Python 2 has been end-of-life since January 2020. The honest answer about a legacy codebase is the encoding boundary and the C extensions, not the print statement.

  </details>

- **MUST** — f-strings

  <details><summary><strong>Answer</strong></summary>

  Introduced in 3.6, they are compiled to concatenation rather than parsed at run time, so they are the fastest of the formatting options as well as the most readable. `f"{value!r}"` applies `repr`, `f"{value:.2f}"` applies the format spec, and `f"{value=}"` from 3.8 prints the expression text alongside its value, which replaces most debug `print` calls.

  The boundary: never use an f-string to build [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") or a shell command, because the whole point of a parameterised query is that the value never becomes part of the statement text. Logging is the other exception — `logger.info("x=%s", x)` defers the formatting until the record is actually emitted.

  </details>

- **MUST** — Dataclasses

  <details><summary><strong>Answer</strong></summary>

  `@dataclass` generates `__init__`, `__repr__` and `__eq__` from annotated class attributes, with `frozen`, `slots`, `order` and `kw_only` as options. It removes the boilerplate that made people reach for a dict or a tuple where a type was wanted.

  What it is not is validation: annotations are not checked at run time, so `Point(x="hello")` constructs happily. That is the line between a dataclass and a Pydantic model — the first is a code generator, the second is a validator, and choosing between them is choosing whether the data is already trusted.

  </details>

- **MUST** — The walrus operator

  <details><summary><strong>Answer</strong></summary>

  `:=` assigns inside an expression, which earns its place in three shapes: `while (chunk := f.read(8192)):`, a comprehension filter that needs the computed value it filtered on, and an `if` that wants the match object it just tested. Anywhere else it costs more readability than it saves lines.

  </details>

- **MUST** — Structural pattern matching

  <details><summary><strong>Answer</strong></summary>

  `match` from 3.10 destructures as it dispatches — it matches against shapes of sequences, mappings and classes, binds names from the parts it matched, and supports guards. It is not a C `switch`, and using it as one is a waste.

  The trap to name is that a bare lowercase name in a pattern is a capture, not a comparison, so `case HTTP_OK:` binds the name rather than testing against the constant; a dotted name such as `case status.OK:` compares.

  </details>

- **MUST** — Modern typing syntax

  <details><summary><strong>Answer</strong></summary>

  Builtin generics from 3.9 mean `list[int]` rather than `typing.List[int]`; `X | None` from 3.10 replaces `Optional[X]`; and the 3.12 syntax `def f[T](x: T) -> T` declares a type parameter without a module-level `TypeVar`. From 3.14 annotations are evaluated lazily by default, which removes most of the reason for `from __future__ import annotations`.

  </details>

- **OPTIONAL** — Other changes worth a sentence

  <details><summary><strong>Answer</strong></summary>

  Exception groups and `except*` from 3.11 for concurrent failures; `asyncio.TaskGroup` and `timeout` from the same release; dictionaries keeping insertion order as a guarantee from 3.7; `zoneinfo` from 3.9 removing the need for `pytz`; and the 3.11 and 3.12 interpreter speed-ups, which are real and free.

  </details>

## Data Model Topics


## 9. Decorators and Closures

**Why it comes up:** it is the most-asked data-model question, it requires closures, first-class functions and argument forwarding all at once, and almost every framework the candidate has used is built from it.

- **MUST** — What a decorator is

  <details><summary><strong>Answer</strong></summary>

  A **decorator** is a callable that takes a function and returns a replacement, and `@dec` above a `def` is exactly `f = dec(f)` after the definition. Nothing else is special about it; the syntax is sugar over a rebinding.

  The usual shape wraps the original in a closure that does something before and after, forwarding arguments with `*args, **kwargs` and returning the result. Because the name now refers to the wrapper, the decorator can log, time, retry, cache, authorise or register without the wrapped function knowing.

  </details>

- **MUST** — Why `functools.wraps` is not optional

  <details><summary><strong>Answer</strong></summary>

  Without it the decorated name carries the wrapper's identity: `__name__` becomes `wrapper`, the docstring disappears, `__module__`, `__qualname__` and `__annotations__` are wrong, and `__wrapped__` is absent. That breaks `help`, breaks introspection-driven frameworks that read signatures, and produces logs and tracebacks naming `wrapper` for every decorated function in the codebase.

  `@functools.wraps(func)` on the wrapper copies that metadata across and sets `__wrapped__` so `inspect.signature` can see through. **The tell is** whether a candidate reaches for it unprompted, because it is the difference between having written a decorator and having debugged one.

  </details>

- **MUST** — Closures and late binding

  <details><summary><strong>Answer</strong></summary>

  A **closure** is a function plus the enclosing variables it references, captured as cells visible in `__closure__`. The capture is by reference, not by value, so the closure sees the variable's value at call time rather than at definition time.

  That is the source of the classic bug: `[lambda: i for i in range(3)]` yields three functions that all return 2, because they share one `i` that has finished looping. The fix is a default argument, `lambda i=i: i`, which is evaluated at definition time — the same mechanism that makes mutable defaults dangerous, used deliberately.

  </details>

- **MUST** — Decorators that take arguments

  <details><summary><strong>Answer</strong></summary>

  A parameterised decorator is a function returning a decorator, so there are three nested levels and `@retry(times=3)` is called before it is applied: `retry(times=3)` runs first and its return value receives the function.

  This is where most implementations go wrong, usually by forgetting that `@retry` without parentheses then passes the function where `times` was expected. Supporting both forms means checking whether the single argument is callable, which is worth doing only for a decorator with a genuinely common no-argument case.

  </details>

- **MUST** — Stateful decorators and the ones in the standard library

  <details><summary><strong>Answer</strong></summary>

  State can live in the closure, on the wrapper as an attribute, or in a class with `__call__`; the class form is clearest once there is more than one piece of state. The library already provides the ones worth knowing: `functools.lru_cache` and `cache`, `cached_property`, `singledispatch` for type-based dispatch, `contextlib.contextmanager`, and `staticmethod`, `classmethod` and `property`, which are decorators rather than keywords.

  </details>

- **NICE** — Class decorators and decorating methods

  <details><summary><strong>Answer</strong></summary>

  A decorator applied to a class receives and returns the class, which is how `@dataclass` and `@functools.total_ordering` work — a lighter tool than a metaclass for the same jobs. Decorating a method is unchanged in principle, but the wrapper must accept `self` as its first positional argument like any other.

  Order matters and reads bottom-up: the decorator nearest the `def` is applied first, so `@app.route` above `@login_required` registers the authorised version, and swapping them registers the unprotected one.

  </details>

- **OPTIONAL** — What decorators cost

  <details><summary><strong>Answer</strong></summary>

  Every layer adds a Python-level call to every invocation, which is measurable on a hot function called millions of times and irrelevant anywhere else. The larger cost is diagnostic: a stack of four decorators makes a traceback harder to read and a signature harder to trust, which is an argument for depth, not for avoidance.

  </details>

## 10. Iterators and Iterables

**Why it comes up:** it is the protocol every `for` loop, comprehension and unpacking in the language is built on, and the iterable-against-iterator distinction explains a whole family of "the second loop was empty" bugs.

- **MUST** — The protocol, and the difference between the two words

  <details><summary><strong>Answer</strong></summary>

  An **iterable** implements `__iter__` and returns a fresh iterator each time; an **iterator** implements `__next__`, returns successive values and raises `StopIteration` when exhausted, and also implements `__iter__` returning itself so it can be used where an iterable is expected.

  A list is an iterable and not an iterator: you can loop over it twice because each loop calls `__iter__` and gets a new cursor. A generator is its own iterator, which is why looping over it twice gives you the values once and then nothing — and why passing one to two functions in sequence leaves the second with an empty stream.

  </details>

- **MUST** — What `for` actually does

  <details><summary><strong>Answer</strong></summary>

  `for x in obj` calls `iter(obj)` once, then `next()` repeatedly until `StopIteration` is raised, which the loop catches and turns into a normal exit. That is the whole mechanism, and knowing it explains the surprises: mutating a list while looping over it skips elements because the cursor is an index, and a `StopIteration` raised accidentally inside a loop body used to end the loop silently.

  `iter` also has an older fallback, the sequence protocol — an object with `__getitem__` taking integers from 0 is iterable without `__iter__` at all.

  </details>

- **MUST** — Writing one, and why generators usually win

  <details><summary><strong>Answer</strong></summary>

  The class form needs `__iter__` returning `self` and `__next__` maintaining the position and raising `StopIteration` at the end — roughly fifteen lines, all of it state management you have to keep correct.

  The generator form is the same thing in three lines, because `yield` makes the compiler write the state machine. Reach for the class only when the iterator needs a public API beyond iteration, such as a `reset`, a `peek` or an introspectable position.

  </details>

- **MUST** — Lazy evaluation and the memory argument

  <details><summary><strong>Answer</strong></summary>

  An iterator produces values on demand, so a pipeline over a ten-gigabyte file holds one line at a time, and `itertools.count` or a socket reader can be unbounded. That is the actual reason `range`, `map`, `filter`, `zip` and `dict.keys` return lazy objects in Python 3 rather than lists.

  **The cost is** that laziness is single-pass and its errors are deferred: an exception inside a generator surfaces where it is consumed, not where it was created, which makes a traceback point at the wrong layer.

  </details>

- **NICE** — `itertools` as the vocabulary

  <details><summary><strong>Answer</strong></summary>

  `chain` to concatenate, `islice` to take a window without materialising, `groupby` which requires its input already sorted by the key, `tee` to fan a stream into two — with the caveat that it buffers whatever the slower consumer has not read, `zip_longest`, `product` and `combinations`, and `batched` from 3.12 for chunking.

  Using them signals fluency, because each replaces a hand-rolled loop that is usually slightly wrong at the boundaries.

  </details>

- **NICE** — `enumerate`, `zip` and the silent truncation

  <details><summary><strong>Answer</strong></summary>

  `enumerate(it, start=1)` replaces an index counter, and `zip` walks several iterables in step — stopping at the **shortest** without complaint, which silently drops data when the inputs were supposed to be the same length. `zip(a, b, strict=True)` from 3.10 raises instead, and is the right default for anything you did not construct yourself.

  `itertools.zip_longest` is the other direction, padding with a fill value.

  </details>

- **OPTIONAL** — The sentinel form of `iter`

  <details><summary><strong>Answer</strong></summary>

  `iter(callable, sentinel)` calls the callable repeatedly until it returns the sentinel, which turns any `read`-style function into an iterator: `for chunk in iter(lambda: f.read(4096), b"")`. It is rarely known and occasionally exactly right.

  </details>

## 11. Generators

**Why it comes up:** it is the lazy-evaluation question, and `yield from` plus `send` is the bridge to how coroutines and `await` were built.

- **MUST** — What `yield` does to a function

  <details><summary><strong>Answer</strong></summary>

  A function containing `yield` anywhere becomes a **generator function**: calling it runs no body at all and returns a generator object. Each `next()` runs to the next `yield`, produces that value and suspends, preserving local variables and the instruction pointer in the frame; the frame survives between calls instead of being discarded.

  On exhaustion the function returns, which raises `StopIteration` — carrying the return value in `StopIteration.value` if there was one. **The consequence is** that nothing in the body executes until the first `next`, so argument validation written at the top of a generator function never fires when the caller expects it; the usual fix is a plain wrapper function that validates and then returns the generator.

  </details>

- **MUST** — What they buy

  <details><summary><strong>Answer</strong></summary>

  Constant memory over an arbitrarily long stream, and composition: generators chain into pipelines where each stage pulls from the one before, so a filter over a parse over a read never materialises an intermediate list. Time-to-first-result also improves, since the consumer sees element one before element two is computed.

  The costs are that they are single-pass and not indexable, that `len` does not work, and that a traceback from inside a pipeline is harder to read. Where the data fits comfortably in memory and is traversed repeatedly, a list is the simpler choice.

  </details>

- **MUST** — Generator expressions against list comprehensions

  <details><summary><strong>Answer</strong></summary>

  `(x*2 for x in it)` builds nothing and evaluates lazily; `[x*2 for x in it]` builds the whole list. Pass a generator expression to `sum`, `any`, `all`, `min` or `max` and the extra brackets are pure waste — `sum(x for x in it)` never allocates.

  The exception worth naming is `"".join`, which materialises internally anyway to size the result, so a list comprehension is marginally faster there. And a generator expression can only be consumed once, so assigning one to a name that is iterated twice is a silent bug.

  </details>

- **MUST** — `yield from` and delegation

  <details><summary><strong>Answer</strong></summary>

  `yield from sub()` delegates the whole protocol to a sub-generator: values flow out, `send` and `throw` flow in, and the sub-generator's return value becomes the value of the expression. Writing the equivalent by hand correctly is about fifteen lines, which is why it was added.

  It is also the mechanism generator-based coroutines were built on before `async def`, which is the connection worth drawing: `await` is the same suspend-and-delegate idea with a dedicated syntax and a scheduler behind it.

  </details>

- **NICE** — Two-way generators: `send`, `throw` and `close`

  <details><summary><strong>Answer</strong></summary>

  `gen.send(value)` resumes the generator and makes the paused `yield` expression evaluate to `value`, which turns a generator into a consumer — a running average, a state machine, an accumulating sink. The generator must be primed with one `next()` first, since there is no paused `yield` to receive the value otherwise.

  `close` raises `GeneratorExit` at the suspension point, which is why cleanup in a generator belongs in `try/finally` rather than after the loop, and `contextlib.contextmanager` is built on exactly that pairing.

  </details>

- **NICE** — Async generators and `async for`

  <details><summary><strong>Answer</strong></summary>

  An `async def` function containing `yield` is an asynchronous generator, consumed with `async for` and closed with `aclose`. It is the natural shape for streaming a paginated API or a database cursor without loading everything, because each batch can be awaited.

  The care needed is cleanup: an async generator abandoned without `aclose` has its finalisation deferred to the loop's shutdown hook, so `contextlib.aclosing` is the safe wrapper when you might break out early.

  </details>

- **OPTIONAL** — Generators as a coroutine substrate

  <details><summary><strong>Answer</strong></summary>

  Before 3.5 an event loop drove `yield`-based coroutines directly, and `@asyncio.coroutine` with `yield from` was the idiom. Knowing this makes `async def` demystified rather than magic, and it explains why an `async` function shares the "nothing runs until it is driven" property with a generator.

  </details>

## 12. Context Managers

**Why it comes up:** it is the answer to every "how do you guarantee cleanup" question, and `__exit__` returning a truthy value is a favourite follow-up.

- **MUST** — The protocol and what `with` guarantees

  <details><summary><strong>Answer</strong></summary>

  `with expr as name` calls `__enter__` on the object and binds its return value to `name`, then calls `__exit__(exc_type, exc_value, traceback)` when the block leaves — normally, by exception, by `return`, or by `break`. The guarantee is that `__exit__` runs on every path out of the block, which is what makes it stronger than a `try/finally` someone has to remember to write.

  `__enter__` commonly returns `self`, but not always: `open` returns the file, and a lock returns `None`, which is why `with lock:` has no `as` clause.

  </details>

- **MUST** — Suppressing exceptions from `__exit__`

  <details><summary><strong>Answer</strong></summary>

  Returning a truthy value from `__exit__` **swallows the exception** and execution continues after the `with` block. Returning `None` — which a function without an explicit return does — lets it propagate, which is almost always what you want.

  The trap is accidental: an `__exit__` that ends with a call returning something truthy silences every error in the block. `contextlib.suppress(FileNotFoundError)` is the explicit, readable version when suppression genuinely is intended, and it is narrow by construction because you must name the type.

  </details>

- **MUST** — The `contextmanager` decorator

  <details><summary><strong>Answer</strong></summary>

  `@contextlib.contextmanager` turns a generator with exactly one `yield` into a context manager: everything before the `yield` is `__enter__`, the yielded value is what `as` binds, and everything after is `__exit__`.

  Cleanup must be in a `finally`, because an exception in the body is thrown back in at the `yield` and will skip any plain trailing code. To suppress an exception in this form you catch it and do not re-raise; returning a value has no effect, which is a real difference from the class form.

  </details>

- **MUST** — The rest of `contextlib`

  <details><summary><strong>Answer</strong></summary>

  `ExitStack` for a number of managers not known until run time — entering a variable list of files, or registering a rollback that is cancelled on success with `pop_all`. `closing` to adapt an object that has `close` but no protocol. `suppress` for narrow, explicit silence. `redirect_stdout` for capturing output from code you do not control. `asynccontextmanager` and `AsyncExitStack` for the `async with` equivalents.

  </details>

- **NICE** — Reentrancy and reuse

  <details><summary><strong>Answer</strong></summary>

  A `@contextmanager` generator is single-use: the generator is exhausted after one block, so reusing the same object raises. Class-based managers may be reusable and may be reentrant, but only if written to be, which usually means holding a counter or a stack rather than a single piece of state.

  `threading.RLock` is the standard example of deliberate reentrancy, and the reason a plain `Lock` deadlocks against itself if a method holding it calls another method that takes it.

  </details>

- **NICE** — Where `try/finally` still wins

  <details><summary><strong>Answer</strong></summary>

  `with` is a `try/finally` with the cleanup bound to the object rather than written at the call site, which is why it is preferred: it cannot be forgotten and cannot be got wrong twice. `try/finally` is still the right tool when the cleanup is specific to this one block, or when acquisition and release are not symmetrical.

  `try/except/finally` also remains the place for the error handling itself — a context manager decides whether an exception propagates, not what to do about it.

  </details>

- **OPTIONAL** — Where they replace a decorator

  <details><summary><strong>Answer</strong></summary>

  `contextlib.ContextDecorator` lets one object serve as both `with` block and `@decorator`, which is convenient for timing and tracing helpers that are sometimes wanted around a whole function and sometimes around a few lines.

  </details>

## 13. Dunder Methods and the Protocols

**Why it comes up:** it is the question behind "how does Python know what to do with your object", and naming the protocol rather than the method is what distinguishes a considered answer.

- **MUST** — What they are and how dispatch works

  <details><summary><strong>Answer</strong></summary>

  **Dunder methods** are the hooks the interpreter calls for syntax: `len(x)` calls `type(x).__len__(x)`, `x[k]` calls `__getitem__`, `x + y` calls `__add__`, and `with x` calls `__enter__` and `__exit__`. Implementing the method is what makes a class participate in the language rather than merely hold data.

  Dispatch for implicit invocations is on the **type, not the instance**, so assigning `obj.__len__ = ...` does not change what `len(obj)` does. That is a deliberate optimisation and a regular source of confusion when someone tries to patch a single object.

  </details>

- **MUST** — The protocols worth naming

  <details><summary><strong>Answer</strong></summary>

  Grouping them is the answer: iteration is `__iter__` and `__next__`; container is `__len__`, `__getitem__`, `__setitem__`, `__contains__`; representation is `__repr__` and `__str__`; comparison is `__eq__`, `__lt__` and the rest; numeric is `__add__` and its reflected and in-place variants; callable is `__call__`; context is `__enter__` and `__exit__`; attribute access is `__getattr__`, `__getattribute__` and `__setattr__`; async is `__aiter__`, `__anext__`, `__aenter__`, `__aexit__` and `__await__`.

  You get the behaviour for free once the protocol is satisfied: define `__eq__` and `__lt__` and `sorted` works; define `__len__` and `__getitem__` and looping, `in`, and reversed iteration follow.

  </details>

- **MUST** — `__repr__` against `__str__`

  <details><summary><strong>Answer</strong></summary>

  `__repr__` is for developers and should be unambiguous, ideally something that could be evaluated to reconstruct the object; `__str__` is for users and may be lossy. `str` falls back to `repr` when `__str__` is absent, so a class with only one should have `__repr__`.

  This matters at three in the morning: a container prints its elements with `repr`, so a list of objects with the default `<Order object at 0x7f...>` tells you nothing, and half a minute spent writing `__repr__` pays for itself in every log line and debugger session thereafter.

  </details>

- **NICE** — `__getattr__` against `__getattribute__`

  <details><summary><strong>Answer</strong></summary>

  `__getattribute__` intercepts **every** attribute access and is easy to make infinitely recursive, since any `self.x` inside it re-enters; `__getattr__` is called only when normal lookup has already failed, which makes it the safe hook for proxies, lazy loading and dynamic attributes.

  The rule is to use `__getattr__` unless you genuinely need to intercept existing attributes, and to delegate through `object.__getattribute__` or `super()` when you do.

  </details>

- **NICE** — Truthiness, hashing and the defaults you inherit

  <details><summary><strong>Answer</strong></summary>

  `bool(x)` uses `__bool__`, falls back to `__len__`, and defaults to True — so an empty custom container is truthy unless you define one of them, which is a quiet bug in code that writes `if collection:`. Equality defaults to identity, hashing defaults to an identity-derived value, and defining `__eq__` removes the default hash.

  </details>

- **NICE** — Making a container behave like one

  <details><summary><strong>Answer</strong></summary>

  Implementing `__len__`, `__getitem__`, `__setitem__`, `__contains__` and `__iter__` gets you indexing, `in`, looping, unpacking and most of what code expects of a sequence. `__getitem__` receives a `slice` object when called with `a[1:5]`, so honouring slices means handling both an integer and a slice.

  Inheriting from `collections.abc.Sequence` or `MutableMapping` fills in the derived methods from a small required set, which is less code and fewer inconsistencies than writing them all.

  </details>

- **OPTIONAL** — Operator overloading and when to stop

  <details><summary><strong>Answer</strong></summary>

  Reflected methods such as `__radd__` handle the case where the left operand does not know your type, and in-place methods such as `__iadd__` exist so mutable types can avoid an allocation. Overload arithmetic where the analogy is exact — vectors, money, matrices, paths — and not where it is merely clever, because a reader has to guess what `user + group` means.

  </details>

## 14. Method Resolution Order and super

**Why it comes up:** it is the diamond-inheritance question, and the answer reveals whether `super` is understood as cooperative delegation or as "call the parent class".

- **MUST** — What the [MRO](https://docs.python.org/3/howto/mro.html "Method Resolution Order — The linear order in which Python searches classes for an attribute") is and how it is computed

  <details><summary><strong>Answer</strong></summary>

  The **Method Resolution Order** is the linear sequence of classes Python searches for an attribute, visible as `Cls.__mro__`. It is computed by the C3 linearisation, which guarantees that a class precedes its parents, that the order of base classes in the declaration is preserved, and that the result is monotonic — a subclass's order never contradicts a parent's.

  When no such order exists, the class statement itself fails at definition time with `TypeError: Cannot create a consistent method resolution order`, which is a compile-time guard rather than a run-time surprise.

  </details>

- **MUST** — What `super()` actually does

  <details><summary><strong>Answer</strong></summary>

  `super()` does not mean "my parent class". It means the next class after this one in the **MRO** of the instance's type, which depends on the object being constructed and not on where the code was written. In a diamond, `super()` inside the left branch may dispatch into the right branch, a class the author never mentioned.

  That is the whole point: it makes cooperative multiple inheritance possible, so each class in the chain runs exactly once. The consequence is that every class in a cooperative hierarchy must call `super()` and must accept and forward `**kwargs`, because breaking the chain in one class silently skips every class after it.

  </details>

- **MUST** — Mixins, and why they are the practical form

  <details><summary><strong>Answer</strong></summary>

  A mixin is a small class contributing one behaviour, not meant to be instantiated alone, and placed **before** the base class in the declaration so its methods win. It is how logging, serialisation or permission checks get layered onto a framework's base class.

  The discipline that makes them work is narrowness: one concern, no `__init__` state where it can be avoided, and `super()` calls that forward. Where two mixins both want to control the same method, composition or an explicit hook is the better design, because the ordering rules stop being obvious to a reader.

  </details>

- **MUST** — When to prefer composition

  <details><summary><strong>Answer</strong></summary>

  Multiple inheritance is the right tool for orthogonal behaviours with no shared state. Once two bases both hold data, both define `__init__` and both expect to be the primary, the MRO is being asked to express a relationship that is really delegation, and holding an instance as an attribute is clearer and easier to test.

  </details>

- **NICE** — The two-argument form and its uses

  <details><summary><strong>Answer</strong></summary>

  `super(Cls, self)` starts the search after `Cls` rather than after the current class, which is what you need outside a method body, in a `classmethod` with `super(Cls, cls)`, or when deliberately skipping a level. The zero-argument form works only inside a class body, where the compiler supplies `__class__` as a closure cell.

  </details>

- **NICE** — Diagnosing an inheritance problem

  <details><summary><strong>Answer</strong></summary>

  Print `Cls.__mro__` first — it is the ground truth, and most confusion dissolves on reading it. If a base class's `__init__` never runs, the cause is a class in the chain that did not call `super().__init__`; if an unexpected implementation wins, the cause is declaration order.

  The discipline that prevents both is making every cooperative class accept `**kwargs` and forward them, so that a class it has never heard of can still be inserted into the chain.

  </details>

- **OPTIONAL** — `__init_subclass__` and `__set_name__` as lighter hooks

  <details><summary><strong>Answer</strong></summary>

  `__init_subclass__` runs on the parent whenever a subclass is defined, which covers registration and validation of subclasses without a metaclass, and `__set_name__` lets a descriptor learn the attribute name it was assigned to. Between them they removed most of the remaining reasons to write one.

  </details>

## 15. Class and Instance Attributes

**Why it comes up:** the mutable class attribute shared across instances is the same bug as the mutable default argument in a different costume, and the lookup order underlies descriptors and properties.

- **MUST** — Where an attribute actually lives, and the lookup order

  <details><summary><strong>Answer</strong></summary>

  An instance attribute lives in that object's `__dict__` and belongs to one object; a class attribute lives in the class's namespace and is shared by every instance. Reading `obj.x` searches data descriptors on the type, then the instance `__dict__`, then the classes along the MRO, then non-data descriptors and `__getattr__`.

  Writing `obj.x = 1` always creates or replaces an **instance** attribute, shadowing the class one rather than changing it — so a counter incremented as `self.count += 1` reads the class value once and then writes a per-instance copy, which is why it appears to work and then does not.

  </details>

- **MUST** — The shared mutable class attribute

  <details><summary><strong>Answer</strong></summary>

  `class Cart: items = []` gives every instance the same list, so `self.items.append(x)` in one instance is visible in all of them, forever, including across requests in a long-running server. The mutation goes through the class attribute because no assignment ever happened to create an instance one.

  The fix is to assign in `__init__`, or to use a dataclass with `field(default_factory=list)` — which exists precisely because a plain mutable default in a dataclass is rejected at class-creation time rather than silently shared.

  </details>

- **MUST** — What class attributes are legitimately for

  <details><summary><strong>Answer</strong></summary>

  Constants and configuration shared by all instances, defaults a subclass is meant to override, `__slots__`, and the annotations a dataclass or [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") reads. Anything immutable is safe; anything mutable needs a per-instance factory.

  `ClassVar[int]` in a typed codebase makes the intent explicit and tells both the type checker and a dataclass that the attribute is not a field.

  </details>

- **MUST** — Instance, class and static methods

  <details><summary><strong>Answer</strong></summary>

  An instance method receives the instance; a `classmethod` receives the class, which makes it the correct tool for an alternative constructor because it returns the right type when subclassed; a `staticmethod` receives neither and is simply a function living in the class namespace for organisation.

  The test for `classmethod` over `staticmethod` is whether the method needs to know which class it was called on. If it does, and you hard-coded the class name instead, subclasses will construct the wrong type.

  </details>

- **MUST** — `property` and computed attributes

  <details><summary><strong>Answer</strong></summary>

  `@property` turns a method into a read-only attribute, with `@x.setter` adding a validated write. It exists so a class can start with a plain attribute and later add computation or validation without changing any caller — which is the reason Python code does not write getters and setters up front.

  `functools.cached_property` computes once and stores the result in the instance `__dict__`, so it is free afterwards; it therefore requires an instance dict and cannot be combined with `__slots__`.

  </details>

- **NICE** — Class-level state in a long-running process

  <details><summary><strong>Answer</strong></summary>

  A class attribute, like a module-level global, lives for the life of the process, so in a web server it is shared across every request and, with threads, across every worker thread in that process. That is exactly right for a compiled regex or a constant, and exactly wrong for anything request-scoped.

  A cache placed there must be bounded and thread-safe, since two workers will reach it concurrently. `contextvars` is the tool for state that should follow one request through async code instead.

  </details>

- **OPTIONAL** — Name mangling

  <details><summary><strong>Answer</strong></summary>

  A leading double underscore inside a class body is rewritten to `_ClassName__name`, which is not privacy but collision avoidance, aimed at a subclass accidentally reusing an attribute name. A single leading underscore is the actual convention for "internal", enforced by nothing but read by everyone.

  </details>

## 16. Slots

**Why it comes up:** it is the memory-optimisation question with a real measurement behind it, and the list of things it breaks is the interesting half.

- **MUST** — What it does

  <details><summary><strong>Answer</strong></summary>

  `__slots__ = ("x", "y")` tells the class to store those attributes in a fixed array of descriptors instead of giving each instance a `__dict__`. The saving is substantial — typically 40-50% of the per-instance footprint for a small object — and attribute access is marginally faster, because it is an indexed slot lookup rather than a dictionary probe.

  The trade is rigidity: assigning any attribute not listed raises `AttributeError`. That is occasionally sold as typo protection, but the real reason to use it is millions of instances, not correctness.

  </details>

- **MUST** — What it breaks

  <details><summary><strong>Answer</strong></summary>

  No `__dict__`, so no dynamic attributes, no `cached_property`, and anything expecting `vars(obj)` to work fails. Multiple inheritance from two classes that both define non-empty `__slots__` is a `TypeError` at class creation. A subclass that omits `__slots__` silently regains a `__dict__` and with it the whole saving. Default values must move into `__init__`, since a class attribute of the same name collides with the slot descriptor.

  Pickling needs care without a `__dict__`, and weak references require `"__weakref__"` to be listed explicitly.

  </details>

- **MUST** — Measuring the saving honestly

  <details><summary><strong>Answer</strong></summary>

  `sys.getsizeof` on an instance does **not** include its `__dict__`, so comparing that number before and after adding slots reports a saving far smaller than the real one. Measure the resident size of a process holding a million instances, or use `tracemalloc` around the allocation.

  The figure to expect for a small object is roughly 50 bytes against 100 or more, and the honest framing is that this only matters at a scale where you should also be asking whether the objects need to exist individually at all.

  </details>

- **NICE** — The alternatives that give the same win

  <details><summary><strong>Answer</strong></summary>

  `@dataclass(slots=True)` from 3.10 generates the slots and the `__init__` together and is the version to reach for. `NamedTuple` is smaller still where the object is genuinely a value. For very large homogeneous collections, the real answer is usually to stop having millions of objects: an `array`, a NumPy array or columnar storage changes the footprint by an order of magnitude rather than by half.

  </details>

- **NICE** — Slots and inheritance

  <details><summary><strong>Answer</strong></summary>

  Only the classes that declare `__slots__` avoid a `__dict__`, and the whole chain must declare it — a single base or subclass without one gives every instance a dict back and erases the saving. A base class intended to be slotted but with no attributes of its own declares `__slots__ = ()`.

  Repeating a name in both a parent's and a child's slots wastes a slot and hides the parent's descriptor, and inheriting from two classes that both declare non-empty slots is a `TypeError` at class creation.

  </details>

- **NICE** — Slots, pickling and serialisation

  <details><summary><strong>Answer</strong></summary>

  Pickle's default protocol handles slotted objects through `__reduce_ex__`, which produces a two-part state of dict and slots, so modern pickling works without extra code. Anything that assumes `obj.__dict__` exists — an older custom `__getstate__`, a hand-rolled serialiser, some debugging helpers — does not.

  `dataclasses.asdict` and `attrs` handle slots correctly, which is another argument for generating them rather than writing them out.

  </details>

- **OPTIONAL** — Key sharing makes the case weaker than it was

  <details><summary><strong>Answer</strong></summary>

  Since 3.3, instances of the same class share the keys of their `__dict__`, which already removed a large part of the historical overhead. Measure before adopting slots for memory reasons, because the number in a blog post from 2010 is not the number you will get.

  </details>

## 17. Descriptors

**Why it comes up:** it is the mechanism `property`, `classmethod`, `staticmethod` and every ORM field are built from, so it is asked to find out whether the candidate has looked underneath the abstractions they use daily.

- **MUST** — The protocol, and data against non-data

  <details><summary><strong>Answer</strong></summary>

  A **descriptor** is an object defining `__get__`, and optionally `__set__` and `__delete__`, placed as a class attribute; the interpreter calls those methods instead of returning the object when the attribute is accessed. One that defines `__set__` or `__delete__` is a *data* descriptor and takes priority over the instance `__dict__`; one that defines only `__get__` is a *non-data* descriptor and loses to it.

  That priority rule is the whole reason `property` cannot be shadowed by an instance attribute while a plain method can be, and it is the answer to "why does assigning to a property raise but assigning over a method work".

  </details>

- **MUST** — What is built on it

  <details><summary><strong>Answer</strong></summary>

  Functions are non-data descriptors: `obj.method` works because `function.__get__` returns a bound method with the instance already attached, which is where `self` comes from. `property` is a data descriptor wrapping up to three functions. `classmethod` and `staticmethod` are descriptors that change what gets bound. `__slots__` creates one descriptor per slot. `cached_property` is a non-data descriptor that writes its result into the instance dict so the second access never reaches it.

  Naming two or three of these is the answer; reciting the method signatures is not.

  </details>

- **MUST** — Writing one, and `__set_name__`

  <details><summary><strong>Answer</strong></summary>

  The reason to write your own is a validation or conversion rule repeated across many attributes or many classes — a positive-number field, a unit-carrying value, a lazily loaded relation. `__set_name__(self, owner, name)` is called at class creation and hands the descriptor the attribute name it was bound to, which removes the old boilerplate of passing the name in by hand.

  State belongs in the instance, keyed by that name, not on the descriptor — a descriptor is one shared object per class, so storing per-instance data on it leaks values between instances.

  </details>

- **MUST** — Access on the class rather than an instance

  <details><summary><strong>Answer</strong></summary>

  When an attribute is read on the class, `__get__` is called with `None` as the instance. The conventional response is to return the descriptor itself, which is why `SomeClass.attr` gives you the `property` object rather than raising.

  An ORM uses the same hook in the other direction: `Model.field` returns a query expression so that `Model.field == 5` builds a `WHERE` clause, while `instance.field` returns the value. One descriptor serving both is the entire trick behind declarative query syntax.

  </details>

- **NICE** — Where per-instance state belongs

  <details><summary><strong>Answer</strong></summary>

  A descriptor is one object shared by the class, so any value stored on `self` inside `__get__` is shared by every instance — the classic bug that makes two objects report each other's data. The value belongs in the instance's own `__dict__`, under the name `__set_name__` supplied.

  When the owner class uses `__slots__` there is no instance dict to write into, and a `WeakKeyDictionary` keyed by the instance is the fallback that does not leak.

  </details>

- **NICE** — Choosing between a property, a descriptor and `__getattr__`

  <details><summary><strong>Answer</strong></summary>

  One computed attribute on one class is a `property`. The same rule on many attributes or many classes is a descriptor, because a property cannot be parameterised without writing a factory. An open-ended set of names known only at run time is `__getattr__`.

  Reaching for the heaviest of the three first is the common mistake, and the order above is the order to try them in.

  </details>

- **OPTIONAL** — Where it appears in frameworks

  <details><summary><strong>Answer</strong></summary>

  A Django or [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries") model field, a Pydantic field before validation, a form field and a `traitlets` attribute are all descriptors. Recognising the pattern is what lets you read the source of those libraries rather than treating their declarative syntax as magic.

  </details>

## 18. First-Class Functions and Callables

**Why it comes up:** it underlies decorators, callbacks and dependency injection, and `functools.partial` against a lambda is a small question with a real answer.

- **MUST** — Functions as objects

  <details><summary><strong>Answer</strong></summary>

  A function is an ordinary object: it can be bound to a name, stored in a list or dict, passed as an argument, returned, and given attributes. That is what makes decorators, callbacks, key functions, strategy dispatch and a dict of handlers instead of a long `elif` chain all possible with no special machinery.

  The dict-of-handlers pattern is the one worth naming in the room, because it is where the language feature meets a design someone will recognise.

  </details>

- **MUST** — What makes an object callable

  <details><summary><strong>Answer</strong></summary>

  Defining `__call__` makes any instance callable, so a class can carry configuration and state while still being used wherever a function is expected. That is the clean solution to the stateful-decorator and stateful-callback problem, where a closure would work but is harder to inspect and test.

  Classes themselves are callable — `MyClass()` invokes the metaclass's `__call__`, which calls `__new__` and then `__init__` — which is why "class" and "function" are interchangeable in a factory signature.

  </details>

- **MUST** — `functools.partial` against a lambda

  <details><summary><strong>Answer</strong></summary>

  `partial(f, 1)` binds arguments now and returns a callable that applies them later. Against `lambda x: f(1, x)` it differs in three ways that matter: the arguments are evaluated immediately rather than at call time, so it does not suffer the late-binding capture bug; it is picklable, so it can cross a process boundary to a `ProcessPoolExecutor`; and it keeps `func`, `args` and `keywords` introspectable.

  A lambda is fine for a throwaway key function. For anything stored, sent to another process, or read back in a traceback, `partial` is the better tool.

  </details>

- **MUST** — Argument passing rules

  <details><summary><strong>Answer</strong></summary>

  `*args` and `**kwargs` collect and forward; `*` in a signature forces the parameters after it to be keyword-only, and `/` forces the ones before it to be positional-only. Keyword-only parameters are the cheapest readability win available in an API — they stop a caller writing `resize(img, True, False)` and let the signature grow without breaking callers.

  </details>

- **NICE** — Higher-order helpers worth knowing

  <details><summary><strong>Answer</strong></summary>

  `functools.reduce` where a fold is genuinely clearer than a loop, `operator.itemgetter` and `attrgetter` as faster and clearer `key` functions than a lambda, `functools.singledispatch` for type-based dispatch without an `isinstance` chain, and `functools.wraps` on anything that wraps.

  </details>

- **NICE** — Callbacks keep their object alive

  <details><summary><strong>Answer</strong></summary>

  Storing `self.on_event` in a registry stores a **bound method**, which holds a strong reference to the instance, so an object that registered a callback and was otherwise discarded stays in memory for as long as the registry does. This is the most common shape of a leak in event-driven Python.

  `weakref.WeakMethod` holds it without preventing collection, and an explicit unregister in a `close` or context manager is the simpler fix where the lifetime is known.

  </details>

- **OPTIONAL** — Where the functional style stops paying

  <details><summary><strong>Answer</strong></summary>

  Python has no tail-call elimination, closures capture by reference, and a chain of `map` and `filter` over lambdas is both slower and harder to read than a comprehension. The idiomatic line is that comprehensions and generator expressions are the functional tools the language actually favours.

  </details>

## 19. Metaclasses and Subclass Hooks

**Why it comes up:** it is the deepest data-model question, and the best answer usually explains why you would not use one.

- **MUST** — What a metaclass is

  <details><summary><strong>Answer</strong></summary>

  A class is an object, and its type is a **metaclass**, by default `type`. A `class` statement is compiled into a call to that metaclass with the name, bases and namespace, so subclassing `type` and overriding `__new__` or `__init__` lets you inspect or rewrite a class as it is created.

  `type` with three arguments does the same thing dynamically, which is the demonstration that there is no separate mechanism: `class Foo: pass` and `type("Foo", (), {})` produce the same object.

  </details>

- **MUST** — What they are used for, and the lighter alternatives

  <details><summary><strong>Answer</strong></summary>

  The real uses are registration of subclasses into a registry, validation that a subclass declared what the framework requires, transforming declared attributes into descriptors — the ORM and serialiser pattern — and enforcing a singleton or an interface.

  Almost all of those are better served today by `__init_subclass__` for registration and validation, `__set_name__` for descriptors learning their names, a class decorator for rewriting a class after creation, and `abc.ABCMeta` for interfaces. **The rule is** that a metaclass is justified only when the behaviour must be inherited by every subclass automatically and must run at class-creation time; a decorator does not inherit, which is the one thing it cannot do.

  </details>

- **MUST** — `__new__` against `__init__`

  <details><summary><strong>Answer</strong></summary>

  `__new__` allocates and returns the object, `__init__` initialises the object it is handed. Overriding `__new__` is required for immutable types, since there is nothing to mutate afterwards, and for factories that return a cached or singleton instance.

  The trap is that `__init__` still runs on whatever `__new__` returned, so a cached instance is re-initialised on every construction unless you guard against it — and if `__new__` returns an object of a different type, `__init__` is skipped entirely.

  </details>

- **NICE** — Abstract base classes

  <details><summary><strong>Answer</strong></summary>

  `abc.ABC` with `@abstractmethod` makes instantiating an incomplete subclass a `TypeError` at construction, which is the nominal way to declare an interface. Its cost is that implementers must inherit from it — a real constraint when the classes are not yours.

  `typing.Protocol` is the structural alternative: it checks shape rather than ancestry, and is checked statically, which is usually the better fit for a boundary between packages.

  </details>

- **NICE** — `__prepare__` and declaration order

  <details><summary><strong>Answer</strong></summary>

  A metaclass can implement `__prepare__` to supply the mapping used for the class body's namespace, which is how a framework captures the order fields were declared in or rejects a duplicate name. Since 3.6 the default namespace is already ordered, which removed the most common reason to define it.

  It is worth knowing because it explains how a declarative ORM or serialiser knows which field came first without being told.

  </details>

- **NICE** — Singletons, and why they are usually the wrong use

  <details><summary><strong>Answer</strong></summary>

  A metaclass overriding `__call__` to return a cached instance is the textbook singleton, and it is almost always worse than the alternative: a module-level instance, since a module is already imported once and cached by the interpreter.

  The metaclass version breaks subclassing, complicates testing because the instance outlives a test, and hides a global behind what looks like a constructor. Naming that trade is a better answer than implementing it.

  </details>

- **OPTIONAL** — Metaclass conflicts

  <details><summary><strong>Answer</strong></summary>

  Inheriting from two classes with unrelated metaclasses raises `TypeError: metaclass conflict`, and the only remedy is a metaclass deriving from both. It is the concrete reason widespread metaclass use makes a codebase hard to extend, and a good closing sentence for the topic.

  </details>
