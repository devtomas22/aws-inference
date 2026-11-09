#!/bin/bash
# ec2/publish-tunnel-url.sh — one-shot systemd unit: waits for the cloudflared
# quick-tunnel URLs (gateway + hermes dashboard) in the journals and publishes them
# to SSM so the local deploy script picks them up without ever SSHing in.
set -u
ENVF=/opt/aws-inference/env-vars
[ -f "$ENVF" ] && . "$ENVF"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-aws-inference}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

grab() { # grab <unit> — latest trycloudflare URL from the unit's journal
  journalctl -u "$1" --no-pager -o cat | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n1
}

if [ -n "$TUNNEL_TOKEN" ]; then
  URL="token-managed"; HURL="token-managed"
  echo "named-tunnel mode — publish placeholders"
else
  URL=""; HURL=""
  for i in $(seq 1 40); do
    [ -z "$URL" ]  && URL=$(grab aws-inference-tunnel)
    [ -z "$HURL" ] && HURL=$(grab aws-inference-tunnel-hermes)
    [ -n "$URL" ] && [ -n "$HURL" ] && break
    sleep 5
  done
fi

if [ -z "$URL" ] || [ -z "$HURL" ]; then
  echo "missing tunnel URL (gateway='$URL' hermes='$HURL')"
  journalctl -u aws-inference-tunnel --no-pager -o cat | tail -8
  journalctl -u aws-inference-tunnel-hermes --no-pager -o cat | tail -8
  exit 1
fi

echo "$URL" > /opt/aws-inference/TUNNEL_URL
echo "$HURL" > /opt/aws-inference/HERMES_URL
chmod 644 /opt/aws-inference/TUNNEL_URL /opt/aws-inference/HERMES_URL
aws --region "$REGION" ssm put-parameter --name "/inf-gw/$STACK_NAME/tunnel-url" \
    --type String --value "$URL" --overwrite >/dev/null
aws --region "$REGION" ssm put-parameter --name "/inf-gw/$STACK_NAME/hermes-url" \
    --type String --value "$HURL" --overwrite >/dev/null
echo "published gateway=$URL hermes=$HURL"
