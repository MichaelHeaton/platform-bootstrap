#!/usr/bin/env bash
# Fail closed before tofu apply when the Tunnel substrate token lacks
# Account → Cloudflare Tunnel → Edit (Cloudflare API 403 / code 10000).
#
# DNS Edit alone can create the kb-mcp CNAME; remote ingress PUT needs Tunnel Edit.
# See docs/runbooks/08-aws-secrets-manager.md § Tunnel substrate.
#
# Usage (CI, after AWS OIDC):
#   bash scripts/ci-cloudflare-tunnel-token-prereq.sh
#
# Env:
#   KB_MCP_TUNNEL_ID            — optional; else read terraform/kb_mcp.auto.tfvars
#   CLOUDFLARE_API_TOKEN_SECRET — default platform-bootstrap/cloudflare-api-token
#   CLOUDFLARE_API_TOKEN        — optional override (skips SM; tests / break-glass)
#   AWS_REGION + AWS_* OIDC     — SM read via stdlib SigV4 (no aws CLI / boto3)
#   SPECTERREALM_ZONE_NAME      — default specterrealm.com
#
# Sibling runner note: no aws CLI / boto3 — SM is read with Python stdlib + OIDC env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_ID="${CLOUDFLARE_API_TOKEN_SECRET:-platform-bootstrap/cloudflare-api-token}"
ZONE_NAME="${SPECTERREALM_ZONE_NAME:-specterrealm.com}"

tunnel_id="${KB_MCP_TUNNEL_ID:-}"
if [[ -z "${tunnel_id}" && -f "${ROOT}/terraform/kb_mcp.auto.tfvars" ]]; then
  tunnel_id="$(python3 - <<'PY' "${ROOT}/terraform/kb_mcp.auto.tfvars"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'kb_mcp_tunnel_id\s*=\s*"([^"]*)"', text)
print(m.group(1) if m else "")
PY
)"
fi

if [[ -z "${tunnel_id}" ]]; then
  echo "kb_mcp_tunnel_id empty — skipping Cloudflare Tunnel token prereq"
  exit 0
fi

read_secret() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    printf '%s' "${CLOUDFLARE_API_TOKEN}"
    return
  fi
  # Prefer aws CLI when present (laptop); else stdlib SigV4 (sibling runner).
  if command -v aws >/dev/null 2>&1; then
    aws secretsmanager get-secret-value \
      --secret-id "${SECRET_ID}" \
      --query SecretString \
      --output text
    return
  fi
  python3 - <<'PY' "${SECRET_ID}"
"""GetSecretValue via AWS SigV4 — stdlib only (no boto3)."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

secret_id = sys.argv[1]
region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-west-2"
access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
session_token = os.environ.get("AWS_SESSION_TOKEN", "")
if not access_key or not secret_key:
    print(
        "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY required for SM read "
        "(run after configure-aws-credentials)",
        file=sys.stderr,
    )
    raise SystemExit(2)

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
    [
        "POST",
        "/",
        "",
        canonical_headers,
        signed_headers,
        payload_hash,
    ]
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
signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

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
    raise SystemExit(1) from e

secret = (body.get("SecretString") or "").strip()
if not secret:
    print(f"SM {secret_id} returned empty SecretString", file=sys.stderr)
    raise SystemExit(1)
print(secret)
PY
}

token="$(read_secret | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "${token}" ]]; then
  echo "::error::SM ${SECRET_ID} is empty — seed Tunnel substrate token (runbook 08)"
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${token}" -H "Content-Type: application/json")

verify_json="$(curl -sfS "${auth_hdr[@]}" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" || true)"
if [[ -z "${verify_json}" ]] || ! echo "${verify_json}" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "::error::Cloudflare token verify failed for SM ${SECRET_ID} — rotate/seed per runbook 08"
  echo "${verify_json:-"(empty response)"}" >&2
  exit 1
fi

zones_json="$(curl -sfS "${auth_hdr[@]}" \
  "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" || true)"
account_id="$(echo "${zones_json:-}" | jq -r '.result[0].account.id // empty')"
if [[ -z "${account_id}" ]]; then
  echo "::error::Cannot resolve Cloudflare account for zone ${ZONE_NAME} with SM ${SECRET_ID}"
  echo "Token needs Zone → Zone → Read on ${ZONE_NAME} (runbook 08)." >&2
  echo "${zones_json:-"(empty response)"}" >&2
  exit 1
fi

# GET configurations — 403/10000 means DNS-only token (or wrong account scope).
http_code="$(curl -sS -o /tmp/cf-tunnel-config.json -w '%{http_code}' "${auth_hdr[@]}" \
  "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
  || true)"

if [[ "${http_code}" == "200" ]]; then
  echo "✓ Cloudflare Tunnel token can read config for ${tunnel_id} (account ${account_id})"
  exit 0
fi

body="$(cat /tmp/cf-tunnel-config.json 2>/dev/null || true)"
echo "::error::Cloudflare Tunnel config API returned HTTP ${http_code} for tunnel ${tunnel_id}"
echo "${body}" >&2
if [[ "${http_code}" == "403" ]] || echo "${body}" | grep -q '"code":10000'; then
  cat >&2 <<EOF

SM ${SECRET_ID} can authenticate but lacks Account → Cloudflare Tunnel → Edit
(or Account resources do not include this account). DNS Edit alone creates the
CNAME; remote ingress PUT needs Tunnel Edit.

Fix (operator, once):
  1. dash.cloudflare.com/profile/api-tokens → custom token
     Zone DNS Edit + Zone Read on specterrealm.com
     Account → Cloudflare Tunnel → Edit (account that owns kb-mcp)
  2. aws secretsmanager put-secret-value \\
       --secret-id platform-bootstrap/cloudflare-api-token \\
       --secret-string '<new-token>'
  3. Re-run Actions → OpenTofu Apply (gated) → confirm_apply=yes

Do not widen personal/cloudflare-api-token. Details: docs/runbooks/08-aws-secrets-manager.md
EOF
fi
exit 1
