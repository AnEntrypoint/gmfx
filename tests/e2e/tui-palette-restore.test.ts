import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const SETTLE_MS = 500;

test.skipIf(!tmuxAvailable())("closing the slash palette returns the composer to the grid it had before the palette opened", async () => {
  const profile = new Profile("palette-restore");
  let passed = false;
  try {
    const shell = await profile.launch({ env: {} });
    const settle = () => new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
    const rows = async () => (await shell.session.capturePaneGrid()).map((line) => line.trimEnd());

    await shell.session.sendKeys("Escape");
    await settle();
    await shell.session.sendText("hello");
    await settle();
    const before = await rows();

    await shell.session.sendText("/");
    await settle();
    expect((await rows()).some((line) => line.includes("Commands"))).toBe(true);

    await shell.session.sendKeys("Escape");
    await settle();
    expect(await rows()).toEqual(before);

    await shell.session.sendKeys("BSpace");
    await settle();
    expect((await rows()).some((line) => line.includes("hello"))).toBe(true);

    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
