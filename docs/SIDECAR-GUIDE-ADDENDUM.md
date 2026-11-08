# Sidecar adoption guide — addendum and outstanding actions

Status: findings from implementing `party-mastering-service` against
`controls-core` **v0.38.3** and
[`SIDECAR-GUIDE.md`](../../controls-core/docs/SIDECAR-GUIDE.md) on 2026-11-08.

**Coverage note.** The guide's phase 5 (signed identity) and phase 7 (signed
bundle) are exercised in this repo by `make test-signed`; they are not gaps.
Only the findings below required workarounds or are deferred upstream.

**No `controls-core` code was changed for this repository.** Every item below
is either (a) a workaround contained in this repo, or (b) a deferred upstream
action. The purpose of this document is to make the next adoption cheaper and
to give the controls team a concrete, reproducible backlog.

## 1. Summary

| ID | Area | Severity | Finding |
|---|---|---|---|
| G1 | `openapi-diff` | High | `x-controls-ignore` is honoured by `openapi-registry` but not by `openapi-diff`; the guide's own gate fails on a deliberately excluded route |
| G2 | DQ engine | High | DQ is evaluated against every request body, so a `required` rule on a resource type with a `GET` denies the read |
| G3 | `controls-check` | High | DQ fields are validated against one request schema per resource type; two write journeys on one type fail against the wrong schema |
| G4 | DQ contract/gate | High | DQ array paths pass `controls-check` but the extension rejects them at runtime; the gate does not compile DQ rules |
| G5 | Masking gate | High | A mask-policy path that does not exist in the response schema is only a warning; the gate still exits 0 and PII may be returned unmasked |
| G6 | Mask validation | Medium | A bare `partial` (no keep parameters) is accepted, although the mask spec says it is a validation error |
| G7 | OpenAPI generator | Medium | `allowNonJSON` exists in the registry schema/runtime but has no OpenAPI extension, so it cannot be generated |
| G8 | Registry contract | Medium | SPEC/schema require kebab-case endpoint ids, the guide example is camelCase, and the generator copies `operationId` verbatim |
| G9 | `openapi-diff` | Medium | Annotation parity checks only four fields; action, attributes, freshness, self-description and mask-error bindings are not compared |
| G10 | PIP fixtures | Medium | The local PIP fixture cannot express per-resource lag, unknown lag or version, so the stale/unknown DQ-of-freshness tests cannot be run locally |
| D1–D5 | Guide text | Low | Command lines, `both` source semantics, DQ authoring, cached PIP outages and the drift-test template are underspecified |

How to read each finding:

- **Evidence** — what was observed or read in the reference implementation.
- **Impact** — why an adopting service should care.
- **Workaround here** — what this repo does instead.
- **Proposed upstream action** — the deferred change, with acceptance criteria.

## 2. Behaviour and contract gaps

### G1 — `openapi-diff` does not honour `x-controls-ignore` (High)

**Guide:** phase 1 table, line 88: `x-controls-ignore` "explicitly omit[s] a
route from the generated registry (it remains default-deny)".

**Evidence.** `openapi-registry` honours the flag
([`internal/openapiregistry/generate.go`](../../controls-core/internal/openapiregistry/generate.go)),
but `openapi-diff` iterates every documented operation and requires a registry
entry ([`internal/openapidiff/openapidiff.go`](../../controls-core/internal/openapidiff/openapidiff.go)).
Running the guide's gate on the raw contract fails:

```text
$ cd controls-core
$ go run ./tools/openapi-diff \
    -openapi ../party-mastering-service/openapi.yaml \
    -registry ../party-mastering-service/controls/registry.json
documented operations with no registry entry:
  - GET /parties
exit status 1
```

**Impact.** A service cannot follow the guide literally: either it omits the
ignored route from the contract (losing documentation) or it fails its own
coverage gate. Hand-editing an extra registry entry would defeat the
default-deny intent.

**Workaround here.** `IgnoreAwareSpecTest` writes an ignore-filtered copy of
the contract to `target/controlled-openapi.yaml`; the Makefile runs
`openapi-diff` against that copy and keeps the committed registry untouched.
See [`src/test/java/com/example/party/IgnoreAwareSpecTest.java`](../src/test/java/com/example/party/IgnoreAwareSpecTest.java)
and the `gate` target in [`Makefile`](../Makefile). The raw contract remains
the source of truth for code generation and for `controls-check`.

**Proposed upstream action.**

1. Skip operations with `x-controls-ignore: true` in
   `openapidiff.Check` (or add `-honor-ignore`, default on).
2. Add a test fixture with one ignored and one controlled operation; expected
   result: no `MissingRegistry` for the ignored route.
3. Once released, delete `IgnoreAwareSpecTest` and point `gate` at
   `openapi.yaml` again.

**Acceptance:** raw `openapi-diff` on a contract containing
`x-controls-ignore` exits 0, and an ignored route still produces
`403 unregistered_endpoint` at the sidecar.

---

### G2 — DQ `required` rules deny reads of the same resource type (High)

**Guide:** phase 6 says blocking DQ must deny; phase 6's matrix implies DQ is a
write-path control. It does not say DQ is evaluated on reads.

**Evidence.** The engine parses the request body (empty for `GET`) and always
calls `dq.Check(ep.ResourceType, body)`
([`internal/engine/engine.go`](../../controls-core/internal/engine/engine.go)).
`required` is `!present || value == nil || value == ""`
([`internal/dq/dq.go`](../../controls-core/internal/dq/dq.go)).

Adding this rule to the running demo:

```json
{"id":"experiment.legalName.required","resourceType":"party",
 "field":"legalName.firstName","required":true,"blocking":true}
```

made an owner read fail:

```text
GET /parties/PTY-1001  ->  403
{"error":"dq_blocking:experiment.legalName.required"}
```

Removing the rule restored `200`. The rule was not committed.

**Impact.** Any resource type with a read endpoint cannot use `required` DQ
rules, which is the most common data-quality check. Silent alternatives
(non-blocking `required`) pollute decision logs and metrics on every read.

**Workaround here.**

- No `required` rules on `party`; presence/requiredness is enforced by the
  OpenAPI schema and Bean Validation, so the application returns
  `400 validation_failed` before mastering state changes.
- DQ owns value quality on writes: date format, email/phone shape, segment
  enum, version type, change-reason pattern, advisory length.
- `docs/CONTROLS.md` §5 records the constraint explicitly.

**Proposed upstream action.**

1. Add an action/method scope to `config.DQRule` (`action: read|write|*`, or
   `methods: [PUT, PATCH, POST]`), applied in `dq.Evaluator.Check`.
2. Alternatively, evaluate `required` only when the request carried a body
   (and keep value rules evaluating on any present field).
3. Add a regression test: `GET` and `PUT` on the same resource type; the
   required rule applies only to `PUT`.
4. Document the chosen semantics in the guide and a DQ contract.

**Acceptance:** a required DQ rule on `party` does not deny
`GET /parties/{id}`, but still denies a `PUT` missing that field with
`dq_blocking:<rule>`.

---

### G3 — `controls-check` assumes one request schema per resource type (High)

**Guide:** phase 6 says `controls-check` proves "rules/masks/DQ/attributes
resolve" and phase 1 owns "route/resource binding". It does not state that only
one write journey per resource type is supported.

**Evidence.** `controlscheck.Validate` collects endpoints by resource type
([`internal/controlscheck/check.go`](../../controls-core/internal/controlscheck/check.go))
and `requestSchema` returns the **first** endpoint's JSON request body
([same file](../../controls-core/internal/controlscheck/check.go)). With the
merge journey initially registered as resource type `party` (as the domain
suggests), the gate checked the update DQ rules against the merge body:

```text
error: dq rule "party.dateOfBirth.format" field "dateOfBirth" not in request schema
error: dq rule "party.contactPoints.email.format" field "contactPoints.email.value" not in request schema
error: dq rule "party.segment.allowed" field "segment" not in request schema
...
```

**Impact.** A service with more than one write body per resource type cannot
keep `controls-check` green without either weakening DQ or distorting the
resource model. This is common in mastering services (update, merge, consent,
address change), so it will block real adopters.

**Workaround here.** The merge journey is registered under the control scope
`partyMerge` (`x-resource-type: partyMerge`) with the same PIP attributes and
its own entitlement/DQ rules. `party` now has one write body (`PUT`), so the
gate validates each rule against its real schema. This is documented in
`docs/CONTROLS.md` §2 as a **control-scope split, not a second entity**.

**Proposed upstream action.**

1. Make `controls-check` validate DQ per endpoint (or per operation) using the
   endpoint's own request schema, not the first one for the resource type.
2. If per-endpoint validation is undesirable, add an explicit `operation`/`id`
   field to DQ rules so the scope is unambiguous.
3. Document the "one request schema per resource type" constraint until fixed,
   with the `partyMerge` pattern as an example.

**Acceptance:** a bundle with two `POST`/`PUT` journeys on one resource type,
each with different DQ fields, passes `controls-check`.

---

### G4 — DQ array paths pass the gate but fail at runtime (High)

**Guide:** phase 6 expects `controls-check` to validate DQ resolution; the
guide's masking section supports `[*]`, and Party-style models naturally have
arrays (addresses, documents, consents).

**Evidence.** `dq.New` rejects wildcard paths:

```text
dq rule "...": wildcard paths are not supported
```

([`internal/dq/dq.go`](../../controls-core/internal/dq/dq.go)). But
`controls-check` loads the bundle with `config.LoadDir` and never compiles the
rules, so it accepts the same rule and exits 0:

```text
$ go run ./tools/controls-check ... -bundle .tmp/dq-array ...
ok: bundle matches openapi.yaml
$ echo $?
0
```

At sidecar startup the rule is rejected, so the bundle that passed the gate
cannot be served. `controls-check` also does not validate DQ operators,
patterns, `type` values or `maxLength` values; those checks live only in
`dq.New`.

**Impact.** A green pipeline can publish a bundle that makes the sidecar fail
closed or refuse to start. Array fields cannot be DQ-validated even though they
can be masked.

**Workaround here.** DQ targets only scalar or nested-object paths
(`legalName.middleName`, `contactPoints.email.value`, `dateOfBirth`, …).
Array-level validation is delegated to the OpenAPI schema and the application.
The end-to-end test asserts the supported rules.

**Proposed upstream action.**

1. `controls-check` should call `dq.New` (or an equivalent compiled validation)
   so operator/pattern/wildcard errors fail the gate.
2. Add wildcard support to DQ evaluation (`addresses[*].country`) and to
   `controls-check`'s path resolution.
3. Until then, document the array limitation in the guide and a DQ contract.
4. Add negative gate fixtures: unknown op, invalid regex, wildcard path.

**Acceptance:** a DQ rule with `[*]` either works end-to-end or fails
`controls-check` with a clear message — never passes the gate and then fails at
runtime.

---

### G5 — Mask-path typos are warnings, not gate failures (High)

**Guide:** phase 6 claims `controls-check` proves "rules/masks/DQ/attributes
resolve"; the definition of done (guide §14) requires `controls-check` green.

**Evidence.** A field listed in a mask policy but absent from the response
schema produces a warning, and the tool still exits 0:

```text
$ # party.read: "ssn" renamed to "ssnTypo"
warning: mask policy "party.read" field "ssnTypo" not in response schema for "get-party"
ok: bundle matches openapi.yaml
$ echo $?
0
```

The warning is emitted in
[`internal/controlscheck/check.go`](../../controls-core/internal/controlscheck/check.go);
only `res.Errors` fail the command.

**Impact.** This is a security-relevant gate gap. A typo in `ssn`, `pan` or a
nested path means the response is returned unmasked, while the pipeline is
green. The end-to-end tests only catch paths they assert. Schema validation does
not close this gap either: a JSON schema for the registry cannot know which
fields a response will contain.

**Workaround here.** `test.sh` asserts exact outputs for every masked field
(`ssn`, `taxId`, `dateOfBirth`, email, phone, document number, merge source
id). That catches regressions in the demo, but it is not a substitute for a
gate.

**Proposed upstream action.**

1. Treat a missing mask path as an error by default (or under `-strict`).
2. Add a negative fixture with a typo; expected exit 1.
3. Consider validating `rejectFields` and `fallback`/classification paths the
   same way.

**Acceptance:** a mask policy referencing a non-existent response field fails
`controls-check`.

---

### G6 — Bare `partial` is accepted despite the spec (Medium)

**Guide/contract:** [`SPEC-mask-ops.md`](../../controls-core/contracts/SPEC-mask-ops.md)
says `partial` is valid only when at least one of `keepPrefix`, `keepSuffix`,
`preserveDomain` or `keep` is set; "a bare partial is a validation error".

**Evidence.** Bundle validation checks the mode and locked fields but not the
presence of a keep parameter
([`internal/config/config.go`](../../controls-core/internal/config/config.go)).
A policy with `{"mode":"partial"}` loads successfully and `controls-check`
returns `ok`. At runtime the partial masker masks the whole value (prefix 0,
suffix 0), rather than rejecting the bundle.

**Impact.** An authoring mistake becomes a silent full mask (possibly breaking
a non-sensitive journey) instead of a configuration error. It also makes the
"partial must never be an ambiguous default" promise untrue.

**Workaround here.** Every `partial` rule in `controls/mask-policies.json`
sets `keepPrefix`, `keepSuffix`, `keep: "year"` or `preserveDomain`.

**Proposed upstream action.** Enforce the parameter requirement in
`config.Validate` (and the mask-policy schema), with tests for each valid form
and for bare `partial`.

**Acceptance:** a bundle containing `{"mode":"partial"}` fails to load with a
clear error.

---

### G7 — No OpenAPI annotation for `allowNonJSON` (Medium)

**Guide/contract:** phase 1's extension table has no `allowNonJSON`. The
mask contract (`SPEC-mask-ops.md` §6) says a masked endpoint fails closed on
non-JSON unless it opts out.

**Evidence.** `allowNonJSON` exists in the registry schema and runtime
([`contracts/registry.schema.json`](../../controls-core/contracts/registry.schema.json),
[`internal/config/config.go`](../../controls-core/internal/config/config.go)),
but the OpenAPI operation struct in the generator has no field for it
([`internal/openapiregistry/generate.go`](../../controls-core/internal/openapiregistry/generate.go)).
There is no `x-allow-non-json`, so a non-JSON endpoint cannot be expressed in
the contract and still have a generated registry. The only options are to
hand-edit the registry (anti-pattern) or stay JSON-only.

**Impact.** Download, CSV export or binary routes cannot be adopted cleanly,
even though the runtime supports the opt-out.

**Workaround here.** All controlled routes are JSON; no opt-out is needed.

**Proposed upstream action.** Add `x-allow-non-json` to the generator
operation struct and registry output, document it in the guide table, and add a
generation test. If the decision is intentionally "JSON only", remove
`allowNonJSON` from the public contract to avoid a misleading option.

**Acceptance:** a contract with `x-allow-non-json: true` produces
`"allowNonJSON": true` in the generated registry, and a non-JSON response is
passed through only for that endpoint.

---

### G8 — Registry id casing is inconsistent across contracts, guide and tool (Medium)

**Guide:** the phase 1 example uses `operationId: getAccount`; the generated
registry example uses `"id": "get-account"`.

**Evidence.** [`SPEC-registry.md`](../../controls-core/contracts/SPEC-registry.md)
and [`registry.schema.json`](../../controls-core/contracts/registry.schema.json)
require kebab-case (`^[a-z0-9][a-z0-9-]*$`). The generator uses
`operationId` verbatim as the registry id
([`internal/openapiregistry/generate.go`](../../controls-core/internal/openapiregistry/generate.go)).
A camelCase operation id therefore produces a registry that violates the
schema. The guide's example does exactly that.

**Impact.** Services that copy the guide's example ship schema-invalid ids.
Decision logs, metrics labels and bundle validation may diverge between the
generated file and the contract.

**Workaround here.** All operation ids are kebab-case (`get-party`,
`update-party`, `merge-party`, `search-parties`). OpenAPI Generator still
produces the expected Java methods (`getParty`, `updateParty`, …). The drift
test pins the ids, and `ControlsSchemaTest` validates the committed registry
against `registry.schema.json`, so an id-casing regression now fails the build.

**Proposed upstream action.** Either normalize `operationId` to kebab-case in
the generator (and document the mapping), or relax the schema/SPEC to allow
camelCase. Add schema validation of generated registries in CI.

**Acceptance:** every generated registry id validates against
`registry.schema.json`, regardless of the operation-id casing style used in
the contract.

---

### G9 — `openapi-diff` parity is partial (Medium)

**Guide:** phase 1 says `openapi-diff` checks "coverage and annotation parity".

**Evidence.** `compareAnnotations` compares only `x-resource-type`,
`x-mask-policy`, `x-resource-source` and `x-resource-id`
([`internal/openapidiff/openapidiff.go`](../../controls-core/internal/openapidiff/openapidiff.go)).
It does not compare `x-action`, `x-attributes`, `x-freshness`,
`x-self-describing`, `x-mask-errors` or `x-max-staleness-seconds`, even though
all of those change enforcement behaviour.

**Impact.** A contract change to `x-attributes` (for example dropping `region`
from the PIP projection) can silently change entitlement outcomes while
`openapi-diff` stays green. The registry drift test in this repo was widened to
cover these bindings because of this gap.

**Workaround here.** `RegistryContractTest` compares resource type, action,
mask policy, source, attributes (order-sensitive), freshness,
`maxStalenessSeconds`, `maskErrors`, `selfDescribing` and the resource-id
reference.

**Proposed upstream action.** Extend `compareAnnotations`/`Endpoint` with the
remaining bindings and add a drift fixture for each.

**Acceptance:** changing any of the listed annotations makes `openapi-diff`
fail.

---

### G10 — PIP fixtures cannot model per-resource lag or unknown lag (Medium)

**Guide:** phase 6 requires failure tests for "stale/unknown lag"; phase 5
documents `lagSeconds`/`lagKnown` in the PIP contract.

**Evidence.** The fixture format only contains `resources` and
`classifications` ([`pip/server/repository.go`](../../controls-core/pip/server/repository.go));
lag is a process-wide `server.lagSeconds` setting, and `lagKnown` is derived
from it. There is no fixture-level way to make one party stale, another unknown
and a third fresh in the same run.

**Impact.** The local failure matrix cannot be exercised without writing a
custom PIP, which defeats the "self-contained example" goal. The demo uses
`lagSeconds: 2` and `x-freshness: fresh` on the read, so the happy path and the
PIP-outage path are covered, but `stale_attributes` and `lag_unknown` are not.

**Workaround here.** `pip/pip.yaml` reports `lagSeconds: 2`; `GET` uses
`x-freshness: fresh` with `x-max-staleness-seconds: 5`. A local PIP contract
stub (`tools/stubpip`) reads `lagSeconds`/`lagKnown` from a state file on every
request, so `make test-lag` exercises the boundary (`5` → allow), stale (`6` →
`stale_attributes`), unknown (`lagKnown: false` → `lag_unknown`) and recovery
without a custom PIP build.

**Proposed upstream action.** Extend the fixture schema with per-resource
`lagSeconds`, `lagKnown`, `version` and `ttlSeconds` overrides, and document
how to script stale/unknown cases.

**Acceptance:** one fixture can produce allow, `stale_attributes` and
`lag_unknown` outcomes for different party ids without a custom PIP.

## 3. Documentation gaps

### D1 — Command lines are placeholders

The guide's phase 1 block shows `openapi-registry` without `-service` and
`openapi-registry -check ...` without `-out` (the tool requires it). The
`openapi-diff` invocation is also abbreviated. The full, working sequence is in
this repo's [`Makefile`](../Makefile) `gate` target.

**Proposed:** copy the full commands into the guide, including `-service` and
`-out`, and note that `-check` compares generated JSON byte-for-byte.

### D2 — `x-resource-source: both` semantics are underspecified

The guide says `both` is "payload overlaid with PIP attributes" but does not
say that:

- the PIP record is still required (an unknown resource is `404` before the
  application runs);
- PIP attributes win over body fields, which is what prevents a client from
  writing `ownerId`/`region` to gain entitlement.

Both behaviours are used by `update-party` and documented in
`docs/CONTROLS.md` §1. **Proposed:** add them to the phase 1 table and phase 8.

### D3 — The guide promises a drift test that it does not ship

Phase 6 says `mvn verify` proves "app builds and registry drift test passes",
but no reusable test is provided. This repo's
[`RegistryContractTest`](../src/test/java/com/example/party/RegistryContractTest.java)
is a candidate template (SnakeYAML + Jackson, no extra dependencies).

**Proposed:** publish a Maven test template or a small checker, and link it
from the guide.

### D4 — DQ authoring is not specified

The guide lists `dq.json` ownership but not the rule schema, supported
operators, `blocking` semantics, or the request-body-only scope. This repo's
[`docs/CONTROLS.md`](../docs/CONTROLS.md) §5 is a working reference.

**Proposed:** add a DQ contract (schema + operator list + examples) under
`contracts/`, alongside `SPEC-mask-ops.md`, and link it from phase 6.

### D5 — Cached endpoints can hide a PIP outage in tests

Phase 6's matrix says "PIP down → 503", but a `cached` endpoint can still serve
from the sidecar cache. The demo's read uses `x-freshness: fresh` specifically
so the outage test is deterministic.

**Proposed:** note in phase 6 that outage tests must use `fresh` (or clear the
cache), and that `cached` endpoints may continue to serve during a PIP outage.

## 4. Outstanding actions for later action

These are deferred by request. None was applied to `controls-core` during this
task.

### P0 — correctness/security gates

1. **Honor `x-controls-ignore` in `openapi-diff`.**
   Files: `internal/openapidiff/openapidiff.go`, `tools/openapi-diff/main.go`.
   Acceptance: G1.
2. **Scope DQ rules by action/method (or skip `required` without a body).**
   Files: `internal/config/config.go`, `internal/dq/dq.go`,
   `internal/engine/engine.go`.
   Acceptance: G2.
3. **Make missing mask paths fail `controls-check`.**
   File: `internal/controlscheck/check.go`.
   Acceptance: G5, with a negative fixture.
4. **Compile DQ rules in `controls-check` and reject wildcards at the gate.**
   Files: `tools/controls-check/main.go`, `internal/dq/dq.go`.
   Acceptance: G4.

### P1 — contract/tooling consistency

5. **Per-endpoint DQ schema validation in `controls-check`** (or an explicit
   `operation` field on DQ rules), replacing the one-schema-per-resource-type
   assumption.
   Acceptance: G3.
6. **Add DQ wildcard support** for array paths in the engine and gate.
   Acceptance: G4.
7. **Enforce bare-`partial` validation.**
   Files: `internal/config/config.go`, `contracts/mask-policy.schema.json`.
   Acceptance: G6.
8. **Add `x-allow-non-json` generation.**
   Files: `internal/openapiregistry/generate.go`,
   `docs/SIDECAR-GUIDE.md`.
   Acceptance: G7.
9. **Extend `openapi-diff` parity** to action, attributes, freshness,
   self-description, mask-errors and max-staleness.
   Acceptance: G9.
10. **Normalize or validate registry ids** against the kebab-case schema.
    Acceptance: G8.

### P2 — developer experience and documentation

11. **Per-resource lag/version fixture support in the PIP.**
    Acceptance: G10.
12. **Guide updates:** full commands (D1), `both` semantics (D2), DQ contract
    (D4), cached-outage note (D5).
13. **Publish a registry drift-test template** (D3).

## 5. How this repo compensates

| Gap | Local compensation | Residual risk |
|---|---|---|
| G1 | `IgnoreAwareSpecTest` + filtered spec for `openapi-diff` | Workaround must be removed when upstream fixes it |
| G2 | No `required` DQ; OpenAPI/Bean Validation returns 400 | Requiredness is not a sidecar DQ denial |
| G3 | `partyMerge` control scope | Extra fixture/rule duplication; scope split must be explained |
| G4 | DQ only on scalar/nested fields | Array fields rely on application validation |
| G5 | Exact-output assertions in `test.sh` | A newly added mask field without a test can still regress |
| G6 | Every `partial` has keep parameters | Reviewer discipline only |
| G7 | JSON-only controlled routes | Non-JSON journeys not demonstrated |
| G8 | Kebab-case operation ids + drift test | Adopters copying the guide may still get it wrong |
| G9 | Wider `RegistryContractTest` | Only as good as the local test |
| G10 | Stub PIP with state-file lag covers boundary/stale/unknown/recovery | Fixture-level lag support still deferred upstream |

## 6. Reproductions

From the workspace root, with a sibling `controls-core` checkout:

```bash
# G1: raw diff fails on the ignored route
cd controls-core
go run ./tools/openapi-diff \
  -openapi ../party-mastering-service/openapi.yaml \
  -registry ../party-mastering-service/controls/registry.json

# G5: rename "ssn" to "ssnTypo" in a copy of mask-policies.json, then:
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/mask-typo \
  -pip-fixture ../party-mastering-service/pip/attributes.json

# G6: set a policy field to {"mode":"partial"} with no keep parameter, then:
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/bare-partial \
  -pip-fixture ../party-mastering-service/pip/attributes.json

# G4: add a DQ rule on addresses[*].country, then:
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/dq-array \
  -pip-fixture ../party-mastering-service/pip/attributes.json
# -> "ok"; the sidecar then rejects the rule at startup ("wildcard paths are not supported")
```

G2 was reproduced against the running compose stack by temporarily adding the
required rule, restarting the sidecar, observing
`403 dq_blocking:experiment.legalName.required` on a GET, then restoring the
bundle and observing `200`.

The normal, committed gate is:

```bash
cd party-mastering-service
make gate
make test
```
