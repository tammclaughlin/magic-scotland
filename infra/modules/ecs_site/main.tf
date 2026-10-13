# The container path: an ECS service on Fargate, image from ECR.
#
# Two stages:
#   enable_alb = false (start here)  tasks get a public IP; you browse to
#                                    http://<task ip>:8000 (make ecs-url).
#                                    The IP changes on every deploy.
#   enable_alb = true  (final step)  an Application Load Balancer in front:
#                                    one stable address, health checks,
#                                    zero-downtime deploys. Tasks then only
#                                    accept traffic from the ALB.
#
# Terraform creates the service with an initial task definition. After that,
# deploys register new task definition revisions (new image tags), so
# Terraform ignores changes to the service's task_definition.

locals {
  container_name = "web"
  container_port = 8000
  use_https      = var.enable_alb && var.certificate_arn != ""
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "disabled" # costs extra; turn on to explore
  }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# IAM: execution role (ECS agent: pull image, write logs)
#      task role (the app itself: DynamoDB, SES, SSM)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "task_app" {
  role       = aws_iam_role.task.name
  policy_arn = var.app_policy_arn
}

# Lets you run `aws ecs execute-command` to get a shell in a running task.
resource "aws_iam_role_policy" "task_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# ---------------------------------------------------------------------------
# Task security group
#   without ALB: port 8000 from web_allowed_cidrs (you browse to the task)
#   with ALB:    port 8000 from the ALB only
# ---------------------------------------------------------------------------
resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Fargate tasks: port 8000 from the ALB, or from web_allowed_cidrs without one"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "task_direct" {
  for_each          = var.enable_alb ? toset([]) : toset(var.web_allowed_cidrs)
  security_group_id = aws_security_group.task.id
  description       = "Direct access while there is no ALB"
  ip_protocol       = "tcp"
  from_port         = local.container_port
  to_port           = local.container_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  count                        = var.enable_alb ? 1 : 0
  security_group_id            = aws_security_group.task.id
  description                  = "From the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.alb[0].id
}

resource "aws_vpc_security_group_egress_rule" "task_all" {
  security_group_id = aws_security_group.task.id
  description       = "ECR, SSM, DynamoDB, SES, CloudWatch"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# FINAL STEP: Application Load Balancer (only when enable_alb = true)
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  count       = var.enable_alb ? 1 : 0
  name        = "${var.name}-alb"
  description = "Public load balancer"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = var.enable_alb ? toset(var.web_allowed_cidrs) : toset([])
  security_group_id = aws_security_group.alb[0].id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = local.use_https ? toset(var.web_allowed_cidrs) : toset([])
  security_group_id = aws_security_group.alb[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  count                        = var.enable_alb ? 1 : 0
  security_group_id            = aws_security_group.alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.task.id
}

resource "aws_lb" "this" {
  count                      = var.enable_alb ? 1 : 0
  name                       = substr(var.name, 0, 32)
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb[0].id]
  subnets                    = var.subnet_ids
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  count                = var.enable_alb ? 1 : 0
  name                 = substr("${var.name}-app", 0, 32)
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip" # required for Fargate
  vpc_id               = var.vpc_id
  deregistration_delay = 15

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  count             = var.enable_alb ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.use_https ? "redirect" : "forward"
    target_group_arn = local.use_https ? null : aws_lb_target_group.app[0].arn

    dynamic "redirect" {
      for_each = local.use_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.use_https ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# ---------------------------------------------------------------------------
# Task definition + service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([{
    name      = local.container_name
    image     = "${var.ecr_repository_url}:${var.image_tag}"
    essential = true
    portMappings = [{
      containerPort = local.container_port
      protocol      = "tcp"
    }]
    environment = [
      { name = "SSM_PARAM_PREFIX", value = var.ssm_prefix },
      { name = "AWS_REGION", value = var.region },
      # Only trust X-Forwarded-For when the ALB is in front.
      { name = "PROXY_HOPS", value = var.enable_alb ? "1" : "0" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "web"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3)\" || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }
  }])
}

resource "aws_ecs_service" "app" {
  name                   = "web"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.app.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # no NAT gateway, so tasks need a public IP to reach ECR
  }

  dynamic "load_balancer" {
    for_each = var.enable_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.app[0].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition] # deploys own this
  }
}

# ---------------------------------------------------------------------------
# Optional DNS: www-<env>.<domain> -> ALB (needs a domain and the ALB)
# ---------------------------------------------------------------------------
resource "aws_route53_record" "www" {
  count   = var.enable_alb && var.zone_id != "" ? 1 : 0
  zone_id = var.zone_id
  name    = var.dns_name
  type    = "A"
  alias {
    name                   = aws_lb.this[0].dns_name
    zone_id                = aws_lb.this[0].zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# Alarms (ALB metrics, so only with the ALB)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count               = var.enable_alb ? 1 : 0
  alarm_name          = "${var.name}-alb-5xx"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this[0].arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = compact([var.alarm_topic_arn])
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_tasks" {
  count       = var.enable_alb ? 1 : 0
  alarm_name  = "${var.name}-no-healthy-tasks"
  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.this[0].arn_suffix
    TargetGroup  = aws_lb_target_group.app[0].arn_suffix
  }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = compact([var.alarm_topic_arn])
}
