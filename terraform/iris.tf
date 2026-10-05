# Iris — personal AI assistant suite monorepo baseline (ADR-008).
# Merged into managed_repositories_resolved when name == "iris".

locals {
  iris_settings = {
    squash_merge_only               = true
    require_signed_commits          = true
    require_linear_history          = true
    require_conversation_resolution = true
    enforce_admins                  = true
    codeowners_file                 = ".github/CODEOWNERS"
    dependabot_security_updates     = true
    actions_hardened                = true

    labels = tolist([
      # type
      { name = "type/bug", color = "d73a4a", description = "Something isn't working" },
      { name = "type/feature", color = "1f883d", description = "New capability or user-facing feature" },
      { name = "type/docs", color = "0075ca", description = "Documentation only" },
      { name = "type/chore", color = "6b7280", description = "Maintenance, deps, or tooling" },
      { name = "type/adr", color = "5319e7", description = "Architecture decision record" },
      # area
      { name = "area/web", color = "0e8a16", description = "Web UI" },
      { name = "area/api", color = "1d76db", description = "HTTP API" },
      { name = "area/mcp", color = "fbca04", description = "MCP server" },
      { name = "area/memex", color = "c2e0c6", description = "Knowledge / Memex module" },
      { name = "area/tickets", color = "bfd4f2", description = "Ticketing module" },
      { name = "area/relationships", color = "f9d0c4", description = "Relationship management" },
      { name = "area/calendar", color = "d4c5f9", description = "Calendar sync" },
      { name = "area/voice", color = "e99695", description = "Voice assistant" },
      { name = "area/infra", color = "555555", description = "Repo hygiene, CI, platform" },
      { name = "area/brand", color = "ffc0cb", description = "Brand assets and naming" },
      # priority
      { name = "priority/p0", color = "b60205", description = "Drop everything" },
      { name = "priority/p1", color = "d93f0b", description = "Urgent" },
      { name = "priority/p2", color = "fbca04", description = "Normal" },
      { name = "priority/p3", color = "c5def5", description = "Low / backlog" },
      # status
      { name = "status/needs-decision", color = "d4c5f9", description = "Blocked on an explicit decision" },
    ])
  }
}
