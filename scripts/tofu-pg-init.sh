#!/usr/bin/env bash
# Initialize platform-bootstrap OpenTofu with PostgreSQL remote state (#97).
#
# conn_str from Vault homelab/postgres/conn-platform (tofu_platform role).
#
# Usage:
#   scripts/tofu-pg-init.sh [--migrate-state]
#
# Requires VAULT_TOKEN + VAULT_ADDR (AppRole login in CI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="${ROOT}/terraform"

MIGRATE=false
if [[ "${1:-}" == "--migrate-state" ]]; then
  MIGRATE=true
fi

: "${VAULT_ADDR:?VAULT_ADDR required}"
: "${VAULT_TOKEN:?VAULT_TOKEN required}"

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

tofu -chdir="${WORKSPACE_DIR}" init "${INIT_ARGS[@]}"
