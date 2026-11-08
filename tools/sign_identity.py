#!/usr/bin/env python3
"""Mint a gateway-style signed identity envelope for local signed-mode tests.

The controls sidecar verifies ``x-controls-identity`` with
HMAC-SHA256 when ``CONTROLS_IDENTITY_HMAC_KEY`` is configured. The envelope is

    base64url(payload_json) + "." + base64url(HMAC-SHA256(payload_json, key))

with no padding, matching controls-core's ext_proc identity verifier. This is a
test helper, not a production gateway: the key must come from the gateway
secret store, and the sidecar must never accept raw ``x-subject`` headers.

Example:

    python3 tools/sign_identity.py \
        --subject cust-1001 \
        --key party-mastering-local-identity-key
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def parse_claim(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError(f"claim {raw!r} must be key=value")
    key, value = raw.split("=", 1)
    if not key:
        raise argparse.ArgumentTypeError(f"claim {raw!r} has an empty key")
    return key, value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject", required=True, help="subject id (sub)")
    parser.add_argument(
        "--claim",
        action="append",
        default=[],
        type=parse_claim,
        metavar="KEY=VALUE",
        help="claim to add; repeatable",
    )
    parser.add_argument(
        "--key",
        default=os.environ.get("CONTROLS_IDENTITY_HMAC_KEY", ""),
        help="HMAC key (default: CONTROLS_IDENTITY_HMAC_KEY)",
    )
    parser.add_argument(
        "--issued-at",
        type=int,
        default=int(time.time()),
        help="epoch seconds for iat (default: now)",
    )
    args = parser.parse_args()

    if not args.key:
        parser.error("--key or CONTROLS_IDENTITY_HMAC_KEY is required")

    payload = {
        "sub": args.subject,
        "claims": dict(args.claim),
        "iat": args.issued_at,
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    mac = hmac.new(args.key.encode("utf-8"), raw, hashlib.sha256).digest()
    sys.stdout.write(b64url(raw) + "." + b64url(mac) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
