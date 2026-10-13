output "ecr_repository_url" {
  description = "GitHub variable ECR_REPOSITORY_URL"
  value       = module.shared.ecr_repository_url
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

output "ansible_ssm_bucket" {
  description = "GitHub variable ANSIBLE_SSM_BUCKET"
  value       = var.enable_ec2 ? module.ec2_site[0].ansible_ssm_bucket : null
}

output "site_url_ec2" {
  value = var.enable_ec2 ? "http://${module.ec2_site[0].public_ip}" : null
}

output "alb_url" {
  description = "GitHub variable ECS_SITE_URL"
  value       = var.enable_ecs ? "http://${module.ecs_site[0].alb_dns_name}" : null
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
