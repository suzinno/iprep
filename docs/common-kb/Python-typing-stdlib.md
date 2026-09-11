# Fundamental Topics: Python Typing and the Standard Library

**Table of Contents**

[Typing Topics](#typing-topics)

- [1. Gradual Typing](#1-gradual-typing)
- [2. Optional, Union and the Modern Syntax](#2-optional-union-and-the-modern-syntax)
- [3. mypy and pyright](#3-mypy-and-pyright)
- [4. Runtime Validation against Static Typing](#4-runtime-validation-against-static-typing)
- [5. Protocols and Structural Typing](#5-protocols-and-structural-typing)
- [6. Generics: TypeVar, ParamSpec and Self](#6-generics-typevar-paramspec-and-self)
- [7. Literal, Final, TypedDict and NewType](#7-literal-final-typeddict-and-newtype)
- [8. Variance](#8-variance)

[Standard Library and Idioms Topics](#standard-library-and-idioms-topics)

- [9. Exceptions and the Hierarchy](#9-exceptions-and-the-hierarchy)
- [10. try, except, else and finally](#10-try-except-else-and-finally)
- [11. EAFP and LBYL](#11-eafp-and-lbyl)
- [12. Logging](#12-logging)
- [13. datetime and Time Zones](#13-datetime-and-time-zones)
- [14. The Import System](#14-the-import-system)
- [15. json and pickle](#15-json-and-pickle)
- [16. subprocess](#16-subprocess)
- [17. Dependency Management and Lock Files](#17-dependency-management-and-lock-files)
- [18. Virtual Environments](#18-virtual-environments)
- [19. Packaging](#19-packaging)
- [20. pathlib against os.path](#20-pathlib-against-ospath)
**What this is.** The typing topics and the standard-library idioms a backend engineer is expected to reason about rather than recite, taken from two groups of the list in `docs/tmp/common-kb/Python.txt`. That list is long enough to be five documents; the others are `Python-language.md`, `Python-data-structures.md`, `Python-concurrency.md` and `Python-applications.md`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. [CPython](https://docs.python.org/3/ "CPython — The reference implementation of Python, written in C") is the concrete reference throughout, at a 3.12 baseline with later behaviour named where it differs, and mypy is the reference type checker because it is the implementation the specification is written against — pyright's differences are named where they matter rather than assumed away.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1 and topic 9 are the ones you are most likely to be asked. The grouping follows `Python.txt`: what a type annotation does and does not do, then the parts of the standard library and the surrounding tooling that every service uses.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 80 MUST, 40 NICE and 20 OPTIONAL across 20 topics. These are the topics an interviewer can check quickly and cheaply, which is why the MUST share is high: exceptions, logging, time zones and imports come up in the course of discussing anything else you have built.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Typing Topics

## 1. Gradual Typing

**Why it comes up:** the first thing to establish is that annotations do nothing at run time, because everything else about typing in Python follows from it.

- **MUST** — Annotations are not enforced

  <details><summary><strong>Answer</strong></summary>

  `def f(x: int) -> str` is a promise to a **type checker**, not a constraint the interpreter applies. Calling `f("hello")` runs happily, and the annotation is stored in `__annotations__` where introspection can read it. Nothing checks it unless a separate tool does.

  That is deliberate: it lets typing be added incrementally to an existing codebase, and it keeps the run-time cost at zero. The consequence is that data arriving from outside the program — a request body, a [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") file, a database row — is not made safe by a type hint, and needs a validator if it is to be trusted.

  </details>

- **MUST** — What gradual means, and what `Any` does

  <details><summary><strong>Answer</strong></summary>

  **Gradual typing** means annotated and unannotated code coexist, with the checker reasoning about what it has been told and stepping aside where it has not. An unannotated function is invisible to the checker, and `Any` is the explicit escape hatch that turns checking off for a value.

  The trap is that `Any` is contagious: one `Any` returned from a helper propagates through every expression that touches it, so a codebase can be extensively annotated and effectively unchecked. `--disallow-any-explicit` and `warn_return_any` are the settings that surface it, and `object` is the honest alternative when the type genuinely is unknown, because it forces a narrowing check before use.

  </details>

- **MUST** — What typing actually buys

  <details><summary><strong>Answer</strong></summary>

  A whole class of errors caught before the code runs — a `None` that was not handled, a renamed field, a changed signature, a branch that returns the wrong shape — plus editor completion and refactoring that works, and a signature that documents itself and cannot drift from the implementation.

  The costs are real and worth naming: annotating dynamic code is sometimes genuinely hard, the checker's error messages for generics are unfriendly, and a team that adds types without running the checker in [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") has paid the cost and taken none of the benefit.

  </details>

- **MUST** — Where annotations are evaluated

  <details><summary><strong>Answer</strong></summary>

  Historically annotations were evaluated at definition time, so a forward reference had to be quoted and an expensive import was paid at import time. `from __future__ import annotations` made them strings, and from 3.14 lazy evaluation is the default, which removes the quoting and most of the circular-import pain.

  The catch is anything that reads annotations at run time — [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime"), [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"), dataclasses, `attrs` — which must resolve them, and `typing.get_type_hints` is the supported way. That resolution is what fails with a confusing `NameError` when a type is only imported under `if TYPE_CHECKING:`.

  </details>

- **NICE** — `if TYPE_CHECKING` and import-only types

  <details><summary><strong>Answer</strong></summary>

  `if TYPE_CHECKING:` guards imports needed only for annotations, which breaks import cycles and keeps start-up cheap. The types imported there exist for the checker and not at run time, so anything that resolves annotations at run time will fail unless the name is also available.

  It is the standard fix for a circular import introduced by typing, and the standard cause of a `NameError` in a framework that reads hints.

  </details>

- **NICE** — Typing an existing codebase

  <details><summary><strong>Answer</strong></summary>

  The order that works is to turn the checker on in non-strict mode for the whole repository, fix what it finds, then raise strictness per module with a per-module configuration rather than globally. `# type: ignore[code]` with a specific error code is acceptable as a marker; a bare `# type: ignore` hides the next error too.

  Annotating the boundaries first — public functions, data models, external interfaces — gives most of the value for a small fraction of the work.

  </details>

- **OPTIONAL** — Run-time enforcement when it is wanted

  <details><summary><strong>Answer</strong></summary>

  `typeguard` and `beartype` check annotations at run time by decorating functions, and Pydantic does it for models. All of them cost per call, so the sensible placement is at a boundary rather than everywhere, which is the same conclusion validation reaches by a different route.

  </details>

## 2. Optional, Union and the Modern Syntax

**Why it comes up:** `Optional` being a union with `None` rather than "this argument may be omitted" is a small misunderstanding that produces a lot of wrong annotations.

- **MUST** — `Optional[X]` is `X | None`

  <details><summary><strong>Answer</strong></summary>

  `Optional[X]` means the value may be `X` or `None`. It says nothing about whether the parameter has a default or may be omitted — an optional *parameter* is expressed by giving it a default value, and the two are independent.

  Since 3.10 the spelling is `X | None`, which reads better and needs no import; `Optional` remains for older targets and is not deprecated. A function with a default of `None` should be annotated `X | None`, which is the single most common annotation in real code.

  </details>

- **MUST** — Narrowing, and why the checker insists

  <details><summary><strong>Answer</strong></summary>

  A value of type `str | None` cannot have `.upper()` called on it until the checker knows it is not `None`. **Narrowing** is how you tell it: an `if x is None: return` guard, an `isinstance` check, an `assert x is not None`, or a truthiness test — after which the type in that branch is the narrowed one.

  This is typing's largest practical benefit, because it makes every unhandled `None` visible before the code runs. Reaching for `assert` or a cast to silence it throws that away; handling the branch is the point.

  </details>

- **MUST** — Unions, and why a large one is a design smell

  <details><summary><strong>Answer</strong></summary>

  `int | str | bytes | None` forces every caller to narrow before doing anything, which usually means the function is doing several jobs, or that the data wants a class rather than a bag of alternatives. Two or three related members is normal; five is a message.

  A **discriminated union** is the version that works at scale: give each member a `Literal` tag field, and the checker narrows the whole object from a single test on that field — the same pattern `match` was designed around.

  </details>

- **MUST** — Containers and what `list[X]` really promises

  <details><summary><strong>Answer</strong></summary>

  Builtin generics from 3.9 mean `list[int]` and `dict[str, int]` rather than the `typing` equivalents. In a parameter, prefer the abstract type: `Iterable[int]` or `Sequence[int]` accepts a tuple, a generator or a list, while `list[int]` accepts only a list. Return types go the other way — return the concrete type, so the caller knows what they have.

  The rule of thumb is to be liberal in what you accept and specific in what you return, and it is enforceable by the checker rather than merely advisory.

  </details>

- **NICE** — `None` as a return type

  <details><summary><strong>Answer</strong></summary>

  `-> None` means the function returns nothing useful and is what every procedure should carry; omitting the return annotation entirely leaves the function unchecked in some configurations, which is why `disallow_untyped_defs` exists.

  `NoReturn` is different again: it marks a function that never returns normally because it always raises or exits, and it lets the checker treat the following code as unreachable.

  </details>

- **NICE** — Type aliases

  <details><summary><strong>Answer</strong></summary>

  A long union or a nested generic used in several places should be named: `type UserId = int` in the 3.12 syntax, or `UserId: TypeAlias = int` before it. It shortens signatures and gives the concept a name that can be searched for.

  An alias is transparent to the checker — `UserId` and `int` are interchangeable — so it documents rather than enforces. `NewType` is the version that creates a distinct type.

  </details>

- **OPTIONAL** — `Union` at run time

  <details><summary><strong>Answer</strong></summary>

  `isinstance(x, int | str)` works from 3.10, which is occasionally convenient. `typing.get_args` and `get_origin` are the introspection tools a library uses to walk an annotation, and they are how a validator discovers what a union contains.

  </details>

## 3. mypy and pyright

**Why it comes up:** knowing that the two disagree, and on what, is the difference between using a checker and having installed one.

- **MUST** — What a type checker does

  <details><summary><strong>Answer</strong></summary>

  It reads the source, infers types where they are not written, and reports calls and assignments that cannot be consistent — without running anything. That is the important property: it covers every branch, including the error paths a test suite never reaches, which is where `None` handling bugs live.

  It is not a substitute for tests. It proves that the types line up, not that the logic is right, and a fully typed function can be entirely wrong.

  </details>

- **MUST** — Strict mode is where the value is

  <details><summary><strong>Answer</strong></summary>

  In its default configuration mypy ignores unannotated functions entirely, so a codebase can pass with almost nothing checked. `--strict` turns on the settings that matter: `disallow_untyped_defs`, `disallow_any_generics`, `warn_return_any`, `no_implicit_optional` and `warn_unused_ignores`.

  The practical route on an existing codebase is strict for new modules and a per-module override for the old ones, tightened as they are touched. Running it in CI as a blocking gate is what makes any of it real.

  </details>

- **MUST** — How the two differ

  <details><summary><strong>Answer</strong></summary>

  **mypy** is the reference implementation, written by the people who wrote the specification, and it is generally the more conservative. **pyright** is much faster, is the engine behind Pylance in Visual Studio Code, and is usually ahead on new features, with stronger inference and better narrowing.

  They disagree at the edges, so a codebase should pick one as the gate and treat the other as advisory. Fighting two checkers with conflicting opinions in the same pipeline wastes more time than the second one finds.

  </details>

- **MUST** — Third-party libraries and stubs

  <details><summary><strong>Answer</strong></summary>

  A library is typed only if it ships a `py.typed` marker; otherwise the checker sees `Any` everywhere it is used. `types-requests` and its siblings from `typeshed` are separately installed stub packages that fill the gap for untyped libraries.

  `ignore_missing_imports` silences the resulting errors and also silences everything downstream of them, so it should be scoped per module rather than set globally. This is the most common reason a codebase that "has mypy" checks far less than it appears to.

  </details>

- **NICE** — `cast`, `reveal_type` and the escape hatches

  <details><summary><strong>Answer</strong></summary>

  `typing.cast(X, value)` asserts a type to the checker and does nothing at run time — it is a promise, so a wrong cast is a lie the checker will believe. `reveal_type(x)` makes the checker print what it inferred, which is the fastest way to understand an error.

  `# type: ignore[arg-type]` with the specific code is the narrow form of silencing, and `warn_unused_ignores` is what stops those markers accumulating after the underlying problem is fixed.

  </details>

- **NICE** — Performance and caching

  <details><summary><strong>Answer</strong></summary>

  mypy caches per module in `.mypy_cache` and is slow on a cold run over a large codebase; the daemon `dmypy` keeps that state warm for editor-speed feedback. pyright is fast enough that the question rarely arises.

  In CI the cache is worth persisting, because a several-minute type check on every pull request is how a gate gets disabled.

  </details>

- **OPTIONAL** — The other checkers

  <details><summary><strong>Answer</strong></summary>

  `pyre` from Meta and `pytype` from Google both exist and both have a following; `ty` and `pyrefly` are newer and much faster, written in Rust. The specification is shared, so the choice is about speed, strictness and tooling rather than about semantics.

  </details>

## 4. Runtime Validation against Static Typing

**Why it comes up:** Pydantic and mypy look like alternatives and are not, and saying why is a clean architectural answer.

- **MUST** — They do different jobs

  <details><summary><strong>Answer</strong></summary>

  A static checker verifies the code you wrote, before it runs, against data it can see in the source. A **validator** checks values at run time, and is the only one of the two that can say anything about data that came from outside the program — a request body, a message, a configuration file, a database row.

  So they are complementary rather than competing: the checker covers the inside of the program and the validator covers its boundary. A codebase with both has the whole surface; one with only a checker trusts every input.

  </details>

- **MUST** — Where the boundary goes

  <details><summary><strong>Answer</strong></summary>

  Validate once, at the edge, converting untrusted input into a typed object — then pass that object inward and do not re-validate. That gives a single place where malformed data is rejected, a single place where error messages are produced, and typed confidence everywhere else.

  The anti-pattern is validating in several layers, which is slow, produces inconsistent errors, and still leaves nobody sure whether the value has been checked. The other anti-pattern is a dict passed five levels deep and checked with `.get` at each one.

  </details>

- **MUST** — What Pydantic actually does

  <details><summary><strong>Answer</strong></summary>

  It reads the annotations on a model and generates a validator that parses and coerces input into typed fields, raising a structured `ValidationError` listing every failure with its location. Version 2 does that work in Rust, which made it fast enough to sit in a hot request path.

  The word to be careful with is **parse** rather than validate: by default it converts where it safely can, so the string `"5"` becomes `5` for an `int` field. Strict mode turns that off, and knowing which one is in effect is the difference between a lenient [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") and a surprising one.

  </details>

- **MUST** — When a dataclass is the better choice

  <details><summary><strong>Answer</strong></summary>

  Inside the trusted boundary, where the data has already been validated, a dataclass is cheaper, has no dependency, and expresses the same shape. Re-validating a value you constructed yourself is pure cost.

  The rule is validated types at the edge and plain typed objects inside. A codebase where every internal function takes a Pydantic model is paying validation on data that was proved correct three calls ago.

  </details>

- **NICE** — Validation beyond types

  <details><summary><strong>Answer</strong></summary>

  Types cannot express that a string is a valid email address, that an integer is positive, that an end date follows a start date, or that exactly one of two fields is set. Those are field validators, constrained types and model validators, and they are the reason a validator library is wanted even where the types are already known.

  A type checker will never catch them, which is the clearest illustration that the two tools are not substitutes.

  </details>

- **NICE** — Errors as an API contract

  <details><summary><strong>Answer</strong></summary>

  A validation error is something a client sees, so its shape is part of the interface: which field failed, why, and a stable machine-readable code. Returning the library's default representation exposes internal field names and changes when the library does.

  Mapping validation errors to a documented error response is a small amount of work that turns a debugging aid into an interface.

  </details>

- **OPTIONAL** — The alternatives

  <details><summary><strong>Answer</strong></summary>

  `attrs` with validators, `marshmallow` for schema-first work, `cattrs` for structuring and unstructuring without a model base class, and `jsonschema` where the schema is the contract and is shared with other languages. Pydantic dominates because it reuses annotations, which means one declaration serves both jobs.

  </details>

## 5. Protocols and Structural Typing

**Why it comes up:** it is the duck-typing question with a type-checker answer, and choosing between a Protocol and an [ABC](https://docs.python.org/3/library/abc.html "Abstract Base Class — Declares an interface that subclasses must implement and cannot be instantiated directly") is a real design decision.

- **MUST** — Structural against nominal

  <details><summary><strong>Answer</strong></summary>

  Nominal typing asks what a class inherits from; **structural** typing asks what shape it has. A `typing.Protocol` declares the methods and attributes a type must provide, and any class providing them satisfies it — with no inheritance, no registration and no import of the protocol by the implementer.

  That is static duck typing: the flexibility Python has always had, now visible to the checker. It is what lets you type a parameter as "anything with a `read` method" without demanding that every caller's class inherit from something of yours.

  </details>

- **MUST** — When to prefer a Protocol over an ABC

  <details><summary><strong>Answer</strong></summary>

  Use a Protocol when the implementers are not yours to change — a third-party class, a test double, an object from another package — and when the interface is about capability rather than identity. Use an `abc.ABC` when you own the hierarchy, want shared implementation, and want instantiation of an incomplete subclass to fail at run time.

  The deciding question is who is bound: an ABC binds the implementer, a Protocol binds only the consumer's expectation. For a boundary between packages, that makes the Protocol the looser and usually better coupling.

  </details>

- **MUST** — Protocols make test doubles honest

  <details><summary><strong>Answer</strong></summary>

  A function taking a `Protocol` can be given a small hand-written fake that implements the two methods used, and the checker verifies the fake matches. That is strictly better than a `Mock`, which satisfies any attribute access and therefore keeps passing after the real interface changes.

  This is the argument that tends to land in a review: structural typing makes the seam explicit, and the explicit seam is what stops mocks from drifting away from reality.

  </details>

- **MUST** — What a Protocol costs

  <details><summary><strong>Answer</strong></summary>

  It is a static construct, so nothing is enforced at run time unless it is decorated `@runtime_checkable` — and even then `isinstance` only checks that the method *names* exist, not their signatures. It is a weaker run-time check than it appears.

  Errors are also reported at the call site rather than at the class, so a class that nearly implements a protocol produces a message far from the mistake. Declaring `class Impl(MyProtocol):` explicitly is allowed and gets the error reported where the class is.

  </details>

- **NICE** — The protocols already in the standard library

  <details><summary><strong>Answer</strong></summary>

  `Iterable`, `Iterator`, `Sequence`, `Mapping`, `Callable`, `Hashable`, `SupportsInt`, `SupportsFloat` and the file-like `IO` types cover most needs, so a custom protocol is often unnecessary. Accepting `Iterable[str]` rather than `list[str]` is the everyday version of this advice.

  </details>

- **NICE** — Protocols with attributes and generics

  <details><summary><strong>Answer</strong></summary>

  A protocol can declare attributes as well as methods, and can be generic — `class Repo(Protocol[T])` with `get(self, id: str) -> T`. That is what makes it usable for the repository and adapter shapes where an ABC would otherwise be reached for.

  A mutable attribute in a protocol makes it invariant in that attribute, which is the usual source of a confusing variance error.

  </details>

- **OPTIONAL** — ABC registration

  <details><summary><strong>Answer</strong></summary>

  `ABCMeta.register` declares an existing class as a virtual subclass, satisfying `isinstance` without inheritance and without any check that the methods exist. It predates Protocols and solves a similar problem far less safely.

  </details>

## 6. Generics: TypeVar, ParamSpec and Self

**Why it comes up:** it is where typing stops being annotation and starts being design, and a correctly generic function is a clear signal of fluency.

- **MUST** — What a TypeVar does

  <details><summary><strong>Answer</strong></summary>

  A **type variable** links types across a signature: `def first(items: Sequence[T]) -> T` says the return type is whatever the sequence contained, so passing `list[str]` yields `str`. Without it the honest annotation is `Any`, and everything downstream loses its type.

  The 3.12 syntax makes it local and unnamed at module level — `def first[T](items: Sequence[T]) -> T` — which removes the boilerplate of declaring a `TypeVar` beside every function that uses one.

  </details>

- **MUST** — Bounds and constraints

  <details><summary><strong>Answer</strong></summary>

  A **bound** says the type must be a subtype of something: `T: Comparable` allows any orderable type and keeps the specific one. **Constraints** list the exact types allowed: `AnyStr` is the classic, allowing `str` or `bytes` and nothing between them.

  The difference matters because a constrained variable resolves to one of the listed types, so a function taking two constrained arguments cannot mix them — which is exactly the property that stops `str` and `bytes` being concatenated by accident.

  </details>

- **MUST** — Generic classes

  <details><summary><strong>Answer</strong></summary>

  `class Repository[T]` — or the older `Generic[T]` base — makes a container or a service generic in the type it holds, so `Repository[User]` has a `get` that returns a `User`. This is where typing pays off in application code: a repository, a cache, a result wrapper.

  The place people get stuck is variance, which follows from whether the parameter appears in arguments, in return types, or in both. Where a class only produces values, declaring it covariant makes it usable where a subtype was expected.

  </details>

- **MUST** — `Self` and returning your own type

  <details><summary><strong>Answer</strong></summary>

  `Self` from 3.11 annotates a method that returns the instance's own type, so a fluent builder or an alternative constructor keeps the *subclass* type rather than collapsing to the base class. Hard-coding the class name in the return annotation is the bug it replaces, and it is invisible until someone subclasses.

  It also makes `classmethod` factories correct: `def from_row(cls, row) -> Self` returns the subclass when called on one.

  </details>

- **NICE** — `ParamSpec` for decorators

  <details><summary><strong>Answer</strong></summary>

  A decorator annotated with `Callable[..., Any]` erases the signature of everything it wraps, which silently unchecks the decorated function. `ParamSpec` preserves it: `def deco[**P, R](f: Callable[P, R]) -> Callable[P, R]` keeps every parameter and the return type intact.

  `Concatenate` extends it for decorators that add or remove a leading argument, which is the shape of most dependency-injecting decorators.

  </details>

- **NICE** — Overloads

  <details><summary><strong>Answer</strong></summary>

  `@overload` declares several signatures for one implementation, which is how a function whose return type depends on its arguments is typed — the classic being a `get` whose return is `X` with a default and `X | None` without. The overloads are for the checker only; the single implementation carries the real body.

  Reaching for overloads more than occasionally usually means two functions were wanted.

  </details>

- **OPTIONAL** — Type parameter defaults

  <details><summary><strong>Answer</strong></summary>

  From 3.13 a type parameter can have a default, so `class Repo[T = User]` lets `Repo` be written bare and still mean something specific. It mainly removes boilerplate in library code with deep generic nesting.

  </details>

## 7. Literal, Final, TypedDict and NewType

**Why it comes up:** these are the annotations that express intent rather than shape, and using them well is what makes a checker catch domain errors rather than only type errors.

- **MUST** — `Literal` and exhaustiveness

  <details><summary><strong>Answer</strong></summary>

  `Literal["read", "write"]` restricts a value to specific constants, which turns a stringly-typed parameter into something the checker can verify at every call site. It is the mechanism behind a discriminated union: a `kind: Literal["circle"]` field lets the checker narrow the whole object from one test.

  Paired with `assert_never` in the final `else`, it gives **exhaustiveness checking**: add a new member to the union and every unhandled `match` or `if` chain becomes a type error. That is the single most valuable thing the checker does in domain code, because it turns "find every place that handles this enum" into a compile-time list.

  </details>

- **MUST** — `TypedDict`

  <details><summary><strong>Answer</strong></summary>

  It annotates the shape of a dict — the keys and the type of each value — while remaining a plain dict at run time, with no class and no validation. That is exactly right for decoded JSON that is passed straight back out, and it lets the checker catch a typo in a key.

  `total=False`, or `NotRequired` per key, marks optional keys. It cannot carry methods or defaults, and it does not check anything at run time, so data arriving from outside still needs a validator — the TypedDict describes the promise, it does not enforce it.

  </details>

- **MUST** — `Final` and constants

  <details><summary><strong>Answer</strong></summary>

  `MAX: Final = 100` tells the checker the name is never rebound, and `@final` on a class or method forbids subclassing or overriding. Neither is enforced at run time; both are enforced everywhere the checker runs, which in a CI-gated codebase is enough.

  `Final` also enables literal-type inference, so the constant keeps its literal type rather than widening to `int` — which is what makes it usable in a `Literal` union.

  </details>

- **MUST** — `NewType` for domain identity

  <details><summary><strong>Answer</strong></summary>

  `UserId = NewType("UserId", int)` creates a type the checker treats as distinct from `int`, while at run time it is exactly an `int` with no wrapper and no cost. Passing an `OrderId` where a `UserId` was expected becomes an error, and the classic bug of swapping two integer identifiers in a call becomes impossible.

  It is deliberately weaker than a wrapper class: no methods, no validation, no run-time distinction. That weakness is the point, because it makes adoption free.

  </details>

- **NICE** — `Annotated` for metadata

  <details><summary><strong>Answer</strong></summary>

  `Annotated[int, Field(gt=0)]` attaches metadata to a type that the checker ignores and a library reads. It is how Pydantic expresses constraints and how FastAPI expresses where a parameter comes from, without inventing a parallel annotation syntax.

  </details>

- **NICE** — Enum against Literal

  <details><summary><strong>Answer</strong></summary>

  An `Enum` gives a real object with a name, a value and somewhere to hang methods, and it supports exhaustiveness checking too. `Literal` is lighter and keeps the wire format — a JSON string stays a string — which is why it is usually better at an API boundary and an Enum is better in domain logic.

  </details>

- **OPTIONAL** — `ClassVar` and `ReadOnly`

  <details><summary><strong>Answer</strong></summary>

  `ClassVar` marks an attribute as belonging to the class rather than the instance, which a dataclass needs in order not to treat it as a field. `ReadOnly` from 3.13 marks a TypedDict key that must not be reassigned.

  </details>

## 8. Variance

**Why it comes up:** it is the typing topic most people cannot explain, and the practical form of the question — why `list[Dog]` is not a `list[Animal]` — has a clean answer.

- **MUST** — Why `list[Dog]` is not a `list[Animal]`

  <details><summary><strong>Answer</strong></summary>

  If it were, a function taking `list[Animal]` could append a `Cat` to your list of dogs, and every later read would be wrong. Mutability is what forbids it: a container you can write to is **invariant** in its element type.

  The immutable counterpart is different — `Sequence[Dog]` *is* a `Sequence[Animal]`, because you can only read from it. That is the whole rule in one comparison, and it is the answer to give before any vocabulary.

  </details>

- **MUST** — The three words

  <details><summary><strong>Answer</strong></summary>

  **Covariant** means the container follows its parameter: `Sequence[Dog]` is a `Sequence[Animal]`, which is safe for producers — things you only read out of. **Contravariant** means it goes the other way: a `Callable[[Animal], None]` can be used where a `Callable[[Dog], None]` is wanted, because a handler that accepts any animal certainly accepts a dog. **Invariant** means neither, which is what mutability forces.

  The mnemonic worth carrying is producers are covariant, consumers are contravariant, and anything that does both is invariant.

  </details>

- **MUST** — Where it shows up in practice

  <details><summary><strong>Answer</strong></summary>

  In parameter annotations: taking `Sequence[Animal]` or `Iterable[Animal]` rather than `list[Animal]` lets a caller pass a `list[Dog]`, which is usually what was meant and is the fix for the error people hit first.

  It also shows up in callbacks, where a handler is contravariant in its argument, and in generic classes you write, where a `Repository[T]` that both stores and returns `T` is invariant and cannot be substituted for a supertype's repository.

  </details>

- **MUST** — Declaring it on your own generics

  <details><summary><strong>Answer</strong></summary>

  A type parameter used only in return positions can be declared covariant, and one used only in argument positions contravariant; the 3.12 syntax infers this automatically, which is one of the better reasons to adopt it. Before that it was `TypeVar("T_co", covariant=True)` by hand.

  If the checker rejects a variance declaration, it has found a real hole: a covariant parameter appearing in an argument position is exactly the unsound case that would let a wrong value in.

  </details>

- **NICE** — `Mapping` against `dict` in signatures

  <details><summary><strong>Answer</strong></summary>

  `Mapping[str, Animal]` is covariant in its value type and read-only, so it accepts a `dict[str, Dog]`; `dict[str, Animal]` does not. Accepting the abstract read-only type is therefore both more permissive and more honest about what the function does with it.

  </details>

- **NICE** — Why `Any` sidesteps all of it

  <details><summary><strong>Answer</strong></summary>

  `Any` is compatible in both directions, so annotating around a variance error with `Any` makes the message go away and removes the checking that would have caught the real mistake. The correct fix is almost always to accept a read-only abstract type instead.

  </details>

- **OPTIONAL** — Function return and argument variance

  <details><summary><strong>Answer</strong></summary>

  `Callable` is contravariant in its arguments and covariant in its return type, which is the formal statement of "a function that accepts more and returns less is a safe substitute". It is the same rule that governs overriding a method in a subclass.

  </details>

## Standard Library and Idioms Topics

## 9. Exceptions and the Hierarchy

**Why it comes up:** catching too broadly is the most common defect in otherwise good Python, and exception chaining is a small feature that transforms a production traceback.

- **MUST** — The hierarchy, and why it matters what you catch

  <details><summary><strong>Answer</strong></summary>

  Everything derives from `BaseException`. **`Exception`** is the branch for ordinary errors; `KeyboardInterrupt`, `SystemExit` and `asyncio.CancelledError` sit outside it deliberately, so that `except Exception` does not swallow a Ctrl-C, an intentional exit or a cancellation.

  That is the reason to catch `Exception` rather than `BaseException`, and the reason a bare `except:` is wrong — it catches the three things you must not catch, and turns a killable program into one that ignores its shutdown signal.

  </details>

- **MUST** — Catch narrowly, and catch what you can handle

  <details><summary><strong>Answer</strong></summary>

  An `except` clause should name the exceptions the block can actually do something about, and the block should do something: retry, substitute a default, translate to a domain error, or add context and re-raise. Catching broadly to log and continue leaves the program running on state it has not checked.

  The rule that follows is that the narrower the try block, the better the diagnosis — wrapping twenty lines in one `try` means an error anywhere in them is attributed to the same cause. Wrap the call that can fail, not the function that contains it.

  </details>

- **MUST** — Chaining with `raise from`

  <details><summary><strong>Answer</strong></summary>

  `raise DomainError("could not load user") from exc` sets `__cause__`, so the traceback shows both the new exception and the original with "The above exception was the direct cause" between them. Raising inside an `except` without `from` still attaches the original as `__context__`, printed as "During handling of the above exception" — which is implicit chaining, and usually enough.

  `raise ... from None` suppresses the original deliberately, which is right when the internal cause would leak an implementation detail to a user and wrong when you are hiding it from yourself. **The consequence is** that a wrapped exception keeps the root cause in the log instead of replacing it, which is the difference between a debuggable error and a mystery.

  </details>

- **MUST** — Custom exceptions

  <details><summary><strong>Answer</strong></summary>

  Define a base exception per package or per domain and derive specific ones from it, so a caller can catch the whole family or one member. Carry structured data as attributes — the identifier that was not found, the field that failed — rather than only a formatted message, because callers and log processors need the value, not the sentence.

  The purpose is to separate the layer's vocabulary from its implementation: a repository raising `UserNotFound` rather than a driver-specific error means the service above it is not coupled to the database. Inheriting from a built-in such as `ValueError` is reasonable when the semantics really match, and misleading otherwise.

  </details>

- **NICE** — Exception groups

  <details><summary><strong>Answer</strong></summary>

  `ExceptionGroup` and `except*` from 3.11 let several failures propagate together rather than the first one winning, which is what concurrent code needs — a task group raises one when more than one of its tasks failed.

  `except* ValueError` handles the members of that type and leaves the rest to propagate, so a handler can deal with the part it understands without discarding the others.

  </details>

- **NICE** — Notes and richer messages

  <details><summary><strong>Answer</strong></summary>

  `exc.add_note("while processing row 412")` from 3.11 attaches context to an exception as it travels, which is the clean alternative to catching, reformatting and re-raising with a new message. The notes appear in the traceback beneath the exception.

  </details>

- **OPTIONAL** — Cost, and exceptions as control flow

  <details><summary><strong>Answer</strong></summary>

  Raising is more expensive than returning because a traceback is built, but a `try` block that does not raise is nearly free — which is why the idiomatic style prefers trying over checking. In a loop where the exceptional case is the common case, the cost stops being negligible and a check is better.

  </details>

## 10. try, except, else and finally

**Why it comes up:** `else` is the clause most people cannot explain, and what `finally` does to a `return` is a precise question with a surprising answer.

- **MUST** — What each clause is for

  <details><summary><strong>Answer</strong></summary>

  `try` holds the code that may fail; `except` handles a failure; `else` runs only if no exception was raised; `finally` runs on every path out, including a `return`, a `break` and an exception propagating.

  `else` exists so that the `try` block can be kept to the statement that can actually raise. Code that should run on success but must not be covered by the handler belongs there — otherwise an error it raises is caught by an `except` that was written for a different call.

  </details>

- **MUST** — `finally` and the return it swallows

  <details><summary><strong>Answer</strong></summary>

  `finally` runs after the return value has been computed but before the function actually returns, so it can see the value and can override it: a `return` inside `finally` replaces the one that was in flight, and — worse — discards any exception that was propagating.

  That is the trap. A `return` or a `break` inside `finally` silently swallows an exception, which is the single most effective way to make a failure invisible. Put cleanup there and nothing else, or use a context manager.

  </details>

- **MUST** — Swallowing errors

  <details><summary><strong>Answer</strong></summary>

  `except Exception: pass` is the line that causes the most production confusion, because the system continues on unknown state and nothing is recorded. If an error genuinely can be ignored, the code should say which error and why — `contextlib.suppress(FileNotFoundError)` with a comment says both in one line.

  The intermediate case is logging and continuing, which is only honest if the caller can proceed meaningfully without the result. `logger.exception` inside a handler records the traceback, where `logger.error` records only the message.

  </details>

- **MUST** — Order of `except` clauses

  <details><summary><strong>Answer</strong></summary>

  Clauses are tested in order and the first match wins, so a broad class before a narrow one makes the narrow one dead code — `except Exception` above `except ValueError` means the specific handler never runs. Most linters catch it; knowing why is better.

  A tuple catches several types with one handler: `except (ValueError, TypeError) as exc`. The `as` name is deleted at the end of the block, which is why using it afterwards raises `NameError`.

  </details>

- **NICE** — Retrying

  <details><summary><strong>Answer</strong></summary>

  A retry loop belongs around transient failures only — a timeout, a connection reset, a 503 — and never around a validation error or a 400, which will fail identically every time. Exponential backoff with jitter is what stops a retry storm from synchronising across clients and finishing off a service that was recovering.

  Retrying a non-idempotent operation can duplicate its effect, so an idempotency key or a check before the retry is part of the design rather than an optional extra.

  </details>

- **NICE** — Cleanup without `finally`

  <details><summary><strong>Answer</strong></summary>

  A context manager is the better expression of paired acquire and release, because it cannot be forgotten at the second call site and the pairing lives with the resource rather than with the caller. `try/finally` remains right for cleanup that is specific to one block.

  </details>

- **OPTIONAL** — The traceback object

  <details><summary><strong>Answer</strong></summary>

  `traceback.format_exc` inside a handler gives the formatted string, and `sys.exc_info` gives the parts. Keeping a reference to a traceback keeps every frame it names alive, including their local variables, which is a real way to hold a large object long after it was needed.

  </details>

## 11. EAFP and LBYL

**Why it comes up:** it is the question that asks whether you write Python or write another language in Python.

- **MUST** — The two styles

  <details><summary><strong>Answer</strong></summary>

  [EAFP](https://docs.python.org/3/glossary.html "Easier to Ask Forgiveness than Permission — Python idiom of attempting an operation and handling the exception rather than testing first") — easier to ask forgiveness than permission — does the thing and handles the failure: `try: return d[key] except KeyError: ...`. [LBYL](https://docs.python.org/3/glossary.html "Look Before You Leap — Style that tests preconditions before performing an operation") — look before you leap — checks first: `if key in d: return d[key]`.

  Python's idiom is EAFP, and the reason is correctness rather than taste. The check-then-act form has a gap between the check and the action, so in concurrent code the state can change in between — a file that existed when you asked and does not when you open it. The `try` form has no such gap, because the operation itself is what reports the failure.

  </details>

- **MUST** — Why EAFP is usually also faster

  <details><summary><strong>Answer</strong></summary>

  The check costs on every call, while the exception costs only when it fires. So when the failure is rare, EAFP pays almost nothing and LBYL pays a lookup every time — and when the failure is common, the balance reverses, because raising is genuinely expensive.

  That gives the rule: EAFP when the happy path dominates, an explicit check when the failure is expected often enough to be ordinary. Saying which way round it is, rather than reciting a preference, is the answer.

  </details>

- **MUST** — Where LBYL is right

  <details><summary><strong>Answer</strong></summary>

  When the check is cheap and the failure is a normal outcome: validating user input, choosing between branches, guarding a division by zero. Also when the operation has a side effect that a failure would leave half-done, since asking forgiveness after a partial write is not a recovery.

  And where a specific exception cannot be isolated: a `try` around something that can fail in five unrelated ways catches too much, and a check for the one condition you care about is clearer.

  </details>

- **MUST** — The idioms that make the question moot

  <details><summary><strong>Answer</strong></summary>

  `dict.get(key, default)` and `setdefault`, `getattr(obj, name, default)`, `next(it, default)`, `contextlib.suppress`, and a `defaultdict` all express the fallback directly with no `try` and no check. Reaching for them first is the most idiomatic answer of the three.

  Naming a couple of these is what distinguishes an answer about style from an answer about the language.

  </details>

- **NICE** — Race conditions this actually prevents

  <details><summary><strong>Answer</strong></summary>

  `if os.path.exists(p): open(p)` is a genuine time-of-check to time-of-use bug: the file can be deleted or replaced in between, and in a security context replaced by a symlink to something else. Opening and catching `FileNotFoundError` has no window.

  The same shape appears with a directory check before a create — `os.makedirs(p, exist_ok=True)` is the version with no window at all.

  </details>

- **NICE** — Type checkers prefer narrowing

  <details><summary><strong>Answer</strong></summary>

  A checker narrows types through an `if` and through `isinstance`, and does the same through an `except` block less completely. Where the value is `X | None`, an explicit `is None` check both satisfies the checker and documents the branch, which is a mild argument for LBYL in typed code.

  </details>

- **OPTIONAL** — Duck typing as the same instinct

  <details><summary><strong>Answer</strong></summary>

  Calling a method and letting `AttributeError` decide is the EAFP version of an `isinstance` check, and it is why Python code historically accepted anything with the right shape. A `Protocol` is the modern way to say the same thing where a checker can verify it.

  </details>

## 12. Logging

**Why it comes up:** every production incident is investigated through logs, so how they are produced says a great deal about whether the candidate has operated a service.

- **MUST** — Why not `print`

  <details><summary><strong>Answer</strong></summary>

  `print` has no level, no timestamp, no logger name, no structure, no way to be turned down in production or up during an incident, and it goes to stdout whatever the context. Logging gives all of that with the same amount of typing, and it lets a library emit messages that the application decides what to do with.

  The rule in a library is to get a logger with `logging.getLogger(__name__)` and configure nothing — configuration belongs to the application, and a library that adds handlers or sets levels is overriding a decision that is not its own.

  </details>

- **MUST** — Loggers, handlers, levels and formatters

  <details><summary><strong>Answer</strong></summary>

  A **logger** is where the message is emitted and is named hierarchically by module, so `myapp.db` inherits from `myapp`. A **handler** decides where records go — stream, file, [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") — and a **formatter** decides how they look. A record is filtered by the logger's level, then by each handler's level.

  Propagation is the part people trip on: a record travels up to ancestor loggers' handlers, so configuring both a child and the root produces every line twice. Configure handlers at the root and levels per logger.

  </details>

- **MUST** — Lazy formatting and structured logs

  <details><summary><strong>Answer</strong></summary>

  `logger.info("user %s failed", user_id)` defers formatting until a handler actually emits the record, so a debug line costs nothing when debug is off; an f-string formats first and pays the cost regardless.

  In a service, the format that matters is **JSON with fields** rather than a sentence: a request ID, a user ID, a duration, an outcome. That is what makes logs queryable, and it is the difference between grepping and asking "which requests over 500 ms failed on this route". A correlation ID carried in a `contextvar` and injected by a filter is what ties the lines of one request together.

  </details>

- **MUST** — What must never be logged

  <details><summary><strong>Answer</strong></summary>

  Passwords, tokens, API keys, full card numbers, health data and personal data beyond what is needed. The common accidents are logging a whole request body, logging an exception whose message contains the credential, and logging a configuration object at start-up that includes secrets.

  The defences are a redacting filter for known field names, logging identifiers rather than payloads, and a `__repr__` on any secret-carrying object that does not print the value. Retention matters too, since a log holding personal data is a data store subject to the same obligations as any other.

  </details>

- **NICE** — `logger.exception` and tracebacks

  <details><summary><strong>Answer</strong></summary>

  Inside an `except` block, `logger.exception("could not send")` logs at error level with the traceback attached; `logger.error(..., exc_info=True)` is the explicit form, and plain `logger.error` records only the message and throws away the cause.

  Logging the traceback and then re-raising duplicates it, so the convention is to log where it is handled and to add context and re-raise everywhere else.

  </details>

- **NICE** — Configuration and performance

  <details><summary><strong>Answer</strong></summary>

  `dictConfig` at start-up is the maintainable form, and it is what lets configuration come from a file. Logging is synchronous, so a slow handler blocks the caller — which is why a network handler belongs behind `QueueHandler` and `QueueListener` rather than on the request path.

  Sampling high-volume lines and keeping debug logging off by default are what stop logging from becoming the bottleneck it is meant to diagnose.

  </details>

- **OPTIONAL** — The ecosystem

  <details><summary><strong>Answer</strong></summary>

  `structlog` makes structured logging the default rather than something bolted onto a formatter, and `loguru` trades configurability for a much simpler API. Both ultimately sit on the standard library, so the concepts transfer.

  </details>

## 13. datetime and Time Zones

**Why it comes up:** naive and aware datetimes are a two-minute question that catches a real, expensive class of bug, and everyone has been bitten by it.

- **MUST** — Naive against aware

  <details><summary><strong>Answer</strong></summary>

  An **aware** datetime carries a `tzinfo`; a **naive** one does not and therefore means nothing on its own. Comparing or subtracting one of each raises `TypeError`, which is the language refusing to guess — and is a feature, because the guess would be wrong somewhere.

  The discipline is to be aware everywhere: parse to aware at the boundary, store in [UTC](https://en.wikipedia.org/wiki/Coordinated_Universal_Time "Coordinated Universal Time — The time standard that instants are stored and compared against"), and convert to a local zone only for display. A naive datetime in a database column is an accident waiting for the first user in another country.

  </details>

- **MUST** — `utcnow` is the trap

  <details><summary><strong>Answer</strong></summary>

  `datetime.utcnow()` returns the current UTC time as a **naive** object, so it looks right and compares wrongly against anything aware — and against local naive times it is silently off by the offset. It is deprecated from 3.12 for exactly this reason.

  `datetime.now(timezone.utc)` is the correct call, and `datetime.now(UTC)` from 3.11. Spotting this in a code review is a small thing that prevents a whole family of off-by-hours bugs.

  </details>

- **MUST** — Storing and transmitting

  <details><summary><strong>Answer</strong></summary>

  Store instants in UTC, in a column that is timestamptz or an integer epoch, and convert at the edges. Transmit in [ISO](https://en.wikipedia.org/wiki/International_Organization_for_Standardization "International Organization for Standardization — Publishes international standards, including information security management") 8601 with an offset — `fromisoformat` and `isoformat` round-trip it, and from 3.11 `fromisoformat` handles the full format including a trailing `Z`.

  The exception worth naming is a **future local time**, such as a recurring appointment: storing that as UTC is wrong, because a government can change the offset between now and then. The correct storage is the local time plus the zone name.

  </details>

- **MUST** — Zones, offsets and `zoneinfo`

  <details><summary><strong>Answer</strong></summary>

  A fixed offset is not a time zone: `+01:00` says nothing about what happens in summer. `zoneinfo.ZoneInfo("Europe/Berlin")` from 3.9 reads the [IANA](https://www.iana.org/ "Internet Assigned Numbers Authority — Maintains global registries including the time zone database") database and knows the transitions, which is what makes arithmetic across a daylight-saving boundary correct. It replaced `pytz`, whose `localize` idiom existed to work around an older model and is no longer needed.

  The two edges to name: a local time that does not exist because the clock jumped forward, and one that occurs twice because it jumped back — the second needs `fold` to say which. On Windows the database is not present and `tzdata` must be installed.

  </details>

- **NICE** — Durations and monotonic time

  <details><summary><strong>Answer</strong></summary>

  `timedelta` arithmetic is exact for absolute durations and does not know about calendars, so "one month later" is not expressible and needs `dateutil.relativedelta` or explicit logic.

  For measuring elapsed time, use `time.monotonic` rather than a wall clock: the wall clock can jump backwards when [NTP](https://en.wikipedia.org/wiki/Network_Time_Protocol "Network Time Protocol — Synchronizes machine clocks over a network") corrects it, which produces negative durations and, in a retry loop, a very long wait.

  </details>

- **NICE** — Parsing and formatting

  <details><summary><strong>Answer</strong></summary>

  `strptime` needs an exact format and is the right tool when the format is known; guessing formats with `dateutil.parser` on untrusted input silently misreads ambiguous dates such as `03/04/2025`. Prefer ISO 8601 everywhere it is your choice, and be explicit about the format where it is not.

  </details>

- **OPTIONAL** — Testing time

  <details><summary><strong>Answer</strong></summary>

  Code that calls `datetime.now()` directly is hard to test; injecting a clock function or freezing time with `freezegun` makes the behaviour at a boundary — a month end, a daylight-saving transition, a leap day — testable rather than hoped for.

  </details>

## 14. The Import System

**Why it comes up:** circular imports and "it works in my editor but not from the command line" are everyday problems whose cause is the import machinery.

- **MUST** — How a name is found

  <details><summary><strong>Answer</strong></summary>

  `import x` searches `sys.modules` first — an already-imported module is never re-executed — then the finders on `sys.meta_path`, which walk `sys.path`. `sys.path` starts with the directory of the script being run, or the current directory for the interactive interpreter, then `PYTHONPATH`, then the installed packages.

  That first entry is the cause of most confusion: running `python script.py` from inside a package directory puts that directory on the path, so imports resolve differently than they will when the code is installed. `python -m package.module` uses the current directory instead, which is why it behaves differently and is usually the right invocation.

  </details>

- **MUST** — Packages and `__init__.py`

  <details><summary><strong>Answer</strong></summary>

  A directory with `__init__.py` is a **regular package**, and the file runs on first import — which makes it the place to define the public API, and a bad place for anything expensive. Since 3.3 a directory without one is a namespace package, which can be split across several path entries and is mostly useful for plugin systems.

  The practical advice is to keep the file thin and explicit: re-export the names that make up the package's interface, and avoid importing submodules that pull in heavy dependencies, since every consumer pays for them.

  </details>

- **MUST** — Circular imports

  <details><summary><strong>Answer</strong></summary>

  Module A imports B, which imports A; the second import finds a partially initialised module in `sys.modules` and fails with `ImportError: cannot import name`, or — worse — gets a module missing the attributes defined after the import line.

  The real fix is structural: the cycle means two modules are entangled, and the shared part usually wants to be a third module. The tactical fixes are importing inside the function that needs it, importing the module rather than the name, and `if TYPE_CHECKING:` when the cycle exists only for annotations.

  </details>

- **MUST** — Absolute and relative imports

  <details><summary><strong>Answer</strong></summary>

  Absolute imports — `from myapp.db import session` — are the default and the recommendation, because they mean the same thing wherever the module is imported from. Explicit relative imports — `from .db import session` — are shorter within a package and break when a module is run as a script, because a script has no package context.

  Implicit relative imports were removed in Python 3, which is why old code that worked in 2 fails with a `ModuleNotFoundError` that looks mysterious.

  </details>

- **NICE** — Import side effects and start-up cost

  <details><summary><strong>Answer</strong></summary>

  Everything at module level runs on import: a database connection opened there is opened by every tool that imports the module, including a test collector. A slow command-line tool is almost always doing import-time work, and `python -X importtime` prints the cost per module.

  Deferring a heavy import into the function that needs it is the standard fix, and it is also how an optional dependency stays optional.

  </details>

- **NICE** — `__main__` and the guard

  <details><summary><strong>Answer</strong></summary>

  A module run directly has `__name__ == "__main__"`, so `if __name__ == "__main__":` separates script behaviour from import behaviour. It is required rather than stylistic for anything using `multiprocessing` with the spawn start method, where the child re-imports the module.

  </details>

- **OPTIONAL** — Reloading and the plugin path

  <details><summary><strong>Answer</strong></summary>

  `importlib.reload` re-executes a module but leaves existing references pointing at the old objects, which is why it is unreliable outside a [REPL](https://docs.python.org/3/tutorial/interpreter.html "Read Eval Print Loop — Interactive prompt that evaluates expressions and prints results one at a time"). For plugins, `importlib.import_module` with a name from configuration, or entry points declared in package metadata, are the supported mechanisms.

  </details>

## 15. json and pickle

**Why it comes up:** the boundary between them is a security boundary, and stating it unprompted is the point of the question.

- **MUST** — What each is for

  <details><summary><strong>Answer</strong></summary>

  **JSON** is a text interchange format understood by everything, limited to objects, arrays, strings, numbers, booleans and null. **Pickle** is a Python-specific binary format that serialises almost any object graph, including custom classes, by recording how to reconstruct it.

  So the rule is: JSON for anything that crosses a process, a language or a network boundary, and pickle only inside one application's own trust boundary — a `multiprocessing` argument, a local cache written and read by the same code.

  </details>

- **MUST** — Why pickle is unsafe

  <details><summary><strong>Answer</strong></summary>

  Unpickling **executes code**: the format contains opcodes that import modules and call callables, so a crafted payload runs arbitrary commands the moment it is loaded. There is no safe subset and no sanitising step — `loads` on untrusted bytes is a remote code execution vulnerability, not a risk to be mitigated.

  That covers a cache an attacker could write to, a queue message from another service, a session cookie and an uploaded file. If the data crosses a trust boundary, the answer is JSON with a schema, or a signed and verified envelope around the bytes — and even signing only proves origin, it does not make the format safe.

  </details>

- **MUST** — What JSON cannot represent

  <details><summary><strong>Answer</strong></summary>

  No `datetime`, no `Decimal`, no `UUID`, no set, no bytes, no tuple distinct from a list, and integer keys become strings — `json.loads(json.dumps({1: "a"}))` returns `{"1": "a"}`, which is a silent change of type. Floats also mean the decimal value is not preserved exactly, which matters for money.

  The answer is a `default` function for encoding, a schema or a model on decoding, and ISO 8601 strings for times. Naming the integer-key surprise is a good sign, because it is the one that gets discovered in production.

  </details>

- **MUST** — Performance and the alternatives

  <details><summary><strong>Answer</strong></summary>

  The standard library's `json` is pure Python with a C accelerator and is adequate; `orjson` is several times faster and handles `datetime` and `UUID` directly, which is why it is the common choice in a service that serialises large responses.

  Where the payload is large or the schema is fixed, a binary format — MessagePack, Protocol Buffers, Avro — is smaller and faster, at the cost of not being readable in a log or a browser. Parsing a large JSON document also holds the whole thing in memory, so streaming formats such as line-delimited JSON exist for that case.

  </details>

- **NICE** — Other unsafe deserialisers

  <details><summary><strong>Answer</strong></summary>

  `yaml.load` without a loader argument constructs arbitrary Python objects and has the same class of vulnerability; `yaml.safe_load` is the correct call. `eval` and `exec` on input are the same mistake stated directly, and `ast.literal_eval` is the safe way to parse a Python literal.

  Anything that reconstructs objects from a description should be assumed dangerous until its documentation says otherwise.

  </details>

- **NICE** — Versioning a serialised format

  <details><summary><strong>Answer</strong></summary>

  Pickle ties both ends to compatible class definitions, so a cached object written by one release may not load after a refactor — which makes it a poor choice for anything persistent. JSON with an explicit version field, and a reader that tolerates unknown fields, is what survives a deployment where old and new code run together.

  </details>

- **OPTIONAL** — Custom encoding hooks

  <details><summary><strong>Answer</strong></summary>

  `json.dumps(obj, default=fn)` handles unknown types on the way out, and `object_hook` rebuilds them on the way in. Both are per-call and easy to apply inconsistently, which is an argument for a model layer that owns the conversion in one place.

  </details>

## 16. subprocess

**Why it comes up:** `shell=True` on a string built from input is a textbook command injection, and the safe form is one line away.

- **MUST** — Argument lists against `shell=True`

  <details><summary><strong>Answer</strong></summary>

  `subprocess.run(["git", "clone", url])` passes the arguments directly to `execve` with no shell involved, so nothing in `url` can be interpreted as a command separator. `subprocess.run(f"git clone {url}", shell=True)` hands the whole string to a shell, where `; rm -rf /` in the [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") is a second command.

  Use the list form. `shell=True` is needed only for genuine shell features — a pipeline, a glob, variable expansion — and even then the input must never be interpolated; `shlex.quote` is the mitigation if there is no alternative, and restructuring to avoid the shell is better.

  </details>

- **MUST** — Timeouts and deadlock

  <details><summary><strong>Answer</strong></summary>

  Without `timeout=`, a child that hangs hangs the parent forever, and that is how a service stops responding for a reason nobody can see. `run(..., timeout=30)` raises `TimeoutExpired` and kills the child.

  The related trap is `Popen` with pipes: writing to stdin while the child fills its stdout buffer deadlocks, because neither side can proceed. `communicate()` handles both directions at once and is the reason to prefer it over reading and writing the pipes by hand.

  </details>

- **MUST** — Capturing output and checking the result

  <details><summary><strong>Answer</strong></summary>

  `run(cmd, capture_output=True, text=True, check=True)` is the everyday call: it captures both streams, decodes them, and raises `CalledProcessError` on a non-zero exit. Without `check=True` a failure is silent and the empty output is processed as if it were data.

  `text=True` decodes with the locale encoding, so pass `encoding="utf-8"` when the child's output is known to be [UTF-8](https://datatracker.ietf.org/doc/html/rfc3629 "Unicode Transformation Format 8-bit — Variable-width encoding that represents every Unicode code point as bytes"). Capturing gigabytes into memory is the other failure — redirect to a file for anything large.

  </details>

- **MUST** — Environment and working directory

  <details><summary><strong>Answer</strong></summary>

  The child inherits the parent's environment unless `env=` is given, and passing `env={"PATH": ...}` replaces it entirely rather than adding to it, which breaks the child in ways that are hard to diagnose — build it from `os.environ.copy()` instead.

  Relying on `PATH` to find an executable is itself a small risk, since it depends on the deployment; an absolute path, or resolving once with `shutil.which`, is more predictable. `cwd=` sets the working directory without a process-wide `chdir`, which matters because `chdir` affects every thread.

  </details>

- **NICE** — When not to shell out at all

  <details><summary><strong>Answer</strong></summary>

  A subprocess for something the standard library does — copying files, reading a directory, computing a hash, parsing JSON — costs a process, loses error detail and adds a platform dependency. `shutil`, `pathlib` and `hashlib` do those without any of it.

  The legitimate cases are a tool with no library equivalent, and an existing binary whose behaviour must be matched exactly.

  </details>

- **NICE** — Streaming a long-running child

  <details><summary><strong>Answer</strong></summary>

  For a process that produces output over minutes, `Popen` with `stdout=PIPE` and iteration over the stream gives progress, but the child's own buffering usually holds the output back — which is why `python -u` or `PYTHONUNBUFFERED=1` appears in so many container entry points.

  </details>

- **OPTIONAL** — Signals and orphaned children

  <details><summary><strong>Answer</strong></summary>

  A child does not die with its parent unless something arranges it, so a killed parent can leave the child running. `start_new_session` plus killing the process group, or a `try/finally` that calls `terminate` and then `kill`, is what makes the cleanup reliable.

  </details>

## 17. Dependency Management and Lock Files

**Why it comes up:** "it works on my machine" is a dependency-resolution story, and the lock file is the part that ends it.

- **MUST** — What a lock file is for

  <details><summary><strong>Answer</strong></summary>

  A declaration such as `requests>=2.28` describes a range; a **lock file** records the exact version of every package actually installed, including transitive ones, usually with a hash. That is what makes an install reproducible across machines, across time, and between a developer's laptop and the build that ships.

  Without one, a deploy three weeks later resolves differently because a transitive dependency published a release, and the difference between environments is invisible until it fails. `pip freeze` is the crude version and records whatever happens to be installed, including packages nothing depends on.

  </details>

- **MUST** — The tools and what distinguishes them

  <details><summary><strong>Answer</strong></summary>

  `pip` installs and resolves but has no native lock format. `pip-tools` compiles a `requirements.in` into a pinned `requirements.txt` and is the smallest step up. `Poetry` manages dependencies, the virtual environment and packaging together with its own lock file. **uv** does the same set much faster, being written in Rust, and can also manage Python versions.

  The honest summary is that `uv` is where new projects are going, `Poetry` is widely established, and `pip` with a compiled requirements file is the lowest-dependency option that still gives reproducibility.

  </details>

- **MUST** — Pinning against ranges, and who does which

  <details><summary><strong>Answer</strong></summary>

  An **application** pins exactly and commits the lock file, because it controls its own environment and wants reproducibility. A **library** declares ranges and does not commit a lock file, because pinning forces its constraints onto every consumer and makes co-installation impossible.

  Getting this backwards is a common and expensive mistake: a library with `requests==2.28.1` cannot be installed alongside anything else that pins a different patch version.

  </details>

- **MUST** — Keeping dependencies current

  <details><summary><strong>Answer</strong></summary>

  A pinned set that is never updated is a security liability, so the pin has to be paired with automated updates — Dependabot or Renovate raising pull requests that the test suite gates. Small, frequent updates are absorbed; a year of them at once is a project.

  `pip-audit` or `safety` against the lock file reports known vulnerabilities, and running that in CI is what turns an advisory into a build failure rather than a newsletter item.

  </details>

- **NICE** — Resolution and conflicts

  <details><summary><strong>Answer</strong></summary>

  A resolver must find one version of each package satisfying every constraint, and when two dependencies disagree the result is a conflict that no tool can resolve for you — the options are to relax a constraint, upgrade the laggard, or vendor. pip's backtracking resolver can spend a long time exploring before reporting this, which is a common cause of a slow install.

  </details>

- **NICE** — Optional and grouped dependencies

  <details><summary><strong>Answer</strong></summary>

  Test, lint and documentation tools do not belong in the runtime dependency list: `pyproject.toml` expresses them as optional extras or dependency groups, which keeps the production image small and the attack surface with it. Installing the development set in the production container is a common oversight.

  </details>

- **OPTIONAL** — Vendoring and private indexes

  <details><summary><strong>Answer</strong></summary>

  A private index or an internal mirror gives control over availability and over what can be installed; `--index-url` against a proxy such as Artifactory is the usual form. It also defends against dependency confusion, where a public package with an internal name is resolved in preference to the private one.

  </details>

## 18. Virtual Environments

**Why it comes up:** it is basic, and the interesting part is explaining what isolation actually does and where it stops.

- **MUST** — What a virtual environment is

  <details><summary><strong>Answer</strong></summary>

  A directory with its own `site-packages`, its own `bin` and a `pyvenv.cfg` pointing at a base interpreter. Activating it puts that `bin` first on `PATH`, so `python` and `pip` resolve inside it and packages install there rather than system-wide.

  It isolates **packages**, not the interpreter version: the environment uses whatever Python created it. Managing several interpreter versions is a separate job, done by `pyenv`, by `uv`, or by the distribution.

  </details>

- **MUST** — Why it is not optional

  <details><summary><strong>Answer</strong></summary>

  Without one, two projects needing different versions of the same library cannot both work, and installing into the system Python can break operating-system tooling that depends on it. That is why modern distributions mark their Python as externally managed and refuse a global `pip install` outright.

  The corollary for containers is that the isolation is already provided by the image, so a virtual environment inside a container is optional — though it is still useful for keeping build dependencies out of the final layer in a multi-stage build.

  </details>

- **MUST** — `venv` and the alternatives

  <details><summary><strong>Answer</strong></summary>

  `python -m venv .venv` is in the standard library and is enough for most projects. `virtualenv` is faster and supports older interpreters; `conda` manages non-Python dependencies too, which is why it persists in scientific work; `uv venv` is very fast and integrates with the same tool that resolves the dependencies.

  [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects") and uv both create and manage the environment implicitly, which removes the activation step and the class of mistakes that come with forgetting it.

  </details>

- **MUST** — The mistakes that actually happen

  <details><summary><strong>Answer</strong></summary>

  Installing without activating, so packages land in the system Python; an editor configured with a different interpreter than the terminal, so imports resolve in one and not the other; committing the environment directory; and moving or renaming a project directory, which breaks the absolute paths in the environment's scripts.

  `which python` and `python -c "import sys; print(sys.prefix)"` settle all of these in one command, and `python -m pip` rather than bare `pip` guarantees the two match.

  </details>

- **NICE** — Isolating tools from projects

  <details><summary><strong>Answer</strong></summary>

  Command-line tools such as a formatter or a linter do not belong in a project's environment when they are used across projects: `pipx` — or `uv tool` — installs each into its own environment and exposes the executable, which avoids the dependency conflicts that come from mixing tools with application code.

  </details>

- **NICE** — Reproducing an environment

  <details><summary><strong>Answer</strong></summary>

  An environment is reproduced from the lock file and not by copying the directory, which is not relocatable. `--require-hashes` makes the install fail if a package's contents do not match what was recorded, which is what turns the lock file into a supply-chain control rather than a convenience.

  </details>

- **OPTIONAL** — `PYTHONPATH` and editable installs

  <details><summary><strong>Answer</strong></summary>

  `pip install -e .` links the source directory into the environment so changes take effect without reinstalling, which is the normal setup for development. Manipulating `PYTHONPATH` to achieve the same thing works until something else on it shadows a module, and it is the source of the classic import that behaves differently under a test runner.

  </details>

## 19. Packaging

**Why it comes up:** knowing what a wheel is and why it is preferred explains both install speed and a whole class of deployment failure.

- **MUST** — `pyproject.toml` and build backends

  <details><summary><strong>Answer</strong></summary>

  `pyproject.toml` is the single declarative file for project metadata, dependencies and tool configuration; `setup.py` was an executable script whose side effects made packaging unpredictable, and it is legacy. The `[build-system]` table names the **build backend** — setuptools, hatchling, flit or poetry-core — and the frontend installs that backend in an isolated environment to do the build.

  The separation of frontend and backend is what lets `pip` build any project without knowing which backend it uses, and it is why the file is the answer to most "how do I configure this" questions.

  </details>

- **MUST** — Wheels against source distributions

  <details><summary><strong>Answer</strong></summary>

  A **wheel** is a built artefact: a zip with the files laid out ready to copy into `site-packages`, so installing runs no code and needs no compiler. An **sdist** is the source, and installing it runs the build — which requires a toolchain, takes time, and is where "no matching distribution" and compiler errors come from.

  A wheel is platform-specific when it contains compiled code, which is why a package publishes many: one per Python version, operating system and architecture, following the `manylinux` standard for Linux. A pure-Python package publishes one `py3-none-any` wheel that works everywhere.

  </details>

- **MUST** — Versioning and what it promises

  <details><summary><strong>Answer</strong></summary>

  Semantic versioning is a promise about compatibility — a major bump means a break — and the value of dependency ranges rests entirely on publishers keeping it. Python's own version specification defines how `~=` and `>=` compare, including pre-release and post-release forms.

  Deriving the version from a git tag rather than maintaining it in two places removes the commonest release mistake, which is shipping a package whose metadata says the previous version.

  </details>

- **MUST** — Publishing and its supply-chain surface

  <details><summary><strong>Answer</strong></summary>

  `python -m build` produces the sdist and wheel, and `twine upload` publishes them; `cibuildwheel` builds the matrix of binary wheels in CI. Test against TestPyPI before the real index, because a version number on [PyPI](https://pypi.org/ "Python Package Index — Public repository from which Python packages are installed") cannot be reused once published.

  Trusted publishing with [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") from the CI provider removes the long-lived API token that is otherwise the weakest link, and it is the current recommendation. Name-squatting and typosquatting are the other side of the same surface, which is why an organisation reserves its names.

  </details>

- **NICE** — What goes in the package

  <details><summary><strong>Answer</strong></summary>

  Only the runtime code: tests, fixtures, notebooks and CI configuration inflate the artefact and occasionally leak something. `MANIFEST.in` or the backend's include rules control the sdist; a `py.typed` marker is required for consumers' type checkers to see the annotations at all.

  </details>

- **NICE** — Entry points

  <details><summary><strong>Answer</strong></summary>

  `[project.scripts]` generates a console command that calls a function, which is how a package provides a command-line tool without shipping a shell script. The plugin form of the same mechanism lets an application discover installed extensions by group name, which is how pytest and many frameworks find theirs.

  </details>

- **OPTIONAL** — Not packaging at all

  <details><summary><strong>Answer</strong></summary>

  A deployed service usually does not need to be a distributable package: a container image with the code and a locked environment is the artefact. Packaging matters for libraries, for shared internal code and for command-line tools, and treating an application as a library is work with no return.

  </details>

## 20. pathlib against os.path

**Why it comes up:** it is a small question about whether the candidate has kept up, and the cross-platform points are worth having ready.

- **MUST** — What `pathlib` gives you

  <details><summary><strong>Answer</strong></summary>

  A `Path` is an object rather than a string, so operations are methods and composition is the `/` operator: `Path("data") / "raw" / name`. It replaces a scattered set of `os.path` functions with one type carrying `name`, `stem`, `suffix`, `parent`, `exists`, `read_text`, `write_text`, `iterdir`, `glob` and `mkdir(parents=True, exist_ok=True)`.

  It is the recommended modern API, and everything in the standard library that takes a filename accepts it, because it implements `os.PathLike`.

  </details>

- **MUST** — Joining, and why string concatenation is wrong

  <details><summary><strong>Answer</strong></summary>

  `base + "/" + name` bakes in a separator and breaks on Windows; it also mishandles a `base` that already ends in one. `os.path.join` and the `/` operator both handle those.

  The security version of the same point is that a user-supplied name containing `..` escapes the directory you meant — path traversal. Joining and then calling `resolve()` and checking the result is still under the intended parent is the guard, and it must be done after resolution, since a check on the raw string is defeated by symlinks.

  </details>

- **MUST** — Cross-platform behaviour

  <details><summary><strong>Answer</strong></summary>

  Separators differ, case sensitivity differs, Windows has reserved names and a path-length limit, and a trailing dot or space is silently stripped there. `pathlib` handles the separator and the parsing; it does not make case sensitivity uniform, so code that relies on two names differing only in case works on Linux and breaks elsewhere.

  `Path.home()`, `tempfile.gettempdir()` and `os.environ` are the portable ways to find locations, rather than hard-coded `/tmp` or `~`.

  </details>

- **MUST** — Temporary files done properly

  <details><summary><strong>Answer</strong></summary>

  `tempfile.NamedTemporaryFile` and `TemporaryDirectory` create files with safe permissions in the right place and clean up on exit; constructing a name in `/tmp` yourself is a race and a symlink attack, because an attacker can create the name first.

  `TemporaryDirectory` as a context manager is the one to reach for whenever a test or a job needs scratch space, since it removes the tree even when the block raises.

  </details>

- **NICE** — When `os` is still the answer

  <details><summary><strong>Answer</strong></summary>

  `os.walk` for a large recursive traversal, `os.scandir` where the per-entry `stat` matters for performance, `os.replace` for an atomic rename, and the low-level `os.open` flags for exclusive creation. `pathlib` covers the common cases and does not replace the whole module.

  Writing a file atomically — write to a temporary file in the same directory, then `os.replace` — is the pattern worth knowing, because a partial write of a configuration or data file is otherwise indistinguishable from a valid one.

  </details>

- **NICE** — Performance

  <details><summary><strong>Answer</strong></summary>

  Each `Path` is an object and each method call has overhead, so a loop over a million paths is measurably slower than string operations. That matters in a file-system crawler and nowhere else, and 3.13 made the implementation substantially faster.

  </details>

- **OPTIONAL** — Pure paths

  <details><summary><strong>Answer</strong></summary>

  `PurePath`, `PurePosixPath` and `PureWindowsPath` manipulate paths without touching the file system, which is what you want when handling a path for another platform — a key in object storage, or a path inside an archive.

  </details>
