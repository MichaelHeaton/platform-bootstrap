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
    repo_name                   = string
    github_org                  = optional(string)
    environment                 = string
    cloud                       = string
    function                    = string
    allowed_refs                = list(string)
    secretsmanager_secret_names = optional(list(string), [])
    tfe_workspace_enabled       = optional(bool, true)
    tfe_workspace_name          = optional(string)
    tfe_execution_mode          = optional(string) # remote (default), local, or agent
    terraform_working_directory = optional(string, "terraform")
  }))
  description = "Pipeline definitions. Each entry creates GHA OIDC + optional HCP workspace + IAM."
  default     = []
}

# ── HCP Terraform (workspace factory for domain spokes) ─────────────────────

variable "tfe_organization" {
  type        = string
  description = "HCP Terraform organization. HCP workspace variable: tfe_organization."
  default     = "McCleaton-Bootstrap"
}

variable "tfe_hostname" {
  type        = string
  description = "HCP Terraform hostname."
  default     = "app.terraform.io"
}

variable "tfe_vcs_oauth_token_id" {
  type        = string
  description = "OAuth token ID for GitHub VCS in HCP (Organization Settings → VCS Providers). HCP variable: tfe_vcs_oauth_token_id."
}

variable "tfe_management_enabled" {
  type        = bool
  description = "Create HCP workspaces and TFE IAM roles for pipelines with tfe_workspace_enabled."
  default     = true
}

variable "service_accounts" {
  type = list(object({
    service_name                 = string
    repo_name                    = string
    artifact_bucket_name         = string
    allowed_ref                  = optional(string, "refs/heads/main")
    aws_region                   = optional(string)
    stack_name                   = optional(string)
    resource_name_prefixes       = optional(list(string), [])
    execution_role_name_prefixes = optional(list(string), [])
    ssm_parameter_names          = optional(list(string), [])
  }))
  description = "Service deploy accounts. Each entry creates: an S3 artifacts bucket (owned by platform-bootstrap), a Lambda permission boundary, and a GitHub Actions OIDC deploy role scoped to that service's resources."
  default     = []
}

variable "github_app_id" {
  type        = string
  description = "GitHub App ID for Terraform GitHub provider auth. HCP workspace variable: github_app_id."
}

variable "github_app_installation_id" {
  type        = string
  description = "GitHub App installation ID on the MichaelHeaton account. HCP workspace variable: github_app_installation_id."
}

variable "specterrealm_github_app_installation_id" {
  type        = string
  description = "GitHub App installation ID on the SpecterRealm org. HCP workspace variable: specterrealm_github_app_installation_id."
}

# ── McCleaton org (personal platform / domain infrastructure) ─────────────────

variable "mccleaton_org" {
  type        = string
  description = "GitHub org for personal platform and domain infrastructure repos (DNS, cloud, IaC spokes). Not Minecraft/SpecterRealm content."
  default     = "McCleaton"
}

variable "mccleaton_github_app_installation_id" {
  type        = string
  description = "GitHub App installation ID on mccleaton_org. HCP workspace variable: mccleaton_github_app_installation_id."
}

variable "mccleaton_repositories" {
  type = list(object({
    name           = string
    description    = string
    visibility     = string
    topics         = optional(list(string), [])
    default_branch = optional(string, "main")

    has_issues      = optional(bool, true)
    has_wiki        = optional(bool, false)
    has_projects    = optional(bool, false)
    has_discussions = optional(bool, false)

    labels = optional(list(object({
      name        = string
      color       = string
      description = optional(string, "")
    })), [])

    labels_remove = optional(list(string), [])

    license = optional(object({
      spdx_id          = string
      copyright_holder = optional(string, "Michael Heaton")
    }))

    pages = optional(object({
      build_type = optional(string, "legacy")
      source = optional(object({
        branch = string
        path   = optional(string, "/")
      }))
      cname          = optional(string)
      public         = optional(bool)
      https_enforced = optional(bool)
    }))

    main_branch_ruleset = optional(bool, false)
    branch_protection   = optional(bool, true)
  }))
  description = "GitHub repositories under mccleaton_org — platform factory spokes, not SpecterRealm game content."
  default     = []
}

# ── specterrealm-homelab org (homelab / in-house servers) ─────────────────────

variable "specterrealm_homelab_org" {
  type        = string
  description = "GitHub org for homelab infrastructure and service repos (Proxmox, Grafana, streaming, etc.)."
  default     = "specterrealm-homelab"
}

variable "specterrealm_homelab_github_app_installation_id" {
  type        = string
  description = "GitHub App installation ID on specterrealm_homelab_org. HCP workspace variable: specterrealm_homelab_github_app_installation_id."
}

variable "specterrealm_homelab_repositories" {
  type = list(object({
    name           = string
    description    = string
    visibility     = string
    topics         = optional(list(string), [])
    default_branch = optional(string, "main")

    has_issues      = optional(bool, true)
    has_wiki        = optional(bool, false)
    has_projects    = optional(bool, false)
    has_discussions = optional(bool, false)

    labels = optional(list(object({
      name        = string
      color       = string
      description = optional(string, "")
    })), [])

    labels_remove = optional(list(string), [])

    license = optional(object({
      spdx_id          = string
      copyright_holder = optional(string, "Michael Heaton")
    }))

    pages = optional(object({
      build_type = optional(string, "legacy")
      source = optional(object({
        branch = string
        path   = optional(string, "/")
      }))
      cname          = optional(string)
      public         = optional(bool)
      https_enforced = optional(bool)
    }))

    main_branch_ruleset = optional(bool, false)
    branch_protection   = optional(bool, true)
  }))
  description = "GitHub repositories under specterrealm_homelab_org — homelab ops, not Minecraft modpack content."
  default     = []
}

variable "managed_repositories" {
  type = list(object({
    name           = string
    description    = string
    visibility     = string
    topics         = optional(list(string), [])
    default_branch = optional(string, "main")

    has_issues      = optional(bool, true)
    has_wiki        = optional(bool, false)
    has_projects    = optional(bool, false)
    has_discussions = optional(bool, false)

    labels = optional(list(object({
      name        = string
      color       = string
      description = optional(string, "")
    })), [])

    labels_remove = optional(list(string), [])

    license = optional(object({
      spdx_id          = string
      copyright_holder = optional(string, "Michael Heaton")
    }))

    pages = optional(object({
      build_type = optional(string, "legacy")
      source = optional(object({
        branch = string
        path   = optional(string, "/")
      }))
      cname          = optional(string)
      public         = optional(bool)
      https_enforced = optional(bool)
    }))

    main_branch_ruleset = optional(bool, false)
    branch_protection   = optional(bool, true)
  }))
  description = "GitHub repositories to manage. Must NOT include platform-bootstrap. See ADR-004."
  default     = []
}

# ── SpecterRealm org ───────────────────────────────────────────────────────────

variable "specterrealm_repositories" {
  type = list(object({
    name           = string
    description    = string
    visibility     = string
    topics         = optional(list(string), [])
    default_branch = optional(string, "main")

    has_issues      = optional(bool, true)
    has_wiki        = optional(bool, false)
    has_projects    = optional(bool, false)
    has_discussions = optional(bool, false)

    labels = optional(list(object({
      name        = string
      color       = string
      description = optional(string, "")
    })), [])

    labels_remove = optional(list(string), [])

    license = optional(object({
      spdx_id          = string
      copyright_holder = optional(string, "Michael Heaton")
    }))

    pages = optional(object({
      build_type = optional(string, "legacy")
      source = optional(object({
        branch = string
        path   = optional(string, "/")
      }))
      cname          = optional(string)
      public         = optional(bool)
      https_enforced = optional(bool)
    }))

    main_branch_ruleset = optional(bool, false)
    branch_protection   = optional(bool, true)
  }))
  description = "GitHub repositories to manage under the SpecterRealm org. Same schema as managed_repositories."
  default     = []
}
