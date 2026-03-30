# Hybrid-Node Makefile
# ============================================================================

IMAGE_NAME := ghcr.io/gvolcy/hybrid-node
NODE_VERSION := 10.1.4
TAG := $(NODE_VERSION)
PLATFORM := linux/amd64

.PHONY: help build build-multi push run-relay run-bp shell version clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the Docker image (amd64)
	docker build -f platform/docker/Dockerfile \
	--build-arg NODE_VERSION=$(NODE_VERSION) \
	-t $(IMAGE_NAME):$(TAG) \
	-t $(IMAGE_NAME):latest \
	.

build-multi: ## Build multi-arch image (amd64 + arm64)
	docker buildx build -f platform/docker/Dockerfile \
	--platform linux/amd64,linux/arm64 \
	--build-arg NODE_VERSION=$(NODE_VERSION) \
	-t $(IMAGE_NAME):$(TAG) \
	-t $(IMAGE_NAME):latest \
	.

push: ## Push image to GHCR
	docker push $(IMAGE_NAME):$(TAG)
	docker push $(IMAGE_NAME):latest

run-relay: ## Run as relay (mainnet)
	docker run -d \
	--name hybrid-relay \
	-e NETWORK=mainnet \
	-e NODE_MODE=relay \
	-e NODE_PORT=3001 \
	-v hybrid-relay-db:/opt/cardano/cnode/db \
	-p 3001:3001 \
	-p 12798:12798 \
	$(IMAGE_NAME):$(TAG)

run-bp: ## Run as block producer (mainnet)
	docker run -d \
	--name hybrid-bp \
	-e NETWORK=mainnet \
	-e NODE_MODE=bp \
	-e NODE_PORT=6000 \
	-v hybrid-bp-db:/opt/cardano/cnode/db \
	-v hybrid-bp-keys:/opt/cardano/cnode/priv \
	-p 6000:6000 \
	$(IMAGE_NAME):$(TAG)

shell: ## Open a shell in the container
	docker run --rm -it \
	-e NETWORK=mainnet \
	$(IMAGE_NAME):$(TAG) bash

version: ## Show version info
	docker run --rm $(IMAGE_NAME):$(TAG) version

clean: ## Remove containers and volumes
	docker rm -f hybrid-relay hybrid-bp 2>/dev/null || true
	docker volume rm hybrid-relay-db hybrid-bp-db hybrid-bp-keys 2>/dev/null || true
	@echo "Cleaned up containers and volumes"

helm-relay: ## Deploy relay via Helm
	helm install cardano-relay ./charts/hybrid-node \
	--set cardano.mode=relay \
	--set cardano.network=mainnet \
	--set cardano.port=3001

helm-bp: ## Deploy BP via Helm
	helm install cardano-bp ./charts/hybrid-node \
	--set cardano.mode=bp \
	--set cardano.network=mainnet
