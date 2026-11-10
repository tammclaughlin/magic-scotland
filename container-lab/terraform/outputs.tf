output "registry" {
  description = "Log docker in to this before pushing"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "app_repository_url" {
  value = aws_ecr_repository.repo["app"].repository_url
}

output "nginx_repository_url" {
  value = aws_ecr_repository.repo["nginx"].repository_url
}

output "cluster" {
  value = aws_ecs_cluster.lab.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.lab.name
}

output "running_image_tag" {
  value = var.image_tag == "" ? "(none: no tasks running)" : var.image_tag
}
