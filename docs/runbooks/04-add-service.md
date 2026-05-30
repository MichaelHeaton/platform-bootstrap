# Runbook 04 — Add a New Service

**Estimated time:** ~20 minutes (after platform-bootstrap apply is green)

---

## 1. Overview

Adding a new service to the platform involves three steps:

1. **Register the service in platform-bootstrap** — Terraform creates the S3 artifacts bucket,
   Lambda permission boundary, and GitHub Actions OIDC deploy role.
2. **Apply platform-bootstrap** — merge a PR, CI applies on merge to `main`.
3. **Wire the service repo** — run the `configure-service-cicd` script to push the role ARN and
   bucket name into the service repo's GitHub Actions secrets and variables.

The service repo itself is never allowed to create its own IAM roles or buckets. All of that is
owned here in platform-bootstrap. This is the intentional security boundary: the service cannot
escalate its own permissions or delete its own artifact store.

---

## 2. Prerequisites

- `make apply` has been run at least once (bootstrap is complete — see runbook 02)
- `gh` CLI authenticated: `gh auth status`
- `jq` installed: `jq --version`
- Active AWS credentials: `aws sts get-caller-identity`
- The target service repo already exists on GitHub

---

## 3. Register the Service in Terraform

Open `terraform/managed.auto.tfvars` and add an entry to the `service_accounts` list:

```hcl
service_accounts = [
  # existing entries ...
  {
    service_name         = "my-new-service"           # used as the IAM/resource prefix
    repo_name            = "my-new-service"           # GitHub repo name (case-sensitive)
    artifact_bucket_name = "my-new-service-sam-artifacts"
    allowed_ref          = "refs/heads/main"          # branch that can trigger deploys
  },
]
```

**Naming rules:**
- `service_name` becomes the prefix for all AWS resources: IAM role, boundary policy, S3 bucket.
  Keep it short, lowercase, hyphen-separated.
- `artifact_bucket_name` must be globally unique across all AWS accounts. The
  `{service_name}-sam-artifacts` pattern works well.
- `allowed_ref` is the Git ref that the OIDC trust policy permits. Only pushes/merges to this
  ref can assume the deploy role.

---

## 4. Open a Pull Request

```bash
git checkout -b add-service/my-new-service
git add terraform/managed.auto.tfvars
git commit -m "chore: add my-new-service service account"
git push -u origin add-service/my-new-service
gh pr create --fill
```

The `Terraform Plan` workflow fires automatically. Review the plan in the PR — it should show:

- `aws_s3_bucket.artifacts` — will be created
- `aws_iam_policy.lambda_boundary` — will be created
- `aws_iam_role.deploy` + `aws_iam_policy.deploy` — will be created
- No destroys or unexpected changes to existing resources

> **If the plan shows any destroys to existing service accounts**, stop and investigate before
> merging. A destroy of `prevent_destroy = true` resources will fail at apply time, but it is
> better to catch it in the plan.

---

## 5. Merge and Apply

Merge the PR. The `Terraform Apply` workflow fires automatically on merge to `main` and creates
the AWS resources.

**Verify the apply succeeded:**

```bash
# Pull the latest main
git checkout main && git pull

# Confirm the new outputs exist
make plan
# Expected: "No changes. Your infrastructure matches the configuration."

# Read the new outputs
terraform -chdir=terraform output -json service_deploy_role_arns
terraform -chdir=terraform output -json service_artifact_buckets
```

---

## 6. Wire the Service Repo

Run the automation script to push the role ARN and bucket name to the service repo's GitHub
Actions secrets and variables. This replaces all manual "go set a secret in the GitHub UI" steps.

**Dry run first:**

```bash
make configure-service-cicd-dry
```

Expected output for the new service:

```
── my-new-service ──────────────────────────────────────────────────────
  ~ Would set secret  AWS_DEPLOY_ROLE_ARN = arn:aws:iam::123456789012:role/my-new-service-github-actions
  ~ Would set variable AWS_SAM_BUCKET      = my-new-service-sam-artifacts
```

**Apply:**

```bash
make configure-service-cicd
```

Expected output:

```
── my-new-service ──────────────────────────────────────────────────────
  ✓ Secret  AWS_DEPLOY_ROLE_ARN set
  ✓ Variable AWS_SAM_BUCKET     set

  ✓ All service repos configured. CI/CD is ready.
```

> The script is safe to re-run. `gh secret set` and `gh variable set` are idempotent.

---

## 7. Verify End-to-End

Push a commit to the service repo's `main` branch (or open and merge a PR) and confirm the
GitHub Actions deploy workflow completes successfully.

**Checklist:**

- [ ] `configure-service-cicd` completed with no errors
- [ ] `AWS_DEPLOY_ROLE_ARN` secret is visible in the service repo's Actions settings
- [ ] `AWS_SAM_BUCKET` variable is visible in the service repo's Actions settings
- [ ] First deploy workflow run completes (green) after the secrets are set
- [ ] SAM stack appears in CloudFormation: `aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE`

---

## 8. Troubleshooting

### `configure-service-cicd` — "Repo not found on GitHub"

The `repo_name` in `managed.auto.tfvars` must match the exact GitHub repo name. Check with:

```bash
gh repo view MichaelHeaton/my-new-service
```

If the repo does not exist, create it first, then re-run the script.

### Deploy workflow fails: `sts:AssumeRoleWithWebIdentity` denied

The OIDC trust policy on the deploy role restricts which Git ref can assume it. Verify:

1. The workflow is triggered from the branch matching `allowed_ref` (default: `refs/heads/main`)
2. The `id-token: write` permission is present in the workflow's `permissions` block
3. The `aws-region` in the workflow matches the region where the role was created

### Deploy workflow fails: SAM cannot write to the artifacts bucket

The deploy role's S3 permissions are scoped to `arn:aws:s3:::my-new-service-sam-artifacts/*`.
Verify `vars.AWS_SAM_BUCKET` in the service repo matches the bucket name from Terraform output:

```bash
terraform -chdir=terraform output -json service_artifact_buckets
```
