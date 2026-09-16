#!/usr/bin/env bash
# Vault AppRole login for GitHub Actions workflows and break-glass recovery.
#
# Primary: VAULT_ADDR / HOMELAB_VAULT_ADDR / https://vault.specterrealm.com (Traefik).
# Break-glass: active k3s vault-ha peer on mgmt VLAN (HTTP 200 on /v1/sys/health).
# NAS01 homelab-vault was removed from Raft (#600) — do not use 172.16.0.5.
#
# Prints shell exports for eval: VAULT_TOKEN and VAULT_ADDR (addr actually used).
#
# Requires: VAULT_APPROLE_ROLE_ID, VAULT_APPROLE_SECRET_ID
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/homelab-vault-addr-default.sh
source "${ROOT}/scripts/homelab-vault-addr-default.sh"

# Optional override; otherwise discover active among k3s peers.
readonly HOMELAB_VAULT_ADDR_BREAKGLASS="${HOMELAB_VAULT_ADDR_BREAKGLASS:-}"

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

# Active Vault HA peer: /v1/sys/health returns 200 only on the leader (standbys 429).
_discover_active_peer() {
  local ip code
  for ip in 172.16.0.23 172.16.0.24 172.16.0.25; do
    code=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://${ip}:8200/v1/sys/health" || true)
    if [[ "${code}" == "200" ]]; then
      echo "http://${ip}:8200"
      return 0
    fi
  done
  return 1
}

_addr_used="${_primary}"
token="$(_approle_login "${_primary}" || true)"

if [[ -z "${token}" ]]; then
  _breakglass="${HOMELAB_VAULT_ADDR_BREAKGLASS}"
  if [[ -z "${_breakglass}" ]]; then
    _breakglass="$(_discover_active_peer || true)"
  fi
  if [[ -n "${_breakglass}" && "${_primary}" != "${_breakglass}" ]]; then
    echo "::warning::Primary Vault login failed at ${_primary}; trying break-glass ${_breakglass}" >&2
    token="$(_approle_login "${_breakglass}" || true)"
    _addr_used="${_breakglass}"
  fi
fi

if [[ -z "${token}" ]]; then
  echo "::error::Vault AppRole login failed at ${_primary} (and k3s peer break-glass if attempted)" >&2
  echo "::error::Confirm vault-ha pods Ready/unsealed and vault-ingress EndpointSlice points at the active leader (#600)" >&2
  exit 1
fi

printf 'export VAULT_TOKEN=%q\n' "${token}"
printf 'export VAULT_ADDR=%q\n' "${_addr_used}"
