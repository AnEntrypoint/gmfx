import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";

type IsolatedRoot = {
  root: string;
  home: string;
  workspace: string;
};

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createIsolatedRoot(): IsolatedRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-ask-synthetic-answers-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(root: IsolatedRoot, gateway: ReturnType<typeof startFakeGateway>, permissionMode: string) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-ask-synthetic-answers-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: permissionMode,
    FX_AUTO_UPGRADE: "0",
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
  return runCodeVerbReply(output.value as string);
}

function runCodeVerbReply(text: string): string {
  const envelope = JSON.parse(text);
  return typeof envelope.value === "string" ? envelope.value : JSON.stringify(envelope.value);
}

const CONTINUE_QUESTION = {
  questions: [
    {
      question: "Continue with the plan?",
      options: [{ label: "Continue" }, { label: "Stop" }],
    },
  ],
};

describe("AskUserQuestion with no human channel in full access", () => {
  test(
    "a headless full-access ask answers with the first option and labels it synthetic",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        fakeGatewayVerbCall("ask_continue", "AskUserQuestion", CONTINUE_QUESTION),
        (body) => {
          const answer = toolResultText(body, "ask_continue");
          expect(answer).toBe(
            "[{\"question\":\"Continue with the plan?\",\"answer\":\"Continue\",\"synthetic\":true}]",
          );
          return fakeGatewayFinalText("synthetic answer seen");
        },
      ]);
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Ask me one question and continue."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway, "yolo"),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("synthetic answer seen");
    },
    TIMEOUT,
  );

  test(
    "a headless ask in ask mode keeps the not-available reply instead of a synthetic answer",
    async () => {
      const root = createIsolatedRoot();
      const gateway = startFakeGateway([
        fakeGatewayVerbCall("ask_continue", "AskUserQuestion", CONTINUE_QUESTION),
        (body) => {
          const reply = toolResultText(body, "ask_continue");
          expect(reply).toContain("only available in the interactive shell");
          expect(reply).not.toContain("synthetic");
          return fakeGatewayFinalText("sentinel seen");
        },
      ]);
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Ask me one question and continue."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway, "ask"),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("sentinel seen");
    },
    TIMEOUT,
  );
});
