terraform {
  required_version = ">= 1.10.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.67"
    }
  }
}
