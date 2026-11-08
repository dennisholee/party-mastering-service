#!/usr/bin/env bash
# Signed-mode contract test.
#
# Unlike test.sh (development headers), this stack runs with:
#   - CONTROLS_IDENTITY_HMAC_KEY set, so raw x-subject/x-claim-* are ignored;
#   - a rendered bundle signed with Ed25519, verified against a mounted public
#     key, with allowUnsigned: false;
#   - only the public key mounted into the sidecar (the private key stays on
#     the host).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE="docker compose -f compose.signed.yaml"
BASE="http://127.0.0.1:18008"
TMP=".tmp"
OUT="$TMP/signed-test-body.json"
KEY="${CONTROLS_IDENTITY_HMAC_KEY:?set CONTROLS_IDENTITY_HMAC_KEY (make test-signed sets a local key)}"
mkdir -p "$TMP"

fail() { echo "SIGNED SAMPLE FAIL: $*" >&2; $COMPOSE logs >&2 || true; exit 1; }
cleanup() { $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

sign() {
  local sub=$1
  shift
  python3 tools/sign_identity.py --key "$KEY" --subject "$sub" "$@"
}

req() {
  local method=$1 url=$2 out=$3 token=$4
  shift 4
  curl -s --max-time 10 -o "$out" -w '%{http_code}' -X "$method" \
    -H "x-controls-identity: $token" "$@" "$BASE$url"
}

anon() {
  local method=$1 url=$2 out=$3
  shift 3
  curl -s --max-time 10 -o "$out" -w '%{http_code}' -X "$method" "$@" "$BASE$url"
}

assert_code() {
  local want=$1 got=$2 label=$3
  [ "$want" = "$got" ] || { echo "body: $(cat "$OUT" 2>/dev/null || true)" >&2; fail "$label: expected $want, got $got"; }
}

assert_reason() {
  local want=$1 file=$2 label=$3
  local got
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$file")
  [ "$want" = "$got" ] || { echo "body: $(cat "$file" 2>/dev/null || true)" >&2; fail "$label: expected reason $want, got $got"; }
}

# ---------------------------------------------------------------- readiness
code=""
for _ in $(seq 1 120); do
  owner=$(sign cust-1001)
  code=$(req GET "/parties/PTY-1001" "$OUT" "$owner" 2>/dev/null || true)
  [ "$code" = "200" ] && break
  sleep 1
done
assert_code 200 "$code" "signed sidecar/PIP not ready"

# ------------------------------------------------- signed owner read + mask
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["partyId"] == "PTY-1001", b
assert b["ssn"] == "[REDACTED]", b
assert b["taxId"] == "[REDACTED]", b
assert b["dateOfBirth"] == "1984******", b
assert b["contactPoints"]["email"]["value"] == "j***@example.com", b
assert b["documents"][0]["number"] == "*****567", b
PY

# ------------------------------------------------------- signed entitlements
rm_mgr=$(sign rm-77)
code=$(req GET "/parties/PTY-1001" "$OUT" "$rm_mgr")
assert_code 200 "$code" "signed relationship-manager read"

ops_us=$(sign u-ops-us --claim role=ops --claim region=US)
code=$(req GET "/parties/PTY-1001" "$OUT" "$ops_us")
assert_code 200 "$code" "signed ops US read"

ops_eu=$(sign u-ops-eu --claim role=ops --claim region=EU)
code=$(req GET "/parties/PTY-1001" "$OUT" "$ops_eu")
assert_code 403 "$code" "signed ops EU read must be denied"

compliance=$(sign u-compliance --claim role=compliance --claim clearance=high)
code=$(req GET "/parties/PTY-2002" "$OUT" "$compliance")
assert_code 200 "$code" "signed compliance read"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["ssn"] == "[REDACTED]", b
assert b["contactPoints"]["email"]["value"] == "l***@example.dk", b
PY

# ------------------------------------------------------------- signed update
cat > "$TMP/signed-update.json" <<'JSON'
{
  "_type": "party",
  "_id": "PTY-1001",
  "legalName": {"firstName": "Janet", "middleName": "Q", "lastName": "Doe"},
  "dateOfBirth": "1984-07-12",
  "contactPoints": {
    "email": {"value": "janet.doe@example.com", "verified": true},
    "phone": {"value": "+1-415-555-0142", "verified": true}
  },
  "segment": "PREMIER",
  "changeReason": "CUSTOMER_REQUEST",
  "version": 1
}
JSON
steward=$(sign u-steward-us --claim role=data-steward --claim region=US)
code=$(req PUT "/parties/PTY-1001" "$OUT" "$steward" \
  -H 'content-type: application/json' --data-binary @"$TMP/signed-update.json")
assert_code 200 "$code" "signed steward update"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["version"] == 2, b
assert b["ssn"] == "[REDACTED]", b
assert b["contactPoints"]["email"]["value"] == "j***@example.com", b
PY
code=$(req GET "/parties/PTY-1001" "$OUT" "$owner")
assert_code 200 "$code" "signed read after update"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["version"] == 2' "$OUT"

# -------------------------------------------------- signed rejected field
cat > "$TMP/signed-ssn.json" <<'JSON'
{"legalName":{"firstName":"Janet","lastName":"Doe"},"dateOfBirth":"1984-07-12","ssn":"111-22-3333","contactPoints":{"email":{"value":"janet.doe@example.com"},"phone":{"value":"+1-415-555-0142"}},"segment":"PREMIER","changeReason":"CUSTOMER_REQUEST","version":2}
JSON
code=$(req PUT "/parties/PTY-1001" "$OUT" "$steward" \
  -H 'content-type: application/json' --data-binary @"$TMP/signed-ssn.json")
assert_code 403 "$code" "signed cleartext SSN must be rejected"
assert_reason rejected_field:ssn "$OUT" "signed SSN rejection"

# ------------------------------------------------- identity failure paths
code=$(anon GET "/parties/PTY-1001" "$OUT")
assert_code 403 "$code" "missing identity envelope"
assert_reason identity_untrusted "$OUT" "missing identity"

code=$(anon GET "/parties/PTY-1001" "$OUT" -H 'x-subject: cust-1001' -H 'x-claim-role: compliance')
assert_code 403 "$code" "raw headers must be ignored in signed mode"
assert_reason identity_untrusted "$OUT" "raw headers"

code=$(req GET "/parties/PTY-1001" "$OUT" "${owner}x")
assert_code 403 "$code" "tampered signature"
assert_reason identity_untrusted "$OUT" "tampered envelope"

expired=$(sign cust-1001 --issued-at "$(($(date +%s) - 3600))")
code=$(req GET "/parties/PTY-1001" "$OUT" "$expired")
assert_code 403 "$code" "expired envelope"
assert_reason identity_untrusted "$OUT" "expired envelope"

wrong_key=$(python3 tools/sign_identity.py --key wrong-key --subject cust-1001)
code=$(req GET "/parties/PTY-1001" "$OUT" "$wrong_key")
assert_code 403 "$code" "wrong signing key"
assert_reason identity_untrusted "$OUT" "wrong key"

# ------------------------------------------------------ signed bundle proof
[ -f "$TMP/signed/bundle/manifest.sig" ] || fail "signed bundle has no manifest.sig"
if $COMPOSE logs sidecar 2>&1 | grep -q "bundle signature not verified"; then
  fail "sidecar reported an unsigned bundle"
fi
published=$($COMPOSE port app 8080 2>/dev/null || true)
case "$published" in
  *0.0.0.0:*|*"[::]":*|*127.0.0.1:*) fail "signed application port is published directly: $published" ;;
esac

echo "SIGNED SAMPLE OK: HMAC identity envelope required, raw headers ignored,"
echo "                   tampered/expired/wrong-key envelopes denied, Ed25519"
echo "                   bundle verified, entitlement/masking/rejection intact"
