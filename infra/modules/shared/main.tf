# Per-environment resources both deploy paths use: ECR, DynamoDB,
# SSM parameters, the IAM policy the app needs, and optional DNS + TLS.
# (SES identity and the budget are account-wide: see infra/bootstrap.)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  ssm_prefix = "/${var.project}/${var.env}"
}

# ---------------------------------------------------------------------------
# Container registry (one per environment; prod images are promoted from dev)
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
# Optional: DNS + ACM certificate (only when domain_name is set).
# You chose no domain, so none of this is created.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  count = var.domain_name == "" ? 0 : 1
  name  = var.domain_name
}

resource "aws_acm_certificate" "site" {
  count                     = var.domain_name == "" ? 0 : 1
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
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
