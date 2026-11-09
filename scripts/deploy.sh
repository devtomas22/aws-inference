#!/usr/bin/env bash
# Plug-and-play deploy: CloudFormation -> EC2 -> node gateway -> cloudflared -> live tests.
# Prints a PUBLIC URL + API key at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PAGER=""

PROFILE="${PROFILE:-sandbox}"
STACK="${STACK:-aws-inference}"
REGION="${REGION:-$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)}"
REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
REPO_URL="${REPO_URL:-https://github.com/devtomas22/aws-inference.git}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
BASE="${BASE:-}"

echo "== [1/4] cloudformation deploy  stack=$STACK  profile=$PROFILE  region=$REGION  type=$INSTANCE_TYPE =="
aws --profile "$PROFILE" --region "$REGION" cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name "$STACK" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides InstanceType="$INSTANCE_TYPE" RepoUrl="$REPO_URL" TunnelToken="$TUNNEL_TOKEN"

STACK_JSON=$(aws --profile "$PROFILE" --region "$REGION" cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].{Outputs:Outputs,Status:StackStatus}' --output json)
echo "$STACK_JSON"
INSTANCE_ID=$(echo "$STACK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["Outputs"]; print([o["OutputValue"] for o in d if o["OutputKey"]=="InstanceId"][0])')
PUBLIC_IP=$(echo "$STACK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["Outputs"]; print([o["OutputValue"] for o in d if o["OutputKey"]=="PublicIP"][0])')

PREFIX="/aws-inference/$STACK"
if [ -z "$BASE" ]; then
  echo "== [2/4] waiting for EC2 bootstrap + quick tunnel (SSM $PREFIX/tunnel-url) =="
  URL=""
  for i in $(seq 1 66); do
    URL=$(aws --profile "$PROFILE" --region "$REGION" ssm get-parameter --name "$PREFIX/tunnel-url" \
          --query 'Parameter.Value' --output text 2>/dev/null || true)
    if [ -n "$URL" ] && [ "$URL" != "None" ]; then break; fi
    echo "  attempt $i/66: not published yet (cloud-init + node install can take a few minutes)…"
    sleep 10
  done
  [ -z "$URL" ] && { echo "tunnel URL never appeared. Debug: aws --profile $PROFILE ssm send-command --instance-ids $INSTANCE_ID --document-name AWS-RunShellScript --parameters commands='tail -50 /var/log/aws-inference-bootstrap.log'"; exit 1; }
  echo "  tunnel: $URL"
else
  URL="$BASE"
fi

echo "== [3/4] fetching API key from SSM =="
KEY=$(aws --profile "$PROFILE" --region "$REGION" ssm get-parameter --name "$PREFIX/api-key" \
      --with-decryption --query 'Parameter.Value' --output text)

if [[ "$URL" == https://* ]]; then BASE="$URL"; else BASE="${BASE:-http://$PUBLIC_IP}"; fi

echo "== [4/4] live curl tests =="
if [[ "$BASE" == https://* ]]; then
  bash scripts/live-test.sh "$BASE" "$KEY" || true
else
  echo "named-tunnel mode: no public HTTPS URL known to this script — set BASE=https://<your-tunnel-host> and rerun tests."
fi

echo
echo "================================================================"
echo " PUBLIC URL   : $BASE"
echo " API KEY      : $KEY"
echo " dashboard    : $BASE/            (basic auth user=anything, pass=\$KEY; or paste key in the page)"
echo " openai api   : POST $BASE/v1/chat/completions"
echo " instance     : $INSTANCE_ID (PublicIP $PUBLIC_IP, no inbound ports — SSM: aws ssm start-session --target $INSTANCE_ID)"
echo " on-box hermes: $BASE/v1 already wired as hermes custom provider in /root/.hermes/config.yaml"
echo " teardown     : PROFILE=$PROFILE STACK=$STACK bash scripts/teardown.sh"
echo "================================================================"
