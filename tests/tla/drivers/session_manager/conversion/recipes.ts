



import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, shellQuote, targetModule } from "../../lib/context";
import {
  Acp, fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall, plainReplies, shown, TmuxSession, waitUntil, type Fixture, type Via, v1Writer,
} from "./driver";

const { readPermissionsPanel } = await targetModule("info-panel.ts");

export type Made = { id: string; read(home: string, v2: boolean): Promise<string | null> };




async function continued(f: Fixture, id: string, home: string, v2: boolean, prompt: string) {
  const mark = f.gateway.requests.length;
  const run = await f.fx(v2, ["ask", "--json", v2 ? "--resume" : "--resume-id", id, prompt], home);
  return run.code === 0 ? f.gateway.requests.slice(mark).map((r: any) => r.body as string) : null;
}


function toolResults(bodies: string[] | null, ...callIds: string[]): string | null {
  for (const body of bodies ?? []) {
    const results = JSON.parse(body).prompt.filter((m: any) => m.role === "tool").flatMap((m: any) => m.content)
      .filter((part: any) => callIds.includes(part.toolCallId));
    if (results.length === callIds.length) return JSON.stringify(results);
  }
  return null;
}


function calls(...steps: [callId: string, tool: string, input: object][]) {
  return (body: string) => {
    const next = steps.find(([callId]) => !body.includes(callId));
    return next ? fakeGatewayToolCall(...next) : fakeGatewayFinalText("CONV_CALLS_DONE");
  };
}



async function inApp(f: Fixture, home: string, v2: boolean, id: string, use: (app: any) => Promise<string | null>): Promise<string | null> {
  const app = await TmuxSession.create({
    cmd: `${shellQuote(v2 ? binary : v1Writer())} --resume ${shellQuote(id)}`, cwd: f.workspace, env: f.env(v2, home), width: 200, height: 50,
  });
  f.apps.add(app);
  try {
    const opened = await waitUntil(async () => !app.isAlive() || (await app.captureFullScrollback()).includes("session resumed"), 15_000);
    if (!opened || !app.isAlive()) return null;
    await app.waitForComposer(15_000);
    const result = await use(app);
    await app.sendText("/quit");
    await app.waitForSessionEnd(10_000);
    return result;
  } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
}



async function rules(f: Fixture): Promise<Made> {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;

  const command = "touch conv-allowed";
  await inApp(f, f.home, false, id, async app => {
    await app.sendText(`/permissions remember allow shell ${JSON.stringify({ action: "run", timeout_ms: 600_000, command })}`);
    await app.waitForText("Remember allow for this saved session", 15_000);
    await app.sendKeys("1");
    await app.waitForText("saved-session permission rule updated", 15_000);
    return "";
  });
  assert(readFileSync(join(f.v1Root, id, "permissions.json"), "utf8").includes("conv-allowed"), "the v1 app saved no permission rule");
  return {
    id, read: (home, v2) => inApp(f, home, v2, id, async app => {


      if (v2) {
        const panel = await readPermissionsPanel(app, 15_000, (shown: any) => shown.fields["Saved rules"] !== undefined);
        const count = panel.fields["Saved rules"];
        if (count === "none") return "saved-session permission rules: none";
        return [`saved-session permission rules (${count}):`, ...(panel.items["Saved rules"] ?? []).map((rule: string) => `  ${rule}`)].join("\n");
      }
      await app.sendText("/permissions");
      await app.waitForText("saved-session permission rules", 15_000);
      const text = await app.captureFullScrollback();
      const [head, ...listed] = text.slice(text.lastIndexOf("saved-session permission rules")).split("\n\n")[0]!.split("\n");
      return [head!.trimEnd(), ...listed.map((rule) => `  ${rule.trim()}`)].join("\n");
    }),
  };
}





const MINI = [{ type: "acp", name: "mini", serverId: "mini:load" }];
function mini(params: any): object {
  if (params.method === "server/discover") return { result: { resultType: "complete", supportedVersions: ["2026-07-28"], capabilities: { tools: {} } } };
  if (params.method === "tools/list") {
    return { result: { resultType: "complete", ttlMs: 60_000, tools: [{ name: "browser_read", title: "Read page", description: "Read the page", inputSchema: { type: "object" } }] } };
  }
  if (params.method === "tools/call") return { result: { resultType: "complete", content: [{ type: "text", text: "CONV_PAGE_TEXT" }] } };
  return { error: { code: -32601, message: "Method not found" } };
}

async function acpClient(f: Fixture): Promise<Made> {
  f.setRespond(calls(["conv-acp-read", "mcp_mini_browser_read", {}]));
  const client = await Acp.start(f, false);
  client.serve = mini;
  let id: string;
  try {
    const created = await client.request("session/new", {
      cwd: f.workspace, mcpServers: MINI, systemPromptMode: "append",
      systemPrompt: [{ type: "text", text: "CONV_CLIENT_PROMPT: you run inside Mini." }],
    });
    assert(!created.error, `v1 ACP session/new failed: ${JSON.stringify(created.error)}`);
    id = created.result.sessionId;
    const prompted = await client.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "CONV_FIRST" }] });
    assert(!prompted.error, `v1 ACP prompt failed: ${JSON.stringify(prompted.error)}`);
  } finally { client.close(); }
  for (const file of ["system-prompt.txt", "mcp-tool-identities.json"]) {
    assert(existsSync(join(f.v1Root, id, "client", file)), `the v1 ACP session kept no client/${file}`);
  }
  return {
    id, async read(home, v2) {
      plainReplies(f);
      const reader = await Acp.start(f, v2, home);
      try {
        const loaded = await reader.request("session/load", { sessionId: id, cwd: f.workspace, mcpServers: [] });
        if (loaded.error) return null;
        const replay = reader.updates.filter(update => update.sessionUpdate === "tool_call");
        const mark = f.gateway.requests.length;
        const prompted = await reader.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: "CONV_NEXT" }] });
        const body: string | undefined = f.gateway.requests.slice(mark).map((r: any) => r.body).find((b: string) => b.includes("CONV_NEXT"));
        if (prompted.error || !body) return null;
        const system = JSON.stringify(JSON.parse(body).prompt.filter((m: any) => m.role === "system"));
        return JSON.stringify({ instructions: /<client_instructions>.*?<\/client_instructions>/.exec(system)?.[0] ?? null, replay });
      } finally { reader.close(); }
    },
  };
}



async function terminal(f: Fixture): Promise<Made> {
  f.setRespond(calls(["conv-tty-run", "shell", {
    request: { action: "run", command: "printf 'CONV_TTY_READY\\n'; while IFS= read -r line; do :; done", profile: "clean", tty: true, yield_time_ms: 0 },
  }]));
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const shellId = /shell-[A-Za-z0-9_-]{22}/.exec(f.gateway.requests.map((r: any) => r.body).join("\n"))?.[0];
  const record = join(f.v1Root, id, `terminal/state/record-${shellId}.json`);
  assert(shellId && existsSync(record) && JSON.parse(readFileSync(record, "utf8")).lifecycle === "lost",
    "the v1 session kept no record of a terminal that ended with its process");
  return {
    id, async read(home, v2) {
      f.setRespond(calls(["conv-tty-read", "shell", { request: { action: "interact", session_id: shellId, chars: "x" } }]));
      return toolResults(await continued(f, id, home, v2, "CONV_NEXT"), "conv-tty-read");
    },
  };
}







async function unfinished(f: Fixture): Promise<Made> {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  f.setRespond(body => {
    const request = JSON.parse(body);
    if (request.toolChoice?.type === "none" && request.tools?.length === 0) return fakeGatewayFinalText("CONV_SUMMARY");
    if (body.includes("<compacted_conversation>")) {
      return fakeGatewaySse([
        { type: "text-delta", id: "answer_1", delta: "CONV_PARTIAL_REPLY" },
        { type: "error", error: { code: "gateway_stream_timeout", message: "stream exceeded maximum duration" } },
        { type: "finish", finishReason: { unified: "error", raw: "gateway_stream_timeout" } },
      ]);
    }
    return fakeGatewaySse([
      { type: "text-delta", id: "answer_1", delta: "older narrative alpha beta gamma delta\n".repeat(20_000) },
      { type: "tool-call", toolCallId: "conv-stall-run", toolName: "shell", input: { request: { action: "run", command: "echo CONV_STALL_TOOL" } } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
  });
  const stalled = f.start(false, ["ask", "--json", "--resume-id", id, "CONV_STALL"]);
  const recovery = join(f.v1Root, id, "recovery.json"), events = join(f.v1Root, id, "events.jsonl");
  const reached = await waitUntil(() => existsSync(recovery) && readFileSync(recovery, "utf8").includes("CONV_PARTIAL_REPLY"), 20_000);
  stalled.child.kill("SIGKILL");
  await stalled.finished;
  assert(reached && /"context_checkpoint"/.test(readFileSync(events, "utf8")),
    "Owned fault boundary not reached: no open v1 turn with its unfinished reply in recovery.json");
  return {
    id, async read(home, v2) {
      plainReplies(f);
      const body = (await continued(f, id, home, v2, "CONV_NEXT"))?.find(b => b.includes("CONV_NEXT"));
      return body ? shown(body, home) : null;
    },
  };
}





async function midTurn(f: Fixture): Promise<Made> {
  plainReplies(f);
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  f.setRespond(body => {
    const request = JSON.parse(body);
    if (request.toolChoice?.type === "none" && request.tools?.length === 0) return fakeGatewayFinalText("CONV_SUMMARY");
    if (body.includes("<compacted_conversation>")) {
      return body.includes("conv-step-two") ? fakeGatewayFinalText("CONV_TURN_DONE")
        : fakeGatewayToolCall("conv-step-two", "shell", { request: { action: "run", command: "echo CONV_STEP_TWO" } });
    }
    return fakeGatewaySse([
      { type: "text-delta", id: "answer_1", delta: "older narrative alpha beta gamma delta\n".repeat(20_000) },
      { type: "tool-call", toolCallId: "conv-step-one", toolName: "shell", input: { request: { action: "run", command: "echo CONV_STEP_ONE" } } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
  });
  await f.v1Ask(["--resume-id", id, "CONV_LONG"]);
  const events = readFileSync(join(f.v1Root, id, "events.jsonl"), "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line).event);
  const checkpoint = events.findIndex(event => "context_checkpoint" in event);
  const stepOne = events.findIndex(event => event.tool_result?.call_id === "conv-step-one");
  const stepTwo = events.findIndex(event => event.tool_result?.call_id === "conv-step-two");
  assert(stepOne >= 0 && stepOne < checkpoint && checkpoint < stepTwo,
    "Owned fault boundary not reached: no v1 compaction between the turn's two tool steps");
  return {
    id, async read(home, v2) {
      plainReplies(f);
      const body = (await continued(f, id, home, v2, "CONV_NEXT"))?.find(b => b.includes("CONV_NEXT"));
      return body ? shown(body, home) : null;
    },
  };
}





async function sideFile(f: Fixture): Promise<Made> {
  f.setRespond(calls(["conv-long-run", "shell", { request: { action: "run", command: "seq 1 200000", yield_time_ms: 30_000 } }]));
  const id = (await f.v1Ask(["CONV_FIRST"])).session_id;
  const files = (dir: string) => (existsSync(join(f.v1Root, id, dir)) ? readdirSync(join(f.v1Root, id, dir)) : []);
  const [result] = files("tool-results"), [replay] = files("logs/commands");
  assert(result && replay && readFileSync(join(f.v1Root, id, "tool-results", result), "utf8").includes(replay),
    "the v1 session kept no side file naming its full command output");
  return {
    id, async read(home, v2) {
      f.setRespond(calls(
        ["conv-page", "read_tool_result", { request: { handle: result, start_byte: 1, byte_count: 2000 } }],
        ["conv-replay", "read_tool_result", { request: { handle: replay, query: "150001" } }],
      ));
      return toolResults(await continued(f, id, home, v2, "CONV_NEXT"), "conv-page", "conv-replay");
    },
  };
}



export const KINDS: Record<string, { name: string; make(f: Fixture): Promise<Made>; via: Via; shows: RegExp }> = {
  rules: { name: "saved-session permission rules", make: rules, via: "app", shows: /saved-session permission rules \(1\):\n\s+1 allow shell\.run touch .*conv-allowed/ },
  acp: { name: "ACP client prompt and tool identities", make: acpClient, via: "acp", shows: /CONV_CLIENT_PROMPT.*Read page/ },
  terminal: { name: "hosted terminal state", make: terminal, via: "ask", shows: /ended when the fx process that started it exited/ },
  unfinished: { name: "unfinished reply in recovery.json", make: unfinished, via: "ask", shows: /CONV_PARTIAL_REPLY.*turn_aborted/ },
  side: { name: "tool-result side files and their handles", make: sideFile, via: "ask", shows: /total_bytes.*output_delta.*150001/ },
  midturn: { name: "cut of a compaction inside a turn", make: midTurn, via: "ask", shows: /CONV_LONG.*CONV_STEP_TWO.*CONV_TURN_DONE/ },
};
