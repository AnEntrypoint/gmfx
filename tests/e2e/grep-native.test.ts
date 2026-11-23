import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayVerbCall, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const REGEX_FALLBACK = "no literal match for the pattern; matched as a regular expression";

async function toolResultBody(label: string, prompt: string, toolName: string, input: object, files: Record<string, string> = {}) {
  const profile = new Profile(label);
  let passed = false;
  try {
    for (const [name, content] of Object.entries(files)) writeFileSync(join(profile.workspace, name), content);
    const done = `Finished ${label}.`;
    profile.script(prompt, [() => fakeGatewayVerbCall(`${label}-call`, toolName, input), () => fakeGatewayFinalText(done)]);
    const shell = await profile.launch();
    await shell.session.sendText(prompt);
    await shell.session.waitForText(done, STEP);
    const body = profile.gateway.requests.map((request) => request.body).filter((text) => text.includes(`${label}-call`)).at(-1) ?? "";
    await shell.quit();
    expect(shell.stderrText()).toBe("");
    passed = true;
    return body;
  } finally {
    await profile.close(!passed);
  }
}

test.skipIf(!tmuxAvailable())("grep_files finds a pattern with regex characters as literal text", async () => {
  const body = await toolResultBody(
    "grep-literal",
    "Find the net price line.",
    "grep_files",
    { pattern: "$5.00 (net)", output_mode: "content" },
    { "prices.txt": "price is $5.00 (net)\nprice is $5x00 [net]\n" },
  );
  expect(body).toContain("[grep] 1 matches for $5.00 (net)");
  expect(body).toContain("prices.txt:1: price is $5.00 (net)");
  expect(body).not.toContain("prices.txt:2:");
  expect(body).not.toContain(REGEX_FALLBACK);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("grep_files retries a literal miss as a regular expression and says so", async () => {
  const body = await toolResultBody(
    "grep-regex-fallback",
    "Find the numbered ids.",
    "grep_files",
    { pattern: "id [0-9]+$", output_mode: "content" },
    { "ids.txt": "id 42\nid none\n" },
  );
  expect(body).toContain("ids.txt:1: id 42");
  expect(body).not.toContain("ids.txt:2:");
  expect(body).toContain(REGEX_FALLBACK);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("grep_files refuses an unknown argument by name", async () => {
  const body = await toolResultBody(
    "grep-unknown-argument",
    "Search with a wrong argument.",
    "grep_files",
    { pattern: "needle", max_count: 3 },
    { "notes.txt": "needle\n" },
  );
  expect(body).toMatch(/grep_files does not take argument \\*"max_count\\*"; accepted fields: pattern, path, glob, include, type, output_mode, literal, word, regex/);
  expect(body).not.toContain("[grep] 1 files with matches");
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("read_tool_result refuses an unknown argument by name", async () => {
  const body = await toolResultBody(
    "read-tool-result-unknown-argument",
    "Page a result with a wrong argument.",
    "read_tool_result",
    { handle: "T1", limit: 5 },
  );
  expect(body).toMatch(/read_tool_result does not take argument \\*"limit\\*"; accepted fields: handle, query, start_byte, byte_count, search, request/);
}, TIMEOUT);
