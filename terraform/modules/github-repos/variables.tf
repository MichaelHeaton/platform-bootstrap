variable "repositories" {
  type = list(object({
    name           = string
    description    = string
    visibility     = string
    topics         = optional(list(string), [])
    default_branch = optional(string, "main")
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
