terraform {
  required_version = ">= 1.10"

  # Local state (terraform.tfstate here, gitignored). It's a throwaway lab:
  # if you lose the state, delete the resources named magic-scotland-dev-lab* by hand.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "magic-scotland", Env = "dev", Role = "lab" }
  }
}
