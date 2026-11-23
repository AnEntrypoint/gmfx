import { expect, test } from "bun:test";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayVerbCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 120_000;
const STEP = 60_000;
const REMINDER = "still open and reachable";

function escaped(text: string): string {
  return JSON.stringify(text).slice(1, -1);
}

function holds(body: string, text: string): boolean {
  return body.includes(text) || body.includes(escaped(text));
}

test.skipIf(!tmuxAvailable())("a turn that ends with open todo work is continued once and names the open items", async () => {
  const profile = new Profile("open-work");
  let passed = false;
  try {
    profile.script("Plan two steps and stop early.", [
      () =>
        fakeGatewayVerbCall("plan-two", "TodoList", {
          todos: [
            { title: "write the parser", status: "in_progress" },
            { title: "add the parser test", status: "pending" },
          ],
        }),
      () => fakeGatewayFinalText("Planned two steps."),
      () => fakeGatewayFinalText("The test waits on the user's fixture."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Plan two steps and stop early.");
    await shell.session.waitForText("The test waits on the user's fixture.", STEP);
    await shell.session.waitForStableComposer(STEP);
    const requests = profile.gateway.requests;
    expect(requests.length).toBe(3);
    expect(holds(requests[1]!.body, REMINDER)).toBe(false);
    const continued = requests[2]!.body;
    expect(holds(continued, `2 todo items are ${REMINDER}`)).toBe(true);
    expect(holds(continued, "write the parser")).toBe(true);
    expect(holds(continued, "add the parser test")).toBe(true);
    await Bun.sleep(1_500);
    expect(profile.gateway.requests.length).toBe(3);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a turn whose todo items are all done ends without a reminder", async () => {
  const profile = new Profile("open-work-done");
  let passed = false;
  try {
    profile.script("Plan one step and finish it.", [
      () => fakeGatewayVerbCall("plan-one", "TodoList", { todos: [{ title: "write the note", status: "done" }] }),
      () => fakeGatewayFinalText("Wrote the note."),
    ]);
    const shell = await profile.launch();
    await shell.session.sendText("Plan one step and finish it.");
    await shell.session.waitForText("Wrote the note.", STEP);
    await shell.session.waitForStableComposer(STEP);
    await Bun.sleep(1_500);
    const requests = profile.gateway.requests;
    expect(requests.length).toBe(2);
    expect(holds(requests[1]!.body, REMINDER)).toBe(false);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
  } finally {
    await profile.close(!passed);
  }
}, TIMEOUT);
