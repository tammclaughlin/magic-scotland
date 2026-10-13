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
  description = "Where contact form notifications are sent (SES identity, see bootstrap)."
  type        = string
}

variable "ses_sender_email" {
  description = "From address for notifications (SES identity, see bootstrap)."
  type        = string
}

variable "domain_name" {
  description = "Domain with an existing Route 53 hosted zone, or empty to skip DNS/TLS."
  type        = string
  default     = ""
}
