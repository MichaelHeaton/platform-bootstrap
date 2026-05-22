# platform-bootstrap is explicitly excluded from GitHub management.
# See ADR-004: GitHub Repository Management via Terraform.
# This repo was created manually and is maintained manually.

module "state_bucket" {
  source = "./modules/s3-state"

  bucket_name = var.state_bucket_name

  tags = {
    environment = "shared"
    cloud       = "aws"
    function    = "state"
    managed-by  = "terraform"
  }
}

module "oidc_roles" {
  source = "./modules/oidc-roles"

  github_org       = var.github_org
  aws_account_id   = var.aws_account_id
  state_bucket_arn = module.state_bucket.bucket_arn
  pipelines        = var.pipelines
}

module "github_repos" {
  source = "./modules/github-repos"

  repositories   = var.managed_repositories
  default_branch = "main"
  codeowners     = ["@MichaelHeaton"] # See CODEOWNERS
}

# DEFERRED: Multi-account AWS via AWS Organizations
# See ADR-006: In-repo modules
# Pending: scale review before implementing cross-account trust

# DEFERRED: Azure provider
# See ADR-006: In-repo modules
# Pending: confirmed need

# DEFERRED: GitLab provider
# Pending: GitLab support in target CI platform
