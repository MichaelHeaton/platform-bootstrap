# Runbook 03 — Disaster Recovery

**Purpose:** Recovery procedures for platform-bootstrap outages, ranging from a lost state file
to complete loss of both GitHub and AWS access.

---

## DECISION TREE

Use this to identify your scenario before reading any further.

```
START HERE — What do you still have access to?

Can you log into GitHub?
├── YES → Can you access the AWS console / CLI?
│   ├── YES → Full access — infrastructure may still be intact
│   │         → Check: is the S3 state bucket accessible?
│   │           aws s3 ls s3://$TF_STATE_BUCKET_NAME
│   │           ├── Bucket accessible, state present  → Scenario 0 (state recovery)
│   │           ├── Bucket accessible, state missing  → Scenario 0 (state recovery)
│   │           └── Bucket missing or access denied   → Scenario 2 (S3 lost)
│   └── NO  → GitHub intact, AWS lost → Scenario 2 (if S3 gone) or credential issue
│             → If OIDC/credentials are just misconfigured (not a true AWS loss),
│               go to Section "Common non-disaster issues" below
└── NO  → Can you access the AWS console / CLI?
    ├── YES → AWS intact, GitHub lost → Scenario 1
    └── NO  → Complete loss of both  → Scenario 3

Quick credential check (run this first if in doubt):
  aws sts get-caller-identity --profile platform-bootstrap
  → Success: AWS access is intact
  → Error "Unable to locate credentials": credential issue, not a disaster
  → Error "AccessDenied": role/user may have been deleted — check IAM console
```

---

## Common Non-Disaster Issues

Check these before escalating to a full disaster scenario. Most "outages" are one of the
following:

| Symptom | Likely cause | Fix |
|---|---|---|
| GitHub Actions fails with `credentials` error | `AWS_ACCOUNT_ID` GitHub variable missing or wrong | Re-check Section 5 of runbook 02 |
| `AssumeRoleWithWebIdentity` denied in CI | OIDC trust policy sub condition wrong | Fix trust policy in IAM console |
| `terraform init` fails with "NoSuchBucket" | `TF_STATE_BUCKET_NAME` variable wrong or region mismatch | Verify variable and region match |
| S3 lock file stuck (`terraform.tfstate.tflock`) | A previous run crashed without releasing the lock | Delete the lock file: `aws s3 rm "s3://$TF_STATE_BUCKET_NAME/platform-bootstrap/terraform.tfstate.tflock"` |
| `terraform plan` shows everything as "will be created" | Backend pointing to empty/wrong state key | Verify `-backend-config` values; check `terraform/backend.tf` key value |

---

## Scenario 0: State File Lost but Infrastructure Intact

**Estimated recovery time:** 30–60 minutes

**What happened:** The S3 state file was deleted or corrupted, but the actual AWS resources
(S3 bucket, OIDC provider, IAM roles) still exist. Terraform does not know about them because
its record of them is gone.

**What you still have:** All AWS infrastructure intact; GitHub repository intact.

**What you cannot automatically recover:** State history and prior state versions unless S3
versioning has preserved them.

### Check whether S3 versioning can help

```bash
export AWS_PROFILE="platform-bootstrap"
export BOOTSTRAP_BUCKET="<your-bucket-name>"  # from TF_STATE_BUCKET_NAME

# List all versions of the state file — a previous version may be intact
aws s3api list-object-versions \
  --bucket "$BOOTSTRAP_BUCKET" \
  --prefix "platform-bootstrap/terraform.tfstate" \
  --query 'Versions[*].{VersionId:VersionId,LastModified:LastModified,IsLatest:IsLatest}'
```

If a previous version exists:

```bash
# Restore the most recent non-deleted version
# Replace VERSION_ID with the VersionId value from the output above
aws s3api copy-object \
  --bucket "$BOOTSTRAP_BUCKET" \
  --copy-source "$BOOTSTRAP_BUCKET/platform-bootstrap/terraform.tfstate?versionId=VERSION_ID" \
  --key "platform-bootstrap/terraform.tfstate"

# Verify by running plan
cd /path/to/platform-bootstrap/terraform
terraform init \
  -backend-config="bucket=$BOOTSTRAP_BUCKET" \
  -backend-config="key=platform-bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION"
terraform plan
# If this shows "No changes" — you are done. Skip the import steps below.
```

### Rebuild state via terraform import

If the state cannot be restored from a version, rebuild it by importing each resource.

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export AWS_REGION="us-east-1"  # your region

cd /path/to/platform-bootstrap/terraform

# Initialise with an empty backend (state will be written back to S3 after import)
terraform init \
  -backend-config="bucket=$BOOTSTRAP_BUCKET" \
  -backend-config="key=platform-bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION"

# Set required Terraform variables
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_aws_account_id="$AWS_ACCOUNT_ID"
export TF_VAR_state_bucket_name="$BOOTSTRAP_BUCKET"
export TF_VAR_github_org="<your-github-org>"
export GITHUB_TOKEN="<your-github-token>"

# -----------------------------------------------------------------------
# Import the S3 state bucket
# -----------------------------------------------------------------------
terraform import module.state_bucket.aws_s3_bucket.state "$BOOTSTRAP_BUCKET"

# Import S3 sub-resources (bucket name is the ID for each)
terraform import module.state_bucket.aws_s3_bucket_versioning.state "$BOOTSTRAP_BUCKET"
terraform import module.state_bucket.aws_s3_bucket_server_side_encryption_configuration.state "$BOOTSTRAP_BUCKET"
terraform import module.state_bucket.aws_s3_bucket_public_access_block.state "$BOOTSTRAP_BUCKET"
terraform import module.state_bucket.aws_s3_bucket_policy.state "$BOOTSTRAP_BUCKET"

# -----------------------------------------------------------------------
# Import the GitHub Actions OIDC provider
# -----------------------------------------------------------------------
terraform import \
  module.oidc_roles.aws_iam_openid_connect_provider.github_actions \
  "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# -----------------------------------------------------------------------
# Import IAM roles and policies for each pipeline
# Role key format: {environment}-{cloud}-{function} (e.g., prod-aws-vpc)
# List all managed roles first:
# -----------------------------------------------------------------------
aws iam list-roles \
  --query 'Roles[?ends_with(RoleName, `-github-actions`)].RoleName' \
  --output text

# For each role (replace PIPELINE_KEY with e.g. "prod-aws-vpc"):
# terraform import 'module.oidc_roles.aws_iam_role.pipeline["PIPELINE_KEY"]' PIPELINE_KEY-github-actions
# terraform import 'module.oidc_roles.aws_iam_policy.pipeline_state["PIPELINE_KEY"]' \
#   "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/PIPELINE_KEY-state-access"

# -----------------------------------------------------------------------
# Import GitHub repositories managed by this repo (if any)
# For each repository in var.managed_repositories:
# terraform import 'module.github_repos.github_repository.repo["REPO_NAME"]' REPO_NAME
# -----------------------------------------------------------------------
```

After importing all resources, run plan to confirm state is consistent:

```bash
terraform plan
# Must show: "No changes. Your infrastructure matches the configuration."
```

If the plan shows unexpected diffs, review each one. Small diffs (tags, description fields) can
usually be resolved by running `terraform apply`. Larger structural diffs may indicate that the
live infrastructure diverged from the Terraform configuration and should be investigated before
applying.

### Verification

- `terraform plan` shows "No changes"
- `aws s3 ls "s3://$BOOTSTRAP_BUCKET/platform-bootstrap/"` shows `terraform.tfstate`
- `python scripts/compliance_check.py --structural-only` shows all PASS

---

## Scenario 1: Lost Access to GitHub — AWS is Intact

**Estimated recovery time:** 1–4 hours

**What happened:** You have lost access to the GitHub repository or your GitHub account. AWS
infrastructure and the S3 state are intact.

**What you cannot automatically recover:** Git history and commit metadata (unless a local clone
exists), pull request and issue history, GitHub Actions workflow run logs, branch protection
settings, GitHub variable configuration.

### Recovery steps

**Step 1: Regain GitHub account access**

If locked out of your GitHub account:
- Use GitHub's account recovery flow at <https://github.com/password_reset>
- If you have 2FA recovery codes, use them now
- As a last resort, contact GitHub Support at <https://support.github.com>
  - Recovery may take hours to days depending on support queue

**Step 2: If the repository was deleted — restore from a local clone**

```bash
# On a developer machine that has a local clone of platform-bootstrap:
cd /path/to/platform-bootstrap

# Create a new repository on GitHub named "platform-bootstrap"
# (via github.com/new — do NOT initialise it with any files)

# Point the local clone at the new remote
git remote set-url origin https://github.com/GITHUB_ORG/platform-bootstrap.git

# Push all branches and tags
git push origin --all
git push origin --tags
```

If no local clone exists, you will need to reconstruct the repository from scratch. In that case
proceed to Scenario 3.

**Step 3: Re-apply branch protection**

Navigate to: `https://github.com/GITHUB_ORG/platform-bootstrap/settings/branches`

- Add branch protection rule for `main`
- Require pull request reviews before merging (1 reviewer)
- Require status checks to pass: `Terraform Plan`, `Compliance Check (AWS)`, `Structural Checks (local)`
- Require branches to be up to date before merging
- Do not allow force pushes

**Step 4: Re-create GitHub variables**

Navigate to: `https://github.com/GITHUB_ORG/platform-bootstrap/settings/variables/actions`

Re-create the variables that were on the repository (values are in AWS, not lost):

```bash
# Retrieve values from AWS to confirm what they should be
aws sts get-caller-identity --query Account --output text   # AWS_ACCOUNT_ID
# AWS_REGION: the region where your resources are deployed
# TF_STATE_BUCKET_NAME: the bucket name — list your S3 buckets if unsure:
aws s3 ls
# GITHUB_ORG: your GitHub org or username
```

| Variable | Where to find the value |
|---|---|
| `AWS_ACCOUNT_ID` | `aws sts get-caller-identity` |
| `TF_STATE_BUCKET_NAME` | `aws s3 ls` — find your opaque state bucket name |
| `AWS_REGION` | Check `terraform/backend.tf` in your local clone or `aws configure get region` |
| `GITHUB_ORG` | Your GitHub organisation or username |

**Step 5: Verify OIDC trust still works**

```bash
cd /path/to/platform-bootstrap/terraform

export AWS_PROFILE="platform-bootstrap"
export BOOTSTRAP_BUCKET="<your-bucket-name>"
export AWS_REGION="us-east-1"

terraform init \
  -backend-config="bucket=$BOOTSTRAP_BUCKET" \
  -backend-config="key=platform-bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION"

export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_state_bucket_name="$BOOTSTRAP_BUCKET"
export TF_VAR_github_org="<your-github-org>"
export GITHUB_TOKEN="<your-token>"

terraform plan
# Must show: "No changes. Your infrastructure matches the configuration."
```

**Step 6: Re-configure CODEOWNERS**

Restore the CODEOWNERS file at `.github/CODEOWNERS` if it was lost:

```
* @YOUR_GITHUB_USERNAME
```

### Verification

- Can open and merge pull requests on `platform-bootstrap`
- `terraform plan` (local) shows "No changes"
- A test PR triggers the `Terraform Plan` workflow and it passes
- All four GitHub variables are present and correct

---

## Scenario 2: S3 Bucket Lost — GitHub is Intact

**Estimated recovery time:** 1–3 hours

**What happened:** The S3 state bucket was deleted (accidentally or otherwise). GitHub is intact,
and AWS account access is intact, but Terraform state is gone and the storage layer must be
recreated.

**What you cannot automatically recover:** Prior state history and state file versions. The
live AWS resources (OIDC provider, IAM roles) may still exist and will need to be imported.

> **Warning:** This scenario means state is lost. Terraform has no record of what it previously
> managed. Proceed carefully — importing resources incorrectly can cause them to be destroyed
> on the next apply.

### Step 1: Create a new S3 bucket

Follow **Section 3** of `docs/runbooks/02-bootstrap.md` exactly, choosing a new opaque bucket name.

```bash
export NEW_BUCKET="<new-opaque-name>"
export AWS_REGION="us-east-1"
export AWS_PROFILE="platform-bootstrap"

# Create, configure, and verify the new bucket per runbook 02 Section 3
```

### Step 2: Update the GitHub variable

Navigate to: `https://github.com/GITHUB_ORG/platform-bootstrap/settings/variables/actions`

Update `TF_STATE_BUCKET_NAME` to the new bucket name.

### Step 3: Initialise Terraform against the new bucket

```bash
cd /path/to/platform-bootstrap/terraform

export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_state_bucket_name="$NEW_BUCKET"
export TF_VAR_github_org="<your-github-org>"
export GITHUB_TOKEN="<your-token>"

terraform init \
  -backend-config="bucket=$NEW_BUCKET" \
  -backend-config="key=platform-bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION"
```

### Step 4: Import existing AWS resources

Check which resources still exist in AWS before importing:

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Check if OIDC provider exists
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[*].Arn' --output text

# Check if the bootstrap IAM role exists
aws iam get-role --role-name "platform-bootstrap-github-actions" 2>/dev/null && echo "EXISTS"

# List pipeline roles
aws iam list-roles \
  --query 'Roles[?ends_with(RoleName, `-github-actions`)].RoleName' \
  --output text
```

Import each resource that exists (see Scenario 0 import commands for syntax). Skip resources
that do not exist — Terraform will create them on the next apply.

### Step 5: Run plan and fix drift

```bash
terraform plan
```

Review the plan carefully:

- Resources shown as "will be created" but that actually exist: import them (go back to Step 4)
- Resources shown as "will be changed": compare the proposed change to the actual configuration
  and decide whether to apply
- Resources shown as "will be destroyed": investigate before applying — this is usually a sign
  that import was incomplete

### Step 6: Apply

```bash
terraform apply
```

### Step 7: End-to-end verification

Push a commit to trigger the GitHub Actions pipeline:

```bash
git checkout -b fix/post-recovery-verification
# Make a trivial change (e.g., update a comment)
git commit -am "chore: post-recovery verification"
git push origin fix/post-recovery-verification
# Open a PR and confirm the Terraform Plan workflow passes
```

### Verification

- `terraform plan` shows "No changes"
- `aws s3 ls "s3://$NEW_BUCKET/platform-bootstrap/"` shows `terraform.tfstate`
- GitHub Actions `Terraform Plan` workflow passes on a test PR
- `python scripts/compliance_check.py --structural-only` shows all PASS

---

## Scenario 3: Complete Loss — Both GitHub and AWS

**Estimated recovery time:** 4–8 hours

**What happened:** You have lost access to both GitHub and AWS. This is the most severe scenario
and requires a full rebuild from scratch.

**What you cannot automatically recover:**
- Git history and commit metadata — unless a team member has a local clone
- Pull request and issue history
- GitHub Actions workflow run logs
- Terraform state history
- Any data stored in resources managed by this repository (the repository itself manages only
  IAM and S3 metadata, not application data)

> **Before proceeding:** Search all team members' machines for a local clone of
> `platform-bootstrap`. If one exists, git history and the Terraform code are recoverable,
> which saves hours. Ask every developer now.

### Step 1: Regain or create AWS access

Follow `docs/runbooks/01-aws-account-setup.md` from the beginning:

- If recovering an existing AWS account (account still exists but credentials are lost):
  - Use AWS root account to log in (root credentials should be in your password manager)
  - Create a new `platform-bootstrap-admin` IAM user
  - Generate new access keys
  - Run `aws configure --profile platform-bootstrap`

- If the AWS account itself is gone (extremely rare; requires contacting AWS Billing):
  - Create a completely new AWS account per Section 3 of runbook 01
  - Complete all root hardening steps

### Step 2: Regain or create GitHub access

- Use GitHub's account recovery flow at <https://github.com/password_reset>
- Contact GitHub Support at <https://support.github.com> if account recovery fails
- If your organisation is gone, you may need to create a new GitHub organisation

### Step 3: Recreate the platform-bootstrap repository

**If a local clone exists on any developer's machine:**

```bash
cd /path/to/local-clone

# Create a new repository named "platform-bootstrap" on GitHub
# (via github.com/new — do NOT initialise with any files)

# Update remote and push
git remote set-url origin https://github.com/NEW_GITHUB_ORG/platform-bootstrap.git
git push origin --all
git push origin --tags
```

**If no local clone exists:**

You must reconstruct the repository from scratch. The Terraform module structure is:

```
terraform/
  backend.tf
  main.tf
  variables.tf
  outputs.tf
  versions.tf
  modules/
    s3-state/
    oidc-roles/
    github-repos/
```

This is a significant undertaking. At minimum you need a working `backend.tf`, `versions.tf`,
the OIDC roles module, and the S3 state module. Refer to any documentation or architecture
decision records (ADRs) your team has preserved offline.

### Step 4: Run the full bootstrap

Follow `docs/runbooks/02-bootstrap.md` completely from the beginning, starting with Section 3.

All infrastructure must be recreated from scratch. There is no state to import — the bucket,
OIDC provider, and IAM roles must all be created new.

### Step 5: Recreate managed GitHub repositories

Any repositories that were managed by this repository's Terraform code (those in
`var.managed_repositories`) will need to be recreated. After the bootstrap apply succeeds,
add them back to the `managed_repositories` variable and apply again.

> **Note:** Recreated repositories will have new repository IDs and no issue/PR history.
> If the code was in a local clone, push it to the new repository. Application data is separate
> and outside the scope of this runbook.

### Mitigation for future incidents

To avoid total loss in future:

- **Keep at least one local clone** on a team member's machine that is pushed to regularly.
  A clone preserves git history even if the remote is gone.
- **Store root AWS credentials and IAM access keys** in a password manager that is backed up
  independently of AWS (e.g., 1Password, Bitwarden with cloud sync).
- **Store the `TF_STATE_BUCKET_NAME` value** in the password manager as well — it is not
  recoverable from Terraform code if the state is gone.
- **Export critical repository data** periodically using `gh repo clone` or GitHub's export
  features if your organisation requires it for compliance purposes.

### Verification

- AWS CLI `aws sts get-caller-identity` returns expected account ID
- `terraform plan` shows "No changes"
- GitHub Actions `Terraform Plan` workflow passes
- `python scripts/compliance_check.py --structural-only` shows all PASS

---

## General Verification Steps

Run these checks after completing any scenario recovery. All must pass.

```bash
# 1. Confirm AWS access is working
aws sts get-caller-identity --profile platform-bootstrap
# Expected: JSON with Account, UserId, Arn

# 2. Confirm Terraform state is consistent
cd /path/to/platform-bootstrap/terraform
terraform plan
# Expected: "No changes. Your infrastructure matches the configuration."

# 3. Confirm structural compliance
cd /path/to/platform-bootstrap
python scripts/compliance_check.py --structural-only
# Expected: all checks PASS

# 4. Confirm S3 state bucket is accessible and state file exists
aws s3 ls "s3://$TF_STATE_BUCKET_NAME/platform-bootstrap/"
# Expected: terraform.tfstate listed

# 5. Confirm the bootstrap IAM role exists
aws iam get-role \
  --role-name "platform-bootstrap-github-actions" \
  --query 'Role.Arn' --output text
# Expected: arn:aws:iam::ACCOUNT_ID:role/platform-bootstrap-github-actions
```

**End-to-end GitHub Actions test:**

1. Create a branch and make a trivial change
2. Open a pull request against `main`
3. Confirm the `Terraform Plan` and `Compliance Check` workflows start and pass
4. This confirms OIDC authentication, S3 backend access, and GitHub variables are all working

---

## Recovery Time Estimates

| Scenario | Description | Best Case | Worst Case | Primary Blocker |
|---|---|---|---|---|
| Scenario 0 | State file lost, infrastructure intact | 30 min | 90 min | Identifying all resource IDs to import |
| Scenario 1 | GitHub lost, AWS intact | 1 hour | 4 hours | GitHub support response time |
| Scenario 2 | S3 bucket lost, GitHub intact | 1 hour | 3 hours | Resource import completeness |
| Scenario 3 | Complete loss of both | 4 hours | 8 hours | AWS account setup + GitHub recovery |

Times assume familiarity with the platform. Add 1–2 hours for first-time recovery by someone
who did not perform the original bootstrap.
