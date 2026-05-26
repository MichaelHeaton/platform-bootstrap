# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- SpecterRealm pack GitHub settings for `minecraft-modpack-cp-verdant`
  - Discussions + `ideas` / `mod-suggestions` categories (`scripts/github_repo_extras.py`)
  - Pack issue labels and optional `main` ruleset (deletion + non-fast-forward)
  - Runbook: `docs/runbooks/05-specterrealm-pack-github-settings.md`
- Initial Terraform module structure for S3 state storage (ADR-001, ADR-003)
  - Single S3 bucket with versioning, encryption, and HTTPS-only bucket policy
  - Flat `{environment}-{cloud}-{function}/terraform.tfstate` key convention
  - `prevent_destroy = true` lifecycle rule to guard against accidental deletion
- OIDC authentication module for GitHub Actions to AWS (ADR-002)
  - `aws_iam_openid_connect_provider` resource for `token.actions.githubusercontent.com`
  - Per-pipeline IAM roles with trust conditions scoped to exact repo and ref
  - Least-privilege S3 policies scoped to each pipeline's state path prefix
- GitHub repository management module (ADR-004)
  - `github_repository` resource for all managed repositories
  - Branch protection on `main`: PR required, stale review dismissal, CODEOWNERS review required
  - Validation rule rejecting any repository list that includes `platform-bootstrap`
- S3 native state locking via `use_lockfile = true` — no DynamoDB table required (ADR-007)
- Compliance drift detection script at `scripts/compliance_check.py` (ADR-005)
  - `--structural-only` mode runs without credentials on every PR
  - Full mode checks live AWS resource configuration and GitHub repository settings
  - Plain-English output with exact remediation commands for each failing check
  - `pytest` test suite in `scripts/tests/`
- GitHub Actions workflows
  - `terraform-plan.yml` — runs on PRs touching `terraform/**`; posts plan as PR comment
  - `terraform-apply.yml` — runs on merge to `main`; applies the approved plan
  - `compliance-check.yml` — scheduled and on-PR compliance drift detection
  - `pre-publication-audit.yml` — blocks repository visibility changes to `public` without human approval
- Runbooks
  - `docs/runbooks/01-aws-account-setup.md` — AWS account prerequisites and IAM bootstrap user setup
  - `docs/runbooks/02-bootstrap.md` — first-run sequence: local apply, state migration to S3, GitHub variable setup
  - `docs/runbooks/03-disaster-recovery.md` — procedures for corrupted state, deleted bucket, and locked state
- Architecture Decision Records
  - ADR-001: S3 for Terraform Remote State Storage
  - ADR-002: OIDC Authentication for GitHub Actions to AWS (No Static Credentials)
  - ADR-003: Single S3 Bucket with Flat Folder Structure for All Terraform State
  - ADR-004: Manage All GitHub Repositories via Terraform (Except platform-bootstrap)
  - ADR-005: Python Script for Compliance Drift Detection (Not OPA or Checkov)
  - ADR-006: Terraform Modules as Subdirectories (Not Separate Repos)
  - ADR-007: S3 Native State Locking over DynamoDB
- CODEOWNERS enforcement requiring `@MichaelHeaton` review on all changes
- `.gitignore` excluding Terraform state files, `.tfvars`, `.terraform/` directories, and
  plan artifacts from version control

## [0.1.0] - 2026-05-23

Initial bootstrap release. S3 state bucket, OIDC provider, and CI IAM role
all bootstrapped manually and imported into Terraform state. All compliance
checks passing. `v0.1.0` tagged on `main` after merge.
