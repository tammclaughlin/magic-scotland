variable "name" {
  description = "Name prefix, e.g. magic-scotland-dev."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
