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

Credential flow:

```text
GitHub Actions (OIDC) on McCleaton/cloudflare
  → IAM role shared-cloudflare-dns-github-actions
    → S3 state (shared-cloudflare-dns/*)
    → SM read personal/cloudflare-api-token
      → Cloudflare provider api_token
```

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

### Step 4 — Wire GitHub Actions on the cloudflare repo

```bash
terraform -chdir=terraform output -json pipeline_role_arns | jq -r '."shared-cloudflare-dns"'

gh secret set AWS_ROLE_ARN --repo McCleaton/cloudflare
gh variable set AWS_REGION --body "us-west-2" --repo McCleaton/cloudflare
gh variable set TF_STATE_BUCKET_NAME --body "mccleaton-tfstate" --repo McCleaton/cloudflare
gh variable set AWS_ACCOUNT_ID --body "336090301942" --repo McCleaton/cloudflare
```

### Step 5 — Push the cloudflare repo scaffold

```bash
git clone git@github.com:McCleaton/cloudflare.git
cd cloudflare
git add .
git commit -m "feat: initial Cloudflare DNS Terraform with SM token read"
git push origin main
```

### Step 6 — Add DNS records

Add `cloudflare_record` resources (or `tf-module-dns-record`) per zone via PR.

---

## 4. Pipeline and state layout

| Item | Value |
|---|---|
| GitHub repo | `McCleaton/cloudflare` |
| Pipeline key | `shared-cloudflare-dns` |
| Pipeline `github_org` | `McCleaton` |
| IAM role | `shared-cloudflare-dns-github-actions` |
| S3 state key | `shared-cloudflare-dns/terraform.tfstate` |
| SM secret | `personal/cloudflare-api-token` |

---

## 5. Local development

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2
export TF_STATE_BUCKET_NAME=mccleaton-tfstate

make init plan
```

---

## 6. Optional tokens (when needed)

See runbook 08 — **Tunnel** and **R2** tokens are separate secrets. Do not widen the DNS token.

---

## 7. Related

- [07 — GitHub App auth](./07-github-app-auth.md)
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md)
- Repo: `McCleaton/cloudflare`
