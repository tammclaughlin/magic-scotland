# One small Linux web server. Terraform creates the box; Ansible configures it.

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.architecture}-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# SSH key: only the PUBLIC key goes to AWS. The private key stays on your
# laptop and never enters Terraform state or Git.
# ---------------------------------------------------------------------------
resource "aws_key_pair" "admin" {
  key_name   = "${var.name}-admin"
  public_key = var.ssh_public_key
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "web" {
  name        = "${var.name}-web-ec2"
  description = "Web server: SSH from admin IPs, HTTP/HTTPS from anywhere"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-web-ec2" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.ssh_allowed_cidrs)
  security_group_id = aws_security_group.web.id
  description       = "SSH from admin"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP (redirected to HTTPS by Nginx when TLS is on)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound: updates, SES, DynamoDB, SSM, ECR"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Instance role: SSM Session Manager, CloudWatch agent, ECR pulls, app access
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web" {
  name               = "${var.name}-web-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.web.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.web.name
  policy_arn = var.app_policy_arn
}

# Ansible over SSM copies files through this bucket.
resource "aws_iam_role_policy" "ssm_transfer" {
  name = "ansible-ssm-transfer"
  role = aws_iam_role.web.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.ansible_ssm.arn, "${aws_s3_bucket.ansible_ssm.arn}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "web" {
  name = "${var.name}-web-ec2"
  role = aws_iam_role.web.name
}

# ---------------------------------------------------------------------------
# Bucket used by Ansible's aws_ssm connection plugin to move files
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "ansible_ssm" {
  bucket_prefix = "${var.name}-ansible-ssm-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ansible_ssm" {
  bucket                  = aws_s3_bucket.ansible_ssm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    id     = "expire-transfers"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.web.name

  credit_specification {
    cpu_credits = "standard" # no surprise charges from "unlimited" mode
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets containers on the host reach IMDS
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-web"
    Role = "web" # Ansible dynamic inventory selects on this tag
  }

  lifecycle {
    ignore_changes = [ami] # don't replace the server every time Ubuntu publishes a new AMI
  }
}

resource "aws_eip" "web" {
  domain   = "vpc"
  instance = aws_instance.web.id
  tags     = { Name = "${var.name}-web" }
}

# Optional DNS record: ec2.<domain> -> Elastic IP
resource "aws_route53_record" "web" {
  count   = var.zone_id == "" ? 0 : 1
  zone_id = var.zone_id
  name    = var.dns_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.web.public_ip]
}

# ---------------------------------------------------------------------------
# Alarm: recover the instance if the AWS host fails
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name}-web-status-check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.web.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = compact(["arn:aws:automate:${var.region}:ec2:recover", var.alarm_topic_arn])
}
