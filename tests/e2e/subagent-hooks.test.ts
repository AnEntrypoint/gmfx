import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, fakeGatewayToolCall, LIST_VERBS_BODY, runCodeVerbNames, serveFakeGateway } from "./tmux-helpers";

const TIMEOUT = 60_000;
const MODEL = "openai/gpt-5";
const MAIN_PROMPT = "Hand the CHILD-TASK to a subagent and report what it says.";
const CHILD_TASK = "CHILD-TASK: reply with the word child-done";
const advertisedTools: string[][] = [];
const listedVerbs: string[][] = [];

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

function createRoot(hooks: unknown) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-subagent-hooks-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const marker = join(root, "hook-events.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission: {}, hooks: hooks(marker) }),
  );
  return { home, workspace: realpathSync(workspace), marker };
}

function gatewayEnv(home: string, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-subagent-hooks-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "yolo",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function advertisedToolNames(body: string): string[] {
  const request = JSON.parse(body) as { tools?: Array<{ name?: unknown }> };
  return (request.tools ?? []).map((tool) => String(tool.name ?? ""));
}

function route(body: string): Response {
  const user = lastUserText(body);
  const results = resultsSinceLastUser(body);
  if (user.includes(CHILD_TASK)) return fakeGatewayFinalText("child-done");
  if (user.includes(MAIN_PROMPT)) {
    if (results.length === 0) {
      advertisedTools.push(advertisedToolNames(body));
      return fakeGatewayToolCall("list-verbs", "run_code", LIST_VERBS_BODY);
    }
    if (results.length === 1) {
      listedVerbs.push(runCodeVerbNames(results[0]));
      return fakeGatewayToolCall("agent-child", "Agent", {
        prompt: CHILD_TASK,
        description: "child task",
        subagent_type: "explore",
      });
    }
    return fakeGatewayFinalText("main-done");
  }
  return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
}

describe("subagent lifecycle hooks in headless ask", () => {
  test(
    "SubagentStart and SubagentStop run as user hooks around a subagent run",
    async () => {
      const layout = createRoot((marker) => [
        { event: "SubagentStart", command: `printf 'SubagentStart\\n' >> ${marker}` },
        { event: "SubagentStop", command: `printf 'SubagentStop\\n' >> ${marker}` },
      ]);
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const result = await runFx(["ask", "--quiet", "--json", MAIN_PROMPT], {
        cwd: layout.workspace,
        env: gatewayEnv(layout.home, gateway),
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("main-done");
      expect(existsSync(layout.marker), `no hook wrote ${layout.marker}; stderr: ${result.stderr}`).toBe(true);
      const events = readFileSync(layout.marker, "utf8").split("\n").filter((line) => line.length > 0);
      expect(events).toEqual(["SubagentStart", "SubagentStop"]);
      expect(advertisedTools.length, "the main request was seen").toBeGreaterThan(0);
      expect(advertisedTools[0], "run_code alone is offered to the model").toEqual(["run_code"]);
      expect(listedVerbs[0], "Agent is reachable as a verb").toContain("Agent");
      expect(listedVerbs[0], "AgentSwarm is not a verb: it is not available in this runtime").not.toContain("AgentSwarm");
    },
    TIMEOUT,
  );
});
