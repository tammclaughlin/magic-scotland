locals {
  name = "${var.project}-${var.env}"
}

module "network" {
  source = "../../modules/network"
  name   = local.name
}

module "shared" {
  source             = "../../modules/shared"
  name               = local.name
  project            = var.project
  env                = var.env
  notify_email       = var.notify_email
  ses_sender_email   = var.ses_sender_email
  budget_email       = var.budget_email
  monthly_budget_usd = var.monthly_budget_usd
  domain_name        = var.domain_name
}

# Alarm notifications by email (confirm the subscription email AWS sends you).
resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.budget_email
}

# --- EC2 path ---------------------------------------------------------------
module "ec2_site" {
  count  = var.enable_ec2 ? 1 : 0
  source = "../../modules/ec2_site"

  name              = local.name
  region            = var.region
  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.public_subnet_ids[0]
  instance_type     = var.instance_type
  architecture      = var.ec2_architecture
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  app_policy_arn    = module.shared.app_policy_arn
  zone_id           = module.shared.zone_id
  dns_name          = var.domain_name == "" ? "" : "ec2.${var.domain_name}"
  alarm_topic_arn   = aws_sns_topic.alarms.arn
}

# --- Container path (ECS on Fargate) -----------------------------------------
module "ecs_site" {
  count  = var.enable_ecs ? 1 : 0
  source = "../../modules/ecs_site"

  name               = local.name
  region             = var.region
  vpc_id             = module.network.vpc_id
  subnet_ids         = module.network.public_subnet_ids
  ecr_repository_url = module.shared.ecr_repository_url
  image_tag          = var.initial_image_tag
  app_policy_arn     = module.shared.app_policy_arn
  ssm_prefix         = module.shared.ssm_prefix
  certificate_arn    = module.shared.certificate_arn
  zone_id            = module.shared.zone_id
  dns_name           = var.domain_name == "" ? "" : "www.${var.domain_name}"
  alarm_topic_arn    = aws_sns_topic.alarms.arn
}
