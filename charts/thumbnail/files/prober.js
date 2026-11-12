// Synthetic prober. Every PROBE_INTERVAL_SECONDS it uploads a small test image
// through the public gateway, waits for the worker, downloads the thumbnail
// and checks it is a 100x100 PNG: the same path a user takes. The result of
// each run is exposed as Prometheus metrics on :9090/metrics.
// Node built-ins only, so it runs on a stock Node image.
const http = require('node:http');
const fs = require('node:fs');

const target = process.env.PROBE_TARGET;
const intervalMs = Number(process.env.PROBE_INTERVAL_SECONDS || 30) * 1000;
const timeoutMs = Number(process.env.PROBE_TIMEOUT_SECONDS || 30) * 1000;
const image = fs.readFileSync('/prober/probe.png');

const RESULTS = ['success', 'upload_failed', 'processing_failed', 'processing_timeout', 'download_failed'];
const BUCKETS = [1, 2.5, 5, 7.5, 10, 15, 20, 30];
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const runs = Object.fromEntries(RESULTS.map((result) => [result, 0]));
const duration = { buckets: BUCKETS.map(() => 0), sum: 0, count: 0 };
let lastSuccess = 0;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class ProbeError extends Error {
  constructor(result, message) {
    super(message);
    this.result = result;
  }
}

// One HTTP call; any failure is reported as `result` (the stage it belongs to).
async function request(result, path, options = {}) {
  let res;
  try {
    res = await fetch(target + path, {
      ...options,
      headers: { 'user-agent': 'thumbnail-prober' },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    throw new ProbeError(result, `${path}: ${err.cause?.code || err.message}`);
  }
  if (!res.ok) throw new ProbeError(result, `${path}: HTTP ${res.status}`);
  return res;
}

async function probe(started) {
  const form = new FormData();
  form.append('file', new Blob([image], { type: 'image/png' }), 'probe.png');
  const upload = await request('upload_failed', '/thumbnail', { method: 'POST', body: form });
  const jobId = (await upload.json()).data?.job_id;
  if (!jobId) throw new ProbeError('upload_failed', 'no job_id in the response');

  for (;;) {
    const res = await request('processing_failed', `/thumbnail/${jobId}`);
    const status = (await res.json()).data?.status;
    if (status === 'complete') break;
    if (status === 'failed') throw new ProbeError('processing_failed', `job ${jobId} failed`);
    if (Date.now() - started > timeoutMs) {
      throw new ProbeError('processing_timeout', `job ${jobId} still '${status}' after ${timeoutMs / 1000}s`);
    }
    await sleep(500);
  }

  const res = await request('download_failed', `/thumbnail/${jobId}/image`);
  const png = Buffer.from(await res.arrayBuffer());
  const valid = png.length > 24 && png.subarray(0, 8).equals(PNG_SIGNATURE)
    && png.readUInt32BE(16) === 100 && png.readUInt32BE(20) === 100;
  if (!valid) throw new ProbeError('download_failed', `job ${jobId}: not a 100x100 PNG`);
}

function record(result, seconds) {
  runs[result] += 1;
  if (result !== 'success') return;
  lastSuccess = Date.now() / 1000;
  duration.sum += seconds;
  duration.count += 1;
  BUCKETS.forEach((le, i) => {
    if (seconds <= le) duration.buckets[i] += 1;
  });
}

function metrics() {
  return [
    '# HELP thumbnail_probe_runs_total Probe runs by result (success or the stage that failed).',
    '# TYPE thumbnail_probe_runs_total counter',
    ...RESULTS.map((result) => `thumbnail_probe_runs_total{result="${result}"} ${runs[result]}`),
    '# HELP thumbnail_probe_duration_seconds Upload to downloaded thumbnail, successful runs only.',
    '# TYPE thumbnail_probe_duration_seconds histogram',
    ...BUCKETS.map((le, i) => `thumbnail_probe_duration_seconds_bucket{le="${le}"} ${duration.buckets[i]}`),
    `thumbnail_probe_duration_seconds_bucket{le="+Inf"} ${duration.count}`,
    `thumbnail_probe_duration_seconds_sum ${duration.sum}`,
    `thumbnail_probe_duration_seconds_count ${duration.count}`,
    '# HELP thumbnail_probe_last_success_timestamp_seconds Unix time of the last successful run.',
    '# TYPE thumbnail_probe_last_success_timestamp_seconds gauge',
    `thumbnail_probe_last_success_timestamp_seconds ${lastSuccess}`,
    '',
  ].join('\n');
}

http.createServer((req, res) => {
  if (req.url !== '/metrics') {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' }).end(metrics());
}).listen(9090);

(async () => {
  // First run after one interval, so the minute the API takes to start on a
  // fresh install isn't counted as an outage.
  await sleep(intervalMs);
  for (;;) {
    const started = Date.now();
    let result = 'success';
    let error;
    try {
      await probe(started);
    } catch (err) {
      result = err instanceof ProbeError ? err.result : 'upload_failed';
      error = err.message;
    }
    const seconds = (Date.now() - started) / 1000;
    record(result, seconds);
    console.log(JSON.stringify({ time: new Date().toISOString(), result, seconds, error }));
    await sleep(Math.max(0, intervalMs - (Date.now() - started)));
  }
})();
