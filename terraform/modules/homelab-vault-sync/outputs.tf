output "iam_user_name" {
  description = "IAM user for vault-aws-sync (create access keys manually; store on NAS, not in TF state)."
  value       = aws_iam_user.vault_sync.name
}

output "iam_user_arn" {
  description = "ARN of the vault-aws-sync IAM user."
  value       = aws_iam_user.vault_sync.arn
}

output "sm_policy_arn" {
  description = "ARN of the allowlisted Secrets Manager policy."
  value       = aws_iam_policy.vault_sync_sm.arn
}

output "secretsmanager_secret_names" {
  description = "SM secrets in the sync allowlist."
  value       = var.secretsmanager_secret_names
}
