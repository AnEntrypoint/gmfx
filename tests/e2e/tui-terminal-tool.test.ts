import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { rootSessionIds } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const sessions: TmuxSession[] = [];
const roots: string[] = [];
const gateways: Array<ReturnType<typeof startFakeGateway>> = [];

type Fixture = ReturnType<typeof createFixture>;
type Gateway = ReturnType<typeof startFakeGateway>;

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createFixture(prefix: string) {
  const root = realpathSync(mkdtempSync(join("/tmp", prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "yolo",
      sandbox: "os",
      yolo_acknowledged: true,
      permission: {},
    }) + "\n",
  );
  writeFileSync(stderrPath, "");
  roots.push(root);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    stderrPath,
  };
}

function tuiEnv(fixture: Fixture, gateway: Gateway): Record<string, string | undefined> {
  return {
    HOME: fixture.home,
    SHELL: terminalFixtureShell(),
    AI_GATEWAY_API_KEY: "fake-shell-tool-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_PERMISSION_MODE: "yolo",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
  };
}

function askEnv(fixture: Fixture, gateway: Gateway): Record<string, string | undefined> {
  return {
    ...tuiEnv(fixture, gateway),
    FX_DISABLE_KEYCHAIN: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
  };
}

async function launch(
  fixture: Fixture,
  gateway: Gateway,
  options: { cmd?: string; width?: number; height?: number } = {},
) {
  const session = await TmuxSession.create({
    isolated: true,
    cmd: options.cmd ?? FX_BIN,
    cwd: fixture.workspace,
    env: tuiEnv(fixture, gateway),
    width: options.width ?? 120,
    height: options.height ?? 32,
    stderrPath: fixture.stderrPath,
  });
  sessions.push(session);
  await session.waitForComposer(TIMEOUT);
  return session;
}

function runCodeValue(text: string): string {
  const open = text.indexOf("\n\n<fx-context-update>");
  const body = open < 0 ? text : text.slice(0, open);
  try {
    const reply = JSON.parse(body);
    if (typeof reply?.ok !== "boolean") return text;
    const inner = reply.ok ? reply.value : reply.error;
    return (typeof inner === "string" ? inner : JSON.stringify(inner)) + text.slice(body.length);
  } catch {
    return text;
  }
}

function toolResultTexts(body: string, toolCallId: string): string[] {
  const texts: string[] = [];
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item);
      return;
    }
    if (!value || typeof value !== "object") return;
    const object = value as Record<string, unknown>;
    if (object.type === "tool-result" && object.toolCallId === toolCallId) {
      const output = object.output as { value?: unknown } | undefined;
      texts.push(runCodeValue(typeof output?.value === "string" ? output.value : JSON.stringify(object.output)));
    }
    for (const child of Object.values(object)) visit(child);
  };
  visit(JSON.parse(body));
  return texts;
}

function toolResult(body: string, toolCallId: string): string {
  const text = toolResultTexts(body, toolCallId).at(-1);
  if (text === undefined) throw new Error(`missing tool result ${toolCallId}`);
  return text;
}

function latestToolResult(gateway: Gateway, toolCallId: string): string {
  for (const request of gateway.requests.toReversed()) {
    const text = toolResultTexts(request.body, toolCallId).at(-1);
    if (text !== undefined) return text;
  }
  throw new Error(`no request carries tool result ${toolCallId}`);
}

function startedTaskId(body: string, toolCallId: string): string {
  const match = /"session_id":"([^"]+)"/.exec(toolResult(body, toolCallId));
  if (!match) throw new Error(`tool result ${toolCallId} names no task`);
  return match[1]!;
}

function background(id: string, command: string, extra: Record<string, unknown> = {}) {
  return fakeGatewayVerbCall(id, "Bash", {
    command,
    run_in_background: true,
    description: "Run in the background",
    ...extra,
  });
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function processesRunning(command: string): number[] {
  const listing = execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" });
  return listing.split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(.*)$/);
    return match && match[2]!.trim() === command ? [Number(match[1])] : [];
  });
}

async function waitUntilGone(pids: number[], timeoutMs: number): Promise<void> {
  const started = Date.now();
  while (pids.some(processAlive)) {
    if (Date.now() - started > timeoutMs) {
      throw new Error(`processes still running after ${timeoutMs}ms: ${pids.filter(processAlive)}`);
    }
    await Bun.sleep(10);
  }
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${path}`);
}

async function recordedPid(path: string): Promise<number> {
  await waitForFile(path);
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const pid = Number(readFileSync(path, "utf8"));
    if (Number.isSafeInteger(pid) && pid > 0) return pid;
    await Bun.sleep(10);
  }
  throw new Error(`${path} never held a pid`);
}

function trimmedRows(grid: string[]): string[] {
  return grid.map((line) => line.trimEnd());
}

test.skipIf(!tmuxAvailable())(
  "a task read with no output yet waits for the command and returns its completed output without respawn",
  async () => {
    const fixture = createFixture("fx-task-read-floor-");
    const runsPath = join(fixture.root, "runs.txt");
    const command = `printf x >> ${JSON.stringify(runsPath)}; sleep 2; printf CAPTURED_DONE`;
    let taskId = "";
    const gateway = startFakeGateway([
      background("task_run", command),
      (body) => {
        taskId = startedTaskId(body, "task_run");
        return fakeGatewayVerbCall("task_read", "TaskOutput", { task_id: taskId });
      },
      fakeGatewayFinalText("TASK_READ_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the background command and read it.");
    await active.sendKeys("Enter");
    await active.waitForText("TASK_READ_OK", TIMEOUT);

    expect(taskId.length).toBeGreaterThan(0);
    const runResult = latestToolResult(gateway, "task_run");
    expect(runResult).toContain(`"session_id":"${taskId}"`);
    expect(runResult).toContain('"state":"running"');
    expect(runResult).not.toContain('"next_action"');
    const readResult = latestToolResult(gateway, "task_read");
    expect(readResult).toContain(`"session_id":"${taskId}"`);
    expect(readResult).toContain('"state":"completed"');
    expect(readResult).toContain('"exit_code":0');
    expect(readResult).toContain('"output_delta":"CAPTURED_DONE"');
    expect(readFileSync(runsPath, "utf8")).toBe("x");
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Ran printf x >> ");
    expect(scrollback).toContain("Read task printf x >> ");
    expect(scrollback).not.toContain(`Read task ${taskId}`);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a running background task survives a model-completed turn and stops in a later turn",
  async () => {
    const fixture = createFixture("fx-task-cross-turn-");
    const pidPath = join(fixture.root, "cross-turn.pid");
    let taskId = "";
    const gateway = startFakeGateway([
      background(
        "task_cross_turn_run",
        `printf '%s' "$$" > ${JSON.stringify(pidPath)}; printf HANDOFF_READY; sleep 30`,
      ),
      (body) => {
        taskId = startedTaskId(body, "task_cross_turn_run");
        return fakeGatewayFinalText("PHASE_ONE_READY");
      },
      () => fakeGatewayVerbCall("task_cross_turn_stop", "TaskStop", { task_id: taskId }),
      fakeGatewayFinalText("PHASE_TWO_READY"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Start the command and return control while it remains active.");
    await active.sendKeys("Enter");
    await active.waitForText("PHASE_ONE_READY", TIMEOUT);
    expect(taskId.length).toBeGreaterThan(0);
    const pid = await recordedPid(pidPath);
    await active.waitForStableComposer(TIMEOUT);
    expect(processAlive(pid)).toBe(true);

    await active.sendText("Stop the exact retained command now.");
    await active.sendKeys("Enter");
    await active.waitForText("PHASE_TWO_READY", TIMEOUT);
    const stopResult = latestToolResult(gateway, "task_cross_turn_stop");
    expect(stopResult).toContain("reason: Stopped by TaskStop");
    expect(stopResult).toContain(`"session_id":"${taskId}"`);
    expect(stopResult).toContain('"state":"stopped"');
    expect(stopResult).toContain("HANDOFF_READY");
    await waitUntilGone([pid], 1_000);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Stopped task printf '%s' \"$$\" > ");
    expect(scrollback).not.toContain(`Stopped task ${taskId}`);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "TaskStop settles a stubborn background command and permits later work",
  async () => {
    const fixture = createFixture("fx-task-force-stop-");
    const pidPath = join(fixture.workspace, "stubborn.pid");
    let taskId = "";
    const gateway = startFakeGateway([
      background(
        "task_stubborn_run",
        `printf '%s' "$$" > ${JSON.stringify(pidPath)}; trap '' TERM; while :; do sleep 1; done`,
      ),
      async (body) => {
        taskId = startedTaskId(body, "task_stubborn_run");
        await recordedPid(pidPath);
        return fakeGatewayVerbCall("task_stubborn_stop", "TaskStop", { task_id: taskId });
      },
      fakeGatewayVerbCall("task_after_stop", "Bash", { command: "printf AFTER_STOP" }),
      fakeGatewayFinalText("TASK_FORCE_STOP_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Stop the stubborn command, then run the follow-up command.");
    await active.sendKeys("Enter");
    await active.waitForText("TASK_FORCE_STOP_OK", TIMEOUT);

    expect(taskId.length).toBeGreaterThan(0);
    const stopResult = latestToolResult(gateway, "task_stubborn_stop");
    expect(stopResult).toContain('"state":"stopped"');
    expect(stopResult).toContain('"signal":9');
    expect(stopResult).not.toContain("termination_indeterminate");
    const followUp = latestToolResult(gateway, "task_after_stop");
    expect(followUp).toContain('"state":"completed"');
    expect(followUp).toContain('"output_delta":"AFTER_STOP"');
    await waitUntilGone([await recordedPid(pidPath)], 3_000);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "reused provider call ids start distinct background commands",
  async () => {
    const fixture = createFixture("fx-task-reused-call-id-");
    const firstMarker = join(fixture.workspace, "first-command.txt");
    const secondMarker = join(fixture.workspace, "second-command.txt");
    const firstPid = join(fixture.root, "first.pid");
    const secondPid = join(fixture.root, "second.pid");
    const gateway = startFakeGateway([
      background(
        "reused_task_call",
        `printf '%s' "$$" > ${JSON.stringify(firstPid)}; printf first > ${JSON.stringify(firstMarker)}; sleep 30`,
      ),
      fakeGatewayFinalText("FIRST_REUSED_CALL_DONE"),
      background(
        "reused_task_call",
        `printf '%s' "$$" > ${JSON.stringify(secondPid)}; printf second > ${JSON.stringify(secondMarker)}; sleep 30`,
      ),
      fakeGatewayFinalText("SECOND_REUSED_CALL_DONE"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("Run the first background command.");
    await active.sendKeys("Enter");
    await active.waitForText("FIRST_REUSED_CALL_DONE", TIMEOUT);
    await active.sendText("Run the second background command.");
    await active.sendKeys("Enter");
    await active.waitForText("SECOND_REUSED_CALL_DONE", TIMEOUT);

    const startedIds = toolResultTexts(gateway.requests[3]!.body, "reused_task_call").map((text) =>
      /"session_id":"([^"]+)"/.exec(text)?.[1]
    );
    expect(startedIds).toHaveLength(2);
    expect(startedIds[0]).toBeDefined();
    expect(startedIds[1]).toBeDefined();
    expect(startedIds[0]).not.toBe(startedIds[1]);
    expect(startedTaskId(gateway.requests[1]!.body, "reused_task_call")).toBe(startedIds[0]!);
    await Promise.all([waitForFile(firstMarker), waitForFile(secondMarker)]);
    expect(readFileSync(firstMarker, "utf8")).toBe("first");
    expect(readFileSync(secondMarker, "utf8")).toBe("second");
    const pids = [await recordedPid(firstPid), await recordedPid(secondPid)];
    expect(pids.every(processAlive)).toBe(true);

    await active.sendText("/quit");
    expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
    await waitUntilGone(pids, 1_000);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "overlapping background tasks keep lifecycle output isolated",
  async () => {
    const fixture = createFixture("fx-task-overlap-");
    let firstTaskId = "";
    let secondTaskId = "";
    const gateway = startFakeGateway([
      background("task_overlap_first", "sleep 0.8; printf FIRST_OVERLAP"),
      (body) => {
        firstTaskId = startedTaskId(body, "task_overlap_first");
        return background("task_overlap_second", "sleep 0.4; printf SECOND_OVERLAP");
      },
      (body) => {
        secondTaskId = startedTaskId(body, "task_overlap_second");
        return fakeGatewayVerbCall("task_overlap_wait_first", "WaitFor", {
          timeout: 20,
          task_id: firstTaskId,
        });
      },
      () => fakeGatewayVerbCall("task_overlap_wait_second", "WaitFor", {
        timeout: 20,
        task_id: secondTaskId,
      }),
      fakeGatewayFinalText("TASK_OVERLAP_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run both overlapping background commands.");
    await active.sendKeys("Enter");
    await active.waitForText("TASK_OVERLAP_OK", TIMEOUT);

    expect(firstTaskId.length).toBeGreaterThan(0);
    expect(secondTaskId.length).toBeGreaterThan(0);
    expect(secondTaskId).not.toBe(firstTaskId);
    const firstResult = latestToolResult(gateway, "task_overlap_wait_first");
    const secondResult = latestToolResult(gateway, "task_overlap_wait_second");
    expect(firstResult).toContain(`"session_id":"${firstTaskId}"`);
    expect(firstResult).toContain('"state":"completed"');
    expect(firstResult).toContain("FIRST_OVERLAP");
    expect(firstResult).not.toContain("SECOND_OVERLAP");
    expect(secondResult).toContain(`"session_id":"${secondTaskId}"`);
    expect(secondResult).toContain('"state":"completed"');
    expect(secondResult).toContain("SECOND_OVERLAP");
    expect(secondResult).not.toContain("FIRST_OVERLAP");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

function observedTaskFlow(prefix: string, launchCommand: string, done: string) {
  let taskId = "";
  return startFakeGateway([
    background(`${prefix}_run`, launchCommand),
    (body) => {
      taskId = startedTaskId(body, `${prefix}_run`);
      return fakeGatewayVerbCall(`${prefix}_observe`, "TaskOutput", { task_id: taskId });
    },
    () => fakeGatewayVerbCall(`${prefix}_stop`, "TaskStop", { task_id: taskId }),
    fakeGatewayFinalText(done),
  ]);
}

test.skipIf(!tmuxAvailable())(
  "task command statuses reclip to the live width instead of the activity cap",
  async () => {
    const fixture = createFixture("fx-task-width-");
    const launchCommand = `echo ${"f".repeat(100)} >/dev/null; sleep 60`;
    const gateway = observedTaskFlow("task_width", launchCommand, "WIDTH_FLOW_DONE");
    gateways.push(gateway);
    const session = await launch(fixture, gateway, { width: 160 });
    await session.sendText("Run and observe the task.");
    await session.waitForText("WIDTH_FLOW_DONE", TIMEOUT);
    await session.waitForStableComposer(TIMEOUT);

    const wideRows = trimmedRows(await session.capturePaneGrid());
    const row = (rows: string[], prefix: string) => rows.find((line) => line.startsWith(prefix));
    expect(row(wideRows, "├ Ran ")).toBe(`├ Ran ${launchCommand}`);
    expect(row(wideRows, "├ Read task ")).toBe(`├ Read task ${launchCommand}`);
    expect(row(wideRows, "└ Stopped task ")).toBe(`└ Stopped task ${launchCommand}`);

    await session.resizeWindow(100, 32);
    await session.waitForPane((pane) => pane.includes("├ Ran echo ") && pane.includes("…"), TIMEOUT);
    const narrowRows = trimmedRows(await session.capturePaneGrid());
    for (const prefix of ["├ Ran ", "├ Read task ", "└ Stopped task "]) {
      const narrow = row(narrowRows, prefix);
      expect(narrow).toBeDefined();
      expect(narrow).toEndWith("…");
      expect(narrow!.length).toBe(100);
    }
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O shows task launch commands in full while the main view trails them",
  async () => {
    const fixture = createFixture("fx-task-full-transcript-width-");
    const words = Array.from({ length: 30 }, (_, index) => `word${index}`).join(" ");
    const launchCommand = `echo ${words} FULL_LAUNCH_TAIL >/dev/null; sleep 60`;
    const gateway = observedTaskFlow("task_full_width", launchCommand, "FULL_WIDTH_FLOW_DONE");
    gateways.push(gateway);
    const session = await launch(fixture, gateway, { width: 100, height: 72 });
    await session.sendText("Run and observe the task.");
    await session.waitForText("FULL_WIDTH_FLOW_DONE", TIMEOUT);
    await session.waitForStableComposer(TIMEOUT);

    const mainRows = trimmedRows(await session.capturePaneGrid());
    const mainRead = mainRows.find((line) => line.startsWith("├ Read task "));
    expect(mainRead).toBeDefined();
    expect(mainRead).toEndWith("…");
    expect(mainRows.join("\n")).not.toContain("FULL_LAUNCH_TAIL");

    const fullReadHeading = (grid: string[]) => {
      const rows = trimmedRows(grid);
      const start = rows.findIndex((line) => line.startsWith("● Read task "));
      if (start < 0) return null;
      const parts = [rows[start]!.slice("● ".length).trim()];
      for (const line of rows.slice(start + 1)) {
        if (line.trim() === "" || /^ {4}[a-z_]+: /.test(line) || /^ {4}\d{2}:\d{2}:\d{2}\b/.test(line)) break;
        parts.push(line.trim());
      }
      return parts.join(" ");
    };
    const expectedHeading = `Read task ${launchCommand}`;
    const settledFullGrid = async () => {
      const deadline = Date.now() + TIMEOUT;
      let grid = await session.capturePaneGrid();
      while (fullReadHeading(grid) !== expectedHeading && Date.now() < deadline) {
        await Bun.sleep(50);
        grid = await session.capturePaneGrid();
      }
      return grid;
    };
    await session.sendKeys("C-o");
    await session.waitForText("esc close · pgup/pgdn scroll", TIMEOUT);
    let grid = await settledFullGrid();
    expect(fullReadHeading(grid), grid.join("\n")).toBe(expectedHeading);
    expect(grid.join("\n")).toContain("task_id: ");
    expect(grid.join("\n")).not.toContain("…");

    await session.resizeWindow(60, 72);
    grid = await settledFullGrid();
    expect(fullReadHeading(grid), grid.join("\n")).toBe(expectedHeading);
    expect(grid.join("\n")).not.toContain("…");

    await session.sendKeys("C-o");
    await session.waitForPane((pane) => !pane.includes("esc close · pgup/pgdn scroll"), TIMEOUT);
    const scrollback = await session.captureFullScrollback();
    expect(scrollback).toContain("├ Read task echo word0");
    expect(scrollback).not.toContain("FULL_LAUNCH_TAIL");
    expect(scrollback).not.toContain("task_id: ");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "resumed task rows reclip to the live width from recorded launch commands",
  async () => {
    const fixture = createFixture("fx-task-resume-width-");
    const launchCommand = `echo ${"r".repeat(100)} >/dev/null; sleep 60`;
    const gateway = observedTaskFlow("task_resume", launchCommand, "RESUME_WIDTH_DONE");
    gateways.push(gateway);
    const session = await TmuxSession.create({
      isolated: true,
      cmd: "/bin/sh -i",
      cwd: fixture.workspace,
      env: { ...tuiEnv(fixture, gateway), PS1: "RESUME_SHELL> " },
      width: 160,
      height: 36,
    });
    sessions.push(session);
    await session.waitForText("RESUME_SHELL>", TIMEOUT);
    await session.sendText(`${FX_BIN} 2>${fixture.stderrPath}`);
    await session.waitForStableComposer(TIMEOUT);
    await session.sendText("Run and observe the task.");
    await session.waitForText("RESUME_WIDTH_DONE", TIMEOUT);
    await session.sendText("/quit");
    await session.waitForText("RESUME_SHELL>", TIMEOUT);

    const fxSessionIds = rootSessionIds(fixture.home);
    expect(fxSessionIds).toHaveLength(1);

    await session.sendText(`${FX_BIN} --resume ${fxSessionIds[0]} 2>>${fixture.stderrPath}`);
    await session.waitForText("session resumed", TIMEOUT);
    await session.waitForStableComposer(TIMEOUT);

    const rows = trimmedRows(await session.capturePaneGrid());
    const row = (prefix: string) => rows.find((line) => line.startsWith(prefix));
    expect(row("├ Ran ")).toBe(`├ Ran ${launchCommand}`);
    expect(row("├ Read task ")).toBe(`├ Read task ${launchCommand}`);
    expect(row("└ Stopped task ")).toBe(`└ Stopped task ${launchCommand}`);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "task output reads advance one runtime-owned cursor without duplicate output",
  async () => {
    const fixture = createFixture("fx-task-cursor-");
    const firstPrinted = join(fixture.root, "first-printed");
    const gate = join(fixture.root, "gate");
    let taskId = "";
    const gateway = startFakeGateway([
      background(
        "task_cursor_run",
        `printf 'CURSOR_FIRST\\n'; touch ${JSON.stringify(firstPrinted)}; ` +
          `until [ -e ${JSON.stringify(gate)} ]; do sleep 0.1; done; printf 'CURSOR_SECOND\\n'`,
      ),
      async (body) => {
        taskId = startedTaskId(body, "task_cursor_run");
        await waitForFile(firstPrinted);
        return fakeGatewayVerbCall("task_cursor_read", "TaskOutput", { task_id: taskId, wait: 1 });
      },
      () => {
        writeFileSync(gate, "");
        return fakeGatewayVerbCall("task_cursor_read_two", "TaskOutput", { task_id: taskId, wait: 20 });
      },
      () => fakeGatewayVerbCall("task_cursor_read_three", "TaskOutput", { task_id: taskId }),
      fakeGatewayFinalText("TASK_CURSOR_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the task cursor flow.");
    await active.sendKeys("Enter");
    await active.waitForText("TASK_CURSOR_OK", TIMEOUT);

    const first = latestToolResult(gateway, "task_cursor_read");
    const second = latestToolResult(gateway, "task_cursor_read_two");
    const third = latestToolResult(gateway, "task_cursor_read_three");
    expect(first).toContain('"state":"running"');
    expect(first).toContain("CURSOR_FIRST");
    expect(first).not.toContain("CURSOR_SECOND");
    expect(second).toContain('"state":"completed"');
    expect(second).toContain("CURSOR_SECOND");
    expect(second).not.toContain("CURSOR_FIRST");
    expect(third).toContain('"state":"completed"');
    expect(third).toContain('"output_delta":""');
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a foreground timeout stops the owned process and reports the deadline",
  async () => {
    const fixture = createFixture("fx-bash-timeout-");
    const pidPath = join(fixture.root, "timeout.pid");
    const gateway = startFakeGateway([
      fakeGatewayVerbCall("bash_timeout_run", "Bash", {
        command: `printf '%s' "$$" > ${JSON.stringify(pidPath)}; printf 'TIMEOUT_READY\\n'; sleep 30`,
        timeout: 1,
      }),
      fakeGatewayFinalText("BASH_TIMEOUT_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the foreground timeout flow.");
    await active.sendKeys("Enter");
    await active.waitForText("BASH_TIMEOUT_OK", TIMEOUT);

    const result = latestToolResult(gateway, "bash_timeout_run");
    expect(result).toContain('"state":"stopped"');
    expect(result).toContain('"error":"TimeoutExpired"');
    expect(result).toContain("ran past its timeout");
    expect(result).toContain("TIMEOUT_READY");
    expect(result).not.toContain("termination_indeterminate");
    await waitUntilGone([await recordedPid(pidPath)], 1_000);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("1 timed out");
    expect(scrollback).toContain("└ Timed out printf '%s' \"$$\" > ");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test("a foreground timeout stops a nested interactive shell before its next command", async () => {
  const fixture = createFixture("fx-bash-timeout-tree-");
  const pidFile = join(fixture.root, "nested-shell.pid");
  const marker = join(fixture.root, "after-timeout");
  const gateway = startFakeGateway([
    fakeGatewayVerbCall("bash_tree_timeout_run", "Bash", {
      command: `bash --norc --noprofile -i -c 'printf %s $$ > ${pidFile}; sleep 3; touch ${marker}'`,
      timeout: 1,
    }),
    fakeGatewayFinalText("TREE_TIMEOUT_DONE"),
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Run the nested shell."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  expect(toolResult(gateway.requests[1]!.body, "bash_tree_timeout_run")).toContain(
    '"error":"TimeoutExpired"',
  );
  const report = JSON.parse(result.stdout) as {
    tool_calls: Array<{ status: string; error?: { code: string }; command_result?: { timed_out: boolean } }>;
  };
  expect(report.tool_calls).toHaveLength(1);
  expect(report.tool_calls[0]!.status).toBe("error");
  expect(report.tool_calls[0]!.error?.code).toBe("timeout");
  expect(report.tool_calls[0]!.command_result?.timed_out).toBe(true);
  await waitUntilGone([await recordedPid(pidFile)], 1_000);
  expect(existsSync(marker)).toBe(false);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())(
  "quit ends a running background task and a resumed session no longer finds it",
  async () => {
    const fixture = createFixture("fx-task-resume-");
    const pidPath = join(fixture.root, "resume.pid");
    let taskId = "";
    const gateway = startFakeGateway([
      background(
        "task_resume_run",
        `printf '%s' "$$" > ${JSON.stringify(pidPath)}; printf 'TASK_RESUME_READY\\n'; sleep 37.25`,
      ),
      (body) => {
        taskId = startedTaskId(body, "task_resume_run");
        return fakeGatewayFinalText("TASK_RESUME_STARTED");
      },
      () => fakeGatewayVerbCall("task_resume_read", "TaskOutput", { task_id: taskId }),
      () => fakeGatewayVerbCall("task_resume_stop", "TaskStop", { task_id: taskId }),
      () => fakeGatewayVerbCall("task_resume_list", "TaskList", {}),
      fakeGatewayFinalText("TASK_RESUME_OK"),
    ]);
    gateways.push(gateway);

    const first = await launch(fixture, gateway);
    await first.sendText("Start the background task.");
    await first.waitForText("TASK_RESUME_STARTED", TIMEOUT);
    expect(taskId.length).toBeGreaterThan(0);
    const shellPid = await recordedPid(pidPath);
    expect(processAlive(shellPid)).toBe(true);
    const sleepers = processesRunning("sleep 37.25");
    await first.sendText("/quit");
    expect(await first.waitForSessionEnd(TIMEOUT)).toBe(true);
    await waitUntilGone([shellPid, ...sleepers], 1_000);

    const resumed = await launch(fixture, gateway, { cmd: `${FX_BIN} --resume last` });
    await resumed.sendText("Use the earlier background task.");
    await resumed.waitForText("TASK_RESUME_OK", TIMEOUT);

    for (const id of ["task_resume_read", "task_resume_stop"]) {
      expect(latestToolResult(gateway, id)).toContain('"code":"ExecutionNotFound"');
    }
    expect(latestToolResult(gateway, "task_resume_list")).toBe("No background tasks found.");
    expect(processAlive(shellPid)).toBe(false);
    const scrollback = await resumed.captureFullScrollback();
    expect(scrollback).toContain("Ran printf '%s' \"$$\" > ");
    expect(scrollback).toContain("2 failed");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  60_000,
);

test("fx ask exit ends its untimed background task within one second", async () => {
  const fixture = createFixture("fx-task-ask-exit-");
  const pidPath = join(fixture.root, "ask.pid");
  const gateway = startFakeGateway([
    background(
      "task_ask_run",
      `printf '%s' "$$" > ${JSON.stringify(pidPath)}; sleep 38.25`,
      { disable_timeout: true },
    ),
    async () => {
      await recordedPid(pidPath);
      return fakeGatewayFinalText("ASK_TASK_STARTED");
    },
  ]);
  gateways.push(gateway);

  const started = Date.now();
  const result = await runFx(["ask", "--json", "Start a long background task."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  const exitedAt = Date.now();
  expect(result.code).toBe(0);
  expect(JSON.parse(result.stdout).output).toBe("ASK_TASK_STARTED");
  expect(exitedAt - started).toBeLessThan(15_000);
  expect(toolResult(gateway.requests[1]!.body, "task_ask_run")).toContain('"state":"running"');

  const shellPid = await recordedPid(pidPath);
  await waitUntilGone(
    [shellPid, ...processesRunning("sleep 38.25")],
    Math.max(0, 1_000 - (Date.now() - exitedAt)),
  );
  expect(processAlive(shellPid)).toBe(false);
}, TIMEOUT);

test("Bash runs in the requested cwd and reports the exact exit", async () => {
  const fixture = createFixture("fx-bash-cwd-");
  const nested = join(fixture.workspace, "nested");
  mkdirSync(nested);
  const gateway = startFakeGateway([
    fakeGatewayVerbCall("bash_cwd_run", "Bash", {
      command: "printf 'CWD:%s\\n' \"$PWD\"; exit 7",
      cwd: nested,
    }),
    fakeGatewayFinalText("CWD_DONE"),
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Probe the working directory."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  const text = toolResult(gateway.requests[1]!.body, "bash_cwd_run");
  expect(text).toContain(`CWD:${nested}\\n`);
  expect(text).toContain('"state":"completed"');
  expect(text).toContain('"exit_code":7');
  const report = JSON.parse(result.stdout) as {
    tool_calls: Array<{
      status: string;
      error?: { code: string };
      command_result?: { cwd: string; exit_code: number };
    }>;
  };
  expect(report.tool_calls).toHaveLength(1);
  expect(report.tool_calls[0]!.status).toBe("error");
  expect(report.tool_calls[0]!.error?.code).toBe("nonzero_exit");
  expect(report.tool_calls[0]!.command_result?.cwd).toBe(nested);
  expect(report.tool_calls[0]!.command_result?.exit_code).toBe(7);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())(
  "another fx process can neither read nor stop a running owner's task",
  async () => {
    const fixture = createFixture("fx-task-owner-");
    const pidPath = join(fixture.root, "owner.pid");
    let ownerTask = "";
    const ownerGateway = startFakeGateway([
      background(
        "task_owner_run",
        `printf '%s' "$$" > ${JSON.stringify(pidPath)}; printf OWNER_OUTPUT; sleep 41.5`,
        { name: "owned-task" },
      ),
      (body) => {
        ownerTask = startedTaskId(body, "task_owner_run");
        return fakeGatewayFinalText("OWNER_TASK_STARTED");
      },
    ]);
    gateways.push(ownerGateway);
    const owner = await launch(fixture, ownerGateway);
    await owner.sendText("Start the owned task.");
    await owner.waitForText("OWNER_TASK_STARTED", TIMEOUT);
    expect(ownerTask).toBe("owned-task");
    const shellPid = await recordedPid(pidPath);

    const intruderGateway = startFakeGateway([
      () => fakeGatewayVerbCall("intruder_read", "TaskOutput", { task_id: ownerTask }),
      () => fakeGatewayVerbCall("intruder_stop", "TaskStop", { task_id: ownerTask }),
      () => fakeGatewayVerbCall("intruder_list", "TaskList", {}),
      fakeGatewayFinalText("INTRUDER_DONE"),
    ]);
    gateways.push(intruderGateway);
    const intruder = await runFx(["ask", "--json", "Touch the other task."], {
      cwd: fixture.workspace,
      env: askEnv(fixture, intruderGateway),
      timeoutMs: TIMEOUT,
    });
    expect(intruder.code).toBe(0);
    const intrusion = JSON.parse(intruder.stdout) as {
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(intrusion.tool_calls).toEqual([
      { name: "TaskOutput", status: "error" },
      { name: "TaskStop", status: "error" },
      { name: "TaskList", status: "success" },
    ]);
    for (const id of ["intruder_read", "intruder_stop"]) {
      const refusal = latestToolResult(intruderGateway, id);
      expect(refusal).toContain('"code":"ExecutionNotFound"');
      expect(refusal).not.toContain("OWNER_OUTPUT");
    }
    expect(latestToolResult(intruderGateway, "intruder_list")).toBe("No background tasks found.");

    await Bun.sleep(300);
    expect(processAlive(shellPid)).toBe(true);

    await owner.sendText("/quit");
    expect(await owner.waitForSessionEnd(TIMEOUT)).toBe(true);
    await waitUntilGone([shellPid], 1_000);
  },
  60_000,
);

test("TaskStop reaches a background job the task started", async () => {
  const fixture = createFixture("fx-task-signal-");
  const pidFile = join(fixture.root, "background.pid");
  let taskId = "";
  let jobAliveAfterStop = true;
  const gateway = startFakeGateway([
    background(
      "task_signal_run",
      `sleep 43.5 & printf '%s' "$!" > ${JSON.stringify(pidFile)}; printf 'BG_READY\\n'; wait`,
    ),
    async (body) => {
      taskId = startedTaskId(body, "task_signal_run");
      await recordedPid(pidFile);
      return fakeGatewayVerbCall("task_signal_stop", "TaskStop", { task_id: taskId });
    },
    async () => {
      const backgroundPid = await recordedPid(pidFile);
      const deadline = Date.now() + 1_000;
      while (processAlive(backgroundPid) && Date.now() < deadline) await Bun.sleep(10);
      jobAliveAfterStop = processAlive(backgroundPid);
      return fakeGatewayFinalText("SIGNAL_DONE");
    },
  ]);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Stop the background job."], {
    cwd: fixture.workspace,
    env: askEnv(fixture, gateway),
    timeoutMs: TIMEOUT,
  });
  expect(result.code).toBe(0);
  const stopResult = toolResult(gateway.requests[2]!.body, "task_signal_stop");
  expect(stopResult).toContain(`"session_id":"${taskId}"`);
  expect(stopResult).toContain('"state":"stopped"');
  expect(stopResult).toContain("BG_READY");
  expect(jobAliveAfterStop).toBe(false);
}, TIMEOUT);

test("the full task budget starts, refuses one more, and ends together at exit", async () => {
  const fixture = createFixture("fx-task-capacity-");
  const budget = 64;
  const pidsPath = join(fixture.root, "pids.txt");
  const responses: Parameters<typeof startFakeGateway>[0] = [];
  for (let index = 0; index <= budget; index += 1) {
    responses.push(background(
      `task_capacity_${index}`,
      `printf '%s\\n' "$$" >> ${JSON.stringify(pidsPath)}; sleep 45.75`,
      { disable_timeout: true },
    ));
  }
  responses.push(async () => {
    const deadline = Date.now() + TIMEOUT;
    while (Date.now() < deadline) {
      if (existsSync(pidsPath) && readFileSync(pidsPath, "utf8").trim().split("\n").length >= budget) break;
      await Bun.sleep(25);
    }
    return fakeGatewayFinalText("CAPACITY_DONE");
  });
  const gateway = startFakeGateway(responses);
  gateways.push(gateway);

  const result = await runFx(["ask", "--json", "Fill the task budget."], {
    cwd: fixture.workspace,
    env: { ...askEnv(fixture, gateway), FX_MAX_AGENT_STEPS: "100" },
    timeoutMs: 120_000,
  });
  const exitedAt = Date.now();
  expect(result.code).toBe(0);
  const statuses = (JSON.parse(result.stdout) as {
    tool_calls: Array<{ status: string }>;
  }).tool_calls.map(({ status }) => status);
  expect(statuses).toHaveLength(budget + 1);
  expect(statuses.slice(0, budget).every((status) => status === "success")).toBe(true);
  expect(statuses[budget]).toBe("error");
  expect(toolResult(gateway.requests[budget + 1]!.body, `task_capacity_${budget}`)).toContain(
    `The limit of ${budget} running background tasks is reached`,
  );

  const shellPids = readFileSync(pidsPath, "utf8").trim().split("\n").map(Number);
  expect(shellPids).toHaveLength(budget);
  expect(new Set(shellPids).size).toBe(budget);
  await waitUntilGone(
    [...shellPids, ...processesRunning("sleep 45.75")],
    Math.max(0, 1_500 - (Date.now() - exitedAt)),
  );
}, 150_000);
