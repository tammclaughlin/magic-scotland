# One complete environment (dev or prod). infra/envs/<env> calls this module
# with its own settings and its own state file, so the two can never touch
# each other's resources.

locals {
  name = "${var.project}-${var.env}"
}

module "network" {
  source   = "../network"
  name     = local.name
  vpc_cidr = var.vpc_cidr
}

module "shared" {
  source           = "../shared"
  name             = local.name
  project          = var.project
  env              = var.env
  notify_email     = var.notify_email
  ses_sender_email = var.notify_email # same verified address sends and receives
  domain_name      = var.domain_name
}

# Alarm notifications by email (confirm the subscription email AWS sends you).
resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- EC2 path ---------------------------------------------------------------
module "ec2_site" {
  count  = var.enable_ec2 ? 1 : 0
  source = "../ec2_site"

  name              = local.name
  region            = var.region
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.public_subnet_ids[0]
  instance_type     = var.instance_type
  architecture      = var.architecture
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  web_allowed_cidrs = var.web_allowed_cidrs
  app_policy_arn    = module.shared.app_policy_arn
  zone_id           = module.shared.zone_id
  dns_name          = var.domain_name == "" ? "" : "ec2-${var.env}.${var.domain_name}"
  alarm_topic_arn   = aws_sns_topic.alarms.arn
}

# --- Container path (ECS on Fargate) -----------------------------------------
module "ecs_site" {
  count  = var.enable_ecs ? 1 : 0
  source = "../ecs_site"

  name               = local.name
  region             = var.region
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.public_subnet_ids
  ecr_repository_url = module.shared.ecr_repository_url
  image_tag          = var.initial_image_tag
  cpu_architecture   = var.architecture == "arm64" ? "ARM64" : "X86_64"
  desired_count      = var.ecs_desired_count
  enable_alb         = var.enable_alb
  app_policy_arn     = module.shared.app_policy_arn
  ssm_prefix         = module.shared.ssm_prefix
  certificate_arn    = module.shared.certificate_arn
  web_allowed_cidrs  = var.web_allowed_cidrs
  zone_id            = module.shared.zone_id
  dns_name           = var.domain_name == "" ? "" : "www-${var.env}.${var.domain_name}"
  alarm_topic_arn    = aws_sns_topic.alarms.arn
}
