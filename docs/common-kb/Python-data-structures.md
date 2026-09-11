# Fundamental Topics: Python Data Structures and Performance

**Table of Contents**

[Data Structures and Algorithms Topics](#data-structures-and-algorithms-topics)

- [1. The Built-in Collections and Their Complexity](#1-the-built-in-collections-and-their-complexity)
- [2. Dict Internals](#2-dict-internals)
- [3. Comprehensions, map and Loops](#3-comprehensions-map-and-loops)
- [4. The collections Module](#4-the-collections-module)
- [5. Text, Bytes and Encoding](#5-text-bytes-and-encoding)
- [6. Records: dataclass, NamedTuple, TypedDict and a Plain Class](#6-records-dataclass-namedtuple-typeddict-and-a-plain-class)
- [7. List Growth and Insertion Cost](#7-list-growth-and-insertion-cost)
- [8. heapq, bisect and Sorted Structures](#8-heapq-bisect-and-sorted-structures)

[Memory and Performance Topics](#memory-and-performance-topics)

- [9. Finding the Real Bottleneck](#9-finding-the-real-bottleneck)
- [10. Profiling Tools](#10-profiling-tools)
- [11. Common Performance Traps](#11-common-performance-traps)
- [12. Caching](#12-caching)
- [13. Memory Layout and Object Overhead](#13-memory-layout-and-object-overhead)
- [14. Streaming Over Large Data](#14-streaming-over-large-data)
- [15. Native Code and the GIL](#15-native-code-and-the-gil)
- [16. C Extensions and the Alternatives](#16-c-extensions-and-the-alternatives)
**What this is.** The container, algorithm and performance topics a backend engineer is expected to reason about rather than recite, taken from two groups of the list in `docs/tmp/common-kb/Python.txt`. That list is long enough to be five documents; the others are `Python-language.md`, `Python-concurrency.md`, `Python-typing-stdlib.md` and `Python-applications.md`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") is the concrete reference throughout, at a 3.12 baseline with later behaviour named where it differs, because the numbers that make these topics answerable — what an object costs, how a dict is laid out, how a list grows — are properties of that implementation and not of the language.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1 and topic 9 are the ones you are most likely to be asked. The grouping follows `Python.txt`: the containers and the costs of using them, then how you find and fix a program that is too slow or too large.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 64 MUST, 32 NICE and 16 OPTIONAL across 16 topics. The MUST share is high because half this list is the complexity table and the other half is the measure-before-you-change habit, and both are checked directly rather than inferred from what you have built.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Data Structures and Algorithms Topics

## 1. The Built-in Collections and Their Complexity

**Why it comes up:** choosing the wrong container turns a linear algorithm into a quadratic one, and the complexity table is the cheapest thing an interviewer can check.

- **MUST** — The four containers and what each is for

  <details><summary><strong>Answer</strong></summary>

  A **list** is a dynamic array of pointers: ordered, mutable, indexable in constant time, and the default sequence. A **tuple** is its immutable, hashable counterpart, which is what lets it be a dict key or a set member. A **set** is a hash table of keys with no values, for membership and deduplication. A **dict** is a hash table mapping keys to values, and since 3.7 it preserves insertion order as a language guarantee.

  The choice is usually decided by one question: do you need order and position, or do you need to ask whether something is present? Position means a list; presence means a set or a dict.

  </details>

- **MUST** — The complexity that actually matters

  <details><summary><strong>Answer</strong></summary>

  List: index and append are O(1) amortised, `insert(0, x)` and `pop(0)` are O(n), `in` is O(n), `sort` is O(n log n). Dict and set: lookup, insert and delete are O(1) average and O(n) in the pathological collision case, and `in` is O(1). Tuple matches list for reads and has no writes.

  The one that dominates real code is `in` on a list against `in` on a set. A membership test inside a loop over a list of ten thousand items is a hundred million comparisons; converting the haystack to a set first makes it ten thousand. **The tell is** whether you spot that shape in code rather than reciting the table.

  </details>

- **MUST** — Memory profile, and why it differs so much

  <details><summary><strong>Answer</strong></summary>

  A list of a million small integers is roughly 8 MB of pointers plus 28 bytes per distinct integer object, so the container is the cheap part and the objects are not. A set or a dict holds a sparse table and is deliberately kept under about two thirds full, so it costs several times a list of the same elements — the price of O(1) lookup.

  A tuple is slightly smaller than a list, because a list over-allocates to make appends amortised while a tuple is sized exactly once. For large homogeneous numeric data, `array.array` or a [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") array drops the per-element object entirely and is an order of magnitude smaller.

  </details>

- **MUST** — Hashability as the constraint behind set and dict

  <details><summary><strong>Answer</strong></summary>

  Set members and dict keys must be hashable, which in practice means immutable, because the hash must not change while the object is in the table. That is why a list cannot be a key and a tuple can — and why a tuple containing a list cannot either, since hashing recurses into the elements.

  `frozenset` exists for the case where the key is itself a set. When a natural key is mutable, the usual moves are to key by an immutable projection such as an ID or a tuple of fields, or to make the object frozen.

  </details>

- **NICE** — Sorting, and what `key` costs

  <details><summary><strong>Answer</strong></summary>

  `sorted` and `list.sort` use Timsort, which is O(n log n) worst case, stable, and close to linear on partially ordered input — which real data usually is. Stability is the property that lets you sort by one field and then another to get a compound ordering.

  `key` is called exactly once per element and the results are cached, so an expensive key function costs n calls rather than n log n. `operator.itemgetter` and `attrgetter` are faster than a lambda because they avoid a Python-level call.

  </details>

- **NICE** — The set operations people forget

  <details><summary><strong>Answer</strong></summary>

  Union, intersection, difference and symmetric difference are all available as operators and methods, and each is roughly linear in the smaller operand rather than a loop with a membership test. Comparing two datasets for what was added and what was removed is two set differences and one line.

  `issubset` and `isdisjoint` answer permission and overlap questions directly, and `isdisjoint` short-circuits rather than building an intersection it then discards.

  </details>

- **OPTIONAL** — Why a tuple is not just a frozen list

  <details><summary><strong>Answer</strong></summary>

  The convention is that a tuple is a record with meaning per position — a coordinate, a row — while a list is a homogeneous collection of the same kind of thing. That is why a heterogeneous tuple is idiomatic and a heterogeneous list is usually a sign that a class or a dataclass was wanted.

  </details>

## 2. Dict Internals

**Why it comes up:** the ordering guarantee and the compact layout are a short, checkable story about how a language feature became official because an implementation detail turned out to be free.

- **MUST** — How a lookup works

  <details><summary><strong>Answer</strong></summary>

  The key is hashed, the low bits of the hash select a slot in the index table, and the entry there is compared first by hash and then with `==`. A mismatch means a collision, and CPython resolves it by **open addressing** — probing another slot by a perturbation of the hash — rather than by chaining into a linked list.

  The consequence is that lookup is O(1) average and degrades only when many keys collide, and that the comparison step is why the equality-and-hash contract has to hold: an equal key with a different hash is looked for in the wrong place and never found.

  </details>

- **MUST** — The compact dict and where the ordering came from

  <details><summary><strong>Answer</strong></summary>

  Since 3.6 a dict is two structures: a sparse array of indices, and a dense array of entries in insertion order. Iteration walks the dense array, so it yields keys in the order they were added — which is why ordering was a free side effect of a layout change made to save memory, roughly 20-25%.

  It became a **language guarantee in 3.7**, so it can be relied on now, while code that must run on 3.5 cannot rely on it. `OrderedDict` still differs in two ways worth naming: its equality is order-sensitive, and it has `move_to_end`, which is what makes it the natural [LRU](https://en.wikipedia.org/wiki/Cache_replacement_policies "Least Recently Used — Cache eviction policy that discards the entry untouched for longest") structure.

  </details>

- **MUST** — Key sharing and instance dictionaries

  <details><summary><strong>Answer</strong></summary>

  Instances of the same class share one copy of their `__dict__` keys, because every instance has the same attribute names. That removed most of the historical per-instance overhead and is the reason the memory case for `__slots__` is weaker than the older benchmarks suggest.

  The sharing is lost when an instance gains an attribute the others do not have, so adding attributes dynamically to some objects of a class and not others quietly costs memory across all of them.

  </details>

- **MUST** — Resizing, and why insertion order is not the same as key order

  <details><summary><strong>Answer</strong></summary>

  When the table passes roughly two thirds full it is reallocated at a larger size and every entry is reinserted, so an insert is O(1) amortised rather than always. Building a large dict from a known size is therefore slightly cheaper as a single comprehension than as a loop of assignments.

  Deletion leaves a tombstone in the index and a gap in the entries array, which is compacted on the next resize — so a dict that has had many deletions does not shrink until it is rebuilt, and `dict(d)` is the way to reclaim that space.

  </details>

- **NICE** — Dict methods that replace a conditional

  <details><summary><strong>Answer</strong></summary>

  `get(key, default)` for a read that may miss, `setdefault` for read-or-create in one step, `|` and `|=` from 3.9 for merging, and `dict.fromkeys` for building from an iterable. `collections.defaultdict` moves the default into the container rather than the call site.

  The trap in `setdefault` is that its default argument is evaluated whether or not it is needed, so `setdefault(k, expensive())` pays the cost on every call. `defaultdict` takes a factory and does not.

  </details>

- **NICE** — Hash randomisation and why dict order is still not a security property

  <details><summary><strong>Answer</strong></summary>

  String hashes are salted per process, so the *iteration* order of a dict is stable within a run and the *hash* values are not stable across runs. Insertion ordering is unaffected, since it comes from the entries array rather than the hash.

  Never persist a `hash()` value, and never use dict ordering as a substitute for an explicit sort when the output is a contract.

  </details>

- **OPTIONAL** — Views and what they cost

  <details><summary><strong>Answer</strong></summary>

  `keys`, `values` and `items` return dynamic views rather than lists: they are O(1) to create, reflect later changes, and support set operations in the case of `keys` and `items`. Mutating the dict while iterating a view raises `RuntimeError`, which is a deliberate guard rather than an inconvenience — take `list(d)` first if you intend to modify.

  </details>

## 3. Comprehensions, map and Loops

**Why it comes up:** everyone writes them, so the question is whether you know when a comprehension stops being the right tool rather than whether you can write one.

- **MUST** — What a comprehension is and why it is faster

  <details><summary><strong>Answer</strong></summary>

  `[f(x) for x in it if cond(x)]` builds a list in one expression. It is faster than the equivalent `for` loop with `append` because the append is a specialised opcode rather than an attribute lookup and a method call per element, which saves roughly a third on a tight loop.

  The same syntax builds a set with braces, a dict with `k: v`, and a lazy generator with parentheses. The generator form is the one to reach for when the result is consumed once, because it allocates nothing.

  </details>

- **MUST** — When a comprehension is the wrong choice

  <details><summary><strong>Answer</strong></summary>

  When it needs more than about two clauses, when the body wants a `try`, or when the reader has to parse nesting to work out what is being produced. Nested comprehensions read in an order that surprises people — the loops run left to right, and the expression is at the far left — so two levels is usually the limit.

  The honest rule is that a comprehension is for building a collection from a transformation and a filter. Anything that is really a loop with side effects should be written as a loop, and a comprehension evaluated only for its side effects is a misuse.

  </details>

- **MUST** — Against `map` and `filter`

  <details><summary><strong>Answer</strong></summary>

  `map(f, it)` and `filter(p, it)` are lazy in Python 3 and are marginally faster than a comprehension *only* when `f` is an existing function such as `str` or `int`, because no Python-level frame is created per element. With a lambda they are slower, since the lambda call costs exactly what the comprehension's expression would have.

  The idiomatic choice is a comprehension, with `map` reserved for the case where the function already exists and reads cleanly — `map(int, line.split())`. Chaining `map` over `filter` over `map` is where readability is lost for no gain.

  </details>

- **MUST** — Scope and the walrus

  <details><summary><strong>Answer</strong></summary>

  A comprehension has its own scope in Python 3, so its loop variable does not leak into the enclosing function — a real change from Python 2, and the reason a comprehension cannot accidentally clobber a name. The iterable of the outermost `for` is evaluated in the enclosing scope; everything else is evaluated inside.

  `:=` is what lets a filter reuse a computed value without computing it twice: `[y for x in it if (y := f(x)) is not None]`. Before it, the choice was to call `f` twice or to write a loop.

  </details>

- **NICE** — Where the loop wins on memory

  <details><summary><strong>Answer</strong></summary>

  A list comprehension materialises everything, so building a list of a million parsed rows to iterate over once is a pure waste of memory. Swapping the brackets for parentheses makes it a generator expression and the memory constant, with no other change to the code.

  The case for materialising is needing the result more than once, needing its length, or needing to index it — and in those cases the list is correct, not a compromise.

  </details>

- **NICE** — `any`, `all` and short-circuiting

  <details><summary><strong>Answer</strong></summary>

  `any(p(x) for x in it)` stops at the first match, so it is the right way to express "does anything satisfy this" and strictly better than building a filtered list and testing its truthiness. `all` short-circuits on the first failure in the same way.

  Passing a list comprehension to either evaluates every element first and throws away the saving, which is the most common way this is got wrong.

  </details>

- **OPTIONAL** — Async comprehensions

  <details><summary><strong>Answer</strong></summary>

  `[x async for x in agen()]` and `[await f(x) for x in it]` are both valid inside an `async def`, the first iterating an async generator and the second awaiting per element. The second is sequential, not concurrent — genuine concurrency needs `asyncio.gather` or a task group, which is the mistake the syntax invites.

  </details>

## 4. The collections Module

**Why it comes up:** reaching for the right one is a fluency signal, and `deque` against `list` is the direct follow-up to the insert-at-front question.

- **MUST** — `deque` and what it is for

  <details><summary><strong>Answer</strong></summary>

  A **deque** is a doubly linked list of blocks, so `append`, `appendleft`, `pop` and `popleft` are all O(1), against O(n) for a list's left-hand operations. It is the correct structure for a queue, a sliding window and a breadth-first search frontier.

  The trade is indexing: reaching the middle is O(n) rather than O(1), so a deque is a bad list. `deque(maxlen=n)` also gives a bounded buffer for free, discarding from the opposite end on overflow, which is the neatest way to keep the last n log lines or samples.

  </details>

- **MUST** — `defaultdict` and `Counter`

  <details><summary><strong>Answer</strong></summary>

  `defaultdict(list)` calls the factory on a missing key, which turns grouping into one line without a `setdefault` or a membership test. The trap is that merely *reading* a missing key inserts it, so a defaultdict passed to code that does lookups grows silently — `dict.get` or converting back with `dict(d)` is the guard.

  `Counter` counts hashables and adds `most_common`, arithmetic between counters, and `total`. Both are dict subclasses, so everything that works on a dict works on them.

  </details>

- **MUST** — `namedtuple` and where it still fits

  <details><summary><strong>Answer</strong></summary>

  `namedtuple` gives a tuple subclass with named fields: immutable, hashable, iterable, unpackable, and the smallest of the record types in memory because it has no instance dict. `typing.NamedTuple` is the same thing with annotations and a class body.

  Its limits are what push people to a dataclass: no mutation, no defaults before 3.6.1, no methods without subclassing, and the fact that it is still a tuple — so it compares equal to a plain tuple with the same values, which is occasionally exactly wrong.

  </details>

- **MUST** — `ChainMap`, `OrderedDict` and the rest

  <details><summary><strong>Answer</strong></summary>

  `ChainMap` layers mappings and searches them in order without copying, which is the natural shape for configuration precedence — command line over environment over file over defaults. `OrderedDict` survives for order-sensitive equality and `move_to_end`. `UserDict` and `UserList` are the safe bases for subclassing, because subclassing `dict` directly means your `__setitem__` is bypassed by `update` and by the constructor.

  That last point is the one worth knowing: `class MyDict(dict)` with an overridden `__setitem__` does not intercept `d.update(...)`, because the C implementation does not route through it.

  </details>

- **NICE** — `collections.abc` as the vocabulary for type hints

  <details><summary><strong>Answer</strong></summary>

  `Iterable`, `Sequence`, `Mapping`, `MutableMapping`, `Hashable` and `Callable` are the abstract base classes to accept in a signature, because accepting `Iterable[str]` rather than `list[str]` lets a caller pass a generator, a tuple or a set.

  They are also the classes to inherit from when writing a container, since implementing a small required set gets the derived methods filled in consistently.

  </details>

- **NICE** — `heapq` in the same breath

  <details><summary><strong>Answer</strong></summary>

  The priority queue does not live in `collections`, which surprises people: `heapq` operates on a plain list in place. `queue.PriorityQueue` wraps the same thing with locking for cross-thread use, and paying for that lock in single-threaded code is a common accident.

  </details>

- **OPTIONAL** — When a plain dict is the better answer

  <details><summary><strong>Answer</strong></summary>

  A `defaultdict` that is returned from a function or stored in a structure carries its surprising insert-on-read behaviour with it. For anything crossing an [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") boundary, build with a defaultdict internally and return `dict(result)`, so the caller gets a container that behaves the way its type says it does.

  </details>

## 5. Text, Bytes and Encoding

**Why it comes up:** it is the change that forced Python 3, and a `UnicodeDecodeError` in production is the one bug that is always an encoding assumption rather than a bug in the parser.

- **MUST** — `str` against `bytes`

  <details><summary><strong>Answer</strong></summary>

  A **`str`** is a sequence of Unicode code points with no encoding; **`bytes`** is a sequence of octets with no meaning. `encode` goes from text to bytes and `decode` goes back, and Python 3 refuses to do either implicitly — which is exactly why the migration was painful and why the resulting code is correct.

  The model to hold is the sandwich: decode at the edge where bytes enter, work in `str` throughout the middle, and encode at the edge where bytes leave. Every encoding bug is a place where that boundary was not drawn.

  </details>

- **MUST** — Where encodings come from, and the defaults that bite

  <details><summary><strong>Answer</strong></summary>

  `open` in text mode uses `locale.getpreferredencoding`, which is [UTF-8](https://datatracker.ietf.org/doc/html/rfc3629 "Unicode Transformation Format 8-bit — Variable-width encoding that represents every Unicode code point as bytes") on modern Linux and macOS and was historically `cp1252` on Windows — so the same script reads a file correctly on one machine and raises on another. Always pass `encoding="utf-8"` explicitly; from 3.15 that becomes the default, and `PYTHONWARNDEFAULTENCODING` flags the places that relied on the old behaviour.

  Network and subprocess boundaries have the same problem: the bytes arriving have whatever encoding the sender used, and the `Content-Type` header or the protocol spec is the only thing that tells you which.

  </details>

- **MUST** — Handling a decode error deliberately

  <details><summary><strong>Answer</strong></summary>

  `decode` takes an `errors` argument: `strict` raises, `replace` substitutes the replacement character, `ignore` drops the bytes, and `surrogateescape` smuggles undecodable bytes through so they can be written back out unchanged. Choosing one is a data-integrity decision, not a way to silence an exception.

  `ignore` silently corrupts, `replace` marks the damage visibly, and `surrogateescape` is the right answer for filenames and other data you must round-trip without understanding. Say which and why — an answer that just reaches for `errors="ignore"` is the wrong one.

  </details>

- **MUST** — Length, indexing and what a character is

  <details><summary><strong>Answer</strong></summary>

  `len` on a `str` counts code points, not characters as a user sees them and not bytes. An emoji with a skin-tone modifier is several code points, an accented letter may be one code point or two depending on normalisation, and `len(s.encode())` is a third number again.

  `unicodedata.normalize("NFC", s)` is what makes two visually identical strings compare equal, and it belongs at the same boundary as decoding — before storing, before comparing and before hashing. Truncating a `str` by bytes to fit a column is where this most often goes wrong.

  </details>

- **NICE** — String interning and identity

  <details><summary><strong>Answer</strong></summary>

  CPython interns string literals that look like identifiers and short strings created at compile time, so `"abc" is "abc"` is True and the same comparison on runtime-built strings is not. `sys.intern` forces it, which is a real optimisation when a program holds millions of repeated keys, since comparison then usually short-circuits on identity.

  It is an implementation detail, not a guarantee, and the rule remains to compare strings with `==`.

  </details>

- **NICE** — Building strings efficiently

  <details><summary><strong>Answer</strong></summary>

  `+=` in a loop is quadratic, because each step allocates a new string and copies everything so far; `"".join(parts)` is linear because it sizes the result once. CPython has an in-place optimisation that sometimes hides the cost when the string has exactly one reference, which is why the bad version occasionally benchmarks fine and then does not.

  `io.StringIO` is the right tool when the pieces are produced incrementally and a list would be awkward.

  </details>

- **OPTIONAL** — `bytearray` and `memoryview`

  <details><summary><strong>Answer</strong></summary>

  `bytearray` is the mutable byte buffer, and `memoryview` exposes another object's buffer without copying — so slicing a `memoryview` over a large frame is free where slicing the underlying `bytes` would copy. Both matter in protocol and file work and almost nowhere else.

  </details>

## 6. Records: dataclass, NamedTuple, TypedDict and a Plain Class

**Why it comes up:** four ways to hold a record is a design question, and the answer shows whether you distinguish validation from structure.

- **MUST** — What each one actually is

  <details><summary><strong>Answer</strong></summary>

  A **dataclass** is a code generator that writes `__init__`, `__repr__` and `__eq__` onto a normal class. A **NamedTuple** is a tuple subclass with names — immutable, indexable and hashable. A **TypedDict** is *only* a type annotation: at run time it is a plain dict, with no class, no validation and no methods. A plain class is what you write when there is behaviour and not just data.

  The distinction people miss is that TypedDict describes the shape of a dict that already exists, usually decoded [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange"), and produces no object at all.

  </details>

- **MUST** — How to choose

  <details><summary><strong>Answer</strong></summary>

  Mutable record with behaviour or defaults: dataclass. Immutable value used as a key or returned in bulk: NamedTuple, which is also the smallest. Data that must stay a dict because it is serialised straight back out: TypedDict. Real invariants and methods: a plain class.

  `@dataclass(frozen=True, slots=True)` covers most of what a NamedTuple was used for, with better ergonomics and without comparing equal to a bare tuple. **The judgment being tested is** whether you reach for the lightest thing that expresses the constraint, rather than one habit applied everywhere.

  </details>

- **MUST** — None of them validates

  <details><summary><strong>Answer</strong></summary>

  Annotations are not enforced at run time, so a dataclass, a NamedTuple and a TypedDict will all happily hold a string where an `int` was declared. A type checker catches it before the code runs; nothing catches it if the data came from JSON, a request body or a database row.

  That is the line where [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime") or another validator belongs: at the boundary where untrusted data enters, converting to a trusted typed object once. Inside that boundary a dataclass is the cheaper choice, because re-validating already-validated data is pure cost.

  </details>

- **MUST** — Dataclass details worth knowing

  <details><summary><strong>Answer</strong></summary>

  Mutable defaults must use `field(default_factory=list)` — a bare `[]` is rejected at class creation, which is the language declining to repeat the mutable-default trap. `frozen=True` adds hashability alongside equality, `order=True` generates comparisons, `kw_only=True` removes the rule that fields with defaults must come last, and `__post_init__` is where derived fields and cross-field checks go.

  `field(compare=False)` keeps a timestamp or a cache out of equality, and `field(repr=False)` keeps a secret out of the log line — both small and both frequently wanted.

  </details>

- **NICE** — `attrs` and Pydantic as neighbours

  <details><summary><strong>Answer</strong></summary>

  `attrs` predates dataclasses, is a superset of them, and adds converters and validators; `dataclasses` is the standard-library subset that came out of it. Pydantic looks similar and does a different job — it parses and coerces at run time, which is why it is the right tool at an API edge and the wrong tool for an internal value object.

  </details>

- **NICE** — Serialising them

  <details><summary><strong>Answer</strong></summary>

  `dataclasses.asdict` recurses and copies, which is convenient and surprisingly expensive in a hot path; `astuple` is the positional version. A NamedTuple has `_asdict`. A TypedDict needs nothing, because it is already a dict.

  None of them handles `datetime`, `Decimal` or `UUID` for JSON, so there is always a converter somewhere — a `default` function for `json.dumps`, or a model layer that owns it.

  </details>

- **OPTIONAL** — Pattern matching over records

  <details><summary><strong>Answer</strong></summary>

  `match obj: case Point(x=0, y=y):` destructures a class by keyword, and `__match_args__` — which a dataclass generates — enables the positional form `case Point(0, y)`. It is the one place where the four record types visibly diverge, since a TypedDict matches as a mapping instead.

  </details>

## 7. List Growth and Insertion Cost

**Why it comes up:** amortised analysis is the one piece of algorithmic theory that shows up directly in everyday Python, and `insert(0, x)` is a real bug shape.

- **MUST** — Why append is O(1) amortised

  <details><summary><strong>Answer</strong></summary>

  A list is a contiguous array of pointers with spare capacity. When it fills, CPython allocates a larger block — growth is roughly a ninth over the current size, not a doubling — copies the pointers and frees the old block. Any single append may therefore be O(n), but the copies are rare enough that the cost per append averages to a constant.

  **Amortised** is the word that matters: it means averaged over a sequence of operations, not "usually fast". A latency-sensitive loop can still see the occasional copy of a large array.

  </details>

- **MUST** — Why inserting at the front is O(n)

  <details><summary><strong>Answer</strong></summary>

  `insert(0, x)` must shift every existing element one position to the right to make room, and `pop(0)` shifts them all back. Doing either inside a loop over n items is O(n²) — the classic way a queue built on a list becomes the bottleneck at a few tens of thousands of elements.

  The fix is `collections.deque`, where both ends are O(1). If the order can be reversed, appending and reading backwards is the other answer, and it needs no new type.

  </details>

- **MUST** — Slicing, concatenation and the hidden copies

  <details><summary><strong>Answer</strong></summary>

  Every slice of a list is a new list holding copied pointers, so `data[1:]` inside a recursive function copies the whole remainder at every level and turns a linear algorithm quadratic. `a + b` also allocates a new list, which is why `+=` in a loop over many small lists is worse than `extend` or one `chain`.

  Where a view is wanted rather than a copy, `itertools.islice` iterates a window without allocating, and an index pair passed down a recursion avoids the copy entirely.

  </details>

- **MUST** — Preallocation, and when it is worth anything

  <details><summary><strong>Answer</strong></summary>

  `[None] * n` allocates once and is measurably faster than appending n times when n is large and known — but the difference is small, because the amortised growth is already cheap. It matters in a tight numeric loop and almost nowhere else.

  The honest version of this answer names the real fix for large numeric arrays instead: an `array.array` or a NumPy array, which removes the per-element object rather than saving a few reallocations.

  </details>

- **NICE** — Deleting from the middle, and the loop that skips elements

  <details><summary><strong>Answer</strong></summary>

  `del lst[i]` and `remove` are both O(n) for the same shifting reason. Removing while iterating is worse than slow, it is wrong: the loop's index advances while the list shrinks, so elements are skipped.

  Build a new list with a comprehension, or iterate over a copy, or walk backwards by index. The comprehension is both the fastest and the clearest.

  </details>

- **NICE** — What `sys.getsizeof` on a list does not tell you

  <details><summary><strong>Answer</strong></summary>

  It reports the size of the pointer array and the object header, not the objects pointed at — so a list of a million strings reports about 8 MB regardless of whether the strings are one character or a kilobyte. Measuring real usage means `tracemalloc`, or the resident size of the process.

  </details>

- **OPTIONAL** — Over-allocation and shrinking

  <details><summary><strong>Answer</strong></summary>

  A list that grew to a million elements and then had most of them removed keeps its capacity until it shrinks well below it, so memory is not returned promptly. Rebuilding with `list(x)` or slicing into a new list is the way to reclaim it.

  </details>

## 8. heapq, bisect and Sorted Structures

**Why it comes up:** it is the "top k" and "keep it sorted" question, and knowing that Python has no built-in balanced tree is part of the answer.

- **MUST** — What `heapq` gives you

  <details><summary><strong>Answer</strong></summary>

  A binary **min-heap** maintained in place on a plain list: `heappush` and `heappop` are O(log n), and reading the smallest element is O(1) at `h[0]`. It is the right structure for a priority queue, a scheduler, a merge of sorted streams via `heapq.merge`, and for "top k" through `nlargest` and `nsmallest`.

  What it does not give you is order beyond the root — the list is not sorted, and iterating it yields heap order. For a max-heap, negate the keys or push `(-priority, item)`, since there is no max variant.

  </details>

- **MUST** — Top k, and why it beats sorting

  <details><summary><strong>Answer</strong></summary>

  Keeping a heap of size k while streaming n items is O(n log k) and holds k items in memory; sorting everything is O(n log n) and holds all n. For k far smaller than n — the top 10 of a hundred million — that is the difference between a stream and a machine that does not have the memory.

  `heapq.nlargest(k, it)` does exactly this, and its docstring's own advice is worth repeating: for k of 1 use `max`, and for k close to n use `sorted`.

  </details>

- **MUST** — `bisect` on a sorted list

  <details><summary><strong>Answer</strong></summary>

  `bisect_left` and `bisect_right` binary-search a sorted sequence in O(log n) and return an insertion point, which answers range queries, rank queries and "which bucket does this fall in" — the classic being mapping a score to a grade boundary. `insort` inserts while keeping the order.

  The asymmetry to know is that the search is O(log n) but the insert is still O(n), because the list has to shift. A sorted list is therefore excellent for read-heavy data and poor for interleaved writes.

  </details>

- **MUST** — When a sorted list beats a tree

  <details><summary><strong>Answer</strong></summary>

  Python has no balanced tree in the standard library, and for most workloads it does not need one: a sorted array has perfect cache locality, so binary search over it beats pointer-chasing through a tree at the sizes ordinary programs deal with, and rebuilding it with one `sort` is fast.

  The case for a real tree is many interleaved inserts and ordered queries on a large structure, and the answer there is `sortedcontainers` — a third-party, pure-Python library that is genuinely faster than a naive tree for the same reason. Naming it, and naming why the standard library omits one, is the complete answer.

  </details>

- **NICE** — The stability trap when heap entries compare

  <details><summary><strong>Answer</strong></summary>

  Pushing `(priority, item)` compares the item when two priorities tie, which raises `TypeError` if the item is not orderable — the usual surprise with dicts or custom objects. The fix is a monotonic counter in the middle: `(priority, next(counter), item)`, which also makes the queue stable by insertion order.

  </details>

- **NICE** — Keeping a heap and a lookup in step

  <details><summary><strong>Answer</strong></summary>

  Heaps have no efficient delete or decrease-key, so a scheduler that must cancel entries uses lazy deletion: mark the entry dead in a side dict and skip it when it is popped. Rebuilding the heap to remove one item is O(n) and usually the wrong instinct.

  </details>

- **OPTIONAL** — `queue` against `heapq` and `deque`

  <details><summary><strong>Answer</strong></summary>

  `queue.Queue`, `LifoQueue` and `PriorityQueue` are thread-safe wrappers with blocking `get` and `put`, which is what you want between threads and pure overhead within one. `deque` itself has atomic appends and pops, so it is already safe for the simple producer-consumer case without a lock.

  </details>

## Memory and Performance Topics

## 9. Finding the Real Bottleneck

**Why it comes up:** it is asked as "this endpoint is slow, what do you do", and the answer separates people who measure from people who guess.

- **MUST** — Measure before changing anything

  <details><summary><strong>Answer</strong></summary>

  The sequence is to reproduce the slowness with a representative input, measure where the time goes, change the largest item, and measure again. Every step of that is load-bearing: a fix applied to an unmeasured guess is as likely to cost time as to save it, and without the second measurement you do not know which.

  **The judgment being tested is** whether you can resist the optimisation you already have in mind. Intuition about Python performance is reliably wrong, because the cost is dominated by allocation and dispatch rather than by the operations that look expensive in the source.

  </details>

- **MUST** — In a backend service it is usually not the Python

  <details><summary><strong>Answer</strong></summary>

  The distribution of real causes is roughly: a database query without an index or a query issued per row, a network call in a loop, serialisation of a payload far larger than needed, and a lock or a connection pool that has become the queue. CPU time in the interpreter is a minority case.

  That is why the first tool is usually distributed tracing or the database's own statistics rather than a Python profiler — profiling the application shows a flat profile with all the time inside the driver's socket read, which is true and useless. Say this before reaching for `cProfile`, because it is the answer for the system rather than for the function.

  </details>

- **MUST** — Latency against throughput, and the average against the tail

  <details><summary><strong>Answer</strong></summary>

  A mean response time hides everything that matters. The 95th and 99th percentiles are where timeouts, retries and user complaints live, and a change that improves the mean by making the tail worse is a regression.

  The related trap is measuring a single iteration: a warm cache, a [JIT](https://en.wikipedia.org/wiki/Just-in-time_compilation "Just In Time compilation — Compiles code to machine instructions during execution rather than ahead of time")-specialised loop and a warm connection pool all make the first run unrepresentative in one direction and every later run unrepresentative in the other. Report a distribution, and say which one you measured.

  </details>

- **MUST** — Amdahl's law, stated as a habit

  <details><summary><strong>Answer</strong></summary>

  Optimising a part that takes 5% of the time can never save more than 5%, however well it is done. Before starting, name the fraction of total time the target accounts for and the best case that follows from it — that one sentence kills most premature optimisation without an argument.

  The corollary is that the biggest wins are usually removals rather than speed-ups: not doing the work, doing it once and caching, doing it in bulk instead of per item, or doing it outside the request.

  </details>

- **NICE** — Big-O against constants

  <details><summary><strong>Answer</strong></summary>

  Complexity decides what happens as the input grows, and constants decide what happens at the size you actually have. A quadratic loop over fifty items is free; a linear scan with a per-element database round trip is not.

  Both matter, and naming which one you are talking about prevents the common confusion where an algorithmically perfect solution is slower than the naive one at every realistic size.

  </details>

- **NICE** — Benchmarking honestly

  <details><summary><strong>Answer</strong></summary>

  `timeit` runs a snippet many times and reports the best of several repeats, which disposes of scheduler noise; take the minimum rather than the mean, because noise only ever adds. Keep the setup out of the timed section, use realistic data rather than `range(1000)`, and disable the effect you are not measuring — a warm `lru_cache` makes any function look fast.

  </details>

- **OPTIONAL** — The cost of the measurement itself

  <details><summary><strong>Answer</strong></summary>

  A deterministic profiler adds overhead per function call and therefore exaggerates the cost of small functions, which can invert the ranking in call-heavy code. A sampling profiler distorts far less and is the one to trust when the two disagree.

  </details>

## 10. Profiling Tools

**Why it comes up:** naming the right tool for the right question, and knowing which one can be pointed at a running production process, is a short and very revealing question.

- **MUST** — `cProfile` and reading its output

  <details><summary><strong>Answer</strong></summary>

  `cProfile` is the deterministic profiler in the standard library: it records every call and reports call counts with `tottime` — time in the function itself — and `cumtime`, which includes everything it called. Sort by `tottime` to find the hot function and by `cumtime` to find the expensive call path.

  Run it as `python -m cProfile -o out.prof script.py` and read the file with `pstats` or `snakeviz`, rather than squinting at a text table. **The cost is** the per-call overhead it adds, which is why it belongs in development and not in production.

  </details>

- **MUST** — `py-spy` for a process you cannot restart

  <details><summary><strong>Answer</strong></summary>

  `py-spy` is a sampling profiler that attaches to a **running process**, by [PID](https://en.wikipedia.org/wiki/Process_identifier "Process Identifier — Number the operating system assigns to a running process"), without modifying it, without importing anything into it, and with overhead low enough to use in production. `py-spy top` gives a live view and `py-spy record` produces a flame graph.

  It is also the tool for a hang: `py-spy dump` prints the current stack of every thread, which answers "what is it stuck on" in one command where adding logging would mean a deploy. Naming it is a strong production signal, because it is the answer to the question a development-only profiler cannot address.

  </details>

- **MUST** — `tracemalloc` for memory

  <details><summary><strong>Answer</strong></summary>

  `tracemalloc` records where each allocation happened, so taking a snapshot at two points and comparing them with `compare_to` names the line responsible for the growth. That is the tool for a leak, and it is in the standard library.

  Its limits are worth stating: it sees Python-level allocations, so memory held by a C extension or by allocator fragmentation does not appear, and it costs both memory and time while enabled.

  </details>

- **MUST** — `timeit` for a micro-question

  <details><summary><strong>Answer</strong></summary>

  `timeit` answers "is A faster than B" for a small snippet, with the loop count chosen automatically and the garbage collector disabled during the run by default. It is the right tool for settling a specific argument and the wrong tool for finding a bottleneck, because the thing you chose to time is already the assumption under test.

  The command-line form `python -m timeit -s "setup" "statement"` is quicker than writing a script, and keeping setup out of the statement is what makes the number mean anything.

  </details>

- **NICE** — Line-level and memory-line profilers

  <details><summary><strong>Answer</strong></summary>

  `line_profiler` attributes time to individual lines within a decorated function, which is the next step after `cProfile` has identified the function. `memray` and `memory_profiler` do the equivalent for allocations.

  Both are third-party and both are slow enough that they are used on a narrow target rather than a whole program.

  </details>

- **NICE** — Tracing and metrics as the production version

  <details><summary><strong>Answer</strong></summary>

  Distributed tracing spans across services answer the question a profiler cannot: which of six calls in this request took the time. `OpenTelemetry` instrumentation for the common frameworks and drivers gives that for a modest amount of setup.

  Application metrics — a histogram of request duration by route, and a counter of database queries per request — catch the regression before someone reports it, which is cheaper than any profiling session.

  </details>

- **OPTIONAL** — Profiling async code

  <details><summary><strong>Answer</strong></summary>

  A deterministic profiler attributes time to the event loop rather than to the coroutine that was waiting, which makes the output hard to read. `asyncio` debug mode logs callbacks that blocked the loop for longer than a threshold, and that log line is usually the actual answer.

  </details>

## 11. Common Performance Traps

**Why it comes up:** these are the concrete mistakes an interviewer has seen in real code, and recognising them is worth more than reciting optimisation theory.

- **MUST** — String concatenation in a loop

  <details><summary><strong>Answer</strong></summary>

  `result += piece` inside a loop allocates a new string and copies everything accumulated so far on every iteration, which is O(n²) in the total length. `"".join(pieces)` is linear because it computes the final size once and copies each piece once.

  CPython has an in-place optimisation that applies when the target string has exactly one reference, so the naive version sometimes looks fine in a benchmark and then collapses when the same code is used where another reference exists. That is the reason to write the `join` version by default rather than only when it is measured to matter.

  </details>

- **MUST** — Work repeated inside the loop

  <details><summary><strong>Answer</strong></summary>

  An attribute lookup is a dictionary probe, so `obj.method(x)` inside a million-iteration loop pays for the lookup a million times; binding `method = obj.method` outside the loop removes it. The same applies to a regex compiled per iteration, a constant recomputed per row, and a configuration value read from the environment per call.

  The size of this effect has fallen since the specialising interpreter arrived in 3.11, so it is worth doing where a profile says so and not worth doing everywhere. The version that always matters is the *semantic* one: a database query or an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") call inside the loop.

  </details>

- **MUST** — Needless copies

  <details><summary><strong>Answer</strong></summary>

  Slicing a list copies it, `list(x)` copies it, `sorted` builds a new one, `dataclasses.asdict` recurses and copies the whole tree, and passing a large structure through three layers that each defensively copy multiplies all of it. None of these is wrong in itself; doing them per request on a large object is.

  The cheap alternatives are an iterator instead of a materialised list, `itertools.islice` instead of a slice, and an index range instead of a sliced recursion.

  </details>

- **MUST** — The membership test on the wrong container

  <details><summary><strong>Answer</strong></summary>

  `if x in big_list` inside a loop is the most common accidental quadratic in Python, and converting the haystack to a `set` once before the loop fixes it outright. The same shape appears as a nested loop joining two lists on a key, where building a dict index first turns O(n·m) into O(n+m).

  Recognising this pattern in a code review is a more useful skill than any micro-optimisation, because the speed-up is measured in orders of magnitude.

  </details>

- **NICE** — Logging and exceptions in hot paths

  <details><summary><strong>Answer</strong></summary>

  `logger.debug(f"...")` formats the string before the call, so the cost is paid even when debug logging is off; `logger.debug("x=%s", x)` defers it to the handler. Building a traceback is expensive, so exceptions used for ordinary control flow in a tight loop are measurable — though at normal rates they are cheaper than the `if` chain they replace, which is why `EAFP` is idiomatic.

  </details>

- **NICE** — Doing one row at a time

  <details><summary><strong>Answer</strong></summary>

  A round trip per item — one `INSERT` per row, one HTTP request per record, one file open per line — is dominated by latency rather than by work, and batching is usually a hundredfold rather than a percentage. `executemany`, a bulk endpoint, or a chunked generator feeding a batch writer are the standard shapes.

  </details>

- **OPTIONAL** — Optimisations that are no longer true

  <details><summary><strong>Answer</strong></summary>

  Hoisting `len` into a local, preferring `map` over a comprehension, avoiding function calls and using `while` instead of `for` were all worth something on older interpreters and are mostly noise now. Quoting them without measuring is a signal that the knowledge is second-hand.

  </details>

## 12. Caching

**Why it comes up:** `lru_cache` is one line, so the interesting question is always invalidation and what the cache is hiding.

- **MUST** — `functools.lru_cache` and `cache`

  <details><summary><strong>Answer</strong></summary>

  `@lru_cache(maxsize=128)` memoises a function on its arguments, evicting the least recently used entry when full; `@cache` is the same with no bound. The arguments must be hashable, which is why a function taking a list or a dict cannot be memoised without converting them first.

  It is correct only for a **pure function** — same arguments, same result, no side effects — and applying it to something that reads a file, a clock or a database gives a program that is right until the underlying value changes. `cache_info` reports hits and misses and is how you find out whether it is doing anything.

  </details>

- **MUST** — The invalidation problem

  <details><summary><strong>Answer</strong></summary>

  A cache is a copy of the truth, so every cache has a policy for when the copy is wrong: time-based expiry, explicit invalidation on write, or versioning the key so a new value simply has a new key. `lru_cache` offers only `cache_clear`, which empties everything.

  Time-based expiry is the honest default because it bounds the staleness without requiring every writer to know about the cache. Explicit invalidation is exact and fragile, since it breaks the moment a new write path is added and nobody remembers the cache exists.

  </details>

- **MUST** — Caching on an instance method leaks

  <details><summary><strong>Answer</strong></summary>

  `@lru_cache` on a method keys on `self`, so the cache holds a strong reference to every instance it has ever seen and none of them can be collected — an unbounded leak in a long-running process, exactly where it hurts.

  `functools.cached_property` is the right tool for a per-instance computed value, because it stores the result in the instance's own dictionary and dies with the object. Where a real method cache is wanted, key it on the identifying fields rather than on `self`.

  </details>

- **MUST** — Cache stampede and the thundering herd

  <details><summary><strong>Answer</strong></summary>

  When a popular key expires, every concurrent request misses at once and all of them recompute it, so the moment of expiry is the moment of peak load — often heavier than having no cache at all. The defences are a lock or single-flight so that one caller computes while the others wait, serving the stale value while a refresh happens in the background, and jittering the expiry so keys do not fall due together.

  Naming this unprompted is a strong signal, because it is the failure that only appears under production concurrency.

  </details>

- **NICE** — Where the cache should live

  <details><summary><strong>Answer</strong></summary>

  In-process is fastest and is per worker, so with eight workers there are eight copies, eight warm-ups and eight versions of stale. A shared cache such as [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") is consistent across workers and costs a network round trip. A [CDN](https://en.wikipedia.org/wiki/Content_delivery_network "Content Delivery Network — Distributes cached content across edge locations to reduce latency") or an HTTP cache in front removes the request entirely and is cheaper than both.

  The choice follows the data: small, hot and derived goes in process; shared, expensive and invalidatable goes in the shared cache.

  </details>

- **NICE** — Measuring whether it helps

  <details><summary><strong>Answer</strong></summary>

  A hit rate below roughly 80% often means the cache is paying its costs — memory, staleness, a code path that only fires occasionally and is therefore less tested — without earning them. The number to watch alongside it is the latency percentile, since a cache can improve the mean while leaving the tail exactly where it was.

  </details>

- **OPTIONAL** — What a cache is hiding

  <details><summary><strong>Answer</strong></summary>

  A cache added to make a slow query acceptable leaves the slow query in place, now firing only on a miss and therefore only under the worst conditions. Fixing the index first and then deciding whether the cache is still wanted is the order that leaves the system honest.

  </details>

## 13. Memory Layout and Object Overhead

**Why it comes up:** it explains why a Python process holding "a few million small things" uses gigabytes, and the fix is a structural choice rather than a tweak.

- **MUST** — What an object costs

  <details><summary><strong>Answer</strong></summary>

  Every object carries a header of a reference count and a type pointer, so a bare `object` is 16 bytes, an `int` is 28, a short `str` around 50, and an ordinary instance is roughly 50 plus its attribute storage. A list of a million small integers is therefore not 4 MB but closer to 40 once the integer objects are counted.

  This is the real reason Python uses more memory than C for the same data, and it is also why the effective remedies remove objects rather than shrink them.

  </details>

- **MUST** — The ladder of fixes, in order of effect

  <details><summary><strong>Answer</strong></summary>

  Do not hold it all: stream with a generator and keep one item at a time. If it must be held, hold it without per-element objects: `array.array` for homogeneous numbers, a NumPy array for anything numeric you will compute over, or columnar storage such as Arrow or Parquet for tabular data. Only then reduce per-object overhead with `__slots__` or a NamedTuple.

  The ordering matters because the first two are order-of-magnitude changes and the third is roughly half. `__slots__` and its trade-offs are covered in `Python-language.md`; the point here is where it sits in the ladder.

  </details>

- **MUST** — Why NumPy changes the arithmetic

  <details><summary><strong>Answer</strong></summary>

  A NumPy array is a single contiguous buffer of machine values with one Python object around the whole thing, so a million 64-bit floats are 8 MB rather than 40, with no per-element header and no pointer chasing. Operations run in C over the whole buffer, which also removes the interpreter dispatch per element.

  The boundary to state is that it is only a win for homogeneous numeric data operated on in bulk. Indexing a NumPy array element by element from Python is slower than a list, because each access builds a boxed scalar — so a loop over an array usually means the vectorised form was missed.

  </details>

- **MUST** — Why freed memory does not come back

  <details><summary><strong>Answer</strong></summary>

  CPython allocates small objects from pools within arenas; an arena is returned to the operating system only when it is entirely empty, so a single surviving object keeps a whole arena resident. That is **fragmentation**, and it is why a process that peaked at 4 GB and freed almost everything can still report 3 GB resident with no leak at all.

  The practical answers are to avoid the peak rather than recover from it — process in chunks, stream, or do the large job in a separate process that exits and returns everything at once.

  </details>

- **NICE** — Measuring memory honestly

  <details><summary><strong>Answer</strong></summary>

  `sys.getsizeof` reports one object and not what it references, so it under-reports a container by everything that matters. `tracemalloc` attributes allocations to source lines, `memray` gives a fuller picture including extensions, and the resident size of the process is the number that decides whether the container is killed.

  Quote the last one when discussing limits, because a pod's memory limit is enforced against [RSS](https://en.wikipedia.org/wiki/Resident_set_size "Resident Set Size — The amount of physical memory a process currently occupies") and not against anything Python reports.

  </details>

- **NICE** — Sharing data between processes

  <details><summary><strong>Answer</strong></summary>

  Forked workers do not keep sharing a large preloaded structure, because touching an object writes to its reference count and copies the page. `multiprocessing.shared_memory`, an `mmap`, or a NumPy array over a shared buffer are the ways to actually share, and `gc.freeze` before forking reduces the damage for the remaining objects.

  </details>

- **OPTIONAL** — Interning and deduplication at scale

  <details><summary><strong>Answer</strong></summary>

  Millions of rows holding the same handful of category strings hold millions of separate string objects unless something deduplicates them. `sys.intern` on the way in, or a categorical type in pandas or Arrow, collapses that to one object per distinct value and can be the single largest saving in a data pipeline.

  </details>

## 14. Streaming Over Large Data

**Why it comes up:** "this file does not fit in memory" is a real constraint with a clean Python answer, and the pipeline shape is worth showing.

- **MUST** — Read lazily, process lazily, write lazily

  <details><summary><strong>Answer</strong></summary>

  Iterating a file yields one line at a time, a generator stage transforms without materialising, and a writer consumes as it goes — so a hundred-gigabyte file passes through a process with a few megabytes resident. The protocol behind that laziness is covered in `Python-language.md`; the shape is what matters here.

  The discipline is that a single `list(...)` or a `sorted(...)` anywhere in the chain defeats all of it, because both must hold everything. Sorting a stream that does not fit means an external merge sort, which is where the constraint stops being free.

  </details>

- **MUST** — The `itertools` vocabulary for streams

  <details><summary><strong>Answer</strong></summary>

  `islice` for a window or a limit, `chain` to concatenate sources, `batched` from 3.12 to chunk into fixed-size tuples for bulk writes, `groupby` for runs — which requires the input to be sorted by the key already, and silently produces nonsense if it is not — and `takewhile` and `dropwhile` for boundaries.

  `tee` deserves a warning: it buffers everything the slower consumer has not yet read, so teeing a large stream and consuming one branch fully before the other holds the whole thing in memory.

  </details>

- **MUST** — Chunking for the downstream system

  <details><summary><strong>Answer</strong></summary>

  Per-item processing in memory is cheap, but per-item round trips are not, so a streaming pipeline usually batches at its edges: read row by row, accumulate a thousand, write once. That keeps memory bounded and the round trips amortised, which is the combination that makes a stream fast as well as small.

  The batch size is a real trade — larger means fewer round trips and more lost work on a failure, and a partial batch at the end must still be flushed, which is the bug this shape most often has.

  </details>

- **MUST** — Where laziness makes debugging harder

  <details><summary><strong>Answer</strong></summary>

  An exception raised inside a generator surfaces at the point of consumption, so the traceback names the `for` loop rather than the stage that failed — and validation written at the top of a generator function does not run until the first item is pulled.

  Cleanup has the same issue: a generator abandoned part way is finalised whenever it is collected, so a file it opened stays open until then. Opening the file outside the generator, or wrapping the consumption in a context manager, is what makes the lifetime explicit.

  </details>

- **NICE** — Reading structured formats without loading them

  <details><summary><strong>Answer</strong></summary>

  `csv.reader` over a file object is already streaming. JSON is not: `json.load` builds the whole document, so a large array needs a streaming parser such as `ijson`, or the line-delimited JSON format, which turns the problem back into one object per line.

  For tabular data, Parquet with column and row-group selection reads a fraction of the file rather than streaming all of it, which is a better answer than streaming when it is available.

  </details>

- **NICE** — Backpressure

  <details><summary><strong>Answer</strong></summary>

  A producer that is faster than its consumer needs a bounded queue, or memory grows until the process dies. `queue.Queue(maxsize=n)` blocks the producer when full and `asyncio.Queue` does the same in a coroutine, and that blocking *is* the backpressure.

  An unbounded queue is not a performance choice, it is a deferred failure.

  </details>

- **OPTIONAL** — When streaming is the wrong answer

  <details><summary><strong>Answer</strong></summary>

  If the data fits comfortably and is traversed several times, a list is simpler, faster and easier to debug. Streaming buys a memory bound and costs single-pass access, so paying for it when the bound was never at risk is complexity with no return.

  </details>

## 15. Native Code and the GIL

**Why it comes up:** it is the part of the [GIL](https://wiki.python.org/moin/GlobalInterpreterLock "Global Interpreter Lock — CPython mechanism that lets only one thread execute Python bytecode at a time") answer that determines whether threads are useful to you, and it is where the "Python cannot use multiple cores" folklore breaks down.

- **MUST** — What releasing the lock means

  <details><summary><strong>Answer</strong></summary>

  A C extension brackets work that does not touch Python objects in `Py_BEGIN_ALLOW_THREADS` and `Py_END_ALLOW_THREADS`, dropping the interpreter lock for the duration — what that lock protects is covered in `Python-language.md`. Other threads then run Python bytecode while that work proceeds, so the process genuinely uses several cores.

  The condition is the important half: the released section may not touch any Python object, because the invariant the lock protects — chiefly reference counts — is not held during it. That is why the pattern fits self-contained numeric and I/O work and not code that calls back into Python.

  </details>

- **MUST** — What this enables in practice

  <details><summary><strong>Answer</strong></summary>

  Threads are the right model whenever the heavy work is already in C: NumPy and SciPy operations, `hashlib`, compression through `zlib` and `lz4`, image work in Pillow, and most database drivers during a query. A `ThreadPoolExecutor` over those scales across cores with shared memory and no pickling.

  The tell for whether it applies is simple and worth saying: if the hot loop is Python bytecode, use processes; if it is a single call into a compiled library, use threads.

  </details>

- **MUST** — Every blocking I/O call releases it too

  <details><summary><strong>Answer</strong></summary>

  Socket reads, file reads, `time.sleep` and `subprocess` waits all release the lock, which is why a thread pool making a hundred HTTP requests really does overlap them, and why threading was a reasonable answer for I/O concurrency long before `asyncio` existed.

  The difference against async is cost rather than capability: a thread carries a stack and a context switch, a coroutine does not, so threads stop scaling in the low thousands where coroutines do not.

  </details>

- **MUST** — What does not release it

  <details><summary><strong>Answer</strong></summary>

  Pure Python loops, and any extension that was written without the macros — including some older or smaller libraries, and any code that calls back into Python from inside the native section. Pure-Python JSON parsing, a regex over a large string and a `pickle` round trip all hold the lock for their duration.

  The honest way to find out is to measure: run the work in two threads and see whether the wall-clock time halves. If it does not, the library is holding the lock and processes are the answer.

  </details>

- **NICE** — The free-threaded build changes the calculus

  <details><summary><strong>Answer</strong></summary>

  With the lock gone, pure Python threads become genuinely parallel and the reason to reach for `multiprocessing` largely disappears — at the cost of every data race in existing threaded code becoming real. The build itself is covered in `Python-language.md`, and what it means for choosing a concurrency model in `Python-concurrency.md`.

  </details>

- **NICE** — Oversubscription when libraries are already threaded

  <details><summary><strong>Answer</strong></summary>

  NumPy's [BLAS](https://www.netlib.org/blas/ "Basic Linear Algebra Subprograms — Standard low-level routines that numeric libraries use for vector and matrix operations") backend often starts a thread per core on its own, so running eight worker processes each with an eight-thread BLAS creates sixty-four threads fighting over eight cores, and throughput falls. `OMP_NUM_THREADS=1` in the workers is the standard fix, and it is a real production problem rather than a curiosity.

  </details>

- **OPTIONAL** — Checking from the outside

  <details><summary><strong>Answer</strong></summary>

  `py-spy dump` on a busy multi-threaded process shows which threads are in Python frames and which are inside a native call, which answers the release question directly for a library whose source you have not read.

  </details>

## 16. C Extensions and the Alternatives

**Why it comes up:** it is the "what if Python is genuinely too slow" question, and the good answer starts by narrowing the part that has to leave Python.

- **MUST** — The options and what each is for

  <details><summary><strong>Answer</strong></summary>

  **Cython** compiles annotated Python to C and is the lowest-friction way to speed up an existing hot function. **ctypes** and **cffi** call an existing shared library with no build step, which is binding rather than acceleration. **PyO3** builds an extension in Rust, with memory safety and a good story for releasing the lock. Numba compiles numeric functions with a decorator and no build system at all.

  The choice follows the goal: accelerating your own loop is Cython or Rust, calling someone else's library is cffi, and numeric array work is usually NumPy or Numba before any of them.

  </details>

- **MUST** — Narrow the boundary first

  <details><summary><strong>Answer</strong></summary>

  Crossing between Python and native code costs per call, so a native function called a million times in a Python loop can be slower than the pure Python version. The win comes from moving the **loop** across the boundary, not the body — pass the whole array and return the whole result.

  That is the same reason vectorised NumPy beats element-wise NumPy, and it is the first thing to check when a rewrite in C produced no speed-up.

  </details>

- **MUST** — What it costs the project

  <details><summary><strong>Answer</strong></summary>

  A compiled extension means a build toolchain, wheels for every platform and Python version you support, a debugging story that now includes segmentation faults, and a new class of contributor barrier. `cibuildwheel` makes the distribution tractable but does not make it free.

  Say this before the technical detail: the honest sequence is profile, fix the algorithm, use an existing native library, and only then write one. Most cases end at step two or three.

  </details>

- **MUST** — Try the cheaper accelerations first

  <details><summary><strong>Answer</strong></summary>

  A better algorithm or data structure usually beats a rewrite in any language. After that: an existing C-backed library such as NumPy, `orjson` for serialisation or `re2` for pathological regexes; then `multiprocessing` if the work is parallel; then PyPy if the workload is pure Python and long-running.

  Each of those is a fraction of the cost of maintaining an extension, and each should be ruled out by measurement rather than by assumption.

  </details>

- **NICE** — The stable [ABI](https://docs.python.org/3/c-api/stable.html "Application Binary Interface — Defines the binary contract a compiled extension relies on to work with an interpreter build") and version churn

  <details><summary><strong>Answer</strong></summary>

  Building against the limited API and the stable ABI produces a wheel that works across Python versions, at the cost of some performance and access to internals. Without it, every minor release needs a new build — which is exactly why a project can be blocked from upgrading Python by one dependency.

  </details>

- **NICE** — Releasing the lock is the point

  <details><summary><strong>Answer</strong></summary>

  An extension that holds the interpreter lock throughout gives a faster function and no parallelism. Bracketing the pure computation so other threads can run is what turns it into a scaling win, and it is the first thing to check in a binding someone else wrote.

  </details>

- **OPTIONAL** — Subinterpreters and the extension ecosystem

  <details><summary><strong>Answer</strong></summary>

  Per-interpreter isolation requires extensions to declare multi-phase initialisation and to hold no process-global state, which much of the existing ecosystem does not yet do. That, rather than the interpreter work itself, is what paces adoption.

  </details>
