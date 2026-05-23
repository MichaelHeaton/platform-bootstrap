terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.3"
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
}
