# Import blocks for SpecterRealm repos created directly before the IaC pattern
# was enforced. These adopt the existing repositories into Terraform state on
# the next `terraform apply`. Remove this file once the import has run.

import {
  to = module.github_repos_specterrealm.github_repository.managed["specterrealm-core"]
  id = "specterrealm-core"
}

import {
  to = module.github_repos_specterrealm.github_repository.managed["minecraft-modpack-cp-elysian"]
  id = "minecraft-modpack-cp-elysian"
}

import {
  to = module.github_repos_specterrealm.github_repository.managed["minecraft-modpack-cp-influx"]
  id = "minecraft-modpack-cp-influx"
}
