# aws-inference

OpenAI / Hermes-Agent-compatible API gateway for **AWS Bedrock**, one-command deployable:

    PROFILE=sandbox bash scripts/deploy.sh

The template is region-agnostic; the deployed region/profile defaults live in
`scripts/.env` (`REGION=us-east-1`, `PROFILE=sandbox`) — edit it or override on
the CLI (`REGION=eu-west-1 PROFILE=sandbox bash scripts/deploy.sh`).

End result: a **public HTTPS URL + password** you can point any OpenAI client, or a
Hermes Agent, at. Runs on a single EC2 instance with **zero inbound ports** — all
traffic arrives through a Cloudflare Tunnel.

```
you ──HTTPS──> trycloudflare.com tunnel ──> cloudflared (EC2, egress-only)
                                              └─> node gateway (:3000, auth wall)
                                                    └─ AWS Bedrock (Converse API)
                       dashboard /  <── basic auth / bearer key
```

## What gets deployed (CloudFormation: `cloudformation/template.yaml`)

- EC2 AL2023 instance (default `t3.micro`, deploy override `INSTANCE_TYPE=m5.large`
  in `scripts/.env`) + IAM role (bedrock invoke/list, SSM param publish, SSM access)
- Security group with **no ingress rules at all** (egress only) — created OUTSIDE
  CloudFormation by `deploy.sh` (plain EC2 API) and passed as the `SgId` parameter,
  because some backends flip-fail `SecurityGroup` template bodies
- **Two public URLs**: the gateway URL (API + status dashboard) and a second
  quick-tunnel serving the **Hermes Agent web panel** (`hermes dashboard`, port 9119 on
  the box) through an authenticated reverse proxy in `server.js` (also pipes the
  WebSocket the embedded TUI chat needs). Same password on both.
- user-data → `ec2/bootstrap.sh`, which installs:
  - **Node 22** (official tarball) + gateway deps (`npm install`)
  - **cloudflared** (quick tunnel by default; named tunnel if you pass `TunnelToken`)
  - **Hermes Agent** (`install.sh --non-interactive`) configured to use the gateway
    as a `custom` provider out of the box (`/root/.hermes/config.yaml`)
  - systemd units: `aws-inference` (gateway), `aws-inference-tunnel` (cloudflared),
    `aws-inference-publish` (publishes tunnel URL → SSM)
- The random API key + tunnel URL are written to SSM Parameter Store
  `/inf-gw/<stack>/{api-key,tunnel-url}` at boot (`/aws/...` prefixes are reserved
  on some accounts); `deploy.sh` fetches them
  and prints the URL + password. Nothing to type, nothing to SSH for.

## Endpoints

| Route | Auth | What |
|---|---|---|
| `POST /v1/chat/completions` | `Bearer <key>` or Basic | OpenAI-compatible chat (streaming SSE + tool calling, maps to Bedrock Converse) |
| `GET /v1/models` | key | live Bedrock model list incl. inference profiles |
| `GET /api/stats` | key | requests, tokens, per-model counts, recent calls |
| `GET /` | Basic | dashboard: status, stats, chat playground, copy-paste snippets |
| `GET /health` | none | liveness |

Auth wall: any `/v1`, `/api`, dashboard route requires the key. The key never
leaves the box except into SSM (SecureString) and the deploy console output.

Model names: any Bedrock model/inference-profile id passes through. Friendly aliases in
`models.json` (verified per account by a live probe on 2026-11-09): `haiku`, `sonnet`
(claude-sonnet-4.5), `gpt-oss`, `gpt-oss-20b`, `nova`, `nova-pro`, `nova-micro`, plus
aliases for opus/glm/kimi/deepseek that 403 until that account enables model access.
Default: `us.anthropic.claude-haiku-4-5-20251001-v1:0`. Unrecognised OpenAI-ish names
fall back to the default model.

## Plug-and-play

```bash
PROFILE=sandbox bash scripts/deploy.sh          # deploy + wait + live curl tests
# → prints PUBLIC URL and API KEY, runs 8 live curl checks

# use with hermes anywhere (or on the box: base_url http://127.0.0.1:3000/v1):
hermes config set model.provider custom
hermes config set model.base_url https://<tunnel>/v1
hermes config set model.api_key '${BEDROCK_GATEWAY_API_KEY}'   # + key in ~/.hermes/.env

PROFILE=sandbox bash scripts/teardown.sh        # delete everything
```

## Repo layout

    server.js                  gateway (express, streaming, tools, auth, dashboard api)
    lib/converse.js            OpenAI <-> Bedrock Converse mapping (pure functions)
    public/index.html          dashboard (vanilla JS, dark)
    cloudformation/template.yaml
    ec2/bootstrap.sh           on-instance installer (node, cloudflared, hermes, systemd)
    ec2/*.service, publish-tunnel-url.sh
    scripts/deploy.sh          CFN deploy → wait → fetch key/URL → live tests
    scripts/live-test.sh       curl suite (auth wall, chat, SSE, tools, models, dashboard)
    scripts/teardown.sh

## Notes & costs

- Quick tunnels (`*.trycloudflare.com`) are ephemeral: URL changes on reboot
  (the publish unit re-publishes it; `deploy.sh` re-reads SSM). For a stable
  hostname: create a named tunnel in Cloudflare Zero Trust and pass
  `TUNNEL_TOKEN=<token> PROFILE=sandbox bash scripts/deploy.sh`.
- t3.small ≈ $0.04/h + Bedrock tokens. Teardown stops all spend.
- Bedrock model access must be enabled for the account/region (default model is
  verified by the live test; a 403 there means "enable model access" in Bedrock).
- Local dev: `API_KEY=x PORT=3000 npm start`.
