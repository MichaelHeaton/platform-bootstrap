# Infrastructure managed by this platform.
# Add new repos and pipelines here — Terraform picks this file up automatically.

managed_repositories = [
  {
    name        = "MichaelHeaton"
    description = "GitHub profile README"
    visibility  = "public"
    topics      = ["readme-profile"]
  },
  {
    name           = "claude-skills"
    description    = "Custom Claude Code skills for daily workflows"
    visibility     = "public"
    default_branch = "Main"
  },
]
