output "workspace_ids" {
  description = "Map of pipeline key to HCP workspace ID."
  value       = { for k, ws in tfe_workspace.spoke : k => ws.id }
}

output "workspace_names" {
  description = "Map of pipeline key to HCP workspace name."
  value       = { for k, ws in tfe_workspace.spoke : k => ws.name }
}

output "workspace_html_urls" {
  description = "Map of pipeline key to HCP workspace URL."
  value       = { for k, ws in tfe_workspace.spoke : k => ws.html_url }
}

output "repos_by_github_org" {
  description = "Map of GitHub org to repo names with managed HCP workspaces."
  value = {
    for org in toset([for k, _ in local.pipelines_map : local.github_org[k]]) :
    org => [for k, p in local.pipelines_map : p.repo_name if local.github_org[k] == org]
  }
}
