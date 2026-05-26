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

  discussion_category_entries = {
    for entry in flatten([
      for repo in var.repositories : [
        for category in try(repo.discussion_categories, []) : {
          key         = "${repo.name}/${try(category.slug, replace(lower(category.name), " ", "-"))}"
          repository  = repo.name
          name        = category.name
          slug        = try(category.slug, replace(lower(category.name), " ", "-"))
          description = category.description
          emoji       = try(category.emoji, "")
        }
      ]
    ]) : entry.key => entry
  }

  main_ruleset_repos = {
    for name, repo in local.repos_map : name => repo
    if try(repo.main_branch_ruleset, false)
  }
}
