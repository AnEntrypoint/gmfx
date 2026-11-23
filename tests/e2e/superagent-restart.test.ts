import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  serveFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 120_000;
const STEP = 60_000;
const MODEL = "openai/gpt-5";
const PROJECT = "cutproj";
const OWNER_PROMPT = "CUT-OWNER: start cutproj and send it the task";
const PEER_TASK = "CUT-TASK: do the long work and reply CUT-FINAL-ANSWER";
const FINAL_ANSWER = "CUT-FINAL-ANSWER";
const WAITING = "cut waiting for the turn-end event";
const RESTART_SEEN = "cut restart event received";
const TURN_SEEN = "cut turn event received";
const BLOCKED_SEEN = "cut blocked event received";
const RESTART_EVENT = "superagent event: fx restarted after its last run was cut";
const TURN_EVENT = `superagent event: root ${PROJECT} finished its turn`;
const BLOCKED_EVENT = `superagent event: root ${PROJECT} is blocked and waits for its owner`;
const CUT_NOTE = "cut it without warning";

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

function lastUserText(body: string): string {
  const last = messages(body).filter((message) => message.role === "user").at(-1);
  if (!last) return "";
  return typeof last.content === "string" ? last.content : JSON.stringify(last.content ?? "");
}

function lastToolResultId(body: string): string | undefined {
  const all = messages(body);
  let lastUser = -1;
  all.forEach((message, index) => {
    if (message.role === "user") lastUser = index;
  });
  const results = all
    .slice(lastUser + 1)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry): entry is Record<string, unknown> => {
      return typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result";
    });
  const last = results.at(-1);
  return last ? String(last.toolCallId) : undefined;
}

function createLayout() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-restart-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(project, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  return {
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
      AI_GATEWAY_API_KEY: "fake-superagent-restart-key",
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

function ownerSteps(body: string): Response | null {
  const last = lastToolResultId(body);
  if (!last) return fakeGatewayVerbCall("cut-start", "superagent", { action: "start", agent: PROJECT });
  if (last === "cut-start") {
    return fakeGatewayVerbCall("cut-instruct", "superagent", { action: "instruct", agent: PROJECT, prompt: PEER_TASK });
  }
  if (last === "cut-instruct") return fakeGatewayFinalText(WAITING);
  return null;
}

function ledgerText(home: string): string {
  const dir = join(home, ".fx", "superagent");
  if (!existsSync(dir)) return "";
  return readdirSync(dir).map((name) => readFileSync(join(dir, name), "utf8")).join("\n");
}

async function waitUntil(check: () => boolean, what: string, timeoutMs = STEP) {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(100);
  }
}

function failureContext(layout: Layout, pane: string): string {
  const trace = existsSync(layout.tracePath) ? readFileSync(layout.tracePath, "utf8").split("\n").slice(-40).join("\n") : "(no trace)";
  return `PANE:\n${pane}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nLEDGER: ${ledgerText(layout.home)}\nTRACE: ${trace}`;
}

describe.skipIf(SKIP)("superagent roots across a cut and at a limit", () => {
  test(
    "a root cut mid-turn by a killed fx is brought back at the next start and runs its prompt again",
    async () => {
      const layout = createLayout();
      let peerRequestsBeforeCut = 0;
      const firstRoute = (body: string): Response | Promise<Response> => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          peerRequestsBeforeCut += 1;
          return new Promise<Response>(() => {});
        }
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body) ?? fakeGatewayFinalText("unexpected owner step");
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const firstGateway = serveFakeGateway(firstRoute, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(firstGateway);

      const first = await startSession(layout, firstGateway);
      await first.waitForComposer(STEP);
      await first.sendText(OWNER_PROMPT);
      await first.waitForText(WAITING, STEP);
      await waitUntil(() => peerRequestsBeforeCut > 0, "the root's request");
      await waitUntil(() => /"in_flight":true/.test(ledgerText(layout.home)) && /"main_session":"[^"]+"/.test(ledgerText(layout.home)), "the ledger to hold the in-flight root and the superagent session");
      const ledgerBeforeCut = ledgerText(layout.home);
      expect(ledgerBeforeCut).toContain(`"agent":"${PROJECT}"`);
      expect(ledgerBeforeCut).toContain(PEER_TASK);

      process.kill(first.processPid(), "SIGKILL");
      await waitUntil(() => !first.isAlive(), "the killed fx to be gone");

      let restartEvent = "";
      let resumedPeerPrompt = "";
      let turnEvent = "";
      const secondRoute = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          resumedPeerPrompt = user;
          return fakeGatewayFinalText(FINAL_ANSWER);
        }
        if (user.includes(RESTART_EVENT)) {
          restartEvent = user;
          return fakeGatewayFinalText(RESTART_SEEN);
        }
        if (user.includes(TURN_EVENT)) {
          turnEvent = user;
          return fakeGatewayFinalText(TURN_SEEN);
        }
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const secondGateway = serveFakeGateway(secondRoute, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(secondGateway);

      const second = await startSession(layout, secondGateway);
      await waitUntil(() => restartEvent.length > 0 && turnEvent.length > 0, "the restart event and the resumed root's turn end", TIMEOUT - 40_000).catch(async (error) => {
        throw new Error(`${String(error)}\n${failureContext(layout, await second.capturePane())}`);
      });

      expect(restartEvent).toContain(`- ${PROJECT} `);
      expect(restartEvent).toContain("was cut mid-turn");
      expect(resumedPeerPrompt).toContain(CUT_NOTE);
      expect(resumedPeerPrompt).toContain(PEER_TASK);
      expect(turnEvent).toContain(FINAL_ANSWER);
      const pane = await second.capturePane();
      expect(pane, "the superagent's own session came back with its earlier turn").toContain(WAITING);
      expect(second.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "leaving fx with /exit releases the ledger, so the next start resumes nothing",
    async () => {
      const layout = createLayout();
      let peerRequests = 0;
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          peerRequests += 1;
          return fakeGatewayFinalText(FINAL_ANSWER);
        }
        if (user.includes(TURN_EVENT)) return fakeGatewayFinalText(TURN_SEEN);
        if (user.includes(RESTART_EVENT)) return fakeGatewayFinalText(RESTART_SEEN);
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body) ?? fakeGatewayFinalText("unexpected owner step");
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const first = await startSession(layout, gateway);
      await first.waitForComposer(STEP);
      await first.sendText(OWNER_PROMPT);
      await first.waitForText(TURN_SEEN, STEP);
      await first.sendText("/exit");
      await waitUntil(() => !first.isAlive(), "fx to exit");
      expect(ledgerText(layout.home)).toContain('"host_pid":0');

      const requestsBefore = gateway.requests.length;
      const second = await startSession(layout, gateway);
      await second.waitForComposer(STEP);
      await Bun.sleep(1_500);
      expect(gateway.requests.length).toBe(requestsBefore);
      expect(peerRequests).toBe(1);
      expect(await second.capturePane()).not.toContain(RESTART_SEEN);
    },
    TIMEOUT,
  );

  test(
    "a root whose request ends on a credit limit comes back to the superagent as blocked",
    async () => {
      const layout = createLayout();
      let blockedEvent = "";
      const route = (body: string): Response => {
        const user = lastUserText(body);
        if (user.includes(PEER_TASK)) {
          return new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "The account has no credits left." } }), {
            status: 402,
            headers: { "content-type": "application/json" },
          });
        }
        if (user.includes(BLOCKED_EVENT)) {
          blockedEvent = user;
          return fakeGatewayFinalText(BLOCKED_SEEN);
        }
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body) ?? fakeGatewayFinalText("unexpected owner step");
        return fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
      };
      const gateway = serveFakeGateway(route, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      gateways.push(gateway);

      const session = await startSession(layout, gateway);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await session.waitForText(BLOCKED_SEEN, STEP).catch(async (error) => {
        throw new Error(`${String(error)}\n${failureContext(layout, await session.capturePane())}`);
      });
      expect(blockedEvent).toContain(" blocked alive=true");
      expect(blockedEvent).toContain("Out of credits");
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );
});
