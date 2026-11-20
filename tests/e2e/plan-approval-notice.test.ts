import { expect, test } from "bun:test";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewaySse, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const PLAN = "Ship the parser fix in two steps.";

function findPlanFiles(root: string): string[] {
  if (!existsSync(root)) return [];
  const found: string[] = [];
  for (const name of readdirSync(root)) {
    const path = join(root, name);
    if (statSync(path).isDirectory()) found.push(...findPlanFiles(path));
    else if (name.endsWith(".md")) found.push(path);
  }
  return found;
}

test.skipIf(!tmuxAvailable())("an approved plan is saved and the approval reports where it went", async () => {
  const profile = new Profile("plan-approval-notice");
  let passed = false;
  try {
    profile.script("Plan the parser fix.", [
      () =>
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "exit-plan",
            toolName: "ExitPlanMode",
            input: { plan: PLAN, options: [{ label: "Ship it" }, { label: "Split work" }] },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
      () => fakeGatewayFinalText("Plan received."),
    ]);
    const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
    await shell.session.sendText("/plan Plan the parser fix.");
    await shell.session.waitForText("Ship it", STEP);
    await shell.session.sendKeys("Enter");
    await shell.session.waitForText("Plan received.", STEP);
    const second = profile.gateway.requests[1]!.body;
    expect(second).toContain("Exited plan mode.");
    expect(second).toContain("Plan saved to: ");
    const saved = findPlanFiles(profile.home).map((path) => readFileSync(path, "utf8"));
    expect(saved).toContain(PLAN);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
