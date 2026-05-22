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
