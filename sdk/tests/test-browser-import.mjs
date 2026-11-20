#!/usr/bin/env node




import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";


const calls = [];
const record = (name, original) => function (...args) {
  calls.push(name);
  return original.apply(this, args);
};
globalThis.fetch = record("fetch", globalThis.fetch);
for (const name of ["compile", "compileStreaming", "instantiate", "instantiateStreaming"]) {
  WebAssembly[name] = record(`WebAssembly.${name}`, WebAssembly[name]);
}

const browser = await import("../browser.js");


const agent = browser.createFxAgent();
assert.equal(typeof agent.session, "function");
assert.deepEqual(calls, [], `importing libfx/browser and creating an agent did work: ${calls.join(", ")}`);


const nodeOnly = new Set(["node.js", "node.cjs", "node-wasm.js", "bundled-asset.js", "skills-node.js"]);
const importPattern = /(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)["']([^"']+)["']/g;
const sources = new Map();
const queue = ["browser.js"];
while (queue.length) {
  const name = queue.shift();
  if (sources.has(name)) continue;
  const source = await readFile(new URL(`../${name}`, import.meta.url), "utf8");
  sources.set(name, source);
  for (const [, specifier] of source.matchAll(importPattern)) {
    assert.ok(specifier.startsWith("./"), `${name} imports ${specifier}; libfx/browser must reach only its own modules`);
    const target = specifier.slice(2);
    assert.ok(!nodeOnly.has(target), `${name} imports ${target}, which is for Node.js`);
    queue.push(target);
  }
}



const statements = sources.get("browser.js").split("\n").filter((line) => line.trim() && !line.startsWith("//"));
for (const line of statements) assert.match(line, /^export \{[^}]+\} from "\.\/[a-z-]+\.js";$/, `browser.js must only re-export: ${line}`);

const namers = (asset) => [...sources].filter(([, source]) => source.includes(`"./${asset}"`)).map(([name]) => name);
assert.deepEqual(namers("fx-core.wasm"), ["browser-agent.js"]);
assert.deepEqual([...sources.keys()].filter((name) => sources.get(name).includes("fx-term.wasm")), [], "the disabled browser terminal must not name fx-term.wasm");
console.log(`libfx/browser import passed: no work on import, ${sources.size} modules with no Node.js code, only fx-core.wasm is named`);
