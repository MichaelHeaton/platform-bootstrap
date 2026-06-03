# Label removal is not exposed by integrations/github v6.x.
# Discussion categories cannot be created via the public GitHub API — verify
# required slugs in compliance (scripts/github_repo_extras.py) and create any
# custom categories once in the repo Settings UI (see runbook 05).

locals {
  extras_script = abspath("${path.module}/../../../scripts/github_repo_extras.py")
}

resource "terraform_data" "initialize_default_branch" {
  for_each = local.repos_map

  input = {
    repository               = each.value.name
    branch                   = each.value.default_branch
    codeowners               = join(" ", var.codeowners)
    license_spdx_id          = try(each.value.license.spdx_id, "")
    license_copyright_holder = try(each.value.license.copyright_holder, "")
  }

  depends_on = [github_repository.managed]

  provisioner "local-exec" {
    command = "python3 ${local.extras_script} ensure-default-branch --repo ${jsonencode(each.value.name)} --branch ${jsonencode(each.value.default_branch)} --codeowners ${jsonencode(join(" ", var.codeowners))} --license-spdx-id ${jsonencode(try(each.value.license.spdx_id, ""))} --license-copyright-holder ${jsonencode(try(each.value.license.copyright_holder, ""))}"
    environment = {
      GITHUB_TOKEN = var.github_token
      GITHUB_ORG   = var.github_org
    }
  }
}

resource "terraform_data" "ensure_license" {
  for_each = local.license_entries

  input = each.value

  depends_on = [terraform_data.initialize_default_branch]

  provisioner "local-exec" {
    command = "python3 ${local.extras_script} ensure-license --repo ${jsonencode(each.value.repository)} --branch ${jsonencode(each.value.branch)} --license-spdx-id ${jsonencode(each.value.spdx_id)} --license-copyright-holder ${jsonencode(each.value.copyright_holder)}"
    environment = {
      GITHUB_TOKEN = var.github_token
      GITHUB_ORG   = var.github_org
    }
  }
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
