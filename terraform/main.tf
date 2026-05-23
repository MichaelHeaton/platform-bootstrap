# platform-bootstrap is explicitly excluded from GitHub management.
# See ADR-004: GitHub Repository Management via Terraform.
# This repo was created manually and is maintained manually.

module "state_bucket" {
  source = "./modules/s3-state"

  bucket_name = var.state_bucket_name

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "state"
    managed-by  = "terraform"
  }
}

module "oidc_roles" {
  source = "./modules/oidc-roles"

  github_org       = var.github_org
  aws_account_id   = var.aws_account_id
  state_bucket_arn = module.state_bucket.bucket_arn
  pipelines        = var.pipelines
}

module "github_repos" {
  source = "./modules/github-repos"

  repositories   = var.managed_repositories
  default_branch = "main"
  codeowners     = ["@MichaelHeaton"] # See CODEOWNERS
}

# ── Bootstrap CI role permissions ─────────────────────────────────────────────
# The platform-bootstrap-github-actions role was created manually during the
# bootstrap sequence (see docs/runbooks/02-bootstrap.md). The state-path policy
# was also created manually and imported. This block adds the management
# permissions the role needs to run terraform plan/apply in CI:
# - Read/write the state bucket at any path (not just platform-bootstrap/)
# - Describe and manage IAM roles, policies, and OIDC providers
# - sts:GetCallerIdentity for provider authentication checks

resource "aws_iam_policy" "bootstrap_ci_management" {
  name        = "platform-bootstrap-ci-management"
  description = "Allows platform-bootstrap GitHub Actions to manage its own infrastructure via Terraform CI"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketManagement"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          module.state_bucket.bucket_arn,
          "${module.state_bucket.bucket_arn}/*",
        ]
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com",
        ]
      },
      {
        Sid    = "IAMRolesAndPolicies"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          "arn:aws:iam::${var.aws_account_id}:role/*-github-actions",
          "arn:aws:iam::${var.aws_account_id}:policy/*-state-access",
          "arn:aws:iam::${var.aws_account_id}:policy/platform-bootstrap-ci-management",
        ]
      },
      {
        Sid      = "STSCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = ["*"]
      },
    ]
  })

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "ci"
    managed-by  = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "bootstrap_ci_management" {
  role       = "platform-bootstrap-github-actions"
  policy_arn = aws_iam_policy.bootstrap_ci_management.arn
}

# DEFERRED: Multi-account AWS via AWS Organizations
# See ADR-006: In-repo modules
# Pending: scale review before implementing cross-account trust

# DEFERRED: Azure provider
# See ADR-006: In-repo modules
# Pending: confirmed need

# DEFERRED: GitLab provider
# Pending: GitLab support in target CI platform
