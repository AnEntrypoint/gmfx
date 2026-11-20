

























import { appendFileSync, readFileSync } from "node:fs";
import { createAuth, type AuthConfig } from "./oauth";

export interface HttpRule {
  method: string;
  times?: number;

  version?: string | null;
  cursor?: string | null;

  name?: string;

  status?: number;

  sse?: boolean;

  before?: unknown[];
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };

  raw?: string;
  contentType?: string;

  delayMs?: number;

  drop?: boolean;

  hang?: boolean;

  headers?: Record<string, string>;

  ids?: boolean;

  retry?: number;

  poll?: boolean;

  endSession?: boolean;

  later?: unknown[];
  laterMs?: number;

  awaitReply?: boolean;
  awaitMs?: number;

  listenLater?: unknown[];

  keepOpen?: boolean;
}

interface Message {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: { _meta?: Record<string, unknown>; cursor?: string; name?: string };
}

const args = process.argv.slice(2);
const get = (flag: string) => {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
};
const rules = JSON.parse(readFileSync(get("--script") ?? "/dev/null", "utf8") || "[]") as HttpRule[];
const used = rules.map(() => 0);
const logPath = get("--log");
const sessions = args.includes("--session");

const noSessionId = args.includes("--no-session-id");
const listenMode = get("--listen") ?? "405";
const deleteStatus = Number(get("--delete-status") ?? "200");

const initializedDelay = Number(get("--initialized-delay") ?? "0");

const listenDelay = Number(get("--listen-delay") ?? "0");
const log = (entry: object) => {
  if (logPath) appendFileSync(logPath, JSON.stringify({ t: Date.now(), ...entry }) + "\n");
};

const authPath = get("--auth");
const auth = authPath ? createAuth(JSON.parse(readFileSync(authPath, "utf8")) as AuthConfig, () => `http://127.0.0.1:${server.port}`, log) : null;



const withId = <T>(value: T, id: unknown): T => JSON.parse(JSON.stringify(value).replaceAll('"$id"', JSON.stringify(id ?? null)));

const encoder = new TextEncoder();
const sseEvent = (message: unknown, id?: string, retry?: number) =>
  encoder.encode(`${retry !== undefined ? `retry: ${retry}\n` : ""}${id !== undefined ? `id: ${id}\n` : ""}event: message\ndata: ${message === undefined ? "" : JSON.stringify(message)}\n\n`);


let sessionCount = 0;
let currentSession: string | null = null;
const ended = new Set<string>();

const kept = new Map<string, { answer: unknown; next: number }>();
let streamCount = 0;

let listenController: ReadableStreamDefaultController | null = null;

const replies = new Map<string, () => void>();

function sessionProblem(req: Request, initialize: boolean): Response | null {
  if (!sessions || initialize) return null;
  const id = req.headers.get("mcp-session-id");
  if (!id) return new Response("Bad Request: No valid session ID provided", { status: 400 });
  if (id !== currentSession || ended.has(id))
    return Response.json({ jsonrpc: "2.0", error: { code: -32001, message: "Session not found" }, id: null }, { status: 404 });
  return null;
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  idleTimeout: 0,
  async fetch(req) {
    const headers = Object.fromEntries(req.headers.entries());
    const routed = auth ? await auth.route(req) : null;
    if (routed) return routed;
    if (req.method === "DELETE") {
      log({ dir: "in", httpMethod: "DELETE", headers });
      const denied = auth?.check(req, "DELETE");
      if (denied) return denied;
      const problem = sessionProblem(req, false);
      if (problem) return problem;
      if (currentSession) ended.add(currentSession);
      return new Response(null, { status: deleteStatus });
    }
    if (req.method === "GET") {
      log({ dir: "in", httpMethod: "GET", headers });
      const deniedGet = auth?.check(req, "GET");
      if (deniedGet) return deniedGet;
      const problem = sessionProblem(req, false);
      if (problem) return problem;
      const last = req.headers.get("last-event-id");
      if (last) {
        const name = last.slice(0, last.lastIndexOf("-"));
        const stream = kept.get(name);
        if (!stream) return new Response("Unknown stream", { status: 400 });
        kept.delete(name);
        return new Response(sseEvent(stream.answer, `${name}-${stream.next}`), { headers: { "content-type": "text/event-stream" } });
      }
      if (listenMode === "405") return new Response("Method Not Allowed", { status: 405 });
      const name = `listen${++streamCount}`;
      const body = new ReadableStream({
        start(controller) {
          listenController = controller;
          controller.enqueue(sseEvent(undefined, `${name}-0`));
          if (listenMode === "close") controller.close();
        },
        cancel() {
          listenController = null;
          log({ dir: "closed", stream: name });
        },
      });
      if (listenDelay > 0) await Bun.sleep(listenDelay);
      log({ dir: "listen_open", stream: name });
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    }
    if (req.method !== "POST") {
      log({ dir: "in", httpMethod: req.method, headers });
      return new Response("Method Not Allowed", { status: 405 });
    }
    const text = await req.text();
    log({ dir: "in", httpMethod: "POST", headers, body: text });
    let message: Message;
    try {
      message = JSON.parse(text) as Message;
    } catch {
      return Response.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, { status: 400 });
    }
    const denied = auth?.check(req, message.method);
    if (denied) return denied;
    const problem = sessionProblem(req, message.method === "initialize");
    if (problem) return problem;

    if (message.id === undefined || message.method === undefined) {
        if (message.method === undefined && message.id !== undefined) replies.get(JSON.stringify(message.id))?.();
        if (message.method === "notifications/initialized" && initializedDelay > 0) {
            await Bun.sleep(initializedDelay);
            log({ dir: "answered", method: message.method });
        }
        return new Response(null, { status: 202 });
    }
    const version = message.params?._meta?.["io.modelcontextprotocol/protocolVersion"] ?? null;
    const index = rules.findIndex(
      (r, i) =>
        r.method === message.method &&
        (r.version === undefined || r.version === version) &&
        (r.cursor === undefined || r.cursor === (message.params?.cursor ?? null)) &&
        (r.name === undefined || r.name === message.params?.name) &&
        (r.times === undefined || used[i] < r.times),
    );
    if (index < 0) return Response.json({ jsonrpc: "2.0", id: message.id ?? null, error: { code: -32601, message: "Method not found" } }, { status: 404 });
    used[index] += 1;
    const rule = rules[index];
    if (rule.listenLater) {
      const messages = rule.listenLater;
      setTimeout(() => {
        for (const m of messages) listenController?.enqueue(sseEvent(m));
      }, rule.laterMs ?? 300);
    }
    if (rule.delayMs) await Bun.sleep(rule.delayMs);
    const status = rule.status ?? 200;
    const extra: Record<string, string> = { ...(rule.headers ?? {}) };
    if (sessions && message.method === "initialize" && status === 200 && !rule.error) {
      currentSession = `s${++sessionCount}`;
      extra["mcp-session-id"] = currentSession;
    } else if (!sessions && !noSessionId && !("mcp-session-id" in extra)) extra["mcp-session-id"] = "fake-session";
    if (rule.endSession && currentSession) ended.add(currentSession);
    if (rule.raw !== undefined) return new Response(rule.raw, { status, headers: { "content-type": rule.contentType ?? "text/plain", ...extra } });
    const answer = rule.error ? { jsonrpc: "2.0", id: message.id ?? null, error: rule.error } : { jsonrpc: "2.0", id: message.id ?? null, result: withId(rule.result ?? {}, message.id) };
    if (!rule.sse) return Response.json(answer, { status, headers: extra });
    const id = message.id;
    const name = `stream${++streamCount}`;
    let n = 0;
    const nextId = () => (rule.ids ? `${name}-${n++}` : undefined);
    const stream = new ReadableStream({
      async start(controller) {
        controller.enqueue(encoder.encode(": keep-alive\n\n"));
        if (rule.ids) controller.enqueue(sseEvent(undefined, nextId(), rule.retry));
        else if (rule.retry !== undefined) controller.enqueue(encoder.encode(`retry: ${rule.retry}\n\n`));
        const asked: Promise<void>[] = [];
        for (const m of rule.before ?? []) {
          const msg = withId(m, id) as Message;
          if (rule.awaitReply && msg.method !== undefined && msg.id !== undefined) {
            asked.push(new Promise<void>((resolve) => replies.set(JSON.stringify(msg.id), resolve)));
          }
          controller.enqueue(sseEvent(msg, nextId()));
        }
        if (asked.length > 0) {
          await Promise.race([Promise.all(asked), Bun.sleep(rule.awaitMs ?? 5000)]);
          log({ dir: "replied", id });
        }
        if (rule.later) {
          await Bun.sleep(rule.laterMs ?? 300);
          for (const m of rule.later) controller.enqueue(sseEvent(withId(m, id), nextId()));
        }
        if (rule.drop) {
          await Bun.sleep(20);
          controller.error(new Error("dropped by the fake server"));
          return;
        }
        if (rule.hang) return;
        if (rule.poll) {
          kept.set(name, { answer, next: n });
          await Bun.sleep(20);
          controller.close();
          return;
        }
        controller.enqueue(sseEvent(answer, nextId()));
        if (!rule.keepOpen) controller.close();
      },
      cancel() {
        log({ dir: "closed", id });
      },
    });
    req.signal.addEventListener("abort", () => log({ dir: "aborted", id }));
    return new Response(stream, { status, headers: { "content-type": "text/event-stream", "cache-control": "no-cache", ...extra } });
  },
});

console.log(JSON.stringify({ listening: server.port }));
process.on("SIGTERM", () => {
  server.stop(true);
  process.exit(0);
});
