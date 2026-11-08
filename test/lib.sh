#!/usr/bin/env bash
# Shared assertions and teardown for the party demo suites.
# Requires the sourcing script to set COMPOSE, LABEL and OUT.

fail() {
  echo "${LABEL:-SAMPLE} FAIL: $*" >&2
  ${COMPOSE:-docker compose} logs >&2 || true
  exit 1
}

cleanup() {
  ${COMPOSE:-docker compose} down -v >/dev/null 2>&1 || true
}

assert_code() {
  local want=$1 got=$2 label=$3
  [ "$want" = "$got" ] || {
    echo "body: $(cat "$OUT" 2>/dev/null || true)" >&2
    fail "$label: expected $want, got $got"
  }
}

assert_reason() {
  local want=$1 file=$2 label=$3
  local got
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error",""))' "$file")
  [ "$want" = "$got" ] || {
    echo "body: $(cat "$file" 2>/dev/null || true)" >&2
    fail "$label: expected reason $want, got $got"
  }
}
