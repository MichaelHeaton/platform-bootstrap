# Import blocks for repositories that existed before being added to managed_repositories.
# Remove an import block after the first successful apply that includes it.

import {
  to = module.github_repos.github_repository.managed["claude-skills"]
  id = "claude-skills"
}

import {
  to = module.github_repos.github_repository_vulnerability_alerts.managed["claude-skills"]
  id = "claude-skills"
}

import {
  to = module.github_repos.github_repository_file.codeowners["claude-skills"]
  id = "claude-skills:CODEOWNERS:Main"
}

import {
  to = module.github_repos.github_repository.managed["memex"]
  id = "memex"
}

import {
  to = module.github_repos.github_repository_vulnerability_alerts.managed["memex"]
  id = "memex"
}

import {
  to = module.github_repos.github_repository_file.codeowners["memex"]
  id = "memex:CODEOWNERS:main"
}
