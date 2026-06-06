output "terraform_cloud_oidc_provider_arn" {
  description = "ARN of the HCP Terraform OIDC provider in AWS."
  value       = aws_iam_openid_connect_provider.terraform_cloud.arn
}

output "pipeline_tfe_role_arns" {
  description = "Map of pipeline key to HCP dynamic-credentials IAM role ARN."
  value       = { for k, r in aws_iam_role.pipeline_tfe : k => r.arn }
}
