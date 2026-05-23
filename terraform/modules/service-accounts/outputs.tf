output "deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as AWS_DEPLOY_ROLE_ARN in the service repo's GitHub Actions secrets."
  value       = aws_iam_role.deploy.arn
}

output "artifact_bucket_name" {
  description = "S3 bucket name for SAM deployment artifacts. Pass to sam deploy via --s3-bucket or samconfig.toml."
  value       = aws_s3_bucket.artifacts.id
}

output "artifact_bucket_arn" {
  description = "ARN of the SAM artifacts bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "lambda_boundary_arn" {
  description = "ARN of the Lambda execution role permission boundary. Add to SAM template Globals.Function.PermissionsBoundary."
  value       = aws_iam_policy.lambda_boundary.arn
}
