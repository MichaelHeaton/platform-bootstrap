# AGENTS.md — platform-bootstrap

Guidance for AI agents and humans working in this repository.

## Purpose

platform-bootstrap is the **platform factory** for personal infrastructure. It provisions
foundational AWS identity, GitHub repositories, and HCP Terraform workspaces for domain
spokes (Cloudflare, Azure, homelab, services) so they can run independently.

It does **not** own domain resources — no Cloudflare DNS records, Azure Entra apps, or
Proxmox VMs live here.

## Credential strategy

> **Prefer credentials that expire in minutes and renew themselves. Use AWS Secrets Manager
> only for what still has to be a stored secret overnight.**

| Tier | Pattern | Examples in this repo |
|---|---|---|
| Ephemeral | OIDC / federated identity — no stored secret | AWS deploy roles for service repos (ADR-002) |
| Short-lived | GitHub App installation tokens (~1 hour, auto-minted) | Terraform `integrations/github` providers |
| Stored | AWS Secrets Manager (scoped IAM per consumer) | `platform-bootstrap/github-app-pem`; `personal/cloudflare-api-token` (DNS, 5 zones); workstation: `personal/linear-api-token`, `personal/notion-api-token` — see runbooks 08–09 |

Do **not** introduce user PATs with manual expiry for Terraform automation. Use a GitHub App
(see runbook 07). Store long-lived material in AWS Secrets Manager (see runbook 08).

## Quick reference

| Task | Command |
|---|---|
| Run Python tests | `pytest scripts/tests/ -v` |
| Structural compliance check | `python3 scripts/compliance_check.py --structural-only` |
| Terraform format check | `terraform -chdir=terraform fmt -check -recursive` |
| Terraform validate | `terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate` |
| Auto-format Terraform | `terraform -chdir=terraform fmt -recursive` |
| All Makefile targets | `make help` |

## Non-obvious caveats

- **GitHub repo creation is managed here — never imperatively**: when asked to create or change a GitHub repository, add or update an entry in `terraform/managed.auto.tfvars`. Use `managed_repositories` for repos under the personal `MichaelHeaton` account; use `specterrealm_repositories` for repos under the `SpecterRealm` org. **Do not** create repositories with `gh repo create`, the GitHub REST API, MCP tool calls (`mcp__github__create_repository`), or any other imperative method. CI/CD will run Terraform plan/apply after the PR is merged. This rule is absolute — no exceptions.
- **New repo requests have an issue form**: prefer using `.github/ISSUE_TEMPLATE/new-repository.yml` as the source of truth for repository name, visibility, default branch, license, Pages, Discussions, and service-account needs. Public repos should include a supported `license` block when added to the relevant repositories list.
- **Terraform init requires `-backend=false`** for local validation. The S3 backend needs real AWS credentials and bucket config, so always use `terraform init -backend=false` when running `validate` or `fmt` locally without AWS access.
- **Python path for pytest**: pytest resolves imports via `sys.path` manipulation in the test files themselves, so running `pytest scripts/tests/ -v` from the repo root works without extra `PYTHONPATH` setup.
- **No `requirements.txt`**: Python dependencies (`pytest`) are installed directly via `pip3 install pytest`. The compliance script's heavy dependencies (`boto3`, `requests`) are optional and only needed for full (non-structural) checks that require AWS/GitHub credentials.
- **Terraform >= 1.10.0 is required** (for S3 native state locking). The update script installs Terraform 1.15.4 to `/usr/local/bin/terraform`. To upgrade, change the version in the update script.
- The `.terraform/` directory created by `terraform init` is gitignored and ephemeral; re-run init after a fresh clone.
- **Two GitHub providers, one GitHub App**: `provider "github"` (default, owner = `MichaelHeaton`) and `provider "github" { alias = "specterrealm" }` (owner = `SpecterRealm`). Both authenticate via the same GitHub App (`github_app_id` + `github_app_pem`) with **different installation IDs** per account/org. HCP workspace variables (terraform category): `github_app_id`, `github_app_pem`, `github_app_installation_id`, `specterrealm_github_app_installation_id`. App setup: `docs/runbooks/07-github-app-auth.md`. PEM canonical store in SM: `platform-bootstrap/github-app-pem` — `docs/runbooks/08-aws-secrets-manager.md`.
- **Domain spokes read SM at plan time**: platform infra repos live under **`McCleaton`** (`mccleaton_repositories`), not SpecterRealm. Example: `McCleaton/cloudflare` reads `personal/cloudflare-api-token` via SM. Set `github_org` on the pipeline entry for OIDC trust — see runbook 09.
- **HCP workspaces are factory-managed**: each `pipelines` entry with `tfe_workspace_enabled` (default true) creates an HCP workspace (`tfe-workspaces` module), TFE dynamic-credentials IAM role (`tfe-roles` module), and `TF_TOKEN_app_terraform_io` on the spoke repo. Requires HCP variable `tfe_vcs_oauth_token_id` on the platform-bootstrap workspace; org API token in SM `platform-bootstrap/tfe-api-token` — `docs/runbooks/08-aws-secrets-manager.md`.
- **platform-bootstrap excludes itself from GitHub Terraform management** (ADR-004). It is the foundation — if broken, repair via HCP UI and local Terraform, not via itself.

## Cursor Cloud specific instructions

This is an infrastructure-as-code (Terraform + Python) repository with no application services to run. Development work involves Terraform configuration and a Python compliance script.
