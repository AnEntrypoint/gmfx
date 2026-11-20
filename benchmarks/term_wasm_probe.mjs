import { spawn } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, extname, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const USAGE = 'usage: node benchmarks/term_wasm_probe.mjs [--runs N] [--out <json file>] [--shim <url>] [--wasm <fx-term.wasm>] [--xterm <dir with xterm.mjs and xterm.css>] [--native <fx binary>] [--skip node,browser,native] [--only-prompt hi|plain|long|long-shell|tool|paced]';
const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MODEL = 'claude-hy4[1m]';
const MODEL_METADATA = { context_window: 1000000, max_output_tokens: 64000, supports_tool_use: true };
const PROVIDER = 'gy4';
const COUNT_PROMPT = 'count from 1 to 120, one number per line';
const PROMPTS = [
  { id: 'hi', typed: 'hi', workspace: false, route: 'shim', expect: null, native: true },
  { id: 'plain', typed: 'reply with only the word ok', workspace: false, route: 'shim', expect: 'ok', native: true },
  { id: 'long', typed: COUNT_PROMPT, workspace: false, route: 'shim', expect: '120', native: true },
  { id: 'long-shell', typed: COUNT_PROMPT, workspace: true, route: 'shim', expect: '120', native: false },
  { id: 'tool', typed: 'run the command "echo probe-42" with your shell tool and reply with its output', workspace: true, route: 'shim', expect: 'probe-42', native: true },
  { id: 'paced', typed: COUNT_PROMPT, workspace: false, route: 'paced', expect: '120', native: true },
];
const PACED = { count: 120, intervalMs: 25, firstDelayMs: 100 };
const SESSION_TIMEOUT_MS = 420000;
const FORWARDED_HEADERS = new Set(['authorization', 'content-type', 'accept', 'origin', 'user-agent']);
const MIME = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm', '.html': 'text/html; charset=utf-8', '.json': 'application/json' };
const KEY_ENTER = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, modifiers: 0 };

const epoch = () => performance.timeOrigin + performance.now();
const round = (value) => (typeof value === 'number' && Number.isFinite(value) ? Math.round(value * 10) / 10 : null);
const span = (from, to) => (typeof from === 'number' && typeof to === 'number' ? round(to - from) : null);
const loadAverage = () => Number(readFileSync('/proc/loadavg', 'utf8').split(' ')[0]);

const parseArgs = (argv) => {
  const options = { runs: 4, out: null, shim: 'http://127.0.0.1:8793', wasm: join(REPO, 'zig-out', 'bin', 'fx-term.wasm'), xterm: '/workspace/thebird/web/vendor/xterm', native: '/tmp/fx-release/bin/fx', skip: new Set(), onlyPrompt: null, session: false };
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === '--runs') options.runs = Math.max(1, Number(argv[++index]));
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--shim') options.shim = argv[++index].replace(/\/$/, '');
    else if (arg === '--wasm') options.wasm = resolve(argv[++index]);
    else if (arg === '--xterm') options.xterm = resolve(argv[++index]);
    else if (arg === '--native') options.native = resolve(argv[++index]);
    else if (arg === '--skip') options.skip = new Set(argv[++index].split(','));
    else if (arg === '--only-prompt') options.onlyPrompt = argv[++index];
    else if (arg === '--session') options.session = true;
    else throw new Error(USAGE);
  }
  return options;
};

const liveKey = () => {
  const key = process.env.THEBIRD_LIVE_FX_KEY ?? JSON.parse(readFileSync('/config/.fx/settings.json', 'utf8')).providers?.gy4?.auth?.key;
  if (!key) throw new Error('the probe needs THEBIRD_LIVE_FX_KEY or the gy4 key in /config/.fx/settings.json');
  return key;
};

const netTools = () => {
  const now = () => performance.timeOrigin + performance.now();
  const size = (value) => new TextEncoder().encode(JSON.stringify(value)).length;
  const describeChatBody = (text) => {
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      return null;
    }
    if (!Array.isArray(body?.messages)) return null;
    const isSystem = (message) => message.role === 'system' || message.role === 'developer';
    return {
      model: body.model,
      stream: Boolean(body.stream),
      maxTokens: body.max_tokens ?? body.max_completion_tokens ?? null,
      messageCount: body.messages.length,
      roles: body.messages.map((message) => message.role),
      systemMessages: body.messages.filter(isSystem).length,
      systemBytes: body.messages.filter(isSystem).reduce((total, message) => total + size(message), 0),
      toolsBytes: body.tools ? size(body.tools) : 0,
      conversationBytes: body.messages.filter((message) => !isSystem(message)).reduce((total, message) => total + size(message), 0),
      toolNames: (body.tools ?? []).map((tool) => tool.function?.name ?? tool.name),
      otherKeys: Object.keys(body).filter((key) => !['messages', 'tools', 'model', 'stream'].includes(key)),
    };
  };
  const sseReader = (record) => {
    const decoder = new TextDecoder();
    let buffer = '';
    let text = '';
    record.frames = 0;
    record.textChars = 0;
    record.toolCalls = 0;
    record.arrivals = [];
    return (chunk) => {
      buffer += decoder.decode(chunk, { stream: true });
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
        if (hasText) {
          record.textChars += delta.content.length;
          text += delta.content;
          const groups = (text.match(/\d+(?=\D)/g) ?? []).length;
          if (record.arrivals.length < 2000 && groups > (record.arrivals.at(-1)?.groups ?? 0)) record.arrivals.push({ at: now(), groups });
        }
        for (const call of delta.tool_calls ?? []) if (call.id) record.toolCalls += 1;
        if (hasText || delta.tool_calls) record.firstContentAt ??= now();
        if (choice?.finish_reason) record.finishReason = choice.finish_reason;
        if (payload.usage) record.usage = payload.usage;
        if (payload.error) record.error = String(payload.error.message ?? '').slice(0, 300);
      }
    };
  };
  return { describeChatBody, sseReader };
};

const probeWorkspace = () => {
  const calls = [];
  const now = () => performance.timeOrigin + performance.now();
  const answer = (command) => {
    const echo = /^echo ([\w .-]+)$/.exec(command);
    if (echo) return { stdout: `${echo[1]}\n`, stderr: '', exitCode: 0 };
    const seq = /^seq (\d{1,4})(?: (\d{1,4}))?$/.exec(command);
    if (seq) {
      const first = seq[2] === undefined ? 1 : Number(seq[1]);
      const last = Number(seq[2] ?? seq[1]);
      const numbers = [];
      for (let value = first; value <= last; value++) numbers.push(value);
      return { stdout: `${numbers.join('\n')}\n`, stderr: '', exitCode: 0 };
    }
    return { stdout: '', stderr: 'the probe workspace only answers echo and seq\n', exitCode: 126 };
  };
  return {
    calls,
    adapter: {
      info: { version: 1, root: '/workspace', cwd: '/workspace', home: '/home/visitor', gitAvailable: false, ephemeral: true },
      permission: 'allow-sandboxed',
      exec({ command }) {
        const call = { command: String(command).slice(0, 200), startAt: now() };
        calls.push(call);
        const result = answer(String(command).trim());
        call.exitCode = result.exitCode;
        call.endAt = now();
        return result;
      },
    },
  };
};

const runSession = async (env) => {
  const { spec, terminal, tools } = env;
  const now = () => performance.timeOrigin + performance.now();
  const pause = (ms) => new Promise((done) => setTimeout(done, ms));
  const round = (value) => (typeof value === 'number' && Number.isFinite(value) ? Math.round(value * 10) / 10 : null);
  const span = (from, to) => (typeof from === 'number' && typeof to === 'number' ? round(to - from) : null);
  const STATUS = /↑\s?[\d.,kKmM]+/;
  const LABEL = /[A-Za-z]{4,}/;
  const marks = {};
  const frames = [];
  const renders = [];
  const ticks = [];
  const stdout = [];
  const own = [];
  const requests = env.requests ?? (() => own);
  const histories = new Map();
  let stderrText = '';
  let watcherMs = 0;
  let version = 0;
  let previous = null;

  const readFrame = () => {
    const startedAt = performance.now();
    const buffer = terminal.buffer.active;
    const kept = [];
    let working = false;
    for (let row = 0; row < buffer.length; row++) {
      const line = buffer.getLine(row)?.translateToString(true) ?? '';
      if (STATUS.test(line)) {
        if (LABEL.test(line)) working = true;
        continue;
      }
      kept.push(line);
    }
    const text = kept.join('\n');
    if (text !== previous) version += 1;
    previous = text;
    const frame = { at: now(), version, working, welcome: text.includes('𝒇x'), groups: (text.match(/\d+/g) ?? []).length, expect: spec.expect ? text.split(spec.expect).length - 1 : 0 };
    if (frames.length < 20000) frames.push(frame);
    watcherMs += performance.now() - startedAt;
  };
  terminal.onWriteParsed(readFrame);
  terminal.onRender?.(() => {
    if (renders.length < 20000) renders.push(now());
  });

  const timed = (name) => {
    const original = WebAssembly[name];
    if (typeof original !== 'function') return () => {};
    WebAssembly[name] = function (...args) {
      marks[`${name}StartAt`] ??= now();
      const result = original.apply(this, args);
      Promise.resolve(result).then(() => { marks[`${name}EndAt`] ??= now(); }, () => {});
      return result;
    };
    return () => { WebAssembly[name] = original; };
  };
  const restore = env.surface === 'native' ? [] : ['compileStreaming', 'compile', 'instantiate'].map(timed);
  const promising = WebAssembly.promising;
  if (env.surface !== 'native' && typeof promising === 'function') {
    WebAssembly.promising = function (target) {
      const wrapped = promising.call(this, target);
      return function (...args) {
        marks.startCallAt ??= now();
        return wrapped.apply(this, args);
      };
    };
    restore.push(() => { WebAssembly.promising = promising; });
  }

  const hostFetch = async (url, init = {}) => {
    const body = init.body ? (typeof init.body === 'string' ? init.body : new TextDecoder().decode(init.body)) : '';
    const record = { url: String(url).split('?')[0], method: init.method ?? 'GET', at: now(), requestBytes: new TextEncoder().encode(body).length, responseBytes: 0, chunks: 0 };
    const chat = body ? tools.describeChatBody(body) : null;
    if (chat) record.chat = chat;
    own.push(record);
    const headers = new Headers(init.headers);
    record.headerNames = [...headers.keys()].sort();
    if (env.key) headers.set('authorization', `Bearer ${env.key}`);
    let response;
    try {
      response = await env.fetch(url, { ...init, headers });
    } catch (error) {
      record.failed = String(error?.message ?? error).slice(0, 200);
      record.lastByteAt = now();
      throw error;
    }
    record.headersAt = now();
    record.status = response.status;
    if (!response.body) {
      record.lastByteAt = now();
      return response;
    }
    const readSse = String(response.headers.get('content-type')).includes('event-stream') ? tools.sseReader(record) : null;
    const reader = response.body.getReader();
    const stream = new ReadableStream({
      async pull(controller) {
        try {
          const { done, value } = await reader.read();
          if (done) {
            record.lastByteAt ??= now();
            record.endAt = now();
            controller.close();
            return;
          }
          record.firstByteAt ??= now();
          record.chunks += 1;
          record.responseBytes += value.length;
          readSse?.(value);
          record.lastByteAt = now();
          controller.enqueue(value);
        } catch (error) {
          if (error?.name === 'AbortError') record.cancelledAt = now();
          else record.failed = String(error?.message ?? error).slice(0, 200);
          controller.error(error);
        }
      },
      cancel(reason) {
        record.cancelledAt = now();
        return reader.cancel(reason);
      },
    });
    return new Response(stream, { status: response.status, statusText: response.statusText, headers: response.headers });
  };

  const adapter = env.adapter;
  const write = adapter.write.bind(adapter);
  adapter.write = (bytes) => {
    const at = now();
    marks.firstStdoutAt ??= at;
    if (stdout.length < 50000) stdout.push({ at, bytes: bytes.length });
    return write(bytes);
  };
  const promptHistoryStore = {
    load: (root, limit) => (limit > 0 ? (histories.get(root) ?? []).slice(-limit) : []),
    append(root, value) {
      const entries = histories.get(root) ?? [];
      histories.set(root, entries);
      if (entries.at(-1) === value) return 'duplicate';
      entries.push(value);
      return 'stored';
    },
    clear: (root) => { histories.delete(root); },
  };

  marks.createAt = now();
  const runtime = await env.create({
    terminal: adapter,
    env: {
      FX_CONFIGURED_PROVIDERS: JSON.stringify({ [spec.provider]: { protocol: 'openai-chat-completions', base_url: spec.baseUrl, auth: { type: 'none' }, model_metadata: { [spec.model]: spec.modelMetadata } } }),
      FX_PROVIDER: spec.provider,
      FX_MODEL: spec.model,
    },
    fetch: hostFetch,
    promptHistoryStore,
    onEvent: (event) => {
      if (event.type === 'terminal.size' && ticks.length < 100000) ticks.push(now());
    },
    stderr: (chunk) => {
      if (stderrText.length < 4000) stderrText += typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk);
    },
    ...(env.workspace ? { workspace: env.workspace.adapter } : {}),
  });
  marks.createdAt = now();
  let exitCode = null;
  runtime.exited.then((code) => { exitCode = code; });
  await Promise.race([runtime.interactive, pause(30000)]);
  marks.interactiveAt = now();
  const welcomeDeadline = now() + 30000;
  while (!frames.some((frame) => frame.welcome) && now() < welcomeDeadline && exitCode === null) await pause(5);
  marks.welcomeAt = frames.find((frame) => frame.welcome)?.at ?? null;
  for (const undo of restore) undo();
  await pause(spec.startSettleMs);
  const idleFrom = now() - spec.startSettleMs;
  const startup = {
    createToCompileStartMs: span(marks.createAt, marks.compileStreamingStartAt ?? marks.compileStartAt),
    compileMs: span(marks.compileStreamingStartAt ?? marks.compileStartAt, marks.compileStreamingEndAt ?? marks.compileEndAt),
    compileKind: marks.compileStreamingStartAt ? 'compileStreaming' : marks.compileStartAt ? 'compile' : null,
    instantiateMs: span(marks.instantiateStartAt, marks.instantiateEndAt),
    instantiateEndToStartCallMs: span(marks.instantiateEndAt, marks.startCallAt),
    startCallToFirstStdoutMs: span(marks.startCallAt, marks.firstStdoutAt),
    startCallToWelcomeMs: span(marks.startCallAt, marks.welcomeAt),
    createToStartCallMs: span(marks.createAt, marks.startCallAt),
    createToFirstStdoutMs: span(marks.createAt, marks.firstStdoutAt),
    createToWelcomeMs: span(marks.createAt, marks.welcomeAt),
    createToWelcomePaintMs: span(marks.createAt, renders.find((at) => at >= marks.welcomeAt)),
    createToInteractiveMs: span(marks.createAt, marks.interactiveAt),
    createToFirstTickMs: span(marks.createAt, ticks[0]),
    idleTicksPerSecond: round(ticks.filter((at) => at >= idleFrom).length / (spec.startSettleMs / 1000)),
    requestsBeforeFirstPrompt: requests().map((record) => `${record.method} ${record.url}`),
    createAt: marks.createAt,
    welcomeAt: marks.welcomeAt,
  };

  const ask = async (typed) => {
    const requestFloor = requests().length;
    const execFloor = env.workspace?.calls.length ?? 0;
    await env.type(typed, runtime);
    await pause(spec.typeSettleMs);
    const enterAt = await env.enter(runtime);
    const deadline = now() + spec.turnTimeoutMs;
    let final = null;
    let timedOut = true;
    while (now() < deadline && exitCode === null) {
      const chat = requests().slice(requestFloor).filter((record) => record.chat);
      final = chat.find((record) => record.lastByteAt && (record.endAt || record.cancelledAt || record.finishReason || env.surface === 'native') && (record.status !== 200 || (record.finishReason && record.finishReason !== 'tool_calls'))) ?? null;
      if (final) {
        const idleFrame = frames.findLast((frame) => frame.at > final.lastByteAt && !frame.working);
        const tick = env.surface === 'native' ? true : ticks.findLast((at) => at > final.lastByteAt);
        if (idleFrame && tick && frames.at(-1) === idleFrame) {
          timedOut = false;
          break;
        }
      }
      await pause(10);
    }
    const settleFrom = now();
    await pause(spec.settleMs);
    const settleTo = now();
    const window = requests().slice(requestFloor);
    const chat = window.filter((record) => record.chat);
    const lastByteAt = final?.lastByteAt ?? chat.at(-1)?.lastByteAt ?? null;
    const versionAt = (at) => frames.findLast((frame) => frame.at <= at)?.version ?? 0;
    const changeAfter = (at) => {
      if (typeof at !== 'number') return null;
      const base = versionAt(at);
      return frames.find((frame) => frame.at > at && frame.version > base)?.at ?? null;
    };
    const paintAfter = (at) => (typeof at === 'number' ? renders.find((render) => render >= at) ?? null : null);
    const readyFrame = typeof lastByteAt === 'number' ? frames.find((frame) => frame.at > lastByteAt && !frame.working) : null;
    const readyTick = typeof lastByteAt === 'number' ? ticks.find((at) => at > lastByteAt) ?? null : null;
    const endAt = readyFrame?.at ?? settleFrom;
    let lastVisible = null;
    for (let index = 1; index < frames.length; index++) {
      const frame = frames[index];
      if (frame.at <= enterAt || frame.at > endAt + 200) continue;
      if (frame.version > frames[index - 1].version) lastVisible = frame.at;
    }
    const exec = (env.workspace?.calls ?? []).slice(execFloor);
    const turns = chat.map((record, index) => {
      const visibleAt = changeAfter(record.firstByteAt);
      const before = chat[index - 1];
      const call = before ? exec.find((entry) => entry.startAt >= before.lastByteAt && entry.startAt <= record.at) : null;
      return {
        status: record.status ?? null,
        failed: record.failed ?? null,
        requestBytes: record.requestBytes,
        systemBytes: record.chat.systemBytes,
        systemMessages: record.chat.systemMessages,
        toolsBytes: record.chat.toolsBytes,
        conversationBytes: record.chat.conversationBytes,
        messageCount: record.chat.messageCount,
        toolNames: record.chat.toolNames,
        otherKeys: record.chat.otherKeys,
        maxTokens: record.chat.maxTokens,
        headerNames: record.headerNames ?? [],
        sinceEnterMs: span(enterAt, record.at),
        ttfbMs: span(record.at, record.headersAt),
        headersToFirstByteMs: span(record.headersAt, record.firstByteAt),
        headersToFirstContentMs: span(record.headersAt, record.firstContentAt),
        streamMs: span(record.firstContentAt ?? record.firstByteAt, record.lastByteAt),
        lastByteToStreamEndMs: span(record.lastByteAt, record.endAt),
        contentToStdoutMs: span(record.firstContentAt, stdout.find((entry) => entry.at >= record.firstByteAt)?.at),
        contentToVisibleMs: span(record.firstContentAt, visibleAt),
        contentToPaintMs: span(record.firstContentAt, paintAfter(visibleAt)),
        afterPreviousTurnMs: before ? span(before.lastByteAt, record.at) : null,
        previousToToolStartMs: call ? span(before.lastByteAt, call.startAt) : null,
        toolMs: call ? span(call.startAt, call.endAt) : null,
        toolEndToRequestMs: call ? span(call.endAt, record.at) : null,
        responseBytes: record.responseBytes,
        chunks: record.chunks ?? null,
        frames: record.frames ?? null,
        textChars: record.textChars ?? null,
        toolCalls: record.toolCalls ?? null,
        finishReason: record.finishReason ?? null,
        usage: record.usage ?? null,
        error: record.error ?? null,
        at: record.at,
        lastByteAt: record.lastByteAt ?? null,
      };
    });
    const first = chat[0];
    const firstVisibleAt = changeAfter(first?.firstByteAt);
    const streamed = chat.find((record) => (record.arrivals?.length ?? 0) >= 20);
    let paced = null;
    if (streamed) {
      const base = frames.findLast((frame) => frame.at <= streamed.firstByteAt)?.groups ?? 0;
      const lags = [];
      for (const arrival of streamed.arrivals) {
        const shown = frames.find((frame) => frame.at >= arrival.at && frame.groups - base >= arrival.groups);
        if (shown) lags.push(shown.at - arrival.at);
      }
      lags.sort((left, right) => left - right);
      const inStream = (at) => at >= streamed.firstByteAt && at <= streamed.lastByteAt + 100;
      const streamFrames = frames.filter((frame) => inStream(frame.at));
      const changed = streamFrames.filter((frame, index) => index > 0 && frame.version > streamFrames[index - 1].version);
      paced = {
        deltas: streamed.arrivals.length,
        matched: lags.length,
        lagMedianMs: round(lags[Math.floor(lags.length / 2)]),
        lagP90Ms: round(lags[Math.floor(lags.length * 0.9)]),
        lagMaxMs: round(lags.at(-1)),
        arrivalSpanMs: span(streamed.arrivals[0].at, streamed.arrivals.at(-1).at),
        visibleSpanMs: span(changed[0]?.at, changed.at(-1)?.at),
        stdoutWrites: stdout.filter((entry) => inStream(entry.at)).length,
        gridFrames: streamFrames.length,
        changedFrames: changed.length,
        renders: renders.filter(inStream).length,
      };
    }
    const during = (at) => at >= enterAt && at <= endAt;
    const settled = (at) => at >= settleFrom && at <= settleTo;
    return {
      typed,
      timedOut,
      enterAt,
      endAt,
      modelTurns: chat.filter((record) => record.status === 200).length,
      toolCalls: chat.reduce((total, record) => total + (record.toolCalls ?? 0), 0),
      hostRequests: window.map((record) => `${record.method} ${record.url.split('/').slice(-2).join('/')} ${record.status ?? record.failed ?? 'pending'}`),
      exec: exec.map((call) => ({ command: call.command, exitCode: call.exitCode, ms: span(call.startAt, call.endAt) })),
      timeline: {
        enterToFirstRequestMs: span(enterAt, first?.at),
        enterToHeadersMs: span(enterAt, first?.headersAt),
        enterToFirstByteMs: span(enterAt, first?.firstByteAt),
        enterToFirstContentMs: span(enterAt, first?.firstContentAt),
        enterToFirstVisibleMs: span(enterAt, firstVisibleAt),
        enterToFirstPaintMs: span(enterAt, paintAfter(firstVisibleAt)),
        enterToEchoMs: span(enterAt, changeAfter(enterAt)),
        enterToLastByteMs: span(enterAt, lastByteAt),
        enterToLastVisibleMs: span(enterAt, lastVisible),
        enterToReadyFrameMs: span(enterAt, readyFrame?.at),
        enterToReadyPaintMs: span(enterAt, paintAfter(readyFrame?.at)),
        enterToReadyTickMs: span(enterAt, readyTick),
        lastByteToLastVisibleMs: span(lastByteAt, lastVisible),
        lastByteToReadyFrameMs: span(lastByteAt, readyFrame?.at),
        lastByteToReadyTickMs: span(lastByteAt, readyTick),
      },
      render: {
        stdoutWrites: stdout.filter((entry) => during(entry.at)).length,
        stdoutBytes: stdout.filter((entry) => during(entry.at)).reduce((total, entry) => total + entry.bytes, 0),
        gridFrames: frames.filter((frame) => during(frame.at)).length,
        renders: renders.filter(during).length,
        ticksDuringTurn: ticks.filter((at) => at > enterAt + 50 && at < (lastByteAt ?? enterAt)).length,
        idleTicksPerSecond: round(ticks.filter(settled).length / ((settleTo - settleFrom) / 1000)),
        idleStdoutWrites: stdout.filter((entry) => settled(entry.at)).length,
      },
      turns,
      paced,
      replySeen: spec.expect ? (frames.at(-1)?.expect ?? 0) > (frames.findLast((frame) => frame.at <= enterAt)?.expect ?? 0) : null,
    };
  };

  const asks = [];
  for (const typed of spec.prompts) {
    if (exitCode !== null) break;
    asks.push(await ask(typed));
  }
  const tail = [];
  const buffer = terminal.buffer.active;
  for (let row = Math.max(0, buffer.length - 14); row < buffer.length; row++) tail.push(buffer.getLine(row)?.translateToString(true) ?? '');
  runtime.write('/exit\r');
  await Promise.race([runtime.exited, pause(5000)]);
  runtime.abort?.();
  return { surface: env.surface, startup, asks, exitCode, watcherMs: round(watcherMs), gridFrames: frames.length, stderr: stderrText.slice(0, 1000), screenTail: tail.join('\n').replace(/\n+$/, '').slice(-900), userAgent: globalThis.navigator?.userAgent ?? null };
};

const startLoggingProxy = async (target) => {
  const upstream = new URL(target);
  const tools = netTools();
  const records = [];
  const server = createServer((req, res) => {
    const record = { seq: records.length, method: req.method, url: req.url, path: req.url, client: req.headers.origin ? 'browser' : 'native', at: epoch(), requestBytes: 0, responseBytes: 0, chunks: 0 };
    records.push(record);
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      record.requestBytes = body.length;
      record.requestEndAt = epoch();
      const chat = body.length ? tools.describeChatBody(body.toString('utf8')) : null;
      if (chat) record.chat = chat;
      record.headerNames = Object.keys(req.headers).sort();
      const headers = Object.fromEntries(Object.entries(req.headers).filter(([name]) => FORWARDED_HEADERS.has(name) || name.startsWith('access-control-request-')));
      if (body.length > 0 || req.method === 'POST') headers['content-length'] = String(body.length);
      const forward = httpRequest({ hostname: upstream.hostname, port: upstream.port, path: req.url, method: req.method, headers }, (upstreamResponse) => {
        record.status = upstreamResponse.statusCode;
        record.headersAt = epoch();
        record.contentType = upstreamResponse.headers['content-type'] ?? null;
        res.writeHead(upstreamResponse.statusCode, upstreamResponse.headers);
        res.flushHeaders();
        const readSse = String(record.contentType).includes('event-stream') ? tools.sseReader(record) : null;
        upstreamResponse.on('data', (chunk) => {
          record.firstByteAt ??= epoch();
          record.chunks += 1;
          record.responseBytes += chunk.length;
          readSse?.(chunk);
          record.lastByteAt = epoch();
          res.write(chunk);
        });
        upstreamResponse.on('end', () => {
          record.lastByteAt ??= epoch();
          record.endAt = epoch();
          res.end();
        });
      });
      forward.on('error', (error) => {
        record.proxyError = error.message;
        record.lastByteAt = epoch();
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
    window: (from, to) => records.filter((record) => record.at >= from && record.at <= to),
    close: () => new Promise((ok) => {
      server.closeAllConnections();
      server.close(ok);
    }),
  };
};

const startPacedModel = async ({ count, intervalMs, firstDelayMs }) => {
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': 'authorization, content-type, accept', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'access-control-max-age': '600' };
  const frame = (delta, finish) => `data: ${JSON.stringify({ id: 'paced', object: 'chat.completion.chunk', created: 0, model: MODEL, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  const server = createServer((req, res) => {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, cors);
      res.end();
      return;
    }
    req.resume();
    req.on('end', async () => {
      if (req.method !== 'POST') {
        res.writeHead(200, { ...cors, 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [{ id: MODEL, object: 'model' }] }));
        return;
      }
      res.writeHead(200, { ...cors, 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      res.flushHeaders();
      await sleep(firstDelayMs);
      res.write(frame({ role: 'assistant', content: '' }, null));
      for (let value = 1; value <= count && !res.destroyed; value++) {
        res.write(frame({ content: `${value}\n` }, null));
        await sleep(intervalMs);
      }
      res.write(frame({}, 'stop'));
      res.write(`data: ${JSON.stringify({ id: 'paced', object: 'chat.completion.chunk', created: 0, model: MODEL, choices: [], usage: { prompt_tokens: 10, completion_tokens: count, total_tokens: count + 10 } })}\n\n`);
      res.end('data: [DONE]\n\n');
    });
  });
  await new Promise((ok, fail) => {
    server.once('error', fail);
    server.listen(0, '127.0.0.1', ok);
  });
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((ok) => {
      server.closeAllConnections();
      server.close(ok);
    }),
  };
};

const pageHtml = () => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>fx terminal probe</title>
<link rel="stylesheet" href="/xterm/xterm.css">
<style>html, body, #terminal { width: 100%; height: 100%; margin: 0; background: #111; }</style>
</head>
<body>
<div id="terminal"></div>
<script type="module">
import { Terminal } from '/xterm/xterm.mjs';
import { createFxTerminal } from '/sdk/browser-terminal.js';
import { xtermAdapter } from '/sdk/xterm.js';
const { spec, key } = window.__termProbe;
const now = () => performance.timeOrigin + performance.now();
const terminal = new Terminal({ cols: spec.cols, rows: spec.rows, allowProposedApi: true, scrollback: 3000 });
terminal.open(document.querySelector('#terminal'));
terminal.focus();
const moduleReadyAt = now();
const host = (request) => new Promise((resolve) => {
  window.__termProbeAck = resolve;
  window.termProbeInput(JSON.stringify(request));
});
const session = (${runSession})({
  surface: 'browser',
  spec,
  key,
  terminal,
  adapter: xtermAdapter(terminal),
  tools: (${netTools})(),
  workspace: spec.workspace ? (${probeWorkspace})() : undefined,
  fetch: (url, init) => fetch(url, init),
  create: (options) => createFxTerminal({ ...options, wasm: spec.wasm }),
  type: (text) => host({ kind: 'type', text }),
  enter: () => new Promise((resolve) => {
    const listener = (event) => {
      if (event.key !== 'Enter') return;
      removeEventListener('keydown', listener, true);
      resolve(now());
    };
    addEventListener('keydown', listener, true);
    host({ kind: 'enter' });
  }),
});
window.__termProbeDone = session.then((result) => {
  const navigation = performance.getEntriesByType('navigation')[0];
  const wasm = performance.getEntriesByType('resource').find((entry) => entry.name.endsWith('.wasm'));
  return JSON.stringify({
    ...result,
    page: {
      navigationStartAt: performance.timeOrigin,
      moduleReadyAt,
      resources: performance.getEntriesByType('resource').length,
      domContentLoadedMs: navigation?.domContentLoadedEventEnd ?? null,
      wasm: wasm ? { startAt: performance.timeOrigin + wasm.startTime, fetchMs: wasm.responseEnd - wasm.startTime, transferBytes: wasm.transferSize, encodedBytes: wasm.encodedBodySize, decodedBytes: wasm.decodedBodySize } : null,
    },
  });
}, (error) => JSON.stringify({ failed: String(error?.stack ?? error) }));
</script>
</body>
</html>
`;

const startStaticServer = async ({ wasm, xterm }) => {
  const records = [];
  const roots = [
    { prefix: '/sdk/', directory: join(REPO, 'sdk') },
    { prefix: '/xterm/', directory: xterm },
  ];
  const html = Buffer.from(pageHtml());
  const server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname);
    const record = { path, at: epoch(), status: 200, bytes: 0 };
    records.push(record);
    const finish = (status, headers, body) => {
      record.status = status;
      record.bytes = body?.length ?? 0;
      res.writeHead(status, headers);
      res.end(body);
    };
    if (path === '/term-probe.html') return finish(200, { 'content-type': MIME['.html'], 'cache-control': 'no-store' }, html);
    const root = roots.find((entry) => path.startsWith(entry.prefix));
    const file = path === '/fx-term.wasm' ? wasm : root ? resolve(root.directory, path.slice(root.prefix.length)) : null;
    if (!file || (root && !file.startsWith(root.directory + sep)) || !existsSync(file) || !statSync(file).isFile()) return finish(404, { 'content-type': 'text/plain' }, Buffer.from('not found'));
    const stat = statSync(file);
    const etag = `"${stat.size}-${Math.round(stat.mtimeMs)}"`;
    const headers = { 'content-type': MIME[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-cache', etag };
    if (req.headers['if-none-match'] === etag) return finish(304, headers, null);
    return finish(200, headers, readFileSync(file));
  });
  await new Promise((ok, fail) => {
    server.once('error', fail);
    server.listen(0, '127.0.0.1', ok);
  });
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    records,
    close: () => new Promise((ok) => {
      server.closeAllConnections();
      server.close(ok);
    }),
  };
};

const children = new Set();
const markers = new Set();

const processTable = () => {
  const table = new Map();
  for (const entry of readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = readFileSync(`/proc/${entry}/stat`, 'utf8');
      table.set(Number(entry), Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]));
    } catch {
      continue;
    }
  }
  return table;
};

const killTree = (root) => {
  const parents = processTable();
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

const killMarked = (marker) => {
  const killed = [];
  for (const pid of processTable().keys()) {
    if (pid === process.pid) continue;
    try {
      if (!readFileSync(`/proc/${pid}/cmdline`, 'utf8').includes(marker)) continue;
      process.kill(pid, 'SIGKILL');
      killed.push(pid);
    } catch {
      continue;
    }
  }
  return killed;
};

process.on('exit', () => {
  for (const pid of children) killTree(pid);
  for (const marker of markers) killMarked(marker);
});
for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) process.on(signal, () => process.exit(code));

const startChromium = async (chrome) => {
  const profile = mkdtempSync(join(tmpdir(), 'fx-term-probe-profile-'));
  markers.add(profile);
  const child = spawn(chrome, ['--headless', '--no-sandbox', '--disable-gpu', '--disable-breakpad', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--window-size=1280,900', 'about:blank'], { stdio: 'ignore' });
  children.add(child.pid);
  const stop = async () => {
    killTree(child.pid);
    children.delete(child.pid);
    await sleep(100);
    killMarked(profile);
    markers.delete(profile);
    rmSync(profile, { recursive: true, force: true });
  };
  try {
    const portFile = join(profile, 'DevToolsActivePort');
    const deadline = Date.now() + 30000;
    while (!existsSync(portFile) || readFileSync(portFile, 'utf8').split('\n').length < 2) {
      if (Date.now() > deadline) throw new Error('Chromium did not open its debugging port');
      await sleep(50);
    }
    const [port, path] = readFileSync(portFile, 'utf8').trim().split('\n');
    const socket = new WebSocket(`ws://127.0.0.1:${port}${path}`);
    await new Promise((ok, fail) => {
      socket.addEventListener('open', ok, { once: true });
      socket.addEventListener('error', () => fail(new Error('the Chromium debugging socket did not open')), { once: true });
    });
    const pending = new Map();
    const listeners = new Set();
    let counter = 0;
    socket.addEventListener('message', ({ data }) => {
      const message = JSON.parse(data);
      if (message.id === undefined) {
        for (const listener of listeners) listener(message);
        return;
      }
      const waiter = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) waiter?.fail(new Error(`${waiter.method}: ${message.error.message}`));
      else waiter?.ok(message.result);
    });
    const send = (method, params = {}, sessionId) => new Promise((ok, fail) => {
      const id = ++counter;
      pending.set(id, { ok, fail, method });
      socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
    return {
      send,
      listen: (listener) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      close: async () => {
        socket.close();
        await stop();
      },
    };
  } catch (error) {
    await stop();
    throw error;
  }
};

const deadlineFor = (promise, ms, label) => {
  let timer;
  return Promise.race([promise, new Promise((_, fail) => { timer = setTimeout(() => fail(new Error(`${label} did not finish within ${ms} ms`)), ms); })]).finally(() => clearTimeout(timer));
};

const browserSession = async ({ chromium, site, spec, key }) => {
  const { send } = chromium;
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const logs = [];
  const stopListening = chromium.listen((message) => {
    if (message.sessionId !== sessionId) return;
    if (message.method === 'Runtime.exceptionThrown') logs.push(String(message.params.exceptionDetails?.exception?.description ?? message.params.exceptionDetails?.text).slice(0, 400));
    if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') logs.push(String(message.params.entry.text).slice(0, 400));
    if (message.method !== 'Runtime.bindingCalled' || message.params.name !== 'termProbeInput') return;
    const request = JSON.parse(message.params.payload);
    const act = request.kind === 'type'
      ? send('Input.insertText', { text: request.text }, sessionId)
      : send('Input.dispatchKeyEvent', { type: 'keyDown', ...KEY_ENTER, text: '\r' }, sessionId).then(() => send('Input.dispatchKeyEvent', { type: 'keyUp', ...KEY_ENTER }, sessionId));
    act.then(() => send('Runtime.evaluate', { expression: 'window.__termProbeAck()' }, sessionId)).catch((error) => logs.push(`input: ${error.message}`));
  });
  try {
    await send('Page.enable', {}, sessionId);
    await send('Runtime.enable', {}, sessionId);
    await send('Log.enable', {}, sessionId);
    await send('Runtime.addBinding', { name: 'termProbeInput' }, sessionId);
    await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.__termProbe = ${JSON.stringify({ spec, key })};` }, sessionId);
    const navigatedAt = epoch();
    await send('Page.navigate', { url: `${site.url}/term-probe.html` }, sessionId);
    const evaluate = async (expression, awaitPromise = false) => (await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise }, sessionId)).result?.value;
    const loadDeadline = Date.now() + 60000;
    while (!(await evaluate("typeof window.__termProbeDone === 'object'"))) {
      if (Date.now() > loadDeadline) throw new Error(`the probe page did not start: ${logs.join(' | ')}`);
      await sleep(50);
    }
    const result = JSON.parse(await deadlineFor(evaluate('window.__termProbeDone', true), SESSION_TIMEOUT_MS, 'the browser session'));
    if (result.failed) throw new Error(`the browser session failed: ${result.failed} ${logs.join(' | ')}`);
    return { ...result, navigatedAt, logs };
  } finally {
    stopListening();
    await send('Target.closeTarget', { targetId }).catch(() => {});
  }
};

const nodeSession = ({ spec, key }) => new Promise((done, fail) => {
  const child = spawn(process.execPath, ['--experimental-wasm-jspi', fileURLToPath(import.meta.url), '--session'], { env: { ...process.env, FX_TERM_PROBE_SPEC: JSON.stringify(spec), FX_TERM_PROBE_KEY: key }, stdio: ['ignore', 'pipe', 'pipe'] });
  children.add(child.pid);
  const spawnedAt = epoch();
  let stdout = '';
  let stderr = '';
  const timer = setTimeout(() => killTree(child.pid), SESSION_TIMEOUT_MS);
  child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
  child.stderr.on('data', (chunk) => { if (stderr.length < 4000) stderr += chunk.toString('utf8'); });
  child.on('close', (code) => {
    clearTimeout(timer);
    children.delete(child.pid);
    const line = stdout.split('\n').findLast((entry) => entry.startsWith('{'));
    if (!line) return fail(new Error(`the node session exited with ${code}: ${stderr.slice(0, 1500)}`));
    return done({ ...JSON.parse(line), spawnedAt, childStderr: stderr.slice(0, 500) });
  });
});

const runNodeChild = async () => {
  const spec = JSON.parse(process.env.FX_TERM_PROBE_SPEC);
  const key = process.env.FX_TERM_PROBE_KEY;
  const processStartAt = performance.timeOrigin;
  const { Terminal } = createRequire(join(REPO, 'sdk', 'node', 'package.json'))('@xterm/headless');
  const { createFxTerminal, xtermAdapter } = await import(pathToFileURL(join(REPO, 'sdk', 'node.js')).href);
  const importedAt = epoch();
  const terminal = new Terminal({ cols: spec.cols, rows: spec.rows, allowProposedApi: true, scrollback: 3000 });
  const result = await runSession({
    surface: 'node',
    spec,
    key,
    terminal,
    adapter: xtermAdapter(terminal),
    tools: netTools(),
    workspace: spec.workspace ? probeWorkspace() : undefined,
    fetch: (url, init) => fetch(url, init),
    create: (options) => createFxTerminal({ ...options, backend: 'wasm', wasm: spec.wasm }),
    type: (text, runtime) => runtime.write(text),
    enter: (runtime) => {
      const at = epoch();
      runtime.write('\r');
      return at;
    },
  });
  process.stdout.write(`${JSON.stringify({ ...result, process: { startAt: processStartAt, importMs: span(processStartAt, importedAt) } })}\n`);
};

const nativeSession = async ({ bin, spec, key, proxy }) => {
  const { Terminal } = createRequire(join(REPO, 'sdk', 'node', 'package.json'))('@xterm/headless');
  const realSettings = JSON.parse(readFileSync('/config/.fx/settings.json', 'utf8'));
  const home = mkdtempSync(join(tmpdir(), 'fx-term-probe-home-'));
  const cwd = mkdtempSync(join(tmpdir(), 'fx-term-probe-cwd-'));
  writeFileSync(join(home, 'settings.json'), JSON.stringify({
    providers: { [PROVIDER]: { protocol: 'openai-chat-completions', base_url: spec.baseUrl, auth: { type: 'bearer', env: 'FX_TERM_PROBE_KEY' }, model_metadata: realSettings.providers?.gy4?.model_metadata ?? { [MODEL]: MODEL_METADATA } } },
    models: { [PROVIDER]: MODEL },
    provider: PROVIDER,
    permission_mode: 'yolo',
    yolo_acknowledged: true,
  }, null, 1));
  const terminal = new Terminal({ cols: spec.cols, rows: spec.rows, allowProposedApi: true, scrollback: 3000 });
  const startedAt = epoch();
  let child = null;
  try {
    return await deadlineFor(runSession({
      surface: 'native',
      spec,
      key: null,
      terminal,
      adapter: { write: (bytes) => terminal.write(bytes) },
      tools: netTools(),
      requests: () => proxy.records.filter((record) => record.at >= startedAt && record.method !== 'OPTIONS'),
      create: async ({ terminal: sink }) => {
        child = spawn('script', ['-qfc', `stty rows ${spec.rows} cols ${spec.cols}; exec '${bin}'`, '/dev/null'], { cwd, env: { ...process.env, FX_HOME: home, FX_TERM_PROBE_KEY: key, TERM: 'xterm-256color' }, stdio: ['pipe', 'pipe', 'ignore'] });
        children.add(child.pid);
        child.stdout.on('data', (chunk) => sink.write(chunk));
        child.stdin.on('error', () => {});
        terminal.onData((data) => child.stdin.write(data));
        const exited = new Promise((ok) => child.on('close', (code) => ok(code)));
        return { interactive: Promise.resolve(), exited, write: (data) => child.stdin.write(data), abort: () => {} };
      },
      type: (text, runtime) => runtime.write(text),
      enter: (runtime) => {
        const at = epoch();
        runtime.write('\r');
        return at;
      },
    }), SESSION_TIMEOUT_MS, 'the native session');
  } finally {
    if (child) {
      killTree(child.pid);
      children.delete(child.pid);
    }
    rmSync(home, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  }
};

const classify = (record) => {
  if (record.method === 'OPTIONS') return 'cors-preflight';
  if (record.url.endsWith('/chat/completions')) return 'chat';
  if (record.url.endsWith('/models')) return 'models';
  return 'other';
};

const flatten = ({ session, ask, index, proxy, site, condition, prompt }) => {
  const proxied = proxy.window(ask.enterAt - 5, ask.endAt + 300);
  const byClass = {};
  for (const record of proxied) byClass[classify(record)] = (byClass[classify(record)] ?? 0) + 1;
  const wasmFetches = index === 0 && site ? site.records.filter((record) => record.path.endsWith('.wasm') && record.at >= session.navigatedAt).length : 0;
  if (wasmFetches) byClass.wasm = wasmFetches;
  const proxyChat = proxied.filter((record) => record.chat);
  const turn = (position) => ask.turns[position] ?? {};
  const last = ask.turns.at(-1) ?? {};
  const second = ask.turns.length > 1 ? last : {};
  const cold = index === 0;
  const startup = session.startup;
  return {
    surface: session.surface,
    prompt: prompt.id,
    condition,
    typed: ask.typed,
    timedOut: ask.timedOut,
    replySeen: ask.replySeen,
    hostRequests: ask.hostRequests,
    httpByClass: byClass,
    exec: ask.exec,
    finishReasons: ask.turns.map((entry) => entry.finishReason),
    toolNames: turn(0).toolNames ?? [],
    usage: ask.turns.map((entry) => entry.usage),
    errors: ask.turns.map((entry) => entry.error ?? entry.failed).filter(Boolean),
    metrics: {
      modelTurns: ask.modelTurns,
      toolCalls: ask.toolCalls,
      httpRequests: proxied.length + wasmFetches,
      enterToEchoMs: ask.timeline.enterToEchoMs,
      enterToFirstRequestMs: ask.timeline.enterToFirstRequestMs,
      enterToFirstByteMs: ask.timeline.enterToFirstByteMs,
      enterToFirstContentMs: ask.timeline.enterToFirstContentMs,
      enterToFirstVisibleMs: ask.timeline.enterToFirstVisibleMs,
      enterToFirstPaintMs: ask.timeline.enterToFirstPaintMs,
      enterToLastByteMs: ask.timeline.enterToLastByteMs,
      enterToLastVisibleMs: ask.timeline.enterToLastVisibleMs,
      enterToReadyFrameMs: ask.timeline.enterToReadyFrameMs,
      enterToReadyPaintMs: ask.timeline.enterToReadyPaintMs,
      enterToReadyTickMs: ask.timeline.enterToReadyTickMs,
      lastByteToLastVisibleMs: ask.timeline.lastByteToLastVisibleMs,
      lastByteToReadyFrameMs: ask.timeline.lastByteToReadyFrameMs,
      lastByteToReadyTickMs: ask.timeline.lastByteToReadyTickMs,
      turn1TtfbMs: turn(0).ttfbMs,
      turn1ProxyTtfbMs: span(proxyChat[0]?.at, proxyChat[0]?.headersAt),
      turn1ClientOverheadMs: typeof turn(0).ttfbMs === 'number' && proxyChat[0]?.headersAt ? round(turn(0).ttfbMs - (proxyChat[0].headersAt - proxyChat[0].at)) : null,
      turn1HeadersToFirstContentMs: turn(0).headersToFirstContentMs,
      turn1StreamMs: turn(0).streamMs,
      turn1ContentToStdoutMs: turn(0).contentToStdoutMs,
      turn1ContentToVisibleMs: turn(0).contentToVisibleMs,
      turn1ContentToPaintMs: turn(0).contentToPaintMs,
      turn1SseChunks: turn(0).chunks,
      turn1SseFrames: turn(0).frames,
      lastTurnToolStartMs: second.previousToToolStartMs,
      lastTurnToolMs: second.toolMs,
      lastTurnToolEndToRequestMs: second.toolEndToRequestMs,
      lastTurnAfterPreviousMs: second.afterPreviousTurnMs,
      lastTurnTtfbMs: second.ttfbMs,
      lastTurnHeadersToFirstContentMs: second.headersToFirstContentMs,
      lastTurnStreamMs: second.streamMs,
      lastTurnContentToVisibleMs: second.contentToVisibleMs,
      lastTurnTextChars: last.textChars,
      turn1RequestBytes: turn(0).requestBytes,
      turn1SystemBytes: turn(0).systemBytes,
      turn1SystemMessages: turn(0).systemMessages,
      turn1ToolsBytes: turn(0).toolsBytes,
      turn1ConversationBytes: turn(0).conversationBytes,
      lastTurnRequestBytes: last.requestBytes,
      stdoutWrites: ask.render.stdoutWrites,
      stdoutBytes: ask.render.stdoutBytes,
      gridFrames: ask.render.gridFrames,
      renders: ask.render.renders,
      ticksDuringTurn: ask.render.ticksDuringTurn,
      idleTicksPerSecond: ask.render.idleTicksPerSecond,
      pacedLagMedianMs: ask.paced?.lagMedianMs,
      pacedLagP90Ms: ask.paced?.lagP90Ms,
      pacedLagMaxMs: ask.paced?.lagMaxMs,
      pacedDeltas: ask.paced?.deltas,
      pacedMatched: ask.paced?.matched,
      pacedArrivalSpanMs: ask.paced?.arrivalSpanMs,
      pacedVisibleSpanMs: ask.paced?.visibleSpanMs,
      pacedStdoutWrites: ask.paced?.stdoutWrites,
      pacedChangedFrames: ask.paced?.changedFrames,
      pacedRenders: ask.paced?.renders,
      startupProcessImportMs: cold ? session.process?.importMs : undefined,
      startupPageLoadMs: cold && session.page ? span(session.navigatedAt, session.page.moduleReadyAt) : undefined,
      startupWasmFetchMs: cold ? round(session.page?.wasm?.fetchMs) ?? undefined : undefined,
      startupWasmTransferBytes: cold ? session.page?.wasm?.transferBytes : undefined,
      startupCreateToCompileStartMs: cold ? startup.createToCompileStartMs : undefined,
      startupCompileMs: cold ? startup.compileMs : undefined,
      startupInstantiateMs: cold ? startup.instantiateMs : undefined,
      startupCreateToStartCallMs: cold ? startup.createToStartCallMs : undefined,
      startupStartCallToFirstStdoutMs: cold ? startup.startCallToFirstStdoutMs : undefined,
      startupStartCallToWelcomeMs: cold ? startup.startCallToWelcomeMs : undefined,
      startupCreateToWelcomeMs: cold ? startup.createToWelcomeMs : undefined,
      startupCreateToWelcomePaintMs: cold ? startup.createToWelcomePaintMs : undefined,
      startupCreateToInteractiveMs: cold ? startup.createToInteractiveMs : undefined,
      startupIdleTicksPerSecond: cold ? startup.idleTicksPerSecond : undefined,
      startupRequests: cold ? startup.requestsBeforeFirstPrompt.length : undefined,
      watcherMs: cold ? session.watcherMs : undefined,
      load: loadAverage(),
    },
    turns: ask.turns,
    paced: ask.paced,
    startup: cold ? { ...startup, page: session.page ?? null, process: session.process ?? null, compileKind: startup.compileKind } : undefined,
    screenTail: index === session.asks.length - 1 ? session.screenTail : undefined,
  };
};

const stats = (values) => {
  const numbers = values.filter((value) => typeof value === 'number' && Number.isFinite(value)).sort((left, right) => left - right);
  if (numbers.length === 0) return null;
  const middle = Math.floor(numbers.length / 2);
  const median = numbers.length % 2 ? numbers[middle] : (numbers[middle - 1] + numbers[middle]) / 2;
  return { n: numbers.length, median: round(median), min: round(numbers[0]), max: round(numbers.at(-1)) };
};

const show = (value) => (value ? `${value.median} [${value.min}..${value.max}] n=${value.n}` : 'n/a');

const summarise = (results) => {
  const groups = new Map();
  for (const result of results) {
    const key = `${result.prompt} | ${result.surface} | ${result.condition}`;
    groups.set(key, [...(groups.get(key) ?? []), result]);
  }
  const summary = {};
  for (const [key, rows] of groups) {
    const names = [...new Set(rows.flatMap((row) => Object.keys(row.metrics)))];
    const distinct = (read) => rows.map(read).map((value) => JSON.stringify(value)).filter((value, index, all) => all.indexOf(value) === index);
    summary[key] = {
      runs: rows.length,
      timedOut: rows.filter((row) => row.timedOut).length,
      replySeen: rows.filter((row) => row.replySeen).length,
      httpByClass: distinct((row) => row.httpByClass),
      hostRequests: distinct((row) => row.hostRequests),
      finishReasons: distinct((row) => row.finishReasons),
      exec: distinct((row) => row.exec.map((call) => `${call.command} -> ${call.exitCode}`)),
      toolNames: distinct((row) => row.toolNames),
      errors: distinct((row) => row.errors),
      metrics: Object.fromEntries(names.map((name) => [name, stats(rows.map((row) => row.metrics[name]))]).filter(([, value]) => value)),
    };
  }
  return summary;
};

const printSummary = (summary) => {
  for (const [key, row] of Object.entries(summary)) {
    console.log(`\n== ${key} (runs ${row.runs}, timed out ${row.timedOut}, reply seen ${row.replySeen}) ==`);
    for (const name of ['httpByClass', 'hostRequests', 'finishReasons', 'exec', 'toolNames', 'errors']) console.log(`  ${name}: ${row[name].join(' ; ')}`);
    for (const [name, value] of Object.entries(row.metrics)) console.log(`  ${name}: ${show(value)}`);
  }
};

const main = async () => {
  const options = parseArgs(process.argv.slice(2));
  if (options.session) return runNodeChild();
  const key = liveKey();
  const chrome = process.env.CHROME_BIN ?? '/usr/bin/chromium-browser';
  const prompts = PROMPTS.filter((prompt) => !options.onlyPrompt || prompt.id === options.onlyPrompt);
  const surfaces = {
    node: !options.skip.has('node') && existsSync(options.wasm),
    browser: !options.skip.has('browser') && existsSync(options.wasm) && existsSync(chrome) && existsSync(join(options.xterm, 'xterm.mjs')),
    native: !options.skip.has('native') && existsSync(options.native),
  };
  const shimProxy = await startLoggingProxy(options.shim);
  const pacedModel = await startPacedModel(PACED);
  const pacedProxy = await startLoggingProxy(pacedModel.url);
  const site = await startStaticServer({ wasm: options.wasm, xterm: options.xterm });
  const results = [];
  const failures = [];
  const started = new Date().toISOString();
  const specFor = (prompt, wasm) => ({
    prompts: [prompt.typed, prompt.typed],
    expect: prompt.expect,
    workspace: prompt.workspace,
    provider: PROVIDER,
    model: MODEL,
    modelMetadata: MODEL_METADATA,
    baseUrl: `${(prompt.route === 'paced' ? pacedProxy : shimProxy).url}/v1`,
    wasm,
    cols: 100,
    rows: 34,
    startSettleMs: 1000,
    typeSettleMs: 250,
    settleMs: 1500,
    turnTimeoutMs: 180000,
  });
  const record = ({ session, prompt, proxy, conditions, siteRecords }) => {
    session.asks.forEach((ask, index) => {
      const row = flatten({ session, ask, index, proxy, site: siteRecords, condition: conditions[index], prompt });
      results.push(row);
      console.log(`${row.surface} ${row.prompt} ${row.condition}: turns ${row.metrics.modelTurns} tools ${row.metrics.toolCalls} http ${JSON.stringify(row.httpByClass)} first-content ${row.metrics.enterToFirstContentMs} visible ${row.metrics.enterToFirstVisibleMs} last-byte ${row.metrics.enterToLastByteMs} ready ${row.metrics.enterToReadyFrameMs} ms${row.timedOut ? ' TIMED OUT' : ''}`);
    });
  };
  const attempt = async (label, run) => {
    try {
      await run();
    } catch (error) {
      failures.push(`${label}: ${String(error.message).slice(0, 600)}`);
      console.log(`${label} failed: ${String(error.message).slice(0, 600)}`);
    }
  };
  try {
    for (let run = 0; run < options.runs; run++) {
      for (const prompt of prompts) {
        const proxy = prompt.route === 'paced' ? pacedProxy : shimProxy;
        if (surfaces.node) {
          await attempt(`node ${prompt.id} run ${run}`, async () => {
            record({ session: await nodeSession({ spec: specFor(prompt, options.wasm), key }), prompt, proxy, conditions: ['cold', 'warm'], siteRecords: null });
          });
        }
        if (surfaces.browser) {
          await attempt(`browser ${prompt.id} run ${run}`, async () => {
            const chromium = await startChromium(chrome);
            try {
              for (const cold of ['cold-fresh-profile', 'cold-reused-profile']) {
                record({ session: await browserSession({ chromium, site, spec: specFor(prompt, `${site.url}/fx-term.wasm`), key }), prompt, proxy, conditions: [cold, 'warm'], siteRecords: site });
              }
            } finally {
              await chromium.close();
            }
          });
        }
        if (surfaces.native && prompt.native) {
          await attempt(`native ${prompt.id} run ${run}`, async () => {
            record({ session: await nativeSession({ bin: options.native, spec: specFor(prompt, null), key, proxy }), prompt, proxy, conditions: ['cold', 'warm'], siteRecords: null });
          });
        }
      }
    }
  } finally {
    await shimProxy.close();
    await pacedProxy.close();
    await pacedModel.close();
    await site.close();
    for (const pid of children) killTree(pid);
    for (const marker of markers) killMarked(marker);
  }
  const summary = summarise(results);
  printSummary(summary);
  if (failures.length) console.log(`\nfailed sessions:\n${failures.join('\n')}`);
  if (options.out) {
    writeFileSync(options.out, JSON.stringify({ started, finished: new Date().toISOString(), model: MODEL, shim: options.shim, wasm: options.wasm, wasmBytes: existsSync(options.wasm) ? statSync(options.wasm).size : null, runs: options.runs, surfaces, paced: PACED, summary, failures, results }, null, 1));
    console.log(`\nresults written to ${options.out}`);
  }
  return undefined;
};

main().then(() => process.exit(0), (error) => {
  console.error(error.stack ?? String(error));
  process.exit(1);
});
