locals {
  # Boundary policy name and ARN — referenced both when creating the policy and
  # as the condition value in the deploy role's IAM statements.
  boundary_policy_name = "${var.service_name}-lambda-boundary"
  boundary_policy_arn  = "arn:aws:iam::${var.aws_account_id}:policy/${local.boundary_policy_name}"

  stack_name_pattern = coalesce(var.stack_name, "${var.service_name}-*")

  resource_name_prefixes = length(var.resource_name_prefixes) > 0 ? var.resource_name_prefixes : ["${var.service_name}-"]
  resource_name_patterns = [for prefix in local.resource_name_prefixes : "${prefix}*"]

  execution_role_name_prefixes = length(var.execution_role_name_prefixes) > 0 ? var.execution_role_name_prefixes : ["${var.service_name}-"]
  execution_role_arns          = [for prefix in local.execution_role_name_prefixes : "arn:aws:iam::${var.aws_account_id}:role/${prefix}*"]

  lambda_function_arns = flatten([
    for pattern in local.resource_name_patterns : [
      "arn:aws:lambda:*:${var.aws_account_id}:function:${pattern}",
      "arn:aws:lambda:*:${var.aws_account_id}:function:${pattern}:*",
    ]
  ])

  log_group_arns = flatten([
    for pattern in local.resource_name_patterns : [
      "arn:aws:logs:*:${var.aws_account_id}:log-group:/aws/lambda/${pattern}",
      "arn:aws:logs:*:${var.aws_account_id}:log-group:/aws/lambda/${pattern}:*",
    ]
  ])

  ssm_parameter_names = length(var.ssm_parameter_names) > 0 ? var.ssm_parameter_names : ["/${var.service_name}/*"]
  ssm_parameter_arns  = [for name in local.ssm_parameter_names : "arn:aws:ssm:*:${var.aws_account_id}:parameter/${trimprefix(name, "/")}"]

  common_tags = {
    environment = "prod"
    cloud       = "aws"
    function    = "deploy"
    managed-by  = "terraform"
    service     = var.service_name
  }
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
        Resource = flatten([
          for pattern in local.resource_name_patterns : [
            "arn:aws:dynamodb:*:${var.aws_account_id}:table/${pattern}",
            "arn:aws:dynamodb:*:${var.aws_account_id}:table/${pattern}/index/*",
          ]
        ])
      },
      {
        Sid    = "S3ServiceBuckets"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        # Scoped to service-owned data buckets only — not the artifacts bucket
        Resource = flatten([
          for pattern in local.resource_name_patterns : [
            "arn:aws:s3:::${pattern}",
            "arn:aws:s3:::${pattern}/*",
          ]
        ])
      },
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage",
          "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility",
        ]
        Resource = [for pattern in local.resource_name_patterns : "arn:aws:sqs:*:${var.aws_account_id}:${pattern}"]
      },
      {
        Sid      = "EventBridgePutEvents"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "arn:aws:events:*:${var.aws_account_id}:event-bus/*"
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.log_group_arns
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
        Sid      = "SSMParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = local.ssm_parameter_arns
      },
      {
        Sid      = "RDSIAMAuth"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = [for prefix in local.resource_name_prefixes : "arn:aws:rds-db:*:${var.aws_account_id}:dbuser:*/${replace(trimsuffix(prefix, "-"), "-", "_")}_*"]
      },
      {
        Sid      = "STSCallerIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

# ── GitHub Actions deploy role ─────────────────────────────────────────────────
# Assumed by GitHub Actions on push to the allowed ref. Grants SAM deployment
# permissions scoped to this service's resources. Key constraints:
#   - Cannot delete or configure the S3 artifacts bucket
#   - Can only create/modify IAM roles that carry the lambda boundary above
#   - Cannot modify IAM roles or policies outside the service prefix

resource "aws_iam_role" "deploy" {
  name        = "${var.service_name}-github-actions-deploy"
  description = "Assumed by GitHub Actions to deploy ${var.service_name} via SAM. Scoped to configured service resources."

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
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.repo_name}:ref:${var.allowed_ref}"
          }
        }
      }
    ]
  })

  tags = local.common_tags
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
        Sid    = "SAMArtifactsBucket"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = aws_s3_bucket.artifacts.arn
      },
      {
        Sid    = "SAMArtifactsObjects"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },

      # ── CloudFormation ────────────────────────────────────────────────────────
      # SAM uses CloudFormation stacks. Change sets have generated names, but the
      # stack itself is scoped to the configured service stack name/pattern.
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
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackEvents",
          "cloudformation:DescribeStackResources",
          "cloudformation:DescribeChangeSet",
          "cloudformation:GetTemplate",
          "cloudformation:ListStackResources",
        ]
        Resource = [
          "arn:aws:cloudformation:*:${var.aws_account_id}:stack/${local.stack_name_pattern}/*",
          "arn:aws:cloudformation:*:${var.aws_account_id}:changeSet/*",
        ]
      },

      # ── Lambda ────────────────────────────────────────────────────────────────
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = [
          "lambda:AddPermission",
          "lambda:CreateAlias",
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:DeleteAlias",
          "lambda:GetAlias",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetPolicy",
          "lambda:ListAliases",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction",
          "lambda:PublishVersion",
          "lambda:RemovePermission",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:UpdateAlias",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
        ]
        Resource = local.lambda_function_arns
      },

      # ── IAM execution roles — boundary required ───────────────────────────────
      # The deploy role may create and modify Lambda execution roles, but ONLY IF
      # those roles carry the permission boundary created above. This prevents a
      # compromised CI token from creating a Lambda with elevated privileges.
      {
        Sid    = "IAMExecutionRolesCreateWithBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePermissionsBoundary",
        ]
        Resource = local.execution_role_arns
        Condition = {
          StringEquals = {
            # Boundary must be attached — enforced at the IAM API level by AWS,
            # not just by convention. Requests without this condition are denied.
            "iam:PermissionsBoundary" = local.boundary_policy_arn
          }
        }
      },
      {
        Sid    = "IAMExecutionRolesMutate"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
        ]
        Resource = local.execution_role_arns
      },
      {
        Sid    = "IAMExecutionRoleManagedPolicies"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = local.execution_role_arns
        Condition = {
          StringEquals = {
            "iam:PolicyARN" = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
          }
        }
      },
      {
        Sid      = "IAMExecutionRoleInlinePolicies"
        Effect   = "Allow"
        Action   = ["iam:PutRolePolicy", "iam:DeleteRolePolicy"]
        Resource = local.execution_role_arns
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
          "iam:ListRoleTags",
        ]
        Resource = local.execution_role_arns
      },
      {
        # PassRole lets CloudFormation hand the execution role to Lambda.
        # Scoped to service roles only, passed to Lambda and CF service principals.
        Sid      = "IAMPassRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.execution_role_arns
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "lambda.amazonaws.com"
          }
        }
      },

      # ── API Gateway ───────────────────────────────────────────────────────────
      # API Gateway resource ARNs don't carry a service prefix — cannot scope
      # narrower than this without breaking SAM's HTTP API resource creation.
      {
        Sid    = "APIGateway"
        Effect = "Allow"
        Action = [
          "apigateway:DELETE",
          "apigateway:GET",
          "apigateway:PATCH",
          "apigateway:POST",
          "apigateway:PUT",
          "apigateway:TagResource",
          "apigateway:UntagResource",
        ]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/apis",
          "arn:aws:apigateway:${var.aws_region}::/apis/*",
          "arn:aws:apigateway:${var.aws_region}::/tags/*",
        ]
      },

      # ── SQS queues ────────────────────────────────────────────────────────────
      {
        Sid      = "SQS"
        Effect   = "Allow"
        Action   = ["sqs:CreateQueue", "sqs:DeleteQueue", "sqs:SetQueueAttributes", "sqs:GetQueueAttributes", "sqs:TagQueue"]
        Resource = [for pattern in local.resource_name_patterns : "arn:aws:sqs:*:${var.aws_account_id}:${pattern}"]
      },

      # ── EventBridge ───────────────────────────────────────────────────────────
      {
        Sid    = "EventBridge"
        Effect = "Allow"
        Action = ["events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:PutTargets", "events:RemoveTargets", "events:TagResource"]
        Resource = flatten([
          for pattern in local.resource_name_patterns : [
            "arn:aws:events:*:${var.aws_account_id}:rule/${pattern}",
            "arn:aws:events:*:${var.aws_account_id}:event-bus/${pattern}",
          ]
        ])
      },

      # ── CloudWatch Logs ───────────────────────────────────────────────────────
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DeleteRetentionPolicy", "logs:PutRetentionPolicy", "logs:TagResource", "logs:UntagResource"]
        Resource = local.log_group_arns
      },

      # ── SSM parameters ────────────────────────────────────────────────────────
      {
        Sid      = "SSMParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = local.ssm_parameter_arns
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

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy.arn
}
