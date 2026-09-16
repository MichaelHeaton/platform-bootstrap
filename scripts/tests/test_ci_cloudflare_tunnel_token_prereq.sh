#!/usr/bin/env bash
# Smoke-test ci-cloudflare-tunnel-token-prereq.sh without AWS/Cloudflare.
# Run: bash scripts/tests/test_ci_cloudflare_tunnel_token_prereq.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/bin" "${TMP}/terraform"
printf 'kb_mcp_tunnel_id = "6b14bcf0-99db-450f-b978-00b4b6eed214"\n' \
  >"${TMP}/terraform/kb_mcp.auto.tfvars"

cat >"${TMP}/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "dns-only-fake-token"
EOF
chmod +x "${TMP}/bin/aws"

# curl: verify OK, zones OK, configurations 403
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
else
  body='{"success":false}'
  code="500"
fi

if [[ -n "${out}" ]]; then
  printf '%s' "${body}" >"${out}"
fi
if [[ -n "${write_out}" ]]; then
  # shellcheck disable=SC2059
  printf "${write_out}" | sed "s/%{http_code}/${code}/g"
else
  printf '%s' "${body}"
fi
EOF
chmod +x "${TMP}/bin/curl"

# Use a copy of the script with ROOT rewritten to TMP
sed "s|^ROOT=.*|ROOT=\"${TMP}\"|" \
  "${ROOT}/scripts/ci-cloudflare-tunnel-token-prereq.sh" \
  >"${TMP}/prereq.sh"
chmod +x "${TMP}/prereq.sh"

export PATH="${TMP}/bin:${PATH}"
export AWS_REGION=us-west-2

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

echo "OK: prereq fails closed with Tunnel Edit guidance"
