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

const LIVE_HELP_COMMAND = "claude --help";
const claudeOnPath = Bun.which("claude") !== null;

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
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-read-tool-result-query-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  roots.push(root);
  return { root, home, workspace: realpathSync(workspace) };
}

function gatewayEnv(root: IsolatedRoot, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-read-tool-result-query-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "yolo",
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function shellCall(command: string, id: string) {
  return fakeGatewayVerbCall(id, "Bash", { command });
}

function runCodeVerbReply(text: string): string {
  const envelope = JSON.parse(text);
  expect(envelope.ok).toBe(true);
  return typeof envelope.value === "string" ? envelope.value : JSON.stringify(envelope.value);
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

describe.skipIf(!claudeOnPath)("read_tool_result over the live claude --help output", () => {
  test(
    "a query finds the text that the ranged read returns",
    async () => {
      const root = createIsolatedRoot();
      let handle = "";
      let queriedClaudeCode = "";
      let queriedVersion = "";
      const gateway = startFakeGateway([
        shellCall(LIVE_HELP_COMMAND, "help_output"),
        (body) => {
          const commandResult = JSON.parse(toolResultText(body, "help_output")) as {
            full_output_handle?: string;
            exit_code?: number;
          };
          expect(commandResult.exit_code).toBe(0);
          handle = commandResult.full_output_handle ?? "";
          expect(handle).toMatch(/^fx-command-replay-.+\.bin$/);
          return fakeGatewayVerbCall("query_claude_code", "read_tool_result", {
            handle,
            query: "Claude Code",
          });
        },
        (body) => {
          queriedClaudeCode = toolResultText(body, "query_claude_code");
          expect(queriedClaudeCode).not.toContain("(no matches");
          return fakeGatewayVerbCall("query_version", "read_tool_result", {
            handle,
            query: "version",
          });
        },
        (body) => {
          queriedVersion = toolResultText(body, "query_version");
          expect(queriedVersion).not.toContain("(no matches");
          expect(queriedVersion).toContain("--version");
          return fakeGatewayVerbCall("ranged_read", "read_tool_result", {
            handle,
            start_byte: 1,
            byte_count: 400,
          });
        },
        (body) => {
          const ranged = toolResultText(body, "ranged_read");
          expect(ranged).toContain("Claude Code");
          return fakeGatewayFinalText("query matches the ranged read");
        },
      ]);
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Run the colored help output retrieval fixture."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("query matches the ranged read");
    },
    TIMEOUT,
  );
});

describe("read_tool_result over output with SGR color codes", () => {
  test(
    "a query finds text that color codes split in the replay",
    async () => {
      const root = createIsolatedRoot();
      let handle = "";
      const colored = "printf '\\033[1;31mClaude\\033[0m \\033[32mCode\\033[0m is ready\\n'";
      const gateway = startFakeGateway([
        shellCall(colored, "colored_output"),
        (body) => {
          const commandResult = JSON.parse(toolResultText(body, "colored_output")) as {
            full_output_handle?: string;
            exit_code?: number;
          };
          expect(commandResult.exit_code).toBe(0);
          handle = commandResult.full_output_handle ?? "";
          expect(handle).toMatch(/^fx-command-replay-.+\.bin$/);
          return fakeGatewayVerbCall("query_colored", "read_tool_result", {
            handle,
            query: "Claude Code is ready",
          });
        },
        (body) => {
          const queried = toolResultText(body, "query_colored");
          expect(queried).not.toContain("(no matches");
          expect(queried).toContain("Claude");
          return fakeGatewayFinalText("query finds the split text");
        },
      ]);
      gateways.push(gateway);

      const result = await runFx(
        ["ask", "--quiet", "--json", "--no-save", "Print the colored line and query it."],
        {
          cwd: root.workspace,
          env: gatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        },
      );

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("query finds the split text");
    },
    TIMEOUT,
  );
});
