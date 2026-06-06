# CurseForge upload — GHA OIDC roles read personal/curseforge-api-key from SM.
# Workflows assume AWS_CURSEFORGE_UPLOAD_ROLE_ARN (set below) and fetch the key at runtime.

locals {
  curseforge_upload_pipeline_keys = {
    for p in var.pipelines :
    "${coalesce(p.github_org, var.github_org)}/${p.repo_name}" => "${p.environment}-${p.cloud}-${p.function}"
    if contains(coalesce(p.secretsmanager_secret_names, []), "personal/curseforge-api-key")
  }

  curseforge_upload_pipelines_michaelheaton = {
    for k, pipeline_key in local.curseforge_upload_pipeline_keys :
    k => pipeline_key
    if startswith(k, "${var.github_org}/")
  }

  curseforge_upload_pipelines_specterrealm = {
    for k, pipeline_key in local.curseforge_upload_pipeline_keys :
    k => pipeline_key
    if startswith(k, "SpecterRealm/")
  }
}

resource "github_actions_secret" "curseforge_upload_role_arn" {
  for_each = local.curseforge_upload_pipelines_michaelheaton

  repository  = split("/", each.key)[1]
  secret_name = "AWS_CURSEFORGE_UPLOAD_ROLE_ARN"
  value       = module.oidc_roles.pipeline_role_arns[each.value]

  depends_on = [module.github_repos, module.oidc_roles]
}

resource "github_actions_secret" "curseforge_upload_role_arn_specterrealm" {
  for_each = local.curseforge_upload_pipelines_specterrealm

  provider = github.specterrealm

  repository  = split("/", each.key)[1]
  secret_name = "AWS_CURSEFORGE_UPLOAD_ROLE_ARN"
  value       = module.oidc_roles.pipeline_role_arns[each.value]

  depends_on = [module.github_repos_specterrealm, module.oidc_roles]
}
