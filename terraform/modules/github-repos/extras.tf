# Discussion categories and label removal are not exposed by integrations/github v6.x.

locals {
  extras_script = abspath("${path.module}/../../../scripts/github_repo_extras.py")
}

resource "terraform_data" "discussion_category" {
  for_each = local.discussion_category_entries

  input = {
    repository  = each.value.repository
    name        = each.value.name
    slug        = each.value.slug
    description = each.value.description
    emoji       = each.value.emoji
  }

  depends_on = [github_repository.managed]

  provisioner "local-exec" {
    command = <<-EOT
      python3 ${local.extras_script} ensure-discussion-category \
        --repo ${each.value.repository} \
        --name ${jsonencode(each.value.name)} \
        --slug ${jsonencode(each.value.slug)} \
        --description ${jsonencode(each.value.description)} \
        ${each.value.emoji != "" ? "--emoji ${jsonencode(each.value.emoji)}" : ""}
    EOT
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
    command = <<-EOT
      python3 ${local.extras_script} delete-label \
        --repo ${each.value.repository} \
        --name ${jsonencode(each.value.name)}
    EOT
    environment = {
      GITHUB_TOKEN = var.github_token
      GITHUB_ORG   = var.github_org
    }
  }
}
