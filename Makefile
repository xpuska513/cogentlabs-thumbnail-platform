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

.DEFAULT_GOAL := help
.PHONY: help cluster platform namespaces monitoring tracing gateway down

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

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
	  --wait --timeout 10m

tracing: ## Jaeger, in memory
	$(KUBECTL) apply -f deploy/manifests/jaeger.yaml
	$(KUBECTL) rollout status deployment/jaeger -n monitoring --timeout=120s

gateway: ## Envoy Gateway and the shared public Gateway
	helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version $(ENVOY_GATEWAY_VERSION) \
	  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=true \
	  | $(KUBECTL) apply --server-side --force-conflicts -f - >/dev/null
	$(HELM) upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $(ENVOY_GATEWAY_VERSION) \
	  -n envoy-gateway-system --create-namespace -f deploy/values/envoy-gateway.yaml --wait --timeout 5m
	$(KUBECTL) apply -f deploy/manifests/gateway.yaml
	$(KUBECTL) wait --for=condition=Programmed gateway/public -n envoy-gateway-system --timeout=180s

down: ## Delete the cluster and everything in it
	kind delete cluster --name $(CLUSTER)
