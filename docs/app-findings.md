# Findings for the app team

The infrastructure runs the app exactly as delivered (`app/` is unchanged). Running and breaking it surfaced
the issues below. Where the platform works around one, the workaround is labelled in the manifests and listed
in the README, with the change that lets us remove it.

"Tested" means reproduced with docker-compose or on the kind cluster; "Code" means found by reading the code.

## Reliability

| # | Finding | Where | How found | Fix |
|---|---|---|---|---|
| 1 | **An upload is answered 200 before the file is stored.** `putFile` isn't awaited, so `fileResult` is a Promise and always truthy; the database insert isn't awaited either. With MinIO down the client still gets a job id, and the job fails later. | `src/controllers/thumbnail.ts:31-32, 41` | Tested | `await` both and return 503 when they fail. |
| 2 | **A failed startup check doesn't exit.** The process logs "Shutting down server" but keeps running and never retries, so a worker started while MinIO is down idles forever with jobs piling up. No restart policy can help because nothing exits. | `src/index.ts:6-26` | Tested | `process.exit(1)` after logging; Kubernetes restarts it. |
| 3 | **The API crashes on a database error.** Async Express handlers have no error handling; on Node 15+ an unhandled rejection exits the process. With MongoDB down, a request hangs 30 s, then the whole API exits, dropping every request in flight. In Kubernetes it crash-loops, and after MongoDB returned it took 318 s to answer again (restart back-off). | `src/controllers/thumbnail.ts:56-74` (and every handler) | Tested | Catch errors per request (or a wrapper / Express 5) and answer 503. |
| 4 | **The startup database check crashes instead of logging.** `client.db()` runs before checking `err`, so a failed connection throws a TypeError. | `src/database.ts:11` | Code | Check `err` first. |
| 5 | **A job is marked complete even if the thumbnail wasn't saved.** The result of `putFile` is ignored. | `src/jobs/thumbnail.ts:45-49` | Code | Fail the job when the write fails. |
| 6 | **Failed jobs are never retried, and Agenda thinks every job succeeded** (`failCount` was 0 for every job). The job function catches everything and only sets `status: failed` on the record. | `src/jobs/thumbnail.ts:36-38` | Tested | Rethrow transient errors so Agenda retries; keep `failed` for bad input. |
| 7 | **`failed` mixes bad uploads and outages.** A corrupt image and an unreachable MinIO end in the same status, so failure rates can't be alerted on. | `src/jobs/thumbnail.ts:7-13` | Tested | Record a failure reason. |
| 8 | **No graceful shutdown.** Nothing handles SIGTERM. With `npm start` as PID 1 the app is killed abruptly (and npm logs `npm error signal SIGTERM` on every stop); a job running at that moment is retried only after Agenda's 10-minute lock expires. | `Dockerfile:13`, `src/index.ts` | Tested | On SIGTERM: stop accepting, finish requests, `agenda.stop()` (releases locks), exit. |
| 9 | **Agenda's polling (5 s) and concurrency (5 per worker) are hard-coded.** Polling sets a floor of 2-5 s on every thumbnail. | `src/worker.ts:5-14` | Tested | Read both from the environment. |

## Interfaces

| # | Finding | Where | How found | Fix |
|---|---|---|---|---|
| 10 | **Every error is a 400**: unknown job, failed job, server-side failures. Status codes can't be used to measure availability. | `src/controllers/thumbnail.ts` | Tested | 404 for unknown jobs, 409 for not ready, 5xx for server faults. |
| 11 | **No health endpoints.** `GET /` is static, so probes can't tell whether the API can reach MongoDB or MinIO. | `src/server.ts:10-12` | Code | `/healthz` (process) and `/readyz` (dependencies). |
| 12 | **Presigned links point at the internal MinIO host** (`http://minio:9000/...`), which only resolves inside the cluster. | `src/storage.ts:72-74` | Tested | A separate public endpoint for signing, or serve images through `/thumbnail/:id/image` only. |
| 13 | **A non-image upload gets "Please supply an image"**, not the file-type message: the empty-file check runs first. | `src/controllers/thumbnail.ts:17-25` | Tested | Check `fileValidationError` first. |
| 14 | **`/thumbnail/:id/image` has no `Content-Type`.** | `src/controllers/thumbnail.ts:86-88` | Tested | Set `image/png` / `image/jpeg`. |
| 15 | **The bucket region is hard-coded** (`ap-northeast-1`). | `src/storage.ts:21` | Code | Configuration. |

## Resources and data

| # | Finding | Where | How found | Fix |
|---|---|---|---|---|
| 16 | **Uploads have no size limit** and are held in memory. The gateway now rejects uploads over 10 MiB. A 256-megapixel PNG (729 KiB file) was processed fine in under 10 s at 57 MiB, because libvips streams PNG decoding. | `src/middleware.ts:5-21` | Tested | `limits.fileSize` in multer; an explicit `limitInputPixels` in sharp. |
| 17 | **Nothing is ever deleted**: originals, thumbnails, job records and Agenda jobs. Storage only grows. | whole app | Tested | Retention: a bucket lifecycle rule and a TTL index on job records. |
| 18 | **Without a database name in the URL the app uses `test`.** The platform sets `/thumbnails` in the connection string. | `src/database.ts:11` | Tested | Document it, or require a name. |

## Observability

| # | Finding | How found | Fix |
|---|---|---|---|
| 19 | **No metrics and no traces.** The platform injects OpenTelemetry auto-instrumentation, which gives per-route API metrics and request traces, but nothing for jobs: no span per job, no queue metrics. | Tested | Expose queue length, oldest waiting job, job duration and failures by reason; carry `traceparent` in the job data so a trace connects the upload to its processing. |
| 20 | **Logs are thin.** No request log (a successful request writes nothing), plain text without timestamps or levels, multi-line stack traces. A client asking for an unfinished job's image produces a 10-line error stack trace. With MongoDB down the worker logs nothing at all. | Tested | JSON logs with level and request or job id; no stack traces for client mistakes. |

## Build and dependencies

| # | Finding | Where | Fix |
|---|---|---|---|
| 21 | **Node.js 20 reached end of life in April 2026.** Current OpenTelemetry releases need Node 22.15+, which is why the platform pins an older instrumentation image. | `Dockerfile:1` | Node 22 or 24 LTS. |
| 22 | **`npm audit` of production dependencies: 19 known vulnerabilities, 1 critical and 10 high**, including direct dependencies express 4.17.1, multer 1.4.2 and sharp 0.29.0. | `package.json` | Upgrade; scan in CI. |
| 23 | **The image ships dev dependencies, tests and TypeScript sources** (235 MB of `node_modules`, 526 packages) and runs as root. The platform runs it as uid 1000 with a read-only filesystem. | `Dockerfile` | Multi-stage build: compile, then copy `dist` and production dependencies only; `USER node`. |
| 24 | **`npm start` as the entrypoint.** npm becomes PID 1: it loads `NODE_OPTIONS` too and logs errors on every stop. The platform runs `node dist/index.js`. | `Dockerfile:13` | `CMD ["node", "dist/index.js"]`. |

---

## What the platform expects from every service

The list that would let the platform drop its workarounds, and the same bar for the next service:

1. **Health endpoints**: `/healthz` for the process, `/readyz` for its dependencies.
2. **Fail loudly**: exit non-zero when it can't start; don't crash on a transient dependency error mid-request.
3. **Graceful shutdown**: on SIGTERM stop accepting work, finish what's in flight, release locks, exit within 10 s.
4. **`/metrics`** in Prometheus format: rate, errors and duration per route, plus queue metrics for background work.
5. **Meaningful status codes**: 4xx for client errors, 5xx for server faults, 503 when a dependency is down.
6. **Structured logs**: JSON, with level and a request or job id.
7. **Configuration from the environment**, including limits and tuning knobs.
8. **Bounded resources**: request size limits, retention for stored data.
9. **A supported runtime** in a minimal, non-root image with `node` as the entrypoint.
10. **Trace context through queues**, so a trace follows a request across asynchronous work.
