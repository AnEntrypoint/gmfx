import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, fakeGatewayToolCall, serveFakeGateway } from "./tmux-helpers";

const TIMEOUT = 60_000;
const MODEL = "openai/gpt-5";
const MAIN_PROMPT = "LIFECYCLE-TASK: finish the lifecycle witness.";
const TOOL_PROMPT = "LIFECYCLE-TOOL: write the note through the tool.";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Message = { role?: string; content?: unknown };

function lastUserText(body: string): string {
  const request = JSON.parse(body) as { prompt?: Message[] };
  const last = (request.prompt ?? []).filter((message) => message.role === "user").at(-1);
  if (!last) return "";
  return typeof last.content === "string" ? last.content : JSON.stringify(last.content ?? "");
}

function resultsSinceLastUser(body: string): Record<string, unknown>[] {
  const request = JSON.parse(body) as { prompt?: Message[] };
  const all = request.prompt ?? [];
  let lastUser = -1;
  all.forEach((message, index) => {
    if (message.role === "user") lastUser = index;
  });
  return all
    .slice(lastUser + 1)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry): entry is Record<string, unknown> => {
      return typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result";
    });
}

function createRoot(hooks: (marker: string) => unknown, permission: unknown = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-lifecycle-hooks-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const marker = join(root, "hook-events.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission, hooks: hooks(marker) }),
  );
  return { home, workspace: realpathSync(workspace), marker };
}

function gatewayEnv(home: string, gateway: { baseUrl: string; chatUrl: string }, permissionMode: string) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-lifecycle-hooks-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: permissionMode,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function routeFinal(body: string): Response {
  const user = lastUserText(body);
  if (user.includes(MAIN_PROMPT)) return fakeGatewayFinalText("lifecycle-done");
  return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
}

function routeTool(body: string): Response {
  const user = lastUserText(body);
  const results = resultsSinceLastUser(body);
  if (user.includes(TOOL_PROMPT)) {
    if (results.length === 0) {
      return fakeGatewayToolCall("write-note", "write_file", { path: "note.txt", content: "note" });
    }
    return fakeGatewayFinalText("tool-done");
  }
  return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
}

function readEvents(marker: string): string[] {
  return readFileSync(marker, "utf8").split("\n").filter((line) => line.length > 0);
}

describe("session lifecycle hooks in headless ask", () => {
  test(
    "SessionStart receives the session identity fields on stdin",
    async () => {
      const layout = createRoot((marker) => [
        { event: "SessionStart", command: `cat > ${marker}` },
      ]);
      const gateway = serveFakeGateway(routeFinal, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const result = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway, "yolo"),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `no hook wrote ${layout.marker}; stderr: ${result.stderr}`).toBe(true);
      const payload = JSON.parse(readFileSync(layout.marker, "utf8")) as Record<string, unknown>;
      expect(payload.hook_event_name).toBe("SessionStart");
      expect(typeof payload.session_id).toBe("string");
      expect(payload.cwd).toBe(layout.workspace);
    },
    TIMEOUT,
  );

  test(
    "SessionEnd runs as a user hook after the headless ask completes",
    async () => {
      const layout = createRoot((marker) => [
        { event: "SessionStart", command: `printf 'SessionStart\\n' >> ${marker}` },
        { event: "SessionEnd", command: `printf 'SessionEnd\\n' >> ${marker}` },
      ]);
      const gateway = serveFakeGateway(routeFinal, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const result = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway, "yolo"),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("lifecycle-done");
      expect(readEvents(layout.marker)).toEqual(["SessionStart", "SessionEnd"]);
    },
    TIMEOUT,
  );

  test(
    "PermissionRequest and PermissionResult bracket a configured-ask tool call",
    async () => {
      const layout = createRoot(
        (marker) => [
          { event: "PermissionRequest", command: `printf 'PermissionRequest\\n' >> ${marker}` },
          { event: "PermissionResult", command: `printf 'PermissionResult\\n' >> ${marker}` },
        ],
        { write_file: { "*": "ask" } },
      );
      const gateway = serveFakeGateway(routeTool, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const result = await runFx(["ask", "--quiet", "--json", TOOL_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway, "default"),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(layout.marker), `no permission hook wrote ${layout.marker}; stderr: ${result.stderr}`).toBe(true);
      const events = readEvents(layout.marker);
      expect(events[0]).toBe("PermissionRequest");
      expect(events.at(-1)).toBe("PermissionResult");
    },
    TIMEOUT,
  );
});
