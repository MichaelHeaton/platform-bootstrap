# These tests provision real AWS resources and require valid AWS credentials.
# Run with: terraform test
# Credentials must be supplied via environment variables or an assumed IAM role.
# Resources created during the test run are destroyed automatically on completion.
#
# Note: aws_iam_openid_connect_provider is a global resource. If the GitHub
# OIDC provider already exists in the target account, this test will fail with
# a conflict error. Run against a dedicated test account or import the existing
# provider first.

variables {
  github_org       = "test-org"
  aws_account_id   = "123456789012"
  state_bucket_arn = "arn:aws:s3:::mock-state-bucket-for-testing"

  pipelines = [
    {
      repo_name    = "test-repo"
      environment  = "dev"
      cloud        = "aws"
      function     = "app"
      allowed_refs = ["refs/heads/main"]
    }
  ]
}

run "oidc_provider_created" {
  command = apply

  assert {
    condition     = aws_iam_openid_connect_provider.github_actions.arn != ""
    error_message = "OIDC provider ARN must not be empty after apply"
  }

  assert {
    condition     = contains(aws_iam_openid_connect_provider.github_actions.client_id_list, "sts.amazonaws.com")
    error_message = "OIDC provider client_id_list must contain sts.amazonaws.com"
  }
}

run "pipeline_role_arns_populated" {
  command = apply

  assert {
    condition     = contains(keys(aws_iam_role.pipeline), "dev-aws-app")
    error_message = "pipeline_role_arns must contain key 'dev-aws-app' matching the test pipeline definition"
  }

  assert {
    condition     = aws_iam_role.pipeline["dev-aws-app"].arn != ""
    error_message = "IAM role ARN for dev-aws-app must not be empty"
  }
}
