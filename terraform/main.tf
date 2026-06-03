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

locals {
  service_accounts_by_name = {
    for service in var.service_accounts : service.service_name => service
  }

  service_artifact_bucket_arns = flatten([
    for service in var.service_accounts : [
      "arn:aws:s3:::${service.artifact_bucket_name}",
      "arn:aws:s3:::${service.artifact_bucket_name}/*",
    ]
  ])
}

module "service_accounts" {
  source   = "./modules/service-accounts"
  for_each = { for s in var.service_accounts : s.service_name => s }

  service_name                 = each.value.service_name
  repo_name                    = each.value.repo_name
  github_org                   = var.github_org
  aws_account_id               = var.aws_account_id
  aws_region                   = coalesce(each.value.aws_region, var.aws_region)
  oidc_provider_arn            = module.oidc_roles.oidc_provider_arn
  artifact_bucket_name         = each.value.artifact_bucket_name
  allowed_ref                  = each.value.allowed_ref
  stack_name                   = each.value.stack_name
  resource_name_prefixes       = each.value.resource_name_prefixes
  execution_role_name_prefixes = each.value.execution_role_name_prefixes
  ssm_parameter_names          = each.value.ssm_parameter_names
}

locals {
  managed_repositories_resolved = [
    for repo in var.managed_repositories : (
      repo.name == "minecraft-modpack-cp-verdant"
      ? merge(repo, local.pack_settings_minecraft_modpack_cp_verdant)
      : repo
    )
  ]
}

module "github_repos" {
  source = "./modules/github-repos"

  repositories = local.managed_repositories_resolved
  codeowners   = ["@MichaelHeaton"] # See CODEOWNERS
  github_org   = var.github_org
  github_token = var.tfe_pb_michaelheaton
}

resource "github_actions_secret" "service_deploy_role_arn" {
  for_each = module.service_accounts

  repository  = local.service_accounts_by_name[each.key].repo_name
  secret_name = "AWS_DEPLOY_ROLE_ARN"
  value       = each.value.deploy_role_arn

  depends_on = [module.github_repos]
}

resource "github_actions_variable" "service_sam_bucket" {
  for_each = module.service_accounts

  repository    = local.service_accounts_by_name[each.key].repo_name
  variable_name = "AWS_SAM_BUCKET"
  value         = each.value.artifact_bucket_name

  depends_on = [module.github_repos]
}

# ── Bootstrap CI role permissions ─────────────────────────────────────────────
# The platform-bootstrap-github-actions role was created manually during the
# bootstrap sequence (see docs/runbooks/02-bootstrap.md). The state-path policy
# was also created manually and imported. This block adds the management
# permissions the role needs to run terraform plan/apply in CI:
# - Read/write the state bucket and managed service artifact buckets
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
        Resource = concat(
          [
            module.state_bucket.bucket_arn,
            "${module.state_bucket.bucket_arn}/*",
          ],
          local.service_artifact_bucket_arns
        )
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
          "arn:aws:iam::${var.aws_account_id}:role/*-github-actions-deploy",
          "arn:aws:iam::${var.aws_account_id}:role/platform-bootstrap-*",
          "arn:aws:iam::${var.aws_account_id}:policy/*-state-access",
          "arn:aws:iam::${var.aws_account_id}:policy/*-lambda-boundary",
          "arn:aws:iam::${var.aws_account_id}:policy/*-sam-deploy",
          "arn:aws:iam::${var.aws_account_id}:policy/platform-bootstrap-*",
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

# ── Compliance read-only role ──────────────────────────────────────────────────
# Scoped to exactly the AWS calls made by scripts/compliance_check.py.
# Deliberately does not include "github-actions" in the name so the
# IAM_NO_WILDCARD_PATHS compliance check does not scan it (IAM list/describe
# operations require Resource: "*" — there is no narrower scope for list calls).

resource "aws_iam_role" "compliance_readonly" {
  name        = "platform-bootstrap-compliance-readonly"
  description = "Assumed by the compliance-check workflow. Read-only S3 and IAM access only."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = module.oidc_roles.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Allows any ref — compliance runs on both PRs and the daily cron
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/platform-bootstrap:*"
          }
        }
      }
    ]
  })

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "compliance"
    managed-by  = "terraform"
  }
}

resource "aws_iam_policy" "compliance_readonly" {
  name        = "platform-bootstrap-compliance-readonly"
  description = "Read-only access scoped to the exact AWS calls in scripts/compliance_check.py."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketReadOnly"
        Effect = "Allow"
        Action = [
          "s3:GetBucketVersioning",
          "s3:GetPublicAccessBlock",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPolicy",
        ]
        # Bucket-level operations only — no object read required
        Resource = module.state_bucket.bucket_arn
      },
      {
        Sid    = "IAMReadOnly"
        Effect = "Allow"
        Action = [
          "iam:ListRoles",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRolePolicy",
        ]
        # IAM list/describe cannot be scoped below "*"
        Resource = "*"
      },
    ]
  })

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "compliance"
    managed-by  = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "compliance_readonly" {
  role       = aws_iam_role.compliance_readonly.name
  policy_arn = aws_iam_policy.compliance_readonly.arn
}

# ── SpecterRealm org repositories ─────────────────────────────────────────────

locals {
  specterrealm_repositories_resolved = [
    for repo in var.specterrealm_repositories : (
      repo.name == "specterrealm-core"
      ? merge(repo, local.pack_settings_specterrealm_core)
      : repo.name == "minecraft-modpack-cp-elysian"
      ? merge(repo, local.pack_settings_minecraft_modpack_cp_elysian)
      : repo.name == "minecraft-modpack-cp-influx"
      ? merge(repo, local.pack_settings_minecraft_modpack_cp_influx)
      : repo.name == "minecraft-modpack-cp-liminal"
      ? merge(repo, local.pack_settings_minecraft_modpack_cp_liminal)
      : repo
    )
  ]
}

module "github_repos_specterrealm" {
  source = "./modules/github-repos"

  providers = {
    github = github.specterrealm
  }

  repositories = local.specterrealm_repositories_resolved
  codeowners   = ["@MichaelHeaton"]
  github_org   = "SpecterRealm"
  github_token = var.tfe_pb_specterrealm
}


# DEFERRED: Multi-account AWS via AWS Organizations
# See ADR-006: In-repo modules
# Pending: scale review before implementing cross-account trust

# DEFERRED: Azure provider
# See ADR-006: In-repo modules
# Pending: confirmed need

# DEFERRED: GitLab provider
# Pending: GitLab support in target CI platform
