# Fundamental Topics: Databases

**Table of Contents**

**[Common Topics](#common-topics)**

- [1. ACID and BASE](#1-acid-and-base)
- [2. Relational and NoSQL Databases Compared](#2-relational-and-nosql-databases-compared)
- [3. Sharding, Partitioning and Replication](#3-sharding-partitioning-and-replication)
- [4. The N+1 Problem](#4-the-n1-problem)

**[Relational Database Topics](#relational-database-topics)**

- [5. Indexes and PostgreSQL Index Types](#5-indexes-and-postgresql-index-types)
- [6. Transaction Isolation Levels](#6-transaction-isolation-levels)
- [7. MVCC](#7-mvcc)
- [8. VACUUM, VACUUM FULL and Autovacuum](#8-vacuum-vacuum-full-and-autovacuum)
- [9. EXPLAIN and EXPLAIN ANALYZE](#9-explain-and-explain-analyze)
- [10. The PostgreSQL Query Planner](#10-the-postgresql-query-planner)
- [11. Normal Forms, Normalization and Denormalization](#11-normal-forms-normalization-and-denormalization)
- [12. Performance for Read and for Write Workloads](#12-performance-for-read-and-for-write-workloads)
- [13. Lock Types in PostgreSQL](#13-lock-types-in-postgresql)
- [14. Constraints](#14-constraints)
- [15. Views and Materialized Views](#15-views-and-materialized-views)
- [16. Row-Level Security in PostgreSQL](#16-row-level-security-in-postgresql)
- [17. Triggers, Functions and Procedures](#17-triggers-functions-and-procedures)
- [18. Pages and TOAST in PostgreSQL](#18-pages-and-toast-in-postgresql)

**[NoSQL Database Topics](#nosql-database-topics)**

- [19. NoSQL Database Types](#19-nosql-database-types)
- [20. Horizontal Scaling](#20-horizontal-scaling)
- [21. Redis Data Structures](#21-redis-data-structures)
- [22. Transactions in NoSQL](#22-transactions-in-nosql)
- [23. Resolving Eventual Consistency with Anti-Entropy and Reconciliation](#23-resolving-eventual-consistency-with-anti-entropy-and-reconciliation)
- [24. Full-Text Search with Inverted Indexes, Tokenization and Trigrams](#24-full-text-search-with-inverted-indexes-tokenization-and-trigrams)
- [25. Schema on Write and Schema on Read](#25-schema-on-write-and-schema-on-read)
- [26. Strong Eventual Consistency and CRDTs](#26-strong-eventual-consistency-and-crdts)
- [27. Vector Clocks and Lamport Clocks](#27-vector-clocks-and-lamport-clocks)

**What this is.** The database topics a backend engineer is expected to discuss from first principles rather than recite, taken from the list in `docs/tmp/common-kb/DBs.txt`. It is common knowledge, bound to no case, project or employer: every example is generic, and nothing here assumes you worked on a particular system. [PostgreSQL](https://www.postgresql.org/docs/current/ "PostgreSQL — Relational database storing and querying structured data with strong transactional guarantees") is the concrete reference wherever a relational topic needs one, because it is the store most often named in the room and because its mechanics are documented well enough to be argued about precisely.

**How to use it.** Answer the bullet out loud first, then expand the **Answer** beneath it to check yourself — the block is collapsed so the bullet stays a recall test rather than a reading exercise. Every bullet carries one. A topic you can only define is not yet known.

**What an answer block is.** The substance the same answer should have in the room: what the thing is, the mechanism underneath it, the trade-off it buys and what that costs, and the failure it prevents or causes. It is a target, not a script — the point is to hear whether your own answer reached the same substance. Each block stands alone; there is no companion question file to defer to.

**Order.** Topics run most-probed first within each group, and bullets run the same way inside a topic. The first bullets of topic 1, 5 and 19 are the ones you are most likely to be asked. The grouping follows `DBs.txt`: what holds for every database, then what is specific to relational stores, then what is specific to non-relational ones.

**Priority.** Every subtopic carries one:

| Priority | Meaning |
|---|---|
| **MUST** | Expect it probed directly. A vague answer here reads as a gap in fundamentals rather than a gap in experience, and it casts doubt on the answers around it. |
| **NICE** | Strengthens the answer and shows depth. A gap is survivable if you say plainly that you have not worked with it. |
| **OPTIONAL** | Worth knowing exists, and worth a sentence if it comes up. It surfaces only when you or the interviewer chooses to go deeper. |

The split is 123 MUST, 53 NICE and 26 OPTIONAL across 27 topics. A MUST-heavy list is what a fundamentals list looks like: these are the topics an interviewer reaches for when checking that the foundation is there, rather than the ones that show range.

**Why it comes up:** under each heading names what the topic is actually testing, since most of these are asked as a proxy for something else.

## Common Topics

## 1. ACID and BASE

**Why it comes up:** it is the vocabulary every later answer about consistency, replication and distributed writes is built from, so a loose answer here undermines topics 6, 22 and 26.

- **MUST** — Atomicity, Consistency, Isolation, Durability: what each actually promises

  <details><summary><strong>Answer</strong></summary>

  **Atomicity** is all-or-nothing: a transaction's writes either all become visible or none do, including after a crash mid-way. Isolation is the promise that concurrent transactions produce a result equivalent to some serial order — and it is the one you buy in degrees, because full serializability costs throughput. **Durability** is that a committed transaction survives loss of power, which in practice means the write-ahead log reached stable storage before the commit was acknowledged.

  **Consistency** is the odd one out: the database only enforces the constraints you declared — keys, foreign keys, checks — so "consistency" here means your invariants, and any invariant you did not declare is not protected by the C in [ACID](https://en.wikipedia.org/wiki/ACID "Atomicity, Consistency, Isolation, Durability — Names the four guarantees a database transaction provides") at all. That last point is the one interviewers listen for, because it is where application bugs hide.

  </details>

- **MUST** — Consistency in ACID and consistency in [CAP](https://en.wikipedia.org/wiki/CAP_theorem "Consistency, Availability and Partition tolerance — Names the theorem that a distributed system can guarantee only two of the three during a network partition") are two different words

  <details><summary><strong>Answer</strong></summary>

  ACID consistency is about integrity constraints holding across a transaction on one node; CAP consistency is linearizability — every reader sees the latest committed write, no matter which replica answers. They are unrelated properties that share a name, and conflating them produces nonsense like "we use an ACID database so we are consistent across regions".

  A single-node PostgreSQL is ACID-consistent and says nothing about CAP; a replicated store can be linearizable and still let you write a row that violates a business rule you never declared. When the question is about a distributed system, say which of the two you mean before answering.

  </details>

- **MUST** — [BASE](https://en.wikipedia.org/wiki/Eventual_consistency "Basically Available, Soft state, Eventually consistent — Names the availability-first alternative to ACID guarantees in distributed stores"): basically available, soft state, eventually consistent, and what it actually buys

  <details><summary><strong>Answer</strong></summary>

  BASE is the deliberate opposite trade: stay available and accept that replicas disagree for a window, rather than refuse writes to keep them identical. "**Basically available**" means the system answers even when parts of it are unreachable, "soft state" means a replica's value may change without a new write as replication catches up, and "**eventually consistent**" means the replicas converge if writes stop.

  What it buys is write availability and latency under partition and at geographic scale; what it costs is that the application must now tolerate stale reads and resolve conflicting writes, which is real work pushed up the stack rather than work avoided.

  **The honest framing is** that BASE is not weaker engineering, it is a different placement of the same difficulty — and it is a bad trade for anything where two conflicting versions cannot be merged, such as money.

  </details>

- **MUST** — Durability in practice: the write-ahead log, fsync, group commit, and the knobs that trade it away

  <details><summary><strong>Answer</strong></summary>

  Durability is implemented by writing the change to a sequential log and flushing that log to stable storage before acknowledging the commit — the data pages themselves can be written lazily afterwards, which is why one sequential **fsync** buys durability for a scattered set of page writes. **Group commit** amortizes that flush across concurrent transactions, which is why throughput often improves under concurrency rather than degrading.

  The knobs matter: PostgreSQL's `synchronous_commit = off` acknowledges before the flush, so you keep atomicity and lose only the last fraction of a second of commits on a crash, while `fsync = off` gives up crash safety entirely and is never right in production. In a replicated setup durability extends outward — acknowledging on the primary alone means a failover can lose committed transactions, so synchronous replica acknowledgement is the version of durability that survives losing the machine.

  </details>

- **MUST** — Where ACID stops: one database, not two services

  <details><summary><strong>Answer</strong></summary>

  A transaction is a property of **one database** connection to one database; the moment a unit of work spans two stores or two services, there is no commit that covers both, and pretending otherwise is the most common distributed-systems bug. The practical patterns are the transactional outbox — write the business row and an event row in the same local transaction, and publish the event separately from that table — and the saga, a sequence of local transactions with an explicit compensating action for each. Both replace atomicity with eventual consistency plus idempotency, so consumers must tolerate duplicates and out-of-order delivery.

  The failure mode they exist to prevent is the "write to the database, then publish to the broker" pair, which silently loses events on every crash between the two.

  </details>

- **NICE** — CAP and [PACELC](https://en.wikipedia.org/wiki/PACELC_design_principle "Partition, Availability, Consistency, Else Latency, Consistency — Extends CAP by naming the latency against consistency trade that applies when there is no partition") as the reason BASE exists

  <details><summary><strong>Answer</strong></summary>

  CAP says that when a network partition occurs, a distributed store must choose between refusing to answer and answering with possibly stale data — it is a statement about behaviour during a partition, not a menu of three properties to pick two from at design time. **PACELC** is the more useful form because it adds the case that dominates real life: else, when there is no partition, you still trade latency against consistency, since a linearizable read has to reach a quorum.

  That is the honest reason most globally distributed stores default to eventual consistency — not partitions, which are rare, but the cross-region round trip on every request, which is not.

  **Quoting PACELC rather than CAP alone signals** you have thought about steady state and not just about the disaster.

  </details>

- **NICE** — Modern stores that offer ACID inside a boundary, and what the boundary costs

  <details><summary><strong>Answer</strong></summary>

  The ACID/BASE split is a spectrum rather than a camp: [MongoDB](https://www.mongodb.com/docs/ "MongoDB — Document database that stores schema-flexible JSON-like documents") gives atomic single-document writes and multi-document transactions with a real cost, DynamoDB gives conditional writes plus a bounded transactional [API](https://en.wikipedia.org/wiki/API "Application Programming Interface — Defines the contract by which software components exchange requests and data"), Cassandra offers lightweight transactions via Paxos on a single partition, and Spanner or CockroachDB give serializable distributed transactions by paying in coordination and latency. The pattern is that atomicity is cheap inside one partition or document and expensive across them, which is a data-modelling instruction: put what must change together in one place.

  The good answer names the boundary explicitly — "atomic within a partition key" — rather than saying a store "supports transactions", because the guarantee is defined by its scope.

  </details>

- **OPTIONAL** — Two-phase commit: correct, and rarely used

  <details><summary><strong>Answer</strong></summary>

  **Two-phase commit** has a coordinator ask every participant to prepare, and commit only if all vote yes, which gives genuine atomicity across stores. It is avoided because it is blocking: if the coordinator dies after the prepare vote, participants hold their locks and cannot decide alone, so a stall in one component becomes a stall in all of them, and availability is the product of every participant's. Three-phase commit and consensus-based coordinators reduce but do not remove the coupling.

  Knowing why it is unpopular is more useful than knowing the protocol, since the answer is what motivates sagas and outboxes.

  </details>

## 2. Relational and NoSQL Databases Compared

**Why it comes up:** it is really a test of whether you choose a store from access patterns and invariants, or from fashion.

- **MUST** — The real differences: data model, schema enforcement, join capability, transaction scope, scaling axis

  <details><summary><strong>Answer</strong></summary>

  A relational store keeps normalized tuples with a schema the database enforces, can join any table to any other at query time, and gives ACID transactions across the whole dataset on one node; a [NoSQL](https://en.wikipedia.org/wiki/NoSQL "Not Only SQL — Describes non-relational databases optimized for flexible schemas or horizontal scale") store typically keeps denormalized aggregates addressed by a key, enforces little or nothing about their shape, joins in the application if at all, and scopes transactions to one key or document so writes can be routed independently to many nodes. Everything else follows from that: the relational model optimizes for asking questions you did not anticipate, and the NoSQL model optimizes for serving a known access pattern at scale.

  **The distinction that survives scrutiny is** query flexibility against horizontal write scale, not "[SQL](https://en.wikipedia.org/wiki/SQL "Structured Query Language — Queries and manipulates data in a relational database") versus not SQL" and certainly not speed — a well-indexed relational query on a single node beats a badly modelled document store easily.

  </details>

- **MUST** — How to actually choose: start from access patterns, invariants and cardinality, not from scale you do not have

  <details><summary><strong>Answer</strong></summary>

  The three questions that decide it are what queries must be served, what invariants must never be violated, and how the data will be written. If the queries are varied and partly unknown, a relational store is the safer default, because normalized data can answer questions you have not thought of and denormalized data cannot. If invariants span entities — a balance, a unique constraint, a booking that must not double-allocate — that is a hard argument for a store that can enforce them in one transaction. Scale enters only as a measured constraint: most systems that pick a NoSQL store "for scale" are running at a volume one PostgreSQL instance handles without effort, and pay the cost of hand-written joins for years.

  **The honest closing line is** that the two are commonly used together — a relational system of record with a key-value cache, a search index, or a document store for one high-volume aggregate.

  </details>

- **MUST** — Why joins disappear in NoSQL and what replaces them

  <details><summary><strong>Answer</strong></summary>

  A distributed join needs data from several partitions on several nodes, so the store would have to move data across the network mid-query with unpredictable cost — most NoSQL stores refuse rather than offer an operation that occasionally takes minutes. What replaces it is modelling: embed the related data in the aggregate, duplicate it deliberately, or keep a second table keyed for the second access pattern and write to both.

  The cost lands on writes and on correctness — every duplicate is a copy that can drift, and keeping them in step is application code that a foreign key would have done for free.

  The good answer names the tell: if you find yourself writing join loops in the service layer, you have a relational workload in a non-relational store.

  </details>

- **MUST** — Schema flexibility is a shift of enforcement, not an absence of schema

  <details><summary><strong>Answer</strong></summary>

  Data always has a schema; the only question is whether the database enforces it or the readers do. Schema-on-read lets you ship a new field without a migration and keep heterogeneous documents in one collection, which is genuinely valuable for evolving or irregular data.

  What it costs is that every consumer must handle every historical shape forever, and there is no single place to look up what a record contains — the schema lives implicitly in the code that reads it, and nothing tells you when a writer stops emitting a field. Mature teams usually reintroduce enforcement anyway, as document validators, contracts or a typed layer in the application.

  </details>

- **NICE** — The polyglot answer and its cost

  <details><summary><strong>Answer</strong></summary>

  Using several stores for their strengths is standard: a relational system of record, [Redis](https://redis.io/docs/latest/ "Redis — In-memory data store used as a cache and fast key-value store") for sessions and rate limits, Elasticsearch or OpenSearch for text queries, an object store for blobs, a column store for analytics. The cost is that every additional store adds a synchronization path that can lag or diverge, an operational surface to back up and upgrade, and a failure mode where two stores disagree about the same fact.

  **The rule that keeps it honest is** one system of record per fact and everything else derived from it, so a divergence is always repairable by rebuilding the derived copy — a search index you cannot rebuild from the database is a second source of truth by accident.

  </details>

- **NICE** — NewSQL and distributed SQL as the third answer

  <details><summary><strong>Answer</strong></summary>

  Stores such as CockroachDB, Spanner, TiDB and Vitess-fronted MySQL keep the relational model and SQL while sharding underneath, offering horizontal write scale with real transactions. The cost is coordination: a transaction touching several ranges pays consensus latency, so the model rewards the same locality discipline as NoSQL — keep what changes together in one range.

  They also complicate the operational picture, and single-region latency is usually worse than a single node's. They are the honest answer to "what if I need both", provided you can point at why one primary is not enough.

  </details>

- **OPTIONAL** — Where the categories blur: [JSONB](https://www.postgresql.org/docs/current/datatype-json.html "JSON Binary — PostgreSQL type storing JSON documents in a decomposed binary form that can be indexed"), foreign data wrappers, secondary indexes in document stores

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL stores and indexes **JSONB** documents with [GIN](https://www.postgresql.org/docs/current/gin.html "Generalized Inverted Index — PostgreSQL index type suited to values containing multiple keys, such as arrays or text search"), so it can serve document workloads without giving up transactions or joins; document stores have added secondary indexes, aggregation pipelines and transactions in the other direction. The boundary is now about defaults and operational shape rather than capability, which means "we need a document store because our data is nested" is rarely sufficient on its own.

  **The remaining real differences are** how far the store scales writes horizontally without you doing the sharding, and whether the schema is enforced by default.

  </details>

## 3. Sharding, Partitioning and Replication

**Why it comes up:** three words often used interchangeably that solve three different problems — precision here is the whole point of the question.

- **MUST** — The three, distinguished precisely: partitioning splits a table, sharding splits across nodes, replication copies

  <details><summary><strong>Answer</strong></summary>

  Partitioning splits one logical table into physical pieces inside one database, so the planner can skip pieces and maintenance can work on one at a time; it addresses table size and manageability, not machine capacity. Sharding distributes data across independent nodes by a shard key, so both storage and write throughput scale with node count; it is the only one of the three that scales writes. **Replication copies** the same data to more nodes, which buys read capacity, availability and failover, and never write capacity — the primary still takes every write.

  **The tell of a shallow answer is** treating replication as a scaling strategy for a write-heavy system; the tell of a good one is naming which bottleneck each addresses.

  </details>

- **MUST** — Choosing a shard or partition key, and the failure modes of a bad one

  <details><summary><strong>Answer</strong></summary>

  The key must spread load evenly and keep together what is queried and transacted together — those two pull against each other, and the choice is where you resolve them. Bad keys fail in recognizable ways: a monotonically increasing key sends every insert to one shard, a low-cardinality key leaves most shards idle, and a popular customer or celebrity makes one partition hot regardless of hashing.

  A key that ignores the access pattern is just as bad in the other direction, because every query becomes a scatter-gather across all shards and the slowest one sets the latency. Composite and salted keys are the usual repairs, and the costly truth is that resharding a live system is one of the hardest migrations there is, so the key deserves more thought than the rest of the schema combined.

  </details>

- **MUST** — Range, hash and list partitioning, and what each is good for

  <details><summary><strong>Answer</strong></summary>

  **Range** partitioning splits on ordered values — usually time — which makes pruning trivial for time-bounded queries and makes retention a matter of detaching a partition rather than a mass delete; its weakness is that the newest range takes all the writes. Hash partitioning spreads writes evenly and is the right default when there is no natural order, at the cost of losing range pruning entirely.

  **List partitioning** splits on a discrete set such as region or tenant, which is useful when the sets differ in policy, retention or residency. In PostgreSQL these are declarative, and the practical wins are constraint exclusion during planning, cheaper autovacuum per partition, and `DETACH PARTITION` as an instant archive.

  </details>

- **MUST** — Replication mechanics: synchronous and asynchronous, physical and logical, and what replica lag actually breaks

  <details><summary><strong>Answer</strong></summary>

  **Asynchronous** replication acknowledges the commit on the primary and ships the log afterwards, so a failover can lose the last transactions; **synchronous** replication waits for a replica to acknowledge, which removes that loss and adds the round trip to every commit — and, if configured strictly with one replica, makes that replica's health a write dependency. **Physical** replication ships the write-ahead log byte for byte, giving an identical copy at the same major version; logical replication ships decoded row changes, which allows selective tables, cross-version replication and near-zero-downtime upgrades, at the cost of not replicating schema changes and needing primary keys.

  Lag is what breaks applications: read-your-own-writes fails when a user writes on the primary and immediately reads a stale replica. The fixes are routing the reads that need it back to the primary, waiting on a log position, or accepting staleness explicitly per endpoint.

  </details>

- **MUST** — Single-primary, multi-primary and leaderless, and what each demands of the application

  <details><summary><strong>Answer</strong></summary>

  **Single-primary** is the default because it makes write conflicts impossible by construction — one writer orders everything — and its costs are the write ceiling of one machine and a failover window. **Multi-primary** accepts writes anywhere and therefore requires a conflict-resolution rule; last-write-wins is the usual choice and it silently discards data, which is acceptable for a presence flag and not for a shopping cart. Leaderless replication as in Dynamo or Cassandra writes to N replicas and waits for W acknowledgements, reading from R, where R plus W greater than N gives overlap and quorum consistency; the application then handles version conflicts.

  **The judgment being tested is** whether you know that abandoning a single writer moves conflict resolution into your code, not out of the system.

  </details>

- **NICE** — Consistent hashing and rebalancing

  <details><summary><strong>Answer</strong></summary>

  Naive modulo hashing remaps almost every key when node count changes, so adding a node means moving nearly all the data. **Consistent hashing** places nodes and keys on a ring so that adding or removing a node moves only the neighbouring slice, and virtual nodes smooth the imbalance that a small number of physical nodes would otherwise create.

  Many systems instead use a fixed large number of logical partitions assigned to nodes — Kafka partitions, Elasticsearch shards, Redis Cluster hash slots — which makes **rebalancing** a matter of reassigning ownership rather than rehashing. The topic is worth knowing because it explains why partition counts are chosen up front and are painful to change later.

  </details>

- **NICE** — Cross-shard queries, transactions and aggregation

  <details><summary><strong>Answer</strong></summary>

  Once sharded, any query without the shard key becomes scatter-gather: every shard is asked, and tail latency is the maximum over shards rather than the average, so p99 degrades as shard count grows. **Transactions** across shards need two-phase commit or a saga, with the availability and locking costs that implies. The usual mitigations are a secondary index table keyed by the alternative lookup, a search index for ad-hoc queries, and precomputed aggregates for reporting so nobody runs analytics across live shards.

  **Saying this before being asked shows** you understand sharding as a trade rather than an upgrade.

  </details>

- **OPTIONAL** — Vertical partitioning and functional sharding

  <details><summary><strong>Answer</strong></summary>

  **Vertical partitioning** splits a table by column — rarely accessed or very large columns into a side table — which improves cache density for the hot columns; PostgreSQL does some of this automatically through [TOAST](https://www.postgresql.org/docs/current/storage-toast.html "The Oversized-Attribute Storage Technique — Stores oversized column values out of line in a side table, compressed where possible").

  **Functional sharding** puts different tables on different servers by domain, which is often the first real split a system makes and is simpler than key-based sharding, though it caps out quickly and it removes joins between the separated domains. Both are worth naming as cheaper steps to take before horizontal sharding.

  </details>

## 4. The N+1 Problem

**Why it comes up:** it is the cheapest test of whether you have actually debugged a slow endpoint, and the answer reveals how you think about ORMs.

- **MUST** — What it is and why it is invisible in the code

  <details><summary><strong>Answer</strong></summary>

  One query fetches N parent rows and then, for each one, a second query fetches its children — one query plus N, where the loop is usually a plain attribute access in application code rather than anything that looks like a query. It matters because the cost is dominated by round trips, not by work: 200 queries of 0.3 ms each is 60 ms of network and parse overhead for data one query would have returned in 2 ms, and it degrades linearly with result size so it passes tests on ten rows and collapses on a thousand.

  It is invisible precisely because a lazy-loading [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping "Object Relational Mapper — Maps application objects to relational database rows and queries") makes the query look like a field access, which is why it is found with query logs and counts rather than by reading code.

  </details>

- **MUST** — How to fix it: eager loading, a join, or a second batched query

  <details><summary><strong>Answer</strong></summary>

  Three fixes, and the choice matters. A join in one query — [SQLAlchemy](https://www.sqlalchemy.org/ "SQLAlchemy — Python SQL toolkit and ORM that maps objects to relational tables and builds queries")'s `joinedload`, Django's `select_related` — is best for to-one relationships, and bad for to-many because the parent columns are duplicated for every child and the result set explodes. A second query with `WHERE child.parent_id IN (...)` — `selectinload`, `prefetch_related` — is the right default for collections: two queries regardless of N, no row multiplication.

  A `DataLoader`-style batcher is the GraphQL answer, coalescing per-field loads within a request tick. The fix that is not a fix is caching, which hides the round trips at the cost of a staleness problem you did not have before.

  </details>

- **MUST** — How you detect it rather than guess at it

  <details><summary><strong>Answer</strong></summary>

  Count queries per request and assert on the count — a test that fails when an endpoint issues more than a fixed number of queries catches the regression at the commit that introduces it, which no amount of code review does reliably. In development, echo SQL or use a toolbar that shows repeated identical statements with different parameters, which is the visual signature. In production it shows up as an endpoint whose latency scales with page size, and as one statement dominating `pg_stat_statements` by call count rather than by mean time.

  Naming `pg_stat_statements` ordered by calls is the detail that separates having read about the problem from having chased one.

  </details>

- **MUST** — Why it is not exclusively an ORM problem

  <details><summary><strong>Answer</strong></summary>

  **The pattern is** any per-item round trip in a loop: a [REST](https://en.wikipedia.org/wiki/REST "Representational State Transfer — Architectural style for stateless, resource-oriented HTTP APIs") endpoint called once per item, a Redis `GET` per key instead of `MGET`, a per-row call to a microservice, a document store fetch per embedded reference. The general form is that latency is per call and not per byte, so the fix is always to batch.

  **Framing it that way is** stronger than framing it as an ORM defect, because it transfers to the service and cache layers where the same shape costs far more per round trip.

  </details>

- **NICE** — When N+1 is the right choice

  <details><summary><strong>Answer</strong></summary>

  When N is small and bounded, when the children are already cached, or when the join would multiply a wide parent row across thousands of children, several small queries can beat one large one. There is a real symmetric failure — the cartesian explosion from eager-loading two to-many relationships in one join, which produces the product of both collections and is far worse than the N+1 it replaced.

  **The mature answer is** that both extremes are wrong and the choice depends on cardinality, which is measured rather than assumed.

  </details>

- **NICE** — Structural defences

  <details><summary><strong>Answer</strong></summary>

  Configure relationships to raise on unexpected lazy loads — SQLAlchemy's `lazy="raise"` — so an unintended access fails loudly in development instead of silently issuing queries in production. Keep loading strategy at the query site rather than on the model, so each endpoint declares what it needs.

  In GraphQL, batch per request with a loader and set a query-complexity limit, since the client controls the shape and can otherwise request an unbounded fan-out. These are examples of the general rule that the fix which survives is the one that fails loudly, not the one applied by hand at each call site.

  </details>

## Relational Database Topics

## 5. Indexes and PostgreSQL Index Types

**Why it comes up:** it is the highest-yield relational topic there is, and the one where "I add an index" versus "I know what an index costs" is immediately audible.

- **MUST** — What a B-tree index is and why lookups are logarithmic

  <details><summary><strong>Answer</strong></summary>

  A B-tree is a balanced multi-way tree whose internal pages hold separator keys and whose leaves hold the indexed values in sorted order with pointers to the heap rows; depth grows logarithmically, so even a hundred-million-row table is three or four page reads from any key. Because the leaves are sorted and linked, the same structure serves equality, range, prefix, `ORDER BY`, `MIN`/`MAX` and merge joins — which is why it is the default and why the other types are exceptions for specific data shapes.

  **The cost is** that every insert, update of an indexed column, and delete must maintain it, and the index competes with the table for cache memory.

  **The sentence worth having ready is** that an index is a write tax paid to make a read cheap, so an unused index is pure loss — measurable in `pg_stat_user_indexes` as an `idx_scan` of zero.

  </details>

- **MUST** — Composite indexes and column order: the leftmost-prefix rule

  <details><summary><strong>Answer</strong></summary>

  A composite index sorts by the first column, then the second within it, so it can serve any leftmost prefix of its columns and cannot serve a query that skips the first — an index on `(tenant_id, created_at)` supports a filter on `tenant_id`, and a filter on `created_at` alone gets no useful help from it. The practical ordering rule is equality columns first, then the range or sort column last, because once you use a range predicate the columns after it are no longer in usable order for filtering.

  **Getting this wrong is** the most common cause of "we have an index and it is still slow". One well-ordered composite index usually replaces several single-column ones, and fewer, wider indexes are cheaper to maintain than many narrow ones.

  </details>

- **MUST** — Clustered against non-clustered, and why PostgreSQL has no clustered index

  <details><summary><strong>Answer</strong></summary>

  A **clustered** index — the SQL Server and InnoDB model — is the table: the rows are stored in the index's leaf pages in key order, so there is exactly one per table, a lookup by that key needs no second fetch, and secondary indexes must store the clustering key and pay a second traversal to reach the row. PostgreSQL takes the other design: the heap is unordered, every index is secondary and stores a tuple pointer, and so no index is privileged.

  **The consequence is** that `CLUSTER` in PostgreSQL is a one-off physical reordering that new writes immediately begin to undo, not a maintained property, and the relevant runtime measure is the planner's correlation statistic for how well physical order matches an index. This is a favourite question because candidates carry the InnoDB mental model into PostgreSQL and predict the wrong costs.

  </details>

- **MUST** — Covering indexes, index-only scans and the visibility map

  <details><summary><strong>Answer</strong></summary>

  A covering index contains every column a query needs, so the query is answered from the index without touching the table — in PostgreSQL, with `INCLUDE` columns carried in the leaves without affecting sort order or being usable for filtering. The catch is specific to PostgreSQL's [MVCC](https://www.postgresql.org/docs/current/mvcc.html "Multi Version Concurrency Control — Lets readers and writers proceed concurrently by keeping multiple versions of a row"): the index does not record whether a tuple is visible to your snapshot, so an **index-only scan** must consult the **visibility map**, and pages not marked all-visible force a heap fetch anyway.

  That is why an index-only scan degrades on a heavily updated table and why `EXPLAIN ANALYZE` reporting a large "Heap Fetches" count is the sign that the win is not being realized — the fix is usually autovacuum, since vacuum is what sets the visibility map.

  **Naming that chain is** what makes the answer sound like production experience rather than documentation.

  </details>

- **MUST** — PostgreSQL index types and when each earns its place

  <details><summary><strong>Answer</strong></summary>

  B-tree is the default and handles equality, ranges and ordering. Hash serves equality only, is now write-ahead logged and crash-safe, and rarely beats B-tree enough to justify losing range support. GIN is for values containing many keys — full-text vectors, arrays, JSONB — and inverts the containment relation, with expensive updates buffered through a pending list. [GiST](https://www.postgresql.org/docs/current/gist.html "Generalized Search Tree — PostgreSQL index type supporting range and exclusion constraints") is a framework for types with a notion of overlap or distance: geometry, ranges, nearest-neighbour ordering, and exclusion constraints. SP-GiST suits non-balanced partitioned structures such as quadtrees and text prefix trees. [BRIN](https://www.postgresql.org/docs/current/brin.html "Block Range Index — Compact PostgreSQL index type suited to large, sequentially correlated tables") stores min/max summaries per block range, so it is tiny and only works when physical order correlates with the value — an append-only timestamp column is its home, and it is useless on shuffled data.

  **The judgment being tested is** knowing that GIN and BRIN are answers to specific data shapes, not general upgrades.

  </details>

- **MUST** — Partial and expression indexes

  <details><summary><strong>Answer</strong></summary>

  A **partial** index indexes only the rows matching a predicate — `WHERE status = 'pending'` — which is dramatically smaller and cheaper to maintain when the interesting rows are a small fraction, and it is the correct tool for a queue table where the backlog is thousands of rows in a table of millions. The condition is that the planner can only use it when it can prove the query's predicate implies the index's.

  An expression index stores the result of a deterministic expression, `lower(email)` or a JSONB path extraction, and is required for the query to use an index at all when the predicate wraps the column in a function. Both also give a neat trick: a unique partial index enforces "at most one active row per owner", an invariant that has no plain constraint form.

  </details>

- **MUST** — Why the planner declines an index

  <details><summary><strong>Answer</strong></summary>

  Usually for a good reason: the predicate is not sargable because the column is wrapped in a function or has an implicit cast, the estimated selectivity is high enough that a sequential scan with cheaper sequential I/O wins, the statistics are stale so the estimate is wrong, the collation or operator class does not match the query's operator, or the leading column of a composite index is not constrained. The way to answer is procedural rather than declarative — run `EXPLAIN ANALYZE` and compare estimated to actual rows, since a large divergence points at statistics, and a close match with a sequential scan means the planner is probably right.

  Adding an index to a query the planner will not use is the visible symptom of skipping that step.

  </details>

- **NICE** — Index maintenance: bloat, `REINDEX CONCURRENTLY`, `CREATE INDEX CONCURRENTLY`, unused and duplicate indexes

  <details><summary><strong>Answer</strong></summary>

  `CREATE INDEX` takes a lock that blocks writes for its duration, so on a live table the concurrent form is the only acceptable one — it takes two passes, cannot run inside a transaction, and can leave an invalid index behind on failure that must be dropped and retried. Indexes **bloat** under heavy update churn as dead entries accumulate, and `REINDEX CONCURRENTLY` rebuilds them without a long lock.

  Housekeeping is a real source of easy wins: indexes with zero scans since the last statistics reset, and indexes whose columns are the leftmost prefix of a wider one, are both write tax paid for nothing. Every index also slows `COPY`-style bulk loads, which is why dropping and recreating them around a large load is standard.

  </details>

- **NICE** — Multicolumn statistics, and correlated columns

  <details><summary><strong>Answer</strong></summary>

  The planner assumes columns are independent, so for correlated predicates — city and postcode, or status and type — it multiplies selectivities and underestimates the row count badly, which cascades into a nested loop chosen where a hash join was needed. `CREATE STATISTICS` with `ndistinct` and `dependencies` teaches it the correlation. This is worth knowing because it is a class of slow query that no additional index fixes, and recognizing it — estimate off by orders of magnitude on a two-column filter — is a distinctive diagnostic.

  </details>

- **OPTIONAL** — Bloom, hash-join-friendly designs and index-organized alternatives

  <details><summary><strong>Answer</strong></summary>

  The `bloom` extension gives a compact index that serves equality on any subset of many columns with a false-positive rate, which suits wide fact tables queried on unpredictable column combinations where individual indexes would be too numerous. Covering indexes plus partitioning often outperform exotic index types in practice, so the reason to know these is to recognize when a workload has outgrown the defaults rather than to reach for them early.

  </details>

## 6. Transaction Isolation Levels

**Why it comes up:** it is where "we use transactions" gets tested against "you know what your transactions do not prevent".

- **MUST** — The four levels and the three classic anomalies

  <details><summary><strong>Answer</strong></summary>

  Read uncommitted permits dirty reads — seeing another transaction's uncommitted writes; read committed prevents that but permits non-repeatable reads, where the same row read twice differs because another transaction committed in between; repeatable read prevents that but classically permits phantoms, where a range query returns new rows on re-execution; serializable prevents all three and guarantees a result equivalent to some serial order. The levels are defined as which anomalies are prohibited, not as which mechanism is used, which is why implementations differ so much underneath.

  **The important framing is** that the level you choose is a statement about which concurrency bugs your application is prepared to handle itself.

  </details>

- **MUST** — What PostgreSQL actually does, which differs from the standard

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL has three distinct levels, not four: read uncommitted behaves as read committed because MVCC never exposes uncommitted tuples. The default is read committed, where each statement sees a snapshot taken at statement start — so two queries in the same transaction can legitimately see different data. Repeatable read takes one snapshot for the whole transaction and, unlike the standard's minimum, also prevents phantoms because the snapshot is consistent; instead of blocking it raises a serialization failure when a concurrent update conflicts. Serializable adds serializable snapshot isolation, which monitors read/write dependencies and aborts a transaction that would create a cycle.

  Knowing that repeatable read and serializable can both abort with `40001` — and that the application must therefore retry — is the practically important half of this answer.

  </details>

- **MUST** — Write skew: the anomaly that survives repeatable read

  <details><summary><strong>Answer</strong></summary>

  Two transactions each read an overlapping set, each check an invariant that still holds, and each write a different row — so no write conflicts, both commit, and the invariant is broken. The canonical case is the on-call rule that at least one doctor must be on duty: two doctors each see two on duty, each sign off, and the shift ends empty. Snapshot isolation cannot catch it because the transactions never touch the same row, which is exactly why serializable exists — it tracks the read/write dependency and aborts one. The alternatives without serializable are explicit locking with `SELECT ... FOR UPDATE` on the rows the decision reads, or materializing the conflict into a row or constraint so the write actually collides.

  Being able to give this example unprompted is one of the strongest signals in the whole topic.

  </details>

- **MUST** — Optimistic and pessimistic concurrency, and lost updates

  <details><summary><strong>Answer</strong></summary>

  A **lost update** is read-modify-write from two transactions where one overwrites the other's change; read committed does not prevent it, because both reads succeed before either write. Pessimistic control takes a row lock at read time with `SELECT ... FOR UPDATE`, which serializes the two and costs contention and holding-time discipline.

  **Optimistic** control carries a version column and writes with `WHERE version = :seen`, retrying when zero rows were updated — cheaper under low contention and better across a user think-time gap, where holding a database lock would be unacceptable. Atomic statements such as `UPDATE balance = balance - 10` avoid the problem entirely when the new value is a function of the old, which is the simplest fix and the one most often overlooked.

  </details>

- **MUST** — Retry as a required part of the design, not an afterthought

  <details><summary><strong>Answer</strong></summary>

  At repeatable read or serializable, the database is entitled to abort your transaction with a serialization failure at any time, so a **retry** loop is part of the contract rather than defensive coding. That loop needs a bounded attempt count, backoff with jitter, and — crucially — a transaction body free of side effects that cannot be repeated, meaning no email sent and no payment charged before commit.

  It also constrains transaction size: long transactions have a larger conflict window and hurt more when they abort. If a system runs at serializable without a retry path, it does not run at serializable, it just fails occasionally.

  </details>

- **NICE** — How MySQL/InnoDB differs, since the comparison is often asked

  <details><summary><strong>Answer</strong></summary>

  InnoDB defaults to repeatable read and prevents phantoms with next-key locks, which lock the gaps between index entries — a locking approach where PostgreSQL uses snapshots, so InnoDB blocks where PostgreSQL aborts, and deadlocks are the more common symptom. InnoDB's repeatable read also has the well-known quirk that a plain `SELECT` reads a consistent snapshot while `SELECT ... FOR UPDATE` and updates read the latest committed row, so a read-modify-write inside a transaction can see two different worlds.

  **Being able to name that difference is** a good demonstration that you have used both rather than transferring one store's behaviour to another.

  </details>

- **NICE** — The cost of higher levels, and where to apply them

  <details><summary><strong>Answer</strong></summary>

  Serializable in PostgreSQL is not lock-based, so its cost is predicate-tracking memory and an abort rate that rises with conflict rate and transaction length rather than raw slowdown — for many workloads it is affordable. The pragmatic pattern is per-transaction rather than global: run the whole system at read committed and raise the level only for the few transactions with cross-row invariants, since the level is a per-transaction setting.

  That framing beats both "we always use serializable" and "isolation is a database concern" because it puts the cost where the invariant is.

  </details>

- **OPTIONAL** — Advisory locks and application-level serialization

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL **advisory locks** let the application take a named lock unrelated to any row, which is useful for serializing a job, a leader election or a cross-row critical section with no obvious row to lock. They are session or transaction scoped, and the session-scoped form leaks if the code path that releases it is skipped — the transaction-scoped variant is the safer default.

  They are worth knowing precisely because they solve the case where the thing to protect is not a row.

  </details>

## 7. MVCC

**Why it comes up:** it is the mechanism behind isolation, vacuum, bloat and long-transaction incidents, so it makes several other answers coherent.

- **MUST** — The core idea: writers do not block readers because updates create new versions

  <details><summary><strong>Answer</strong></summary>

  Under multi-version concurrency control an update does not overwrite a row; it writes a new tuple version and marks the old one as ending at the current transaction, so a reader with an older snapshot still finds a valid version to read. The consequence is the property people quote — readers never block writers and writers never block readers — and the price is that the table now holds versions nobody can see, which must be reclaimed later.

  Understanding it as a space-and-maintenance trade rather than a free lunch is what connects it to vacuum, bloat and the visibility map, and explains why PostgreSQL's `UPDATE` is closer in cost to a delete plus insert than to an in-place write.

  </details>

- **MUST** — How visibility is determined: `xmin`, `xmax`, snapshots and the transaction ID

  <details><summary><strong>Answer</strong></summary>

  Every tuple carries `xmin`, the transaction that created it, and `xmax`, the transaction that deleted or superseded it. A **snapshot** records which **transaction IDs** had committed at the moment it was taken plus the set still in progress, and a tuple is visible if its `xmin` is committed and visible to that snapshot and its `xmax` is not.

  Read committed takes a fresh snapshot per statement, repeatable read one per transaction — the whole isolation-level difference reduces to when the snapshot is taken. The commit log records transaction outcomes, and hint bits on the tuple cache that result to avoid re-checking, which is why the first read after a bulk write can be unexpectedly expensive and can dirty pages.

  </details>

- **MUST** — Dead tuples, bloat and why a long-running transaction is the classic incident

  <details><summary><strong>Answer</strong></summary>

  A version becomes dead once no possible snapshot can see it, and only then may vacuum reclaim it — so the oldest snapshot in the system pins every version newer than it, across all tables. That is why one forgotten `idle in transaction` session, a long analytics query, an abandoned replication slot, or a stale prepared transaction causes table and index **bloat** everywhere, slows every scan, and eventually threatens wraparound.

  **The tell is** `pg_stat_activity` showing an old `xact_start` with `state = 'idle in transaction'`, and the standard defences are `idle_in_transaction_session_timeout`, `statement_timeout`, and monitoring the age of the oldest transaction and the size of replication slot backlogs.

  This is the single most common serious PostgreSQL production incident, so having the diagnostic sequence ready is worth more than the theory.

  </details>

- **MUST** — Heap-only tuple updates and the fillfactor lever

  <details><summary><strong>Answer</strong></summary>

  When an update changes no indexed column and the new version fits on the same page, PostgreSQL writes a heap-only tuple: the new version is chained from the old within the page, and no index entry is created, which avoids touching every index and lets the space be reclaimed cheaply by page pruning without a full vacuum. Lowering `fillfactor` on an update-heavy table leaves free space per page to keep that path available.

  **The corollary is** a design instruction: indexing a frequently updated column costs more than the index's own maintenance, because it forfeits heap-only updates for every write to that table.

  </details>

- **MUST** — Transaction ID wraparound and freezing

  <details><summary><strong>Answer</strong></summary>

  Transaction IDs are 32-bit and compared circularly, so a tuple older than roughly two billion transactions would appear to be in the future and vanish. Vacuum prevents that by **freezing** old tuples, marking them visible to everyone regardless of transaction ID.

  If freezing falls behind — commonly because autovacuum is being blocked by a long transaction or is too conservatively tuned — PostgreSQL warns, then refuses new transactions and demands a single-user vacuum, which is a full outage. Monitoring `age(datfrozenxid)` against `autovacuum_freeze_max_age` is the preventative measure, and mentioning it signals operational rather than theoretical familiarity.

  </details>

- **NICE** — Undo-log MVCC as the alternative, and the trade

  <details><summary><strong>Answer</strong></summary>

  InnoDB and Oracle keep the current row in place and push old versions to an undo log, so tables do not bloat with dead versions and there is no vacuum — but rollback is expensive, long readers can exhaust undo space and fail with a snapshot-too-old error, and readers reconstructing an old version must walk the undo chain. PostgreSQL's heap approach makes rollback nearly free and reads of the current version direct, at the cost of vacuum and bloat management.

  Neither is strictly better; naming it as a placement of the same cost — in maintenance or in read reconstruction — is the answer an interviewer is listening for.

  </details>

- **OPTIONAL** — What MVCC does not give you

  <details><summary><strong>Answer</strong></summary>

  MVCC gives snapshot reads, not serializability: write skew survives it, uniqueness still needs a real constraint and blocking, and `SELECT ... FOR UPDATE` still blocks because locking is a separate mechanism layered on top. Counting rows is not free either, since visibility is per tuple, which is why PostgreSQL has no O(1) `COUNT(*)`.

  Knowing the boundary keeps you from assuming a snapshot protects an invariant it does not.

  </details>

## 8. VACUUM, VACUUM FULL and Autovacuum

**Why it comes up:** it is the operational consequence of MVCC, and the difference between the two vacuum forms is a one-question test of whether you have run PostgreSQL in production.

- **MUST** — What plain `VACUUM` does, and what it does not

  <details><summary><strong>Answer</strong></summary>

  Plain `VACUUM` scans the table, removes dead tuples and their index entries, and marks the freed space reusable by future inserts into the same table — it does not return space to the operating system and the file does not shrink. It also updates the visibility map, which is what enables index-only scans, and freezes old transaction IDs to hold off wraparound.

  It takes only a lock that permits concurrent reads and writes, so it is safe to run at any time. The steady-state goal is not zero dead tuples but a stable table size, where reclaimed space is reused as fast as new dead tuples are created.

  </details>

- **MUST** — `VACUUM FULL`, and why it is a last resort

  <details><summary><strong>Answer</strong></summary>

  `VACUUM FULL` rewrites the entire table into a new file with no dead space and rebuilds its indexes, so it does return space to the operating system — while holding an `ACCESS EXCLUSIVE` lock that blocks every read and write for the duration, and needing free disk space for a full second copy. On a large table that is an outage, and it is the wrong reflex for routine bloat, which is a sign that autovacuum is not keeping up rather than a condition to clean up by hand.

  When space genuinely must be returned, `pg_repack` or a rewrite into a new table does the same job with only brief locking, and the durable fix is tuning autovacuum or removing whatever is holding an old snapshot.

  </details>

- **MUST** — Autovacuum: what triggers it and the tuning that actually matters

  <details><summary><strong>Answer</strong></summary>

  **Autovacuum** wakes periodically and vacuums a table when its estimated dead tuples exceed a threshold plus a scale factor of the table size, and analyzes it on a similar rule for statistics. The default scale factor of 0.2 is the classic problem at scale: on a table of a hundred million rows it waits for twenty million dead tuples, so large hot tables need a much smaller per-table scale factor, set with `ALTER TABLE ... SET`.

  The other lever is throughput — the cost-delay settings that deliberately throttle vacuum I/O are conservative for modern storage, and raising the cost limit is usually what lets autovacuum keep up. The signals to watch are `pg_stat_user_tables` for `n_dead_tup` and `last_autovacuum`, and workers spending their time on a few huge tables while small hot tables starve.

  </details>

- **MUST** — What blocks vacuum from reclaiming anything

  <details><summary><strong>Answer</strong></summary>

  Vacuum can only remove versions older than the oldest snapshot anyone might still need, so anything that pins an old transaction horizon stops reclamation across the database: a long-running or idle-in-transaction session, an unused or lagging replication slot, `hot_standby_feedback` from a replica running long queries, and orphaned prepared transactions. The diagnostic is that dead tuples keep climbing while autovacuum runs and completes — vacuum is working and simply not permitted to free anything.

  **Naming the four causes in order is** a strong answer because it is exactly the checklist an on-call engineer runs.

  </details>

- **NICE** — `ANALYZE` and why it is a separate concern

  <details><summary><strong>Answer</strong></summary>

  `ANALYZE` samples the table to refresh the planner's statistics — row counts, most-common values, histograms, null fraction and physical correlation — and has nothing to do with reclaiming space, even though autovacuum runs both. Stale statistics produce bad plans rather than bloat, and the classic case is a bulk load or a large data change followed immediately by queries, where an explicit `ANALYZE` is the fix.

  Statistics are also not replicated as such and must exist on a replica used for queries, and a `pg_upgrade` leaves them empty, which surprises teams the morning after an upgrade.

  </details>

- **NICE** — Index bloat and the visibility-map connection

  <details><summary><strong>Answer</strong></summary>

  Indexes bloat by the same mechanism, and a bloated index is a larger tree with worse cache density, so scans slow even when the plan is unchanged; `REINDEX CONCURRENTLY` fixes it without a long lock. The subtler cost is the visibility map: pages containing dead tuples are not all-visible, so index-only scans fall back to heap fetches, and a query that was fast becomes slow with no change in plan shape.

  That is the concrete answer to "why does vacuum affect read performance" — it is not just space, it is the ability to skip the heap.

  </details>

- **OPTIONAL** — Partitioning and `TRUNCATE` as a way to avoid vacuum entirely

  <details><summary><strong>Answer</strong></summary>

  Deleting a hundred million rows creates a hundred million dead tuples and a vacuum problem; detaching or dropping a partition frees the space instantly with no vacuum at all, and `TRUNCATE` does the same for a whole table. Designing retention around partition boundaries therefore removes a whole class of maintenance work rather than tuning it.

  It is the cheapest structural answer to a bloat question and worth giving before the tuning answer.

  </details>

## 9. EXPLAIN and EXPLAIN ANALYZE

**Why it comes up:** it is the practical half of query performance, and it separates people who read plans from people who guess and add indexes.

- **MUST** — The difference: `EXPLAIN` estimates, `EXPLAIN ANALYZE` executes

  <details><summary><strong>Answer</strong></summary>

  `EXPLAIN` prints the plan the planner chose with its estimated costs and row counts, without running the query — cheap, safe, and entirely a prediction. `EXPLAIN ANALYZE` runs the query and adds actual times, actual row counts and loop counts, which is the only way to see where the estimate was wrong. Two consequences matter in practice: it really executes, so an `EXPLAIN ANALYZE` of an `UPDATE` or `DELETE` changes data unless you wrap it in a transaction and roll back; and instrumentation adds measurable overhead on plans with many rows, so the reported total can exceed the query's normal runtime.

  **The habit worth stating is** that costs are arbitrary units for comparing plans, not milliseconds.

  </details>

- **MUST** — Reading a plan: estimated against actual rows is the first thing to look at

  <details><summary><strong>Answer</strong></summary>

  Read the tree from the innermost nodes outward, and for each node compare `rows` estimated with `rows` actual, remembering that per-node numbers are per loop, so the true total is rows times loops. A large divergence — orders of magnitude — is the root cause more often than the plan shape itself, because a bad estimate is what made the planner choose a nested loop over a hash join or skip an index. Where estimates are close and the query is still slow, the problem is genuinely resource-bound or a missing index, which is a different fix.

  Saying "I look at estimated versus actual first" is the single most credible sentence in this topic.

  </details>

- **MUST** — The options that make a plan diagnosable: `BUFFERS`, `ANALYZE`, `VERBOSE`, `SETTINGS`, `FORMAT`

  <details><summary><strong>Answer</strong></summary>

  `BUFFERS` is the one people omit and the one that matters most: it reports shared hits, reads, dirtied and written blocks per node, which turns "slow" into "reading 400 MB from disk" or "cache-resident and CPU-bound", and it distinguishes a genuinely expensive node from a cold cache. `VERBOSE` shows output columns and schema-qualified names, `SETTINGS` shows non-default planner parameters that explain an odd choice, and `FORMAT JSON` is what tooling and visualizers consume. `WAL` reports write-ahead log volume for write statements. The standard incantation to have ready is `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)`.

  </details>

- **MUST** — Node types and what they tell you: scans, joins, sorts, aggregates

  <details><summary><strong>Answer</strong></summary>

  Sequential **scan** reads the whole table and is correct for a large fraction of rows; index scan walks the index and fetches heap rows, good for selective predicates; bitmap heap scan sits between them, collecting tuple pointers and visiting heap pages in physical order, which is what the planner picks for a medium selectivity or when combining several indexes. Nested loop is right when the outer side is tiny and the inner is indexed, and catastrophic when the outer row estimate is wrong; hash join builds a hash table on the smaller side and suits large unsorted joins; merge join needs both sides sorted and pairs well with index order. A sort spilling to disk, a hash **aggregate** exceeding its memory, or a materialize node appearing all point at `work_mem`.

  Naming the node and the condition under which it is the right choice is what a good answer does, rather than labelling nodes good or bad.

  </details>

- **MUST** — Turning a plan into a fix

  <details><summary><strong>Answer</strong></summary>

  The chain is: find the node where actual time or rows first explodes, decide whether the cause is a wrong estimate or genuine work, and act accordingly — stale statistics get `ANALYZE` or a higher statistics target, correlated columns get extended statistics, a non-sargable predicate gets rewritten or an expression index, a selective filter with no index gets one, a disk sort gets more `work_mem` or an index providing the order, and a plan that is simply doing too much gets a rewrite or a precomputed aggregate. What you avoid is tuning planner cost constants globally to force a plan, which fixes one query and destabilizes the rest.

  Ending with "then re-measure with the same plan captured" closes the loop honestly.

  </details>

- **NICE** — Why the plan differs in production from your laptop

  <details><summary><strong>Answer</strong></summary>

  Data volume, statistics, `work_mem`, `effective_cache_size`, parallel worker settings and cache warmth all differ, and the planner is cost-based, so a different cost model produces a different plan on identical SQL. Prepared statements add another cause: after five executions PostgreSQL may switch to a generic plan that ignores your specific parameters, which is how a query that is fast in testing becomes slow for one skewed parameter value.

  Testing plans on a restore with production-scale statistics, and knowing `plan_cache_mode` exists, are the two things that prevent this surprise.

  </details>

- **NICE** — `pg_stat_statements` as the entry point

  <details><summary><strong>Answer</strong></summary>

  You do not start from a plan, you start from finding which query to explain: `pg_stat_statements` aggregates normalized statements by total time, mean time and call count, and the ordering you choose reveals different problems — total time finds the real load, mean time finds the slow outliers, call count finds N+1. Auto-explain can capture plans for statements exceeding a duration, which is the way to catch a plan that only misbehaves in production with particular parameters.

  Mentioning that the top query by total time is usually a fast query called constantly is a useful, slightly counter-intuitive detail.

  </details>

- **OPTIONAL** — Reading the [JSON](https://www.json.org/json-en.html "JavaScript Object Notation — Lightweight text format for structured data exchange") and visual plan tools

  <details><summary><strong>Answer</strong></summary>

  `FORMAT JSON` output feeds visualizers that show per-node time share and estimate error graphically, which makes a fifty-node plan tractable and is the practical answer for deeply nested queries. They change nothing analytically — the same estimated-versus-actual reasoning applies — but they shorten the search for the node that matters.

  </details>

## 10. The PostgreSQL Query Planner

**Why it comes up:** understanding the planner is what makes index and rewrite decisions predictable rather than trial and error.

- **MUST** — What the planner is: cost-based plan selection, not rule-based

  <details><summary><strong>Answer</strong></summary>

  The pipeline is parse, rewrite — where views and rules are expanded — plan, and execute. The planner enumerates candidate plans for the query, estimates a cost for each from table statistics and cost constants, and picks the cheapest; there is no fixed rule saying an index beats a scan. Cost is an abstract number built from estimated page reads, sequential and random, plus per-tuple and per-operator CPU costs, so it is comparable between plans and meaningless as a duration.

  **The practical consequence is** that the planner's decisions are only as good as its row estimates, which is why almost every planner problem is really a statistics problem.

  </details>

- **MUST** — Statistics: what `ANALYZE` collects and how selectivity is estimated

  <details><summary><strong>Answer</strong></summary>

  `ANALYZE` samples rows and stores, per column, the fraction of nulls, the most common values with their frequencies, a histogram of the remaining distribution, the number of distinct values, and the correlation between logical order and physical order. Selectivity for a predicate comes from the most-common-value list if the constant is in it and from the histogram otherwise, and the estimated row count is selectivity times the table's estimated size.

  Skewed columns need a higher `default_statistics_target` — or a per-column target — so the most-common-value list is long enough to cover the skew. Correlation is what makes an index scan look cheap or expensive, because it predicts whether an index scan's heap fetches will be sequential or random.

  </details>

- **MUST** — Join order, join methods and why the search is bounded

  <details><summary><strong>Answer</strong></summary>

  The planner chooses both the **join method** per pair and the order of joins, and the number of orderings grows factorially, so beyond `geqo_threshold` — twelve relations by default — it switches from exhaustive dynamic programming to a genetic algorithm that finds a good plan rather than the best one. That is why very wide queries sometimes get an unstable plan, and why decomposing a twenty-table query helps.

  Join method selection follows the estimates: nested loop for a small outer side with an indexed inner, hash join for large unsorted inputs with enough `work_mem`, merge join when inputs are already ordered. An error in a leaf estimate propagates upward and is amplified at every join, which is why the deepest wrong estimate is the one to fix.

  </details>

- **MUST** — The cost constants and memory settings that shape plans

  <details><summary><strong>Answer</strong></summary>

  `random_page_cost` against `seq_page_cost` encodes how much more expensive a random read is; the default 4.0 reflects spinning disks, and on SSDs something between 1.1 and 2.0 is closer to reality and is the most common legitimate global tuning change — leaving it at 4.0 biases the planner away from index scans. `effective_cache_size` tells the planner how much memory the operating system is likely caching, which makes repeated index access look cheaper. `work_mem` is per sort or hash node per parallel worker, not per query, so a generous value multiplied across a complex parallel plan can exhaust memory — raising it per session for a known heavy query is safer than raising it globally. `cpu_tuple_cost` and friends are rarely worth touching.

  </details>

- **NICE** — Planner-visible rewrites: predicate pushdown, subquery flattening, partition pruning, join removal

  <details><summary><strong>Answer</strong></summary>

  Before costing, the query is transformed: simple views and subqueries are pulled up into the parent query, predicates are pushed down toward the scans, partitions are pruned by constraint exclusion at plan time or at execution time for parameters, and a left join whose columns are unused and whose key is unique can be removed entirely. Knowing which rewrites happen explains why a nested view is often free while a subquery with a `LIMIT`, a volatile function, or a window function forms an optimization fence the planner cannot see through.

  That distinction — which constructs block pushdown — is the practically useful part.

  </details>

- **NICE** — Parallel query and when it does not happen

  <details><summary><strong>Answer</strong></summary>

  The planner may add a gather node with parallel workers for large scans, hash joins and aggregates, and it only does so when the table exceeds `min_parallel_table_scan_size` and the estimated saving outweighs the worker startup cost. Parallelism is disabled for queries using unsafe functions, for cursors, for `FOR UPDATE`, and inside some contexts, which surprises people who expect it.

  Workers are also capped globally, so a busy system may plan parallel and run with fewer workers than planned — visible in `EXPLAIN ANALYZE` as workers planned against workers launched.

  </details>

- **OPTIONAL** — Forcing a plan and why to avoid it

  <details><summary><strong>Answer</strong></summary>

  The `enable_*` settings are diagnostic tools, not production configuration: switching one off is how you ask the planner what its second choice was and what it estimated the difference to be. `pg_hint_plan` provides real hints if you truly need them, but a pinned plan is a plan that will be wrong after the data changes, which is exactly the failure the cost model exists to avoid. Fix the estimate, not the choice.

  </details>

## 11. Normal Forms, Normalization and Denormalization

**Why it comes up:** it tests whether you can state the forms precisely and still know when to break them on purpose.

- **MUST** — 1NF, 2NF, 3NF stated precisely

  <details><summary><strong>Answer</strong></summary>

  First normal form: every attribute holds a single atomic value, with no repeating groups and no comma-separated lists in a column. Second normal form: 1NF, plus every non-key attribute depends on the whole primary key, which only bites when the key is composite — a partial dependency means the attribute belongs in a table keyed by that part. Third normal form: 2NF, plus no non-key attribute depends on another non-key attribute, so a transitive dependency such as postcode determining city moves to its own table.

  The one-line version worth memorizing is that every non-key attribute must depend on the key, the whole key, and nothing but the key.

  </details>

- **MUST** — What normalization actually buys, and what it costs

  <details><summary><strong>Answer</strong></summary>

  It buys one place per fact, which removes update anomalies — a value changed in one row and not another cannot happen if it exists only once — along with insert and delete anomalies where facts can only be recorded or are accidentally destroyed alongside other data. It also makes constraints expressible, since a foreign key can enforce what a duplicated string cannot.

  **The cost is** joins at read time and more tables to reason about, which is a real cost at scale but a much smaller one than people assume, because a join on indexed keys is cheap and the planner is good at it. The framing that lands well is that normalization is about correctness under change, and denormalization is about read cost — so they are answers to different questions.

  </details>

- **MUST** — When to denormalize deliberately, and how to keep it honest

  <details><summary><strong>Answer</strong></summary>

  Denormalize when a measured read path cannot afford the join and the duplicated value is either immutable or cheap to keep in step — a stored order total, a cached counter, a copy of the price at time of purchase. The last case is not really denormalization at all, and it is worth saying so: the price on an order line is a different fact from the current product price, so storing it is correct modelling rather than a shortcut.

  Where the copy genuinely duplicates a live fact, the discipline is to name the mechanism that maintains it — trigger, materialized view, application write path, or a periodic reconciliation job — and to accept that it can drift. The unacceptable version is denormalizing by default, with no measurement and no maintenance story.

  </details>

- **MUST** — [BCNF](https://en.wikipedia.org/wiki/Boyce%E2%80%93Codd_normal_form "Boyce-Codd Normal Form — Normal form requiring every determinant to be a candidate key"), and 4NF/5NF in one sentence each

  <details><summary><strong>Answer</strong></summary>

  Boyce-Codd normal form strengthens 3NF: every determinant must be a candidate key, which catches the case where a non-key attribute determines part of a key and 3NF does not. Fourth normal form removes independent multi-valued facts stored in the same table, which otherwise force a cartesian product of unrelated values — the classic example is skills and languages for one person in one table. Fifth normal form addresses join dependencies that only decompose into three or more tables.

  **In practice** 3NF or BCNF is where design stops, and the higher forms matter as vocabulary and as an explanation for why one specific table feels wrong.

  </details>

- **NICE** — Star schemas and why analytics normalizes differently

  <details><summary><strong>Answer</strong></summary>

  Analytical models use a fact table with foreign keys to denormalized dimension tables, because the workload is append-mostly and read-heavy with wide aggregations, so update anomalies barely arise while join reduction pays on every query. A snowflake schema normalizes the dimensions and trades read simplicity for less duplication.

  **The generalizable point is** that normalization level should follow the write/read ratio and the mutability of the data, which is why the same company runs a normalized [OLTP](https://en.wikipedia.org/wiki/Online_transaction_processing "Online Transaction Processing — Workload of many short read and write transactions serving an application") schema and a denormalized warehouse over the same facts.

  </details>

- **NICE** — Modelling patterns the forms do not settle

  <details><summary><strong>Answer</strong></summary>

  Surrogate against natural keys, how to represent inheritance — single table, table per class, or a shared table with a type discriminator — soft deletion, temporal and slowly changing dimensions, and entity-attribute-value tables are all decisions normalization does not decide for you. Entity-attribute-value in particular is the trap: it looks like flexibility and gives up types, constraints, indexing and readable queries all at once, and a JSONB column with a validator is usually the better version of the same wish.

  **Recognizing that the normal forms are** about functional dependencies and not about these choices is itself a mark of experience.

  </details>

- **OPTIONAL** — Constraints as the enforcement half of normalization

  <details><summary><strong>Answer</strong></summary>

  A normalized design without keys and foreign keys is only a convention. The forms describe where facts live; **constraints** are what stops them being duplicated or orphaned at runtime, which is why the two topics belong together and why "we normalize but enforce referential integrity in the application" is a contradiction worth naming.

  </details>

## 12. Performance for Read and for Write Workloads

**Why it comes up:** it is the synthesis question, and a good answer is a sequence of measurements rather than a list of tips.

- **MUST** — Start from measurement: find the query before tuning anything

  <details><summary><strong>Answer</strong></summary>

  The order is find the expensive statement, explain it, fix the specific cause, re-measure. `pg_stat_statements` ranks by total time, mean time and calls; the top entry by total time is usually a fast query executed constantly, which is a different fix from a slow one executed rarely. Only after that does an index, a rewrite or a configuration change make sense, because every one of those has a cost and applying it to the wrong query pays the cost for nothing.

  Saying explicitly that you would not add an index before seeing a plan is the strongest opening this topic has.

  </details>

- **MUST** — Read-side levers, in order of usual payoff

  <details><summary><strong>Answer</strong></summary>

  Correct indexes, including composite and partial ones matching the real predicates; a rewrite that removes non-sargable predicates, unnecessary `DISTINCT`, or `SELECT *` on wide rows; keyset pagination instead of large `OFFSET`, since `OFFSET 100000` reads and discards a hundred thousand rows; precomputation with a materialized view or a summary table for aggregates that do not need to be live; a cache in front for genuinely hot, tolerably stale reads; and read replicas for capacity once the primary is CPU-bound on reads. Configuration matters too — `shared_buffers`, `effective_cache_size` and a realistic `random_page_cost` — but it is a multiplier on a good plan, not a substitute for one.

  The ordering itself is the answer: structure first, hardware and caching last.

  </details>

- **MUST** — Write-side levers, and why they are mostly about batching and indexes

  <details><summary><strong>Answer</strong></summary>

  Batch inserts rather than issuing one statement per row — `COPY` for bulk load, multi-row `INSERT` otherwise — because per-statement round trip and commit dominate; group work into fewer transactions, since each commit is a log flush, and consider `synchronous_commit = off` per transaction for data whose last second is expendable. Reduce index count on write-heavy tables, since every index is maintained on every write, and avoid indexing frequently updated columns so heap-only updates remain possible.

  Beyond that: partition to keep indexes and vacuum work bounded, tune checkpoints so they do not produce write storms, keep `fillfactor` low on hot tables, and move work out of the write path into a queue where it is not needed synchronously. Sharding is the last resort, when a single primary genuinely cannot take the write volume.

  </details>

- **MUST** — The tension: every read optimization taxes writes

  <details><summary><strong>Answer</strong></summary>

  Indexes, materialized views, denormalized copies and search indexes all make a read cheap by doing extra work at write time or by accepting staleness — so the honest way to answer a performance question is to say which side you are optimizing and what the other side pays. On a write-heavy table the right move is often to remove indexes, which is the opposite of the reflex.

  Stating the trade explicitly, and asking about the read/write ratio before proposing anything, is what distinguishes a considered answer from a checklist.

  </details>

- **MUST** — Connection management and pooling as a performance topic

  <details><summary><strong>Answer</strong></summary>

  Each PostgreSQL connection is a process with its own memory, so throughput peaks at a connection count near the core count and degrades beyond it as contention rises — a pool of a few dozen usually outperforms hundreds of direct connections. PgBouncer in transaction mode multiplexes many client connections onto few server ones, at the cost of losing session-scoped features such as prepared statements caching in older setups, session advisory locks and `SET` outside a transaction.

  Application-side pools need a maximum below what the database can support in total, counting every service instance, and a timeout so exhaustion fails fast instead of stalling. Pool exhaustion looks like database slowness from the application and is one of the most misdiagnosed incidents there is.

  </details>

- **NICE** — Caching layers and their invalidation cost

  <details><summary><strong>Answer</strong></summary>

  Cache-aside with a [TTL](https://en.wikipedia.org/wiki/Time_to_live "Time To Live — Duration after which a cached or stored value expires") is the default and is honest about staleness; write-through keeps the cache current at the cost of coupling the write path; write-behind buys write latency and risks loss. The hard part is always invalidation, so the practical rules are to key on something that changes when the data changes, prefer short TTLs over clever invalidation, and guard against stampedes with a lock or a probabilistic early refresh.

  A cache added to hide an unindexed query is a decision to carry a staleness problem forever instead of fixing a plan.

  </details>

- **NICE** — Read replicas and the routing decision

  <details><summary><strong>Answer</strong></summary>

  Replicas add read capacity and a failover target, and they introduce lag, so routing must be per query rather than global: reads that follow a user's own write go to the primary or wait on a log position, reporting and search go to replicas, and anything that writes obviously stays on the primary. Long analytics queries on a replica can also block replay or, with `hot_standby_feedback`, hold back vacuum on the primary — one of the few ways a read-only replica hurts the primary.

  **Saying that out loud is** a good sign you have operated one.

  </details>

- **OPTIONAL** — Hardware and storage as the last lever

  <details><summary><strong>Answer</strong></summary>

  More memory raises cache hit ratio and is usually the highest-value hardware change; faster **storage** with high random [IOPS](https://en.wikipedia.org/wiki/IOPS "Input/Output Operations Per Second — Measures how many discrete read or write operations a storage device sustains") mostly matters once the working set exceeds memory; more cores help concurrency and parallel query. It is the **last lever** not because it does not work but because it scales a workload's shape without changing it — a query doing a thousand times too much work stays wrong on better hardware, just later.

  </details>

## 13. Lock Types in PostgreSQL

**Why it comes up:** it is the topic behind every migration that took the site down, and the lock table is knowledge you either have or improvise badly.

- **MUST** — Table-level lock modes and the conflict rule

  <details><summary><strong>Answer</strong></summary>

  There are eight table-level modes, and what matters is which conflict. `ACCESS SHARE` is taken by `SELECT` and conflicts only with `ACCESS EXCLUSIVE`. `ROW SHARE` comes from `SELECT ... FOR UPDATE`, `ROW EXCLUSIVE` from `INSERT`, `UPDATE` and `DELETE` — and those do not conflict with each other, which is why concurrent writes to different rows proceed. `SHARE UPDATE EXCLUSIVE` is taken by `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY` and many `ALTER TABLE` variants, and self-conflicts. `SHARE` blocks writes and is taken by plain `CREATE INDEX`. `ACCESS EXCLUSIVE` blocks everything including `SELECT`, and is taken by most `ALTER TABLE` forms, `DROP`, `TRUNCATE`, `VACUUM FULL` and `REINDEX`. The takeaway is that the danger is not the lock's duration alone but its conflict set.

  </details>

- **MUST** — Row-level locks: `FOR UPDATE`, `FOR NO KEY UPDATE`, `FOR SHARE`, `FOR KEY SHARE`

  <details><summary><strong>Answer</strong></summary>

  `FOR UPDATE` takes the strongest row lock and blocks other lockers and updaters of that row; `FOR NO KEY UPDATE` is what a plain `UPDATE` of non-key columns takes and is weaker, so it permits concurrent `FOR KEY SHARE`. `FOR SHARE` allows other readers with share locks but blocks updates, and `FOR KEY SHARE` — taken implicitly by foreign key checks on the referenced row — only blocks changes to the key. That last pair is the explanation for a classic production surprise: inserting child rows takes a key-share lock on the parent, so a concurrent update of the parent row can block on inserts into a child table.

  **The practical modifiers are** `NOWAIT` to fail immediately and `SKIP LOCKED`, which is the standard way to build a work queue where each worker takes different rows.

  </details>

- **MUST** — The `ACCESS EXCLUSIVE` queue: why a short migration blocks everything

  <details><summary><strong>Answer</strong></summary>

  Lock requests queue in order, so a migration waiting for `ACCESS EXCLUSIVE` sits behind a long-running `SELECT` — and every query arriving after it queues behind the migration, including the ones that would not have conflicted with anything. A one-millisecond `ALTER TABLE` therefore takes the table down for as long as the oldest transaction ahead of it runs. The defence is to set a short `lock_timeout` before [DDL](https://en.wikipedia.org/wiki/Data_definition_language "Data Definition Language — The SQL statements that create and alter database objects") and retry, so failure to acquire fails fast rather than building a queue, and to check `pg_stat_activity` for long transactions before deploying.

  This is the mechanism people describe as "the migration hung", and being able to explain the queue is the whole answer.

  </details>

- **MUST** — Which DDL is cheap and which rewrites the table

  <details><summary><strong>Answer</strong></summary>

  Adding a nullable column, or since PostgreSQL 11 a column with a constant default, is metadata-only and instant. Dropping a column is metadata-only too. Rewrites — and therefore long exclusive locks — come from changing a column's type in most cases, adding a column with a volatile default, and `VACUUM FULL`. Adding a `NOT NULL` or a check constraint scans the table, which is why the safe pattern is `ADD CONSTRAINT ... NOT VALID` then `VALIDATE CONSTRAINT` in a second transaction that takes a weaker lock. Foreign keys follow the same two-step.

  **Knowing this list is** what makes zero-downtime migrations routine rather than lucky.

  </details>

- **MUST** — Deadlocks: how they arise and how to prevent them

  <details><summary><strong>Answer</strong></summary>

  A **deadlock** is a cycle of waits — A holds a lock B wants while B holds one A wants — and PostgreSQL detects it after `deadlock_timeout` and aborts one transaction with error `40P01`. The prevention is a consistent lock ordering across the application, typically by sorting the affected keys before locking or updating them, plus short transactions that hold fewer locks for less time. `SELECT ... FOR UPDATE` in a deliberate order, or a single statement with `ORDER BY` in the subquery, removes the most common cause.

  The victim's transaction must be retried, which is the same retry loop serialization failures need.

  </details>

- **NICE** — Diagnosing a lock incident

  <details><summary><strong>Answer</strong></summary>

  `pg_locks` joined to `pg_stat_activity` shows who holds what and who waits, `pg_blocking_pids` gives the blocker of a waiting backend directly, and `wait_event_type` in `pg_stat_activity` distinguishes lock waits from I/O waits. Logging with `log_lock_waits` records waits exceeding `deadlock_timeout`, which is how you get evidence after the fact rather than during.

  **The habit to state is** finding the root blocker at the head of the chain rather than cancelling waiters, since cancelling the queue changes nothing.

  </details>

- **NICE** — Advisory locks and lock-free alternatives

  <details><summary><strong>Answer</strong></summary>

  **Advisory locks** serialize application-level sections that have no row to lock, such as a singleton job. `SKIP LOCKED` builds queues without contention. And frequently the best answer is to avoid the lock: an atomic `UPDATE ... SET n = n + 1`, an upsert with `ON CONFLICT`, or an insert-only design with aggregation at read time removes the critical section rather than protecting it.

  </details>

- **OPTIONAL** — Lock escalation, and why PostgreSQL does not do it

  <details><summary><strong>Answer</strong></summary>

  SQL Server escalates many row locks into a table lock to bound lock-manager memory, which can turn a large update into a table-wide block. PostgreSQL stores row lock state in the tuple header rather than in a lock table, so there is no escalation and a million-row update does not become a table lock — though it does create a million dead tuples and a vacuum obligation.

  It is a useful comparison to have ready because the InnoDB and SQL Server mental models predict behaviour PostgreSQL does not have.

  </details>

## 14. Constraints

**Why it comes up:** it is a short test of where you believe invariants belong — in the database, or in whichever service happens to write next.

- **MUST** — The constraint types and what each guarantees

  <details><summary><strong>Answer</strong></summary>

  `NOT NULL` forbids absence; `UNIQUE` forbids duplicates and is implemented by a unique index, with the SQL rule that nulls are distinct so multiple nulls are allowed unless declared `NULLS NOT DISTINCT`; `PRIMARY KEY` is unique plus not null plus the row's identity; `FOREIGN KEY` requires a referenced row to exist and defines what happens when it goes away; `CHECK` enforces a predicate over one row; and `EXCLUSION` generalizes uniqueness to any operator, which is how you forbid overlapping bookings on a time range with a GiST index. `DEFAULT` and generated columns are related but are value production rather than constraint. Being able to name exclusion constraints is the detail that marks the difference between a textbook answer and a practical one.

  </details>

- **MUST** — Why constraints belong in the database and not only in the application

  <details><summary><strong>Answer</strong></summary>

  The database is the one place every writer passes through — the application, a second service, a background job, a migration, an engineer with psql at 2am — so it is the only place an invariant can actually hold. Application checks also suffer a race the database does not: check-then-insert from two concurrent requests both pass the check, and only a unique constraint stops both inserts.

  **The costs are** real and worth naming: a constraint violation surfaces as an error the application must translate into a useful message, constraints slow bulk loads, and a foreign key takes a lock on the referenced row.

  The cost of the alternative is data that is already wrong by the time anyone notices, and no way to correct it retroactively.

  </details>

- **MUST** — Foreign keys: referential actions, locking and the indexing rule

  <details><summary><strong>Answer</strong></summary>

  `ON DELETE RESTRICT` or `NO ACTION` refuses; `CASCADE` deletes children, which is powerful and dangerous because one delete can silently remove a subtree; `SET NULL` or `SET DEFAULT` orphan the child deliberately. Two operational details matter more than the syntax: PostgreSQL indexes the referencing side of a **foreign key** for you, so every delete or key update on the parent scans the child table unless you create that index yourself; and foreign key checks take a `FOR KEY SHARE` lock on the parent row, so heavy child inserts can block parent updates.

  Deferrable constraints checked at commit are the escape hatch for circular references and for bulk operations that are only consistent at the end.

  </details>

- **MUST** — Partial and expression uniqueness for invariants with no plain form

  <details><summary><strong>Answer</strong></summary>

  A unique index with a `WHERE` clause enforces "at most one active row per owner" — one default address per customer, one live version per document — which no plain unique constraint expresses. A unique index on `lower(email)` enforces case-insensitive uniqueness without a second stored column.

  Both are indexes rather than declared constraints, so they cannot be the target of a foreign key and they appear differently in the catalogue, which is worth knowing before someone asks why `ADD CONSTRAINT UNIQUE` will not take a predicate.

  </details>

- **NICE** — Validating constraints on a live table without an outage

  <details><summary><strong>Answer</strong></summary>

  Adding a `CHECK` or foreign key normally scans the table under a lock, so the safe pattern is two steps: `ADD CONSTRAINT ... NOT VALID`, which enforces the rule for new and changed rows immediately with only a brief lock, then `VALIDATE CONSTRAINT` in a separate transaction, which scans under a weaker lock that permits reads and writes. For `NOT NULL`, the modern equivalent is a `NOT VALID` check constraint that is later promoted.

  This is one of the most useful concrete techniques in the whole topic and it directly demonstrates zero-downtime migration experience.

  </details>

- **NICE** — Handling violations well in application code

  <details><summary><strong>Answer</strong></summary>

  Catch the specific [SQLSTATE](https://www.postgresql.org/docs/current/errcodes-appendix.html "SQLSTATE — Five-character standard error code a database returns for a failed statement") — `23505` unique violation, `23503` foreign key violation, `23514` check violation — and map it to a domain error, rather than parsing the message text, which is locale- and version-dependent. For the common insert-or-update case, `INSERT ... ON CONFLICT` is both simpler and race-free compared to check-then-insert.

  Constraint names should be chosen deliberately, since they are the stable identifier your error handling keys on.

  </details>

- **OPTIONAL** — What constraints cannot express

  <details><summary><strong>Answer</strong></summary>

  A `CHECK` sees one row, so cross-row and cross-table invariants — a total that must match its lines, at least one active member per team — need a trigger, a materialized helper column, or serializable isolation. Subqueries are not allowed in check constraints for exactly this reason: the constraint would not be re-checked when the other table changes, so it would be a guarantee that quietly stops holding.

  </details>

## 15. Views and Materialized Views

**Why it comes up:** it checks whether you know which one costs at read time and which one carries a staleness contract.

- **MUST** — A view is a stored query, not stored data

  <details><summary><strong>Answer</strong></summary>

  A view is a named query that the rewriter inlines into the statement using it, so it costs exactly what the underlying query costs, every time, and it stores nothing. That is its virtue — it is always current and adds no write cost — and its limit: a view over an expensive aggregate is an expensive aggregate with a friendly name.

  Because it is inlined, predicates from the outer query are usually pushed down into it, so a filtered `SELECT` from a wide view is often efficient; the exceptions are views containing `LIMIT`, `DISTINCT ON`, window functions or volatile functions, which form an optimization fence. Views are worth using for encapsulating a join, presenting a stable interface over a changing schema, and restricting columns — the last with `security_invoker` or `security_definer` chosen deliberately.

  </details>

- **MUST** — A materialized view stores the result and therefore has a freshness contract

  <details><summary><strong>Answer</strong></summary>

  A materialized view runs its query once and stores the rows, so reads are as cheap as reading a table and can be indexed, and the data is exactly as old as the last refresh. `REFRESH MATERIALIZED VIEW` takes an exclusive lock and blocks reads for the whole rebuild; `REFRESH ... CONCURRENTLY` avoids that but requires a unique index, computes a diff, and is slower overall. PostgreSQL has no incremental refresh, so the cost is a full recomputation each time — which is what makes it a good fit for hourly reporting aggregates and a poor fit for anything needing near-live data.

  The answer should always state the staleness explicitly, because a materialized view silently substitutes stale data for slow data and someone downstream will assume it is live.

  </details>

- **MUST** — Choosing between a view, a materialized view, a summary table and a cache

  <details><summary><strong>Answer</strong></summary>

  A view when the query is affordable and currency matters; a **materialized view** when the query is expensive, the result is reusable and a known lag is acceptable; a **summary table** maintained incrementally by triggers or by the write path when the aggregate must be current and the recomputation would be too big; an external cache when the result is per-request, hot and short-lived. The deciding questions are how stale the result may be, how expensive recomputation is, and whether the maintenance can be incremental.

  **Naming the summary-table option is** what shows you know materialized views cannot refresh incrementally.

  </details>

- **NICE** — Updatable views, `WITH CHECK OPTION`, and views as an API

  <details><summary><strong>Answer</strong></summary>

  A simple **view** over one table with no aggregation is automatically updatable, and `WITH CHECK OPTION` prevents an update that would move a row out of the view's own predicate — a genuine correctness guard, not decoration. Anything more complex needs `INSTEAD OF` triggers.

  Views as a compatibility layer are one of the cleaner migration tools: rename a table, put a view with the old name over it, and both old and new callers work while call sites migrate.

  </details>

- **NICE** — Operational costs people forget

  <details><summary><strong>Answer</strong></summary>

  Materialized views hold a second copy of the data, so storage and backup grow; they need their own indexes and their own vacuum; and refreshes are write bursts that compete with the workload, so they belong on a schedule that accounts for that. Nested views are also a common source of surprisingly bad plans, because each level restricts what the planner can flatten, and a five-deep view stack can produce a plan nobody intended.

  Views make schema changes harder too, since a dependent view blocks altering a column's type.

  </details>

- **OPTIONAL** — Incremental view maintenance elsewhere

  <details><summary><strong>Answer</strong></summary>

  Oracle's fast refresh, SQL Server's indexed views, ClickHouse's materialized views and streaming systems such as Materialize maintain results incrementally as base data changes, which is what PostgreSQL lacks natively. Knowing the alternative exists is useful context for why the PostgreSQL answer is often a trigger-maintained summary table rather than a materialized view.

  </details>

## 16. Row-Level Security in PostgreSQL

**Why it comes up:** multi-tenancy questions land here, and the interesting part is what [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html "Row Level Security — Restricts which rows a database query can see or modify based on the current user") costs and what it cannot see.

- **MUST** — What RLS does and how a policy is evaluated

  <details><summary><strong>Answer</strong></summary>

  With `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`, the planner appends the applicable policy predicates to every query on that table, so the filter cannot be forgotten by a caller — the database, not the application, decides which rows exist. Policies are per command, with `USING` controlling which rows are visible to `SELECT`, `UPDATE` and `DELETE`, and `WITH CHECK` controlling which rows may be written, so a tenant cannot insert a row belonging to another tenant.

  Multiple permissive policies combine with OR and restrictive ones with AND. The value is that it is a default-deny filter enforced below every code path, including an ad-hoc query and a reporting tool.

  </details>

- **MUST** — Carrying the current tenant or user into the policy

  <details><summary><strong>Answer</strong></summary>

  The policy needs a value to compare against, and there are two mechanisms: a database role per user, which does not scale to application users, or a session setting — `SET LOCAL app.tenant_id = ...` read back with `current_setting`, which is the usual pattern. `SET LOCAL` is essential rather than stylistic: it is scoped to the transaction, so a pooled connection cannot leak a previous request's tenant to the next one, and the pooling mode must be transaction-level for that to hold. Getting this wrong is a cross-tenant data leak, which makes it the part of the topic worth being most precise about.

  </details>

- **MUST** — The bypasses: table owners, superusers and `BYPASSRLS`

  <details><summary><strong>Answer</strong></summary>

  Policies do not apply to **superusers**, to roles with `BYPASSRLS`, or to the **table owner** unless `FORCE ROW LEVEL SECURITY` is set — and the application very often connects as the owner, which means RLS is enabled and doing nothing. That is the single most common misconfiguration in this topic. The correct shape is a dedicated application role that owns nothing, plus `FORCE` on the tables, plus a test that logs in as that role and asserts a foreign tenant's row is invisible.

  **The general point is** that a security control unverified from the attacker's seat is not yet a control.

  </details>

- **MUST** — The performance cost, and how it interacts with the planner

  <details><summary><strong>Answer</strong></summary>

  The policy predicate is added to every query, so it must be indexable and cheap: a tenant column in the leading position of the relevant indexes turns it into a cheap filter, while a policy calling a function or a subquery per row can dominate the query. Policy predicates are also security barriers, which restricts how far the **planner** may push down user predicates — a user-supplied function could otherwise see rows the policy hides, so the planner evaluates the policy first and some optimizations are lost. `LEAKPROOF` functions and marking helper functions `STABLE` are the levers.

  This is why the honest answer includes "and then I check the plan on the largest tenant".

  </details>

- **NICE** — RLS against alternatives for multi-tenancy

  <details><summary><strong>Answer</strong></summary>

  The three shapes are a shared table with a tenant column and RLS, a schema per tenant, and a database or cluster per tenant. Shared plus RLS scales to many tenants and pools connections well, at the cost of one shared blast radius and per-query filtering; schema per tenant gives clean separation and per-tenant migrations, and stops scaling somewhere in the thousands as catalogue size and connection overhead grow; database per tenant gives the strongest isolation, per-tenant backup and restore, and the highest operational cost.

  Naming the crossover — roughly, isolation requirements and tenant count decide it — is better than defending one universally.

  </details>

- **NICE** — Testing and auditing RLS

  <details><summary><strong>Answer</strong></summary>

  The only meaningful test is a negative one executed as the restricted role: set the session to tenant A, query for a row belonging to tenant B, and assert zero rows — for `SELECT`, `UPDATE`, `DELETE` and `INSERT` separately, since a missing `WITH CHECK` is invisible to a read test. `pg_policies` lists what is defined, and a check that every table carrying a tenant column has RLS enabled and forced catches the table someone adds later without a policy. A suite that only tests the permitted path proves nothing about the boundary.

  </details>

- **OPTIONAL** — Application-side scoping as the alternative

  <details><summary><strong>Answer</strong></summary>

  Enforcing the tenant filter in a repository layer or a query hook is workable and is what most systems do, but it is one forgotten `WHERE` clause away from a leak, and it does not cover migrations, jobs or ad-hoc access. Using both — a scoped data layer and RLS as the backstop — is defence in depth where the backstop is the one that holds when the layer is bypassed.

  </details>

## 17. Triggers, Functions and Procedures

**Why it comes up:** it is really a question about where business logic should live, and about the debuggability of logic that runs invisibly.

- **MUST** — Functions and procedures, and the difference that matters

  <details><summary><strong>Answer</strong></summary>

  A **function** returns a value and runs inside the calling transaction, so it cannot commit; a **procedure**, added in PostgreSQL 11 and called with `CALL`, can control transactions internally, which is what makes it suitable for a batch job that must commit in chunks. Both can be written in PL/pgSQL, SQL, or other languages.

  Volatility classification is the part with real consequences: `IMMUTABLE` allows the result to be constant-folded and used in expression indexes, `STABLE` guarantees consistency within one statement and allows use in index scans, and `VOLATILE` — the default — forbids both and blocks optimizations. Mislabelling a volatile function as immutable produces wrong results that persist in an index, which is why the default is the pessimistic one.

  </details>

- **MUST** — Trigger anatomy: `BEFORE` and `AFTER`, row and statement level

  <details><summary><strong>Answer</strong></summary>

  A `BEFORE ROW` trigger can modify `NEW` or return null to cancel the row's operation, which makes it the place for normalization and derived columns; an `AFTER ROW` trigger sees the final state and is the place for auditing and cascading effects, since the row is already written. Statement-level triggers fire once regardless of row count, and with transition tables — `REFERENCING NEW TABLE AS` — they can process the whole change set in one set-based operation, which is far cheaper than a per-row trigger on a bulk update. `INSTEAD OF` triggers apply to views. Constraint triggers can be deferred to commit time.

  **Knowing that the per-row trigger is** what makes a bulk load ten times slower is the practically important part.

  </details>

- **MUST** — What triggers are genuinely good for, and what they should not do

  <details><summary><strong>Answer</strong></summary>

  Good uses are the ones that must hold for every writer regardless of path: audit rows, `updated_at` maintenance, append-only enforcement, maintaining a denormalized counter or a search vector, and validating a cross-row invariant a check constraint cannot express. Bad uses are business workflows, calls to external systems, and anything with side effects outside the database — the transaction may roll back after the effect has happened, and the effect is not repeated on retry. The systemic cost is invisibility: a trigger executes logic that no call site mentions, so debugging starts with an unexplained change, and a chain of triggers firing triggers is very hard to reason about.

  Naming that cost before being challenged on it is what makes the pro-trigger case credible.

  </details>

- **MUST** — Business logic in the database: the genuine trade-off

  <details><summary><strong>Answer</strong></summary>

  In favour: it is enforced for every client, it runs next to the data so a set-based operation avoids moving rows to the application, and it cannot be bypassed by a second service. Against: it is harder to version, test and review than application code, migrations become deployments, the language ecosystem is thinner, debugging and profiling are weaker, and horizontal scaling is limited because the database is the one component you cannot easily add instances of.

  **The line most teams settle on is** that data integrity and audit belong in the database while workflow belongs in the application — and that whatever goes into the database must be in version control as migrations, with tests, exactly like the rest of the code.

  </details>

- **NICE** — Performance characteristics

  <details><summary><strong>Answer</strong></summary>

  A row trigger runs once per row, so a million-row update runs it a million times, and PL/pgSQL's per-call overhead makes that dominate; the statement-level trigger with transition tables is often a hundred times cheaper for the same work. Triggers also extend transaction duration, which increases lock hold time and conflict windows.

  Set-returning and heavily used functions should be `STABLE` where correct so the planner can use indexes on them, and a function used in a `WHERE` clause without an expression index forces a full scan.

  </details>

- **NICE** — `LISTEN`/`NOTIFY` and the outbox, as the alternative to side effects in triggers

  <details><summary><strong>Answer</strong></summary>

  `NOTIFY` delivers a message to listening sessions on commit, so it is transactionally safe — unlike an [HTTP](https://datatracker.ietf.org/doc/html/rfc9110 "Hypertext Transfer Protocol — Application protocol used to request and transfer web resources") call from a trigger — but it is fire-and-forget with no persistence, so a listener that is down misses the event entirely. The durable version is the transactional **outbox**: the trigger or the write path inserts a row into an outbox table in the same transaction, and a separate worker publishes and marks it done.

  That pattern is the correct answer whenever someone proposes calling an external system from a trigger.

  </details>

- **OPTIONAL** — Extension languages and security

  <details><summary><strong>Answer</strong></summary>

  PL/Python and PL/Perl in their unrestricted forms can read the filesystem and open sockets as the database user, which is why they are superuser-installable only and are usually declined outright in managed environments. `SECURITY DEFINER` functions run with the owner's rights and must set a safe `search_path` explicitly, or they are a privilege-escalation path. If a function is the mechanism by which a restricted role performs a privileged action, that function is a security boundary and deserves review as one.

  </details>

## 18. Pages and TOAST in PostgreSQL

**Why it comes up:** it is the storage-layer question that explains row width, large values and a class of surprising performance results.

- **MUST** — The page as the unit of everything

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL stores tables and indexes as 8 KB pages, and every read, write, cache entry and I/O accounting unit is a page — reading one row means reading its whole page into shared buffers. A page holds a header, an array of item pointers growing from the front, the tuples growing from the back, and free space in the middle. Because a tuple cannot span pages, the maximum tuple size is bounded by the page, which is precisely why TOAST has to exist.

  **The practical consequence of page-granular I/O is** that narrow rows mean more rows per page, better cache density and fewer reads — so `SELECT *` on a wide table is not just extra bytes on the wire, it is a different cache profile.

  </details>

- **MUST** — What TOAST does and when it triggers

  <details><summary><strong>Answer</strong></summary>

  When a row exceeds roughly 2 KB — a quarter of a page — PostgreSQL compresses and then, if still too large, moves oversized variable-length values out to a side table, storing a pointer in the row: The Oversized-Attribute Storage Technique. The out-of-line value is split into chunks in a per-table TOAST relation with its own index. The strategies are `PLAIN` for no toasting, `EXTENDED` — the default — for compress then store out of line, `EXTERNAL` for out of line without compression, and `MAIN` for compress and keep inline if possible.

  The reason to know this is that a large `text`, `jsonb` or `bytea` column is silently a second table with a second index, and reading it is a second lookup.

  </details>

- **MUST** — The performance consequences you can actually observe

  <details><summary><strong>Answer</strong></summary>

  Selecting the wide column costs the extra fetch and decompression, so a query listing rows without it is dramatically faster than one that includes it — moving a big `jsonb` payload out of a frequently scanned table is often the single largest win available. Updating any column of a row with toasted values rewrites the main tuple but not the unchanged out-of-line values, which is why wide rows are less costly to update than they appear. `EXTERNAL` is the right strategy when substring access matters, since an uncompressed value supports partial reads.

  And a table's reported size in `pg_relation_size` excludes its TOAST relation, which is why `pg_total_relation_size` is the number to look at when the disk usage does not add up.

  </details>

- **NICE** — Row layout, alignment and column order

  <details><summary><strong>Answer</strong></summary>

  Each tuple carries a 23-byte header plus **alignment** padding, and columns are aligned to their type's boundary, so declaration order affects physical size: ordering columns from widest fixed-width type down to narrowest, with variable-length last, can save a noticeable percentage on a narrow table with many rows. It is a micro-optimization and worth mentioning as one — the reason to know it is that it explains why a table is larger than the sum of its column sizes, which otherwise looks like a bug.

  </details>

- **NICE** — Page-level mechanics: [HOT](https://www.postgresql.org/docs/current/storage-hot.html "Heap Only Tuple — PostgreSQL update path that keeps the new row version on the same page and touches no index") chains, pruning, fillfactor and the free space map

  <details><summary><strong>Answer</strong></summary>

  Within a page, dead tuples can be pruned opportunistically during a read without a full vacuum, and heap-only tuple chains keep updated versions on the same page without touching indexes — both are page-local optimizations that lower vacuum pressure. `fillfactor` reserves free space per page so those in-page updates stay possible on hot tables. The **free space map** tracks pages with room for new tuples, which is what makes vacuumed space reusable.

  These mechanics are what connect this topic back to MVCC and vacuum, and mentioning the connection shows the layers are one system rather than trivia.

  </details>

- **OPTIONAL** — Compression choices and large-object storage

  <details><summary><strong>Answer</strong></summary>

  PostgreSQL 14 added [LZ4](https://lz4.org/ "LZ4 — Fast compression algorithm, available in PostgreSQL for compressing large column values") as an alternative to the historical pglz, trading a slightly worse ratio for much faster compression and decompression, which is usually the better default for a hot toasted column. The large-object facility is a separate, older mechanism with its own API and 4 TB limit, largely superseded by `bytea` plus TOAST for anything under a few hundred megabytes — and the usual right answer for genuinely large files is an object store with only the reference in the database.

  </details>

## NoSQL Database Topics

## 19. NoSQL Database Types

**Why it comes up:** the categories are only useful if you can say which access pattern each one is for, and where each stops working.

- **MUST** — Key-value stores: what they are for and what they refuse

  <details><summary><strong>Answer</strong></summary>

  A **key-value store** is a distributed hash map: get and put by key, with an opaque value the store does not interpret, which is what allows partitioning by key hash and near-linear scaling with predictable single-digit-millisecond latency. Redis, DynamoDB in its simplest use, Memcached and etcd are the familiar examples, though they differ enormously in durability and features.

  What you give up is querying by anything but the key — no ad-hoc filters, no joins, no aggregates — so every access pattern must be designed into the key.

  **The right uses are** sessions, caches, feature flags, rate limiters and any lookup where the key is always known; the wrong use is a primary store for data you will later need to query by attribute.

  </details>

- **MUST** — Document stores: aggregates with secondary indexes

  <details><summary><strong>Answer</strong></summary>

  A **document store** keeps self-describing JSON-like documents, indexes fields inside them, and lets you query by those fields — MongoDB, Couchbase, DynamoDB with **secondary indexes**, and PostgreSQL with JSONB in practice. The modelling principle is the **aggregate**: embed what is read and written together so one read serves the request and one write is atomic, and reference what is shared or unbounded, because a document has a size limit and an unbounded array inside one is a known failure.

  What you trade is the join and the enforced schema, so shared entities are either duplicated and kept in step, or fetched in a second query. It suits content, catalogues, user profiles and event payloads — data with a natural aggregate boundary and irregular shape.

  </details>

- **MUST** — Wide-column stores: partition key, clustering key and query-first modelling

  <details><summary><strong>Answer</strong></summary>

  Cassandra, ScyllaDB, HBase and Bigtable store rows grouped by a **partition key** and sorted within the partition by clustering columns, so the fast operation is reading a contiguous slice of one partition — a time range for one device, the last fifty messages in one conversation. The design method is the inverse of relational: start from the queries, define one table per query, and duplicate data across them, because there are no joins and a query without the partition key is a full cluster scan.

  They scale writes exceptionally well thanks to log-structured storage, and their failure modes are unbounded partitions, hot partitions and tombstone accumulation from heavy deletes. It is the right choice for high-volume time-series and event data with known access patterns.

  </details>

- **MUST** — Graph databases: when the traversal is the workload

  <details><summary><strong>Answer</strong></summary>

  Graph stores such as Neo4j keep nodes and edges with direct references between them, so traversing a relationship is a pointer hop rather than an index lookup and join — which makes variable-depth traversal, shortest path and pattern matching over connections tractable where SQL would need a recursive [CTE](https://en.wikipedia.org/wiki/Hierarchical_and_recursive_queries_in_SQL "Common Table Expression — Named subquery declared with WITH and referenced within one statement") whose cost explodes with depth. The query languages, Cypher or Gremlin, express those traversals directly.

  **The cost is** that they scale horizontally poorly, because partitioning a graph cuts edges and turns local traversals into network hops, and that they are a weak fit for aggregate reporting. Choose one when the questions are about paths and relationships — fraud rings, recommendations, permission hierarchies, network topology — and not merely because the data has foreign keys.

  </details>

- **MUST** — Log-based and stream stores as a data-store category

  <details><summary><strong>Answer</strong></summary>

  An append-only log — Kafka, or the log-structured layer underneath many of these stores — treats an ordered, immutable sequence of records as the primary structure: writes are sequential and therefore very fast, reads are by offset, and consumers keep their own position, so the same data can be replayed to rebuild any derived view. That inverts the usual relationship: the log is the source of truth and databases become materialized views over it, which is the event-sourcing model.

  It buys auditability, replay and multiple independent consumers; it costs storage of the full history, the need for compaction or retention, and the fact that querying current state requires maintaining a projection. [LSM](https://en.wikipedia.org/wiki/Log-structured_merge-tree "Log Structured Merge tree — Storage structure that buffers writes in memory and merges sorted files in the background")-tree storage inside Cassandra, RocksDB and others is the same idea applied at the storage-engine level.

  </details>

- **NICE** — Search engines, time-series and vector stores as specialized cases

  <details><summary><strong>Answer</strong></summary>

  Elasticsearch and OpenSearch are document stores built around an inverted index for relevance-ranked text and analytics; they are excellent secondary indexes and poor systems of record, because they have no transactions and their durability story is weaker. **Time-series** stores such as InfluxDB, TimescaleDB and Prometheus optimize for timestamped appends, time-bucketed aggregation, downsampling and retention. **Vector stores** index high-dimensional embeddings for approximate nearest-neighbour search with [HNSW](https://arxiv.org/abs/1603.09320 "Hierarchical Navigable Small World — Graph index for approximate nearest-neighbour search over vectors") or IVF indexes, and PostgreSQL does the same with pgvector.

  **The pattern across all three is** a purpose-built index that a general store can approximate but not match — and, in each case, they are usually fed from a system of record rather than being one.

  </details>

- **NICE** — The storage engines underneath: B-tree against LSM-tree

  <details><summary><strong>Answer</strong></summary>

  A **B-tree** updates pages in place, which gives predictable reads and read-modify-write amplification on random writes; an **LSM-tree** buffers writes in a memory table, flushes sorted files, and merges them in the background, turning random writes into sequential ones at the cost of read amplification across levels — mitigated with bloom filters — and background compaction that competes for I/O. That single difference explains most of the performance character of the stores above: Cassandra and RocksDB-backed systems absorb writes exceptionally well and can suffer from compaction pressure and tombstones, while PostgreSQL and InnoDB give steadier reads and pay more per random write.

  Naming the engine rather than the product is what makes a comparison answer sound like understanding.

  </details>

- **OPTIONAL** — Multi-model stores and the convergence

  <details><summary><strong>Answer</strong></summary>

  Most stores have grown into each other's territory: PostgreSQL does documents, full-text and vectors; Redis has modules for search, JSON and time-series;

  MongoDB has transactions and aggregation. The pragmatic consequence is that adding a specialized store should be justified by a measured limitation of the one you already run, since each addition is a new operational and consistency surface — and the answer "we used PostgreSQL until it stopped being enough, and here is what stopped" is stronger than a diverse stack.

  </details>

## 20. Horizontal Scaling

**Why it comes up:** it is where "add more nodes" gets tested against knowing what does not scale by adding nodes.

- **MUST** — Vertical against horizontal, and what each actually removes

  <details><summary><strong>Answer</strong></summary>

  **Vertical** scaling makes one machine bigger — simple, no application changes, no new failure modes, and it goes a long way further than people assume, since a modern server holds terabytes of memory and hundreds of cores. Its limits are a hard ceiling, cost that rises faster than capacity, and the fact that it does nothing for availability, because there is still one machine. **Horizontal** scaling adds machines, which removes the ceiling and can improve availability, at the cost of coordination, partitioning decisions and the loss of cheap cross-node operations.

  **The honest recommendation is** to scale up first and out when the shape of the workload or the availability requirement demands it — and to be able to say which of those two forced the move.

  </details>

- **MUST** — Why partitioning is the only thing that scales writes

  <details><summary><strong>Answer</strong></summary>

  Replication puts the same data everywhere, so every replica must apply every write and total write capacity stays that of one node — adding replicas adds read capacity and costs write amplification. Partitioning gives each node a disjoint subset, so each handles only its share of the writes, and that is the only structure under which write throughput grows with node count.

  **The consequence is** that a write-bound system must partition, and a read-bound one usually should not, since replication is far simpler.

  Being able to state that distinction crisply is most of this topic.

  </details>

- **MUST** — What horizontal scaling costs: coordination, cross-partition operations and rebalancing

  <details><summary><strong>Answer</strong></summary>

  Once data spans nodes, transactions across partitions need consensus or a saga, queries without the partition key become scatter-gather with tail-latency-dominated performance, secondary indexes are either local and require querying every partition or global and require cross-partition writes, and unique constraints across the whole dataset are no longer free. **Rebalancing** moves data while serving traffic and is a source of real incidents. Operations grow too: more nodes mean more failures per week, and a cluster is a system with its own failure modes rather than several servers.

  **The single sentence worth having is** that horizontal scaling converts a capacity problem into a distributed-systems problem, which is a trade rather than a solution.

  </details>

- **MUST** — Hot partitions and skew

  <details><summary><strong>Answer</strong></summary>

  Even distribution of keys does not mean even distribution of load: one celebrity user, one large tenant or one popular product can make a single partition the bottleneck while the rest idle, and no amount of extra nodes helps because the constraint is one key's traffic. The mitigations are salting the key with a bounded random suffix and fanning reads across the variants, splitting the hot entity into sub-partitions such as per-day buckets, caching the hot values in front, or handling the outlier separately.

  Detecting it needs per-partition metrics rather than cluster averages, since an average hides exactly this. Time-ordered keys are the systematic version of the same problem, where the newest partition is always hot.

  </details>

- **MUST** — Stateless application scaling and where the state moves

  <details><summary><strong>Answer</strong></summary>

  Application instances scale trivially when they hold no state, which is why sessions go to Redis, uploads go to object storage, and locks and schedules go to a shared store — the state does not disappear, it moves to a component chosen for it. The result is that the datastore becomes the scaling constraint, which is the reason database scaling questions matter more than application ones.

  Connection count is the concrete trap: doubling application instances doubles connections to the database, which for PostgreSQL can reduce throughput, so a pooler belongs in the design before the autoscaler does.

  </details>

- **NICE** — Read scaling with replicas and the consistency you give up

  <details><summary><strong>Answer</strong></summary>

  **Replicas** scale reads cheaply and give a failover target, and they introduce lag, so the application must decide per query whether staleness is acceptable, route read-your-own-writes to the primary, or wait for a log position. Quorum reads give stronger guarantees at higher latency in stores that offer tunable consistency.

  **The general principle is** that **read scaling** is nearly free and read consistency is what you pay with — so the design work is classifying reads, not adding replicas.

  </details>

- **NICE** — Autoscaling a stateful system

  <details><summary><strong>Answer</strong></summary>

  Stateless tiers autoscale in seconds; a database node must receive its share of the data first, so scaling a cluster is minutes to hours and is driven by capacity planning rather than by a request-rate metric. Serverless offerings hide this by separating compute from shared storage, which genuinely changes the trade at the cost of a different latency and cost profile.

  **The practical implication is** that database capacity must be provisioned ahead of a known spike, not autoscaled into it.

  </details>

- **OPTIONAL** — Amdahl, Universal Scalability, and why throughput can fall

  <details><summary><strong>Answer</strong></summary>

  **Amdahl**'s law bounds speedup by the serial fraction; the **Universal Scalability** Law adds a crosstalk term for coherence between nodes, which is why real systems do not merely plateau but get slower past a point — every node must agree with every other, and that cost grows quadratically. It is the formal reason a cluster can be slower than a smaller one, and it is a good closing sentence when the question is "why not just add nodes".

  </details>

## 21. Redis Data Structures

**Why it comes up:** Redis is nearly universal, and the question distinguishes people who use it as a string cache from people who use the structures.

- **MUST** — Strings, hashes, lists, sets and sorted sets, and what each is for

  <details><summary><strong>Answer</strong></summary>

  **Strings** hold any binary value up to 512 MB and carry atomic counters via `INCR`, which is the basis of most rate limiting. **Hashes** hold field-value maps under one key, so a session or object can have individual fields read and written without deserializing the whole value, and they are memory-efficient for small maps. Lists are linked lists with pushes and pops at both ends plus blocking pops, which makes a simple queue — although Streams are the better queue now.

  Sets are unordered unique collections with union, intersection and difference computed server-side, good for tags, unique visitors and relationship sets. Sorted sets keep members ordered by a score with logarithmic insertion and range queries by score or rank, which makes them the single most useful structure in Redis: leaderboards, priority queues, sliding-window rate limiters and time-ordered indexes are all **sorted sets**.

  </details>

- **MUST** — The structures beyond the basic five

  <details><summary><strong>Answer</strong></summary>

  Streams are an append-only log with consumer groups, per-consumer acknowledgement and a pending list, which gives at-least-once delivery and makes them the right choice for work queues rather than lists. HyperLogLog counts distinct elements in about 12 KB with roughly 0.8% error regardless of cardinality, which is the correct tool for unique-visitor counts at scale. Bitmaps address individual bits in a string, so daily active users can be one bit per user with `BITCOUNT` for the total. Geospatial commands are sorted sets over geohashes, giving radius queries. Bloom filters, JSON documents, time-series and vector similarity come from Redis modules.

  **Naming HyperLogLog and Streams unprompted is** a strong signal, because both replace a common but wasteful pattern.

  </details>

- **MUST** — Single-threaded execution, atomicity and the blocking-command trap

  <details><summary><strong>Answer</strong></summary>

  Redis executes commands on one thread, so every command is atomic without locks and the data structures need no synchronization — which is exactly why an O(N) command on a large key is dangerous: `KEYS`, `SMEMBERS` on a million-member set, or a large `LRANGE` blocks every other client for the duration. The safe equivalents are `SCAN` and its cursor-based relatives, which return in bounded chunks.

  The same principle makes multi-command **atomicity** easy: `MULTI`/`EXEC` queues commands and runs them without interleaving, and a Lua script runs atomically as a unit, which is how compare-and-set patterns are implemented. Newer versions add I/O threads, which parallelize socket work and not command execution, so the model still holds.

  </details>

- **MUST** — Persistence, eviction and what Redis promises about durability

  <details><summary><strong>Answer</strong></summary>

  [RDB](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ "Redis Database file — Redis persistence mode that writes point-in-time snapshots of the dataset") takes point-in-time snapshots — compact and fast to restore, losing everything since the last snapshot; [AOF](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/ "Append Only File — Redis persistence mode that logs every write for durability") logs every write and replays it, with `everysec` fsync as the usual compromise, losing at most a second; running both is common. Even so, replication is asynchronous, so a failover can lose acknowledged writes, and Redis is therefore not the place for data that must not be lost. `maxmemory` plus an **eviction** policy decides behaviour when full: `allkeys-lru` or `allkeys-lfu` for a cache, `volatile-*` variants to evict only keys with a TTL, and `noeviction` to return errors — which is the right choice for a queue or a lock store, where silently evicting data is worse than failing.

  Choosing the policy deliberately per use is the part most people skip.

  </details>

- **MUST** — Expiry, TTL semantics and the stampede problem

  <details><summary><strong>Answer</strong></summary>

  Keys expire by a combination of lazy deletion on access and a sampling background cycle, so expired keys can occupy memory briefly — **expiry** is not a scheduled event. Most write commands reset or clear a TTL depending on the command, which is a common source of keys that never expire.

  The operational hazard is the stampede: many keys with the same TTL expire together and every client recomputes at once, so add jitter to expiry times, and protect expensive recomputation with a short lock or a probabilistic early refresh so one client refreshes while others serve the slightly stale value.

  </details>

- **NICE** — Distributed locks and why they are subtle

  <details><summary><strong>Answer</strong></summary>

  The basic lock is `SET key token NX PX ttl` with a unique token, released by a Lua script that deletes only if the token matches — the compare-and-delete matters, because otherwise a process whose lock expired deletes someone else's. Even correct, it is not safe against a process that pauses past its TTL and then acts, so a lock must either be short and its work idempotent, or the protected resource must itself reject stale operations with a fencing token. Redlock across independent instances is contested precisely on these grounds.

  **The right answer is** to name the limitation rather than present Redis locks as mutual exclusion.

  </details>

- **NICE** — Scaling Redis: replication, Sentinel and Cluster

  <details><summary><strong>Answer</strong></summary>

  Replicas serve reads and provide failover; **Sentinel** adds automatic failover for a single-primary setup;

  **Cluster** shards the keyspace across 16384 hash slots for horizontal scale, at the cost that multi-key operations must land in one slot — which is what hash tags in braces are for — and that clients must be cluster-aware. Big keys are the recurring operational problem: a single huge hash or set cannot be split across slots and makes one node hot, so key design matters as much here as in any other partitioned store.

  </details>

- **OPTIONAL** — Redis against Memcached and against a real queue

  <details><summary><strong>Answer</strong></summary>

  **Memcached** is a simpler multi-threaded cache with a smaller memory footprint per key and no persistence or data structures — a reasonable choice for a pure cache at scale, and nothing more. Against a real broker, **Redis** Streams give consumer groups and acknowledgement but not the routing, durability guarantees or dead-lettering of [RabbitMQ](https://www.rabbitmq.com/docs "RabbitMQ — Message broker that routes and queues messages between producers and consumers") or Kafka; using Redis as a queue is a deliberate trade of guarantees for latency and simplicity, and it is a fine one as long as it is stated.

  </details>

## 22. Transactions in NoSQL

**Why it comes up:** it checks whether you know the scope of the guarantee a given store actually offers, rather than whether it has a `transaction` API.

- **MUST** — The single-key or single-document guarantee that almost every store has

  <details><summary><strong>Answer</strong></summary>

  Nearly every NoSQL store makes a write to one key or one document atomic and isolated, because that write is handled by one partition and needs no coordination. That is a real guarantee and it is usually enough — provided the data model puts what must change together in one document, which is the aggregate principle.

  **The corollary is** a design rule rather than a limitation: choose the aggregate boundary to match the transaction boundary you need, and you rarely need a multi-key transaction at all.

  **Stating it that way is** much stronger than listing which stores added transaction support.

  </details>

- **MUST** — Conditional writes and compare-and-set as the everyday tool

  <details><summary><strong>Answer</strong></summary>

  Where a store does not offer multi-key transactions, it offers a **conditional write** — DynamoDB's condition expressions, Cassandra's `IF NOT EXISTS` lightweight transactions, MongoDB's `findAndModify`, an etcd compare-and-swap — which makes read-modify-write safe by failing when the precondition no longer holds. Combined with a version attribute this is optimistic concurrency control, and it covers most real invariants on one entity.

  Cassandra's version is worth a caveat: lightweight transactions use Paxos and cost several round trips, so they are correct and slow, and using them on a hot path is a known mistake.

  </details>

- **MUST** — Multi-document transactions where they exist, and what they cost

  <details><summary><strong>Answer</strong></summary>

  MongoDB supports multi-document ACID transactions, across shards since 4.2; DynamoDB has `TransactWriteItems` for up to a hundred items with all-or-nothing semantics; Spanner and CockroachDB offer full serializable distributed transactions.

  **The costs are** consistent across all of them: coordination latency, tighter size and duration limits, higher abort and retry rates under contention, and — in DynamoDB's case — double the capacity consumption.

  **The judgment being tested is** treating them as an escape hatch for the few cases the data model could not absorb, rather than as permission to model relationally in a non-relational store.

  </details>

- **MUST** — Sagas and idempotency as the general answer

  <details><summary><strong>Answer</strong></summary>

  When a unit of work genuinely spans partitions or services, the pattern is a **saga**: a sequence of local transactions, each with a compensating action that semantically undoes it, coordinated either by choreography through events or by an explicit orchestrator. What it requires is that every step is idempotent, since retries and duplicate deliveries are certain, and that compensations are meaningful — you cannot un-send an email, so you send a correction. It also exposes intermediate states to readers, which must be either tolerable or hidden behind a status field.

  Naming **idempotency** keys and the outbox pattern alongside it is what makes the answer operational.

  </details>

- **NICE** — Tunable consistency and quorums

  <details><summary><strong>Answer</strong></summary>

  Cassandra and DynamoDB let you choose per operation: write to a **quorum** and read from a quorum so that R plus W exceeds N and the sets overlap, guaranteeing you read the latest write, or read from one replica for speed and accept staleness. That is a per-query decision rather than a database-wide one, which is the useful part — a balance read can be strong while a feed read is eventual.

  **The costs are** latency and availability: quorum operations fail when too many replicas are unreachable, which is the CAP trade made explicit at the call site.

  </details>

- **NICE** — Isolation levels in distributed stores

  <details><summary><strong>Answer</strong></summary>

  Distributed stores mostly offer snapshot isolation or serializable rather than the full standard ladder, and some offer weaker per-operation guarantees such as read-your-writes, monotonic reads or causal consistency — session guarantees that are much cheaper than linearizability and often exactly what an application needs. Being able to ask for causal consistency by name, and to say that it prevents the "my comment disappeared after I posted it" class of bug, is a good demonstration that consistency is a spectrum rather than a switch.

  </details>

- **OPTIONAL** — Consensus underneath: Paxos and Raft

  <details><summary><strong>Answer</strong></summary>

  Strong guarantees across replicas come from a consensus protocol — Raft in etcd, Consul, CockroachDB and TiKV, **Paxos** variants in Spanner and Cassandra's lightweight transactions — which elects a leader and commits an entry once a majority acknowledges it. The properties that matter to a user are that a majority must be reachable, so a cluster survives a minority failure and stalls on a majority one, and that each committed operation costs at least one round trip to the quorum.

  That single fact explains the latency of every strongly consistent distributed store.

  </details>

## 23. Resolving Eventual Consistency with Anti-Entropy and Reconciliation

**Why it comes up:** eventual consistency is easy to say; the question is what mechanism actually makes replicas converge.

- **MUST** — What eventual consistency promises and what it does not

  <details><summary><strong>Answer</strong></summary>

  It promises that if writes stop, all replicas converge to the same value; it promises nothing about how long that takes, nothing about the order in which intermediate values appear, and nothing about reading your own write from a different replica. The practically important consequences are that a read can go backwards in time, that two clients can see different values simultaneously, and that concurrent writes to different replicas must be resolved by some rule.

  Every mechanism in this topic exists to make convergence actually happen rather than merely being promised.

  </details>

- **MUST** — Read repair and hinted handoff as the foreground mechanisms

  <details><summary><strong>Answer</strong></summary>

  **Read repair** happens on the read path: the coordinator queries several replicas, notices that one returned a stale version, returns the newest to the client and writes the correction back to the laggard — so frequently read data self-heals, and rarely read data does not, which is precisely why a background mechanism is also needed. **Hinted handoff** covers the write path: when a replica is down, another node stores a hint and replays it when the replica returns, which keeps a short outage from causing divergence at all.

  Hints have a time limit, after which they are dropped and the gap becomes anti-entropy's problem — which is why a node down for longer than the hint window must be repaired explicitly.

  </details>

- **MUST** — Anti-entropy with Merkle trees

  <details><summary><strong>Answer</strong></summary>

  **Anti-entropy** is the background process that compares replicas in full and repairs differences, and comparing terabytes directly is infeasible, so replicas exchange **Merkle trees**: a hash tree over key ranges where equal root hashes prove the ranges are identical, and unequal ones let both sides descend only into the differing subtrees. Transfer is therefore proportional to the differences rather than the data.

  In Cassandra this is `nodetool repair`, which is heavy enough that it is scheduled and throttled, and skipping it is a known way to resurrect deleted rows once tombstones expire. The same idea appears in Dynamo, Riak, and in Git's object comparison.

  </details>

- **MUST** — Conflict resolution rules: last-write-wins and its cost

  <details><summary><strong>Answer</strong></summary>

  **Last-write-wins** picks the version with the highest timestamp, which is simple, needs no application logic, and silently discards the losing write — acceptable for a presence flag or a cached profile, unacceptable for a cart or a balance. It also depends on clock synchronization, so clock skew across nodes can discard a newer write, which is why some stores use logical rather than wall-clock time. The alternatives are keeping siblings and letting the application merge on read, as Riak does, or using a data type whose merge is defined mathematically, which is topic 26.

  **The important sentence is** that last-write-wins is not conflict resolution but conflict deletion, and choosing it should be a decision rather than a default nobody noticed.

  </details>

- **MUST** — Reconciliation at the application level

  <details><summary><strong>Answer</strong></summary>

  Beyond a single store, reconciliation is the periodic job that compares two systems that should agree — a database and a search index, a ledger and a payment provider, a cache and its source — reports divergence and repairs it. It matters because every asynchronous pipeline drifts eventually through dropped events, bugs and outages, so a system without a reconciliation path has an unbounded error that nobody will notice until a customer does.

  The design points are that it must be idempotent, must be able to run continuously without disturbing the workload, must emit a divergence metric rather than only fixing silently, and must have a defined authority — one side wins, and it is decided in advance. A rising divergence count is one of the most useful alerts an event-driven system can have.

  </details>

- **NICE** — Tombstones and deletion in an eventually consistent store

  <details><summary><strong>Answer</strong></summary>

  Deletion cannot simply remove data, because a replica that missed the delete would resurrect it during the next repair, so a delete writes a tombstone — a marker with a timestamp that wins over older values and is itself removed after a grace period. That produces two known problems: **tombstones** accumulate and make reads slow, since a query over a range must skip them, and a replica that is down for longer than the grace period brings the deleted data back.

  This is the concrete reason repair schedules must be shorter than the tombstone lifetime, and it is a memorable detail to be able to explain.

  </details>

- **NICE** — Session guarantees as the practical fix for user-visible weirdness

  <details><summary><strong>Answer</strong></summary>

  Most complaints about eventual consistency are one of four things: not reading your own write, monotonic reads going backwards, writes appearing out of causal order, or a read that contradicts a previous read in the same session. Each has a cheap fix — sticky routing to one replica, tracking a version or log position per client and waiting for it, or causal consistency where the store supports it — and none requires full linearizability.

  **Framing it this way shows** that consistency requirements come from the user experience rather than from a preference for strong guarantees.

  </details>

- **OPTIONAL** — Gossip and membership

  <details><summary><strong>Answer</strong></summary>

  The same anti-entropy idea propagates cluster metadata: nodes **gossip** state to a few random peers each round, and information spreads to the whole cluster in logarithmic time without a central coordinator, with failure detection built on missed heartbeats — usually a phi-accrual detector that reports a suspicion level rather than a binary verdict. It is worth knowing because it explains why cluster **membership** changes take seconds to settle and why a partitioned cluster can briefly hold two views of itself.

  </details>

## 24. Full-Text Search with Inverted Indexes, Tokenization and Trigrams

**Why it comes up:** search questions test whether you understand the index structure and the linguistic pipeline, not just which product to install.

- **MUST** — The inverted index and why it is the right structure

  <details><summary><strong>Answer</strong></summary>

  An **inverted index** maps each term to a posting list of the documents containing it, with positions and frequencies, so answering "which documents contain these words" is a lookup and a merge of a few short lists rather than a scan of every document. Intersecting posting lists gives conjunctions, positions give phrase queries, and frequencies feed relevance scoring.

  **The costs are** that the index is large — often comparable to the source text — that writes are heavier since every term must be updated, and that it answers term queries and not arbitrary predicates. In PostgreSQL this is a GIN index over `tsvector`; in Elasticsearch it is the Lucene segment structure.

  </details>

- **MUST** — The analysis pipeline: tokenization, normalization, stemming, stop words

  <details><summary><strong>Answer</strong></summary>

  Text becomes searchable through an ordered pipeline: tokenize into terms — which is language-dependent and not merely splitting on spaces, given hyphenation, URLs, and languages without spaces; normalize case and accents; remove **stop words** if the language and workload justify it; and reduce terms to a root by **stemming**, a fast rule-based truncation, or lemmatization, which is dictionary-based and more accurate. The rule that catches people out is that the query must be analyzed the same way as the document, or "Running" will not match an index entry of "run" — and in PostgreSQL that means the same text search configuration on both sides.

  Stop-word removal also breaks phrase queries containing them, which is why modern engines often keep them and de-weight them instead.

  </details>

- **MUST** — Relevance scoring: [TF-IDF](https://en.wikipedia.org/wiki/Tf%E2%80%93idf "Term Frequency-Inverse Document Frequency — Scores how important a term is to one document relative to the whole collection") and [BM25](https://en.wikipedia.org/wiki/Okapi_BM25 "Best Matching 25 — Ranking function that scores how relevant a document is to a search query")

  <details><summary><strong>Answer</strong></summary>

  Term frequency rewards documents that use the term often; inverse document frequency rewards rare terms, so a match on an unusual word counts for far more than one on a common word; and length normalization stops long documents winning by accumulation. BM25 is the refinement in use nearly everywhere: it saturates term frequency, so the tenth occurrence adds much less than the second, and it parameterizes length normalization. PostgreSQL's `ts_rank` is weaker than BM25 and does not use collection-wide statistics in the same way, which is one honest reason to reach for a dedicated engine.

  **The practical point is** that relevance is tunable — field boosts, phrase proximity, recency and popularity signals — and that it must be evaluated against a labelled set rather than by intuition.

  </details>

- **MUST** — Trigrams, and the problems they solve that an inverted index does not

  <details><summary><strong>Answer</strong></summary>

  A **trigram** index — `pg_trgm` with GIN or GiST — decomposes strings into overlapping three-character sequences, so similarity becomes set overlap between trigram sets. That gives three capabilities full-text search does not: fuzzy matching against typos, similarity ranking on short strings such as names and product codes, and crucially the ability to index `LIKE '%substring%'` and case-insensitive regular expression matches, which no B-tree can serve because they have no fixed prefix.

  **The costs are** a large index and degradation on very short search strings, where too few trigrams exist to be selective.

  Knowing that `pg_trgm` is the answer to leading-wildcard `LIKE` is one of the most immediately useful facts in this topic.

  </details>

- **MUST** — PostgreSQL full-text search: how it is actually wired

  <details><summary><strong>Answer</strong></summary>

  Documents are converted to `tsvector` with a language configuration, queries to `tsquery`, and matching uses the `@@` operator over a GIN index. For any real table the vector should be a stored generated column or a trigger-maintained column rather than computed per query, with field weights assigned via `setweight` so a title match outranks a body match. `ts_headline` produces highlighted snippets and is expensive, so it should run only over the page of results being returned.

  **The honest boundary is** that this is excellent for moderate corpora and searching data you already store transactionally, and it lacks the analyzers, distributed scale, aggregations and relevance tuning of a dedicated engine.

  </details>

- **NICE** — When to add a dedicated search engine, and the cost of doing so

  <details><summary><strong>Answer</strong></summary>

  Move to Elasticsearch or OpenSearch when you need multi-language analyzers, faceted aggregation over search results, per-field relevance tuning at a level PostgreSQL cannot express, autocomplete and did-you-mean, or a corpus and query rate beyond what one database should carry. The cost is a second store to operate and a synchronization path that will drift, so the design must include how documents get there — outbox or change data capture rather than dual writes — how a full reindex is performed, and the acceptance that search results are eventually consistent with the database.

  **The rule that keeps it safe is** that the search index is derived and rebuildable, never a system of record.

  </details>

- **NICE** — Ranking beyond text, and evaluating quality

  <details><summary><strong>Answer</strong></summary>

  Real relevance mixes the text score with business signals — recency, popularity, stock availability, personalization — and increasingly with vector similarity for semantic matching, combined in a hybrid score or by reranking the top results. None of it is improvable without measurement: a labelled evaluation set with a metric such as [NDCG](https://en.wikipedia.org/wiki/Discounted_cumulative_gain "Normalized Discounted Cumulative Gain — Ranking metric that rewards relevant results appearing near the top") or [MRR](https://en.wikipedia.org/wiki/Mean_reciprocal_rank "Mean Reciprocal Rank — Ranking metric scoring how high the first relevant result appears"), plus click-through and abandonment in production.

  Being able to say how you would tell whether a relevance change helped is what separates a search answer from a search opinion.

  </details>

- **OPTIONAL** — Segment mechanics and near-real-time indexing

  <details><summary><strong>Answer</strong></summary>

  Lucene writes immutable segments and merges them in the background, deletions are marked rather than applied, and a document becomes searchable only after a refresh — which is why Elasticsearch is near-real-time with a default one-second refresh interval rather than immediately consistent. Raising that interval speeds bulk indexing considerably.

  It is the same log-structured trade as an LSM-tree, and recognizing it as such ties this topic back to storage engines.

  </details>

## 25. Schema on Write and Schema on Read

**Why it comes up:** it is the clearest way to ask whether you know that flexibility relocates a cost rather than removing it.

- **MUST** — The distinction, and where the enforcement lands

  <details><summary><strong>Answer</strong></summary>

  Schema on write validates and shapes data at insert time, so the store guarantees that everything inside it conforms and every reader can rely on that; schema on read accepts whatever arrives and applies structure when the data is queried, so writers are never blocked and readers carry the burden. Neither removes the schema — data always has one — the question is only whether it is enforced once at the boundary or implicitly by every consumer.

  That framing is the answer, and the follow-up is that schema-on-read systems tend to accumulate an undocumented schema in code, which is the most expensive form to change.

  </details>

- **MUST** — What each buys, honestly

  <details><summary><strong>Answer</strong></summary>

  Schema on write buys early failure at the writer that produced the bad data, self-documentation, type-aware storage and indexing, and a planner that knows what it is dealing with — at the cost of migrations and coordinated deployments. Schema on read buys ingesting data whose shape you do not control or do not yet understand, heterogeneous records in one place, and the ability to reinterpret history when your understanding improves — at the cost of defensive readers, silent corruption that surfaces months later, and query-time transformation cost.

  **The deciding question is** who owns the writer: if you do, enforce; if you do not, accept and validate at the boundary you control.

  </details>

- **MUST** — Evolution in each model, and the compatibility rules

  <details><summary><strong>Answer</strong></summary>

  Under schema on write, evolution is a migration and the discipline is expand-and-contract: add the new nullable column, backfill in batches, write both, switch reads, then remove the old — so that old and new application versions run simultaneously without either failing. Under schema on read, evolution is versioned records and readers that tolerate every historical shape, which is only sustainable with a schema registry enforcing backward and forward compatibility, as Avro or Protobuf with a registry provides.

  The failure that motivates both is the same: a deploy where writer and reader disagree about the shape, and knowing the expand-and-contract sequence by name is worth stating explicitly.

  </details>

- **MUST** — The hybrid that most real systems use

  <details><summary><strong>Answer</strong></summary>

  The common shape is a strict relational core for the entities with invariants and a JSONB or document column for the irregular tail — settings, provider-specific payloads, form responses — indexed with GIN where it is queried. That keeps constraints, types and foreign keys where they earn their cost and flexibility where the shape is genuinely unknown, and PostgreSQL supports both in one store. The discipline that keeps the flexible part from rotting is a validator or typed accessor at the application boundary and a rule that anything queried frequently or constrained gets promoted to a real column.

  **Saying that promotion rule out loud is** what makes the hybrid a design rather than an excuse.

  </details>

- **NICE** — Data lakes, lakehouses and where schema on read came from

  <details><summary><strong>Answer</strong></summary>

  The term comes from analytics: land raw files cheaply, define the schema in the query engine, and avoid discarding data whose value is not yet known. The lesson of a decade of that practice is that unmanaged lakes become unusable, which is why table formats such as Iceberg and Delta Lake reintroduced schemas, evolution rules and transactions over the same files — schema on read plus governance.

  **Citing that arc is** a good way to answer "is schema on read a good idea" with evidence rather than preference.

  </details>

- **NICE** — Validation at the boundary as the middle path

  <details><summary><strong>Answer</strong></summary>

  Even in a schemaless store, validation can be enforced where it is cheapest to fix: JSON Schema at the API edge, MongoDB document validators, a check constraint over a JSONB path, or a typed model in the application. It gives most of the guarantee of schema on write while keeping storage flexible, and it puts the error next to the writer that caused it, which is the property that actually matters — a bad record rejected at ingestion costs minutes, and the same record discovered in a report costs a data-repair project.

  </details>

- **OPTIONAL** — Cost of query-time transformation at scale

  <details><summary><strong>Answer</strong></summary>

  Parsing and casting at read time is paid on every query by every consumer, so a field extracted from JSON a billion times is far more expensive in total than a typed column written once — which is the performance half of the argument and the reason columnar formats with declared types dominate analytics. It is worth one sentence because it shows the trade has a measurable side and not only a governance side.

  </details>

## 26. Strong Eventual Consistency and CRDTs

**Why it comes up:** it is the depth question behind eventual consistency, and the one place where "convergence" has a precise definition.

- **MUST** — What strong eventual consistency actually claims

  <details><summary><strong>Answer</strong></summary>

  Eventual consistency says replicas converge if writes stop; strong eventual consistency says any two replicas that have received the same set of updates are already in the same state, regardless of order, delivery duplication or timing — no coordination, no rollback, no conflict resolution step. It is a stronger guarantee than eventual consistency and weaker than strong consistency, which orders operations globally.

  **The reason it matters is** that it removes the "if writes stop" caveat, which never holds in a live system, and it turns convergence into a property of the data type rather than of an anti-entropy process that must be scheduled and might be skipped.

  </details>

- **MUST** — The mathematical requirement: a merge that is commutative, associative and idempotent

  <details><summary><strong>Answer</strong></summary>

  Replica states form a join-semilattice: there is a merge operation that is commutative so order does not matter, **associative** so grouping does not matter, and **idempotent** so a duplicate delivery changes nothing, and every merge moves the state upward in a partial order. Those three properties are exactly what an unreliable network requires, since it reorders, regroups and duplicates. A simple example is a set with union as the merge — any order of unions of the same elements gives the same set — and a counter with per-replica sub-counters merged by taking the maximum per replica.

  Being able to name the three properties and say why each corresponds to a network failure mode is the core of this answer.

  </details>

- **MUST** — State-based and operation-based CRDTs

  <details><summary><strong>Answer</strong></summary>

  A **state-based** [CRDT](https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type "Conflict-free Replicated Data Type — Data type whose replicas converge without coordination because its merge is order-independent") ships its whole state and merges with the lattice join, which tolerates any delivery — duplicates, reordering, loss — as long as messages eventually arrive, at the cost of message size; delta-state variants ship only the change to fix that. An **operation-based CRDT** ships operations, which are small, but requires the delivery layer to guarantee exactly-once causally ordered delivery, since the operations are commutative but usually not idempotent.

  **The trade is** therefore where the burden sits: bandwidth in one, a stronger messaging guarantee in the other. Most production systems use delta-state or a hybrid for that reason.

  </details>

- **MUST** — The common types and what each is for

  <details><summary><strong>Answer</strong></summary>

  G-Counter is a grow-only counter as a vector of per-replica counts, merged element-wise by maximum; PN-Counter adds a second vector for decrements. G-Set is add-only; 2P-Set allows removal but never re-adding; LWW-Element-Set resolves by timestamp; OR-Set tags each addition with a unique identifier so a remove only cancels the additions it saw, which makes concurrent add-and-remove resolve as add — the behaviour users expect. LWW-Register keeps the last value by timestamp, and MV-Register keeps concurrent values as siblings for the application to resolve. Sequence types such as RGA and Logoot underpin collaborative text editing.

  Knowing that OR-Set exists specifically because 2P-Set and LWW-Set lose information is the distinguishing detail.

  </details>

- **MUST** — What CRDTs cannot do

  <details><summary><strong>Answer</strong></summary>

  They guarantee convergence, not correctness of a global invariant: a PN-Counter for a bank balance converges beautifully to a negative number, because no local replica could see that the total had reached zero. Any invariant over the whole state — a limit, a unique constraint, an allocation of a finite resource — needs coordination, and no data type removes that. They also carry metadata that grows with the number of replicas and with tombstones, which must be garbage-collected, and merge semantics can surprise users when concurrent edits combine in a way neither person intended.

  **The right closing sentence is** that CRDTs move a class of problems out of coordination, and the class they leave behind is precisely the one worth coordinating for.

  </details>

- **NICE** — Where they are used in practice

  <details><summary><strong>Answer</strong></summary>

  Riak offered CRDT data types natively; Redis Enterprise's active-active replication is built on them; Automerge and Yjs power collaborative editors and local-first applications; Azure Cosmos DB and several offline-first mobile sync frameworks use the same ideas.

  **The pattern in every case is** multi-writer replicas that must accept writes while disconnected — offline mobile, multi-region active-active, collaborative editing — which is a useful way to recognize when a CRDT is the right tool rather than a curiosity.

  </details>

- **NICE** — CRDTs against operational transformation

  <details><summary><strong>Answer</strong></summary>

  **Operational transformation**, the older approach behind Google Docs, transforms incoming operations against concurrent ones to preserve intent, and it generally relies on a central server to order operations; **CRDTs** make the data type itself commutative and therefore work peer-to-peer without a coordinator.

  OT tends to produce smaller messages and harder-to-verify transformation functions, while CRDTs carry more metadata and much simpler correctness arguments. That trade — metadata size against implementation complexity and a server dependency — is the whole comparison.

  </details>

- **OPTIONAL** — Garbage collection and metadata growth

  <details><summary><strong>Answer</strong></summary>

  Tombstones in an OR-Set, per-replica entries in a counter and position identifiers in a sequence all accumulate, so a long-lived document can carry more metadata than content. Real implementations compact using causal stability — once every replica is known to have seen an update, its metadata can be dropped — which requires knowing the replica set, and that is exactly the coordination CRDTs otherwise avoid.

  It is a good example of a guarantee that is free in theory and has an operational bill.

  </details>

## 27. Vector Clocks and Lamport Clocks

**Why it comes up:** it is the "how do you order events without a global clock" question, and it explains why wall-clock timestamps are the wrong tool.

- **MUST** — Why physical clocks cannot order distributed events

  <details><summary><strong>Answer</strong></summary>

  Clocks on different machines drift, [NTP](https://en.wikipedia.org/wiki/Network_Time_Protocol "Network Time Protocol — Synchronizes machine clocks over a network") corrections can step time backwards, and the skew between two servers is typically milliseconds but occasionally much worse — so a timestamp comparison between events on different nodes can be simply wrong, and a last-write-wins rule built on it can silently discard the newer write. There is also no way to distinguish "happened earlier" from "was recorded by a slow clock".

  This is why logical clocks exist: they order events by causality, which is a property of the system rather than of the hardware, and it is the first sentence the answer should reach.

  </details>

- **MUST** — Happens-before, and what concurrency actually means here

  <details><summary><strong>Answer</strong></summary>

  Lamport's **happens-before** is a partial order defined by three rules: events on the same process are ordered by their sequence, a send happens before the corresponding receive, and the relation is transitive. Two events unrelated by that chain are concurrent — which does not mean simultaneous, it means neither could have influenced the other.

  **The key insight is** that the order is partial rather than total: some pairs are genuinely unordered, and a system that forces a total order on them is inventing information. Once that is clear, both clock types follow naturally.

  </details>

- **MUST** — Lamport clocks: what they give and their limitation

  <details><summary><strong>Answer</strong></summary>

  Each process keeps a counter, increments it on every event, sends it with each message, and on receipt sets its counter to the maximum of its own and the received value plus one. The guarantee is one-directional: if A happens before B then A's timestamp is smaller — but a smaller timestamp does not prove causality, so you cannot detect concurrency, only impose a consistent total order by breaking ties with a process identifier.

  That is enough for many purposes, such as ordering operations deterministically across replicas, and it costs one integer. Being precise that the implication runs one way only is the point of the question.

  </details>

- **MUST** — Vector clocks: detecting concurrency, and the cost

  <details><summary><strong>Answer</strong></summary>

  Each process keeps a vector of counters, one per process, increments its own entry on each event, and merges element-wise by maximum on receipt. Comparing two vectors gives the full answer: one dominates the other — every entry greater or equal, at least one greater — meaning causal order, or neither dominates, meaning genuinely concurrent, which is exactly the conflict a store needs to detect.

  **The cost is** that the vector grows with the number of participants and must be stored with every version and shipped with every message, which is why Dynamo-style systems prune old entries and why the technique does not scale to large client populations. That size problem is the reason the next bullet exists.

  </details>

- **MUST** — What a store does with the answer

  <details><summary><strong>Answer</strong></summary>

  Detecting concurrency is only useful if something acts on it: Dynamo and Riak return both siblings to the client and let the application merge — the shopping cart that unions items rather than losing one — while other stores pick a winner by rule and accept the loss. The alternative is to make merging unnecessary with a CRDT, which is why topics 26 and 27 are usually asked together.

  The complete answer therefore runs: physical clocks cannot order events, logical clocks detect concurrency, and then either the application merges, a rule discards, or the data type converges by construction.

  </details>

- **NICE** — Version vectors, dotted version vectors and the practical variants

  <details><summary><strong>Answer</strong></summary>

  A **version vector** is the same structure applied to replicas of a data item rather than to processes, which is the form actually used in storage systems, and **dotted version vectors** fix a real problem with it — sibling explosion when many clients write through a coordinator, by tagging each write with the specific event that produced it. Riak adopted them for exactly that reason.

  **Naming the variant is** a good depth signal, because it shows the topic is knowledge from implementations rather than from the original papers alone.

  </details>

- **NICE** — Hybrid logical clocks and TrueTime

  <details><summary><strong>Answer</strong></summary>

  **Hybrid logical clocks** combine a physical timestamp with a logical counter, so timestamps stay close to wall-clock time — which makes them human-readable and useful for time-range queries — while still respecting causality; CockroachDB and MongoDB use them.

  Spanner takes the opposite approach with **TrueTime**: atomic clocks and GPS give a bounded uncertainty interval, and a transaction waits out that interval before committing, buying externally consistent global ordering at the cost of a few milliseconds per commit and special hardware. Together they are the modern answer to the clock problem, and being able to contrast "wait out the uncertainty" with "track causality explicitly" shows the trade clearly.

  </details>

- **OPTIONAL** — Where this shows up outside databases

  <details><summary><strong>Answer</strong></summary>

  The same reasoning underlies distributed tracing spans, Git's commit graph as a causal partial order with merges as explicit reconciliation, causal message delivery in group communication, and debugging distributed systems from logs — where the first thing to distrust is the timestamp ordering across machines. Recognizing the pattern outside its original context is a good way to close the topic.

  </details>
