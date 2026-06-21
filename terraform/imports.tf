# CP Verdant GitHub Pages was enabled once in the GitHub UI before Terraform
# managed Pages. This declarative import adopts that existing site into state.
import {
  to = module.github_repos.github_repository_pages.managed["minecraft-modpack-cp-verdant"]
  id = "minecraft-modpack-cp-verdant"
}

# homelab-azure, homelab-identity, and homelab-proxmox HCP workspaces were created
# before platform-bootstrap managed them. These imports adopt them into TF state.
import {
  to = module.tfe_workspaces[0].tfe_workspace.spoke["personal-homelab-azure"]
  id = "McCleaton-Bootstrap/homelab-azure"
}

import {
  to = module.tfe_workspaces[0].tfe_workspace.spoke["personal-homelab-identity"]
  id = "McCleaton-Bootstrap/homelab-identity"
}

import {
  to = module.tfe_workspaces[0].tfe_workspace.spoke["personal-homelab-proxmox"]
  id = "McCleaton-Bootstrap/homelab-proxmox"
}
