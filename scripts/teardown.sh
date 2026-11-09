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
echo "stack + SSM params deleted. EC2 terminated, no lingering cost."
