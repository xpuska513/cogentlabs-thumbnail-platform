#!/usr/bin/env sh
# Generates random credentials on first install and stores them only in the
# cluster. Existing secrets are left alone, so re-running `make up` is safe.
set -eu

CONTEXT=${CONTEXT:-kind-thumbnail}
kc() { kubectl --context "$CONTEXT" "$@"; }
rand() { openssl rand -hex 16; }

if ! kc get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  kc create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(rand)"
fi

if ! kc get secret thumbnail-credentials -n thumbnail >/dev/null 2>&1; then
  mongo_root=$(rand)
  mongo_app=$(rand)
  mongo_exporter=$(rand)
  minio_root=$(rand)
  kc create secret generic thumbnail-credentials -n thumbnail \
    --from-literal=mongo-root-password="$mongo_root" \
    --from-literal=mongo-app-password="$mongo_app" \
    --from-literal=mongo-exporter-password="$mongo_exporter" \
    --from-literal=mongo-url="mongodb://thumbnail:$mongo_app@mongodb:27017/thumbnails?authSource=thumbnails" \
    --from-literal=mongo-exporter-uri="mongodb://exporter:$mongo_exporter@mongodb:27017/admin" \
    --from-literal=minio-root-user=minio-admin \
    --from-literal=minio-root-password="$minio_root"
fi

echo "credentials ready"
