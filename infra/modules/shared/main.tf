# Resources both deploy paths use: ECR, DynamoDB, SES, SSM parameters,
# the IAM policy the app needs, a budget alert, and optional DNS + TLS.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_prefix = "/${var.project}/${var.env}"
}

# ---------------------------------------------------------------------------
# Container registry
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # learning project: allow destroy with images inside

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Contact form submissions
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "contact" {
  name         = "${var.name}-contact"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# Email (SES). New accounts are in the SES sandbox: you can only send to
# verified addresses. Verifying your own address is enough here, because the
# form only emails you. AWS sends a confirmation link to this address.
# ---------------------------------------------------------------------------
resource "aws_ses_email_identity" "notify" {
  email = var.notify_email
}

resource "aws_ses_email_identity" "sender" {
  count = var.ses_sender_email == var.notify_email ? 0 : 1
  email = var.ses_sender_email
}

# ---------------------------------------------------------------------------
# App settings in SSM Parameter Store, read by the app at start-up
# ---------------------------------------------------------------------------
resource "random_password" "secret_key" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "secret_key" {
  name  = "${local.ssm_prefix}/secret_key"
  type  = "SecureString"
  value = random_password.secret_key.result
}

resource "aws_ssm_parameter" "contact_table" {
  name  = "${local.ssm_prefix}/contact_table"
  type  = "String"
  value = aws_dynamodb_table.contact.name
}

resource "aws_ssm_parameter" "ses_sender" {
  name  = "${local.ssm_prefix}/ses_sender"
  type  = "String"
  value = var.ses_sender_email
}

resource "aws_ssm_parameter" "notify_email" {
  name  = "${local.ssm_prefix}/notify_email"
  type  = "String"
  value = var.notify_email
}

# ---------------------------------------------------------------------------
# What the running app may do (attached to the EC2 role and ECS task role)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "app" {
  statement {
    sid       = "WriteContactSubmissions"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.contact.arn]
  }
  statement {
    sid       = "SendNotificationEmail"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.ses_sender_email]
    }
  }
  statement {
    sid     = "ReadAppSettings"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
    ]
  }
}

resource "aws_iam_policy" "app" {
  name   = "${var.name}-app"
  policy = data.aws_iam_policy_document.app.json
}

# ---------------------------------------------------------------------------
# Budget alert
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}

# ---------------------------------------------------------------------------
# Optional: DNS + ACM certificate (only when domain_name is set)
# Assumes a Route 53 hosted zone for the domain already exists.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  count = var.domain_name == "" ? 0 : 1
  name  = var.domain_name
}

resource "aws_acm_certificate" "site" {
  count                     = var.domain_name == "" ? 0 : 1
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name == "" ? {} : {
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.domain_name => dvo
  }
  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count                   = var.domain_name == "" ? 0 : 1
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
