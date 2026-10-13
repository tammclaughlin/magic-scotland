output "state_bucket" {
  description = "Put this in infra/envs/dev/backend.tf."
  value       = aws_s3_bucket.state.bucket
}

output "github_actions_role_arn" {
  description = "Save as the GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
