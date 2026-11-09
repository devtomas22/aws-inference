#!/usr/bin/env bash
# Teardown: deletes the CloudFormation stack and SSM params.
set -euo pipefail
export AWS_PAGER=""
PROFILE="${PROFILE:-sandbox}"
STACK="${STACK:-aws-inference}"
REGION="${REGION:-us-east-1}"

aws --profile "$PROFILE" --region "$REGION" cloudformation delete-stack --stack-name "$STACK"
echo "deleting stack (wait ~2 min)…"
aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$STACK" || true
aws --profile "$PROFILE" --region "$REGION" ssm delete-parameters --names \
  "/aws-inference/$STACK/api-key" "/aws-inference/$STACK/tunnel-url" >/dev/null 2>&1 || true
echo "stack + SSM params deleted. EC2 terminated, no lingering cost."
