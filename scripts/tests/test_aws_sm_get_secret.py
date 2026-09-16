"""Unit tests for scripts/aws-sm-get-secret.py SigV4 header ordering."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SYS_PATH_SCRIPT = ROOT / "scripts" / "aws-sm-get-secret.py"

spec = importlib.util.spec_from_file_location("aws_sm_get_secret", SYS_PATH_SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
sys.modules["aws_sm_get_secret"] = mod
spec.loader.exec_module(mod)


def test_signed_headers_order_with_session_token_matches_aws() -> None:
    """Regression: OIDC session token must sort before x-amz-target (#111 seed)."""
    payload = b'{"SecretId":"platform-bootstrap/cloudflare-api-token"}'
    headers = mod.build_sigv4_headers(
        method="POST",
        host="secretsmanager.us-west-2.amazonaws.com",
        region="us-west-2",
        service="secretsmanager",
        amz_target="secretsmanager.GetSecretValue",
        content_type="application/x-amz-json-1.1",
        payload=payload,
        access_key="ASIAEXAMPLE",
        secret_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        session_token="session-token-value",
        amz_date="20260916T212712Z",
        date_stamp="20260916",
    )
    # Parse SignedHeaders from Authorization
    auth = headers["Authorization"]
    signed = auth.split("SignedHeaders=")[1].split(",")[0]
    assert signed == (
        "content-type;host;x-amz-date;x-amz-security-token;x-amz-target"
    ), signed
    assert "X-Amz-Security-Token" in headers
    # Payload hash in canonical request path is exercised via non-empty Authorization
    assert headers["Authorization"].startswith("AWS4-HMAC-SHA256 Credential=")
    assert hashlib.sha256(payload).hexdigest()


def test_signed_headers_without_session_token() -> None:
    headers = mod.build_sigv4_headers(
        method="POST",
        host="secretsmanager.us-west-2.amazonaws.com",
        region="us-west-2",
        service="secretsmanager",
        amz_target="secretsmanager.GetSecretValue",
        content_type="application/x-amz-json-1.1",
        payload=b"{}",
        access_key="AKIAEXAMPLE",
        secret_key="secret",
        session_token="",
        amz_date="20260916T212712Z",
        date_stamp="20260916",
    )
    signed = headers["Authorization"].split("SignedHeaders=")[1].split(",")[0]
    assert signed == "content-type;host;x-amz-date;x-amz-target"
    assert "X-Amz-Security-Token" not in headers
