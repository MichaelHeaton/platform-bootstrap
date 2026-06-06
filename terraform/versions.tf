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
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.67"
    }
  }
}

provider "tfe" {
  hostname = var.tfe_hostname
  token    = var.tfe_api_token
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

# SpecterRealm org — Colony Protocol / Minecraft modpack repos.
provider "github" {
  alias = "specterrealm"
  owner = "SpecterRealm"
  app_auth {
    id              = var.github_app_id
    installation_id = var.specterrealm_github_app_installation_id
    pem_file        = var.github_app_pem
  }
}

# McCleaton org — personal platform and domain infrastructure (Cloudflare, cloud spokes).
provider "github" {
  alias = "mccleaton"
  owner = var.mccleaton_org
  app_auth {
    id              = var.github_app_id
    installation_id = var.mccleaton_github_app_installation_id
    pem_file        = var.github_app_pem
  }
}

# DEFERRED: specterrealm-homelab org provider
# Add when homelab repos are managed here. Requires HCP variable:
# specterrealm_homelab_github_app_installation_id (installation 138340201).
