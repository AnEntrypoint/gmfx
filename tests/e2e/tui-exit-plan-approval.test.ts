import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";
const APPROVAL_QUESTION = "Would you like to approve this plan and leave plan mode?";
const SHORT_PLAN = "PLAN_STEP_ONE read the parser\nPLAN_STEP_TWO edit the tokenizer";
const LONG_PLAN = Array.from({ length: 30 }, (_, index) => `PLAN_LINE_${String(index + 1).padStart(2, "0")}`).join("\n");

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
  stderrPath: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
let session: TmuxSession | undefined;

afterEach(async () => {
  if (session) {
    await session.kill();
    session = undefined;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-exit-plan-approval-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ permission_mode: "ask", permission: {}, default_plan_mode: true }),
  );
  writeFileSync(join(root, "stderr.log"), "");
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace), stderrPath: join(root, "stderr.log") };
}

function exitPlanCall(plan: string) {
  return fakeGatewayToolCall("exit_plan", "ExitPlanMode", { plan });
}

async function launchPlanScenario(plan: string, resultMarker: string, expectedResult = "Exited plan mode.") {
  const root = createIsolatedRoot();
  const gateway = startFakeGateway(
    [
      exitPlanCall(plan),
      (body) => {
        expect(body).toContain(expectedResult);
        return fakeGatewayFinalText(resultMarker);
      },
    ],
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  gateways.push(gateway);

  session = await TmuxSession.create({
    cmd: `env -u VERCEL_OIDC_TOKEN ${FX_BIN} 2>${root.stderrPath}`,
    cwd: root.workspace,
    env: {
      HOME: root.home,
      AI_GATEWAY_API_KEY: "fake-exit-plan-approval-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: MODEL,
      FX_AUTO_UPGRADE: "0",
      NO_COLOR: "1",
    },
    width: 120,
    height: 40,
  });
  await session.waitForComposer(TIMEOUT);
  await session.sendText("Plan the parser change.");
  return { gateway, session, stderrPath: root.stderrPath };
}

describe.skipIf(SKIP)("ExitPlanMode approval panel", () => {
  test(
    "the plan is the panel body and approving it resumes with the approved plan",
    async () => {
      const ctx = await launchPlanScenario(SHORT_PLAN, "plan approved handled");

      const pane = await ctx.session.waitForText(APPROVAL_QUESTION, TIMEOUT);
      expect(pane).toContain("  Plan PLAN_STEP_ONE read the parser");
      expect(pane).toContain("       PLAN_STEP_TWO edit the tokenizer");
      expect(pane).not.toContain("  $ PLAN_STEP_ONE");
      expect(pane).toContain("1. Approve");
      expect(pane).toContain("2. Reject");
      expect(pane).toContain("3. Revise");
      expect(pane).not.toContain("Allow once");
      expect(pane).not.toContain("don't ask again");

      await ctx.session.sendLiteralText("1");
      await ctx.session.waitForText("plan approved handled", TIMEOUT);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.gateway.requests[1]!.body).toContain("PLAN_STEP_TWO edit the tokenizer");
      expect(ctx.gateway.requests[1]!.body).toContain("Plan mode deactivated. All tools are now available.");
      expect(ctx.session.isAlive()).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "rejecting the plan keeps plan mode on and tells the model the plan was rejected",
    async () => {
      const ctx = await launchPlanScenario(
        SHORT_PLAN,
        "plan rejection handled",
        "Plan rejected by user. Plan mode remains active.",
      );

      await ctx.session.waitForText(APPROVAL_QUESTION, TIMEOUT);
      await ctx.session.sendLiteralText("2");
      await ctx.session.waitForText("plan rejection handled", TIMEOUT);
      expect(ctx.gateway.requests).toHaveLength(2);
      expect(ctx.session.isAlive()).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "revising the plan sends the typed feedback back as the tool result and keeps plan mode on",
    async () => {
      const ctx = await launchPlanScenario(
        SHORT_PLAN,
        "plan revision handled",
        "User rejected the plan. Feedback:",
      );

      await ctx.session.waitForText(APPROVAL_QUESTION, TIMEOUT);
      await ctx.session.sendLiteralText("3");
      await ctx.session.waitForText("3. Revise, ", TIMEOUT);
      await ctx.session.sendLiteralText("cover the tokenizer tests");
      await ctx.session.sendKeys("Enter");
      await ctx.session.waitForText("plan revision handled", TIMEOUT);
      expect(ctx.gateway.requests[1]!.body).toContain("cover the tokenizer tests");
      expect(ctx.session.isAlive()).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "a long plan is cut to twelve panel rows with a truncation row",
    async () => {
      const ctx = await launchPlanScenario(LONG_PLAN, "long plan handled");

      const pane = await ctx.session.waitForText(APPROVAL_QUESTION, TIMEOUT);
      expect(pane).toContain("PLAN_LINE_11");
      expect(pane).not.toContain("PLAN_LINE_12");
      expect(pane).toContain("       ... plan truncated");

      await ctx.session.sendLiteralText("1");
      await ctx.session.waitForText("long plan handled", TIMEOUT);
      expect(ctx.session.isAlive()).toBe(true);
      expect(readFileSync(ctx.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
