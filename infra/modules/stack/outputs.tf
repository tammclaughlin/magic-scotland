output "ecr_repository_url" {
  value = module.shared.ecr_repository_url
}

output "ssm_prefix" {
  value = module.shared.ssm_prefix
}

output "ec2_public_ip" {
  value = var.enable_ec2 ? module.ec2_site[0].public_ip : null
}

output "ec2_instance_id" {
  value = var.enable_ec2 ? module.ec2_site[0].instance_id : null
}

output "ec2_security_group_id" {
  value = var.enable_ec2 ? module.ec2_site[0].security_group_id : null
}

output "site_url_ec2" {
  value = var.enable_ec2 ? "http://${module.ec2_site[0].public_dns}" : null
}

output "alb_url" {
  description = "Only with enable_alb = true. Before that: make ecs-url ENV=<env>"
  value       = var.enable_ecs && var.enable_alb ? "http://${module.ecs_site[0].alb_dns_name}" : null
}

output "ecs_cluster" {
  value = var.enable_ecs ? module.ecs_site[0].cluster_name : null
}

output "ecs_service" {
  value = var.enable_ecs ? module.ecs_site[0].service_name : null
}

output "ecs_task_family" {
  value = var.enable_ecs ? module.ecs_site[0].task_family : null
}
