import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startDynamicFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const CONTINUATION_MARK = "You are working under an active goal (goal mode).";

type Fixture = { root: string; home: string; workspace: string };

function createFixture(prefix: string): Fixture {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  return { root, home: realpathSync(home), workspace: realpathSync(workspace) };
}

function env(fixture: Fixture, gateway: { baseUrl: string; chatUrl: string }) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "goal-print-test-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
  };
}

function updateGoalCall(id: string, status: string) {
  return fakeGatewayToolCall(id, "run_code", { body: "return await gm.UpdateGoal({ status: \"" + status + "\" });" });
}

test("a /goal ask runs one continuation turn and exits 0 when the model completes the goal", async () => {
  const fixture = createFixture("fx-goal-complete-");
  let continuationTurns = 0;
  const gateway = startDynamicFakeGateway((body) => {
    if (body.includes("goal-complete-call")) return fakeGatewayFinalText("GOAL_DONE");
    if (body.includes(CONTINUATION_MARK)) {
      continuationTurns += 1;
      return updateGoalCall("goal-complete-call", "complete");
    }
    return fakeGatewayFinalText("FIRST_TURN_DONE");
  }, { classifierDecision: "clear" });
  try {
    const result = await runFx(["ask", "--json", "--auto", "/goal Ship the widget."], {
      cwd: fixture.workspace,
      env: env(fixture, gateway),
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(0);
    expect(continuationTurns + 1).toBe(2);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a /goal ask exits 3 with no continuation turn when the model marks the goal blocked", async () => {
  const fixture = createFixture("fx-goal-blocked-");
  let continuationTurns = 0;
  const gateway = startDynamicFakeGateway((body) => {
    if (body.includes("goal-blocked-call")) return fakeGatewayFinalText("GOAL_BLOCKED");
    if (body.includes(CONTINUATION_MARK)) continuationTurns += 1;
    return updateGoalCall("goal-blocked-call", "blocked");
  }, { classifierDecision: "clear" });
  try {
    const result = await runFx(["ask", "--json", "--auto", "/goal Ship the widget."], {
      cwd: fixture.workspace,
      env: env(fixture, gateway),
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(3);
    expect(continuationTurns).toBe(0);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a /goal ask interrupted by SIGINT while the goal is active pauses it and exits 6", async () => {
  const fixture = createFixture("fx-goal-paused-");
  let markArrived!: () => void;
  const arrived = new Promise<void>((resolve) => (markArrived = resolve));
  let release!: () => void;
  const released = new Promise<void>((resolve) => (release = resolve));
  const gateway = startDynamicFakeGateway(async () => {
    markArrived();
    await released;
    return fakeGatewayFinalText("INTERRUPTED");
  }, { classifierDecision: "clear" });
  const child = spawn(FX_BIN, ["ask", "--json", "--auto", "/goal Hold the line."], {
    cwd: fixture.workspace,
    env: { ...process.env, ...env(fixture, gateway) } as Record<string, string>,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const closed = new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
  try {
    await arrived;
    child.kill("SIGINT");
    release();
    expect(await closed).toBe(6);
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);

test("a /goal ask stops at the print turn cap, marks the goal blocked and exits 3", async () => {
  const fixture = createFixture("fx-goal-turn-cap-");
  let continuationTurns = 0;
  const gateway = startDynamicFakeGateway((body) => {
    if (body.includes(CONTINUATION_MARK)) continuationTurns += 1;
    return fakeGatewayFinalText("STILL_WORKING");
  }, { classifierDecision: "clear" });
  try {
    const result = await runFx(["ask", "--json", "--auto", "/goal Keep going."], {
      cwd: fixture.workspace,
      env: { ...env(fixture, gateway), KIMI_CODE_BACKGROUND_PRINT_MAX_TURNS: "1" },
      timeoutMs: TIMEOUT,
    });
    expect(result.code).toBe(3);
    expect(continuationTurns).toBe(0);
    expect(result.stderr.includes("task.print_max_turns")).toBe(true);
  } finally {
    gateway.stop();
    rmSync(fixture.root, { recursive: true, force: true });
  }
}, TIMEOUT * 3);
