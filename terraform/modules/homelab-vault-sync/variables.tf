variable "aws_account_id" {
  type        = string
  description = "AWS account ID for Secrets Manager ARNs."
}

variable "secretsmanager_secret_names" {
  type        = list(string)
  description = "SM secret names the Vault sync principal may read and update (allowlist)."
}

variable "user_name" {
  type        = string
  description = "IAM user name for NAS01 vault-aws-sync sidecar."
  default     = "homelab-vault-aws-sync"
}
