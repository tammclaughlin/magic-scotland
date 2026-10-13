output "instance_id" {
  value = aws_instance.web.id
}

output "public_ip" {
  value = aws_eip.web.public_ip
}

output "public_dns" {
  value = aws_eip.web.public_dns
}

output "security_group_id" {
  value = aws_security_group.web.id
}

output "ami_id" {
  value = aws_instance.web.ami
}
