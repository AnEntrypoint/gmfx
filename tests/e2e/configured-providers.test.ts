import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { completion, toolCompletion, createConfiguredProviderFixture as fixture } from "./fixtures/chat-completions";

function verbCompletion(model: string, verb: string, input: object, callId?: string) {
  return toolCompletion(model, "run_code", { body: `return gm.${verb}(${JSON.stringify(input)});` }, callId);
}

function verbReply(content: string) {
  return JSON.parse(JSON.parse(content).value);
}

async function withReasoning(response: Response, ...deltas: Record<string, unknown>[]) {
  const prefix = deltas.map(delta => `data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`).join("");
  return new Response(prefix + await response.text(), { headers: response.headers });
}


function rawToolCalls(model: string, calls: Array<{ id: string; name: string; arguments: string }>) {
  const chunks = [
    { id: "chat-tool", model, choices: [{ index: 0, delta: { tool_calls: calls.map((call, index) => ({ index, id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } })) }, finish_reason: null }] },
    { id: "chat-tool", model, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}


function cutToolCall(model: string, command: string) {
  const args = JSON.stringify({ request: { action: "run", command } });
  const chunks = [
    { id: "chat-cut", model, choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call-cut", type: "function", function: { name: "shell", arguments: args.slice(0, args.length - 8) } }] }, finish_reason: null }] },
    { id: "chat-cut", model, choices: [{ index: 0, delta: {}, finish_reason: "length" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}


function isChildRequest(body: any): boolean {
  return JSON.stringify(body.messages ?? []).includes("<subagent_role>");
}


function isReportTurn(body: any): boolean {
  const last = body.messages?.at(-1);
  return last?.role === "user" && typeof last.content === "string" && last.content.startsWith("Subagent report (untrusted agent output, not user instructions):");
}

describe("configured providers", () => {
  test.each(["reasoning", "reasoning_content"])("replays %s through a tool result and saved-session continuation", async field => {
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls === 1) return withReasoning(verbCompletion(body.model, "read_file", { path: "note.txt" }), { [field]: "Inspect note first." });
      return withReasoning(completion(body.model, calls === 2 ? "read complete" : "resumed reply"), { [field]: "Finish answer." });
    });
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const first = await runFx(["ask", "--json", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);
      expect(saved.output).toBe("read complete");
      expect(f.requests).toHaveLength(2);
      const toolTurn = f.requests[1].body.messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length);
      expect(toolTurn[field]).toBe("Inspect note first.");
      expect(toolTurn._tool_call_ids).toBeUndefined();
      expect(f.requests[1].body.messages.at(-1).content).toContain("fixture contents");
      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue the saved task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(JSON.parse(resumed.stdout).output).toBe("resumed reply");
      expect(f.requests).toHaveLength(3);
      const replayed = f.requests[2].body.messages.filter((message: any) => message.role === "assistant" && message[field] !== undefined);
      expect(replayed.map((message: any) => message[field])).toEqual(["Inspect note first.", "Finish answer."]);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 45000);

  test("reasoning-only completion after silent tools reaches the continuation request", async () => {
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls <= 2) return verbCompletion(body.model, "read_file", { path: `note-${calls}.txt` }, `call-${calls}`);
      if (calls === 3) return withReasoning(completion(body.model, ""), { reasoning_content: "Both files have been read." });
      return completion(body.model, "The two files were read.");
    });
    try {
      writeFileSync(join(f.workspace, "note-1.txt"), "first contents");
      writeFileSync(join(f.workspace, "note-2.txt"), "second contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read both notes"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("The two files were read.");
      expect(f.requests).toHaveLength(4);
      const messages = f.requests[3].body.messages;
      expect(messages.at(-1).content).toBe("Summarize what you just did.");
      expect(messages.at(-2).reasoning_content).toBe("Both files have been read.");
      expect(messages.at(-2).tool_calls).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("a tool call cut off by the provider's own limit is resent once with fx's limit", async () => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? cutToolCall(body.model, "printf ran > cut.txt") : completion(body.model, "finished after the resend"));
    try {

      (f.settings.providers.local.model_metadata as any)["local-model"] = { context_window: 262144, supports_tool_use: true };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the command"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).final_output).toBe("finished after the resend");
      expect(f.requests).toHaveLength(2);
      expect(f.requests[0].body.max_tokens).toBeUndefined();
      expect(f.requests[1].body.max_tokens).toBe(32768);
      expect(JSON.stringify(f.requests[1].body.messages)).not.toContain("call-cut");
      expect(result.stderr).toContain("Retrying with a higher limit.");
      expect(existsSync(join(f.workspace, "cut.txt"))).toBe(false);
    } finally { f.close(); }
  }, 25000);

  test("a tool call cut off at the model's own limit is not resent when that would repeat the request", async () => {
    let calls = 0;
    const f = fixture(body => ++calls === 1 ? cutToolCall(body.model, "printf ran > cut.txt") : completion(body.model, "a resend must not be sent"));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "Run the command"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(result.code).toBe(1);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.max_tokens).toBe(8192);
      expect(result.stderr).toContain("so I did not run them");
      expect(existsSync(join(f.workspace, "cut.txt"))).toBe(false);
    } finally { f.close(); }
  }, 25000);

  test("preserves opaque reasoning and tool IDs on resume but never forwards them to another connection", async () => {
    const firstDetail = { type: "reasoning.text", text: "Inspect the file.", signature: "opaque-signature", format: "anthropic-claude-v1", index: 0 };
    const secondDetail = { type: "reasoning.encrypted", data: "opaque-encrypted-data", id: "reasoning-1", index: 1 };
    const callId = "call:opaque/1";
    let calls = 0;
    const f = fixture(body => {
      calls++;
      if (calls === 1) return withReasoning(verbCompletion(body.model, "read_file", { path: "note.txt" }, callId), { reasoning_details: [firstDetail] }, { reasoning_details: [secondDetail] });
      return completion(body.model, calls === 2 ? "read complete" : "continued");
    });
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const first = await runFx(["ask", "--json", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const saved = JSON.parse(first.stdout);
      expect(saved.output).toBe("read complete");
      expect(f.requests).toHaveLength(2);
      const toolTurn = f.requests[1].body.messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length);
      expect(toolTurn.reasoning_details).toEqual([firstDetail, secondDetail]);
      expect(toolTurn.tool_calls[0].id).toBe(callId);
      expect(toolTurn._tool_call_ids).toBeUndefined();
      expect(f.requests[1].body.messages.at(-1).tool_call_id).toBe(callId);
      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue the saved task"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(3);
      const restored = f.requests[2].body.messages.find((message: any) => message.reasoning_details);
      expect(restored.reasoning_details).toEqual([firstDetail, secondDetail]);
      expect(restored.tool_calls[0].id).toBe(callId);
      const switched = await runFx(["ask", "--json", "--resume", saved.session_id, "Continue on the other connection"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (switched.code !== 0) throw new Error(switched.stdout + switched.stderr);
      expect(f.requests).toHaveLength(4);
      expect(f.requests[3].authorization).toBe(`Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`);
      expect(f.requests[3].body.messages.every((message: any) => message.reasoning_details === undefined && message.reasoning === undefined && message.reasoning_content === undefined)).toBe(true);
    } finally { f.close(); }
  }, 65000);

  test("status identifies the configured connection and endpoint without probing it", async () => {
    const f = fixture();
    try {
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.model_source).toBe("local");
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(status.connected_providers).toContain("local");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("anonymous local requests use Chat Completions without Gateway credentials", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(result.stderr).toBe("");
      if (result.code !== 0) throw new Error(`fx ask failed: ${result.stdout} ${result.stderr}; paths=${f.requests.map(r => r.path).join(",")}`);
      expect(result.code).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("local reply");
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBeNull();
      expect(f.requests[0].path).toBe("/v1/chat/completions");
      expect(f.requests[0].body.model).toBe("local-model");
      expect(f.requests[0].body.messages.some((message: any) => message.role === "user")).toBe(true);
      expect(f.requests[0].body.prompt).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("terminal usage may repeat an empty matching finished choice", async () => {
    const f = fixture(async body => {
      const response = completion(body.model);
      const wire = (await response.text()).replace('"choices":[]', '"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop"}]');
      return new Response(wire, { headers: response.headers });
    });
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      expect(result.stderr).toBe("");
      const parsed = JSON.parse(result.stdout);
      expect(parsed.final_output).toBe("local reply");
      expect(parsed.usage).toMatchObject({ input_tokens: 12, output_tokens: 3 });
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  });

  test("CLI selection persists a configured name and uses only its credential", async () => {
    const f = fixture();
    try {
      const selection = await runFx(["provider", "remote"], { cwd: f.workspace, env: f.env });
      expect(selection.code).toBe(0);
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("remote");
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(`fx ask failed: ${result.stdout} ${result.stderr}; paths=${f.requests.map(r => r.path).join(",")}`);
      expect(result.code).toBe(0);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(f.requests[0].body.model).toBe("remote-model");
    } finally { f.close(); }
  }, 25000);

  test("ask --provider picks a connection for one request, beats FX_PROVIDER, and is never saved", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "--provider", "remote", "remember this"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(f.requests[0].body.model).toBe("remote-model");
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("local");
      const saved = JSON.parse(first.stdout);

      const flagWins = await runFx(["ask", "--json", "--no-save", "--provider=local", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (flagWins.code !== 0) throw new Error(flagWins.stdout + flagWins.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].authorization).toBeNull();
      expect(f.requests[1].body.model).toBe("local-model");

      const resumed = await runFx(["ask", "--json", "--resume", saved.session_id, "--provider", "local", "continue"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(3);
      expect(f.requests[2].authorization).toBeNull();
      expect(f.requests[2].body.model).toBe("local-model");
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("local");
    } finally { f.close(); }
  }, 65000);

  test("CLI selection names an unknown connection and leaves settings unchanged", async () => {
    const f = fixture();
    try {
      const before = readFileSync(f.settingsPath, "utf8");
      const selection = await runFx(["provider", "remte"], { cwd: f.workspace, env: f.env });
      expect(selection.code).toBe(2);
      expect(selection.stdout).toBe("");
      expect(selection.stderr).toBe(
        'fx provider: unknown provider remte; expected gateway, codex, grok, or a name under "providers" in ~/.fx/settings.json\n',
      );

      const ask = await runFx(["ask", "--provider", "remte", "hi"], { cwd: f.workspace, env: f.env });
      expect(ask.code).toBe(2);
      expect(ask.stderr).toBe(
        'fx ask: unknown provider remte; expected gateway, codex, grok, or a name under "providers" in ~/.fx/settings.json\n',
      );
      expect(readFileSync(f.settingsPath, "utf8")).toBe(before);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("CLI selection creates an owned model key from workspace-only preferences", async () => {
    const f = fixture();
    try {
      delete (f.settings.models as any).remote;
      (f.settings as any).workspaces = { [f.workspace]: { models: { remote: "workspace-model" } } };
      f.save();
      const selection = await runFx(["provider", "remote"], { cwd: f.workspace, env: f.env });
      if (selection.code !== 0) throw new Error(selection.stdout + selection.stderr);
      const saved = JSON.parse(readFileSync(f.settingsPath, "utf8"));
      expect(saved.provider).toBe("remote");
      expect(saved.models).toEqual({ local: "local-model", remote: "workspace-model" });
      expect(saved.workspaces[f.workspace].models.remote).toBe("workspace-model");
      expect(saved.providers).toEqual(f.settings.providers);
    } finally { f.close(); }
  });

  test("catalog listing and file model selection do not require a catalog login", async () => {
    const f = fixture();
    try {
      f.settings.provider = "remote";
      f.save();
      const env = { ...f.env, FX_TEST_PROVIDER_TOKEN: undefined };
      const catalog = await runFx(["models"], { cwd: f.workspace, env });
      if (catalog.code !== 0) throw new Error(catalog.stdout + catalog.stderr);
      expect(catalog.stdout).toContain("remote-model");
      f.settings.models.remote = "opaque/custom:v1";
      f.save();
      const selection = await runFx(["status", "--json"], { cwd: f.workspace, env });
      if (selection.code !== 0) throw new Error(selection.stdout + selection.stderr);
      expect(JSON.parse(selection.stdout).model).toBe("opaque/custom:v1");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("executes a tool and returns its result to the same connection", async () => {
    const f = fixture(body => body.messages.some((message: any) => message.role === "tool")
      ? completion(body.model, "read succeeded")
      : verbCompletion(body.model, "read_file", { path: "note.txt" }));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("read succeeded");
      expect(f.requests).toHaveLength(2);
      const returned = f.requests[1].body.messages.find((message: any) => message.role === "tool");
      expect(returned.tool_call_id).toBe("call-local");
      expect(returned.content).toContain("fixture contents");
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 25000);

  test("unknown tools and malformed arguments are answered and the turn continues", async () => {
    const readNoteArguments = JSON.stringify({ body: `return gm.read_file(${JSON.stringify({ path: "note.txt" })});` });
    const f = fixture(body => body.messages.some((message: any) => message.role === "tool")
      ? completion(body.model, "recovered")
      : rawToolCalls(body.model, [
        { id: "call-read", name: "run_code", arguments: readNoteArguments },
        { id: "call-missing", name: "missing_tool", arguments: "{}" },
        { id: "call-malformed", name: "run_code", arguments: readNoteArguments.slice(0, -2) },
      ]));
    try {
      writeFileSync(join(f.workspace, "note.txt"), "fixture contents");
      const result = await runFx(["ask", "--json", "--no-save", "Read note.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const output = JSON.parse(result.stdout);
      expect(output.output).toBe("recovered");
      expect(output.tool_calls.map((call: any) => [call.name, call.status]).sort()).toEqual([
        ["missing_tool", "error"],
        ["run_code", "error"],
        ["run_code", "success"],
      ]);
      expect(f.requests).toHaveLength(2);
      const messages = f.requests[1].body.messages;
      const replayed = messages.find((message: any) => message.role === "assistant" && message.tool_calls?.length).tool_calls;
      expect(replayed.map((call: any) => call.function.arguments)).toEqual([readNoteArguments, "{}", "{}"]);
      const results = Object.fromEntries(messages.filter((message: any) => message.role === "tool").map((message: any) => [message.tool_call_id, message.content]));
      expect(results["call-read"]).toContain("fixture contents");
      expect(results["call-missing"]).toBe("Unsupported tool: missing_tool");
      expect(results["call-malformed"]).toContain("did not run the call");
      expect(results["call-malformed"]).not.toContain("fixture contents");
    } finally { f.close(); }
  }, 25000);

  test("saved sessions resume the named connection and reject endpoint rebinding", async () => {
    const f = fixture();
    try {
      const first = await runFx(["ask", "--json", "remember this"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      expect(session.length).toBeGreaterThan(0);
      const second = await runFx(["ask", "--json", "--resume", session, "continue"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (second.code !== 0) throw new Error(second.stdout + second.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].body.messages.some((message: any) => message.content?.includes("remember this"))).toBe(true);
      f.settings.providers.local.base_url += "/changed";
      f.save();
      const rebound = await runFx(["ask", "--json", "--resume", session, "continue again"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(rebound.code).not.toBe(0);
      expect(f.requests).toHaveLength(2);
    } finally { f.close(); }
  }, 60000);

  test.each(["inherited", "override", "unknown"])("subagent requests preserve connection and %s model capabilities", async mode => {
    const childModel = mode === "inherited" ? "local-model" : mode === "override" ? "child-model" : "unknown-model";
    const f = fixture(body => {
      if (isChildRequest(body)) return completion(body.model, "child reply");
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      return verbCompletion(body.model, "Agent", { description: "Delegate", prompt: "child-marker", ...(mode === "inherited" ? {} : { model: childModel }) });
    });
    f.settings.providers.local.model_metadata["local-model"].max_output_tokens = 512;
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 1024, supports_tool_use: true };
    f.save();
    try {
      const result = await runFx(["ask", "--json", "Delegate a task"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("parent reply");
      expect(f.requests.map(request => isChildRequest(request.body))).toEqual([false, true, false]);
      expect(f.requests[1].body.messages.at(-1)).toEqual({ role: "user", content: "child-marker" });
      expect([f.requests[1].body.model, f.requests[1].body.max_tokens]).toEqual([childModel, mode === "unknown" ? undefined : mode === "override" ? 1024 : 512]);
      const returned = verbReply(f.requests[2].body.messages.at(-1).content);
      expect(returned.ok).toBe(true);
      expect(returned.result).toContain("child reply");
      expect([f.requests[0], f.requests[2]].map(request => [request.body.model, request.body.max_tokens])).toEqual([["local-model", 512], ["local-model", 512]]);
      expect(f.requests.every(request => request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 35000);

  test("persistent child capabilities stay bound when the parent changes providers", async () => {
    let callId = 0;
    const f = fixture(body => {
      if (isChildRequest(body)) return completion(body.model, "child reply");
      if (isReportTurn(body)) return completion(body.model, "report handled");
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      callId++;
      return verbCompletion(body.model, "Agent", { description: "Read", prompt: "read the child fixture", ...(callId === 1 ? {} : { resume: "agent-child-call-1-1" }) }, `child-call-${callId}`);
    });
    const toolReturns = (requests: typeof f.requests) => requests.filter(request => request.body.messages.at(-1)?.role === "tool").map(request => JSON.parse(request.body.messages.at(-1).content));
    const agentResults = (requests: typeof f.requests) => toolReturns(requests).map(returned => JSON.parse(returned.value));
    f.settings.models.local = "shared-model";
    f.settings.models.remote = "shared-model";
    (f.settings.providers.local as any).model_metadata = { "shared-model": { context_window: 32768, max_output_tokens: 512, supports_tool_use: true } };
    (f.settings.providers.remote as any).model_metadata = { "shared-model": { context_window: 65536, max_output_tokens: 1024, supports_tool_use: true } };
    f.save();
    try {
      const first = await runFx(["ask", "--json", "Create the named child"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 30000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const id = JSON.parse(first.stdout).session_id;
      expect(f.requests.map(request => [isChildRequest(request.body), request.body.max_tokens, request.authorization])).toEqual([
        [false, 1024, `Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`],
        [true, 1024, `Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`],
        [false, 1024, `Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`],
      ]);
      expect(agentResults(f.requests).map(result => [result.ok, result.result.includes("agent_id: agent-child-call-1")])).toEqual([[true, true]]);
      const afterFirst = f.requests.length;
      const resumed = await runFx(["ask", "--json", "--resume", id, "Continue the named child"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      const resumedRequests = f.requests.slice(afterFirst);
      expect(agentResults(resumedRequests).map(result => [result.ok, result.result.includes("child reply")])).toEqual([[true, true]]);
      const resumedChild = resumedRequests.filter(request => isChildRequest(request.body));
      const resumedParent = resumedRequests.filter(request => !isChildRequest(request.body));
      expect(resumedChild.map(request => [request.body.max_tokens, request.authorization, request.body.messages.filter((message: any) => message.content === "read the child fixture").length])).toEqual([[1024, `Bearer ${f.env.FX_TEST_PROVIDER_TOKEN}`, 2]]);
      expect(resumedParent.length).toBeGreaterThanOrEqual(2);
      expect(resumedParent.every(request => request.body.max_tokens === 512 && request.authorization === null)).toBe(true);
      f.settings.providers.remote.base_url += "/changed";
      f.save();
      const afterResumed = f.requests.length;
      const rebound = await runFx(["ask", "--json", "--resume", id, "Continue the named child again"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "local" }, timeoutMs: 30000 });
      if (rebound.code !== 0) throw new Error(rebound.stdout + rebound.stderr);
      const reboundRequests = f.requests.slice(afterResumed);
      expect(reboundRequests.every(request => !isChildRequest(request.body) && request.authorization === null && request.path === "/v1/chat/completions")).toBe(true);
      const failed = toolReturns(reboundRequests);
      expect(failed.length).toBeGreaterThanOrEqual(1);
      expect(failed.every(result => result.ok === false && result.error.includes("status: failed"))).toBe(true);
    } finally { f.close(); }
  }, 100000);

  test("configured child compaction uses the model capability lookup", async () => {
    let parentTurns = 0;
    const f = fixture(body => {
      if (body.model === "child-model") return completion(body.model, "child reply " + "detail ".repeat(2000), Math.ceil(JSON.stringify(body).length / 4));
      if (isReportTurn(body)) return completion(body.model, "report handled");
      if (body.messages.at(-1)?.role === "tool") return completion(body.model, "parent reply");
      parentTurns++;
      return verbCompletion(body.model, "Agent", { description: "Read", prompt: `child context ${parentTurns}`, ...(parentTurns === 1 ? { model: "child-model" } : { resume: "agent-context-call-1-1" }) }, `context-call-${parentTurns}`);
    });
    (f.settings.providers.local.model_metadata as any)["child-model"] = { context_window: 32768, max_output_tokens: 512, supports_tool_use: true };
    f.save();
    let id: string | undefined;
    try {
      for (let turn = 0; turn < 12; turn++) {
        const result = await runFx(["ask", "--json", ...(id ? ["--resume", id] : []), "Continue the child context"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
        if (result.code !== 0) throw new Error(result.stdout + result.stderr);
        id = JSON.parse(result.stdout).session_id;
        const returned = f.requests.filter(request => request.body.model === "local-model" && request.body.messages.at(-1)?.role === "tool").at(-1)!.body.messages.at(-1).content;
        const reply = verbReply(returned);
        if (!reply.ok) throw new Error(returned);
        expect(reply.result).toContain("agent_id: agent-context-call-1");
      }
      const childRequests = f.requests.filter(request => request.body.model === "child-model");
      expect(childRequests.some(request => JSON.stringify(request.body.messages).includes("<compacted_conversation>"))).toBe(true);
      expect(childRequests.every(request => request.body.max_tokens > 0 && request.body.max_tokens <= 512)).toBe(true);
      expect(f.requests.every(request => request.path === "/v1/chat/completions" && request.authorization === null)).toBe(true);
    } finally { f.close(); }
  }, 90000);

  test("auto mode runs a shell call on the custom connection without a reviewer request", async () => {
    const f = fixture(body => body.messages.some((message: any) => message.role === "tool")
      ? completion(body.model, "command finished")
      : verbCompletion(body.model, "Bash", { command: "printf ran > auto-ran.txt", description: "Write the marker" }));
    try {
      f.settings.permission_mode = "auto";
      (f.settings.providers.local as any).reviewer_model = "review-model";
      (f.settings.providers.local.model_metadata as any)["review-model"] = { context_window: 262144, max_output_tokens: 512 };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "Run the command"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(JSON.parse(result.stdout).output).toBe("command finished");
      expect(readFileSync(join(f.workspace, "auto-ran.txt"), "utf8")).toBe("ran");
      expect(f.requests.map(request => [request.path, request.body.model, request.authorization])).toEqual([
        ["/v1/chat/completions", "local-model", null],
        ["/v1/chat/completions", "local-model", null],
      ]);
      expect(f.requests.some(request => request.body.tools?.some((tool: any) => tool.function?.name === "permission_decision"))).toBe(false);
    } finally { f.close(); }
  }, 35000);

  test("resume uses its own key when a different bearer connection is the default", async () => {
    const f = fixture();
    try {
      (f.settings.providers.local as any).auth = { type: "bearer", env: "FX_TEST_LOCAL_TOKEN" };
      f.save();
      const env = { ...f.env, FX_TEST_LOCAL_TOKEN: "local-only-token" };
      const first = await runFx(["ask", "--json", "remember remote"], { cwd: f.workspace, env: { ...env, FX_PROVIDER: "remote" }, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const id = JSON.parse(first.stdout).session_id;
      const resumed = await runFx(["ask", "--json", "--resume", id, "continue"], { cwd: f.workspace, env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].body.model).toBe("remote-model");
      expect(f.requests[1].authorization).toBe("Bearer own-provider-token");
    } finally { f.close(); }
  }, 45000);

  test("malformed workspace provider overrides fail before any network request", async () => {
    const f = fixture();
    try {
      f.settings.provider = "gateway";
      (f.settings as any).workspaces = { [f.workspace]: { provider: "local", permission_mode: "invalid" } };
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "local-only prompt"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 15000);

  test("a tool call cut off in every stream is never executed, and the run ends after six requests", async () => {
    const f = fixture(body => new Response(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "partial", type: "function", function: { name: "write_file", arguments: JSON.stringify({ path: "must-not-exist.txt", content: "unsafe" }) } }] }, finish_reason: "tool_calls" }] })}\n\n`, { headers: { "content-type": "text/event-stream" } }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "--full-access", "Write must-not-exist.txt"], { cwd: f.workspace, env: f.env, timeoutMs: 80000 });
      expect(result.code).not.toBe(0);
      expect(existsSync(join(f.workspace, "must-not-exist.txt"))).toBe(false);
      expect(f.requests).toHaveLength(6);
    } finally { f.close(); }
  }, 90000);

  test.each(["headers", "stream"])("cancellation stops stalled custom %s without replaying the POST", async phase => {
    const f = fixture(() => phase === "headers" ? new Promise<Response>(() => {}) : new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}\n\n')); } }), { headers: { "content-type": "text/event-stream" } }));
    const env: Record<string, string | undefined> = { ...process.env };
    for (const [key, value] of Object.entries(f.env)) {
      if (value === undefined) delete env[key]; else env[key] = value;
    }
    const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const output = Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    let forced = false;
    const timer = setTimeout(() => { forced = true; child.kill("SIGKILL"); }, 8000);
    try {
      const until = Date.now() + 5000;
      while (f.requests.length === 0 && child.exitCode === null && Date.now() < until) await Bun.sleep(10);
      expect(f.requests).toHaveLength(1);
      child.kill("SIGINT");
      expect(await child.exited).toBe(130);
      await output;
      expect(forced).toBe(false);
      expect(f.requests).toHaveLength(1);
    } finally {
      clearTimeout(timer);
      if (child.exitCode === null) child.kill("SIGKILL");
      await child.exited;
      await output;
      f.close();
    }
  }, 12000);

  test("a connection without a saved model runs from --model or FX_MODEL and rejects a blank FX_MODEL", async () => {
    const f = fixture();
    try {
      delete (f.settings.models as Record<string, string>).local;
      f.save();
      const chatModels = () => f.requests.filter(request => request.path === "/v1/chat/completions").map(request => request.body.model);

      const flag = await runFx(["ask", "--json", "--no-save", "--model", "flag-model", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 10000 });
      if (flag.code !== 0) throw new Error(flag.stdout + flag.stderr);
      const env = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "  env-model  " }, timeoutMs: 10000 });
      if (env.code !== 0) throw new Error(env.stdout + env.stderr);
      expect(chatModels()).toEqual(["flag-model", "env-model"]);

      const status = await runFx(["status", "--json"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "env-model" } });
      expect(status.code).toBe(0);
      expect(JSON.parse(status.stdout)).toMatchObject({ model: "env-model", model_origin: "FX_MODEL", model_source: "local" });

      const blank = await runFx(["status"], { cwd: f.workspace, env: { ...f.env, FX_MODEL: "   " } });
      expect(blank.code).toBe(1);
      expect(blank.stderr).toBe("fx: no model is selected for this connection; save one under \"models\" in ~/.fx/settings.json, or set a model for this run with --model or FX_MODEL\n");
      expect(chatModels()).toHaveLength(2);
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).models.local).toBeUndefined();
    } finally { f.close(); }
  }, 25000);

  test("redirects cannot forward credentials to another connection", async () => {
    const target = fixture();
    const f = fixture(() => new Response("redirect", { status: 307, headers: { location: `${target.settings.providers.local.base_url}/chat/completions` } }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" } });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(1);
      expect(target.requests).toHaveLength(0);
    } finally { f.close(); target.close(); }
  });

  test("provider error diagnostics redact the selected key", async () => {
    const f = fixture(() => Response.json({ error: { message: "rejected own-provider-token" } }, { status: 401, headers: { "retry-after": "3" } }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote" }, timeoutMs: 10000 });
      expect(result.code).toBe(1);
      expect(() => JSON.parse(result.stdout)).not.toThrow();
      expect(result.stderr).not.toContain("panic");
      expect(result.stdout + result.stderr).not.toContain("own-provider-token");
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 15000);

  test.each(["slashes", "unicode", "plain", "duplicate"])("provider errors redact opaque credentials encoded as %s", async encoding => {
    const token = "alpha/beta/gamma";
    const encoded = encoding === "slashes" ? token.replaceAll("/", "\\/") : [...token].map(char => `\\u${char.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
    const body = encoding === "plain" ? `rejected ${token}` : encoding === "duplicate" ? `{"error":{"message":"rejected ${encoded}"},"${token}":0,"${encoded}":1}` : `{"error":{"message":"rejected ${encoded}","code":"${encoded}"}}`;
    const f = fixture(() => new Response(body, { status: 400 }));
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: token } });
      expect(result.code).toBe(1);
      expect(() => JSON.parse(result.stdout)).not.toThrow();
      expect(result.stdout + result.stderr).not.toContain(token);
      expect(result.stdout + result.stderr).toContain(encoding === "duplicate" ? "could not be decoded" : "rejected");
    } finally { f.close(); }
  });

  test("corrupt profile JSON cannot silently choose Gateway", async () => {
    const f = fixture();
    try {
      writeFileSync(f.settingsPath, '{"provider":"local",');
      const result = await runFx(["ask", "--json", "--no-save", "local-only prompt"], { cwd: f.workspace, env: f.env, timeoutMs: 8000 });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 12000);

  test("invalid bearer header bytes are rejected before sending", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: "bad\nheader" } });
      expect(result.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  });

  test("process overrides select a connection and opaque model without rewriting settings", async () => {
    const f = fixture();
    try {
      const before = readFileSync(f.settingsPath, "utf8");
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_MODEL: "unlisted-model" } });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.model).toBe("unlisted-model");
      expect(f.requests[0].authorization).toBe("Bearer own-provider-token");
      expect(readFileSync(f.settingsPath, "utf8")).toBe(before);
    } finally { f.close(); }
  });

  test("project files cannot replace profile connections", async () => {
    const f = fixture();
    try {
      writeFileSync(join(f.workspace, ".fx.json"), JSON.stringify({ provider: "remote", providers: { local: "invalid" } }));
      const result = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: f.env });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].body.model).toBe("local-model");
      expect(f.requests[0].authorization).toBeNull();
    } finally { f.close(); }
  });

  test("saved history remains readable after its connection is removed", async () => {
    const f = fixture();
    try {
      const saved = await runFx(["ask", "--json", "remember this"], { cwd: f.workspace, env: f.env });
      if (saved.code !== 0) throw new Error(saved.stdout + saved.stderr);
      const id = JSON.parse(saved.stdout).session_id;
      delete (f.settings.providers as any).local;
      f.save();
      const history = await runFx(["session", id, "--json"], { cwd: f.workspace, env: f.env });
      if (history.code !== 0) throw new Error(history.stdout + history.stderr);
      expect(history.stdout).toContain("remember this");
      expect(f.requests).toHaveLength(1);
    } finally { f.close(); }
  }, 25000);

  test("ignored workspace provider definitions stay inert when a sibling workspace field is malformed", async () => {
    const f = fixture();
    try {
      (f.settings as any).workspaces = {
        [f.workspace]: {
          providers: { shadow: { protocol: "openai-chat-completions", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } },
          effort: 42,
        },
      };
      f.save();
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.model_source).toBe("local");
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(status.connected_providers).toContain("local");
      expect(status.connected_providers).not.toContain("shadow");
      expect(result.stderr).toContain("malformed_settings");
    } finally { f.close(); }
  });

  test("ignored workspace provider definitions with broken protocols stay inert during recovery", async () => {
    const f = fixture();
    try {
      (f.settings as any).workspaces = {
        [f.workspace]: {
          providers: { shadow: { protocol: "bogus", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } },
          effort: 42,
        },
      };
      f.save();
      const result = await runFx(["status", "--json"], { cwd: f.workspace, env: f.env });
      expect(result.code).toBe(0);
      const status = JSON.parse(result.stdout);
      expect(status.provider_endpoint).toBe(f.settings.providers.local.base_url);
      expect(result.stderr).toContain("malformed_settings");
    } finally { f.close(); }
  });

  test("unknown connections and missing keys fail without a Gateway fallback", async () => {
    const f = fixture();
    try {
      const unknown = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "missing" } });
      expect(unknown.code).not.toBe(0);
      const missingKey = await runFx(["ask", "--json", "--no-save", "hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "remote", FX_TEST_PROVIDER_TOKEN: undefined } });
      expect(missingKey.code).not.toBe(0);
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 25000);
});
