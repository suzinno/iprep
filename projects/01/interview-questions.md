# Interview Questions — Personalized Cancer Support Platform
> Auto-generated from CV and system design documents. Questions target stated responsibilities and technical pillars.

## Table of Contents
- [Database Engineering & SQL Optimization](#database-engineering--sql-optimization)
- [AI/ML Pipeline Engineering (LangChain, LangGraph, RAG)](#aiml-pipeline-engineering-langchain-langgraph-rag)
- [Cloud Infrastructure & Serverless (Azure)](#cloud-infrastructure--serverless-azure)
- [Containerization & CI/CD](#containerization--cicd)
- [Data Processing & Caching](#data-processing--caching)
- [Frontend Development (React & Webpack)](#frontend-development-react--webpack)
- [AI-Assisted Development & Testing](#ai-assisted-development--testing)

## Database Engineering & SQL Optimization

---

### Q1. What factors guided your choice of UUIDs over auto-incrementing integers as primary keys in the PostgreSQL schema?

**Brief answer**
UUIDs prevent sequential ID enumeration (a security concern with PHI) and support distributed ID generation without central coordination.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, patients, appointments, prescriptions, and documents all use UUID primary keys. The primary motivation is security — with auto-incrementing IDs, an attacker who sees `/patients/42` can trivially try `/patients/43` and enumerate records. In a HIPAA-regulated system handling Protected Health Information (PHI), this is unacceptable even with proper authorization checks, because it leaks information about how many records exist and their creation order.

The second driver is distributed ID generation. With multiple service instances running on Azure Kubernetes Service (AKS), each pod can generate UUIDs independently without coordinating with a sequence counter on PostgreSQL. This eliminates a potential bottleneck on write-heavy paths like wellbeing logging (~80 write QPS peak).

The trade-off is storage and index performance — UUIDs are 16 bytes versus 4 bytes for an integer, and random UUIDs cause B-tree index page splits because insertions are non-sequential. We mitigate this by using UUIDv7 (time-ordered) where available, which preserves chronological ordering and improves index locality. For tables like `wellbeing_entry` where we frequently scan by `(patient_id, entry_date DESC)`, the composite index dominates lookup performance regardless of the primary key type, so the UUID overhead is negligible in practice.

</details>

---

### Q1. Explain the role of `jsonb` columns in the patient schema. When would you choose `jsonb` over a normalized relational design?

**Brief answer**
`jsonb` is used for fields like `treatment_plan`, `symptoms`, and `vitals` where the schema varies significantly across patients and cancer types — normalizing these would require constant schema migrations.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, the `Patient` table stores `treatment_plan` as `jsonb`, and `WellbeingEntry` stores `symptoms` and `vitals` as `jsonb`. The reasoning is that treatment protocols vary dramatically by cancer type, stage, and institution. A lung cancer treatment plan has different fields than a breast cancer plan. If we normalized this into relational tables, every new cancer type or protocol update would require an Alembic migration, a deployment, and a schema review — unacceptable friction for a clinical team that needs to move fast.

`jsonb` is appropriate when: (1) the data is heterogeneous across rows, (2) you don't need foreign keys pointing into the nested structure, and (3) you still want to query into the data. PostgreSQL's `jsonb` supports GIN indexes, so queries like `WHERE symptoms @> '{"nausea": true}'` are indexed and performant.

The boundary is clear: structured data with referential integrity (appointments, prescriptions, messages) stays relational. Semi-structured data that varies by patient context uses `jsonb`. The anti-pattern would be putting everything in `jsonb` and losing the ability to enforce constraints — for example, `dosage` and `frequency` on prescriptions are always present, so they remain proper columns with NOT NULL constraints.

One gotcha: `jsonb` doesn't enforce schema at the database level. We compensate with Pydantic models in FastAPI that validate the JSON structure before it reaches the database, ensuring that a malformed `treatment_plan` is rejected at the API boundary, not discovered later in a reporting query.

</details>

---

### Q1. What is a composite B-tree index, and why does the column order matter?

**Brief answer**
A composite B-tree index covers multiple columns in a specified order. The leftmost column is the primary sort key — queries that don't filter on it typically can't use the index efficiently.

<details>
<summary><strong>Detailed answer</strong></summary>

In this project, the `wellbeing_entry` table has a composite index on `(patient_id, entry_date DESC)`. This index is structured as a B-tree sorted first by `patient_id`, then by `entry_date` in descending order within each patient. A query like `SELECT * FROM wellbeing_entry WHERE patient_id = ? ORDER BY entry_date DESC LIMIT 10` is an index-only scan (or very close to it) — it jumps to the patient's section of the tree and reads the first 10 entries without scanning the table.

Column order matters because a B-tree is a sorted structure. The index `(patient_id, entry_date)` can efficiently answer "all entries for patient X" or "all entries for patient X on date Y," but it cannot efficiently answer "all entries on date Y across all patients" — for that, you need a separate index on `(entry_date)`, which is exactly what we have for the analytics path.

A common mistake is creating an index `(entry_date, patient_id)` thinking it covers both access patterns. It doesn't — the dashboard query that fetches one patient's latest entries would need to scan every date partition in the index. The rule of thumb is: high-selectivity equality columns first, range/sort columns last.

In our case, the `appointment` table follows the same pattern with `(patient_id, scheduled_at)` for the patient view and `(provider_id, scheduled_at)` for the provider schedule view — two separate indexes because the leading column differs based on the access pattern.

</details>

---

### Q2. Walk me through how you would diagnose a slow SQL query in this platform. What tools and approaches would you use?

**Brief answer**
Start with `EXPLAIN ANALYZE` to see the actual execution plan, check for sequential scans on large tables, missing indexes, and bad row estimates. Correlate with Azure Monitor metrics for broader patterns.

<details>
<summary><strong>Detailed answer</strong></summary>

The diagnosis process follows a systematic funnel. First, identify the query — Azure Monitor (Application Insights) captures query duration via OpenTelemetry traces, so I can find the slow span in a distributed trace and extract the exact SQL.

Next, run `EXPLAIN ANALYZE` on the query against a representative dataset (staging, not production, to avoid adding load). Key things I'm looking for: (1) sequential scans on large tables like `wellbeing_entry` — this table grows at ~100K rows/day, so a full scan is catastrophic; (2) nested loop joins where a hash join would be more efficient; (3) bad row count estimates from the planner, which indicate stale statistics (fix with `ANALYZE`); (4) sorts that spill to disk because `work_mem` is too low for the intermediate result set.

In this project specifically, wellbeing trend queries use window functions (`LAG`, `AVG OVER`) rather than self-joins. A common issue is that the planner underestimates the cost of window functions over large partitions. The fix is usually to ensure the `(patient_id, entry_date)` index covers the window's `PARTITION BY` and `ORDER BY` clause, so the data arrives pre-sorted and the window function runs in streaming mode.

We also run `EXPLAIN ANALYZE` in CI for any migration that modifies queries touching over 10K rows. This catches regressions before they reach production — for example, an innocent-looking schema change that invalidates a partial index on `document_meta WHERE processing_status = 'pending'`. The CI check compares the plan against a baseline and fails if a sequential scan appears where an index scan was expected.

For production incidents, I'd also check pg_stat_statements for the query's historical performance (average time, calls, rows), check for lock contention via `pg_stat_activity`, and review if a recent deployment changed query patterns.

</details>

---

### Q2. You used materialized views for wellbeing dashboard aggregates. What are the trade-offs, and how did you handle refresh?

**Brief answer**
Materialized views pre-compute expensive aggregations for fast reads, but the data is stale between refreshes. We refresh hourly, which is acceptable for trend analytics but not for real-time data.

<details>
<summary><strong>Detailed answer</strong></summary>

The wellbeing dashboard shows aggregated data — average mood by week, symptom frequency over time, vitals trends. Computing these on every page load would mean running window functions and aggregations over potentially thousands of rows per patient. With ~15K daily active users (DAU), that's untenable on the primary database.

Materialized views pre-compute these aggregates. The view definition contains the full query (CTEs with window functions, GROUP BY week/month), and PostgreSQL stores the result as a physical table. Dashboard reads hit this table directly — it's fast and predictable.

The trade-off is staleness. We refresh hourly via a cron-triggered job (`REFRESH MATERIALIZED VIEW CONCURRENTLY`). The `CONCURRENTLY` keyword is critical — without it, the refresh takes an exclusive lock and blocks reads. With it, PostgreSQL builds the new data in the background and swaps it in atomically. The cost is that concurrent refresh requires a unique index on the materialized view.

Why hourly? The wellbeing dashboard shows trends over days and weeks. A 1-hour lag is invisible to the user. Real-time data (latest wellbeing entry) is served from Redis cache with a 5-minute TTL, not from the materialized view. This two-tier approach — Redis for "right now," materialized view for "over time" — gives us the best of both worlds.

One pitfall we avoided: refreshing materialized views on every write. Some teams trigger a refresh when new data arrives, but with ~80 write QPS, that would mean constant refresh operations competing for I/O. Hourly batch refresh amortizes the cost and runs on the read replica, keeping the primary free for writes.

</details>

---

### Q2. How do you approach optimizing a complex SQL statement that joins multiple tables with filtering and sorting?

**Brief answer**
Break it into parts: check if each join has an indexed path, push filters as close to the data as possible, use CTEs to avoid repeated subquery evaluation, and validate with `EXPLAIN ANALYZE`.

<details>
<summary><strong>Detailed answer</strong></summary>

A concrete example from this platform: the treatment timeline view joins `prescription`, `appointment`, and `wellbeing_entry` for a single patient, filtered by date range, sorted by date. The naive approach — a three-way JOIN with WHERE and ORDER BY — can result in the planner choosing a bad strategy (e.g., joining all appointments with all prescriptions before filtering by patient).

Step one: ensure each table's access is indexed. For this query, `prescription(patient_id, status)`, `appointment(patient_id, scheduled_at)`, and `wellbeing_entry(patient_id, entry_date)` all have composite indexes. The planner can use index scans to fetch only the relevant rows for one patient before joining.

Step two: use CTEs to isolate subqueries. We define a CTE for active prescriptions, another for appointments in the date range, and join the CTEs. This avoids the planner re-evaluating a correlated subquery for each row. In PostgreSQL 12+, CTEs can be inlined by the optimizer (`NOT MATERIALIZED`), so we sometimes add `MATERIALIZED` explicitly when we want to force the evaluation boundary.

Step three: push predicates down. If the WHERE clause filters by `patient_id` and `date_range`, those conditions should appear in each CTE, not just in the outer query. This reduces the intermediate result set before the join.

Step four: validate with `EXPLAIN ANALYZE`. Check that the join strategy is hash join (for equi-joins on UUIDs) rather than nested loop (which is quadratic for large inputs). Check that sorts use indexes rather than in-memory sorting. Check the actual row counts versus estimates — a 100x mismatch means the planner is guessing wrong.

Finally, consider if the query can be simplified by denormalization. If this timeline view is hit frequently, a materialized view or a denormalized summary table might be the right call — the same pattern we use for wellbeing aggregates.

</details>

---

### Q2. Explain partial indexes. Where did you use them in this project, and why?

**Brief answer**
A partial index only indexes rows matching a WHERE condition, keeping the index small and focused. We used one on `document_meta(processing_status) WHERE status = 'pending'` to accelerate the document processing queue lookup.

<details>
<summary><strong>Detailed answer</strong></summary>

The `document_meta` table tracks every document uploaded by patients. Over time, this table grows to millions of rows, but the Blob Processing Function only cares about documents with `processing_status = 'pending'` — typically a tiny fraction of the total. A full index on `processing_status` would include every row (including the vast majority that are `'completed'`), wasting storage and slowing down inserts.

A partial index `CREATE INDEX idx_doc_pending ON document_meta(processing_status) WHERE processing_status = 'pending'` includes only the rows that match. This index stays small regardless of table size — if there are 2 million completed documents and 50 pending ones, the index has 50 entries. The Blob Processing Function's query `SELECT * FROM document_meta WHERE processing_status = 'pending'` hits this tiny index and returns instantly.

The maintenance overhead is also reduced. Every INSERT or UPDATE that changes `processing_status` to `'pending'` adds to the index; every UPDATE that moves a row away from `'pending'` removes it. Since most documents move through the pipeline quickly (p95 < 60 seconds), the index stays small and write amplification is minimal.

Partial indexes are underused in my experience. Other candidates in this schema: an index on `message(recipient_id, is_read) WHERE is_read = false` for unread message counts — most messages are eventually read, so the partial index covering only unread ones would be much smaller. The key requirement is that your queries always include the WHERE predicate matching the partial index condition; otherwise the planner ignores it.

</details>

---

### Q3. If the wellbeing_entry table grows to hundreds of millions of rows, what partitioning strategy would you implement, and what are the operational implications?

**Brief answer**
Range-partition by `entry_date` (monthly). This enables efficient date-range queries, fast archival of old partitions, and keeps individual partition sizes manageable for vacuum and index operations.

<details>
<summary><strong>Detailed answer</strong></summary>

At ~100K patients logging daily, `wellbeing_entry` grows at ~36.5M rows/year. Within 3 years, we're looking at 100M+ rows. PostgreSQL's declarative partitioning by range on `entry_date` is the right move.

The implementation: a parent table `wellbeing_entry` with monthly child partitions (`wellbeing_entry_2026_01`, `wellbeing_entry_2026_02`, etc.). The `(patient_id, entry_date DESC)` index is created on each partition individually — PostgreSQL handles this automatically with partitioned indexes.

Why monthly? Monthly gives us 12 partitions/year, each around 3M rows. That's small enough for vacuum to complete quickly (a major operational concern — vacuum on a 100M-row table takes hours and holds resources). It's also granular enough for the archival strategy: HIPAA requires 6-year retention, so we keep 72 partitions hot and can detach older partitions to cold storage or archive tablespaces.

The date-range queries for analytics (`WHERE entry_date BETWEEN ? AND ?`) benefit from partition pruning — the planner only scans the relevant monthly partitions. The dashboard query (`WHERE patient_id = ? ORDER BY entry_date DESC LIMIT 10`) spans at most 1-2 partitions for active patients, since their latest entries are in recent months.

Operational implications: (1) Partition creation must be automated — a cron job or Alembic migration creates next month's partition before the month starts. Missing a partition means INSERT failures. (2) Indexes exist per-partition, so index maintenance is parallelizable. (3) `pg_stat_statements` reports per-partition, so monitoring needs adjustment. (4) If we later need to shard by `patient_id` (e.g., with Citus), we'd use composite partitioning (range on date, hash on patient_id) — but that's a 10x scale trigger, well beyond current projections.

The alternative — partitioning by `patient_id` — was considered but rejected. Date-range analytics queries would need to scan all partitions (one per patient would be millions of partitions — absurd). Date partitioning aligns with both access patterns: per-patient lookups are fast because the composite index within each partition covers them, and date-range analytics get partition pruning.

</details>

---

### Q3. How does the choice between strong consistency for PostgreSQL and eventual consistency for Cosmos DB affect your schema design and application code?

**Brief answer**
PostgreSQL's strong consistency means we can trust that reads after writes are always current — critical for PHI. Cosmos DB's session consistency requires the application to handle the case where a provider sees a slight delay on conversation updates.

<details>
<summary><strong>Detailed answer</strong></summary>

This is a deliberate CAP theorem positioning. PostgreSQL is our CP store — during a failover event (~30 seconds for Azure Database for PostgreSQL), writes are rejected rather than risk returning stale medical data. A patient's prescription must never show outdated dosage information because a read hit a lagging replica. The application code relies on this guarantee: after `UPDATE prescription SET dosage = '500mg'`, the next `GET /prescriptions` always returns the updated value. No retry loops, no "read your own writes" hacks needed.

Cosmos DB stores conversation history with session consistency. This means a patient always sees their own latest messages (the session token ensures read-your-writes for the same client). But a provider viewing the same conversation might see a few seconds of lag. In application code, this means:

1. The AI Assistant Service writes to Cosmos DB and returns the response to the patient in the same request — the patient sees their message immediately because the write completes before the SSE stream starts.
2. The provider dashboard uses a polling mechanism (or eventual push notification) that inherently tolerates a few seconds of delay. We don't make UI promises like "real-time" for provider views of conversations.

Schema design is affected too. In PostgreSQL, we can use foreign keys and rely on transactional integrity — creating an appointment and linking it to a prescription happens atomically. In Cosmos DB, we embed messages inside the conversation document (denormalized) because cross-document transactions are limited and expensive. This means updating a single message (e.g., adding citations after RAG completes) requires reading the entire conversation document, modifying the embedded message, and writing it back — a read-modify-write pattern that we guard with optimistic concurrency (using Cosmos DB's ETag).

The cost dimension matters too: Cosmos DB charges by Request Units (RUs), and strong consistency doubles RU consumption compared to session consistency. For a chatbot generating potentially hundreds of messages per conversation, that cost difference is significant — and the consistency guarantee isn't worth it for conversation data that has no medical-record-level criticality.

</details>

---

### Q3. The platform uses both PostgreSQL read replicas and Redis caching. How do these two strategies interact, and where does each shine?

**Brief answer**
Read replicas handle complex analytical queries that can't be cached (ad-hoc reporting, trend computation). Redis handles high-frequency, simple lookups where sub-millisecond latency matters (dashboards, session checks). They complement rather than compete.

<details>
<summary><strong>Detailed answer</strong></summary>

The distinction is about query complexity and access patterns. Redis is ideal for key-value lookups: "give me patient 42's profile" or "what's the latest wellbeing entry for patient 42." These are simple, frequent, and benefit enormously from sub-millisecond response times. The cache-aside pattern means the first request hits PostgreSQL and populates Redis; subsequent requests (within the TTL) skip the database entirely.

Read replicas handle the queries that Redis can't: "show me the average mood trend for patient 42 over the last 6 months with weekly granularity." This involves window functions, date arithmetic, and potentially joins with prescriptions. You can't cache this in Redis without building a secondary query engine — and the result set changes with every new wellbeing entry. The read replica offloads these analytical queries from the primary, keeping the primary's I/O budget free for writes.

The interaction points are important. When a patient logs a new wellbeing entry: (1) the write hits the PostgreSQL primary, (2) Redis cache for `patient:{id}:wellbeing:latest` is explicitly invalidated, (3) the read replica receives the write via streaming replication (typically < 1 second lag), and (4) the materialized view on the replica refreshes hourly. So the dashboard shows the latest entry from Redis (repopulated on next read) and the trend chart from the materialized view (up to 1 hour stale).

SQLAlchemy `bind_keys` configuration routes queries at the application level: methods decorated with `@readonly` go to the replica, everything else goes to the primary. This is implemented as a FastAPI dependency that selects the appropriate database session based on the endpoint's HTTP method — GETs use the replica, POSTs/PUTs/DELETEs use the primary. The exception is reads that must be consistent (e.g., reading a prescription immediately after updating it) — these are explicitly routed to the primary.

A failure scenario to consider: if Redis goes down, all cache misses hit the primary. At ~500 QPS peak, this spike could overwhelm it. The mitigation is that Azure Cache for Redis is zone-redundant, and the application degrades gracefully — slower but functional. If the read replica goes down, analytical queries fall back to the primary with reduced performance. Neither failure takes the system offline; they just shift load.

</details>

---

## AI/ML Pipeline Engineering (LangChain, LangGraph, RAG)

---

### Q1. What is Retrieval-Augmented Generation (RAG), and why is it used in this platform instead of fine-tuning a model on medical data?

**Brief answer**
RAG retrieves relevant documents at query time and provides them as context to the Large Language Model (LLM). It avoids fine-tuning costs, keeps knowledge updatable without retraining, and provides traceable citations — critical for medical accuracy.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, the AI Assistant answers patient questions about their diagnosis and treatment. Fine-tuning an LLM on medical literature would bake knowledge into model weights, making it impossible to update when new treatment guidelines are published — you'd need to retrain, which is expensive and slow. RAG solves this by keeping the knowledge external in Milvus vector collections (`medical_knowledge` for curated articles, `patient_documents` for personal uploads).

When a patient asks "What are common side effects of carboplatin?", the pipeline: (1) embeds the query into a 1536-dimensional vector, (2) performs a semantic search in Milvus to find the top-k (k=5) most relevant chunks, (3) constructs a prompt that includes these chunks as context, and (4) sends this augmented prompt to the LLM for generation. The response includes citations (`source_doc_id`, `chunk_id`) so the patient can verify the information.

The citation traceability is the killer feature for healthcare. A fine-tuned model might generate a correct answer, but you can't point to which source document it came from. With RAG, every claim maps back to a specific medical article or guideline. When a clinician reviews the AI's output, they can verify the source — this is a compliance requirement, not just a nice-to-have.

RAG also respects data boundaries. Patient-specific documents are in a separate Milvus collection (`patient_documents`), scoped by `patient_id`. The RAG query can combine results from both collections — general medical knowledge and the patient's own uploaded documents — without cross-patient data leakage. Fine-tuning would risk memorizing PHI from training data.

</details>

---

### Q1. What is LangGraph, and how does it differ from a simple LangChain chain?

**Brief answer**
LangGraph is a framework for building stateful, graph-based agent flows. Unlike a linear LangChain chain (A -> B -> C), LangGraph supports branching, loops, and conditional transitions — essential for complex conversational flows like escalation to human support.

<details>
<summary><strong>Detailed answer</strong></summary>

A LangChain chain is a sequential pipeline: retriever → prompt template → LLM → output parser. It works well for single-turn question-answering but breaks down when the flow has conditional logic. In this platform, the AI Assistant needs to: (1) retrieve context from Milvus, (2) assess confidence — if confidence is low, escalate to a human support agent instead of generating an answer, (3) if generating, stream tokens back, (4) persist the response with citations to Cosmos DB.

LangGraph models this as a directed graph where nodes are processing steps and edges are transitions. Nodes include: `retrieve` (Milvus search), `assess_confidence` (checks retrieval quality), `generate` (LLM call with streaming), `escalate` (routes to human support), and `persist` (writes to Cosmos DB). The edge from `assess_confidence` branches: if confidence > threshold, go to `generate`; otherwise, go to `escalate`. This branching is impossible in a linear chain.

LangGraph also provides built-in state management. The conversation state (accumulated messages, retrieved context, confidence scores) is passed through the graph as a typed state object. This matters for multi-turn conversations where the assistant needs to remember what was discussed earlier — the state accumulates across turns, and LangGraph's checkpointing can persist it between requests.

In our implementation, the graph execution is asynchronous — each node is an async function, and the graph runner handles the orchestration. This means the Milvus query and Cosmos DB context load can happen concurrently (parallel branches in the graph), reducing overall latency before the LLM call.

</details>

---

### Q2. How did you design the memory and context management strategy for the conversational agent? What happens when conversations grow very long?

**Brief answer**
Conversation history is stored in Cosmos DB and loaded per-request. For long conversations, we use a sliding window of recent messages plus a summarized prefix, keeping the LLM's context window within budget while preserving critical information.

<details>
<summary><strong>Detailed answer</strong></summary>

The challenge is that LLM context windows are finite (typically 4K-128K tokens depending on the model), but patient conversations can span weeks. A patient with a complex treatment plan might have dozens of exchanges with the AI Assistant, and each exchange needs access to prior context to avoid repetitive questions.

The strategy has three layers. First, the full conversation history lives in Cosmos DB, partitioned by `patient_id`. Every message (user and assistant) is persisted with timestamps and citations. This is the source of truth.

Second, when a new message arrives, the AI Assistant Service loads the conversation from Cosmos DB. If the conversation has fewer than ~20 messages, all are included in the LLM prompt. Beyond 20 messages, we apply a sliding window: the last 10 messages are included verbatim, and older messages are summarized into a condensed context block. The summarization itself is an LLM call (a cheaper, faster model) that produces a paragraph capturing key facts: the patient's diagnosis, treatment stage, previously discussed side effects, and any action items.

Third, the RAG context is injected alongside the conversation history. The LLM prompt structure is: system prompt → summarized conversation history → recent messages → retrieved document chunks → user's new question. This ensures the model has both conversational continuity and factual grounding.

The trade-off is between context fidelity and token cost/latency. Including all messages preserves nuance but is expensive and slow. The summarization approach loses some conversational subtlety but keeps the token budget predictable. We chose to summarize after 20 messages based on empirical testing — beyond that point, including raw messages added tokens without meaningfully improving response quality.

A critical implementation detail: the summary is cached in the Cosmos DB conversation document itself (as a `summary` field) and only regenerated when new messages push the conversation beyond the window threshold. This avoids re-summarizing on every request.

</details>

---

### Q2. How does the platform combine Milvus semantic search with LangChain for RAG? Walk through the data flow from document upload to query-time retrieval.

**Brief answer**
On upload, documents are processed by Azure Functions (OCR → chunking → embedding → indexed into Milvus). At query time, LangChain's retriever interface searches Milvus for semantically similar chunks and passes them to the LLM as context.

<details>
<summary><strong>Detailed answer</strong></summary>

The data flow has two phases: ingestion (write path) and retrieval (read path).

**Ingestion:** When a patient uploads a document, the Document Service writes it to Azure Blob Storage and publishes a `document.uploaded` event to Azure Service Bus. The Blob Processing Function (Azure Functions) picks up this event, reads the blob, and runs it through Azure AI Document Intelligence for OCR/text extraction. The extracted text is chunked (typically 500-token chunks with 50-token overlap to preserve context across boundaries), and each chunk is embedded using an embedding model (1536-dimensional vectors). The embeddings are indexed into the `patient_documents` Milvus collection with metadata: `patient_id`, `document_id`, `chunk_id`, `text_content`. Separately, the curated medical knowledge base is pre-indexed into the `medical_knowledge` collection through a batch pipeline.

**Retrieval:** When a patient sends a message to the AI Assistant, LangGraph's `retrieve` node executes a LangChain retriever. The retriever: (1) embeds the user's query using the same embedding model, (2) runs two Milvus searches in parallel — one against `medical_knowledge` (general medical info) and one against `patient_documents` filtered by `patient_id` (personal documents), (3) merges and re-ranks the results by relevance score, (4) returns the top-k chunks (k=5). These chunks become the context in the LLM prompt.

The Milvus index types are chosen deliberately: IVF_FLAT for `medical_knowledge` (moderate size, high recall is critical — we don't want to miss relevant medical guidelines) and HNSW for `patient_documents` (faster approximate search, since per-patient collections are small and speed matters more). The LangChain retriever abstraction makes this transparent to the rest of the pipeline — swapping index types or even the vector store doesn't require changing the LangGraph flow.

A subtle but important detail: the patient documents collection is scoped by `patient_id` in the Milvus filter expression, ensuring no cross-patient retrieval. This is a PHI isolation boundary enforced at the vector store level, not just the application level.

</details>

---

### Q2. What is the difference between IVF_FLAT and HNSW indexes in Milvus, and why did you choose different index types for different collections?

**Brief answer**
IVF_FLAT partitions vectors into clusters and does exhaustive search within relevant clusters (high recall, moderate speed). Hierarchical Navigable Small World (HNSW) builds a multi-layer graph for fast approximate search (very fast, slightly lower recall). We chose based on collection size and accuracy requirements.

<details>
<summary><strong>Detailed answer</strong></summary>

IVF_FLAT (Inverted File with Flat quantization) divides the vector space into `nlist` clusters using k-means. At query time, it identifies the `nprobe` closest clusters and performs exhaustive distance computation within them. With a moderate `nprobe` (e.g., 10-20% of `nlist`), you get high recall — important for the `medical_knowledge` collection where missing a relevant treatment guideline could mean providing incomplete medical advice. The trade-off is speed: each query scans more vectors than HNSW.

HNSW builds a proximity graph with multiple layers. The top layers contain few, well-connected nodes for coarse navigation; lower layers add more nodes for fine-grained search. Query time is logarithmic in the dataset size — very fast for small to medium collections. We use HNSW for `patient_documents` because: (1) per-patient document collections are small (a patient might have 20 documents × 10 chunks = 200 vectors), so the speed advantage of HNSW is more noticeable than recall differences, and (2) the Milvus query already filters by `patient_id`, reducing the search space dramatically.

For `medical_knowledge` (~5M vectors from 500K articles × 10 chunks), IVF_FLAT gives us the recall guarantee we need. The latency difference at this scale (IVF_FLAT ~50ms vs HNSW ~20ms) is absorbed by the much larger LLM generation time, so it doesn't impact the overall 2-second first-token Service Level Objective (SLO).

A common mistake is choosing HNSW everywhere because it's faster. For high-stakes retrieval (medical, legal), IVF_FLAT's higher recall at the cost of milliseconds is the right trade-off. You can tune IVF_FLAT's recall/speed by adjusting `nprobe` — we run recall benchmarks during the knowledge base ingestion pipeline and set `nprobe` to achieve >95% recall against a golden test set.

</details>

---

### Q3. How would you handle a scenario where the LLM provider experiences an outage while patients are actively using the AI Assistant?

**Brief answer**
A circuit breaker pattern detects consecutive LLM failures and trips open after 5 failures. The AI Assistant falls back to a degraded mode — it can still retrieve relevant documents from Milvus and display them with a "summarization temporarily unavailable" notice.

<details>
<summary><strong>Detailed answer</strong></summary>

The AI Assistant has a circuit breaker on LLM provider calls, implemented via Python's `tenacity` or `circuitbreaker` library. After 5 consecutive failures (timeouts, 5xx responses), the circuit opens and no LLM calls are attempted for 30 seconds. During the half-open phase, a single request is sent to test recovery.

When the circuit is open, the LangGraph flow branches differently. The `generate` node is skipped, and instead the flow routes to a `degraded_response` node that: (1) returns the retrieved Milvus chunks directly to the patient, formatted as "Here are relevant articles about your question," (2) adds a banner: "Our AI summarization is temporarily unavailable. The information below is sourced from verified medical content," (3) logs the degradation event for monitoring.

This is better than showing an error page for several reasons. The patient still gets value — the RAG retrieval step (Milvus search) is independent of the LLM provider. The most useful part of the pipeline (finding relevant medical information) still works. What's lost is the natural language synthesis, which is a convenience, not the core value proposition.

For a secondary failover, the architecture supports configuring a backup LLM provider. Azure OpenAI Service is the primary (covered under the Azure HIPAA BAA), with Anthropic Claude as a fallback. The challenge is prompt compatibility — system prompts, output format instructions, and token limits differ between providers. We maintain provider-specific prompt templates and test both in CI to ensure consistent output quality. The circuit breaker can be configured to try the secondary provider before entering full degraded mode.

The monitoring dimension matters too. An LLM outage that lasts more than 5 minutes triggers a PagerDuty alert. The error budget for AI Assistant availability is tracked separately from the overall platform SLO (99.9%), because the AI component has more external dependencies and a more forgiving SLO (99.5%).

</details>

---

### Q3. How did you implement asynchronous and event-driven execution flows in LangGraph? What challenges arise with streaming responses in an async pipeline?

**Brief answer**
LangGraph nodes are async Python coroutines orchestrated by the graph runner. The challenge with streaming is that we need to emit tokens to the client (via Server-Sent Events) while the pipeline is still running — requiring careful coordination between the generation node and the HTTP response.

<details>
<summary><strong>Detailed answer</strong></summary>

The LangGraph execution is fully async. Each node (`retrieve`, `assess_confidence`, `generate`, `persist`) is an `async def` function. The graph runner (LangGraph's `CompiledGraph.astream()`) executes nodes according to the graph topology, respecting dependencies. Nodes without data dependencies (e.g., loading conversation context from Cosmos DB and querying Milvus) are run concurrently using `asyncio.gather()` semantics within the graph.

The streaming challenge is specific to the `generate` node. The LLM provider returns tokens one at a time (via streaming API). These tokens must be forwarded to the client as Server-Sent Events (SSE) in real-time — the patient sees text appearing incrementally, keeping perceived latency under 2 seconds for the first token. But the LangGraph flow isn't done when streaming starts: after all tokens are emitted, the `persist` node must save the complete response (with citations) to Cosmos DB.

The implementation uses an async generator pattern. The `generate` node yields tokens as they arrive from the LLM. The FastAPI endpoint wraps this in a `StreamingResponse` that emits each token as an SSE event. Simultaneously, the node accumulates the full response text. When the LLM signals completion, the generator yields a final event (with citation metadata), and then the LangGraph flow transitions to the `persist` node.

A subtle issue is error handling during streaming. If the LLM fails mid-stream (connection drops after 50 tokens), we've already sent partial content to the client. The approach is: (1) send an SSE error event so the frontend can display a retry option, (2) do NOT persist the partial response to Cosmos DB (it would corrupt the conversation history), (3) increment the circuit breaker failure counter. The frontend handles this by showing the partial text with an "Answer interrupted — tap to retry" affordance.

Backpressure is another concern. If the client disconnects mid-stream (patient closes the browser), FastAPI detects the closed connection and cancels the async generator. This propagates through LangGraph as a task cancellation, preventing the LLM call from consuming tokens and money for a response nobody will read. We implemented this with `asyncio.CancelledError` handling in each node.

</details>

---

### Q3. If you needed to scale the RAG pipeline to 10x the current query volume (500 AI queries/second), what architectural changes would you make?

**Brief answer**
Milvus horizontal scaling (more query nodes), embedding computation moved to a GPU-backed service with batching, response caching for common medical queries, and potentially pre-computing answers for the top-N most asked questions.

<details>
<summary><strong>Detailed answer</strong></summary>

At 50 QPS the current architecture works: Milvus on AKS with 2+ query nodes handles retrieval, and the LLM provider manages generation. At 500 QPS, several components hit limits.

**Milvus scaling:** Milvus separates query nodes from data nodes. We'd scale query nodes horizontally — each query node loads collection segments into memory and handles searches independently. For `medical_knowledge` (5M vectors), the segments are replicated across query nodes so each can serve requests independently. The bottleneck shifts to memory: 5M × 1536-dim × 4 bytes ≈ 30 GB per replica. At 500 QPS with 50ms per query, we'd need ~25 query nodes to maintain throughput (assuming each node handles ~20 concurrent queries).

**Embedding computation:** At 500 QPS, embedding the user's query adds up. If embedding takes 20ms on CPU, that's 10 QPS per embedding instance — we'd need 50 instances. Moving to GPU-backed embedding with batching (collecting multiple queries and embedding them in a single batch) dramatically improves throughput. An embedding service on AKS with a T4 GPU can handle ~500 embeddings/second with batch size 32.

**Response caching:** Many patients ask similar questions ("What are side effects of chemotherapy?"). We can cache RAG responses keyed by the semantic hash of the query (embedding similarity > 0.98 to a cached query = cache hit). This bypasses both Milvus retrieval and LLM generation for common questions. The cache must be scoped carefully — queries that reference patient-specific context (personal documents) are never cached, only general medical queries.

**LLM provider:** This is likely the bottleneck. At 500 QPS with ~2 second generation time per response, we'd need 1000 concurrent LLM calls. This requires either a high-throughput LLM provider tier, self-hosted models (which introduces GPU infrastructure complexity), or a hybrid where common questions use a smaller, faster model and complex ones use the full model. The cost at 500 QPS is substantial — optimizing token usage (shorter system prompts, fewer retrieved chunks for high-confidence queries) becomes critical.

**Pre-computation:** For the top 1000 most-asked medical questions (determined from query logs), pre-compute and store answers with citations. These become a "fast path" that bypasses the entire RAG pipeline — a simple lookup in Redis or PostgreSQL. This handles the head of the query distribution, leaving the RAG pipeline for the long tail.

</details>

---

## Cloud Infrastructure & Serverless (Azure)

---

### Q1. What is the difference between running a workload on Azure Kubernetes Service (AKS) versus Azure Functions? How did you decide which services go where?

**Brief answer**
AKS hosts long-lived services needing persistent connections, in-memory state, and predictable latency. Azure Functions handles event-triggered, bursty workloads that benefit from scale-to-zero. The decision is driven by the workload's execution pattern.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, four services run on AKS (Patient Service, AI Assistant Service, Document Service, Notification Service) and two run as Azure Functions (Blob Processing Function, Event Processing Function). The split follows a clear principle.

AKS services need: (1) persistent HTTP connections — the AI Assistant uses SSE streaming, which requires holding a connection open for seconds while tokens arrive. Azure Functions' HTTP trigger has a 230-second timeout and cold starts of 2-5 seconds, which would violate the 2-second first-token SLO. (2) In-memory caching and connection pooling — services maintain SQLAlchemy connection pools to PostgreSQL and Redis clients. Functions create and destroy these on each invocation (unless using premium plan with pre-warmed instances). (3) Predictable latency — CRUD operations must respond within 300ms at p95. Cold starts are unacceptable for user-facing API calls.

Azure Functions handle: (1) the Blob Processing Function, triggered when a `document.uploaded` event arrives on Service Bus. This workload is inherently bursty — a patient might upload 10 documents at once, then nothing for days. Functions scale horizontally to handle the burst and scale to zero when idle, saving cost. (2) The Event Processing Function for analytics aggregation, which processes `wellbeing.logged` events in batches.

The cost equation is also a factor. AKS has a minimum cost (at least 2 replicas per service for availability, across 2 availability zones). Functions on the consumption plan cost nothing when idle. For the document processing workload (~20 documents per patient, sporadic uploads), running a dedicated AKS service would waste ~90% of its compute budget on idle time.

</details>

---

### Q1. What is Azure Service Bus, and how does it differ from a simple message queue?

**Brief answer**
Azure Service Bus is an enterprise message broker supporting both queues (point-to-point) and topics with subscriptions (pub/sub). Unlike a simple queue, it provides dead-letter queues (DLQs), message sessions, at-least-once delivery, and scheduled delivery.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, Service Bus uses the topics/subscriptions model (pub/sub). When the Document Service publishes a `document.uploaded` event, both the Blob Processing Function and the Notification Service can receive it — each has its own subscription on the topic. With a simple queue, you'd need to publish the message twice or build a fan-out mechanism yourself.

Dead-letter queues are critical for reliability. If the Blob Processing Function fails to process a document after 5 attempts (max delivery count), the message moves to the DLQ instead of being discarded. We retain DLQ messages for 14 days, giving the ops team time to investigate and replay. This is especially important for healthcare — losing a patient's document upload event means their medical records never get indexed for RAG, silently degrading the AI Assistant's usefulness for that patient.

At-least-once delivery means consumers must be idempotent. If the Blob Processing Function processes a document and crashes before acknowledging the message, Service Bus redelivers it. The function must handle this by checking if the document is already indexed in Milvus (using `document_id` as an idempotency key) before re-processing.

We chose Service Bus over RabbitMQ because of native Azure integration. Azure Functions can bind directly to Service Bus triggers, and the messages carry trace context for OpenTelemetry distributed tracing. Self-hosting RabbitMQ on AKS would add operational burden (cluster management, monitoring, upgrades) without material benefits at this scale.

</details>

---

### Q2. How did you design the serverless workload for document processing with Azure Functions? What happens when a large batch of documents is uploaded?

**Brief answer**
The Blob Processing Function is triggered by Service Bus messages (not directly by blob triggers). For large batches, Service Bus naturally distributes messages across multiple Function instances, scaling horizontally. Each function instance processes one document independently.

<details>
<summary><strong>Detailed answer</strong></summary>

The architecture is: Document Service → writes blob to Azure Blob Storage → publishes `document.uploaded` event to Service Bus → Blob Processing Function is triggered. We deliberately chose Service Bus triggers over blob triggers. Blob triggers in Azure Functions have known issues with reliability — they use a polling mechanism that can miss blobs or process them with significant delay. Service Bus triggers are push-based and reliable.

When a patient uploads 10 documents simultaneously, the Document Service publishes 10 `document.uploaded` messages to Service Bus in quick succession. Azure Functions scales out by instantiating multiple instances of the Blob Processing Function, each pulling messages from the subscription. The `maxConcurrentCalls` setting (we set it to 5 per instance) controls how many messages each instance processes in parallel. At default scaling, Functions can spin up dozens of instances within seconds.

Each function execution: (1) reads the message to get the blob path and patient_id, (2) downloads the blob from Azure Blob Storage, (3) sends it to Azure AI Document Intelligence for OCR, (4) chunks the extracted text, (5) generates embeddings, (6) indexes the chunks into Milvus's `patient_documents` collection, (7) updates `document_meta.processing_status` to `'completed'` in PostgreSQL.

For very large batches (e.g., a clinic migrating a patient's historical records — potentially hundreds of documents), we use Azure Blob Storage batch operations to invoke Functions at scale. The concern here is downstream pressure: hundreds of concurrent function instances all hitting Milvus and PostgreSQL simultaneously. We mitigate this with: (1) the `maxConcurrentCalls` throttle, (2) exponential backoff on Milvus writes with retry, and (3) PostgreSQL connection limits enforced by Azure Database for PostgreSQL (which rejects connections beyond the configured max, causing the function to retry).

The idempotency design is essential. Each function checks `document_meta.processing_status` before processing — if it's already `'completed'`, the function acknowledges the message and returns. This handles Service Bus redeliveries after partial failures without reindexing documents.

</details>

---

### Q2. Explain how you managed networking in AKS, including ingress controllers, load balancers, and secure service communication.

**Brief answer**
NGINX Ingress Controller routes external traffic from Azure API Management to services. Internal service-to-service communication uses ClusterIP services with mTLS enforced by the service mesh. Calico network policies restrict pod-to-pod traffic to declared dependencies.

<details>
<summary><strong>Detailed answer</strong></summary>

The networking architecture has three layers: external ingress, service mesh (internal), and network policies (restrictions).

**External ingress:** Azure API Management is the public entry point, handling JWT validation and rate limiting. APIM connects to AKS via an NGINX Ingress Controller deployed in the cluster. The ingress controller maps URL paths to Kubernetes services: `/patients/*` → Patient Service, `/assistant/*` → AI Assistant Service, `/documents/*` → Document Service. The ingress controller terminates TLS (using a certificate from cert-manager backed by Let's Encrypt) and forwards plain HTTP to pods. However, the service mesh re-encrypts this traffic via mTLS, so no unencrypted traffic flows between pods.

**Service mesh (mTLS):** We use Istio (or Linkerd, depending on operational preference) to enforce mutual TLS (mTLS) between all pods. Every pod gets a sidecar proxy that handles TLS termination and origination. Certificates are auto-rotated by cert-manager. This means even if an attacker gains access to the cluster network, they can't sniff traffic between the Patient Service and PostgreSQL — it's encrypted. For a HIPAA-regulated system, mTLS for service-to-service communication is a compliance requirement, not an optimization.

**Network policies:** Calico network policies act as a firewall at the pod level. Each service has a policy declaring which other services it can communicate with. For example, Patient Service can reach PostgreSQL and Redis but not Milvus (it has no reason to query the vector store). AI Assistant Service can reach Milvus, Cosmos DB, and Redis but not PostgreSQL directly. This limits the blast radius of a compromised pod — if an attacker exploits the Notification Service, they can't pivot to the database because the network policy blocks it.

**Private endpoints:** The data tier (PostgreSQL, Cosmos DB, Redis, Blob Storage) uses Azure Private Endpoints. These services have no public IP; they're accessible only through the Azure virtual network. AKS pods reach them through VNet integration. This eliminates an entire class of attacks — you can't probe PostgreSQL from the internet because it has no internet-facing endpoint.

</details>

---

### Q3. How would you handle a scenario where an Azure Function triggered by Service Bus keeps failing, and messages are piling up in the dead-letter queue?

**Brief answer**
Investigate the DLQ messages to identify the failure pattern (bad payload, downstream outage, code bug). Fix the root cause, then replay DLQ messages using a dedicated replay function. Never increase max delivery count as a first response.

<details>
<summary><strong>Detailed answer</strong></summary>

The first step is diagnosis, not remediation. Dead-lettered messages contain the original payload plus metadata: `DeadLetterReason`, `DeadLetterErrorDescription`, and the delivery count. I'd query the DLQ using the Service Bus Explorer (or `az servicebus` CLI) to categorize failures.

Common patterns: (1) **Downstream outage** — Milvus or PostgreSQL is unreachable, so every processing attempt fails. The fix is to restore the downstream service, then replay DLQ messages. (2) **Poison message** — a specific document causes a crash (e.g., a corrupted PDF that crashes the OCR service). This message fails 5 times and dead-letters, but other messages process fine. The fix is to handle the specific failure gracefully (try/except around OCR, mark the document as `processing_failed` in PostgreSQL, notify the patient). (3) **Code bug** — a recent deployment introduced a regression. The fix is to roll back the Function deployment, then replay.

For replay, we have a dedicated `DLQReplayFunction` that reads messages from the DLQ and re-publishes them to the main topic. This function runs manually (triggered by an operator) after the root cause is fixed. It processes messages one at a time with a delay between messages to avoid overwhelming the downstream services.

A critical consideration: during a downstream outage, new messages also pile up in the main subscription (they'll retry and eventually dead-letter too). The max delivery count of 5 with Service Bus's exponential backoff means messages are retried over ~2-3 minutes before dead-lettering. If the outage lasts longer, you'll have a growing DLQ. The mitigation is to monitor the DLQ depth as a metric in Azure Monitor and alert when it exceeds a threshold (e.g., >50 messages). This gives the ops team time to intervene before the DLQ grows unmanageable.

What I would NOT do: increase `maxDeliveryCount` to 20 hoping the downstream service recovers. This just delays the dead-lettering and wastes compute on retries. The right approach is to fix the root cause and replay, not to brute-force through transient failures.

</details>

---

### Q3. The platform uses Azure Blob Storage lifecycle policies to tier documents from hot to cool to archive. How does this interact with the RAG pipeline, and what happens when a patient needs to access an archived document?

**Brief answer**
The lifecycle policy moves original blobs through tiers, but the extracted text and embeddings in Milvus remain in the hot tier permanently. Accessing an archived original document requires a rehydration step (hours), so the system serves the extracted text from Milvus immediately and queues the original for rehydration.

<details>
<summary><strong>Detailed answer</strong></summary>

The lifecycle policy is: hot tier for 90 days → cool tier for 1 year → archive tier after 1 year. This applies to the original document blobs in `medical-documents/{patient_id}/{document_id}/`. The processed text in `processed/{patient_id}/{document_id}/extracted.json` follows a separate policy (kept in hot tier for 1 year, then cool — never archived, since it's small and frequently useful).

The key insight is that the RAG pipeline doesn't need the original blob. Once the Blob Processing Function extracts text and indexes embeddings into Milvus, the AI Assistant queries Milvus for semantic search — the original PDF is irrelevant to RAG. So tiering the original blob has zero impact on AI Assistant functionality.

The challenge comes when a patient wants to download the original document (e.g., sharing a lab report with a new doctor). If the document is in the hot or cool tier, the download is immediate (cool tier has slightly higher latency, ~10ms vs ~1ms, but imperceptible to users). If it's in the archive tier, Azure requires a rehydration request, which takes up to 15 hours for standard priority or up to 1 hour for high priority.

Our application handles this: (1) The Document Service checks the blob's access tier before attempting download. (2) If archived, it returns a 202 Accepted response with a message: "Your document is being retrieved. You'll be notified when it's ready." (3) It submits a rehydration request (high priority) and publishes a `document.rehydration.requested` event. (4) A separate Azure Function polls the blob's rehydration status and, once complete, sends a notification to the patient. (5) Meanwhile, the patient can view the extracted text version immediately.

Cost optimization is the motivation. Blob Storage archive tier costs ~$0.002/GB/month versus ~$0.02/GB/month for hot. With 12 TB projected over 5 years, and most of it being documents older than 1 year, the savings are significant. HIPAA requires 6-year retention, so we can't delete — tiering is the cost management strategy.

</details>

---

## Containerization & CI/CD

---

### Q1. What makes a Docker image "optimized"? What techniques did you use for writing optimized Dockerfiles?

**Brief answer**
Multi-stage builds to separate build dependencies from runtime, minimal base images (e.g., `python:3.12-slim`), layer ordering for cache efficiency, and avoiding unnecessary files via `.dockerignore`.

<details>
<summary><strong>Detailed answer</strong></summary>

In this project, each FastAPI service has a multi-stage Dockerfile. The first stage (`builder`) installs build tools and compiles dependencies (some Python packages like `cryptography` need C compilation). The second stage (`runtime`) copies only the installed packages and application code from the builder, without the compiler toolchain. This reduces the final image size from ~1.2 GB to ~300 MB.

Layer ordering matters for build cache efficiency. Docker caches layers and invalidates from the first changed layer downward. We structure Dockerfiles as: (1) base image, (2) system dependencies (`apt-get`), (3) copy `requirements.txt` and install Python packages, (4) copy application code. Since application code changes far more frequently than dependencies, steps 1-3 are cached on most builds. A naive Dockerfile that copies everything first (`COPY . .`) invalidates the dependency installation layer on every code change, adding minutes to each build.

`.dockerignore` excludes test files, documentation, `.git`, `__pycache__`, and local configuration — all unnecessary in the runtime image and a security risk (test fixtures might contain sample PHI data).

Security hardening: we run the application as a non-root user (`USER appuser`), drop all Linux capabilities, and use `--no-cache-dir` with pip to avoid storing package tarballs in the image. The CI pipeline runs Trivy to scan for vulnerabilities in both the base image and installed packages. Images with critical CVEs (Common Vulnerabilities and Exposures) fail the build.

For Docker Compose in local development, we use volume mounts for application code (so changes are reflected without rebuilding) and override the entrypoint to include hot-reload (`uvicorn --reload`). The production Dockerfile uses `gunicorn` with `uvicorn` workers for process management — a key difference from the dev configuration.

</details>

---

### Q1. What are pre-commit hooks, and which ones did you configure in this project?

**Brief answer**
Pre-commit hooks are scripts that run automatically before each `git commit`, rejecting the commit if checks fail. We configured `black` (formatting), `ruff` (linting), `mypy` (type checking), `bandit` (security scanning), and `pytest` for changed files.

<details>
<summary><strong>Detailed answer</strong></summary>

Pre-commit hooks use the `pre-commit` framework (a Python tool that manages git hook scripts). When a developer runs `git commit`, the framework intercepts the commit, runs the configured hooks on staged files, and blocks the commit if any hook fails. This shifts quality checks left — issues are caught on the developer's machine, not in CI where the feedback loop is much longer.

Our hook configuration: (1) `black` — enforces consistent code formatting. No debates about style in code reviews; the formatter is the authority. (2) `ruff` — a fast Python linter that catches common errors (unused imports, undefined variables, style violations). It replaces flake8 and isort with a single, Rust-based tool that runs in milliseconds. (3) `mypy` — static type checking. With Pydantic models throughout the FastAPI services, mypy catches type mismatches between API schemas and database models before runtime. (4) `bandit` — security-focused static analysis. It flags common security issues like hardcoded passwords, use of `eval()`, and insecure cryptographic practices. Critical for a HIPAA platform. (5) `pytest` — runs unit tests for changed files only (using `--co` to collect and filter). This keeps the hook fast (a few seconds) while still catching regressions.

The hooks run only on staged files, not the entire codebase. This keeps them fast — a commit that changes 3 files runs checks on those 3 files, not the entire project. Full-project checks run in CI.

A practical consideration: hooks must be fast (< 30 seconds) or developers skip them with `--no-verify`. We keep the pytest hook limited to unit tests (no integration tests that need database connections). Integration tests run in CI where the full infrastructure is available.

</details>

---

### Q2. How did you configure the CI/CD pipeline for deploying services to AKS? Walk through the stages.

**Brief answer**
GitHub Actions handles CI (lint, test, build, security scan). Azure DevOps handles CD (deploy to staging, smoke tests, manual approval gate, canary rollout to production at 10% → 50% → 100%).

<details>
<summary><strong>Detailed answer</strong></summary>

The pipeline has two halves, split across two systems for a deliberate reason: GitHub Actions integrates natively with the code repository for fast CI feedback, while Azure DevOps provides enterprise deployment features (approval gates, environment-specific secrets, audit trails) that GitHub Actions lacks at the same maturity level.

**CI (GitHub Actions):** Triggered on every push to a feature branch and on pull request creation. Stages run sequentially: (1) Pre-commit hooks (black, ruff, mypy, bandit) validate code quality. (2) Unit and integration tests run in parallel — pytest for backend, React Testing Library for frontend. Integration tests use Docker Compose to spin up PostgreSQL, Redis, and Milvus containers as test dependencies. (3) Docker build (multi-stage) produces the production image. (4) Trivy scans the image for vulnerabilities. The build fails on critical/high CVEs.

**CD (Azure DevOps):** Triggered when CI passes on the main branch (after PR merge). (1) The Docker image is pushed to Azure Container Registry (ACR). (2) Helm chart is updated with the new image tag. (3) Deployment to the staging AKS namespace — a full replica of production with synthetic test data. (4) Automated smoke tests validate core flows: patient registration, wellbeing logging, AI assistant query, document upload. (5) Manual approval gate — a team lead reviews the staging deployment and smoke test results before promoting to production. (6) Canary rollout: Azure API Management routes 10% of production traffic to the new version. Automated monitoring watches for 15 minutes — if error rate exceeds 1% or p95 latency exceeds 500ms, the canary is automatically rolled back. (7) Progressive rollout: 10% → 50% → 100%, with health checks at each stage.

Alembic database migrations run as a pre-deployment step in the CD pipeline. They execute against the production database before the new application code is deployed. This means migrations must be backward-compatible — the old code must still work with the new schema during the rollout window.

</details>

---

### Q2. What common issues have you encountered in CI/CD pipelines, and how did you diagnose and resolve them?

**Brief answer**
Flaky tests (timing-dependent integration tests), Docker layer cache invalidation (slow builds), secret rotation mismatches (expired credentials), and Helm chart version conflicts during concurrent deployments.

<details>
<summary><strong>Detailed answer</strong></summary>

**Flaky integration tests:** Tests that pass locally but fail intermittently in CI. The root cause is usually timing — a test expects a database record to exist immediately after an async event, but the Service Bus consumer hasn't processed it yet. Diagnosis: re-run the test 10 times locally and in CI; check if the failure correlates with load or timing. Fix: add explicit waits with polling (not `sleep`) in integration tests that depend on async flows, or restructure the test to verify the synchronous part and test the async consumer separately.

**Docker cache misuse:** A CI pipeline that rebuilds from scratch on every run because the GitHub Actions cache wasn't configured for Docker layers. Diagnosis: check CI logs for which layers were rebuilt. Fix: use `docker/build-push-action` with `cache-from: type=gha` to persist layer cache across runs. For this project, caching the pip install layer (which rarely changes) saves 3-5 minutes per build.

**Secret rotation failures:** Azure DevOps pipelines use service connections to authenticate with ACR and AKS. When Azure AD credentials rotate (every 90 days by default), the pipeline fails with authentication errors. Diagnosis: the error message says "401 Unauthorized" on the Docker push or kubectl apply step. Fix: use managed identities instead of service principal secrets — they auto-rotate. For service principals that must remain, set up alerts 14 days before expiry.

**Helm version conflicts:** Two PRs merged in quick succession, both modifying the Helm chart. The second deployment uses a stale chart because the CD pipeline cached the chart from the first deployment. Diagnosis: the deployed pods have the first PR's configuration, not the second's. Fix: always pull the latest chart from the repository as the first CD step, never rely on cached charts. Use Helm `--atomic` flag to automatically rollback if the deployment fails, preventing partial upgrades.

**Alembic migration ordering:** Two developers create migrations on separate branches. When both merge, Alembic's linear history breaks (two migrations claim the same parent). Diagnosis: `alembic check` fails in CI. Fix: one developer rebases their migration to chain after the other's. We added a CI check that runs `alembic check` before tests to catch this early.

</details>

---

### Q3. How do canary deployments work in your AKS setup, and what metrics trigger an automatic rollback?

**Brief answer**
Azure API Management routes a percentage of traffic to canary pods based on a weighted routing rule. Automatic rollback triggers if error rate exceeds 1% or p95 latency exceeds 500ms during the 15-minute observation window.

<details>
<summary><strong>Detailed answer</strong></summary>

The canary deployment leverages two AKS deployment objects: the stable deployment (current production version) and the canary deployment (new version). Both run in the same namespace with different labels (`version: stable` and `version: canary`). Two Kubernetes services point to each set of pods.

Azure API Management handles the traffic split. A policy on each API operation uses a weighted backend pool: initially 90% to stable, 10% to canary. This is configured via APIM policy XML (or Bicep/Terraform for infrastructure-as-code). The split happens at the request level, not the connection level — so a single patient might get some requests served by stable and others by canary within the same session. This is acceptable for our stateless API design (session state is in Redis, not in-memory).

During the 15-minute observation window, Azure Monitor tracks three SLIs per backend: (1) error rate (5xx responses) — threshold: 1%. For medical applications, even a 1% error rate is aggressive; incorrect information or failed wellbeing logging could affect patient trust. (2) p95 latency — threshold: 500ms. The normal SLO is 300ms, so 500ms is a generous buffer for canary. (3) Pod restart count — if canary pods crash-loop, the deployment is fundamentally broken.

An Azure Monitor alert rule evaluates these metrics every minute. If any threshold is breached, the alert triggers an Azure DevOps webhook that: (1) sets the APIM routing to 100% stable (removing canary traffic), (2) scales the canary deployment to 0 replicas, (3) creates a PagerDuty incident with the specific metric that triggered the rollback, and (4) marks the Azure DevOps release as "failed."

The progressive rollout (10% → 50% → 100%) uses the same mechanism with increasing weight. At each step, the 15-minute observation window resets. The total rollout takes ~45 minutes minimum. For critical fixes, we have a "fast-track" option that skips canary and deploys directly — but this requires explicit approval from two team leads and is used only for security patches.

A subtlety: database migrations run before the canary starts. This means both stable and canary pods must work with the new schema. If the migration is breaking (e.g., dropping a column), we use a two-phase approach: first migration adds the new column (backward-compatible), deploy new code, then a follow-up migration removes the old column.

</details>

---

## Data Processing & Caching

---

### Q1. What is the cache-aside pattern, and why was it chosen over write-through for this platform?

**Brief answer**
Cache-aside (lazy loading) populates the cache on read misses, not on writes. It was chosen because many writes (audit logs, status changes) don't correspond to cached entities, making write-through wasteful.

<details>
<summary><strong>Detailed answer</strong></summary>

In cache-aside, the application checks Redis first for the requested data. On a cache miss, it reads from PostgreSQL, writes the result to Redis with a TTL, and returns it. On a cache hit, it returns the Redis value directly. On writes, the application updates PostgreSQL and explicitly deletes the Redis key — the cache is not updated, just invalidated. The next read will repopulate it.

Write-through updates the cache on every write, ensuring the cache is always current. The problem in our platform is that many writes don't map to cached data. For example, creating an audit log entry (required for HIPAA compliance on every PHI access) is a write to PostgreSQL, but nobody caches audit logs. Updating `document_meta.processing_status` from `'pending'` to `'completed'` is a write, but we don't cache document processing status. If we used write-through, we'd need logic to determine which writes should update the cache — essentially duplicating the cache-aside decision logic.

Cache-aside also handles cache failures gracefully. If Redis goes down, reads fall through to PostgreSQL — slower but functional. With write-through, a Redis failure could block writes (do you fail the write if the cache update fails? or write to DB without updating the cache, making it stale?).

The explicit invalidation on writes is the critical detail. When `update_patient_profile()` runs, it first updates PostgreSQL, then deletes `patient:{id}:profile` from Redis. The deletion ensures the next read gets fresh data. The order matters: update DB first, then invalidate cache. If we invalidated first and the DB update failed, the cache would be empty and the next read would re-cache the old data — a consistency violation.

The race condition we guard against: two concurrent reads hit a cache miss simultaneously, both query PostgreSQL, and both try to write to Redis. This is harmless — both write the same value. But if a write happens between the DB read and the Redis write, we could cache stale data. The short TTL (5-10 minutes) limits the staleness window, and for high-contention keys, we use Redis `SET ... NX` with a lock TTL.

</details>

---

### Q1. What are the different data sources your streaming applications process, and how are they structured?

**Brief answer**
The platform processes events from Azure Service Bus (document uploads, wellbeing logs, notifications) and batch data from Azure Blob Storage (historical document migrations). Each source uses a different trigger mechanism in Azure Functions.

<details>
<summary><strong>Detailed answer</strong></summary>

The streaming application architecture is event-driven, with Azure Service Bus as the primary message backbone. Three categories of data flow through the system:

**Real-time events via Service Bus:** These are published by AKS services when state changes occur. `document.uploaded` events trigger the Blob Processing Function (OCR, embedding, Milvus indexing). `wellbeing.logged` events trigger the Event Processing Function (trend computation, alert threshold checks). `message.received` events trigger the Notification Service (push notifications). Each event carries a compact payload (IDs and metadata, not full objects) — the consumer fetches the full data from the appropriate store.

**Batch processing via Blob Storage:** When onboarding a new clinic (~2,000 patients), historical medical documents are bulk-uploaded to a staging blob container. A Blob Storage batch operation iterates over all blobs and publishes `document.uploaded` events to Service Bus for each one. This reuses the same processing pipeline as real-time uploads but at higher volume. The batch operation uses Blob Storage's `list_blobs` with pagination and publishes events in configurable-size batches (e.g., 50 at a time) to avoid overwhelming Service Bus.

**Auxiliary scripts for data processing:** Python scripts (run via Bash) handle one-off data transformations: importing patient records from CSV exports of the clinic's existing Electronic Health Record (EHR) system, normalizing diagnosis codes to standard ontologies (ICD-10), and generating initial embeddings for the medical knowledge base. These scripts use the same SQLAlchemy models and Pydantic schemas as the services, ensuring data consistency. They run locally or in an Azure Container Instance for larger jobs.

The common pattern across all sources: data enters the system, is validated against Pydantic schemas, and is routed to the appropriate store (PostgreSQL for structured data, Blob Storage for documents, Milvus for embeddings). The Service Bus topic/subscription model ensures that adding a new consumer (e.g., a future analytics service) doesn't require modifying the publisher.

</details>

---

### Q2. How does cache invalidation work when multiple services can modify the same data? What race conditions can occur?

**Brief answer**
Only the owning service invalidates its cache keys. Race conditions arise when concurrent read-after-write operations re-cache stale data during the window between a DB write and cache invalidation. Short TTLs and Redis locking mitigate this.

<details>
<summary><strong>Detailed answer</strong></summary>

In our architecture, each service owns its data domain. The Patient Service is the only service that writes to and caches patient profiles, wellbeing entries, and appointments. This eliminates cross-service cache invalidation complexity — no service needs to know about another service's cache keys.

The race condition that matters is within a single service, under concurrent requests. Consider this sequence: (1) Request A reads patient profile — cache miss — queries PostgreSQL and gets version V1. (2) Request B updates the patient profile in PostgreSQL (now V2) and invalidates the cache. (3) Request A writes V1 to Redis (its PostgreSQL read completed before B's invalidation). Now Redis has stale V1, and subsequent reads will return it until the TTL expires.

At our scale (~500 QPS peak, spread across ~15K patients), this race is rare — two requests for the same patient within the same millisecond window. The short TTL (10 minutes for patient profiles, 5 minutes for wellbeing) limits the impact. For a healthcare platform, a 5-minute staleness on a cached patient profile is acceptable because the data isn't medically actionable in real-time — the profile shows diagnosis and treatment plan metadata, not time-sensitive vitals.

For genuinely high-contention keys (if we ever have them), the defense is Redis `SET ... NX` (set if not exists) with a short lock TTL. The first request to cache the value wins; concurrent requests that lose the race simply return the value the winner cached. This is a read lock, not a write lock — it doesn't block reads, just prevents redundant cache population.

There's a subtler cross-service scenario: the Event Processing Function computes wellbeing trends and writes aggregates. If the Patient Service caches a dashboard response that includes trend data, the cached dashboard becomes stale when new trends are computed. We solve this by keeping trend data in materialized views (not Redis), refreshed hourly. The dashboard reads real-time data from Redis (latest wellbeing entry) and trend data from the materialized view — two different staleness windows, both acceptable.

</details>

---

### Q2. Walk through the auxiliary data processing scripts you wrote. What were they for, and how did you ensure reliability?

**Brief answer**
Scripts handled clinic data imports (CSV → PostgreSQL), diagnosis code normalization (ICD-10 mapping), and medical knowledge base ingestion (articles → embeddings → Milvus). Reliability comes from idempotency, transaction boundaries, and progress checkpointing.

<details>
<summary><strong>Detailed answer</strong></summary>

The most common script was the clinic onboarding pipeline. When a new partner clinic joins, their existing patient data arrives as CSV exports from their Electronic Health Record system. The script: (1) validates each row against the Pydantic `Patient` model (catching malformed dates, missing required fields, invalid diagnosis codes), (2) normalizes diagnosis codes to ICD-10 standard (the clinic might use internal codes), (3) inserts records into PostgreSQL in batches of 500 (using SQLAlchemy's `bulk_insert_mappings` for performance), (4) publishes events for downstream processing.

Reliability mechanisms: **Idempotency** — each patient record has a composite natural key (name + date of birth + clinic source ID). The script uses `INSERT ... ON CONFLICT DO UPDATE` (upsert) so re-running the script after a failure doesn't create duplicates. **Transaction boundaries** — each batch of 500 records is a single transaction. If row 450 fails validation, the entire batch is rolled back and logged. The script continues with the next batch, producing a report of failed batches for manual review. **Progress checkpointing** — for large imports (50K+ records), the script tracks the last successfully processed batch number in a checkpoint file. On restart, it resumes from the checkpoint instead of reprocessing everything.

The medical knowledge base ingestion script processes curated medical articles (downloaded from verified sources in JSON format). It chunks articles (500 tokens per chunk, 50-token overlap), generates embeddings via the Azure OpenAI embedding API, and bulk-indexes them into Milvus. This script runs periodically (monthly) when the clinical content team updates the knowledge base. It uses a `source_doc_id` + `chunk_index` as the Milvus primary key, so re-ingesting an updated article replaces old chunks rather than duplicating them.

All scripts share common infrastructure: logging to stdout with structured JSON (same format as the services), execution via Bash wrapper scripts that handle argument parsing and error codes, and the same Pydantic models and SQLAlchemy connections as the main services — ensuring data written by scripts is validated identically to data written by APIs.

</details>

---

### Q3. How would you redesign the caching strategy if the platform needed to support real-time data for clinical dashboards where 5-minute staleness is unacceptable?

**Brief answer**
Switch from cache-aside to event-driven cache invalidation via Service Bus. When data changes, the writing service publishes an event, and the cache is invalidated (or updated) immediately. For truly real-time needs, consider WebSocket push instead of polling with cache.

<details>
<summary><strong>Detailed answer</strong></summary>

The current cache-aside pattern tolerates 5-10 minute staleness because the platform's users (patients) aren't making clinical decisions based on the cached data. But if providers need real-time dashboards (e.g., a nurse monitoring 20 patients' vitals in an ICU-adjacent scenario), the strategy must change fundamentally.

**Option 1: Event-driven invalidation.** Every write operation publishes an event to Service Bus (it already does for some operations: `wellbeing.logged`, `document.uploaded`). Extend this to all cache-relevant writes. A dedicated cache invalidation consumer subscribes to these events and deletes or refreshes the corresponding Redis keys. This reduces the staleness window from TTL-based (minutes) to event-processing latency (milliseconds to low seconds). The trade-off is infrastructure complexity — every cached entity needs a corresponding event type.

**Option 2: Write-through for critical paths.** For the specific data that must be real-time (e.g., vitals), switch to write-through: the Patient Service writes to both PostgreSQL and Redis in the same request path. Use a Lua script in Redis to make the update atomic (`SET` + `PUBLISH`). Non-critical data (patient profile, appointment list) remains cache-aside with TTL. This is a hybrid approach — more complexity but surgically applied.

**Option 3: WebSocket push.** For a clinical dashboard showing live vitals, caching isn't the right model at all. A WebSocket connection between the frontend and a dedicated real-time service would push updates immediately when new data arrives. The Patient Service publishes a `vitals.updated` event to Service Bus, the real-time service consumes it and pushes to all connected dashboards for that patient. This eliminates the polling-with-cache model entirely for real-time views.

I'd likely use a combination: WebSocket push for the real-time dashboard (Option 3), write-through for the specific vitals cache key (Option 2), and cache-aside for everything else that doesn't need real-time updates. The principle is: match the caching strategy to the access pattern's staleness tolerance, not one-size-fits-all.

The cost implications matter too. Write-through doubles Redis write load. WebSockets require persistent connections (more AKS memory). Event-driven invalidation adds Service Bus message volume and a new consumer service. All are justified only if the clinical use case demands real-time — over-engineering the cache for a patient self-service portal would be wasteful.

</details>

---

## Frontend Development (React & Webpack)

---

### Q1. How do you manage data flow in a React application using Redux Toolkit? Why not just use local component state?

**Brief answer**
Redux Toolkit provides centralized state management with `createSlice` for reducers and `createAsyncThunk` for API calls. Local state works for UI-only concerns (form inputs, modals), but shared data (patient profile, authentication state) needs a global store to avoid prop drilling and duplicated fetches.

<details>
<summary><strong>Detailed answer</strong></summary>

In this platform, the React Single-Page Application (SPA) manages several categories of state: authentication (JWT tokens, user role), patient data (profile, wellbeing entries, appointments), and UI state (sidebar open/closed, modal visibility). Redux Toolkit is used for the first two categories because multiple components need access to the same data.

For example, the patient profile is displayed in the header (name), the sidebar (diagnosis summary), and the main content area (full profile). Without Redux, you'd either prop-drill the profile through every intermediate component or fetch it independently in each component (causing three API calls for the same data). Redux Toolkit's `createAsyncThunk` fetches the profile once, stores it in the global slice, and any component can access it via `useSelector`. When the profile updates, all components re-render automatically.

`createSlice` simplifies reducer boilerplate. Instead of writing action types, action creators, and reducer switch statements separately, you define them in one place. The `extraReducers` builder handles async thunk lifecycle (pending, fulfilled, rejected), making loading and error states straightforward.

Local component state (`useState`) is still appropriate for ephemeral UI concerns: whether a dropdown is open, the current value of a text input before form submission, or animation state. Putting these in Redux would add unnecessary indirection — the data is relevant to exactly one component and has no persistence or sharing requirements.

Axios is configured with an interceptor that attaches the JWT from the Redux auth slice to every API request. If a response returns 401 (token expired), the interceptor triggers a token refresh flow using the refresh token stored in the auth slice. This is a cross-cutting concern that benefits from centralized state — scattered `fetch` calls in individual components can't coordinate token refresh without a shared store.

</details>

---

### Q1. What is Hot Module Replacement (HMR), and how did you set it up in Webpack?

**Brief answer**
HMR allows Webpack to push updated modules to the browser without a full page reload, preserving application state during development. It's configured via `webpack-dev-server` with `hot: true` in the dev config.

<details>
<summary><strong>Detailed answer</strong></summary>

Without HMR, every code change triggers a full browser reload. This means: the page re-renders from scratch, Redux state is lost (you're logged out, navigation resets), and any form input you were testing disappears. For a complex healthcare dashboard with authentication and multi-step forms, this feedback loop is painfully slow — you make a CSS change, save, wait for the build, wait for reload, log in again, navigate back to the page you were working on.

HMR changes this: Webpack watches source files, rebuilds only the changed module, and sends it to the browser via a WebSocket connection. The browser swaps the updated module in place without reloading. React state is preserved (using `react-refresh`), so your form inputs, navigation state, and authentication persist.

The Webpack configuration: `devServer: { hot: true }` enables HMR. We pair this with `@pmmmwh/react-refresh-webpack-plugin`, which integrates React Fast Refresh with Webpack's HMR. React Fast Refresh is specifically designed to preserve component state during updates — it re-renders changed components while keeping their `useState` and `useReducer` state intact.

There are boundaries to what HMR can handle. Changes to the Redux store structure, route definitions, or top-level providers usually require a full reload because the module dependency graph changes in a way HMR can't reconcile. The plugin detects this and falls back to a full reload automatically. In practice, 90%+ of development changes (component markup, styling, logic within a component) are handled by HMR without reload.

The production Webpack config does NOT include HMR — it uses content hashing for cache busting (`[name].[contenthash].js`) and code splitting for performance. The HMR setup lives entirely in `webpack.dev.js`, separated from `webpack.prod.js` to keep production builds clean.

</details>

---

### Q2. How did you implement form handling and validation in the React application? What patterns ensure good user experience and data integrity?

**Brief answer**
We use controlled components with a form library (like React Hook Form or Formik) for complex forms, with Pydantic-aligned validation schemas on the frontend. Real-time validation gives immediate feedback; server-side validation is the final authority.

<details>
<summary><strong>Detailed answer</strong></summary>

The platform has several complex forms: patient registration (name, DOB, diagnosis, stage, treatment plan), wellbeing logging (symptoms checklist, mood scale, vitals), appointment scheduling (provider selection, datetime, type), and secure messaging (recipient, body, attachments). Each has different validation needs.

The pattern: controlled components where React state drives input values. For simple forms (search, single field), `useState` is sufficient. For multi-field forms with cross-field validation (e.g., prescription end date must be after start date), a form library provides structure: field registration, validation rules, error state management, and form submission handling.

Validation runs at multiple levels for defense-in-depth: (1) **Field-level (onChange):** Immediate feedback as the user types — email format check, required field indicator, date format validation. This uses the same regex patterns as the Pydantic models on the backend, ensuring consistency. (2) **Form-level (onSubmit):** Cross-field validation before the API call — end date after start date, vitals within reasonable ranges (heart rate 30-250 BPM). (3) **Server-side (FastAPI + Pydantic):** The authoritative validator. Even if a bug in the frontend lets invalid data through, Pydantic rejects it at the API boundary. The frontend displays server-side validation errors by mapping the Pydantic error response (`detail[].loc` and `detail[].msg`) to the corresponding form fields.

User experience considerations specific to a healthcare application: (1) **Vitals input** — number inputs with min/max constraints and step values. An out-of-range vital (heart rate of 500) shows a warning but doesn't block submission — patients might have unusual readings that are clinically valid. The warning says "This value is unusual. Please double-check before submitting." (2) **Symptoms checklist** — MUI checkboxes grouped by category (pain, fatigue, nausea, etc.) with an "Other" free-text field. The data is serialized as JSON matching the `jsonb` symptoms column in PostgreSQL. (3) **File upload** — drag-and-drop with progress indicators, file type validation (PDF, JPEG, PNG only), and size limits (20 MB). The upload uses multipart/form-data via Axios with an upload progress callback to update the UI.

Data integrity means the frontend never transforms data in ways the backend doesn't expect. All date fields use ISO 8601 format. All IDs are UUIDs. The Redux Toolkit's `createAsyncThunk` serializes form data into the exact JSON shape the FastAPI endpoint expects (matching the Pydantic model).

</details>

---

### Q2. How do you ensure smooth interaction between the React frontend and backend APIs, especially for the AI Assistant's streaming responses?

**Brief answer**
Standard CRUD uses Axios with Redux Toolkit's `createAsyncThunk`. The AI Assistant's streaming uses the EventSource API (or fetch with ReadableStream) to consume Server-Sent Events (SSE), updating the UI token-by-token as the response arrives.

<details>
<summary><strong>Detailed answer</strong></summary>

The dual communication pattern reflects the two types of backend interactions: request-response (CRUD) and streaming (AI Assistant).

For CRUD operations, Axios is configured with a base URL pointing to Azure API Management, an interceptor that attaches the JWT from the Redux auth slice, and a response interceptor that handles 401 errors (token refresh) and 5xx errors (retry with exponential backoff). Each service domain (patients, documents, appointments) has an Axios instance or a set of API functions that the Redux Toolkit async thunks call. This keeps API logic out of components — a component dispatches `fetchWellbeingEntries(patientId)`, and the thunk handles the Axios call, error handling, and state updates.

For the AI Assistant streaming, Axios doesn't natively support SSE. We use the browser's `EventSource` API (for GET-based SSE) or, since our endpoint is POST-based, `fetch` with a `ReadableStream`. The pattern: (1) The user sends a message via a POST request to `/assistant/conversations/{id}/messages`. (2) The response is a stream of SSE events. (3) A custom hook (`useAssistantStream`) reads the stream chunk by chunk using `getReader()`. (4) Each chunk is parsed as an SSE event — either a `token` event (append to the current response) or a `done` event (with citation metadata). (5) The accumulated response is stored in local component state (not Redux — it's ephemeral during streaming) and promoted to Redux once streaming completes.

The UI renders tokens as they arrive, creating the "typing" effect. A subtle UX detail: we buffer a few tokens before rendering to avoid character-by-character jitter. Every 3-5 tokens, the component re-renders with the accumulated text. This provides a smooth reading experience while maintaining the perception of speed.

Error handling during streaming: if the stream disconnects mid-response, the hook detects the broken connection and shows a "Response interrupted — tap to retry" button. The partial response is not persisted to the conversation history. On retry, the full response is regenerated (not resumed from where it left off, as LLM generation is not resumable).

</details>

---

### Q3. How would you optimize the React application's bundle size and loading performance for patients on slow connections?

**Brief answer**
Code splitting with React.lazy and dynamic imports, tree shaking of unused MUI components, Webpack content hashing for long-term caching, and critical CSS inlining for fast first paint.

<details>
<summary><strong>Detailed answer</strong></summary>

Cancer patients may access the platform from hospital waiting rooms with poor connectivity, or from older devices at home. Performance isn't a luxury — it directly impacts whether patients can access their medical information when they need it.

**Code splitting:** The application uses `React.lazy()` with `Suspense` for route-based splitting. The login page, dashboard, AI Assistant, document viewer, and settings page are separate chunks. A patient who only uses the wellbeing tracker never downloads the AI Assistant code. Webpack's `splitChunks` configuration separates vendor libraries (React, Redux, MUI) into a separate chunk that changes rarely and caches aggressively.

**Tree shaking MUI:** Material-UI (MUI) is large. Importing `import { Button } from '@mui/material'` can pull in the entire library if not configured correctly. We use path imports (`import Button from '@mui/material/Button'`) and Webpack's tree shaking to include only used components. The `@mui/material` package supports this out of the box, but it requires `sideEffects: false` in the Webpack configuration to work optimally.

**Caching strategy:** Webpack output files use `[contenthash]` in filenames (`main.a1b2c3.js`). When code changes, only the affected chunk gets a new hash — other chunks remain cached. The Azure CDN serves these with `Cache-Control: max-age=31536000` (1 year) since the hash guarantees uniqueness. On deployment, the CDN is purged for the HTML entry point only — it references the new hashed bundles, and unchanged chunks serve from cache.

**First paint optimization:** The HTML shell loads immediately (served from CDN, < 5 KB). A critical CSS inline style renders the loading skeleton (patient dashboard layout without data). React hydrates and starts fetching data. The user sees a structured loading state within 500ms, even on slow connections, rather than a blank white page.

**API optimization:** Redux Toolkit Query (RTK Query) can be configured with automatic cache tags and stale-while-revalidate behavior. For data that changes infrequently (patient profile, prescription list), the frontend serves the cached version immediately and revalidates in the background. The user sees content instantly, and it updates silently if the data has changed.

**Image and document optimization:** Medical documents (PDFs, images) are loaded on demand, not prefetched. The document list shows metadata only; the actual document downloads when the patient clicks "View." For image thumbnails in the document list, we generate compressed thumbnails in the Blob Processing Function and serve those instead of full-resolution images.

</details>

---

## AI-Assisted Development & Testing

---

### Q1. How do you use AI tools to analyze an existing codebase and identify bottlenecks?

**Brief answer**
Feed the AI tool (Cursor/Claude) specific files or modules and ask targeted questions: "What are the performance implications of this query pattern?" or "Identify N+1 query issues in this service." Validate every suggestion against actual profiling data.

<details>
<summary><strong>Detailed answer</strong></summary>

AI-assisted code analysis is a force multiplier, but it's a starting point, not a conclusion. The workflow in this project: (1) **Scoping** — identify the area of concern. If the wellbeing dashboard is slow, start with the Patient Service's wellbeing endpoints, the SQLAlchemy models, and the associated SQL queries. (2) **Context loading** — feed the AI tool the relevant files with enough surrounding context (model definitions, database schema, the specific endpoint code). (3) **Targeted prompting** — ask specific questions: "Are there any N+1 query patterns in this endpoint?" or "What would happen to this query at 100x the current row count?" Generic prompts like "find bugs" produce generic results.

In this project, AI analysis identified: (1) a missing index on `message(recipient_id, is_read)` — the unread count badge was doing a sequential scan. (2) A SQLAlchemy relationship that was eagerly loading related appointments when only the patient profile was needed — adding `lazy='select'` and explicit `joinedload` where needed fixed unnecessary queries. (3) A Redis connection that wasn't using connection pooling — each request opened a new TCP connection to Redis, adding 2-3ms overhead.

The critical step is **validation**. AI tools can hallucinate optimizations that don't apply. Every suggestion is validated against: (1) `EXPLAIN ANALYZE` for SQL changes, (2) actual latency measurements (Application Insights traces) before and after, (3) load testing for changes that affect concurrency. The AI suggested converting a serial API call pattern to parallel `asyncio.gather()` — which was correct in principle but wrong in this specific case because the second call depended on the first call's result. Always read the suggestion critically.

AI tools are also used for refactoring suggestions: "This function is 200 lines. How would you decompose it while maintaining the same behavior?" The AI provides a proposed structure; I evaluate whether the decomposition actually reduces complexity or just moves it around.

</details>

---

### Q1. What is the difference between unit tests and integration tests, and how did you decide what to test at each level in this project?

**Brief answer**
Unit tests verify individual functions/methods in isolation with mocked dependencies. Integration tests verify that components work together with real infrastructure (database, Redis, Service Bus). The decision: unit test business logic, integration test data flows and external interactions.

<details>
<summary><strong>Detailed answer</strong></summary>

In this project, the testing pyramid is: many unit tests (fast, run in pre-commit hooks), fewer integration tests (slower, run in CI with Docker Compose), and a handful of end-to-end smoke tests (run against staging after deployment).

**Unit tests (pytest):** Test pure business logic — Pydantic model validation, data transformation functions, cache key generation, authorization logic (given a JWT with role X, can they access resource Y?). These use mocked dependencies: a fake Redis client, a mock SQLAlchemy session, a stubbed Milvus client. They run in milliseconds and catch logic errors.

**Integration tests (pytest + Docker Compose):** Test the actual interaction between components. A typical integration test: POST a wellbeing entry via the FastAPI test client → verify it's in PostgreSQL → verify the Redis cache was invalidated → verify a `wellbeing.logged` message was published to Service Bus. These use real PostgreSQL, Redis, and Service Bus containers (or emulators) spun up by Docker Compose. They're slower (seconds per test) but catch issues that unit tests miss: SQL syntax errors, Redis serialization bugs, Service Bus message format mismatches.

**React Testing Library:** For the frontend, tests render components with mock data and verify user interactions. For example: render the wellbeing form → fill in symptoms → click submit → verify the correct Axios call was made with the expected payload. These are technically unit tests (the backend is mocked) but they test the full component lifecycle.

The decision boundary: if the function's correctness depends only on its inputs and logic, unit test it. If the correctness depends on how it interacts with an external system (database, cache, message broker), integration test it. We explicitly don't mock the database in integration tests — a past incident showed that mocked database tests can pass while the actual SQL fails due to a missing column or type mismatch.

Coverage targets: 80%+ line coverage for business logic modules, 60%+ for API endpoint handlers (integration tests cover the rest), no coverage target for infrastructure/configuration code.

</details>

---

### Q2. How do you validate and refine AI-generated code to ensure it meets project standards and performance requirements?

**Brief answer**
Treat AI output like a junior developer's pull request: review for correctness, style compliance (black, ruff, mypy), security issues (bandit), and performance implications. Never merge AI-generated code without understanding every line.

<details>
<summary><strong>Detailed answer</strong></summary>

The validation process has multiple gates, matching the same quality pipeline as human-written code.

**Step 1: Understanding.** Before accepting AI-generated code, read it line by line. AI tools can produce code that looks correct but has subtle issues: off-by-one errors, incorrect async/await usage (forgetting to `await` a coroutine), or logic that works for the happy path but fails on edge cases. If you can't explain what every line does, don't use it.

**Step 2: Style and static analysis.** Run the same pre-commit hooks: `black` reformats to match project style, `ruff` catches linting issues (AI-generated code often has unused imports), `mypy` verifies type annotations are correct (AI sometimes invents types that don't exist in our codebase), and `bandit` checks for security issues (AI code might use `eval()` or construct SQL strings directly).

**Step 3: Test coverage.** Write tests for the AI-generated code — or better, write the tests first and have the AI generate code that passes them. In this project, we sometimes used the AI to generate both implementation and tests, then manually reviewed both. The danger is circular validation: AI-generated tests that pass AI-generated code may share the same incorrect assumption.

**Step 4: Performance validation.** AI-generated SQL is a particular risk area. The AI might write a correct query that performs terribly — correlated subqueries instead of joins, missing index hints, or ORM usage that generates N+1 queries. Every AI-generated database interaction gets an `EXPLAIN ANALYZE` review. We caught a case where the AI generated a Milvus query that fetched all vectors and filtered in Python instead of using Milvus's native filtering — correct results, catastrophic performance.

**Step 5: Security review.** For a HIPAA platform, this is non-negotiable. AI-generated code that handles PHI gets extra scrutiny: Does it log patient data? Does it properly scope queries to the authenticated user? Does it use parameterized queries? AI tools don't understand the compliance context of your project — they'll generate code that works functionally but violates HIPAA by logging patient names in plain text.

**Step 6: Integration verification.** Does the AI-generated code integrate correctly with existing code? Naming conventions, error handling patterns, and logging formats must match the project's established patterns. AI tools often introduce inconsistent patterns (e.g., using `print()` instead of the project's structured logger).

</details>

---

### Q2. How do you write effective integration tests for an event-driven system with asynchronous flows?

**Brief answer**
Use real infrastructure (Docker Compose containers), publish events, then poll for expected outcomes with timeouts. Verify the full chain: event published → consumer processes → downstream state changes.

<details>
<summary><strong>Detailed answer</strong></summary>

Integration testing an async event-driven system is harder than testing synchronous APIs because the request and the side effect are decoupled in time. The test publishes an event and then needs to wait for the consumer to process it. Here's the approach in this project:

**Test infrastructure:** Docker Compose spins up PostgreSQL, Redis, a Service Bus emulator (or Azure Service Bus test namespace), and Milvus. The test suite initializes a clean database state (Alembic migration) before each test module.

**Test pattern — assert with polling:** After publishing a `document.uploaded` event to Service Bus, the test polls for the expected outcome. Instead of `time.sleep(5)`, which is fragile (too short = flaky, too long = slow), we use a polling helper:

```python
async def wait_for(predicate, timeout=30, interval=0.5):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if await predicate():
            return True
        await asyncio.sleep(interval)
    raise TimeoutError("Condition not met within timeout")
```

For the document processing test: publish event → `wait_for(lambda: document_meta.processing_status == 'completed')`. The predicate queries PostgreSQL directly. If the consumer hasn't processed within 30 seconds, the test fails with a clear timeout error.

**Verifying the full chain:** The test doesn't just check that the event was published — it verifies the downstream state changes. For `document.uploaded`: (1) `document_meta.processing_status` changed from `'pending'` to `'completed'` in PostgreSQL. (2) The extracted text exists in `processed/{patient_id}/{document_id}/extracted.json` in Blob Storage. (3) Embeddings are indexed in the Milvus `patient_documents` collection (verified by a Milvus query for the `document_id`).

**Idempotency testing:** Publish the same event twice and verify the system handles it correctly — the document shouldn't be double-indexed in Milvus. This catches bugs where the consumer isn't checking for already-processed documents.

**Failure testing:** Publish an event with an invalid blob path and verify: (1) the consumer retries the configured number of times, (2) the message lands in the DLQ, (3) `document_meta.processing_status` is set to `'failed'`. This validates the error handling path, not just the happy path.

**Isolation:** Each test uses unique patient_ids and document_ids (generated UUIDs) so tests don't interfere with each other when running in parallel. The Service Bus subscription is test-scoped (created at test start, deleted at end) to avoid consuming messages from other test runs.

</details>

---

### Q3. If you discovered that a critical performance bottleneck was in code that AI had generated and merged months ago, how would you approach the investigation and fix?

**Brief answer**
Use git blame to trace the code's origin, profiling tools to confirm the bottleneck, and compare the AI-generated approach against manual alternatives. Fix the code, add a regression test, and update the validation process to catch similar issues.

<details>
<summary><strong>Detailed answer</strong></summary>

This scenario isn't hypothetical — it happens. AI-generated code can be functionally correct but architecturally wrong in ways that only surface at scale.

**Investigation:** Start with the symptom. Application Insights shows the wellbeing trend endpoint has p95 latency of 3 seconds (SLO is 300ms). Distributed tracing reveals 80% of the time is spent in a single database query. `EXPLAIN ANALYZE` shows a sequential scan on a 50M-row table — no index is being used despite one existing. The query was AI-generated during a sprint three months ago: it uses a `CASE WHEN` expression in the `WHERE` clause that the PostgreSQL planner can't match to the B-tree index.

`git blame` confirms the file and the PR that introduced it. The PR review at the time approved the query because it produced correct results in testing — the test database had 1,000 rows, not 50 million. The index wasn't tested because `EXPLAIN ANALYZE` on 1,000 rows always shows an index scan.

**Fix:** Rewrite the query to use index-compatible predicates. Replace the `CASE WHEN` with explicit `AND`/`OR` conditions that the planner can push to the index. Verify with `EXPLAIN ANALYZE` on a production-replica dataset (50M rows) that the index scan is now used. The fix might seem trivial — but understanding *why* the original query was slow (planner behavior with computed expressions) prevents the same mistake in a different form.

**Regression test:** Add a CI check for this specific query. The integration test runs the query against a dataset with enough rows (10K+) to make the difference between index scan and sequential scan visible. The test asserts that `EXPLAIN` output contains `Index Scan` and not `Seq Scan`. This isn't bulletproof (the planner can change strategies based on data distribution), but it catches the most common regressions.

**Process improvement:** Update the AI code validation checklist: "For any AI-generated SQL that touches tables projected to exceed 100K rows, run `EXPLAIN ANALYZE` against a representative dataset, not just the test database." Add this as a code review comment template for SQL-touching PRs.

The broader lesson: AI-generated code requires the same lifecycle management as human code. It's not "write once, done forever." As data grows and usage patterns change, AI code can become a bottleneck just like human code. The difference is that nobody on the team has the "mental model" of why the AI wrote it that way — there's no institutional knowledge to draw on. This makes documentation and tests even more important for AI-generated code.

</details>

---

### Q3. How do you balance using AI development tools for productivity while maintaining deep understanding of the codebase, especially in a safety-critical healthcare context?

**Brief answer**
AI tools accelerate boilerplate and exploration but must never replace understanding. In healthcare, every line of code that touches PHI or medical logic must be comprehended by a human. The rule: if you can't explain it, you can't ship it.

<details>
<summary><strong>Detailed answer</strong></summary>

The tension is real: AI tools can generate a FastAPI endpoint with SQLAlchemy queries, Pydantic models, Redis caching, and error handling in minutes. A developer might be tempted to accept it wholesale and move to the next task. In a non-critical application, this might be acceptable. In a HIPAA-regulated cancer support platform, it's dangerous.

The framework I use: **AI for acceleration, humans for judgment.** AI tools are excellent at: (1) generating boilerplate (CRUD endpoints, Pydantic model definitions, test scaffolding), (2) exploring unfamiliar APIs ("show me how to configure Milvus HNSW index parameters"), (3) suggesting refactoring patterns ("how would you decompose this 300-line function?"), (4) identifying potential issues ("what could go wrong with this caching strategy?"). In all cases, the human evaluates the output.

AI tools should NOT be the sole author of: (1) authorization logic (who can access what PHI), (2) data processing pipelines where correctness affects patient outcomes (wellbeing trend calculations that providers use for clinical decisions), (3) security-sensitive code (encryption, input sanitization, audit logging), (4) database migrations (a wrong migration can corrupt production data).

The practical workflow: use AI to generate a first draft, then review it as if it were a PR from a contractor who doesn't know your project. Check: Does it use our logging format? Does it scope queries to the authenticated user? Does it follow our error handling pattern (structured errors, not generic 500s)? Does the SQL work with our indexes? Does it handle the edge cases that matter in our domain (e.g., a patient with no wellbeing entries yet)?

Maintaining deep understanding requires deliberate practice. I periodically write modules from scratch without AI assistance to stay sharp on the fundamentals. If I notice myself reflexively accepting AI suggestions without reading them, that's a red flag — I'm losing the understanding that makes the review meaningful.

The test for whether you've maintained understanding: can you debug a production issue in AI-generated code at 2 AM without the AI tool? If the Milvus query is returning wrong results, can you reason about the embedding dimensions, index type, and distance metric without asking an AI to explain it? If not, you've outsourced understanding, and that's a liability in a safety-critical system.

</details>
