






import { expect, test } from "bun:test";
import { join } from "node:path";
import {
  closedAsBefore,
  closePanel,
  infoPanel,
  keystrokeFrames,
  lastTranscriptRow,
  PERMISSIONS_PANEL_LABELS,
  replayGrids,
  submittedFrames,
  waitForPanel,
  type PanelReport,
} from "./info-panel";
import { Profile } from "./shell-sessions";
import { fakeGatewayFinalText, fakeGatewayToolCall, tmuxAvailable } from "./tmux-helpers";
import { assertSingleFooter } from "./tui-render-assertions";

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

function expectPanel(report: PanelReport, mode: string) {
  const display: Record<string, string> = { manual: "Always Ask", auto: "Never Ask" };
  expect(report.fields.Mode).toBe(display[mode] ?? mode);
  expect(report.labels.slice(-3)).toEqual(["Change mode", "Remember", "Revoke"]);
  expect(report.fields["Change mode"]).toBe("/permissions manual, auto, yolo, or reset");
  expect(report.fields.Remember).toBe("/permissions remember allow|deny <tool-name> <arguments-json>");
  expect(report.fields.Revoke).toBe("/permissions revoke <rule-id>");
  expect(infoPanel(report.closed, "Permissions")).toBeNull();
  if (!closedAsBefore(report)) {
    throw new Error(`the /permissions panel at tape frame ${report.frame} changed the shell:\n--- before\n${report.before.join("\n")}\n--- closed\n${report.closed.join("\n")}`);
  }
  const failures: string[] = [];
  assertSingleFooter(report.closed, failures, `the grid after the /permissions panel at tape frame ${report.frame} closed`);
  expect(failures).toEqual([]);
}

scenario("the panel shows the mode, each configured rule, and how to change them, and a mode change still confirms", async (profile) => {
  profile.settings({ permission: { edit: "deny", bash: { "git status *": "allow" } } });
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "auto" } });
  await shell.permissions();
  await shell.command("/permissions manual");
  expect(await shell.session.captureFullScrollback()).toContain("* permissions: mode set to manual");
  await shell.permissions();
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");

  const [first, second] = shell.reports("Permissions");
  expectPanel(first!, "auto");
  expect(first!.labels).toEqual([...PERMISSIONS_PANEL_LABELS]);
  expect(first!.fields["Configured rules"]).toBe("2");
  expect(first!.items["Configured rules"]).toEqual(["deny edit → *", "allow bash → git status *"]);
  expect(first!.fields["Session grants"]).toBe("none");
  expect(first!.items["Session grants"]).toBeUndefined();
  expect(first!.fields["Saved rules"]).toBe("none");
  expectPanel(second!, "manual");
  expect(second!.items["Configured rules"]).toEqual(first!.items["Configured rules"]);
});

scenario("a remembered rule shows with the id /permissions revoke takes, and is gone once revoked", async (profile) => {
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "auto" } });
  const id = shell.current()!;
  await shell.prompt("Save this session first.", "SESSION_SAVED");
  const args = JSON.stringify({ command: "touch remembered-marker" });
  await shell.session.sendText(`/permissions remember deny Bash ${args}`);
  await shell.session.waitForText("Remember deny for this saved session", STEP);
  await shell.session.sendKeys("1");
  await shell.session.waitForText("saved-session permission rule updated", STEP);
  await shell.session.waitForStableComposer(STEP);

  const live = await shell.permissions();
  const ruleId = /^(\d+) deny /.exec(live.items["Saved rules"]?.[0] ?? "")?.[1];
  expect(ruleId).toBeDefined();
  await shell.session.sendText(`/permissions revoke ${ruleId}`);
  await shell.session.waitForText("Revoke this saved-session permission rule?", STEP);
  await shell.session.sendKeys("1");
  await shell.session.waitForStableComposer(STEP);
  await shell.permissions();
  expect(await shell.quit()).toBe(id);
  expect(shell.stderrText()).toBe("");

  const [remembered, revoked] = shell.reports("Permissions");
  expectPanel(remembered!, "auto");
  expect(remembered!.fields["Saved rules"]).toBe("1");
  expect(remembered!.items["Saved rules"]).toHaveLength(1);
  expect(remembered!.items["Saved rules"]![0]).toMatch(new RegExp(`^${ruleId} deny \\S+ touch \\S*remembered-marker$`));
  expectPanel(revoked!, "auto");
  expect(revoked!.fields["Saved rules"]).toBe("none");
  expect(revoked!.items["Saved rules"]).toBeUndefined();
});

scenario("a session grant an approval adds while the panel is open shows when the panel comes back", async (profile) => {
  let release!: () => void;
  const released = new Promise<void>((resolve) => (release = resolve));
  profile.script("Write the note.", [
    async () => {
      await released;
      return fakeGatewayToolCall("write_note", "write_file", { path: "note.txt", content: "hi\n" });
    },
    () => fakeGatewayFinalText("WROTE_NOTE"),
  ]);
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
  const before = profile.gateway.requests.length;
  await shell.session.sendText("Write the note.");
  await shell.session.waitForPane(() => profile.gateway.requests.length > before, STEP);
  await shell.session.sendText("/permissions");
  await waitForPanel(shell.session, "Permissions", STEP, (panel) => panel.fields["Session grants"] === "none");


  release();
  await shell.session.waitForText("Apply + allow workspace file access for this session", STEP);
  await shell.session.sendKeys("2");
  await shell.session.waitForText("WROTE_NOTE", STEP);
  await waitForPanel(shell.session, "Permissions", STEP, (panel) => panel.fields["Session grants"] !== "none");
  await closePanel(shell.session, "Permissions", STEP);
  await shell.session.sendKeys("C-u");
  expect(await shell.quit()).toBe(shell.current());
  expect(shell.stderrText()).toBe("");


  const grids = replayGrids(profile.bin, shell.tape, join(profile.root, "approval.frames"));
  const [{ submitted }] = submittedFrames(shell.tape, "/permissions");
  const answer = keystrokeFrames(shell.tape).find((index) => index > submitted)!;
  const close = keystrokeFrames(shell.tape).find((index) => index > answer)!;
  const painted = [...grids.keys()].filter((index) => index > submitted && index < close).sort((a, b) => a - b);
  const approvalShown = (grid: string[]) => grid.some((row) => row.includes("Apply + allow workspace file access for this session"));
  const states = painted.map((index) => {
    const grid = grids.get(index)!;
    const panel = infoPanel(grid, "Permissions");
    const wrote = grid.some((row) => row.includes("Wrote note.txt"));
    return { index, approval: approvalShown(grid), wrote, grants: panel?.fields["Session grants"], items: panel?.items["Session grants"] };
  });
  const lastApproval = states.findLastIndex((state) => state.approval);
  expect(lastApproval).toBeGreaterThan(0);

  expect(states.slice(0, states.findIndex((state) => state.approval)).filter((state) => state.grants !== undefined).map((state) => state.grants)).toContain("none");

  for (const state of states.filter((state) => state.approval)) expect(state.grants).toBeUndefined();




  const after = states.slice(lastApproval + 1).filter((state) => state.grants !== undefined);
  const shown = after.findIndex((state) => state.grants !== "none");
  expect(shown).toBeGreaterThanOrEqual(0);
  for (const state of after.slice(shown)) {
    expect(state.grants).toBe("4");
    expect(state.items).toEqual(["edit → **", "read → **", "glob → **", "grep → **"]);
  }

  expect(states.slice(lastApproval + 1).some((state) => state.wrote)).toBe(true);
});

scenario("a long rule wraps under its bullet in a narrow terminal and reads back whole", async (profile) => {
  const pattern = "npm run build -- --filter=packages/terminal/renderer/wrapping";
  profile.settings({ permission: { bash: { [pattern]: "allow" } } });
  const shell = await profile.launch({ width: 50, env: { FX_PERMISSION_MODE: "auto" } });
  await shell.permissions();
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");

  const [report] = shell.reports("Permissions");
  expectPanel(report!, "auto");
  expect(report!.grid.every((row) => [...row].length <= 50)).toBe(true);
  expect(report!.items["Configured rules"]).toEqual([`allow bash → ${pattern}`]);

  const bullet = report!.rows.findIndex((row) => row.trimStart().startsWith("• allow bash"));
  const column = report!.rows[bullet]!.indexOf("•");
  expect(report!.rows[bullet + 1]!.slice(0, column + 2).trim()).toBe("");
  expect(report!.rows[bullet + 1]![column + 2]).not.toBe(" ");
});

scenario("a short terminal keeps the transcript in view and ↓ scrolls the panel to its last line", async (profile) => {
  profile.settings({ permission: { edit: "deny", bash: { "git status *": "allow", "npm test": "allow" } } });
  const shell = await profile.launch({ width: 80, height: 14, env: { FX_PERMISSION_MODE: "auto" } });
  await shell.permissions({ scroll: 30 });
  expect(await shell.quit()).toBeNull();
  expect(shell.stderrText()).toBe("");

  const [report] = shell.reports("Permissions");
  const [first, ...scrolled] = report!.views;
  expect(first!.labels[0]).toBe("Mode");
  expect(first!.labels).not.toContain("Revoke");
  expect(first!.grid.some((row) => row.trimEnd() === "↑↓ scroll     esc close")).toBe(true);


  const kept = lastTranscriptRow(report!.before);
  for (const view of report!.views) {
    expect(view.grid.map((row) => row.trimEnd())).toContain(kept);
  }
  expect(scrolled.length).toBeGreaterThan(0);
  let previous = first!;
  for (const view of scrolled) {

    expect(view.rows.slice(0, -1)).toEqual(previous.rows.slice(1));
    expect(view.rows.length).toBe(first!.rows.length);
    previous = view;
  }

  expect(previous.labels.at(-1)).toBe("Revoke");
  expect(scrolled.length).toBeLessThan(30);
  expect(infoPanel(report!.closed, "Permissions")).toBeNull();
  expect(closedAsBefore(report!)).toBe(true);
});

scenario("a .git control approval offers the whole .git tree as the third choice and grants it for the session", async (profile) => {
  let release!: () => void;
  const released = new Promise<void>((resolve) => (release = resolve));
  profile.script("Write the git note.", [
    async () => {
      await released;
      return fakeGatewayToolCall("write_git_note", "write_file", { path: ".git/note.txt", content: "hi\n" });
    },
    () => fakeGatewayFinalText("WROTE_GIT_NOTE"),
  ]);
  const shell = await profile.launch({ env: { FX_PERMISSION_MODE: "ask" } });
  const before = profile.gateway.requests.length;
  await shell.session.sendText("Write the git note.");
  await shell.session.waitForPane(() => profile.gateway.requests.length > before, STEP);
  await shell.session.sendText("/permissions");
  await waitForPanel(shell.session, "Permissions", STEP, (panel) => panel.fields["Session grants"] === "none");

  release();
  await shell.session.waitForText("Apply + allow the .git control directory for this session", STEP);
  await shell.session.waitForText("this exact path for this session", STEP);
  await shell.session.sendKeys("3");
  await shell.session.waitForText("WROTE_GIT_NOTE", STEP);
  await waitForPanel(shell.session, "Permissions", STEP, (panel) => panel.fields["Session grants"] !== "none" && (panel.items["Session grants"] ?? []).some((item) => item.includes(".git")));
  await closePanel(shell.session, "Permissions", STEP);
  await shell.session.sendKeys("C-u");
  expect(await shell.quit()).toBe(shell.current());
  expect(shell.stderrText()).toBe("");
});
