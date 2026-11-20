

import { Terminal } from "@xterm/headless";
import { createFxTerminal, xtermAdapter } from "libfx/browser";

export async function run(): Promise<void> {
  const term = new Terminal({ cols: 100, rows: 30, allowProposedApi: true });
  const runtime = await createFxTerminal({ terminal: xtermAdapter(term), wasm: "/fx-term.wasm" });
  await runtime.interactive;
  runtime.abort();
}
