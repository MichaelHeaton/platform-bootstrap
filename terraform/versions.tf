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
  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = var.github_app_pem
  }
}

# SpecterRealm org — manages Colony Protocol pack repos.
provider "github" {
  alias = "specterrealm"
  owner = "SpecterRealm"
  app_auth {
    id              = var.github_app_id
    installation_id = var.specterrealm_github_app_installation_id
    pem_file        = var.github_app_pem
  }
}

# DEFERRED: specterrealm-homelab org provider
# Add when homelab repos are managed here. Requires HCP variable:
# specterrealm_homelab_github_app_installation_id (installation 138340201).
