output "instance_id" {
  value = aws_instance.web.id
}

output "public_ip" {
  value = aws_eip.web.public_ip
}

output "public_dns" {
  value = aws_eip.web.public_dns
}

output "ansible_ssm_bucket" {
  description = "Set as ansible_aws_ssm_bucket_name / GitHub variable ANSIBLE_SSM_BUCKET."
  value       = aws_s3_bucket.ansible_ssm.bucket
}

output "ami_id" {
  value = aws_instance.web.ami
}
