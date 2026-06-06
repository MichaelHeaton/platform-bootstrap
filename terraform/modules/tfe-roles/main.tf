locals {
  tfe_oidc_url = "https://app.terraform.io"

  pipelines_map = {
    for p in var.pipelines : "${p.environment}-${p.cloud}-${p.function}" => p
    if coalesce(p.tfe_workspace_enabled, true)
  }

  workspace_name = {
    for k, p in local.pipelines_map :
    k => coalesce(p.tfe_workspace_name, p.repo_name)
  }
}

data "aws_region" "current" {}

# HCP Terraform dynamic AWS credentials — one OIDC provider per account.
# Thumbprint: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/aws-configuration
resource "aws_iam_openid_connect_provider" "terraform_cloud" {
  url = local.tfe_oidc_url

  client_id_list = ["aws.workload.identity"]

  thumbprint_list = [
    "a689f1cff185a16420bf1bcbbd2e2668c3cb37a6",
  ]

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "tfe-oidc"
    managed-by  = "terraform"
  }
}

resource "aws_iam_role" "pipeline_tfe" {
  for_each = local.pipelines_map

  name        = "${each.key}-tfe"
  description = "Assumed by HCP Terraform workspace ${local.workspace_name[each.key]} (${coalesce(each.value.github_org, var.default_github_org)}/${each.value.repo_name})"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HCPTerraformOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.terraform_cloud.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(local.tfe_oidc_url, "https://", "")}:aud" = "aws.workload.identity"
          }
          StringLike = {
            "${replace(local.tfe_oidc_url, "https://", "")}:sub" = "organization:${var.tfe_organization}:workspace:${local.workspace_name[each.key]}:run_phase:*"
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

resource "aws_iam_policy" "pipeline_tfe" {
  for_each = {
    for k, p in local.pipelines_map : k => p
    if length(p.secretsmanager_secret_names) > 0
  }

  name        = "${each.key}-tfe-access"
  description = "HCP Terraform run permissions for workspace ${local.workspace_name[each.key]}."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadPipelineSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetResourcePolicy"
        ]
        Resource = [
          for secret_name in each.value.secretsmanager_secret_names :
          "arn:aws:secretsmanager:${data.aws_region.current.name}:${var.aws_account_id}:secret:${secret_name}-*"
        ]
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

resource "aws_iam_role_policy_attachment" "pipeline_tfe" {
  for_each = aws_iam_policy.pipeline_tfe

  role       = aws_iam_role.pipeline_tfe[each.key].name
  policy_arn = each.value.arn
}
