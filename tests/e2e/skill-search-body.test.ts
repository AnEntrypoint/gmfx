import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { fakeGatewayFinalText, fakeGatewayToolCall, serveFakeGateway } from "./tmux-helpers";

const TIMEOUT = 60_000;
const MODEL = "openai/gpt-5";
const BODY_SKILL = [
  "---",
  "name: long-task",
  "description: Carries a large change from plan to proof.",
  "---",
  "",
  "# Long task",
  "",
  "Build all steps as one batch. Every step is witnessed in one pass, and the run log keeps each result.",
  "",
].join("\n");
const SIBLING_SKILL = "---\nname: long-task-resume\ndescription: Picks up a large change that was left open.\n---\n\n# Resume\n\nList the open items, then hand each one to the long-task skill.\n";
const OTHER_SKILL = "---\nname: release-notes\ndescription: Writes release notes from merged changes.\n---\n\n# Release notes\n\nCollect the merged changes and group them by area.\n";
const BODY_QUERY = "one batch all steps witnessed in one pass run log";

const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];

afterEach(() => {
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type Message = { role?: string; content?: unknown };

function resultsSinceLastUser(body: string): Array<Record<string, unknown>> {
  const request = JSON.parse(body) as { prompt?: Message[] };
  const all = request.prompt ?? [];
  let lastUser = -1;
  all.forEach((message, index) => {
    if (message.role === "user") lastUser = index;
  });
  return all
    .slice(lastUser + 1)
    .flatMap((message) => (Array.isArray(message.content) ? message.content : []))
    .filter((entry): entry is Record<string, unknown> => typeof entry === "object" && entry !== null && (entry as Record<string, unknown>).type === "tool-result");
}

function searchResultText(body: string, toolCallId: string): string {
  const result = resultsSinceLastUser(body).find((part) => part.toolCallId === toolCallId);
  expect(result).toBeDefined();
  const output = result!.output as Record<string, unknown>;
  expect(typeof output.value).toBe("string");
  return output.value as string;
}

describe("skill search over a skill body", () => {
  test(
    "a query made of body words finds the skill whose description lacks them",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-skill-search-body-e2e-")));
      roots.push(root);
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(workspace, { recursive: true });
      for (const [name, text] of [["long-task", BODY_SKILL], ["long-task-resume", SIBLING_SKILL]] as const) {
        mkdirSync(join(home, ".fx", "skills", name), { recursive: true });
        writeFileSync(join(home, ".fx", "skills", name, "SKILL.md"), text);
      }
      mkdirSync(join(home, ".fx", "skills", "release-notes"), { recursive: true });
      writeFileSync(join(home, ".fx", "skills", "release-notes", "SKILL.md"), OTHER_SKILL);
      writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));

      let searched = "";
      const gateway = serveFakeGateway(
        (body) => {
          const user = JSON.stringify(JSON.parse(body).prompt ?? []);
          if (user.includes("SEARCH-BODY") && resultsSinceLastUser(body).length === 0) {
            return fakeGatewayToolCall("search_body", "run_code", { body: `return JSON.parse(await gm.capability_search({ query: ${JSON.stringify(BODY_QUERY)} })).skills.map((skill) => skill.name).join(",");` });
          }
          if (resultsSinceLastUser(body).length > 0) {
            searched = searchResultText(body, "search_body");
            return fakeGatewayFinalText("search done");
          }
          return fakeGatewayFinalText("unexpected");
        },
        { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
      );
      gateways.push(gateway);

      const result = await runFx(["ask", "--quiet", "--json", "--no-save", "SEARCH-BODY find the skill"], {
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-skill-search-body-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: MODEL,
          FX_PERMISSION_MODE: "yolo",
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        timeoutMs: TIMEOUT,
      });

      expect(result.code, `stdout: ${result.stdout}\nstderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("search done");
      expect(JSON.parse(searched).value).toBe("long-task");
    },
    TIMEOUT,
  );
});
