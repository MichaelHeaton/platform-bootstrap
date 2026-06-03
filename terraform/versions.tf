terraform {
  required_version = ">= 1.10.0"

  cloud {
    organization = "McCleaton-Bootstrap"

    workspaces {
      name = "platform-bootstrap"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed-by = "terraform"
      repo       = "platform-bootstrap"
    }
  }
}

provider "github" {
  owner = var.github_org
  token = var.github_token
}

# SpecterRealm org — manages Colony Protocol pack repos.
# Requires TF_VAR_specterrealm_github_token in CI (same PAT scope as github_token
# if the token owner is an org member, otherwise a separate org-scoped PAT).
provider "github" {
  alias = "specterrealm"
  owner = "SpecterRealm"
  token = var.specterrealm_github_token
}
