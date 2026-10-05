# CP Verdant GitHub Pages was enabled once in the GitHub UI before Terraform
# managed Pages. This declarative import adopts that existing site into state.
import {
  to = module.github_repos.github_repository_pages.managed["minecraft-modpack-cp-verdant"]
  id = "minecraft-modpack-cp-verdant"
}

# Iris is created once with a user token (GitHub Apps cannot POST /user/repos),
# then adopted into state. See ADR-008. Remove this block after the first apply
# that successfully imports the repository (or leave it — re-import of the same
# address is a no-op once the resource is in state).
import {
  to = module.github_repos.github_repository.managed["iris"]
  id = "iris"
}

# minecraft-modpack-ltm no longer exists on GitHub (404). Drop from state without
# destroy — github_repository has prevent_destroy, and the remote is already gone.
removed {
  from = module.github_repos.github_repository.managed["minecraft-modpack-ltm"]

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_repos.github_repository_vulnerability_alerts.managed["minecraft-modpack-ltm"]

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_repos.github_branch_protection.main["minecraft-modpack-ltm"]

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_repos.github_repository_file.codeowners["minecraft-modpack-ltm"]

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_repos.terraform_data.initialize_default_branch["minecraft-modpack-ltm"]

  lifecycle {
    destroy = false
  }
}

# homelab-azure / homelab-identity / homelab-proxmox imports removed — HCP workspaces
# disabled after PostgreSQL cutover (homelab-infra #214). Keeping import blocks would
# fail plan once tfe_workspace.spoke no longer contains those keys.
