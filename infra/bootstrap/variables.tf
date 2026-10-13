variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "project" {
  type    = string
  default = "magic-scotland"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the owner)."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "false if the account already has a GitHub OIDC provider (make preflight tells you)."
  type        = bool
  default     = true
}

variable "notify_email" {
  description = "Address that receives (and sends) contact-form notifications."
  type        = string
}

variable "create_ses_identity" {
  description = "false if make preflight shows this address is already an SES identity."
  type        = bool
  default     = true
}

variable "budget_email" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}
