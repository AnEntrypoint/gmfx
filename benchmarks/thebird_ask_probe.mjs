import { spawn } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const USAGE = 'usage: node thebird_ask_probe.mjs <thebird checkout> [--runs N] [--native <fx binary>] [--out <json file>] [--shim <url>] [--upstream <url>] [--skip page,direct,native,baseline,cache] [--only-prompt plain|long|tool]';
const MODEL = 'claude-hy4[1m]';
const PROMPTS = [
  { id: 'plain', typed: 'fx ask reply with only the word ok', prompt: 'reply with only the word ok' },
  { id: 'long', typed: 'fx ask count from 1 to 120 with one number per line and nothing else', prompt: 'count from 1 to 120 with one number per line and nothing else' },
  { id: 'tool', typed: 'fx ask run the command "echo probe-42" with the Bash tool and reply with its output', prompt: 'run the command echo probe-42 with the Bash tool and reply with its output' },
];
const ASK_TIMEOUT_MS = 240000;
const FORWARDED_HEADERS = new Set(['authorization', 'content-type', 'accept', 'origin', 'user-agent']);

const epoch = () => performance.timeOrigin + performance.now();
const round = (value) => (typeof value === 'number' && Number.isFinite(value) ? Math.round(value * 10) / 10 : null);
const span = (from, to) => (typeof from === 'number' && typeof to === 'number' ? round(to - from) : null);
const loadAverage = () => Number(readFileSync('/proc/loadavg', 'utf8').split(' ')[0]);

const parseArgs = (argv) => {
  const options = { runs: 3, native: '/tmp/fx-release/bin/fx', out: null, shim: 'http://127.0.0.1:8793', upstream: 'http://127.0.0.1:8792', skip: new Set(), onlyPrompt: null, thebird: null };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === '--runs') options.runs = Math.max(1, Number(argv[++index]));
    else if (arg === '--native') options.native = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--shim') options.shim = argv[++index].replace(/\/$/, '');
    else if (arg === '--upstream') options.upstream = argv[++index].replace(/\/$/, '');
    else if (arg === '--skip') options.skip = new Set(argv[++index].split(','));
    else if (arg === '--only-prompt') options.onlyPrompt = argv[++index];
    else if (!options.thebird) options.thebird = resolve(arg);
    else throw new Error(USAGE);
  }
  if (!options.thebird) throw new Error(USAGE);
  return options;
};

const liveKey = () => {
  const key = process.env.THEBIRD_LIVE_FX_KEY ?? JSON.parse(readFileSync('/config/.fx/settings.json', 'utf8')).providers?.gy4?.auth?.key;
  if (!key) throw new Error('the probe needs THEBIRD_LIVE_FX_KEY or the gy4 key in /config/.fx/settings.json');
  return key;
};

const describeChatBody = (bytes) => {
  let body;
  try {
    body = JSON.parse(bytes.toString('utf8'));
  } catch {
    return {};
  }
  if (!Array.isArray(body?.messages)) return {};
  const size = (value) => Buffer.byteLength(JSON.stringify(value));
  const systemMessages = body.messages.filter((message) => message.role === 'system' || message.role === 'developer');
  const conversation = body.messages.filter((message) => message.role !== 'system' && message.role !== 'developer');
  return {
    chat: {
      model: body.model,
      stream: Boolean(body.stream),
      maxTokens: body.max_tokens ?? body.max_completion_tokens ?? null,
      messageCount: body.messages.length,
      roles: body.messages.map((message) => message.role),
      systemBytes: systemMessages.reduce((total, message) => total + size(message), 0),
      toolsBytes: body.tools ? size(body.tools) : 0,
      conversationBytes: conversation.reduce((total, message) => total + size(message), 0),
      toolNames: (body.tools ?? []).map((tool) => tool.function?.name ?? tool.name),
      otherKeys: Object.keys(body).filter((key) => !['messages', 'tools', 'model', 'stream'].includes(key)),
    },
    parsed: body,
  };
};

const sseReader = (record) => {
  let buffer = '';
  record.frames = 0;
  record.textChars = 0;
  record.toolCalls = 0;
  return (chunk) => {
    buffer += chunk.toString('utf8');
    let end = buffer.indexOf('\n\n');
    while (end !== -1) {
      const frame = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      end = buffer.indexOf('\n\n');
      const data = frame.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trimStart()).join('\n');
      if (!data || data === '[DONE]') continue;
      let payload;
      try {
        payload = JSON.parse(data);
      } catch {
        continue;
      }
      record.frames += 1;
      const choice = payload.choices?.[0];
      const delta = choice?.delta ?? {};
      const hasText = typeof delta.content === 'string' && delta.content.length > 0;
      if (hasText) record.textChars += delta.content.length;
      for (const call of delta.tool_calls ?? []) if (call.id) record.toolCalls += 1;
      if (hasText || delta.tool_calls) record.firstContentAt ??= epoch();
      if (choice?.finish_reason) record.finishReason = choice.finish_reason;
      if (payload.usage) record.usage = payload.usage;
      if (payload.error) record.error = String(payload.error.message ?? '').slice(0, 300);
    }
  };
};

const startLoggingProxy = async (target) => {
  const upstream = new URL(target);
  const records = [];
  const bodies = [];
  const server = createServer((req, res) => {
    const record = { seq: records.length, method: req.method, path: req.url, client: req.headers.origin ? 'browser' : 'native', at: epoch(), requestBytes: 0, responseBytes: 0 };
    records.push(record);
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      record.requestBytes = body.length;
      record.requestEndAt = epoch();
      const described = describeChatBody(body);
      if (described.chat) {
        record.chat = described.chat;
        bodies.push({ seq: record.seq, body: described.parsed });
      }
      record.headerNames = Object.keys(req.headers).sort();
      const headers = Object.fromEntries(Object.entries(req.headers).filter(([name]) => FORWARDED_HEADERS.has(name) || name.startsWith('access-control-request-')));
      if (body.length > 0 || req.method === 'POST') headers['content-length'] = String(body.length);
      const forward = httpRequest({ hostname: upstream.hostname, port: upstream.port, path: req.url, method: req.method, headers }, (upstreamResponse) => {
        record.status = upstreamResponse.statusCode;
        record.headersAt = epoch();
        record.contentType = upstreamResponse.headers['content-type'] ?? null;
        res.writeHead(upstreamResponse.statusCode, upstreamResponse.headers);
        res.flushHeaders();
        const readSse = sseReader(record);
        let plain = '';
        upstreamResponse.on('data', (chunk) => {
          record.firstByteAt ??= epoch();
          record.responseBytes += chunk.length;
          if (String(record.contentType).includes('event-stream')) readSse(chunk);
          else if (plain.length < 200000) plain += chunk.toString('utf8');
          res.write(chunk);
        });
        upstreamResponse.on('end', () => {
          record.lastByteAt = epoch();
          if (plain) {
            try {
              const payload = JSON.parse(plain);
              if (payload.usage) record.usage = payload.usage;
              if (payload.error) record.error = String(payload.error.message ?? '').slice(0, 300);
              if (Array.isArray(payload.data)) record.listed = payload.data.length;
            } catch {
              record.unparsed = true;
            }
          }
          res.end();
        });
      });
      forward.on('error', (error) => {
        record.proxyError = error.message;
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json', 'access-control-allow-origin': '*' });
        res.end(JSON.stringify({ error: { message: `probe proxy: ${error.message}` } }));
      });
      forward.end(body);
    });
  });
  await new Promise((ok, fail) => {
    server.once('error', fail);
    server.listen(0, '127.0.0.1', ok);
  });
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    records,
    bodies,
    window: (from, to) => records.filter((record) => record.at >= from && record.at <= to),
    close: () => new Promise((ok) => {
      server.closeAllConnections();
      server.close(ok);
    }),
  };
};

const WORKER_PATCH = `(() => {
  if (globalThis.__fxProbe) return;
  const now = () => performance.timeOrigin + performance.now();
  const marks = [];
  globalThis.__fxProbe = marks;
  const mark = (kind, detail = {}) => marks.push({ kind, at: now(), ...detail });
  const timed = (owner, name) => {
    const original = owner[name];
    if (typeof original !== 'function') return;
    owner[name] = function (...args) {
      const id = marks.length;
      mark(name + ':start', { id });
      const result = original.apply(this, args);
      Promise.resolve(result).then(() => mark(name + ':end', { id }), () => mark(name + ':fail', { id }));
      return result;
    };
  };
  for (const name of ['compileStreaming', 'compile', 'instantiate', 'instantiateStreaming']) timed(WebAssembly, name);
  if (typeof WebAssembly.promising === 'function') {
    const promising = WebAssembly.promising;
    WebAssembly.promising = function (target) {
      const wrapped = promising.call(this, target);
      return function (...args) {
        const id = marks.length;
        mark('start:call', { id });
        const result = wrapped.apply(this, args);
        Promise.resolve(result).then(() => mark('start:return', { id }), () => mark('start:throw', { id }));
        return result;
      };
    };
  }
  const originalFetch = globalThis.fetch;
  globalThis.fetch = function (input, init) {
    const url = String(typeof input === 'string' ? input : input?.url ?? input).split('?')[0];
    const id = marks.length;
    mark('fetch:start', { id, url, method: init?.method ?? input?.method ?? 'GET' });
    const result = originalFetch.apply(this, arguments);
    result.then((response) => mark('fetch:headers', { id, url, status: response.status }), () => mark('fetch:fail', { id, url }));
    return result;
  };
})()`;

const SCREEN_PATCH = `(() => {
  if (globalThis.__fxScreen) return true;
  const now = () => performance.timeOrigin + performance.now();
  const events = [];
  globalThis.__fxScreen = events;
  addEventListener('keydown', (event) => { if (event.key === 'Enter') events.push({ kind: 'enter', at: now() }); }, true);
  globalThis.thebird.term.onWriteParsed(() => events.push({ kind: 'write', at: now(), text: globalThis.thebird.text().slice(-1500) }));
  new MutationObserver(() => events.push({ kind: 'busy', at: now(), busy: document.body.dataset.busy === 'true' })).observe(document.body, { attributes: true, attributeFilter: ['data-busy'] });
  return true;
})()`;

const installSocketTap = () => {
  const NativeSocket = globalThis.WebSocket;
  const roots = new Map();
  let send = null;
  const prepare = (sessionId) => {
    send('Network.enable', {}, sessionId).catch(() => {});
    send('Runtime.evaluate', { expression: WORKER_PATCH }, sessionId).catch(() => {});
    send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId).catch(() => {});
    send('Runtime.runIfWaitingForDebugger', {}, sessionId).catch(() => {});
  };
  const onMessage = (message) => {
    if (message.id !== undefined || !send) return;
    const { method, params = {}, sessionId: from } = message;
    const root = roots.get(from);
    if (!root) return;
    if (method === 'Target.attachedToTarget') {
      roots.set(params.sessionId, root);
      root.workers.push({ sessionId: params.sessionId, type: params.targetInfo.type, url: params.targetInfo.url, at: epoch() });
      prepare(params.sessionId);
      return;
    }
    if (!method.startsWith('Network.')) return;
    const origin = from === root.sessionId ? 'page' : 'worker';
    const key = `${from}:${params.requestId}`;
    if (method === 'Network.requestWillBeSent') {
      const postData = params.request.postData;
      root.requests.set(key, {
        origin,
        requestId: params.requestId,
        url: params.request.url.split('?')[0],
        method: params.request.method,
        type: params.type ?? null,
        sentAt: params.wallTime * 1000,
        offset: params.wallTime - params.timestamp,
        postBytes: typeof postData === 'string' ? Buffer.byteLength(postData) : null,
        dataBytes: 0,
      });
      return;
    }
    const record = root.requests.get(key);
    if (!record) return;
    const at = (params.timestamp + record.offset) * 1000;
    if (method === 'Network.responseReceived') {
      record.status = params.response.status;
      record.headersAt = at;
      record.fromDiskCache = Boolean(params.response.fromDiskCache);
      record.mime = params.response.mimeType;
      record.protocol = params.response.protocol ?? null;
      record.connectionReused = params.response.connectionReused ?? null;
      const timing = params.response.timing;
      if (timing) record.timing = { connect: round(timing.connectEnd - timing.connectStart), sendEnd: round(timing.sendEnd), receiveHeadersEnd: round(timing.receiveHeadersEnd) };
    } else if (method === 'Network.dataReceived') {
      record.firstDataAt ??= at;
      record.dataBytes += params.dataLength;
    } else if (method === 'Network.loadingFinished') {
      record.finishedAt = at;
      record.encodedBytes = params.encodedDataLength;
    } else if (method === 'Network.loadingFailed') {
      record.failedAt = at;
      record.failure = params.errorText;
    }
  };
  globalThis.WebSocket = class TapSocket extends NativeSocket {
    constructor(...args) {
      super(...args);
      this.addEventListener('message', ({ data }) => onMessage(JSON.parse(data)));
    }
  };
  return {
    bind: (browserSend) => { send = browserSend; },
    track: (sessionId) => {
      const root = { sessionId, workers: [], requests: new Map() };
      roots.set(sessionId, root);
      return root;
    },
    release: (root) => {
      for (const [sessionId, owner] of roots) if (owner === root) roots.delete(sessionId);
    },
  };
};

const KEY_ENTER = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, modifiers: 0 };

const openPage = async ({ browser, tap, url, initScript }) => {
  const { send, sessions } = browser;
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const logs = [];
  sessions.set(sessionId, { logs, blockUrls: [] });
  const root = tap.track(sessionId);
  const evaluate = async (expression, session = sessionId) => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true }, session);
    return result.result?.value;
  };
  await send('Page.enable', {}, sessionId);
  await send('Page.addScriptToEvaluateOnNewDocument', { source: initScript }, sessionId);
  await send('Runtime.enable', {}, sessionId);
  await send('Log.enable', {}, sessionId);
  await send('Network.enable', {}, sessionId);
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId);
  const navigatedAt = epoch();
  await send('Page.navigate', { url }, sessionId);
  const deadline = Date.now() + 300000;
  while (!(await evaluate("document.body && document.body.dataset.done === 'true'"))) {
    if (Date.now() > deadline) throw new Error('the thebird page did not finish loading');
    await sleep(100);
  }
  const readyAt = epoch();
  await evaluate(SCREEN_PATCH);
  const workerMarks = async () => {
    const all = [];
    for (const worker of root.workers) {
      const text = await evaluate('JSON.stringify(globalThis.__fxProbe ?? [])', worker.sessionId).catch(() => '[]');
      for (const mark of JSON.parse(text ?? '[]')) all.push(mark);
    }
    return all.sort((left, right) => left.at - right.at);
  };
  const ask = async (typed) => {
    await send('Input.insertText', { text: typed }, sessionId);
    await sleep(200);
    const pressedAt = epoch();
    await send('Input.dispatchKeyEvent', { type: 'keyDown', ...KEY_ENTER, text: '\r' }, sessionId);
    await send('Input.dispatchKeyEvent', { type: 'keyUp', ...KEY_ENTER }, sessionId);
    const finished = `(() => { const events = globalThis.__fxScreen; const index = events.findLastIndex((event) => event.kind === 'enter'); return index >= 0 && events.slice(index).some((event) => event.kind === 'busy' && !event.busy); })()`;
    const limit = Date.now() + ASK_TIMEOUT_MS;
    let timedOut = false;
    while (!(await evaluate(finished))) {
      if (Date.now() > limit) {
        timedOut = true;
        break;
      }
      await sleep(40);
    }
    await sleep(400);
    const events = JSON.parse(await evaluate('JSON.stringify(globalThis.__fxScreen.splice(0))'));
    const collectedAt = epoch();
    return { pressedAt, collectedAt, timedOut, events, marks: await workerMarks(), requests: [...root.requests.values()], screen: await evaluate('globalThis.thebird.text().slice(-700)') };
  };
  return {
    root,
    logs,
    loadMs: round(readyAt - navigatedAt),
    navigatedAt,
    readyAt,
    ask,
    requests: () => [...root.requests.values()],
    close: async () => {
      sessions.delete(sessionId);
      tap.release(root);
      await send('Target.closeTarget', { targetId }).catch(() => {});
    },
  };
};

const classify = (request) => {
  if (request.type === 'Preflight' || request.method === 'OPTIONS') return 'cors-preflight';
  if (request.url.endsWith('.wasm')) return 'wasm';
  if (request.url.endsWith('/chat/completions')) return 'chat-completions';
  if (request.url.endsWith('/models')) return 'models';
  return 'other';
};

const dedupe = (requests) => {
  const kept = new Map();
  for (const request of requests) {
    const key = `${request.requestId}|${request.url}|${request.method}`;
    const existing = kept.get(key);
    if (!existing || (existing.origin === 'page' && request.origin === 'worker')) kept.set(key, request);
  }
  return [...kept.values()].sort((left, right) => left.sentAt - right.sentAt);
};

const turnsFromProxy = (records) => records.filter((record) => record.chat).map((record) => ({
  status: record.status,
  requestBytes: record.requestBytes,
  systemBytes: record.chat.systemBytes,
  toolsBytes: record.chat.toolsBytes,
  conversationBytes: record.chat.conversationBytes,
  messageCount: record.chat.messageCount,
  toolNames: record.chat.toolNames,
  otherKeys: record.chat.otherKeys,
  maxTokens: record.chat.maxTokens,
  stream: record.chat.stream,
  receivedAt: record.at,
  headersAt: record.headersAt,
  firstByteAt: record.firstByteAt,
  firstContentAt: record.firstContentAt,
  lastByteAt: record.lastByteAt,
  ttfbMs: span(record.at, record.headersAt),
  headersToFirstContentMs: span(record.headersAt, record.firstContentAt),
  streamMs: span(record.firstContentAt ?? record.firstByteAt, record.lastByteAt),
  totalMs: span(record.at, record.lastByteAt),
  responseBytes: record.responseBytes,
  frames: record.frames,
  textChars: record.textChars,
  toolCalls: record.toolCalls,
  finishReason: record.finishReason ?? null,
  usage: record.usage ?? null,
  error: record.error ?? null,
  headerNames: record.headerNames ?? [],
}));

const analysePageAsk = ({ typed, capture, proxyRecords, viaProxy }) => {
  const enter = capture.events.findLast((event) => event.kind === 'enter');
  const enterAt = enter?.at ?? capture.pressedAt;
  const after = capture.events.filter((event) => event.at >= enterAt);
  const outputOf = (text) => {
    const index = text.lastIndexOf(typed);
    return index === -1 ? '' : text.slice(index + typed.length);
  };
  const firstVisible = after.find((event) => event.kind === 'write' && outputOf(event.text).trim() !== '');
  const idle = after.find((event) => event.kind === 'busy' && !event.busy);
  const promptWrite = idle ? after.find((event) => event.kind === 'write' && event.at >= idle.at) : null;
  const doneAt = promptWrite?.at ?? idle?.at ?? null;
  const windowEnd = (doneAt ?? capture.collectedAt) + 300;
  const requests = dedupe(capture.requests.filter((request) => request.sentAt >= enterAt - 5 && request.sentAt <= windowEnd));
  const counts = {};
  for (const request of requests) counts[classify(request)] = (counts[classify(request)] ?? 0) + 1;
  const inFlight = capture.requests.filter((request) => request.sentAt < enterAt - 5 && (request.finishedAt ?? request.failedAt ?? Infinity) > enterAt);
  const marks = capture.marks.filter((mark) => mark.at >= enterAt - 5 && mark.at <= windowEnd);
  const pair = (name) => {
    const start = marks.find((mark) => mark.kind === `${name}:start`);
    const end = start ? marks.find((mark) => mark.kind === `${name}:end` && mark.id === start.id) : null;
    return { startAt: start?.at ?? null, endAt: end?.at ?? null, ms: span(start?.at, end?.at) };
  };
  const wasm = requests.find((request) => classify(request) === 'wasm');
  const compile = pair('compileStreaming').startAt === null ? pair('compile') : pair('compileStreaming');
  const instantiate = pair('instantiate');
  const startCall = marks.find((mark) => mark.kind === 'start:call');
  const startReturn = marks.find((mark) => mark.kind === 'start:return' || mark.kind === 'start:throw');
  const chatFetches = marks.filter((mark) => mark.kind === 'fetch:start' && mark.url.endsWith('/chat/completions'));
  const chatRequests = requests.filter((request) => classify(request) === 'chat-completions');
  const cdpTurns = chatRequests.map((request) => ({
    sentAt: request.sentAt,
    status: request.status ?? null,
    postBytes: request.postBytes,
    ttfbMs: span(request.sentAt, request.headersAt),
    headersToFirstDataMs: span(request.headersAt, request.firstDataAt),
    streamMs: span(request.firstDataAt, request.finishedAt),
    finishedAt: request.finishedAt ?? null,
    encodedBytes: request.encodedBytes ?? null,
    connectionReused: request.connectionReused ?? null,
  }));
  const proxyTurns = viaProxy ? turnsFromProxy(proxyRecords) : [];
  const firstRequestAt = chatFetches[0]?.at ?? chatRequests[0]?.sentAt ?? null;
  const lastFinishedAt = chatRequests.at(-1)?.finishedAt ?? null;
  const gaps = [];
  for (let index = 1; index < chatRequests.length; index++) gaps.push(span(chatRequests[index - 1].finishedAt, chatFetches[index]?.at ?? chatRequests[index].sentAt));
  const firstStreamByteAt = chatRequests[0]?.firstDataAt ?? null;
  const firstTextAt = viaProxy ? proxyRecords.filter((record) => record.chat && record.textChars > 0).map((record) => record.firstContentAt)[0] ?? null : null;
  return {
    enterAt,
    output: firstVisible ? outputOf(after.findLast((event) => event.kind === 'write')?.text ?? '').trim().slice(0, 200) : '',
    timedOut: capture.timedOut,
    modelTurns: viaProxy ? proxyTurns.filter((turn) => turn.status === 200).length : cdpTurns.filter((turn) => turn.status === 200).length,
    toolCalls: viaProxy ? proxyTurns.reduce((total, turn) => total + (turn.toolCalls ?? 0), 0) : null,
    httpRequests: requests.length,
    httpByClass: counts,
    inFlightAtEnter: inFlight.map((request) => `${request.method} ${request.url.split('/').slice(-2).join('/')} ${request.finishedAt ? `finished ${round(request.finishedAt - enterAt)} ms after Enter` : 'unfinished'}`),
    otherUrls: requests.filter((request) => classify(request) === 'other').map((request) => `${request.method} ${request.url} ${request.status ?? request.failure ?? 'pending'}`),
    timeline: {
      enterToFirstStreamByteMs: span(enterAt, firstStreamByteAt),
      enterToFirstTextDeltaMs: span(enterAt, firstTextAt),
      enterToFirstVisibleMs: span(enterAt, firstVisible?.at),
      enterToLastByteMs: span(enterAt, lastFinishedAt),
      enterToPromptMs: span(enterAt, doneAt),
    },
    phases: {
      enterToWasmRequestMs: span(enterAt, wasm?.sentAt ?? compile.startAt ?? instantiate.startAt),
      wasmFetchMs: wasm ? span(wasm.sentAt, wasm.finishedAt) : 0,
      wasmBytes: wasm?.encodedBytes ?? 0,
      wasmFromDiskCache: wasm?.fromDiskCache ?? null,
      wasmCompileMs: compile.ms ?? 0,
      wasmCompileEndSinceEnterMs: span(enterAt, compile.endAt),
      wasmInstantiateMs: instantiate.ms,
      enterToInstantiateStartMs: span(enterAt, instantiate.startAt),
      instantiateEndToStartCallMs: span(instantiate.endAt, startCall?.at),
      startCallToFirstRequestMs: span(startCall?.at, firstRequestAt),
      enterToFirstRequestMs: span(enterAt, firstRequestAt),
      betweenTurnsMs: gaps,
      lastByteToStartReturnMs: span(lastFinishedAt, startReturn?.at),
      lastByteToFirstVisibleMs: span(lastFinishedAt, firstVisible?.at),
      lastByteToPromptMs: span(lastFinishedAt, doneAt),
    },
    cdpTurns,
    proxyTurns,
    proxyOther: viaProxy ? proxyRecords.filter((record) => !record.chat).map((record) => ({ method: record.method, path: record.path, status: record.status, ms: span(record.at, record.lastByteAt) })) : [],
    marks: marks.map((mark) => ({ kind: mark.kind, sinceEnterMs: round(mark.at - enterAt), url: mark.url, status: mark.status })),
    load: loadAverage(),
  };
};

const pageScenario = async ({ thebird, driver, tap, relayUrl, chatUrl, key, prompt, proxy, pagesPerBrowser, asksPerPage, chrome }) => {
  const profile = mkdtempSync(join(tmpdir(), 'fx-ask-probe-profile-'));
  const browser = await driver.startBrowser({ chrome, profile });
  tap.bind(browser.send);
  const results = [];
  try {
    for (let pageIndex = 0; pageIndex < pagesPerBrowser; pageIndex++) {
      const page = await openPage({ browser, tap, url: relayUrl, initScript: `window.THEBIRD_FX = ${JSON.stringify({ apiKey: key, model: MODEL, gatewayChatUrl: chatUrl })};` });
      try {
        for (let askIndex = 0; askIndex < asksPerPage; askIndex++) {
          const from = epoch();
          const capture = await page.ask(prompt.typed);
          const analysed = analysePageAsk({ typed: prompt.typed, capture, proxyRecords: proxy ? proxy.window(from, capture.collectedAt) : [], viaProxy: Boolean(proxy) });
          const condition = askIndex > 0 ? 'warm' : pageIndex === 0 ? 'cold-fresh-profile' : 'cold-reused-profile';
          results.push({ surface: 'page', route: proxy ? 'proxy' : 'direct', prompt: prompt.id, condition, pageLoadMs: page.loadMs, ...analysed, httpErrors: page.logs.filter((line) => /HTTP [45]\d\d|status of [45]\d\d/.test(line)).length });
          console.log(`page ${proxy ? 'proxy ' : 'direct'} ${prompt.id} ${condition}: turns ${analysed.modelTurns} http ${analysed.httpRequests} first-visible ${analysed.timeline.enterToFirstVisibleMs} ms prompt ${analysed.timeline.enterToPromptMs} ms output ${JSON.stringify(analysed.output.slice(0, 80))}`);
        }
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
    rmSync(profile, { recursive: true, force: true });
  }
  return results;
};

const children = new Set();

const killTree = (root) => {
  const parents = new Map();
  for (const entry of readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = readFileSync(`/proc/${entry}/stat`, 'utf8');
      parents.set(Number(entry), Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]));
    } catch {
      continue;
    }
  }
  const tree = [root];
  for (let index = 0; index < tree.length; index++) for (const [pid, parent] of parents) if (parent === tree[index]) tree.push(pid);
  for (const pid of tree.reverse()) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      continue;
    }
  }
};

process.on('exit', () => {
  for (const pid of children) killTree(pid);
});

const runNative = ({ bin, args, env, cwd }) => new Promise((done) => {
  const startedAt = epoch();
  const child = spawn(bin, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  children.add(child.pid);
  const result = { startedAt, firstStdoutAt: null, firstStderrAt: null, stdout: '', stderrBytes: 0 };
  const timer = setTimeout(() => killTree(child.pid), ASK_TIMEOUT_MS);
  child.stdout.on('data', (chunk) => {
    result.firstStdoutAt ??= epoch();
    result.stdout += chunk.toString('utf8');
  });
  child.stderr.on('data', (chunk) => {
    result.firstStderrAt ??= epoch();
    result.stderrBytes += chunk.length;
  });
  child.on('close', (code) => {
    clearTimeout(timer);
    children.delete(child.pid);
    done({ ...result, exitedAt: epoch(), code });
  });
});

const analyseNative = ({ run, proxyRecords, route, prompt, mode }) => {
  const turns = turnsFromProxy(proxyRecords);
  const gaps = [];
  for (let index = 1; index < turns.length; index++) gaps.push(span(turns[index - 1].lastByteAt, turns[index].receivedAt));
  const counts = {};
  for (const record of proxyRecords) {
    const kind = record.chat ? 'chat-completions' : record.path.endsWith('/models') ? 'models' : 'other';
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  let json = null;
  if (mode === 'json') {
    try {
      json = JSON.parse(run.stdout);
    } catch {
      json = null;
    }
  }
  const firstTextAt = proxyRecords.filter((record) => record.chat && record.textChars > 0).map((record) => record.firstContentAt)[0] ?? null;
  return {
    surface: 'native',
    route,
    prompt: prompt.id,
    condition: mode === 'json' ? 'native-json' : 'native',
    exitCode: run.code,
    output: mode === 'json' ? String(json?.final_output ?? json?.output ?? '').slice(0, 200) : run.stdout.trim().slice(0, 200),
    jsonUsage: json?.usage ?? null,
    modelTurns: route === 'proxy' ? turns.filter((turn) => turn.status === 200).length : null,
    toolCalls: route === 'proxy' ? turns.reduce((total, turn) => total + (turn.toolCalls ?? 0), 0) : null,
    httpRequests: route === 'proxy' ? proxyRecords.length : null,
    httpByClass: route === 'proxy' ? counts : null,
    timeline: {
      spawnToFirstStreamByteMs: span(run.startedAt, turns[0]?.firstByteAt),
      spawnToFirstTextDeltaMs: span(run.startedAt, firstTextAt),
      spawnToFirstStdoutMs: span(run.startedAt, run.firstStdoutAt),
      spawnToLastByteMs: span(run.startedAt, turns.at(-1)?.lastByteAt),
      spawnToExitMs: span(run.startedAt, run.exitedAt),
    },
    phases: {
      spawnToFirstRequestMs: span(run.startedAt, turns[0]?.receivedAt ?? proxyRecords[0]?.at),
      betweenTurnsMs: gaps,
      lastByteToFirstStdoutMs: span(turns.at(-1)?.lastByteAt, run.firstStdoutAt),
      lastByteToExitMs: span(turns.at(-1)?.lastByteAt, run.exitedAt),
    },
    proxyTurns: turns,
    proxyOther: proxyRecords.filter((record) => !record.chat).map((record) => ({ method: record.method, path: record.path, status: record.status, ms: span(record.at, record.lastByteAt) })),
    load: loadAverage(),
  };
};

const nativeScenario = async ({ bin, prompt, proxy, key, runs }) => {
  const results = [];
  const realSettings = JSON.parse(readFileSync('/config/.fx/settings.json', 'utf8'));
  const home = mkdtempSync(join(tmpdir(), 'fx-ask-probe-home-'));
  const cwd = mkdtempSync(join(tmpdir(), 'fx-ask-probe-cwd-'));
  mkdirSync(home, { recursive: true });
  writeFileSync(join(home, 'settings.json'), JSON.stringify({
    providers: { gy4: { protocol: 'openai-chat-completions', base_url: `${proxy.url}/v1`, auth: { type: 'bearer', env: 'FX_ASK_PROBE_KEY' }, model_metadata: realSettings.providers?.gy4?.model_metadata ?? {} } },
    models: { gy4: MODEL },
    provider: 'gy4',
    permission_mode: 'yolo',
    yolo_acknowledged: true,
  }, null, 1));
  const proxiedEnv = { ...process.env, FX_HOME: home, FX_ASK_PROBE_KEY: key, NO_COLOR: '1' };
  const directEnv = { ...process.env, NO_COLOR: '1' };
  try {
    for (let index = 0; index < runs; index++) {
      for (const mode of ['text', 'json']) {
        const from = epoch();
        const args = ['ask', '--no-save', '--provider', 'gy4', '--model', MODEL, ...(mode === 'json' ? ['--json'] : []), '--', prompt.prompt];
        const run = await runNative({ bin, args, env: proxiedEnv, cwd });
        const analysed = analyseNative({ run, proxyRecords: proxy.window(from, epoch()), route: 'proxy', prompt, mode });
        results.push(analysed);
        console.log(`native proxy ${prompt.id} ${mode}: rc ${run.code} turns ${analysed.modelTurns} http ${analysed.httpRequests} first-stdout ${analysed.timeline.spawnToFirstStdoutMs} ms exit ${analysed.timeline.spawnToExitMs} ms output ${JSON.stringify(analysed.output.slice(0, 80))}`);
      }
      const direct = await runNative({ bin, args: ['ask', '--no-save', '--provider', 'gy4', '--model', MODEL, '--', prompt.prompt], env: directEnv, cwd });
      const analysedDirect = analyseNative({ run: direct, proxyRecords: [], route: 'direct', prompt, mode: 'text' });
      results.push(analysedDirect);
      console.log(`native direct ${prompt.id}: rc ${direct.code} first-stdout ${analysedDirect.timeline.spawnToFirstStdoutMs} ms exit ${analysedDirect.timeline.spawnToExitMs} ms`);
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  }
  return results;
};

const cacheProbe = async ({ upstream, key, body }) => {
  const systemText = body.messages.filter((message) => message.role === 'system' || message.role === 'developer').map((message) => (typeof message.content === 'string' ? message.content : (message.content ?? []).map((part) => part.text ?? '').join(''))).filter(Boolean).join('\n\n');
  const tools = (body.tools ?? []).map((tool) => ({ name: tool.function.name, description: tool.function.description ?? '', input_schema: tool.function.parameters ?? { type: 'object', properties: {} } }));
  const call = async (label, system) => {
    const startedAt = epoch();
    const response = await fetch(`${upstream}/v1/messages`, {
      method: 'POST',
      headers: { 'anthropic-version': '2023-06-01', 'content-type': 'application/json', authorization: `Bearer ${key}` },
      body: JSON.stringify({ model: body.model, max_tokens: 16, thinking: { type: 'disabled' }, system, ...(tools.length ? { tools } : {}), messages: [{ role: 'user', content: [{ type: 'text', text: 'reply with only the word ok' }] }] }),
    });
    const payload = await response.json().catch(() => ({}));
    return { label, status: response.status, ms: span(startedAt, epoch()), usage: payload.usage ?? null, error: payload.error?.message?.slice(0, 200) ?? null };
  };
  const fresh = (tag) => `probe nonce ${tag} ${Date.now()} ${Math.random()}\n\n${systemText}`;
  const unmarked = fresh('unmarked');
  const markedText = fresh('marked');
  const marked = [{ type: 'text', text: markedText, cache_control: { type: 'ephemeral' } }];
  const results = [];
  results.push(await call('known-prefix-as-shim-sends', systemText));
  results.push(await call('fresh-prefix-as-shim-sends-1', unmarked));
  results.push(await call('fresh-prefix-as-shim-sends-2', unmarked));
  results.push(await call('fresh-prefix-as-shim-sends-3', unmarked));
  results.push(await call('fresh-prefix-with-cache-control-1', marked));
  results.push(await call('fresh-prefix-with-cache-control-2', marked));
  results.push(await call('fresh-prefix-with-cache-control-3', marked));
  return { systemChars: systemText.length, toolCount: tools.length, results };
};

const baseline = async ({ shim, upstream, key, runs }) => {
  const timed = async (label, path, init) => {
    const startedAt = epoch();
    const response = await fetch(`${shim}${path}`, { ...init, headers: { authorization: `Bearer ${key}`, ...(init?.body ? { 'content-type': 'application/json' } : {}) } });
    const headersAt = epoch();
    const text = await response.text();
    let usage = null;
    try {
      usage = JSON.parse(text).usage ?? null;
    } catch {
      usage = null;
    }
    return { label, status: response.status, headersMs: span(startedAt, headersAt), totalMs: span(startedAt, epoch()), bytes: text.length, usage };
  };
  const rows = [];
  for (let index = 0; index < runs; index++) {
    rows.push(await timed('models', '/v1/models', { method: 'GET' }));
    rows.push(await timed('minimal-chat', '/v1/chat/completions', { method: 'POST', body: JSON.stringify({ model: MODEL, max_tokens: 16, stream: false, messages: [{ role: 'user', content: 'reply with only the word ok' }] }) }));
  }
  const shape = async (label, url, body, headers) => {
    const startedAt = epoch();
    const response = await fetch(url, { method: 'POST', headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
    const headersAt = epoch();
    const arrivals = [];
    let bytes = 0;
    for await (const chunk of response.body) {
      bytes += chunk.length;
      arrivals.push({ at: epoch(), bytes });
    }
    const quantile = (share) => span(startedAt, arrivals.find((arrival) => arrival.bytes >= bytes * share)?.at);
    return { label, status: response.status, headersMs: span(startedAt, headersAt), firstChunkMs: span(startedAt, arrivals[0]?.at), quarterBytesMs: quantile(0.25), halfBytesMs: quantile(0.5), lastChunkMs: span(startedAt, arrivals.at(-1)?.at), chunks: arrivals.length, bytes };
  };
  const longMessages = [{ role: 'user', content: 'count from 1 to 120 with one number per line and nothing else' }];
  const streams = [];
  for (let index = 0; index < runs; index++) {
    streams.push(await shape('shim-stream', `${shim}/v1/chat/completions`, { model: MODEL, max_tokens: 1024, stream: true, messages: longMessages }, {}));
    streams.push(await shape('upstream-stream', `${upstream}/v1/messages`, { model: MODEL, max_tokens: 1024, stream: true, thinking: { type: 'disabled' }, messages: longMessages }, { 'anthropic-version': '2023-06-01' }));
  }
  const of = (label, field) => stats(rows.filter((row) => row.label === label && row.status === 200).map((row) => row[field]));
  return { modelsTotalMs: of('models', 'totalMs'), minimalChatTotalMs: of('minimal-chat', 'totalMs'), statuses: rows.map((row) => row.status), minimalChatUsage: rows.find((row) => row.label === 'minimal-chat')?.usage ?? null, streams };
};

const stats = (values) => {
  const numbers = values.filter((value) => typeof value === 'number').sort((left, right) => left - right);
  if (numbers.length === 0) return null;
  const middle = Math.floor(numbers.length / 2);
  const median = numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2;
  return { n: numbers.length, median: round(median), min: round(numbers[0]), max: round(numbers.at(-1)) };
};

const show = (value) => (value ? `${value.median} [${value.min}..${value.max}] n=${value.n}` : 'n/a');

const summarise = (results) => {
  const groups = new Map();
  for (const result of results) {
    const key = `${result.prompt} | ${result.surface} ${result.route} | ${result.condition}`;
    groups.set(key, [...(groups.get(key) ?? []), result]);
  }
  const summary = {};
  for (const [key, rows] of groups) {
    const pick = (read) => stats(rows.map(read));
    const turn = (index, field) => pick((row) => row.proxyTurns?.[index]?.[field] ?? (field === 'ttfbMs' || field === 'streamMs' ? row.cdpTurns?.[index]?.[field] : undefined));
    summary[key] = {
      runs: rows.length,
      modelTurns: pick((row) => row.modelTurns),
      toolCalls: pick((row) => row.toolCalls),
      httpRequests: pick((row) => row.httpRequests),
      httpByClass: rows.map((row) => JSON.stringify(row.httpByClass)).filter((value, index, all) => all.indexOf(value) === index),
      toFirstStreamByteMs: pick((row) => row.timeline.enterToFirstStreamByteMs ?? row.timeline.spawnToFirstStreamByteMs),
      toFirstTextDeltaMs: pick((row) => row.timeline.enterToFirstTextDeltaMs ?? row.timeline.spawnToFirstTextDeltaMs),
      toFirstVisibleMs: pick((row) => row.timeline.enterToFirstVisibleMs ?? row.timeline.spawnToFirstStdoutMs),
      toLastByteMs: pick((row) => row.timeline.enterToLastByteMs ?? row.timeline.spawnToLastByteMs),
      toPromptOrExitMs: pick((row) => row.timeline.enterToPromptMs ?? row.timeline.spawnToExitMs),
      startupToFirstRequestMs: pick((row) => row.phases.enterToFirstRequestMs ?? row.phases.spawnToFirstRequestMs),
      wasmFetchMs: pick((row) => row.phases.wasmFetchMs),
      wasmCompileMs: pick((row) => row.phases.wasmCompileMs),
      wasmInstantiateMs: pick((row) => row.phases.wasmInstantiateMs),
      startCallToFirstRequestMs: pick((row) => row.phases.startCallToFirstRequestMs),
      turn1TtfbMs: turn(0, 'ttfbMs'),
      turn1HeadersToFirstContentMs: turn(0, 'headersToFirstContentMs'),
      turn1StreamMs: turn(0, 'streamMs'),
      betweenTurnsMs: pick((row) => row.phases.betweenTurnsMs?.[0]),
      turn2TtfbMs: turn(1, 'ttfbMs'),
      turn2HeadersToFirstContentMs: turn(1, 'headersToFirstContentMs'),
      turn2StreamMs: turn(1, 'streamMs'),
      tailMs: pick((row) => row.phases.lastByteToPromptMs ?? row.phases.lastByteToExitMs),
      turn1RequestBytes: turn(0, 'requestBytes'),
      turn1SystemBytes: turn(0, 'systemBytes'),
      turn1ToolsBytes: turn(0, 'toolsBytes'),
      turn2RequestBytes: turn(1, 'requestBytes'),
      turn1PromptTokens: pick((row) => row.proxyTurns?.[0]?.usage?.prompt_tokens),
      turn1CompletionTokens: pick((row) => row.proxyTurns?.[0]?.usage?.completion_tokens),
      turn2PromptTokens: pick((row) => row.proxyTurns?.[1]?.usage?.prompt_tokens),
      turn2CompletionTokens: pick((row) => row.proxyTurns?.[1]?.usage?.completion_tokens),
      load: pick((row) => row.load),
    };
  }
  return summary;
};

const printSummary = (summary) => {
  for (const [key, row] of Object.entries(summary)) {
    console.log(`\n== ${key} (runs ${row.runs}) ==`);
    for (const [name, value] of Object.entries(row)) {
      if (name === 'runs') continue;
      console.log(`  ${name}: ${Array.isArray(value) ? value.join(' ; ') : show(value)}`);
    }
  }
};

const main = async () => {
  const options = parseArgs(process.argv.slice(2));
  const key = liveKey();
  const chrome = process.env.CHROME_BIN ?? '/usr/bin/chromium-browser';
  const prompts = PROMPTS.filter((prompt) => !options.onlyPrompt || prompt.id === options.onlyPrompt);
  const tap = installSocketTap();
  const driver = await import(pathToFileURL(join(options.thebird, 'scripts', 'browser-driver.mjs')).href);
  const { startRelay } = await import(pathToFileURL(join(options.thebird, 'src', 'relay.js')).href);
  const site = await startRelay({ port: 0 });
  const proxy = await startLoggingProxy(options.shim);
  const results = [];
  let cache = null;
  let floor = null;
  const started = new Date().toISOString();
  try {
    if (!options.skip.has('page') && existsSync(chrome)) {
      for (let run = 0; run < options.runs; run++) {
        for (const prompt of prompts) {
          results.push(...await pageScenario({ thebird: options.thebird, driver, tap, relayUrl: site.url, chatUrl: `${proxy.url}/v1/chat/completions`, key, prompt, proxy, pagesPerBrowser: 2, asksPerPage: 2, chrome }));
        }
      }
    }
    if (!options.skip.has('direct') && existsSync(chrome)) {
      for (let run = 0; run < options.runs; run++) {
        for (const prompt of prompts) {
          results.push(...await pageScenario({ thebird: options.thebird, driver, tap, relayUrl: site.url, chatUrl: `${options.shim}/v1/chat/completions`, key, prompt, proxy: null, pagesPerBrowser: 1, asksPerPage: 2, chrome }));
        }
      }
    }
    if (!options.skip.has('native') && existsSync(options.native)) {
      for (const prompt of prompts) results.push(...await nativeScenario({ bin: options.native, prompt, proxy, key, runs: options.runs }));
    }
    if (!options.skip.has('baseline')) floor = await baseline({ shim: options.shim, upstream: options.upstream, key, runs: Math.max(3, options.runs) });
    if (!options.skip.has('cache')) {
      const pageBody = proxy.bodies.find((entry) => proxy.records[entry.seq].client === 'browser')?.body;
      const nativeBody = proxy.bodies.find((entry) => proxy.records[entry.seq].client === 'native')?.body;
      cache = {
        page: pageBody ? await cacheProbe({ upstream: options.upstream, key, body: pageBody }) : null,
        native: nativeBody ? await cacheProbe({ upstream: options.upstream, key, body: nativeBody }) : null,
      };
    }
  } finally {
    await proxy.close();
    await site.close();
    driver.closeBrowserTrees();
  }
  const summary = summarise(results);
  printSummary(summary);
  if (floor) console.log(`\nshim baseline: ${JSON.stringify(floor)}`);
  if (cache) console.log(`\ncache probe: ${JSON.stringify(cache, null, 1)}`);
  if (options.out) {
    writeFileSync(options.out, JSON.stringify({ started, finished: new Date().toISOString(), model: MODEL, shim: options.shim, runs: options.runs, summary, baseline: floor, cache, results }, null, 1));
    console.log(`\nresults written to ${options.out}`);
  }
};

main().then(() => process.exit(0), (error) => {
  console.error(error.stack ?? String(error));
  process.exit(1);
});
