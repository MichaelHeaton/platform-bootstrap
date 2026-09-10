#!/usr/bin/env bash
# Copy McCleaton-Bootstrap/platform-bootstrap HCP state into PostgreSQL (#97).
#
# Usage (on runner-lxc-01 / VLAN 1):
#   export TF_TOKEN_app_terraform_io=...
#   export VAULT_ADDR=... VAULT_TOKEN=...
#   bash scripts/tofu-hcp-state-to-pg.sh
#
# Sanity-checks for aws_iam_policy.bootstrap_ci_management before push.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="${ROOT}/terraform"
HCP_ORG="${HCP_ORG:-McCleaton-Bootstrap}"
HCP_WS="${HCP_WS:-platform-bootstrap}"
WANT_TYPE="${WANT_TYPE:-aws_iam_policy}"
WANT_NAME="${WANT_NAME:-bootstrap_ci_management}"

if [[ -z "${TF_TOKEN_app_terraform_io:-}" ]]; then
  echo "::error::TF_TOKEN_app_terraform_io required to download HCP state." >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "::error::VAULT_TOKEN required for PostgreSQL backend init." >&2
  exit 1
fi

API="https://app.terraform.io/api/v2"
AUTH=(
  -H "Authorization: Bearer ${TF_TOKEN_app_terraform_io}"
  -H "Content-Type: application/vnd.api+json"
)

ws_json="$(curl -sf "${AUTH[@]}" \
  "${API}/organizations/${HCP_ORG}/workspaces/${HCP_WS}")" || {
  echo "::error::Failed to read HCP workspace ${HCP_ORG}/${HCP_WS}." >&2
  exit 1
}

ws_id="$(jq -r '.data.id // empty' <<<"${ws_json}")"
if [[ -z "${ws_id}" ]]; then
  echo "::error::HCP workspace ${HCP_ORG}/${HCP_WS} has no id." >&2
  exit 1
fi

sv_json="$(curl -sf "${AUTH[@]}" \
  "${API}/workspaces/${ws_id}/current-state-version")" || {
  echo "::error::No current state version on ${HCP_ORG}/${HCP_WS}. Do not apply empty pg state." >&2
  exit 1
}

serial="$(jq -r '.data.attributes.serial // empty' <<<"${sv_json}")"
dl_url="$(jq -r '.data.attributes["hosted-state-download-url"] // empty' <<<"${sv_json}")"
if [[ -z "${dl_url}" ]]; then
  echo "::error::HCP state version has no hosted-state-download-url (serial=${serial:-unknown})." >&2
  exit 1
fi

state_file="$(mktemp /tmp/hcp-state.XXXXXX.tfstate)"
trap 'rm -f "${state_file}"' EXIT

if ! curl -sfL -o "${state_file}" "${dl_url}"; then
  curl -sfL "${AUTH[@]}" -o "${state_file}" "${dl_url}"
fi

count="$(jq '[.resources[]?] | length' "${state_file}")"
echo "::notice::HCP ${HCP_ORG}/${HCP_WS} state serial=${serial} resource_blocks=${count}"

if ! jq -e --arg t "${WANT_TYPE}" --arg n "${WANT_NAME}" \
  '.resources[]? | select(.type == $t and .name == $n)' \
  "${state_file}" >/dev/null; then
  echo "::error::HCP state is missing ${WANT_TYPE}.${WANT_NAME}. Refusing to push." >&2
  exit 1
fi

bash "${ROOT}/scripts/tofu-pg-init.sh"

tofu -chdir="${WORKSPACE_DIR}" state push -force "${state_file}"
echo "::notice::Pushed HCP ${HCP_ORG}/${HCP_WS} serial ${serial} into PostgreSQL"
