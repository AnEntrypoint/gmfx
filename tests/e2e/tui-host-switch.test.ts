import { describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewaySse,
  startDynamicFakeGateway,
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  composerContains,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";








const TIMEOUT = 90_000;
const LIST_HINT = "enter switch";




async function moveAgent(session: TmuxSession, rows: number) {
  await session.sendKeys("C-x");
  await session.waitForText(LIST_HINT, 10_000);
  for (let step = 0; step < Math.abs(rows); step += 1) await session.sendKeys(rows > 0 ? "Down" : "Up");
  await session.sendKeys("Enter");
  await session.waitForPane((pane) => !pane.includes(LIST_HINT), 10_000);
}

async function waitForReportAnswered(session: TmuxSession, reply: string, ms = 30_000) {
  const reported = "agent-main-sub completed";
  return session.waitForPane((pane) => pane.includes(reported) && pane.lastIndexOf(reply) > pane.indexOf(reported), ms);
}

function text(id: string, delta: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id, delta },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function toolCall(id: string, tool: string, input: object): Response {
  if (tool !== "run_code") return fakeGatewayVerbCall(id, tool, input);
  return fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: tool, input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

function agentCall(id: string, prompt: string, extra: object = {}): Response {
  return toolCall(id, "run_code", { body: `return gm.Agent(${JSON.stringify({ description: "Do the task", prompt, run_in_background: true, ...extra })});` });
}

function userTexts(body: string): string[] {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  return (request.prompt ?? []).filter((message) => message.role === "user").map((message) => {
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";
    return message.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
  });
}


async function stablePaneTitle(session: TmuxSession, ms = 15_000): Promise<string> {
  const deadline = Date.now() + ms;
  let last = await session.paneTitle();
  let since = Date.now();
  while (Date.now() < deadline) {
    await Bun.sleep(100);
    const now = await session.paneTitle();
    if (now !== last) {
      last = now;
      since = Date.now();
    } else if (Date.now() - since >= 500) {
      return now;
    }
  }
  return last;
}

async function waitForPaneTitle(session: TmuxSession, done: (title: string) => boolean, ms = 15_000): Promise<string> {
  const deadline = Date.now() + ms;
  let title = "";
  while (Date.now() < deadline) {
    title = await session.paneTitle();
    if (done(title)) return title;
    await Bun.sleep(50);
  }
  throw new Error(`pane title never matched; last saw ${JSON.stringify(title)}`);
}


function childLogLines(home: string): Array<{ kind?: string; work_id?: string; data?: { by?: string } }> {
  const sessions = join(home, ".fx", "sessions", "v2");
  if (!existsSync(sessions)) return [];
  return readdirSync(sessions).flatMap((id) => {
    const log = join(sessions, id, "log.jsonl");
    if (!existsSync(log)) return [];
    return readFileSync(log, "utf8").split("\n").filter((line) => line.includes('"child_')).map((line) => JSON.parse(line));
  });
}


function latestUserText(body: string): string {
  return userTexts(body).at(-1) ?? "";
}

async function until(what: string, done: () => boolean, ms = 30_000) {
  const deadline = Date.now() + ms;
  while (!done()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(50);
  }
}


function traceHas(path: string, text: string): boolean {
  return existsSync(path) && readFileSync(path, "utf8").includes(text);
}




function lastRecoveryRecords(home: string) {
  const sessions = join(home, ".fx", "sessions", "v2");
  const found: { rootId: string; root: object | null; child: object | null } = { rootId: "", root: null, child: null };
  for (const id of readdirSync(sessions)) {
    const log = join(sessions, id, "log.jsonl");
    if (!existsSync(log)) continue;
    const lines = readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line));
    const saved = lines.filter((line) => line.kind === "item" && line.type === "recovery" && line.data?.record).at(-1);
    const record = saved ? { phase: Number.parseInt(saved.data.record.slice(2, 4), 16), clean: (Number.parseInt(saved.data.record.slice(4, 6), 16) & 1) === 1 } : null;
    if (lines[0].role === "root") {
      found.rootId = id;
      found.root = record;
    } else {
      found.child = record;
    }
  }
  return found;
}


function tapeFrames(path: string): string {
  const replay = Bun.spawnSync([FX_BIN, "replay", path, "--frames"], { stdout: "pipe", stderr: "pipe" });
  expect(replay.exitCode).toBe(0);
  return new TextDecoder().decode(replay.stdout);
}


function held() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => (release = resolve));
  return { promise, release };
}




const isMainRequest = (body: string) => userTexts(body).some((text) => text.includes("SWITCH_USER"));



const subagentTitles = {
  titleResponses: Array.from({ length: 8 }, () => (body: string) =>
    fakeGatewayFinalText(body.includes("src/parser.zig") ? "Review the parser" : "Plan the parser work")),
};


function sessionsHolding(home: string, marker: string): string[] {
  const sessions = join(home, ".fx", "sessions", "v2");
  const holds = (path: string): boolean => readdirSync(path).some((entry) => {
    const full = join(path, entry);
    return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes(marker);
  });
  return readdirSync(sessions).filter((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id)));
}

interface Run {
  workspace: string;
  home: string;
  launch: (args?: string) => Promise<TmuxSession>;
  tape: string;
}

async function withFx(
  respond: (body: string) => Response | Promise<Response>,
  run: (session: TmuxSession, context: Run) => Promise<void>,
  setupHome: (home: string) => void = () => {},
  record = false,
  env: Record<string, string> = {},
  gatewayOptions: Parameters<typeof startDynamicFakeGateway>[1] = {},
) {
  const gateway = startDynamicFakeGateway(respond, gatewayOptions);
  const home = createIsolatedTestHome();
  const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-switch-")));
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  setupHome(home);
  const sessions: TmuxSession[] = [];
  const tape = join(workspace, "fx.fxtape");
  const launch = async (args = "") => {
    const session = await TmuxSession.create({
      cmd: args ? `${JSON.stringify(FX_BIN)} ${args}` : FX_BIN,
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-switch-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        ...(record && sessions.length === 0 ? { FX_RECORD: tape } : {}),
        ...env,
      },
      width: 120,
      height: 40,
    });
    sessions.push(session);
    await session.waitForComposer(30_000);
    return session;
  };
  try {
    await run(await launch(), { workspace, home, launch, tape });
    return gateway.requests.map((request) => request.body);
  } finally {
    gateway.stop();
    try {
      for (const session of sessions) await session.kill();
    } finally {
      cleanupIsolatedTestHome(home);
      rmSync(workspace, { recursive: true, force: true });
    }
  }
}

describe.skipIf(!tmuxAvailable())("TUI agent switching", () => {
  test(
    "the agent list shows a subagent's conversation, which takes messages typed there",
    async () => {
      let mainCalls = 0;
      const bodies = await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) return text("child_reply", "SWITCH_CHILD_REPLY");
          return text("child_answer", "SWITCH_CHILD_ANSWER");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_TASK look for nothing");
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await waitForReportAnswered(session, "SWITCH_MAIN_FINAL");
        await session.waitForComposer(15_000);


        await moveAgent(session, 1);
        const subagent = await session.waitForPane((pane) =>
          pane.includes("SWITCH_CHILD_ANSWER") && pane.includes("agent-main-sub \u00b7 "), 15_000);
        expect(subagent).toContain("SWITCH_TASK look for nothing");

        expect(subagent).toContain("Run /help for commands");
        expect(subagent).not.toContain("SWITCH_MAIN_FINAL");
        expect(await session.captureFullScrollback()).not.toContain("SWITCH_USER");


        await session.sendText("SWITCH_TYPED to the subagent");
        await session.waitForText("SWITCH_CHILD_REPLY", 30_000);



        const refusals = (pane: string, command: string) => pane.split(`${command} works on main's screen`).length - 1;
        for (const [typed, named, seen] of [["/new", "/new", 1], ["/clear", "/new", 2], ["/reset", "/reset", 1]] as const) {
          await session.sendText(typed);
          await session.waitForPane((pane) => refusals(pane, named) === seen, 15_000);
        }
        expect(await session.capturePane()).toContain("SWITCH_CHILD_REPLY");


        await moveAgent(session, 1);
        const main = await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_FINAL"), 15_000);
        expect(main).toContain("SWITCH_USER");
        expect(main).not.toContain("SWITCH_CHILD_REPLY");

        expect(main).not.toMatch(/^agent-main-sub \u00b7 /m);

        expect(main).toContain("agent-main-sub completed");
      });



      const mainBodies = bodies.filter(isMainRequest);
      expect(mainBodies.length).toBe(3);
      for (const body of mainBodies) expect(body).not.toContain("SWITCH_CHILD_REPLY");
      expect(mainBodies.filter((body) => body.includes("SWITCH_CHILD_ANSWER"))).toHaveLength(1);
      expect(bodies.some((body) => !isMainRequest(body) && latestUserText(body).includes("SWITCH_TYPED"))).toBe(true);
      for (const body of bodies.filter((body) => !isMainRequest(body))) {
        expect(body).toContain('You are the subagent \\"agent-main-sub\\", started by \\"main\\"');
      }
    },
    TIMEOUT,
  );

  test(
    "drafts and images stay with each agent across switches, and no switch enters the alternate screen",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_TASK look for nothing");
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { workspace, tape }) => {
        await session.sendText("SWITCH_USER");
        await waitForReportAnswered(session, "SWITCH_MAIN_FINAL");
        await session.waitForComposer(15_000);


        const image = join(workspace, "switch-draft.png");
        copyFileSync(join(import.meta.dir, "fixtures", "favicon.png"), image);
        await session.sendText(`/image ${image}`);
        await session.waitForText("attached image: switch-draft.png", 15_000);
        await session.sendLiteralText("SWITCH_MAIN_DRAFT");
        await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_DRAFT") && pane.includes("Image 1"), 15_000);
        const beforeSwitches = statSync(tape).size;



        await moveAgent(session, 1);
        const child = await session.waitForPane((pane) => pane.includes("agent-main-sub \u00b7 "), 15_000);
        expect(child).not.toContain("SWITCH_MAIN_DRAFT");
        expect(child).not.toContain("Image 1");
        await session.sendLiteralText("SWITCH_CHILD_DRAFT");
        await session.waitForText("SWITCH_CHILD_DRAFT", 15_000);


        await moveAgent(session, -1);
        const main = await session.waitForPane(
          (pane) => pane.includes("SWITCH_MAIN_DRAFT") && pane.includes("Image 1"), 15_000);
        expect(main).not.toContain("SWITCH_CHILD_DRAFT");


        await moveAgent(session, 1);
        const again = await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_DRAFT"), 15_000);
        expect(again).not.toContain("SWITCH_MAIN_DRAFT");



        const switches = readFileSync(tape).subarray(beforeSwitches);
        expect(switches.includes(Buffer.from("SWITCH_CHILD_DRAFT"))).toBe(true);
        expect(switches.includes(Buffer.from("SWITCH_MAIN_DRAFT"))).toBe(true);
        expect(switches.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      }, undefined, true);
    },
    TIMEOUT,
  );

  test(
    "quitting from a subagent's screen stops main and exits",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_TASK look for nothing");
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await waitForReportAnswered(session, "SWITCH_MAIN_FINAL");
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("agent-main-sub \u00b7 "), 15_000);


        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "Esc on a subagent's screen stops its turn, and its report tells main the user stopped it",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const first = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;

          if (childCalls === 1) await first.promise;
          return text("child_answer", "SWITCH_CHILD_RAN");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_STOP_TASK work slowly");
        }
        if (body.includes('\\"outcome\\":\\"cancelled\\"') && body.includes('\\"cause\\":\\"user_stop\\"')) {
          return text("main_saw", "SWITCH_MAIN_SAW_STOP");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_DONE", 30_000);
        await until("the subagent's turn", () => childCalls >= 1);
        expect(childCalls).toBe(1);

        await moveAgent(session, -1);
        await session.waitForPane((pane) => pane.includes("SWITCH_STOP_TASK") && pane.includes("agent-main-sub \u2193"), 15_000);
        await session.sendKeys("Escape");
        await session.waitForText("esc again to interrupt", 10_000);
        await session.sendKeys("Escape");

        await session.waitForText("What can fx do differently?", 15_000);
        await moveAgent(session, -1);

        await session.waitForText("SWITCH_MAIN_SAW_STOP", 30_000);
        first.release();

        expect(childCalls).toBe(1);
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent's work that /quit cuts short reports after a resume, saying fx quit",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const child = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;

          await child.promise;
          return text("child_answer", "SWITCH_CHILD_LATE");
        }
        mainCalls += 1;
        if (body.includes('\\"cause\\":\\"fx_quit\\"')) return text("main_saw_quit", "SWITCH_MAIN_SAW_QUIT");
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_QUIT_TASK work slowly");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_DONE", 30_000);
        const deadline = Date.now() + 15_000;
        while (childCalls === 0 && Date.now() < deadline) await Bun.sleep(50);
        expect(childCalls).toBe(1);
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);
        child.release();


        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
        });
        const parents = readdirSync(sessions).filter((id) =>
          !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), "SWITCH_MAIN_DONE"));
        expect(parents.length).toBe(1);


        const resumed = await launch(`--resume ${parents[0]}`);
        await resumed.waitForText("SWITCH_MAIN_SAW_QUIT", 30_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a task with terminal escapes shows them as text on the subagent's screen and never sends them",
    async () => {


      const HOSTILE = "SWITCH_TASK \u001b]2;pwned\u0007 \u001b[31mred\u001b[0m \u009b2J tail";
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_FIRST");
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return agentCall("main_sub", HOSTILE);
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { tape }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        const pane = await session.waitForPane((value) => value.includes("SWITCH_CHILD_FIRST"), 15_000);

        expect(pane).toContain("SWITCH_TASK \\x1b]2;pwned\\x07 \\x1b[31mred\\x1b[0m \\u{009b}2J tail");
        expect(await session.paneTitle()).not.toBe("pwned");
        await moveAgent(session, -1);
        await session.waitForComposer(15_000);

        const written = readFileSync(tape).toString("latin1");
        expect(written).not.toContain("\u001b]2;pwned");
        expect(written).not.toContain("\u001b[31mred");
        expect(written).not.toContain("\u00c2\u009b2J");
      }, () => {}, true);
    },
    TIMEOUT,
  );
  test(
    "the tab title names the agent on screen, and a subagent's title never takes over main's",
    async () => {
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_FIRST");
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return agentCall("main_sub", "SWITCH_TASK look for nothing");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);

        const mainTitle = await stablePaneTitle(session);
        expect(mainTitle).not.toBe("");
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        const childTitle = await waitForPaneTitle(session, (title) => title !== "" && title !== mainTitle);
        await moveAgent(session, -1);
        await waitForPaneTitle(session, (title) => title === mainTitle);
        expect(childTitle).not.toBe(mainTitle);
      });
    },
    TIMEOUT,
  );

  test(
    "an Enter with nothing typed on a subagent's screen opens no turn there",
    async () => {
      await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) return text("child_typed", "SWITCH_CHILD_TYPED");
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return agentCall("main_sub", "SWITCH_TASK look for nothing");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { home }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendKeys("Enter");
        await session.sendText("SWITCH_TYPED a real turn");
        await session.waitForText("SWITCH_CHILD_TYPED", 30_000);


        const spawns = childLogLines(home).filter((line) => line.kind === "child_spawned" && line.work_id?.startsWith("fxuser:"));
        expect(spawns).toHaveLength(1);
        expect(spawns[0]!.data?.by).toBe("user");
      });
    },
    TIMEOUT,
  );
  test(
    "a turn typed on a subagent's screen that fx dies during reaches main after a resume as the user's",
    async () => {
      const typed = held();
      let typedReached = false;
      let reports: string[] = [];
      try {
        await withFx(async (body) => {
          if (!isMainRequest(body)) {
            if (latestUserText(body).includes("SWITCH_TYPED")) {
              typedReached = true;
              await typed.promise;
              return text("child_typed", "SWITCH_CHILD_TYPED");
            }
            return text("child_answer", "SWITCH_CHILD_FIRST");
          }
          const interrupted = userTexts(body).filter((t) => t.includes('"child_id"') && t.includes('"outcome":"interrupted"'));
          if (interrupted.length > 0) {
            reports = interrupted;
            return text("main_saw_report", "SWITCH_MAIN_SAW_REPORT");
          }
          if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
          if (!body.includes('"main_sub"')) {
            return agentCall("main_sub", "SWITCH_TASK look for nothing");
          }
          return text("main_done", "SWITCH_MAIN_DONE");
        }, async (session, { home, launch }) => {
          await session.sendText("SWITCH_USER");
          await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
          await session.waitForComposer(15_000);
          await moveAgent(session, 1);
          await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("SWITCH_TYPED a turn the crash cuts off");
          await until("the typed turn's request", () => typedReached);


          const pid = session.processPid();
          process.kill(pid, "SIGKILL");
          const deadline = Date.now() + 10_000;
          while (Date.now() < deadline) {
            try { process.kill(pid, 0); } catch { break; }
            await Bun.sleep(25);
          }
          await session.kill();

          const sessions = join(home, ".fx", "sessions", "v2");
          const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
            const full = join(path, entry);
            return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
          });
          const parents = readdirSync(sessions).filter((id) =>
            !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), "SWITCH_MAIN_SAW_FIRST"));
          expect(parents).toHaveLength(1);
          const resumed = await launch(`--resume ${parents[0]}`);
          await resumed.waitForText("SWITCH_MAIN_SAW_REPORT", 30_000);
          await resumed.waitForComposer(15_000);
          await resumed.sendText("/quit");
          expect(await resumed.waitForSessionEnd(15_000)).toBe(true);
        });
      } finally {
        typed.release();
      }

      expect(reports).toHaveLength(1);
      expect(reports[0]).toContain('"started_by":"user"');
    },
    TIMEOUT,
  );

  test(
    "a subagent's approval can be answered on its own screen, and main's clears",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          if (childCalls === 1) {
            return toolCall("child_write", "write_file", { path: "switch-child.txt", content: "SWITCH_WROTE\n" });
          }
          return text("child_done", "SWITCH_WRITER_DONE");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_WRITE_TASK", { subagent_type: "writer" });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { workspace }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("Subagent agent-main-sub needs permission", 30_000);



        await session.sendKeys("C-x");
        const over = await session.waitForText(LIST_HINT, 10_000);
        expect(over).not.toContain("Apply this change?");

        expect(over).toMatch(/agent-main-sub · [^\n]* · writer · /);
        await session.sendKeys("1");
        await session.sendKeys("Escape");
        const back = await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("Apply this change?"), 10_000);
        expect(back).toContain("Subagent agent-main-sub needs permission");
        expect(existsSync(join(workspace, "switch-child.txt"))).toBe(false);


        await moveAgent(session, 1);
        await session.waitForPane((pane) =>
          pane.includes("SWITCH_WRITE_TASK") && pane.includes("Subagent agent-main-sub needs permission"), 15_000);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_WRITER_DONE", 30_000);
        expect(readFileSync(join(workspace, "switch-child.txt"), "utf8")).toBe("SWITCH_WROTE\n");


        await moveAgent(session, -1);
        const main = await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_DONE"), 30_000);
        expect(main).not.toContain("needs permission");
      }, (home) => {
        const folder = join(home, ".fx", "agents", "writer");
        mkdirSync(folder, { recursive: true });
        writeFileSync(join(folder, "profile.json"), JSON.stringify({
          description: "Writes one file",
          tools: ["read_file", "write_file"],
          permission_mode: "ask",
        }));
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent's question shows on main's screen, named for it, and is answered there",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      let answer = "";
      await withFx((body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          if (childCalls === 1) {
            return toolCall("child_ask", "AskUserQuestion", {
              questions: [{ question: "SWITCH_QUESTION pick one", options: [{ label: "SWITCH_ALPHA" }, { label: "SWITCH_BETA" }] }],
            });
          }
          answer = body;
          return text("child_done", "SWITCH_ASKER_DONE");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_ASK_TASK", { subagent_type: "asker" });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForPane((pane) => pane.includes("SWITCH_QUESTION pick one") && pane.includes("agent-main-sub asks"), 30_000);
        await session.sendKeys("1");
        await until("the subagent's request after the answer", () => answer !== "");
        const main = await session.waitForPane((pane) => pane.includes("agent-main-sub completed") && !pane.includes("SWITCH_QUESTION"), 30_000);
        expect(main).toContain("SWITCH_MAIN_DONE");
        expect(answer).toContain("SWITCH_ALPHA");


        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_ASKER_DONE"), 15_000);
      }, (home) => {
        const folder = join(home, ".fx", "agents", "asker");
        mkdirSync(folder, { recursive: true });
        writeFileSync(join(folder, "profile.json"), JSON.stringify({
          description: "Asks one question",
          tools: ["read_file", "AskUserQuestion"],
        }));
      }, false, { FX_PERMISSION_MODE: "yolo" });
    },
    TIMEOUT,
  );

  test(
    "a subagent with no mode of its own follows main's as it changes, on its next tool call",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const first = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) {
            if (body.includes('"typed_write"')) return text("typed_done", "SWITCH_TYPED_DONE");
            return toolCall("typed_write", "write_file", { path: "typed.txt", content: "TYPED\n" });
          }
          childCalls += 1;
          if (childCalls > 1) return text("child_done", "SWITCH_FOLLOWER_DONE");
          await first.promise;
          return toolCall("child_write", "write_file", { path: "followed.txt", content: "FOLLOWED\n" });
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_FOLLOW_TASK write a note");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { workspace }) => {


        await session.sendText("SWITCH_USER");
        await until("the subagent's first request", () => childCalls === 1);
        await session.sendText("/permissions auto");
        await session.waitForText("mode set to auto", 10_000);
        await session.waitForText("auto ·", 10_000);
        first.release();


        await session.waitForText("agent-main-sub completed", 30_000);
        expect(readFileSync(join(workspace, "followed.txt"), "utf8")).toBe("FOLLOWED\n");
        expect(await session.captureFullScrollback()).not.toContain("needs permission");


        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_FOLLOWER_DONE") && pane.includes("auto ·"), 15_000);



        await moveAgent(session, -1);
        await session.sendText("/permissions ask");
        await session.waitForText("mode set to manual", 10_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("ask ·"), 15_000);
        await session.sendText("SWITCH_TYPED write again");
        await session.waitForText("Apply this change?", 30_000);
        expect(existsSync(join(workspace, "typed.txt"))).toBe(false);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_TYPED_DONE", 30_000);
        expect(readFileSync(join(workspace, "typed.txt"), "utf8")).toBe("TYPED\n");
      }, () => {}, false, { FX_PERMISSION_MODE: "ask" });
    },
    TIMEOUT,
  );

  test(
    "main's screen shows the subagent prompt asked first, whichever subagent started first",
    async () => {
      const gates = { first: held(), second: held() };
      const seen = { first: 0, second: 0 };
      const started = { first: false, second: false };
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          const who: "first" | "second" = userTexts(body).some((t) => t.includes("SWITCH_TASK_SECOND")) ? "second" : "first";
          if (body.includes(`"write_${who}"`)) return text(`done_${who}`, `CHILD_DONE_${who.toUpperCase()}`);
          seen[who] += 1;
          await gates[who].promise;
          return toolCall(`write_${who}`, "write_file", { path: `${who}.txt`, content: `${who}\n` });
        }
        if (body.includes("CHILD_DONE_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (body.includes("CHILD_DONE_SECOND")) return text("main_saw_second", "SWITCH_MAIN_SAW_SECOND");
        if (latestUserText(body).includes("START_SECOND") && !started.second) {
          started.second = true;
          return agentCall("main_second", "SWITCH_TASK_SECOND write second.txt");
        }
        if (!started.first) {
          started.first = true;
          return agentCall("main_first", "SWITCH_TASK_FIRST write first.txt");
        }
        return text("main_idle", "SWITCH_MAIN_IDLE");
      }, async (session, { workspace }) => {
        await session.sendText("SWITCH_USER start the first");
        await until("the first subagent's request", () => seen.first === 1);
        await session.sendText("SWITCH_USER START_SECOND");
        await until("the second subagent's request", () => seen.second === 1);



        await moveAgent(session, -2);
        gates.second.release();
        await session.waitForText("agent-main-second needs approval", 30_000);
        gates.first.release();
        await session.waitForText("Subagent agent-main-first needs permission", 30_000);


        await moveAgent(session, -1);
        const oldest = await session.waitForText("Subagent agent-main-second needs permission", 15_000);
        expect(oldest).not.toContain("Subagent agent-main-first needs permission");
        await session.sendKeys("1");
        await session.waitForText("Subagent agent-main-first needs permission", 15_000);
        expect(readFileSync(join(workspace, "second.txt"), "utf8")).toBe("second\n");
        expect(existsSync(join(workspace, "first.txt"))).toBe(false);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        expect(readFileSync(join(workspace, "first.txt"), "utf8")).toBe("first\n");
      }, () => {}, false, { FX_PERMISSION_MODE: "ask" });
    },
    TIMEOUT,
  );

  test(
    "after a restart, the agent list shows a subagent's saved conversation before it runs again",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_SAVED_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_SAVED_TASK");
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER");
        await waitForReportAnswered(session, "SWITCH_MAIN_FINAL");
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);



        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes("SWITCH_MAIN_FINAL");
        });
        const parent = readdirSync(sessions).find((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id)));
        expect(parent).toBeDefined();
        const resumed = await launch(`--resume ${parent}`);
        await moveAgent(resumed, 1);
        const subagent = await resumed.waitForPane((pane) =>
          pane.includes("SWITCH_SAVED_ANSWER") && pane.includes("agent-main-sub \u00b7 done"), 15_000);
        expect(subagent).toContain("SWITCH_SAVED_TASK");

        expect(subagent).not.toContain("Run /help for commands");
        await moveAgent(resumed, -1);
        await resumed.waitForPane((pane) => pane.includes("SWITCH_MAIN_FINAL"), 15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "/compact on a subagent's screen saves to its own session, and its next turns use it, after a restart too",
    async () => {
      const summary = "Facts:\nF1: SWITCH_COMPACT_SUMMARY: the subagent read notes.txt for main.";
      const history = "history alpha beta gamma delta sample line\n".repeat(1600);
      let mainCalls = 0;
      const bodies = await withFx((body) => {

        const request = JSON.parse(body) as { toolChoice?: { type?: string }; tools?: unknown[] };
        if (request.toolChoice?.type === "none" && request.tools?.length === 0) return text("summary", summary);
        if (!isMainRequest(body)) {
          const latest = latestUserText(body);
          if (latest.includes("SWITCH_AFTER_COMPACT")) return text("child_after", "SWITCH_CHILD_AFTER");
          if (latest.includes("SWITCH_AFTER_RESUME")) return text("child_resumed", "SWITCH_CHILD_RESUMED");

          if (!body.includes('"child_read"')) return toolCall("child_read", "read_file", { path: "notes.txt" });
          return text("child_answer", `SWITCH_CHILD_ANSWER\n${history}`);
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return agentCall("main_sub", "SWITCH_TASK read notes.txt");
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { home, workspace, launch }) => {
        writeFileSync(join(workspace, "notes.txt"), "SWITCH_NOTES\n");
        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
        });

        const holding = (marker: string) => readdirSync(sessions).filter((id) =>
          !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), marker));

        await session.sendText("SWITCH_USER");
        await waitForReportAnswered(session, "SWITCH_MAIN_FINAL");
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("agent-main-sub \u00b7 "), 15_000);
        await session.sendText("/compact");
        const deadline = Date.now() + 30_000;
        while (holding("SWITCH_COMPACT_SUMMARY").length === 0 && Date.now() < deadline) await Bun.sleep(100);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_AFTER_COMPACT");
        await session.waitForText("SWITCH_CHILD_AFTER", 30_000);
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);


        const parents = holding("SWITCH_MAIN_FINAL");
        expect(parents.length).toBe(1);
        const compacted = holding("SWITCH_COMPACT_SUMMARY");
        expect(compacted.length).toBe(1);
        expect(compacted[0]).not.toBe(parents[0]);
        expect(holding("SWITCH_TASK")).toContain(compacted[0]!);


        const resumed = await launch(`--resume ${parents[0]}`);
        await moveAgent(resumed, -1);
        await resumed.waitForPane((pane) => pane.includes("agent-main-sub \u00b7 "), 15_000);
        await resumed.sendText("SWITCH_AFTER_RESUME");
        await resumed.waitForText("SWITCH_CHILD_RESUMED", 30_000);
      });

      const childTurn = (marker: string) => bodies.find((body) => !isMainRequest(body) && latestUserText(body).includes(marker));
      for (const marker of ["SWITCH_AFTER_COMPACT", "SWITCH_AFTER_RESUME"]) {
        const body = childTurn(marker);
        expect(body).toBeDefined();
        expect(body).toContain("compacted_conversation");
        expect(body).toContain("SWITCH_COMPACT_SUMMARY");
      }

      for (const body of bodies.filter(isMainRequest)) expect(body).not.toContain("SWITCH_COMPACT_SUMMARY");
    },
    TIMEOUT,
  );

  test(
    "with no subagent, Option+Right jumps by word",
    async () => {
      await withFx(() => text("unused", "unused"), async (session) => {
        await session.sendLiteral("alpha beta");
        await session.waitForText("alpha beta", 10_000);
        await session.sendKeys("C-a");
        await session.sendKeys("M-Right");
        await session.sendLiteral("Z");
        const pane = await session.waitForPane((value) => value.includes("Z"), 10_000);
        expect(pane).toMatch(/alpha ?Z ?beta/);
      });
    },
    TIMEOUT,
  );


  const withReviewer = (run: (session: TmuxSession) => Promise<void>) => {
    let mainCalls = 0;
    return withFx((body) => {
      if (!isMainRequest(body)) return text("child_answer", "EDGE_CHILD_ANSWER");
      mainCalls += 1;
      if (mainCalls === 1) {
        return agentCall("main_sub", "EDGE_TASK look for nothing");
      }
      return text("main_final", "EDGE_MAIN_FINAL");
    }, async (session) => {
      await session.sendText("SWITCH_USER_EDGE");
      await waitForReportAnswered(session, "EDGE_MAIN_FINAL");
      await session.waitForComposer(15_000);
      await run(session);
    });
  };

  test(
    "with a subagent, Option+arrows only move text and never switch",
    async () => {
      await withReviewer(async (session) => {

        await session.sendLiteral("hello world");
        await session.waitForText("hello world", 10_000);
        await session.sendKeys("M-Left");
        await session.sendLiteral("Z");
        await session.waitForPane((pane) => pane.includes("hello Zworld"), 10_000);



        await session.sendKeys("C-a");
        await session.sendKeys("M-Left");
        await session.sendKeys("M-b");
        await session.sendKeys("M-Up");
        await session.sendLiteral("Y");
        const stayed = await session.waitForPane((pane) => pane.includes("Yhello Zworld"), 10_000);
        expect(stayed).toContain("main \u00b7 ctrl+x");


        expect(stayed).toMatch(/^┃ SWITCH_USER_EDGE/m);
        expect(stayed).not.toMatch(/^┃ EDGE_TASK/m);
        expect(stayed).not.toContain(LIST_HINT);
      });
    },
    TIMEOUT,
  );

  test(
    "down on an empty composer opens the agent list, which previews, and Esc goes back",
    async () => {
      await withReviewer(async (session) => {

        expect(await session.capturePane()).toContain("main \u2193");




        await session.sendKeys("Up");
        await session.waitForPane((pane) => pane.includes("main \u00b7 ctrl+x"), 10_000);
        await session.sendKeys("Down");
        await session.waitForPane((pane) => pane.includes("main \u2193"), 10_000);
        expect(await session.capturePane()).not.toContain(LIST_HINT);


        await session.sendKeys("Down");
        const list = await session.waitForText(LIST_HINT, 10_000);
        expect(list).toContain("fx 1 (on screen) \u00b7 ");
        expect(list).toContain("  agent-main-sub \u00b7 ");


        await session.sendKeys("Down");
        const preview = await session.waitForPane((pane) => pane.includes("EDGE_CHILD_ANSWER") && pane.includes(LIST_HINT), 10_000);
        expect(preview).not.toContain("EDGE_MAIN_FINAL");


        await session.sendKeys("Escape");
        const back = await session.waitForPane((pane) => pane.includes("EDGE_MAIN_FINAL") && !pane.includes(LIST_HINT), 10_000);
        expect(back).toContain("main \u2193");


        await session.sendKeys("Down");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        await session.waitForText("EDGE_CHILD_ANSWER", 10_000);
        await session.sendKeys("Enter");
        const kept = await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("agent-main-sub \u00b7 done \u2193"), 10_000);
        expect(kept).toContain("EDGE_CHILD_ANSWER");
      });
    },
    TIMEOUT,
  );

  test(
    "with a draft, down stays in the composer, Ctrl+X opens the list, and the draft stays where it was typed",
    async () => {
      await withReviewer(async (session) => {
        await session.sendLiteral("EDGE_KEEP_ME");
        await session.waitForPane((pane) => pane.includes("main \u00b7 ctrl+x"), 10_000);
        await session.sendKeys("Down");
        expect(await session.capturePane()).not.toContain(LIST_HINT);


        await session.sendKeys("C-x");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendLiteral("q");
        await session.sendKeys("BSpace");
        await session.sendKeys("Down");
        const preview = await session.waitForPane((pane) => pane.includes("EDGE_CHILD_ANSWER"), 10_000);
        expect(preview).not.toContain("EDGE_KEEP_ME");
        await session.sendKeys("Enter");


        const child = await session.waitForPane((pane) => pane.includes("agent-main-sub \u00b7 done \u2193"), 10_000);
        expect(child).not.toContain("EDGE_KEEP_ME");


        await moveAgent(session, -1);
        const main = await session.waitForPane((pane) => pane.includes("\u2503 EDGE_KEEP_ME"), 10_000);
        expect(main).not.toContain("EDGE_KEEP_MEq");
        expect(main).toContain("main \u00b7 ctrl+x");
      });
    },
    TIMEOUT,
  );
  test(
    "the agent list names each agent by its title, profile, state, and model, and main's footer counts the subagents working",
    async () => {
      const reviewer = held();
      let childCalls = 0;
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          await reviewer.promise;
          return text("child_answer", "LIST_CHILD_DONE");
        }
        if (!body.includes('"main_sub"')) {
          return agentCall("main_sub", "Review src/parser.zig for bugs");
        }
        return text("main_wait", "LIST_MAIN_WAITING");
      }, async (session) => {
        await session.sendText("SWITCH_USER plan it");
        await session.waitForText("LIST_MAIN_WAITING", 30_000);
        await until("the reviewer's turn", () => childCalls >= 1);

        await session.waitForText("1 subagent working \u00b7 main \u2193", 15_000);
        await session.sendKeys("Down");

        const list = await session.waitForPane((pane) => / {4}agent-main-sub \u00b7 Review the parser \u00b7 coder \u00b7 working \u00b7 \S/.test(pane), 15_000);
        expect(list).toMatch(/fx 1 \(on screen\) \u00b7 Plan the parser work \u00b7 main \u00b7 idle \u00b7 \S/);

        expect(list).toContain("\u2191\u2193 preview     enter switch     esc back");
        expect(list).not.toContain("delete close");
        await session.sendKeys("Escape");
        reviewer.release();
        await session.waitForPane((pane) => !pane.includes("subagent working"), 30_000);
      }, () => {}, false, {}, subagentTitles);
    },
    TIMEOUT,
  );

  test(
    "the agent list keeps working order, sorts idle responses newest first through resume, and preserves selection",
    async () => {
      const gates = { reviewer: held(), tester: held() };
      const started = { reviewer: false, tester: false };
      let reportsAnswered = 0;
      const inOrder = (pane: string, ...rows: string[]) =>
        rows.every((row, index) => pane.includes(row) && (index === 0 || pane.indexOf(rows[index - 1]!) < pane.indexOf(row)));
      try {
        await withFx(async (body) => {
          if (!isMainRequest(body)) {
            const who = userTexts(body).some((value) => value.includes("ORDER_TEST_TASK")) ? "tester" : "reviewer";
            started[who] = true;
            await gates[who].promise;
            return text(`order_${who}_done`, `ORDER_${who.toUpperCase()}_DONE`);
          }
          if (!body.includes('"order_review"')) {
            return agentCall("order_review", "ORDER_REVIEW_TASK check the parser");
          }
          if (!body.includes('"order_test"')) {
            return agentCall("order_test", "ORDER_TEST_TASK check the tests");
          }
          if (latestUserText(body).includes("ORDER_MAIN_NEW_REPLY")) return text("order_main_new", "ORDER_MAIN_NEWEST");
          if (latestUserText(body).includes("Subagent report")) reportsAnswered += 1;
          return text("order_main_idle", "ORDER_MAIN_IDLE");
        }, async (session, { home, launch }) => {
          await session.sendText("SWITCH_USER start both workers");
          await session.waitForText("ORDER_MAIN_IDLE", 30_000);
          await until("both workers' requests", () => started.reviewer && started.tester);
          await session.waitForText("2 subagents working", 15_000);
          await session.sendKeys("Down");
          const initial = await session.waitForPane((pane) =>
            /^ {4}agent-order-review \u00b7 .* \u00b7 working \u00b7 /m.test(pane)
            && /^ {4}agent-order-test \u00b7 .* \u00b7 working \u00b7 /m.test(pane)
            && /fx 1 \(on screen\) \u00b7 .* \u00b7 idle \u00b7 /.test(pane), 15_000);


          expect(initial.indexOf("    agent-order-review \u00b7 ")).toBeLessThan(initial.indexOf("    agent-order-test \u00b7 "));
          expect(initial.indexOf("    agent-order-test \u00b7 ")).toBeLessThan(initial.indexOf("  fx 1 (on screen)"));
          await session.sendKeys("Up");
          const preview = await session.waitForText("ORDER_TEST_TASK check the tests", 10_000);
          expect(preview).toContain("ORDER_TEST_TASK check the tests");
          expect(preview).toContain("enter switch     delete close     esc back");

          gates.reviewer.release();
          const reordered = await session.waitForPane((pane) =>
            pane.includes("ORDER_TEST_TASK check the tests")
            && /^ {4}agent-order-test \u00b7 .* \u00b7 working \u00b7 /m.test(pane)
            && /^ {4}agent-order-review \u00b7 /m.test(pane)
            && !/^ {4}agent-order-review \u00b7 .* \u00b7 working \u00b7 /m.test(pane)
            && /fx 1 \(on screen\) \u00b7 .* \u00b7 (?:idle|finished) \u00b7 /.test(pane)
            && reportsAnswered === 1 && inOrder(pane, "    agent-order-test \u00b7 ", "  fx 1 (on screen) \u00b7 ", "    agent-order-review \u00b7 "), 30_000);
          expect(reordered).toContain("enter switch     delete close     esc back");
          gates.tester.release();
          const idle = await session.waitForPane((pane) => pane.includes("ORDER_TESTER_DONE")
            && /^ {4}agent-order-test \u00b7 /m.test(pane) && /^ {4}agent-order-review \u00b7 /m.test(pane)
            && /fx 1 \(on screen\) \u00b7 .* \u00b7 (?:idle|finished) \u00b7 /.test(pane)
            && pane.includes(LIST_HINT) && !/\u00b7 working \u00b7 /.test(pane)
            && reportsAnswered === 2 && inOrder(pane, "  fx 1 (on screen) \u00b7 ", "    agent-order-test \u00b7 ", "    agent-order-review \u00b7 "), 30_000);
          expect(idle).toContain("ORDER_TEST_TASK check the tests");
          await session.sendKeys("Enter");
          const kept = await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
          expect(kept).toContain("ORDER_TESTER_DONE");
          expect(kept).toContain("agent-order-test \u00b7 done \u2193");
          expect(kept).not.toContain("ORDER_MAIN_IDLE");

          await moveAgent(session, -1);
          await session.waitForText("ORDER_MAIN_IDLE", 10_000);
          await session.sendText("SWITCH_USER ORDER_MAIN_NEW_REPLY");
          await session.waitForText("ORDER_MAIN_NEWEST", 30_000);
          await session.sendKeys("C-x");
          const mainNewest = await session.waitForPane((pane) => pane.includes(LIST_HINT)
            && /fx 1 \(on screen\) \u00b7 .* \u00b7 idle \u00b7 /.test(pane), 15_000);
          expect(mainNewest.indexOf("  fx 1 (on screen) \u00b7 ")).toBeLessThan(mainNewest.indexOf("    agent-order-test \u00b7 "));
          expect(mainNewest.indexOf("    agent-order-test \u00b7 ")).toBeLessThan(mainNewest.indexOf("    agent-order-review \u00b7 "));
          expect(mainNewest).not.toContain("delete close");
          await session.sendKeys("Enter");
          await session.waitForPane((pane) => !pane.includes(LIST_HINT), 10_000);
          expect(await session.captureFullScrollback()).toContain("ORDER_MAIN_NEWEST");
          await session.sendText("/quit");
          expect(await session.waitForSessionEnd(15_000)).toBe(true);

          const parents = sessionsHolding(home, "ORDER_MAIN_NEWEST");
          expect(parents).toHaveLength(1);
          const resumed = await launch(`--resume ${parents[0]}`);
          await resumed.waitForText("ORDER_MAIN_NEWEST", 30_000);
          await resumed.sendKeys("C-x");
          const restored = await resumed.waitForPane((pane) => pane.includes(LIST_HINT)
            && /^ {4}agent-order-test \u00b7 /m.test(pane) && /^ {4}agent-order-review \u00b7 /m.test(pane), 15_000);
          expect(restored.indexOf("  fx 1 (on screen) \u00b7 ")).toBeLessThan(restored.indexOf("    agent-order-test \u00b7 "));
          expect(restored.indexOf("    agent-order-test \u00b7 ")).toBeLessThan(restored.indexOf("    agent-order-review \u00b7 "));
          expect(restored).not.toContain("delete close");
          await resumed.sendKeys("Enter");
          await resumed.waitForPane((pane) => !pane.includes(LIST_HINT), 10_000);
          expect(await resumed.capturePane()).toContain("ORDER_MAIN_NEWEST");
        });
      } finally {
        gates.reviewer.release();
        gates.tester.release();
      }
    },
    TIMEOUT,
  );

  test(
    "Delete, then Delete again, in the agent list closes a working subagent for good: main hears the user closed it, and a resume doesn't bring it back",
    async () => {
      const reviewer = held();
      let childCalls = 0;

      const env: Record<string, string> = {};
      let tracePath = "";
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          await reviewer.promise;
          return text("child_answer", "CLOSE_CHILD_DONE");
        }
        if (!body.includes('"main_sub"')) {
          return agentCall("main_sub", "Review src/parser.zig for bugs");
        }
        if (body.includes('\\"cause\\":\\"user_close\\"')) return text("main_told", "CLOSE_MAIN_TOLD");
        return text("main_wait", "CLOSE_MAIN_WAITING");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER review it");
        await session.waitForText("CLOSE_MAIN_WAITING", 30_000);
        await until("the reviewer's turn", () => childCalls >= 1);
        await session.sendKeys("Down");
        await session.waitForText("esc back", 10_000);



        await session.sendKeys("BSpace");
        await session.sendKeys("Up");
        const working = await session.waitForText("enter switch     delete close     esc back", 10_000);
        expect(working).toContain("Review src/parser.zig for bugs");
        expect(working.indexOf("    agent-main-sub \u00b7 ")).toBeLessThan(working.indexOf("  fx 1 (on screen) \u00b7 "));
        expect(readFileSync(tracePath, "utf8")).not.toContain("agents_menu_close_armed");
        await session.sendKeys("BSpace");
        const warning = await session.waitForText("press delete again to close this subagent", 10_000);
        expect(warning).not.toContain("any other key");
        expect(readFileSync(tracePath, "utf8")).toContain("agents_menu_close_armed");

        await session.sendKeys("Down");
        await session.waitForPane((pane) => !pane.includes("press delete again to close this subagent")
          && pane.includes("fx 1 (on screen)"), 10_000);
        await session.sendKeys("Up");
        await session.sendKeys("BSpace");
        await session.waitForText("press delete again to close this subagent", 10_000);
        await session.sendKeys("BSpace");
        const closed = await session.waitForPane((pane) => !/^ {4}agent-main-sub \u00b7 /m.test(pane) && pane.includes("esc back"), 15_000);

        expect(closed).toContain("SWITCH_USER review it");
        await session.sendKeys("Escape");

        await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        await session.waitForText("CLOSE_MAIN_TOLD", 30_000);
        expect(await session.capturePane()).not.toContain("subagent working");
        reviewer.release();
        expect(childCalls).toBe(1);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        const parents = sessionsHolding(home, "CLOSE_MAIN_TOLD");
        expect(parents.length).toBe(1);
        const resumed = await launch(`--resume ${parents[0]}`);
        await resumed.waitForText("CLOSE_MAIN_TOLD", 30_000);


        expect(await resumed.capturePane()).not.toContain("main \u2193");
        await resumed.sendKeys("Down");
        await resumed.sendLiteral("z");
        const typed = await resumed.waitForPane((pane) => composerContains(pane, "z"), 10_000);
        expect(typed).not.toContain("esc back");
      }, (home) => {
        tracePath = join(home, "fx-trace.log");
        env.FX_TRACE_LOG = tracePath;
      }, false, env);
    },
    TIMEOUT,
  );

  test(
    "closing the middle row of the agent list keeps the highlight on the agent shown, and the first Delete warns at once",
    async () => {
      let reviewerReported = false;
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          if (userTexts(body).some((value) => value.includes("MIDDLE_TEST"))) {
            await until("the reviewer's report", () => reviewerReported);
            return text("tester_done", "MIDDLE_TESTER_DONE");
          }
          return text("reviewer_done", "MIDDLE_REVIEWER_DONE");
        }
        reviewerReported ||= body.includes("MIDDLE_REVIEWER_DONE");
        if (!body.includes('"main_r"')) {
          return agentCall("main_r", "MIDDLE_REVIEW");
        }
        if (!body.includes('"main_t"')) {
          return agentCall("main_t", "MIDDLE_TEST");
        }
        return body.includes("MIDDLE_TESTER_DONE")
          ? text("main_done", "MIDDLE_MAIN_DONE")
          : text("main_wait", "MIDDLE_MAIN_WAITING");
      }, async (session) => {
        await session.sendText("SWITCH_USER start them");
        await session.waitForText("MIDDLE_MAIN_DONE", 30_000);
        await session.waitForPane((pane) => !pane.includes("subagent working"), 30_000);


        await session.sendKeys("Down");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        await session.waitForText("enter switch     delete close     esc back", 10_000);
        await session.sendKeys("BSpace");
        await session.waitForText("press delete again to close this subagent", 10_000);

        await session.sendKeys("a");
        await session.waitForText("enter switch     delete close     esc back", 10_000);

        await session.sendKeys("x");
        await session.sendKeys("X");
        expect(await session.capturePane()).not.toContain("press delete again to close this subagent");

        await session.sendLiteral("\x1b[127u");
        await session.waitForText("press delete again to close this subagent", 10_000);
        await session.sendLiteral("\x1b[127;1u");

        const closed = await session.waitForPane((pane) => !/^ {4}agent-main-t \u00b7 /m.test(pane) && pane.includes("esc back"), 15_000);
        expect(closed).toMatch(/^ {4}agent-main-r \u00b7 /m);
        expect(closed).toContain("\u2191\u2193 preview     enter switch     esc back");
        expect(closed).not.toContain("delete close");
        expect(await session.captureFullScrollback()).not.toContain("for good");
        await session.sendKeys("Enter");
        const kept = await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        expect(kept).toContain("MIDDLE_MAIN_DONE");
        expect(kept).toContain("main \u2193");
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent fx stops for repeated invalid Bash calls reports to main that it failed, and why",
    async () => {
      const env: Record<string, string> = {};
      let tracePath = "";
      let report = "";
      let laneSteps = 0;


      const invalidShell = (id: string) => toolCall(id, "Bash", {
        command: "printf unexpected > must-not-run.txt",
        description: `Write the marker, ${id}`,
        tty: true,
      });
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          laneSteps += 1;
          if (laneSteps > 2) return text("lane4_extra", "LANE4_ASKED_AGAIN");
          return invalidShell(`lane4_bad_${laneSteps}`);
        }
        if (latestUserText(body).includes('"child_id"')) {
          report = latestUserText(body);
          return text("main_report", "MAIN_SAW_REPORT");
        }
        if (!body.includes('"main_lane4"')) {
          return agentCall("main_lane4", "LANE4_TASK run the bench");
        }
        return text("main_waiting", "MAIN_WAITING");
      }, async (session) => {
        await session.sendText("SWITCH_USER start lane4");
        await session.waitForText("MAIN_SAW_REPORT", 60_000);
        await session.waitForComposer(30_000);
        expect(traceHas(tracePath, "terminal_validation_retry")).toBe(true);

        expect(laneSteps).toBe(2);
        const screen = await session.captureFullScrollback();
        expect(screen).toContain("agent-main-lane4 failed");
        expect(screen).not.toContain("agent-main-lane4 completed");


        const fields = JSON.parse(report.slice(report.indexOf("{")));
        expect(fields.outcome).toBe("failed");
        expect(fields.output).toContain("Repeated shell validation failures stopped the tool loop.");

        await moveAgent(session, 1);
        await session.waitForText("Repeated shell validation failures stopped the tool loop.", 10_000);
      }, (home) => {
        tracePath = join(home, "fx-trace.log");
        env.FX_TRACE_LOG = tracePath;
      }, false, env);
    },
    TIMEOUT,
  );

  test(
    "a subagent's report that waits for main's running turn never shows as a message the user queued",
    async () => {
      const env: Record<string, string> = {};
      let tapePath = "";
      let tracePath = "";
      let mainWaiting = () => {};
      const mainWaits = new Promise<void>((resolve) => { mainWaiting = resolve; });
      let releaseMain = () => {};
      const mainReleased = new Promise<void>((resolve) => { releaseMain = resolve; });
      await withFx(async (body) => {
        if (!isMainRequest(body)) {

          await mainWaits;
          return text("solo_reply", "SOLO_DONE");
        }
        if (latestUserText(body).includes('"child_id"')) return text("main_report", "MAIN_SAW_REPORT");
        if (!body.includes('"main_solo"')) {
          return agentCall("main_solo", "SOLO_TASK answer at once");
        }
        mainWaiting();
        await mainReleased;
        return text("main_done", "MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER go");


        await until("the report to reach main", () => traceHas(tracePath, "event=child_delivery_posted"), 30_000);

        await Bun.sleep(1_000);
        releaseMain();
        await session.waitForText("MAIN_SAW_REPORT", 60_000);
        await session.waitForComposer(30_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        const frames = tapeFrames(tapePath);
        expect(frames).toContain("MAIN_SAW_REPORT");
        expect(frames).not.toContain("untrusted agent output");
      }, (home) => {
        tapePath = join(home, "report.fxtape");
        tracePath = join(home, "fx-trace.log");
        env.FX_RECORD = tapePath;
        env.FX_TRACE_LOG = tracePath;
      }, false, env);
    },
    TIMEOUT,
  );

  test(
    "\u2191 takes back the user's own queued message, never a subagent's report waiting behind a tool",
    async () => {

      const env: Record<string, string> = { FX_PERMISSION_MODE: "yolo" };
      let tapePath = "";
      let tracePath = "";
      let started = "";
      let gate = "";
      let releaseSolo = () => {};
      const soloReleased = new Promise<void>((resolve) => { releaseSolo = resolve; });
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          await soloReleased;
          return text("solo_reply", "SOLO_DONE");
        }
        if (latestUserText(body).includes('"child_id"')) return text("main_report", "MAIN_SAW_REPORT");
        if (!body.includes('"main_solo"')) {


          const command = `touch ${started}; i=0; while [ ! -f ${gate} ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done; echo MAIN_WAITED`;
          return fakeGatewaySse([
            { type: "tool-call", toolCallId: "main_solo", toolName: "run_code", input: { body: 'return gm.Agent({"description":"Answer at once","prompt":"SOLO_TASK answer at once","run_in_background":true});' } },
            { type: "tool-call", toolCallId: "main_wait", toolName: "run_code", input: { body: `return gm.Bash(${JSON.stringify({ command, description: "Wait for the gate" })});` } },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
          ]);
        }
        return text("main_done", "MAIN_DONE");
      }, async (session, { workspace }) => {
        started = join(workspace, "command-started");
        gate = join(workspace, "command-gate");
        await session.sendText("SWITCH_USER go");
        await until("main's command to start", () => existsSync(started), 30_000);

        await session.sendText("MY_STEER");
        await session.waitForPane((pane) => pane.includes("\u250b MY_STEER"), 10_000);
        releaseSolo();
        await until("the report to reach main", () => traceHas(tracePath, "event=child_delivery_posted"), 30_000);


        await session.sendKeys("Up");
        await until("\u2191 to take a message back", () => traceHas(tracePath, "event=queued_steer_restored"), 10_000);
        expect(readFileSync(tracePath, "utf8")).toMatch(/event=queued_steer_restored bytes=8\b/);
        const restored = await session.waitForPane((pane) => composerContains(pane, "MY_STEER"), 10_000);
        expect(restored).not.toContain("Subagent report");
        await session.sendKeys("C-u");

        writeFileSync(gate, "");
        await session.waitForText("MAIN_SAW_REPORT", 60_000);
        await session.waitForComposer(30_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        expect(tapeFrames(tapePath)).not.toContain("untrusted agent output");
      }, (home) => {
        tapePath = join(home, "steer.fxtape");
        tracePath = join(home, "fx-trace.log");
        env.FX_RECORD = tapePath;
        env.FX_TRACE_LOG = tracePath;
      }, false, env);
    },
    TIMEOUT,
  );

  test(
    "closing the window while main and a subagent wait on the model resumes main without a crash question",
    async () => {

      const env: Record<string, string> = { FX_PERMISSION_MODE: "yolo" };
      let home = "";
      let mainSends = 0;
      let subagentSends = 0;
      const never = new Promise<Response>(() => {});
      await withFx(async (body) => {
        if (!isMainRequest(body)) {


          if (!body.includes('"solo_sleep"')) return toolCall("solo_sleep", "Bash", { command: "sleep 1", description: "Sleep a second" });
          subagentSends += 1;
          return never;
        }
        if (!body.includes('"main_solo"')) {
          return agentCall("main_solo", "SOLO_TASK");
        }
        mainSends += 1;
        return never;
      }, async (session, context) => {
        await session.sendText("SWITCH_USER go");
        await until("main's request", () => mainSends === 1, 30_000);
        await until("the subagent's later request", () => subagentSends === 1, 30_000);
        process.kill(session.processPid(), "SIGHUP");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        const records = lastRecoveryRecords(home);
        expect(records.root).toEqual({ phase: 1, clean: true });
        expect(records.child).toEqual({ phase: 1, clean: true });



        const second = await context.launch(`--resume ${records.rootId}`);
        await until("main's resumed request", () => mainSends === 2, 30_000);
        await moveAgent(second, 1);
        await second.sendText("SOLO_AGAIN");
        await until("the subagent's request after main's", () => subagentSends === 2, 30_000);
        process.kill(second.processPid(), "SIGHUP");
        expect(await second.waitForSessionEnd(15_000)).toBe(true);


        const third = await context.launch(`--resume ${records.rootId}`);
        await until("main's request to resume again", () => mainSends === 3, 30_000);
        expect(await third.capturePane()).not.toContain("crashed fx twice");
      }, (dir) => {
        home = dir;
      }, false, env);
    },
    TIMEOUT,
  );
});
