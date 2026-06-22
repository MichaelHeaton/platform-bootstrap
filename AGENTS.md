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
| Stored | AWS Secrets Manager (scoped IAM per consumer) | `platform-bootstrap/github-app-pem`; `platform-bootstrap/tfe-api-token` (HCP org API); `personal/cloudflare-api-token` (DNS, 5 zones); workstation: `personal/linear-api-token`, `personal/notion-api-token` — see runbooks 08–09 |

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
- **Two GitHub providers, one GitHub App**: `provider "github"` (default, owner = `MichaelHeaton`) and `provider "github" { alias = "specterrealm" }` (owner = `SpecterRealm`). Both authenticate via the same GitHub App (`github_app_id` + PEM from SM) with **different installation IDs** per account/org. HCP workspace variables (terraform category): `github_app_id`, `github_app_installation_id`, `specterrealm_github_app_installation_id`, `mccleaton_github_app_installation_id`. App setup: `docs/runbooks/07-github-app-auth.md`. PEM in SM: `platform-bootstrap/github-app-pem` — `docs/runbooks/08-aws-secrets-manager.md`.
- **Domain spokes read SM at plan time**: platform infra repos live under **`McCleaton`** (`mccleaton_repositories`), not SpecterRealm. Example: `McCleaton/cloudflare` reads `personal/cloudflare-api-token` via SM. Set `github_org` on the pipeline entry for OIDC trust — see runbook 09.
- **HCP workspaces are factory-managed**: each `pipelines` entry with `tfe_workspace_enabled` (default true) creates an HCP workspace (`tfe-workspaces` module), TFE dynamic-credentials IAM role (`tfe-roles` module), and `TF_TOKEN_app_terraform_io` on the spoke repo. Requires HCP variable `tfe_vcs_oauth_token_id` on the platform-bootstrap workspace; org API token in SM `platform-bootstrap/tfe-api-token` — `docs/runbooks/08-aws-secrets-manager.md`.
- **New spoke repo + HCP workspace: two PRs, not one**: PR 1 adds only the `*_repositories` entry and merges so apply creates the GitHub repo. PR 2 adds the `pipelines` entry so apply can link the HCP workspace VCS to an existing repo. Combining both in one PR often fails with `Repository doesn't exist or isn't accessible` on the first apply (a second apply usually succeeds, but split PRs avoid the failure). For a new GitHub org, also grant the HCP VCS OAuth provider access to that org before PR 2 — see `docs/runbooks/09-cloudflare-terraform-repo.md` §8.
- **platform-bootstrap excludes itself from GitHub Terraform management** (ADR-004). It is the foundation — if broken, repair via HCP UI and local Terraform, not via itself.

## Homelab factory (`specterrealm-homelab`)

This repo is the **platform factory** for homelab ops. Target rename: **`homelab-platform`**
([homelab-infra #100](https://github.com/specterrealm-homelab/homelab-infra/issues/100)).

**Operator model (2026-06-22):** Two repos for AI + humans — `homelab-platform` + `homelab-infra`.
Operational Terraform lives only in `homelab-infra` (one HCP workspace per `terraform/<stack>/`).

| Action | Issue | Effect on factory |
|--------|-------|-------------------|
| Merge `homelab-vault`, `homelab-identity`, `homelab-observability` into `homelab-infra` | [#102](https://github.com/specterrealm-homelab/homelab-infra/issues/102) | Fewer `github_repository` resources → **lower McCleaton-Bootstrap RUM** |
| Wire `homelab-unifi` through factory | [#103](https://github.com/specterrealm-homelab/homelab-infra/issues/103) | Move workspace from legacy `SpecterRealm-HomeLab` org |
| Gitea on NAS01 | [#90](https://github.com/specterrealm-homelab/homelab-infra/issues/90)–[#93](https://github.com/specterrealm-homelab/homelab-infra/issues/93) | Unblocks LAN-local CI before OpenTofu state migration |

**HCP RUM:** The 500-resource cap is **per HCP Terraform organization**, not summed across orgs.
`McCleaton-Bootstrap` (~395 RUM) and `SpecterRealm-HomeLab` (~106 RUM) are both under cap today;
repo consolidation still reduces headroom pressure on the factory monolith.

**Spoke docs:** [homelab-infra/docs/iac-modernization.md](https://github.com/specterrealm-homelab/homelab-infra/blob/main/docs/iac-modernization.md) · full audit [AUDIT-REPORT.md](https://github.com/specterrealm-homelab/homelab-infra/blob/main/AUDIT-REPORT.md).

When updating homelab pipelines after #102: keep `tfe_workspace_name` unchanged; update `repo_name`
to `homelab-infra` and `terraform_working_directory` to e.g. `terraform/vault`.

## Cursor Cloud specific instructions

This is an infrastructure-as-code (Terraform + Python) repository with no application services to run. Development work involves Terraform configuration and a Python compliance script.
