# Temporary import blocks — remove after first successful apply.

import {
  to = module.github_repos.github_repository.managed["memex-suite"]
  id = "memex-suite"
}

import {
  to = module.github_repos.github_repository_vulnerability_alerts.managed["memex-suite"]
  id = "memex-suite"
}

# GitHub renamed the branch protection rule from "Main" to "main" when the branch
# was renamed. Terraform state still says "Main" so it tried to create a duplicate.
# Import the renamed rule so state reflects reality before apply proceeds.
import {
  to = module.github_repos.github_branch_protection.main["claude-skills"]
  id = "R_kgDOSRKtgw:main"
}
