// Init container: block until MongoDB and MinIO accept the app's own
// credentials. Workaround for an app defect: when its startup checks fail the
// app logs an error but keeps running and never retries (app/src/index.ts),
// so a worker started before MinIO is ready would sit idle forever.
// Runs with the app image and its libraries (NODE_PATH points at them).
const { MongoClient } = require('mongodb');
const Minio = require('minio');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function mongoReady() {
  const client = await MongoClient.connect(process.env.MONGO_URL, {
    useUnifiedTopology: true,
    serverSelectionTimeoutMS: 3000,
  });
  try {
    await client.db().command({ ping: 1 });
  } finally {
    await client.close();
  }
}

async function minioReady() {
  const storage = new Minio.Client({
    endPoint: process.env.MINIO_ENDPOINT,
    port: parseInt(process.env.MINIO_PORT, 10),
    useSSL: process.env.MINIO_USE_SSL === 'true',
    accessKey: process.env.MINIO_ACCESS_KEY,
    secretKey: process.env.MINIO_SECRET_KEY,
  });
  await storage.bucketExists('thumbnails');
}

(async () => {
  for (const [name, check] of [['MongoDB', mongoReady], ['MinIO', minioReady]]) {
    for (;;) {
      try {
        await check();
        console.log(`${name} is ready`);
        break;
      } catch (err) {
        console.log(`waiting for ${name}: ${err.message}`);
        await sleep(2000);
      }
    }
  }
  process.exit(0);
})();
