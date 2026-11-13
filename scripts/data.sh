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
BUSYBOX_IMAGE=busybox:1.37.0
BUCKET=thumbnails
CLIENT=minio-client-$$
kc() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

# mongodump and mongorestore run inside the MongoDB pod, as the app's own user.
mongo() {
  kc exec -i mongodb-0 -- sh -c "$1 --quiet --archive --gzip \
    --uri \"mongodb://thumbnail:\$MONGO_APP_PASSWORD@localhost:27017/?authSource=thumbnails\" $2"
}

# The bucket moves as one tar stream through a throwaway pod: busybox for tar,
# plus mc copied in from the MinIO image, which has no tar. The pod has its own
# memory limit; a first version ran mc inside the MinIO container, and
# `mc pipe`'s 528 MiB upload buffer got the server OOM-killed.
start_minio_client() {
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  initContainers:
    - name: copy-mc
      image: $MINIO_IMAGE
      command: ["cp", "/usr/bin/mcli", "/tools/mc"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      volumeMounts: [{ name: tools, mountPath: /tools }]
  containers:
    - name: client
      image: $BUSYBOX_IMAGE
      command: ["sleep", "3600"]
      env:
        - { name: PATH, value: "/tools:/bin" }
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
      volumeMounts:
        - { name: tools, mountPath: /tools }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - { name: tools, emptyDir: {} }
    - { name: tmp, emptyDir: {} }
EOF
  trap 'kc delete pod "$CLIENT" --wait=false >/dev/null 2>&1' EXIT
  kc wait --for=condition=Ready "pod/$CLIENT" --timeout=120s >/dev/null
}
# Runs a shell command in the client pod, with mc's alias s3 pointing at MinIO.
# A failure anywhere fails the script: kubectl exec returns the command's status.
in_client() {
  kc exec -i "$CLIENT" -c client -- sh -c "export MC_HOST_s3=\"http://\$MINIO_USER:\$MINIO_PASSWORD@minio:9000\" && $1"
}
objects() { tar -tf "$1" | grep -vc '/$' || true; }

case "${1:-}" in
  backup)
    dir=backups/$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$dir"
    mongo mongodump "--db thumbnails" < /dev/null > "$dir/mongodb.archive.gz"
    start_minio_client
    in_client "mkdir -p /tmp/$BUCKET && mc mirror --quiet s3/$BUCKET /tmp/$BUCKET >/dev/null && tar -C /tmp -cf - $BUCKET" \
      < /dev/null > "$dir/minio.tar"
    echo "backup in $dir: MongoDB $(du -h "$dir/mongodb.archive.gz" | cut -f1), $(objects "$dir/minio.tar") objects"
    ;;
  restore)
    dir=${2:?usage: data.sh restore backups/<timestamp>}
    [ -f "$dir/mongodb.archive.gz" ] && [ -f "$dir/minio.tar" ] || { echo "$dir is not a complete backup" >&2; exit 1; }
    mongo mongorestore "--drop" < "$dir/mongodb.archive.gz"
    start_minio_client
    in_client "tar -C /tmp -xf - && mc mb --ignore-existing s3/$BUCKET >/dev/null \
      && mc mirror --quiet --overwrite /tmp/$BUCKET s3/$BUCKET >/dev/null" < "$dir/minio.tar"
    echo "restored $dir: MongoDB and $(objects "$dir/minio.tar") objects"
    ;;
  *)
    echo "usage: data.sh backup | data.sh restore backups/<timestamp>" >&2
    exit 1
    ;;
esac
