# One entry point for the whole lifecycle. `make help` lists the targets.

CLUSTER   ?= thumbnail
NAMESPACE ?= thumbnail

# Every command targets the kind cluster explicitly, never the current context.
KUBECTL := kubectl --context kind-$(CLUSTER)
HELM    := helm --kube-context kind-$(CLUSTER)

.DEFAULT_GOAL := help
.PHONY: help cluster down

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

cluster: ## Create the kind cluster (skipped if it exists)
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || kind create cluster --name $(CLUSTER) --config cluster/kind.yaml
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s

down: ## Delete the cluster and everything in it
	kind delete cluster --name $(CLUSTER)
