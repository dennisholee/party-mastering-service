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
SIDECAR_IMAGE ?= party-mastering-sidecar:dev
APP_IMAGE ?= party-mastering-app:dev
PIP_IMAGE ?= party-mastering-pip:dev

.PHONY: registry schema gate test up down logs

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
		-openapi ../party-mastering-service/target/controlled-openapi.yaml \
		-registry ../party-mastering-service/controls/registry.json
	cd $(CONTROLS_CORE) && $(GO) run ./tools/controls-check \
		-openapi ../party-mastering-service/openapi.yaml \
		-bundle ../party-mastering-service/controls \
		-pip-fixture ../party-mastering-service/pip/attributes.json

## Build the local images and start app + PIP + Envoy/ext_proc.
up:
	mkdir -p $(TMP)
	cd $(CONTROLS_CORE) && CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o $(TMP)/extproc ./sidecar/cmd/extproc
	cd $(CONTROLS_CORE) && CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) go build -o $(TMP)/pip ./pip/cmd/pip
	$(MVN) $(MVN_ARGS) -q -DskipTests package
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build --build-arg EXTPROC_BIN=.tmp/extproc \
		-f sidecar/Dockerfile -t $(SIDECAR_IMAGE) .
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build -f Dockerfile -t $(APP_IMAGE) .
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build --build-arg PIP_BIN=.tmp/pip \
		-f pip/Dockerfile -t $(PIP_IMAGE) .
	CONTROLS_SIDECAR_IMAGE=$(SIDECAR_IMAGE) docker compose up -d

## One-shot: gates, images, compose, contract tests, teardown.
test: gate up
	./test.sh

down:
	docker compose down -v

logs:
	docker compose logs -f
