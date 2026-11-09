#!/bin/bash
# ec2/publish-tunnel-url.sh — one-shot systemd unit: waits for the cloudflared
# quick-tunnel URL in the journal and publishes it to SSM so the local deploy
# script (and you) can pick it up without ever SSHing in.
set -u
ENVF=/opt/aws-inference/env-vars
[ -f "$ENVF" ] && . "$ENVF"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-aws-inference}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

if [ -n "$TUNNEL_TOKEN" ]; then
  URL="token-managed"
  echo "named-tunnel mode — publish placeholder"
else
  URL=""
  for i in $(seq 1 40); do
    URL=$(journalctl -u aws-inference-tunnel.service --no-pager -o cat | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -n1)
    [ -n "$URL" ] && break
    sleep 5
  done
fi

if [ -z "$URL" ]; then
  echo "no tunnel URL found after 200s — check: journalctl -u aws-inference-tunnel"
  journalctl -u aws-inference-tunnel.service --no-pager -o cat | tail -20 || true
  exit 1
fi

echo "$URL" > /opt/aws-inference/TUNNEL_URL
chmod 644 /opt/aws-inference/TUNNEL_URL
aws --region "$REGION" ssm put-parameter --name "/inf-gw/$STACK_NAME/tunnel-url" \
    --type String --value "$URL" --overwrite >/dev/null
echo "published $URL"
