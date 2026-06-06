# Short-lived installation token for local-exec extras (default branch init, license
# commits, label deletion). Minted at plan/apply time from the GitHub App credentials.
data "github_app_token" "local_exec" {
  app_id          = var.github_app_id
  installation_id = var.github_app_installation_id
  pem_file        = var.github_app_pem
}
