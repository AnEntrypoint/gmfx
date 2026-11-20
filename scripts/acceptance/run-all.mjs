import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const binary = join(repo, "zig-out", "bin", "fx");
const binaryBlocked = !existsSync(binary);
const mode = process.argv.includes("--static") || binaryBlocked ? "static" : "binary";
const askReason = "MissingCredentials, ask not wired to FX_TEST_PARITY_CONTEXT";
const failures = [];
const results = [];

function sourceFiles(dir, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) sourceFiles(full, out);
    else if (entry.name.endsWith(".zig") && !entry.name.includes("parity") && !full.startsWith(join(repo, "src", "core", "parity"))) out.push(full);
  }
  return out;
}

function lastJsonLine(text) {
  const lines = text.trim().split("\n");
  try {
    return { line: lines[lines.length - 1], value: JSON.parse(lines[lines.length - 1]) };
  } catch {
    return null;
  }
}

function parityPassedWitness(gateStdout) {
  const parsed = lastJsonLine(gateStdout);
  if (!parsed) return { ok: false, detail: "item1 gate output is not JSON" };
  const gate = parsed.value;
  if (gate.item !== 1 || gate.ok !== true || !Array.isArray(gate.failures) || gate.failures.length !== 0) {
    return { ok: false, detail: "item1 gate summary does not report ok with no failures" };
  }
  return { ok: true, line: parsed.line };
}

function askOpenReason(gateStdout) {
  const parsed = lastJsonLine(gateStdout);
  if (!parsed) return { ok: false, detail: "item1 gate output is not JSON" };
  const gate = parsed.value;
  const gateFailures = Array.isArray(gate.failures) ? gate.failures : [];
  if (gateFailures.length === 0) return { ok: false, detail: "item1 gate failed without a recorded check" };
  const nonAsk = gateFailures.filter((message) => !message.startsWith("ask-"));
  if (nonAsk.length > 0) return { ok: false, detail: "item1 non-ask checks failed: " + nonAsk.join("; ") };

  const home = mkdtempSync(join(tmpdir(), "item1-open-"));
  const probe = spawnSync(binary, ["ask", "--json", "open-reason probe"], {
    cwd: repo,
    encoding: "utf8",
    env: { HOME: home, FX_HOME: join(home, ".fx"), PATH: "/usr/bin:/bin" },
    timeout: 30000
  });
  let probeError = null;
  try {
    probeError = JSON.parse(probe.stdout).error;
  } catch {
    probeError = null;
  }
  if (probe.status !== 1 || probeError !== "MissingCredentials") {
    return { ok: false, detail: "ask did not report MissingCredentials (status " + probe.status + ", error " + probeError + ")" };
  }

  const wired = sourceFiles(join(repo, "src"), []).filter((file) => readFileSync(file, "utf8").includes("FX_TEST_PARITY_CONTEXT"));
  if (wired.length > 0) return { ok: false, detail: "FX_TEST_PARITY_CONTEXT is referenced outside the parity modules: " + wired.join(", ") };

  return { ok: true, reason: askReason };
}

for (let item = 1; item <= 10; item += 1) {
  const script = join(repo, "scripts", "acceptance", "item" + item + ".mjs");
  if (!existsSync(script)) {
    failures.push("missing item" + item + ".mjs");
    continue;
  }
  const argv = mode === "static" ? ["--check", script] : [script];
  const env = { FX_PARITY_MODE: mode, FX_PARITY_BINARY_BLOCKED: String(binaryBlocked) };
  const run = spawnSync(process.execPath, argv, { cwd: repo, encoding: "utf8", env });
  if (item === 1 && run.status === 0) {
    const witness = parityPassedWitness(run.stdout || "");
    if (witness.ok) {
      results.push({ item, mode, status: "passed", witness: witness.line });
      continue;
    }
    failures.push("item1 exited 0 without an explicit passed witness: " + witness.detail);
    results.push({ item, mode, status: run.status });
    continue;
  }
  if (item === 1 && run.status === 1) {
    const open = askOpenReason(run.stdout || "");
    if (open.ok) {
      results.push({ item, mode, status: "open", reason: open.reason });
      continue;
    }
    failures.push("item1 " + mode + " failed: " + open.detail);
    results.push({ item, mode, status: run.status });
    continue;
  }
  results.push({ item, mode, status: run.status });
  if (run.status !== 0) {
    failures.push("item" + item + " " + mode + " failed with " + String(run.status) + " " + String(run.stderr || "").slice(0, 300));
  }
}

const gitSnapshot = join(repo, "scripts", "acceptance", "git-snapshot.mjs");
const gitRun = spawnSync(process.execPath, [gitSnapshot], { cwd: repo, encoding: "utf8" });
results.push({ item: "git-snapshot", mode: "binary", status: gitRun.status });
if (gitRun.status !== 0) failures.push("git-snapshot failed with " + String(gitRun.status) + " " + String(gitRun.stderr || "").slice(0, 300));

console.log(JSON.stringify({ mode, binaryBlocked, checked: 10, results, failures }));
if (failures.length) process.exit(1);
