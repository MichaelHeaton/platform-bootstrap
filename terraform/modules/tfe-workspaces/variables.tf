variable "tfe_organization" {
  type        = string
  description = "HCP Terraform organization name."
}

variable "tfe_vcs_oauth_token_id" {
  type        = string
  description = "OAuth token ID for the GitHub VCS provider in HCP (Settings → VCS Providers)."
}

variable "default_github_org" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "pipeline_tfe_role_arns" {
  type        = map(string)
  description = "Map of pipeline key to HCP dynamic-credentials IAM role ARN."
}

variable "pipelines" {
  type = list(object({
    repo_name                   = string
    github_org                  = optional(string)
    environment                 = string
    cloud                       = string
    function                    = string
    allowed_refs                = list(string)
    secretsmanager_secret_names = optional(list(string), [])
    tfe_workspace_enabled       = optional(bool, true)
    tfe_workspace_name          = optional(string)
    terraform_working_directory = optional(string, "terraform")
  }))
}
