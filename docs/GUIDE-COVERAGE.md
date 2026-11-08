# SIDECAR-GUIDE coverage matrix

Scope: [`controls-core/docs/SIDECAR-GUIDE.md`](https://github.com/dennisholee/controls-core/docs/SIDECAR-GUIDE.md)
at `controls-core` **v0.41.0**, plus its extensions and the service demo.

Status legend:

| Status | Meaning |
|---|---|
| **Verified** | Exercised locally by an automated test or a documented gate |
| **Partial** | The local part is verified; one or more production-only steps are not |
| **Documented** | A process/ownership rule, not executable code |
| **Environment-only** | Requires the target cluster, gateway, registry or CI; **not claimed as verified** |
| **N/A** | Deliberately not used by this demo |

`tools/docs_check.py` enforces that every numbered guide section appears below
and that every `x-*` extension named by the guide is covered. It also checks
local links/anchors and that documented `make` targets exist.

## 1. Guide sections

| Guide | Requirement | Implementation | Evidence | Status |
|---|---|---|---|---|
| §1 | Sidecar scope and non-goals | `internal/engine`, `sidecar/extproc`, Helm charts | `test.sh`, `test-signed.sh`, Go tests | Verified |
| §2 | Role ownership | README, `docs/CONTROLS.md`, `docs/GOVERNANCE.md` | review only | Documented |
| §3 | Prerequisites | `Makefile`, `compose*.yaml`, Helm charts | `make gate`, local stacks; cluster prerequisites absent | Partial |
| §4 | Annotate contract, generate and gate registry | `openapi.yaml`, `RegistryContractTest`, `ControlsSchemaTest`, `openapi-registry`, `openapi-diff` | `make gate` | Verified |
| §5 | Run locally | `compose.yaml`, `compose.signed.yaml`, `compose.lag*.yaml`, `sidecar*.yaml`, `pip/` | `make up`, `test*.sh` | Verified |
| §6 | Policy and DQ ownership | `controls/*.json`; DQ contract [`SPEC-dq.md`](https://github.com/dennisholee/controls-core/contracts/SPEC-dq.md) | `controls-check`, tests | Documented |
| §7 | Package and deploy | `Dockerfile`, `sidecar/Dockerfile`, Helm charts | local images; Helm/cluster not deployed | Environment-only |
| §8 | Identity and PIP | `sidecar.signed.yaml`, `tools/sign_identity.py`, PIP fixture/contract | `test-signed.sh`, PIP handshake; gateway/mTLS absent | Partial |
| §9 | Test | `test/lib.sh`, `test*.sh`, `conformance/fixtures`, Maven tests | all local suites green, including malformed/oversized bodies; cluster matrix absent | Partial |
| §10 | Rollout | production process | not performed | Environment-only |
| §11 | Operate | ext_proc metrics/health, audit sink | metrics endpoint present; dashboards/retention absent | Partial |
| §12 | Troubleshooting | tests reproduce `403`/`404`/`503` reasons | `test.sh`, `test-signed.sh`, `test-lag*.sh` | Verified |
| §13 | Anti-patterns | app port unpublished, signed mode, service-owned registry | `test.sh`, `test-signed.sh`, review | Verified |
| §14 | Definition of done | see §3 below | see §3 below | Partial |
| §15 | Reference | documentation set | `make docs-check` | Verified |

## 2. Extensions

| Extension | Demo use | Evidence |
|---|---|---|
| `x-resource-type` | all controlled routes | `RegistryContractTest` |
| `x-resource-id` | path-bound routes | `RegistryContractTest` |
| `x-mask-policy` | all controlled routes | `ControlsSchemaTest`, e2e masking |
| `x-resource-source` | `pip` and `both` | contract + e2e |
| `x-attributes` | PIP projections | `RegistryContractTest`, `controls-check` |
| `x-action` | derived read/write; explicit supported | parity gate |
| `x-freshness` | `fresh` on reads | `test-lag*.sh` |
| `x-self-describing` | `update-party` | `self_describing_id_mismatch` test |
| `x-mask-errors` | all controlled routes | error masking path |
| `x-max-staleness-seconds` | reads (5s) | `test-lag*.sh` |
| `x-controls-ignore` | `GET /parties` | `unregistered_endpoint` test |
| `x-allow-non-json` | `export-party` CSV | CSV e2e test |
| `x-subject` | development stacks | raw-header tests |
| `x-claim-*` | development stacks | role/region tests |
| `x-controls-identity` | signed mode | `test-signed.sh` |

## 3. Definition of done

| Guide §14 item | Status | Evidence |
|---|---|---|
| Annotations complete; generated registry committed | Verified | `make registry`, drift test |
| `mvn verify`, `openapi-diff`, `controls-check` green | Verified | `make gate`, `mvn verify` |
| Signed bundle and public key mounted | Verified locally | `make test-signed` |
| Gateway identity envelope enforced | Partial | signed mode verified; gateway signer environment-only |
| App port unpublished; NetworkPolicy applied | Partial | app port verified unpublished; NetworkPolicy environment-only |
| PIP mTLS/caller checks enabled | Environment-only | Helm values + audit C1; not deployed here |
| Contract tests cover allow, deny, mask, DQ, 404, outage | Verified | `test.sh`, conformance |
| Canary metrics reviewed | Environment-only | not performed |
| Dashboards/alerts for PIP, DQ, stale, audit, version mismatch | Environment-only | not shipped |
| Bundle digest and rollback digest recorded | Partial | digest verified/logged locally; rollback environment-only |

## 4. Environment-only register

These items are **not** claimed as verified by the demo. They are tracked in
[`controls-core/docs/PILOT-CHECKLIST.md`](https://github.com/dennisholee/controls-core/docs/PILOT-CHECKLIST.md):

- CNI-enforced NetworkPolicy and gateway-only ingress.
- Gateway header stripping and signed identity envelope.
- PIP mTLS, caller/field authorization, rate/concurrency limits.
- Bundle publication, signing-key custody and digest-pinned images.
- Canary/rollout, dashboards, alerts and audit retention.
- 1,200 RPS/pod load test and p99 budget.

## 5. Reproduce

```bash
make docs-check        # links, anchors, make targets, coverage completeness
make conformance       # engine-level fixtures against the rendered bundle
make guide-smoke       # docs-check + gate + all four end-to-end suites
```

`make docs-check` requires the sibling `controls-core` checkout for the guide
section/extension check; it fails closed if the guide cannot be read.
