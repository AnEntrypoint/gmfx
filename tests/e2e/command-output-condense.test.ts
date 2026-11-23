import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayVerbCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const BASH_FIELDS = "command, cwd, timeout, description, run_in_background, disable_timeout";

type BashResult = {
  state?: string;
  exit_code?: number;
  output_delta?: string;
  output_truncated?: boolean;
  original_bytes?: number;
  dropped_lines?: number;
  full_output_handle?: string;
};

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function runCodeVerbReply(text: string): string {
  const envelope = JSON.parse(text.split("\n\n<")[0]!);
  if (envelope.ok === false) return String(envelope.error).replace(/^Error: /, "").replace(/\n\s+at [\s\S]*$/, "");
  expect(envelope.ok).toBe(true);
  return typeof envelope.value === "string" ? envelope.value : JSON.stringify(envelope.value);
}

function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find((part) => part.type === "tool-result" && part.toolCallId === callId);
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return runCodeVerbReply(contentText(result.output));
}

async function bashResultText(label: string, prompt: string, input: object, inspect?: (profile: Profile) => void) {
  const profile = new Profile(label);
  let passed = false;
  try {
    const callId = `${label}-call`;
    const done = `Finished ${label}.`;
    profile.script(prompt, [() => fakeGatewayVerbCall(callId, "Bash", input), () => fakeGatewayFinalText(done)]);
    const shell = await profile.launch();
    await shell.session.sendText(prompt);
    await shell.session.waitForText(done, STEP);
    const body = profile.gateway.requests.map((request) => request.body).filter((text) => text.includes(callId)).at(-1) ?? "";
    const text = toolResultText(body, callId);
    inspect?.(profile);
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
    return text;
  } finally {
    await profile.close(!passed);
  }
}

function parseBashResult(text: string): BashResult {
  return JSON.parse(text.slice(text.indexOf("{"))) as BashResult;
}

test.skipIf(!tmuxAvailable())("a long noisy failing command reaches the model condensed with its failing line and footer", async () => {
  const command =
    "for i in $(seq 1 150); do printf '\\033[32mcompiling unit %s\\033[0m\\n\\n' \"$i\"; done; " +
    "echo \"src/main.zig:12:5: error: expected ';' after statement\"; " +
    "for i in $(seq 1 150); do echo \"linking object $i\"; done; " +
    "echo 'FINAL_LINE build stopped'; exit 3";
  const result = parseBashResult(await bashResultText("condense-noisy", "Run the noisy build.", { command }));

  expect(result.exit_code).toBe(3);
  expect(result.output_truncated).toBe(true);
  expect(result.dropped_lines).toBe(411);
  expect(result.original_bytes).toBeGreaterThan(6_000);
  expect(result.full_output_handle).toMatch(/^fx-command-replay-.+\.bin$/);
  const output = result.output_delta ?? "";
  expect(output.startsWith("compiling unit 1\ncompiling unit 2\n")).toBe(true);
  expect(output).not.toContain("\u001b");
  expect(output).toContain("compiling unit 20\n[...]\nsrc/main.zig:12:5: error: expected ';' after statement\n[...]\nlinking object 132\n");
  expect(output).not.toContain("compiling unit 21\n");
  expect(output).toContain("linking object 150\nFINAL_LINE build stopped\n[output condensed: kept 41 of 452 lines; dropped 411; ");
  expect(output.endsWith("original bytes; page the full output with read_tool_result on full_output_handle]")).toBe(true);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a small command output reaches the model unchanged", async () => {
  const result = parseBashResult(
    await bashResultText("condense-small", "Print two short lines.", { command: "printf 'alpha\\n\\nbeta\\n'" }),
  );

  expect(result.exit_code).toBe(0);
  expect(result.output_delta).toBe("alpha\n\nbeta\n");
  expect(result.output_truncated).toBeUndefined();
  expect(result.original_bytes).toBeUndefined();
  expect(result.dropped_lines).toBeUndefined();
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a Bash call with an unknown argument is refused by name with the accepted fields", async () => {
  let markerExists = true;
  const text = await bashResultText(
    "condense-unknown-argument",
    "Run the command in a terminal.",
    { command: "printf ran > unknown-argument-marker", tty: true },
    (profile) => {
      markerExists = existsSync(join(profile.workspace, "unknown-argument-marker"));
    },
  );

  expect(text).toContain(`Bash does not take argument "tty"; accepted fields: ${BASH_FIELDS}`);
  expect(markerExists).toBe(false);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a secret printed by a command is masked before it reaches the model", async () => {
  const text = await bashResultText("condense-secret", "Print the request header.", {
    command: "printf 'Authorization: Bearer %s%s\\nplain line\\n' abcdefghijklmnop qrstuvwxyz012345",
  });

  expect(text).not.toContain("abcdefghijklmnopqrstuvwxyz012345");
  expect(text).toContain("[redacted]");
  expect(text).toContain("plain line");
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a command does not inherit the gateway credential and git cannot prompt", async () => {
  const result = parseBashResult(
    await bashResultText("condense-child-env", "Print the child environment.", {
      command: "printf '%s|%s|%s' \"${AI_GATEWAY_API_KEY-unset}\" \"${GIT_TERMINAL_PROMPT-unset}\" \"${GIT_PAGER-unset}\"",
    }),
  );

  const [credential, gitPrompt, gitPager] = (result.output_delta ?? "").split("|");
  expect(credential).toBe("unset");
  expect(gitPrompt).not.toBe("unset");
  expect(gitPager).not.toBe("unset");
}, TIMEOUT);
