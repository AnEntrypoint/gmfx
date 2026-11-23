import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayVerbCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const CANCELLED = "was not run because the approval request was cancelled.";

function createGoalCall() {
  return fakeGatewayVerbCall("create-goal", "CreateGoal", { objective: "ship the parser", completionCriterion: "tests pass" });
}

test.skipIf(!tmuxAvailable())("CreateGoal in Always Ask shows the goal start prompt and Switch to Never Ask changes the mode", async () => {
  const profile = new Profile("goal-start-prompt-switch");
  let passed = false;
  try {
    profile.script("Work towards shipping the parser.", [createGoalCall, () => fakeGatewayFinalText("Goal started.")]);
    const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
    await shell.session.sendText("Work towards shipping the parser.");
    await shell.session.waitForText("Start a goal with approvals on?", STEP);
    await shell.session.waitForText("1. Switch to Never Ask and start", STEP);
    const pane = await shell.session.capturePane();
    expect(pane).toContain("Start goal: ship the parser");
    expect(pane).toContain("2. Switch to Ask When Needed and start");
    expect(pane).toContain("3. Start in Always Ask");
    await shell.session.sendKeys("Enter");
    await shell.session.waitForText("Permission mode: Never Ask", STEP);
    await shell.session.waitForText("Goal started.", STEP);
    expect(profile.gateway.requests[1]!.body).not.toContain(CANCELLED);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("Esc on the goal start prompt tells the model the goal was not started", async () => {
  const profile = new Profile("goal-start-prompt-cancel");
  let passed = false;
  try {
    profile.script("Work towards shipping the parser.", [createGoalCall, () => fakeGatewayFinalText("Goal not started.")]);
    const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
    await shell.session.sendText("Work towards shipping the parser.");
    await shell.session.waitForText("Start a goal with approvals on?", STEP);
    await shell.session.sendKeys("Escape");
    await shell.session.waitForText("Goal not started.", STEP);
    expect(profile.gateway.requests[1]!.body).toContain(CANCELLED);
    const pane = await shell.session.capturePane();
    expect(pane).not.toContain("Permission mode: ");
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
