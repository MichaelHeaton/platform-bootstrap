locals {
  # Boundary policy name and ARN — referenced both when creating the policy and
  # as the condition value in the deploy role's IAM statements.
  boundary_policy_name = "${var.service_name}-lambda-boundary"
  boundary_policy_arn  = "arn:aws:iam::${var.aws_account_id}:policy/${local.boundary_policy_name}"
}

# ── SAM artifacts bucket ───────────────────────────────────────────────────────
# Owned by platform-bootstrap. The service deploy role can read/write objects
# for SAM deployments but cannot delete the bucket or alter its configuration.
# prevent_destroy: the deploy role has no DeleteBucket permission, but this adds
# a Terraform-level guard so a platform-bootstrap mistake can't destroy it either.

resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifact_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Lambda execution role permission boundary ──────────────────────────────────
# Defines the MAXIMUM permissions any Lambda execution role for this service can
# ever have. Even if the deploy role creates a role with Action: "*", the
# boundary limits actual access to exactly what's listed here.
#
# The deploy role's IAM statements require this boundary on any role it creates,
# so a compromised CI token cannot spin up a Lambda with elevated privileges.

resource "aws_iam_policy" "lambda_boundary" {
  name        = local.boundary_policy_name
  description = "Permission boundary for ${var.service_name} Lambda execution roles. Caps maximum permissions regardless of what the role policy grants."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan",
          "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
        ]
        Resource = [
          "arn:aws:dynamodb:*:${var.aws_account_id}:table/${var.service_name}-*",
          "arn:aws:dynamodb:*:${var.aws_account_id}:table/${var.service_name}-*/index/*",
        ]
      },
      {
        Sid    = "S3ServiceBuckets"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        # Scoped to service-owned data buckets only — not the artifacts bucket
        Resource = [
          "arn:aws:s3:::${var.service_name}-*",
          "arn:aws:s3:::${var.service_name}-*/*",
        ]
      },
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage",
          "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility",
        ]
        Resource = "arn:aws:sqs:*:${var.aws_account_id}:${var.service_name}-*"
      },
      {
        Sid      = "EventBridgePutEvents"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:aws:events:*:${var.aws_account_id}:event-bus/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${var.aws_account_id}:log-group:/aws/lambda/${var.service_name}-*"
      },
      {
        # Required for VPC-attached Lambdas (Aurora access). Resource cannot be
        # scoped narrower than "*" for these EC2 describe/ENI operations.
        Sid    = "VPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:*:${var.aws_account_id}:parameter/${var.service_name}/*"
      },
      {
        Sid      = "RDSIAMAuth"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = "arn:aws:rds-db:*:${var.aws_account_id}:dbuser:*/${var.service_name}_*"
      },
      {
        Sid      = "STSCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })

  tags = {
    service = var.service_name
  }
}

# ── GitHub Actions deploy role ─────────────────────────────────────────────────
# Assumed by GitHub Actions on push to the allowed ref. Grants SAM deployment
# permissions scoped to this service's resources. Key constraints:
#   - Cannot delete or configure the S3 artifacts bucket
#   - Can only create/modify IAM roles that carry the lambda boundary above
#   - Cannot modify IAM roles or policies outside the service prefix

resource "aws_iam_role" "deploy" {
  name        = "${var.service_name}-github-actions-deploy"
  description = "Assumed by GitHub Actions to deploy ${var.service_name} via SAM. Scoped to ${var.service_name}-* resources."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.repo_name}:${var.allowed_ref}"
          }
        }
      }
    ]
  })

  tags = {
    service = var.service_name
  }
}

resource "aws_iam_policy" "deploy" {
  name        = "${var.service_name}-sam-deploy"
  description = "SAM deployment permissions for ${var.service_name}. Scoped to service resources; cannot delete the artifacts bucket or manage IAM outside the service prefix."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ── S3 artifacts bucket — object access only ─────────────────────────────
      # PutObject/GetObject/ListBucket for SAM uploads.
      # Deliberately excludes DeleteBucket, PutBucketPolicy, PutBucketVersioning,
      # PutEncryptionConfiguration — bucket lifecycle is owned by platform-bootstrap.
      {
        Sid    = "SAMArtifactsBucketObjects"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*",
        ]
      },

      # ── CloudFormation ────────────────────────────────────────────────────────
      # SAM uses CloudFormation stacks. Stack names get a `memex-*` prefix by
      # convention (enforced in the service's Makefile/deploy commands).
      # SAM also creates transform stacks with generated names — hence the broader
      # scope on describe/validate actions.
      {
        Sid    = "CloudFormationServiceStacks"
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStack",
          "cloudformation:UpdateStack",
          "cloudformation:DeleteStack",
          "cloudformation:CreateChangeSet",
          "cloudformation:ExecuteChangeSet",
          "cloudformation:DeleteChangeSet",
        ]
        Resource = "arn:aws:cloudformation:*:${var.aws_account_id}:stack/${var.service_name}-*"
      },
      {
        Sid    = "CloudFormationDescribe"
        Effect = "Allow"
        Action = [
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackEvents",
          "cloudformation:DescribeStackResources",
          "cloudformation:DescribeChangeSet",
          "cloudformation:GetTemplate",
          "cloudformation:ValidateTemplate",
          "cloudformation:ListStacks",
          "cloudformation:ListStackResources",
        ]
        # SAM describe calls reference generated names — cannot scope narrower here
        Resource = "*"
      },

      # ── Lambda ────────────────────────────────────────────────────────────────
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:DeleteFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:TagResource",
          "lambda:PublishVersion",
          "lambda:CreateAlias",
          "lambda:UpdateAlias",
          "lambda:DeleteAlias",
          "lambda:CreateEventSourceMapping",
          "lambda:UpdateEventSourceMapping",
          "lambda:DeleteEventSourceMapping",
          "lambda:ListEventSourceMappings",
        ]
        Resource = "arn:aws:lambda:*:${var.aws_account_id}:function:${var.service_name}-*"
      },

      # ── IAM execution roles — boundary required ───────────────────────────────
      # The deploy role may create and modify Lambda execution roles, but ONLY IF
      # those roles carry the permission boundary created above. This prevents a
      # compromised CI token from creating a Lambda with elevated privileges.
      {
        Sid    = "IAMExecutionRolesMutate"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy",
          "iam:TagRole",
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-*"
        Condition = {
          StringEquals = {
            # Boundary must be attached — enforced at the IAM API level by AWS,
            # not just by convention. Requests without this condition are denied.
            "iam:PermissionsBoundary" = local.boundary_policy_arn
          }
        }
      },
      {
        # Detach/delete do not mutate the role's effective permissions — no
        # boundary condition needed. Scoped to service prefix.
        Sid    = "IAMExecutionRolesDelete"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:DetachRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-*"
      },
      {
        # Inline and managed policies for execution roles
        Sid    = "IAMPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:TagPolicy",
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:policy/${var.service_name}-*"
      },
      {
        # Read-only IAM — needed by SAM/CloudFormation to check existing resources
        Sid    = "IAMReadOnly"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
        ]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-*"
      },
      {
        # PassRole lets CloudFormation hand the execution role to Lambda.
        # Scoped to service roles only, passed to Lambda and CF service principals.
        Sid    = "IAMPassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "lambda.amazonaws.com",
              "cloudformation.amazonaws.com",
            ]
          }
        }
      },

      # ── API Gateway ───────────────────────────────────────────────────────────
      # API Gateway resource ARNs don't carry a service prefix — cannot scope
      # narrower than this without breaking SAM's HTTP API resource creation.
      {
        Sid      = "APIGateway"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = "arn:aws:apigateway:${var.aws_region}::*"
      },

      # ── SQS queues ────────────────────────────────────────────────────────────
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:GetQueueAttributes", "sqs:TagQueue"]
        Resource = "arn:aws:sqs:*:${var.aws_account_id}:${var.service_name}-*"
      },

      # ── EventBridge ───────────────────────────────────────────────────────────
      {
        Sid    = "EventBridge"
        Effect = "Allow"
        Action = ["events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:PutTargets", "events:RemoveTargets", "events:TagResource"]
        Resource = [
          "arn:aws:events:*:${var.aws_account_id}:rule/${var.service_name}-*",
          "arn:aws:events:*:${var.aws_account_id}:event-bus/${var.service_name}-*",
        ]
      },

      # ── CloudWatch Logs ───────────────────────────────────────────────────────
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:TagResource", "logs:PutRetentionPolicy"]
        Resource = "arn:aws:logs:*:${var.aws_account_id}:log-group:/aws/lambda/${var.service_name}-*"
      },

      # ── SSM parameters ────────────────────────────────────────────────────────
      {
        Sid    = "SSMParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"]
        Resource = "arn:aws:ssm:*:${var.aws_account_id}:parameter/${var.service_name}/*"
      },

      # ── Identity ──────────────────────────────────────────────────────────────
      {
        Sid      = "STSCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })

  tags = {
    service = var.service_name
  }
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}
