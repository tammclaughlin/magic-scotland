output "ecr_repository_url" {
  value = module.stack.ecr_repository_url
}

output "ssm_prefix" {
  value = module.stack.ssm_prefix
}

output "ec2_public_ip" {
  value = module.stack.ec2_public_ip
}

output "ec2_instance_id" {
  value = module.stack.ec2_instance_id
}

output "ec2_security_group_id" {
  value = module.stack.ec2_security_group_id
}

output "site_url_ec2" {
  value = module.stack.site_url_ec2
}

output "alb_url" {
  value = module.stack.alb_url
}

output "ecs_cluster" {
  value = module.stack.ecs_cluster
}

output "ecs_service" {
  value = module.stack.ecs_service
}

output "ecs_task_family" {
  value = module.stack.ecs_task_family
}
