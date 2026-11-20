import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewaySse, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;

test.skipIf(!tmuxAvailable())("/tasks opens the task browser with a running background task", async () => {
  const profile = new Profile("tasks-browser");
  let passed = false;
  try {
    profile.script("Start a background sleep.", [
      () =>
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "background-sleep",
            toolName: "Bash",
            input: { command: "sleep 120", run_in_background: true, description: "Sleep in the background" },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
      () => fakeGatewayFinalText("Started the background sleep."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Start a background sleep.");
    await shell.session.waitForText("Started the background sleep.", STEP);
    await shell.session.sendText("/tasks");
    await shell.session.waitForText("Tasks 1", STEP);
    await shell.session.waitForText("running", STEP);
    await shell.session.waitForText("sleep 120", STEP);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
