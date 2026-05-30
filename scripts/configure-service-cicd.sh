#!/usr/bin/env bash
# configure-service-cicd.sh
#
# Reads service account outputs from Terraform and configures each service
# repo's GitHub Actions secrets and variables in one pass.
#
# What it sets on each service repo:
#   Secret  → AWS_DEPLOY_ROLE_ARN   IAM role the deploy workflow assumes via OIDC
#   Variable → AWS_SAM_BUCKET        S3 bucket for SAM deployment artifacts
#
# Both values come from platform-bootstrap Terraform outputs. Running this
# script replaces all the manual "go set a secret in GitHub" steps.
#
# Usage:
#   ./scripts/configure-service-cicd.sh [--dry-run]
#
# Prerequisites:
#   - terraform apply completed in terraform/ (outputs must be available)
#   - gh CLI authenticated:  gh auth status
#   - jq installed:          jq --version
#   - AWS credentials active: aws sts get-caller-identity
#
# Safe to re-run: gh secret set and gh variable set are idempotent.

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
skip() { echo "  ~ $* (dry-run)"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

# ── Preflight ──────────────────────────────────────────────────────────────────

command -v gh  >/dev/null 2>&1 || fail "gh CLI not found. Install: brew install gh"
command -v jq  >/dev/null 2>&1 || fail "jq not found. Install: brew install jq"
command -v terraform >/dev/null 2>&1 || fail "terraform not found."

gh auth status >/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"

echo ""
echo "configure-service-cicd"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
$DRY_RUN && echo "  MODE: dry-run — no changes will be made"
echo ""

# ── Read Terraform outputs ─────────────────────────────────────────────────────

TF_DIR="$(cd "$(dirname "$0")/.." && pwd)/terraform"
[[ -d "$TF_DIR" ]] || fail "terraform/ directory not found at $TF_DIR"

log "Reading Terraform outputs from $TF_DIR ..."

# Outputs are maps keyed by service name, e.g.:
#   service_deploy_role_arns    = { "memex-suite" = "arn:aws:iam::..." }
#   service_artifact_buckets    = { "memex-suite" = "memex-suite-sam-artifacts" }
DEPLOY_ROLES=$(terraform -chdir="$TF_DIR" output -json service_deploy_role_arns 2>/dev/null) \
  || fail "Could not read service_deploy_role_arns output. Has terraform apply been run?"

SAM_BUCKETS=$(terraform -chdir="$TF_DIR" output -json service_artifact_buckets 2>/dev/null) \
  || fail "Could not read service_artifact_buckets output."

GH_ORG=$(terraform -chdir="$TF_DIR" output -json github_org 2>/dev/null | tr -d '"') \
  || fail "Could not read github_org output."

REPO_NAMES=$(terraform -chdir="$TF_DIR" output -json service_repo_names 2>/dev/null) \
  || fail "Could not read service_repo_names output."

SERVICES=$(echo "$DEPLOY_ROLES" | jq -r 'keys[]')

if [[ -z "$SERVICES" ]]; then
  echo "  No service accounts found in Terraform outputs. Nothing to configure."
  exit 0
fi

echo "  GitHub org:  $GH_ORG"
echo "  Services:    $(echo "$SERVICES" | tr '\n' ' ')"
echo ""

# ── Configure each service repo ────────────────────────────────────────────────

ERRORS=0

while IFS= read -r service; do
  echo "── $service ──────────────────────────────────"
  repo_name=$(echo "$REPO_NAMES" | jq -r ".\"${service}\"")
  if [[ -z "$repo_name" || "$repo_name" == "null" ]]; then
    echo "  ✗ No repo_name found for $service" >&2
    (( ERRORS++ )) || true
    continue
  fi
  repo="${GH_ORG}/${repo_name}"

  role_arn=$(echo "$DEPLOY_ROLES" | jq -r ".\"${service}\"")
  bucket=$(echo "$SAM_BUCKETS"   | jq -r ".\"${service}\"")

  if [[ -z "$role_arn" || "$role_arn" == "null" ]]; then
    echo "  ✗ No deploy role ARN found for $service" >&2
    (( ERRORS++ )) || true
    continue
  fi

  # Check repo exists on GitHub
  if ! gh repo view "$repo" >/dev/null 2>&1; then
    echo "  ✗ Repo $repo not found on GitHub — skipping" >&2
    (( ERRORS++ )) || true
    continue
  fi

  # AWS_DEPLOY_ROLE_ARN — secret (sensitive: it's a role ARN in your account)
  if $DRY_RUN; then
    skip "Would set secret  AWS_DEPLOY_ROLE_ARN = ${role_arn}"
    skip "Would set variable AWS_SAM_BUCKET      = ${bucket}"
  else
    gh secret set AWS_DEPLOY_ROLE_ARN \
      --repo "$repo" \
      --body "$role_arn" \
      && ok "Secret  AWS_DEPLOY_ROLE_ARN set" \
      || { echo "  ✗ Failed to set AWS_DEPLOY_ROLE_ARN" >&2; (( ERRORS++ )) || true; }

    gh variable set AWS_SAM_BUCKET \
      --repo "$repo" \
      --body "$bucket" \
      && ok "Variable AWS_SAM_BUCKET     set" \
      || { echo "  ✗ Failed to set AWS_SAM_BUCKET" >&2; (( ERRORS++ )) || true; }
  fi

done <<< "$SERVICES"

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
if (( ERRORS > 0 )); then
  echo "  ✗ Completed with $ERRORS error(s). Fix the issues above and re-run."
  exit 1
else
  $DRY_RUN \
    && echo "  ~ Dry-run complete. Re-run without --dry-run to apply." \
    || echo "  ✓ All service repos configured. CI/CD is ready."
fi
echo ""
