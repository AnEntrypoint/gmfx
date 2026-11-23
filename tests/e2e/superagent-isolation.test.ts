import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  serveFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !existsSync("/proc/self/stat");
const TIMEOUT = 120_000;
const STEP = 60_000;
const MODEL = "openai/gpt-5";
const PROJECT = "isoproj";
const OWNER_PROMPT = "ISOLATION-OWNER: start isoproj and give it the long command";
const ROOT_TASK = "ISOLATION-ROOT-TASK: run the long command in this project";
const STATUS_PROMPT = "ISOLATION-STATUS: read the superagent status now";
const ROOT_COMMAND = "sleep 37";
const WAITING = "isolation waiting for the root event";
const STATUS_SEEN = "isolation status seen";
const EVENT_SEEN = "isolation event received";
const HYPERAGENT = "/workspace/hyperagent";
const FOREIGN_NAMES = ["airc", "gm", "gm-core", "hyperagent", "tmux", "script", "screen"];

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Message = { role?: string; content?: unknown };

function messages(body: string): Message[] {
  const request = JSON.parse(body) as { prompt?: Message[] };
  return request.prompt ?? [];
}

function textOf(message: Message): string {
  return typeof message.content === "string" ? message.content : JSON.stringify(message.content ?? "");
}

function lastUserText(body: string): string {
  const last = messages(body).filter((message) => message.role === "user").at(-1);
  return last ? textOf(last) : "";
}

function verbReply(result: Record<string, unknown>): string {
  const output = result.output as { value?: unknown } | undefined;
  const envelope = typeof output?.value === "string" ? JSON.parse(output.value) : undefined;
  if (envelope?.ok !== true) return JSON.stringify(output ?? result);
  return typeof envelope.value === "string" ? envelope.value : JSON.stringify(envelope.value);
}

function lastToolResult(body: string): Record<string, unknown> | undefined {
  const all = messages(body);
  let lastUser = -1;
  all.forEach((message, index) => {
    if (message.role === "user") lastUser = index;
  });
  return all
    .slice(lastUser + 1)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry): entry is Record<string, unknown> => {
      return typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result";
    })
    .at(-1);
}

function createLayout() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-isolation-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(project, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    project: realpathSync(project),
    stderrPath: join(root, "stderr.log"),
    tracePath: join(root, "trace.log"),
  };
}

type Layout = ReturnType<typeof createLayout>;

async function startSession(layout: Layout, gateway: { baseUrl: string; chatUrl: string }): Promise<TmuxSession> {
  writeFileSync(layout.stderrPath, "");
  const session = await TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${layout.stderrPath}`,
    cwd: layout.workspace,
    env: {
      HOME: layout.home,
      AI_GATEWAY_API_KEY: "fake-superagent-isolation-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_PERMISSION_MODE: "yolo",
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      NO_COLOR: "1",
      FX_TRACE: "1",
      FX_TRACE_LOG: layout.tracePath,
    },
    width: 120,
    height: 40,
  });
  sessions.push(session);
  return session;
}

function superagentFiles(home: string): string[] {
  const dir = join(home, ".fx", "superagent");
  if (!existsSync(dir)) return [];
  return readdirSync(dir).map((name) => join(dir, name));
}

async function waitUntil(check: () => boolean, what: string, context: () => Promise<string>, timeoutMs = STEP) {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}\n${await context()}`);
    await Bun.sleep(100);
  }
}

function linkOf(path: string): string {
  try {
    return readlinkSync(path);
  } catch {
    return "";
  }
}

function textAt(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function namesIn(path: string): string[] {
  try {
    return readdirSync(path);
  } catch {
    return [];
  }
}

function parentOf(pid: number): number {
  const stat = textAt(`/proc/${pid}/stat`);
  const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
  const parent = Number.parseInt(fields[1] ?? "", 10);
  return Number.isSafeInteger(parent) ? parent : -1;
}

function childrenOf(pid: number): number[] {
  return namesIn(`/proc/${pid}/task`)
    .flatMap((task) => textAt(`/proc/${pid}/task/${task}/children`).trim().split(/\s+/))
    .filter((entry) => entry.length > 0)
    .map((entry) => Number.parseInt(entry, 10));
}

function descendantsOf(pid: number): number[] {
  const found: number[] = [];
  const pending = [pid];
  while (pending.length > 0) {
    for (const child of childrenOf(pending.pop()!)) {
      if (found.includes(child)) continue;
      found.push(child);
      pending.push(child);
    }
  }
  return found;
}

function argvOf(pid: number): string[] {
  return textAt(`/proc/${pid}/cmdline`).split("\0").filter((entry) => entry.length > 0);
}

function withoutDeletedMark(path: string): string {
  return path.endsWith(" (deleted)") ? path.slice(0, -" (deleted)".length) : path;
}

function openPathsOf(pid: number): string[] {
  const descriptors = namesIn(`/proc/${pid}/fd`).map((fd) => linkOf(`/proc/${pid}/fd/${fd}`));
  const mapped = textAt(`/proc/${pid}/maps`)
    .split("\n")
    .map((line) => line.slice(line.indexOf("/")))
    .filter((path) => path.startsWith("/"));
  const all = [...descriptors, ...mapped, linkOf(`/proc/${pid}/cwd`), linkOf(`/proc/${pid}/exe`)];
  return [...new Set(all.filter((path) => path.length > 0).map(withoutDeletedMark))];
}

function describeProcess(pid: number) {
  const argv = argvOf(pid);
  return {
    pid,
    ppid: parentOf(pid),
    exe: withoutDeletedMark(linkOf(`/proc/${pid}/exe`)),
    argv,
    cmd: argv.join(" "),
    cwd: linkOf(`/proc/${pid}/cwd`),
    paths: openPathsOf(pid),
  };
}

type ProcessView = ReturnType<typeof describeProcess>;

function reachesParent(pid: number, ancestor: number): boolean {
  let current = pid;
  for (let depth = 0; depth < 64 && current > 1; depth += 1) {
    current = parentOf(current);
    if (current === ancestor) return true;
  }
  return false;
}

function isUnder(path: string, folders: string[]): boolean {
  return folders.some((folder) => path === folder || path.startsWith(`${folder}/`));
}

function hasForeignName(view: ProcessView): boolean {
  return [basename(view.exe), basename(view.argv[0] ?? "")].some((name) => FOREIGN_NAMES.includes(name));
}

function fxPidUnder(panePid: number): number {
  const binary = realpathSync(FX_BIN);
  const owned = [panePid, ...descendantsOf(panePid)].find((pid) => {
    const exe = withoutDeletedMark(linkOf(`/proc/${pid}/exe`));
    return exe === binary || (existsSync(exe) && realpathSync(exe) === binary);
  });
  if (owned === undefined) throw new Error(`no process under tmux pane ${panePid} runs ${binary}`);
  return owned;
}

describe.skipIf(SKIP)("the superagent needs no process outside fx", () => {
  test(
    "the superagent runs its roots inside fx: every child process is fx-owned and no open path is under /workspace/hyperagent",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let rootRequests = 0;
      let started = "";
      let instructed = "";
      let statusText = "";
      const gateway = serveFakeGateway(
        (body: string) => {
          const user = lastUserText(body);
          seen.push(user.slice(0, 160).replaceAll("\n", " | "));
          const last = lastToolResult(body);
          const lastId = last ? String(last.toolCallId) : undefined;
          if (user.includes(ROOT_TASK)) {
            rootRequests += 1;
            if (lastId === "iso-run") return fakeGatewayFinalText("REPORT: finished — the long command ended");
            return fakeGatewayVerbCall("iso-run", "Bash", { command: ROOT_COMMAND, description: "Run the long command" });
          }
          if (user.includes(STATUS_PROMPT)) {
            if (lastId !== "iso-status") return fakeGatewayVerbCall("iso-status", "superagent", { action: "status" });
            statusText = verbReply(last!);
            return fakeGatewayFinalText(STATUS_SEEN);
          }
          if (user.includes(OWNER_PROMPT)) {
            if (!lastId) return fakeGatewayVerbCall("iso-start", "superagent", { action: "start", agent: PROJECT });
            if (lastId === "iso-start") {
              started = verbReply(last!);
              return fakeGatewayVerbCall("iso-instruct", "superagent", { action: "instruct", agent: PROJECT, prompt: ROOT_TASK });
            }
            instructed = verbReply(last!);
            return fakeGatewayFinalText(WAITING);
          }
          if (user.includes("superagent event: root ")) return fakeGatewayFinalText(EVENT_SEEN);
          return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
        },
        { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
      );
      gateways.push(gateway);

      const session = await startSession(layout, gateway);
      const context = async () => {
        const trace = existsSync(layout.tracePath) ? readFileSync(layout.tracePath, "utf8").split("\n").slice(-30).join("\n") : "(no trace)";
        return `PANE:\n${await session.capturePane()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nREQUESTS:\n${seen.join("\n")}\nTRACE: ${trace}`;
      };
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await session.waitForText(WAITING, STEP).catch(async (error) => {
        throw new Error(`${String(error)}\n${await context()}`);
      });
      await waitUntil(() => rootRequests > 0, "the root's first request", context);

      const fxPid = fxPidUnder(session.panePid());
      const runsRootCommand = (pid: number) => argvOf(pid).join(" ") === ROOT_COMMAND;
      await waitUntil(() => descendantsOf(fxPid).some(runsRootCommand), "the root's command to run under fx", context);
      const commandPids = descendantsOf(fxPid).filter(runsRootCommand);

      try {
        await session.sendText(STATUS_PROMPT);
        await waitUntil(() => statusText.length > 0, "the superagent status result", context);

        const fx = describeProcess(fxPid);
        const children = descendantsOf(fxPid)
          .filter((pid) => existsSync(`/proc/${pid}/stat`))
          .map(describeProcess)
          .filter((view) => view.ppid > 0);
        const hyperagentFolders = [...new Set([HYPERAGENT, existsSync(HYPERAGENT) ? realpathSync(HYPERAGENT) : HYPERAGENT])];
        const underHyperagent = [fx, ...children].flatMap((view) =>
          view.paths.filter((path) => isUnder(path, hyperagentFolders)).map((path) => `pid=${view.pid} ${path}`),
        );
        const childPathCount = children.reduce((total, view) => total + view.paths.length, 0);
        const foreign = children.filter((view) => !reachesParent(view.pid, fxPid) || hasForeignName(view));
        const fxOwned = children.filter((view) => !foreign.includes(view));

        console.log(`ISOLATION-FX pid=${fx.pid} ppid=${fx.ppid} exe=${fx.exe} cwd=${fx.cwd}`);
        for (const view of children) {
          console.log(`ISOLATION-CHILD pid=${view.pid} ppid=${view.ppid} exe=${view.exe} cmd=${view.cmd} cwd=${view.cwd}`);
        }
        console.log(`ISOLATION-PATHS fx=${fx.paths.length} children=${childPathCount} under_hyperagent=${underHyperagent.length}`);
        console.log(`ISOLATION-STATUS ${statusText}`);
        console.log(
          `ISOLATION-WITNESS children=${children.length} fx_owned=${fxOwned.length} foreign=${foreign.length} under_hyperagent=${underHyperagent.length}`,
        );

        expect(realpathSync(fx.exe), "the inspected process is the fx binary under test").toBe(realpathSync(FX_BIN));
        expect(started, `start result: ${started}`).toContain(layout.project);
        expect(statusText, "status ends with the host line of the native memory and process checks").toMatch(/host memory_available_mb=\S+ min_free_mb=\d+ new_roots=admitted child_processes=[1-9]/);
        expect(instructed, `instruct result: ${instructed}`).toContain("queued");
        expect(statusText, `status shows the root: ${statusText}`).toContain(`${PROJECT} ${layout.project}`);
        expect(statusText, `status shows the root alive: ${statusText}`).toContain("alive=true");
        expect(children.length, "fx had at least one child process while it was inspected").toBeGreaterThan(0);
        expect(
          children.some((view) => view.cmd === ROOT_COMMAND && view.cwd === layout.project),
          "the root's command ran as a descendant of fx, in the root's project folder",
        ).toBe(true);
        for (const view of children) {
          expect(reachesParent(view.pid, fxPid), `pid ${view.pid} (${view.cmd}) has fx ${fxPid} in its parent chain`).toBe(true);
          expect(hasForeignName(view), `pid ${view.pid} exe=${view.exe} argv0=${view.argv[0]} is not an outside orchestrator`).toBe(false);
        }
        expect(foreign.map((view) => `${view.pid} ${view.exe} ${view.cmd}`)).toEqual([]);
        expect(fxOwned.length).toBe(children.length);
        expect(fx.paths.length, "fx's open paths were read").toBeGreaterThan(0);
        expect(underHyperagent).toEqual([]);

        const files = superagentFiles(layout.home);
        const ledgers = files.filter((path) => path.endsWith(".json"));
        const journals = files.filter((path) => path.endsWith(".journal.jsonl"));
        expect(ledgers.length, `fx wrote its own dispatch ledger under ${layout.home}: ${files.join(", ")}`).toBeGreaterThan(0);
        expect(journals.length, `fx wrote its own journal under ${layout.home}: ${files.join(", ")}`).toBeGreaterThan(0);
        for (const path of [...ledgers, ...journals]) {
          expect(realpathSync(path).startsWith(`${layout.root}/`), `${path} is inside the test's own home`).toBe(true);
          expect(isUnder(realpathSync(path), hyperagentFolders)).toBe(false);
        }
        expect(ledgers.map((path) => readFileSync(path, "utf8")).join("\n")).toContain(PROJECT);
        expect(journals.map((path) => readFileSync(path, "utf8")).join("\n")).toContain(ROOT_TASK);
        expect(session.isAlive()).toBe(true);
      } finally {
        for (const pid of commandPids) {
          try {
            process.kill(pid, "SIGTERM");
          } catch {}
        }
      }
    },
    TIMEOUT,
  );
});
