resource "github_repository_pages" "managed" {
  for_each = local.pages_repos

  repository = github_repository.managed[each.key].name
  build_type = try(each.value.pages.build_type, "legacy")

  dynamic "source" {
    for_each = try(each.value.pages.source, null) == null ? [] : [each.value.pages.source]

    content {
      branch = source.value.branch
      path   = try(source.value.path, "/")
    }
  }

  cname          = try(each.value.pages.cname, null)
  public         = try(each.value.pages.public, null)
  https_enforced = try(each.value.pages.https_enforced, null)
}
