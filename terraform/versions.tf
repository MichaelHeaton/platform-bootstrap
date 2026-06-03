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
  token = var.tfe_pb_michaelheaton
}

# SpecterRealm org — manages Colony Protocol pack repos.
provider "github" {
  alias = "specterrealm"
  owner = "SpecterRealm"
  token = var.tfe_pb_specterrealm
}

# specterrealm-homelab org — manages homelab infrastructure repos.
provider "github" {
  alias = "specterrealm_homelab"
  owner = "specterrealm-homelab"
  token = var.tfe_pb_specterrealm_homelab
}
