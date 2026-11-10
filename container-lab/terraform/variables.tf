variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "image_tag" {
  description = <<-EOT
    Tag of both images to run (make deploy passes the git SHA).
    Empty = create everything but run no tasks: that's the first apply, before any image exists.
  EOT
  type        = string
  default     = ""
}

variable "allowed_cidrs" {
  description = "Who may reach nginx on port 80. Same default as web_allowed_cidrs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
