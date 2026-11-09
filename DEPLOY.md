# DEPLOY.md — deploying aws-inference from the command line

Everything below runs on the machine that has AWS credentials for the sandbox
profile. The pipeline is fully self-contained: it builds the network, the security
group, the CloudFormation stack, boots the EC2, installs node + hermes, starts
cloudflared tunnels, publishes the URLs/keys to SSM, and runs the live test suite.

## Prerequisites

```bash
aws --version                                    # v2
aws --profile sandbox sts get-caller-identity    # works, no region needed for this
```

Defaults come from `scripts/.env` (committed): `REGION=us-east-1`,
`PROFILE=sandbox`, `STACK=aws-inference`, `INSTANCE_TYPE=m5.large`.
Any of them can be overridden on the command line.

## Deploy (one command)

```bash
git clone https://github.com/devtomas22/aws-inference.git
cd aws-inference
PROFILE=sandbox bash scripts/deploy.sh
```

Typical duration: ~8–12 min (stack create → cloud-init → node install →
cloudflared → hermes install). The script prints, at the end:

```
================================================================
 PUBLIC URL   : https://<random>.trycloudflare.com
 HERMES DASH  : https://<random>.trycloudflare.com   (Hermes Agent web panel, same key)
 API KEY      : <32-hex>
 ...
================================================================
```

Both URLs share the same password. Basic-auth username is ignored.

## Use it immediately

```bash
URL=https://<random>.trycloudflare.com
KEY=<32-hex-from-deploy>

# OpenAI-compatible chat (streaming SSE + tool calling work)
curl -s $URL/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "content-type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}'

# Model list (basic auth also works)
curl -s $URL/v1/models -u web:$KEY

# Dashboards (browser): any username + $KEY
echo "$URL/"         # gateway status dashboard + chat playground
# hermes panel URL printed as HERMES DASH — the real Hermes Agent web panel
```

Point any hermes (or OpenAI client) at it:

```bash
hermes config set model.provider custom
hermes config set model.base_url $URL/v1
hermes config set model.api_key '${BEDROCK_GATEWAY_API_KEY}'   # key goes in ~/.hermes/.env
```

On the deployed box itself, hermes is pre-wired to `http://127.0.0.1:3000/v1`
(`/root/.hermes/config.yaml`) — just run `hermes`.

## Parameters (command-line wins over scripts/.env)

```bash
PROFILE=sandbox bash scripts/deploy.sh                 # what scripts/.env holds
INSTANCE_TYPE=t3.micro bash scripts/deploy.sh          # free-tier class
INSTANCE_TYPE=m5.large bash scripts/deploy.sh          # current default
REGION=us-west-2 PROFILE=sandbox bash scripts/deploy.sh
STACK=aws-inference2 bash scripts/deploy.sh            # parallel independent stack
```

## Stable public hostname (optional)

Quick tunnels are ephemeral (URL changes on every boot). For a fixed hostname,
create a tunnel in Cloudflare Zero Trust ("cloudflared" connector → copy the
token), then:

```bash
TUNNEL_TOKEN=<cloudflare-tunnel-token> PROFILE=sandbox bash scripts/deploy.sh
```

The box runs `cloudflared tunnel run --token …` instead; no URL publishing needed —
open the hostname you mapped in Cloudflare.

## Redeploys & code changes

```bash
cd ~/repo/aws-inference && git commit … && GIT_SSH_COMMAND="ssh -i ~/.ssh/ct104_gh -o IdentitiesOnly=yes" git push
PROFILE=sandbox bash scripts/deploy.sh
```

The deploy stamps the repo short-SHA into the stack. **If the pushed code changed,
the stack is torn down and recreated** (this backend applies some EC2 changes
in-place; recreation is what guarantees new bootstrap/server code lands).
If nothing changed, the deploy is a fast no-op.

The sandbox session can rotate credentials mid-day to a NEW AWS account
(`aws --profile sandbox sts get-caller-identity` shows a different account);
all old-account resources vanish with it. `deploy.sh` rebuilds everything on the
new account in one run — URLs/keys are per-session.

## Verify

```bash
bash scripts/live-test.sh <gateway-url> <key> <hermes-panel-url>   # last arg optional
# 11 checks: auth wall, basic auth, dashboards, chat, SSE, tool_calls, models, hermes panel
```

## Debug

```bash
aws --profile sandbox --region us-east-1 cloudformation describe-stack-events \
  --stack-name aws-inference --query 'StackEvents[0:8].[Timestamp,ResourceStatus,ResourceType,ResourceStatusReason]' --output table
aws --profile sandbox --region us-east-1 ec2 get-console-output --latest \
  --instance-id i-xxx --output text --query Output | tail -40    # boot log (user-data is teed here)
aws --profile sandbox --region us-east-1 ssm get-parameter \
  --name /inf-gw/aws-inference/tunnel-url --output text --query Parameter.Value   # live URL
aws --profile sandbox --region us-east-1 ssm get-parameter \
  --name /inf-gw/aws-inference/api-key --with-decryption --output text --query Parameter.Value
```

What lives where: the VPC/subnet/IGW, the security group and both published
parameters are managed by the scripts under the `aws-inference` name tags/prefix
`/inf-gw/<stack>/…` (parameter names starting with `/aws` are reserved on
restricted accounts).

## Teardown

```bash
PROFILE=sandbox bash scripts/teardown.sh
# deletes: CloudFormation stack (+instance), SSM params, security group, VPC/subnet/IGW
```
