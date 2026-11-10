#!/usr/bin/env node
// aws-inference: OpenAI-compatible API gateway for AWS Bedrock (Hermes Agent compatible).
// Auth: Bearer or Basic with the API key. Streaming SSE, tool calling, /v1/models.
import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BedrockRuntimeClient,
  ConverseCommand,
  ConverseStreamCommand
} from '@aws-sdk/client-bedrock-runtime';
import {
  messagesToConverse,
  toolsToConverse,
  converseToOpenAi,
  finishReasonFromStopReason
} from './lib/converse.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VERSION = '1.0.0';
const START = Date.now();

// ---------------------------------------------------------------- env / config
function loadEnvFile(p) {
  try {
    for (const line of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
      if (m && m[1].toUpperCase() !== 'API_KEY_OR_COMMENT' && process.env[m[1]] === undefined) {
        process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
      }
    }
  } catch { /* no .env — fine, rely on process env */ }
}
loadEnvFile(path.join(__dirname, '.env'));

if (!process.env.API_KEY) {
  process.env.API_KEY = crypto.randomBytes(16).toString('hex');
  console.warn('[warn] API_KEY missing — generated one for this run:',
    process.env.API_KEY, '(write it to .env for persistence)');
}

const CONFIG = {
  port: parseInt(process.env.PORT || '3000', 10),
  apiKey: process.env.API_KEY,
  region: process.env.BEDROCK_REGION || process.env.AWS_REGION || 'us-east-1',
  defaultModel: process.env.DEFAULT_MODEL || null,
  hermesDashPort: parseInt(process.env.HERMES_DASH_PORT || '9119', 10),
  hermesProxyPort: parseInt(process.env.HERMES_PROXY_PORT || '3001', 10)
};

const MODELS_META = readJson(path.join(__dirname, 'models.json')) || { default: 'anthropic.claude-haiku-4-5-20251001-v1:0', map: {}, suggested: [] };
if (!CONFIG.defaultModel) CONFIG.defaultModel = MODELS_META.default;

const RUNTIME = new BedrockRuntimeClient({ region: CONFIG.region });
// control-plane client, imported lazily so /v1/models can list models
const { BedrockClient, ListInferenceProfilesCommand, ListFoundationModelsCommand } =
  await import('@aws-sdk/client-bedrock');
const CONTROL = new BedrockClient({ region: CONFIG.region });

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; }
}

// ---------------------------------------------------------------- stats
const STATS = {
  totalRequests: 0,
  tokensIn: 0,
  tokensOut: 0,
  errors: 0,
  byModel: {},
  recent: [] // cap 40
};
function record(entry) {
  STATS.totalRequests += 1;
  if (entry.ok) {
    STATS.tokensIn += entry.usage?.prompt_tokens || 0;
    STATS.tokensOut += entry.usage?.completion_tokens || 0;
    STATS.byModel[entry.model] = (STATS.byModel[entry.model] || 0) + 1;
  } else {
    STATS.errors += 1;
  }
  STATS.recent.unshift({ ...entry, t: Date.now() });
  STATS.recent.length = Math.min(STATS.recent.length, 40);
}

function tunnelUrl() {
  for (const p of ['/opt/aws-inference/TUNNEL_URL', path.join(__dirname, 'TUNNEL_URL')]) {
    try {
      const v = fs.readFileSync(p, 'utf8').trim();
      if (v.startsWith('https://')) return v;
    } catch { /* try next */ }
  }
  return null;
}
function hermesUrl() {
  for (const p of ['/opt/aws-inference/HERMES_URL', path.join(__dirname, 'HERMES_URL')]) {
    try {
      const v = fs.readFileSync(p, 'utf8').trim();
      if (v.startsWith('https://')) return v;
    } catch { /* try next */ }
  }
  return null;
}

// ---------------------------------------------------------------- auth
const KEY_HASH = crypto.createHash('sha256').update(CONFIG.apiKey).digest();
// "transparent after the wall": the first successful key check mints an HttpOnly cookie;
// every later request AND browser WebSocket handshakes (which cannot send custom auth
// headers) are accepted with the cookie alone — nginx-basic-auth style.
const WALL_COOKIE = 'ai_wall';
const COOKIE_VAL = crypto.createHash('sha256').update(`ai-wall-v1:${CONFIG.apiKey}`).digest('hex').slice(0, 32);
function cookieAuthed(req) {
  const m = /(?:^|;\s*)ai_wall=([a-f0-9]{32})/.exec(req.headers.cookie || '');
  if (!m) return false;
  const h = crypto.createHash('sha256').update(m[1]).digest();
  return crypto.timingSafeEqual(h, crypto.createHash('sha256').update(COOKIE_VAL).digest());
}
function markAuthed(res) {
  // express res.cookie; when a raw proxy writeHead follows, mergeCookieHeader() preserves it
  res.cookie(WALL_COOKIE, COOKIE_VAL, { httpOnly: true, sameSite: 'lax', path: '/', maxAge: 7 * 24 * 3600 * 1000 });
}
function mergeCookieHeader(res, headers) {
  const mine = res.getHeader('set-cookie');
  if (!mine || !headers) return headers;
  headers['set-cookie'] = [].concat(headers['set-cookie'] || [], mine);
  return headers;
}
function keyOk(candidate) {
  if (!candidate) return false;
  const h = crypto.createHash('sha256').update(candidate).digest();
  return crypto.timingSafeEqual(h, KEY_HASH);
}
function extractKeyCandidates(req) {
  const h = req.headers.authorization || '';
  if (/^Bearer\s+/i.test(h)) return [h.replace(/^Bearer\s+/i, '').trim()];
  if (/^Basic\s+/i.test(h)) {
    try {
      const dec = Buffer.from(h.replace(/^Basic\s+/i, ''), 'base64').toString('utf8');
      const i = dec.indexOf(':');
      return [dec, i >= 0 ? dec.slice(i + 1) : '', i >= 0 ? dec.slice(0, i) : ''];
    } catch { return []; }
  }
  const xk = req.headers['x-api-key'];
  return xk ? [String(xk)] : [];
}
function requireAuth(req, res, next) {
  if (extractKeyCandidates(req).some(keyOk) || cookieAuthed(req)) {
    markAuthed(res);
    return next();
  }
  res.set('WWW-Authenticate', 'Basic realm="aws-inference"');
  return res.status(401).json({ error: { message: 'Missing or invalid API key', type: 'auth_error', code: 'invalid_api_key' } });
}

// ---------------------------------------------------------------- models listing
let modelCache = { at: 0, ids: null };
async function listBedrockModelIds() {
  if (modelCache.ids && Date.now() - modelCache.at < 5 * 60_000) return modelCache.ids;
  const ids = new Set();
  try {
    const r = await CONTROL.send(new ListInferenceProfilesCommand({ maxResults: 200 }));
    for (const p of r.inferenceProfileSummaries || []) {
      if (p.type === 'SYSTEM_DEFINED' || !p.type) ids.add(p.inferenceProfileId);
    }
  } catch (e) { /* fall through */ }
  if (ids.size < 3) {
    try {
      const r = await CONTROL.send(new ListFoundationModelsCommand({}));
      for (const m of r.modelSummaries || []) {
        if ((m.modelLifecycle?.status || 'ACTIVE') !== 'ACTIVE') continue;
        if (!(m.outputModalities || []).includes('TEXT')) continue;
        ids.add(m.modelId);
      }
    } catch { /* fall through */ }
  }
  if (ids.size) { modelCache = { at: Date.now(), ids: [...ids] }; return [...ids]; }
  throw new Error('bedrock listing unavailable');
}
function suggestDefault() {
  const prefs = ['claude-haiku', 'claude-sonnet', 'glm-4.7-flash', 'nova-lite', 'nova-micro', 'gpt-oss-120b', 'glm', 'nova'];
  for (const p of prefs) {
    const hit = (modelCache.ids || []).find((id) => id.includes(p));
    if (hit) return hit;
  }
  return (modelCache.ids || [])[0] || MODELS_META.default;
}

// Auto model selection: alias values 'auto' / 'auto:<csv of bedrock ids>' walk a
// preference list. Each candidate is probed with a 1-token Converse call at first
// use; blocked ids (AccessDenied / Validation / NotFound — i.e. not enabled for the
// account) are skipped and remembered process-wide, and the first reachable id
// becomes the sticky default. Lets 'sonnet-5 / newest sonnet / newest haiku' light
// up the moment an account enables them, falling back to sonnet-4.5 / haiku-4.5.
const AUTO_BAD = new Set();
const AUTO_OK = new Map(); // preference-list-key -> resolved bedrock id
const AUTO_BLOCKED = new Set(['AccessDeniedException', 'ResourceNotFoundException', 'NotFoundException', 'ValidationException', 'ModelNotReadyException']);
async function autoModel(list) {
  const key = list.join('|');
  if (AUTO_OK.has(key)) return AUTO_OK.get(key);
  let lastBad = null;
  for (const cand of list) {
    if (!cand || AUTO_BAD.has(cand)) continue;
    try {
      await RUNTIME.send(new ConverseCommand({
        modelId: cand,
        messages: [{ role: 'user', content: [{ text: 'ping' }] }],
        inferenceConfig: { maxTokens: 1 }
      }));
      AUTO_OK.set(key, cand);
      console.log(`[auto] preferred model resolved: ${cand}`);
      return cand;
    } catch (e) {
      console.warn(`[auto] candidate blocked: ${cand} (${e.name || 'Error'})`);
      if (AUTO_BLOCKED.has(e.name)) { AUTO_BAD.add(cand); lastBad = `${cand}: ${e.name}`; continue; }
      throw e; // unexpected (network, throttling…) — surface to the caller
    }
  }
  throw new Error(`no reachable model in preference list of ${list.length}; last blocked: ${lastBad || '-'}`);
}

function resolveModel(requested) {
  const map = MODELS_META.map || {};
  if (requested && map[requested]) {
    const spec = map[requested];
    if (spec === 'auto') return { auto: MODELS_META.preferred || [], echoed: requested };
    if (spec.startsWith('auto:')) return { auto: spec.slice(5).split(',').map((s) => s.trim()), echoed: requested };
    return { id: spec, echoed: requested };
  }
  const req = requested || 'default';
  if (req === 'default' && MODELS_META.default === 'auto') return { auto: MODELS_META.preferred || [], echoed: requested };
  if (req === 'auto') return { auto: MODELS_META.preferred || [CONFIG.defaultModel].filter(Boolean), echoed: requested };
  if (!requested) return { id: CONFIG.defaultModel || suggestDefault(), echoed: requested };
  return { id: requested, echoed: requested }; // Bedrock ids (incl. inference profiles) pass straight through
}

function defaultModelLabel() {
  const sticky = AUTO_OK.get((MODELS_META.preferred || []).join('|'));
  return sticky || (MODELS_META.preferred || [])[0] || CONFIG.defaultModel || 'auto';
}

// ---------------------------------------------------------------- app
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '4mb' }));
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'authorization, content-type, x-api-key');
  res.set('Access-Control-Max-Age', '86400');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

app.get('/health', (req, res) => {
  res.json({ ok: true, version: VERSION, uptime_s: Math.round((Date.now() - START) / 1000), region: CONFIG.region });
});

app.get('/', requireAuth, (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.get('/api/stats', requireAuth, (req, res) => {
  res.json({
    version: VERSION,
    uptime_s: Math.round((Date.now() - START) / 1000),
    default_model: defaultModelLabel(),
    region: CONFIG.region,
    tunnel_url: tunnelUrl(),
    hermes_url: hermesUrl(),
    ...STATS,
    node: process.version
  });
});

app.get('/v1/models', requireAuth, async (req, res) => {
  let ids;
  try { ids = await listBedrockModelIds(); }
  catch { ids = MODELS_META.suggested || []; }
  const data = ids.map((id) => ({ id, object: 'model', created: Math.floor(START / 1000), owned_by: 'bedrock' }));
  res.json({ object: 'list', data });
});

// ---------------------------------------------------------------- chat completions
function errorStatus(e) {
  const name = e?.name || '';
  if (name === 'AccessDeniedException') return { code: 403, type: 'permission_error' };
  if (name === 'ResourceNotFoundException' || name === 'NotFoundException') return { code: 404, type: 'invalid_request_error' };
  if (name === 'ThrottlingException' || name === 'TooManyRequestsException') return { code: 429, type: 'rate_limit_error' };
  if (name === 'ValidationException') return { code: 400, type: 'invalid_request_error' };
  if (name === 'ModelNotReadyException') return { code: 503, type: 'temporarily_unavailable' };
  if (name === 'ServiceUnavailableException') return { code: 503, type: 'temporarily_unavailable' };
  return { code: 500, type: 'api_error' };
}
function sendError(res, e, extra) {
  const { code, type } = errorStatus(e);
  const msg = extra ? `${extra}: ${e.message}` : e.message;
  console.error(`[chat] ${code} ${e.name || 'Error'} ${msg}`);
  res.status(code).json({ error: { message: msg, type, code: e.name || String(code) } });
}

function toConverseParams(body, modelId, msgs) {
  const conv = messagesToConverse(msgs);
  const params = {
    modelId,
    messages: conv.messages,
    system: conv.system,
    inferenceConfig: {}
  };
  const mt = body.max_completion_tokens ?? body.max_tokens;
  if (mt != null) params.inferenceConfig.maxTokens = Math.min(parseInt(mt, 10) || 4096, 100_000);
  else params.inferenceConfig.maxTokens = 4096;
  if (body.temperature != null) params.inferenceConfig.temperature = Math.max(0, Math.min(1, Number(body.temperature)));
  if (body.top_p != null) params.inferenceConfig.topP = Math.max(0, Math.min(1, Number(body.top_p)));
  if (Array.isArray(body.stop) && body.stop.length) params.inferenceConfig.stopSequences = body.stop.map(String).slice(0, 4);
  const tc = toolsToConverse(body.tools, body.tool_choice);
  if (tc) params.toolConfig = tc;
  return params;
}

app.post('/v1/chat/completions', requireAuth, async (req, res) => {
  const body = req.body || {};
  const msgs = body.messages;
  if (!Array.isArray(msgs) || !msgs.length) {
    return res.status(400).json({ error: { message: 'messages array required', type: 'invalid_request_error' } });
  }
  const resolved = resolveModel(body.model);
  const stream = !!body.stream;
  const started = Date.now();
  let modelId;
  if (resolved.auto) {
    if (!resolved.auto.length) {
      return res.status(503).json({ error: { message: 'no preference list configured (models.json "preferred")', type: 'api_error' } });
    }
    try { modelId = await autoModel(resolved.auto); }
    catch (e) {
      return res.status(503).json({ error: { message: `auto model selection failed: ${e.message}`, type: 'api_error', code: 'auto_unavailable' } });
    }
  } else {
    modelId = resolved.id;
  }
  const echoed = resolved.echoed ?? modelId;
  let params;
  try { params = toConverseParams(body, modelId, msgs); }
  catch (e) { return sendError(res, e, 'converting request'); }

  const cid = `chatcmpl-${crypto.randomUUID()}`;
  const created = Math.floor(Date.now() / 1000);
  const usageRec = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };

  const finishRecord = (ok, err) => {
    record({
      ok, model: modelId, ms: Date.now() - started, stream,
      usage: ok ? usageRec : null,
      err: err ? String(err.message || err).slice(0, 160) : null
    });
  };

  if (!stream) {
    try {
      const out = await RUNTIME.send(new ConverseCommand(params));
      const conv = converseToOpenAi(out);
      Object.assign(usageRec, conv.usage);
      finishRecord(true, null);
      const resp = {
        id: cid,
        object: 'chat.completion',
        created,
        model: echoed || modelId,
        choices: [{ index: 0, message: conv.message, finish_reason: conv.finish_reason }],
        usage: conv.usage
      };
      return res.json(resp);
    } catch (e) {
      finishRecord(false, e);
      return sendError(res, e, `Bedrock model ${modelId}`);
    }
  }

  // ---------------- streaming ----------------
  res.status(200);
  res.set('Content-Type', 'text/event-stream; charset=utf-8');
  res.set('Cache-Control', 'no-cache');
  res.set('Connection', 'keep-alive');
  res.set('X-Accel-Buffering', 'no');
  res.flushHeaders?.();

  let clientGone = false;
  // NOTE: req 'close' fires when the request body finishes (node http semantics),
  // NOT on client disconnect — it must NOT be used to detect client-gone.
  res.on('close', () => { clientGone = true; });

  const send = (obj) => {
    if (clientGone) return false;
    try { res.write(`data: ${JSON.stringify(obj)}\n\n`); return true; }
    catch { clientGone = true; return false; }
  };
  const chunk = (delta, finish) => send({
    id: cid, object: 'chat.completion.chunk', created, model: echoed || modelId,
    choices: [{ index: 0, delta, finish_reason: finish ?? null }]
  });

  // CRIS streaming on some paths returns headers but no event frames — watch
  // the stream and fall back to Converse if nothing arrives
  const ac = new AbortController();
  let gotAny = false;
  const watchdog = setTimeout(() => { if (!gotAny) { console.error('[chat-stream] watchdog: aborting stalled stream'); ac.abort(); } }, 20000);
  try {
    const streamResp = await RUNTIME.send(new ConverseStreamCommand(params), { abortSignal: ac.signal });
    chunk({ role: 'assistant', content: '' });
    let toolIdx = -1;
    let stopReason = 'end_turn';
    // ConverseStreamOutput exposes the event stream as `stream` (SDK >=3.7xx);
    // `eventStream`/`body` are legacy aliases that may be undefined
    const events = (streamResp && (streamResp.stream ?? streamResp.eventStream ?? streamResp.body)) ?? [];
    if (!events?.[Symbol.asyncIterator]) throw new Error('no event stream in ConverseStream response (keys: ' + Object.keys(streamResp || {}).join(',') + ')');
    for await (const ev of events) {
      gotAny = true;
      if (clientGone) break;
      if (ev.messageStart) { continue; }
      if (ev.contentBlockStart) {
        const tu = ev.contentBlockStart.start?.toolUse;
        if (tu) {
          toolIdx += 1;
          chunk({ tool_calls: [{ index: toolIdx, id: tu.toolUseId, type: 'function', function: { name: tu.name, arguments: '' } }] });
        }
        continue;
      }
      if (ev.contentBlockDelta) {
        const d = ev.contentBlockDelta.delta || {};
        if (d.text) chunk({ content: d.text });
        if (d.toolUse && d.toolUse.input && toolIdx >= 0) {
          chunk({ tool_calls: [{ index: toolIdx, function: { arguments: d.toolUse.input } }] });
        }
        continue;
      }
      if (ev.messageStop) {
        stopReason = ev.messageStop.stopReason || stopReason;
        continue;
      }
      if (ev.metadata?.usage) {
        usageRec.prompt_tokens = ev.metadata.usage.inputTokens ?? 0;
        usageRec.completion_tokens = ev.metadata.usage.outputTokens ?? 0;
        usageRec.total_tokens = ev.metadata.usage.totalTokens ?? (usageRec.prompt_tokens + usageRec.completion_tokens);
      }
    }
    clearTimeout(watchdog);
    if (!clientGone) {
      chunk({}, finishReasonFromStopReason(stopReason));
      if (body.stream_options?.include_usage) {
        send({ id: cid, object: 'chat.completion.chunk', created, model: echoed || modelId, choices: [], usage: usageRec });
      }
      res.write('data: [DONE]\n\n');
      res.end();
    }
    finishRecord(true, null);
  } catch (e) {
    clearTimeout(watchdog);
    // stalled ConverseStream (headers OK, zero event frames) → pseudo-stream via Converse
    if (!gotAny && (e.name === 'AbortError' || e.name === 'TimeoutError') && !clientGone) {
      console.error('[chat-stream] stalled ConverseStream (no event frames), falling back to Converse');
      try {
        const out = await RUNTIME.send(new ConverseCommand(params));
        const conv = converseToOpenAi(out);
        Object.assign(usageRec, conv.usage);
        const m = conv.message;
        if (m.tool_calls) chunk(m.tool_calls, conv.finish_reason);
        else chunk({ content: m.content }, conv.finish_reason);
        send({ id: cid, object: 'chat.completion.chunk', created, model: echoed || modelId, choices: [], usage: conv.usage });
        res.write('data: [DONE]\n\n');
        res.end();
        finishRecord(true, null);
      } catch (e2) {
        finishRecord(false, e2);
        try {
          res.write(`data: ${JSON.stringify({ error: { message: e2.message || String(e2), type: 'api_error', code: e2.name || 'stream_error' } })}\n\n`);
          res.end();
        } catch { /* client gone */ }
      }
      return;
    }
    if (!clientGone) {
      try {
        res.write(`data: ${JSON.stringify({ error: { message: e.message || String(e), type: 'api_error', code: e.name || 'stream_error' } })}\n\n`);
        res.end();
      } catch { /* client gone */ }
    }
    finishRecord(false, e);
    console.error('[chat-stream]', e.name || 'Error', e.message);
  }
});

app.use((req, res) => {
  res.status(404).json({ error: { message: `no route: ${req.method} ${req.path}`, type: 'invalid_request_error' } });
});

app.listen(CONFIG.port, () => {
  console.log(`aws-inference v${VERSION} listening on :${CONFIG.port} (region ${CONFIG.region}, default model ${CONFIG.defaultModel})`);
});

// ---------------------------------------------------------------- hermes dashboard proxy
// Hermes' own web panel (hermes dashboard) runs on 127.0.0.1:HERMES_DASH_PORT with its auth
// gate disengaged (loopback bind) — this proxy IS the auth wall, and it also pipes the
// WebSocket the embedded TUI chat needs. Exposed via its own quick tunnel (port 3001).
const proxyApp = express();
proxyApp.disable('x-powered-by');
proxyApp.use((req, res, next) => {
  if (!extractKeyCandidates(req).some(keyOk) && !cookieAuthed(req)) {
    res.set('WWW-Authenticate', 'Basic realm="hermes dashboard"');
    return res.status(401).send('hermes dashboard: unauthorized (any user, password = API key)');
  }
  markAuthed(res);
  next();
});
proxyApp.use((req, res) => {
  // Rewrite Host to the bound loopback host (hermes rejects foreign Host/Origin on the
  // WebSocket gate) and mark the client protocol; the browser-facing URL stays public.
  const headers = { ...req.headers, 'x-forwarded-proto': req.headers['x-forwarded-proto'] || 'https' };
  headers.host = `127.0.0.1:${CONFIG.hermesDashPort}`;
  const upstream = http.request(
    { host: '127.0.0.1', port: CONFIG.hermesDashPort, path: req.url, method: req.method, headers },
    (pr) => {
      res.writeHead(pr.statusCode || 502, mergeCookieHeader(res, pr.headers));
      pr.pipe(res);
    }
  );
  upstream.on('error', () => {
    if (res.headersSent) return res.end();
    res.status(502).json({ error: { message: 'hermes dashboard not reachable on this box', type: 'bad_gateway' } });
  });
  req.pipe(upstream);
});
const proxyServer = http.createServer((req, res) => proxyApp(req, res));
proxyServer.on('upgrade', (req, sock, head) => {
  if (!extractKeyCandidates(req).some(keyOk) && !cookieAuthed(req)) {
    sock.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    return;
  }
  const target = net.connect(CONFIG.hermesDashPort, '127.0.0.1', () => {
    // Host must be the bound loopback host and Origin must be absent, or hermes'
    // DNS-rebinding gate closes the socket (4403 / bare 403 before handshake).
    const raw = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i].toLowerCase();
      const value = req.rawHeaders[i + 1];
      if (name === 'origin') continue;                       // strip browser origin
      if (name === 'host') { raw.push(`Host: 127.0.0.1:${CONFIG.hermesDashPort}`); continue; }
      raw.push(`${req.rawHeaders[i]}: ${value}`);
    }
    target.write(raw.join('\r\n') + '\r\n\r\n');
    if (head?.length) target.write(head);
    sock.pipe(target);
    target.pipe(sock);
  });
  target.on('error', () => { try { sock.end('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch { /* gone */ } sock.destroy(); });
});
proxyServer.listen(CONFIG.hermesProxyPort, '127.0.0.1', () => {
  console.log(`hermes dashboard proxy on 127.0.0.1:${CONFIG.hermesProxyPort} -> 127.0.0.1:${CONFIG.hermesDashPort}`);
});
