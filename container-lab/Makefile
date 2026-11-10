# Container lab: deploy the magic-scotland site to ECS Fargate as two containers
# (nginx + gunicorn). Separate from the main Makefile and the dev/prod stacks.
# Run from this directory: cd container-lab && make help
#
# Make prints each command before running it, so you see the raw docker/aws/terraform.

.RECIPEPREFIX = >
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

RO     ?= claude-ro
RW     ?= claude-rw
REGION ?= eu-west-2
NAME   := magic-scotland-dev-lab
TF     := terraform -chdir=terraform
# Image tag = commit; "-dirty" if app/ or nginx/ have uncommitted changes.
TAG    ?= $(shell git rev-parse --short=12 HEAD)$(shell git diff --quiet HEAD -- ../app nginx 2>/dev/null || echo -dirty)

export AWS_REGION := $(REGION)
unexport AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
# Terraform can't read the `aws login` session; hand it plain temporary credentials.
as = creds=$$(aws configure export-credentials --profile $(1) --format env) && eval "$$creds" &&

.PHONY: help run init plan infra push deploy url logs shell down
help: ## Show the targets, in the order you use them
> @grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
> @echo; echo "  TAG=$(TAG)  RO=$(RO)  RW=$(RW)"

run: ## 1. Build both images and run them locally: http://localhost:8080
> docker compose up --build

init: ## 2. terraform init (local state, no AWS changes)
> $(TF) init -input=false

plan: ## 3. Show what deploy would change for TAG (RO)
> $(call as,$(RO)) $(TF) plan -lock=false -var image_tag=$(TAG)

infra: ## 4. Create repos, roles, cluster, service with 0 tasks (RW). Later: stops the tasks
> $(call as,$(RW)) $(TF) apply -var image_tag=

push: ## 5. Build both images for ARM64 and push them to ECR as TAG (RW)
> reg=$$($(TF) output -raw registry); \
> aws ecr get-login-password --profile $(RW) | docker login -u AWS --password-stdin $$reg; \
> docker buildx build --platform linux/arm64 --push -t $$reg/$(NAME)-app:$(TAG)   ../app; \
> docker buildx build --platform linux/arm64 --push -t $$reg/$(NAME)-nginx:$(TAG) nginx

deploy: ## 6. Run TAG on Fargate: new task definition revision, rolling update, waits (RW)
> $(call as,$(RW)) $(TF) apply -var image_tag=$(TAG)
> @$(MAKE) --no-print-directory url

url: ## Show the running task's address (RO). It changes on every deploy
> task=$$(aws ecs list-tasks --profile $(RO) --cluster $(NAME) --service-name web --desired-status RUNNING --query 'taskArns[0]' --output text); \
> [ "$$task" != None ] || { echo "No running task (make deploy?)"; exit 1; }; \
> eni=$$(aws ecs describe-tasks --profile $(RO) --cluster $(NAME) --tasks $$task --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text); \
> ip=$$(aws ec2 describe-network-interfaces --profile $(RO) --network-interface-ids $$eni --query 'NetworkInterfaces[0].Association.PublicIp' --output text); \
> echo "http://$$ip"; curl -fsS -m 5 "http://$$ip/healthz" && echo || echo "(not answering yet)"

logs: ## Follow both containers' logs (RO)
> aws logs tail /ecs/$(NAME) --follow --profile $(RO)

shell: ## Shell in the web container (C=nginx for the other). Needs session-manager-plugin (RW)
> task=$$(aws ecs list-tasks --profile $(RW) --cluster $(NAME) --service-name web --query 'taskArns[0]' --output text); \
> aws ecs execute-command --profile $(RW) --cluster $(NAME) --task $$task --container $${C:-web} --interactive --command /bin/sh

down: ## Delete everything the lab created (RW). The dev stack isn't touched
> $(call as,$(RW)) $(TF) destroy -var image_tag=
