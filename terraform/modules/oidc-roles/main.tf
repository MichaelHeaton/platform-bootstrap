locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"

  # Key format: "${environment}-${cloud}-${function}"
  # This key is also used as the S3 state path prefix, so it must be stable.
  pipelines_map = {
    for p in var.pipelines : "${p.environment}-${p.cloud}-${p.function}" => p
  }
}

# GitHub Actions OIDC provider.
# Both thumbprints are listed: GitHub rotates certificates and both are valid
# at time of writing. Remove the expired one once GitHub's rotation is complete.
# Thumbprint reference: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = local.github_oidc_url

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1", # GitHub Actions CA (primary)
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd", # GitHub Actions CA (secondary)
  ]

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "oidc"
    managed-by  = "terraform"
  }
}

# One IAM role per pipeline. The role name embeds the pipeline key so it is
# self-describing in the AWS console without relying on tags alone.
resource "aws_iam_role" "pipeline" {
  for_each = local.pipelines_map

  name        = "${each.key}-github-actions"
  description = "Assumed by GitHub Actions for ${each.value.repo_name} (${each.value.environment}/${each.value.cloud}/${each.value.function})"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # One subject per allowed_refs entry. StringLike allows the wildcard
            # suffix on the ref value itself (e.g. refs/heads/main); the repo
            # path is always fully-qualified with no wildcards.
            "token.actions.githubusercontent.com:sub" = [
              for ref in each.value.allowed_refs :
              "repo:${var.github_org}/${each.value.repo_name}:ref:${ref}"
            ]
          }
        }
      }
    ]
  })

  tags = {
    environment = each.value.environment
    cloud       = each.value.cloud
    function    = each.value.function
    managed-by  = "terraform"
  }
}

# One narrow IAM policy per pipeline.
# NO wildcards in resource paths — every S3 path is fully specified.
# The pipeline key is used as the S3 folder prefix, keeping role and state
# path in sync without additional variables.
resource "aws_iam_policy" "pipeline_state" {
  for_each = local.pipelines_map

  name        = "${each.key}-state-access"
  description = "Grants explicit access to exactly one S3 state folder (${each.key}/*). No wildcards in resource paths."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListStateFolder"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = var.state_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "${each.key}/",
              "${each.key}/*"
            ]
          }
        }
      },
      {
        Sid    = "ReadWriteStateObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        # Explicit path — no bucket-level wildcard.
        Resource = "${var.state_bucket_arn}/${each.key}/*"
      }
    ]
  })

  tags = {
    environment = each.value.environment
    cloud       = each.value.cloud
    function    = each.value.function
    managed-by  = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "pipeline_state" {
  for_each = local.pipelines_map

  role       = aws_iam_role.pipeline[each.key].name
  policy_arn = aws_iam_policy.pipeline_state[each.key].arn
}
