#!/usr/bin/env bash
# Print the URL of an environment's ECS service.
#   With the ALB (final step):  http://<alb dns name>
#   Before the ALB:             http://<public IP of the running task>:8000
#                               (this IP changes on every deploy)
#   scripts/ecs-url.sh dev          -> URL
#   scripts/ecs-url.sh dev --ip     -> just the task IP
set -euo pipefail
ENV="${1:?usage: ecs-url.sh <dev|prod> [--ip]}"
NAME="magic-scotland-$ENV"

if [ "${2:-}" != "--ip" ]; then
  dns=$(aws elbv2 describe-load-balancers --names "$NAME" \
          --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)
  if [ -n "$dns" ] && [ "$dns" != "None" ]; then echo "http://$dns"; exit 0; fi
fi

task=$(aws ecs list-tasks --cluster "$NAME" --service-name web --desired-status RUNNING \
         --query 'taskArns[0]' --output text)
[ -n "$task" ] && [ "$task" != "None" ] || { echo "No running task in $NAME" >&2; exit 1; }
eni=$(aws ecs describe-tasks --cluster "$NAME" --tasks "$task" \
        --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text)
ip=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
       --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
if [ "${2:-}" = "--ip" ]; then echo "$ip"; else echo "http://$ip:8000"; fi
