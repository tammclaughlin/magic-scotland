# Account-level, one-off bootstrap. Run ONCE from your laptop:
#
#   make preflight            # read-only check of the account first
#   make bootstrap            # uses the tam-admin profile (needs IAM + budgets)
#
# Creates the things that exist once per account, shared by dev and prod:
#   - S3 bucket for Terraform state (both environments)
#   - GitHub OIDC identity provider (or reuses an existing one)
#   - IAM role that GitHub Actions assumes
#   - SES identity for the notification email address
#   - Account-wide monthly budget alert
#   - ReadOnlyAccess on the hand-made read-only role (claude-ro), for plans
#   - Stack-scoped IAM rights for the hand-made change role (claude-rw), for applies
#
# This stack keeps its state locally (terraform.tfstate in this folder,
# git-ignored). Back that file up somewhere safe.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Terraform state bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC
# An account can only have ONE provider for token.actions.githubusercontent.com.
# If `make preflight` finds one already, set create_github_oidc_provider = false
# and this stack reuses it.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = (var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
  : data.aws_iam_openid_connect_provider.github[0].arn)
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only this repository: main-branch runs, pull requests, and the
    # dev / prod GitHub Environments.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_owner}/${var.github_repo}:pull_request",
        "repo:${var.github_owner}/${var.github_repo}:environment:dev",
        "repo:${var.github_owner}/${var.github_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

# LEARNING SHORTCUT: AdministratorAccess lets Terraform create anything.
# The trust policy above limits WHO can assume it to your repo.
# CHANGE_ME_LATER: replace with a scoped policy once the project settles.
resource "aws_iam_role_policy_attachment" "github_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# The read-only role (made by hand, outside Terraform) only has ViewOnlyAccess,
# which can list things but not read the state bucket or the details Terraform
# refreshes. ReadOnlyAccess adds those reads. It still can't kms:Decrypt, so
# SecureString parameter values stay hidden.
resource "aws_iam_role_policy_attachment" "readonly" {
  count      = var.readonly_role_name == "" ? 0 : 1
  role       = var.readonly_role_name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The change role (also made by hand) can't touch IAM, but every stack apply
# creates the instance role, ECS task roles, the app policy and an instance
# profile. Allow that for magic-scotland-<env>-* names only: this leaves out
# the GitHub Actions role above (magic-scotland-github-actions, admin) and
# everything else in the account.
# Not airtight: a role it creates could still be given a broad inline policy.
# A permissions boundary on the stack's roles would close that ("Later" item).
locals {
  rw_prefixes = [for e in var.environments : "${var.project}-${e}-*"]
  account_id  = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "rw_iam" {
  statement {
    sid = "ProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
    ]
    resources = [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:role/${p}"]
  }

  statement {
    sid       = "AttachOnlyKnownPolicies"
    actions   = ["iam:AttachRolePolicy"]
    resources = [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:role/${p}"]
    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = concat(
        [
          "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
          "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
          "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
          "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
        ],
        [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:policy/${p}"],
      )
    }
  }

  statement {
    sid       = "PassProjectRolesToEc2AndEcs"
    actions   = ["iam:PassRole"]
    resources = [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:role/${p}"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid = "ProjectPolicies"
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:TagPolicy", "iam:UntagPolicy", "iam:ListEntitiesForPolicy",
    ]
    resources = [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:policy/${p}"]
  }

  statement {
    sid = "ProjectInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = [for p in local.rw_prefixes : "arn:aws:iam::${local.account_id}:instance-profile/${p}"]
  }

  # ECS and the ALB (final step) create their service-linked roles on first use.
  statement {
    sid       = "ServiceLinkedRolesForEcsAndElb"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "rw_iam" {
  count       = var.rw_role_name == "" ? 0 : 1
  name        = "${var.project}-rw-stack-iam"
  description = "Lets ${var.rw_role_name} manage the IAM that the dev/prod stacks create"
  policy      = data.aws_iam_policy_document.rw_iam.json
}

resource "aws_iam_role_policy_attachment" "rw_iam" {
  count      = var.rw_role_name == "" ? 0 : 1
  role       = var.rw_role_name
  policy_arn = aws_iam_policy.rw_iam[0].arn
}

# ---------------------------------------------------------------------------
# SES: verify the notification address once for the whole account.
# AWS emails a confirmation link to it - click it.
# ---------------------------------------------------------------------------
resource "aws_ses_email_identity" "notify" {
  count = var.create_ses_identity ? 1 : 0
  email = var.notify_email
}

# ---------------------------------------------------------------------------
# Account-wide budget (covers dev + prod and anything else in the account)
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
