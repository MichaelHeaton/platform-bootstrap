#!/usr/bin/env bash
# Fail closed before tofu apply when the Tunnel substrate token lacks
# Account → Cloudflare Tunnel → Edit (Cloudflare API 403 / code 10000).
#
# DNS Edit alone can create the kb-mcp CNAME; remote ingress PUT needs Tunnel Edit.
# See docs/runbooks/08-aws-secrets-manager.md § Tunnel substrate.
#
# Usage (CI, after Vault AppRole login — NOT AWS SM):
#   bash scripts/ci-cloudflare-tunnel-token-prereq.sh
#
# Env:
#   KB_MCP_TUNNEL_ID              — optional; else read terraform/kb_mcp.auto.tfvars
#   CLOUDFLARE_API_TOKEN          — optional override (tests / already loaded)
#   VAULT_ADDR + VAULT_TOKEN      — read homelab/cloudflare/tunnel-substrate-api
#   CLOUDFLARE_TUNNEL_VAULT_PATH  — default cloudflare/tunnel-substrate-api (under homelab/)
#   SPECTERREALM_ZONE_NAME        — default specterrealm.com
#
# Sibling runner has Vault AppRole (same as tofu-pg-init / HCP migrate). It does
# not need aws CLI or boto3 for this check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_KV_PATH="${CLOUDFLARE_TUNNEL_VAULT_PATH:-cloudflare/tunnel-substrate-api}"
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

read_token() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    printf '%s' "${CLOUDFLARE_API_TOKEN}"
    return
  fi
  : "${VAULT_ADDR:?VAULT_ADDR required (Vault AppRole login first)}"
  : "${VAULT_TOKEN:?VAULT_TOKEN required (Vault AppRole login first)}"

  tok="$(curl -sfS \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR%/}/v1/homelab/data/${VAULT_KV_PATH}" \
    | jq -r '.data.data.api_token // empty')"
  if [[ -z "${tok}" ]]; then
    cat >&2 <<EOF
::error::Vault homelab/${VAULT_KV_PATH} missing api_token

Seed (same pattern as homelab/hcp/tfe-api-token — runner uses Vault, not SM):
  vault kv put homelab/${VAULT_KV_PATH} api_token='<Cloudflare token with Tunnel Edit>'

Token scopes: Zone DNS Edit + Zone Read on specterrealm.com AND
Account → Cloudflare Tunnel → Edit. See runbook 08.
Optional: also keep SM platform-bootstrap/cloudflare-api-token in sync for
laptop/SM fallback; gated apply loads Vault → TF_VAR_cloudflare_api_token.
EOF
    exit 1
  fi
  printf '%s' "${tok}"
}

token="$(read_token | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "${token}" ]]; then
  echo "::error::Cloudflare API token empty after Vault/env read"
  exit 1
fi

# Export for later workflow steps (tofu provider via TF_VAR / CLOUDFLARE_API_TOKEN).
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "::add-mask::${token}"
  echo "CLOUDFLARE_API_TOKEN=${token}" >> "${GITHUB_ENV}"
  echo "TF_VAR_cloudflare_api_token=${token}" >> "${GITHUB_ENV}"
fi

auth_hdr=(-H "Authorization: Bearer ${token}" -H "Content-Type: application/json")

verify_json="$(curl -sfS "${auth_hdr[@]}" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify" || true)"
if [[ -z "${verify_json}" ]] || ! echo "${verify_json}" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "::error::Cloudflare token verify failed for Vault homelab/${VAULT_KV_PATH} — rotate/seed per runbook 08"
  echo "${verify_json:-"(empty response)"}" >&2
  exit 1
fi

zones_json="$(curl -sfS "${auth_hdr[@]}" \
  "https://api.cloudflare.com/client/v4/zones?name=${ZONE_NAME}" || true)"
account_id="$(echo "${zones_json:-}" | jq -r '.result[0].account.id // empty')"
if [[ -z "${account_id}" ]]; then
  echo "::error::Cannot resolve Cloudflare account for zone ${ZONE_NAME}"
  echo "Token needs Zone → Zone → Read on ${ZONE_NAME} (runbook 08)." >&2
  echo "${zones_json:-"(empty response)"}" >&2
  exit 1
fi

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

Vault homelab/${VAULT_KV_PATH} authenticates but lacks Account → Cloudflare Tunnel → Edit
(or Account resources omit this account). DNS Edit alone creates the CNAME;
remote ingress PUT needs Tunnel Edit.

Fix (operator, once):
  1. dash.cloudflare.com/profile/api-tokens → custom token
     Zone DNS Edit + Zone Read on specterrealm.com
     Account → Cloudflare Tunnel → Edit (account that owns kb-mcp)
  2. vault kv put homelab/${VAULT_KV_PATH} api_token='<new-token>'
  3. Re-run Actions → OpenTofu Apply (gated) → confirm_apply=yes

Do not widen personal/cloudflare-api-token. Details: docs/runbooks/08-aws-secrets-manager.md
EOF
fi
exit 1
