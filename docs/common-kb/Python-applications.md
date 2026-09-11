# Fundamental Topics: Python Testing, Web Applications and Security

**Table of Contents**

[Testing and Quality Topics](#testing-and-quality-topics)

- [1. pytest](#1-pytest)
- [2. Mocking](#2-mocking)
- [3. Test Doubles and Integration Boundaries](#3-test-doubles-and-integration-boundaries)
- [4. Coverage](#4-coverage)
- [5. Linting and Formatting](#5-linting-and-formatting)
- [6. Type Checking as a CI Gate](#6-type-checking-as-a-ci-gate)
- [7. Property-Based Testing](#7-property-based-testing)

[Web and Application Topics](#web-and-application-topics)

- [8. ORM Behaviour](#8-orm-behaviour)
- [9. WSGI and ASGI](#9-wsgi-and-asgi)
- [10. Sync and Async Frameworks](#10-sync-and-async-frameworks)
- [11. The Request Lifecycle](#11-the-request-lifecycle)
- [12. Worker Models and Deployment](#12-worker-models-and-deployment)
- [13. Background Work](#13-background-work)
- [14. Configuration and Secrets](#14-configuration-and-secrets)

[Security Topics](#security-topics)

- [15. SQL Injection and Parameterised Queries](#15-sql-injection-and-parameterised-queries)
- [16. Input Validation and Unsafe Deserialisation](#16-input-validation-and-unsafe-deserialisation)
- [17. Secrets Handling](#17-secrets-handling)
- [18. The Dependency Supply Chain](#18-the-dependency-supply-chain)
- [19. Randomness](#19-randomness)
**What this is.** The testing, web-application and security topics a backend engineer is expected to reason about rather than recite, taken from three groups of the list in `docs/tmp/common-kb/Python.txt`. That list is long enough to be five documents; the others are `Python-language.md`, `Python-data-structures.md`, `Python-concurrency.md` and `Python-typing-stdlib.md`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. pytest is the reference test framework and [FastAPI](https://fastapi.tiangolo.com/ "FastAPI — Python web framework for building HTTP APIs with async support and automatic schema generation"), Django and Flask the reference web frameworks, because those four are what an interviewer will compare against — and where a point holds for any framework, it is stated that way rather than tied to one.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1, 8 and 15 are the ones you are most likely to be asked. The grouping follows `Python.txt`: how the code is tested, how it is served, and the ways it is attacked.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 76 MUST, 38 NICE and 19 OPTIONAL across 19 topics. The security group is MUST-heavy in a way the others are not, because there is no partial credit on injection, deserialisation or token generation — a vague answer there reads as a risk rather than as a gap.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Testing and Quality Topics

## 1. pytest

**Why it comes up:** fixtures and parametrisation are what a test suite is made of, and scope is where a slow or flaky suite is usually explained.

- **MUST** — What fixtures are and why they beat setup methods

  <details><summary><strong>Answer</strong></summary>

  A **fixture** is a function that produces something a test needs, requested by naming it as a parameter. Dependency injection rather than inheritance: a test declares what it wants, and pytest builds the graph, so two tests needing different setups do not share a base class that provides both.

  A fixture that `yield`s runs its teardown after the test, and the teardown runs even when the test fails. That is the mechanism that stops a suite leaving a database row, a file or a patched global behind.

  </details>

- **MUST** — Scope, and what it costs to get wrong

  <details><summary><strong>Answer</strong></summary>

  A fixture is `function`-scoped by default and can be `class`, `module`, `package` or `session` scoped. Widening the scope is how an expensive resource — a container, a database schema, a loaded model — is created once instead of per test.

  The cost is **shared mutable state**: a session-scoped fixture that a test modifies leaks into every later test, which produces the failure that only appears when the suite runs in a particular order. The rule that keeps both is to share the expensive *creation* and reset the *state* per test — one schema per session, one transaction rolled back per test.

  </details>

- **MUST** — `conftest.py`

  <details><summary><strong>Answer</strong></summary>

  Fixtures defined in `conftest.py` are available to every test in that directory and below, with no import. It is also where plugins, hooks and command-line options are registered, and nested files let a subdirectory add or override what the parent provides.

  The discipline is that it is implicit: a fixture appearing from nowhere is hard to trace, so a large `conftest.py` at the root becomes a place where surprising global behaviour accumulates. Keep it small, and keep fixtures near the tests that use them.

  </details>

- **MUST** — `parametrize`

  <details><summary><strong>Answer</strong></summary>

  `@pytest.mark.parametrize("value,expected", [...])` runs the test once per case, each reported separately, so a failure names the case rather than the loop. That is the difference from a `for` loop inside a test, which stops at the first failure and hides the rest.

  `ids=` gives each case a readable name, `pytest.param(..., marks=pytest.mark.xfail)` marks one case as expected to fail, and parametrising a fixture instead of a test runs the whole dependent suite against each variant — which is how the same tests run against two backends.

  </details>

- **NICE** — Markers, selection and a fast feedback loop

  <details><summary><strong>Answer</strong></summary>

  Markers label tests — `@pytest.mark.slow`, `integration` — so `-m "not slow"` gives a fast local run and [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change") runs everything. `-k` selects by name, `-x` stops at the first failure, `--lf` reruns only what failed last time, and `-n auto` with `pytest-xdist` distributes across cores.

  A suite that takes twenty minutes is a suite that stops being run before pushing, so the split between a fast subset and a full CI run is a design decision rather than a convenience.

  </details>

- **NICE** — Assertions, exceptions and useful failures

  <details><summary><strong>Answer</strong></summary>

  pytest rewrites the `assert` statement so a plain comparison prints both sides and the difference, which is why no assertion [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data") is needed. `pytest.raises(ValueError, match="...")` asserts the exception *and* its message, and asserting the type alone lets an unrelated error of the same class pass for the one you meant.

  `pytest.approx` handles floating-point comparison, which is the alternative to an equality that fails for reasons unrelated to the code under test.

  </details>

- **OPTIONAL** — Fixtures that are really global state

  <details><summary><strong>Answer</strong></summary>

  `monkeypatch` undoes its changes at the end of the test, `tmp_path` gives a unique directory, and `caplog` captures log records. Reaching around them to set a module global or an environment variable directly is what leaves the state behind and makes the next test's failure inexplicable.

  </details>

## 2. Mocking

**Why it comes up:** patching the wrong target is the most common reason a mock silently does nothing, and over-mocking is the most common reason a suite passes while the system is broken.

- **MUST** — Patch where it is used, not where it is defined

  <details><summary><strong>Answer</strong></summary>

  `from x import fn` binds the function into the importing module's namespace, so patching `x.fn` afterwards leaves that binding untouched and the real function still runs. The patch target must be `myapp.service.fn` — the name **in the module under test**.

  That is the single most common mocking mistake, and its symptom is a test that passes while asserting nothing, or one that unexpectedly makes a real network call. Importing the module and calling `x.fn()` rather than importing the name avoids the problem entirely.

  </details>

- **MUST** — `autospec` and why a bare `Mock` is dangerous

  <details><summary><strong>Answer</strong></summary>

  A `Mock` answers any attribute and any call with another `Mock`, so a test keeps passing after the real function's signature changes, after a method is renamed, and after the call is made with the wrong arguments. The test is no longer connected to the code it claims to cover.

  `create_autospec` or `patch(..., autospec=True)` builds the double from the real object, so an unknown attribute raises `AttributeError` and a wrong-arity call raises `TypeError`. Using it by default is the difference between a mock that verifies an interface and one that merely absorbs calls.

  </details>

- **MUST** — Asserting on interactions, carefully

  <details><summary><strong>Answer</strong></summary>

  `assert_called_once_with(...)` checks that the collaborator was used as expected, and `call_args_list` inspects multiple calls. The names matter: `assert_called_once` and `assert_called_with` differ in what they check, and `mock.assert_not_called` typed slightly wrong — `assert_no_calls`, say — is a no-op attribute access that always passes.

  That is why `autospec` matters again: a specced mock raises on an unknown `assert_*` name. And asserting on every interaction produces a test that fails whenever the implementation is refactored, which is the cost of testing the how rather than the what.

  </details>

- **MUST** — Patching a method against injecting a dependency

  <details><summary><strong>Answer</strong></summary>

  Patching reaches into a module to replace something the code did not offer to have replaced, so the test is coupled to the implementation's import structure. Passing the collaborator in — as a constructor argument or a parameter — needs no patching at all and makes the seam explicit.

  A codebase that needs heavy patching is usually telling you its dependencies are hard-wired. Naming that, rather than only knowing the patching API, is the answer that shows design judgment.

  </details>

- **NICE** — Async mocks and context managers

  <details><summary><strong>Answer</strong></summary>

  `AsyncMock` returns awaitables and is what `patch` produces automatically when the target is an async function. A mocked context manager needs `__enter__` configured — `mock.return_value.__enter__.return_value = thing` — which is the incantation behind most "the mock returned a Mock" confusion.

  `MagicMock` supports the dunder protocols that plain `Mock` does not, which is why it is the default for `patch`.

  </details>

- **NICE** — Faking time, randomness and identifiers

  <details><summary><strong>Answer</strong></summary>

  A test asserting on `datetime.now()`, `uuid4()` or `random` is non-deterministic unless the source is controlled. Injecting a clock or an ID factory is cleaner than patching, and `freezegun` is the pragmatic option for existing code.

  Non-determinism from these three is the most common cause of a test that fails once a week and is dismissed as flaky.

  </details>

- **OPTIONAL** — Mocking what you do not own

  <details><summary><strong>Answer</strong></summary>

  Mocking a third-party client's internals binds the test to that library's implementation, which then breaks on upgrade. The usual advice is to wrap the library in a thin adapter of your own, mock the adapter, and test the adapter against the real thing or a recorded response.

  </details>

## 3. Test Doubles and Integration Boundaries

**Why it comes up:** deciding what to fake and what to run for real is the design question behind a test suite, and the answer reveals what the candidate believes tests are for.

- **MUST** — The kinds of double

  <details><summary><strong>Answer</strong></summary>

  A **stub** returns canned values. A **fake** is a working but simplified implementation — an in-memory repository, a temporary SQLite database. A **mock** records interactions and asserts on them. A **spy** wraps the real thing and observes it.

  The distinction that matters in practice is between a double that lets you check the **result** and one that lets you check the **interaction**. Preferring the first gives tests that survive refactoring; leaning on the second gives tests that describe the current implementation.

  </details>

- **MUST** — Where the boundary belongs

  <details><summary><strong>Answer</strong></summary>

  Fake what is slow, non-deterministic, costly or outside your control — third-party APIs, email, payment providers, clocks. Use the real thing for what you own and what the correctness depends on, above all the database, because a mocked database tests your assumptions about [SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") rather than the SQL.

  The most common failure here is a suite that mocks the [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") and therefore never executes a query, then fails in production on a constraint, a migration or a query that the mock happily pretended to run.

  </details>

- **MUST** — The pyramid, and what it is really saying

  <details><summary><strong>Answer</strong></summary>

  Many fast unit tests, fewer integration tests, very few end-to-end tests. The reason is feedback economics rather than doctrine: a unit test localises the failure and runs in milliseconds, while an end-to-end test tells you something is wrong somewhere and takes minutes.

  The honest qualification is that an over-unit-tested system with no integration coverage passes its suite and fails on wiring, which is why the modern emphasis has shifted towards a thicker middle layer — tests that exercise a real database and a real [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") layer through the application's own entry points.

  </details>

- **MUST** — Testing against real infrastructure

  <details><summary><strong>Answer</strong></summary>

  A container per dependency — `testcontainers` or a compose file — gives the real engine with real SQL, real constraints and real transaction behaviour, at a start-up cost amortised over a session-scoped fixture. Substituting SQLite for [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") is the cheap version and hides exactly the dialect differences that cause production failures.

  Isolation between tests then comes from wrapping each in a transaction and rolling back, or from truncating between tests. That is what makes a shared, expensive resource safe to reuse.

  </details>

- **NICE** — Contract tests for a service you call

  <details><summary><strong>Answer</strong></summary>

  A stub of another team's API encodes your belief about it, and nothing detects when that belief goes stale. A contract test — or a recorded interaction replayed by `vcrpy` or `responses`, refreshed periodically — checks the belief against the real response shape.

  The failure this prevents is a suite that is green for weeks after the upstream response changed.

  </details>

- **NICE** — Test data

  <details><summary><strong>Answer</strong></summary>

  Factories such as `factory_boy` build objects with sensible defaults and let a test override only the field it cares about, which keeps the intent visible. Large shared fixture files do the opposite: every test depends on data whose meaning nobody remembers, and changing one row breaks tests across the suite.

  </details>

- **OPTIONAL** — Testing in production

  <details><summary><strong>Answer</strong></summary>

  Feature flags, canary releases and synthetic monitoring cover what no suite can: real traffic, real data volume, real dependencies. They are a complement rather than a replacement, and naming them shows the limits of testing are understood.

  </details>

## 4. Coverage

**Why it comes up:** the number is easy to game and easy to misread, so the question is really about what you believe it tells you.

- **MUST** — What it measures

  <details><summary><strong>Answer</strong></summary>

  Line coverage records which lines executed during the run; branch coverage records which way each conditional went, which is strictly more informative and is what `--cov-branch` enables. That is all it measures: **execution, not verification**.

  A test that calls every function and asserts nothing reports full coverage. So coverage answers "what did the tests not touch at all", which is a genuinely useful question, and says nothing about whether what they touched is correct.

  </details>

- **MUST** — Reading it as a floor, not a target

  <details><summary><strong>Answer</strong></summary>

  The useful reading is the uncovered report: which modules, branches and error paths were never executed. Error handling and edge cases are what usually appear there, and they are exactly the code least likely to be exercised in production before an incident.

  Setting a percentage target inverts the tool. At a high threshold people write tests for trivial code and add `# pragma: no cover` to the hard parts, and the number goes up while the suite gets weaker. A ratchet that forbids a decrease is the version that does not produce that behaviour.

  </details>

- **MUST** — What 100% does not prove

  <details><summary><strong>Answer</strong></summary>

  It does not prove the assertions are meaningful, that the combinations of branches were tried, that the boundaries were checked, that concurrency is handled, or that the code does what the requirement said. A correct implementation of the wrong behaviour has the same coverage as the right one.

  Saying this plainly is the answer. The follow-up worth offering is **mutation testing** — `mutmut` or `cosmic-ray` change the code and check that a test fails — which measures whether the assertions detect anything, and is the honest version of what people hope coverage means.

  </details>

- **MUST** — Where it is genuinely valuable

  <details><summary><strong>Answer</strong></summary>

  On a pull request, as the **diff coverage**: whether the lines this change added are tested. That is actionable, local and not gameable in the way a global percentage is, and it lets a legacy codebase improve without a project to retrofit tests.

  It is also how dead code is found — a module at zero coverage across a full suite and a period of production tracing is a strong candidate for deletion.

  </details>

- **NICE** — Configuring it honestly

  <details><summary><strong>Answer</strong></summary>

  Omit what should not be measured — migrations, generated code, the test suite itself — in configuration rather than by scattering pragmas. Measuring subprocess and multi-worker runs needs `parallel = true` and `coverage combine`, and forgetting that is why an integration suite reports far lower coverage than it achieves.

  </details>

- **NICE** — Coverage of the tests themselves

  <details><summary><strong>Answer</strong></summary>

  A test that never runs — misnamed so the collector skips it, or permanently skipped by a marker — contributes nothing and looks like it does. `--strict-markers` and reporting the skip count catch the common cases, and a suite where the skip list only grows is worth an audit.

  </details>

- **OPTIONAL** — Runtime cost

  <details><summary><strong>Answer</strong></summary>

  Tracing adds noticeable overhead, and 3.12's `sys.monitoring` support made `coverage.py` substantially faster. If it is slowing the feedback loop, measure it on CI and not locally rather than turning it off.

  </details>

## 5. Linting and Formatting

**Why it comes up:** it is a question about how a team spends its review attention, and the specific tools say whether the candidate has configured a pipeline recently.

- **MUST** — What each tool is for

  <details><summary><strong>Answer</strong></summary>

  A **formatter** rewrites layout deterministically and has no opinion about correctness: `black` made this the norm and `ruff format` reimplements it far faster. A **linter** finds likely defects and questionable constructs — an unused import, a mutable default, a bare `except`, an undefined name. `ruff` now covers what `flake8` and most of its plugins did, and `pylint` remains deeper and slower.

  The split matters because they fail differently: a formatter's disagreement is never worth discussing, and a linter's sometimes is.

  </details>

- **MUST** — Why a formatter ends an argument rather than winning it

  <details><summary><strong>Answer</strong></summary>

  With one deterministic formatter there is nothing to discuss in review, diffs contain only real changes, and nobody spends attention on line breaks. The value is the removal of a category of discussion, not the specific style chosen — which is why arguing about the style defeats the purpose.

  The one-off cost is a large reformatting commit that pollutes `git blame`; `.git-blame-ignore-revs` is what removes it from the default view.

  </details>

- **MUST** — Its role in CI

  <details><summary><strong>Answer</strong></summary>

  Run in check mode as a blocking gate — `ruff format --check` and `ruff check` — so a pull request cannot merge unformatted. Run the same commands in a pre-commit hook so the failure arrives in seconds locally rather than minutes later in CI.

  The rule that keeps it sane is that the hook and the gate run the **same command**, with the same configuration and the same pinned version, because a formatter version difference between the two produces a build that fails on code the developer's own tool just produced.

  </details>

- **MUST** — Which rules to enable

  <details><summary><strong>Answer</strong></summary>

  Start with the default set plus the ones that catch real defects — `bugbear` for likely bugs, `pyupgrade` for outdated syntax, `isort` for import order — and add more deliberately. Enabling every rule produces hundreds of findings, a wave of `noqa` comments, and a team that stops reading the output.

  A `noqa` should carry the specific code and, for anything non-obvious, a reason. Blanket ignores accumulate and are never revisited.

  </details>

- **NICE** — Security linting

  <details><summary><strong>Answer</strong></summary>

  `bandit`, or ruff's equivalent rules, flags `shell=True`, `yaml.load`, `assert` in production code, hard-coded passwords and weak hashes. It is noisy and worth tuning rather than dismissing, because the findings it gets right are the expensive kind.

  </details>

- **NICE** — What linting cannot do

  <details><summary><strong>Answer</strong></summary>

  It does not check behaviour, and a codebase with zero findings can be entirely wrong. Its value is removing the mechanical class of review comment so that review attention goes to design, naming and correctness — which is the argument to make when someone asks whether it is worth the setup.

  </details>

- **OPTIONAL** — Formatting inside a migration

  <details><summary><strong>Answer</strong></summary>

  Adopting a formatter mid-project is best done in one commit, on a quiet branch, with the ignore-revs file added in the same change. Doing it file by file produces months of diffs that mix formatting with logic, which is the thing the formatter was meant to prevent.

  </details>

## 6. Type Checking as a CI Gate

**Why it comes up:** a checker that runs only in an editor catches nothing for the team, and the interesting part is how it is introduced to an existing codebase.

- **MUST** — Why it has to block

  <details><summary><strong>Answer</strong></summary>

  A checker nobody runs is documentation. Making it a required status check means the annotations stay true, because a change that breaks them cannot merge — which is what separates a typed codebase from one with type-shaped comments.

  The corollary is that it must be fast and its failures must be real, or it will be marked non-blocking within a month. Caching and a per-module configuration are what keep that from happening.

  </details>

- **MUST** — Introducing it to an existing codebase

  <details><summary><strong>Answer</strong></summary>

  Turn it on non-strict across the repository, fix or ignore what it reports, and make that state the baseline the gate enforces. Then raise strictness per module as modules are touched, so the ratchet only moves one way and no one is asked to annotate a hundred thousand lines before the gate can exist.

  New modules start strict. That combination gives a codebase that improves with the work being done anyway, rather than a migration project that competes with features.

  </details>

- **MUST** — What it catches that tests do not

  <details><summary><strong>Answer</strong></summary>

  Every branch, including the error paths tests never reach — an unhandled `None`, a renamed attribute, a signature changed at one of forty call sites, a function that returns two different shapes. Those are found without writing a test and without executing the code.

  It is complementary rather than competing: the checker proves the types line up and the tests prove the behaviour is right. Neither substitutes for the other, and saying so is better than defending typing as a replacement for testing.

  </details>

- **MUST** — The gaps to be honest about

  <details><summary><strong>Answer</strong></summary>

  An untyped dependency makes everything it touches `Any`, a `cast` is a promise the checker believes without evidence, and data entering the program is unchecked by definition — which is where a validator belongs rather than a type hint.

  So a green type check says the code is internally consistent, not that it is correct and not that its inputs are safe. Stating that boundary unprompted is the mark of someone who has actually run one in anger.

  </details>

- **NICE** — Keeping it fast

  <details><summary><strong>Answer</strong></summary>

  Persist the cache between CI runs, check only what changed on a pull request while checking everything on the main branch, and pin the checker's version so an upgrade is a deliberate pull request rather than a surprise failure on an unrelated change.

  </details>

- **NICE** — Types in review

  <details><summary><strong>Answer</strong></summary>

  A signature is the part of a change worth reading first: it states the contract, and a reviewer who disagrees with it is disagreeing about design rather than about style. That is the quiet benefit of typing in a team — it moves review to the interface.

  </details>

- **OPTIONAL** — Reporting and ratchets

  <details><summary><strong>Answer</strong></summary>

  Counting `type: ignore` comments and untyped functions over time shows whether the codebase is converging or accumulating debt. A gate that forbids the count from rising is cheap and works better than a target nobody owns.

  </details>

## 7. Property-Based Testing

**Why it comes up:** it is not universally used, so knowing what it is for — and where it is not worth it — is a depth signal rather than a fundamental.

- **MUST** — What it is

  <details><summary><strong>Answer</strong></summary>

  Instead of asserting on chosen examples, you state a **property** that should hold for all inputs and let the library generate them. `hypothesis` explores the space, including the boundaries humans skip: empty, zero, negative, enormous, Unicode, and the values around every limit.

  The strength is that the examples come from the tool rather than from the same assumptions that produced the bug. It finds what you did not think to test, which is by construction the part a hand-written suite misses.

  </details>

- **MUST** — Shrinking

  <details><summary><strong>Answer</strong></summary>

  When a property fails, hypothesis reduces the input to the smallest example that still fails, so the report is a two-character string rather than the thousand-character one that happened to trigger it. That is what makes the failures actionable rather than merely alarming.

  It also records the failing example in a local database and replays it first on the next run, so a fix is verified against the exact case.

  </details>

- **MUST** — The properties worth asserting

  <details><summary><strong>Answer</strong></summary>

  Round trips are the most valuable and the easiest: `decode(encode(x)) == x` for any serialiser, parser or converter. Then invariants — the output is always sorted, the total is preserved, the result is never negative. Then equivalence against a slower obviously-correct implementation, and idempotence for anything applied twice.

  Finding the property is the hard part, and it is also the useful part: an operation whose property you cannot state is one whose contract is not clear.

  </details>

- **MUST** — Where it does not fit

  <details><summary><strong>Answer</strong></summary>

  Code whose correctness is a specific business rule rather than a general property — a tax band, a discount table, a workflow — is better served by examples, because the property would just restate the implementation. It is also slow by design, so it belongs alongside a fast example suite rather than replacing it.

  Non-determinism between runs is the operational cost: a test that generates new inputs each time can fail on a pull request that changed nothing, which is correct behaviour and still needs a process for triage.

  </details>

- **NICE** — Strategies and data generation

  <details><summary><strong>Answer</strong></summary>

  Strategies compose — `st.lists(st.integers(min_value=0))`, `st.builds(User, name=st.text())` — and `@st.composite` builds one for a domain object. `hypothesis.extra` has strategies derived from a Django model, a dataclass or a [NumPy](https://numpy.org/doc/stable/ "NumPy — Array library that stores homogeneous numeric data in contiguous buffers and computes over it in native code") array, which removes most of the setup.

  </details>

- **NICE** — Stateful testing

  <details><summary><strong>Answer</strong></summary>

  `RuleBasedStateMachine` generates *sequences* of operations against a system and checks invariants after each, which finds ordering bugs that no single-call property reaches. It is the version that applies to a cache, a queue or a state machine, and it is where the technique earns the most.

  </details>

- **OPTIONAL** — Fuzzing as the neighbour

  <details><summary><strong>Answer</strong></summary>

  `atheris` and coverage-guided fuzzing apply the same idea to crash-finding rather than property-checking, and are worth naming for parsers and anything handling untrusted binary input.

  </details>

## Web and Application Topics

## 8. ORM Behaviour

**Why it comes up:** the N+1 query is the most common performance defect in a Python web service, and it is invisible in the code that causes it.

- **MUST** — The N+1 query

  <details><summary><strong>Answer</strong></summary>

  Fetching a list of objects and then touching a related attribute on each one issues one query for the list and one per row — a hundred orders become a hundred and one round trips, each carrying network latency. Nothing in the source looks like a query; the loop that renders `order.customer.name` is the whole cause.

  The fixes are eager loading strategies: a join for a to-one relation, a second batched query for a to-many — `selectinload` and `joinedload` in [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries"), `select_related` and `prefetch_related` in Django. The detection is what matters most: log queries per request in development, or assert a query count in a test, because the defect never announces itself.

  </details>

- **MUST** — Lazy loading and where it explodes

  <details><summary><strong>Answer</strong></summary>

  A relationship is a **descriptor** that issues a query when first accessed, so the timing of a database call is decided by attribute access rather than by anything visible. Accessing it after the session is closed raises `DetachedInstanceError`; accessing it inside a template or a serialiser moves the queries somewhere nobody is looking.

  In async code the same laziness is worse: a lazy load triggered from a coroutine context that has no session is an error rather than a slow path. Loading explicitly at the query, and passing plain data structures outward, is what removes the class of problem.

  </details>

- **MUST** — Sessions, transactions and their lifetime

  <details><summary><strong>Answer</strong></summary>

  A session is a unit of work with an identity map and a transaction; its natural scope is one request or one job, committed at the end and rolled back on an exception. A session shared between requests leaks objects and state between them, and one that spans a long-running task holds a connection and a transaction open for its duration.

  Long transactions are the specific harm: they hold locks, block schema changes and keep old row versions from being reclaimed. Doing an HTTP call or a file upload inside an open transaction is the common version of that mistake.

  </details>

- **MUST** — Connection pooling

  <details><summary><strong>Answer</strong></summary>

  A pool keeps connections open because establishing one costs a round trip and authentication. The size is a real constraint: workers multiplied by pool size must stay under the database's connection limit, and twenty pods with a pool of ten each is two hundred connections against a default limit of one hundred.

  A pool that is too small queues requests invisibly, which shows as latency with no slow query. `pool_pre_ping`, or a recycle interval, handles connections killed by an idle timeout in a proxy or the database — otherwise the first query after a quiet period fails.

  </details>

- **NICE** — When to drop to SQL

  <details><summary><strong>Answer</strong></summary>

  An ORM is worth having for the ordinary 90%: mapping, identity, migrations and safety from injection. For a complex report, a window function, a bulk update or a query whose plan matters, hand-written SQL is clearer and faster, and every mature ORM supports executing it.

  The judgment is knowing which side a query is on. Fighting the query builder to express something SQL says in four lines is a signal to stop.

  </details>

- **NICE** — Migrations

  <details><summary><strong>Answer</strong></summary>

  Schema changes belong in versioned migrations — [Alembic](https://alembic.sqlalchemy.org/en/latest/ "Alembic — Applies and versions database schema migrations for SQLAlchemy") or Django's — reviewed like code, because an autogenerated migration can be wrong about renames and about data. Backwards-compatible changes deploy safely with rolling releases; an added non-null column without a default, or a dropped column still referenced by the running version, does not.

  The expand-and-contract sequence — add, backfill, switch, remove in a later release — is what makes a breaking change safe under zero-downtime deployment.

  </details>

- **OPTIONAL** — The identity map and stale reads

  <details><summary><strong>Answer</strong></summary>

  A session returns the same object for the same primary key, so a second query does not refresh an already-loaded instance unless asked. That is a useful guarantee and a source of confusion when a long-lived session serves data another transaction has since changed.

  </details>

## 9. WSGI and ASGI

**Why it comes up:** it explains why a synchronous framework cannot simply be made async, and it is the interface every Python web deployment sits on.

- **MUST** — What [WSGI](https://peps.python.org/pep-3333/ "Web Server Gateway Interface — Synchronous standard interface between Python web servers and applications") is

  <details><summary><strong>Answer</strong></summary>

  **WSGI** is the synchronous contract between a Python web server and an application: a callable taking an environment dictionary and a `start_response` function, returning an iterable of bytes. One call, one request, start to finish, occupying the worker for its whole duration.

  Because it is one standard, any WSGI server runs any WSGI application — gunicorn with Django or Flask, in any combination. That interchangeability is the point of having the specification at all.

  </details>

- **MUST** — What [ASGI](https://asgi.readthedocs.io/en/latest/ "Asynchronous Server Gateway Interface — Standard interface between asynchronous Python web servers and applications") adds

  <details><summary><strong>Answer</strong></summary>

  **ASGI** is the asynchronous successor: an `async` callable taking a scope, a `receive` and a `send`. Because the application can await, one process can hold thousands of requests in flight, and because messages flow in both directions over time, it also supports WebSockets, server-sent events and background lifespans — which WSGI structurally cannot express.

  The concurrency consequence is the one to name: WSGI buys concurrency with a worker per request, ASGI with a coroutine per request, and the second is two orders of magnitude cheaper for I/O-bound work.

  </details>

- **MUST** — Why you cannot just make a WSGI app async

  <details><summary><strong>Answer</strong></summary>

  The contract is synchronous at every level, so every middleware, every framework internal and every database call in the stack is written to block. Changing the outermost interface does not change what is underneath it, and one blocking call anywhere stops the whole loop.

  That is why Django's async support arrived incrementally over several releases and why a partly-converted application is slower than either pure form. Adapters exist in both directions — `asgiref`'s `sync_to_async` and `async_to_sync`, and a WSGI-to-ASGI wrapper — and each hands the work to a thread, so they are bridges rather than conversions.

  </details>

- **MUST** — Which to choose

  <details><summary><strong>Answer</strong></summary>

  Choose ASGI when the workload is I/O-bound with high concurrency, when WebSockets or streaming are needed, or when the ecosystem you are using is already async. Choose WSGI when the application is CPU-bound per request, when the libraries are synchronous, or when the team has no async experience and the concurrency requirement is modest.

  The honest point is that a synchronous stack with enough workers handles a great deal of real traffic, and that an async stack full of blocking calls handles less than either. The model has to be consistent to pay off.

  </details>

- **NICE** — The servers

  <details><summary><strong>Answer</strong></summary>

  gunicorn and uWSGI implement WSGI; uvicorn and hypercorn implement ASGI; and the common production shape is gunicorn as the process manager with uvicorn worker classes, which gives process supervision from one and the event loop from the other. Granian is a newer Rust-based server implementing both.

  </details>

- **NICE** — Where middleware lives

  <details><summary><strong>Answer</strong></summary>

  ASGI middleware wraps the application callable and sees the raw scope and messages, so it can act on a WebSocket as well as on an HTTP request. Framework-level middleware sits higher and sees request and response objects. Putting per-request work in the wrong layer — parsing a body in ASGI middleware, or doing connection setup per request — is a recurring source of overhead.

  </details>

- **OPTIONAL** — Lifespan

  <details><summary><strong>Answer</strong></summary>

  ASGI has a lifespan protocol for start-up and shutdown events, which is where a connection pool, a client or a background task belongs. Doing that work at import time instead means it happens during collection in tests and in any tool that imports the module.

  </details>

## 10. Sync and Async Frameworks

**Why it comes up:** the comparison is a proxy for whether the candidate chooses tools by fit rather than by fashion.

- **MUST** — What distinguishes the three

  <details><summary><strong>Answer</strong></summary>

  **Django** is batteries-included: ORM, migrations, admin, auth, forms and templates, with conventions that make a large team productive and a strong upgrade story. **Flask** is a microframework — routing and request handling, with everything else chosen by you. **FastAPI** is async-first on Starlette, deriving validation and [OpenAPI](https://www.openapis.org/ "OpenAPI Specification — Describes an HTTP API's endpoints, schemas and behavior in a machine readable format") documentation from type annotations.

  The choice follows the shape of the work: a content-and-admin application with a relational core is Django's home ground, a small service or an unusual architecture suits Flask, and a typed [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") API with high I/O concurrency suits FastAPI.

  </details>

- **MUST** — What FastAPI's typing actually buys

  <details><summary><strong>Answer</strong></summary>

  One declaration does three jobs: the annotation is the parser, the validator and the OpenAPI schema, so the documentation cannot drift from the code and a malformed body is rejected before the handler runs with a structured error. That is a genuine reduction in duplicated work rather than a convenience.

  The dependency injection system is the other half, and it is what makes a session, a current user or a settings object testable by overriding the dependency rather than by patching.

  </details>

- **MUST** — Django's async story, stated accurately

  <details><summary><strong>Answer</strong></summary>

  Django supports ASGI, async views and an async ORM interface, but the ORM's async methods largely run the synchronous implementation in a thread, so the benefit is limited and the middleware stack must be async-capable or it is adapted with a thread hop each way.

  The accurate summary is that Django can serve async workloads and was not built around them. Saying that plainly is better than either dismissing Django as synchronous or claiming parity it does not have.

  </details>

- **MUST** — Choosing for a team rather than for a benchmark

  <details><summary><strong>Answer</strong></summary>

  Framework throughput rarely decides a service's performance — the database, the network calls and the serialisation do. What differs is what the framework gives you for free and what it costs to maintain: Django's admin and migrations against assembling the same from parts, FastAPI's schema generation against Django's ecosystem depth.

  **The judgment being tested is** whether you weigh the team's experience, the ecosystem and the operational story rather than quoting a requests-per-second figure from a synthetic benchmark.

  </details>

- **NICE** — Mixing models inside one service

  <details><summary><strong>Answer</strong></summary>

  A FastAPI service can declare a handler `def` rather than `async def` and the framework runs it in a thread pool, which is the correct choice for a handler calling a blocking library. Doing the opposite — an `async def` handler containing a blocking call — stops the loop for every other request, and the mechanics of that are covered in `Python-concurrency.md`.

  </details>

- **NICE** — The smaller options

  <details><summary><strong>Answer</strong></summary>

  Starlette alone where FastAPI's validation is not wanted, Litestar as a typed alternative, Quart as an async Flask, and Sanic or aiohttp for lower-level async servers. Naming one or two shows the landscape is known rather than the default assumed.

  </details>

- **OPTIONAL** — The framework is not the architecture

  <details><summary><strong>Answer</strong></summary>

  Business logic that lives in view functions is hard to test and impossible to reuse from a job or a command-line entry point, whatever the framework. Keeping the domain independent of the web layer is what makes the framework choice reversible.

  </details>

## 11. The Request Lifecycle

**Why it comes up:** knowing where each piece of work belongs — middleware, handler, background, worker — is what separates a service that degrades gracefully from one that falls over.

- **MUST** — What happens to a request

  <details><summary><strong>Answer</strong></summary>

  The server accepts the connection and parses the HTTP message, the application's middleware chain runs outward-in, routing picks a handler, dependencies are resolved, the body is parsed and validated, the handler runs, the response is serialised, and middleware unwinds in reverse.

  Knowing the order matters because it says where a concern belongs: authentication and correlation IDs early, response compression late, and anything expensive nowhere in the chain at all, since middleware runs for every request including health checks.

  </details>

- **MUST** — What does not belong inline

  <details><summary><strong>Answer</strong></summary>

  Anything that is slow, unreliable or not needed for the response: sending an email, generating a report, calling a third party whose latency you do not control, resizing an image. Doing it inline ties the user's response time to something unrelated and makes a failure there a failure of the request.

  The replacement is a queued job with a durable store, and the request returns an identifier the client can poll or a webhook the system calls later. That also makes the work retryable, which an inline call is not.

  </details>

- **MUST** — Timeouts and limits at every layer

  <details><summary><strong>Answer</strong></summary>

  A request budget only exists if every outbound call has a timeout shorter than it — a client with no timeout inherits the server's, and a chain of them multiplies. Body size limits, a request timeout at the server and a limit on concurrent in-flight requests are what stop one slow dependency from consuming every worker.

  The failure this prevents is the cascade: a slow downstream service fills the pool, the upstream's requests queue, health checks time out, and the platform restarts a service that was not itself broken.

  </details>

- **MUST** — Where blocking work goes in an async service

  <details><summary><strong>Answer</strong></summary>

  A blocking call in an async handler stops every concurrent request on that worker, so it belongs in a thread via `asyncio.to_thread`, or in a process pool if it is CPU-bound, or in a background worker if it can be deferred. The mechanics and the diagnosis are covered in `Python-concurrency.md`.

  What belongs here is the design rule: the handler should do the minimum needed to produce the response, and everything else should have an owner outside the request path.

  </details>

- **NICE** — Observability per request

  <details><summary><strong>Answer</strong></summary>

  A correlation ID generated or accepted at the edge, stored in a `contextvar` and attached to every log line and outbound call, is what makes one request traceable across services. A per-request timer, a query counter and a span per external call turn "the endpoint is slow" into a specific answer.

  Adding these as middleware means they apply uniformly rather than being remembered per handler.

  </details>

- **NICE** — Idempotency and retries from the client

  <details><summary><strong>Answer</strong></summary>

  Clients retry, proxies retry, and a user double-clicks, so any endpoint with an effect needs to tolerate being called twice. An idempotency key stored with the result, or a natural unique constraint, is what makes the second call return the first result rather than creating a second order.

  </details>

- **OPTIONAL** — Streaming responses

  <details><summary><strong>Answer</strong></summary>

  A streaming response starts sending before the body is complete, which keeps memory flat for a large export and improves time to first byte. The cost is that an error partway through has already sent a 200, so the failure has to be expressed in the stream itself.

  </details>

## 12. Worker Models and Deployment

**Why it comes up:** worker and thread counts are set once and rarely understood, and the wrong numbers waste either money or headroom.

- **MUST** — Processes, workers and the reason for both

  <details><summary><strong>Answer</strong></summary>

  A process uses one core for Python bytecode, so parallelism comes from running several — gunicorn forking workers, or several single-worker containers. Concurrency within a worker comes from threads in a synchronous stack and from the event loop in an async one.

  The common shape is therefore processes for cores and the loop or a thread pool for concurrency inside each. Choosing one lever and ignoring the other is what produces a service that is either idle on seven cores or thrashing on one.

  </details>

- **MUST** — Sizing them

  <details><summary><strong>Answer</strong></summary>

  For CPU-bound synchronous work, roughly one worker per core; the often-quoted `2 × cores + 1` assumes I/O-bound handlers where a worker spends most of its time waiting. For async workers, one per core is usually right, because each already multiplexes.

  In a container the core count must come from the CPU limit rather than the host, or a pod with one core starts sixteen workers and spends its time context switching. Memory is the other bound: workers multiplied by resident size must fit the limit, and each worker also holds its own connection pool.

  </details>

- **MUST** — What is not shared between workers

  <details><summary><strong>Answer</strong></summary>

  Nothing in memory. An in-process cache exists once per worker, a rate limiter counting in a global counts per worker, a scheduled task registered at import runs in every worker, and a WebSocket connection lives in exactly one.

  Anything that must be shared belongs in [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store"), the database or a broker. This is the most common surprise when a service is scaled from one worker to several, because everything worked locally.

  </details>

- **MUST** — Restarts, health and shutdown

  <details><summary><strong>Answer</strong></summary>

  A worker with a memory leak or a slow leak from fragmentation is commonly restarted on a schedule — gunicorn's `max_requests` with jitter — which is a pragmatic mitigation rather than a fix. A worker timeout kills one that stops responding, and setting it below the longest legitimate request kills healthy work.

  Liveness and readiness are different questions: readiness should fail first on shutdown so traffic drains before the listener closes. The signal handling behind that is covered in `Python-concurrency.md`.

  </details>

- **NICE** — Preloading

  <details><summary><strong>Answer</strong></summary>

  `--preload` imports the application before forking, which speeds start-up and shares some memory. It also means each worker inherits anything created at import — most dangerously a database connection or a connection pool, which must not be shared across processes and has to be created per worker after the fork.

  </details>

- **NICE** — Autoscaling signals

  <details><summary><strong>Answer</strong></summary>

  CPU is a poor scaling signal for an I/O-bound async service, which can be saturated at low CPU. Request concurrency, queue depth or latency percentile track the real constraint, and scaling on the wrong one produces either a service that never scales up or one that never scales down.

  </details>

- **OPTIONAL** — Threads inside a worker

  <details><summary><strong>Answer</strong></summary>

  gunicorn's `gthread` worker gives threads within a process, which suits I/O-bound synchronous handlers and lets one process serve more concurrency than a worker per request. It does nothing for CPU-bound handlers, for the usual reason.

  </details>

## 13. Background Work

**Why it comes up:** every real service has work that must not happen in the request, and the interesting half is what happens when a task fails.

- **MUST** — Why a queue rather than a thread

  <details><summary><strong>Answer</strong></summary>

  Work handed to a background thread dies with the process — on a deploy, a crash, an out-of-memory kill — and nothing knows it was lost. A queue makes the work **durable**: it survives a restart, it can be retried, it can be observed, and it can be processed by workers scaled independently of the web tier.

  That is the distinction to lead with. FastAPI's `BackgroundTasks` and a fire-and-forget task are appropriate only for work whose loss is acceptable.

  </details>

- **MUST** — The options

  <details><summary><strong>Answer</strong></summary>

  [Celery](https://docs.celeryq.dev/en/stable/ "Celery — Distributed task queue that runs background and scheduled jobs outside the request cycle") is the mature, feature-heavy choice — scheduling, chains, routing, several brokers — and carries the operational weight to match. [RQ](https://python-rq.org/ "Redis Queue — Lightweight Python task queue that runs background jobs on Redis") is much simpler, Redis-only, and often sufficient. **arq** is the async-native equivalent, and **Dramatiq** sits between Celery and RQ. A database-backed queue is a legitimate answer for modest volume, because it needs no new infrastructure and inherits the transaction.

  Choosing the smallest one that covers the requirement is usually right; Celery's flexibility is a genuine operational cost.

  </details>

- **MUST** — Tasks must be idempotent

  <details><summary><strong>Answer</strong></summary>

  Delivery is at-least-once in every realistic setup: a worker can die after doing the work and before acknowledging, and the message is redelivered. So a task that charges a card, sends an email or increments a counter must be safe to run twice — through an idempotency key, a unique constraint, or a check of the current state before acting.

  Exactly-once delivery is not available; exactly-once *effect* is, and it is achieved by making the effect idempotent. That is the sentence worth having ready.

  </details>

- **MUST** — Arguments, retries and the dead letter

  <details><summary><strong>Answer</strong></summary>

  Pass identifiers, not objects: the payload is serialised, a large object bloats the queue, and by the time the task runs the object may be stale — so the task should load what it needs itself. Retries need a bounded count and exponential backoff, and a distinction between a transient failure worth retrying and a permanent one that never will be.

  After the last retry the message goes to a dead-letter queue, which someone must monitor. An unwatched dead-letter queue is where silently failed work accumulates for months.

  </details>

- **NICE** — The transactional gap

  <details><summary><strong>Answer</strong></summary>

  Committing a row and then enqueuing a task is two operations with no atomicity: a crash between them loses the task, and enqueuing before the commit can run the task before the row exists. The transactional outbox — write the task into the same transaction as the data, and publish from that table — is the standard fix.

  Where the queue is the database itself, the problem disappears, which is a real argument for a database-backed queue at modest scale.

  </details>

- **NICE** — Scheduled work

  <details><summary><strong>Answer</strong></summary>

  Celery Beat or a platform cron triggers periodic work, and the recurring mistake is running the scheduler in every replica so the job fires n times. A leader lock, or a single scheduler deployment, is what makes it fire once — and the job itself should still be idempotent, because that lock will eventually fail.

  </details>

- **OPTIONAL** — Monitoring a queue

  <details><summary><strong>Answer</strong></summary>

  Queue depth, oldest-message age and failure rate are the numbers that matter; task throughput on its own hides a backlog. Oldest-message age is the one that catches a queue being processed steadily but slower than it fills.

  </details>

## 14. Configuration and Secrets

**Why it comes up:** hard-coded configuration and leaked secrets are both everyday failures, and the twelve-factor answer is short and checkable.

- **MUST** — Configuration comes from the environment

  <details><summary><strong>Answer</strong></summary>

  The same artefact should run in every environment with its behaviour supplied from outside, because building a separate image per environment means the thing tested is not the thing deployed. Environment variables are the lowest common denominator across containers, platforms and local development.

  What follows is that configuration is a deployment concern, not a code concern: no `if ENV == "production"` branches, and no settings module per environment holding values.

  </details>

- **MUST** — Validate configuration at start-up

  <details><summary><strong>Answer</strong></summary>

  Every variable arrives as a string, so it must be parsed and checked — and the right moment is start-up, so that a missing or malformed value fails the deploy rather than the first request that happens to need it. [Pydantic](https://docs.pydantic.dev/latest/ "Pydantic — Python library that validates and parses data against typed models at runtime")'s settings support, or an explicit loader, does this in one place with types.

  **The rule is** fail fast and loudly: a service that starts with a missing API key and only errors an hour later under a specific code path has converted a configuration error into an incident.

  </details>

- **MUST** — Secrets are not configuration

  <details><summary><strong>Answer</strong></summary>

  A secret needs to be stored encrypted, access-controlled, rotatable and auditable, which a plain environment variable is not — it is visible in the process environment, in a crash dump, in a debug endpoint that prints settings, and often in the orchestrator's own API.

  The graded answer is: never in the repository, never in the image, from a secret manager where one exists — cloud provider, Vault, or the platform's own secret objects mounted as files — and injected into the process at start. Mounted files are preferable to environment variables because they can be rotated without a restart and do not appear in a process listing.

  </details>

- **MUST** — Keeping them out of logs and errors

  <details><summary><strong>Answer</strong></summary>

  The recurring accidents are logging the whole configuration at start-up, logging a request that contains an authorisation header, an exception whose message includes a connection string, and a debug page that renders local variables. A secret in a log has leaked into a system with different access control and a long retention.

  The defences are a redacting log filter, a `__repr__` on any secret-carrying type that prints nothing, and debug mode off in production. The logging side of this is covered in `Python-typing-stdlib.md`; what belongs here is that the secret must be unprintable by construction rather than by discipline.

  </details>

- **NICE** — Local development

  <details><summary><strong>Answer</strong></summary>

  A `.env` file loaded in development is fine as long as it is in `.gitignore`, a committed `.env.example` documents the variable names with placeholder values, and the loader does not run in production. A pre-commit secret scanner such as `gitleaks` catches what discipline misses.

  </details>

- **NICE** — Rotation and what a leak costs

  <details><summary><strong>Answer</strong></summary>

  A secret committed to a repository stays in the history after it is deleted, so the response is rotation and not removal — assume it is compromised from the moment of the push. Designing for rotation from the start, with a credential that can be replaced without a code change, is what makes that response a routine operation rather than an outage.

  </details>

- **OPTIONAL** — Feature flags as configuration

  <details><summary><strong>Answer</strong></summary>

  A flag changed without a deploy is operationally valuable and becomes debt quickly: every flag is a branch that must be tested in both states. Flags need an owner and a removal date, or they become permanent configuration nobody understands.

  </details>

## Security Topics

## 15. SQL Injection and Parameterised Queries

**Why it comes up:** it is the oldest question in the list and still the most likely to be asked, because the wrong answer is a critical vulnerability.

- **MUST** — What parameterisation actually does

  <details><summary><strong>Answer</strong></summary>

  A **parameterised query** sends the SQL text and the values to the database separately, so the value is never parsed as part of the statement. `cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))` is safe for any content of `user_id`, because the database receives it as data rather than as text to compile.

  The critical distinction is that this is not escaping. Escaping is a transformation someone can get wrong or forget; parameterisation removes the possibility, because the value never reaches the parser at all.

  </details>

- **MUST** — What is unsafe

  <details><summary><strong>Answer</strong></summary>

  Any construction of the statement from input: f-strings, `%` formatting, `.format`, and string concatenation. `f"SELECT * FROM users WHERE name = '{name}'"` is the vulnerability, and it does not stop being one because the value "comes from our own frontend" — the request can be made directly.

  Passing the tuple to `execute` is the fix, and the note that catches people out is that `execute("...", params)` with a second argument is safe while `execute("..." % params)` has already done the damage before the call.

  </details>

- **MUST** — What cannot be parameterised

  <details><summary><strong>Answer</strong></summary>

  Only values can be bound. A table name, a column name, a sort direction or the structure of the query cannot be — so dynamic sorting and filtering, which is where most remaining injection lives, needs a different defence.

  That defence is an **allow-list**: map the client's `sort=name` to a known column from a dictionary you control, and reject anything not in it. Never interpolate an identifier the client supplied, even after checking it looks harmless.

  </details>

- **MUST** — ORMs help and do not immunise

  <details><summary><strong>Answer</strong></summary>

  A query built through the ORM's expression language is parameterised for you, which is the main security argument for using one. The gaps are the escape hatches: `text()` with an f-string, `raw()`, `extra()`, and any place a fragment is concatenated into a filter.

  So the review rule is to grep for the raw-SQL entry points rather than to assume the ORM covers everything. `sqlalchemy.text("... :id")` with bound parameters is the safe form of the same escape hatch.

  </details>

- **NICE** — Defence in depth

  <details><summary><strong>Answer</strong></summary>

  Least privilege on the database user so the application cannot drop a table or read another schema, validation of input shape before it reaches the query, and a web application firewall as a coarse net. None of these substitutes for parameterisation; each limits what a missed instance can reach.

  Error messages matter too: returning the database's error to the client hands an attacker the schema and the query structure.

  </details>

- **NICE** — Finding it

  <details><summary><strong>Answer</strong></summary>

  `bandit` and ruff's security rules flag string-built SQL, and a code-search for the formatting operators next to `execute` finds most of the rest. Both belong in CI rather than in a periodic audit, because this is the class of defect that is cheap to catch automatically.

  </details>

- **OPTIONAL** — The other injections

  <details><summary><strong>Answer</strong></summary>

  The same shape appears wherever input becomes part of an interpreted string: a shell command, an [LDAP](https://datatracker.ietf.org/doc/html/rfc4511 "Lightweight Directory Access Protocol — Queries and modifies directory services holding users and groups") filter, a [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") query document, an XPath expression, a template. The defence is always the same — pass the value as a parameter to a structured interface rather than concatenating it into a language.

  </details>

## 16. Input Validation and Unsafe Deserialisation

**Why it comes up:** a single `yaml.load` or `pickle.loads` on untrusted data is remote code execution, and the safe alternative is one word different.

- **MUST** — Validate at the boundary, and what that means

  <details><summary><strong>Answer</strong></summary>

  Everything from outside is untrusted: request bodies, query parameters, headers, uploaded files, message payloads, webhooks, and responses from third parties. Validation converts that into a typed object once, at the edge, with unknown fields rejected or dropped deliberately rather than passed through.

  Validate for shape **and** for domain rules — a positive amount, a permitted enum value, a date range that makes sense. A type check alone accepts a negative price, and the authorisation question is separate again: whether this user may act on this object is not something a schema can answer.

  </details>

- **MUST** — The deserialisers that execute code

  <details><summary><strong>Answer</strong></summary>

  `pickle.loads`, `yaml.load` without a safe loader, `eval`, `exec`, and `marshal` all construct or run arbitrary code from their input. There is no sanitising step that makes them safe on untrusted data, which is why the answer is to use a different format rather than to filter the input.

  `yaml.safe_load`, `json.loads` and `ast.literal_eval` are the safe counterparts. The pickle boundary is covered in `Python-typing-stdlib.md`; what matters here is the rule that any format capable of reconstructing arbitrary objects is an execution vector.

  </details>

- **MUST** — File uploads

  <details><summary><strong>Answer</strong></summary>

  A filename from a client is input: it can contain `..`, a null byte, or a name that overwrites something. Generate the stored name yourself, never use the supplied one as a path, and resolve the final path to check it is still inside the intended directory.

  Enforce a size limit before reading, determine the type from the content rather than the extension or the client's `Content-Type`, and store uploads outside the web root or in object storage — so that an uploaded file cannot be served back as code.

  </details>

- **MUST** — Injection into other interpreters

  <details><summary><strong>Answer</strong></summary>

  Input reaching a shell is command injection, input reaching [HTML](https://html.spec.whatwg.org/ "HyperText Markup Language — Markup format that structures content for web browsers") is cross-site scripting, input reaching a [URL](https://datatracker.ietf.org/doc/html/rfc3986 "Uniform Resource Locator — Addresses the location and access method of a resource on the web") a server fetches is server-side request forgery, and input reaching a redirect is an open redirect. The pattern is the same: a value crossing into a context where it can be read as instructions.

  The defences are contextual — argument lists rather than a shell string, template auto-escaping for HTML, an allow-list of hosts for outbound fetches — and the habit worth stating is to ask, at each boundary, what language the value is about to become part of.

  </details>

- **NICE** — Denial of service through input

  <details><summary><strong>Answer</strong></summary>

  A deeply nested JSON document, a zip bomb, a regex with catastrophic backtracking on a crafted string, or a request for a million records all consume resources disproportionate to their size. Limits on body size, nesting depth, page size and regex complexity — or a linear-time engine such as `re2` — are what bound them.

  </details>

- **NICE** — Where validation does not belong

  <details><summary><strong>Answer</strong></summary>

  Re-validating the same object at every internal layer is cost without benefit and produces inconsistent error handling. Validate once at the edge and let the type system carry the guarantee inward, which is the same conclusion the typing discussion reaches from the other direction.

  </details>

- **OPTIONAL** — Signed payloads

  <details><summary><strong>Answer</strong></summary>

  An [HMAC](https://datatracker.ietf.org/doc/html/rfc2104 "Hash based Message Authentication Code — Verifies both the integrity and authenticity of a message using a shared secret key") or a signed token proves a payload came from a party holding the key and was not modified, which is what a webhook signature verifies. It does not make an unsafe format safe — a signed pickle is still a pickle, and a compromised key is then full code execution.

  </details>

## 17. Secrets Handling

**Why it comes up:** it is the security topic most likely to be tested by an anecdote, and the good answer covers detection and rotation rather than only storage.

- **MUST** — Never in the repository or the image

  <details><summary><strong>Answer</strong></summary>

  A committed secret is in the history of every clone forever, and deleting it in a later commit changes nothing. A secret baked into a container image is readable by anyone who can pull the image, including from a layer that a later `RUN` appeared to remove.

  The rule is that a secret is injected at run time — from a secret manager, or as a mounted file — and that the artefact itself contains none. Build arguments are not a workaround, since they are recorded in the image metadata.

  </details>

- **MUST** — Environment variables and their limits

  <details><summary><strong>Answer</strong></summary>

  They are the practical default and they are not private: they appear in `/proc`, in a crash report, in a debug endpoint that dumps settings, in a child process created by `subprocess`, and often in the orchestrator's API to anyone who can read a pod specification.

  Mounted files are better where available — they can be rotated without restarting the process, they are not inherited by children, and access can be controlled by file permissions. Naming that difference is what distinguishes a considered answer from a repeated slogan.

  </details>

- **MUST** — Rotation and the response to a leak

  <details><summary><strong>Answer</strong></summary>

  Treat a secret that has appeared in a log, a repository, a screenshot or a ticket as compromised, and rotate it — removal does not undo exposure. That is only affordable if rotation is routine, which means short-lived credentials where possible, and a design where replacing a credential needs no code change.

  Workload identity — the platform issuing a short-lived token to the running service — removes the long-lived secret entirely and is the direction to name for cloud deployments. Where a static key remains, it should be scoped to exactly what it needs.

  </details>

- **MUST** — Accidental disclosure

  <details><summary><strong>Answer</strong></summary>

  The everyday leaks are a logged request with an authorisation header, a start-up line printing the settings object, a traceback in debug mode showing local variables, an exception whose message contains a connection string, and a metrics label carrying a token.

  The structural defence is a type whose `__repr__` and `__str__` print a placeholder, so the value cannot be formatted into anything by accident — Pydantic's secret types do this. That is better than a redaction filter, which depends on knowing every field name in advance.

  </details>

- **NICE** — Detection

  <details><summary><strong>Answer</strong></summary>

  `gitleaks` or `detect-secrets` as a pre-commit hook and as a CI job catches most commits before they land, and provider-side scanning catches some after. A scan of the full history when adopting one is worth doing, because the interesting findings are usually old.

  </details>

- **NICE** — Who can see what

  <details><summary><strong>Answer</strong></summary>

  Access to the secret store should be scoped per service and audited, so that a compromise of one workload does not yield every credential. A single shared set of production credentials that every engineer can read is the common reality and is worth naming as the risk it is.

  </details>

- **OPTIONAL** — Encryption at rest is not enough

  <details><summary><strong>Answer</strong></summary>

  A secret manager encrypts storage, which protects against a stolen disk and not against an application that can read every secret it asks for. Scoping and short lifetimes are what limit the blast radius; encryption is table stakes.

  </details>

## 18. The Dependency Supply Chain

**Why it comes up:** most of the code in a service is somebody else's, and the attacks on that path have become routine rather than theoretical.

- **MUST** — What the threat actually is

  <details><summary><strong>Answer</strong></summary>

  Installing a package runs its build and imports its code, so a malicious or compromised dependency executes with your permissions — in CI, where the credentials usually are, as much as in production. The routes are a compromised maintainer account, a malicious release of a legitimate package, a **typosquatted** name, and dependency confusion, where a public package with an internal name is resolved in preference to the private one.

  The transitive set is what makes it serious: a direct dependency list of twenty is a real graph of several hundred, and every one of them is trusted.

  </details>

- **MUST** — Pinning and hashes

  <details><summary><strong>Answer</strong></summary>

  A lock file fixes the exact versions so the install is reproducible; `--require-hashes` goes further and fails if a package's contents differ from what was recorded, which defends against a republished artefact. The mechanics of lock files are covered in `Python-typing-stdlib.md`.

  What belongs here is why it is a security control and not only a reproducibility one: without it, an install performed today can differ from the one that was reviewed and tested, and nothing detects the difference.

  </details>

- **MUST** — Auditing and updating

  <details><summary><strong>Answer</strong></summary>

  `pip-audit` checks the installed set against the advisory database and belongs in CI as a blocking or reporting job. Pinning without updating is its own risk, so it must be paired with automated update pull requests gated by the test suite.

  The tension to state honestly is between updating fast, which limits exposure to known vulnerabilities, and updating carefully, which limits exposure to a malicious release. A short delay before adopting a new version is a reasonable compromise, and some tools support it directly.

  </details>

- **MUST** — Reducing what you depend on

  <details><summary><strong>Answer</strong></summary>

  The cheapest control is fewer dependencies: a small utility package replaced by twenty lines of standard library removes an entire branch of the graph. Development-only tools must not be installed in the production image, which is what dependency groups and a multi-stage build are for.

  Judging a new dependency on its maintenance, its own dependency count and its release history — rather than only on whether it works — is the habit this question is looking for.

  </details>

- **NICE** — Build and CI integrity

  <details><summary><strong>Answer</strong></summary>

  CI is where the credentials are, so a compromised dependency there is often worse than in production. Pinning actions and base images by digest, minimising token scope, and avoiding running untrusted code with secrets in the environment are the controls.

  Trusted publishing with [OIDC](https://openid.net/developers/how-connect-works/ "OpenID Connect — Identity layer on top of OAuth 2.0 for authenticating users") removes the long-lived publishing token, which has historically been the credential that leaks.

  </details>

- **NICE** — Inventory

  <details><summary><strong>Answer</strong></summary>

  An [SBOM](https://www.cisa.gov/sbom "Software Bill of Materials — Inventory of every component and dependency in a build") generated at build time answers "are we affected" in minutes rather than days when an advisory lands. That question is the one that actually gets asked during an incident, and a list assembled by hand afterwards is always incomplete.

  </details>

- **OPTIONAL** — Private indexes and confusion

  <details><summary><strong>Answer</strong></summary>

  When an internal index is configured alongside the public one, some tools consult both and take the highest version — so publishing an internal name publicly can hijack the install. Reserving internal names publicly, or configuring the index to be exclusive for those names, is the defence.

  </details>

## 19. Randomness

**Why it comes up:** it is a one-line question with a security answer, and using the wrong module for a token is a real vulnerability that looks like working code.

- **MUST** — `random` is predictable by design

  <details><summary><strong>Answer</strong></summary>

  `random` uses a **Mersenne Twister**, which is fast, well-distributed and completely deterministic: observing 624 consecutive outputs is enough to reconstruct the internal state and predict every subsequent value. Seeding it from the clock makes it worse, not better, because the seed space is then small and guessable.

  That is fine for simulation, sampling, shuffling test data and jitter on a retry. It is not fine for anything an attacker would benefit from predicting.

  </details>

- **MUST** — Use `secrets` for anything security-relevant

  <details><summary><strong>Answer</strong></summary>

  `secrets` draws from the operating system's cryptographically secure source, and it has the right helpers: `token_urlsafe(32)` for a session token or an API key, `token_hex`, `choice` for a code, and `compare_digest` for comparing secrets without a timing side channel.

  The list of things that must use it is short and worth reciting: session identifiers, password-reset and email-verification tokens, API keys, [CSRF](https://owasp.org/www-community/attacks/csrf "Cross Site Request Forgery — Attack that makes a signed-in user's browser submit an unintended request") tokens, nonces, salts, and any one-time code. A password reset token generated with `random` is a full account takeover.

  </details>

- **MUST** — Enough entropy, and the right shape

  <details><summary><strong>Answer</strong></summary>

  32 bytes is the usual recommendation for a token, which `token_urlsafe(32)` encodes to 43 characters. Shorter values become guessable in bulk, and a token built from a timestamp, a user ID or a counter is not random at all whatever function produced it.

  The other half is storage: a token that authenticates should be stored hashed, so a leak of the table does not hand over live credentials — the same reasoning as for passwords, though a high-entropy token needs only a fast hash rather than a slow one.

  </details>

- **MUST** — Identifiers and UUIDs

  <details><summary><strong>Answer</strong></summary>

  `uuid4` is random and suitable as a non-guessable identifier; `uuid1` embeds the [MAC](https://en.wikipedia.org/wiki/MAC_address "Media Access Control — Hardware address identifying a network interface") address and the time and is therefore both predictable and a small information leak. `uuid7` from 3.14 is time-ordered, which indexes far better in a database while keeping enough randomness for identity.

  A [UUID](https://datatracker.ietf.org/doc/html/rfc9562 "Universally Unique Identifier — 128-bit identifier that can be generated without a central authority") is an identifier, not a secret: it is fine in a URL as a reference and should not be the thing that grants access, because identifiers end up in logs, referrer headers and support tickets.

  </details>

- **NICE** — Passwords are a separate problem

  <details><summary><strong>Answer</strong></summary>

  Password hashing needs a deliberately slow, salted, memory-hard algorithm — [Argon2](https://datatracker.ietf.org/doc/html/rfc9106 "Argon2 — Memory-hard password hashing function designed to make cracking a leaked password table expensive"), scrypt or bcrypt — precisely so that a leaked table is expensive to attack. A fast hash such as [SHA-256](https://csrc.nist.gov/pubs/fips/180-4/upd1/final "Secure Hash Algorithm 256-bit — Produces a fixed-size digest used to verify content integrity"), with or without a salt, is the wrong tool, and hashing at all is only relevant if you are storing passwords rather than delegating to an identity provider.

  </details>

- **NICE** — Reproducibility where it is wanted

  <details><summary><strong>Answer</strong></summary>

  A seeded `random.Random(42)` instance gives repeatable output for a test or a simulation, and using an instance rather than the module-level functions avoids affecting global state that another part of the program depends on. NumPy's generator API is the equivalent for numeric work.

  </details>

- **OPTIONAL** — Where the entropy comes from

  <details><summary><strong>Answer</strong></summary>

  `os.urandom` and `secrets` read the operating system's pool, which is seeded from hardware sources and does not block on a modern kernel once initialised. The historical concern about a freshly booted virtual machine having insufficient entropy is largely resolved, but it is the reason the question exists.

  </details>
