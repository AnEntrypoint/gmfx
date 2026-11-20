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
const TIMEOUT = 120_000;
const MODEL = "openai/gpt-5";
const PROJECT = "witness-root";
const START_PROMPT = "WITNESS-START: start witness-root and run the first step";
const ROOT_FIRST = "WITNESS-ROOT-FIRST: reply with the first step report";
const ROOT_SECOND = "WITNESS-ROOT-SECOND: continue on the saved session and reply with the second step report";
const FIRST_REPORT = "REPORT: finished — step one done — witness: 1 pass";
const SECOND_REPORT = "REPORT: finished — step two done — witness: 2 pass";
const SUPERAGENT_DONE = "WITNESS-SUPERAGENT-DONE";
const SUPERAGENT_WAITING = "WITNESS-SUPERAGENT-WAITING";
const CONTINUED = "WITNESS-CONTINUED";

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

function resultText(part: Record<string, unknown>): string {
  return JSON.stringify(part.output ?? part);
}

function sessionFromEvent(event: string): string {
  return /session=(\S*)/.exec(event)?.[1] ?? "";
}

function createLayout() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-witness-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(join(project, ".git"), { recursive: true });
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

function startSession(layout: Layout, gateway: { baseUrl: string; chatUrl: string }): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${layout.stderrPath}`,
    cwd: layout.workspace,
    env: {
      HOME: layout.home,
      AI_GATEWAY_API_KEY: "fake-superagent-witness-key",
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

describe.skipIf(SKIP)("superagent live witness: start, REPORT event, continue on session, status", () => {
  test(
    "a root ends its turn with a REPORT line, the superagent continues it on the same session and reads status once",
    async () => {
      const layout = createLayout();
      const seen: Record<string, string[]> = {};
      const rootPrompts: string[] = [];
      let sessionId = "";
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(ROOT_SECOND)) {
          rootPrompts.push("second");
          return fakeGatewayFinalText(SECOND_REPORT);
        }
        if (user.includes(ROOT_FIRST)) {
          rootPrompts.push("first");
          return fakeGatewayFinalText(FIRST_REPORT);
        }
        const last = resultsSinceLastUser(body).at(-1);
        if (user.includes(START_PROMPT)) {
          if (!last) return fakeGatewayToolCall("w-start", "superagent", { action: "start", agent: PROJECT });
          (seen["w-start"] ??= []).push(resultText(last));
          return fakeGatewayToolCall("w-instruct-1", "superagent", { action: "instruct", agent: PROJECT, prompt: ROOT_FIRST });
        }
        if (user.includes("superagent event: root") && user.includes("step one done")) {
          sessionId = sessionFromEvent(user);
          (seen.event1 ??= []).push(user);
          if (!last) return fakeGatewayToolCall("w-start-2", "superagent", { action: "start", agent: PROJECT, session: sessionId });
          (seen["w-start-2"] ??= []).push(resultText(last));
          return fakeGatewayToolCall("w-instruct-2", "superagent", { action: "instruct", agent: PROJECT, prompt: ROOT_SECOND });
        }
        if (user.includes("superagent event: root") && user.includes("step two done")) {
          (seen.event2 ??= []).push(user);
          if (!last) return fakeGatewayToolCall("w-status", "superagent", { action: "status" });
          (seen["w-status"] ??= []).push(resultText(last));
          return fakeGatewayFinalText(SUPERAGENT_DONE);
        }
        if (user.includes("superagent event: root") && user.includes("is gone")) {
          return fakeGatewayFinalText(CONTINUED);
        }
        if (last && String(last.toolCallId) === "w-instruct-1") return fakeGatewayFinalText(SUPERAGENT_WAITING);
        if (last && String(last.toolCallId) === "w-instruct-2") return fakeGatewayFinalText(CONTINUED);
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      session = await startSession(layout, gateway);
      await session.waitForComposer(TIMEOUT);
      await session.sendText(START_PROMPT);
      await session.waitForText(SUPERAGENT_DONE, TIMEOUT - 30_000).catch(async (error) => {
        throw new Error(`${String(error)}\nPANE:\n${await session!.capturePane()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nSEEN: ${JSON.stringify(seen)}\nROOT: ${rootPrompts.join(",")}`);
      });

      const started = seen["w-start"]?.[0] ?? "";
      const continued = seen["w-start-2"]?.[0] ?? "";
      const status = seen["w-status"]?.[0] ?? "";
      const firstEvent = seen.event1?.[0] ?? "";
      const secondEvent = seen.event2?.[0] ?? "";
      expect(started, `start result: ${started}`).toContain(layout.project);
      expect(firstEvent, "first turn-end event carries the REPORT line").toContain(FIRST_REPORT);
      expect(sessionId, "the event names the saved session id").not.toBe("");
      expect(continued, `continuation start on the saved session: ${continued}`).toContain(sessionId);
      expect(secondEvent, "second turn-end event carries the REPORT line").toContain(SECOND_REPORT);
      expect([...new Set(rootPrompts)]).toEqual(["first", "second"]);
      expect(rootPrompts.indexOf("first")).toBeLessThan(rootPrompts.indexOf("second"));
      expect(status, `one status read: ${status}`).toContain(PROJECT);
      expect(readFileSync(layout.stderrPath, "utf8")).toBe("");

      const witness = [
        `WITNESS start: ${started}`,
        `WITNESS event 1 REPORT: ${FIRST_REPORT}`,
        `WITNESS session: ${sessionId}`,
        `WITNESS event 2 REPORT: ${SECOND_REPORT}`,
        `WITNESS status: ${status}`,
      ].join("\n");
      writeFileSync(join(layout.home, "..", "superagent-witness.txt"), witness);
      console.log(witness);
    },
    TIMEOUT,
  );
});
