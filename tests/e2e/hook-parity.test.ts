import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  serveFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 60_000;
const WAIT = 30_000;
const MODEL = "openai/gpt-5";
const MAIN_PROMPT = "PARITY-TASK: finish the hook parity witness.";
const AGENT_PROMPT = "PARITY-AGENT: hand the CHILD-TASK to a subagent.";
const CHILD_TASK = "CHILD-TASK: reply with the word child-done";
const FAILING_PROMPT = "PARITY-FAIL: the provider rejects this turn.";
const HELD_PROMPT = "PARITY-HELD: keep this turn streaming.";
const QUEUED_PROMPT = "PARITY-QUEUED: wait behind the held turn.";
const BACKGROUND_PROMPT = "PARITY-BACKGROUND: start a detached command.";
const BACKGROUND_AGENT_PROMPT = "PARITY-BACKGROUND-AGENT: hand the CHILD-TASK to a background subagent.";
const BLOCKED_PROMPT = "PARITY-BLOCKED: write the note two hooks refuse.";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Message = { role?: string; content?: unknown };
type HookPayload = Record<string, unknown>;

function lastUserText(body: string): string {
  const request = JSON.parse(body) as { prompt?: Message[] };
  const last = (request.prompt ?? []).filter((message) => message.role === "user").at(-1);
  if (!last) return "";
  return typeof last.content === "string" ? last.content : JSON.stringify(last.content ?? "");
}

function toolResultCountSinceLastUser(body: string): number {
  const request = JSON.parse(body) as { prompt?: Message[] };
  const all = request.prompt ?? [];
  let lastUser = -1;
  all.forEach((message, index) => {
    if (message.role === "user") lastUser = index;
  });
  return all
    .slice(lastUser + 1)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry) => typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result")
    .length;
}

function createRoot(settings: (marker: string) => Record<string, unknown>) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-hook-parity-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const marker = join(root, "hook-events.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission: {}, ...settings(marker) }),
  );
  return { root, home, workspace: realpathSync(workspace), marker };
}

function gatewayEnv(home: string, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-hook-parity-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "yolo",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function route(body: string): Response {
  const user = lastUserText(body);
  if (user.includes(CHILD_TASK)) return fakeGatewayFinalText("child-done");
  if (user.includes(BACKGROUND_AGENT_PROMPT)) {
    if (toolResultCountSinceLastUser(body) === 0) {
      return fakeGatewayToolCall("agent-background-child", "Agent", {
        prompt: CHILD_TASK,
        description: "child task",
        subagent_type: "explore",
        run_in_background: true,
      });
    }
    return fakeGatewayFinalText("background-agent-started");
  }
  if (user.includes(AGENT_PROMPT)) {
    if (toolResultCountSinceLastUser(body) === 0) {
      return fakeGatewayToolCall("agent-child", "Agent", {
        prompt: CHILD_TASK,
        description: "child task",
        subagent_type: "explore",
      });
    }
    return fakeGatewayFinalText("agent-done");
  }
  if (user.includes(BACKGROUND_PROMPT)) {
    if (toolResultCountSinceLastUser(body) === 0) {
      return fakeGatewayToolCall("background-sleep", "Bash", {
        command: "sleep 1",
        description: "detached sleep",
        run_in_background: true,
      });
    }
    return fakeGatewayFinalText("background-done");
  }
  if (user.includes(BLOCKED_PROMPT)) {
    if (toolResultCountSinceLastUser(body) === 0) {
      return fakeGatewayToolCall("blocked-write", "write_file", { path: "note.txt", content: "note" });
    }
    return fakeGatewayFinalText("blocked-done");
  }
  if (user.includes(FAILING_PROMPT)) {
    return Response.json({ error: { message: "PARITY-PROVIDER-REJECTED", type: "invalid_request_error" } }, { status: 400 });
  }
  return fakeGatewayFinalText("parity-done");
}

function startGateway() {
  const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  gateways.push(gateway);
  return gateway;
}

function readPayloads(marker: string): HookPayload[] {
  return readFileSync(marker, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as HookPayload);
}

const appendPayloadLine = (marker: string) => `cat >> ${marker}; echo >> ${marker}`;

async function waitForPayloads(marker: string, count: number, timeoutMs: number): Promise<HookPayload[]> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(marker)) {
      const text = readFileSync(marker, "utf8");
      if (text.endsWith("\n") && text.split("\n").filter((line) => line.trim().length > 0).length >= count) {
        return readPayloads(marker);
      }
    }
    await Bun.sleep(50);
  }
  throw new Error(`Timed out waiting for ${count} hook payload(s) in ${marker}: ${existsSync(marker) ? readFileSync(marker, "utf8") : "<no file>"}`);
}

describe("hook parity in headless ask", () => {
  test(
    "SessionStart names startup then resume and SessionEnd carries the same session id",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [
          { event: "SessionStart", command: appendPayloadLine(marker) },
          { event: "SessionEnd", command: appendPayloadLine(marker) },
        ],
      }));
      const gateway = startGateway();

      const first = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(first.code, `stdout: ${first.stdout}\nstderr: ${first.stderr}`).toBe(0);
      const firstRun = readPayloads(layout.marker);
      expect(firstRun.map((payload) => payload.hook_event_name)).toEqual(["SessionStart", "SessionEnd"]);
      expect(firstRun[0].source).toBe("startup");
      expect(typeof firstRun[0].session_id).toBe("string");
      expect((firstRun[0].session_id as string).length).toBeGreaterThan(0);
      expect(firstRun[1].reason).toBe("exit");
      expect(firstRun[1].session_id).toBe(firstRun[0].session_id);

      const second = await runFx(["ask", "--quiet", "--json", "--resume", "last", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });
      expect(second.code, `stdout: ${second.stdout}\nstderr: ${second.stderr}`).toBe(0);
      const bothRuns = readPayloads(layout.marker);
      expect(bothRuns.map((payload) => payload.hook_event_name)).toEqual([
        "SessionStart",
        "SessionEnd",
        "SessionStart",
        "SessionEnd",
      ]);
      expect(bothRuns[2].source).toBe("resume");
      expect(bothRuns[2].session_id).toBe(firstRun[0].session_id);
      expect(bothRuns[3].session_id).toBe(firstRun[0].session_id);
    },
    TIMEOUT,
  );

  test(
    "an enabled plugin's manifest hook runs from the plugin root with the plugin env",
    async () => {
      const layout = createRoot(() => ({}));
      const pluginRoot = join(layout.root, "plugin-hooky");
      mkdirSync(pluginRoot, { recursive: true });
      const fxHome = join(layout.home, ".fx");
      writeFileSync(
        join(pluginRoot, "kimi.plugin.json"),
        JSON.stringify({
          name: "hooky",
          hooks: [
            {
              event: "SessionStart",
              command: `printf '%s|%s|%s|%s|%s\\n' "$KIMI_PLUGIN_ROOT" "$FX_PLUGIN_ROOT" "$KIMI_CODE_HOME" "$FX_HOME" "$(pwd -P)" > ${layout.marker}`,
            },
          ],
        }),
      );
      mkdirSync(join(fxHome, "plugins"), { recursive: true });
      writeFileSync(
        join(fxHome, "plugins", "installed.json"),
        JSON.stringify({ version: 1, plugins: [{ id: "hooky", root: pluginRoot, source: pluginRoot, enabled: true }] }),
      );
      const gateway = startGateway();

      const result = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `the plugin hook did not run; stderr: ${result.stderr}`).toBe(true);
      expect(readFileSync(layout.marker, "utf8").trim()).toBe(
        [pluginRoot, pluginRoot, fxHome, fxHome, pluginRoot].join("|"),
      );
    },
    TIMEOUT,
  );

  test(
    "TaskStarted fires with kind agent when a subagent run starts",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [{ event: "TaskStarted", matcher: "^agent$", command: appendPayloadLine(marker) }],
      }));
      const gateway = startGateway();

      const result = await runFx(["ask", "--quiet", "--json", AGENT_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `no TaskStarted hook ran; stderr: ${result.stderr}`).toBe(true);
      const payloads = readPayloads(layout.marker);
      expect(payloads.length).toBeGreaterThan(0);
      expect(payloads[0].hook_event_name).toBe("TaskStarted");
      expect(payloads[0].kind).toBe("agent");
      expect(payloads[0].status).toBe("running");
      expect(typeof payloads[0].task_id).toBe("string");
    },
    TIMEOUT,
  );

  test(
    "StopFailure carries the error name and message of a provider failure",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [
          { event: "StopFailure", command: appendPayloadLine(marker) },
          { event: "StopFailure", matcher: "^invalid_request$", command: `touch ${marker}.matched` },
          { event: "StopFailure", matcher: "^some_other_error$", command: `touch ${marker}.unmatched` },
        ],
      }));
      const gateway = startGateway();

      const result = await runFx(["ask", "--quiet", "--json", FAILING_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).not.toBe(0);
      expect(existsSync(layout.marker), `no StopFailure hook ran; stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(true);
      const payloads = readPayloads(layout.marker);
      expect(payloads.map((payload) => payload.hook_event_name)).toEqual(["StopFailure"]);
      expect(payloads[0].error_type).toBe("invalid_request");
      expect(payloads[0].error_message as string).toContain("PARITY-PROVIDER-REJECTED");
      expect((payloads[0].session_id as string).length).toBeGreaterThan(0);
      expect(existsSync(`${layout.marker}.matched`)).toBe(true);
      expect(existsSync(`${layout.marker}.unmatched`)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "two matched hooks run at the same time",
    async () => {
      const layout = createRoot((marker) => {
        const overlapping = (own: string, other: string) =>
          `touch ${marker}.${own}; sleep 3; if [ -e ${marker}.${other} ]; then echo ${own}-saw-${other} >> ${marker}; fi`;
        return {
          hooks: [
            { event: "SessionStart", command: overlapping("first", "second") },
            { event: "SessionStart", command: overlapping("second", "first") },
          ],
        };
      });
      const gateway = startGateway();

      const started = Date.now();
      const result = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });
      const elapsedMs = Date.now() - started;

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(readFileSync(layout.marker, "utf8").split("\n").filter((line) => line.length > 0).sort()).toEqual([
        "first-saw-second",
        "second-saw-first",
      ]);
      expect(elapsedMs).toBeGreaterThanOrEqual(3_000);
      expect(elapsedMs).toBeLessThan(6_000);
    },
    TIMEOUT,
  );

  test(
    "TaskStarted fires with kind process when a detached command starts",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [{ event: "TaskStarted", matcher: "^process$", command: appendPayloadLine(marker) }],
      }));
      const gateway = startGateway();

      const result = await runFx(["ask", "--quiet", "--json", BACKGROUND_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `no TaskStarted hook ran; stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(true);
      const payloads = readPayloads(layout.marker);
      expect(payloads.length).toBe(1);
      expect(payloads[0].hook_event_name).toBe("TaskStarted");
      expect(payloads[0].kind).toBe("process");
      expect(payloads[0].status).toBe("running");
      expect(payloads[0].detached).toBe(true);
      expect(typeof payloads[0].task_id).toBe("string");
      expect(typeof payloads[0].started_at).toBe("number");
      expect((payloads[0].session_id as string).length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );

  test(
    "Notification reports sink context and the task status when a background subagent's report reaches its parent",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [{ event: "Notification", matcher: "^task\\.", command: appendPayloadLine(marker) }],
      }));
      const gateway = startGateway();

      const result = await runFx(["ask", "--quiet", "--json", BACKGROUND_AGENT_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `no Notification hook ran; stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(true);
      const payloads = readPayloads(layout.marker);
      expect(payloads.length).toBe(1);
      expect(payloads[0].hook_event_name).toBe("Notification");
      expect(payloads[0].sink).toBe("context");
      expect(payloads[0].notification_type).toBe("task.completed");
      expect(payloads[0].source_kind).toBe("background_task");
      expect(payloads[0].body as string).toContain("child-done");
      expect((payloads[0].session_id as string).length).toBeGreaterThan(0);
    },
    TIMEOUT,
  );

  test(
    "the first block in configured order wins and each dispatch leaves an external_hook_resolved trace event",
    async () => {
      const layout = createRoot(() => ({
        hooks: [
          { event: "PreToolUse", matcher: "^write_file$", command: "sleep 1; echo FIRST-CONFIGURED-REASON >&2; exit 2" },
          { event: "PreToolUse", matcher: "^write_file$", command: "echo SECOND-CONFIGURED-REASON >&2; exit 2" },
          { event: "SessionStart", command: "true" },
        ],
      }));
      const gateway = startGateway();
      const tracePath = join(layout.root, "trace.log");

      const result = await runFx(["ask", "--quiet", "--json", BLOCKED_PROMPT], {
        cwd: layout.workspace,
        env: { ...gatewayEnv(layout.home, gateway), FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "hooks" },
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("blocked-done");
      expect(existsSync(join(layout.workspace, "note.txt"))).toBe(false);
      const afterBlock = gateway.requests.at(-1)!.body;
      expect(afterBlock).toContain("FIRST-CONFIGURED-REASON");
      expect(afterBlock).not.toContain("SECOND-CONFIGURED-REASON");
      const resolved = readFileSync(tracePath, "utf8").split("\n").filter((line) => line.includes("external_hook_resolved"));
      expect(resolved.some((line) => line.includes("event=SessionStart action=allow matched_count=1 failed_count=0")), resolved.join("\n")).toBe(true);
      expect(resolved.some((line) => line.includes("event=PreToolUse action=block matched_count=2 failed_count=0")), resolved.join("\n")).toBe(true);
    },
    TIMEOUT,
  );
});

describe("hook parity in the TUI", () => {
  test.skipIf(!tmuxAvailable())(
    "SessionStart and SessionEnd fire in the TUI beside a plugin's manifest hook",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [
          { event: "SessionStart", command: appendPayloadLine(marker) },
          { event: "SessionEnd", command: appendPayloadLine(marker) },
        ],
      }));
      const pluginRoot = join(layout.root, "plugin-hooky");
      const pluginMarker = `${layout.marker}.plugin`;
      mkdirSync(pluginRoot, { recursive: true });
      const fxHome = join(layout.home, ".fx");
      writeFileSync(
        join(pluginRoot, "kimi.plugin.json"),
        JSON.stringify({
          name: "hooky",
          hooks: [{ event: "SessionStart", command: `printf '%s|%s|%s\\n' "$FX_PLUGIN_ROOT" "$FX_HOME" "$(pwd -P)" > ${pluginMarker}` }],
        }),
      );
      mkdirSync(join(fxHome, "plugins"), { recursive: true });
      writeFileSync(
        join(fxHome, "plugins", "installed.json"),
        JSON.stringify({ version: 1, plugins: [{ id: "hooky", root: pluginRoot, source: pluginRoot, enabled: true }] }),
      );
      const gateway = startGateway();
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: layout.workspace,
          env: { ...gatewayEnv(layout.home, gateway), FX_SOUND: "0" },
        });
        await session.waitForComposer(WAIT);
        await session.sendText(MAIN_PROMPT);
        await session.waitForText("parity-done", WAIT);
        await session.sendText("/quit");
        await session.waitForSessionEnd(WAIT);

        const payloads = readPayloads(layout.marker);
        expect(payloads.map((payload) => payload.hook_event_name)).toEqual(["SessionStart", "SessionEnd"]);
        expect(payloads[0].source).toBe("startup");
        expect(payloads[1].reason).toBe("exit");
        expect((payloads[1].session_id as string).length).toBeGreaterThan(0);
        expect(readFileSync(pluginMarker, "utf8").trim()).toBe([pluginRoot, fxHome, pluginRoot].join("|"));
      } finally {
        if (session) await session.kill();
      }
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "UserPromptQueued reports prompt_id, prompt and queue_length for a prompt queued behind a running turn",
    async () => {
      const layout = createRoot((marker) => ({
        hooks: [{ event: "UserPromptQueued", command: appendPayloadLine(marker) }],
      }));
      const held = heldFakeGatewayFinalText();
      const gateway = serveFakeGateway(
        (body) => (lastUserText(body).includes(QUEUED_PROMPT) ? fakeGatewayFinalText("queued-done") : held.response),
        { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
      );
      gateways.push(gateway);
      let session: TmuxSession | null = null;
      try {
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: layout.workspace,
          env: { ...gatewayEnv(layout.home, gateway), FX_SOUND: "0" },
        });
        await session.waitForComposer(WAIT);
        await session.sendText(HELD_PROMPT);
        const waitStarted = Date.now();
        while (gateway.requestCount() === 0) {
          if (Date.now() - waitStarted > WAIT) throw new Error(`the held turn never reached the gateway:\n${await session.capturePane()}`);
          await Bun.sleep(50);
        }
        await session.sendText(QUEUED_PROMPT);
        const payloads = await waitForPayloads(layout.marker, 1, WAIT).catch(async (error) => {
          throw new Error(`${error}\n${await session!.capturePane()}`);
        });

        expect(payloads.length).toBe(1);
        expect(payloads[0].hook_event_name).toBe("UserPromptQueued");
        expect(payloads[0].prompt).toBe(QUEUED_PROMPT);
        expect(payloads[0].queue_length).toBe(1);
        expect(typeof payloads[0].prompt_id).toBe("number");
        expect(payloads[0]).not.toHaveProperty("promptId");
        expect(payloads[0]).not.toHaveProperty("queueLength");
        expect(typeof payloads[0].session_id).toBe("string");
        expect((payloads[0].session_id as string).length).toBeGreaterThan(0);

        held.release("held-done");
        await session.waitForText("queued-done", WAIT);
      } finally {
        held.dispose();
        if (session) await session.kill();
      }
    },
    TIMEOUT,
  );
});
