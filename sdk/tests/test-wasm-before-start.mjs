#!/usr/bin/env node
import assert from "node:assert/strict";
import { instantiate } from "../wasm-runtime.js";

const emptyStartModule = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
  0x03, 0x02, 0x01, 0x00,
  0x07, 0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00,
  0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
]);
const module = new WebAssembly.Module(emptyStartModule);

const originalSuspending = WebAssembly.Suspending;
const originalPromising = WebAssembly.promising;
const events = [];
const promisedExports = [];
WebAssembly.Suspending = class Suspending {};
WebAssembly.promising = (fn) => {
  promisedExports.push(fn);
  events.push("promising");
  return (...args) => Promise.resolve().then(() => fn(...args));
};

try {
  const hookSeen = [];
  const runtime = await instantiate({
    wasm: module,
    args: ["fx"],
    beforeStart(instance) {
      events.push("beforeStart");
      hookSeen.push(instance);
      assert.equal(typeof instance.exports._start, "function");
      assert.equal(promisedExports.length, 0, "beforeStart runs before _start is promised");
    },
  });
  assert.ok(runtime, "instantiate returns a runtime");
  assert.deepEqual(events, ["beforeStart", "promising"]);
  assert.equal(hookSeen.length, 1);
  assert.equal(promisedExports[0], hookSeen[0].exports._start);

  const withoutHook = await instantiate({ wasm: module, args: ["fx"] });
  assert.ok(withoutHook, "instantiate works without beforeStart");
  assert.equal(events.length, 3);
} finally {
  WebAssembly.Suspending = originalSuspending;
  WebAssembly.promising = originalPromising;
}

console.log("wasm-runtime beforeStart hook order ok");
