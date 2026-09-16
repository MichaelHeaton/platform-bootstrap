#!/usr/bin/env bash
# Initialize platform-bootstrap OpenTofu with PostgreSQL remote state (#97).
#
# conn_str from Vault homelab/postgres/conn-platform (tofu_platform role).
#
# Usage:
#   scripts/tofu-pg-init.sh [--migrate-state]
#
# Requires VAULT_TOKEN + VAULT_ADDR (AppRole login in CI).
#
# Provider downloads: checkout@v4 cleans the workspace (.terraform/), so every
# job re-fetches providers from the GitHub releases CDN (185.199.x.x) unless a
# persistent TF_PLUGIN_CACHE_DIR is set. runner-lxc-01 has seen intermittent
# "connection reset by peer" on those downloads (same class as homelab-infra
# #879). This script:
#   1. Points TF_PLUGIN_CACHE_DIR at a runner-local dir outside the workspace
#   2. Retries tofu init with exponential backoff on transient failure
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="${ROOT}/terraform"

MIGRATE=false
if [[ "${1:-}" == "--migrate-state" ]]; then
  MIGRATE=true
fi

: "${VAULT_ADDR:?VAULT_ADDR required}"
: "${VAULT_TOKEN:?VAULT_TOKEN required}"

# Persist providers across jobs (survives actions/checkout clean of the workspace).
if [[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
  if [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
    TF_PLUGIN_CACHE_DIR="${RUNNER_TOOL_CACHE}/opentofu-plugins"
  elif [[ -d /opt/actions-runner-platform-bootstrap ]]; then
    TF_PLUGIN_CACHE_DIR="/opt/actions-runner-platform-bootstrap/.opentofu-plugin-cache"
  else
    TF_PLUGIN_CACHE_DIR="${HOME}/.opentofu.d/plugin-cache"
  fi
fi
mkdir -p "${TF_PLUGIN_CACHE_DIR}"
export TF_PLUGIN_CACHE_DIR
echo "TF_PLUGIN_CACHE_DIR=${TF_PLUGIN_CACHE_DIR}"

CONN="$(curl -sf \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR%/}/v1/homelab/data/postgres/conn-platform" \
  | jq -r '.data.data.conn_str // empty')"

if [[ -z "${CONN}" ]]; then
  echo "✗ Vault path homelab/postgres/conn-platform missing conn_str — run bootstrap-postgres.yml first" >&2
  exit 1
fi

BACKEND_CFG="$(mktemp /tmp/tofu-pg-backend.XXXXXX.hcl)"
trap 'rm -f "${BACKEND_CFG}"' EXIT

PG_CONN_STR="${CONN}" BACKEND_CFG="${BACKEND_CFG}" python3 - <<'PY'
import os
from pathlib import Path

conn = os.environ["PG_CONN_STR"]
path = Path(os.environ["BACKEND_CFG"])
escaped = conn.replace("\\", "\\\\").replace('"', '\\"')
path.write_text(f'conn_str = "{escaped}"\n')
PY

INIT_ARGS=(-input=false -backend-config="${BACKEND_CFG}")
if $MIGRATE; then
  if [[ -z "${TF_TOKEN_app_terraform_io:-}" ]]; then
    echo "✗ TF_TOKEN_app_terraform_io required for --migrate-state (HCP → pg)" >&2
    exit 1
  fi
  INIT_ARGS=(-migrate-state "${INIT_ARGS[@]}")
fi

# Retry provider-install RST / short GitHub CDN blips without hand-installing plugins.
MAX_ATTEMPTS="${TOFU_INIT_MAX_ATTEMPTS:-4}"
DELAY="${TOFU_INIT_RETRY_DELAY_SEC:-5}"
attempt=1
while true; do
  set +e
  tofu -chdir="${WORKSPACE_DIR}" init "${INIT_ARGS[@]}"
  ec=$?
  set -e
  if [[ "${ec}" -eq 0 ]]; then
    break
  fi
  if [[ "${attempt}" -ge "${MAX_ATTEMPTS}" ]]; then
    echo "::error::tofu init failed after ${MAX_ATTEMPTS} attempts (last exit ${ec})" >&2
    exit "${ec}"
  fi
  echo "::warning::tofu init failed (attempt ${attempt}/${MAX_ATTEMPTS}, exit ${ec}); retrying in ${DELAY}s — often GitHub CDN RST on provider download"
  sleep "${DELAY}"
  DELAY=$((DELAY * 2))
  attempt=$((attempt + 1))
done
