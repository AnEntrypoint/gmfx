import { afterEach, describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { readPermissionsPanel } from "./info-panel";
import { rootSessionIds } from "./saved-sessions";
import {
  fakeGatewayFinalText,
  fakeGatewaySse,
  fakeShellRun,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

function toolCallStatuses(stdout: string) {
  const json = JSON.parse(stdout.trim()) as {
    tool_calls: Array<{ name: string; status: string }>;
  };
  return json.tool_calls.map(({ name, status }) => ({ name, status }));
}

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let activeSession: TmuxSession | null = null;

afterEach(async () => {
  if (activeSession) {
    await activeSession.kill();
    activeSession = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function createIsolatedRoot(permission: Record<string, unknown> = {}): IsolatedRoot {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), "fx-auto-mode-reliability-e2e-")),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission }),
  );
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(
  root: IsolatedRoot,
  gateway: ReturnType<typeof startFakeGateway>,
  permissionMode: "auto" | "yolo" = "auto",
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-auto-mode-reliability-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: permissionMode,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    NO_COLOR: "1",
  };
}

function toolResultText(body: string, toolCallId: string): string {
  const request = JSON.parse(body) as {
    prompt?: Array<{ content?: Array<Record<string, unknown>> }>;
  };
  const result = (request.prompt ?? [])
    .flatMap((message) => message.content ?? [])
    .find((part) => part.type === "tool-result" && part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as Record<string, unknown>;
  expect(output.type).toBe("text");
  expect(typeof output.value).toBe("string");
  const envelope = JSON.parse(output.value as string);
  expect(envelope.ok).toBe(true);
  return typeof envelope.value === "string" ? envelope.value : JSON.stringify(envelope.value);
}

function runGit(cwd: string, args: string[]) {
  const result = Bun.spawnSync(["/usr/bin/git", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  expect(
    result.exitCode,
    `git ${args.join(" ")} failed: ${result.stderr.toString()}`,
  ).toBe(0);
  return result.stdout.toString();
}

function startGateway(responses: Parameters<typeof startFakeGateway>[0]) {
  const gateway = startFakeGateway(responses);
  gateways.push(gateway);
  return gateway;
}

async function rememberSavedSessionRule(
  session: TmuxSession,
  effect: "allow" | "deny",
  command: string,
) {
  await session.sendText(
    `/permissions remember ${effect} Bash ${JSON.stringify({ command })}`,
  );
  await session.waitForText(`Remember ${effect} for this saved session`, TIMEOUT);
  await session.sendKeys("1");
  await session.waitForText("saved-session permission rule updated", TIMEOUT);
}

describe("lean auto mode reliability", () => {
  test(
    "a configured safe command runs in auto mode without a review request",
    async () => {
      const root = createIsolatedRoot({ bash: { pwd: "allow" } });
      const gateway = startGateway([
        fakeShellRun("direct_pwd", "pwd"),
        fakeGatewayFinalText("direct action complete"),
      ]);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Print the working directory."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, result.stderr).toBe(0);
      expect(result.stderr.toLowerCase()).not.toContain("permission required");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(toolCallStatuses(result.stdout)).toEqual([{ name: "run_code", status: "success" }]);
    },
    TIMEOUT,
  );

  test(
    "an exact read-only git status runs in auto mode without a review request",
    async () => {
      const root = createIsolatedRoot();
      runGit(root.workspace, ["init", "--quiet"]);
      const gateway = startGateway([
        fakeShellRun("direct_git_status", "git status --short --branch"),
        (body) => {
          expect(toolResultText(body, "direct_git_status")).toContain("## ");
          return fakeGatewayFinalText("git inspection complete");
        },
      ]);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Inspect repository status."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, result.stderr).toBe(0);
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(toolCallStatuses(result.stdout)).toEqual([{ name: "run_code", status: "success" }]);
    },
    TIMEOUT,
  );

  test(
    "read-only commands in one batch all run in auto mode without a review request",
    async () => {
      const root = createIsolatedRoot();
      runGit(root.workspace, ["init", "--quiet"]);
      writeFileSync(join(root.workspace, "untracked-probe.txt"), "probe\n");
      const gateway = startGateway([
        fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "direct_pwd",
            toolName: "run_code",
            input: { body: "return gm.Bash({ command: \"pwd\" });" },
          },
          {
            type: "tool-call",
            toolCallId: "direct_git_status",
            toolName: "run_code",
            input: { body: "return gm.Bash({ command: \"git status --short\" });" },
          },
          {
            type: "finish",
            finishReason: { unified: "tool-calls", raw: "tool-calls" },
          },
        ]),
        (body) => {
          expect(toolResultText(body, "direct_pwd")).toContain(root.workspace);
          expect(toolResultText(body, "direct_git_status")).toContain("untracked-probe.txt");
          return fakeGatewayFinalText("Direct command group complete.");
        },
      ]);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Run the direct command group."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(
        result.code,
        `stdout: ${result.stdout}\nstderr: ${result.stderr}`,
      ).toBe(0);
      expect(result.stderr).not.toContain("panic");
      expect(result.stderr).not.toContain("error:");
      expect(gateway.requests).toHaveLength(2);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(toolCallStatuses(result.stdout)).toEqual([
        { name: "run_code", status: "success" },
        { name: "run_code", status: "success" },
      ]);
      expect(result.stdout).toContain("Direct command group complete.");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "saved-session allow survives restart and runs a configured-ask command without a prompt",
    async () => {
      const allowedName = "saved-allow-ran";
      const unsavedName = "unsaved-ask-must-not-run";
      const allowedCommand = `touch ${allowedName}`;
      const unsavedCommand = `touch ${unsavedName}`;
      const root = createIsolatedRoot({
        bash: { [allowedCommand]: "ask", [unsavedCommand]: "ask" },
      });
      const gateway = startGateway([
        fakeGatewayFinalText("allow session initialized"),
        fakeShellRun("saved_allow_action", allowedCommand),
        fakeShellRun("unsaved_ask_action", unsavedCommand),
        fakeGatewayFinalText("saved allow complete"),
      ]);
      const stderrPath = join(root.root, "saved-allow-stderr.log");
      writeFileSync(stderrPath, "");
      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 140,
        height: 42,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Initialize the saved allow session.");
      await activeSession.waitForText("allow session initialized", TIMEOUT);
      await rememberSavedSessionRule(activeSession, "allow", allowedCommand);
      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;

      const sessionIds = rootSessionIds(root.home);
      expect(sessionIds).toHaveLength(1);
      const result = await runFx(
        ["ask", "--json", "--resume", sessionIds[0]!, "Run the exact saved action."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway, "yolo"),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(existsSync(join(root.workspace, allowedName))).toBe(true);
      expect(existsSync(join(root.workspace, unsavedName))).toBe(false);
      expect(gateway.classifierRequests).toHaveLength(0);
      expect(gateway.requests).toHaveLength(4);
      expect(toolCallStatuses(result.stdout)).toEqual([
        { name: "run_code", status: "success" },
        { name: "run_code", status: "error" },
      ]);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test.skipIf(!tmuxAvailable())(
    "saved-session deny is confirmed, enforced over configured allow, listed, and revoked by id",
    async () => {
      const blockedName = "saved-deny-must-not-run";
      const blockedCommand = `touch ${blockedName}`;
      const root = createIsolatedRoot({
        bash: { [blockedCommand]: "allow", pwd: "allow" },
      });
      const blockedMarker = join(root.workspace, blockedName);
      const gateway = startGateway([
        fakeGatewayFinalText("session initialized"),
        fakeShellRun("saved_deny_blocked", blockedCommand),
        (body) => {
          expect(body).toContain("policy_denied");
          return fakeShellRun("saved_deny_replan", "pwd");
        },
        fakeGatewayFinalText("saved deny replan complete"),
      ]);
      const stderrPath = join(root.root, "saved-deny-stderr.log");
      writeFileSync(stderrPath, "");
      activeSession = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: gatewayEnv(root, gateway),
        stderrPath,
        width: 140,
        height: 42,
      });
      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText("Initialize this saved session.");
      await activeSession.waitForText("session initialized", TIMEOUT);
      await rememberSavedSessionRule(activeSession, "deny", blockedCommand);

      const listed = await readPermissionsPanel(activeSession, TIMEOUT, (panel) => panel.fields["Saved rules"] === "1");
      const idMatch = /^(\d+) deny /.exec(listed.items["Saved rules"]?.[0] ?? "");
      expect(idMatch).not.toBeNull();
      const ruleId = idMatch![1];

      await activeSession.sendText("Complete the configured action safely.");
      await activeSession.waitForText("saved deny replan complete", TIMEOUT);
      expect(existsSync(blockedMarker)).toBe(false);
      expect(gateway.classifierRequests).toHaveLength(0);

      await activeSession.waitForComposer(TIMEOUT);
      await activeSession.sendText(`/permissions revoke ${ruleId}`);
      await activeSession.waitForText("Revoke this saved-session permission rule?", TIMEOUT);
      await activeSession.sendKeys("1");
      await activeSession.waitForComposer(TIMEOUT);
      await readPermissionsPanel(activeSession, TIMEOUT, (panel) => panel.fields["Saved rules"] === "none");
      expect(readFileSync(stderrPath, "utf8")).toBe("");

      await activeSession.sendText("/quit");
      expect(await activeSession.waitForSessionEnd()).toBe(true);
      await activeSession.kill();
      activeSession = null;
    },
    TIMEOUT,
  );
});
