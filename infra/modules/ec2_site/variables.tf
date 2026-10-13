variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "instance_type" {
  description = "t3.medium = 2 vCPU / 4 GiB (x86). Use t4g.medium with architecture = arm64 for ~20% less."
  type        = string
  default     = "t3.medium"
}

variable "architecture" {
  description = "amd64 for t3.*, arm64 for t4g.*"
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.architecture)
    error_message = "architecture must be amd64 or arm64."
  }
}

variable "root_volume_gb" {
  type    = number
  default = 20
}

variable "ssh_public_key" {
  description = "Contents of your PUBLIC key, e.g. ~/.ssh/magic-scotland.pub"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Admin IPs allowed to SSH, e.g. [\"203.0.113.10/32\"]"
  type        = list(string)
}

variable "app_policy_arn" {
  type = string
}

variable "zone_id" {
  type    = string
  default = ""
}

variable "dns_name" {
  type    = string
  default = ""
}

variable "alarm_topic_arn" {
  type    = string
  default = ""
}
