locals {
  pipelines_map = {
    for p in var.pipelines : "${p.environment}-${p.cloud}-${p.function}" => p
    if coalesce(p.tfe_workspace_enabled, true)
  }

  workspace_name = {
    for k, p in local.pipelines_map :
    k => coalesce(p.tfe_workspace_name, p.repo_name)
  }

  github_org = {
    for k, p in local.pipelines_map :
    k => coalesce(p.github_org, var.default_github_org)
  }
}

resource "tfe_workspace" "spoke" {
  for_each = local.pipelines_map

  name         = local.workspace_name[each.key]
  organization = var.tfe_organization
  description  = "Domain spoke — managed by platform-bootstrap (${each.key})"

  working_directory = each.value.terraform_working_directory
  auto_apply        = false
  queue_all_runs    = false

  vcs_repo {
    identifier         = "${local.github_org[each.key]}/${each.value.repo_name}"
    oauth_token_id     = var.tfe_vcs_oauth_token_id
    ingress_submodules = false
  }

  trigger_patterns = [
    "/${each.value.terraform_working_directory}/**/*",
    "/.github/workflows/terraform-*.yml",
  ]
}

resource "tfe_workspace_settings" "spoke" {
  for_each = local.pipelines_map

  workspace_id   = tfe_workspace.spoke[each.key].id
  execution_mode = coalesce(each.value.tfe_execution_mode, "remote")
}

resource "tfe_variable" "aws_provider_auth" {
  for_each = local.pipelines_map

  workspace_id = tfe_workspace.spoke[each.key].id
  key          = "TFC_AWS_PROVIDER_AUTH"
  value        = "true"
  category     = "env"
}

resource "tfe_variable" "aws_run_role_arn" {
  for_each = local.pipelines_map

  workspace_id = tfe_workspace.spoke[each.key].id
  key          = "TFC_AWS_RUN_ROLE_ARN"
  value        = var.pipeline_tfe_role_arns[each.key]
  category     = "env"
}

resource "tfe_variable" "aws_workload_identity_audience" {
  for_each = local.pipelines_map

  workspace_id = tfe_workspace.spoke[each.key].id
  key          = "TFC_AWS_WORKLOAD_IDENTITY_AUDIENCE"
  value        = "aws.workload.identity"
  category     = "env"
}

resource "tfe_variable" "aws_region" {
  for_each = local.pipelines_map

  workspace_id = tfe_workspace.spoke[each.key].id
  key          = "aws_region"
  value        = var.aws_region
  category     = "terraform"
}
