#!/usr/bin/env bash
# Smoke-test ci-cloudflare-tunnel-token-prereq.sh without live Vault/Cloudflare.
# Run: bash scripts/tests/test_ci_cloudflare_tunnel_token_prereq.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/terraform"
printf 'kb_mcp_tunnel_id = "6b14bcf0-99db-450f-b978-00b4b6eed214"\n' \
  >"${TMP}/terraform/kb_mcp.auto.tfvars"

export CLOUDFLARE_API_TOKEN="dns-only-fake-token"
export GITHUB_ENV="${TMP}/github.env"
: >"${GITHUB_ENV}"

cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
out=""
write_out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    -o) out="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    -w) write_out="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    -H|-sfS|-sS) i=$((i+1)); continue ;;
    https://*) url="${args[$i]}"; i=$((i+1)); continue ;;
    *) i=$((i+1)); continue ;;
  esac
done

body=""
code="200"
if [[ "${url}" == *"/user/tokens/verify" ]]; then
  body='{"success":true,"errors":[],"messages":[],"result":{"status":"active"}}'
elif [[ "${url}" == *"/zones?"* ]]; then
  body='{"success":true,"result":[{"id":"zone1","account":{"id":"acct1"}}]}'
elif [[ "${url}" == *"/configurations" ]]; then
  body='{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"messages":[],"result":null}'
  code="403"
elif [[ "${url}" == *"/v1/homelab/data/"* ]]; then
  echo "Vault should not be called when CLOUDFLARE_API_TOKEN is set" >&2
  exit 99
else
  body='{"success":false}'
  code="500"
fi

if [[ -n "${out}" ]]; then
  printf '%s' "${body}" >"${out}"
fi
if [[ -n "${write_out}" ]]; then
  printf '%s' "${write_out}" | sed "s/%{http_code}/${code}/g"
else
  printf '%s' "${body}"
fi
EOF
chmod +x "${TMP}/bin/curl"

sed "s|^ROOT=.*|ROOT=\"${TMP}\"|" \
  "${ROOT}/scripts/ci-cloudflare-tunnel-token-prereq.sh" \
  >"${TMP}/prereq.sh"
chmod +x "${TMP}/prereq.sh"

export PATH="${TMP}/bin:${PATH}"

set +e
out="$(bash "${TMP}/prereq.sh" 2>&1)"
ec=$?
set -e

if [[ "${ec}" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit on 403" >&2
  echo "${out}" >&2
  exit 1
fi
if ! echo "${out}" | grep -q "Cloudflare Tunnel → Edit"; then
  echo "FAIL: missing operator guidance in output" >&2
  echo "${out}" >&2
  exit 1
fi
if ! grep -q 'TF_VAR_cloudflare_api_token=' "${GITHUB_ENV}"; then
  echo "FAIL: expected TF_VAR export to GITHUB_ENV" >&2
  exit 1
fi

# Second smoke: Vault path required when env token unset.
unset CLOUDFLARE_API_TOKEN
: >"${GITHUB_ENV}"
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fail Vault miss clearly
for a in "$@"; do
  if [[ "$a" == *"/v1/homelab/data/cloudflare/tunnel-substrate-api"* ]]; then
    echo '{"data":{"data":{}}}'
    exit 0
  fi
done
echo '{}'
exit 0
EOF
chmod +x "${TMP}/bin/curl"
export VAULT_ADDR=https://vault.example.test
export VAULT_TOKEN=test-token

set +e
out2="$(bash "${TMP}/prereq.sh" 2>&1)"
ec2=$?
set -e
if [[ "${ec2}" -eq 0 ]]; then
  echo "FAIL: expected failure when Vault api_token missing" >&2
  echo "${out2}" >&2
  exit 1
fi
if ! echo "${out2}" | grep -q "tunnel-substrate-api"; then
  echo "FAIL: expected Vault path guidance" >&2
  echo "${out2}" >&2
  exit 1
fi
if echo "${out2}" | grep -qi "boto3\|SigV4\|aws CLI"; then
  echo "FAIL: still mentioning AWS SM read path" >&2
  echo "${out2}" >&2
  exit 1
fi

echo "OK: prereq uses Vault (no AWS SM) and fails closed on Tunnel Edit / missing seed"
