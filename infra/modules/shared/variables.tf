variable "name" {
  type = string
}

variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "notify_email" {
  description = "Where contact form notifications are sent (verified in SES)."
  type        = string
}

variable "ses_sender_email" {
  description = "From address for notifications (verified in SES). Can equal notify_email."
  type        = string
}

variable "budget_email" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 20
}

variable "domain_name" {
  description = "Apex domain with an existing Route 53 hosted zone, or empty to skip DNS/TLS."
  type        = string
  default     = ""
}
