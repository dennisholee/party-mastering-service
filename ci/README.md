# CI setup

The workflow is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

## Why two checkouts

The service consumes the sidecar tools (`openapi-registry`, `openapi-diff`,
`controls-check`) and the normative schemas from a sibling `controls-core`
checkout. That mirrors the local layout:

```text
workspace/
  controls-core/
  party-mastering-service/
```

The service repository itself does not vendor sidecar code.

## Required repository configuration

Set this **Actions repository variable** on the service repository:

| Name | Example | Purpose |
|---|---|---|
| `CONTROLS_CORE_REPOSITORY` | `my-org/controls-core` | Repository checked out as the sibling |

If `controls-core` is private, add a **secret** with read access:

| Name | Purpose |
|---|---|
| `CONTROLS_CORE_TOKEN` | Token used for the `controls-core` checkout |

The workflow falls back to `github.token` when the secret is absent. That works
when both repositories are public or when the workflow token can read the
controls repository.

## Jobs

| Job | Trigger | What it runs |
|---|---|---|
| `gate` | push, pull request, manual | `make gate`: docs coverage, EOL policy, entrypoint drift, Java tests, generated-code drift, registry schema validation, OpenAPI coverage, bundle checks and conformance fixtures |
| `e2e` | push to `main`, manual | `make test` (development headers), `make test-signed` (signed bundle + HMAC identity), `make test-lag` (stub-PIP lag matrix) and `make test-lag-fixture` (reference-PIP fixture lag matrix): builds images, runs all four suites through Envoy + ext_proc, tears down |

The end-to-end job is intentionally not run on every pull request: it builds
three images and exercises a real Envoy listener. Run it manually with
`workflow_dispatch` for a change that touches the runtime or bundle.

## Local equivalents

```bash
# from party-mastering-service, with ../controls-core present
make gate
make test
make test-signed
make test-lag
make test-lag-fixture

# validate only the contract schemas
make schema
```

`make gate` exports `CONTROLS_CORE`, which is how `ControlsSchemaTest` finds
`contracts/registry.schema.json` and `contracts/mask-policy.schema.json`. A
plain `mvn verify` without the sibling checkout skips those two tests rather
than failing.
