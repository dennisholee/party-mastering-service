# Party domain model

Status: reference model for this demo. Revision `1.0.0`, matching
`openapi.yaml`.

## 1. What a Party is

A **Party** is the mastered, golden record for one individual bank customer. It
is the single answer to "who is this customer?" across core banking, CRM and
wealth systems. The service owns the record; downstream systems subscribe to
its changes.

This service models natural persons only (`partyType = INDIVIDUAL`). A future
`ORGANIZATION` party type would be a separate schema extension, not a new field
value sprinkled through the model.

Two identifiers are deliberately separated:

| Identifier | Meaning | Authority |
|---|---|---|
| `partyId` | Golden mastering identifier (`PTY-1001`) | this service |
| `ownerId` | Subject id of the customer for entitlement (`cust-1001`) | gateway claims / PIP |
| `relationshipManagerId` | Subject id of the assigned RM | PIP |
| `ssn`, `taxId`, document numbers | Sensitive identifiers | mastered but never returned in clear |

`ownerId` is **not** `partyId`. A party can be read by its owner, its
relationship manager, a regional operations user or compliance, depending on
policy. The route binding decides which policy applies; the payload never does.

## 2. Golden-record shape

```json
{
  "partyId": "PTY-1001",
  "partyType": "INDIVIDUAL",
  "legalName": {"firstName": "Jane", "middleName": "Q", "lastName": "Doe"},
  "dateOfBirth": "1984-07-12",
  "ssn": "111-22-3333",
  "taxId": "TIN-99-8877665",
  "contactPoints": {
    "email": {"value": "jane.doe@example.com", "verified": true},
    "phone": {"value": "+1-415-555-0142", "verified": true}
  },
  "addresses": [
    {"type": "HOME", "line1": "1 Market St", "line2": "Apt 9",
     "city": "San Francisco", "administrativeArea": "CA",
     "postalCode": "94105", "country": "US"}
  ],
  "documents": [
    {"type": "PASSPORT", "number": "X1234567", "issuingCountry": "US"}
  ],
  "segment": "PREMIER",
  "status": "ACTIVE",
  "riskRating": "LOW",
  "ownerId": "cust-1001",
  "relationshipManagerId": "rm-77",
  "region": "US",
  "version": 1,
  "updatedAt": "2026-11-01T09:15:00Z",
  "sourceSystems": ["CORE", "CRM"],
  "consents": [
    {"purpose": "MARKETING", "granted": false, "reference": "CONSENT-77"},
    {"purpose": "ANALYTICS", "granted": true, "reference": "CONSENT-78"}
  ]
}
```

## 3. Field semantics

| Field | Type | Notes |
|---|---|---|
| `partyId` | string `^PTY-[0-9]{4,}$` | Stable golden identifier; appears in the route |
| `partyType` | enum `INDIVIDUAL` | Natural person only in v1 |
| `legalName` | object | `firstName` and `lastName` required; `middleName` optional |
| `dateOfBirth` | date | Masked to the year for reads (`1984******`) |
| `ssn` | string | Locked field, always fully masked in responses |
| `taxId` | string | Fully masked in responses |
| `contactPoints` | object | Email and phone; both partially masked |
| `addresses` | array | Home, work or mailing address; structural data |
| `documents` | array | Identity documents; `number` partially masked |
| `segment` | enum | `RETAIL`, `PREMIER`, `PRIVATE` |
| `status` | enum | `ACTIVE`, `BLOCKED`, `CLOSED` |
| `riskRating` | enum | `LOW`, `MEDIUM`, `HIGH` |
| `ownerId` | string | Customer subject id for owner entitlement |
| `relationshipManagerId` | string | RM subject id for RM entitlement |
| `region` | string | Servicing region; drives regional entitlement and residency |
| `version` | integer >= 1 | Optimistic concurrency |
| `updatedAt` | date-time | Last mastering write |
| `sourceSystems` | string[] | Contributing systems for lineage |
| `consents` | array | Purpose-scoped consent flags |

## 4. Mastering invariants

1. **One golden record per `partyId`.** Duplicate source records are merged
   into it; the service exposes merges explicitly.
2. **`version` is the concurrency token.** `PUT` must send the current version.
   A stale version is `409 version_conflict`; no partial write occurs.
3. **Identifiers are immutable through the customer-update journey.** `ssn`,
   `taxId`, document numbers, `ownerId`, `relationshipManagerId`, `region` and
   `status` are not client-writable. The sidecar rejects the sensitive fields in
   cleartext (`rejected_field`) and the application preserves authoritative
   values.
4. **Ownership comes from the PIP, not the payload.** `PUT` uses
   `x-resource-source: both`, so PIP attributes overlay body fields; a client
   cannot write `ownerId` or `region` to gain entitlement.
5. **A BLOCKED party is immutable through the write journeys.** A deny rule is
   evaluated before allow rules and beats a matching allow.
6. **Merges are explicit and one-way.** The source party becomes `CLOSED`; the
   target version increments. Merging a party into itself or re-merging a
   closed source is rejected.
7. **Reads never return cleartext PII.** Masking is applied by the sidecar,
   including error responses.

## 5. Status lifecycle

```
ACTIVE ──(risk/compliance block)──▶ BLOCKED
   │                                   │
   └────────(merge source)────────────▶ CLOSED
```

`BLOCKED` drives the absolute deny rule for writes. `CLOSED` is terminal for
the update and merge journeys.

## 6. Data classification

The PIP fixture carries the same classification metadata a production PIP
would publish:

| Field | Classification | Masking mode |
|---|---|---|
| `ssn` | `pii.locked` | full (`[REDACTED]`) |
| `taxId` | `pii.locked` | full |
| `dateOfBirth` | `pii.partial` | partial, keep year |
| `contactPoints.email.value` | `pii.partial` | partial, keep 1 local char + domain |
| `contactPoints.phone.value` | `pii.partial` | partial, keep last 4 |
| `documents[*].number` | `pii.partial` | partial, keep last 3 |

The demo's policies list these fields explicitly. Classification fallback
(`fallback: "classification"`) is available in the sidecar but is not used here,
so the expected outputs stay exact and reviewable.

## 7. Why the Party model suits a controls demo

- It has **one route-bound identity** (`partyId`) and no ambiguity about which
  resource a request targets.
- It has **natural journeys with different bodies** (full update vs merge),
  which exposes the controls-check scoping constraint documented in the
  addendum.
- It has **sensitive scalars, nested objects and arrays**, exercising every
  masking path form.
- It has **owner, manager, region and compliance entitlements**, showing
  default-deny, allow and absolute-deny semantics on the same resource.
