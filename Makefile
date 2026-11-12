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
# The git tree hash of app/: the tag (and the pods) only change when the app does.
TAG ?= $(shell git rev-parse --short HEAD:app 2>/dev/null || echo dev)$(shell git diff --quiet HEAD -- app 2>/dev/null || echo -dirty)
# Roll back by itself if an upgrade fails. Helm 4 renamed --atomic and applies
# server-side; it creates objects that an upgrade adds with a plain update, so
# the next upgrade conflicts with Helm's own earlier write. Helm owns these
# objects, so it may force.
HELM_UPGRADE_FLAGS := --wait $(shell helm version --short 2>/dev/null | grep -q '^v3' && echo --atomic || echo --rollback-on-failure --force-conflicts)

.DEFAULT_GOAL := help
.PHONY: help up cluster platform namespaces monitoring tracing gateway deps build deploy rollback test down

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

up: cluster platform deps deploy test ## Create everything from scratch (safe to re-run)

cluster: ## Create the kind cluster (skipped if it exists)
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config cluster/kind.yaml
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s

platform: namespaces monitoring tracing gateway ## Install monitoring, tracing and the gateway

namespaces: ## Create namespaces and generate credentials (only once)
	$(KUBECTL) apply -f deploy/manifests/namespaces.yaml
	CONTEXT=kind-$(CLUSTER) scripts/create-secrets.sh

monitoring: ## Prometheus, Alertmanager and Grafana
	helm template prometheus-operator-crds oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds \
	  --version $(PROMETHEUS_OPERATOR_CRDS_VERSION) | $(KUBECTL) apply --server-side --force-conflicts -f - >/dev/null
	$(HELM) upgrade --install kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
	  --version $(KUBE_PROMETHEUS_STACK_VERSION) -n monitoring -f deploy/values/kube-prometheus-stack.yaml \
	  $(HELM_UPGRADE_FLAGS) --timeout 10m

tracing: ## Jaeger, in memory
	$(KUBECTL) apply -f deploy/manifests/jaeger.yaml
	$(KUBECTL) rollout status deployment/jaeger -n monitoring --timeout=120s

gateway: ## Envoy Gateway and the shared public Gateway
	helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version $(ENVOY_GATEWAY_VERSION) \
	  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=true \
	  | $(KUBECTL) apply --server-side --force-conflicts -f - >/dev/null
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $(ENVOY_GATEWAY_VERSION) \
	  -n envoy-gateway-system --create-namespace -f deploy/values/envoy-gateway.yaml $(HELM_UPGRADE_FLAGS) --timeout 5m
	$(KUBECTL) apply -f deploy/manifests/gateway.yaml
	$(KUBECTL) wait --for=condition=Programmed gateway/public -n envoy-gateway-system --timeout=180s

deps: ## MongoDB and MinIO (dev stand-ins for managed services), Mongo exporter
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

rollback: ## Roll the app back to its previous release
	$(HELM) rollback thumbnail -n $(NAMESPACE) --wait

test: ## Smoke test through the gateway: upload, wait, download, check
	scripts/smoke-test.sh http://localhost:8080

down: ## Delete the cluster and everything in it
	kind delete cluster --name $(CLUSTER)
