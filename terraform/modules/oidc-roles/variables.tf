variable "github_org" {
  type        = string
  description = "GitHub organization name used in OIDC trust conditions."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID. Used to construct OIDC provider ARN and avoid data source lookups."
}

variable "state_bucket_arn" {
  type        = string
  description = "ARN of the S3 state bucket. Used to construct IAM policy resource paths."
}

variable "pipelines" {
  type = list(object({
    repo_name                   = string
    environment                 = string
    cloud                       = string
    function                    = string
    allowed_refs                = list(string)
    secretsmanager_secret_names = optional(list(string), [])
  }))
  description = "Pipeline definitions. Each produces one IAM role with explicit, narrow S3 permissions."
}
