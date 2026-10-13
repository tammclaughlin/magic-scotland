output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.app.arn
}

output "contact_table_name" {
  value = aws_dynamodb_table.contact.name
}

output "app_policy_arn" {
  value = aws_iam_policy.app.arn
}

output "ssm_prefix" {
  value = local.ssm_prefix
}

output "zone_id" {
  value = var.domain_name == "" ? "" : data.aws_route53_zone.this[0].zone_id
}

output "certificate_arn" {
  value = var.domain_name == "" ? "" : aws_acm_certificate_validation.site[0].certificate_arn
}
