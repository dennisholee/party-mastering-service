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
| `merge-party` | `party` | `partyId` | `pip` | same | `party.merge` | `x-mask-errors: true` |
| `search-parties` | — | — | — | — | — | `x-controls-ignore: true` |

`x-action` is omitted on purpose; it is derived (`GET` → `read`, `PUT`/`POST` →
`write`). The generated registry records the derived action.

### Endpoint-scoped DQ

Both write journeys resolve the same `party` resource and evaluate the same
ownership attributes. DQ rules carry an `endpoint` in addition to `action`:

- `update-party` rules are validated against `PartyUpdateRequest`;
- `merge-party` rules are validated against `PartyMergeRequest`.

`controls-check` validates a scoped rule against that endpoint's own request
schema, so the two journeys can share the `party` resource type. This replaces
the earlier `partyMerge` control-scope workaround (addendum G3).

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

The merge journey uses the `party` write rules above; there is no separate
`partyMerge` policy scope.

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
Rules may be scoped by `action` (`read`, `write`, `delete` or `*`) and by
`endpoint` (a registry entry id). This is how write-only required rules avoid
denying reads, and how update and merge rules validate against their own request
schemas while sharing the `party` resource type.

| Rule | Scope | Action | Endpoint | Field | Operator | Blocking |
|---|---|---|---|---|---|---|
| `party.legalName.firstName.required` | party | write | update-party | `legalName.firstName` | required | yes |
| `party.legalName.lastName.required` | party | write | update-party | `legalName.lastName` | required | yes |
| `party.dateOfBirth.format` | party | write | update-party | `dateOfBirth` | pattern `^\d{4}-\d{2}-\d{2}$` | yes |
| `party.contactPoints.email.format` | party | write | update-party | `contactPoints.email.value` | email-shaped pattern | yes |
| `party.contactPoints.phone.format` | party | write | update-party | `contactPoints.phone.value` | `^\+?[0-9][0-9-]{6,19}$` | yes |
| `party.segment.allowed` | party | write | update-party | `segment` | `^(RETAIL|PREMIER|PRIVATE)$` | yes |
| `party.version.type` | party | write | update-party | `version` | `type: number` | yes |
| `party.changeReason.format` | party | write | update-party | `changeReason` | `^[A-Z_]{3,32}$` | yes |
| `party.legalName.middleName.length` | party | write | update-party | `legalName.middleName` | `maxLength: 40` | **no** |
| `party.addresses.country.format` | party | write | update-party | `addresses[*].country` | `^[A-Z]{2}$` | yes |
| `party.merge.sourcePartyId.format` | party | write | merge-party | `sourcePartyId` | `^PTY-[0-9]{4,}$` | yes |
| `party.merge.reason.format` | party | write | merge-party | `reason` | `^[A-Z_]{3,32}$` | yes |

### Action-scoped required rules

Earlier in adoption, the sidecar evaluated DQ against every request body,
including the empty body of a `GET`; a `required` rule therefore denied reads.
The engine accepts `action` and `endpoint` on a DQ rule, and resolves `[*]`
array paths. Write rules are skipped on reads:

- `GET /parties/PTY-1001` with no body → the write rules are skipped → `200`;
- `PUT` with `legalName.firstName` missing →
  `403 dq_blocking:party.legalName.firstName.required`;
- `PUT` with an invalid value → the value rule denies as before.

This is the P0 fix recorded as G2 in the addendum, extended with endpoint
scoping for G3. Presence is still also described by the OpenAPI schema; the DQ
rule is the enforcement point on the write path.

Cross-field checks are still not expressible in DQ (`sourcePartyId != partyId`
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
| sidecar/PIP runtime, contracts, Helm | core engineering | consumed from a sibling checkout; not vendored |
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

## 9. Replica-lag matrix

`GET /parties/{partyId}` is registered with `x-freshness: fresh` and
`x-max-staleness-seconds: 5`. The local PIP fixture reports a static lag, so
`make test-lag` runs a third stack on `:18009` with the contract stub in
`tools/stubpip`. The stub reads `lagSeconds`/`lagKnown` from
`.tmp/lag-state.json` on every request, which lets the test change the state
without restarting the sidecar.

| Reported lag | `lagKnown` | Sidecar result |
|---|---|---|
| 2 | true | `200`, masked party |
| 5 | true | `200` — the bound is inclusive |
| 6 | true | `503 stale_attributes` |
| any | false | `503 lag_unknown` |
| 2 | true | `200` recovery |

Because the read uses `fresh`, the sidecar bypasses its attribute cache on each
request; a cached endpoint would keep serving the last value. The stub is test
infrastructure, not a production PIP: production PIPs derive lag from the read
replica and report `lagKnown` honestly.
