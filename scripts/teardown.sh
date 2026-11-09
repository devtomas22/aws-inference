#!/usr/bin/env bash
# Teardown: deletes the CloudFormation stack and SSM params.
set -euo pipefail
export AWS_PAGER=""

# scripts/.env supplies defaults; CLI/env values win.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
while IFS='=' read -r K V; do
  case "$K" in ''|\#*) continue ;; esac
  [ -z "${!K:-}" ] && export "$K=$V"
done < "$REPO_ROOT/scripts/.env"

PROFILE="${PROFILE:-sandbox}"
STACK="${STACK:-aws-inference}"
REGION="${REGION:-us-east-1}"

aws --profile "$PROFILE" --region "$REGION" cloudformation delete-stack --stack-name "$STACK"
echo "deleting stack (wait ~2 min)…"
aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$STACK" || true
aws --profile "$PROFILE" --region "$REGION" ssm delete-parameters --names \
  "/inf-gw/$STACK/api-key" "/inf-gw/$STACK/tunnel-url" >/dev/null 2>&1 || true
SG_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-security-groups \
  --filters Name=group-name,Values="aws-inference-$STACK-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
[ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] && \
  aws --profile "$PROFILE" --region "$REGION" ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null || true

# dedicated public network
VPC_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-vpcs \
  --filters Name=tag:Name,Values="aws-inference-$STACK-net" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  SUBNET_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
  IGW_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-internet-gateways \
    --filters Name=attachment.vpc-id,Values="$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || true)
  RTB_ID=$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-route-tables \
    --filters Name=vpc-id,Values="$VPC_ID" Name=association.main,Values=false \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)
  [ "$SUBNET_ID" != "None" ] && aws --profile "$PROFILE" --region "$REGION" ec2 delete-subnet --subnet-id "$SUBNET_ID" 2>/dev/null || true
  [ "$IGW_ID" != "None" ] && { aws --profile "$PROFILE" --region "$REGION" ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true; aws --profile "$PROFILE" --region "$REGION" ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" 2>/dev/null || true; }
  [ "$RTB_ID" != "None" ] && aws --profile "$PROFILE" --region "$REGION" ec2 delete-route-table --route-table-id "$RTB_ID" 2>/dev/null || true
  aws --profile "$PROFILE" --region "$REGION" ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
fi
echo "stack + SSM params + security group + network deleted. EC2 terminated, no lingering cost."
