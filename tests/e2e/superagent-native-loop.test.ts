import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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
const STEP = 60_000;
const MODEL = "openai/gpt-5";
const PROJECT = "loopproj";
const OWNER_PROMPT = "LOOP-OWNER: start loopproj and send it the queue";
const ITEM_ONE = "LOOP-ITEM-ONE: do the first item";
const ITEM_TWO = "LOOP-ITEM-TWO: do the second item";
const ITEM_THREE = "LOOP-ITEM-THREE: do one more item on the saved session";
const WAITING = "loop waiting for the root event";
const EVENT_SEEN = "loop event received";
const FINISHED_EVENT = `superagent event: root ${PROJECT} finished its turn`;
const OWNER_EVENT = `superagent event: root ${PROJECT} needs its owner`;
const DIED_EVENT = `superagent event: root ${PROJECT} died without a stop: its instance was closed`;
const LIST_HINT = "enter switch";

async function showNextAgent(session: TmuxSession) {
  await session.sendKeys("C-x");
  const pane = await session.waitForText(LIST_HINT, 10_000);
  const lines = pane.split("\n");
  const hint = lines.findIndex((line) => line.includes(LIST_HINT));
  let top = hint - 2;
  while (top > 0 && !lines[top - 1]!.trimStart().startsWith("\u2500")) top -= 1;
  const rows = lines.slice(top, hint - 1);
  const from = rows.findIndex((row) => row.includes("(on screen)"));
  if (from < 0 || rows.length < 2) throw new Error(`no agent list in:\n${pane}`);
  const to = (from + 1) % rows.length;
  for (let step = 0; step < Math.abs(to - from); step += 1) await session.sendKeys(to > from ? "Down" : "Up");
  await session.sendKeys("Enter");
  await session.waitForPane((value) => !value.includes(LIST_HINT), 10_000);
}

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

function createLayout(settings: Record<string, unknown> = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-superagent-loop-e2e-")));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "sa");
  const project = join(root, PROJECT);
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(project, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {}, ...settings }));
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
      AI_GATEWAY_API_KEY: "fake-superagent-loop-key",
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

function ownerSteps(body: string, instruct: Record<string, unknown>): Response | null {
  const last = lastToolResultId(body);
  if (!last) return fakeGatewayToolCall("loop-start", "superagent", { action: "start", agent: PROJECT });
  if (last === "loop-start") {
    return fakeGatewayToolCall("loop-instruct", "superagent", { action: "instruct", agent: PROJECT, ...instruct });
  }
  if (last === "loop-instruct") return fakeGatewayFinalText(WAITING);
  return null;
}

function journalLines(home: string): Array<Record<string, unknown>> {
  const dir = join(home, ".fx", "superagent");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".journal.jsonl"))
    .flatMap((name) => readFileSync(join(dir, name), "utf8").split("\n"))
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

function ledgerText(home: string): string {
  const dir = join(home, ".fx", "superagent");
  if (!existsSync(dir)) return "";
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => readFileSync(join(dir, name), "utf8"))
    .join("\n");
}

function rawJournal(home: string): string {
  return journalLines(home)
    .map((line) => JSON.stringify(line))
    .join("\n");
}

async function waitUntil(check: () => boolean, what: string, context: () => Promise<string>, timeoutMs = STEP) {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}\n${await context()}`);
    await Bun.sleep(100);
  }
}

function contextOf(layout: Layout, session: TmuxSession, seen: string[]): () => Promise<string> {
  return async () => {
    const trace = existsSync(layout.tracePath) ? readFileSync(layout.tracePath, "utf8").split("\n").slice(-30).join("\n") : "(no trace)";
    return `PANE:\n${await session.capturePane()}\nSTDERR: ${readFileSync(layout.stderrPath, "utf8")}\nJOURNAL:\n${rawJournal(layout.home)}\nREQUESTS:\n${seen.join("\n")}\nTRACE: ${trace}`;
  };
}

function serve(route: (body: string, user: string) => Response | Promise<Response> | null, seen: string[]) {
  const gateway = serveFakeGateway(
    (body: string) => {
      const user = lastUserText(body);
      seen.push(user.slice(0, 160).replaceAll("\n", " | "));
      return route(body, user) ?? fakeGatewayFinalText(`unexpected prompt: ${user.slice(0, 80)}`);
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  gateways.push(gateway);
  return gateway;
}

describe.skipIf(SKIP)("the superagent loop runs in fx's own code", () => {
  test(
    "a finished root with a queued item is continued on its session with no model turn of the owner in between, then stopped",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let ownerRequests = 0;
      let ownerRequestsWhenItemTwoArrived = -1;
      let itemTwoHistory = "";
      let event = "";
      const gateway = serve((body, user) => {
        if (user.includes(ITEM_ONE)) return fakeGatewayFinalText("first done\nREPORT: finished — item one done — witness: 1 pass");
        if (user.includes(ITEM_TWO)) {
          ownerRequestsWhenItemTwoArrived = ownerRequests;
          itemTwoHistory = messages(body).map(textOf).join("\n");
          return fakeGatewayFinalText("second done\nREPORT: finished — item two done — witness: 2 pass");
        }
        ownerRequests += 1;
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE, queue: [ITEM_TWO] });
        if (user.includes(FINISHED_EVENT)) {
          event = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await waitUntil(() => event.length > 0, "the one event after the queue ran out", context);

      expect(ownerRequestsWhenItemTwoArrived, "the owner's model made only its three dispatch requests before item two went out").toBe(3);
      expect(ownerRequests, "the owner's model woke once more, for the one event").toBe(4);
      expect(itemTwoHistory, "item two ran on the session that holds item one").toContain(ITEM_ONE);
      expect(event).toContain("fx carried this root through 1 earlier turn end(s) itself:");
      expect(event).toContain("- REPORT: finished — item one done — witness: 1 pass");
      expect(event).toContain("REPORT: finished — item two done — witness: 2 pass");
      expect(event).toContain(" stopped alive=false busy=false");

      const journal = journalLines(layout.home);
      const kinds = journal.map((line) => `${line.event}:${line.by}:${line.decision}`);
      expect(kinds).toEqual([
        "send:owner:",
        "turn_end:root:send_queued_item",
        "send:runtime:",
        "turn_end:root:stop_root",
        "stop:runtime:stop_root",
      ]);
      const runtimeSend = journal[2]!;
      expect(runtimeSend.text).toBe(ITEM_TWO);
      expect(runtimeSend.root).toBe(PROJECT);
      expect(runtimeSend.session).toBe(journal[0]!.session);
      console.log(`JOURNAL-LINE ${JSON.stringify(runtimeSend)}`);
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "an open report gets its next step from fx on the same session, and a report blocked twice goes to the owner",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let ownerRequests = 0;
      let openStep = "";
      let blockedStep = "";
      let event = "";
      const gateway = serve((body, user) => {
        if (user.includes("ended blocked")) {
          blockedStep = user;
          return fakeGatewayFinalText("REPORT: blocked — the owner must supply the deploy key");
        }
        if (user.includes("ended open")) {
          openStep = user;
          return fakeGatewayFinalText("REPORT: blocked — port 9000 is taken or a deploy key is missing");
        }
        if (user.includes(ITEM_ONE)) return fakeGatewayFinalText("half way\nREPORT: open — two rows left");
        ownerRequests += 1;
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE, queue: [ITEM_TWO] });
        if (user.includes(OWNER_EVENT)) {
          event = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await waitUntil(() => event.length > 0, "the event that hands the root to its owner", context);

      expect(openStep).toContain("REPORT: open — two rows left");
      expect(openStep).toContain("Carry on with the open items on this session");
      expect(blockedStep).toContain("REPORT: blocked — port 9000 is taken or a deploy key is missing");
      expect(ownerRequests).toBe(4);
      expect(event).toContain(" queued=1");
      expect(event).toContain("fx carried this root through 2 earlier turn end(s) itself:");
      expect(event).toContain("REPORT: blocked — the owner must supply the deploy key");
      expect(journalLines(layout.home).map((line) => `${line.event}:${line.decision}:${line.report}`)).toEqual([
        "send::",
        "turn_end:send_next_step:open",
        "send::",
        "turn_end:send_next_step:blocked",
        "send::",
        "turn_end:hand_to_owner:blocked",
      ]);
    },
    TIMEOUT,
  );

  test(
    "a root that ends its turn with a job still running is waited on once and continued with the job's result",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let jobResult = "";
      let event = "";
      let ownerRequestsBeforeJobResult = -1;
      let ownerRequests = 0;
      const gateway = serve((body, user) => {
        if (user.includes("The job your last turn left running has this result")) {
          jobResult = user;
          ownerRequestsBeforeJobResult = ownerRequests;
          return fakeGatewayFinalText("REPORT: finished — the job passed — witness: LOOP-JOB-OUT");
        }
        if (user.includes(ITEM_ONE)) {
          if (lastToolResultId(body) === "loop-job") return fakeGatewayFinalText("REPORT: open — the job is still running");
          return fakeGatewayToolCall("loop-job", "Bash", {
            command: "sleep 3; echo LOOP-JOB-OUT",
            description: "Run the slow job",
            run_in_background: true,
          });
        }
        ownerRequests += 1;
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE });
        if (user.includes(FINISHED_EVENT)) {
          event = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await waitUntil(() => event.length > 0, "the event after the job's result was handled", context);

      expect(jobResult).toContain("exit");
      expect(ownerRequestsBeforeJobResult).toBe(3);
      expect(event).toContain("- REPORT: open — the job is still running");
      expect(event).toContain("REPORT: finished — the job passed");
      const journal = journalLines(layout.home);
      expect(journal.map((line) => `${line.event}:${line.decision}`)).toEqual([
        "send:",
        "turn_end:wait_for_job",
        "wait:wait_for_job",
        "send:",
        "turn_end:stop_root",
        "stop:stop_root",
      ]);
      expect(String(journal[2]!.text)).toContain("tasks=1 pid=0");
    },
    TIMEOUT,
  );

  test(
    "a root that names a running process id in its report is waited on once by that id and continued when it exits",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      const job = Bun.spawn(["sleep", "4"], { stdout: "ignore", stderr: "ignore" });
      let jobResult = "";
      let event = "";
      let ownerRequests = 0;
      let ownerRequestsBeforeJobResult = -1;
      try {
        const gateway = serve((body, user) => {
          if (user.includes("The job your last turn left running has this result")) {
            jobResult = user;
            ownerRequestsBeforeJobResult = ownerRequests;
            return fakeGatewayFinalText("REPORT: finished — the outside job ended");
          }
          if (user.includes(ITEM_ONE)) return fakeGatewayFinalText(`REPORT: open — validation still running, PID ${job.pid}`);
          ownerRequests += 1;
          if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE });
          if (user.includes(FINISHED_EVENT)) {
            event = user;
            return fakeGatewayFinalText(EVENT_SEEN);
          }
          return null;
        }, seen);

        const session = await startSession(layout, gateway);
        const context = contextOf(layout, session, seen);
        await session.waitForComposer(STEP);
        await session.sendText(OWNER_PROMPT);
        await waitUntil(() => event.length > 0, "the event after the named process ended", context);

        expect(jobResult).toContain(`process ${job.pid} has exited`);
        expect(ownerRequestsBeforeJobResult).toBe(3);
        expect(job.exitCode, "the wait ended because the process ended, not before").toBe(0);
        const journal = journalLines(layout.home);
        expect(journal.map((line) => `${line.event}:${line.decision}`)).toEqual([
          "send:",
          "turn_end:wait_for_job",
          "wait:wait_for_job",
          "send:",
          "turn_end:stop_root",
          "stop:stop_root",
        ]);
        expect(String(journal[2]!.text)).toContain(`tasks=0 pid=${job.pid} `);
        expect(journal[3]!.by).toBe("runtime");
        const waitedMs = Number(journal[3]!.at_ms) - Number(journal[2]!.at_ms);
        expect(waitedMs, "the continuation went out only after the process had run").toBeGreaterThan(1500);
        console.log(`JOURNAL-WAIT ${JSON.stringify(journal[2])}`);
      } finally {
        job.kill();
      }
    },
    TIMEOUT,
  );

  test(
    "a queue that was waiting when fx was killed comes back from the ledger and is sent after the cut turn runs again",
    async () => {
      const layout = createLayout();
      const seenFirst: string[] = [];
      let itemOneRequests = 0;
      const firstGateway = serve((body, user) => {
        if (user.includes(ITEM_ONE)) {
          itemOneRequests += 1;
          return new Promise<Response>(() => {}) as unknown as Response;
        }
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE, queue: [ITEM_TWO] });
        return null;
      }, seenFirst);
      const first = await startSession(layout, firstGateway);
      const firstContext = contextOf(layout, first, seenFirst);
      await first.waitForComposer(STEP);
      await first.sendText(OWNER_PROMPT);
      await first.waitForText(WAITING, STEP);
      await waitUntil(() => itemOneRequests > 0, "the root's first request", firstContext);
      await waitUntil(
        () => /"in_flight":true/.test(ledgerText(layout.home)) && /"main_session":"[^"]+"/.test(ledgerText(layout.home)),
        "the ledger to hold the running root and the owner's session",
        firstContext,
      );
      expect(ledgerText(layout.home)).toContain(`"queue":["${ITEM_TWO}"]`);

      process.kill(first.processPid(), "SIGKILL");
      await waitUntil(() => !first.isAlive(), "the killed fx to be gone", firstContext);

      const seenSecond: string[] = [];
      let itemOneAgain = "";
      let itemTwo = "";
      let event = "";
      const secondGateway = serve((_body, user) => {
        if (user.includes(ITEM_TWO)) {
          itemTwo = user;
          return fakeGatewayFinalText("REPORT: finished — item two done after the restart");
        }
        if (user.includes(ITEM_ONE)) {
          itemOneAgain = user;
          return fakeGatewayFinalText("REPORT: finished — item one done after the restart");
        }
        if (user.includes(FINISHED_EVENT)) {
          event = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return fakeGatewayFinalText("restart noted");
      }, seenSecond);
      const second = await startSession(layout, secondGateway);
      const secondContext = contextOf(layout, second, seenSecond);
      await waitUntil(() => event.length > 0, "the stop event after the restored queue ran out", secondContext, TIMEOUT - 40_000);

      expect(itemOneAgain).toContain("cut it without warning");
      expect(itemTwo).toContain(ITEM_TWO);
      expect(event).toContain("REPORT: finished — item two done after the restart");
      const runtimeSends = journalLines(layout.home).filter((line) => line.event === "send" && line.by === "runtime");
      expect(runtimeSends.map((line) => line.text)).toContain(ITEM_TWO);
      expect(second.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "the job wait takes its time from task.root_job_wait_s and continues the root when that time runs out",
    async () => {
      const layout = createLayout({ task: { root_job_wait_s: 2 } });
      const seen: string[] = [];
      const job = Bun.spawn(["sleep", "40"], { stdout: "ignore", stderr: "ignore" });
      let jobResult = "";
      let event = "";
      try {
        const gateway = serve((body, user) => {
          if (user.includes("The job your last turn left running has this result")) {
            jobResult = user;
            return fakeGatewayFinalText("REPORT: finished — stopped waiting for the outside job");
          }
          if (user.includes(ITEM_ONE)) return fakeGatewayFinalText(`REPORT: open — a long job is running, PID ${job.pid}`);
          if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE });
          if (user.includes(FINISHED_EVENT)) {
            event = user;
            return fakeGatewayFinalText(EVENT_SEEN);
          }
          return null;
        }, seen);

        const session = await startSession(layout, gateway);
        const context = contextOf(layout, session, seen);
        await session.waitForComposer(STEP);
        await session.sendText(OWNER_PROMPT);
        await waitUntil(() => event.length > 0, "the event after the wait ran out", context);

        expect(jobResult).toContain(`process ${job.pid} was still running when the wait timed out`);
        expect(job.exitCode, "the job was left running").toBeNull();
        const journal = journalLines(layout.home);
        const wait = journal.find((line) => line.event === "wait")!;
        expect(String(wait.text)).toContain(`pid=${job.pid} timeout_ms=2000`);
        const resumed = journal[journal.indexOf(wait) + 1]!;
        const waitedMs = Number(resumed.at_ms) - Number(wait.at_ms);
        expect(waitedMs).toBeGreaterThanOrEqual(1900);
        expect(waitedMs).toBeLessThan(15_000);
      } finally {
        job.kill();
      }
    },
    TIMEOUT,
  );

  test(
    "a root whose instance is closed mid-turn posts a death event, is started again on its session, and its turn and queue follow",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let itemOneRequests = 0;
      let itemOneAgain = "";
      let itemTwo = "";
      let died = "";
      let finished = "";
      const gateway = serve((body, user) => {
        if (user.includes(ITEM_TWO)) {
          itemTwo = user;
          return fakeGatewayFinalText("REPORT: finished — item two done after the death");
        }
        if (user.includes(ITEM_ONE)) {
          itemOneRequests += 1;
          if (itemOneRequests === 1) return new Promise<Response>(() => {});
          itemOneAgain = user;
          return fakeGatewayFinalText("REPORT: finished — item one done after the death");
        }
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE, queue: [ITEM_TWO] });
        if (user.includes(DIED_EVENT)) {
          died = user;
          return fakeGatewayFinalText("death noted");
        }
        if (user.includes(FINISHED_EVENT)) {
          finished = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await session.waitForText(WAITING, STEP);
      await waitUntil(() => itemOneRequests === 1, "the root's first request", context);

      await showNextAgent(session);
      await session.waitForText(ITEM_ONE, STEP);
      await session.sendText("/close");
      await waitUntil(() => died.length > 0 && finished.length > 0, "the death event and the stop event after the queue", context, TIMEOUT - 40_000);

      expect(died).toContain("fx started it again on that session and sent its cut turn again");
      expect(died).toContain("queued=1");
      expect(itemOneAgain).toContain("cut it without warning");
      expect(itemTwo).toContain(ITEM_TWO);
      expect(finished).toContain("REPORT: finished — item two done after the death");
      const journal = journalLines(layout.home);
      const death = journal.find((line) => line.event === "stop" && line.by === "root")!;
      expect(death.decision).toBe("revive_and_send_again");
      expect(death.text).toBe("its instance was closed");
      const after = journal.slice(journal.indexOf(death) + 1).map((line) => `${line.event}:${line.by}`);
      expect(after.slice(0, 3)).toEqual(["send:restart", "turn_end:root", "send:runtime"]);
      expect(new Set(journal.map((line) => line.session)).size, "the root kept one saved session across its death").toBe(1);
      console.log(`JOURNAL-DEATH ${JSON.stringify(death)}`);
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "a root with no work whose instance is closed posts a death event and stays stopped",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let idleEvent = "";
      let died = "";
      const gateway = serve((body, user) => {
        if (user.includes(ITEM_ONE)) return fakeGatewayFinalText("a plain reply with no report line");
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE });
        if (user.includes(DIED_EVENT)) {
          died = user;
          return fakeGatewayFinalText("death noted");
        }
        if (user.includes(FINISHED_EVENT)) {
          idleEvent = user;
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await waitUntil(() => idleEvent.length > 0, "the idle event", context);
      expect(idleEvent).toContain(" idle alive=true busy=false");
      await session.waitForText(EVENT_SEEN, STEP);
      await session.waitForComposer(STEP);

      await showNextAgent(session);
      await session.waitForText("a plain reply with no report line", STEP);
      await session.sendText("/close");
      await waitUntil(() => died.length > 0, "the death event", context);

      expect(died).toContain("it is stopped; an instruct resumes that session");
      expect(died).toContain("queued=0");
      const death = journalLines(layout.home).find((line) => line.event === "stop" && line.by === "root")!;
      expect(death.decision).toBe("stay_stopped");
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "an instruct to a root that fx stopped resumes it on its saved session",
    async () => {
      const layout = createLayout();
      const seen: string[] = [];
      let events = 0;
      let itemThreeHistory = "";
      let lastEvent = "";
      const gateway = serve((body, user) => {
        if (user.includes(ITEM_ONE)) return fakeGatewayFinalText("REPORT: finished — item one done");
        if (user.includes(ITEM_THREE)) {
          itemThreeHistory = messages(body).map(textOf).join("\n");
          return fakeGatewayFinalText("REPORT: finished — item three done");
        }
        if (user.includes(OWNER_PROMPT)) return ownerSteps(body, { prompt: ITEM_ONE });
        if (user.includes(FINISHED_EVENT)) {
          if (lastToolResultId(body) === "loop-again") return fakeGatewayFinalText(WAITING);
          events += 1;
          lastEvent = user;
          if (events === 1) return fakeGatewayToolCall("loop-again", "superagent", { action: "instruct", agent: PROJECT, prompt: ITEM_THREE });
          return fakeGatewayFinalText(EVENT_SEEN);
        }
        return null;
      }, seen);

      const session = await startSession(layout, gateway);
      const context = contextOf(layout, session, seen);
      await session.waitForComposer(STEP);
      await session.sendText(OWNER_PROMPT);
      await waitUntil(() => events >= 2, "the second stop event", context, TIMEOUT - 30_000);

      expect(itemThreeHistory, "the resumed root still holds its first turn").toContain(ITEM_ONE);
      expect(lastEvent).toContain("REPORT: finished — item three done");
      const sessionsUsed = new Set(journalLines(layout.home).map((line) => line.session));
      expect(sessionsUsed.size, "every send and turn end ran on one saved session").toBe(1);
      expect(session.isAlive()).toBe(true);
    },
    TIMEOUT,
  );
});
