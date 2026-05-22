output "repository_ids" {
  description = "Map of repository name to GitHub node ID"
  value       = { for k, r in github_repository.managed : k => r.node_id }
}

output "repository_urls" {
  description = "Map of repository name to clone URL"
  value       = { for k, r in github_repository.managed : k => r.html_url }
}
