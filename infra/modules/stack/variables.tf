variable "project" {
  type = string
}

variable "env" {
  description = "dev or prod"
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  description = "Different per environment so the two VPCs could be peered later."
  type        = string
}

variable "enable_ec2" {
  type = bool
}

variable "enable_ecs" {
  type = bool
}

variable "instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "architecture" {
  description = "arm64 (t4g, Graviton) or amd64 (t3). Images must be built to match."
  type        = string
  default     = "arm64"
}

variable "enable_alb" {
  description = "Final step, once everything else works: ALB in front of the ECS tasks."
  type        = bool
  default     = false
}

variable "ecs_desired_count" {
  type    = number
  default = 1
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_allowed_cidrs" {
  type = list(string)
}

variable "web_allowed_cidrs" {
  type = list(string)
}

variable "notify_email" {
  type = string
}

variable "alarm_email" {
  type = string
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "initial_image_tag" {
  type    = string
  default = "latest"
}
