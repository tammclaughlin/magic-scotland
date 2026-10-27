# Run everything from your laptop with your AWS profiles from ~/.aws/config.
#
#   make help                     list targets
#   make plan ENV=prod            pick the environment (default dev)
#   make apply RW=my-admin        override a profile name
#
# Read-only work (checks, plans, inventory) uses RO; anything that changes
# AWS uses RW.

.RECIPEPREFIX = >
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ENV     ?= dev
RO      ?= claude-ro
RW      ?= claude-rw
# bootstrap creates IAM and a budget, which claude-rw isn't allowed to do.
ADMIN   ?= tam-admin
REGION  ?= eu-west-2
PROJECT ?= magic-scotland
# Matches the Dockerfile base image (python:3.12-slim).
PYTHON  ?= python3.12
NAME    := $(PROJECT)-$(ENV)

TF_ENV  := infra/envs/$(ENV)
STATE_BUCKET ?= $(shell terraform -chdir=infra/bootstrap output -raw state_bucket 2>/dev/null)
GIT_SHA := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo local)

export AWS_REGION := $(REGION)
# Credentials left in the shell by a manual `eval $(aws configure export-credentials ...)`
# would beat AWS_PROFILE; drop them so each target uses exactly the profile it names.
unexport AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION

# Terraform (Go SDK) and Ansible (boto3) can't use the login_session that
# `aws login` writes, so let the AWS CLI resolve the profile (login -> assume
# role) and pass plain temporary credentials in the environment instead.
#   > $(call as,$(RO)) terraform ...
as = creds=$$(aws configure export-credentials --profile $(1) --format env) && eval "$$creds" &&

.PHONY: help
help: ## Show this help
> @grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
> @echo; echo "  ENV=$(ENV)  RO=$(RO)  RW=$(RW)  REGION=$(REGION)"

check-env:
> @[[ "$(ENV)" == dev || "$(ENV)" == prod ]] || { echo "ENV must be dev or prod"; exit 1; }

# ---------------------------------------------------------------------------
# App (local)
# ---------------------------------------------------------------------------
.PHONY: venv test run docker-run
venv: ## Create app/.venv with dev requirements
> cd app && $(PYTHON) -m venv .venv && .venv/bin/pip install -q -r requirements-dev.txt

test: ## Lint and test the app
> cd app && .venv/bin/black --check . && .venv/bin/flake8 . && .venv/bin/pytest -q

run: ## Run the app locally on http://127.0.0.1:5000
> cd app && .venv/bin/flask --app wsgi run --debug

docker-run: ## Build and run the container on http://localhost:8000
> cd app && docker compose up --build

# ---------------------------------------------------------------------------
# One-off setup
# ---------------------------------------------------------------------------
.PHONY: keys preflight bootstrap
keys: ## Create the admin and CI SSH keys if missing
> @for k in magic-scotland magic-scotland-ci; do \
>   if [ -f ~/.ssh/$$k ]; then echo "~/.ssh/$$k exists"; \
>   else ssh-keygen -t ed25519 -N "" -C "$$k" -f ~/.ssh/$$k; fi; done

preflight: ## Read-only check of the AWS account for clashes and quotas (RO)
> AWS_PROFILE=$(RO) STATE_BUCKET="$(STATE_BUCKET)" scripts/preflight.sh

bootstrap: ## Create state bucket, OIDC role, SES identity, budget (ADMIN, once)
> cd infra/bootstrap && $(call as,$(ADMIN)) terraform init -input=false && terraform apply
> @echo; echo "Next: GitHub variables AWS_ROLE_ARN and TF_STATE_BUCKET from these outputs:"
> terraform -chdir=infra/bootstrap output

# ---------------------------------------------------------------------------
# Terraform per environment
# ---------------------------------------------------------------------------
.PHONY: init plan apply destroy outputs fmt
init: check-env ## terraform init for ENV (RO)
> @[ -n "$(STATE_BUCKET)" ] || { echo "No state bucket: run make bootstrap first, or pass STATE_BUCKET=..."; exit 1; }
> $(call as,$(RO)) terraform -chdir=$(TF_ENV) init -input=false -reconfigure -backend-config="bucket=$(STATE_BUCKET)"

plan: check-env ## terraform plan for ENV (RO, no state lock)
> $(call as,$(RO)) terraform -chdir=$(TF_ENV) plan -lock=false

apply: check-env ## terraform apply for ENV (RW)
> $(call as,$(RW)) terraform -chdir=$(TF_ENV) apply

destroy: check-env ## terraform destroy for ENV (RW) - stops the charges
> $(call as,$(RW)) terraform -chdir=$(TF_ENV) destroy

outputs: check-env ## Show ENV outputs (RO)
> $(call as,$(RO)) terraform -chdir=$(TF_ENV) output

fmt: ## terraform fmt everything
> terraform fmt -recursive infra

# ---------------------------------------------------------------------------
# EC2 path (Ansible over SSH; AWS is only used to find the server, so RO)
# ---------------------------------------------------------------------------
.PHONY: ansible-deps inventory deploy-ec2-check deploy-ec2 deploy-ec2-docker ssh
ansible-deps: ## Install Ansible collections
> cd ansible && ansible-galaxy collection install -r requirements.yml

inventory: check-env ## Show the servers Ansible finds for ENV (RO)
> cd ansible && $(call as,$(RO)) ansible-inventory -i inventory/$(ENV) --graph

deploy-ec2-check: check-env ## Dry run of the playbook for ENV (RO)
> cd ansible && $(call as,$(RO)) ansible-playbook -i inventory/$(ENV) site.yml --check --diff

deploy-ec2: check-env ## Configure the EC2 server and deploy the app for ENV (RO)
> cd ansible && $(call as,$(RO)) ansible-playbook -i inventory/$(ENV) site.yml

deploy-ec2-docker: check-env ## Run the ECR image on the EC2 server instead (RO)
> cd ansible && $(call as,$(RO)) ansible-playbook -i inventory/$(ENV) site.yml -e app_mode=docker

ssh: check-env ## SSH to the ENV server (ADMIN_USER=..., default your login name)
> ip=$$(AWS_PROFILE=$(RO) aws ec2 describe-instances --output text \
>   --filters Name=tag:Project,Values=$(PROJECT) Name=tag:Env,Values=$(ENV) Name=tag:Role,Values=web Name=instance-state-name,Values=running \
>   --query 'Reservations[0].Instances[0].PublicIpAddress'); \
> ssh -i ~/.ssh/magic-scotland $${ADMIN_USER:-$$USER}@$$ip

# ---------------------------------------------------------------------------
# Container path (ECR + ECS Fargate)
# ---------------------------------------------------------------------------
.PHONY: push-image promote deploy-ecs ecs-url
push-image: check-env ## Build the ARM image and push it to ENV's ECR, tagged GIT_SHA + latest (RW)
> acct=$$(AWS_PROFILE=$(RW) aws sts get-caller-identity --query Account --output text); \
> reg=$$acct.dkr.ecr.$(REGION).amazonaws.com; \
> AWS_PROFILE=$(RW) aws ecr get-login-password | docker login -u AWS --password-stdin $$reg; \
> docker buildx build --platform linux/arm64 --push \
>   -t $$reg/$(NAME):$(GIT_SHA) -t $$reg/$(NAME):latest app

promote: ## Copy image TAG (default GIT_SHA) from dev to prod ECR (RW)
> acct=$$(AWS_PROFILE=$(RW) aws sts get-caller-identity --query Account --output text); \
> reg=$$acct.dkr.ecr.$(REGION).amazonaws.com; tag=$${TAG:-$(GIT_SHA)}; \
> AWS_PROFILE=$(RW) aws ecr get-login-password | docker login -u AWS --password-stdin $$reg; \
> docker buildx imagetools create -t $$reg/$(PROJECT)-prod:$$tag -t $$reg/$(PROJECT)-prod:latest $$reg/$(PROJECT)-dev:$$tag

deploy-ecs: check-env ## Point ENV's ECS service at image TAG (default GIT_SHA) and wait (RW)
> AWS_PROFILE=$(RW) scripts/ecs-deploy.sh $(ENV) $${TAG:-$(GIT_SHA)}

ecs-url: check-env ## Show where the ENV containers are reachable (ALB, or task IP:8000 before the ALB) (RO)
> AWS_PROFILE=$(RO) scripts/ecs-url.sh $(ENV)
