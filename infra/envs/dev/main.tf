locals {
  env      = "dev"
  vpc_cidr = "10.20.0.0/16"
}

module "stack" {
  source = "../../modules/stack"

  project  = var.project
  env      = local.env
  region   = var.region
  vpc_cidr = local.vpc_cidr

  enable_ec2        = var.enable_ec2
  enable_ecs        = var.enable_ecs
  enable_alb        = var.enable_alb
  instance_type     = var.instance_type
  architecture      = var.architecture
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  web_allowed_cidrs = var.web_allowed_cidrs
  notify_email      = var.notify_email
  alarm_email       = var.alarm_email
  domain_name       = var.domain_name
}
