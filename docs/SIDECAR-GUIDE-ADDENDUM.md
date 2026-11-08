# Sidecar adoption guide — addendum and outstanding actions

Status: findings from implementing `party-mastering-service` against
`controls-core` **v0.39.0** (released 2026-11-08) and
[`SIDECAR-GUIDE.md`](../../controls-core/docs/SIDECAR-GUIDE.md).

**Coverage note.** The guide's phase 5 (signed identity) and phase 7 (signed
bundle) are exercised in this repo by `make test-signed`; they are not gaps.
Only the findings below required workarounds or are deferred upstream.

**The P0/P1 fixes below shipped in `controls-core` v0.39.0.** This demo
repository vendors none of that code; it consumes the sibling checkout. Every item is now either (a) fixed upstream and
removed from the demo's workarounds, (b) mitigated locally, or (c) still
deferred. The purpose of this document is to keep the evidence and the
remaining backlog reproducible.

## 1. Summary

| ID | Area | Severity | Finding | Status |
|---|---|---|---|---|
| G1 | `openapi-diff` | High | `x-controls-ignore` is honoured by `openapi-registry` but not by `openapi-diff`; the guide's own gate fails on a deliberately excluded route | **Fixed** |
| G2 | DQ engine | High | DQ is evaluated against every request body, so a `required` rule on a resource type with a `GET` denies the read | **Fixed** |
| G3 | `controls-check` | High | DQ fields are validated against one request schema per resource type; two write journeys on one type fail against the wrong schema | **Fixed** |
| G4 | DQ contract/gate | High | DQ array paths pass `controls-check` but the extension rejects them at runtime; the gate does not compile DQ rules | **Fixed** |
| G5 | Masking gate | High | A mask-policy path that does not exist in the response schema is only a warning; the gate still exits 0 and PII may be returned unmasked | **Fixed** |
| G6 | Mask validation | Medium | A bare `partial` (no keep parameters) is accepted, although the mask spec says it is a validation error | **Fixed** |
| G7 | OpenAPI generator | Medium | `allowNonJSON` exists in the registry schema/runtime but has no OpenAPI extension, so it cannot be generated | **Fixed** |
| G8 | Registry contract | Medium | SPEC/schema require kebab-case endpoint ids, the guide example is camelCase, and the generator copies `operationId` verbatim | **Fixed** |
| G9 | `openapi-diff` | Medium | Annotation parity checks only four fields; action, attributes, freshness, self-description and mask-error bindings are not compared | **Fixed** |
| G10 | PIP fixtures | Medium | The local PIP fixture cannot express per-resource lag, unknown lag or version, so the stale/unknown DQ-of-freshness tests cannot be run locally | **Fixed** |
| D1–D5 | Guide text | Low | Command lines, `both` source semantics, DQ authoring, cached PIP outages and the drift-test template are underspecified | **Fixed** |

**Fixed** means implemented in the workspace `controls-core` checkout
(unreleased) with regression tests; the corresponding demo workaround was
removed or updated. **Open** items remain deferred.

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

**Resolution.** `openapidiff.Check` now skips operations with
`x-controls-ignore: true`; regression tests cover both the skipped route and
the case where an ignored route is wrongly present in the registry. The demo's
`IgnoreAwareSpecTest` and filtered `target/controlled-openapi.yaml` were
deleted, and `make gate` runs `openapi-diff` on the raw `openapi.yaml`.

**Acceptance met:** raw `openapi-diff` on the demo contract exits 0, and
`GET /parties` still produces `403 unregistered_endpoint` at the sidecar.

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

**Resolution.** `config.DQRule` now carries an optional `action`
(`read|write|delete|*`), applied by `dq.Evaluator.Check`. The demo's DQ rules
are scoped to `write` and now include required first/last name rules. A `GET`
with no body still returns `200`; a `PUT` missing `legalName.firstName`
returns `403 dq_blocking:party.legalName.firstName.required`. `controls-check`
also rejects an action that is not registered for the rule's resource type.

**Acceptance met:** a write-scoped required rule does not deny
`GET /parties/{id}`, but still denies a `PUT` missing that field.

---

### G3 — `controls-check` assumes one request schema per resource type (High)

**Guide:** phase 6 says `controls-check` proves "rules/masks/DQ/attributes
resolve" and phase 1 owns "route/resource binding". It does not state that only
one write journey per resource type is supported.

**Evidence.** `controlscheck.Validate` collected endpoints by resource type and
`requestSchema` returned the **first** endpoint's JSON request body. With the
merge journey initially registered as resource type `party`, the gate checked
the update DQ rules against the merge body:

```text
error: dq rule "party.dateOfBirth.format" field "dateOfBirth" not in request schema
error: dq rule "party.contactPoints.email.format" field "contactPoints.email.value" not in request schema
error: dq rule "party.segment.allowed" field "segment" not in request schema
...
```

**Impact.** A service with more than one write body per resource type cannot
keep `controls-check` green without either weakening DQ or distorting the
resource model. This is common in mastering services (update, merge, consent,
address change), so it would block real adopters.

**Resolution.** `config.DQRule` now accepts an optional `endpoint` (registry
entry id) in addition to `action`. `controls-check` validates an
endpoint-scoped rule against that endpoint's own JSON request schema, and
checks that the rule's resource type and action agree with the endpoint. The
demo's update rules target `update-party` and its merge rules target
`merge-party`, both under the `party` resource type; the duplicated
`partyMerge` scope, PIP fixture and entitlement rules were removed.

**Acceptance met:** a bundle with two write journeys on one resource type, each
with different DQ fields, passes `controls-check`.

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

**Resolution.** `controlscheck.Validate` compiles the DQ rules with
`dq.New`, so unknown operators, invalid regexes and malformed paths fail
`controls-check` instead of passing the gate. `dq` now resolves `[*]` array
wildcards: a rule evaluates every element, and `required` treats a missing or
empty array as a violation. The demo adds
`party.addresses.country.format` on `addresses[*].country`.

**Acceptance met:** a DQ rule with `[*]` works end-to-end and is validated by
`controls-check`.

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

**Resolution.** `controlscheck.Validate` now treats a mask field that does not
exist in the response schema as an error. A regression test renames `ssn` to
`ssnTypo` and requires a failure. `test.sh` still asserts the exact outputs, so
a runtime masking regression is also caught.

**Acceptance met:** a mask policy referencing a non-existent response field
fails `controls-check`.

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

**Resolution.** `config.Validate` rejects a `partial` field with none of
`keepPrefix`, `keepSuffix`, `preserveDomain` or `keep`. A regression test loads
a bundle with a bare partial and expects a validation error.

**Acceptance met:** a bundle containing `{"mode":"partial"}` fails to load with
a clear error.

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

**Resolution.** `openapi-registry` maps `x-allow-non-json` to the registry's
`allowNonJSON`, with a generation test. The extension is documented in the
guide's phase 1 table. The party service stays JSON-only, so no route uses it.

**Acceptance met:** a contract with `x-allow-non-json: true` produces
`"allowNonJSON": true` in the generated registry.

---

### G8 — Registry id casing is inconsistent across contracts, guide and tool (Medium)

**Guide:** the phase 1 example uses `operationId: getAccount`; the generated
registry example uses `"id": "get-account"`.

**Evidence.** [`SPEC-registry.md`](../../controls-core/contracts/SPEC-registry.md)
and [`registry.schema.json`](../../controls-core/contracts/registry.schema.json)
require kebab-case (`^[a-z0-9][a-z0-9-]*$`). The generator used
`operationId` verbatim as the registry id, so a camelCase operation id produced
a registry that violates the schema. The guide's example did exactly that.

**Impact.** Services that copy the guide's example shipped schema-invalid ids.
Decision logs, metrics labels and bundle validation could diverge between the
generated file and the contract.

**Resolution.** `openapi-registry` normalizes the derived id with `kebabCase`
(`getAccount` → `get-account`, `getPartyByID` → `get-party-by-id`) and rejects
duplicate ids created by normalization. Existing kebab-case operation ids are
unchanged. A generation test pins the mapping, and the demo's
`ControlsSchemaTest` validates the committed registry against the schema.

**Acceptance met:** every generated registry id validates against
`registry.schema.json`; camelCase and kebab-case operation ids produce the same
kebab-case id.### G9 — `openapi-diff` parity is partial (Medium)

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

**Resolution.** `openapi-diff` now compares action, attributes,
freshness, `maxStalenessSeconds`, `maskErrors`, `selfDescribing` and
`allowNonJSON` in addition to the resource bindings. A binding-parity test
asserts each mismatch is reported. `RegistryContractTest` remains the
independent service-side drift check.

**Acceptance met:** changing any of the listed annotations makes
`openapi-diff` fail.

---

### G10 — PIP fixtures cannot model per-resource lag or unknown lag (Medium)

**Guide:** phase 6 requires failure tests for "stale/unknown lag"; phase 5
documents `lagSeconds`/`lagKnown` in the PIP contract.

**Evidence.** The fixture format only contains `resources` and
`classifications` ([`pip/server/repository.go`](../../controls-core/pip/server/repository.go));
lag is a process-wide `server.lagSeconds` setting, and `lagKnown` is derived
from it. There is no fixture-level way to make one party stale, another unknown
and a third fresh in the same run.

**Impact (before the fix).** The reference fixture could not express a mixed
lag matrix, so a service needed a custom PIP or stub to test
`stale_attributes` and `lag_unknown`.

**Resolution.** The fixture format now accepts an optional `resourceMeta` map
with per-resource `lagSeconds`, `lagKnown`, `version` and `ttlSeconds`.
`MemoryRepo` returns them and the PIP server uses the fixture TTL when present;
the process-wide `-lag-seconds` flag still overrides lag. A server test covers
known and unknown lag plus version/TTL overrides. The demo keeps its stub PIP
for dynamic state-file toggling, but the reference PIP can now express the
matrix statically.

**Acceptance met:** one fixture can produce allow, `stale_attributes` and
`lag_unknown` outcomes for different party ids without a custom PIP.

## 3. Documentation gaps

### D1 — Command lines are placeholders

The guide's phase 1 block showed `openapi-registry` without `-service` and
`openapi-registry -check ...` without `-out` (the tool requires it). The
`openapi-diff` invocation is also abbreviated. The full, working sequence is in
this repo's [`Makefile`](../Makefile) `gate` target.

**Fixed:** the guide now has full `openapi-registry -check` and
`openapi-diff` commands, including `-service`/`-out`, and notes that `-check`
compares generated JSON byte-for-byte.

### D2 — `x-resource-source: both` semantics are underspecified

The guide said `both` is "payload overlaid with PIP attributes" but did not
say that:

- the PIP record is still required (an unknown resource is `404` before the
  application runs);
- PIP attributes win over body fields, which is what prevents a client from
  writing `ownerId`/`region` to gain entitlement.

Both behaviours are used by `update-party` and documented in
`docs/CONTROLS.md` §1. **Fixed:** the guide's phase 1 now states both the PIP
record requirement and the attribute-overlay rule.

### D3 — The guide promises a drift test that it does not ship

Phase 6 said `mvn verify` proves "app builds and registry drift test passes",
but no reusable test is provided. This repo's
[`RegistryContractTest`](../src/test/java/com/example/party/RegistryContractTest.java)
is a candidate template (SnakeYAML + Jackson, no extra dependencies).

**Fixed:** the guide links the existing
[`spring-accounts` drift test](../../controls-core/examples/spring-accounts/src/test/java/example/RegistryContractTest.java).

### D4 — DQ authoring is not specified

The guide listed `dq.json` ownership but not the rule schema, supported
operators, `blocking` semantics, or the request-body-only scope. This repo's
[`docs/CONTROLS.md`](../docs/CONTROLS.md) §5 is a working reference.

**Fixed:** added [`contracts/SPEC-dq.md`](../../controls-core/contracts/SPEC-dq.md)
and [`contracts/dq.schema.json`](../../controls-core/contracts/dq.schema.json),
and linked them from the guide. The demo validates `dq.json` against the schema.

### D5 — Cached endpoints can hide a PIP outage in tests

Phase 6's matrix said "PIP down → 503", but a `cached` endpoint could still serve
from the sidecar cache. The demo's read uses `x-freshness: fresh` specifically
so the outage test is deterministic.

**Fixed:** phase 6 now says outage tests must use `fresh` (or clear the
cache), and that `cached` endpoints may keep serving last-known-good data.

## 4. Actions taken and remaining backlog

### Implemented in this pass

All P0 and P1 items, with regression tests in `controls-core`:

1. `openapi-diff` honors `x-controls-ignore` (G1).
2. DQ rules scope by `action` and `endpoint`; `required` no longer denies reads
   (G2, G3).
3. `controls-check` validates endpoint-scoped DQ against the endpoint request
   schema, and compiles all DQ rules (G3, G4).
4. Missing mask-policy paths are gate errors (G5).
5. Bare `partial` is rejected at bundle load (G6).
6. `x-allow-non-json` generates `allowNonJSON` (G7).
7. Registry ids are normalized to kebab-case (G8).
8. `openapi-diff` compares action, attributes, freshness, max-staleness,
   mask-errors, self-description and allow-non-json (G9).
9. DQ supports `[*]` array paths; the demo exercises
   `addresses[*].country` (G4).
10. Guide docs D1–D5 updated; DQ contract and schema added.

### Release

The fixes are released as `controls-core` **v0.39.0** (commit `10b5c06` plus the
release commit) and tagged locally. Publishing the contracts package and tools
image is a CI action that needs the registry credentials; it is not performed
from this workspace.

### Remaining backlog

1. **Optional:** use the new `x-allow-non-json` path in a non-JSON demo route
   (for example a CSV export) to prove the opt-out end-to-end.
2. **Optional:** replace the demo's stub PIP with fixture `resourceMeta` for the
   static lag cases; keep the stub only for dynamic state toggling.

## 5. How this repo compensates

| Gap | Local compensation | Residual risk |
|---|---|---|
| G1 | n/a — fixed upstream; filtered spec removed | None |
| G2 | Write-scoped required DQ rules enforce presence on writes | None |
| G3 | n/a — fixed upstream; endpoint-scoped DQ rules | None |
| G4 | n/a — fixed upstream; array DQ rules active | None |
| G5 | n/a — fixed upstream; exact-output tests remain | None |
| G6 | n/a — fixed upstream; `keep` parameters still explicit | None |
| G7 | JSON-only controlled routes | Non-JSON journey not demonstrated |
| G8 | n/a — generator normalizes ids; schema test retained | None |
| G9 | n/a — fixed upstream; `RegistryContractTest` retained | None |
| G10 | n/a — fixture metadata added; stub retained for dynamic state | None |

## 6. Reproductions

From the workspace root, with a sibling `controls-core` checkout:

```bash
# G1 (fixed): now exits 0, even though GET /parties has no registry entry
cd controls-core
go run ./tools/openapi-diff \
  -openapi ../party-mastering-service/openapi.yaml \
  -registry ../party-mastering-service/controls/registry.json

# G5 (fixed): rename "ssn" to "ssnTypo" in a copy of mask-policies.json
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/mask-typo \
  -pip-fixture ../party-mastering-service/pip/attributes.json
# -> exits 1 with "mask policy ... field ... not in response schema"

# G4 (fixed at gate): add a DQ rule on addresses[*].country
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/dq-array \
  -pip-fixture ../party-mastering-service/pip/attributes.json
# -> exits 1 with "wildcard paths are not supported"

# G6 (fixed): a policy field with {"mode":"partial"} and no keep parameter
go run ./tools/controls-check \
  -openapi ../party-mastering-service/openapi.yaml \
  -bundle ../party-mastering-service/.tmp/bare-partial \
  -pip-fixture ../party-mastering-service/pip/attributes.json
# -> exits 1 with "partial requires keepPrefix, keepSuffix, preserveDomain or keep"
```

G2 is covered by `internal/dq` `TestActionScoping` and by `test.sh`: a
write-scoped required rule does not run on `GET`, and a `PUT` missing
`legalName.firstName` returns
`403 dq_blocking:party.legalName.firstName.required`.

The normal, committed gate is:

```bash
cd party-mastering-service
make gate
make test
make test-signed
make test-lag
```
