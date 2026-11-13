# One entry point for the whole lifecycle. `make help` lists the targets.

CLUSTER   ?= thumbnail
NAMESPACE ?= thumbnail

# Every command targets the kind cluster explicitly, never the current context.
KUBECTL := kubectl --context kind-$(CLUSTER)
HELM    := helm --kube-context kind-$(CLUSTER)

# Pinned versions. Each was at least two weeks old when pinned.
ENVOY_GATEWAY_VERSION         := v1.9.3
KUBE_PROMETHEUS_STACK_VERSION := 92.14.1
# Must match the operator version inside kube-prometheus-stack (v0.94.2).
PROMETHEUS_OPERATOR_CRDS_VERSION := 32.0.2
MONGODB_EXPORTER_VERSION := 3.23.0

IMAGE := thumbnail-generator
# The git tree hash of app/ as it is on disk, uncommitted and new files included
# (hashed through a scratch copy of the index): the tag, and so the pods, change
# exactly when the app does. "dev" outside a git checkout.
TAG ?= $(or $(shell i=$$(mktemp) && cp "$$(git rev-parse --git-path index 2>/dev/null)" "$$i" 2>/dev/null \
  && GIT_INDEX_FILE="$$i" git add -A app 2>/dev/null && GIT_INDEX_FILE="$$i" git write-tree --prefix=app/ | cut -c1-7; \
  rm -f "$$i"),dev)
# Roll back by itself if an upgrade fails. Helm 4 renamed --atomic and applies
# server-side; it creates objects that an upgrade adds with a plain update, so
# the next upgrade (or rollback) conflicts with Helm's own earlier write. Helm
# owns these objects, so it may force. Server-side is set explicitly: Helm 4
# otherwise keeps the method a release was installed with, and on a release
# Helm 3 installed it then rejects --force-conflicts.
HELM3 := $(shell helm version --short 2>/dev/null | grep -q '^v3' && echo yes)
HELM_UPGRADE_FLAGS := --wait $(if $(HELM3),--atomic,--rollback-on-failure --server-side=true --force-conflicts)
HELM_ROLLBACK_FLAGS := --wait $(if $(HELM3),,--server-side=true --force-conflicts)

.DEFAULT_GOAL := help
.PHONY: help up cluster platform namespaces crds monitoring tracing gateway deps build deploy rollback test backup restore \
	status alerts grafana prometheus alertmanager jaeger down

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

up: cluster platform deps deploy test ## Create everything from scratch (safe to re-run)

# Linux's default of 128 inotify instances per user runs out once this stack is up
# (Docker Desktop allows 8192). containerd then can't watch new containers for OOM
# kills: they show as exit 137 and the OOM alert never fires. The limit is read on
# a node, so it's the kernel Docker actually runs on.
cluster: ## Create the kind cluster (skipped if it exists)
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config cluster/kind.yaml
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s
	@n=$$(docker exec $(CLUSTER)-control-plane cat /proc/sys/fs/inotify/max_user_instances); [ "$$n" -ge 512 ] || { \
	  echo "fs.inotify.max_user_instances is $$n; this cluster needs 512. Raise it, then run make up again:" >&2; \
	  echo "  sudo sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288" >&2; exit 1; }

platform: namespaces crds monitoring tracing gateway ## Install monitoring, tracing and the gateway

namespaces: ## Create namespaces and generate credentials (only once)
	$(KUBECTL) apply -f deploy/manifests/namespaces.yaml
	CONTEXT=kind-$(CLUSTER) scripts/create-secrets.sh

# All CRDs first, so no component depends on another one's install order.
# Applied server-side because Helm never upgrades CRDs itself.
crds: ## CRDs for the Prometheus operator, the Gateway API and Envoy Gateway
	helm template prometheus-operator-crds oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds \
	  --version $(PROMETHEUS_OPERATOR_CRDS_VERSION) | $(KUBECTL) apply --server-side --force-conflicts -f - >/dev/null
	helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version $(ENVOY_GATEWAY_VERSION) \
	  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=true \
	  | $(KUBECTL) apply --server-side --force-conflicts -f - >/dev/null

monitoring: namespaces crds ## Prometheus, Alertmanager and Grafana
	$(HELM) upgrade --install kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
	  --version $(KUBE_PROMETHEUS_STACK_VERSION) -n monitoring -f deploy/values/kube-prometheus-stack.yaml \
	  $(HELM_UPGRADE_FLAGS) --timeout 10m

tracing: namespaces crds ## Jaeger, in memory
	$(KUBECTL) apply -f deploy/manifests/jaeger.yaml
	$(KUBECTL) rollout status deployment/jaeger -n monitoring --timeout=120s

gateway: crds ## Envoy Gateway and the shared public Gateway
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $(ENVOY_GATEWAY_VERSION) \
	  -n envoy-gateway-system --create-namespace -f deploy/values/envoy-gateway.yaml $(HELM_UPGRADE_FLAGS) --timeout 5m
	$(KUBECTL) apply -f deploy/manifests/gateway.yaml
	$(KUBECTL) wait --for=condition=Programmed gateway/public -n envoy-gateway-system --timeout=180s

deps: namespaces crds ## MongoDB and MinIO (dev stand-ins for managed services), Mongo exporter
	$(KUBECTL) apply -f deploy/manifests/mongodb.yaml -f deploy/manifests/minio.yaml
	$(KUBECTL) rollout status statefulset/mongodb -n $(NAMESPACE) --timeout=180s
	$(KUBECTL) rollout status statefulset/minio -n $(NAMESPACE) --timeout=180s
	$(HELM) upgrade --install mongodb-exporter oci://ghcr.io/prometheus-community/charts/prometheus-mongodb-exporter \
	  --version $(MONGODB_EXPORTER_VERSION) -n $(NAMESPACE) -f deploy/values/mongodb-exporter.yaml $(HELM_UPGRADE_FLAGS) --timeout 3m

build: ## Build the app image and load it into kind
	docker build -t $(IMAGE):$(TAG) app
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)

deploy: build ## Install or update the app (rolls back by itself if the rollout fails)
	$(HELM) upgrade --install thumbnail charts/thumbnail -n $(NAMESPACE) \
	  --set image.repository=$(IMAGE) --set image.tag=$(TAG) $(HELM_UPGRADE_FLAGS) --timeout 5m

# Plain `helm rollback` goes to the previous revision, which after a failed
# deploy (already rolled back by itself) is the failed one. Default to the
# newest earlier revision that went out fine: superseded, and not "... failed"
# (Helm marks a failed upgrade superseded too once it has rolled it back).
# REVISION=<n> from `helm history` overrides.
REVISION ?= $(shell $(HELM) history thumbnail -n $(NAMESPACE) -o yaml 2>/dev/null | awk '/^- /{r=""; bad=0} \
  /^  description:/{bad=/failed/} /^  revision:/{r=$$2} /^  status: superseded/{if (r != "" && !bad) last=r} END{print last}')
rollback: ## Roll the app back to the last good release before this one (or REVISION=<n>)
	@[ -n "$(REVISION)" ] || { echo "no earlier release to roll back to" >&2; exit 1; }
	$(HELM) rollback thumbnail $(REVISION) -n $(NAMESPACE) $(HELM_ROLLBACK_FLAGS) --timeout 5m

test: ## Smoke test through the gateway: upload, wait, download, check
	scripts/smoke-test.sh http://localhost:8080

backup: ## Back up MongoDB and the MinIO bucket to backups/<timestamp>/
	CONTEXT=kind-$(CLUSTER) NAMESPACE=$(NAMESPACE) scripts/data.sh backup

restore: ## Restore a backup: make restore BACKUP=backups/<timestamp>
	@test -n "$(BACKUP)" || { echo "usage: make restore BACKUP=backups/<timestamp>"; exit 1; }
	CONTEXT=kind-$(CLUSTER) NAMESPACE=$(NAMESPACE) scripts/data.sh restore $(BACKUP)

status: ## Show the app's pods and every Helm release
	$(KUBECTL) get pods -n $(NAMESPACE) -o wide
	@$(HELM) list -A

alerts: ## List firing alerts
	@$(KUBECTL) exec -n monitoring prometheus-kps-prometheus-0 -c prometheus -- \
	  promtool query instant http://localhost:9090 'sort_desc(ALERTS{alertstate="firing"})' \
	  | sed -E 's/^ALERTS\{(.*)\} => .*/\1/; s/alertstate="firing",? ?//'

grafana: ## Grafana on http://localhost:3000 (prints the admin password)
	@echo "user admin, password $$($(KUBECTL) get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 --decode)"
	@echo "dashboard: http://localhost:3000/d/thumbnail"
	$(KUBECTL) port-forward -n monitoring svc/kps-grafana 3000:80

prometheus: ## Prometheus on http://localhost:9090
	$(KUBECTL) port-forward -n monitoring svc/kps-prometheus 9090:9090

alertmanager: ## Alertmanager on http://localhost:9093
	$(KUBECTL) port-forward -n monitoring svc/kps-alertmanager 9093:9093

jaeger: ## Jaeger on http://localhost:16686
	$(KUBECTL) port-forward -n monitoring svc/jaeger 16686:16686

down: ## Delete the cluster and everything in it
	kind delete cluster --name $(CLUSTER)
