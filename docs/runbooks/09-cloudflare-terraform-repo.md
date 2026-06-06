# Runbook 09 — Cloudflare Terraform repo

**Estimated time:** ~60 minutes (first time, includes new GitHub org setup)

---

## 1. Overview

The `cloudflare` repository is a **domain spoke** — it owns Cloudflare DNS (and later tunnel/R2)
resources. It lives in the **McCleaton** GitHub org — personal platform infrastructure, separate
from:

| GitHub target | Owns |
|---|---|
| `MichaelHeaton` (user) | Existing personal repos; App cannot **create** new repos here |
| **`McCleaton` (org)** | Platform/domain infra — Cloudflare, future Azure/Cloud spokes |
| `SpecterRealm` (org) | Minecraft mods and Colony Protocol modpacks only |

McCleaton aligns with HCP (`McCleaton-Bootstrap`) and AWS naming (`mccleaton-tfstate`). To use a
different org handle, change `mccleaton_org` in `terraform/variables.tf` and matching pipeline
`github_org` values.

Credential flow (HCP Terraform — factory-managed by platform-bootstrap):

```text
HCP Terraform (McCleaton-Bootstrap/cloudflare) via VCS on McCleaton/cloudflare
  → AWS dynamic credentials (IAM role shared-cloudflare-dns-tfe)
    → SM read personal/cloudflare-api-token
      → Cloudflare provider api_token
```

GitHub Actions on the spoke repo runs **validate only** (fmt + validate). Plan and apply run in
HCP after merge to `main`.

---

## 2. Prerequisites

- [08-aws-secrets-manager.md](./08-aws-secrets-manager.md) — `personal/cloudflare-api-token`
  uploaded and verified
- platform-bootstrap GitHub App auth (runbook 07)
- **McCleaton GitHub org created** and App installed (step 3 below)
- HCP variables on `platform-bootstrap` workspace (steps 2 and 4)
- `gh` CLI authenticated

---

## 3. Steps (in order)

### Step 0 — Create the McCleaton GitHub org (one-time)

1. Go to [github.com/organizations/plan](https://github.com/organizations/plan) → **Create a free
   organization**
2. Owner: your personal account (`MichaelHeaton`)
3. Organization name: **`McCleaton`** (or your chosen handle — update `mccleaton_org` if different)
4. Complete setup (no paid plan required for private repos)

### Step 1 — Install the GitHub App on McCleaton

Using the existing `platform-bootstrap-terraform` app (runbook 07):

1. App settings → **Install App** → select **McCleaton**
2. Repository access: **All repositories**
3. Accept any pending permission requests (org **Administration** write required)
4. Note the **Installation ID** from:
   `https://github.com/organizations/McCleaton/settings/installations/<INSTALLATION_ID>`

### Step 2 — HCP workspace variables (GitHub App)

In `McCleaton-Bootstrap/platform-bootstrap`, add (terraform category):

| Variable | Value |
|---|---|
| `mccleaton_github_app_installation_id` | Installation ID from step 1 |

### Step 3 — Merge platform-bootstrap and apply

Terraform creates `McCleaton/cloudflare`, the legacy GHA OIDC role, and registers the pipeline in
`managed.auto.tfvars`.

> **Branch protection:** GitHub Free orgs cannot enable classic branch protection on **private**
> repos. `cloudflare` sets `branch_protection = false` until McCleaton is upgraded.

### Step 4 — HCP workspace factory variables

In `McCleaton-Bootstrap/platform-bootstrap`, add:

| Variable | Category | Value |
|---|---|---|
| `tfe_vcs_oauth_token_id` | terraform | OAuth token ID from HCP → Organization Settings → VCS Providers (McCleaton GitHub) |

Org-level HCP API token: SM secret `platform-bootstrap/tfe-api-token` (see runbook 08) — not an HCP variable.

One-time: connect **McCleaton** GitHub to HCP VCS if not already linked.

### Step 5 — platform-bootstrap apply creates the spoke workspace

After HCP apply, Terraform (`tfe-workspaces` + `tfe-roles` modules) creates:

- HCP workspace **`cloudflare`** (VCS → `McCleaton/cloudflare`, dir `terraform`)
- IAM role **`shared-cloudflare-dns-tfe`** + SM read policy
- HCP env vars `TFC_AWS_PROVIDER_AUTH` / `TFC_AWS_RUN_ROLE_ARN`
- GitHub secret **`TF_TOKEN_app_terraform_io`** on `McCleaton/cloudflare`

### Step 6 — Push the cloudflare repo scaffold

Ensure `terraform/versions.tf` uses the HCP cloud block (see section 8). Merge
`McCleaton/cloudflare` PR with spoke Terraform + validate-only GHA.

### Step 7 — Add DNS records

Add `cloudflare_record` resources (or `tf-module-dns-record`) per zone via PR.

---

## 4. Pipeline and state layout

| Item | Value |
|---|---|
| GitHub repo | `McCleaton/cloudflare` |
| HCP org / workspace | `McCleaton-Bootstrap` / `cloudflare` |
| Pipeline key (IAM naming) | `shared-cloudflare-dns` |
| Pipeline `github_org` | `McCleaton` |
| HCP AWS role | `shared-cloudflare-dns-tfe` |
| Legacy GHA OIDC role | `shared-cloudflare-dns-github-actions` (retire after S3 state migration) |
| Legacy S3 state key | `shared-cloudflare-dns/terraform.tfstate` |
| SM secret | `personal/cloudflare-api-token` |

---

## 5. Local development

```bash
terraform login
make init plan
```

Use `AWS_PROFILE=platform-bootstrap` for local plan when not using HCP remote execution.

---

## 6. Optional tokens (when needed)

See runbook 08 — **Tunnel** and **R2** tokens are separate secrets. Do not widen the DNS token.

---

## 7. Related

- [07 — GitHub App auth](./07-github-app-auth.md)
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md)
- Repo: `McCleaton/cloudflare`
- HCP: [McCleaton-Bootstrap/cloudflare](https://app.terraform.io/app/McCleaton-Bootstrap/workspaces/cloudflare)

---

## 8. HCP workspace (factory-managed)

platform-bootstrap owns spoke workspaces via `terraform/modules/tfe-workspaces` and
`terraform/modules/tfe-roles`. The `pipelines` entry in `managed.auto.tfvars` drives:

| Factory output | cloudflare spoke |
|---|---|
| HCP workspace | `McCleaton-Bootstrap/cloudflare` |
| TFE IAM role | `shared-cloudflare-dns-tfe` |
| VCS repo | `McCleaton/cloudflare` → `terraform/` |
| GHA validate secret | `TF_TOKEN_app_terraform_io` (set by Terraform) |

Spoke repo `terraform/versions.tf` must use the same workspace name:

```hcl
cloud {
  organization = "McCleaton-Bootstrap"
  workspaces { name = "cloudflare" }
}
```

To add another spoke: extend `pipelines` + `mccleaton_repositories`, merge platform-bootstrap,
HCP apply.

**Import (one-time):** if `app.terraform.io` OIDC provider already exists from manual setup:

```bash
terraform import 'module.tfe_roles[0].aws_iam_openid_connect_provider.terraform_cloud' \
  arn:aws:iam::336090301942:oidc-provider/app.terraform.io
```

### 8.1 Migrate state from S3 (one-time)

If GHA already wrote state to S3 before HCP cutover:

```bash
cd ~/Projects/personal/cloudflare/terraform
terraform login
terraform init -migrate-state
terraform plan   # expect no changes
```

Or upload via HCP UI after:

```bash
aws s3 cp s3://mccleaton-tfstate/shared-cloudflare-dns/terraform.tfstate /tmp/cloudflare.tfstate
```

### 8.2 Verify

1. PR on `McCleaton/cloudflare` → **Terraform Validate** passes
2. Merge platform-bootstrap factory PR → HCP apply creates workspace
3. Merge spoke PR → HCP queues **plan** on `McCleaton-Bootstrap/cloudflare`
4. Confirm plan reads SM and Cloudflare zones; apply when ready
