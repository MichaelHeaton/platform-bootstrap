# These tests provision real AWS resources and require valid AWS credentials.
# Run with: terraform test
# Credentials must be supplied via environment variables (AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN) or an IAM role assumed via OIDC.
# Resources created during the test run are destroyed automatically on completion.

variables {
  bucket_name = "tftest-s3state-mock-bucket-do-not-use"
  tags = {
    environment = "test"
    cloud       = "aws"
    function    = "state"
    managed-by  = "terraform"
  }
}

run "s3_state_bucket_has_versioning" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "S3 bucket versioning must be Enabled, got: ${aws_s3_bucket_versioning.state.versioning_configuration[0].status}"
  }
}

run "s3_state_public_access_blocked" {
  command = apply

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls == true
    error_message = "block_public_acls must be true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_policy == true
    error_message = "block_public_policy must be true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.ignore_public_acls == true
    error_message = "ignore_public_acls must be true"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.restrict_public_buckets == true
    error_message = "restrict_public_buckets must be true"
  }
}
