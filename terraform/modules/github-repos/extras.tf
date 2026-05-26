# Label removal is not exposed by integrations/github v6.x.
# Discussion categories cannot be created via the public GitHub API — verify
# required slugs in compliance (scripts/github_repo_extras.py) and create any
# custom categories once in the repo Settings UI (see runbook 05).

locals {
  extras_script = abspath("${path.module}/../../../scripts/github_repo_extras.py")
}

resource "terraform_data" "label_remove" {
  for_each = local.label_remove_entries

  input = {
    repository = each.value.repository
    name       = each.value.name
  }

  provisioner "local-exec" {
    command = "python3 ${local.extras_script} delete-label --repo ${each.value.repository} --name ${jsonencode(each.value.name)}"
    environment = {
      GITHUB_TOKEN = var.github_token
      GITHUB_ORG   = var.github_org
    }
  }
}
