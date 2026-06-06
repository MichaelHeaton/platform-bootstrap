# Runbook 09 — Cloudflare Terraform repo

**Estimated time:** ~45 minutes (first time)

---

## 1. Overview

The `cloudflare` repository is a **domain spoke** — it owns Cloudflare DNS (and later tunnel/R2)
resources. It does **not** live in platform-bootstrap.

Credential flow:

```text
GitHub Actions (OIDC)
  → IAM role shared-cloudflare-dns-github-actions
    → S3 state (shared-cloudflare-dns/*)
    → SM read personal/cloudflare-api-token
      → Cloudflare provider api_token
```

---

## 2. Prerequisites

- [08-aws-secrets-manager.md](./08-aws-secrets-manager.md) — `personal/cloudflare-api-token`
  uploaded and verified (`platform-terraform-dns`, 5 zones)
- platform-bootstrap GitHub App auth merged and HCP green (runbook 07)
- `gh` CLI authenticated

---

## 3. Steps (in order)

### Step 1 — Merge platform-bootstrap PRs

1. Merge the open **GitHub App + SM docs** PR (`feat/github-app-auth`).
2. Merge the **cloudflare registration** PR (adds `cloudflare` to `managed_repositories`,
   pipeline entry, SM IAM on the pipeline role).
3. Confirm HCP apply is green on `main`.

This creates the empty `MichaelHeaton/cloudflare` GitHub repository and IAM role
`shared-cloudflare-dns-github-actions`.

### Step 2 — Wire GitHub Actions on the cloudflare repo

After apply, read the pipeline role ARN from platform-bootstrap outputs (HCP UI or local
`terraform output pipeline_role_arns`):

```bash
# From platform-bootstrap clone with AWS/HCP access
terraform -chdir=terraform output -json pipeline_role_arns | jq -r '."shared-cloudflare-dns"'
```

Set repository configuration on `MichaelHeaton/cloudflare`:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | ARN from output above |
| Variable | `AWS_REGION` | `us-west-2` |
| Variable | `TF_STATE_BUCKET_NAME` | e.g. `mccleaton-tfstate` |
| Variable | `AWS_ACCOUNT_ID` | `336090301942` |

```bash
gh secret set AWS_ROLE_ARN --repo MichaelHeaton/cloudflare
gh variable set AWS_REGION --body "us-west-2" --repo MichaelHeaton/cloudflare
gh variable set TF_STATE_BUCKET_NAME --body "mccleaton-tfstate" --repo MichaelHeaton/cloudflare
gh variable set AWS_ACCOUNT_ID --body "336090301942" --repo MichaelHeaton/cloudflare
```

### Step 3 — Push the cloudflare repo

Clone the (initially empty) repo and push the scaffold from your workstation:

```bash
git clone git@github.com:MichaelHeaton/cloudflare.git
cd cloudflare
# Copy scaffold from your platform-bootstrap PR branch or merge commit
git add .
git commit -m "feat: initial Cloudflare DNS Terraform with SM token read"
git push origin main
```

### Step 4 — First plan

Open a PR or push to `main`. The `Terraform Plan` workflow should:

- Assume the OIDC role
- Read `personal/cloudflare-api-token` from SM
- Run `terraform plan` with zero or minimal changes (zone data sources only on first run)

### Step 5 — Add DNS records

Add `cloudflare_record` resources (or use `tf-module-dns-record`) per zone. Keep zone-scoped
changes in PRs with plan output review.

---

## 4. Pipeline and state layout

| Item | Value |
|---|---|
| Pipeline key | `shared-cloudflare-dns` |
| IAM role | `shared-cloudflare-dns-github-actions` |
| S3 state key | `shared-cloudflare-dns/terraform.tfstate` |
| SM secret | `personal/cloudflare-api-token` |

---

## 5. Local development

```bash
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=us-west-2
export TF_STATE_BUCKET_NAME=mccleaton-tfstate

cd terraform
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET_NAME" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="key=shared-cloudflare-dns/terraform.tfstate" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

terraform plan
```

The Cloudflare token is read from SM at plan time — no `CLOUDFLARE_API_TOKEN` export needed
when AWS credentials can reach the secret.

---

## 6. Optional tokens (when needed)

See runbook 08 — **Tunnel** and **R2** tokens are separate secrets with separate pipeline IAM
grants. Do not add tunnel/R2 permissions to `platform-terraform-dns`.

| Token | When to add |
|---|---|
| Tunnel | Homelab `cloudflared` / `tf-module-cloudflare-tunnel` automation |
| R2 | Memex file storage buckets on Cloudflare R2 |

---

## 7. Related

- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md)
- `AGENTS.md` — platform factory vs domain spokes
- Repo: `MichaelHeaton/cloudflare`
