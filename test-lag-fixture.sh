#!/usr/bin/env bash
# Static replica-lag matrix through the reference PIP and fixture resourceMeta.
#
#   PTY-1001: lag 5, known  -> 200 (boundary, inclusive)
#   PTY-2002: lag 6, known  -> 503 stale_attributes
#   PTY-3003: lag 2, unknown -> 503 lag_unknown
#
# The dynamic stale->recovery sequence lives in test-lag.sh with the stub PIP.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE="docker compose -f compose.lag-fixture.yaml"
BASE="http://127.0.0.1:18010"
TMP=".tmp"
OUT="$TMP/lag-fixture-body.json"
mkdir -p "$TMP"

fail() { echo "LAG FIXTURE FAIL: $*" >&2; $COMPOSE logs >&2 || true; exit 1; }
cleanup() { $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

req() {
  local url=$1 out=$2
  shift 2
  curl -s --max-time 10 -o "$out" -w '%{http_code}' "$@" "$BASE$url"
}

assert_reason() {
  local want=$1 file=$2 label=$3
  local got
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$file")
  [ "$want" = "$got" ] || { echo "body: $(cat "$file" 2>/dev/null || true)" >&2; fail "$label: expected reason $want, got $got"; }
}

code=""
for _ in $(seq 1 120); do
  code=$(req "/parties/PTY-1001" "$OUT" -H 'x-subject: cust-1001' 2>/dev/null || true)
  [ "$code" = "200" ] && break
  sleep 1
done
[ "$code" = "200" ] || { cat "$OUT" >&2 || true; fail "reference PIP/lag fixture not ready: $code"; }
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["ssn"] == "[REDACTED]", b
PY

code=$(req "/parties/PTY-2002" "$OUT" \
  -H 'x-subject: u-compliance' -H 'x-claim-role: compliance' -H 'x-claim-clearance: high')
[ "$code" = "503" ] || { cat "$OUT" >&2 || true; fail "lag 6 should be stale, got $code"; }
assert_reason stale_attributes "$OUT" "stale fixture lag"

code=$(req "/parties/PTY-3003" "$OUT" -H 'x-subject: cust-3003')
[ "$code" = "503" ] || { cat "$OUT" >&2 || true; fail "unknown lag should fail closed, got $code"; }
assert_reason lag_unknown "$OUT" "unknown fixture lag"

echo "LAG FIXTURE OK: reference PIP resourceMeta gives 200 at lag 5,"
echo "               503 stale_attributes at lag 6, and 503 lag_unknown"
