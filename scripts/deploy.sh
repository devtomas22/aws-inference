#!/usr/bin/env bash
# Plug-and-play deploy: CloudFormation -> EC2 -> node gateway -> cloudflared -> live tests.
# Prints a PUBLIC URL + API key at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_PAGER=""

# scripts/.env supplies defaults; CLI/env values win.
REPO_ROOT="$(pwd)"
while IFS='=' read -r K V; do
  case "$K" in ''|\#*) continue ;; esac
  [ -z "${!K:-}" ] && export "$K=$V"
done < "$REPO_ROOT/scripts/.env"

PROFILE="${PROFILE:-sandbox}"
STACK="${STACK:-aws-inference}"
REGION="${REGION:-$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)}"
REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
REPO_URL="${REPO_URL:-https://github.com/devtomas22/aws-inference.git}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
BASE="${BASE:-}"

echo "== [1/4] cloudformation deploy  stack=$STACK  profile=$PROFILE  region=$REGION  type=$INSTANCE_TYPE =="

# Some restricted/lab CFN backends reject template type-list scans intermittently
# (minutes-scale windows). Cheap probe: wait for a green validate-template, then create.
for i in $(seq 1 15); do
  if aws --profile "$PROFILE" --region "$REGION" cloudformation validate-template \
       --template-body file://cloudformation/template.yaml >/dev/null 2>&1; then
    echo "  validate-template green (attempt $i)"; break
  fi
  echo "  validate-template rejected (attempt $i/15) — waiting 20s for the validation window…"
  sleep 20
done

DEPLOY_OK=0
for ATTEMPT in 1 2 3 4 5 6; do
  if aws --profile "$PROFILE" --region "$REGION" cloudformation deploy \
    --template-file cloudformation/template.yaml \
    --stack-name "$STACK" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides InstanceType="$INSTANCE_TYPE" RepoUrl="$REPO_URL" TunnelToken="$TUNNEL_TOKEN"; then
    DEPLOY_OK=1; break
  fi
  echo "  deploy attempt $ATTEMPT/6 failed — waiting 30s before retry…"
  # a rejected change set can leave a rollback-in-progress stack; wait for it to settle
  aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-create-complete --stack-name "$STACK" 2>/dev/null || \
  aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-rollback-complete --stack-name "$STACK" 2>/dev/null || true
  aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$STACK" 2>/dev/null || true
  sleep 30
done
[ "$DEPLOY_OK" = 1 ] || {
  # Fallback: direct create-stack bypasses the change-set path some backends reject.
  echo "  change-set path kept failing — trying direct create-stack fallback…"
  ST=$(aws --profile "$PROFILE" --region "$REGION" cloudformation describe-stacks --stack-name "$STACK" \
       --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo none)
  echo "  existing stack status: $ST"
  if ! grep -qE '_IN_PROGRESS|CREATE_COMPLETE|UPDATE_COMPLETE' <<<"$ST"; then
    aws --profile "$PROFILE" --region "$REGION" cloudformation delete-stack --stack-name "$STACK" 2>/dev/null || true
    aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-delete-complete --stack-name "$STACK" 2>/dev/null || true
    aws --profile "$PROFILE" --region "$REGION" cloudformation create-stack \
      --stack-name "$STACK" --capabilities CAPABILITY_IAM \
      --template-body file://cloudformation/template.yaml \
      --parameters ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
                   ParameterKey=RepoUrl,ParameterValue="$REPO_URL" \
                   ParameterKey=TunnelToken,ParameterValue="$TUNNEL_TOKEN" \
                   ParameterKey=KeyName,ParameterValue="" >/dev/null
    aws --profile "$PROFILE" --region "$REGION" cloudformation wait stack-create-complete --stack-name "$STACK" \
      && DEPLOY_OK=1
  fi
}
[ "$DEPLOY_OK" = 1 ] || { echo "create failed after retries — check: aws cloudformation describe-stack-events --stack-name $STACK | tail -20"; exit 1; }

STACK_JSON=$(aws --profile "$PROFILE" --region "$REGION" cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].{Outputs:Outputs,Status:StackStatus}' --output json)
echo "$STACK_JSON"
INSTANCE_ID=$(echo "$STACK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["Outputs"]; print([o["OutputValue"] for o in d if o["OutputKey"]=="InstanceId"][0])')
PUBLIC_IP=$(echo "$STACK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["Outputs"]; print([o["OutputValue"] for o in d if o["OutputKey"]=="PublicIP"][0])')

PREFIX="/inf-gw/$STACK"
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
