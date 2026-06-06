# CP Verdant GitHub Pages was enabled once in the GitHub UI before Terraform
# managed Pages. This declarative import adopts that existing site into state.
import {
  to = module.github_repos.github_repository_pages.managed["minecraft-modpack-cp-verdant"]
  id = "minecraft-modpack-cp-verdant"
}

# cloudflare: GitHub App installation tokens cannot POST /user/repos on personal
# accounts. Create the empty repo manually (runbook 09 step 1b), then apply.
import {
  to = module.github_repos.github_repository.managed["cloudflare"]
  id = "cloudflare"
}
