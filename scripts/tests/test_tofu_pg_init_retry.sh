#!/usr/bin/env bash
# Smoke-test tofu-pg-init.sh cache + retry without Vault/OpenTofu.
# Run: bash scripts/tests/test_tofu_pg_init_retry.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/cache" "${TMP}/terraform"
# Minimal workspace so -chdir exists (tofu is mocked).
touch "${TMP}/terraform/.keep"

# Fake curl: return a conn_str JSON envelope Vault would emit.
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Ignore args; emit Vault KV v2 shape with conn_str.
printf '%s\n' '{"data":{"data":{"conn_str":"postgres://u:p@127.0.0.1:5432/db?sslmode=disable"}}}'
EOF
chmod +x "${TMP}/bin/curl"

# Fake jq: extract conn_str the same way the real script does.
cat >"${TMP}/bin/jq" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2016
python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["data"]["conn_str"])'
EOF
chmod +x "${TMP}/bin/jq"

# Fake tofu: fail twice with a CDN-like message, then succeed.
cat >"${TMP}/bin/tofu" <<'EOF'
#!/usr/bin/env bash
STATE="${TOFU_FAKE_STATE:-/tmp/tofu-fake-state}"
n=0
if [[ -f "${STATE}" ]]; then
  n="$(cat "${STATE}")"
fi
n=$((n + 1))
echo "${n}" >"${STATE}"
if [[ "${n}" -lt 3 ]]; then
  echo "Error while installing hashicorp/aws: connection reset by peer" >&2
  exit 1
fi
echo "OpenTofu init ok (attempt ${n})"
exit 0
EOF
chmod +x "${TMP}/bin/tofu"

export PATH="${TMP}/bin:${PATH}"
export VAULT_ADDR="https://vault.example.test"
export VAULT_TOKEN="test-token"
export TF_PLUGIN_CACHE_DIR="${TMP}/cache/opentofu-plugins"
export TOFU_INIT_MAX_ATTEMPTS=4
export TOFU_INIT_RETRY_DELAY_SEC=0
export TOFU_FAKE_STATE="${TMP}/tofu-attempts"
export HOME="${TMP}/home"
mkdir -p "${HOME}"

# Point the script's ROOT at TMP by invoking a wrapper copy... easier: run
# from a copy of the script with ROOT overridden via sed into TMP.
sed "s|^ROOT=.*|ROOT=\"${TMP}\"|" "${ROOT}/scripts/tofu-pg-init.sh" >"${TMP}/tofu-pg-init.sh"
chmod +x "${TMP}/tofu-pg-init.sh"

bash "${TMP}/tofu-pg-init.sh"

if [[ ! -d "${TF_PLUGIN_CACHE_DIR}" ]]; then
  echo "FAIL: plugin cache dir not created: ${TF_PLUGIN_CACHE_DIR}" >&2
  exit 1
fi

attempts="$(cat "${TOFU_FAKE_STATE}")"
if [[ "${attempts}" -ne 3 ]]; then
  echo "FAIL: expected 3 tofu attempts (2 fail + 1 ok), got ${attempts}" >&2
  exit 1
fi

echo "OK: cache dir created and tofu init retried until success"
