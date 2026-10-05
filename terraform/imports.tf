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

# minecraft-modpack-ltm no longer exists on GitHub (404). OpenTofu cannot
# `removed` a for_each instance key directly — move each instance to a
# temporary non-indexed address, then forget with destroy = false.
# (Same pattern as opentofu/opentofu#3361.) Delete these blocks after one
# successful apply that clears them from state.

moved {
  from = module.github_repos.github_repository.managed["minecraft-modpack-ltm"]
  to   = github_repository.forgotten_minecraft_modpack_ltm
}

moved {
  from = module.github_repos.github_repository_vulnerability_alerts.managed["minecraft-modpack-ltm"]
  to   = github_repository_vulnerability_alerts.forgotten_minecraft_modpack_ltm
}

moved {
  from = module.github_repos.github_branch_protection.main["minecraft-modpack-ltm"]
  to   = github_branch_protection.forgotten_minecraft_modpack_ltm
}

moved {
  from = module.github_repos.github_repository_file.codeowners["minecraft-modpack-ltm"]
  to   = github_repository_file.forgotten_minecraft_modpack_ltm
}

moved {
  from = module.github_repos.terraform_data.initialize_default_branch["minecraft-modpack-ltm"]
  to   = terraform_data.forgotten_minecraft_modpack_ltm
}

removed {
  from = github_repository.forgotten_minecraft_modpack_ltm

  lifecycle {
    destroy = false
  }
}

removed {
  from = github_repository_vulnerability_alerts.forgotten_minecraft_modpack_ltm

  lifecycle {
    destroy = false
  }
}

removed {
  from = github_branch_protection.forgotten_minecraft_modpack_ltm

  lifecycle {
    destroy = false
  }
}

removed {
  from = github_repository_file.forgotten_minecraft_modpack_ltm

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.forgotten_minecraft_modpack_ltm

  lifecycle {
    destroy = false
  }
}

# homelab-azure / homelab-identity / homelab-proxmox imports removed — HCP workspaces
# disabled after PostgreSQL cutover (homelab-infra #214). Keeping import blocks would
# fail plan once tfe_workspace.spoke no longer contains those keys.
