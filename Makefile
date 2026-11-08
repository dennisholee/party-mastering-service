SHELL := /bin/bash

CONTROLS_CORE ?= ../controls-core
export CONTROLS_CORE
SERVICE ?= party-mastering

GO ?= go
GOCACHE ?= $(abspath $(CONTROLS_CORE)/.gocache)
GOPATH ?= $(abspath $(CONTROLS_CORE)/.gopath)
export GOCACHE
export GOPATH
GOARCH ?= $(shell go env GOARCH)

MVN ?= mvn
MVN_ARGS ?=
DOCKER_BUILDKIT ?= 0

TMP := $(CURDIR)/.tmp
SIGNED_DIR := $(TMP)/signed
SIDECAR_IMAGE ?= party-mastering-sidecar:dev
APP_IMAGE ?= party-mastering-app:dev
PIP_IMAGE ?= party-mastering-pip:dev
STUB_IMAGE ?= party-mastering-stubpip:dev

# Local-only gateway key for signed mode. Production takes this from the
# gateway secret store, never from a Makefile.
IDENTITY_KEY ?= party-mastering-local-identity-key-change-me

.PHONY: registry schema gate images up signed test test-signed stub lag test-lag lag-fixture test-lag-fixture down logs logs-signed logs-lag logs-lag-fixture

## Regenerate the committed controls/registry.json from openapi.yaml.
registry:
	cd $(CONTROLS_CORE) && $(GO) run ./tools/openapi-registry \
		-openapi ../party-mastering-service/openapi.yaml \
		-service $(SERVICE) \
		-out ../party-mastering-service/controls/registry.json

## Validate the control fixtures against controls-core/contracts.
schema:
	$(MVN) $(MVN_ARGS) -q -Dtest=ControlsSchemaTest test

## Build-time gates: Java tests + registry drift + OpenAPI coverage + bundle checks.
## Requires a sibling controls-core checkout (or CONTROLS_CORE=...).
gate:
	$(MVN) $(MVN_ARGS) -q test
	cd $(CONTROLS_CORE) && $(GO) run ./tools/openapi-registry -check \
		-openapi ../party-mastering-service/openapi.yaml \
		-service $(SERVICE) \
		-out ../party-mastering-service/controls/registry.json
	cd $(CONTROLS_CORE) && $(GO) run ./tools/openapi-diff \
		-openapi ../party-mastering-service/openapi.yaml \
		-registry ../party-mastering-service/controls/registry.json
	cd $(CONTROLS_CORE) && $(GO) run ./tools/controls-check \
		-openapi ../party-mastering-service/openapi.yaml \
		-bundle ../party-mastering-service/controls \
		-pip-fixture ../party-mastering-service/pip/attributes.json

## Build the app, PIP and Envoy/ext_proc images.
images:
	mkdir -p $(TMP)
	cd $(CONTROLS_CORE) && CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o $(TMP)/extproc ./sidecar/cmd/extproc
	cd $(CONTROLS_CORE) && CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o $(TMP)/pip ./pip/cmd/pip
	$(MVN) $(MVN_ARGS) -q -DskipTests package
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build --build-arg EXTPROC_BIN=.tmp/extproc \
		-f sidecar/Dockerfile -t $(SIDECAR_IMAGE) .
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build -f Dockerfile -t $(APP_IMAGE) .
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build --build-arg PIP_BIN=.tmp/pip \
		-f pip/Dockerfile -t $(PIP_IMAGE) .

## Development stack: raw gateway-stand-in headers, unsigned local bundle.
up: images
	CONTROLS_SIDECAR_IMAGE=$(SIDECAR_IMAGE) docker compose up -d

## Signed stack: render + Ed25519-sign a bundle, then require HMAC identity.
signed: images
	rm -rf $(SIGNED_DIR)
	mkdir -p $(SIGNED_DIR)/src/policies $(SIGNED_DIR)/src/mask-policies \
		$(SIGNED_DIR)/src/registry $(SIGNED_DIR)/src/dq
	cp controls/rules.json $(SIGNED_DIR)/src/policies/rules.json
	cp controls/mask-policies.json $(SIGNED_DIR)/src/mask-policies/mask-policies.json
	cp controls/registry.json $(SIGNED_DIR)/src/registry/party-mastering.json
	cp controls/dq.json $(SIGNED_DIR)/src/dq/dq.json
	cd $(CONTROLS_CORE) && $(GO) run ./tools/bundle \
		-src $(SIGNED_DIR)/src \
		-service $(SERVICE) \
		-out $(SIGNED_DIR)/bundle
	cd $(CONTROLS_CORE) && $(GO) run ./tools/bundle-keygen \
		-out $(SIGNED_DIR)/keys
	cd $(CONTROLS_CORE) && $(GO) run ./tools/bundle-sign \
		-bundle $(SIGNED_DIR)/bundle \
		-key $(SIGNED_DIR)/keys/bundle-signing.pem
	cd $(CONTROLS_CORE) && $(GO) run ./tools/bundle-sign \
		-bundle $(SIGNED_DIR)/bundle \
		-verify \
		-pubkey $(SIGNED_DIR)/keys/bundle-signing.pub.pem
	CONTROLS_IDENTITY_HMAC_KEY=$(IDENTITY_KEY) docker compose -f compose.signed.yaml up -d

## One-shot: gates, images, compose, development contract tests, teardown.
test: gate up
	./test.sh

## Build the local PIP contract stub used for the replica-lag matrix.
stub:
	mkdir -p $(TMP)
	cd tools/stubpip && CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) $(GO) build -o $(TMP)/stubpip .
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build --build-arg STUB_BIN=.tmp/stubpip \
		-f pip/Dockerfile.stub -t $(STUB_IMAGE) .

## Replica-lag stack: fresh GET with a stub PIP whose lag is state-file driven.
lag: images stub
	mkdir -p $(TMP)
	printf '{"lagSeconds":2,"lagKnown":true}\n' > $(TMP)/lag-state.json
	CONTROLS_SIDECAR_IMAGE=$(SIDECAR_IMAGE) docker compose -f compose.lag.yaml up -d

## One-shot: gates, stub PIP, replica-lag failure matrix, teardown.
test-lag: gate lag
	./test-lag.sh

## Static lag matrix through the reference PIP and fixture resourceMeta.
lag-fixture: images
	CONTROLS_SIDECAR_IMAGE=$(SIDECAR_IMAGE) docker compose -f compose.lag-fixture.yaml up -d

test-lag-fixture: gate lag-fixture
	./test-lag-fixture.sh

## One-shot: gates, signed bundle, signed identity, contract tests, teardown.
test-signed: gate signed
	CONTROLS_IDENTITY_HMAC_KEY=$(IDENTITY_KEY) ./test-signed.sh

down:
	docker compose down -v
	CONTROLS_IDENTITY_HMAC_KEY=$(IDENTITY_KEY) docker compose -f compose.signed.yaml down -v
	docker compose -f compose.lag.yaml down -v
	docker compose -f compose.lag-fixture.yaml down -v

logs:
	docker compose logs -f

logs-signed:
	CONTROLS_IDENTITY_HMAC_KEY=$(IDENTITY_KEY) docker compose -f compose.signed.yaml logs -f

logs-lag:
	docker compose -f compose.lag.yaml logs -f

logs-lag-fixture:
	docker compose -f compose.lag-fixture.yaml logs -f
