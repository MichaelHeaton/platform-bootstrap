# platform-bootstrap

This repository is the foundational layer of the platform. It manages all other infrastructure
repositories, the S3 bucket used for Terraform remote state, and the OIDC trust relationships
that allow GitHub Actions pipelines to authenticate to AWS without static credentials. It is the
only repository in the platform that is NOT managed by Terraform — it was created manually and is
maintained manually. This is intentional: managing it via Terraform would create a circular
dependency where it must be working to manage itself. See [ADR-004](docs/decisions/ADR-004-github-terraform-management.md)
for the full reasoning.

## What This Repository Does

- Manages the S3 bucket used for all Terraform remote state storage across every project and environment
- Manages all GitHub repositories in the organization via the Terraform `integrations/github` provider,
  including optional GitHub Pages settings for repositories that opt in
- Manages OIDC trust relationships between GitHub Actions and AWS so pipelines never hold static credentials
- Defines one IAM role per pipeline with explicit least-privilege S3 scoping to that pipeline's state path
- Runs compliance drift detection against its own configuration and the live AWS and GitHub state

## Runbooks

Complete these in order. Each runbook assumes the previous one is done.

1. [01 — AWS Account Setup](docs/runbooks/01-aws-account-setup.md)
2. [02 — Bootstrap](docs/runbooks/02-bootstrap.md)
3. [03 — Disaster Recovery](docs/runbooks/03-disaster-recovery.md)
4. [04 — Add a Service](docs/runbooks/04-add-service.md)
5. [05 — SpecterRealm Pack GitHub Settings](docs/runbooks/05-specterrealm-pack-github-settings.md)

## How to Add a New Project

1. Add the repo to `managed_repositories` in `terraform/managed.auto.tfvars` if it is a new
   GitHub repository that should be managed by this platform (branch protection, CODEOWNERS, etc.).
2. Add an entry to `var.pipelines` in `terraform/main.tf` with the project's `repo_name`,
   `environment`, `cloud`, `function`, and `allowed_refs`.
3. Open a PR — the `terraform-plan` workflow will post a comment showing exactly what will be
   created before anyone approves.
4. After merge, the `terraform-apply` workflow creates the S3 state path and the IAM role
   automatically. No manual AWS console steps required.
5. The new repository can now authenticate to AWS via OIDC using the role
   `{environment}-{cloud}-{function}-github-actions`.

**Example pipeline entry:**

```hcl
{
  repo_name    = "my-app"
  environment  = "prod"
  cloud        = "aws"
  function     = "app"
  allowed_refs = ["refs/heads/main"]
}
```

This single entry creates:

- **S3 state path:** `prod-aws-app/terraform.tfstate`
- **IAM role:** `prod-aws-app-github-actions`

The role trusts only the `my-app` repository on `refs/heads/main`. No other repository or
branch can assume it, even if it knows the role ARN.

## How to Add a GitHub Repository Only

For repository-only requests, add an entry to `managed_repositories` in
`terraform/managed.auto.tfvars` and open a PR. Do not create repositories manually with `gh repo
create` or the GitHub API; the Terraform plan/apply workflows are the source of truth and create
the repository after merge.

## How to Run the Compliance Check

```bash
# Structural checks only — no credentials needed, safe to run anywhere
python scripts/compliance_check.py --structural-only

# Full checks — requires AWS credentials and a GITHUB_TOKEN with read:org scope
python scripts/compliance_check.py \
  --account-id $AWS_ACCOUNT_ID \
  --region $AWS_REGION \
  --bucket $TF_STATE_BUCKET_NAME \
  --github-org $GITHUB_ORG
```

The structural-only mode validates naming conventions, required file presence, and
cross-references between ADRs and code without making any network calls. It runs on every
pull request in CI. Full checks additionally verify live AWS resource configuration (bucket
policies, OIDC provider thumbprints, IAM role trust conditions) and GitHub repository settings
against what Terraform declares.

## Architecture Decisions

| ADR | Title | Summary |
|-----|-------|---------|
| [ADR-001](docs/decisions/ADR-001-s3-remote-state.md) | S3 for Terraform Remote State Storage | AWS S3 with encryption and versioning is the remote state backend |
| [ADR-002](docs/decisions/ADR-002-oidc-authentication.md) | OIDC Authentication for GitHub Actions to AWS | No static AWS credentials; pipelines use short-lived OIDC tokens |
| [ADR-003](docs/decisions/ADR-003-single-bucket-flat-folders.md) | Single S3 Bucket with Flat Folder Structure | One bucket, flat `{env}-{cloud}-{function}/terraform.tfstate` paths |
| [ADR-004](docs/decisions/ADR-004-github-terraform-management.md) | Manage All GitHub Repos via Terraform (Except platform-bootstrap) | Consistent settings enforced by code; platform-bootstrap excluded to break circular dependency |
| [ADR-005](docs/decisions/ADR-005-python-compliance-script.md) | Python Script for Compliance Drift Detection | Custom Python script with plain-English output over OPA or Checkov |
| [ADR-006](docs/decisions/ADR-006-in-repo-modules.md) | Terraform Modules as Subdirectories | Modules live in-repo until consumed by a second team; extraction deferred |
| [ADR-007](docs/decisions/ADR-007-s3-native-state-locking.md) | S3 Native State Locking over DynamoDB | Terraform 1.10+ native locking eliminates the DynamoDB dependency |

## Repository Structure

```
platform-bootstrap/
├── .github/
│   ├── CODEOWNERS                          # All changes require @MichaelHeaton review
│   └── workflows/
│       ├── terraform-plan.yml              # Runs on PRs; posts plan output as a comment
│       ├── terraform-apply.yml             # Runs on merge to main; applies the plan
│       ├── compliance-check.yml            # Scheduled + on-PR compliance drift detection
│       └── pre-publication-audit.yml       # Blocks repo visibility changes to public
├── docs/
│   ├── decisions/                          # Architecture Decision Records (ADR-001–ADR-007)
│   └── runbooks/                           # Step-by-step operational procedures
│       ├── 01-aws-account-setup.md
│       ├── 02-bootstrap.md
│       └── 03-disaster-recovery.md
├── scripts/
│   ├── compliance_check.py                 # Compliance drift detection script (see ADR-005)
│   └── tests/                              # pytest tests for the compliance script
├── terraform/
│   ├── backend.tf                          # S3 backend config (bucket/region via -backend-config)
│   ├── main.tf                             # Root module — wires together the three modules below
│   ├── variables.tf                        # Input variables (supplied via GitHub Actions vars)
│   ├── outputs.tf                          # Outputs: bucket ARN, role ARNs, repo names
│   ├── versions.tf                         # Provider versions; enforces Terraform >= 1.10.0
│   └── modules/
│       ├── s3-state/                       # S3 bucket, versioning, encryption, bucket policy
│       ├── oidc-roles/                     # OIDC provider, IAM roles, per-pipeline IAM policies
│       └── github-repos/                   # GitHub repository settings and branch protection
├── CHANGELOG.md
└── README.md
```

## What This Repository Does NOT Manage

- **Itself (platform-bootstrap)** — settings are maintained manually and audited by the
  compliance script. See [ADR-004](docs/decisions/ADR-004-github-terraform-management.md).
- **Application code** — each project has its own repository and manages its own source.
- **Application-level infrastructure** — each project manages its own AWS resources
  (compute, databases, networking) in its own Terraform state under its own IAM role.
  This repository only provides the state storage and the authentication mechanism.
