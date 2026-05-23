.PHONY: init plan apply fmt validate compliance compliance-full lock help

# Read from environment — these map to the GitHub Actions variable names.
BUCKET  ?= $(TF_STATE_BUCKET_NAME)
REGION  ?= $(AWS_REGION)

# Run all terraform commands from the terraform/ subdirectory.
TF := terraform -chdir=terraform

# ── Terraform ─────────────────────────────────────────────────────────────────

init:
	$(TF) init \
		-backend-config="bucket=$(BUCKET)" \
		-backend-config="region=$(REGION)"

plan:
	$(TF) plan

apply:
	$(TF) apply

fmt:
	$(TF) fmt -recursive

validate:
	$(TF) fmt -check -recursive
	$(TF) validate

# Update the lock file for all platforms CI and local dev run on.
# Re-run this whenever provider versions change.
lock:
	$(TF) providers lock \
		-platform=linux_amd64 \
		-platform=darwin_arm64 \
		-platform=darwin_amd64

# ── Compliance ────────────────────────────────────────────────────────────────

# Structural checks only — no AWS credentials required.
compliance:
	python3 scripts/compliance_check.py --structural-only

# Full checks — requires AWS credentials and GITHUB_TOKEN in environment.
compliance-full:
	python3 scripts/compliance_check.py \
		--account-id $(AWS_ACCOUNT_ID) \
		--region $(AWS_REGION) \
		--bucket $(TF_STATE_BUCKET_NAME) \
		--github-org $(GH_ORG)

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "platform-bootstrap — available make targets"
	@echo ""
	@echo "  make init              Initialise Terraform with S3 backend"
	@echo "                         Requires: BUCKET (TF_STATE_BUCKET_NAME) and REGION (AWS_REGION)"
	@echo ""
	@echo "  make plan              Terraform plan"
	@echo "  make apply             Terraform apply"
	@echo "  make fmt               Format all Terraform files in-place"
	@echo "  make validate          Format check + validate (non-destructive)"
	@echo ""
	@echo "  make lock              Regenerate provider lock file for all platforms"
	@echo "                         Run after any provider version change"
	@echo ""
	@echo "  make compliance        Structural checks — no credentials needed"
	@echo "  make compliance-full   Full checks — requires AWS credentials + GITHUB_TOKEN"
	@echo ""
	@echo "Environment variables used by init:"
	@echo "  TF_STATE_BUCKET_NAME   S3 bucket name (mccleaton-tfstate)"
	@echo "  AWS_REGION             AWS region (us-west-2)"
	@echo ""
	@echo "Additional variables used by compliance-full:"
	@echo "  AWS_ACCOUNT_ID, GH_ORG, GITHUB_TOKEN"
	@echo ""
