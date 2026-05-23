output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "pipeline_role_arns" {
  description = "Map of pipeline key (env-cloud-function) to IAM role ARN"
  value       = { for k, r in aws_iam_role.pipeline : k => r.arn }
}
