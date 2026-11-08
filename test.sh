#!/usr/bin/env bash
# Contract test for the party mastering service.
#
# Proves, through the real Envoy + ext_proc path:
#   - owner / relationship-manager / regional-ops / compliance entitlement
#   - default deny for unknown and unauthenticated callers
#   - exact response masking, including array wildcard paths
#   - blocking DQ, advisory DQ, rejected fields and self-description checks
#   - absolute deny rules beating an otherwise matching allow rule
#   - unregistered (x-controls-ignore) routes stay default-deny
#   - PIP outage fails closed with 503
#   - the application port is not published
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE="docker compose -f compose.base.yaml -f compose.yaml"
BASE="http://127.0.0.1:18007"
TMP=".tmp"
OUT="$TMP/test-body.json"
mkdir -p "$TMP"

LABEL="PARTY SAMPLE"
source test/lib.sh
trap cleanup EXIT

req() {
  local method=$1 url=$2 out=$3
  shift 3
  curl -s --max-time 10 -o "$out" -w '%{http_code}' -X "$method" "$@" "$BASE$url"
}

# ---------------------------------------------------------------- readiness
code=""
for _ in $(seq 1 120); do
  code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: cust-1001' 2>/dev/null || true)
  [ "$code" = "200" ] && break
  sleep 1
done
assert_code 200 "$code" "sidecar/PIP not ready"

# ------------------------------------------------------- owner read + mask
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["partyId"] == "PTY-1001", b
assert b["legalName"]["firstName"] == "Jane", b
assert b["ssn"] == "[REDACTED]", b
assert b["taxId"] == "[REDACTED]", b
assert b["dateOfBirth"] == "1984******", b
assert b["contactPoints"]["email"]["value"] == "j***@example.com", b
assert b["contactPoints"]["phone"]["value"] == "*" * 11 + "0142", b
assert b["documents"][0]["number"] == "*****567", b
assert b["addresses"][0]["line1"] == "1 Market St", b
PY

# ---------------------------------------------------- non-JSON CSV export
code=$(req GET "/parties/PTY-1001/export" "$OUT" -H 'x-subject: cust-1001')
assert_code 200 "$code" "owner CSV export"
grep -q '^partyId,segment,status,region,version$' "$OUT" || fail "CSV header missing: $(cat "$OUT")"
grep -q '^PTY-1001,PREMIER,ACTIVE,US,1$' "$OUT" || fail "CSV row missing: $(cat "$OUT")"
if grep -Eq '111-22|@example' "$OUT"; then fail "CSV leaked PII: $(cat "$OUT")"; fi
code=$(req GET "/parties/PTY-1001/export" "$OUT" -H 'x-subject: u-2')
assert_code 403 "$code" "non-owner CSV export"
code=$(req GET "/parties/PTY-9999/export" "$OUT" -H 'x-subject: cust-1001')
assert_code 404 "$code" "unknown party CSV export"

# ------------------------------------------------ body failure modes
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary '{')
assert_code 400 "$code" "malformed JSON"
assert_reason invalid_json "$OUT" "malformed JSON"

python3 - <<'PY'
import json
body = {
    "legalName": {"firstName": "Janet", "lastName": "Doe"},
    "dateOfBirth": "1984-07-12",
    "contactPoints": {
        "email": {"value": "janet.doe@example.com"},
        "phone": {"value": "+1-415-555-0142"},
    },
    "segment": "PREMIER",
    "changeReason": "CUSTOMER_REQUEST",
    "version": 2,
    "padding": "x" * 1100000,
}
open(".tmp/oversize.json", "w").write(json.dumps(body))
PY
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/oversize.json")
assert_code 413 "$code" "oversized request body"
grep -qi 'payload too large' "$OUT" || fail "oversized body should be rejected by Envoy: $(cat "$OUT")"

# ------------------------------------------------- relationship manager read
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: rm-77')
assert_code 200 "$code" "relationship manager read"

# --------------------------------------------------- regional ops entitlement
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: u-ops-us' -H 'x-claim-role: ops' -H 'x-claim-region: US')
assert_code 200 "$code" "ops US read"
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: u-ops-eu' -H 'x-claim-role: ops' -H 'x-claim-region: EU')
assert_code 403 "$code" "ops EU read must be denied"

# ------------------------------------------------------- compliance read PII
code=$(req GET "/parties/PTY-2002" "$OUT" -H 'x-subject: u-compliance' -H 'x-claim-role: compliance' -H 'x-claim-clearance: high')
assert_code 200 "$code" "compliance read"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["ssn"] == "[REDACTED]", b
assert b["contactPoints"]["email"]["value"] == "l***@example.dk", b
assert b["contactPoints"]["phone"]["value"] == "*" * 11 + "4-56", b
assert b["documents"][0]["number"] == "*****321", b
PY

# ------------------------------------------------------- deny / 404 / missing
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: u-2')
assert_code 403 "$code" "unknown caller"
code=$(req GET "/parties/PTY-1001" "$OUT")
assert_code 403 "$code" "missing identity"
code=$(req GET "/parties/PTY-9999" "$OUT" -H 'x-subject: cust-1001')
assert_code 404 "$code" "unknown party"
assert_reason resource_not_found "$OUT" "unknown party"

# ------------------------------------------------------- update: owner denied
cat > "$TMP/update-denied.json" <<'JSON'
{"legalName":{"firstName":"Jane","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"jane.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":1}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: cust-1001' -H 'content-type: application/json' \
  --data-binary @"$TMP/update-denied.json")
assert_code 403 "$code" "owner has no write entitlement"

# ------------------------------------------------------------- update: allow
cat > "$TMP/update-ok.json" <<'JSON'
{
  "_type": "party",
  "_id": "PTY-1001",
  "legalName": {"firstName": "Janet", "middleName": "Q", "lastName": "Doe"},
  "dateOfBirth": "1984-07-12",
  "contactPoints": {
    "email": {"value": "janet.doe@example.com", "verified": true},
    "phone": {"value": "+1-415-555-0142", "verified": true}
  },
  "addresses": [
    {"type": "HOME", "line1": "1 Market St", "line2": "Apt 9", "city": "San Francisco",
     "administrativeArea": "CA", "postalCode": "94105", "country": "US"}
  ],
  "segment": "PREMIER",
  "changeReason": "CUSTOMER_REQUEST",
  "version": 1
}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/update-ok.json")
assert_code 200 "$code" "steward update"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["version"] == 2, b
assert b["legalName"]["firstName"] == "Janet", b
assert b["ssn"] == "[REDACTED]", b
assert b["contactPoints"]["email"]["value"] == "j***@example.com", b
PY
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: cust-1001')
assert_code 200 "$code" "read after update"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["version"] == 2, b
assert b["legalName"]["firstName"] == "Janet", b
PY

# --------------------------------------------------------------- blocking DQ
cat > "$TMP/dq-bad-date.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"12/07/1984","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-bad-date.json")
assert_code 403 "$code" "invalid date must be blocked by DQ"
assert_reason dq_blocking:party.dateOfBirth.format "$OUT" "date DQ"

cat > "$TMP/dq-bad-email.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"not-an-email"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-bad-email.json")
assert_code 403 "$code" "invalid email must be blocked by DQ"
assert_reason dq_blocking:party.contactPoints.email.format "$OUT" "email DQ"

cat > "$TMP/dq-missing-name.json" <<'JSON'
{"legalName":{"lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-missing-name.json")
assert_code 403 "$code" "missing required first name must be blocked by DQ"
assert_reason dq_blocking:party.legalName.firstName.required "$OUT" "required first name"

cat > "$TMP/dq-bad-address.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"addresses":[{"type":"HOME","line1":"1 Market St","city":"San Francisco","administrativeArea":"CA","postalCode":"94105","country":"USA"}],"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-bad-address.json")
assert_code 403 "$code" "invalid array country must be blocked by DQ"
assert_reason dq_blocking:party.addresses.country.format "$OUT" "array country DQ"

cat > "$TMP/dq-bad-segment.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"GOLD","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-bad-segment.json")
assert_code 403 "$code" "invalid segment must be blocked by DQ"
assert_reason dq_blocking:party.segment.allowed "$OUT" "segment DQ"

cat > "$TMP/dq-bad-version.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":"2"}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-bad-version.json")
assert_code 403 "$code" "string version must be blocked by DQ"
assert_reason dq_blocking:party.version.type "$OUT" "version DQ"

# --------------------------------------------------------- advisory DQ allows
middle=$(python3 -c 'print("Q" * 45)')
cat > "$TMP/dq-advisory.json" <<JSON
{"legalName":{"firstName":"Mei","middleName":"$middle","lastName":"Chen"},"dateOfBirth":"1990-11-23","contactPoints":{"email":{"value":"mei.chen@example.sg"},"phone":{"value":"+65-9123-4567"}},"segment":"PRIVATE","changeReason":"DATA_QUALITY_REVIEW","version":1}
JSON
code=$(req PUT "/parties/PTY-3003" "$OUT" \
  -H 'x-subject: u-steward-apac' -H 'x-claim-role: data-steward' -H 'x-claim-region: APAC' \
  -H 'content-type: application/json' --data-binary @"$TMP/dq-advisory.json")
assert_code 200 "$code" "advisory DQ must not block"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["version"] == 2' "$OUT"

# ------------------------------------------------------- rejected sensitive data
cat > "$TMP/reject-ssn.json" <<'JSON'
{"_type":"party","_id":"PTY-1001","legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","ssn":"111-22-3333","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/reject-ssn.json")
assert_code 403 "$code" "cleartext SSN must be rejected"
assert_reason rejected_field:ssn "$OUT" "SSN rejection"

# --------------------------------------------------- self-description mismatch
cat > "$TMP/self-id.json" <<'JSON'
{"_type":"party","_id":"PTY-2002","legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/self-id.json")
assert_code 403 "$code" "self-describing id mismatch"
assert_reason self_describing_id_mismatch "$OUT" "self-description"

# ------------------------------------------------------- absolute deny on write
cat > "$TMP/blocked-update.json" <<'JSON'
{"legalName":{"firstName":"Lars","lastName":"Nielsen"},"dateOfBirth":"1979-02-03","contactPoints":{"email":{"value":"lars.nielsen@example.dk"},"phone":{"value":"+45-20-12-34-56"}},"segment":"RETAIL","changeReason":"CUSTOMER_REQUEST","version":1}
JSON
code=$(req PUT "/parties/PTY-2002" "$OUT" \
  -H 'x-subject: u-steward-eu' -H 'x-claim-role: data-steward' -H 'x-claim-region: EU' \
  -H 'content-type: application/json' --data-binary @"$TMP/blocked-update.json")
assert_code 403 "$code" "BLOCKED party write must be denied"
assert_reason deny:party.write.blocked "$OUT" "blocked deny rule"

# --------------------------------------------------------------- merge journey
cat > "$TMP/merge-ok.json" <<'JSON'
{"sourcePartyId":"PTY-2002","reason":"DUPLICATE_RECORD"}
JSON
code=$(req POST "/parties/PTY-1001/merges" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/merge-ok.json")
assert_code 201 "$code" "steward merge"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["status"] == "COMPLETED", b
assert b["partyId"] == "PTY-1001", b
assert b["mergedFromPartyId"] == "****2002", b
PY

cat > "$TMP/merge-bad-source.json" <<'JSON'
{"sourcePartyId":"party-2","reason":"DUPLICATE_RECORD"}
JSON
code=$(req POST "/parties/PTY-1001/merges" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/merge-bad-source.json")
assert_code 403 "$code" "merge source id DQ"
assert_reason dq_blocking:party.merge.sourcePartyId.format "$OUT" "merge source DQ"

cat > "$TMP/merge-self.json" <<'JSON'
{"sourcePartyId":"PTY-1001","reason":"DUPLICATE_RECORD"}
JSON
code=$(req POST "/parties/PTY-1001/merges" "$OUT" \
  -H 'x-subject: u-steward-us' -H 'x-claim-role: data-steward' -H 'x-claim-region: US' \
  -H 'content-type: application/json' --data-binary @"$TMP/merge-self.json")
assert_code 400 "$code" "source equals target is application validation"
assert_reason source_equals_target "$OUT" "merge self"

# --------------------------------------------- x-controls-ignore default deny
code=$(req GET "/parties?query=Jane" "$OUT" -H 'x-subject: cust-1001')
assert_code 403 "$code" "ignored route must stay default-deny"
assert_reason unregistered_endpoint "$OUT" "ignored route"

# ---------------------------------------------------- upstream not published
published=$($COMPOSE port app 8080 2>/dev/null || true)
case "$published" in
  *0.0.0.0:*|*"[::]":*|*127.0.0.1:*) fail "application port is published directly: $published" ;;
esac

# ---------------------------------------------------------- PIP outage last
$COMPOSE stop pip >/dev/null
code=$(req GET "/parties/PTY-1001" "$OUT" -H 'x-subject: cust-1001' || true)
assert_code 503 "$code" "PIP outage must fail closed"
assert_reason pip_unavailable "$OUT" "PIP outage"

echo "PARTY SAMPLE OK: entitlement, masking, DQ, rejected fields, self-description,"
echo "                 absolute deny, merge, ignored-route default deny, PIP outage,"
echo "                 and unpublished application port"
