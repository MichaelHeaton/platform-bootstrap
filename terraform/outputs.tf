output "state_bucket_id" {
  description = "ID of the S3 bucket used for Terraform remote state"
  value       = module.state_bucket.bucket_id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket used for Terraform remote state"
  value       = module.state_bucket.bucket_arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = module.oidc_roles.oidc_provider_arn
}

output "pipeline_role_arns" {
  description = "Map of pipeline name to IAM role ARN"
  value       = module.oidc_roles.pipeline_role_arns
}

output "service_deploy_role_arns" {
  description = "Map of service name to GitHub Actions deploy role ARN. Add each value as AWS_DEPLOY_ROLE_ARN in the corresponding repo's GitHub Actions secrets."
  value       = { for k, m in module.service_accounts : k => m.deploy_role_arn }
}

output "service_artifact_buckets" {
  description = "Map of service name to SAM artifacts bucket name."
  value       = { for k, m in module.service_accounts : k => m.artifact_bucket_name }
}

output "service_lambda_boundary_arns" {
  description = "Map of service name to Lambda execution role permission boundary ARN."
  value       = { for k, m in module.service_accounts : k => m.lambda_boundary_arn }
}

output "github_pages_urls" {
  description = "Map of repository name to GitHub Pages URL for repositories with Pages managed."
  value       = module.github_repos.pages_urls
}
