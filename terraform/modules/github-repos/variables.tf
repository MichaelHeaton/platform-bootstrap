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

  validation {
    condition = alltrue([
      for r in var.repositories :
      try(r.pages, null) == null || contains(["legacy", "workflow"], try(r.pages.build_type, "legacy"))
    ])
    error_message = "Repository Pages build_type must be either 'legacy' or 'workflow'."
  }

  validation {
    condition = alltrue([
      for r in var.repositories :
      try(r.pages, null) == null ||
      try(r.pages.build_type, "legacy") == "workflow" ||
      try(r.pages.source.branch, "") != ""
    ])
    error_message = "Repository Pages source.branch is required when build_type is 'legacy'."
  }

  validation {
    condition = alltrue([
      for r in var.repositories :
      try(r.pages, null) == null ||
      try(r.pages.build_type, "legacy") != "workflow" ||
      try(r.pages.source, null) == null
    ])
    error_message = "Repository Pages source is only valid for legacy Pages; workflow Pages paths are configured by the GitHub Actions workflow."
  }

  validation {
    condition = alltrue([
      for r in var.repositories :
      try(r.pages.source.path, "/") == "/" || try(r.pages.source.path, "/") == "/docs"
    ])
    error_message = "Repository Pages source.path must be '/' or '/docs'."
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
