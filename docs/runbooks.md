# Runbooks

One section per alert. Every alert links here (`runbook_url`).

Commands assume the kind cluster's context: `kubectl config use-context kind-thumbnail`.
Dashboards: `make grafana`, then open the **Thumbnail service** dashboard.

## Triage order

The dashboard rows follow the order to check things in. Stop at the first layer that looks wrong:

1. **End to end.** Is the prober failing, and at which stage (`upload`, `processing`, `download`)?
2. **Gateway.** 5xx at Envoy? 503 means no healthy API pod, 504 means the API didn't answer within 10 s.
3. **API and worker.** Errors or latency per route, failed calls to MinIO.
4. **Pods.** Restarts, OOM kills, memory near the limit.
5. **Dependencies.** MongoDB and MinIO up, free space.

The app returns HTTP 400 for every error, including its own failures, so don't read 4xx as "client problem"
without checking the logs. Logs: `kubectl -n thumbnail logs deploy/thumbnail-api` (and `-worker`).
Request log: `kubectl -n envoy-gateway-system logs -l app.kubernetes.io/component=proxy -c envoy`.
Each access-log line has a `trace_id` you can open in Jaeger (`make jaeger`).

---

## ThumbnailProbeFailing

**Meaning.** The synthetic upload failed at least 3 times at the same stage in 5 minutes. The `result` label
says where:

| result | Where it broke | Look at |
|---|---|---|
| `upload_failed` | POST through the gateway | Gateway 5xx, API pods, MongoDB (the API crashes without it) |
| `processing_failed` | The job ended as `failed` | Worker logs; MinIO (the worker can't read the original) |
| `processing_timeout` | Still `waiting` after 30 s | Worker pods running? Stuck in `Init`? MongoDB reachable? |
| `download_failed` | Thumbnail missing or not a 100x100 PNG | MinIO; `ThumbnailStorageWritesFailing` |

**Impact.** Users don't get thumbnails. This is the main reliability indicator.

**Check.**
```sh
kubectl -n thumbnail logs deploy/thumbnail-prober --tail=20   # one JSON line per run, with the error
kubectl -n thumbnail get pods -o wide
make alerts                                                   # what else is firing
```

**Fix.** Follow the stage. Workers stuck in `Init` print what they are waiting for:
`kubectl -n thumbnail logs <worker-pod> -c wait-for-deps`.

## ThumbnailProbeErrorBudgetBurn

**Meaning.** More than 14.4% of synthetic uploads failed over both the last 5 minutes and the last hour, at any
mix of stages: at that rate the monthly 99% budget lasts about two days. It catches failures spread across
stages, which `ThumbnailProbeFailing` (3 at one stage) can miss.

**Check.** Which stages fail, from the prober's own log, then follow them as in `ThumbnailProbeFailing`:
```sh
kubectl -n thumbnail logs deploy/thumbnail-prober --tail=120 | grep -v '"result":"success"'
```

## ThumbnailProbeSlow

**Meaning.** p95 of upload-to-thumbnail time is over 10 s for 15 minutes. The normal value is 4-6 s, set
mostly by Agenda checking for new jobs every 5 s.

**Check.** CPU and memory of the workers (dashboard row 4), the worker event loop delay (row 3), MongoDB
operations (row 5). A backlog shows as many jobs `waiting`.

**Fix.** Add workers: `kubectl -n thumbnail scale deploy/thumbnail-worker --replicas=4` (and set
`worker.replicas` in the chart values so the next deploy keeps it).

## ThumbnailProberDown

**Meaning.** Prometheus has no prober metrics for 5 minutes, so end-to-end failures would go unnoticed.

**Check.** `kubectl -n thumbnail get pods -l app.kubernetes.io/component=prober` and its logs. The prober
needs nothing but the gateway.

## ThumbnailApiErrorBudgetBurn

**Meaning.** More than 7.2% of requests at the gateway are 5xx, over both the last 5 minutes and the last
hour: at that rate the monthly 99.5% budget would last about two days.

With little traffic, mostly the prober, this alert is slow: a failing prober sends one request per run
instead of about ten, so the 1-hour ratio climbs slowly. `ThumbnailProbeFailing` is the fast signal.

**Check.** Status codes in the Envoy access log:
```sh
kubectl -n envoy-gateway-system logs -l app.kubernetes.io/component=proxy -c envoy --tail=50 | grep '"status":5'
```
- `503` with flags `UH` or `UF`: no healthy API pod. Check API pods and restarts.
- `503` with flag `UC`: an API pod died mid-request; it crashes on a MongoDB error (see `ThumbnailMongoDown`).
- `504` with flag `UT`: the API didn't answer in 10 s. Usually MongoDB: see `ThumbnailMongoDown`.

## ThumbnailApiSlow

**Meaning.** p95 latency of `/thumbnail` requests, measured inside the API, is over 500 ms for 10 minutes.

**Check.** Which route (dashboard row 3), then a slow trace in Jaeger: it shows the MongoDB and MinIO calls
with their timings.

## ThumbnailStorageWritesFailing

**Meaning.** Uploads to MinIO failed in the last 5 minutes. The app hides this:
- from the **api**: the client got HTTP 200 and a job id, but the original was never stored. The job will fail.
- from the **worker**: the job was marked `complete`, but the thumbnail was never stored.

The alert stays up for 5 minutes after the last failed write.

**Check.** `ThumbnailMinioDown`, MinIO logs (`kubectl -n thumbnail logs minio-0`), free space.

**Fix.** Restore MinIO. Affected jobs can't be recovered (the files were never written): users have to
upload again.

## ThumbnailContainerOOMKilled

**Meaning.** A container was killed for exceeding its memory limit.

**Check.** Which container (labels), then its memory in dashboard row 4. The worker resizes 5 images at once;
the API holds whole uploads in memory (the gateway caps them at 10 MiB).

**Fix.** Raise the limit in the chart values (`api.resources` / `worker.resources`) and `make deploy`.

## ThumbnailMongoDown

**Meaning.** MongoDB is unreachable (or its exporter is down) for 1 minute.

**Impact, as tested.** API requests hang until the gateway answers 504 after 10 s; then the API process crashes
(unhandled error) and Kubernetes restarts it, so the API pods crash-loop. Workers stay up and stop processing
without logging anything; they resume by themselves.

**Check.** `kubectl -n thumbnail get pods mongodb-0`, `kubectl -n thumbnail logs mongodb-0`, `kubectl -n thumbnail describe pod mongodb-0`.

**Fix.** Bring MongoDB back, then restart the API: after crash-looping, Kubernetes waits up to 5 minutes between
restarts (measured: 318 s until the API answered again).
```sh
kubectl -n thumbnail rollout restart deploy/thumbnail-api
```

## ThumbnailMinioDown

**Meaning.** MinIO is unreachable or gone for 1 minute.

**Impact, as tested.** Uploads still get HTTP 200 but nothing is stored; jobs fail; downloads fail. Workers started
during the outage wait in their init container until MinIO is back.

**Check.** `kubectl -n thumbnail get pods minio-0`, `kubectl -n thumbnail logs minio-0`.

**Fix.** Bring MinIO back. Workers recover within seconds (tested: 8 s).

## ThumbnailStorageLow

**Meaning.** Less than 20% free space for MinIO. The app never deletes originals, thumbnails or job records,
so usage only grows. On kind the number is the node's disk, because local-path volumes don't enforce their size.

**Fix.** Short term: delete old objects or grow the volume. Long term: a lifecycle rule on the bucket and a
retention policy for job records (see the README).
