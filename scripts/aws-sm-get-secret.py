#!/usr/bin/env python3
"""Read one AWS Secrets Manager SecretString via SigV4 (stdlib only).

Usage:
  AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… [AWS_SESSION_TOKEN=…] \\
    python3 scripts/aws-sm-get-secret.py platform-bootstrap/cloudflare-api-token

Prints the secret string to stdout (no trailing commentary). Exit 1 on failure.
Sibling runner has no aws CLI / boto3 — OIDC env from configure-aws-credentials.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <secret-id>", file=sys.stderr)
        return 2
    secret_id = sys.argv[1]
    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-west-2"
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    session_token = os.environ.get("AWS_SESSION_TOKEN", "")
    if not access_key or not secret_key:
        print(
            "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY required "
            "(aws CLI profile or configure-aws-credentials OIDC)",
            file=sys.stderr,
        )
        return 2

    service = "secretsmanager"
    host = f"secretsmanager.{region}.amazonaws.com"
    amz_target = "secretsmanager.GetSecretValue"
    payload = json.dumps({"SecretId": secret_id}).encode("utf-8")
    content_type = "application/x-amz-json-1.1"

    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    credential_scope = f"{date_stamp}/{region}/{service}/aws4_request"

    payload_hash = hashlib.sha256(payload).hexdigest()
    canonical_headers = (
        f"content-type:{content_type}\n"
        f"host:{host}\n"
        f"x-amz-date:{amz_date}\n"
        f"x-amz-target:{amz_target}\n"
    )
    signed_headers = "content-type;host;x-amz-date;x-amz-target"
    if session_token:
        canonical_headers += f"x-amz-security-token:{session_token}\n"
        signed_headers += ";x-amz-security-token"

    canonical_request = "\n".join(
        ["POST", "/", "", canonical_headers, signed_headers, payload_hash]
    )
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    def _sign(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    k_date = _sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region = _sign(k_date, region)
    k_service = _sign(k_region, service)
    k_signing = _sign(k_service, "aws4_request")
    signature = hmac.new(
        k_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        "AWS4-HMAC-SHA256 "
        f"Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )
    headers = {
        "Content-Type": content_type,
        "X-Amz-Date": amz_date,
        "X-Amz-Target": amz_target,
        "Authorization": authorization,
    }
    if session_token:
        headers["X-Amz-Security-Token"] = session_token

    req = urllib.request.Request(
        f"https://{host}/",
        data=payload,
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", errors="replace")
        print(f"SM GetSecretValue HTTP {e.code}: {err}", file=sys.stderr)
        return 1

    secret = (body.get("SecretString") or "").strip()
    if not secret:
        print(f"SM {secret_id} returned empty SecretString", file=sys.stderr)
        return 1
    print(secret, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
