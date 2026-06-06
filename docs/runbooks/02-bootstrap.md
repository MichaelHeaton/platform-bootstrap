# Runbook 02 — Bootstrap

**Estimated time:** ~90 minutes (first time) / ~20 minutes (re-bootstrap from existing infrastructure)

---

## 1. Overview

### What this runbook bootstraps

| Layer | Purpose |
|---|---|
| **S3 state bucket** | Shared bucket for legacy spoke state paths and compliance checks |
| **GitHub Actions OIDC** | `platform-bootstrap-github-actions` — validate + compliance workflows |
| **HCP Terraform OIDC** | `platform-bootstrap-tfe` — plan/apply with AWS dynamic credentials |
| **Secrets Manager** | Canonical store for GitHub App PEM and HCP org API token |
| **HCP workspace** | `McCleaton-Bootstrap/platform-bootstrap` — remote state + VCS-driven runs |

### Execution model (after bootstrap)

```text
Pull request → GitHub Actions
                 ├── Terraform Validate (fmt + validate)
                 └── Compliance Check (structural + optional AWS read-only)

Merge to main → HCP Terraform (VCS)
                 └── plan / apply via platform-bootstrap-tfe → SM read at runtime
```

Do **not** use GitHub Actions for Terraform plan/apply on this repo. HCP owns that path.

### The chicken-and-egg problem

Several dependencies reference each other:

1. **S3 bucket** must exist before Terraform can manage spoke state paths — but the bucket is
   created by Terraform.
2. **HCP workspace** holds `platform-bootstrap` state — but Terraform configures the workspace
   factory that creates other workspaces.
3. **SM secrets** (`github-app-pem`, `tfe-api-token`) are read at plan time — but IAM to read
   them is attached by Terraform to `platform-bootstrap-tfe`, which HCP must assume first.

### How we solve it

1. Create the **S3 bucket** and **bootstrap IAM roles** manually (Sections 3–5).
2. Upload **SM secrets** and configure the **HCP workspace** (Sections 6–7).
3. Run **Terraform locally** with `AWS_PROFILE=platform-bootstrap` for the first apply — local
   credentials read SM and create resources HCP cannot yet manage alone.
4. Connect **VCS** on the HCP workspace; subsequent changes flow through PR → HCP plan/apply.

After step 4, bootstrap is complete. Further changes go through pull requests — this procedure
is not repeated unless disaster recovery requires it ([03-disaster-recovery.md](./03-disaster-recovery.md)).

**Related runbooks (complete in parallel or immediately after):**

- [07 — GitHub App authentication](./07-github-app-auth.md) — App, installs, HCP workspace vars
- [08 — AWS Secrets Manager](./08-aws-secrets-manager.md) — PEM and org API token upload

---

## 2. Prerequisites

> **Complete [01-aws-account-setup.md](./01-aws-account-setup.md) before proceeding.**

You need:

- **AWS CLI** — profile `platform-bootstrap` tested with `aws sts get-caller-identity`
- **Terraform >= 1.10** — `terraform version` must show v1.10+
- **Terraform Cloud login** — `terraform login` (token for `app.terraform.io`)
- **Git clone** of `MichaelHeaton/platform-bootstrap`
- **HCP Terraform org** — `McCleaton-Bootstrap` with permission to create workspaces
- **GitHub App** — created and installed per runbook 07 (App ID + three installation IDs)
- **SM secrets** — `platform-bootstrap/github-app-pem` and `platform-bootstrap/tfe-api-token`
  uploaded per runbook 08

**GitHub repository variables** (non-secret — Section 8):

| Variable | Example |
|---|---|
| `AWS_ACCOUNT_ID` | `336090301942` |
| `TF_STATE_BUCKET_NAME` | `mccleaton-tfstate` |
| `AWS_REGION` | `us-west-2` |
| `GH_ORG` | `MichaelHeaton` |

**Do not** set `GITHUB_TOKEN` or fine-grained PATs for Terraform — GitHub App auth replaces them
(runbook 07).

---

## 3. Creating the S3 Bootstrap Bucket Manually

The S3 bucket must exist before Terraform can reference it for spoke state paths. Create it once
via AWS CLI.

> **Bucket naming:** Globally unique, 3–63 chars, lowercase. `{owner}-tfstate` works well.
> See ADR-003.

```bash
export BOOTSTRAP_BUCKET="mccleaton-tfstate"
export AWS_REGION="us-west-2"
export AWS_PROFILE="platform-bootstrap"

# us-east-1: omit --create-bucket-configuration
aws s3api create-bucket \
  --bucket "$BOOTSTRAP_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "$BOOTSTRAP_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BOOTSTRAP_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block \
  --bucket "$BOOTSTRAP_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api get-bucket-versioning --bucket "$BOOTSTRAP_BUCKET"
```

Record the bucket name — it becomes `TF_STATE_BUCKET_NAME` and `TF_VAR_state_bucket_name`.

> **Note:** `platform-bootstrap` workspace state lives in **HCP**, not this S3 key. The bucket
> remains for spoke legacy paths, compliance checks, and service artifact storage.

---

## 4. GitHub Actions IAM (OIDC)

GHA workflows authenticate via OIDC. Create the provider and
`platform-bootstrap-github-actions` role before CI can run.

### 4a. Create the GitHub Actions OIDC provider

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list \
    "6938fd4d98bab03faadb97b34396831e3780aea1" \
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
```

### 4b. Trust policy

Save as `/tmp/gha-trust-policy.json`. Replace `ACCOUNT_ID` and `GITHUB_ORG`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:GITHUB_ORG/platform-bootstrap:*"
        }
      }
    }
  ]
}
```

### 4c. Permissions policy (initial bootstrap scope)

Save as `/tmp/gha-bootstrap-policy.json`. Replace `BUCKET_NAME`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListStateFolder",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["platform-bootstrap/", "platform-bootstrap/*"]
        }
      }
    },
    {
      "Sid": "ReadWriteStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/platform-bootstrap/*"
    }
  ]
}
```

### 4d. Create the role

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export GH_ORG="MichaelHeaton"

# macOS: sed -i '' 's/...'  |  Linux: sed -i 's/...'
sed -i.bak "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" /tmp/gha-trust-policy.json
sed -i.bak "s/GITHUB_ORG/$GH_ORG/g" /tmp/gha-trust-policy.json
sed -i.bak "s/BUCKET_NAME/$BOOTSTRAP_BUCKET/g" /tmp/gha-bootstrap-policy.json

aws iam create-role \
  --role-name "platform-bootstrap-github-actions" \
  --assume-role-policy-document file:///tmp/gha-trust-policy.json \
  --description "Assumed by GitHub Actions for platform-bootstrap (validate + compliance)"

POLICY_ARN=$(aws iam create-policy \
  --policy-name "platform-bootstrap-state-access" \
  --policy-document file:///tmp/gha-bootstrap-policy.json \
  --query 'Policy.Arn' --output text)

aws iam attach-role-policy \
  --role-name "platform-bootstrap-github-actions" \
  --policy-arn "$POLICY_ARN"
```

Terraform expands this role's permissions after the first apply (`bootstrap_ci_management` policy).

---

## 5. HCP Terraform IAM (OIDC)

HCP plan/apply assumes **`platform-bootstrap-tfe`** via dynamic credentials. This role must
exist **before** HCP runs that read SM secrets.

Terraform references the role with `data "aws_iam_role" "platform_bootstrap_tfe"` — it is **not**
created by Terraform (bootstrap exception).

### 5a. Create the HCP OIDC provider

Skip if `app.terraform.io` provider already exists (check IAM → Identity providers).

```bash
aws iam create-open-id-connect-provider \
  --url "https://app.terraform.io" \
  --client-id-list "aws.workload.identity" \
  --thumbprint-list "a689f1cff185a16420bf1bcbbd2e2668c3cb37a6"
```

### 5b. Trust policy for `platform-bootstrap-tfe`

Save as `/tmp/tfe-trust-policy.json`. Replace `ACCOUNT_ID`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/app.terraform.io"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "app.terraform.io:aud": "aws.workload.identity"
        },
        "StringLike": {
          "app.terraform.io:sub": [
            "organization:McCleaton-Bootstrap:workspace:platform-bootstrap:run_phase:*",
            "organization:McCleaton-Bootstrap:project:*:workspace:platform-bootstrap:run_phase:*"
          ]
        }
      }
    }
  ]
}
```

### 5c. Create the role

```bash
sed -i.bak "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" /tmp/tfe-trust-policy.json

aws iam create-role \
  --role-name "platform-bootstrap-tfe" \
  --assume-role-policy-document file:///tmp/tfe-trust-policy.json \
  --description "Assumed by HCP Terraform for platform-bootstrap workspace runs"
```

After the first Terraform apply, the managed policy `platform-bootstrap-tfe-secrets-access`
grants `secretsmanager:GetSecretValue` on `platform-bootstrap/*`.

> **First factory apply:** if HCP apply fails with `CreatePolicy` or `CreateOpenIDConnectProvider`
> denied on `platform-bootstrap-tfe`, attach a **temporary** inline policy with the minimum IAM
> permissions needed for the workspace factory (`tfe-roles`, `tfe-workspaces` modules). Remove
> temp inline policies once apply is stable.

---

## 6. Secrets Manager

Upload canonical secrets **before** the first HCP plan that uses GitHub or TFE providers.

| Secret | Purpose |
|---|---|
| `platform-bootstrap/github-app-pem` | GitHub App private key |
| `platform-bootstrap/tfe-api-token` | HCP org API token (workspace factory + `tfe` provider) |

Full upload commands: [08-aws-secrets-manager.md](./08-aws-secrets-manager.md).

Verify:

```bash
aws secretsmanager describe-secret --secret-id platform-bootstrap/github-app-pem --query Name
aws secretsmanager describe-secret --secret-id platform-bootstrap/tfe-api-token --query Name
```

**No** `github_app_pem` or `tfe_api_token` HCP workspace variables — Terraform reads SM at
plan time.

---

## 7. HCP workspace setup

Create workspace **`platform-bootstrap`** in org **`McCleaton-Bootstrap`**.

### 7a. Connect VCS

1. HCP → Organization Settings → **VCS Providers** → GitHub (Custom OAuth or GitHub App)
2. Workspace → **Version control** → `MichaelHeaton/platform-bootstrap`, directory `terraform`
3. Set `tfe_vcs_oauth_token_id` as a workspace variable (terraform category)

Details: [07-github-app-auth.md](./07-github-app-auth.md) §4.

### 7b. Workspace variables (12 total — no secrets)

**Terraform category:**

| Variable | Notes |
|---|---|
| `aws_account_id` | 12-digit account ID |
| `aws_region` | e.g. `us-west-2` |
| `github_org` | `MichaelHeaton` |
| `github_app_id` | GitHub App ID |
| `github_app_installation_id` | MichaelHeaton install |
| `mccleaton_github_app_installation_id` | McCleaton org install |
| `specterrealm_github_app_installation_id` | SpecterRealm org install |
| `state_bucket_name` | e.g. `mccleaton-tfstate` |
| `tfe_vcs_oauth_token_id` | VCS OAuth token ID |

**Environment category** (AWS dynamic credentials):

| Variable | Value |
|---|---|
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_RUN_ROLE_ARN` | `arn:aws:iam::ACCOUNT_ID:role/platform-bootstrap-tfe` |
| `TFC_AWS_WORKLOAD_IDENTITY_AUDIENCE` | `aws.workload.identity` |

Use HCP **Quick setup → AWS dynamic credentials** or set manually.

### 7c. Remote backend

`terraform/versions.tf` pins the workspace:

```hcl
cloud {
  organization = "McCleaton-Bootstrap"
  workspaces { name = "platform-bootstrap" }
}
```

No S3 backend configuration for this repo.

---

## 8. GitHub repository variables

Navigate to: `https://github.com/MichaelHeaton/platform-bootstrap/settings/variables/actions`

| Variable | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your account ID |
| `TF_STATE_BUCKET_NAME` | Bucket from Section 3 |
| `AWS_REGION` | Same as HCP `aws_region` |
| `GH_ORG` | `MichaelHeaton` |

These are **variables**, not secrets — safe to appear in workflow logs.

Add GitHub Actions secret **`TF_TOKEN_app_terraform_io`** on `platform-bootstrap` if not already
set (HCP user/team token for `terraform init` in validate workflow). The factory also sets this
on spoke repos.

---

## 9. Running the Terraform bootstrap sequence

### Local first apply (recommended for greenfield)

Use local AWS credentials to break the SM/IAM chicken-and-egg. State writes to HCP after
`terraform init` with the cloud block.

```bash
cd /path/to/platform-bootstrap/terraform

terraform login
export AWS_PROFILE="platform-bootstrap"
export AWS_REGION="us-west-2"

export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_state_bucket_name="$BOOTSTRAP_BUCKET"
export TF_VAR_github_org="$GH_ORG"

# From runbook 07 — installation IDs only; PEM comes from SM
export TF_VAR_github_app_id="<app-id>"
export TF_VAR_github_app_installation_id="<michaelheaton-install>"
export TF_VAR_mccleaton_github_app_installation_id="<mccleaton-install>"
export TF_VAR_specterrealm_github_app_installation_id="<specterrealm-install>"
export TF_VAR_tfe_vcs_oauth_token_id="<oauth-token-id>"

terraform init
terraform plan -out=bootstrap.tfplan

# Review: creates/reconciles S3 module, OIDC roles, GitHub repos, factory modules, etc.
terraform apply bootstrap.tfplan
```

**Expected on first apply:**

- S3 bucket imported or created via `module.state_bucket`
- GitHub Actions OIDC provider reconciled (may replace manual provider from Section 4)
- `platform-bootstrap-tfe-secrets-access` policy attached to pre-created role
- HCP workspace factory resources if `tfe_management_enabled = true`

### HCP-driven runs (steady state)

After VCS is connected:

1. Open PR → **Terraform Validate** + **Compliance Check** in GHA
2. Merge → HCP **plan** on `McCleaton-Bootstrap/platform-bootstrap`
3. Review and **apply** in HCP

---

## 10. Verification

**HCP plan clean:**

```bash
# Queue plan in HCP UI or push an empty commit; expect no changes
```

**Local structural check:**

```bash
cd /path/to/platform-bootstrap
python scripts/compliance_check.py --structural-only
```

**Pull request CI:**

1. Branch + trivial change → open PR
2. Confirm **Terraform Validate**, **Structural Checks**, and **Compliance Check (AWS)** pass
3. Confirm HCP speculative plan succeeds on the PR commit

**IAM roles exist:**

```bash
aws iam get-role --role-name platform-bootstrap-github-actions --query Role.Arn
aws iam get-role --role-name platform-bootstrap-tfe --query Role.Arn
```

**SM readable from HCP:** plan output shows no `AccessDenied` on `aws_secretsmanager_secret_version`.

---

## 11. Break-glass: partial failure recovery

### Apply fails mid-way

Do not delete HCP state. Retry `terraform apply` — Terraform is idempotent.

### HCP cannot read SM (`AccessDenied`)

1. Confirm `platform-bootstrap-tfe` role exists (Section 5)
2. Confirm `platform-bootstrap-tfe-secrets-access` policy is attached (after first apply)
3. Temporarily attach inline SM read on `platform-bootstrap-tfe` if policy not yet created

### HCP dynamic creds fail (`AssumeRoleWithWebIdentity`)

1. Verify `TFC_AWS_*` env vars on the workspace (Section 7b)
2. Verify trust policy includes **both** sub patterns (with and without `project:*`)
3. Verify `TFC_AWS_WORKLOAD_IDENTITY_AUDIENCE` = `aws.workload.identity`

### OIDC trust policy wrong for GitHub Actions

If GHA fails with `AssumeRoleWithWebIdentity` denied:

1. IAM → Roles → `platform-bootstrap-github-actions` → Trust relationships
2. Fix `sub` to `repo:MichaelHeaton/platform-bootstrap:*`
3. Re-run workflow; reconcile with Terraform apply

### Terraform plan shows unexpected destroys

**Do not apply.** Import existing resources or investigate state drift — see
[03-disaster-recovery.md](./03-disaster-recovery.md) Scenario 0.

### Migrating legacy S3 state to HCP

If upgrading from an older bootstrap that used S3 backend for this repo:

```bash
terraform login
terraform init
# Only if lineages differ and resources match:
terraform state push -force /path/to/exported/terraform.tfstate
```

Prefer a clean plan in HCP over forced push if state already matches.

### Complete loss

See [03-disaster-recovery.md](./03-disaster-recovery.md) — Scenario 3.

---

## 12. Next steps

Bootstrap complete. Typical follow-on:

1. [07 — GitHub App auth](./07-github-app-auth.md) — verify installs and permissions
2. [08 — AWS Secrets Manager](./08-aws-secrets-manager.md) — rotation procedures
3. [09 — Cloudflare Terraform repo](./09-cloudflare-terraform-repo.md) — first domain spoke
4. [04 — Add a service](./04-add-service.md) — Lambda/deploy OIDC pattern
5. [#63 — Post-cloudflare housekeeping](https://github.com/MichaelHeaton/platform-bootstrap/issues/63)

Future infrastructure changes are made via pull requests — the bootstrap procedure is not
repeated unless recovering from disaster.

Optional: tag the bootstrap completion commit:

```bash
git tag v0.1.0
git push origin v0.1.0
```
