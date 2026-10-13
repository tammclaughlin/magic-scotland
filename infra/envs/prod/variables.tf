variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "project" {
  type    = string
  default = "magic-scotland"
}

# Feature flags: run one path at a time to save money.
variable "enable_ec2" {
  type    = bool
  default = true
}

variable "enable_ecs" {
  description = "Turn on once an image tagged latest is in this environment's ECR."
  type        = bool
  default     = false
}

variable "enable_alb" {
  description = "FINAL STEP: add the load balancer once EC2 and ECS both work."
  type        = bool
  default     = false
}

variable "instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "architecture" {
  type    = string
  default = "arm64"
}

variable "ssh_public_key" {
  description = "Contents of your SSH PUBLIC key (~/.ssh/magic-scotland.pub)."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Your IP(s) as /32 for SSH."
  type        = list(string)
}

variable "web_allowed_cidrs" {
  description = "Who may open the website. Your IP /32 keeps the test site private; [\"0.0.0.0/0\"] opens it."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "notify_email" {
  description = "Contact-form notifications go to (and come from) this SES-verified address."
  type        = string
}

variable "alarm_email" {
  type = string
}

variable "domain_name" {
  description = "Empty: no domain, the site uses AWS addresses over HTTP."
  type        = string
  default     = ""
}
