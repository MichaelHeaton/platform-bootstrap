data "aws_region" "current" {}

locals {
  secret_arns = [
    for name in var.secretsmanager_secret_names :
    "arn:aws:secretsmanager:${data.aws_region.current.name}:${var.aws_account_id}:secret:${name}-*"
  ]
}

# NAS01 Docker cannot use instance profiles or IRSA. An IAM user with access keys
# stored on the NAS filesystem (not git) is the practical bootstrap pattern until
# a future LXC/EC2 runner with an instance profile exists.
resource "aws_iam_user" "vault_sync" {
  name = var.user_name

  tags = {
    environment = "personal"
    cloud       = "homelab"
    function    = "vault-aws-sync"
    managed-by  = "terraform"
  }
}

resource "aws_iam_policy" "vault_sync_sm" {
  name        = "${var.user_name}-sm-access"
  description = "Vault → AWS SM sync allowlist for homelab NAS01 sidecar."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SyncAllowlistedSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = local.secret_arns
      },
    ]
  })

  tags = {
    environment = "personal"
    cloud       = "homelab"
    function    = "vault-aws-sync"
    managed-by  = "terraform"
  }
}

resource "aws_iam_user_policy_attachment" "vault_sync_sm" {
  user       = aws_iam_user.vault_sync.name
  policy_arn = aws_iam_policy.vault_sync_sm.arn
}
