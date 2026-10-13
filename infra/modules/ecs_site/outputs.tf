output "alb_dns_name" {
  description = "Empty until enable_alb = true. Without the ALB, run make ecs-url."
  value       = var.enable_alb ? aws_lb.this[0].dns_name : ""
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "task_family" {
  value = aws_ecs_task_definition.app.family
}

output "container_name" {
  value = local.container_name
}
