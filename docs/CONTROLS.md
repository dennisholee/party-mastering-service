# Controls: routes, entitlements, masks and data quality

This document is the service team's view of the sidecar controls for the party
mastering service. Policy content under `controls/` is a **local fixture**;
production content is authored by the delivery team and rendered into a signed
bundle by the central pipeline.

## 1. Enforcement order

For each request the sidecar runs, in order:

1. **Identity** — signed `x-controls-identity` envelope if
   `CONTROLS_IDENTITY_HMAC_KEY` is set; raw `x-subject`/`x-claim-*` locally.
2. **Route binding** — exact method + path template from `registry.json`;
   unregistered routes are `403 unregistered_endpoint`.
3. **Body and resource id** — JSON parse, then `partyId` from the path
   (or `$._id` for body-bound writes).
4. **Self-description** — with `x-self-describing: true`, `_type`/`_id` in the
   body must match the route (`403 self_describing_id_mismatch`).
5. **Rejected fields** — cleartext `ssn`, `taxId` or document number is
   `403 rejected_field:<name>`.
6. **PIP resolution** — route-bound attribute projection; missing resource is
   `404 resource_not_found`; PIP unavailable is `503 pip_unavailable`; staleness
   is enforced for `fresh`/`deny-on-stale`.
7. **Entitlement** — deny rules first (absolute), then allow rules (OR-ed),
   otherwise `defaultEffect: deny`.
8. **Data quality** — rules for the endpoint's resource type run against the
   request body; blocking violations are `403 dq_blocking:<rule>`.
9. **Upstream call** — only after all of the above.
10. **Response masking** — selected by `x-mask-policy`; errors are masked too
    because `x-mask-errors: true`. A non-JSON body fails closed.

`GET /parties` never reaches step 2 successfully: it is excluded from the
registry with `x-controls-ignore` and is therefore default-deny.

## 2. OpenAPI annotations

| Operation | `x-resource-type` | `x-resource-id` | `x-resource-source` | `x-attributes` | `x-mask-policy` | Other |
|---|---|---|---|---|---|---|
| `get-party` | `party` | `partyId` | `pip` | ownerId, relationshipManagerId, region, status | `party.read` | `x-freshness: fresh`, `x-max-staleness-seconds: 5`, `x-mask-errors: true` |
| `update-party` | `party` | `partyId` | `both` | same | `party.update` | `x-self-describing: true`, `x-mask-errors: true` |
| `merge-party` | `partyMerge` | `partyId` | `pip` | same | `party.merge` | `x-mask-errors: true` |
| `search-parties` | — | — | — | — | — | `x-controls-ignore: true` |

`x-action` is omitted on purpose; it is derived (`GET` → `read`, `PUT`/`POST` →
`write`). The generated registry records the derived action.

### Why `partyMerge` is a separate control scope

`party` and `partyMerge` resolve the **same party** from the PIP and evaluate
the same ownership attributes. The split exists because `controls-check` in
`controls-core` v0.38.3 validates DQ fields against one request schema per
resource type (the first endpoint that has a JSON body). With two write
journeys sharing `party`, the merge rules were checked against the update
schema and vice versa. The `partyMerge` scope keeps each DQ rule validated
against its real request schema. This is a documented workaround, not a second
domain entity; see the addendum (G3).

## 3. Entitlement

`controls/rules.json` uses the reference structured-rule engine
(`defaultEffect: deny`). Deny rules are evaluated first and cannot be overridden.

| Rule | Effect | Scope | Condition |
|---|---|---|---|
| `party.read.owner` | allow | party/read | `subject.sub == resource.ownerId` |
| `party.read.relationship-manager` | allow | party/read | `subject.sub == resource.relationshipManagerId` |
| `party.read.region-ops` | allow | party/read | role `ops` and claim region == resource region |
| `party.read.compliance` | allow | party/read | role `compliance` and clearance `high` |
| `party.write.steward` | allow | party/write | role `data-steward` and claim region == resource region |
| `party.write.compliance` | allow | party/write | role `compliance` and clearance `high` |
| `party.write.blocked` | **deny** | party/write | `resource.status == BLOCKED` |
| `partyMerge.write.steward` | allow | partyMerge/write | role `data-steward` and region match |
| `partyMerge.write.compliance` | allow | partyMerge/write | role `compliance` and clearance `high` |
| `partyMerge.write.blocked` | **deny** | partyMerge/write | `resource.status == BLOCKED` |

### Decision matrix (PTY-1001 is US/ACTIVE; PTY-2002 is EU/BLOCKED)

| Caller | Read PTY-1001 | Read PTY-2002 | Write PTY-1001 | Write PTY-2002 |
|---|---|---|---|---|
| `cust-1001` (owner) | allow | deny | deny (no owner-write rule) | deny |
| `rm-77` (manager) | allow | deny | deny | deny |
| `u-ops-us` role=ops region=US | allow | deny | deny | deny |
| `u-steward-us` role=data-steward region=US | deny | deny | allow | deny (region + BLOCKED) |
| `u-steward-eu` role=data-steward region=EU | deny | deny | deny | deny (`deny:party.write.blocked`) |
| `u-compliance` role=compliance clearance=high | allow | allow | allow | deny (`blocked` absolute) |
| `u-2` unknown | deny | deny | deny | deny |
| missing identity | deny | deny | deny | deny |

`u-steward-eu` writing PTY-2002 is the key case: the allow rule matches the
region, but the BLOCKED deny rule fires first. Deny beats allow by design.

## 4. Masking

Policy content: `controls/mask-policies.json`.

| Policy | Field | Mode | Exact result |
|---|---|---|---|
| `party.read` | `ssn` | full (locked) | `[REDACTED]` |
| `party.read` | `taxId` | full | `[REDACTED]` |
| `party.read` | `dateOfBirth` | partial `keep: year` | `1984-07-12` → `1984******` |
| `party.read` | `contactPoints.email.value` | partial `keepPrefix: 1`, `preserveDomain` | `jane.doe@example.com` → `j***@example.com` |
| `party.read` | `contactPoints.phone.value` | partial `keepSuffix: 4` | `+1-415-555-0142` → `***********0142` |
| `party.read` | `documents[*].number` | partial `keepSuffix: 3` | `X1234567` → `*****567` |
| `party.update` | same fields | same | response of `PUT` is masked identically |
| `party.update` | `rejectFields` | reject | cleartext `ssn`, `taxId`, `documents[*].number` are `403` |
| `party.merge` | `mergedFromPartyId` | partial `keepSuffix: 4` | `PTY-2002` → `****2002` |

`party.read` uses `default: none`: unlisted fields (`partyId`, `ownerId`,
`region`, names, addresses, consents, `version`) pass through. `party.update`
also rejects sensitive request fields, so a write cannot smuggle PII in
cleartext. `ssn` and `taxId` are listed in both `fields` and `rejectFields`:
the first masks a response, the second rejects a request.

Example masked read:

```json
{
  "partyId": "PTY-1001",
  "legalName": {"firstName": "Jane", "middleName": "Q", "lastName": "Doe"},
  "dateOfBirth": "1984******",
  "ssn": "[REDACTED]",
  "taxId": "[REDACTED]",
  "contactPoints": {
    "email": {"value": "j***@example.com", "verified": true},
    "phone": {"value": "***********0142", "verified": true}
  },
  "documents": [{"type": "PASSPORT", "number": "*****567", "issuingCountry": "US"}],
  "segment": "PREMIER",
  "status": "ACTIVE",
  "ownerId": "cust-1001",
  "relationshipManagerId": "rm-77",
  "region": "US",
  "version": 1
}
```

## 5. Data quality

Policy content: `controls/dq.json`. DQ is multi-state: a violation is reported
in logs/metrics even when it does not block. Only `blocking: true` rejects.

| Rule | Scope | Field | Operator | Blocking | Failure reason |
|---|---|---|---|---|---|
| `party.dateOfBirth.format` | party | `dateOfBirth` | pattern `^\d{4}-\d{2}-\d{2}$` | yes | `dq_blocking:party.dateOfBirth.format` |
| `party.contactPoints.email.format` | party | `contactPoints.email.value` | email-shaped pattern | yes | `dq_blocking:party.contactPoints.email.format` |
| `party.contactPoints.phone.format` | party | `contactPoints.phone.value` | `^\+?[0-9][0-9-]{6,19}$` | yes | `dq_blocking:party.contactPoints.phone.format` |
| `party.segment.allowed` | party | `segment` | `^(RETAIL|PREMIER|PRIVATE)$` | yes | `dq_blocking:party.segment.allowed` |
| `party.version.type` | party | `version` | `type: number` | yes | `dq_blocking:party.version.type` |
| `party.changeReason.format` | party | `changeReason` | `^[A-Z_]{3,32}$` | yes | `dq_blocking:party.changeReason.format` |
| `party.legalName.middleName.length` | party | `legalName.middleName` | `maxLength: 40` | **no** | logged, request allowed |
| `party.merge.sourcePartyId.format` | partyMerge | `sourcePartyId` | `^PTY-[0-9]{4,}$` | yes | `dq_blocking:party.merge.sourcePartyId.format` |
| `party.merge.reason.format` | partyMerge | `reason` | `^[A-Z_]{3,32}$` | yes | `dq_blocking:party.merge.reason.format` |

### Why there are no `required` DQ rules

The sidecar evaluates DQ against **every** request body for the resource type,
including the empty body of a `GET`. A `required: true` rule therefore denies
the read: adding `required` on `legalName.firstName` made
`GET /parties/PTY-1001` return `403 dq_blocking:experiment.legalName.required`.
This was reproduced against the running stack and the rule was removed.

Consequences for this service:

- presence/requiredness is enforced by the OpenAPI schema and Bean Validation,
  returning `400 validation_failed` from the application;
- DQ owns **value quality** (format, allowed values, type, length) on writes;
- advisory rules (non-blocking) are used for softer quality signals.

The upstream fix is tracked as G2 in the addendum (scope DQ rules by action or
evaluate `required` only when a body is present).

Cross-field checks are also not expressible in DQ (`sourcePartyId != partyId`
is enforced by the application and returns `400 source_equals_target`).

## 6. Local test matrix

`./test.sh` exercises the real Envoy + ext_proc path. The cases and exact
assertions are listed in the README. The most useful failure modes to reproduce
while developing:

| Symptom | First check |
|---|---|
| `403 default:deny(no-allow-match)` | caller headers, claims, allow rules |
| `403 deny:party.write.blocked` | PIP `status`; deny precedes allow |
| `403 dq_blocking:<rule>` | request field value and `dq.json` |
| `403 rejected_field:ssn` | mask policy `rejectFields` |
| `403 self_describing_id_mismatch` | body `_type`/`_id` vs route |
| `404 resource_not_found` | PIP fixture has the `partyId` |
| `503 pip_unavailable` | PIP container and `pip/pip.yaml` |
| `503 lag_unknown` / `stale_attributes` | PIP `lagSeconds` vs `x-max-staleness-seconds` |
| response not masked | content type, mask policy name, non-JSON body |

## 7. Ownership and production

| Artifact | Owner | This repo |
|---|---|---|
| `openapi.yaml` annotations, registry fragment | service team | committed, generated |
| `rules.json`, `mask-policies.json`, `dq.json` | delivery team | local fixtures |
| sidecar/PIP runtime, contracts, Helm | core engineering | consumed, not modified |
| signed bundle and publication | central pipeline | not present locally |

The local bundle is intentionally unsigned (`allowUnsigned: true`) and uses raw
identity headers. Neither is acceptable in production; see the README's
production notes.

## 8. Signed mode

The development stack (`compose.yaml`) uses raw gateway-stand-in headers and
`allowUnsigned: true`. The signed stack exercises the production path:

```bash
make test-signed
```

What `make signed` (and therefore `make test-signed`) does:

1. copies `controls/` into the pipeline source layout
   (`.tmp/signed/src/{policies,mask-policies,registry,dq}`);
2. renders a bundle with `tools/bundle -service party-mastering`, producing
   `manifest.json` with a digest;
3. generates an Ed25519 key pair with `tools/bundle-keygen`;
4. signs `manifest.sig` with `tools/bundle-sign` and verifies it;
5. starts `compose.signed.yaml` on `:18008` with
   `sidecar.signed.yaml`: `allowUnsigned: false`, the public key mounted, and
   `CONTROLS_IDENTITY_HMAC_KEY` set;
6. runs `test-signed.sh`.

Only the public key is mounted into the sidecar. The private key stays under
`.tmp/signed/keys/` on the host and is never added to the container or git.

`sidecar.signed.yaml` requires the signed `x-controls-identity` envelope:

```
base64url({"sub": "...", "claims": {...}, "iat": <epoch>})
  + "." +
base64url(HMAC-SHA256(payload, CONTROLS_IDENTITY_HMAC_KEY))
```

Mint one locally:

```bash
export CONTROLS_IDENTITY_HMAC_KEY=party-mastering-local-identity-key-change-me
TOKEN=$(python3 tools/sign_identity.py \
  --subject u-steward-us --claim role=data-steward --claim region=US)
curl -s -H "x-controls-identity: $TOKEN" http://127.0.0.1:18008/parties/PTY-1001 | jq
```

In signed mode:

- raw `x-subject` / `x-claim-*` headers are ignored, not merged;
- a missing, malformed, expired or wrongly signed envelope is
  `403 identity_untrusted`;
- an unsigned or tampered bundle prevents the extension from starting, so
  Envoy fails closed;
- decision logs carry the rendered bundle version/digest.

The key in the Makefile is a local demo value. Production takes the HMAC key
from the gateway secret store and the bundle private key from Jenkins
credentials or an HSM; neither belongs in this repository.
