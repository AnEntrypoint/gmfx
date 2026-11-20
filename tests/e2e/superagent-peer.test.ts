import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  serveFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 90_000;
const MODEL = "openai/gpt-5";
const PROJECT = "nygrok";
const LATE_PROJECT = "late-project";
const README_MARKER = "NYGROK-README-MARKER combine pages and terminals";
const PEER_TASK = "PEER-TASK: read README.md in this project and reply peer-pong";
const LIST_PROMPT = "what superagent projects do you see?";
const START_PROMPT = "lets start up nygrok and get it to combine all the features from ../sharesies so that it can do pages and terminals";
const RELIST_PROMPT = "the new folder is there now, check the superagent folders again";
const LATE_PROMPT = "start up late-project";
const LISTED = "projects listed";
const RELISTED = "projects relisted";
const DONE = "superagent witness done";
const LATE_DONE = "late project started";
const WAITING = "waiting for the peer's turn-end event";
const GONE_ACK = "root gone event seen";

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

function allToolResults(body: string): Record<string, unknown>[] {
  return messages(body)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry): entry is Record<string, unknown> => {
      return typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result";
    });
}

function resultText(part: Record<string, unknown>): string {
  return JSON.stringify(part.output ?? part);
}

function createLayout() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-peer-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(join(project, ".git"), { recursive: true });
  mkdirSync(join(root, "sharesies"), { recursive: true });
  writeFileSync(join(project, "README.md"), `${README_MARKER}\n`);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  writeFileSync(join(root, "stderr.log"), "");
  return {
    root: realpathSync(root),
    home,
    workspace: realpathSync(workspace),
    project: realpathSync(project),
    stderrPath: join(root, "stderr.log"),
    tracePath: join(root, "trace.log"),
  };
}

type Layout = ReturnType<typeof createLayout>;

function startSession(layout: Layout, gateway: { baseUrl: string; chatUrl: string }): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${layout.stderrPath}`,
    cwd: layout.workspace,
    env: {
      HOME: layout.home,
      AI_GATEWAY_API_KEY: "fake-superagent-peer-key",
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

function traceTail(path: string): string {
  if (!existsSync(path)) return "(no trace)";
  const lines = readFileSync(path, "utf8").split("\n");
  const interesting = lines.filter((line) => /superagent|peer|enqueue|worker|panic|error/i.test(line));
  return [...interesting.slice(-60), "--- last lines ---", ...lines.slice(-12)].join("\n");
}

describe.skipIf(SKIP)("superagent drives a persistent project root", () => {
  test(
    "list projects, start the named project, instruct it, read its status and stop it without a crash",
    async () => {
      const layout = createLayout();
      const seen: Record<string, string[]> = {};
      const peerRead: string[] = [];
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          const results = resultsSinceLastUser(body);
          if (results.length === 0) return fakeGatewayToolCall("peer-read", "read_file", { path: "README.md" });
          peerRead.push(resultText(results[0]!));
          return fakeGatewayFinalText("peer-pong");
        }
        const last = resultsSinceLastUser(body).at(-1);
        if (user.includes(LIST_PROMPT)) {
          if (!last) return fakeGatewayToolCall("sa-list", "superagent", { action: "list_projects" });
          (seen["sa-list"] ??= []).push(resultText(last));
          return fakeGatewayFinalText(LISTED);
        }
        const stopResult = allToolResults(body).find((part) => String(part.toolCallId) === "sa-stop");
        if (stopResult) {
          (seen["sa-stop"] ??= []).push(resultText(stopResult));
          return fakeGatewayFinalText(DONE);
        }
        if (user.includes("superagent event: root ")) {
          if (user.includes("is gone")) return fakeGatewayFinalText(GONE_ACK);
          (seen.event ??= []).push(user);
          return fakeGatewayToolCall("sa-stop", "superagent", { action: "stop", agent: PROJECT });
        }
        if (user.includes(START_PROMPT)) {
          if (!last) return fakeGatewayToolCall("sa-start", "superagent", { action: "start", agent: PROJECT });
          const id = String(last.toolCallId);
          (seen[id] ??= []).push(resultText(last));
          if (id === "sa-start") {
            return fakeGatewayToolCall("sa-instruct", "superagent", { action: "instruct", agent: PROJECT, prompt: PEER_TASK });
          }
          if (id === "sa-instruct") return fakeGatewayFinalText(WAITING);
        }
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      session = await startSession(layout, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText(LIST_PROMPT);
      await session.waitForText(LISTED, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nTRACE: ${traceTail(layout.tracePath)}`);
      });
      await session.sendText(START_PROMPT);
      await session.waitForText(DONE, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nALIVE: ${session!.isAlive()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nTRACE: ${traceTail(layout.tracePath)}\nSEEN: ${JSON.stringify(seen)}`);
      });

      const listed = seen["sa-list"]?.[0] ?? "";
      const started = seen["sa-start"]?.[0] ?? "";
      const instructed = seen["sa-instruct"]?.[0] ?? "";
      const eventText = seen.event?.[0] ?? "";
      const stopped = seen["sa-stop"]?.[0] ?? "";
      expect(listed, `list_projects result: ${listed}`).toContain(PROJECT);
      expect(started, `start result: ${started}`).toContain(layout.project);
      expect(started).not.toContain("not found");
      expect(instructed, `instruct result: ${instructed}`).toContain("queued");
      expect(eventText, `the turn-end event reached the superagent: ${eventText}`).toContain("finished its turn");
      expect(eventText, `the event carries the peer's final response: ${eventText}`).toContain("peer-pong");
      expect(eventText, `the event carries the state line: ${eventText}`).toContain("alive=true");
      expect(stopped, `stop result: ${stopped}`).toContain("stopped");
      expect(peerRead.length, "the peer read the project README").toBeGreaterThan(0);
      expect(peerRead[0], "the peer's workspace is the project folder").toContain(README_MARKER);
      const pane = await session.capturePane();
      expect(pane).not.toMatch(/\b\d+ subagents?\b/);
      expect(pane).toContain("superagent");
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(layout.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "a folder created after an earlier listing appears in a later list and starts by name",
    async () => {
      const layout = createLayout();
      const seen: Record<string, string[]> = {};
      const route = (body: string): Response => {
        const user = lastUserText(body);
        const last = resultsSinceLastUser(body).at(-1);
        if (user.includes(LATE_PROMPT)) {
          if (!last) return fakeGatewayToolCall("sa-start-late", "superagent", { action: "start", agent: LATE_PROJECT });
          (seen["sa-start-late"] ??= []).push(resultText(last));
          return fakeGatewayFinalText(LATE_DONE);
        }
        if (user.includes(RELIST_PROMPT)) {
          if (!last) return fakeGatewayToolCall("sa-list-2", "superagent", { action: "list_projects" });
          (seen["sa-list-2"] ??= []).push(resultText(last));
          return fakeGatewayFinalText(RELISTED);
        }
        if (user.includes(LIST_PROMPT)) {
          if (!last) return fakeGatewayToolCall("sa-list-1", "superagent", { action: "list_projects" });
          (seen["sa-list-1"] ??= []).push(resultText(last));
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
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nTRACE: ${traceTail(layout.tracePath)}`);
      });
      const lateProject = join(layout.root, LATE_PROJECT);
      mkdirSync(join(lateProject, ".git"), { recursive: true });
      await session.sendText(RELIST_PROMPT);
      await session.waitForText(RELISTED, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nSEEN: ${JSON.stringify(seen)}`);
      });
      await session.sendText(LATE_PROMPT);
      await session.waitForText(LATE_DONE, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nALIVE: ${session!.isAlive()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nTRACE: ${traceTail(layout.tracePath)}\nSEEN: ${JSON.stringify(seen)}`);
      });

      const firstList = seen["sa-list-1"]?.[0] ?? "";
      const secondList = seen["sa-list-2"]?.[0] ?? "";
      const started = seen["sa-start-late"]?.[0] ?? "";
      expect(firstList, `first list was taken before the folder existed: ${firstList}`).not.toContain(LATE_PROJECT);
      expect(secondList, `second list: ${secondList}`).toContain(LATE_PROJECT);
      expect(started, `start result: ${started}`).toContain(lateProject);
      expect(started).not.toContain("not found");
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(layout.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
