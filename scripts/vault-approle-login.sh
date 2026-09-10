#!/usr/bin/env bash
# Vault AppRole login for Forgejo workflows and break-glass recovery.
#
# Primary: VAULT_ADDR / https://vault.specterrealm.com (service DNS via Traefik).
# Break-glass: http://172.16.0.5:8200 on mgmt VLAN when Traefik routes are not yet synced
# to NAS (/volume1/docker/traefik/dynamic/routes-vault.yaml) — Deploy Workload nas01
# apply vault-sso (#236), not a full nas01 apply.
#
# Prints shell exports for eval: VAULT_TOKEN and VAULT_ADDR (addr actually used).
#
# Requires: VAULT_APPROLE_ROLE_ID, VAULT_APPROLE_SECRET_ID
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/homelab-vault-addr-default.sh
source "${ROOT}/scripts/homelab-vault-addr-default.sh"

readonly HOMELAB_VAULT_ADDR_BREAKGLASS="${HOMELAB_VAULT_ADDR_BREAKGLASS:-http://172.16.0.5:8200}"

: "${VAULT_APPROLE_ROLE_ID:?VAULT_APPROLE_ROLE_ID required}"
: "${VAULT_APPROLE_SECRET_ID:?VAULT_APPROLE_SECRET_ID required}"

_primary="${VAULT_ADDR:-${HOMELAB_VAULT_ADDR:-${HOMELAB_VAULT_ADDR_DEFAULT}}}"

_approle_login() {
  local addr="$1"
  local body http_code resp

  body=$(jq -nc \
    --arg role_id "${VAULT_APPROLE_ROLE_ID}" \
    --arg secret_id "${VAULT_APPROLE_SECRET_ID}" \
    '{role_id: $role_id, secret_id: $secret_id}')

  resp=$(curl -sS -w '\n%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -d "${body}" \
    "${addr%/}/v1/auth/approle/login") || return 1

  http_code="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"

  if [[ "${http_code}" != "200" ]]; then
    echo "Vault AppRole login at ${addr} returned HTTP ${http_code}" >&2
    [[ -n "${resp}" ]] && echo "${resp}" >&2
    return 1
  fi

  echo "${resp}" | jq -r '.auth.client_token // empty'
}

_addr_used="${_primary}"
token="$(_approle_login "${_primary}" || true)"

if [[ -z "${token}" && "${_primary}" != "${HOMELAB_VAULT_ADDR_BREAKGLASS}" ]]; then
  echo "::warning::Primary Vault login failed at ${_primary}; trying break-glass ${HOMELAB_VAULT_ADDR_BREAKGLASS}" >&2
  echo "::warning::Sync routes-vault.yaml: Deploy Workload nas01 apply vault-sso (#236)" >&2
  token="$(_approle_login "${HOMELAB_VAULT_ADDR_BREAKGLASS}" || true)"
  _addr_used="${HOMELAB_VAULT_ADDR_BREAKGLASS}"
fi

if [[ -z "${token}" ]]; then
  echo "::error::Vault AppRole login failed at ${_primary} and ${HOMELAB_VAULT_ADDR_BREAKGLASS}" >&2
  echo "::error::Push routes-vault.yaml to NAS (Deploy Workload nas01 apply vault-sso) and confirm DSM reverse proxy + cert for vault.specterrealm.com" >&2
  exit 1
fi

printf 'export VAULT_TOKEN=%q\n' "${token}"
printf 'export VAULT_ADDR=%q\n' "${_addr_used}"
