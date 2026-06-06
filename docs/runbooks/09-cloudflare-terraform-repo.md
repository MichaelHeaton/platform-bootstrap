# Runbook 09 — Cloudflare Terraform repo

**Estimated time:** ~60 minutes (first time, includes new GitHub org setup)

**Status (2026-06-06):** Rollout **complete**. HCP workspace `cloudflare` runs plan/apply on VCS;
23 DNS records imported across 5 zones ([McCleaton/cloudflare#2](https://github.com/McCleaton/cloudflare/pull/2)).

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

## 2. Prerequisites (one-time)

| Prerequisite | Runbook / note |
|---|---|
| `personal/cloudflare-api-token` in SM | [08](./08-aws-secrets-manager.md) |
| GitHub App on McCleaton | [07](./07-github-app-auth.md) — `mccleaton_github_app_installation_id` |
| HCP `tfe_vcs_oauth_token_id` on platform-bootstrap | [07](./07-github-app-auth.md) — GitHub.com (Custom) VCS provider |
| `platform-bootstrap/tfe-api-token` in SM | [08](./08-aws-secrets-manager.md) — not an HCP variable |
| McCleaton org + factory apply | Steps 0–5 below (done) |

---

## 3. Bootstrap steps (one-time — completed)

### Step 0 — Create the McCleaton GitHub org

[github.com/organizations/plan](https://github.com/organizations/plan) → org **`McCleaton`**.

### Step 1 — Install the GitHub App on McCleaton

Runbook 07 → note **Installation ID** → HCP variable `mccleaton_github_app_installation_id`.

### Step 2 — HCP workspace factory variables (platform-bootstrap)

| Variable | Category | Notes |
|---|---|---|
| `mccleaton_github_app_installation_id` | terraform | McCleaton install ID |
| `tfe_vcs_oauth_token_id` | terraform | OAuth token ID from VCS provider |

Org API token: SM `platform-bootstrap/tfe-api-token` (not HCP).

### Step 3 — platform-bootstrap apply

Creates `McCleaton/cloudflare`, pipeline IAM, HCP workspace factory resources. PRs
[#59](https://github.com/MichaelHeaton/platform-bootstrap/pull/59),
[#60](https://github.com/MichaelHeaton/platform-bootstrap/pull/60).

> **Branch protection:** GitHub Free orgs cannot enable classic branch protection on **private**
> repos. `cloudflare` sets `branch_protection = false` until McCleaton is upgraded.

### Step 4 — Merge cloudflare HCP cutover

[McCleaton/cloudflare#1](https://github.com/McCleaton/cloudflare/pull/1) — HCP `cloud` block,
validate-only GHA.

### Step 5 — Factory outputs (verify in HCP / GitHub)

- HCP workspace **`cloudflare`** (VCS → `McCleaton/cloudflare`, dir `terraform`)
- IAM role **`shared-cloudflare-dns-tfe`** + SM read policy
- HCP env vars: `TFC_AWS_PROVIDER_AUTH`, `TFC_AWS_RUN_ROLE_ARN`, `TFC_AWS_WORKLOAD_IDENTITY_AUDIENCE`, `aws_region`
- GitHub Actions secret **`TF_TOKEN_APP_TERRAFORM_IO`** (validate workflow only)

### Step 6 — Import DNS records

[McCleaton/cloudflare#2](https://github.com/McCleaton/cloudflare/pull/2) — 23 `cloudflare_dns_record`
resources in `terraform/dns_*.tf`. One-time import: `make import-dns` (see §8.3).

---

## 4. Ongoing workflow

1. Branch on `McCleaton/cloudflare`
2. Edit `terraform/dns_*.tf` (or add new zone file)
3. PR → GHA **Terraform Validate**
4. Merge → HCP **plan** on `McCleaton-Bootstrap/cloudflare`
5. Review and **apply** in HCP when plan is acceptable

Do not use GHA for plan/apply — legacy `AWS_ROLE_ARN` / S3 state path is retired.

---

## 5. Pipeline and state layout

| Item | Value |
|---|---|
| GitHub repo | `McCleaton/cloudflare` |
| HCP org / workspace | `McCleaton-Bootstrap` / `cloudflare` |
| Pipeline key (IAM naming) | `shared-cloudflare-dns` |
| Pipeline `github_org` | `McCleaton` |
| HCP AWS role | `shared-cloudflare-dns-tfe` |
| State | HCP workspace (not S3) |
| Legacy S3 state key | `shared-cloudflare-dns/terraform.tfstate` (archived) |
| Legacy GHA OIDC role | `shared-cloudflare-dns-github-actions` (optional cleanup) |
| SM secret | `personal/cloudflare-api-token` |
| Managed zones | `heatons.me`, `mccleaton.com`, `specterrealm.com`, `spicyaccountants.fun`, `the-blackhole.com` |
| DNS records in TF | 23 (Outlook mail + homelab A on specterrealm) |

---

## 6. Local development

```bash
terraform login
make init plan
```

Use `AWS_PROFILE=platform-bootstrap` for local plan when not using HCP remote execution.

---

## 7. Optional tokens (when needed)

See runbook 08 — **Tunnel** and **R2** tokens are separate secrets. Do not widen the DNS token.

---

## 8. HCP workspace (factory-managed)

platform-bootstrap owns spoke workspaces via `terraform/modules/tfe-workspaces` and
`terraform/modules/tfe-roles`. The `pipelines` entry in `managed.auto.tfvars` drives factory
outputs.

Spoke `terraform/versions.tf` must use the same workspace name:

```hcl
cloud {
  organization = "McCleaton-Bootstrap"
  workspaces { name = "cloudflare" }
}
```

TFE IAM trust policy must accept **both** OIDC sub formats (HCP projects):

```text
organization:McCleaton-Bootstrap:workspace:cloudflare:run_phase:*
organization:McCleaton-Bootstrap:project:*:workspace:cloudflare:run_phase:*
```

Factory module `tfe-roles` encodes this from PR [#60](https://github.com/MichaelHeaton/platform-bootstrap/pull/60).

To add another spoke: extend `pipelines` + `mccleaton_repositories`, merge platform-bootstrap,
HCP apply.

**Import (one-time):** if `app.terraform.io` OIDC provider already exists from manual setup:

```bash
terraform import 'module.tfe_roles[0].aws_iam_openid_connect_provider.terraform_cloud' \
  arn:aws:iam::336090301942:oidc-provider/app.terraform.io
```

### 8.1 State cutover (one-time — done)

HCP does **not** support `terraform init -migrate-state` from S3. Records were already present
in the HCP workspace after the first successful plan; no `state push` was required.

If you ever need to seed HCP state from a local/S3 file:

```bash
aws s3 cp s3://mccleaton-tfstate/shared-cloudflare-dns/terraform.tfstate /tmp/cloudflare.tfstate
cd ~/Projects/personal/cloudflare/terraform
terraform login && terraform init
terraform state push -force /tmp/cloudflare.tfstate   # only if lineages differ; prefer import-dns
```

### 8.2 DNS import (one-time — done)

From `McCleaton/cloudflare` repo:

```bash
terraform login
make init
make import-dns    # 23 records → HCP remote state
make plan          # expect no changes
```

TXT records use Cloudflare's quoted form in `content` (e.g. `"v=spf1 ... ~all"`). Match live
API values or plan will show in-place updates.

### 8.3 Verify

- [x] PR → **Terraform Validate** passes
- [x] HCP plan reads SM + all 5 zones
- [x] 23 DNS records imported; plan shows **no changes**
- [x] Merge to `main` → HCP VCS plan clean

---

## 9. Follow-ups (optional)

| Item | Notes |
|---|---|
| `www` CNAMEs / DMARC | Cloudflare dashboard recommendations |
| GitHub Pages TXT on mccleaton.com | Removed from TF — not in API; re-add if Pages verification needed |
| Retire legacy GHA secret `AWS_ROLE_ARN` | No longer used for apply |
| Tunnel / R2 spokes | Separate SM tokens + pipeline entries (runbook 08) |
| Notion repo catalogue row | workstation-devops sync payload |

---

## 10. Related

- [07 — GitHub App auth](./07-github-app-auth.md)
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md)
- Repo: [McCleaton/cloudflare](https://github.com/McCleaton/cloudflare)
- HCP: [McCleaton-Bootstrap/cloudflare](https://app.terraform.io/app/McCleaton-Bootstrap/workspaces/cloudflare)
