#!/usr/bin/env bash
# Deploy an image tag to an environment's ECS service from your laptop.
#   AWS_PROFILE=claude-rw scripts/ecs-deploy.sh dev <tag>
# Same steps as the GitHub workflow: new task definition revision with the
# image swapped, update the service, wait until it is stable.
set -euo pipefail

ENV="${1:?usage: ecs-deploy.sh <dev|prod> <image tag>}"
TAG="${2:?usage: ecs-deploy.sh <dev|prod> <image tag>}"
REGION="${AWS_REGION:-eu-west-2}"
NAME="magic-scotland-$ENV"

command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)"; exit 1; }

account=$(aws sts get-caller-identity --query Account --output text)
image="$account.dkr.ecr.$REGION.amazonaws.com/$NAME:$TAG"

aws ecr describe-images --repository-name "$NAME" --image-ids imageTag="$TAG" >/dev/null \
  || { echo "Image $image not found - run make push-image (dev) or make promote (prod) first"; exit 1; }

echo "Registering new task definition for $NAME with $image"
new_td=$(aws ecs describe-task-definition --task-definition "$NAME" --query taskDefinition \
  | jq --arg img "$image" '
      .containerDefinitions |= map(if .name == "web" then .image = $img else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)')
arn=$(aws ecs register-task-definition --cli-input-json "$new_td" \
        --query taskDefinition.taskDefinitionArn --output text)

echo "Updating service $NAME/web -> $arn"
aws ecs update-service --cluster "$NAME" --service web --task-definition "$arn" >/dev/null

echo "Waiting for the service to become stable (a few minutes)..."
aws ecs wait services-stable --cluster "$NAME" --services web

url=$("$(dirname "$0")/ecs-url.sh" "$ENV")
echo "Deployed: $url"
curl -fsS "$url/healthz" && echo || echo "(health check from here failed - check web_allowed_cidrs)"
