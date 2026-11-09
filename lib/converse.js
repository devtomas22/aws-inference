// OpenAI <-> AWS Bedrock Converse payload mapping.
// Pure functions, no I/O — unit-testable.

const FINISH_MAP = {
  end_turn: 'stop',
  stop_sequence: 'stop',
  max_tokens: 'length',
  tool_use: 'tool_calls',
  content_filtered: 'content_filter',
  guardrail_intervened: 'content_filter'
};

function contentText(content) {
  if (content == null) return '';
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter((p) => p && p.type === 'text' && typeof p.text === 'string')
      .map((p) => p.text)
      .join('\n');
  }
  try { return JSON.stringify(content); } catch { return String(content); }
}

function imageBlock(url) {
  const m = /^data:(image\/(png|jpeg|jpg|gif|webp));base64,(.+)$/i.exec(url || '');
  if (!m) return null; // http(s) URLs are not supported by Converse (bytes required)
  const fmt = m[2].toLowerCase() === 'jpg' ? 'jpeg' : m[2].toLowerCase();
  return { image: { format: fmt, source: { bytes: Uint8Array.from(Buffer.from(m[3], 'base64')) } } };
}

function parseToolArgs(args) {
  if (args == null) return {};
  if (typeof args === 'string') {
    try { return JSON.parse(args || '{}'); } catch { return { _raw: args }; }
  }
  return args;
}

function parseToolResult(content) {
  if (content == null) return {};
  if (typeof content === 'string') {
    try { return JSON.parse(content); } catch { return { output: content }; }
  }
  if (Array.isArray(content)) {
    const s = content
      .filter((p) => p && p.type === 'text')
      .map((p) => p.text)
      .join('\n');
    return parseToolResult(s);
  }
  if (typeof content === 'object') return content;
  return { output: String(content) };
}

// Merge a block list into `out`, merging consecutive same-role messages
// (Bedrock Anthropic needs one message per role turn). ToolResult blocks are
// kept first inside a merged user message.
function appendMessage(out, role, blocks) {
  if (!blocks.length) return;
  const last = out[out.length - 1];
  if (last && last.role === role) {
    last.content.push(...blocks);
    last.content.sort((a, b) => (b.toolResult ? 1 : 0) - (a.toolResult ? 1 : 0));
    return;
  }
  out.push({ role, content: blocks });
}

/**
 * Convert OpenAI chat messages to Bedrock Converse shape.
 * Returns { system: [{text}]|undefined, messages: [{role, content:[...]}] }
 */
export function messagesToConverse(messages) {
  if (!Array.isArray(messages)) throw new Error('messages must be an array');
  const system = [];
  const out = [];

  for (const m of messages) {
    if (!m || typeof m !== 'object') continue;
    const role = m.role === 'developer' ? 'system' : m.role;

    if (role === 'system') {
      const t = contentText(m.content);
      if (t) system.push({ text: t });
      continue;
    }

    if (role === 'assistant') {
      const blocks = [];
      const t = contentText(m.content);
      if (t) blocks.push({ text: t });
      for (const tc of Array.isArray(m.tool_calls) ? m.tool_calls : []) {
        if (!tc?.function?.name) continue;
        blocks.push({
          toolUse: {
            toolUseId: tc.id || `call_${blocks.length}`,
            name: tc.function.name,
            input: parseToolArgs(tc.function.arguments)
          }
        });
      }
      appendMessage(out, 'assistant', blocks);
      continue;
    }

    if (role === 'tool' || role === 'function') {
      const block = {
        toolResult: {
          toolUseId: m.tool_call_id || 'unknown_tool_use_id',
          content: [{ json: parseToolResult(m.content) }],
          status: 'success'
        }
      };
      appendMessage(out, 'user', [block]);
      continue;
    }

    // user (default)
    const blocks = [];
    const t = contentText(m.content);
    if (t) blocks.push({ text: t });
    if (Array.isArray(m.content)) {
      for (const p of m.content) {
        if (p && p.type === 'image_url' && p.image_url && blocks.every((b) => !b.image)) {
          const ib = imageBlock(p.image_url.url);
          if (ib) blocks.push(ib);
        }
      }
    }
    appendMessage(out, 'user', blocks);
  }

  const cleaned = out.filter((msg) => msg.content.length > 0);
  return {
    system: system.length ? system : undefined,
    messages: cleaned.length ? cleaned : [{ role: 'user', content: [{ text: ' ' }] }]
  };
}

/** Convert OpenAI `tools` to Converse toolConfig. */
export function toolsToConverse(tools, toolChoice) {
  const specs = (Array.isArray(tools) ? tools : [])
    .filter((t) => t && (t.type === 'function' || t.function))
    .map((t) => ({
      toolSpec: {
        name: t.function.name,
        description: t.function.description || '',
        inputSchema: { json: t.function.parameters || { type: 'object', properties: {} } }
      }
    }));
  if (!specs.length) return undefined;
  const cfg = { tools: specs };
  if (toolChoice === 'auto') cfg.toolChoice = { auto: {} };
  else if (toolChoice === 'required' || toolChoice === 'any') cfg.toolChoice = { any: {} };
  else if (toolChoice && typeof toolChoice === 'object' && toolChoice.type === 'function') {
    cfg.toolChoice = { tool: { name: toolChoice.function.name } };
  }
  return cfg;
}

/**
 * Convert a Converse (non-streaming) response to OpenAI fields.
 */
export function converseToOpenAi(output) {
  const message = output?.output?.message || {};
  let content = '';
  const tool_calls = [];
  for (const block of Array.isArray(message.content) ? message.content : []) {
    if (block.text) content += (content ? '\n' : '') + block.text;
    if (block.toolUse) {
      tool_calls.push({
        id: block.toolUse.toolUseId,
        type: 'function',
        function: {
          name: block.toolUse.name,
          arguments: JSON.stringify(block.toolUse.input ?? {})
        }
      });
    }
  }
  const usage = output?.usage || {};
  const finish = FINISH_MAP[output?.stopReason] || 'stop';
  const messageOut = { role: 'assistant', content };
  if (tool_calls.length) messageOut.tool_calls = tool_calls;
  return {
    message: messageOut,
    finish_reason: finish,
    usage: {
      prompt_tokens: usage.inputTokens ?? 0,
      completion_tokens: usage.outputTokens ?? 0,
      total_tokens: usage.totalTokens ?? ((usage.inputTokens ?? 0) + (usage.outputTokens ?? 0))
    }
  };
}

export const finishReasonFromStopReason = (sr) => FINISH_MAP[sr] || 'stop';
