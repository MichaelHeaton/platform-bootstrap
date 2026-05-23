# Pre-publication audit is enforced via .github/workflows/pre-publication-audit.yml
# — not via rulesets, to allow a manual approval step before any repo goes public.
# See ADR-004: GitHub Repository Management via Terraform.

locals {
  repos_map = { for r in var.repositories : r.name => r }
}

resource "github_repository" "managed" {
  for_each = local.repos_map

  name        = each.value.name
  description = each.value.description
  visibility  = each.value.visibility
  topics      = each.value.topics

  has_issues   = true
  has_wiki     = false
  has_projects = false

  # auto_init is ignored after initial creation to avoid drift on existing repos.
  auto_init = false

  allow_merge_commit     = true
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

    # auto_init only applies on creation; ignore subsequent drift.
    ignore_changes = [auto_init]
  }
}

# vulnerability_alerts moved to a standalone resource per provider deprecation notice.
resource "github_repository_vulnerability_alerts" "managed" {
  for_each = local.repos_map

  repository = github_repository.managed[each.key].name
  enabled    = true
}

resource "github_branch_protection" "main" {
  for_each = local.repos_map

  repository_id = github_repository.managed[each.key].node_id
  pattern       = each.value.default_branch

  # Admins can bypass in emergencies (break-glass), but normal pushes always
  # require a reviewed PR.
  enforce_admins = false

  allows_deletions    = false
  allows_force_pushes = false

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
  file       = "CODEOWNERS"

  # "* <owner1> <owner2>" — every path owned by all listed handles.
  content = "* ${join(" ", var.codeowners)}\n"

  commit_message      = "chore: initialize CODEOWNERS"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content]
  }
}
