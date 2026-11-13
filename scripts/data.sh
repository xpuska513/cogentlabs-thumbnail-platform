#!/usr/bin/env sh
# Backs up or restores the app's data: the MongoDB database (jobs and the
# queue) and every object in the MinIO bucket.
#
#   data.sh backup              writes backups/<timestamp>/
#   data.sh restore <directory> replaces the collections and rewrites the objects
#
# Credentials are read inside the cluster, never through this shell.
set -eu

CONTEXT=${CONTEXT:-kind-thumbnail}
NAMESPACE=${NAMESPACE:-thumbnail}
MINIO_IMAGE=pgsty/minio:RELEASE.2026-08-04T00-00-00Z
kc() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

# mongodump and mongorestore run inside the MongoDB pod, as the app's own user.
mongo() {
  kc exec -i mongodb-0 -- sh -c "$1 --quiet --archive --gzip \
    --uri \"mongodb://thumbnail:\$MONGO_APP_PASSWORD@localhost:27017/?authSource=thumbnails\" $2"
}

# mc runs in a throwaway pod, so it never shares the MinIO server's memory
# limit. (A first version ran it inside the MinIO container, and `mc pipe`'s
# default 528 MiB upload buffer got the server OOM-killed.)
start_minio_client() {
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: minio-client
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: mc
      image: $MINIO_IMAGE
      command: ["sleep", "3600"]
      env:
        - { name: MC_CONFIG_DIR, value: /tmp/mc }
        - name: MINIO_USER
          valueFrom: { secretKeyRef: { name: thumbnail-credentials, key: minio-root-user } }
        - name: MINIO_PASSWORD
          valueFrom: { secretKeyRef: { name: thumbnail-credentials, key: minio-root-password } }
      resources:
        requests: { cpu: 10m, memory: 64Mi }
        limits: { memory: 256Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      volumeMounts: [{ name: tmp, mountPath: /tmp }]
  volumes: [{ name: tmp, emptyDir: {} }]
EOF
  trap 'kc delete pod minio-client --wait=false >/dev/null 2>&1' EXIT
  kc wait --for=condition=Ready pod/minio-client --timeout=120s >/dev/null
}
mc_script='MC_HOST_s3="http://$MINIO_USER:$MINIO_PASSWORD@minio:9000" exec mc "$@"'
mc() { kc exec minio-client -- sh -c "$mc_script" mc "$@"; }
mc_stdin() { kc exec -i minio-client -- sh -c "$mc_script" mc "$@"; }

case "${1:-}" in
  backup)
    dir=backups/$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$dir/minio"
    mongo mongodump "--db thumbnails" < /dev/null > "$dir/mongodb.archive.gz"
    start_minio_client
    # The MinIO image has no tar, so objects are copied one by one.
    mc ls --recursive s3/thumbnails | awk '{print $NF}' > "$dir/minio/objects.txt"
    while read -r key; do
      mc cat "s3/thumbnails/$key" > "$dir/minio/$key"
    done < "$dir/minio/objects.txt"
    echo "backup in $dir: MongoDB $(du -h "$dir/mongodb.archive.gz" | cut -f1), $(wc -l < "$dir/minio/objects.txt" | tr -d ' ') objects"
    ;;
  restore)
    dir=${2:?usage: data.sh restore backups/<timestamp>}
    mongo mongorestore "--drop" < "$dir/mongodb.archive.gz"
    start_minio_client
    mc mb --ignore-existing s3/thumbnails > /dev/null
    # Objects are at most 10 MiB (the gateway's upload cap), so a 16 MiB part
    # size keeps each upload in one part and the buffer small.
    while read -r key; do
      mc_stdin pipe --part-size 16MiB "s3/thumbnails/$key" < "$dir/minio/$key" > /dev/null
    done < "$dir/minio/objects.txt"
    echo "restored $dir: MongoDB and $(wc -l < "$dir/minio/objects.txt" | tr -d ' ') objects"
    ;;
  *)
    echo "usage: data.sh backup | data.sh restore backups/<timestamp>" >&2
    exit 1
    ;;
esac
