variable "aws_region" {
  type        = string
  description = "AWS region for all resources. Supplied via GitHub variable AWS_REGION."
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID. Supplied via GitHub variable AWS_ACCOUNT_ID."
}

variable "state_bucket_name" {
  type        = string
  description = "Name of the S3 bucket for Terraform state. Supplied via GitHub variable TF_STATE_BUCKET_NAME."
}

variable "github_org" {
  type        = string
  description = "GitHub organization or user owning all managed repositories."
}

variable "pipelines" {
  type = list(object({
    repo_name    = string
    environment  = string
    cloud        = string
    function     = string
    allowed_refs = list(string) # e.g. ["refs/heads/main"]
  }))
  description = "Pipeline definitions. Each entry creates one IAM role scoped to exactly one S3 state folder."
  default     = []
}

variable "managed_repositories" {
  type = list(object({
    name        = string
    description = string
    visibility  = string
    topics      = optional(list(string), [])
  }))
  description = "GitHub repositories to manage. Must NOT include platform-bootstrap. See ADR-004."
  default     = []
}
