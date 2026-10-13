# Remote state in the bucket created by infra/bootstrap.
# use_lockfile = native S3 state locking (Terraform 1.10+), no DynamoDB table needed.
terraform {
  backend "s3" {
    bucket       = "CHANGE_ME-magic-scotland-tfstate" # output "state_bucket" from bootstrap
    key          = "magic-scotland/dev/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
