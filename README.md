# Thumbnail generator on Kubernetes

**Kyryl Skobylko** · Senior Platform Engineer assignment for Cogent Labs · November 2026

This repository runs the thumbnail generator API on a local Kubernetes cluster, with monitoring, alerting,
tracing and a synthetic check of the whole upload-to-thumbnail path. One command builds everything from
nothing. The application in [`app/`](app/) is exactly as delivered; everything else is infrastructure.

- [Quick start](#quick-start)
- [What's running](#whats-running)
- [Operating it](#operating-it)
- [Observability](#observability)
- [What I tested](#what-i-tested)
- [Trade-offs and operational concerns](#trade-offs-and-operational-concerns)
- [Disaster recovery](#disaster-recovery)
- [Beyond this assignment](#beyond-this-assignment)
- [Findings for the app team](docs/app-findings.md) · [Runbooks](docs/runbooks.md)

## Quick start

You need Docker with **at least 6 GB of memory** (8 GB recommended; the whole cluster uses about 5 GB),
`kind`, `kubectl`, `helm`, `make`, `curl` and `openssl`, and port 8080 free.
Tested on macOS (Apple silicon) with Docker 28.4, kind 0.32.0, kubectl 1.34, and both Helm 4.0.0 and Helm 3.22.1,
and on a fresh Ubuntu 24.04 VM (x86_64, 4 vCPU, 8 GB) with Docker 29.1, kind 0.32.0, kubectl 1.34 and Helm 4.0.0.

**On Linux, raise the inotify limit first.** The default of 128 instances per user runs out once the cluster is
up, and containerd then stops noticing OOM kills ([details](#what-i-tested)). Docker Desktop already allows 8192.
`make up` checks it and stops with this command if needed:

```sh
sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
```

```sh
make up        # cluster, platform, MongoDB and MinIO, app, then a smoke test (4 to 7 minutes)
make help      # every target
make down      # delete everything
```

Use the API through the gateway on `http://localhost:8080`:

```sh
curl -F 'file=@app/src/test/images/good_image_400x400.png' localhost:8080/thumbnail   # -> {"data":{"job_id":"..."}}
curl localhost:8080/thumbnail/<job_id>                                                  # status, "complete" after ~5 s
curl -o thumb.png localhost:8080/thumbnail/<job_id>/image                               # the 100x100 thumbnail
```

Look inside:

| Command | Opens |
|---|---|
| `make grafana` | Grafana on http://localhost:3000 (prints the password); dashboard **Thumbnail service** |
| `make prometheus` / `make alertmanager` | http://localhost:9090 / http://localhost:9093 |
| `make jaeger` | Traces on http://localhost:16686 |
| `make status` / `make alerts` | Pods and releases / firing alerts, in the terminal |

## What's running

```
                      localhost:8080
                            │
              ┌─────────────▼─────────────┐
              │  Envoy Gateway (2 Envoys) │◄──── prober: test upload every 30 s
              └─────────────┬─────────────┘
                            │ HTTPRoute
                    ┌───────▼───────┐
                    │   api  ×2     │──┐
                    └───────────────┘  │      ┌──────────────────────────┐
                    ┌───────────────┐  ├─────►│ MongoDB  (jobs + queue)  │
                    │  worker ×2    │──┤      ├──────────────────────────┤
                    └───────────────┘  └─────►│ MinIO    (images)        │
                                              └──────────────────────────┘
  monitoring: Prometheus · Alertmanager · Grafana · Jaeger · kube-state-metrics · node-exporter · Mongo exporter
```

A client uploads an image to the API, which stores it in MinIO, records a job in MongoDB and queues it
(Agenda, also in MongoDB). A worker picks the job up within about 5 s, resizes the image with sharp and stores
the thumbnail. The client polls the job and downloads the result.

| Component | Choice | Why |
|---|---|---|
| Cluster | kind: one control plane, two workers, pinned node image (Kubernetes 1.35) | Free and reproducible; two workers make replica spreading and disruption budgets real |
| Entry point | Envoy Gateway v1.9 with the Gateway API | Standard routing that works with any Gateway API implementation in the cloud or on-prem; request metrics, JSON access logs and tracing at the edge; the platform owns the Gateway, the app owns its route |
| App | Helm chart [`charts/thumbnail`](charts/thumbnail): API and worker from one image, route, prober, monitoring | One command to install, update or roll back; values per environment |
| MongoDB, MinIO | Plain StatefulSets with the compose images, outside the chart | Development stand-ins: in the cloud the chart points at managed MongoDB and S3 instead |
| Monitoring | kube-prometheus-stack, trimmed for kind | Prometheus, Alertmanager, Grafana and kube-state-metrics in one pinned chart |
| App telemetry | OpenTelemetry auto-instrumentation, injected without changing the app | Per-route metrics and request traces from an app that has none |
| Traces | Jaeger, in memory | Enough for development |

```
Makefile              every operation: make help
app/                  the provided application, unchanged
cluster/kind.yaml     the cluster
charts/thumbnail/     the app's chart: Deployments, route, prober, PodMonitor, alerts, dashboard
deploy/manifests/     namespaces, gateway, Jaeger, MongoDB, MinIO
deploy/values/        values for the third-party charts
scripts/              credentials, smoke test, backup and restore
docs/                 runbooks, findings for the app team
```

## Operating it

**Deploy a change.** `make deploy` builds the image, tags it with the git tree hash of `app/` (the pods only
roll when the app changes), loads it into kind and runs `helm upgrade`. The rollout replaces one pod at a time
and never goes below the current capacity; if the new pods don't become ready, Helm rolls back by itself.
`make rollback` returns to the previous release.

**Scale.** Set `api.replicas` / `worker.replicas` in [`values.yaml`](charts/thumbnail/values.yaml) and `make deploy`.

**Configuration.** Connection settings and limits are chart values; credentials are generated once into
cluster Secrets by [`scripts/create-secrets.sh`](scripts/create-secrets.sh) and never written to disk or git.
The app connects to MongoDB as a user that can only read and write its own database; the exporter's user can
only read monitoring data.

**Upgrade the platform.** Versions are pinned at the top of the [`Makefile`](Makefile) (each was at least two
weeks old when pinned). Bump one and run `make platform` or `make deps`. All CRDs are applied server-side first
(`make crds`), because Helm never upgrades CRDs itself and components depend on each other's CRDs.

**Send alerts somewhere.** Alerts show in Alertmanager (`make alertmanager`) and Grafana but go nowhere else by
default. To route them to Slack, add to [`deploy/values/kube-prometheus-stack.yaml`](deploy/values/kube-prometheus-stack.yaml)
and run `make monitoring`:

```yaml
alertmanager:
  config:
    route:
      receiver: slack
      routes:
        - receiver: "null"
          matchers: [alertname = "Watchdog"]
    receivers:
      - name: "null"
      - name: slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack/url   # from a Secret, not git
            channel: "#thumbnail-alerts"
            send_resolved: true
  alertmanagerSpec:
    secrets: [slack]
```

## Observability

Signals are grouped by layer, so a failure points at its layer instead of starting an argument about whose
fault it is:

| Layer | Source | Tells you |
|---|---|---|
| End to end | Synthetic prober ([`prober.js`](charts/thumbnail/files/prober.js)) | Does an uploaded image come back as a 100x100 PNG, how long it takes, and at which stage it failed |
| Gateway | Envoy stats and JSON access logs | What clients actually got, including errors Envoy generates itself (no healthy pod, timeouts) |
| App | OpenTelemetry metrics and traces | Latency and status per route, failed calls to MinIO, event loop delay; per-request traces |
| Pods | kube-state-metrics, cAdvisor | Restarts, OOM kills, memory against limits, CPU |
| Dependencies | MongoDB exporter, MinIO's built-in metrics | Up or down, operations, objects stored, free space |

### Reliability indicators

| Indicator | Good events / all events | Target | Measured at |
|---|---|---|---|
| **Thumbnail success** | Prober runs whose thumbnail downloaded within 30 s | 99% | Prober |
| **Thumbnail latency** | Prober runs done within 10 s | 95% | Prober |
| **Gateway availability** | Requests answered without a 5xx | 99.5% | Envoy listener |
| **API latency** | `/thumbnail` requests answered within 500 ms | 95% | Inside the API |

Thumbnail success is the one that matters most. The app answers 200 when an upload wasn't stored, marks jobs
complete when the thumbnail wasn't saved, and answers 400 to everything else, so status codes alone can't show
whether users get thumbnails. Only doing what a user does, uploading and downloading, can. 4xx are left out of
availability for the same reason: the app's 400s can't be told apart from client mistakes.

The prober goes through the public gateway, so it also tests the route, the gateway and its timeout. It waits
one interval after starting, so a fresh install isn't counted as an outage.

### Alerts

Defined in [`alerts.yaml`](charts/thumbnail/templates/alerts.yaml), each linking to its [runbook](docs/runbooks.md):

| Alert | Fires when | Severity |
|---|---|---|
| ThumbnailProbeFailing | 3 prober failures in 5 min; labelled with the stage that failed | critical |
| ThumbnailProbeSlow | p95 upload-to-thumbnail time over 10 s for 15 min | warning |
| ThumbnailProberDown | No prober metrics for 5 min | warning |
| ThumbnailApiErrorBudgetBurn | Gateway 5xx ratio over 14.4× the 0.5% budget, over both 5 min and 1 h | critical |
| ThumbnailApiSlow | API p95 over 500 ms for 10 min | warning |
| ThumbnailStorageWritesFailing | Failed writes to MinIO from the API (upload lost behind a 200) or the worker (job "complete" without a thumbnail) | critical |
| ThumbnailContainerOOMKilled | A container killed for exceeding its memory limit | warning |
| ThumbnailMongoDown / ThumbnailMinioDown | A dependency unreachable or gone for 1 min | critical |
| ThumbnailStorageLow | Under 20% free space for MinIO | warning |

kube-prometheus-stack adds its standard alerts (crash loops, pods not ready, disks filling up, and so on).

### Dashboard, traces and logs

The **Thumbnail service** dashboard has one row per layer, top to bottom in the order to check them: the four
indicators over the selected time range, then end to end, gateway, app, pods and dependencies.

Envoy starts a trace for every request and passes it to the API, so one trace in Jaeger shows the time spent in
the gateway, the API handler and each MongoDB and MinIO call. The API only keeps traces that came through the
gateway (a parent-based sampler with ratio 0), which drops health probes and metric scrapes. Each Envoy
access-log line carries its `trace_id`. The worker sends metrics only: without a span per job, its traces are
disconnected fragments.

## What I tested

Each test was run on the kind cluster with the prober running; numbers are measured, not estimated.

| Test | Result |
|---|---|
| Rolling restart of API and workers (3 rollouts) | 16 of 16 prober runs succeeded, 0 gateway 5xx |
| Delete an API pod | No prober failures, 0 gateway 5xx |
| Stop MinIO | Uploads still answered 200 (app defect). `ThumbnailStorageWritesFailing` fired after 62 s, `ThumbnailProbeFailing` with stage `processing`. A worker restarted during the outage waited in its init container ("waiting for MinIO: ECONNREFUSED") and started 8 s after MinIO returned. This test also showed `ThumbnailMinioDown` never fired, because a pod that's gone has no `up` series at all; fixed with `absent()` |
| Stop MongoDB | Requests got a 504 after the 10 s gateway timeout instead of hanging 30 s. `ThumbnailMongoDown` fired at 86 s, `ThumbnailProbeFailing` at 117 s. The API crash-looped; workers stayed up and silent. After MongoDB returned (2 s), the API took **318 s** to answer again because of Kubernetes' restart back-off. Data intact |
| Scale workers to zero | Only `ThumbnailProbeFailing` (stage `processing_timeout`) fired, at 153 s: nothing crashed, so no other signal could see it |
| Upload over 10 MiB / 5 MB | 413 from the gateway / accepted |
| A 256-megapixel PNG (729 KiB file, 732 MiB decoded) | Thumbnail in under 10 s, worker memory 57 MiB: libvips streams PNG decoding |
| `make down && make up` | 220 s from nothing to a passing smoke test (Helm 4.0.0); 210 s with Helm 3.22.1 |
| `make up` on a fresh Ubuntu 24.04 VM (x86_64, Docker 29.1) | Passed in 392 s, downloading every image. But it ran out of inotify instances; see below |
| Disaster recovery: `make backup`, `make down`, `make up`, `make restore` | Backup 3 s, rebuild 210 s, restore 4 s. A thumbnail made before the cluster was deleted downloaded again |
| Enforce the restricted Pod Security standard | A server-side dry run found no violating pod; enforced, and pods are still admitted |

The tests also found problems in my own setup, all fixed:
- Grafana was OOM-killed at the memory limit I had guessed; it's now set from measurements.
- Both API replicas landed on one node after a rolling update; the spread rule now counts only pods of the same revision.
- A clean `make up` failed: Jaeger's manifest needed the Gateway API's CRDs, which a later step installed. On my
  working cluster they were already there. All CRDs now go in first.
- The first restore got MinIO OOM-killed: `mc pipe` buffers 528 MiB by default and ran inside MinIO's container.
  `ThumbnailContainerOOMKilled` fired a minute later. The copy now runs in its own pod with a 16 MiB part size.
- On Linux the cluster needs 150 inotify instances, and the kernel allows 128 per user by default (Docker Desktop
  allows 8192, so the Mac never showed it). Nothing visibly broke, but containerd couldn't watch the containers
  started after that for OOM kills ("failed to watch oom events", 45 times during one install). A test pod killed
  for memory showed as `Error`, exit 137, instead of `OOMKilled`, so `ThumbnailContainerOOMKilled` would never
  have fired. `make up` now checks the limit and stops with the fix; with the limit at 512, the same pod showed
  `OOMKilled`.

## Trade-offs and operational concerns

### Running the app unchanged

The app has defects that infrastructure can only work around ([full list](docs/app-findings.md)). I kept the
workarounds few and labelled, each with the app change that removes it, so they don't quietly become permanent:

| Workaround | Because the app… | Remove when |
|---|---|---|
| Init container that checks MongoDB and MinIO with the app's credentials | Keeps running, idle, when its startup checks fail | It exits non-zero on startup failure |
| 10 MiB upload cap at the gateway | Accepts any upload size into memory | It enforces its own limit (keep the cap as an extra guard) |
| `node dist/index.js` instead of `npm start` | Runs npm as PID 1, which loads the instrumentation too and takes its metrics port | The Dockerfile runs node directly |
| Injected OpenTelemetry instrumentation | Has no metrics or traces | It ships its own, with queue metrics and a span per job |
| Prober as the main indicator | Answers 200 for failures and 400 for everything else | Never: synthetic checks stay useful |

The cost of running `node` directly: the app doesn't handle SIGTERM, and as PID 1 it ignores it, so each pod
waits out its 15 s grace period before being killed. The API gets a 5 s pause first so the gateway stops sending it
traffic, and rolling updates showed no errors. A job running when a worker is killed is retried only after
Agenda's 10-minute lock expires. Only the app can fix that, by handling SIGTERM.

### MongoDB and MinIO

They run as single instances on local volumes: if their node dies, they stay down until it returns. That's
acceptable for development and the reason they're outside the app chart. The chart only needs a connection string
and an S3 endpoint, so the same chart runs against MongoDB Atlas or DocumentDB and S3 in the cloud, or against
operator-run replicated MongoDB and object storage on-prem. I avoided the Bitnami charts (Bitnami withdrew most
of its free images in 2025) and MinIO's operator (too much for a stand-in). The MinIO image is a community build,
the same one the app's docker-compose uses, since MinIO stopped publishing free images.

On kind, the local-path volumes don't enforce their size; MinIO's free space reports the node's disk.

### Envoy Gateway and the Gateway API

Ingress is frozen upstream and ingress-nginx was retired in March 2026, so routing uses the Gateway API.
The platform owns a shared Gateway that accepts routes only from namespaces labelled for it; the app ships its
own HTTPRoute, with a request timeout that is standard Gateway API. Two settings are specific to Envoy Gateway,
and both are marked in the files: the upload cap (a `BackendTrafficPolicy`) and the gateway's own telemetry.

It costs more than a single ingress controller: a controller, two Envoy pods and 18 CRDs. CRDs come from the
standard channel, which is safe next to CRDs a cloud provider already manages.

On kind, the gateway's NodePort uses `externalTrafficPolicy: Cluster`: kind publishes port 8080 only on the
control-plane node, which runs no Envoy. That loses the client's IP address; in the cloud the default `Local`
keeps it.

### OpenTelemetry in the chart rather than through the operator

The chart does what the OpenTelemetry operator would inject: an init container copies the Node.js SDK from the
operator's own image into a shared volume, and `NODE_OPTIONS` preloads it. I didn't run the operator itself because:

- For one service, it adds CRDs and an admission webhook to every pod start. A pod is instrumented only if the
  operator and its `Instrumentation` resource are ready when the pod starts; otherwise it starts without
  instrumentation and nothing reports it.
- This app needs settings the operator doesn't cover anyway: `node` instead of `npm start`, a pinned image (the
  current one requires Node 22.15, the app runs Node 20; 0.78.0 is the last that supports Node 20), metrics bound
  to all interfaces, noisy DNS and TCP instrumentation off, and cloud metadata detection off (it probes Google
  Cloud on every start).
- Moving to the operator later is cheap: same image, same environment variables. That's the right step once
  several services run on the platform.

The init container needs 256 MiB for a few seconds: the SDK is 133 MB in 19,000 files, and with 64 MiB the copy's
page cache got it OOM-killed.

### Smaller decisions

- **Prober as a Deployment, not a CronJob.** It exposes a success counter, a duration histogram and the failing
  stage; a CronJob would only report that each run passed or failed. It runs on a current Node image with no
  dependencies.
- **Error-budget alert.** The gateway availability alert uses two windows (5 min and 1 h), so a short blip doesn't
  page and recovery clears it quickly. With little traffic it's slow, as the MongoDB test showed; the prober alert
  is the fast signal.
- **Helm 4.** It applies changes server-side, and an object added by one upgrade conflicts with Helm's own write on
  the next. The Makefile passes `--force-conflicts` on Helm 4 (Helm owns these objects) and `--atomic` on Helm 3.
- **Everything targets the kind context explicitly** (`--context kind-thumbnail`), so no command can touch another
  cluster that happens to be current.
- **Resources come from measurements**: the app's limits from load tests (the worker resizes 5 images at once and
  peaked at 361 MiB), the platform's from a run on this cluster.
- **Security baseline.** Every pod in the app's namespace (app, prober, MongoDB, MinIO, exporter) runs as non-root
  with no privilege escalation and no capabilities, and the namespace enforces the restricted Pod Security
  standard, so a pod that doesn't comply is rejected. The app's containers also have a read-only filesystem.
  MinIO serves metrics without a token, acceptable only because the port isn't exposed outside the cluster.

## Disaster recovery

**Everything except data is in git.** `make up` rebuilds the cluster, platform, dependencies and app from nothing
in 4 to 7 minutes (210-220 s measured on a Mac with Docker's cache warm, 392 s on a fresh Linux VM that downloaded
everything). Credentials are generated fresh, so nothing secret has to be restored.

**Data** is MongoDB (jobs and the queue) and MinIO (originals and thumbnails). On kind both live inside the node
containers, so `make down` deletes them. [`scripts/data.sh`](scripts/data.sh) backs them up and restores them:

```sh
make backup                               # -> backups/<timestamp>/: a MongoDB dump and every object in the bucket
make restore BACKUP=backups/<timestamp>   # into a running cluster: replaces the collections, rewrites the objects
```

To recover from a lost cluster: `make up`, then `make restore`. Tested end to end: a thumbnail created before
the cluster was deleted downloaded again after the restore.

- Backups land in `backups/` (ignored by git) on the machine running `make`; copy them somewhere else.
- The MongoDB dump runs inside the MongoDB pod as the app's own user. MinIO objects are copied one by one from a
  throwaway pod, because the MinIO image has no `tar`: fine for this volume, far too slow for a real bucket.
- Recovery point is the last backup: anything uploaded after it is lost, and clients would upload again. The
  dump is taken before the objects, so every job in the dump has its files in the backup.

## Beyond this assignment

### Autoscaling

- **API:** a HorizontalPodAutoscaler on CPU is enough for this app (requests are short; uploads are buffered at
  the gateway). Per-pod request rate from Envoy, through KEDA's Prometheus scaler, is the better signal if CPU
  stays flat while latency grows.
- **Workers:** KEDA's MongoDB scaler on jobs waiting in the `agenda` collection
  (`{nextRunAt: {$lte: now}, lockedAt: null}`), sized as waiting jobs ÷ 5 (Agenda's concurrency per worker).
  KEDA also exports the queue length as a metric, which the app doesn't.
- **First, fix shutdown.** Scaling workers down kills them mid-job, and a killed job waits 10 minutes for its lock
  to expire. Autoscaling workers before the app handles SIGTERM (`agenda.stop()` releases locks) turns every
  scale-down into delayed thumbnails.
- **Testing it:** a load generator (k6) uploading at a rising rate, from below to well above one worker's
  capacity, then dropping to zero. Pass if the thumbnail latency indicator stays within target during the ramp,
  replicas follow the queue within a minute or two, and scale-down loses or delays no jobs. Run it in CI against
  kind before each change to the scaling rules.
- **Nodes:** Karpenter or the cluster autoscaler, with workers allowed on spot capacity once the shutdown issue is fixed.

### Cost

- **Allocation:** OpenCost, using the cloud's price list, gives cost per namespace and workload from the same
  Prometheus.
- **Right-sizing:** compare requests with actual use; the dashboard already shows memory against limits. On this
  cluster limits range from twice the measured peak (Grafana) to many times it (Jaeger, the Envoy Gateway
  controller): fine for development, to be tightened from a few weeks of production data.
- **The dominant cost is storage**, because nothing is ever deleted. A lifecycle rule (originals to infrequent
  access after a week, deleted after a month, if the product allows) and a TTL on job records cap it.
- **Telemetry costs too**: metric retention and label counts, trace sampling (1-10% in production, errors kept),
  log retention.

### Backups in production

Managed services first: continuous backup with point-in-time restore for MongoDB (Atlas, DocumentDB), versioning
plus cross-region replication and Object Lock for S3. On-prem: Percona Backup for MongoDB or scheduled dumps to
object storage, and bucket replication for the object store. Velero for cluster resources and volumes. Agree
recovery targets with the product owner, then restore into a scratch environment regularly; a backup that
has never been restored is a guess.

### Security and compliance

- **Network:** NetworkPolicies, default deny: only the gateway reaches the API, only the app reaches MongoDB and
  MinIO, only Prometheus scrapes metrics. TLS at the gateway (cert-manager), authentication and rate limits there
  too (Envoy Gateway's `SecurityPolicy` and `BackendTrafficPolicy`), and TLS to MongoDB.
- **Workloads:** the restricted Pod Security standard (already enforced here) on every namespace; a MinIO user
  limited to one bucket instead of the root credentials; secrets from a manager (External Secrets with Vault or
  the cloud's).
- **Supply chain:** the app's production dependencies have 19 known vulnerabilities (1 critical, 10 high) and run on
  an unsupported Node. Scan images and dependencies in CI (Trivy), keep them current (Renovate), sign images
  (cosign) and admit only signed images with resource limits (Kyverno). Generate SBOMs.
- **Compliance** (ISO 27001, SOC 2 and the like) then mostly means evidence: policy as code, audit logs from the API
  server and gateway, access reviews, change history in git.

### Getting to production

- **Cloud:** Terraform for the cluster (EKS or similar), managed MongoDB, S3 and DNS. The Gateway gets a
  LoadBalancer Service; the chart is unchanged apart from values.
- **On-prem:** the same chart; MetalLB or the existing load balancer in front of Envoy; operators for replicated
  MongoDB and object storage.
- **Delivery:** CI that builds, tests, scans and signs the image and pushes it to a registry; Argo CD or Flux
  deploying the chart per environment from git.
- **Telemetry:** an OpenTelemetry Collector between apps and backends (filtering, tail sampling, one place to
  change backends), Tempo or Jaeger on object storage, central logs with Loki and Alloy, SLOs and burn-rate
  alerts managed with Sloth or Pyrra.
- **High availability:** at least three nodes across zones, MongoDB as a replica set, distributed object storage,
  Envoy spread across zones.

### For the app

The full list, with file and line references, is in [docs/app-findings.md](docs/app-findings.md). The ones that
matter most: answer 200 only after the upload is stored, exit when startup fails, don't crash on a database error,
handle SIGTERM, return meaningful status codes, expose queue metrics, upgrade Node and the vulnerable dependencies.
