import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewaySse,
  LIST_VERBS_BODY,
  runCodeVerbNames,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";






const TIMEOUT = 90_000;
const LIST_HINT = "enter switch";



async function switchAgent(session: TmuxSession, target: "next" | "previous" | number) {
  await session.sendKeys("C-x");
  const pane = await session.waitForText(LIST_HINT, 10_000);
  const lines = pane.split("\n");
  const hint = lines.findIndex((line) => line.includes(LIST_HINT));

  let top = hint - 2;
  while (top > 0 && !lines[top - 1].trimStart().startsWith("\u2500")) top -= 1;
  const rows = lines.slice(top, hint - 1);
  const from = rows.findIndex((row) => row.includes("(on screen)"));
  if (from < 0 || rows.length < 2) throw new Error(`no agent list in:\n${pane}`);
  const to = typeof target === "number"
    ? rows.findIndex((row) => new RegExp(`\\bfx ${target}(?: \\(on screen\\))? ·`).test(row))
    : target === "next" ? (from + 1) % rows.length : (from + rows.length - 1) % rows.length;
  if (to < 0) throw new Error(`no fx ${target} row in:\n${pane}`);
  for (let step = 0; step < Math.abs(to - from); step += 1) await session.sendKeys(to > from ? "Down" : "Up");
  await session.sendKeys("Enter");
  await session.waitForPane((value) => !value.includes(LIST_HINT), 10_000);
}

function text(id: string, delta: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id, delta },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function userTexts(body: string): string[] {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  return (request.prompt ?? []).filter((message) => message.role === "user").map((message) => {
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";
    return message.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
  });
}


function letterOf(body: string): string {
  return userTexts(body).at(-1)?.match(/HOST_([A-Z])/)?.[1] ?? "X";
}



function rejected(): Response {
  const message = "Your team has restricted access to this provider.";
  return new Response(
    JSON.stringify({ error: { message, type: "no_providers_available", param: { name: "RestrictedProvidersError", message } } }),
    { status: 403, headers: { "content-type": "application/json" } },
  );
}

function answerByLetter(body: string): Response {
  const letter = letterOf(body);
  return text(`answer_${letter}`, `HOST_ANSWER_${letter}`);
}

function answerAfterVerbs(body: string): Response {
  return answered(body) ? answerByLetter(body) : call(`verbs_${letterOf(body)}`, "run_code", LIST_VERBS_BODY);
}

function lettersVerbs(bodies: string[], letter: string): string[] {
  expect(toolNames(bodies.find((body) => letterOf(body) === letter)!)).toEqual(["run_code"]);
  return verbNames(bodies.find((body) => letterOf(body) === letter && answered(body))!);
}

interface Host {
  home: string;
  workspace: string;
  session: TmuxSession;
}

async function withHost(
  respond: (body: string) => Response | Promise<Response>,
  options: {
    args?: string;
    instances?: number;

    env?: Record<string, string | undefined>;

    models?: unknown[];

    requests?: Array<{ body: string; headers: Headers }>;
    remainOnExit?: boolean;

    reuse?: { home: string; workspace: string };
  },
  run: (host: Host) => Promise<void>,
): Promise<string[]> {
  const gateway = startDynamicFakeGateway(respond, options.models ? { models: options.models as never } : {});
  const home = options.reuse?.home ?? createIsolatedTestHome();
  const workspace = options.reuse?.workspace ?? realpathSync(mkdtempSync(join(tmpdir(), "fx-host-instances-")));
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: options.args ? `${JSON.stringify(FX_BIN)} ${options.args}` : FX_BIN,
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-host-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        ...(options.instances ? { FX_TEST_INSTANCES: String(options.instances) } : {}),
        ...options.env,
      },
      width: 120,
      height: 40,
      remainOnExit: options.remainOnExit ?? false,
    });
    await session.waitForComposer(30_000);
    await run({ home, workspace, session });
    options.requests?.push(...gateway.requests);
    return gateway.requests.map((request) => request.body);
  } finally {
    gateway.stop();
    try {
      if (session) await session.kill();
    } finally {
      if (!options.reuse) {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    }
  }
}

const ANSWERS = ["A", "B", "C", "D"].map((letter) => `HOST_ANSWER_${letter}`);


function toolNames(body: string): string[] {
  const request = JSON.parse(body) as { tools?: Array<{ name?: string }> };
  return (request.tools ?? []).map((tool) => tool.name ?? "");
}

const CALL_FIXTURE_ECHO = { body: "return await gm.mcp__fixture__echo({ text: \"hello\" });" };

function verbNames(body: string): string[] {
  return runCodeVerbNames((JSON.parse(body) as { prompt?: unknown[] }).prompt?.at(-1));
}



function answered(body: string): boolean {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
  return request.prompt?.at(-1)?.role === "tool";
}

function call(id: string, tool: string, input: object): Response {
  return fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: tool, input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}


const PREFERENCE_MODELS = ["profile/model", "openai/gpt-5", "other/model"].map((id) => ({
  id,
  type: "language",
  tags: ["reasoning", "tool-use"],
  reasoning_options: [{ type: "effort", values: ["low", "medium", "high"] }],
  fast_options: [{ type: "toggle" }],
}));


function echoMarker(body: string): Response {
  const marker = (userTexts(body).at(-1) ?? "").match(/[A-Z][A-Z0-9_]+/)?.[0] ?? "UNMARKED";
  return text(`answer_${marker}`, `DONE_${marker}`);
}

async function promptMarker(session: TmuxSession, marker: string) {
  await session.sendText(marker);
  await session.waitForText(`DONE_${marker}`, 30_000);
  await session.waitForComposer(15_000);
}


function preferencesOf(requests: Array<{ body: string; headers: Headers }>, marker: string) {
  const request = requests.find((value) => (userTexts(value.body).at(-1) ?? "").includes(marker));
  if (!request) return null;
  const body = JSON.parse(request.body);
  return {
    model: request.headers.get("ai-language-model-id"),
    reasoning: body.reasoning ?? null,
    speed: body.providerOptions?.gateway?.speed ?? null,
  };
}


function writeProfile(home: string, name: string, profile: object) {
  const dir = join(home, ".fx", "agents", name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "profile.json"), JSON.stringify(profile));
}

const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";


function sessionHolding(home: string, marker: string): string | null {
  const holds = (path: string): boolean => readdirSync(path).some((entry) => {
    const full = join(path, entry);
    return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes(marker);
  });
  const dir = join(home, ".fx", "sessions", "v2");
  if (!existsSync(dir)) return null;
  const ids = readdirSync(dir).filter((id) => !id.startsWith(".") && statSync(join(dir, id)).isDirectory());
  return ids.find((id) => holds(join(dir, id))) ?? null;
}


function hostRecords(home: string): string[][] {
  const dir = join(home, ".fx", "hosts");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => (JSON.parse(readFileSync(join(dir, name), "utf8")) as { sessions: string[] }).sessions);
}


function hostProfiles(home: string): Array<Array<string | null>> {
  const dir = join(home, ".fx", "hosts");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => (JSON.parse(readFileSync(join(dir, name), "utf8")) as { profiles?: Array<string | null> }).profiles ?? []);
}



async function saveGroup(home: string, workspace: string): Promise<string[]> {
  await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
    for (const [index, letter] of ["A", "B", "C"].entries()) {
      if (index > 0) {
        await switchAgent(session, index + 1);
        await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
        await session.waitForComposer(15_000);
      }
      await session.sendText(`HOST_${letter} first run`);
      await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
    }
    await quitWith(session, "/exit");
  });
  return ["A", "B", "C"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
}


async function quitWith(session: TmuxSession, command: string): Promise<string> {
  await session.sendText(command);
  const deadline = Date.now() + 15_000;
  while (!session.paneStatus().dead) {
    if (Date.now() > deadline) throw new Error(`fx did not exit after ${command}`);
    await Bun.sleep(50);
  }
  return (await session.captureFullScrollback()).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
}




function runThenAnswer(body: string): Response {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
  const turn = userTexts(body).at(-1)?.match(/PERM_(\d+)/)?.[1] ?? "0";
  if (request.prompt?.at(-1)?.role === "tool") return text(`done_${turn}`, `PERM_DONE_${turn}`);
  const command = userTexts(body).at(-1)?.match(/RUN\[(.+?)\]/)?.[1] ?? "true";
  return fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: `run_${turn}`,
      toolName: "Bash",
      input: { command, description: "Run the turn's command" },
    },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}


async function runTurn(session: TmuxSession, turn: number, command: string): Promise<"asked" | "done"> {
  await session.waitForComposer(15_000);
  await session.sendText(`PERM_${turn} RUN[${command}]`);
  const pane = await session.waitForPane(
    (value) => value.includes(COMMAND_APPROVAL_PROMPT) || value.includes(`PERM_DONE_${turn}`),
    30_000,
  );
  return pane.includes(`PERM_DONE_${turn}`) ? "done" : "asked";
}



async function approve(session: TmuxSession, turn: number, choice: "1" | "2") {
  await session.sendKeys(choice);
  await session.sendKeys("Enter");
  await session.waitForText(`PERM_DONE_${turn}`, 30_000);
}
const shownAnswers = (pane: string) => ANSWERS.filter((answer) => pane.includes(answer));

describe.skipIf(!tmuxAvailable())("TUI host instances", () => {
  test(
    "three instances started together each keep their own conversation",
    async () => {
      const bodies = await withHost(answerByLetter, { instances: 3 }, async ({ session }) => {
        for (const [index, letter] of ["A", "B", "C"].entries()) {
          if (index > 0) {
            await switchAgent(session, index + 1);
            await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
          } else {
            await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
          }
          await session.waitForComposer(15_000);
          await session.sendText(`HOST_${letter} hello`);
          const pane = await session.waitForPane((value) => value.includes(`HOST_ANSWER_${letter}`), 30_000);


          expect(pane).toContain("Run /help for commands");
          expect(pane).toContain("auto · gpt-5");
          expect(pane).toContain(`fx ${index + 1}/3 \u2193`);
          expect(shownAnswers(pane)).toEqual([`HOST_ANSWER_${letter}`]);
        }

        await switchAgent(session, 1);
        const first = await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);

        await switchAgent(session, 3);
        const last = await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        expect(shownAnswers(last)).toEqual(["HOST_ANSWER_C"]);
      });

      expect(bodies.length).toBe(3);
      for (const body of bodies) {
        const texts = userTexts(body).join("\n");
        expect(texts.match(/HOST_[A-Z]/g)?.length).toBe(1);
      }
      expect(bodies.map(letterOf).sort()).toEqual(["A", "B", "C"]);
    },
    TIMEOUT,
  );

  test(
    "--instances starts several, /launch adds one and shows it, /close closes it",
    async () => {
      await withHost(answerByLetter, { args: "--instances 2" }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);

        await session.sendText("/launch");
        const launched = await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        expect(launched).toContain("Run /help for commands");
        expect(shownAnswers(launched)).toEqual([]);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_D launched");
        await session.waitForText("HOST_ANSWER_D", 30_000);


        await session.sendText("/close");
        const after = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(after)).toEqual(["HOST_ANSWER_A"]);
        await switchAgent(session, "next");
        const second = await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(shownAnswers(second)).toEqual([]);


        await session.sendText("/launch nosuch");
        const refused = await session.waitForPane((pane) => pane.includes("no profile named 'nosuch'"), 15_000);
        expect(refused).toContain("Couldn't start another fx instance: no profile named 'nosuch'. Profiles:");
        expect(refused).not.toContain("ProfileNotFound");
        expect(refused).toContain("fx 2/2");
      });
    },
    TIMEOUT,
  );

  test(
    "/new on a later instance starts its own fresh session and leaves the others",
    async () => {
      const bodies = await withHost(answerByLetter, { instances: 2 }, async ({ session }) => {
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B before new");
        await session.waitForText("HOST_ANSWER_B", 30_000);


        await session.sendText("/new");
        await session.waitForPane((pane) => !pane.includes("HOST_ANSWER_B") && pane.includes("fx 2/2"), 15_000);
        expect(await session.capturePane()).not.toContain("works on main's screen");
        await session.waitForComposer(15_000);
        await session.sendText("HOST_C after new");
        await session.waitForText("HOST_ANSWER_C", 30_000);

        await switchAgent(session, "previous");
        const first = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
      });

      const after = bodies.find((body) => letterOf(body) === "C")!;
      expect(userTexts(after).join("\n")).not.toContain("HOST_B");
    },
    TIMEOUT,
  );

  test(
    "an instance keeps working while another one is on screen",
    async () => {
      let releaseSlow: () => void = () => {};
      const slowGate = new Promise<void>((resolve) => { releaseSlow = resolve; });
      const order: string[] = [];
      await withHost(async (body) => {
        const letter = letterOf(body);
        order.push(`request ${letter}`);
        if (letter === "A") {
          await slowGate;
          order.push("answer A");
        }
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.sendText("HOST_A slow");

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B fast");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        order.push("B shown");
        releaseSlow();
        await switchAgent(session, "previous");
        const first = await session.waitForPane((pane) => pane.includes("HOST_ANSWER_A"), 30_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
      });

      expect(order.indexOf("B shown")).toBeLessThan(order.indexOf("answer A"));
    },
    TIMEOUT,
  );

  test(
    "each instance keeps its own permission mode",
    async () => {
      await withHost(runThenAnswer, { instances: 2, env: { FX_PERMISSION_MODE: "ask" } }, async ({ workspace, session }) => {

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/permissions yolo");
        await session.waitForText("mode set to yolo", 15_000);
        expect(await runTurn(session, 1, "touch second-ran")).toBe("done");
        expect(existsSync(join(workspace, "second-ran"))).toBe(true);


        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(await runTurn(session, 2, "touch first-ran")).toBe("asked");
        expect(existsSync(join(workspace, "first-ran"))).toBe(false);
        await approve(session, 2, "1");
        expect(existsSync(join(workspace, "first-ran"))).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "an always approval belongs to its own instance and outlives another's /new",
    async () => {
      await withHost(runThenAnswer, { instances: 2, env: { FX_PERMISSION_MODE: "ask" } }, async ({ workspace, session }) => {
        const marker = join(workspace, "shared-marker");

        expect(await runTurn(session, 1, "touch shared-marker")).toBe("asked");
        await approve(session, 1, "2");
        expect(existsSync(marker)).toBe(true);
        rmSync(marker);
        expect(await runTurn(session, 2, "touch shared-marker")).toBe("done");
        expect(existsSync(marker)).toBe(true);
        rmSync(marker);


        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(await runTurn(session, 3, "touch shared-marker")).toBe("asked");
        await approve(session, 3, "1");
        rmSync(marker);


        await session.waitForComposer(15_000);
        await session.sendText("/new");
        await session.waitForPane((pane) => !pane.includes("PERM_DONE_3") && pane.includes("fx 2/2"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(await runTurn(session, 4, "touch shared-marker")).toBe("done");
        expect(existsSync(marker)).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "/close on the first instance hands over to the next, and the host keeps running",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ home, session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);


        await switchAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/close");
        const after = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(after)).toEqual(["HOST_ANSWER_B"]);

        await switchAgent(session, "next");
        const third = await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(shownAnswers(third)).toEqual([]);
        await switchAgent(session, "next");
        const wrapped = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(wrapped)).toEqual(["HOST_ANSWER_B"]);


        await session.waitForComposer(15_000);
        await session.sendText("/launch");
        await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_C launched");
        await session.waitForText("HOST_ANSWER_C", 30_000);

        const closed = sessionHolding(home, "HOST_ANSWER_A");
        expect(closed).not.toBeNull();
        expect(sessionHolding(home, "HOST_ANSWER_B")).not.toBe(closed);
      });
    },
    TIMEOUT,
  );

  test(
    "quitting from a later instance prints its own resume command",
    async () => {
      await withHost(answerByLetter, { instances: 2, remainOnExit: true }, async ({ home, session }) => {
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        const printed = await quitWith(session, "/exit");
        const second = sessionHolding(home, "HOST_ANSWER_B");
        expect(second).not.toBeNull();
        expect(printed).toContain(`Resume this session with:\nfx --resume ${second}\n`);
        expect(printed).not.toContain(`fx --resume ${sessionHolding(home, "HOST_ANSWER_A")}`);
      });
    },
    TIMEOUT,
  );

  test(
    "an instance with no turn stays out of the host record, and quitting from it names a saved one",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-unsaved-")));
      try {
        let printed = "";
        await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A only");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(500);

          expect(hostRecords(home)).toEqual([]);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
          await session.waitForComposer(15_000);
          printed = await quitWith(session, "/exit");
        });
        const saved = sessionHolding(home, "HOST_ANSWER_A");
        expect(saved).not.toBeNull();
        expect(printed).toContain(`Resume this session with:\nfx --resume ${saved}\n`);

        await withHost(answerByLetter, { args: `--resume ${saved}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_A"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
          expect(pane).not.toContain("Couldn't bring back");
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/close on the only open instance ends fx with its resume command",
    async () => {
      await withHost(answerByLetter, { instances: 2, remainOnExit: true }, async ({ home, session }) => {
        await session.sendText("/close");
        await session.waitForPane((pane) => !/fx \d+\/\d+/.test(pane) && pane.includes("Run /help for commands"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B last one");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        const printed = await quitWith(session, "/close");
        const last = sessionHolding(home, "HOST_ANSWER_B");
        expect(last).not.toBeNull();
        expect(printed).toContain(`Resume this session with:\nfx --resume ${last}\n`);
      });
    },
    TIMEOUT,
  );

  test(
    "resuming any session of a host brings back its whole group, the named one first",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-restore-")));
      try {
        await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          for (const [index, letter] of ["A", "B", "C"].entries()) {
            if (index > 0) {
              await switchAgent(session, index + 1);
              await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
              await session.waitForComposer(15_000);
            }
            await session.sendText(`HOST_${letter} first run`);
            await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
          }
          await quitWith(session, "/exit");
        });
        const [a, b, c] = ["A", "B", "C"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
        expect(hostRecords(home)).toEqual([[a, b, c]]);



        const bodies = await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          const first = await session.waitForPane((pane) => pane.includes("fx 1/3") && pane.includes("HOST_ANSWER_B"), 30_000);
          expect(shownAnswers(first)).toEqual(["HOST_ANSWER_B"]);
          await switchAgent(session, 2);
          const second = await session.waitForPane((pane) => pane.includes("fx 2/3") && pane.includes("HOST_ANSWER_A"), 15_000);
          expect(shownAnswers(second)).toEqual(["HOST_ANSWER_A"]);
          await switchAgent(session, 3);
          const third = await session.waitForPane((pane) => pane.includes("fx 3/3") && pane.includes("HOST_ANSWER_C"), 15_000);
          expect(shownAnswers(third)).toEqual(["HOST_ANSWER_C"]);

          await switchAgent(session, 2);
          await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_D carries on A");
          await session.waitForText("HOST_ANSWER_D", 30_000);
          await session.waitForPane(() => hostRecords(home).length === 1 && hostRecords(home)[0]![0] === b, 15_000);
          expect(hostRecords(home)).toEqual([[b, a, c]]);
        });
        const carried = bodies.find((body) => letterOf(body) === "D")!;
        expect(userTexts(carried).join("\n")).toContain("HOST_A first run");
        expect(userTexts(carried).join("\n")).not.toContain("HOST_B");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "the host record follows the open instances, and a lone session resumes alone",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-record-")));
      try {
        await withHost(answerByLetter, { remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A alone");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          expect(hostRecords(home)).toEqual([]);
          await session.sendText("/launch");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);

          await Bun.sleep(500);
          expect(hostRecords(home)).toEqual([]);
          await session.sendText("HOST_B second");
          await session.waitForText("HOST_ANSWER_B", 30_000);
          await session.waitForPane(() => hostRecords(home).length === 1 && hostRecords(home)[0]!.length === 2, 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/close");
          await session.waitForPane((pane) => !/fx \d+\/\d+/.test(pane), 15_000);
          await session.waitForPane(() => hostRecords(home).length === 0, 15_000);
          await quitWith(session, "/exit");
        });
        const alone = sessionHolding(home, "HOST_ANSWER_A")!;
        await withHost(answerByLetter, { args: `--resume ${alone}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_A"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );


  test(
    "the startup picker restores a group; in-app /resume and a missing session don't",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-picker-")));
      try {
        const [a, b, c] = await saveGroup(home, workspace);


        await withHost(answerByLetter, { args: "-r", reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("Sessions 3"), 30_000);
          await session.sendLiteralText("HOST_B");
          await session.waitForPane((pane) => pane.includes("Sessions 1"), 15_000);
          await session.sendKeys("Enter");
          const first = await session.waitForPane((pane) => pane.includes("fx 1/3") && pane.includes("HOST_ANSWER_B"), 30_000);
          expect(shownAnswers(first)).toEqual(["HOST_ANSWER_B"]);
          await switchAgent(session, 2);
          await session.waitForPane((pane) => pane.includes("fx 2/3") && pane.includes("HOST_ANSWER_A"), 15_000);
          await quitWith(session, "/exit").catch(() => "");
        });



        await withHost(answerByLetter, { reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/resume");
          await session.waitForPane((pane) => /Sessions \d+/.test(pane), 15_000);
          await session.sendLiteralText("HOST_C");
          await session.waitForPane((pane) => pane.includes("Sessions 1"), 15_000);
          await session.sendKeys("Enter");
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_C"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
          await Bun.sleep(500);
          expect(await session.capturePane()).not.toMatch(/fx \d+\/\d+/);
        });



        rmSync(join(home, ".fx", "sessions", "v2", a), { recursive: true, force: true });
        await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("fx 1/2") && value.includes("HOST_ANSWER_B"), 30_000);
          expect(pane).not.toContain("Couldn't bring back");
          await switchAgent(session, "next");
          await session.waitForPane((value) => value.includes("fx 2/2") && value.includes("HOST_ANSWER_C"), 15_000);
          await session.waitForPane(() => hostRecords(home).some((ids) => ids.length === 2 && !ids.includes(a!)), 15_000);
        });
        expect(c).not.toBeNull();
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/exit ends every instance, and each kept its own saved session",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ home, session }) => {
        for (const [index, letter] of ["A", "B", "C"].entries()) {
          if (index > 0) {
            await switchAgent(session, index + 1);
            await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
            await session.waitForComposer(15_000);
          }
          await session.sendText(`HOST_${letter} saved`);
          await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
        }
        await session.sendText("/exit");
        await session.waitForSessionEnd(15_000);
        const sessions = join(home, ".fx", "sessions", "v2");
        expect(existsSync(sessions)).toBe(true);
        expect(readdirSync(sessions).filter((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory()).length).toBe(3);
      });
    },
    TIMEOUT,
  );

  test(
    "a launched instance's subagents work under that instance",
    async () => {
      const bodies = await withHost((body) => {
        const texts = userTexts(body);
        if (texts.join("\n").includes("TREE_TASK")) {
          if (answered(body)) return text("tree_child_done", "TREE_CHILD_DONE");
          return call("tree_touch", "Bash", { command: "touch tree-marker", description: "Make the marker" });
        }
        if (texts.join("\n").includes("TREE_USER")) {
          if (answered(body)) return text("tree_main_final", "TREE_MAIN_FINAL");
          return call("tree_sub", "Agent", { description: "Make the marker", prompt: "TREE_TASK make the marker" });
        }
        return answerByLetter(body);
      }, { instances: 2, env: { FX_PERMISSION_MODE: "yolo" } }, async ({ workspace, session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER start a helper");
        await session.waitForText("TREE_MAIN_FINAL", 45_000);
        expect(existsSync(join(workspace, "tree-marker"))).toBe(true);
      });
      const child = bodies.filter((body) => userTexts(body).join("\n").includes("TREE_TASK"));
      expect(child.length).toBeGreaterThan(0);
      expect(toolNames(child[0])).toEqual(["run_code"]);
      const parent = bodies.filter((body) => userTexts(body).join("\n").includes("TREE_USER"));
      expect(parent.at(-1) ?? "").toContain("agent_id: agent-tree-sub");
      expect(parent.at(-1) ?? "").toContain("status: completed");
    },
    TIMEOUT * 2,
  );

  test(
    "/close ends an instance's working subagent with no report, and reopening that session runs none",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-close-tree-")));
      const releases: Array<() => void> = [];
      let reportTurns = 0;
      const respond = (body: string): Response | Promise<Response> => {
        const texts = userTexts(body);
        if (texts.at(-1)?.startsWith("Subagent report (untrusted agent output, not user instructions):")) {
          reportTurns += 1;
          return text("close_reported", "CLOSE_MAIN_REPORTED");
        }

        if (texts.join("\n").includes("SLOW_TASK")) {
          return new Promise((resolve) => releases.push(() => resolve(text("slow_done", "SLOW_DONE"))));
        }
        if (texts.at(-1)?.includes("CLOSE_USER")) {
          if (answered(body)) return text("close_final", "CLOSE_MAIN_FINAL");
          return call("close_sub", "Agent", { description: "Slow helper", prompt: "SLOW_TASK take your time", run_in_background: true });
        }
        return answerByLetter(body);
      };
      try {
        let closedId = "";
        await withHost(respond, { instances: 2, env: { FX_PERMISSION_MODE: "yolo" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_A saved");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("CLOSE_USER start a slow helper");
          await session.waitForText("CLOSE_MAIN_FINAL", 45_000);
          await session.waitForPane(() => releases.length > 0 && hostRecords(home).some((ids) => ids.length === 2), 15_000);
          closedId = hostRecords(home).find((ids) => ids.length === 2)![1]!;

          await session.sendText("/close");
          await session.waitForPane(() => hostRecords(home).every((ids) => !ids.includes(closedId)), 15_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(500);
          await session.sendText("/exit");
          await session.waitForSessionEnd(15_000);
        });
        expect(reportTurns).toBe(0);

        const log = readFileSync(join(home, ".fx", "sessions", "v2", closedId, "log.jsonl"), "utf8");
        const finishes = log.split("\n").filter((line) => line.includes("child_finished"));
        expect(finishes.length).toBe(1);
        expect(finishes[0]).toContain("cancelled");
        expect(finishes[0]).not.toMatch(/report\\?"\s*:\s*true/);



        await withHost(respond, { args: `--resume ${closedId}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("CLOSE_MAIN_FINAL"), 30_000);
          await session.waitForComposer(15_000);
          await Bun.sleep(1500);
          expect(await session.capturePane()).not.toContain("CLOSE_MAIN_REPORTED");
        });
        expect(reportTurns).toBe(0);
      } finally {
        for (const release of releases) release();
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a restored later instance lists its subagents under it again, with their conversations",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-restore-tree-")));
      const respond = (body: string) => {
        const texts = userTexts(body);
        if (texts.join("\n").includes("KEEP_TASK")) return text("keep_child", "KEEP_CHILD_DONE");
        if (texts.at(-1)?.includes("KEEP_USER")) {
          if (answered(body)) return text("keep_final", "KEEP_MAIN_FINAL");
          return call("keep_sub", "Agent", { description: "Keeper", prompt: "KEEP_TASK note it" });
        }
        return answerByLetter(body);
      };
      try {
        await withHost(respond, { instances: 2, env: { FX_PERMISSION_MODE: "yolo" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_A saved");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("KEEP_USER start a keeper");
          await session.waitForText("KEEP_MAIN_FINAL", 45_000);
          await session.waitForComposer(15_000);
          await session.sendText("/exit");
          await session.waitForSessionEnd(15_000);
        });
        const group = hostRecords(home).find((ids) => ids.length === 2);
        expect(group).toBeDefined();



        await withHost(respond, { args: `--resume ${group![0]}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("HOST_ANSWER_A"), 30_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("KEEP_MAIN_FINAL"), 15_000);
          await switchAgent(session, "next");
          const keeper = await session.waitForPane((pane) => pane.includes("KEEP_CHILD_DONE") && !pane.includes("fx 1/2"), 15_000);
          expect(keeper).toContain("KEEP_TASK");
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a subagent with no type is a coder whatever its instance's profile, and one with a type gets what the profile says",
    async () => {
      const bodies = await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_PLAIN_TASK")) return answered(body) ? text("plain_done", "TREE_PLAIN_DONE") : call("plain_verbs", "run_code", LIST_VERBS_BODY);
        if (texts.includes("TREE_BUILDER_TASK")) return answered(body) ? text("builder_done", "TREE_BUILDER_DONE") : call("builder_verbs", "run_code", LIST_VERBS_BODY);
        const last = userTexts(body).at(-1) ?? "";
        if (last.includes("TREE_USER_PLAIN")) {
          if (answered(body) && body.includes("plain_sub")) return text("plain_final", "TREE_PLAIN_FINAL");
          if (answered(body)) return call("plain_sub", "Agent", { description: "Plain helper", prompt: "TREE_PLAIN_TASK" });
          return call("instance_verbs", "run_code", LIST_VERBS_BODY);
        }
        if (last.includes("TREE_USER_BUILDER")) {
          if (answered(body)) return text("builder_final", "TREE_BUILDER_FINAL");
          return call("builder_sub", "Agent", { description: "Builder", prompt: "TREE_BUILDER_TASK", subagent_type: "builder" });
        }
        return answerByLetter(body);
      }, { env: { FX_PERMISSION_MODE: "yolo" } }, async ({ home, session }) => {
        writeProfile(home, "noshell", { description: "Everything but the shell", tools: ["*", "!Bash"] });
        writeProfile(home, "builder", { description: "Builds things by reading and running", tools: ["read_file", "Bash"] });
        await session.sendText("/launch noshell");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER_PLAIN start a plain helper");
        await session.waitForText("TREE_PLAIN_FINAL", 45_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER_BUILDER start a builder");
        await session.waitForText("TREE_BUILDER_FINAL", 45_000);
      });
      const holding = (marker: string) => bodies.filter((body) => userTexts(body).join("\n").includes(marker));

      const instance = holding("TREE_USER_PLAIN");
      expect(instance.length).toBeGreaterThan(0);
      expect(toolNames(instance[0])).toEqual(["run_code"]);
      const instanceVerbs = verbNames(instance.find((body) => answered(body) && !body.includes("plain_sub")) ?? "{}");
      expect(instanceVerbs).not.toContain("Bash");
      expect(instanceVerbs).toContain("Agent");
      expect(instance.at(-1) ?? "").toContain("actual_subagent_type: coder");

      const plain = holding("TREE_PLAIN_TASK");
      expect(plain.length).toBeGreaterThan(0);
      expect(toolNames(plain[0])).toEqual(["run_code"]);
      const plainVerbs = verbNames(plain.find(answered) ?? "{}");
      expect(plainVerbs).toContain("Bash");
      expect(plainVerbs).toContain("read_file");
      expect(plainVerbs).not.toContain("Agent");

      const builder = holding("TREE_BUILDER_TASK");
      expect(builder.length).toBeGreaterThan(0);
      expect(toolNames(builder[0])).toEqual(["run_code"]);
      const builderVerbs = verbNames(builder.find(answered) ?? "{}");
      expect(builderVerbs).toContain("read_file");
      expect(builderVerbs).toContain("Bash");
      expect(builderVerbs).not.toContain("write_file");
      expect(holding("TREE_USER_BUILDER").at(-1) ?? "").toContain("actual_subagent_type: builder");
    },
    TIMEOUT,
  );


  test(
    "a launched instance's subagent asks on that instance's screen, not the first's",
    async () => {
      await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_LEND_TASK")) {
          if (answered(body)) return text("lend_child_done", "TREE_LEND_CHILD_DONE");
          return call("lend_write", "write_file", { path: "lent.txt", content: "TREE_LENT\n" });
        }
        if (texts.includes("TREE_LEND_USER")) {
          if (answered(body)) return text("lend_main_done", "TREE_LEND_MAIN_DONE");
          return call("lend_sub", "Agent", { description: "Write the file", prompt: "TREE_LEND_TASK", subagent_type: "writer" });
        }
        return answerByLetter(body);
      }, { instances: 2 }, async ({ home, workspace, session }) => {
        writeProfile(home, "writer", { description: "Writes one file", tools: ["read_file", "write_file"], permission_mode: "ask" });
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_LEND_USER write the file");


        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent agent-lend-sub needs permission"), 30_000);


        await switchAgent(session, 1);
        const first = await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("agent-lend-sub needs approval"), 15_000);
        expect(first).not.toContain("Subagent agent-lend-sub needs permission");


        expect(first).not.toContain("TREE_LEND_USER");
        await switchAgent(session, 2);
        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent agent-lend-sub needs permission"), 15_000);
        await session.sendKeys("1");
        await session.waitForText("TREE_LEND_MAIN_DONE", 30_000);
        expect(readFileSync(join(workspace, "lent.txt"), "utf8")).toBe("TREE_LENT\n");
      });
    },
    TIMEOUT,
  );


  test(
    "an instance's profile decides which MCP servers it can use",
    async () => {
      const fixture = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");


      const respond = (direct: boolean) => (body: string): Response => {
        const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
        const results = (request.prompt ?? []).filter((message) => message.role === "tool").length;
        if (!direct && results === 0) return call("select_mcp", "select_tools", { names: ["mcp__fixture__echo"] });
        if (results === (direct ? 0 : 1)) return call("call_mcp", "mcp__fixture__echo", { text: "hello" });
        return text("mcp_done", "TREE_MCP_DONE");
      };
      for (const [profile, servers, reaches, direct] of [
        ["nomcp", [], false, false],
        ["withmcp", ["fixture"], true, false],
        ["nomcp", [], false, true],
        ["withmcp", ["fixture"], true, true],
      ] as const) {
        const home = createIsolatedTestHome();
        const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-mcp-")));
        try {
          mkdirSync(join(home, ".fx"), { recursive: true });
          writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({

            mcp: { fixture: { type: "local", command: [process.execPath, fixture], enabled: true, environment: { FX_MCP_EXPECT_ELICITATION: "both" } } },
          }));
          writeProfile(home, profile, { description: "Checks MCP access", mcp_servers: servers });
          const bodies = await withHost(respond(direct), {
            args: `--profile ${profile}`,
            env: { FX_PERMISSION_MODE: "yolo" },
            reuse: { home, workspace },
          }, async ({ session }) => {
            await session.sendText("TREE_MCP_USER call the fixture");
            await session.waitForText("TREE_MCP_DONE", 45_000);
          });


          expect((bodies.at(-1) ?? "").includes("MODERN_MCP_TOOL_RESULT")).toBe(reaches);
        } finally {
          cleanupIsolatedTestHome(home);
          rmSync(workspace, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT * 4,
  );


  test(
    "a launched instance's model and speed changes reach its own turns and no other's",
    async () => {
      for (const launch of ["instances", "launch"] as const) {
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, {
          args: `${launch === "instances" ? "--instances 2 " : ""}--model openai/gpt-5 --effort high --fast`,
          env: { FX_MODEL: undefined },
          models: PREFERENCE_MODELS,
          requests,
        }, async ({ session }) => {
          await promptMarker(session, "FIRST_BEFORE");
          if (launch === "instances") {
            await switchAgent(session, "next");
          } else {
            await session.sendText("/launch");
          }
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/model other/model low normal");
          await session.waitForText("Switched to other/model", 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "SECOND_AFTER");
          await switchAgent(session, "previous");
          await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "FIRST_AFTER");
        });
        expect(preferencesOf(requests, "SECOND_AFTER"), launch).toEqual({ model: "other/model", reasoning: "low", speed: null });
        expect(preferencesOf(requests, "FIRST_AFTER"), launch).toEqual({ model: "openai/gpt-5", reasoning: "high", speed: "fast" });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/effort sets the effort of the instance on screen and no other's",
    async () => {
      const requests: Array<{ body: string; headers: Headers }> = [];
      await withHost(echoMarker, {
        args: "--instances 2 --model openai/gpt-5 --effort high",
        env: { FX_MODEL: undefined },
        models: PREFERENCE_MODELS,
        requests,
      }, async ({ session }) => {
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/effort low");
        await session.waitForText("Reasoning effort set to", 15_000);
        await session.waitForComposer(15_000);
        await promptMarker(session, "EFFORT_SECOND");
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForComposer(15_000);
        await promptMarker(session, "EFFORT_FIRST");
      });
      expect(preferencesOf(requests, "EFFORT_SECOND")?.reasoning).toBe("low");
      expect(preferencesOf(requests, "EFFORT_FIRST")?.reasoning).toBe("high");
    },
    TIMEOUT,
  );

  test(
    "/launch <profile> uses the profile's model unless the process chose one",
    async () => {
      for (const [fxModel, expected] of [[undefined, "profile/model"], ["openai/gpt-5", "openai/gpt-5"]] as const) {
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: fxModel }, models: PREFERENCE_MODELS, requests }, async ({ home, session }) => {
          writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "PROFILE_LAUNCH");
        });
        const launched = preferencesOf(requests, "PROFILE_LAUNCH");
        expect(launched?.model, String(fxModel)).toBe(expected);
        expect(launched?.reasoning, String(fxModel)).toBe("high");
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/launch <profile> under fx --profile starts in the launched profile's model and effort",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-launch-in-profile-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        writeProfile(home, "plain", { description: "Sets no model or effort" });
        const requests: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "FIRST_PROFILE");
          for (const [command, count, marker] of [
            ["/launch chooser", 2, "CHOOSER_LAUNCH"],
            ["/launch plain", 3, "PLAIN_LAUNCH"],
            ["/launch", 4, "SAME_LAUNCH"],
          ] as const) {
            await session.sendText(command);
            await session.waitForPane((pane) => pane.includes(`fx ${count}/${count}`), 15_000);
            await session.waitForComposer(15_000);
            await promptMarker(session, marker);
          }
        });
        expect(preferencesOf(requests, "FIRST_PROFILE")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(requests, "CHOOSER_LAUNCH")).toMatchObject({ model: "profile/model", reasoning: "high" });


        const plain = preferencesOf(requests, "PLAIN_LAUNCH");
        expect(plain?.model).not.toBe("other/model");
        expect(plain?.reasoning).toBeNull();

        expect(preferencesOf(requests, "SAME_LAUNCH")).toMatchObject({ model: "other/model", reasoning: "low" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "a group started in profiles resumes in each profile's model and effort, not the run's --effort",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-resume-profiles-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first --effort medium", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "SAVED_FIRST");
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "SAVED_CHOOSER");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "SAVED_FIRST")).toMatchObject({ model: "other/model", reasoning: "medium" });
        expect(preferencesOf(before, "SAVED_CHOOSER")).toMatchObject({ model: "profile/model", reasoning: "medium" });
        const first = sessionHolding(home, "DONE_SAVED_FIRST")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${first}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_SAVED_FIRST"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_FIRST");
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("DONE_SAVED_CHOOSER"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_CHOOSER");
        });


        expect(preferencesOf(after, "RESUMED_FIRST")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(after, "RESUMED_CHOOSER")).toMatchObject({ model: "profile/model", reasoning: "high" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new under fx --profile keeps a /model choice, and its session resumes in it",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-in-profile-")));
      try {
        writeProfile(home, "first", { description: "The launch profile", model: "other/model", effort: "low" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: "--profile first", env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await promptMarker(session, "PROFILE_TURN");
          await session.sendText("/model profile/model medium normal");
          await session.waitForText("Switched to profile/model", 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_PROFILE_TURN"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "PROFILE_TURN")).toMatchObject({ model: "other/model", reasoning: "low" });
        expect(preferencesOf(before, "NEW_TURN")).toMatchObject({ model: "profile/model", reasoning: "medium" });
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });


        expect(preferencesOf(after, "RESUMED_TURN")).toMatchObject({ model: "profile/model", reasoning: "medium" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new in a launched profile instance keeps the profile's model and effort, and its session resumes in them",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-launched-")));
      try {
        writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/launch chooser");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "LAUNCHED_TURN");
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_LAUNCHED_TURN") && pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "LAUNCHED_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
        expect(preferencesOf(before, "NEW_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });
        expect(preferencesOf(after, "RESUMED_TURN")).toMatchObject({ model: "profile/model", reasoning: "high" });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "/new in a launched instance keeps FX_MODEL for the run without saving it",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-new-env-model-")));
      try {
        const before: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { env: { FX_MODEL: "other/model" }, models: PREFERENCE_MODELS, requests: before, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/launch");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "LAUNCHED_TURN");
          await session.sendText("/new");
          await session.waitForPane((pane) => !pane.includes("DONE_LAUNCHED_TURN") && pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "NEW_TURN");
          await quitWith(session, "/exit");
        });
        expect(preferencesOf(before, "LAUNCHED_TURN")?.model).toBe("other/model");
        expect(preferencesOf(before, "NEW_TURN")?.model).toBe("other/model");
        const id = sessionHolding(home, "DONE_NEW_TURN")!;
        const after: Array<{ body: string; headers: Headers }> = [];
        await withHost(echoMarker, { args: `--resume ${id}`, env: { FX_MODEL: undefined }, models: PREFERENCE_MODELS, requests: after, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("DONE_NEW_TURN"), 30_000);
          await session.waitForComposer(15_000);
          await promptMarker(session, "RESUMED_TURN");
        });

        expect(preferencesOf(after, "RESUMED_TURN")?.model).not.toBe("other/model");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT * 2,
  );

  test(
    "fx --profile <name> uses the profile's model unless the process chose one",
    async () => {
      for (const [args, fxModel, expected] of [
        ["--profile chooser", undefined, "profile/model"],
        ["--profile chooser", "openai/gpt-5", "openai/gpt-5"],
        ["--profile chooser --model other/model", "openai/gpt-5", "other/model"],
      ] as const) {
        const label = `${args} FX_MODEL=${fxModel}`;
        const home = createIsolatedTestHome();
        const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-profile-model-")));
        try {
          writeProfile(home, "chooser", { description: "Chooses a model", model: "profile/model", effort: "high" });
          const requests: Array<{ body: string; headers: Headers }> = [];
          await withHost(echoMarker, { args, env: { FX_MODEL: fxModel }, models: PREFERENCE_MODELS, requests, reuse: { home, workspace } }, async ({ session }) => {
            await promptMarker(session, "PROFILE_START");
          });
          const started = preferencesOf(requests, "PROFILE_START");
          expect(started?.model, label).toBe(expected);
          expect(started?.reasoning, label).toBe("high");
        } finally {
          cleanupIsolatedTestHome(home);
          rmSync(workspace, { recursive: true, force: true });
        }
      }
    },
    TIMEOUT * 3,
  );

  test(
    "a subagent calls the MCP tool it selected, and is offered only what its profile admits",
    async () => {
      const fixture = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-mcp-child-")));
      try {
        mkdirSync(join(home, ".fx"), { recursive: true });
        writeFileSync(join(home, ".fx", "mcp.json"), JSON.stringify({
          mcp: { fixture: { type: "local", command: [process.execPath, fixture], enabled: true, environment: { FX_MCP_EXPECT_ELICITATION: "both" } } },
        }));
        writeProfile(home, "mcp-child", { description: "Uses the fixture", tools: ["read_file", "select_tools"], mcp_servers: ["fixture"] });
        const bodies = await withHost((body) => {
          const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
          const results = (request.prompt ?? []).filter((message) => message.role === "tool").length;
          if (userTexts(body).join("\n").includes("CHILD_MCP_TASK")) {
            if (results === 0) return call("child_verbs", "run_code", LIST_VERBS_BODY);
            if (results === 1) return call("call_mcp", "run_code", CALL_FIXTURE_ECHO);
            return text("child_mcp_done", "CHILD_MCP_DONE");
          }

          if (results === 0) return call("start_child", "Agent", { description: "Call the fixture", prompt: "CHILD_MCP_TASK", subagent_type: "mcp-child" });
          return text("parent_mcp_done", "PARENT_MCP_DONE");
        }, { env: { FX_PERMISSION_MODE: "yolo" }, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("PARENT_MCP start the child");
          await session.waitForText("PARENT_MCP_DONE", 45_000);
        });
        const child = bodies.filter((body) => userTexts(body).join("\n").includes("CHILD_MCP_TASK"));

        expect(child.at(-1) ?? "").toContain("MODERN_MCP_TOOL_RESULT");

        expect(toolNames(child[0])).toEqual(["run_code"]);
        const childVerbs = verbNames(child[1] ?? "{}");
        expect(childVerbs).toContain("read_file");
        expect(childVerbs).toContain("mcp__fixture__echo");
        expect(childVerbs).not.toContain("Bash");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );


  test(
    "resuming brings each instance back in the profile it ran in",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-profiles-")));
      try {
        writeProfile(home, "limited", { description: "Reads only", tools: ["read_file"] });

        await withHost(answerByLetter, { remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A first run");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await session.waitForComposer(15_000);
          await session.sendText("/launch limited");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_B first run");
          await session.waitForText("HOST_ANSWER_B", 30_000);
          await quitWith(session, "/exit");
        });
        const [a, b] = ["A", "B"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
        expect(hostRecords(home)).toEqual([[a, b]]);
        expect(hostProfiles(home)).toEqual([["main", "limited"]]);



        const bodies = await withHost(answerAfterVerbs, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("HOST_ANSWER_B"), 30_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_C on the limited one");
          await session.waitForText("HOST_ANSWER_C", 30_000);
          await session.waitForComposer(15_000);
          await switchAgent(session, "next");
          await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("HOST_ANSWER_A"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_D on the main one");
          await session.waitForText("HOST_ANSWER_D", 30_000);
        });
        const limited = lettersVerbs(bodies, "C");
        const unlimited = lettersVerbs(bodies, "D");
        expect(limited).toContain("read_file");
        expect(limited).not.toContain("Bash");
        expect(unlimited).toContain("Bash");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a lone instance in a profile resumes in it, unless --profile names another",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-lone-profile-")));
      try {
        writeProfile(home, "limited", { description: "Reads only", tools: ["read_file"] });
        await withHost(answerByLetter, { args: "--profile limited", remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A only run");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          await quitWith(session, "/exit");
        });
        const a = sessionHolding(home, "HOST_ANSWER_A")!;
        expect(hostRecords(home)).toEqual([[a]]);
        expect(hostProfiles(home)).toEqual([["limited"]]);
        const resumed = async (args: string, letter: string) => {
          const bodies = await withHost(answerAfterVerbs, { args, reuse: { home, workspace } }, async ({ session }) => {
            await session.waitForPane((pane) => pane.includes("HOST_ANSWER_A"), 30_000);
            await session.waitForComposer(15_000);
            await session.sendText(`HOST_${letter} resumed`);
            await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
          });
          return lettersVerbs(bodies, letter);
        };
        expect(await resumed(`--resume ${a}`, "B")).not.toContain("Bash");
        expect(await resumed(`--profile main --resume ${a}`, "C")).toContain("Bash");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a hidden instance's waiting note names it by number, before the agent indicator",
    async () => {
      await withHost((body) => {
        if (answered(body)) return text("note_done", "NOTE_DONE");
        return call("note_shell", "Bash", { command: "rm -rf ./nothing-here", description: "Remove nothing" });
      }, { instances: 3, env: { FX_PERMISSION_MODE: "ask" } }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("NOTE_THREE go");
        await session.waitForPane((pane) => pane.includes("rm -rf"), 15_000);

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 3 needs approval · fx 1/3 \u2193"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("NOTE_ONE go");
        await session.waitForPane((pane) => pane.includes("rm -rf"), 15_000);

        await switchAgent(session, "next");
        const pane = await session.waitForPane((value) => value.includes("fx 2/3") && value.includes("need you"), 15_000);
        expect(pane).toContain("fx 1 and 1 more need you · fx 2/3 \u2193");
        expect(pane).not.toContain("main");
      });
    },
    TIMEOUT,
  );


  test(
    "/agents lists the open agents, and Enter keeps the one shown",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);


        await session.sendText("/status");
        await session.waitForPane((pane) => pane.includes("Step limit"), 15_000);
        await session.sendKeys("C-x");
        const list = await session.waitForPane((pane) => pane.includes("fx 3 ·"), 15_000);
        expect(list).not.toContain("Step limit");
        expect(list).toContain("fx 1 (on screen) ·");
        expect(list).toContain("fx 2 · new session · main · idle");
        expect(list).toContain("fx 3 · new session · main · idle");
        expect(list).toContain(LIST_HINT);

        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("fx 3 ·"), 15_000);

        await session.sendText("/agents");
        await session.waitForPane((pane) => pane.includes("fx 3 ·"), 15_000);
        await session.sendKeys("Down");
        await session.sendKeys("Down");
        await session.sendKeys("Enter");
        await session.waitForPane((pane) => pane.includes("fx 3/3") && !pane.includes("fx 3 ·"), 15_000);
        await session.waitForComposer(15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "down on an empty composer opens the agent list while another agent is open, and not with one",
    async () => {
      await withHost(answerByLetter, {}, async ({ session }) => {
        await session.sendKeys("Down");
        await Bun.sleep(500);
        expect(await session.capturePane()).not.toContain("fx 1 (on screen)");
        await session.sendText("/launch");
        await session.waitForPane((pane) => pane.includes("fx 2/2 \u2193"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendKeys("Down");
        const list = await session.waitForPane((pane) => pane.includes("fx 2 (on screen) ·"), 15_000);
        expect(list).toContain("fx 1 ·");
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("fx 2 (on screen) ·"), 15_000);



        await session.sendLiteral("first");
        await session.sendKeys("M-Enter");
        await session.sendLiteral("second");
        await session.waitForPane((pane) => pane.includes("second") && pane.includes("fx 2/2 · ctrl+x"), 10_000);
        await session.sendKeys("Down");
        await session.sendKeys("M-Up");
        await session.sendLiteral("Z");
        const moved = await session.waitForPane((pane) => pane.includes("Z"), 10_000);
        expect(moved).not.toContain("(on screen) ·");
        expect(moved).not.toContain("secondZ");
      });
    },
    TIMEOUT,
  );

  test(
    "the agent list puts each instance's subagents under it and marks the agent on screen",
    async () => {
      await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("LIST_TASK")) return text("list_child", "LIST_CHILD_DONE");
        if (texts.includes("LIST_USER")) {
          if (answered(body)) return text("list_main_final", "LIST_MAIN_FINAL");
          return call("list_sub", "Agent", { description: "Look", prompt: "LIST_TASK look" });
        }
        return answerByLetter(body);
      }, { instances: 2, env: { FX_PERMISSION_MODE: "yolo" } }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("LIST_USER start a helper");
        await session.waitForText("LIST_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("agent-list-sub \u00b7 "), 15_000);
        await session.sendKeys("C-x");
        const list = await session.waitForPane((pane) => pane.includes("agent-list-sub (on screen) ·"), 15_000);
        const rows = list.split("\n");
        const first = rows.findIndex((row) => row.includes("fx 1 ·"));
        const helper = rows.findIndex((row) => row.includes("    agent-list-sub (on screen) ·"));
        const second = rows.findIndex((row) => row.includes("fx 2 ·"));
        expect(first).toBeGreaterThanOrEqual(0);
        expect(helper).toBe(first + 1);
        expect(second).toBe(helper + 1);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("agent-list-sub \u00b7 "), 15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a hidden instance that finishes is named in the footer until it is shown",
    async () => {
      await withHost(async (body) => {
        if (userTexts(body).join("\n").includes("HOST_S")) await Bun.sleep(1500);
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_S slow work");
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.waitForPane((pane) => pane.includes("fx 2 finished · fx 1/2 \u2193"), 15_000);
        await session.sendText("/agents");
        const list = await session.waitForPane((pane) => pane.includes("fx 2 ·"), 15_000);
        expect(list).toMatch(/fx 2 · .* · main · finished/);
        await session.sendKeys("Escape");

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("HOST_ANSWER_S"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await Bun.sleep(300);
        expect(await session.capturePane()).not.toContain("finished ·");
      });
    },
    TIMEOUT,
  );

  test(
    "a hidden instance whose request waits for you is named in the footer and the list",
    async () => {
      await withHost((body) => {
        if (userTexts(body).join("\n").includes("HOST_R")) return rejected();
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_R refused");

        await session.waitForText("The provider rejected this request · press Esc", 30_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("fx 2 needs you · fx 1/2 \u2193"), 15_000);
        await session.sendText("/agents");
        const list = await session.waitForPane((pane) => pane.includes("fx 2 ·"), 15_000);
        expect(list).toMatch(/fx 2 · .* · main · needs you/);
        await session.sendKeys("Escape");

        await switchAgent(session, "next");
        await session.waitForPane((pane) => pane.includes("fx 2/2") && pane.includes("press Esc"), 15_000);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("The provider rejected this request"), 15_000);
        await switchAgent(session, "previous");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await Bun.sleep(300);
        expect(await session.capturePane()).not.toContain("needs you");
      });
    },
    TIMEOUT,
  );

});
