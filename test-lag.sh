#!/usr/bin/env bash
# Replica-lag failure matrix.
#
# The GET journey is registered with x-freshness: fresh and
# x-max-staleness-seconds: 5. The stub PIP reports lag from
# .tmp/lag-state.json on every request, so this test can move between:
#
#   lag 2, known    -> 200 (within bound)
#   lag 5, known    -> 200 (boundary, inclusive)
#   lag 6, known    -> 503 stale_attributes
#   lag 2, unknown  -> 503 lag_unknown
#   lag 2, known    -> 200 (recovery)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE="docker compose -f compose.lag.yaml"
BASE="http://127.0.0.1:18009"
TMP=".tmp"
STATE="$TMP/lag-state.json"
OUT="$TMP/lag-test-body.json"
mkdir -p "$TMP"

fail() { echo "LAG SAMPLE FAIL: $*" >&2; $COMPOSE logs >&2 || true; exit 1; }
cleanup() { $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

set_state() {
  printf '{"lagSeconds":%d,"lagKnown":%s}\n' "$1" "$2" > "$STATE"
}

assert_reason() {
  local want=$1 file=$2 label=$3
  local got
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$file")
  [ "$want" = "$got" ] || { echo "body: $(cat "$file" 2>/dev/null || true)" >&2; fail "$label: expected reason $want, got $got"; }
}

get() {
  curl -s --max-time 10 -o "$OUT" -w '%{http_code}' \
    -H 'x-subject: cust-1001' "$BASE/parties/PTY-1001"
}

wait_for() {
  local want=$1 label=$2
  local code=""
  for _ in $(seq 1 60); do
    code=$(get 2>/dev/null || true)
    [ "$code" = "$want" ] && return 0
    sleep 1
  done
  echo "body: $(cat "$OUT" 2>/dev/null || true)" >&2
  fail "$label: expected $want, last code $code"
}

set_state 2 true
wait_for 200 "initial fresh read"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["ssn"] == "[REDACTED]", b
PY

# Boundary: maxStalenessSeconds is inclusive.
set_state 5 true
wait_for 200 "lag equals the staleness bound"

set_state 6 true
wait_for 503 "lag above the staleness bound"
assert_reason stale_attributes "$OUT" "stale attributes"

set_state 2 false
wait_for 503 "unknown replica lag"
assert_reason lag_unknown "$OUT" "unknown lag"

set_state 2 true
wait_for 200 "recovery after lag returns to normal"
python3 - "$OUT" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
assert b["partyId"] == "PTY-1001", b
assert b["ssn"] == "[REDACTED]", b
PY

echo "LAG SAMPLE OK: fresh read allowed at lag 2 and boundary 5;"
echo "               lag 6 -> 503 stale_attributes;"
echo "               unknown lag -> 503 lag_unknown; recovery -> 200"
