variable "service_name" {
  type        = string
  description = "Short identifier for the service. Used as a prefix on all resources (e.g. \"memex-suite\")."
}

variable "repo_name" {
  type        = string
  description = "GitHub repository name (without org prefix)."
}

variable "github_org" {
  type        = string
  description = "GitHub organization or username that owns the repository."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID. Used to construct scoped IAM resource ARNs."
}

variable "aws_region" {
  type        = string
  description = "Primary AWS region. Used to scope regional resource ARNs in policies."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the GitHub Actions OIDC provider. Created once by the oidc-roles module and shared."
}

variable "artifact_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for SAM/deployment artifacts. Owned by platform-bootstrap — the service deploy role can read/write objects but cannot delete the bucket or change its configuration."
}

variable "allowed_ref" {
  type        = string
  default     = "refs/heads/main"
  description = "Git ref allowed to assume the deploy role (e.g. \"refs/heads/main\")."
}
