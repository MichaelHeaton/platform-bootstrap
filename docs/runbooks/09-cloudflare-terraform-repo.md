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

Credential flow (HCP Terraform):

```text
HCP Terraform (McCleaton-Bootstrap/cloudflare) via VCS on McCleaton/cloudflare
  → AWS dynamic credentials (IAM role shared-cloudflare-dns-tfe)
    → SM read personal/cloudflare-api-token
      → Cloudflare provider api_token
```

GitHub Actions on the repo runs **validate only** (fmt + validate). Plan and apply are **not**
in GHA — they run in HCP after merge to `main`.

Legacy GHA OIDC role `shared-cloudflare-dns-github-actions` (S3 state) remains in AWS until
state is migrated off S3; do not run GHA apply after HCP cutover.

---

## 2. Prerequisites

- [08-aws-secrets-manager.md](./08-aws-secrets-manager.md) — `personal/cloudflare-api-token`
  uploaded and verified
- platform-bootstrap GitHub App auth (runbook 07)
- **McCleaton GitHub org created** and App installed (step 3 below)
- HCP variable `mccleaton_github_app_installation_id` set
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

### Step 2 — HCP workspace variable

In `McCleaton-Bootstrap/platform-bootstrap`, add (terraform category):

| Variable | Value |
|---|---|
| `mccleaton_github_app_installation_id` | Installation ID from step 1 |

### Step 3 — Merge platform-bootstrap PR and apply

1. Merge #53 (cloudflare registration) — done.
2. Merge #54 (McCleaton org module + IAM fix).
3. Confirm HCP apply is green.

Terraform creates `McCleaton/cloudflare`, the OIDC pipeline role, and SM read on the state policy.

> **Branch protection:** GitHub Free orgs cannot enable classic branch protection on **private**
> repos (requires Team/Enterprise or public visibility). `cloudflare` sets
> `branch_protection = false` until McCleaton is upgraded. Rely on PR workflow discipline meanwhile.

### Step 4 — HCP Terraform workspace (plan + apply)

See **section 8** below. Complete before relying on VCS-driven applies.

### Step 5 — Wire GitHub Actions (validate only)

```bash
# HCP API token for terraform init -backend=false in PR validate workflow
gh secret set TF_TOKEN_app_terraform_io --repo McCleaton/cloudflare
```

Do **not** set `AWS_ROLE_ARN` for plan/apply — HCP uses workspace dynamic credentials.

### Step 6 — Push the cloudflare repo scaffold

```bash
git clone git@github.com:McCleaton/cloudflare.git
cd cloudflare
git add .
git commit -m "feat: initial Cloudflare DNS Terraform with SM token read"
git push origin main
```

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
| HCP AWS role | `shared-cloudflare-dns-tfe` (dynamic credentials) |
| Legacy GHA OIDC role | `shared-cloudflare-dns-github-actions` (S3 — retire after migration) |
| Legacy S3 state key | `shared-cloudflare-dns/terraform.tfstate` |
| SM secret | `personal/cloudflare-api-token` |

---

## 5. Local development

```bash
terraform login
make init plan
```

Use `AWS_PROFILE=platform-bootstrap` when running local plan if not using HCP remote execution.

---

## 6. Optional tokens (when needed)

See runbook 08 — **Tunnel** and **R2** tokens are separate secrets. Do not widen the DNS token.

---

## 8. HCP Terraform workspace setup

### 8.1 Create workspace

1. Open [McCleaton-Bootstrap](https://app.terraform.io/app/McCleaton-Bootstrap/workspaces)
2. **New workspace** → **Version control workflow**
3. Connect **McCleaton** GitHub App / OAuth (same org as `McCleaton/cloudflare`)
4. Repository: `McCleaton/cloudflare`, branch `main`
5. **Terraform working directory:** `terraform`
6. Workspace name: **`cloudflare`**
7. Auto-apply: **off** (apply on merge via manual run or enable later)

Confirm `terraform/versions.tf` contains:

```hcl
cloud {
  organization = "McCleaton-Bootstrap"
  workspaces { name = "cloudflare" }
}
```

### 8.2 AWS dynamic provider credentials

Use [HCP AWS quick setup](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/aws-configuration/quick-setup)
or configure manually:

1. **IAM OIDC provider** for `https://app.terraform.io` (if not already present from
   `platform-bootstrap` setup)
2. **IAM role** `shared-cloudflare-dns-tfe` with trust policy scoped to:
   - `organization:McCleaton-Bootstrap`
   - `workspace:cloudflare`
3. **Attach policy** allowing SM read on `personal/cloudflare-api-token` (same actions as the
   GHA pipeline role: `GetSecretValue`, `DescribeSecret`, `GetResourcePolicy`)

Workspace **environment** variables (category env, not terraform):

| Variable | Value |
|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_RUN_ROLE_ARN` | `arn:aws:iam::336090301942:role/shared-cloudflare-dns-tfe` |

Optional workspace **terraform** variables:

| Variable | Value |
|---|---|
| `aws_region` | `us-west-2` |

### 8.3 GitHub validate secret

```bash
gh secret set TF_TOKEN_app_terraform_io --repo McCleaton/cloudflare
# Token: HCP → User settings → Tokens → API token (org: McCleaton-Bootstrap)
```

### 8.4 Migrate state from S3 (one-time)

If GHA already wrote state to S3:

```bash
cd ~/Projects/personal/cloudflare
export AWS_PROFILE=platform-bootstrap

# Temporarily init against S3 to pull state (if cloud block not yet merged, skip)
# After cloud block is merged:
terraform login
cd terraform
terraform init -migrate-state
# Confirm migration into McCleaton-Bootstrap/cloudflare workspace
terraform plan   # expect no changes
```

Alternatively: **HCP UI → workspace → States → upload** after downloading from S3:

```bash
aws s3 cp s3://mccleaton-tfstate/shared-cloudflare-dns/terraform.tfstate /tmp/cloudflare.tfstate
```

### 8.5 Verify

1. Open a trivial PR on `McCleaton/cloudflare` → **Terraform Validate** passes
2. Merge → HCP queues **plan** on `McCleaton-Bootstrap/cloudflare`
3. Confirm plan reads SM and Cloudflare zones; apply when ready

---

## 7. Related

- [07 — GitHub App auth](./07-github-app-auth.md)
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md)
- Repo: `McCleaton/cloudflare`
- HCP: [McCleaton-Bootstrap/cloudflare](https://app.terraform.io/app/McCleaton-Bootstrap/workspaces/cloudflare)
