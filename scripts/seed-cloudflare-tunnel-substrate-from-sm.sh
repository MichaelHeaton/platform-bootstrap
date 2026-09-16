#!/usr/bin/env bash
# Copy Cloudflare Tunnel substrate API token from AWS SM → Vault (#1135).
#
# SM:    platform-bootstrap/cloudflare-api-token
# Vault: homelab/cloudflare/tunnel-substrate-api  (key: api_token)
#
# Sibling runner has Vault AppRole + AWS OIDC but no aws CLI — this script
# reads SM via scripts/aws-sm-get-secret.py (stdlib SigV4) and writes Vault
# via curl (same as seed-cloudflare-tunnel-vault.sh / HCP migrate).
#
# Usage:
#   # GHA: workflow "Seed Tunnel substrate Vault" (preferred)
#   # Laptop (after vault login + AWS_PROFILE=platform-bootstrap):
#   bash scripts/seed-cloudflare-tunnel-substrate-from-sm.sh
#
# Optional: SKIP_TUNNEL_EDIT_CHECK=1 to only copy (not recommended).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SM_SECRET_ID="${CLOUDFLARE_API_TOKEN_SECRET:-platform-bootstrap/cloudflare-api-token}"
VAULT_KV_PATH="${CLOUDFLARE_TUNNEL_VAULT_PATH:-cloudflare/tunnel-substrate-api}"
ZONE_NAME="${SPECTERREALM_ZONE_NAME:-specterrealm.com}"

: "${VAULT_ADDR:?VAULT_ADDR required}"
: "${VAULT_TOKEN:?VAULT_TOKEN required (AppRole login or vault login)}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required (OIDC or aws profile)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"
: "${AWS_REGION:=${AWS_DEFAULT_REGION:-us-west-2}}"
export AWS_REGION

echo "→ Reading SM ${SM_SECRET_ID}"
token="$(python3 "${ROOT}/scripts/aws-sm-get-secret.py" "${SM_SECRET_ID}" | tr -d '\r\n')"
token="$(printf '%s' "${token}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "${token}" ]]; then
  echo "✗ Empty token from SM ${SM_SECRET_ID}" >&2
  exit 1
fi
echo "  SM token length: ${#token}"

if [[ "${SKIP_TUNNEL_EDIT_CHECK:-0}" != "1" ]]; then
  echo "→ Checking Cloudflare token can read tunnel configurations (Tunnel Edit)"
  auth_hdr=(-H "Authorization: Bearer ${token}" -H "Content-Type: application/json")
  verify_json="$(curl -sfS "${auth_hdr[@]}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" || true)"
  if [[ -z "${verify_json}" ]] || ! echo "${verify_json}" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "✗ Cloudflare token verify failed — rotate SM token (runbook 08)" >&2
    echo "${verify_json:-"(empty)"}" >&2
    exit 1
  fi
  zones_json="$(curl -sfS "${auth_hdr[@]}" \
    "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" || true)"
  account_id="$(echo "${zones_json:-}" | jq -r '.result[0].account.id // empty')"
  if [[ -z "${account_id}" ]]; then
    echo "✗ Cannot resolve account for ${ZONE_NAME} — token needs Zone Read" >&2
    exit 1
  fi
  tunnel_id=""
  if [[ -f "${ROOT}/terraform/kb_mcp.auto.tfvars" ]]; then
    tunnel_id="$(python3 - <<'PY' "${ROOT}/terraform/kb_mcp.auto.tfvars"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'kb_mcp_tunnel_id\s*=\s*"([^"]*)"', text)
print(m.group(1) if m else "")
PY
)"
  fi
  if [[ -n "${tunnel_id}" ]]; then
    http_code="$(curl -sS -o /tmp/cf-tunnel-cfg.json -w '%{http_code}' "${auth_hdr[@]}" \
      "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
      || true)"
    if [[ "${http_code}" != "200" ]]; then
      body="$(cat /tmp/cf-tunnel-cfg.json 2>/dev/null || true)"
      echo "✗ SM token cannot GET tunnel config (HTTP ${http_code}) — likely DNS-only" >&2
      echo "${body}" >&2
      cat >&2 <<EOF

Do not copy a DNS-only token into Vault. Create/rotate a Cloudflare API token with:
  Zone DNS Edit + Zone Read on specterrealm.com
  Account → Cloudflare Tunnel → Edit
Then put-secret-value on SM ${SM_SECRET_ID} and re-run this seed.
EOF
      exit 1
    fi
    echo "  ✓ Tunnel Edit OK for ${tunnel_id}"
  else
    echo "  (no kb_mcp_tunnel_id in tfvars — skipped config GET)"
  fi
fi

echo "→ Writing Vault homelab/${VAULT_KV_PATH} (api_token)"
body="$(jq -nc --arg t "${token}" '{data: {api_token: $t}}')"
put_http="$(curl -sS -o /tmp/cf-substrate-kv-put.json -w '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "${body}" \
  "${VAULT_ADDR%/}/v1/homelab/data/${VAULT_KV_PATH}" || true)"
if [[ "${put_http}" != "200" && "${put_http}" != "204" ]]; then
  echo "✗ Vault write failed HTTP ${put_http}" >&2
  cat /tmp/cf-substrate-kv-put.json >&2 || true
  exit 1
fi

len="$(curl -sfS -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR%/}/v1/homelab/data/${VAULT_KV_PATH}" \
  | jq -r '.data.data.api_token|length')"
echo "✓ Seeded homelab/${VAULT_KV_PATH} (api_token length ${len})"
echo "  Next: Actions → OpenTofu Apply (gated) → confirm_apply=yes → approve"
