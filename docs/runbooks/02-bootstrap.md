# Runbook 02 — Bootstrap

**Estimated time:** ~60 minutes (first time) / ~15 minutes (re-bootstrap from existing infrastructure)

---

## 1. Overview

### The chicken-and-egg problem

This repository uses S3 for Terraform remote state. But the S3 bucket that holds that state is
*itself* managed by Terraform. You cannot initialise Terraform with a remote S3 backend if the
bucket does not yet exist, and you cannot create the bucket via Terraform if you have nowhere to
store state.

### How we solve it

1. **Create the S3 bucket manually** via AWS CLI — once, before Terraform runs.
2. **Run Terraform with local state** (`-backend=false`) to create the OIDC provider and IAM roles.
3. **Migrate local state to S3** — Terraform copies the local `terraform.tfstate` file into the
   bucket, then all subsequent runs use S3 as the backend.

After step 3, the bootstrap is complete and all further changes go through normal pull requests
against the `main` branch.

---

## 2. Prerequisites

> **Complete `docs/runbooks/01-aws-account-setup.md` before proceeding.**
> This runbook assumes that runbook is finished and all its verification steps have passed.

You need:

- **AWS CLI configured** — named profile `platform-bootstrap` created and tested with
  `aws sts get-caller-identity`
- **Terraform >= 1.10** installed locally — this repo requires `use_lockfile = true` which was
  introduced in Terraform 1.10
- **Git clone** of this repository (`platform-bootstrap`) on your local machine
- **GitHub variables** set on the `platform-bootstrap` repository (see Section 5):
  - `AWS_ACCOUNT_ID` — your 12-digit AWS account ID
  - `TF_STATE_BUCKET_NAME` — the bucket name you will create in Section 3
  - `AWS_REGION` — AWS region (e.g., `us-east-1`)
  - `GH_ORG` — your GitHub organisation or username
- **GitHub token** with `repo` permissions — needed for the GitHub Terraform provider to manage
  repositories. Set as the environment variable `GITHUB_TOKEN` before running Terraform.

**Verify Terraform version:**

```bash
terraform version
# Must show: Terraform v1.10.x or higher
```

---

## 3. Creating the S3 Bootstrap Bucket Manually

The S3 bucket must exist before Terraform can use it as a backend. Create it now via AWS CLI.

> **Bucket naming:** Bucket names are globally unique across all AWS accounts and must be 3–63
> characters, lowercase letters, numbers, and hyphens only. A `{owner}-tfstate` pattern works
> well — unique in practice, recognisable in billing reports and CLI output. See ADR-003 for
> the full naming rationale.

```bash
# Set your bucket name — this value goes into the TF_STATE_BUCKET_NAME GitHub variable
# Pattern: {owner}-tfstate  e.g. mccleaton-tfstate
export BOOTSTRAP_BUCKET="mccleaton-tfstate"

# Set region and profile
export AWS_REGION="us-west-2"           # or your chosen region
export AWS_PROFILE="platform-bootstrap" # profile from runbook 01

# -----------------------------------------------------------------------
# Create the bucket
# NOTE: For us-east-1, omit --create-bucket-configuration entirely.
# For all other regions, include the LocationConstraint flag shown below.
# -----------------------------------------------------------------------

# If your region is us-east-1:
aws s3api create-bucket \
  --bucket "$BOOTSTRAP_BUCKET" \
  --region "$AWS_REGION"

# If your region is NOT us-east-1 (e.g., eu-west-1, ap-southeast-2):
aws s3api create-bucket \
  --bucket "$BOOTSTRAP_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# -----------------------------------------------------------------------
# Enable versioning — required for state history and recovery
# -----------------------------------------------------------------------
aws s3api put-bucket-versioning \
  --bucket "$BOOTSTRAP_BUCKET" \
  --versioning-configuration Status=Enabled

# -----------------------------------------------------------------------
# Enable server-side encryption (AES-256 with bucket key)
# -----------------------------------------------------------------------
aws s3api put-bucket-encryption \
  --bucket "$BOOTSTRAP_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# -----------------------------------------------------------------------
# Block all public access — state buckets must never be public
# -----------------------------------------------------------------------
aws s3api put-public-access-block \
  --bucket "$BOOTSTRAP_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# -----------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------
echo "--- Versioning ---"
aws s3api get-bucket-versioning --bucket "$BOOTSTRAP_BUCKET"
# Expected: {"Status": "Enabled"}

echo "--- Public access block ---"
aws s3api get-public-access-block --bucket "$BOOTSTRAP_BUCKET"
# Expected: all four values true

echo "--- Encryption ---"
aws s3api get-bucket-encryption --bucket "$BOOTSTRAP_BUCKET"
# Expected: SSEAlgorithm AES256
```

Once verified, record the bucket name — you will use it in Sections 5 and 6, and it becomes the
value of the `TF_STATE_BUCKET_NAME` GitHub variable.

---

## 4. Creating the Initial IAM Role Manually

The GitHub Actions workflows in this repository authenticate to AWS via OIDC. Before Terraform
can run in CI, the OIDC provider and the `platform-bootstrap-github-actions` IAM role must exist
in AWS. You will create them manually here; Terraform will take them under management in Section 6.

### 4a. Create the OIDC provider

```bash
# Create the GitHub Actions OIDC provider in your AWS account.
# Both thumbprints are listed — GitHub rotates certificates and both are valid.
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list \
    "6938fd4d98bab03faadb97b34396831e3780aea1" \
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
```

Note the ARN returned — it will look like:
`arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com`

### 4b. Create the trust policy document

Save the following as `/tmp/trust-policy.json`. Replace `ACCOUNT_ID` with your 12-digit AWS
account ID and `GH_ORG` with your GitHub organisation or username.

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

### 4c. Create the permissions policy document

Save the following as `/tmp/bootstrap-policy.json`. Replace `BUCKET_NAME` with your actual bucket
name from Section 3.

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

### 4d. Create the IAM role and attach the policy

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export GH_ORG="<your-github-org-or-username>"

# Substitute real values into the trust policy
sed -i "s/ACCOUNT_ID/$AWS_ACCOUNT_ID/g" /tmp/trust-policy.json
sed -i "s/GH_ORG/$GH_ORG/g" /tmp/trust-policy.json

# Substitute bucket name into the permissions policy
sed -i "s/BUCKET_NAME/$BOOTSTRAP_BUCKET/g" /tmp/bootstrap-policy.json

# Create the IAM role
aws iam create-role \
  --role-name "platform-bootstrap-github-actions" \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --description "Assumed by GitHub Actions for the platform-bootstrap repository"

# Create the permissions policy
POLICY_ARN=$(aws iam create-policy \
  --policy-name "platform-bootstrap-state-access" \
  --policy-document file:///tmp/bootstrap-policy.json \
  --query 'Policy.Arn' \
  --output text)

echo "Policy ARN: $POLICY_ARN"

# Attach the policy to the role
aws iam attach-role-policy \
  --role-name "platform-bootstrap-github-actions" \
  --policy-arn "$POLICY_ARN"

# Verify
aws iam get-role --role-name "platform-bootstrap-github-actions" \
  --query 'Role.RoleName' --output text
# Expected: platform-bootstrap-github-actions
```

> **Note:** Terraform will import and manage this role after the bootstrap apply in Section 6.
> The role's trust policy and attached policy will be reconciled to exactly match the Terraform
> configuration. Do not add extra policies to this role manually.

---

## 5. Setting Up GitHub Variables

The GitHub Actions workflows read configuration from repository-level variables (not secrets).
These variables are visible in workflow logs — do not store sensitive values here.

**Navigate to:** `https://github.com/GITHUB_ORG/platform-bootstrap/settings/variables/actions`

Or: Repository → **Settings** → **Secrets and variables** → **Actions** → **Variables** tab

Create the following variables by clicking **New repository variable** for each:

| Variable name | Value | Notes |
|---|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit account ID | From `aws sts get-caller-identity` |
| `TF_STATE_BUCKET_NAME` | The bucket name from Section 3 | e.g. `mccleaton-tfstate` |
| `AWS_REGION` | e.g., `us-east-1` | Must match the region used in Section 3 |
| `GH_ORG` | Your GitHub org or username | Case-sensitive |

> **Variables vs Secrets:** These are repository *variables*, not *secrets*. Values appear in
> plaintext in workflow logs. This is intentional — none of these values are sensitive credentials.
> The actual AWS credentials are obtained via OIDC at runtime and are never stored.

---

## 6. Running the Terraform Bootstrap Sequence

```bash
# Navigate to the terraform directory in your local clone
cd /path/to/platform-bootstrap/terraform

# Ensure you have a GitHub token for the GitHub Terraform provider
export GITHUB_TOKEN="<your-github-token>"  # repo permissions required

# Ensure AWS profile is set
export AWS_PROFILE="platform-bootstrap"

# -----------------------------------------------------------------------
# Step 1: Initialise with local state — no S3 backend yet
# The -backend=false flag tells Terraform to skip backend initialisation
# and use local state only for this run.
# -----------------------------------------------------------------------
terraform init -backend=false

# -----------------------------------------------------------------------
# Step 2: Set Terraform variables
# These match the variable declarations in terraform/variables.tf
# -----------------------------------------------------------------------
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_state_bucket_name="$BOOTSTRAP_BUCKET"
export TF_VAR_github_org="$GH_ORG"

# Confirm values before proceeding
echo "Region:  $TF_VAR_aws_region"
echo "Account: $TF_VAR_aws_account_id"
echo "Bucket:  $TF_VAR_state_bucket_name"
echo "Org:     $TF_VAR_github_org"

# -----------------------------------------------------------------------
# Step 3: Plan and review
# The plan creates the OIDC provider and all IAM roles defined in
# terraform/modules/oidc-roles/main.tf. Review it carefully.
# -----------------------------------------------------------------------
terraform plan -out=bootstrap.tfplan

# Read the plan output carefully before proceeding:
#   - It should show resources being created, not destroyed
#   - The OIDC provider (aws_iam_openid_connect_provider.github_actions) will
#     be marked as "will be created" — this is correct because Terraform does
#     not yet know about the one you created manually in Section 4a
#   - After apply, Terraform will own the OIDC provider; the manual one you
#     created will be REPLACED (same ARN, same configuration)
# WARNING: If the plan shows unexpected destroys, stop and investigate.

# -----------------------------------------------------------------------
# Step 4: Apply
# -----------------------------------------------------------------------
terraform apply bootstrap.tfplan
```

After a successful apply, Terraform will have:
- Taken ownership of the S3 bucket (via `module.state_bucket`)
- Taken ownership of the OIDC provider (via `module.oidc_roles`)
- Created or reconciled all IAM roles defined in `var.pipelines`
- Created or updated any GitHub repositories in `var.managed_repositories`

---

## 7. Migrating Local State to S3

The local `terraform.tfstate` file now holds the state of the bootstrap run. Migrate it to S3
so that all future runs (local and CI) use the shared remote backend.

```bash
# Still in the terraform/ directory with TF_VAR_* and AWS_PROFILE set

# -----------------------------------------------------------------------
# Reconfigure the backend to point to the S3 bucket.
# Terraform will detect that state exists locally and prompt you to copy it.
# The key is fixed in backend.tf: platform-bootstrap/terraform.tfstate
# -----------------------------------------------------------------------
terraform init -reconfigure \
  -backend-config="bucket=$BOOTSTRAP_BUCKET" \
  -backend-config="key=platform-bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION"

# Terraform will print:
#   "Do you want to copy existing state to the new backend?"
#
# Type: yes
#
# Terraform will upload the state file to S3 and switch the backend.
```

**Verify the migration succeeded before deleting local state:**

```bash
# List the S3 prefix — you should see the state file
aws s3 ls "s3://$BOOTSTRAP_BUCKET/platform-bootstrap/"
# Expected output (file names may vary slightly):
#   terraform.tfstate
#   terraform.tfstate.tflock   (if a lock was recently held)

# Run plan against the remote backend to confirm state is intact
terraform plan
# Expected: "No changes. Your infrastructure matches the configuration."
```

**Only after confirming the plan shows no changes, remove local state:**

```bash
# Remove local state files if they still exist
# These are safe to delete ONLY after the migration is verified above
rm -f terraform.tfstate terraform.tfstate.backup
```

> **Warning:** Do not delete `terraform.tfstate` until the S3 plan shows "No changes." If you
> delete local state before verifying the migration, you may need to recover from Section 9 or
> from `docs/runbooks/03-disaster-recovery.md`.

---

## 8. Verification

Run all of the following checks. All must pass before the bootstrap is considered complete.

**Remote state is working:**

```bash
cd /path/to/platform-bootstrap/terraform
terraform plan
# Must show: "No changes. Your infrastructure matches the configuration."
```

**Structural compliance check (no AWS credentials required):**

```bash
cd /path/to/platform-bootstrap
python scripts/compliance_check.py --structural-only
# All checks must show PASS
```

**Open a test pull request to verify GitHub Actions:**

1. Create a branch: `git checkout -b test/verify-oidc`
2. Make a trivial change (e.g., add a comment to `terraform/main.tf`)
3. Push and open a PR against `main`
4. Confirm the `Terraform Plan` workflow fires and completes — this proves OIDC authentication
   is working end-to-end
5. Close the PR without merging (or merge it if the change is harmless)

**IAM role exists and is assumable:**

```bash
aws iam get-role \
  --role-name "platform-bootstrap-github-actions" \
  --query 'Role.Arn' \
  --output text
# Expected: arn:aws:iam::ACCOUNT_ID:role/platform-bootstrap-github-actions
```

---

## 9. Break-Glass: Partial Failure Recovery

Follow these steps if something goes wrong during the bootstrap.

### Apply fails mid-way

Do **not** delete the local `terraform.tfstate` file. Try `terraform apply` again — Terraform is
idempotent and will skip resources it already created successfully. Provider API errors (rate
limits, transient failures) are almost always safe to retry.

If the same error repeats, read the error message carefully before taking any other action.

### State migration fails

The local `terraform.tfstate` is still intact. Check the S3 bucket permissions:

```bash
# Verify the bucket exists and is accessible
aws s3 ls "s3://$BOOTSTRAP_BUCKET/"

# Verify the IAM role has the correct permissions
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):user/platform-bootstrap-admin" \
  --action-names "s3:PutObject" \
  --resource-arns "arn:aws:s3:::$BOOTSTRAP_BUCKET/platform-bootstrap/terraform.tfstate"
```

### OIDC trust policy is wrong

If the GitHub Actions workflow fails with an authentication error (`sts:AssumeRoleWithWebIdentity`
denied), update the trust policy directly in the IAM console:

1. Navigate to **IAM** → **Roles** → `platform-bootstrap-github-actions`
2. Click the **Trust relationships** tab → **Edit trust policy**
3. Correct the `sub` condition to match `repo:MichaelHeaton/platform-bootstrap:*`
4. Save and re-run the workflow
5. Run `terraform apply` locally to reconcile the trust policy back to Terraform management

### Terraform plan shows unexpected destroys

If the plan proposes destroying the S3 bucket or OIDC provider, **do not apply.** This usually
means the state does not match reality. Investigate by importing the existing resource:

```bash
# Example: re-import the S3 bucket if it shows as "will be created" but already exists
terraform import module.state_bucket.aws_s3_bucket.state "$BOOTSTRAP_BUCKET"

# Example: re-import the OIDC provider
terraform import \
  module.oidc_roles.aws_iam_openid_connect_provider.github_actions \
  "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/token.actions.githubusercontent.com"
```

### Need to start completely over

See `docs/runbooks/03-disaster-recovery.md` — **Scenario 3**.

---

## 10. Next Steps

Bootstrap is complete.

Tag this commit as the initial release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This marks the point at which the platform was fully bootstrapped and operational. Future
infrastructure changes are made via pull requests — the bootstrap procedure is not repeated.
