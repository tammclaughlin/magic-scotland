# Container lab: the magic-scotland site as two containers on ECS Fargate.
#
# The whole thing in one file, for reading. Compare with the EC2 path:
#
#   EC2 + Ansible                              Fargate + containers (this file)
#   aws_instance (a server you look after)     aws_ecs_task_definition + aws_ecs_service
#   Ansible roles install nginx, the app       Dockerfiles bake them into images
#   apt / pip on the server at deploy time     docker build on your laptop, push to ECR
#   systemd keeps nginx and gunicorn running   the ECS service keeps 1 task running
#   SSH in to look around                      aws ecs execute-command (make shell)
#   journalctl / /var/log                      CloudWatch Logs (make logs)
#   instance profile (IAM role)                task role (app) + execution role (ECS agent)
#
# It borrows, read-only, from the dev stack: the VPC and public subnets, the SSM
# parameters and the IAM policy the app needs (so the contact form works too).
# Nothing in the dev stack is changed. Names start with magic-scotland-dev-lab so
# the claude-rw profile is allowed to create the IAM roles.

locals {
  name = "magic-scotland-dev-lab"
  dev  = "magic-scotland-dev" # the existing dev stack we borrow from
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Borrowed from the dev stack (data sources only read)
# ---------------------------------------------------------------------------
data "aws_vpc" "dev" {
  tags = { Name = "${local.dev}-vpc" }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.dev.id]
  }
  tags = { Tier = "public" }
}

# The dev app's policy: DynamoDB put, SES send, read /magic-scotland/dev/* in SSM.
# Built from its known name rather than looked up: a lookup by name needs
# iam:ListPolicies, which claude-rw doesn't have.
locals {
  app_policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.dev}-app"
}

# ---------------------------------------------------------------------------
# 1. Registries: where the images go after `docker build` (like a private Docker Hub)
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "repo" {
  for_each             = toset(["app", "nginx"])
  name                 = "${local.name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # let `make down` delete repos that still hold images

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "repo" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# 2. Logs: container stdout/stderr ends up here (the journald of the container world)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lab" {
  name              = "/ecs/${local.name}"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# 3. IAM. Two roles, where EC2 has one instance profile:
#    execution role = ECS itself: pull the images from ECR, write logs
#    task role      = the code in the containers: SSM, DynamoDB, SES
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
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy_attachment" "task_app" {
  role       = aws_iam_role.task.name
  policy_arn = local.app_policy_arn
}

# For `make shell` (aws ecs execute-command): the SSM agent inside the task needs these.
resource "aws_iam_role_policy" "task_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# ---------------------------------------------------------------------------
# 4. Firewall: port 80 (nginx) in. Gunicorn's 8000 is never opened; it listens
#    on 127.0.0.1 inside the task. Same as ufw + Nginx on the EC2 server.
# ---------------------------------------------------------------------------
resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Container lab: HTTP to nginx"
  vpc_id      = data.aws_vpc.dev.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.task.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Image pulls from ECR, SSM, DynamoDB, SES, CloudWatch"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# 5. The task definition: "what to run". The container world's equivalent of the
#    server's systemd units plus their config. Every change makes a new revision.
# ---------------------------------------------------------------------------
locals {
  # Before the first deploy there are no images yet; point at :latest so the
  # definition is valid. With image_tag = "" the service runs 0 copies anyway.
  tag = var.image_tag == "" ? "latest" : var.image_tag

  log_options = {
    awslogs-group  = aws_cloudwatch_log_group.lab.name
    awslogs-region = var.region
  }
}

resource "aws_ecs_task_definition" "lab" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # the task gets its own network interface and IP
  cpu                      = 256      # 0.25 vCPU, shared by both containers
  memory                   = 512      # MiB
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # images are built with --platform linux/arm64
  }

  container_definitions = jsonencode([
    {
      # Gunicorn + Flask, built from ../app/Dockerfile (the ansible "app" role).
      name      = "web"
      image     = "${aws_ecr_repository.repo["app"].repository_url}:${local.tag}"
      essential = true # if it dies, the whole task is replaced
      environment = [
        { name = "BIND", value = "127.0.0.1:8000" },
        { name = "SSM_PARAM_PREFIX", value = "/magic-scotland/dev" },
        { name = "AWS_REGION", value = var.region },
        { name = "PROXY_HOPS", value = "1" }, # nginx in front
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { awslogs-stream-prefix = "web" })
      }
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3)\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    },
    {
      # nginx, built from ../nginx/Dockerfile (the ansible "nginx" role).
      name         = "nginx"
      image        = "${aws_ecr_repository.repo["nginx"].repository_url}:${local.tag}"
      essential    = true
      portMappings = [{ containerPort = 80, protocol = "tcp" }]
      # Start only once Gunicorn is healthy: systemd's After= / Requires=.
      dependsOn = [{ containerName = "web", condition = "HEALTHY" }]
      logConfiguration = {
        logDriver = "awslogs"
        options   = merge(local.log_options, { awslogs-stream-prefix = "nginx" })
      }
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    },
  ])
}

# ---------------------------------------------------------------------------
# 6. Cluster + service: "keep N copies of that task running". Changing image_tag
#    makes a new task definition revision; the service then starts a new task,
#    waits for it to be healthy and stops the old one (a rolling deploy).
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "lab" {
  name = local.name
}

resource "aws_ecs_service" "lab" {
  name                   = "web"
  cluster                = aws_ecs_cluster.lab.id
  task_definition        = aws_ecs_task_definition.lab.arn
  desired_count          = var.image_tag == "" ? 0 : 1
  launch_type            = "FARGATE"
  enable_execute_command = true
  wait_for_steady_state  = true # terraform apply returns once the new task is healthy

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a task that never gets healthy rolls back to the last good revision
  }

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # no NAT gateway: the public IP is how it reaches ECR, and how you reach it
  }
}
