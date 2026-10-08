# Build the WAF container images from this super-repo.
# The build context is always the repo root, the Containerfiles reference
# sources through their submodule directory prefix.

SHELL := /bin/bash

CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

REGISTRY ?= quay.io/redhat-user-workloads
OPERATOR_IMAGE ?= $(REGISTRY)/waf-operator
PROXY_WASM_IMAGE ?= $(REGISTRY)/coraza-proxy-wasm

# Version and provenance, derived per submodule
OPERATOR_DIR := coraza-kubernetes-operator
PROXY_WASM_DIR := coraza-proxy-wasm

CORAZA_KUBERNETES_OPERATOR_VERSION ?= $(shell git -C $(OPERATOR_DIR) describe --tags --always --dirty 2>/dev/null || echo unknown)
CORAZA_PROXY_WASM_VERSION ?= $(shell git -C $(PROXY_WASM_DIR) describe --tags --always --dirty 2>/dev/null || echo unknown)

OPERATOR_GIT_SHA ?= $(shell git -C $(OPERATOR_DIR) rev-parse HEAD 2>/dev/null || echo unknown)
PROXY_WASM_GIT_SHA ?= $(shell git -C $(PROXY_WASM_DIR) rev-parse HEAD 2>/dev/null || echo unknown)

OPERATOR_DIRTY ?= $(shell test -z "$$(git -C $(OPERATOR_DIR) status --porcelain 2>/dev/null)" && echo false || echo true)
PROXY_WASM_DIRTY ?= $(shell test -z "$$(git -C $(PROXY_WASM_DIR) status --porcelain 2>/dev/null)" && echo false || echo true)

OPERATOR_TAG ?= $(CORAZA_KUBERNETES_OPERATOR_VERSION)
PROXY_WASM_TAG ?= $(CORAZA_PROXY_WASM_VERSION)

# Target architecture of the produced images
TARGETARCH ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

# Plugin build tuning, see coraza-proxy-wasm/magefiles/magefile.go
MULTIPHASE_EVAL ?= true
INITIAL_PAGES ?= 2100

# Extra flags passed to the engine, for example --no-cache or
# --build-arg TINYGO_LOCAL_DIR=/cachi2/output/deps/generic
BUILD_ARGS ?=

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: check-engine
check-engine:
	@test -n "$(CONTAINER_ENGINE)" || { echo "No podman or docker found, set CONTAINER_ENGINE"; exit 1; }

.PHONY: submodules
submodules: ## Initialize and update the git submodules
	git submodule update --init --recursive

.PHONY: build
build: build-operator build-proxy-wasm ## Build all images

.PHONY: build-operator
build-operator: check-engine ## Build the operator image
	$(CONTAINER_ENGINE) build \
		-f Containerfile.waf-operator \
		-t $(OPERATOR_IMAGE):$(OPERATOR_TAG) \
		--build-arg TARGETARCH=$(TARGETARCH) \
		--build-arg GIT_SHA=$(OPERATOR_GIT_SHA) \
		--build-arg DIRTY=$(OPERATOR_DIRTY) \
		--build-arg CORAZA_KUBERNETES_OPERATOR_VERSION=$(CORAZA_KUBERNETES_OPERATOR_VERSION) \
		$(BUILD_ARGS) \
		.

.PHONY: build-proxy-wasm
build-proxy-wasm: check-engine ## Build the proxy-wasm plugin image
	$(CONTAINER_ENGINE) build \
		-f Containerfile.proxy-wasm \
		-t $(PROXY_WASM_IMAGE):$(PROXY_WASM_TAG) \
		--build-arg TARGETARCH=$(TARGETARCH) \
		--build-arg GIT_SHA=$(PROXY_WASM_GIT_SHA) \
		--build-arg DIRTY=$(PROXY_WASM_DIRTY) \
		--build-arg CORAZA_PROXY_WASM_VERSION=$(CORAZA_PROXY_WASM_VERSION) \
		--build-arg MULTIPHASE_EVAL=$(MULTIPHASE_EVAL) \
		--build-arg INITIAL_PAGES=$(INITIAL_PAGES) \
		$(BUILD_ARGS) \
		.

.PHONY: push
push: push-operator push-proxy-wasm ## Push all images

.PHONY: push-operator
push-operator: check-engine ## Push the operator image
	$(CONTAINER_ENGINE) push $(OPERATOR_IMAGE):$(OPERATOR_TAG)

.PHONY: push-proxy-wasm
push-proxy-wasm: check-engine ## Push the proxy-wasm plugin image
	$(CONTAINER_ENGINE) push $(PROXY_WASM_IMAGE):$(PROXY_WASM_TAG)

.PHONY: extract-wasm
extract-wasm: check-engine ## Copy plugin.wasm out of the built image into build/
	mkdir -p build
	id=$$($(CONTAINER_ENGINE) create $(PROXY_WASM_IMAGE):$(PROXY_WASM_TAG)) ;\
	$(CONTAINER_ENGINE) cp $$id:/plugin.wasm build/plugin.wasm ;\
	$(CONTAINER_ENGINE) rm $$id
	@ls -lh build/plugin.wasm

.PHONY: vars
vars: ## Print the resolved build variables
	@echo "CONTAINER_ENGINE   = $(CONTAINER_ENGINE)"
	@echo "TARGETARCH         = $(TARGETARCH)"
	@echo "operator image     = $(OPERATOR_IMAGE):$(OPERATOR_TAG)"
	@echo "operator sha/dirty = $(OPERATOR_GIT_SHA) / $(OPERATOR_DIRTY)"
	@echo "proxy-wasm image   = $(PROXY_WASM_IMAGE):$(PROXY_WASM_TAG)"
	@echo "proxy-wasm sha/dty = $(PROXY_WASM_GIT_SHA) / $(PROXY_WASM_DIRTY)"

.PHONY: clean
clean: ## Remove locally built images and extracted artifacts
	-$(CONTAINER_ENGINE) rmi $(OPERATOR_IMAGE):$(OPERATOR_TAG) $(PROXY_WASM_IMAGE):$(PROXY_WASM_TAG)
	rm -rf build
