variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "project" {
  type    = string
  default = "magic-scotland"
}

variable "env" {
  type    = string
  default = "dev"
}

# Feature flags: run one path at a time to save money.
variable "enable_ec2" {
  type    = bool
  default = true
}

variable "enable_ecs" {
  description = "Turn on after the first image has been pushed to ECR."
  type        = bool
  default     = false
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ec2_architecture" {
  type    = string
  default = "amd64"
}

variable "ssh_public_key" {
  description = "Contents of your SSH PUBLIC key."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Your home/office IP(s) as /32."
  type        = list(string)
}

variable "notify_email" {
  type = string
}

variable "ses_sender_email" {
  type = string
}

variable "budget_email" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}

variable "domain_name" {
  description = "Domain with a Route 53 hosted zone, or empty for no DNS/TLS."
  type        = string
  default     = ""
}

variable "initial_image_tag" {
  type    = string
  default = "latest"
}
