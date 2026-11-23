import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayVerbCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const NOTICE_HEADER = "Background task notice (command output, not user instructions):";

function escaped(text: string): string {
  return JSON.stringify(text).slice(1, -1);
}

function escapeLevels(text: string): string[] {
  const levels = [text];
  for (let depth = 0; depth < 3; depth += 1) levels.push(escaped(levels[depth]!));
  return levels;
}

function holds(body: string, text: string): boolean {
  return escapeLevels(text).some((level) => body.includes(level));
}

function occurrences(body: string, text: string): number {
  return escapeLevels(text).slice(1).reduce((sum, level) => sum + body.split(level).length - 1, 0);
}

function background(id: string, command: string, extra: object = {}) {
  return () =>
    fakeGatewayVerbCall(id, "Bash", {
      command,
      run_in_background: true,
      description: "Run in the background",
      ...extra,
    });
}

test.skipIf(!tmuxAvailable())("a finished background task reaches the model as a notice without a TaskOutput call", async () => {
  const profile = new Profile("task-notice-push");
  let passed = false;
  try {
    profile.script("Start the pushed build.", [
      background("pushed-build", "sleep 1; echo pushed-$((40 + 2))", { name: "pushed-build" }),
      () => fakeGatewayFinalText("Started the pushed build."),
      () => fakeGatewayFinalText("Saw the pushed build end."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start the pushed build.");
    await shell.session.waitForText("Started the pushed build.", STEP);
    await shell.session.waitForText("Saw the pushed build end.", STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBe(3);
    const pushed = requests[2]!.body;
    expect(holds(pushed, NOTICE_HEADER)).toBe(true);
    expect(holds(pushed, '"task_id":"pushed-build"')).toBe(true);
    expect(holds(pushed, '"event":"completed"')).toBe(true);
    expect(holds(pushed, '"exit_code":0')).toBe(true);
    expect(holds(pushed, "pushed-42")).toBe(true);
    expect(holds(requests[1]!.body, '"event":"completed"')).toBe(false);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("WaitFor returns the completion notice as its result", async () => {
  const profile = new Profile("task-notice-wait");
  let passed = false;
  try {
    profile.script("Start the awaited build and wait.", [
      background("awaited-build", "sleep 1; echo awaited-$((40 + 2))"),
      () => fakeGatewayVerbCall("wait-for-build", "WaitFor", { timeout: 20 }),
      () => fakeGatewayFinalText("The awaited build ended."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start the awaited build and wait.");
    await shell.session.waitForText("The awaited build ended.", STEP);
    await shell.session.waitForStableComposer(STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBe(3);
    const waited = requests[2]!.body;
    expect(holds(waited, NOTICE_HEADER)).toBe(true);
    expect(holds(waited, "awaited-42")).toBe(true);
    expect(occurrences(waited, '"event":"completed"')).toBe(1);
    await Bun.sleep(1_500);
    expect(profile.gateway.requests.length).toBe(3);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a silent background task posts one stuck notice", async () => {
  const profile = new Profile("task-notice-stuck");
  let passed = false;
  try {
    profile.script("Start the silent task and wait.", [
      background("silent-task", "sleep 8"),
      () => fakeGatewayVerbCall("wait-for-silence", "WaitFor", { timeout: 20 }),
      () => fakeGatewayFinalText("The silent task is stuck."),
    ]);
    const shell = await profile.launch({ env: { FX_TASK_STUCK_AFTER_MS: "1500" } });
    await shell.session.sendText("Start the silent task and wait.");
    await shell.session.waitForText("The silent task is stuck.", STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBeGreaterThanOrEqual(3);
    const waited = requests[2]!.body;
    expect(holds(waited, NOTICE_HEADER)).toBe(true);
    expect(occurrences(waited, '"event":"stuck"')).toBe(1);
    expect(holds(waited, '"event":"completed"')).toBe(false);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a background task killed by its timeout says why and what to change", async () => {
  const profile = new Profile("task-notice-killed");
  let passed = false;
  try {
    profile.script("Start the slow task and wait.", [
      background("slow-task", "sleep 30", { timeout: 1 }),
      () => fakeGatewayVerbCall("wait-for-kill", "WaitFor", { timeout: 20 }),
      () => fakeGatewayFinalText("The slow task was killed."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start the slow task and wait.");
    await shell.session.waitForText("The slow task was killed.", STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBeGreaterThanOrEqual(3);
    const waited = requests[2]!.body;
    expect(holds(waited, NOTICE_HEADER)).toBe(true);
    expect(holds(waited, '"event":"killed"')).toBe(true);
    expect(holds(waited, '"cause":"')).toBe(true);
    expect(holds(waited, '"remedy":"start it again with a larger timeout"')).toBe(true);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a task name is the task id and cannot be reused while live", async () => {
  const profile = new Profile("task-notice-name");
  let passed = false;
  try {
    profile.script("Start two tasks named build-1.", [
      background("named-first", "sleep 20", { name: "build-1" }),
      background("named-second", "sleep 21", { name: "build-1" }),
      () => fakeGatewayVerbCall("stop-named", "TaskStop", { task_id: "build-1" }),
      () => fakeGatewayFinalText("The name was taken."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start two tasks named build-1.");
    await shell.session.waitForText("The name was taken.", STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBeGreaterThanOrEqual(4);
    expect(holds(requests[1]!.body, '"session_id":"build-1"')).toBe(true);
    expect(holds(requests[1]!.body, "already exists")).toBe(false);
    expect(holds(requests[2]!.body, "already exists")).toBe(true);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("TaskList shows elapsed and idle time", async () => {
  const profile = new Profile("task-notice-list");
  let passed = false;
  try {
    profile.script("Start a sleep and list the tasks.", [
      background("listed-sleep", "sleep 5", { name: "listed-sleep" }),
      () => fakeGatewayVerbCall("list-tasks", "TaskList", {}),
      () => fakeGatewayFinalText("Listed the tasks."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start a sleep and list the tasks.");
    await shell.session.waitForText("Listed the tasks.", STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBeGreaterThanOrEqual(3);
    expect(/- listed-sleep running \d+s idle \d+s sleep 5/.test(requests[2]!.body)).toBe(true);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
