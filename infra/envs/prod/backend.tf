# Remote state in the bucket created by infra/bootstrap.
# The bucket name is passed at init time, so it lives in one place:
#   make init ENV=prod                      (reads it from the bootstrap output)
#   terraform init -backend-config="bucket=<state bucket>"
# use_lockfile = native S3 state locking (Terraform 1.10+).
terraform {
  backend "s3" {
    key          = "magic-scotland/prod/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
