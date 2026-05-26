resource "github_issue_label" "managed" {
  for_each = local.label_entries

  repository  = each.value.repository
  name        = each.value.name
  color       = each.value.color
  description = each.value.description
}
