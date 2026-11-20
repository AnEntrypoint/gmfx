import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const STEP = 30_000;
const DESCRIPTION = "Summarise the repo for planning.";

function scenario(name: string, body: (profile: Profile) => Promise<void>) {
  test.skipIf(!tmuxAvailable())(name, async () => {
    const profile = new Profile(name.replace(/[^A-Za-z0-9]+/g, "-").slice(0, 32));
    let passed = false;
    try {
      await body(profile);
      passed = true;
    } finally {
      await profile.close(!passed);
    }
  }, TIMEOUT);
}

scenario("/plan with a description turns plan mode on and sends the description as the prompt", async (profile) => {
  profile.script(DESCRIPTION, [() => fakeGatewayFinalText("PLAN_DONE")]);
  const shell = await profile.launch({ env: {} });
  await shell.session.sendText(`/plan ${DESCRIPTION}`);
  await shell.session.waitForText("Plan mode: ON", STEP);
  await shell.session.waitForText("Plan will be created here: ", STEP);
  await shell.session.waitForText("PLAN_DONE", STEP);
  expect(await shell.quit()).toBe(shell.current());
  expect(shell.stderrText()).toBe("");
});

scenario("/plan on, off and clear report the plan mode state and keep plan mode on after a clear", async (profile) => {
  const shell = await profile.launch({ env: {} });
  await shell.session.sendText("/plan on");
  await shell.session.waitForText("Plan mode: ON", STEP);
  await shell.session.waitForText("/.fx/plans/plan.md", STEP);
  await shell.session.sendText("/plan on");
  await shell.session.waitForText("Plan mode is already on", STEP);
  await shell.session.sendText("/plan clear");
  await shell.session.waitForText("Plan cleared", STEP);
  await shell.session.sendText("/plan on");
  await shell.session.waitForText("Plan mode is already on", STEP);
  await shell.session.sendText("/plan off");
  await shell.session.waitForText("Plan mode: OFF", STEP);
  await shell.session.sendText("/plan off");
  await shell.session.waitForText("Plan mode is already off", STEP);
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");
});

scenario("Shift-Tab toggles plan mode with the same notices as /plan", async (profile) => {
  const shell = await profile.launch({ env: {} });
  await shell.session.sendKeys("BTab");
  await shell.session.waitForText("Plan mode: ON", STEP);
  await shell.session.waitForText("Plan will be created here: ", STEP);
  await shell.session.sendKeys("BTab");
  await shell.session.waitForText("Plan mode: OFF", STEP);
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");
});
