# One small Linux web server. Terraform creates the box; Ansible configures it
# over plain SSH.

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
#   22      from your IP(s) only. GitHub Actions adds a temporary rule for the
#           runner's IP during a deploy and removes it afterwards.
#   80/443  from web_allowed_cidrs
# ---------------------------------------------------------------------------
resource "aws_security_group" "web" {
  name        = "${var.name}-web-ec2"
  description = "Web server: SSH from admin IPs, HTTP/HTTPS from web_allowed_cidrs"
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
  for_each          = toset(var.web_allowed_cidrs)
  security_group_id = aws_security_group.web.id
  description       = "HTTP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = toset(var.web_allowed_cidrs)
  security_group_id = aws_security_group.web.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  description       = "Outbound: updates, SES, DynamoDB, SSM, ECR"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Instance role: CloudWatch agent, ECR pulls, app access, and SSM Session
# Manager as a break-glass way in if you lock yourself out of SSH.
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

resource "aws_iam_instance_profile" "web" {
  name = "${var.name}-web-ec2"
  role = aws_iam_role.web.name
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

# Optional DNS record (only with a domain)
resource "aws_route53_record" "web" {
  count   = var.zone_id == "" ? 0 : 1
  zone_id = var.zone_id
  name    = var.dns_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.web.public_ip]
}

# ---------------------------------------------------------------------------
# Alarm: recover the instance if the AWS host fails, and tell you
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
