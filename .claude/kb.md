# Essentials

Concise notes on the technologies, techniques and protocols the cases use — enough to explain a concept or its mechanism from cold, and no more. Entries are added on demand with `/kb`.

Each entry is a `###` term heading, the topic tags it can be found by, and one sentence saying what it is in essence, followed by an expandable block holding **How it works**, **Boundary** — what it is not and what it is confused with — an optional **Alternatives** comparison, and an **Example**. Categories are `##` headings; terms are alphabetical within their category.

**Tags in use:** `application-monitoring` · `container-platform` · `continuous-delivery` · `data-validation` · `data-visualization` · `delegated-authorization` · `directory` · `distributed-tracing` · `gitops` · `identity-provisioning` · `iot` · `llm-framework` · `messaging` · `metrics` · `ml-library` · `model-hub` · `orm` · `schema-migration` · `static-analysis` — extend this list rather than coining a synonym for a tag already on it. Tags are single tokens, hyphenated where a bare word would mean something else in another part of this file.

## Protocols

### AMQP
`messaging`

A binary protocol for passing messages between services through a broker, with delivery confirmed rather than assumed. The sender hands a message to the broker, which holds it in a queue until a consumer acknowledges having processed it.

<details><summary>Details</summary>

**How it works:** In the 0-9-1 model, a publisher never names a queue. It publishes to an *exchange* with a *routing key*, and *bindings* declared on the exchange decide which queues receive a copy — one, several, or none. A consumer takes messages from a queue and returns an *ack*; an unacknowledged message whose consumer dies is redelivered, and a rejected one can be dropped, requeued or sent to a dead-letter queue. Prefetch limits how many a consumer may hold unacknowledged at once, which is what keeps a slow worker from being buried.

**Boundary:** Two protocols share the name, and they are not interchangeable — a 1.0 client cannot talk to a 0-9-1 broker. The exchange and binding model above is 0-9-1, which is what RabbitMQ speaks; AMQP 1.0 is a different, lower-level link protocol used by Azure Service Bus and others, and leaves routing to the broker's own concepts. It is also a protocol, not a product: RabbitMQ is one implementation, and much of what people call AMQP behaviour is RabbitMQ's. Like a queue and unlike a log, an acknowledged message is gone — which is the real contrast with Kafka, a system rather than a protocol, whose consumers keep a position in a log they can rewind.

**Alternatives:**
- **MQTT** — topic matching instead of exchanges and bindings, and far lighter on constrained clients. The right trade for telemetry from many devices, the wrong one for work queues that must not lose a job.
- **STOMP** — a text-based frame protocol that any language can speak in a few lines. Much simpler to implement and debug, with none of the routing or delivery machinery.

**Example:** An order service publishes to the `orders` exchange with routing key `order.placed`. A `billing` queue and an `analytics` queue are both bound to that key, so each gets a copy; the billing worker acks only after the payment row is committed, so a crash mid-charge returns the message to the queue rather than losing it.

</details>

### LDAP
`directory`

A protocol for reading and writing entries in a hierarchical directory. A client connects to a directory server, searches under a branch of the tree, and can also hand the server a name and password for it to verify.

<details><summary>Details</summary>

**How it works:** Entries sit in a tree, each identified by a *distinguished name* built from its path — `cn=jsmith,ou=people,dc=example,dc=com` — and each holding attributes whose permitted names and types come from a schema. A client authenticates with a *bind*: a simple bind sends a distinguished name and a password, and the server answers whether it accepted them. A bind carrying an empty password is an *unauthenticated* bind that many servers accept, so an application must reject empty passwords itself rather than read any success as proof. Reads use a *search*, given a *base* to start from, a scope saying how deep to go, and a filter such as `(&(objectClass=person)(department=cardiology))`. Writes exist but are single-entry operations; the protocol runs over TCP, wrapped in TLS in any deployment that matters.

**Boundary:** A protocol, not a product. Active Directory is a directory server that speaks it alongside Kerberos and much else, and OpenLDAP is another; most claims about "LDAP behaviour" are really claims about one of them. An accepted bind says the server accepted those credentials at that instant and nothing more — no token, no session, no expiry — so an application still has to issue its own session afterwards. And it is not a relational database: entries are read far more often than written, there are no joins and no transaction spanning two entries.

**Alternatives:** OIDC, where the application redirects to an identity provider instead of taking the password itself and binding with it. Safer, since the application never sees the credential, and it carries a session where a bind does not — but it gives no way to query the tree, so anything that needs to list a department's members still wants a directory.

**Example:** An intranet application authenticates someone by binding as `cn=jsmith,ou=people,dc=example,dc=com` with the password they typed, having refused it first if it was empty; an accepted bind then means the credentials were valid. It then searches from base `ou=groups,dc=example,dc=com` with the filter `(member=cn=jsmith,ou=people,dc=example,dc=com)` to learn which groups they belong to.

</details>

### MQTT
`messaging` `iot`

A lightweight publish and subscribe protocol for devices on slow or unreliable networks. Clients never address each other — they publish to a named topic on a broker, which fans each message out to whoever subscribed.

<details><summary>Details</summary>

**How it works:** A client opens one long-lived TCP connection with a `CONNECT` packet, then publishes to slash-separated topic strings such as `sensors/aisle-4/temp`. Subscribers match those with wildcards — `+` for one level, `#` for the rest of the tree — so `sensors/+/temp` catches every aisle. The broker owns the subscription table and does all the routing; neither side knows the other exists. Delivery is negotiated per message: QoS 0 at most once, 1 at least once, 2 exactly once. A client can also register a *last will* that the broker publishes on its behalf if the connection drops.

**Boundary:** Not a queue and not a log: topic matching is the only routing, and while retained messages give a last known value and persistent sessions replay what was missed, nothing rewinds history. Kafka is therefore the usual complement rather than a rival — a connector bridges device topics into a replayable log. MQTT 5's shared subscriptions are the closest it comes to a consumer group.

**Alternatives:**
- **CoAP** — the same job over UDP with a REST-shaped request model. Lighter still and works without a broker, but has no equivalent of a persistent session.
- **AMQP** — durable queues, exchanges, per-message acknowledgement. Far richer broker semantics, at a cost on the wire and in the client that MQTT exists to avoid.
- **Plain HTTPS requests** — no broker to operate and no new protocol, but each device pays a full connection per reading and nothing is pushed back to it.

**Example:** A cold store's sensors each publish to `sensors/aisle-4/freezer-2/temp` every thirty seconds. An alerting service subscribes to `sensors/+/+/temp` and sees every reading; adding a freezer needs no change to it.

</details>

### OAuth 2.0
`delegated-authorization`

A framework for letting one application act on a user's behalf in another service without ever handling their password. The user approves the access at the service that holds the data, and the application is issued a scoped, expiring token to present instead.

<details><summary>Details</summary>

**How it works:** Four roles: the *resource owner* (the user), the *client* (the application asking), the *authorization server* that authenticates the user and issues tokens, and the *resource server* holding the API. In the authorization code grant, the client redirects the browser to the authorization server naming its client id, the *scopes* it wants and a redirect URI registered in advance; the user signs in and consents there; the server redirects back with a short-lived *authorization code*, which the client exchanges at the *token endpoint* for an *access token* and usually a *refresh token*. The access token is a bearer credential sent as `Authorization: Bearer <token>` on each API call and is short-lived — minutes or an hour, by deployment convention rather than by the specification; the refresh token buys new ones without asking the user again. PKCE — a one-time secret the client commits to at the redirect and proves at the exchange — binds the code to the client that began the flow, and current guidance applies it to every client, not only mobile and browser ones. A separate *client credentials* grant covers service-to-service calls where there is no user at all. Grants are revocable, but what that stops depends on the deployment: withdrawing consent kills the refresh token at once, while an access token already issued stays usable until it expires unless the resource server checks it against the authorization server on every call.

**Boundary:** Authorization, not authentication. An access token says an application was granted certain scopes; it says nothing reliable about who is using it, and treating a valid token as proof of identity is the standard way this gets misused — OIDC exists to supply that missing piece, as a thin layer issuing an *ID token* alongside. It is also a framework rather than a single protocol: the token format is deliberately unspecified, opaque string or JWT, so a resource server validates tokens however its authorization server says to, and "supports OAuth" describes very different implementations. The tokens are bearer credentials — possession alone is sufficient to use one — so every leg runs over TLS. The older implicit and resource owner password grants are still widely described in tutorials and are no longer recommended.

**Alternatives:** GNAP, a later IETF protocol for the same job, written as a clean break rather than a replacement — nothing in OAuth 2.0 is deprecated in its favour. The grant is negotiated through a JSON API instead of being assembled from redirect parameters, though redirecting the user remains one of its interaction modes. Effectively nothing deployed speaks it.

**Example:** A scheduling app wants to read someone's calendar. It redirects them to the calendar provider's authorization server asking for the `calendar.read` scope; they sign in there and approve. The provider redirects back with a code, the app exchanges it at the token endpoint for an access token, and sends that token as a bearer on every calendar request — never seeing the password, and losing the ability to renew the token the moment the user revokes the grant.

</details>

### SCIM
`identity-provisioning`

A standard REST API one system uses to create, update and delete user accounts inside another — the identity provider pushes the changes, and the application only implements the endpoints.

<details><summary>Details</summary>

**How it works:** A fixed JSON schema for `User` and `Group` resources, served at `/Users` and `/Groups` over ordinary HTTP verbs — `POST` to create, `PATCH` to change one attribute, `DELETE` to deprovision. The identity provider is the client and drives every change; the application is the server and only reacts. Because the schema is fixed, one connector works against any compliant application.

**Boundary:** Provisioning only — it cannot authenticate anyone or carry a sign-in. That is SAML or OIDC's job, and the two run together: OIDC logs the user in, SCIM makes sure the account existed to be logged into and is gone the day they leave.

**Alternatives:**
- **LDAP directory sync** — the application pulls the directory on a schedule instead of being pushed to. Simpler to run, slower to reflect a leaver.
- **Just-in-time provisioning** from SAML or OIDC claims — creates the account at first sign-in and needs no extra API, but nothing ever deprovisions.

**Example:** HR marks an employee as a leaver. The identity provider sends `PATCH /Users/<id>` with `active: false` to every connected application, and access ends everywhere without an administrator touching any of them.

</details>

## Tools

### Alembic
`schema-migration`

A Python tool that versions a relational database's schema as an ordered chain of migration scripts. Each script says how to move the schema one step forward and how to undo that step, and the tool applies whichever scripts the target database has not run yet.

<details><summary>Details</summary>

**How it works:** Each migration is a Python file under `versions/`, carrying a `revision` identifier and a `down_revision` naming its parent, so the files form a linked chain rather than relying on filenames or timestamps for order. The database records where it stands in a single table, `alembic_version`, holding — on a chain with one head — the revision it is currently at; `alembic upgrade head` runs the `upgrade()` of every script between that point and the newest, and `downgrade` runs their `downgrade()` in reverse. A script body calls operations on `op` — `op.add_column`, `op.create_index`, or `op.execute` for SQL the operations do not cover. `alembic revision --autogenerate` compares the SQLAlchemy model metadata against the live database and writes a first draft of the script. Passing `--sql` renders a migration as SQL text instead of running it, for review or for a DBA to apply by hand.

**Boundary:** A schema manager only — it changes tables, columns, indexes and constraints, and never touches the application's reads and writes, which remain SQLAlchemy's job. It is the companion to SQLAlchemy rather than a rival to it, and the two are usually run together. Autogenerate is a drafting aid and not a trustworthy differ: it detects added and dropped tables and columns reliably, but a renamed column reads as a drop plus an add — which discards the data — and server defaults, constraint names and type changes are detected inconsistently or not at all depending on configuration and dialect, so every generated script is read before it is committed. Nor does a migration's success depend on Alembic alone: under Alembic's default single-transaction run, whether a failed migration rolls back cleanly is the database's property, not the tool's — PostgreSQL runs DDL inside that transaction, so a failure leaves nothing applied, while MySQL commits each DDL statement implicitly, so a script that fails halfway leaves the schema part-changed.

**Alternatives:**
- **Flyway** — migrations as numbered plain-SQL files, applied by a tool that neither knows nor cares what language the application is in. Simpler to reason about and usable from any stack, but nothing drafts a migration from your models.
- **Django's migrations** — the same versioned-chain idea built into the framework and generated from Django models, with an autodetector that asks whether a change is a rename. Only available if the application is Django.

**Example:** Adding a status column to `orders`: `alembic revision --autogenerate -m "add order status"` writes a script whose `upgrade()` calls `op.add_column("orders", sa.Column("status", sa.String(), nullable=True))`, whose `downgrade()` drops it again, and whose `down_revision` points at the previous head. On deploy, `alembic upgrade head` applies it and moves `alembic_version` to the new revision.

</details>

### Argo CD
`gitops` `continuous-delivery`

A controller that runs inside a Kubernetes cluster and keeps it matching manifests held in a Git repository. It reads the repo, compares what it finds there against what is actually running, and reports or corrects the difference.

<details><summary>Details</summary>

**How it works:** An `Application` resource names a repository URL, a path inside it, a target revision and the destination cluster and namespace. The controller renders the manifests at that path — plain YAML, Kustomize or a Helm chart — and diffs the result against the live objects. Each Application carries two independent statuses: *sync*, meaning Synced or OutOfSync against Git, and *health*, meaning whether the running objects are actually serving. Syncing is manual until an automated sync policy is set, and two further switches stay off unless asked for: *self-heal* reverts changes made directly against the cluster, and *prune* deletes objects that have been removed from the repo. Ordering within a sync comes from *sync waves* and from hooks that run before, during or after it. The controller pulls — it polls the repository on a timer of a few minutes unless a webhook nudges it sooner — so the CI system never holds a credential for the cluster.

**Boundary:** Not a CI system. It never builds, tests or pushes an image, and it does not write to Git, so "deploy what I just built" happens only because something else committed the new image tag; the component that does that, Argo CD Image Updater, is a separate install. Nor is it progressive delivery: a sync applies the manifests and leaves the rollout to Kubernetes, while canary and blue-green belong to Argo Rollouts, a sibling project usually run alongside it. And Synced is a claim about Git, not about working software — an Application can be Synced and unhealthy at the same time, which is why the two statuses are reported separately.

**Alternatives:**
- **Flux CD** — the same pull-based GitOps controller, assembled from a set of smaller controllers driven by their own custom resources. Equivalent in what it reconciles; it ships no web UI of its own, where Argo CD's is much of why teams pick it.
- **`kubectl apply` or `helm upgrade` run from the CI pipeline** — nothing extra to operate and the deploy is one step in a job you already have. The pipeline must then hold credentials for the cluster, and once the job ends nothing is watching, so a change made by hand afterwards goes unnoticed.

**Example:** An engineer scales a service by hand with `kubectl` at 2am to get through an incident. The Application turns OutOfSync, and with self-heal on the controller re-applies the manifest from Git within minutes, so the change disappears unless it is committed. Rolling that release back later means reverting the commit rather than running anything against the cluster.

</details>

### Elastic APM
`application-monitoring` `distributed-tracing`

The application performance monitoring part of the Elastic Stack. A library loaded into each service times what it does while handling a request, ships that to Elasticsearch, and Kibana reconstructs the request's whole path across every service it touched.

<details><summary>Details</summary>

**How it works:** An agent library instruments common frameworks and clients for you, with little or no code change — the Java agent attaches with `-javaagent` and needs nothing further, while Go's wants its instrumentation modules wired in by hand. Each request a service handles becomes a *transaction*; each timed sub-operation inside it — a SQL query, an outbound HTTP call — becomes a *span*. Agents propagate a trace identifier and a sampled flag in the W3C Trace Context `traceparent` header, so the caller's span and the callee's transaction join into one *trace* spanning services. Agents batch their documents to *APM Server* — a standalone binary, or the Fleet-managed integration run by Elastic Agent that is the default from 8.x — which validates them and writes to Elasticsearch; Kibana's APM UI reads them back as per-service latency, throughput and error rate, a service map, and a waterfall of any single trace. Sampling is head-based by default: the agent decides at the start of a transaction against a configured rate, and the rest of the trace follows that decision. APM Server can also sample tail-based, deciding once the trace is complete so the slow and failed ones are kept preferentially — recent versions only, and subscription-tier-specific. Uncaught exceptions are captured as separate error documents, grouped by type and stack trace.

**Boundary:** Not a monitoring stack in itself — it is one of three data types sharing the same Elasticsearch alongside logs and infrastructure metrics, which is why agents inject the trace identifier into log lines: a trace and its logs then open side by side. Not a datastore either — retention, index lifecycle and disk cost are Elasticsearch's, which is much of what sampling is for. And a waterfall tells you which call was slow, not which line of code: profiling is a different tool reached from the same Kibana, not something a trace gives you. OpenTelemetry is a complement rather than a rival here — APM Server accepts OTLP directly, and Elastic now ships its own OpenTelemetry distributions, so the vendor agent is no longer the only way in.

**Alternatives:**
- **Datadog APM** — the same agent-and-trace model as a hosted service with nothing to operate and broader ready-made integrations. You stop holding the data yourself, and you pay per host and per ingested span instead of for disk you already run.
- **A dedicated tracing backend** such as Grafana Tempo or Jaeger — takes traces, stores them, draws waterfalls, and nothing else. Much cheaper at volume (Tempo keeps traces in object storage), but it carries no logs or metrics, so correlating the three is something you assemble.

**Example:** A checkout request takes four seconds. The waterfall for the `POST /checkout` transaction shows 80ms across the service's own spans, then one long span for a call to `pricing` — whose transaction, in the same trace, holds 140 near-identical SQL spans. The fault is in `pricing`, whose own latency chart never flagged it because every one of those queries was individually fast.

</details>

### Hugging Face
`model-hub` `ml-library`

A hosting platform for machine-learning models, datasets and demo apps, together with the open-source Python libraries that fetch and run what it hosts. One line of code names a repository on the platform, and the library downloads its weights and hands back a model ready to call.

<details><summary>Details</summary>

**How it works:** Every model, dataset and app on the *Hub* is a git repository, with the large weight files held outside the git object store — by Git LFS traditionally, and by Hugging Face's own content-addressed store, Xet, on the repositories migrated to it since 2025. A model repository holds those weights — `.safetensors` by preference, a format that stores tensors as plain data so loading executes no code, unlike a pickled `.bin` — the tokenizer files, a `config.json` naming the architecture and its hyperparameters where the model follows the `transformers` conventions, and a `README.md` that is the *model card*: prose stating intended use, limitations and evaluation results, over YAML frontmatter carrying the machine-readable licence, task, base model and training datasets. The `transformers` library implements the architectures and gives them one interface: `from_pretrained("org/name")` resolves that repository, downloads the files into a local cache, and returns an instantiated model, with `revision=` pinning a branch, tag or commit so later edits to the repository cannot change what you load. Companion libraries cover the rest — `datasets` for corpora, `tokenizers`, `diffusers` for image models, `peft` for fine-tuning adapters. Private repositories, and *gated* ones whose terms must be accepted first, need an access token. Alongside the Hub, Hugging Face sells compute: *Spaces* run a demo app on hosted hardware, free on a small shared CPU and paid for anything larger, and *Inference Endpoints* deploy a single model as a managed HTTPS service.

**Boundary:** A distributor, not the author — nearly everything on the Hub is uploaded by third parties, so a model card's description, its benchmark numbers and its stated licence are the uploader's assertions rather than a vetted fact, and "open weights" is not itself a licence: several of the headline families carry bespoke community terms restricting use, alongside plenty of plain Apache-2.0 repositories. Downloading a model is not a deployment either: `from_pretrained` gives you a process holding weights in memory, while serving it under load is a dedicated inference server's job. The Hub and the libraries are separable, which the single name obscures — `from_pretrained` takes a local directory just as happily, and the Hub will host a model no `transformers` class can load. And a repository is code as well as data: a model whose architecture the library does not implement ships its own Python and loads only under `trust_remote_code=True`, which executes that code.

**Alternatives:**
- **ModelScope** — Alibaba's hub, deliberately close in shape, and the first-party host for several Chinese model families. The one to reach for where the Hugging Face Hub is blocked or slow, at the cost of a far smaller catalogue elsewhere and documentation written mostly in Chinese.
- **A private model registry**, such as MLflow's or a cloud provider's. Your own trained models, versioned and access-controlled inside your own estate with nothing external resolved at load time — and nothing pretrained to start from, and no discovery.

**Example:** A team needs a sentiment classifier for clinical notes. They filter the Hub by task and licence, open a candidate's model card, and find it was fine-tuned on product reviews — adjacent, not clinical, so they evaluate it against their own held-out set before trusting it. The load is `from_pretrained("org/name", revision="9e4f2c1")`, pinned so a later push to that repository cannot quietly change the model underneath them; what lands in the cache is a `.safetensors` file, a `config.json` and the tokenizer.

</details>

### Kibana
`data-visualization`

The web interface to Elasticsearch: it turns indexed documents into searches, charts and dashboards, and is the console the rest of the Elastic Stack is administered from. It holds none of your data — everything it draws is a query it issues against the cluster.

<details><summary>Details</summary>

**How it works:** Kibana is a Node.js server the browser talks to; its own saved objects — searches, visualizations, dashboards, rules — live in system indices in the same Elasticsearch cluster, and its version is matched to that cluster's. What a user can query is named by a *data view*, the older name for which, *index pattern*, is still widely seen: a pattern such as `logs-*` plus the field to treat as time. *Discover* lists the matching documents over a chosen time range, filtered by clicking a field value or by typing an expression in *KQL*, the Kibana Query Language; *Lens* builds a chart by dragging fields onto it and picking the aggregation for you; a *dashboard* arranges those panels so they share one time range and one set of filters. A *space* partitions saved objects so different teams see different dashboards, and who may read which index is Elasticsearch's own role-based security rather than Kibana's. *Rules* run on the Kibana server on a schedule, query the cluster, and hand a firing alert to a *connector* — email, Slack, PagerDuty, a webhook — with which connectors are available depending on subscription tier. The solution apps (APM, Logs, Security, Maps, Fleet) are purpose-built UIs over the same indices.

**Boundary:** Not a datastore and not a search engine. It indexes none of your data — only its own saved objects — and can show nothing that is not already in Elasticsearch, so a slow dashboard is nearly always a slow query or too wide a time range, not a Kibana problem. It is not an ingest path either: getting the data in is Beats, Logstash, Elastic Agent or APM Server's job. And it is not a general front end you can point at another database — it speaks only to its own version-matched Elasticsearch cluster.

**Alternatives:**
- **Grafana** — dashboards over many datasources at once, Elasticsearch among them. The right choice when the numbers you need are spread across systems; weaker at free-form exploration of raw documents, and it administers nothing in the Elastic Stack.
- **OpenSearch Dashboards** — the fork taken from Kibana 7.10 when the licence changed, the same shape over an OpenSearch cluster. Apache-2.0 licensed, but it does not track Kibana's later work, so the newer apps and much of Lens are absent.

**Example:** A spike of server errors is being investigated. An engineer opens Discover on the `logs-*` data view, narrows the time range to the last thirty minutes, and types `service.name : "checkout" and http.response.status_code >= 500` in KQL. Clicking one value of `host.name` in the field list adds it as a filter and shows the errors are confined to a single host. The search is saved, and a Lens chart of the same count over time is put beside it on a dashboard.

</details>

### LangChain
`llm-framework`

An open-source Python and JavaScript framework for building applications on top of large language models. It puts one interface in front of every model provider, vector store and tool, so an application is assembled from interchangeable pieces rather than written against a single vendor's API.

<details><summary>Details</summary>

**How it works:** `langchain-core` defines a small set of abstractions — chat models that take a list of messages and return one, prompt templates, output parsers, retrievers and tools, alongside embedding models and vector stores. The first five implement one common *Runnable* interface — `invoke`, `batch`, `stream` and their async twins — and because that shape is uniform they compose with the `|` operator into a chain that streams and batches end to end. Embedding models and vector stores are the exceptions, keeping their own methods, which is why a vector store joins a chain through the retriever it returns rather than in the pipe itself. Each provider lives in its own package — `langchain-openai`, `langchain-anthropic` and the rest — so the abstraction is what the application imports and the provider is a dependency; messages carry a neutral system / human / AI / tool shape that each integration translates to its own wire format. A *tool* is a function plus a schema describing its arguments, handed to the model's tool-calling API: the model replies with a tool call, the application runs the function, and the result goes back as a tool message — the loop that makes an agent. Retrieval-augmented generation is assembled from the same parts: a loader and a splitter cut documents into chunks, an embedding model turns each chunk into a vector, a vector store holds them, and a retriever fetches the nearest ones for a question so the prompt template can put them in front of the model. Since 1.0, released in 2025, a single prebuilt agent constructor is the standard entry point for that loop and runs it on LangGraph, and the older chain and agent classes have moved to a separate legacy package.

**Boundary:** Not a model and not a provider — it runs no inference and ships no weights, so every call goes out to a provider's API or a local runtime, and it hosts and fine-tunes nothing. Not an observability or evaluation product either: the tracing hooks are in the open-source packages, but the service they report to, LangSmith, is a separate commercial product with its own key, and nothing in the framework requires it. The confusion worth settling is LangChain against LangGraph, its sibling library: a LangChain chain composes model calls and runs to completion, while LangGraph executes a graph of steps holding state across turns, with checkpointing, interruption and resumption — they pair rather than compete, and since 1.0 the agent loop above is LangChain's API over LangGraph's runtime. And the common interface is not portability: the chain survives a change of provider, while tool-calling behaviour, context limits and prompt sensitivity do not, so the prompt is retuned anyway.

**Alternatives:**
- **LlamaIndex** — the same kind of framework with retrieval at its centre rather than as one pattern among many: richer ingestion, indexing and query machinery for documents. A thinner catalogue for everything that is not retrieval.
- **The provider's own SDK with your own glue** — one dependency, no abstraction to learn, and each provider's newest features on the day they ship. You write the tool loop, the retrieval plumbing and the streaming yourself, and a second provider means writing them twice.

**Example:** A support assistant answers from a product manual. A loader reads the PDFs, a splitter cuts them into chunks, and an embedding model turns each into a vector held in a vector store. At question time a retriever returns the nearest chunks, a prompt template drops them into the system message, and the chain `prompt | model | parser` is invoked. Swapping the chat model for another provider's is a change of import and dependency; the prompt still has to be retuned against the new model.

</details>

### OpenShift
`container-platform`

Red Hat's Kubernetes distribution: a certified Kubernetes cluster shipped with the parts a team would otherwise assemble — a web console, an image registry, an ingress router, a build system and a sign-in server — and with tighter security defaults than upstream.

<details><summary>Details</summary>

**How it works:** The API is Kubernetes', plus OpenShift's own additions: a *Route* publishes a Service on a hostname through the cluster's HAProxy router, a *BuildConfig* with *Source-to-Image* turns a Git repository into a container image inside the cluster, and a *Project* is a namespace carrying extra metadata. What a pod may ask for is decided by a *security context constraint* (SCC); the one granted to ordinary users — `restricted-v2` since version 4.11, `restricted` before it — refuses containers that run as root or that pick their own user, and instead assigns each project a range of high UIDs and runs every such container in group 0. Since version 4 the cluster manages itself through operators — one per component, driven by a cluster version operator — so an upgrade is a declared target version rather than a sequence of steps. The `oc` CLI is `kubectl` plus commands for the extra objects.

**Boundary:** A distribution, not a different orchestrator — anything written against the Kubernetes API still applies, and Ingress objects are accepted and turned into Routes. The friction is the security defaults rather than the API: an image that assumes root runs on a stock cluster and is rejected here. OKD is the community distribution the product is built from, the same shape without subscription or support. And the name covers several things: a cluster you install and run yourself, and managed services — ROSA on AWS, ARO on Azure — where the control plane is operated for you. A multi-cluster manager such as Rancher is not a rival but a layer above: it imports and manages conformant clusters, OpenShift's included.

**Alternatives:**
- **Upstream Kubernetes assembled yourself**, whether installed with kubeadm or taken as a managed service such as EKS or GKE. Nothing is opinionated and nothing is imposed, so the console, registry, router, build system and admission policy are each a choice you make and wire up.
- **Another vendor distribution** such as SUSE's RKE2. A conformant cluster with hardening profiles and a support contract, and far lighter to run — but no registry, no build system and no console of its own.

**Example:** A team moves a working Deployment across from a stock cluster. The image runs as root and writes to a directory its Dockerfile created and left owned by root; on OpenShift the pod is admitted under `restricted-v2` with an arbitrary UID from the project's range, cannot write there, and crash-loops. The fix is to make that directory group-writable and owned by group 0, which every such container belongs to — not to grant the pod a looser SCC.

</details>

### Prometheus
`metrics` `application-monitoring`

A server that collects numeric measurements from services and stores them as time series to query and alert on. In its normal deployment it pulls rather than receives: each target exposes its current values on an HTTP endpoint, and the server fetches that endpoint on a fixed interval.

<details><summary>Details</summary>

**How it works:** Targets come from static configuration or from *service discovery* — a Kubernetes API, DNS, a file — so a new pod is scraped without editing anything. A scrape returns a line-based text exposition of every metric the target currently holds, and each value becomes a sample in a *time series* identified by the metric name plus a set of key-value *labels*: `http_requests_total{method="POST",status="500"}` is a different series from the same metric with `status="200"`. An instrumentation library in the service keeps those values in memory — a *counter* that only rises, a *gauge* that moves both ways, a *histogram* of observations sorted into buckets. Anything that cannot be instrumented directly, such as a host or a database, gets an *exporter*: a small process that reads it and exposes the same kind of endpoint. Samples land in a local time-series database and are queried with *PromQL*, which selects series by label — exactly, or by regular expression with `=~` — and whose functions work on the shape of a series rather than on bare values: `rate()` turns a counter into a per-second rate over a stated window, and copes with the counter resetting when the process restarts. *Recording rules* precompute expensive expressions on a schedule; *alerting rules* evaluate an expression on the same schedule and send a firing alert to *Alertmanager*, a separate process that groups, deduplicates, silences and routes it to email, chat or a pager. A rule may carry a `for` duration, holding the alert pending until the expression has been true that long, so a momentary spike does not page anyone.

**Boundary:** Numbers only, and low-cardinality ones. Cost is per series, so a label carrying a user ID or a trace identifier creates a series per value and will exhaust the server — anything per-request-identifiable belongs in logs or traces, which are different systems. Not a durable or clustered store either: a server is a single node writing to local disk, retaining 15 days by default and replicating nothing, so high availability is usually two identical servers scraping the same targets, and long-term or cross-cluster querying is added by a system built over it — Mimir, which takes a *remote write* stream of samples, or Thanos, which in its usual form runs a sidecar uploading completed data blocks to object storage. Both are complements, not rivals. Scraping is also sampled rather than exact: a missed scrape is a gap, which rules it out for billing. And it is not a dashboard — it ships only a bare expression browser, and the graphs people picture are Grafana's, a separate product reading it as a data source.

**Alternatives:**
- **VictoriaMetrics** — scrapes the same endpoints and answers PromQL, on less memory and disk, and clusters where Prometheus does not; the size of that saving is its own vendor's benchmark rather than an independent figure. It is a re-implementation rather than the same code, so edge behaviour and PromQL corners can differ.
- **A hosted metrics platform** such as Datadog — an agent pushes to a service you do not operate, with retention, dashboards and alerting included. You stop holding the data, and you pay per host and per custom metric, so cardinality becomes a bill rather than an outage.

**Example:** A service exposes `http_requests_total` with a `status` label, incremented on every response. An alerting rule evaluates `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.05` with a `for` of ten minutes, and Alertmanager then pages whoever is on call. Adding the requesting user's ID as a label on that counter would create one series per user and eventually take the server down; the query never needed it.

</details>

### Pydantic
`data-validation`

A Python library that turns type annotations into runtime validation: you declare a class whose fields carry ordinary type hints, and constructing it checks the incoming data against them, converting what it safely can and reporting every field that fails rather than only the first.

<details><summary>Details</summary>

**How it works:** A model subclasses `BaseModel` and declares annotated fields. At class definition the annotations are compiled once into a validation schema executed by `pydantic-core`, a Rust extension — v2's design, and why validation is not the field-by-field Python loop it looks like. `Model(**data)` or `Model.model_validate_json(raw)` validates and returns an instance; a failure raises a single `ValidationError` holding one entry per failing field, each with its location in the input. That accumulation is across fields: a field stops at its first failed check, and a whole-model validator runs only once every field has passed. In the default lax mode a value is converted where the conversion is unambiguous — the string `"17"` satisfies an `int` field — while strict mode rejects it. `Field()` and `Annotated` attach constraints such as `ge=0` or `max_length`, and `@field_validator` and `@model_validator` hook in arbitrary checks. `model_dump()` goes the other way, back to plain Python objects or JSON, and `TypeAdapter` applies the whole machinery to a bare annotation with no model class. These are v2's names; v1 spelled them differently throughout.

**Boundary:** Runtime, not static. mypy and pyright read annotations without running anything and can say nothing about a JSON payload that arrives at 3am; Pydantic says nothing about code it never executes — the two are complements, and models type-check like ordinary classes. It also validates at a boundary rather than continuously: a model is checked when it is constructed, and a field assigned afterwards is not rechecked unless `validate_assignment` is configured on. And it is not an ORM and talks to no database — `from_attributes` lets a model read values off a SQLAlchemy instance, which is the whole of the relationship. A plain `dataclass` is the contrast that makes the point: the same annotations, enforced by nothing.

**Alternatives:**
- **marshmallow** — schemas written as explicit field objects, separate from the class being loaded. More room where the wire format and the object differ sharply, at the cost of declaring each field twice in a form no type checker reads.
- **msgspec** — the same annotation-driven validation aimed squarely at speed, decoding JSON straight into typed structs. Faster on decode and lighter, though the margin is its own project's benchmark, and with far less of the customisation and surrounding ecosystem.

**Example:** `class Order(BaseModel):` with `id: int` and `quantity: int = Field(ge=1)`. Validating `{"id": "17", "quantity": 0}` converts `id` to the integer `17` and raises `ValidationError` naming `quantity` and the `ge` constraint it failed. `{"id": "17", "quantity": 2}` passes, and `model_dump()` on the result returns `{"id": 17, "quantity": 2}`.

</details>

### SonarQube
`static-analysis`

A server that inspects source code without running it and judges whether a change is fit to merge. A scanner runs inside the build and uploads what it found; the server weighs that against a policy and records a pass or fail.

<details><summary>Details</summary>

**How it works:** The scanner parses each file against a *quality profile* — the set of rules active for that language — and reports *issues*, each with a rule, a location and a severity. The server keeps them per project and per branch, then evaluates the *quality gate*: a small list of threshold conditions, such as no new issues above a given severity, or coverage on new code at or above a percentage. The shipped default applies its conditions to *new code* only — lines added or changed since a chosen baseline — so an old codebase with years of debt is not permanently red. Coverage is not measured here: the build produces a report with its own tool, such as JaCoCo or lcov, and the scanner uploads it to be judged against the gate. The upload is asynchronous and the scanner exits successfully whatever the verdict, so a red gate blocks nothing unless the build is told to wait for it — `sonar.qualitygate.wait=true` on the scanner, or a `waitForQualityGate` step in Jenkins. A gate wired without that is a gate that cannot fail.

**Boundary:** Not a test runner and not a coverage tool — it never executes the code, and a coverage figure it shows was measured by something else. Nor is it a replacement for the linter in an editor: it is a server holding history and a policy, and the local companion that flags the same rules as you type is a separate product (SonarQube for IDE, formerly SonarLint) run alongside it. It reads the code you wrote, not the dependencies you pulled in, so vulnerable third-party packages remain a separate scanner's job — recent commercial editions have begun adding that, so treat it as edition-specific. Branch and pull-request analysis is likewise edition-specific rather than universal.

**Alternatives:**
- **Codacy Cloud** — a hosted platform with the same scan, history and gate-on-a-pull-request shape, and nothing to operate. The code leaves your network to be analysed, which is often the reason SonarQube is self-hosted in the first place.
- **Per-language linters wired into CI**, each failing the build on its own exit code. No server to run and no new vocabulary, and the build genuinely fails by default — but no shared history, no cross-language view, and no notion of new code, so a large legacy codebase either fails from the first day or has the check turned off.

**Example:** A pull request adds two hundred lines. The build runs the tests, writes a JaCoCo report, and the scanner uploads it with the issues it found, waiting for the verdict. Coverage on those new lines is 55% against a gate condition of 80%, so the gate fails, the waiting step exits non-zero and the merge is blocked — the older code sitting at 40% is outside the new-code baseline and counts for nothing.

</details>

### SQLAlchemy
`orm`

A Python library for talking to relational databases in two layers: a SQL expression toolkit that builds statements as Python objects, and an object-relational mapper that keeps Python instances in step with the rows they came from. Both run through one engine, which renders each statement into the dialect the target database actually speaks.

<details><summary>Details</summary>

**How it works:** `create_engine("postgresql+psycopg://…")` selects a *dialect* and holds a connection pool. Statements are built as expression trees — `select(User).where(User.name == "jsmith")` — and rendered to SQL with bound parameters by that dialect at execution. The ORM adds a *Session*, a unit of work: it keeps an *identity map* so one row is one object within a session, records the changes made to those objects, and emits the INSERT, UPDATE and DELETE for them in dependency order at *flush* — automatically before a query and at commit, not at the moment of assignment. Relationships between mapped classes load *lazily* by default: touching `order.customer` emits its own SELECT there and then, unless the query asked for it up front with a loader option such as `selectinload`.

**Boundary:** Not a database driver — it sits on top of DBAPI drivers such as psycopg and hands them the SQL it generated. Not a schema manager either: it can create tables from the mapping, but migrating a live schema is Alembic's job, a separate project by the same author that pairs with it rather than competing. And the ORM is a layer, not the whole library — Core is usable on its own, and since 1.4 the two share one construct, `select()`, for building statements, which 2.0 made the only way. The lazy loading that makes the ORM comfortable is also its characteristic failure: a loop over a hundred orders touching `order.customer` runs a hundred and one queries.

**Alternatives:**
- **Django ORM** — models, migrations and an admin site in one framework, with far less to wire up. Less control over the SQL emitted, and it expects the rest of Django around it.
- **Peewee** — a small single-purpose ORM that can be read through in an afternoon. Fewer loader strategies and a thinner dialect layer, which tells on anything beyond straightforward queries.

**Example:** `session.get(Order, 17)` returns the mapped object, from the identity map if that row is already loaded. Setting `order.status = "shipped"` emits nothing yet; the UPDATE goes out at the next flush, and `session.commit()` flushes and commits in one step.

</details>
