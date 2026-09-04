# CP Verdant GitHub Pages was enabled once in the GitHub UI before Terraform
# managed Pages. This declarative import adopts that existing site into state.
import {
  to = module.github_repos.github_repository_pages.managed["minecraft-modpack-cp-verdant"]
  id = "minecraft-modpack-cp-verdant"
}

# homelab-azure / homelab-identity / homelab-proxmox imports removed — HCP workspaces
# disabled after PostgreSQL cutover (homelab-infra #214). Keeping import blocks would
# fail plan once tfe_workspace.spoke no longer contains those keys.
