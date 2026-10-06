# Pre-publication audit is enforced via .github/workflows/pre-publication-audit.yml
# — not via rulesets, to allow a manual approval step before any repo goes public.
# See ADR-004: GitHub Repository Management via Terraform.

resource "github_repository" "managed" {
  for_each = local.repos_map

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility
  topics      = each.value.topics

  has_issues      = try(each.value.has_issues, true)
  has_wiki        = try(each.value.has_wiki, false)
  has_projects    = try(each.value.has_projects, false)
  has_discussions = try(each.value.has_discussions, false)

  # Repositories are initialized by terraform_data.initialize_default_branch so
  # the first branch uses the configured name instead of the account default.
  auto_init = false

  allow_merge_commit     = try(each.value.squash_merge_only, false) ? false : true
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true

  dynamic "security_and_analysis" {
    for_each = each.value.visibility == "public" ? [1] : []
    content {
      secret_scanning {
        status = "enabled"
      }
      secret_scanning_push_protection {
        status = "enabled"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [auto_init]
  }
}

# vulnerability_alerts moved to a standalone resource per provider deprecation notice.
resource "github_repository_vulnerability_alerts" "managed" {
  for_each = local.repos_map

  repository = github_repository.managed[each.key].name
  enabled    = true
}

resource "github_repository_dependabot_security_updates" "managed" {
  for_each = local.dependabot_security_updates_repos

  repository = github_repository.managed[each.key].name
  enabled    = true
}

resource "github_actions_repository_permissions" "hardened" {
  for_each = local.actions_hardened_repos

  repository      = github_repository.managed[each.key].name
  enabled         = true
  allowed_actions = "selected"

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = true
    patterns_allowed     = []
  }
}

resource "github_workflow_repository_permissions" "hardened" {
  for_each = local.actions_hardened_repos

  repository                       = github_repository.managed[each.key].name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

resource "github_branch_protection" "main" {
  for_each = local.branch_protection_repos

  repository_id = github_repository.managed[each.key].node_id
  pattern       = each.value.default_branch

  depends_on = [
    github_repository_file.codeowners,
    terraform_data.ensure_license,
  ]

  # Default false: admins can bypass in emergencies (legacy). Opt-in enforce_admins
  # for repos that require no bypass (see ADR-008 / Iris).
  enforce_admins = try(each.value.enforce_admins, false)

  allows_deletions    = false
  allows_force_pushes = false

  require_signed_commits          = try(each.value.require_signed_commits, false)
  required_linear_history         = try(each.value.require_linear_history, false)
  require_conversation_resolution = try(each.value.require_conversation_resolution, false)

  required_pull_request_reviews {
    required_approving_review_count = 0
    dismiss_stale_reviews           = false
    require_code_owner_reviews      = false
  }

  # required_status_checks are intentionally left unset here.
  # Each repository configures its own required checks via its own workflow
  # files and branch protection settings. Centralising them here would couple
  # all repos to a single check list and make incremental rollout impossible.
}

resource "github_repository_file" "codeowners" {
  for_each = local.repos_map

  repository = github_repository.managed[each.key].name
  branch     = each.value.default_branch
  file       = try(each.value.codeowners_file, "CODEOWNERS")

  # "* <owner1> <owner2>" — every path owned by all listed handles.
  content = "* ${join(" ", var.codeowners)}\n"

  commit_message      = "chore: initialize CODEOWNERS"
  overwrite_on_create = true

  lifecycle {
    # The GitHub Contents API cannot push directly to a protected branch,
    # so Terraform must not attempt updates after the file is initially written.
    ignore_changes = all
  }

  depends_on = [terraform_data.initialize_default_branch]
}
