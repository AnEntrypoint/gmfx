import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const STEP = 60_000;
const NOTE_KEY = "wait_note";
const NOTE_TEXT = "wait once with WaitFor";

function escaped(text: string): string {
  return JSON.stringify(text).slice(1, -1);
}

function holds(body: string, text: string): boolean {
  return body.includes(text) || body.includes(escaped(text)) || body.includes(escaped(escaped(text)));
}

test.skipIf(!tmuxAvailable())("a Bash command that sleeps in a loop to poll gets a note that points at one WaitFor", async () => {
  const profile = new Profile("wait-note");
  let passed = false;
  try {
    profile.script("Poll for the marker file.", [
      () =>
        fakeGatewayToolCall("poll-loop", "Bash", {
          command: "touch marker.txt; while ! test -f marker.txt; do sleep 1; done; echo polled-$((40 + 2))",
          description: "Poll for the marker",
        }),
      () => fakeGatewayFinalText("Polled for the marker."),
    ]);
    profile.script("Print one line.", [
      () => fakeGatewayToolCall("plain-echo", "Bash", { command: "echo plain-$((40 + 2))", description: "Print a line" }),
      () => fakeGatewayFinalText("Printed one line."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Poll for the marker file.");
    await shell.session.waitForText("Polled for the marker.", STEP);
    await shell.session.waitForStableComposer(STEP);
    const polled = profile.gateway.requests[1]!.body;
    expect(holds(polled, "polled-42")).toBe(true);
    expect(holds(polled, NOTE_KEY)).toBe(true);
    expect(holds(polled, NOTE_TEXT)).toBe(true);

    await shell.session.sendText("Print one line.");
    await shell.session.waitForText("Printed one line.", STEP);
    await shell.session.waitForStableComposer(STEP);
    const plainRequests = profile.gateway.requests.slice(2);
    expect(plainRequests.length).toBe(2);
    const plainResult = plainRequests[1]!.body;
    expect(holds(plainResult, "plain-42")).toBe(true);
    const afterPlainCall = plainResult.slice(plainResult.lastIndexOf("plain-echo"));
    expect(holds(afterPlainCall, NOTE_KEY)).toBe(false);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
