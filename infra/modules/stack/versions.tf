# Child module: minimum versions only. The root modules (infra/envs/*) pin
# with ~> and the lock file fixes the exact build.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}
