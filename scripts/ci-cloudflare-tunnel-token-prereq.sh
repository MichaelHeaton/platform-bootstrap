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
#   KB_MCP_TUNNEL_ID          — optional; else read terraform/kb_mcp.auto.tfvars
#   CLOUDFLARE_API_TOKEN_SECRET — default platform-bootstrap/cloudflare-api-token
#   AWS_REGION                — required when reading SM
#   SPECTERREALM_ZONE_NAME    — default specterrealm.com
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
  if command -v aws >/dev/null 2>&1; then
    aws secretsmanager get-secret-value \
      --secret-id "${SECRET_ID}" \
      --query SecretString \
      --output text
    return
  fi
  python3 - <<'PY' "${SECRET_ID}"
import os, sys
try:
    import boto3
except ImportError as e:
    print(
        "aws CLI and boto3 both missing — cannot read SM for tunnel token prereq",
        file=sys.stderr,
    )
    raise SystemExit(2) from e
secret_id = sys.argv[1]
region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-west-2"
client = boto3.client("secretsmanager", region_name=region)
print(client.get_secret_value(SecretId=secret_id)["SecretString"].strip())
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
