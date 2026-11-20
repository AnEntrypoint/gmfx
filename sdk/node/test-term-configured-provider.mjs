#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-term.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run through: npm run test:term");
  process.exit(2);
}

const PROVIDER = "relay";
const MODEL = "relay-model";
const BASE_URL = "http://127.0.0.1:8793/v1";
const REPLY = "hello from the env provider";
const providers = {
  [PROVIDER]: {
    protocol: "openai-chat-completions",
    base_url: BASE_URL,
    auth: { type: "none" },
    model_metadata: { [MODEL]: { context_window: 200000, max_output_tokens: 8192, supports_tool_use: true } },
  },
};

const terminal = new Terminal({ cols: 96, rows: 30, allowProposedApi: true });
const encoded = new TextEncoder();
const requests = [];
const mockFetch = async (url, init) => {
  const body = JSON.parse(typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body));
  requests.push({ url: String(url), body });
  const frames = [
    `data: ${JSON.stringify({ id: "chat-1", choices: [{ index: 0, delta: { role: "assistant", content: REPLY }, finish_reason: null }] })}\n\n`,
    `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`,
    "data: [DONE]\n\n",
  ];
  return new Response(new ReadableStream({
    start(controller) {
      for (const frame of frames) controller.enqueue(encoded.encode(frame));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};

const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: {
    FX_CONFIGURED_PROVIDERS: JSON.stringify(providers),
    FX_PROVIDER: PROVIDER,
    FX_MODEL: MODEL,
  },
  fetch: mockFetch,
});
const exited = runtime.exited.then((code) => ({ code }));
const flushTerminal = () => new Promise((done) => terminal.write("", done));
const readGrid = () => {
  const lines = [];
  const buffer = terminal.buffer.active;
  for (let row = 0; row < buffer.length; row++) lines.push(buffer.getLine(row)?.translateToString(true) ?? "");
  return lines.join("\n");
};
const waitForGrid = async (text, what) => {
  const deadline = performance.now() + 8000;
  while (!readGrid().includes(text)) {
    await flushTerminal();
    const ended = await Promise.race([exited, new Promise((later) => setTimeout(() => later(null), 10))]);
    if (ended) throw new Error(`fx-term exited with code ${ended.code} while waiting for ${what}:\n${readGrid()}`);
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${what}; requests=${JSON.stringify(requests.map((request) => request.url))}:\n${readGrid()}`);
  }
};

await waitForGrid("𝒇x", "fx-term startup with a provider from the environment");
runtime.write("hi\r");
await waitForGrid(REPLY, "the env provider's reply to a typed hi");
const grid = readGrid();
runtime.write("/exit\r");
const { code } = await Promise.race([
  exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for fx-term exit")), 5000)),
]);

if (code !== 0) throw new Error(`fx-term exited with code ${code}`);
const chat = requests.filter((request) => request.url === `${BASE_URL}/chat/completions`);
if (chat.length !== 1) throw new Error(`expected one chat-completions request to the env provider, saw ${JSON.stringify(requests.map((request) => request.url))}`);
if (chat[0].body.model !== MODEL) throw new Error(`the request named model ${chat[0].body.model}`);
const userTurn = chat[0].body.messages?.findLast((message) => message.role === "user");
const userText = typeof userTurn?.content === "string" ? userTurn.content : JSON.stringify(userTurn?.content ?? "");
if (!userText.includes("hi")) throw new Error(`the request carried no typed hi: ${userText.slice(0, 200)}`);
if (chat[0].body.prompt !== undefined) throw new Error("the request used the gateway body shape");
if (!grid.includes(REPLY)) throw new Error(`the reply was not on the grid:\n${grid}`);

console.log(`configured provider smoke passed: POST ${chat[0].url} model=${chat[0].body.model} user=hi reply="${REPLY}" exit=${code}`);
