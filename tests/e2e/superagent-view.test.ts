import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  LIST_VERBS_BODY,
  runCodeVerbNames,
  serveFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 90_000;
const MODEL = "openai/gpt-5";
const PROJECT = "viewproj";
const FILES = 6;
const TOOL_MARKER = "VIEW-TOOL-OUTPUT";
const OWNER_PROMPT = "VIEW-OWNER: start viewproj and send it the task";
const PEER_TASK = "VIEW-TASK: read every file in this project and reply VIEW-FINAL-ANSWER";
const FINAL_ANSWER = "VIEW-FINAL-ANSWER";
const WAITING = "view waiting for the turn-end event";
const ACKED = "view event received";
const EVENT_PREFIX = "superagent event: root viewproj finished its turn";
const LINKED_PROJECT = "linked-viewproj";
const LIST_PROMPT = "VIEW-LIST: what superagent projects do you see?";
const LISTED = "view projects listed";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let session: TmuxSession | undefined;

afterEach(async () => {
  if (session) {
    await session.kill();
    session = undefined;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Message = { role?: string; content?: unknown };

function messages(body: string): Message[] {
  const request = JSON.parse(body) as { prompt?: Message[] };
  return request.prompt ?? [];
}

function lastUserText(body: string): string {
  const last = messages(body).filter((message) => message.role === "user").at(-1);
  if (!last) return "";
  return typeof last.content === "string" ? last.content : JSON.stringify(last.content ?? "");
}

function resultsSinceLastUser(body: string): Record<string, unknown>[] {
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
    });
}

function advertisedToolNames(body: string): string[] {
  const request = JSON.parse(body) as { tools?: Array<{ name?: unknown }> };
  return (request.tools ?? []).map((tool) => String(tool.name ?? ""));
}

function createLayout() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-view-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(project, { recursive: true });
  for (let index = 0; index < FILES; index += 1) {
    writeFileSync(join(project, `file-${index}.txt`), `${TOOL_MARKER}-${index}\n`);
  }
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  writeFileSync(join(root, "stderr.log"), "");
  return {
    home,
    workspace: realpathSync(workspace),
    project: realpathSync(project),
    stderrPath: join(root, "stderr.log"),
    tracePath: join(root, "trace.log"),
  };
}

type Layout = ReturnType<typeof createLayout>;

function traceTail(path: string): string {
  if (!existsSync(path)) return "(no trace)";
  const lines = readFileSync(path, "utf8").split("\n");
  const interesting = lines.filter((line) => /superagent|peer|enqueue|mail|report|child|panic|error/i.test(line));
  return [...interesting.slice(-60), "--- last lines ---", ...lines.slice(-12)].join("\n");
}

function startSession(layout: Layout, gateway: { baseUrl: string; chatUrl: string }): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${layout.stderrPath}`,
    cwd: layout.workspace,
    env: {
      HOME: layout.home,
      AI_GATEWAY_API_KEY: "fake-superagent-view-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_PERMISSION_MODE: "yolo",
      FX_AUTO_UPGRADE: "0",
      NO_COLOR: "1",
      FX_TRACE: "1",
      FX_TRACE_LOG: layout.tracePath,
    },
    width: 120,
    height: 40,
  });
}

describe.skipIf(SKIP)("superagent sees a root through its final response and status", () => {
  test(
    "a root's many tool calls stay out of the superagent's context; only the turn-end event carries the reply",
    async () => {
      const layout = createLayout();
      const superagentBodies: string[] = [];
      let peerToolResults = 0;
      let advertised: string[] = [];
      let verbs: string[] = [];
      let eventBody = "";
      let eventText = "";
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          const results = resultsSinceLastUser(body);
          peerToolResults = Math.max(peerToolResults, results.length);
          if (results.length < FILES) {
            return fakeGatewayToolCall(`view-read-${results.length}`, "read_file", { path: `file-${results.length}.txt` });
          }
          return fakeGatewayFinalText(FINAL_ANSWER);
        }
        superagentBodies.push(body);
        if (user.includes(EVENT_PREFIX)) {
          eventBody = body;
          eventText = user;
          return fakeGatewayFinalText(ACKED);
        }
        if (user.includes(OWNER_PROMPT)) {
          const last = resultsSinceLastUser(body).at(-1);
          if (!last) {
            advertised = advertisedToolNames(body);
            return fakeGatewayToolCall("view-verbs", "run_code", LIST_VERBS_BODY);
          }
          if (String(last.toolCallId) === "view-verbs") {
            verbs = runCodeVerbNames(last);
            return fakeGatewayToolCall("view-start", "superagent", { action: "start", agent: PROJECT });
          }
          if (String(last.toolCallId) === "view-start") {
            return fakeGatewayToolCall("view-instruct", "superagent", { action: "instruct", agent: PROJECT, prompt: PEER_TASK });
          }
          if (String(last.toolCallId) === "view-instruct") return fakeGatewayFinalText(WAITING);
        }
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      session = await startSession(layout, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText(OWNER_PROMPT);
      await session.waitForText(ACKED, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nTRACE: ${traceTail(layout.tracePath)}`);
      });

      expect(advertised, "the owner's first request offers run_code alone").toEqual(["run_code"]);
      expect(verbs, "the superagent tool is a verb with no skill loaded").toContain("superagent");
      expect(peerToolResults, "the root made one read_file call per file").toBe(FILES);
      expect(superagentBodies.length, "the superagent was asked more than once").toBeGreaterThan(2);
      for (const body of superagentBodies) {
        expect(body.includes(TOOL_MARKER), "no root tool output reached the superagent's context").toBe(false);
      }
      expect(eventBody.length, "the turn-end event reached the superagent").toBeGreaterThan(0);
      expect(eventText, `event: ${eventText}`).toContain(FINAL_ANSWER);
      expect(eventText, `event carries the state line: ${eventText}`).toContain("alive=true");
      expect(eventText).not.toContain(TOOL_MARKER);
      expect(readFileSync(layout.stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "list_projects shows a project folder that is a symlink beside the workspace",
    async () => {
      const layout = createLayout();
      const target = join(layout.project, "..", "linked-target");
      mkdirSync(target, { recursive: true });
      symlinkSync(target, join(layout.project, "..", LINKED_PROJECT));
      let listed = "";
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(LIST_PROMPT)) {
          const last = resultsSinceLastUser(body).at(-1);
          if (!last) return fakeGatewayToolCall("view-list", "superagent", { action: "list_projects" });
          listed = JSON.stringify(last.output ?? last);
          return fakeGatewayFinalText(LISTED);
        }
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      session = await startSession(layout, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText(LIST_PROMPT);
      await session.waitForText(LISTED, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}`);
      });

      expect(listed, `list_projects result: ${listed}`).toContain(LINKED_PROJECT);
      expect(listed).toContain(PROJECT);
      expect(readFileSync(layout.stderrPath, "utf8")).toBe("");
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );
});
