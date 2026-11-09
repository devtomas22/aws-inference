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
echo "stack + SSM params + security group deleted. EC2 terminated, no lingering cost."
