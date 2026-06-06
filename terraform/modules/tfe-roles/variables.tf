variable "aws_account_id" {
  type = string
}

variable "tfe_organization" {
  type        = string
  description = "HCP Terraform organization name."
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
  }))
}

variable "default_github_org" {
  type = string
}
