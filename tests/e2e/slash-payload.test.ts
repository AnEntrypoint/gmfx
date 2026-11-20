import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const STEP = 30_000;

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

scenario("/experiments with a flag and a value sets that flag and says so", async (profile) => {
  const shell = await profile.launch({ env: {} });
  await shell.session.sendText("/experiments wait_for off");
  await shell.session.waitForText("wait_for set to off", STEP);
  await shell.quit();
  expect(shell.stderrText()).toBe("");
});

scenario("/tasks with an id that is not running says it is not a task", async (profile) => {
  const shell = await profile.launch({ env: {} });
  await shell.session.sendText("/tasks nosuch-task");
  await shell.session.waitForText("No background task named nosuch-task.", STEP);
  await shell.quit();
  expect(shell.stderrText()).toBe("");
});

scenario("/theme with no name opens the theme picker", async (profile) => {
  const shell = await profile.launch({ env: {} });
  await shell.session.sendText("/theme");
  await shell.session.waitForText("dark", STEP);
  await shell.quit();
  expect(shell.stderrText()).toBe("");
});
