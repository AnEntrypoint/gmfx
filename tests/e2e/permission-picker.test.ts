import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const STEP = 30_000;
const PICKER_TITLE = "Select permission mode";
const PLAN_BADGE = "· plan ·";

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

async function waitForPaneWithout(
  capture: () => Promise<string>,
  absent: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let pane = await capture();
  while (pane.includes(absent)) {
    if (Date.now() > deadline) throw new Error(`pane still shows ${JSON.stringify(absent)}:\n${pane}`);
    await Bun.sleep(100);
    pane = await capture();
  }
  return pane;
}

scenario("/yolo opens the permission picker on Ask When Needed and Enter switches to it", async (profile) => {
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
  await shell.session.sendText("/yolo");
  await shell.session.waitForText(PICKER_TITLE, STEP);
  const picker = await shell.session.capturePane();
  expect(picker).toContain("Always Ask");
  expect(picker).toContain("Ask When Needed");
  expect(picker).toContain("Never Ask");
  expect(picker.indexOf("Always Ask")).toBeLessThan(picker.indexOf("Ask When Needed"));
  expect(picker.indexOf("Ask When Needed")).toBeLessThan(picker.indexOf("Never Ask"));
  await shell.session.sendKeys("Enter");
  await shell.session.waitForText("Permission mode: Ask When Needed", STEP);
  await waitForPaneWithout(() => shell.session.capturePane(), PICKER_TITLE, STEP);

  await shell.session.sendText("/yolo");
  await shell.session.waitForText(PICKER_TITLE, STEP);
  await shell.session.sendKeys("Enter");
  await shell.session.waitForText("Permission mode unchanged: Ask When Needed.", STEP);
  expect(await shell.quit()).toBeNull();
});

scenario("/auto opens the permission picker on Never Ask and Escape leaves the mode alone", async (profile) => {
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
  await shell.session.sendText("/auto");
  await shell.session.waitForText(PICKER_TITLE, STEP);
  await shell.session.sendKeys("Escape");
  const closed = await waitForPaneWithout(() => shell.session.capturePane(), PICKER_TITLE, STEP);
  expect(closed).not.toContain("Permission mode: Never Ask");

  await shell.session.sendText("/auto");
  await shell.session.waitForText(PICKER_TITLE, STEP);
  await shell.session.sendKeys("Enter");
  await shell.session.waitForText("Permission mode: Never Ask", STEP);
  expect(await shell.quit()).toBeNull();
});

scenario("the footer shows a plan badge while plan mode is on and drops it when plan mode goes off", async (profile) => {
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
  expect(await shell.session.capturePane()).not.toContain(PLAN_BADGE);
  await shell.session.sendKeys("BTab");
  await shell.session.waitForText(PLAN_BADGE, STEP);
  await shell.session.sendKeys("BTab");
  await waitForPaneWithout(() => shell.session.capturePane(), PLAN_BADGE, STEP);
  expect(await shell.quit()).toBeNull();
});
