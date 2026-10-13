terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials: locally via AWS_PROFILE (the Makefile sets claude-ro / claude-rw),
# in GitHub Actions via the OIDC role.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Env       = local.env
      ManagedBy = "terraform"
    }
  }
}
