#!/usr/bin/env node
















import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { nativeDirArgument, nativeTarballs } from "./native-package.mjs";

const tarball = resolve(process.argv[2] ?? "");
const nativeDir = nativeDirArgument();
assert.ok(nativeDir, "usage: test-package-size.mjs <libfx.tgz> --native-dir <dir> [--print]");
const budgets = JSON.parse(await readFile(new URL("./package-size-budgets.json", import.meta.url), "utf8"));

async function unpackedBytes(dir) {
  let total = 0;
  for (const entry of await readdir(dir, { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) total += (await stat(join(entry.parentPath, entry.name))).size;
  }
  return total;
}


async function measurePackage(path) {
  const dir = await mkdtemp(resolve(tmpdir(), "libfx-size-"));
  const untar = spawnSync("tar", ["-xzf", path, "-C", dir, "--strip-components=1"]);
  assert.equal(untar.status, 0, String(untar.stderr));
  return { dir, packed: (await stat(path)).size, unpacked: await unpackedBytes(dir) };
}

const measured = {};
const libfx = await measurePackage(tarball);
try {
  measured.libfx = { packed: libfx.packed, unpacked: libfx.unpacked };


  for (const file of ["fx-core.wasm"]) measured[file] = { bytes: (await stat(join(libfx.dir, file))).size };
  for (const file of ["engine.js", "wasm-runtime.js", "fx-sdk.js"]) {
    measured[file] = { gzip: gzipSync(await readFile(join(libfx.dir, file)), { level: 9 }).length };
  }
} finally {
  await rm(libfx.dir, { recursive: true, force: true });
}




function frameRecordSetups(addon, packageName) {
  let count = 0;
  if (packageName.includes("arm64")) {
    for (let i = 0; i + 4 <= addon.length; i += 4) if (((addon.readUInt32LE(i) & 0xffc003ff) >>> 0) === 0x910003fd) count++;
  } else {
    const setup = Buffer.from([0x55, 0x48, 0x89, 0xe5]);
    for (let i = addon.indexOf(setup); i !== -1; i = addon.indexOf(setup, i + 1)) count++;
  }
  return count;
}
const miscompiled = [];


const toolSource = await readFile(new URL("../../src/builtins/tools.zig", import.meta.url), "utf8");
const toolDescriptions = [
  "Fetch a public http(s) URL the user named and return its text",
  "Run a shell command. Each call starts a new shell",
  "Read more of a truncated tool result by its handle",
];
for (const text of toolDescriptions) {
  assert.ok(toolSource.includes(text), `src/builtins/tools.zig no longer contains "${text}"; use another built-in tool's description`);
}
const withTools = [];
for (const [name, path] of Object.entries(nativeTarballs(nativeDir))) {
  const platform = await measurePackage(path);
  measured[name] = { packed: platform.packed, unpacked: platform.unpacked };
  const addon = await readFile(join(platform.dir, "libfx.node"));

  for (const section of ["eh_frame", "__unwind_info"]) if (addon.includes(section)) miscompiled.push(`${name}: has ${section}`);
  const frames = frameRecordSetups(addon, name);
  if (frames < 1000) miscompiled.push(`${name}: only ${frames} functions set up a frame record`);
  for (const text of toolDescriptions) if (addon.includes(text)) withTools.push(`${name}: "${text}"`);
  await rm(platform.dir, { recursive: true, force: true });
}
assert.deepEqual(miscompiled, [], `a native addon was built with the wrong code generation settings; see addNapiArtifact in build.zig:\n${miscompiled.join("\n")}`);
assert.deepEqual(withTools, [], `a native addon contains fx's built-in tools; build it with builtin_tools false:\n${withTools.join("\n")}`);

if (process.argv.includes("--print")) {
  console.log(JSON.stringify(measured, null, 2));
  process.exit(0);
}

const over = [];
for (const [name, sizes] of Object.entries(measured)) {
  const budget = budgets[name];
  assert.ok(budget, `package-size-budgets.json has no budget for ${name}`);
  for (const [metric, bytes] of Object.entries(sizes)) {
    assert.ok(budget[metric], `package-size-budgets.json has no ${metric} budget for ${name}`);
    const line = `${name} ${metric}: ${bytes} of ${budget[metric]} bytes (${Math.round(100 * bytes / budget[metric])}%)`;
    console.log(line);
    if (bytes > budget[metric]) over.push(line);
  }
}
assert.deepEqual(over, [], `over budget. A .wasm over its budget may have skipped sdk/scripts/optimize-wasm.mjs:\n${over.join("\n")}`);
console.log(`Package sizes passed: ${Object.keys(measured).length} files and packages within their budgets, every native addon has the expected code generation settings, and none contains fx's built-in tools`);
