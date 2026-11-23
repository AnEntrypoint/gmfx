import { describe, expect, test } from "bun:test";
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
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayVerbCall,
  startFakeGateway,
  type FakeGatewayResponse,
} from "./tmux-helpers";

const TIMEOUT = 120_000;
const CONFIGURED_SANDBOX = process.platform === "darwin" ? "os" : "none";

type FxJson = {
  output: string;
  exit_code: number;
  tool_calls: Array<{ name: string; status: string }>;
};

function createIsolatedRoot(prefix: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const external = join(root, "external");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(external, { recursive: true });
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    external: realpathSync(external),
  };
}

function parseFxJson(result: { stdout: string; stderr: string; code: number | null }): FxJson {
  if (result.code !== 0) {
    throw new Error(`fx exited ${result.code}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
  }
  return JSON.parse(result.stdout.trim()) as FxJson;
}

async function runWithFakeGateway(
  root: ReturnType<typeof createIsolatedRoot>,
  args: string[],
  responses: FakeGatewayResponse[],
  env: Record<string, string> = {},
) {
  const gateway = startFakeGateway(responses);
  try {
    const result = await runFx(args, {
      cwd: root.workspace,
      env: {
        HOME: root.home,
        AI_GATEWAY_API_KEY: "fake-file-permission-key",
        VERCEL_OIDC_TOKEN: undefined,
        ...env,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_TEST_GATEWAY_CREDITS_URL: undefined,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      timeoutMs: TIMEOUT,
    });
    return { gateway, result };
  } finally {
    gateway.stop();
  }
}

describe("external file permissions", () => {
  test(
    "fx ask --yolo keeps a configured write denial and writes externally once it is lifted",
    async () => {
      const root = createIsolatedRoot("fx-yolo-permissions-");
      try {
        const target = join(root.external, "yolo-write.txt");
        const tracePath = join(root.root, "permission-trace.log");
        const settingsPath = join(root.home, ".fx", "settings.json");
        const yoloWrite = () =>
          runWithFakeGateway(
            root,
            [
              "ask",
              "--json",
              "--no-save",
              "--yolo",
              `Use only the write_file tool to create ${target} with exactly this content: FX_E2E_YOLO.`,
            ],
            [
              fakeGatewayVerbCall("yolo_write_1", "write_file", {
                path: target,
                content: "FX_E2E_YOLO",
              }),
              fakeGatewayFinalText("yolo write complete"),
            ],
            {
              FX_TRACE_LOG: tracePath,
              FX_TRACE_SCOPES: "permission",
            },
          );

        writeFileSync(
          settingsPath,
          JSON.stringify({
            permission_mode: "ask",
            sandbox: CONFIGURED_SANDBOX,
            yolo_acknowledged: false,
            permission: { edit: "deny" },
          }) + "\n",
        );
        const { gateway: deniedGateway, result: deniedResult } = await yoloWrite();
        expect(deniedResult.stderr).toContain(
          "Full access enabled: fx permission checks disabled",
        );
        const denied = parseFxJson(deniedResult);
        expect(denied.tool_calls).toEqual([{ name: "run_code", status: "error" }]);
        expect(existsSync(target)).toBe(false);
        expect(deniedGateway.requests[1]!.body).toContain("policy_denied");
        expect(readFileSync(tracePath, "utf8")).toContain(
          "tool_name=write_file permission_mode=yolo decision=policy_denied approval_source=denied",
        );
        expect(JSON.parse(readFileSync(settingsPath, "utf8"))).toMatchObject({
          permission_mode: "ask",
          sandbox: CONFIGURED_SANDBOX,
          yolo_acknowledged: true,
          permission: { edit: "deny" },
        });

        writeFileSync(
          settingsPath,
          JSON.stringify({
            permission_mode: "ask",
            sandbox: CONFIGURED_SANDBOX,
            yolo_acknowledged: true,
          }) + "\n",
        );
        rmSync(tracePath, { force: true });
        const { result: allowedResult } = await yoloWrite();
        expect(allowedResult.stderr).not.toContain("Full access enabled");
        const allowed = parseFxJson(allowedResult);
        expect(allowed.tool_calls).toEqual([{ name: "run_code", status: "success" }]);
        expect(readFileSync(target, "utf8")).toBe("FX_E2E_YOLO");
        expect(readFileSync(tracePath, "utf8")).toContain(
          "tool_name=write_file permission_mode=yolo decision=once approval_source=file_mutation",
        );
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "fx ask --auto reads and overwrites external paths and holds a rule-denied external write",
    async () => {
      const root = createIsolatedRoot("fx-file-permissions-");
      try {
        const readTarget = join(root.external, "read-fixture.txt");
        const overwriteTarget = join(root.external, "overwritten.txt");
        const deniedTarget = join(root.external, "denied-write.txt");
        const siblingTarget = join(root.root, "sibling", "allowed-write.txt");
        const tracePath = join(root.root, "permission-trace.log");
        writeFileSync(readTarget, "FX_E2E_EXTERNAL_READ\n");
        writeFileSync(overwriteTarget, "before");
        writeFileSync(join(root.home, ".fx", "settings.json"), "{}");

        const { result: readResult } = await runWithFakeGateway(
          root,
          [
            "ask",
            "--json",
            "--no-save",
            "--auto",
            `Use only the read_file tool to read ${readTarget}, then reply with exactly the file content and nothing else.`,
          ],
          [
            fakeGatewayVerbCall("external_read_1", "read_file", { path: readTarget }),
            fakeGatewayFinalText("FX_E2E_EXTERNAL_READ"),
          ],
        );
        const read = parseFxJson(readResult);
        expect(read.tool_calls).toContainEqual({ name: "run_code", status: "success" });
        expect(read.output).toContain("FX_E2E_EXTERNAL_READ");

        const { gateway: overwriteGateway, result: overwriteResult } =
          await runWithFakeGateway(
            root,
            [
              "ask",
              "--json",
              "--no-save",
              "--auto",
              `Use only the write_file tool to overwrite ${overwriteTarget} with exactly this content: FX_E2E_EXTERNAL_OVERWRITE.`,
            ],
            [
              fakeGatewayVerbCall("external_overwrite_1", "write_file", {
                path: overwriteTarget,
                content: "FX_E2E_EXTERNAL_OVERWRITE",
              }),
              fakeGatewayFinalText("external overwrite complete"),
            ],
            {
              FX_TRACE_LOG: tracePath,
              FX_TRACE_SCOPES: "permission",
            },
          );
        const trace = readFileSync(tracePath, "utf-8");
        expect(trace).toContain(
          "tool_name=write_file permission_mode=auto decision=once approval_source=file_mutation",
        );
        expect(trace).not.toContain("event=auto_review_start");
        expect(overwriteGateway.requests).toHaveLength(2);
        const overwritten = parseFxJson(overwriteResult);
        expect(overwritten.tool_calls).toContainEqual({ name: "run_code", status: "success" });
        expect(readFileSync(overwriteTarget, "utf-8")).toBe("FX_E2E_EXTERNAL_OVERWRITE");

        writeFileSync(
          join(root.home, ".fx", "settings.json"),
          JSON.stringify({
            permission: {
              edit: {
                [`${root.external}/**`]: "deny",
              },
            },
          }),
        );

        const { gateway: deniedGateway, result: deniedResult } = await runWithFakeGateway(
          root,
          [
            "ask",
            "--json",
            "--no-save",
            "--auto",
            `Use only the write_file tool to create ${deniedTarget} and ${siblingTarget}.`,
          ],
          [
            fakeGatewayVerbCall("denied_write_1", "write_file", {
              path: deniedTarget,
              content: "FX_E2E_EXTERNAL_DENIED",
            }),
            fakeGatewayVerbCall("sibling_write_1", "write_file", {
              path: siblingTarget,
              content: "FX_E2E_EXTERNAL_SIBLING",
            }),
            fakeGatewayFinalText("rule-gated writes complete"),
          ],
        );
        const gated = parseFxJson(deniedResult);
        expect(gated.tool_calls).toEqual([
          { name: "run_code", status: "error" },
          { name: "run_code", status: "success" },
        ]);
        expect(deniedGateway.requests[1]!.body).toContain("policy_denied");
        expect(existsSync(deniedTarget)).toBe(false);
        expect(readFileSync(siblingTarget, "utf-8")).toBe("FX_E2E_EXTERNAL_SIBLING");
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
