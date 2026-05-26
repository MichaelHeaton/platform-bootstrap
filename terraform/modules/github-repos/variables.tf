variable "repositories" {
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

    main_branch_ruleset = optional(bool, false)
  }))
  description = "Repositories to manage. Must NOT include platform-bootstrap (see ADR-004)."

  validation {
    condition     = !contains([for r in var.repositories : r.name], "platform-bootstrap")
    error_message = "platform-bootstrap must not be managed by Terraform. See ADR-004."
  }

  validation {
    condition     = alltrue([for r in var.repositories : contains(["private", "public"], r.visibility)])
    error_message = "Repository visibility must be 'private' or 'public'."
  }
}

variable "codeowners" {
  type        = list(string)
  description = "GitHub handles to list as owners in CODEOWNERS (e.g. [\"@MichaelHeaton\"])."
}

variable "github_org" {
  type        = string
  description = "GitHub organization or user that owns managed repositories."
}

variable "github_token" {
  type        = string
  sensitive   = true
  description = "GitHub token for local-exec extras (discussion categories, label removal). Set via TF_VAR_github_token in CI."
}
