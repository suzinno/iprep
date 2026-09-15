# Infrastructure and Delivery

> 21 questions on container image construction and hardening, Kubernetes and OpenShift scheduling, requests, limits and graceful shutdown, [Terraform](https://developer.hashicorp.com/terraform/docs "Terraform — Infrastructure as code tool that declares and provisions cloud infrastructure from configuration files") and state, [CI](https://en.wikipedia.org/wiki/Continuous_integration "Continuous Integration — Automatically builds and tests code on every change")/[CD](https://en.wikipedia.org/wiki/Continuous_deployment "Continuous Deployment — Automatically releases every build that passes the pipeline's gates to production without a manual step") and GitOps deployment and rollback, and quality gates and dependency hygiene. Answers are written from the project briefs and system design documents in this case, weighted toward the client brief in `candidate-profile.txt`.
> Questions supplied by the client, except INF-02, INF-03, INF-05, INF-06, INF-07, INF-08, INF-09, INF-10, INF-11, INF-12, INF-13, INF-14, INF-15, INF-16, INF-17, INF-18, INF-19, INF-20 and INF-21, which were generated.
> Difficulty tiers are defined once, in [README.md](README.md).

## Questions by project

- **cancer-support-platform** — INF-02, INF-03, INF-04, INF-05, INF-06, INF-07, INF-08, INF-09, INF-10, INF-11, INF-12, INF-13, INF-14, INF-15, INF-16, INF-17, INF-18, INF-19, INF-20
- **retail-software-marketplace** — INF-02, INF-03, INF-04, INF-05, INF-06, INF-08, INF-09, INF-10, INF-11, INF-12, INF-13, INF-14, INF-15, INF-16, INF-17, INF-18, INF-19, INF-20
- **general** — INF-01, INF-21

---

## 1. Containers and images

---

### INF-01. What is in your Dockerfile that a generated one is not — and what would you refuse to put in an image, however convenient?

**Level:** Q1 — baseline · **Project:** general

**Brief answer**
A multi-stage build, so no compiler or build dependency reaches the runtime image. A non-root user with an explicit numeric id. A base pinned by digest. Dependencies installed from a lockfile before the source is copied, so the cache layer survives a code change. And a real health check. What I would refuse is any secret, in any form: a build argument, an environment variable, or a file in a discarded stage. The reason is that layers are not private.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the generated one usually gets wrong.**

- **One stage.** The build toolchain ends up in the runtime image: the compiler, the headers and the package manager's cache. That triples the size. More importantly, it triples the vulnerability-scan surface. A multi-stage build installs dependencies in a builder and copies only the resulting environment forward.
- **Layer order that defeats the cache.** If `COPY . .` comes before installing dependencies, every source edit reinstalls everything. Copy the lockfile, install, then copy the source. The client expects its pipeline to run for twenty to thirty minutes, and on a pipeline like that, minutes of build cache are worth having.
- **Root.** The default is root. A non-root numeric user is a one-line change, and it turns a container escape from trivial into work. It also matters concretely on OpenShift, which assigns an arbitrary user id at runtime. So the image has to be group-writable where it needs to write, and it must not assume a fixed uid.
- **An unpinned base.** `python:3.12-slim` is a moving target. So the image built today and the image built next month are different artefacts with the same recipe. Pin by digest.
- **No lockfile discipline.** If you install from a loose requirements file, the resolver picks whatever is current. [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects") with a committed lock is what keeps runtime and packages consistent across services. The cancer platform services do this. The drift it removes was previously a deploy-time surprise.
- **No health check, or one that only checks the process is alive.** A readiness probe that returns `200` while the database pool is exhausted will still send traffic to a pod that cannot serve it. Liveness and readiness need to mean different things.
- **No `.dockerignore`.** The build context ends up carrying the git history, local environment files, test fixtures and the virtual environment. That is slow, and it is a disclosure risk.
- **`CMD` in shell form**, so the process is not process id 1 and does not receive `SIGTERM`. That breaks graceful shutdown. Graceful shutdown matters where workers are drained rather than killed: they stop consuming, finish the in-flight task and exit inside the grace period.

**What else I put in.** Version and commit metadata as labels, so a running container can be traced to a commit without guessing. `PYTHONDONTWRITEBYTECODE` and `PYTHONUNBUFFERED`. I set the second because unbuffered output is the difference between having logs from a crash and not having them. An explicit `WORKDIR`, and explicit ownership on anything that needs to be writable. And the smallest base that still has a package manager I can patch with. A distroless base is marginally smaller, but it is much harder to fix under time pressure. I would rather take a slim Debian base that I can update.

**And a scan as a blocking gate**, with base images rebuilt on a schedule, not only when the application changes. Otherwise a service that has not been deployed for two months is running two months of unpatched advisories, and nothing reports it.

**What I refuse to put in, and why.**

- **Any secret.** Not as a build argument, not as an environment variable, and not as a file deleted in a later layer. The layer persists, and `docker history` shows build arguments. Secrets come from the platform at runtime: from Key Vault, projected as files and reached by workload identity. They are never baked into an image, and they are never environment variables set at build time. A secret in an image is a secret in a registry, and a registry is a distribution system.
- **Credentials for the package index**, for the same reason. Build-time secret mounts exist exactly so that these credentials do not become layers.
- **Anything that makes the image environment-specific.** One image is promoted from staging to production and configured at runtime. If you build an image per environment, the artefact that was tested is not the artefact that ships.
- **A debugging shell, a package manager left usable, or diagnostic tools "just in case".** They are attack surface. The modern answer is an ephemeral debug container that is attached when needed, not a permanently larger image.
- **`latest` anywhere**, in the base or in a deployment manifest. The deployment references a digest. So a mutable tag cannot be swapped underneath a running cluster. That is a supply-chain property, not a matter of tidiness.
- **Test fixtures, sample data, or the test suite.** They make the image bigger. Occasionally they also contain something that should not leave the repository.

</details>


---

### INF-02. What does your Compose stack contain, and how close is it to production?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It contains the real components, at the same pinned versions as production: database, document store, search, cache and broker. The reason is that the integration stage in the pipeline runs against that same stack. It is not a convenience. It is what makes the tests mean something.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it and why it is the real thing.** On the cancer platform: the relational database, the document store, the search cluster, the cache and the broker. On the marketplace: the relational database, the document store and the cache, and the cache appears twice in different roles. They run the same major versions as production, pinned. The pipeline's integration stage brings up the same definition.

The reason is specific, not about how it looks. A mocked test passes while two things are broken: the projection pipeline and the query plans. And a mocked broker cannot fail the way a real one does. None of these exist in a fake: redelivery, acknowledgement semantics, the memory watermark blocking publishers, and an unroutable publish that is still confirmed. So the components that carry the guarantees are real everywhere.

**Where it is honestly not like production.** It runs single nodes, not clusters. So replication, failover, quorum behaviour and network partitions are not exercised at all. There is no gateway, no managed identity and no service bus. Locally, those are stubbed or bypassed. Volumes are small, so nothing about plans at scale is represented. Resource limits are absent, so nothing about throttling or memory pressure appears.

I would rather state those gaps than let the local stack suggest coverage it does not have. The consequence is that anything that depends on cluster behaviour needs a real environment to verify it. That includes some of the most important properties in the design. That is exactly why a restore and a failover get rehearsed instead of assumed.

**What makes it usable day to day.** Healthchecks with dependency ordering, so the application waits for the database to be ready instead of crash-looping. Seed data from the same factories the tests use, so a developer's local data exercises the awkward cases. Named volumes, so a restart does not lose state. And a documented one-line reset that does lose it.

**The property I care most about.** A developer runs the same stack the pipeline runs. So when something fails in the pipeline and passes locally, the difference is not the dependencies. That removes the most frustrating category of debugging there is.

</details>


---

### INF-03. How do you pin things — base images, packages, and the tool versions in CI?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Everything is pinned to an immutable identifier. Base images are pinned by digest, packages by a committed lockfile, tools by exact version, and pipeline images by digest too. The rule is that a build with unchanged inputs produces the same result. Any moving reference breaks that.

<details>
<summary><strong>Detailed answer</strong></summary>

**Base images by digest.** A tag is a pointer that can be repointed. A digest is content. If you pin by tag, the same source can produce a different image tomorrow. Then a failure is impossible to attribute, and "the tested image" is a fiction. The cost is a scheduled job that bumps the digest and opens a merge request. That is a small automation, and it turns an implicit update into a reviewed one.

**Packages by lockfile**, committed, with the transitive tree resolved exactly. Constraints go in the manifest, and exact versions go in the lock. That is what makes the pipeline, the developer machine and the production image identical.

**Pipeline tooling.** The linter, type checker, formatter and scanners are pinned to exact versions. The container images the pipeline itself runs in are pinned by digest. An unpinned linter that updates overnight fails the build for everyone, on code nobody touched. That is disruptive, and it is confusing because nothing in the repository changed. Tool versions are part of the environment.

**Deployment by digest.** The manifest references the image digest, not a tag. So a mutable tag cannot be swapped underneath a running cluster. And a rollback names a specific artifact, not a label whose meaning may have moved.

**Where pinning has a real cost, stated.** It turns automatic security updates into deliberate ones, so you now own the update cadence. That is the right trade. I would rather choose when to take a change than have it arrive during an incident. But it only works if the cadence is actually maintained. Pinning without an update process is how a service ends up two years behind, and that is a worse outcome than not pinning.

**So the pinning and the update automation are one decision.** Scheduled proposals for base image digests and package updates, in small batches, with a suite good enough that green is evidence. Pinning is what makes updates safe to automate. Automation is what makes pinning sustainable. Doing either one alone fails, in opposite directions.

</details>


---

### INF-04. How do you make a container image reproducible, and how do you keep base-image pinning from meaning "frozen on a vulnerable base forever"?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Reproducibility comes from pinning every input: the base by digest, dependencies by a committed lockfile with hashes, and system packages by version. It also comes from removing the sources of nondeterminism that remain, mainly timestamps and file ordering. The tension between pinning and staleness is resolved by automating the *update*, not by loosening the pin. Rebuild on a schedule, let a bot propose the new digest, and make the pipeline's vulnerability gate the thing that forces the merge.

<details>
<summary><strong>Detailed answer</strong></summary>

**What "reproducible" actually requires.** Bit-for-bit reproducibility is achievable, but it is rarely what people need. What is needed is two things. The same source produces a functionally identical image. And you can say exactly what is inside an image you built six months ago.

- **Base by digest**, not by tag. `python:3.12-slim` moves; `python@sha256:...` does not.
- **Application dependencies from a committed lockfile**, Poetry here. They are resolved once and installed identically everywhere. Ideally the lockfile has hashes, so a compromised or republished package fails the install instead of silently changing.
- **System packages pinned by version** where they matter. Also pin the package index snapshot, if the distribution supports it. This is the one people skip most, and it is the most common source of "it built differently today".
- **The build context controlled by `.dockerignore`**, so stray local files cannot get in and change the result.
- **Deterministic timestamps.** Use `SOURCE_DATE_EPOCH`, or a build tool that normalises timestamps. File modification times are the single largest source of digest differences between builds that are otherwise identical.
- **One image promoted across environments**, never rebuilt per environment. If the staging and production images are separate builds, the thing you tested is not the thing you shipped. No amount of pinning fixes that.
- **A software bill of materials generated at build.** Then, when a vulnerability is announced, "what is in this image" is a query, not an archaeology exercise.

**And then the artefact has to be referenced by digest downstream.** Both designs deploy digest-pinned images only. On the cancer platform, the pipeline's final act is committing a digest to the GitOps repository, which [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") reconciles. A mutable tag cannot be swapped underneath a running cluster. That makes "what is running" answerable with certainty. If reproducibility stops at the build and hands a mutable tag to the deployer, it has given away the property it just paid for.

**The staleness problem, which is the real question.** A pinned digest is frozen by construction, and freezing is the point. That holds until it means running a base with a known critical vulnerability, because nobody wanted to touch the pin. The answer is that **the pin is a record of what you chose, not a commitment to never choose again**. And the update has to be automated, or it will not happen.

1. **Rebuild on a schedule, whether or not the source changed.** The marketplace design rebuilds base images weekly. This alone picks up upstream security patches without anyone deciding to.
2. **Automate the digest bump.** A dependency bot opens a merge request that moves the base digest forward. The merge request runs the full pipeline, and a human reviews a small diff. The decision stays with a person; the *work* does not.
3. **Scan at build and make the scan blocking.** Image vulnerability scanning and dependency audit are pipeline gates in both designs. A gate that can only warn gets ignored. So the gate has to be able to fail the build. And it has to have been *shown* to fail, or nobody knows whether it works.
4. **Separate "found" from "must fix now" with a policy.** Block on critical and high findings that have a fix available. Ticket the rest with a deadline. Blocking on every finding trains everyone to bypass the gate. That is worse than a looser policy honestly applied.
5. **Have an expedited path.** When a serious vulnerability lands, the fix is a digest bump and a redeploy. That should be the same pipeline everyone uses daily, not a special procedure. The path you use every day is the one that works under pressure.
6. **Keep the runtime image small enough that the question stays manageable.** Fewer packages means fewer findings. A multi-stage build that leaves the compiler behind removes a large share of them permanently.
7. **Track base age as a metric.** Put "oldest base image in production, in days" on a dashboard. That makes drift visible before a scanner makes it urgent.

**The trade-off stated plainly.** Weekly rebuilds mean the running image changes without a code change. That is a small ongoing risk of an upstream regression. And that is exactly what staging, a smoke test and a canary are for. The other risk, an unpatched base, is worse, and it only grows over time. I would take the frequent small change over the rare large one. And I would say so in those terms, instead of treating it as obviously correct.

</details>


---

### INF-05. A container works locally and fails in the cluster. Where do you look?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
I look in this order: configuration and secrets, identity and permissions, the filesystem and user identifier, network policy, and resource limits. Almost every instance is one of those five. And each one can be told apart from the others in a couple of minutes.

<details>
<summary><strong>Detailed answer</strong></summary>

**Configuration.** A value is present in a local environment file and absent from the cluster's configuration. The failure is usually at startup, and the log says so, if the application validates its configuration on boot. It should do that, loudly, instead of failing later with something unrelated. Failing fast on a missing configuration value is one of the cheapest robustness measures there is.

**Identity and permissions.** Locally, the application uses a connection string. In the cluster, it authenticates as a federated workload identity. If the service account is not annotated correctly, or the role assignment is missing, the application cannot reach the database or the storage account. The symptom is an authorization error from the cloud provider that reads like a network problem. In my experience, this is the most common cause once configuration is ruled out.

**Filesystem and user.** Locally, the container often runs as root. In the cluster it does not, and on a stricter platform it runs as an arbitrary assigned identifier. Two things fail here: anything writing to a path owned by a specific user, and anything expecting a writable filesystem where the root filesystem is read-only. Temporary directories need to be explicit mounts.

**Network.** Network policy denying egress, a private endpoint the pod cannot resolve, or a name that resolves differently inside the cluster. Test from a debug container in the same namespace with the same service account. In about a minute, that separates "the application is wrong" from "the network is wrong".

**Resources.** The container is terminated for memory. Or it is throttled so much that startup takes longer than the probe threshold, and it restart-loops. Locally there are no limits, so the first time the process meets one is in the cluster.

**How I actually work through it.** First I read the previous container's termination reason, because it splits the problem space immediately. Then I read the whole startup log, not just the last line. The real error is usually several lines above the symptom. Then I run the same image in the cluster with a shell as the entrypoint, so I can inspect the environment as the process sees it. The answer is usually in what the pod's environment actually contains. And the pod's actual environment is different from what the manifest appears to say more often than you would expect.

</details>


---

### INF-06. How do you debug inside a running container in production, and what would you not do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First I use everything the telemetry can tell me. Then I attach a debug container to inspect, not to change anything. What I would not do: edit anything inside a running container, install tools into it, or restart it before capturing what I need. A restart destroys the evidence.

<details>
<summary><strong>Detailed answer</strong></summary>

**Almost always, telemetry answers it.** Traces show where the time goes. Structured logs, filtered by the correlation identifier, show the path a specific request took. Metrics show whether it is one pod or all of them. If those cannot answer the question, that is itself a finding. It means the instrumentation has a gap. Fixing that gap is worth more than debugging this one instance by hand.

**When I do need to be inside.** I use an ephemeral debug container, attached to the pod's namespaces and carrying the tools. That way the application image stays minimal. It also means I am not installing anything into a running production container. Installing something changes the thing being investigated, and it leaves the container in a state nobody can reproduce.

**What I look at.**

- The environment as the process actually sees it.
- Network reachability to its dependencies from inside the pod.
- Whether the filesystem is what the manifest claims.
- Process-level state: thread stacks, if the interpreter supports dumping them. That is the fastest way to find a whole worker pool stuck on the same lock.

**Before anything else: capture.** Logs from the current and previous instance. The pod description, including the termination reason. A heap or thread dump, if relevant. And the current metrics. A restart is often the correct remediation, and it destroys everything. So the order is capture, then remediate. I hold that order because of how often an incident has been resolved by a restart and then recurred a week later, with no evidence from the first occurrence.

**What I would not do.**

- **Edit code or configuration inside a running container.** The change vanishes on restart and is invisible to everyone. And the running system no longer matches what is declared.
- **Restart before capturing**, unless the cost of the outage really outweighs the evidence.
- **Exec into a container to read data**, on the cancer platform. Access to patient data goes through the audited path, not through a shell. Going around that path is a control failure, whatever the intent.
- **Leave a debug container attached**, or leave a temporarily relaxed policy in place. Both get forgotten.
- **Attach a debugger that pauses the process** on something serving traffic.

**And afterwards.** Whatever I had to go inside to learn becomes a metric or a log field. Then the next occurrence can be answered from telemetry. Debugging by hand in production is a signal about the observability. It is not a routine to get better at.

</details>

---

## 2. Kubernetes and runtime

---

### INF-07. What is different about OpenShift compared with plain Kubernetes, and what would you have to learn?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It is [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") with opinionated defaults, a stricter security posture, and its own resources added on top. The differences that cause real problems in practice are the security context constraints and its own build and route objects. Under the security context constraints, containers do not run as root, and they are assigned an arbitrary user identifier.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I have worked with.** Deployments to a managed OpenShift cluster, delivered by a GitOps controller from a manifest repository. Migrations ran as a pre-sync hook and a smoke test as a post-sync hook. So the delivery path and the workload shape are familiar. I have used the platform's own build tooling less.

**The differences that matter in practice.**

- **Security context constraints.** The default policy refuses root. It assigns an arbitrary, high-numbered user identifier at runtime. An image that assumes a fixed user, or writes to a directory owned by a specific user, fails. The fix is to build images with group-writable directories and with no assumption about the user identifier. That is good practice generally; OpenShift simply enforces it. This is the single most common reason why an image that runs elsewhere does not run on OpenShift.
- **Routes rather than ingress.** Routes have their own object and their own approach to certificates and termination. Ingress works too. But if you mix both, it is easy to get confused about which one is authoritative.
- **Projects rather than namespaces.** A project is a namespace with additional defaults from a project template. That template can also attach quota.
- **Its own build and image stream objects.** These can watch a registry tag and trigger a rollout. That is useful. But it is also a second mechanism to reason about when a GitOps controller is also managing the desired state. Two systems that both think they own the deployed image are a real source of confusion.
- **An integrated registry and an ecosystem built around operators.** So a lot of platform capability arrives as operators, not as raw manifests.

**What I would want to learn deliberately instead of assuming.** The exact constraint policy in use and what it permits, because that decides which images can run at all. How the platform's own networking layer is configured, since network policy behaviour differs. The upgrade cadence, which is more opinionated than on a plain cluster and affects planning. And whether the platform's build tooling or an external pipeline is authoritative. That decides where the source of truth for a deployed version lives.

**What transfers unchanged.** Everything about workload design: probes, resource requests and limits, graceful shutdown, autoscaling signals and pod disruption budgets. And the entire delivery discipline: expand-and-contract migrations, digest-pinned images, and declarative desired state with rollback as a revert. Those are the hard parts, and none of them are platform-specific.

</details>


---

### INF-08. Explain requests and limits, and what goes wrong when they are set badly.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Requests decide scheduling and what the pod is guaranteed. Limits cap consumption. The two failure modes are opposite, and both are common. Processor limits set too low cause throttling that looks like slow code. Memory limits set too low cause the process to be killed abruptly, with no stack trace.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** The request is what the scheduler reserves and what the pod is guaranteed. The limit is the ceiling. For processor time, exceeding the limit means throttling: the container is descheduled for the rest of its accounting period. For memory there is no throttling. Exceeding the limit can get the process killed.

**Processor limits set too low.** The symptom is latency spikes that correlate with nothing visible. The application is not busy and the database is fine, but periodically requests take much longer. What is happening is that the container used up its quota early in the accounting window, and it is being descheduled. This is especially bad with garbage collection and with startup. A short, legitimate burst gets throttled, and then the startup probe fails. That produces a restart loop that looks like a crash. The sign to look for is the throttling metric. It is not on most default dashboards, and it should be.

**Memory limits set too low.** The container is killed. There is no stack trace and no application log line. There is just a restart, with a status that the orchestrator records and nobody reads. It shows up as intermittent restarts under load, and it is often misdiagnosed as a crash bug. There is a subtlety with a runtime that manages its own heap: memory use grows until collection. So a limit set to the observed steady-state use will be exceeded routinely.

**Requests set too high** waste capacity. Nodes fill up with reservations that nothing uses. Then the cluster autoscaler adds nodes, and the bill grows for guarantees that sit idle.

**Requests set too low** mean the pod is scheduled onto a node with nothing to spare. It is also a first candidate for eviction under pressure. Its behaviour then depends on what else lands next to it, so its performance cannot be reproduced.

**How I set them.** From observed usage under realistic load, not from a guess. The request goes near the steady-state median. The limit goes above the observed peak, with real headroom. For memory, I prefer request and limit equal on anything important. Then, as long as the pod stays within its memory limit, its memory use does not exceed its request. Under node pressure, pods like that are evicted last. And its behaviour does not depend on its neighbours. For processor, I often set a generous limit, or none, on latency-sensitive services. The reason is that throttling a request-serving process to save capacity it was not going to use anyway is a bad trade.

**And I watch the throttling and termination counters as first-class signals.** The reason is that both failure modes are invisible in application metrics. One looks like slow code, and the other looks like a crash.

</details>


---

### INF-09. A pod is being killed and restarted repeatedly. Walk me through the diagnosis.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Read the termination reason first, because it splits the whole problem space in one step. The pod was killed for memory, failed a probe, exited non-zero, or was evicted. Each of those has a different cause and a different fix. Guessing between them wastes the most time.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: the last state and its reason.** The pod's status carries the previous container's exit reason and code. There are four broad outcomes.

- **Killed for exceeding memory.** No application log will explain it, because the process was terminated, not thrown. Look at whether the limit is below the actual peak. Look at whether there is a leak: memory that only climbs across restarts, instead of a sawtooth pattern. And look at whether one request shape allocates a huge amount. That is the usual cause when restarts correlate with a specific endpoint or a large import.
- **A probe failing.** A failing liveness probe restarts the container. A failing readiness probe only removes the pod from service. If liveness fails under load rather than at startup, the probe is measuring load, not liveness. Then it is causing the outage it claims to detect. If it fails at startup, the container needs longer than the probe allows. The fix is then a startup probe, not a more generous liveness threshold.
- **A non-zero exit.** An application crash or a failure to start: a missing configuration value, an unreachable dependency, or a failed migration. The answer is in the logs from the previous container instance. You need to fetch them explicitly, because the current instance's logs will not have it.
- **Evicted.** This is node pressure, on disk or memory, not anything about this pod. Look at the node, not the workload.

**Step two: the pattern.** Immediately on start, every time, is configuration or a dependency. After some minutes is memory or a leak. Under load is limits or probes. All pods at once is a deploy or a shared dependency. One pod is a node.

**Step three: reproduce with the safety off.** Run the image with generous limits and relaxed probes, and see what it does. If it survives, the problem is the limits or the probes, not the code. That is a much better place to be.

**Two specifics worth naming.** First, a worker being restarted mid-task is not just an availability problem. It is a durability question, and the answer must be that redelivery covers it. If a restart loses work, the acknowledgement mode is wrong. Second, a liveness probe that hits an endpoint touching the database will fail during a short database outage. It will then restart every pod at the same time. That turns a brief dependency problem into a full outage. Liveness should test the process. Readiness should test the dependencies.

</details>


---

### INF-10. How do you make a worker shut down safely mid-task?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Stop consuming first, finish the in-flight task, then exit. All of that is bounded by the termination grace period, and task chunk sizes must be small enough to finish comfortably inside it. And behind all of that sits at-least-once delivery, so an ungraceful kill causes redelivery, not loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence.** On termination, the orchestrator runs a pre-stop hook and sends a termination signal. It kills the process if the process is still running when the grace period runs out. The grace period is counted from the start of termination, and the pre-stop hook runs inside it. So:

1. **Pre-stop: stop accepting new work.** Cancel the broker consumer, so no further messages are delivered to this worker. Anything already prefetched is either processed or returned unacknowledged.
2. **Finish the in-flight task.** The signal handler sets a flag. The task loop completes the current item and does not start another one.
3. **Acknowledge, release resources, exit cleanly.**

**The numbers have to agree, and this is where it usually goes wrong.** The grace period must be longer than the longest realistic task. Otherwise the process is killed mid-task anyway, and the graceful shutdown is only for show. There are two ways to make that true: raise the grace period, or make tasks short. I strongly prefer the second. Chunk a large import into pieces sized to finish well inside the window. Then the worker is never far from a clean stopping point. Chunking also makes the whole system more tolerant of every kind of interruption, not just deploys.

**Why redelivery still has to work.** Graceful shutdown is best-effort. A node failure, an out-of-memory kill or an exceeded grace period all skip it. So the durable guarantee is late acknowledgement plus idempotent handling. The message is only acknowledged after the work completes, so an ungraceful death causes redelivery. And the handler tolerates running twice, because the guarantee lives in a database constraint. Graceful shutdown reduces how often that path is used. It is not what makes the system correct.

**For long-running work specifically.** Checkpoint progress, so a resumed task does not redo everything. For example, an import that records which chunk it completed can restart at that boundary instead of at the beginning. This matters more as tasks get longer. It is the difference between a redelivery costing seconds and costing an hour.

**For the web tier**, the shape is the same, with different mechanics. As soon as the pod starts terminating, it is taken out of the service endpoints. Traffic stops arriving once that change has reached the load balancer, and a brief pause covers that propagation delay. Then in-flight requests complete. Skipping the pause is the classic source of connection errors during a rollout that is otherwise clean. The pod stops before the routing layer has noticed.

</details>

---

## 3. Terraform, CI/CD and GitOps

---

### INF-11. How do you structure Terraform so more than one person can work on it?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
I split state along blast-radius lines, not by resource type. I use one module set with a variables file per environment. And I lock state, so two applies cannot collide. The structure question is really a question about what one careless apply can destroy.

<details>
<summary><strong>Detailed answer</strong></summary>

**State splitting is the main decision.** With one monolithic state, every apply plans the whole estate and plans take a long time. Everyone also competes for the lock, and a mistake can affect anything. So state is split. The seam I use is blast radius and change frequency together:

- the network and identity layer changes rarely, and it is catastrophic to get wrong;
- the data layer changes rarely, and it holds the data;
- the application layer changes constantly, and it is recoverable.

That gives three states. The application layer's identity does not have permission to touch the other two.

**One module set, variables per environment.** Environments differ in instance sizes and counts, not in topology. That is what makes a staging smoke test meaningful. Staging is the same architecture at smaller sizes, not a different architecture that happens to share a name. Copying the configuration per environment guarantees divergence within a quarter.

**The operational rules.**

- **State in a versioned, locked backend.** Then two concurrent applies cannot corrupt it, and a damaged state can be recovered from a previous version.
- **Applies run only from continuous integration on the default branch**, authenticated by workload identity federation. Nobody applies from a laptop. So state and reality cannot diverge through a helpful local fix.
- **Plan on every merge request, posted for review.** The plan is the review artifact. Reviewing configuration without the plan means reviewing intent, not effect. The two differ most on the changes that matter. For example, a plan that shows a resource being destroyed and recreated is the finding, and it is invisible in the source diff.
- **Production has a manual gate between plan and apply.** So a human confirms that the plan they read is the plan being applied.

**What is in it that people leave out.** Alert rules and role assignments. With alert rules in code, a hand-silenced alert is a reviewable diff. Otherwise it is discovered six months later, when the thing it watched failed quietly. With role assignments in code, a widened permission is a diff, not a click nobody sees.

**The concentration of privilege, stated honestly.** The deploy identity is the largest single concentration of privilege in either design. The right shape is to split it: a plan-only identity for merge requests, an apply identity gated on protected branches, and the network and data modules under their own identity. That decision is worth taking before the first production apply, not after an incident. It is also the kind of change I would flag for review instead of making it on my own judgement.

</details>


---

### INF-12. What do you do about a resource someone created by hand in the portal?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
If a hand-made change touches a resource that Terraform manages, the change shows up in the plan and fails the pipeline. A resource that Terraform does not manage at all never shows up in the plan. The origin tag that the pipeline puts on everything it creates is what finds that resource. Either way, the drift then gets codified or it gets removed. To codify an unmanaged resource, it is first imported into state. What I would not do is quietly reconcile the drift. The reason is that the moment the code stops describing reality, infrastructure as code becomes only for show.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why drift has to be a failure, not a warning.** A configuration that describes most of the infrastructure is worse than one that describes none, because people trust it. The plan is the mechanism that keeps the description honest. If drift is tolerated, the plan becomes noise that nobody reads. And that is exactly when the destructive change slips through unnoticed.

**What actually happens.**

1. **Detected.** A scheduled plan runs on the default branch, not only on merge requests. So a change made outside the pipeline to a managed resource appears within a day, not at the next deploy. A resource that Terraform does not manage never appears in a plan. The origin tag, described below, is what finds it.
2. **Understood before touched.** Why does the drift exist? Usually the answer is an incident. Someone scaled something or opened a firewall rule at two in the morning, and they were right to. That is a legitimate act. The failure is not having codified it afterwards.
3. **Import or remove.** If a hand-made resource should exist, it is imported into state and written into the configuration, so the next plan is clean. If a hand-made change to a managed resource should stay, it is written into the configuration. If the drift should not exist, it is removed through the configuration. For a hand-made resource, that means importing it into state first.
4. **Never resolved by applying blindly.** A plan that proposes to undo a hand-made change might be right. Or it might be about to delete something an incident depends on. That decision needs a person.

**The emergency case, handled explicitly.** Break-glass changes will happen. If you pretend otherwise, you get a policy that people work around. The rule is that a manual change is permitted during an incident. It must be codified within an agreed window and tracked as a ticket created at the time. That keeps the discipline without making the incident harder.

**Two related habits.** First, everything the pipeline creates is tagged with its origin. So an untagged resource is immediately identifiable as unmanaged. Second, nobody has standing write access to the production subscription. A human who needs it goes through a time-bound elevation that writes an audit record. That is the control that actually reduces drift, because it makes the manual path visible instead of convenient.

**The uncomfortable case.** A resource created by another team, in a subscription we share. That needs a conversation, not a technical fix. The resolution is usually a boundary, not an agreement to be careful. That boundary is separate resource groups or subscriptions with separate ownership.

</details>


---

### INF-13. How do you roll back — application code, database schema, and infrastructure?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Application code: redeploy the previous digest, or revert the manifest commit. Schema: deliberately, not at all. Expand-and-contract means the old code runs against the new schema, so there is nothing to undo. Infrastructure: revert the configuration and apply. The caveat is that some resources do not roll back cleanly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Application code.** Roll back to the previous image by digest, not by tag. A mutable tag may have been repointed, and then "the previous version" is not what you think. On the GitOps side, that is a revert of the manifest commit. On the direct-deploy side, it is a redeploy of the recorded digest. Either way, it should be one action, take a couple of minutes, and need no decisions.

**The schema is the interesting one, and the answer is that it is not rolled back.** Migrations are expand-only. A release adds nullable columns, new tables and concurrently-built indexes. Removals come at least one release later, once nothing reads the old shape. The consequence is that the previous image runs correctly against the current schema the whole time. So rolling back the code needs no schema change at all.

That is a deliberate choice: one hard problem is replaced by a discipline. Nobody will run a down-migration on a table with hundreds of millions of rows under pressure. It is slow and it is untested. And if the forward migration destroyed data, the down-migration cannot recreate it. So the design does not depend on having one. A migration that cannot be written in expand-and-contract form gets split across two releases. That is a rule, not a case-by-case judgement.

**Infrastructure.** Revert the configuration and apply. That works for most changes. But there are real exceptions worth knowing in advance:

- a resource whose change forces replacement will be destroyed and recreated on the way back, and for anything stateful that is not a rollback;
- some settings are one-way;
- a reverted change may not restore a dependent resource's state.

So for infrastructure, the more useful discipline is reading the plan properly before the first apply. The reason is that the reverse plan is not guaranteed to be symmetric.

**What makes a rollback actually work in practice**, beyond the mechanism: it has to be rehearsed. A rollback path that nobody has executed is an assumption. The moment you need it is the worst moment to find out that the previous image no longer starts because a configuration key was removed. So the rollback is exercised as part of a release, not trusted.

**And knowing when not to.** Suppose the bad release has already written data in a new shape. Then rolling back the code means the old version meets data it does not understand. In that case, rolling forward with a fix is correct. Recognising that case quickly is the actual skill. That is why, before any risky release, I ask what the bad version will have written by the time we notice.

</details>


---

### INF-14. How do you know a pipeline gate can actually fail?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By having seen it go red for a real reason. That is the only acceptable evidence. The way to get that evidence deliberately is a known-pass and known-fail pair. Introduce a change the gate should catch, confirm the build fails, then restore. Two inputs, a few minutes.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the question needs asking at all.** From the outside, a gate that cannot fail looks exactly like a gate that works. Both are green forever. And in most teams, a green pipeline is the single most trusted signal. So a broken gate does not just fail to protect. It actively gives false confidence, and it keeps doing that until an incident.

**The specific ways gates turn out to be only for show.**

- **Configured to report, not to enforce.** A quality or scanning stage prints findings and exits zero. This is very common, because report mode is the sensible way to introduce a tool, and nobody comes back to switch it.
- **Exit status lost through a pipe.** A command piped through a log filter reports the filter's status, not the command's. The fix is to capture the status on the command's own line and exit with it. This one is easy to introduce by accident while making output readable.
- **A step in a shell that exits before it runs.** Under strict error handling, a search that correctly finds nothing returns non-zero, and that kills the step. That is the passing branch of an assert-absent check, and it dies before it prints anything.
- **Invoked differently from how it runs locally.** Some analysers report different findings for one file alone than for a directory sweep. So if you verify a guard through a convenient local invocation, it is still unverified in the pipeline. The invocation has to be copied from the pipeline definition, not approximated.
- **A test that passes for a reason unrelated to its name.** The fixture satisfies the assertion before the logic under test is reached.

**What I do about it.**

- **Verify each gate once, deliberately, with a real known-fail input.** Not a syntax error, but a mutation that leaves the file parsable. A syntax error makes everything fail at once. That looks like overwhelming evidence, and it is worthless. It is a could-not-run, not a catch.
- **Three outcomes, never two: pass, fail, and could-not-run.** Take a check with no explicit could-not-run branch. It folds a tool error, or a mutation that did not take, into whichever branch was written first. And that branch is always the one that confirms what you expected.
- **Commit a known-pass and known-fail pair for anything guarding an invariant.** Then, if someone weakens the gate later, that pair fails. This is the only mechanism I know that makes a gate resistant to being quietly loosened.
- **Report on gate history.** A stage that has never gone red is either perfect or broken. It is worth a look to find out which.

**Where I apply the same scepticism.** Alerts and monitoring, in exactly the same way. An alert rule with a typo in a label matches nothing and reports nothing, forever. The only evidence that it works is having seen it fire.

</details>


---

### INF-15. How do you answer "what exactly was running in production at two o'clock last Tuesday"?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
From version control, if the desired state is a commit and images are referenced by digest. Then the answer is a revision at a timestamp. It is not an archaeology exercise across deploy logs. That property is most of the reason why the regulated system uses a pull-based delivery model.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it is a hard question in most systems.** A deploy job ran. What it produced depends on what its inputs resolved to at the time: a mutable tag, a dependency range, or a configuration value read from somewhere else. The job log says it succeeded. To reconstruct the actual artifact months later, you have to correlate three things. They are a build number, a registry tag that may have been repointed, and a configuration store with no history.

**What makes it answerable.**

- **Images referenced by digest, not by tag.** A tag is a pointer that can be repointed; a digest is the content. This is the single most important part. Without it, "we deployed version 2.3.1" names a label, not an artifact.
- **Desired state as a commit.** The manifest repository holds what should be running, so the state at any timestamp is a revision. A rollback is a revert of that revision. It is not a re-run of a job whose inputs may have changed since.
- **A controller reconciling that state continuously.** So drift between what is declared and what is running is detected, not inferred. Without reconciliation, a hand-edited resource survives silently until the next deploy overwrites it. Then nobody can say which state was in effect during an incident.
- **Configuration in the same repository as the manifests**, or at least versioned. Then a change to a value is as traceable as a change to code.
- **Infrastructure in version control too**, including alert rules and role assignments. Then "was this alert enabled on Tuesday" and "who could reach this resource" are also queries, not guesses.

**The credential property that comes with the same arrangement.** The pipeline's final act is committing an image digest, not talking to the cluster. Because of that, no pipeline job holds cluster credentials at all. That removes a broad standing privilege from a system that runs code from every merge request. It is the reason I would choose this model on a regulated system, even setting the auditability aside.

**What it does not answer, honestly.** It does not tell you what data was in flight. It does not tell you what feature flags were set, if flags live outside version control. And it does not tell you what a human did by hand during an incident. Those need their own records: flag changes with an audit trail, and manual changes tracked as tickets at the time. And there is a gap that catches people. A long-lived pod is running the image it started with. So checking the declared digest against what is actually running is a separate check, not an assumption.

**On the marketplace**, which deploys directly and not through a controller, the equivalent evidence is the recorded digest per deploy plus the pipeline history. That is weaker, and it is adequate for that system. Saying which one is weaker is more useful than claiming both are equal.

</details>


---

### INF-16. How do you keep a pipeline honest when everyone is under pressure to merge?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First, by making the gates hard to weaken quietly: configuration in code and reviewed, no ad-hoc skip mechanism, and a check on the checks. Second, by making the pipeline fast enough that people are not motivated to route around it. Most gate erosion is a response to friction, not to disagreement.

<details>
<summary><strong>Detailed answer</strong></summary>

**How gates actually erode.** Rarely by decision. Usually it is changes like these:

- a skip flag added for one urgent release and never removed;
- a threshold lowered to unblock a merge and never raised;
- a flaky test marked as skipped that stays skipped;
- a stage made non-blocking during an incident.

Each one is reasonable at the time. Added together, they give a pipeline that cannot fail.

**The controls I would put in place.**

- **Pipeline configuration is code, reviewed like code.** Weakening a gate is a diff that someone approves, not a setting that someone changes.
- **No general skip mechanism.** A commit-message flag that bypasses the pipeline will be used, and nobody will review its use. If an emergency path is really needed, it should require a named approver and produce a record.
- **A check on the checks.** For anything that guards an invariant, commit a known-pass and known-fail pair alongside it. Then, if someone loosens the gate, that pair fails. This is the only mechanism I know that makes a gate resistant to being quietly weakened, and it costs very little.
- **Quarantine rather than skip for flaky tests.** A skipped test disappears. A quarantined test still runs, still reports, and has an owner and a deadline. A flaky test is a defect in the test or a race in the code. If you treat it as noise, you eventually ignore a real failure.
- **Report on gate health.** How often each stage fails, and whether any stage has never failed. A stage that has never gone red is either perfect or broken, and it is worth knowing which.

**And attack the friction, because that is the actual driver.** Parallelise stages and cache properly. Run the affected subset on merge requests and the full matrix on merge. And make failures diagnosable. Half the pressure to bypass a gate comes from a failure message nobody can interpret. A pipeline that is fast, and whose failures are clear, does not get argued with nearly as much.

**Where I would hold firm.** Not shipping with the authorization boundary incomplete. Not skipping expand-and-contract. Not disabling a gate to get a release out. Those failures are silent and expensive to undo, and they are exactly what the pipeline exists for. If someone senior wants it anyway, I state the cost in writing, and the decision is theirs. But I would not make that decision myself under time pressure. Time pressure is the condition under which that decision is most likely to be wrong.

</details>

---

## 4. Quality gates and dependencies

---

### INF-17. A static analysis gate fails your merge on something you think is a false positive. What do you do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
First I assume it is right and look properly, because a fair share of the time it is seeing something I am not. If it really is wrong, I suppress it at the narrowest scope, with a written reason. And if the same rule keeps misfiring, I change the rule for everyone instead of suppressing it again and again.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I start by assuming it is right.** Findings that feel like false positives are often correct in a way that is not obvious. Examples are a broad exception clause that really does swallow something, a resource that is not closed on an error path, or a comparison that behaves differently from how it reads. The instinct that a tool is being pedantic is exactly the instinct that lets a real defect through. And checking costs ten minutes.

**When it really is wrong.** Suppress it at the narrowest possible scope: the line, not the file, and never the rule globally. Add a comment saying why. A bare suppression is a defect in itself. The next person cannot tell whether it was considered or whether someone was in a hurry. So they leave it forever.

**When the same rule misfires repeatedly.** That is not a suppression problem. It is a configuration problem. Turn the rule off for the codebase or for a directory, in the shared configuration, and record the reason. Scattering identical suppressions across thirty files is worse in every way. It is invisible as a pattern, it cannot be revisited, and it trains people to add suppressions without thinking.

**Where I would push back on the gate itself.** There are two cases. The first is a coverage threshold applied to the whole codebase instead of to new code. On a legacy codebase that threshold cannot be reached, and it produces exactly the fake tests it was meant to prevent. The second is a security rule that produces a lot of noise in a context where it does not apply. A noisy security rule is worse than none, because it teaches people to skim security findings.

**How I raise that.** With data, not annoyance. For example: here are the last thirty findings from this rule, this many were real, and here is what I propose. A specific proposal with evidence usually gets accepted. "This rule is annoying" does not, and that is reasonable.

**And what I would not do.** Suppress it to get the merge through and plan to look later. That is how a suppression becomes permanent. It is also how a whole gate stops meaning anything: one reasonable exception at a time.

</details>


---

### INF-18. A vulnerability scanner reports a critical finding in a base image with no fix available. What do you do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Before doing anything else, I establish whether it is reachable in our usage. The reason is that most base-image findings are in components the application never invokes. Then I either remove the component, change the base image, or accept the finding with an expiry and a written reason. I never suppress it silently.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: is it reachable?** A finding in a package that is present in the image is not the same as a finding in code the application executes. Take a vulnerability in a shell utility, or in a library the application never imports. It is a real finding about the image. But it is often not an exploitable path in this deployment. Not being reachable does not make the finding acceptable. But it completely changes the urgency and the response.

**Step two: can it just go away?** In order of preference:

- **Remove the component.** A slimmer base image removes whole categories of finding permanently. So does a multi-stage build where the runtime stage carries only the runtime. Most base-image findings are in things a Python service does not need, and this is the fix that keeps paying.
- **Change the base image** to a variant where the component is patched or absent.
- **Update the layer above.** Sometimes the finding is in a transitive dependency, and a newer version of a direct dependency drops it.

**Step three: if none of those work.** An explicit, time-bounded exception with a written justification. It says:

- why it is not reachable in our deployment;
- what compensating control exists;
- who owns it;
- and an expiry date, after which it fails the build again.

The expiry is the essential part. An exception without one is a permanent silent suppression. And the whole value of the gate is that it is not silent.

**Who decides.** Not me alone. A critical finding accepted into production is a security decision. It goes to whoever owns security, with the analysis attached. My job is to bring the analysis, not the verdict.

**The habit that prevents most of this.** Rebuild base images on a schedule, not only when the application changes. Take a service that has not been deployed for two months. It is running a two-month-old base image with two months of accumulated advisories. And nothing will tell you, because nothing changed. Scheduled rebuilds, plus scheduled rescans of what is actually running, turn this from a build-time formality into an operational control.

**And a related honesty point.** The scan proves what is in the image, not what is running. A long-lived pod is running the image it started with. Checking deployed digests against scan results is the step that closes that gap, and people skip it.

</details>


---

### INF-19. How do you keep a service's dependencies current without a monthly surprise?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A committed lockfile, so every environment resolves identically. Automated update proposals on a regular cadence, in small batches. And a test suite good enough that a green build on an update is actually evidence. The surprise comes from batching six months of updates into one change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The lockfile is the foundation.** Direct dependencies have permissive constraints. A committed lock resolves every transitive package to an exact version. So the pipeline, the developer's machine and the production image install identical trees. Without the lockfile, "works locally" and "works in production" are two different dependency graphs, and the difference shows up at deploy time. On the cancer platform, adopting this removed a class of deploy-time surprise that had come from drift between modules.

**Updates on a cadence, in small batches.** Automated proposals come weekly and are grouped sensibly: patch updates together, and each significant version bump on its own. Small and frequent is dramatically cheaper than large and rare. A single patch batch that breaks something is trivially bisected. A quarterly update that touches forty packages is a research project. Because it is a research project, it keeps being deferred, and that makes the next one worse.

**Separating the kinds of update.**

- **Security updates** go promptly and out of cadence.
- **Patch and minor updates** are the weekly batch. They are largely automatic, if the suite is trustworthy.
- **Major versions** get their own change, their own reading of the release notes and their own testing. These are the ones that need a person. Treating them as routine is how a breaking change ships quietly.
- **The language runtime** is its own project, planned instead of absorbed.

**What makes automation safe.** The suite has to be good enough that green means something. That means integration tests against real data stores. Most dependency breakage is at the boundary with the database driver, the broker client or the serialisation library, and a mocked test will not see it. Auto-merging updates on a suite that only exercises mocks is how you deploy a broken driver.

**And pin the tools too.** The linter, the type checker and the formatter are pinned. The reason is that an unpinned linter that updates overnight fails the build for everyone, on code nobody touched. Tool versions are part of the environment, and they deserve the same treatment as libraries.

**The honest trade-off.** This is ongoing maintenance that produces no features, and it is the first thing dropped under pressure. The argument I would make for keeping it is that it is not optional work. It is only deferrable. Deferring it turns small regular effort into an occasional large emergency. That emergency is usually triggered by a security advisory at the worst moment.

</details>


---

### INF-20. If you had to halve pipeline time, which quality tool would you drop first, and which would you never drop?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
I would drop nothing first. I would parallelise, cache and split by relevance. The reason is that almost all of the twenty to thirty minutes is one stage, and the tools take seconds. If I were really forced to remove a gate, the formatter and the duplication metrics would go before anything that can catch a defect.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the time actually is, which changes the question.** Linting, formatting and type checking take seconds. Static analysis takes a minute or two. Almost the entire pipeline duration is two things. One is the integration stage, which brings up real data stores and runs against them. The other is image build and scanning. So dropping a quality tool would buy nothing measurable. It is worth saying that, instead of accepting the premise.

**What I would do instead, in order.**

- **Parallelise independent stages.** Lint, type check and unit tests have no reason to run in sequence.
- **Fix the caching.** When dependency installation and image layers are rebuilt from scratch on every run, that is usually a large share of the time. And it is a configuration fix, not a trade-off.
- **Split by relevance.** Merge requests run the affected integration subset. The full matrix runs on merge to the default branch. That keeps coverage at the point where it matters, and it shortens the loop where people feel it.
- **Reuse containers across tests**, not one per test, with transactional isolation per test instead of teardown.
- **Move scanning off the critical path** where it can be. Scan the built image in parallel with deployment to a non-production environment, not before it.

**If I really had to remove gates**, this is the order and the reasoning.

1. **Formatting checks in the pipeline.** A pre-commit hook enforces formatting anyway, so the pipeline check is a backstop. It has the lowest information content of anything there.
2. **Duplication and complexity metrics.** They are useful as a trend. They are rarely the thing that stops a defect.
3. **Import layering rules.** Reluctantly, because architecture erodes quietly and this is what stops it. But that erosion takes months, while a defect takes a day.

**What I would not drop, and would argue about.**

- **The integration stage against real stores.** It is the slow one, and it is the one people propose cutting. But it is exactly what catches the query plans, the projection behaviour and the broker semantics that a mocked test passes while broken. A mocked broker cannot fail the way a real one does.
- **Strict type checking.** It takes seconds, and it catches a whole class at the boundary.
- **Vulnerability scanning.** It is the only thing looking at what your dependencies did, not what you did.

**And the honest framing I would offer.** A fast pipeline that cannot catch a broken migration is worse than a slow one that can. The reason is that the wait simply moves to production, where it costs more and lands on someone else. If the real problem is that a twenty-minute wait is painful, the fix is to arrange to have something else legitimately in flight. The fix is not to weaken the thing that makes merging safe.

</details>


---

### INF-21. How do you introduce strict type checking into a codebase that was never typed?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Incrementally, module by module, with the strictness gate applying only to what has been converted. If you turn it on globally, you get thousands of findings and a team that learns to ignore the tool. That is worse than not having enabled it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The approach.**

1. **Turn it on in a permissive mode across the whole codebase**, so it runs and reports without failing anything. That establishes the baseline. More usefully, it shows where the pain is concentrated, which is usually a few modules with dynamic behaviour.
2. **Make it blocking for a small set of modules first**, chosen deliberately. Choose the data models and the domain layer, because every other module depends on them. Typing them spreads useful information outward. Typing the leaves first gets you much less.
3. **Add modules to the strict set as they are converted**, in separate merge requests that do nothing else. A typing change mixed with a behavioural change is unreviewable. The diff is enormous, and the important part is three lines of it.
4. **Ratchet.** The set only grows. A new module is strict from creation. This is what stops the effort from decaying. Without a ratchet, converted modules drift back.

**What I would be careful about.**

- **Not letting the escape hatches become permanent.** Ignore comments and untyped-any annotations are legitimate during conversion. But they need a reason attached and a way to count them. Then the debt is visible and shrinking, not invisible and stable.
- **Not twisting the code to satisfy the checker.** If typing something honestly needs an overly complicated construction, the type is telling you the design is unclear. That is worth acting on. But sometimes the right answer is a narrow, documented escape, not a rewrite.
- **Third-party stubs.** A large share of the initial findings are missing type information for dependencies, not defects in your code. It is worth separating those out early, or they drown the signal.

**What it buys, so the effort is justified and not assumed.** Refactoring becomes manageable, because the checker lists the call sites affected by a shape change. The optional-value class of defect largely disappears at the boundary. And on an async codebase, it catches a coroutine that is never awaited. That is a really nasty runtime bug: it produces no error, only a `RuntimeWarning` that is easy to miss, and the coroutine does nothing.

**And the honest caveat.** It is a real investment, and its benefit is slow and spread out. So it needs to be proposed as that, not as a quick win. On a codebase nobody is changing much, it may simply not be worth it.

</details>

