# Optional ATM-style ruleset: block branch deletion and force-push on the default branch.
# PR requirement remains on github_branch_protection.main.

resource "github_repository_ruleset" "main" {
  for_each = local.main_ruleset_repos

  name        = "main-branch-guardrails"
  target      = "branch"
  repository  = each.value.name
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true
  }
}
