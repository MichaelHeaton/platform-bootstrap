locals {
  repos_map = { for r in var.repositories : r.name => r }

  label_entries = {
    for entry in flatten([
      for repo in var.repositories : [
        for label in try(repo.labels, []) : {
          key         = "${repo.name}/${label.name}"
          repository  = repo.name
          name        = label.name
          color       = label.color
          description = try(label.description, "")
        }
      ]
    ]) : entry.key => entry
  }

  label_remove_entries = {
    for entry in flatten([
      for repo in var.repositories : [
        for label_name in try(repo.labels_remove, []) : {
          key        = "${repo.name}/${label_name}"
          repository = repo.name
          name       = label_name
        }
      ]
    ]) : entry.key => entry
  }

  license_entries = {
    for name, repo in local.repos_map : name => {
      repository       = repo.name
      branch           = repo.default_branch
      spdx_id          = repo.license.spdx_id
      copyright_holder = try(repo.license.copyright_holder, "Michael Heaton")
    }
    if try(repo.license, null) != null
  }

  main_ruleset_repos = {
    for name, repo in local.repos_map : name => repo
    if try(repo.main_branch_ruleset, false)
  }

  main_protection_repos = {
    for name, repo in local.repos_map : name => repo
    if try(repo.main_branch_protection, true)
  }

  pages_repos = {
    for name, repo in local.repos_map : name => repo
    if try(repo.pages, null) != null
  }
}
