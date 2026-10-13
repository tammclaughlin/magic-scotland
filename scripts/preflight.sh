#!/usr/bin/env bash
# Read-only check of an EXISTING AWS account before bootstrapping this project.
# Changes nothing. Run with your read-only profile:
#
#   make preflight                  (uses AWS_PROFILE=claude-ro)
#   AWS_PROFILE=claude-ro scripts/preflight.sh
#
# It reports:
#   - who you are and which account/region you're pointed at
#   - anything that would CLASH with what Terraform creates (OIDC provider,
#     SES identity, IAM role/policy names, ECR repos, SSM paths, buckets)
#   - quota headroom for the things this project adds (VPCs, Elastic IPs)
#   - what's already running and costing money in the region

set -uo pipefail

REGION="${AWS_REGION:-eu-west-2}"
PROJECT="${PROJECT:-magic-scotland}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-tam.mclaughlin@gmail.com}"
STATE_BUCKET="${STATE_BUCKET:-}"
ENVS=(dev prod)

aws_() { aws --region "$REGION" --output text "$@" 2>/dev/null; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }
info() { printf '  ....  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
WARNINGS=0

command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }

head_ "Identity"
ident=$(aws sts get-caller-identity --output text --query '[Account,Arn]' 2>&1) \
  || { echo "  Cannot call AWS (profile: ${AWS_PROFILE:-default}): $ident"; exit 1; }
info "Profile: ${AWS_PROFILE:-default}   Region: $REGION"
info "Account / caller: $ident"

# ---------------------------------------------------------------------------
head_ "Things that would clash with this project"

oidc=$(aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' | tr '\t' '\n' | grep token.actions.githubusercontent.com)
if [ -n "$oidc" ]; then
  warn "GitHub OIDC provider already exists: $oidc"
  info "      -> set create_github_oidc_provider = false in infra/bootstrap/terraform.tfvars"
else
  ok "No GitHub OIDC provider yet (bootstrap will create one)"
fi

ses=$(aws_ ses get-identity-verification-attributes --identities "$NOTIFY_EMAIL" \
        --query "VerificationAttributes.\"$NOTIFY_EMAIL\".VerificationStatus")
if [ -n "$ses" ] && [ "$ses" != "None" ]; then
  warn "SES identity $NOTIFY_EMAIL already exists (status: $ses)"
  info "      -> set create_ses_identity = false in infra/bootstrap/terraform.tfvars"
else
  ok "SES identity $NOTIFY_EMAIL not set up yet"
fi
sandbox=$(aws_ sesv2 get-account --query 'ProductionAccessEnabled')
info "SES production access: ${sandbox:-unknown} (False = sandbox: can only email verified addresses - fine here)"

role="$PROJECT-github-actions"
aws_ iam get-role --role-name "$role" >/dev/null && warn "IAM role $role already exists" || ok "IAM role $role is free"

budget=$(aws_ budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
           --query "Budgets[?BudgetName=='$PROJECT-monthly'].BudgetName")
[ -n "$budget" ] && warn "Budget $PROJECT-monthly already exists" || ok "Budget name $PROJECT-monthly is free"

if [ -n "$STATE_BUCKET" ]; then
  if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
    warn "Bucket $STATE_BUCKET already exists in your account"
  else
    code=$(aws s3api head-bucket --bucket "$STATE_BUCKET" 2>&1 | grep -oE '\(4[0-9]{2}\)|403|404' | head -1)
    case "$code" in
      *404*) ok "State bucket name $STATE_BUCKET is available" ;;
      *403*) warn "State bucket name $STATE_BUCKET is taken by another AWS account - pick another" ;;
      *)     info "Could not tell whether $STATE_BUCKET is free ($code)" ;;
    esac
  fi
else
  info "Set STATE_BUCKET=<name> to check your chosen state bucket name"
fi

for env in "${ENVS[@]}"; do
  name="$PROJECT-$env"
  aws_ ecr describe-repositories --repository-names "$name" >/dev/null \
    && warn "ECR repo $name already exists" || ok "ECR repo $name is free"
  aws_ iam get-role --role-name "$name-web-ec2" >/dev/null \
    && warn "IAM role $name-web-ec2 already exists" || ok "IAM role $name-web-ec2 is free"
  aws_ iam get-role --role-name "$name-ecs-task" >/dev/null \
    && warn "IAM role $name-ecs-task already exists" || ok "IAM role $name-ecs-task is free"
  n=$(aws_ ssm get-parameters-by-path --path "/$PROJECT/$env" --query 'length(Parameters)')
  [ "${n:-0}" != "0" ] && warn "SSM parameters already under /$PROJECT/$env ($n)" || ok "SSM path /$PROJECT/$env is free"
  aws_ dynamodb describe-table --table-name "$name-contact" >/dev/null \
    && warn "DynamoDB table $name-contact already exists" || ok "DynamoDB table $name-contact is free"
  aws_ ec2 describe-key-pairs --key-names "$name-admin" >/dev/null \
    && warn "EC2 key pair $name-admin already exists" || ok "EC2 key pair $name-admin is free"
done

# ---------------------------------------------------------------------------
head_ "Quota headroom in $REGION (this project adds per env: 1 VPC, up to 1 EIP)"

vpcs=$(aws_ ec2 describe-vpcs --query 'length(Vpcs)')
vpc_q=$(aws_ service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --query 'Quota.Value')
vpc_q=${vpc_q%.*}; vpc_q=${vpc_q:-5}
if [ $((vpcs + 2)) -gt "$vpc_q" ]; then warn "VPCs: $vpcs used of $vpc_q - not enough room for dev + prod"
else ok "VPCs: $vpcs used of $vpc_q"; fi

eips=$(aws_ ec2 describe-addresses --query 'length(Addresses)')
eip_q=$(aws_ service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value')
eip_q=${eip_q%.*}; eip_q=${eip_q:-5}
if [ $((eips + 2)) -gt "$eip_q" ]; then warn "Elastic IPs: $eips used of $eip_q - not enough room for dev + prod"
else ok "Elastic IPs: $eips used of $eip_q"; fi

overlap=$(aws_ ec2 describe-vpcs --query "Vpcs[?CidrBlock=='10.20.0.0/16' || CidrBlock=='10.30.0.0/16'].[VpcId,CidrBlock]")
[ -n "$overlap" ] && info "Existing VPC uses 10.20/16 or 10.30/16 (only matters if you peer them): $overlap"

# ---------------------------------------------------------------------------
head_ "Already running in $REGION (things that cost money)"

aws_ ec2 describe-instances --filters Name=instance-state-name,Values=running,stopped \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' \
  | sed 's/^/  EC2   /'
aws_ ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'NatGateways[].[NatGatewayId,VpcId]' | sed 's/^/  NAT   /'
aws_ elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type]' | sed 's/^/  LB    /'
aws_ ec2 describe-addresses --query 'Addresses[?AssociationId==null].[PublicIp]' | sed 's/^/  Unattached EIP (charged) /'
aws_ rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass]' | sed 's/^/  RDS   /'
aws_ eks list-clusters --query 'clusters[]' | tr '\t' '\n' | sed '/^$/d;s/^/  EKS   /'
aws_ ecs list-clusters --query 'clusterArns[]' | tr '\t' '\n' | sed '/^$/d;s/^/  ECS   /'
info "(empty sections above = nothing of that kind)"

start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d 2>/dev/null || date -u -v1d +%Y-%m-%d)
end=$(date -u -d tomorrow +%Y-%m-%d 2>/dev/null || date -u -v+1d +%Y-%m-%d)
mtd=$(aws ce get-cost-and-usage --region us-east-1 --time-period Start="$start",End="$end" \
        --granularity MONTHLY --metrics UnblendedCost \
        --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null)
[ -n "$mtd" ] && info "Account spend so far this month: \$$(printf '%.2f' "$mtd") (the \$20 budget covers the whole account)" \
             || info "Couldn't read Cost Explorer (needs ce:GetCostAndUsage)"

# ---------------------------------------------------------------------------
head_ "Result"
if [ "$WARNINGS" -eq 0 ]; then
  ok "No clashes found - safe to run: make bootstrap"
else
  warn "$WARNINGS item(s) to look at before: make bootstrap"
fi
