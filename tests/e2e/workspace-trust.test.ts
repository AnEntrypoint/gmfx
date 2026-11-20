import { expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { Profile } from "./shell-sessions";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 180_000;
const STEP = 60_000;
const UNTRUSTED = { KIMI_CODE_TRUST_WORKSPACE: "0" };

function trustRecords(profile: Profile): string[] {
  const dir = join(profile.home, ".fx", "workspace-trust");
  return existsSync(dir) ? readdirSync(dir) : [];
}

function savedSessions(profile: Profile): string[] {
  const dir = join(profile.home, ".fx", "sessions");
  return existsSync(dir) ? readdirSync(dir) : [];
}

async function launchUntrusted(profile: Profile, label: string): Promise<TmuxSession> {
  return TmuxSession.create({
    cwd: profile.workspace,
    env: { ...profile.env(join(profile.root, `${label}.fxtape`)), ...UNTRUSTED },
    stderrPath: join(profile.root, `${label}.stderr`),
    width: 120,
    height: 48,
  });
}

test.skipIf(!tmuxAvailable())("an untrusted folder with no project config asks for trust before the session starts", async () => {
  const profile = new Profile("workspace-trust-prompt");
  let passed = false;
  let session: TmuxSession | undefined;
  try {
    session = await launchUntrusted(profile, "prompt");
    await session.waitForText("Trust this folder?", STEP);
    const pane = await session.capturePane();
    expect(pane).toContain(profile.workspace);
    expect(pane).toContain("No project integrations or instructions to activate.");
    expect(pane).toContain("Trust is remembered for this folder, including future project config changes.");
    expect(pane).toContain("Tool approvals follow your permission settings.");
    expect(pane).toContain("❯ Trust and continue");
    expect(pane).toContain("Exit");
    expect(trustRecords(profile)).toEqual([]);
    passed = true;
  } finally {
    await session?.kill().catch(() => {});
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("Trust and continue records the folder and the next launch does not ask", async () => {
  const profile = new Profile("workspace-trust-accept");
  let passed = false;
  let first: TmuxSession | undefined;
  let second: TmuxSession | undefined;
  try {
    first = await launchUntrusted(profile, "accept-first");
    await first.waitForText("Trust this folder?", STEP);
    await first.sendKeys("Enter");
    await first.waitForStableComposer(STEP);
    expect(trustRecords(profile).length).toBe(1);
    await first.kill();
    first = undefined;

    second = await launchUntrusted(profile, "accept-second");
    await second.waitForStableComposer(STEP);
    expect(await second.capturePane()).not.toContain("Trust this folder?");
    expect(trustRecords(profile).length).toBe(1);
    passed = true;
  } finally {
    await first?.kill().catch(() => {});
    await second?.kill().catch(() => {});
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("Exit leaves fx with a zero status before any session is created", async () => {
  const profile = new Profile("workspace-trust-exit");
  let passed = false;
  let session: TmuxSession | undefined;
  try {
    session = await launchUntrusted(profile, "exit");
    await session.waitForText("Trust this folder?", STEP);
    await session.sendKeys("Down");
    await session.waitForText("❯ Exit", STEP);
    await session.sendKeys("Enter");
    await session.waitForSessionEnd(STEP);
    expect(session.recordedExitStatus()).toBe(0);
    expect(trustRecords(profile)).toEqual([]);
    expect(savedSessions(profile)).toEqual([]);
    passed = true;
  } finally {
    await session?.kill().catch(() => {});
    await profile.close(!passed);
  }
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a project MCP config is disclosed in the trust prompt", async () => {
  const profile = new Profile("workspace-trust-disclosure");
  let passed = false;
  let session: TmuxSession | undefined;
  try {
    await Bun.write(
      join(profile.workspace, ".mcp.json"),
      JSON.stringify({ mcpServers: { docs: { command: "docs-server" } } }),
    );
    await Bun.write(join(profile.workspace, "AGENTS.md"), "Follow the house rules.\n");
    session = await launchUntrusted(profile, "disclosure");
    await session.waitForText("Trust this folder?", STEP);
    const pane = await session.capturePane();
    expect(pane).toContain("Start 1 MCP server automatically");
    expect(pane).toContain("Config: .mcp.json");
    expect(pane).toContain("Load project instructions");
    expect(pane).toContain("Check: AGENTS.md");
    expect(pane).not.toContain("No project integrations or instructions to activate.");
    passed = true;
  } finally {
    await session?.kill().catch(() => {});
    await profile.close(!passed);
  }
}, TIMEOUT);
