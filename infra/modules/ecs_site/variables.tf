variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag" {
  description = "Initial image tag. Later deploys come from the pipeline (commit SHA tags)."
  type        = string
  default     = "latest"
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64 - must match how the image was built."
  type        = string
  default     = "ARM64"
}

variable "task_cpu" {
  type    = number
  default = 256 # 0.25 vCPU
}

variable "task_memory" {
  type    = number
  default = 512 # MiB
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "enable_alb" {
  description = "Final step: put an Application Load Balancer in front of the tasks."
  type        = bool
  default     = false
}

variable "web_allowed_cidrs" {
  description = "Who may reach the load balancer on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_policy_arn" {
  type = string
}

variable "ssm_prefix" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate ARN. Empty = HTTP only."
  type        = string
  default     = ""
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
