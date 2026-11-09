#!/bin/bash -xe
# ec2/bootstrap.sh — runs ON the instance from user-data.
# Installs node, the gateway, cloudflared, hermes; wires systemd; publishes secrets to SSM.
exec > /var/log/aws-inference-bootstrap.log 2>&1

STACK_NAME="${STACK_NAME:-aws-inference}"
if [ -z "$AWS_DEFAULT_REGION" ]; then
  TOKEN=$(curl -sf -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
  REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
fi
REGION="${REGION:-us-east-1}"
REPO=/opt/aws-inference/repo
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

echo "== bootstrap stack=$STACK_NAME region=$REGION =="

# --- base packages (git/tar preinstalled on AL2023; xz + awscli guard)
dnf install -y xz tar git awscli || dnf install -y xz tar git

# --- node (official tarball, deterministic)
ARCH=$(uname -m); case "$ARCH" in x86_64) NARCH=x64;; aarch64) NARCH=arm64;; *) NARCH=x64;; esac
NODE_VER=22.14.0
if [ ! -x /opt/node/bin/node ]; then
  curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${NARCH}.tar.xz" -o /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /opt
  ln -sfn "/opt/node-v${NODE_VER}-linux-${NARCH}" /opt/node
  ln -sf /opt/node/bin/node /usr/local/bin/node
  ln -sf /opt/node/bin/npm  /usr/local/bin/npm
  ln -sf /opt/node/bin/npx  /usr/local/bin/npx
fi
export PATH=/opt/node/bin:$PATH

# --- gateway deps + config
cd "$REPO"
npm install --omit=dev --no-audit --no-fund

ENVF=/opt/aws-inference/env-vars
if [ ! -f /opt/aws-inference/repo/.env ]; then
  API_KEY="$(openssl rand -hex 16)"
  printf 'API_KEY=%s\nPORT=3000\nBEDROCK_REGION=%s\n' "$API_KEY" "$REGION" > "$REPO/.env"
  chmod 600 "$REPO/.env"
fi
API_KEY="$(grep -E '^API_KEY=' "$REPO/.env" | cut -d= -f2)"
DEFAULT_MODEL="$(node -e 'console.log(require("./models.json").default)')"

# --- publish secrets/URL to SSM Parameter Store (deploy script reads these)
# NOTE: parameter names under /aws/... are reserved on some accounts -> use /inf-gw/
aws --region "$REGION" ssm put-parameter --name "/inf-gw/$STACK_NAME/api-key" \
    --type SecureString --value "$API_KEY" --overwrite >/dev/null

cat > "$ENVF" <<EOF
STACK_NAME=$STACK_NAME
API_KEY=$API_KEY
DEFAULT_MODEL=$DEFAULT_MODEL
AWS_DEFAULT_REGION=$REGION
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF
chmod 600 "$ENVF"

# --- systemd units
if [ -n "$TUNNEL_TOKEN" ]; then
  TUNNEL_EXEC="tunnel run --no-autoupdate --token $TUNNEL_TOKEN"
else
  TUNNEL_EXEC="tunnel --no-autoupdate --url http://127.0.0.1:3000"
fi
cp "$REPO/ec2/aws-inference.service" /etc/systemd/system/
cp "$REPO/ec2/aws-inference-publish.service" /etc/systemd/system/
sed -e "s|@TUNNEL_EXEC@|$TUNNEL_EXEC|" \
    -e "s|@ENVF@|$ENVF|" \
    "$REPO/ec2/aws-inference-tunnel.service.template" > /etc/systemd/system/aws-inference-tunnel.service

# --- cloudflared
if [ ! -x /usr/local/bin/cloudflared ]; then
  CARCH=${NARCH/x64/amd64}
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CARCH}" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

# --- hermes agent (python-based installer; non-fatal if it fails)
if ! command -v hermes >/dev/null 2>&1; then
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive || \
    echo "WARN: hermes installer failed — the gateway itself is unaffected"
fi
HERMES_BIN="$(command -v hermes || true)"
[ -n "$HERMES_BIN" ] && ln -sf "$HERMES_BIN" /usr/local/bin/hermes

# --- configure hermes (root) to use the local Bedrock gateway
write_hermes_config() {  # $1 = home dir
  local hd="$1"; mkdir -p "$hd/.hermes"
  cat > "$hd/.hermes/config.yaml" <<EOF
model:
  provider: custom
  base_url: http://127.0.0.1:3000/v1
  api_key: "\${BEDROCK_GATEWAY_API_KEY}"
  default: "$DEFAULT_MODEL"
model_aliases:
  bedrock:
    model: "$DEFAULT_MODEL"
    provider: custom
    base_url: $( [ "$1" = /root ] && echo http://127.0.0.1:3000/v1 || echo REPLACED )
    key_env: BEDROCK_GATEWAY_API_KEY
EOF
  printf 'BEDROCK_GATEWAY_API_KEY=%s\n' "$API_KEY" > "$hd/.hermes/.env"
  chmod 600 "$hd/.hermes/.env"
}
write_hermes_config /root
# hermes alias fix-up for non-root (tunnel URL unknown at boot; on-box users should use localhost)
sed -i "s|base_url: REPLACED|base_url: http://127.0.0.1:3000/v1|" /root/.hermes/config.yaml
for U in ssm-user ec2-user; do
  [ -d "/home/$U" ] && write_hermes_config "/home/$U" && sed -i "s|base_url: REPLACED|base_url: http://127.0.0.1:3000/v1|" "/home/$U/.hermes/config.yaml" && chown -R "$U:$U" "/home/$U/.hermes" || true
done

# --- start services
systemctl daemon-reload
systemctl enable --now aws-inference.service
systemctl enable --now aws-inference-tunnel.service
systemctl enable --now aws-inference-publish.service

echo "== bootstrap done =="
