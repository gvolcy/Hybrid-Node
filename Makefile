# Hybrid-Node Makefile
# ============================================================================
# Multi-chain build system - Cardano, ApexFusion, Midnight
# Each chain has its own Dockerfile, version pins, and image tags
# ============================================================================

IMAGE_NAME := ghcr.io/gvolcy/hybrid-node
PLATFORM := linux/amd64

CHAIN ?= cardano

# ============================================================================
# Version defaults per chain
# ============================================================================
ifeq ($(CHAIN),cardano)
  NODE_VERSION ?= 10.7.0
  CLI_VERSION ?= 10.15.1.0
  DOCKERFILE := platform/docker/Dockerfile.cardano
  TAG := cardano-$(NODE_VERSION)
else ifeq ($(CHAIN),apexfusion)
  NODE_VERSION ?= 10.1.4
  CLI_VERSION ?= 9.4.1.0
  DOCKERFILE := platform/docker/Dockerfile.apexfusion
  TAG := apexfusion-$(NODE_VERSION)
else
  $(error Unknown CHAIN=$(CHAIN). Use: cardano, apexfusion)
endif

.PHONY: help build build-cardano build-apexfusion build-all push run-relay run-bp shell version versions clean clean-all lint lint-yaml lint-docker lint-all helm-relay helm-bp logs logs-bp status

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "%-22s %s\n", $$1, $$2}'

build: ## Build image for CHAIN (default: cardano)
	docker build -f $(DOCKERFILE) --build-arg NODE_VERSION=$(NODE_VERSION) --build-arg CLI_VERSION=$(CLI_VERSION) -t $(IMAGE_NAME):$(TAG) .

build-cardano: ## Build Cardano image (node 10.7.0)
	$(MAKE) build CHAIN=cardano

build-apexfusion: ## Build ApexFusion image (node 10.1.4)
	$(MAKE) build CHAIN=apexfusion

build-all: build-cardano build-apexfusion ## Build all chain images

push: ## Push CHAIN image to GHCR
	docker push $(IMAGE_NAME):$(TAG)

push-all: ## Push all chain images to GHCR
	docker push $(IMAGE_NAME):cardano-10.7.0
	docker push $(IMAGE_NAME):apexfusion-10.1.4

run-relay: ## Run as relay node for CHAIN
	docker run -d --name hybrid-$(CHAIN)-relay -e NETWORK=$(or $(NETWORK),mainnet) -e NODE_MODE=relay -e NODE_PORT=3001 -v hybrid-$(CHAIN)-relay-db:/opt/cardano/cnode/db -p 3001:3001 -p 12798:12798 $(IMAGE_NAME):$(TAG)

run-bp: ## Run as block producer for CHAIN
	docker run -d --name hybrid-$(CHAIN)-bp -e NETWORK=$(or $(NETWORK),mainnet) -e NODE_MODE=bp -e NODE_PORT=6000 -v hybrid-$(CHAIN)-bp-db:/opt/cardano/cnode/db -v hybrid-$(CHAIN)-bp-keys:/opt/cardano/cnode/priv -p 6000:6000 $(IMAGE_NAME):$(TAG)

shell: ## Open a shell in CHAIN container
	docker run --rm -it -e NETWORK=$(or $(NETWORK),mainnet) $(IMAGE_NAME):$(TAG) bash

version: ## Show version info for CHAIN image
	docker run --rm $(IMAGE_NAME):$(TAG) version

versions: ## Show pinned versions for all chains
	@echo "=== Cardano ===" && grep -E "^[A-Z]" chains/cardano/versions.env
	@echo "" && echo "=== ApexFusion ===" && grep -E "^[A-Z]" chains/apexfusion/versions.env
	@echo "" && echo "=== Midnight ===" && grep -E "^[A-Z]" chains/midnight/versions.env

clean: ## Remove containers and volumes for CHAIN
	docker rm -f hybrid-$(CHAIN)-relay hybrid-$(CHAIN)-bp 2>/dev/null || true
	docker volume rm hybrid-$(CHAIN)-relay-db hybrid-$(CHAIN)-bp-db hybrid-$(CHAIN)-bp-keys 2>/dev/null || true
	@echo "Cleaned up $(CHAIN) containers and volumes"

clean-all: ## Remove ALL chain containers and volumes
	$(MAKE) clean CHAIN=cardano
	$(MAKE) clean CHAIN=apexfusion

helm-relay: ## Deploy relay via Helm for CHAIN
	helm install $(CHAIN)-relay ./charts/hybrid-node --set image.tag=$(TAG) --set cardano.mode=relay --set cardano.network=$(or $(NETWORK),mainnet)

helm-bp: ## Deploy BP via Helm for CHAIN
	helm install $(CHAIN)-bp ./charts/hybrid-node --set image.tag=$(TAG) --set cardano.mode=bp --set cardano.network=$(or $(NETWORK),mainnet)

lint: ## Run ShellCheck on all shell scripts
	shellcheck -x -s bash bin/entrypoint.sh bin/healthcheck.sh
	@echo "ShellCheck passed"

lint-yaml: ## Lint YAML manifests
	find chains/ charts/ -name "*.yaml" -o -name "*.yml" | xargs yamllint -d relaxed
	@echo "YAML lint passed"

lint-docker: ## Lint all Dockerfiles with hadolint
	hadolint platform/docker/Dockerfile.cardano
	hadolint platform/docker/Dockerfile.apexfusion
	@echo "Dockerfile lint passed"

lint-all: lint lint-yaml lint-docker ## Run all linters

logs: ## Tail relay container logs for CHAIN
	docker logs -f hybrid-$(CHAIN)-relay 2>&1 | tail -100

logs-bp: ## Tail BP container logs for CHAIN
	docker logs -f hybrid-$(CHAIN)-bp 2>&1 | tail -100

status: ## Show running Hybrid-Node containers (all chains)
	@docker ps --filter name=hybrid- --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
