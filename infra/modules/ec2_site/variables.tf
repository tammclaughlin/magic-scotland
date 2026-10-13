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
  description = "t4g.medium = 2 vCPU / 4 GiB, ARM (Graviton). Use t3.medium with architecture = amd64 for x86."
  type        = string
  default     = "t4g.medium"
}

variable "architecture" {
  description = "arm64 for t4g.*, amd64 for t3.*"
  type        = string
  default     = "arm64"
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

variable "web_allowed_cidrs" {
  description = "Who may reach the website on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
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
