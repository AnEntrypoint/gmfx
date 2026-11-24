import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewaySse, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;

test.skipIf(!tmuxAvailable())("a bash tool call opens the approval panel with its options and its command row", async () => {
  const profile = new Profile("approval-panel");
  let passed = false;
  try {
    profile.script("Run echo approval.", [
      () =>
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "echo-approval",
            toolName: "run_code",
            input: { body: 'return gm.Bash({"command":"echo approval"});' },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
      () => fakeGatewayFinalText("Done."),
    ]);
    const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
    await shell.session.sendText("Run echo approval.");
    await shell.session.waitForText("1. Allow once", STEP);
    const lines = (await shell.session.capturePane()).split("\n");
    expect(lines.some((line) => line.includes("1. Allow once"))).toBe(true);
    expect(lines.some((line) => line.includes("3. Deny"))).toBe(true);
    expect(lines.some((line) => line.includes("echo approval") && !line.startsWith("┃"))).toBe(true);
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
