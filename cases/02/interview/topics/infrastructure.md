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
A multi-stage build so no compiler or build dependency reaches the runtime image, a non-root user with an explicit numeric id, a base pinned by digest, dependencies installed from a lockfile before the source is copied so the cache layer survives a code change, and a real health check. What I would refuse: any secret, in any form — build argument, environment variable, or a file in a discarded stage — because layers are not private.

<details>
<summary><strong>Detailed answer</strong></summary>

**What the generated one usually gets wrong.**

- **One stage.** The build toolchain — compiler, headers, the package manager's cache — ends up in the runtime image, which triples the size and, more importantly, triples the vulnerability-scan surface. A multi-stage build installs dependencies in a builder and copies only the resulting environment forward.
- **Layer order that defeats the cache.** `COPY . .` before installing dependencies means every source edit reinstalls everything. Copy the lockfile, install, then copy the source. On a pipeline the client expects to run for twenty to thirty minutes, minutes of build cache are worth having.
- **Root.** The default is root, and a non-root numeric user is a one-line change that turns a container escape from trivial into work. It also matters concretely on OpenShift, which assigns an arbitrary user id at runtime — so the image has to be group-writable where it needs to write and must not assume a fixed uid.
- **An unpinned base.** `python:3.12-slim` is a moving target, so the image built today and the one built next month are different artefacts with the same recipe. Pin by digest.
- **No lockfile discipline.** Installing from a loose requirements file means the resolver picks whatever is current. [Poetry](https://python-poetry.org/docs/ "Poetry — Python dependency and packaging tool that manages, builds and publishes projects") with a committed lock — the marketplace and clinical services both do this — is what keeps runtime and packages consistent across services, and the drift it removes was previously a deploy-time surprise.
- **No health check, or one that only checks the process is alive.** A readiness probe that returns `200` while the database pool is exhausted will happily send traffic to a pod that cannot serve it. Liveness and readiness need to mean different things.
- **No `.dockerignore`.** The build context ends up carrying the git history, local environment files, test fixtures and the virtual environment — slow, and a disclosure risk.
- **`CMD` in shell form**, so the process is not process id 1 and does not receive `SIGTERM`. That breaks graceful shutdown, which matters where workers are drained rather than killed: stop consuming, finish the in-flight task, exit inside the grace period.

**What else I put in.** Version and commit metadata as labels, so a running container can be traced to a commit without guessing. `PYTHONDONTWRITEBYTECODE` and `PYTHONUNBUFFERED`, the second because unbuffered output is the difference between having logs from a crash and not. An explicit `WORKDIR` and explicit ownership on anything that needs to be writable. And the smallest base that still has a package manager I can patch with — I would rather take a slim Debian base I can update than a distroless one that is marginally smaller and much harder to fix under time pressure.

**And a scan as a blocking gate**, with base images rebuilt on a schedule rather than only when the application changes — otherwise a service not deployed for two months is running two months of unpatched advisories and nothing reports it.

**What I refuse to put in, and why.**

- **Any secret.** Not as a build argument, not as an environment variable, not as a file deleted in a later layer — the layer persists and `docker history` shows build arguments. Secrets come from the platform at runtime: Key Vault projected as files, reached by workload identity, never baked into an image and never environment variables set at build time. A secret in an image is a secret in a registry, and a registry is a distribution system.
- **Credentials for the package index**, for the same reason. Build-time secret mounts exist precisely so they do not become layers.
- **Anything that makes the image environment-specific.** One image, promoted from staging to production, configured at runtime. An image built per environment means the artefact that was tested is not the artefact that ships.
- **A debugging shell, a package manager left usable, or diagnostic tools "just in case".** They are attack surface, and the modern answer is an ephemeral debug container attached when needed rather than a permanently larger image.
- **`latest` anywhere**, in the base or in a deployment manifest. The deployment references a digest; a mutable tag cannot then be swapped underneath a running cluster, which is a supply-chain property rather than a tidiness one.
- **Test fixtures, sample data, or the test suite.** They inflate the image and occasionally contain something that should not leave the repository.

</details>


---

### INF-02. What does your Compose stack contain, and how close is it to production?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
The real components at the same pinned versions as production — database, document store, search, cache and broker — because the integration stage in the pipeline runs against that same stack. It is not a convenience; it is what makes the tests mean something.

<details>
<summary><strong>Detailed answer</strong></summary>

**What is in it and why it is the real thing.** On the health platform: the relational database, the document store, the search cluster, the cache and the broker. On the marketplace: the relational database, the document store and the cache, with the cache appearing twice in different roles. Same major versions as production, pinned, and the pipeline's integration stage brings up the same definition.

The reason is specific rather than aesthetic. The two things a mocked test passes while broken are the projection pipeline and the query plans — and a mocked broker cannot fail the way a real one does. Redelivery, acknowledgement semantics, the memory watermark blocking publishers, an unroutable publish still being confirmed: none of those exist in a fake. So the components that carry the guarantees are real everywhere.

**Where it is honestly not like production.** Single nodes rather than clusters, so replication, failover, quorum behaviour and network partitions are not exercised at all. No gateway, no managed identity, no service bus — those are stubbed or bypassed locally. Volumes are small, so nothing about plans at scale is represented. Resource limits are absent, so nothing about throttling or memory pressure appears.

I would rather state those gaps than let the local stack imply coverage it does not have. The consequence is that anything depending on cluster behaviour needs a real environment to verify, and that includes some of the most important properties in the design — which is exactly why a restore and a failover get rehearsed rather than assumed.

**What makes it usable day to day.** Healthchecks with dependency ordering, so the application waits for the database to be ready rather than crash-looping. Seed data from the same factories the tests use, so a developer's local data exercises the awkward cases. Named volumes so a restart does not lose state, and a documented one-line reset that does.

**The property I care most about.** A developer runs the same stack the pipeline runs. When something fails in the pipeline and passes locally, the difference is not the dependencies, which removes the most frustrating category of debugging there is.

</details>


---

### INF-03. How do you pin things — base images, packages, and the tool versions in CI?

**Level:** Q1 — baseline · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Everything pinned to an immutable identifier: base images by digest, packages by a committed lockfile, tools by exact version, and pipeline images by digest too. The rule is that a build with unchanged inputs produces the same result, and any moving reference breaks that.

<details>
<summary><strong>Detailed answer</strong></summary>

**Base images by digest.** A tag is a pointer that can be repointed; a digest is content. Pinning by tag means the same source can produce a different image tomorrow, which makes a failure impossible to attribute and makes "the tested image" a fiction. The cost is a scheduled job that bumps the digest and opens a merge request, which is a small automation and turns an implicit update into a reviewed one.

**Packages by lockfile**, committed, with the transitive tree resolved exactly. Constraints in the manifest, exact versions in the lock. That is what makes the pipeline, the developer machine and the production image identical.

**Pipeline tooling.** The linter, type checker, formatter and scanners pinned to exact versions, and the container images the pipeline itself runs in pinned by digest. An unpinned linter that updates overnight fails the build for everyone on code nobody touched, which is both disruptive and confusing because nothing in the repository changed. Tool versions are part of the environment.

**Deployment by digest.** The manifest references the image digest, not a tag. A mutable tag cannot then be swapped underneath a running cluster, and a rollback names a specific artifact rather than a label whose meaning may have moved.

**Where pinning has a real cost, stated.** It converts automatic security updates into deliberate ones, so you now own the update cadence. That is the right trade — I would rather choose when to take a change than have it arrive during an incident — but it only works if the cadence is actually maintained. Pinning without an update process is how a service ends up two years behind, and that is a worse outcome than not pinning.

**So the pinning and the update automation are one decision.** Scheduled proposals for base image digests and package updates, small batches, a suite good enough that green is evidence. Pinning is what makes updates safe to automate; automation is what makes pinning sustainable. Doing either alone fails, in opposite directions.

</details>


---

### INF-04. How do you make a container image reproducible, and how do you keep base-image pinning from meaning "frozen on a vulnerable base forever"?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Reproducibility comes from pinning every input — base by digest, dependencies by a committed lockfile with hashes, system packages by version — and from removing the sources of nondeterminism that remain, chiefly timestamps and file ordering. The pinning-versus-staleness tension is resolved by automating the *update*, not by loosening the pin: rebuild on a schedule, let a bot propose the new digest, and make the pipeline's vulnerability gate the thing that forces the merge.

<details>
<summary><strong>Detailed answer</strong></summary>

**What "reproducible" actually requires.** Bit-for-bit reproducibility is achievable and rarely what people need; what is needed is that the same source produces a functionally identical image, and that you can say exactly what is inside one you built six months ago.

- **Base by digest**, not by tag. `python:3.12-slim` moves; `python@sha256:...` does not.
- **Application dependencies from a committed lockfile** — Poetry here — resolved once and installed identically everywhere, ideally with hashes so a compromised or republished package fails the install rather than silently changing.
- **System packages pinned by version** where they matter, and the package index snapshot pinned if the distribution supports it. This is the most-skipped one and the most common source of "it built differently today".
- **The build context controlled by `.dockerignore`**, so stray local files cannot enter and change the result.
- **Deterministic timestamps.** `SOURCE_DATE_EPOCH`, or a build tool that normalises them. File modification times are the single largest source of digest differences between otherwise-identical builds.
- **One image promoted across environments**, never rebuilt per environment. If staging and production images are separate builds, the thing you tested is not the thing you shipped, and no amount of pinning fixes that.
- **A software bill of materials generated at build**, so "what is in this image" is a query rather than an archaeology exercise when a vulnerability is announced.

**And then the artefact has to be referenced by digest downstream.** Both designs deploy digest-pinned images only — the pipeline's final act is committing a digest to the GitOps repository, which [ArgoCD](https://argo-cd.readthedocs.io/en/stable/ "Argo CD — GitOps continuous delivery tool that syncs a Kubernetes cluster to a Git repository") reconciles. A mutable tag cannot be swapped underneath a running cluster, which makes "what is running" answerable with certainty. Reproducibility that stops at the build and hands a mutable tag to the deployer has given away the property it just paid for.

**The staleness problem, which is the real question.** A pinned digest is frozen by construction, and freezing is the point — right up until it means running a base with a known critical vulnerability because nobody wanted to touch the pin. The resolution is that **the pin is a record of what you chose, not a commitment to never choose again**, and the update has to be automated or it will not happen.

1. **Rebuild on a schedule regardless of source changes.** The marketplace design rebuilds base images weekly. This alone picks up upstream security patches without anyone deciding to.
2. **Automate the digest bump.** A dependency bot opens a merge request moving the base digest forward; it runs the full pipeline; a human reviews a small diff. The decision stays with a person, the *work* does not.
3. **Scan at build and make it blocking.** Image vulnerability scanning and dependency audit are pipeline gates in both designs. A gate that can only warn is a gate that gets ignored, so it has to be able to fail the build — and it has to have been *shown* to fail, or nobody knows whether it works.
4. **Separate "found" from "must fix now" with a policy.** Block on critical and high with a fix available; ticket the rest with a deadline. Blocking on every finding trains everyone to bypass the gate, which is worse than a looser policy honestly applied.
5. **Have an expedited path.** When a serious vulnerability lands, the fix is a digest bump and a redeploy, and that should be the same pipeline everyone uses daily rather than a special procedure. The path you use every day is the one that works under pressure.
6. **Keep the runtime image small enough that the question is tractable.** Fewer packages means fewer findings; a multi-stage build that leaves the compiler behind removes a large share of them permanently.
7. **Track base age as a metric.** "Oldest base image in production, in days" on a dashboard makes drift visible before a scanner makes it urgent.

**The trade-off stated plainly.** Weekly rebuilds mean the running image changes without a code change, which is a small ongoing risk of an upstream regression — and that is exactly what staging plus a smoke test plus a canary is for. The alternative risk, an unpatched base, is worse and grows monotonically. I would take the frequent small change over the rare large one, and I would say so in those terms rather than treating it as obviously correct.

</details>


---

### INF-05. A container works locally and fails in the cluster. Where do you look?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
In order: configuration and secrets, identity and permissions, the filesystem and user identifier, network policy, and resource limits. Almost every instance is one of those five, and they are distinguishable in a couple of minutes each.

<details>
<summary><strong>Detailed answer</strong></summary>

**Configuration.** A value present in a local environment file and absent from the cluster's configuration. The failure is usually at startup and the log says so, if the application validates its configuration on boot — which it should, loudly, rather than failing later with something unrelated. Failing fast on a missing configuration value is one of the cheapest robustness measures there is.

**Identity and permissions.** Locally the application uses a connection string; in the cluster it authenticates as a federated workload identity. If the service account is not annotated correctly, or the role assignment is missing, it cannot reach the database or the storage account. The symptom is an authorization error from the cloud provider that reads like a network problem. This is the most common cause in my experience once configuration is ruled out.

**Filesystem and user.** Locally the container often runs as root. In the cluster it does not, and on a stricter platform it runs as an arbitrary assigned identifier. Anything writing to a path owned by a specific user, or expecting a writable filesystem where the root filesystem is read-only, fails here. Temporary directories need to be explicit mounts.

**Network.** Network policy denying egress, a private endpoint the pod cannot resolve, a name that resolves differently inside the cluster. Testing from a debug container in the same namespace with the same service account separates "the application is wrong" from "the network is wrong" in about a minute.

**Resources.** Terminated for memory, or throttled so severely that startup exceeds the probe threshold and it restart-loops. Locally there are no limits, so the first time the process meets one is in the cluster.

**How I actually work through it.** Read the previous container's termination reason first, because it partitions the space immediately. Then read the whole startup log rather than the last line — the real error is usually several lines above the symptom. Then run the same image in the cluster with a shell as the entrypoint, so I can inspect the environment as the process sees it. What the pod's environment actually contains is usually where the answer is, and it is different from what the manifest appears to say more often than you would expect.

</details>


---

### INF-06. How do you debug inside a running container in production, and what would you not do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By exhausting telemetry first, then attaching a debug container to inspect rather than to change. What I would not do is edit anything inside a running container, install tools into it, or restart it before capturing what I need — a restart destroys the evidence.

<details>
<summary><strong>Detailed answer</strong></summary>

**Almost always, telemetry answers it.** Traces show where the time goes, structured logs filtered by the correlation identifier show the path a specific request took, and metrics show whether it is one pod or all of them. If those cannot answer the question, that is itself a finding — it means the instrumentation has a gap, and the gap is worth fixing more than this instance is worth debugging by hand.

**When I do need to be inside.** An ephemeral debug container attached to the pod's namespaces, carrying the tools, so the application image stays minimal — and so I am not installing anything into a running production container, which changes the thing being investigated and leaves it in a state nobody can reproduce.

**What I look at.** The environment as the process actually sees it, network reachability to its dependencies from inside the pod, whether the filesystem is what the manifest claims, and process-level state — thread stacks if the interpreter supports dumping them, which is the fastest way to find a whole worker pool parked on the same lock.

**Before anything else: capture.** Logs from the current and previous instance, the pod description including the termination reason, a heap or thread dump if relevant, and the current metrics. A restart is often the correct remediation and it destroys everything, so the order is capture, then remediate. The number of times an incident has been resolved by a restart and then recurred a week later with no evidence from the first occurrence is why I hold that order.

**What I would not do.**

- **Edit code or configuration inside a running container.** The change vanishes on restart, it is invisible to everyone, and the running system no longer matches what is declared.
- **Restart before capturing**, unless the outage cost genuinely outweighs the evidence.
- **Exec into a container to read data**, on the clinical system. Access to patient data goes through the audited path, not through a shell, and going around it is a control failure regardless of intent.
- **Leave a debug container attached** or a temporarily relaxed policy in place. Both get forgotten.
- **Attach a debugger that pauses the process** on something serving traffic.

**And afterwards.** Whatever I had to go inside to learn becomes a metric or a log field, so the next occurrence is answerable from telemetry. Debugging by hand in production is a signal about the observability, not a routine to get better at.

</details>

---

## 2. Kubernetes and runtime

---

### INF-07. What is different about OpenShift compared with plain Kubernetes, and what would you have to learn?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform

**Brief answer**
It is [Kubernetes](https://kubernetes.io/ "Kubernetes — Automates deployment, scaling and management of containerized applications") with opinionated defaults, a stricter security posture and its own resources layered on top. The differences that actually bite are the security context constraints — containers do not run as root and are assigned an arbitrary user identifier — and its own build and route objects.

<details>
<summary><strong>Detailed answer</strong></summary>

**What I have worked with.** Deployments to a managed OpenShift cluster, delivered by a GitOps controller from a manifest repository, with migrations as a pre-sync hook and a smoke test as a post-sync hook. So the delivery path and the workload shape are familiar; the platform's own build tooling I have used less.

**The differences that matter in practice.**

- **Security context constraints.** The default policy refuses root and assigns an arbitrary, high-numbered user identifier at runtime. An image that assumes a fixed user, or writes to a directory owned by a specific one, fails. The fix is to build images with group-writable directories and no assumption about the user identifier — which is good practice generally and is simply enforced here. This is the single most common reason an image that runs elsewhere does not run on OpenShift.
- **Routes rather than ingress**, with their own object and their own approach to certificates and termination. Ingress works too, and mixing both is a way to get confused about which is authoritative.
- **Projects rather than namespaces**, which is a namespace with additional defaults and quota attached.
- **Its own build and image stream objects**, which can watch a registry tag and trigger a rollout. Useful, and a second mechanism to reason about when a GitOps controller is also managing the desired state — two systems that both think they own the deployed image is a genuine source of confusion.
- **An integrated registry and an operator-heavy ecosystem**, so a lot of platform capability arrives as operators rather than as raw manifests.

**What I would want to learn deliberately rather than assume.** The exact constraint policy in use and what it permits, because that determines what images can run at all. How the platform's own networking layer is configured, since network policy behaviour differs. The upgrade cadence, which is more opinionated than on a plain cluster and affects planning. And whether the platform's build tooling or an external pipeline is authoritative, because that decides where the source of truth for a deployed version lives.

**What transfers unchanged.** Everything about workload design — probes, resource requests and limits, graceful shutdown, autoscaling signals, pod disruption budgets — and the entire delivery discipline: expand-and-contract migrations, digest-pinned images, declarative desired state with rollback as a revert. Those are the parts that are hard, and none of them are platform-specific.

</details>


---

### INF-08. Explain requests and limits, and what goes wrong when they are set badly.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Requests decide scheduling and guarantee; limits cap consumption. The two failure modes are opposite and both common: processor limits set too low cause throttling that looks like slow code, and memory limits set too low cause the process to be killed abruptly with no stack trace.

<details>
<summary><strong>Detailed answer</strong></summary>

**The mechanics.** The request is what the scheduler reserves and what the pod is guaranteed. The limit is the ceiling. For processor time, exceeding the limit means throttling — the container is descheduled for the rest of its accounting period. For memory there is no throttling; exceeding the limit means the process is terminated.

**Processor limits set too low.** The symptom is latency spikes that correlate with nothing visible: the application is not busy, the database is fine, and periodically requests take much longer. What is happening is that the container burned its quota early in the accounting window and is being descheduled. It is particularly cruel with garbage collection and with startup, where a brief legitimate burst gets throttled and the startup probe then fails, producing a restart loop that looks like a crash. The tell is the throttling metric, which is not on most default dashboards and should be.

**Memory limits set too low.** The container is killed. No stack trace, no application log line, just a restart with a status the orchestrator records and nobody reads. It shows up as intermittent restarts under load and is frequently misdiagnosed as a crash bug. The subtlety with a runtime that manages its own heap is that memory use grows until collection, so a limit set to observed steady-state use will be exceeded routinely.

**Requests set too high** wastes capacity — nodes fill up with reservations nothing uses, the cluster autoscaler adds nodes, and the bill grows for idle guarantees.

**Requests set too low** means the pod is scheduled onto a node with nothing to spare and is a first candidate for eviction under pressure. Its behaviour then depends on what else lands next to it, which makes performance irreproducible.

**How I set them.** From observed usage under realistic load, not from a guess: request near the steady-state median, limit with real headroom above the observed peak. For memory I prefer request and limit equal on anything important, so the pod gets the strongest scheduling guarantee and its behaviour does not depend on its neighbours. For processor I often set a generous limit or none on latency-sensitive services, because throttling a request-serving process to save capacity it was not going to use anyway is a bad trade.

**And I watch the throttling and termination counters as first-class signals**, because both failure modes are invisible in application metrics — one looks like slow code, the other looks like a crash.

</details>


---

### INF-09. A pod is being killed and restarted repeatedly. Walk me through the diagnosis.

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Read the termination reason first, because it separates the whole problem space in one step: killed for memory, failed a probe, exited non-zero, or evicted. Each has a different cause and a different fix, and guessing between them wastes the most time.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: the last state and its reason.** The pod's status carries the previous container's exit reason and code. Four broad outcomes:

- **Killed for exceeding memory.** No application log will explain it — the process was terminated, not thrown. Look at whether the limit is below the actual peak, whether there is a leak (memory climbing monotonically across restarts rather than sawtoothing), or whether one request shape allocates hugely, which is the usual cause when restarts correlate with a specific endpoint or a large import.
- **A probe failing.** Liveness failing restarts the container; readiness failing only removes it from service. If liveness is failing under load rather than at startup, the probe is measuring load rather than liveness and it is causing the outage it claims to detect. If it fails at startup, the container needs longer than the probe allows, and the fix is a startup probe rather than a more generous liveness threshold.
- **A non-zero exit.** An application crash or a failure to start — a missing configuration value, an unreachable dependency, a failed migration. The logs from the previous container instance are where the answer is, and they need to be fetched explicitly since the current instance's logs will not have it.
- **Evicted.** Node pressure — disk, memory — rather than anything about this pod. Look at the node, not the workload.

**Step two: the pattern.** Immediately on start every time is configuration or a dependency. After some minutes is memory or a leak. Under load is limits or probes. All pods at once is a deploy or a shared dependency; one pod is a node.

**Step three: reproduce with the safety off.** Run the image with generous limits and probes relaxed, and see what it does. If it survives, the problem is the limits or the probes rather than the code, which is a much better place to be.

**Two specifics worth naming.** A worker being restarted mid-task is not just an availability problem — it is a durability question, and the answer must be that redelivery covers it. If a restart loses work, the acknowledgement mode is wrong. And a liveness probe hitting an endpoint that touches the database will fail during a database blip and restart every pod simultaneously, converting a brief dependency problem into a full outage. Liveness should test the process, readiness should test the dependencies.

</details>


---

### INF-10. How do you make a worker shut down safely mid-task?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Stop consuming first, finish the in-flight task, then exit — bounded by the termination grace period, with task chunk sizes small enough to finish comfortably inside it. And behind all of that, at-least-once delivery so an ungraceful kill causes redelivery rather than loss.

<details>
<summary><strong>Detailed answer</strong></summary>

**The sequence.** On termination the orchestrator runs a pre-stop hook and sends a termination signal, then waits for the grace period before killing the process. So:

1. **Pre-stop: stop accepting new work.** Cancel the broker consumer so no further messages are delivered to this worker. Anything already prefetched is either processed or returned unacknowledged.
2. **Finish the in-flight task.** The signal handler sets a flag; the task loop completes the current item and does not start another.
3. **Acknowledge, release resources, exit cleanly.**

**The numbers have to agree, and this is where it usually goes wrong.** The grace period must exceed the longest realistic task duration, or the process is killed mid-task anyway and the graceful shutdown is decorative. Two ways to make that true: raise the grace period, or make tasks short. I strongly prefer the second — chunking a large import into pieces sized to finish well inside the window means the worker is never far from a clean stopping point, and it makes the whole system more tolerant of every kind of interruption, not just deploys.

**Why redelivery still has to work.** Graceful shutdown is best-effort. A node failure, an out-of-memory kill or an exceeded grace period all skip it. So the durable guarantee is late acknowledgement plus idempotent handling: the message is only acknowledged after the work completes, so an ungraceful death causes redelivery, and the handler tolerates running twice because the guarantee lives in a database constraint. Graceful shutdown reduces how often that path is exercised; it is not what makes the system correct.

**For long-running work specifically.** Checkpoint progress so a resumed task does not redo everything — an import that records which chunk it completed can restart at the boundary rather than at the beginning. This matters more as tasks get longer, and it is the difference between a redelivery costing seconds and costing an hour.

**For the web tier**, the same shape with different mechanics: readiness fails first so traffic stops arriving, a brief pause covers the propagation delay through the load balancer, then in-flight requests complete. Skipping the pause is the classic source of connection errors during an otherwise clean rollout — the pod stops before the routing layer has noticed.

</details>

---

## 3. Terraform, CI/CD and GitOps

---

### INF-11. How do you structure Terraform so more than one person can work on it?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By splitting state along blast-radius lines rather than by resource type, using one module set with a variables file per environment, and locking state so two applies cannot collide. The structure question is really a question about what one careless apply can destroy.

<details>
<summary><strong>Detailed answer</strong></summary>

**State splitting is the main decision.** One monolithic state means every apply plans the whole estate, plans take a long time, everyone contends for the lock, and a mistake can affect anything. So state is split, and the seam I use is blast radius and change frequency together: the network and identity layer changes rarely and is catastrophic to get wrong; the data layer changes rarely and holds the data; the application layer changes constantly and is recoverable. Three states, and the application layer's identity does not have permission to touch the other two.

**One module set, variables per environment.** Environments differ in instance sizes and counts, not in topology. That is what makes a staging smoke test meaningful — staging is the same architecture at smaller sizes rather than a different architecture that happens to share a name. Copying the configuration per environment guarantees divergence within a quarter.

**The operational rules.**

- **State in a versioned, locked backend**, so two concurrent applies cannot corrupt it and a damaged state can be recovered from a previous version.
- **Applies run only from continuous integration on the default branch**, authenticated by workload identity federation. Nobody applies from a laptop, so state and reality cannot diverge through a helpful local fix.
- **Plan on every merge request, posted for review.** The plan is the review artifact. Reviewing configuration without the plan means reviewing intent rather than effect, and the two differ most on the changes that matter — a plan showing a resource being destroyed and recreated is the finding, and it is invisible in the source diff.
- **Production has a manual gate between plan and apply**, so a human confirms the plan they read is the plan being applied.

**What is in it that people leave out.** Alert rules, and role assignments. Alert rules in code means a hand-silenced alert is a reviewable diff rather than something discovered six months later when the thing it watched failed quietly. Role assignments in code means a widened permission is a diff rather than a click nobody sees.

**The concentration of privilege, stated honestly.** The deploy identity is the largest single concentration of privilege in either design. The right shape is to split it — a plan-only identity for merge requests, an apply identity gated on protected branches, and the network and data modules under their own identity. That is a decision worth taking before the first production apply rather than after an incident, and it is the kind of change I would flag for review rather than make on my own judgement.

</details>


---

### INF-12. What do you do about a resource someone created by hand in the portal?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
It shows up in the plan and it fails the pipeline. Then it gets imported into state and codified, or removed. What I would not do is quietly reconcile it, because the moment the code stops describing reality, infrastructure as code becomes decorative.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why drift has to be a failure rather than a warning.** A configuration that describes most of the infrastructure is worse than one that describes none, because people trust it. The plan is the mechanism that keeps the description honest, and if drift is tolerated then the plan becomes noise nobody reads, which is exactly when the destructive change slips through unnoticed.

**What actually happens.**

1. **Detected.** A scheduled plan on the default branch, not only on merge requests, so drift from something outside the pipeline surfaces within a day rather than at the next deploy.
2. **Understood before touched.** Why does it exist? Usually the answer is an incident — someone scaled something or opened a firewall rule at two in the morning, correctly. That is a legitimate act and the failure is not having codified it afterwards.
3. **Import or remove.** If it should exist, it is imported into state and written into the configuration, so the next plan is clean. If it should not, it is removed through the configuration.
4. **Never resolved by applying blindly.** A plan proposing to destroy a hand-created resource might be right, or it might be about to delete something an incident depends on. That decision needs a person.

**The emergency case, handled explicitly.** Break-glass changes will happen and pretending otherwise produces a policy people work around. The rule is that a manual change is permitted during an incident and must be codified within an agreed window, tracked as a ticket created at the time. That keeps the discipline without making the incident harder.

**Two related habits.** Everything created by the pipeline is tagged with its origin, so an untagged resource is immediately identifiable as unmanaged. And nobody has standing write access to the production subscription — a human needing it goes through a time-bound elevation that writes an audit record. That is the control that actually reduces drift, because it makes the manual path visible rather than convenient.

**The uncomfortable case.** A resource created by another team, in a subscription we share. That is a conversation rather than a technical fix, and the resolution is usually a boundary — separate resource groups or subscriptions with separate ownership — rather than an agreement to be careful.

</details>


---

### INF-13. How do you roll back — application code, database schema, and infrastructure?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Application code by redeploying the previous digest or reverting the manifest commit. Schema, deliberately, not at all — expand-and-contract means the old code runs against the new schema, so there is nothing to undo. Infrastructure by reverting the configuration and applying, with the caveat that some resources do not roll back cleanly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Application code.** The previous image by digest, not by tag, because a mutable tag can have been repointed and then "the previous version" is not what you think. On the GitOps side that is a revert of the manifest commit; on the direct-deploy side a redeploy of the recorded digest. Either way it should be one action, take a couple of minutes, and require no decisions.

**The schema is the interesting one, and the answer is that it is not rolled back.** Migrations are expand-only: a release adds nullable columns, new tables and concurrently-built indexes. Removals land at least one release later, once nothing reads the old shape. The consequence is that the previous image runs correctly against the current schema throughout, so rolling back the code needs no schema change at all.

That is a deliberate substitution of one hard problem for a discipline. A down-migration on a table with hundreds of millions of rows is not something anyone will run under pressure — it is slow, it is untested, and if the forward migration destroyed data the down migration cannot recreate it. So the design does not depend on one existing. A migration that cannot be written in expand-and-contract form gets split across two releases; that is a rule rather than a case-by-case judgement.

**Infrastructure.** Revert the configuration and apply. It works for most changes and there are real exceptions worth knowing in advance: a resource whose change forces replacement will be destroyed and recreated on the way back, which for anything stateful is not a rollback; some settings are one-way; and a reverted change may not restore a dependent resource's state. So for infrastructure the more useful discipline is reading the plan properly before the first apply, since the reverse plan is not guaranteed to be symmetric.

**What makes a rollback actually work in practice**, beyond mechanism: it has to be rehearsed. A rollback path nobody has executed is an assumption, and the moment you need it is the worst moment to find out that the previous image no longer starts because a configuration key was removed. So the rollback is exercised as part of a release rather than trusted.

**And knowing when not to.** If the bad release has already written data in a new shape, rolling back the code means the old version meets data it does not understand. That is the case where rolling forward with a fix is correct, and recognising it quickly is the actual skill — which is why the question I ask before any risky release is what the bad version will have written by the time we notice.

</details>


---

### INF-14. How do you know a pipeline gate can actually fail?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By having seen it go red for a real reason. That is the only acceptable evidence, and the way to get it deliberately is a known-pass and known-fail pair: introduce a change the gate should catch, confirm the build fails, restore. Two inputs, a few minutes.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why the question needs asking at all.** A gate that cannot fail is indistinguishable from a gate that works, from the outside — both are green forever. And a green pipeline is the single most trusted signal in most teams. So a broken gate does not merely fail to protect; it actively provides false confidence, and it will keep doing so until an incident.

**The specific ways gates turn out to be decorative.**

- **Configured to report rather than enforce.** A quality or scanning stage that prints findings and exits zero. Very common, because report mode is the sensible way to introduce a tool and nobody comes back to flip it.
- **Exit status lost through a pipe.** A command piped through a log filter reports the filter's status, not the command's. The fix is capturing the status on the command's own line and exiting with it, and this one is easy to introduce accidentally while making output readable.
- **A step in a shell that exits before it runs.** Under strict error handling, a search that correctly finds nothing returns non-zero and kills the step — which is the passing branch of an assert-absent check, dying before it prints anything.
- **Invoked differently from how it runs locally.** Some analysers report different findings for one file alone than for a directory sweep, so verifying a guard through a convenient local invocation leaves it unverified in the pipeline. The invocation has to be copied from the pipeline definition rather than approximated.
- **A test that passes for a reason unrelated to its name**, because the fixture satisfies the assertion before the logic under test is reached.

**What I do about it.**

- **Verify each gate once, deliberately, with a real known-fail input.** Not a syntax error — a mutation that leaves the file parsable, because a syntax error makes everything fail at once, which reads as overwhelming evidence and is worthless. It is a could-not-run, not a catch.
- **Three outcomes, never two: pass, fail, and could-not-run.** A check with no explicit could-not-run branch folds a tool error or a mutation that did not take into whichever branch was written first, and that is always the one confirming what you expected.
- **Commit a known-pass and known-fail pair for anything guarding an invariant**, so weakening the gate later fails that pair. This is the only mechanism I know that makes a gate resistant to being quietly loosened.
- **Report on gate history.** A stage that has never gone red is either perfect or broken. Knowing which is worth a look.

**Where I apply the same scepticism.** Alerts and monitoring, identically. An alert rule with a typo in a label matches nothing and reports nothing, forever, and the only evidence it works is having seen it fire.

</details>


---

### INF-15. How do you answer "what exactly was running in production at two o'clock last Tuesday"?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
From version control, if the desired state is a commit and images are referenced by digest. Then the answer is a revision at a timestamp, not an archaeology exercise across deploy logs — and that property is most of why the regulated system uses a pull-based delivery model.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why it is a hard question in most systems.** A deploy job ran, and what it produced depends on what its inputs resolved to at the time — a mutable tag, a dependency range, a configuration value read from somewhere else. The job log says it succeeded. Reconstructing the actual artifact months later means correlating a build number, a registry tag that may have been repointed, and a configuration store with no history.

**What makes it answerable.**

- **Images referenced by digest, not by tag.** A tag is a pointer that can be repointed; a digest is the content. This is the single most important part — without it, "we deployed version 2.3.1" names a label rather than an artifact.
- **Desired state as a commit.** The manifest repository holds what should be running, so the state at any timestamp is a revision. A rollback is a revert of that revision rather than a re-run of a job whose inputs may have changed since.
- **A controller reconciling that state continuously**, so drift between what is declared and what is running is detected rather than inferred. Without reconciliation, a hand-edited resource survives silently until the next deploy overwrites it, and nobody can say which state was in effect during an incident.
- **Configuration in the same repository as the manifests**, or at least versioned, so a change to a value is as traceable as a change to code.
- **Infrastructure in version control too**, including alert rules and role assignments, so "was this alert enabled on Tuesday" and "who could reach this resource" are also queries rather than guesses.

**The credential property that comes with the same arrangement.** Because the pipeline's final act is committing an image digest rather than talking to the cluster, no pipeline job holds cluster credentials at all. That removes a broad standing privilege from a system that runs code from every merge request, and it is the reason I would choose this model on a regulated system even setting the auditability aside.

**What it does not answer, honestly.** What data was in flight, what feature flags were set if flags live outside version control, and what a human did by hand during an incident. Those need their own records — flag changes with an audit trail, and manual changes tracked as tickets at the time. And the gap that catches people: a long-lived pod is running the image it started with, so correlating the declared digest against what is actually running is a separate check rather than an assumption.

**On the marketplace**, which deploys directly rather than through a controller, the equivalent evidence is the recorded digest per deploy plus the pipeline history. Weaker, and adequate for that system — and stating which one is weaker is more useful than claiming both are equal.

</details>


---

### INF-16. How do you keep a pipeline honest when everyone is under pressure to merge?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
By making the gates hard to weaken quietly — configuration in code and reviewed, no ad-hoc skip mechanism, and a check on the checks — and by making the pipeline fast enough that people are not motivated to route around it. Most gate erosion is a response to friction rather than to disagreement.

<details>
<summary><strong>Detailed answer</strong></summary>

**How gates actually erode.** Rarely by decision. It is a skip flag added for one urgent release and never removed; a threshold lowered to unblock a merge and never raised; a flaky test marked as skipped that stays skipped; a stage made non-blocking during an incident. Each is reasonable at the time and the aggregate is a pipeline that cannot fail.

**The controls I would put in place.**

- **Pipeline configuration is code, reviewed like code.** Weakening a gate is a diff someone approves, not a setting someone changes.
- **No general skip mechanism.** A commit-message flag that bypasses the pipeline will be used, and its use will not be reviewed. If an emergency path is genuinely needed, it should require a named approver and produce a record.
- **A check on the checks.** For anything that guards an invariant, a known-pass and known-fail pair committed alongside it, so if someone loosens the gate, that pair fails. This is the only mechanism I know that makes a gate resistant to being quietly weakened, and it costs very little.
- **Quarantine rather than skip for flaky tests.** A skipped test disappears; a quarantined one still runs, still reports, and has an owner and a deadline. A flaky test is a defect in the test or a race in the code, and treating it as noise means eventually ignoring a real failure.
- **Report on gate health.** How often each stage fails, and whether any has never failed. A stage that has never gone red is either perfect or broken, and it is worth knowing which.

**And attack the friction, because that is the actual driver.** Parallelise stages, cache properly, run the affected subset on merge requests and the full matrix on merge, and make failures diagnosable — half the pressure to bypass a gate comes from a failure message nobody can interpret. A pipeline that is fast and whose failures are clear does not get argued with nearly as much.

**Where I would hold firm.** Not shipping with the authorization boundary incomplete, not skipping expand-and-contract, not disabling a gate to get a release out. Those failures are silent and expensive to undo, and they are exactly what the pipeline exists for. If someone senior wants it anyway, I state the cost in writing and the decision is theirs — but I would not make that decision myself under time pressure, because time pressure is the condition under which it is most likely to be wrong.

</details>

---

## 4. Quality gates and dependencies

---

### INF-17. A static analysis gate fails your merge on something you think is a false positive. What do you do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Assume it is right first and look properly, because a decent fraction of the time it is seeing something I am not. If it genuinely is wrong, suppress it at the narrowest scope with a written reason, and if the same rule keeps misfiring, change the rule for everyone rather than suppressing repeatedly.

<details>
<summary><strong>Detailed answer</strong></summary>

**Why I start by assuming it is right.** Findings that feel like false positives are often correct in a way that is not obvious — a broad exception clause that does swallow something, a resource that is not closed on an error path, a comparison that behaves differently than it reads. The instinct that a tool is being pedantic is exactly the instinct that lets a real defect through, and it costs ten minutes to check.

**When it really is wrong.** Suppress at the narrowest possible scope — the line, not the file, and never the rule globally — with a comment saying why. A bare suppression is a defect in itself: the next person cannot tell whether it was considered or whether someone was in a hurry, so they leave it forever.

**When the same rule misfires repeatedly.** That is not a suppression problem, it is a configuration problem. Turn the rule off for the codebase or for a directory, in the shared configuration, with the reason recorded. Scattering identical suppressions across thirty files is worse in every way: it is invisible as a pattern, it cannot be revisited, and it trains people to add suppressions reflexively.

**Where I would push back on the gate itself.** Two cases. A coverage threshold applied to the whole codebase rather than to new code — that is unachievable on a legacy codebase and it produces exactly the fake tests it was meant to prevent. And a security rule producing a high volume of noise in a context where it does not apply; a noisy security rule is worse than none, because it teaches people to skim security findings.

**How I raise that.** With data rather than annoyance: here are the last thirty findings from this rule, this many were real, here is what I propose. A specific proposal with evidence usually gets accepted. "This rule is annoying" does not, and reasonably so.

**And what I would not do.** Suppress it to get the merge through and plan to look later. That is how a suppression becomes permanent, and it is the mechanism by which a whole gate stops meaning anything — one reasonable exception at a time.

</details>


---

### INF-18. A vulnerability scanner reports a critical finding in a base image with no fix available. What do you do?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
Establish whether it is reachable in our usage before doing anything else, because most base-image findings are in components the application never invokes. Then either remove the component, change the base image, or accept it with an expiry and a written reason — never suppress it silently.

<details>
<summary><strong>Detailed answer</strong></summary>

**Step one: is it reachable?** A finding in a package present in the image is not the same as a finding in code the application executes. A vulnerability in a shell utility or a library the application never imports is a real finding about the image and often not an exploitable path in this deployment. That does not make it acceptable, but it entirely changes the urgency and the response.

**Step two: can it just go away?** In order of preference:

- **Remove the component.** A slimmer base image, or a multi-stage build where the runtime stage carries only the runtime, removes whole categories of finding permanently. Most base-image findings are in things a Python service does not need, and this is the fix that keeps paying.
- **Change the base image** to a variant where the component is patched or absent.
- **Update the layer above.** Sometimes the finding is in a transitive dependency that a newer version of a direct dependency drops.

**Step three: if none of those work.** An explicit, time-bounded exception with a written justification: why it is not reachable in our deployment, what compensating control exists, who owns it, and an expiry date after which it fails the build again. The expiry is the essential part — an exception without one is a permanent silent suppression, and the whole value of the gate is that it is not silent.

**Who decides.** Not me alone. A critical finding accepted into production is a security decision, and it goes to whoever owns security with the analysis attached. My job is to bring the analysis, not the verdict.

**The habit that prevents most of this.** Rebuild base images on a schedule rather than only when the application changes. A service not deployed for two months is running a two-month-old base image with two months of accumulated advisories, and nothing will tell you because nothing changed. Scheduled rebuilds plus scheduled rescans of what is actually running is what turns this from a build-time formality into an operational control.

**And a related honesty point.** The scan proves what is in the image, not what is running. A long-lived pod is running the image it started with. Correlating deployed digests against scan results is the step that closes that gap, and it is one people skip.

</details>


---

### INF-19. How do you keep a service's dependencies current without a monthly surprise?

**Level:** Q2 — deep dive · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
A committed lockfile so every environment resolves identically, automated update proposals on a regular cadence in small batches, and a test suite good enough that a green build on an update is actually evidence. The surprise comes from batching six months of updates into one change.

<details>
<summary><strong>Detailed answer</strong></summary>

**The lockfile is the foundation.** Direct dependencies with permissive constraints and a committed lock resolving every transitive package to an exact version, so the pipeline, the developer's machine and the production image install identical trees. Without it, "works locally" and "works in production" are two different dependency graphs and the difference surfaces at deploy time. Adopting this removed a class of deploy-time surprise on the health platform that had come from drift between modules.

**Updates on a cadence, in small batches.** Automated proposals weekly, grouped sensibly — patch updates together, each significant version bump on its own. Small and frequent is dramatically cheaper than large and rare: a single patch batch that breaks something is trivially bisected, whereas a quarterly update touching forty packages is a research project, and the fact that it is a research project is why it keeps being deferred, which makes the next one worse.

**Separating the kinds of update.**

- **Security updates** go promptly and out of cadence.
- **Patch and minor updates** are the weekly batch, largely automatic if the suite is trustworthy.
- **Major versions** get their own change, their own reading of the release notes and their own testing. These are the ones that need a person, and treating them as routine is how a breaking change ships quietly.
- **The language runtime** is its own project, planned rather than absorbed.

**What makes automation safe.** The suite has to be good enough that green means something — which means integration tests against real data stores, because most dependency breakage is at the boundary with the database driver, the broker client or the serialisation library, and a mocked test will not see it. Auto-merging updates on a suite that only exercises mocks is how you deploy a broken driver.

**And pin the tools too.** The linter, the type checker and the formatter are pinned, because an unpinned linter updating overnight fails the build for everyone on code nobody touched. Tool versions are part of the environment and deserve the same treatment as libraries.

**The honest trade-off.** This is ongoing maintenance that produces no features, and it is the first thing dropped under pressure. The argument I would make for keeping it is that it is not optional work, it is only deferrable — and deferring it converts small regular effort into an occasional large emergency, usually triggered by a security advisory at the worst moment.

</details>


---

### INF-20. If you had to halve pipeline time, which quality tool would you drop first, and which would you never drop?

**Level:** Q3 — architectural · **Project:** cancer-support-platform, retail-software-marketplace

**Brief answer**
I would drop nothing first — I would parallelise, cache and split by relevance, because almost all of the twenty to thirty minutes is one stage and the tools are seconds. If genuinely forced to remove a gate, the formatter and the duplication metrics go before anything that can catch a defect.

<details>
<summary><strong>Detailed answer</strong></summary>

**Where the time actually is, which reframes the question.** Linting, formatting and type checking are seconds. Static analysis is a minute or two. Almost the entire pipeline duration is the integration stage bringing up real data stores and running against them, plus image build and scanning. So "drop a quality tool" would buy nothing measurable, and it is worth saying that rather than accepting the premise.

**What I would do instead, in order.**

- **Parallelise independent stages.** Lint, type check and unit tests have no reason to run in sequence.
- **Fix the caching.** Dependency installation and image layers rebuilt from scratch every run is usually a large share of the time and it is a configuration fix, not a trade-off.
- **Split by relevance.** Merge requests run the affected integration subset; the full matrix runs on merge to the default branch. That preserves coverage at the point it matters while shortening the loop where it is felt.
- **Reuse containers across tests** rather than per test, with transactional isolation per test instead of teardown.
- **Move scanning off the critical path** where it can be: scan the built image in parallel with deployment to a non-production environment rather than before it.

**If I genuinely had to remove gates**, the order and the reasoning.

1. **Formatting checks in the pipeline.** Enforced by a pre-commit hook anyway, so the pipeline check is a backstop. Lowest information content of anything there.
2. **Duplication and complexity metrics.** Useful as a trend, rarely the thing that stops a defect.
3. **Import layering rules** — reluctantly, because architecture erodes quietly and this is what stops it, but the erosion takes months while a defect takes a day.

**What I would not drop, and would argue about.**

- **The integration stage against real stores.** It is the slow one and it is the one people propose cutting, and it is precisely what catches the query plans, the projection behaviour and the broker semantics that a mocked test passes while broken. A mocked broker cannot fail the way a real one does.
- **Strict type checking.** Seconds, and it catches a whole class at the boundary.
- **Vulnerability scanning.** It is the only thing looking at what your dependencies did rather than what you did.

**And the honest framing I would offer.** A fast pipeline that cannot catch a broken migration is worse than a slow one that can, because the wait simply moves to production where it costs more and lands on someone else. If the real problem is that a twenty-minute wait is painful, the fix is arranging to have something else legitimately in flight, not weakening the thing that makes merging safe.

</details>


---

### INF-21. How do you introduce strict type checking into a codebase that was never typed?

**Level:** Q3 — architectural · **Project:** general

**Brief answer**
Incrementally, module by module, with the strictness gate applying only to what has been converted. Turning it on globally produces thousands of findings and a team that learns to ignore the tool, which is worse than not having enabled it.

<details>
<summary><strong>Detailed answer</strong></summary>

**The approach.**

1. **Turn it on in a permissive mode across the whole codebase**, so it runs and reports without failing anything. That establishes the baseline and, more usefully, shows where the pain is concentrated — usually a few modules with dynamic behaviour.
2. **Make it blocking for a small set of modules first**, chosen deliberately: the data models and the domain layer, because they are the ones every other module depends on, and typing them propagates useful information outward. Typing the leaves first gets you much less.
3. **Add modules to the strict set as they are converted**, in separate merge requests that do nothing else. A typing change mixed with a behavioural change is unreviewable, because the diff is enormous and the important part is three lines of it.
4. **Ratchet.** The set only grows. A new module is strict from creation. This is what stops the effort decaying — without a ratchet, converted modules drift back.

**What I would be careful about.**

- **Not letting the escape hatches become permanent.** Ignore comments and untyped-any annotations are legitimate during conversion and need a reason attached and a way to count them, so the debt is visible and shrinking rather than invisible and stable.
- **Not contorting the code to satisfy the checker.** If typing something honestly requires a baroque construction, the type is telling you the design is unclear — that is worth acting on, but sometimes the right answer is a narrow, documented escape rather than a rewrite.
- **Third-party stubs.** A large share of the initial findings are missing type information for dependencies rather than defects in your code, and it is worth separating those out early or the signal is drowned.

**What it buys, so the effort is justified rather than assumed.** Refactoring becomes tractable, because the checker enumerates the call sites affected by a shape change. The optional-value class of defect largely disappears at the boundary. And on an asynchronous codebase it catches a coroutine that is never awaited, which is a genuinely nasty runtime bug that produces no error and silently does nothing.

**And the honest caveat.** It is a real investment and its benefit is slow and diffuse, so it needs to be proposed as such rather than as a quick win. On a codebase nobody is changing much, it may simply not be worth it.

</details>

